import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/widgets/common/common_indicator.dart';

/// 右键隐藏UI管理器
/// 视觉小说标配功能，右键可以隐藏/显示所有UI元素，左键推进剧情
class RightClickUIManager extends StatefulWidget {
  /// 子组件 - 包含所有UI元素
  final Widget child;

  /// 背景组件 - 不会被隐藏的背景内容（角色、背景等）
  final Widget backgroundChild;

  /// UI隐藏状态改变回调
  final Function(bool isUIHidden)? onUIVisibilityChanged;

  /// 左键点击回调（用于推进剧情）
  final VoidCallback? onLeftClick;

  /// 隐藏 UI 后是否允许缩放、拖动画面
  final bool enableHiddenUiSceneZoom;

  /// 隐藏 UI 时允许的最大画面倍率
  final double hiddenUiSceneMaxZoom;

  /// 隐藏 UI 后的场景是否仍处于缩放或拖动状态
  ///
  /// 可用于暂时关闭鼠标视差；场景复位到 1× 后会回调 `false`。
  final ValueChanged<bool>? onHiddenUiSceneTransformChanged;

  const RightClickUIManager({
    super.key,
    required this.child,
    required this.backgroundChild,
    this.onUIVisibilityChanged,
    this.onLeftClick,
    this.enableHiddenUiSceneZoom = true,
    this.hiddenUiSceneMaxZoom = 3.0,
    this.onHiddenUiSceneTransformChanged,
  }) : assert(hiddenUiSceneMaxZoom >= 1.0);

  @override
  State<RightClickUIManager> createState() => _RightClickUIManagerState();
}

