import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/rendering/game_renderer.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/config/config_models.dart';

/// 游戏截图生成器
/// 默认根据当前游戏状态生成16:9截图（背景+角色）。
/// 可选启用实时游戏画面捕获（含UI）作为优先来源。
class ScreenshotGenerator {
  static const double targetWidth = 640.0;
  static const double targetHeight = 360.0; // 16:9 比例
  static bool _captureGameUiInSaveThumbnail = false;
  static Future<Uint8List?> Function()? _liveGameViewCaptureProvider;
  static Object? _liveGameViewCaptureOwner;

  static bool get captureGameUiInSaveThumbnail => _captureGameUiInSaveThumbnail;

  /// 是否启用“使用实时游戏画面(含UI)作为存档缩略图”的能力。
  /// 默认关闭，保持旧行为。
  static void setCaptureGameUiInSaveThumbnail(bool enabled) {
    _captureGameUiInSaveThumbnail = enabled;
  }

  /// 注册当前游戏画面的实时截图提供者。
  /// 使用 owner 防止旧页面 dispose 时误清空新页面的提供者。
  static void registerLiveGameViewCaptureProvider({
    required Object owner,
    Future<Uint8List?> Function()? provider,
  }) {
    if (provider == null) {
      if (identical(_liveGameViewCaptureOwner, owner)) {
        _liveGameViewCaptureOwner = null;
        _liveGameViewCaptureProvider = null;
      }
      return;
    }

    _liveGameViewCaptureOwner = owner;
    _liveGameViewCaptureProvider = provider;
  }

  static Future<Uint8List?> _tryCaptureLiveGameView() async {
    if (!_captureGameUiInSaveThumbnail ||
        _liveGameViewCaptureProvider == null) {
      return null;
    }

    try {
      final bytes = await _liveGameViewCaptureProvider!.call();
      if (bytes != null && bytes.isNotEmpty) {
        return bytes;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('[ScreenshotGenerator] 实时UI截图失败，回退到状态渲染: $e');
      }
    }

    return null;
  }

  /// 生成当前游戏状态的截图数据
  /// 返回WebP格式的截图字节数据，如果失败返回null
  static Future<Uint8List?> generateScreenshotData(
    GameState gameState,
    Map<String, PoseConfig> poseConfigs,
  ) async {
    try {
      final liveCapture = await _tryCaptureLiveGameView();
      if (liveCapture != null) {
        return liveCapture;
      }

      // 创建画布
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, targetWidth, targetHeight),
      );
      const canvasSize = Size(targetWidth, targetHeight);

      // 使用统一的渲染器绘制背景
      await GameRenderer.drawBackground(
        canvas,
        gameState.background,
        canvasSize,
      );

      // 如果有CG角色，优先渲染CG角色（铺满屏幕，类似背景）
      if (gameState.cgCharacters.isNotEmpty) {
        await GameRenderer.drawCgCharacters(
          canvas,
          gameState.cgCharacters,
          poseConfigs,
          canvasSize,
        );
      } else {
        // 没有CG时才绘制普通角色
        await GameRenderer.drawCharacters(
          canvas,
          gameState.characters,
          poseConfigs,
          canvasSize,
        );
      }

      // 完成绘制
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(
          targetWidth.toInt(),
          targetHeight.toInt(),
        );
        try {
          // 尝试使用WebP格式，如果不支持则使用PNG
          ui.ImageByteFormat format;
          try {
            // Flutter的ImageByteFormat没有直接的WebP支持，当前使用PNG。
            final pngData = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (pngData != null) {
              format = ui.ImageByteFormat.png;
            } else {
              format = ui.ImageByteFormat.png;
            }
          } catch (e) {
            format = ui.ImageByteFormat.png;
          }

          final byteData = await image.toByteData(format: format);
          if (byteData == null) return null;

          return byteData.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } catch (e) {
      print('生成截图失败: $e');
      return null;
    }
  }
}
