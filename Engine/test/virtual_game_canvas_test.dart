import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/widgets/common/virtual_game_canvas.dart';

void main() {
  testWidgets('fills a wider host when placed in a loose Stack', (
    tester,
  ) async {
    final config = SakiEngineConfig();
    final previousWidth = config.logicalWidth;
    final previousHeight = config.logicalHeight;
    config.logicalWidth = 1920;
    config.logicalHeight = 1080;
    addTearDown(() {
      config.logicalWidth = previousWidth;
      config.logicalHeight = previousHeight;
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2166, 1175);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          children: [
            SakiVirtualGameCanvas(
              key: ValueKey('game-canvas'),
              child: ColoredBox(
                key: ValueKey('logical-content'),
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('game-canvas'))),
      const Size(2166, 1175),
    );

    final contentRect = tester.getRect(
      find.byKey(const ValueKey('logical-content')),
    );
    expect(contentRect.left, lessThanOrEqualTo(0));
    expect(contentRect.top, lessThanOrEqualTo(0));
    expect(contentRect.right, greaterThanOrEqualTo(2166));
    expect(contentRect.bottom, greaterThanOrEqualTo(1175));
  });
}
