import 'dart:ui' as ui;
import 'dart:math';
import 'dart:ui'; // Add for FragmentProgram, FragmentShader, Canvas

import 'package:flame/components.dart';
import 'package:flame/effects.dart' as effects; // Import with prefix
import 'package:flame/game.dart';
import 'package:flame/rendering.dart';
import 'package:flutter/material.dart';

// Assuming PoseDefinition is in this file or imported correctly
import 'visual_novel_scene.dart' show PoseDefinition;

class DissolvingSprite extends SpriteComponent with HasGameReference {
  Sprite? _spriteA; // Current sprite (being faded out)
  Sprite? _spriteB; // Target sprite (being faded in)
  double _progress = 0.0; // Dissolve progress [0.0, 1.0]
  bool _isDissolving = false;
  ui.FragmentProgram? _shaderProgram;
  late final Paint _shaderPaint; // Reusable Paint object for the shader

  // Store pose info for resizing and identification
  late PoseDefinition _currentPose;
  final String characterAlias; // For debugging/identification

  // Effect controller for the dissolve animation
  effects.Effect? _currentDissolveEffect; // Use prefix

  // Add duration for the initial fade-in
  final Duration fadeInDuration;

  DissolvingSprite({
    required Sprite initialSprite,
    required PoseDefinition initialPose,
    required this.characterAlias,
    required this.fadeInDuration, // Add required duration parameter
    Vector2? position,
    Vector2? scale, // Will be set based on pose calculation
    Anchor? anchor,
    int? priority,
  }) : _spriteA = initialSprite,
       _currentPose = initialPose,
       super(
         sprite: initialSprite, // Start with the initial sprite
         position: position,
         scale: scale,
         anchor: anchor ?? Anchor.center,
         priority: priority,
       ) {
    _shaderPaint = Paint(); // Initialize paint object
  }

  @override
  Future<void> onLoad() async {
    await super.onLoad();
    
    // Set initial opacity to 0 before starting fade-in
    this.opacity = 0.0;

    try {
      // Load shader
      _shaderProgram = await ui.FragmentProgram.fromAsset(
        'assets/shaders/dissolve.frag',
      );
      print("DissolvingSprite '$characterAlias': Shader loaded successfully.");
    } catch (e) {
      print("DissolvingSprite '$characterAlias': Failed to load shader: $e");
    }
    // Apply initial transform based on the provided pose and game size
    updateTransform(_currentPose, game.size);

    // Add the initial fade-in effect
    add(
      effects.OpacityEffect.fadeIn(
        effects.LinearEffectController(fadeInDuration.inMilliseconds / 1000.0),
      ),
    );
  }

  /// Starts the dissolve transition to a new sprite and pose.
  void startDissolve(Sprite newSprite, PoseDefinition newPose, Duration duration) {
    if (_shaderProgram == null) {
      print("DissolvingSprite '$characterAlias': Cannot dissolve - shader not loaded. Swapping instantly.");
      // Fallback: Swap instantly
      this.sprite = newSprite;
      _spriteA = newSprite;
      _spriteB = null;
      _progress = 0.0;
      _isDissolving = false;
      _currentPose = newPose;
      updateTransform(_currentPose, game.size); // Apply new transform
      // Remove any lingering effect
      _currentDissolveEffect?.removeFromParent();
      _currentDissolveEffect = null;
      return;
    }

    // If already dissolving, remove the old effect first
    if (_isDissolving) {
      print("DissolvingSprite '$characterAlias': Interrupting existing dissolve.");
      _currentDissolveEffect?.removeFromParent();
       // Use the *current* visual sprite (`this.sprite`) as the starting point
       // for the new transition to avoid visual jumps.
       _spriteA = this.sprite;
    } else {
       // If not dissolving, ensure spriteA is the current sprite
       _spriteA = this.sprite;
    }


    print("DissolvingSprite '$characterAlias': Starting dissolve to new sprite/pose.");
    _spriteB = newSprite;
    _progress = 0.0; // Start progress from 0
    _isDissolving = true;
    _currentPose = newPose; // Update to the target pose immediately for transform calculation

    // Update transform to match the *target* pose/size immediately.
    // The visual transition will be handled by the shader.
    // Base the transform calculation on the *new* sprite's size.
    updateTransform(_currentPose, game.size, baseSprite: _spriteB);

    // Create and add the effect to animate the progress uniform
    // Use FunctionEffect driven by a LinearEffectController
    _currentDissolveEffect = effects.FunctionEffect<DissolvingSprite>(
      (target, progress) {
        _progress = progress as double;
        // DEBUG: Print progress value from effect
        print("  Effect Tick: progress = ${_progress.toStringAsFixed(3)}");
      },
      effects.LinearEffectController(duration.inMilliseconds / 1000.0),
      onComplete: () {
        print("DissolvingSprite '$characterAlias': Dissolve complete.");
        // Transition finished: B becomes the main sprite
        this.sprite = _spriteB;
        _spriteA = _spriteB; // Update spriteA to the new sprite
        _spriteB = null;     // Clear spriteB
        _progress = 0.0;
        _isDissolving = false;
        _currentDissolveEffect = null; // Clear the effect reference
        // Ensure final transform is correct based on the final sprite
        updateTransform(_currentPose, game.size, baseSprite: this.sprite);
      },
    )..removeOnFinish = true; // Effect removes itself when done

    add(_currentDissolveEffect!); 
  }