class _RightClickUIManagerState extends State<RightClickUIManager>
    with TickerProviderStateMixin {
  /// UI是否被隐藏
  bool _isUIHidden = false;

  late final GlobalRightClickUIManager _globalManager;

  /// 动画控制器
  late AnimationController _animationController;

  /// 淡出动画
  late Animation<double> _fadeAnimation;

  late final TransformationController _sceneTransformationController;
  late final AnimationController _sceneResetController;
  Animation<Matrix4>? _sceneResetAnimation;
  Timer? _sceneZoomIndicatorHideTimer;
  bool _showSceneZoomIndicator = false;
  bool _hasReportedSceneTransform = false;
  bool _isResettingSceneTransform = false;

  @override
  void initState() {
    super.initState();

    _globalManager = GlobalRightClickUIManager();
    _isUIHidden = _globalManager.isUIHidden;

    // 初始化动画控制器
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    // 初始化淡出动画
    _fadeAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    // 设置初始值
    // 当UI显示时，controller为0，fade为1.0
    // 当UI隐藏时，controller为1，fade为0.0
    _animationController.value = _isUIHidden ? 1.0 : 0.0;

    _sceneTransformationController = TransformationController()
      ..addListener(_handleSceneTransformationChanged);
    _sceneResetController = AnimationController(
      duration: const Duration(milliseconds: 260),
      vsync: this,
    )..addListener(_handleSceneResetTick);

    _globalManager.addListener(_handleGlobalVisibilityChange);
  }

  @override
  void dispose() {
    _globalManager.removeListener(_handleGlobalVisibilityChange);
    _sceneZoomIndicatorHideTimer?.cancel();
    _sceneResetController
      ..removeListener(_handleSceneResetTick)
      ..dispose();
    _sceneTransformationController
      ..removeListener(_handleSceneTransformationChanged)
      ..dispose();
    _animationController.dispose();
    super.dispose();
  }

  void _handleGlobalVisibilityChange() {
    final hidden = _globalManager.isUIHidden;
    if (hidden == _isUIHidden) return;
    setState(() {
      _isUIHidden = hidden;
    });
    if (_isUIHidden) {
      if (_sceneResetController.isAnimating) {
        _sceneResetController.stop();
        _sceneTransformationController.value = Matrix4.identity();
        _isResettingSceneTransform = false;
      }
      _animationController.forward();
    } else {
      _hideSceneZoomIndicator();
      _animationController.reverse();
      _animateSceneReset();
    }
    widget.onUIVisibilityChanged?.call(_isUIHidden);
  }

  void _handleSceneResetTick() {
    final animation = _sceneResetAnimation;
    if (animation != null) {
      _sceneTransformationController.value = animation.value;
    }
  }

  void _handleSceneTransformationChanged() {
    final hasTransform = widget.enableHiddenUiSceneZoom && _hasSceneTransform;
    if (hasTransform != _hasReportedSceneTransform) {
      _hasReportedSceneTransform = hasTransform;
      widget.onHiddenUiSceneTransformChanged?.call(hasTransform);
    }

    if (_isUIHidden && !_isResettingSceneTransform) {
      _showSceneZoomIndicatorTemporarily();
    }
  }

  void _showSceneZoomIndicatorTemporarily() {
    _sceneZoomIndicatorHideTimer?.cancel();
    if (!_showSceneZoomIndicator && mounted) {
      setState(() {
        _showSceneZoomIndicator = true;
      });
    }
    _sceneZoomIndicatorHideTimer = Timer(
      const Duration(milliseconds: 900),
      () {
        if (!mounted || !_showSceneZoomIndicator) {
          return;
        }
        setState(() {
          _showSceneZoomIndicator = false;
        });
      },
    );
  }

  void _hideSceneZoomIndicator() {
    _sceneZoomIndicatorHideTimer?.cancel();
    _sceneZoomIndicatorHideTimer = null;
    _showSceneZoomIndicator = false;
  }

  bool get _hasSceneTransform {
    final matrix = _sceneTransformationController.value;
    final translationX = matrix.storage[12];
    final translationY = matrix.storage[13];
    return (matrix.getMaxScaleOnAxis() - 1.0).abs() > 0.001 ||
        translationX.abs() > 0.001 ||
        translationY.abs() > 0.001;
  }

  void _animateSceneReset() {
    if (!_hasSceneTransform) {
      _isResettingSceneTransform = true;
      _sceneTransformationController.value = Matrix4.identity();
      _isResettingSceneTransform = false;
      return;
    }
    _isResettingSceneTransform = true;
    _sceneResetAnimation = Matrix4Tween(
      begin: _sceneTransformationController.value.clone(),
      end: Matrix4.identity(),
    ).animate(
      CurvedAnimation(
        parent: _sceneResetController,
        curve: Curves.easeOutCubic,
      ),
    );
    _sceneResetController.forward(from: 0.0).whenComplete(() {
      _isResettingSceneTransform = false;
    });
  }

  void _setUIHidden() {
    if (!_globalManager.isUIHidden) {
      _globalManager.setUIHidden(true);
      HapticFeedback.lightImpact();
    }
  }

  void _setUIVisible() {
    if (_globalManager.isUIHidden) {
      _globalManager.setUIHidden(false);
    }
  }

  Widget _buildSceneZoomIndicator(BuildContext context) {
    if (!_isUIHidden || !widget.enableHiddenUiSceneZoom) {
      return const SizedBox(
        key: ValueKey('hidden_ui_scene_zoom_indicator_hidden'),
      );
    }

    final scale = context.scaleFor(ComponentType.menu);
    return Positioned(
      left: 100 * scale,
      top: 20 * scale,
      child: IgnorePointer(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: _showSceneZoomIndicator
              ? ValueListenableBuilder<Matrix4>(
                  key: const ValueKey('hidden_ui_scene_zoom_indicator'),
                  valueListenable: _sceneTransformationController,
                  builder: (context, matrix, child) {
                    final zoom = matrix.getMaxScaleOnAxis().clamp(
                          1.0,
                          widget.hiddenUiSceneMaxZoom,
                        );
                    return Semantics(
                      label: 'Scene zoom',
                      value: '${zoom.toStringAsFixed(2)} times',
                      child: CommonIndicator(
                        isVisible: true,
                        icon: Icons.zoom_in_rounded,
                        text: '${zoom.toStringAsFixed(2)}×',
                      ),
                    );
                  },
                )
              : const SizedBox(
                  key: ValueKey('hidden_ui_scene_zoom_indicator_idle'),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 背景层 - 不会被隐藏
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _isUIHidden ? (_) => _setUIVisible() : null,
          onSecondaryTapUp: _isUIHidden ? (_) => _setUIVisible() : null,
          child: widget.enableHiddenUiSceneZoom
              ? InteractiveViewer(
                  transformationController: _sceneTransformationController,
                  panEnabled: _isUIHidden,
                  scaleEnabled: _isUIHidden,
                  trackpadScrollCausesScale: true,
                  minScale: 1.0,
                  maxScale: widget.hiddenUiSceneMaxZoom,
                  clipBehavior: Clip.hardEdge,
                  onInteractionStart: (_) {
                    if (_isUIHidden) {
                      _showSceneZoomIndicatorTemporarily();
                    }
                  },
                  onInteractionUpdate: (_) {
                    if (_isUIHidden) {
                      _showSceneZoomIndicatorTemporarily();
                    }
                  },
                  child: SizedBox.expand(child: widget.backgroundChild),
                )
              : widget.backgroundChild,
        ),

        // UI层 - 可以被隐藏，在最上面
        AnimatedBuilder(
          animation: _fadeAnimation,
          builder: (context, child) {
            return IgnorePointer(
              ignoring: _isUIHidden,
              child: Opacity(
                opacity: _fadeAnimation.value,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (details) {
                    // 触屏点击推进逻辑由 MobileTouchController 负责，这里只处理鼠标输入。
                    if (details.kind != PointerDeviceKind.mouse) {
                      return;
                    }
                    widget.onLeftClick?.call();
                  },
                  onSecondaryTapUp: (details) {
                    // 仅处理鼠标右键
                    if (details.kind != PointerDeviceKind.mouse) {
                      return;
                    }
                    _setUIHidden();
                  },
                  child: widget.child,
                ),
              ),
            );
          },
        ),

        _buildSceneZoomIndicator(context),
      ],
    );
  }
}

