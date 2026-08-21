import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GameManager createManager({ScriptApiExecutor? apiExecutor}) {
    final manager = GameManager(onScriptApiExecute: apiExecutor);
    manager.characterConfigs['noe'] = CharacterConfig(
      id: 'noe',
      name: '弥黑埜爱',
      resourceId: 'noe',
      defaultPoseId: 'pose',
      slotId: 'noe',
    );
    addTearDown(manager.dispose);
    return manager;
  }

  GameState noeVisibleState() => GameState(
    characters: {
      'slot:noe': CharacterState(
        resourceId: 'noe',
        pose: 'pose1',
        expression: 'normal',
        positionId: 'pose',
      ),
    },
  );

  test(
    'dialogue revives a character whose hide fade is still pending',
    () async {
      final manager = createManager();

      await manager.startTestScript(
        ScriptNode([
          HideNode('noe'),
          SayNode(character: 'noe', dialogue: '这是黑服哦。'),
        ]),
        initialState: noeVisibleState(),
      );

      final revived = manager.currentState.characters['slot:noe'];
      expect(revived, isNotNull);
      expect(revived!.isFadingOut, isFalse);

      // Simulate the completion callback queued by the old hide animation.
      manager.removeCharacterAfterFadeOut('slot:noe');
      expect(manager.currentState.characters['slot:noe'], isNotNull);
    },
  );

  test(
    'API wait completion does not resurrect a character removed mid-wait',
    () async {
      late final GameManager manager;
      manager = createManager(
        apiExecutor:
            ({
              required String apiName,
              required Map<String, String> params,
              required GameState gameState,
              required int scriptIndex,
            }) async {
              final overlayState = gameState.copyWith(
                scriptOverlayText: '',
                scriptOverlayBackgroundColor: '#000000',
                scriptOverlayRevision: gameState.scriptOverlayRevision + 1,
                clearDialogueAndSpeaker: true,
              );
              return ScriptApiExecutionResult.handled(
                nextState: overlayState,
                waitDuration: const Duration(milliseconds: 10),
                stateAfterWait: overlayState.copyWith(
                  clearScriptOverlay: true,
                  scriptOverlayRevision: overlayState.scriptOverlayRevision + 1,
                ),
              );
            },
      );

      await manager.startTestScript(
        ScriptNode([
          HideNode('noe'),
          ApiCallNode('menhera.fullscreen_text'),
          SayNode(dialogue: '于是我们跟着服务员一起走到结账的地方。'),
          SayNode(character: 'noe', dialogue: '这是黑服哦。'),
        ]),
        initialState: noeVisibleState(),
      );

      expect(manager.currentState.characters['slot:noe']?.isFadingOut, isTrue);

      // The renderer finishes the 220 ms hide before the API's wait snapshot is
      // applied. The snapshot must not put the fading character back.
      manager.removeCharacterAfterFadeOut('slot:noe');
      expect(manager.currentState.characters, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(manager.currentState.dialogue, '于是我们跟着服务员一起走到结账的地方。');
      expect(manager.currentState.characters, isEmpty);

      manager.next();
      await Future<void>.delayed(Duration.zero);

      final revived = manager.currentState.characters['slot:noe'];
      expect(manager.currentState.dialogue, '这是黑服哦。');
      expect(revived, isNotNull);
      expect(revived!.isFadingOut, isFalse);
    },
  );
}
