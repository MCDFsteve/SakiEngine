import Darwin
import AVFoundation
import Flutter
import MediaPlayer
import Metal
import ObjectiveC.runtime
import QuartzCore
import UIKit

private let erikaWindowHostedVideoSurfaceId: Int64 = -1
private let erikaDebugLabelsEnabled =
  ProcessInfo.processInfo.environment["ERIKA_DEBUG_LABELS"] == "1"

private func erikaHdrWrite(_ message: String) {
  fputs("ErikaHDR[iOS]: \(message)\n", stderr)
  fflush(stderr)
}

private func erikaHdrLog(_ enabled: Bool, _ message: String) {
  if enabled {
    erikaHdrWrite(message)
  }
}

private func erikaHdrEnvironmentEnabled() -> Bool {
  guard let value = ProcessInfo.processInfo.environment["ERIKA_HDR_DEBUG"] else {
    return false
  }
  switch value.lowercased() {
  case "1", "true", "yes", "on":
    return true
  default:
    return false
  }
}

private func erikaOutputModeLabel(_ config: ErikaPresenterConfigC) -> String {
  switch config.outputMode {
  case 1:
    return String(format: "AppleEdr(headroom=%.2f)", config.edrHeadroom)
  case 2:
    return String(format: "ExtendedLinear(headroom=%.2f)", config.edrHeadroom)
  case 3:
    return String(format: "Auto(headroom=%.2f)", config.edrHeadroom)
  default:
    return "Sdr"
  }
}

private func erikaScreenSummary(_ screen: UIScreen?) -> String {
  guard let screen else {
    return "screen=nil"
  }
  var parts = [
    "scale=\(screen.scale)",
    "nativeScale=\(screen.nativeScale)",
    "brightness=\(String(format: "%.3f", screen.brightness))",
    "gamut=\(screen.traitCollection.displayGamut.rawValue)",
  ]
  if #available(iOS 16.0, *) {
    parts.append("currentEDR=\(String(format: "%.3f", screen.currentEDRHeadroom))")
    parts.append("potentialEDR=\(String(format: "%.3f", screen.potentialEDRHeadroom))")
  }
  return parts.joined(separator: " ")
}

private func erikaLayerValue(_ layer: CAMetalLayer, selector name: String) -> String {
  let selector = Selector(name)
  guard layer.responds(to: selector) else {
    return "unavailable"
  }
  return String(describing: layer.value(forKey: name) ?? "nil")
}

private func erikaConfigureLayerDynamicRange(_ layer: CAMetalLayer, config: ErikaPresenterConfigC) {
  if config.outputMode == 1 || config.outputMode == 2 {
    layer.contentsFormat = .RGBA16Float
    if #available(iOS 16.0, *) {
      layer.wantsExtendedDynamicRangeContent = true
      layer.edrMetadata = CAEDRMetadata.hdr10(
        minLuminance: 0.02,
        maxLuminance: 1200.0,
        opticalOutputScale: 203.0
      )
    }
    if #available(iOS 18.0, *) {
      layer.toneMapMode = .ifSupported
    }
    if #available(iOS 26.0, *) {
      layer.preferredDynamicRange = .high
      layer.contentsHeadroom = CGFloat(max(config.edrHeadroom, 1.0))
    }
    return
  }

  layer.contentsFormat = .RGBA8Uint
  if #available(iOS 16.0, *) {
    layer.wantsExtendedDynamicRangeContent = false
    layer.edrMetadata = nil
  }
  if #available(iOS 18.0, *) {
    layer.toneMapMode = .automatic
  }
  // Auto is initialized in SDR, but the native renderer owns later changes.
  // Do not pin preferredDynamicRange/contentsHeadroom to SDR here.
  if config.outputMode != 3 {
    if #available(iOS 26.0, *) {
      layer.preferredDynamicRange = .standard
      layer.contentsHeadroom = 0.0
    }
  }
}

private func erikaLayerSummary(_ layer: CAMetalLayer) -> String {
  let wantsEDR: String
  if #available(iOS 16.0, *) {
    wantsEDR = String(layer.wantsExtendedDynamicRangeContent)
  } else {
    wantsEDR = "unavailable"
  }
  let toneMapMode: String
  if #available(iOS 18.0, *) {
    toneMapMode = String(describing: layer.toneMapMode)
  } else {
    toneMapMode = "unavailable"
  }
  let preferredDynamicRange: String
  if #available(iOS 26.0, *) {
    preferredDynamicRange = String(describing: layer.preferredDynamicRange)
  } else {
    preferredDynamicRange = "unavailable"
  }
  let contentsHeadroom: String
  if #available(iOS 26.0, *) {
    contentsHeadroom = String(format: "%.3f", layer.contentsHeadroom)
  } else {
    contentsHeadroom = "unavailable"
  }
  let colorSpace = layer.colorspace?.name.map { String(describing: $0) } ?? "nil"
  return [
    "pixelFormat=\(layer.pixelFormat.rawValue)",
    "drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))",
    "framebufferOnly=\(layer.framebufferOnly)",
    "opaque=\(layer.isOpaque)",
    "contentsFormat=\(layer.contentsFormat)",
    "wantsEDR=\(wantsEDR)",
    "toneMapMode=\(toneMapMode)",
    "preferredDynamicRange=\(preferredDynamicRange)",
    "contentsHeadroom=\(contentsHeadroom)",
    "edrMetadata=\(erikaLayerValue(layer, selector: "EDRMetadata"))",
    "colorspace=\(colorSpace)",
  ].joined(separator: " ")
}

private struct ErikaTrackSelectionC {
  var video: Int64 = -1
  var audio: Int64 = -1
  var subtitle: Int64 = -1
}

private struct ErikaVideoParamsC {
  var width: UInt32 = 0
  var height: UInt32 = 0
  var primaries: UInt32 = 0
  var transfer: UInt32 = 0
}

private struct ErikaTrackCountsC {
  var video: UInt32 = 0
  var audio: UInt32 = 0
  var subtitle: UInt32 = 0
}

private struct ErikaTrackInfoC {
  var id: Int64 = -1
  var kind: Int32 = 0
  var source: Int32 = 0
  var selected: UInt8 = 0
  var canRemove: UInt8 = 0
  var title: UnsafeMutablePointer<CChar>?
  var language: UnsafeMutablePointer<CChar>?
  var codec: UnsafeMutablePointer<CChar>?
  var width: UInt32 = 0
  var height: UInt32 = 0
  var sampleRate: UInt32 = 0
  var channels: UInt32 = 0
  var pixelFormat: UnsafeMutablePointer<CChar>?
  var sampleFormat: UnsafeMutablePointer<CChar>?
  var profile: UnsafeMutablePointer<CChar>?
  var level: Int32 = 0
  var bitRate: UInt64 = 0
  var frameRateNumerator: UInt32 = 0
  var frameRateDenominator: UInt32 = 0
}

private struct ErikaPresenterConfigC {
  var outputMode: Int32 = 0
  var edrHeadroom: Float = 1.0
  var lumaUpscaler: Int32 = 0
  var videoAlphaMode: Int32 = 0

  static let sdr = ErikaPresenterConfigC()

  static func appleEdr(headroom: Float) -> ErikaPresenterConfigC {
    ErikaPresenterConfigC(outputMode: 1, edrHeadroom: max(1.0, headroom))
  }

  static func auto(headroom: Float) -> ErikaPresenterConfigC {
    ErikaPresenterConfigC(outputMode: 3, edrHeadroom: max(1.0, headroom))
  }
}

private struct ErikaSubtitleStyleC {
  var fontFamily: UnsafePointer<CChar>?
  var fontFilePath: UnsafePointer<CChar>?
  var primaryColorRgba: UInt32
  var outlineColorRgba: UInt32
  var fontSize: Double
  var outlineWidth: Double
  var bold: Bool
  var italic: Bool
  var underline: Bool
  var strikeOut: Bool
  var spacing: Double
  var scaleXPercent: Double
  var scaleYPercent: Double
  var borderStyle: Int32
  var shadowDepth: Double
  var blur: Double
  var alignment: Int32
  var marginLeft: Int32
  var marginRight: Int32
  var marginVertical: Int32
  var overrideMask: UInt32
}

private struct ErikaHttpHeader {
  var name: UnsafeMutablePointer<CChar>?
  var value: UnsafeMutablePointer<CChar>?
}

private struct ErikaEventC {
  var kind: Int32 = 0
  var status: Int32 = 0
  var state: Int32 = 0
  var durationMicros: Int64 = -1
  var positionMicros: UInt64 = 0
  var buffering: UInt8 = 0
  var video: ErikaVideoParamsC = ErikaVideoParamsC()
  var tracks: ErikaTrackCountsC = ErikaTrackCountsC()
}

private struct ErikaPresenterStatsC {
  var decodedVideoFrames: UInt64 = 0
  var renderedVideoFrames: UInt64 = 0
  var renderedTestFrames: UInt64 = 0
  var pushedAudioFrames: UInt64 = 0
  var overlayFrames: UInt64 = 0
  var danmakuFrames: UInt64 = 0
  var danmakuItems: UInt64 = 0
  var importFailures: UInt64 = 0
  var renderFailures: UInt64 = 0
  var audioFailures: UInt64 = 0
  // The fields below must mirror `ErikaPresenterStats` in
  // crates/erika_capi/include/erika.h exactly (order and types). erika_presenter_render_tick
  // writes the full struct through this pointer, so any missing field overflows the buffer.
  var softwareVideoFrames: UInt64 = 0
  var hardwareVideoFrames: UInt64 = 0
  var zeroCopyVideoFrames: UInt64 = 0
  var cpuVideoFrameFallbacks: UInt64 = 0
  var lastRenderMicros: UInt64 = 0
  var lastRenderCurrentMicros: UInt64 = 0
  var audioClockReadFrames: UInt64 = 0
  var audioClockQueuedFrames: UInt64 = 0
  var audioClockUnderflowFrames: UInt64 = 0
  var audioRecoveryState: Int32 = 0
  var audioLastErrorCode: Int32 = 0
  var audioRecoveryAttempts: UInt64 = 0
  var audioRecoveryCount: UInt64 = 0
  var audioRecoveryFailures: UInt64 = 0
  var directZeroCopyVideoFrames: UInt64 = 0
  var sharedHandleVideoFrames: UInt64 = 0
  var hdrSourceFrames: UInt64 = 0
  var hdr10OutputFrames: UInt64 = 0
  var sdrTonemapFrames: UInt64 = 0
  var hdr10MetadataUpdates: UInt64 = 0
  var hdr10MetadataFailures: UInt64 = 0
  var hdr10OutputFailures: UInt64 = 0
  var hdr10OutputActive: Bool = false
  var videoFrameBackpressureDrops: UInt64 = 0
}

private struct ErikaUpscalerStatusC {
  var requestedMode: Int32 = 0
  var activeBackend: Int32 = 0
  var fallbackCount: UInt64 = 0
  var upscaledFrames: UInt64 = 0
  var lastEncodeMicros: UInt64 = 0
  var lastGpuMicros: UInt64 = 0
}

private struct ErikaSubtitleMemoryFontStatusC {
  var registeredCount: UInt = 0
  var registeredBytes: UInt = 0
  var selectedCount: UInt = 0
  var generation: UInt64 = 0
  var selectedIds: UnsafeMutablePointer<UInt64>?
}

// Keep field order and types aligned with `ErikaOutputStatus` in erika.h.
private struct ErikaOutputStatusC {
  var requestedMode: Int32 = 0
  var activeEncoding: Int32 = 0
  var surfaceFormat: Int32 = 0
  var nativeDataSpace: Int32 = 0
  var requestedHeadroom: Float = 1.0
  var activeHeadroom: Float = 1.0
  var activeHeadroomKnown: Bool = false
  var extendedLinearActive: Bool = false
  var fallbackReason: Int32 = 0
  var fallbackCount: UInt64 = 0
  var dataSpaceFailures: UInt64 = 0
  var headroomUpdates: UInt64 = 0
  var extendedLinearFrames: UInt64 = 0
}

// Keep field order and types aligned with `ErikaPresenterResourceStatus` in erika.h.
private struct ErikaPresenterResourceStatusC {
  var deviceCurrentAllocatedBytes: UInt64 = 0
  var deviceRecommendedWorkingSetBytes: UInt64 = 0
  var drawableEstimatedBytes: UInt64 = 0
  var videoFrameBytes: UInt64 = 0
  var overlayAtlasBytes: UInt64 = 0
  var danmakuAtlasBytes: UInt64 = 0
  var danmakuVertexBufferBytes: UInt64 = 0
  var upscalerBytes: UInt64 = 0
  var rendererTrackedBytes: UInt64 = 0
  var presenterCpuDanmakuAtlasBytes: UInt64 = 0
  var drawableCount: UInt32 = 0
  var outputModeSwitches: UInt64 = 0
}

private let erikaDefaultDisplayFps = 60

private struct ErikaDanmakuConfigC {
  var enabled: UInt8 = 1
  var fontSize: Float = 30.0
  var opacity: Float = 1.0
  var displayArea: Float = 1.0
  var scrollDurationSeconds: Float = 10.0
  var scrollSpeedFactor: Float = 1.0
  var trackGapRatio: Float = 0.15
  var outlineWidth: Float = 1.0
  var shadowOffsetX: Float = 1.0
  var shadowOffsetY: Float = 1.0
  var mergeDuplicates: UInt8 = 0
  var allowStacking: UInt8 = 0
  var allowScrollOverwrite: UInt8 = 1
  var maxQuantity: UInt32 = 0
  var maxLinesPerMode: UInt32 = 0
  var blockTop: UInt8 = 0
  var blockBottom: UInt8 = 0
  var blockScroll: UInt8 = 0
  var shadowStyle: Int32 = 3
}

private struct ErikaDanmakuTrackInfoC {
  var id: UInt64 = 0
  var enabled: UInt8 = 0
  var offsetMicros: Int64 = 0
  var itemCount: Int = 0
  var name: UnsafeMutablePointer<CChar>?
  var source: UnsafeMutablePointer<CChar>?
}

private enum ErikaPluginError: Error, CustomStringConvertible {
  case libraryNotFound([String])
  case symbolMissing(String)
  case httpHeadersUnsupported
  case invalidArguments(String)
  case playerNotFound(Int64)
  case viewNotFound(Int64)
  case overlayNotAvailable
  case presenterCreateFailed
  case erikaStatus(String, Int32)
  case libraryLoadFailed(String, String?)

