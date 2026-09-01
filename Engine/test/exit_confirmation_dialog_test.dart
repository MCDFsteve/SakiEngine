import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/widgets/common/exit_confirmation_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowManagerChannel = MethodChannel('window_manager');

  test('application exit destroys the process-level window session', () async {
    final methodCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, (call) async {
          methodCalls.add(call.method);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, null);
    });

    await ExitConfirmationDialog.closeApplication();

    expect(
      methodCalls,
      containsAllInOrder(['setPreventClose', 'hide', 'destroy']),
    );
    expect(methodCalls, isNot(contains('close')));
  });
}
