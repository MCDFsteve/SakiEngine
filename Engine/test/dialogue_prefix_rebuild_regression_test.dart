import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';

void main() {
  const dialogue = '的确是音无彩名，如你明察哦！';

  Future<String> _rewriteSingleLine({
    required String line,
    required String characterId,
    String? newPose,
    String? newExpression,
    bool updateAnimation = false,
    String? newAnimation,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp(
      'dialogue_prefix_rebuild_regression_test_',
    );
    try {
      final scriptFile = File('${tempDir.path}/story_01_part_02.sks');
      await scriptFile.writeAsString('$line\n');

      final ok = await ScriptContentModifier.modifyDialogueLineWithPose(
        scriptFilePath: scriptFile.path,
        targetDialogue: dialogue,
        characterId: characterId,
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
    'corrupted duplicated character prefix should be normalized in one rewrite',
    () async {
      final updated = await _rewriteSingleLine(
        line:
            'aru3 afraid2aru3 pose1 gloomy aru3 pose1 sideeye aru3 pose1 sad "$dialogue"',
        characterId: 'aru3',
        newPose: 'pose1',
        newExpression: 'angry',
      );

      expect(updated, 'aru3 pose1 angry "$dialogue"');
    },
  );

  test(
    'normal character line still keeps tail controls like an/repeat',
    () async {
      final updated = await _rewriteSingleLine(
        line: 'aru3 pose1 sad an jump repeat 2 "$dialogue"',
        characterId: 'aru3',
        newPose: null,
        newExpression: 'happy',
      );

      expect(updated, 'aru3 pose1 happy an jump repeat 2 "$dialogue"');
    },
  );

  test('selector can replace a character animation', () async {
    final updated = await _rewriteSingleLine(
      line: 'aru3 pose1 sad an jump repeat 2 "$dialogue"',
      characterId: 'aru3',
      newPose: 'pose1',
      newExpression: 'happy',
      updateAnimation: true,
      newAnimation: 'shake',
    );

    expect(updated, 'aru3 pose1 happy an shake repeat 2 "$dialogue"');
  });

  test('selector can add an animation to a character line', () async {
    final updated = await _rewriteSingleLine(
      line: 'aru3 pose1 sad "$dialogue"',
      characterId: 'aru3',
      newPose: 'pose1',
      newExpression: 'happy',
      updateAnimation: true,
      newAnimation: 'jump',
    );

    expect(updated, 'aru3 pose1 happy an jump "$dialogue"');
  });

  test('selector can clear an and its repeat count', () async {
    final updated = await _rewriteSingleLine(
      line: 'aru3 pose1 sad an jump repeat 2 "$dialogue"',
      characterId: 'aru3',
      newPose: 'pose1',
      newExpression: 'happy',
      updateAnimation: true,
    );

    expect(updated, 'aru3 pose1 happy "$dialogue"');
  });
}
