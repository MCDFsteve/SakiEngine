import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/utils/cg_image_compositor.dart';
import 'package:sakiengine/src/utils/engine_asset_loader.dart';
import 'package:sakiengine/src/utils/gpu_image_compositor.dart';
import 'package:sakiengine/src/utils/character_composite_cache.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';

ui.FilterQuality _resolveFilterQuality(bool preferSpeed) {
  return ImageSamplingManager().resolveCanvasFilterQualityBySpeed(
    preferSpeed: preferSpeed,
  );
}

@visibleForTesting
ui.Rect calculateDissolveImageRect(
  ui.Size canvasSize,
  int imageWidth,
  int imageHeight,
  BoxFit fit,
) {
  assert(fit == BoxFit.cover || fit == BoxFit.fitHeight);
  final scaleX = canvasSize.width / imageWidth;
  final scaleY = canvasSize.height / imageHeight;
  final scale = fit == BoxFit.fitHeight ? scaleY : math.max(scaleX, scaleY);
  final targetWidth = imageWidth * scale;
  final targetHeight = imageHeight * scale;
  return ui.Rect.fromLTWH(
    (canvasSize.width - targetWidth) / 2,
    (canvasSize.height - targetHeight) / 2,
    targetWidth,
    targetHeight,
  );
}

/// 基于预合成图像的CG角色渲染器
///
/// 替代原有的多层实时渲染方式，直接使用预合成的单张图像
class CompositeCgRenderer {
  static final Map<String, int> _fadeTokens = <String, int>{};

  static bool _isFreshFade(String key) => (_fadeTokens[key] ?? 0) < 1;

  static void _markFadeUsed(String key) {
    _fadeTokens[key] = (_fadeTokens[key] ?? 0) + 1;
  }

  static void resetFadeToken(String key) {
    _fadeTokens.remove(key);
    _fadeTokens.remove('gpu_$key');
  }

