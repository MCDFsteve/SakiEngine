import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/effects/mouse_parallax.dart';

void main() {
  test('bleed scale covers the full parallax travel without distortion', () {
    const viewport = Size(1280, 720);
    const maxOffset = Offset(26, 16);
    const depth = 0.55;
    const padding = 1.0;

    final scale = resolveParallaxBleedScale(
      viewportSize: viewport,
      maxOffset: maxOffset,
      depth: depth,
      padding: padding,
    );
    final horizontalBleed = viewport.width * (scale - 1.0) / 2.0;
    final verticalBleed = viewport.height * (scale - 1.0) / 2.0;

    expect(scale, closeTo(1.02723, 0.00001));
    expect(horizontalBleed, greaterThanOrEqualTo(26 * depth + padding));
    expect(verticalBleed, greaterThanOrEqualTo(16 * depth + padding));
  });

  testWidgets('reserved bleed remains while parallax input is disabled', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: MouseParallax(
          enabled: false,
          maxOffset: Offset(26, 16),
          child: ParallaxAware(
            depth: 0.55,
            reserveBleed: true,
            child: SizedBox.expand(key: ValueKey('cg')),
          ),
        ),
      ),
    );

    final scaleTransforms = tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(ParallaxAware),
            matching: find.byType(Transform),
          ),
        )
        .where((transform) => transform.transform.getMaxScaleOnAxis() > 1.0)
        .toList();

    expect(scaleTransforms, hasLength(1));
    expect(
      scaleTransforms.single.transform.getMaxScaleOnAxis(),
      closeTo(1.02723, 0.00001),
    );
  });
}
