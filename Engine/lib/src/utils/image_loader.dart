import 'dart:io';
import 'dart:ui' as ui;
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/config/saki_pack_store.dart';
import 'package:sakiengine/src/utils/cg_image_compositor.dart';
import 'package:sakiengine/src/utils/asset_path_utils.dart';

/// 图像加载器 - 支持多种图像格式包括AVIF和WebP
///
/// 支持的格式:
/// - WebP: 原生支持，完美透明通道，文件大小优化
/// - PNG: 原生支持，完美透明通道
/// - AVIF: 通过flutter_avif插件支持，透明通道有限制
/// - JPG/JPEG: 原生支持，无透明通道
///
/// 智能回退策略 (针对AVIF):
/// 1. WebP版本 (最优选择)
/// 2. PNG版本 (可靠的透明通道)
/// 3. AVIF原文件 (最后选择)
class ImageLoader {
  /// 获取游戏路径，统一由 GamePathResolver 解析
  static Future<String> _getGamePath() async {
    if (!GamePathResolver.shouldUseFileSystemAssets) {
      return '';
    }
    return (await GamePathResolver.resolveGamePath()) ?? '';
  }

  /// 从资源路径加载图像
  static Future<ui.Image?> loadImage(String assetPath) async {
    try {
      // 检查是否为内存缓存路径
      if (_isMemoryCachePath(assetPath)) {
        return await _loadMemoryCacheImage(assetPath);
      }

      // 在debug模式下，优先从外部文件系统加载
      if (GamePathResolver.shouldUseFileSystemAssets && !kIsWeb) {
        final externalImage = await _loadExternalImage(assetPath);
        if (externalImage != null) {
          return externalImage;
        }
        // 如果外部文件加载失败，回退到assets加载
      }

      // 统一使用AVIF加载器，它内部有完整的回退机制：AVIF → WebP → PNG
      return await _loadAvifImageWithFallback(assetPath);
    } catch (e) {
      print('加载图像失败 $assetPath: $e');
      return null;
    }
  }

  /// 判断是否为内存缓存路径
  static bool _isMemoryCachePath(String path) {
    return CgImageCompositor().isCachePath(path);
  }

  /// 从内存缓存加载图像
  static Future<ui.Image?> _loadMemoryCacheImage(String assetPath) async {
    try {
      //print('[ImageLoader] 🐛 尝试从内存缓存加载: $assetPath');

      final imageBytes = CgImageCompositor().getImageBytes(assetPath);
      if (imageBytes == null) {
        //print('[ImageLoader] ❌ 内存缓存中未找到图像: $assetPath');
        return null;
      }

      //print('[ImageLoader] ✅ 找到内存缓存图像: $assetPath (${imageBytes.length} bytes)');

      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();

      //print('[ImageLoader] ✅ 成功解码图像: ${frame.image.width}x${frame.image.height}');
      return frame.image;
    } catch (e) {
      //print('[ImageLoader] ❌ 从内存缓存加载图像失败 $assetPath: $e');
      return null;
    }
  }

  /// 根据文件格式选择合适的加载方法
  static Future<ui.Image?> _loadImageByFormat(String assetPath) async {
    final lowercasePath = assetPath.toLowerCase();

    if (lowercasePath.endsWith('.avif')) {
      return await _loadAvifImage(assetPath);
    } else {
      return await _loadStandardImage(assetPath);
    }
  }

  /// 加载AVIF图像并提供回退机制
  static Future<ui.Image?> _loadAvifImageWithFallback(String assetPath) async {
    //print('[ImageLoader] 尝试加载图片: $assetPath');

    final config = SakiEngineConfig();

    // 首先尝试原始路径（无论什么格式）
    try {
      //print('[ImageLoader] 尝试原始路径: $assetPath');
      final originalImage = await _loadImageByFormat(assetPath);
      if (originalImage != null) {
        //print('[ImageLoader] 原始路径加载成功: $assetPath');
        return originalImage;
      }
    } catch (e) {
      //print('[ImageLoader] 原始路径加载失败: $assetPath, 错误: $e');
    }

    // 如果原始路径失败，尝试回退格式（仅当原始是AVIF时）
    if (assetPath.toLowerCase().endsWith('.avif')) {
      // 根据配置决定优先级：WebP > PNG
      if (config.preferWebpOverAvif) {
        final webpPath = assetPath.replaceAll(
            RegExp(r'\.avif$', caseSensitive: false), '.webp');
        try {
          //print('[ImageLoader] 尝试WebP回退: $webpPath');
          final webpImage = await _loadStandardImage(webpPath);
          if (webpImage != null) {
            //print('[ImageLoader] WebP回退成功: $webpPath');
            return webpImage;
          }
        } catch (e) {
          //print('[ImageLoader] WebP回退失败: $webpPath, 错误: $e');
        }
      }

      if (config.preferPngOverAvif) {
        final pngPath = assetPath.replaceAll(
            RegExp(r'\.avif$', caseSensitive: false), '.png');
        try {
          //print('[ImageLoader] 尝试PNG回退: $pngPath');
          final pngImage = await _loadStandardImage(pngPath);
          if (pngImage != null) {
            //print('[ImageLoader] PNG回退成功: $pngPath');
            return pngImage;
          }
        } catch (e) {
          //print('[ImageLoader] PNG回退失败: $pngPath, 错误: $e');
        }
      }
    }

    //print('[ImageLoader] 所有尝试都失败，返回null: $assetPath');
    return null;
  }

