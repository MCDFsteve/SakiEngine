import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/engine_asset_loader.dart';
import 'package:sakiengine/src/utils/image_loader.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';

/// 转场效果类型枚举
enum TransitionType {
  fade, // 黑屏淡入淡出 (原有效果)
  diss, // 直接图片渐变过渡
  wipe, // 擦除效果 (未来扩展)
  slide, // 滑动效果 (未来扩展)
  blink, // 睁眼效果 (上下黑屏移开，模拟睁开眼睛)
  pixel, // 像素化截图转场
}

/// 转场效果管理器
class SceneTransitionEffectManager {
  static SceneTransitionEffectManager? _instance;
  static SceneTransitionEffectManager get instance =>
      _instance ??= SceneTransitionEffectManager._();

  SceneTransitionEffectManager._();

  OverlayEntry? _overlayEntry;
  bool _isTransitioning = false;

  /// 执行场景转场
  /// [context] 用于创建覆盖层的上下文
  /// [transitionType] 转场类型
  /// [onMidTransition] 在转场中点执行的回调（切换场景时机）
  /// [duration] 转场时长
  /// [oldBackground] 旧背景名称（用于diss效果）
  /// [newBackground] 新背景名称（用于diss效果）
  Future<void> transition({
    required BuildContext context,
    required TransitionType transitionType,
    required VoidCallback onMidTransition,
    Duration duration = const Duration(milliseconds: 800),
    String? oldBackground,
    String? newBackground,
  }) async {
    //print('[SceneTransition] 请求${transitionType.name}转场，当前状态: isTransitioning=$_isTransitioning');
    if (_isTransitioning) return;

    // 对于diss转场，如果新旧背景相同，直接跳过转场
    if (transitionType == TransitionType.diss &&
        oldBackground == newBackground) {
      //print('[SceneTransition] diss转场检测到相同背景($oldBackground -> $newBackground)，跳过转场效果');
      onMidTransition();
      return;
    }

    _isTransitioning = true;
    //print('[SceneTransition] 开始${transitionType.name}转场，时长: ${duration.inMilliseconds}ms');

    final completer = Completer<void>();
    final oldFrame = transitionType == TransitionType.pixel
        ? await _captureTransitionFrame(context)
        : null;

    // 根据转场类型创建不同的覆盖层
    Widget transitionWidget;
    switch (transitionType) {
      case TransitionType.fade:
        transitionWidget = _FadeTransitionOverlay(
          duration: duration,
          onMidTransition: onMidTransition,
          onComplete: () {
            //print('[SceneTransition] fade转场完成，移除覆盖层');
            _removeOverlay();
            _isTransitioning = false;
            completer.complete();
          },
        );
        break;
      case TransitionType.diss:
        transitionWidget = _DissTransitionOverlay(
          duration: duration,
          onMidTransition: onMidTransition,
          onComplete: () {
            //print('[SceneTransition] diss转场完成，移除覆盖层');
            _removeOverlay();
            _isTransitioning = false;
            completer.complete();
          },
          oldBackgroundName: oldBackground,
          newBackgroundName: newBackground,
        );
        break;
      case TransitionType.wipe:
        transitionWidget = _WipeTransitionOverlay(
          duration: duration * 2, // wipe转场持续时间翻倍
          onMidTransition: onMidTransition,
          onComplete: () {
            //print('[SceneTransition] wipe转场完成，移除覆盖层');
            _removeOverlay();
            _isTransitioning = false;
            completer.complete();
          },
        );
        break;
      case TransitionType.blink:
        transitionWidget = _BlinkTransitionOverlay(
          duration: duration,
          onMidTransition: onMidTransition,
          onComplete: () {
            //print('[SceneTransition] blink转场完成，移除覆盖层');
            _removeOverlay();
            _isTransitioning = false;
            completer.complete();
          },
        );
        break;
      case TransitionType.pixel:
        transitionWidget = _PixelTransitionOverlay(
          duration: duration,
          oldFrame: oldFrame,
          captureFrame: () => _captureTransitionFrame(context),
          onMidTransition: onMidTransition,
          onComplete: () {
            //print('[SceneTransition] pixel转场完成，移除覆盖层');
            _removeOverlay();
            _isTransitioning = false;
            completer.complete();
          },
        );
        break;
      default:
        // 默认使用fade效果
        transitionWidget = _FadeTransitionOverlay(
          duration: duration,
          onMidTransition: onMidTransition,
          onComplete: () {
            //print('[SceneTransition] 默认fade转场完成，移除覆盖层');
            _removeOverlay();
            _isTransitioning = false;
            completer.complete();
          },
        );
    }

    // 创建覆盖层
    _overlayEntry = OverlayEntry(
      builder: (context) => transitionWidget,
    );

    // 插入覆盖层
    //print('[SceneTransition] 插入${transitionType.name}转场覆盖层');
    Overlay.of(context).insert(_overlayEntry!);

    return completer.future;
  }

