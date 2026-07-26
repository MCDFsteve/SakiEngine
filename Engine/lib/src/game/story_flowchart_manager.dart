import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:crypto/crypto.dart';
import 'package:sakiengine/src/game/unified_game_data_manager.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/config/project_info_manager.dart';
import 'package:sakiengine/src/game/save_load_manager.dart';

/// 剧情节点类型
enum StoryNodeType {
  chapter, // 章节开始
  branch, // 分支选择
  merge, // 分支汇合
  ending, // 结局
}

/// 剧情流程节点
class StoryFlowNode {
  final String id; // 唯一标识
  final String label; // 标签名（脚本中的label）
  final StoryNodeType type; // 节点类型
  final String displayName; // 显示名称（章节名/选项名）
  final int scriptIndex; // 脚本索引位置
  final String? chapterName; // 所属章节名
  final String? parentNodeId; // 父节点ID（来自哪个节点）
  final List<String> childNodeIds; // 子节点ID列表
  final String? autoSaveId; // 关联的自动存档ID
  final bool isUnlocked; // 是否已解锁（玩家是否到达过）
  final DateTime? firstReachedTime; // 首次到达时间
  final Map<String, dynamic>? metadata; // 额外元数据

  StoryFlowNode({
    required this.id,
    required this.label,
    required this.type,
    required this.displayName,
    required this.scriptIndex,
    this.chapterName,
    this.parentNodeId,
    this.childNodeIds = const [],
    this.autoSaveId,
    this.isUnlocked = false,
    this.firstReachedTime,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'label': label,
      'type': type.name,
      'displayName': displayName,
      'scriptIndex': scriptIndex,
      'chapterName': chapterName,
      'parentNodeId': parentNodeId,
      'childNodeIds': childNodeIds,
      'autoSaveId': autoSaveId,
      'isUnlocked': isUnlocked,
      'firstReachedTime': firstReachedTime?.toIso8601String(),
      'metadata': metadata,
    };
  }

