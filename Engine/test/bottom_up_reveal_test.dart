import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/animation_manager.dart';
import 'package:sakiengine/src/widgets/common/bottom_up_reveal.dart';

void main() {
  tearDown(AnimationManager.clearCache);

  test('animation preset starts hidden and finishes fully revealed', () {
    AnimationManager.loadAnimationsFromStringForTesting('''
reveal_from_bottom
reveal+0
linear 1.2 reveal+1
''');

    expect(
      AnimationManager.getAnimationPresetProperties('reveal_from_bottom'),
      containsPair('reveal', 0.0),
    );
    final finalProperties = AnimationManager.resolveFinalProperties(
      'reveal_from_bottom',
      const <String, double>{},
    );
    expect(finalProperties, containsPair('reveal', 1.0));
  });

  testWidgets('reveal grows upward while its bottom edge stays fixed', (
    tester,
  ) async {
    Widget buildReveal(double progress) {
      return MaterialApp(
        home: Align(
          alignment: Alignment.bottomLeft,
          child: BottomUpReveal(
            progress: progress,
            child: const SizedBox(width: 80, height: 200),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildReveal(0.25));
    expect(tester.getSize(find.byType(BottomUpReveal)), const Size(80, 50));
    final firstBottom = tester.getBottomLeft(find.byType(BottomUpReveal)).dy;

    await tester.pumpWidget(buildReveal(0.75));
    expect(tester.getSize(find.byType(BottomUpReveal)), const Size(80, 150));
    expect(tester.getBottomLeft(find.byType(BottomUpReveal)).dy, firstBottom);
  });
}
