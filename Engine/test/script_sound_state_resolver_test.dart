import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/game/script_sound_state_resolver.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('history before play sound has no active loop to restore', () {
    final script = ScriptNode([
      SayNode(dialogue: 'before'),
      PlaySoundNode('rain', loop: true),
      SayNode(dialogue: 'after'),
    ]);

    expect(
      ScriptSoundStateResolver.resolveLoopingSoundFiles(script, 1),
      isEmpty,
    );
    expect(ScriptSoundStateResolver.resolveLoopingSoundFiles(script, 2), [
      'rain',
    ]);
  });

  test('one-shot sounds are never replayed while restoring history', () {
    final script = ScriptNode([
      PlaySoundNode('door'),
      SayNode(dialogue: 'after door'),
    ]);

    expect(
      ScriptSoundStateResolver.resolveLoopingSoundFiles(script, 2),
      isEmpty,
    );
  });

  test('stop sound clears all earlier looped ambience', () {
    final script = ScriptNode([
      PlaySoundNode('rain', loop: true),
      PlaySoundNode('fire', loop: true),
      SayNode(dialogue: 'both active'),
      StopSoundNode(),
      SayNode(dialogue: 'silent'),
    ]);

    expect(ScriptSoundStateResolver.resolveLoopingSoundFiles(script, 3), [
      'rain',
      'fire',
    ]);
    expect(
      ScriptSoundStateResolver.resolveLoopingSoundFiles(script, 4),
      isEmpty,
    );
  });

  test(
    'runtime history captures exact loop state around a play boundary',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'before'),
          PlaySoundNode('rain', loop: true),
          PlaySoundNode('door'),
          SayNode(dialogue: 'after'),
          StopSoundNode(),
          SayNode(dialogue: 'silent'),
        ]),
      );

      expect(manager.activeLoopingSoundsForTesting, isEmpty);

      manager.next();
      await Future<void>.delayed(Duration.zero);
      expect(manager.activeLoopingSoundsForTesting, {'Assets/sound/rain.mp3'});
      expect(
        manager.getDialogueHistory().last.stateSnapshot.activeLoopingSounds,
        [
          'Assets/sound/rain.mp3',
        ],
      );

      final history = manager.getDialogueHistory();
      await manager.restoreSoundStateForHistoryEntryForTesting(history.first);
      expect(manager.activeLoopingSoundsForTesting, isEmpty);

      await manager.restoreSoundStateForHistoryEntryForTesting(history.last);
      expect(manager.activeLoopingSoundsForTesting, {
        'Assets/sound/rain.mp3',
      });

      manager.next();
      await Future<void>.delayed(Duration.zero);
      expect(manager.activeLoopingSoundsForTesting, isEmpty);
      expect(
        manager.getDialogueHistory().last.stateSnapshot.activeLoopingSounds,
        isEmpty,
      );
    },
  );

  test('save binary keeps active looping sound state', () {
    final save = SaveSlot(
      id: 1,
      saveTime: DateTime.fromMillisecondsSinceEpoch(1234),
      currentScript: 'test',
      dialoguePreview: '',
      snapshot: GameStateSnapshot(
        scriptIndex: 3,
        currentState: GameState.initial(),
        activeLoopingSounds: const [
          'Assets/sound/rain.mp3',
          'Assets/sound/fire.mp3',
        ],
      ),
    );

    final restored = SaveSlot.fromBinary(save.toBinary());

    expect(restored.snapshot.activeLoopingSounds, [
      'Assets/sound/rain.mp3',
      'Assets/sound/fire.mp3',
    ]);
  });
}
