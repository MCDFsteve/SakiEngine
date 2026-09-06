package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidNativeEventStateTest {
    @Test
    fun `position event cannot overwrite end of stream state`() {
        var latestState: Int? = null

        latestState = updatedPlaybackState(
            latestState,
            mapOf("kind" to STATE_CHANGED_EVENT_KIND, "state" to 5),
        )
        latestState = updatedPlaybackState(
            latestState,
            mapOf("kind" to 3, "state" to 0),
        )

        assertEquals(5, latestState)
    }

    @Test
    fun `only state changed events establish playback state`() {
        assertNull(updatedPlaybackState(null, mapOf("kind" to 3, "state" to 3)))
        assertNull(updatedPlaybackState(null, mapOf("kind" to 9, "state" to 7)))
        assertEquals(
            3,
            updatedPlaybackState(
                null,
                mapOf("kind" to STATE_CHANGED_EVENT_KIND, "state" to 3),
            ),
        )
    }
}
