// lib/src/game/background_manager.dart
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart'; // For Duration

// Import DissolvingSprite and PoseDefinition
import 'dissolving_sprite.dart';
import 'visual_novel_scene.dart' show PoseDefinition;

// Manages the background image, including transitions
class BackgroundManager extends Component with HasGameReference<FlameGame> {
  DissolvingSprite? _backgroundComponent; // Store the dissolving component
  String? _currentBackgroundPath;

  // Durations for background effects
  final Duration initialFadeInDuration;
  final Duration dissolveDuration;

  // Static default pose for backgrounds (aspect fill, centered)
  static final PoseDefinition _backgroundPose = PoseDefinition(
      scale: -1, // -1 = aspect fill (cover)
      xcenter: 0.5,
      ycenter: 0.5,
      anchor: Anchor.center, 
  );

  BackgroundManager({
    this.initialFadeInDuration = const Duration(milliseconds: 800), // Default fade-in for BG
    this.dissolveDuration = const Duration(milliseconds: 500),      // Default dissolve for BG
  });

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
    removeCurrentBackground();
    super.onRemove();
    print("  BG Manager Component: Removed.");
  }

  Future<void> changeBackground(String identifier) async {
    print("  BG Manager Component: Received scene identifier \"$identifier\"");
    final baseName = identifier.replaceAll(' ', '-').toLowerCase(); // Handle spaces
    print("    Processed base name (hyphenated): '$baseName'");
    
    String? potentialPath;
    Sprite? loadedSprite;
    String? loadedFileName;
    final extensions = ['.webp', '.png'];

    for (final ext in extensions) {
      // Construct path relative to 'assets/images/'
      potentialPath = 'backgrounds/$baseName$ext';
      print("    Attempting to load from assets/images/: $potentialPath"); // Updated log
      try {
        // Pass the path relative to 'assets/images/'
        loadedSprite = await game.loadSprite(potentialPath);
        loadedFileName = '$baseName$ext';
        print("      Success! Loaded '$loadedFileName'.");
        break;
      } catch (e) {
        // Log the path that failed
        print("      Failed to load 'assets/images/$potentialPath': $e");
        loadedSprite = null;
      }
    }

    if (loadedSprite == null || loadedFileName == null) {
      print("    Error: Could not load background '$baseName' with any extension.");
      removeCurrentBackground(); 
      return;
    }

    // Use the path relative to 'assets/images/' for comparison
    if (potentialPath == _currentBackgroundPath && _backgroundComponent != null) { 
      print("    Background '$loadedFileName' is already displayed. Skipping transition.");
      return;
    }

    // --- Handle Component Creation/Update ---
    if (_backgroundComponent != null) {
      // Background exists, start dissolve transition
      print("    Background exists. Starting dissolve to '$loadedFileName'...");
      _backgroundComponent!.startDissolve(loadedSprite, _backgroundPose, dissolveDuration);
      // No need to update size/position here, DissolvingSprite handles it based on pose
      print("      Dissolve initiated for background.");
    } else {
      // No background exists, create a new one with fade-in
      print("    No background exists. Creating new component for '$loadedFileName' with fade-in...");
      _backgroundComponent = DissolvingSprite(
        initialSprite: loadedSprite,
        initialPose: _backgroundPose, 
        characterAlias: 'background', // Use a generic alias
        fadeInDuration: initialFadeInDuration,
        priority: -10, // Ensure background is behind characters
        // Position, scale, anchor set by DissolvingSprite based on pose
      );
      await add(_backgroundComponent!); // Add to the manager
      print("      New background component added and fade-in started.");
    }

    _currentBackgroundPath = potentialPath; // Store the path relative to 'assets/images/'
  }

  void removeCurrentBackground() {
    print("  BG Manager Component: Background removed logic executed.");
    _backgroundComponent?.removeFromParent(); // Trigger component removal (handles effects)
    _backgroundComponent = null;
    _currentBackgroundPath = null;
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    // Log message is simplified as DissolvingSprite handles its own resizing.
    print("  BG Manager Component: onGameResize called with $size. Child component handles resize.");
    // The DissolvingSprite component ('_backgroundComponent') will handle its own 
    // resizing internally based on the _backgroundPose when its onGameResize is called.
  }
} 