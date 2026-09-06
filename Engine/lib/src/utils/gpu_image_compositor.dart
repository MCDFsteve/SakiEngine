import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/character_layer_parser.dart';
import 'package:sakiengine/src/utils/image_loader.dart';

/// GPU 合成结果，包含所有需要在 GPU 上绘制的图层
class GpuCompositeResult {
  GpuCompositeResult({
    required List<_LayerHandle> handles,
    required this.width,
    required this.height,
    required void Function(String cacheKey) releaseLayer,
  })  : _handles = handles,
        _releaseLayer = releaseLayer,
        layers = UnmodifiableListView<ui.Image>(
          handles.map((handle) => handle.image).toList(growable: false),
        );

  final List<_LayerHandle> _handles;
  final void Function(String cacheKey) _releaseLayer;

  /// 参与绘制的所有图层（已经解码为 GPU 纹理）
  final UnmodifiableListView<ui.Image> layers;

  /// 合成画布宽度（像素）
  final int width;

  /// 合成画布高度（像素）
  final int height;

  bool _disposed = false;

  /// 解码后的纹理字节估算。用于按真实 GPU/物理内存规模限制缓存，
  /// 而不是只按“有多少个 CG”限制。
  int get estimatedDecodedBytes => layers.fold<int>(
        0,
        (total, image) => total + image.width * image.height * 4,
      );

  /// 释放所有图层资源（减少引用计数，必要时真正释放纹理）
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final handle in _handles) {
      _releaseLayer(handle.cacheKey);
    }
    // `_handles` is intentionally created with `growable: false`. Clearing it
    // throws during LRU eviction; retaining this short-lived list is harmless
    // once the result itself is removed from every cache.
  }
}

/// GPU 合成条目，包含缓存键、虚拟路径以及合成结果
class GpuCompositeEntry {
  const GpuCompositeEntry({
    required this.cacheKey,
    required this.virtualPath,
    required this.result,
  });

  final String cacheKey;
  final String virtualPath;
  final GpuCompositeResult result;
}

class _LayerHandle {
  _LayerHandle({required this.cacheKey, required this.image});

  final String cacheKey;
  final ui.Image image;
}

class _LayerCacheEntry {
  _LayerCacheEntry({required this.image});

  final ui.Image image;
  int refCount = 0;
}

/// GPU加速图像合成器
///
/// 主要优化：
/// 1. 使用GPU Fragment Shader进行图像混合
/// 2. 批量处理多张图像
/// 3. 异步并行解码
/// 4. 智能内存管理
class GpuImageCompositor {
  static final GpuImageCompositor _instance = GpuImageCompositor._internal();
  factory GpuImageCompositor() => _instance;
  GpuImageCompositor._internal();

  /// 内存缓存
  final Map<String, GpuCompositeEntry> _entryCache =
      <String, GpuCompositeEntry>{};
  final Map<String, String> _pathToCacheKey = <String, String>{};
  final Map<String, Future<GpuCompositeEntry?>> _compositingTasks =
      <String, Future<GpuCompositeEntry?>>{};

  final Map<String, _LayerCacheEntry> _layerCache =
      <String, _LayerCacheEntry>{};
  final Map<String, Future<_LayerHandle?>> _layerLoadTasks =
      <String, Future<_LayerHandle?>>{};
  int _decodedLayerBytes = 0;
  int _cacheGeneration = 0;

  /// GPU加速可用性检查
  bool _gpuAvailable = false;
  bool _checkedGpuAvailability = false;

  /// 检查GPU加速可用性
  Future<void> _checkGpuAvailability() async {
    if (_checkedGpuAvailability) return;

    try {
      // 简单的GPU可用性检测
      _gpuAvailable = true; // 默认启用优化合成模式
      _checkedGpuAvailability = true;
    } catch (e) {
      _gpuAvailable = false;
      _checkedGpuAvailability = true;
    }
  }

  /// 生成缓存键
  String _generateCacheKey(String resourceId, String pose, String expression) {
    return '${resourceId}_${pose}_$expression';
  }

  /// 生成虚拟缓存路径
  String _generateVirtualPath(String cacheKey) {
    return '/gpu_cache/cg_cache/$cacheKey.png';
  }

