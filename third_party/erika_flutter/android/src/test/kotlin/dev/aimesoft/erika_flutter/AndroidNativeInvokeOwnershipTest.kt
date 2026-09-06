package dev.aimesoft.erika_flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidNativeInvokeOwnershipTest {
    @Test
    fun `destroy race and missing symbol leave detached fd with Kotlin`() {
        assertTrue(androidNativeInvokeDidNotStart(AndroidPlayerDestroyedException(1L)))
        assertTrue(androidNativeInvokeDidNotStart(UnsatisfiedLinkError("missing")))
    }

    @Test
    fun `post-dispatch decode errors leave detached fd with Rust`() {
        assertFalse(androidNativeInvokeDidNotStart(IllegalArgumentException("bad JSON")))
        assertFalse(androidNativeInvokeDidNotStart(IllegalStateException("native response")))
    }
}