  var description: String {
    switch self {
    case .libraryNotFound(let paths):
      return "Unable to load Erika C ABI. Tried: \(paths.joined(separator: ", "))"
    case .symbolMissing(let symbol):
      return "Missing Erika C ABI symbol: \(symbol)"
    case .httpHeadersUnsupported:
      return "The loaded Erika native library does not export erika_presenter_open_with_headers, so httpHeaders cannot be applied. Update the bundled native library (a prebuilt from 0.1.3 or earlier predates HTTP header support)."
    case .invalidArguments(let message):
      return message
    case .playerNotFound(let playerId):
      return "Erika player \(playerId) was not found."
    case .viewNotFound(let viewId):
      return "Erika video view \(viewId) was not found."
    case .overlayNotAvailable:
      return "No window-hosted Erika overlay is available."
    case .presenterCreateFailed:
      return "erika_presenter_create returned null."
    case .erikaStatus(let operation, let status):
      return "\(operation) failed with ErikaStatus \(status)."
    case .libraryLoadFailed(let path, let detail):
      if let detail, !detail.isEmpty {
        return "\(path) (\(detail))"
      }
      return path
    }
  }
}

private final class ErikaNativeLibrary {
  typealias CreateFn = @convention(c) () -> UnsafeMutableRawPointer?
  typealias CreateWithOutputModeFn = @convention(c) (Int32, Float) -> UnsafeMutableRawPointer?
  typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias OpenFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
  typealias OpenWithHeadersFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeRawPointer?, UInt) -> Int32
  typealias CommandFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
  typealias SeekFn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32
  typealias SetPlaybackRateFn = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
  typealias SetVolumeFn = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
  typealias SetUpscalerFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
  typealias SetSubtitleScaleFn = @convention(c) (UnsafeMutableRawPointer?, Double) -> Int32
  typealias SetSubtitleFontFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> Int32
  typealias SetSubtitleStyleFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeRawPointer?
  ) -> Int32
  typealias RegisterSubtitleMemoryFontFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt, UnsafeMutablePointer<UInt64>?) -> Int32
  typealias SelectSubtitleMemoryFontsFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt64>?, UInt) -> Int32
  typealias GetSubtitleMemoryFontStatusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias FreeSubtitleMemoryFontStatusFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias GetUpscalerStatusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias GetOutputStatusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias GetResourceStatusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias SelectTrackFn = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Int32
  typealias AddExternalSubtitleFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<Int64>?
  ) -> Int32
  typealias RemoveSubtitleTrackFn = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Int32
  typealias LoadDanmakuFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
  typealias AddDanmakuTrackFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    Int64,
    UnsafeMutablePointer<UInt64>?
  ) -> Int32
  typealias ClearDanmakuFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
  typealias SetDanmakuEnabledFn = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32
  typealias SetDebugHudEnabledFn = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Int32
  typealias SetDanmakuConfigFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Int32
  typealias GetDanmakuConfigFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias SetDanmakuFontFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> Int32
  typealias SetDanmakuBlockWordsFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
  typealias RemoveDanmakuTrackFn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Int32
  typealias SetDanmakuTrackEnabledFn = @convention(c) (UnsafeMutableRawPointer?, UInt64, Bool) -> Int32
  typealias SetDanmakuTrackOffsetFn = @convention(c) (UnsafeMutableRawPointer?, UInt64, Int64) -> Int32
  typealias SetDanmakuGlobalOffsetFn = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Int32
  typealias TrackSelectionFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias TracksFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int,
    UnsafeMutablePointer<Int>?
  ) -> Int32
  typealias TrackInfoFreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias DanmakuTrackInfoFreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
  typealias AttachMetalLayerFn = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt32, UInt32, Double) -> Int32
  typealias ResizeSurfaceFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, Double) -> Int32
  typealias RenderTickFn = @convention(c) (UnsafeMutableRawPointer?, Double, UnsafeMutableRawPointer?) -> Int32
  typealias AudioOnlyTickFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias CaptureFrameRgbaFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
  typealias PollEventFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
  typealias LastErrorMessageFn = @convention(c) () -> UnsafeMutablePointer<CChar>?
  typealias StringFreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

  static let shared = try? ErikaNativeLibrary()

  let create: CreateFn
  let createWithOutputMode: CreateWithOutputModeFn?
  let destroy: DestroyFn
  let open: OpenFn
  let openWithHeaders: OpenWithHeadersFn?
  let play: CommandFn
  let pause: CommandFn
  let stop: CommandFn
  let close: CommandFn
  let seek: SeekFn
  let setPlaybackRate: SetPlaybackRateFn?
  let setVolume: SetVolumeFn?
  let setUpscaler: SetUpscalerFn?
  let setSubtitleScale: SetSubtitleScaleFn?
  let setSubtitleFont: SetSubtitleFontFn?
  let setSubtitleStyle: SetSubtitleStyleFn?
  let registerSubtitleMemoryFont: RegisterSubtitleMemoryFontFn?
  let selectSubtitleMemoryFonts: SelectSubtitleMemoryFontsFn?
  let clearSubtitleMemoryFonts: CommandFn?
  let getSubtitleMemoryFontStatus: GetSubtitleMemoryFontStatusFn?
  let freeSubtitleMemoryFontStatus: FreeSubtitleMemoryFontStatusFn?
  let getUpscalerStatus: GetUpscalerStatusFn?
  let getOutputStatus: GetOutputStatusFn?
  let getResourceStatus: GetResourceStatusFn?
  let selectAudioTrack: SelectTrackFn
  let selectSubtitleTrack: SelectTrackFn
  let addExternalSubtitle: AddExternalSubtitleFn
  let removeSubtitleTrack: RemoveSubtitleTrackFn
  let loadDanmakuFile: LoadDanmakuFn?
  let loadDanmakuJson: LoadDanmakuFn?
  let addDanmakuTrackFile: AddDanmakuTrackFn?
  let addDanmakuTrackJson: AddDanmakuTrackFn?
  let removeDanmakuTrack: RemoveDanmakuTrackFn?
  let setDanmakuTrackEnabled: SetDanmakuTrackEnabledFn?
  let setDanmakuTrackOffset: SetDanmakuTrackOffsetFn?
  let setDanmakuGlobalOffset: SetDanmakuGlobalOffsetFn?
  let danmakuTracks: TracksFn?
  let clearDanmaku: ClearDanmakuFn?
  let setDanmakuEnabled: SetDanmakuEnabledFn?
  let setDebugHudEnabled: SetDebugHudEnabledFn?
  let setDanmakuConfig: SetDanmakuConfigFn?
  let getDanmakuConfig: GetDanmakuConfigFn?
  let setDanmakuFont: SetDanmakuFontFn?
  let setDanmakuBlockWords: SetDanmakuBlockWordsFn?
  let trackSelection: TrackSelectionFn
  let tracks: TracksFn
  let freeTrackInfo: TrackInfoFreeFn
  let freeDanmakuTrackInfo: DanmakuTrackInfoFreeFn?
  let attachMetalLayer: AttachMetalLayerFn
  let resizeSurface: ResizeSurfaceFn
  let detachSurface: CommandFn
  let renderTick: RenderTickFn
  let audioOnlyTick: AudioOnlyTickFn
  let captureFrameRgba: CaptureFrameRgbaFn?
  let pollEvent: PollEventFn
  let lastErrorMessage: LastErrorMessageFn
  let stringFree: StringFreeFn

  private let libraryHandle: UnsafeMutableRawPointer
  let path: String

  private init() throws {
    let loaded = try Self.openLibrary()
    libraryHandle = loaded.handle
    path = loaded.path
    erikaHdrLog(
      erikaHdrEnvironmentEnabled(),
      "loaded native library from \(path)"
    )

    create = try Self.load("erika_presenter_create", from: libraryHandle, as: CreateFn.self)
    createWithOutputMode = Self.loadOptional("erika_presenter_create_with_output_mode", from: libraryHandle, as: CreateWithOutputModeFn.self)
    destroy = try Self.load("erika_presenter_destroy", from: libraryHandle, as: DestroyFn.self)
    open = try Self.load("erika_presenter_open", from: libraryHandle, as: OpenFn.self)
    openWithHeaders = Self.loadOptional("erika_presenter_open_with_headers", from: libraryHandle, as: OpenWithHeadersFn.self)
    play = try Self.load("erika_presenter_play", from: libraryHandle, as: CommandFn.self)
    pause = try Self.load("erika_presenter_pause", from: libraryHandle, as: CommandFn.self)
    stop = try Self.load("erika_presenter_stop", from: libraryHandle, as: CommandFn.self)
    close = try Self.load("erika_presenter_close", from: libraryHandle, as: CommandFn.self)
    seek = try Self.load("erika_presenter_seek", from: libraryHandle, as: SeekFn.self)
    setPlaybackRate = Self.loadOptional("erika_presenter_set_playback_rate", from: libraryHandle, as: SetPlaybackRateFn.self)
    setVolume = Self.loadOptional("erika_presenter_set_volume", from: libraryHandle, as: SetVolumeFn.self)
    setUpscaler = Self.loadOptional("erika_presenter_set_upscaler", from: libraryHandle, as: SetUpscalerFn.self)
    setSubtitleScale = Self.loadOptional("erika_presenter_set_subtitle_scale", from: libraryHandle, as: SetSubtitleScaleFn.self)
    setSubtitleFont = Self.loadOptional("erika_presenter_set_subtitle_font", from: libraryHandle, as: SetSubtitleFontFn.self)
    setSubtitleStyle = Self.loadOptional("erika_presenter_set_subtitle_style", from: libraryHandle, as: SetSubtitleStyleFn.self)
    registerSubtitleMemoryFont = Self.loadOptional("erika_presenter_register_subtitle_memory_font", from: libraryHandle, as: RegisterSubtitleMemoryFontFn.self)
    selectSubtitleMemoryFonts = Self.loadOptional("erika_presenter_select_subtitle_memory_fonts", from: libraryHandle, as: SelectSubtitleMemoryFontsFn.self)
    clearSubtitleMemoryFonts = Self.loadOptional("erika_presenter_clear_subtitle_memory_fonts", from: libraryHandle, as: CommandFn.self)
    getSubtitleMemoryFontStatus = Self.loadOptional("erika_presenter_get_subtitle_memory_font_status", from: libraryHandle, as: GetSubtitleMemoryFontStatusFn.self)
    freeSubtitleMemoryFontStatus = Self.loadOptional("erika_subtitle_memory_font_status_free", from: libraryHandle, as: FreeSubtitleMemoryFontStatusFn.self)
    getUpscalerStatus = Self.loadOptional("erika_presenter_get_upscaler_status", from: libraryHandle, as: GetUpscalerStatusFn.self)
    getOutputStatus = Self.loadOptional("erika_presenter_get_output_status", from: libraryHandle, as: GetOutputStatusFn.self)
    getResourceStatus = Self.loadOptional("erika_presenter_get_resource_status", from: libraryHandle, as: GetResourceStatusFn.self)
    selectAudioTrack = try Self.load("erika_presenter_select_audio_track", from: libraryHandle, as: SelectTrackFn.self)
    selectSubtitleTrack = try Self.load("erika_presenter_select_subtitle_track", from: libraryHandle, as: SelectTrackFn.self)
    addExternalSubtitle = try Self.load("erika_presenter_add_external_subtitle", from: libraryHandle, as: AddExternalSubtitleFn.self)
    removeSubtitleTrack = try Self.load("erika_presenter_remove_subtitle_track", from: libraryHandle, as: RemoveSubtitleTrackFn.self)
    loadDanmakuFile = Self.loadOptional("erika_presenter_load_danmaku_file", from: libraryHandle, as: LoadDanmakuFn.self)
    loadDanmakuJson = Self.loadOptional("erika_presenter_load_danmaku_json", from: libraryHandle, as: LoadDanmakuFn.self)
    addDanmakuTrackFile = Self.loadOptional("erika_presenter_add_danmaku_track_file", from: libraryHandle, as: AddDanmakuTrackFn.self)
    addDanmakuTrackJson = Self.loadOptional("erika_presenter_add_danmaku_track_json", from: libraryHandle, as: AddDanmakuTrackFn.self)
    removeDanmakuTrack = Self.loadOptional("erika_presenter_remove_danmaku_track", from: libraryHandle, as: RemoveDanmakuTrackFn.self)
    setDanmakuTrackEnabled = Self.loadOptional("erika_presenter_set_danmaku_track_enabled", from: libraryHandle, as: SetDanmakuTrackEnabledFn.self)
    setDanmakuTrackOffset = Self.loadOptional("erika_presenter_set_danmaku_track_offset", from: libraryHandle, as: SetDanmakuTrackOffsetFn.self)
    setDanmakuGlobalOffset = Self.loadOptional("erika_presenter_set_danmaku_global_offset", from: libraryHandle, as: SetDanmakuGlobalOffsetFn.self)
    danmakuTracks = Self.loadOptional("erika_presenter_danmaku_tracks", from: libraryHandle, as: TracksFn.self)
    clearDanmaku = Self.loadOptional("erika_presenter_clear_danmaku", from: libraryHandle, as: ClearDanmakuFn.self)
    setDanmakuEnabled = Self.loadOptional("erika_presenter_set_danmaku_enabled", from: libraryHandle, as: SetDanmakuEnabledFn.self)
    setDebugHudEnabled = Self.loadOptional("erika_presenter_set_debug_hud_enabled", from: libraryHandle, as: SetDebugHudEnabledFn.self)
    setDanmakuConfig = Self.loadOptional("erika_presenter_set_danmaku_config_ptr", from: libraryHandle, as: SetDanmakuConfigFn.self)
    getDanmakuConfig = Self.loadOptional("erika_presenter_get_danmaku_config", from: libraryHandle, as: GetDanmakuConfigFn.self)
    setDanmakuFont = Self.loadOptional("erika_presenter_set_danmaku_font", from: libraryHandle, as: SetDanmakuFontFn.self)
    setDanmakuBlockWords = Self.loadOptional("erika_presenter_set_danmaku_block_words_json", from: libraryHandle, as: SetDanmakuBlockWordsFn.self)
    trackSelection = try Self.load("erika_presenter_track_selection", from: libraryHandle, as: TrackSelectionFn.self)
    tracks = try Self.load("erika_presenter_tracks", from: libraryHandle, as: TracksFn.self)
    freeTrackInfo = try Self.load("erika_track_info_free", from: libraryHandle, as: TrackInfoFreeFn.self)
    freeDanmakuTrackInfo = Self.loadOptional("erika_danmaku_track_info_free", from: libraryHandle, as: DanmakuTrackInfoFreeFn.self)
    attachMetalLayer = try Self.load("erika_presenter_attach_metal_layer", from: libraryHandle, as: AttachMetalLayerFn.self)
    resizeSurface = try Self.load("erika_presenter_resize_surface", from: libraryHandle, as: ResizeSurfaceFn.self)
    detachSurface = try Self.load("erika_presenter_detach_surface", from: libraryHandle, as: CommandFn.self)
    renderTick = try Self.load("erika_presenter_render_tick", from: libraryHandle, as: RenderTickFn.self)
    audioOnlyTick = try Self.load("erika_presenter_audio_only_tick", from: libraryHandle, as: AudioOnlyTickFn.self)
    captureFrameRgba = Self.loadOptional("erika_presenter_capture_frame_rgba", from: libraryHandle, as: CaptureFrameRgbaFn.self)
    pollEvent = try Self.load("erika_presenter_poll_event", from: libraryHandle, as: PollEventFn.self)
    lastErrorMessage = try Self.load("erika_last_error_message", from: libraryHandle, as: LastErrorMessageFn.self)
    stringFree = try Self.load("erika_string_free", from: libraryHandle, as: StringFreeFn.self)
  }

  private static func openLibrary() throws -> (handle: UnsafeMutableRawPointer, path: String) {
    var failures: [ErikaPluginError] = []
    if let handle = dlopen(nil, RTLD_NOW), dlsym(handle, "erika_presenter_create") != nil {
      return (handle, "main executable")
    }

    var candidates: [String] = []
    let environment = ProcessInfo.processInfo.environment
    if let override = environment["ERIKA_CAPI_DYLIB"], !override.isEmpty {
      candidates.append(override)
    }
    let bundle = Bundle(for: ErikaFlutterPlugin.self)
    if let pluginExecutable = bundle.executablePath {
      candidates.append(pluginExecutable)
    }
    if let resourcePath = bundle.path(forResource: "liberika_capi", ofType: "dylib") {
      candidates.append(resourcePath)
    }
    if let frameworksPath = Bundle.main.privateFrameworksPath {
      candidates.append(URL(fileURLWithPath: frameworksPath).appendingPathComponent("liberika_capi.dylib").path)
    }
    if let executablePath = Bundle.main.executablePath {
      let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
      candidates.append(URL(fileURLWithPath: executableDirectory).appendingPathComponent("liberika_capi.dylib").path)
    }

    for path in candidates {
      if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
        if dlsym(handle, "erika_presenter_create") != nil {
          return (handle, path)
        }
        dlclose(handle)
        failures.append(.libraryLoadFailed(path, "erika_presenter_create not found"))
        continue
      }
      let detail = dlerror().map { String(cString: $0) }
      failures.append(.libraryLoadFailed(path, detail))
    }
    throw ErikaPluginError.libraryNotFound(failures.map(String.init(describing:)))
  }

  private static func load<T>(_ symbol: String, from handle: UnsafeMutableRawPointer, as type: T.Type) throws -> T {
    guard let raw = dlsym(handle, symbol) else {
      throw ErikaPluginError.symbolMissing(symbol)
    }
    return unsafeBitCast(raw, to: type)
  }

  private static func loadOptional<T>(_ symbol: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
    guard let raw = dlsym(handle, symbol) else {
      return nil
    }
    return unsafeBitCast(raw, to: type)
  }

  func createPresenter(config: ErikaPresenterConfigC) -> UnsafeMutableRawPointer? {
    if let createWithOutputMode {
      return createWithOutputMode(config.outputMode, config.edrHeadroom)
    }
    return create()
  }

  func currentEventMessage() -> String? {
    guard let pointer = lastErrorMessage() else {
      return nil
    }
    defer { stringFree(pointer) }
    return String(validatingUTF8: pointer)
  }
}

