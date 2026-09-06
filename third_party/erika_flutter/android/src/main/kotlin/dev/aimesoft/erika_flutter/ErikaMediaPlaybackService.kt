package dev.aimesoft.erika_flutter

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock

class ErikaMediaPlaybackService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            dispatchTick(SystemClock.elapsedRealtimeNanos().toDouble() / 1_000_000_000.0)
            handler.postDelayed(this, TICK_INTERVAL_MILLIS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val notification = intent.notification() ?: return START_NOT_STICKY
                startForeground(NOTIFICATION_ID, notification)
                handler.removeCallbacks(tick)
                handler.post(tick)
            }
            ACTION_STOP -> stopPlaybackService()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    private fun stopPlaybackService() {
        handler.removeCallbacks(tick)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun Intent.notification(): Notification? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(EXTRA_NOTIFICATION, Notification::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(EXTRA_NOTIFICATION)
    }

    companion object {
        private const val ACTION_START = "dev.aimesoft.erika_flutter.action.START_MEDIA_PLAYBACK"
        private const val ACTION_STOP = "dev.aimesoft.erika_flutter.action.STOP_MEDIA_PLAYBACK"
        private const val EXTRA_NOTIFICATION = "notification"
        private const val NOTIFICATION_ID = 0x4552494B
        private const val TICK_INTERVAL_MILLIS = 16L
        private val tickHandlers = LinkedHashMap<Any, (Double) -> Unit>()

        @Synchronized
        fun registerTickHandler(owner: Any, handler: (Double) -> Unit) {
            tickHandlers[owner] = handler
        }

        @Synchronized
        fun unregisterTickHandler(owner: Any) {
            tickHandlers.remove(owner)
        }

        private fun dispatchTick(timeSeconds: Double) {
            val handlers = synchronized(this) { tickHandlers.values.toList() }
            handlers.forEach { it(timeSeconds) }
        }

        fun start(context: Context, notification: Notification) {
            val intent = Intent(context, ErikaMediaPlaybackService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_NOTIFICATION, notification)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ErikaMediaPlaybackService::class.java))
        }
    }
}
