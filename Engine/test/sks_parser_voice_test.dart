import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';
import 'package:sakiengine/src/utils/music_manager.dart';
import 'package:sakiengine/src/widgets/floating_script_editor_overlay.dart';

void main() {
  test('parses voice and stop voice commands', () {
    final script = SksParser().parse('''
voice cp0/xiayo_001.ogg
voice "chapter one/line 002.wav"
stop voice
''');

    expect(script.children, hasLength(3));
    expect(script.children[0], isA<VoiceNode>());
    expect((script.children[0] as VoiceNode).voiceFile, 'cp0/xiayo_001.ogg');
    expect(
      (script.children[1] as VoiceNode).voiceFile,
      '"chapter one/line 002.wav"',
    );
    expect(script.children[2], isA<StopVoiceNode>());
  });

  test('extracts editor voice previews and resolves asset paths', () {
    expect(
      extractVoiceFileFromScriptLine('  voice cp0/xiayo_001.m4a'),
      'cp0/xiayo_001.m4a',
    );
    expect(
      extractVoiceFileFromScriptLine(
        'voice "chapter one/line 002.m4a" // preview',
      ),
      '"chapter one/line 002.m4a"',
    );
    expect(extractVoiceFileFromScriptLine('// voice ignored.m4a'), isNull);
    expect(extractVoiceFileFromScriptLine('voiceover ignored.m4a'), isNull);

    expect(
      MusicManager.buildVoiceAssetPath('cp0/xiayo_001.m4a'),
      'Assets/voice/cp0/xiayo_001.m4a',
    );
    expect(
      MusicManager.buildVoiceAssetPath('"chapter one/line 002.m4a"'),
      'Assets/voice/chapter one/line 002.m4a',
    );
    expect(
      MusicManager.buildVoiceAssetPath('Assets/voice/cp1/xiayo_001.m4a'),
      'Assets/voice/cp1/xiayo_001.m4a',
    );
  });
}
