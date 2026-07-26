import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:collection';

import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/cg_cache_storage.dart';
import 'package:sakiengine/src/utils/character_layer_parser.dart';
import 'package:sakiengine/src/utils/image_loader.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';
import 'package:sakiengine/src/native/native_image_metadata.dart';

/// CG图像合成器 - 负责将多层图像合成为单张图像并将结果保存到磁盘缓存
class CgImageCompositor {
  static final CgImageCompositor _instance = CgImageCompositor._internal();
  factory CgImageCompositor() => _instance;
  CgImageCompositor._internal();

  /// 磁盘缓存映射：缓存键 -> 合成图像的磁盘路径
  final Map<String, String> _diskPathCache = {};
  final Map<String, String> _memoryPathCache = {};
  final LinkedHashMap<String, Uint8List> _memoryBytesCache = LinkedHashMap();

  /// 正在合成的任务，避免重复合成
  final Map<String, Future<String?>> _compositingTasks = {};

  static const bool _preferMemoryCache = bool.fromEnvironment(
    'SAKI_CG_MEMORY_CACHE',
    defaultValue: true,
  );
  static const bool _enableDiskFallback = bool.fromEnvironment(
    'SAKI_CG_DISK_CACHE_FALLBACK',
    defaultValue: false,
  );
  static const int _maxMemoryEntries = 180;
  static const int _maxMemoryBytes =
      int.fromEnvironment('SAKI_CG_MEMORY_CACHE_MB', defaultValue: 64) *
      1024 *
      1024;
  int _memoryBytes = 0;
  bool _loggedNativeImageMetadata = false;

  /// 生成缓存键
  String _generateCacheKey(String resourceId, String pose, String expression) {
    return '${resourceId}_${pose}_$expression';
  }

  String _generateMemoryPath(String cacheKey) {
    return '/memory_cache/cg_cache/$cacheKey.png';
  }

