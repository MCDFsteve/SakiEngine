/// 渲染系统配置和集成
///
/// 提供在旧的预合成系统和新的层叠渲染系统间切换的功能
/// 支持渐进式迁移和性能对比
library rendering_system_integration;

import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/rendering/composite_cg_renderer.dart';
import 'package:sakiengine/src/rendering/layered_cg_renderer.dart';
import 'package:sakiengine/src/rendering/layered/layer_types.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

/// 渲染系统类型
enum RenderingSystemType {
  /// 旧的预合成渲染系统（兼容模式）
  composite,

  /// 新的层叠渲染系统（高性能模式）
  layered,

  /// 自动选择（根据性能指标动态选择）
  auto,
}

/// 渲染系统管理器
///
/// 负责在不同渲染系统之间切换，提供统一的接口
class RenderingSystemManager {
  static final RenderingSystemManager _instance =
      RenderingSystemManager._internal();
  factory RenderingSystemManager() => _instance;
  RenderingSystemManager._internal();

  static const String _renderSystemOverride = String.fromEnvironment(
    'SAKI_RENDER_SYSTEM',
    defaultValue: 'auto',
  );

  static RenderingSystemType _initialSystem() {
    if (kIsWeb) {
      return RenderingSystemType.layered;
    }
    switch (_renderSystemOverride) {
      case 'composite':
        return RenderingSystemType.composite;
      case 'layered':
        return RenderingSystemType.layered;
      default:
        return RenderingSystemType.auto;
    }
  }

  /// 当前使用的渲染系统
  RenderingSystemType _currentSystem = _initialSystem();

  /// 是否启用性能监控
  bool _performanceMonitoringEnabled = kEngineDebugMode;

  /// 性能统计
  final List<double> _renderTimings = [];
  final List<double> _memoryUsage = [];
  DateTime _lastPerfCheck = DateTime.now();

  /// 自动切换阈值
  static const double _performanceThreshold = 30.0; // FPS低于30时考虑切换
  static const Duration _autoSwitchCooldown = Duration(minutes: 1); // 切换冷却时间
  DateTime _lastAutoSwitch = DateTime.now();
  String? _lastCgRendererDiag;

  /// 设置渲染系统类型
  void setRenderingSystem(RenderingSystemType system) {
    if (_currentSystem == system) return;

    final oldSystem = _currentSystem;
    _currentSystem = system;

    if (kEngineDebugMode) {
      print('[RenderingSystemManager] Switched from $oldSystem to $system');
    }

    // 清理旧系统缓存
    _cleanupOldSystem(oldSystem);
  }

  /// 获取当前渲染系统类型
  RenderingSystemType get currentSystem => _currentSystem;

  /// 构建CG角色组件（统一接口）
  List<Widget> buildCgCharacters(
    BuildContext context,
    Map<String, CharacterState> cgCharacters,
    GameManager gameManager,
  ) {
    final stopwatch = Stopwatch()..start();

    try {
      // 强制统一使用 composite（shader 融合路径）
      const effectiveSystem = RenderingSystemType.composite;
      if (cgCharacters.isNotEmpty) {
        final diag =
            '${effectiveSystem.name}(forced)|count=${cgCharacters.length}|'
            'ff=${gameManager.isFastForwardMode}|current=${_currentSystem.name}';
        if (diag != _lastCgRendererDiag) {
          _lastCgRendererDiag = diag;
          print('[RenderingSystemManager] CG renderer selected: $diag');
        }
      }

      final widgets = CompositeCgRenderer.buildCgCharacters(
        context,
        cgCharacters,
        gameManager,
        skipAnimations: gameManager.isFastForwardMode,
        transitionDuration: gameManager.cgRendererTransitionDuration,
        onTransitionCompleted: gameManager.notifyCgRendererTransitionCompleted,
      );

      stopwatch.stop();
      _recordPerformance(stopwatch.elapsedMicroseconds / 1000.0);

      return widgets;
    } catch (e) {
      if (kEngineDebugMode) {
        print('[RenderingSystemManager] Render error: $e');
      }

      // 出错时回退到兼容模式
      if (_currentSystem == RenderingSystemType.layered) {
        print('[RenderingSystemManager] Falling back to composite renderer');
        return CompositeCgRenderer.buildCgCharacters(
          context,
          cgCharacters,
          gameManager,
          skipAnimations: gameManager.isFastForwardMode,
          transitionDuration: gameManager.cgRendererTransitionDuration,
          onTransitionCompleted:
              gameManager.notifyCgRendererTransitionCompleted,
        );
      }

      return [];
    }
  }

