import 'dart:io';

import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/utils/local_storage_paths.dart';

/// 管理 CG 预合成结果的磁盘缓存目录
class CgCacheStorage {
  static final CgCacheStorage _instance = CgCacheStorage._internal();
  factory CgCacheStorage() => _instance;
  CgCacheStorage._internal();

  Directory? _cacheDirectory;

  /// 默认缓存文件最大数量，超过后按最旧文件淘汰
  static const int _defaultMaxEntries = 400;

  Future<String> getCacheDirectory() async {
    if (kIsWeb) {
      return '';
    }

    if (_cacheDirectory != null) {
      final exists = await _cacheDirectory!.exists();
      if (exists) {
        return _cacheDirectory!.path;
      }
    }

    final projectName = await _resolveProjectName();
    final baseDir = await LocalStoragePaths.projectCacheDirectory(projectName);
    final cacheDir = Directory(p.join(baseDir.path, '.cg_cache'));

    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    _cacheDirectory = cacheDir;
    return cacheDir.path;
  }

  Future<String> _resolveProjectName() async {
    try {
      final projectName = await GamePathResolver.resolveProjectName();
      if (projectName != null && projectName.isNotEmpty) {
        return projectName;
      }
    } catch (_) {
      // 忽略读取失败，使用默认值
    }
    return 'DefaultProject';
  }

  Future<File?> fileForKey(String cacheKey) async {
    final dir = await getCacheDirectory();
    if (dir.isEmpty) {
      return null;
    }
    return File(p.join(dir, '$cacheKey.png'));
  }

  bool isCachePath(String path) {
    if (path.isEmpty) {
      return false;
    }
    return path.contains('${p.separator}.cg_cache${p.separator}') ||
        path.contains('/.cg_cache/');
  }

  Future<void> pruneIfNeeded({int maxEntries = _defaultMaxEntries}) async {
    if (kIsWeb) {
      return;
    }
    final dirPath = await getCacheDirectory();
    if (dirPath.isEmpty) {
      return;
    }

    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return;
    }

    final entries = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.png'))
        .toList();

    if (entries.length <= maxEntries) {
      return;
    }

    entries.sort((a, b) {
      final aStat = (a as FileSystemEntity).statSync();
      final bStat = (b as FileSystemEntity).statSync();
      return aStat.modified.compareTo(bStat.modified);
    });

    final toDelete = entries.length - maxEntries;
    for (var i = 0; i < toDelete; i++) {
      try {
        await entries[i].delete();
      } catch (_) {
        // 忽略单个文件删除失败
      }
    }
  }

  Future<Map<String, dynamic>> collectStats() async {
    if (kIsWeb) {
      return {'cache_type': 'disk'};
    }

    final dirPath = await getCacheDirectory();
    if (dirPath.isEmpty) {
      return {'cache_type': 'disk'};
    }

    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return {'cache_type': 'disk'};
    }

    int fileCount = 0;
    int totalSize = 0;

    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.png')) {
        fileCount += 1;
        try {
          totalSize += await entity.length();
        } catch (_) {}
      }
    }

    return {
      'cache_type': 'disk',
      'cached_files': fileCount,
      'total_size': totalSize,
      'directory': dirPath,
    };
  }

  Future<void> clear() async {
    if (kIsWeb) {
      return;
    }

    final dirPath = await getCacheDirectory();
    if (dirPath.isEmpty) {
      return;
    }
    final directory = Directory(dirPath);
    if (await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
    }
    _cacheDirectory = null;
  }
}
