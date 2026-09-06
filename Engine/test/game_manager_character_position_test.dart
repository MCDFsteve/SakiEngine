import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';
import 'package:sakiengine/src/utils/animation_manager.dart';
import 'package:sakiengine/src/utils/character_auto_distribution.dart';

Map<String, CharacterConfig> _characterConfigs() => {
  for (final entry in {'a': 'alpha', 'b': 'beta', 'c': 'gamma'}.entries)
    entry.key: CharacterConfig(
      id: entry.key,
      name: entry.key,
      resourceId: entry.value,
      defaultPoseId: 'auto',
    ),
};

Map<String, PoseConfig> _poseConfigs() => {
  'auto': PoseConfig(id: 'auto', scale: 1.3, ycenter: 0.7, anchor: 'auto'),
  'close': PoseConfig(
    id: 'close',
    scale: 1.55,
    xcenter: 0.35,
    ycenter: 0.65,
    anchor: 'center',
  ),
};

CharacterState _character(
  String resourceId, {
  Map<String, double>? animationProperties,
}) => CharacterState(
  resourceId: resourceId,
  positionId: 'auto',
  animationProperties: animationProperties,
);

Map<String, Map<String, double>> _renderedProperties(GameManager manager) {
  final characters = manager.currentState.characters;
  final distributed = CharacterAutoDistribution.calculateAutoDistribution(
    characters,
    manager.poseConfigs,
    characters.keys.toList(),
  );
  return {
    for (final entry in characters.entries)
      entry.key: {
        'xcenter':
            (distributed['${entry.key}_auto_distributed'] ??
                    manager.poseConfigs[entry.value.positionId]!)
                .xcenter,
        'ycenter': manager.poseConfigs[entry.value.positionId]!.ycenter,
        'scale': manager.poseConfigs[entry.value.positionId]!.scale,
        'alpha': 1,
        ...?entry.value.animationProperties,
      },
  };
}

void _expectPositions(GameManager manager, Map<String, double> expected) {
  final actual = _renderedProperties(manager);
  expect(actual.keys, unorderedEquals(expected.keys));
  for (final entry in expected.entries) {
    expect(
      actual[entry.key]!['xcenter'],
      closeTo(entry.value, 0.000001),
      reason: '${entry.key} should occupy its current distributed position',
    );
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  var remaining = duration;
  while (remaining > Duration.zero) {
    final step = remaining < const Duration(milliseconds: 20)
        ? remaining
        : const Duration(milliseconds: 20);
    await tester.pump(step);
    remaining -= step;
  }
}

Future<GameManager> _createManager(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (buildContext) {
          context = buildContext;
          return const SizedBox();
        },
      ),
    ),
  );
  final manager = GameManager();
  manager.setContext(context, const TestVSync());
  addTearDown(manager.dispose);
  return manager;
}

