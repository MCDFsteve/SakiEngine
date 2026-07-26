import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main() {
  group('SksParser anime overlay', () {
    test('parses a persistent looping overlay and its explicit stop', () {
      final script = SksParser().parse('''
anime smoke loop keep
stop anime
''');

      final play = script.children[0] as AnimeNode;
      expect(play.animeName, 'smoke');
      expect(play.loop, isTrue);
      expect(play.keep, isTrue);
      expect(script.children[1], isA<StopAnimeNode>());
    });
  });
}
