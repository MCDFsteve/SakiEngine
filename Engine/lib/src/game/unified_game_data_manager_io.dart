import 'dart:io';
import 'dart:typed_data';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:path_provider/path_provider.dart';

/// 统一的游戏数据管理器
/// 将所有游戏数据（设置、变量、音量等）保存到存档目录
/// 使用二进制格式，方便 Steam 云存档同步
class UnifiedGameDataManager {
  static final UnifiedGameDataManager _instance =
      UnifiedGameDataManager._internal();
  factory UnifiedGameDataManager() => _instance;
  UnifiedGameDataManager._internal();

  static const int _version = 4;
  static const String _fileName = 'game_data.sakidata';
  static const String _defaultMouseRollbackBehavior = 'rewind';
  static const bool _defaultMouseParallaxEnabled = true;

  // 游戏设置
  double _dialogOpacity = 0.9;
  bool _isFullscreen = false;
  bool _darkMode = false;
  double _typewriterCharsPerSecond = 50.0;
  bool _skipPunctuationDelay = false;
  bool _speakerAnimation = true;
  bool _autoHideQuickMenu = false;
  bool _mouseParallaxEnabled = _defaultMouseParallaxEnabled;
  String _menuDisplayMode = 'windowed';
  String _fastForwardMode = 'read_only';
  String _mouseRollbackBehavior = _defaultMouseRollbackBehavior;
  String _dialogueFontFamily = 'SourceHanSansCN'; // 对话文字字体

  // 音频设置
  bool _isMusicEnabled = true;
  bool _isSoundEnabled = true;
  double _musicVolume = 0.8;
  double _soundVolume = 0.8;
  double _voiceVolume = 0.8;

  // 持久化变量
  final Map<String, bool> _boolVariables = {};
  final Map<String, int> _intVariables = {};
  final Map<String, double> _doubleVariables = {};
  final Map<String, String> _stringVariables = {};

  bool _isInitialized = false;
  bool _hasPersistedData = false;

  /// 获取数据文件路径
  Future<String> _getDataFilePath(String projectName) async {
    final directory = await getApplicationDocumentsDirectory();
    final dataDir =
        Directory('${directory.path}/SakiEngine/Saves/$projectName');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    return '${dataDir.path}/$_fileName';
  }

  /// 初始化并加载数据
  Future<void> init(String projectName) async {
    if (_isInitialized) return;

    try {
      final filePath = await _getDataFilePath(projectName);
      final file = File(filePath);

      if (await file.exists()) {
        _hasPersistedData = true;
        final data = await file.readAsBytes();
        _deserialize(data);
      }

      _isInitialized = true;
    } catch (e) {
      if (kEngineDebugMode) {
        print('[UnifiedGameDataManager] 初始化失败: $e');
      }
    }
  }

  /// 保存所有数据
  Future<void> save(String projectName) async {
    try {
      final filePath = await _getDataFilePath(projectName);
      final file = File(filePath);
      final data = _serialize();
      await file.writeAsBytes(data);
    } catch (e) {
      if (kEngineDebugMode) {
        print('[UnifiedGameDataManager] 保存失败: $e');
      }
    }
  }

  /// 序列化数据到二进制
  Uint8List _serialize() {
    final buffer = BytesBuilder();

    // 写入版本号
    buffer.add(_writeInt32(_version));

    // 写入设置数据
    buffer.add(_writeDouble(_dialogOpacity));
    buffer.add(_writeBool(_isFullscreen));
    buffer.add(_writeBool(_darkMode));
    buffer.add(_writeDouble(_typewriterCharsPerSecond));
    buffer.add(_writeBool(_skipPunctuationDelay));
    buffer.add(_writeBool(_speakerAnimation));
    buffer.add(_writeBool(_autoHideQuickMenu));
    buffer.add(_writeBool(_mouseParallaxEnabled));
    buffer.add(_writeString(_menuDisplayMode));
    buffer.add(_writeString(_fastForwardMode));
    buffer.add(_writeString(_dialogueFontFamily));
    buffer.add(_writeString(_mouseRollbackBehavior));

    // 写入音频设置
    buffer.add(_writeBool(_isMusicEnabled));
    buffer.add(_writeBool(_isSoundEnabled));
    buffer.add(_writeDouble(_musicVolume));
    buffer.add(_writeDouble(_soundVolume));
    buffer.add(_writeDouble(_voiceVolume));

    // 写入持久化变量
    buffer.add(_writeInt32(_boolVariables.length));
    for (final entry in _boolVariables.entries) {
      buffer.add(_writeString(entry.key));
      buffer.add(_writeBool(entry.value));
    }

    buffer.add(_writeInt32(_intVariables.length));
    for (final entry in _intVariables.entries) {
      buffer.add(_writeString(entry.key));
      buffer.add(_writeInt32(entry.value));
    }

    buffer.add(_writeInt32(_doubleVariables.length));
    for (final entry in _doubleVariables.entries) {
      buffer.add(_writeString(entry.key));
      buffer.add(_writeDouble(entry.value));
    }

    buffer.add(_writeInt32(_stringVariables.length));
    for (final entry in _stringVariables.entries) {
      buffer.add(_writeString(entry.key));
      buffer.add(_writeString(entry.value));
    }

    return buffer.toBytes();
  }