  factory StoryFlowNode.fromJson(Map<String, dynamic> json) {
    return StoryFlowNode(
      id: json['id'] as String,
      label: json['label'] as String,
      type: StoryNodeType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => StoryNodeType.chapter,
      ),
      displayName: json['displayName'] as String,
      scriptIndex: json['scriptIndex'] as int,
      chapterName: json['chapterName'] as String?,
      parentNodeId: json['parentNodeId'] as String?,
      childNodeIds: (json['childNodeIds'] as List?)?.cast<String>() ?? [],
      autoSaveId: json['autoSaveId'] as String?,
      isUnlocked: json['isUnlocked'] as bool? ?? false,
      firstReachedTime: json['firstReachedTime'] != null
          ? DateTime.parse(json['firstReachedTime'] as String)
          : null,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  StoryFlowNode copyWith({
    String? id,
    String? label,
    StoryNodeType? type,
    String? displayName,
    int? scriptIndex,
    String? chapterName,
    String? parentNodeId,
    List<String>? childNodeIds,
    String? autoSaveId,
    bool? isUnlocked,
    DateTime? firstReachedTime,
    Map<String, dynamic>? metadata,
  }) {
    return StoryFlowNode(
      id: id ?? this.id,
      label: label ?? this.label,
      type: type ?? this.type,
      displayName: displayName ?? this.displayName,
      scriptIndex: scriptIndex ?? this.scriptIndex,
      chapterName: chapterName ?? this.chapterName,
      parentNodeId: parentNodeId ?? this.parentNodeId,
      childNodeIds: childNodeIds ?? this.childNodeIds,
      autoSaveId: autoSaveId ?? this.autoSaveId,
      isUnlocked: isUnlocked ?? this.isUnlocked,
      firstReachedTime: firstReachedTime ?? this.firstReachedTime,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// 剧情流程图管理器
class StoryFlowchartManager extends ChangeNotifier {
  static final StoryFlowchartManager _instance =
      StoryFlowchartManager._internal();
  factory StoryFlowchartManager() => _instance;
  StoryFlowchartManager._internal();

  // 所有节点（key: nodeId）
  final Map<String, StoryFlowNode> _nodes = {};

  // 根节点ID列表（章节起点）
  final List<String> _rootNodeIds = [];

  // 当前激活的节点ID
  String? _currentNodeId;

  // 自动存档前缀
  static const String autoSavePrefix = 'auto_story_';

  /// 获取所有节点
  Map<String, StoryFlowNode> get nodes => Map.unmodifiable(_nodes);

  /// 获取根节点列表
  List<StoryFlowNode> get rootNodes {
    return _rootNodeIds
        .map((id) => _nodes[id])
        .whereType<StoryFlowNode>()
        .toList();
  }

  /// 获取当前节点
  StoryFlowNode? get currentNode {
    return _currentNodeId != null ? _nodes[_currentNodeId] : null;
  }

  /// 初始化（从持久化存储加载）
  Future<void> initialize() async {
    try {
      final dataManager = UnifiedGameDataManager();
      final savedData = dataManager.getStringVariable(
        'story_flowchart',
        defaultValue: '',
      );

      if (savedData.isNotEmpty) {
        final jsonData = jsonDecode(savedData) as Map<String, dynamic>;

        // 加载节点
        if (jsonData['nodes'] != null) {
          final nodesMap = jsonData['nodes'] as Map<String, dynamic>;
          _nodes.clear();
          nodesMap.forEach((key, value) {
            _nodes[key] = StoryFlowNode.fromJson(value as Map<String, dynamic>);
          });
        }

        // 加载根节点列表
        if (jsonData['rootNodeIds'] != null) {
          _rootNodeIds.clear();
          _rootNodeIds.addAll((jsonData['rootNodeIds'] as List).cast<String>());
        }

        // 加载当前节点
        _currentNodeId = jsonData['currentNodeId'] as String?;
      }

      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 初始化完成，加载了 ${_nodes.length} 个节点');
      }
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 初始化失败: $e');
      }
    }
  }

  /// 保存到持久化存储
  Future<void> save() async {
    try {
      final jsonData = {
        'nodes': _nodes.map((key, value) => MapEntry(key, value.toJson())),
        'rootNodeIds': _rootNodeIds,
        'currentNodeId': _currentNodeId,
      };

      final dataManager = UnifiedGameDataManager();
      final projectName = await ProjectInfoManager().getAppName();
      await dataManager.setStringVariable(
        'story_flowchart',
        jsonEncode(jsonData),
        projectName,
      );

      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 保存成功，共 ${_nodes.length} 个节点');
      }
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 保存失败: $e');
      }
    }
  }

  /// 添加或更新节点
  Future<void> addOrUpdateNode(StoryFlowNode node) async {
    _nodes[node.id] = node;

    // 如果是章节节点且没有父节点，添加到根节点列表
    if (node.type == StoryNodeType.chapter && node.parentNodeId == null) {
      if (!_rootNodeIds.contains(node.id)) {
        _rootNodeIds.add(node.id);
      }
    }

    // 更新父节点的子节点列表
    if (node.parentNodeId != null) {
      final parentNode = _nodes[node.parentNodeId];
      if (parentNode != null) {
        final updatedChildren = List<String>.from(parentNode.childNodeIds);
        if (!updatedChildren.contains(node.id)) {
          updatedChildren.add(node.id);
          _nodes[node.parentNodeId!] = parentNode.copyWith(
            childNodeIds: updatedChildren,
          );
        }
      }
    }

    await save();
    notifyListeners();
  }

  /// Replaces a complete precomputed graph and persists it once.
  Future<void> replaceGraph(
    Iterable<StoryFlowNode> nodes, {
    required Iterable<String> rootIds,
  }) async {
    _nodes
      ..clear()
      ..addEntries(nodes.map((node) => MapEntry(node.id, node)));
    _rootNodeIds
      ..clear()
      ..addAll(rootIds.where(_nodes.containsKey));
    _currentNodeId = null;
    await save();
    notifyListeners();
  }

