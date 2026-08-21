import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/expression_selector_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('speaker alias disambiguates characters with the same display name', () {
    final manager = GameManager();
    addTearDown(manager.dispose);
    manager.characterConfigs.addAll({
      'noe': CharacterConfig(
        id: 'noe',
        name: '弥黑埜爱',
        resourceId: 'noe',
        slotId: 'noe',
      ),
      'noe2': CharacterConfig(
        id: 'noe2',
        name: '弥黑埜爱',
        resourceId: 'noe2',
        slotId: 'noe',
      ),
    });
    final state = GameState(
      speaker: '弥黑埜爱',
      speakerAlias: 'noe2',
      characters: {
        'slot:noe': CharacterState(
          resourceId: 'noe2',
          pose: 'pose1',
          expression: 'normal',
        ),
      },
    );
    final selector = ExpressionSelectorManager(
      gameManager: manager,
      showNotificationCallback: (_) {},
      triggerReloadCallback: () {},
      setExpressionSelectorVisibility: (_) {},
      getCurrentGameState: () => state,
    );

    final speaker = selector.getCurrentSpeakerInfo();

    expect(speaker, isNotNull);
    expect(speaker!.scriptCharacterKey, 'noe2');
    expect(speaker.characterId, 'noe2');
  });
}
