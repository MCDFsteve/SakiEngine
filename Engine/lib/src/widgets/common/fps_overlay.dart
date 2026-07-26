import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/performance_monitor.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/utils/smart_asset_image.dart';

class FpsOverlay extends StatefulWidget {
  const FpsOverlay({super.key});

  @override
  State<FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<FpsOverlay> {
  static const String _tooltipAssetName = 'gui/tooltips.png';
  static const double _tooltipBaseWidth = 88.0;
  static const double _tooltipBaseHeight = 34.0;
  static const double _titleBarHeightBase = 39.0;
  static const double _titleBarHeightScale = 0.84;

  final SakiPerformanceMonitor _monitor = SakiPerformanceMonitor.instance;

  @override
  void initState() {
    super.initState();
    _monitor.start();
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = context.scaleFor(ComponentType.ui);
    final rightInset = (12.0 * uiScale).clamp(6.0, 24.0).toDouble();
    final topGap = (8.0 * uiScale).clamp(4.0, 16.0).toDouble();
    final topInset = (12.0 * uiScale).clamp(6.0, 24.0).toDouble();
    final safeTop = MediaQuery.paddingOf(context).top;
    final titleBarHeight =
        (_titleBarHeightBase * uiScale * _titleBarHeightScale)
            .clamp(30.0, 58.0)
            .toDouble();
    final topOffset = safeTop +
        (SettingsManager().currentIsFullscreen
            ? topInset
            : titleBarHeight + topGap);

    return Positioned(
      top: topOffset,
      right: rightInset,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: ListenableBuilder(
            listenable: _monitor,
            builder: (context, child) {
              final snapshot = _monitor.snapshot;
              return kEngineDebugMode
                  ? _buildDiagnosticOverlay(context, snapshot, uiScale)
                  : _buildCompactOverlay(context, snapshot, uiScale);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildCompactOverlay(
    BuildContext context,
    PerformanceSnapshot snapshot,
    double uiScale,
  ) {
    final config = SakiEngineConfig();
    final tooltipHeight =
        (_tooltipBaseHeight * uiScale).clamp(22.0, 50.0).toDouble();
    final tooltipWidth =
        tooltipHeight * (_tooltipBaseWidth / _tooltipBaseHeight);

    return SizedBox(
      width: tooltipWidth,
      height: tooltipHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          SmartAssetImage(
            assetName: _tooltipAssetName,
            fit: BoxFit.contain,
            errorWidget: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.35),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(6 * uiScale),
              ),
            ),
          ),
          Center(
            child: Text(
              snapshot.fps > 0
                  ? 'FPS ${snapshot.fps.toStringAsFixed(1)}'
                  : 'FPS --',
              textHeightBehavior: const TextHeightBehavior(
                applyHeightToFirstAscent: false,
                applyHeightToLastDescent: false,
              ),
              style: config.dialogueTextStyle.copyWith(
                fontSize: (tooltipHeight * 0.4).clamp(9.0, 18.0).toDouble(),
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w700,
                color: const Color(0xFFF6F2FF),
                height: 1,
                shadows: const [
                  Shadow(
                    color: Color(0x99000000),
                    offset: Offset(1, 1),
                    blurRadius: 0,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticOverlay(
    BuildContext context,
    PerformanceSnapshot snapshot,
    double uiScale,
  ) {
    final accent = _statusColor(snapshot.bottleneck);
    final width = (310.0 * uiScale).clamp(280.0, 420.0).toDouble();
    final padding = (12.0 * uiScale).clamp(10.0, 18.0).toDouble();
    final smallFont = (11.0 * uiScale).clamp(10.0, 15.0).toDouble();
    final valueFont = (13.0 * uiScale).clamp(12.0, 18.0).toDouble();

    return Container(
      width: width,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: const Color(0xE612151C),
        border: Border.all(color: accent.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(8 * uiScale),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: const Color(0xFFE8EAF0),
          fontSize: smallFont,
          height: 1.25,
          decoration: TextDecoration.none,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8 * uiScale,
                  height: 8 * uiScale,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 7 * uiScale),
                Text(
                  snapshot.fps > 0
                      ? '${snapshot.fps.toStringAsFixed(1)} FPS'
                      : 'FPS --',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: (18.0 * uiScale).clamp(16.0, 24.0).toDouble(),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  snapshot.bottleneckLabel,
                  style: TextStyle(
                    color: accent,
                    fontSize: valueFont,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            SizedBox(height: 8 * uiScale),
            Row(
              children: [
                Expanded(
                  child: _buildMetric(
                    'UI',
                    snapshot.averageBuildMs,
                    snapshot.p95BuildMs,
                    snapshot.frameBudgetMs,
                    valueFont,
                  ),
                ),
                Expanded(
                  child: _buildMetric(
                    'Raster',
                    snapshot.averageRasterMs,
                    snapshot.p95RasterMs,
                    snapshot.frameBudgetMs,
                    valueFont,
                  ),
                ),
                Expanded(
                  child: _buildMetric(
                    'Schedule',
                    snapshot.averageSchedulingMs,
                    snapshot.p95SchedulingMs,
                    snapshot.frameBudgetMs,
                    valueFont,
                  ),
                ),
              ],
            ),
            SizedBox(height: 7 * uiScale),
            Text(
              'Frame avg/p95 '
              '${snapshot.averageFrameIntervalMs.toStringAsFixed(1)} / '
              '${snapshot.p95FrameIntervalMs.toStringAsFixed(1)} ms'
              '  ·  Jank ${(snapshot.jankRate * 100).toStringAsFixed(0)}%'
              '  ·  ${snapshot.frameRateLimit == 0 ? 'uncapped' : 'cap ${snapshot.frameRateLimit}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFFAFB5C2),
                fontSize: smallFont,
              ),
            ),
            SizedBox(height: 5 * uiScale),
            Text(
              snapshot.diagnosis,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFFD8DCE6),
                fontSize: smallFont,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetric(
    String label,
    double averageMs,
    double p95Ms,
    double budgetMs,
    double fontSize,
  ) {
    final color = p95Ms > budgetMs
        ? const Color(0xFFFF6B6B)
        : p95Ms > budgetMs * 0.7
            ? const Color(0xFFFFC857)
            : const Color(0xFF7DDBA3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: const Color(0xFF9299A8),
            fontSize: fontSize * 0.85,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          '${averageMs.toStringAsFixed(1)}/${p95Ms.toStringAsFixed(1)}',
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Color _statusColor(PerformanceBottleneck bottleneck) {
    switch (bottleneck) {
      case PerformanceBottleneck.collecting:
        return const Color(0xFF8AA4D6);
      case PerformanceBottleneck.smooth:
        return const Color(0xFF63D297);
      case PerformanceBottleneck.frameRateCap:
        return const Color(0xFF77BDFB);
      case PerformanceBottleneck.ui:
      case PerformanceBottleneck.raster:
      case PerformanceBottleneck.uiAndRaster:
      case PerformanceBottleneck.uiAndScheduling:
        return const Color(0xFFFF6B6B);
      case PerformanceBottleneck.scheduling:
      case PerformanceBottleneck.pipeline:
        return const Color(0xFFFFC857);
    }
  }
}
