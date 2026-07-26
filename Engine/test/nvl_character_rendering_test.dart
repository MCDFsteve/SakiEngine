import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GameManager createManager() {
    final manager = GameManager();
    manager.characterConfigs['x'] = CharacterConfig(
      id: 'x',
      name: '夏悠',
      resourceId: 'xiayo2',
      defaultPoseId: 'center',
    );
    addTearDown(manager.dispose);
    return manager;
  }

  for (final mode in <String, SksNode>{
    'nvl': NvlNode(),
    'nvln': NvlnNode(),
    'nvlm': NvlMovieNode(),
  }.entries) {
    test('${mode.key} dialogue keeps the speaker but does not show a sprite',
        () async {
      final manager = createManager();

      await manager.startTestScript(
        ScriptNode([
          mode.value,
          SayNode(
            character: 'x',
            dialogue: '这句只应该显示在NVL文本中。',
            pose: 'pose2',
            expression: 'smile',
          ),
        ]),
      );

      expect(manager.currentState.isNvlMode, isTrue);
      expect(manager.currentState.characters, isEmpty);
      expect(manager.currentState.nvlDialogues, hasLength(1));
      expect(manager.currentState.nvlDialogues.single.speaker, '夏悠');
      expect(manager.currentState.nvlDialogues.single.speakerAlias, 'x');
    });
  }

  test('NVL dialogue does not change an explicitly visible sprite', () async {
    final manager = createManager();
    final originalCharacter = CharacterState(
      resourceId: 'xiayo2',
      pose: 'pose1',
      expression: 'normal',
      positionId: 'center',
    );

    await manager.startTestScript(
      ScriptNode([
        NvlMovieNode(),
        SayNode(
          character: 'x',
          dialogue: '署名保留，但不改立绘。',
          pose: 'pose2',
          expression: 'smile',
        ),
      ]),
      initialState: GameState(
        characters: {'xiayo2': originalCharacter},
      ),
    );

    final visibleCharacter = manager.currentState.characters['xiayo2'];
    expect(visibleCharacter, same(originalCharacter));
    expect(visibleCharacter!.pose, 'pose1');
    expect(visibleCharacter.expression, 'normal');
  });

  test('conditional NVL dialogue also does not show a sprite', () async {
    final manager = createManager();

    await manager.startTestScript(
      ScriptNode([
        NvlNode(),
        ConditionalSayNode(
          character: 'x',
          dialogue: '条件台词同样只进入NVL文本。',
          conditionVariable: 'unset_flag',
          conditionValue: false,
          pose: 'pose2',
          expression: 'smile',
        ),
      ]),
    );

    expect(manager.currentState.characters, isEmpty);
    expect(manager.currentState.nvlDialogues.single.speaker, '夏悠');
  });

  test('ADV character dialogue keeps automatic sprite rendering', () async {
    final manager = createManager();

    await manager.startTestScript(
      ScriptNode([
        SayNode(
          character: 'x',
          dialogue: '普通ADV仍然自动显示角色。',
          pose: 'pose2',
          expression: 'smile',
        ),
      ]),
    );

    final visibleCharacter = manager.currentState.characters['xiayo2'];
    expect(visibleCharacter, isNotNull);
    expect(visibleCharacter!.pose, 'pose2');
    expect(visibleCharacter.expression, 'smile');
  });
}