/// 全局右键UI管理器状态
class GlobalRightClickUIManager extends ChangeNotifier {
  static final GlobalRightClickUIManager _instance =
      GlobalRightClickUIManager._internal();
  factory GlobalRightClickUIManager() => _instance;
  GlobalRightClickUIManager._internal();

  /// 当前UI是否被隐藏
  bool _isUIHidden = false;
  bool get isUIHidden => _isUIHidden;

  /// 设置UI隐藏状态
  void setUIHidden(bool hidden) {
    if (_isUIHidden != hidden) {
      _isUIHidden = hidden;
      notifyListeners();
    }
  }

  /// 切换UI显示状态
  void toggleUIVisibility() {
    setUIHidden(!_isUIHidden);
  }
}

/// 右键UI管理Mixin，方便其他组件使用
mixin RightClickUIManagerMixin<T extends StatefulWidget> on State<T> {
  final GlobalRightClickUIManager _globalManager = GlobalRightClickUIManager();

  bool get isUIHidden => _globalManager.isUIHidden;

  @override
  void initState() {
    super.initState();
    _globalManager.addListener(_onUIVisibilityChanged);
  }

  @override
  void dispose() {
    _globalManager.removeListener(_onUIVisibilityChanged);
    super.dispose();
  }

  void _onUIVisibilityChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 子类可以重写此方法来处理UI隐藏状态变化
  void onUIVisibilityChanged(bool isHidden) {}
}

/// 可隐藏的UI组件包装器
class HideableUI extends StatelessWidget {
  final Widget child;
  final bool hideWhenUIHidden;
  final double hiddenOpacity;
  final Duration animationDuration;

  const HideableUI({
    super.key,
    required this.child,
    this.hideWhenUIHidden = true,
    this.hiddenOpacity = 0.0,
    this.animationDuration = const Duration(milliseconds: 200),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GlobalRightClickUIManager(),
      builder: (context, child) {
        final isHidden = GlobalRightClickUIManager().isUIHidden;
        final shouldHide = hideWhenUIHidden && isHidden;

        return AnimatedOpacity(
          opacity: shouldHide ? hiddenOpacity : 1.0,
          duration: animationDuration,
          child: IgnorePointer(
            ignoring: shouldHide,
            child: this.child,
          ),
        );
      },
    );
  }
}
