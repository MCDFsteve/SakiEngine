package dev.aimesoft.erika_flutter

internal data class AndroidMediaMetadata(
    val title: String,
    val artist: String?,
    val album: String?,
    val artwork: ByteArray?,
)

internal data class AndroidMediaState(
    val playerId: Long,
    val metadata: AndroidMediaMetadata? = null,
    val playbackState: Int = 0,
    val positionMicros: Long = 0L,
    val durationMicros: Long = 0L,
    val playbackRate: Float = 1f,
    val allowBackgroundPlayback: Boolean = false,
    val previousEnabled: Boolean = false,
    val nextEnabled: Boolean = false,
)

internal fun AndroidMediaState.canPlay(activityActive: Boolean): Boolean =
    activityActive || allowBackgroundPlayback

internal fun androidMediaMetadata(arguments: Map<String, Any?>): AndroidMediaMetadata {
    val raw = arguments["metadata"] as? Map<*, *>
        ?: throw IllegalArgumentException("metadata is required")
    val title = (raw["title"] as? String)?.trim().orEmpty()
    require(title.isNotEmpty()) { "metadata.title is required" }
    return AndroidMediaMetadata(
        title = title,
        artist = (raw["artist"] as? String)?.takeIf(String::isNotBlank),
        album = (raw["album"] as? String)?.takeIf(String::isNotBlank),
        artwork = raw["artwork"] as? ByteArray,
    )
}

internal fun updatedSystemMediaNavigation(
    state: AndroidMediaState,
    arguments: Map<String, Any?>,
): AndroidMediaState = state.copy(
    previousEnabled = arguments["previousEnabled"] as? Boolean ?: false,
    nextEnabled = arguments["nextEnabled"] as? Boolean ?: false,
)

internal fun systemMediaNavigationEvent(
    state: AndroidMediaState,
    navigation: String,
): Map<String, Any?>? {
    val enabled = when (navigation) {
        SYSTEM_MEDIA_NAVIGATION_PREVIOUS -> state.previousEnabled
        SYSTEM_MEDIA_NAVIGATION_NEXT -> state.nextEnabled
        else -> false
    }
    if (!enabled) {
        return null
    }
    return linkedMapOf(
        "playerId" to state.playerId,
        "kind" to SYSTEM_MEDIA_NAVIGATION_EVENT_KIND,
        "navigation" to navigation,
    )
}

internal const val SYSTEM_MEDIA_NAVIGATION_EVENT_KIND = 13
internal const val SYSTEM_MEDIA_NAVIGATION_PREVIOUS = "previous"
internal const val SYSTEM_MEDIA_NAVIGATION_NEXT = "next"

internal fun updatedAndroidMediaState(
    state: AndroidMediaState,
    event: Map<*, *>,
): AndroidMediaState {
    val kind = (event["kind"] as? Number)?.toInt()
    val playbackState = if (kind == STATE_CHANGED_EVENT_KIND) {
        (event["state"] as? Number)?.toInt() ?: state.playbackState
    } else {
        state.playbackState
    }
    if (kind == STATE_CHANGED_EVENT_KIND && playbackState == ANDROID_CLOSED_PLAYBACK_STATE) {
        return closedAndroidMediaState(state, playbackState)
    }
    return state.copy(
        playbackState = playbackState,
        positionMicros = if (kind == 3) {
            ((event["positionMicros"] as? Number)?.toLong() ?: state.positionMicros).coerceAtLeast(0L)
        } else {
            state.positionMicros
        },
        durationMicros = if (kind == ANDROID_DURATION_CHANGED_EVENT_KIND) {
            ((event["durationMicros"] as? Number)?.toLong() ?: state.durationMicros).coerceAtLeast(0L)
        } else {
            state.durationMicros
        },
    )
}

internal fun closedAndroidMediaState(
    state: AndroidMediaState,
    playbackState: Int = ANDROID_CLOSED_PLAYBACK_STATE,
): AndroidMediaState = state.copy(
    metadata = null,
    playbackState = playbackState,
    positionMicros = 0L,
    durationMicros = 0L,
)

internal const val ANDROID_CLOSED_PLAYBACK_STATE = 6
