/// 高性能层叠图像渲染器
///
/// 基于Ren'Py的渲染理念，实现实时层叠渲染而非预合成方式
/// 核心目标：快进时保持60FPS+，CG切换延迟<1ms
library layered_image_renderer;

import 'dart:async';
import 'dart:ui' as ui;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/rendering/layered/layer_types.dart';
import 'package:sakiengine/src/rendering/layered/smart_layer_cache.dart';
import 'package:sakiengine/src/utils/character_layer_parser.dart';
import 'package:sakiengine/src/config/asset_manager.dart';

/// 层叠图像渲染器
///
/// 核心职责：
/// - 管理多个图层的实时渲染
/// - 智能图层切换和缓存
/// - 性能监控和优化
/// - 支持动画和过渡效果
class LayeredImageRenderer {
  static final LayeredImageRenderer _instance =
      LayeredImageRenderer._internal();
  factory LayeredImageRenderer() => _instance;
  LayeredImageRenderer._internal();

  /// 智能缓存管理器
  final SmartLayerCache _cache = SmartLayerCache();

  /// 当前激活的层叠图像状态
  final Map<String, LayeredImageState> _activeImages =
      <String, LayeredImageState>{};

  /// 图层变化监听器
  final List<StreamController<LayerChangeEvent>> _changeControllers = [];

  /// 性能统计
  final List<double> _renderTimes = [];
  DateTime _lastStatsUpdate = DateTime.now();
  int _frameCount = 0;

  /// 渲染配置
  static const Duration _transitionDuration = Duration(milliseconds: 200);
  static const int _maxRenderTimeHistory = 60; // 保留最近60帧的渲染时间

  /// 创建层叠图像状态
  ///
  /// [resourceId] 资源ID（如角色名）
  /// [pose] 姿势
  /// [expression] 表情
  /// [attributes] 额外属性集合
  Future<LayeredImageState?> createLayeredImage({
    required String resourceId,
    required String pose,
    required String expression,
    Set<String>? attributes,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      // 生成唯一的图像ID
      final imageId = '${resourceId}_${pose}_$expression';

      // 解析图层信息
      final layerInfos = await CharacterLayerParser.parseCharacterLayers(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );

      if (layerInfos.isEmpty) {
        if (kEngineDebugMode) {
          print('[LayeredImageRenderer] No layers found for: $imageId');
        }
        return null;
      }

      // 转换为LayerInfo对象
      final layers = <LayerInfo>[];
      int zOrder = 0;

      for (final layerInfo in layerInfos) {
        final layer = LayerInfo(
          layerId: '${imageId}_layer_$zOrder',
          type: _getLayerTypeFromAssetName(layerInfo.assetName),
          assetPath: layerInfo.assetName,
          zOrder: zOrder++,
          visible: true,
          opacity: 1.0,
        );
        layers.add(layer);
      }

      // 创建状态
      final state = LayeredImageState(
        imageId: imageId,
        layers: layers,
        activeAttributes: attributes ?? {pose, expression},
      );

      // 预热缓存
      unawaited(_preloadLayerTextures(state));

      // 缓存状态
      _activeImages[imageId] = state;

      if (kEngineDebugMode) {
        print(
            '[LayeredImageRenderer] Created layered image: $imageId (${layers.length} layers)');
      }

      return state;
    } finally {
      stopwatch.stop();
      _recordRenderTime(stopwatch.elapsedMicroseconds / 1000.0);
    }
  }

