import 'dart:io';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/game/story_flowchart_manager.dart';
import 'package:sakiengine/src/game/script_merger.dart';
import 'package:sakiengine/src/game/save_load_manager.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/localization/script_text_localizer.dart';
import 'package:sakiengine/src/native/native_runtime_index.dart';

/// 剧情流程图分析器 - 完全重写版本
class StoryFlowchartAnalyzer {
  static Future<void>? _sharedAnalysis;

  final StoryFlowchartManager _manager = StoryFlowchartManager();
  final ScriptMerger _scriptMerger = ScriptMerger();
  final LocalizationManager _localization = LocalizationManager();

  /// 分析整个脚本，构建流程图
  Future<void> analyzeScript() => _sharedAnalysis ??= _analyzeScript();

  Future<void> _analyzeScript() async {
    try {
      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 开始分析脚本...');
      }

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 正在获取合并后的脚本...');
      }

      // 获取合并后的脚本
      final script = await _scriptMerger.getMergedScript();
      final nodes = script.children;

      final nativeIndex = await buildRuntimeIndexNatively(nodes);
      if (nativeIndex != null && nativeIndex.flowNodes.isNotEmpty) {
        try {
          await _applyNativeIndex(nativeIndex);
          await _restoreUnlockStatusFromAutoSaves();
          if (kEngineDebugMode) {
            print(
              '[SAKI_NATIVE][FLOW] nodes=${nativeIndex.flowNodes.length} '
              'compact=${nativeIndex.compactBytes}B '
              'native=${nativeIndex.elapsedMicros / 1000.0}ms',
            );
          }
        } finally {
          nativeIndex.dispose();
        }
        return;
      }
      nativeIndex?.dispose();

