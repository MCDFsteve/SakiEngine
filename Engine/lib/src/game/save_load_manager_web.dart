import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/game/screenshot_generator.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/utils/rich_text_parser.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/config/config_parser.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/game/script_merger.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/engine_asset_loader.dart';
import 'package:sakiengine/src/localization/script_text_localizer.dart';

class SaveLoadManager {
  static const String _storageKeyPrefix = 'saki_save_';
  static const int _autoSaveSlotCount = 18;
  static const String _autoSaveStorageKeyPrefix = 'saki_autosave_slot_';
  static const String _autoSaveIndexKey = 'saki_autosave_index';

  /// Web 平台没有文件系统：用 localStorage 模拟原子写入语义。
  /// 这里保持与 IO 版本同名 API，避免跨平台调用处编译失败。
  static Future<void> writeBinaryFileAtomically(
    Object targetFile,
    Uint8List data,
  ) async {
    final storageKey = targetFile.toString();
    html.window.localStorage[storageKey] = base64Encode(data);
  }

  // 缓存脚本和配置，避免重复加载
  static ScriptNode? _cachedScript;
  static Map<String, CharacterConfig>? _cachedCharacterConfigs;
  static Future<ScriptNode>? _scriptLoadFuture;
  static Future<Map<String, CharacterConfig>>? _characterConfigsLoadFuture;

  static Future<void> _ensureScriptLoaded() async {
    if (_cachedScript != null) {
      return;
    }

    _scriptLoadFuture ??= () async {
      final scriptMerger = ScriptMerger();
      return scriptMerger.getMergedScript();
    }();

    try {
      _cachedScript = await _scriptLoadFuture!;
    } finally {
      _scriptLoadFuture = null;
    }
  }

  static Future<void> _ensureCharacterConfigsLoaded() async {
    if (_cachedCharacterConfigs != null) {
      return;
    }

    _characterConfigsLoadFuture ??= () async {
      final charactersContent = await AssetManager().loadString(
        'assets/GameScript/configs/characters.sks',
      );
      return ConfigParser().parseCharacters(charactersContent);
    }();

    try {
      _cachedCharacterConfigs = await _characterConfigsLoadFuture!;
    } finally {
      _characterConfigsLoadFuture = null;
    }
  }

  /// 实时查询存档的对话预览文本
  /// 根据scriptIndex从当前脚本中查询对话内容
  static Future<String> getDialoguePreview(GameStateSnapshot snapshot) async {
    try {
      final currentState = snapshot.currentState;

      // 检查是否是选择界面
      if (currentState.currentNode != null &&
          currentState.currentNode is MenuNode) {
        final menuNode = currentState.currentNode as MenuNode;
        final choiceTexts = menuNode.choices
            .map((choice) => '[${choice.text}]')
            .toList();
        final localization = LocalizationManager();
        return '${localization.t('saveLoad.choiceMenu')}\n${choiceTexts.join('\n')}';
      }

      // 如果无法从脚本查询，回退到NVL模式检查
      if (currentState.isNvlMode && currentState.nvlDialogues.isNotEmpty) {
        final latestNvlDialogue = currentState.nvlDialogues.last;
        if (latestNvlDialogue.speaker != null &&
            latestNvlDialogue.speaker!.isNotEmpty) {
          return '【${latestNvlDialogue.speaker}】${RichTextParser.cleanText(latestNvlDialogue.dialogue)}';
        } else {
          return RichTextParser.cleanText(latestNvlDialogue.dialogue);
        }
      }

      // 普通模式优先使用当前状态的对话
      if (currentState.dialogue != null && currentState.dialogue!.isNotEmpty) {
        if (currentState.speaker != null && currentState.speaker!.isNotEmpty) {
          return '【${currentState.speaker}】${RichTextParser.cleanText(currentState.dialogue!)}';
        } else {
          return RichTextParser.cleanText(currentState.dialogue!);
        }
      }

      // 再回退到历史最后一句（避免不必要的脚本解析）
      if (snapshot.dialogueHistory.isNotEmpty) {
        final latestDialogue = snapshot.dialogueHistory.last;
        if (latestDialogue.speaker != null &&
            latestDialogue.speaker!.isNotEmpty) {
          return '【${latestDialogue.speaker}】${RichTextParser.cleanText(latestDialogue.dialogue)}';
        } else {
          return RichTextParser.cleanText(latestDialogue.dialogue);
        }
      }

      // 最后兜底：基于脚本索引查询（旧存档兼容）
      final int dialogueScriptIndex = snapshot.scriptIndex;
      if (dialogueScriptIndex >= 0) {
        await _ensureScriptLoaded();
        if (dialogueScriptIndex < _cachedScript!.children.length) {
          final node = _cachedScript!.children[dialogueScriptIndex];
          if (node is SayNode) {
            final dialogue = ScriptTextLocalizer.resolve(node.dialogue);
            String? speaker;

            if (node.character != null) {
              await _ensureCharacterConfigsLoaded();
              final characterConfig = _cachedCharacterConfigs![node.character];
              speaker = characterConfig?.name;
            }

            if (speaker != null && speaker.isNotEmpty) {
              return '【$speaker】${RichTextParser.cleanText(dialogue)}';
            } else {
              return RichTextParser.cleanText(dialogue);
            }
          }
        }
      }

      return '...';
    } catch (e) {
      if (kEngineDebugMode) {
        print('[SaveLoadManager] 实时查询对话预览失败: $e');
      }
      return '...';
    }
    // return '...';
  }

