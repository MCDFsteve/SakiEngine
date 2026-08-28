package dev.aimesoft.erika_flutter

internal const val OUTPUT_FALLBACK_NONE = 0
internal const val OUTPUT_FALLBACK_DISPLAY_HDR_UNSUPPORTED = 1
internal const val OUTPUT_FALLBACK_HYBRID_COMPOSITION_REQUIRED = 2
internal const val OUTPUT_FALLBACK_WGPU_BACKEND_NOT_VULKAN = 3
internal const val OUTPUT_FALLBACK_RGBA16FLOAT_SURFACE_FORMAT_UNAVAILABLE = 4
internal const val OUTPUT_FALLBACK_NATIVE_WINDOW_DATASPACE_API_UNAVAILABLE = 5
internal const val OUTPUT_FALLBACK_SCRGB_DATASPACE_VERIFICATION_FAILED = 6
internal const val OUTPUT_FALLBACK_SURFACE_CONFIGURE_FAILED = 7
internal const val OUTPUT_FALLBACK_LEGACY_APPLE_EDR_UNSUPPORTED = 8

internal data class AndroidOutputCapabilityDecision(
    val extendedLinearEligible: Boolean,
    val fallbackReason: Int,
)

internal data class AndroidHdrHeadroomState(
    val headroom: Float,
    val known: Boolean,
)

internal fun androidDesiredHdrHeadroom(value: Float?): Float {
    if (value == null || !value.isFinite()) {
        return 0f
    }
    return if (value == 0f || value in 1f..10_000f) value else 0f
}

internal fun androidHdrHeadroomState(
    ratioAvailable: Boolean,
    ratio: Float,
): AndroidHdrHeadroomState = if (ratioAvailable && ratio.isFinite() && ratio >= 1f) {
    AndroidHdrHeadroomState(headroom = ratio, known = true)
} else {
    AndroidHdrHeadroomState(headroom = 1f, known = false)
}

internal fun androidOutputCapabilityDecision(
    extendedLinearRequested: Boolean,
    sdkInt: Int,
    displayHdrSupported: Boolean,
    directComposition: Boolean,
): AndroidOutputCapabilityDecision {
    if (!extendedLinearRequested) {
        return AndroidOutputCapabilityDecision(
            extendedLinearEligible = false,
            fallbackReason = OUTPUT_FALLBACK_NONE,
        )
    }
    if (sdkInt < 28) {
        return AndroidOutputCapabilityDecision(
            extendedLinearEligible = false,
            fallbackReason = OUTPUT_FALLBACK_NATIVE_WINDOW_DATASPACE_API_UNAVAILABLE,
        )
    }
    if (!displayHdrSupported) {
        return AndroidOutputCapabilityDecision(
            extendedLinearEligible = false,
            fallbackReason = OUTPUT_FALLBACK_DISPLAY_HDR_UNSUPPORTED,
        )
    }
    return AndroidOutputCapabilityDecision(
        extendedLinearEligible = true,
        fallbackReason = if (directComposition) {
            OUTPUT_FALLBACK_NONE
        } else {
            OUTPUT_FALLBACK_HYBRID_COMPOSITION_REQUIRED
        },
    )
}

internal fun androidOutputFallbackReasonLabel(reason: Int): String = when (reason) {
    OUTPUT_FALLBACK_NONE -> "none"
    OUTPUT_FALLBACK_DISPLAY_HDR_UNSUPPORTED -> "display_hdr_unsupported"
    OUTPUT_FALLBACK_HYBRID_COMPOSITION_REQUIRED -> "hybrid_composition_required"
    OUTPUT_FALLBACK_WGPU_BACKEND_NOT_VULKAN -> "wgpu_backend_not_vulkan"
    OUTPUT_FALLBACK_RGBA16FLOAT_SURFACE_FORMAT_UNAVAILABLE ->
        "rgba16float_surface_format_unavailable"
    OUTPUT_FALLBACK_NATIVE_WINDOW_DATASPACE_API_UNAVAILABLE ->
        "native_window_dataspace_api_unavailable"
    OUTPUT_FALLBACK_SCRGB_DATASPACE_VERIFICATION_FAILED ->
        "scrgb_dataspace_verification_failed"
    OUTPUT_FALLBACK_SURFACE_CONFIGURE_FAILED -> "surface_configure_failed"
    OUTPUT_FALLBACK_LEGACY_APPLE_EDR_UNSUPPORTED -> "legacy_apple_edr_unsupported"
    else -> "unknown($reason)"
}