  /// 获取或生成合成CG图像的路径（磁盘路径）
  Future<String?> getCompositeImagePath({
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    final cacheKey = _generateCacheKey(resourceId, pose, expression);

    final memoryPath = _memoryPathCache[cacheKey];
    if (memoryPath != null && _memoryBytesCache.containsKey(cacheKey)) {
      return memoryPath;
    }

    // 磁盘缓存命中
    final cachedPath = _diskPathCache[cacheKey];
    if (cachedPath != null) {
      final file = File(cachedPath);
      if (await file.exists()) {
        return cachedPath;
      }
      _diskPathCache.remove(cacheKey);
    }

    // 检查是否正在合成
    if (_compositingTasks.containsKey(cacheKey)) {
      return await _compositingTasks[cacheKey];
    }

    // 开始新的合成任务
    final compositeTask = _performComposition(
      resourceId,
      pose,
      expression,
      cacheKey,
    );
    _compositingTasks[cacheKey] = compositeTask;

    try {
      return await compositeTask;
    } finally {
      _compositingTasks.remove(cacheKey);
    }
  }

  /// 根据磁盘路径或缓存键读取图像字节
  Uint8List? getImageBytes(String pathOrKey) {
    final memoryBytes = _resolveMemoryBytes(pathOrKey);
    if (memoryBytes != null) {
      return memoryBytes;
    }

    final resolvedPath = _resolveDiskPath(pathOrKey);
    if (resolvedPath == null) {
      return null;
    }

    try {
      final file = File(resolvedPath);
      if (!file.existsSync()) {
        return null;
      }
      return file.readAsBytesSync();
    } catch (e) {
      if (kEngineDebugMode) {
        print('[CgImageCompositor] Failed to read cache file: $e');
      }
      return null;
    }
  }

  /// 判断给定路径是否为CG磁盘缓存路径
  bool isCachePath(String path) {
    return path.startsWith('/memory_cache/cg_cache/') ||
        CgCacheStorage().isCachePath(path);
  }

  /// 实际执行合成逻辑
  Future<String?> _performComposition(
    String resourceId,
    String pose,
    String expression,
    String cacheKey,
  ) async {
    try {
      if (kIsWeb) {
        if (kEngineDebugMode) {
          print(
            '[CgImageCompositor] Skip CPU composition on Web for $cacheKey',
          );
        }
        return null;
      }

      // 解析角色图层
      final layerInfos = await CharacterLayerParser.parseCharacterLayers(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );

      if (layerInfos.isEmpty) {
        return null;
      }

      final layerPaths = <String>[];
      for (final layerInfo in layerInfos) {
        final path = await AssetManager().findAsset(layerInfo.assetName);
        if (path == null) {
          return null;
        }
        layerPaths.add(path);
      }

      final physicalPaths = layerPaths
          .where(
            (path) =>
                path.startsWith('/') || (path.length > 2 && path[1] == ':'),
          )
          .toList(growable: false);
      final metadata = await inspectImagesNatively(physicalPaths);
      if (kEngineDebugMode &&
          !_loggedNativeImageMetadata &&
          metadata != null &&
          metadata.isNotEmpty) {
        _loggedNativeImageMetadata = true;
        final decodedBytes = metadata.fold<int>(
          0,
          (sum, image) => sum + image.decodedRgbaBytes,
        );
        print(
          '[SAKI_NATIVE][IMAGE] layers=${metadata.length} '
          'decodedEstimate=${decodedBytes}B',
        );
      }

      // 加载所有图层图像
      final layerImages = <ui.Image>[];
      for (final layerPath in layerPaths) {
        final image = await ImageLoader.loadImage(layerPath);
        if (image == null) {
          for (final loaded in layerImages) {
            loaded.dispose();
          }
          return null;
        }
        layerImages.add(image);
      }

      if (layerImages.isEmpty) {
        return null;
      }

      // 合成图像
      final compositeImage = await _compositeImages(layerImages);
      if (compositeImage == null) {
        for (final image in layerImages) {
          image.dispose();
        }
        return null;
      }

      String? savedPath;
      if (_preferMemoryCache) {
        savedPath = await _saveCompositeToMemory(compositeImage, cacheKey);
        if (_enableDiskFallback) {
          final diskPath = await _saveCompositeToDisk(compositeImage, cacheKey);
          if (diskPath != null) {
            _diskPathCache[cacheKey] = diskPath;
          }
        }
      } else {
        savedPath = await _saveCompositeToDisk(compositeImage, cacheKey);
      }

      // 清理资源
      for (final image in layerImages) {
        image.dispose();
      }
      compositeImage.dispose();

      if (savedPath != null && !savedPath.startsWith('/memory_cache/')) {
        _diskPathCache[cacheKey] = savedPath;
      }

      return savedPath;
    } catch (e) {
      if (kEngineDebugMode) {
        print('[CgImageCompositor] Composition failed: $e');
      }
      return null;
    }
  }

  /// 合成多个图层为单张图像
  Future<ui.Image?> _compositeImages(List<ui.Image> layerImages) async {
    try {
      if (layerImages.isEmpty) return null;

      final baseImage = layerImages.first;
      final canvasWidth = baseImage.width;
      final canvasHeight = baseImage.height;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final canvasRect = ui.Rect.fromLTWH(
        0,
        0,
        canvasWidth.toDouble(),
        canvasHeight.toDouble(),
      );

      for (final image in layerImages) {
        final paint = ui.Paint()
          ..isAntiAlias = true
          ..filterQuality = ImageSamplingManager().resolveCanvasFilterQuality(
            defaultQuality: ui.FilterQuality.high,
          );
        final srcRect = ui.Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        );
        canvas.drawImageRect(image, srcRect, canvasRect, paint);
      }

      final picture = recorder.endRecording();
      final compositeImage = await picture.toImage(canvasWidth, canvasHeight);
      picture.dispose();

      return compositeImage;
    } catch (e) {
      return null;
    }
  }

