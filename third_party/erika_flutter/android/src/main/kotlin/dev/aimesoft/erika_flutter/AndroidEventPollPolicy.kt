package dev.aimesoft.erika_flutter

import java.util.concurrent.atomic.AtomicLong

internal const val ANDROID_MAX_EVENT_POLL_IDLE_ROUNDS = 6
internal const val ANDROID_MAX_EVENT_POLL_FAILURE_ROUNDS = 5
internal const val ANDROID_DURATION_CHANGED_EVENT_KIND = 2
internal const val ANDROID_POSITION_CHANGED_EVENT_KIND = 3
internal const val ANDROID_TRACKS_CHANGED_EVENT_KIND = 4
internal const val ANDROID_BUFFERING_CHANGED_EVENT_KIND = 5
internal const val ANDROID_VIDEO_PARAMS_CHANGED_EVENT_KIND = 6
internal const val ANDROID_SURFACE_ATTACHED_EVENT_KIND = 7
internal const val ANDROID_SURFACE_DETACHED_EVENT_KIND = 8
internal const val ANDROID_TRACK_SELECTION_CHANGED_EVENT_KIND = 10

internal fun androidPendingEventContentGeneration(
    eventKind: Int?,
    contentGeneration: Long,
): Long? = when (eventKind) {
    ANDROID_SURFACE_ATTACHED_EVENT_KIND,
    ANDROID_SURFACE_DETACHED_EVENT_KIND,
    -> null
    else -> contentGeneration
}

private val ANDROID_SURFACE_EVENT_OPERATIONS = setOf(
    "attachSurface",
    "detachSurface",
    "resizeSurface",
)

internal class AndroidImmediateEventPollLatch {
    var pending: Boolean = false
        private set

    fun request(immediate: Boolean) {
        pending = pending || immediate
    }

    fun takeIfReady(pollInFlight: Boolean): Boolean {
        if (pollInFlight || !pending) {
            return false
        }
        pending = false
        return true
    }

    fun clear() {
        pending = false
    }
}

/** Suppresses repeated delivery of the same persistent native polling failure. */
internal class AndroidEventPollFailureDeduplicator {
    private var lastSignature: String? = null

    fun shouldReport(signature: String?, canDeliver: Boolean = true): Boolean {
        if (signature == null) {
            lastSignature = null
            return false
        }
        // Do not consume a signature for a failure that policy rejected
        // before it could even be queued for Dart.
        if (!canDeliver) {
            return false
        }
        if (signature == lastSignature) {
            return false
        }
        lastSignature = signature
        return true
    }

    fun clear() {
        lastSignature = null
    }
}

/** Keeps a failing presenter from slowing event delivery for healthy players. */
internal class AndroidEventPollBackoff {
    var failureRounds: Int = 0
        private set
    private var retryAtMillis: Long = 0L

    fun record(failed: Boolean, nowMillis: Long) {
        if (!failed) {
            reset()
            return
        }
        failureRounds = (failureRounds + 1)
            .coerceAtMost(ANDROID_MAX_EVENT_POLL_FAILURE_ROUNDS)
        retryAtMillis = nowMillis + androidEventPollFailureDelayMillis(failureRounds)
    }

    fun delayMillis(nowMillis: Long): Long = (retryAtMillis - nowMillis).coerceAtLeast(0L)

    fun reset() {
        failureRounds = 0
        retryAtMillis = 0L
    }
}

internal fun androidAuthoritativeStateEvent(
    lastCompleteEvent: Map<String, Any?>?,
    playerId: Long,
    stateChangedEventKind: Int,
    state: Int,
    durationMicros: Long,
    positionMicros: Long,
): LinkedHashMap<String, Any?> {
    val event = linkedMapOf<String, Any?>()
    lastCompleteEvent?.forEach(event::put)
    event["playerId"] = playerId
    event["kind"] = stateChangedEventKind
    event["state"] = state
    event["durationMicros"] = durationMicros
    event["positionMicros"] = positionMicros
    event.putIfAbsent("buffering", false)
    event.putIfAbsent("video", emptyMap<String, Any?>())
    event.putIfAbsent("tracks", emptyMap<String, Any?>())
    event.putIfAbsent("trackList", emptyList<Map<String, Any?>>())
    event.putIfAbsent("trackSelection", emptyMap<String, Any?>())
    event["status"] = 0
    return event
}

