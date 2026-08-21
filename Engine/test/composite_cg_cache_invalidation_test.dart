import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/rendering/composite_cg_renderer.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/character_composite_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CG slot receives a new cache revision after invalidation', (
    tester,
  ) async {
    final manager = GameManager();
    addTearDown(manager.dispose);
    final cgCharacters = <String, CharacterState>{
      'main': CharacterState(
        resourceId: 'noe',
        pose: 'pose1',
        expression: 'happy',
      ),
    };

    late BuildContext buildContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            buildContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final initialSlot =
        CompositeCgRenderer.buildCgCharacters(
              buildContext,
              cgCharacters,
              manager,
            ).single
            as CgSlotWidget;

    CharacterCompositeCache.instance.clear();
    final refreshedSlot =
        CompositeCgRenderer.buildCgCharacters(
              buildContext,
              cgCharacters,
              manager,
            ).single
            as CgSlotWidget;

    expect(refreshedSlot.cacheRevision, initialSlot.cacheRevision + 1);
  });
}
