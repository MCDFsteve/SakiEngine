import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/expression_offset_manager.dart';
import 'package:sakiengine/src/utils/smart_asset_image.dart';

import 'expression_preview_image_loader_io.dart'
    if (dart.library.html) 'expression_preview_image_loader_web.dart';

@immutable
class ExpressionPreviewPixels {
  final int width;
  final int height;
  final Uint8List rgba;

  const ExpressionPreviewPixels({
    required this.width,
    required this.height,
    required this.rgba,
  });
}

@immutable
class ExpressionPreviewTransform {
  final double xOffset;
  final double yOffset;
  final double opacity;
  final double scale;

  const ExpressionPreviewTransform({
    this.xOffset = 0,
    this.yOffset = 0,
    this.opacity = 1,
    this.scale = 1,
  });

  @override
  bool operator ==(Object other) {
    return other is ExpressionPreviewTransform &&
        other.xOffset == xOffset &&
        other.yOffset == yOffset &&
        other.opacity == opacity &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(xOffset, yOffset, opacity, scale);
}

@immutable
class ExpressionPreviewMetadata {
  final ui.Size canvasSize;
  final ui.Rect focusBounds;
  final ExpressionPreviewTransform expressionTransform;

  const ExpressionPreviewMetadata({
    required this.canvasSize,
    required this.focusBounds,
    required this.expressionTransform,
  });
}

/// Loads just enough pixel data to locate the actual changed expression area.
///
/// Work is serialized because character canvases can be several thousand pixels
/// tall. The pose pixels are retained only while the selector is open, while
/// expression pixels are released as soon as their focus metadata is computed.
class ExpressionPreviewMetadataRepository {
  final Map<String, Future<ExpressionPreviewPixels?>> _posePixels = {};
  final Map<String, Future<ExpressionPreviewMetadata?>> _metadata = {};
  Future<void> _analysisQueue = Future<void>.value();
  bool _isDisposed = false;

  Future<ExpressionPreviewMetadata?> load({
    required String poseAssetName,
    required String expressionAssetName,
    required ExpressionPreviewTransform expressionTransform,
  }) {
    if (_isDisposed) {
      return Future<ExpressionPreviewMetadata?>.value(null);
    }

    final cacheKey =
        '$poseAssetName\u0000$expressionAssetName\u0000'
        '${expressionTransform.xOffset}\u0000${expressionTransform.yOffset}\u0000'
        '${expressionTransform.opacity}\u0000${expressionTransform.scale}';
    final cached = _metadata[cacheKey];
    if (cached != null) {
      return cached;
    }

    final completer = Completer<ExpressionPreviewMetadata?>();
    _metadata[cacheKey] = completer.future;
    _analysisQueue = _analysisQueue.then((_) async {
      if (_isDisposed) {
        completer.complete(null);
        return;
      }

      try {
        final pose = await _posePixels.putIfAbsent(
          poseAssetName,
          () => _loadPixels(poseAssetName),
        );
        final expression = await _loadPixels(expressionAssetName);
        if (pose == null || expression == null) {
          completer.complete(null);
          return;
        }

        final changedBounds = findExpressionDifferenceBounds(
          base: pose,
          overlay: expression,
          transform: expressionTransform,
        );
        final fallbackBounds = findVisibleExpressionBounds(
          baseSize: ui.Size(pose.width.toDouble(), pose.height.toDouble()),
          expression: expression,
          transform: expressionTransform,
        );

        completer.complete(
          ExpressionPreviewMetadata(
            canvasSize: ui.Size(pose.width.toDouble(), pose.height.toDouble()),
            focusBounds:
                changedBounds ??
                fallbackBounds ??
                ui.Rect.fromLTWH(
                  0,
                  0,
                  pose.width.toDouble(),
                  pose.height.toDouble(),
                ),
            expressionTransform: expressionTransform,
          ),
        );
      } catch (error, stackTrace) {
        debugPrint(
          'Expression preview analysis failed for $expressionAssetName: '
          '$error\n$stackTrace',
        );
        completer.complete(null);
      }
    });

    return completer.future;
  }

  Future<ExpressionPreviewPixels?> _loadPixels(String assetName) async {
    final assetPath = await AssetManager().findAsset(assetName);
    if (assetPath == null) {
      return null;
    }

    final image = await loadExpressionPreviewImage(assetPath);
    if (image == null) {
      return null;
    }

    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) {
        return null;
      }
      return ExpressionPreviewPixels(
        width: image.width,
        height: image.height,
        rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  }