  /// 从二进制反序列化数据
  void _deserialize(Uint8List data) {
    final reader = _BinaryReader(data);

    // 读取版本号
    final version = reader.readInt32();
    if (version > _version) {
      if (kEngineDebugMode) {
        print('[UnifiedGameDataManager] 版本不匹配: $version');
      }
      return;
    }

    // 读取设置数据
    _dialogOpacity = reader.readDouble();
    _isFullscreen = reader.readBool();
    _darkMode = reader.readBool();
    _typewriterCharsPerSecond = reader.readDouble();
    _skipPunctuationDelay = reader.readBool();
    _speakerAnimation = reader.readBool();
    _autoHideQuickMenu = reader.readBool();
    if (version >= 3) {
      _mouseParallaxEnabled = reader.readBool();
    } else {
      _mouseParallaxEnabled = _defaultMouseParallaxEnabled;
    }
    _menuDisplayMode = reader.readString();
    _fastForwardMode = reader.readString();
    _dialogueFontFamily = reader.readString();
    if (version >= 2) {
      _mouseRollbackBehavior = reader.readString();
    } else {
      _mouseRollbackBehavior = _defaultMouseRollbackBehavior;
    }

    // 读取音频设置
    _isMusicEnabled = reader.readBool();
    _isSoundEnabled = reader.readBool();
    _musicVolume = reader.readDouble();
    _soundVolume = reader.readDouble();
    // v3 及更早版本中，语音与音效共用 soundVolume。迁移时继承该值，
    // 避免升级后玩家的语音听感突然发生变化。
    _voiceVolume = version >= 4 ? reader.readDouble() : _soundVolume;

    // 读取持久化变量
    final boolCount = reader.readInt32();
    _boolVariables.clear();
    for (int i = 0; i < boolCount; i++) {
      final key = reader.readString();
      final value = reader.readBool();
      _boolVariables[key] = value;
    }

    final intCount = reader.readInt32();
    _intVariables.clear();
    for (int i = 0; i < intCount; i++) {
      final key = reader.readString();
      final value = reader.readInt32();
      _intVariables[key] = value;
    }

    final doubleCount = reader.readInt32();
    _doubleVariables.clear();
    for (int i = 0; i < doubleCount; i++) {
      final key = reader.readString();
      final value = reader.readDouble();
      _doubleVariables[key] = value;
    }

    final stringCount = reader.readInt32();
    _stringVariables.clear();
    for (int i = 0; i < stringCount; i++) {
      final key = reader.readString();
      final value = reader.readString();
      _stringVariables[key] = value;
    }
  }

  // ============ 设置相关 Getters/Setters ============

  bool get hasPersistedData => _hasPersistedData;

  double get dialogOpacity => _dialogOpacity;
  Future<void> setDialogOpacity(double value, String projectName) async {
    _dialogOpacity = value;
    await save(projectName);
  }

  bool get isFullscreen => _isFullscreen;
  Future<void> setIsFullscreen(bool value, String projectName) async {
    _isFullscreen = value;
    await save(projectName);
  }

  bool get darkMode => _darkMode;
  Future<void> setDarkMode(bool value, String projectName) async {
    _darkMode = value;
    await save(projectName);
  }

  double get typewriterCharsPerSecond => _typewriterCharsPerSecond;
  Future<void> setTypewriterCharsPerSecond(
      double value, String projectName) async {
    _typewriterCharsPerSecond = value;
    await save(projectName);
  }

  bool get skipPunctuationDelay => _skipPunctuationDelay;
  Future<void> setSkipPunctuationDelay(bool value, String projectName) async {
    _skipPunctuationDelay = value;
    await save(projectName);
  }

  bool get speakerAnimation => _speakerAnimation;
  Future<void> setSpeakerAnimation(bool value, String projectName) async {
    _speakerAnimation = value;
    await save(projectName);
  }

  bool get autoHideQuickMenu => _autoHideQuickMenu;
  Future<void> setAutoHideQuickMenu(bool value, String projectName) async {
    _autoHideQuickMenu = value;
    await save(projectName);
  }

