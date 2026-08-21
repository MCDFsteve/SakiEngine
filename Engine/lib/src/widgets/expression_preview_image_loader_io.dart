import 'dart:ui' as ui;

import 'package:sakiengine/src/utils/image_loader.dart';

Future<ui.Image?> loadExpressionPreviewImage(String assetPath) {
  return ImageLoader.loadImage(assetPath);
}
