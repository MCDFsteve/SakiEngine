import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/effects/scene_filter.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sameBackground in [false, true]) {
    for (final withFilter in [false, true]) {
      testWidgets('${sameBackground ? 'same' : 'initial'} scene timer '
          '${withFilter ? 'with fx' : 'without fx'} holds then resumes once', (
        tester,
      ) async {
        final manager = GameManager();
        addTearDown(manager.dispose);
        final nextIndex = withFilter ? 2 : 1;
        await manager.startTestScript(
          ScriptNode([
            BackgroundNode('sky', timer: 0.1),
            if (withFilter) FxNode('nostalgic'),
            SayNode(dialogue: 'after scene'),
            SayNode(dialogue: 'next line'),
          ]),
          initialState: sameBackground
              ? GameState.initial().copyWith(background: 'sky')
              : null,
        );

        expect(manager.currentState.background, 'sky');
        expect(manager.currentScriptIndex, nextIndex);
        expect(manager.currentState.dialogue, isNull);
        if (withFilter) {
          expect(manager.currentState.sceneFilter?.type, FilterType.nostalgic);
        }

        await tester.pump(const Duration(milliseconds: 40));
        for (var i = 0; i < 10; i++) {
          manager.next();
        }
        await tester.pump();
        expect(manager.currentScriptIndex, nextIndex);
        expect(manager.currentState.dialogue, isNull);

        // Repeated clicks must neither bypass nor restart the original timer.
        await tester.pump(const Duration(milliseconds: 60));
        expect(manager.currentState.dialogue, 'after scene');
        expect(manager.currentScriptIndex, nextIndex + 1);
        await tester.pump(const Duration(seconds: 1));
        expect(manager.currentState.dialogue, 'after scene');
        expect(manager.getDialogueHistory().map((entry) => entry.dialogue), [
          'after scene',
        ]);

        manager.next();
        await tester.pump();
        expect(manager.currentState.dialogue, 'next line');
      });
    }
  }

  testWidgets('anime timer ignores repeated clicks and resumes once', (
    tester,
  ) async {
    final manager = GameManager();
    addTearDown(manager.dispose);
    await manager.startTestScript(
      ScriptNode([
        AnimeNode('intro', timer: 0.1),
        SayNode(dialogue: 'after anime'),
        SayNode(dialogue: 'next line'),
      ]),
    );
    expect(manager.currentState.animeOverlay, 'intro');
    expect(manager.currentScriptIndex, 1);

    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 0; i < 10; i++) {
      manager.next();
    }
    await tester.pump();
    expect(manager.currentState.animeOverlay, 'intro');
    expect(manager.currentState.dialogue, isNull);
    expect(manager.currentScriptIndex, 1);

    await tester.pump(const Duration(milliseconds: 60));
    expect(manager.currentState.dialogue, 'after anime');
    expect(manager.currentScriptIndex, 2);
    await tester.pump(const Duration(seconds: 1));
    expect(manager.currentState.dialogue, 'after anime');
    expect(manager.getDialogueHistory().map((entry) => entry.dialogue), [
      'after anime',
    ]);

    manager.next();
    await tester.pump();
    expect(manager.currentState.animeOverlay, isNull);
    expect(manager.currentState.dialogue, 'next line');
  });

  for (final isAnime in [false, true]) {
    SksNode timedNode() => isAnime
        ? AnimeNode('intro', timer: 30)
        : BackgroundNode('sky', timer: 30);
    final nodeName = isAnime ? 'anime' : 'scene';

    testWidgets('fast-forward completes active $nodeName timer once', (
      tester,
    ) async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          timedNode(),
          SayNode(dialogue: 'after timer'),
          SayNode(dialogue: 'next line'),
        ]),
      );
      manager.setFastForwardMode(true);
      await tester.pump();
      expect(manager.currentState.dialogue, 'after timer');
      expect(manager.currentScriptIndex, 2);
      manager.setFastForwardMode(false);
      await tester.pump(const Duration(seconds: 31));
      expect(manager.currentState.dialogue, 'after timer');
      expect(manager.getDialogueHistory(), hasLength(1));
    });

    testWidgets('fast-forward skips $nodeName timer before it starts', (
      tester,
    ) async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'before timer'),
          timedNode(),
          SayNode(dialogue: 'after timer'),
          SayNode(dialogue: 'next line'),
        ]),
      );
      manager.setFastForwardMode(true);
      manager.next();
      await tester.pump();
      expect(manager.currentState.dialogue, 'after timer');
      expect(manager.currentScriptIndex, 3);
      manager.setFastForwardMode(false);
      await tester.pump(const Duration(seconds: 31));
      expect(manager.currentState.dialogue, 'after timer');
      expect(manager.getDialogueHistory(), hasLength(2));
    });

    testWidgets('replacing script cancels pending $nodeName timer', (
      tester,
    ) async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([timedNode(), SayNode(dialogue: 'old dialogue')]),
      );
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'new dialogue'),
          SayNode(dialogue: 'must still await click'),
        ]),
      );
      await tester.pump(const Duration(seconds: 31));
      expect(manager.currentState.dialogue, 'new dialogue');
      expect(manager.currentScriptIndex, 1);
      expect(manager.getDialogueHistory(), hasLength(1));
    });
  }
}
