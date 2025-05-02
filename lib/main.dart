import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
// import 'package:flutter_screenutil/flutter_screenutil.dart'; // Remove ScreenUtil import
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// 引入主菜单和常量
import 'src/menu_system/main_menu.dart';
import 'src/app_window_state.dart';
import 'src/utils/adaptive_sizer.dart'; // Import the new sizer
import 'src/widgets/constrained_scaffold.dart'; // Import the new wrapper

// Global constant indicating if the platform is a desktop OS
// Defaults to false on the web, as Platform is not available.
final bool kIsDesktopOS = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize window manager only on desktop OS
  if (kIsDesktopOS) {
    await windowManager.ensureInitialized();
    
    // Disable maximization
    await windowManager.setMaximizable(false);
  }

  final appWindowState = AppWindowState();
  // No static init needed for AdaptiveSizer here

  runApp(SakiEngine(appWindowState: appWindowState));
}

class SakiEngine extends StatefulWidget {
  final AppWindowState appWindowState;
  const SakiEngine({super.key, required this.appWindowState});

  @override
  State<SakiEngine> createState() => _SakiEngineState();
}

class _SakiEngineState extends State<SakiEngine> with WindowListener {

  @override
  void initState() {
    super.initState();
    // Add window listener and setup initial size only on desktop OS
    if (kIsDesktopOS) {
         windowManager.addListener(this);
         WidgetsBinding.instance.addPostFrameCallback((_) { 
             if (!widget.appWindowState.isLoading) {
                 widget.appWindowState.applyAppropriateWindowModeAndSize();
             } else {
                 widget.appWindowState.addListener(_applyInitialModeWhenReady);
             }
         });
    }
  }

  // This callback might still be added even if not Desktop, needs the check inside
  void _applyInitialModeWhenReady() {
      // Apply window size only if on desktop and state is ready
      if (kIsDesktopOS && !widget.appWindowState.isLoading) {
          widget.appWindowState.applyAppropriateWindowModeAndSize();
          widget.appWindowState.removeListener(_applyInitialModeWhenReady);
      }
      // If not desktop, but listener was added somehow, remove it once loading is done
      else if (!kIsDesktopOS && !widget.appWindowState.isLoading) {
           widget.appWindowState.removeListener(_applyInitialModeWhenReady);
      }
  }

  @override
  void dispose() {
    // Remove window listener only on desktop OS
    if (kIsDesktopOS) {
        windowManager.removeListener(this);
    }
    widget.appWindowState.removeListener(_applyInitialModeWhenReady);
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    widget.appWindowState.updateFullscreenStatus(true);
    // Apply window size only on desktop OS
    if (kIsDesktopOS) {
      widget.appWindowState.applyAppropriateWindowModeAndSize();
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    widget.appWindowState.updateFullscreenStatus(false);
    // Apply window size only on desktop OS
    if (kIsDesktopOS) {
      widget.appWindowState.applyAppropriateWindowModeAndSize();
    }
  }

  @override
  void onWindowClose() {}
  @override
  void onWindowFocus() {}
  @override
  void onWindowBlur() {}
  @override
  void onWindowMaximize() {}
  @override
  void onWindowUnmaximize() {}
  @override
  void onWindowMinimize() {}
  @override
  void onWindowRestore() {}
  @override
  void onWindowResize() {}
  @override
  void onWindowMove() {}

  @override
  Widget build(BuildContext context) {
    // Use MultiProvider to provide both AppWindowState and AdaptiveSizer
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.appWindowState),
        ChangeNotifierProvider.value(value: AdaptiveSizer.instance),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final currentSize = Size(constraints.maxWidth, constraints.maxHeight);
          
          // Schedule the size update for after the current build frame
          WidgetsBinding.instance.addPostFrameCallback((_) { 
            // Check if the sizer instance still needs update, avoids unnecessary calls if disposed
            // Although with singleton, unlikely to be disposed here.
            AdaptiveSizer.instance.updateSizes(currentSize);
          });

          // Still watch here to ensure LayoutBuilder rebuilds when sizer notifies
          context.watch<AdaptiveSizer>();

          // Return the MaterialApp
          return MaterialApp(
            title: 'SakiEngine',
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
              visualDensity: VisualDensity.adaptivePlatformDensity,
              scaffoldBackgroundColor: Colors.black,
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
                  TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
                  TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
                },
              ),
            ),
            debugShowCheckedModeBanner: false,
            home: Constrained16x9Scaffold(
               body: MainMenu(),
            ),
          );
        }
      ),
    );
  }
}