private final class ErikaPlayerHost {
  let id: Int64

  private let library: ErikaNativeLibrary
  private let handle: UnsafeMutableRawPointer
  private let renderQueue: DispatchQueue
  private let nativeCallLock = NSRecursiveLock()
  private let renderSubmissionLock = NSLock()
  private weak var attachedView: ErikaMetalSurfaceView?
  private var displayLink: CADisplayLink?
  private var displayLinkProxy: DisplayLinkProxy?
  private var startTimeSeconds: CFTimeInterval = CACurrentMediaTime()
  private var currentDanmakuConfig = ErikaDanmakuConfigC()
  private let hdrDebug: Bool
  private let presenterConfig: ErikaPresenterConfigC
  private let allowBackgroundPlayback: Bool
  private var loggedRenderThread = false
  private var loggedFirstRenderedVideoFrame = false
  private var latestPresenterStats = ErikaPresenterStatsC()
  private var fallbackTimer: DispatchSourceTimer?
  private var renderTickQueued = false
  private var isAppInBackground = false
  private(set) var nowPlayingTitle = ""
  private(set) var nowPlayingArtist: String?
  private(set) var nowPlayingAlbum: String?
  private(set) var nowPlayingArtwork: MPMediaItemArtwork?
  private(set) var durationSeconds: Double?
  private(set) var positionSeconds = 0.0
  private(set) var playbackRate = 1.0
  private(set) var isPlaying = false
  var onNowPlayingChanged: ((ErikaPlayerHost) -> Void)?

  init(
    id: Int64,
    library: ErikaNativeLibrary,
    config: ErikaPresenterConfigC,
    hdrDebug: Bool,
    allowBackgroundPlayback: Bool
  ) throws {
    self.id = id
    self.library = library
    self.hdrDebug = hdrDebug
    self.allowBackgroundPlayback = allowBackgroundPlayback
    renderQueue = DispatchQueue(
      label: "dev.aimesoft.erika.render.ios.\(id)",
      qos: .userInteractive
    )
    presenterConfig = config
    guard let handle = library.createPresenter(config: config) else {
      throw ErikaPluginError.presenterCreateFailed
    }
    self.handle = handle
    erikaHdrLog(
      hdrDebug,
      "created presenter player=\(id) mode=\(erikaOutputModeLabel(config)) library=\(library.path) createWithOutputMode=\(library.createWithOutputMode != nil)"
    )
  }

  deinit {
    displayLink?.invalidate()
    fallbackTimer?.cancel()
    withNativeCall {
      _ = library.detachSurface(handle)
      library.destroy(handle)
    }
  }

  private func withNativeCall<T>(_ operation: () throws -> T) rethrows -> T {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    return try operation()
  }

