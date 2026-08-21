import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SksParser hide', () {
    test('keeps the existing fade-out behavior by default', () {
      final script = SksParser().parse('hide noe');

      final hide = script.children.single as HideNode;
      expect(hide.character, 'noe');
      expect(hide.immediate, isFalse);
    });

    test('parses the immediate modifier', () {
      final script = SksParser().parse('hide noe immediate');

      final hide = script.children.single as HideNode;
      expect(hide.character, 'noe');
      expect(hide.immediate, isTrue);
    });
  });

  group('GameManager hide', () {
    test('regular hide leaves the character in its fade-out state', () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([HideNode('noe')]),
        initialState: GameState(
          characters: {'noe': CharacterState(resourceId: 'noe')},
        ),
      );

      expect(manager.currentState.characters['noe']?.isFadingOut, isTrue);
    });

    test('immediate hide removes the character synchronously', () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([HideNode('noe', immediate: true)]),
        initialState: GameState(
          characters: {'noe': CharacterState(resourceId: 'noe')},
        ),
      );

      expect(manager.currentState.characters, isEmpty);
    });

    test(
      'the following API observes the character as already hidden',
      () async {
        bool? wasHiddenAtApiCall;
        final manager = GameManager(
          onScriptApiExecute:
              ({
                required String apiName,
                required Map<String, String> params,
                required GameState gameState,
                required int scriptIndex,
              }) async {
                wasHiddenAtApiCall = gameState.characters.isEmpty;
                return ScriptApiExecutionResult.handled();
              },
        );
        addTearDown(manager.dispose);

        await manager.startTestScript(
          ScriptNode([
            HideNode('noe', immediate: true),
            ApiCallNode('test.fullscreen'),
          ]),
          initialState: GameState(
            characters: {'noe': CharacterState(resourceId: 'noe')},
          ),
        );

        expect(wasHiddenAtApiCall, isTrue);
      },
    );
  });
}
