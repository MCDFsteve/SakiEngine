import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/async_initialization_gate.dart';

void main() {
  test('concurrent callers wait for the same initialization', () async {
    final gate = AsyncInitializationGate<bool>();
    final completer = Completer<bool>();
    var initializationCount = 0;

    Future<bool> initialize() {
      initializationCount += 1;
      return completer.future;
    }

    final first = gate.run(initialize);
    final second = gate.run(initialize);
    final third = gate.run(initialize);

    expect(initializationCount, 1);

    completer.complete(true);

    expect(await Future.wait([first, second, third]), [true, true, true]);
    expect(await gate.run(initialize), isTrue);
    expect(initializationCount, 1);
  });
}
