import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/read_text_identifier.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/native/saki_native_runtime.dart';

/// 已读文本跟踪器
///
/// 记录哪些对话文本已经被用户阅读过，用于实现"跳过已读文本"功能
/// 与现有的Ctrl强制快进功能区分开来
class ReadTextTracker extends ChangeNotifier {
  static ReadTextTracker? _instance;
  static ReadTextTracker get instance => _instance ??= ReadTextTracker._();

  ReadTextTracker._();

  // 存储已读对话的标识符集合
  // 使用对话内容的哈希值作为唯一标识
  final Set<String> _readDialogues = <String>{};
  final Set<int> _stableReadHashes = <int>{};
  final Map<int, bool> _legacyIndexAgnosticMatchCache = <int, bool>{};
  BigInt? _nativeHandle;
  Timer? _nativeFlushTimer;

  // Old records included the global AST index. Story edits in this project
  // shifted it by hundreds of nodes, so lazily probe a bounded neighborhood
  // while those records are migrated to content-only hashes.
  static const int _legacyIndexScanRadius = 1024;

  // 二进制文件配置
  static const String _fileName = 'saki.sakiread';
  static const String _magicNumber = 'SAKI';
  static const String _logMagicNumber = 'SAKR';
  static const int _version = 1;
  static const int _logVersion = 2;

  /// 初始化，从二进制文件加载已读记录
  Future<void> initialize() async {
    //print('[ReadTextTracker] ========== 开始初始化 ==========');
    //print('[ReadTextTracker] 实例hashCode: $hashCode');
    //print('[ReadTextTracker] 初始化前已读数量: ${_readDialogues.length}');
    _nativeFlushTimer?.cancel();
    final previousHandle = _nativeHandle;
    _nativeHandle = null;
    if (previousHandle != null) {
      try {
        await readStateClose(handle: previousHandle);
      } catch (_) {
        // A stale native handle must not prevent a clean reload.
      }
    }
    _readDialogues.clear(); // 确保清空任何现有数据
    _stableReadHashes.clear();
    _legacyIndexAgnosticMatchCache.clear();
    //print('[ReadTextTracker] 清空后已读数量: ${_readDialogues.length}');
    await _loadFromStorage();
    notifyListeners();
    //print('[ReadTextTracker] 初始化完成，最终已读数量: ${_readDialogues.length}');
    //print('[ReadTextTracker] ========== 初始化结束 ==========');
  }

  /// 标记对话为已读
  /// [speaker] 说话者名字（可选）
  /// [dialogue] 对话内容
  /// [scriptIndex] 脚本索引（用于更精确的标识）
  void markAsRead(String? speaker, String dialogue, int scriptIndex) {
    if (dialogue.trim().isEmpty) {
      //print('[ReadTextTracker] 跳过空对话');
      return;
    }

    final indexedHash = stableIndexedReadHash(speaker, dialogue, scriptIndex);
    final contentHash = stableReadContentHash(speaker, dialogue);
    final newHashes = <int>[
      if (_stableReadHashes.add(indexedHash)) indexedHash,
      if (_stableReadHashes.add(contentHash)) contentHash,
    ];

    if (newHashes.isNotEmpty) {
      //print('[ReadTextTracker] 新增已读: $identifier (总数: ${_readDialogues.length})');
      //print('[ReadTextTracker] 当前实例hashCode: ${hashCode}');
      final nativeHandle = _nativeHandle;
      if (nativeHandle != null) {
        _appendNativeReadHashes(nativeHandle, newHashes);
      } else {
        _saveToStorage();
      }
      notifyListeners();
    } else {
      //print('[ReadTextTracker] 已存在，跳过: $identifier');
    }
  }

