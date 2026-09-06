import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main() {
  test('dialogue punctuation is preserved exactly as authored', () {
    final script = SksParser().parse('''
x "「原稿有括号。」"
x "原稿没有括号。"
x "（内心话保持原样。）"
"旁白保持原样。"
''');

    final dialogues = script.children
        .whereType<SayNode>()
        .map((node) => node.dialogue)
        .toList();

    expect(dialogues, <String>['「原稿有括号。」', '原稿没有括号。', '（内心话保持原样。）', '旁白保持原样。']);
  });
}
