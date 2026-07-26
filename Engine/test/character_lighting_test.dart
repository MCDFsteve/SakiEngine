import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakiengine/src/core/game_module.dart';
import 'package:sakiengine/src/game/game_manager.dart';

void main() {
  test('default game module does not infer project-specific scene lighting',
      () {
    final module = DefaultGameModule();

    expect(
      module.resolveCharacterLighting(GameState(background: 'sky-yuu')),
      isNull,
    );
    expect(
      module.resolveCharacterLighting(GameState(background: 'sky-yoru')),
      isNull,
    );
  });

  test('character lighting uses an alpha-safe multiply matrix', () {
    const lighting = CharacterLighting(
      multiplyColor: Color(0xFF2F4778),
      strength: 0.58,
    );
    const retained = 1.0 - 0.58;

    expect(
      lighting.colorFilter,
      ColorFilter.matrix(<double>[
        retained + 47 / 255 * 0.58,
        0,
        0,
        0,
        0,
        0,
        retained + 71 / 255 * 0.58,
        0,
        0,
        0,
        0,
        0,
        retained + 120 / 255 * 0.58,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
    );
  });
}
