import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/saki_audio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <MethodChannel>[];
  final calls = <MethodCall>[];
  String? playerId;
  bool autoPrepare = true;
  bool failLoad = false;

  void mock(String name, Future<Object?> Function(MethodCall) handler) {
    final channel = MethodChannel(name);
    channels.add(channel);
    messenger.setMockMethodCallHandler(channel, handler);
  }

  Future<void> emit(String name, Map<String, Object?> event) async {
    await messenger.handlePlatformMessage(
      name,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> prepared() => emit('xyz.luan/audioplayers/events/$playerId', {
    'event': 'audio.onPrepared',
    'value': true,
  });

  Future<void> linuxError() async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$playerId',
      const StandardMethodCodec().encodeErrorEnvelope(
        code: 'LinuxAudioError',
        message: 'GStreamer could not decode the source',
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    calls.clear();
    autoPrepare = true;
    failLoad = false;
    playerId = null;
    mock(
      'erika_flutter/player',
      (_) async => throw StateError('Audio must not use Erika'),
    );
    mock(
      'com.ryanheise.audio_session',
      (call) async => call.method == 'setActive' ? true : null,
    );
    mock('com.ryanheise.just_audio.methods', (call) async {
      calls.add(call);
      if (call.method == 'init') {
        playerId = (call.arguments as Map)['id'] as String;
        mock('com.ryanheise.just_audio.events.$playerId', (_) async => null);
        mock('com.ryanheise.just_audio.data.$playerId', (_) async => null);
        mock('com.ryanheise.just_audio.methods.$playerId', (call) async {
          calls.add(call);
          if (call.method == 'load') {
            await emit('com.ryanheise.just_audio.events.$playerId', {
              'processingState': 3,
              'updateTime': DateTime.now().millisecondsSinceEpoch,
              'updatePosition': 0,
              'bufferedPosition': 1000000,
              'duration': 1000000,
              'currentIndex': 0,
            });
            return {'duration': 1000000};
          }
          return <String, Object?>{};
        });
      }
      return <String, Object?>{};
    });
    mock('xyz.luan/audioplayers', (call) async {
      calls.add(call);
      if (call.method == 'create') {
        playerId = (call.arguments as Map)['playerId'] as String;
        mock('xyz.luan/audioplayers/events/$playerId', (_) async => null);
      } else if (call.method == 'setSourceUrl') {
        if (failLoad) throw PlatformException(code: 'LinuxAudioError');
        if (autoPrepare) await prepared();
      }
      return null;
    });
  });

  tearDown(() async {
    await Future<void>.delayed(Duration.zero);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    channels.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  test('Windows starts playback without the mobile session handshake', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    mock('com.ryanheise.audio_session', (call) async {
      if (call.method == 'setConfiguration') {
        // WinRT can still report the loaded source as paused while just_audio
        // awaits session activation, overwriting its pending playing state.
        await emit('com.ryanheise.just_audio.data.$playerId', {'playing': false});
      }
      return null;
    });
    final player = AudioPlayer();
    addTearDown(player.dispose);
    await player.setFilePath('C:/Game/Assets/music/bgm_008.mp3');
    await player.play();
    expect(calls.where((call) => call.method == 'play'), hasLength(1));
    expect(player.playing, isTrue);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    test(
      '$platform audio loads and plays through just_audio without a surface',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final player = AudioPlayer();
        addTearDown(player.dispose);
        await player.setLoopMode(LoopMode.one);
        await player.setVolume(0.35);
        await player.setUrl('file:///C:/Game/Assets/music/bgm_008.mp3');
        expect(player.processingState, ProcessingState.ready);
        await player.play();
        expect(player.playing, isTrue);
        expect(calls.any((call) => call.method == 'init'), isTrue);
        final load = calls.singleWhere((call) => call.method == 'load');
        expect(
          (load.arguments as Map)['audioSource']['uri'],
          contains('bgm_008.mp3'),
        );
        expect(
          calls.where((call) => call.method == 'setVolume').last.arguments,
          {'volume': 0.35},
        );
        expect(
          calls.where((call) => call.method == 'setLoopMode').last.arguments,
          {'loopMode': 1},
        );
        await player.pause();
        expect(player.playing, isFalse);
        await player.stop();
      },
    );
  }

  test(
    'Linux waits for GStreamer preroll, then plays independently of EOF',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      autoPrepare = false;
      final player = AudioPlayer();
      addTearDown(player.dispose);
      await player.stop();
      expect(calls, isEmpty);
      var loaded = false;
      final loading = player
          .setFilePath('/tmp/Game 音频/ui click.mp3')
          .then((_) => loaded = true);
      await Future<void>.delayed(Duration.zero);
      expect(loaded, isFalse);
      expect(player.processingState, ProcessingState.loading);
      final source = calls.singleWhere((call) => call.method == 'setSourceUrl');
      expect(
        (source.arguments as Map)['url'],
        Uri.file('/tmp/Game 音频/ui click.mp3').toString(),
      );
      await prepared();
      await loading;
      await player.play();
      expect(player.playing, isTrue);
      expect(player.processingState, ProcessingState.ready);
      await emit('xyz.luan/audioplayers/events/$playerId', {
        'event': 'audio.onComplete',
        'value': true,
      });
      expect(player.playing, isFalse);
      expect(player.processingState, ProcessingState.completed);
    },
  );

  test(
    'Linux native loops stay playing and stop/dispose are explicit',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final player = AudioPlayer();
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(2);
      await player.setUrl('https://example.invalid/music.mp3');
      await player.play();
      await emit('xyz.luan/audioplayers/events/$playerId', {
        'event': 'audio.onComplete',
        'value': true,
      });
      expect(player.playing, isTrue);
      expect(
        calls.where((call) => call.method == 'setReleaseMode').last.arguments,
        containsPair('releaseMode', 'ReleaseMode.loop'),
      );
      expect(
        calls.singleWhere((call) => call.method == 'setVolume').arguments,
        containsPair('volume', 1.0),
      );
      await player.pause();
      expect(player.playing, isFalse);
      await player.stop();
      expect(player.processingState, ProcessingState.idle);
      await player.dispose();
      await player.dispose();
      expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    },
  );

  test(
    'Linux source errors and interrupted loads complete without hanging',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final player = AudioPlayer();
      addTearDown(player.dispose);
      failLoad = true;
      await expectLater(
        player.setUrl('invalid://audio'),
        throwsA(isA<PlatformException>()),
      );
      expect(player.processingState, ProcessingState.idle);
      failLoad = false;
      autoPrepare = false;
      final loading = player.setUrl('https://example.invalid/audio.mp3');
      final interrupted = expectLater(loading, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await player.stop();
      await interrupted;
      autoPrepare = true;
      await player.setUrl('https://example.invalid/retry.mp3');
      expect(player.processingState, ProcessingState.ready);
    },
  );

  test('Linux decoder errors reach the load or playback listener', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    autoPrepare = false;
    final player = AudioPlayer();
    addTearDown(player.dispose);
    final loading = expectLater(
      player.setUrl('file:///tmp/broken.mp3'),
      throwsA(isA<PlatformException>()),
    );
    await Future<void>.delayed(Duration.zero);
    await linuxError();
    await loading;
    expect(player.processingState, ProcessingState.idle);

    autoPrepare = true;
    await player.setUrl('file:///tmp/music.mp3');
    await player.play();
    final playbackError = expectLater(
      player.playbackEventStream,
      emitsError(isA<PlatformException>()),
    );
    await linuxError();
    await playbackError;
    expect(player.playing, isFalse);
    expect(player.processingState, ProcessingState.idle);
  });

  test('Linux disposal interrupts pending preroll and rejects reuse', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    autoPrepare = false;
    final player = AudioPlayer();
    final loading = expectLater(
      player.setUrl('file:///tmp/music.mp3'),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    await player.dispose();
    await loading;
    await expectLater(player.play(), throwsStateError);
    await expectLater(player.setUrl('file:///tmp/music.mp3'), throwsStateError);
    expect(player.playing, isFalse);
  });
}
