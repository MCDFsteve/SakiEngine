import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main() {
  group('SksParser CG transitions', () {
    test('parses with diss separately from the CG expression', () {
      final script = SksParser().parse('cg cg_cp2_pond 2 with diss');
      final node = script.children.single as CgNode;

      expect(node.character, 'cg_cp2_pond');
      expect(node.expression, '2');
      expect(node.transitionType, 'diss');
    });

    test('keeps transition, position, animation and repeat independent', () {
      final script = SksParser().parse(
        'cg memory pose1 crying at center with dissolve an slow_zoom repeat 2',
      );
      final node = script.children.single as CgNode;

      expect(node.pose, 'pose1');
      expect(node.expression, 'crying');
      expect(node.position, 'center');
      expect(node.transitionType, 'dissolve');
      expect(node.animation, 'slow_zoom');
      expect(node.repeatCount, 2);
    });

    test('keeps CG syntax without a transition backwards compatible', () {
      final script = SksParser().parse('cg cg_cp1_1 naku');
      final node = script.children.single as CgNode;

      expect(node.expression, 'naku');
      expect(node.transitionType, isNull);
    });
  });
}
