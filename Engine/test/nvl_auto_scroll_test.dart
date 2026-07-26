import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/widgets/nvl_screen.dart';

void main() {
  Widget buildScreen(
    List<NvlDialogue> dialogues, {
    required bool isFastForwarding,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 220,
          child: NvlScreen(
            nvlDialogues: dialogues,
            isFastForwarding: isFastForwarding,
          ),
        ),
      ),
    );
  }

  List<NvlDialogue> createInitialDialogues() {
    return List<NvlDialogue>.generate(
      6,
      (index) => NvlDialogue(
        dialogue: '旧旁白第${index + 1}行，用于先填满可视区域。',
        timestamp: DateTime(2026, 1, 1, 0, index),
      ),
    );
  }

  ScrollPosition scrollPosition(WidgetTester tester) {
    final scrollView = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    return scrollView.controller!.position;
  }

  void expectAtBottom(ScrollPosition position) {
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
    );
  }

  testWidgets('NVL keeps the latest dialogue visible after its text expands', (
    tester,
  ) async {
    final initialDialogues = createInitialDialogues();

    await tester.pumpWidget(
      buildScreen(initialDialogues, isFastForwarding: true),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final updatedDialogues = <NvlDialogue>[
      ...initialDialogues,
      NvlDialogue(
        dialogue: List<String>.filled(12, '这是需要始终完整显示的最新旁白。').join(),
        timestamp: DateTime(2026, 1, 1, 1),
      ),
    ];

    await tester.pumpWidget(
      buildScreen(updatedDialogues, isFastForwarding: true),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expectAtBottom(scrollPosition(tester));
  });

  testWidgets(
    'NVL follows the latest dialogue while the typewriter is still growing',
    (tester) async {
      final initialDialogues = createInitialDialogues();
      await tester.pumpWidget(
        buildScreen(initialDialogues, isFastForwarding: true),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pumpWidget(
        buildScreen(<NvlDialogue>[
          ...initialDialogues,
          NvlDialogue(
            dialogue: List<String>.filled(30, '这句很长的最新旁白正在逐字显示').join(),
            timestamp: DateTime(2026, 1, 1, 1),
          ),
        ], isFastForwarding: false),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump();
      await tester.pump();

      expectAtBottom(scrollPosition(tester));
    },
  );
}
