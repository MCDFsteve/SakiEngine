package dev.aimesoft.erika_flutter

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Keeps at most the newest task while one serial drain is active. */
internal class AndroidLatestTaskCoalescer<T : Any> {
    private val latest = AtomicReference<T?>(null)
    private val drainScheduled = AtomicBoolean(false)

    /** Returns true when the caller must schedule a new drain. */
    fun submit(value: T): Boolean {
        latest.set(value)
        return drainScheduled.compareAndSet(false, true)
    }

    fun takeLatest(): T? = latest.getAndSet(null)

    /**
     * Ends one drain. Returns true when a task raced with drain completion and
     * the current serial worker should immediately continue draining.
     */
    fun finishDrain(): Boolean {
        drainScheduled.set(false)
        return latest.get() != null && drainScheduled.compareAndSet(false, true)
    }

    fun cancelPending() {
        latest.set(null)
    }

    /** Drops pending work and releases a drain that could not be scheduled. */
    fun abortDrain() {
        latest.set(null)
        drainScheduled.set(false)
    }
}
