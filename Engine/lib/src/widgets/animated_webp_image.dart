import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/utils/webp_preload_cache.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';
import 'package:sakiengine/src/utils/asset_path_utils.dart';

// 平台特定导入
import 'animated_webp_image_io.dart'
    if (dart.library.html) 'animated_webp_image_web.dart';

/// WebP动图播放组件
/// 支持WebP动画的播放和控制
class AnimatedWebPImage extends StatefulWidget {
  final String assetPath;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? errorWidget;
  final bool autoPlay;
  final bool loop;
  final Duration? frameDuration;
  final ui.VoidCallback? onAnimationComplete;

  const AnimatedWebPImage.asset(
    this.assetPath, {
    super.key,
    this.fit,
    this.width,
    this.height,
    this.errorWidget,
    this.autoPlay = true,
    this.loop = true,
    this.frameDuration,
    this.onAnimationComplete,
  });

  @override
  State<AnimatedWebPImage> createState() => _AnimatedWebPImageState();
}

class _AnimatedWebPImageState extends State<AnimatedWebPImage>
    with TickerProviderStateMixin {
  AnimationController? _animationController;
  List<ImageInfo> _frames = [];
  WebPFrameLease? _cacheLease;
  bool _ownsFrames = false;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWebPFrames();
  }

  @override
  void dispose() {
    // 先停止动画，再销毁控制器
    _animationController?.stop();
    _animationController?.dispose();
    _animationController = null;

    _cacheLease?.release();
    _cacheLease = null;
    if (_ownsFrames) {
      for (final frame in _frames) {
        frame.image.dispose();
      }
    }
    _frames = [];
    super.dispose();
  }

  /// 获取游戏路径，统一由 GamePathResolver 解析
  Future<String> _getGamePath() async {
    if (!GamePathResolver.shouldUseFileSystemAssets || kIsWeb) {
      return '';
    }
    return (await GamePathResolver.resolveGamePath()) ?? '';
  }

  /// 加载WebP字节数据，支持外部文件系统
  Future<Uint8List?> _loadWebPBytes() async {
    try {
      final isAbsolutePath = isFileSystemAssetPath(widget.assetPath);
      if (!kIsWeb && isAbsolutePath) {
        final file = createFile(widget.assetPath);
        if (await file?.exists() == true) {
          return await file!.readAsBytes();
        }
      }

      // Web平台直接从assets加载
      if (kIsWeb) {
        final data = await rootBundle.load(widget.assetPath);
        return data.buffer.asUint8List();
      }

      // 在debug模式下，优先从外部文件系统加载
      if (GamePathResolver.shouldUseFileSystemAssets && !kIsWeb) {
        final gamePath = await _getGamePath();
        if (gamePath.isNotEmpty) {
          final relativePath = widget.assetPath.startsWith('assets/')
              ? widget.assetPath.substring('assets/'.length)
              : widget.assetPath;
          final fileSystemPath = p.normalize(p.join(gamePath, relativePath));
          final file = createFile(fileSystemPath);

          try {
            if (await file?.exists() == true) {
              //print('[AnimatedWebPImage] 从外部文件加载WebP: $fileSystemPath');
              return await file!.readAsBytes();
            }
          } catch (e) {
            // 忽略文件访问错误
          }
        }
        // 如果外部文件不存在，回退到assets加载
        //print('[AnimatedWebPImage] 外部文件不存在，回退到assets: ${widget.assetPath}');
      }

      // 从assets加载
      final data = await rootBundle.load(widget.assetPath);
      return data.buffer.asUint8List();
    } catch (e) {
      //print('[AnimatedWebPImage] 加载WebP字节失败: $e');
      return null;
    }
  }

  Future<void> _loadWebPFrames() async {
    try {
      // 从资源路径提取资源名称
      String assetName = widget.assetPath;
      if (assetName.startsWith('assets/')) {
        assetName = p.basenameWithoutExtension(assetName);
      } else if (assetName.contains('/')) {
        assetName = p.basename(assetName);
        if (assetName.contains('.')) {
          assetName = p.basenameWithoutExtension(assetName);
        }
      }

      // 首先尝试从预加载缓存获取
      final cache = WebPPreloadCache();
      final lease = cache.acquire(assetName);
      if (lease != null) {
        _cacheLease = lease;
        final cachedFrames = lease.frames;
        final cachedDuration = lease.duration;

        // 将ui.Image包装为ImageInfo
        _frames = cachedFrames.map((frame) => ImageInfo(image: frame)).toList();

        // 创建动画控制器
        if (_frames.length > 1) {
          if (mounted) {
            _animationController = AnimationController(
              duration: widget.frameDuration ?? cachedDuration,
              vsync: this,
            );

            // 添加动画完成监听
            _animationController?.addStatusListener((status) {
              if (mounted &&
                  status == AnimationStatus.completed &&
                  !widget.loop) {
                widget.onAnimationComplete?.call();
              }
            });

            if (widget.autoPlay && mounted) {
              try {
                if (widget.loop) {
                  _animationController?.repeat();
                } else {
                  _animationController?.forward();
                }
              } catch (e) {
                // 忽略自动播放错误
              }
            }
          }
        } else {
          if (mounted) {
            _animationController = AnimationController(
              duration: const Duration(milliseconds: 100),
              vsync: this,
            );
          }
        }

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      // 缓存未命中，使用原有逻辑加载

      // 使用新的字节加载函数
      final bytes = await _loadWebPBytes();
      if (bytes == null) {
        throw Exception('无法加载WebP字节数据');
      }

      // 使用Flutter的图像解码器
      final codec = await ui.instantiateImageCodec(bytes);
      final frameCount = codec.frameCount;
      _ownsFrames = true;

      if (frameCount > 1) {
        // 这是一个动图
        _frames.clear();
        Duration totalDuration = Duration.zero;

        for (int i = 0; i < frameCount; i++) {
          final frame = await codec.getNextFrame();
          _frames.add(ImageInfo(image: frame.image));
          totalDuration += frame.duration;
        }

        // 创建动画控制器
        if (mounted) {
          _animationController = AnimationController(
            duration: widget.frameDuration ?? totalDuration,
            vsync: this,
          );

          // 添加动画完成监听
          _animationController?.addStatusListener((status) {
            if (mounted &&
                status == AnimationStatus.completed &&
                !widget.loop) {
              widget.onAnimationComplete?.call();
            }
          });

          if (widget.autoPlay && mounted) {
            try {
              if (widget.loop) {
                _animationController?.repeat();
              } else {
                _animationController?.forward();
              }
            } catch (e) {
              // 忽略自动播放错误
            }
          }
        }
      } else {
        // 这是一个静态图片
        final frame = await codec.getNextFrame();
        _frames = [ImageInfo(image: frame.image)];

        if (mounted) {
          _animationController = AnimationController(
            duration: const Duration(milliseconds: 100),
            vsync: this,
          );
        }
      }
      codec.dispose();

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[AnimatedWebPImage] 加载WebP失败: $e');
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filterQuality = ImageSamplingManager().resolveWidgetFilterQuality(
      defaultQuality: FilterQuality.high,
    );

    if (_isLoading) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: Container(
          color: Colors.black, // 黑屏替代转圈加载
        ),
      );
    }

    if (_error != null) {
      return widget.errorWidget ??
          SizedBox(
            width: widget.width,
            height: widget.height,
            child: Center(
              child: Text(
                'WebP加载失败: $_error',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          );
    }

    if (_frames.isEmpty) {
      return widget.errorWidget ??
          SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
              child: Text('WebP无帧数据', style: TextStyle(color: Colors.red)),
            ),
          );
    }

    // 如果只有一帧，直接显示静态图片
    if (_frames.length == 1) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: RawImage(
          image: _frames[0].image,
          fit: widget.fit ?? BoxFit.contain,
          width: widget.width,
          height: widget.height,
          filterQuality: filterQuality,
        ),
      );
    }

    // 多帧动画
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: _animationController != null
          ? AnimatedBuilder(
              animation: _animationController!,
              builder: (context, child) {
                // 添加安全检查
                if (!mounted || _frames.isEmpty) {
                  return Container();
                }

                try {
                  final frameIndex =
                      (_animationController!.value * _frames.length).floor() %
                      _frames.length;
                  if (frameIndex < 0 || frameIndex >= _frames.length) {
                    return Container();
                  }

                  return RawImage(
                    image: _frames[frameIndex].image,
                    fit: widget.fit ?? BoxFit.contain,
                    width: widget.width,
                    height: widget.height,
                    filterQuality: filterQuality,
                  );
                } catch (e) {
                  // 如果动画渲染出错，显示第一帧
                  return RawImage(
                    image: _frames.isNotEmpty ? _frames.first.image : null,
                    fit: widget.fit ?? BoxFit.contain,
                    width: widget.width,
                    height: widget.height,
                    filterQuality: filterQuality,
                  );
                }
              },
            )
          : RawImage(
              image: _frames.isNotEmpty ? _frames.first.image : null,
              fit: widget.fit ?? BoxFit.contain,
              width: widget.width,
              height: widget.height,
              filterQuality: filterQuality,
            ),
    );
  }

  /// 播放动画
  void play() {
    if (!_isLoading &&
        _frames.length > 1 &&
        _animationController != null &&
        mounted) {
      try {
        if (widget.loop) {
          _animationController!.repeat();
        } else {
          _animationController!.forward();
        }
      } catch (e) {
        // 忽略动画控制错误
      }
    }
  }

  /// 暂停动画
  void pause() {
    if (!_isLoading && _animationController != null && mounted) {
      try {
        _animationController!.stop();
      } catch (e) {
        // 忽略动画控制错误
      }
    }
  }

  /// 重置动画
  void reset() {
    if (!_isLoading && _animationController != null && mounted) {
      try {
        _animationController!.reset();
      } catch (e) {
        // 忽略动画控制错误
      }
    }
  }
}
