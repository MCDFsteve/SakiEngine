import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/utils/bundle_asset_path_probe.dart';
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/config/saki_pack_store.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/game/unified_game_data_manager.dart';
import 'package:sakiengine/src/config/project_info_manager.dart';

/// 音频轨道类型枚举
enum AudioTrackType {
  music, // 音乐轨道：循环播放，单轨道
  sound, // 音效轨道：单次播放，可重叠
}

/// 音频轨道配置
class AudioTrackConfig {
  final AudioTrackType type;
  final bool defaultLoop;
  final bool canOverlap;
  final String trackName;

  const AudioTrackConfig({
    required this.type,
    required this.defaultLoop,
    required this.canOverlap,
    required this.trackName,
  });

  static const music = AudioTrackConfig(
    type: AudioTrackType.music,
    defaultLoop: true,
    canOverlap: false,
    trackName: 'music',
  );

  static const sound = AudioTrackConfig(
    type: AudioTrackType.sound,
    defaultLoop: false,
    canOverlap: true,
    trackName: 'sound',
  );
}

class _MusicPlayRequest {
  final String assetPath;
  final bool fadeTransition;
  final Duration fadeDuration;
  final bool loop;

  const _MusicPlayRequest({
    required this.assetPath,
    required this.fadeTransition,
    required this.fadeDuration,
    required this.loop,
  });
}

/// Project-provided metadata for a character with independently adjustable
/// dialogue voice volume.
///
/// [voiceFilePrefixes] are matched against the voice asset's file name (for
/// example, `xiayo_` matches `Assets/voice/cp1/xiayo_001.m4a`). Keeping the
/// matching rule here lets projects declare their cast without teaching the
/// engine about project-specific character names or directories.
class VoiceCharacterProfile {
  final String id;
  final String displayName;
  final String avatarAsset;
  final String previewVoiceAsset;
  final List<String> voiceFilePrefixes;

  const VoiceCharacterProfile({
    required this.id,
    required this.displayName,
    required this.avatarAsset,
    required this.previewVoiceAsset,
    required this.voiceFilePrefixes,
  });

  bool matchesVoiceAsset(String assetPath) {
    final fileName = p.basename(assetPath.trim()).toLowerCase();
    return voiceFilePrefixes.any((prefix) {
      final normalizedPrefix = p.basename(prefix.trim()).toLowerCase();
      return normalizedPrefix.isNotEmpty &&
          fileName.startsWith(normalizedPrefix);
    });
  }
}

class MusicManager extends ChangeNotifier {
  static final MusicManager _instance = MusicManager._internal();
  factory MusicManager() => _instance;
  MusicManager._internal();

  static String buildVoiceAssetPath(String rawVoiceFile) {
    var voiceFile = rawVoiceFile.trim();
    if ((voiceFile.startsWith('"') && voiceFile.endsWith('"')) ||
        (voiceFile.startsWith("'") && voiceFile.endsWith("'"))) {
      if (voiceFile.length >= 2) {
        voiceFile = voiceFile.substring(1, voiceFile.length - 1).trim();
      }
    }
    if (voiceFile.isEmpty) {
      return '';
    }
    if (!voiceFile.contains('.')) {
      voiceFile = '$voiceFile.mp3';
    }
    if (voiceFile.startsWith('Assets/voice/')) {
      return voiceFile;
    }
    return 'Assets/voice/$voiceFile';
  }

  static const bool _musicSourceDiagnostics = bool.fromEnvironment(
    'SAKI_MUSIC_SOURCE_DIAG',
    defaultValue: false,
  );
  static const bool _verboseAudioLogs = bool.fromEnvironment(
    'SAKI_AUDIO_VERBOSE_LOG',
    defaultValue: false,
  );
  static const bool _memoryLifecycleDiagnostics = bool.fromEnvironment(
    'SAKI_MEMORY_DIAG',
    defaultValue: false,
  );

  // 统一的音频轨道管理
  final Map<AudioTrackType, AudioPlayer> _trackPlayers = {
    AudioTrackType.music: AudioPlayer(),
    AudioTrackType.sound: AudioPlayer(),
  };
  AudioPlayer _voicePlayer = AudioPlayer();

  // 音效可能需要多个播放器来支持重叠播放
  final List<AudioPlayer> _soundPlayers = [];
  int _soundPlayerIndex = 0;
  bool _initialized = false;
  Future<void>? _initializeFuture;
  Future<void>? _soundPoolInitialization;
  Future<void>? _gameAudioReleaseFuture;
  Future<void>? _shutdownFuture;
  int _audioSessionGeneration = 0;
  static const int _overlappingSoundPlayerCount = 5;

  final _dataManager = UnifiedGameDataManager();
  String? _projectName;
  String? _currentBackgroundMusic;
  String? _currentSound;
  double? _previewMusicVolume;
  double? _previewSoundVolume;
  double? _previewVoiceVolume;
  List<VoiceCharacterProfile> _voiceCharacterProfiles = const [];
  String? _currentVoiceCharacterId;
  _MusicPlayRequest? _queuedMusicRequest;
  Future<void>? _musicTransitionDrain;
  bool _isMusicTransitioning = false;

  // 淡入淡出相关
  final Map<AudioTrackType, Timer?> _fadeTimers = {};
  final Map<AudioTrackType, bool> _isFading = {};
  final Map<AudioTrackType, double> _currentFadeVolume = {};
  final Map<AudioTrackType, Completer<void>?> _fadeCompleters = {};

  bool get isMusicEnabled => _dataManager.isMusicEnabled;
  bool get isSoundEnabled => _dataManager.isSoundEnabled;
  double get musicVolume => _previewMusicVolume ?? _dataManager.musicVolume;
  double get soundVolume => _previewSoundVolume ?? _dataManager.soundVolume;
  double get voiceVolume => _previewVoiceVolume ?? _dataManager.voiceVolume;
  List<VoiceCharacterProfile> get voiceCharacterProfiles =>
      _voiceCharacterProfiles;
  String? get currentBackgroundMusic => _currentBackgroundMusic;
  String? get currentSound => _currentSound;

