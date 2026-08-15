import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/character_layer_parser.dart';
import 'package:sakiengine/src/utils/expression_offset_manager.dart';
import 'package:sakiengine/src/utils/image_loader.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';

class CharacterCompositeCache {
  CharacterCompositeCache._();
  static final CharacterCompositeCache instance = CharacterCompositeCache._();

  final LinkedHashMap<String, ui.Image> _imageCache = LinkedHashMap();
  final Map<String, Future<ui.Image?>> _pendingTasks = {};
  static const int _maxEntries = 24;
  static const int _maxDecodedBytes =
      int.fromEnvironment(
        'SAKI_CHARACTER_COMPOSITE_CACHE_MB',
        defaultValue: 128,
      ) *
      1024 *
      1024;
  int _decodedBytes = 0;
  int _revision = 0;

  /// Changes whenever cached composites become unsafe for existing consumers.
  int get revision => _revision;

  String _buildKey(String resourceId, String pose, String expression) {
    return '$resourceId::$pose::$expression';
  }

  ui.Image? getCached(String resourceId, String pose, String expression) {
    return _imageCache[_buildKey(resourceId, pose, expression)];
  }

  Future<ui.Image?> preload(String resourceId, String pose, String expression) {
    final key = _buildKey(resourceId, pose, expression);
    //print('[CharacterCompositeCache] preload调用 - key: $key');

    final cached = _imageCache.remove(key);
    if (cached != null) {
      _imageCache[key] = cached;
      //print('[CharacterCompositeCache] 使用缓存图像 - key: $key');
      return SynchronousFuture(cached);
    }

    final pending = _pendingTasks[key];
    if (pending != null) {
      //print('[CharacterCompositeCache] 等待进行中的任务 - key: $key');
      return pending;
    }

    //print('[CharacterCompositeCache] 启动新的合成任务 - key: $key');
    final task = _compose(resourceId, pose, expression).then((image) {
      if (image != null) {
        //print('[CharacterCompositeCache] 合成成功，缓存图像 - key: $key');
        final replaced = _imageCache.remove(key);
        if (replaced != null) {
          _decodedBytes -= _estimatedBytes(replaced);
          _disposeAfterCurrentFrame(replaced);
        }
        _imageCache[key] = image;
        _decodedBytes += _estimatedBytes(image);
        _prune();
      } else {
        //print('[CharacterCompositeCache] 合成失败 - key: $key');
      }
      _pendingTasks.remove(key);
      return image;
    });

    _pendingTasks[key] = task;
    return task;
  }

  Future<ui.Image?> _compose(
    String resourceId,
    String pose,
    String expression,
  ) async {
    try {
      //print('[CharacterCompositeCache] 开始合成角色 - resourceId: $resourceId, pose: $pose, expression: $expression');

      final layerInfos = await CharacterLayerParser.parseCharacterLayers(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );

      //print('[CharacterCompositeCache] 图层解析完成 - 图层数量: ${layerInfos.length}');

      if (layerInfos.isEmpty) {
        //print('[CharacterCompositeCache] 没有图层信息，返回null');
        return null;
      }

      final images = <_CompositeLayer>[];
      ui.Image? baseImage;

      for (final info in layerInfos) {
        //print('[CharacterCompositeCache] 处理图层: ${info.layerType}, 资源名: ${info.assetName}');

        final assetPath = await AssetManager().findAsset(info.assetName);
        if (assetPath == null) {
          //print('[CharacterCompositeCache] 找不到资源: ${info.assetName}');
          continue;
        }

        final image = await ImageLoader.loadImage(assetPath);
        if (image == null) {
          //print('[CharacterCompositeCache] 图像加载失败: $assetPath');
          continue;
        }

        //print('[CharacterCompositeCache] 图像加载成功: $assetPath');

        final (xOffset, yOffset, alpha, scale) = ExpressionOffsetManager()
            .getExpressionOffset(
              characterId: resourceId,
              pose: pose,
              layerType: info.layerType,
            );

        images.add(
          _CompositeLayer(
            image: image,
            xOffset: xOffset,
            yOffset: yOffset,
            alpha: alpha,
            scale: scale,
          ),
        );

        baseImage ??= image;
      }

      final base = baseImage;
      if (base == null) {
        //print('[CharacterCompositeCache] 没有基础图像，返回null');
        return null;
      }

      //print('[CharacterCompositeCache] 开始Canvas合成 - 基础尺寸: ${base.width}x${base.height}');

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..isAntiAlias = true
        ..filterQuality = ImageSamplingManager().resolveCanvasFilterQuality(
          defaultQuality: ui.FilterQuality.high,
        );

      final width = base.width.toDouble();
      final height = base.height.toDouble();

      // 保存基础图像的尺寸，用于后续的toImage调用
      final baseWidth = base.width;
      final baseHeight = base.height;

      for (final layer in images) {
        canvas.save();
        final dx = layer.xOffset * width;
        final dy = layer.yOffset * height;
        canvas.translate(dx, dy);
        if (layer.scale != 1.0) {
          canvas.scale(layer.scale, layer.scale);
        }
        paint.color = ui.Color.fromRGBO(
          255,
          255,
          255,
          layer.alpha.clamp(0.0, 1.0),
        );
        canvas.drawImage(layer.image, ui.Offset.zero, paint);
        canvas.restore();
      }

      //print('[CharacterCompositeCache] Canvas绘制完成，开始转换为图像');

      final picture = recorder.endRecording();
      final composed = await picture.toImage(baseWidth, baseHeight);
      picture.dispose();

      // 现在安全地释放所有图层图像
      for (final layer in images) {
        layer.image.dispose();
      }

      //print('[CharacterCompositeCache] 图像合成成功');
      return composed;
    } catch (e, stackTrace) {
      //print('[CharacterCompositeCache] 合成失败: $e');
      //print('[CharacterCompositeCache] 错误堆栈: $stackTrace');
      return null;
    }
  }

  void clear() {
    _revision++;
    for (final image in _imageCache.values) {
      _disposeAfterCurrentFrame(image);
    }
    _imageCache.clear();
    _decodedBytes = 0;
    _pendingTasks.clear();
  }

  void invalidate(String resourceId, String pose) {
    _revision++;
    final prefix = '$resourceId::$pose::';
    final keysToRemove = _imageCache.keys
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keysToRemove) {
      final image = _imageCache.remove(key);
      if (image != null) {
        _decodedBytes -= _estimatedBytes(image);
        _disposeAfterCurrentFrame(image);
      }
      _pendingTasks.remove(key);
    }
  }

  int _estimatedBytes(ui.Image image) => image.width * image.height * 4;

  void _prune() {
    while (_imageCache.length > _maxEntries ||
        (_decodedBytes > _maxDecodedBytes && _imageCache.length > 1)) {
      final oldestKey = _imageCache.keys.first;
      final image = _imageCache.remove(oldestKey);
      if (image == null) {
        continue;
      }
      _decodedBytes -= _estimatedBytes(image);
      _disposeAfterCurrentFrame(image);
    }
  }

  void _disposeAfterCurrentFrame(ui.Image image) {
    // Callers may still be painting the previous image during a cache
    // invalidation. Give that frame time to retire before releasing the GPU
    // resource.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 250), image.dispose),
    );
  }
}

class _CompositeLayer {
  _CompositeLayer({
    required this.image,
    required this.xOffset,
    required this.yOffset,
    required this.alpha,
    required this.scale,
  });

  final ui.Image image;
  final double xOffset;
  final double yOffset;
  final double alpha;
  final double scale;
}
