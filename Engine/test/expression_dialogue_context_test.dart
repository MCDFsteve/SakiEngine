import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'dialogue context skips directing nodes around the current line',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: '上一句。'),
          ShowNode('noe'),
          ApiCallNode('test.directing'),
          SayNode(character: 'noe', dialogue: '当前句。'),
          CommentNode('只是一条演出注释'),
          HideNode('noe', immediate: true),
          SayNode(dialogue: '下一句。'),
        ]),
        scriptIndex: 3,
      );

      final context = manager.currentDialogueContext;
      expect(context, isNotNull);
      expect(context!.previousDialogue, '上一句。');
      expect(context.currentDialogue, '当前句。');
      expect(context.nextDialogue, '下一句。');
    },
  );

  test('dialogue context exposes an empty side at script boundaries', () async {
    final manager = GameManager();
    addTearDown(manager.dispose);

    await manager.startTestScript(
      ScriptNode([SayNode(dialogue: '第一句。'), SayNode(dialogue: '第二句。')]),
    );

    final firstContext = manager.currentDialogueContext;
    expect(firstContext?.previousDialogue, isNull);
    expect(firstContext?.currentDialogue, '第一句。');
    expect(firstContext?.nextDialogue, '第二句。');

    manager.next();
    await Future<void>.delayed(Duration.zero);

    final lastContext = manager.currentDialogueContext;
    expect(lastContext?.previousDialogue, '第一句。');
    expect(lastContext?.currentDialogue, '第二句。');
    expect(lastContext?.nextDialogue, isNull);
  });

  test(
    'dialogue context does not cross merged script file boundaries',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: '同文件上一句。', sourceFile: 'chapter_a'),
          SayNode(dialogue: '当前句。', sourceFile: 'chapter_a'),
          SayNode(dialogue: '另一文件第一句。', sourceFile: 'chapter_b'),
          SayNode(dialogue: '不应越界找到。', sourceFile: 'chapter_a'),
        ]),
        scriptIndex: 1,
      );

      final context = manager.currentDialogueContext;
      expect(context?.previousDialogue, '同文件上一句。');
      expect(context?.currentDialogue, '当前句。');
      expect(context?.nextDialogue, isNull);
    },
  );
}
