import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart';
import '../utils/adaptive_sizer.dart'; // Import sizer for UI calculations
// Import VisualNovelGame to access game-level properties if needed, like size
import 'visual_novel_scene.dart'; 
import 'package:flame/effects.dart'; // Keep Effects for DialogueManager if needed later?
import 'indicator_component.dart'; // <<< IMPORT new file

// Manages the display and dismissal of dialogue boxes
class DialogueManager extends Component with HasGameReference<VisualNovelGame> {
  Completer<void>? _dialogueCompleter;
  DialogueBoxComponent? _currentDialogueBox;

  // <<< ADDED: Getter to check visibility >>>
  bool get isDialogueVisible => _currentDialogueBox != null;

  // Method called by the game to show dialogue
  Future<void> showDialogue(String character, String dialogue) {
    // If another dialogue is requested before the previous one is dismissed,
    // complete the previous one immediately.
    dismissDialogue(); 

    _dialogueCompleter = Completer<void>();
    _currentDialogueBox = DialogueBoxComponent(
      character: character,
      dialogue: dialogue,
      // REMOVED: onTap callback
      // onTap: _onDialogueTap, 
    );
    add(_currentDialogueBox!); // Add the component to the manager's tree
    
    print("DialogueManager: Added DialogueBoxComponent for '$character'.");
    return _dialogueCompleter!.future;
  }

  // REMOVED: Callback function 
  /*
  void _onDialogueTap() {
     print("DialogueManager: Dialogue tapped.");
     dismissDialogue();
  }
  */

  // Helper to dismiss the current dialogue and complete its future
  // This is now called externally by VisualNovelGame.onTapUp
  void dismissDialogue() {
    if (_currentDialogueBox != null) {
      print("DialogueManager: Removing DialogueBoxComponent.");
      _currentDialogueBox!.removeFromParent(); // Use explicit remove
      remove(_currentDialogueBox!); 
      _currentDialogueBox = null;
    }
    if (_dialogueCompleter != null && !_dialogueCompleter!.isCompleted) {
      print("DialogueManager: Completing dialogue future (via dismissDialogue).");
      _dialogueCompleter!.complete();
      _dialogueCompleter = null;
    }
  }

  @override
  void onRemove() {
    // Ensure resources are cleaned up if the manager itself is removed
    dismissDialogue();
    super.onRemove();
  }
}


// The visual component for the dialogue box
// --- REMOVED TapCallbacks --- 
class DialogueBoxComponent extends PositionComponent with HasGameReference<VisualNovelGame> {
  final String character;
  final String dialogue;
  // REMOVED: final VoidCallback onTap;

  // --- Rendering artifacts --- 
  late TextPainter _characterPainter;
  late TextPainter _dialoguePainter;
  late RRect _backgroundRRect; // For rounded corners
  final Paint _backgroundPaint = Paint()..color = Colors.black.withOpacity(0.7);
  // REMOVED: Icon paint and path
  // final Paint _iconPaint = Paint()
  //     ..color = Colors.white.withOpacity(0.5)
  //     ..style = PaintingStyle.fill;
  // late Path _iconPath; 

  // --- Sizing related --- 
  static final _sizer = AdaptiveSizer.instance;
  double _padding = 0; // For left/right padding
  double _spacing = 0;
  double _iconSize = 0;
  double _topPadding = 0; // <<< ADDED: Specific top padding

  // --- Child Components ---
  IndicatorComponent? _indicator; // Still needed

  DialogueBoxComponent({
    required this.character,
    required this.dialogue,
    // REMOVED: required this.onTap,
  }) : super(priority: 100); // High priority to draw over other elements

  @override
  Future<void> onLoad() async {
    super.onLoad();
    _performLayout(game.size);
    print("DialogueBoxComponent loaded. Initial Size: $size, Position: $position");
  }

  // --- NEW: Handle game resize --- 
  @override
  void onGameResize(Vector2 newSize) {
    super.onGameResize(newSize);
    print("DialogueBoxComponent resizing to: $newSize");
    _performLayout(newSize); // Re-layout with the new size
    print("DialogueBoxComponent resized. New Size: $size, New Position: $position");
  }

  // --- NEW: Central layout logic --- 
  void _performLayout(Vector2 gameSize) {
    // 1. Update Sizer
    _sizer.updateSizes(Size(gameSize.x, gameSize.y));

    // 2. Calculate Dimensions
    final boxHeight = 0.25.sh;
    final boxWidth = 0.9.sw;
    final bottomMargin = 0.05.sh;
    final horizontalMargin = (1.sw - boxWidth) / 2;
    _padding = 0.02.sw; // Keep this for left/right padding
    _spacing = 0.01.sh;
    _iconSize = 0.03.sh;
    _topPadding = 0.02.sh; // <<< CALCULATE top padding (e.g., 2% of screen height)
    final titleFontSize = 36.sp;
    final dialogueFontSize = 24.sp;

    // 3. Update Component Size & Position
    size = Vector2(boxWidth, boxHeight);
    position = Vector2(horizontalMargin, gameSize.y - boxHeight - bottomMargin);

    // 4. Re-layout Painters
    // <<< Set text color based on whether character name is literal "空白" >>>
    final characterColor = character != "空白" ? Colors.yellowAccent : Colors.transparent;
    _characterPainter = TextPainter(
      text: TextSpan(
        text: character, // Use the actual character name (will be "空白" sometimes)
        style: TextStyle(
          color: characterColor, // <<< Use conditional color
          fontWeight: FontWeight.bold,
          fontSize: titleFontSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    _characterPainter.layout();

    _dialoguePainter = TextPainter(
      text: TextSpan(
        text: dialogue,
        style: TextStyle(
          color: Colors.white,
          fontSize: dialogueFontSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    // Layout dialogue using left/right padding for width constraint
    _dialoguePainter.layout(maxWidth: boxWidth - _padding * 2); 

    // 5. Update Background RRect
    final backgroundRect = Rect.fromLTWH(0, 0, size.x, size.y);
    _backgroundRRect = RRect.fromRectAndRadius(backgroundRect, Radius.circular(10));

    // 6. REMOVE old icon path calculation
    /*
    _iconPath = Path();
    ...
    _iconPath.close();
    */

    // Update or Create Indicator Component
    final indicatorPosition = Vector2(
      size.x - _padding - _iconSize, // Position using left/right padding
      size.y - _padding - _iconSize, // Position using bottom (default) padding
    );
    if (_indicator == null) {
      _indicator = IndicatorComponent(size: _iconSize);
      _indicator!.position = indicatorPosition;
      add(_indicator!); // Add as child
    } else {
      _indicator!.updateSize(_iconSize);
      _indicator!.position = indicatorPosition;
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    canvas.drawRRect(_backgroundRRect, _backgroundPaint);
    double currentY = _topPadding;
    
    // <<< Always paint character name (but it might be transparent) >>>
    _characterPainter.paint(canvas, Offset(_padding, currentY));
    
    // Always advance currentY by the calculated height 
    currentY += _characterPainter.height + _spacing;

    _dialoguePainter.paint(canvas, Offset(_padding, currentY));
    // Indicator renders itself via child component
  }

  // REMOVED onTapUp, onTapDown, onTapCancel
  /*
  @override
  void onTapUp(TapUpEvent event) { ... }
  */

  @override
  void onRemove() {
    // Ensure child components are also cleaned up if needed, though Flame handles this
    super.onRemove(); 
  }
}

// --- REMOVED: Indicator Component ---
/*
class IndicatorComponent extends PositionComponent {
  ...
}
*/ 