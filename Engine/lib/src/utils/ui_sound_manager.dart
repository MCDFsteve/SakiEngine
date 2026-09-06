import 'dart:async';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/config/project_info_manager.dart';
import 'package:sakiengine/src/config/saki_pack_store.dart';
import 'package:sakiengine/src/game/unified_game_data_manager.dart';
import 'package:sakiengine/src/utils/bundle_asset_path_probe.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/saki_audio_player.dart';

/// UI interaction sound manager (hover/click).
class UISoundManager {
  static final UISoundManager _instance = UISoundManager._internal();
  factory UISoundManager() => _instance;
  UISoundManager._internal();

  final List<AudioPlayer> _players = <AudioPlayer>[];
  int _playerIndex = 0;
  final UnifiedGameDataManager _dataManager = UnifiedGameDataManager();
  String? _projectName;
  final Random _random = Random();
  bool _initialized = false;
  bool _uiSoundsResolved = false;
  Future<void>? _shutdownFuture;
  final Set<Future<void>> _activePlaybackOperations = <Future<void>>{};
  bool _isShuttingDown = false;
  final List<String> _hoverSounds = <String>[];
  String? _clickSound;
  String? _backSound;
  String? _adjustSound;

  static const List<String> _uiSoundDirectories = <String>[
    'Assets/sound',
    'Assets/gui',
  ];
  static const Map<String, String> _preferredUiSounds = <String, String>{
    'hover': 'Assets/sound/ui_hover.mp3',
    'click': 'Assets/sound/ui_click.mp3',
    'back': 'Assets/sound/ui_back.mp3',
    'adjust': 'Assets/sound/ui_adjust.mp3',
  };
  static const List<String> _supportedSoundExtensions = <String>[
    '.mp3',
    '.ogg',
    '.wav',
    '.flac',
    '.m4a',
    '.aac',
  ];

  bool get isSoundEnabled => _dataManager.isSoundEnabled;
  double get soundVolume => _dataManager.soundVolume;

  Future<void> initialize() async {
    if (_initialized) {
      await _updateVolume();
      return;
    }

    try {
      _projectName = await ProjectInfoManager().getAppName();
    } catch (_) {
      _projectName = 'SakiEngine';
    }

    await _dataManager.init(_projectName!);

    if (_players.isEmpty) {
      for (int i = 0; i < 3; i++) {
        final AudioPlayer player = AudioPlayer();
        await player.setLoopMode(LoopMode.off);
        _players.add(player);
      }
    }

    await _resolveUiSounds();
    await _updateVolume();
    _initialized = true;
  }

  Future<void> _updateVolume() async {
    final double actualVolume = isSoundEnabled ? soundVolume : 0.0;
    for (final AudioPlayer player in _players) {
      await player.setVolume(actualVolume);
    }
  }

  Future<void> playButtonHover() =>
      _trackPlayback(() => _playRandomSound(_hoverSounds, 'playButtonHover'));

  Future<void> playButtonClick() => _trackPlayback(
    () => _playResolvedSound(() => _clickSound, 'playButtonClick'),
  );

  Future<void> playButtonBack() => _trackPlayback(
    () => _playResolvedSound(() => _backSound ?? _clickSound, 'playButtonBack'),
  );

  Future<void> playSettingAdjust() => _trackPlayback(
    () => _playResolvedSound(
      () => _adjustSound ?? _clickSound,
      'playSettingAdjust',
    ),
  );

  Future<void> _trackPlayback(Future<void> Function() createOperation) {
    if (_isShuttingDown) {
      return Future<void>.value();
    }
    final operation = createOperation();
    _activePlaybackOperations.add(operation);
    return operation.whenComplete(() {
      _activePlaybackOperations.remove(operation);
    });
  }

  Future<void> _playRandomSound(List<String> sounds, String debugLabel) async {
    if (!isSoundEnabled) return;

    try {
      await _ensureReady();
      if (sounds.isEmpty) {
        return;
      }
      final String assetPath = sounds[_random.nextInt(sounds.length)];
      await _playSound(assetPath);
    } catch (e) {
      if (kEngineDebugMode && !_isExpectedInterruptionError(e)) {
        print('[UISoundManager] $debugLabel failed: $e');
      }
    }
  }

