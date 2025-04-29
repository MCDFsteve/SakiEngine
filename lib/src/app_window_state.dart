import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // Import kIsWeb
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'package:screen_retriever/screen_retriever.dart';
import '../main.dart'; // Import main.dart to access kIsDesktopOS
import 'menu_system/constants.dart'; // 引入常量

// 应用窗口状态管理类
class AppWindowState extends ChangeNotifier {
  bool _isFullscreen = false;
  Size? _currentPhysicalResolution; // 当前窗口模式下的物理分辨率
  Size? _native16x9PhysicalSize; // *** 新增：计算得到的原生16:9物理尺寸 ***
  List<Size> _availableResolutions = []; // *** 新增：动态生成的可用分辨率列表 ***
  bool _isLoading = true; // 初始加载状态

  bool get isFullscreen => _isFullscreen;
  Size? get currentPhysicalResolution => _currentPhysicalResolution;
  Size? get native16x9PhysicalSize => _native16x9PhysicalSize; // Getter
  List<Size> get availableResolutions => _availableResolutions; // Getter
  bool get isLoading => _isLoading;

  AppWindowState() {
    _initializeWindowState(); // *** 修改：调用新的初始化方法 ***
  }

  // *** 新增：计算原生16:9物理尺寸的辅助方法 ***
  Future<Size?> _calculateNative16x9PhysicalSize() async {
    // *** Use kIsDesktopOS for platform check ***
    if (!kIsDesktopOS) return null;
    try {
      Display primaryDisplay = await screenRetriever.getPrimaryDisplay();
      // *** 获取逻辑尺寸和缩放因子 ***
      double logicalWidth = primaryDisplay.size.width;
      double logicalHeight = primaryDisplay.size.height;
      double scaleFactor = Platform.isMacOS ? (primaryDisplay.scaleFactor ?? 2.0).toDouble() : 1.0;
      // *** 计算物理尺寸 ***
      double monitorWidth = logicalWidth * scaleFactor;
      double monitorHeight = logicalHeight * scaleFactor;
      
      print('AppWindowState: Primary display logical size: ${logicalWidth}x$logicalHeight, scaleFactor: $scaleFactor, physical: ${monitorWidth}x$monitorHeight');
      
      double targetAspectRatio = 16.0 / 9.0;
      double monitorAspectRatio = monitorWidth / monitorHeight;
      double targetPhysicalWidth, targetPhysicalHeight;

      if (monitorAspectRatio > targetAspectRatio) {
          targetPhysicalHeight = monitorHeight;
          targetPhysicalWidth = targetPhysicalHeight * targetAspectRatio;
      } else if (monitorAspectRatio < targetAspectRatio) {
          targetPhysicalWidth = monitorWidth;
          targetPhysicalHeight = targetPhysicalWidth / targetAspectRatio;
      } else {
          targetPhysicalWidth = monitorWidth;
          targetPhysicalHeight = monitorHeight;
      }
      // *** 返回计算出的最大 16:9 *物理* 尺寸 ***
      Size nativeSize = Size(targetPhysicalWidth.roundToDouble(), targetPhysicalHeight.roundToDouble());
      print('AppWindowState: Calculated Native 16:9 physical size: ${nativeSize.width}x${nativeSize.height}');
      return nativeSize;
    } catch (e) {
      print('AppWindowState: Error calculating native 16:9 size: $e');
      return null;
    }
  }

