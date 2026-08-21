import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/widgets/expression_focus_preview.dart';

void main() {
  group('findExpressionDifferenceBounds', () {
    test('ignores RGB values under fully transparent expression pixels', () {
      final base = _solidPixels(
        width: 10,
        height: 10,
        red: 80,
        green: 90,
        blue: 100,
        alpha: 255,
      );
      final overlayBytes = Uint8List(10 * 10 * 4);
      for (var index = 0; index < 10 * 10; index++) {
        overlayBytes[index * 4] = 255;
        overlayBytes[index * 4 + 1] = 30;
        overlayBytes[index * 4 + 2] = 200;
      }
      _fillRect(
        overlayBytes,
        imageWidth: 10,
        left: 4,
        top: 3,
        right: 6,
        bottom: 5,
        red: 220,
        green: 20,
        blue: 40,
        alpha: 255,
      );

      final bounds = findExpressionDifferenceBounds(
        base: base,
        overlay: ExpressionPreviewPixels(
          width: 10,
          height: 10,
          rgba: overlayBytes,
        ),
      );

      expect(bounds, const ui.Rect.fromLTRB(4, 3, 6, 5));
    });

    test('removes isolated export noise outside the changed face region', () {
      final base = _solidPixels(
        width: 40,
        height: 40,
        red: 120,
        green: 120,
        blue: 120,
        alpha: 255,
      );
      final overlayBytes = Uint8List.fromList(base.rgba);
      _fillRect(
        overlayBytes,
        imageWidth: 40,
        left: 10,
        top: 8,
        right: 30,
        bottom: 28,
        red: 200,
        green: 40,
        blue: 80,
        alpha: 255,
      );
      _fillRect(
        overlayBytes,
        imageWidth: 40,
        left: 39,
        top: 39,
        right: 40,
        bottom: 40,
        red: 255,
        green: 255,
        blue: 255,
        alpha: 255,
      );

      final bounds = findExpressionDifferenceBounds(
        base: base,
        overlay: ExpressionPreviewPixels(
          width: 40,
          height: 40,
          rgba: overlayBytes,
        ),
      );

      expect(bounds, const ui.Rect.fromLTRB(10, 8, 30, 28));
    });

    test('maps expression offsets into the pose canvas', () {
      final base = _solidPixels(
        width: 20,
        height: 20,
        red: 0,
        green: 0,
        blue: 0,
        alpha: 255,
      );
      final overlayBytes = Uint8List(20 * 20 * 4);
      _fillRect(
        overlayBytes,
        imageWidth: 20,
        left: 0,
        top: 0,
        right: 4,
        bottom: 4,
        red: 255,
        green: 255,
        blue: 255,
        alpha: 255,
      );

      final bounds = findExpressionDifferenceBounds(
        base: base,
        overlay: ExpressionPreviewPixels(
          width: 20,
          height: 20,
          rgba: overlayBytes,
        ),
        transform: const ExpressionPreviewTransform(
          xOffset: 0.25,
          yOffset: 0.2,
        ),
      );

      expect(bounds, const ui.Rect.fromLTRB(5, 4, 9, 8));
    });
  });

  test('fitExpressionFocusRect keeps the focus visible near canvas edges', () {
    final result = fitExpressionFocusRect(
      focusBounds: const ui.Rect.fromLTRB(90, 90, 100, 100),
      canvasSize: const ui.Size(100, 100),
      viewportSize: const ui.Size(200, 100),
      paddingFraction: 0.2,
    );

    expect(result.right, 100);
    expect(result.bottom, 100);
    expect(result.contains(const ui.Offset(95, 95)), isTrue);
    expect(result.width / result.height, closeTo(2, 0.001));
  });
}

ExpressionPreviewPixels _solidPixels({
  required int width,
  required int height,
  required int red,
  required int green,
  required int blue,
  required int alpha,
}) {
  final bytes = Uint8List(width * height * 4);
  _fillRect(
    bytes,
    imageWidth: width,
    left: 0,
    top: 0,
    right: width,
    bottom: height,
    red: red,
    green: green,
    blue: blue,
    alpha: alpha,
  );
  return ExpressionPreviewPixels(width: width, height: height, rgba: bytes);
}

void _fillRect(
  Uint8List bytes, {
  required int imageWidth,
  required int left,
  required int top,
  required int right,
  required int bottom,
  required int red,
  required int green,
  required int blue,
  required int alpha,
}) {
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final offset = (y * imageWidth + x) * 4;
      bytes[offset] = red;
      bytes[offset + 1] = green;
      bytes[offset + 2] = blue;
      bytes[offset + 3] = alpha;
    }
  }
}
