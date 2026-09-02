import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'saki_audio_player_platform_stub.dart'
    if (dart.library.io) 'saki_audio_player_platform_io.dart';

enum LoopMode { off, one }

enum ProcessingState { idle, loading, ready, completed }

/// Small audio-only facade used by the engine.
///
/// Windows reuses Erika, which is already shipped for video playback. Other
/// platforms keep the existing just_audio backend so this Windows-only change
/// does not alter their media stack.
class AudioPlayer {
  AudioPlayer()
    : _erikaPlayer = useErikaForSakiAudio
          ? ErikaPlayer(allowBackgroundPlayback: true)
          : null,
      _justAudioPlayer = useErikaForSakiAudio
          ? null
          : just_audio.AudioPlayer() {
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      _erikaSubscription = erikaPlayer.events.listen(
        _handleErikaEvent,
        onError: _playbackEvents.addError,
      );
    }
  }

  final ErikaPlayer? _erikaPlayer;
  final just_audio.AudioPlayer? _justAudioPlayer;
  final StreamController<Object?> _playbackEvents =
      StreamController<Object?>.broadcast();
  StreamSubscription<ErikaPlayerEvent>? _erikaSubscription;

  LoopMode _loopMode = LoopMode.off;
  ProcessingState _erikaProcessingState = ProcessingState.idle;
  bool _erikaPlaying = false;
  bool _erikaHasMedia = false;
  bool _disposed = false;
  bool _restartingLoop = false;

  bool get playing => _justAudioPlayer?.playing ?? _erikaPlaying;

  Object get processingState =>
      _justAudioPlayer?.processingState ?? _erikaProcessingState;

  Stream<Object?> get playbackEventStream =>
      _justAudioPlayer?.playbackEventStream ?? _playbackEvents.stream;

  Future<void> setLoopMode(LoopMode mode) async {
    _loopMode = mode;
    final player = _justAudioPlayer;
    if (player != null) {
      await player.setLoopMode(
        mode == LoopMode.one
            ? just_audio.LoopMode.one
            : just_audio.LoopMode.off,
      );
    }
  }

  Future<void> setVolume(double volume) async {
    final normalized = volume.clamp(0.0, 1.0).toDouble();
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      await erikaPlayer.setVolume(normalized);
      return;
    }
    await _justAudioPlayer!.setVolume(normalized);
  }

  Future<void> setUrl(String url) async {
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      await _openErika(erikaPlayer, url);
      return;
    }
    await _justAudioPlayer!.setUrl(url);
  }

  Future<void> setFilePath(String path) async {
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      await _openErika(erikaPlayer, path);
      return;
    }
    await _justAudioPlayer!.setFilePath(path);
  }

  Future<void> setAsset(String assetPath) async {
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      throw UnsupportedError(
        'Erika audio requires a resolved file path on Windows: $assetPath',
      );
    }
    await _justAudioPlayer!.setAsset(assetPath);
  }

  Future<void> _openErika(ErikaPlayer player, String uri) async {
    _ensureActive();
    _erikaPlaying = false;
    _erikaHasMedia = false;
    _erikaProcessingState = ProcessingState.loading;
    try {
      await player.open(uri);
      _erikaHasMedia = true;
      _erikaProcessingState = ProcessingState.ready;
    } catch (_) {
      _erikaProcessingState = ProcessingState.idle;
      rethrow;
    }
  }

  Future<void> play() async {
    _ensureActive();
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      _erikaPlaying = true;
      await erikaPlayer.play();
      return;
    }
    await _justAudioPlayer!.play();
  }

  Future<void> pause() async {
    _ensureActive();
    _erikaPlaying = false;
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      await erikaPlayer.pause();
      return;
    }
    await _justAudioPlayer!.pause();
  }

  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    _erikaPlaying = false;
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      if (!_erikaHasMedia) {
        _erikaProcessingState = ProcessingState.idle;
        return;
      }
      await erikaPlayer.stop();
      _erikaProcessingState = ProcessingState.idle;
      return;
    }
    await _justAudioPlayer!.stop();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _erikaPlaying = false;
    _erikaHasMedia = false;
    await _erikaSubscription?.cancel();
    _erikaSubscription = null;
    final erikaPlayer = _erikaPlayer;
    if (erikaPlayer != null) {
      await erikaPlayer.dispose();
    } else {
      await _justAudioPlayer!.dispose();
    }
    await _playbackEvents.close();
  }

  void _handleErikaEvent(ErikaPlayerEvent event) {
    if (_disposed) {
      return;
    }
    if (event.kind == ErikaEventKind.error ||
        event.state == ErikaPlaybackState.error) {
      _erikaPlaying = false;
      _erikaHasMedia = false;
      _playbackEvents.addError(
        StateError(event.message ?? event.error ?? 'Erika audio error'),
      );
      return;
    }
    if (event.kind != ErikaEventKind.stateChanged) {
      _playbackEvents.add(event);
      return;
    }

    switch (event.state) {
      case ErikaPlaybackState.opening:
        _erikaProcessingState = ProcessingState.loading;
        break;
      case ErikaPlaybackState.ready:
      case ErikaPlaybackState.playing:
      case ErikaPlaybackState.paused:
        _erikaHasMedia = true;
        _erikaProcessingState = ProcessingState.ready;
        break;
      case ErikaPlaybackState.stopped:
        _erikaHasMedia = true;
        if (_erikaPlaying && _loopMode == LoopMode.one) {
          _restartErikaLoop();
        } else {
          _erikaPlaying = false;
          _erikaProcessingState = ProcessingState.completed;
        }
        break;
      case ErikaPlaybackState.idle:
      case ErikaPlaybackState.closed:
        _erikaPlaying = false;
        _erikaHasMedia = false;
        _erikaProcessingState = ProcessingState.idle;
        break;
      case ErikaPlaybackState.error:
        _erikaHasMedia = false;
        break;
    }
    _playbackEvents.add(event);
  }

  void _restartErikaLoop() {
    if (_restartingLoop || _disposed) {
      return;
    }
    _restartingLoop = true;
    unawaited(() async {
      try {
        final player = _erikaPlayer;
        if (player == null || !_erikaPlaying || _loopMode != LoopMode.one) {
          return;
        }
        await player.seek(Duration.zero);
        if (_erikaPlaying && !_disposed) {
          await player.play();
        }
      } catch (error, stackTrace) {
        if (!_disposed) {
          _playbackEvents.addError(error, stackTrace);
        }
      } finally {
        _restartingLoop = false;
      }
    }());
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('AudioPlayer has been disposed.');
    }
  }
}
