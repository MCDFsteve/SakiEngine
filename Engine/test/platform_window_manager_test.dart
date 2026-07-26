import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/utils/platform_window_manager_io.dart';

void main() {
  group('PlatformWindowManager macOS content sizing', () {
    test('measures the title bar outside the Flutter content view', () {
      final inset = PlatformWindowManager.resolveWindowFrameVerticalInset(
        windowFrameSize: const Size(1024, 576),
        contentSize: const Size(1024, 551),
      );

      expect(inset, 25);
    });

    test('ignores invalid or stale content measurements', () {
      expect(
        PlatformWindowManager.resolveWindowFrameVerticalInset(
          windowFrameSize: const Size(1024, 576),
          contentSize: Size.zero,
        ),
        0,
      );
      expect(
        PlatformWindowManager.resolveWindowFrameVerticalInset(
          windowFrameSize: const Size(1024, 576),
          contentSize: const Size(1024, 300),
        ),
        0,
      );
    });

    test('startup bounds preserve the content aspect ratio', () {
      final bounds = PlatformWindowManager.resolveStartupWindowBounds(
        visibleDisplayBounds: const Rect.fromLTWH(0, 0, 1024, 640),
        aspectRatio: 16 / 9,
        fillFraction: 0.9,
        reservedVerticalHeight: 25,
      );

      expect(bounds, const Rect.fromLTWH(51, 49, 922, 543));
      expect(bounds.width / (bounds.height - 25), closeTo(16 / 9, 0.003));
    });
  });
}
