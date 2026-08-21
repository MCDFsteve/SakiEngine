import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'dart:math' as math;

/// 画面震动实际作用的渲染层。
enum SceneShakeLayer { none, scene, cg }

/// 将脚本的 shake target 路由到当前真正可见的画面层。
///
/// 原生 CG 会替代普通 scene 成为全屏画面，因此默认的 `shake` 和
/// `target background` 在 CG 存在时都应震动 CG，而不是变换其外层场景树。
SceneShakeLayer resolveSceneShakeLayer({
  required bool isShaking,
  required String? target,
  required bool hasCg,
}) {
  if (!isShaking) return SceneShakeLayer.none;

  final normalizedTarget = target?.trim().toLowerCase();
  if (normalizedTarget == 'cg') {
    return hasCg ? SceneShakeLayer.cg : SceneShakeLayer.none;
  }
  if (normalizedTarget == null ||
      normalizedTarget.isEmpty ||
      normalizedTarget == 'background') {
    return hasCg ? SceneShakeLayer.cg : SceneShakeLayer.scene;
  }
  return SceneShakeLayer.none;
}

/// 对话框震动效果管理器
/// 当打字机显示到感叹号时，触发GAL风格Q弹震动（快速左右震动带弹性衰减）
class DialogueShakeEffect extends StatefulWidget {
  final Widget child;
  final String dialogue;
  final String displayedText; // 新增：当前显示的文本
  final bool enabled;
  final int? triggerCharacterIndex;
  final double intensity;
  final Duration duration;

  const DialogueShakeEffect({
    super.key,
    required this.child,
    required this.dialogue,
    required this.displayedText, // 新增：必需的显示文本参数
    this.enabled = true,
    this.triggerCharacterIndex,
    this.intensity = 8.0, // 增大默认强度
    this.duration = const Duration(milliseconds: 1000), // 进一步延长到1秒让过渡极其舒缓
  });

  @override
  State<DialogueShakeEffect> createState() => _DialogueShakeEffectState();
}

class _DialogueShakeEffectState extends State<DialogueShakeEffect>
    with SingleTickerProviderStateMixin {
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  bool _hasTriggered = false;

  @override
  void initState() {
    super.initState();
    _initializeShakeAnimation();
    _checkForShakeTrigger();
  }

  @override
  void didUpdateWidget(DialogueShakeEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // 如果显示的文本发生变化，检查是否需要震动
    if (widget.displayedText != oldWidget.displayedText ||
        widget.dialogue != oldWidget.dialogue ||
        widget.triggerCharacterIndex != oldWidget.triggerCharacterIndex) {
      if (widget.dialogue != oldWidget.dialogue ||
          widget.triggerCharacterIndex != oldWidget.triggerCharacterIndex) {
        _hasTriggered = false;
      }
      _checkForShakeTrigger();
    }
  }

  void _initializeShakeAnimation() {
    // Q弹震动控制器
    _shakeController = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _shakeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _shakeController,
      curve: Curves.easeInOutCubic, // 使用更加舒缓的三次曲线
    ));
  }

  void _checkForShakeTrigger() {
    if (!widget.enabled || _hasTriggered) {
      return;
    }

    final triggerIndex = widget.triggerCharacterIndex;
    if (triggerIndex == null) {
      return;
    }

    if (widget.displayedText.length >= triggerIndex) {
      _hasTriggered = true;
      _triggerShake();
    }
  }

  void _triggerShake() {
    // 重置并启动震动动画
    _shakeController.reset();
    _shakeController.forward();
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        final progress = _shakeAnimation.value.clamp(0.0, 1.0);
        
        double offsetX = 0.0;
        double offsetY = 0.0;
        
        if (progress < 0.5) {
          // 主要Q弹震动阶段 - 进一步减少主震动时间比例
          final t = progress / 0.5;
          final shakeIntensity = math.sin(t * math.pi); // 0到1再到0的完美曲线
          
          // 更低频率震动，极其舒缓
          final shakeFreq = 4; // 进一步降低频率让过渡极其舒缓
          final baseAmplitude = widget.intensity * 4.0; // 大幅增加基础震动强度
          
          // 主要左右震动
          offsetX = baseAmplitude * shakeIntensity * math.sin(t * math.pi * shakeFreq);
          
          // 配合轻微上下震动增加Q弹感
          offsetY = baseAmplitude * 0.8 * shakeIntensity * math.cos(t * math.pi * shakeFreq * 0.9);
          
        } else {
          // 极其舒缓的收尾阶段 - 大幅延长收尾时间
          final t = (progress - 0.5) / 0.5;
          final fadeOut = 1.0 - Curves.easeOutCubic.transform(t); // 使用三次缓出曲线让收尾极其平滑
          final finalAmplitude = widget.intensity * 0.5 * fadeOut;
          
          // 极其温和的收尾震动
          offsetX = finalAmplitude * math.sin(t * math.pi * 2); // 极低频率的收尾
          offsetY = finalAmplitude * 0.3 * math.cos(t * math.pi * 1.5); // 轻微的上下收尾
        }

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..translate(offsetX, offsetY, 0.0),
          child: widget.child,
        );
      },
    );
  }
}

