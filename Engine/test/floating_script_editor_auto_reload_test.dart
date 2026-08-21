import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/widgets/floating_script_editor_overlay.dart';

void main() {
  test('floating script editor reloads once after saving', () async {
    var reloadCount = 0;

    await reloadFloatingScriptEditorAfterSave(() async {
      reloadCount += 1;
    });

    expect(reloadCount, 1);
  });

  test(
    'floating script editor allows saving without a reload callback',
    () async {
      await expectLater(reloadFloatingScriptEditorAfterSave(null), completes);
    },
  );
}