  Future<void> _playResolvedSound(
    String? Function() resolveSound,
    String debugLabel,
  ) async {
    if (!isSoundEnabled) return;

    try {
      await _ensureReady();
      final sound = resolveSound();
      if (sound == null || sound.isEmpty) {
        return;
      }
      await _playSound(sound);
    } catch (e) {
      if (kEngineDebugMode && !_isExpectedInterruptionError(e)) {
        print('[UISoundManager] $debugLabel failed: $e');
      }
    }
  }

  Future<void> _playSound(String assetPath) async {
    if (_players.isEmpty) {
      await initialize();
      if (_players.isEmpty) {
        if (kEngineDebugMode) {
          print('[UISoundManager] no available audio players');
        }
        return;
      }
    }

    final AudioPlayer player = _players[_playerIndex % _players.length];
    _playerIndex = (_playerIndex + 1) % _players.length;

    await player.setVolume(isSoundEnabled ? soundVolume : 0.0);

    await player.stop();
    await player.setLoopMode(LoopMode.off);
    await _setPlayerSource(player, assetPath);
    await player.play();
  }

  Future<void> stopAll() async {
    for (final AudioPlayer player in _players) {
      await player.stop();
    }
  }

  Future<void> shutdown() async {
    final activeShutdown = _shutdownFuture;
    if (activeShutdown != null) {
      await activeShutdown;
      return;
    }

    _isShuttingDown = true;
    final pendingOperations = List<Future<void>>.of(_activePlaybackOperations);
    if (pendingOperations.isNotEmpty) {
      await Future.wait<void>(pendingOperations, eagerError: false);
    }

    final players = List<AudioPlayer>.of(_players);
    _players.clear();
    _hoverSounds.clear();
    _clickSound = null;
    _backSound = null;
    _adjustSound = null;
    _uiSoundsResolved = false;
    _initialized = false;
    final shutdown = Future.wait<void>(
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
    _shutdownFuture = shutdown;
    await shutdown;
  }

  void dispose() {
    unawaited(shutdown());
  }

  Future<void> _ensureReady() async {
    if (_players.isEmpty || !_initialized) {
      await initialize();
      return;
    }
    await _resolveUiSounds();
  }

  Future<void> _resolveUiSounds() async {
    if (_uiSoundsResolved) {
      return;
    }
    _uiSoundsResolved = true;

    final Set<String> files = <String>{};
    await _addPreferredUiSounds(files);
    for (final extension in _supportedSoundExtensions) {
      for (final directory in _uiSoundDirectories) {
        try {
          final entries = await AssetManager().listAssets(directory, extension);
          files.addAll(
            entries.map((fileName) => _buildUiSoundPath(directory, fileName)),
          );
        } catch (e) {
          if (kEngineDebugMode) {
            print(
              '[UISoundManager] listAssets failed: dir=$directory ext=$extension error=$e',
            );
          }
        }
      }
    }

    final List<String> audioAssets = files.toList()..sort();
    if (audioAssets.isEmpty) {
      return;
    }

    final hoverCandidates = _pickHoverCandidates(audioAssets);
    final clickCandidate =
        _pickPreferredSound(audioAssets, const <String>[
          'ui_click',
          'click',
          'confirm',
          'select',
          'press',
          'enter',
          'ok',
          'main',
        ]) ??
        _pickFallbackCandidate(audioAssets, hoverCandidates);
    final backCandidate = _pickPreferredSound(audioAssets, const <String>[
      'ui_back',
      'back',
      'return',
      'cancel',
      'close',
      'exit',
      'quit',
    ]);
    final adjustCandidate = _pickPreferredSound(audioAssets, const <String>[
      'ui_adjust',
      'adjust',
      'setting',
      'settings',
      'toggle',
      'switch',
    ]);

    _hoverSounds
      ..clear()
      ..addAll(hoverCandidates);
    _clickSound = clickCandidate;
    _backSound = backCandidate;
    _adjustSound = adjustCandidate;
  }

  Future<void> _addPreferredUiSounds(Set<String> files) async {
    for (final assetPath in _preferredUiSounds.values) {
      try {
        final resolvedPath = await AssetManager().findAsset(assetPath);
        if (resolvedPath != null && resolvedPath.isNotEmpty) {
          files.add(assetPath);
        }
      } catch (_) {}
    }
  }

  String _buildUiSoundPath(String directory, String fileName) {
    if (fileName.startsWith('Assets/') || fileName.startsWith('assets/')) {
      return fileName;
    }
    return '$directory/$fileName';
  }

  List<String> _pickHoverCandidates(List<String> audioAssets) {
    final List<String> hoverSounds = audioAssets.where((assetPath) {
      final stem = _soundStemLower(assetPath);
      return stem == 'ui_hover' ||
          stem.contains('hover') ||
          stem.startsWith('button') ||
          stem.contains('rollover') ||
          stem.contains('cursor') ||
          stem.contains('focus');
    }).toList();

    if (hoverSounds.isNotEmpty) {
      return hoverSounds;
    }
    return const <String>[];
  }

  String? _pickPreferredSound(List<String> audioAssets, List<String> stems) {
    for (final assetPath in audioAssets) {
      final stem = _soundStemLower(assetPath);
      if (stems.contains(stem)) {
        return assetPath;
      }
    }

    for (final assetPath in audioAssets) {
      final stem = _soundStemLower(assetPath);
      if (stems.any((candidate) => stem.contains(candidate))) {
        return assetPath;
      }
    }

    return null;
  }

  String? _pickFallbackCandidate(
    List<String> audioAssets,
    List<String> hoverCandidates,
  ) {
    for (final assetPath in audioAssets) {
      if (assetPath.startsWith('Assets/gui/') &&
          !hoverCandidates.contains(assetPath)) {
        return assetPath;
      }
    }

    return null;
  }

  String _soundStemLower(String assetPath) {
    return p.basenameWithoutExtension(assetPath).toLowerCase();
  }

  Future<void> _setPlayerSource(AudioPlayer player, String assetPath) async {
    final String trimmed = assetPath.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('assetPath must not be empty');
    }

    if (_isNetworkPath(trimmed)) {
      await player.setUrl(trimmed);
      return;
    }

    if (trimmed.startsWith('file://')) {
      await player.setFilePath(Uri.parse(trimmed).toFilePath());
      return;
    }

    if (p.isAbsolute(trimmed)) {
      await player.setFilePath(trimmed);
      return;
    }

    final String resolved = _normalizeBundleAssetPath(trimmed);
    final String? packPlaybackPath =
        await SakiPackStore.instance.resolvePathForPlayback(resolved) ??
        await SakiPackStore.instance.resolvePathForPlayback(trimmed);
    if (packPlaybackPath != null) {
      try {
        await player.setFilePath(packPlaybackPath);
        return;
      } catch (e) {
        if (kEngineDebugMode && !_isExpectedInterruptionError(e)) {
          print(
            '[UISoundManager] setFilePath(sakipack) failed: $packPlaybackPath, error=$e',
          );
        }
      }
    }

    final String? bundlePath = probeBundleAssetAbsolutePath(resolved);
    final bool? bundleExists = probeBundleAssetExists(resolved);

    if (bundlePath != null && bundleExists == true) {
      try {
        await player.setFilePath(bundlePath);
        return;
      } catch (e) {
        if (kEngineDebugMode && !_isExpectedInterruptionError(e)) {
          print(
            '[UISoundManager] setFilePath(bundle) failed: $bundlePath, error=$e',
          );
        }
      }
    }

    final String? gamePath = await _resolveGameAssetPath(resolved);
    if (gamePath != null) {
      try {
        await player.setFilePath(gamePath);
        return;
      } catch (e) {
        if (kEngineDebugMode && !_isExpectedInterruptionError(e)) {
          print(
            '[UISoundManager] setFilePath(game) failed: $gamePath, error=$e',
          );
        }
      }
    }

    await player.setAsset(resolved);
  }

  String _normalizeBundleAssetPath(String path) {
    final String normalized = path.startsWith('asset:///')
        ? path.replaceFirst('asset:///', '')
        : path;
    final String lower = normalized.toLowerCase();
    if (lower.startsWith('assets/') || lower.startsWith('packages/')) {
      return normalized;
    }
    return 'Assets/$normalized';
  }

  Future<String?> _resolveGameAssetPath(String resolvedAssetPath) async {
    if (!GamePathResolver.shouldUseFileSystemAssets) {
      return null;
    }

    final String? gamePath = await GamePathResolver.resolveGamePath();
    if (gamePath == null || gamePath.isEmpty) {
      return null;
    }

    return p.normalize(p.join(gamePath, resolvedAssetPath));
  }

  bool _isNetworkPath(String path) {
    return path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('rtsp://') ||
        path.startsWith('rtmp://');
  }

  bool _isExpectedInterruptionError(Object error) {
    final String message = error.toString().toLowerCase();
    return message.contains('loading interrupted') ||
        message.contains('player interrupted');
  }
}
