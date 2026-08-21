import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';

void main() {
  const dialogue = '她下了一阶阶梯。';

  Future<String> _rewriteSingleLine({
    required String line,
    String? newPose,
    String? newExpression,
    bool updateAnimation = false,
    String? newAnimation,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'script_content_modifier_test_',
    );
    try {
      final scriptFile = File('${tempDir.path}/story_01.sks');
      await scriptFile.writeAsString('$line\n');

      final ok = await ScriptContentModifier.modifyDialogueLineWithPose(
        scriptFilePath: scriptFile.path,
        targetDialogue: dialogue,
        characterId: 'aru2',
        newPose: newPose,
        newExpression: newExpression,
        updateAnimation: updateAnimation,
        newAnimation: newAnimation,
        targetLineNumber: 1,
      );

      expect(ok, isTrue);
      return (await scriptFile.readAsString()).trim();
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  test(
    'narration tail updates in place instead of appending duplicate alias blocks',
    () async {
      final updated = await _rewriteSingleLine(
        line: '"$dialogue" fuzu aru2 normal an jump',
        newPose: 'pose1',
        newExpression: 'smile',
      );

      expect(updated, '"$dialogue" fuzu aru2 pose1 smile an jump');
      expect(RegExp(r'\baru2\b').allMatches(updated).length, 1);
    },
  );

  test(
    'narration line with only dialogueTag gains a single alias pose expression',
    () async {
      final updated = await _rewriteSingleLine(
        line: '"$dialogue" fuzu',
        newPose: 'pose1',
        newExpression: 'smile',
      );

      expect(updated, '"$dialogue" fuzu aru2 pose1 smile');
    },
  );

  test(
    'narration tail keeps an/repeat when updating expression only',
    () async {
      final updated = await _rewriteSingleLine(
        line: '"$dialogue" fuzu aru2 pose1 normal an jump repeat 2',
        newPose: null,
        newExpression: 'smile',
      );

      expect(updated, '"$dialogue" fuzu aru2 pose1 smile an jump repeat 2');
    },
  );

  test('narration tail animation can be replaced by selector', () async {
    final updated = await _rewriteSingleLine(
      line: '"$dialogue" fuzu aru2 pose1 normal an jump repeat 2',
      newPose: 'pose1',
      newExpression: 'smile',
      updateAnimation: true,
      newAnimation: 'fururu',
    );

    expect(updated, '"$dialogue" fuzu aru2 pose1 smile an fururu repeat 2');
  });

  test(
    'narration tail animation and repeat can be cleared by selector',
    () async {
      final updated = await _rewriteSingleLine(
        line: '"$dialogue" fuzu aru2 pose1 normal an jump repeat 2',
        newPose: 'pose1',
        newExpression: 'smile',
        updateAnimation: true,
      );

      expect(updated, '"$dialogue" fuzu aru2 pose1 smile');
    },
  );
}
