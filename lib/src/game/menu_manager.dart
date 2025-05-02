import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart';
import '../utils/adaptive_sizer.dart';
import 'visual_novel_scene.dart'; // Access to game and potentially _findLabel?

// --- Data Structures ---
class MenuOption {
  final String text;
  final int targetLineIndex; // Line index to jump to after label

  MenuOption({required this.text, required this.targetLineIndex});
}

// --- Menu Manager Component ---
class MenuManager extends Component with HasGameReference<VisualNovelGame> {
  List<MenuOption> _currentOptions = [];
  Completer<int>? _menuCompleter; // Completes with the chosen target line index
  MenuDisplayComponent? _currentMenuDisplay;

  // Called by _handleMenuStart
  void startMenu() {
    print("MenuManager: Starting new menu.");
    _currentOptions = [];
    // Dismiss any previous menu instantly
    dismissMenu(); 
  }

  // Called by _handleMenuOption
  void addOption(String text, int targetLineIndex) {
    if (targetLineIndex >= 0) {
       print("MenuManager: Adding option '$text' -> line $targetLineIndex");
      _currentOptions.add(MenuOption(text: text, targetLineIndex: targetLineIndex));
    } else {
       print("MenuManager: WARN - Invalid target line index ($targetLineIndex) for option '$text'. Skipping.");
    }
  }

  // Called by _handleMenuEnd
  Future<int> showMenu() {
     print("MenuManager: Showing menu with ${_currentOptions.length} options.");
    if (_currentOptions.isEmpty) {
      print("MenuManager: ERROR - No options added before showMenu! Returning -1.");
      return Future.value(-1); // Indicate error or no choice
    }

    _menuCompleter = Completer<int>();
    _currentMenuDisplay = MenuDisplayComponent(
      options: _currentOptions.map((opt) => opt.text).toList(), // Pass only text
      onOptionSelected: _onOptionSelected,
    );
    add(_currentMenuDisplay!); // Add display component to manager

    return _menuCompleter!.future;
  }

  // Callback from MenuDisplayComponent
  void _onOptionSelected(int selectedIndex) {
    if (selectedIndex < 0 || selectedIndex >= _currentOptions.length) {
       print("MenuManager: ERROR - Invalid index $selectedIndex selected.");
       _completeMenu(-1); // Indicate error
       return;
    }
    final chosenOption = _currentOptions[selectedIndex];
    print("MenuManager: Option $selectedIndex ('${chosenOption.text}') selected. Target line: ${chosenOption.targetLineIndex}");
    _completeMenu(chosenOption.targetLineIndex);
  }

  void _completeMenu(int targetLineIndex) {
     // Complete the future FIRST with the correct target line
     if (_menuCompleter != null && !_menuCompleter!.isCompleted) {
       print("MenuManager: Completing menu future with target: $targetLineIndex");
       _menuCompleter!.complete(targetLineIndex);
     }
     _menuCompleter = null; // Clear reference *after* completing or checking

     // THEN dismiss the visual component
     dismissMenu(); 
  }

  void dismissMenu() {
    if (_currentMenuDisplay != null) {
      print("MenuManager: Removing MenuDisplayComponent.");
      // Try explicitly calling removeFromParent on the component itself
      _currentMenuDisplay!.removeFromParent(); 
      // Keep the manager's remove call too, just in case
      remove(_currentMenuDisplay!); 
      _currentMenuDisplay = null;
    }
     // Now, this check only triggers if dismissed externally *before* _completeMenu
     if (_menuCompleter != null && !_menuCompleter!.isCompleted) {
       print("MenuManager: Menu dismissed externally. Completing with -1.");
       _menuCompleter!.complete(-1);
       _menuCompleter = null;
     }
  }

   @override
  void onRemove() {
    dismissMenu(); // Clean up on manager removal
    super.onRemove();
  }
}


// --- Menu Display Component ---
// Renders the choices and handles taps
class MenuDisplayComponent extends PositionComponent with TapCallbacks, HasGameReference<VisualNovelGame> {
  final List<String> options;
  final Function(int) onOptionSelected; // Callback with selected index

  // Rendering/Layout related
  late List<TextPainter> _optionPainters;
  late List<Rect> _optionRects;
  late RRect _backgroundRRect;
  final Paint _backgroundPaint = Paint()..color = Colors.black.withOpacity(0.85);
  final Paint _highlightPaint = Paint()..color = Colors.grey.withOpacity(0.5);
  int? _tapDownIndex; // Track which item is being pressed

  static final _sizer = AdaptiveSizer.instance;
  double _padding = 0;
  double _spacing = 0;
  double _optionHeight = 0; // Calculated height per option

  MenuDisplayComponent({
    required this.options,
    required this.onOptionSelected,
  }) : super(priority: 90); // Below dialogue box but above characters/bg

