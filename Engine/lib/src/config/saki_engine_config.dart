import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/localization/script_text_localizer.dart';
import 'package:sakiengine/src/sks_parser/sks_line_utils.dart';
import 'package:sakiengine/src/utils/color_parser.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';

class ThemeColors {
  final Color primary;
  final Color primaryDark;
  final Color primaryLight;
  final Color background;
  final Color surface;
  final Color onSurface;
  final Color onSurfaceVariant;

  ThemeColors({
    required this.primary,
    required this.primaryDark,
    required this.primaryLight,
    required this.background,
    required this.surface,
    required this.onSurface,
    required this.onSurfaceVariant,
  });

  factory ThemeColors.fromPrimary(Color primary) {
    // 从主色生成色彩系统
    final hsl = HSLColor.fromColor(primary);

    return ThemeColors(
      primary: primary,
      primaryDark: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation,
              (hsl.lightness - 0.2).clamp(0.0, 1.0))
          .toColor(),
      primaryLight: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation,
              (hsl.lightness + 0.2).clamp(0.0, 1.0))
          .toColor(),
      background:
          HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.3, 0.95).toColor(),
      surface:
          HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.8, 0.92).toColor(),
      onSurface:
          HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.6, 0.3).toColor(),
      onSurfaceVariant:
          HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.4, 0.5).toColor(),
    );
  }

  factory ThemeColors.fromPrimaryDark(Color primary) {
    // 深色模式：从主色生成深色主题
    final hsl = HSLColor.fromColor(primary);

    return ThemeColors(
      primary: primary,
      primaryDark: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation,
              (hsl.lightness + 0.2).clamp(0.0, 1.0))
          .toColor(),
      primaryLight: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation,
              (hsl.lightness - 0.2).clamp(0.0, 1.0))
          .toColor(),
      background: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.3, 0.1)
          .toColor(), // 深色背景
      surface: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.8, 0.15)
          .toColor(), // 深色表面
      onSurface: HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.6, 0.9)
          .toColor(), // 亮色文字
      onSurfaceVariant:
          HSLColor.fromAHSL(1.0, hsl.hue, hsl.saturation * 0.4, 0.7)
              .toColor(), // 亮色变体
    );
  }

  // 色温调整方法
  ThemeColors adjustColorTemperature({bool cooler = false}) {
    if (!cooler) return this;

    return ThemeColors(
      primary: _adjustColorTemperature(primary),
      primaryDark: _adjustColorTemperature(primaryDark),
      primaryLight: _adjustColorTemperature(primaryLight),
      background: _adjustColorTemperature(background),
      surface: _adjustColorTemperature(surface),
      onSurface: _adjustColorTemperature(onSurface),
      onSurfaceVariant: _adjustColorTemperature(onSurfaceVariant),
    );
  }

  // 单个颜色的色温调整（偏向冷色调）
  Color _adjustColorTemperature(Color color) {
    final hsl = HSLColor.fromColor(color);

    // 调整色相，让暖色调偏向冷色调
    double newHue = hsl.hue;
    if (hsl.hue >= 0 && hsl.hue <= 60) {
      // 红-黄区域，向蓝色方向偏移
      newHue = (hsl.hue + 180) % 360;
    } else if (hsl.hue >= 300 && hsl.hue <= 360) {
      // 红-紫区域，向蓝绿色方向偏移
      newHue = (hsl.hue + 120) % 360;
    }

    return HSLColor.fromAHSL(
      hsl.alpha,
      newHue,
      hsl.saturation * 0.8, // 稍微降低饱和度
      hsl.lightness,
    ).toColor();
  }
}

class SakiEngineConfig {
  static final SakiEngineConfig _instance = SakiEngineConfig._internal();
  factory SakiEngineConfig() => _instance;
  SakiEngineConfig._internal();

  double logicalWidth = 1920;
  double logicalHeight = 1080;

  // 图像格式处理配置
  bool preferWebpOverAvif = true; // 优先使用WebP而不是AVIF
  bool preferPngOverAvif = true; // 优先使用PNG而不是AVIF (WebP不存在时)
  bool enableAvifTransparencyWorkaround = true; // 启用AVIF透明通道修复

