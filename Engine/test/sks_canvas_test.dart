import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('canvas syntax', () {
    test('parses show-like canvas and hide canvas commands', () {
      final script = SksParser().parse('''
canvas pixel_rain
hide canvas
''');

      expect(script.children, hasLength(2));
      expect((script.children.first as CanvasNode).canvasId, 'pixel_rain');
      expect(script.children.last, isA<HideCanvasNode>());
    });

    test('runtime keeps a canvas active while dialogue continues', () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([
          CanvasNode('pixel_rain'),
          SayNode(dialogue: 'Rain keeps falling.'),
        ]),
      );

      expect(manager.currentState.scriptCanvasId, 'pixel_rain');
      expect(manager.currentState.scriptCanvasDurationSeconds, 0);
      expect(manager.currentState.dialogue, 'Rain keeps falling.');
    });

    test('hide canvas clears the active canvas before dialogue', () async {
      final manager = GameManager();
      addTearDown(manager.dispose);

      await manager.startTestScript(
        ScriptNode([HideCanvasNode(), SayNode(dialogue: 'The rain stopped.')]),
        initialState: GameState(scriptCanvasId: 'pixel_rain'),
      );

      expect(manager.currentState.scriptCanvasId, isNull);
      expect(manager.currentState.dialogue, 'The rain stopped.');
    });
  });

  test(
    'debug placement inserts and replaces an adjacent canvas command',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'saki_canvas_rewrite_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/scene.sks');
      await script.writeAsString('label start\n"Line"\n');

      final inserted = await ScriptContentModifier.modifyCanvasNearDialogue(
        scriptFilePath: script.path,
        canvasId: 'pixel_rain',
        targetLineNumber: 2,
      );
      expect(inserted, isTrue);
      expect(
        await script.readAsString(),
        'label start\ncanvas pixel_rain\n"Line"\n',
      );

      final replaced = await ScriptContentModifier.modifyCanvasNearDialogue(
        scriptFilePath: script.path,
        canvasId: 'snow',
        targetLineNumber: 3,
      );
      expect(replaced, isTrue);
      expect(await script.readAsString(), 'label start\ncanvas snow\n"Line"\n');
    },
  );

  test('save binary preserves a persistent canvas', () {
    final save = SaveSlot(
      id: 1,
      saveTime: DateTime.fromMillisecondsSinceEpoch(1234),
      currentScript: 'test',
      dialoguePreview: '',
      snapshot: GameStateSnapshot(
        scriptIndex: 2,
        currentState: GameState(
          scriptCanvasId: 'pixel_rain',
          scriptCanvasRevision: 7,
        ),
      ),
    );

    final restored = SaveSlot.fromBinary(save.toBinary());
    expect(restored.snapshot.currentState.scriptCanvasId, 'pixel_rain');
    expect(restored.snapshot.currentState.scriptCanvasRevision, 7);
  });
}
