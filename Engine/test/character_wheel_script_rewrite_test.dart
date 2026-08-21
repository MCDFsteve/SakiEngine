import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';

void main() {
  const dialogue = '切换角色后继续补上差分。';

  test('character wheel keeps a space before dialogue content', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'character_wheel_script_rewrite_test_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final scriptFile = File('${tempDir.path}/story.sks');
    await scriptFile.writeAsString('me "$dialogue"\n');

    final changed = await ScriptContentModifier.modifyDialogueCharacterWithPose(
      scriptFilePath: scriptFile.path,
      targetDialogue: dialogue,
      oldCharacterId: 'me',
      newCharacterId: 'noe',
      targetLineNumber: 1,
    );

    expect(changed, isTrue);
    final updated = (await scriptFile.readAsString()).trim();
    expect(updated, 'noe "$dialogue"');
    final say = SksParser().parse(updated).children.single as SayNode;
    expect(say.character, 'noe');
    expect(say.dialogue, contains(dialogue));
  });

  test(
    'expression rewrite still works after a character wheel change',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'character_then_expression_rewrite_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final scriptFile = File('${tempDir.path}/story.sks');
      await scriptFile.writeAsString('me "$dialogue"\n');

      final characterChanged =
          await ScriptContentModifier.modifyDialogueCharacterWithPose(
            scriptFilePath: scriptFile.path,
            targetDialogue: dialogue,
            oldCharacterId: 'me',
            newCharacterId: 'noe',
            targetLineNumber: 1,
          );
      final expressionChanged =
          await ScriptContentModifier.modifyDialogueLineWithPose(
            scriptFilePath: scriptFile.path,
            targetDialogue: dialogue,
            characterId: 'noe',
            newPose: 'pose1',
            newExpression: 'happy',
            targetLineNumber: 1,
          );

      expect(characterChanged, isTrue);
      expect(expressionChanged, isTrue);
      expect(
        (await scriptFile.readAsString()).trim(),
        'noe pose1 happy "$dialogue"',
      );
    },
  );

  test(
    'expression rewrite accepts the wheel write id when the old alias is stale',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'character_wheel_stale_alias_rewrite_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final scriptFile = File('${tempDir.path}/story.sks');
      await scriptFile.writeAsString('noe "$dialogue"\n');

      final characterChanged =
          await ScriptContentModifier.modifyDialogueCharacterWithPose(
            scriptFilePath: scriptFile.path,
            targetDialogue: dialogue,
            oldCharacterId: 'noe',
            newCharacterId: 'noe2',
            targetLineNumber: 1,
          );
      final expressionChanged =
          await ScriptContentModifier.modifyDialogueLineWithPose(
            scriptFilePath: scriptFile.path,
            targetDialogue: dialogue,
            characterId: 'noe',
            writeCharacterId: 'noe2',
            newPose: 'pose1',
            newExpression: 'happy',
            targetLineNumber: 1,
          );

      expect(characterChanged, isTrue);
      expect(expressionChanged, isTrue);
      expect(
        (await scriptFile.readAsString()).trim(),
        'noe2 pose1 happy "$dialogue"',
      );
    },
  );

  test(
    'character wheel preserves existing pose and expression tokens',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'character_wheel_prefix_tokens_test_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final scriptFile = File('${tempDir.path}/story.sks');
      await scriptFile.writeAsString('me pose3 angry "$dialogue"\n');

      final changed =
          await ScriptContentModifier.modifyDialogueCharacterWithPose(
            scriptFilePath: scriptFile.path,
            targetDialogue: dialogue,
            oldCharacterId: 'me',
            newCharacterId: 'noe',
            targetLineNumber: 1,
          );

      expect(changed, isTrue);
      expect(
        (await scriptFile.readAsString()).trim(),
        'noe pose3 angry "$dialogue"',
      );
    },
  );
}
