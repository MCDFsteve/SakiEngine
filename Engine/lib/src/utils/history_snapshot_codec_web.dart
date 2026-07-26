import 'dart:typed_data';

class HistorySnapshotCodec {
  static Uint8List pack(Uint8List bytes) {
    final result = Uint8List(bytes.length + 1);
    result.setRange(1, result.length, bytes);
    return result;
  }

  static Uint8List unpack(Uint8List packed) {
    if (packed.isEmpty || packed[0] != 0) {
      throw const FormatException('Unsupported Web history snapshot');
    }
    return Uint8List.fromList(Uint8List.sublistView(packed, 1));
  }
}
