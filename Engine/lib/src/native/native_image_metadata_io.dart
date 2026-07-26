import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/native/saki_native_runtime.dart';

class NativeImageMetadata {
  const NativeImageMetadata({
    required this.path,
    required this.width,
    required this.height,
    required this.decodedRgbaBytes,
    required this.fileBytes,
    required this.format,
  });

  final String path;
  final int width;
  final int height;
  final int decodedRgbaBytes;
  final int fileBytes;
  final String format;
}

Future<List<NativeImageMetadata>?> inspectImagesNatively(
  List<String> paths,
) async {
  if (paths.isEmpty || !await SakiNativeRuntime.ensureInitialized()) {
    return null;
  }
  try {
    final result = await inspectImageFiles(paths: paths);
    return [
      for (final image in result)
        if (image.error == null)
          NativeImageMetadata(
            path: image.path,
            width: image.width,
            height: image.height,
            decodedRgbaBytes: image.decodedRgbaBytes.toInt(),
            fileBytes: image.fileBytes.toInt(),
            format: image.format,
          ),
    ];
  } catch (_) {
    return null;
  }
}
