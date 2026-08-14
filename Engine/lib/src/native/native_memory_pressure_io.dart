import 'package:saki_native/saki_native.dart' as native;
import 'package:sakiengine/src/native/saki_native_runtime.dart';

Future<int> releaseUnusedNativeMemory() async {
  if (!await SakiNativeRuntime.ensureInitialized()) {
    return 0;
  }
  try {
    return native.releaseUnusedNativeMemory().toInt();
  } catch (_) {
    return 0;
  }
}