  @override
  Future<void> onLoad() async {
    super.onLoad();
    _performLayout(game.size);
  }

   @override
  void onGameResize(Vector2 newSize) {
    super.onGameResize(newSize);
    _performLayout(newSize);
  }

  void _performLayout(Vector2 gameSize) {
    _sizer.updateSizes(Size(gameSize.x, gameSize.y));

    // --- Calculate Dimensions & Styles ---
    // Simple vertical menu for now
    final double menuWidth = 0.5.sw; // 50% of screen width
    final double horizontalMargin = (1.sw - menuWidth) / 2;
    _padding = 0.03.sw; // Padding inside the menu box
    _spacing = 0.015.sh; // Spacing between options
    final double fontSize = 22.sp;
    final TextStyle optionStyle = TextStyle(color: Colors.white, fontSize: fontSize);

    // --- Layout Painters & Rects ---
    _optionPainters = [];
    _optionRects = [];
    double currentY = _padding;

    for (int i = 0; i < options.length; i++) {
      final painter = TextPainter(
        text: TextSpan(text: options[i], style: optionStyle),
        textDirection: TextDirection.ltr,
      );
      painter.layout(maxWidth: menuWidth - _padding * 2);
      _optionPainters.add(painter);

      // Calculate tap area for this option
      _optionHeight = painter.height + _spacing; // Height includes spacing below
      final rect = Rect.fromLTWH( 
          _padding, 
          currentY - (_spacing / 2), // Center tap area vertically around text slightly
          menuWidth - _padding * 2, 
          _optionHeight
      );
      _optionRects.add(rect);

      currentY += _optionHeight;
    }
    
    // Add final padding at the bottom
    final double totalHeight = currentY + _padding - _spacing; // Remove last spacing

    // --- Set Component Size & Position ---
    size = Vector2(menuWidth, totalHeight);
    // Center the menu vertically? Or place it near the top/middle?
    // Let's place it slightly above center for now.
    position = Vector2(
      horizontalMargin,
      (gameSize.y - totalHeight) * 0.4 // Adjust vertical position (0.5 is center)
    );

    // --- Background ---
    final backgroundRect = Rect.fromLTWH(0, 0, size.x, size.y);
    _backgroundRRect = RRect.fromRectAndRadius(backgroundRect, Radius.circular(15));

    print("MenuDisplayComponent laid out. Size: $size, Position: $position");
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    // Draw background
    canvas.drawRRect(_backgroundRRect, _backgroundPaint);

    // Draw highlight if tapping
    if (_tapDownIndex != null && _tapDownIndex! < _optionRects.length) {
      canvas.drawRect(_optionRects[_tapDownIndex!], _highlightPaint);
    }

    // Draw options
    double currentY = _padding;
    for (int i = 0; i < _optionPainters.length; i++) {
       // Draw text centered within its rect calculation height? Or just top-aligned?
       // Top-aligned for simplicity
       _optionPainters[i].paint(canvas, Offset(_padding, currentY));
       currentY += _optionHeight; // Use precalculated height + spacing
    }
  }

   @override
  void onTapDown(TapDownEvent event) {
    print("MenuDisplayComponent: onTapDown received at ${event.localPosition}");
    final localPos = event.localPosition;
     _tapDownIndex = _getTouchedIndex(localPos);
      if (_tapDownIndex != null) {
         print("  -> Tapped down on option index: ${_tapDownIndex}");
      } else {
         print("  -> Tapped down outside any option rect.");
      }
  }

  @override
  void onTapUp(TapUpEvent event) {
     print("MenuDisplayComponent: onTapUp received at ${event.localPosition}");
     final localPos = event.localPosition;
     final releasedIndex = _getTouchedIndex(localPos);
     print("  -> Tap up state: downIndex=$_tapDownIndex, releasedIndex=$releasedIndex");
     if (_tapDownIndex != null && releasedIndex == _tapDownIndex) {
        print("  -> SUCCESS: Valid tap on index $releasedIndex. Calling onOptionSelected...");
        onOptionSelected(releasedIndex!); 
        print("  -> onOptionSelected called.");
     } else {
        print("  -> Tap up conditions not met (moved off option or tapped outside).");
     }
     _tapDownIndex = null; // Reset tap down state
  }

   @override
  void onTapCancel(TapCancelEvent event) {
      print("MenuDisplayComponent: onTapCancel received.");
      _tapDownIndex = null; // Reset tap down state if drag off etc.
  }

  // Helper to find which option index was touched
  int? _getTouchedIndex(Vector2 localPosition) {
      for (int i = 0; i < _optionRects.length; i++) {
          if (_optionRects[i].contains(localPosition.toOffset())) {
             return i;
          }
      }
      return null;
  }
} 