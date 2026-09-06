import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as native;

import 'saki_linux_audio_player.dart';

export 'package:just_audio/just_audio.dart' show LoopMode, ProcessingState;

/// Audio is independent of the Erika video presenter and its render surface.
///
/// just_audio uses the platform audio implementation (including WinRT through
/// just_audio_windows). Linux uses the system GStreamer plugin instead of mpv.
class AudioPlayer {
  AudioPlayer()
    : this._(!kIsWeb && defaultTargetPlatform == TargetPlatform.linux);

  AudioPlayer._(bool linux)
    : _native = linux
          ? null
          : native.AudioPlayer(
              // WinRT needs no audio-focus activation. Waiting for the mobile
              // session handshake lets a pending Windows paused event cancel
              // just_audio's play request before it reaches the native player.
              handleAudioSessionActivation:
                  kIsWeb || defaultTargetPlatform != TargetPlatform.windows,
            ),
      _linux = linux ? SakiLinuxAudioPlayer() : null;

  final native.AudioPlayer? _native;
  final SakiLinuxAudioPlayer? _linux;

  bool get playing => _native?.playing ?? _linux!.playing;
  native.ProcessingState get processingState =>
      _native?.processingState ?? _linux!.processingState;
  Stream<Object?> get playbackEventStream =>
      _native?.playbackEventStream ?? _linux!.playbackEventStream;

  Future<void> setLoopMode(native.LoopMode mode) =>
      _native?.setLoopMode(mode) ?? _linux!.setLoopMode(mode);

  Future<void> setVolume(double volume) {
    final normalized = volume.clamp(0.0, 1.0).toDouble();
    return _native?.setVolume(normalized) ?? _linux!.setVolume(normalized);
  }

  Future<void> setUrl(String url) async {
    if (_native != null) {
      await _native.setUrl(url);
    } else {
      await _linux!.setUrl(url);
    }
  }

  Future<void> setFilePath(String path) async {
    if (_native != null) {
      await _native.setFilePath(path);
    } else {
      await _linux!.setFilePath(path);
    }
  }

  Future<void> setAsset(String assetPath) async {
    if (_native != null) {
      await _native.setAsset(assetPath);
    } else {
      await _linux!.setAsset(assetPath);
    }
  }

  Future<void> play() => _native?.play() ?? _linux!.play();
  Future<void> pause() => _native?.pause() ?? _linux!.pause();
  Future<void> stop() => _native?.stop() ?? _linux!.stop();
  Future<void> dispose() => _native?.dispose() ?? _linux!.dispose();
}
