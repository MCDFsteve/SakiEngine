import 'dart:io';
import 'dart:typed_data';
import 'dart:convert' show utf8;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/game/screenshot_generator.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/utils/rich_text_parser.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/config/config_parser.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/game/script_merger.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/localization/script_text_localizer.dart';
import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/native/saki_native_runtime.dart';

class SaveLoadManager {
  static const int _autoSaveSlotCount = 18;
  static const String _autoSaveFilePrefix = 'autosave_';
  static const String _autoSaveIndexFileName = 'autosave_index.txt';

  // 缓存脚本和配置，避免重复加载
  static ScriptNode? _cachedScript;
  static Map<String, CharacterConfig>? _cachedCharacterConfigs;
  static Future<ScriptNode>? _scriptLoadFuture;
  static Future<Map<String, CharacterConfig>>? _characterConfigsLoadFuture;
  static bool _nativeSaveIndexUnavailable = false;
  static bool _nativeSaveCodecLogged = false;
  static String? _cachedApplicationDocumentsPath;
  static Future<String>? _applicationDocumentsPathFuture;
  static final Map<String, String> _cachedSavesDirectories = <String, String>{};
  static List<SaveSlot>? _cachedManualSaveHeaders;
  static Future<List<SaveSlot>>? _manualSaveHeadersFuture;
  static int _manualSaveHeadersGeneration = 0;

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
  }

  /// 清除缓存（在脚本热重载时调用）
  static void clearCache() {
    _cachedScript = null;
    _cachedCharacterConfigs = null;
    _scriptLoadFuture = null;
    _characterConfigsLoadFuture = null;
    _invalidateManualSaveHeaders();
  }

  static void _invalidateManualSaveHeaders() {
    _manualSaveHeadersGeneration++;
    _cachedManualSaveHeaders = null;
    _manualSaveHeadersFuture = null;
  }

  // 获取当前游戏项目名称
  Future<String> _getCurrentProjectName() async {
    try {
      final projectName = await GamePathResolver.resolveProjectName();
      if (projectName != null && projectName.isNotEmpty) {
        return projectName;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('Error getting project name: $e');
      }
    }
    // 如果无法获取项目名称，使用默认值
    return 'DefaultProject';
  }

  static Future<String> _getApplicationDocumentsPath() async {
    final cached = _cachedApplicationDocumentsPath;
    if (cached != null) {
      return cached;
    }

    final activeResolution = _applicationDocumentsPathFuture;
    if (activeResolution != null) {
      return activeResolution;
    }

    final stopwatch = Stopwatch()..start();
    sakiDiagnosticLog('[SAKI_SAVE][DIR] documents-resolve-start');
    final resolution = () async {
      final directory = await getApplicationDocumentsDirectory();
      return directory.path;
    }();
    _applicationDocumentsPathFuture = resolution;
    try {
      final path = await resolution;
      _cachedApplicationDocumentsPath = path;
      stopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][DIR] documents-resolve-done '
        'elapsedMs=${stopwatch.elapsedMicroseconds / 1000.0}',
      );
      return path;
    } finally {
      if (identical(_applicationDocumentsPathFuture, resolution)) {
        _applicationDocumentsPathFuture = null;
      }
    }
  }

  Future<String> getSavesDirectory() async {
    final requestStopwatch = Stopwatch()..start();
    sakiDiagnosticLog('[SAKI_SAVE][DIR] request-start');
    final projectStopwatch = Stopwatch()..start();
    final projectName = await _getCurrentProjectName();
    projectStopwatch.stop();
    sakiDiagnosticLog(
      '[SAKI_SAVE][DIR] project-resolve-done project=$projectName '
      'elapsedMs=${projectStopwatch.elapsedMicroseconds / 1000.0}',
    );
    final cached = _cachedSavesDirectories[projectName];
    if (cached != null) {
      requestStopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][DIR] cache-hit project=$projectName '
        'totalMs=${requestStopwatch.elapsedMicroseconds / 1000.0}',
      );
      return cached;
    }

    sakiDiagnosticLog(
      '[SAKI_SAVE][DIR] documents-request-start project=$projectName',
    );
    final documentsPath = await _getApplicationDocumentsPath();
    sakiDiagnosticLog(
      '[SAKI_SAVE][DIR] documents-request-done project=$projectName',
    );
    final savesDir = Directory('$documentsPath/SakiEngine/Saves/$projectName');
    final existsStopwatch = Stopwatch()..start();
    if (!await savesDir.exists()) {
      await savesDir.create(recursive: true);
    }
    existsStopwatch.stop();
    final path = savesDir.path;
    _cachedSavesDirectories[projectName] = path;
    requestStopwatch.stop();
    sakiDiagnosticLog(
      '[SAKI_SAVE][DIR] cache-store project=$projectName path=$path '
      'existsMs=${existsStopwatch.elapsedMicroseconds / 1000.0} '
      'totalMs=${requestStopwatch.elapsedMicroseconds / 1000.0}',
    );
    return path;
  }

  String _quickSaveFileName(String? namespace) {
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

    final directory = await getSavesDirectory();
    final file = File('$directory/save_$slotId.sakisav');

    // 对话预览现在不再硬编码，而是在读取时实时查询
    // 这里保存空字符串，实际显示时会根据scriptIndex实时查询
    String dialoguePreview = '';

    // 生成截图数据
    Uint8List? screenshotData;
    try {
      screenshotData = await ScreenshotGenerator.generateScreenshotData(
        snapshot.currentState,
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
      isLocked: existingSlot?.isLocked ?? false, // 保持原有锁定状态
    );

    final binaryData = saveSlot.toBinary();
    await writeBinaryFileAtomically(file, binaryData);
    _invalidateManualSaveHeaders();
  }

  /// 快速存档功能
  Future<void> quickSave(
    String currentScript,
    GameStateSnapshot snapshot,
    Map<String, PoseConfig> poseConfigs, {
    String? namespace,
  }) async {
    final directory = await getSavesDirectory();
    final file = File('$directory/${_quickSaveFileName(namespace)}');

    // 生成截图数据
    Uint8List? screenshotData;
    try {
      screenshotData = await ScreenshotGenerator.generateScreenshotData(
        snapshot.currentState,
        poseConfigs,
      );
    } catch (e) {
      print('生成截图失败: $e');
    }

    final saveSlot = SaveSlot(
      id: -1, // 使用特殊ID表示快速存档
      saveTime: DateTime.now(),
      currentScript: currentScript,
      dialoguePreview: '',
      snapshot: snapshot,
      screenshotData: screenshotData,
      isLocked: false,
    );

    final binaryData = saveSlot.toBinary();
    await writeBinaryFileAtomically(file, binaryData);
  }

  /// 读取快速存档
  Future<SaveSlot?> loadQuickSave({String? namespace}) async {
    try {
      final directory = await getSavesDirectory();
      final file = File('$directory/${_quickSaveFileName(namespace)}');
      if (await file.exists()) {
        return await _readSaveSlotFile(file);
      }
    } catch (e) {
      print('Error loading quick save: $e');
    }
    return null;
  }

  /// 检查快速存档是否存在
  Future<bool> hasQuickSave({String? namespace}) async {
    try {
      final directory = await getSavesDirectory();
      final file = File('$directory/${_quickSaveFileName(namespace)}');
      return await file.exists();
    } catch (e) {
      print('Error checking quick save: $e');
      return false;
    }
  }

  Future<int> _readAutoSaveIndex() async {
    try {
      final directory = await getSavesDirectory();
      final file = File('$directory/$_autoSaveIndexFileName');
      if (!await file.exists()) {
        return 1;
      }

      final content = await file.readAsString();
      final parsed = int.tryParse(content.trim());
      if (parsed != null && parsed >= 1 && parsed <= _autoSaveSlotCount) {
        return parsed;
      }
    } catch (_) {
      // 忽略读取失败，回退到默认位置
    }
    return 1;
  }

  Future<void> _writeAutoSaveIndex(int index) async {
    final directory = await getSavesDirectory();
    final file = File('$directory/$_autoSaveIndexFileName');
    await file.writeAsString(index.toString(), flush: true);
  }

  /// 自动存档（环形缓冲）
  Future<void> autoSave(
    String currentScript,
    GameStateSnapshot snapshot, {
    String dialoguePreview = '',
    Map<String, PoseConfig>? poseConfigs,
  }) async {
    final directory = await getSavesDirectory();
    final currentIndex = await _readAutoSaveIndex();
    final file = File('$directory/${_autoSaveFilePrefix}$currentIndex.sakisav');
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
    await writeBinaryFileAtomically(file, binaryData);

    final nextIndex = currentIndex >= _autoSaveSlotCount ? 1 : currentIndex + 1;
    await _writeAutoSaveIndex(nextIndex);
  }

  /// 获取自动存档列表（按时间倒序）
  Future<List<SaveSlot>> listAutoSaveSlots() async {
    final directory = await getSavesDirectory();
    final autoSaveSlots = <SaveSlot>[];

    for (int i = 1; i <= _autoSaveSlotCount; i++) {
      final file = File('$directory/${_autoSaveFilePrefix}$i.sakisav');
      if (!await file.exists()) {
        continue;
      }

      try {
        final saveSlot = await _readSaveSlotFile(file);
        if (saveSlot != null) {
          autoSaveSlots.add(saveSlot);
        }
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
    final stopwatch = Stopwatch()..start();
    try {
      final directory = await getSavesDirectory();
      final file = File('$directory/save_$slotId.sakisav');
      if (await file.exists()) {
        final slot = await _readSaveSlotFile(file);
        stopwatch.stop();
        final bytes = await file.length();
        sakiDiagnosticLog(
          '[SAKI_SAVE][LOAD] slot=$slotId bytes=$bytes '
          'elapsedMs=${stopwatch.elapsedMicroseconds / 1000.0} '
          'success=${slot != null}',
        );
        return slot;
      }
    } catch (e) {
      print('Error loading game from slot $slotId: $e');
    }
    stopwatch.stop();
    sakiDiagnosticLog(
      '[SAKI_SAVE][LOAD] slot=$slotId elapsedMs='
      '${stopwatch.elapsedMicroseconds / 1000.0} success=false',
    );
    return null;
  }

  Future<List<SaveSlot>> listSaveSlots() async {
    final cached = _cachedManualSaveHeaders;
    if (cached != null) {
      sakiDiagnosticLog(
        '[SAKI_SAVE][LIST] backend=memory slots=${cached.length}',
      );
      return List<SaveSlot>.of(cached);
    }

    final activeLoad = _manualSaveHeadersFuture;
    if (activeLoad != null) {
      sakiDiagnosticLog('[SAKI_SAVE][LIST] backend=in-flight');
      return List<SaveSlot>.of(await activeLoad);
    }

    sakiDiagnosticLog(
      '[SAKI_SAVE][LIST] cache-miss generation=$_manualSaveHeadersGeneration',
    );
    final generation = _manualSaveHeadersGeneration;
    final load = _listSaveSlotsUncached();
    _manualSaveHeadersFuture = load;
    try {
      final slots = await load;
      if (_manualSaveHeadersGeneration == generation) {
        _cachedManualSaveHeaders = List<SaveSlot>.unmodifiable(slots);
      }
      return List<SaveSlot>.of(slots);
    } finally {
      if (identical(_manualSaveHeadersFuture, load)) {
        _manualSaveHeadersFuture = null;
      }
    }
  }

  Future<List<SaveSlot>> _listSaveSlotsUncached() async {
    final totalStopwatch = Stopwatch()..start();
    final directoryStopwatch = Stopwatch()..start();
    sakiDiagnosticLog('[SAKI_SAVE][LIST] directory-start');
    final directory = await getSavesDirectory();
    directoryStopwatch.stop();
    sakiDiagnosticLog(
      '[SAKI_SAVE][LIST] directory-done '
      'elapsedMs=${directoryStopwatch.elapsedMicroseconds / 1000.0}',
    );
    final nativeSlots = await _tryListSaveSlotsWithNativeIndex(directory);
    if (nativeSlots != null) {
      totalStopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][LIST] backend=rust slots=${nativeSlots.length} '
        'directoryMs=${directoryStopwatch.elapsedMicroseconds / 1000.0} '
        'totalMs=${totalStopwatch.elapsedMicroseconds / 1000.0}',
      );
      return nativeSlots;
    }

    final files = await Directory(directory).list().toList();
    sakiDiagnosticLog(
      '[SAKI_SAVE][LIST] dart-fallback-enumerated files=${files.length} '
      'elapsedMs=${totalStopwatch.elapsedMilliseconds}',
    );
    //print('DEBUG: 找到 ${files.length} 个文件');

    final saveSlots = <SaveSlot>[];

    for (var fileEntity in files) {
      //print('DEBUG: 检查文件: ${fileEntity.path}');

      if (fileEntity is File &&
          RegExp(
            r'^save_\d+\.sakisav$',
          ).hasMatch(p.basename(fileEntity.path))) {
        //print('DEBUG: 尝试读取存档文件: ${fileEntity.path}');
        try {
          final fileStopwatch = Stopwatch()..start();
          sakiDiagnosticLog(
            '[SAKI_SAVE][LIST] dart-file-start '
            'file=${p.basename(fileEntity.path)}',
          );
          final saveSlot = await _readSaveSlotFile(fileEntity);
          fileStopwatch.stop();
          sakiDiagnosticLog(
            '[SAKI_SAVE][LIST] dart-file-done '
            'file=${p.basename(fileEntity.path)} '
            'success=${saveSlot != null} '
            'elapsedMs=${fileStopwatch.elapsedMicroseconds / 1000.0}',
          );
          if (saveSlot == null) {
            continue;
          }
          //print('DEBUG: 成功解析存档，ID=${saveSlot.id}, 时间=${saveSlot.saveTime}');

          saveSlots.add(saveSlot);
        } catch (e, stackTrace) {
          print('ERROR: 读取存档文件失败 ${fileEntity.path}:');
          print('ERROR: 异常信息: $e');
          print('ERROR: 堆栈跟踪: $stackTrace');
        }
      } else {
        //print('DEBUG: 跳过非存档文件: ${fileEntity.path}');
      }
    }

    //print('DEBUG: 最终解析出 ${saveSlots.length} 个有效存档');
    saveSlots.sort((a, b) => a.id.compareTo(b.id));
    totalStopwatch.stop();
    sakiDiagnosticLog(
      '[SAKI_SAVE][LIST] backend=dart slots=${saveSlots.length} '
      'files=${files.length} '
      'directoryMs=${directoryStopwatch.elapsedMicroseconds / 1000.0} '
      'totalMs=${totalStopwatch.elapsedMicroseconds / 1000.0}',
    );
    return saveSlots;
  }

  /// 获取指定范围的存档位信息（懒加载支持）
  Future<List<SaveSlot?>> listSaveSlotsInRange(
    int startSlotId,
    int endSlotId,
  ) async {
    final directory = await getSavesDirectory();
    final nativeSlots = await _tryListSaveSlotsWithNativeIndex(
      directory,
      startSlotId: startSlotId,
      endSlotId: endSlotId,
    );
    if (nativeSlots != null) {
      final slotsById = <int, SaveSlot>{
        for (final slot in nativeSlots) slot.id: slot,
      };
      return <SaveSlot?>[
        for (int slotId = startSlotId; slotId <= endSlotId; slotId++)
          slotsById[slotId],
      ];
    }

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

  Future<List<SaveSlot>?> _tryListSaveSlotsWithNativeIndex(
    String directory, {
    int startSlotId = 1,
    int endSlotId = 0x7fffffff,
  }) async {
    if (_nativeSaveIndexUnavailable) {
      sakiDiagnosticLog(
        '[SAKI_SAVE][INDEX] skip reason=previously-unavailable',
      );
      return null;
    }

    final totalStopwatch = Stopwatch()..start();
    final initStopwatch = Stopwatch()..start();
    sakiDiagnosticLog('[SAKI_SAVE][INDEX] native-init-start');
    final nativeAvailable = await SakiNativeRuntime.ensureInitialized();
    initStopwatch.stop();
    sakiDiagnosticLog(
      '[SAKI_SAVE][INDEX] native-init-done available=$nativeAvailable '
      'elapsedMs=${initStopwatch.elapsedMicroseconds / 1000.0}',
    );
    if (!nativeAvailable) {
      return null;
    }

    try {
      final scanStopwatch = Stopwatch()..start();
      sakiDiagnosticLog(
        '[SAKI_SAVE][INDEX] rust-scan-start '
        'range=$startSlotId..$endSlotId',
      );
      final result = await scanSaveHeaders(
        directory: directory,
        startSlotId: startSlotId,
        endSlotId: endSlotId,
      );
      scanStopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][INDEX] rust-scan-return '
        'slots=${result.slots.length} '
        'nativeMs=${result.elapsedMicros.toDouble() / 1000.0} '
        'awaitMs=${scanStopwatch.elapsedMicroseconds / 1000.0}',
      );
      if (result.invalidFiles.isNotEmpty) {
        print(
          '[SAKI_SAVE][INDEX] native-invalid='
          '${result.invalidFiles.length} first=${result.invalidFiles.first}',
        );
        // A native codec built against an older save format reports newer,
        // otherwise valid saves as invalid. Returning its partial result here
        // makes occupied slots appear empty. Let the Dart compatibility
        // decoder inspect every file whenever the native scan is incomplete.
        sakiDiagnosticLog(
          '[SAKI_SAVE][INDEX] backend=rust incomplete; '
          'using Dart fallback',
        );
        return null;
      }
      final conversionStopwatch = Stopwatch()..start();
      sakiDiagnosticLog('[SAKI_SAVE][INDEX] bridge-convert-start');
      final slots = result.slots.map(_saveSlotFromNativeHeader).toList();
      conversionStopwatch.stop();
      totalStopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][INDEX] bridge-convert-done '
        'elapsedMs=${conversionStopwatch.elapsedMicroseconds / 1000.0}',
      );

      sakiDiagnosticLog(
        '[SAKI_SAVE][INDEX] backend=rust slots=${slots.length} '
        'nativeMs=${result.elapsedMicros.toDouble() / 1000.0} '
        'totalMs=${totalStopwatch.elapsedMicroseconds / 1000.0} '
        'invalid=${result.invalidFiles.length}',
      );
      return slots;
    } catch (error, stackTrace) {
      _nativeSaveIndexUnavailable = true;
      print(
        '[SAKI_SAVE][INDEX] backend=rust unavailable; '
        'using Dart fallback: $error',
      );
      if (kEngineDebugMode) {
        print(stackTrace);
      }
      return null;
    }
  }

  SaveSlot _saveSlotFromNativeHeader(RustSaveHeader header) {
    final preview = _previewFromNativeHeader(header);
    return SaveSlot(
      id: header.id,
      saveTime: DateTime.fromMillisecondsSinceEpoch(header.saveTimeMillis),
      currentScript: header.currentScript,
      dialoguePreview: preview,
      snapshot: GameStateSnapshot(
        scriptIndex: header.scriptIndex,
        currentState: GameState(dialogue: preview.isEmpty ? '...' : preview),
      ),
      screenshotFilePath: header.filePath,
      screenshotOffset: header.screenshotOffset,
      screenshotLength: header.screenshotLength,
      isLocked: header.isLocked,
    );
  }

  String _previewFromNativeHeader(RustSaveHeader header) {
    if (header.previewKind == 'menu' && header.previewChoices.isNotEmpty) {
      final localization = LocalizationManager();
      final choices = header.previewChoices
          .map((choice) => '[$choice]')
          .join('\n');
      return '${localization.t('saveLoad.choiceMenu')}\n$choices';
    }

    final text = header.previewText;
    if (text != null && text.isNotEmpty) {
      final speaker = header.previewSpeaker;
      if (speaker != null && speaker.isNotEmpty) {
        return '【$speaker】${RichTextParser.cleanText(text)}';
      }
      return RichTextParser.cleanText(text);
    }

    return header.dialoguePreview;
  }

  Future<Uint8List?> loadSaveScreenshot(SaveSlot slot) async {
    if (slot.screenshotData != null) {
      return slot.screenshotData;
    }

    final path = slot.screenshotFilePath;
    final offset = slot.screenshotOffset;
    final length = slot.screenshotLength;
    if (path == null || offset == null || length == null || length <= 0) {
      return null;
    }

    RandomAccessFile? file;
    final stopwatch = Stopwatch()..start();
    sakiDiagnosticLog(
      '[SAKI_SAVE][THUMBNAIL] start slot=${slot.id} bytes=$length',
    );
    var success = false;
    try {
      file = await File(path).open();
      await file.setPosition(offset);
      final data = await file.read(length);
      success = data.length == length;
      return success ? data : null;
    } catch (error) {
      if (kEngineDebugMode) {
        print(
          '[SAVE_INDEX] screenshot read failed for slot ${slot.id}: $error',
        );
      }
      return null;
    } finally {
      await file?.close();
      stopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][THUMBNAIL] done slot=${slot.id} '
        'bytes=$length success=$success '
        'elapsedMs=${stopwatch.elapsedMicroseconds / 1000.0}',
      );
    }
  }

  /// 获取所有存在的存档位ID（用于快速检测存档分布）
  Future<List<int>> getExistingSaveSlotIds() async {
    final directory = await getSavesDirectory();
    final files = await Directory(directory).list().toList();
    final existingIds = <int>[];

    for (var fileEntity in files) {
      if (fileEntity is File && fileEntity.path.endsWith('.sakisav')) {
        try {
          // 从文件名提取ID: save_123.sakisav -> 123
          final fileName = p.basenameWithoutExtension(fileEntity.path);
          if (fileName.startsWith('save_')) {
            final idStr = fileName.substring(5);
            final id = int.tryParse(idStr);
            if (id != null) {
              existingIds.add(id);
            }
          }
        } catch (e) {
          // 忽略解析错误的文件名
        }
      }
    }

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

    final directory = await getSavesDirectory();
    final file = File('$directory/save_$slotId.sakisav');
    if (await file.exists()) {
      await file.delete();
      _invalidateManualSaveHeaders();
    }
  }

  Future<bool> moveSave(int fromSlotId, int toSlotId) async {
    if (fromSlotId == toSlotId) return false;

    final directory = await getSavesDirectory();
    final fromFile = File('$directory/save_$fromSlotId.sakisav');
    final toFile = File('$directory/save_$toSlotId.sakisav');

    if (!await fromFile.exists()) {
      return false;
    }

    try {
      final saveSlot = await loadGame(fromSlotId);
      if (saveSlot == null) return false;

      // 检查源存档是否被锁定
      if (saveSlot.isLocked) return false;

      // 检查目标位置是否有被锁定的存档
      final targetSlot = await loadGame(toSlotId);
      if (targetSlot?.isLocked == true) return false;

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
      await writeBinaryFileAtomically(toFile, binaryData);
      await fromFile.delete();
      _invalidateManualSaveHeaders();

      return true;
    } catch (e) {
      print('Error moving save from slot $fromSlotId to $toSlotId: $e');
      return false;
    }
  }

  Future<bool> swapSaves(int slotId1, int slotId2) async {
    if (slotId1 == slotId2) return false;

    final directory = await getSavesDirectory();
    final file1 = File('$directory/save_$slotId1.sakisav');
    final file2 = File('$directory/save_$slotId2.sakisav');

    final exists1 = await file1.exists();
    final exists2 = await file2.exists();

    if (!exists1 && !exists2) return false;

    try {
      SaveSlot? saveSlot1;
      SaveSlot? saveSlot2;

      if (exists1) {
        saveSlot1 = await loadGame(slotId1);
        if (saveSlot1?.isLocked == true) return false; // 检查锁定状态
      }
      if (exists2) {
        saveSlot2 = await loadGame(slotId2);
        if (saveSlot2?.isLocked == true) return false; // 检查锁定状态
      }

      if (exists1) await file1.delete();
      if (exists2) await file2.delete();

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
        await writeBinaryFileAtomically(file2, binaryData);
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
        await writeBinaryFileAtomically(file1, binaryData);
      }

      _invalidateManualSaveHeaders();
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
      final directory = await getSavesDirectory();
      final file = File('$directory/save_$slotId.sakisav');
      final binaryData = updatedSlot.toBinary();
      await writeBinaryFileAtomically(file, binaryData);
      _invalidateManualSaveHeaders();
      return true;
    } catch (e) {
      print('Error toggling lock for slot $slotId: $e');
      return false;
    }
  }

  static Future<void> writeBinaryFileAtomically(
    File targetFile,
    Uint8List data,
  ) async {
    await targetFile.parent.create(recursive: true);

    final isSakiSave =
        data.length >= 4 &&
        data[0] == 0x53 &&
        data[1] == 0x41 &&
        data[2] == 0x4b &&
        data[3] == 0x49;
    if (isSakiSave && await SakiNativeRuntime.ensureInitialized()) {
      try {
        final metadata = await writeSaveFile(path: targetFile.path, data: data);
        if (kEngineDebugMode && !_nativeSaveCodecLogged) {
          _nativeSaveCodecLogged = true;
          print(
            '[SAKI_NATIVE][SAVE] codec active '
            'version=${metadata.version}',
          );
        }
        return;
      } catch (error, stackTrace) {
        if (kEngineDebugMode) {
          print(
            '[SAKI_NATIVE][SAVE] native write rejected data; '
            'Dart fallback enabled: $error',
          );
          print(stackTrace);
        }
      }
    }

    final tempPath =
        '${targetFile.path}.tmp.${DateTime.now().microsecondsSinceEpoch}';
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsBytes(data, flush: true);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {
          // 忽略清理失败
        }
      }
    }
  }

  SaveSlot? _decodeSaveSlot(Uint8List binaryData, String filePath) {
    if (binaryData.length < 8) {
      if (kEngineDebugMode) {
        print('跳过损坏存档（长度过短）: $filePath');
      }
      return null;
    }

    final magic = String.fromCharCodes(binaryData.sublist(0, 4));
    if (magic != 'SAKI') {
      if (kEngineDebugMode) {
        print('跳过非SAKI格式存档: $filePath');
      }
      return null;
    }

    try {
      return SaveSlot.fromBinary(binaryData);
    } catch (e) {
      if (kEngineDebugMode) {
        print('解析存档失败 $filePath: $e');
      }
      return null;
    }
  }

  Future<SaveSlot?> _readSaveSlotFile(File file) async {
    Uint8List binaryData;
    if (await SakiNativeRuntime.ensureInitialized()) {
      try {
        final decoded = await readSaveFile(path: file.path);
        binaryData = decoded.data;
        if (kEngineDebugMode && !_nativeSaveCodecLogged) {
          _nativeSaveCodecLogged = true;
          print(
            '[SAKI_NATIVE][SAVE] codec active '
            'version=${decoded.metadata.version}',
          );
        }
      } catch (error) {
        if (kEngineDebugMode) {
          print(
            '[SAKI_NATIVE][SAVE] native read failed for ${file.path}; '
            'Dart compatibility decoder will retry: $error',
          );
        }
        binaryData = await file.readAsBytes();
      }
    } else {
      binaryData = await file.readAsBytes();
    }
    return _decodeSaveSlot(binaryData, file.path);
  }
}

class GameConfigManager {
  /// 保存游戏配置到.sakiconfig文件
  Future<void> saveConfig(GameConfig config) async {
    final directory = await getApplicationDocumentsDirectory();
    final configDir = Directory('${directory.path}/SakiEngine');
    if (!await configDir.exists()) {
      await configDir.create(recursive: true);
    }

    final file = File('${configDir.path}/game.sakiconfig');
    final binaryData = config.toBinary();
    await SaveLoadManager.writeBinaryFileAtomically(file, binaryData);
  }

  /// 从.sakiconfig文件加载游戏配置
  Future<GameConfig> loadConfig() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/SakiEngine/game.sakiconfig');
      if (await file.exists()) {
        final binaryData = await file.readAsBytes();
        return GameConfig.fromBinary(binaryData);
      }
    } catch (e) {
      print('Error loading config: $e');
    }
    return GameConfig.defaultConfig();
  }
}

/// 游戏配置类
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
