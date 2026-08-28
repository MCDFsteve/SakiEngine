package dev.aimesoft.erika_flutter

internal const val STATE_CHANGED_EVENT_KIND = 1

/**
 * Retains the latest authoritative playback state while draining native events.
 *
 * Every native event includes a state field for its payload schema, but only a
 * StateChanged event represents a playback transition. PositionChanged and
 * other events may carry the schema default and must not overwrite EOS/closed.
 */
internal fun updatedPlaybackState(
    latestPlaybackState: Int?,
    event: Map<*, *>,
): Int? {
    if ((event["kind"] as? Number)?.toInt() != STATE_CHANGED_EVENT_KIND) {
        return latestPlaybackState
    }
    return (event["state"] as? Number)?.toInt() ?: latestPlaybackState
}
