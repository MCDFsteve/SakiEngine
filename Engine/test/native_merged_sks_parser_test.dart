import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main() {
  test('native merged source preserves file boundaries and source lines', () {
    final script = SksParser().parse('''
__saki_source "start"
label start
"first line"
__saki_source_end "start"
__saki_source "chapter"
label chapter
hero "second line"
__saki_source_end "chapter"
''');

    expect((script.children[0] as CommentNode).comment, '=== 文件: start ===');
    final first = script.children.whereType<SayNode>().first;
    final second = script.children.whereType<SayNode>().last;
    expect(first.sourceFile, 'start');
    expect(first.sourceLine, 2);
    expect(second.sourceFile, 'chapter');
    expect(second.sourceLine, 2);
  });
}
