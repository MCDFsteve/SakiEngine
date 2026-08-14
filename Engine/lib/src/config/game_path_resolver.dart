import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/config/runtime_project_config.dart';
import 'package:sakiengine/src/utils/engine_asset_loader.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';

/// 统一解析游戏根目录（`Game/<project>`）。
///
/// 演出模式与桌面调试都需要从文件系统直读资源与脚本，
/// 但发布包运行时的 CWD 经常不稳定，因此这里统一做多路径探测。
class GamePathResolver {
  static const int _cwdProbeDepth = 6;
  static const int _exeProbeDepth = 8;
  static const String _showcaseRelativeGameDirDefine = String.fromEnvironment(
    'SAKI_SHOWCASE_GAME_DIR',
    defaultValue: '',
  );

  static String? _cachedGamePath;
  static String? _cachedProjectName;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static bool get shouldUseFileSystemAssets => kEngineDebugMode && _isDesktop;

  static void clearCache() {
    _cachedGamePath = null;
    _cachedProjectName = null;
  }

  static String? configuredGamePathHint() {
    final runtimePath = RuntimeProjectConfigStore().config.gamePath;
    if (_isNotEmpty(runtimePath)) {
      return runtimePath!.trim();
    }

    const fromDefine = String.fromEnvironment(
      'SAKI_GAME_PATH',
      defaultValue: '',
    );
    if (fromDefine.isNotEmpty) {
      return fromDefine;
    }

    final fromEnv = _readEnvironment('SAKI_GAME_PATH');
    if (_isNotEmpty(fromEnv)) {
      return fromEnv!.trim();
    }
    return null;
  }

