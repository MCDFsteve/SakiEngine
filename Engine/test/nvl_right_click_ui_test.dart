import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/widgets/common/right_click_ui_manager.dart';
import 'package:sakiengine/src/widgets/nvl_screen.dart';

void main() {
  final uiManager = GlobalRightClickUIManager();

  setUp(() {
    uiManager.setUIHidden(false);
  });

  tearDown(() {
    uiManager.setUIHidden(false);
  });

  testWidgets('NVL right click toggles UI exactly once', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RightClickUIManager(
          backgroundChild: const ColoredBox(color: Colors.black),
          child: const NvlScreen(
            nvlDialogues: [],
            isFastForwarding: true,
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(NvlScreen));
    await tester.tapAt(
      center,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(uiManager.isUIHidden, isTrue);

    await tester.tapAt(
      center,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(uiManager.isUIHidden, isFalse);
  });
}