  /// 更新层叠图像（快速切换表情等）
  ///
  /// 这是性能关键方法，必须保证微秒级响应
  Future<LayeredImageState?> updateLayeredImage({
    required String baseImageId, // 基础图像ID
    required String newExpression,
    Set<String>? newAttributes,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final currentState = _activeImages[baseImageId];
      if (currentState == null) {
        if (kEngineDebugMode) {
          print('[LayeredImageRenderer] Base image not found: $baseImageId');
        }
        return null;
      }

      // 解析新的图层信息（只处理变化的部分）
      final parts = baseImageId.split('_');
      if (parts.length < 4) {
        if (kEngineDebugMode) {
          print(
              '[LayeredImageRenderer] Invalid base image ID format: $baseImageId');
        }
        return null;
      }

      // 对于 "cg_cp1_5_pose1_1" 这样的ID：
      // parts[0] = "cg", parts[1] = "cp1", parts[2] = "5", parts[3] = "pose1", parts[4] = "1"
      // 实际的resourceId应该是 "cg_cp1_5"
      String resourceId;
      String pose;

      if (parts.length >= 5) {
        // 完整格式：cg_cp1_5_pose1_1
        resourceId = '${parts[0]}_${parts[1]}_${parts[2]}'; // "cg_cp1_5"
        pose = parts[3]; // "pose1"
      } else {
        if (kEngineDebugMode) {
          print('[LayeredImageRenderer] Unexpected ID format: $baseImageId');
        }
        return null;
      }

      final newImageId = '${resourceId}_${pose}_$newExpression';

      // 检查缓存
      if (_activeImages.containsKey(newImageId)) {
        if (kEngineDebugMode) {
          print(
              '[LayeredImageRenderer] Reusing cached layered image: $newImageId');
        }
        return _activeImages[newImageId]!;
      }

      // 快速路径：只更新表情层
      final newLayers = <LayerInfo>[];
      bool hasExpressionLayer = false;

      for (final layer in currentState.layers) {
        if (layer.type == LayerType.expression) {
          // 替换表情层 - 使用正确的资源路径格式
          // 从原有的资源路径中提取基础部分，然后替换表情
          String newAssetPath;
          if (layer.assetPath.contains('-')) {
            // 如果是差分格式（如 "cg_cp1_5-1"），替换差分部分
            final basePath = layer.assetPath.split('-')[0]; // "cg_cp1_5"
            newAssetPath = '$basePath-$newExpression'; // "cg_cp1_5-2"
          } else {
            // 如果不是差分格式，使用原有逻辑
            newAssetPath = '${resourceId}-$newExpression';
          }

          final newLayer = layer.copyWith(
            layerId: '${newImageId}_expression',
            assetPath: newAssetPath,
          );
          newLayers.add(newLayer);
          hasExpressionLayer = true;
        } else {
          // 保持其他图层不变
          newLayers.add(layer);
        }
      }

      // 如果没有表情层，添加一个
      if (!hasExpressionLayer) {
        final expressionLayer = LayerInfo(
          layerId: '${newImageId}_expression',
          type: LayerType.expression,
          assetPath: '${resourceId}-$newExpression', // 使用正确的差分格式
          zOrder: newLayers.length,
        );
        newLayers.add(expressionLayer);
      }

      // 创建新状态
      final newState = LayeredImageState(
        imageId: newImageId,
        layers: newLayers,
        activeAttributes: newAttributes ?? {pose, newExpression},
      );

      // 异步预热新图层
      unawaited(_preloadLayerTextures(newState));

      // 缓存新状态
      _activeImages[newImageId] = newState;

      // 发送变化事件
      _notifyLayerChanged(LayerChangeEvent(
        type: LayerChangeType.updated,
        layerId: newImageId,
        oldLayer: currentState.layers.first,
        newLayer: newState.layers.first,
      ));

      if (kEngineDebugMode) {
        print(
            '[LayeredImageRenderer] Fast updated layered image: $baseImageId -> $newImageId');
      }

      return newState;
    } finally {
      stopwatch.stop();
      _recordRenderTime(stopwatch.elapsedMicroseconds / 1000.0);
    }
  }

  /// 获取图层纹理列表
  ///
  /// 返回渲染所需的所有纹理，按Z顺序排序
  Future<List<ui.Image>> getLayerTextures(LayeredImageState state) async {
    final stopwatch = Stopwatch()..start();

    try {
      final textures = <ui.Image>[];
      final visibleLayers = state.visibleLayers;

      // 并行加载所有纹理
      final loadTasks = visibleLayers.map((layer) async {
        final texture = await _cache.getLayerTexture(layer.assetPath);
        return MapEntry(layer, texture);
      });

      final results = await Future.wait(loadTasks);

      // 按Z顺序组织纹理
      for (final result in results) {
        if (result.value != null) {
          textures.add(result.value!);
          result.key.updateAccessTime(); // 更新访问时间
        }
      }

      if (kEngineDebugMode && textures.length != visibleLayers.length) {
        print(
            '[LayeredImageRenderer] Warning: ${visibleLayers.length - textures.length} textures failed to load');
      }

      return textures;
    } finally {
      stopwatch.stop();
      _recordRenderTime(stopwatch.elapsedMicroseconds / 1000.0);
    }
  }

  /// 预加载图层纹理
  Future<void> _preloadLayerTextures(LayeredImageState state) async {
    try {
      // 预加载当前状态的所有图层
      final preloadTasks = state.visibleLayers
          .map((layer) => _cache.getLayerTexture(layer.assetPath));

      await Future.wait(preloadTasks);

      // 预测性预加载相关图层
      final parts = state.imageId.split('_');
      if (parts.length >= 5) {
        // 对于 "cg_cp1_5_pose1_1" 格式
        final resourceId = '${parts[0]}_${parts[1]}_${parts[2]}'; // "cg_cp1_5"
        final pose = parts[3]; // "pose1"
        final currentExpression = parts[4]; // "1"
        await _cache.preloadLayers(resourceId, pose,
            currentExpression: currentExpression);
      } else if (parts.length >= 3) {
        // 向后兼容旧格式
        final resourceId = parts[0];
        final pose = parts[1];
        await _cache.preloadLayers(resourceId, pose,
            currentExpression: parts[2]);
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('[LayeredImageRenderer] Preload failed: $e');
      }
    }
  }

