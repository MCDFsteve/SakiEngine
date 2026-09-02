import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GameManager createManager() {
    final manager = GameManager();
    manager.characterConfigs['aru2'] = CharacterConfig(
      id: 'aru2',
      name: '鸦露露',
      resourceId: 'aru2',
      defaultPoseId: 'pose',
      slotId: 'aru',
    );
    manager.characterConfigs['aru_unknown'] = CharacterConfig(
      id: 'aru_unknown',
      name: '粉色的少女',
      resourceId: 'aru',
      defaultPoseId: 'pose',
      slotId: 'aru',
    );
    addTearDown(manager.dispose);
    return manager;
  }

  GameState aru2SurprisedState() => GameState(
    characters: {
      'slot:aru': CharacterState(
        resourceId: 'aru2',
        pose: 'pose1',
        expression: 'surprised',
        positionId: 'pose',
      ),
    },
  );

  test('resource switch resets an omitted incompatible expression', () async {
    final manager = createManager();

    await manager.startTestScript(
      ScriptNode([
        SayNode(
          character: 'aru_unknown',
          dialogue: '「“美少女游戏”还常被分为“泣系”和“致郁系”对吧？」',
        ),
      ]),
      initialState: aru2SurprisedState(),
    );

    final aru = manager.currentState.characters['slot:aru'];
    expect(aru?.resourceId, 'aru');
    expect(aru?.pose, 'pose1');
    expect(aru?.expression, 'happy');
  });

  test('same resource keeps its current expression when omitted', () async {
    final manager = createManager();

    await manager.startTestScript(
      ScriptNode([SayNode(character: 'aru2', dialogue: '继续说话。')]),
      initialState: aru2SurprisedState(),
    );

    expect(
      manager.currentState.characters['slot:aru']?.expression,
      'surprised',
    );
  });

  test('explicit expression wins when switching resources', () async {
    final manager = createManager();

    await manager.startTestScript(
      ScriptNode([
        SayNode(
          character: 'aru_unknown',
          dialogue: '明确指定表情。',
          expression: 'sad',
        ),
      ]),
      initialState: aru2SurprisedState(),
    );

    expect(manager.currentState.characters['slot:aru']?.expression, 'sad');
  });
}
