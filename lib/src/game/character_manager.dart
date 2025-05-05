import 'dart:math'; // Import math for min
import 'dart:ui' as ui; // Import dart:ui for Canvas compositing

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart'; // For Duration
import 'package:flame/sprite.dart'; // Keep for Sprite loading

// Import the new DissolvingSprite component
import 'dissolving_sprite.dart';
// Import PoseDefinition and CharacterDefinition
import 'visual_novel_scene.dart' show PoseDefinition, CharacterDefinition;

// A component to manage character sprites (立绘) with dissolve effects and layering
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

  // --- Layered Character Display ---
  Future<void> showCharacter({
    required String characterAlias,
    List<String> attributes = const ['default'], // Attributes like 'happy', 'sad', 'glasses'. 'default' is handled.
    String? basePoseAttribute, // Base body pose like 'pose1', 'pose2'. Null uses default.
    String poseName = 'center_default',       // Screen position pose name from poses map
  }) async {
    print('CharacterManager: Request to show $characterAlias with attributes $attributes (Base: ${basePoseAttribute ?? 'pose1'}) at $poseName');
    final characterDef = characters[characterAlias];
    if (characterDef == null) {
        print('  -> Error: Unknown character alias "$characterAlias"');
        return;
    }
    final assetId = characterDef.assetId;
    final targetPose = poses[poseName] ?? defaultPose; // Screen position/scale definition
    if (!poses.containsKey(poseName)) {
        print("    Warning: Pose '$poseName' not found. Using default pose.");
    }
    print("    Using Screen PoseDefinition: (${targetPose.toString()})");

    // --- 1. Load Base Sprite ---
    String actualBasePoseAttr = basePoseAttribute ?? 'pose1'; // Default base pose attribute
    Sprite? baseSprite = await _loadCharacterPart(assetId, actualBasePoseAttr);
    if (baseSprite == null) {
        print('  -> Error: Could not load base pose "$actualBasePoseAttr" for asset ID "$assetId" (Alias: "$characterAlias"). Cannot show character.');
        return; // Cannot proceed without a base sprite
    }
    print("    Base sprite '$actualBasePoseAttr' loaded successfully.");

    // --- 2. Determine and Load Layer Sprites ---
    // Handle 'default' attribute: if 'default' is present or list is empty, use ['happy'] as default layers.
    // Otherwise, use the provided list excluding 'default'.
    List<String> finalAttributes;
    if (attributes.isEmpty || attributes.contains('default')) {
        finalAttributes = ['happy']; // Default expression layer
        print("    Using default attribute 'happy'.");
    } else {
        finalAttributes = attributes.where((attr) => attr != 'default').toList();
        // If after removing 'default', the list is empty, revert to default 'happy'
        if (finalAttributes.isEmpty) {
            finalAttributes = ['happy'];
            print("    Only 'default' attribute provided or resulting list empty, using default 'happy'.");
        } else {
             print("    Using specified attributes: $finalAttributes");
        }
    }


    List<Sprite> layerSprites = [];
    for (final attr in finalAttributes) {
        Sprite? layerSprite = await _loadCharacterPart(assetId, attr);
        if (layerSprite != null) {
            layerSprites.add(layerSprite);
            print("      Layer sprite '$attr' loaded.");
        } else {
            print('    Warning: Could not load layer attribute "$attr" for asset ID "$assetId" (Alias: "$characterAlias"). Skipping this layer.');
            // Optionally continue without this layer
        }
    }

    // --- 3. Composite Sprites ---
    // The composite function now handles the case with no layers gracefully
    Sprite finalSprite = await _compositeCharacterSprites(baseSprite, layerSprites);
    print("    Base and layer sprites composited.");


    // --- 4. Component Creation / Update Logic ---
    try {
        if (_characterComponents.containsKey(characterAlias)) {
            // Character exists, start dissolve transition to the new composite sprite
            print("    Character '$characterAlias' exists. Starting dissolve transition...");
            final existingData = _characterComponents[characterAlias]!;
            // Use dissolveDuration for transitions
            existingData.component.startDissolve(finalSprite, targetPose, dissolveDuration); // Pass the composited sprite
            _characterComponents[characterAlias] = (component: existingData.component, poseName: poseName); // Update poseName if needed

        } else {
            // Character is new, create and add DissolvingSprite with the composite sprite
            print("    Character '$characterAlias' is new. Creating component for initial fade-in...");

             final characterComponent = DissolvingSprite(
                initialSprite: finalSprite, // Use the composited sprite
                initialPose: targetPose,
                characterAlias: characterAlias,
                // Use initialFadeInDuration for the first appearance
                fadeInDuration: initialFadeInDuration,
                priority: 0, // Manage priority if needed
             );

            await add(characterComponent);
            _characterComponents[characterAlias] = (component: characterComponent, poseName: poseName);
            print("    New character '$characterAlias' component added and fade-in started.");
        }

    } catch (e) {
         print('    Error creating/updating character component for $characterAlias: $e');
    }
  }


  // Helper to load a single character part (base or layer) based on asset ID and part name
  Future<Sprite?> _loadCharacterPart(String assetId, String partName) async {
      Sprite? loadedSprite;
      final baseFileName = '$assetId-$partName'; // e.g., yuki-pose1 or yuki-happy
      const List<String> extensionsToTry = ['.webp', '.png']; // Prioritize webp?

      for (final ext in extensionsToTry) {
          final potentialFileName = '$baseFileName$ext';
          final imagePath = 'characters/$potentialFileName'; // Path relative to assets/images/
          try {
              // print("    Attempting to load character part: assets/images/$imagePath"); // Can be noisy
              loadedSprite = await game.loadSprite(imagePath);
              // print("      Success! Loaded '$potentialFileName'."); // Can be noisy
              break; // Found it
          } catch (e) {
              // print("      'assets/images/$imagePath' not found or failed to load. Trying next..."); // Expected case
          }
      }
       // Warning moved to caller for context
       // if (loadedSprite == null) {
       //   print('    Warning: Could not load character part '$partName' for asset '$assetId' with any supported extension (${extensionsToTry.join(', ')}).');
       // }
      return loadedSprite;
  }

  // Helper to composite a base sprite and a list of layer sprites using dart:ui.Canvas
  Future<Sprite> _compositeCharacterSprites(Sprite baseSprite, List<Sprite> layerSprites) async {
      final recorder = ui.PictureRecorder();
      final baseImage = baseSprite.image; // ui.Image
      final imageWidth = baseImage.width.toDouble();
      final imageHeight = baseImage.height.toDouble();

      // Create a canvas with the dimensions of the base image
      final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, imageWidth, imageHeight));

      final paint = ui.Paint(); // Use default paint settings

      // 1. Draw the base image first
      canvas.drawImage(baseImage, ui.Offset.zero, paint);

      // 2. Draw each layer image on top of the base
      for (final layerSprite in layerSprites) {
          // Assuming layers are the same size as the base and positioned at (0,0)
          // If layers could have different offsets/sizes, more complex logic needed here.
          canvas.drawImage(layerSprite.image, ui.Offset.zero, paint);
      }

      // Finalize the drawing and convert the recorded picture to an image
      final picture = recorder.endRecording();
      // Ensure correct dimensions are passed to toImage
      final compositedUiImage = await picture.toImage(imageWidth.toInt(), imageHeight.toInt());

      // Create a new Flame Sprite from the composited ui.Image
      return Sprite(
          compositedUiImage,
          // Source position and size cover the entire new image
          srcPosition: Vector2.zero(),
          srcSize: Vector2(imageWidth, imageHeight),
      );
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