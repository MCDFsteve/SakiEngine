import 'dart:async';

import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:just_audio/just_audio.dart' show LoopMode, ProcessingState;
import 'package:sakiengine/src/config/asset_manager.dart';

/// Minimal engine audio contract over audioplayers_linux's system GStreamer.
/// Only the Linux plugin is a dependency; other platforms keep just_audio.
class SakiLinuxAudioPlayer {
  SakiLinuxAudioPlayer() : _platform = AudioplayersPlatformInterface.instance;

  static int _nextId = 0;
  final String _id = 'saki-audio-${_nextId++}';
  final AudioplayersPlatformInterface _platform;
  final _events = StreamController<Object?>.broadcast();
  StreamSubscription<AudioEvent>? _subscription;
  Future<void>? _creation;
  Completer<void>? _preparing;
  LoopMode _loopMode = LoopMode.off;
  bool _disposed = false;
  bool _playing = false;
  ProcessingState _state = ProcessingState.idle;

  bool get playing => _playing;
  ProcessingState get processingState => _state;
  Stream<Object?> get playbackEventStream => _events.stream;

  Future<void> _ensureCreated() {
    if (_disposed) throw StateError('AudioPlayer has been disposed.');
    return _creation ??= _create();
  }

  Future<void> _create() async {
    await _platform.create(_id);
    _subscription = _platform
        .getEventStream(_id)
        .listen(
          (event) {
            if (event.eventType == AudioEventType.prepared &&
                event.isPrepared == true) {
              _state = ProcessingState.ready;
              _preparing?.complete();
              _preparing = null;
            } else if (event.eventType == AudioEventType.complete &&
                _loopMode == LoopMode.off) {
              _playing = false;
              _state = ProcessingState.completed;
            }
            _events.add(event);
          },
          onError: (Object error, StackTrace stack) {
            _playing = false;
            _state = ProcessingState.idle;
            final preparing = _preparing;
            _preparing = null;
            if (preparing != null) {
              preparing.completeError(error, stack);
            } else {
              _events.addError(error, stack);
            }
          },
        );
    await _platform.setReleaseMode(_id, ReleaseMode.stop);
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _ensureCreated();
    _loopMode = mode;
    await _platform.setReleaseMode(
      _id,
      mode == LoopMode.off ? ReleaseMode.stop : ReleaseMode.loop,
    );
  }

  Future<void> setVolume(double volume) async {
    await _ensureCreated();
    await _platform.setVolume(_id, volume);
  }

  Future<void> setUrl(String url) async {
    await _ensureCreated();
    _interruptLoad();
    _playing = false;
    _state = ProcessingState.loading;
    final preparing = Completer<void>();
    _preparing = preparing;
    try {
      // Wait for preroll, not for playback/EOF, matching just_audio.load.
      await Future.wait<void>([
        preparing.future.timeout(const Duration(seconds: 30)),
        _platform.setSourceUrl(_id, url, isLocal: false),
      ], eagerError: true);
    } catch (_) {
      if (identical(_preparing, preparing)) _state = ProcessingState.idle;
      rethrow;
    } finally {
      if (identical(_preparing, preparing)) _preparing = null;
      // Cancel the timeout if setting the source itself failed first.
      if (!preparing.isCompleted) preparing.complete();
    }
  }

  Future<void> setFilePath(String path) =>
      setUrl(Uri.file(path, windows: false).toString());

  Future<void> setAsset(String assetPath) async {
    final path = await AssetManager().findNativeMediaAsset(assetPath);
    if (path == null) throw StateError('Audio asset not found: $assetPath');
    await setFilePath(path);
  }

  Future<void> play() async {
    await _ensureCreated();
    await _platform.resume(_id);
    _playing = true;
  }

  Future<void> pause() async {
    if (_creation == null || _disposed) return;
    await _creation;
    await _platform.pause(_id);
    _playing = false;
  }

  Future<void> stop() async {
    _interruptLoad();
    _playing = false;
    _state = ProcessingState.idle;
    if (_creation == null || _disposed) return;
    await _creation;
    await _platform.stop(_id);
  }

  void _interruptLoad() {
    _preparing?.completeError(StateError('Audio loading interrupted'));
    _preparing = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playing = false;
    _interruptLoad();
    try {
      if (_creation != null) {
        await _creation;
        await _subscription?.cancel();
        await _platform.dispose(_id);
      }
    } finally {
      await _events.close();
    }
  }
}