  /// 清除缓存（在脚本热重载时调用）
  static void clearCache() {
    _cachedScript = null;
    _cachedCharacterConfigs = null;
    _scriptLoadFuture = null;
    _characterConfigsLoadFuture = null;
  }

  // Web平台使用默认项目名
  Future<String> _getCurrentProjectName() async {
    try {
      // 从assets读取default_game.txt
      final assetContent = await EngineAssetLoader.loadString(
        'assets/default_game.txt',
      );
      final projectName = assetContent.trim();

      if (projectName.isEmpty) {
        throw Exception('Project name is empty in default_game.txt');
      }

      return projectName;
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error getting project name: $e');
      }
      return 'DefaultProject';
    }
  }

  Future<String> getSavesDirectory() async {
    // Web平台不需要目录概念，返回项目名即可
    return await _getCurrentProjectName();
  }

  String _getSaveKey(int slotId) {
    return '${_storageKeyPrefix}slot_$slotId';
  }

  String _getAutoSaveKey(int slotIndex) {
    return '$_autoSaveStorageKeyPrefix$slotIndex';
  }

  String _quickSaveStorageKey(String? namespace) {
    final normalized = namespace?.trim() ?? '';
    if (normalized.isEmpty) {
      return 'quicksave.sakisav';
    }
    final sanitized = normalized
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final bounded = sanitized.length > 64
        ? sanitized.substring(0, 64)
        : sanitized;
    return bounded.isEmpty ? 'quicksave.sakisav' : 'quicksave_$bounded.sakisav';
  }

  Future<void> saveGame(
    int slotId,
    String currentScript,
    GameStateSnapshot snapshot,
    Map<String, PoseConfig> poseConfigs,
  ) async {
    // 检查目标位置是否有被锁定的存档
    final existingSlot = await loadGame(slotId);
    if (existingSlot?.isLocked == true) {
      throw Exception('存档已锁定，无法覆盖');
    }

    String dialoguePreview = '...';
    final currentState = snapshot.currentState;

    // 检查是否是选择界面
    if (currentState.currentNode != null &&
        currentState.currentNode is MenuNode) {
      final menuNode = currentState.currentNode as MenuNode;
      final choiceTexts = menuNode.choices
          .map((choice) => '[${choice.text}]')
          .toList();
      final localization = LocalizationManager();
      dialoguePreview =
          '${localization.t('saveLoad.choiceMenu')}\n${choiceTexts.join('\n')}';
    }
    // 优先检查 NVL 模式（包括普通nvl和无遮罩nvln模式）
    else if (currentState.isNvlMode && currentState.nvlDialogues.isNotEmpty) {
      // 使用最新的 NVL 对话作为预览
      final latestNvlDialogue = currentState.nvlDialogues.last;
      if (latestNvlDialogue.speaker != null &&
          latestNvlDialogue.speaker!.isNotEmpty) {
        dialoguePreview =
            '【${latestNvlDialogue.speaker}】${RichTextParser.cleanText(latestNvlDialogue.dialogue)}';
      } else {
        dialoguePreview = RichTextParser.cleanText(latestNvlDialogue.dialogue);
      }
    } else if (currentState.dialogue != null &&
        currentState.dialogue!.isNotEmpty) {
      // 普通模式的对话
      if (currentState.speaker != null && currentState.speaker!.isNotEmpty) {
        dialoguePreview =
            '【${currentState.speaker}】${RichTextParser.cleanText(currentState.dialogue!)}';
      } else {
        dialoguePreview = RichTextParser.cleanText(currentState.dialogue!);
      }
    }

    // 生成截图数据
    Uint8List? screenshotData;
    try {
      screenshotData = await ScreenshotGenerator.generateScreenshotData(
        currentState,
        poseConfigs,
      );
    } catch (e) {
      print('生成截图失败: $e');
    }

    final saveSlot = SaveSlot(
      id: slotId,
      saveTime: DateTime.now(),
      currentScript: currentScript,
      dialoguePreview: dialoguePreview,
      snapshot: snapshot,
      screenshotData: screenshotData,
      isLocked: existingSlot?.isLocked ?? false,
    );

    final binaryData = saveSlot.toBinary();

    // 将二进制数据转换为base64字符串存储到localStorage
    final base64Data = base64Encode(binaryData);
    html.window.localStorage[_getSaveKey(slotId)] = base64Data;
  }

  /// 快速存档功能
  Future<void> quickSave(
    String currentScript,
    GameStateSnapshot snapshot,
    Map<String, PoseConfig> poseConfigs, {
    String? namespace,
  }) async {
    // final directory = await getSavesDirectory();
    // final file = File('$directory/quicksave.sakisav');
    //
    // // 生成截图数据
    // Uint8List? screenshotData;
    // try {
    //   screenshotData = await ScreenshotGenerator.generateScreenshotData(
    //     snapshot.currentState,
    //     poseConfigs,
    //   );
    // } catch (e) {
    //   print('生成截图失败: $e');
    // }
    //
    // final saveSlot = SaveSlot(
    //   id: -1, // 使用特殊ID表示快速存档
    //   saveTime: DateTime.now(),
    //   currentScript: currentScript,
    //   dialoguePreview: '',
    //   snapshot: snapshot,
    //   screenshotData: screenshotData,
    //   isLocked: false,
    // );
    //
    // final binaryData = saveSlot.toBinary();
    // await file.writeAsBytes(binaryData);
    // 生成截图（需要确保你的 generateScreenshotData 支持 Web）
    Uint8List? screenshotData;
    try {
      screenshotData = await ScreenshotGenerator.generateScreenshotData(
        snapshot.currentState,
        poseConfigs,
      );
    } catch (e, st) {
      print('生成截图失败: $e\n$st');
    }

    final saveSlot = SaveSlot(
      id: -1, // 快速存档
      saveTime: DateTime.now(),
      currentScript: currentScript,
      dialoguePreview: '',
      snapshot: snapshot,
      screenshotData: screenshotData,
      isLocked: false,
    );

    // 转换成二进制
    final binaryData = saveSlot.toBinary();

    // Web 无法保存二进制文件，因此使用 base64
    final base64Data = base64Encode(binaryData);

    try {
      html.window.localStorage[_quickSaveStorageKey(namespace)] = base64Data;
      print("快速存档成功（Web）");
    } catch (e, st) {
      print("快速存储失败: $e\n$st");
    }
  }

  /// 读取快速存档
  Future<SaveSlot?> loadQuickSave({String? namespace}) async {
    // try {
    //   final directory = await getSavesDirectory();
    //   final file = File('$directory/quicksave.sakisav');
    //   if (await file.exists()) {
    //     final binaryData = await file.readAsBytes();
    //     return SaveSlot.fromBinary(binaryData);
    //   }
    // } catch (e) {
    //   print('Error loading quick save: $e');
    // }
    final base64Data =
        html.window.localStorage[_quickSaveStorageKey(namespace)];
    if (base64Data == null) return null;

    try {
      final binaryData = base64Decode(base64Data);
      return SaveSlot.fromBinary(binaryData);
    } catch (e, st) {
      print('快速读档失败: $e\n$st');
      return null;
    }
    // return null;
  }

  /// 检查快速存档是否存在
  Future<bool> hasQuickSave({String? namespace}) async {
    // try {
    //   final directory = await getSavesDirectory();
    //   final file = File('$directory/quicksave.sakisav');
    //   return await file.exists();
    // } catch (e) {
    //   print('Error checking quick save: $e');
    //   return false;
    // }
    return html.window.localStorage.containsKey(
      _quickSaveStorageKey(namespace),
    );
    // return false;
  }

  int _readAutoSaveIndex() {
    final raw = html.window.localStorage[_autoSaveIndexKey];
    final parsed = int.tryParse(raw ?? '');
    if (parsed != null && parsed >= 1 && parsed <= _autoSaveSlotCount) {
      return parsed;
    }
    return 1;
  }

  void _writeAutoSaveIndex(int index) {
    html.window.localStorage[_autoSaveIndexKey] = index.toString();
  }

  /// 自动存档（环形缓冲）
  Future<void> autoSave(
    String currentScript,
    GameStateSnapshot snapshot, {
    String dialoguePreview = '',
    Map<String, PoseConfig>? poseConfigs,
  }) async {
    final currentIndex = _readAutoSaveIndex();
    final now = DateTime.now();
    Uint8List? screenshotData;
    try {
      screenshotData = await ScreenshotGenerator.generateScreenshotData(
        snapshot.currentState,
        poseConfigs ?? <String, PoseConfig>{},
      );
    } catch (_) {
      // 自动存档截图失败不阻断存档
    }

    final saveSlot = SaveSlot(
      id: int.parse(now.millisecondsSinceEpoch.toString().substring(0, 10)),
      saveTime: now,
      currentScript: currentScript,
      dialoguePreview: dialoguePreview,
      snapshot: snapshot,
      screenshotData: screenshotData,
      isLocked: false,
    );

    final binaryData = saveSlot.toBinary();
    final base64Data = base64Encode(binaryData);
    html.window.localStorage[_getAutoSaveKey(currentIndex)] = base64Data;

    final nextIndex = currentIndex >= _autoSaveSlotCount ? 1 : currentIndex + 1;
    _writeAutoSaveIndex(nextIndex);
  }

  /// 获取自动存档列表（按时间倒序）
  Future<List<SaveSlot>> listAutoSaveSlots() async {
    final autoSaveSlots = <SaveSlot>[];

    for (int i = 1; i <= _autoSaveSlotCount; i++) {
      final base64Data = html.window.localStorage[_getAutoSaveKey(i)];
      if (base64Data == null) {
        continue;
      }

      try {
        final binaryData = base64Decode(base64Data);
        final slot = SaveSlot.fromBinary(binaryData);
        autoSaveSlots.add(slot);
      } catch (_) {
        // 忽略损坏/读取失败的自动存档
      }
    }

    autoSaveSlots.sort((a, b) => b.saveTime.compareTo(a.saveTime));
    return autoSaveSlots;
  }

  Future<bool> hasAutoSave() async {
    final slots = await listAutoSaveSlots();
    return slots.isNotEmpty;
  }

  Future<SaveSlot?> loadGame(int slotId) async {
    try {
      final base64Data = html.window.localStorage[_getSaveKey(slotId)];
      if (base64Data != null) {
        final binaryData = base64Decode(base64Data);
        return SaveSlot.fromBinary(binaryData);
      }
    } catch (e) {
      print('Error loading game from slot $slotId: $e');
    }
    return null;
  }

  Future<Uint8List?> loadSaveScreenshot(SaveSlot slot) async {
    return slot.screenshotData;
  }

  Future<List<SaveSlot>> listSaveSlots() async {
    final saveSlots = <SaveSlot>[];

    // 遍历localStorage查找存档
    html.window.localStorage.keys
        .where((key) => key.startsWith(_storageKeyPrefix))
        .forEach((key) {
          try {
            final base64Data = html.window.localStorage[key];
            if (base64Data != null) {
              final binaryData = base64Decode(base64Data);
              final saveSlot = SaveSlot.fromBinary(binaryData);
              saveSlots.add(saveSlot);
            }
          } catch (e) {
            print('Error loading save slot from key $key: $e');
          }
        });

    saveSlots.sort((a, b) => a.id.compareTo(b.id));
    return saveSlots;
  }

  /// 获取指定范围的存档位信息（懒加载支持）
  Future<List<SaveSlot?>> listSaveSlotsInRange(
    int startSlotId,
    int endSlotId,
  ) async {
    final result = <SaveSlot?>[];

    for (int slotId = startSlotId; slotId <= endSlotId; slotId++) {
      try {
        final slot = await loadGame(slotId);
        result.add(slot);
      } catch (e) {
        result.add(null);
      }
    }

    return result;
  }

  /// 获取所有存在的存档位ID
  Future<List<int>> getExistingSaveSlotIds() async {
    final existingIds = <int>[];

    html.window.localStorage.keys
        .where((key) => key.startsWith(_storageKeyPrefix))
        .forEach((key) {
          try {
            // 从key提取ID: saki_save_slot_123 -> 123
            final parts = key.split('_');
            if (parts.length >= 3) {
              final id = int.tryParse(parts.last);
              if (id != null) {
                existingIds.add(id);
              }
            }
          } catch (e) {
            // 忽略解析错误的key
          }
        });

    existingIds.sort();
    return existingIds;
  }

  /// 获取下一个可用的存档位ID
  Future<int> getNextAvailableSlotId() async {
    final existingIds = await getExistingSaveSlotIds();
    if (existingIds.isEmpty) return 1;

    // 查找第一个空隙
    for (int i = 1; i <= existingIds.last + 1; i++) {
      if (!existingIds.contains(i)) {
        return i;
      }
    }

    return existingIds.last + 1;
  }

  Future<void> deleteSave(int slotId) async {
    final saveSlot = await loadGame(slotId);
    if (saveSlot?.isLocked == true) {
      throw Exception('存档已锁定，无法删除');
    }

    html.window.localStorage.remove(_getSaveKey(slotId));
  }

  Future<bool> moveSave(int fromSlotId, int toSlotId) async {
    if (fromSlotId == toSlotId) return false;

    final saveSlot = await loadGame(fromSlotId);
    if (saveSlot == null) return false;

    // 检查源存档是否被锁定
    if (saveSlot.isLocked) return false;

    // 检查目标位置是否有被锁定的存档
    final targetSlot = await loadGame(toSlotId);
    if (targetSlot?.isLocked == true) return false;

    try {
      final updatedSaveSlot = SaveSlot(
        id: toSlotId,
        saveTime: saveSlot.saveTime,
        currentScript: saveSlot.currentScript,
        dialoguePreview: saveSlot.dialoguePreview,
        snapshot: saveSlot.snapshot,
        screenshotData: saveSlot.screenshotData,
        isLocked: saveSlot.isLocked,
      );

      final binaryData = updatedSaveSlot.toBinary();
      final base64Data = base64Encode(binaryData);

      html.window.localStorage[_getSaveKey(toSlotId)] = base64Data;
      html.window.localStorage.remove(_getSaveKey(fromSlotId));

      return true;
    } catch (e) {
      print('Error moving save from slot $fromSlotId to $toSlotId: $e');
      return false;
    }
  }

  Future<bool> swapSaves(int slotId1, int slotId2) async {
    if (slotId1 == slotId2) return false;

    final saveSlot1 = await loadGame(slotId1);
    final saveSlot2 = await loadGame(slotId2);

    if (saveSlot1?.isLocked == true || saveSlot2?.isLocked == true) {
      return false;
    }

    try {
      // 删除原存档
      html.window.localStorage.remove(_getSaveKey(slotId1));
      html.window.localStorage.remove(_getSaveKey(slotId2));

      // 交换保存
      if (saveSlot1 != null) {
        final updatedSaveSlot1 = SaveSlot(
          id: slotId2,
          saveTime: saveSlot1.saveTime,
          currentScript: saveSlot1.currentScript,
          dialoguePreview: saveSlot1.dialoguePreview,
          snapshot: saveSlot1.snapshot,
          screenshotData: saveSlot1.screenshotData,
          isLocked: saveSlot1.isLocked,
        );
        final binaryData = updatedSaveSlot1.toBinary();
        html.window.localStorage[_getSaveKey(slotId2)] = base64Encode(
          binaryData,
        );
      }

      if (saveSlot2 != null) {
        final updatedSaveSlot2 = SaveSlot(
          id: slotId1,
          saveTime: saveSlot2.saveTime,
          currentScript: saveSlot2.currentScript,
          dialoguePreview: saveSlot2.dialoguePreview,
          snapshot: saveSlot2.snapshot,
          screenshotData: saveSlot2.screenshotData,
          isLocked: saveSlot2.isLocked,
        );
        final binaryData = updatedSaveSlot2.toBinary();
        html.window.localStorage[_getSaveKey(slotId1)] = base64Encode(
          binaryData,
        );
      }

      return true;
    } catch (e) {
      print('Error swapping saves between slot $slotId1 and $slotId2: $e');
      return false;
    }
  }

  Future<bool> toggleSaveLock(int slotId) async {
    final saveSlot = await loadGame(slotId);
    if (saveSlot == null) return false;

    final updatedSlot = SaveSlot(
      id: saveSlot.id,
      saveTime: saveSlot.saveTime,
      currentScript: saveSlot.currentScript,
      dialoguePreview: saveSlot.dialoguePreview,
      snapshot: saveSlot.snapshot,
      screenshotData: saveSlot.screenshotData,
      isLocked: !saveSlot.isLocked,
    );

    try {
      final binaryData = updatedSlot.toBinary();
      html.window.localStorage[_getSaveKey(slotId)] = base64Encode(binaryData);
      return true;
    } catch (e) {
      print('Error toggling lock for slot $slotId: $e');
      return false;
    }
  }
}

