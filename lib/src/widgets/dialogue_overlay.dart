import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../game/visual_novel_scene.dart'; // To call acknowledgeDialogue
import '../state/dialogue_state.dart';
import '../utils/adaptive_sizer.dart';
import 'indicator_widget.dart';

class DialogueOverlayWidget extends StatelessWidget {
  const DialogueOverlayWidget({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dialogueState = context.watch<DialogueStateNotifier>().state;
    final game = context.read<VisualNovelGame>();
    final sizer = AdaptiveSizer.instance;
    final mediaQuerySize = MediaQuery.of(context).size;
    sizer.updateSizes(mediaQuerySize);

    // --- Dimensions --- 
    final boxHeight = 0.25.sh;
    final boxWidth = 0.9.sw;
    final bottomMargin = 0.05.sh;
    final horizontalMargin = (1.sw - boxWidth) / 2;
    final paddingH = 0.02.sw;
    final paddingV = 0.02.sh; // Vertical padding for main box
    final spacing = 0.01.sh;
    final indicatorSize = 0.07.sh;
    final titleFontSize = 32.sp;
    final dialogueFontSize = 26.sp;
    final namePaddingH = 20.sp; // Horizontal padding for name box
    final namePaddingV = 6.sp;  // Vertical padding for name box
    final nameOffset = 15.sp; // How much the name box overlaps/offsets

    if (!dialogueState.isVisible) {
      return const SizedBox.shrink();
    }

    final character = dialogueState.character;
    final dialogue = dialogueState.dialogue;
    final bool isCharacterBlank = (character == "空白");

    // Text Styles
    final characterTextStyle = TextStyle(
      color: const Color.fromARGB(255, 255, 240, 214), // Name box text color (always white now)
      fontWeight: FontWeight.bold,
      fontSize: titleFontSize,
    );
    final dialogueTextStyle = TextStyle(
      color: Colors.white,
      fontSize: dialogueFontSize,
    );

    // --- Calculate Positions ---
    // Main dialogue box top Y position
    final mainBoxTopY = mediaQuerySize.height - bottomMargin - boxHeight;
    // Main dialogue box left X position (same as horizontalMargin)
    final mainBoxLeftX = horizontalMargin;

    // --- Build Widgets ---
    // 1. Main Dialogue Box (without name)
    Widget mainDialogueBox = Positioned(
      bottom: bottomMargin,
      left: mainBoxLeftX,
      right: horizontalMargin, // Use right margin to constrain width implicitly
      height: boxHeight,
      child: GestureDetector(
        onTap: () {
          print("DialogueOverlayWidget: Tapped! Acknowledging dialogue...");
          game.acknowledgeDialogue(); // Call acknowledge on tap
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10.0),
          child: Container(
            padding: EdgeInsets.only(
              left: paddingH,
              right: paddingH,
              top: paddingV + (nameOffset / 2), // Add space for name box overlap
              bottom: paddingV,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
            ),
            child: Stack(
              children: [
                // --- Dialogue Text Column (No Character Name Here) ---
                // Padding is now handled by the Container's padding
                Column(
                   crossAxisAlignment: CrossAxisAlignment.start,
                   children: [
                     Expanded(
                       child: SingleChildScrollView(
                         child: Text(
                           dialogue,
                           style: dialogueTextStyle,
                         ),
                       ),
                     ),
                   ],
                 ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: IndicatorWidget(size: indicatorSize),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // 2. Character Name Box (only if character is not blank)
    Widget characterNameBox = const SizedBox.shrink(); // Default to empty
    if (!isCharacterBlank) {
      // Calculate approximate bottom position for the name box
      // It should be positioned relative to the top edge of the main box
      final nameBoxBottom = bottomMargin + boxHeight - nameOffset; // Position bottom relative to main box top

      characterNameBox = Positioned(
        // Position using bottom and left
        bottom: nameBoxBottom + 0.015.sh, // <<< ADD bottom positioning
        left: mainBoxLeftX, // Keep left offset
        // We don't set height/width explicitly, let the content decide
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(25.0), // Match ClipRRect radius
            border: Border.all(
              color: Colors.white,
              width: 1, 
            ),
          ),
          child: ClipRRect( // Inner clip for content and blur
            borderRadius: BorderRadius.circular(25.0), 
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0), 
              child: Container( // Inner container for background and text
                padding: EdgeInsets.symmetric(horizontal: namePaddingH, vertical: namePaddingV),
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 138, 138, 138).withOpacity(0.4), 
                  // <<< REMOVE border from inner container >>>
                  // border: Border.all(...),
                ),
                child: Text(
                  character,
                  style: characterTextStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Return based on whether the name box is present
    if (isCharacterBlank) {
      // If character is blank, only return the main dialogue box
      return mainDialogueBox; 
    } else {
      // Otherwise, return the Stack with both
      return Stack(
        // Make sure Stack allows overflow if name box goes slightly outside bounds
        clipBehavior: Clip.none, 
        children: [
          mainDialogueBox,
          characterNameBox, // This is the actual Positioned widget here
        ],
      );
    }
  }
} 