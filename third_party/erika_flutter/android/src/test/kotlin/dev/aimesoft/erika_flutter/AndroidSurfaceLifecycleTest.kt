package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidSurfaceLifecycleTest {
    @Test
    fun `activity stop retains only a live texture surface`() {
        assertTrue(
            androidShouldRetainSurfaceDuringActivityStop(
                usesTextureView = true,
                outputSurfaceValid = true,
            ),
        )
        assertFalse(
            androidShouldRetainSurfaceDuringActivityStop(
                usesTextureView = true,
                outputSurfaceValid = false,
            ),
        )
        assertFalse(
            androidShouldRetainSurfaceDuringActivityStop(
                usesTextureView = false,
                outputSurfaceValid = true,
            ),
        )
    }

    @Test
    fun `failed native detach retains texture ownership and schedules retry`() {
        val decision = androidSurfaceDestroyDecision(nativeDetachSucceeded = false)

        assertFalse(decision.releaseSurfaceTexture)
        assertTrue(decision.retryNativeDetach)
    }

    @Test
    fun `successful native detach needs no retry`() {
        val decision = androidSurfaceDestroyDecision(nativeDetachSucceeded = true)

        assertFalse(decision.releaseSurfaceTexture)
        assertFalse(decision.retryNativeDetach)
    }

    @Test
    fun `failed detach keeps recovery state until native destroy owns retirement`() {
        assertTrue(
            androidSurfaceDestroyNeedsRetry(
                nativeDetachSucceeded = false,
                hostDestroying = false,
            ),
        )
        assertFalse(
            androidSurfaceDestroyNeedsRetry(
                nativeDetachSucceeded = true,
                hostDestroying = false,
            ),
        )
        assertFalse(
            androidSurfaceDestroyNeedsRetry(
                nativeDetachSucceeded = false,
                hostDestroying = true,
            ),
        )
    }

    @Test
    fun `surface recovery uses bounded exponential backoff`() {
        val delays = (1..ANDROID_SURFACE_RECOVERY_MAX_RETRIES)
            .map(::androidSurfaceRecoveryDelayMillis)

        assertEquals(listOf(16L, 32L, 64L, 128L, 256L, 512L), delays)
        assertNull(androidSurfaceRecoveryDelayMillis(0))
        assertNull(
            androidSurfaceRecoveryDelayMillis(ANDROID_SURFACE_RECOVERY_MAX_RETRIES + 1),
        )
    }

    @Test
    fun `surface recovery counts actual failures within one operation`() {
        val attempts = AndroidSurfaceRecoveryAttemptTracker()

        val recorded = (1..ANDROID_SURFACE_RECOVERY_MAX_RETRIES + 1).map {
            attempts.recordFailure(4L, "attachSurface")
        }
        assertEquals((1..7).toList(), recorded)
        assertEquals(
            listOf(16L, 32L, 64L, 128L, 256L, 512L, null),
            recorded.map(::androidSurfaceRecoveryDelayMillis),
        )
        assertTrue(attempts.markExhaustionReported(4L, "attachSurface"))
        assertFalse(attempts.markExhaustionReported(4L, "attachSurface"))
        assertTrue(attempts.complete(4L, "attachSurface"))
        assertFalse(attempts.complete(4L, "attachSurface"))
        assertEquals(1, attempts.recordFailure(4L, "attachSurface"))
    }

    @Test
    fun `new surface generation or operation gets a fresh recovery budget`() {
        val attempts = AndroidSurfaceRecoveryAttemptTracker()

        assertEquals(1, attempts.recordFailure(4L, "attachSurface"))
        assertEquals(2, attempts.recordFailure(4L, "attachSurface"))
        assertEquals(1, attempts.recordFailure(4L, "resizeSurface"))
        assertEquals(1, attempts.recordFailure(5L, "resizeSurface"))
    }

    @Test
    fun `invalidating recovery token rejects stale callbacks`() {
        val tokens = AndroidSurfaceRecoveryTokenSource()
        val initial = tokens.currentToken

        assertTrue(tokens.isCurrent(initial))
        tokens.invalidate()
        assertFalse(tokens.isCurrent(initial))

        val replacement = tokens.currentToken
        assertTrue(tokens.isCurrent(replacement))
        tokens.invalidate()
        assertFalse(tokens.isCurrent(replacement))
    }

    @Test
    fun `binding generation rejects a retired surface callback`() {
        val generations = AndroidSurfaceBindingGenerationTracker()
        val firstSurface = generations.advance()

        assertTrue(generations.isCurrent(firstSurface))
        val replacementSurface = generations.advance()

        assertFalse(generations.isCurrent(firstSurface))
        assertTrue(generations.isCurrent(replacementSurface))
    }

    @Test
    fun `stale resize callback cannot recover a replacement surface`() {
        assertTrue(
            androidSurfaceCallbackIsCurrent(
                callbackGeneration = 7L,
                currentGeneration = 7L,
                hostStillBound = true,
                surfaceStillCurrent = true,
            ),
        )
        assertFalse(
            androidSurfaceCallbackIsCurrent(
                callbackGeneration = 7L,
                currentGeneration = 8L,
                hostStillBound = true,
                surfaceStillCurrent = true,
            ),
        )
        assertFalse(
            androidSurfaceCallbackIsCurrent(
                callbackGeneration = 7L,
                currentGeneration = 7L,
                hostStillBound = true,
                surfaceStillCurrent = false,
            ),
        )
    }

    @Test
    fun `physical detach settles unbind waiters across a rebind generation`() {
        assertTrue(
            androidSurfaceCompletionMatchesGeneration(
                completionGeneration = 4L,
                callbackGeneration = null,
            ),
        )
        assertFalse(
            androidSurfaceCompletionMatchesGeneration(
                completionGeneration = 4L,
                callbackGeneration = 5L,
            ),
        )
    }

    @Test
    fun `queued surface dispatch has no reportable native result`() {
        assertTrue(
            androidSurfaceOperationIsPending(
                operation = "attachSurface",
                nativeAttachPending = true,
                nativeDetachPending = false,
                nativeResizePending = false,
            ),
        )
        assertTrue(
            androidSurfaceOperationIsPending(
                operation = "detachSurface",
                nativeAttachPending = false,
                nativeDetachPending = true,
                nativeResizePending = false,
            ),
        )
        assertTrue(
            androidSurfaceOperationIsPending(
                operation = "resizeSurface",
                nativeAttachPending = false,
                nativeDetachPending = false,
                nativeResizePending = true,
            ),
        )
        assertFalse(
            androidSurfaceOperationIsPending(
                operation = "attachSurface",
                nativeAttachPending = false,
                nativeDetachPending = false,
                nativeResizePending = false,
            ),
        )
    }

    @Test
    fun `unbind waits for an in flight lifecycle detach`() {
        assertFalse(androidUnbindNeedsNewSurfaceDetach(lifecycleDetachPending = true))
        assertTrue(androidUnbindNeedsNewSurfaceDetach(lifecycleDetachPending = false))
    }

    @Test
    fun `successful attached recovery resumes hdr headroom observation`() {
        assertTrue(
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = true,
                surfaceAttached = true,
                disposed = false,
                disposeRequested = false,
                unbindRequested = false,
            ),
        )
    }

    @Test
    fun `recovery does not resume hdr observation without a live attached binding`() {
        val inactiveStates = listOf(
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = false,
                surfaceAttached = true,
                disposed = false,
                disposeRequested = false,
                unbindRequested = false,
            ),
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = true,
                surfaceAttached = false,
                disposed = false,
                disposeRequested = false,
                unbindRequested = false,
            ),
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = true,
                surfaceAttached = true,
                disposed = true,
                disposeRequested = false,
                unbindRequested = false,
            ),
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = true,
                surfaceAttached = true,
                disposed = false,
                disposeRequested = true,
                unbindRequested = false,
            ),
            androidShouldRefreshHdrHeadroomAfterRecovery(
                hostStillBound = true,
                surfaceAttached = true,
                disposed = false,
                disposeRequested = false,
                unbindRequested = true,
            ),
        )

        assertTrue(inactiveStates.all { shouldRefresh -> !shouldRefresh })
    }

    @Test
    fun `pending view bind resumes only for a live host and target`() {
        assertTrue(
            androidShouldResumePendingViewBind(
                hostDestroyed = false,
                targetDisposed = false,
                targetDisposeRequested = false,
                targetAcceptsHost = true,
                hostAcceptsTarget = true,
            ),
        )
        assertFalse(
            androidShouldResumePendingViewBind(
                hostDestroyed = true,
                targetDisposed = false,
                targetDisposeRequested = false,
                targetAcceptsHost = true,
                hostAcceptsTarget = true,
            ),
        )
        assertFalse(
            androidShouldResumePendingViewBind(
                hostDestroyed = false,
                targetDisposed = true,
                targetDisposeRequested = false,
                targetAcceptsHost = true,
                hostAcceptsTarget = true,
            ),
        )
        assertFalse(
            androidShouldResumePendingViewBind(
                hostDestroyed = false,
                targetDisposed = false,
                targetDisposeRequested = true,
                targetAcceptsHost = true,
                hostAcceptsTarget = true,
            ),
        )
        assertFalse(
            androidShouldResumePendingViewBind(
                hostDestroyed = false,
                targetDisposed = false,
                targetDisposeRequested = false,
                targetAcceptsHost = false,
                hostAcceptsTarget = true,
            ),
        )
        assertFalse(
            androidShouldResumePendingViewBind(
                hostDestroyed = false,
                targetDisposed = false,
                targetDisposeRequested = false,
                targetAcceptsHost = true,
                hostAcceptsTarget = false,
            ),
        )
    }

    @Test
    fun `successful detach completes an unbind superseded by rebind`() {
        assertTrue(
            androidDetachCompletesSupersededUnbind(
                nativeDetachSucceeded = true,
                unbindRequested = false,
                disposeRequested = false,
            ),
        )
        assertFalse(
            androidDetachCompletesSupersededUnbind(
                nativeDetachSucceeded = false,
                unbindRequested = false,
                disposeRequested = false,
            ),
        )
        assertFalse(
            androidDetachCompletesSupersededUnbind(
                nativeDetachSucceeded = true,
                unbindRequested = true,
                disposeRequested = false,
            ),
        )
        assertFalse(
            androidDetachCompletesSupersededUnbind(
                nativeDetachSucceeded = true,
                unbindRequested = false,
                disposeRequested = true,
            ),
        )
    }

    @Test
    fun `exhausted detach recovery retires host before releasing buffers`() {
        assertTrue(
            androidSurfaceRecoveryExhaustionRequiresHostRetirement(
                failedOperation = "detachSurface",
                nativeDetachRetryPending = true,
                unbindRequested = false,
                disposeRequested = false,
            ),
        )
        assertTrue(
            androidSurfaceRecoveryExhaustionRequiresHostRetirement(
                failedOperation = "detachSurface",
                nativeDetachRetryPending = false,
                unbindRequested = true,
                disposeRequested = false,
            ),
        )
        assertFalse(
            androidSurfaceRecoveryExhaustionRequiresHostRetirement(
                failedOperation = "attachSurface",
                nativeDetachRetryPending = true,
                unbindRequested = true,
                disposeRequested = true,
            ),
        )
    }
}