  /// 检查对话是否已读
  /// [speaker] 说话者名字（可选）
  /// [dialogue] 对话内容
  /// [scriptIndex] 脚本索引
  bool isRead(String? speaker, String dialogue, int scriptIndex) {
    if (dialogue.trim().isEmpty) return false;

    final identifier = _createIdentifier(speaker, dialogue, scriptIndex);
    final indexedHash = stableIndexedReadHash(speaker, dialogue, scriptIndex);
    final contentHash = stableReadContentHash(speaker, dialogue);
    final result =
        _stableReadHashes.contains(contentHash) ||
        _stableReadHashes.contains(indexedHash) ||
        _readDialogues.contains(identifier) ||
        _matchesLegacyIndexedRecord(
          speaker,
          dialogue,
          scriptIndex,
          contentHash,
        );
    //print('[ReadTextTracker] 检查是否已读: "$identifier" = $result (实例${hashCode}, 总数${_readDialogues.length})');
    return result;
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
    if (containsLegacyIndexedReadHashNear(
      hashes: _stableReadHashes,
      speaker: speaker,
      dialogue: dialogue,
      currentScriptIndex: scriptIndex,
      radius: _legacyIndexScanRadius,
    )) {
      _legacyIndexAgnosticMatchCache[contentHash] = true;
      return true;
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

  Future<void> _appendNativeReadHashes(
    BigInt handle,
    Iterable<int> hashes,
  ) async {
    try {
      for (final hash in hashes) {
        await readStateMark(handle: handle, stableHash: hash);
      }
      _nativeFlushTimer?.cancel();
      _nativeFlushTimer = Timer(const Duration(milliseconds: 250), () async {
        try {
          await readStateFlush(handle: handle);
        } catch (error) {
          if (kEngineDebugMode) {
            print('[SAKI_NATIVE][READ] flush failed: $error');
          }
        }
      });
    } catch (error) {
      if (kEngineDebugMode) {
        print('[SAKI_NATIVE][READ] append failed: $error');
      }
    }
  }

  /// 获取已读对话数量
  int get readCount => _stableReadHashes.length + _readDialogues.length;

  /// 清除所有已读记录（删除.sakiread文件）
  Future<void> clearAllReadRecords() async {
    //print('[ReadTextTracker] 清除前: ${_readDialogues.length} 条已读记录');
    //print('[ReadTextTracker] 当前实例hashCode: ${hashCode}');

    try {
      final nativeHandle = _nativeHandle;
      if (nativeHandle != null) {
        await readStateClear(handle: nativeHandle);
        _stableReadHashes.clear();
        _readDialogues.clear();
        _legacyIndexAgnosticMatchCache.clear();
        notifyListeners();
        return;
      }
      final filePath = await _getReadFilePath();
      final file = File(filePath);

      if (await file.exists()) {
        await file.delete();
        //print('[ReadTextTracker] 成功删除.sakiread文件: $filePath');
      } else {
        //print('[ReadTextTracker] .sakiread文件不存在，无需删除');
      }

      _readDialogues.clear();
      _stableReadHashes.clear();
      _legacyIndexAgnosticMatchCache.clear();
      //print('[ReadTextTracker] 清除后: ${_readDialogues.length} 条已读记录');
      //print('[ReadTextTracker] 清除操作完成');
    } catch (e) {
      //print('[ReadTextTracker] 删除.sakiread文件失败: $e');
      // 即使删除文件失败，也清空内存中的数据
      _readDialogues.clear();
      _stableReadHashes.clear();
      _legacyIndexAgnosticMatchCache.clear();
    }

    notifyListeners();
  }

  /// 获取.sakiread文件路径
  Future<String> _getReadFilePath() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final projectName = await _getCurrentProjectName();
      final savesDir = Directory(
        '${directory.path}/SakiEngine/Saves/$projectName',
      );
      if (!await savesDir.exists()) {
        await savesDir.create(recursive: true);
      }
      return p.join(savesDir.path, _fileName);
    } catch (e) {
      //print('[ReadTextTracker] 获取文件路径失败: $e');
      rethrow;
    }
  }

  /// 获取当前项目名称（复制自SaveLoadManager逻辑）
  Future<String> _getCurrentProjectName() async {
    try {
      final projectName = await GamePathResolver.resolveProjectName();
      if (projectName != null && projectName.isNotEmpty) {
        return projectName;
      }

      return 'DefaultProject';
    } catch (e) {
      return 'DefaultProject';
    }
  }

  /// 从二进制文件加载已读记录
  Future<void> _loadFromStorage() async {
    try {
      final filePath = await _getReadFilePath();
      final file = File(filePath);

      //print('[ReadTextTracker] 尝试加载文件: $filePath');

      if (!await file.exists()) {
        // Rust open also creates the new append-log file.
      }

      if (await SakiNativeRuntime.ensureInitialized()) {
        try {
          final snapshot = await readStateOpen(path: filePath);
          _nativeHandle = snapshot.handle;
          _stableReadHashes.addAll(
            snapshot.stableHashes.map((hash) => hash.toInt()),
          );
          _readDialogues.addAll(
            snapshot.legacyHashes.map((hash) => hash.toString()),
          );
          if (kEngineDebugMode) {
            print(
              '[SAKI_NATIVE][READ] stable=${_stableReadHashes.length} '
              'legacy=${_readDialogues.length} '
              'migrated=${snapshot.migratedLegacyFile}',
            );
          }
          return;
        } catch (error, stackTrace) {
          if (kEngineDebugMode) {
            print(
              '[SAKI_NATIVE][READ] open failed; '
              'Dart fallback enabled: $error',
            );
            print(stackTrace);
          }
        }
      }

      if (!await file.exists()) {
        return;
      }

      final bytes = await file.readAsBytes();
      //print('[ReadTextTracker] 读取到 ${bytes.length} 字节数据');

      if (bytes.length < 12) {
        // 至少需要魔法数字(4) + 版本(4) + 计数(4)
        //print('[ReadTextTracker] 文件太小，可能损坏');
        return;
      }

      final buffer = bytes.buffer.asByteData();
      int offset = 0;

      // 检查魔法数字
      final magic = String.fromCharCodes(bytes.sublist(0, 4));
      offset += 4;
      if (magic == _logMagicNumber) {
        final version = buffer.getInt32(offset, Endian.little);
        offset += 4;
        if (version != _logVersion) {
          return;
        }
        while (offset + 9 <= bytes.length) {
          final kind = bytes[offset];
          offset += 1;
          final hash = buffer.getInt64(offset, Endian.little);
          offset += 8;
          if (kind == 0) {
            _readDialogues.add(hash.toSigned(32).toString());
          } else if (kind == 1) {
            _stableReadHashes.add(hash);
          }
        }
        return;
      }
      if (magic != _magicNumber) {
        //print('[ReadTextTracker] 魔法数字不匹配: $magic');
        return;
      }

      // 检查版本
      final version = buffer.getInt32(offset, Endian.little);
      offset += 4;
      if (version != _version) {
        //print('[ReadTextTracker] 版本不匹配: $version');
        return;
      }

      // 读取已读记录数量
      final count = buffer.getInt32(offset, Endian.little);
      offset += 4;
      //print('[ReadTextTracker] 准备加载 $count 条已读记录');

      _readDialogues.clear();

      // 读取每个哈希值
      for (int i = 0; i < count; i++) {
        if (offset + 4 > bytes.length) break;
        final hashCode = buffer.getInt32(offset, Endian.little);
        offset += 4;
        _readDialogues.add(hashCode.toString());
      }

      //print('[ReadTextTracker] 从二进制文件加载: ${_readDialogues.length} 条已读记录');
    } catch (e) {
      //print('[ReadTextTracker] 加载已读记录异常: $e');
      if (kEngineDebugMode) {
        print('加载已读记录失败: $e');
      }
    }
  }