  static Future<void> initializeDisplayedCg({
    required String displayKey,
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    final cacheKey = '${resourceId}_${pose}_${expression}';

    _markFadeUsed(displayKey);
    _markFadeUsed('gpu_$displayKey');

    if (!_completedPaths.containsKey(cacheKey)) {
      final compositePath = await _legacyCompositor.getCompositeImagePath(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );
      if (compositePath != null) {
        _completedPaths[cacheKey] = compositePath;
      }

      final gpuEntry = await _gpuCompositor.getCompositeEntry(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );
      if (gpuEntry != null) {
        _cacheGpuResult(cacheKey, gpuEntry.result, markAsPreloaded: true);
      }
    }

    if (_completedPaths.containsKey(cacheKey)) {
      _currentDisplayedImages[displayKey] = _completedPaths[cacheKey]!;
    }

    if (_gpuResultCache.containsKey(cacheKey)) {
      _currentDisplayedGpuKeys[displayKey] = cacheKey;
    }
  }

  // GPU加速合成器实例
  static final GpuImageCompositor _gpuCompositor = GpuImageCompositor();
  static final CgImageCompositor _legacyCompositor = CgImageCompositor();

  // 性能优化开关
  static bool _useGpuAcceleration = true;
  static bool _preferSpeedRendering = false;

  // 缓存Future，避免重复创建导致的loading状态
  static final Map<String, Future<String?>> _futureCache = {};
  // 缓存已完成的合成路径
  static final Map<String, String> _completedPaths = {};

  // 预显示差分的状态跟踪
  static final Set<String> _preDisplayedCgs = <String>{};

  // 当前显示的图像状态缓存（用于无缝切换）
  static final Map<String, String> _currentDisplayedImages = {};

  // 预加载完成的图像缓存（仅保留少量以支持首帧渐变）
  static final LinkedHashMap<String, ui.Image> _preloadedImages =
      LinkedHashMap();
  static const int _maxPreloadedImages = 2;
  static const int _maxPreloadedImageBytes =
      int.fromEnvironment('SAKI_CG_FLATTENED_CACHE_MB', defaultValue: 24) *
      1024 *
      1024;

  // GPU 纹理缓存与状态
  static final Map<String, Future<GpuCompositeEntry?>> _gpuFutureCache = {};
  static final LinkedHashMap<String, GpuCompositeResult> _gpuResultCache =
      LinkedHashMap();
  static final Set<String> _gpuPreloadedKeys = <String>{};
  static const int _maxGpuResultEntries = 8;
  static const int _maxGpuResultBytes =
      int.fromEnvironment('SAKI_CG_GPU_CACHE_MB', defaultValue: 96) *
      1024 *
      1024;
  static final Map<String, String> _currentDisplayedGpuKeys = {};

  static final Map<String, Future<ui.Image?>> _gpuFlattenTasks = {};

  // 着色器支持
  static ui.FragmentProgram? _dissolveProgram;
  static const bool _fallbackDiagnosticsEnabled = bool.fromEnvironment(
    'SAKI_CG_FALLBACK_DIAG',
    defaultValue: true,
  );
  static const bool _transitionDiagnosticsEnabled = bool.fromEnvironment(
    'SAKI_CG_TRANSITION_DIAG',
    defaultValue: true,
  );
  static final Set<String> _fallbackDiagSignatures = <String>{};
  static final Set<String> _transitionDiagSignatures = <String>{};

  static void _logCgFallback({
    required String reason,
    required String targetContentId,
    required String? currentContentId,
    required bool hasCurrentImage,
    required bool hasPreviousImage,
    required bool shaderAvailable,
    required bool isFadingOut,
    required bool skipAnimation,
    required bool useGpuAcceleration,
    double? progress,
  }) {
    if (!_fallbackDiagnosticsEnabled) {
      return;
    }
    final progressText = progress == null ? 'n/a' : progress.toStringAsFixed(3);
    final mode = kEngineDebugMode ? 'debug' : 'release';
    final signature =
        '$reason|$targetContentId|$currentContentId|$hasCurrentImage|'
        '$hasPreviousImage|$shaderAvailable|$isFadingOut|$skipAnimation|'
        '$useGpuAcceleration|$progressText|$mode';
    if (!_fallbackDiagSignatures.add(signature)) {
      return;
    }
    if (_fallbackDiagSignatures.length > 256) {
      _fallbackDiagSignatures.clear();
      _fallbackDiagSignatures.add(signature);
    }
    print(
      '[CompositeCgRenderer] CG fallback triggered: '
      'reason=$reason, mode=$mode, target=$targetContentId, '
      'current=$currentContentId, hasCurrent=$hasCurrentImage, '
      'hasPrevious=$hasPreviousImage, shaderAvailable=$shaderAvailable, '
      'isFadingOut=$isFadingOut, skipAnimation=$skipAnimation, '
      'useGpuAcceleration=$useGpuAcceleration, progress=$progressText',
    );
  }

  static void _logCgTransition(String message) {
    if (!_transitionDiagnosticsEnabled) {
      return;
    }
    if (!_transitionDiagSignatures.add(message)) {
      return;
    }
    if (_transitionDiagSignatures.length > 512) {
      _transitionDiagSignatures.clear();
      _transitionDiagSignatures.add(message);
    }
    print('[CompositeCgRenderer] CG transition: $message');
  }

  static Future<void> _ensureDissolveProgram() async {
    if (_dissolveProgram != null) return;
    try {
      final program = await EngineAssetLoader.loadFragmentProgram(
        'assets/shaders/dissolve.frag',
      );
      _dissolveProgram = program;
    } catch (e) {
      print('[CompositeCgRenderer] Failed to load dissolve shader: $e');
    }
  }

  /// 供后台预合成逻辑注册缓存结果，避免首次切换差分时重新加载
  static Future<void> cachePrecomposedResult({
    required String resourceId,
    required String pose,
    required String expression,
    String? compositePath,
    GpuCompositeEntry? gpuEntry,
    bool prepareFlattenedImage = false,
  }) async {
    final cacheKey = '${resourceId}_${pose}_${expression}';

    if (gpuEntry != null) {
      _cacheGpuResult(cacheKey, gpuEntry.result, markAsPreloaded: true);
      _gpuFutureCache[cacheKey] = Future.value(gpuEntry);

      final virtualPath = gpuEntry.virtualPath;
      _completedPaths[cacheKey] = virtualPath;
      _futureCache[cacheKey] = Future.value(virtualPath);

      // 预测性预热只保留可直接绘制的分层纹理。全分辨率扁平图会让
      // 每个 1920x1080 CG 再增加约 8 MiB，只在真正即将显示时生成。
      if (!kIsWeb && prepareFlattenedImage) {
        final flattenTask = _gpuFlattenTasks[cacheKey] ??=
            _flattenGpuResultToImage(gpuEntry.result);
        final flattenedImage = await flattenTask;
        if (flattenedImage != null) {
          _storePreloadedImage(cacheKey, flattenedImage);
        }
        _gpuFlattenTasks.remove(cacheKey);
      }
    }

    if (compositePath != null) {
      _completedPaths[cacheKey] = compositePath;
      _futureCache[cacheKey] = Future.value(compositePath);
    }
  }

  // 预热是否已经开始
  static bool _preWarmingStarted = false;

  // CG槽位：场景中只有一个固定的CG位置
  static const String _cgSlotKey = 'main_cg_slot';

  static List<Widget> buildCgCharacters(
    BuildContext context,
    Map<String, CharacterState> cgCharacters,
    GameManager gameManager, {
    bool skipAnimations = false,
    Duration transitionDuration = const Duration(milliseconds: 300),
    VoidCallback? onTransitionCompleted,
  }) {
    _preferSpeedRendering = skipAnimations;
    _ensureDissolveProgram();
    // 确保预热已开始（只执行一次）
    if (!_preWarmingStarted) {
      _preWarmingStarted = true;
      // 异步开始预热，不阻塞UI
      _startGlobalPreWarming();
    }

    if (cgCharacters.isEmpty) {
      return [];
    }

    // 按resourceId分组，保留最新的角色状态
    final Map<String, MapEntry<String, CharacterState>> charactersByResourceId =
        {};

    for (final entry in cgCharacters.entries) {
      final resourceId = entry.value.resourceId;
      charactersByResourceId[resourceId] = entry;
    }

    // 场景中应该只有一个CG（取第一个）
    if (charactersByResourceId.isEmpty) return [];

    final mainCgEntry = charactersByResourceId.values.first;
    final characterState = mainCgEntry.value;

    // 返回单个CG槽位Widget，使用固定的key确保始终是同一个实例
    return [
      CgSlotWidget(
        key: const ValueKey(_cgSlotKey),
        resourceId: characterState.resourceId,
        pose: characterState.pose ?? 'pose1',
        expression: characterState.expression ?? 'happy',
        cacheRevision: CharacterCompositeCache.instance.revision,
        isFadingOut: characterState.isFadingOut,
        skipAnimation: skipAnimations,
        useGpuAcceleration: _useGpuAcceleration,
        transitionDuration: transitionDuration,
        onTransitionCompleted: onTransitionCompleted,
        animationProperties: characterState.animationProperties, // 传递动画属性
      ),
    ];
  }

  static Widget _buildCpuCharacterWidget({
    required BuildContext context,
    required MapEntry<String, CharacterState> entry,
    required bool skipAnimations,
  }) {
    final characterState = entry.value;
    // 使用resourceId作为displayKey，确保差分切换时Widget被复用
    final displayKey = characterState.resourceId;

    final widgetKey = 'composite_cg_$displayKey';
    final cacheKey =
        '${characterState.resourceId}_${characterState.pose ?? 'pose1'}_${characterState.expression ?? 'happy'}';

    final resourceBaseId =
        '${characterState.resourceId}_${characterState.pose ?? 'pose1'}';
    if (!_preDisplayedCgs.contains(resourceBaseId)) {
      _preDisplayedCgs.add(resourceBaseId);
      _preDisplayCommonVariations(
        characterState.resourceId,
        characterState.pose ?? 'pose1',
      );
    }

    final currentImagePath = _currentDisplayedImages[displayKey];
    final bool isFirstAppearance =
        !skipAnimations &&
        (currentImagePath == null || _isFreshFade(displayKey));
    if (isFirstAppearance) {
      _markFadeUsed(displayKey);
    }

    final preloadedImage = _getPreloadedImage(cacheKey);
    if (preloadedImage != null) {
      _currentDisplayedImages[displayKey] = cacheKey;

      return _FirstCgFadeWrapper(
        fadeKey: displayKey,
        enableFade: isFirstAppearance,
        child: DirectCgDisplay(
          key: ValueKey('direct_display_$displayKey'),
          image: preloadedImage,
          resourceId: characterState.resourceId,
          isFadingOut: characterState.isFadingOut,
          enableFadeIn: !skipAnimations && currentImagePath == null,
          skipAnimation: skipAnimations,
        ),
      );
    }

    // 检查是否已经完成加载
    if (_completedPaths.containsKey(cacheKey)) {
      final compositeImagePath = _completedPaths[cacheKey]!;
      _currentDisplayedImages[displayKey] = compositeImagePath;

      return _FirstCgFadeWrapper(
        fadeKey: displayKey,
        enableFade: isFirstAppearance,
        child: SeamlessCgDisplay(
          key: ValueKey('seamless_display_$displayKey'),
          newImagePath: compositeImagePath,
          currentImagePath: currentImagePath,
          resourceId: characterState.resourceId,
          dissolveProgram: _dissolveProgram,
          isFadingOut: characterState.isFadingOut,
          skipAnimation: skipAnimations,
        ),
      );
    }

    // 异步加载中，使用_CgLoadingWrapper来监听Future完成
    if (!_futureCache.containsKey(cacheKey)) {
      _futureCache[cacheKey] = _loadAndCacheImage(
        resourceId: characterState.resourceId,
        pose: characterState.pose ?? 'pose1',
        expression: characterState.expression ?? 'happy',
        cacheKey: cacheKey,
        displayKey: displayKey,
      );
    }

    return _CgLoadingWrapper(
      key: ValueKey('loading_wrapper_$displayKey'),
      future: _futureCache[cacheKey]!,
      displayKey: displayKey,
      currentImagePath: currentImagePath,
      resourceId: characterState.resourceId,
      isFadingOut: characterState.isFadingOut,
      skipAnimation: skipAnimations,
      isFirstAppearance: isFirstAppearance,
    );
  }

  static Widget _buildGpuCharacterWidget({
    required BuildContext context,
    required MapEntry<String, CharacterState> entry,
    required bool skipAnimations,
  }) {
    final characterState = entry.value;
    // 使用resourceId作为displayKey，确保差分切换时Widget被复用
    final displayKey = characterState.resourceId;

    final cacheKey =
        '${characterState.resourceId}_${characterState.pose ?? 'pose1'}_${characterState.expression ?? 'happy'}';

    final resourceBaseId =
        '${characterState.resourceId}_${characterState.pose ?? 'pose1'}';
    if (!_preDisplayedCgs.contains(resourceBaseId)) {
      _preDisplayedCgs.add(resourceBaseId);
      _preDisplayCommonVariations(
        characterState.resourceId,
        characterState.pose ?? 'pose1',
      );
    }

    final currentKey = _currentDisplayedGpuKeys[displayKey];
    final currentResult = _peekGpuResult(currentKey);
    final bool isFirstAppearance =
        !skipAnimations &&
        (currentKey == null || _isFreshFade('gpu_$displayKey'));
    if (isFirstAppearance) {
      _markFadeUsed('gpu_$displayKey');
    }

    final preloadedImage = _getPreloadedImage(cacheKey);
    if (preloadedImage != null) {
      _currentDisplayedGpuKeys[displayKey] = cacheKey;

      return _FirstCgFadeWrapper(
        fadeKey: 'gpu_$displayKey',
        enableFade: isFirstAppearance,
        child: DirectCgDisplay(
          key: ValueKey('direct_display_gpu_$displayKey'),
          image: preloadedImage,
          resourceId: characterState.resourceId,
          isFadingOut: characterState.isFadingOut,
          enableFadeIn: !skipAnimations && currentKey == null,
          skipAnimation: skipAnimations,
        ),
      );
    }

    final cachedResult = _peekGpuResult(cacheKey);
    if (cachedResult != null) {
      final bool wasPreloaded = _gpuPreloadedKeys.remove(cacheKey);
      _currentDisplayedGpuKeys[displayKey] = cacheKey;

      if (wasPreloaded) {
        return _FirstCgFadeWrapper(
          fadeKey: 'gpu_$displayKey',
          enableFade: isFirstAppearance,
          child: GpuDirectCgDisplay(
            key: ValueKey('gpu_direct_$displayKey'),
            result: cachedResult,
            resourceId: characterState.resourceId,
            isFadingOut: characterState.isFadingOut,
            skipAnimation: skipAnimations,
            enableFadeIn: !skipAnimations && currentKey == null,
            preferSpeed: skipAnimations,
          ),
        );
      }

      if (currentResult == null && !skipAnimations) {
        return _FirstCgFadeWrapper(
          fadeKey: 'gpu_$displayKey',
          enableFade: true,
          child: GpuDirectCgDisplay(
            key: ValueKey('gpu_direct_initial_$displayKey'),
            result: cachedResult,
            resourceId: characterState.resourceId,
            isFadingOut: characterState.isFadingOut,
            skipAnimation: skipAnimations,
            enableFadeIn: true,
            preferSpeed: skipAnimations,
          ),
        );
      }

      return _FirstCgFadeWrapper(
        fadeKey: 'gpu_$displayKey',
        enableFade: isFirstAppearance,
        child: GpuSeamlessCgDisplay(
          key: ValueKey('gpu_seamless_$displayKey'),
          newResult: cachedResult,
          currentResult: currentResult,
          resourceId: characterState.resourceId,
          isFadingOut: characterState.isFadingOut,
          skipAnimation: skipAnimations,
          preferSpeed: skipAnimations,
        ),
      );
    }

    if (!_gpuFutureCache.containsKey(cacheKey)) {
      _gpuFutureCache[cacheKey] = _gpuCompositor
          .getCompositeEntry(
            resourceId: characterState.resourceId,
            pose: characterState.pose ?? 'pose1',
            expression: characterState.expression ?? 'happy',
          )
          .then((entry) {
            if (entry != null) {
              _cacheGpuResult(cacheKey, entry.result, markAsPreloaded: true);
            }
            return entry;
          });
    }

    return FutureBuilder<GpuCompositeEntry?>(
      key: ValueKey('gpu_future_$displayKey'),
      future: _gpuFutureCache[cacheKey],
      builder: (context, snapshot) {
        final entryData = snapshot.data;
        final newResult = entryData?.result;
        final hasNewResult = snapshot.hasData && newResult != null;

        if (snapshot.connectionState == ConnectionState.waiting) {
          if (currentResult != null) {
            return GpuSeamlessCgDisplay(
              key: ValueKey('gpu_seamless_$displayKey'),
              newResult: null,
              currentResult: currentResult,
              resourceId: characterState.resourceId,
              isFadingOut: characterState.isFadingOut,
              skipAnimation: skipAnimations,
              preferSpeed: skipAnimations,
            );
          }
          return Container(
            key: ValueKey('gpu_loading_$displayKey'),
            width: double.infinity,
            height: double.infinity,
          );
        }

        if (!hasNewResult) {
          if (currentResult != null) {
            return GpuSeamlessCgDisplay(
              key: ValueKey('gpu_seamless_${characterState.resourceId}'),
              newResult: null,
              currentResult: currentResult,
              resourceId: characterState.resourceId,
              isFadingOut: characterState.isFadingOut,
              skipAnimation: skipAnimations,
              preferSpeed: skipAnimations,
            );
          }
          return Container(
            key: ValueKey('gpu_error_${characterState.resourceId}'),
            width: double.infinity,
            height: double.infinity,
          );
        }

        _cacheGpuResult(cacheKey, newResult!, markAsPreloaded: true);
        _currentDisplayedGpuKeys[displayKey] = cacheKey;

        return GpuSeamlessCgDisplay(
          key: ValueKey('gpu_seamless_$displayKey'),
          newResult: newResult,
          currentResult: currentResult,
          resourceId: characterState.resourceId,
          isFadingOut: characterState.isFadingOut,
          skipAnimation: skipAnimations,
          preferSpeed: skipAnimations,
        );
      },
    );
  }

  static Future<ui.Image?> _flattenGpuResultToImage(
    GpuCompositeResult result,
  ) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final width = result.width.toDouble();
      final height = result.height.toDouble();

      final targetRect = ui.Rect.fromLTWH(0, 0, width, height);
      final paint = ui.Paint()
        ..isAntiAlias = false
        ..filterQuality = ImageSamplingManager().resolveCanvasFilterQuality(
          defaultQuality: ui.FilterQuality.none,
        );

      for (
        var layerIndex = 0;
        layerIndex < result.layers.length;
        layerIndex++
      ) {
        final layer = result.layers[layerIndex];
        final srcRect = ui.Rect.fromLTWH(
          0,
          0,
          layer.width.toDouble(),
          layer.height.toDouble(),
        );
        paint.blendMode = layerIndex == 0
            ? ui.BlendMode.src
            : ui.BlendMode.srcOver;
        canvas.drawImageRect(layer, srcRect, targetRect, paint);
      }

      final picture = recorder.endRecording();
      final image = await picture.toImage(result.width, result.height);
      picture.dispose();
      return image;
    } catch (_) {
      return null;
    }
  }

  static ui.Image? _getPreloadedImage(String cacheKey) {
    return _preloadedImages.remove(cacheKey);
  }

  static void _storePreloadedImage(String cacheKey, ui.Image image) {
    final previous = _preloadedImages.remove(cacheKey);
    if (previous != null && !identical(previous, image)) {
      try {
        previous.dispose();
      } catch (_) {}
    }

    _preloadedImages[cacheKey] = image;
    _evictPreloadedImages();
  }

  static void _evictPreloadedImages() {
    var decodedBytes = _preloadedImages.values.fold<int>(
      0,
      (total, image) => total + image.width * image.height * 4,
    );
    if (_preloadedImages.length <= _maxPreloadedImages &&
        decodedBytes <= _maxPreloadedImageBytes) {
      return;
    }

    final protected = _collectActivePreloadedKeys();
    final keysToRemove = <String>[];
    for (final key in _preloadedImages.keys) {
      if (_preloadedImages.length - keysToRemove.length <=
              _maxPreloadedImages &&
          decodedBytes <= _maxPreloadedImageBytes) {
        break;
      }
      if (protected.contains(key)) {
        continue;
      }
      keysToRemove.add(key);
      final image = _preloadedImages[key];
      if (image != null) {
        decodedBytes -= image.width * image.height * 4;
      }
    }

    if (keysToRemove.isEmpty) {
      keysToRemove.add(_preloadedImages.keys.first);
    }

    for (final key in keysToRemove) {
      final removed = _preloadedImages.remove(key);
      try {
        removed?.dispose();
      } catch (_) {}
    }
  }

  static Set<String> _collectActivePreloadedKeys() {
    final active = <String>{};
    for (final path in _currentDisplayedImages.values) {
      if (path != null && _preloadedImages.containsKey(path)) {
        active.add(path);
      }
    }
    for (final key in _currentDisplayedGpuKeys.values) {
      if (_preloadedImages.containsKey(key)) {
        active.add(key);
      }
    }
    return active;
  }

  static GpuCompositeResult? _peekGpuResult(String? cacheKey) {
    if (cacheKey == null) {
      return null;
    }
    final cached = _gpuResultCache.remove(cacheKey);
    if (cached != null) {
      _gpuResultCache[cacheKey] = cached;
    }
    return cached;
  }

  static void _cacheGpuResult(
    String cacheKey,
    GpuCompositeResult result, {
    bool markAsPreloaded = false,
  }) {
    _gpuResultCache.remove(cacheKey);

    _gpuResultCache[cacheKey] = result;
    if (markAsPreloaded) {
      _gpuPreloadedKeys.add(cacheKey);
    } else {
      _gpuPreloadedKeys.remove(cacheKey);
    }

    _enforceGpuCacheLimit();
  }

  static void _enforceGpuCacheLimit() {
    var decodedBytes = _gpuResultCache.values.fold<int>(
      0,
      (total, result) => total + result.estimatedDecodedBytes,
    );
    if (_gpuResultCache.length <= _maxGpuResultEntries &&
        decodedBytes <= _maxGpuResultBytes) {
      return;
    }

    final protectedKeys = _collectActiveGpuKeys();
    final keysToRemove = <String>[];
    for (final key in _gpuResultCache.keys) {
      if (_gpuResultCache.length - keysToRemove.length <=
              _maxGpuResultEntries &&
          decodedBytes <= _maxGpuResultBytes) {
        break;
      }
      if (protectedKeys.contains(key)) {
        continue;
      }
      keysToRemove.add(key);
      decodedBytes -= _gpuResultCache[key]?.estimatedDecodedBytes ?? 0;
    }

    if (keysToRemove.isEmpty) {
      return;
    }

    for (final key in keysToRemove) {
      _evictGpuCacheKey(key);
    }
  }

  static void _evictGpuCacheKey(String key) {
    final removed = _gpuResultCache.remove(key);
    if (removed == null) {
      return;
    }
    _gpuPreloadedKeys.remove(key);
    _gpuFutureCache.remove(key);
    _gpuFlattenTasks.remove(key);
    _futureCache.remove(key);
    _completedPaths.remove(key);
    final preloaded = _preloadedImages.remove(key);
    try {
      preloaded?.dispose();
    } catch (_) {}
    _gpuCompositor.removeEntry(key);
  }

  static Set<String> _collectActiveGpuKeys() {
    return _currentDisplayedGpuKeys.values.toSet();
  }

  /// 加载并缓存图像到内存（关键方法）
  static Future<String?> _loadAndCacheImage({
    required String resourceId,
    required String pose,
    required String expression,
    required String cacheKey,
    required String displayKey,
  }) async {
    try {
      print('[CompositeCgRenderer] 开始加载: $cacheKey');

      if (_useGpuAcceleration) {
        final entry = await _gpuCompositor.getCompositeEntry(
          resourceId: resourceId,
          pose: pose,
          expression: expression,
        );

        if (entry == null) {
          print('[CompositeCgRenderer] 合成失败: $cacheKey');
          return null;
        }

        _cacheGpuResult(cacheKey, entry.result, markAsPreloaded: true);
        return entry.virtualPath;
      }

      // 先获取合成图像路径 - 使用传统合成器
      final compositeImagePath = await _legacyCompositor.getCompositeImagePath(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );

      print('[CompositeCgRenderer] 合成路径: $compositeImagePath');

      if (compositeImagePath != null) {
        // 缓存完成的路径
        _completedPaths[cacheKey] = compositeImagePath;

        final imageBytes = _legacyCompositor.getImageBytes(compositeImagePath);
        print('[CompositeCgRenderer] 内存缓存存在: ${imageBytes != null}');

        if (imageBytes != null) {
          // 将字节数据转换为ui.Image 并缓存少量首帧，用于渐变
          final codec = await ui.instantiateImageCodec(imageBytes);
          final frame = await codec.getNextFrame();
          codec.dispose();
          _storePreloadedImage(cacheKey, frame.image);
        } else {
          print('[CompositeCgRenderer] 内存缓存中无数据: $compositeImagePath');
        }

        // 更新当前显示的图像
        _currentDisplayedImages[displayKey] = compositeImagePath;
      } else {
        print('[CompositeCgRenderer] 合成失败: $cacheKey');
      }

      return compositeImagePath;
    } catch (e) {
      print('[CompositeCgRenderer] 加载异常: $cacheKey - $e');
      return null;
    }
  }

  /// 全局预热 - 在游戏启动时预热所有常见CG组合
  static void _startGlobalPreWarming() {}

  /// 检查CG组合是否存在
  static Future<bool> _checkCgCombinationExists(
    String resourceId,
    String pose,
    String expression,
  ) async {
    try {
      final compositeImagePath = _useGpuAcceleration
          ? await _gpuCompositor.getCompositeImagePath(
              resourceId: resourceId,
              pose: pose,
              expression: expression,
            )
          : await _legacyCompositor.getCompositeImagePath(
              resourceId: resourceId,
              pose: pose,
              expression: expression,
            );
      return compositeImagePath != null;
    } catch (e) {
      return false;
    }
  }

  /// 预显示常见的差分变化，确保后续切换不是"第一次"
  static Future<void> _preDisplayCommonVariations(
    String resourceId,
    String pose,
  ) async {
    print('[CompositeCgRenderer] 开始预热角色: $resourceId $pose');

    // 从游戏管理器获取脚本信息来预热实际使用的差分
    // 这里简化为仅预热当前组合，因为完整的脚本分析在游戏启动时已完成
    print('[CompositeCgRenderer] 脚本分析预热已在游戏启动时完成');
  }

  /// 清理缓存
  static void clearCache() {
    _futureCache.clear();
    _completedPaths.clear();
    _preDisplayedCgs.clear();
    _currentDisplayedImages.clear();
    _gpuFutureCache.clear();
    _gpuResultCache.clear();
    _gpuPreloadedKeys.clear();
    _currentDisplayedGpuKeys.clear();
    _gpuFlattenTasks.clear();

    for (final image in _preloadedImages.values) {
      try {
        image.dispose();
      } catch (_) {}
    }
    _preloadedImages.clear();
    // GpuImageCompositor 是分层纹理的唯一所有者；统一从这里释放，
    // 避免渲染器与合成器分别 dispose 同一个 ui.Image。
    unawaited(_gpuCompositor.clearCache());

    // 重置预热标志，允许重新预热
    _preWarmingStarted = false;
  }

  /// 设置GPU加速开关
  static void setGpuAcceleration(bool enabled) {
    _useGpuAcceleration = enabled;
    if (enabled) {
      print('[CompositeCgRenderer] 🚀 GPU加速已启用');
    } else {
      print('[CompositeCgRenderer] 🔄 已切换到传统CPU合成器');
    }
  }

  /// 获取当前GPU加速状态
  static bool get isGpuAccelerationEnabled => _useGpuAcceleration;
}

