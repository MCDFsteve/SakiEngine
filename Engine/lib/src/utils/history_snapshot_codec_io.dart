import 'dart:typed_data';

import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';

class HistorySnapshotCodec {
  static const int _raw = 0;
  static const int _lz4 = 1;
  static bool _loggedNativeCodec = false;

  static Uint8List pack(Uint8List bytes) {
    try {
      final compressed = compressHistorySnapshotIfReady(bytes);
      if (compressed != null && compressed.length + 1 < bytes.length) {
        final result = Uint8List(compressed.length + 1)..[0] = _lz4;
        result.setRange(1, result.length, compressed);
        if (!_loggedNativeCodec) {
          _loggedNativeCodec = true;
          sakiDiagnosticLog(
            '[SAKI_NATIVE][HISTORY] LZ4 active '
            'raw=${bytes.length}B packed=${result.length}B',
          );
        }
        return result;
      }
    } catch (_) {
      // Native support is optional during unit tests and unsupported hosts.
    }
    final result = Uint8List(bytes.length + 1)..[0] = _raw;
    result.setRange(1, result.length, bytes);
    return result;
  }

  static Uint8List unpack(Uint8List packed) {
    if (packed.isEmpty) {
      throw const FormatException('Empty history snapshot');
    }
    final payload = Uint8List.sublistView(packed, 1);
    if (packed[0] == _raw) {
      return Uint8List.fromList(payload);
    }
    if (packed[0] == _lz4) {
      final decoded = decompressHistorySnapshotIfReady(payload);
      if (decoded == null) {
        throw StateError(
          'Rust history codec is unavailable for a compressed snapshot',
        );
      }
      return decoded;
    }
    throw FormatException('Unknown history snapshot codec: ${packed[0]}');
  }
}
