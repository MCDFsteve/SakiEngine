import 'package:flutter/material.dart';
import 'dart:math'; // Import math for min
import '../../main.dart'; // To access kIsDesktopOS

/// A Scaffold that automatically constrains its body to a 16:9 aspect ratio
/// centered on the screen, but only on non-desktop platforms.
/// On desktop platforms, it behaves like a normal Scaffold.
class Constrained16x9Scaffold extends StatelessWidget {
  final Widget body;
  final Color backgroundColor;

  const Constrained16x9Scaffold({
    super.key,
    required this.body,
    // Change default background color to pure black for letterboxing
    this.backgroundColor = Colors.black,
  });

  @override
  Widget build(BuildContext context) {
    const Color innerBackgroundColor = Color(0xFF0a192f);
    
    // Create the body wrapped with its inner background color ONCE
    final Widget wrappedBody = Container(
      color: innerBackgroundColor,
      child: body,
    );
    
    // REMOVE print statement
    // print('>>> Constrained16x9Scaffold: kIsDesktopOS = $kIsDesktopOS');
    
    if (kIsDesktopOS) {
      // On desktop, use the wrapped body directly
      return Scaffold(
        backgroundColor: backgroundColor, // Outer background (black)
        body: wrappedBody,
      );
    } else {
      // On non-desktop, calculate the 16:9 size manually and use SizedBox
      return Scaffold(
        // Apply the outer background color (black for letterbox)
        backgroundColor: backgroundColor,
        body: Center(
          // Use LayoutBuilder to get parent constraints
          child: LayoutBuilder(
            builder: (context, constraints) {
              // REMOVE print statement for constraints
              // print('>>> LayoutBuilder constraints: MaxW=${constraints.maxWidth}, MaxH=${constraints.maxHeight}');
              
              if (constraints.maxWidth.isInfinite || constraints.maxHeight.isInfinite) {
                  // REMOVE print statement for error
                  // print('>>> Error: Infinite constraints!');
                  return const Center(child: Text("Error: Infinite constraints"));
              }
              
              final double availableWidth = constraints.maxWidth;
              final double availableHeight = constraints.maxHeight;
              const double targetAspectRatio = 16.0 / 9.0;
              
              double targetWidth;
              double targetHeight;
              
              // Calculate the largest 16:9 box that fits
              if (availableWidth / availableHeight > targetAspectRatio) {
                  // Available space is wider than 16:9 (use full height)
                  targetHeight = availableHeight;
                  targetWidth = targetHeight * targetAspectRatio;
              } else {
                  // Available space is taller or equal to 16:9 (use full width)
                  targetWidth = availableWidth;
                  targetHeight = targetWidth / targetAspectRatio;
              }
              
              // Wrap the body in a Container with the desired inner background color
              // AND wrap that container with ClipRect to enforce visual bounds.
              return SizedBox(
                width: targetWidth,
                height: targetHeight,
                child: ClipRect(
                  child: wrappedBody,
                ),
              );
            }
          ),
        ),
      );
    }
  }
} 