/// GPU 直接显示控件（使用 GPU 图层实时合成）
class GpuDirectCgDisplay extends StatefulWidget {
  final GpuCompositeResult result;
  final String resourceId;
  final bool isFadingOut;
  final bool skipAnimation;
  final bool enableFadeIn;
  final bool preferSpeed;

  const GpuDirectCgDisplay({
    super.key,
    required this.result,
    required this.resourceId,
    this.isFadingOut = false,
    this.skipAnimation = false,
    this.enableFadeIn = false,
    this.preferSpeed = false,
  });

  @override
  State<GpuDirectCgDisplay> createState() => _GpuDirectCgDisplayState();
}

class _GpuDirectCgDisplayState extends State<GpuDirectCgDisplay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    final bool shouldFadeIn =
        widget.enableFadeIn && !widget.isFadingOut && !widget.skipAnimation;
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: widget.isFadingOut ? 0.0 : (shouldFadeIn ? 0.0 : 1.0),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    if (!widget.isFadingOut && !widget.skipAnimation) {
      if (shouldFadeIn) {
        _fadeController.forward();
      } else if (_fadeController.value < 1.0) {
        _fadeController.forward();
      }
    }
  }

  @override
  void didUpdateWidget(covariant GpuDirectCgDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.result != oldWidget.result) {
      if (widget.skipAnimation) {
        _fadeController.value = widget.isFadingOut ? 0.0 : 1.0;
      } else {
        final bool shouldFadeIn = widget.enableFadeIn && !widget.isFadingOut;
        _fadeController.forward(from: shouldFadeIn ? 0.0 : 0.0);
      }
    }

    if (!oldWidget.isFadingOut && widget.isFadingOut) {
      if (widget.skipAnimation) {
        _fadeController.value = 0.0;
      } else {
        _fadeController.reverse();
      }
    } else if (oldWidget.isFadingOut && !widget.isFadingOut) {
      if (widget.skipAnimation) {
        _fadeController.value = 1.0;
      } else {
        _fadeController.forward();
      }
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: GpuCompositePainter(
                result: widget.result,
                opacity: _fadeAnimation.value,
                preferSpeed: widget.preferSpeed,
              ),
            );
          },
        );
      },
    );
  }
}

