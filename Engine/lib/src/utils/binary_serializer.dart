import 'dart:convert' show utf8;
import 'dart:typed_data';
import 'dart:math' show min;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';

/// 二进制序列化工具类，用于将游戏数据序列化为二进制格式
class BinarySerializer {
  static const int _version = 17; // 增加版本号以支持全屏脚本画布状态
  static const String _magicNumber = 'SAKI';

  static Uint8List serializeGameStateSnapshot(GameStateSnapshot snapshot) =>
      _serializeGameStateSnapshot(snapshot);

  static GameStateSnapshot deserializeGameStateSnapshot(
    Uint8List data, {
    int version = _version,
  }) {
    final reader = _BinaryReader(data);
    final snapshot = _deserializeGameStateSnapshot(reader, version);
    if (reader.hasMoreData()) {
      throw const FormatException('Trailing history snapshot bytes');
    }
    return snapshot;
  }

  /// 将SaveSlot序列化为二进制数据
  static Uint8List serializeSaveSlot(SaveSlot saveSlot) {
    final buffer = <int>[];

    // 写入魔法数字和版本号
    buffer.addAll(_magicNumber.codeUnits);
    buffer.addAll(_writeInt32(_version));

    // 写入基本信息
    // 桌面平台使用Int64存储ID，Web平台使用Int32
    if (kIsWeb) {
      buffer.addAll(_writeInt32(saveSlot.id));
    } else {
      buffer.addAll(_writeInt64(saveSlot.id));
    }
    // Web平台使用Int32存储时间戳（秒级精度），桌面平台使用Int64（毫秒级精度）
    if (kIsWeb) {
      buffer.addAll(
        _writeInt32((saveSlot.saveTime.millisecondsSinceEpoch ~/ 1000)),
      );
    } else {
      buffer.addAll(_writeInt64(saveSlot.saveTime.millisecondsSinceEpoch));
    }
    buffer.addAll(_writeString(saveSlot.currentScript));
    buffer.addAll(_writeString(saveSlot.dialoguePreview));
    buffer.addAll(_writeNullableBytes(saveSlot.screenshotData));
    buffer.add(saveSlot.isLocked ? 1 : 0); // 写入锁定状态

    // 写入游戏状态快照
    buffer.addAll(_serializeGameStateSnapshot(saveSlot.snapshot));

    return Uint8List.fromList(buffer);
  }