  Future<ui.Image?> _captureTransitionFrame(BuildContext context) async {
    try {
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        return null;
      }

      var needsPaint = false;
      assert(() {
        needsPaint = renderObject.debugNeedsPaint;
        return true;
      }());
      if (needsPaint) {
        await WidgetsBinding.instance.endOfFrame;
      }

      final size = renderObject.size;
      if (size.width <= 0 || size.height <= 0) {
        return null;
      }

      final devicePixelRatio = View.of(context).devicePixelRatio;
      final pixelRatio = devicePixelRatio.clamp(0.75, 1.25).toDouble();
      return renderObject.toImage(pixelRatio: pixelRatio);
    } catch (e) {
      if (kEngineDebugMode) {
        print('[PixelTransition] 捕获转场帧失败: $e');
      }
      return null;
    }
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  bool get isTransitioning => _isTransitioning;
}

/// 黑屏淡入淡出转场覆盖层（原有效果）
class _FadeTransitionOverlay extends StatefulWidget {
  final Duration duration;
  final VoidCallback onMidTransition;
  final VoidCallback onComplete;

  const _FadeTransitionOverlay({
    required this.duration,
    required this.onMidTransition,
    required this.onComplete,
  });

  @override
  State<_FadeTransitionOverlay> createState() => _FadeTransitionOverlayState();
}

class _FadeTransitionOverlayState extends State<_FadeTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeOutAnimation;
  late Animation<double> _fadeInAnimation;
  bool _midTransitionExecuted = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    // 前半段：淡出到黑屏 (0 -> 1)
    _fadeOutAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeInOut),
    ));

    // 后半段：从黑屏淡入 (1 -> 0)
    _fadeInAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeInOut),
    ));

    _controller.addListener(_onAnimationUpdate);
    _controller.addStatusListener(_onAnimationStatus);

    // 开始动画
    _controller.forward();
  }

  void _onAnimationUpdate() {
    // 在动画中点执行场景切换
    if (!_midTransitionExecuted && _controller.value >= 0.5) {
      _midTransitionExecuted = true;
      widget.onMidTransition();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // 计算当前黑屏不透明度
        double opacity;
        if (_controller.value <= 0.5) {
          // 前半段：淡出到黑屏
          opacity = _fadeOutAnimation.value;
        } else {
          // 后半段：从黑屏淡入
          opacity = _fadeInAnimation.value;
        }

        return IgnorePointer(
          ignoring: true, // 不拦截UI交互
          child: Material(
            color: Colors.black.withOpacity(opacity),
            child: const SizedBox(
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        );
      },
    );
  }
}

/// 图片直接渐变转场覆盖层（使用dissolve着色器效果）
class _DissTransitionOverlay extends StatefulWidget {
  final Duration duration;
  final VoidCallback onMidTransition;
  final VoidCallback onComplete;
  final String? oldBackgroundName;
  final String? newBackgroundName;

  const _DissTransitionOverlay({
    required this.duration,
    required this.onMidTransition,
    required this.onComplete,
    this.oldBackgroundName,
    this.newBackgroundName,
  });

  @override
  State<_DissTransitionOverlay> createState() => _DissTransitionOverlayState();
}

