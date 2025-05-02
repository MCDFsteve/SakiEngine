import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:flame/effects.dart';

// --- Indicator Component ---
class IndicatorComponent extends PositionComponent {
  double indicatorSize;
  final Paint _paint = Paint();
  late Path _path; // Chevron path

  IndicatorComponent({required double size}) : indicatorSize = size {
     this.size = Vector2.all(indicatorSize); // Set component size
  }

  @override
  Future<void> onLoad() async {
    super.onLoad();
    _updatePathAndPaint();
    _addPulseEffect();
  }

  // Method to update size externally if needed
  void updateSize(double newSize) {
    if (indicatorSize != newSize) {
      indicatorSize = newSize;
      this.size = Vector2.all(indicatorSize); // Update component size
      _updatePathAndPaint();
       // Re-apply effect if size changes significantly?
       // For now, let's assume effect adapts or restart it.
       removeAll(children.whereType<Effect>()); // Remove old effect
       _addPulseEffect(); // Add new one
    }
  }

  void _updatePathAndPaint() {
    // Create a chevron shape pointing down
    final halfW = indicatorSize * 0.5;
    final quarterH = indicatorSize * 0.25; // Adjust vertical position/thickness
    _path = Path()
      ..moveTo(0, quarterH)       // Top-left point
      ..lineTo(halfW, indicatorSize - quarterH) // Bottom point
      ..lineTo(indicatorSize, quarterH); // Top-right point

    _paint.color = Colors.white.withOpacity(0.85); // Solid white with slight transparency
    _paint.style = PaintingStyle.fill; // Ensure it's filled

  }

  void _addPulseEffect() {
    // Remove old effect if any (important if updateSize recalls this)
    removeAll(children.whereType<Effect>());

    final moveDistance = indicatorSize * 0.25; // How far down it taps
    final tapDownDuration = 0.08; // Duration of tap down
    final tapUpDuration = 0.12; // Duration of return up
    final pauseDuration = 0.7; // Duration of the pause
    final delayBetweenTaps = 0.05; // Small delay between the two taps
    final floatDistance = moveDistance * 0.6; // How far it floats
    final floatDuration = 0.5; // Duration of one float direction
    final floatPause = 0.1; // Short pause before float starts

    final effect = SequenceEffect([
      // 1. Pause
      MoveByEffect(Vector2.zero(), EffectController(duration: pauseDuration)),
      // 2. First Tap Down
      MoveByEffect(Vector2(0, moveDistance), EffectController(duration: tapDownDuration, curve: Curves.easeOut)),
      // 3. First Tap Up (Return)
      MoveByEffect(Vector2(0, -moveDistance), EffectController(duration: tapUpDuration, curve: Curves.easeIn)),
      // 4. Short Pause Between Taps
      MoveByEffect(Vector2.zero(), EffectController(duration: delayBetweenTaps)),
      // 5. Second Tap Down
      MoveByEffect(Vector2(0, moveDistance), EffectController(duration: tapDownDuration, curve: Curves.easeOut)),
      // 6. Second Tap Up (Return)
      MoveByEffect(Vector2(0, -moveDistance), EffectController(duration: tapUpDuration, curve: Curves.easeIn)),
      
      // --- Float Animation ---
      // 7. Pause before float
      MoveByEffect(Vector2.zero(), EffectController(duration: floatPause)),
      // 8. Float Down (1st time)
      MoveByEffect(
        Vector2(0, floatDistance),
        EffectController(duration: floatDuration, curve: Curves.easeInOut),
      ),
      // 9. Float Up (Return) (1st time)
      MoveByEffect(
        Vector2(0, -floatDistance),
        EffectController(duration: floatDuration, curve: Curves.easeInOut),
      ),
      // 10. Float Down (2nd time)
      MoveByEffect(
        Vector2(0, floatDistance),
        EffectController(duration: floatDuration, curve: Curves.easeInOut),
      ),
      // 11. Float Up (Return) (2nd time)
      MoveByEffect(
        Vector2(0, -floatDistance),
        EffectController(duration: floatDuration, curve: Curves.easeInOut),
      ),
      // --- End Float Animation ---
    ], infinite: true);

    add(effect);
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    // Path is defined relative to the component's 0,0 origin
    canvas.drawPath(_path, _paint);
  }
} 