  /// 获取图层类型（从资源名推断）
  LayerType _getLayerTypeFromAssetName(String assetName) {
    final lowerName = assetName.toLowerCase();

    if (lowerName.contains('bg') || lowerName.contains('background')) {
      return LayerType.background;
    } else if (lowerName.contains('expr') || lowerName.contains('face')) {
      return LayerType.expression;
    } else if (lowerName.contains('cloth') || lowerName.contains('outfit')) {
      return LayerType.clothing;
    } else if (lowerName.contains('hat') || lowerName.contains('glass')) {
      return LayerType.accessory;
    } else if (lowerName.contains('effect') || lowerName.contains('fx')) {
      return LayerType.effect;
    } else if (lowerName.contains('foreground') ||
        lowerName.contains('fg') ||
        lowerName.contains('front')) {
      return LayerType.foreground;
    } else {
      return LayerType.characterBase; // 默认为角色基础层
    }
  }

  /// 清理未使用的图像状态
  void cleanupUnusedImages(Duration maxAge) {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    for (final entry in _activeImages.entries) {
      if (now.difference(entry.value.createdAt) > maxAge) {
        keysToRemove.add(entry.key);
      }
    }

    for (final key in keysToRemove) {
      _activeImages.remove(key);
    }

    if (keysToRemove.isNotEmpty && kEngineDebugMode) {
      print(
          '[LayeredImageRenderer] Cleaned up ${keysToRemove.length} unused images');
    }

    // 同时清理缓存
    _cache.cleanupExpiredCache();
  }

  /// 监听图层变化
  Stream<LayerChangeEvent> get onLayerChanged {
    final controller = StreamController<LayerChangeEvent>.broadcast();
    _changeControllers.add(controller);
    return controller.stream;
  }

  /// 通知图层变化
  void _notifyLayerChanged(LayerChangeEvent event) {
    for (final controller in _changeControllers) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }
  }

  /// 记录渲染时间
  void _recordRenderTime(double timeMs) {
    _renderTimes.add(timeMs);
    _frameCount++;

    // 保持固定大小的历史记录
    if (_renderTimes.length > _maxRenderTimeHistory) {
      _renderTimes.removeAt(0);
    }
  }

  /// 获取性能统计
  LayeredRenderingStats getPerformanceStats() {
    final now = DateTime.now();
    final timeWindow = now.difference(_lastStatsUpdate);

    double averageRenderTime = 0.0;
    if (_renderTimes.isNotEmpty) {
      averageRenderTime =
          _renderTimes.reduce((a, b) => a + b) / _renderTimes.length;
    }

    final framesPerSecond = timeWindow.inMilliseconds > 0
        ? (_frameCount * 1000.0) / timeWindow.inMilliseconds
        : 0.0;

    final cacheStats = _cache.getCacheStats();

    // 重置计数器
    _lastStatsUpdate = now;
    _frameCount = 0;

    return LayeredRenderingStats(
      activeLayers: _activeImages.length,
      cacheHitRate: cacheStats.cacheHitRate,
      averageRenderTime: averageRenderTime,
      gpuMemoryUsage: cacheStats.gpuMemoryUsage,
      systemMemoryUsage: 0, // TODO: 实现系统内存监控
      framesPerSecond: framesPerSecond,
      timeWindow: timeWindow,
      timestamp: now,
    );
  }

  /// 获取详细的渲染信息
  Map<String, dynamic> getDetailedRenderInfo() {
    final cacheInfo = _cache.getDetailedCacheInfo();

    return {
      'active_images': _activeImages.length,
      'active_image_ids': _activeImages.keys.toList(),
      'render_times_ms': List.from(_renderTimes),
      'average_render_time_ms': _renderTimes.isNotEmpty
          ? _renderTimes.reduce((a, b) => a + b) / _renderTimes.length
          : 0.0,
      'frame_count': _frameCount,
      'cache_info': cacheInfo,
      'change_listeners': _changeControllers.length,
      'last_stats_update': _lastStatsUpdate.toIso8601String(),
    };
  }

  /// 强制清理所有缓存和状态
  void clearAll() {
    _activeImages.clear();
    _cache.clearAll();
    _renderTimes.clear();
    _frameCount = 0;
    _lastStatsUpdate = DateTime.now();

    // 关闭所有监听器
    for (final controller in _changeControllers) {
      controller.close();
    }
    _changeControllers.clear();

    if (kEngineDebugMode) {
      print('[LayeredImageRenderer] All render state cleared');
    }
  }

  /// 获取当前图像状态
  LayeredImageState? getCurrentImage(String imageId) {
    return _activeImages[imageId];
  }

  /// 检查图像是否已缓存
  bool isImageCached(String imageId) {
    return _activeImages.containsKey(imageId);
  }

  /// 获取缓存统计
  Map<String, dynamic> getCacheStats() {
    return _cache.getDetailedCacheInfo();
  }

  /// 设置预测性加载
  void setPredictiveLoading(bool enabled) {
    _cache.setPredictiveLoading(enabled);
  }
}
