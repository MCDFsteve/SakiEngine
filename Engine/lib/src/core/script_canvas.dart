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
  final Duration animationDuration;
  final bool loop;

  const ScriptCanvasDefinition({
    required this.paint,
    this.animationDuration = Duration.zero,
    this.loop = false,
  });
}

/// One named canvas exposed by a project module to scripts and debug tooling.
@immutable
class ScriptCanvasRegistration {
  final String id;
  final String displayName;
  final ScriptCanvasDefinition definition;

  const ScriptCanvasRegistration({
    required this.id,
    required this.displayName,
    required this.definition,
  });
}