  /// 从二进制数据反序列化SaveSlot
  static SaveSlot deserializeSaveSlot(Uint8List data) {
    //print('Debug: 开始反序列化存档，数据长度: ${data.length}');

    final reader = _BinaryReader(data);

    // 读取并验证魔法数字和版本号
    //print('Debug: 读取魔法数字...');
    final magic = String.fromCharCodes(reader.readBytes(4));
    //print('Debug: 魔法数字: "$magic" (期望: "$_magicNumber")');

    if (magic != _magicNumber) {
      throw FormatException(
        'Invalid file format: expected $_magicNumber, got $magic',
      );
    }

    //print('Debug: 读取版本号...');
    final version = reader.readInt32();
    //print('Debug: 版本号: $version (当前支持: $_version)');

    if (version < 1 || version > _version) {
      throw FormatException(
        'Unsupported version: $version (supported: 1-$_version)',
      );
    }

    // 读取基本信息
    //print('Debug: 读取基本信息...');
    final int id;
    if (version == 1) {
      // 向后兼容：版本1使用32位ID
      id = reader.readInt32();
    } else if (kIsWeb) {
      // Web平台使用32位ID
      id = reader.readInt32();
    } else {
      // 桌面平台版本2及以上使用64位ID
      id = reader.readInt64();
    }

    // 读取时间戳
    final DateTime saveTime;
    if (kIsWeb) {
      final timestamp = reader.readInt32() * 1000; // 秒转毫秒
      saveTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else {
      saveTime = DateTime.fromMillisecondsSinceEpoch(reader.readInt64());
    }
    final currentScript = reader.readString();
    final dialoguePreview = reader.readNullableString();
    final screenshotData = reader.readNullableBytes();

    //print('Debug: ID=$id, 时间=$saveTime, 脚本=$currentScript');
    //print('Debug: 对话预览=${dialoguePreview != null ? (dialoguePreview.length > 50 ? dialoguePreview.substring(0, 50) + "..." : dialoguePreview) : "null"}');
    //print('Debug: 截图数据长度=${screenshotData?.length ?? 0}');

    // 读取锁定状态（向后兼容旧版本存档）
    bool isLocked = false;
    if (reader.hasMoreData()) {
      try {
        isLocked = reader.readByte() == 1;
        //print('Debug: 锁定状态=$isLocked');
      } catch (e) {
        //print('Debug: 无法读取锁定状态，默认为未锁定: $e');
        isLocked = false;
      }
    }

    // 读取游戏状态快照
    //print('Debug: 读取游戏状态快照...');
    final snapshot = _deserializeGameStateSnapshot(reader, version);

    //print('Debug: 存档反序列化完成');
    return SaveSlot(
      id: id,
      saveTime: saveTime,
      currentScript: currentScript,
      dialoguePreview: dialoguePreview ?? '',
      snapshot: snapshot,
      screenshotData: screenshotData,
      isLocked: isLocked,
    );
  }

  /// 序列化GameStateSnapshot
  static Uint8List _serializeGameStateSnapshot(GameStateSnapshot snapshot) {
    final buffer = <int>[];

    buffer.addAll(_writeInt32(snapshot.scriptIndex));
    buffer.addAll(_serializeGameState(snapshot.currentState));

    // 序列化对话历史
    buffer.addAll(_writeInt32(snapshot.dialogueHistory.length));
    for (final entry in snapshot.dialogueHistory) {
      buffer.addAll(_serializeDialogueHistoryEntry(entry));
    }

    // 序列化 NVL 状态
    buffer.add(snapshot.isNvlMode ? 1 : 0);
    buffer.add(snapshot.isNvlMovieMode ? 1 : 0); // 添加电影模式状态
    buffer.add(snapshot.isNvlnMode ? 1 : 0); // 添加无遮罩NVL模式状态
    buffer.add(snapshot.isNvlOverlayVisible ? 1 : 0); // 添加NVL遮罩可见性
    buffer.addAll(_writeInt32(snapshot.nvlDialogues.length));
    for (final nvlDialogue in snapshot.nvlDialogues) {
      buffer.addAll(_serializeNvlDialogue(nvlDialogue));
    }

    buffer.addAll(_writeInt32(snapshot.activeLoopingSounds?.length ?? 0));
    for (final soundPath in snapshot.activeLoopingSounds ?? const <String>[]) {
      buffer.addAll(_writeString(soundPath));
    }

    return Uint8List.fromList(buffer);
  }

  /// 反序列化GameStateSnapshot
  static GameStateSnapshot _deserializeGameStateSnapshot(
    _BinaryReader reader, [
    int? version,
  ]) {
    final scriptIndex = reader.readInt32();
    final currentState = _deserializeGameState(reader, version);

    // 反序列化对话历史
    final historyLength = reader.readInt32();
    final dialogueHistory = <DialogueHistoryEntry>[];
    for (int i = 0; i < historyLength; i++) {
      dialogueHistory.add(_deserializeDialogueHistoryEntry(reader, version));
    }

    // 反序列化 NVL 状态
    final isNvlMode = reader.readByte() == 1;
    final isNvlMovieMode = reader.readByte() == 1; // 添加电影模式状态
    // 版本5及以上才有isNvlnMode字段
    final bool isNvlnMode;
    if (version != null && version >= 5) {
      isNvlnMode = reader.readByte() == 1;
    } else {
      isNvlnMode = false;
    }
    final bool isNvlOverlayVisible = (version != null && version >= 6)
        ? reader.readByte() == 1
        : isNvlMode;
    final nvlDialoguesLength = reader.readInt32();
    final nvlDialogues = <NvlDialogue>[];
    for (int i = 0; i < nvlDialoguesLength; i++) {
      nvlDialogues.add(_deserializeNvlDialogue(reader, version));
    }
    List<String>? activeLoopingSounds;
    if (version != null && version >= 16) {
      final activeLoopingSoundCount = reader.readInt32();
      activeLoopingSounds = <String>[
        for (int i = 0; i < activeLoopingSoundCount; i++) reader.readString(),
      ];
    }

    return GameStateSnapshot(
      scriptIndex: scriptIndex,
      currentState: currentState,
      dialogueHistory: dialogueHistory,
      isNvlMode: isNvlMode,
      isNvlMovieMode: isNvlMovieMode, // 添加电影模式状态
      isNvlnMode: isNvlnMode, // 添加无遮罩NVL模式状态
      isNvlOverlayVisible: isNvlOverlayVisible, // 添加NVL遮罩可见性
      nvlDialogues: nvlDialogues,
      activeLoopingSounds: activeLoopingSounds,
    );
  }

  /// 序列化GameState
  static Uint8List _serializeGameState(GameState state) {
    final buffer = <int>[];

    buffer.addAll(_writeNullableString(state.background));
    buffer.addAll(_writeNullableString(state.movieFile)); // 新增：序列化视频文件
    buffer.addAll(_writeNullableString(state.dialogue));
    buffer.addAll(_writeNullableString(state.dialogueTag));
    buffer.addAll(_writeNullableString(state.speaker));

    // 序列化角色状态
    buffer.addAll(_writeInt32(state.characters.length));
    for (final entry in state.characters.entries) {
      buffer.addAll(_writeString(entry.key));
      buffer.addAll(_serializeCharacterState(entry.value));
    }

    // 序列化CG角色状态（版本4新增）
    buffer.addAll(_writeInt32(state.cgCharacters.length));
    for (final entry in state.cgCharacters.entries) {
      buffer.addAll(_writeString(entry.key));
      buffer.addAll(_serializeCharacterState(entry.value));
    }

    // 序列化 NVL 状态
    buffer.add(state.isNvlMode ? 1 : 0);
    buffer.add(state.isNvlMovieMode ? 1 : 0);
    buffer.add(state.isNvlnMode ? 1 : 0); // 添加无遮罩NVL模式状态
    buffer.add(state.isNvlOverlayVisible ? 1 : 0); // 添加NVL遮罩可见性
    buffer.addAll(_writeInt32(state.nvlDialogues.length));
    for (final nvlDialogue in state.nvlDialogues) {
      buffer.addAll(_serializeNvlDialogue(nvlDialogue));
    }

    // 序列化 currentNode（版本7新增）
    buffer.addAll(_serializeCurrentNode(state.currentNode));

    // 序列化脚本API覆盖层状态（版本8新增）
    buffer.addAll(_writeNullableString(state.scriptOverlayText));
    buffer.addAll(_writeNullableString(state.scriptOverlayBackgroundColor));
    buffer.addAll(_writeNullableString(state.scriptOverlayTextColor));
    buffer.addAll(_writeNullableString(state.scriptOverlayAnimation));
    buffer.addAll(_writeNullableString(state.scriptOverlayStretchX.toString()));
    buffer.add(state.scriptOverlayPlainStyle ? 1 : 0);
    buffer.add(state.scriptOverlayFitScreen ? 1 : 0);
    buffer.add(state.scriptOverlayFitCover ? 1 : 0);
    buffer.addAll(_writeNullableString(state.scriptOverlayLineWidthRatios));
    buffer.add(state.scriptOverlayStretchEachLine ? 1 : 0);
    buffer.addAll(_writeInt32(state.scriptOverlayRevision));
    buffer.addAll(_writeNullableString(state.sceneTopRightStatusText));
    buffer.addAll(_writeNullableString(state.scriptCanvasId));
    buffer.addAll(_writeString(state.scriptCanvasDurationSeconds.toString()));
    buffer.addAll(_writeInt32(state.scriptCanvasRevision));

    return Uint8List.fromList(buffer);
  }

  /// 反序列化GameState
  static GameState _deserializeGameState(_BinaryReader reader, [int? version]) {
    final background = reader.readNullableString();

    // 只在版本3及以上读取movieFile字段
    String? movieFile;
    if (version != null && version >= 3) {
      movieFile = reader.readNullableString();
    } else {
      movieFile = null; // 旧版本存档没有movieFile字段
    }

    final dialogue = reader.readNullableString();
    String? dialogueTag;
    if (version != null && version >= 12) {
      dialogueTag = reader.readNullableString();
    }
    final speaker = reader.readNullableString();

    // 反序列化角色状态
    final charactersLength = reader.readInt32();
    final characters = <String, CharacterState>{};
    for (int i = 0; i < charactersLength; i++) {
      final key = reader.readString();
      final value = _deserializeCharacterState(reader, version);
      characters[key] = value;
    }

    // 反序列化CG角色状态（版本4新增）
    Map<String, CharacterState> cgCharacters = <String, CharacterState>{};
    if (version != null && version >= 4) {
      final cgCharactersLength = reader.readInt32();
      for (int i = 0; i < cgCharactersLength; i++) {
        final key = reader.readString();
        final value = _deserializeCharacterState(reader, version);
        cgCharacters[key] = value;
      }
    }

    // 反序列化 NVL 状态
    final isNvlMode = reader.readByte() == 1;
    final isNvlMovieMode = reader.readByte() == 1;
    // 版本5及以上才有isNvlnMode字段
    final bool isNvlnMode;
    if (version != null && version >= 5) {
      isNvlnMode = reader.readByte() == 1;
    } else {
      isNvlnMode = false;
    }
    final bool isNvlOverlayVisible = (version != null && version >= 6)
        ? reader.readByte() == 1
        : isNvlMode;
    final nvlDialoguesLength = reader.readInt32();
    final nvlDialogues = <NvlDialogue>[];
    for (int i = 0; i < nvlDialoguesLength; i++) {
      nvlDialogues.add(_deserializeNvlDialogue(reader, version));
    }

    // 反序列化 currentNode（版本7新增）
    final currentNode = _deserializeCurrentNode(reader, version);

    String? scriptOverlayText;
    String? scriptOverlayBackgroundColor;
    String? scriptOverlayTextColor;
    String? scriptOverlayAnimation;
    double scriptOverlayStretchX = 1.0;
    bool scriptOverlayPlainStyle = false;
    bool scriptOverlayFitScreen = false;
    bool scriptOverlayFitCover = false;
    String? scriptOverlayLineWidthRatios;
    bool scriptOverlayStretchEachLine = false;
    int scriptOverlayRevision = 0;
    String? sceneTopRightStatusText;
    String? scriptCanvasId;
    double scriptCanvasDurationSeconds = 0;
    int scriptCanvasRevision = 0;
    if (version != null && version >= 8) {
      scriptOverlayText = reader.readNullableString();
      scriptOverlayBackgroundColor = reader.readNullableString();
      scriptOverlayTextColor = reader.readNullableString();
      scriptOverlayAnimation = reader.readNullableString();
      final stretchXRaw = reader.readNullableString();
      scriptOverlayStretchX = double.tryParse(stretchXRaw ?? '') ?? 1.0;
      if (version >= 9) {
        scriptOverlayPlainStyle = reader.readByte() == 1;
        scriptOverlayFitScreen = reader.readByte() == 1;
        if (version >= 10) {
          scriptOverlayFitCover = reader.readByte() == 1;
          if (version >= 11) {
            scriptOverlayLineWidthRatios = reader.readNullableString();
            scriptOverlayStretchEachLine = reader.readByte() == 1;
          }
        }
      }
      scriptOverlayRevision = reader.readInt32();
      if (version >= 14) {
        sceneTopRightStatusText = reader.readNullableString();
      }
    }
    if (version != null && version >= 17) {
      scriptCanvasId = reader.readNullableString();
      scriptCanvasDurationSeconds = double.tryParse(reader.readString()) ?? 0;
      scriptCanvasRevision = reader.readInt32();
    }

    return GameState(
      background: background,
      movieFile: movieFile, // 新增：视频文件参数
      scriptCanvasId: scriptCanvasId,
      scriptCanvasDurationSeconds: scriptCanvasDurationSeconds,
      scriptCanvasRevision: scriptCanvasRevision,
      dialogue: dialogue,
      dialogueTag: dialogueTag,
      speaker: speaker,
      characters: characters,
      cgCharacters: cgCharacters, // 新增：CG角色状态
      isNvlMode: isNvlMode,
      isNvlMovieMode: isNvlMovieMode,
      isNvlnMode: isNvlnMode, // 添加无遮罩NVL模式状态
      isNvlOverlayVisible: isNvlOverlayVisible,
      nvlDialogues: nvlDialogues,
      currentNode: currentNode, // 添加 currentNode
      scriptOverlayText: scriptOverlayText,
      scriptOverlayBackgroundColor: scriptOverlayBackgroundColor,
      scriptOverlayTextColor: scriptOverlayTextColor,
      scriptOverlayAnimation: scriptOverlayAnimation,
      scriptOverlayStretchX: scriptOverlayStretchX,
      scriptOverlayPlainStyle: scriptOverlayPlainStyle,
      scriptOverlayFitScreen: scriptOverlayFitScreen,
      scriptOverlayFitCover: scriptOverlayFitCover,
      scriptOverlayLineWidthRatios: scriptOverlayLineWidthRatios,
      scriptOverlayStretchEachLine: scriptOverlayStretchEachLine,
      scriptOverlayRevision: scriptOverlayRevision,
      sceneTopRightStatusText: sceneTopRightStatusText,
    );
  }

  /// 序列化 currentNode (MenuNode)
  static Uint8List _serializeCurrentNode(SksNode? node) {
    final buffer = <int>[];

    if (node == null || node is! MenuNode) {
      // 如果 currentNode 为 null 或不是 MenuNode，标记为无数据
      buffer.add(0);
    } else {
      // 标记有 MenuNode 数据
      buffer.add(1);

      // 序列化选择项数量
      buffer.addAll(_writeInt32(node.choices.length));

      // 序列化每个选择项
      for (final choice in node.choices) {
        buffer.addAll(_writeString(choice.text));
        buffer.addAll(_writeString(choice.targetLabel));
      }
    }

    return Uint8List.fromList(buffer);
  }

  /// 反序列化 currentNode (MenuNode)
  static SksNode? _deserializeCurrentNode(_BinaryReader reader, int? version) {
    // 只在版本7及以上才读取 currentNode
    if (version == null || version < 7) {
      return null;
    }

    final hasNode = reader.readByte() == 1;
    if (!hasNode) {
      return null;
    }

    // 读取选择项数量
    final choicesLength = reader.readInt32();
    final choices = <ChoiceOptionNode>[];

    // 读取每个选择项
    for (int i = 0; i < choicesLength; i++) {
      final text = reader.readString();
      final targetLabel = reader.readString();
      choices.add(ChoiceOptionNode(text, targetLabel));
    }

    return MenuNode(choices);
  }

  /// 序列化CharacterState
  static Uint8List _serializeCharacterState(CharacterState state) {
    final buffer = <int>[];

    buffer.addAll(_writeString(state.resourceId));
    buffer.addAll(_writeNullableString(state.pose));
    buffer.addAll(_writeNullableString(state.expression));
    buffer.addAll(_writeNullableString(state.positionId));
    buffer.addAll(_writeNullableString(state.maskType));
    buffer.addAll(_writeNullableString(state.maskColor));

    return Uint8List.fromList(buffer);
  }

  /// 反序列化CharacterState
  static CharacterState _deserializeCharacterState(
    _BinaryReader reader, [
    int? version,
  ]) {
    final resourceId = reader.readString();
    final pose = reader.readNullableString();
    final expression = reader.readNullableString();
    final positionId = reader.readNullableString();
    String? maskType;
    String? maskColor;
    if (version != null && version >= 15) {
      maskType = reader.readNullableString();
      maskColor = reader.readNullableString();
    }

    return CharacterState(
      resourceId: resourceId,
      pose: pose,
      expression: expression,
      positionId: positionId,
      maskType: maskType,
      maskColor: maskColor,
    );
  }

  /// 序列化DialogueHistoryEntry
  static Uint8List _serializeDialogueHistoryEntry(DialogueHistoryEntry entry) {
    final buffer = <int>[];

    buffer.addAll(_writeNullableString(entry.speaker));
    buffer.addAll(_writeString(entry.dialogue));
    buffer.addAll(_writeNullableString(entry.dialogueTag));
    // Web平台使用Int32存储时间戳（秒级精度）
    if (kIsWeb) {
      buffer.addAll(
        _writeInt32((entry.timestamp.millisecondsSinceEpoch ~/ 1000)),
      );
    } else {
      buffer.addAll(_writeInt64(entry.timestamp.millisecondsSinceEpoch));
    }
    buffer.addAll(_writeInt32(entry.scriptIndex));
    buffer.addAll(_writeNullableString(entry.sourceScriptFile));
    buffer.addAll(_writeNullableString(entry.sourceLine?.toString()));
    buffer.addAll(entry.serializedStateSnapshot);

    return Uint8List.fromList(buffer);
  }

  /// 反序列化DialogueHistoryEntry
  static DialogueHistoryEntry _deserializeDialogueHistoryEntry(
    _BinaryReader reader, [
    int? version,
  ]) {
    final speaker = reader.readNullableString();
    final dialogue = reader.readString();
    final String? dialogueTag = (version != null && version >= 12)
        ? reader.readNullableString()
        : null;
    // 读取时间戳
    final DateTime timestamp;
    if (kIsWeb) {
      final ts = reader.readInt32() * 1000; // 秒转毫秒
      timestamp = DateTime.fromMillisecondsSinceEpoch(ts);
    } else {
      timestamp = DateTime.fromMillisecondsSinceEpoch(reader.readInt64());
    }
    final scriptIndex = reader.readInt32();
    final String? sourceScriptFile = (version != null && version >= 13)
        ? reader.readNullableString()
        : null;
    final int? sourceLine = (version != null && version >= 13)
        ? int.tryParse(reader.readNullableString() ?? '')
        : null;
    final stateSnapshot = _deserializeGameStateSnapshot(
      reader,
      version,
    ); // 传递版本号

    return DialogueHistoryEntry(
      speaker: speaker,
      dialogue: dialogue,
      dialogueTag: dialogueTag,
      timestamp: timestamp,
      scriptIndex: scriptIndex,
      sourceScriptFile: sourceScriptFile,
      sourceLine: sourceLine,
      stateSnapshot: stateSnapshot,
    );
  }

  // 基础数据类型序列化方法
  static Uint8List _writeInt32(int value) {
    return Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);
  }

