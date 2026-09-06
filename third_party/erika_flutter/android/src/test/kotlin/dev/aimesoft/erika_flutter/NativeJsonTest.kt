package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class NativeJsonTest {
    @Test
    fun optionalEventTreatsJniNullAsNoEvent() {
        assertNull(NativeJson.decodeOptionalEventResponse(null))
    }

    @Test
    fun optionalEventTreatsSuccessfulNullPayloadAsNoEvent() {
        assertNull(
            NativeJson.decodeOptionalEventResponse(
                """{"ok":true,"status":0,"value":null}""",
            ),
        )
    }

    @Test
    fun optionalEventPreservesEventsAndErrors() {
        val event = NativeJson.decodeOptionalEventResponse(
            """{"ok":true,"status":0,"value":{"kind":3,"positionMicros":42}}""",
        )
        val eventValue = event?.value as Map<*, *>
        assertEquals(3, (eventValue["kind"] as Number).toInt())
        assertEquals(42L, (eventValue["positionMicros"] as Number).toLong())

        val error = NativeJson.decodeOptionalEventResponse(
            """{"ok":false,"status":7,"error":"poll failed","value":null}""",
        )
        assertFalse(error?.ok ?: true)
        assertEquals(7, error?.status)
        assertEquals("poll failed", error?.error)
    }
}
