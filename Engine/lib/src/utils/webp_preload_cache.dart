import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/config/asset_manager.dart';

/// WebP动图预加载缓存
class WebPPreloadCache {
  static final WebPPreloadCache _instance = WebPPreloadCache._internal();
  factory WebPPreloadCache() => _instance;
  WebPPreloadCache._internal();
  static const bool _memoryLifecycleDiagnostics = bool.fromEnvironment(
    'SAKI_MEMORY_DIAG',
    defaultValue: false,
  );

  final LinkedHashMap<String, _WebPCacheEntry> _entries = LinkedHashMap();
  final Map<String, Duration> _durationCache = {};
  final Map<String, Completer<void>> _loadingCompleters = {};
  static const int _maxAssets = int.fromEnvironment(
    'SAKI_WEBP_CACHE_ASSETS',
    defaultValue: 8,
  );
  static const int _maxDecodedBytes =
      int.fromEnvironment('SAKI_WEBP_CACHE_MB', defaultValue: 128) *
          1024 *
          1024;
  static const int _maxSingleAssetDecodedBytes =
      int.fromEnvironment('SAKI_WEBP_CACHE_ASSET_MB', defaultValue: 64) *
          1024 *
          1024;
  int _decodedBytes = 0;
  int _cacheGeneration = 0;

  Future<void> preloadWebP(String assetName) async {
    if (_entries.containsKey(assetName) ||
        _loadingCompleters.containsKey(assetName)) {
      return;
    }

    final completer = Completer<void>();
    _loadingCompleters[assetName] = completer;
    final generation = _cacheGeneration;

    try {
      final assetPath = await AssetManager().findAsset(assetName);
      if (assetPath == null) {
        if (kEngineDebugMode) {
          print('[WebPPreloadCache] 资源不存在: $assetName');
        }
        completer.complete();
        _loadingCompleters.remove(assetName);
        return;
      }

      final bytes = await _loadWebPBytes(assetPath);
      if (bytes == null) {
        if (kEngineDebugMode) {
          print('[WebPPreloadCache] 加载字节失败: $assetName');
        }
        completer.complete();
        _loadingCompleters.remove(assetName);
        return;
      }

      final codec = await ui.instantiateImageCodec(bytes);
      final frameCount = codec.frameCount;
      final frames = <ui.Image>[];
      var cacheOwnsFrames = false;
      try {
        final firstFrame = await codec.getNextFrame();
        frames.add(firstFrame.image);
        var totalDuration = firstFrame.duration;
        final estimatedAssetBytes =
            firstFrame.image.width * firstFrame.image.height * 4 * frameCount;

        // 大型动画应由显示控件按需持有，不能在进入游戏时把所有帧
        // 永久塞进全局缓存。以 1920x1080 为例，26 帧约 206 MiB。
        if (estimatedAssetBytes > _maxSingleAssetDecodedBytes ||
            estimatedAssetBytes > _maxDecodedBytes ||
            generation != _cacheGeneration) {
          if (_memoryLifecycleDiagnostics &&
              generation == _cacheGeneration) {
            print(
              '[SAKI_MEMORY][WEBP] skip oversized preload '
              'asset=$assetName frames=$frameCount '
              'decodedEstimate=${estimatedAssetBytes}B',
            );
          }
          return;
        }

        for (int i = 1; i < frameCount; i++) {
          if (generation != _cacheGeneration) {
            return;
          }
          final frame = await codec.getNextFrame();
          frames.add(frame.image);
          totalDuration += frame.duration;
        }

        if (generation != _cacheGeneration) {
          return;
        }
        _store(
          assetName,
          frames,
          frameCount > 1 ? totalDuration : const Duration(milliseconds: 100),
        );
        cacheOwnsFrames = true;
      } finally {
        codec.dispose();
        if (!cacheOwnsFrames) {
          _disposeFrames(frames);
        }
      }

      completer.complete();
    } catch (e) {
      if (kEngineDebugMode) {
        print('[WebPPreloadCache] 预加载失败 $assetName: $e');
      }
      completer.completeError(e);
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      _loadingCompleters.remove(assetName);
    }
  }

  List<ui.Image>? getCachedFrames(String assetName) {
    final entry = _touch(assetName);
    return entry?.frames;
  }

  Duration? getCachedDuration(String assetName) {
    return _durationCache[assetName];
  }

  bool isCached(String assetName) {
    return _entries.containsKey(assetName);
  }

