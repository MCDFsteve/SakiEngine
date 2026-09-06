import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('async script execution stops when its manager is disposed', () async {
    final apiStarted = Completer<void>();
    final releaseApi = Completer<void>();
    final manager = GameManager(
      onScriptApiExecute:
          ({
            required apiName,
            required params,
            required gameState,
            required scriptIndex,
          }) async {
            apiStarted.complete();
            await releaseApi.future;
            return ScriptApiExecutionResult.handled();
          },
    );

    final execution = manager.startTestScript(
      ScriptNode([
        ApiCallNode('test.wait'),
        NvlMovieNode(),
        SayNode(dialogue: '不应在销毁后显示。'),
      ]),
    );

    await apiStarted.future;
    manager.dispose();
    releaseApi.complete();

    await expectLater(execution, completes);
    expect(manager.currentScriptIndex, 1);
  });
}
