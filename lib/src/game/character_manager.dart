import 'dart:math'; // Import math for max/min

import 'package:flame/components.dart';
import 'package:flame/game.dart'; 
import 'package:flutter/material.dart'; 
import 'package:flame/sprite.dart';

// Import necessary classes from visual_novel_scene.dart
// It's better if these definitions are moved to separate files too, but for now:
import 'visual_novel_scene.dart' show PoseDefinition, CharacterDefinition;

// A component to manage character sprites (立绘)
class CharacterManager extends Component with HasGameReference<FlameGame> {
  // Store component and the pose name used to create it
  final Map<String, ({SpriteComponent component, String poseName})> _characterComponents = {};

  // Pose and Character definitions loaded from the main game
  final Map<String, PoseDefinition> poses;
  final Map<String, CharacterDefinition> characters;
  final PoseDefinition defaultPose; // Pass the default pose

  CharacterManager({
    required this.poses,
    required this.characters,
    required this.defaultPose,
  });

  @override
  Future<void> onLoad() async {
    super.onLoad();
  }

  Future<void> showCharacter({
    required String characterAlias,
    String expression = 'default',
    String poseName = 'center_default',
  }) async {
    print('CharacterManager: Showing $characterAlias ($expression) at $poseName');
    final characterDef = characters[characterAlias];
    if (characterDef == null) {
        print('  -> Error: Unknown character alias "$characterAlias"');
        return;
    }
    final assetId = characterDef.assetId;
    final pose = poses[poseName] ?? defaultPose;
    if (!poses.containsKey(poseName)) {
        print("    Warning: Pose '$poseName' not found. Using default pose: $defaultPose");
    }
    print("    Using PoseDefinition: ${pose.toString()}");

    Sprite? loadedSprite;
    String? loadedFileName;
    final baseFileName = '$assetId-$expression';
    const List<String> extensionsToTry = ['.webp', '.png'];

    for (final ext in extensionsToTry) {
      final potentialFileName = '$baseFileName$ext';
      // Path relative to assets/images/
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

    try {
        final imageSize = loadedSprite.srcSize;
        final currentSize = game.size;

        _characterComponents[characterAlias]?.component.removeFromParent();

        double finalScale = _calculateScale(pose, imageSize, currentSize);
        final Anchor finalAnchor = pose.anchor;
        final Vector2 finalPosition = Vector2(
            currentSize.x * pose.xcenter,
            currentSize.y * pose.ycenter,
        );

        final characterComponent = SpriteComponent(
            sprite: loadedSprite,
            anchor: finalAnchor,
            position: finalPosition,
            scale: Vector2.all(finalScale),
            priority: 0, 
        );

        _characterComponents[characterAlias] = (component: characterComponent, poseName: poseName);
        await add(characterComponent); // Add to the CharacterManager itself

        String scaleMode = (pose.scale > 0) ? "Relative(H*${pose.scale})" : "AspectFit";
        print("    Character '$loadedFileName' loaded using pose '$poseName' (ScaleMode: $scaleMode, AppliedScale: ${finalScale.toStringAsFixed(3)}). Added at $finalPosition (Anchor: $finalAnchor).");

    } catch (e) {
         print('    Error adding character component for $loadedFileName: $e');
    }
  }

  void hideCharacter(String characterAlias) {
    print('CharacterManager: Hiding $characterAlias');
     final data = _characterComponents.remove(characterAlias);
     data?.component.removeFromParent();
  }

  void hideAllCharacters() {
     print('CharacterManager: Hiding all characters');
     removeAll(_characterComponents.values.map((data) => data.component));
     _characterComponents.clear();
  }

   @override
   void onGameResize(Vector2 size) {
     super.onGameResize(size);
     print("CharacterManager onGameResize called with: $size");
     _characterComponents.forEach((alias, data) {
        print("  Resizing character: $alias using pose: ${data.poseName}");
        _updateCharacterSizeAndPosition(alias, data.component, data.poseName, size);
     });
   }

   void _updateCharacterSizeAndPosition(String characterAlias, SpriteComponent component, String poseName, Vector2 targetSize) {
      final pose = poses[poseName] ?? defaultPose;
      final sprite = component.sprite;

      if (sprite == null || targetSize.x <= 0 || targetSize.y <= 0) {
          print("  Cannot resize character $characterAlias: Missing sprite or invalid target size.");
          return;
      }
      final imageSize = sprite.srcSize;

      double finalScale = _calculateScale(pose, imageSize, targetSize);
      final Vector2 finalPosition = Vector2(
          targetSize.x * pose.xcenter,
          targetSize.y * pose.ycenter,
      );

      component.scale = Vector2.all(finalScale);
      component.position = finalPosition;

      print("  Character $characterAlias resized/repositioned based on $targetSize. AppliedScale: ${finalScale.toStringAsFixed(3)}, Position: $finalPosition");
   }

   double _calculateScale(PoseDefinition pose, Vector2 imageSize, Vector2 targetSize) {
       double finalScale;
       if (pose.scale > 0) {
          if (imageSize.y != 0) {
             final targetHeight = targetSize.y * pose.scale;
             finalScale = targetHeight / imageSize.y;
          } else {
             finalScale = 1.0;
          }
       } else {
          if (imageSize.x != 0 && imageSize.y != 0) {
             final scaleX = targetSize.x / imageSize.x;
             final scaleY = targetSize.y / imageSize.y;
             finalScale = min(scaleX, scaleY); 
          } else {
             finalScale = 1.0;
          }
       }
       return finalScale;
   }
} 