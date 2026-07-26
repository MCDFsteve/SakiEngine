import 'package:saki_native/saki_native.dart';

/// Initializes the shared Rust library once and remembers an unavailable bridge.
class SakiNativeRuntime {
  static Future<bool>? _initialization;

  static Future<bool> ensureInitialized() {
    return _initialization ??= _initialize();
  }

  static Future<bool> _initialize() async {
    try {
      await RustLib.init();
      return true;
    } catch (error, stackTrace) {
      print(
        '[SAKI_NATIVE] initialization failed; Dart fallback enabled: $error',
      );
      print(stackTrace);
      return false;
    }
  }
}
