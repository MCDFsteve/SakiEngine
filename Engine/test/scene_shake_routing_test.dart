import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/dialogue_shake_effect.dart';

void main() {
  test('background shake routes to the visible CG layer when CG is active', () {
    expect(
      resolveSceneShakeLayer(
        isShaking: true,
        target: 'background',
        hasCg: true,
      ),
      SceneShakeLayer.cg,
    );
    expect(
      resolveSceneShakeLayer(isShaking: true, target: null, hasCg: true),
      SceneShakeLayer.cg,
    );
  });

  test('background shake stays on the ordinary scene when there is no CG', () {
    expect(
      resolveSceneShakeLayer(
        isShaking: true,
        target: 'background',
        hasCg: false,
      ),
      SceneShakeLayer.scene,
    );
    expect(
      resolveSceneShakeLayer(isShaking: true, target: 'dialogue', hasCg: false),
      SceneShakeLayer.none,
    );
  });

  test(
    'shake start and completion both preserve the active CG state',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      final cgState = CharacterState(
        resourceId: 'cg_test',
        pose: 'pose1',
        expression: 'normal',
      );

      await manager.startTestScript(
        ScriptNode([ShakeNode(duration: 0.01), SayNode(dialogue: '震动中的台词。')]),
        initialState: GameState(cgCharacters: {'__global_cg__': cgState}),
      );

      expect(manager.currentState.isShaking, isTrue);
      expect(manager.currentState.cgCharacters['__global_cg__'], same(cgState));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(manager.currentState.isShaking, isFalse);
      expect(manager.currentState.cgCharacters['__global_cg__'], same(cgState));
    },
  );

  testWidgets(
    'shake starts when the wrapper is first built already triggered',
    (tester) async {
      const cgKey = ValueKey('stable-cg');
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox.expand(
            child: SimpleShakeWrapper(
              trigger: true,
              intensity: 8,
              duration: Duration(seconds: 1),
              child: ColoredBox(key: cgKey, color: Colors.white),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(cgKey), findsOneWidget);
      final transform = tester.widget<Transform>(
        find.descendant(
          of: find.byType(SimpleShakeWrapper),
          matching: find.byType(Transform),
        ),
      );
      expect(transform.transform.getTranslation().y, isNot(closeTo(0, 0.001)));
    },
  );
}