class GameConfigManager {
  static const String _configKey = 'saki_game_config';

  /// 保存游戏配置到localStorage
  Future<void> saveConfig(GameConfig config) async {
    final binaryData = config.toBinary();
    final base64Data = base64Encode(binaryData);
    html.window.localStorage[_configKey] = base64Data;
  }

  /// 从localStorage加载游戏配置
  Future<GameConfig> loadConfig() async {
    try {
      final base64Data = html.window.localStorage[_configKey];
      if (base64Data != null) {
        final binaryData = base64Decode(base64Data);
        return GameConfig.fromBinary(binaryData);
      }
    } catch (e) {
      print('Error loading config: $e');
    }
    return GameConfig.defaultConfig();
  }
}

/// 游戏配置类（与IO版本相同）
class GameConfig {
  final String version;
  final String language;
  final double masterVolume;
  final double musicVolume;
  final double soundVolume;
  final double voiceVolume;
  final double textSpeed;
  final double autoplaySpeed;
  final bool enableAutoplay;
  final bool fullscreen;
  final int windowWidth;
  final int windowHeight;

  GameConfig({
    required this.version,
    required this.language,
    required this.masterVolume,
    required this.musicVolume,
    required this.soundVolume,
    required this.voiceVolume,
    required this.textSpeed,
    required this.autoplaySpeed,
    required this.enableAutoplay,
    required this.fullscreen,
    required this.windowWidth,
    required this.windowHeight,
  });

