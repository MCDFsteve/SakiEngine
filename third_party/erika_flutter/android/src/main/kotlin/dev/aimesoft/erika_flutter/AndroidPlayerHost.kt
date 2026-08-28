package dev.aimesoft.erika_flutter

import android.view.Surface
import java.util.concurrent.atomic.AtomicLong

internal class AndroidPlayerHost(
    val handle: Long,
    val requestedOutputMode: Int,
    allowBackgroundPlayback: Boolean,
    private val presenterThread: AndroidPresenterThread,
) {
    val requiresExtendedLinearSurface: Boolean
        get() = requestedOutputMode == 2
    var attachedView: ErikaAndroidVideoView? = null
    private val playbackTracker = AndroidPlaybackTracker()
    private val contentGenerationTracker = AndroidContentGenerationTracker()
    private val contentPreparations = AndroidContentPreparationRegistry()
    private val pendingEvents = AndroidPendingEventQueue(MAX_PENDING_EVENTS)
    val eventPollFailures = AndroidEventPollFailureDeduplicator()
    val eventPollBackoff = AndroidEventPollBackoff()
    private var lastCompleteNativeEvent: Map<String, Any?>? = null
    var mediaState = AndroidMediaState(
        playerId = handle,
        allowBackgroundPlayback = allowBackgroundPlayback,
    )
        private set
    val playbackPhase: AndroidPlaybackPhase
        get() = playbackTracker.phase
    val surfaceAttached: Boolean
        get() = playbackTracker.surfaceAttached
    val shouldTick: Boolean
        get() = playbackTracker.shouldTick
    val currentRenderRequestGeneration: Long
        get() = playbackTracker.currentRenderRequestGeneration
    val currentPlaybackIntentGeneration: Long
        get() = playbackTracker.currentPlaybackIntentGeneration
    private val executedPlaybackIntentGeneration = AtomicLong(0L)
    val latestExecutedPlaybackIntentGeneration: Long
        get() = executedPlaybackIntentGeneration.get()
    val currentContentGeneration: Long
        get() = contentGenerationTracker.currentGeneration
    val latestExecutedContentGeneration: Long
        get() = contentGenerationTracker.latestExecutedGeneration
    var lastRenderError: String? = null
    var lastRenderErrorContentGeneration: Long? = null
    var lastSurfaceError: String? = null
    @Volatile
    private var destroyed = false
    @Volatile
    private var nativeDestroyPending = false
    private var viewAwaitingNativeDestroy: ErikaAndroidVideoView? = null

    val isDestroyed: Boolean
        get() = destroyed

    val isNativeDestroyPending: Boolean
        get() = nativeDestroyPending

    fun enqueuePendingEvent(event: AndroidPendingEvent): AndroidPendingEventOverflow? =
        pendingEvents.enqueue(event)

    fun firstPendingEvent(): AndroidPendingEvent? = pendingEvents.firstOrNull()

    fun removeFirstPendingEvent(): AndroidPendingEvent = pendingEvents.removeFirst()

    fun discardStalePendingEvents(): Int =
        pendingEvents.discardStaleContentEvents(currentContentGeneration)

    fun requestPlayback(): Long = playbackTracker.requestPlayback()

    fun renewPendingPlaybackIntent(): Long? = playbackTracker.renewPendingPlaybackIntent()

    fun tryBeginPlayInvocation(): Long? = playbackTracker.tryBeginPlayInvocation()

    fun finishPlayInvocation(generation: Long): Boolean =
        playbackTracker.finishPlayInvocation(generation)

    fun markPlaybackIntentExecuted(generation: Long) {
        executedPlaybackIntentGeneration.accumulateAndGet(generation) { current, candidate ->
            maxOf(current, candidate)
        }
    }

    fun playbackStarted(): Boolean = playbackTracker.playbackStarted()

    fun suspendPlayback(): Boolean = playbackTracker.suspendPlayback()

    fun handleFocusLoss(mayResume: Boolean): Boolean =
        playbackTracker.handleFocusLoss(mayResume)

    fun cancelPlaybackIntent(forceNewGeneration: Boolean = false): Boolean =
        playbackTracker.cancelPlaybackIntent(forceNewGeneration)

    /** Cancels an intent that will not be followed by a native command. */
    fun cancelPlaybackIntentLocally(forceNewGeneration: Boolean = false): Boolean =
        playbackTracker.cancelPlaybackIntent(forceNewGeneration).also {
            markPlaybackIntentExecuted(currentPlaybackIntentGeneration)
        }

    fun reconcileNativePlaybackStopped() {
        playbackTracker.reconcileNativePlaybackStopped()
    }

    fun setMediaMetadata(metadata: AndroidMediaMetadata?) {
        mediaState = mediaState.copy(metadata = metadata)
    }

    fun prepareForOpen(metadata: AndroidMediaMetadata?): Long {
        lastCompleteNativeEvent = null
        mediaState = mediaState.copy(
            metadata = metadata,
            playbackState = 0,
            positionMicros = 0L,
            durationMicros = 0L,
        )
        return contentGenerationTracker.requestNewContent().also {
            // Content-scoped events can remain queued while Dart has no
            // listener or after a sink exception. Never let media A roll back
            // media B once its Open boundary has been requested.
            discardStalePendingEvents()
        }
    }

    fun markContentGenerationExecuted(generation: Long) {
        contentGenerationTracker.markExecuted(generation)
    }

    fun setSystemMediaNavigation(arguments: Map<String, Any?>) {
        mediaState = updatedSystemMediaNavigation(mediaState, arguments)
    }

    fun setPlaybackRate(rate: Float) {
        mediaState = mediaState.copy(playbackRate = rate)
    }

    fun closeMediaState() {
        lastCompleteNativeEvent = null
        mediaState = closedAndroidMediaState(mediaState)
    }

    fun updateMediaState(event: Map<*, *>, rememberCompleteEvent: Boolean = false) {
        mediaState = updatedAndroidMediaState(mediaState, event)
        if (rememberCompleteEvent) {
            lastCompleteNativeEvent = androidUpdatedNativeEventSnapshot(
                lastCompleteNativeEvent,
                event,
            )
        }
    }

    fun completeNativeEventSnapshot(): Map<String, Any?>? = lastCompleteNativeEvent

    fun requestRender() = playbackTracker.requestRender()

    fun markRenderAttempted(generation: Long) = playbackTracker.markRenderAttempted(generation)

    fun beginContentPreparation(
        onCancel: (String) -> Unit,
    ): AndroidContentPreparationToken = contentPreparations.begin(onCancel)

    fun finishContentPreparation(token: AndroidContentPreparationToken): Boolean =
        !destroyed && contentPreparations.finish(token)

    fun cancelContentPreparations(reason: String): Int = contentPreparations.invalidate(reason)

    fun invoke(method: String, arguments: Map<String, Any?>): NativeResponse {
        return invokeEncoded(method, NativeJson.encodeArguments(arguments))
    }

    fun invokeEncoded(
        method: String,
        argumentsJson: String,
        ownedFd: Int = NO_OWNED_FD,
    ): NativeResponse = NativeJson.decodeResponse(
        invokeEncodedRaw(method, argumentsJson, ownedFd),
    )

    /**
     * Returns the raw JNI response so callers transferring an fd can separate
     * failures before native dispatch from JSON decoding failures after Rust
     * has already taken ownership.
     */
    fun invokeEncodedRaw(
        method: String,
        argumentsJson: String,
        ownedFd: Int = NO_OWNED_FD,
    ): String {
        if (destroyed) {
            throw AndroidPlayerDestroyedException(handle)
        }
        return presenterThread.call {
            ErikaNative.nativeInvoke(handle, method, argumentsJson, ownedFd)
        }
    }

    fun attachSurface(
        surface: Surface,
        width: Int,
        height: Int,
        scale: Double,
        extendedLinear: Boolean,
        directComposition: Boolean,
        desiredHeadroom: Float,
        fallbackReason: Int,
    ): NativeResponse {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        val response = presenterThread.call {
            NativeJson.decodeResponse(
                ErikaNative.nativeAttachSurface(
                    handle,
                    surface,
                    width,
                    height,
                    scale,
                    extendedLinear,
                    directComposition,
                    desiredHeadroom,
                    fallbackReason,
                ),
            )
        }
        if (response.ok) {
            playbackTracker.attachSurface()
        }
        return response
    }

    fun attachSurfaceAsync(
        surface: Surface,
        width: Int,
        height: Int,
        scale: Double,
        extendedLinear: Boolean,
        directComposition: Boolean,
        desiredHeadroom: Float,
        fallbackReason: Int,
        onComplete: (Result<NativeResponse>) -> Unit,
    ): Boolean = presenterThread.post {
        onComplete(
            runCatching {
                attachSurface(
                    surface,
                    width,
                    height,
                    scale,
                    extendedLinear,
                    directComposition,
                    desiredHeadroom,
                    fallbackReason,
                )
            },
        )
    }

    fun resizeSurface(width: Int, height: Int, scale: Double): NativeResponse {
        if (!surfaceAttached || destroyed) {
            return NativeResponse.success()
        }
        val response = presenterThread.call {
            NativeJson.decodeResponse(
                ErikaNative.nativeResizeSurface(handle, width, height, scale),
            )
        }
        if (response.ok) {
            playbackTracker.resizeSurface()
        }
        return response
    }

    fun resizeSurfaceAsync(
        width: Int,
        height: Int,
        scale: Double,
        onComplete: (Result<NativeResponse>) -> Unit,
    ): Boolean = presenterThread.post {
        onComplete(runCatching { resizeSurface(width, height, scale) })
    }

    fun setOutputHeadroom(headroom: Float, known: Boolean): NativeResponse =
        invoke(
            "setOutputHeadroom",
            mapOf(
                "headroom" to headroom,
                "known" to known,
            ),
        )

    fun setOutputHeadroomAsync(
        headroom: Float,
        known: Boolean,
        onComplete: (Result<NativeResponse>) -> Unit,
    ): Boolean = presenterThread.post {
        onComplete(runCatching { setOutputHeadroom(headroom, known) })
    }

    fun detachSurface(): NativeResponse {
        if (!surfaceAttached || destroyed) {
            return NativeResponse.success()
        }
        val response = presenterThread.call {
            NativeJson.decodeResponse(ErikaNative.nativeDetachSurface(handle))
        }
        if (response.ok) {
            playbackTracker.detachSurface()
        }
        return response
    }

    /**
     * Queues a detach behind any in-flight render without making Android's UI thread wait.
     * The callback runs on the presenter owner thread; callers must marshal UI work back to
     * the main looper.
     */
    fun detachSurfaceAsync(
        onComplete: (Result<NativeResponse>) -> Unit,
    ): Boolean = presenterThread.post {
        onComplete(runCatching(::detachSurface))
    }

    /**
     * SurfaceHolder invalidates its Surface as soon as surfaceDestroyed returns. Place the
     * native detach behind already queued presenter work and wait for a short, bounded
     * lifecycle barrier. Keep native attachment state until success so a timeout or failure
     * cannot let replacement binding skip the serialized retry.
     */
    fun detachSurfaceForSystemDestroy(): NativeResponse {
        if (destroyed) {
            if (!nativeDestroyPending) {
                return NativeResponse.success()
            }
            return try {
                // nativeDestroy is already queued on the same serial owner. A no-op
                // barrier therefore proves it has finished dropping the Surface.
                presenterThread.callForSurfaceDestroy(SURFACE_DESTROY_TIMEOUT_MILLIS) { Unit }
                NativeResponse.success()
            } catch (error: Throwable) {
                NativeResponse(
                    false,
                    -1,
                    error.message ?: "Unable to retire Android SurfaceView output",
                    null,
                )
            }
        }
        if (!surfaceAttached) {
            return NativeResponse.success()
        }
        val response = try {
            presenterThread.callForSurfaceDestroy(SURFACE_DESTROY_TIMEOUT_MILLIS) {
                NativeJson.decodeResponse(ErikaNative.nativeDetachSurface(handle))
            }
        } catch (error: Throwable) {
            NativeResponse(
                false,
                -1,
                error.message ?: "Unable to detach Android SurfaceView output",
                null,
            )
        }
        if (response.ok) {
            playbackTracker.detachSurface()
        }
        return response
    }

    fun renderTick(timeSeconds: Double): NativeResponse {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        return presenterThread.call {
            NativeJson.decodeResponse(ErikaNative.nativeRenderTick(handle, timeSeconds))
        }
    }

    fun audioOnlyTick(): NativeResponse {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        return presenterThread.call {
            NativeJson.decodeResponse(ErikaNative.nativeAudioOnlyTick(handle))
        }
    }

    fun pollEvent(): NativeResponse? {
        if (destroyed) {
            return null
        }
        return presenterThread.call {
            NativeJson.decodeOptionalEventResponse(ErikaNative.nativePollEvent(handle))
        }
    }

    fun playbackState(): Int {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        return presenterThread.call {
            ErikaNative.nativePlaybackState(handle).also { state ->
                check(state >= 0) { "Unable to read Erika player $handle playback state" }
            }
        }
    }

    fun playbackIntentState(): Int {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        return presenterThread.call {
            ErikaNative.nativePlaybackIntentState(handle).also { state ->
                check(state >= 0) { "Unable to read Erika player $handle playback intent state" }
            }
        }
    }

    fun captureFrame(width: Int, height: Int): ByteArray? {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        return presenterThread.call {
            ErikaNative.nativeCaptureFrame(handle, width, height)
        }
    }

    fun captureFrameAsync(
        width: Int,
        height: Int,
        onComplete: (Result<ByteArray?>) -> Unit,
    ): Boolean = presenterThread.post {
        onComplete(runCatching { captureFrame(width, height) })
    }

    fun registerSubtitleMemoryFont(data: ByteArray): NativeResponse {
        check(!destroyed) { "Erika player $handle has been destroyed" }
        return presenterThread.call {
            NativeJson.decodeResponse(
                ErikaNative.nativeRegisterSubtitleMemoryFont(handle, data),
            )
        }
    }

    fun registerSubtitleMemoryFontAsync(
        data: ByteArray,
        onComplete: (Result<NativeResponse>) -> Unit,
    ): Boolean = presenterThread.post {
        onComplete(runCatching { registerSubtitleMemoryFont(data) })
    }

    fun destroyAsync(onComplete: (Result<Unit>) -> Unit = {}): Boolean {
        if (destroyed) {
            onComplete(Result.success(Unit))
            return true
        }
        // Publish logical destruction before the queued native boundary so a render drain
        // requeued behind nativeDestroy cannot race the already-freed presenter handle.
        destroyed = true
        nativeDestroyPending = true
        val posted = presenterThread.post {
            val result = runCatching { ErikaNative.nativeDestroy(handle) }
            nativeDestroyPending = false
            onComplete(result)
        }
        if (!posted) {
            // No native work started. Keep the host retryable for a failed Dispose call.
            destroyed = false
            nativeDestroyPending = false
            return false
        }
        cancelContentPreparations("player_disposed")
        val view = attachedView
        attachedView = null
        viewAwaitingNativeDestroy = view
        view?.onPlayerDestroyQueued(this)
        pendingEvents.clear()
        playbackTracker.detachSurface()
        return true
    }

    /** Runs on Android's main thread only after nativeDestroy has completed. */
    fun finishDestroyOnMain() {
        val view = viewAwaitingNativeDestroy
        viewAwaitingNativeDestroy = null
        view?.onPlayerDestroyed(this)
    }

    private companion object {
        const val NO_OWNED_FD = -1
        const val MAX_PENDING_EVENTS = 1024
        const val SURFACE_DESTROY_TIMEOUT_MILLIS = 250L
    }
}

internal class AndroidPlayerDestroyedException(handle: Long) :
    IllegalStateException("Erika player $handle has been destroyed")

internal fun androidNativeInvokeDidNotStart(error: Throwable): Boolean =
    error is AndroidPlayerDestroyedException || error is UnsatisfiedLinkError
