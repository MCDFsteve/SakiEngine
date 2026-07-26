import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/core/game_module.dart';
import 'package:sakiengine/src/core/module_registry.dart';
import 'package:sakiengine/src/core/project_module_loader.dart';
import 'package:sakiengine/src/screens/game_play_screen.dart';
import 'package:sakiengine/src/widgets/common/virtual_game_canvas.dart';

class _FakeModuleA extends DefaultGameModule {}

class _FakeModuleB extends DefaultGameModule {}

void main() {
  setUp(() {
    moduleLoader.resetForTest();
  });

  test('registerProjectModule should register normalized key', () {
    registerProjectModule('MyGame', () => _FakeModuleA());

    expect(moduleLoader.hasCustomModule('mygame'), isTrue);
    expect(moduleLoader.hasCustomModule('MYGAME'), isTrue);
    expect(moduleLoader.getRegisteredModules(), contains('mygame'));
  });

  test('registerProjectModule should overwrite duplicated key', () {
    registerProjectModule('MyGame', () => _FakeModuleA());
    registerProjectModule('mygame', () => _FakeModuleB());

    expect(moduleLoader.getRegisteredModules().length, 1);
    expect(moduleLoader.hasCustomModule('mygame'), isTrue);
  });

  test('default game module does not pass initial loading overlay builder', () {
    final screen = DefaultGameModule().createGamePlayScreen();
    final gameScreen = (screen as SakiVirtualGameCanvas).child;

    expect(gameScreen, isA<GamePlayScreen>());
    expect(
      (gameScreen as GamePlayScreen).initialLoadingOverlayBuilder,
      isNull,
    );
  });

  test('default game module starts new games from start', () {
    expect(DefaultGameModule().initialScript, 'start');
  });

  test('default game module keeps the global quick save namespace', () {
    expect(
      DefaultGameModule().quickSaveNamespaceForScript('start'),
      isNull,
    );
  });
}
