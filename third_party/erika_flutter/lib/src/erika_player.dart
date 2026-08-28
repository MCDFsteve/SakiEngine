import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'erika_event.dart';

@immutable
class ErikaMediaMetadata {
  const ErikaMediaMetadata({
    required this.title,
    this.artist,
    this.album,
    this.artwork,
  });

  final String title;
  final String? artist;
  final String? album;
  final Uint8List? artwork;

  Map<String, Object> toMap() => <String, Object>{
        'title': title,
        if (artist != null) 'artist': artist!,
        if (album != null) 'album': album!,
        if (artwork != null) 'artwork': artwork!,
      };
}

/// Subtitle text colour Erika falls back to, as `0xRRGGBBAA`: opaque white.
const int kErikaDefaultSubtitlePrimaryColorRgba = 0xFFFFFFFF;

/// Subtitle outline colour Erika falls back to: half-transparent black.
const int kErikaDefaultSubtitleOutlineColorRgba = 0x0000007F;

/// Base subtitle font size in ASS script units, before [ErikaPlayer.setSubtitleScale].
const double kErikaDefaultSubtitleFontSize = 48.0;

/// Base subtitle outline width in ASS script units, before the subtitle scale.
const double kErikaDefaultSubtitleOutlineWidth = 2.0;

const int kErikaSubtitleOverrideFontSizeFields = 1 << 2;
const int kErikaSubtitleOverrideFontName = 1 << 3;
const int kErikaSubtitleOverrideColors = 1 << 4;
const int kErikaSubtitleOverrideAttributes = 1 << 5;
const int kErikaSubtitleOverrideBorder = 1 << 6;
const int kErikaSubtitleOverrideAlignment = 1 << 7;
const int kErikaSubtitleOverrideMargins = 1 << 8;
const int kErikaSubtitleOverrideBlur = 1 << 11;
const int kErikaSubtitleOverrideAll = kErikaSubtitleOverrideFontSizeFields |
    kErikaSubtitleOverrideFontName |
    kErikaSubtitleOverrideColors |
    kErikaSubtitleOverrideAttributes |
    kErikaSubtitleOverrideBorder |
    kErikaSubtitleOverrideAlignment |
    kErikaSubtitleOverrideMargins |
    kErikaSubtitleOverrideBlur;

enum ErikaOutputMode {
  sdr(0),
  appleEdr(1),
  extendedLinear(2),
  auto(3);

  const ErikaOutputMode(this.nativeValue);

  final int nativeValue;

  static ErikaOutputMode fromNativeValue(int value) {
    return switch (value) {
      1 => ErikaOutputMode.appleEdr,
      2 => ErikaOutputMode.extendedLinear,
      3 => ErikaOutputMode.auto,
      _ => ErikaOutputMode.sdr,
    };
  }
}

/// How transparency is encoded in a video frame.
enum ErikaVideoAlphaMode {
  /// The decoded video is fully opaque.
  opaque(0),

  /// The left half is colour and the right half is a grayscale alpha mask.
  /// Erika presents the video at half of its encoded width and reconstructs a
  /// premultiplied-alpha frame in the GPU presentation shader.
  packedAlphaRight(1);

  const ErikaVideoAlphaMode(this.nativeValue);

  final int nativeValue;
}

enum ErikaActiveOutputEncoding {
  sdrSrgb(0),
  appleEdr(1),
  androidExtendedLinearScRgb(2),
  hdr10Pq(3);

  const ErikaActiveOutputEncoding(this.nativeValue);

  final int nativeValue;

  static ErikaActiveOutputEncoding fromNativeValue(int value) {
    return switch (value) {
      1 => ErikaActiveOutputEncoding.appleEdr,
      2 => ErikaActiveOutputEncoding.androidExtendedLinearScRgb,
      3 => ErikaActiveOutputEncoding.hdr10Pq,
      _ => ErikaActiveOutputEncoding.sdrSrgb,
    };
  }
}

enum ErikaOutputSurfaceFormat {
  eightBitUnorm(0),
  tenBitUnorm(1),
  sixteenBitFloat(2);

  const ErikaOutputSurfaceFormat(this.nativeValue);

  final int nativeValue;

  static ErikaOutputSurfaceFormat fromNativeValue(int value) {
    return switch (value) {
      1 => ErikaOutputSurfaceFormat.tenBitUnorm,
      2 => ErikaOutputSurfaceFormat.sixteenBitFloat,
      _ => ErikaOutputSurfaceFormat.eightBitUnorm,
    };
  }
}

enum ErikaOutputFallbackReason {
  none(0, 'none'),
  displayHdrUnsupported(1, 'display_hdr_unsupported'),
  hybridCompositionRequired(2, 'hybrid_composition_required'),
  wgpuBackendNotVulkan(3, 'wgpu_backend_not_vulkan'),
  rgba16FloatSurfaceFormatUnavailable(
    4,
    'rgba16float_surface_format_unavailable',
  ),
  nativeWindowDataSpaceApiUnavailable(
    5,
    'native_window_dataspace_api_unavailable',
  ),
  scrgbDataSpaceVerificationFailed(6, 'scrgb_dataspace_verification_failed'),
  surfaceConfigureFailed(7, 'surface_configure_failed'),
  legacyAppleEdrUnsupported(8, 'legacy_apple_edr_unsupported'),
  unknown(-1, 'unknown');

  const ErikaOutputFallbackReason(this.nativeValue, this.label);

  final int nativeValue;
  final String label;

  static ErikaOutputFallbackReason fromNativeValue(int value) {
    return switch (value) {
      0 => ErikaOutputFallbackReason.none,
      1 => ErikaOutputFallbackReason.displayHdrUnsupported,
      2 => ErikaOutputFallbackReason.hybridCompositionRequired,
      3 => ErikaOutputFallbackReason.wgpuBackendNotVulkan,
      4 => ErikaOutputFallbackReason.rgba16FloatSurfaceFormatUnavailable,
      5 => ErikaOutputFallbackReason.nativeWindowDataSpaceApiUnavailable,
      6 => ErikaOutputFallbackReason.scrgbDataSpaceVerificationFailed,
      7 => ErikaOutputFallbackReason.surfaceConfigureFailed,
      8 => ErikaOutputFallbackReason.legacyAppleEdrUnsupported,
      _ => ErikaOutputFallbackReason.unknown,
    };
  }
}

class ErikaOutputStatus {
  const ErikaOutputStatus({
    required this.requestedMode,
    required this.activeEncoding,
    required this.surfaceFormat,
    required this.nativeDataSpace,
    required this.requestedHeadroom,
    required this.activeHeadroom,
    required this.activeHeadroomKnown,
    required this.extendedLinearActive,
    required this.fallbackReason,
    required this.fallbackCount,
    required this.dataSpaceFailures,
    required this.headroomUpdates,
    required this.extendedLinearFrames,
  });

  final ErikaOutputMode requestedMode;
  final ErikaActiveOutputEncoding activeEncoding;
  final ErikaOutputSurfaceFormat surfaceFormat;
  final int nativeDataSpace;
  final double requestedHeadroom;
  final double activeHeadroom;
  final bool activeHeadroomKnown;
  final bool extendedLinearActive;
  final ErikaOutputFallbackReason fallbackReason;
  final int fallbackCount;
  final int dataSpaceFailures;
  final int headroomUpdates;
  final int extendedLinearFrames;

