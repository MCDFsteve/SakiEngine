import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/widgets/smart_image.dart';
import 'package:sakiengine/src/utils/asset_path_utils.dart';
import 'smart_asset_image_io.dart' if (dart.library.html) 'smart_asset_image_web.dart';

class SmartAssetImage extends StatelessWidget {
  final String assetName;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget? errorWidget;
  final bool? loop; // 新增：控制WebP动图是否循环播放
  final VoidCallback? onAnimationComplete; // 新增：动画完成回调

  const SmartAssetImage({
    super.key,
    required this.assetName,
    this.fit,
    this.width,
    this.height,
    this.errorWidget,
    this.loop,
    this.onAnimationComplete, // 新增
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: AssetManager().findAsset(assetName),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          final assetPath = snapshot.data!;
          
          if (assetPath.toLowerCase().endsWith('.svg')) {
            // Web平台总是使用asset方式
            if (kIsWeb) {
              return SvgPicture.asset(
                assetPath,
                fit: fit ?? BoxFit.contain,
                width: width,
                height: height,
                colorFilter: null,
                allowDrawingOutsideViewBox: true,
                placeholderBuilder: errorWidget != null 
                  ? (context) => errorWidget!
                  : null,
              );
            }
            
            // 非Web平台：检查是否是绝对路径（Debug模式）
            if (isFileSystemAssetPath(assetPath)) {
              // 绝对路径：使用平台特定的实现
              return buildSvgFile(
                assetPath,
                fit: fit,
                width: width,
                height: height,
                errorWidget: errorWidget,
              );
            } else {
              // 相对路径：使用SvgPicture.asset
              return SvgPicture.asset(
                assetPath,
                fit: fit ?? BoxFit.contain,
                width: width,
                height: height,
                colorFilter: null,
                allowDrawingOutsideViewBox: true,
                placeholderBuilder: errorWidget != null 
                  ? (context) => errorWidget!
                  : null,
              );
            }
          } else {
            return SmartImage.asset(
              assetPath,
              fit: fit,
              width: width,
              height: height,
              errorWidget: errorWidget,
              loop: loop, // 传递loop参数
              onAnimationComplete: onAnimationComplete, // 传递动画完成回调
            );
          }
        } else if (snapshot.hasError) {
          print('Error loading asset $assetName: ${snapshot.error}');
          return errorWidget ?? Container();
        }
        
        return errorWidget ?? Container();
      },
    );
  }
}