  // *** 重写：初始化逻辑 ***
  Future<void> _initializeWindowState() async {
     _isLoading = true;
     notifyListeners(); // 开始加载，通知 UI 显示 Loading

     // *** Use kIsDesktopOS for platform check ***
     if (!kIsDesktopOS) {
      _currentPhysicalResolution = const Size(defaultWidth, defaultHeight); // 非桌面平台用默认值
      _availableResolutions = [_currentPhysicalResolution!];
      _isLoading = false;
      notifyListeners();
      return;
     }

     try {
        // 1. 计算原生16:9尺寸
        _native16x9PhysicalSize = await _calculateNative16x9PhysicalSize();

        // 2. 生成可用分辨率列表
        final baseResolutions = <Size>{
             const Size(1280, 720),
             const Size(1600, 900),
             const Size(1920, 1080),
             const Size(2560, 1440),
        };
        if (_native16x9PhysicalSize != null) {
            baseResolutions.add(_native16x9PhysicalSize!); // 添加原生尺寸，Set 自动去重
        }
        _availableResolutions = baseResolutions.toList();
        // 按宽度排序
        _availableResolutions.sort((a, b) => a.width.compareTo(b.width)); 
        print('AppWindowState: Available Resolutions: $_availableResolutions');

        // 3. 加载保存的设置并确定当前分辨率
        final prefs = await SharedPreferences.getInstance();
        final double? savedWidth = prefs.getDouble(prefResolutionWidth);
        final double? savedHeight = prefs.getDouble(prefResolutionHeight);
        Size? savedSize = (savedWidth != null && savedHeight != null) ? Size(savedWidth, savedHeight) : null;
        
        // 检查保存的尺寸是否在可用列表中
        bool useSaved = savedSize != null && _availableResolutions.any((res) => res.width == savedSize.width && res.height == savedSize.height);

        if (useSaved) {
             _currentPhysicalResolution = savedSize;
             print('AppWindowState: Using saved resolution: $_currentPhysicalResolution');
        } else {
            // *** First launch or invalid saved: Determine appropriate default ***
            bool defaultSet = false;
            
            // Prefer 1440p on macOS if available
            if (kIsDesktopOS && Platform.isMacOS) {
               const Size default1440p = Size(2560.0, 1440.0);
               bool is1440pAvailable = _availableResolutions.any((res) => res.width == default1440p.width && res.height == default1440p.height);
               if (is1440pAvailable) {
                  _currentPhysicalResolution = default1440p;
                  print('AppWindowState: Using macOS default 1440p resolution: $_currentPhysicalResolution');
                  defaultSet = true;
               }
            }

            // If no macOS default set, try 720p on any platform
            if (!defaultSet) {
              const Size default720p = Size(1280.0, 720.0);
              bool is720pAvailable = _availableResolutions.any((res) => res.width == default720p.width && res.height == default720p.height);
              if (is720pAvailable) {
                  _currentPhysicalResolution = default720p;
                  print('AppWindowState: Using default 720p resolution: $_currentPhysicalResolution');
                  defaultSet = true;
              }
            }

            // Fallback if no preferred default is available
            if (!defaultSet) {
                _currentPhysicalResolution = _native16x9PhysicalSize ?? (_availableResolutions.isNotEmpty ? _availableResolutions[0] : const Size(defaultWidth, defaultHeight));
                print('AppWindowState: Preferred defaults not available. Using fallback (Native or first available): $_currentPhysicalResolution');
            }
            
            // 将选定的默认值保存回去
            await prefs.setDouble(prefResolutionWidth, _currentPhysicalResolution!.width);
            await prefs.setDouble(prefResolutionHeight, _currentPhysicalResolution!.height);
            print('AppWindowState: Saved default resolution preference.');
        }
        
        // 4. 加载全屏状态
        _isFullscreen = prefs.getBool(prefIsFullscreen) ?? false;
        print('AppWindowState: Initial state loaded - Res: $_currentPhysicalResolution, FullscreenPref: $_isFullscreen');

     } catch (e) {
        print('AppWindowState: Error initializing window state: $e');
        // 出错时的 Fallback 逻辑
        _availableResolutions = [const Size(defaultWidth, defaultHeight)];
        _currentPhysicalResolution = _availableResolutions[0];
        _native16x9PhysicalSize = _currentPhysicalResolution; // Fallback native
        _isFullscreen = false;
     } finally {
        _isLoading = false;
        notifyListeners(); // 加载完成，通知 UI 更新
     }
  }

  // 更新内部全屏状态（由 Listener 或 UI 调用）
  void updateFullscreenStatus(bool newStatus) {
    if (_isFullscreen != newStatus) {
      print('AppWindowState: Updating fullscreen status to $newStatus');
      _isFullscreen = newStatus;
      // 保存偏好设置
      _saveFullscreenPreference(newStatus);
      // 通知监听者 UI 更新
      notifyListeners(); 
    }
  }

  // 应用正确的窗口模式和尺寸（由 Listener 或 UI 调用）
  Future<void> applyAppropriateWindowModeAndSize() async {
     // *** Use kIsDesktopOS for platform check ***
     if (!kIsDesktopOS) return;
     print('AppWindowState: Applying appropriate window mode and size. Target fullscreen: $_isFullscreen');
     
     try {
        bool currentActualFullscreen = await windowManager.isFullScreen();
        print('AppWindowState: Current actual fullscreen state is $currentActualFullscreen');

        if (_isFullscreen) {
           // --- 目标：进入或保持全屏 --- 
            Size targetLogicalSize = await _calculateFullscreenLogicalSize();
            // 只有当实际不是全屏，或者尺寸不对时才操作
            Size currentSize = await windowManager.getSize();
            if (!currentActualFullscreen || currentSize != targetLogicalSize) {
                print('AppWindowState: Setting fullscreen size ${targetLogicalSize.width}x${targetLogicalSize.height}');
                await windowManager.setMinimumSize(targetLogicalSize);
                await windowManager.setMaximumSize(targetLogicalSize); 
                await windowManager.setSize(targetLogicalSize); 
                await windowManager.center(); 
                 if (!currentActualFullscreen) {
                    await windowManager.setFullScreen(true);
                 }
                 print('AppWindowState: Fullscreen mode applied and centered.');
            } else {
                 print('AppWindowState: Already in correct fullscreen state/size.');
            }
        } else {
           // --- 目标：退出或保持窗口 --- 
           Size targetLogicalSize = _calculateWindowedLogicalSize(_currentPhysicalResolution ?? (_native16x9PhysicalSize ?? const Size(defaultWidth, defaultHeight)));
           // 只有当实际是全屏，或者尺寸不对时才操作
           Size currentSize = await windowManager.getSize();
           if (currentActualFullscreen || currentSize != targetLogicalSize) {
                print('AppWindowState: Setting windowed size ${targetLogicalSize.width}x${targetLogicalSize.height}');
                if (currentActualFullscreen) {
                   await windowManager.setFullScreen(false);
                   await Future.delayed(const Duration(milliseconds: 100)); // 等待切换完成
                }
                await windowManager.setMinimumSize(targetLogicalSize);
                await windowManager.setMaximumSize(targetLogicalSize);
                await windowManager.setSize(targetLogicalSize);
                await windowManager.center();
                print('AppWindowState: Windowed mode applied.');
            } else {
                 print('AppWindowState: Already in correct windowed state/size.');
            }
        }
     } catch (e) {
        print('AppWindowState: Error applying window mode/size: $e');
        // 发生错误时，尝试根据实际情况更新内部状态
        try {
             bool actualStateAfterError = await windowManager.isFullScreen();
             updateFullscreenStatus(actualStateAfterError); // 用内部方法更新并保存
        } catch (e2) { /* ignore */} 
     }
  }