  factory ErikaOutputStatus.fromMap(Map<dynamic, dynamic> map) {
    return ErikaOutputStatus(
      requestedMode: ErikaOutputMode.fromNativeValue(
        (map['requestedMode'] as num?)?.toInt() ?? 0,
      ),
      activeEncoding: ErikaActiveOutputEncoding.fromNativeValue(
        (map['activeEncoding'] as num?)?.toInt() ?? 0,
      ),
      surfaceFormat: ErikaOutputSurfaceFormat.fromNativeValue(
        (map['surfaceFormat'] as num?)?.toInt() ?? 0,
      ),
      nativeDataSpace: (map['nativeDataSpace'] as num?)?.toInt() ?? -1,
      requestedHeadroom: (map['requestedHeadroom'] as num?)?.toDouble() ?? 1.0,
      activeHeadroom: (map['activeHeadroom'] as num?)?.toDouble() ?? 1.0,
      activeHeadroomKnown: map['activeHeadroomKnown'] == true,
      extendedLinearActive: map['extendedLinearActive'] == true,
      fallbackReason: ErikaOutputFallbackReason.fromNativeValue(
        (map['fallbackReason'] as num?)?.toInt() ?? 0,
      ),
      fallbackCount: (map['fallbackCount'] as num?)?.toInt() ?? 0,
      dataSpaceFailures: (map['dataSpaceFailures'] as num?)?.toInt() ?? 0,
      headroomUpdates: (map['headroomUpdates'] as num?)?.toInt() ?? 0,
      extendedLinearFrames: (map['extendedLinearFrames'] as num?)?.toInt() ?? 0,
    );
  }
}

class ErikaPresenterResourceStatus {
  const ErikaPresenterResourceStatus({
    required this.deviceCurrentAllocatedBytes,
    required this.deviceRecommendedWorkingSetBytes,
    required this.drawableEstimatedBytes,
    required this.videoFrameBytes,
    required this.overlayAtlasBytes,
    required this.danmakuAtlasBytes,
    required this.danmakuVertexBufferBytes,
    required this.upscalerBytes,
    required this.rendererTrackedBytes,
    required this.presenterCpuDanmakuAtlasBytes,
    required this.drawableCount,
    required this.outputModeSwitches,
  });

  /// Metal's process-wide counter for the current device. This can include
  /// allocations from other Erika presenters and other Metal users.
  final int deviceCurrentAllocatedBytes;
  final int deviceRecommendedWorkingSetBytes;
  final int drawableEstimatedBytes;
  final int videoFrameBytes;
  final int overlayAtlasBytes;
  final int danmakuAtlasBytes;
  final int danmakuVertexBufferBytes;
  final int upscalerBytes;
  final int rendererTrackedBytes;
  final int presenterCpuDanmakuAtlasBytes;
  final int drawableCount;
  final int outputModeSwitches;

  factory ErikaPresenterResourceStatus.fromMap(Map<dynamic, dynamic> map) {
    int value(String key) => (map[key] as num?)?.toInt() ?? 0;

    return ErikaPresenterResourceStatus(
      deviceCurrentAllocatedBytes: value('deviceCurrentAllocatedBytes'),
      deviceRecommendedWorkingSetBytes: value(
        'deviceRecommendedWorkingSetBytes',
      ),
      drawableEstimatedBytes: value('drawableEstimatedBytes'),
      videoFrameBytes: value('videoFrameBytes'),
      overlayAtlasBytes: value('overlayAtlasBytes'),
      danmakuAtlasBytes: value('danmakuAtlasBytes'),
      danmakuVertexBufferBytes: value('danmakuVertexBufferBytes'),
      upscalerBytes: value('upscalerBytes'),
      rendererTrackedBytes: value('rendererTrackedBytes'),
      presenterCpuDanmakuAtlasBytes: value(
        'presenterCpuDanmakuAtlasBytes',
      ),
      drawableCount: value('drawableCount'),
      outputModeSwitches: value('outputModeSwitches'),
    );
  }
}

class ErikaSubtitleMemoryFontStatus {
  const ErikaSubtitleMemoryFontStatus({
    required this.registeredCount,
    required this.registeredBytes,
    required this.selectedCount,
    required this.generation,
    required this.selectedIds,
  });

  final int registeredCount;
  final int registeredBytes;
  final int selectedCount;
  final int generation;
  final List<int> selectedIds;

