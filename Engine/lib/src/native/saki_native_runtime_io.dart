import 'package:saki_native/saki_native.dart';

/// Initializes the shared Rust library once and remembers an unavailable bridge.
class SakiNativeRuntime {
  static Future<bool>? _initialization;

  static Future<bool> ensureInitialized() {
    final existing = _initialization;
    if (existing != null) {
      print('[SAKI_NATIVE][INIT] reuse');
      return existing;
    }
    print('[SAKI_NATIVE][INIT] cold-start');
    return _initialization = _initialize();
  }

  static Future<bool> _initialize() async {
    final stopwatch = Stopwatch()..start();
    try {
      await RustLib.init();
      stopwatch.stop();
      print(
        '[SAKI_NATIVE][INIT] ready '
        'elapsedMs=${stopwatch.elapsedMicroseconds / 1000.0}',
      );
      return true;
    } catch (error, stackTrace) {
      stopwatch.stop();
      print(
        '[SAKI_NATIVE][INIT] failed '
        'elapsedMs=${stopwatch.elapsedMicroseconds / 1000.0}; '
        'Dart fallback enabled: $error',
      );
      print(stackTrace);
      return false;
    }
  }
}