  Future<String?> _saveCompositeToMemory(
    ui.Image image,
    String cacheKey,
  ) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        return null;
      }

      final bytes = Uint8List.fromList(byteData.buffer.asUint8List());
      _cacheMemoryBytes(cacheKey, bytes);
      final memoryPath = _generateMemoryPath(cacheKey);
      _memoryPathCache[cacheKey] = memoryPath;
      return memoryPath;
    } catch (e) {
      if (kEngineDebugMode) {
        print(
          '[CgImageCompositor] Failed to save composite image in memory: $e',
        );
      }
      return null;
    }
  }

  /// 保存合成图像到磁盘
  Future<String?> _saveCompositeToDisk(ui.Image image, String cacheKey) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        return null;
      }

      final bytes = byteData.buffer.asUint8List();
      final file = await CgCacheStorage().fileForKey(cacheKey);
      if (file == null) {
        return null;
      }

      await file.writeAsBytes(bytes, flush: false);
      await CgCacheStorage().pruneIfNeeded();

      if (kEngineDebugMode) {
        print(
          '[CgImageCompositor] Disk cache saved: $cacheKey (${bytes.length} bytes)',
        );
      }

      return file.path;
    } catch (e) {
      if (kEngineDebugMode) {
        print('[CgImageCompositor] Failed to save composite image: $e');
      }
      return null;
    }
  }

  /// 清理缓存
  Future<void> clearCache() async {
    try {
      _diskPathCache.clear();
      _memoryPathCache.clear();
      _memoryBytesCache.clear();
      _memoryBytes = 0;
      _compositingTasks.clear();
      await CgCacheStorage().clear();

      if (kEngineDebugMode) {
        print('[CgImageCompositor] Disk cache cleared');
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('[CgImageCompositor] Failed to clear cache: $e');
      }
    }
  }

  /// 获取缓存统计信息
  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      final stats = await CgCacheStorage().collectStats();
      stats['disk_index'] = _diskPathCache.length;
      stats['memory_index'] = _memoryBytesCache.length;
      stats['memory_bytes'] = _memoryBytes;
      stats['memory_limit_bytes'] = _maxMemoryBytes;
      stats['prefer_memory_cache'] = _preferMemoryCache;
      stats['disk_fallback_enabled'] = _enableDiskFallback;
      stats['compositing_tasks'] = _compositingTasks.length;
      return stats;
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  String? _resolveDiskPath(String pathOrKey) {
    if (pathOrKey.isEmpty) {
      return null;
    }

    if (_diskPathCache.containsKey(pathOrKey)) {
      return _diskPathCache[pathOrKey];
    }

    if (_diskPathCache.containsValue(pathOrKey)) {
      return pathOrKey;
    }

    if (pathOrKey.contains('/memory_cache/cg_cache/')) {
      final filename = pathOrKey.split('/').last;
      final cacheKey = filename.replaceAll('.png', '');
      return _diskPathCache[cacheKey];
    }

    final file = File(pathOrKey);
    if (file.existsSync()) {
      return pathOrKey;
    }

    return null;
  }

  Uint8List? _resolveMemoryBytes(String pathOrKey) {
    if (pathOrKey.isEmpty) {
      return null;
    }

    if (_memoryBytesCache.containsKey(pathOrKey)) {
      final bytes = _memoryBytesCache.remove(pathOrKey)!;
      _memoryBytesCache[pathOrKey] = bytes;
      return bytes;
    }

    if (_memoryPathCache.containsKey(pathOrKey)) {
      final cacheKey = pathOrKey;
      final bytes = _memoryBytesCache.remove(cacheKey);
      if (bytes == null) return null;
      _memoryBytesCache[cacheKey] = bytes;
      return bytes;
    }

    if (pathOrKey.startsWith('/memory_cache/cg_cache/')) {
      final cacheKey = pathOrKey.split('/').last.replaceAll('.png', '');
      final bytes = _memoryBytesCache.remove(cacheKey);
      if (bytes == null) return null;
      _memoryBytesCache[cacheKey] = bytes;
      return bytes;
    }

    return null;
  }

  void _cacheMemoryBytes(String cacheKey, Uint8List bytes) {
    final replaced = _memoryBytesCache.remove(cacheKey);
    if (replaced != null) {
      _memoryBytes -= replaced.length;
    }
    _memoryBytesCache[cacheKey] = bytes;
    _memoryBytes += bytes.length;

    while (_memoryBytesCache.length > _maxMemoryEntries ||
        (_memoryBytes > _maxMemoryBytes && _memoryBytesCache.length > 1)) {
      final oldestKey = _memoryBytesCache.keys.first;
      final removed = _memoryBytesCache.remove(oldestKey);
      if (removed != null) {
        _memoryBytes -= removed.length;
      }
      _memoryPathCache.remove(oldestKey);
    }
  }
}