  // 主菜单背景配置
  String mainMenuBackground = 'sky';
  String mainMenuTitle = '';
  double mainMenuTitleSize = 72.0;

  // 主菜单标题位置配置
  double mainMenuTitleTop = 0.1;
  double mainMenuTitleRight = 0.05;
  double mainMenuTitleBottom = 0.0;
  double mainMenuTitleLeft = 0.0;

  // 记录配置中实际设置的位置参数
  bool hasBottom = false;
  bool hasLeft = false;

  // NVL 模式间距配置
  double nvlLeft = 200.0;
  double nvlRight = 40.0;
  double nvlTop = 100.0;
  double nvlBottom = 60.0;

  // 基础窗口配置
  double baseWindowBorder = 0.0;
  double baseWindowAlpha = 1.0;
  String? baseWindowBackground;
  double baseWindowXAlign = 0.5;
  double baseWindowYAlign = 0.5;
  double baseWindowBackgroundAlpha = 0.3;
  BlendMode baseWindowBackgroundBlendMode = BlendMode.multiply;
  double baseWindowBackgroundScale = 1.0;

  // 对话框专用背景缩放
  double dialogueBackgroundScale = 1.0;
  double dialogueBackgroundXAlign = 1.0;
  double dialogueBackgroundYAlign = 0.5;

  // 项目对话框布局配置
  double dialogueSpeakerXPos = 0.2;
  double dialogueSpeakerYPos = 0.0;
  double dialogueTextXPos = 0.0;
  double dialogueTextYPos = 0.0;

  // 设置默认值配置
  String defaultMenuDisplayMode = 'windowed';
  String defaultGameWindowResizeMode = 'keep_aspect';

  // 兼容旧字段名，避免历史项目脚本立即失效
  double get soranoutaSpeakerXPos => dialogueSpeakerXPos;
  set soranoutaSpeakerXPos(double value) => dialogueSpeakerXPos = value;

  double get soranoutaSpeakerYPos => dialogueSpeakerYPos;
  set soranoutaSpeakerYPos(double value) => dialogueSpeakerYPos = value;

  double get soranoUtaTextXPos => dialogueTextXPos;
  set soranoUtaTextXPos(double value) => dialogueTextXPos = value;

  double get soranoUtaTextYPos => dialogueTextYPos;
  set soranoUtaTextYPos(double value) => dialogueTextYPos = value;

  TextStyle dialogueTextStyle =
      const TextStyle(fontSize: 24, color: Colors.white);
  TextStyle speakerTextStyle = const TextStyle(
      fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold);
  TextStyle choiceTextStyle =
      const TextStyle(fontSize: 24, color: Colors.white);
  TextStyle reviewTitleTextStyle = const TextStyle(
      fontSize: 36, color: Color(0xFF5D4037), fontWeight: FontWeight.w300);
  TextStyle quickMenuTextStyle =
      const TextStyle(fontSize: 14, color: Colors.white);

  // 对话文字字体
  String dialogueFontFamily = 'SourceHanSansCN';

  // 全局主题系统
  String currentTheme = 'brown';
  ThemeColors themeColors = ThemeColors.fromPrimary(const Color(0xFF8B4513));
  String scriptDefaultLanguageTag = ScriptTextLocalizer.defaultLanguageTag;

  TextStyle? textButtonDefaultStyle;

  void updateThemeForDarkMode() {
    final isDarkMode = SettingsManager().currentDarkMode;
    final baseColor = parseColor(currentTheme) ?? const Color(0xFF8B4513);

    // 更新对话文字字体
    dialogueFontFamily = SettingsManager().currentDialogueFontFamily;

    if (isDarkMode) {
      // 夜间模式：深色主题 + 色温调整
      themeColors = ThemeColors.fromPrimaryDark(baseColor)
          .adjustColorTemperature(cooler: true);
    } else {
      themeColors = ThemeColors.fromPrimary(baseColor);
    }
  }

