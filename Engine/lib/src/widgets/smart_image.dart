import 'dart:ui' as ui;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:sakiengine/src/widgets/animated_webp_image.dart';
import 'package:sakiengine/src/utils/cg_image_compositor.dart';
import 'package:sakiengine/src/utils/cg_pre_warm_manager.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';
import '../utils/smart_image_io.dart'
    if (dart.library.html) '../utils/smart_image_web.dart';

/// 智能图像小部件 - 自动处理AVIF、WebP和其他格式
///
/// 特性:
/// - 自动识别图像格式
/// - WebP动图支持 (默认播放一次，可通过loop参数控制循环)
/// - WebP优先策略 (完美透明通道 + 优化文件大小)
/// - AVIF智能回退 (WebP > PNG > AVIF)
/// - 透明通道保护处理
class SmartImage extends StatelessWidget {
  final String assetPath;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? errorWidget;
  final bool? loop; // 新增：控制WebP动图是否循环播放
  final VoidCallback? onAnimationComplete; // 新增：动画完成回调

  const SmartImage.asset(
    this.assetPath, {
    super.key,
    this.fit,
    this.width,
    this.height,
    this.errorWidget,
    this.loop,
    this.onAnimationComplete, // 新增
  });

  @override
  Widget build(BuildContext context) {
    final lowercasePath = assetPath.toLowerCase();
    final filterQuality = ImageSamplingManager().resolveWidgetFilterQuality(
      defaultQuality: FilterQuality.high,
    );

    // 检查是否为内存缓存路径
    if (_isMemoryCachePath(assetPath)) {
      return _buildMemoryCacheImage();
    }

    final isFilePath = _isFileSystemPath(assetPath);

    // 检查文件扩展名
    if (lowercasePath.endsWith('.avif')) {
      return _buildAvifImageWithFallback();
    } else if (lowercasePath.endsWith('.webp')) {
      // Infinite ambient overlays can contain hundreds of full-screen frames.
      // Let Flutter's native multi-frame codec stream those frames instead of
      // materializing the whole animation in AnimatedWebPImage.
      if (loop == true && onAnimationComplete == null) {
        return _buildStreamingLoopingWebP(
          isFilePath: isFilePath,
          filterQuality: filterQuality,
        );
      }

      // WebP支持动画，使用专门的动图组件，默认不循环
      return AnimatedWebPImage.asset(
        assetPath,
        fit: fit ?? BoxFit.contain,
        width: width,
        height: height,
        errorWidget: errorWidget,
        autoPlay: true,
        loop: loop ?? false, // 默认不循环
        onAnimationComplete: onAnimationComplete, // 传递动画完成回调
      );
    } else {
      // Web平台总是使用asset方式
      if (kIsWeb) {
        return Image.asset(
          assetPath,
          fit: fit ?? BoxFit.contain,
          width: width,
          height: height,
          filterQuality: filterQuality,
          errorBuilder: errorWidget != null
              ? (context, error, stackTrace) => errorWidget!
              : null,
        );
      }

      // 检查是否为文件路径且非Web平台
      if (!kIsWeb && isFilePath) {
        return buildImageFile(
          assetPath,
          fit: fit,
          width: width,
          height: height,
          errorWidget: errorWidget,
        );
      } else {
        return Image.asset(
          assetPath,
          fit: fit ?? BoxFit.contain,
          width: width,
          height: height,
          filterQuality: filterQuality,
          errorBuilder: errorWidget != null
              ? (context, error, stackTrace) => errorWidget!
              : null,
        );
      }
    }
  }

  Widget _buildStreamingLoopingWebP({
    required bool isFilePath,
    required FilterQuality filterQuality,
  }) {
    if (kIsWeb || !isFilePath) {
      return Image.asset(
        assetPath,
        fit: fit ?? BoxFit.contain,
        width: width,
        height: height,
        filterQuality: filterQuality,
        gaplessPlayback: true,
        errorBuilder: errorWidget != null
            ? (context, error, stackTrace) => errorWidget!
            : null,
      );
    }

    return buildImageFile(
      assetPath,
      fit: fit,
      width: width,
      height: height,
      errorWidget: errorWidget,
    );
  }