class _DissTransitionOverlayState extends State<_DissTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _dissAnimation;
  bool _midTransitionExecuted = false;

  ui.Image? _oldImage;
  ui.Image? _newImage;
  static ui.FragmentProgram? _dissolveProgram;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    // 溶解动画：从旧背景溶解到新背景 (0 -> 1)
    _dissAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));

    _controller.addListener(_onAnimationUpdate);
    _controller.addStatusListener(_onAnimationStatus);

    // 加载图片和着色器
    _loadImages();
    _loadShader();
  }

  Future<void> _loadShader() async {
    if (_dissolveProgram == null) {
      try {
        final program = await EngineAssetLoader.loadFragmentProgram(
          'assets/shaders/dissolve.frag',
        );
        _dissolveProgram = program;
      } catch (e) {
        print('Error loading dissolve shader: $e');
      }
    }
  }

  Future<void> _loadImages() async {
    // 等待所有需要的图片加载完成后再开始动画
    List<Future<void>> loadTasks = [];

    // 加载旧背景图片
    if (widget.oldBackgroundName != null) {
      loadTasks.add(() async {
        final oldAssetPath =
            await AssetManager().findAsset(widget.oldBackgroundName!);
        if (oldAssetPath != null && mounted) {
          final oldImage = await ImageLoader.loadImage(oldAssetPath);
          if (mounted && oldImage != null) {
            _oldImage = oldImage;
          }
        }
      }());
    }

    // 加载新背景图片
    if (widget.newBackgroundName != null) {
      loadTasks.add(() async {
        final newAssetPath =
            await AssetManager().findAsset(widget.newBackgroundName!);
        if (newAssetPath != null && mounted) {
          final newImage = await ImageLoader.loadImage(newAssetPath);
          if (mounted && newImage != null) {
            _newImage = newImage;
          } else {
            print(
                '[DissTransition] 警告: 新背景图片加载失败: ${widget.newBackgroundName}');
          }
        } else {
          print('[DissTransition] 警告: 找不到新背景资源: ${widget.newBackgroundName}');
        }
      }());
    }

    // 等待所有图片加载完成
    if (loadTasks.isNotEmpty) {
      await Future.wait(loadTasks);
    }

    // 如果两个背景都加载失败，直接完成转场避免闪烁
    if (_oldImage == null && _newImage == null) {
      print('[DissTransition] 两个背景都未找到，直接完成转场');
      widget.onMidTransition();
      widget.onComplete();
      return;
    }

    // 所有图片加载完成后，一次性更新状态
    if (mounted) {
      setState(() {
        // 图片已在上面加载，这里只是触发重建
      });

      // 等待下一帧确保图片完全渲染后再开始动画
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.forward();
        }
      });
    }
  }

  void _onAnimationUpdate() {
    // 对于CG转场，延迟状态更新到90%，避免中途更新导致的闪烁
    // 对于普通背景转场，保持在50%更新
    final isLikelyCG =
        widget.oldBackgroundName?.toLowerCase().contains('cg') == true ||
            widget.newBackgroundName?.toLowerCase().contains('cg') == true;

    // 将普通场景的切换点延后到动画完成前的 90%，避免 50% 时旧背景突然变暗
    final updateThreshold = isLikelyCG ? 0.95 : 0.9;

    // 在指定进度执行场景切换
    if (!_midTransitionExecuted && _controller.value >= updateThreshold) {
      _midTransitionExecuted = true;
      print(
          '[DissTransition] 到达转场更新点(${(updateThreshold * 100).toInt()}%)，执行回调');
      widget.onMidTransition();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _oldImage?.dispose();
    _newImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _dissAnimation,
      builder: (context, child) {
        // 如果没有图片，使用黑色遮罩进行渐变过渡
        if (_oldImage == null && _newImage == null) {
          return Material(
            color: Colors.black.withOpacity(_dissAnimation.value > 0.5
                ? 2.0 * (1.0 - _dissAnimation.value)
                : 2.0 * _dissAnimation.value),
            child: const SizedBox(
              width: double.infinity,
              height: double.infinity,
            ),
          );
        }

        // 使用Flutter原生的图片渐变
        return Stack(
          fit: StackFit.expand,
          children: [
            // 旧背景，逐渐淡出
            if (_oldImage != null)
              Opacity(
                opacity: 1.0 - _dissAnimation.value,
                child: RawImage(
                  image: _oldImage!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  filterQuality:
                      ImageSamplingManager().resolveWidgetFilterQuality(
                    defaultQuality: FilterQuality.high,
                  ),
                ),
              ),
            // 新背景，逐渐淡入（如果没有新图片，就不显示）
            if (_newImage != null)
              Opacity(
                opacity: _dissAnimation.value,
                child: RawImage(
                  image: _newImage!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  filterQuality:
                      ImageSamplingManager().resolveWidgetFilterQuality(
                    defaultQuality: FilterQuality.high,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 旋转擦除转场覆盖层（类似iris转场效果）
class _WipeTransitionOverlay extends StatefulWidget {
  final Duration duration;
  final VoidCallback onMidTransition;
  final VoidCallback onComplete;

  const _WipeTransitionOverlay({
    required this.duration,
    required this.onMidTransition,
    required this.onComplete,
  });

  @override
  State<_WipeTransitionOverlay> createState() => _WipeTransitionOverlayState();
}

class _WipeTransitionOverlayState extends State<_WipeTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _wipeInAnimation;
  late Animation<double> _wipeOutAnimation;
  bool _midTransitionExecuted = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    // 重新计算时间分配：前30%顺时针旋转，中间40%保持黑屏，后30%逆时针旋转
    // 前30%：扇形从0度顺时针旋转到360度 (完全覆盖)
    _wipeInAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.3, curve: Curves.easeInOut),
    ));

    // 后30%：扇形从360度逆时针旋转回0度 (完全显示)
    _wipeOutAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.7, 1.0, curve: Curves.easeInOut),
    ));

    _controller.addListener(_onAnimationUpdate);
    _controller.addStatusListener(_onAnimationStatus);

    // 开始动画
    _controller.forward();
  }

  void _onAnimationUpdate() {
    // 在动画中点执行场景切换
    if (!_midTransitionExecuted && _controller.value >= 0.5) {
      _midTransitionExecuted = true;
      print('[WipeTransition] 到达转场中点，执行回调');
      widget.onMidTransition();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // 计算当前扇形覆盖角度
        double sweepProgress;

        if (_controller.value <= 0.35) {
          // 前30%：从0度顺时针旋转到360度
          sweepProgress = _wipeInAnimation.value;
        } else if (_controller.value <= 0.65) {
          // 中间40%：保持完全覆盖（黑屏）
          sweepProgress = 1.0;
        } else {
          // 后30%：从360度逆时针旋转回0度
          sweepProgress = _wipeOutAnimation.value;
        }

        return IgnorePointer(
          ignoring: true, // 不拦截UI交互
          child: Material(
            color: Colors.transparent,
            child: CustomPaint(
              painter: _WipeMaskPainter(
                sweepProgress: sweepProgress,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

/// 旋转遮罩绘制器
class _WipeMaskPainter extends CustomPainter {
  final double sweepProgress;

  _WipeMaskPainter({
    required this.sweepProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (sweepProgress <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius =
        math.sqrt(size.width * size.width + size.height * size.height) / 2;

    // 黑色遮罩画笔
    final maskPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    // 如果进度达到或超过1.0，直接绘制全屏黑色
    if (sweepProgress >= 1.0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), maskPaint);
      return;
    }

    // 创建扇形遮罩路径
    final path = Path();

    // 计算扇形角度 (从0到2π)
    final sweepAngle = 2 * math.pi * sweepProgress;

    // 从中心开始绘制扇形
    path.moveTo(center.dx, center.dy);

    // 添加扇形弧线，从12点方向(-π/2)开始顺时针
    path.arcTo(
      Rect.fromCircle(center: center, radius: maxRadius * 1.2),
      -math.pi / 2, // 从12点方向开始
      sweepAngle, // 顺时针扫过的角度
      false,
    );

    // 回到中心点闭合路径
    path.close();

    canvas.drawPath(path, maskPaint);
  }

  @override
  bool shouldRepaint(covariant _WipeMaskPainter oldDelegate) {
    return oldDelegate.sweepProgress != sweepProgress;
  }
}

/// 像素化截图转场覆盖层。
///
/// 先把旧画面逐渐放大为粗像素块，达到最大颗粒后执行场景切换并等待下一帧，
/// 再捕获新画面并从粗像素块还原到正常画面。
class _PixelTransitionOverlay extends StatefulWidget {
  final Duration duration;
  final ui.Image? oldFrame;
  final Future<ui.Image?> Function() captureFrame;
  final VoidCallback onMidTransition;
  final VoidCallback onComplete;

  const _PixelTransitionOverlay({
    required this.duration,
    required this.oldFrame,
    required this.captureFrame,
    required this.onMidTransition,
    required this.onComplete,
  });

  @override
  State<_PixelTransitionOverlay> createState() =>
      _PixelTransitionOverlayState();
}

class _PixelTransitionOverlayState extends State<_PixelTransitionOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _pixelateController;
  late final AnimationController _restoreController;
  ui.Image? _newFrame;
  bool _showNewFrame = false;
  bool _midTransitionExecuted = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();

    final halfDuration = Duration(
      milliseconds: math.max(120, widget.duration.inMilliseconds ~/ 2),
    );
    _pixelateController = AnimationController(
      duration: halfDuration,
      vsync: this,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          unawaited(_runMidTransition());
        }
      });
    _restoreController = AnimationController(
      duration: halfDuration,
      vsync: this,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _complete();
        }
      });

    _pixelateController.forward();
  }

  Future<void> _runMidTransition() async {
    if (_midTransitionExecuted) {
      return;
    }
    _midTransitionExecuted = true;

    try {
      await Future<void>.sync(widget.onMidTransition);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }

      _newFrame = await widget.captureFrame();
      if (!mounted) {
        return;
      }

      if (_newFrame == null) {
        _complete();
        return;
      }

      setState(() {
        _showNewFrame = true;
      });
      await _restoreController.forward();
    } catch (e) {
      if (kEngineDebugMode) {
        print('[PixelTransition] 转场中点处理失败: $e');
      }
      _complete();
    }
  }

  void _complete() {
    if (_completed) {
      return;
    }
    _completed = true;
    widget.onComplete();
  }

  @override
  void dispose() {
    _pixelateController.dispose();
    _restoreController.dispose();
    widget.oldFrame?.dispose();
    _newFrame?.dispose();
    super.dispose();
  }

  double _maxBlockSize(Size size) {
    if (size.isEmpty) {
      return 48.0;
    }
    return math.min(96.0, math.max(32.0, size.shortestSide * 0.12));
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _pixelateController,
            _restoreController,
          ]),
          builder: (context, child) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final image = _showNewFrame ? _newFrame : widget.oldFrame;
                if (image == null || size.isEmpty) {
                  return const SizedBox.expand();
                }

                final maxBlockSize = _maxBlockSize(size);
                final blockSize = _showNewFrame
                    ? ui.lerpDouble(
                        maxBlockSize,
                        1.0,
                        Curves.easeOutCubic.transform(
                          _restoreController.value,
                        ),
                      )!
                    : ui.lerpDouble(
                        1.0,
                        maxBlockSize,
                        Curves.easeInCubic.transform(
                          _pixelateController.value,
                        ),
                      )!;

                return CustomPaint(
                  painter: _PixelFramePainter(
                    image: image,
                    blockSize: blockSize,
                  ),
                  size: Size.infinite,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _PixelFramePainter extends CustomPainter {
  final ui.Image image;
  final double blockSize;

  const _PixelFramePainter({
    required this.image,
    required this.blockSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    final destination = Offset.zero & size;
    final source = _coverSourceRect(
      imageSize: Size(image.width.toDouble(), image.height.toDouble()),
      outputSize: size,
    );

    if (blockSize < 10.0) {
      canvas.drawImageRect(
        image,
        source,
        destination,
        Paint()..filterQuality = FilterQuality.high,
      );
      return;
    }

    final block = blockSize.clamp(10.0, 128.0).toDouble();
    final paint = Paint()..filterQuality = FilterQuality.none;

    for (double y = 0; y < size.height; y += block) {
      final drawHeight = math.min(block, size.height - y);
      for (double x = 0; x < size.width; x += block) {
        final drawWidth = math.min(block, size.width - x);
        final srcLeft = source.left + (x / size.width) * source.width;
        final srcTop = source.top + (y / size.height) * source.height;
        final srcRight =
            source.left + ((x + drawWidth) / size.width) * source.width;
        final srcBottom =
            source.top + ((y + drawHeight) / size.height) * source.height;

        canvas.drawImageRect(
          image,
          Rect.fromLTRB(srcLeft, srcTop, srcRight, srcBottom),
          Rect.fromLTWH(x, y, drawWidth, drawHeight),
          paint,
        );
      }
    }
  }

  Rect _coverSourceRect({
    required Size imageSize,
    required Size outputSize,
  }) {
    final imageAspectRatio = imageSize.width / imageSize.height;
    final outputAspectRatio = outputSize.width / outputSize.height;

    if (imageAspectRatio > outputAspectRatio) {
      final sourceWidth = imageSize.height * outputAspectRatio;
      final sourceLeft = (imageSize.width - sourceWidth) / 2.0;
      return Rect.fromLTWH(sourceLeft, 0.0, sourceWidth, imageSize.height);
    }

    final sourceHeight = imageSize.width / outputAspectRatio;
    final sourceTop = (imageSize.height - sourceHeight) / 2.0;
    return Rect.fromLTWH(0.0, sourceTop, imageSize.width, sourceHeight);
  }

  @override
  bool shouldRepaint(covariant _PixelFramePainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.blockSize != blockSize;
  }
}

/// 睁眼转场覆盖层（淡入黑屏，然后上下睁眼显示新场景）
class _BlinkTransitionOverlay extends StatefulWidget {
  final Duration duration;
  final VoidCallback onMidTransition;
  final VoidCallback onComplete;

  const _BlinkTransitionOverlay({
    required this.duration,
    required this.onMidTransition,
    required this.onComplete,
  });

  @override
  State<_BlinkTransitionOverlay> createState() =>
      _BlinkTransitionOverlayState();
}

class _BlinkTransitionOverlayState extends State<_BlinkTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeInAnimation;
  late Animation<double> _blinkOutAnimation;
  bool _midTransitionExecuted = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    // 前半段：淡入黑屏（像fade一样） (0 -> 1)
    _fadeInAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    ));

    // 后半段：睁眼（上下遮罩移开） (1 -> 0)
    _blinkOutAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
    ));

    _controller.addListener(_onAnimationUpdate);
    _controller.addStatusListener(_onAnimationStatus);

    // 开始动画
    _controller.forward();
  }

  void _onAnimationUpdate() {
    // 在动画中点（淡入黑屏完成时）执行场景切换
    if (!_midTransitionExecuted && _controller.value >= 0.5) {
      _midTransitionExecuted = true;
      widget.onMidTransition();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.value <= 0.5) {
          // 前半段：使用fade的淡入黑屏效果
          return IgnorePointer(
            ignoring: true,
            child: Material(
              color: Colors.black.withOpacity(_fadeInAnimation.value),
              child: const SizedBox(
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          );
        } else {
          // 后半段：使用睁眼的上下遮罩移开效果
          return IgnorePointer(
            ignoring: true,
            child: Material(
              color: Colors.transparent,
              child: CustomPaint(
                painter: _BlinkMaskPainter(
                  closeProgress: _blinkOutAnimation.value,
                ),
                size: Size.infinite,
              ),
            ),
          );
        }
      },
    );
  }
}