/// GPU 无缝切换控件，支持在两组图层之间进行平滑过渡
class GpuSeamlessCgDisplay extends StatefulWidget {
  final GpuCompositeResult? newResult;
  final GpuCompositeResult? currentResult;
  final String resourceId;
  final bool isFadingOut;
  final bool skipAnimation;
  final bool preferSpeed;

  const GpuSeamlessCgDisplay({
    super.key,
    this.newResult,
    this.currentResult,
    required this.resourceId,
    this.isFadingOut = false,
    this.skipAnimation = false,
    this.preferSpeed = false,
  });

  @override
  State<GpuSeamlessCgDisplay> createState() => _GpuSeamlessCgDisplayState();
}

class _GpuSeamlessCgDisplayState extends State<GpuSeamlessCgDisplay>
    with TickerProviderStateMixin {
  late final AnimationController _transitionController;
  late final Animation<double> _transitionAnimation;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  GpuCompositeResult? _currentResult;
  GpuCompositeResult? _incomingResult;

  @override
  void initState() {
    super.initState();

    _transitionController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: 1.0,
    );
    _transitionAnimation = CurvedAnimation(
      parent: _transitionController,
      curve: Curves.easeInOut,
    );

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: widget.isFadingOut ? 0.0 : 1.0,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    _currentResult = widget.currentResult ?? widget.newResult;
    if (widget.skipAnimation) {
      _currentResult = widget.newResult ?? widget.currentResult;
      _incomingResult = null;
      _transitionController.value = 1.0;
      _fadeController.value = widget.isFadingOut ? 0.0 : 1.0;
    } else {
      if (widget.newResult != null &&
          widget.newResult != widget.currentResult) {
        _startTransition(widget.newResult!);
      }

      if (widget.isFadingOut) {
        _fadeController.reverse(from: 1.0);
      }
    }

    _transitionController.addStatusListener(_handleTransitionStatus);
  }

  void _handleTransitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _incomingResult != null) {
      _currentResult = _incomingResult;
      _incomingResult = null;
      setState(() {});
    }
  }

  void _startTransition(GpuCompositeResult nextResult) {
    _incomingResult = nextResult;
    _transitionController
      ..value = 0.0
      ..forward();
  }

  @override
  void didUpdateWidget(covariant GpuSeamlessCgDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newResult = widget.newResult;
    if (newResult != null &&
        newResult != _incomingResult &&
        newResult != _currentResult) {
      if (widget.skipAnimation) {
        _currentResult = newResult;
        _incomingResult = null;
        _transitionController.value = 1.0;
        setState(() {});
      } else {
        _startTransition(newResult);
      }
    } else if (newResult == null &&
        widget.currentResult != null &&
        widget.currentResult != _currentResult) {
      _currentResult = widget.currentResult;
      _incomingResult = null;
      _transitionController.value = 1.0;
      setState(() {});
    }

    if (!oldWidget.isFadingOut && widget.isFadingOut) {
      if (widget.skipAnimation) {
        _fadeController.value = 0.0;
      } else {
        _fadeController.reverse();
      }
    } else if (oldWidget.isFadingOut && !widget.isFadingOut) {
      if (widget.skipAnimation) {
        _fadeController.value = 1.0;
      } else {
        _fadeController.forward();
      }
    }
  }

  @override
  void dispose() {
    _transitionController.removeStatusListener(_handleTransitionStatus);
    _transitionController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentResult == null && _incomingResult == null) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.transparent,
      );
    }

    final listenable = Listenable.merge(<Listenable>[
      _transitionController,
      _fadeController,
    ]);

    return AnimatedBuilder(
      animation: listenable,
      builder: (context, child) {
        final transitionValue = _incomingResult == null
            ? 0.0
            : _transitionAnimation.value.clamp(0.0, 1.0);
        final fadeValue = _fadeAnimation.value.clamp(0.0, 1.0);

        final currentOpacity = _incomingResult != null
            ? (1.0 - transitionValue) * fadeValue
            : fadeValue;
        final newOpacity = _incomingResult != null
            ? transitionValue * fadeValue
            : 0.0;

        return LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: GpuSeamlessCgPainter(
                currentResult: _currentResult,
                newResult: _incomingResult,
                currentOpacity: currentOpacity,
                newOpacity: newOpacity,
                preferSpeed: widget.preferSpeed,
              ),
            );
          },
        );
      },
    );
  }
}

class GpuCompositePainter extends CustomPainter {
  final GpuCompositeResult result;
  final double opacity;
  final bool preferSpeed;

  GpuCompositePainter({
    required this.result,
    required this.opacity,
    this.preferSpeed = false,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    _drawCompositeResult(
      canvas,
      size,
      result,
      opacity,
      preferSpeed: preferSpeed,
    );
  }

  @override
  bool shouldRepaint(GpuCompositePainter oldDelegate) {
    return result != oldDelegate.result ||
        opacity != oldDelegate.opacity ||
        preferSpeed != oldDelegate.preferSpeed;
  }
}

class GpuSeamlessCgPainter extends CustomPainter {
  final GpuCompositeResult? currentResult;
  final GpuCompositeResult? newResult;
  final double currentOpacity;
  final double newOpacity;
  final bool preferSpeed;

