import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/bundle_asset_path_probe.dart';
import 'package:sakiengine/src/utils/async_initialization_gate.dart';
import 'package:path/path.dart' as p;
import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/native/saki_native_runtime.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';

class _PackEntry {
  final String path;
  final int offset;
  final int length;
  final bool text;
  final String? sha256;

  const _PackEntry({
    required this.path,
    required this.offset,
    required this.length,
    required this.text,
    required this.sha256,
  });
}

class SakiPackStore {
  static final SakiPackStore instance = SakiPackStore._();

  static const int _magic = 0x53414B49; // "SAKI"
  static const int _headerBytes = 20;
  static const int _maxIndexBytes = 1024 * 1024 * 16;

  SakiPackStore._();

  final AsyncInitializationGate<bool> _initializationGate =
      AsyncInitializationGate<bool>();
  bool _available = false;
  String? _packPath;
  BigInt? _nativePackHandle;
  Uint8List? _packBytes;
  final Map<String, _PackEntry> _entryMap = <String, _PackEntry>{};
  final Map<String, String> _searchCache = <String, String>{};
  final Map<String, String> _materializedFiles = <String, String>{};
  final Map<String, Future<String?>> _materializingFiles =
      <String, Future<String?>>{};
  Directory? _materializeRoot;
  Future<Directory>? _materializeRootFuture;

  Future<bool> ensureInitialized() => _initializationGate.run(_initialize);

