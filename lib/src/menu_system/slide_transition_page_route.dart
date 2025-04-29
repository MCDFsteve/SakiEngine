import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart'; // Keep import for .ms extension

class SlideTransitionPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SlideTransitionPageRoute({required this.page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            
            // --- 设置页面动画 (Fade Transition, driven by animation) ---
            // Simplify the top page animation for debugging pop transition
            final Widget settingsPageAnimated = FadeTransition(
                opacity: animation, // Fades in on push (0->1), fades out on pop (1->0)
                child: child,
            );

            // --- 主菜单页面动画 (Slide Transition, driven by secondaryAnimation) ---
            final Tween<Offset> mainMenuTween = Tween(begin: Offset.zero, end: const Offset(-0.3, 0.0));
            final Animation<Offset> mainMenuOffset = mainMenuTween.animate(
              CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOut)
            );

            // Apply secondary animation (main menu slide) to the structure
            return SlideTransition(
              position: mainMenuOffset, // Controls main menu (underneath) slide
              child: settingsPageAnimated, // Apply settings page fade
            );
          },
          // Keep user set duration
          transitionDuration: const Duration(milliseconds: 300),
        );
} 