  bool isLoading(String assetName) {
    return _loadingCompleters.containsKey(assetName);
  }

  Future<void> waitForLoad(String assetName) async {
    final completer = _loadingCompleters[assetName];
    if (completer != null) {
      await completer.future;
    }
  }

  void clearCache([String? assetName]) {
    if (assetName != null) {
      final entry = _entries.remove(assetName);
      if (entry != null) {
        _decodedBytes -= entry.decodedBytes;
        _disposeEntry(entry);
      }
      _durationCache.remove(assetName);
    } else {
      _cacheGeneration++;
      for (final entry in _entries.values) {
        _disposeEntry(entry);
      }
      _entries.clear();
      _durationCache.clear();
      _decodedBytes = 0;
    }
  }

  WebPFrameLease? acquire(String assetName) {
    final entry = _touch(assetName);
    if (entry == null) {
      return null;
    }
    entry.references++;
    return WebPFrameLease._(
      frames: entry.frames,
      duration: entry.duration,
      release: () => _release(assetName, entry),
    );
  }

  Map<String, int> get stats => {
        'assets': _entries.length,
        'decodedBytes': _decodedBytes,
        'maxDecodedBytes': _maxDecodedBytes,
        'maxSingleAssetDecodedBytes': _maxSingleAssetDecodedBytes,
      };

  _WebPCacheEntry? _touch(String assetName) {
    final entry = _entries.remove(assetName);
    if (entry != null) {
      _entries[assetName] = entry;
    }
    return entry;
  }

  void _store(String assetName, List<ui.Image> frames, Duration duration) {
    final replaced = _entries.remove(assetName);
    if (replaced != null) {
      _decodedBytes -= replaced.decodedBytes;
      _disposeEntry(replaced);
    }
    final entry = _WebPCacheEntry(frames, duration);
    _entries[assetName] = entry;
    _durationCache[assetName] = duration;
    _decodedBytes += entry.decodedBytes;
    _prune();
  }

  void _release(String assetName, _WebPCacheEntry expected) {
    if (expected.references > 0) {
      expected.references--;
    }
    if (expected.pendingDispose && expected.references == 0) {
      _disposeFrames(expected.frames);
    }
    _prune();
  }

  void _prune() {
    while (_entries.length > _maxAssets ||
        (_decodedBytes > _maxDecodedBytes && _entries.length > 1)) {
      final oldestKey = _entries.keys.firstWhere(
        (key) => _entries[key]!.references == 0,
        orElse: () => '',
      );
      if (oldestKey.isEmpty) {
        return;
      }
      final removed = _entries.remove(oldestKey)!;
      _durationCache.remove(oldestKey);
      _decodedBytes -= removed.decodedBytes;
      _disposeEntry(removed);
    }
  }

  void _disposeEntry(_WebPCacheEntry entry) {
    if (entry.references == 0) {
      _disposeFrames(entry.frames);
    } else {
      entry.pendingDispose = true;
    }
  }

  void _disposeFrames(List<ui.Image> frames) {
    for (final frame in frames) {
      frame.dispose();
    }
  }

  Future<String> _getGamePath() async {
    if (!GamePathResolver.shouldUseFileSystemAssets) {
      return '';
    }
    return (await GamePathResolver.resolveGamePath()) ?? '';
  }

  Future<Uint8List?> _loadWebPBytes(String assetPath) async {
    try {
      if (GamePathResolver.shouldUseFileSystemAssets) {
        final gamePath = await _getGamePath();
        if (gamePath.isNotEmpty) {
          final relativePath = assetPath.startsWith('assets/')
              ? assetPath.substring('assets/'.length)
              : assetPath;
          final fileSystemPath = p.normalize(p.join(gamePath, relativePath));
          final file = File(fileSystemPath);

          if (await file.exists()) {
            return await file.readAsBytes();
          }
        }
      }

      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List();
    } catch (e) {
      return null;
    }
  }
}

class WebPFrameLease {
  WebPFrameLease._({
    required this.frames,
    required this.duration,
    required void Function() release,
  }) : _release = release;

  final List<ui.Image> frames;
  final Duration duration;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _release();
  }
}

class _WebPCacheEntry {
  _WebPCacheEntry(this.frames, this.duration)
      : decodedBytes = frames.fold<int>(
          0,
          (sum, image) => sum + image.width * image.height * 4,
        );

  final List<ui.Image> frames;
  final Duration duration;
  final int decodedBytes;
  int references = 0;
  bool pendingDispose = false;
}
