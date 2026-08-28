package dev.aimesoft.erika_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper

internal interface ErikaMediaCommandHandler {
    fun play(playerId: Long)
    fun pause(playerId: Long)
    fun stop(playerId: Long)
    fun seek(playerId: Long, positionMicros: Long)
    fun previous(playerId: Long)
    fun next(playerId: Long)
}

internal class ErikaMediaSession(
    context: Context,
    private val commands: ErikaMediaCommandHandler,
) {
    private val applicationContext = context.applicationContext
    private val notificationManager =
        applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val session = MediaSession(applicationContext, SESSION_TAG)
    private var activeState: AndroidMediaState? = null
    private var publishedState: AndroidMediaState? = null
    private var cachedArtworkBytes: ByteArray? = null
    private var cachedArtwork: Bitmap? = null
    private var playbackServiceActive = false

    init {
        notificationManager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Media playback",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = activeState?.let { commands.play(it.playerId) } ?: Unit
            override fun onPause() = activeState?.let { commands.pause(it.playerId) } ?: Unit
            override fun onStop() = activeState?.let { commands.stop(it.playerId) } ?: Unit
            override fun onSeekTo(pos: Long) =
                activeState?.let { commands.seek(it.playerId, pos.coerceAtLeast(0L) * 1_000L) } ?: Unit
            override fun onSkipToPrevious() =
                activeState?.takeIf(AndroidMediaState::previousEnabled)
                    ?.let { commands.previous(it.playerId) } ?: Unit
            override fun onSkipToNext() =
                activeState?.takeIf(AndroidMediaState::nextEnabled)
                    ?.let { commands.next(it.playerId) } ?: Unit
        }, Handler(Looper.getMainLooper()))
    }

    fun update(state: AndroidMediaState) {
        activeState = state
        val previous = publishedState
        val metadataChanged = previous == null ||
            !sameMetadata(previous.metadata, state.metadata) ||
            previous.durationMicros != state.durationMicros
        if (metadataChanged) {
            val metadata = state.metadata
            val metadataBuilder = MediaMetadata.Builder()
                .putString(
                    MediaMetadata.METADATA_KEY_TITLE,
                    metadata?.title
                        ?: applicationContext.applicationInfo.loadLabel(applicationContext.packageManager).toString(),
                )
                .putLong(MediaMetadata.METADATA_KEY_DURATION, state.durationMicros / 1_000L)
            metadata?.artist?.let { metadataBuilder.putString(MediaMetadata.METADATA_KEY_ARTIST, it) }
            metadata?.album?.let { metadataBuilder.putString(MediaMetadata.METADATA_KEY_ALBUM, it) }
            artworkBitmap(metadata?.artwork)?.let {
                metadataBuilder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, it)
            }
            session.setMetadata(metadataBuilder.build())
        }

        val playbackChanged = previous == null ||
            previous.playbackState != state.playbackState ||
            previous.positionMicros != state.positionMicros ||
            previous.playbackRate != state.playbackRate ||
            previous.previousEnabled != state.previousEnabled ||
            previous.nextEnabled != state.nextEnabled
        if (playbackChanged) {
            session.setPlaybackState(
                PlaybackState.Builder()
                    .setActions(state.androidPlaybackActions())
                    .setState(
                        state.playbackState.toAndroidPlaybackState(),
                        state.positionMicros / 1_000L,
                        if (state.playbackState == PLAYING_STATE) state.playbackRate else 0f,
                    )
                    .build(),
            )
        }

        val wasActive = previous?.playbackState !in setOf(null, CLOSED_STATE, ERROR_STATE)
        val isActive = state.playbackState !in setOf(CLOSED_STATE, ERROR_STATE)
        if (wasActive != isActive) {
            session.isActive = isActive
        }
        val notificationChanged = previous == null || metadataChanged ||
            previous.playbackState != state.playbackState ||
            previous.allowBackgroundPlayback != state.allowBackgroundPlayback
        if (isActive && notificationChanged) {
            val notification = notification(state)
            if (state.shouldUsePlaybackService()) {
                if (playbackServiceActive) {
                    notificationManager.notify(NOTIFICATION_ID, notification)
                } else {
                    ErikaMediaPlaybackService.start(applicationContext, notification)
                    playbackServiceActive = true
                }
            } else {
                stopPlaybackService()
                notificationManager.notify(NOTIFICATION_ID, notification)
            }
        } else if (!isActive && wasActive) {
            stopPlaybackService()
            notificationManager.cancel(NOTIFICATION_ID)
        }
        publishedState = state
    }

    fun dispatch(action: String) {
        val state = activeState ?: return
        when (action) {
            ACTION_PLAY -> commands.play(state.playerId)
            ACTION_PAUSE -> commands.pause(state.playerId)
            ACTION_STOP -> commands.stop(state.playerId)
        }
    }

    fun clear(playerId: Long) {
        if (activeState?.playerId != playerId) {
            return
        }
        activeState = null
        publishedState = null
        cachedArtworkBytes = null
        cachedArtwork = null
        stopPlaybackService()
        notificationManager.cancel(NOTIFICATION_ID)
        session.setMetadata(null)
        session.setPlaybackState(
            PlaybackState.Builder().setState(PlaybackState.STATE_NONE, 0L, 0f).build(),
        )
        session.isActive = false
    }

    fun release() {
        activeState = null
        publishedState = null
        cachedArtworkBytes = null
        cachedArtwork = null
        stopPlaybackService()
        notificationManager.cancel(NOTIFICATION_ID)
        session.isActive = false
        session.release()
    }

    private fun stopPlaybackService() {
        if (!playbackServiceActive) {
            return
        }
        ErikaMediaPlaybackService.stop(applicationContext)
        playbackServiceActive = false
    }

    private fun notification(state: AndroidMediaState): Notification {
        val playing = state.playbackState == PLAYING_STATE
        val builder = Notification.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(
                applicationContext.applicationInfo.icon.takeIf { it != 0 }
                    ?: android.R.drawable.ic_media_play,
            )
            .setContentTitle(state.metadata?.title ?: applicationContext.applicationInfo.loadLabel(applicationContext.packageManager))
            .setContentText(state.metadata?.artist ?: state.metadata?.album)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken).setShowActionsInCompactView(0, 1))
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_delete,
                    "Stop",
                    commandIntent(ACTION_STOP),
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "Pause" else "Play",
                    commandIntent(if (playing) ACTION_PAUSE else ACTION_PLAY),
                ).build(),
            )
        artworkBitmap(state.metadata?.artwork)?.let(builder::setLargeIcon)
        applicationContext.packageManager.getLaunchIntentForPackage(applicationContext.packageName)?.let {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    applicationContext,
                    0,
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder.build()
    }

    private fun artworkBitmap(bytes: ByteArray?): Bitmap? {
        if (bytes == null) {
            cachedArtworkBytes = null
            cachedArtwork = null
            return null
        }
        if (cachedArtworkBytes?.contentEquals(bytes) == true) {
            return cachedArtwork
        }
        cachedArtworkBytes = bytes.copyOf()
        cachedArtwork = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        return cachedArtwork
    }

    private fun sameMetadata(left: AndroidMediaMetadata?, right: AndroidMediaMetadata?): Boolean {
        if (left === right) {
            return true
        }
        if (left == null || right == null) {
            return false
        }
        return left.title == right.title &&
            left.artist == right.artist &&
            left.album == right.album &&
            when {
                left.artwork === right.artwork -> true
                left.artwork == null || right.artwork == null -> false
                else -> left.artwork.contentEquals(right.artwork)
            }
    }

    private fun commandIntent(action: String): PendingIntent = PendingIntent.getBroadcast(
        applicationContext,
        action.hashCode(),
        Intent(applicationContext, ErikaMediaCommandReceiver::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        const val ACTION_PLAY = "dev.aimesoft.erika_flutter.action.PLAY"
        const val ACTION_PAUSE = "dev.aimesoft.erika_flutter.action.PAUSE"
        const val ACTION_STOP = "dev.aimesoft.erika_flutter.action.STOP"
        const val PLAYING_STATE = 3
        const val CLOSED_STATE = 6
        const val ERROR_STATE = 7
        private const val SESSION_TAG = "ErikaMediaSession"
        private const val CHANNEL_ID = "erika_media_playback"
        private const val NOTIFICATION_ID = 0x4552494B
    }
}

internal fun AndroidMediaState.shouldUsePlaybackService(): Boolean =
    allowBackgroundPlayback && playbackState == ErikaMediaSession.PLAYING_STATE

internal fun AndroidMediaState.androidPlaybackActions(): Long {
    var actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
        PlaybackState.ACTION_SEEK_TO
    if (previousEnabled) {
        actions = actions or PlaybackState.ACTION_SKIP_TO_PREVIOUS
    }
    if (nextEnabled) {
        actions = actions or PlaybackState.ACTION_SKIP_TO_NEXT
    }
    return actions
}

internal fun Int.toAndroidPlaybackState(): Int = when (this) {
    1 -> PlaybackState.STATE_CONNECTING
    2 -> PlaybackState.STATE_PAUSED
    3 -> PlaybackState.STATE_PLAYING
    4 -> PlaybackState.STATE_PAUSED
    5 -> PlaybackState.STATE_STOPPED
    6 -> PlaybackState.STATE_NONE
    7 -> PlaybackState.STATE_ERROR
    else -> PlaybackState.STATE_NONE
}
