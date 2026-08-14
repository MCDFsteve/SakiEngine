import 'dart:async';
import 'dart:collection';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/cg_script_pre_analyzer.dart';

/// 智能CG预测系统
///
/// 根据当前游戏位置智能预测并预热附近的CG组合
/// 避免预热整个游戏的所有CG，提高启动速度
class SmartCgPredictor {
  SmartCgPredictor();

  final CgScriptPreAnalyzer _preAnalyzer = CgScriptPreAnalyzer();

  /// 当前标签的脚本索引范围
  int _currentLabelStart = 0;
  int _currentLabelEnd = 0;

  /// 当前预热的范围
  int _currentPredictionStart = 0;
  int _currentPredictionEnd = 0;
  int _predictionGeneration = 0;

  /// 预热范围（前后行数）
  static const int _predictionRange = 100;
  // 只预热最近的少量组合。全屏 CG 的单个解码图层通常约 8 MiB，
  // 旧值最多会一次驻留 18 组，并不能换来等比例的首帧收益。
  static const int _maxCgCombos = 2;
  static const int _maxExpressionsPerCombo = 1;
  static const int _maxGlobalRange = 600;

  /// 智能预热：基于当前位置预热局部CG
  Future<void> smartPreWarm({
    required List<SksNode> scriptNodes,
    required int currentIndex,
    String? currentLabel,
  }) async {
    final generation = ++_predictionGeneration;
    // 1. 确定当前标签的范围
    _findCurrentLabelRange(scriptNodes, currentIndex, currentLabel);

    // 2. 计算预热范围（当前位置前后100行，但不超出标签范围）
    var predictionStart = _clampIndex(
      currentIndex - _predictionRange,
      _currentLabelStart,
      _currentLabelEnd,
    );
    var predictionEnd = _clampIndex(
      currentIndex + _predictionRange,
      _currentLabelStart,
      _currentLabelEnd,
    );

    // 3. 收集范围内的CG组合
    var cgCombinations = _collectCgInRange(
      scriptNodes,
      predictionStart,
      predictionEnd,
    );

    // 4. 如果没有找到CG组合，渐进式扩大搜索范围
    if (cgCombinations.isEmpty) {
      // 第一次扩展：扩大到当前标签范围
      if (predictionStart > _currentLabelStart ||
          predictionEnd < _currentLabelEnd) {
        final limitedRange = _limitRange(
          _currentLabelStart,
          _currentLabelEnd,
          currentIndex,
          scriptNodes.length,
        );
        predictionStart = limitedRange[0];
        predictionEnd = limitedRange[1];
        cgCombinations = _collectCgInRange(
          scriptNodes,
          predictionStart,
          predictionEnd,
        );
      }

      // 第二次扩展：如果标签范围内仍然没有，适度向前后扩展
      if (cgCombinations.isEmpty) {
        final moderateExpandStart = _clampIndex(
          currentIndex - _predictionRange * 2,
          0,
          scriptNodes.length - 1,
        );
        final moderateExpandEnd = _clampIndex(
          currentIndex + _predictionRange * 2,
          0,
          scriptNodes.length - 1,
        );

        final limitedRange = _limitRange(
          moderateExpandStart,
          moderateExpandEnd,
          currentIndex,
          scriptNodes.length,
        );

        predictionStart = limitedRange[0];
        predictionEnd = limitedRange[1];
        cgCombinations = _collectCgInRange(
          scriptNodes,
          predictionStart,
          predictionEnd,
        );

        // 第三次扩展：仅在确实必要时才进一步扩大
        if (cgCombinations.isEmpty) {
          final maxExpandStart = _clampIndex(
            currentIndex - _predictionRange * 5,
            0,
            scriptNodes.length - 1,
          );
          final maxExpandEnd = _clampIndex(
            currentIndex + _predictionRange * 5,
            0,
            scriptNodes.length - 1,
          );

          final limitedRange = _limitRange(
            maxExpandStart,
            maxExpandEnd,
            currentIndex,
            scriptNodes.length,
          );

          predictionStart = limitedRange[0];
          predictionEnd = limitedRange[1];
          cgCombinations = _collectCgInRange(
            scriptNodes,
            predictionStart,
            predictionEnd,
          );
        }
      }
    }

    // 5. 检查预热范围是否有变化
    if (predictionStart == _currentPredictionStart &&
        predictionEnd == _currentPredictionEnd &&
        cgCombinations.isEmpty) {
      return;
    }

    _currentPredictionStart = predictionStart;
    _currentPredictionEnd = predictionEnd;

    // 6. 异步预热这些组合
    _preWarmCombinations(cgCombinations, generation);
  }

