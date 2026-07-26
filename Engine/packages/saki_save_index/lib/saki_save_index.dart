import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _assetId = 'package:saki_save_index/saki_save_index.dart';

typedef _ScanNative =
    Pointer<Utf8> Function(
      Pointer<Utf8> directory,
      Int64 startSlotId,
      Int64 endSlotId,
    );

typedef _FreeNative = Void Function(Pointer<Utf8> value);

@Native<_ScanNative>(symbol: 'saki_save_index_scan_json', assetId: _assetId)
external Pointer<Utf8> _scanJson(
  Pointer<Utf8> directory,
  int startSlotId,
  int endSlotId,
);

@Native<_FreeNative>(symbol: 'saki_save_index_free_string', assetId: _assetId)
external void _freeString(Pointer<Utf8> value);

class SakiSaveIndexResult {
  const SakiSaveIndexResult({
    required this.slots,
    required this.elapsedMicros,
    required this.invalidFiles,
  });

  final List<SakiSaveHeader> slots;
  final int elapsedMicros;
  final List<String> invalidFiles;
}

class SakiSaveHeader {
  const SakiSaveHeader({
    required this.id,
    required this.version,
    required this.saveTimeMillis,
    required this.currentScript,
    required this.dialoguePreview,
    required this.filePath,
    required this.screenshotOffset,
    required this.screenshotLength,
    required this.isLocked,
    required this.scriptIndex,
    required this.previewKind,
    required this.previewSpeaker,
    required this.previewText,
    required this.previewChoices,
  });

  final int id;
  final int version;
  final int saveTimeMillis;
  final String currentScript;
  final String dialoguePreview;
  final String filePath;
  final int? screenshotOffset;
  final int? screenshotLength;
  final bool isLocked;
  final int scriptIndex;
  final String previewKind;
  final String? previewSpeaker;
  final String? previewText;
  final List<String> previewChoices;

  factory SakiSaveHeader.fromJson(Map<String, Object?> json) {
    return SakiSaveHeader(
      id: (json['id'] as num).toInt(),
      version: (json['version'] as num).toInt(),
      saveTimeMillis: (json['saveTimeMillis'] as num).toInt(),
      currentScript: json['currentScript'] as String? ?? '',
      dialoguePreview: json['dialoguePreview'] as String? ?? '',
      filePath: json['filePath'] as String? ?? '',
      screenshotOffset: (json['screenshotOffset'] as num?)?.toInt(),
      screenshotLength: (json['screenshotLength'] as num?)?.toInt(),
      isLocked: json['isLocked'] as bool? ?? false,
      scriptIndex: (json['scriptIndex'] as num?)?.toInt() ?? 0,
      previewKind: json['previewKind'] as String? ?? 'stored',
      previewSpeaker: json['previewSpeaker'] as String?,
      previewText: json['previewText'] as String?,
      previewChoices: (json['previewChoices'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }
}

Future<SakiSaveIndexResult> scanSakiSaveHeaders(
  String directory, {
  int startSlotId = 1,
  int endSlotId = 0x7fffffff,
}) async => _scanSakiSaveHeadersSync(directory, startSlotId, endSlotId);

SakiSaveIndexResult _scanSakiSaveHeadersSync(
  String directory,
  int startSlotId,
  int endSlotId,
) {
  final directoryPointer = directory.toNativeUtf8();
  Pointer<Utf8> resultPointer = nullptr;
  try {
    resultPointer = _scanJson(directoryPointer, startSlotId, endSlotId);
    if (resultPointer == nullptr) {
      throw StateError('Rust save index returned a null response.');
    }

    final decoded = jsonDecode(resultPointer.toDartString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid Rust save index response.');
    }
    if (decoded['ok'] != true) {
      throw StateError(
        decoded['error'] as String? ?? 'Rust save index failed.',
      );
    }

    final rawSlots = decoded['slots'] as List<Object?>? ?? const [];
    final slots = rawSlots
        .whereType<Map<String, Object?>>()
        .map(SakiSaveHeader.fromJson)
        .toList(growable: false);
    final invalidFiles = (decoded['invalidFiles'] as List<Object?>? ?? const [])
        .whereType<String>()
        .toList(growable: false);

    return SakiSaveIndexResult(
      slots: slots,
      elapsedMicros: (decoded['elapsedMicros'] as num?)?.toInt() ?? 0,
      invalidFiles: invalidFiles,
    );
  } finally {
    malloc.free(directoryPointer);
    if (resultPointer != nullptr) {
      _freeString(resultPointer);
    }
  }
}
