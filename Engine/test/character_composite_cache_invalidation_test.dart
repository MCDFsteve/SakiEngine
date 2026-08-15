import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/utils/character_composite_cache.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache clear advances the composite revision', () {
    final cache = CharacterCompositeCache.instance;
    final previousRevision = cache.revision;

    cache.clear();

    expect(cache.revision, previousRevision + 1);
  });

  test('pose invalidation advances the composite revision', () {
    final cache = CharacterCompositeCache.instance;
    final previousRevision = cache.revision;

    cache.invalidate('character', 'pose1');

    expect(cache.revision, previousRevision + 1);
  });

  test('history snapshot restore preserves the warm composite cache', () async {
    final manager = GameManager();
    addTearDown(manager.dispose);
    final cache = CharacterCompositeCache.instance;
    final previousRevision = cache.revision;

    await manager.restoreFromSnapshot(
      'start',
      GameStateSnapshot(scriptIndex: 0, currentState: GameState.initial()),
      shouldReExecute: false,
      reloadCharacterConfigs: false,
    );

    expect(cache.revision, previousRevision);
  });
}
