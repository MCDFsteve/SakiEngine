import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';

class CharacterLayerInfo {
  final String assetName;
  final int layerLevel;
  final String layerType;

  const CharacterLayerInfo({
    required this.assetName,
    required this.layerLevel,
    required this.layerType,
  });
}

class CharacterLayerParser {
  // 添加缓存以避免重复解析
  static final Map<String, List<CharacterLayerInfo>> _layerCache = {};

  static Future<List<CharacterLayerInfo>> parseCharacterLayers({
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    // 生成缓存键
    final cacheKey = '$resourceId:$pose:$expression';

    // 检查缓存
    if (_layerCache.containsKey(cacheKey)) {
      return _layerCache[cacheKey]!;
    }

    final layers = <CharacterLayerInfo>[];

    // 首先检查是否为物件（在items文件夹中查找）
    final itemAssetName = 'items/$resourceId';
    final itemExists = await AssetManager().findAsset(itemAssetName) != null;

    if (itemExists) {
      // 这是一个物件，使用简化的图层结构
      print('[CharacterLayerParser] 检测到物件: $resourceId，使用items文件夹');
      layers.add(CharacterLayerInfo(
        assetName: itemAssetName,
        layerLevel: 0,
        layerType: 'item',
      ));

      // 缓存结果
      _layerCache[cacheKey] = layers;
      return layers;
    }

    // 不是物件，按原有逻辑处理角色
    // 1. 底层：pose（姿势）- 如果找不到指定pose，使用字母顺序第一个可用的pose
    String actualPose = pose;
    final poseAssetName = 'characters/$resourceId-$actualPose';
    final poseExists = await AssetManager().findAsset(poseAssetName) != null;

    if (!poseExists) {
      // 寻找可用的pose图层（level 0相当于pose层）
      final availablePoses =
          await AssetManager.getAvailableCharacterLayers(resourceId);
      final poseLayersOnly =
          availablePoses.where((layer) => !layer.contains('-')).toList();
      if (poseLayersOnly.isNotEmpty) {
        actualPose = poseLayersOnly.first;
      }
    }

    layers.add(CharacterLayerInfo(
      assetName: 'characters/$resourceId-$actualPose',
      layerLevel: 0,
      layerType: 'pose',
    ));

    // 2. 解析expression，支持多级图层并处理默认值
    final expressionLayers =
        await _parseExpressionLayers(resourceId, expression);
    layers.addAll(expressionLayers);

    // 3. 可选的姿势前景层。用于手臂、道具等必须覆盖在表情之上的部件，
    // 命名约定：characters/<resourceId>-<pose>-foreground。
    //
    // Ren'Py layeredimage 常见顺序是 body -> face -> arm。把 arm 直接烘进
    // pose 底图会导致后绘制的 face 遮住手部，因此这里提供一个通用的第三层，
    // 让项目无需为每个表情重复生成整张立绘。
    final foregroundAssetName = 'characters/$resourceId-$actualPose-foreground';
    final foregroundExists =
        await AssetManager().findAsset(foregroundAssetName) != null;
    if (foregroundExists) {
      layers.add(CharacterLayerInfo(
        assetName: foregroundAssetName,
        layerLevel: 98,
        layerType: 'pose_foreground',
      ));
    }

    // 4. 检查是否需要添加帽子图层（仅针对特定角色和姿势）
    if (resourceId == 'xiayo1' &&
        (actualPose == 'pose6' ||
            actualPose == 'pose7' ||
            actualPose == 'pose8')) {
      final hatLayer = await _parseHatLayer(resourceId, actualPose);
      if (hatLayer != null) {
        layers.add(hatLayer);
      }
    }

    // 按层级排序确保正确的渲染顺序
    layers.sort((a, b) => a.layerLevel.compareTo(b.layerLevel));

    // 缓存结果
    _layerCache[cacheKey] = layers;

    return layers;
  }

  static Future<List<CharacterLayerInfo>> _parseExpressionLayers(
    String resourceId,
    String expression,
  ) async {
    final layers = <CharacterLayerInfo>[];

    // 单层解析逻辑：
    // "happy" -> level 1 (基础表情)
    // "-happy" -> level 1 (基础差分表情，与原逻辑兼容)
    // "--happy" -> level 2 (第二层图层)
    // "---happy" -> level 3 (第三层图层)
    //
    // 使用 "+" 可在一个 expression 中组合多个差分：
    // "normal+--mask" -> normal(level 1) + mask(level 2)

    if (expression.isEmpty) {
      return layers;
    }

    final expressions = expression
        .split('+')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty);
    for (final expressionPart in expressions) {
      final layer = await _parseExpressionLayer(resourceId, expressionPart);
      if (layer != null) {
        layers.add(layer);
      }
    }

    return layers;
  }

