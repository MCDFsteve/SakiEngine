import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';

void main() {
  testWidgets('console sequence observes keys without consuming text input', (
    tester,
  ) async {
    var completed = false;
    var trailingHandlerSawC = false;
    final detector = KeySequenceDetector(
      sequence: const [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyO],
      onSequenceComplete: () => completed = true,
    );

    bool trailingHandler(KeyEvent event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.keyC) {
        trailingHandlerSawC = true;
      }
      return false;
    }

    detector.startListening();
    HardwareKeyboard.instance.addHandler(trailingHandler);
    addTearDown(() {
      HardwareKeyboard.instance.removeHandler(trailingHandler);
      detector.dispose();
    });

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);

    expect(trailingHandlerSawC, isTrue);
    expect(completed, isTrue);
  });

  testWidgets('console sequence pauses while an editor is active', (
    tester,
  ) async {
    var editorActive = true;
    var completed = false;
    final detector = KeySequenceDetector(
      sequence: const [LogicalKeyboardKey.keyC, LogicalKeyboardKey.keyO],
      onSequenceComplete: () => completed = true,
      shouldIgnore: () => editorActive,
    )..startListening();
    addTearDown(detector.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);
    expect(completed, isFalse);

    editorActive = false;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(completed, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);
    expect(completed, isTrue);
  });
}
