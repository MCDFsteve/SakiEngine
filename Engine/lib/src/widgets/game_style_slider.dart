import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';

class GameStyleSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final double scale;
  final SakiEngineConfig config;
  final String? label;
  final bool showValue;

  const GameStyleSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.scale,
    required this.config,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.showValue = true,
  });

  @override
  State<GameStyleSlider> createState() => _GameStyleSliderState();
}

class _GameStyleSliderState extends State<GameStyleSlider>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _pulseController;
  late AnimationController _dragController;
  late AnimationController _hoverPulseController;
  late Animation<double> _glowAnimation;
  late Animation<double> _pulseAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Color?> _trackColorAnimation;
  late Animation<double> _hoverPulseAnimation;

  bool _isDragging = false;
  bool _isHovered = false;
  double? _dragValue;

  @override
  void initState() {
    super.initState();

    // 主动画控制器
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // 脉冲动画控制器
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    // 拖拽动画控制器
    _dragController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );

    // 悬浮脉冲动画控制器
    _hoverPulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    // 发光动画
    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    // 脉冲动画
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 拖拽时的缩放动画
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _dragController, curve: Curves.elasticOut),
    );

    // 轨道颜色动画
    _trackColorAnimation =
        ColorTween(
          begin: widget.config.themeColors.onSurfaceVariant.withOpacity(0.3),
          end: widget.config.themeColors.primary.withOpacity(0.6),
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        );

    // 悬浮脉冲动画
    _hoverPulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _hoverPulseController, curve: Curves.easeInOut),
    );

    // 启动脉冲动画
    _pulseController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(GameStyleSlider oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 重新初始化颜色动画以响应主题变化
    _trackColorAnimation =
        ColorTween(
          begin: widget.config.themeColors.onSurfaceVariant.withOpacity(0.3),
          end: widget.config.themeColors.primary.withOpacity(0.6),
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeInOut,
          ),
        );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _pulseController.dispose();
    _dragController.dispose();
    _hoverPulseController.dispose();
    super.dispose();
  }

  void _handleDragStart() {
    setState(() => _isDragging = true);
    _animationController.forward();
    _dragController.forward();
  }

  void _handleDragEnd() {
    setState(() => _isDragging = false);
    _animationController.reverse();
    _dragController.reverse();
  }

  void _handleTapValue(double value) {
    widget.onChanged(value);
    widget.onChangeEnd?.call(value);
  }

  void _handlePanEnd() {
    final value = _dragValue ?? widget.value;
    _dragValue = null;
    _handleDragEnd();
    widget.onChangeEnd?.call(value);
  }

  double get _normalizedValue {
    return (widget.value - widget.min) / (widget.max - widget.min);
  }

  @override
  Widget build(BuildContext context) {
    final sliderHeight = 56 * widget.scale;
    final trackHeight = 16 * widget.scale;
    final thumbSize = 32 * widget.scale;

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _hoverPulseController.repeat(reverse: true);
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _hoverPulseController.stop();
        _hoverPulseController.reset();
      },
      child: Container(
        width: double.infinity,
        height: sliderHeight + 32 * widget.scale,
        padding: EdgeInsets.symmetric(
          horizontal: thumbSize / 2,
          vertical: 16 * widget.scale,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth;

            return AnimatedBuilder(
              animation: Listenable.merge([
                _animationController,
                _pulseController,
                _dragController,
                _hoverPulseController,
              ]),
              builder: (context, child) {
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    // 背景轨道（可点击）
                    GestureDetector(
                      onTapDown: (details) {
                        final RenderBox box =
                            context.findRenderObject() as RenderBox;
                        final localPosition = box.globalToLocal(
                          details.globalPosition,
                        );
                        final adjustedPosition =
                            localPosition.dx - thumbSize / 2;
                        final progress = (adjustedPosition / availableWidth)
                            .clamp(0.0, 1.0);
                        final newValue =
                            widget.min + (widget.max - widget.min) * progress;

                        if (widget.divisions != null) {
                          final step =
                              (widget.max - widget.min) / widget.divisions!;
                          final roundedValue = (newValue / step).round() * step;
                          _handleTapValue(
                            roundedValue.clamp(widget.min, widget.max),
                          );
                        } else {
                          _handleTapValue(newValue);
                        }

                        // 添加点击反馈动画
                        _handleDragStart();
                        Future.delayed(const Duration(milliseconds: 150), () {
                          _handleDragEnd();
                        });
                      },
                      child: Container(
                        width: availableWidth,
                        height: trackHeight,
                        decoration: BoxDecoration(
                          color: widget.config.themeColors.surface.withOpacity(
                            0.5,
                          ),
                          border: Border.all(
                            color: _isHovered || _isDragging
                                ? widget.config.themeColors.primary.withOpacity(
                                    0.6,
                                  )
                                : widget.config.themeColors.primary.withOpacity(
                                    0.3,
                                  ),
                            width: 2 * widget.scale,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 2 * widget.scale,
                              offset: Offset(0, 1 * widget.scale),
                            ),
                          ],
                        ),
                        child: Container(
                          margin: EdgeInsets.all(2 * widget.scale),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(0.05),
                                Colors.transparent,
                                Colors.white.withOpacity(0.05),
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 进度轨道（也可点击）
                    Positioned(
                      left: 0,
                      child: GestureDetector(
                        onTapDown: (details) {
                          final RenderBox box =
                              context.findRenderObject() as RenderBox;
                          final localPosition = box.globalToLocal(
                            details.globalPosition,
                          );
                          final adjustedPosition =
                              localPosition.dx - thumbSize / 2;
                          final progress = (adjustedPosition / availableWidth)
                              .clamp(0.0, 1.0);
                          final newValue =
                              widget.min + (widget.max - widget.min) * progress;

                          if (widget.divisions != null) {
                            final step =
                                (widget.max - widget.min) / widget.divisions!;
                            final roundedValue =
                                (newValue / step).round() * step;
                            _handleTapValue(
                              roundedValue.clamp(widget.min, widget.max),
                            );
                          } else {
                            _handleTapValue(newValue);
                          }

                          // 添加点击反馈动画
                          _handleDragStart();
                          Future.delayed(const Duration(milliseconds: 150), () {
                            _handleDragEnd();
                          });
                        },
                        child: Container(
                          width: availableWidth * _normalizedValue,
                          height: trackHeight,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                _trackColorAnimation.value!.withOpacity(0.6),
                                _trackColorAnimation.value!.withOpacity(0.9),
                              ],
                              stops: const [0.0, 1.0],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: widget.config.themeColors.primary
                                    .withOpacity(
                                      0.3 *
                                          _glowAnimation.value *
                                          _pulseAnimation.value,
                                    ),
                                blurRadius:
                                    8 * widget.scale * _pulseAnimation.value,
                                offset: Offset(0, 0),
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withOpacity(0.1),
                                  Colors.transparent,
                                  Colors.black.withOpacity(0.1),
                                ],
                                stops: const [0.0, 0.5, 1.0],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 拖拽滑块
                    Positioned(
                      left: (availableWidth - thumbSize) * _normalizedValue,
                      child: GestureDetector(
                        onPanStart: (_) {
                          _dragValue = widget.value;
                          _handleDragStart();
                        },
                        onPanEnd: (_) => _handlePanEnd(),
                        onPanCancel: _handlePanEnd,
                        onPanUpdate: (details) {
                          final RenderBox box =
                              context.findRenderObject() as RenderBox;
                          final localPosition = box.globalToLocal(
                            details.globalPosition,
                          );
                          final adjustedPosition =
                              localPosition.dx - thumbSize / 2;
                          final progress = (adjustedPosition / availableWidth)
                              .clamp(0.0, 1.0);
                          final newValue =
                              widget.min + (widget.max - widget.min) * progress;

                          if (widget.divisions != null) {
                            final step =
                                (widget.max - widget.min) / widget.divisions!;
                            final roundedValue =
                                (newValue / step).round() * step;
                            _dragValue = roundedValue.clamp(
                              widget.min,
                              widget.max,
                            );
                          } else {
                            _dragValue = newValue;
                          }
                          widget.onChanged(_dragValue!);
                        },
                        child: Transform.scale(
                          scale:
                              (1.0 +
                                  0.1 * _scaleAnimation.value +
                                  (_isHovered && !_isDragging ? 0.05 : 0.0)) *
                              (_isHovered && !_isDragging
                                  ? _hoverPulseAnimation.value
                                  : 1.0),
                          child: Container(
                            width: thumbSize,
                            height: thumbSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.config.themeColors.background,
                              border: Border.all(
                                color: widget.config.themeColors.primary
                                    .withOpacity(0.9),
                                width: 3 * widget.scale,
                              ),
                              boxShadow: [
                                // 基础阴影
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 6 * widget.scale,
                                  offset: Offset(0, 3 * widget.scale),
                                ),
                                // 脉冲发光
                                BoxShadow(
                                  color: widget.config.themeColors.primary
                                      .withOpacity(
                                        0.4 *
                                            _glowAnimation.value *
                                            _pulseAnimation.value,
                                      ),
                                  blurRadius:
                                      12 * widget.scale * _pulseAnimation.value,
                                  offset: Offset(0, 0),
                                ),
                                // 悬浮时额外发光
                                if (_isHovered && !_isDragging)
                                  BoxShadow(
                                    color: widget.config.themeColors.primary
                                        .withOpacity(
                                          0.3 * _hoverPulseAnimation.value,
                                        ),
                                    blurRadius:
                                        8 *
                                        widget.scale *
                                        _hoverPulseAnimation.value,
                                    offset: Offset(0, 0),
                                  ),
                                // 拖拽时额外发光
                                if (_isDragging)
                                  BoxShadow(
                                    color: widget.config.themeColors.primary
                                        .withOpacity(0.6),
                                    blurRadius: 16 * widget.scale,
                                    offset: Offset(0, 0),
                                  ),
                              ],
                            ),
                            child: Center(
                              child: AnimatedBuilder(
                                animation: _pulseController,
                                builder: (context, child) {
                                  return Transform.scale(
                                    scale: _isDragging
                                        ? 1.0
                                        : (_isHovered
                                              ? _hoverPulseAnimation.value *
                                                        0.1 +
                                                    0.9
                                              : _pulseAnimation.value * 0.3 +
                                                    0.7),
                                    child: Container(
                                      width: thumbSize * 0.5,
                                      height: thumbSize * 0.5,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: RadialGradient(
                                          colors: [
                                            widget.config.themeColors.primary
                                                .withOpacity(0.9),
                                            widget.config.themeColors.primary
                                                .withOpacity(0.6),
                                            widget.config.themeColors.primary
                                                .withOpacity(0.3),
                                          ],
                                          stops: const [0.0, 0.7, 1.0],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: widget
                                                .config
                                                .themeColors
                                                .primary
                                                .withOpacity(0.8),
                                            blurRadius: 4 * widget.scale,
                                            offset: Offset(0, 0),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 值显示（如果启用）
                    if (widget.showValue)
                      Positioned(
                        top: -32 * widget.scale, // 调整位置避免被裁剪
                        left:
                            (availableWidth - 60 * widget.scale) *
                                _normalizedValue +
                            30 * widget.scale,
                        child: AnimatedOpacity(
                          opacity: _isDragging || _isHovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Container(
                            width: 60 * widget.scale,
                            padding: EdgeInsets.symmetric(
                              horizontal: 8 * widget.scale,
                              vertical: 4 * widget.scale,
                            ),
                            decoration: BoxDecoration(
                              color: widget.config.themeColors.background
                                  .withOpacity(0.95),
                              border: Border.all(
                                color: widget.config.themeColors.primary
                                    .withOpacity(0.5),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 6 * widget.scale,
                                  offset: Offset(0, 2 * widget.scale),
                                ),
                              ],
                            ),
                            child: Text(
                              widget.divisions != null
                                  ? '${(widget.value * 100).round()}%'
                                  : widget.value.toStringAsFixed(2),
                              textAlign: TextAlign.center,
                              style: widget.config.dialogueTextStyle.copyWith(
                                fontSize:
                                    widget.config.dialogueTextStyle.fontSize! *
                                    widget.scale *
                                    0.5,
                                color: widget.config.themeColors.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}
