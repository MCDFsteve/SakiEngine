import 'package:flutter/material.dart';
import 'dart:math' as math;

class IndicatorWidget extends StatefulWidget {
  final double size;

  const IndicatorWidget({Key? key, required this.size}) : super(key: key);

  @override
  _IndicatorWidgetState createState() => _IndicatorWidgetState();
}

class _IndicatorWidgetState extends State<IndicatorWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  // <<< Define animation parameters >>>
  static const tapDownDurationMs = 80; // Duration of tap down
  static const tapUpDurationMs = 120; // Duration of return up
  static const pauseDurationMs = 700; // Duration of the pause
  static const delayBetweenTapsMs = 50; // Small delay between the two taps
  static const floatDurationMs = 500; // Duration of one float direction
  static const floatPauseMs = 100; // Short pause before float starts

  static const totalDurationMs = 
      pauseDurationMs + 
      tapDownDurationMs + tapUpDurationMs + 
      delayBetweenTapsMs + 
      tapDownDurationMs + tapUpDurationMs + 
      floatPauseMs + 
      (floatDurationMs * 4); // Two full float cycles

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: totalDurationMs),
      vsync: this,
    )..repeat(); // Just repeat, sequence handles timing

    _updateAnimation(); // Initial animation setup
  }
  
  @override
  void didUpdateWidget(covariant IndicatorWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.size != oldWidget.size) {
      // Update animation if size changes
      _updateAnimation();
    }
  }

  void _updateAnimation() {
     // Calculate distances based on current size
     final moveDistance = widget.size * 0.25; 
     final floatDistance = moveDistance * 0.6; 

     // <<< Define complex TweenSequence mimicking original Flame effect >>>
     _animation = TweenSequence<double>([
        // 1. Initial Pause
        TweenSequenceItem(
          tween: ConstantTween<double>(0.0),
          weight: pauseDurationMs.toDouble(),
        ),
        // 2. First Tap Down
        TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: moveDistance).chain(CurveTween(curve: Curves.easeOut)),
          weight: tapDownDurationMs.toDouble(),
        ),
        // 3. First Tap Up (Return)
        TweenSequenceItem(
          tween: Tween<double>(begin: moveDistance, end: 0.0).chain(CurveTween(curve: Curves.easeIn)),
          weight: tapUpDurationMs.toDouble(),
        ),
        // 4. Short Pause Between Taps
        TweenSequenceItem(
          tween: ConstantTween<double>(0.0),
          weight: delayBetweenTapsMs.toDouble(),
        ),
        // 5. Second Tap Down
        TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: moveDistance).chain(CurveTween(curve: Curves.easeOut)),
          weight: tapDownDurationMs.toDouble(),
        ),
        // 6. Second Tap Up (Return)
        TweenSequenceItem(
          tween: Tween<double>(begin: moveDistance, end: 0.0).chain(CurveTween(curve: Curves.easeIn)),
          weight: tapUpDurationMs.toDouble(),
        ),
        // 7. Pause before float
        TweenSequenceItem(
          tween: ConstantTween<double>(0.0),
          weight: floatPauseMs.toDouble(),
        ),
        // 8. Float Down (1st time)
        TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: floatDistance).chain(CurveTween(curve: Curves.easeInOut)),
          weight: floatDurationMs.toDouble(),
        ),
        // 9. Float Up (Return) (1st time)
        TweenSequenceItem(
          tween: Tween<double>(begin: floatDistance, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)),
          weight: floatDurationMs.toDouble(),
        ),
        // 10. Float Down (2nd time)
         TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: floatDistance).chain(CurveTween(curve: Curves.easeInOut)),
          weight: floatDurationMs.toDouble(),
        ),
        // 11. Float Up (Return) (2nd time)
        TweenSequenceItem(
          tween: Tween<double>(begin: floatDistance, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)),
          weight: floatDurationMs.toDouble(),
        ),
     ]).animate(_controller);
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
        return Transform.translate(
          offset: Offset(0, _animation.value),
          child: Icon(
            Icons.keyboard_arrow_down,
            size: widget.size,
            color: Colors.white.withOpacity(0.7),
          ),
        );
      },
    );
  }
} 