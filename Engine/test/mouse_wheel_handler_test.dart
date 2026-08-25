import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/mouse_wheel_handler.dart';

void main() {
  group('MouseWheelHandler story navigation direction', () {
    test('scrolling down advances the story', () {
      var forwardCount = 0;
      var backwardCount = 0;
      final handler = MouseWheelHandler(
        onScrollForward: () => forwardCount += 1,
        onScrollBackward: () => backwardCount += 1,
      );

      handler.handlePointerSignal(
        const PointerScrollEvent(scrollDelta: Offset(0, 100)),
      );

      expect(forwardCount, 1);
      expect(backwardCount, 0);
    });

    test('scrolling up rolls back or opens history', () {
      var forwardCount = 0;
      var backwardCount = 0;
      final handler = MouseWheelHandler(
        onScrollForward: () => forwardCount += 1,
        onScrollBackward: () => backwardCount += 1,
      );

      handler.handlePointerSignal(
        const PointerScrollEvent(scrollDelta: Offset(0, -100)),
      );

      expect(forwardCount, 0);
      expect(backwardCount, 1);
    });

    test('trackpad vertical gestures use the same direction mapping', () {
      var forwardCount = 0;
      var backwardCount = 0;
      final handler = MouseWheelHandler(
        onScrollForward: () => forwardCount += 1,
        onScrollBackward: () => backwardCount += 1,
      );

      handler.handlePanZoomUpdate(
        const PointerPanZoomUpdateEvent(panDelta: Offset(0, 100)),
      );
      handler.handlePanZoomUpdate(
        const PointerPanZoomUpdateEvent(panDelta: Offset(0, -100)),
      );

      expect(forwardCount, 1);
      expect(backwardCount, 1);
    });
  });
}