  /// 加载AVIF图像
  static Future<ui.Image?> _loadAvifImage(String assetPath) async {
    try {
      Uint8List bytes;
      final isAbsolutePath = isFileSystemAssetPath(assetPath);
      if (!kIsWeb && isAbsolutePath) {
        final file = File(assetPath);
        if (await file.exists()) {
          bytes = await file.readAsBytes();
          try {
            final codec = await ui.instantiateImageCodec(bytes);
            final frame = await codec.getNextFrame();
            return frame.image;
          } catch (_) {
            final frames = await decodeAvif(bytes);
            if (frames.isNotEmpty) {
              return frames.first.image;
            }
            return null;
          }
        }
      }

      // 在debug模式下，优先从外部文件系统获取数据
      if (GamePathResolver.shouldUseFileSystemAssets && !kIsWeb) {
        final gamePath = await _getGamePath();
        if (gamePath.isNotEmpty) {
          final relativePath = assetPath.startsWith('assets/')
              ? assetPath.substring('assets/'.length)
              : assetPath;
          final fileSystemPath = p.normalize(p.join(gamePath, relativePath));
          final file = File(fileSystemPath);

          if (await file.exists()) {
            bytes = await file.readAsBytes();
            if (kEngineDebugMode) {
              print('从外部文件加载AVIF: $fileSystemPath');
            }
          } else {
            // 回退到assets
            final data = await rootBundle.load(assetPath);
            bytes = data.buffer.asUint8List();
          }
        } else {
          final data = await rootBundle.load(assetPath);
          bytes = data.buffer.asUint8List();
        }
      } else {
        final data = await rootBundle.load(assetPath);
        bytes = data.buffer.asUint8List();
      }

      // 直接使用标准图像解码器，让Flutter自动处理AVIF
      // 这样可以保持与其他格式相同的透明通道处理方式
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        return frame.image;
      } catch (e) {
        // 如果标准解码器失败，再尝试flutter_avif
        final frames = await decodeAvif(bytes);

        if (frames.isNotEmpty) {
          return frames.first.image;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// 从外部文件系统加载图像（debug模式）
  static Future<ui.Image?> _loadExternalImage(String assetPath) async {
    try {
      if (kIsWeb) {
        return null;
      }

      final gamePath = await _getGamePath();
      if (gamePath.isEmpty) {
        return null;
      }

      // 移除 'assets/' 前缀（如果存在）
      final relativePath = assetPath.startsWith('assets/')
          ? assetPath.substring('assets/'.length)
          : assetPath;

      final fileSystemPath = p.normalize(p.join(gamePath, relativePath));
      final file = File(fileSystemPath);

      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        return frame.image;
      }

      // 如果直接路径不存在，尝试使用AssetManager的查找逻辑
      final fileName = p.basenameWithoutExtension(relativePath);
      final foundAssetPath = await AssetManager().findAsset(fileName);

      if (foundAssetPath != null) {
        final foundRelativePath = foundAssetPath.startsWith('assets/')
            ? foundAssetPath.substring('assets/'.length)
            : foundAssetPath;
        final foundFileSystemPath =
            p.normalize(p.join(gamePath, foundRelativePath));
        final foundFile = File(foundFileSystemPath);

        if (await foundFile.exists()) {
          final bytes = await foundFile.readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          return frame.image;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// 加载标准图像格式
  static Future<ui.Image?> _loadStandardImage(String assetPath) async {
    try {
      final isAbsolutePath = isFileSystemAssetPath(assetPath);
      if (!kIsWeb && isAbsolutePath) {
        final file = File(assetPath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          return frame.image;
        }
      }
      if (!kIsWeb) {
        final materialized =
            await SakiPackStore.instance.resolvePathForPlayback(assetPath);
        if (materialized != null && isFileSystemAssetPath(materialized)) {
          final bytes = await File(materialized).readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          return frame.image;
        }
      }
      final data = await rootBundle.load(assetPath);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      return null;
    }
  }
}
