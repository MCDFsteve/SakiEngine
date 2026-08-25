import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/effects/mouse_parallax.dart';
import 'package:sakiengine/src/utils/mouse_wheel_handler.dart';
import 'package:sakiengine/src/widgets/common/common_indicator.dart';
import 'package:sakiengine/src/widgets/common/right_click_ui_manager.dart';

void main() {
  final uiManager = GlobalRightClickUIManager();

  setUp(() {
    uiManager.setUIHidden(false);
  });

  tearDown(() {
    uiManager.setUIHidden(false);
  });

  Future<void> pumpViewer(
    WidgetTester tester, {
    ValueChanged<bool>? onHiddenUiSceneTransformChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RightClickUIManager(
            onHiddenUiSceneTransformChanged: onHiddenUiSceneTransformChanged,
            backgroundChild: const ColoredBox(color: Colors.blue),
            child: const SizedBox.expand(
              child: ColoredBox(color: Colors.transparent),
            ),
          ),
        ),
      ),
    );
  }

  Future<Offset> hideUi(WidgetTester tester) async {
    final center = tester.getCenter(find.byType(RightClickUIManager));
    await tester.tapAt(
      center,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(uiManager.isUIHidden, isTrue);
    return center;
  }

  TransformationController sceneController(WidgetTester tester) {
    return tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
  }

  test('hidden UI reserves wheel and trackpad input for scene zoom', () {
    var forwardCount = 0;
    var backwardCount = 0;
    final handler = MouseWheelHandler(
      onScrollForward: () => forwardCount += 1,
      onScrollBackward: () => backwardCount += 1,
      shouldHandleScroll: () => !uiManager.isUIHidden,
    );

    uiManager.setUIHidden(true);
    handler.handlePointerSignal(
      const PointerScrollEvent(scrollDelta: Offset(0, -100)),
    );
    handler.handlePanZoomUpdate(
      const PointerPanZoomUpdateEvent(panDelta: Offset(0, -100)),
    );
    expect(forwardCount, 0);
    expect(backwardCount, 0);

    uiManager.setUIHidden(false);
    handler.handlePointerSignal(
      const PointerScrollEvent(scrollDelta: Offset(0, -100)),
    );
    handler.handlePanZoomUpdate(
      const PointerPanZoomUpdateEvent(panDelta: Offset(0, -100)),
    );
    expect(forwardCount, 0);
    expect(backwardCount, 2);
  });

  testWidgets('hidden UI supports mouse zoom, drag, and animated reset', (
    tester,
  ) async {
    await pumpViewer(tester);
    final center = await hideUi(tester);

    expect(find.byType(CommonIndicator), findsNothing);

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -180)));
    await tester.pump();

    final controller = sceneController(tester);
    final zoomAfterWheel = controller.value.getMaxScaleOnAxis();
    expect(zoomAfterWheel, greaterThan(1));
    expect(zoomAfterWheel, lessThanOrEqualTo(3));
    expect(find.byType(CommonIndicator), findsOneWidget);
    final indicator = find.byKey(
      const ValueKey('hidden_ui_scene_zoom_indicator'),
    );
    expect(tester.getTopLeft(indicator).dx, lessThan(80));
    expect(tester.getTopLeft(indicator).dy, lessThan(80));

    await tester.pump(const Duration(milliseconds: 901));
    await tester.pumpAndSettle();
    expect(find.byType(CommonIndicator), findsNothing);

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -1000)));
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), closeTo(3, 0.001));
    expect(
      tester.widget<CommonIndicator>(find.byType(CommonIndicator)).text,
      '3.00×',
    );

    final translationBeforeDrag = controller.value.getTranslation();
    await tester.dragFrom(
      center,
      const Offset(90, 45),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final translationAfterDrag = controller.value.getTranslation();
    expect(uiManager.isUIHidden, isTrue);
    expect(
      translationAfterDrag.x != translationBeforeDrag.x ||
          translationAfterDrag.y != translationBeforeDrag.y,
      isTrue,
    );

    await tester.tapAt(
      center,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(uiManager.isUIHidden, isFalse);
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));

    await tester.pumpAndSettle();
    expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
    expect(controller.value.storage[12], closeTo(0, 0.001));
    expect(controller.value.storage[13], closeTo(0, 0.001));
    expect(find.byType(CommonIndicator), findsNothing);
  });

  testWidgets('hidden UI supports trackpad and two-finger pinch zoom', (
    tester,
  ) async {
    await pumpViewer(tester);
    final center = await hideUi(tester);
    final controller = sceneController(tester);

    final trackpad = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(trackpad.panZoomStart(center));
    await tester.sendEventToBinding(
      trackpad.panZoomUpdate(
        center,
        pan: const Offset(0, -100),
      ),
    );
    await tester.sendEventToBinding(trackpad.panZoomEnd());
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));

    controller.value = Matrix4.identity();
    final firstFinger = await tester.createGesture(
      pointer: 3,
      kind: PointerDeviceKind.touch,
    );
    final secondFinger = await tester.createGesture(
      pointer: 4,
      kind: PointerDeviceKind.touch,
    );
    await firstFinger.down(center - const Offset(35, 0));
    await secondFinger.down(center + const Offset(35, 0));
    await tester.pump();
    await firstFinger.moveTo(center - const Offset(90, 0));
    await secondFinger.moveTo(center + const Offset(90, 0));
    await tester.pump();

    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(controller.value.getMaxScaleOnAxis(), lessThanOrEqualTo(3));

    await firstFinger.up();
    await secondFinger.up();
  });

  testWidgets(
    'active scene transform pauses parallax without resetting the zoom',
    (tester) async {
      final sceneTransformStates = <bool>[];
      final sceneLifecycle = _SceneLifecycleTracker();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _ZoomParallaxHarness(
              onSceneTransformChanged: sceneTransformStates.add,
              sceneLifecycle: sceneLifecycle,
            ),
          ),
        ),
      );
      expect(sceneLifecycle.initCount, 1);
      expect(sceneLifecycle.disposeCount, 0);
      final center = await hideUi(tester);
      final controller = sceneController(tester);
      final mouse = TestPointer(5, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(mouse.hover(center));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -180)));
      await tester.pump();

      expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));
      expect(sceneTransformStates, contains(true));
      expect(tester.widget<MouseParallax>(find.byType(MouseParallax)).enabled,
          isFalse);
      expect(sceneLifecycle.initCount, 1);
      expect(sceneLifecycle.disposeCount, 0);

      await tester.tapAt(
        center,
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
      expect(sceneTransformStates.last, isFalse);
      expect(tester.widget<MouseParallax>(find.byType(MouseParallax)).enabled,
          isTrue);
      expect(sceneLifecycle.initCount, 1);
      expect(sceneLifecycle.disposeCount, 0);
    },
  );
}

