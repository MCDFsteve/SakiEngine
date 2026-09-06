import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/character_position_animator.dart';

void main() {
  List<CharacterPositionChange> positionChanges() => [
    CharacterPositionChange(characterId: 'saya', fromX: 0.2, toX: 0.8),
  ];

  List<CharacterAttributeChange> attributeChanges() => [
    CharacterAttributeChange(
      characterId: 'saya',
      fromAttributes: {'xcenter': 0.2, 'scale': 1.0},
      toAttributes: {'xcenter': 0.8, 'scale': 1.5},
    ),
  ];

  testWidgets('position animation reaches its target and completes once', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    addTearDown(animator.dispose);
    var completions = 0;
    double? position;
    var finished = false;
    final future = animator
        .animatePositionChanges(
          positionChanges: positionChanges(),
          vsync: tester,
          duration: const Duration(milliseconds: 100),
          curve: Curves.linear,
          onUpdate: (positions) => position = positions['saya'],
          onComplete: () => completions++,
        )
        .then((_) => finished = true);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(position, closeTo(0.5, 0.0001));
    expect(finished, isFalse);
    expect(animator.isAnimating, isTrue);

    await tester.pump(const Duration(milliseconds: 51));
    expect(position, closeTo(0.8, 0.0001));
    expect(finished, isTrue);
    expect(completions, 1);
    expect(animator.isAnimating, isFalse);
    await future;
    animator.stop();
    expect(completions, 1);
  });

  testWidgets('attribute animation reaches every target and completes once', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    addTearDown(animator.dispose);
    var completions = 0;
    Map<String, double>? attributes;
    var finished = false;
    final future = animator
        .animateAttributeChanges(
          attributeChanges: attributeChanges(),
          vsync: tester,
          duration: const Duration(milliseconds: 100),
          onUpdate: (values) => attributes = values['saya'],
          onComplete: () => completions++,
        )
        .then((_) => finished = true);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 101));
    expect(attributes, {'xcenter': 0.8, 'scale': 1.5});
    expect(finished, isTrue);
    expect(completions, 1);
    expect(animator.isAnimating, isFalse);
    await future;
  });

  testWidgets('stop releases the waiter without callbacks or further updates', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    addTearDown(animator.dispose);
    var completions = 0;
    var updates = 0;
    var finished = false;
    final future = animator
        .animatePositionChanges(
          positionChanges: positionChanges(),
          vsync: tester,
          onUpdate: (_) => updates++,
          onComplete: () => completions++,
        )
        .then((_) => finished = true);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(animator.isAnimating, isTrue);
    animator.stop();
    animator.stop();
    final updatesAtStop = updates;
    await tester.pump();
    expect(finished, isTrue);
    expect(animator.isAnimating, isFalse);
    expect(completions, 0);
    await future;
    await tester.pump(const Duration(seconds: 1));
    expect(updates, updatesAtStop);
  });

  testWidgets('dispose releases an attribute waiter without completing it', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    var completions = 0;
    var finished = false;
    final future = animator
        .animateAttributeChanges(
          attributeChanges: attributeChanges(),
          vsync: tester,
          onComplete: () => completions++,
        )
        .then((_) => finished = true);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    animator.dispose();
    animator.dispose();
    await tester.pump();
    expect(finished, isTrue);
    expect(completions, 0);
    expect(animator.isAnimating, isFalse);
    await future;
  });

  testWidgets('replacement releases the old waiter and keeps the new ticker', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    addTearDown(animator.dispose);
    var oldCompletions = 0;
    var oldUpdates = 0;
    var oldFinished = false;
    final oldFuture = animator
        .animatePositionChanges(
          positionChanges: positionChanges(),
          vsync: tester,
          onUpdate: (_) => oldUpdates++,
          onComplete: () => oldCompletions++,
        )
        .then((_) => oldFinished = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    var newCompletions = 0;
    var newFinished = false;
    Map<String, double>? attributes;
    final oldUpdatesAtReplacement = oldUpdates;
    final newFuture = animator
        .animateAttributeChanges(
          attributeChanges: attributeChanges(),
          vsync: tester,
          duration: const Duration(milliseconds: 200),
          curve: Curves.linear,
          onUpdate: (values) => attributes = values['saya'],
          onComplete: () => newCompletions++,
        )
        .then((_) => newFinished = true);

    await tester.pump();
    expect(oldFinished, isTrue);
    expect(oldCompletions, 0);
    expect(animator.isAnimating, isTrue);
    await oldFuture;
    await tester.pump(const Duration(milliseconds: 100));
    expect(attributes!['xcenter'], closeTo(0.5, 0.0001));
    expect(attributes!['scale'], closeTo(1.25, 0.0001));
    expect(newFinished, isFalse);
    await tester.pump(const Duration(milliseconds: 101));
    expect(newFinished, isTrue);
    expect(newCompletions, 1);
    expect(oldCompletions, 0);
    expect(oldUpdates, oldUpdatesAtReplacement);
    expect(attributes, {'xcenter': 0.8, 'scale': 1.5});
    await newFuture;
  });

  testWidgets('stop before the first frame releases the waiter', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    addTearDown(animator.dispose);
    var completions = 0;
    var finished = false;
    final future = animator
        .animatePositionChanges(
          positionChanges: positionChanges(),
          vsync: tester,
          onComplete: () => completions++,
        )
        .then((_) => finished = true);
    animator.stop();
    await tester.pump();
    expect(finished, isTrue);
    expect(completions, 0);
    expect(animator.isAnimating, isFalse);
    await future;
  });

  testWidgets('zero duration still completes normally and releases resources', (
    tester,
  ) async {
    final animator = CharacterPositionAnimator();
    addTearDown(animator.dispose);
    var completions = 0;
    double? position;
    var finished = false;
    final future = animator
        .animatePositionChanges(
          positionChanges: positionChanges(),
          vsync: tester,
          duration: Duration.zero,
          onUpdate: (positions) => position = positions['saya'],
          onComplete: () => completions++,
        )
        .then((_) => finished = true);
    await tester.pump();
    expect(finished, isTrue);
    expect(position, closeTo(0.8, 0.0001));
    expect(completions, 1);
    expect(animator.isAnimating, isFalse);
    await future;
  });

  for (final useAttributes in [false, true]) {
    testWidgets(
      'empty ${useAttributes ? 'attribute' : 'position'} request cancels its predecessor',
      (tester) async {
        final animator = CharacterPositionAnimator();
        addTearDown(animator.dispose);
        var oldCompletions = 0;
        var oldFinished = false;
        final oldFuture = animator
            .animatePositionChanges(
              positionChanges: positionChanges(),
              vsync: tester,
              onComplete: () => oldCompletions++,
            )
            .then((_) => oldFinished = true);
        await tester.pump();

        var newCompletions = 0;
        if (useAttributes) {
          await animator.animateAttributeChanges(
            attributeChanges: [
              CharacterAttributeChange(
                characterId: 'saya',
                fromAttributes: {'xcenter': 0.5},
                toAttributes: {'xcenter': 0.5},
              ),
            ],
            vsync: tester,
            onComplete: () => newCompletions++,
          );
        } else {
          await animator.animatePositionChanges(
            positionChanges: [],
            vsync: tester,
            onComplete: () => newCompletions++,
          );
        }

        await tester.pump();
        expect(oldFinished, isTrue);
        expect(oldCompletions, 0);
        expect(newCompletions, 1);
        expect(animator.isAnimating, isFalse);
        await oldFuture;
      },
    );
  }
}