  /// 自动模式下的渲染
  List<Widget> _buildWithAutoSystem(
    BuildContext context,
    Map<String, CharacterState> cgCharacters,
    GameManager gameManager,
  ) {
    // 根据性能历史和复杂度选择系统
    final shouldUseLayered = _shouldUseLayeredSystem(cgCharacters.length);

    if (shouldUseLayered) {
      try {
        return LayeredCgRenderer.buildCgCharacters(
          context,
          cgCharacters,
          gameManager,
        );
      } catch (e) {
        if (kEngineDebugMode) {
          print(
            '[RenderingSystemManager] Layered renderer failed, falling back: $e',
          );
        }
        return CompositeCgRenderer.buildCgCharacters(
          context,
          cgCharacters,
          gameManager,
          skipAnimations: gameManager.isFastForwardMode,
          transitionDuration: gameManager.cgRendererTransitionDuration,
          onTransitionCompleted:
              gameManager.notifyCgRendererTransitionCompleted,
        );
      }
    } else {
      return CompositeCgRenderer.buildCgCharacters(
        context,
        cgCharacters,
        gameManager,
        skipAnimations: gameManager.isFastForwardMode,
        transitionDuration: gameManager.cgRendererTransitionDuration,
        onTransitionCompleted: gameManager.notifyCgRendererTransitionCompleted,
      );
    }
  }

  /// 判断是否应该使用层叠系统
  bool _shouldUseLayeredSystem(int characterCount) {
    if (characterCount <= 0) {
      return false;
    }

    // 允许通过 dart-define 强制指定渲染系统
    if (_renderSystemOverride == 'composite') {
      return false;
    }
    if (_renderSystemOverride == 'layered') {
      return true;
    }

    // 单CG槽位必须使用composite，以保证差分切换走shader融合
    if (characterCount == 1) {
      return false;
    }

    // 多图层/多角色场景优先使用层叠渲染
    if (characterCount > 1) {
      return true;
    }

    // 样本不足时默认使用层叠渲染，减少首帧CPU合成抖动
    if (_renderTimings.length < 10) {
      return true;
    }

    // 当最近平均渲染耗时偏高时保持层叠渲染
    final avgRenderTime =
        _renderTimings.reduce((a, b) => a + b) / _renderTimings.length;
    return avgRenderTime >= 12.0;
  }

  /// 获取实际使用的系统类型
  RenderingSystemType _getEffectiveSystem(int characterCount) {
    if (kIsWeb) {
      return RenderingSystemType.layered;
    }

    if (_currentSystem != RenderingSystemType.auto) {
      return _currentSystem;
    }

    // Auto模式逻辑
    return _shouldUseLayeredSystem(characterCount)
        ? RenderingSystemType.layered
        : RenderingSystemType.composite;
  }

  /// 清理旧系统缓存
  void _cleanupOldSystem(RenderingSystemType oldSystem) {
    switch (oldSystem) {
      case RenderingSystemType.composite:
        CompositeCgRenderer.clearCache();
        break;
      case RenderingSystemType.layered:
        LayeredCgRenderer.clearCache();
        break;
      case RenderingSystemType.auto:
        // Auto模式清理所有缓存
        CompositeCgRenderer.clearCache();
        LayeredCgRenderer.clearCache();
        break;
    }
  }

  /// 记录性能数据
  void _recordPerformance(double renderTimeMs) {
    if (!_performanceMonitoringEnabled) return;

    _renderTimings.add(renderTimeMs);

    // 保持固定大小的历史记录
    if (_renderTimings.length > 60) {
      _renderTimings.removeAt(0);
    }

    // 定期检查是否需要自动切换系统
    final now = DateTime.now();
    if (now.difference(_lastPerfCheck).inSeconds > 5) {
      _checkAutoSwitch();
      _lastPerfCheck = now;
    }
  }

  /// 检查是否需要自动切换渲染系统
  void _checkAutoSwitch() {
    if (_currentSystem != RenderingSystemType.auto) return;

    final now = DateTime.now();
    if (now.difference(_lastAutoSwitch) < _autoSwitchCooldown) return;

    if (_renderTimings.length < 10) return; // 样本不足

    final avgRenderTime =
        _renderTimings.reduce((a, b) => a + b) / _renderTimings.length;
    final estimatedFps = 1000.0 / avgRenderTime;

    if (estimatedFps < _performanceThreshold) {
      // 性能不足，考虑切换系统
      if (kEngineDebugMode) {
        print(
          '[RenderingSystemManager] Performance warning: ${estimatedFps.toStringAsFixed(1)} FPS, considering system switch',
        );
      }

      _lastAutoSwitch = now;
      // 这里可以实现更复杂的切换逻辑
    }
  }

