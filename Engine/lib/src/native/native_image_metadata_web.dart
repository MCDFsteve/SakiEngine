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
) async => null;
