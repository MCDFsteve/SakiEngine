import 'package:flutter/material.dart';
// import 'package:shared_preferences/shared_preferences.dart'; // 由 AppWindowState 管理
// import 'package:window_manager/window_manager.dart'; // 由 AppWindowState 管理
import 'dart:io'; // For Platform check
// import 'package:screen_retriever/screen_retriever.dart'; // 由 AppWindowState 管理
import 'package:provider/provider.dart'; // *** 引入 Provider ***

import 'ui/settings_menu_screen.dart';
import 'constants.dart'; 
import '../app_window_state.dart'; // *** 引入 AppWindowState ***

// Constants (Consider moving to a shared file)
// const String _prefResolutionWidth = 'window_width';
// const String _prefResolutionHeight = 'window_height';
// const String _prefIsFullscreen = 'is_fullscreen';
// const List<Size> _supportedResolutions = [
//   // These represent PHYSICAL resolutions
//   Size(1280, 720),
//   Size(1600, 900),
//   Size(1920, 1080),
// ];

class SettingsMenu extends StatefulWidget {
  const SettingsMenu({super.key});

  @override
  State<SettingsMenu> createState() => _SettingsMenuState();
}

// *** 移除 WindowListener, 不再管理本地状态 ***
class _SettingsMenuState extends State<SettingsMenu> {
  // Size? _selectedResolution; // 由 AppWindowState 管理
  // bool _isFullscreen = false; // 由 AppWindowState 管理
  // bool _isLoading = true; // 由 AppWindowState 管理

  // *** 不再需要 initState/dispose (除非有其他用途) ***
  // @override
  // void initState() {
  //   super.initState();
  //   // _loadSettings(); // 由 AppWindowState 在构造时加载
  // }

  // *** 移除所有窗口/尺寸操作逻辑，移到 AppWindowState ***
  // Future<void> _loadSettings() async { ... }
  // Size _calculateWindowedLogicalSize(Size physicalSize) { ... }
  // Future<Size> _calculateFullscreenLogicalSize() async { ... }

  // 分辨率修改回调
  Future<void> _handleResolutionChanged(BuildContext context, Size? newPhysicalResolution) async {
    if (newPhysicalResolution == null) return;
    // *** 调用 AppWindowState 的方法 ***
    await Provider.of<AppWindowState>(context, listen: false).setResolution(newPhysicalResolution);
  }

  // 全屏切换回调
  Future<void> _handleFullscreenChanged(BuildContext context, bool? desiredFullscreen) async {
    if (desiredFullscreen == null) return;
    // *** 调用 AppWindowState 的方法 ***
    final state = Provider.of<AppWindowState>(context, listen: false);
    state.updateFullscreenStatus(desiredFullscreen);
    await state.applyAppropriateWindowModeAndSize(); // 更新状态后应用模式
  }

  // 返回回调
  void _handleGoBack(BuildContext context) {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppWindowState>(
      builder: (context, appState, child) {
        return SettingsMenuScreen(
          // *** 传递动态生成的列表和原生尺寸 ***
          availableResolutions: appState.availableResolutions,
          native16x9PhysicalSize: appState.native16x9PhysicalSize,
          selectedResolution: appState.currentPhysicalResolution, 
          isLoading: appState.isLoading, 
          isFullscreen: appState.isFullscreen, 
          onResolutionChanged: (newRes) => _handleResolutionChanged(context, newRes),
          onFullscreenChanged: (newFullscreen) => _handleFullscreenChanged(context, newFullscreen),
          onGoBack: () => _handleGoBack(context),
        );
      },
    );
  }
} 