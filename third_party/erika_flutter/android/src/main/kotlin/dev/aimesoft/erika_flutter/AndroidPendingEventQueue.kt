package dev.aimesoft.erika_flutter

internal sealed interface AndroidPendingEvent {
    /** Null marks a presenter/Surface event that may cross an Open boundary. */
    val contentGeneration: Long?

    data class Success(
        val value: Map<String, Any?>,
        override val contentGeneration: Long?,
    ) : AndroidPendingEvent

    data class Error(
        val code: String,
        val message: String,
        val details: Map<String, Any?>,
        override val contentGeneration: Long?,
    ) : AndroidPendingEvent
}

internal data class AndroidPendingEventOverflow(
    val dropped: AndroidPendingEvent,
    val droppedTotal: Long,
    val capacity: Int,
)

/**
 * Per-player FIFO used while Flutter has no active EventChannel listener.
 *
 * The queue deliberately drops the oldest item on overflow. This preserves the
 * most recent playback/error state while keeping memory bounded if Dart stays
 * detached for an extended playback session.
 */
internal class AndroidPendingEventQueue(
    val capacity: Int,
) {
    private val events = ArrayDeque<AndroidPendingEvent>()
    private var droppedTotal = 0L

    init {
        require(capacity > 0) { "Pending event queue capacity must be positive" }
    }

    val size: Int
        get() = events.size

    fun enqueue(event: AndroidPendingEvent): AndroidPendingEventOverflow? {
        val dropped = if (events.size >= capacity) events.removeFirst() else null
        events.addLast(event)
        if (dropped == null) {
            return null
        }
        droppedTotal += 1
        return AndroidPendingEventOverflow(dropped, droppedTotal, capacity)
    }

    fun firstOrNull(): AndroidPendingEvent? = events.firstOrNull()

    fun removeFirst(): AndroidPendingEvent = events.removeFirst()

    fun discardStaleContentEvents(currentContentGeneration: Long): Int {
        val originalSize = events.size
        events.removeAll { event ->
            event.contentGeneration?.let { it != currentContentGeneration } == true
        }
        return originalSize - events.size
    }

    fun clear() {
        events.clear()
    }
}