  /// 解锁节点（玩家到达该节点时调用）
  Future<void> unlockNode(String nodeId, {String? autoSaveId}) async {
    final node = _nodes[nodeId];
    if (node != null && !node.isUnlocked) {
      _nodes[nodeId] = node.copyWith(
        isUnlocked: true,
        firstReachedTime: DateTime.now(),
        autoSaveId: autoSaveId ?? node.autoSaveId,
      );

      _currentNodeId = nodeId;
      await save();
      notifyListeners();

      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 解锁节点: ${node.displayName} ($nodeId)');
      }
    }
  }

  /// 创建自动存档并关联到节点
  Future<String?> createAutoSaveForNode(
    String nodeId,
    SaveSlot saveSlot,
  ) async {
    try {
      final node = _nodes[nodeId];
      if (node == null) return null;

      // 使用节点ID作为文件名（语言无关）
      final autoSaveId = '${autoSavePrefix}$nodeId';

      // 直接保存为文件（参考 SaveLoadManager 的实现）
      final saveLoadManager = SaveLoadManager();
      final directory = await saveLoadManager.getSavesDirectory();
      final file = File('$directory/$autoSaveId.sakisav');

      final binaryData = saveSlot.toBinary();
      await SaveLoadManager.writeBinaryFileAtomically(file, binaryData);

      // 更新节点关联
      _nodes[nodeId] = node.copyWith(autoSaveId: autoSaveId);
      await save();

      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 为节点 $nodeId (${node.displayName}) 创建自动存档文件: $autoSaveId.sakisav');
      }

      return autoSaveId;
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[StoryFlowchart] 创建自动存档失败: $e');
      }
      return null;
    }
  }

  /// 获取节点的子节点列表
  List<StoryFlowNode> getChildNodes(String nodeId) {
    final node = _nodes[nodeId];
    if (node == null) return [];

    return node.childNodeIds
        .map((id) => _nodes[id])
        .whereType<StoryFlowNode>()
        .toList();
  }

  /// 获取节点的父节点
  StoryFlowNode? getParentNode(String nodeId) {
    final node = _nodes[nodeId];
    if (node?.parentNodeId == null) return null;
    return _nodes[node!.parentNodeId];
  }

  /// 获取某个章节下的所有节点
  List<StoryFlowNode> getNodesInChapter(String chapterName) {
    return _nodes.values
        .where((node) => node.chapterName == chapterName)
        .toList();
  }

  /// 获取所有已解锁的节点
  List<StoryFlowNode> getUnlockedNodes() {
    return _nodes.values.where((node) => node.isUnlocked).toList();
  }

  /// 获取所有结局节点
  List<StoryFlowNode> getEndingNodes() {
    return _nodes.values
        .where((node) => node.type == StoryNodeType.ending)
        .toList();
  }

  /// 获取已达成的结局数量
  int getUnlockedEndingsCount() {
    return getEndingNodes().where((node) => node.isUnlocked).length;
  }

  /// 获取总结局数量
  int getTotalEndingsCount() {
    return getEndingNodes().length;
  }

  /// 清空所有数据（用于重置）
  Future<void> clearAll() async {
    _nodes.clear();
    _rootNodeIds.clear();
    _currentNodeId = null;

    final dataManager = UnifiedGameDataManager();
    final projectName = await ProjectInfoManager().getAppName();
    await dataManager.setStringVariable('story_flowchart', '', projectName);

    notifyListeners();

    if (kEngineDebugMode) {
      //print('[StoryFlowchart] 已清空所有数据');
    }
  }

  /// 导出流程图数据（用于调试）
  Map<String, dynamic> exportData() {
    return {
      'nodes': _nodes.map((key, value) => MapEntry(key, value.toJson())),
      'rootNodeIds': _rootNodeIds,
      'currentNodeId': _currentNodeId,
      'stats': {
        'totalNodes': _nodes.length,
        'unlockedNodes': getUnlockedNodes().length,
        'totalEndings': getTotalEndingsCount(),
        'unlockedEndings': getUnlockedEndingsCount(),
      },
    };
  }
}
