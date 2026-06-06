import 'dart:convert';
import 'dart:io';

import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/game/game_script_localization.dart';
import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';
import 'package:sakiengine/src/sks_compiler/compiled_sks_registry.dart';
import 'package:sakiengine/src/config/saki_pack_store.dart';

class AssetManager {
  static const bool _forceAssetDiagnostics =
      bool.fromEnvironment('SAKI_ASSET_DIAG', defaultValue: false);

  static final AssetManager _instance = AssetManager._internal();
  factory AssetManager() => _instance;
  AssetManager._internal() {
    // Print the CWD at initialization
    if (_shouldLoadFromExternal()) {
      print("AssetManager CWD: ${Directory.current.path}");
      print(
          "Game path hint: ${GamePathResolver.configuredGamePathHint() ?? ''}");
    }
    _assetDiag(
      'AssetManager 初始化: mode=${kEngineDebugMode ? "debug" : "release"}, '
      'cwd=${Directory.current.path}, external=${_shouldLoadFromExternal()}',
    );
  }

  Map<String, dynamic>? _assetManifest;
  final Map<String, String> _imageCache = {};
  bool _manifestDiagPrinted = false;
  int _findAssetDiagCount = 0;
  int _findAssetMissDiagCount = 0;

  // 检查是否应该从外部加载资源（仅桌面平台的Debug模式）
  static bool _shouldLoadFromExternal() {
    return GamePathResolver.shouldUseFileSystemAssets;
  }

  static bool _shouldAssetDiagnostics() {
    if (kEngineDebugMode) {
      return false;
    }
    return _forceAssetDiagnostics &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }

  static void _assetDiag(String message) {
    if (!_shouldAssetDiagnostics()) {
      return;
    }
    final now = DateTime.now().toIso8601String();
    stderr.writeln('[SAKI_ASSET_DIAG][$now] $message');
  }

  // 获取游戏路径，统一由 GamePathResolver 解析
  static Future<String> _getGamePath() async {
    final gamePath = await GamePathResolver.resolveGamePath();
    if (gamePath == null || gamePath.isEmpty) {
      return '';
    }
    return gamePath;
  }

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

    final packStore = SakiPackStore.instance;
    if (await packStore.ensureInitialized()) {
      for (final candidate in candidates) {
        final normalized = GameScriptLocalization.stripAssetsPrefix(candidate);
        final fromPack = await packStore.loadText(normalized);
        if (fromPack != null) {
          return fromPack;
        }
      }
    }

