import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For SystemNavigator
import 'dart:io'; // For exit()

import 'settings_menu.dart';
import 'slide_transition_page_route.dart';
import 'ui/main_menu_screen.dart';

class MainMenu extends StatelessWidget {
  const MainMenu({super.key});

  // --- Logic --- 

  void _handleStartNewGame(BuildContext context) {
    // TODO: Implement Start New Game Logic
    print('Start New Game logic executed');
  }

  void _handleContinueGame(BuildContext context) {
    // TODO: Implement Continue Game Logic
    print('Continue Game logic executed');
  }

  void _navigateToSettings(BuildContext context) {
    Navigator.of(context).push(
      SlideTransitionPageRoute(page: const SettingsMenu()),
    );
  }

  void _handleExit(BuildContext context) {
    // Add confirmation dialog later if needed
    if (Platform.isAndroid || Platform.isIOS) {
        SystemNavigator.pop(); // Recommended way for mobile
    } else {
        exit(0); // Standard way for desktop/web
    }
  }

  // --- Build Method --- 

  @override
  Widget build(BuildContext context) {
     // Apply theme here if needed, or let MaterialApp handle it
     // The Theme widget was removed as it mainly affected button styles
     // which are now encapsulated in MenuButton / MainMenuScreen can have its own theme if needed

    return MainMenuScreen(
      onStartNewGame: () => _handleStartNewGame(context),
      onContinueGame: () => _handleContinueGame(context),
      onNavigateSettings: () => _navigateToSettings(context),
      onExit: () => _handleExit(context),
    );
  }
} 