/// GAL风格Q弹震动效果的工具方法类
class ShakeEffectUtils {
  /// 检测文本中是否包含感叹号（中英文）
  static bool containsExclamation(String text) {
    return text.contains('!') || text.contains('！');
  }

  /// 创建Q弹震动效果矩阵
  static Matrix4 createShakeTransform(double progress, double intensity) {
    progress = progress.clamp(0.0, 1.0);
    
    double offsetX = 0.0;
    double offsetY = 0.0;
    
    if (progress < 0.5) {
      // 主要Q弹震动阶段 - 进一步减少主震动时间比例
      final t = progress / 0.5;
      final shakeIntensity = math.sin(t * math.pi); // 0到1再到0的完美曲线
      
      // 更低频率震动，极其舒缓
      final shakeFreq = 4; // 进一步降低频率让过渡极其舒缓
      final baseAmplitude = intensity * 2.0; // 大幅增加基础震动强度
      
      // 主要左右震动
      offsetX = baseAmplitude * shakeIntensity * math.sin(t * math.pi * shakeFreq);
      
      // 配合轻微上下震动增加Q弹感
      offsetY = baseAmplitude * 0.6 * shakeIntensity * math.cos(t * math.pi * shakeFreq * 0.7);
      
    } else {
      // 极其舒缓的收尾阶段 - 大幅延长收尾时间
      final t = (progress - 0.5) / 0.5;
      final fadeOut = 1.0 - Curves.easeOutCubic.transform(t); // 使用三次缓出曲线让收尾极其平滑
      final finalAmplitude = intensity * 0.5 * fadeOut;
      
      // 极其温和的收尾震动
      offsetX = finalAmplitude * math.sin(t * math.pi * 2); // 极低频率的收尾
      offsetY = finalAmplitude * 0.3 * math.cos(t * math.pi * 1.5); // 轻微的上下收尾
    }
    
    return Matrix4.identity()
      ..translate(offsetX, offsetY, 0.0);
  }

  /// 获取Q弹震动效果偏移量
  static Offset getShakeOffset(double progress, double intensity) {
    progress = progress.clamp(0.0, 1.0);
    
    double offsetX = 0.0;
    double offsetY = 0.0;
    
    if (progress < 0.5) {
      // 主要Q弹震动阶段 - 进一步减少主震动时间比例
      final t = progress / 0.5;
      final shakeIntensity = math.sin(t * math.pi);
      
      final shakeFreq = 4; // 进一步降低频率让过渡极其舒缓
      final baseAmplitude = intensity * 2.0;
      
      offsetX = baseAmplitude * shakeIntensity * math.sin(t * math.pi * shakeFreq);
      offsetY = baseAmplitude * 0.6 * shakeIntensity * math.cos(t * math.pi * shakeFreq * 0.7);
      
    } else {
      // 极其舒缓的收尾阶段 - 大幅延长收尾时间
      final t = (progress - 0.5) / 0.5;
      final fadeOut = 1.0 - Curves.easeOutCubic.transform(t); // 使用三次缓出曲线让收尾极其平滑
      final finalAmplitude = intensity * 0.5 * fadeOut;
      
      // 极其温和的收尾震动
      offsetX = finalAmplitude * math.sin(t * math.pi * 2); // 极低频率的收尾
      offsetY = finalAmplitude * 0.3 * math.cos(t * math.pi * 1.5); // 轻微的上下收尾
    }
    
    return Offset(offsetX, offsetY);
  }
}

/// 简化版本的GAL震动Widget，可以直接包装任何组件
class SimpleShakeWrapper extends StatefulWidget {
  final Widget child;
  final bool trigger;
  final double intensity;
  final Duration duration;
  final VoidCallback? onShakeComplete;

  const SimpleShakeWrapper({
    super.key,
    required this.child,
    required this.trigger,
    this.intensity = 8.0, // 增大默认强度
    this.duration = const Duration(milliseconds: 1000), // 进一步延长到1秒让过渡极其舒缓
    this.onShakeComplete,
  });

  @override
  State<SimpleShakeWrapper> createState() => _SimpleShakeWrapperState();
}

class _SimpleShakeWrapperState extends State<SimpleShakeWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _lastTrigger = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _animation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(_controller);

    _animation.addStatusListener((status) {
      if (status == AnimationStatus.completed && widget.onShakeComplete != null) {
        widget.onShakeComplete!();
      }
    });

    _lastTrigger = widget.trigger;
    if (widget.trigger) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(SimpleShakeWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    
    // 检测trigger从false变为true时触发GAL震动
    if (!_lastTrigger && widget.trigger) {
      _controller.reset();
      _controller.forward();
    }
    _lastTrigger = widget.trigger;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final transform = ShakeEffectUtils.createShakeTransform(
          _animation.value, 
          widget.intensity
        );
        
        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: widget.child,
        );
      },
    );
  }
}
