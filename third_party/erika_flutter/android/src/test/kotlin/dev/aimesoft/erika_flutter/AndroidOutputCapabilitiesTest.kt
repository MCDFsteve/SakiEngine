package dev.aimesoft.erika_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidOutputCapabilitiesTest {
    @Test
    fun sdrDoesNotReportAnOutputFallback() {
        val decision = androidOutputCapabilityDecision(
            extendedLinearRequested = false,
            sdkInt = 26,
            displayHdrSupported = false,
            directComposition = false,
        )

        assertFalse(decision.extendedLinearEligible)
        assertEquals(OUTPUT_FALLBACK_NONE, decision.fallbackReason)
    }

    @Test
    fun apiBelow28ReportsMissingNativeWindowDataspaceApi() {
        val decision = androidOutputCapabilityDecision(
            extendedLinearRequested = true,
            sdkInt = 27,
            displayHdrSupported = true,
            directComposition = true,
        )

        assertFalse(decision.extendedLinearEligible)
        assertEquals(
            OUTPUT_FALLBACK_NATIVE_WINDOW_DATASPACE_API_UNAVAILABLE,
            decision.fallbackReason,
        )
    }

    @Test
    fun nonHdrDisplayReportsDisplayCapabilityFailure() {
        val decision = androidOutputCapabilityDecision(
            extendedLinearRequested = true,
            sdkInt = 35,
            displayHdrSupported = false,
            directComposition = true,
        )

        assertFalse(decision.extendedLinearEligible)
        assertEquals(OUTPUT_FALLBACK_DISPLAY_HDR_UNSUPPORTED, decision.fallbackReason)
    }

    @Test
    fun textureCompositionReportsHybridCompositionRequirement() {
        val decision = androidOutputCapabilityDecision(
            extendedLinearRequested = true,
            sdkInt = 35,
            displayHdrSupported = true,
            directComposition = false,
        )

        assertTrue(decision.extendedLinearEligible)
        assertEquals(
            OUTPUT_FALLBACK_HYBRID_COMPOSITION_REQUIRED,
            decision.fallbackReason,
        )
    }

    @Test
    fun hdrSurfaceViewOnSupportedDisplayIsEligible() {
        val decision = androidOutputCapabilityDecision(
            extendedLinearRequested = true,
            sdkInt = 35,
            displayHdrSupported = true,
            directComposition = true,
        )

        assertTrue(decision.extendedLinearEligible)
        assertEquals(OUTPUT_FALLBACK_NONE, decision.fallbackReason)
    }

    @Test
    fun everyStableReasonHasTheAbiLabel() {
        assertEquals("none", androidOutputFallbackReasonLabel(0))
        assertEquals("display_hdr_unsupported", androidOutputFallbackReasonLabel(1))
        assertEquals("hybrid_composition_required", androidOutputFallbackReasonLabel(2))
        assertEquals("wgpu_backend_not_vulkan", androidOutputFallbackReasonLabel(3))
        assertEquals(
            "rgba16float_surface_format_unavailable",
            androidOutputFallbackReasonLabel(4),
        )
        assertEquals(
            "native_window_dataspace_api_unavailable",
            androidOutputFallbackReasonLabel(5),
        )
        assertEquals(
            "scrgb_dataspace_verification_failed",
            androidOutputFallbackReasonLabel(6),
        )
        assertEquals("surface_configure_failed", androidOutputFallbackReasonLabel(7))
        assertEquals("legacy_apple_edr_unsupported", androidOutputFallbackReasonLabel(8))
        assertEquals("unknown(99)", androidOutputFallbackReasonLabel(99))
    }

    @Test
    fun desiredHdrHeadroomAcceptsAutoOrApi35RangeOnly() {
        assertEquals(0f, androidDesiredHdrHeadroom(null))
        assertEquals(0f, androidDesiredHdrHeadroom(Float.NaN))
        assertEquals(0f, androidDesiredHdrHeadroom(0f))
        assertEquals(0f, androidDesiredHdrHeadroom(0.5f))
        assertEquals(1f, androidDesiredHdrHeadroom(1f))
        assertEquals(4f, androidDesiredHdrHeadroom(4f))
        assertEquals(10_000f, androidDesiredHdrHeadroom(10_000f))
        assertEquals(0f, androidDesiredHdrHeadroom(10_001f))
    }

    @Test
    fun hdrRatioMustBeAvailableFiniteAndAtLeastOne() {
        assertEquals(
            AndroidHdrHeadroomState(1f, false),
            androidHdrHeadroomState(ratioAvailable = false, ratio = 4f),
        )
        assertEquals(
            AndroidHdrHeadroomState(1f, false),
            androidHdrHeadroomState(ratioAvailable = true, ratio = Float.NaN),
        )
        assertEquals(
            AndroidHdrHeadroomState(1f, false),
            androidHdrHeadroomState(ratioAvailable = true, ratio = 0.5f),
        )
        assertEquals(
            AndroidHdrHeadroomState(3.25f, true),
            androidHdrHeadroomState(ratioAvailable = true, ratio = 3.25f),
        )
    }
}