  static Future<CharacterLayerInfo?> _parseExpressionLayer(
    String resourceId,
    String expression,
  ) async {
    // 计算开头连续"-"的数量
    int dashCount = 0;
    for (int i = 0; i < expression.length; i++) {
      if (expression[i] == '-') {
        dashCount++;
      } else {
        break;
      }
    }

    // 提取实际的表情名称
    String actualExpression;
    if (dashCount > 0) {
      actualExpression = expression.substring(dashCount);
    } else {
      actualExpression = expression;
    }

    if (actualExpression.isEmpty) {
      return null;
    }

    // 确定图层级别
    int layerLevel;
    if (dashCount == 0) {
      layerLevel = 1; // 无"-"，作为基础表情
    } else if (dashCount == 1) {
      layerLevel = 1; // 单"-"，保持与原有逻辑兼容
    } else {
      layerLevel = dashCount; // 多"-"，按"-"数量确定层级
    }

    // 检查指定表情是否存在，如果不存在则查找该级别的默认表情
    String finalExpression = actualExpression;
    final assetName = 'characters/$resourceId-$finalExpression';
    final exists = await AssetManager().findAsset(assetName) != null;

    if (!exists) {
      // 查找该级别下字母顺序第一个可用的图层
      final defaultLayer =
          await AssetManager.getDefaultLayerForLevel(resourceId, layerLevel);
      if (defaultLayer != null) {
        finalExpression = defaultLayer;
      }
    }

    return CharacterLayerInfo(
      assetName: 'characters/$resourceId-$finalExpression',
      layerLevel: layerLevel,
      layerType: 'expression_layer_$layerLevel',
    );
  }

  /// 辅助方法：检查表情字符串的层级
  static int getExpressionLayerLevel(String expression) {
    if (expression.isEmpty) return 1;

    int dashCount = 0;
    for (int i = 0; i < expression.length; i++) {
      if (expression[i] == '-') {
        dashCount++;
      } else {
        break;
      }
    }

    if (dashCount == 0) {
      return 1;
    } else if (dashCount == 1) {
      return 1; // 保持与原有逻辑兼容
    } else {
      return dashCount;
    }
  }

  /// 解析帽子图层
  static Future<CharacterLayerInfo?> _parseHatLayer(
      String resourceId, String pose) async {
    // 帽子图层的资源命名：characters/xiayo1-hat
    // 帽子图层应该在所有差分图层之上，使用层级99
    final hatAssetName = 'characters/$resourceId-hat';
    final hatExists = await AssetManager().findAsset(hatAssetName) != null;

    if (hatExists) {
      print('[CharacterLayerParser] 为 $resourceId $pose 添加帽子图层: $hatAssetName');
      return CharacterLayerInfo(
        assetName: hatAssetName,
        layerLevel: 99, // 最高层级，确保在所有表情图层之上
        layerType: 'hat_layer',
      );
    }

    return null;
  }

  /// 辅助方法：从表情字符串中提取实际的表情名称
  static String extractExpressionName(String expression) {
    if (expression.isEmpty) return expression;

    int dashCount = 0;
    for (int i = 0; i < expression.length; i++) {
      if (expression[i] == '-') {
        dashCount++;
      } else {
        break;
      }
    }

    return dashCount > 0 ? expression.substring(dashCount) : expression;
  }

  /// 清理缓存（在必要时调用）
  static void clearCache() {
    _layerCache.clear();
  }
}
