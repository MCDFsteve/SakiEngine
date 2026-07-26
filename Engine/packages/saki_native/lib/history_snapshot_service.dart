import 'dart:typed_data';

import 'src/rust/api/history_codec.dart';
import 'src/rust/frb_generated.dart';

Uint8List? compressHistorySnapshotIfReady(Uint8List data) {
  if (!RustLib.instance.initialized) {
    return null;
  }
  return compressHistorySnapshot(data: data);
}

Uint8List? decompressHistorySnapshotIfReady(Uint8List data) {
  if (!RustLib.instance.initialized) {
    return null;
  }
  return decompressHistorySnapshot(data: data);
}
