import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'voice commands advance to dialogue without runtime side effects',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([
          VoiceNode('cp0/xiayo_001.ogg'),
          SayNode(character: 'x', dialogue: '早上好。'),
          StopVoiceNode(),
          SayNode(dialogue: '下一句。'),
        ]),
      );

      expect(manager.currentDialogueText, '早上好。');
      expect(manager.currentScriptIndex, 2);

      manager.next();
      await Future<void>.delayed(Duration.zero);

      expect(manager.currentDialogueText, '下一句。');
      expect(manager.currentScriptIndex, 4);
    },
  );
}
