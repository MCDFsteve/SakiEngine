import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Alignment, BoxFit, Size;
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/widgets/command_radial_wheel.dart';

/// Project commands use the engine's grid, keyboard routing and input blocking.
/// Built-in shortcuts retain priority over project registrations.
class DebugCommandMenu {
  final LogicalKeyboardKey shortcutKey;
  final Future<DebugCommandMenuSession?> Function(GameManager manager) open;

  const DebugCommandMenu({required this.shortcutKey, required this.open});

  bool matchesShortcut(LogicalKeyboardKey key) =>
      key == shortcutKey &&
      !const [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.exclamation,
      ].contains(key);
}

class DebugCommandMenuSession {
  final String title;
  final List<CommandWheelOption> options;
  final String? currentOptionId;
  final String applyHint;
  final Size maxSize;
  final Alignment? alignment;
  final BoxFit imageFit;
  final void Function(String id) onPreview;
  final Future<void> Function(String id)? onApply;
  final VoidCallback onClose;

  const DebugCommandMenuSession({
    required this.title,
    required this.options,
    required this.currentOptionId,
    required this.onPreview,
    required this.onClose,
    this.onApply,
    this.applyHint = 'Double Click To Apply',
    this.maxSize = const Size(880, 620),
    this.alignment,
    this.imageFit = BoxFit.cover,
  });
}
