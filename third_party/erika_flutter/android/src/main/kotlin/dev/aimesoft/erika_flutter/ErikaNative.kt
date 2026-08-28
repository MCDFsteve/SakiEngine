package dev.aimesoft.erika_flutter

import android.view.Surface

internal object ErikaNative {
    init {
        System.loadLibrary("erika_capi")
    }

    @JvmStatic
    external fun nativeCreate(
        outputMode: Int,
        edrHeadroom: Float,
        upscaler: Int,
        videoAlphaMode: Int,
    ): Long

    @JvmStatic
    external fun nativeLastError(): String

    @JvmStatic
    external fun nativeDestroy(handle: Long)

    @JvmStatic
    external fun nativeInvoke(
        handle: Long,
        method: String,
        argsJson: String,
        ownedFd: Int,
    ): String

    @JvmStatic
    external fun nativeRegisterSubtitleMemoryFont(handle: Long, data: ByteArray): String

    @JvmStatic
    external fun nativeAttachSurface(
        handle: Long,
        surface: Surface,
        width: Int,
        height: Int,
        scale: Double,
        extendedLinear: Boolean,
        directComposition: Boolean,
        desiredHeadroom: Float,
        fallbackReason: Int,
    ): String

    @JvmStatic
    external fun nativeResizeSurface(
        handle: Long,
        width: Int,
        height: Int,
        scale: Double,
    ): String

    @JvmStatic
    external fun nativeDetachSurface(handle: Long): String

    @JvmStatic
    external fun nativeRenderTick(handle: Long, timeSeconds: Double): String

    @JvmStatic
    external fun nativeAudioOnlyTick(handle: Long): String

    @JvmStatic
    external fun nativePollEvent(handle: Long): String?

    @JvmStatic
    external fun nativePlaybackState(handle: Long): Int

    @JvmStatic
    external fun nativePlaybackIntentState(handle: Long): Int

    @JvmStatic
    external fun nativeCaptureFrame(handle: Long, width: Int, height: Int): ByteArray?
}