/**
 * Builds a persistent snapshot from the one payload field that each native event kind owns.
 * The JNI schema includes defaults for every other field, so copying a raw event wholesale
 * would turn an unrelated surface/position notification into false zero-valued media state.
 */
internal fun androidUpdatedNativeEventSnapshot(
    previous: Map<String, Any?>?,
    event: Map<*, *>,
): Map<String, Any?> {
    val snapshot = linkedMapOf<String, Any?>()
    previous?.forEach(snapshot::put)
    event["playerId"]?.let { snapshot["playerId"] = it }
    when ((event["kind"] as? Number)?.toInt()) {
        STATE_CHANGED_EVENT_KIND ->
            event.copySnapshotFieldTo(snapshot, "state")
        ANDROID_DURATION_CHANGED_EVENT_KIND ->
            event.copySnapshotFieldTo(snapshot, "durationMicros")
        ANDROID_POSITION_CHANGED_EVENT_KIND ->
            event.copySnapshotFieldTo(snapshot, "positionMicros")
        ANDROID_TRACKS_CHANGED_EVENT_KIND -> {
            event.copySnapshotFieldTo(snapshot, "tracks")
            event.copySnapshotFieldTo(snapshot, "trackList")
            event.copySnapshotFieldTo(snapshot, "trackSelection")
        }
        ANDROID_BUFFERING_CHANGED_EVENT_KIND ->
            event.copySnapshotFieldTo(snapshot, "buffering")
        ANDROID_VIDEO_PARAMS_CHANGED_EVENT_KIND ->
            event.copySnapshotFieldTo(snapshot, "video")
        ANDROID_TRACK_SELECTION_CHANGED_EVENT_KIND -> {
            event.copySnapshotFieldTo(snapshot, "trackList")
            event.copySnapshotFieldTo(snapshot, "trackSelection")
        }
    }
    return snapshot
}

private fun Map<*, *>.copySnapshotFieldTo(
    destination: MutableMap<String, Any?>,
    field: String,
) {
    if (containsKey(field)) {
        destination[field] = this[field]
    }
}

/** A state snapshot may not overtake events left behind by a truncated/failed drain. */
internal fun androidCanSynthesizeAuthoritativeState(eventQueueDrained: Boolean): Boolean =
    eventQueueDrained

/** Suppress the real queued StateChanged if an earlier authoritative snapshot already sent it. */
internal fun androidStateChangedEventIsDuplicate(
    currentPlaybackState: Int,
    eventPlaybackState: Int?,
): Boolean = eventPlaybackState != null && currentPlaybackState == eventPlaybackState

/** Separates a requested media switch from the point where native begins executing it. */
internal class AndroidContentGenerationTracker {
    private val requestedGeneration = AtomicLong(0L)
    private val executedGeneration = AtomicLong(0L)

    val currentGeneration: Long
        get() = requestedGeneration.get()

    val latestExecutedGeneration: Long
        get() = executedGeneration.get()

    fun requestNewContent(): Long = requestedGeneration.incrementAndGet()

    fun markExecuted(generation: Long) {
        executedGeneration.accumulateAndGet(generation) { current, candidate ->
            maxOf(current, candidate)
        }
    }
}

/** Keeps active playback responsive while backing stable paused players off. */
internal fun androidEventPollDelayMillis(
    hasActivePlayers: Boolean,
    idleRounds: Int,
): Long {
    if (hasActivePlayers) {
        return 50L
    }
    return when (idleRounds.coerceAtLeast(0)) {
        0 -> 50L
        1 -> 100L
        2 -> 250L
        3 -> 500L
        4 -> 1_000L
        5 -> 2_500L
        else -> 5_000L
    }
}

