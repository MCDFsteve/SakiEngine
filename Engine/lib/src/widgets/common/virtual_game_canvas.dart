import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';

/// Presents the game as a fixed-size logical canvas and scales it uniformly to
/// cover the host window. Descendants keep seeing the engine logical resolution.
class SakiVirtualGameCanvas extends StatelessWidget {
  final Widget child;
  final double? selectedAspectRatio;
  final bool matchAvailableAspectRatio;
  final List<double> aspectRatioPresets;

  const SakiVirtualGameCanvas({
    super.key,
    required this.child,
    this.selectedAspectRatio,
    this.matchAvailableAspectRatio = false,
    this.aspectRatioPresets = const <double>[],
  });

  EdgeInsets _scaleInsets(EdgeInsets insets, double divisor) {
    if (divisor <= 0 || divisor == 1.0) {
      return insets;
    }
    return EdgeInsets.fromLTRB(
      insets.left / divisor,
      insets.top / divisor,
      insets.right / divisor,
      insets.bottom / divisor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = SakiEngineConfig();
    final canvasWidth = config.logicalWidth;
    final canvasHeight = config.logicalHeight;
    if (canvasWidth <= 0 || canvasHeight <= 0) {
      return child;
    }
    final fallbackAspectRatio = canvasWidth / canvasHeight;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        if (!availableWidth.isFinite ||
            !availableHeight.isFinite ||
            availableWidth <= 0 ||
            availableHeight <= 0) {
          return child;
        }

        final availableAspectRatio = availableWidth / availableHeight;
        final canvasAspectRatio = matchAvailableAspectRatio
            ? availableAspectRatio
            : _normalizeAspectRatio(selectedAspectRatio) ??
                  _resolveClosestAspectRatio(
                    availableAspectRatio,
                    fallbackAspectRatio,
                  );
        final selectedCanvasWidth = canvasHeight * canvasAspectRatio;
        final scaleX = availableWidth / selectedCanvasWidth;
        final scaleY = availableHeight / canvasHeight;
        final scale = scaleX > scaleY ? scaleX : scaleY;
        if (scale <= 0) {
          return child;
        }
        final canvasSize = Size(selectedCanvasWidth, canvasHeight);
        final baseMediaQuery = MediaQuery.of(context);
        final virtualMediaQuery = baseMediaQuery.copyWith(
          size: canvasSize,
          padding: _scaleInsets(baseMediaQuery.padding, scale),
          viewPadding: _scaleInsets(baseMediaQuery.viewPadding, scale),
          viewInsets: _scaleInsets(baseMediaQuery.viewInsets, scale),
          systemGestureInsets: _scaleInsets(
            baseMediaQuery.systemGestureInsets,
            scale,
          ),
        );

        // LayoutBuilder can receive loose constraints (for example as a
        // non-positioned child of a Stack). Pin the outer canvas to the host
        // size so FittedBox covers the full viewport instead of shrink-wrapping
        // to the logical 16:9 child and exposing the black backing at an edge.
        return SizedBox(
          width: availableWidth,
          height: availableHeight,
          child: ColoredBox(
            color: Colors.black,
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: selectedCanvasWidth,
                  height: canvasHeight,
                  child: MediaQuery(data: virtualMediaQuery, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  double _resolveClosestAspectRatio(
    double targetAspectRatio,
    double fallbackAspectRatio,
  ) {
    final candidates = <double>[
      fallbackAspectRatio,
      for (final preset in aspectRatioPresets)
        if (preset.isFinite && preset > 0) preset,
    ];
    var best = candidates.first;
    var bestDiff = (best - targetAspectRatio).abs();
    for (final candidate in candidates.skip(1)) {
      final diff = (candidate - targetAspectRatio).abs();
      if (diff < bestDiff) {
        best = candidate;
        bestDiff = diff;
      }
    }
    return best;
  }

  double? _normalizeAspectRatio(double? aspectRatio) {
    if (aspectRatio == null || !aspectRatio.isFinite || aspectRatio <= 0) {
      return null;
    }
    return aspectRatio;
  }
}