  static const String _voiceCharacterVolumeKeyPrefix =
      'sakiengine.voiceCharacterVolume.';

  /// Registers the independently adjustable voice cast for the active project.
  void configureVoiceCharacters(List<VoiceCharacterProfile> profiles) {
    final ids = <String>{};
    for (final profile in profiles) {
      final id = profile.id.trim();
      if (id.isEmpty) {
        throw ArgumentError.value(
          profile.id,
          'profile.id',
          'Must not be empty',
        );
      }
      if (!ids.add(id)) {
        throw ArgumentError.value(profile.id, 'profile.id', 'Must be unique');
      }
      if (profile.voiceFilePrefixes.isEmpty) {
        throw ArgumentError.value(
          profile.voiceFilePrefixes,
          'profile.voiceFilePrefixes',
          'Must contain at least one prefix',
        );
      }
    }

    _voiceCharacterProfiles = List.unmodifiable(profiles);
    notifyListeners();
  }

  String _voiceCharacterVolumeKey(String characterId) =>
      '$_voiceCharacterVolumeKeyPrefix${Uri.encodeComponent(characterId)}';

  VoiceCharacterProfile? voiceCharacterProfileForAsset(String assetPath) {
    for (final profile in _voiceCharacterProfiles) {
      if (profile.matchesVoiceAsset(assetPath)) {
        return profile;
      }
    }
    return null;
  }