/** Persistent JNI failures back off even while playback intent remains active. */
internal fun androidEventPollFailureDelayMillis(failureRounds: Int): Long = when (
    failureRounds.coerceAtLeast(0)
) {
    0 -> 0L
    1 -> 250L
    2 -> 500L
    3 -> 1_000L
    4 -> 2_500L
    else -> 5_000L
}

internal fun androidNextEventPollDelayMillis(
    idleDelayMillis: Long,
    hostRetryDelaysMillis: Iterable<Long>,
): Long = maxOf(
    idleDelayMillis,
    hostRetryDelaysMillis.minOrNull() ?: 0L,
)

/** Native surface lifecycle events should not wait for a paused player's idle backoff. */
internal fun androidSurfaceOperationNeedsImmediateEventPoll(
    operation: String,
    responseOk: Boolean,
): Boolean = responseOk && operation in ANDROID_SURFACE_EVENT_OPERATIONS

/** Only the native command generation that still owns playback intent may change host state. */
internal fun androidEventBatchAcceptsPlaybackState(
    eventGeneration: Long,
    currentIntentGeneration: Long,
): Boolean = eventGeneration == currentIntentGeneration

/** No event from the previously executed media may cross a requested Open boundary. */
internal fun androidEventBatchAcceptsContent(
    eventGeneration: Long,
    currentContentGeneration: Long,
): Boolean = eventGeneration == currentContentGeneration

/**
 * Surface lifecycle belongs to the presenter rather than the currently opened media, so
 * those events survive a content-generation boundary. Within the current content, stale
 * playback commands suppress only state rollback while retaining position/error/track events.
 */
internal fun androidEventShouldBeDelivered(
    eventKind: Int?,
    stateChangedEventKind: Int,
    acceptsContent: Boolean,
    acceptsPlaybackState: Boolean,
    pendingPlayTransition: Boolean,
): Boolean {
    val contentIndependent = eventKind == ANDROID_SURFACE_ATTACHED_EVENT_KIND ||
        eventKind == ANDROID_SURFACE_DETACHED_EVENT_KIND
    return (acceptsContent || contentIndependent) && (
        eventKind != stateChangedEventKind ||
            (acceptsPlaybackState && !pendingPlayTransition)
        )
}

/** A queued Play may be visible before the Rust worker commits actual Playing state. */
internal fun androidPlaybackStateIsPendingPlayTransition(
    playbackState: Int,
    playbackIntentState: Int?,
    playingState: Int,
): Boolean = playbackState != playingState && playbackIntentState == playingState

/** MediaSession follows the accepted Playing intent while native commits asynchronously. */
internal fun androidMediaSessionPlaybackState(
    playbackState: Int,
    playbackIntentState: Int?,
    playingState: Int,
    acceptsPlaybackState: Boolean,
): Int = if (
    acceptsPlaybackState && androidPlaybackStateIsPendingPlayTransition(
        playbackState,
        playbackIntentState,
        playingState,
    )
) {
    playingState
} else {
    playbackState
}

/** Only the callback that still owns an accepted Play may pause it during UI recovery. */
internal fun androidAsyncPlayCallbackNeedsRollback(
    nativePlayAccepted: Boolean,
    isCurrentHost: Boolean,
    ownsCurrentIntent: Boolean,
): Boolean = nativePlayAccepted && isCurrentHost && ownsCurrentIntent

/** A failed current Open becomes an explicit native Close content boundary. */
internal fun androidFailedContentOpenShouldClose(
    method: String,
    hostDestroyed: Boolean,
    failedGeneration: Long?,
    currentGeneration: Long,
): Boolean = method == "open" &&
    !hostDestroyed &&
    failedGeneration != null &&
    failedGeneration == currentGeneration

/**
 * A decoded Stop/Close response proves that JNI dispatched the content command even when
 * the command reports a business failure. A failed Open is different: validation may fail
 * before Rust establishes its Opening boundary, so its replacement Close owns the marker.
 */
internal fun androidContentCommandEstablishedBoundary(
    method: String,
    responseDecoded: Boolean,
    responseOk: Boolean,
): Boolean = responseDecoded && (method != "open" || responseOk)