  factory ErikaSubtitleMemoryFontStatus.fromMap(Map<dynamic, dynamic> map) {
    return ErikaSubtitleMemoryFontStatus(
      registeredCount: (map['registeredCount'] as num?)?.toInt() ?? 0,
      registeredBytes: (map['registeredBytes'] as num?)?.toInt() ?? 0,
      selectedCount: (map['selectedCount'] as num?)?.toInt() ?? 0,
      generation: (map['generation'] as num?)?.toInt() ?? 0,
      selectedIds: List<int>.unmodifiable(
        (map['selectedIds'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<num>()
            .map((value) => value.toInt()),
      ),
    );
  }
}

enum ErikaUpscalerMode {
  off(0),
  artCnnC4F16(1),
  artCnnC4F32(2),
  artCnnC4F16Ds(3);

  const ErikaUpscalerMode(this.nativeValue);

  final int nativeValue;

  static ErikaUpscalerMode fromNativeValue(int value) {
    return switch (value) {
      1 => ErikaUpscalerMode.artCnnC4F16,
      2 => ErikaUpscalerMode.artCnnC4F32,
      3 => ErikaUpscalerMode.artCnnC4F16Ds,
      _ => ErikaUpscalerMode.off,
    };
  }
}

enum ErikaUpscalerBackendStatus {
  off(0),
  inactive(1),
  building(2),
  scalar(3),
  simdgroupMatrix(4);

  const ErikaUpscalerBackendStatus(this.nativeValue);

  final int nativeValue;

  static ErikaUpscalerBackendStatus fromNativeValue(int value) {
    return switch (value) {
      1 => ErikaUpscalerBackendStatus.inactive,
      2 => ErikaUpscalerBackendStatus.building,
      3 => ErikaUpscalerBackendStatus.scalar,
      4 => ErikaUpscalerBackendStatus.simdgroupMatrix,
      _ => ErikaUpscalerBackendStatus.off,
    };
  }
}

class ErikaUpscalerStatus {
  const ErikaUpscalerStatus({
    required this.requestedMode,
    required this.activeBackend,
    required this.fallbackCount,
    required this.upscaledFrames,
    required this.lastEncodeDuration,
    required this.lastGpuDuration,
  });

  final ErikaUpscalerMode requestedMode;
  final ErikaUpscalerBackendStatus activeBackend;
  final int fallbackCount;
  final int upscaledFrames;
  final Duration lastEncodeDuration;
  final Duration lastGpuDuration;

  factory ErikaUpscalerStatus.fromMap(Map<dynamic, dynamic> map) {
    return ErikaUpscalerStatus(
      requestedMode: ErikaUpscalerMode.fromNativeValue(
        (map['requestedMode'] as num?)?.toInt() ?? 0,
      ),
      activeBackend: ErikaUpscalerBackendStatus.fromNativeValue(
        (map['activeBackend'] as num?)?.toInt() ?? 0,
      ),
      fallbackCount: (map['fallbackCount'] as num?)?.toInt() ?? 0,
      upscaledFrames: (map['upscaledFrames'] as num?)?.toInt() ?? 0,
      lastEncodeDuration: Duration(
        microseconds: (map['lastEncodeMicros'] as num?)?.toInt() ?? 0,
      ),
      lastGpuDuration: Duration(
        microseconds: (map['lastGpuMicros'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

class ErikaPresenterStats {
  const ErikaPresenterStats({
    required this.decodedVideoFrames,
    required this.renderedVideoFrames,
    required this.renderedTestFrames,
    required this.pushedAudioFrames,
    required this.overlayFrames,
    required this.danmakuFrames,
    required this.danmakuItems,
    required this.importFailures,
    required this.renderFailures,
    required this.audioFailures,
    required this.softwareVideoFrames,
    required this.hardwareVideoFrames,
    required this.zeroCopyVideoFrames,
    required this.cpuVideoFrameFallbacks,
    required this.lastRenderDuration,
    required this.lastRenderCurrentDuration,
    required this.audioClockReadFrames,
    required this.audioClockQueuedFrames,
    required this.audioClockUnderflowFrames,
    required this.audioRecoveryState,
    required this.audioLastErrorCode,
    required this.audioRecoveryAttempts,
    required this.audioRecoveryCount,
    required this.audioRecoveryFailures,
    required this.directZeroCopyVideoFrames,
    required this.sharedHandleVideoFrames,
    required this.hdrSourceFrames,
    required this.hdr10OutputFrames,
    required this.sdrTonemapFrames,
    required this.hdr10MetadataUpdates,
    required this.hdr10MetadataFailures,
    required this.hdr10OutputFailures,
    required this.hdr10OutputActive,
    required this.videoFrameBackpressureDrops,
  });

  final int decodedVideoFrames;
  final int renderedVideoFrames;
  final int renderedTestFrames;
  final int pushedAudioFrames;
  final int overlayFrames;
  final int danmakuFrames;
  final int danmakuItems;
  final int importFailures;
  final int renderFailures;
  final int audioFailures;
  final int softwareVideoFrames;
  final int hardwareVideoFrames;
  final int zeroCopyVideoFrames;
  final int cpuVideoFrameFallbacks;
  final Duration lastRenderDuration;
  final Duration lastRenderCurrentDuration;
  final int audioClockReadFrames;
  final int audioClockQueuedFrames;
  final int audioClockUnderflowFrames;
  final int audioRecoveryState;
  final int audioLastErrorCode;
  final int audioRecoveryAttempts;
  final int audioRecoveryCount;
  final int audioRecoveryFailures;
  final int directZeroCopyVideoFrames;
  final int sharedHandleVideoFrames;
  final int hdrSourceFrames;
  final int hdr10OutputFrames;
  final int sdrTonemapFrames;
  final int hdr10MetadataUpdates;
  final int hdr10MetadataFailures;
  final int hdr10OutputFailures;
  final bool hdr10OutputActive;
  final int videoFrameBackpressureDrops;

  factory ErikaPresenterStats.fromMap(Map<dynamic, dynamic> map) {
    return ErikaPresenterStats(
      decodedVideoFrames: _intValue(map['decodedVideoFrames']),
      renderedVideoFrames: _intValue(map['renderedVideoFrames']),
      renderedTestFrames: _intValue(map['renderedTestFrames']),
      pushedAudioFrames: _intValue(map['pushedAudioFrames']),
      overlayFrames: _intValue(map['overlayFrames']),
      danmakuFrames: _intValue(map['danmakuFrames']),
      danmakuItems: _intValue(map['danmakuItems']),
      importFailures: _intValue(map['importFailures']),
      renderFailures: _intValue(map['renderFailures']),
      audioFailures: _intValue(map['audioFailures']),
      softwareVideoFrames: _intValue(map['softwareVideoFrames']),
      hardwareVideoFrames: _intValue(map['hardwareVideoFrames']),
      zeroCopyVideoFrames: _intValue(map['zeroCopyVideoFrames']),
      cpuVideoFrameFallbacks: _intValue(map['cpuVideoFrameFallbacks']),
      lastRenderDuration: Duration(
        microseconds: _intValue(map['lastRenderMicros']),
      ),
      lastRenderCurrentDuration: Duration(
        microseconds: _intValue(map['lastRenderCurrentMicros']),
      ),
      audioClockReadFrames: _intValue(map['audioClockReadFrames']),
      audioClockQueuedFrames: _intValue(map['audioClockQueuedFrames']),
      audioClockUnderflowFrames: _intValue(map['audioClockUnderflowFrames']),
      audioRecoveryState: _intValue(map['audioRecoveryState']),
      audioLastErrorCode: _intValue(map['audioLastErrorCode']),
      audioRecoveryAttempts: _intValue(map['audioRecoveryAttempts']),
      audioRecoveryCount: _intValue(map['audioRecoveryCount']),
      audioRecoveryFailures: _intValue(map['audioRecoveryFailures']),
      directZeroCopyVideoFrames: _intValue(map['directZeroCopyVideoFrames']),
      sharedHandleVideoFrames: _intValue(map['sharedHandleVideoFrames']),
      hdrSourceFrames: _intValue(map['hdrSourceFrames']),
      hdr10OutputFrames: _intValue(map['hdr10OutputFrames']),
      sdrTonemapFrames: _intValue(map['sdrTonemapFrames']),
      hdr10MetadataUpdates: _intValue(map['hdr10MetadataUpdates']),
      hdr10MetadataFailures: _intValue(map['hdr10MetadataFailures']),
      hdr10OutputFailures: _intValue(map['hdr10OutputFailures']),
      hdr10OutputActive: map['hdr10OutputActive'] == true,
      videoFrameBackpressureDrops: _intValue(
        map['videoFrameBackpressureDrops'],
      ),
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'decodedVideoFrames': decodedVideoFrames,
      'renderedVideoFrames': renderedVideoFrames,
      'renderedTestFrames': renderedTestFrames,
      'pushedAudioFrames': pushedAudioFrames,
      'overlayFrames': overlayFrames,
      'danmakuFrames': danmakuFrames,
      'danmakuItems': danmakuItems,
      'importFailures': importFailures,
      'renderFailures': renderFailures,
      'audioFailures': audioFailures,
      'softwareVideoFrames': softwareVideoFrames,
      'hardwareVideoFrames': hardwareVideoFrames,
      'zeroCopyVideoFrames': zeroCopyVideoFrames,
      'cpuVideoFrameFallbacks': cpuVideoFrameFallbacks,
      'lastRenderMicros': lastRenderDuration.inMicroseconds,
      'lastRenderCurrentMicros': lastRenderCurrentDuration.inMicroseconds,
      'audioClockReadFrames': audioClockReadFrames,
      'audioClockQueuedFrames': audioClockQueuedFrames,
      'audioClockUnderflowFrames': audioClockUnderflowFrames,
      'audioRecoveryState': audioRecoveryState,
      'audioLastErrorCode': audioLastErrorCode,
      'audioRecoveryAttempts': audioRecoveryAttempts,
      'audioRecoveryCount': audioRecoveryCount,
      'audioRecoveryFailures': audioRecoveryFailures,
      'directZeroCopyVideoFrames': directZeroCopyVideoFrames,
      'sharedHandleVideoFrames': sharedHandleVideoFrames,
      'hdrSourceFrames': hdrSourceFrames,
      'hdr10OutputFrames': hdr10OutputFrames,
      'sdrTonemapFrames': sdrTonemapFrames,
      'hdr10MetadataUpdates': hdr10MetadataUpdates,
      'hdr10MetadataFailures': hdr10MetadataFailures,
      'hdr10OutputFailures': hdr10OutputFailures,
      'hdr10OutputActive': hdr10OutputActive,
      'videoFrameBackpressureDrops': videoFrameBackpressureDrops,
    };
  }

  static int _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }
}

class ErikaDanmakuTrackInfo {
  const ErikaDanmakuTrackInfo({
    required this.id,
    required this.enabled,
    required this.offset,
    required this.itemCount,
    this.name,
    this.source,
  });

  final int id;
  final bool enabled;
  final Duration offset;
  final int itemCount;
  final String? name;
  final String? source;

  factory ErikaDanmakuTrackInfo.fromMap(Map<dynamic, dynamic> map) {
    return ErikaDanmakuTrackInfo(
      id: (map['id'] as num?)?.toInt() ?? 0,
      enabled: map['enabled'] == true,
      offset: Duration(
        microseconds: (map['offsetMicros'] as num?)?.toInt() ?? 0,
      ),
      itemCount: (map['itemCount'] as num?)?.toInt() ?? 0,
      name: map['name'] as String?,
      source: map['source'] as String?,
    );
  }
}

class _ErikaDanmakuConfigPatch {
  _ErikaDanmakuConfigPatch({
    this.enabled,
    this.fontSize,
    this.opacity,
    this.displayArea,
    this.scrollDurationSeconds,
    this.scrollSpeedFactor,
    this.trackGapRatio,
    this.outlineWidth,
    this.shadowOffsetX,
    this.shadowOffsetY,
    this.shadowStyle,
    this.customFontFamily,
    this.customFontFilePath,
    this.mergeDuplicates,
    this.allowStacking,
    this.allowScrollOverwrite,
    this.maxQuantity,
    this.maxLinesPerMode,
    this.blockTop,
    this.blockBottom,
    this.blockScroll,
    List<String>? blockWords,
  }) : blockWords =
            blockWords == null ? null : List<String>.unmodifiable(blockWords);

  final bool? enabled;
  final double? fontSize;
  final double? opacity;
  final double? displayArea;
  final double? scrollDurationSeconds;
  final double? scrollSpeedFactor;
  final double? trackGapRatio;
  final double? outlineWidth;
  final double? shadowOffsetX;
  final double? shadowOffsetY;
  final int? shadowStyle;
  final String? customFontFamily;
  final String? customFontFilePath;
  final bool? mergeDuplicates;
  final bool? allowStacking;
  final bool? allowScrollOverwrite;
  final int? maxQuantity;
  final int? maxLinesPerMode;
  final bool? blockTop;
  final bool? blockBottom;
  final bool? blockScroll;
  final List<String>? blockWords;

  bool get isEmpty =>
      enabled == null &&
      fontSize == null &&
      opacity == null &&
      displayArea == null &&
      scrollDurationSeconds == null &&
      scrollSpeedFactor == null &&
      trackGapRatio == null &&
      outlineWidth == null &&
      shadowOffsetX == null &&
      shadowOffsetY == null &&
      shadowStyle == null &&
      customFontFamily == null &&
      customFontFilePath == null &&
      mergeDuplicates == null &&
      allowStacking == null &&
      allowScrollOverwrite == null &&
      maxQuantity == null &&
      maxLinesPerMode == null &&
      blockTop == null &&
      blockBottom == null &&
      blockScroll == null &&
      blockWords == null;

  _ErikaDanmakuConfigPatch merge(_ErikaDanmakuConfigPatch other) {
    return _ErikaDanmakuConfigPatch(
      enabled: other.enabled ?? enabled,
      fontSize: other.fontSize ?? fontSize,
      opacity: other.opacity ?? opacity,
      displayArea: other.displayArea ?? displayArea,
      scrollDurationSeconds:
          other.scrollDurationSeconds ?? scrollDurationSeconds,
      scrollSpeedFactor: other.scrollSpeedFactor ?? scrollSpeedFactor,
      trackGapRatio: other.trackGapRatio ?? trackGapRatio,
      outlineWidth: other.outlineWidth ?? outlineWidth,
      shadowOffsetX: other.shadowOffsetX ?? shadowOffsetX,
      shadowOffsetY: other.shadowOffsetY ?? shadowOffsetY,
      shadowStyle: other.shadowStyle ?? shadowStyle,
      customFontFamily: other.customFontFamily ?? customFontFamily,
      customFontFilePath: other.customFontFilePath ?? customFontFilePath,
      mergeDuplicates: other.mergeDuplicates ?? mergeDuplicates,
      allowStacking: other.allowStacking ?? allowStacking,
      allowScrollOverwrite: other.allowScrollOverwrite ?? allowScrollOverwrite,
      maxQuantity: other.maxQuantity ?? maxQuantity,
      maxLinesPerMode: other.maxLinesPerMode ?? maxLinesPerMode,
      blockTop: other.blockTop ?? blockTop,
      blockBottom: other.blockBottom ?? blockBottom,
      blockScroll: other.blockScroll ?? blockScroll,
      blockWords: other.blockWords ?? blockWords,
    );
  }

  _ErikaDanmakuConfigPatch differenceFrom(_ErikaDanmakuConfigPatch? previous) {
    return _ErikaDanmakuConfigPatch(
      enabled: _changed(enabled, previous?.enabled) ? enabled : null,
      fontSize: _changed(fontSize, previous?.fontSize) ? fontSize : null,
      opacity: _changed(opacity, previous?.opacity) ? opacity : null,
      displayArea:
          _changed(displayArea, previous?.displayArea) ? displayArea : null,
      scrollDurationSeconds:
          _changed(scrollDurationSeconds, previous?.scrollDurationSeconds)
              ? scrollDurationSeconds
              : null,
      scrollSpeedFactor:
          _changed(scrollSpeedFactor, previous?.scrollSpeedFactor)
              ? scrollSpeedFactor
              : null,
      trackGapRatio: _changed(trackGapRatio, previous?.trackGapRatio)
          ? trackGapRatio
          : null,
      outlineWidth:
          _changed(outlineWidth, previous?.outlineWidth) ? outlineWidth : null,
      shadowOffsetX: _changed(shadowOffsetX, previous?.shadowOffsetX)
          ? shadowOffsetX
          : null,
      shadowOffsetY: _changed(shadowOffsetY, previous?.shadowOffsetY)
          ? shadowOffsetY
          : null,
      shadowStyle:
          _changed(shadowStyle, previous?.shadowStyle) ? shadowStyle : null,
      customFontFamily: _changed(customFontFamily, previous?.customFontFamily)
          ? customFontFamily
          : null,
      customFontFilePath:
          _changed(customFontFilePath, previous?.customFontFilePath)
              ? customFontFilePath
              : null,
      mergeDuplicates: _changed(mergeDuplicates, previous?.mergeDuplicates)
          ? mergeDuplicates
          : null,
      allowStacking: _changed(allowStacking, previous?.allowStacking)
          ? allowStacking
          : null,
      allowScrollOverwrite:
          _changed(allowScrollOverwrite, previous?.allowScrollOverwrite)
              ? allowScrollOverwrite
              : null,
      maxQuantity:
          _changed(maxQuantity, previous?.maxQuantity) ? maxQuantity : null,
      maxLinesPerMode: _changed(maxLinesPerMode, previous?.maxLinesPerMode)
          ? maxLinesPerMode
          : null,
      blockTop: _changed(blockTop, previous?.blockTop) ? blockTop : null,
      blockBottom:
          _changed(blockBottom, previous?.blockBottom) ? blockBottom : null,
      blockScroll:
          _changed(blockScroll, previous?.blockScroll) ? blockScroll : null,
      blockWords:
          _changedList(blockWords, previous?.blockWords) ? blockWords : null,
    );
  }

  Map<String, Object?> toArguments(int playerId) {
    return <String, Object?>{
      'playerId': playerId,
      if (enabled != null) 'enabled': enabled,
      if (fontSize != null) 'fontSize': fontSize,
      if (opacity != null) 'opacity': opacity,
      if (displayArea != null) 'displayArea': displayArea,
      if (scrollDurationSeconds != null)
        'scrollDurationSeconds': scrollDurationSeconds,
      if (scrollSpeedFactor != null) 'scrollSpeedFactor': scrollSpeedFactor,
      if (trackGapRatio != null) 'trackGapRatio': trackGapRatio,
      if (outlineWidth != null) 'outlineWidth': outlineWidth,
      if (shadowOffsetX != null) 'shadowOffsetX': shadowOffsetX,
      if (shadowOffsetY != null) 'shadowOffsetY': shadowOffsetY,
      if (shadowStyle != null) 'shadowStyle': shadowStyle,
      if (customFontFamily != null) 'customFontFamily': customFontFamily,
      if (customFontFilePath != null) 'customFontFilePath': customFontFilePath,
      if (mergeDuplicates != null) 'mergeDuplicates': mergeDuplicates,
      if (allowStacking != null) 'allowStacking': allowStacking,
      if (allowScrollOverwrite != null)
        'allowScrollOverwrite': allowScrollOverwrite,
      if (maxQuantity != null) 'maxQuantity': maxQuantity,
      if (maxLinesPerMode != null) 'maxLinesPerMode': maxLinesPerMode,
      if (blockTop != null) 'blockTop': blockTop,
      if (blockBottom != null) 'blockBottom': blockBottom,
      if (blockScroll != null) 'blockScroll': blockScroll,
      if (blockWords != null) 'blockWordsJson': jsonEncode(blockWords),
    };
  }

  static bool _changed<T>(T? value, T? previous) =>
      value != null && value != previous;

  static bool _changedList(List<String>? value, List<String>? previous) =>
      value != null && !listEquals(value, previous);
}

class ErikaPlayer {
  ErikaPlayer({
    this.outputMode,
    this.edrHeadroom,
    this.upscaler,
    this.videoAlphaMode = ErikaVideoAlphaMode.opaque,
    this.hdrDebug = false,
    this.allowBackgroundPlayback = false,
  }) {
    final headroom = edrHeadroom;
    if (headroom != null &&
        (!headroom.isFinite || headroom < 1.0 || headroom > 10000.0)) {
      throw ArgumentError.value(
        headroom,
        'edrHeadroom',
        'must be finite and in [1, 10000]; omit it for system-auto headroom',
      );
    }
    _eventSubscription ??= _events.receiveBroadcastStream().listen(
      _dispatchNativeEvent,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('ErikaPlayer event stream error: $error');
      },
    );
  }

  static const MethodChannel _channel = MethodChannel('erika_flutter/player');
  static const EventChannel _events = EventChannel('erika_flutter/events');
  static const int windowOverlayViewId = -1;
  static final Map<int, StreamController<ErikaPlayerEvent>> _controllers =
      <int, StreamController<ErikaPlayerEvent>>{};
  static StreamSubscription<dynamic>? _eventSubscription;

  int? _id;
  Future<int>? _createFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;
  static const Duration _danmakuConfigCoalesceDelay = Duration(
    milliseconds: 50,
  );
  Timer? _danmakuConfigTimer;
  bool _danmakuConfigInFlight = false;
  _ErikaDanmakuConfigPatch? _pendingDanmakuConfig;
  _ErikaDanmakuConfigPatch? _lastAppliedDanmakuConfig;
  String? _subtitleFontFamily;
  String? _subtitleFontFilePath;
  int _subtitlePrimaryColorRgba = kErikaDefaultSubtitlePrimaryColorRgba;
  int _subtitleOutlineColorRgba = kErikaDefaultSubtitleOutlineColorRgba;
  double _subtitleFontSize = kErikaDefaultSubtitleFontSize;
  double _subtitleOutlineWidth = kErikaDefaultSubtitleOutlineWidth;
  bool _subtitleBold = false;
  bool _subtitleItalic = false;
  bool _subtitleUnderline = false;
  bool _subtitleStrikeOut = false;
  double _subtitleSpacing = 0.0;
  double _subtitleScaleXPercent = 100.0;
  double _subtitleScaleYPercent = 100.0;
  int _subtitleBorderStyle = 1;
  double _subtitleShadowDepth = 0.0;
  double _subtitleBlur = 0.0;
  int _subtitleAlignment = 2;
  int _subtitleMarginLeft = 48;
  int _subtitleMarginRight = 48;
  int _subtitleMarginVertical = 54;
  int _subtitleOverrideMask = 0;
  final List<Completer<void>> _pendingDanmakuConfigCompleters =
      <Completer<void>>[];

  final ErikaOutputMode? outputMode;
  final double? edrHeadroom;
  final ErikaUpscalerMode? upscaler;
  final ErikaVideoAlphaMode videoAlphaMode;
  final bool hdrDebug;
  final bool allowBackgroundPlayback;

  int? get id => _id;

  Stream<ErikaPlayerEvent> get events async* {
    final playerId = await ensureCreated();
    yield* _controllerFor(playerId).stream;
  }

  Future<int> ensureCreated() {
    if (_disposed) {
      throw StateError('ErikaPlayer has been disposed.');
    }
    final existing = _id;
    final player = existing != null
        ? Future<int>.value(existing)
        : (_createFuture ??= _create());
    return _requireActiveAfter(player);
  }

  Future<void> open(
    String uri, {
    Map<String, String>? httpHeaders,
    ErikaMediaMetadata? metadata,
  }) async {
    final playerId = await ensureCreated();
    await _invoke('open', <String, Object?>{
      'playerId': playerId,
      'uri': uri,
      if (httpHeaders != null && httpHeaders.isNotEmpty)
        'httpHeaders': httpHeaders,
      'metadata': metadata?.toMap(),
    });
  }

  Future<void> setMediaMetadata(ErikaMediaMetadata metadata) async {
    final playerId = await ensureCreated();
    await _invoke('setMediaMetadata', <String, Object?>{
      'playerId': playerId,
      'metadata': metadata.toMap(),
    });
  }

  Future<void> setSystemMediaNavigation({
    required bool previousEnabled,
    required bool nextEnabled,
  }) async {
    final playerId = await ensureCreated();
    await _invoke('setSystemMediaNavigation', <String, Object?>{
      'playerId': playerId,
      'previousEnabled': previousEnabled,
      'nextEnabled': nextEnabled,
    });
  }

  Future<void> play() async {
    await _invokeForPlayer('play');
  }

  Future<void> pause() async {
    await _invokeForPlayer('pause');
  }

  Future<void> stop() async {
    await _invokeForPlayer('stop');
  }

  Future<void> close() async {
    await _invokeForPlayer('close');
  }

  Future<void> seek(Duration position) async {
    final playerId = await ensureCreated();
    await _invoke('seek', <String, Object?>{
      'playerId': playerId,
      'positionMicros': position.inMicroseconds,
    });
  }

  Future<void> setPlaybackRate(double rate) async {
    final playerId = await ensureCreated();
    await _invoke('setPlaybackRate', <String, Object?>{
      'playerId': playerId,
      'rate': rate,
    });
  }

  Future<void> setVolume(double volume) async {
    final playerId = await ensureCreated();
    await _invoke('setVolume', <String, Object?>{
      'playerId': playerId,
      'volume': volume.clamp(0.0, 1.0),
    });
  }

  Future<void> setUpscaler(ErikaUpscalerMode mode) async {
    final playerId = await ensureCreated();
    await _invoke('setUpscaler', <String, Object?>{
      'playerId': playerId,
      'mode': mode.nativeValue,
    });
  }

  Future<void> setSubtitleScale(double scale) async {
    final playerId = await ensureCreated();
    final clampedScale = scale.isFinite ? scale.clamp(0.25, 4.0) : 1.0;
    await _invoke('setSubtitleScale', <String, Object?>{
      'playerId': playerId,
      'scale': clampedScale,
    });
  }

  Future<int> registerSubtitleMemoryFont(Uint8List data) async {
    if (data.isEmpty) {
      throw ArgumentError.value(data, 'data', 'must not be empty');
    }
    final playerId = await ensureCreated();
    final fontId = await _channel.invokeMethod<int>(
      'registerSubtitleMemoryFont',
      <String, Object?>{'playerId': playerId, 'data': data},
    );
    if (fontId == null) {
      throw StateError(
          'Erika subtitle memory font registration returned null.');
    }
    return fontId;
  }

  Future<void> selectSubtitleMemoryFonts(Iterable<int> fontIds) async {
    final ids = List<int>.unmodifiable(fontIds);
    if (ids.any((id) => id <= 0) || ids.toSet().length != ids.length) {
      throw ArgumentError.value(
          fontIds, 'fontIds', 'must contain unique positive IDs');
    }
    final playerId = await ensureCreated();
    await _invoke('selectSubtitleMemoryFonts', <String, Object?>{
      'playerId': playerId,
      'fontIds': ids,
    });
  }

  Future<void> clearSubtitleMemoryFonts() async {
    await _invokeForPlayer('clearSubtitleMemoryFonts');
  }

  Future<ErikaSubtitleMemoryFontStatus> getSubtitleMemoryFontStatus() async {
    final playerId = await ensureCreated();
    final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getSubtitleMemoryFontStatus',
      <String, Object?>{'playerId': playerId},
    );
    if (status == null) {
      throw StateError('Erika subtitle memory font status returned null.');
    }
    return ErikaSubtitleMemoryFontStatus.fromMap(status);
  }

  /// Sets the subtitle style.
  ///
  /// Values act as fallbacks: an ASS script keeps its own styling, and these
  /// only fill in what it leaves open, what the system cannot resolve, and the
  /// look of plain-text (SRT/WebVTT) subtitles. Set bits in [overrideMask] to
  /// push selected fields onto dialogue that carries its own styling.
  ///
  /// Colours are `0xRRGGBBAA`. [fontSize] and [outlineWidth] are in ASS script
  /// units (clamped to `8..400` and `0..32`), and [setSubtitleScale] still
  /// multiplies both.
  ///
  /// Omitted arguments keep whatever this player last applied, so a single
  /// field can be changed on its own. Pass an empty string to clear the font
  /// family or file and return to the platform default.
  Future<void> setSubtitleStyle({
    String? fontFamily,
    String? fontFilePath,
    int? primaryColorRgba,
    int? outlineColorRgba,
    double? fontSize,
    double? outlineWidth,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikeOut,
    double? spacing,
    double? scaleXPercent,
    double? scaleYPercent,
    int? borderStyle,
    double? shadowDepth,
    double? blur,
    int? alignment,
    int? marginLeft,
    int? marginRight,
    int? marginVertical,
    int? overrideMask,
  }) async {
    final playerId = await ensureCreated();
    _subtitleFontFamily = fontFamily ?? _subtitleFontFamily;
    _subtitleFontFilePath = fontFilePath ?? _subtitleFontFilePath;
    _subtitlePrimaryColorRgba =
        _clampColorRgba(primaryColorRgba) ?? _subtitlePrimaryColorRgba;
    _subtitleOutlineColorRgba =
        _clampColorRgba(outlineColorRgba) ?? _subtitleOutlineColorRgba;
    _subtitleFontSize = _clampMetric(fontSize, 8.0, 400.0) ?? _subtitleFontSize;
    _subtitleOutlineWidth =
        _clampMetric(outlineWidth, 0.0, 32.0) ?? _subtitleOutlineWidth;
    _subtitleBold = bold ?? _subtitleBold;
    _subtitleItalic = italic ?? _subtitleItalic;
    _subtitleUnderline = underline ?? _subtitleUnderline;
    _subtitleStrikeOut = strikeOut ?? _subtitleStrikeOut;
    _subtitleSpacing = _clampMetric(spacing, -100.0, 100.0) ?? _subtitleSpacing;
    _subtitleScaleXPercent =
        _clampMetric(scaleXPercent, 1.0, 1000.0) ?? _subtitleScaleXPercent;
    _subtitleScaleYPercent =
        _clampMetric(scaleYPercent, 1.0, 1000.0) ?? _subtitleScaleYPercent;
    _subtitleBorderStyle =
        _validValue(borderStyle, const <int>{1, 3}) ?? _subtitleBorderStyle;
    _subtitleShadowDepth =
        _clampMetric(shadowDepth, 0.0, 32.0) ?? _subtitleShadowDepth;
    _subtitleBlur = _clampMetric(blur, 0.0, 100.0) ?? _subtitleBlur;
    _subtitleAlignment = _clampInt(alignment, 1, 9) ?? _subtitleAlignment;
    _subtitleMarginLeft =
        _clampInt(marginLeft, 0, 10000) ?? _subtitleMarginLeft;
    _subtitleMarginRight =
        _clampInt(marginRight, 0, 10000) ?? _subtitleMarginRight;
    _subtitleMarginVertical =
        _clampInt(marginVertical, 0, 10000) ?? _subtitleMarginVertical;
    _subtitleOverrideMask = overrideMask == null
        ? _subtitleOverrideMask
        : overrideMask & kErikaSubtitleOverrideAll;
    await _invoke('setSubtitleStyle', <String, Object?>{
      'playerId': playerId,
      'fontFamily': _subtitleFontFamily ?? '',
      'fontFilePath': _subtitleFontFilePath ?? '',
      'primaryColorRgba': _subtitlePrimaryColorRgba,
      'outlineColorRgba': _subtitleOutlineColorRgba,
      'fontSize': _subtitleFontSize,
      'outlineWidth': _subtitleOutlineWidth,
      'bold': _subtitleBold,
      'italic': _subtitleItalic,
      'underline': _subtitleUnderline,
      'strikeOut': _subtitleStrikeOut,
      'spacing': _subtitleSpacing,
      'scaleXPercent': _subtitleScaleXPercent,
      'scaleYPercent': _subtitleScaleYPercent,
      'borderStyle': _subtitleBorderStyle,
      'shadowDepth': _subtitleShadowDepth,
      'blur': _subtitleBlur,
      'alignment': _subtitleAlignment,
      'marginLeft': _subtitleMarginLeft,
      'marginRight': _subtitleMarginRight,
      'marginVertical': _subtitleMarginVertical,
      'overrideMask': _subtitleOverrideMask,
    });
  }

  static int? _validValue(int? value, Set<int> validValues) {
    return value != null && validValues.contains(value) ? value : null;
  }

  static int? _clampInt(int? value, int min, int max) {
    return value?.clamp(min, max);
  }

  static int? _clampColorRgba(int? value) {
    if (value == null) {
      return null;
    }
    return value & 0xFFFFFFFF;
  }

  static double? _clampMetric(double? value, double min, double max) {
    if (value == null || !value.isFinite) {
      return null;
    }
    return value.clamp(min, max);
  }

  Future<ErikaUpscalerStatus> getUpscalerStatus() async {
    final playerId = await ensureCreated();
    final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getUpscalerStatus',
      <String, Object?>{'playerId': playerId},
    );
    if (status == null) {
      throw StateError('Erika upscaler status returned null.');
    }
    return ErikaUpscalerStatus.fromMap(status);
  }

  Future<ErikaOutputStatus> getOutputStatus() async {
    final playerId = await ensureCreated();
    final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getOutputStatus',
      <String, Object?>{'playerId': playerId},
    );
    if (status == null) {
      throw StateError('Erika output status returned null.');
    }
    return ErikaOutputStatus.fromMap(status);
  }

  Future<ErikaPresenterResourceStatus> getResourceStatus() async {
    final playerId = await ensureCreated();
    final status = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getResourceStatus',
      <String, Object?>{'playerId': playerId},
    );
    if (status == null) {
      throw StateError('Erika resource status returned null.');
    }
    return ErikaPresenterResourceStatus.fromMap(status);
  }

  Future<ErikaPresenterStats> getPresenterStats() async {
    final playerId = await ensureCreated();
    final stats = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getPresenterStats',
      <String, Object?>{'playerId': playerId},
    );
    if (stats == null) {
      throw StateError('Erika presenter stats returned null.');
    }
    return ErikaPresenterStats.fromMap(stats);
  }

  Future<void> setDebugHudEnabled(bool enabled) async {
    final playerId = await ensureCreated();
    await _channel.invokeMethod<void>('setDebugHudEnabled', <String, Object?>{
      'playerId': playerId,
      'enabled': enabled,
    });
  }

  Future<Uint8List?> screenshot({int? viewId, int? width, int? height}) async {
    final playerId = await ensureCreated();
    return _channel.invokeMethod<Uint8List>('screenshot', <String, Object?>{
      'playerId': playerId,
      if (viewId != null) 'viewId': viewId,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
    });
  }

  Future<int> addExternalSubtitle(String uri) async {
    final playerId = await ensureCreated();
    final trackId = await _channel.invokeMethod<int>(
      'addExternalSubtitle',
      <String, Object?>{'playerId': playerId, 'uri': uri},
    );
    if (trackId == null) {
      throw StateError('Erika external subtitle add returned no track id.');
    }
    return trackId;
  }

  Future<void> removeSubtitleTrack(int trackId) async {
    final playerId = await ensureCreated();
    await _invoke('removeSubtitleTrack', <String, Object?>{
      'playerId': playerId,
      'trackId': trackId,
    });
  }

  Future<void> loadDanmakuFile(String uri) async {
    final playerId = await ensureCreated();
    await _invoke('loadDanmakuFile', <String, Object?>{
      'playerId': playerId,
      'uri': uri,
    });
  }

  Future<void> loadDanmakuJson(String json) async {
    final playerId = await ensureCreated();
    await _invoke('loadDanmakuJson', <String, Object?>{
      'playerId': playerId,
      'json': json,
    });
  }

  Future<int> addDanmakuTrackFile(
    String uri, {
    String? name,
    Duration offset = Duration.zero,
  }) async {
    final playerId = await ensureCreated();
    final trackId = await _channel
        .invokeMethod<int>('addDanmakuTrackFile', <String, Object?>{
      'playerId': playerId,
      'uri': uri,
      if (name != null) 'name': name,
      'offsetMicros': offset.inMicroseconds,
    });
    if (trackId == null || trackId <= 0) {
      throw StateError('Erika danmaku track add returned no track id.');
    }
    return trackId;
  }

  Future<int> addDanmakuTrackJson(
    String json, {
    String? name,
    Duration offset = Duration.zero,
  }) async {
    final playerId = await ensureCreated();
    final trackId = await _channel
        .invokeMethod<int>('addDanmakuTrackJson', <String, Object?>{
      'playerId': playerId,
      'json': json,
      if (name != null) 'name': name,
      'offsetMicros': offset.inMicroseconds,
    });
    if (trackId == null || trackId <= 0) {
      throw StateError('Erika danmaku track add returned no track id.');
    }
    return trackId;
  }

  Future<void> removeDanmakuTrack(int trackId) async {
    final playerId = await ensureCreated();
    await _invoke('removeDanmakuTrack', <String, Object?>{
      'playerId': playerId,
      'trackId': trackId,
    });
  }

  Future<void> setDanmakuTrackEnabled(int trackId, bool enabled) async {
    final playerId = await ensureCreated();
    await _invoke('setDanmakuTrackEnabled', <String, Object?>{
      'playerId': playerId,
      'trackId': trackId,
      'enabled': enabled,
    });
  }

  Future<void> setDanmakuTrackOffset(int trackId, Duration offset) async {
    final playerId = await ensureCreated();
    await _invoke('setDanmakuTrackOffset', <String, Object?>{
      'playerId': playerId,
      'trackId': trackId,
      'offsetMicros': offset.inMicroseconds,
    });
  }

  Future<void> setDanmakuGlobalOffset(Duration offset) async {
    final playerId = await ensureCreated();
    await _invoke('setDanmakuGlobalOffset', <String, Object?>{
      'playerId': playerId,
      'offsetMicros': offset.inMicroseconds,
    });
  }

  Future<List<ErikaDanmakuTrackInfo>> danmakuTracks() async {
    final playerId = await ensureCreated();
    final rawTracks = await _channel.invokeMethod<List<dynamic>>(
      'danmakuTracks',
      <String, Object?>{'playerId': playerId},
    );
    if (rawTracks == null) {
      return const <ErikaDanmakuTrackInfo>[];
    }
    return rawTracks
        .whereType<Map<dynamic, dynamic>>()
        .map(ErikaDanmakuTrackInfo.fromMap)
        .toList(growable: false);
  }

  Future<void> clearDanmaku() async {
    await _invokeForPlayer('clearDanmaku');
  }

  Future<void> setDanmakuEnabled(bool enabled) async {
    final playerId = await ensureCreated();
    await _invoke('setDanmakuEnabled', <String, Object?>{
      'playerId': playerId,
      'enabled': enabled,
    });
  }

  Future<void> setDanmakuConfig({
    bool? enabled,
    // NipaPlay/Flutter logical danmaku font size. Erika uses the NipaPlay
    // default danmaku font and applies the native surface scale internally.
    double? fontSize,
    double? opacity,
    double? displayArea,
    double? scrollDurationSeconds,
    double? scrollSpeedFactor,
    double? trackGapRatio,
    double? outlineWidth,
    double? shadowOffsetX,
    double? shadowOffsetY,
    int? shadowStyle,
    String? customFontFamily,
    String? customFontFilePath,
    bool? mergeDuplicates,
    bool? allowStacking,
    bool? allowScrollOverwrite,
    int? maxQuantity,
    int? maxLinesPerMode,
    bool? blockTop,
    bool? blockBottom,
    bool? blockScroll,
    List<String>? blockWords,
  }) async {
    if (_disposed) {
      return;
    }
    final playerId = await ensureCreated();
    if (enabled != null) {
      // Visibility changes are presentation-critical. Do not hold them behind
      // the style coalescing timer; the native presenter can hide immediately.
      await _invoke('setDanmakuEnabled', <String, Object?>{
        'playerId': playerId,
        'enabled': enabled,
      });
    }
    final patch = _ErikaDanmakuConfigPatch(
      enabled: null,
      fontSize: fontSize,
      opacity: opacity,
      displayArea: displayArea,
      scrollDurationSeconds: scrollDurationSeconds,
      scrollSpeedFactor: scrollSpeedFactor,
      trackGapRatio: trackGapRatio,
      outlineWidth: outlineWidth,
      shadowOffsetX: shadowOffsetX,
      shadowOffsetY: shadowOffsetY,
      shadowStyle: shadowStyle,
      customFontFamily: customFontFamily,
      customFontFilePath: customFontFilePath,
      mergeDuplicates: mergeDuplicates,
      allowStacking: allowStacking,
      allowScrollOverwrite: allowScrollOverwrite,
      maxQuantity: maxQuantity,
      maxLinesPerMode: maxLinesPerMode,
      blockTop: blockTop,
      blockBottom: blockBottom,
      blockScroll: blockScroll,
      blockWords: blockWords,
    );
    if (patch.isEmpty) {
      return;
    }

    final completer = Completer<void>();
    _pendingDanmakuConfig = _pendingDanmakuConfig?.merge(patch) ?? patch;
    _pendingDanmakuConfigCompleters.add(completer);
    _scheduleDanmakuConfigFlush(playerId);
    return completer.future;
  }

  void _scheduleDanmakuConfigFlush(int playerId) {
    if (_disposed || _danmakuConfigInFlight || _danmakuConfigTimer != null) {
      return;
    }
    _danmakuConfigTimer = Timer(_danmakuConfigCoalesceDelay, () {
      _danmakuConfigTimer = null;
      unawaited(_flushDanmakuConfig(playerId));
    });
  }

  Future<void> _flushDanmakuConfig(int playerId) async {
    if (_disposed || _danmakuConfigInFlight) {
      return;
    }

    final requestedPatch = _pendingDanmakuConfig;
    if (requestedPatch == null) {
      return;
    }
    final completers = List<Completer<void>>.of(
      _pendingDanmakuConfigCompleters,
    );
    _pendingDanmakuConfigCompleters.clear();
    _pendingDanmakuConfig = null;

    final outgoingPatch = requestedPatch.differenceFrom(
      _lastAppliedDanmakuConfig,
    );
    if (outgoingPatch.isEmpty) {
      for (final completer in completers) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
      if (_pendingDanmakuConfig != null) {
        _scheduleDanmakuConfigFlush(playerId);
      }
      return;
    }

    _danmakuConfigInFlight = true;
    try {
      await _invoke('setDanmakuConfig', outgoingPatch.toArguments(playerId));
      _lastAppliedDanmakuConfig =
          _lastAppliedDanmakuConfig?.merge(requestedPatch) ?? requestedPatch;
      for (final completer in completers) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    } catch (error, stackTrace) {
      for (final completer in completers) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    } finally {
      _danmakuConfigInFlight = false;
      if (_pendingDanmakuConfig != null) {
        _scheduleDanmakuConfigFlush(playerId);
      }
    }
  }

  Future<void> selectAudioTrack(int? trackId) async {
    final playerId = await ensureCreated();
    await _invoke('selectAudioTrack', <String, Object?>{
      'playerId': playerId,
      'trackId': trackId,
    });
  }

  Future<void> selectSubtitleTrack(int? trackId) async {
    final playerId = await ensureCreated();
    await _invoke('selectSubtitleTrack', <String, Object?>{
      'playerId': playerId,
      'trackId': trackId,
    });
  }

  Future<List<ErikaTrackInfo>> tracks() async {
    final playerId = await ensureCreated();
    final rawTracks = await _channel.invokeMethod<List<dynamic>>(
      'tracks',
      <String, Object?>{'playerId': playerId},
    );
    if (rawTracks == null) {
      return const <ErikaTrackInfo>[];
    }
    return rawTracks
        .whereType<Map<dynamic, dynamic>>()
        .map(ErikaTrackInfo.fromMap)
        .toList(growable: false);
  }

  Future<void> attachView(int viewId) async {
    final playerId = await ensureCreated();
    await _invoke('attachView', <String, Object?>{
      'playerId': playerId,
      'viewId': viewId,
    });
  }

  Future<void> detachView(int viewId) async {
    final playerId = _id;
    if (playerId == null || _disposed) {
      return;
    }
    await _invoke('detachView', <String, Object?>{
      'playerId': playerId,
      'viewId': viewId,
    });
  }

  /// Allocates a Flutter texture backed by an OpenHarmony SurfaceProducer.
  ///
  /// This is used by [ErikaVideoView] on HarmonyOS; other embedders normally
  /// attach their platform view directly.
  Future<int> createTextureSurface({
    required int width,
    required int height,
    required double scale,
  }) async {
    final textureId = await _channel.invokeMethod<int>(
      'createTexture',
      <String, Object?>{
        'width': width,
        'height': height,
        'scale': scale,
      },
    );
    if (textureId == null || textureId < 0) {
      throw StateError('Erika texture allocation failed.');
    }
    return textureId;
  }

  Future<void> resizeTextureSurface(
    int textureId, {
    required int width,
    required int height,
    required double scale,
  }) {
    return _invoke('resizeTexture', <String, Object?>{
      'textureId': textureId,
      'width': width,
      'height': height,
      'scale': scale,
    });
  }

  Future<void> releaseTextureSurface(int textureId) {
    return _invoke('releaseTexture', <String, Object?>{
      'textureId': textureId,
    });
  }

  /// Attaches the shared native overlay to this player.
  ///
  /// Multi-view embedders can use [flutterViewId] and [secondaryWindow] to
  /// identify the Flutter view that currently hosts the player widget.
  Future<int> attachWindowOverlay({
    int? flutterViewId,
    bool secondaryWindow = false,
    String blendMode = 'srcOver',
    double opacity = 1.0,
  }) async {
    final playerId = await ensureCreated();
    final viewId = await _channel.invokeMethod<int>(
      'attachOverlay',
      <String, Object?>{
        'playerId': playerId,
        if (flutterViewId != null) 'flutterViewId': flutterViewId,
        'secondaryWindow': secondaryWindow,
        if (blendMode != 'srcOver') 'blendMode': blendMode,
        if (opacity != 1.0) 'opacity': opacity,
      },
    );
    return viewId ?? windowOverlayViewId;
  }

  Future<void> detachWindowOverlay({int? generation}) async {
    final playerId = _id;
    if (playerId == null || _disposed) {
      return;
    }
    await _invoke('detachOverlay', <String, Object?>{
      'playerId': playerId,
      if (generation != null) 'generation': generation,
    });
  }

  Future<void> setWindowOverlayFrame({
    required Rect frame,
    required bool visible,
    required int generation,
    int? flutterViewId,
    bool secondaryWindow = false,
    String? debugLabel,
    String blendMode = 'srcOver',
    double opacity = 1.0,
  }) async {
    final playerId = await ensureCreated();
    await _invoke('setOverlayFrame', <String, Object?>{
      'playerId': playerId,
      'viewId': windowOverlayViewId,
      'generation': generation,
      'x': frame.left,
      'y': frame.top,
      'width': frame.width,
      'height': frame.height,
      'visible': visible,
      if (flutterViewId != null) 'flutterViewId': flutterViewId,
      'secondaryWindow': secondaryWindow,
      if (debugLabel != null) 'debugLabel': debugLabel,
      if (blendMode != 'srcOver') 'blendMode': blendMode,
      if (opacity != 1.0) 'opacity': opacity,
    });
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _disposed = true;
    return _disposeFuture = _dispose();
  }

  Future<void> _dispose() async {
    _danmakuConfigTimer?.cancel();
    _danmakuConfigTimer = null;
    for (final completer in _pendingDanmakuConfigCompleters) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _pendingDanmakuConfigCompleters.clear();
    _pendingDanmakuConfig = null;

    final createFuture = _createFuture;
    if (createFuture != null) {
      try {
        await createFuture;
      } catch (_) {
        // Creation callers retain the original error. Disposal only needs to
        // clean up a native player if creation produced one.
      }
    }

    final playerId = _id;
    _id = null;
    _createFuture = null;
    if (playerId == null) {
      return;
    }
    try {
      await _invoke('dispose', <String, Object?>{'playerId': playerId});
    } finally {
      final controller = _controllers.remove(playerId);
      await controller?.close();
    }
  }

  Future<int> _create() async {
    final requestedHeadroom = edrHeadroom ??
        (outputMode == ErikaOutputMode.extendedLinear ? 4.0 : null);
    final arguments = <String, Object?>{
      if (outputMode case final mode?) 'outputMode': mode.nativeValue,
      if (requestedHeadroom case final headroom?) 'edrHeadroom': headroom,
      if (upscaler case final mode?) 'upscaler': mode.nativeValue,
      if (videoAlphaMode != ErikaVideoAlphaMode.opaque)
        'videoAlphaMode': videoAlphaMode.nativeValue,
      if (hdrDebug) 'hdrDebug': true,
      if (allowBackgroundPlayback) 'allowBackgroundPlayback': true,
    };
    if (hdrDebug) {
      debugPrint('ErikaHDR[Dart]: create arguments=$arguments');
    }
    final playerId = await _channel.invokeMethod<int>('create', arguments);
    if (playerId == null || playerId <= 0) {
      throw StateError('Erika presenter creation failed.');
    }
    _id = playerId;
    _controllerFor(playerId);
    return playerId;
  }

  Future<int> _requireActiveAfter(Future<int> player) async {
    final playerId = await player;
    if (_disposed) {
      throw StateError('ErikaPlayer has been disposed.');
    }
    return playerId;
  }

  Future<void> _invokeForPlayer(String method) async {
    final playerId = await ensureCreated();
    await _invoke(method, <String, Object?>{'playerId': playerId});
  }

  Future<void> _invoke(String method, Map<String, Object?> arguments) async {
    await _channel.invokeMethod<void>(method, arguments);
  }

  static StreamController<ErikaPlayerEvent> _controllerFor(int playerId) {
    return _controllers.putIfAbsent(
      playerId,
      () => StreamController<ErikaPlayerEvent>.broadcast(),
    );
  }

  static void _dispatchNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) {
      return;
    }
    final event = ErikaPlayerEvent.fromMap(rawEvent);
    final controller = _controllers[event.playerId];
    controller?.add(event);
  }
}
