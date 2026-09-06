import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/core/debug_command_menu.dart';
import 'package:sakiengine/src/core/game_module.dart';
import 'package:sakiengine/src/widgets/command_grid_menu.dart';
import 'package:sakiengine/src/widgets/command_radial_wheel.dart';

void main() {
  test(
    'default projects add no command menus and reserved shortcuts stay owned by the engine',
    () {
      expect(DefaultGameModule().debugCommandMenus, isEmpty);
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.digit1,
      ]) {
        expect(
          DebugCommandMenu(
            shortcutKey: key,
            open: (_) async => null,
          ).matchesShortcut(key),
          isFalse,
        );
      }
    },
  );

  for (final size in [const Size(800, 600), const Size(1280, 720)]) {
    testWidgets('grid fits $size and Escape dismisses without a modal route', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                CommandGridMenu(
                  title: 'Project command',
                  options: const [CommandWheelOption(id: 'one', label: 'One')],
                  center: size.center(Offset.zero),
                  onHighlightedOptionChanged: (_) {},
                  onDismiss: () => dismissed = true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text('Project command'));
      expect(title.left, greaterThanOrEqualTo(12));
      expect(title.right, lessThanOrEqualTo(size.width - 12));
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(CommandRadialWheel), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(dismissed, isTrue);
    });
  }

  testWidgets('compact grid leaves the lower-left game preview visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              CommandGridMenu(
                title: 'Portraits',
                options: const [CommandWheelOption(id: 'one', label: 'One')],
                center: const Offset(10, 590),
                maxSize: const Size(540, 620),
                alignment: Alignment.topRight,
                onHighlightedOptionChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    final panel = tester.getRect(
      find
          .descendant(
            of: find.byType(CommandGridMenu),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(panel, const Rect.fromLTWH(248, 12, 540, 576));
    expect(tester.takeException(), isNull);
  });
}
