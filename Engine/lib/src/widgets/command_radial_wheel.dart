import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sakiengine/src/widgets/smart_image.dart';

class CommandWheelOption {
  final String id;
  final String label;
  final String? imagePath;

  const CommandWheelOption({
    required this.id,
    required this.label,
    this.imagePath,
  });
}

/// Debug命令轮盘（按住Shift显示，松开应用）
class CommandRadialWheel extends StatefulWidget {
  final String title;
  final String applyHint;
  final String? currentOptionId;
  final List<CommandWheelOption> options;
  final Offset center;
  final ValueChanged<String> onHighlightedOptionChanged;
  final VoidCallback? onDismiss;

  const CommandRadialWheel({
    super.key,
    required this.title,
    required this.options,
    required this.center,
    required this.onHighlightedOptionChanged,
    this.currentOptionId,
    this.applyHint = 'Release Shift To Apply',
    this.onDismiss,
  });

  @override
  State<CommandRadialWheel> createState() => _CommandRadialWheelState();
}

class _CommandRadialWheelState extends State<CommandRadialWheel> {
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _syncHighlightWithCurrent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.options.isEmpty) {
        return;
      }
      widget.onHighlightedOptionChanged(widget.options[_highlightedIndex].id);
    });
  }

  @override
  void didUpdateWidget(covariant CommandRadialWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.options.isEmpty) {
      return;
    }

    final optionsChanged =
        widget.options.length != oldWidget.options.length ||
        widget.options.asMap().entries.any((entry) {
          final index = entry.key;
          if (index >= oldWidget.options.length) {
            return true;
          }
          final oldOption = oldWidget.options[index];
          final option = entry.value;
          return oldOption.id != option.id ||
              oldOption.label != option.label ||
              oldOption.imagePath != option.imagePath;
        });
    if (optionsChanged || widget.currentOptionId != oldWidget.currentOptionId) {
      _syncHighlightWithCurrent();
      widget.onHighlightedOptionChanged(widget.options[_highlightedIndex].id);
    }
  }

  void _syncHighlightWithCurrent() {
    if (widget.options.isEmpty) {
      _highlightedIndex = 0;
      return;
    }
    final currentId = widget.currentOptionId;
    if (currentId == null || currentId.isEmpty) {
      _highlightedIndex = _highlightedIndex.clamp(0, widget.options.length - 1);
      return;
    }
    final currentIndex = widget.options.indexWhere((o) => o.id == currentId);
    if (currentIndex >= 0) {
      _highlightedIndex = currentIndex;
      return;
    }
    _highlightedIndex = _highlightedIndex.clamp(0, widget.options.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) {
      return const SizedBox.shrink();
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onDismiss?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Positioned.fill(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final center = Offset(
              widget.center.dx.clamp(0.0, size.width),
              widget.center.dy.clamp(0.0, size.height),
            );
            final maxRadiusByEdges = [
              center.dx,
              center.dy,
              size.width - center.dx,
              size.height - center.dy,
            ].reduce(math.min);
            final outerRadius = math.max(
              96.0,
              math.min(maxRadiusByEdges - 12, 224.0),
            );
            final innerRadius = outerRadius * 0.45;

            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (event) =>
                  _updateHighlightFromPointer(event.localPosition, center),
              onPointerMove: (event) =>
                  _updateHighlightFromPointer(event.localPosition, center),
              onPointerHover: (event) =>
                  _updateHighlightFromPointer(event.localPosition, center),
              child: Stack(
                children: [
                  CustomPaint(
                    size: size,
                    painter: _CommandRadialWheelPainter(
                      center: center,
                      outerRadius: outerRadius,
                      innerRadius: innerRadius,
                      segmentCount: widget.options.length,
                      highlightedIndex: _highlightedIndex,
                    ),
                  ),
                  ..._buildSegmentLabels(
                    center: center,
                    outerRadius: outerRadius,
                    innerRadius: innerRadius,
                  ),
                  _buildCenterLabel(center: center, innerRadius: innerRadius),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildSegmentLabels({
    required Offset center,
    required double outerRadius,
    required double innerRadius,
  }) {
    final widgets = <Widget>[];
    final count = widget.options.length;
    final labelRadius = (outerRadius + innerRadius) * 0.52;
    final step = (math.pi * 2) / count;
    const startAngle = -math.pi / 2;

    for (var i = 0; i < count; i++) {
      final angle = startAngle + (i + 0.5) * step;
      final position =
          center + Offset(math.cos(angle), math.sin(angle)) * labelRadius;
      final isSelected = i == _highlightedIndex;
      final option = widget.options[i];

      widgets.add(
        Positioned(
          left: position.dx - 62,
          top: position.dy - 44,
          width: 124,
          child: IgnorePointer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (option.imagePath != null && option.imagePath!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _TopSquarePreview(
                      imagePath: option.imagePath!,
                      size: isSelected ? 44 : 38,
                      selected: isSelected,
                    ),
                  ),
                Text(
                  option.label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? const Color(0xFFFFF0A6) : Colors.white,
                    fontSize: isSelected ? 14 : 12,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    shadows: const [
                      Shadow(
                        blurRadius: 6,
                        color: Colors.black54,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildCenterLabel({
    required Offset center,
    required double innerRadius,
  }) {
    final selectedOption = widget.options[_highlightedIndex];
    return Positioned(
      left: center.dx - innerRadius * 0.92,
      top: center.dy - innerRadius * 0.92,
      width: innerRadius * 1.84,
      height: innerRadius * 1.84,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A).withOpacity(0.92),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withOpacity(0.24),
              width: 1.2,
            ),
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                selectedOption.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.applyHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _updateHighlightFromPointer(Offset localPosition, Offset center) {
    if (widget.options.isEmpty) {
      return;
    }

    final offset = localPosition - center;
    final angle = math.atan2(offset.dy, offset.dx);
    final normalized = (angle + math.pi / 2 + math.pi * 2) % (math.pi * 2);
    final step = (math.pi * 2) / widget.options.length;
    final index = (normalized ~/ step).clamp(0, widget.options.length - 1);
    if (index == _highlightedIndex) {
      return;
    }

    setState(() {
      _highlightedIndex = index;
    });
    widget.onHighlightedOptionChanged(widget.options[index].id);
  }
}

class _TopSquarePreview extends StatelessWidget {
  final String imagePath;
  final double size;
  final bool selected;

  const _TopSquarePreview({
    required this.imagePath,
    required this.size,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(6);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: selected
              ? const Color(0xFFF1C15D).withOpacity(0.95)
              : Colors.white.withOpacity(0.35),
          width: selected ? 1.8 : 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          color: const Color(0xFF121212),
          child: ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              child: OverflowBox(
                alignment: Alignment.topCenter,
                minWidth: size,
                maxWidth: size,
                minHeight: 0,
                maxHeight: double.infinity,
                child: SmartImage.asset(
                  imagePath,
                  width: size,
                  fit: BoxFit.fitWidth,
                  errorWidget: Container(
                    color: const Color(0xFF1E1E1E),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: size * 0.48,
                      color: Colors.white38,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandRadialWheelPainter extends CustomPainter {
  final Offset center;
  final double outerRadius;
  final double innerRadius;
  final int segmentCount;
  final int highlightedIndex;

  const _CommandRadialWheelPainter({
    required this.center,
    required this.outerRadius,
    required this.innerRadius,
    required this.segmentCount,
    required this.highlightedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (segmentCount <= 0) {
      return;
    }

    final sweep = (math.pi * 2) / segmentCount;
    const startAngle = -math.pi / 2;
    final outerRect = Rect.fromCircle(center: center, radius: outerRadius);
    final innerRect = Rect.fromCircle(center: center, radius: innerRadius);

    for (var i = 0; i < segmentCount; i++) {
      final from = startAngle + i * sweep;
      final isSelected = i == highlightedIndex;
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = isSelected
            ? const Color(0xFFDA9D2B).withOpacity(0.78)
            : const Color(0xFF262626).withOpacity(0.82);

      final path = Path()
        ..arcTo(outerRect, from, sweep, false)
        ..arcTo(innerRect, from + sweep, -sweep, false)
        ..close();
      canvas.drawPath(path, fillPaint);
    }

    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withOpacity(0.24);
    canvas.drawCircle(center, outerRadius, strokePaint);
    canvas.drawCircle(center, innerRadius, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _CommandRadialWheelPainter oldDelegate) {
    return oldDelegate.highlightedIndex != highlightedIndex ||
        oldDelegate.segmentCount != segmentCount ||
        oldDelegate.center != center ||
        oldDelegate.outerRadius != outerRadius ||
        oldDelegate.innerRadius != innerRadius;
  }
}
