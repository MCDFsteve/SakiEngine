package dev.aimesoft.erika_flutter

internal enum class AndroidPlaybackPhase {
    PAUSED,
    PENDING,
    PLAYING,
}

internal fun androidAsyncPlayCanStart(
    phase: AndroidPlaybackPhase,
    canPlayInCurrentActivityState: Boolean,
    audioFocusGranted: Boolean,
): Boolean = phase == AndroidPlaybackPhase.PENDING &&
    canPlayInCurrentActivityState &&
    audioFocusGranted

/**
 * Main-thread playback and render intent for one Android player.
 *
 * Native playback state remains owned by Erika. This tracker records only the
 * Android host's intent, including whether a delayed focus gain may resume the
 * player and whether the attached surface needs another render tick.
 */
internal class AndroidPlaybackTracker {
    var phase: AndroidPlaybackPhase = AndroidPlaybackPhase.PAUSED
        private set

    @Volatile
    var surfaceAttached: Boolean = false
        private set

    @Volatile
    private var renderRequestGeneration: Long = 0L
    @Volatile
    private var acknowledgedRenderGeneration: Long = 0L
    private var playbackIntentGeneration: Long = 0L
    private var playInvocationGeneration: Long? = null

    val currentRenderRequestGeneration: Long
        get() = renderRequestGeneration

    val currentPlaybackIntentGeneration: Long
        get() = playbackIntentGeneration

    val renderRequested: Boolean
        get() = acknowledgedRenderGeneration < renderRequestGeneration

    val shouldTick: Boolean
        get() = phase == AndroidPlaybackPhase.PLAYING ||
            (surfaceAttached && renderRequested)

    fun requestPlayback(): Long {
        if (phase != AndroidPlaybackPhase.PENDING) {
            playbackIntentGeneration += 1L
        }
        phase = AndroidPlaybackPhase.PENDING
        return playbackIntentGeneration
    }

    /** Invalidates a queued transient-loss Pause before resuming the pending Play. */
    fun renewPendingPlaybackIntent(): Long? {
        if (phase != AndroidPlaybackPhase.PENDING) {
            return null
        }
        playbackIntentGeneration += 1L
        return playbackIntentGeneration
    }

    fun tryBeginPlayInvocation(): Long? {
        if (phase != AndroidPlaybackPhase.PENDING || playInvocationGeneration != null) {
            return null
        }
        return playbackIntentGeneration.also { generation ->
            playInvocationGeneration = generation
        }
    }

    /** Returns true only when the completed invocation still represents the latest intent. */
    fun finishPlayInvocation(generation: Long): Boolean {
        if (playInvocationGeneration != generation) {
            return false
        }
        playInvocationGeneration = null
        return playbackIntentGeneration == generation &&
            phase != AndroidPlaybackPhase.PAUSED
    }

    fun playbackStarted(): Boolean {
        if (phase != AndroidPlaybackPhase.PENDING) {
            return false
        }
        phase = AndroidPlaybackPhase.PLAYING
        requestRender()
        return true
    }

    /** Returns true when native playback was running and must be paused. */
    fun suspendPlayback(): Boolean {
        val wasPlaying = phase == AndroidPlaybackPhase.PLAYING
        if (phase != AndroidPlaybackPhase.PAUSED) {
            phase = AndroidPlaybackPhase.PENDING
        }
        return wasPlaying
    }

    /** Returns true when native playback is or may soon be running and must be paused. */
    fun handleFocusLoss(mayResume: Boolean): Boolean {
        val nativeMayBePlaying = phase == AndroidPlaybackPhase.PLAYING ||
            playInvocationGeneration != null
        if (phase != AndroidPlaybackPhase.PAUSED) {
            playbackIntentGeneration += 1L
        }
        phase = if (mayResume && phase != AndroidPlaybackPhase.PAUSED) {
            AndroidPlaybackPhase.PENDING
        } else {
            AndroidPlaybackPhase.PAUSED
        }
        return nativeMayBePlaying
    }

    /** Returns true when native playback is or may soon be running and must be paused. */
    fun cancelPlaybackIntent(forceNewGeneration: Boolean = false): Boolean {
        val nativeMayBePlaying = phase == AndroidPlaybackPhase.PLAYING ||
            playInvocationGeneration != null
        if (forceNewGeneration || phase != AndroidPlaybackPhase.PAUSED) {
            playbackIntentGeneration += 1L
        }
        phase = AndroidPlaybackPhase.PAUSED
        return nativeMayBePlaying
    }

    /** Reconciles a native terminal/paused state without inventing a command generation. */
    fun reconcileNativePlaybackStopped() {
        phase = AndroidPlaybackPhase.PAUSED
    }

    fun attachSurface() {
        surfaceAttached = true
        requestRender()
    }

    fun resizeSurface() {
        if (surfaceAttached) {
            requestRender()
        }
    }

    fun detachSurface() {
        surfaceAttached = false
    }

    @Synchronized
    fun requestRender(): Long {
        renderRequestGeneration += 1L
        return renderRequestGeneration
    }

    @Synchronized
    fun markRenderAttempted(generation: Long) {
        if (generation > acknowledgedRenderGeneration) {
            acknowledgedRenderGeneration = generation.coerceAtMost(renderRequestGeneration)
        }
    }
}
