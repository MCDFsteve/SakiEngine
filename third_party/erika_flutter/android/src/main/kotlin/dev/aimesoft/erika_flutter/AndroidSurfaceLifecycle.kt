package dev.aimesoft.erika_flutter

internal data class AndroidSurfaceDestroyDecision(
    val releaseSurfaceTexture: Boolean,
    val retryNativeDetach: Boolean,
)

internal fun androidSurfaceDestroyDecision(
    nativeDetachSucceeded: Boolean,
): AndroidSurfaceDestroyDecision = AndroidSurfaceDestroyDecision(
    // Native detach is asynchronous for TextureView. Retain ownership and release the
    // SurfaceTexture explicitly only after that presenter boundary has completed.
    releaseSurfaceTexture = false,
    // Native attachment state is committed only on success, so a failed detach
    // remains explicit and can be retried before binding the next SurfaceTexture.
    retryNativeDetach = !nativeDetachSucceeded,
)

/** A failed detach remains explicit until a retry or native destroy confirms retirement. */
internal fun androidSurfaceDestroyNeedsRetry(
    nativeDetachSucceeded: Boolean,
    hostDestroying: Boolean,
): Boolean = !hostDestroying && !nativeDetachSucceeded

internal const val ANDROID_SURFACE_RECOVERY_MAX_RETRIES = 6

private val androidSurfaceRecoveryDelaysMillis = listOf(16L, 32L, 64L, 128L, 256L, 512L)

/** Returns null once the bounded recovery budget has been exhausted. */
internal fun androidSurfaceRecoveryDelayMillis(retryAttempt: Int): Long? {
    if (retryAttempt <= 0) {
        return null
    }
    return androidSurfaceRecoveryDelaysMillis.getOrNull(retryAttempt - 1)
}

/** Counts completed native failures, rather than merely queued retry tasks. */
internal class AndroidSurfaceRecoveryAttemptTracker {
    private var generation: Long? = null
    private var operation: String? = null
    private var failures = 0
    private var exhaustionReported = false

    fun recordFailure(generation: Long, operation: String): Int {
        if (this.generation != generation || this.operation != operation) {
            this.generation = generation
            this.operation = operation
            failures = 0
            exhaustionReported = false
        }
        failures += 1
        return failures
    }

    fun complete(generation: Long, operation: String): Boolean {
        if (this.generation != generation || this.operation != operation || failures == 0) {
            return false
        }
        reset()
        return true
    }

    fun markExhaustionReported(generation: Long, operation: String): Boolean {
        if (this.generation != generation || this.operation != operation || exhaustionReported) {
            return false
        }
        exhaustionReported = true
        return true
    }

    fun reset() {
        generation = null
        operation = null
        failures = 0
        exhaustionReported = false
    }
}

internal fun androidShouldRefreshHdrHeadroomAfterRecovery(
    hostStillBound: Boolean,
    surfaceAttached: Boolean,
    disposed: Boolean,
    disposeRequested: Boolean,
    unbindRequested: Boolean,
): Boolean = hostStillBound &&
    surfaceAttached &&
    !disposed &&
    !disposeRequested &&
    !unbindRequested

internal fun androidShouldResumePendingViewBind(
    hostDestroyed: Boolean,
    targetDisposed: Boolean,
    targetDisposeRequested: Boolean,
    targetAcceptsHost: Boolean,
    hostAcceptsTarget: Boolean,
): Boolean = !hostDestroyed &&
    !targetDisposed &&
    !targetDisposeRequested &&
    targetAcceptsHost &&
    hostAcceptsTarget

/** A successful detach still completes an unbind that a newer bind superseded. */
internal fun androidDetachCompletesSupersededUnbind(
    nativeDetachSucceeded: Boolean,
    unbindRequested: Boolean,
    disposeRequested: Boolean,
): Boolean = nativeDetachSucceeded && !unbindRequested && !disposeRequested

/** A detach that cannot recover must retire the presenter before Java releases its buffers. */
internal fun androidSurfaceRecoveryExhaustionRequiresHostRetirement(
    failedOperation: String,
    nativeDetachRetryPending: Boolean,
    unbindRequested: Boolean,
    disposeRequested: Boolean,
): Boolean = failedOperation == "detachSurface" &&
    (nativeDetachRetryPending || unbindRequested || disposeRequested)

/**
 * A live TextureView keeps the same SurfaceTexture while an activity is merely
 * stopped (for example, after pressing Home). Detaching and immediately
 * recreating a wgpu surface around that still-live buffer queue can leave some
 * Android Vulkan drivers acquiring from the retired native window. Keep the
 * native attachment until TextureView reports an actual surface destruction.
 */
internal fun androidShouldRetainSurfaceDuringActivityStop(
    usesTextureView: Boolean,
    outputSurfaceValid: Boolean,
): Boolean = usesTextureView && outputSurfaceValid

internal class AndroidSurfaceRecoveryTokenSource {
    var currentToken: Long = 0L
        private set

    fun invalidate() {
        currentToken += 1L
    }

    fun isCurrent(token: Long): Boolean = token == currentToken
}

/** Separates callbacks belonging to retired Surface/bind requests. */
internal class AndroidSurfaceBindingGenerationTracker {
    var currentGeneration: Long = 0L
        private set

    fun advance(): Long {
        currentGeneration = if (currentGeneration == Long.MAX_VALUE) 1L else currentGeneration + 1L
        return currentGeneration
    }

    fun isCurrent(generation: Long): Boolean = generation == currentGeneration
}

/** A callback may mutate recovery state only while it still owns the active surface binding. */
internal fun androidSurfaceCallbackIsCurrent(
    callbackGeneration: Long,
    currentGeneration: Long,
    hostStillBound: Boolean,
    surfaceStillCurrent: Boolean,
): Boolean = callbackGeneration == currentGeneration && hostStillBound && surfaceStillCurrent

/** A null generation deliberately settles all physical detach waiters for the same host. */
internal fun androidSurfaceCompletionMatchesGeneration(
    completionGeneration: Long,
    callbackGeneration: Long?,
): Boolean = callbackGeneration == null || completionGeneration == callbackGeneration

/** A posted asynchronous JNI operation has no result until its callback runs. */
internal fun androidSurfaceOperationIsPending(
    operation: String,
    nativeAttachPending: Boolean,
    nativeDetachPending: Boolean,
    nativeResizePending: Boolean,
): Boolean = when (operation) {
    "attachSurface" -> nativeAttachPending
    "detachSurface" -> nativeDetachPending
    "resizeSurface" -> nativeResizePending
    else -> false
}

/** An existing lifecycle detach is the serialized native boundary for unbind. */
internal fun androidUnbindNeedsNewSurfaceDetach(
    lifecycleDetachPending: Boolean,
): Boolean = !lifecycleDetachPending
