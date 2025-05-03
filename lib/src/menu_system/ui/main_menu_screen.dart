import '../../utils/adaptive_sizer.dart'; // Import the new sizer
// import '../../utils/resolution_sizer.dart'; // REMOVED
// import 'package:flutter_screenutil/flutter_screenutil.dart'; // REMOVED
import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // Import Provider
import 'dart:math'; // Import for min
import '../widgets/menu_button.dart'; // 引入可复用的按钮
import '../../widgets/constrained_scaffold.dart'; // Import the wrapper
import '../../app_window_state.dart'; // Correct import path for AppWindowState

// 主菜单的 UI 界面 (StatelessWidget)
class MainMenuScreen extends StatelessWidget {
  // 定义按钮点击的回调函数
  final VoidCallback onStartNewGame;
  final VoidCallback onContinueGame;
  final VoidCallback onNavigateSettings;
  final VoidCallback onExit;

  // 构造函数，接收回调
  const MainMenuScreen({
    super.key,
    required this.onStartNewGame,
    required this.onContinueGame,
    required this.onNavigateSettings,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    // Watch for sizer changes to rebuild
    context.watch<AdaptiveSizer>();
    // Also watch AppWindowState to force rebuild on resolution/fullscreen changes
    context.watch<AppWindowState>(); 
    
    // Center the potentially scrollable content block
    return Constrained16x9Scaffold(
      body: Center( // Center the SingleChildScrollView
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min, // Fit content vertically
            mainAxisAlignment: MainAxisAlignment.center, // Center if space available
            crossAxisAlignment: CrossAxisAlignment.center, // Center horizontally
            children: [
              // Title Widget
              Text(
                '引入新世界\nuse world::new;',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 64.sp,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      offset: Offset(0.001.sw, 0.0015.sh),
                      blurRadius: min(1.sw, 1.sh) * 0.005,
                      color: Color.fromARGB(150, 0, 0, 0),
                    ),
                  ]
                ),
              ),
              // Explicit Spacing between title and menu panel
              SizedBox(height: 0.03.sh),
              // Menu Panel Container (already centered by outer Center)
              Container(
                width: 0.25.sw, // Constrain width
                padding: EdgeInsets.symmetric(vertical: 0.05.sh, horizontal: 0.02.sw),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(min(1.sw, 1.sh) * 0.025),
                  border: Border.all(color: Colors.cyan.withOpacity(0.5), width: 0.0015.sw)
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MenuButton(text: '新游戏', onPressed: onStartNewGame),
                    SizedBox(height: 0.015.sh),
                    MenuButton(text: '继续游戏', onPressed: onContinueGame),
                    SizedBox(height: 0.015.sh),
                    MenuButton(text: '设置', onPressed: onNavigateSettings),
                    SizedBox(height: 0.015.sh),
                    MenuButton(text: '退出', onPressed: onExit),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
} 