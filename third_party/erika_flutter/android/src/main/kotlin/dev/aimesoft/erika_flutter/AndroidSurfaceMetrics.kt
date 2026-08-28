package dev.aimesoft.erika_flutter

import kotlin.math.max

internal data class AndroidSurfaceMetrics(
    val width: Int,
    val height: Int,
    val scale: Double,
)

internal fun resolveAndroidSurfaceMetrics(
    pixelWidth: Int,
    pixelHeight: Int,
    density: Double,
): AndroidSurfaceMetrics {
    val contentScale = if (density.isFinite() && density > 0.0) density else 1.0
    return AndroidSurfaceMetrics(
        width = max(1, pixelWidth),
        height = max(1, pixelHeight),
        scale = contentScale,
    )
}