  bool get mouseParallaxEnabled => _mouseParallaxEnabled;
  Future<void> setMouseParallaxEnabled(bool value, String projectName) async {
    _mouseParallaxEnabled = value;
    await save(projectName);
  }

  String get menuDisplayMode => _menuDisplayMode;
  Future<void> setMenuDisplayMode(String value, String projectName) async {
    _menuDisplayMode = value;
    await save(projectName);
  }

  String get fastForwardMode => _fastForwardMode;
  Future<void> setFastForwardMode(String value, String projectName) async {
    _fastForwardMode = value;
    await save(projectName);
  }

  String get mouseRollbackBehavior => _mouseRollbackBehavior;
  Future<void> setMouseRollbackBehavior(
      String value, String projectName) async {
    _mouseRollbackBehavior = value;
    await save(projectName);
  }

  // ============ 音频设置 Getters/Setters ============

  bool get isMusicEnabled => _isMusicEnabled;
  Future<void> setMusicEnabled(bool value, String projectName) async {
    _isMusicEnabled = value;
    await save(projectName);
  }

  bool get isSoundEnabled => _isSoundEnabled;
  Future<void> setSoundEnabled(bool value, String projectName) async {
    _isSoundEnabled = value;
    await save(projectName);
  }

  double get musicVolume => _musicVolume;
  Future<void> setMusicVolume(double value, String projectName) async {
    _musicVolume = value;
    await save(projectName);
  }

  double get soundVolume => _soundVolume;
  Future<void> setSoundVolume(double value, String projectName) async {
    _soundVolume = value;
    await save(projectName);
  }

  double get voiceVolume => _voiceVolume;
  Future<void> setVoiceVolume(double value, String projectName) async {
    _voiceVolume = value;
    await save(projectName);
  }

  String get dialogueFontFamily => _dialogueFontFamily;
  Future<void> setDialogueFontFamily(String value, String projectName) async {
    _dialogueFontFamily = value;
    await save(projectName);
  }

  // ============ 持久化变量 ============

  bool getBoolVariable(String name, {bool defaultValue = false}) {
    return _boolVariables[name] ?? defaultValue;
  }

  Future<void> setBoolVariable(
      String name, bool value, String projectName) async {
    _boolVariables[name] = value;
    await save(projectName);
  }

  int getIntVariable(String name, {int defaultValue = 0}) {
    return _intVariables[name] ?? defaultValue;
  }

  Future<void> setIntVariable(
      String name, int value, String projectName) async {
    _intVariables[name] = value;
    await save(projectName);
  }

  double getDoubleVariable(String name, {double defaultValue = 0.0}) {
    return _doubleVariables[name] ?? defaultValue;
  }

  Future<void> setDoubleVariable(
      String name, double value, String projectName) async {
    _doubleVariables[name] = value;
    await save(projectName);
  }

  String getStringVariable(String name, {String defaultValue = ''}) {
    return _stringVariables[name] ?? defaultValue;
  }

  Future<void> setStringVariable(
      String name, String value, String projectName) async {
    _stringVariables[name] = value;
    await save(projectName);
  }

  Map<String, bool> getAllBoolVariables() => Map.unmodifiable(_boolVariables);

  Future<void> clearAllVariables(String projectName) async {
    _boolVariables.clear();
    _intVariables.clear();
    _doubleVariables.clear();
    _stringVariables.clear();
    await save(projectName);
  }

  // ============ 二进制辅助方法 ============

  Uint8List _writeInt32(int value) {
    final data = ByteData(4);
    data.setInt32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _writeDouble(double value) {
    final data = ByteData(8);
    data.setFloat64(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _writeBool(bool value) {
    return Uint8List.fromList([value ? 1 : 0]);
  }

  Uint8List _writeString(String value) {
    final bytes = Uint8List.fromList(value.codeUnits);
    final length = _writeInt32(bytes.length);
    return Uint8List.fromList([...length, ...bytes]);
  }
}

/// 二进制读取器
class _BinaryReader {
  final Uint8List _data;
  int _offset = 0;

  _BinaryReader(this._data);

  int readInt32() {
    final value = ByteData.sublistView(_data, _offset, _offset + 4)
        .getInt32(0, Endian.little);
    _offset += 4;
    return value;
  }

  double readDouble() {
    final value = ByteData.sublistView(_data, _offset, _offset + 8)
        .getFloat64(0, Endian.little);
    _offset += 8;
    return value;
  }

  bool readBool() {
    final value = _data[_offset] == 1;
    _offset += 1;
    return value;
  }

  String readString() {
    final length = readInt32();
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return String.fromCharCodes(bytes);
  }
}