  static Uint8List _writeInt64(int value) {
    // 这个方法只在非Web平台使用
    if (kIsWeb) {
      throw UnsupportedError('Int64 not supported on web platform');
    }
    return Uint8List(8)..buffer.asByteData().setInt64(0, value, Endian.little);
  }

  static Uint8List _writeString(String value) {
    final bytes = utf8.encode(value);
    final buffer = <int>[];
    buffer.addAll(_writeInt32(bytes.length));
    buffer.addAll(bytes);
    return Uint8List.fromList(buffer);
  }

  static Uint8List _writeNullableBytes(Uint8List? value) {
    if (value == null) {
      return _writeInt32(-1);
    }
    final buffer = <int>[];
    buffer.addAll(_writeInt32(value.length));
    buffer.addAll(value);
    return Uint8List.fromList(buffer);
  }

  static Uint8List _writeNullableString(String? value) {
    if (value == null) {
      return _writeInt32(-1);
    }
    final bytes = utf8.encode(value);
    final buffer = <int>[];
    buffer.addAll(_writeInt32(bytes.length));
    buffer.addAll(bytes);
    return Uint8List.fromList(buffer);
  }

  /// 序列化 NvlDialogue
  static Uint8List _serializeNvlDialogue(NvlDialogue nvlDialogue) {
    final buffer = <int>[];
    buffer.addAll(_writeNullableString(nvlDialogue.speaker));
    buffer.addAll(_writeString(nvlDialogue.dialogue));
    buffer.addAll(_writeNullableString(nvlDialogue.dialogueTag));
    // Web平台使用Int32存储时间戳（秒级精度）
    if (kIsWeb) {
      buffer.addAll(
        _writeInt32((nvlDialogue.timestamp.millisecondsSinceEpoch ~/ 1000)),
      );
    } else {
      buffer.addAll(_writeInt64(nvlDialogue.timestamp.millisecondsSinceEpoch));
    }
    return Uint8List.fromList(buffer);
  }