  /// 查找当前标签的范围
  void _findCurrentLabelRange(
    List<SksNode> scriptNodes,
    int currentIndex,
    String? currentLabel,
  ) {
    if (currentLabel == null) {
      // 没有标签信息，使用整个脚本
      _currentLabelStart = 0;
      _currentLabelEnd = scriptNodes.length - 1;
      return;
    }

    // 向前查找标签开始
    _currentLabelStart = 0;
    for (int i = currentIndex; i >= 0; i--) {
      final node = scriptNodes[i];
      if (node is LabelNode && node.name == currentLabel) {
        _currentLabelStart = i;
        break;
      }
    }

    // 向后查找标签结束（下一个标签开始）
    _currentLabelEnd = scriptNodes.length - 1;
    for (int i = currentIndex; i < scriptNodes.length; i++) {
      final node = scriptNodes[i];
      if (node is LabelNode && node.name != currentLabel) {
        _currentLabelEnd = i - 1;
        break;
      }
    }
  }

  /// 收集指定范围内的CG组合
  Map<String, Set<String>> _collectCgInRange(
    List<SksNode> scriptNodes,
    int start,
    int end,
  ) {
    final combinations = LinkedHashMap<String, Set<String>>();

    for (int i = start; i <= end && i < scriptNodes.length; i++) {
      final node = scriptNodes[i];
      if (node is CgNode) {
        final resourceId = node.character;
        final pose = node.pose ?? 'pose1';
        final expression = node.expression ?? 'happy';

        final key = '${resourceId}_$pose';
        final expressions = combinations.putIfAbsent(key, () => <String>{});
        if (expressions.length < _maxExpressionsPerCombo) {
          expressions.add(expression);
        }

        if (combinations.length >= _maxCgCombos) {
          break;
        }
      }
    }

    // 日志输出已移除

    return combinations;
  }

  /// 预热CG组合
  void _preWarmCombinations(
    Map<String, Set<String>> combinations,
    int generation,
  ) {
    if (combinations.isEmpty) {
      return;
    }

    // 异步预热，不阻塞UI
    Future.microtask(() async {
      int totalPrewarmed = 0;

      for (final entry in combinations.entries) {
        if (generation != _predictionGeneration) {
          return;
        }
        if (totalPrewarmed >= _maxCgCombos * _maxExpressionsPerCombo) {
          break;
        }
        final parts = entry.key.split('_');
        if (parts.length >= 2) {
          // 至少需要resourceId和pose
          // 重新构建resourceId和pose
          final pose = parts.last; // 最后一部分是pose
          final resourceId =
              parts.sublist(0, parts.length - 1).join('_'); // 其余部分组成resourceId
          final expressions = entry.value;

          for (final expression in expressions) {
            if (generation != _predictionGeneration) {
              return;
            }
            if (totalPrewarmed >= _maxCgCombos * _maxExpressionsPerCombo) {
              break;
            }
            try {
              await _preAnalyzer.precomposeCg(
                resourceId: resourceId,
                pose: pose,
                expression: expression,
              );
              totalPrewarmed++;

              // 小延迟避免阻塞
              if (totalPrewarmed % 2 == 0) {
                await Future.delayed(const Duration(milliseconds: 2));
              }
            } catch (e) {}
          }
        } else {}
      }
    });
  }

  /// 根据标签预热（用于新游戏和读档）
  Future<void> preWarmByLabel({
    required List<SksNode> scriptNodes,
    required String labelName,
    int baseIndex = 0,
  }) async {
    // 执行标准的智能预热（已经包含渐进式扩展）
    await smartPreWarm(
      scriptNodes: scriptNodes,
      currentIndex: baseIndex,
      currentLabel: labelName,
    );

    // 只有在标准预热找到的CG组合较少时，才进行额外的周围预热
    final standardRange =
        (_currentPredictionEnd - _currentPredictionStart).abs();
    if (standardRange < _predictionRange * 2) {
      // 轻量范围不足时进行额外预热
      await _preWarmLabelSurroundingsLite(scriptNodes, labelName, baseIndex);
    } else {
      // 范围充足无需额外预热
    }
  }

