import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main() {
  group('SksParser conditional jump', () {
    test('parses true and false conditions', () {
      final script = SksParser().parse('''
jump route_a if route_selected true
jump route_b if route_selected false
''');

      final first = script.children[0] as JumpNode;
      final second = script.children[1] as JumpNode;

      expect(first.targetLabel, 'route_a');
      expect(first.conditionVariable, 'route_selected');
      expect(first.conditionValue, isTrue);
      expect(first.isConditional, isTrue);

      expect(second.targetLabel, 'route_b');
      expect(second.conditionVariable, 'route_selected');
      expect(second.conditionValue, isFalse);
      expect(second.isConditional, isTrue);
    });

    test('keeps unconditional jump backwards compatible', () {
      final script = SksParser().parse('jump next_scene');
      final node = script.children.single as JumpNode;

      expect(node.targetLabel, 'next_scene');
      expect(node.isConditional, isFalse);
    });

    test('rejects non-boolean condition values', () {
      expect(
        () => SksParser().parse('jump route if selected maybe'),
        throwsFormatException,
      );
    });
  });
}
