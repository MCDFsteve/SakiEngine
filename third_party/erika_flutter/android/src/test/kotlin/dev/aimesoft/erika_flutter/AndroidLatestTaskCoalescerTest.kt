package dev.aimesoft.erika_flutter

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidLatestTaskCoalescerTest {
    @Test
    fun replacesQueuedWorkWithTheLatestTask() {
        val coalescer = AndroidLatestTaskCoalescer<Int>()

        assertTrue(coalescer.submit(1))
        assertFalse(coalescer.submit(2))
        assertFalse(coalescer.submit(3))
        assertEquals(3, coalescer.takeLatest())
        assertNull(coalescer.takeLatest())
        assertFalse(coalescer.finishDrain())
    }

    @Test
    fun schedulesAgainAfterDrainCompletion() {
        val coalescer = AndroidLatestTaskCoalescer<Int>()

        assertTrue(coalescer.submit(1))
        assertEquals(1, coalescer.takeLatest())
        assertFalse(coalescer.finishDrain())
        assertTrue(coalescer.submit(2))
        assertEquals(2, coalescer.takeLatest())
    }

    @Test
    fun workArrivingDuringDrainRequestsAQueuedFollowUp() {
        val coalescer = AndroidLatestTaskCoalescer<Int>()

        assertTrue(coalescer.submit(1))
        assertEquals(1, coalescer.takeLatest())
        assertFalse(coalescer.submit(2))
        assertTrue(coalescer.finishDrain())
        assertEquals(2, coalescer.takeLatest())
        assertFalse(coalescer.finishDrain())
    }

    @Test
    fun concurrentArrivalAndDrainCompletionNeverLoseTheWakeup() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            repeat(1_000) {
                val coalescer = AndroidLatestTaskCoalescer<Int>()
                assertTrue(coalescer.submit(1))
                assertEquals(1, coalescer.takeLatest())
                val start = CountDownLatch(1)
                val submitScheduled = AtomicBoolean(false)
                val drainContinues = AtomicBoolean(false)
                val submit = executor.submit {
                    start.await()
                    submitScheduled.set(coalescer.submit(2))
                }
                val finish = executor.submit {
                    start.await()
                    drainContinues.set(coalescer.finishDrain())
                }

                start.countDown()
                submit.get()
                finish.get()

                assertTrue(submitScheduled.get() xor drainContinues.get())
                assertEquals(2, coalescer.takeLatest())
                assertFalse(coalescer.finishDrain())
            }
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun cancellationDropsOnlyPendingWork() {
        val coalescer = AndroidLatestTaskCoalescer<Int>()

        assertTrue(coalescer.submit(1))
        coalescer.cancelPending()
        assertNull(coalescer.takeLatest())
        assertFalse(coalescer.finishDrain())
    }

    @Test
    fun abortedDrainCanBeScheduledAgain() {
        val coalescer = AndroidLatestTaskCoalescer<Int>()

        assertTrue(coalescer.submit(1))
        coalescer.abortDrain()

        assertNull(coalescer.takeLatest())
        assertTrue(coalescer.submit(2))
        assertEquals(2, coalescer.takeLatest())
    }
}