/// 睁眼遮罩绘制器
class _BlinkMaskPainter extends CustomPainter {
  final double closeProgress;

  _BlinkMaskPainter({
    required this.closeProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (closeProgress <= 0) return;

    // 计算上下遮罩的高度（从0逐渐增长到屏幕高度的一半）
    final maskHeight = (size.height / 2) * closeProgress;

    // 模糊边缘的高度（羽化效果）
    final blurHeight = size.height * 0.08; // 8%的屏幕高度作为模糊区域

    // 绘制上方黑色遮罩（从顶部向下，带模糊边缘）
    final topRect = Rect.fromLTWH(0, 0, size.width, maskHeight);
    final topGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.black,
        Colors.black,
        Colors.black.withOpacity(0.0),
      ],
      stops: [
        0.0,
        math.max(0.0, 1.0 - (blurHeight / maskHeight)),
        1.0,
      ],
    );

    final topPaint = Paint()..shader = topGradient.createShader(topRect);
    canvas.drawRect(topRect, topPaint);

    // 绘制下方黑色遮罩（从底部向上，带模糊边缘）
    final bottomRect =
        Rect.fromLTWH(0, size.height - maskHeight, size.width, maskHeight);
    final bottomGradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        Colors.black,
        Colors.black,
        Colors.black.withOpacity(0.0),
      ],
      stops: [
        0.0,
        math.max(0.0, 1.0 - (blurHeight / maskHeight)),
        1.0,
      ],
    );

    final bottomPaint = Paint()
      ..shader = bottomGradient.createShader(bottomRect);
    canvas.drawRect(bottomRect, bottomPaint);
  }

  @override
  bool shouldRepaint(covariant _BlinkMaskPainter oldDelegate) {
    return oldDelegate.closeProgress != closeProgress;
  }
}

/// 转场类型解析工具
class TransitionTypeParser {
  static TransitionType parseTransitionType(String transitionString) {
    switch (transitionString.toLowerCase().trim()) {
      case 'fade':
        return TransitionType.fade;
      case 'diss':
      case 'dissolve':
        return TransitionType.diss;
      case 'wipe':
        return TransitionType.wipe;
      case 'pixel':
      case 'pix':
      case 'pixelate':
      case 'pixelated':
        return TransitionType.pixel;
      case 'slide':
        return TransitionType.slide;
      case 'blink':
      case 'eyeopen':
      case 'eye':
        return TransitionType.blink;
      default:
        return TransitionType.fade; // 默认使用fade
    }
  }
}