  /// 轻量级周围预热（仅预热紧邻的少量CG）
  Future<void> _preWarmLabelSurroundingsLite(
    List<SksNode> scriptNodes,
    String labelName,
    int baseIndex,
  ) async {
    // 仅轻度扩展搜索范围（当前位置前后150行）
    final lightExtendStart = _clampIndex(
      (baseIndex - _predictionRange * 1.5).round(),
      0,
      scriptNodes.length - 1,
    );
    final lightExtendEnd = _clampIndex(
      (baseIndex + _predictionRange * 1.5).round(),
      0,
      scriptNodes.length - 1,
    );

    // 收集轻度扩展范围内的CG组合
    final lightCombinations = _collectCgInRange(
      scriptNodes,
      lightExtendStart,
      lightExtendEnd,
    );

    // 过滤掉已经预热过的组合
    final newCombinations = <String, Set<String>>{};
    for (final entry in lightCombinations.entries) {
      if (newCombinations.length >= 3) break;
      newCombinations[entry.key] = entry.value;
    }

    if (newCombinations.isNotEmpty) {
      // 去除冗余日志，仅执行必要预热

      // 异步预热，使用更长的延迟
      _preWarmCombinationsWithDelay(
        newCombinations,
        generation: _predictionGeneration,
        delayMs: 1000,
      );
    }
  }

  /// 带延迟的预热组合（用于背景预热）
  void _preWarmCombinationsWithDelay(
    Map<String, Set<String>> combinations, {
    required int generation,
    int delayMs = 500,
  }) {
    if (combinations.isEmpty) return;

    // 使用可配置的延迟时间
    Future.delayed(Duration(milliseconds: delayMs), () async {
      if (generation != _predictionGeneration) {
        return;
      }
      int totalPrewarmed = 0;

      for (final entry in combinations.entries) {
        if (generation != _predictionGeneration) {
          return;
        }
        final parts = entry.key.split('_');
        if (parts.length >= 3) {
          final resourceId = parts.sublist(0, parts.length - 1).join('_');
          final pose = parts.last;
          final expressions = entry.value.take(_maxExpressionsPerCombo);

          for (final expression in expressions) {
            if (generation != _predictionGeneration) {
              return;
            }
            try {
              await _preAnalyzer.precomposeCg(
                resourceId: resourceId,
                pose: pose,
                expression: expression,
              );
              totalPrewarmed++;

              // 根据延迟时间调整处理间隔
              if (totalPrewarmed % 1 == 0) {
                await Future.delayed(Duration(milliseconds: delayMs ~/ 50));
              }
            } catch (e) {
              // 静默处理失败
            }
          }
        }
      }

      // 预热结束
    });
  }

  /// 紧急预热：当即将显示的CG还未预热时立即预热
  Future<void> emergencyPreWarm({
    required String resourceId,
    required String pose,
    required String expression,
  }) async {
    try {
      await _preAnalyzer.precomposeCg(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );
    } catch (e) {
      // 静默失败
    }
  }

  /// 检查CG组合是否已经预热
  bool isCgPreWarmed({
    required String resourceId,
    required String pose,
    required String expression,
  }) {
    // 这里应该检查CgImageCompositor的缓存
    // 但为了简化，我们返回false，让系统主动预热
    return false;
  }

  /// 清理预测状态
  void clearPrediction() {
    _predictionGeneration++;
    _preAnalyzer.cancelAllTasks();
    _currentLabelStart = 0;
    _currentLabelEnd = 0;
    _currentPredictionStart = 0;
    _currentPredictionEnd = 0;
  }

  List<int> _limitRange(int start, int end, int currentIndex, int length) {
    int limitedStart = start;
    int limitedEnd = end;
    if (limitedEnd < limitedStart) {
      final tmp = limitedStart;
      limitedStart = limitedEnd;
      limitedEnd = tmp;
    }
    if (limitedEnd - limitedStart > _maxGlobalRange) {
      final halfWindow = _maxGlobalRange ~/ 2;
      limitedStart = _clampIndex(currentIndex - halfWindow, 0, length - 1);
      limitedEnd = _clampIndex(currentIndex + halfWindow, 0, length - 1);
    }
    return [limitedStart, limitedEnd];
  }

  int _clampIndex(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}
