import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/saki_audio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Erika stop is skipped until a media source has opened',
    () async {
      const playerChannel = MethodChannel('erika_flutter/player');
      const eventsChannel = MethodChannel('erika_flutter/events');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final playerCalls = <MethodCall>[];

      messenger.setMockMethodCallHandler(playerChannel, (call) async {
        playerCalls.add(call);
        if (call.method == 'create') {
          return 1;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(eventsChannel, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(playerChannel, null);
        messenger.setMockMethodCallHandler(eventsChannel, null);
      });

      final player = AudioPlayer();
      await Future<void>.delayed(Duration.zero);

      await player.stop();
      expect(playerCalls.where((call) => call.method == 'stop'), isEmpty);

      await player.setFilePath(r'C:\Game\Assets\sound\ui_hover.mp3');
      await player.stop();
      expect(playerCalls.where((call) => call.method == 'stop'), hasLength(1));

      await player.dispose();
    },
    skip: !Platform.isWindows,
  );
}
