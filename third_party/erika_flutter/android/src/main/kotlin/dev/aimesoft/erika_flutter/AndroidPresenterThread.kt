package dev.aimesoft.erika_flutter

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.util.Log
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

internal fun androidPresenterCallMustBeAsync(
    isOwnerThread: Boolean,
    isAndroidMainThread: Boolean,
): Boolean = !isOwnerThread && isAndroidMainThread

internal inline fun androidPresenterTaskResult(block: () -> Unit): Result<Unit> = runCatching(block)

/**
 * Serial owner thread for Android presenter handles.
 *
 * Rust records the JNI thread that creates a presenter and rejects every call
 * from a different thread. Keeping creation, commands, surface operations,
 * rendering, capture, event polling, and destruction on this dispatcher makes
 * that ownership explicit while leaving Flutter's platform thread responsive.
 */
internal class AndroidPresenterThread(
    name: String = "erika-presenter",
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val thread = HandlerThread(name, Process.THREAD_PRIORITY_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)

    val isOwnerThread: Boolean
        get() = Looper.myLooper() === thread.looper

    fun post(block: () -> Unit): Boolean {
        if (closed.get()) {
            return false
        }
        return handler.post {
            androidPresenterTaskResult(block).onFailure { error ->
                Log.e(TAG, "Unhandled Android presenter task failure", error)
            }
        }
    }

    fun <T> call(block: () -> T): T {
        if (isOwnerThread) {
            return block()
        }
        check(!androidPresenterCallMustBeAsync(
            isOwnerThread = false,
            isAndroidMainThread = Looper.myLooper() === Looper.getMainLooper(),
        )) {
            "Android UI thread must post presenter work asynchronously"
        }
        check(!closed.get()) { "Android presenter thread is closed" }
        val task = FutureTask(Callable(block))
        check(handler.post(task)) { "Android presenter thread rejected a task" }
        return try {
            task.get()
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IllegalStateException("Interrupted while waiting for Android presenter thread", error)
        } catch (error: ExecutionException) {
            val cause = error.cause ?: error
            when (cause) {
                is RuntimeException -> throw cause
                is Error -> throw cause
                else -> throw IllegalStateException("Android presenter task failed", cause)
            }
        }
    }

    /**
     * SurfaceView does not let its owner retain the underlying buffer queue after
     * surfaceDestroyed returns. Queue a native detach behind earlier presenter work and
     * wait for only this lifecycle boundary; regular rendering never uses this path.
     *
     * A timed-out task deliberately remains queued. This stops the UI thread from waiting
     * indefinitely behind a slow Open while still ensuring native eventually drops the
     * retired window before any subsequently posted render work.
     */
    fun <T> callForSurfaceDestroy(timeoutMillis: Long, block: () -> T): T {
        if (isOwnerThread) {
            return block()
        }
        check(Looper.myLooper() === Looper.getMainLooper()) {
            "Surface destroy barriers may only wait from Android's UI thread"
        }
        check(timeoutMillis > 0L) { "Surface destroy timeout must be positive" }
        check(!closed.get()) { "Android presenter thread is closed" }
        val task = FutureTask(Callable(block))
        check(handler.post(task)) { "Android presenter thread rejected a surface destroy barrier" }
        return try {
            task.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IllegalStateException("Interrupted while detaching an Android surface", error)
        } catch (error: TimeoutException) {
            throw IllegalStateException(
                "Timed out after ${timeoutMillis}ms detaching an Android surface",
                error,
            )
        } catch (error: ExecutionException) {
            val cause = error.cause ?: error
            when (cause) {
                is RuntimeException -> throw cause
                is Error -> throw cause
                else -> throw IllegalStateException("Android surface detach failed", cause)
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) {
            return
        }
        thread.quitSafely()
        // Flutter detaches plugins on Android's UI thread. Joining a presenter
        // that is retiring a slow Open would recreate the ANR this dispatcher
        // exists to avoid; quitSafely drains the already-queued native destroys.
        if (Looper.myLooper() === Looper.getMainLooper()) {
            return
        }
        if (!isOwnerThread) {
            try {
                thread.join(SHUTDOWN_TIMEOUT_MILLIS)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (thread.isAlive) {
                thread.quit()
                try {
                    thread.join(SHUTDOWN_TIMEOUT_MILLIS)
                } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }
    }

    private companion object {
        const val TAG = "AndroidPresenterThread"
        const val SHUTDOWN_TIMEOUT_MILLIS = 2_000L
    }
}