  /// 获取当前性能统计
  Map<String, dynamic> getPerformanceStats() {
    final stats = <String, dynamic>{
      'current_system': _currentSystem.toString(),
      'performance_monitoring': _performanceMonitoringEnabled,
      'render_sample_count': _renderTimings.length,
    };

    if (_renderTimings.isNotEmpty) {
      final avgRenderTime =
          _renderTimings.reduce((a, b) => a + b) / _renderTimings.length;
      final minRenderTime = _renderTimings.reduce((a, b) => a < b ? a : b);
      final maxRenderTime = _renderTimings.reduce((a, b) => a > b ? a : b);

      stats.addAll({
        'avg_render_time_ms': avgRenderTime,
        'min_render_time_ms': minRenderTime,
        'max_render_time_ms': maxRenderTime,
        'estimated_fps': 1000.0 / avgRenderTime,
        'recent_render_times': List.from(_renderTimings.take(10)),
      });
    }

    // 添加各系统特定的统计
    try {
      if (_currentSystem == RenderingSystemType.layered ||
          _currentSystem == RenderingSystemType.auto) {
        final layeredStats = LayeredCgRenderer.getCurrentStats();
        if (layeredStats != null) {
          stats['layered_system'] = {
            'active_layers': layeredStats.activeLayers,
            'cache_hit_rate': layeredStats.cacheHitRate,
            'gpu_memory_usage': layeredStats.gpuMemoryUsage,
            'fps': layeredStats.framesPerSecond,
          };
        }
      }
    } catch (e) {
      stats['stats_error'] = e.toString();
    }

    return stats;
  }

  /// 执行系统维护
  void performMaintenance() {
    // 清理过期性能数据
    final now = DateTime.now();
    if (now.difference(_lastPerfCheck).inMinutes > 10) {
      _renderTimings.clear();
      _memoryUsage.clear();
    }

    // 调用各系统的维护方法
    switch (_currentSystem) {
      case RenderingSystemType.composite:
        // CompositeCgRenderer 没有维护方法，跳过
        break;
      case RenderingSystemType.layered:
        LayeredCgRenderer.performMaintenance();
        break;
      case RenderingSystemType.auto:
        LayeredCgRenderer.performMaintenance();
        break;
    }

    if (kEngineDebugMode) {
      print(
        '[RenderingSystemManager] Maintenance completed for $_currentSystem system',
      );
    }
  }

  /// 强制清理所有缓存
  void clearAllCache() {
    CompositeCgRenderer.clearCache();
    LayeredCgRenderer.clearCache();
    _renderTimings.clear();
    _memoryUsage.clear();

    if (kEngineDebugMode) {
      print('[RenderingSystemManager] All caches cleared');
    }
  }

  /// 启用/禁用性能监控
  void setPerformanceMonitoring(bool enabled) {
    _performanceMonitoringEnabled = enabled;
    if (!enabled) {
      _renderTimings.clear();
      _memoryUsage.clear();
    }

    if (kEngineDebugMode) {
      print(
        '[RenderingSystemManager] Performance monitoring: ${enabled ? "enabled" : "disabled"}',
      );
    }
  }

  /// 获取详细的系统信息
  Map<String, dynamic> getDetailedSystemInfo() {
    final info = <String, dynamic>{
      'current_system': _currentSystem.toString(),
      'performance_monitoring': _performanceMonitoringEnabled,
      'last_auto_switch': _lastAutoSwitch.toIso8601String(),
      'last_perf_check': _lastPerfCheck.toIso8601String(),
      'performance_stats': getPerformanceStats(),
    };

    // 添加各系统的详细信息
    try {
      info['composite_system'] = {
        'available': true,
        'description': 'Legacy pre-composition system',
      };

      info['layered_system'] = LayeredCgRenderer.getDetailedInfo();
    } catch (e) {
      info['info_error'] = e.toString();
    }

    return info;
  }
}

/// 渲染系统扩展方法
extension RenderingSystemExtensions on GameManager {
  /// 获取渲染系统管理器
  RenderingSystemManager get renderingSystem => RenderingSystemManager();

  /// 设置渲染系统
  void setRenderingSystem(RenderingSystemType system) {
    renderingSystem.setRenderingSystem(system);
  }

  /// 获取渲染性能统计
  Map<String, dynamic> getRenderingStats() {
    return renderingSystem.getPerformanceStats();
  }

  /// 执行渲染系统维护
  void performRenderingMaintenance() {
    renderingSystem.performMaintenance();
  }
}
