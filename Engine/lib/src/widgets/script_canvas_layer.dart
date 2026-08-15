import 'package:flutter/material.dart';
import 'package:sakiengine/src/core/script_canvas.dart';

/// Hosts one project-provided full-screen canvas performance.
class ScriptCanvasLayer extends StatefulWidget {
  final ScriptCanvasDefinition definition;
  final Duration duration;
  final int revision;

  const ScriptCanvasLayer({
    super.key,
    required this.definition,
    required this.duration,
    required this.revision,
  });

  @override
  State<ScriptCanvasLayer> createState() => _ScriptCanvasLayerState();
}

class _ScriptCanvasLayerState extends State<ScriptCanvasLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _restart();
  }

  @override
  void didUpdateWidget(covariant ScriptCanvasLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        oldWidget.duration != widget.duration) {
      _restart();
    }
  }

  void _restart() {
    if (widget.duration <= Duration.zero) {
      _controller
        ..stop()
        ..value = 1;
      return;
    }
    _controller
      ..duration = widget.duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AbsorbPointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _ScriptCanvasCustomPainter(
              definition: widget.definition,
              progress: _controller,
              revision: widget.revision,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _ScriptCanvasCustomPainter extends CustomPainter {
  final ScriptCanvasDefinition definition;
  final Animation<double> progress;
  final int revision;

  _ScriptCanvasCustomPainter({
    required this.definition,
    required this.progress,
    required this.revision,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    definition.paint(canvas, size, progress.value.clamp(0.0, 1.0).toDouble());
  }

  @override
  bool shouldRepaint(covariant _ScriptCanvasCustomPainter oldDelegate) {
    return oldDelegate.definition != definition ||
        oldDelegate.revision != revision;
  }
}
