package dev.aimesoft.erika_flutter

internal data class AndroidPendingPresenterCreate<T : Any>(
    val handle: Long,
    val owner: T,
    val generation: Long,
)

/**
 * Serializes native presenter creation with Flutter-engine attachment changes.
 *
 * Native handles are registered here on their owner thread before completion is
 * posted to Android's main looper. Engine detach retires every unclaimed handle
 * before closing that owner thread, so a late completion can never publish a
 * handle owned by a previous attachment.
 */
internal class AndroidPresenterCreateRegistry<T : Any> {
    private var generation = 0L
    private var currentOwner: T? = null
    private val pending = linkedMapOf<Long, AndroidPendingPresenterCreate<T>>()

    @Synchronized
    fun attach(owner: T): Long {
        generation = generation.saturatingIncrement()
        currentOwner = owner
        return generation
    }

    @Synchronized
    fun registerIfCurrent(handle: Long, owner: T, attachmentGeneration: Long): Boolean {
        if (currentOwner !== owner || generation != attachmentGeneration) {
            return false
        }
        pending[handle] = AndroidPendingPresenterCreate(handle, owner, attachmentGeneration)
        return true
    }

    @Synchronized
    fun claimIfCurrent(handle: Long, owner: T, attachmentGeneration: Long): Boolean {
        val entry = pending[handle] ?: return false
        if (
            entry.owner !== owner ||
            entry.generation != attachmentGeneration ||
            currentOwner !== owner ||
            generation != attachmentGeneration
        ) {
            return false
        }
        pending.remove(handle)
        return true
    }

    @Synchronized
    fun abandon(handle: Long, owner: T): Boolean {
        val entry = pending[handle] ?: return false
        if (entry.owner !== owner) {
            return false
        }
        pending.remove(handle)
        return true
    }

    @Synchronized
    fun detach(owner: T): List<AndroidPendingPresenterCreate<T>> {
        if (currentOwner === owner) {
            generation = generation.saturatingIncrement()
            currentOwner = null
        }
        val retired = pending.values.filter { it.owner === owner }
        retired.forEach { pending.remove(it.handle) }
        return retired
    }

    @Synchronized
    fun isCurrent(owner: T, attachmentGeneration: Long): Boolean =
        currentOwner === owner && generation == attachmentGeneration
}

private fun Long.saturatingIncrement(): Long = if (this == Long.MAX_VALUE) 1L else this + 1L
