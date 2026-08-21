import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/effects/scene_transition_effects.dart';

Future<ui.Image> _solidImage(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(8, 8);
}

void main() {
  testWidgets(
    'pixel transition stays inside the captured game viewport',
    (tester) async {
      final gameViewportKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 60, child: ColoredBox(color: Colors.red)),
              Expanded(
                child: RepaintBoundary(
                  key: gameViewportKey,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      );

      final oldFrame = await _solidImage(Colors.black);
      final newFrame = await _solidImage(Colors.blue);
      var captureCount = 0;
      final transition = SceneTransitionEffectManager.instance.transition(
        context: gameViewportKey.currentContext!,
        transitionType: TransitionType.pixel,
        duration: const Duration(milliseconds: 240),
        captureFrame: () async {
          captureCount++;
          return captureCount == 1 ? oldFrame : newFrame;
        },
        onMidTransition: () {},
      );

      await tester.pump();
      await tester.pump();

      expect(
        tester.getRect(
          find.byKey(
            const ValueKey<String>('pixel_transition_overlay'),
          ),
        ),
        const Rect.fromLTWH(0, 60, 800, 540),
      );

      await tester.pumpAndSettle();
      await transition;
    },
  );

  testWidgets(
    'diss keeps the captured old scene visible until the target frame is ready',
    (tester) async {
      late BuildContext overlayContext;
      late StateSetter updateScene;
      var targetSceneVisible = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              overlayContext = context;
              updateScene = setState;
              return ColoredBox(
                color: targetSceneVisible ? Colors.blue : Colors.black,
              );
            },
          ),
        ),
      );

      final oldFrame = await _solidImage(Colors.red);
      final newFrame = await _solidImage(Colors.blue);
      final newFrameCompleter = Completer<ui.Image?>();
      final events = <String>[];
      var captureCount = 0;

      final transition = SceneTransitionEffectManager.instance.transition(
        context: overlayContext,
        transitionType: TransitionType.diss,
        duration: const Duration(milliseconds: 100),
        oldBackground: 'old-scene',
        newBackground: 'new-scene',
        captureFrame: () {
          captureCount++;
          events.add('capture-$captureCount');
          if (captureCount == 1) {
            return Future<ui.Image?>.value(oldFrame);
          }
          return newFrameCompleter.future;
        },
        onMidTransition: () {
          events.add('commit-target');
          updateScene(() {
            targetSceneVisible = true;
          });
        },
      );

      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(events, <String>['capture-1', 'commit-target', 'capture-2']);
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((widget) => identical(widget.image, oldFrame)),
        isTrue,
      );
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((widget) => identical(widget.image, newFrame)),
        isFalse,
      );

      newFrameCompleter.complete(newFrame);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        final hasNewFrame = tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((widget) => identical(widget.image, newFrame));
        if (hasNewFrame) {
          break;
        }
      }

      final transitionImages =
          tester.widgetList<RawImage>(find.byType(RawImage)).toList();
      expect(
        transitionImages.any((widget) => identical(widget.image, oldFrame)),
        isTrue,
      );
      expect(
        transitionImages.any((widget) => identical(widget.image, newFrame)),
        isTrue,
      );

      await tester.pumpAndSettle();
      await transition;
      expect(find.byType(RawImage), findsNothing);
    },
  );
}