  /// 构建AVIF图像，支持WebP和PNG回退
  Widget _buildAvifImageWithFallback() {
    final filterQuality = ImageSamplingManager().resolveWidgetFilterQuality(
      defaultQuality: FilterQuality.high,
    );

    // 优先级：WebP > PNG > AVIF
    final webpPath =
        assetPath.replaceAll(RegExp(r'\.avif$', caseSensitive: false), '.webp');
    final pngPath =
        assetPath.replaceAll(RegExp(r'\.avif$', caseSensitive: false), '.png');

    return FutureBuilder<String?>(
      future: _findBestImageFormat(webpPath, pngPath),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        final bestPath = snapshot.data;

        // 如果找到了更好的格式，使用对应的组件
        if (bestPath != null && bestPath != assetPath) {
          final isBestPathFile = _isFileSystemPath(bestPath);
          if (bestPath.toLowerCase().endsWith('.webp')) {
            // 使用WebP动图组件，默认不循环
            return AnimatedWebPImage.asset(
              bestPath,
              fit: fit ?? BoxFit.contain,
              width: width,
              height: height,
              errorWidget: errorWidget,
              autoPlay: true,
              loop: loop ?? false, // 默认不循环
              onAnimationComplete: onAnimationComplete,
            );
          } else {
            // Web平台总是使用asset方式
            if (kIsWeb) {
              return Image.asset(
                bestPath,
                fit: fit ?? BoxFit.contain,
                width: width,
                height: height,
                filterQuality: filterQuality,
                errorBuilder: errorWidget != null
                    ? (context, error, stackTrace) => errorWidget!
                    : null,
              );
            }

            // 检查是否为文件路径且非Web平台
            if (!kIsWeb && isBestPathFile) {
              return buildImageFile(
                bestPath,
                fit: fit,
                width: width,
                height: height,
                errorWidget: errorWidget,
              );
            } else {
              return Image.asset(
                bestPath,
                fit: fit ?? BoxFit.contain,
                width: width,
                height: height,
                filterQuality: filterQuality,
                errorBuilder: errorWidget != null
                    ? (context, error, stackTrace) => errorWidget!
                    : null,
              );
            }
          }
        }

        // 否则使用AVIF，但添加透明背景处理
        final isOriginalFile = _isFileSystemPath(assetPath);
        return Container(
          width: width,
          height: height,
          decoration: const BoxDecoration(
            color: Colors.transparent,
          ),
          child: kIsWeb
              ?
              // Web平台总是使用asset方式
              AvifImage.asset(
                  assetPath,
                  fit: fit ?? BoxFit.contain,
                  isAntiAlias: true,
                  filterQuality: filterQuality,
                  errorBuilder: errorWidget != null
                      ? (context, error, stackTrace) => errorWidget!
                      : null,
                )
              :
              // 非Web平台：检查是否为文件路径
              (!kIsWeb && isOriginalFile
                  ? buildAvifFile(
                      assetPath,
                      fit: fit,
                      width: width,
                      height: height,
                      errorWidget: errorWidget,
                    )
                  : AvifImage.asset(
                      assetPath,
                      fit: fit ?? BoxFit.contain,
                      isAntiAlias: true,
                      filterQuality: filterQuality,
                      errorBuilder: errorWidget != null
                          ? (context, error, stackTrace) => errorWidget!
                          : null,
                    )),
        );
      },
    );
  }

  /// 查找最佳的图像格式 (WebP > PNG > null)
  Future<String?> _findBestImageFormat(String webpPath, String pngPath) async {
    // 首先尝试WebP
    if (await _assetExists(webpPath)) {
      return webpPath;
    }

    // 然后尝试PNG
    if (await _assetExists(pngPath)) {
      return pngPath;
    }

    // 都不存在，返回null使用原始AVIF
    return null;
  }

  /// 判断是否为文件系统路径（debug模式下的绝对路径）
  bool _isFileSystemPath(String path) {
    // 排除内存缓存路径
    if (_isMemoryCachePath(path)) {
      return false;
    }
    // 检查是否为绝对路径：Unix风格 (/) 或 Windows风格 (C:)
    return path.startsWith('/') || (path.length > 2 && path[1] == ':');
  }

  /// 判断是否为内存缓存路径
  bool _isMemoryCachePath(String path) {
    return CgImageCompositor().isCachePath(path);
  }

  /// 构建内存缓存图像（集成预热管理器）
  Widget _buildMemoryCacheImage() {
    //print('[SmartImage] 🐛 尝试从内存缓存加载: $assetPath');

    // 提取缓存键信息
    String? cacheKey;
    if (_isMemoryCachePath(assetPath)) {
      final filename = assetPath.split('/').last;
      cacheKey = filename.replaceAll('.png', '');
    }

    final imageBytes = CgImageCompositor().getImageBytes(assetPath);
    final preWarmManager = CgPreWarmManager();

    if (imageBytes == null) {
      //print('[SmartImage] ❌ 内存缓存中未找到图像数据: $assetPath');

      // 如果是CG缓存键，尝试触发紧急预热
      if (cacheKey != null) {
        final parts = cacheKey.split('_');
        if (parts.length >= 3) {
          final resourceId = parts.sublist(0, parts.length - 2).join('_');
          final pose = parts[parts.length - 2];
          final expression = parts[parts.length - 1];

          preWarmManager.preWarmUrgent(
            resourceId: resourceId,
            pose: pose,
            expression: expression,
          );
        }
      }

      return errorWidget ??
          Container(
            width: width,
            height: height,
            color: Colors.grey.withValues(alpha: 0.3),
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.grey),
            ),
          );
    }

    //print('[SmartImage] ✅ 找到内存缓存图像: $assetPath (${imageBytes.length} bytes)');

    // 检查是否有预热的ui.Image对象
    ui.Image? preWarmedImage;
    if (cacheKey != null) {
      final parts = cacheKey.split('_');
      if (parts.length >= 3) {
        final resourceId = parts.sublist(0, parts.length - 2).join('_');
        final pose = parts[parts.length - 2];
        final expression = parts[parts.length - 1];

        preWarmedImage =
            preWarmManager.getPreWarmedImage(resourceId, pose, expression);

        if (preWarmedImage != null) {
          //print('[SmartImage] 🔥 使用预热的图像对象: $cacheKey');
          return RawImage(
            image: preWarmedImage,
            fit: fit ?? BoxFit.contain,
            width: width,
            height: height,
            filterQuality: ImageSamplingManager().resolveWidgetFilterQuality(
              defaultQuality: FilterQuality.high,
            ),
          );
        }
      }
    }

    // 使用Image.memory，但添加frameBuilder来处理第一帧
    return Image.memory(
      imageBytes,
      fit: fit ?? BoxFit.contain,
      width: width,
      height: height,
      filterQuality: ImageSamplingManager().resolveWidgetFilterQuality(
        defaultQuality: FilterQuality.high,
      ),
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded == true) {
          // 同步加载，直接显示
          return child;
        }

        if (frame == null) {
          // 第一帧尚未准备好，显示透明容器避免黑屏
          return Container(
            width: width,
            height: height,
            color: Colors.transparent,
          );
        }

        // 第二帧及之后，显示真实图像
        return AnimatedOpacity(
          opacity: 1.0,
          duration: const Duration(milliseconds: 100),
          child: child,
        );
      },
      errorBuilder: errorWidget != null
          ? (context, error, stackTrace) {
              //print('[SmartImage] ❌ Image.memory加载失败: $error');
              return errorWidget!;
            }
          : (context, error, stackTrace) {
              //print('[SmartImage] ❌ Image.memory加载失败: $error');
              return Container(
                width: width,
                height: height,
                color: Colors.red.withValues(alpha: 0.3),
                child: const Center(
                  child: Icon(Icons.error, color: Colors.red),
                ),
              );
            },
    );
  }

  /// 检查资源文件是否存在
  Future<bool> _assetExists(String assetPath) async {
    try {
      // Web平台总是检查bundle资源
      if (kIsWeb) {
        await rootBundle.load(assetPath);
        return true;
      }

      // 检查文件是否存在
      if (!kIsWeb && _isFileSystemPath(assetPath)) {
        // 非Web平台且为文件系统路径
        return await checkFileExists(assetPath);
      } else {
        // Bundle资源路径或Web平台
        await rootBundle.load(assetPath);
        return true;
      }
    } catch (e) {
      return false;
    }
  }
}
