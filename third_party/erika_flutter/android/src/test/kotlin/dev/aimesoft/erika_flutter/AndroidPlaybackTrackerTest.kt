package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPlaybackTrackerTest {
    @Test
    fun `explicit pause cancels delayed playback intent`() {
        val tracker = AndroidPlaybackTracker()

        tracker.requestPlayback()
        assertEquals(AndroidPlaybackPhase.PENDING, tracker.phase)

        tracker.cancelPlaybackIntent()

        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)
        assertFalse(tracker.playbackStarted())
        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)
    }

    @Test
    fun `lifecycle stop preserves resumable playback intent`() {
        val tracker = AndroidPlaybackTracker()
        tracker.requestPlayback()
        assertTrue(tracker.playbackStarted())

        assertTrue(tracker.suspendPlayback())
        assertEquals(AndroidPlaybackPhase.PENDING, tracker.phase)

        assertTrue(tracker.playbackStarted())
        assertEquals(AndroidPlaybackPhase.PLAYING, tracker.phase)
    }

    @Test
    fun `foreground lifecycle cancellation stays paused until an explicit new play`() {
        val tracker = AndroidPlaybackTracker()
        tracker.requestPlayback()
        assertTrue(tracker.playbackStarted())

        assertTrue(tracker.cancelPlaybackIntent())
        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)
        assertFalse(tracker.playbackStarted())

        tracker.requestPlayback()
        assertEquals(AndroidPlaybackPhase.PENDING, tracker.phase)
        assertTrue(tracker.playbackStarted())
    }

    @Test
    fun `explicit stop or close cancels pending playback`() {
        val tracker = AndroidPlaybackTracker()

        tracker.requestPlayback()
        assertFalse(tracker.cancelPlaybackIntent())
        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)

        tracker.requestPlayback()
        assertFalse(tracker.cancelPlaybackIntent())
        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)
    }

    @Test
    fun `explicit native cancellation advances generation even while already paused`() {
        val tracker = AndroidPlaybackTracker()
        val initialGeneration = tracker.currentPlaybackIntentGeneration

        assertFalse(tracker.cancelPlaybackIntent(forceNewGeneration = true))

        assertNotEquals(initialGeneration, tracker.currentPlaybackIntentGeneration)
    }

    @Test
    fun `native terminal state reconciles without advancing command generation`() {
        val tracker = AndroidPlaybackTracker()
        tracker.requestPlayback()
        tracker.playbackStarted()
        val playingGeneration = tracker.currentPlaybackIntentGeneration

        tracker.reconcileNativePlaybackStopped()

        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)
        assertEquals(playingGeneration, tracker.currentPlaybackIntentGeneration)
    }

    @Test
    fun `transient focus loss is resumable but permanent loss is not`() {
        val tracker = AndroidPlaybackTracker()
        tracker.requestPlayback()
        tracker.playbackStarted()

        assertTrue(tracker.handleFocusLoss(mayResume = true))
        assertEquals(AndroidPlaybackPhase.PENDING, tracker.phase)
        assertTrue(tracker.playbackStarted())

        assertTrue(tracker.handleFocusLoss(mayResume = false))
        assertEquals(AndroidPlaybackPhase.PAUSED, tracker.phase)
        assertFalse(tracker.playbackStarted())
    }

    @Test
    fun `focus gain renews pending intent so an older pause cannot own state`() {
        val tracker = AndroidPlaybackTracker()
        tracker.requestPlayback()
        assertTrue(tracker.playbackStarted())

        assertTrue(tracker.handleFocusLoss(mayResume = true))
        val pauseGeneration = tracker.currentPlaybackIntentGeneration
        val resumedGeneration = tracker.renewPendingPlaybackIntent()

        assertNotEquals(pauseGeneration, resumedGeneration)
        assertEquals(resumedGeneration, tracker.tryBeginPlayInvocation())
        assertTrue(tracker.finishPlayInvocation(checkNotNull(resumedGeneration)))
    }

    @Test
    fun `ticking supports headless playback and surface render requests`() {
        val tracker = AndroidPlaybackTracker()

        assertFalse(tracker.shouldTick)
        tracker.requestRender()
        assertFalse(tracker.shouldTick)

        tracker.attachSurface()
        assertTrue(tracker.shouldTick)
        tracker.markRenderAttempted(tracker.currentRenderRequestGeneration)
        assertFalse(tracker.shouldTick)

        tracker.requestPlayback()
        assertFalse(tracker.shouldTick)
        tracker.playbackStarted()
        assertTrue(tracker.shouldTick)
        tracker.markRenderAttempted(tracker.currentRenderRequestGeneration)
        assertTrue(tracker.shouldTick)

        tracker.suspendPlayback()
        assertFalse(tracker.shouldTick)
        tracker.requestRender()
        assertTrue(tracker.shouldTick)
        tracker.detachSurface()
        assertFalse(tracker.shouldTick)

        tracker.requestPlayback()
        tracker.playbackStarted()
        assertTrue(tracker.shouldTick)
    }

    @Test
    fun `players keep independent playback and render state`() {
        val first = AndroidPlaybackTracker()
        val second = AndroidPlaybackTracker()

        first.attachSurface()
        first.markRenderAttempted(first.currentRenderRequestGeneration)
        first.requestPlayback()
        first.playbackStarted()

        second.attachSurface()
        second.markRenderAttempted(second.currentRenderRequestGeneration)
        second.requestPlayback()
        second.playbackStarted()

        assertEquals(AndroidPlaybackPhase.PLAYING, first.phase)
        assertTrue(first.shouldTick)
        assertEquals(AndroidPlaybackPhase.PLAYING, second.phase)
        assertTrue(second.shouldTick)

        first.cancelPlaybackIntent()
        assertEquals(AndroidPlaybackPhase.PAUSED, first.phase)
        assertEquals(AndroidPlaybackPhase.PLAYING, second.phase)
        assertTrue(second.shouldTick)
    }

    @Test
    fun `old render completion cannot clear a newer request`() {
        val tracker = AndroidPlaybackTracker()
        tracker.attachSurface()
        val firstGeneration = tracker.currentRenderRequestGeneration

        tracker.requestRender()
        tracker.markRenderAttempted(firstGeneration)

        assertTrue(tracker.renderRequested)
        assertTrue(tracker.shouldTick)
        tracker.markRenderAttempted(tracker.currentRenderRequestGeneration)
        assertFalse(tracker.renderRequested)
        assertFalse(tracker.shouldTick)
    }

    @Test
    fun `acknowledging generations is monotonic`() {
        val tracker = AndroidPlaybackTracker()
        tracker.attachSurface()
        val firstGeneration = tracker.currentRenderRequestGeneration
        val secondGeneration = tracker.requestRender()

        tracker.markRenderAttempted(secondGeneration)
        tracker.markRenderAttempted(firstGeneration)

        assertFalse(tracker.renderRequested)
    }

    @Test
    fun `async play completion requires pending intent activity permission and focus`() {
        assertTrue(
            androidAsyncPlayCanStart(
                AndroidPlaybackPhase.PENDING,
                canPlayInCurrentActivityState = true,
                audioFocusGranted = true,
            ),
        )
        assertFalse(
            androidAsyncPlayCanStart(
                AndroidPlaybackPhase.PENDING,
                canPlayInCurrentActivityState = false,
                audioFocusGranted = true,
            ),
        )
        assertFalse(
            androidAsyncPlayCanStart(
                AndroidPlaybackPhase.PENDING,
                canPlayInCurrentActivityState = true,
                audioFocusGranted = false,
            ),
        )
        assertFalse(
            androidAsyncPlayCanStart(
                AndroidPlaybackPhase.PAUSED,
                canPlayInCurrentActivityState = true,
                audioFocusGranted = true,
            ),
        )
    }

    @Test
    fun `only one native play invocation can be in flight`() {
        val tracker = AndroidPlaybackTracker()
        val generation = tracker.requestPlayback()

        assertEquals(generation, tracker.tryBeginPlayInvocation())
        assertNull(tracker.tryBeginPlayInvocation())

        // A transient focus cycle leaves the intent pending but must not submit again.
        assertTrue(tracker.handleFocusLoss(mayResume = true))
        assertEquals(AndroidPlaybackPhase.PENDING, tracker.phase)
        assertNull(tracker.tryBeginPlayInvocation())

        assertFalse(tracker.finishPlayInvocation(generation))
        assertFalse(tracker.finishPlayInvocation(generation))
        val resumedGeneration = tracker.tryBeginPlayInvocation()
        assertNotNull(resumedGeneration)
        assertEquals(tracker.currentPlaybackIntentGeneration, resumedGeneration)
        assertNotEquals(generation, resumedGeneration)
        assertTrue(tracker.finishPlayInvocation(checkNotNull(resumedGeneration)))
    }

    @Test
    fun `play pause play starts the latest generation after the old invocation finishes`() {
        val tracker = AndroidPlaybackTracker()
        val firstGeneration = tracker.requestPlayback()
        assertEquals(firstGeneration, tracker.tryBeginPlayInvocation())

        tracker.cancelPlaybackIntent()
        assertNull(tracker.tryBeginPlayInvocation())
        val latestGeneration = tracker.requestPlayback()
        assertNotEquals(firstGeneration, latestGeneration)
        assertNull(tracker.tryBeginPlayInvocation())

        assertFalse(tracker.finishPlayInvocation(firstGeneration))
        assertEquals(latestGeneration, tracker.tryBeginPlayInvocation())
        assertTrue(tracker.finishPlayInvocation(latestGeneration))
    }

    @Test
    fun `duplicate pending play shares the active intent generation`() {
        val tracker = AndroidPlaybackTracker()
        val firstGeneration = tracker.requestPlayback()
        assertEquals(firstGeneration, tracker.tryBeginPlayInvocation())

        val duplicateGeneration = tracker.requestPlayback()
        assertEquals(firstGeneration, duplicateGeneration)
        assertNull(tracker.tryBeginPlayInvocation())
        assertTrue(tracker.finishPlayInvocation(firstGeneration))
    }

    @Test
    fun `play requested from locally playing state starts a new intent generation`() {
        val tracker = AndroidPlaybackTracker()
        val firstGeneration = tracker.requestPlayback()
        assertTrue(tracker.playbackStarted())

        val replayGeneration = tracker.requestPlayback()

        assertNotEquals(firstGeneration, replayGeneration)
        assertEquals(AndroidPlaybackPhase.PENDING, tracker.phase)
    }

    @Test
    fun `finishing before a main callback failure always clears the invocation`() {
        val tracker = AndroidPlaybackTracker()
        val generation = tracker.requestPlayback()
        assertEquals(generation, tracker.tryBeginPlayInvocation())

        assertTrue(tracker.finishPlayInvocation(generation))

        // The callback may now fail while processing events or updating MediaSession. A
        // retry can still begin because completion released the in-flight slot first.
        assertEquals(generation, tracker.tryBeginPlayInvocation())
    }
}