  GpuSeamlessCgPainter({
    required this.currentResult,
    required this.newResult,
    required this.currentOpacity,
    required this.newOpacity,
    this.preferSpeed = false,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    if (size.isEmpty) return;

    if (currentResult != null && currentOpacity > 0) {
      _drawCompositeResult(
        canvas,
        size,
        currentResult!,
        currentOpacity,
        preferSpeed: preferSpeed,
      );
    }
    if (newResult != null && newOpacity > 0) {
      _drawCompositeResult(
        canvas,
        size,
        newResult!,
        newOpacity,
        preferSpeed: preferSpeed,
      );
    }
  }

  @override
  bool shouldRepaint(GpuSeamlessCgPainter oldDelegate) {
    return currentResult != oldDelegate.currentResult ||
        newResult != oldDelegate.newResult ||
        currentOpacity != oldDelegate.currentOpacity ||
        newOpacity != oldDelegate.newOpacity ||
        preferSpeed != oldDelegate.preferSpeed;
  }
}

/// 直接CG显示组件（用于已预加载的图像）
///
/// 会在同一角色的差分切换时使用溶解效果过渡
class DirectCgDisplay extends StatefulWidget {
  final ui.Image image;
  final String resourceId;
  final bool isFadingOut;
  final bool enableFadeIn;
  final bool skipAnimation;
  final BoxFit fit;

  const DirectCgDisplay({
    super.key,
    required this.image,
    required this.resourceId,
    this.isFadingOut = false,
    this.enableFadeIn = false,
    this.skipAnimation = false,
    this.fit = BoxFit.cover,
  });

  @override
  State<DirectCgDisplay> createState() => _DirectCgDisplayState();
}

class _DirectCgDisplayState extends State<DirectCgDisplay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _progress;

  ui.Image? _currentImage;
  ui.Image? _previousImage;
  bool _hasShownOnce = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _progress = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    _currentImage = widget.image;
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_controller.isAnimating) {
        _previousImage = null;
        _hasShownOnce = true;
      }
    });

    if (widget.skipAnimation) {
      _controller.value = 1.0;
      _hasShownOnce = true;
    } else {
      _controller.forward();
    }
    CompositeCgRenderer._ensureDissolveProgram().then((_) {
      if (mounted && CompositeCgRenderer._dissolveProgram != null) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant DirectCgDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    final imageChanged = widget.image != _currentImage;
    final fadingChanged = widget.isFadingOut != oldWidget.isFadingOut;

    if (imageChanged) {
      _previousImage = _currentImage;
      _currentImage = widget.image;
      if (widget.skipAnimation) {
        _controller.value = 1.0;
        _previousImage = null;
        _hasShownOnce = true;
      } else {
        _controller.forward(from: 0.0);
      }
    } else if (fadingChanged) {
      if (widget.isFadingOut) {
        // 淡出时不参与差分溶解
        _previousImage = null;
      }
      if (widget.skipAnimation) {
        _controller.value = widget.isFadingOut ? 0.0 : 1.0;
        _previousImage = null;
        _hasShownOnce = true;
      } else {
        _controller.forward(from: 0.0);
      }
    } else if (widget.skipAnimation && !_hasShownOnce) {
      _controller.value = 1.0;
      _previousImage = null;
      _hasShownOnce = true;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _currentImage;
    if (image == null) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _progress,
      builder: (context, child) {
        final dissolveProgram = CompositeCgRenderer._dissolveProgram;
        final bool shaderAvailable = dissolveProgram != null;
        final bool hasPrevious = _previousImage != null && !widget.isFadingOut;
        final progressValue = _progress.value.clamp(0.0, 1.0);
        double overallAlpha;
        if (widget.isFadingOut) {
          overallAlpha = 1.0 - progressValue;
        } else if (widget.enableFadeIn && !_hasShownOnce && !hasPrevious) {
          // Avoid one-frame transparency flash when a second diff arrives
          // before the first fade-in completes (e.g. timed [x,0.3,y] syntax).
          overallAlpha = progressValue;
        } else {
          overallAlpha = 1.0;
        }
        if (widget.skipAnimation) {
          overallAlpha = widget.isFadingOut ? 0.0 : 1.0;
        }
        overallAlpha = overallAlpha.clamp(0.0, 1.0);
        final ui.Image fromImage = hasPrevious ? _previousImage! : image;
        final double dissolveProgress = hasPrevious ? progressValue : 1.0;
        if (shaderAvailable) {
          return LayoutBuilder(
            builder: (context, constraints) {
              return CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _DissolveShaderPainter(
                  program: dissolveProgram!,
                  progress: dissolveProgress,
                  fromImage: fromImage,
                  toImage: image,
                  opacity: overallAlpha,
                  fit: widget.fit,
                ),
              );
            },
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: DirectCgPainter(
                currentImage: image,
                previousImage: _previousImage,
                progress: progressValue,
                isFadingOut: widget.isFadingOut,
                enableFadeIn: widget.enableFadeIn && !_hasShownOnce,
                preferSpeed: widget.skipAnimation,
                fit: widget.fit,
              ),
            );
          },
        );
      },
    );
  }
}

/// 使用预合成图像的交叉淡入淡出绘制器
class DirectCgPainter extends CustomPainter {
  final ui.Image currentImage;
  final ui.Image? previousImage;
  final double progress;
  final bool isFadingOut;
  final bool enableFadeIn;
  final bool preferSpeed;
  final BoxFit fit;

  DirectCgPainter({
    required this.currentImage,
    required this.previousImage,
    required this.progress,
    required this.isFadingOut,
    required this.enableFadeIn,
    this.preferSpeed = false,
    this.fit = BoxFit.cover,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    if (size.isEmpty) return;

    final clampedProgress = progress.clamp(0.0, 1.0);
    final hasPrevious = previousImage != null;

    if (hasPrevious && !isFadingOut) {
      canvas.saveLayer(null, ui.Paint());
      _drawImage(canvas, size, previousImage!, 1.0 - clampedProgress);
      _drawImage(canvas, size, currentImage, clampedProgress);
      canvas.restore();
      return;
    }

    final opacity = isFadingOut
        ? 1.0 - clampedProgress
        : (enableFadeIn ? clampedProgress : 1.0);
    _drawImage(canvas, size, currentImage, opacity);
  }

  void _drawImage(
    ui.Canvas canvas,
    ui.Size size,
    ui.Image image,
    double opacity,
  ) {
    if (opacity <= 0) return;

    final targetRect = calculateDissolveImageRect(
      size,
      image.width,
      image.height,
      fit,
    );

    final paint = ui.Paint()
      ..color = ui.Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0))
      ..isAntiAlias = true
      ..filterQuality = _resolveFilterQuality(preferSpeed);

    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      targetRect,
      paint,
    );
  }

  @override
  bool shouldRepaint(DirectCgPainter oldDelegate) {
    return currentImage != oldDelegate.currentImage ||
        previousImage != oldDelegate.previousImage ||
        progress != oldDelegate.progress ||
        isFadingOut != oldDelegate.isFadingOut ||
        enableFadeIn != oldDelegate.enableFadeIn ||
        preferSpeed != oldDelegate.preferSpeed ||
        fit != oldDelegate.fit;
  }
}

/// 无缝CG切换显示组件
///
/// 提供在差分切换时无黑屏的平滑过渡效果
class SeamlessCgDisplay extends StatefulWidget {
  final String? newImagePath;
  final String? currentImagePath;
  final String resourceId;
  final ui.FragmentProgram? dissolveProgram;
  final bool isFadingOut;
  final bool skipAnimation;

  const SeamlessCgDisplay({
    super.key,
    this.newImagePath,
    this.currentImagePath,
    required this.resourceId,
    this.dissolveProgram,
    this.isFadingOut = false,
    this.skipAnimation = false,
  });

  @override
  State<SeamlessCgDisplay> createState() => _SeamlessCgDisplayState();
}

