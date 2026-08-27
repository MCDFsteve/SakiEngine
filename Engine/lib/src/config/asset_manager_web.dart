import 'dart:convert';

import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/game/game_script_localization.dart';
import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';
import 'package:sakiengine/src/sks_compiler/compiled_sks_registry.dart';

class AssetManager {
  static final AssetManager _instance = AssetManager._internal();
  factory AssetManager() => _instance;
  AssetManager._internal() {
    // Web平台不需要初始化日志
    if (kEngineDebugMode) {
      print("AssetManager (Web): Using bundle assets only");
    }
  }

  Map<String, dynamic>? _assetManifest;
  final Map<String, String> _imageCache = {};

  // Web平台总是返回空字符串
  static String get _debugRoot => '';

  // Web平台总是返回空字符串，强制使用bundle模式
  static Future<String> _getGamePath() async => '';

  Future<String> loadString(String path) async {
    final candidates = GameScriptLocalization.resolveAssetPaths(path);
    Object? lastError;
    final compiledBundle = CompiledSksRegistry.instance.activeBundle;

    if (compiledBundle != null) {
      for (final candidate in candidates) {
        final precompiled = compiledBundle.loadText(candidate);
        if (precompiled != null) {
          return precompiled;
        }
      }
    }

    for (final candidate in candidates) {
      for (final bundleCandidate in _bundleCandidates(candidate)) {
        try {
          return await rootBundle.loadString(bundleCandidate, cache: false);
        } catch (e) {
          lastError = e;
        }
      }
    }

    throw Exception(
      'Failed to load asset from bundle. Tried: ${candidates.join(', ')}. Last error: $lastError',
    );
  }

  Map<String, dynamic> listToManifestMap(List<String> assets) {
    final Map<String, dynamic> manifest = {};

    for (final path in assets) {
      manifest[path] = [path];
    }

    return manifest;
  }

  Future<void> _loadManifest() async {
    if (_assetManifest != null) return;
    // final manifestJson = await rootBundle.loadString('AssetManifest.json');
    // _assetManifest = json.decode(manifestJson);
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    _assetManifest = listToManifestMap(assetManifest.listAssets());
  }

  Future<List<String>> listAssets(String directory, String extension) async {
    final assets = <String>[];
    final seen = <String>{};
    final candidates = GameScriptLocalization.resolveAssetDirectories(
      directory,
    );
    final resolvedDirectories = <String>[];
    final precompiledAssets = _listPrecompiledAssets(
      candidates: candidates,
      extension: extension,
    );
    if (precompiledAssets.isNotEmpty) {
      return precompiledAssets;
    }

    await _loadManifest();
    if (_assetManifest != null) {
      for (final candidate in candidates) {
        final currentAssets = <String>[];
        final candidatePrefixes = _bundleCandidates(candidate);

        for (final assetPath in _assetManifest!.keys) {
          for (final prefix in candidatePrefixes) {
            if (assetPath.startsWith(prefix) && assetPath.endsWith(extension)) {
              currentAssets.add(p.basename(assetPath));
              break;
            }
          }
        }

        if (currentAssets.isNotEmpty) {
          resolvedDirectories.add(candidate);
          for (final fileName in currentAssets) {
            if (seen.add(fileName)) {
              assets.add(fileName);
            }
          }
        }
      }
    }
    return assets;
  }

