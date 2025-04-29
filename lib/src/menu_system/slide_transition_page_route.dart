import 'package:flutter/material.dart';

class SlideTransitionPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SlideTransitionPageRoute({required this.page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Curves for animations
            const Curve enteringCurve = Curves.easeInOut; 
            const Curve exitingCurve = Curves.easeInOut;
            
            // --- Entering Page Animation (0ms -> 150ms) ---
            // Use Interval(0.0, 0.75) to map the first 150ms of the total duration (200ms * 0.75 = 150ms)
            final CurvedAnimation enteringAnimation = CurvedAnimation(
              parent: animation, 
              curve: const Interval(0.0, 0.75, curve: enteringCurve),
            );
            
            // Entering Fade (0ms -> 150ms)
            final Animation<double> enteringFade = enteringAnimation;
            
            // Entering Slide (0ms -> 100ms)
            const Offset slideFrom = Offset(1.0, 0.0);
            const Offset slideTo = Offset.zero;
            final Tween<Offset> enteringTween = Tween(begin: slideFrom, end: slideTo);
            final Animation<Offset> enteringOffset = enteringTween.animate(enteringAnimation);

            // --- Exiting Page Animation (0ms -> 200ms) ---
            // Use secondaryAnimation directly, it spans the full duration
            final CurvedAnimation exitingAnimation = CurvedAnimation(
              parent: secondaryAnimation, 
              curve: exitingCurve,
            );
            
            // Exiting Slide (0ms -> 200ms)
            const Offset exitTo = Offset(-0.3, 0.0); // Slight left slide
            final Tween<Offset> exitingTween = Tween(begin: Offset.zero, end: exitTo);
            final Animation<Offset> exitingOffset = exitingTween.animate(exitingAnimation);
            
            // Combine transitions
            return FadeTransition(
              opacity: enteringFade, // Entering page fade
              child: SlideTransition(
                position: enteringOffset, // Entering page slide
                child: SlideTransition( 
                   position: exitingOffset, // Exiting page slide
                   child: child,
                ),
              ),
            );
          },
          // Set total duration to the longer one (200ms)
          transitionDuration: const Duration(milliseconds: 300),
        );
} 