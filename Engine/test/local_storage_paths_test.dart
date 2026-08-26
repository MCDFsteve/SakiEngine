import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sakiengine/src/utils/local_storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'new saves use Application Support and legacy Documents stays readable',
    () async {
      final originalPathProvider = PathProviderPlatform.instance;
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'saki-local-storage-paths-test-',
      );
      final support = Directory(p.join(temporaryDirectory.path, 'Support'));
      final documents = Directory(p.join(temporaryDirectory.path, 'Documents'));
      final cache = Directory(p.join(temporaryDirectory.path, 'Caches'));
      const projectName = 'storage-path-test';
      final legacy = Directory(
        p.join(documents.path, 'SakiEngine', 'Saves', projectName),
      );
      await legacy.create(recursive: true);
      final legacyMetadata = File(p.join(legacy.path, 'game_data.sakidata'));
      await legacyMetadata.writeAsString('legacy-data');

      PathProviderPlatform.instance = _TestPathProvider(
        supportPath: support.path,
        documentsPath: documents.path,
        cachePath: cache.path,
      );
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        await temporaryDirectory.delete(recursive: true);
      });

      final current = await LocalStoragePaths.projectSavesDirectory(
        projectName,
      );
      final resolvedLegacy =
          await LocalStoragePaths.legacyProjectSavesDirectory(projectName);
      final migratedMetadata = await LocalStoragePaths.projectMetadataFile(
        projectName,
        'game_data.sakidata',
      );

      expect(
        current.path,
        p.join(support.path, 'SakiEngine', 'Saves', projectName),
      );
      expect(await current.exists(), isTrue);
      expect(resolvedLegacy?.path, legacy.path);
      expect(await legacy.exists(), isTrue);
      expect(await migratedMetadata.readAsString(), 'legacy-data');
      expect(await legacyMetadata.readAsString(), 'legacy-data');
    },
  );
}

final class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider({
    required this.supportPath,
    required this.documentsPath,
    required this.cachePath,
  });

  final String supportPath;
  final String documentsPath;
  final String cachePath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationCachePath() async => cachePath;
}
