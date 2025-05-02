import 'package:flutter/material.dart';
import '../game/visual_novel_scene.dart' show MenuItem; // Import MenuItem definition
import 'package:sakiengine/src/utils/adaptive_sizer.dart'; // For adaptive sizing

class MenuView extends StatelessWidget {
  final List<MenuItem> menuItems;
  final Function(int) onOptionSelected; // Callback with target line index

  const MenuView({
    super.key,
    required this.menuItems,
    required this.onOptionSelected,
  });

  @override
  Widget build(BuildContext context) {
    // Use MediaQuery for screen size for positioning calculations
    // Note: AdaptiveSizer is typically for Flame components, but we can use its extensions here
    // if we ensure the sizer is updated somewhere (e.g., in the game's resize)
    // For simplicity here, let's use MediaQuery first.
    final screenSize = MediaQuery.of(context).size;
    final sizer = AdaptiveSizer.instance; // Get sizer instance
    sizer.updateSizes(screenSize); // Ensure sizer has up-to-date screen size

    // --- Style Constants ---
    final double buttonWidth = 0.6.sw; // 60% of fitted screen width
    final double verticalSpacing = 0.02.sh; // Spacing between buttons
    final double buttonPaddingVertical = 0.015.sh;
    final double buttonPaddingHorizontal = 0.03.sw;
    final double fontSize = 20.sp;
    final Color buttonColor = Colors.black.withOpacity(0.8);
    final Color textColor = Colors.white;
    final BorderRadius borderRadius = BorderRadius.circular(10.0);

    // --- Calculate total height needed for positioning ---
    // Estimate height based on font size, padding, and spacing (might need adjustment)
    final estimatedTextHeight = fontSize * 1.5; // Rough estimate per line
    final buttonHeight = estimatedTextHeight + buttonPaddingVertical * 2;
    final totalMenuHeight = (buttonHeight * menuItems.length) + (verticalSpacing * (menuItems.length - 1));
    final topOffset = (screenSize.height - totalMenuHeight) * 0.4; // Start position (adjust 0.4 for vertical centering)

    return Stack(
      children: List.generate(menuItems.length, (index) {
        final item = menuItems[index];
        final buttonTop = topOffset + (buttonHeight + verticalSpacing) * index;

        return Positioned(
          left: (screenSize.width - buttonWidth) / 2, // Center horizontally
          top: buttonTop,
          child: ElevatedButton(
             style: ElevatedButton.styleFrom(
               backgroundColor: buttonColor,
               foregroundColor: textColor,
               minimumSize: Size(buttonWidth, buttonHeight), // Control size
               padding: EdgeInsets.symmetric(
                 vertical: buttonPaddingVertical,
                 horizontal: buttonPaddingHorizontal,
               ),
               shape: RoundedRectangleBorder(
                 borderRadius: borderRadius,
               ),
               textStyle: TextStyle(fontSize: fontSize),
             ),
            onPressed: () {
              print("MenuView: Button '${item.text}' pressed.");
              onOptionSelected(item.targetLineIndex);
            },
            child: Text(item.text, textAlign: TextAlign.center),
          ),
        );
      }),
    );
  }
} 