class _SeamlessCgDisplayState extends State<SeamlessCgDisplay>
    with TickerProviderStateMixin {
  ui.Image? _currentImage;
  ui.Image? _previousImage;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    // 优先加载当前图像或新图像
    final imageToLoad = widget.newImagePath ?? widget.currentImagePath;
    if (imageToLoad != null) {
      _loadAndSetImage(imageToLoad);
    }

    _fadeController.addStatusListener(_handleFadeStatus);
    if (widget.dissolveProgram == null) {
      CompositeCgRenderer._ensureDissolveProgram().then((_) {
        if (mounted && CompositeCgRenderer._dissolveProgram != null) {
          setState(() {});
        }
      });
    }
    if (widget.skipAnimation) {
      _fadeController.value = widget.isFadingOut ? 0.0 : 1.0;
    }
  }

  @override
  void didUpdateWidget(SeamlessCgDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 如果有新图像路径，加载它
    if (widget.newImagePath != null &&
        widget.newImagePath != oldWidget.newImagePath) {
      _loadAndSetImage(widget.newImagePath!);
    }
    // 如果没有新图像但有当前图像，且当前图像变了，加载当前图像
    else if (widget.newImagePath == null &&
        widget.currentImagePath != null &&
        widget.currentImagePath != oldWidget.currentImagePath) {
      _loadAndSetImage(widget.currentImagePath!);
    }

    if (widget.skipAnimation) {
      _fadeController.value = widget.isFadingOut ? 0.0 : 1.0;
      if (_previousImage != null) {
        _previousImage = null;
      }
    }
  }

  Future<void> _loadAndSetImage(String imagePath) async {
    try {
      // 修复：优先从内存缓存获取图像数据
      final imageBytes = CompositeCgRenderer._legacyCompositor.getImageBytes(
        imagePath,
      );
      if (imageBytes != null) {
        final codec = await ui.instantiateImageCodec(imageBytes);
        final frame = await codec.getNextFrame();

        if (mounted) {
          final oldImage = _currentImage;

          setState(() {
            _previousImage = oldImage;
            _currentImage = frame.image;
          });

          if (widget.skipAnimation) {
            _fadeController.value = widget.isFadingOut ? 0.0 : 1.0;
            _previousImage = null;
          } else {
            _fadeController.forward(from: 0.0);
          }
        }
        return;
      }

      // 降级到文件系统（兼容性处理）
      final file = File(imagePath);
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();

      if (mounted) {
        final oldImage = _currentImage;

        setState(() {
          _previousImage = oldImage;
          _currentImage = frame.image;
        });

        if (widget.skipAnimation) {
          _fadeController.value = widget.isFadingOut ? 0.0 : 1.0;
          _previousImage = null;
        } else {
          _fadeController.forward(from: 0.0);
        }
      }
    } catch (e) {
      // 加载失败时保持当前显示的图像不变
    }
  }

  @override
  void dispose() {
    _fadeController.removeStatusListener(_handleFadeStatus);
    _fadeController.dispose();
    _previousImage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 关键：如果没有图像可显示，返回透明容器而不是空白
    if (_currentImage == null) {
      return Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.transparent,
      );
    }

    final dissolveProgram =
        widget.dissolveProgram ?? CompositeCgRenderer._dissolveProgram;
    final bool shaderAvailable = dissolveProgram != null;
    final bool skipping = widget.skipAnimation;
    final double animationValue = skipping
        ? (widget.isFadingOut ? 0.0 : 1.0)
        : _fadeAnimation.value.clamp(0.0, 1.0);
    final bool hasPrevious =
        !skipping && _previousImage != null && !widget.isFadingOut;
    double overallAlpha;
    if (widget.isFadingOut) {
      overallAlpha = skipping ? 0.0 : 1.0 - animationValue;
    } else {
      overallAlpha = 1.0;
    }
    overallAlpha = overallAlpha.clamp(0.0, 1.0);
    final ui.Image fromImage = hasPrevious ? _previousImage! : _currentImage!;
    final double dissolveProgress = hasPrevious ? animationValue : 1.0;

    if (shaderAvailable) {
      return AnimatedBuilder(
        animation: _fadeAnimation,
        builder: (context, child) {
          return LayoutBuilder(
            builder: (context, constraints) {
              return CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _DissolveShaderPainter(
                  program: dissolveProgram!,
                  progress: dissolveProgress,
                  fromImage: fromImage,
                  toImage: _currentImage!,
                  opacity: overallAlpha,
                ),
              );
            },
          );
        },
      );
    }

    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) {
        final double painterOpacity = widget.skipAnimation
            ? (widget.isFadingOut ? 0.0 : 1.0)
            : _fadeAnimation.value;

        // 计算过渡透明度（仅在有前一张图像时使用）
        final double transitionOpacity = hasPrevious ? animationValue : 0.0;

        return LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: SeamlessCgPainter(
                currentImage: _currentImage,
                newImage: _previousImage, // 传递前一张图像用于过渡
                fadeOpacity: painterOpacity,
                transitionOpacity: transitionOpacity,
                preferSpeed: widget.skipAnimation,
              ),
            );
          },
        );
      },
    );
  }

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _previousImage = null;
    }
  }
}

class _FirstCgFadeWrapper extends StatefulWidget {
  final String fadeKey;
  final Widget child;
  final bool enableFade;

  const _FirstCgFadeWrapper({
    required this.fadeKey,
    required this.child,
    required this.enableFade,
  });

  @override
  State<_FirstCgFadeWrapper> createState() => _FirstCgFadeWrapperState();
}

class _FirstCgFadeWrapperState extends State<_FirstCgFadeWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late bool _shouldFade;

  @override
  void initState() {
    super.initState();
    _shouldFade = widget.enableFade;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: _shouldFade ? 0.0 : 1.0,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

    if (_shouldFade) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _FirstCgFadeWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fadeKey != widget.fadeKey) {
      _shouldFade = widget.enableFade;
      _controller.value = _shouldFade ? 0.0 : 1.0;
      if (_shouldFade) {
        _controller.forward();
      }
      return;
    }

    if (widget.enableFade && !_shouldFade) {
      _shouldFade = true;
      _controller.value = 0.0;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldFade) {
      return widget.child;
    }
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// 合成CG显示组件
class CompositeCgDisplay extends StatefulWidget {
  final String imagePath;
  final bool isFadingOut;

  const CompositeCgDisplay({
    super.key,
    required this.imagePath,
    this.isFadingOut = false,
  });

  @override
  State<CompositeCgDisplay> createState() => _CompositeCgDisplayState();
}

class _CompositeCgDisplayState extends State<CompositeCgDisplay>
    with SingleTickerProviderStateMixin {
  ui.Image? _image;
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(_controller);

    _loadImage();
  }

  @override
  void didUpdateWidget(covariant CompositeCgDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 检查是否开始淡出
    if (!oldWidget.isFadingOut && widget.isFadingOut) {
      _controller.reverse();
      return;
    }

    // 检查图像路径是否改变
    if (oldWidget.imagePath != widget.imagePath) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    try {
      final file = File(widget.imagePath);
      if (!await file.exists()) {
        return;
      }

      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();

      if (mounted) {
        setState(() {
          _image?.dispose(); // 释放旧图像
          _image = frame.image;
        });

        // 开始淡入动画
        _controller.forward();
      }
    } catch (e) {
      // 静默处理错误
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, child) {
        return LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: CompositeCgPainter(
                image: _image!,
                opacity: _fadeAnimation.value,
                preferSpeed: CompositeCgRenderer._preferSpeedRendering,
              ),
            );
          },
        );
      },
    );
  }
}

class _DissolveShaderPainter extends CustomPainter {
  final ui.FragmentProgram program;
  final double progress;
  final ui.Image fromImage;
  final ui.Image toImage;
  final double opacity;
  final BoxFit fit;

  _DissolveShaderPainter({
    required this.program,
    required this.progress,
    required this.fromImage,
    required this.toImage,
    required this.opacity,
    this.fit = BoxFit.cover,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    if (size.isEmpty) return;

    // Each image gets its own aspect-preserving rectangle. The shader still
    // performs the exact same per-pixel mix used by ordinary expression diffs,
    // but resource sets with different canvas ratios no longer stretch the
    // outgoing image into the incoming image's bounds.
    final fromRect = calculateDissolveImageRect(
      size,
      fromImage.width,
      fromImage.height,
      fit,
    );
    final toRect = calculateDissolveImageRect(
      size,
      toImage.width,
      toImage.height,
      fit,
    );

    final shader = program.fragmentShader();
    shader
      ..setFloat(0, progress.clamp(0.0, 1.0))
      ..setFloat(1, fromRect.width)
      ..setFloat(2, fromRect.height)
      ..setFloat(3, fromImage.width.toDouble())
      ..setFloat(4, fromImage.height.toDouble())
      ..setFloat(5, toRect.width)
      ..setFloat(6, toRect.height)
      ..setFloat(7, toImage.width.toDouble())
      ..setFloat(8, toImage.height.toDouble())
      ..setFloat(9, fromRect.left)
      ..setFloat(10, fromRect.top)
      ..setFloat(11, toRect.left)
      ..setFloat(12, toRect.top)
      ..setFloat(13, opacity.clamp(0.0, 1.0));

    // 让 shader 采样跟随引擎的最近邻配置（像素风立绘）。
    // dissolve.frag 使用单点 texture() 采样，插值方式由 sampler 决定。
    final samplerQuality = ImageSamplingManager().resolveCanvasFilterQuality(
      defaultQuality: ui.FilterQuality.high,
    );
    shader
      ..setImageSampler(0, fromImage, filterQuality: samplerQuality)
      ..setImageSampler(1, toImage, filterQuality: samplerQuality);

    final paint = ui.Paint()..shader = shader;

    // Paint the union rather than clipping to the incoming image's widget
    // bounds. The shader makes pixels outside each image rect transparent, so
    // a wider outgoing sprite remains fully visible during the dissolve.
    canvas.drawRect(fromRect.expandToInclude(toRect), paint);
  }

  @override
  bool shouldRepaint(covariant _DissolveShaderPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        fromImage != oldDelegate.fromImage ||
        toImage != oldDelegate.toImage ||
        program != oldDelegate.program ||
        opacity != oldDelegate.opacity ||
        fit != oldDelegate.fit;
  }
}

/// 无缝CG切换绘制器
///
/// 支持两个图像之间的平滑过渡，避免黑屏
class SeamlessCgPainter extends CustomPainter {
  final ui.Image? currentImage;
  final ui.Image? newImage;
  final double fadeOpacity;
  final double transitionOpacity;
  final bool preferSpeed;