  /// 反序列化 NvlDialogue
  static NvlDialogue _deserializeNvlDialogue(
    _BinaryReader reader, [
    int? version,
  ]) {
    final speaker = reader.readNullableString();
    final dialogue = reader.readString();
    final String? dialogueTag = (version != null && version >= 12)
        ? reader.readNullableString()
        : null;
    // 读取时间戳
    final DateTime timestamp;
    if (kIsWeb) {
      final ts = reader.readInt32() * 1000; // 秒转毫秒
      timestamp = DateTime.fromMillisecondsSinceEpoch(ts);
    } else {
      timestamp = DateTime.fromMillisecondsSinceEpoch(reader.readInt64());
    }

    return NvlDialogue(
      speaker: speaker,
      dialogue: dialogue,
      dialogueTag: dialogueTag,
      timestamp: timestamp,
    );
  }
}

/// 二进制读取器类
class _BinaryReader {
  final Uint8List _data;
  int _position = 0;

  _BinaryReader(this._data);

  bool hasMoreData() {
    return _position < _data.length;
  }

  Uint8List readBytes(int length) {
    if (_position + length > _data.length) {
      throw RangeError('Not enough data to read $length bytes');
    }
    final result = _data.sublist(_position, _position + length);
    _position += length;
    return result;
  }