  // 更新窗口模式下的分辨率
  Future<void> setResolution(Size newPhysicalResolution) async {
      if (_isFullscreen) {
          print('AppWindowState: Cannot change resolution while fullscreen.');
          return; // 全屏时不允许更改
      }
      if (_currentPhysicalResolution == newPhysicalResolution) return; // 分辨率未改变

      print('AppWindowState: Setting new resolution: $newPhysicalResolution');
      _currentPhysicalResolution = newPhysicalResolution;
      // 保存分辨率设置
      try {
           final prefs = await SharedPreferences.getInstance();
           await prefs.setDouble(prefResolutionWidth, newPhysicalResolution.width);
           await prefs.setDouble(prefResolutionHeight, newPhysicalResolution.height);
      } catch (e) {
          print('AppWindowState: Error saving resolution preference: $e');
      }
      // 应用新的窗口尺寸
      await applyAppropriateWindowModeAndSize(); 
      // 通知 UI 更新（例如下拉菜单的选中项）
      notifyListeners(); 
  }

  // --- 私有辅助方法 ---

  // 保存全屏偏好
  Future<void> _saveFullscreenPreference(bool isFullscreen) async {
     try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(prefIsFullscreen, isFullscreen);
        print('AppWindowState: Preference saved: isFullscreen = $isFullscreen');
     } catch (e) {
        print('AppWindowState: Error saving fullscreen preference: $e');
     }
  }

  // 计算窗口化逻辑尺寸 (与 settings_menu 中类似)
  Size _calculateWindowedLogicalSize(Size physicalSize) {
    // *** Check kIsDesktopOS first, then specific platform ***
    if (kIsDesktopOS && Platform.isMacOS) {
      // macOS uses logical pixels which might be half the physical pixels on Retina
      // Assuming a default scale factor of 2.0 for simplicity here.
      // A more robust solution might involve getting the actual scale factor.
      return Size(physicalSize.width / 2.0, physicalSize.height / 2.0);
    } else {
      // Other desktop platforms (Windows, Linux) and non-desktop platforms
      // typically use physical pixels directly as logical pixels for window size.
      return physicalSize;
    }
  }

  // 计算全屏逻辑尺寸 (与 settings_menu 中类似)
  Future<Size> _calculateFullscreenLogicalSize() async {
     try {
        Display primaryDisplay = await screenRetriever.getPrimaryDisplay();
        double monitorWidth = primaryDisplay.size.width;
        double monitorHeight = primaryDisplay.size.height;
        print('AppWindowState: Primary display physical size: ${monitorWidth}x$monitorHeight');
        
        double targetAspectRatio = 16.0 / 9.0;
        double monitorAspectRatio = monitorWidth / monitorHeight;
        double targetPhysicalWidth, targetPhysicalHeight;

        if (monitorAspectRatio > targetAspectRatio) {
            targetPhysicalHeight = monitorHeight;
            targetPhysicalWidth = targetPhysicalHeight * targetAspectRatio;
        } else if (monitorAspectRatio < targetAspectRatio) {
            targetPhysicalWidth = monitorWidth;
            targetPhysicalHeight = targetPhysicalWidth / targetAspectRatio;
        } else {
            targetPhysicalWidth = monitorWidth;
            targetPhysicalHeight = monitorHeight;
        }
        // macOS 全屏直接用物理尺寸作为逻辑尺寸，其他平台物理逻辑相同
        Size logicalSize = Size(targetPhysicalWidth, targetPhysicalHeight);
        print('AppWindowState: Calculated fullscreen logical size: ${logicalSize.width}x${logicalSize.height}');
        return logicalSize;

     } catch (e) {
        print('AppWindowState: Error calculating fullscreen size: $e');
        // *** Fallback 使用当前的或原生的物理尺寸计算窗口逻辑尺寸 ***
        return _calculateWindowedLogicalSize(_currentPhysicalResolution ?? _native16x9PhysicalSize ?? const Size(defaultWidth, defaultHeight));
     }
  }

} 