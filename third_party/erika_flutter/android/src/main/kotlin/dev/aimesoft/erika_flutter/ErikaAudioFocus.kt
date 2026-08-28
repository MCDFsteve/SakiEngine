package dev.aimesoft.erika_flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper

internal enum class AudioFocusGrant {
    GRANTED,
    DELAYED,
    DENIED,
}

internal class ErikaAudioFocus(
    context: Context,
    private val onFocusLoss: (mayResume: Boolean) -> Unit,
    private val onFocusGain: () -> Unit,
) {
    private val applicationContext = context.applicationContext
    private val audioManager =
        applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var focusRequest: AudioFocusRequest? = null
    var focusGranted: Boolean = false
        private set
    var focusRequested: Boolean = false
        private set
    private var resumeOnGain = false
    private var noisyReceiverRegistered = false

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                return
            }
            if (!focusRequested) {
                return
            }
            resumeOnGain = false
            onFocusLoss(false)
            abandon()
        }
    }

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        mainHandler.post { handleFocusChange(change) }
    }

    fun request(): AudioFocusGrant {
        if (focusRequested) {
            return if (focusGranted) AudioFocusGrant.GRANTED else AudioFocusGrant.DELAYED
        }
        resumeOnGain = false
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(listener, mainHandler)
                .build()
                .also { focusRequest = it }
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        return when (result) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                focusRequested = true
                focusGranted = true
                registerNoisyReceiver()
                AudioFocusGrant.GRANTED
            }
            AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> {
                focusRequested = true
                focusGranted = false
                resumeOnGain = true
                registerNoisyReceiver()
                AudioFocusGrant.DELAYED
            }
            else -> {
                focusRequested = false
                focusGranted = false
                unregisterNoisyReceiver()
                AudioFocusGrant.DENIED
            }
        }
    }

    fun abandon() {
        if (!focusRequested) {
            return
        }
        focusRequested = false
        focusGranted = false
        resumeOnGain = false
        unregisterNoisyReceiver()
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let(audioManager::abandonAudioFocusRequest)
            } else {
                @Suppress("DEPRECATION")
                audioManager.abandonAudioFocus(listener)
            }
        }
    }

    private fun handleFocusChange(change: Int) {
        if (!focusRequested) {
            return
        }
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                focusGranted = true
                if (resumeOnGain) {
                    resumeOnGain = false
                    onFocusGain()
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                focusGranted = false
                resumeOnGain = true
                onFocusLoss(true)
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                focusRequested = false
                focusGranted = false
                resumeOnGain = false
                unregisterNoisyReceiver()
                onFocusLoss(false)
            }
        }
    }

    private fun registerNoisyReceiver() {
        if (noisyReceiverRegistered) {
            return
        }
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(
                noisyReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            applicationContext.registerReceiver(noisyReceiver, filter)
        }
        noisyReceiverRegistered = true
    }

    private fun unregisterNoisyReceiver() {
        if (!noisyReceiverRegistered) {
            return
        }
        runCatching { applicationContext.unregisterReceiver(noisyReceiver) }
        noisyReceiverRegistered = false
    }
}