  Future<bool> _initialize() async {
    if (GamePathResolver.shouldUseFileSystemAssets) {
      _available = false;
      return false;
    }

    final candidates = <String>[];
    final fromBundle = probeBundleAssetAbsolutePath('Assets/game.sakipak');
    final fromBundleExists = probeBundleAssetExists('Assets/game.sakipak');
    if (fromBundle != null && fromBundleExists == true) {
      candidates.add(fromBundle);
    }
    final fromCacheBundle = probeBundleAssetAbsolutePath(
      '.saki_cache/game.sakipak',
    );
    final fromCacheBundleExists = probeBundleAssetExists(
      '.saki_cache/game.sakipak',
    );
    if (fromCacheBundle != null && fromCacheBundleExists == true) {
      candidates.add(fromCacheBundle);
    }
    candidates.add(p.normalize(p.absolute('Assets/game.sakipak')));
    candidates.add(p.normalize(p.absolute('.saki_cache/game.sakipak')));
    final gamePath = await GamePathResolver.resolveGamePath();
    if (gamePath != null && gamePath.isNotEmpty) {
      candidates.add(p.join(gamePath, 'Assets', 'game.sakipak'));
      candidates.add(p.join(gamePath, '.saki_cache', 'game.sakipak'));
    }

    File? packFile;
    String? packPath;
    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        packFile = file;
        packPath = candidate;
        break;
      }
    }
    if (packFile != null && packPath != null && await packFile.exists()) {
      if (await SakiNativeRuntime.ensureInitialized()) {
        try {
          final catalog = await openSakiPack(path: packPath);
          _packPath = packPath;
          _nativePackHandle = catalog.handle;
          for (final entry in catalog.entries) {
            _entryMap[entry.path] = _PackEntry(
              path: entry.path,
              offset: entry.offset.toInt(),
              length: entry.length.toInt(),
              text: entry.text,
              sha256: entry.sha256,
            );
          }
          _available = true;
          sakiDiagnosticLog(
            '[SAKI_NATIVE][PACK] opened=${catalog.entries.length} '
            'path=${catalog.path}',
          );
          return true;
        } catch (error, stackTrace) {
          print(
            '[SAKI_NATIVE][PACK] native open failed; '
            'Dart fallback enabled: $error',
          );
          print(stackTrace);
        }
      }
      try {
        final raf = await packFile.open(mode: FileMode.read);
        try {
          final header = await raf.read(_headerBytes);
          final parsedHeader = _parseHeader(header);
          if (parsedHeader == null) {
            _available = false;
            return false;
          }
          final indexOffset = parsedHeader.$1;
          final indexLength = parsedHeader.$2;

          await raf.setPosition(indexOffset);
          final indexBytes = await raf.read(indexLength);
          if (indexBytes.length != indexLength) {
            _available = false;
            return false;
          }

          final parsed = _parseIndex(indexBytes);
          if (parsed == null) {
            _available = false;
            return false;
          }
          _packPath = packPath;
          for (final entry in parsed) {
            _entryMap[entry.path] = entry;
          }
          _available = true;
          return true;
        } finally {
          await raf.close();
        }
      } catch (_) {
        // continue with rootBundle fallback
      }
    }

    final bundleCandidates = <String>[
      'Assets/game.sakipak',
      'assets/Assets/game.sakipak',
      '.saki_cache/game.sakipak',
      'assets/.saki_cache/game.sakipak',
    ];
    for (final assetPath in bundleCandidates) {
      try {
        final data = await rootBundle.load(assetPath);
        final bytes = data.buffer.asUint8List();
        if (bytes.length < _headerBytes) {
          continue;
        }
        final parsedHeader = _parseHeader(bytes.sublist(0, _headerBytes));
        if (parsedHeader == null) {
          continue;
        }
        final indexOffset = parsedHeader.$1;
        final indexLength = parsedHeader.$2;
        final end = indexOffset + indexLength;
        if (end > bytes.length || indexOffset < 0 || indexLength <= 0) {
          continue;
        }
        final indexBytes = bytes.sublist(indexOffset, end);
        final parsed = _parseIndex(indexBytes);
        if (parsed == null) {
          continue;
        }
        _packBytes = bytes;
        for (final entry in parsed) {
          _entryMap[entry.path] = entry;
        }
        _available = true;
        return true;
      } catch (_) {
        // try next candidate
      }
    }

    _available = false;
    return false;
  }

  bool contains(String virtualPath) {
    if (!_available) return false;
    return _entryMap.containsKey(_normalizePath(virtualPath));
  }

  String? resolveVirtualAssetPath(String name) {
    if (!_available) {
      return null;
    }

    final normalized = _normalizeName(name);
    if (_searchCache.containsKey(normalized)) {
      return _searchCache[normalized];
    }

    final targetFileName = normalized.split('/').last.toLowerCase();
    final targetStem = p.basenameWithoutExtension(targetFileName).toLowerCase();
    final targetPath = normalized.contains('/')
        ? normalized.substring(0, normalized.lastIndexOf('/')).toLowerCase()
        : '';

    final supportedExtensions = <String>[
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.avif',
      '.svg',
      '.mp4',
      '.mov',
      '.avi',
      '.mkv',
      '.webm',
      '.mp3',
      '.ogg',
      '.wav',
      '.flac',
      '.m4a',
      '.aac',
      '.sks',
      '.json',
      '.txt',
    ];

    String? findWithPathPreference(bool strictPath) {
      for (final entry in _entryMap.values) {
        final fileName = p.basename(entry.path).toLowerCase();
        if (!supportedExtensions.any((ext) => fileName.endsWith(ext))) {
          continue;
        }
        final stem = p.basenameWithoutExtension(fileName).toLowerCase();
        final fileMatch = fileName == targetFileName || stem == targetStem;
        if (!fileMatch) continue;
        if (!strictPath || targetPath.isEmpty) {
          return entry.path;
        }
        final lowerPath = entry.path.toLowerCase();
        if (lowerPath.contains('/$targetPath/') ||
            lowerPath.contains('$targetPath/')) {
          return entry.path;
        }
      }
      return null;
    }

    final resolved =
        findWithPathPreference(true) ?? findWithPathPreference(false);
    if (resolved != null) {
      _searchCache[normalized] = resolved;
    }
    return resolved;
  }

  Future<String?> loadText(String virtualPath) async {
    final bytes = await loadBytes(virtualPath);
    if (bytes == null) {
      return null;
    }
    return utf8.decode(bytes);
  }

  Future<Uint8List?> loadBytes(String virtualPath) async {
    if (!await ensureInitialized()) {
      return null;
    }
    final entry = _entryMap[_normalizePath(virtualPath)];
    if (entry == null) {
      return null;
    }
    if (_packBytes != null) {
      final bytes = _packBytes!;
      final start = entry.offset;
      final end = entry.offset + entry.length;
      if (start < 0 || end > bytes.length || start >= end) {
        return null;
      }
      return Uint8List.sublistView(bytes, start, end);
    }
    final nativeHandle = _nativePackHandle;
    if (nativeHandle != null) {
      try {
        return await readSakiPackEntry(handle: nativeHandle, path: entry.path);
      } catch (error) {
        print('[SAKI_NATIVE][PACK] read failed for ${entry.path}: $error');
        return null;
      }
    }
    if (_packPath == null) {
      return null;
    }
    try {
      final raf = await File(_packPath!).open(mode: FileMode.read);
      try {
        await raf.setPosition(entry.offset);
        final bytes = await raf.read(entry.length);
        if (bytes.length != entry.length) {
          return null;
        }
        return bytes;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  Future<String?> materializeFilePath(String virtualPath) async {
    if (!await ensureInitialized()) {
      return null;
    }
    final normalized = _normalizePath(virtualPath);
    final cached = _materializedFiles[normalized];
    if (cached != null && await File(cached).exists()) {
      return cached;
    }

    final activeMaterialization = _materializingFiles[normalized];
    if (activeMaterialization != null) {
      return activeMaterialization;
    }

    late final Future<String?> materialization;
    materialization = _materializeFilePathUncached(normalized).whenComplete(() {
      if (identical(_materializingFiles[normalized], materialization)) {
        _materializingFiles.remove(normalized);
      }
    });
    _materializingFiles[normalized] = materialization;
    return materialization;
  }

  Future<String?> _materializeFilePathUncached(String normalized) async {
    final entry = _entryMap[normalized];
    if (entry == null) {
      return null;
    }

    try {
      final tmpRoot = await _ensureMaterializeRoot();
      final suffix = p.extension(entry.path);
      final digest = base64Url
          .encode(utf8.encode(entry.path))
          .replaceAll('=', '');
      final outputPath = p.join(tmpRoot.path, '$digest$suffix');
      final nativeHandle = _nativePackHandle;
      if (nativeHandle != null) {
        final materialized = await materializeSakiPackEntry(
          handle: nativeHandle,
          path: entry.path,
          outputPath: outputPath,
        );
        if (materialized) {
          _materializedFiles[normalized] = outputPath;
          return outputPath;
        }
        return null;
      }
      final bytes = await loadBytes(normalized);
      if (bytes == null) {
        return null;
      }
      final tempFile = File(
        '$outputPath.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      await tempFile.rename(outputPath);
      _materializedFiles[normalized] = outputPath;
      return outputPath;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _ensureMaterializeRoot() {
    final root = _materializeRoot;
    if (root != null) {
      return Future<Directory>.value(root);
    }

    final activeRootCreation = _materializeRootFuture;
    if (activeRootCreation != null) {
      return activeRootCreation;
    }

    late final Future<Directory> rootCreation;
    rootCreation = Directory.systemTemp
        .createTemp('saki_pack_')
        .then((root) {
          _materializeRoot = root;
          return root;
        })
        .whenComplete(() {
          if (identical(_materializeRootFuture, rootCreation)) {
            _materializeRootFuture = null;
          }
        });
    _materializeRootFuture = rootCreation;
    return rootCreation;
  }

  List<String> listFileNames(String directory, String extension) {
    if (!_available) {
      return const <String>[];
    }
    final normalizedDir = _normalizePath(directory).replaceAll('\\', '/');
    final prefix = normalizedDir.endsWith('/')
        ? normalizedDir
        : '$normalizedDir/';
    final lowerExt = extension.toLowerCase();
    final result = <String>[];
    final seen = <String>{};
    for (final entry in _entryMap.values) {
      final path = entry.path;
      if (!path.startsWith(prefix)) {
        continue;
      }
      final fileName = p.basename(path);
      if (!fileName.toLowerCase().endsWith(lowerExt)) {
        continue;
      }
      if (seen.add(fileName)) {
        result.add(fileName);
      }
    }
    return result;
  }

  Future<String?> resolvePathForPlayback(String pathOrName) async {
    if (!await ensureInitialized()) {
      return null;
    }
    final normalized = _normalizeName(pathOrName);
    final exactPath = contains(normalized)
        ? _normalizePath(normalized)
        : resolveVirtualAssetPath(normalized);
    if (exactPath == null) {
      return null;
    }
    final materialized = await materializeFilePath(exactPath);
    if (materialized != null) {
      return materialized;
    }
    return exactPath;
  }

  List<_PackEntry>? _parseIndex(Uint8List bytes) {
    try {
      final dynamic raw = json.decode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic>) {
        return null;
      }
      final version = raw['version']?.toString() ?? '1';
      if (version != '1') {
        return null;
      }
      final dynamic entriesRaw = raw['entries'];
      if (entriesRaw is! List) {
        return null;
      }
      final entries = <_PackEntry>[];
      for (final item in entriesRaw) {
        if (item is! Map) {
          return null;
        }
        final path = _normalizePath(item['path']?.toString() ?? '');
        final offset = item['offset'];
        final length = item['length'];
        final text = item['text'] == true;
        final shaValue = item['sha256']?.toString();
        if (path.isEmpty || offset is! int || length is! int) {
          return null;
        }
        entries.add(
          _PackEntry(
            path: path,
            offset: offset,
            length: length,
            text: text,
            sha256: shaValue,
          ),
        );
      }
      return entries;
    } catch (_) {
      return null;
    }
  }

  (int, int)? _parseHeader(Uint8List header) {
    if (header.length != _headerBytes) {
      return null;
    }
    final headerData = ByteData.sublistView(header);
    final magic = headerData.getUint32(0, Endian.big);
    if (magic != _magic) {
      return null;
    }
    final version = headerData.getUint32(4, Endian.big);
    if (version != 1) {
      return null;
    }
    final indexOffset = headerData.getUint64(8, Endian.big);
    final indexLength = headerData.getUint32(16, Endian.big);
    if (indexLength <= 0 || indexLength > _maxIndexBytes) {
      return null;
    }
    return (indexOffset.toInt(), indexLength);
  }

  String _normalizeName(String value) {
    final normalized = value.replaceAll('\\', '/').trim();
    if (normalized.startsWith('asset:///')) {
      return normalized.substring('asset:///'.length);
    }
    if (normalized.startsWith('/')) {
      return normalized.substring(1);
    }
    if (normalized.startsWith('assets/')) {
      return normalized.substring('assets/'.length);
    }
    return normalized;
  }

  String _normalizePath(String value) {
    var normalized = value.replaceAll('\\', '/').trim();
    if (normalized.startsWith('asset:///')) {
      normalized = normalized.substring('asset:///'.length);
    }
    if (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    if (normalized.startsWith('assets/')) {
      normalized = normalized.substring('assets/'.length);
    }
    return normalized;
  }
}
