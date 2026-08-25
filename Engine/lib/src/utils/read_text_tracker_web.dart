import 'dart:convert';
import 'dart:html' as html;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/read_text_identifier.dart';

/// 已读文本跟踪器 - Web平台版本
///
/// 使用localStorage存储已读记录，与桌面版本功能相同
class ReadTextTracker extends ChangeNotifier {
  static ReadTextTracker? _instance;
  static ReadTextTracker get instance => _instance ??= ReadTextTracker._();

  ReadTextTracker._();

  // 存储已读对话的标识符集合
  final Set<String> _readDialogues = <String>{};
  final Map<int, bool> _legacyIndexAgnosticMatchCache = <int, bool>{};

  static const int _legacyIndexScanRadius = 1024;

  // localStorage配置
  static const String _storageKey = 'saki_read_tracker';

  /// 初始化，从localStorage加载已读记录
  Future<void> initialize() async {
    _readDialogues.clear();
    _legacyIndexAgnosticMatchCache.clear();
    await _loadFromStorage();
    notifyListeners();
  }

  /// 标记对话为已读
  /// [speaker] 说话者名字（可选）
  /// [dialogue] 对话内容
  /// [scriptIndex] 脚本索引（用于更精确的标识）
  void markAsRead(String? speaker, String dialogue, int scriptIndex) {
    if (dialogue.trim().isEmpty) {
      return;
    }

    final indexedIdentifier = _createIdentifier(speaker, dialogue, scriptIndex);
    final contentIdentifier = stableReadContentHash(
      speaker,
      dialogue,
    ).toString();
    final changed =
        _readDialogues.add(indexedIdentifier) |
        _readDialogues.add(contentIdentifier);

    if (changed) {
      _saveToStorage();
      notifyListeners();
    }
  }

  /// 检查对话是否已读
  /// [speaker] 说话者名字（可选）
  /// [dialogue] 对话内容
  /// [scriptIndex] 脚本索引
  bool isRead(String? speaker, String dialogue, int scriptIndex) {
    if (dialogue.trim().isEmpty) return false;

    final identifier = _createIdentifier(speaker, dialogue, scriptIndex);
    final contentHash = stableReadContentHash(speaker, dialogue);
    return _readDialogues.contains(contentHash.toString()) ||
        _readDialogues.contains(identifier) ||
        _matchesLegacyIndexedRecord(
          speaker,
          dialogue,
          scriptIndex,
          contentHash,
        );
  }

  /// 创建对话的唯一标识符
  String _createIdentifier(String? speaker, String dialogue, int scriptIndex) {
    // 结合说话者、对话内容和脚本索引创建唯一标识
    final speakerPart = speaker ?? '';
    final content = '$speakerPart|$dialogue|$scriptIndex';

    // 使用简单的哈希算法减少存储空间
    return content.hashCode.toString();
  }

  bool _matchesLegacyIndexedRecord(
    String? speaker,
    String dialogue,
    int scriptIndex,
    int contentHash,
  ) {
    final cached = _legacyIndexAgnosticMatchCache[contentHash];
    if (cached != null) {
      return cached;
    }
    final firstIndex = scriptIndex > _legacyIndexScanRadius
        ? scriptIndex - _legacyIndexScanRadius
        : 0;
    final lastIndex = scriptIndex + _legacyIndexScanRadius;
    for (
      var candidateIndex = firstIndex;
      candidateIndex <= lastIndex;
      candidateIndex++
    ) {
      if (_readDialogues.contains(
        _createIdentifier(speaker, dialogue, candidateIndex),
      )) {
        _legacyIndexAgnosticMatchCache[contentHash] = true;
        return true;
      }
    }
    _legacyIndexAgnosticMatchCache[contentHash] = false;
    return false;
  }

  /// 获取已读对话数量
  int get readCount => _readDialogues.length;

  /// 清除所有已读记录
  Future<void> clearAllReadRecords() async {
    try {
      html.window.localStorage.remove(_storageKey);
      _readDialogues.clear();
      _legacyIndexAgnosticMatchCache.clear();
    } catch (e) {
      if (kEngineDebugMode) {
        print('清除已读记录失败: $e');
      }
      _readDialogues.clear();
      _legacyIndexAgnosticMatchCache.clear();
    }

    notifyListeners();
  }

  /// 从localStorage加载已读记录
  Future<void> _loadFromStorage() async {
    try {
      final jsonData = html.window.localStorage[_storageKey];
      if (jsonData != null) {
        final data = json.decode(jsonData) as Map<String, dynamic>;
        final readList = data['readDialogues'] as List<dynamic>?;
        if (readList != null) {
          _readDialogues.addAll(readList.cast<String>());
        }
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('加载已读记录失败: $e');
      }
    }
  }

  /// 保存已读记录到localStorage
  Future<void> _saveToStorage() async {
    try {
      final data = {
        'version': 1,
        'readCount': _readDialogues.length,
        'readDialogues': _readDialogues.toList(),
        'saveTime': DateTime.now().toIso8601String(),
      };
      html.window.localStorage[_storageKey] = json.encode(data);
    } catch (e) {
      if (kEngineDebugMode) {
        print('保存已读记录失败: $e');
      }
    }
  }

  /// 导出已读记录
  Map<String, dynamic> exportReadRecords() {
    return {
      'version': 1,
      'readCount': _readDialogues.length,
      'readDialogues': _readDialogues.toList(),
      'exportTime': DateTime.now().toIso8601String(),
      'storageType': 'local_storage', // 标记存储类型
    };
  }

  /// 导入已读记录
  Future<void> importReadRecords(Map<String, dynamic> data) async {
    try {
      final List<dynamic> readList = data['readDialogues'] ?? [];
      _readDialogues.clear();
      _readDialogues.addAll(readList.cast<String>());
      _legacyIndexAgnosticMatchCache.clear();
      await _saveToStorage();
      notifyListeners();
    } catch (e) {
      if (kEngineDebugMode) {
        print('导入已读记录失败: $e');
      }
    }
  }
}
