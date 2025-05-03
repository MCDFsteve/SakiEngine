import 'dart:math'; // Import math for min

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart'; // For Duration
import 'package:flame/sprite.dart'; // Keep for Sprite loading

// Import the new DissolvingSprite component
import 'dissolving_sprite.dart';
// Import PoseDefinition and CharacterDefinition
import 'visual_novel_scene.dart' show PoseDefinition, CharacterDefinition;

// A component to manage character sprites (立绘) with dissolve effects
class CharacterManager extends Component with HasGameReference<FlameGame> {
  // Store DissolvingSprite component and the pose name
  final Map<String, ({DissolvingSprite component, String poseName})> _characterComponents = {};

  // Definitions loaded from the main game
  final Map<String, PoseDefinition> poses;
  final Map<String, CharacterDefinition> characters;
  final PoseDefinition defaultPose;

  // Configuration for the effects
  final Duration initialFadeInDuration; // Duration for the first appearance
  final Duration dissolveDuration;      // Duration for transitions

  CharacterManager({
    required this.poses,
    required this.characters,
    required this.defaultPose,
    // Set separate default durations
    this.initialFadeInDuration = const Duration(milliseconds: 500),
    this.dissolveDuration = const Duration(milliseconds: 150), 
  });

  // No onLoad needed here unless CharacterManager needs specific setup

  Future<void> showCharacter({
    required String characterAlias,
    String expression = 'default',
    String poseName = 'center_default',
  }) async {
    print('CharacterManager: Request to show $characterAlias ($expression) at $poseName');
    final characterDef = characters[characterAlias];
    if (characterDef == null) {
        print('  -> Error: Unknown character alias "$characterAlias"');
        return;
    }
    final assetId = characterDef.assetId;
    final targetPose = poses[poseName] ?? defaultPose;
    if (!poses.containsKey(poseName)) {
        print("    Warning: Pose '$poseName' not found. Using default pose.");
    }
    print("    Using PoseDefinition: (${targetPose.toString()})");

    // --- Sprite Loading Logic (same as before) ---
    Sprite? loadedSprite;
    String? loadedFileName;
    final baseFileName = '$assetId-$expression';
    const List<String> extensionsToTry = ['.webp', '.png'];

    for (final ext in extensionsToTry) {
      final potentialFileName = '$baseFileName$ext';
      final imagePath = 'characters/$potentialFileName';
      try {
        print("    Attempting to load character: assets/images/$imagePath");
        loadedSprite = await game.loadSprite(imagePath);
        loadedFileName = potentialFileName;
        print("      Success! Loaded '$loadedFileName'.");
        break;
      } catch (e) {
         print("      'assets/images/$imagePath' not found or failed to load. Trying next...");
      }
    }

    if (loadedSprite == null || loadedFileName == null) {
       print('    Error: Could not load character asset \'$baseFileName\' with any supported extension (${extensionsToTry.join(', ')}).');
       return;
    }
    // --- End Sprite Loading ---


    // --- Component Creation / Update Logic ---
    try {
        if (_characterComponents.containsKey(characterAlias)) {
            // Character exists, start dissolve transition
            print("    Character '$characterAlias' exists. Starting dissolve...");
            final existingData = _characterComponents[characterAlias]!;
            // Use dissolveDuration for transitions
            existingData.component.startDissolve(loadedSprite, targetPose, dissolveDuration);
            _characterComponents[characterAlias] = (component: existingData.component, poseName: poseName);

        } else {
            // Character is new, create and add DissolvingSprite
            print("    Character '$characterAlias' is new. Creating component for initial fade-in...");

             final characterComponent = DissolvingSprite(
                initialSprite: loadedSprite,
                initialPose: targetPose, 
                characterAlias: characterAlias, 
                // Use initialFadeInDuration for the first appearance
                fadeInDuration: initialFadeInDuration, 
                priority: 0, 
             );

            await add(characterComponent);
            _characterComponents[characterAlias] = (component: characterComponent, poseName: poseName);
            print("    New character '$characterAlias' component added and fade-in started.");
        }

    } catch (e) {
         print('    Error creating/updating character component for $characterAlias: $e');
    }
  }

  void hideCharacter(String characterAlias) {
    print('CharacterManager: Hiding $characterAlias');
     final data = _characterComponents.remove(characterAlias);
     // `removeFromParent` triggers the component's `onRemove`, cleaning up effects.
     data?.component.removeFromParent();
     if (data == null) {
        print("    Warning: Tried to hide character '$characterAlias', but it wasn't found.");
     }
  }

  void hideAllCharacters() {
     print('CharacterManager: Hiding all characters');
     // Use `toList` to avoid modification during iteration issues
     final componentsToRemove = _characterComponents.values.map((data) => data.component).toList();
     removeAll(componentsToRemove);
     _characterComponents.clear();
  }

   @override
   void onGameResize(Vector2 size) {
     super.onGameResize(size);
     print("CharacterManager onGameResize called with: $size. Child components will handle resizing.");
     // No need to manually iterate and resize children here.
     // DissolvingSprite components will receive onGameResize call automatically
     // and use their `updateTransform` logic.
   }

   // _updateCharacterSizeAndPosition is no longer needed as DissolvingSprite handles its own transform.

   // _calculateScale is no longer needed here as it's encapsulated within DissolvingSprite.
} 