  func open(uri: String, httpHeaders: [String: String]) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    isPlaying = false
    positionSeconds = 0
    durationSeconds = nil
    if nowPlayingTitle.isEmpty {
      let fallbackTitle = URL(string: uri)?.lastPathComponent.removingPercentEncoding
        ?? URL(fileURLWithPath: uri).lastPathComponent
      nowPlayingTitle = fallbackTitle.isEmpty ? "Erika" : fallbackTitle
    }
    try uri.withCString { cString in
      guard !httpHeaders.isEmpty else {
        try check(library.open(handle, cString), operation: "open")
        return
      }
      // Never fall back to the headerless entry point here: silently dropping
      // the headers turns an authenticated stream into an opaque 403.
      guard let openWithHeaders = library.openWithHeaders else {
        throw ErikaPluginError.httpHeadersUnsupported
      }
      let names = httpHeaders.keys.map { strdup($0) }
      let values = httpHeaders.values.map { strdup($0) }
      defer {
        names.forEach { free($0) }
        values.forEach { free($0) }
      }
      let headers = zip(names, values).map { ErikaHttpHeader(name: $0.0, value: $0.1) }
      try headers.withUnsafeBufferPointer { buffer in
        try check(openWithHeaders(handle, cString, buffer.baseAddress.map(UnsafeRawPointer.init), UInt(headers.count)), operation: "open")
      }
    }
    notifyNowPlayingChanged()
  }

  func play() throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try configureAudioSessionForPlayback()
    try check(library.play(handle), operation: "play")
    isPlaying = true
    updateTickDriver()
    notifyNowPlayingChanged()
  }
  func pause() throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.pause(handle), operation: "pause")
    isPlaying = false
    updateTickDriver()
    notifyNowPlayingChanged()
  }
  func stop() throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.stop(handle), operation: "stop")
    isPlaying = false
    positionSeconds = 0
    updateTickDriver()
    notifyNowPlayingChanged()
  }
  func close() throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.close(handle), operation: "close")
    isPlaying = false
    positionSeconds = 0
    durationSeconds = nil
    updateTickDriver()
    notifyNowPlayingChanged()
  }

  func seek(positionMicros: UInt64) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.seek(handle, positionMicros), operation: "seek")
    positionSeconds = Double(positionMicros) / 1_000_000
    notifyNowPlayingChanged()
  }

  func setPlaybackRate(_ rate: Double) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setRate = library.setPlaybackRate else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_playback_rate")
    }
    try check(setRate(handle, rate), operation: "set_playback_rate")
    playbackRate = rate
    notifyNowPlayingChanged()
  }

  func setMediaMetadata(title: String, artist: String?, album: String?, artworkData: Data?) throws {
    let artwork: MPMediaItemArtwork?
    if let artworkData {
      guard let image = UIImage(data: artworkData) else {
        throw ErikaPluginError.invalidArguments("metadata.artwork must contain a supported image.")
      }
      artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    } else {
      artwork = nil
    }
    nowPlayingTitle = title
    nowPlayingArtist = artist
    nowPlayingAlbum = album
    nowPlayingArtwork = artwork
    notifyNowPlayingChanged()
  }

  func clearMediaMetadata() {
    nowPlayingTitle = ""
    nowPlayingArtist = nil
    nowPlayingAlbum = nil
    nowPlayingArtwork = nil
    notifyNowPlayingChanged()
  }

  func setAppInBackground(_ value: Bool) {
    isAppInBackground = value
    updateTickDriver()
  }

  func prepareForInactiveApp() {
    setAppInBackground(true)
    scheduleTick(audioOnly: true)
  }

  func didEnterBackground() {
    setAppInBackground(true)
    if !allowBackgroundPlayback && isPlaying {
      try? pause()
    }
  }

  func setVolume(_ volume: Double) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setVolume = library.setVolume else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_volume")
    }
    let clampedVolume = volume.isFinite ? min(max(volume, 0.0), 1.0) : 1.0
    try check(setVolume(handle, clampedVolume), operation: "set_volume")
  }

  func setUpscaler(mode: Int32) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setUpscaler = library.setUpscaler else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_upscaler")
    }
    try check(setUpscaler(handle, mode), operation: "set_upscaler")
  }

  func setSubtitleScale(_ scale: Double) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setSubtitleScale = library.setSubtitleScale else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_subtitle_scale")
    }
    let clampedScale = scale.isFinite ? min(max(scale, 0.25), 4.0) : 1.0
    try check(setSubtitleScale(handle, clampedScale), operation: "set_subtitle_scale")
  }

  func setSubtitleFont(family: String?, filePath: String?) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setSubtitleFont = library.setSubtitleFont else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_subtitle_font")
    }
    let status = withOptionalCString(family ?? "") { familyCString in
      withOptionalCString(filePath ?? "") { filePathCString in
        setSubtitleFont(handle, familyCString, filePathCString)
      }
    }
    try check(status, operation: "set_subtitle_font")
  }

  func setSubtitleStyle(
    fontFamily: String?,
    fontFilePath: String?,
    primaryRgba: UInt32,
    outlineRgba: UInt32,
    fontSize: Double,
    outlineWidth: Double,
    bold: Bool,
    italic: Bool,
    underline: Bool,
    strikeOut: Bool,
    spacing: Double,
    scaleXPercent: Double,
    scaleYPercent: Double,
    borderStyle: Int32,
    shadowDepth: Double,
    blur: Double,
    alignment: Int32,
    marginLeft: Int32,
    marginRight: Int32,
    marginVertical: Int32,
    overrideMask: UInt32
  ) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setSubtitleStyle = library.setSubtitleStyle else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_subtitle_style")
    }
    let status = withOptionalCString(fontFamily ?? "") { fontFamilyCString in
      withOptionalCString(fontFilePath ?? "") { fontFilePathCString in
        var style = ErikaSubtitleStyleC(
          fontFamily: fontFamilyCString,
          fontFilePath: fontFilePathCString,
          primaryColorRgba: primaryRgba,
          outlineColorRgba: outlineRgba,
          fontSize: fontSize,
          outlineWidth: outlineWidth,
          bold: bold,
          italic: italic,
          underline: underline,
          strikeOut: strikeOut,
          spacing: spacing,
          scaleXPercent: scaleXPercent,
          scaleYPercent: scaleYPercent,
          borderStyle: borderStyle,
          shadowDepth: shadowDepth,
          blur: blur,
          alignment: alignment,
          marginLeft: marginLeft,
          marginRight: marginRight,
          marginVertical: marginVertical,
          overrideMask: overrideMask
        )
        return withUnsafePointer(to: &style) { pointer in
          setSubtitleStyle(handle, UnsafeRawPointer(pointer))
        }
      }
    }
    try check(status, operation: "set_subtitle_style")
  }

  func upscalerStatus() throws -> [String: Any] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let getStatus = library.getUpscalerStatus else {
      throw ErikaPluginError.symbolMissing("erika_presenter_get_upscaler_status")
    }
    var status = ErikaUpscalerStatusC()
    let result = withUnsafeMutablePointer(to: &status) { pointer in
      getStatus(handle, UnsafeMutableRawPointer(pointer))
    }
    try check(result, operation: "get_upscaler_status")
    return status.toFlutterMap()
  }

  func registerSubtitleMemoryFont(_ data: Data) throws -> UInt64 {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let register = library.registerSubtitleMemoryFont else {
      throw ErikaPluginError.symbolMissing("erika_presenter_register_subtitle_memory_font")
    }
    var fontId: UInt64 = 0
    let status = data.withUnsafeBytes { bytes in
      register(handle, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count), &fontId)
    }
    try check(status, operation: "register_subtitle_memory_font")
    return fontId
  }

  func selectSubtitleMemoryFonts(_ fontIds: [UInt64]) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let select = library.selectSubtitleMemoryFonts else {
      throw ErikaPluginError.symbolMissing("erika_presenter_select_subtitle_memory_fonts")
    }
    try fontIds.withUnsafeBufferPointer { buffer in
      try check(select(handle, buffer.baseAddress, UInt(buffer.count)), operation: "select_subtitle_memory_fonts")
    }
  }

  func clearSubtitleMemoryFonts() throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let clear = library.clearSubtitleMemoryFonts else {
      throw ErikaPluginError.symbolMissing("erika_presenter_clear_subtitle_memory_fonts")
    }
    try check(clear(handle), operation: "clear_subtitle_memory_fonts")
  }

  func subtitleMemoryFontStatus() throws -> [String: Any] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let getStatus = library.getSubtitleMemoryFontStatus else {
      throw ErikaPluginError.symbolMissing("erika_presenter_get_subtitle_memory_font_status")
    }
    var status = ErikaSubtitleMemoryFontStatusC()
    defer {
      if let freeStatus = library.freeSubtitleMemoryFontStatus {
        withUnsafeMutablePointer(to: &status) { freeStatus(UnsafeMutableRawPointer($0)) }
      }
    }
    try withUnsafeMutablePointer(to: &status) { pointer in
      try check(getStatus(handle, UnsafeMutableRawPointer(pointer)), operation: "get_subtitle_memory_font_status")
    }
    return [
      "registeredCount": Int(status.registeredCount),
      "registeredBytes": Int(status.registeredBytes),
      "selectedCount": Int(status.selectedCount),
      "generation": Int64(clamping: status.generation),
      "selectedIds": status.selectedIds.map { pointer in
        (0..<Int(status.selectedCount)).map { Int64(clamping: pointer[$0]) }
      } ?? [],
    ]
  }

  func outputStatus() throws -> [String: Any] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let getStatus = library.getOutputStatus else {
      throw ErikaPluginError.symbolMissing("erika_presenter_get_output_status")
    }
    var status = ErikaOutputStatusC()
    let result = withUnsafeMutablePointer(to: &status) { pointer in
      getStatus(handle, UnsafeMutableRawPointer(pointer))
    }
    try check(result, operation: "get_output_status")
    return status.toFlutterMap()
  }

  func resourceStatus() throws -> [String: Any] {
    guard let getStatus = library.getResourceStatus else {
      throw ErikaPluginError.symbolMissing("erika_presenter_get_resource_status")
    }
    var status = ErikaPresenterResourceStatusC()
    let result = withNativeCall {
      withUnsafeMutablePointer(to: &status) { pointer in
        getStatus(handle, UnsafeMutableRawPointer(pointer))
      }
    }
    try check(result, operation: "get_resource_status")
    return status.toFlutterMap()
  }

  func presenterStats() -> [String: Any] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    return latestPresenterStats.toFlutterMap()
  }

  func addExternalSubtitle(uri: String) throws -> Int64 {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    var trackId: Int64 = 0
    try uri.withCString { cString in
      try check(library.addExternalSubtitle(handle, cString, &trackId), operation: "add_external_subtitle")
    }
    return trackId
  }

  func removeSubtitleTrack(trackId: Int64) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.removeSubtitleTrack(handle, trackId), operation: "remove_subtitle_track")
  }

  func loadDanmakuFile(uri: String) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let load = library.loadDanmakuFile else {
      throw ErikaPluginError.symbolMissing("erika_presenter_load_danmaku_file")
    }
    try uri.withCString { cString in
      try check(load(handle, cString), operation: "load_danmaku_file")
    }
  }

  func loadDanmakuJson(_ json: String) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let load = library.loadDanmakuJson else {
      throw ErikaPluginError.symbolMissing("erika_presenter_load_danmaku_json")
    }
    try json.withCString { cString in
      try check(load(handle, cString), operation: "load_danmaku_json")
    }
  }

  func addDanmakuTrackFile(uri: String, name: String?, offsetMicros: Int64) throws -> UInt64 {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let add = library.addDanmakuTrackFile else {
      throw ErikaPluginError.symbolMissing("erika_presenter_add_danmaku_track_file")
    }
    var trackId: UInt64 = 0
    let status = uri.withCString { uriCString in
      withOptionalCString(name) { nameCString in
        add(handle, uriCString, nameCString, offsetMicros, &trackId)
      }
    }
    try check(status, operation: "add_danmaku_track_file")
    return trackId
  }

  func addDanmakuTrackJson(_ json: String, name: String?, offsetMicros: Int64) throws -> UInt64 {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let add = library.addDanmakuTrackJson else {
      throw ErikaPluginError.symbolMissing("erika_presenter_add_danmaku_track_json")
    }
    var trackId: UInt64 = 0
    let status = json.withCString { jsonCString in
      withOptionalCString(name) { nameCString in
        add(handle, jsonCString, nameCString, offsetMicros, &trackId)
      }
    }
    try check(status, operation: "add_danmaku_track_json")
    return trackId
  }

  func removeDanmakuTrack(trackId: UInt64) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let remove = library.removeDanmakuTrack else {
      throw ErikaPluginError.symbolMissing("erika_presenter_remove_danmaku_track")
    }
    try check(remove(handle, trackId), operation: "remove_danmaku_track")
  }

  func setDanmakuTrackEnabled(trackId: UInt64, enabled: Bool) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setEnabled = library.setDanmakuTrackEnabled else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_track_enabled")
    }
    try check(setEnabled(handle, trackId, enabled), operation: "set_danmaku_track_enabled")
  }

  func setDanmakuTrackOffset(trackId: UInt64, offsetMicros: Int64) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setOffset = library.setDanmakuTrackOffset else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_track_offset")
    }
    try check(setOffset(handle, trackId, offsetMicros), operation: "set_danmaku_track_offset")
  }

  func setDanmakuGlobalOffset(offsetMicros: Int64) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setOffset = library.setDanmakuGlobalOffset else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_global_offset")
    }
    try check(setOffset(handle, offsetMicros), operation: "set_danmaku_global_offset")
  }

  func danmakuTracks() throws -> [[String: Any]] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let danmakuTracks = library.danmakuTracks else {
      throw ErikaPluginError.symbolMissing("erika_presenter_danmaku_tracks")
    }
    var count: Int = 0
    try check(danmakuTracks(handle, nil, 0, &count), operation: "danmaku_tracks_len")
    if count <= 0 { return [] }
    var tracks = Array(repeating: ErikaDanmakuTrackInfoC(), count: count)
    var written: Int = 0
    let status = tracks.withUnsafeMutableBufferPointer { buffer in
      danmakuTracks(handle, UnsafeMutableRawPointer(buffer.baseAddress), buffer.count, &written)
    }
    try check(status, operation: "danmaku_tracks")
    let result = tracks.prefix(min(written, tracks.count)).map { $0.toFlutterMap() }
    if let free = library.freeDanmakuTrackInfo {
      for index in tracks.indices {
        withUnsafeMutablePointer(to: &tracks[index]) { pointer in
          free(UnsafeMutableRawPointer(pointer))
        }
      }
    }
    return result
  }

  func clearDanmaku() throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let clear = library.clearDanmaku else {
      throw ErikaPluginError.symbolMissing("erika_presenter_clear_danmaku")
    }
    try check(clear(handle), operation: "clear_danmaku")
  }

  func setDanmakuEnabled(_ enabled: Bool) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setEnabled = library.setDanmakuEnabled else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_enabled")
    }
    try check(setEnabled(handle, enabled), operation: "set_danmaku_enabled")
    currentDanmakuConfig.enabled = enabled ? 1 : 0
  }

  func setDebugHudEnabled(_ enabled: Bool) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setEnabled = library.setDebugHudEnabled else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_debug_hud_enabled")
    }
    try check(setEnabled(handle, enabled), operation: "set_debug_hud_enabled")
  }

  func danmakuConfigSnapshot() -> ErikaDanmakuConfigC {
    currentDanmakuConfig
  }

  private func refreshDanmakuConfigSnapshot() {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let getConfig = library.getDanmakuConfig else {
      return
    }
    var config = ErikaDanmakuConfigC()
    let status = withUnsafeMutablePointer(to: &config) { pointer in
      getConfig(handle, UnsafeMutableRawPointer(pointer))
    }
    if status == 0 {
      currentDanmakuConfig = config
    }
  }

  func setDanmakuConfig(_ config: ErikaDanmakuConfigC) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setConfig = library.setDanmakuConfig else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_config_ptr")
    }
    var config = config
    let status = withUnsafePointer(to: &config) { pointer in
      setConfig(handle, UnsafeRawPointer(pointer))
    }
    try check(status, operation: "set_danmaku_config")
    currentDanmakuConfig = config
  }

  func setDanmakuFont(family: String?, filePath: String?) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setFont = library.setDanmakuFont else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_font")
    }
    let status = withOptionalCString(family ?? "") { familyCString in
      withOptionalCString(filePath ?? "") { filePathCString in
        setFont(handle, familyCString, filePathCString)
      }
    }
    try check(status, operation: "set_danmaku_font")
    refreshDanmakuConfigSnapshot()
  }

  func setDanmakuBlockWordsJson(_ json: String) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard let setBlockWords = library.setDanmakuBlockWords else {
      throw ErikaPluginError.symbolMissing("erika_presenter_set_danmaku_block_words_json")
    }
    try json.withCString { cString in
      try check(setBlockWords(handle, cString), operation: "set_danmaku_block_words")
    }
    refreshDanmakuConfigSnapshot()
  }

  func selectAudioTrack(trackId: Int64?) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.selectAudioTrack(handle, trackId ?? -1), operation: "select_audio_track")
  }

  func selectSubtitleTrack(trackId: Int64?) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    try check(library.selectSubtitleTrack(handle, trackId ?? -1), operation: "select_subtitle_track")
  }

  func tracks() throws -> [[String: Any]] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    var count: Int = 0
    try check(library.tracks(handle, nil, 0, &count), operation: "tracks_len")
    if count <= 0 { return [] }
    var tracks = Array(repeating: ErikaTrackInfoC(), count: count)
    var written: Int = 0
    let status = tracks.withUnsafeMutableBufferPointer { buffer in
      library.tracks(handle, UnsafeMutableRawPointer(buffer.baseAddress), buffer.count, &written)
    }
    try check(status, operation: "tracks")
    let result = tracks.prefix(min(written, tracks.count)).map { $0.toFlutterMap() }
    for index in tracks.indices {
      withUnsafeMutablePointer(to: &tracks[index]) { pointer in
        library.freeTrackInfo(UnsafeMutableRawPointer(pointer))
      }
    }
    return result
  }

  func trackSelection() throws -> [String: Any] {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    var selection = ErikaTrackSelectionC()
    let status = withUnsafeMutablePointer(to: &selection) { pointer in
      library.trackSelection(handle, UnsafeMutableRawPointer(pointer))
    }
    try check(status, operation: "track_selection")
    return selection.toFlutterMap()
  }

  func captureFrameRgba(width: Int, height: Int) -> Data? {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    guard width > 0, height > 0, let captureFrameRgba = library.captureFrameRgba else {
      return nil
    }
    let byteCount = width * height * 4
    var data = Data(count: byteCount)
    let status = data.withUnsafeMutableBytes { buffer in
      captureFrameRgba(
        handle,
        UInt32(width),
        UInt32(height),
        buffer.baseAddress,
        byteCount
      )
    }
    guard status == 0 else {
      NSLog("Erika: captureFrameRgba failed with status \(status)")
      return nil
    }
    return data
  }

  func screenshot(view: ErikaMetalSurfaceView? = nil, width: Int? = nil, height: Int? = nil) -> Data? {
    if let width, let height, let data = captureFrameRgba(width: width, height: height) {
      return data
    }
    return (view ?? attachedView)?.pngSnapshotData()
  }

  func attach(view: ErikaMetalSurfaceView) throws {
    attachedView = view
    view.attachedPlayerId = id
    try attachOrResize(view: view, attach: true)
    startDisplayLinkIfNeeded()
    updateTickDriver()
  }

  func detach(viewId: Int64?) {
    guard viewId == nil || attachedView?.platformViewId == viewId else { return }
    attachedView?.attachedPlayerId = nil
    attachedView = nil
    displayLink?.invalidate()
    displayLink = nil
    displayLinkProxy = nil
    withNativeCall {
      _ = library.detachSurface(handle)
    }
    updateTickDriver()
  }

  func resizeFromAttachedView() {
    guard let view = attachedView else { return }
    do {
      try attachOrResize(view: view, attach: false)
    } catch {
      NSLog("ErikaFlutterPlugin: resize failed: \(error)")
    }
  }

  func renderTick() {
    if !loggedRenderThread {
      loggedRenderThread = true
      erikaHdrLog(
        hdrDebug,
        "render driver player=\(id) mainThread=\(Thread.isMainThread)"
      )
    }
    var stats = ErikaPresenterStatsC()
    let status = withNativeCall {
      let timeSeconds = CACurrentMediaTime() - startTimeSeconds
      let status = withUnsafeMutablePointer(to: &stats) { pointer in
        library.renderTick(handle, timeSeconds, UnsafeMutableRawPointer(pointer))
      }
      if status == 0 {
        latestPresenterStats = stats
      }
      return status
    }
    if status != 0 {
      NSLog("ErikaFlutterPlugin: render_tick failed with status \(status)")
    }
    if hdrDebug && stats.renderedVideoFrames > 0 {
      let statsSnapshot = stats
      DispatchQueue.main.async { [weak self] in
        self?.logFirstRenderedVideoFrameIfNeeded(statsSnapshot)
      }
    }
  }

  func audioOnlyTick() {
    var stats = ErikaPresenterStatsC()
    let status = withNativeCall {
      let status = withUnsafeMutablePointer(to: &stats) { pointer in
        library.audioOnlyTick(handle, UnsafeMutableRawPointer(pointer))
      }
      if status == 0 {
        latestPresenterStats = stats
      }
      return status
    }
    if status != 0 {
      NSLog("ErikaFlutterPlugin: audio_only_tick failed with status \(status)")
    }
  }

  func pollEvents(sendEvent: (([String: Any]) -> Void)?) {
    withNativeCall {
      while true {
        var event = ErikaEventC()
        let status = withUnsafeMutablePointer(to: &event) { pointer in
          library.pollEvent(handle, UnsafeMutableRawPointer(pointer))
        }
        if status == 0 {
          if event.durationMicros >= 0 {
            durationSeconds = Double(event.durationMicros) / 1_000_000
          }
          if event.kind == 3 {
            positionSeconds = Double(event.positionMicros) / 1_000_000
          }
          if event.kind == 1 {
            isPlaying = event.state == 3
            updateTickDriver()
          }
          if event.kind == 1 || event.kind == 2 || event.kind == 3 {
            notifyNowPlayingChanged()
          }
          if event.kind == 6 {
            erikaHdrLog(
              hdrDebug,
              "video params player=\(id) width=\(event.video.width) height=\(event.video.height) primaries=\(event.video.primaries) transfer=\(event.video.transfer)"
            )
          }
          let message = event.kind == 9 || event.kind == 11 || event.kind == 12
            ? library.currentEventMessage()
            : nil
          sendEvent?(event.toFlutterMap(playerId: id, host: self, structuredMessage: message))
          continue
        }
        if status != 5 {
          NSLog("ErikaFlutterPlugin: poll_event failed with status \(status)")
        }
        break
      }
    }
  }

  private func scheduleTick(audioOnly: Bool = false) {
    renderSubmissionLock.lock()
    guard !renderTickQueued else {
      renderSubmissionLock.unlock()
      return
    }
    renderTickQueued = true
    renderSubmissionLock.unlock()

    renderQueue.async { [weak self] in
      guard let self else { return }
      if audioOnly {
        self.audioOnlyTick()
      } else {
        self.renderTick()
      }
      self.renderSubmissionLock.lock()
      self.renderTickQueued = false
      self.renderSubmissionLock.unlock()
    }
  }

  private func logFirstRenderedVideoFrameIfNeeded(_ stats: ErikaPresenterStatsC) {
    guard hdrDebug, !loggedFirstRenderedVideoFrame else { return }
    loggedFirstRenderedVideoFrame = true
    let layer = attachedView.map { erikaLayerSummary($0.metalLayer) } ?? "layer=nil"
    let screen = erikaScreenSummary(attachedView?.window?.screen ?? UIScreen.main)
    erikaHdrLog(
      true,
      "first rendered frame player=\(id) mode=\(erikaOutputModeLabel(presenterConfig)) decoded=\(stats.decodedVideoFrames) rendered=\(stats.renderedVideoFrames) test=\(stats.renderedTestFrames) \(screen) \(layer)"
    )
  }

  private func attachOrResize(view: ErikaMetalSurfaceView, attach: Bool) throws {
    nativeCallLock.lock()
    defer { nativeCallLock.unlock() }
    if attach || presenterConfig.outputMode != 3 {
      erikaConfigureLayerDynamicRange(view.metalLayer, config: presenterConfig)
    }
    view.updateDrawableSize()
    let width = UInt32(max(1.0, view.metalLayer.drawableSize.width).rounded())
    let height = UInt32(max(1.0, view.metalLayer.drawableSize.height).rounded())
    let scale = view.currentScale
    if attach {
      let rawLayer = UInt64(UInt(bitPattern: Unmanaged.passUnretained(view.metalLayer).toOpaque()))
      try check(library.attachMetalLayer(handle, rawLayer, width, height, scale), operation: "attach_metal_layer")
      erikaHdrLog(
        hdrDebug,
        "attached layer player=\(id) view=\(view.platformViewId) physical=\(width)x\(height) scale=\(String(format: "%.3f", scale)) \(erikaScreenSummary(view.window?.screen ?? UIScreen.main)) \(erikaLayerSummary(view.metalLayer))"
      )
    } else {
      try check(library.resizeSurface(handle, width, height, scale), operation: "resize_surface")
      erikaHdrLog(
        hdrDebug,
        "resized layer player=\(id) view=\(view.platformViewId) physical=\(width)x\(height) scale=\(String(format: "%.3f", scale)) \(erikaLayerSummary(view.metalLayer))"
      )
    }
  }

  private func startDisplayLinkIfNeeded() {
    guard displayLink == nil, attachedView != nil, !isAppInBackground else { return }
    withNativeCall {
      startTimeSeconds = CACurrentMediaTime()
    }
    let proxy = DisplayLinkProxy { [weak self] in
      self?.scheduleTick()
    }
    let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
    link.preferredFramesPerSecond = resolvedDisplayLinkFps()
    link.add(to: .main, forMode: .common)
    displayLinkProxy = proxy
    displayLink = link
  }

  private func updateTickDriver() {
    if isAppInBackground || (attachedView == nil && isPlaying) {
      displayLink?.invalidate()
      displayLink = nil
      displayLinkProxy = nil
      startFallbackTimerIfNeeded()
    } else {
      fallbackTimer?.cancel()
      fallbackTimer = nil
      startDisplayLinkIfNeeded()
    }
  }

  private func startFallbackTimerIfNeeded() {
    guard fallbackTimer == nil, isPlaying else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if self.isAppInBackground {
        self.scheduleTick(audioOnly: true)
      } else {
        self.scheduleTick()
      }
    }
    fallbackTimer = timer
    timer.resume()
  }

  private func notifyNowPlayingChanged() {
    onNowPlayingChanged?(self)
  }

  private func resolvedDisplayLinkFps() -> Int {
    if let override = ProcessInfo.processInfo.environment["ERIKA_FLUTTER_TARGET_FPS"],
       let fps = Int(override), fps > 0 {
      return min(max(fps, 1), 1000)
    }
    let fps = attachedView?.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
    return fps > 0 ? fps : erikaDefaultDisplayFps
  }

  private func check(_ status: Int32, operation: String) throws {
    if status != 0 {
      throw ErikaPluginError.erikaStatus(operation, status)
    }
  }

  private func configureAudioSessionForPlayback() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .moviePlayback, options: [])
    try session.setActive(true)
  }
}

