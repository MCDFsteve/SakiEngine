import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/animation_manager.dart';
import 'package:sakiengine/src/utils/global_variable_manager.dart';

final _characters = {
  'alice': CharacterConfig(
    id: 'alice',
    name: 'Alice',
    resourceId: 'alice_front',
    defaultPoseId: 'center',
    slotId: 'alice',
  ),
  'alice2': CharacterConfig(
    id: 'alice2',
    name: 'Alice',
    resourceId: 'alice_side',
    defaultPoseId: 'center',
    slotId: 'alice',
  ),
};

MenuNode _menu() => MenuNode([ChoiceOptionNode('Continue', 'after_choice')]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('saki-choice-seek-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => storage.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await storage.delete(recursive: true);
  });

  test(
    'CG to scene restores cast, aliases, hides and per-line history',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'inside CG'),
          BackgroundNode('street-night', transitionType: 'fade', timer: 30),
          ShowNode('alice', pose: 'pose1', expression: 'sad', position: 'left'),
          ShowNode('extra'),
          SayNode(dialogue: 'on the street'),
          HideNode('extra'),
          SayNode(
            character: 'alice2',
            pose: 'pose2',
            expression: 'happy',
            position: 'right',
            dialogue: 'choose',
          ),
          _menu(),
          SayNode(dialogue: 'must not execute'),
        ]),
        characterConfigs: _characters,
        initialState: GameState(
          cgCharacters: {'__global_cg__': CharacterState(resourceId: 'old_cg')},
        ),
      );
      final emitted = <GameState>[];
      final subscription = manager.gameStateStream.listen(emitted.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      emitted.clear();

      expect(
        await manager.jumpToNextChoice().timeout(const Duration(seconds: 2)),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      final state = manager.currentState;
      expect(state.background, 'street-night');
      expect(state.cgCharacters, isEmpty);
      expect(state.characters.keys, ['slot:alice']);
      expect(state.characters['slot:alice']!.resourceId, 'alice_side');
      expect(state.characters['slot:alice']!.pose, 'pose2');
      expect(state.characters['slot:alice']!.expression, 'happy');
      expect(state.characters['slot:alice']!.positionId, 'right');
      expect(state.characters['slot:alice']!.isFadingOut, isFalse);
      expect(emitted, hasLength(1));
      expect(emitted.single.currentNode, isA<MenuNode>());
      expect(manager.currentScriptIndex, 7);
      final history = manager.getDialogueHistory();
      expect(history.map((entry) => entry.dialogue), [
        'inside CG',
        'on the street',
        'choose',
      ]);
      expect(history[0].stateSnapshot.currentState.cgCharacters, isNotEmpty);
      expect(history[1].stateSnapshot.currentState.cgCharacters, isEmpty);
      expect(
        history[1].stateSnapshot.currentState.characters.keys,
        containsAll(['slot:alice', 'extra']),
      );
      expect(history.last.stateSnapshot.currentState.characters.keys, [
        'slot:alice',
      ]);
      expect(manager.saveStateSnapshot().scriptIndex, 7);
    },
  );

  test(
    'empty scene auto-renders dialogue character and final timed expression',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'empty scene'),
          SayNode(
            character: 'alice',
            dialogue: 'arrives',
            pose: 'pose1',
            startExpression: 'sad',
            switchDelay: 30,
            endExpression: 'happy',
          ),
          SayNode(
            dialogue: 'prompt',
            tailCharacter: 'alice',
            tailPose: 'pose2',
            tailExpression: 'smile',
          ),
          _menu(),
        ]),
        characterConfigs: _characters,
      );
      expect(manager.currentState.characters, isEmpty);
      expect(await manager.jumpToNextChoice(), isTrue);
      expect(manager.currentState.characters['slot:alice']!.pose, 'pose2');
      expect(
        manager.currentState.characters['slot:alice']!.expression,
        'smile',
      );
      expect(
        manager
            .getDialogueHistory()[1]
            .stateSnapshot
            .currentState
            .characters['slot:alice']!
            .expression,
        'happy',
      );
    },
  );

  test(
    'destination CG is retained with its final variant and clears sprites',
    () async {
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'before CG'),
          CgNode(
            'new_cg',
            pose: 'pose1',
            expression: 'sad',
            transitionType: 'diss',
          ),
          SayNode(dialogue: 'CG line'),
          CgNode('new_cg', pose: 'pose1', expression: 'happy'),
          _menu(),
        ]),
        initialState: GameState(
          background: 'street',
          characters: {'alice': CharacterState(resourceId: 'alice_front')},
        ),
      );
      expect(await manager.jumpToNextChoice(), isTrue);
      expect(manager.currentState.background, isNull);
      expect(manager.currentState.characters, isEmpty);
      expect(
        manager.currentState.cgCharacters.values.single.resourceId,
        'new_cg',
      );
      expect(
        manager.currentState.cgCharacters.values.single.expression,
        'happy',
      );
    },
  );

  test(
    'NVL, persistent overlays, scene animations and audio reach final state',
    () async {
      AnimationManager.loadAnimationsFromStringForTesting(
        'camera\nlinear 1 scale+0.5',
      );
      addTearDown(AnimationManager.clearCache);
      final manager = GameManager();
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'before'),
          PlayMusicNode('discarded'),
          PlaySoundNode('discarded_loop', loop: true),
          MovieNode('chapter_movie', timer: 30),
          BackgroundNode('destination', animation: 'camera'),
          FxNode('nostalgic'),
          NvlNode(),
          SayNode(dialogue: 'NVL line'),
          EndNvlNode(),
          CanvasNode('discarded_canvas'),
          HideCanvasNode(),
          AnimeNode('retained_overlay', keep: true, loop: true),
          StopMusicNode(),
          StopSoundNode(),
          PlaySoundNode('destination_loop', loop: true),
          SayNode(dialogue: 'prompt'),
          _menu(),
        ]),
      );
      expect(
        await manager.jumpToNextChoice().timeout(const Duration(seconds: 2)),
        isTrue,
      );
      final state = manager.currentState;
      expect(state.movieFile, isNull);
      expect(state.background, 'destination');
      expect(state.sceneAnimationProperties!['scale'], 1.5);
      expect(state.sceneFilter, isNotNull);
      expect(state.isNvlMode, isFalse);
      expect(state.nvlDialogues, isEmpty);
      expect(state.scriptCanvasId, isNull);
      expect(state.animeOverlay, 'retained_overlay');
      expect(state.currentMusicRegion, isNull);
      expect(manager.activeLoopingSoundsForTesting, {
        'Assets/sound/destination_loop.mp3',
      });
      expect(manager.getDialogueHistory()[1].stateSnapshot.isNvlMode, isTrue);
      expect(manager.isFastForwardMode, isFalse);
      expect(state.isFastForwarding, isFalse);
    },
  );

  test(
    'bool assignments and project API conditions select the actual first menu',
    () async {
      final manager = GameManager(
        onScriptApiExecute:
            ({
              required apiName,
              required params,
              required gameState,
              required scriptIndex,
            }) async {
              await GlobalVariableManager().setBoolVariable(
                'seek_api_route',
                true,
              );
              return ScriptApiExecutionResult.handled();
            },
      );
      addTearDown(manager.dispose);
      await GlobalVariableManager().setBoolVariable('seek_api_route', false);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'start'),
          BoolNode('seek_route', true),
          JumpNode(
            'api',
            conditionVariable: 'seek_route',
            conditionValue: true,
          ),
          ReturnNode(),
          LabelNode('api'),
          ApiCallNode('test.change_route'),
          JumpNode(
            'choice',
            conditionVariable: 'seek_api_route',
            conditionValue: true,
          ),
          ReturnNode(),
          LabelNode('choice'),
          ConditionalSayNode(
            dialogue: 'conditional prompt',
            character: 'alice',
            expression: 'happy',
            conditionVariable: 'seek_route',
            conditionValue: true,
          ),
          _menu(),
          MenuNode([ChoiceOptionNode('wrong', 'wrong')]),
        ]),
        characterConfigs: _characters,
      );
      expect(await manager.jumpToNextChoice(), isTrue);
      expect(manager.currentScriptIndex, 10);
      expect(
        manager.currentState.characters['slot:alice']!.expression,
        'happy',
      );
      expect(manager.getDialogueHistory().last.dialogue, 'conditional prompt');
    },
  );

  test(
    'no reachable choice leaves state and variables untouched, including cycles',
    () async {
      for (final ending in <List<SksNode>>[
        [ReturnNode(), _menu()],
        [LabelNode('loop'), JumpNode('loop'), _menu()],
        [JumpNode('missing'), _menu()],
      ]) {
        final manager = GameManager();
        addTearDown(manager.dispose);
        await GlobalVariableManager().setBoolVariable('seek_unchanged', false);
        await manager.startTestScript(
          ScriptNode([
            SayNode(dialogue: 'stay here'),
            BoolNode('seek_unchanged', true),
            BackgroundNode('must not be displayed'),
            ...ending,
          ]),
        );
        final before = manager.currentState;
        expect(await manager.jumpToNextChoice(), isFalse);
        expect(manager.currentState, same(before));
        expect(manager.currentScriptIndex, 1);
        expect(
          GlobalVariableManager().getBoolVariableSync('seek_unchanged'),
          isFalse,
        );
      }
    },
  );

  test(
    'already running seek excludes duplicate input and disposal releases it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      final manager = GameManager(
        onScriptApiExecute:
            ({
              required apiName,
              required params,
              required gameState,
              required scriptIndex,
            }) async {
              calls++;
              entered.complete();
              await release.future;
              return ScriptApiExecutionResult.handled(
                nextState: gameState.copyWith(
                  sceneTopRightStatusText: 'finished',
                ),
              );
            },
      );
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'start'),
          ApiCallNode('test.wait'),
          _menu(),
        ]),
      );
      final seeking = manager.jumpToNextChoice();
      await entered.future;
      expect(await manager.jumpToNextChoice(), isFalse);
      manager.next();
      manager.dispose();
      release.complete();
      expect(await seeking, isFalse);
      expect(calls, 1);
    },
  );

  test(
    'pending API wait resolves and old expression timer cannot overwrite arrival',
    () async {
      final manager = GameManager(
        onScriptApiExecute:
            ({
              required apiName,
              required params,
              required gameState,
              required scriptIndex,
            }) async {
              return ScriptApiExecutionResult.handled(
                nextState: gameState.copyWith(scriptOverlayText: 'waiting'),
                waitDuration: const Duration(seconds: 30),
                stateAfterWait: gameState.copyWith(
                  clearScriptOverlay: true,
                  sceneTopRightStatusText: 'resolved',
                ),
              );
            },
      );
      addTearDown(manager.dispose);
      await manager.startTestScript(
        ScriptNode([
          ApiCallNode('test.wait'),
          SayNode(character: 'alice', dialogue: 'prompt', expression: 'happy'),
          _menu(),
        ]),
        characterConfigs: _characters,
      );
      expect(manager.currentState.scriptOverlayText, 'waiting');
      expect(await manager.jumpToNextChoice(), isTrue);
      expect(manager.currentState.scriptOverlayText, isNull);
      expect(manager.currentState.sceneTopRightStatusText, 'resolved');

      await manager.startTestScript(
        ScriptNode([
          SayNode(
            character: 'alice',
            dialogue: 'old timed line',
            startExpression: 'old_start',
            endExpression: 'old_end',
            switchDelay: .03,
          ),
          SayNode(
            character: 'alice',
            dialogue: 'new prompt',
            expression: 'new',
          ),
          _menu(),
        ]),
        characterConfigs: _characters,
      );
      expect(await manager.jumpToNextChoice(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(manager.currentState.characters['slot:alice']!.expression, 'new');
    },
  );
}