  /// 获取合成图像路径（主接口）
  Future<String?> getCompositeImagePath({
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    final entry = await _getOrCreateEntry(
      resourceId: resourceId,
      pose: pose,
      expression: expression,
    );

    return entry?.virtualPath;
  }

  /// 获取 GPU 合成结果（仅包含内存中的图层数据）
  Future<GpuCompositeResult?> getCompositeResult({
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    final entry = await _getOrCreateEntry(
      resourceId: resourceId,
      pose: pose,
      expression: expression,
    );
    return entry?.result;
  }

  /// 获取完整的合成条目（带虚拟路径）
  Future<GpuCompositeEntry?> getCompositeEntry({
    required String resourceId,
    required String pose,
    required String expression,
  }) {
    return _getOrCreateEntry(
      resourceId: resourceId,
      pose: pose,
      expression: expression,
    );
  }

  /// 读取已缓存的 GPU 合成结果
  GpuCompositeResult? getCachedResult(String keyOrPath) {
    final cacheKey = keyOrPath.startsWith('/gpu_cache/')
        ? _pathToCacheKey[keyOrPath]
        : keyOrPath;
    if (cacheKey == null) return null;
    return _entryCache[cacheKey]?.result;
  }

  /// 获取（或创建）完整的合成条目
  Future<GpuCompositeEntry?> _getOrCreateEntry({
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    final cacheKey = _generateCacheKey(resourceId, pose, expression);

    // 命中缓存
    final cachedEntry = _entryCache[cacheKey];
    if (cachedEntry != null) {
      return cachedEntry;
    }

    // 是否已有并发任务
    final existingTask = _compositingTasks[cacheKey];
    if (existingTask != null) {
      return await existingTask;
    }

    final compositionTask = _performOptimizedComposition(
      resourceId,
      pose,
      expression,
      cacheKey,
      _cacheGeneration,
    );
    _compositingTasks[cacheKey] = compositionTask;

    try {
      final entry = await compositionTask;
      return entry;
    } finally {
      if (identical(_compositingTasks[cacheKey], compositionTask)) {
        _compositingTasks.remove(cacheKey);
      }
    }
  }

  /// 批量GPU合成（性能优化核心）
  Future<List<String?>> batchCompose(List<Map<String, String>> requests) async {
    await _checkGpuAvailability();

    try {
      final tasks = requests.map((request) {
        final resourceId = request['resourceId']!;
        final pose = request['pose'] ?? 'pose1';
        final expression = request['expression'] ?? 'happy';
        return _getOrCreateEntry(
          resourceId: resourceId,
          pose: pose,
          expression: expression,
        );
      }).toList();

      final entries = await Future.wait(tasks, eagerError: false);

      return entries.map((entry) => entry?.virtualPath).toList();
    } catch (_) {
      return List<String?>.filled(requests.length, null);
    }
  }

  /// 执行优化合成，准备 GPU 渲染所需的图层
  Future<GpuCompositeEntry?> _performOptimizedComposition(
    String resourceId,
    String pose,
    String expression,
    String cacheKey,
    int generation,
  ) async {
    try {
      await _checkGpuAvailability();
      if (generation != _cacheGeneration) {
        return null;
      }

      // 解析图层信息
      final layerInfos = await CharacterLayerParser.parseCharacterLayers(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );
      if (layerInfos.isEmpty) return null;

      // 并行加载所有图层，并使用缓存避免重复解码
      final layerLoadTasks = layerInfos
          .map(
            (layerInfo) =>
                _loadLayerImageAsync(layerInfo.assetName, generation),
          )
          .toList();

      final layerHandles = await Future.wait(layerLoadTasks);
      final validHandles = layerHandles.whereType<_LayerHandle>().toList(
            growable: false,
          );

      if (validHandles.isEmpty) {
        return null;
      }
      if (generation != _cacheGeneration) {
        for (final handle in validHandles) {
          _releaseLayer(handle.cacheKey);
        }
        return null;
      }

      final width = validHandles.first.image.width;
      final height = validHandles.first.image.height;

      final result = GpuCompositeResult(
        handles: validHandles,
        width: width,
        height: height,
        releaseLayer: _releaseLayer,
      );

      final virtualPath = _generateVirtualPath(cacheKey);
      final entry = GpuCompositeEntry(
        cacheKey: cacheKey,
        virtualPath: virtualPath,
        result: result,
      );

      _entryCache[cacheKey] = entry;
      _pathToCacheKey[virtualPath] = cacheKey;

      return entry;
    } catch (_) {
      return null;
    }
  }

  /// 异步加载图层图像
  Future<_LayerHandle?> _loadLayerImageAsync(
    String assetName,
    int generation,
  ) async {
    if (generation != _cacheGeneration) {
      return null;
    }

    // 命中缓存
    final cached = _layerCache[assetName];
    if (cached != null) {
      return _retainLayer(assetName);
    }

    // 等待正在进行的加载任务
    final existingTask = _layerLoadTasks[assetName];
    if (existingTask != null) {
      final handle = await existingTask;
      if (handle == null || generation != _cacheGeneration) {
        return null;
      }
      return _retainLayer(assetName);
    }

    final loadTask = _loadLayerImageInternal(assetName, generation);
    _layerLoadTasks[assetName] = loadTask;

    try {
      return await loadTask;
    } finally {
      if (identical(_layerLoadTasks[assetName], loadTask)) {
        _layerLoadTasks.remove(assetName);
      }
    }
  }

  Future<_LayerHandle?> _loadLayerImageInternal(
    String assetName,
    int generation,
  ) async {
    try {
      final assetPath = await AssetManager().findAsset(assetName);
      if (assetPath == null || generation != _cacheGeneration) return null;

      final image = await ImageLoader.loadImage(assetPath);
      if (image == null) return null;
      if (generation != _cacheGeneration) {
        image.dispose();
        return null;
      }

      final cacheEntry = _LayerCacheEntry(image: image)..refCount = 1;
      _layerCache[assetName] = cacheEntry;
      _decodedLayerBytes += image.width * image.height * 4;
      return _LayerHandle(cacheKey: assetName, image: image);
    } catch (e) {
      return null;
    }
  }

  void _releaseLayer(String cacheKey) {
    final entry = _layerCache[cacheKey];
    if (entry == null) {
      return;
    }

    entry.refCount -= 1;
    if (entry.refCount <= 0) {
      _decodedLayerBytes -= entry.image.width * entry.image.height * 4;
      entry.image.dispose();
      _layerCache.remove(cacheKey);
    }
  }

  _LayerHandle? _retainLayer(String cacheKey) {
    final entry = _layerCache[cacheKey];
    if (entry == null) return null;
    entry.refCount += 1;
    return _LayerHandle(cacheKey: cacheKey, image: entry.image);
  }

  /// 获取缓存图像字节
  Uint8List? getImageBytes(String pathOrKey) {
    // GPU 渲染路径不再返回 CPU 合成的二进制数据
    return null;
  }

  /// 删除单个合成条目。由上层 LRU 在确认该条目不再显示时调用。
  bool removeEntry(String cacheKey) {
    final entry = _entryCache.remove(cacheKey);
    if (entry == null) {
      return false;
    }
    _pathToCacheKey.remove(entry.virtualPath);
    entry.result.dispose();
    return true;
  }

  /// 清理缓存
  Future<void> clearCache() async {
    _cacheGeneration++;
    for (final entry in _entryCache.values) {
      entry.result.dispose();
    }
    _entryCache.clear();
    _pathToCacheKey.clear();
    _compositingTasks.clear();
    _layerLoadTasks.clear();

    if (_layerCache.isNotEmpty) {
      for (final cacheEntry in _layerCache.values) {
        cacheEntry.image.dispose();
      }
      _layerCache.clear();
    }
    _decodedLayerBytes = 0;
  }

  /// 获取缓存统计
  Map<String, dynamic> getCacheStats() {
    final totalLayers = _entryCache.values.fold<int>(
      0,
      (previousValue, entry) => previousValue + entry.result.layers.length,
    );

    return {
      'cache_type': 'gpu_layers',
      'gpu_available': _gpuAvailable,
      'cached_entries': _entryCache.length,
      'total_layers': totalLayers,
      'unique_layers': _layerCache.length,
      'decoded_layer_bytes': _decodedLayerBytes,
      'active_tasks': _compositingTasks.length,
    };
  }

  /// 预热优化器（可选调用）
  Future<void> warmUpGpu() async {
    await _checkGpuAvailability();
  }
}
