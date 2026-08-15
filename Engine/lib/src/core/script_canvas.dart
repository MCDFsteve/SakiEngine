import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Paint callback for a blocking, full-screen scripted canvas performance.
///
/// [progress] advances from 0 to 1 over the duration supplied by the script.
/// The project owns all artwork; the engine owns sizing, animation, input
/// blocking, fast-forward completion, and lifecycle.
typedef ScriptCanvasPaintCallback =
    void Function(Canvas canvas, Size size, double progress);

@immutable
class ScriptCanvasDefinition {
  final ScriptCanvasPaintCallback paint;

  const ScriptCanvasDefinition({required this.paint});
}
