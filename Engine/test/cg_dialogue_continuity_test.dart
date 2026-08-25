import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<GameState>> executeCgUpdate({
    required String currentResourceId,
    required String nextResourceId,
  }) async {
    final manager = GameManager();
    final emittedStates = <GameState>[];
    final subscription = manager.gameStateStream.listen(emittedStates.add);
    addTearDown(() async {
      await subscription.cancel();
      manager.dispose();
    });

    await manager.startTestScript(
      ScriptNode([
        CgNode(nextResourceId, pose: 'pose1', expression: 'variant2'),
        SayNode(dialogue: '下一句。'),
      ]),
      initialState: GameState(
        dialogue: '上一句。',
        speaker: '角色',
        cgCharacters: {
          '__global_cg__': CharacterState(
            resourceId: currentResourceId,
            pose: 'pose1',
            expression: 'variant1',
          ),
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);

    return emittedStates;
  }

  test(
    'same CG resource keeps dialogue visible while changing variant',
    () async {
      final states = await executeCgUpdate(
        currentResourceId: 'cg_event',
        nextResourceId: 'cg_event',
      );

      expect(states, hasLength(2));
      expect(states.first.dialogue, '上一句。');
      expect(states.first.speaker, '角色');
      expect(
        states.first.cgCharacters['__global_cg__']?.expression,
        'variant2',
      );
      expect(states.last.dialogue, '下一句。');
    },
  );

  test(
    'different CG resource keeps the existing clear-dialogue behavior',
    () async {
      final states = await executeCgUpdate(
        currentResourceId: 'cg_event_a',
        nextResourceId: 'cg_event_b',
      );

      expect(states, hasLength(2));
      expect(states.first.dialogue, isNull);
      expect(states.first.speaker, isNull);
      expect(
        states.first.cgCharacters['__global_cg__']?.resourceId,
        'cg_event_b',
      );
      expect(states.last.dialogue, '下一句。');
    },
  );
}
