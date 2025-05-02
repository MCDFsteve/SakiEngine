import 'dart:ui';
import 'package:flutter/foundation.dart'; // Import ChangeNotifier
import 'dart:math'; // Import math library for min function

/// Calculates sizes based on the largest 16:9 rectangle that fits within the actual screen size.
/// Notifies listeners when the fitted size changes.
class AdaptiveSizer with ChangeNotifier { // Use 'with ChangeNotifier'
  // Singleton instance
  static final AdaptiveSizer instance = AdaptiveSizer._();

  // Private constructor
  AdaptiveSizer._();

  // Design size - make it accessible via getter
  final Size _designSize = const Size(1920, 1080);
  Size get designSize => _designSize;

  // Holds the calculated size of the fitted 16:9 area based on the last update
  Size _fitted16x9Size = const Size(1920, 1080); // Initialize with default

  /// Updates the internal fitted size based on the actual screen size.
  /// This should be called whenever the screen size changes (e.g., via LayoutBuilder).
  void updateSizes(Size actualScreenSize) {
    if (actualScreenSize.isEmpty) {
      // Avoid division by zero or nonsensical calculations if size is invalid
      return;
    }

    const double aspect16x9 = 16.0 / 9.0;
    final double screenAspect = actualScreenSize.width / actualScreenSize.height;

    double targetWidth;
    double targetHeight;

    if (screenAspect > aspect16x9) {
      // Screen is wider than 16:9 (letterbox top/bottom)
      // Height is the constraint
      targetHeight = actualScreenSize.height;
      targetWidth = targetHeight * aspect16x9;
    } else {
      // Screen is taller than or equal to 16:9 (pillarbox left/right, or exact match)
      // Width is the constraint
      targetWidth = actualScreenSize.width;
      targetHeight = targetWidth / aspect16x9;
    }

    // Calculate the new size
    Size newFittedSize = _fitted16x9Size; // Default to old value
    if (targetWidth > 0 && targetHeight > 0) {
       newFittedSize = Size(targetWidth, targetHeight);
    }

    // Only update and notify if the size actually changed
    if (_fitted16x9Size != newFittedSize) {
      _fitted16x9Size = newFittedSize;
      notifyListeners(); // Notify listeners about the change
    }
  }

  /// The width of the largest 16:9 rectangle that fits the current screen.
  double get fittedWidth => _fitted16x9Size.width;

  /// The height of the largest 16:9 rectangle that fits the current screen.
  double get fittedHeight => _fitted16x9Size.height;
}

/// Extension methods on num to provide convenient sizing based on the AdaptiveSizer.
extension AdaptiveSizerExt on num {
  /// Calculates a height relative to the current fitted 16:9 height.
  /// e.g., 0.1.sh is 10% of the fitted 16:9 height.
  double get sh => this * AdaptiveSizer.instance.fittedHeight;

  /// Calculates a width relative to the current fitted 16:9 width.
  /// e.g., 0.1.sw is 10% of the fitted 16:9 width.
  double get sw => this * AdaptiveSizer.instance.fittedWidth;

  /// Calculates a font size scaled relative to the design size,
  /// using the minimum of the width and height scaling factors for better adaptability.
  double get sp {
    final double fittedW = AdaptiveSizer.instance.fittedWidth;
    final double fittedH = AdaptiveSizer.instance.fittedHeight;
    final double designW = AdaptiveSizer.instance.designSize.width;
    final double designH = AdaptiveSizer.instance.designSize.height;

    // Prevent division by zero
    if (designW <= 0 || designH <= 0) return toDouble();

    // Calculate both width and height scale factors
    final double scaleW = fittedW / designW;
    final double scaleH = fittedH / designH;

    // Use the smaller scale factor to ensure text fits well in both dimensions
    final double scaleFactor = min(scaleW, scaleH);

    return this * scaleFactor;
  }
} 