  @override
  void render(Canvas canvas) {
    // Only use custom shader logic if dissolving and shader is loaded
    if (_isDissolving && _shaderProgram != null && _spriteA != null && _spriteB != null && size.x > 0 && size.y > 0) {
      // DEBUG: Print when entering shader rendering logic
      print("  Rendering DIRECTLY with Shader: progress = ${_progress.toStringAsFixed(3)}"); // Updated log message
      
      // Configure the shader paint for this frame
      final ui.FragmentShader shader = _shaderProgram!.fragmentShader();
      
      // Set uniforms
      shader.setFloat(0, _progress);          // uniform float progress;
      shader.setFloat(1, size.x);             // uniform vec2 uResolution (x)
      shader.setFloat(2, size.y);             // uniform vec2 uResolution (y)

      // Sampler indices start from 0 independently
      shader.setImageSampler(0, _spriteA!.image); // uniform sampler2D texA; 
      shader.setImageSampler(1, _spriteB!.image); // uniform sampler2D texB; 

      _shaderPaint.shader = shader;
      // Optional: Copy other paint properties if needed (like blend mode)
      // _shaderPaint.blendMode = this.paint.blendMode; 
      // _shaderPaint.color = this.paint.color; // Tint might interfere, usually keep default white
      _shaderPaint.filterQuality = this.paint.filterQuality;
      _shaderPaint.isAntiAlias = this.paint.isAntiAlias;

      // Draw a rectangle covering the component area using the shader paint.
      // The shader handles sampling and mixing based on fragment coordinates.
      canvas.drawRect(size.toRect(), _shaderPaint);

    } else {
      // Default rendering (just draws `this.sprite`) when not dissolving
      // print("  Rendering default sprite."); // Optional debug log
      super.render(canvas);
    }
  }

  @override
  void onRemove() {
    // Clean up effect if component is removed mid-dissolve
    _currentDissolveEffect?.removeFromParent();
    super.onRemove();
  }


  // Handle game resize: recalculate transform based on the current pose
  @override
  void onGameResize(Vector2 newGameSize) {
    super.onGameResize(newGameSize);
    print("DissolvingSprite '$characterAlias': onGameResize - Recalculating transform for size $newGameSize");
    // Use the current pose and the currently active sprite for size reference
    updateTransform(_currentPose, newGameSize, baseSprite: this.sprite);
  }

  /// Updates the component's position, scale, and anchor based on a PoseDefinition.
  /// Optionally specify which sprite to use for size calculation (defaults to current `this.sprite`).
  void updateTransform(PoseDefinition pose, Vector2 targetSize, { Sprite? baseSprite }) {
    final spriteForSizing = baseSprite ?? this.sprite;

    if (spriteForSizing == null) {
      print("DissolvingSprite '$characterAlias': Cannot update transform - no sprite available for sizing.");
      return;
    }
    final imageSize = spriteForSizing.srcSize;

    if (imageSize.x <= 0 || imageSize.y <= 0 || targetSize.x <= 0 || targetSize.y <= 0) {
      print("DissolvingSprite '$characterAlias': Cannot update transform - invalid image or target size. Image: $imageSize, Target: $targetSize");
      // Set to safe defaults? Or just return? Let's return for now.
      return;
    }

    double finalScale = _calculateScale(pose, imageSize, targetSize);
    final Vector2 finalPosition = Vector2(
        targetSize.x * pose.xcenter,
        targetSize.y * pose.ycenter,
    );
    final Anchor finalAnchor = pose.anchor;

    // Update the component's transform properties
    this.scale = Vector2.all(finalScale);
    this.position = finalPosition;
    this.anchor = finalAnchor;

    // Debug print (optional)
    // print("DissolvingSprite '$characterAlias' updated transform. Pose: ${pose.name}, Scale: ${finalScale.toStringAsFixed(3)}, Position: $finalPosition, Anchor: $finalAnchor");
  }

   /// Calculates the scale factor based on the pose definition and target size.
   double _calculateScale(PoseDefinition pose, Vector2 imageSize, Vector2 targetSize) {
      double finalScale;
      if (pose.scale > 0) { // Relative height scaling
          if (imageSize.y != 0) {
             final targetHeight = targetSize.y * pose.scale;
             finalScale = targetHeight / imageSize.y;
          } else {
             finalScale = 1.0; // Avoid division by zero
          }
      } else if (pose.scale == -1) { // Aspect fill scaling (cover)
          if (imageSize.x != 0 && imageSize.y != 0) {
             final scaleX = targetSize.x / imageSize.x;
             final scaleY = targetSize.y / imageSize.y;
             finalScale = max(scaleX, scaleY); // Use the larger scale factor for fill
          } else {
             finalScale = 1.0;
          }
      } else { // Aspect fit scaling (contain - default for scale == 0 or other negatives)
          if (imageSize.x != 0 && imageSize.y != 0) {
             final scaleX = targetSize.x / imageSize.x;
             final scaleY = targetSize.y / imageSize.y;
             finalScale = min(scaleX, scaleY); // Use the smaller scale factor for fit
          } else {
             finalScale = 1.0;
          }
      }
      // TODO: Consider adding min/max scale constraints from pose if needed
      // finalScale = clamp(finalScale, pose.minScale ?? 0.0, pose.maxScale ?? double.infinity);
      return finalScale;
   }
}