  double voiceCharacterVolume(String characterId) {
    return _dataManager
        .getDoubleVariable(
          _voiceCharacterVolumeKey(characterId),
          defaultValue: 1.0,
        )
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Future<void> setVoiceCharacterVolume(
    String characterId,
    double volume,
  ) async {
    await initialize();
    final normalizedVolume = volume.clamp(0.0, 1.0).toDouble();
    await _dataManager.setDoubleVariable(
      _voiceCharacterVolumeKey(characterId),
      normalizedVolume,
      _projectName!,
    );
    if (_currentVoiceCharacterId == characterId) {
      await _updateVoiceVolume();
    }
    notifyListeners();
  }

  Future<void> resetVoiceCharacterVolumes() async {
    await initialize();
    for (final profile in _voiceCharacterProfiles) {
      await _dataManager.setDoubleVariable(
        _voiceCharacterVolumeKey(profile.id),
        1.0,
        _projectName!,
      );
    }
    await _updateVoiceVolume();
    notifyListeners();
  }

  void _musicSourceLog(String message) {
    if (_musicSourceDiagnostics && kEngineDebugMode) {
      print('[MusicSourceDiag] $message');
    }
  }

  void _audioVerboseLog(String message) {
    if (_verboseAudioLogs && kEngineDebugMode) {
      print('[MusicManager] $message');
    }
  }

  Future<void> initialize() async {
    if (_initialized) {
      await _updateTrackVolume(AudioTrackType.music);
      await _updateTrackVolume(AudioTrackType.sound);
      await _updateVoiceVolume();
      return;
    }
    final activeInitialization = _initializeFuture;
    if (activeInitialization != null) {
      await activeInitialization;
      return;
    }

    final initialization = _initializeInternal();
    _initializeFuture = initialization;
    try {
      await initialization;
      _initialized = true;
    } finally {
      if (identical(_initializeFuture, initialization)) {
        _initializeFuture = null;
      }
    }
  }

  Future<void> _initializeInternal() async {
    // 获取项目名称
    try {
      _projectName = await ProjectInfoManager().getAppName();
    } catch (e) {
      _projectName = 'SakiEngine';
    }

    // 初始化数据管理器
    await _dataManager.init(_projectName!);

    // 设置音乐轨道为循环播放
    await _trackPlayers[AudioTrackType.music]!.setLoopMode(LoopMode.one);
    _attachPlayerDiagnostics(
      _trackPlayers[AudioTrackType.music]!,
      'music-main',
    );

    // 设置音效轨道为单次播放
    await _trackPlayers[AudioTrackType.sound]!.setLoopMode(LoopMode.off);
    _attachPlayerDiagnostics(
      _trackPlayers[AudioTrackType.sound]!,
      'sound-main',
    );

    await _voicePlayer.setLoopMode(LoopMode.off);
    _attachPlayerDiagnostics(_voicePlayer, 'voice-main');

    await _ensureSoundPlayerPool();

    await _updateTrackVolume(AudioTrackType.music);
    await _updateTrackVolume(AudioTrackType.sound);
    await _updateVoiceVolume();
  }

  Future<void> _ensureSoundPlayerPool() async {
    if (_soundPlayers.isNotEmpty) {
      return;
    }
    final activeInitialization = _soundPoolInitialization;
    if (activeInitialization != null) {
      await activeInitialization;
      return;
    }

    final generation = _audioSessionGeneration;
    final initialization = () async {
      for (int i = 0; i < _overlappingSoundPlayerCount; i++) {
        final player = AudioPlayer();
        await player.setLoopMode(LoopMode.off);
        if (generation != _audioSessionGeneration) {
          await player.dispose();
          return;
        }
        _soundPlayers.add(player);
        _attachPlayerDiagnostics(player, 'sound-$i');
      }
    }();
    _soundPoolInitialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_soundPoolInitialization, initialization)) {
        _soundPoolInitialization = null;
      }
    }
  }

  void _attachPlayerDiagnostics(AudioPlayer player, String label) {
    if (!kEngineDebugMode) {
      return;
    }
    player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        print('[MusicManager] [$label] playbackEvent error: $error');
        print(stackTrace);
      },
    );
  }

  Future<void> setMusicEnabled(bool enabled) async {
    await _dataManager.setMusicEnabled(enabled, _projectName!);

    if (!enabled) {
      _cancelTrackFade(AudioTrackType.music);
      await _trackPlayers[AudioTrackType.music]!.pause();
    } else if (_currentBackgroundMusic != null) {
      await playAudio(
        _currentBackgroundMusic!,
        AudioTrackConfig.music,
        fadeTransition: true,
        fadeDuration: const Duration(milliseconds: 500),
      );
    }

    notifyListeners();
  }

  Future<void> setSoundEnabled(bool enabled) async {
    await _dataManager.setSoundEnabled(enabled, _projectName!);

    if (!enabled) {
      _cancelTrackFade(AudioTrackType.sound);
      await _trackPlayers[AudioTrackType.sound]!.pause();
      // 暂停所有音效播放器
      for (final player in _soundPlayers) {
        await player.pause();
      }
      await _voicePlayer.pause();
    }

    notifyListeners();
  }

  Future<void> setMusicVolume(double volume) async {
    final normalizedVolume = volume.clamp(0.0, 1.0).toDouble();
    _previewMusicVolume = null;
    await _dataManager.setMusicVolume(normalizedVolume, _projectName!);
    await _updateTrackVolume(AudioTrackType.music);
    notifyListeners();
  }

  Future<void> setSoundVolume(double volume) async {
    final normalizedVolume = volume.clamp(0.0, 1.0).toDouble();
    _previewSoundVolume = null;
    await _dataManager.setSoundVolume(normalizedVolume, _projectName!);
    await _updateTrackVolume(AudioTrackType.sound);
    notifyListeners();
  }

  Future<void> setVoiceVolume(double volume) async {
    final normalizedVolume = volume.clamp(0.0, 1.0).toDouble();
    _previewVoiceVolume = null;
    await _dataManager.setVoiceVolume(normalizedVolume, _projectName!);
    await _updateVoiceVolume();
    notifyListeners();
  }

  Future<void> previewMusicVolume(double volume) async {
    _previewMusicVolume = volume.clamp(0.0, 1.0).toDouble();
    await _updateTrackVolume(AudioTrackType.music);
    notifyListeners();
  }

  Future<void> previewSoundVolume(double volume) async {
    _previewSoundVolume = volume.clamp(0.0, 1.0).toDouble();
    await _updateTrackVolume(AudioTrackType.sound);
    notifyListeners();
  }

  Future<void> previewVoiceVolume(double volume) async {
    _previewVoiceVolume = volume.clamp(0.0, 1.0).toDouble();
    await _updateVoiceVolume();
    notifyListeners();
  }

  Future<void> _updateVoiceVolume() async {
    final characterVolume = _currentVoiceCharacterId == null
        ? 1.0
        : voiceCharacterVolume(_currentVoiceCharacterId!);
    final volume = _dataManager.isSoundEnabled
        ? (voiceVolume * characterVolume).clamp(0.0, 1.0).toDouble()
        : 0.0;
    await _voicePlayer.setVolume(volume);
  }

  /// 统一的轨道音量更新方法
  Future<void> _updateTrackVolume(AudioTrackType trackType) async {
    late bool isEnabled;
    late double baseVolume;

    switch (trackType) {
      case AudioTrackType.music:
        isEnabled = _dataManager.isMusicEnabled;
        baseVolume = musicVolume;
        break;
      case AudioTrackType.sound:
        isEnabled = _dataManager.isSoundEnabled;
        baseVolume = soundVolume;
        break;
    }

    final actualVolume = isEnabled ? baseVolume : 0.0;
    final isFading = _isFading[trackType] ?? false;
    final fadeVolume = isFading
        ? (_currentFadeVolume[trackType] ?? actualVolume)
        : actualVolume;

    await _trackPlayers[trackType]!.setVolume(fadeVolume);

    // 同时更新音效播放器
    if (trackType == AudioTrackType.sound) {
      for (final player in _soundPlayers) {
        await player.setVolume(fadeVolume);
      }
    }
  }

  /// 统一的淡出方法
  Future<void> _fadeOut(
    AudioTrackType trackType, {
    Duration duration = const Duration(milliseconds: 1000),
    FutureOr<void> Function()? onComplete,
  }) async {
    late bool isEnabled;
    late double baseVolume;
    late String? currentTrack;

    switch (trackType) {
      case AudioTrackType.music:
        isEnabled = _dataManager.isMusicEnabled;
        baseVolume = musicVolume;
        currentTrack = _currentBackgroundMusic;
        break;
      case AudioTrackType.sound:
        isEnabled = _dataManager.isSoundEnabled;
        baseVolume = soundVolume;
        currentTrack = _currentSound;
        break;
    }

    if (!isEnabled || currentTrack == null) {
      if (onComplete != null) {
        await onComplete();
      }
      return;
    }

    _cancelTrackFade(trackType); // 取消之前的淡化效果
    _isFading[trackType] = true;
    _currentFadeVolume[trackType] = baseVolume;

    final completer = Completer<void>();
    _fadeCompleters[trackType] = completer;

    const steps = 20; // 分20步进行淡出
    final stepDuration = Duration(
      milliseconds: duration.inMilliseconds ~/ steps,
    );
    final volumeStep = baseVolume / steps;

    int currentStep = 0;
    _fadeTimers[trackType] = Timer.periodic(stepDuration, (timer) async {
      currentStep++;
      final newVolume = baseVolume - (volumeStep * currentStep);
      _currentFadeVolume[trackType] = newVolume.clamp(0.0, 1.0);

      await _updateTrackVolume(trackType);

      if (currentStep >= steps || _currentFadeVolume[trackType]! <= 0.0) {
        timer.cancel();
        _isFading[trackType] = false;
        _currentFadeVolume[trackType] = 0.0;
        if (onComplete != null) {
          await onComplete();
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
        _fadeCompleters[trackType] = null;
      }
    });

    await completer.future;
  }

  /// 统一的淡入方法
  Future<void> _fadeIn(
    AudioTrackType trackType, {
    Duration duration = const Duration(milliseconds: 1000),
    FutureOr<void> Function()? onComplete,
  }) async {
    late bool isEnabled;
    late double baseVolume;
    late String? currentTrack;

    switch (trackType) {
      case AudioTrackType.music:
        isEnabled = _dataManager.isMusicEnabled;
        baseVolume = musicVolume;
        currentTrack = _currentBackgroundMusic;
        break;
      case AudioTrackType.sound:
        isEnabled = _dataManager.isSoundEnabled;
        baseVolume = soundVolume;
        currentTrack = _currentSound;
        break;
    }

    if (!isEnabled || currentTrack == null) {
      if (onComplete != null) {
        await onComplete();
      }
      return;
    }

    _cancelTrackFade(trackType); // 取消之前的淡化效果
    _isFading[trackType] = true;
    _currentFadeVolume[trackType] = 0.0;
    await _updateTrackVolume(trackType); // 先设置为0音量

    final completer = Completer<void>();
    _fadeCompleters[trackType] = completer;

    const steps = 20; // 分20步进行淡入
    final stepDuration = Duration(
      milliseconds: duration.inMilliseconds ~/ steps,
    );
    final volumeStep = baseVolume / steps;

    int currentStep = 0;
    _fadeTimers[trackType] = Timer.periodic(stepDuration, (timer) async {
      currentStep++;
      final newVolume = volumeStep * currentStep;
      _currentFadeVolume[trackType] = newVolume.clamp(0.0, baseVolume);

      await _updateTrackVolume(trackType);

      if (currentStep >= steps ||
          _currentFadeVolume[trackType]! >= baseVolume) {
        timer.cancel();
        _isFading[trackType] = false;
        _currentFadeVolume[trackType] = baseVolume;
        await _updateTrackVolume(trackType);
        if (onComplete != null) {
          await onComplete();
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
        _fadeCompleters[trackType] = null;
      }
    });

    await completer.future;
  }

  /// 取消指定轨道的淡化效果
  void _cancelTrackFade(AudioTrackType trackType) {
    _fadeTimers[trackType]?.cancel();
    _fadeTimers[trackType] = null;
    _isFading[trackType] = false;
    final completer = _fadeCompleters[trackType];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _fadeCompleters[trackType] = null;
  }

  /// 取消所有轨道的淡化效果
  void _cancelAllFades() {
    for (final trackType in AudioTrackType.values) {
      _cancelTrackFade(trackType);
    }
  }

  /// 统一的音频播放方法
  Future<void> playAudio(
    String assetPath,
    AudioTrackConfig config, {
    bool fadeTransition = true,
    Duration fadeDuration = const Duration(milliseconds: 1000),
    bool loop = false, // 允许覆盖默认循环设置
  }) async {
    try {
      _audioVerboseLog(
        'playAudio request: track=${config.trackName}, assetPath=$assetPath, '
        'fade=$fadeTransition, fadeMs=${fadeDuration.inMilliseconds}, loop=$loop',
      );
      // 根据轨道类型选择处理逻辑
      if (config.type == AudioTrackType.music) {
        await _playMusic(
          assetPath,
          fadeTransition: fadeTransition,
          fadeDuration: fadeDuration,
          loop: loop || config.defaultLoop,
        );
      } else if (config.type == AudioTrackType.sound) {
        await _playSound(
          assetPath,
          config,
          fadeTransition: fadeTransition,
          fadeDuration: fadeDuration,
          loop: loop,
        );
      }
    } catch (e, stackTrace) {
      if (kEngineDebugMode) {
        print(
          '[MusicManager] playAudio failed: track=${config.trackName}, assetPath=$assetPath, error=$e',
        );
        print(stackTrace);
      }
    }
  }

  /// 播放音乐（向后兼容的方法）
  Future<void> playBackgroundMusic(
    String assetPath, {
    bool fadeTransition = true,
    Duration fadeDuration = const Duration(milliseconds: 1000),
  }) async {
    await playAudio(
      assetPath,
      AudioTrackConfig.music,
      fadeTransition: fadeTransition,
      fadeDuration: fadeDuration,
    );
  }

  /// 播放音乐的具体实现
  Future<void> _playMusic(
    String assetPath, {
    required bool fadeTransition,
    required Duration fadeDuration,
    required bool loop,
  }) async {
    _queuedMusicRequest = _MusicPlayRequest(
      assetPath: assetPath,
      fadeTransition: fadeTransition,
      fadeDuration: fadeDuration,
      loop: loop,
    );

    final activeDrain = _musicTransitionDrain;
    if (activeDrain != null) {
      await activeDrain;
      return;
    }

    final drainFuture = _drainQueuedMusicRequests();
    _musicTransitionDrain = drainFuture;
    try {
      await drainFuture;
    } finally {
      if (identical(_musicTransitionDrain, drainFuture)) {
        _musicTransitionDrain = null;
      }
    }
  }

  Future<void> _drainQueuedMusicRequests() async {
    while (true) {
      final request = _queuedMusicRequest;
      _queuedMusicRequest = null;
      if (request == null) {
        return;
      }
      await _playMusicRequest(request);
    }
  }

  Future<void> _playMusicRequest(_MusicPlayRequest request) async {
    final musicPlayer = _trackPlayers[AudioTrackType.music]!;
    final assetPath = request.assetPath;
    final fadeTransition = request.fadeTransition;
    final fadeDuration = request.fadeDuration;
    final loop = request.loop;

    _musicSourceLog(
      'playMusic request: assetPath="$assetPath", old="$_currentBackgroundMusic", fade=$fadeTransition, loop=$loop',
    );
    _audioVerboseLog(
      '_playMusic begin: new=$assetPath, current=$_currentBackgroundMusic, '
      'playerPlaying=${musicPlayer.playing}, transitioning=$_isMusicTransitioning, '
      'fade=$fadeTransition',
    );

    if (_currentBackgroundMusic == assetPath &&
        (musicPlayer.playing || _isMusicTransitioning)) {
      _audioVerboseLog(
        '_playMusic skip: already playing/transitioning same track',
      );
      return;
    }

    if (!_dataManager.isMusicEnabled) {
      _currentBackgroundMusic = assetPath;
      _audioVerboseLog('_playMusic abort: music disabled, only cached path');
      return;
    }

    final oldMusicPath = _currentBackgroundMusic;
    _currentBackgroundMusic = assetPath;
    _isMusicTransitioning = true;
    try {
      Future<void> startNewMusic() async {
        try {
          _musicSourceLog('startNewMusic: stop current player then set source');
          await musicPlayer.stop();
          await musicPlayer.setLoopMode(loop ? LoopMode.one : LoopMode.off);
          await _setPlayerSource(musicPlayer, assetPath, sourceLabel: 'music');
          final playFuture = musicPlayer.play();
          unawaited(
            playFuture.catchError((Object e, StackTrace stackTrace) {
              if (kEngineDebugMode) {
                print(
                  '[MusicManager] music.play async failed: $assetPath, error=$e',
                );
                print(stackTrace);
              }
            }),
          );
          _audioVerboseLog(
            '_playMusic started (non-blocking): $assetPath, '
            'playing=${musicPlayer.playing}, state=${musicPlayer.processingState}',
          );
        } catch (e, stackTrace) {
          if (kEngineDebugMode) {
            print(
              '[MusicManager] _playMusic startNewMusic failed: $assetPath, error=$e',
            );
            print(stackTrace);
          }
          rethrow;
        }
      }

      _audioVerboseLog(
        '_playMusic transition: old=$oldMusicPath -> new=$assetPath',
      );
      if (oldMusicPath != null && fadeTransition) {
        // 先淡出旧音乐
        await _fadeOut(
          AudioTrackType.music,
          duration: Duration(milliseconds: fadeDuration.inMilliseconds ~/ 2),
          onComplete: () async {
            await startNewMusic();
            await _fadeIn(
              AudioTrackType.music,
              duration: Duration(
                milliseconds: fadeDuration.inMilliseconds ~/ 2,
              ),
            );
          },
        );
      } else {
        // 没有旧音乐或不需要过渡，直接播放
        await startNewMusic();

        if (fadeTransition) {
          // 淡入新音乐
          await _fadeIn(AudioTrackType.music, duration: fadeDuration);
        } else {
          // 直接设置音量
          await _updateTrackVolume(AudioTrackType.music);
        }
      }
    } finally {
      _isMusicTransitioning = false;
    }
  }

  /// 播放音效的具体实现
  Future<void> _playSound(
    String assetPath,
    AudioTrackConfig config, {
    required bool fadeTransition,
    required Duration fadeDuration,
    required bool loop,
  }) async {
    final activeRelease = _gameAudioReleaseFuture;
    if (activeRelease != null) {
      await activeRelease;
    }
    if (!_dataManager.isSoundEnabled) {
      _currentSound = assetPath;
      return;
    }

    if (config.canOverlap) {
      await _ensureSoundPlayerPool();
    }
    final sessionGeneration = _audioSessionGeneration;
    _currentSound = assetPath;

    // 对于音效，如果允许重叠，使用额外的播放器
    AudioPlayer player;
    if (config.canOverlap && _soundPlayers.isNotEmpty) {
      // 使用轮询的方式选择音效播放器
      player = _soundPlayers[_soundPlayerIndex % _soundPlayers.length];
      _soundPlayerIndex = (_soundPlayerIndex + 1) % _soundPlayers.length;
    } else {
      // 使用主音效播放器
      player = _trackPlayers[AudioTrackType.sound]!;
    }

    await player.stop();
    await player.setLoopMode(loop ? LoopMode.one : LoopMode.off);
    await _setPlayerSource(player, assetPath, sourceLabel: 'sound');
    if (sessionGeneration != _audioSessionGeneration) {
      return;
    }
    // `AudioPlayer.play()` completes when playback finishes or is interrupted
    // on the native just_audio backends. Awaiting it would therefore block the
    // SKS executor for the full duration of a one-shot sound, and forever for a
    // looping ambience cue. Only source/setup work belongs to this Future; keep
    // actual playback detached, matching the music and voice channels.
    final playFuture = player.play();
    unawaited(
      playFuture.catchError((Object error, StackTrace stackTrace) {
        if (kEngineDebugMode) {
          print(
            '[MusicManager] sound.play async failed: $assetPath, error=$error',
          );
          print(stackTrace);
        }
      }),
    );

    if (fadeTransition) {
      // 音效淡入（通常时间较短）
      await _fadeIn(
        AudioTrackType.sound,
        duration: Duration(milliseconds: fadeDuration.inMilliseconds ~/ 2),
      );
    } else {
      // 直接设置音量
      await _updateTrackVolume(AudioTrackType.sound);
    }
  }

  /// Loads and starts a one-shot dialogue voice cue without waiting for it to end.
  /// A new cue always interrupts the previous one on this dedicated channel.
  Future<void> playVoice(String assetPath) async {
    final activeRelease = _gameAudioReleaseFuture;
    if (activeRelease != null) {
      await activeRelease;
    }

    if (!_dataManager.isSoundEnabled) {
      return;
    }

    _currentVoiceCharacterId = voiceCharacterProfileForAsset(assetPath)?.id;
    final sessionGeneration = _audioSessionGeneration;
    await _voicePlayer.stop();
    await _voicePlayer.setLoopMode(LoopMode.off);
    await _setPlayerSource(_voicePlayer, assetPath, sourceLabel: 'voice');
    if (sessionGeneration != _audioSessionGeneration) {
      return;
    }
    await _updateVoiceVolume();
    final playFuture = _voicePlayer.play();
    unawaited(
      playFuture.catchError((Object error, StackTrace stackTrace) {
        if (kEngineDebugMode) {
          print('[MusicManager] voice.play failed: $assetPath, error=$error');
          print(stackTrace);
        }
      }),
    );
  }

  Future<void> stopVoice() async {
    try {
      await _voicePlayer.stop();
    } catch (error) {
      if (kEngineDebugMode) {
        print('[MusicManager] stopVoice failed: $error');
      }
    }
  }

  Future<void> _setPlayerSource(
    AudioPlayer player,
    String assetPath, {
    String sourceLabel = '',
  }) async {
    final traceMusic = sourceLabel == 'music' && _musicSourceDiagnostics;
    final trimmed = assetPath.trim();
    if (traceMusic) {
      _musicSourceLog(
        'setPlayerSource input: assetPath="$assetPath", trimmed="$trimmed"',
      );
    }
    _audioVerboseLog('_setPlayerSource input=$assetPath trimmed=$trimmed');
    if (trimmed.isEmpty) {
      if (traceMusic) {
        _musicSourceLog('setPlayerSource failed: empty assetPath');
      }
      throw ArgumentError('assetPath must not be empty');
    }
    try {
      if (_isNetworkPath(trimmed)) {
        if (traceMusic) {
          _musicSourceLog('try setUrl("$trimmed")');
        }
        await player.setUrl(trimmed);
        if (traceMusic) {
          _musicSourceLog('setUrl success: "$trimmed"');
        }
        return;
      }
      if (trimmed.startsWith('file://')) {
        final path = Uri.parse(trimmed).toFilePath();
        if (traceMusic) {
          _musicSourceLog('try setFilePath(from file://): "$path"');
        }
        await player.setFilePath(path);
        if (traceMusic) {
          _musicSourceLog('setFilePath success: "$path"');
        }
        return;
      }
      if (trimmed.startsWith('/')) {
        if (traceMusic) {
          _musicSourceLog('try setFilePath(absolute): "$trimmed"');
        }
        await player.setFilePath(trimmed);
        if (traceMusic) {
          _musicSourceLog('setFilePath success: "$trimmed"');
        }
        return;
      }
      final resolved = _normalizeBundleAssetPath(trimmed);
      final packPlaybackPath =
          await SakiPackStore.instance.resolvePathForPlayback(resolved) ??
          await SakiPackStore.instance.resolvePathForPlayback(trimmed);
      if (packPlaybackPath != null) {
        if (traceMusic) {
          _musicSourceLog('try setFilePath(sakipack): "$packPlaybackPath"');
        }
        try {
          await player.setFilePath(packPlaybackPath);
          if (traceMusic) {
            _musicSourceLog(
              'setFilePath(sakipack) success: "$packPlaybackPath"',
            );
          }
          return;
        } catch (packError, packStackTrace) {
          if (traceMusic) {
            _musicSourceLog(
              'setFilePath(sakipack) failed: "$packPlaybackPath", error=$packError',
            );
          }
          if (kEngineDebugMode) {
            print(
              '[MusicManager] setFilePath(sakipack) failed: path=$packPlaybackPath, error=$packError',
            );
            print(packStackTrace);
          }
        }
      }
      final absoluteBundlePath = probeBundleAssetAbsolutePath(resolved);
      final absoluteBundleExists = probeBundleAssetExists(resolved);
      if (traceMusic) {
        _musicSourceLog(
          'normalized asset="$resolved", shouldUseFileSystemAssets=${GamePathResolver.shouldUseFileSystemAssets}',
        );
        _musicSourceLog(
          'bundle absolute candidate: ${absoluteBundlePath ?? "<unavailable on this platform>"}, exists=${absoluteBundleExists ?? "<unknown>"}',
        );
      }
      if (absoluteBundlePath != null && absoluteBundleExists == true) {
        if (traceMusic) {
          _musicSourceLog(
            'try setFilePath(bundle absolute first): "$absoluteBundlePath"',
          );
        }
        try {
          await player.setFilePath(absoluteBundlePath);
          if (traceMusic) {
            _musicSourceLog(
              'setFilePath(bundle absolute first) success: "$absoluteBundlePath"',
            );
          }
          return;
        } catch (bundleFileError, bundleFileStackTrace) {
          if (traceMusic) {
            _musicSourceLog(
              'setFilePath(bundle absolute first) failed: "$absoluteBundlePath", error=$bundleFileError',
            );
          }
          if (kEngineDebugMode) {
            print(
              '[MusicManager] bundle absolute setFilePath failed: path=$absoluteBundlePath, error=$bundleFileError',
            );
            print(bundleFileStackTrace);
          }
        }
      }
      _audioVerboseLog('_setPlayerSource resolvedAsset=$resolved');
      final fallbackFilePath = await _resolveGameAssetFallbackPath(resolved);
      if (traceMusic) {
        _musicSourceLog(
          'fallback path resolve result: ${fallbackFilePath ?? "<null>"}',
        );
      }
      if (fallbackFilePath != null) {
        if (traceMusic) {
          _musicSourceLog(
            'try setFilePath(primary fallback): "$fallbackFilePath"',
          );
        }
        _audioVerboseLog(
          'try setFilePath first via SAKI_GAME_PATH: $fallbackFilePath',
        );
        try {
          await player.setFilePath(fallbackFilePath);
          if (traceMusic) {
            _musicSourceLog(
              'setFilePath(primary fallback) success: "$fallbackFilePath"',
            );
          }
          return;
        } catch (fileError, fileStackTrace) {
          if (traceMusic) {
            _musicSourceLog(
              'setFilePath(primary fallback) failed: "$fallbackFilePath", error=$fileError',
            );
          }
          if (kEngineDebugMode) {
            print(
              '[MusicManager] setFilePath primary failed, fallback to setAsset: path=$fallbackFilePath, error=$fileError',
            );
            print(fileStackTrace);
          }
        }
      }
      try {
        if (traceMusic) {
          _musicSourceLog('try setAsset("$resolved")');
        }
        await player.setAsset(resolved);
        if (traceMusic) {
          _musicSourceLog('setAsset success: "$resolved"');
        }
        return;
      } catch (assetError, assetStackTrace) {
        if (traceMusic) {
          _musicSourceLog('setAsset failed: "$resolved", error=$assetError');
        }
        if (fallbackFilePath != null) {
          if (kEngineDebugMode) {
            print(
              '[MusicManager] setAsset failed, fallback to file path: $fallbackFilePath, error=$assetError',
            );
          }
          try {
            if (traceMusic) {
              _musicSourceLog(
                'try setFilePath(secondary fallback): "$fallbackFilePath"',
              );
            }
            await player.setFilePath(fallbackFilePath);
            if (traceMusic) {
              _musicSourceLog(
                'setFilePath(secondary fallback) success: "$fallbackFilePath"',
              );
            }
            return;
          } catch (fallbackError, fallbackStackTrace) {
            if (traceMusic) {
              _musicSourceLog(
                'setFilePath(secondary fallback) failed: "$fallbackFilePath", error=$fallbackError',
              );
            }
            if (kEngineDebugMode) {
              print(
                '[MusicManager] fallback setFilePath failed: path=$fallbackFilePath, error=$fallbackError',
              );
              print(fallbackStackTrace);
            }
          }
        }
        if (kEngineDebugMode) {
          print(
            '[MusicManager] setAsset failed without usable fallback: resolved=$resolved, error=$assetError',
          );
          print(assetStackTrace);
        }
        rethrow;
      }
    } catch (e, stackTrace) {
      if (traceMusic) {
        _musicSourceLog(
          'setPlayerSource final failure: input="$assetPath", trimmed="$trimmed", error=$e',
        );
      }
      if (kEngineDebugMode) {
        print(
          '[MusicManager] _setPlayerSource failed: input=$assetPath, trimmed=$trimmed, error=$e',
        );
        print(stackTrace);
      }
      rethrow;
    }
  }

  String _normalizeBundleAssetPath(String path) {
    final normalized = path.startsWith('asset:///')
        ? path.replaceFirst('asset:///', '')
        : path;
    final lower = normalized.toLowerCase();
    if (lower.startsWith('assets/') || lower.startsWith('packages/')) {
      return normalized;
    }
    return 'Assets/$normalized';
  }

  Future<String?> _resolveGameAssetFallbackPath(
    String resolvedAssetPath,
  ) async {
    if (!GamePathResolver.shouldUseFileSystemAssets) {
      return null;
    }

    final gamePath = await GamePathResolver.resolveGamePath();
    if (gamePath == null || gamePath.isEmpty) {
      return null;
    }

    if (resolvedAssetPath.startsWith('/')) {
      return resolvedAssetPath;
    }

    return p.normalize(p.join(gamePath, resolvedAssetPath));
  }

  bool _isNetworkPath(String path) {
    return path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('rtsp://') ||
        path.startsWith('rtmp://');
  }

  /// 统一的音频停止方法
  Future<void> stopAudio(
    AudioTrackConfig config, {
    bool fadeOut = true,
    Duration fadeDuration = const Duration(milliseconds: 800),
  }) async {
    if (config.type == AudioTrackType.music) {
      await stopBackgroundMusic(fadeOut: fadeOut, fadeDuration: fadeDuration);
    } else if (config.type == AudioTrackType.sound) {
      await _stopSound(fadeOut: fadeOut, fadeDuration: fadeDuration);
    }
  }

  /// 停止音效的具体实现
  Future<void> _stopSound({
    bool fadeOut = true,
    Duration fadeDuration = const Duration(milliseconds: 400),
  }) async {
    try {
      if (_currentSound == null) return;

      if (fadeOut && _dataManager.isSoundEnabled) {
        if (kEngineDebugMode) {
          //print('[AudioManager] 淡出停止音效: $_currentSound');
        }

        await _fadeOut(
          AudioTrackType.sound,
          duration: fadeDuration,
          onComplete: () async {
            await _trackPlayers[AudioTrackType.sound]!.stop();
            // 停止所有音效播放器
            for (final player in _soundPlayers) {
              await player.stop();
            }
            _currentSound = null;
          },
        );
      } else {
        await _trackPlayers[AudioTrackType.sound]!.stop();
        for (final player in _soundPlayers) {
          await player.stop();
        }
        _currentSound = null;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error stopping sound effect: $e');
      }
    }
  }

  Future<void> stopBackgroundMusic({
    bool fadeOut = true,
    Duration fadeDuration = const Duration(milliseconds: 800),
  }) async {
    try {
      if (_currentBackgroundMusic == null) return;

      if (fadeOut && _dataManager.isMusicEnabled) {
        if (kEngineDebugMode) {
          //print('[AudioManager] 淡出停止音乐: $_currentBackgroundMusic');
        }

        await _fadeOut(
          AudioTrackType.music,
          duration: fadeDuration,
          onComplete: () async {
            await _trackPlayers[AudioTrackType.music]!.stop();
            _currentBackgroundMusic = null;
          },
        );
      } else {
        await _trackPlayers[AudioTrackType.music]!.stop();
        _currentBackgroundMusic = null;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error stopping background music: $e');
      }
    }
  }

  Future<void> clearBackgroundMusic({
    bool fadeOut = true,
    Duration fadeDuration = const Duration(milliseconds: 800),
  }) async {
    try {
      if (_currentBackgroundMusic == null) return;

      if (fadeOut && _dataManager.isMusicEnabled) {
        if (kEngineDebugMode) {
          //print('[AudioManager] 淡出清除音乐: $_currentBackgroundMusic');
        }

        await _fadeOut(
          AudioTrackType.music,
          duration: fadeDuration,
          onComplete: () async {
            await _trackPlayers[AudioTrackType.music]!.stop();
            _currentBackgroundMusic = null;
          },
        );
      } else {
        _cancelTrackFade(AudioTrackType.music); // 取消任何正在进行的淡化
        await _trackPlayers[AudioTrackType.music]!.stop();
        _currentBackgroundMusic = null;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error clearing background music: $e');
      }
    }
  }

  /// 检查指定音乐是否正在播放
  bool isPlayingMusic(String assetPath) {
    return _currentBackgroundMusic == assetPath &&
        _trackPlayers[AudioTrackType.music]!.playing;
  }

  /// 强制停止背景音乐（用于音乐区间系统）
  Future<void> forceStopBackgroundMusic({
    bool fadeOut = true,
    Duration fadeDuration = const Duration(milliseconds: 600),
  }) async {
    try {
      if (_currentBackgroundMusic == null) return;

      if (fadeOut && _dataManager.isMusicEnabled) {
        if (kEngineDebugMode) {
          //print('[AudioManager] 淡出强制停止音乐: $_currentBackgroundMusic');
        }

        await _fadeOut(
          AudioTrackType.music,
          duration: fadeDuration,
          onComplete: () async {
            await _trackPlayers[AudioTrackType.music]!.stop();
            _currentBackgroundMusic = null;
          },
        );
      } else {
        _cancelTrackFade(AudioTrackType.music); // 取消任何正在进行的淡化
        await _trackPlayers[AudioTrackType.music]!.stop();
        _currentBackgroundMusic = null;
        if (kEngineDebugMode) {
          //print('[AudioManager] 强制停止背景音乐');
        }
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error force stopping background music: $e');
      }
    }
  }

  Future<void> pauseBackgroundMusic() async {
    try {
      await _trackPlayers[AudioTrackType.music]!.pause();
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error pausing background music: $e');
      }
    }
  }

  Future<void> resumeBackgroundMusic() async {
    try {
      if (_dataManager.isMusicEnabled && _currentBackgroundMusic != null) {
        await _trackPlayers[AudioTrackType.music]!.play();
        // 恢复播放时淡入
        await _fadeIn(
          AudioTrackType.music,
          duration: const Duration(milliseconds: 500),
        );
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error resuming background music: $e');
      }
    }
  }

  /// 播放音效（向后兼容的方法，现在支持淡入淡出）
  Future<void> playSoundEffect(String assetPath, {bool loop = false}) async {
    await playAudio(
      assetPath,
      AudioTrackConfig.sound,
      fadeTransition: true,
      fadeDuration: const Duration(milliseconds: 200),
      loop: loop,
    );
  }

  /// 返回主菜单时释放本局剧情使用过的 mpv 音效核心和解码源。
  ///
  /// 主音乐播放器继续保留给菜单音乐复用；音效主轨与重叠播放器按需重建，
  /// 从而让已经启动的 mpv worker/demux 线程和其缓冲真正退出。
  Future<void> releaseGameAudioResources() async {
    final activeRelease = _gameAudioReleaseFuture;
    if (activeRelease != null) {
      await activeRelease;
      return;
    }

    final release = _releaseGameAudioResourcesInternal();
    _gameAudioReleaseFuture = release;
    try {
      await release;
    } finally {
      if (identical(_gameAudioReleaseFuture, release)) {
        _gameAudioReleaseFuture = null;
      }
    }
  }

  Future<void> _releaseGameAudioResourcesInternal() async {
    _audioSessionGeneration++;
    _cancelTrackFade(AudioTrackType.sound);
    _currentSound = null;
    _soundPlayerIndex = 0;

    final previousMainSound = _trackPlayers[AudioTrackType.sound]!;
    final previousVoice = _voicePlayer;
    final previousPool = List<AudioPlayer>.of(_soundPlayers);
    _soundPlayers.clear();

    final replacementMainSound = AudioPlayer();
    await replacementMainSound.setLoopMode(LoopMode.off);
    _attachPlayerDiagnostics(replacementMainSound, 'sound-main');
    _trackPlayers[AudioTrackType.sound] = replacementMainSound;
    await _updateTrackVolume(AudioTrackType.sound);

    _voicePlayer = AudioPlayer();
    await _voicePlayer.setLoopMode(LoopMode.off);
    _attachPlayerDiagnostics(_voicePlayer, 'voice-main');
    await _updateVoiceVolume();

    final playersToRelease = <AudioPlayer>[
      previousMainSound,
      previousVoice,
      ...previousPool,
    ];
    if (_memoryLifecycleDiagnostics) {
      print(
        '[SAKI_MEMORY][AUDIO] releasing '
        '${playersToRelease.length} gameplay sound players',
      );
    }
    await Future.wait<void>(
      playersToRelease.map((player) async {
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }),
      eagerError: false,
    );
    if (_memoryLifecycleDiagnostics) {
      print('[SAKI_MEMORY][AUDIO] gameplay sound players released');
    }
  }

  /// 在 Flutter/Dart 运行时销毁前等待所有 mpv 后台线程退出。
  Future<void> shutdown() async {
    final activeShutdown = _shutdownFuture;
    if (activeShutdown != null) {
      await activeShutdown;
      return;
    }

    final shutdown = _shutdownInternal();
    _shutdownFuture = shutdown;
    await shutdown;
  }

  Future<void> _shutdownInternal() async {
    _audioSessionGeneration++;
    _initialized = false;
    _queuedMusicRequest = null;
    _cancelAllFades();

    final players = <AudioPlayer>[
      ..._trackPlayers.values,
      _voicePlayer,
      ..._soundPlayers,
    ];
    _trackPlayers.clear();
    _soundPlayers.clear();
    _currentBackgroundMusic = null;
    _currentSound = null;

    await Future.wait<void>(
      players.map((player) async {
        try {
          await player.stop();
        } catch (_) {}
        try {
          await player.dispose();
        } catch (_) {}
      }),
      eagerError: false,
    );
    // 给 media_kit 的事件端口一个事件循环周期来完成注销。
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