  int readInt32() {
    final bytes = readBytes(4);
    return bytes.buffer.asByteData().getInt32(0, Endian.little);
  }

  int readInt64() {
    // 这个方法只在非Web平台使用
    if (kIsWeb) {
      throw UnsupportedError('Int64 not supported on web platform');
    }
    final bytes = readBytes(8);
    return bytes.buffer.asByteData().getInt64(0, Endian.little);
  }

  int readByte() {
    if (_position >= _data.length) {
      throw RangeError('Not enough data to read 1 byte');
    }
    return _data[_position++];
  }

  String readString() {
    final length = readInt32();
    if (length < 0) {
      throw FormatException('Invalid string length: $length');
    }
    final bytes = readBytes(length);
    return utf8.decode(bytes);
  }

  String? readNullableString() {
    final length = readInt32();
    if (length == -1) {
      return null;
    }
    if (length < 0) {
      throw FormatException('Invalid string length: $length');
    }
    final bytes = readBytes(length);
    return utf8.decode(bytes);
  }

  Uint8List? readNullableBytes() {
    final length = readInt32();
    if (length == -1) {
      return null;
    }
    if (length < 0) {
      throw FormatException('Invalid bytes length: $length');
    }
    return readBytes(length);
  }
}

/// SaveSlot类，只支持二进制序列化
class SaveSlot {
  final int id;
  final DateTime saveTime;
  final String currentScript;
  final String dialoguePreview; // 已废弃，保留用于向后兼容
  final GameStateSnapshot snapshot;
  final Uint8List? screenshotData; // 内嵌的截图数据
  final String? screenshotFilePath; // 原生索引使用：截图所在存档文件
  final int? screenshotOffset; // 原生索引使用：截图字节偏移
  final int? screenshotLength; // 原生索引使用：截图字节长度
  final bool isLocked; // 存档是否被锁定