private final class DisplayLinkProxy: NSObject {
  private let body: () -> Void

  init(_ body: @escaping () -> Void) {
    self.body = body
  }

  @objc func tick() {
    body()
  }
}

private protocol ErikaMetalSurfaceView: AnyObject {
  var platformViewId: Int64 { get }
  var metalLayer: CAMetalLayer { get }
  var attachedPlayerId: Int64? { get set }
  var bounds: CGRect { get }
  var window: UIWindow? { get }
  var currentScale: Double { get }

  func updateDrawableSize()
  func pngSnapshotData() -> Data?
}

private final class WeakErikaVideoPlatformViewBox {
  weak var view: ErikaMetalSurfaceView?

  init(view: ErikaMetalSurfaceView) {
    self.view = view
  }
}

private final class ErikaMetalUIView: UIView, ErikaMetalSurfaceView {
  let platformViewId: Int64
  weak var plugin: ErikaFlutterPlugin?
  var attachedPlayerId: Int64?

  override class var layerClass: AnyClass { CAMetalLayer.self }

  var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

  var currentScale: Double {
    Double(max(1.0, window?.screen.scale ?? UIScreen.main.scale))
  }

  init(frame: CGRect, viewId: Int64, arguments: Any?, plugin: ErikaFlutterPlugin?) {
    platformViewId = viewId
    self.plugin = plugin
    super.init(frame: frame)
    isOpaque = true
    isUserInteractionEnabled = false
    backgroundColor = .black
    contentScaleFactor = CGFloat(currentScale)
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.isOpaque = true
    metalLayer.backgroundColor = UIColor.black.cgColor
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    plugin?.unregisterView(viewId: platformViewId)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateDrawableSize()
    plugin?.resizePlayerAttachedToView(viewId: platformViewId)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateDrawableSize()
    plugin?.resizePlayerAttachedToView(viewId: platformViewId)
  }

  func updateDrawableSize() {
    let scale = CGFloat(currentScale)
    contentScaleFactor = scale
    metalLayer.contentsScale = scale
    // metalLayer is this view's *backing* layer (layerClass == CAMetalLayer);
    // UIKit already syncs its frame to the view. Setting it to `bounds` would
    // move the backing layer to the superlayer origin, rendering the video at
    // (0,0) instead of the view's frame (visible once the view isn't full-screen).
    metalLayer.drawableSize = CGSize(
      width: max(1.0, bounds.width * scale),
      height: max(1.0, bounds.height * scale)
    )
  }

  func pngSnapshotData() -> Data? {
    snapshotPngData(of: self)
  }
}

private final class ErikaWindowOverlayView: UIView, ErikaMetalSurfaceView {
  let platformViewId: Int64 = erikaWindowHostedVideoSurfaceId
  weak var plugin: ErikaFlutterPlugin?
  var attachedPlayerId: Int64?

  private var overlayFrameGeneration: Int64?
  private var debugLabelView: UILabel?

  /// Generation of the widget that currently owns this shared overlay surface.
  /// Used to reject stale detach calls from disposed widgets.
  var activeGeneration: Int64? { overlayFrameGeneration }

  override class var layerClass: AnyClass { CAMetalLayer.self }

  var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

  var currentScale: Double {
    Double(max(1.0, window?.screen.scale ?? UIScreen.main.scale))
  }

  init(plugin: ErikaFlutterPlugin?) {
    self.plugin = plugin
    super.init(frame: .zero)
    isOpaque = true
    isHidden = true
    isUserInteractionEnabled = false
    backgroundColor = .black
    contentScaleFactor = CGFloat(currentScale)
    autoresizingMask = []
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.isOpaque = true
    metalLayer.backgroundColor = UIColor.black.cgColor
    layer.actions = [
      "bounds": NSNull(),
      "frame": NSNull(),
      "position": NSNull(),
    ]
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    plugin?.detachOverlayView(self)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateDrawableSize()
    plugin?.resizePlayerAttachedToView(viewId: platformViewId)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateDrawableSize()
    plugin?.resizePlayerAttachedToView(viewId: platformViewId)
  }

  func updateOverlayFrame(
    _ frame: CGRect?,
    visible: Bool,
    debugLabel: String?,
    generation: Int64?
  ) {
    if visible {
      overlayFrameGeneration = generation
    } else if let generation,
              let overlayFrameGeneration,
              generation != overlayFrameGeneration {
      return
    }

    updateDebugLabel(debugLabel)
    let shouldShow = visible &&
      (frame?.width ?? 0) > 0 &&
      (frame?.height ?? 0) > 0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    guard shouldShow, let frame else {
      isHidden = true
      return
    }

    let resolvedFrame = frame.integral
    if self.frame != resolvedFrame {
      self.frame = resolvedFrame
    }
    isHidden = false
    updateDrawableSize()
    plugin?.resizePlayerAttachedToView(viewId: platformViewId)
  }

  func updateDrawableSize() {
    let scale = CGFloat(currentScale)
    contentScaleFactor = scale
    metalLayer.contentsScale = scale
    // metalLayer is this view's *backing* layer (layerClass == CAMetalLayer);
    // UIKit already syncs its frame to the view. Setting it to `bounds` would
    // move the backing layer to the superlayer origin, rendering the video at
    // (0,0) instead of the view's frame (visible once the view isn't full-screen).
    metalLayer.drawableSize = CGSize(
      width: max(1.0, bounds.width * scale),
      height: max(1.0, bounds.height * scale)
    )
  }

  func pngSnapshotData() -> Data? {
    snapshotPngData(of: self)
  }

  private func updateDebugLabel(_ text: String?) {
    guard erikaDebugLabelsEnabled, let text, !text.isEmpty else {
      debugLabelView?.removeFromSuperview()
      debugLabelView = nil
      return
    }
    let label = debugLabelView ?? UILabel()
    if debugLabelView == nil {
      label.textColor = UIColor(white: 1.0, alpha: 0.45)
      label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      ])
      debugLabelView = label
    }
    label.text = text
  }
}

private func snapshotPngData(of view: UIView) -> Data? {
  guard view.bounds.width > 0, view.bounds.height > 0 else {
    return nil
  }
  let format = UIGraphicsImageRendererFormat()
  format.scale = view.window?.screen.scale ?? UIScreen.main.scale
  format.opaque = view.isOpaque
  let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
  let image = renderer.image { _ in
    view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
  }
  return image.pngData()
}

private final class ErikaVideoPlatformView: NSObject, FlutterPlatformView {
  let metalView: ErikaMetalUIView

  init(frame: CGRect, viewId: Int64, arguments: Any?, plugin: ErikaFlutterPlugin?) {
    metalView = ErikaMetalUIView(frame: frame, viewId: viewId, arguments: arguments, plugin: plugin)
    super.init()
  }

  func view() -> UIView {
    metalView
  }
}

private final class ErikaVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var plugin: ErikaFlutterPlugin?

  init(plugin: ErikaFlutterPlugin) {
    self.plugin = plugin
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let platformView = ErikaVideoPlatformView(frame: frame, viewId: viewId, arguments: args, plugin: plugin)
    plugin?.registerView(platformView.metalView, viewId: viewId)
    return platformView
  }
}

private enum ErikaAssociatedObjectKeys {
  static var windowOverlayView: UInt8 = 0
}