  factory GameConfig.defaultConfig() {
    return GameConfig(
      version: '1.0.0',
      language: 'zh_CN',
      masterVolume: 1.0,
      musicVolume: 0.8,
      soundVolume: 1.0,
      voiceVolume: 1.0,
      textSpeed: 0.5,
      autoplaySpeed: 3.0,
      enableAutoplay: false,
      fullscreen: false,
      windowWidth: 1280,
      windowHeight: 720,
    );
  }

  /// 从二进制数据创建配置
  factory GameConfig.fromBinary(Uint8List data) {
    final reader = _BinaryConfigReader(data);

    // 验证魔法数字
    final magic = String.fromCharCodes(reader.readBytes(4));
    if (magic != 'CONF') {
      throw FormatException('Invalid config file format');
    }

    final version = reader.readInt32();
    if (version != 1) {
      throw FormatException('Unsupported config version: $version');
    }

    return GameConfig(
      version: reader.readString(),
      language: reader.readString(),
      masterVolume: reader.readDouble(),
      musicVolume: reader.readDouble(),
      soundVolume: reader.readDouble(),
      voiceVolume: reader.readDouble(),
      textSpeed: reader.readDouble(),
      autoplaySpeed: reader.readDouble(),
      enableAutoplay: reader.readBool(),
      fullscreen: reader.readBool(),
      windowWidth: reader.readInt32(),
      windowHeight: reader.readInt32(),
    );
  }

