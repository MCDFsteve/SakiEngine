package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidEventPollPolicyTest {
    @Test
    fun activePlaybackAlwaysUsesTheLowLatencyInterval() {
        for (idleRounds in 0..20) {
            assertEquals(50L, androidEventPollDelayMillis(true, idleRounds))
        }
    }

    @Test
    fun pausedPlaybackBacksOffToFiveSeconds() {
        assertEquals(
            listOf(50L, 100L, 250L, 500L, 1_000L, 2_500L, 5_000L),
            (0..ANDROID_MAX_EVENT_POLL_IDLE_ROUNDS).map { idleRounds ->
                androidEventPollDelayMillis(false, idleRounds)
            },
        )
        assertEquals(5_000L, androidEventPollDelayMillis(false, 100))
    }

    @Test
    fun persistentPollingFailuresBackOffEvenForActivePlayback() {
        assertEquals(
            listOf(0L, 250L, 500L, 1_000L, 2_500L, 5_000L),
            (0..ANDROID_MAX_EVENT_POLL_FAILURE_ROUNDS)
                .map(::androidEventPollFailureDelayMillis),
        )
        assertEquals(5_000L, androidEventPollFailureDelayMillis(100))
    }

    @Test
    fun aFailingPlayerDoesNotBackOffAHealthyPlayer() {
        val failed = AndroidEventPollBackoff()
        val healthy = AndroidEventPollBackoff()
        failed.record(failed = true, nowMillis = 1_000L)

        assertEquals(250L, failed.delayMillis(1_000L))
        assertEquals(0L, healthy.delayMillis(1_000L))
        assertEquals(
            50L,
            androidNextEventPollDelayMillis(
                idleDelayMillis = 50L,
                hostRetryDelaysMillis = listOf(
                    failed.delayMillis(1_000L),
                    healthy.delayMillis(1_000L),
                ),
            ),
        )
        assertEquals(
            250L,
            androidNextEventPollDelayMillis(
                idleDelayMillis = 50L,
                hostRetryDelaysMillis = listOf(failed.delayMillis(1_000L)),
            ),
        )

        failed.record(failed = false, nowMillis = 1_100L)
        assertEquals(0, failed.failureRounds)
        assertEquals(0L, failed.delayMillis(1_100L))
    }

    @Test
    fun authoritativeStateEventsPreserveTheLastCompleteNativeSnapshot() {
        val video = mapOf("width" to 3840, "height" to 2160, "fps" to 60.0)
        val tracks = mapOf("video" to 1, "audio" to 2, "subtitle" to 3)
        val selection = mapOf("video" to 0, "audio" to 1, "subtitle" to -1)
        val event = androidAuthoritativeStateEvent(
            lastCompleteEvent = mapOf(
                "playerId" to 7L,
                "kind" to 3,
                "state" to 2,
                "durationMicros" to 20_000_000L,
                "positionMicros" to 8_000_000L,
                "buffering" to true,
                "video" to video,
                "tracks" to tracks,
                "trackList" to listOf(mapOf("id" to 0)),
                "trackSelection" to selection,
                "status" to 17,
            ),
            playerId = 7L,
            stateChangedEventKind = 1,
            state = 3,
            durationMicros = 20_000_000L,
            positionMicros = 9_000_000L,
        )

        assertEquals(1, event["kind"])
        assertEquals(3, event["state"])
        assertEquals(9_000_000L, event["positionMicros"])
        assertEquals(true, event["buffering"])
        assertEquals(video, event["video"])
        assertEquals(tracks, event["tracks"])
        assertEquals(selection, event["trackSelection"])
        assertEquals(0, event["status"])
    }

    @Test
    fun sparseNativeEventsUpdateOnlyTheirAuthoritativeSnapshotFields() {
        val video = mapOf("width" to 3840, "height" to 2160)
        val tracks = mapOf("video" to 1, "audio" to 2, "subtitle" to 0)
        val selection = mapOf("video" to 0, "audio" to 1, "subtitle" to -1)
        var snapshot: Map<String, Any?>? = null
        snapshot = androidUpdatedNativeEventSnapshot(
            snapshot,
            mapOf(
                "playerId" to 7L,
                "kind" to ANDROID_VIDEO_PARAMS_CHANGED_EVENT_KIND,
                "video" to video,
                "tracks" to emptyMap<String, Any?>(),
                "positionMicros" to 0L,
            ),
        )
        snapshot = androidUpdatedNativeEventSnapshot(
            snapshot,
            mapOf(
                "playerId" to 7L,
                "kind" to ANDROID_TRACKS_CHANGED_EVENT_KIND,
                "tracks" to tracks,
                "trackList" to listOf(mapOf("id" to 0)),
                "trackSelection" to selection,
                "video" to emptyMap<String, Any?>(),
            ),
        )
        snapshot = androidUpdatedNativeEventSnapshot(
            snapshot,
            mapOf(
                "playerId" to 7L,
                "kind" to ANDROID_SURFACE_ATTACHED_EVENT_KIND,
                "state" to 0,
                "durationMicros" to -1L,
                "positionMicros" to 0L,
                "buffering" to false,
                "video" to emptyMap<String, Any?>(),
                "tracks" to emptyMap<String, Any?>(),
            ),
        )

        assertEquals(video, snapshot["video"])
        assertEquals(tracks, snapshot["tracks"])
        assertEquals(selection, snapshot["trackSelection"])
        assertEquals(false, snapshot.containsKey("state"))
        assertEquals(false, snapshot.containsKey("durationMicros"))
        assertEquals(false, snapshot.containsKey("positionMicros"))
        assertEquals(false, snapshot.containsKey("buffering"))
    }

    @Test
    fun authoritativeStateNeverOvertakesATruncatedEventBatch() {
        assertEquals(true, androidCanSynthesizeAuthoritativeState(eventQueueDrained = true))
        assertEquals(false, androidCanSynthesizeAuthoritativeState(eventQueueDrained = false))
    }

    @Test
    fun queuedStateMatchingAnAlreadyPublishedSnapshotIsDeduplicated() {
        assertEquals(
            true,
            androidStateChangedEventIsDuplicate(
                currentPlaybackState = 3,
                eventPlaybackState = 3,
            ),
        )
        assertEquals(
            false,
            androidStateChangedEventIsDuplicate(
                currentPlaybackState = 2,
                eventPlaybackState = 3,
            ),
        )
        assertEquals(
            false,
            androidStateChangedEventIsDuplicate(
                currentPlaybackState = 3,
                eventPlaybackState = null,
            ),
        )
    }

    @Test
    fun pollFailureDeliveryIsDeduplicatedUntilASuccessfulPoll() {
        val failures = AndroidEventPollFailureDeduplicator()

        assertEquals(
            false,
            failures.shouldReport("response:-1:disconnected", canDeliver = false),
        )
        assertEquals(true, failures.shouldReport("response:-1:disconnected"))
        assertEquals(false, failures.shouldReport("response:-1:disconnected"))
        assertEquals(true, failures.shouldReport("response:-2:closed"))
        assertEquals(false, failures.shouldReport(null))
        assertEquals(true, failures.shouldReport("response:-1:disconnected"))
    }

    @Test
    fun onlySurfaceLifecycleEventsCanCrossAContentBoundary() {
        val generation = 7L
        assertEquals(
            null,
            androidPendingEventContentGeneration(
                ANDROID_SURFACE_ATTACHED_EVENT_KIND,
                generation,
            ),
        )
        assertEquals(
            null,
            androidPendingEventContentGeneration(
                ANDROID_SURFACE_DETACHED_EVENT_KIND,
                generation,
            ),
        )
        assertEquals(
            generation,
            androidPendingEventContentGeneration(ANDROID_POSITION_CHANGED_EVENT_KIND, generation),
        )
        assertEquals(generation, androidPendingEventContentGeneration(null, generation))
    }

    @Test
    fun successfulSurfaceLifecycleOperationsPollImmediately() {
        for (operation in listOf("attachSurface", "detachSurface", "resizeSurface")) {
            assertEquals(
                true,
                androidSurfaceOperationNeedsImmediateEventPoll(operation, responseOk = true),
            )
        }
        assertEquals(
            false,
            androidSurfaceOperationNeedsImmediateEventPoll(
                "setOutputHeadroom",
                responseOk = true,
            ),
        )
        assertEquals(
            false,
            androidSurfaceOperationNeedsImmediateEventPoll(
                "attachSurface",
                responseOk = false,
            ),
        )
    }

    @Test
    fun immediatePollRequestSurvivesAnInFlightPoll() {
        val latch = AndroidImmediateEventPollLatch()

        latch.request(immediate = true)
        assertEquals(false, latch.takeIfReady(pollInFlight = true))
        assertEquals(true, latch.pending)

        assertEquals(true, latch.takeIfReady(pollInFlight = false))
        assertEquals(false, latch.pending)
        assertEquals(false, latch.takeIfReady(pollInFlight = false))
    }

    @Test
    fun delayedRequestsDoNotArmTheImmediatePollLatch() {
        val latch = AndroidImmediateEventPollLatch()
        latch.request(immediate = false)
        assertEquals(false, latch.pending)
        assertEquals(false, latch.takeIfReady(pollInFlight = false))
    }

    @Test
    fun onlyTheCurrentCommandGenerationMayApplyPlaybackState() {
        assertEquals(true, androidEventBatchAcceptsPlaybackState(7L, 7L))
        assertEquals(false, androidEventBatchAcceptsPlaybackState(6L, 7L))
        assertEquals(false, androidEventBatchAcceptsPlaybackState(8L, 7L))
    }

    @Test
    fun onlyTheExecutedCurrentContentMayDeliverMediaEvents() {
        assertEquals(true, androidEventBatchAcceptsContent(2L, 2L))
        assertEquals(false, androidEventBatchAcceptsContent(1L, 2L))
        assertEquals(false, androidEventBatchAcceptsContent(3L, 2L))
    }

    @Test
    fun stalePlaybackBatchesDropOnlyStateChangesAndKeepOtherEvents() {
        assertEquals(
            false,
            androidEventShouldBeDelivered(
                eventKind = 1,
                stateChangedEventKind = 1,
                acceptsContent = true,
                acceptsPlaybackState = false,
                pendingPlayTransition = false,
            ),
        )
        for (eventKind in listOf(3, 7, 9)) {
            assertEquals(
                true,
                androidEventShouldBeDelivered(
                    eventKind = eventKind,
                    stateChangedEventKind = 1,
                    acceptsContent = true,
                    acceptsPlaybackState = false,
                    pendingPlayTransition = false,
                ),
            )
        }
    }

    @Test
    fun staleContentBatchesDropMediaEventsButKeepSurfaceLifecycle() {
        for (eventKind in listOf(null, 1, 3, 9)) {
            assertEquals(
                false,
                androidEventShouldBeDelivered(
                    eventKind = eventKind,
                    stateChangedEventKind = 1,
                    acceptsContent = false,
                    acceptsPlaybackState = true,
                    pendingPlayTransition = false,
                ),
            )
        }
        for (eventKind in listOf(
            ANDROID_SURFACE_ATTACHED_EVENT_KIND,
            ANDROID_SURFACE_DETACHED_EVENT_KIND,
        )) {
            assertEquals(
                true,
                androidEventShouldBeDelivered(
                    eventKind = eventKind,
                    stateChangedEventKind = 1,
                    acceptsContent = false,
                    acceptsPlaybackState = false,
                    pendingPlayTransition = false,
                ),
            )
        }
    }

    @Test
    fun contentGenerationChangesAtRequestAndAcknowledgesExecutionMonotonically() {
        val tracker = AndroidContentGenerationTracker()
        val first = tracker.requestNewContent()
        val second = tracker.requestNewContent()

        assertEquals(2L, tracker.currentGeneration)
        assertEquals(0L, tracker.latestExecutedGeneration)

        tracker.markExecuted(second)
        tracker.markExecuted(first)
        assertEquals(2L, tracker.latestExecutedGeneration)
    }

    @Test
    fun callbackFailureRollsBackOnlyTheAcceptedPlayThatStillOwnsIntent() {
        assertEquals(
            true,
            androidAsyncPlayCallbackNeedsRollback(
                nativePlayAccepted = true,
                isCurrentHost = true,
                ownsCurrentIntent = true,
            ),
        )
        assertEquals(
            false,
            androidAsyncPlayCallbackNeedsRollback(
                nativePlayAccepted = false,
                isCurrentHost = true,
                ownsCurrentIntent = true,
            ),
        )
        assertEquals(
            false,
            androidAsyncPlayCallbackNeedsRollback(
                nativePlayAccepted = true,
                isCurrentHost = false,
                ownsCurrentIntent = true,
            ),
        )
        assertEquals(
            false,
            androidAsyncPlayCallbackNeedsRollback(
                nativePlayAccepted = true,
                isCurrentHost = true,
                ownsCurrentIntent = false,
            ),
        )
    }

    @Test
    fun failedCurrentContentOpenClosesButSupersededOrDestroyedOpenDoesNot() {
        assertEquals(true, androidFailedContentOpenShouldClose("open", false, 3L, 3L))
        assertEquals(false, androidFailedContentOpenShouldClose("open", false, 2L, 3L))
        assertEquals(false, androidFailedContentOpenShouldClose("open", true, 3L, 3L))
        assertEquals(false, androidFailedContentOpenShouldClose("stop", false, 3L, 3L))
        assertEquals(false, androidFailedContentOpenShouldClose("open", false, null, 3L))
    }

    @Test
    fun contentBoundaryMarkerDefersOnlyFailedOrUndecodedOpen() {
        assertEquals(true, androidContentCommandEstablishedBoundary("open", true, true))
        assertEquals(false, androidContentCommandEstablishedBoundary("open", true, false))
        assertEquals(false, androidContentCommandEstablishedBoundary("open", false, false))
        assertEquals(true, androidContentCommandEstablishedBoundary("stop", true, false))
        assertEquals(true, androidContentCommandEstablishedBoundary("close", true, false))
    }

    @Test
    fun queuedPlayKeepsTransientActualStateFromCancellingIntent() {
        for (actualState in listOf(2, 4, 5)) {
            assertEquals(
                true,
                androidPlaybackStateIsPendingPlayTransition(
                    playbackState = actualState,
                    playbackIntentState = 3,
                    playingState = 3,
                ),
            )
        }
        assertEquals(
            false,
            androidPlaybackStateIsPendingPlayTransition(
                playbackState = 3,
                playbackIntentState = 3,
                playingState = 3,
            ),
        )
        assertEquals(
            false,
            androidPlaybackStateIsPendingPlayTransition(
                playbackState = 4,
                playbackIntentState = 4,
                playingState = 3,
            ),
        )
    }

    @Test
    fun queuedPlayKeepsMediaSessionPlayingUntilNativeCommitOrFailure() {
        assertEquals(
            3,
            androidMediaSessionPlaybackState(
                playbackState = 4,
                playbackIntentState = 3,
                playingState = 3,
                acceptsPlaybackState = true,
            ),
        )
        assertEquals(
            4,
            androidMediaSessionPlaybackState(
                playbackState = 4,
                playbackIntentState = 4,
                playingState = 3,
                acceptsPlaybackState = true,
            ),
        )
        assertEquals(
            4,
            androidMediaSessionPlaybackState(
                playbackState = 4,
                playbackIntentState = 3,
                playingState = 3,
                acceptsPlaybackState = false,
            ),
        )
    }

}