  static Future<String?> resolveProjectName() async {
    if (_isNotEmpty(_cachedProjectName)) {
      return _cachedProjectName;
    }

    final runtimeConfig = RuntimeProjectConfigStore().config;
    final candidates = <String>[];
    final seen = <String>{};

    void addCandidate(String? value) {
      final normalized = _normalizeName(value);
      if (normalized == null) {
        return;
      }
      if (seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    addCandidate(runtimeConfig.projectName);
    addCandidate(_basenameSafe(runtimeConfig.gamePath));
    addCandidate(_basenameSafe(const String.fromEnvironment('SAKI_GAME_PATH')));
    addCandidate(_basenameSafe(_readEnvironment('SAKI_GAME_PATH')));

    // Explicit runtime configuration always has higher priority than discovery.
    // Returning here avoids probing the filesystem and loading bundled assets
    // every time a cold subsystem (for example the save browser) asks for the
    // project-specific data directory.
    if (candidates.isNotEmpty) {
      _cachedProjectName = candidates.first;
      return _cachedProjectName;
    }

    final localDefault = await _resolveLocalDefaultGameName();
    addCandidate(localDefault);

    final bundledDefault = await _resolveBundledDefaultGameName();
    addCandidate(bundledDefault);

    if (candidates.isEmpty) {
      return null;
    }
    _cachedProjectName = candidates.first;
    return _cachedProjectName;
  }

  static Future<String?> resolveGamePath() async {
    if (!shouldUseFileSystemAssets) {
      return null;
    }

    final cached = _cachedGamePath;
    if (_isNotEmpty(cached)) {
      final normalizedCached = await _normalizeGameRoot(cached!);
      if (normalizedCached != null) {
        return normalizedCached;
      }
    }

    final projectCandidates = <String>[];
    final projectName = await resolveProjectName();
    if (_isNotEmpty(projectName)) {
      projectCandidates.add(projectName!);
    }

    final showcasePackagedPath = await _resolveShowcasePackagedGamePath(
      projectCandidates,
    );
    if (showcasePackagedPath != null) {
      _cachedGamePath = showcasePackagedPath;
      if (_isNotEmpty(_cachedProjectName) == false) {
        _cachedProjectName = p.basename(showcasePackagedPath);
      }
      return showcasePackagedPath;
    }

    final seedPaths = _collectProbeBaseDirectories();
    final searchSeeds = <String>[];
    final seenSeeds = <String>{};

    void addSeed(String? value) {
      final normalized = _normalizePath(value);
      if (normalized == null) {
        return;
      }
      if (seenSeeds.add(normalized)) {
        searchSeeds.add(normalized);
      }
    }

    addSeed(RuntimeProjectConfigStore().config.gamePath);
    addSeed(const String.fromEnvironment('SAKI_GAME_PATH', defaultValue: ''));
    addSeed(_readEnvironment('SAKI_GAME_PATH'));
    for (final base in seedPaths) {
      addSeed(base);
    }

    for (final seed in searchSeeds) {
      final resolved = await _resolveFromSeed(seed, projectCandidates);
      if (resolved != null) {
        _cachedGamePath = resolved;
        if (_isNotEmpty(_cachedProjectName) == false) {
          _cachedProjectName = p.basename(resolved);
        }
        return resolved;
      }
    }

    return null;
  }

  static Future<String?> _resolveShowcasePackagedGamePath(
    List<String> projectCandidates,
  ) async {
    if (!kSakiShowMode || !_isNotEmpty(_showcaseRelativeGameDirDefine)) {
      return null;
    }

    final relativePath = _showcaseRelativeGameDirDefine.trim();
    if (p.isAbsolute(relativePath)) {
      return _normalizeGameRoot(relativePath);
    }

    final executableBases = _collectExecutableProbeDirectories();
    final seenCandidates = <String>{};
    final candidates = <String>[];

    void addCandidate(String value) {
      final normalized = _normalizePath(value);
      if (normalized == null) {
        return;
      }
      if (seenCandidates.add(normalized)) {
        candidates.add(normalized);
      }
    }

    for (final base in executableBases) {
      addCandidate(p.join(base, relativePath));
      for (final project in projectCandidates) {
        addCandidate(p.join(base, 'Game', project));
      }
    }

    for (final candidate in candidates) {
      final resolved = await _normalizeGameRoot(candidate);
      if (resolved != null) {
        return resolved;
      }
    }
    return null;
  }

  static Future<String?> _resolveFromSeed(
    String seed,
    List<String> projectCandidates,
  ) async {
    String seedDir = seed;
    final seedFile = File(seed);
    if (await seedFile.exists()) {
      seedDir = p.dirname(seed);
    }

    final direct = await _normalizeGameRoot(seedDir);
    if (direct != null) {
      return direct;
    }

    final candidatePaths = <String>[];
    final seen = <String>{};

    void addCandidate(String? value) {
      final normalized = _normalizePath(value);
      if (normalized == null) {
        return;
      }
      if (seen.add(normalized)) {
        candidatePaths.add(normalized);
      }
    }

    for (final project in projectCandidates) {
      addCandidate(p.join(seedDir, 'Game', project));
      addCandidate(p.join(seedDir, project));
      addCandidate(p.join(seedDir, 'Resources', 'Game', project));
      addCandidate(p.join(seedDir, 'Contents', 'Resources', 'Game', project));
    }

    for (final candidate in candidatePaths) {
      final normalized = await _normalizeGameRoot(candidate);
      if (normalized != null) {
        return normalized;
      }
    }

    final discoveryRoots = <String>[
      p.join(seedDir, 'Game'),
      p.join(seedDir, 'Resources', 'Game'),
      p.join(seedDir, 'Contents', 'Resources', 'Game'),
    ];
    if (_basenameLower(seedDir) == 'game') {
      discoveryRoots.insert(0, seedDir);
    }

    for (final discoveryRoot in discoveryRoots) {
      final discovered = await _findGameRootInDirectory(
        discoveryRoot,
        projectCandidates,
      );
      if (discovered != null) {
        return discovered;
      }
    }

    return null;
  }

  static String? _readEnvironment(String key) {
    if (kIsWeb) {
      return null;
    }
    return Platform.environment[key];
  }

  static Future<String?> _findGameRootInDirectory(
    String directoryPath,
    List<String> projectCandidates,
  ) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) {
      return null;
    }

    for (final project in projectCandidates) {
      final candidate = await _normalizeGameRoot(
        p.join(directoryPath, project),
      );
      if (candidate != null) {
        return candidate;
      }
    }

    try {
      final entities = await dir.list(followLinks: false).toList();
      final children = entities.whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final child in children) {
        final normalized = await _normalizeGameRoot(child.path);
        if (normalized != null) {
          return normalized;
        }
      }
    } catch (_) {
      // 忽略目录读取异常
    }