  /// 保存已读记录到二进制文件
  Future<void> _saveToStorage() async {
    try {
      if (_nativeHandle != null) {
        return;
      }
      final filePath = await _getReadFilePath();
      final file = File(filePath);

      // 与 Rust 使用同一 v2 追加日志格式，确保原生库暂时不可用时
      // 仍能读取迁移后的记录，且不会退回并覆盖成旧格式。
      final bufferSize =
          8 + ((_readDialogues.length + _stableReadHashes.length) * 9);
      final buffer = Uint8List(bufferSize);
      final byteData = buffer.buffer.asByteData();

      int offset = 0;

      // 写入魔法数字
      for (int i = 0; i < _logMagicNumber.length; i++) {
        buffer[offset + i] = _logMagicNumber.codeUnitAt(i);
      }
      offset += 4;

      // 写入版本
      byteData.setInt32(offset, _logVersion, Endian.little);
      offset += 4;

      // kind=0: 旧版 Dart int32 hash；kind=1: 稳定 int64 hash。
      for (final hashString in _readDialogues) {
        final hashCode = int.parse(hashString);
        buffer[offset++] = 0;
        byteData.setInt64(offset, hashCode, Endian.little);
        offset += 8;
      }
      for (final hashCode in _stableReadHashes) {
        buffer[offset++] = 1;
        byteData.setInt64(offset, hashCode, Endian.little);
        offset += 8;
      }

      await file.writeAsBytes(buffer);
      //print('[ReadTextTracker] 保存到二进制文件: ${_readDialogues.length} 条已读记录 ($bufferSize 字节)');
      //print('[ReadTextTracker] 文件路径: $filePath');
    } catch (e) {
      //print('[ReadTextTracker] 保存已读记录失败: $e');
      if (kEngineDebugMode) {
        print('保存已读记录失败: $e');
      }
    }
  }

  /// 导出已读记录（备份.sakiread文件）
  Map<String, dynamic> exportReadRecords() {
    return {
      'version': _version,
      'readCount': readCount,
      'readDialogues': _readDialogues.toList(),
      'stableReadHashes': _stableReadHashes.toList(),
      'exportTime': DateTime.now().toIso8601String(),
      'storageType': 'binary_file', // 标记存储类型
    };
  }

  /// 导入已读记录（从备份恢复并保存到.sakiread文件）
  Future<void> importReadRecords(Map<String, dynamic> data) async {
    try {
      final List<dynamic> readList = data['readDialogues'] ?? [];
      final List<dynamic> stableList = data['stableReadHashes'] ?? [];
      _readDialogues.clear();
      _readDialogues.addAll(readList.cast<String>());
      _stableReadHashes.clear();
      _stableReadHashes.addAll(stableList.map((value) => value as int));
      _legacyIndexAgnosticMatchCache.clear();
      final nativeHandle = _nativeHandle;
      if (nativeHandle != null) {
        await replaceReadStateValues(
          handle: nativeHandle,
          stableHashes: _stableReadHashes.toList(),
          legacyHashes: _readDialogues
              .map(int.tryParse)
              .whereType<int>()
              .toList(growable: false),
        );
      } else {
        await _saveToStorage(); // 保存到二进制文件
      }
      notifyListeners();
      //print('[ReadTextTracker] 成功导入 ${_readDialogues.length} 条已读记录');
    } catch (e) {
      //print('[ReadTextTracker] 导入已读记录失败: $e');
      if (kEngineDebugMode) {
        print('导入已读记录失败: $e');
      }
    }
  }
}