  SaveSlot({
    required this.id,
    required this.saveTime,
    required this.currentScript,
    required this.dialoguePreview,
    required this.snapshot,
    this.screenshotData,
    this.screenshotFilePath,
    this.screenshotOffset,
    this.screenshotLength,
    this.isLocked = false,
  });

  SaveSlot copyWith({
    int? id,
    DateTime? saveTime,
    String? currentScript,
    String? dialoguePreview,
    GameStateSnapshot? snapshot,
    Uint8List? screenshotData,
    String? screenshotFilePath,
    int? screenshotOffset,
    int? screenshotLength,
    bool? isLocked,
  }) {
    return SaveSlot(
      id: id ?? this.id,
      saveTime: saveTime ?? this.saveTime,
      currentScript: currentScript ?? this.currentScript,
      dialoguePreview: dialoguePreview ?? this.dialoguePreview,
      snapshot: snapshot ?? this.snapshot,
      screenshotData: screenshotData ?? this.screenshotData,
      screenshotFilePath: screenshotFilePath ?? this.screenshotFilePath,
      screenshotOffset: screenshotOffset ?? this.screenshotOffset,
      screenshotLength: screenshotLength ?? this.screenshotLength,
      isLocked: isLocked ?? this.isLocked,
    );
  }

  /// 从二进制数据创建SaveSlot
  factory SaveSlot.fromBinary(Uint8List data) {
    return BinarySerializer.deserializeSaveSlot(data);
  }

  /// 将SaveSlot转换为二进制数据
  Uint8List toBinary() {
    return BinarySerializer.serializeSaveSlot(this);
  }

  /// 获取实时对话预览（需要异步加载）
  /// 此方法会根据scriptIndex从当前脚本中查询最新的对话内容
  /// 使用方式：
  /// ```dart
  /// final preview = await saveSlot.getRealtimeDialoguePreview();
  /// ```
  Future<String> getRealtimeDialoguePreview() async {
    // 导入需要延迟到运行时，避免循环依赖
    // 这里通过调用SaveLoadManager的静态方法来实现
    // 由于SaveLoadManager在save_load_manager_io.dart中定义，
    // 我们需要在UI层调用时处理，而不是在这里直接调用
    // 因此这个方法只是一个占位符，实际实现在SaveLoadManager中
    throw UnimplementedError(
      'Please use SaveLoadManager.getDialoguePreview(saveSlot.snapshot) instead',
    );
  }
}