    return null;
  }

  static Future<String?> _normalizeGameRoot(String rawPath) async {
    final normalized = _normalizePath(rawPath);
    if (normalized == null) {
      return null;
    }
    if (await _looksLikeGameRoot(normalized)) {
      return normalized;
    }
    return null;
  }

  static Future<bool> _looksLikeGameRoot(String path) async {
    final rootDir = Directory(path);
    if (!await rootDir.exists()) {
      return false;
    }

    final hasAssets = await Directory(p.join(path, 'Assets')).exists();
    final hasGameConfig = await File(p.join(path, 'game_config.txt')).exists();
    final hasScriptDirectory = await _hasScriptDirectory(rootDir);

    return (hasAssets && hasScriptDirectory) ||
        (hasAssets && hasGameConfig) ||
        (hasScriptDirectory && hasGameConfig);
  }

  static Future<bool> _hasScriptDirectory(Directory rootDir) async {
    try {
      await for (final entity in rootDir.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        final name = p.basename(entity.path);
        if (name == 'GameScript' || name.startsWith('GameScript_')) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static List<String> _collectProbeBaseDirectories() {
    final bases = <String>[];
    final seen = <String>{};

    void addBase(String? value) {
      final normalized = _normalizePath(value);
      if (normalized == null) {
        return;
      }
      if (seen.add(normalized)) {
        bases.add(normalized);
      }
    }

    void addParentChain(String? start, int depth) {
      final startPath = _normalizePath(start);
      if (startPath == null) {
        return;
      }
      var current = startPath;

      for (var i = 0; i <= depth; i++) {
        addBase(current);
        final parent = p.dirname(current);
        if (parent == current) {
          break;
        }
        current = parent;
      }
    }

    // 优先可执行文件附近目录，避免演出模式误回退到源码工作目录。
    for (final base in _collectExecutableProbeDirectories()) {
      addBase(base);
    }
    for (final base in _collectCwdProbeDirectories()) {
      addBase(base);
    }

    return bases;
  }

  static List<String> _collectExecutableProbeDirectories() {
    final bases = <String>[];
    void addParentChain(String? start, int depth) {
      final startPath = _normalizePath(start);
      if (startPath == null) {
        return;
      }
      var current = startPath;
      for (var i = 0; i <= depth; i++) {
        bases.add(current);
        final parent = p.dirname(current);
        if (parent == current) {
          break;
        }
        current = parent;
      }
    }

    try {
      addParentChain(p.dirname(Platform.resolvedExecutable), _exeProbeDepth);
    } catch (_) {
      // 某些平台/测试环境下可能不可用
    }
    return bases;
  }

  static List<String> _collectCwdProbeDirectories() {
    final bases = <String>[];
    void addParentChain(String? start, int depth) {
      final startPath = _normalizePath(start);
      if (startPath == null) {
        return;
      }
      var current = startPath;
      for (var i = 0; i <= depth; i++) {
        bases.add(current);
        final parent = p.dirname(current);
        if (parent == current) {
          break;
        }
        current = parent;
      }
    }

    addParentChain(Directory.current.path, _cwdProbeDepth);
    return bases;
  }

  static Future<String?> _resolveLocalDefaultGameName() async {
    for (final base in _collectProbeBaseDirectories()) {
      final file = File(p.join(base, 'default_game.txt'));
      if (!await file.exists()) {
        continue;
      }
      try {
        final content = (await file.readAsString()).trim();
        if (content.isNotEmpty) {
          return content;
        }
      } catch (_) {
        // 忽略读取失败
      }
    }
    return null;
  }

  static Future<String?> _resolveBundledDefaultGameName() async {
    final candidates = <String>['assets/default_game.txt', 'default_game.txt'];
    for (final assetPath in candidates) {
      try {
        final content = (await EngineAssetLoader.loadString(assetPath)).trim();
        if (content.isNotEmpty) {
          return content;
        }
      } catch (_) {
        // 尝试下一候选路径
      }
    }
    return null;
  }

  static String? _normalizePath(String? value) {
    if (!_isNotEmpty(value)) {
      return null;
    }

    var path = value!.trim();
    if ((path.startsWith('"') && path.endsWith('"')) ||
        (path.startsWith("'") && path.endsWith("'"))) {
      path = path.substring(1, path.length - 1).trim();
    }
    if (path.isEmpty) {
      return null;
    }

    return p.normalize(p.absolute(path));
  }

  static String? _basenameSafe(String? path) {
    if (!_isNotEmpty(path)) {
      return null;
    }
    return _normalizeName(p.basename(path!.trim()));
  }

  static String? _normalizeName(String? value) {
    if (!_isNotEmpty(value)) {
      return null;
    }
    final normalized = value!.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  static String _basenameLower(String path) {
    return p.basename(path).toLowerCase();
  }

  static bool _isNotEmpty(String? value) {
    return value != null && value.trim().isNotEmpty;
  }
}
