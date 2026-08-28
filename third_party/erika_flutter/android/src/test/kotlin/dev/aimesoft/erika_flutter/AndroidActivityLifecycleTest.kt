package dev.aimesoft.erika_flutter

import androidx.lifecycle.Lifecycle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidActivityLifecycleTest {
    @Test
    fun `only started and resumed lifecycle states are active`() {
        assertFalse(androidActivityIsActive(Lifecycle.State.DESTROYED))
        assertFalse(androidActivityIsActive(Lifecycle.State.INITIALIZED))
        assertFalse(androidActivityIsActive(Lifecycle.State.CREATED))
        assertTrue(androidActivityIsActive(Lifecycle.State.STARTED))
        assertTrue(androidActivityIsActive(Lifecycle.State.RESUMED))
    }

    @Test
    fun `start stop and destroy events drive activity state`() {
        assertEquals(true, androidActivityActiveForEvent(Lifecycle.Event.ON_START))
        assertEquals(false, androidActivityActiveForEvent(Lifecycle.Event.ON_STOP))
        assertEquals(false, androidActivityActiveForEvent(Lifecycle.Event.ON_DESTROY))
        assertNull(androidActivityActiveForEvent(Lifecycle.Event.ON_RESUME))
        assertNull(androidActivityActiveForEvent(Lifecycle.Event.ON_PAUSE))
    }
}