  /// 转换为二进制数据
  Uint8List toBinary() {
    final buffer = <int>[];

    // 写入魔法数字和版本
    buffer.addAll('CONF'.codeUnits);
    buffer.addAll(_writeInt32(1));

    // 写入配置数据
    buffer.addAll(_writeString(version));
    buffer.addAll(_writeString(language));
    buffer.addAll(_writeDouble(masterVolume));
    buffer.addAll(_writeDouble(musicVolume));
    buffer.addAll(_writeDouble(soundVolume));
    buffer.addAll(_writeDouble(voiceVolume));
    buffer.addAll(_writeDouble(textSpeed));
    buffer.addAll(_writeDouble(autoplaySpeed));
    buffer.addAll(_writeBool(enableAutoplay));
    buffer.addAll(_writeBool(fullscreen));
    buffer.addAll(_writeInt32(windowWidth));
    buffer.addAll(_writeInt32(windowHeight));

    return Uint8List.fromList(buffer);
  }

  // 辅助序列化方法
  static Uint8List _writeInt32(int value) {
    return Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);
  }

  static Uint8List _writeDouble(double value) {
    return Uint8List(8)
      ..buffer.asByteData().setFloat64(0, value, Endian.little);
  }

  static Uint8List _writeBool(bool value) {
    return Uint8List(1)..[0] = value ? 1 : 0;
  }

  static Uint8List _writeString(String value) {
    final bytes = utf8.encode(value);
    final buffer = <int>[];
    buffer.addAll(_writeInt32(bytes.length));
    buffer.addAll(bytes);
    return Uint8List.fromList(buffer);
  }
}

/// 配置文件二进制读取器
class _BinaryConfigReader {
  final Uint8List _data;
  int _position = 0;

  _BinaryConfigReader(this._data);

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

  double readDouble() {
    final bytes = readBytes(8);
    return bytes.buffer.asByteData().getFloat64(0, Endian.little);
  }

  bool readBool() {
    final bytes = readBytes(1);
    return bytes[0] == 1;
  }

  String readString() {
    final length = readInt32();
    if (length < 0) {
      throw FormatException('Invalid string length: $length');
    }
    final bytes = readBytes(length);
    return utf8.decode(bytes);
  }
}