private extension UIWindow {
  var erikaWindowOverlayView: ErikaWindowOverlayView? {
    get {
      objc_getAssociatedObject(
        self,
        &ErikaAssociatedObjectKeys.windowOverlayView
      ) as? ErikaWindowOverlayView
    }
    set {
      objc_setAssociatedObject(
        self,
        &ErikaAssociatedObjectKeys.windowOverlayView,
        newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
  }
}

public final class ErikaFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static var sharedEventSink: FlutterEventSink?

  private static let playerChannelName = "erika_flutter/player"
  private static let eventsChannelName = "erika_flutter/events"
  private static let videoViewType = "erika_flutter/video_view"

  private var players: [Int64: ErikaPlayerHost] = [:]
  private var views: [Int64: WeakErikaVideoPlatformViewBox] = [:]
  private var nextPlayerId: Int64 = 1
  private var pollTimer: Timer?
  private var activePlayerId: Int64?
  private var interruptedPlayerId: Int64?
  private var interruptionResumeWorkItem: DispatchWorkItem?
  private var notificationObservers: [NSObjectProtocol] = []
  private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
  private var systemMediaNavigation: [Int64: (previousEnabled: Bool, nextEnabled: Bool)] = [:]

  deinit {
    interruptionResumeWorkItem?.cancel()
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
    remoteCommandTargets.forEach { command, target in
      command.removeTarget(target)
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ErikaFlutterPlugin()
    instance.configureSystemPlayback()
    let playerChannel = FlutterMethodChannel(name: playerChannelName, binaryMessenger: registrar.messenger())
    let eventsChannel = FlutterEventChannel(name: eventsChannelName, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: playerChannel)
    eventsChannel.setStreamHandler(instance)
    registrar.register(ErikaVideoViewFactory(plugin: instance), withId: videoViewType)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "create":
        result(try createPlayer(arguments: call.arguments))
      case "dispose":
        let args = try dictionaryArgs(call.arguments)
        let playerId = try requiredInt64(args["playerId"], name: "playerId")
        players.removeValue(forKey: playerId)
        systemMediaNavigation.removeValue(forKey: playerId)
        cancelPendingInterruptionResume(ifPlayer: playerId)
        if activePlayerId == playerId {
          activePlayerId = nil
          clearNowPlayingInfo()
          refreshRemoteCommands()
        }
        result(nil)
      case "open":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        guard let uri = args["uri"] as? String, !uri.isEmpty else {
          throw ErikaPluginError.invalidArguments("uri is required.")
        }
        let headers = (args["httpHeaders"] as? [String: String]) ?? [:]
        if let metadata = args["metadata"] as? [String: Any] {
          try applyMediaMetadata(metadata, to: host)
        } else {
          host.clearMediaMetadata()
        }
        try host.open(uri: uri, httpHeaders: headers)
        result(nil)
      case "play":
        let host = try playerHost(from: try dictionaryArgs(call.arguments))
        try host.play()
        activePlayerId = host.id
        refreshRemoteCommands()
        updateNowPlayingInfo(for: host)
        result(nil)
      case "pause":
        let host = try playerHost(from: try dictionaryArgs(call.arguments))
        // Drop a pending interruption resume first: it is scheduled on the main
        // queue and would otherwise fire after this pause and play again.
        cancelPendingInterruptionResume(ifPlayer: host.id)
        try host.pause()
        result(nil)
      case "stop":
        let host = try playerHost(from: try dictionaryArgs(call.arguments))
        cancelPendingInterruptionResume(ifPlayer: host.id)
        try host.stop()
        result(nil)
      case "close":
        let host = try playerHost(from: try dictionaryArgs(call.arguments))
        cancelPendingInterruptionResume(ifPlayer: host.id)
        try host.close()
        result(nil)
      case "seek":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).seek(positionMicros: try requiredUInt64(args["positionMicros"], name: "positionMicros"))
        result(nil)
      case "setPlaybackRate":
        let args = try dictionaryArgs(call.arguments)
        guard let rate = doubleValue(args["rate"]) else {
          throw ErikaPluginError.invalidArguments("rate is required.")
        }
        try playerHost(from: args).setPlaybackRate(rate)
        result(nil)
      case "setMediaMetadata":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        guard let metadata = args["metadata"] as? [String: Any] else {
          throw ErikaPluginError.invalidArguments("metadata is required.")
        }
        try applyMediaMetadata(metadata, to: host)
        result(nil)
      case "setSystemMediaNavigation":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        systemMediaNavigation[host.id] = (
          previousEnabled: boolValue(args["previousEnabled"]) ?? false,
          nextEnabled: boolValue(args["nextEnabled"]) ?? false
        )
        if activePlayerId == host.id {
          refreshRemoteCommands()
        }
        result(nil)
      case "setVolume":
        let args = try dictionaryArgs(call.arguments)
        guard let volume = doubleValue(args["volume"]) else {
          throw ErikaPluginError.invalidArguments("volume is required.")
        }
        try playerHost(from: args).setVolume(volume)
        result(nil)
      case "setUpscaler":
        let args = try dictionaryArgs(call.arguments)
        guard let mode = int32Value(args["mode"]) else {
          throw ErikaPluginError.invalidArguments("mode is required.")
        }
        try playerHost(from: args).setUpscaler(mode: mode)
        result(nil)
      case "setSubtitleScale":
        let args = try dictionaryArgs(call.arguments)
        guard let scale = doubleValue(args["scale"]) else {
          throw ErikaPluginError.invalidArguments("scale is required.")
        }
        try playerHost(from: args).setSubtitleScale(scale)
        result(nil)
      case "registerSubtitleMemoryFont":
        let args = try dictionaryArgs(call.arguments)
        guard let data = args["data"] as? FlutterStandardTypedData else {
          throw ErikaPluginError.invalidArguments("data is required.")
        }
        result(Int64(clamping: try playerHost(from: args).registerSubtitleMemoryFont(data.data)))
      case "selectSubtitleMemoryFonts":
        let args = try dictionaryArgs(call.arguments)
        let ids = (args["fontIds"] as? [NSNumber] ?? []).map { $0.uint64Value }
        try playerHost(from: args).selectSubtitleMemoryFonts(ids)
        result(nil)
      case "clearSubtitleMemoryFonts":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).clearSubtitleMemoryFonts()
        result(nil)
      case "getSubtitleMemoryFontStatus":
        let args = try dictionaryArgs(call.arguments)
        result(try playerHost(from: args).subtitleMemoryFontStatus())
      case "setSubtitleStyle":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        if args.keys.contains("fontFamily") || args.keys.contains("fontFilePath") {
          try host.setSubtitleFont(
            family: args["fontFamily"] as? String,
            filePath: args["fontFilePath"] as? String
          )
        }
        if args.keys.contains("primaryColorRgba") || args.keys.contains("outlineColorRgba")
          || args.keys.contains("fontSize") || args.keys.contains("outlineWidth")
          || args.keys.contains("bold") || args.keys.contains("italic")
          || args.keys.contains("underline") || args.keys.contains("strikeOut")
          || args.keys.contains("spacing") || args.keys.contains("scaleXPercent")
          || args.keys.contains("scaleYPercent") || args.keys.contains("borderStyle")
          || args.keys.contains("shadowDepth") || args.keys.contains("blur")
          || args.keys.contains("alignment") || args.keys.contains("marginLeft")
          || args.keys.contains("marginRight") || args.keys.contains("marginVertical")
          || args.keys.contains("overrideMask")
        {
          let primary = int64Value(args["primaryColorRgba"]) ?? 0xFFFF_FFFF
          let outline = int64Value(args["outlineColorRgba"]) ?? 0x0000_007F
          try host.setSubtitleStyle(
            fontFamily: args["fontFamily"] as? String,
            fontFilePath: args["fontFilePath"] as? String,
            primaryRgba: UInt32(truncatingIfNeeded: primary),
            outlineRgba: UInt32(truncatingIfNeeded: outline),
            fontSize: doubleValue(args["fontSize"]) ?? 48.0,
            outlineWidth: doubleValue(args["outlineWidth"]) ?? 2.0,
            bold: boolValue(args["bold"]) ?? false,
            italic: boolValue(args["italic"]) ?? false,
            underline: boolValue(args["underline"]) ?? false,
            strikeOut: boolValue(args["strikeOut"]) ?? false,
            spacing: doubleValue(args["spacing"]) ?? 0.0,
            scaleXPercent: doubleValue(args["scaleXPercent"]) ?? 100.0,
            scaleYPercent: doubleValue(args["scaleYPercent"]) ?? 100.0,
            borderStyle: int32Value(args["borderStyle"]) ?? 1,
            shadowDepth: doubleValue(args["shadowDepth"]) ?? 0.0,
            blur: doubleValue(args["blur"]) ?? 0.0,
            alignment: int32Value(args["alignment"]) ?? 2,
            marginLeft: int32Value(args["marginLeft"]) ?? 48,
            marginRight: int32Value(args["marginRight"]) ?? 48,
            marginVertical: int32Value(args["marginVertical"]) ?? 54,
            overrideMask: UInt32(truncatingIfNeeded: int64Value(args["overrideMask"]) ?? 0)
          )
        }
        result(nil)
      case "getUpscalerStatus":
        let args = try dictionaryArgs(call.arguments)
        result(try playerHost(from: args).upscalerStatus())
      case "getOutputStatus":
        let args = try dictionaryArgs(call.arguments)
        result(try playerHost(from: args).outputStatus())
      case "getResourceStatus":
        let args = try dictionaryArgs(call.arguments)
        result(try playerHost(from: args).resourceStatus())
      case "getPresenterStats":
        let args = try dictionaryArgs(call.arguments)
        result(try playerHost(from: args).presenterStats())
      case "setDebugHudEnabled":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).setDebugHudEnabled(boolValue(args["enabled"]) ?? false)
        result(nil)
      case "addExternalSubtitle":
        let args = try dictionaryArgs(call.arguments)
        guard let uri = args["uri"] as? String, !uri.isEmpty else {
          throw ErikaPluginError.invalidArguments("uri is required.")
        }
        result(try playerHost(from: args).addExternalSubtitle(uri: uri))
      case "removeSubtitleTrack":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).removeSubtitleTrack(trackId: try requiredInt64(args["trackId"], name: "trackId"))
        result(nil)
      case "loadDanmakuFile":
        let args = try dictionaryArgs(call.arguments)
        guard let uri = args["uri"] as? String, !uri.isEmpty else {
          throw ErikaPluginError.invalidArguments("uri is required.")
        }
        try playerHost(from: args).loadDanmakuFile(uri: uri)
        result(nil)
      case "loadDanmakuJson":
        let args = try dictionaryArgs(call.arguments)
        guard let json = args["json"] as? String, !json.isEmpty else {
          throw ErikaPluginError.invalidArguments("json is required.")
        }
        try playerHost(from: args).loadDanmakuJson(json)
        result(nil)
      case "addDanmakuTrackFile":
        let args = try dictionaryArgs(call.arguments)
        guard let uri = args["uri"] as? String, !uri.isEmpty else {
          throw ErikaPluginError.invalidArguments("uri is required.")
        }
        result(Int64(clamping: try playerHost(from: args).addDanmakuTrackFile(
          uri: uri,
          name: args["name"] as? String,
          offsetMicros: int64Value(args["offsetMicros"]) ?? 0
        )))
      case "addDanmakuTrackJson":
        let args = try dictionaryArgs(call.arguments)
        guard let json = args["json"] as? String, !json.isEmpty else {
          throw ErikaPluginError.invalidArguments("json is required.")
        }
        result(Int64(clamping: try playerHost(from: args).addDanmakuTrackJson(
          json,
          name: args["name"] as? String,
          offsetMicros: int64Value(args["offsetMicros"]) ?? 0
        )))
      case "removeDanmakuTrack":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).removeDanmakuTrack(trackId: try requiredUInt64(args["trackId"], name: "trackId"))
        result(nil)
      case "setDanmakuTrackEnabled":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).setDanmakuTrackEnabled(
          trackId: try requiredUInt64(args["trackId"], name: "trackId"),
          enabled: boolValue(args["enabled"]) ?? true
        )
        result(nil)
      case "setDanmakuTrackOffset":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).setDanmakuTrackOffset(
          trackId: try requiredUInt64(args["trackId"], name: "trackId"),
          offsetMicros: int64Value(args["offsetMicros"]) ?? 0
        )
        result(nil)
      case "setDanmakuGlobalOffset":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).setDanmakuGlobalOffset(offsetMicros: int64Value(args["offsetMicros"]) ?? 0)
        result(nil)
      case "danmakuTracks":
        result(try playerHost(from: try dictionaryArgs(call.arguments)).danmakuTracks())
      case "clearDanmaku":
        try playerHost(from: try dictionaryArgs(call.arguments)).clearDanmaku()
        result(nil)
      case "setDanmakuEnabled":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).setDanmakuEnabled(boolValue(args["enabled"]) ?? true)
        result(nil)
      case "setDanmakuConfig":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        try host.setDanmakuConfig(
          danmakuConfig(from: args, base: host.danmakuConfigSnapshot())
        )
        if args.keys.contains("customFontFamily") || args.keys.contains("customFontFilePath") {
          try host.setDanmakuFont(
            family: args["customFontFamily"] as? String,
            filePath: args["customFontFilePath"] as? String
          )
        }
        if let blockWordsJson = args["blockWordsJson"] as? String {
          try host.setDanmakuBlockWordsJson(blockWordsJson)
        }
        result(nil)
      case "selectAudioTrack":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).selectAudioTrack(trackId: optionalTrackId(args["trackId"]))
        result(nil)
      case "selectSubtitleTrack":
        let args = try dictionaryArgs(call.arguments)
        try playerHost(from: args).selectSubtitleTrack(trackId: optionalTrackId(args["trackId"]))
        result(nil)
      case "tracks":
        result(try playerHost(from: try dictionaryArgs(call.arguments)).tracks())
      case "screenshot":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        let view = try optionalVideoView(from: args, host: host)
        let width = int64Value(args["width"]).map(Int.init)
        let height = int64Value(args["height"]).map(Int.init)
        if let data = host.screenshot(view: view, width: width, height: height) {
          result(FlutterStandardTypedData(bytes: data))
        } else {
          result(nil)
        }
      case "attachView":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        let viewId = try requiredInt64(args["viewId"], name: "viewId")
        guard let view = views[viewId]?.view else {
          throw ErikaPluginError.viewNotFound(viewId)
        }
        try host.attach(view: view)
        result(nil)
      case "detachView":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        let viewId = try requiredInt64(args["viewId"], name: "viewId")
        host.detach(viewId: viewId)
        result(nil)
      case "attachOverlay":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        let overlay = try ensureWindowOverlayInstalled()
        try host.attach(view: overlay)
        result(erikaWindowHostedVideoSurfaceId)
      case "detachOverlay":
        let args = try dictionaryArgs(call.arguments)
        let host = try playerHost(from: args)
        let generation = int64Value(args["generation"])
        let overlay = resolveWindowOverlay()
        // A disposing widget can fire detachOverlay after a newer widget has
        // already re-attached the shared overlay surface. Skip the teardown so
        // the stale detach cannot stop the live surface's display link and
        // leave a frozen, non-rendering overlay on screen.
        if let generation,
           let activeGeneration = overlay?.activeGeneration,
           generation != activeGeneration {
          result(nil)
          return
        }
        host.detach(viewId: erikaWindowHostedVideoSurfaceId)
        overlay?.updateOverlayFrame(
          nil,
          visible: false,
          debugLabel: nil,
          generation: generation
        )
        result(nil)
      case "setOverlayFrame":
        let args = try dictionaryArgs(call.arguments)
        let overlay = try ensureWindowOverlayInstalled()
        let visible = boolValue(args["visible"]) ?? true
        let frame = convertedOverlayRect(from: args, targetView: overlay)
        overlay.updateOverlayFrame(
          frame,
          visible: visible,
          debugLabel: args["debugLabel"] as? String,
          generation: int64Value(args["generation"])
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(flutterError(error))
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    Self.sharedEventSink = events
    startPollTimerIfNeeded()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    Self.sharedEventSink = nil
    pollTimer?.invalidate()
    pollTimer = nil
    return nil
  }

  fileprivate func registerView(_ view: ErikaMetalSurfaceView, viewId: Int64) {
    views[viewId] = WeakErikaVideoPlatformViewBox(view: view)
  }

  fileprivate func unregisterView(viewId: Int64) {
    views.removeValue(forKey: viewId)
    for host in players.values {
      host.detach(viewId: viewId)
    }
  }

  fileprivate func resizePlayerAttachedToView(viewId: Int64) {
    for host in players.values {
      if let attachedPlayerId = views[viewId]?.view?.attachedPlayerId,
         attachedPlayerId == host.id {
        host.resizeFromAttachedView()
      }
    }
  }

  fileprivate func detachOverlayView(_ view: ErikaWindowOverlayView) {
    for host in players.values {
      host.detach(viewId: view.platformViewId)
    }
    if views[view.platformViewId]?.view === view {
      views.removeValue(forKey: view.platformViewId)
    }
    if view.window?.erikaWindowOverlayView === view {
      view.window?.erikaWindowOverlayView = nil
    }
  }

  private func ensureWindowOverlayInstalled() throws -> ErikaWindowOverlayView {
    if let existing = resolveWindowOverlay(),
       existing.superview != nil {
      return existing
    }

    guard let flutterHostView = currentFlutterHostView() else {
      throw ErikaPluginError.overlayNotAvailable
    }
    guard let hostWindow = flutterHostView.window else {
      throw ErikaPluginError.overlayNotAvailable
    }
    let hostSuperview = flutterHostView.superview ?? hostWindow

    prepareFlutterHostViewForWindowOverlay(flutterHostView)

    let overlay = hostWindow.erikaWindowOverlayView ??
      ErikaWindowOverlayView(plugin: self)
    overlay.plugin = self

    if overlay.superview !== hostSuperview {
      overlay.removeFromSuperview()
      overlay.frame = .zero
    }
    if flutterHostView.superview === hostSuperview,
       shouldPlaceWindowOverlayAboveFlutter() {
      hostSuperview.insertSubview(overlay, aboveSubview: flutterHostView)
    } else if flutterHostView.superview === hostSuperview {
      hostSuperview.insertSubview(overlay, belowSubview: flutterHostView)
    } else if shouldPlaceWindowOverlayAboveFlutter() {
      hostSuperview.addSubview(overlay)
    } else {
      hostSuperview.insertSubview(overlay, at: 0)
    }

    hostWindow.erikaWindowOverlayView = overlay
    registerView(overlay, viewId: overlay.platformViewId)
    return overlay
  }

  private func resolveWindowOverlay() -> ErikaWindowOverlayView? {
    for window in activeWindows() {
      if let overlay = window.erikaWindowOverlayView {
        return overlay
      }
    }
    return nil
  }

  private func currentFlutterHostView() -> UIView? {
    for window in activeWindows() {
      if let controller = findFlutterViewController(from: window.rootViewController) {
        return controller.view
      }
    }
    return activeWindows().first?.rootViewController?.view
  }

  private func activeWindows() -> [UIWindow] {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter {
        $0.activationState == .foregroundActive ||
          $0.activationState == .foregroundInactive
      }
    let windows = scenes.flatMap(\.windows).filter { !$0.isHidden }
    return windows.sorted { lhs, rhs in
      if lhs.isKeyWindow != rhs.isKeyWindow {
        return lhs.isKeyWindow
      }
      return lhs.windowLevel.rawValue > rhs.windowLevel.rawValue
    }
  }

  private func findFlutterViewController(from controller: UIViewController?) -> FlutterViewController? {
    guard let controller else {
      return nil
    }
    if let flutter = controller as? FlutterViewController {
      return flutter
    }
    if let presented = findFlutterViewController(from: controller.presentedViewController) {
      return presented
    }
    if let navigation = controller as? UINavigationController,
       let visible = findFlutterViewController(from: navigation.visibleViewController) {
      return visible
    }
    if let tab = controller as? UITabBarController,
       let selected = findFlutterViewController(from: tab.selectedViewController) {
      return selected
    }
    for child in controller.children {
      if let flutter = findFlutterViewController(from: child) {
        return flutter
      }
    }
    return nil
  }

  private func prepareFlutterHostViewForWindowOverlay(_ view: UIView) {
    if shouldPlaceWindowOverlayAboveFlutter() {
      return
    }
    view.isOpaque = false
    view.backgroundColor = .clear
    view.layer.isOpaque = false
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.window?.backgroundColor = .black
  }

  private func shouldPlaceWindowOverlayAboveFlutter() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    if environment["ERIKA_WINDOW_OVERLAY_BELOW"] == "1" {
      return false
    }
    return environment["ERIKA_WINDOW_OVERLAY_ABOVE"] == "1"
  }

  private func convertedOverlayRect(
    from args: [String: Any],
    targetView: UIView
  ) -> CGRect? {
    guard let x = doubleValue(args["x"]),
          let y = doubleValue(args["y"]),
          let width = doubleValue(args["width"]),
          let height = doubleValue(args["height"]) else {
      return nil
    }
    guard width > 0, height > 0 else {
      return nil
    }
    guard let flutterHostView = currentFlutterHostView(),
          let targetSuperview = targetView.superview else {
      return CGRect(x: x, y: y, width: width, height: height)
    }
    let rect = CGRect(x: x, y: y, width: width, height: height)
    return flutterHostView.convert(rect, to: targetSuperview)
  }

  private func createPlayer(arguments: Any?) throws -> Int64 {
    guard let library = ErikaNativeLibrary.shared else {
      throw ErikaPluginError.libraryNotFound(["main executable", "ERIKA_CAPI_DYLIB", "app bundle"])
    }
    let args = arguments as? [String: Any]
    let hdrDebug = boolValue(args?["hdrDebug"]) ??
      boolEnvironmentFlag("ERIKA_HDR_DEBUG", environment: ProcessInfo.processInfo.environment)
    let config = presenterConfigForNewPlayer(arguments: arguments, hdrDebug: hdrDebug)
    let id = nextPlayerId
    nextPlayerId += 1
    let host = try ErikaPlayerHost(
      id: id,
      library: library,
      config: config,
      hdrDebug: hdrDebug,
      allowBackgroundPlayback: boolValue(args?["allowBackgroundPlayback"]) ?? false
    )
    host.onNowPlayingChanged = { [weak self] changedHost in
      guard self?.activePlayerId == changedHost.id else { return }
      self?.updateNowPlayingInfo(for: changedHost)
    }
    players[id] = host
    systemMediaNavigation[id] = (previousEnabled: false, nextEnabled: false)
    startPollTimerIfNeeded()
    return id
  }

  private func configureSystemPlayback() {
    let center = NotificationCenter.default
    notificationObservers.append(center.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.players.values.forEach { $0.prepareForInactiveApp() }
    })
    notificationObservers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.players.values.forEach { $0.didEnterBackground() }
    })
    notificationObservers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.players.values.forEach { $0.setAppInBackground(false) }
    })
    notificationObservers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleAudioInterruption(notification)
    })

    let commands = MPRemoteCommandCenter.shared()
    addRemoteTarget(commands.playCommand) { [weak self] _ in self?.performRemotePlay() ?? .commandFailed }
    addRemoteTarget(commands.pauseCommand) { [weak self] _ in self?.performRemotePause() ?? .commandFailed }
    addRemoteTarget(commands.togglePlayPauseCommand) { [weak self] _ in self?.performRemoteToggle() ?? .commandFailed }
    addRemoteTarget(commands.changePlaybackPositionCommand) { [weak self] event in
      guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      return self?.performRemoteSeek(positionEvent.positionTime) ?? .commandFailed
    }
    addRemoteTarget(commands.previousTrackCommand) { [weak self] _ in
      self?.emitSystemMediaNavigation("previous") ?? .commandFailed
    }
    addRemoteTarget(commands.nextTrackCommand) { [weak self] _ in
      self?.emitSystemMediaNavigation("next") ?? .commandFailed
    }
    refreshRemoteCommands()
  }

  private func addRemoteTarget(
    _ command: MPRemoteCommand,
    handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
  ) {
    let target = command.addTarget(handler: handler)
    remoteCommandTargets.append((command, target))
  }

  private func applyMediaMetadata(_ metadata: [String: Any], to host: ErikaPlayerHost) throws {
    guard let title = metadata["title"] as? String, !title.isEmpty else {
      throw ErikaPluginError.invalidArguments("metadata.title is required.")
    }
    try host.setMediaMetadata(
      title: title,
      artist: metadata["artist"] as? String,
      album: metadata["album"] as? String,
      artworkData: (metadata["artwork"] as? FlutterStandardTypedData)?.data
    )
  }

  private func updateNowPlayingInfo(for host: ErikaPlayerHost) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: host.nowPlayingTitle,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: host.positionSeconds,
      MPNowPlayingInfoPropertyPlaybackRate: host.isPlaying ? host.playbackRate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: host.playbackRate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if let artist = host.nowPlayingArtist { info[MPMediaItemPropertyArtist] = artist }
    if let album = host.nowPlayingAlbum { info[MPMediaItemPropertyAlbumTitle] = album }
    if let artwork = host.nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = artwork }
    if let duration = host.durationSeconds { info[MPMediaItemPropertyPlaybackDuration] = duration }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = host.isPlaying ? .playing : .paused
  }

  private func clearNowPlayingInfo() {
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }

  private func performRemotePlay() -> MPRemoteCommandHandlerStatus {
    guard let host = activePlayerId.flatMap({ players[$0] }) else { return .noSuchContent }
    do {
      try host.play()
      return .success
    } catch {
      return .commandFailed
    }
  }

  private func performRemotePause() -> MPRemoteCommandHandlerStatus {
    guard let host = activePlayerId.flatMap({ players[$0] }) else { return .noSuchContent }
    cancelPendingInterruptionResume(ifPlayer: host.id)
    do {
      try host.pause()
      return .success
    } catch {
      return .commandFailed
    }
  }

  private func performRemoteToggle() -> MPRemoteCommandHandlerStatus {
    guard let host = activePlayerId.flatMap({ players[$0] }) else { return .noSuchContent }
    return host.isPlaying ? performRemotePause() : performRemotePlay()
  }

  private func performRemoteSeek(_ position: TimeInterval) -> MPRemoteCommandHandlerStatus {
    guard let host = activePlayerId.flatMap({ players[$0] }) else { return .noSuchContent }
    do {
      try host.seek(positionMicros: UInt64(max(0, position) * 1_000_000))
      return .success
    } catch {
      return .commandFailed
    }
  }

  private func emitSystemMediaNavigation(_ navigation: String) -> MPRemoteCommandHandlerStatus {
    performOnMain {
      guard let playerId = self.activePlayerId,
            self.players[playerId] != nil,
            let capabilities = self.systemMediaNavigation[playerId] else { return .noSuchContent }
      let enabled = navigation == "previous"
        ? capabilities.previousEnabled
        : capabilities.nextEnabled
      guard enabled else { return .noSuchContent }
      Self.sharedEventSink?([
        "playerId": playerId,
        "kind": 13,
        "navigation": navigation,
      ])
      return .success
    }
  }

  private func performOnMain(
    _ work: @escaping () -> MPRemoteCommandHandlerStatus
  ) -> MPRemoteCommandHandlerStatus {
    if Thread.isMainThread {
      return work()
    }
    return DispatchQueue.main.sync(execute: work)
  }

  private func refreshRemoteCommands() {
    let commands = MPRemoteCommandCenter.shared()
    let enabled = activePlayerId.flatMap { players[$0] } != nil
    remoteCommandTargets.forEach { command, _ in
      command.isEnabled = enabled
    }
    let capabilities = activePlayerId.flatMap { systemMediaNavigation[$0] }
    commands.previousTrackCommand.isEnabled = enabled && capabilities?.previousEnabled == true
    commands.nextTrackCommand.isEnabled = enabled && capabilities?.nextEnabled == true
  }

  private func handleAudioInterruption(_ notification: Notification) {
    guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawType),
          let host = activePlayerId.flatMap({ players[$0] }) else { return }
    if type == .began {
      let wasPlaying = host.isPlaying
      cancelPendingInterruptionResume()
      interruptedPlayerId = wasPlaying ? host.id : nil
      if wasPlaying {
        do {
          try host.pause()
        } catch {
          NSLog("ErikaFlutterPlugin: audio interruption pause failed: \(error)")
        }
      }
      return
    }
    guard let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
          AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
          interruptedPlayerId == host.id else {
      cancelPendingInterruptionResume()
      return
    }
    resumeInterruptedPlayback(host, attempt: 0)
  }

  /// Drops a scheduled interruption resume, whichever player it targets.
  private func cancelPendingInterruptionResume() {
    interruptionResumeWorkItem?.cancel()
    interruptionResumeWorkItem = nil
    interruptedPlayerId = nil
  }

  /// Drops a scheduled interruption resume only when it targets `playerId`, so
  /// an explicit pause/stop/close on one player leaves another player's
  /// pending resume alone.
  private func cancelPendingInterruptionResume(ifPlayer playerId: Int64) {
    guard interruptedPlayerId == playerId else { return }
    cancelPendingInterruptionResume()
  }

  private func resumeInterruptedPlayback(_ host: ErikaPlayerHost, attempt: Int) {
    // A retry can fire after the active player changed. Drop the recovery
    // instead of returning with `interruptedPlayerId` still set, which would
    // leave a resume owed to a player that will never be resumed.
    guard interruptedPlayerId == host.id, activePlayerId == host.id else {
      cancelPendingInterruptionResume(ifPlayer: host.id)
      return
    }
    do {
      // ErikaPlayerHost.play() configures the playback category and calls
      // setActive(true) before sending the native play command.
      try host.play()
      cancelPendingInterruptionResume()
    } catch {
      let maxAttempts = 3
      guard attempt < maxAttempts else {
        cancelPendingInterruptionResume()
        NSLog("ErikaFlutterPlugin: audio interruption resume failed after \(maxAttempts + 1) attempts: \(error)")
        return
      }
      NSLog("ErikaFlutterPlugin: audio interruption resume attempt \(attempt + 1) failed: \(error)")
      let workItem = DispatchWorkItem { [weak self, weak host] in
        guard let self, let host else { return }
        self.interruptionResumeWorkItem = nil
        self.resumeInterruptedPlayback(host, attempt: attempt + 1)
      }
      interruptionResumeWorkItem = workItem
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(100),
        execute: workItem
      )
    }
  }

  private func presenterConfigForNewPlayer(arguments: Any?, hdrDebug: Bool) -> ErikaPresenterConfigC {
    if let args = arguments as? [String: Any], let explicitMode = int32Value(args["outputMode"]) {
      let headroom = floatValue(args["edrHeadroom"]) ?? 4.0
      let config: ErikaPresenterConfigC
      switch explicitMode {
      case 1:
        config = .appleEdr(headroom: headroom)
      case 2:
        config = ErikaPresenterConfigC(outputMode: 2, edrHeadroom: max(1.0, headroom))
      case 3:
        config = .auto(headroom: headroom)
      default:
        config = .sdr
      }
      erikaHdrLog(
        hdrDebug,
        "create explicit outputMode=\(explicitMode) requestedHeadroom=\(String(format: "%.3f", headroom)) selected=\(erikaOutputModeLabel(config))"
      )
      return config
    }
    let headroom = resolvedEdrHeadroom(hdrDebug: hdrDebug)
    let config = ErikaPresenterConfigC.auto(headroom: headroom)
    erikaHdrLog(
      hdrDebug,
      "create auto selected=\(erikaOutputModeLabel(config)) resolvedHeadroom=\(String(format: "%.3f", headroom))"
    )
    return config
  }

  private func resolvedEdrHeadroom(hdrDebug: Bool) -> Float {
    let environment = ProcessInfo.processInfo.environment
    if boolEnvironmentFlag("ERIKA_DISABLE_EDR", environment: environment) {
      erikaHdrLog(hdrDebug, "EDR disabled by ERIKA_DISABLE_EDR")
      return 1.0
    }
    if let override = floatEnvironmentValue("ERIKA_EDR_HEADROOM", environment: environment), override > 1.0 {
      erikaHdrLog(hdrDebug, "EDR headroom override ERIKA_EDR_HEADROOM=\(String(format: "%.3f", override))")
      return override
    }
    let screenHeadroom = currentScreenEdrHeadroom(hdrDebug: hdrDebug)
    if screenHeadroom > 1.0 { return screenHeadroom }
    if boolEnvironmentFlag("ERIKA_ENABLE_EDR", environment: environment) {
      erikaHdrLog(hdrDebug, "EDR forced by ERIKA_ENABLE_EDR")
      return 4.0
    }
    return 1.0
  }

  private func currentScreenEdrHeadroom(hdrDebug: Bool) -> Float {
    let screen = UIScreen.main
    var samples: [String] = []
    for key in ["potentialEDRHeadroom", "currentEDRHeadroom", "maximumPotentialExtendedDynamicRangeColorComponentValue"] {
      let selector = Selector(key)
      if screen.responds(to: selector), let number = screen.value(forKey: key) as? NSNumber {
        let value = number.floatValue
        samples.append("\(key)=\(String(format: "%.3f", value))")
        if value.isFinite && value > 1.0 {
          erikaHdrLog(
            hdrDebug,
            "screen headroom selected \(key)=\(String(format: "%.3f", value)) \(erikaScreenSummary(screen)) samples=[\(samples.joined(separator: ", "))]"
          )
          return value
        }
      } else {
        samples.append("\(key)=unavailable")
      }
    }
    erikaHdrLog(
      hdrDebug,
      "screen headroom fallback=1.000 \(erikaScreenSummary(screen)) samples=[\(samples.joined(separator: ", "))]"
    )
    return 1.0
  }

  private func startPollTimerIfNeeded() {
    guard pollTimer == nil else { return }
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self else { return }
      let sink = Self.sharedEventSink
      for host in self.players.values {
        host.pollEvents(sendEvent: sink)
      }
    }
    pollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func playerHost(from args: [String: Any]) throws -> ErikaPlayerHost {
    let playerId = try requiredInt64(args["playerId"], name: "playerId")
    guard let host = players[playerId] else {
      throw ErikaPluginError.playerNotFound(playerId)
    }
    return host
  }

  private func optionalVideoView(
    from args: [String: Any],
    host: ErikaPlayerHost
  ) throws -> ErikaMetalSurfaceView? {
    guard let viewId = int64Value(args["viewId"]) else {
      return nil
    }
    guard let view = views[viewId]?.view,
          view.attachedPlayerId == host.id else {
      throw ErikaPluginError.viewNotFound(viewId)
    }
    return view
  }

  private func optionalTrackId(_ value: Any?) throws -> Int64? {
    if value == nil || value is NSNull { return nil }
    guard let trackId = int64Value(value) else {
      throw ErikaPluginError.invalidArguments("trackId must be an integer or null.")
    }
    return trackId >= 0 ? trackId : nil
  }

  private func danmakuConfig(
    from args: [String: Any],
    base: ErikaDanmakuConfigC
  ) -> ErikaDanmakuConfigC {
    var config = base
    if let value = boolValue(args["enabled"]) { config.enabled = value ? 1 : 0 }
    if let value = doubleValue(args["fontSize"]) { config.fontSize = Float(value) }
    if let value = doubleValue(args["opacity"]) { config.opacity = Float(value) }
    if let value = doubleValue(args["displayArea"]) { config.displayArea = Float(value) }
    if let value = doubleValue(args["scrollDurationSeconds"]) { config.scrollDurationSeconds = Float(value) }
    if let value = doubleValue(args["scrollSpeedFactor"]) { config.scrollSpeedFactor = Float(value) }
    if let value = doubleValue(args["trackGapRatio"]) { config.trackGapRatio = Float(value) }
    if let value = doubleValue(args["outlineWidth"]) { config.outlineWidth = Float(value) }
    if let value = doubleValue(args["shadowOffsetX"]) { config.shadowOffsetX = Float(value) }
    if let value = doubleValue(args["shadowOffsetY"]) { config.shadowOffsetY = Float(value) }
    if let value = boolValue(args["mergeDuplicates"]) { config.mergeDuplicates = value ? 1 : 0 }
    if let value = boolValue(args["allowStacking"]) { config.allowStacking = value ? 1 : 0 }
    if let value = boolValue(args["allowScrollOverwrite"]) { config.allowScrollOverwrite = value ? 1 : 0 }
    if let value = int64Value(args["maxQuantity"]), value > 0 { config.maxQuantity = UInt32(clamping: value) }
    if let value = int64Value(args["maxLinesPerMode"]), value > 0 { config.maxLinesPerMode = UInt32(clamping: value) }
    if let value = boolValue(args["blockTop"]) { config.blockTop = value ? 1 : 0 }
    if let value = boolValue(args["blockBottom"]) { config.blockBottom = value ? 1 : 0 }
    if let value = boolValue(args["blockScroll"]) { config.blockScroll = value ? 1 : 0 }
    if let value = int64Value(args["shadowStyle"]) { config.shadowStyle = Int32(clamping: value) }
    return config
  }

  private func dictionaryArgs(_ arguments: Any?) throws -> [String: Any] {
    guard let args = arguments as? [String: Any] else {
      throw ErikaPluginError.invalidArguments("Arguments must be a dictionary.")
    }
    return args
  }

  private func int32Value(_ value: Any?) -> Int32? {
    if let value = value as? Int32 { return value }
    if let value = value as? NSNumber { return value.int32Value }
    if let value = value as? String { return Int32(value) }
    return nil
  }

  private func int64Value(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
  }

  private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
  }

  private func floatValue(_ value: Any?) -> Float? {
    if let value = value as? Float, value.isFinite { return value }
    if let value = value as? Double, value.isFinite { return Float(value) }
    if let value = value as? NSNumber {
      let result = value.floatValue
      return result.isFinite ? result : nil
    }
    if let value = value as? String, let result = Float(value), result.isFinite { return result }
    return nil
  }

  private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on": return true
      case "0", "false", "no", "off": return false
      default: return nil
      }
    }
    return nil
  }

  private func requiredInt64(_ value: Any?, name: String) throws -> Int64 {
    if let value = int64Value(value) { return value }
    throw ErikaPluginError.invalidArguments("\(name) is required.")
  }

  private func requiredUInt64(_ value: Any?, name: String) throws -> UInt64 {
    if let value = value as? UInt64 { return value }
    if let value = value as? Int64, value >= 0 { return UInt64(value) }
    if let value = value as? NSNumber { return value.uint64Value }
    if let value = value as? String, let parsed = UInt64(value) { return parsed }
    throw ErikaPluginError.invalidArguments("\(name) is required.")
  }

  private func boolEnvironmentFlag(_ name: String, environment: [String: String]) -> Bool {
    switch environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    default: return false
    }
  }

  private func floatEnvironmentValue(_ name: String, environment: [String: String]) -> Float? {
    guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let value = Float(raw),
          value.isFinite else {
      return nil
    }
    return value
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(code: "ERIKA_ERROR", message: String(describing: error), details: nil)
  }
}