  SeamlessCgPainter({
    this.currentImage,
    this.newImage,
    required this.fadeOpacity,
    required this.transitionOpacity,
    this.preferSpeed = false,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    if (size.isEmpty) return;

    try {
      // 如果正在过渡，绘制两个图像的混合
      if (newImage != null && currentImage != null && transitionOpacity > 0) {
        // 绘制当前图像（透明度递减）
        _drawImageWithOpacity(
          canvas,
          size,
          currentImage!,
          1.0 - transitionOpacity,
        );

        // 绘制新图像（透明度递增）
        _drawImageWithOpacity(canvas, size, newImage!, transitionOpacity);
      }
      // 只有当前图像
      else if (currentImage != null) {
        _drawImageWithOpacity(canvas, size, currentImage!, fadeOpacity);
      }
      // 只有新图像
      else if (newImage != null) {
        _drawImageWithOpacity(canvas, size, newImage!, fadeOpacity);
      }
    } catch (e) {
      // 静默处理绘制错误
    }
  }

  void _drawImageWithOpacity(
    ui.Canvas canvas,
    ui.Size size,
    ui.Image image,
    double opacity,
  ) {
    if (opacity <= 0) return;

    try {
      // 计算BoxFit.cover的缩放和定位
      final imageSize = Size(image.width.toDouble(), image.height.toDouble());

      // 计算缩放比例（cover模式取较大的缩放比例）
      final scaleX = size.width / imageSize.width;
      final scaleY = size.height / imageSize.height;
      final scale = scaleX > scaleY ? scaleX : scaleY;

      // 计算缩放后的尺寸
      final scaledWidth = imageSize.width * scale;
      final scaledHeight = imageSize.height * scale;

      // 计算居中偏移
      final offsetX = (size.width - scaledWidth) / 2;
      final offsetY = (size.height - scaledHeight) / 2;

      // 创建目标矩形
      final targetRect = ui.Rect.fromLTWH(
        offsetX,
        offsetY,
        scaledWidth,
        scaledHeight,
      );

      // 创建画笔，设置透明度
      final paint = ui.Paint()
        ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0))
        ..isAntiAlias = true
        ..filterQuality = _resolveFilterQuality(preferSpeed);

      // 绘制图像
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        targetRect,
        paint,
      );
    } catch (e) {
      // 静默处理绘制错误
    }
  }

  @override
  bool shouldRepaint(SeamlessCgPainter oldDelegate) {
    return currentImage != oldDelegate.currentImage ||
        newImage != oldDelegate.newImage ||
        fadeOpacity != oldDelegate.fadeOpacity ||
        transitionOpacity != oldDelegate.transitionOpacity ||
        preferSpeed != oldDelegate.preferSpeed;
  }
}

/// 合成CG图像的绘制器
class CompositeCgPainter extends CustomPainter {
  final ui.Image image;
  final double opacity;
  final bool preferSpeed;

  CompositeCgPainter({
    required this.image,
    required this.opacity,
    this.preferSpeed = false,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    try {
      // 计算BoxFit.cover的缩放和定位
      final imageSize = Size(image.width.toDouble(), image.height.toDouble());

      // 计算缩放比例（cover模式取较大的缩放比例）
      final scaleX = size.width / imageSize.width;
      final scaleY = size.height / imageSize.height;
      final scale = scaleX > scaleY ? scaleX : scaleY;

      // 计算缩放后的尺寸
      final scaledWidth = imageSize.width * scale;
      final scaledHeight = imageSize.height * scale;

      // 计算居中偏移
      final offsetX = (size.width - scaledWidth) / 2;
      final offsetY = (size.height - scaledHeight) / 2;

      // 创建目标矩形
      final targetRect = ui.Rect.fromLTWH(
        offsetX,
        offsetY,
        scaledWidth,
        scaledHeight,
      );

      // 创建画笔，设置透明度
      final paint = ui.Paint()
        ..color = Color.fromRGBO(255, 255, 255, opacity)
        ..isAntiAlias = true
        ..filterQuality = _resolveFilterQuality(preferSpeed);

      // 绘制图像
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        targetRect,
        paint,
      );
    } catch (e) {
      // 静默处理绘制错误
    }
  }

  @override
  bool shouldRepaint(covariant CompositeCgPainter oldDelegate) {
    return image != oldDelegate.image ||
        opacity != oldDelegate.opacity ||
        preferSpeed != oldDelegate.preferSpeed;
  }
}

ui.Rect _calculateCoverRect(ui.Size canvasSize, int width, int height) {
  if (canvasSize.isEmpty || width == 0 || height == 0) {
    return ui.Rect.zero;
  }

  final imageWidth = width.toDouble();
  final imageHeight = height.toDouble();
  final scaleX = canvasSize.width / imageWidth;
  final scaleY = canvasSize.height / imageHeight;
  final scale = math.max(scaleX, scaleY);

  final scaledWidth = imageWidth * scale;
  final scaledHeight = imageHeight * scale;
  final offsetX = (canvasSize.width - scaledWidth) / 2;
  final offsetY = (canvasSize.height - scaledHeight) / 2;

  return ui.Rect.fromLTWH(offsetX, offsetY, scaledWidth, scaledHeight);
}

void _drawCompositeResult(
  ui.Canvas canvas,
  ui.Size size,
  GpuCompositeResult result,
  double opacity, {
  bool preferSpeed = false,
}) {
  if (opacity <= 0 || size.isEmpty) return;

  final targetRect = _calculateCoverRect(size, result.width, result.height);
  if (targetRect.isEmpty) return;

  final srcRect = ui.Rect.fromLTWH(
    0,
    0,
    result.width.toDouble(),
    result.height.toDouble(),
  );

  final alpha = opacity.clamp(0.0, 1.0);
  final paint = ui.Paint()
    ..isAntiAlias = true
    ..filterQuality = _resolveFilterQuality(preferSpeed);

  for (var index = 0; index < result.layers.length; index++) {
    final layer = result.layers[index];
    paint
      ..blendMode = index == 0 ? ui.BlendMode.src : ui.BlendMode.srcOver
      ..color = ui.Color.fromRGBO(255, 255, 255, alpha);
    canvas.drawImageRect(layer, srcRect, targetRect, paint);
  }
}

/// CG加载包装器，用于在异步加载时保持Widget结构稳定
class _CgLoadingWrapper extends StatefulWidget {
  final Future<String?> future;
  final String displayKey;
  final String? currentImagePath;
  final String resourceId;
  final bool isFadingOut;
  final bool skipAnimation;
  final bool isFirstAppearance;

  const _CgLoadingWrapper({
    super.key,
    required this.future,
    required this.displayKey,
    required this.currentImagePath,
    required this.resourceId,
    required this.isFadingOut,
    required this.skipAnimation,
    required this.isFirstAppearance,
  });

  @override
  State<_CgLoadingWrapper> createState() => _CgLoadingWrapperState();
}

class _CgLoadingWrapperState extends State<_CgLoadingWrapper> {
  String? _loadedImagePath;

  @override
  void initState() {
    super.initState();
    _listenToFuture();
  }

