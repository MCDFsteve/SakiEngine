import 'dart:async';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/engine_asset_loader.dart';
import 'package:sakiengine/src/utils/image_loader.dart';

/// 转场效果预热管理器
/// 在游戏启动时预热转场效果，避免首次使用时卡顿
class TransitionPrewarmingManager {
  static TransitionPrewarmingManager? _instance;
  static TransitionPrewarmingManager get instance =>
      _instance ??= TransitionPrewarmingManager._();

  TransitionPrewarmingManager._();

  bool _isPrewarming = false;
  bool _isPrewarmed = false;

  /// 执行预热
  /// 预热转场着色器和图片加载流程
  Future<void> prewarm(BuildContext context) async {
    if (_isPrewarming || _isPrewarmed) return;

    _isPrewarming = true;
    //print('[TransitionPrewarming] 开始转场预热');

    try {
      // Web平台采用更保守的预热策略，避免在渲染阶段访问上下文
      if (kIsWeb) {
        await _prewarmWeb();
      } else {
        // 预热转场着色器
        await _prewarmDissolveShader();
        await _prewarmPixelShader();

        // 预热图片加载流程
        await _prewarmImageLoading();
      }

      _isPrewarmed = true;
      //print('[TransitionPrewarming] 转场预热完成');
    } catch (e) {
      //print('[TransitionPrewarming] 转场预热失败: $e');
    } finally {
      _isPrewarming = false;
    }
  }

  /// 预热dissolve着色器
  Future<void> _prewarmDissolveShader() async {
    try {
      //print('[TransitionPrewarming] 预热dissolve着色器');
      await EngineAssetLoader.loadFragmentProgram(
          'assets/shaders/dissolve.frag');
    } catch (e) {
      //print('[TransitionPrewarming] 着色器预热失败: $e');
    }
  }

  /// 预热pixel转场着色器
  Future<void> _prewarmPixelShader() async {
    try {
      await EngineAssetLoader.loadFragmentProgram(
          'assets/shaders/pixelate.frag');
    } catch (e) {
      //print('[TransitionPrewarming] pixel着色器预热失败: $e');
    }
  }

  /// 预热图片加载流程
  Future<void> _prewarmImageLoading() async {
    try {
      //print('[TransitionPrewarming] 预热图片加载流程');

      // 尝试加载一个默认背景来预热图片加载管道
      final assetManager = AssetManager();

      // 查找可能存在的背景图片进行预热
      const testBackgrounds = ['school', 'sky', 'bg-school', 'chapter0'];

      for (final bgName in testBackgrounds) {
        final assetPath = await assetManager.findAsset(bgName);
        if (assetPath != null) {
          //print('[TransitionPrewarming] 找到预热背景: $bgName');
          final image = await ImageLoader.loadImage(assetPath);
          // 立即释放图片内存，我们只是想预热加载流程
          image?.dispose();
          break;
        }
      }
    } catch (e) {
      //print('[TransitionPrewarming] 图片加载预热失败: $e');
    }
  }

  /// Web平台专用预热方法 - 更保守的策略
  Future<void> _prewarmWeb() async {
    try {
      //print('[TransitionPrewarming] Web平台预热');

      // Web平台只预热着色器，不进行图片加载预热
      // 避免在启动阶段进行复杂的资产搜索
      await _prewarmDissolveShader();
      await _prewarmPixelShader();

      // Web平台跳过图片加载预热，因为AssetManager查询可能触发不当的上下文访问
      //print('[TransitionPrewarming] Web平台预热完成，跳过图片预热');
    } catch (e) {
      //print('[TransitionPrewarming] Web平台预热失败: $e');
    }
  }

  bool get isPrewarmed => _isPrewarmed;
}