class _ZoomParallaxHarness extends StatefulWidget {
  const _ZoomParallaxHarness({
    required this.onSceneTransformChanged,
    required this.sceneLifecycle,
  });

  final ValueChanged<bool> onSceneTransformChanged;
  final _SceneLifecycleTracker sceneLifecycle;

  @override
  State<_ZoomParallaxHarness> createState() => _ZoomParallaxHarnessState();
}

class _ZoomParallaxHarnessState extends State<_ZoomParallaxHarness> {
  bool _hasSceneTransform = false;

  @override
  Widget build(BuildContext context) {
    return MouseParallax(
      enabled: !_hasSceneTransform,
      child: RightClickUIManager(
        onHiddenUiSceneTransformChanged: (isActive) {
          widget.onSceneTransformChanged(isActive);
          if (_hasSceneTransform == isActive) {
            return;
          }
          setState(() {
            _hasSceneTransform = isActive;
          });
        },
        backgroundChild: ParallaxAware(
          depth: 0.5,
          child: _TrackedScene(lifecycle: widget.sceneLifecycle),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SceneLifecycleTracker {
  int initCount = 0;
  int disposeCount = 0;
}

class _TrackedScene extends StatefulWidget {
  const _TrackedScene({required this.lifecycle});

  final _SceneLifecycleTracker lifecycle;

  @override
  State<_TrackedScene> createState() => _TrackedSceneState();
}

class _TrackedSceneState extends State<_TrackedScene> {
  @override
  void initState() {
    super.initState();
    widget.lifecycle.initCount += 1;
  }

  @override
  void dispose() {
    widget.lifecycle.disposeCount += 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: Colors.blue);
  }
}
