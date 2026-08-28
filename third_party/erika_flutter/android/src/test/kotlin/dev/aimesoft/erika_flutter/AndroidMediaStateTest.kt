package dev.aimesoft.erika_flutter

import android.media.session.PlaybackState
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class AndroidMediaStateTest {
    @Test
    fun `metadata accepts supported system media fields`() {
        val artwork = byteArrayOf(1, 2, 3)

        val metadata = androidMediaMetadata(
            mapOf(
                "metadata" to mapOf(
                    "title" to "Episode 1",
                    "artist" to "Erika",
                    "album" to "Season 1",
                    "artwork" to artwork,
                ),
            ),
        )

        assertEquals("Episode 1", metadata.title)
        assertEquals("Erika", metadata.artist)
        assertEquals("Season 1", metadata.album)
        assertArrayEquals(artwork, metadata.artwork)
    }

    @Test
    fun `metadata requires a non blank title`() {
        assertThrows(IllegalArgumentException::class.java) {
            androidMediaMetadata(mapOf("metadata" to mapOf("title" to "  ")))
        }
    }

    @Test
    fun `native media events update only their authoritative fields`() {
        var state = AndroidMediaState(playerId = 7L)
        state = updatedAndroidMediaState(
            state,
            mapOf("kind" to 2, "durationMicros" to 9_000_000L),
        )
        state = updatedAndroidMediaState(
            state,
            mapOf("kind" to 1, "state" to 3, "durationMicros" to -1L),
        )
        state = updatedAndroidMediaState(
            state,
            mapOf("kind" to 3, "positionMicros" to 2_500_000L, "state" to 7),
        )

        assertEquals(3, state.playbackState)
        assertEquals(9_000_000L, state.durationMicros)
        assertEquals(2_500_000L, state.positionMicros)
    }

    @Test
    fun `closed state clears content metadata position and duration`() {
        val state = updatedAndroidMediaState(
            AndroidMediaState(
                playerId = 7L,
                metadata = AndroidMediaMetadata("Episode 1", "Erika", null, null),
                playbackState = 3,
                positionMicros = 2_500_000L,
                durationMicros = 9_000_000L,
            ),
            mapOf("kind" to STATE_CHANGED_EVENT_KIND, "state" to ANDROID_CLOSED_PLAYBACK_STATE),
        )

        assertNull(state.metadata)
        assertEquals(ANDROID_CLOSED_PLAYBACK_STATE, state.playbackState)
        assertEquals(0L, state.positionMicros)
        assertEquals(0L, state.durationMicros)
    }

    @Test
    fun `erika playback states map to Android media session states`() {
        assertEquals(PlaybackState.STATE_PLAYING, 3.toAndroidPlaybackState())
        assertEquals(PlaybackState.STATE_PAUSED, 4.toAndroidPlaybackState())
        assertEquals(PlaybackState.STATE_STOPPED, 5.toAndroidPlaybackState())
        assertEquals(PlaybackState.STATE_NONE, 6.toAndroidPlaybackState())
        assertEquals(PlaybackState.STATE_ERROR, 7.toAndroidPlaybackState())
    }

    @Test
    fun `foreground playback service requires playing background enabled media`() {
        val state = AndroidMediaState(
            playerId = 7L,
            playbackState = ErikaMediaSession.PLAYING_STATE,
            allowBackgroundPlayback = true,
        )

        assertEquals(true, state.shouldUsePlaybackService())
        assertEquals(false, state.copy(playbackState = 4).shouldUsePlaybackService())
        assertEquals(false, state.copy(allowBackgroundPlayback = false).shouldUsePlaybackService())
    }

    @Test
    fun `playback outside an active activity requires background opt in`() {
        val foregroundOnly = AndroidMediaState(playerId = 7L)
        val backgroundAllowed = foregroundOnly.copy(allowBackgroundPlayback = true)

        assertEquals(true, foregroundOnly.canPlay(activityActive = true))
        assertEquals(false, foregroundOnly.canPlay(activityActive = false))
        assertEquals(true, backgroundAllowed.canPlay(activityActive = false))
    }

    @Test
    fun `system media navigation updates capabilities independently`() {
        val state = updatedSystemMediaNavigation(
            AndroidMediaState(playerId = 7L, nextEnabled = true),
            mapOf("previousEnabled" to true, "nextEnabled" to false),
        )

        assertEquals(true, state.previousEnabled)
        assertEquals(false, state.nextEnabled)
    }

    @Test
    fun `system media navigation defaults missing capabilities to disabled`() {
        val state = updatedSystemMediaNavigation(
            AndroidMediaState(playerId = 7L, previousEnabled = true, nextEnabled = true),
            emptyMap(),
        )

        assertEquals(false, state.previousEnabled)
        assertEquals(false, state.nextEnabled)
    }

    @Test
    fun `Android playback actions reflect navigation capabilities`() {
        val base = AndroidMediaState(playerId = 7L)

        assertEquals(0L, base.androidPlaybackActions() and PlaybackState.ACTION_SKIP_TO_PREVIOUS)
        assertEquals(0L, base.androidPlaybackActions() and PlaybackState.ACTION_SKIP_TO_NEXT)
        assertEquals(
            PlaybackState.ACTION_SKIP_TO_PREVIOUS,
            base.copy(previousEnabled = true).androidPlaybackActions() and
                PlaybackState.ACTION_SKIP_TO_PREVIOUS,
        )
        assertEquals(
            PlaybackState.ACTION_SKIP_TO_NEXT,
            base.copy(nextEnabled = true).androidPlaybackActions() and
                PlaybackState.ACTION_SKIP_TO_NEXT,
        )
    }

    @Test
    fun `enabled system media navigation creates kind 13 event`() {
        val state = AndroidMediaState(playerId = 7L, previousEnabled = true)

        assertEquals(
            mapOf(
                "playerId" to 7L,
                "kind" to SYSTEM_MEDIA_NAVIGATION_EVENT_KIND,
                "navigation" to SYSTEM_MEDIA_NAVIGATION_PREVIOUS,
            ),
            systemMediaNavigationEvent(state, SYSTEM_MEDIA_NAVIGATION_PREVIOUS),
        )
        assertNull(systemMediaNavigationEvent(state, SYSTEM_MEDIA_NAVIGATION_NEXT))
        assertNull(systemMediaNavigationEvent(state, "unknown"))
    }
}