void main() {
  tearDown(AnimationManager.clearCache);

  testWidgets('completed jump stays distributed when two characters enter', (
    tester,
  ) async {
    final manager = await _createManager(tester);
    AnimationManager.loadAnimationsFromStringForTesting('''
jump
ease 0.3 ycenter-0.05
ease 0.3 ycenter+0
''');

    // The reported scene's ordering: jump, dialogue/expression changes, then
    // two consecutive shows. These generic fixtures require no game assets.
    await manager.startTestScript(
      SksParser().parse('''
show alpha happy at auto an jump
"scissors"
"winner"
a surprised "surprised"
a sad "catcher"
"friends-enter"
show beta at auto
show gamma at auto
b "after-show"
'''),
      characterConfigs: _characterConfigs(),
      poseConfigs: _poseConfigs(),
      initialState: GameState(characters: {'alpha': _character('alpha')}),
    );
    await _pumpFor(tester, const Duration(milliseconds: 750));
    expect(manager.currentState.dialogue, 'scissors');
    expect(
      manager.currentState.characters['alpha']!.animationProperties,
      containsPair('xcenter', 0.5),
      reason: 'The completed jump must leave the original centered snapshot',
    );

    for (final dialogue in [
      'winner',
      'surprised',
      'catcher',
      'friends-enter',
      'after-show',
    ]) {
      manager.next();
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 1300));
      expect(manager.currentState.dialogue, dialogue);
    }

    _expectPositions(manager, {'alpha': 0.2, 'beta': 0.5, 'gamma': 0.8});
    final alpha = _renderedProperties(manager)['alpha']!;
    expect(alpha['ycenter'], closeTo(0.7, 0.000001));
    expect(alpha['scale'], closeTo(1.3, 0.000001));
    expect(manager.currentState.characters['alpha']!.expression, 'sad');
  });

  for (final enterViaDialogue in [false, true]) {
    final entryDescription = enterViaDialogue ? 'dialogue' : 'show';

    testWidgets(
      'fade completion during $entryDescription entrance keeps advancing and removes old cast',
      (tester) async {
        final manager = await _createManager(tester);
        await manager.startTestScript(
          ScriptNode([
            HideNode('alpha'),
            SayNode(dialogue: 'before-show'),
            if (enterViaDialogue)
              SayNode(character: 'c', dialogue: 'after-show')
            else ...[
              ShowNode('gamma', position: 'auto'),
              SayNode(dialogue: 'after-show'),
            ],
            SayNode(dialogue: 'after-click'),
          ]),
          characterConfigs: _characterConfigs(),
          poseConfigs: _poseConfigs(),
          initialState: GameState(
            characters: {
              'alpha': _character('alpha'),
              'beta': _character(
                'beta',
                animationProperties: {
                  'ycenter': 0.64,
                  'scale': 1.45,
                  'alpha': 0.9,
                },
              ),
            },
          ),
        );
        expect(manager.currentState.dialogue, 'before-show');
        expect(manager.currentState.characters['alpha']!.isFadingOut, isTrue);

        manager.next();
        await tester.pump();
        await _pumpFor(tester, const Duration(milliseconds: 220));
        // Renderer completion arrives during the awaited 500 ms placement.
        manager.removeCharacterAfterFadeOut('alpha');
        await _pumpFor(tester, const Duration(milliseconds: 1500));

        expect(manager.currentState.dialogue, 'after-show');
        _expectPositions(manager, {'beta': 0.25, 'gamma': 0.75});
        final beta = _renderedProperties(manager)['beta']!;
        expect(beta['ycenter'], closeTo(0.64, 0.000001));
        expect(beta['scale'], closeTo(1.45, 0.000001));
        expect(beta['alpha'], closeTo(0.9, 0.000001));
        manager.next();
        await tester.pump();
        expect(manager.currentState.dialogue, 'after-click');
        expect(manager.currentState.characters.containsKey('alpha'), isFalse);
      },
    );

    testWidgets(
      '$entryDescription distribution preserves non-horizontal transforms',
      (tester) async {
        final manager = await _createManager(tester);
        await manager.startTestScript(
          ScriptNode([
            SayNode(dialogue: 'before-entry'),
            if (enterViaDialogue)
              SayNode(character: 'b', dialogue: 'after-entry')
            else ...[
              ShowNode('beta', position: 'auto'),
              SayNode(dialogue: 'after-entry'),
            ],
          ]),
          characterConfigs: _characterConfigs(),
          poseConfigs: _poseConfigs(),
          initialState: GameState(
            characters: {
              'alpha': _character(
                'alpha',
                animationProperties: {
                  'xcenter': 0.5,
                  'ycenter': 0.63,
                  'scale': 1.55,
                  'alpha': 0.8,
                },
              ),
            },
          ),
        );
        manager.next();
        await tester.pump();
        await _pumpFor(tester, const Duration(milliseconds: 750));

        expect(manager.currentState.dialogue, 'after-entry');
        _expectPositions(manager, {'alpha': 0.25, 'beta': 0.75});
        final alpha = _renderedProperties(manager)['alpha']!;
        expect(alpha['ycenter'], closeTo(0.63, 0.000001));
        expect(alpha['scale'], closeTo(1.55, 0.000001));
        expect(alpha['alpha'], closeTo(0.8, 0.000001));
      },
    );
  }

  testWidgets(
    'fade completion during explicit pose change does not restore removed cast',
    (tester) async {
      final manager = await _createManager(tester);
      await manager.startTestScript(
        ScriptNode([
          HideNode('alpha'),
          SayNode(dialogue: 'before-pose'),
          SayNode(character: 'b', position: 'close', dialogue: 'after-pose'),
          SayNode(dialogue: 'after-click'),
        ]),
        characterConfigs: _characterConfigs(),
        poseConfigs: _poseConfigs(),
        initialState: GameState(
          characters: {
            'alpha': _character('alpha'),
            'beta': _character('beta'),
          },
        ),
      );
      manager.next();
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 220));
      manager.removeCharacterAfterFadeOut('alpha');
      await _pumpFor(tester, const Duration(milliseconds: 1500));

      expect(manager.currentState.dialogue, 'after-pose');
      _expectPositions(manager, {'beta': 0.35});
      expect(manager.currentState.characters['beta']!.positionId, 'close');
      final beta = _renderedProperties(manager)['beta']!;
      expect(beta['ycenter'], closeTo(0.65, 0.000001));
      expect(beta['scale'], closeTo(1.55, 0.000001));
      manager.next();
      await tester.pump();
      expect(manager.currentState.dialogue, 'after-click');
      expect(manager.currentState.characters.containsKey('alpha'), isFalse);
    },
  );

  testWidgets(
    'fast-forward applies final distribution without clearing other transforms',
    (tester) async {
      final manager = await _createManager(tester);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'before-entry'),
          ShowNode('beta', position: 'auto'),
          ShowNode('gamma', position: 'auto'),
          SayNode(dialogue: 'after-entry'),
        ]),
        characterConfigs: _characterConfigs(),
        poseConfigs: _poseConfigs(),
        initialState: GameState(
          characters: {
            'alpha': _character(
              'alpha',
              animationProperties: {
                'xcenter': 0.5,
                'ycenter': 0.63,
                'scale': 1.55,
                'alpha': 0.8,
              },
            ),
          },
        ),
      );
      manager.setFastForwardMode(true);
      manager.next();
      await tester.pump();

      expect(manager.currentState.dialogue, 'after-entry');
      _expectPositions(manager, {'alpha': 0.2, 'beta': 0.5, 'gamma': 0.8});
      final alpha = _renderedProperties(manager)['alpha']!;
      expect(alpha['ycenter'], closeTo(0.63, 0.000001));
      expect(alpha['scale'], closeTo(1.55, 0.000001));
      expect(alpha['alpha'], closeTo(0.8, 0.000001));
      await _pumpFor(tester, const Duration(milliseconds: 60));
    },
  );

  testWidgets(
    'running jump cannot restore old horizontal position after entrance',
    (tester) async {
      final manager = await _createManager(tester);
      AnimationManager.loadAnimationsFromStringForTesting('''
long_jump
ease 2 ycenter-0.05
ease 2 ycenter+0
''');
      await manager.startTestScript(
        SksParser().parse('''
show alpha happy at auto an long_jump
"before-entry"
show beta at auto
show gamma at auto
"after-entry"
'''),
        characterConfigs: _characterConfigs(),
        poseConfigs: _poseConfigs(),
        initialState: GameState(characters: {'alpha': _character('alpha')}),
      );
      await _pumpFor(tester, const Duration(milliseconds: 220));
      manager.next();
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 1300));
      expect(manager.currentState.dialogue, 'after-entry');
      final history = manager.getDialogueHistory().last;
      expect(history.dialogue, 'after-entry');
      expect(
        history
            .stateSnapshot
            .currentState
            .characters['alpha']!
            .animationProperties?['xcenter'],
        closeTo(0.2, 0.000001),
        reason: 'History must keep the new slot even before the jump finishes',
      );
      // Continue through the long jump's remaining frames and final callback.
      await _pumpFor(tester, const Duration(seconds: 3));

      _expectPositions(manager, {'alpha': 0.2, 'beta': 0.5, 'gamma': 0.8});
      final alpha = _renderedProperties(manager)['alpha']!;
      expect(alpha['ycenter'], closeTo(0.7, 0.000001));
      expect(alpha['scale'], closeTo(1.3, 0.000001));
    },
  );

  testWidgets(
    'conditional dialogue entrance respects a concurrent fade completion',
    (tester) async {
      final manager = await _createManager(tester);
      await manager.startTestScript(
        ScriptNode([
          HideNode('alpha'),
          SayNode(dialogue: 'before-entry'),
          ConditionalSayNode(
            character: 'c',
            dialogue: 'after-entry',
            conditionVariable: 'position_test_disabled',
            conditionValue: false,
          ),
          SayNode(dialogue: 'after-click'),
        ]),
        characterConfigs: _characterConfigs(),
        poseConfigs: _poseConfigs(),
        initialState: GameState(
          characters: {
            'alpha': _character('alpha'),
            'beta': _character('beta'),
          },
        ),
      );
      manager.next();
      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 220));
      manager.removeCharacterAfterFadeOut('alpha');
      await _pumpFor(tester, const Duration(milliseconds: 1500));

      expect(manager.currentState.dialogue, 'after-entry');
      _expectPositions(manager, {'beta': 0.25, 'gamma': 0.75});
      manager.next();
      await tester.pump();
      expect(manager.currentState.dialogue, 'after-click');
    },
  );

  testWidgets(
    'disposing during entrance finishes the pending script without mutation',
    (tester) async {
      final manager = await _createManager(tester);
      var executionCompleted = false;
      final execution = manager
          .startTestScript(
            ScriptNode([
              ShowNode('beta', position: 'auto'),
              SayNode(dialogue: 'must-not-display'),
            ]),
            characterConfigs: _characterConfigs(),
            poseConfigs: _poseConfigs(),
            initialState: GameState(characters: {'alpha': _character('alpha')}),
          )
          .then((_) => executionCompleted = true);

      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 220));
      expect(executionCompleted, isFalse);
      manager.dispose();
      final stateAtDisposal = manager.currentState;
      await _pumpFor(tester, const Duration(milliseconds: 750));

      expect(executionCompleted, isTrue);
      await execution;
      expect(manager.currentState, same(stateAtDisposal));
      expect(manager.currentState.dialogue, isNot('must-not-display'));
    },
  );

  testWidgets(
    'restarting during entrance ignores the old script continuation',
    (tester) async {
      final manager = await _createManager(tester);
      var oldExecutionCompleted = false;
      final oldExecution = manager
          .startTestScript(
            ScriptNode([
              ShowNode('beta', position: 'auto'),
              SayNode(dialogue: 'old-dialogue'),
              SayNode(dialogue: 'old-next'),
            ]),
            characterConfigs: _characterConfigs(),
            poseConfigs: _poseConfigs(),
            initialState: GameState(characters: {'alpha': _character('alpha')}),
          )
          .then((_) => oldExecutionCompleted = true);

      await tester.pump();
      await _pumpFor(tester, const Duration(milliseconds: 220));
      expect(oldExecutionCompleted, isFalse);
      await manager.startTestScript(
        ScriptNode([
          SayNode(dialogue: 'replacement-dialogue'),
          SayNode(dialogue: 'replacement-next'),
        ]),
        characterConfigs: _characterConfigs(),
        poseConfigs: _poseConfigs(),
        initialState: GameState(characters: {'gamma': _character('gamma')}),
      );
      await _pumpFor(tester, const Duration(milliseconds: 750));

      expect(oldExecutionCompleted, isTrue);
      await oldExecution;
      expect(manager.currentState.dialogue, 'replacement-dialogue');
      _expectPositions(manager, {'gamma': 0.5});
      manager.next();
      await tester.pump();
      expect(manager.currentState.dialogue, 'replacement-next');
      _expectPositions(manager, {'gamma': 0.5});
    },
  );
}
