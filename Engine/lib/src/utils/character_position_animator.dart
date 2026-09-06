import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show TickerCanceled;
import 'package:sakiengine/src/utils/foundation_compat.dart';

/// 角色位置变化的描述
class CharacterPositionChange {
  final String characterId;
  final double fromX;
  final double toX;

  CharacterPositionChange({
    required this.characterId,
    required this.fromX,
    required this.toX,
  });
}

/// 角色属性变化的描述（包括所有pose属性）
class CharacterAttributeChange {
  final String characterId;
  final Map<String, double> fromAttributes;
  final Map<String, double> toAttributes;

  CharacterAttributeChange({
    required this.characterId,
    required this.fromAttributes,
    required this.toAttributes,
  });

  /// 检查是否有属性变化
  bool get hasChanges {
    for (final key in toAttributes.keys) {
      final fromValue = fromAttributes[key] ?? 0.0;
      final toValue = toAttributes[key] ?? 0.0;
      if ((fromValue - toValue).abs() > 0.001) {
        return true;
      }
    }
    return false;
  }
}

/// 角色位置补间动画管理器
/// 处理角色从一个位置平滑移动到另一个位置的动画
/// 现已扩展支持所有pose属性的补间（xcenter、ycenter、scale、alpha等）
class CharacterPositionAnimator {
  AnimationController? _controller;
  Animation<double>? _animation;
  CurvedAnimation? _curvedAnimation;
  List<CharacterPositionChange> _positionChanges = [];
  List<CharacterAttributeChange> _attributeChanges = [];
  Map<String, double> _currentPositions = {};
  Map<String, Map<String, double>> _currentAttributes = {};
  void Function(Map<String, double>)? _onUpdate;
  void Function(Map<String, Map<String, double>>)? _onAttributeUpdate;
  VoidCallback? _onComplete;

  /// 开始角色位置变化的补间动画
  /// [positionChanges] 所有需要动画的角色位置变化
  /// [vsync] TickerProvider用于创建AnimationController
  /// [duration] 动画持续时间，默认0.5秒
  /// [curve] 动画曲线，默认easeInOut
  /// [onUpdate] 动画更新回调，参数是角色ID到当前位置的映射
  /// [onComplete] 动画正常完成回调；被停止或替换时仅结束等待，不调用此回调
  Future<void> animatePositionChanges({
    required List<CharacterPositionChange> positionChanges,
    required TickerProvider vsync,
    Duration duration = const Duration(milliseconds: 500),
    Curve curve = Curves.easeInOut,
    void Function(Map<String, double>)? onUpdate,
    VoidCallback? onComplete,
  }) async {
    stop();
    if (positionChanges.isEmpty) {
      onComplete?.call();
      return;
    }

    _positionChanges = positionChanges;
    _attributeChanges = [];
    _onUpdate = onUpdate;
    _onAttributeUpdate = null;
    _onComplete = onComplete;

    // 初始化当前位置
    _currentPositions.clear();
    for (final change in positionChanges) {
      _currentPositions[change.characterId] = change.fromX;
    }

    await _startAnimation(vsync, duration, curve);
  }

  /// 开始角色属性变化的补间动画
  /// [attributeChanges] 所有需要动画的角色属性变化
  /// [vsync] TickerProvider用于创建AnimationController
  /// [duration] 动画持续时间，默认0.3秒（比位置动画稍快）
  /// [curve] 动画曲线，默认easeInOut
  /// [onUpdate] 动画更新回调，参数是角色ID到属性映射的映射
  /// [onComplete] 动画正常完成回调；被停止或替换时仅结束等待，不调用此回调
  Future<void> animateAttributeChanges({
    required List<CharacterAttributeChange> attributeChanges,
    required TickerProvider vsync,
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOut,
    void Function(Map<String, Map<String, double>>)? onUpdate,
    VoidCallback? onComplete,
  }) async {
    stop();
    // 过滤掉没有变化的属性
    final filteredChanges = attributeChanges
        .where((change) => change.hasChanges)
        .toList();

    if (filteredChanges.isEmpty) {
      onUpdate?.call({});
      onComplete?.call();
      return;
    }

    _positionChanges = [];
    _attributeChanges = filteredChanges;
    _onUpdate = null;
    _onAttributeUpdate = onUpdate;
    _onComplete = onComplete;

    // 初始化当前属性
    _currentAttributes.clear();
    for (final change in filteredChanges) {
      _currentAttributes[change.characterId] = Map.from(change.fromAttributes);
    }

    await _startAnimation(vsync, duration, curve);
  }

  /// 开始动画
  Future<void> _startAnimation(
    TickerProvider vsync,
    Duration duration,
    Curve curve,
  ) async {
    // 创建动画控制器
    final controller = AnimationController(duration: duration, vsync: vsync);
    _controller = controller;

    // 创建动画
    final curvedAnimation = CurvedAnimation(parent: controller, curve: curve);
    _curvedAnimation = curvedAnimation;

    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(curvedAnimation);

    _animation!.addListener(_updateAnimation);

    final onComplete = _onComplete;
    var completed = false;
    try {
      // 普通TickerFuture被取消后不会结束；orCancel让剧情可以正常解除等待。
      await controller.forward().orCancel;
      completed = identical(_controller, controller);
    } on TickerCanceled {
      // 停止、替换和释放都是正常取消，不能执行旧动画的完成回调。
    } finally {
      // 旧动画的异步收尾不能释放后来启动的新动画。
      if (identical(_controller, controller)) {
        stop();
      }
    }

    if (completed) {
      onComplete?.call();
    }
  }

  /// 更新动画
  void _updateAnimation() {
    final progress = _animation!.value;

    // 更新位置变化
    if (_positionChanges.isNotEmpty) {
      for (final change in _positionChanges) {
        final currentX = change.fromX + (change.toX - change.fromX) * progress;
        _currentPositions[change.characterId] = currentX;
      }
      _onUpdate?.call(Map.from(_currentPositions));
    }
    // 更新属性变化
    else if (_attributeChanges.isNotEmpty) {
      for (final change in _attributeChanges) {
        final currentAttrs = _currentAttributes[change.characterId]!;

        // 对每个属性进行插值
        for (final key in change.toAttributes.keys) {
          final fromValue = change.fromAttributes[key] ?? 0.0;
          final toValue = change.toAttributes[key]!;
          final currentValue = fromValue + (toValue - fromValue) * progress;
          currentAttrs[key] = currentValue;
        }
      }
      _onAttributeUpdate?.call(Map.from(_currentAttributes));
    }
  }

  /// 更新角色位置（已废弃，保留以兼容旧代码）
  void _updatePositions() {
    _updateAnimation();
  }

  /// 立即停止动画
  void stop() {
    final controller = _controller;
    if (controller == null) return;

    _controller = null;
    _animation?.removeListener(_updateAnimation);
    _animation = null;
    _curvedAnimation?.dispose();
    _curvedAnimation = null;
    controller.dispose();
  }

  /// 释放资源
  void dispose() {
    stop();
  }

  /// 获取当前是否正在动画中
  bool get isAnimating => _controller?.isAnimating ?? false;
}
