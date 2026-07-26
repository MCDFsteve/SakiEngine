import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';

/// 在鼠标移动时为子组件提供视差偏移能力的封装组件。
class MouseParallax extends StatefulWidget {
  const MouseParallax({
    super.key,
    required this.child,
    this.maxOffset = const Offset(24, 16),
    this.enabled = true,
    this.resetDuration = const Duration(milliseconds: 220),
    this.resetCurve = Curves.easeOut,
  });

  /// 覆盖层内容。
  final Widget child;

  /// 允许的最大位移像素（水平/垂直）。
  final Offset maxOffset;

  /// 是否启用视差效果。
  final bool enabled;

  /// 鼠标离开时回正所需时间。
  final Duration resetDuration;

  /// 回正动画曲线。
  final Curve resetCurve;

  @override
  State<MouseParallax> createState() => _MouseParallaxState();
}

class _MouseParallaxState extends State<MouseParallax>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<Offset> _offsetNotifier = ValueNotifier(Offset.zero);
  late AnimationController _resetController;
  late Animation<Offset> _resetAnimation;
  Offset _currentOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _resetController = AnimationController(
      vsync: this,
      duration: widget.resetDuration,
    )..addListener(() {
        _offsetNotifier.value = _resetAnimation.value;
        _currentOffset = _resetAnimation.value;
      });

    _resetAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(_resetController);
  }

  @override
  void didUpdateWidget(MouseParallax oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetDuration != oldWidget.resetDuration) {
      _resetController.duration = widget.resetDuration;
    }
    if (!widget.enabled && oldWidget.enabled) {
      _resetToCenter();
    }
  }

  @override
  void dispose() {
    _resetController.dispose();
    _offsetNotifier.dispose();
    super.dispose();
  }

  void _handlePointer(Offset localPosition) {
    if (!widget.enabled) {
      return;
    }

    final size = context.size;
    if (size == null || size.width == 0 || size.height == 0) {
      return;
    }

    final normalized = Offset(
      (localPosition.dx / size.width) * 2 - 1,
      (localPosition.dy / size.height) * 2 - 1,
    )._clampToUnit();

    _resetController.stop();
    _currentOffset = normalized;
    _offsetNotifier.value = normalized;
  }

  void _resetToCenter() {
    if (_currentOffset == Offset.zero) {
      return;
    }

    _resetAnimation = Tween<Offset>(
      begin: _currentOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _resetController,
      curve: widget.resetCurve,
    ));

    _resetController
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    return MouseParallaxScope(
      offsetListenable: _offsetNotifier,
      maxOffset: widget.maxOffset,
      enabled: widget.enabled,
      child: Listener(
        onPointerHover: (event) => _handlePointer(event.localPosition),
        onPointerDown: (event) => _handlePointer(event.localPosition),
        onPointerMove: (event) => _handlePointer(event.localPosition),
        onPointerCancel: (_) => _resetToCenter(),
        onPointerUp: (_) => _resetToCenter(),
        child: MouseRegion(
          opaque: false,
          onHover: (event) => _handlePointer(event.localPosition),
          onExit: (_) => _resetToCenter(),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 将鼠标偏移暴露给子组件的作用域。
class MouseParallaxScope extends InheritedWidget {
  const MouseParallaxScope({
    super.key,
    required this.offsetListenable,
    required this.maxOffset,
    required this.enabled,
    required super.child,
  });

  final ValueListenable<Offset> offsetListenable;
  final Offset maxOffset;
  final bool enabled;

  static MouseParallaxScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MouseParallaxScope>();
  }

  static MouseParallaxScope of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) {
      throw FlutterError(
          'MouseParallaxScope.of() called with no MouseParallax ancestor.');
    }
    return scope;
  }

  @override
  bool updateShouldNotify(MouseParallaxScope oldWidget) {
    return offsetListenable != oldWidget.offsetListenable ||
        maxOffset != oldWidget.maxOffset ||
        enabled != oldWidget.enabled;
  }
}

/// 根据作用域中的偏移量对内部组件应用平移。
class ParallaxAware extends StatelessWidget {
  const ParallaxAware({
    super.key,
    required this.depth,
    required this.child,
    this.customMaxOffset,
    this.invert = true,
  });

  /// 深度系数，越大移动越明显。
  final double depth;

  /// 被应用视差的组件。
  final Widget child;

  /// 自定义最大位移（可选）。
  final Offset? customMaxOffset;

  /// 是否反向移动（默认背景->鼠标反向）。
  final bool invert;

  @override
  Widget build(BuildContext context) {
    if (depth == 0) {
      return child;
    }

    final scope = MouseParallaxScope.maybeOf(context);
    if (scope == null) {
      return child;
    }

    final maxOffset = customMaxOffset ?? scope.maxOffset;

    return ValueListenableBuilder<Offset>(
      valueListenable: scope.offsetListenable,
      builder: (context, normalized, widgetChild) {
        final effectiveOffset = scope.enabled ? normalized : Offset.zero;
        final direction = invert ? -1.0 : 1.0;
        final dx = effectiveOffset.dx * maxOffset.dx * depth * direction;
        final dy = effectiveOffset.dy * maxOffset.dy * depth * direction;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: widgetChild,
        );
      },
      child: child,
    );
  }
}

extension _OffsetClamp on Offset {
  Offset _clampToUnit() {
    return Offset(
      dx.clamp(-1.0, 1.0),
      dy.clamp(-1.0, 1.0),
    );
  }
}
