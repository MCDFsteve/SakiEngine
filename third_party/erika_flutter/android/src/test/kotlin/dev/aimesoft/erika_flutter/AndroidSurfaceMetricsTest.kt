package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidSurfaceMetricsTest {
    @Test
    fun keepsExactPhysicalExtentAndFractionalDensity() {
        val metrics = resolveAndroidSurfaceMetrics(1081, 607, 2.625)

        assertEquals(1081, metrics.width)
        assertEquals(607, metrics.height)
        assertEquals(2.625, metrics.scale, 0.0)
    }

    @Test
    fun preservesLowDensityAndSanitizesInvalidValues() {
        assertEquals(0.75, resolveAndroidSurfaceMetrics(320, 180, 0.75).scale, 0.0)
        assertEquals(1.0, resolveAndroidSurfaceMetrics(320, 180, Double.NaN).scale, 0.0)
        assertEquals(1.0, resolveAndroidSurfaceMetrics(320, 180, 0.0).scale, 0.0)
        assertEquals(1.0, resolveAndroidSurfaceMetrics(320, 180, -1.0).scale, 0.0)
    }
}