private extension ErikaEventC {
  func toFlutterMap(
    playerId: Int64,
    host: ErikaPlayerHost? = nil,
    structuredMessage: String? = nil
  ) -> [String: Any] {
    var map: [String: Any] = [
      "playerId": playerId,
      "kind": Int(kind),
      "status": Int(status),
      "state": Int(state),
      "durationMicros": Int(durationMicros),
      "positionMicros": Int64(positionMicros),
      "buffering": buffering != 0,
      "video": [
        "width": Int(video.width),
        "height": Int(video.height),
        "primaries": Int(video.primaries),
        "transfer": Int(video.transfer),
      ],
      "tracks": [
        "video": Int(tracks.video),
        "audio": Int(tracks.audio),
        "subtitle": Int(tracks.subtitle),
      ],
    ]
    if kind == 4 || kind == 10 {
      map["trackList"] = (try? host?.tracks()) ?? []
      map["trackSelection"] = (try? host?.trackSelection()) ?? [
        "video": -1,
        "audio": -1,
        "subtitle": -1,
      ]
    }
    if let structuredMessage,
       let data = structuredMessage.data(using: .utf8),
       let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if kind == 11 {
        map["decoder"] = payload
      } else if kind == 12 {
        map["audio"] = payload
      } else if kind == 9 {
        map["error"] = structuredMessage
      }
    }
    return map
  }
}