  void dispose() {
    _isDisposed = true;
    _posePixels.clear();
    _metadata.clear();
  }
}

/// Returns the robust bounding box of pixels that visibly change after the
/// expression layer is composited over the selected pose.
///
/// Transparent RGB garbage is ignored by comparing premultiplied output. A
/// small histogram quantile removes isolated export noise without assuming that
/// every expression asset is a sparse transparent overlay.
@visibleForTesting
ui.Rect? findExpressionDifferenceBounds({
  required ExpressionPreviewPixels base,
  required ExpressionPreviewPixels overlay,
  ExpressionPreviewTransform transform = const ExpressionPreviewTransform(),
  int differenceThreshold = 18,
  double outlierFraction = 0.005,
  int maxAnalysisSamples = 600000,
}) {
  if (!_hasValidPixelBuffer(base) ||
      !_hasValidPixelBuffer(overlay) ||
      transform.scale <= 0 ||
      transform.opacity <= 0) {
    return null;
  }

  final totalPixels = base.width * base.height;
  final stride = math.max(
    1,
    math.sqrt(totalPixels / math.max(1, maxAnalysisSamples)).ceil(),
  );
  final columnCount = (base.width + stride - 1) ~/ stride;
  final rowCount = (base.height + stride - 1) ~/ stride;
  final columnHits = List<int>.filled(columnCount, 0);
  final rowHits = List<int>.filled(rowCount, 0);
  var totalHits = 0;

  final opacity = transform.opacity.clamp(0.0, 1.0);
  for (var y = 0; y < base.height; y += stride) {
    final normalizedY = (y + 0.5) / base.height;
    final overlayNormalizedY =
        (normalizedY - transform.yOffset) / transform.scale;
    for (var x = 0; x < base.width; x += stride) {
      final normalizedX = (x + 0.5) / base.width;
      final overlayNormalizedX =
          (normalizedX - transform.xOffset) / transform.scale;

      final baseOffset = (y * base.width + x) * 4;
      var overlayRed = 0;
      var overlayGreen = 0;
      var overlayBlue = 0;
      var overlayAlpha = 0;
      if (overlayNormalizedX >= 0 &&
          overlayNormalizedX < 1 &&
          overlayNormalizedY >= 0 &&
          overlayNormalizedY < 1) {
        final overlayX = math.min(
          overlay.width - 1,
          (overlayNormalizedX * overlay.width).floor(),
        );
        final overlayY = math.min(
          overlay.height - 1,
          (overlayNormalizedY * overlay.height).floor(),
        );
        final overlayOffset = (overlayY * overlay.width + overlayX) * 4;
        overlayRed = overlay.rgba[overlayOffset];
        overlayGreen = overlay.rgba[overlayOffset + 1];
        overlayBlue = overlay.rgba[overlayOffset + 2];
        overlayAlpha = (overlay.rgba[overlayOffset + 3] * opacity).round();
      }

      final baseAlpha = base.rgba[baseOffset + 3];
      final inverseOverlayAlpha = 255 - overlayAlpha;
      final basePremultipliedRed =
          (base.rgba[baseOffset] * baseAlpha + 127) ~/ 255;
      final basePremultipliedGreen =
          (base.rgba[baseOffset + 1] * baseAlpha + 127) ~/ 255;
      final basePremultipliedBlue =
          (base.rgba[baseOffset + 2] * baseAlpha + 127) ~/ 255;
      final outputRed =
          (overlayRed * overlayAlpha + 127) ~/ 255 +
          (basePremultipliedRed * inverseOverlayAlpha + 127) ~/ 255;
      final outputGreen =
          (overlayGreen * overlayAlpha + 127) ~/ 255 +
          (basePremultipliedGreen * inverseOverlayAlpha + 127) ~/ 255;
      final outputBlue =
          (overlayBlue * overlayAlpha + 127) ~/ 255 +
          (basePremultipliedBlue * inverseOverlayAlpha + 127) ~/ 255;
      final outputAlpha =
          overlayAlpha + (baseAlpha * inverseOverlayAlpha + 127) ~/ 255;
      final difference = math.max(
        math.max(
          (outputRed - basePremultipliedRed).abs(),
          (outputGreen - basePremultipliedGreen).abs(),
        ),
        math.max(
          (outputBlue - basePremultipliedBlue).abs(),
          (outputAlpha - baseAlpha).abs(),
        ),
      );

      if (difference >= differenceThreshold) {
        columnHits[x ~/ stride]++;
        rowHits[y ~/ stride]++;
        totalHits++;
      }
    }
  }

  if (totalHits == 0) {
    return null;
  }

  final discardHits = totalHits >= 32
      ? math.max(1, (totalHits * outlierFraction).floor())
      : 0;
  final leftIndex = _lowerHistogramBound(columnHits, discardHits);
  final rightIndex = _upperHistogramBound(columnHits, discardHits);
  final topIndex = _lowerHistogramBound(rowHits, discardHits);
  final bottomIndex = _upperHistogramBound(rowHits, discardHits);
  if (leftIndex == null ||
      rightIndex == null ||
      topIndex == null ||
      bottomIndex == null) {
    return null;
  }

  return ui.Rect.fromLTRB(
    (leftIndex * stride).toDouble(),
    (topIndex * stride).toDouble(),
    math.min(base.width, (rightIndex + 1) * stride).toDouble(),
    math.min(base.height, (bottomIndex + 1) * stride).toDouble(),
  );
}

@visibleForTesting
ui.Rect? findVisibleExpressionBounds({
  required ui.Size baseSize,
  required ExpressionPreviewPixels expression,
  ExpressionPreviewTransform transform = const ExpressionPreviewTransform(),
  int alphaThreshold = 8,
}) {
  if (!_hasValidPixelBuffer(expression) || transform.scale <= 0) {
    return null;
  }

  var left = expression.width;
  var top = expression.height;
  var right = -1;
  var bottom = -1;
  for (var y = 0; y < expression.height; y++) {
    for (var x = 0; x < expression.width; x++) {
      final alpha = expression.rgba[(y * expression.width + x) * 4 + 3];
      if (alpha < alphaThreshold) {
        continue;
      }
      left = math.min(left, x);
      top = math.min(top, y);
      right = math.max(right, x);
      bottom = math.max(bottom, y);
    }
  }
  if (right < left || bottom < top) {
    return null;
  }

  final mapped = ui.Rect.fromLTRB(
    (transform.xOffset + left / expression.width * transform.scale) *
        baseSize.width,
    (transform.yOffset + top / expression.height * transform.scale) *
        baseSize.height,
    (transform.xOffset + (right + 1) / expression.width * transform.scale) *
        baseSize.width,
    (transform.yOffset + (bottom + 1) / expression.height * transform.scale) *
        baseSize.height,
  );
  return mapped.intersect(ui.Offset.zero & baseSize);
}

@visibleForTesting
ui.Rect fitExpressionFocusRect({
  required ui.Rect focusBounds,
  required ui.Size canvasSize,
  required ui.Size viewportSize,
  double paddingFraction = 0.18,
}) {
  if (canvasSize.isEmpty || viewportSize.isEmpty || focusBounds.isEmpty) {
    return ui.Offset.zero & canvasSize;
  }

  final canvasRect = ui.Offset.zero & canvasSize;
  final padding = math.max(
    6.0,
    math.max(focusBounds.width, focusBounds.height) * paddingFraction,
  );
  var result = _clampRectToCanvas(focusBounds.inflate(padding), canvasSize);
  final targetAspect = viewportSize.width / viewportSize.height;
  final resultAspect = result.width / result.height;

  if (resultAspect < targetAspect) {
    final desiredWidth = math.min(
      canvasSize.width,
      result.height * targetAspect,
    );
    result = _rectFromCenter(
      center: result.center,
      width: desiredWidth,
      height: result.height,
      canvasSize: canvasSize,
    );
  } else if (resultAspect > targetAspect) {
    final desiredHeight = math.min(
      canvasSize.height,
      result.width / targetAspect,
    );
    result = _rectFromCenter(
      center: result.center,
      width: result.width,
      height: desiredHeight,
      canvasSize: canvasSize,
    );
  }

  return result.intersect(canvasRect);
}

class ExpressionFocusPreview extends StatefulWidget {
  final ExpressionPreviewMetadataRepository metadataRepository;
  final String characterId;
  final String pose;
  final String expression;
  final bool showPoseLayer;
  final double paddingFraction;