    if (_shouldLoadFromExternal()) {
      final gamePath = await _getGamePath();
      if (gamePath.isEmpty) {
        throw Exception(
            'Game path is not defined. Please set SAKI_GAME_PATH environment variable or create default_game.txt');
      }

      for (final candidate in candidates) {
        final assetPath = GameScriptLocalization.stripAssetsPrefix(candidate);
        final fileSystemPath = p.normalize(p.join(gamePath, assetPath));

        try {
          return await File(fileSystemPath).readAsString();
        } catch (e) {
          lastError = e;
          if (_shouldLoadFromExternal()) {
            print(
                '[AssetManager] Failed to load $fileSystemPath, trying fallback if available. Error: $e');
          }
        }
      }

      throw Exception(
          'Failed to load asset from file system. Tried: ${candidates.join(', ')}. Last error: $lastError');
    } else {
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
          'Failed to load asset from bundle. Tried: ${candidates.join(', ')}. Last error: $lastError');
    }
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
    // https://docs.flutter.dev/release/breaking-changes/asset-manifest-dot-json
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    _assetManifest = listToManifestMap(assetManifest.listAssets());

    if (!_manifestDiagPrinted && _assetManifest != null) {
      _manifestDiagPrinted = true;
      final keys = _assetManifest!.keys.toList(growable: false);
      final total = keys.length;
      final projectAssets =
          keys.where((key) => key.startsWith('Assets/')).length;
      final imageAssets = keys
          .where((key) => key.toLowerCase().contains('assets/images/'))
          .length;
      final scriptAssets = keys
          .where((key) =>
              key.startsWith('GameScript') &&
              key.toLowerCase().endsWith('.sks'))
          .length;
      _assetDiag(
        'AssetManifest 已加载: total=$total, projectAssets=$projectAssets, '
        'imageAssets=$imageAssets, sksAssets=$scriptAssets',
      );
      if (imageAssets == 0) {
        final preview = keys.take(40).join(', ');
        _assetDiag('AssetManifest 前40项: $preview');
      }
    }
  }

  Future<List<String>> listAssets(String directory, String extension) async {
    final assets = <String>[];
    final seen = <String>{};
    final candidates =
        GameScriptLocalization.resolveAssetDirectories(directory);
    final resolvedDirectories = <String>[];
    final precompiledAssets =
        _listPrecompiledAssets(candidates: candidates, extension: extension);
    if (precompiledAssets.isNotEmpty) {
      return precompiledAssets;
    }

    final packStore = SakiPackStore.instance;
    if (await packStore.ensureInitialized()) {
      final fromPack = <String>[];
      final seenPack = <String>{};
      for (final candidate in candidates) {
        final normalized = GameScriptLocalization.stripAssetsPrefix(candidate);
        for (final fileName in packStore.listFileNames(normalized, extension)) {
          if (seenPack.add(fileName)) {
            fromPack.add(fileName);
          }
        }
      }
      if (fromPack.isNotEmpty) {
        return fromPack;
      }
    }

    if (_shouldLoadFromExternal()) {
      final gamePath = await _getGamePath();
      if (gamePath.isEmpty) {
        print('Game path is not set, cannot list assets from file system.');
        return assets;
      }

      for (final candidate in candidates) {
        final assetPath = GameScriptLocalization.stripAssetsPrefix(candidate);
        final dirPath = p.join(gamePath, assetPath);
        final dir = Directory(dirPath);
        final currentAssets = <String>[];

        if (await dir.exists()) {
          await for (final file in dir.list()) {
            if (file is File && file.path.endsWith(extension)) {
              currentAssets.add(p.basename(file.path));
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
    } else {
      await _loadManifest();
      if (_assetManifest != null) {
        for (final candidate in candidates) {
          final currentAssets = <String>[];
          final candidatePrefixes = _bundleCandidates(candidate);

          for (final assetPath in _assetManifest!.keys) {
            for (final prefix in candidatePrefixes) {
              if (assetPath.startsWith(prefix) &&
                  assetPath.endsWith(extension)) {
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
      // rootBundle.loadString 在部分平台会自动追加 assets/ 前缀，
      // 优先 stripped 可以避免 assets/assets/* 的无效请求。
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

    final candidates = _exactAssetPathCandidates(name)
        .map((candidate) => candidate.toLowerCase())
        .toSet();
    for (final key in _bundleAssetKeysByPriority()) {
      final normalizedKey = key.replaceAll('\\', '/').toLowerCase();
      if (candidates.contains(normalizedKey)) {
        _imageCache[name] = key;
        return key;
      }
      if (normalizedKey.startsWith('packages/') &&
          candidates
              .any((candidate) => normalizedKey.endsWith('/$candidate'))) {
        _imageCache[name] = key;
        return key;
      }
    }

    return null;
  }

  Future<String?> findAsset(String name) async {
    if (_imageCache.containsKey(name)) {
      if (_findAssetDiagCount < 200) {
        _findAssetDiagCount++;
        _assetDiag('findAsset 缓存命中: "$name" -> "${_imageCache[name]}"');
      }
      return _imageCache[name];
    }

    String? result;
    if (_shouldLoadFromExternal()) {
      result = await _findAssetInFileSystem(name);
    } else {
      result = await _findAssetInBundle(name);
    }

    if (result != null) {
      if (_findAssetDiagCount < 200) {
        _findAssetDiagCount++;
        _assetDiag('findAsset 命中: "$name" -> "$result"');
      }
      return result;
    }

    final packStore = SakiPackStore.instance;
    if (await packStore.ensureInitialized()) {
      String? resolvedVirtual;
      if (_isPreciseAssetLookup(name)) {
        for (final candidate in _exactAssetPathCandidates(name)) {
          if (packStore.contains(candidate)) {
            resolvedVirtual = candidate;
            break;
          }
        }
      } else {
        resolvedVirtual = packStore.resolveVirtualAssetPath(name);
      }
      if (resolvedVirtual != null) {
        final materialized =
            await packStore.materializeFilePath(resolvedVirtual);
        if (materialized != null) {
          _imageCache[name] = materialized;
          return materialized;
        } else {
          _imageCache[name] = resolvedVirtual;
          return resolvedVirtual;
        }
      }
    }

    if (_findAssetMissDiagCount < 200) {
      _findAssetMissDiagCount++;
      _assetDiag('findAsset 未命中: "$name"');
    }

    return null;
  }

  Future<String?> _findAssetInBundle(String name) async {
    await _loadManifest();
    if (_assetManifest == null) {
      print("AssetManifest is null - cannot find assets");
      _assetDiag('AssetManifest 为 null，无法查找 "$name"');
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
      '.svg'
    ];
    final videoExtensions = [
      '.mp4',
      '.mov',
      '.avi',
      '.mkv',
      '.webm'
    ]; // 新增：视频扩展名
    final supportedExtensions = [
      ...imageExtensions,
      ...videoExtensions
    ]; // 合并支持的扩展名

    // 从查询名称中提取文件名，例如 "backgrounds/sky" -> "sky"
    final targetFileName = name.split('/').last;
    final targetFileNameLower = targetFileName.toLowerCase();
    final targetFileNameWithoutExt = p.basenameWithoutExtension(targetFileName);
    final targetFileNameWithoutExtLower =
        targetFileNameWithoutExt.toLowerCase();

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
        final keyFileNameWithoutExtLower =
            p.basenameWithoutExtension(keyFileName).toLowerCase();
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
      final keyFileNameWithoutExtLower =
          p.basenameWithoutExtension(keyFileName).toLowerCase();

      // 检查文件名是否匹配
      final fileNameMatched =
          keyFileNameWithoutExtLower == targetFileNameWithoutExtLower ||
              keyFileNameLower == targetFileNameLower;
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
      final keyFileNameWithoutExtLower =
          p.basenameWithoutExtension(keyFileName).toLowerCase();
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

  Future<String?> _findAssetInFileSystem(String name) async {
    final gamePath = await _getGamePath();
    if (gamePath.isEmpty) {
      print("Game path is not set, cannot find assets in file system.");
      _assetDiag('文件系统查找失败: gamePath 为空, name="$name"');
      return null;
    }

    // 从资源名中提取文件名用于搜索，例如 "backgrounds/bg-school" -> "bg-school"
    final fileNameToSearch = name.split('/').last;
    final fileNameToSearchLower = fileNameToSearch.toLowerCase();
    final fileNameToSearchWithoutExtLower =
        p.basenameWithoutExtension(fileNameToSearch).toLowerCase();
    final normalizedName = name.replaceAll('\\', '/');
    final normalizedNameLower = normalizedName.toLowerCase();

    final searchBase = p.join(gamePath, 'Assets', 'images');

    // 检测是否包含cg关键词（不区分大小写）
    final nameToCheck = name.toLowerCase();
    final fileNameToCheck = fileNameToSearch.toLowerCase();
    final isCgRelated =
        nameToCheck.contains('cg') || fileNameToCheck.contains('cg');

    // 如果检测到cg关键词，优先从cg文件夹搜索
    final searchPaths = <String>[];
    if (isCgRelated) {
      searchPaths.add(p.join(searchBase, 'cg'));
    }

    // 添加其他常规搜索路径
    searchPaths.addAll([
      p.join(searchBase, 'backgrounds'),
      p.join(searchBase, 'characters'),
      p.join(searchBase, 'items'),
      p.join(gamePath, 'Assets', 'gui'),
      p.join(gamePath, 'Assets', 'movies'), // 新增：视频文件搜索路径
    ]);

    if (_isPreciseAssetLookup(name)) {
      for (final exactPath in _exactAssetPathCandidates(name)) {
        final candidate = p.join(gamePath, exactPath);
        final file = File(candidate);
        if (await file.exists()) {
          final assetPath = file.path.replaceAll('\\', '/');
          _imageCache[name] = assetPath;
          return assetPath;
        }
      }
      return null;
    }

    String? fallbackMatch;
    String? pathMatchedFallback;

    for (final dirPath in searchPaths) {
      final directory = Directory(dirPath);
      if (await directory.exists()) {
        await for (final file in directory.list(recursive: true)) {
          if (file is! File) continue;

          final fileName = p.basename(file.path);
          final fileNameLower = fileName.toLowerCase();
          final fileNameWithoutExtLower =
              p.basenameWithoutExtension(fileName).toLowerCase();
          final fileNameMatched =
              fileNameWithoutExtLower == fileNameToSearchWithoutExtLower ||
                  fileNameLower == fileNameToSearchLower;

          if (!fileNameMatched) continue;

          final assetPath = file.path.replaceAll('\\', '/');
          fallbackMatch ??= assetPath;

          // 2) 路径约束匹配：在同名情况下，优先命中包含目标路径片段的资源
          final lowerAssetPath = assetPath.toLowerCase();
          if (normalizedNameLower.contains('/')) {
            if (lowerAssetPath.contains('/assets/$normalizedNameLower') ||
                lowerAssetPath
                    .contains('/assets/images/$normalizedNameLower')) {
              pathMatchedFallback = assetPath;
              break;
            }
          } else {
            pathMatchedFallback = assetPath;
            break;
          }
        }

        if (pathMatchedFallback != null) {
          break;
        }
      }
    }

    final resolved = pathMatchedFallback ?? fallbackMatch;
    if (resolved != null) {
      _imageCache[name] = resolved;
      return resolved;
    }

    return null;
  }

  /// 递归扫描指定角色ID的所有可用图层文件
  /// 使用与findAsset相同的递归搜索逻辑
  static Future<List<String>> getAvailableCharacterLayersRecursive(
      String characterId) async {
    final availableLayers = <String>[];

    final packStore = SakiPackStore.instance;
    if (await packStore.ensureInitialized()) {
      final prefix = '$characterId-';
      final imageExtensions = ['.png', '.jpg', '.jpeg', '.webp', '.avif'];
      final fromPack = packStore.listFileNames('Assets/images/characters', '');
      for (final fileName in fromPack) {
        final fileNameLower = fileName.toLowerCase();
        final fileNameWithoutExt = p.basenameWithoutExtension(fileName);
        if (!imageExtensions.any((ext) => fileNameLower.endsWith(ext))) {
          continue;
        }
        if (!fileNameWithoutExt.startsWith(prefix)) {
          continue;
        }
        final layerName = fileNameWithoutExt.substring(prefix.length);
        if (layerName.isNotEmpty) {
          availableLayers.add(layerName);
        }
      }
      if (availableLayers.isNotEmpty) {
        availableLayers.sort();
        return availableLayers;
      }
    }

    try {
      final gamePath = await _getGamePath();
      if (gamePath.isEmpty) {
        return availableLayers;
      }

      final searchBase = p.join(gamePath, 'Assets', 'images');
      final charactersDir = Directory(p.join(searchBase, 'characters'));

      if (!await charactersDir.exists()) {
        return availableLayers;
      }

      final prefix = '$characterId-';
      final imageExtensions = ['.png', '.jpg', '.jpeg', '.webp', '.avif'];

      // 使用递归搜索，和findAsset一样
      await for (final file in charactersDir.list(recursive: true)) {
        if (file is File) {
          final fileName = p.basename(file.path);
          final fileNameWithoutExt = p.basenameWithoutExtension(fileName);

          // 检查是否以指定角色ID开头且是图片文件
          if (fileNameWithoutExt.startsWith(prefix) &&
              imageExtensions
                  .any((ext) => fileName.toLowerCase().endsWith(ext))) {
            // 提取图层名称（去掉角色ID前缀）
            final layerName = fileNameWithoutExt.substring(prefix.length);
            if (layerName.isNotEmpty) {
              availableLayers.add(layerName);
            }
          }
        }
      }

      // 按字母顺序排序
      availableLayers.sort();
    } catch (e) {
      if (_shouldLoadFromExternal()) {
        print("AssetManager: 递归扫描角色图层出错 $characterId: $e");
      }
    }

    return availableLayers;
  }

  /// 扫描指定角色ID的所有可用图层文件
  /// 返回按字母顺序排序的文件名列表（不包含扩展名和角色ID前缀）
  static Future<List<String>> getAvailableCharacterLayers(
      String characterId) async {
    final availableLayers = <String>[];

    final packStore = SakiPackStore.instance;
    if (await packStore.ensureInitialized()) {
      final prefix = '$characterId-';
      final imageExtensions = ['.png', '.jpg', '.jpeg', '.webp', '.avif'];
      final fromPack = packStore.listFileNames('Assets/images/characters', '');
      for (final fileName in fromPack) {
        final fileNameLower = fileName.toLowerCase();
        final fileNameWithoutExt = p.basenameWithoutExtension(fileName);
        if (!imageExtensions.any((ext) => fileNameLower.endsWith(ext))) {
          continue;
        }
        if (!fileNameWithoutExt.startsWith(prefix)) {
          continue;
        }
        final layerName = fileNameWithoutExt.substring(prefix.length);
        if (layerName.isNotEmpty) {
          availableLayers.add(layerName);
        }
      }
      if (availableLayers.isNotEmpty) {
        availableLayers.sort();
        return availableLayers;
      }
    }

    try {
      final gamePath = await _getGamePath();
      final charactersDir =
          Directory(p.join(gamePath, 'Assets', 'images', 'characters'));
      if (!await charactersDir.exists()) {
        return availableLayers;
      }

      final prefix = '$characterId-';
      final imageExtensions = ['.png', '.jpg', '.jpeg', '.webp', '.avif'];
      var fileCount = 0;
      await for (final file in charactersDir.list()) {
        if (file is File) {
          final fileName = p.basename(file.path);
          fileCount++;
          final fileNameWithoutExt = p.basenameWithoutExtension(fileName);

          // 检查是否以指定角色ID开头且是图片文件
          if (fileNameWithoutExt.startsWith(prefix) &&
              imageExtensions
                  .any((ext) => fileName.toLowerCase().endsWith(ext))) {
            // 提取图层名称（去掉角色ID前缀）
            final layerName = fileNameWithoutExt.substring(prefix.length);
            if (layerName.isNotEmpty) {
              availableLayers.add(layerName);
            }
          }
        }
      }
      // 按字母顺序排序
      availableLayers.sort();
    } catch (e) {
      if (_shouldLoadFromExternal()) {
        print("AssetManager: 扫描角色图层出错 $characterId: $e");
      }
    }

    return availableLayers;
  }

  /// 获取指定角色ID和图层级别的默认图层名称
  /// 返回该级别下按字母顺序第一个可用的图层
  static Future<String?> getDefaultLayerForLevel(
      String characterId, int layerLevel) async {
    final availableLayers = await getAvailableCharacterLayers(characterId);

    // 筛选出指定级别的图层
    final layersForLevel = availableLayers.where((layer) {
      // 解析图层级别
      int dashCount = 0;
      for (int i = 0; i < layer.length; i++) {
        if (layer[i] == '-') {
          dashCount++;
        } else {
          break;
        }
      }

      int currentLayerLevel;
      if (dashCount == 0) {
        currentLayerLevel = 1; // 无"-"，作为基础表情
      } else if (dashCount == 1) {
        currentLayerLevel = 1; // 单"-"，保持兼容
      } else {
        currentLayerLevel = dashCount; // 多"-"，按数量确定层级
      }

      return currentLayerLevel == layerLevel;
    }).toList();

    // 提取实际的图层名称（去掉前缀"-"）
    if (layersForLevel.isNotEmpty) {
      String firstLayer = layersForLevel.first;

      // 提取实际名称
      int dashCount = 0;
      for (int i = 0; i < firstLayer.length; i++) {
        if (firstLayer[i] == '-') {
          dashCount++;
        } else {
          break;
        }
      }

      return dashCount > 0 ? firstLayer.substring(dashCount) : firstLayer;
    }

    return null;
  }
}