private extension ErikaTrackSelectionC {
  func toFlutterMap() -> [String: Any] {
    ["video": Int(video), "audio": Int(audio), "subtitle": Int(subtitle)]
  }
}

private extension ErikaUpscalerStatusC {
  func toFlutterMap() -> [String: Any] {
    [
      "requestedMode": Int(requestedMode),
      "activeBackend": Int(activeBackend),
      "fallbackCount": Int64(clamping: fallbackCount),
      "upscaledFrames": Int64(clamping: upscaledFrames),
      "lastEncodeMicros": Int64(clamping: lastEncodeMicros),
      "lastGpuMicros": Int64(clamping: lastGpuMicros),
    ]
  }
}

private extension ErikaOutputStatusC {
  func toFlutterMap() -> [String: Any] {
    [
      "requestedMode": Int(requestedMode),
      "activeEncoding": Int(activeEncoding),
      "surfaceFormat": Int(surfaceFormat),
      "nativeDataSpace": Int(nativeDataSpace),
      "requestedHeadroom": Double(requestedHeadroom),
      "activeHeadroom": Double(activeHeadroom),
      "activeHeadroomKnown": activeHeadroomKnown,
      "extendedLinearActive": extendedLinearActive,
      "fallbackReason": Int(fallbackReason),
      "fallbackCount": Int64(clamping: fallbackCount),
      "dataSpaceFailures": Int64(clamping: dataSpaceFailures),
      "headroomUpdates": Int64(clamping: headroomUpdates),
      "extendedLinearFrames": Int64(clamping: extendedLinearFrames),
    ]
  }
}

private extension ErikaPresenterResourceStatusC {
  func toFlutterMap() -> [String: Any] {
    [
      "deviceCurrentAllocatedBytes": Int64(clamping: deviceCurrentAllocatedBytes),
      "deviceRecommendedWorkingSetBytes": Int64(clamping: deviceRecommendedWorkingSetBytes),
      "drawableEstimatedBytes": Int64(clamping: drawableEstimatedBytes),
      "videoFrameBytes": Int64(clamping: videoFrameBytes),
      "overlayAtlasBytes": Int64(clamping: overlayAtlasBytes),
      "danmakuAtlasBytes": Int64(clamping: danmakuAtlasBytes),
      "danmakuVertexBufferBytes": Int64(clamping: danmakuVertexBufferBytes),
      "upscalerBytes": Int64(clamping: upscalerBytes),
      "rendererTrackedBytes": Int64(clamping: rendererTrackedBytes),
      "presenterCpuDanmakuAtlasBytes": Int64(clamping: presenterCpuDanmakuAtlasBytes),
      "drawableCount": Int(drawableCount),
      "outputModeSwitches": Int64(clamping: outputModeSwitches),
    ]
  }
}

private extension ErikaPresenterStatsC {
  func toFlutterMap() -> [String: Any] {
    [
      "decodedVideoFrames": Int64(clamping: decodedVideoFrames),
      "renderedVideoFrames": Int64(clamping: renderedVideoFrames),
      "renderedTestFrames": Int64(clamping: renderedTestFrames),
      "pushedAudioFrames": Int64(clamping: pushedAudioFrames),
      "overlayFrames": Int64(clamping: overlayFrames),
      "danmakuFrames": Int64(clamping: danmakuFrames),
      "danmakuItems": Int64(clamping: danmakuItems),
      "importFailures": Int64(clamping: importFailures),
      "renderFailures": Int64(clamping: renderFailures),
      "audioFailures": Int64(clamping: audioFailures),
      "softwareVideoFrames": Int64(clamping: softwareVideoFrames),
      "hardwareVideoFrames": Int64(clamping: hardwareVideoFrames),
      "zeroCopyVideoFrames": Int64(clamping: zeroCopyVideoFrames),
      "cpuVideoFrameFallbacks": Int64(clamping: cpuVideoFrameFallbacks),
      "lastRenderMicros": Int64(clamping: lastRenderMicros),
      "lastRenderCurrentMicros": Int64(clamping: lastRenderCurrentMicros),
      "audioClockReadFrames": Int64(clamping: audioClockReadFrames),
      "audioClockQueuedFrames": Int64(clamping: audioClockQueuedFrames),
      "audioClockUnderflowFrames": Int64(clamping: audioClockUnderflowFrames),
      "audioRecoveryState": Int(audioRecoveryState),
      "audioLastErrorCode": Int(audioLastErrorCode),
      "audioRecoveryAttempts": Int64(clamping: audioRecoveryAttempts),
      "audioRecoveryCount": Int64(clamping: audioRecoveryCount),
      "audioRecoveryFailures": Int64(clamping: audioRecoveryFailures),
      "directZeroCopyVideoFrames": Int64(clamping: directZeroCopyVideoFrames),
      "sharedHandleVideoFrames": Int64(clamping: sharedHandleVideoFrames),
      "hdrSourceFrames": Int64(clamping: hdrSourceFrames),
      "hdr10OutputFrames": Int64(clamping: hdr10OutputFrames),
      "sdrTonemapFrames": Int64(clamping: sdrTonemapFrames),
      "hdr10MetadataUpdates": Int64(clamping: hdr10MetadataUpdates),
      "hdr10MetadataFailures": Int64(clamping: hdr10MetadataFailures),
      "hdr10OutputFailures": Int64(clamping: hdr10OutputFailures),
      "hdr10OutputActive": hdr10OutputActive,
      "videoFrameBackpressureDrops": Int64(clamping: videoFrameBackpressureDrops),
    ]
  }
}

private extension ErikaTrackInfoC {
  func toFlutterMap() -> [String: Any] {
    [
      "id": Int(id),
      "kind": Int(kind),
      "source": Int(source),
      "selected": selected != 0,
      "canRemove": canRemove != 0,
      "title": title.map { String(cString: $0) } as Any,
      "language": language.map { String(cString: $0) } as Any,
      "codec": codec.map { String(cString: $0) } as Any,
      "width": Int(width),
      "height": Int(height),
      "sampleRate": Int(sampleRate),
      "channels": Int(channels),
      "pixelFormat": pixelFormat.map { String(cString: $0) } as Any,
      "sampleFormat": sampleFormat.map { String(cString: $0) } as Any,
      "profile": profile.map { String(cString: $0) } as Any,
      "level": Int(level),
      "bitRate": Int64(clamping: bitRate),
      "frameRateNumerator": Int(frameRateNumerator),
      "frameRateDenominator": Int(frameRateDenominator),
    ]
  }
}

private extension ErikaDanmakuTrackInfoC {
  func toFlutterMap() -> [String: Any] {
    [
      "id": Int64(clamping: id),
      "enabled": enabled != 0,
      "offsetMicros": offsetMicros,
      "itemCount": itemCount,
      "name": name.map { String(cString: $0) } as Any,
      "source": source.map { String(cString: $0) } as Any,
    ]
  }
}

private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
  guard let value, !value.isEmpty else {
    return body(nil)
  }
  return value.withCString { pointer in body(pointer) }
}
