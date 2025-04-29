import 'package:flutter/material.dart';

// *** 不再定义静态的分辨率列表 ***
// const List<Size> supportedResolutions = [...];

// SharedPreferences Keys
const String prefResolutionWidth = 'window_width';
const String prefResolutionHeight = 'window_height';
const String prefIsFullscreen = 'is_fullscreen'; 

// 默认物理分辨率 (主要用作无法获取屏幕信息时的 fallback)
const double defaultWidth = 1920;
const double defaultHeight = 1080; 