  @override
  void didUpdateWidget(_CgLoadingWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.future != oldWidget.future) {
      _listenToFuture();
    }
  }

  void _listenToFuture() {
    widget.future.then((path) {
      if (mounted && path != null) {
        setState(() {
          _loadedImagePath = path;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _FirstCgFadeWrapper(
      fadeKey: widget.displayKey,
      enableFade: widget.isFirstAppearance,
      child: SeamlessCgDisplay(
        key: ValueKey('seamless_display_${widget.displayKey}'),
        newImagePath: _loadedImagePath,
        currentImagePath: widget.currentImagePath,
        resourceId: widget.resourceId,
        dissolveProgram: CompositeCgRenderer._dissolveProgram,
        isFadingOut: widget.isFadingOut,
        skipAnimation: widget.skipAnimation,
      ),
    );
  }
}

/// CG快照，用于在不同CG切换时保留前一张作为背景
class _PreviousCgSnapshot {
  final String resourceId;
  final String? imagePath;
  final ui.Image? image;

  _PreviousCgSnapshot({required this.resourceId, this.imagePath, this.image});
}

/// CG槽位Widget - 管理场景中唯一的CG位置
///
/// 这个Widget使用固定的key，确保所有CG切换都是同一个Widget实例的状态更新
/// 类似于角色立绘的实现方式
class CgSlotWidget extends StatefulWidget {
  final String resourceId;
  final String pose;
  final String expression;
  final int cacheRevision;
  final bool isFadingOut;
  final bool skipAnimation;
  final bool useGpuAcceleration;
  final Duration transitionDuration;
  final VoidCallback? onTransitionCompleted;
  final Map<String, double>? animationProperties; // 新增：动画属性

  const CgSlotWidget({
    super.key,
    required this.resourceId,
    required this.pose,
    required this.expression,
    required this.cacheRevision,
    required this.isFadingOut,
    required this.skipAnimation,
    required this.useGpuAcceleration,
    this.transitionDuration = const Duration(milliseconds: 300),
    this.onTransitionCompleted,
    this.animationProperties, // 新增
  });

  @override
  State<CgSlotWidget> createState() => _CgSlotWidgetState();
}

class _CgSlotWidgetState extends State<CgSlotWidget>
    with SingleTickerProviderStateMixin {
  // 当前显示的图像
  ui.Image? _currentImage;
  // 前一张图像（用于渐变）
  ui.Image? _previousImage;

  // 当前加载的内容标识
  String? _currentContentId;

  // 渐变动画控制器
  late AnimationController _transitionController;
  late Animation<double> _transitionAnimation;

  // 是否是第一次显示CG（用于从背景渐变到CG）
  bool _isFirstCg = true;
  int _loadRequestToken = 0;

  String _targetContentId() {
    return '${widget.resourceId}_${widget.pose}_${widget.expression}';
  }

  @override
  void initState() {
    super.initState();

    _transitionController = AnimationController(
      duration: widget.transitionDuration,
      vsync: this,
    );
    _transitionAnimation = CurvedAnimation(
      parent: _transitionController,
      curve: Curves.easeInOut,
    );
    _transitionController.addStatusListener(_handleTransitionStatus);

    // 加载shader
    CompositeCgRenderer._ensureDissolveProgram().then((_) {
      if (mounted && CompositeCgRenderer._dissolveProgram != null) {
        setState(() {}); // 触发重建以使用shader
      }
    });

    // 初始加载
    _loadCgImage(
      resourceId: widget.resourceId,
      pose: widget.pose,
      expression: widget.expression,
      contentId: _targetContentId(),
      trigger: 'init',
    );
  }

  @override
  void didUpdateWidget(CgSlotWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.transitionDuration != widget.transitionDuration) {
      _transitionController.duration = widget.transitionDuration;
    }

    final newContentId = _targetContentId();
    final oldRequestedContentId =
        '${oldWidget.resourceId}_${oldWidget.pose}_${oldWidget.expression}';
    final contentChanged = oldRequestedContentId != newContentId;
    final cacheInvalidated = oldWidget.cacheRevision != widget.cacheRevision;

    // 配置热重载会清空共享合成缓存。即使CG资源、pose和差分没有变化，
    // 也必须重新取得新revision的图像，否则槽位会继续绘制已经释放的旧图像。
    if (contentChanged || cacheInvalidated) {
      // 缓存失效时旧图像即将被释放，不能再把它交给dissolve采样。
      // 普通差分切换仍保留原有的前后图融合。
      _previousImage = contentChanged && !cacheInvalidated
          ? _currentImage
          : null;
      CompositeCgRenderer._logCgTransition(
        'reload old=$oldRequestedContentId -> new=$newContentId, '
        'contentChanged=$contentChanged, cacheInvalidated=$cacheInvalidated, '
        'hasCurrent=${_currentImage != null}, hasPrevious=${_previousImage != null}, '
        'skipAnimation=${widget.skipAnimation}, isFadingOut=${widget.isFadingOut}',
      );

      _loadCgImage(
        resourceId: widget.resourceId,
        pose: widget.pose,
        expression: widget.expression,
        contentId: newContentId,
        trigger: cacheInvalidated ? 'cache_revision' : 'update',
        animateTransition: !cacheInvalidated,
      );
    }

    // 处理淡出状态变化
    if (oldWidget.isFadingOut != widget.isFadingOut) {
      if (widget.isFadingOut) {
        _transitionController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _transitionController.removeStatusListener(_handleTransitionStatus);
    _transitionController.dispose();
    super.dispose();
  }

  void _handleTransitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onTransitionCompleted?.call();
    }
  }

  Future<void> _loadCgImage({
    required String resourceId,
    required String pose,
    required String expression,
    required String contentId,
    required String trigger,
    bool animateTransition = true,
  }) async {
    final requestToken = ++_loadRequestToken;

    try {
      // 尝试从预合成缓存获取
      final image = await _getCompositeImage(resourceId, pose, expression);

      if (!mounted) return;
      if (requestToken != _loadRequestToken) {
        CompositeCgRenderer._logCgTransition(
          'drop_stale_load trigger=$trigger, content=$contentId, token=$requestToken, currentToken=$_loadRequestToken',
        );
        return;
      }

      setState(() {
        _currentImage = image;
        _currentContentId = contentId;
      });

      if (image == null) {
        CompositeCgRenderer._logCgFallback(
          reason: 'composite_image_null',
          targetContentId: contentId,
          currentContentId: _currentContentId,
          hasCurrentImage: _currentImage != null,
          hasPreviousImage: _previousImage != null,
          shaderAvailable: CompositeCgRenderer._dissolveProgram != null,
          isFadingOut: widget.isFadingOut,
          skipAnimation: widget.skipAnimation,
          useGpuAcceleration: widget.useGpuAcceleration,
          progress: _transitionController.value,
        );
      }

      // 启动渐变动画
      if (animateTransition && !widget.skipAnimation && !widget.isFadingOut) {
        // 对每次成功内容加载都强制触发过渡：
        // - 有_previousImage时走dissolve
        // - 无_previousImage时走透明淡入（防止异步竞态导致“无动画切换”）
        CompositeCgRenderer._logCgTransition(
          'start_transition trigger=$trigger, content=$contentId, hasPrevious=${_previousImage != null}, '
          'isFirstCg=$_isFirstCg, controller=${_transitionController.value.toStringAsFixed(3)}',
        );
        _transitionController.forward(from: 0.0);
        _isFirstCg = false;
      } else {
        CompositeCgRenderer._logCgTransition(
          'skip_transition trigger=$trigger, content=$contentId, '
          'animateTransition=$animateTransition, '
          'skipAnimation=${widget.skipAnimation}, isFadingOut=${widget.isFadingOut}',
        );
        _transitionController.value = 1.0;
        _isFirstCg = false;
      }
    } catch (e) {
      print('[CgSlotWidget] Failed to load CG: $e');
      CompositeCgRenderer._logCgFallback(
        reason: 'load_exception:$e',
        targetContentId: contentId,
        currentContentId: _currentContentId,
        hasCurrentImage: _currentImage != null,
        hasPreviousImage: _previousImage != null,
        shaderAvailable: CompositeCgRenderer._dissolveProgram != null,
        isFadingOut: widget.isFadingOut,
        skipAnimation: widget.skipAnimation,
        useGpuAcceleration: widget.useGpuAcceleration,
        progress: _transitionController.value,
      );
    }
  }

  Future<ui.Image?> _getCompositeImage(
    String resourceId,
    String pose,
    String expression,
  ) async {
    // 使用CharacterCompositeCache获取预合成图像
    final image = await CharacterCompositeCache.instance.preload(
      resourceId,
      pose,
      expression,
    );
    return image;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentImage == null && _previousImage == null) {
      return const SizedBox.shrink();
    }

    // 获取动画属性
    final animProps = widget.animationProperties;
    final screenSize = MediaQuery.of(context).size;

    // 构建shader绘制widget
    Widget cgWidget = AnimatedBuilder(
      animation: _transitionAnimation,
      builder: (context, child) {
        final progress = _transitionAnimation.value;
        final dissolveProgram = CompositeCgRenderer._dissolveProgram;
        final shaderAvailable = dissolveProgram != null;

        if (!shaderAvailable || _currentImage == null) {
          final reasons = <String>[];
          if (!shaderAvailable) {
            reasons.add('shader_unavailable');
          }
          if (_currentImage == null) {
            reasons.add('current_image_null');
          }
          CompositeCgRenderer._logCgFallback(
            reason: reasons.join('+'),
            targetContentId: _targetContentId(),
            currentContentId: _currentContentId,
            hasCurrentImage: _currentImage != null,
            hasPreviousImage: _previousImage != null,
            shaderAvailable: shaderAvailable,
            isFadingOut: widget.isFadingOut,
            skipAnimation: widget.skipAnimation,
            useGpuAcceleration: widget.useGpuAcceleration,
            progress: progress,
          );
          // 移除 alpha fallback：shader不可用时不再执行不透明度混合过渡
          return const SizedBox.expand();
        }

        // 始终使用shader绘制，保持坐标一致性
        // 如果是第一次显示且没有previous，使用淡入效果
        if (_previousImage == null && progress < 1.0) {
          return LayoutBuilder(
            builder: (context, constraints) {
              return Opacity(
                opacity: progress,
                child: CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _DissolveShaderPainter(
                    program: dissolveProgram!,
                    progress: 1.0, // shader内部progress=1.0，只显示toImage
                    fromImage: _currentImage!,
                    toImage: _currentImage!,
                    opacity: 1.0,
                  ),
                ),
              );
            },
          );
        }

        // 正常过渡或稳定显示
        final fromImage = _previousImage ?? _currentImage!;
        final toImage = _currentImage!;
        final dissolveProgress = _previousImage != null ? progress : 1.0;

        return LayoutBuilder(
          builder: (context, constraints) {
            return CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _DissolveShaderPainter(
                program: dissolveProgram!,
                progress: dissolveProgress,
                fromImage: fromImage,
                toImage: toImage,
                opacity: widget.isFadingOut ? (1.0 - progress) : 1.0,
              ),
            );
          },
        );
      },
    );

    // 应用动画变换（类似背景的实现）
    if (animProps != null) {
      cgWidget = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translate(
            (animProps['xcenter'] ?? 0.0) * screenSize.width,
            (animProps['ycenter'] ?? 0.0) * screenSize.height,
          )
          ..scale(animProps['scale'] ?? 1.0)
          ..rotateZ(animProps['rotation'] ?? 0.0),
        child: Opacity(
          opacity: (animProps['alpha'] ?? 1.0).clamp(0.0, 1.0),
          child: cgWidget,
        ),
      );
    }

    return cgWidget;
  }
}