  List<String> _listPrecompiledAssets({
    required List<String> candidates,
    required String extension,
  }) {
    final bundle = CompiledSksRegistry.instance.activeBundle;
    if (bundle == null) {
      return const <String>[];
    }

    final assets = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      final normalized = CompiledSksBundle.normalizeAssetPath(candidate);
      final prefix = normalized.endsWith('/') ? normalized : '$normalized/';
      for (final assetPath in bundle.textAssetPaths) {
        if (assetPath.startsWith(prefix) && assetPath.endsWith(extension)) {
          final fileName = p.basename(assetPath);
          if (seen.add(fileName)) {
            assets.add(fileName);
          }
        }
      }
    }
    return assets;
  }

  List<String> _bundleCandidates(String path) {
    if (path.startsWith('assets/')) {
      final stripped = path.substring('assets/'.length);
      if (stripped == path) {
        return <String>[path];
      }
      // Web 上 rootBundle 通常会再加一层 assets/ 前缀，优先 stripped 可避免 assets/assets/* 404
      return <String>[stripped, path];
    }
    return <String>[path];
  }

  Iterable<String> _bundleAssetKeysByPriority() sync* {
    if (_assetManifest == null) {
      return;
    }
    for (final key in _assetManifest!.keys) {
      if (!key.startsWith('packages/')) {
        yield key;
      }
    }
    for (final key in _assetManifest!.keys) {
      if (key.startsWith('packages/')) {
        yield key;
      }
    }
  }

  String _normalizeAssetLookupName(String name) {
    var normalized = name.replaceAll('\\', '/').trim();
    if (normalized.startsWith('asset:///')) {
      normalized = normalized.substring('asset:///'.length);
    }
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    return normalized;
  }

  bool _isPreciseAssetLookup(String name) {
    final normalized = _normalizeAssetLookupName(name);
    return normalized.contains('/') && p.extension(normalized).isNotEmpty;
  }

  List<String> _exactAssetPathCandidates(String name) {
    final normalized = _normalizeAssetLookupName(name);
    if (normalized.isEmpty) {
      return const <String>[];
    }

    final candidates = <String>[];
    final seen = <String>{};
    void add(String value) {
      final candidate = _normalizeAssetLookupName(value);
      if (candidate.isNotEmpty && seen.add(candidate.toLowerCase())) {
        candidates.add(candidate);
      }
    }

    add(normalized);

    final lower = normalized.toLowerCase();
    if (lower.startsWith('assets/')) {
      final stripped = normalized.substring('assets/'.length);
      add(stripped);
      add('Assets/$stripped');
      add('Assets/images/$stripped');
    } else if (!lower.startsWith('packages/')) {
      add('Assets/$normalized');
      add('Assets/images/$normalized');
    }

    return candidates;
  }

  String? _findExactAssetInLoadedBundle(String name) {
    if (!_isPreciseAssetLookup(name)) {
      return null;
    }

    final candidates = _exactAssetPathCandidates(
      name,
    ).map((candidate) => candidate.toLowerCase()).toSet();
    for (final key in _bundleAssetKeysByPriority()) {
      final normalizedKey = key.replaceAll('\\', '/').toLowerCase();
      final keyWithoutBundleAssetsPrefix = normalizedKey.startsWith('assets/')
          ? normalizedKey.substring('assets/'.length)
          : normalizedKey;
      if (candidates.contains(normalizedKey) ||
          candidates.contains(keyWithoutBundleAssetsPrefix)) {
        _imageCache[name] = key;
        return key;
      }
      if (normalizedKey.startsWith('packages/') &&
          candidates.any(
            (candidate) => normalizedKey.endsWith('/$candidate'),
          )) {
        _imageCache[name] = key;
        return key;
      }
      if (normalizedKey.startsWith('assets/packages/') &&
          candidates.any(
            (candidate) => keyWithoutBundleAssetsPrefix.endsWith('/$candidate'),
          )) {
        _imageCache[name] = key;
        return key;
      }
    }

    return null;
  }

  Future<String?> findAsset(String name) async {
    if (_imageCache.containsKey(name)) {
      return _imageCache[name];
    }

    // Web平台总是使用bundle搜索
    return _findAssetInBundle(name);
  }

  Future<String?> findNativeMediaAsset(String name) {
    return findAsset(name);
  }

  Future<String?> _findAssetInBundle(String name) async {
    await _loadManifest();
    if (_assetManifest == null) {
      print("AssetManifest is null - cannot find assets");
      return null;
    }

    final exactMatch = _findExactAssetInLoadedBundle(name);
    if (exactMatch != null || _isPreciseAssetLookup(name)) {
      return exactMatch;
    }

    final imageExtensions = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.avif',
    ];
    final videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm'];
    final supportedExtensions = [...imageExtensions, ...videoExtensions];

    // 从查询名称中提取文件名，例如 "backgrounds/sky" -> "sky"
    final targetFileName = name.split('/').last;
    final targetFileNameLower = targetFileName.toLowerCase();
    final targetFileNameWithoutExt = p.basenameWithoutExtension(targetFileName);
    final targetFileNameWithoutExtLower = targetFileNameWithoutExt
        .toLowerCase();

    // 提取路径部分，例如 "backgrounds/sky" -> "backgrounds"
    final pathParts = name.split('/');
    final targetPath = pathParts.length > 1
        ? pathParts.sublist(0, pathParts.length - 1).join('/')
        : '';

    // 检测是否包含cg关键词（不区分大小写）
    final nameToCheck = name.toLowerCase();
    final fileNameToCheck = targetFileName.toLowerCase();
    final isCgRelated =
        nameToCheck.contains('cg') || fileNameToCheck.contains('cg');

    // 如果检测到cg关键词，优先在cg路径下搜索（支持递归子文件夹）
    if (isCgRelated) {
      for (final key in _bundleAssetKeysByPriority()) {
        final keyParts = key.split('/');
        final keyFileName = keyParts.last;
        final keyFileNameLower = keyFileName.toLowerCase();
        if (!supportedExtensions.any((ext) => keyFileNameLower.endsWith(ext))) {
          continue;
        }
        final keyFileNameWithoutExtLower = p
            .basenameWithoutExtension(keyFileName)
            .toLowerCase();
        final fileNameMatched =
            keyFileNameWithoutExtLower == targetFileNameWithoutExtLower ||
            keyFileNameLower == targetFileNameLower;

        // 检查文件名是否匹配且路径包含cg（支持cg的任意子文件夹）
        if (fileNameMatched) {
          final keyPath = key.toLowerCase();
          // 更精确的cg路径检测：支持 /cg/ 或 /cg/任意子目录/
          if (keyPath.contains('/cg/') ||
              keyPath.startsWith('cg/') ||
              keyPath.contains('assets/images/cg/')) {
            _imageCache[name] = key;
            return key;
          }
        }
      }
    }

    // 1. 精确匹配：路径和文件名都要匹配
    for (final key in _bundleAssetKeysByPriority()) {
      final keyParts = key.split('/');
      final keyFileName = keyParts.last;
      final keyFileNameLower = keyFileName.toLowerCase();
      if (!supportedExtensions.any((ext) => keyFileNameLower.endsWith(ext))) {
        continue;
      }
      final keyFileNameWithoutExtLower = p
          .basenameWithoutExtension(keyFileName)
          .toLowerCase();
      final fileNameMatched =
          keyFileNameWithoutExtLower == targetFileNameWithoutExtLower ||
          keyFileNameLower == targetFileNameLower;

      // 检查文件名是否匹配
      if (fileNameMatched) {
        // 如果查询有路径要求，检查路径是否匹配
        if (targetPath.isNotEmpty) {
          final keyPath = key.toLowerCase();
          if (keyPath.contains('/${targetPath.toLowerCase()}/') ||
              keyPath.contains('${targetPath.toLowerCase()}/')) {
            _imageCache[name] = key;
            //print("Found asset in bundle (path + name match): $name -> $key");
            return key;
          }
        } else {
          // 没有路径要求，直接匹配文件名
          _imageCache[name] = key;
          //print("Found asset in bundle (name match): $name -> $key");
          return key;
        }
      }
    }

    // 2. 宽松匹配：只匹配文件名，忽略路径
    for (final key in _bundleAssetKeysByPriority()) {
      final keyParts = key.split('/');
      final keyFileName = keyParts.last;
      final keyFileNameLower = keyFileName.toLowerCase();
      if (!supportedExtensions.any((ext) => keyFileNameLower.endsWith(ext))) {
        continue;
      }
      final keyFileNameWithoutExtLower = p
          .basenameWithoutExtension(keyFileName)
          .toLowerCase();
      final fileNameMatched =
          keyFileNameWithoutExtLower == targetFileNameWithoutExtLower ||
          keyFileNameLower == targetFileNameLower;

      if (fileNameMatched) {
        _imageCache[name] = key;
        //print("Found asset in bundle (fallback name match): $name -> $key");
        return key;
      }
    }

    return null;
  }

  /// Web平台返回空列表
  static Future<List<String>> getAvailableCharacterLayersRecursive(
    String characterId,
  ) async {
    return <String>[];
  }

  /// Web平台返回空列表
  static Future<List<String>> getAvailableCharacterLayers(
    String characterId,
  ) async {
    return <String>[];
  }

  /// Web平台返回null
  static Future<String?> getDefaultLayerForLevel(
    String characterId,
    int layerLevel,
  ) async {
    return null;
  }
}