  Future<void> loadConfig() async {
    try {
      final configContent = await AssetManager()
          .loadString('assets/GameScript/configs/configs.sks');
      final lines = configContent.split('\n');
      ScriptTextLocalizer.setDefaultLanguageTag(
        ScriptTextLocalizer.defaultLanguageTag,
      );
      scriptDefaultLanguageTag =
          ScriptTextLocalizer.currentDefaultLanguageTag();

      for (final rawLine in lines) {
        final trimmedLine =
            SksLineUtils.stripLineCommentOutsideQuotes(rawLine).trim();
        if (trimmedLine.isEmpty) {
          continue;
        }
        if (trimmedLine.startsWith('script_default_language:') ||
            trimmedLine.startsWith('default_language:')) {
          final value = _valueAfterColon(trimmedLine);
          if (value != null && value.isNotEmpty) {
            final tag = value.split(RegExp(r'\s+')).first.trim();
            ScriptTextLocalizer.setDefaultLanguageTag(tag);
            scriptDefaultLanguageTag =
                ScriptTextLocalizer.currentDefaultLanguageTag();
          }
        }
      }

      for (final rawLine in lines) {
        final strippedLine =
            SksLineUtils.stripLineCommentOutsideQuotes(rawLine).trim();
        if (strippedLine.isEmpty) {
          continue;
        }
        final trimmedLine =
            ScriptTextLocalizer.localizeQuotedText(strippedLine);
        if (trimmedLine.startsWith('script_default_language:') ||
            trimmedLine.startsWith('default_language:')) {
          continue;
        }
        if (trimmedLine.startsWith('theme:')) {
          final paramsString = _valueAfterColon(trimmedLine);
          if (paramsString == null) {
            continue;
          }
          final colorMatch =
              RegExp(r'color\s*=\s*([#\w(),.\s]+)').firstMatch(paramsString);
          if (colorMatch != null) {
            final colorValue = colorMatch.group(1)?.trim();
            if (colorValue != null) {
              final themeColor = parseColor(colorValue);
              if (themeColor != null) {
                currentTheme = colorValue;
                themeColors = ThemeColors.fromPrimary(themeColor);
              }
            }
          }
        }
        if (trimmedLine.startsWith('main_menu:')) {
          //print('Debug: parsing main_menu config line: $trimmedLine');
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          final menuParams = paramsValue.split(' ');
          for (final param in menuParams) {
            final keyValue = param.split('=');
            if (keyValue.length == 2) {
              //print('Debug: parsing param ${keyValue[0]} = ${keyValue[1]}');
              switch (keyValue[0]) {
                case 'title':
                  mainMenuTitle = _stripWrappingQuotes(keyValue[1]);
                  //print('Debug: set mainMenuTitle to: $mainMenuTitle');
                  break;
                case 'background':
                  mainMenuBackground = _stripWrappingQuotes(keyValue[1]);
                  break;
                case 'size':
                  mainMenuTitleSize = double.tryParse(keyValue[1]) ?? 72.0;
                  //print('Debug: set mainMenuTitleSize to: $mainMenuTitleSize');
                  break;
                case 'top':
                  mainMenuTitleTop = double.tryParse(keyValue[1]) ?? 0.1;
                  break;
                case 'right':
                  mainMenuTitleRight = double.tryParse(keyValue[1]) ?? 0.05;
                  break;
                case 'bottom':
                  mainMenuTitleBottom = double.tryParse(keyValue[1]) ?? 0.0;
                  hasBottom = true;
                  //print('Debug: set mainMenuTitleBottom to: $mainMenuTitleBottom');
                  break;
                case 'left':
                  mainMenuTitleLeft = double.tryParse(keyValue[1]) ?? 0.0;
                  hasLeft = true;
                  //print('Debug: set mainMenuTitleLeft to: $mainMenuTitleLeft');
                  break;
              }
            }
          }
        }
        if (trimmedLine.startsWith('base_textbutton:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          textButtonDefaultStyle = _parseTextStyle(paramsValue);
        }
        if (trimmedLine.startsWith('base_dialogue:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          dialogueTextStyle = _parseTextStyle(paramsValue);
        }
        if (trimmedLine.startsWith('base_speaker:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          speakerTextStyle = _parseTextStyle(paramsValue);
        }
        if (trimmedLine.startsWith('base_choice:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          choiceTextStyle = _parseTextStyle(paramsValue);
        }
        if (trimmedLine.startsWith('base_review_title:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          reviewTitleTextStyle = _parseTextStyle(paramsValue)
              .copyWith(fontWeight: FontWeight.w300);
        }
        if (trimmedLine.startsWith('base_quick_menu:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          quickMenuTextStyle = _parseTextStyle(paramsValue);
        }
        if (trimmedLine.startsWith('nvl:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          final nvlParams = paramsValue.split(' ');
          for (final param in nvlParams) {
            final keyValue = param.split('=');
            if (keyValue.length == 2) {
              switch (keyValue[0]) {
                case 'left':
                  nvlLeft = double.tryParse(keyValue[1]) ?? 200.0;
                  break;
                case 'right':
                  nvlRight = double.tryParse(keyValue[1]) ?? 40.0;
                  break;
                case 'top':
                  nvlTop = double.tryParse(keyValue[1]) ?? 100.0;
                  break;
                case 'bottom':
                  nvlBottom = double.tryParse(keyValue[1]) ?? 60.0;
                  break;
              }
            }
          }
        }
        if (trimmedLine.startsWith('base_window:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          final windowParams = paramsValue.split(' ');
          for (final param in windowParams) {
            final keyValue = param.split('=');
            if (keyValue.length == 2) {
              switch (keyValue[0]) {
                case 'border':
                  baseWindowBorder = double.tryParse(keyValue[1]) ?? 0.0;
                  //print('[Config] baseWindowBorder 设置为: $baseWindowBorder');
                  break;
                case 'alpha':
                  baseWindowAlpha = double.tryParse(keyValue[1]) ?? 1.0;
                  //print('[Config] baseWindowAlpha 设置为: $baseWindowAlpha');
                  break;
                case 'background':
                  baseWindowBackground = keyValue[1];
                  //print('[Config] baseWindowBackground 设置为: $baseWindowBackground');
                  break;
                case 'xalign':
                  baseWindowXAlign = double.tryParse(keyValue[1]) ?? 0.5;
                  //print('[Config] baseWindowXAlign 设置为: $baseWindowXAlign');
                  break;
                case 'yalign':
                  baseWindowYAlign = double.tryParse(keyValue[1]) ?? 0.5;
                  //print('[Config] baseWindowYAlign 设置为: $baseWindowYAlign');
                  break;
                case 'background_alpha':
                  baseWindowBackgroundAlpha =
                      double.tryParse(keyValue[1]) ?? 0.3;
                  //print('[Config] baseWindowBackgroundAlpha 设置为: $baseWindowBackgroundAlpha');
                  break;
                case 'background_blend':
                  baseWindowBackgroundBlendMode = _parseBlendMode(keyValue[1]);
                  //print('[Config] baseWindowBackgroundBlendMode 设置为: $baseWindowBackgroundBlendMode');
                  break;
                case 'background_scale':
                  baseWindowBackgroundScale =
                      double.tryParse(keyValue[1]) ?? 1.0;
                  //print('[Config] baseWindowBackgroundScale 设置为: $baseWindowBackgroundScale');
                  break;
                case 'background_xalign':
                  baseWindowXAlign =
                      (double.tryParse(keyValue[1]) ?? 0.5).clamp(0.0, 1.0);
                  //print('[Config] baseWindowXAlign 设置为: $baseWindowXAlign');
                  break;
                case 'background_yalign':
                  baseWindowYAlign =
                      (double.tryParse(keyValue[1]) ?? 0.5).clamp(0.0, 1.0);
                  //print('[Config] baseWindowYAlign 设置为: $baseWindowYAlign');
                  break;
                case 'dialogue_background_scale':
                  dialogueBackgroundScale = double.tryParse(keyValue[1]) ?? 1.0;
                  //print('[Config] dialogueBackgroundScale 设置为: $dialogueBackgroundScale');
                  break;
                case 'dialogue_background_xalign':
                  dialogueBackgroundXAlign =
                      double.tryParse(keyValue[1]) ?? 1.0;
                  //print('[Config] dialogueBackgroundXAlign 设置为: $dialogueBackgroundXAlign');
                  break;
                case 'dialogue_background_yalign':
                  dialogueBackgroundYAlign =
                      double.tryParse(keyValue[1]) ?? 0.5;
                  //print('[Config] dialogueBackgroundYAlign 设置为: $dialogueBackgroundYAlign');
                  break;
              }
            }
          }
        }
        if (trimmedLine.startsWith('dialogbox_layout:') ||
            trimmedLine.startsWith('soranouta_dialogbox:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          final params = paramsValue.split(' ');
          for (final param in params) {
            final keyValue = param.split('=');
            if (keyValue.length == 2) {
              switch (keyValue[0]) {
                case 'xpos':
                  dialogueSpeakerXPos = double.tryParse(keyValue[1]) ?? 0.2;
                  break;
                case 'ypos':
                  dialogueSpeakerYPos = double.tryParse(keyValue[1]) ?? 0.0;
                  break;
                case 'dialogue_xpos':
                  dialogueTextXPos = double.tryParse(keyValue[1]) ?? 0.0;
                  break;
                case 'dialogue_ypos':
                  dialogueTextYPos = double.tryParse(keyValue[1]) ?? 0.0;
                  break;
              }
            }
          }
        }
        if (trimmedLine.startsWith('settings_defaults:')) {
          final paramsValue = _valueAfterColon(trimmedLine);
          if (paramsValue == null) {
            continue;
          }
          final params = paramsValue.split(' ');
          for (final param in params) {
            final keyValue = param.split('=');
            if (keyValue.length == 2) {
              switch (keyValue[0]) {
                case 'menu_display_mode':
                  final mode = keyValue[1].trim();
                  if (mode == 'windowed' || mode == 'fullscreen') {
                    defaultMenuDisplayMode = mode;
                  }
                  break;
                case 'game_window_resize_mode':
                  final mode = keyValue[1].trim();
                  if (mode == 'keep_aspect') {
                    defaultGameWindowResizeMode = mode;
                  }
                  break;
              }
            }
          }
        }
      }
    } catch (e) {
      // 如果配置文件读取失败，保持默认值
    }

    // 根据深色模式设置更新主题
    updateThemeForDarkMode();
  }

  String? _valueAfterColon(String line) {
    final index = line.indexOf(':');
    if (index < 0 || index + 1 >= line.length) {
      return null;
    }
    return line.substring(index + 1).trim();
  }

  String _stripWrappingQuotes(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2 &&
        trimmed.startsWith('"') &&
        trimmed.endsWith('"')) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  TextStyle _parseTextStyle(String styleString) {
    double? size;
    Color? color;

    final matches =
        RegExp(r'(\w+)\s*=\s*([#\w(),.\s]+)').allMatches(styleString);

    for (final match in matches) {
      final key = match.group(1);
      final value = match.group(2)?.trim();

      if (key != null && value != null) {
        switch (key) {
          case 'size':
            size = double.tryParse(value);
            break;
          case 'color':
            color = parseColor(value);
            break;
        }
      }
    }

    return TextStyle(
        fontSize: size, color: color, fontFamily: 'SourceHanSansCN');
  }

  BlendMode _parseBlendMode(String blendModeString) {
    switch (blendModeString.toLowerCase()) {
      case 'multiply':
        return BlendMode.multiply;
      case 'screen':
        return BlendMode.screen;
      case 'overlay':
        return BlendMode.overlay;
      case 'darken':
        return BlendMode.darken;
      case 'lighten':
        return BlendMode.lighten;
      case 'color_dodge':
        return BlendMode.colorDodge;
      case 'color_burn':
        return BlendMode.colorBurn;
      case 'hard_light':
        return BlendMode.hardLight;
      case 'soft_light':
        return BlendMode.softLight;
      case 'difference':
        return BlendMode.difference;
      case 'exclusion':
        return BlendMode.exclusion;
      case 'src_over':
      default:
        return BlendMode.srcOver;
    }
  }
}
