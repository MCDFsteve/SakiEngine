import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/animation_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(AnimationManager.clearCache);

  test('animation final properties preserve preset and last keyframe state',
      () {
    AnimationManager.loadAnimationsFromStringForTesting('''
bigjump
scale+0.10
ease 0.05 ycenter+0.10
ease 0.05 ycenter+0.15 scale+0.40
''');

    final result = AnimationManager.resolveFinalProperties(
      'bigjump',
      {
        'xcenter': 0.5,
        'ycenter': 0.7,
        'scale': 1.3,
        'alpha': 1.0,
        'rotation': 0.0,
      },
    );

    expect(result, isNotNull);
    expect(result!['xcenter'], 0.5);
    expect(result['ycenter'], closeTo(0.85, 0.0001));
    expect(result['scale'], closeTo(1.7, 0.0001));
    expect(result['alpha'], 1.0);
  });

  testWidgets(
      'finite character animation stays on its last frame until the next animation',
      (tester) async {
    AnimationManager.loadAnimationsFromStringForTesting('''
bigjump
ease 0.05 ycenter+0.10
ease 0.05 ycenter+0.15 scale+0.40

shrink
scale+0.40
ycenter+0.15
ease 0.10 ycenter-0.02 scale+0.38
ease 0.10 ycenter+0.02 scale+0.08
ease 0.10 ycenter+0 scale+0
''');

    late BuildContext context;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (currentContext) {
            context = currentContext;
            return const SizedBox();
          },
        ),
      ),
    );

    final manager = GameManager();
    addTearDown(manager.dispose);
    manager.characterConfigs['x'] = CharacterConfig(
      id: 'x',
      name: '夏悠',
      resourceId: 'xiayo2',
      defaultPoseId: 'center',
    );
    manager.poseConfigs['center'] = PoseConfig(
      id: 'center',
      scale: 1.3,
      xcenter: 0.5,
      ycenter: 0.7,
      anchor: 'center',
    );
    manager.setContext(context, const TestVSync());

    await manager.startTestScript(
      ScriptNode([
        SayNode(
          character: 'x',
          dialogue: '放大并停住。',
          animation: 'bigjump',
        ),
        SayNode(
          character: 'x',
          dialogue: '现在缩回去。',
          animation: 'shrink',
        ),
      ]),
      initialState: GameState(
        characters: {
          'xiayo2': CharacterState(
            resourceId: 'xiayo2',
            pose: 'pose3',
            expression: 'unhappy',
            positionId: 'center',
          ),
        },
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    var properties =
        manager.currentState.characters['xiayo2']!.animationProperties!;
    expect(properties['ycenter'], closeTo(0.85, 0.0001));
    expect(properties['scale'], closeTo(1.7, 0.0001));

    await tester.pump(const Duration(milliseconds: 500));
    properties =
        manager.currentState.characters['xiayo2']!.animationProperties!;
    expect(properties['ycenter'], closeTo(0.85, 0.0001));
    expect(properties['scale'], closeTo(1.7, 0.0001));

    manager.next();
    await tester.pump();
    await tester.pumpAndSettle();
    properties =
        manager.currentState.characters['xiayo2']!.animationProperties!;
    expect(properties['ycenter'], closeTo(0.7, 0.0001));
    expect(properties['scale'], closeTo(1.3, 0.0001));
  });

  test('explicit dialogue position without animation resets retained transform',
      () async {
    final manager = GameManager();
    addTearDown(manager.dispose);
    manager.characterConfigs['x'] = CharacterConfig(
      id: 'x',
      name: '夏悠',
      resourceId: 'xiayo2',
      defaultPoseId: 'center',
    );
    manager.poseConfigs['center'] = PoseConfig(
      id: 'center',
      scale: 1.3,
      xcenter: 0.5,
      ycenter: 0.7,
      anchor: 'center',
    );

    await manager.startTestScript(
      ScriptNode([
        SayNode(
          character: 'x',
          dialogue: '回到中央舞台位。',
          position: 'center',
        ),
      ]),
      initialState: GameState(
        characters: {
          'xiayo2': CharacterState(
            resourceId: 'xiayo2',
            pose: 'pose3',
            expression: 'unhappy',
            positionId: 'center',
            animationProperties: {
              'xcenter': 0.5,
              'ycenter': 0.85,
              'scale': 1.7,
              'alpha': 1.0,
              'rotation': 0.0,
            },
          ),
        },
      ),
    );

    final character = manager.currentState.characters['xiayo2'];
    expect(character, isNotNull);
    expect(character!.positionId, 'center');
    expect(character.animationProperties, isNull);
  });
}
