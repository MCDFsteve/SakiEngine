import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves private, device-local storage used by the engine.
///
/// User documents are intentionally not used here. On Apple platforms the
/// Documents directory may be managed by iCloud/FileProvider, which can evict
/// save files and turn an otherwise small header read into a network download.
class LocalStoragePaths {
  LocalStoragePaths._();

  static Future<Directory> engineDataDirectory({bool create = true}) async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'SakiEngine'));
    if (create) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static Future<Directory> savesRootDirectory({bool create = true}) async {
    final engine = await engineDataDirectory(create: create);
    final directory = Directory(p.join(engine.path, 'Saves'));
    if (create) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static Future<Directory> projectSavesDirectory(
    String projectName, {
    bool create = true,
  }) async {
    final savesRoot = await savesRootDirectory(create: create);
    final directory = Directory(p.join(savesRoot.path, projectName));
    if (create) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Returns the pre-migration Documents save directory when it exists.
  ///
  /// The directory is never created or modified. It exists only so releases
  /// made before the Application Support migration can keep old saves visible
  /// without putting any new data back under Documents.
  static Future<Directory?> legacyProjectSavesDirectory(
    String projectName,
  ) async {
    final documents = await getApplicationDocumentsDirectory();
    final legacy = Directory(
      p.join(documents.path, 'SakiEngine', 'Saves', projectName),
    );
    final current = await projectSavesDirectory(projectName, create: false);
    if (p.equals(legacy.path, current.path) || !await legacy.exists()) {
      return null;
    }
    return legacy;
  }

  /// Resolves a small project metadata file in Application Support.
  ///
  /// Existing metadata from the old Documents layout is copied once, without
  /// deleting or overwriting the source. This is intended for settings and
  /// read-state files, not large `.sakisav` files.
  static Future<File> projectMetadataFile(
    String projectName,
    String fileName,
  ) async {
    final currentDirectory = await projectSavesDirectory(projectName);
    final current = File(p.join(currentDirectory.path, fileName));
    if (await current.exists()) return current;

    final legacyDirectory = await legacyProjectSavesDirectory(projectName);
    if (legacyDirectory != null) {
      final legacy = File(p.join(legacyDirectory.path, fileName));
      if (await legacy.exists()) {
        await legacy.copy(current.path);
      }
    }
    return current;
  }

  /// Resolves engine-wide metadata and copies the old Documents file once.
  static Future<File> engineMetadataFile(String fileName) async {
    final currentDirectory = await engineDataDirectory();
    final current = File(p.join(currentDirectory.path, fileName));
    if (await current.exists()) return current;

    final documents = await getApplicationDocumentsDirectory();
    final legacy = File(p.join(documents.path, 'SakiEngine', fileName));
    if (!p.equals(legacy.path, current.path) && await legacy.exists()) {
      await legacy.copy(current.path);
    }
    return current;
  }

  static Future<Directory> projectCacheDirectory(
    String projectName, {
    bool create = true,
  }) async {
    final cache = await getApplicationCacheDirectory();
    final directory = Directory(p.join(cache.path, 'SakiEngine', projectName));
    if (create) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