  const ExpressionFocusPreview({
    super.key,
    required this.metadataRepository,
    required this.characterId,
    required this.pose,
    required this.expression,
    this.showPoseLayer = true,
    this.paddingFraction = 0.18,
  });

  @override
  State<ExpressionFocusPreview> createState() => _ExpressionFocusPreviewState();
}

class _ExpressionFocusPreviewState extends State<ExpressionFocusPreview> {
  late Future<ExpressionPreviewMetadata?> _metadata;

  String get _poseAssetName =>
      'characters/${widget.characterId}-${widget.pose}';
  String get _expressionAssetName =>
      'characters/${widget.characterId}-${widget.expression}';

  @override
  void initState() {
    super.initState();
    _reloadMetadata();
  }

  @override
  void didUpdateWidget(covariant ExpressionFocusPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.metadataRepository != widget.metadataRepository ||
        oldWidget.characterId != widget.characterId ||
        oldWidget.pose != widget.pose ||
        oldWidget.expression != widget.expression) {
      _reloadMetadata();
    }
  }

  void _reloadMetadata() {
    final (xOffset, yOffset, opacity, scale) = ExpressionOffsetManager()
        .getExpressionOffset(
          characterId: widget.characterId,
          pose: widget.pose,
          layerType: 'expression',
        );
    _metadata = widget.metadataRepository.load(
      poseAssetName: _poseAssetName,
      expressionAssetName: _expressionAssetName,
      expressionTransform: ExpressionPreviewTransform(
        xOffset: xOffset,
        yOffset: yOffset,
        opacity: opacity,
        scale: scale,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ExpressionPreviewMetadata?>(
      future: _metadata,
      builder: (context, snapshot) {
        final metadata = snapshot.data;
        if (metadata == null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _buildFullCanvasFallback(),
              if (snapshot.connectionState == ConnectionState.waiting)
                const Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final viewportSize = constraints.biggest;
            if (!viewportSize.width.isFinite ||
                !viewportSize.height.isFinite ||
                viewportSize.isEmpty) {
              return _buildFullCanvasFallback();
            }

            final sourceRect = fitExpressionFocusRect(
              focusBounds: metadata.focusBounds,
              canvasSize: metadata.canvasSize,
              viewportSize: viewportSize,
              paddingFraction: widget.paddingFraction,
            );
            final scale = math.min(
              viewportSize.width / sourceRect.width,
              viewportSize.height / sourceRect.height,
            );
            final canvasWidth = metadata.canvasSize.width * scale;
            final canvasHeight = metadata.canvasSize.height * scale;
            final sourceWidth = sourceRect.width * scale;
            final sourceHeight = sourceRect.height * scale;
            final left =
                (viewportSize.width - sourceWidth) / 2 -
                sourceRect.left * scale;
            final top =
                (viewportSize.height - sourceHeight) / 2 -
                sourceRect.top * scale;
            final transform = metadata.expressionTransform;

            Widget expressionLayer = SmartAssetImage(
              assetName: _expressionAssetName,
              fit: BoxFit.fill,
              width: canvasWidth * transform.scale,
              height: canvasHeight * transform.scale,
            );
            if (transform.opacity < 1) {
              expressionLayer = Opacity(
                opacity: transform.opacity.clamp(0.0, 1.0),
                child: expressionLayer,
              );
            }

            return ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (widget.showPoseLayer)
                    Positioned(
                      left: left,
                      top: top,
                      width: canvasWidth,
                      height: canvasHeight,
                      child: SmartAssetImage(
                        assetName: _poseAssetName,
                        fit: BoxFit.fill,
                        width: canvasWidth,
                        height: canvasHeight,
                      ),
                    ),
                  Positioned(
                    left: left + transform.xOffset * canvasWidth,
                    top: top + transform.yOffset * canvasHeight,
                    width: canvasWidth * transform.scale,
                    height: canvasHeight * transform.scale,
                    child: expressionLayer,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFullCanvasFallback() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.showPoseLayer)
          SmartAssetImage(assetName: _poseAssetName, fit: BoxFit.contain),
        SmartAssetImage(assetName: _expressionAssetName, fit: BoxFit.contain),
      ],
    );
  }
}

bool _hasValidPixelBuffer(ExpressionPreviewPixels pixels) {
  return pixels.width > 0 &&
      pixels.height > 0 &&
      pixels.rgba.length >= pixels.width * pixels.height * 4;
}

int? _lowerHistogramBound(List<int> histogram, int discardHits) {
  var accumulated = 0;
  for (var index = 0; index < histogram.length; index++) {
    accumulated += histogram[index];
    if (accumulated > discardHits) {
      return index;
    }
  }
  return null;
}

int? _upperHistogramBound(List<int> histogram, int discardHits) {
  var accumulated = 0;
  for (var index = histogram.length - 1; index >= 0; index--) {
    accumulated += histogram[index];
    if (accumulated > discardHits) {
      return index;
    }
  }
  return null;
}

ui.Rect _clampRectToCanvas(ui.Rect rect, ui.Size canvasSize) {
  return _rectFromCenter(
    center: rect.center,
    width: math.min(rect.width, canvasSize.width),
    height: math.min(rect.height, canvasSize.height),
    canvasSize: canvasSize,
  );
}

ui.Rect _rectFromCenter({
  required ui.Offset center,
  required double width,
  required double height,
  required ui.Size canvasSize,
}) {
  final halfWidth = width / 2;
  final halfHeight = height / 2;
  final centerX = center.dx.clamp(halfWidth, canvasSize.width - halfWidth);
  final centerY = center.dy.clamp(halfHeight, canvasSize.height - halfHeight);
  return ui.Rect.fromCenter(
    center: ui.Offset(centerX, centerY),
    width: width,
    height: height,
  );
}