      // Native is optional on Web and in unit-test runners.
      await _manager.clearAll();

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 获取到 ${nodes.length} 个节点');
      }

      // 建立label索引
      final Map<String, int> labelIndex = {};
      for (int i = 0; i < nodes.length; i++) {
        if (nodes[i] is LabelNode) {
          labelIndex[(nodes[i] as LabelNode).name] = i;
        }
      }

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 建立label索引完成，共 ${labelIndex.length} 个label');
      }

      // 第一步：预先检测汇合点（不创建节点，只返回哪些label是汇合点）
      final mergeLabels = _preDetectMergePoints(nodes, labelIndex);

      // 第二步：分析章节和分支
      String? currentChapter; // 章节显示名称（用于chapterName字段）
      String? currentChapterId; // 章节ID（用于父节点引用）
      for (int i = 0; i < nodes.length; i++) {
        final node = nodes[i];

        // 检查当前位置是否是汇合点的label位置
        if (node is LabelNode && mergeLabels.containsKey(node.name)) {
          // 在这个位置创建汇合点节点
          await _createMergePointNode(
            node.name,
            mergeLabels[node.name]!,
            currentChapter,
            currentChapterId,
          );
        }

        // 检测章节
        if (node is BackgroundNode && _isChapterBackground(node.background)) {
          currentChapter = _extractChapterName(node.background);
          currentChapterId = _extractChapterId(node.background);
          await _createChapterNode(currentChapter, i, nodes, labelIndex);
        }
        // 检测分支
        else if (node is MenuNode) {
          await _createBranchNode(
            i,
            node,
            nodes,
            labelIndex,
            currentChapter,
            currentChapterId,
            mergeLabels,
          );
        }
        // 检测结局
        else if (node is ReturnNode) {
          await _createEndingNode(
            i,
            nodes,
            labelIndex,
            currentChapter,
            currentChapterId,
            mergeLabels,
          );
        }
      }

      // 第三步：创建实际的汇合点节点，并收集它们的父节点ID
      await _createMergePointNodes(nodes, labelIndex, mergeLabels);

      // 第四步：处理汇合点之后的跳转（连接到结局或下一章）
      await _connectMergePointsToNextNodes(nodes, labelIndex, mergeLabels);

      // 第五步：为每个章节添加"章节末尾"节点
      await _createChapterEndNodes(nodes, labelIndex);

      // 第六步：扫描自动存档文件，恢复节点解锁状态
      await _restoreUnlockStatusFromAutoSaves();

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 脚本分析完成');
        //print('[FlowchartAnalyzer] 统计信息: ${_manager.exportData()['stats']}');
      }
    } catch (e, stack) {
      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 分析失败: $e');
        //print('[FlowchartAnalyzer] 堆栈跟踪:');
      }
      print(stack);
    }
  }

  Future<void> _applyNativeIndex(NativeRuntimeIndex index) async {
    final nodes = <StoryFlowNode>[];
    for (final native in index.flowNodes) {
      final type = switch (native.kind) {
        'chapter' => StoryNodeType.chapter,
        'merge' => StoryNodeType.merge,
        'ending' => StoryNodeType.ending,
        _ => StoryNodeType.branch,
      };
      final chapterName = native.chapterName == null
          ? null
          : _extractChapterName(native.chapterName);
      final displayName = switch (type) {
        StoryNodeType.chapter => _extractChapterName(native.displayName),
        StoryNodeType.merge => _localization.t('flowchart.nodeType.merge'),
        StoryNodeType.ending =>
          native.displayName.startsWith('ending:')
              ? '结局: ${native.label}'
              : native.displayName,
        StoryNodeType.branch =>
          native.branchText == null
              ? _localization.t('flowchart.nodeType.branch')
              : ScriptTextLocalizer.resolve(native.displayName),
      };
      nodes.add(
        StoryFlowNode(
          id: native.id,
          label: native.label,
          type: type,
          displayName: displayName,
          scriptIndex: native.scriptIndex,
          chapterName: chapterName,
          parentNodeId: native.parentId,
          childNodeIds: native.childIds,
          metadata: {
            if (native.branchText != null)
              'branchText': ScriptTextLocalizer.resolve(native.branchText!),
            if (native.parentIds.isNotEmpty) 'parentIds': native.parentIds,
            if (native.parentIds.isNotEmpty)
              'parentCount': native.parentIds.length,
          },
        ),
      );
    }
    await _manager.replaceGraph(nodes, rootIds: index.rootIds);
  }

  /// 创建章节节点
  Future<void> _createChapterNode(
    String chapterName,
    int index,
    List<SksNode> nodes,
    Map<String, int> labelIndex,
  ) async {
    final label =
        _findNearestLabel(index, nodes, labelIndex) ?? 'chapter_$index';

    // 从背景名称获取语言无关的章节ID
    final node = nodes[index];
    String chapterId = 'chapter_$index';
    if (node is BackgroundNode) {
      chapterId = _extractChapterId(node.background);
    }

    final nodeId = chapterId;

    final chapterNode = StoryFlowNode(
      id: nodeId,
      label: label,
      type: StoryNodeType.chapter,
      displayName: chapterName,
      scriptIndex: index,
      chapterName: chapterName,
      parentNodeId: null, // 章节是根节点
    );

    await _manager.addOrUpdateNode(chapterNode);

    if (kEngineDebugMode) {
      //print('[FlowchartAnalyzer] 创建章节: $chapterName (ID: $nodeId) at $index');
    }
  }

  /// 创建分支节点
  Future<void> _createBranchNode(
    int index,
    MenuNode menuNode,
    List<SksNode> nodes,
    Map<String, int> labelIndex,
    String? currentChapter,
    String? currentChapterId,
    Map<String, int> mergeLabels,
  ) async {
    final label = _findNearestLabel(index, nodes, labelIndex) ?? 'menu_$index';

    // 跳过捉迷藏相关的分支（cp1_002 中的石头剪刀布）
    if (_isHideAndSeekBranch(label, menuNode)) {
      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 跳过捉迷藏分支: $label');
      }
      return;
    }

    final branchId = 'branch_$index';

    // 找到父节点（传入mergeLabels来判断，使用currentChapterId）
    final parentId = _findParentNode(label, currentChapterId, mergeLabels);

    final branchNode = StoryFlowNode(
      id: branchId,
      label: label,
      type: StoryNodeType.branch,
      displayName: _localization.t('flowchart.nodeType.branch'),
      scriptIndex: index,
      chapterName: currentChapter,
      parentNodeId: parentId,
    );

    await _manager.addOrUpdateNode(branchNode);

    // 创建选项节点
    for (final choice in menuNode.choices) {
      final optionId = 'option_${branchId}_${choice.targetLabel}';
      final optionIndex = labelIndex[choice.targetLabel];
      final localizedChoiceText = ScriptTextLocalizer.resolve(choice.text);

      if (optionIndex != null) {
        final optionNode = StoryFlowNode(
          id: optionId,
          label: choice.targetLabel,
          type: StoryNodeType.branch,
          displayName: localizedChoiceText,
          scriptIndex: optionIndex,
          chapterName: currentChapter,
          parentNodeId: branchId,
          metadata: {'branchText': localizedChoiceText},
        );

        await _manager.addOrUpdateNode(optionNode);
      }
    }

    if (kEngineDebugMode) {
      //print('[FlowchartAnalyzer] 创建分支: $label at $index, 父节点: $parentId');
    }
  }

  /// 判断是否为捉迷藏相关分支（需要跳过）
  bool _isHideAndSeekBranch(String label, MenuNode menuNode) {
    // 检查是否在 cp1_002 的捉迷藏部分
    if (label.startsWith('cp1_002')) {
      // 检查选项文本是否包含"剪刀"、"石头"、"布"
      for (final choice in menuNode.choices) {
        final candidateText =
            '${choice.text} ${ScriptTextLocalizer.resolve(choice.text)}';
        if (candidateText.contains('剪刀') ||
            candidateText.contains('石头') ||
            candidateText.contains('布') ||
            candidateText.contains('出剪刀') ||
            candidateText.contains('出石头') ||
            candidateText.contains('出布')) {
          return true;
        }
      }
    }
    return false;
  }

  /// 查找父节点
  String? _findParentNode(
    String currentLabel,
    String? currentChapterId,
    Map<String, int> mergeLabels,
  ) {
    // 检查当前label是否是汇合点
    if (mergeLabels.containsKey(currentLabel)) {
      return 'merge_$currentLabel'; // 父节点是汇合点
    }

    // 否则返回章节节点ID（语言无关）
    if (currentChapterId != null) {
      return currentChapterId;
    }

    return null;
  }

  /// 创建单个汇合点节点（在遍历到label时立即创建）
  Future<void> _createMergePointNode(
    String label,
    int scriptIndex,
    String? currentChapter,
    String? currentChapterId,
  ) async {
    final mergeId = 'merge_$label';

    // 查找这个汇合点的所有父节点（已创建的选项节点）
    final parents = <String>[];
    final allNodes = _manager.nodes;
    for (final node in allNodes.values) {
      if (node.type == StoryNodeType.branch &&
          node.metadata != null &&
          node.metadata!.containsKey('branchText') &&
          node.label == label) {
        // 这是一个跳转到这个label的选项节点
        parents.add(node.id);
      }
    }

    if (parents.isEmpty) {
      // 还没有找到任何父节点，说明汇合点在选项之前被遍历到
      // 先创建一个临时的汇合点，稍后更新父节点
      final mergeNode = StoryFlowNode(
        id: mergeId,
        label: label,
        type: StoryNodeType.merge,
        displayName: _localization.t('flowchart.nodeType.merge'),
        scriptIndex: scriptIndex,
        chapterName: currentChapter,
        parentNodeId: null, // 暂时没有父节点
        metadata: {'parentCount': 0, 'parentIds': <String>[]},
      );

      await _manager.addOrUpdateNode(mergeNode);

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 预创建汇合点: $label at $scriptIndex (稍后更新父节点)');
      }
    } else {
      // 找到了父节点，直接创建完整的汇合点
      final mergeNode = StoryFlowNode(
        id: mergeId,
        label: label,
        type: StoryNodeType.merge,
        displayName: _localization.t('flowchart.nodeType.merge'),
        scriptIndex: scriptIndex,
        chapterName: currentChapter,
        parentNodeId: parents.first,
        metadata: {
          'parentCount': parents.length,
          'parentIds': parents,
          'isMergePoint': true, // 标记为汇合点
        },
      );

      await _manager.addOrUpdateNode(mergeNode);

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 创建汇合点: $label (来自 ${parents.length} 个选项: $parents)');
      }
    }
  }

  /// 更新汇合点的父节点信息（在所有节点创建完成后）
  Future<void> _createMergePointNodes(
    List<SksNode> nodes,
    Map<String, int> labelIndex,
    Map<String, int> mergeLabels,
  ) async {
    // 建立label到Jump的映射：从label开始，找到它下一个Jump跳转的目标
    final Map<String, String> labelToJumpTarget = {};

    for (int i = 0; i < nodes.length; i++) {
      if (nodes[i] is LabelNode) {
        final currentLabel = (nodes[i] as LabelNode).name;
        // 从这个label开始，找下一个JumpNode
        for (int j = i + 1; j < nodes.length; j++) {
          if (nodes[j] is LabelNode) {
            // 遇到新label，停止
            break;
          }
          if (nodes[j] is JumpNode) {
            // 找到jump，记录映射
            labelToJumpTarget[currentLabel] =
                (nodes[j] as JumpNode).targetLabel;
            break;
          }
        }
      }
    }

    if (kEngineDebugMode) {
      //print('[FlowchartAnalyzer] Label到Jump目标映射完成，共 ${labelToJumpTarget.length} 个映射');
    }

    // 收集每个汇合点的父节点ID（来自哪些选项）
    final Map<String, List<String>> mergeParents = {};

    for (final mergeLabel in mergeLabels.keys) {
      mergeParents[mergeLabel] = [];
    }

    // 遍历所有已创建的选项节点，通过label追踪找到最终跳转目标
    final allNodes = _manager.nodes;
    for (final node in allNodes.values) {
      if (node.type == StoryNodeType.branch &&
          node.metadata != null &&
          node.metadata!.containsKey('branchText')) {
        // 这是一个选项节点，它的label是choice.targetLabel
        final choiceLabel = node.label;
        // 查找这个label最终跳转到哪里
        final finalTarget = labelToJumpTarget[choiceLabel];

        if (finalTarget != null && mergeParents.containsKey(finalTarget)) {
          mergeParents[finalTarget]!.add(node.id);
        }
      }
    }

    // 更新已创建的汇合点节点
    for (final entry in mergeLabels.entries) {
      final label = entry.key;
      final parents = mergeParents[label] ?? [];

      if (parents.length >= 2) {
        final mergeId = 'merge_$label';
        final existingNode = allNodes[mergeId];

        if (existingNode != null &&
            (existingNode.metadata?['parentCount'] ?? 0) == 0) {
          // 这是一个需要更新的汇合点
          final updatedNode = existingNode.copyWith(
            parentNodeId: parents.first,
            metadata: {'parentCount': parents.length, 'parentIds': parents},
          );

          await _manager.addOrUpdateNode(updatedNode);

          if (kEngineDebugMode) {
            //print('[FlowchartAnalyzer] 更新汇合点: $label (来自 ${parents.length} 个选项: $parents)');
          }
        }
      }
    }
  }

  /// 创建结局节点
  Future<void> _createEndingNode(
    int returnIndex,
    List<SksNode> nodes,
    Map<String, int> labelIndex,
    String? currentChapter,
    String? currentChapterId,
    Map<String, int> mergeLabels,
  ) async {
    final lastSceneIndex = _findLastSceneBeforeReturn(returnIndex, nodes);
    if (lastSceneIndex != null) {
      final label =
          _findNearestLabel(lastSceneIndex, nodes, labelIndex) ??
          'ending_$lastSceneIndex';
      final endingId = 'ending_$lastSceneIndex';

      // 找到父节点（传入mergeLabels来判断，使用currentChapterId）
      final parentId = _findParentNode(label, currentChapterId, mergeLabels);

      // 只有当父节点不是章节根节点时，才创建结局节点
      // 如果父节点是章节根节点，说明这个return不是分支结局，而是普通剧情流程
      if (parentId != null && !parentId.startsWith('chapter_')) {
        final endingNode = StoryFlowNode(
          id: endingId,
          label: label,
          type: StoryNodeType.ending,
          displayName: '结局: $label',
          scriptIndex: lastSceneIndex,
          chapterName: currentChapter,
          parentNodeId: parentId,
        );

        await _manager.addOrUpdateNode(endingNode);

        if (kEngineDebugMode) {
          //print('[FlowchartAnalyzer] 创建结局: $label at $lastSceneIndex');
        }
      } else {
        if (kEngineDebugMode) {
          //print('[FlowchartAnalyzer] 跳过非分支结局: $label (父节点: $parentId)');
        }
      }
    }
  }

  /// 处理汇合点之后的跳转（连接到结局或下一章）
  Future<void> _connectMergePointsToNextNodes(
    List<SksNode> nodes,
    Map<String, int> labelIndex,
    Map<String, int> mergeLabels,
  ) async {
    final allNodes = _manager.nodes;

    // 遍历所有汇合点
    for (final entry in mergeLabels.entries) {
      final mergeLabel = entry.key;
      final mergeIndex = entry.value;
      final mergeId = 'merge_$mergeLabel';
      final mergeNode = allNodes[mergeId];

      if (mergeNode == null) continue;

      // 从汇合点开始，查找下一个关键节点（return、jump、menu）
      bool foundNextNode = false;

      for (int i = mergeIndex + 1; i < nodes.length; i++) {
        final node = nodes[i];

        // 遇到新的 label，停止（说明进入了其他模块）
        if (node is LabelNode && node.name != mergeLabel) {
          break;
        }

        // 找到 return，创建结局节点并连接
        if (node is ReturnNode) {
          final endingIndex = _findLastSceneBeforeReturn(i, nodes);
          if (endingIndex != null) {
            final endingLabel =
                _findNearestLabel(endingIndex, nodes, labelIndex) ??
                'ending_$endingIndex';
            final endingId = 'ending_$endingIndex';

            // 检查这个结局节点是否已经存在
            if (!allNodes.containsKey(endingId)) {
              final endingNode = StoryFlowNode(
                id: endingId,
                label: endingLabel,
                type: StoryNodeType.ending,
                displayName: '结局: $endingLabel',
                scriptIndex: endingIndex,
                chapterName: mergeNode.chapterName,
                parentNodeId: mergeId,
              );

              await _manager.addOrUpdateNode(endingNode);

              if (kEngineDebugMode) {
                //print('[FlowchartAnalyzer] 汇合点 $mergeLabel 连接到结局: $endingLabel');
              }
            }
          }
          foundNextNode = true;
          break;
        }

        // 找到 jump，连接到跳转目标
        if (node is JumpNode) {
          final targetLabel = node.targetLabel;

          // 检查跳转目标是否是章节
          if (allNodes.containsKey(
            'chapter_${_extractChapterName(targetLabel)}',
          )) {
            // 跳转到下一章，不需要创建新节点
            if (kEngineDebugMode) {
              //print('[FlowchartAnalyzer] 汇合点 $mergeLabel 跳转到下一章: $targetLabel');
            }
          }

          foundNextNode = true;
          break;
        }

        // 找到新的 menu，说明有新分支，不需要处理
        if (node is MenuNode) {
          foundNextNode = true;
          break;
        }
      }

      if (!foundNextNode && kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 汇合点 $mergeLabel 之后没有找到明确的结束点');
      }
    }
  }

  Future<void> _createChapterEndNodes(
    List<SksNode> nodes,
    Map<String, int> labelIndex,
  ) async {
    // 获取所有章节节点
    final allNodes = _manager.nodes;
    final chapterNodes = allNodes.values
        .where((n) => n.type == StoryNodeType.chapter)
        .toList();

    for (final chapterNode in chapterNodes) {
      // 找到该章节下的所有节点
      final chapterNodesInSameChapter = allNodes.values
          .where(
            (n) =>
                n.chapterName == chapterNode.displayName &&
                n.id != chapterNode.id,
          )
          .toList();

      if (chapterNodesInSameChapter.isEmpty) continue;

      // 找到最后一个节点（scriptIndex最大的）
      chapterNodesInSameChapter.sort(
        (a, b) => a.scriptIndex.compareTo(b.scriptIndex),
      );
      final lastNode = chapterNodesInSameChapter.last;

      // 检查最后一个节点是否有子节点
      final hasChildren = lastNode.childNodeIds.isNotEmpty;

      if (!hasChildren) {
        // 最后一个节点没有子节点，创建章节末尾节点
        // 使用章节ID（去掉"chapter_"前缀）+ "_end"作为末尾节点ID
        final chapterIdWithoutPrefix = chapterNode.id.replaceFirst(
          'chapter_',
          '',
        );
        final endId = 'chapter_end_$chapterIdWithoutPrefix';

        final endNode = StoryFlowNode(
          id: endId,
          label: 'end_${chapterNode.displayName}',
          type: StoryNodeType.ending,
          displayName: '${chapterNode.displayName}末尾',
          scriptIndex: lastNode.scriptIndex + 1,
          chapterName: chapterNode.displayName,
          parentNodeId: lastNode.id,
        );

        await _manager.addOrUpdateNode(endNode);

        if (kEngineDebugMode) {
          //print('[FlowchartAnalyzer] 创建章节末尾节点: ${chapterNode.displayName}末尾 (ID: $endId, 父节点: ${lastNode.id})');
        }
      }
    }
  }

  /// 预先检测汇合点（分析哪些label有多个跳转来源）
  Map<String, int> _preDetectMergePoints(
    List<SksNode> nodes,
    Map<String, int> labelIndex,
  ) {
    // 统计每个label被JumpNode跳转到的次数
    final Map<String, int> labelJumpCount = {};

    for (int i = 0; i < nodes.length; i++) {
      final node = nodes[i];

      // 分析JumpNode（真正的跳转）
      if (node is JumpNode) {
        final targetLabel = node.targetLabel;
        labelJumpCount[targetLabel] = (labelJumpCount[targetLabel] ?? 0) + 1;
      }
    }

    // 返回跳转次数>=2的label（这些是汇合点）
    final mergeLabels = <String, int>{};
    labelJumpCount.forEach((label, count) {
      if (count >= 2) {
        mergeLabels[label] = labelIndex[label] ?? -1;
      }
    });

    if (kEngineDebugMode) {
      //print('[FlowchartAnalyzer] 预检测到 ${mergeLabels.length} 个汇合点: ${mergeLabels.keys.toList()}');
    }

    return mergeLabels;
  }

  /// 判断是否为章节背景
  bool _isChapterBackground(String? bgName) {
    if (bgName == null) return false;
    final lower = bgName.toLowerCase();
    return lower.contains('chapter') ||
        lower.contains('prologue') ||
        lower.contains('epilogue') ||
        RegExp(r'\bch\d+\b').hasMatch(lower) ||
        RegExp(r'\bep\d+\b').hasMatch(lower);
  }

  /// 提取章节名（用于显示）
  String _extractChapterName(String? bgName) {
    if (bgName == null) return 'Unknown';

    final chapterMatch = RegExp(
      r'chapter[_\s-]?(\d+)',
      caseSensitive: false,
    ).firstMatch(bgName);
    if (chapterMatch != null) {
      final chapterNum = chapterMatch.group(1)!;
      return _localization.t('flowchart.chapter', params: {'num': chapterNum});
    }

    final chMatch = RegExp(
      r'\bch(\d+)\b',
      caseSensitive: false,
    ).firstMatch(bgName);
    if (chMatch != null) {
      final chapterNum = chMatch.group(1)!;
      return _localization.t('flowchart.chapter', params: {'num': chapterNum});
    }

    if (bgName.toLowerCase().contains('prologue')) {
      return _localization.t('flowchart.prologue');
    }

    if (bgName.toLowerCase().contains('epilogue')) {
      return _localization.t('flowchart.epilogue');
    }

    return bgName;
  }

  /// 提取章节ID（语言无关，用于节点ID）
  String _extractChapterId(String? bgName) {
    if (bgName == null) return 'unknown';

    final chapterMatch = RegExp(
      r'chapter[_\s-]?(\d+)',
      caseSensitive: false,
    ).firstMatch(bgName);
    if (chapterMatch != null) {
      return 'chapter_${chapterMatch.group(1)}';
    }

    final chMatch = RegExp(
      r'\bch(\d+)\b',
      caseSensitive: false,
    ).firstMatch(bgName);
    if (chMatch != null) {
      return 'chapter_${chMatch.group(1)}';
    }

    if (bgName.toLowerCase().contains('prologue')) {
      return 'chapter_prologue';
    }

    if (bgName.toLowerCase().contains('epilogue')) {
      return 'chapter_epilogue';
    }

    return 'chapter_$bgName';
  }

  /// 查找最近的label
  String? _findNearestLabel(
    int index,
    List<SksNode> nodes,
    Map<String, int> labelIndex,
  ) {
    for (int i = index; i >= 0; i--) {
      if (nodes[i] is LabelNode) {
        return (nodes[i] as LabelNode).name;
      }
    }
    return null;
  }

  /// 查找return前的最后一个scene
  int? _findLastSceneBeforeReturn(int returnIndex, List<SksNode> nodes) {
    for (int i = returnIndex - 1; i >= 0; i--) {
      final node = nodes[i];
      if (node is BackgroundNode || node is MovieNode) {
        return i;
      }
    }
    return null;
  }

  /// 清空并重新分析
  Future<void> resetAndAnalyze() async {
    _sharedAnalysis = null;
    await analyzeScript();
  }

  /// 扫描自动存档文件，恢复节点解锁状态
  Future<void> _restoreUnlockStatusFromAutoSaves() async {
    try {
      final saveLoadManager = SaveLoadManager();
      final directory = await saveLoadManager.getSavesDirectory();
      final dir = Directory(directory);

      if (!await dir.exists()) {
        if (kEngineDebugMode) {
          //print('[FlowchartAnalyzer] 存档目录不存在，跳过恢复解锁状态');
        }
        return;
      }

      // 扫描目录中的所有自动存档文件
      final autoSaveFiles = <String>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.sakisav')) {
          final fileName = entity.path
              .split(Platform.pathSeparator)
              .last
              .replaceAll('.sakisav', '');
          if (fileName.startsWith(StoryFlowchartManager.autoSavePrefix)) {
            autoSaveFiles.add(fileName);
          }
        }
      }

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 找到 ${autoSaveFiles.length} 个自动存档文件: $autoSaveFiles');
      }

      // 根据自动存档文件名，找到对应的节点并标记为已解锁
      int unlockedCount = 0;
      for (final autoSaveId in autoSaveFiles) {
        // 从文件名提取nodeId (移除前缀 "auto_story_")
        final nodeId = autoSaveId.replaceFirst(
          StoryFlowchartManager.autoSavePrefix,
          '',
        );

        // 查找对应的节点（同时支持两种匹配方式）
        final allNodes = _manager.nodes;
        StoryFlowNode? node;

        // 方式1：直接通过node.id匹配（适用于branch_、chapter_end_等生成的ID）
        node = allNodes[nodeId];

        // 方式2：如果方式1没找到，尝试通过node.label匹配（适用于章节开始等使用label作为nodeId的情况）
        if (node == null) {
          for (final n in allNodes.values) {
            if (n.label == nodeId && !n.isUnlocked) {
              node = n;
              break;
            }
          }
        }

        if (node != null && !node.isUnlocked) {
          // 解锁节点
          await _manager.unlockNode(node.id, autoSaveId: autoSaveId);
          unlockedCount++;

          if (kEngineDebugMode) {
            //print('[FlowchartAnalyzer] 根据自动存档 $autoSaveId 解锁节点: ${node.displayName} (${node.id})');
          }
        }
      }

      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 共恢复 $unlockedCount 个节点的解锁状态');
      }
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[FlowchartAnalyzer] 恢复解锁状态失败: $e');
      }
    }
  }
}
