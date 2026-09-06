package dev.aimesoft.erika_flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPresenterThreadPolicyTest {
    @Test
    fun `Android main thread must never synchronously wait for presenter work`() {
        assertTrue(
            androidPresenterCallMustBeAsync(
                isOwnerThread = false,
                isAndroidMainThread = true,
            ),
        )
        assertFalse(
            androidPresenterCallMustBeAsync(
                isOwnerThread = true,
                isAndroidMainThread = true,
            ),
        )
        assertFalse(
            androidPresenterCallMustBeAsync(
                isOwnerThread = false,
                isAndroidMainThread = false,
            ),
        )
    }

    @Test
    fun `presenter task boundary catches linkage errors`() {
        val result = androidPresenterTaskResult {
            throw UnsatisfiedLinkError("missing native symbol")
        }

        assertTrue(result.exceptionOrNull() is UnsatisfiedLinkError)
    }
}
