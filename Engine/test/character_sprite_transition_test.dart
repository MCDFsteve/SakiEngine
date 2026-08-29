import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/rendering/composite_cg_renderer.dart';
import 'package:sakiengine/src/screens/game_play_screen.dart';
import 'package:sakiengine/src/utils/engine_asset_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('different sprite ratios keep independent dissolve geometry', () {
    const canvasSize = Size(299, 1048);
    final fromRect = calculateDissolveCoverRect(canvasSize, 423, 1049);
    final toRect = calculateDissolveCoverRect(canvasSize, 299, 1048);

    expect(fromRect.width / fromRect.height, closeTo(423 / 1049, 0.000001));
    expect(toRect.width / toRect.height, closeTo(299 / 1048, 0.000001));
    expect(fromRect.width, greaterThan(toRect.width));
  });

  test('aspect-preserving dissolve shader compiles', () async {
    final program = await EngineAssetLoader.loadFragmentProgram(
      'assets/shaders/dissolve.frag',
    );
    expect(program, isNotNull);
  });

  Future<ui.Image> createImage(Color color) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = color);
    return recorder.endRecording().toImage(4, 4);
  }

  Widget buildSprite({
    required ui.Image image,
    required String resourceId,
    String characterKey = 'slot:aru',
  }) {
    return MaterialApp(
      home: Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: KeyedSubtree(
            key: characterPositionedRenderKey(characterKey),
            child: DirectCgDisplay(
              key: characterCompositeRenderKey(characterKey),
              image: image,
              resourceId: resourceId,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'different resources in the same character slot reuse the dissolve state',
    (tester) async {
      final firstImage = await createImage(Colors.pink);
      final secondImage = await createImage(Colors.purple);
      addTearDown(firstImage.dispose);
      addTearDown(secondImage.dispose);

      await tester.pumpWidget(
        buildSprite(image: firstImage, resourceId: 'aru'),
      );
      await tester.pumpAndSettle();
      final firstState = tester.state(find.byType(DirectCgDisplay));

      await tester.pumpWidget(
        buildSprite(image: secondImage, resourceId: 'aru3'),
      );
      await tester.pump();

      expect(tester.state(find.byType(DirectCgDisplay)), same(firstState));

      await tester.pump(const Duration(milliseconds: 300));
    },
  );

  testWidgets('different character slots keep independent render state', (
    tester,
  ) async {
    final image = await createImage(Colors.pink);
    addTearDown(image.dispose);

    await tester.pumpWidget(buildSprite(image: image, resourceId: 'aru'));
    await tester.pumpAndSettle();
    final aruState = tester.state(find.byType(DirectCgDisplay));

    await tester.pumpWidget(
      buildSprite(
        image: image,
        resourceId: 'aru',
        characterKey: 'slot:aru_shadow_1',
      ),
    );
    await tester.pump();

    expect(tester.state(find.byType(DirectCgDisplay)), isNot(same(aruState)));
  });
}
