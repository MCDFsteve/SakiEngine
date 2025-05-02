// lib/src/game/background_manager.dart
import 'package:flame/components.dart';
import 'package:flame/game.dart';
// For min

class BackgroundManager extends Component {
  SpriteComponent? _backgroundComponent;

  FlameGame get _game => findGame()!;

  @override
  Future<void> onLoad() async {
    super.onLoad();
    print("  BG Manager Component: onLoad.");
  }

  @override
  void onMount() {
    super.onMount();
    print("  BG Manager Component: Mounted.");
  }

  @override
  void onRemove() {
    removeBackground();
    super.onRemove();
    print("  BG Manager Component: Removed.");
  }

  Future<void> changeBackground(String sceneIdentifier) async {
    print('  BG Manager Component: Received scene identifier "$sceneIdentifier"');
    if (sceneIdentifier.isEmpty) {
      print('    Error: Empty scene identifier provided.');
      removeBackground();
      return;
    }

    // --- Logic to find base name and try extensions --- 
    String baseName = sceneIdentifier;
    // Remove potential existing extension first, to handle cases like "scene intro.png"
    const supportedExtensions = ['.webp', '.png', '.jpg', '.jpeg'];
    for (var ext in supportedExtensions) {
      if (baseName.toLowerCase().endsWith(ext)) {
        baseName = baseName.substring(0, baseName.length - ext.length);
        break; // Found and removed extension
      }
    }

    // Replace spaces with hyphens
    String processedBaseName = baseName.replaceAll(' ', '-').trim();
    if (processedBaseName.isEmpty) {
       print('    Error: Processed base name is empty for identifier "$sceneIdentifier"');
       removeBackground();
       return;
    }
    print("    Processed base name (hyphenated): '$processedBaseName'");

    // Define the order of extensions to try
    const List<String> extensionsToTry = ['.webp', '.png']; // Prioritize webp
    Sprite? loadedSprite;
    String? loadedFileName;

    for (final ext in extensionsToTry) {
      final potentialFileName = '$processedBaseName$ext';
      final imagePath = 'backgrounds/$potentialFileName';
      try {
        print("    Attempting to load: assets/images/$imagePath");
        loadedSprite = await _game.loadSprite(imagePath);
        loadedFileName = potentialFileName; // Store the successful filename
        print("      Success! Loaded '$loadedFileName'.");
        break; // Stop trying once loaded
      } catch (e) {
        // Check if it's specifically an asset loading error
        // Note: This check might need refinement based on actual error types
        if (e.toString().contains('Unable to load asset')) {
          print("      '$potentialFileName' not found or failed to load. Trying next...");
        } else {
           print("      An unexpected error occurred while trying to load '$potentialFileName': $e");
           // Decide if we should stop or continue on other errors
           // For now, let's continue to try other formats
        }
      }
    }
    // --- End logic --- 

    // Check if a sprite was successfully loaded
    if (loadedSprite != null && loadedFileName != null) {
      removeBackground(); // Remove previous background if any
      _backgroundComponent = SpriteComponent(
        sprite: loadedSprite,
        anchor: Anchor.center,
        priority: -10,
      );
      _updateSizeAndPosition(_game.size); // Set initial size/pos
      await _game.add(_backgroundComponent!); // Add to game
      print("    Background '$loadedFileName' successfully added.");
    } else {
      // If loop finished and no sprite was loaded
      print('    Error: Could not load background asset \'$processedBaseName\' with any supported extension (${extensionsToTry.join(', ')}).');
      removeBackground(); // Ensure no old background remains
    }
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    print("  BG Manager Component: onGameResize called with $size");
    _updateSizeAndPosition(size);
  }

  void _updateSizeAndPosition(Vector2 targetSize) {
    if (_backgroundComponent == null || _backgroundComponent!.sprite == null) {
        print("    Cannot update size: background component or sprite is null.");
        return;
    }

    final imageSize = _backgroundComponent!.sprite!.srcSize;
    if (imageSize.x <= 0 || imageSize.y <= 0 || targetSize.x <= 0 || targetSize.y <= 0) {
        print("    Cannot update size: Invalid image or target dimensions.");
        return; 
    }

    final screenAspect = targetSize.x / targetSize.y;
    final imageAspect = imageSize.x / imageSize.y;
    double scale;
    if (screenAspect > imageAspect) {
      scale = targetSize.x / imageSize.x;
    } else {
      scale = targetSize.y / imageSize.y;
    }

    _backgroundComponent!.scale = Vector2.all(scale);
    _backgroundComponent!.position = targetSize / 2;
    print("    Background component updated: Scale=${_backgroundComponent!.scale.x.toStringAsFixed(3)}, Position=${_backgroundComponent!.position}");
  }

  void removeBackground() {
      if (_backgroundComponent != null && _backgroundComponent!.isMounted) {
         _backgroundComponent!.removeFromParent();
      }
      _backgroundComponent = null;
       print("  BG Manager Component: Background removed logic executed.");
  }
} 