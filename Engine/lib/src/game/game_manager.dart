import 'dart:ui' as ui;
import 'dart:async';
import 'dart:io';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/config/config_parser.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/game/script_merger.dart';
import 'package:sakiengine/src/game/save_load_manager.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/localization/script_text_localizer.dart';
import 'package:sakiengine/src/widgets/common/black_screen_transition.dart';
import 'package:sakiengine/src/effects/scene_filter.dart';
import 'package:sakiengine/src/effects/scene_transition_effects.dart';
import 'package:sakiengine/src/utils/music_manager.dart';
import 'package:sakiengine/src/utils/animation_manager.dart';
import 'package:sakiengine/src/utils/scene_animation_controller.dart';
import 'package:sakiengine/src/utils/character_position_animator.dart';
import 'package:sakiengine/src/utils/character_auto_distribution.dart';
import 'package:sakiengine/src/utils/rich_text_parser.dart';
import 'package:sakiengine/src/utils/global_variable_manager.dart';
import 'package:sakiengine/src/utils/webp_preload_cache.dart';
import 'package:sakiengine/src/utils/smart_cg_predictor.dart';
import 'package:sakiengine/src/utils/cg_script_pre_analyzer.dart';
import 'package:sakiengine/src/rendering/composite_cg_renderer.dart';
import 'package:sakiengine/src/utils/cg_image_compositor.dart';
import 'package:sakiengine/src/utils/cg_pre_warm_manager.dart';
import 'package:sakiengine/src/utils/gpu_image_compositor.dart';
import 'package:sakiengine/src/utils/expression_offset_manager.dart';
import 'package:sakiengine/src/utils/character_composite_cache.dart';
import 'package:sakiengine/src/rendering/color_background_renderer.dart';
import 'package:sakiengine/src/game/story_flowchart_manager.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/game/nvl_state_manager.dart';
import 'package:sakiengine/src/game/chapter_autosave_manager.dart';

part 'game_manager_lifecycle.dart';

enum _NvlContextMode { none, standard, movie, noMask }

class _MenuPromptDialogue {
  final String? speaker;
  final String dialogue;
  final String? dialogueTag;
  final int scriptIndex;
  final String? sourceScriptFile;
  final int? sourceLine;

  const _MenuPromptDialogue({
    required this.speaker,
    required this.dialogue,
    required this.dialogueTag,
    required this.scriptIndex,
    required this.sourceScriptFile,
    required this.sourceLine,
  });
}

class _MenuJumpTarget {
  final int menuIndex;
  final List<_MenuPromptDialogue> promptDialogues;

  const _MenuJumpTarget({
    required this.menuIndex,
    required this.promptDialogues,
  });
}

/// 音乐区间类
/// 定义音乐播放的有效范围，从play music到下一个play music/stop music之间
class MusicRegion {
  final String musicFile; // 音乐文件名
  final int startScriptIndex; // 区间开始的脚本索引
  final int? endScriptIndex; // 区间结束的脚本索引（null表示区间还没结束）

  MusicRegion({
    required this.musicFile,
    required this.startScriptIndex,
    this.endScriptIndex,
  });

  /// 检查指定的脚本索引是否在音乐区间内
  bool containsIndex(int scriptIndex) {
    if (scriptIndex < startScriptIndex) return false;
    if (endScriptIndex != null && scriptIndex >= endScriptIndex!) return false;
    return true;
  }

  /// 创建一个新的区间，设置结束索引
  MusicRegion copyWithEndIndex(int endIndex) {
    return MusicRegion(
      musicFile: musicFile,
      startScriptIndex: startScriptIndex,
      endScriptIndex: endIndex,
    );
  }

  @override
  String toString() {
    return 'MusicRegion(musicFile: $musicFile, start: $startScriptIndex, end: $endScriptIndex)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MusicRegion) return false;
    return musicFile == other.musicFile &&
        startScriptIndex == other.startScriptIndex &&
        endScriptIndex == other.endScriptIndex;
  }

  @override
  int get hashCode {
    return Object.hash(musicFile, startScriptIndex, endScriptIndex);
  }
}

class ScriptApiExecutionResult {
  final bool handled;
  final GameState? nextState;
  final Duration? waitDuration;
  final GameState? stateAfterWait;

  const ScriptApiExecutionResult({
    required this.handled,
    this.nextState,
    this.waitDuration,
    this.stateAfterWait,
  });

  const ScriptApiExecutionResult.unhandled()
      : handled = false,
        nextState = null,
        waitDuration = null,
        stateAfterWait = null;

  factory ScriptApiExecutionResult.handled({
    GameState? nextState,
    Duration? waitDuration,
    GameState? stateAfterWait,
  }) {
    return ScriptApiExecutionResult(
      handled: true,
      nextState: nextState,
      waitDuration: waitDuration,
      stateAfterWait: stateAfterWait,
    );
  }
}

typedef ScriptApiExecutor = Future<ScriptApiExecutionResult> Function({
  required String apiName,
  required Map<String, String> params,
  required GameState gameState,
  required int scriptIndex,
});

class GameManager {
  static const bool _musicRegionVerboseLogs = bool.fromEnvironment(
    'SAKI_MUSIC_REGION_LOG',
    defaultValue: false,
  );
  static const bool _fxDiagLogs = bool.fromEnvironment(
    'SAKI_FX_DIAG',
    defaultValue: true,
  );

  final _gameStateController = StreamController<GameState>.broadcast();
  Stream<GameState> get gameStateStream => _gameStateController.stream;

  late GameState _currentState;
  late ScriptNode _script;
  int _scriptIndex = 0;
  bool _isProcessing = false;
  bool _isWaitingForTimer = false; // 新增：专门的计时器等待标志
  Timer? _currentTimer; // 新增：当前活跃的计时器引用
  VoidCallback? _currentTimerCompletion;
  Map<String, int> _labelIndexMap = {};

  // 脚本合并器
  final ScriptMerger _scriptMerger = ScriptMerger();
  SupportedLanguage _activeLanguage = SupportedLanguage.zhHans;
  bool _isLanguageReloading = false;
  late final VoidCallback _languageListener;

  Map<String, CharacterConfig> _characterConfigs = {};
  Map<String, PoseConfig> _poseConfigs = {};
  VoidCallback? onReturn;
  final ScriptApiExecutor? onScriptApiExecute;
  final String defaultSceneTransitionType;
  BuildContext? _context;
  TickerProvider? _tickerProvider;
  Future<ui.Image?> Function()? _transitionFrameCapturer;
  final Set<String> _everShownCharacters = {};
  static const String _globalCgCharacterKey = '__global_cg__';

  // 快进状态
  bool _isFastForwardMode = false;
  bool _disableRuntimeSideEffectsForTesting = false;
  _NvlContextMode _activeNvlContext = _NvlContextMode.none;
  bool _showNvlOverlayOnNextDialogue = false;

  // 待处理的章节自动存档信息（章节背景显示后，等待第一句话再存档）
  String? _pendingChapterAutoSaveLabel; // 待存档的章节label

  // 章节自动存档管理器
  final ChapterAutoSaveManager _chapterAutoSaveManager =
      ChapterAutoSaveManager();

  // 场景动画控制器
  SceneAnimationController? _sceneAnimationController;

  // 角色位置动画管理器
  CharacterPositionAnimator? _characterPositionAnimator;

  // CG脚本预分析器
  final CgScriptPreAnalyzer _cgPreAnalyzer = CgScriptPreAnalyzer();

  // 智能CG预测器
  final SmartCgPredictor _smartPredictor = SmartCgPredictor();

  // 剧情流程图管理器
  final StoryFlowchartManager _flowchartManager = StoryFlowchartManager();

  /// 检查是否需要创建自动存档
  Future<void> _checkAndCreateAutoSave(int scriptIndex,
      {String? reason}) async {
    if (_disableRuntimeSideEffectsForTesting) {
      return;
    }
    try {
      final node = _script.children[scriptIndex];
      String? nodeId;
      String? displayName;
      StoryNodeType? nodeType;

      // 判断节点类型
      if (node is BackgroundNode && _containsChapter(node.background)) {
        // 章节开始
        nodeId = 'chapter_${_extractChapterName(node.background)}';
        displayName = _extractChapterName(node.background);
        nodeType = StoryNodeType.chapter;
      } else if (node is MenuNode) {
        // 分支选择
        final label = _findNearestLabel(scriptIndex) ?? 'menu_$scriptIndex';
        nodeId = 'branch_$scriptIndex';
        displayName = '分支选择: $label';
        nodeType = StoryNodeType.branch;
      }
      // 注意：章节末尾的自动存档由 _checkChapterEndAutoSave 处理

      if (nodeId != null && nodeType != null) {
        // 创建自动存档
        final saveSlot = SaveSlot(
          id: int.parse(DateTime.now()
              .millisecondsSinceEpoch
              .toString()
              .substring(0, 10)),
          saveTime: DateTime.now(),
          currentScript: currentScriptFile,
          dialoguePreview: displayName ?? '自动存档',
          snapshot: saveStateSnapshot(),
          screenshotData: null,
        );

        // 保存到流程图管理器，并获取实际的 autoSaveId
        final actualAutoSaveId =
            await _flowchartManager.createAutoSaveForNode(nodeId, saveSlot);

        // 解锁节点，使用实际的 autoSaveId
        await _flowchartManager.unlockNode(nodeId,
            autoSaveId: actualAutoSaveId);

        if (kEngineDebugMode) {
          //print('[AutoSave] 创建自动存档: $displayName (原因: $reason)');
        }
      }
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[AutoSave] 创建自动存档失败: $e');
      }
    }
  }

  Future<void> _createRuntimeAutoSave({required String reason}) async {
    if (_disableRuntimeSideEffectsForTesting) {
      return;
    }
    try {
      await SaveLoadManager().autoSave(
        currentScriptFile,
        saveStateSnapshot(),
        dialoguePreview: reason,
        poseConfigs: _poseConfigs,
      );
    } catch (e) {
      if (kEngineDebugMode) {
        print('[AutoSave] 运行时自动存档失败($reason): $e');
      }
    }
  }

  /// 在返回主菜单前触发自动存档（供外部UI主动返回时调用）
  Future<void> createAutoSaveBeforeMainMenu() async {
    await _createRuntimeAutoSave(reason: '返回主菜单');
  }

  /// 查找章节结束前的最后一个有对话的scene
  /// 章节结束可能是：jump到下一章、遇到下一个chapter背景、或return
  int? _findLastSceneWithDialogueBeforeChapterEnd(int startIndex) {
    // 从startIndex往前找所有scene
    for (int i = startIndex - 1; i >= 0; i--) {
      final node = _script.children[i];
      if (node is BackgroundNode || node is MovieNode) {
        // 找到一个scene，检查它后面（到下一个scene或章节结束之间）是否有对话
        bool hasDialogue = false;
        for (int j = i + 1; j < startIndex; j++) {
          final checkNode = _script.children[j];
          // 如果遇到下一个scene，停止检查
          if (checkNode is BackgroundNode || checkNode is MovieNode) {
            break;
          }
          // 如果有对话节点，标记为有对话
          if (checkNode is SayNode || checkNode is ConditionalSayNode) {
            hasDialogue = true;
            break;
          }
        }

        // 如果这个scene后面有对话，就是我们要找的
        if (hasDialogue) {
          return i;
        }
      }
    }
    return null;
  }

  /// 检查当前scene是否是章节末尾前最后一个有对话的scene
  /// 如果是则创建自动存档,用于解锁流程图跳转功能
  Future<void> _checkChapterEndAutoSave(int sceneIndex) async {
    final currentNode = _script.children[sceneIndex];
    String sceneName = '';
    if (currentNode is BackgroundNode) {
      sceneName = currentNode.background;
    } else if (currentNode is MovieNode) {
      sceneName = currentNode.movieFile;
    }

    if (kEngineDebugMode) {
      //print('[AutoSave] 检查scene是否为章节末尾: $sceneName (index: $sceneIndex)');
    }

    // 获取当前所在章节(通过label名称判断,如cp0_xxx)
    final currentLabel = _findNearestLabel(sceneIndex);
    String? currentChapter;
    if (currentLabel != null) {
      final chapterMatch = RegExp(r'^cp(\d+)_').firstMatch(currentLabel);
      if (chapterMatch != null) {
        currentChapter = chapterMatch.group(1);
      }
    }

    if (currentChapter == null) {
      if (kEngineDebugMode) {
        //print('[AutoSave] ❌ $sceneName 无法确定所在章节');
      }
      return;
    }

    // 从当前scene往后查找章节结束点
    for (int i = sceneIndex + 1; i < _script.children.length; i++) {
      final node = _script.children[i];

      // 情况1: 遇到return节点 (回主菜单)
      if (node is ReturnNode) {
        final lastSceneIndex = _findLastSceneWithDialogueBeforeChapterEnd(i);
        if (kEngineDebugMode) {
          //print('[AutoSave] 找到return节点 (index: $i), return前最后一个有对话的scene是: $lastSceneIndex, 当前scene: $sceneIndex');
        }

        if (lastSceneIndex == sceneIndex) {
          await _createChapterEndAutoSave(sceneIndex, sceneName, i);
        } else {
          if (kEngineDebugMode) {
            //print('[AutoSave] ❌ $sceneName 不是章节末尾: 不是return前最后一个有对话的scene');
          }
        }
        return;
      }

      // 情况2: 遇到下一个章节的背景
      if (node is BackgroundNode &&
          _containsChapter(node.background) &&
          i != sceneIndex) {
        final lastSceneIndex = _findLastSceneWithDialogueBeforeChapterEnd(i);
        if (kEngineDebugMode) {
          //print('[AutoSave] 找到下一章节背景 ${node.background} (index: $i), 前面最后一个有对话的scene是: $lastSceneIndex, 当前scene: $sceneIndex');
        }

        if (lastSceneIndex == sceneIndex) {
          await _createChapterEndAutoSave(sceneIndex, sceneName, i);
        } else {
          if (kEngineDebugMode) {
            //print('[AutoSave] ❌ $sceneName 不是章节末尾: 不是下一章前最后一个有对话的scene');
          }
        }
        return;
      }

      // 情况3: 遇到jump节点，检查是否跳转到下一章
      if (node is JumpNode) {
        // 检查jump目标label是否是不同的章节
        final targetLabel = node.targetLabel;
        final targetChapterMatch = RegExp(r'^cp(\d+)_').firstMatch(targetLabel);

        if (targetChapterMatch != null) {
          final targetChapter = targetChapterMatch.group(1);

          // 只有跨章节的jump才算章节末尾
          if (targetChapter != currentChapter) {
            final lastSceneIndex =
                _findLastSceneWithDialogueBeforeChapterEnd(i);
            if (kEngineDebugMode) {
              //print('[AutoSave] 找到跨章节jump: cp$currentChapter -> cp$targetChapter (index: $i), 前面最后一个有对话的scene是: $lastSceneIndex, 当前scene: $sceneIndex');
            }

            if (lastSceneIndex == sceneIndex) {
              await _createChapterEndAutoSave(sceneIndex, sceneName, i);
            } else {
              if (kEngineDebugMode) {
                //print('[AutoSave] ❌ $sceneName 不是章节末尾: 不是跨章节jump前最后一个有对话的scene');
              }
            }
            return;
          } else {
            if (kEngineDebugMode) {
              //print('[AutoSave] 跳过同章节jump: $targetLabel (当前章节: cp$currentChapter)');
            }
          }
        }
      }
    }

    if (kEngineDebugMode) {
      //print('[AutoSave] ❌ $sceneName 不是章节末尾: 未找到章节结束点');
    }
  }

  /// 创建章节末尾自动存档
  Future<void> _createChapterEndAutoSave(
      int sceneIndex, String sceneName, int endIndex) async {
    // 获取当前章节编号并构建语言无关的ID
    final currentLabel = _findNearestLabel(sceneIndex);
    String chapterIdSuffix = 'unknown';
    String chapterDisplayName = 'unknown';

    if (currentLabel != null) {
      final chapterMatch = RegExp(r'^cp(\d+)_').firstMatch(currentLabel);
      if (chapterMatch != null) {
        final chapterNum = chapterMatch.group(1);
        chapterIdSuffix = chapterNum!; // 例如: "0", "1", "2"
        chapterDisplayName = '第${chapterNum}章';
      }
    }

    // 使用与流程图分析器一致的节点ID格式: chapter_end_{number}
    final nodeId = 'chapter_end_$chapterIdSuffix';
    final displayName = '${chapterDisplayName}末尾';

    if (kEngineDebugMode) {
      //print('[AutoSave] ✅ $sceneName 是章节末尾! 创建自动存档: $displayName (节点ID: $nodeId)');
    }

    // 创建自动存档
    final saveSlot = SaveSlot(
      id: int.parse(
          DateTime.now().millisecondsSinceEpoch.toString().substring(0, 10)),
      saveTime: DateTime.now(),
      currentScript: currentScriptFile,
      dialoguePreview: displayName,
      snapshot: saveStateSnapshot(),
      screenshotData: null,
    );

    // 保存到流程图管理器
    final actualAutoSaveId =
        await _flowchartManager.createAutoSaveForNode(nodeId, saveSlot);

    // 解锁节点
    await _flowchartManager.unlockNode(nodeId, autoSaveId: actualAutoSaveId);

    if (kEngineDebugMode) {
      //print('[AutoSave] 章节末尾自动存档创建完成: $displayName (scene: $sceneIndex, end: $endIndex, autoSaveId: $actualAutoSaveId)');
    }
  }

  /// 查找最近的label
  String? _findNearestLabel(int index) {
    for (int i = index; i >= 0; i--) {
      if (_script.children[i] is LabelNode) {
        return (_script.children[i] as LabelNode).name;
      }
    }
    return null;
  }

  /// 提取章节名
  String _extractChapterName(String bgName) {
    final chapterMatch =
        RegExp(r'chapter[_\s-]?(\d+)', caseSensitive: false).firstMatch(bgName);
    if (chapterMatch != null) {
      return '第${chapterMatch.group(1)}章';
    }

    final chMatch =
        RegExp(r'\bch(\d+)\b', caseSensitive: false).firstMatch(bgName);
    if (chMatch != null) {
      return '第${chMatch.group(1)}章';
    }

    if (bgName.toLowerCase().contains('prologue')) return '序章';
    if (bgName.toLowerCase().contains('epilogue')) return '尾声';

    return bgName;
  }

  /// 检测并播放角色属性变化动画（用于pose切换）
  Future<void> _checkAndAnimatePoseAttributeChanges({
    required String characterId,
    required String? oldPositionId,
    required String? newPositionId,
  }) async {
    if (_tickerProvider == null || oldPositionId == newPositionId) return;

    // 获取旧的和新的pose配置
    final oldPoseConfig =
        oldPositionId != null ? _poseConfigs[oldPositionId] : null;
    final newPoseConfig =
        newPositionId != null ? _poseConfigs[newPositionId] : null;

    if (oldPoseConfig == null || newPoseConfig == null) return;

    // 比较属性，创建变化描述
    final fromAttributes = <String, double>{
      'xcenter': oldPoseConfig.xcenter,
      'ycenter': oldPoseConfig.ycenter,
      'scale': oldPoseConfig.scale,
      'alpha': 1.0, // 暂时硬编码，后续可扩展
    };

    final toAttributes = <String, double>{
      'xcenter': newPoseConfig.xcenter,
      'ycenter': newPoseConfig.ycenter,
      'scale': newPoseConfig.scale,
      'alpha': 1.0, // 暂时硬编码，后续可扩展
    };

    final attributeChange = CharacterAttributeChange(
      characterId: characterId,
      fromAttributes: fromAttributes,
      toAttributes: toAttributes,
    );

    // 如果没有变化，跳过动画
    if (!attributeChange.hasChanges) return;

    //print('[PoseAttributeAnimation] 检测到属性变化: $characterId');
    //print('[PoseAttributeAnimation] 从 $oldPositionId 到 $newPositionId');
    //print('[PoseAttributeAnimation] 属性变化: $fromAttributes -> $toAttributes');

    // 停止之前的动画
    _characterPositionAnimator?.stop();
    _characterPositionAnimator = CharacterPositionAnimator();

    // 开始属性补间动画
    await _characterPositionAnimator!.animateAttributeChanges(
      attributeChanges: [attributeChange],
      vsync: _tickerProvider!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      onUpdate: (attributesMap) {
        // 更新角色的动画属性
        final updatedCharacters =
            Map<String, CharacterState>.from(_currentState.characters);
        final attributes = attributesMap[characterId];

        if (attributes != null) {
          final character = updatedCharacters[characterId];
          if (character != null) {
            updatedCharacters[characterId] = character.copyWith(
              animationProperties: attributes,
            );

            // 立即更新状态以显示动画效果
            _currentState =
                _currentState.copyWith(characters: updatedCharacters);
            _gameStateController.add(_currentState);
          }
        }
      },
      onComplete: () {
        //print('[PoseAttributeAnimation] 属性动画完成: $characterId');
        // 动画完成后，清除动画属性，让角色使用新pose的正常属性
        final updatedCharacters =
            Map<String, CharacterState>.from(_currentState.characters);
        final character = updatedCharacters[characterId];
        if (character != null) {
          updatedCharacters[characterId] = character.copyWith(
            animationProperties: null, // 清除动画属性，回到新pose的基础位置
          );
          _currentState = _currentState.copyWith(characters: updatedCharacters);
          _gameStateController.add(_currentState);
        }
      },
    );
  }

  Future<void> _checkAndAnimateCharacterPositions(
      Map<String, CharacterState> newCharacters) async {
    if (_tickerProvider == null) return;

    //print('[CharacterPositionAnimation] 检测位置变化...');
    //print('[CharacterPositionAnimation] 旧角色: ${_currentState.characters.keys.toList()}');
    //print('[CharacterPositionAnimation] 新角色: ${newCharacters.keys.toList()}');

    // 检测位置变化
    final characterOrder = newCharacters.keys.toList();
    final positionChanges = CharacterAutoDistribution.calculatePositionChanges(
      _currentState.characters,
      newCharacters,
      _poseConfigs,
      _poseConfigs,
      characterOrder,
    );

    //print('[CharacterPositionAnimation] 检测到 ${positionChanges.length} 个位置变化');
    for (final change in positionChanges) {
      //print('[CharacterPositionAnimation] ${change.characterId}: ${change.fromX} -> ${change.toX}');
    }

    if (positionChanges.isNotEmpty) {
      // 如果有位置变化，播放动画
      _characterPositionAnimator?.stop();
      _characterPositionAnimator = CharacterPositionAnimator();

      //print('[CharacterPositionAnimation] 开始播放位置动画...');

      await _characterPositionAnimator!.animatePositionChanges(
        positionChanges: positionChanges,
        vsync: _tickerProvider!,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        onUpdate: (positions) {
          // 更新角色的动画属性
          final updatedCharacters =
              Map<String, CharacterState>.from(_currentState.characters);
          for (final entry in positions.entries) {
            final characterId = entry.key;
            final xPosition = entry.value;
            final character = updatedCharacters[characterId];
            if (character != null) {
              updatedCharacters[characterId] = character.copyWith(
                animationProperties: {
                  ...character.animationProperties ?? {},
                  'xcenter': xPosition,
                },
              );
            }
          }

          _currentState = _currentState.copyWith(characters: updatedCharacters);
          _gameStateController.add(_currentState);
        },
        onComplete: () {
          // 动画完成，清理动画属性
          //print('[CharacterPositionAnimation] 角色位置动画完成');
        },
      );
    } else {
      //print('[CharacterPositionAnimation] 无需位置动画');
    }
  }

  /// 智能分析并预热局部CG组合
  void _analyzeCgCombinationsAndPreWarm({bool isLoadGame = false}) {
    if (kEngineDebugMode) {}

    // 获取当前标签
    String? currentLabel;
    if (_scriptIndex < _script.children.length) {
      // 向前查找最近的标签
      for (int i = _scriptIndex; i >= 0; i--) {
        final node = _script.children[i];
        if (node is LabelNode) {
          currentLabel = node.name;
          if (kEngineDebugMode) {}
          break;
        }
      }

      // 如果向前没找到，向后查找最近的标签
      if (currentLabel == null) {
        for (int i = _scriptIndex; i < _script.children.length; i++) {
          final node = _script.children[i];
          if (node is LabelNode) {
            currentLabel = node.name;
            if (kEngineDebugMode) {}
            break;
          }
        }
      }
    }

    // 如果是新游戏且在位置0没找到标签，向后查找第一个标签
    if (!isLoadGame && _scriptIndex == 0 && currentLabel == null) {
      for (int i = 0; i < _script.children.length; i++) {
        final node = _script.children[i];
        if (node is LabelNode) {
          currentLabel = node.name;
          if (kEngineDebugMode) {}
          break;
        }
      }
    }

    if (currentLabel == null) {
      if (kEngineDebugMode) {}
    }

    // 使用智能预热
    _smartPredictor.smartPreWarm(
      scriptNodes: _script.children,
      currentIndex: _scriptIndex,
      currentLabel: currentLabel,
    );
  }

  /// 轻量级初始预热 - 只预热游戏开始附近的少量CG
  void _performLightweightInitialPreWarm() {
    if (kEngineDebugMode) {}

    // 只搜索前200行的CG组合
    final lightRange = 200;
    final combinations = <String, Set<String>>{};

    for (int i = 0; i < lightRange && i < _script.children.length; i++) {
      final node = _script.children[i];
      if (node is CgNode) {
        final resourceId = node.character;
        final pose = node.pose ?? 'pose1';
        final expression = node.expression ?? 'happy';

        final key = '${resourceId}_$pose';
        if (!combinations.containsKey(key)) {
          combinations[key] = <String>{};
        }
        combinations[key]!.add(expression);

        // 限制最多预热5个CG组合，避免过度预热
        if (combinations.length >= 5) break;
      }
    }

    if (combinations.isNotEmpty) {
      if (kEngineDebugMode) {
        combinations.forEach((key, expressions) {
          print('  轻量级CG: $key -> ${expressions.take(2).toList()}'); // 只显示前2个表情
        });
      }

      // 异步预热，延迟执行避免影响启动速度
      Future.delayed(const Duration(milliseconds: 1000), () {
        _preWarmLightweightCombinations(combinations);
      });
    } else {
      if (kEngineDebugMode) {}
    }
  }

  /// 预热轻量级组合
  void _preWarmLightweightCombinations(
      Map<String, Set<String>> combinations) async {
    int totalPrewarmed = 0;

    for (final entry in combinations.entries) {
      final parts = entry.key.split('_');
      if (parts.length >= 3) {
        final resourceId = parts.sublist(0, parts.length - 1).join('_');
        final pose = parts.last;
        final expressions = entry.value;

        // 每个组合只预热前2个表情
        final limitedExpressions = expressions.take(2);

        for (final expression in limitedExpressions) {
          try {
            await CgScriptPreAnalyzer().precomposeCg(
              resourceId: resourceId,
              pose: pose,
              expression: expression,
            );
            totalPrewarmed++;

            // 每个预热后暂停一下，避免阻塞UI
            if (totalPrewarmed % 2 == 0) {
              await Future.delayed(const Duration(milliseconds: 50));
            }
          } catch (e) {
            // 静默处理失败
          }
        }
      }
    }

    if (kEngineDebugMode) {}
  }

  /// 分析脚本并预加载anime资源
  Future<void> _analyzeAndPreloadAnimeResources() async {
    final animeResources = <String>{};

    // 遍历整个脚本，收集所有anime命令
    for (int i = 0; i < _script.children.length; i++) {
      final node = _script.children[i];
      if (node is AnimeNode) {
        animeResources.add(node.animeName);
      }
    }

    if (animeResources.isEmpty) {
      return;
    }

    // 并发预加载所有anime资源
    final futures = animeResources.map<Future<dynamic>>((animeName) {
      return WebPPreloadCache().preloadWebP(animeName);
    }).toList();

    try {
      await Future.wait(futures);
    } catch (e) {
      if (kEngineDebugMode) {
        ////print('[GameManager] anime资源预加载出现错误: $e');
      }
      rethrow;
    }
  }

  String? _findExistingCharacterKey(String resourceId) {
    ////print('[GameManager] 查找resourceId=$resourceId的角色，当前角色列表: ${_currentState.characters.keys}');
    for (final entry in _currentState.characters.entries) {
      ////print('[GameManager] 检查角色 ${entry.key}, resourceId=${entry.value.resourceId}');
      if (entry.value.resourceId == resourceId) {
        ////print('[GameManager] 找到匹配的角色: ${entry.key}');
        return entry.key;
      }
    }
    ////print('[GameManager] 未找到resourceId=$resourceId的角色');
    return null;
  }

  GameStateSnapshot? _savedSnapshot;

  List<DialogueHistoryEntry> _dialogueHistory = [];
  static const int maxHistoryEntries = 100;

  // 音乐区间管理
  final List<MusicRegion> _musicRegions = []; // 所有音乐区间的列表

  // Getters for accessing configurations
  Map<String, PoseConfig> get poseConfigs => _poseConfigs;
  String get currentScriptFile =>
      _scriptMerger.getFileNameByIndex(_scriptIndex) ?? 'start';

  // 获取当前脚本执行索引（用于开发者面板定位）
  int get currentScriptIndex => _scriptIndex;

  // 获取当前对话文本（用于开发者面板定位）
  String get currentDialogueText =>
      _dialogueHistory.isNotEmpty ? _dialogueHistory.last.dialogue : '';

  /// 获取当前显示对话的精确来源行号（1-based）。
  /// 该值由解析器在构建节点时写入，优先作为脚本修改定位依据。
  int? get currentDialogueSourceLine =>
      _dialogueHistory.isNotEmpty ? _dialogueHistory.last.sourceLine : null;

  /// 获取当前显示对话的来源脚本名（不含扩展名）。
  String? get currentDialogueSourceScriptFile => _dialogueHistory.isNotEmpty
      ? _dialogueHistory.last.sourceScriptFile
      : null;

  /// 获取当前显示对话在当前脚本文件中的“同文案出现序号”（1-based）。
  /// 用于在脚本存在重复台词时，精准定位当前句而不是总命中第一句。
  int estimateCurrentDialogueOccurrenceInFile({
    required String dialogue,
    String? speakerName,
    String? scriptCharacterKey,
  }) {
    if (_script.children.isEmpty) {
      return 1;
    }

    final targetNodeIndex = _dialogueHistory.isNotEmpty
        ? _dialogueHistory.last.scriptIndex
        : (_scriptIndex > 0 ? _scriptIndex - 1 : _scriptIndex);
    final safeTargetIndex =
        targetNodeIndex.clamp(0, _script.children.length - 1).toInt();
    final currentFile = currentScriptFile;
    final fileStart = _scriptMerger.getFileStartIndex(currentFile) ?? 0;

    var occurrence = 0;
    for (int i = fileStart;
        i <= safeTargetIndex && i < _script.children.length;
        i++) {
      final node = _script.children[i];
      String? nodeDialogue;
      String? nodeCharacterKey;

      if (node is SayNode) {
        nodeDialogue = _resolveScriptText(node.dialogue);
        nodeCharacterKey = node.character;
      } else if (node is ConditionalSayNode) {
        nodeDialogue = _resolveScriptText(node.dialogue);
        nodeCharacterKey = node.character;
      } else {
        continue;
      }

      if (!_isDialogueTextEquivalent(nodeDialogue, dialogue)) {
        continue;
      }
      if (speakerName != null &&
          speakerName.isNotEmpty &&
          !_isSpeakerNameEquivalent(nodeCharacterKey, speakerName)) {
        continue;
      }
      if (scriptCharacterKey != null &&
          scriptCharacterKey.isNotEmpty &&
          !_isScriptCharacterKeyCompatible(
              nodeCharacterKey, scriptCharacterKey)) {
        continue;
      }

      occurrence++;
    }

    if (kEngineDebugMode) {
      print(
          'GameManager: 当前对话出现序号估算 file=$currentFile, targetNodeIndex=$safeTargetIndex, occurrence=$occurrence, dialogue="$dialogue", speaker="$speakerName", scriptCharacterKey=$scriptCharacterKey');
    }
    return occurrence > 0 ? occurrence : 1;
  }

  bool _isDialogueTextEquivalent(String? a, String b) {
    if (a == null) {
      return false;
    }
    String normalize(String text) {
      final localized = ScriptTextLocalizer.resolve(text);
      return localized
          .replaceAll('"', '')
          .replaceAll('「', '')
          .replaceAll('」', '')
          .trim();
    }

    return normalize(a) == normalize(b);
  }

  bool _isSpeakerNameEquivalent(String? nodeCharacterKey, String speakerName) {
    if (nodeCharacterKey == null) {
      return false;
    }
    final cfg = _characterConfigs[nodeCharacterKey];
    if (cfg != null && cfg.name == speakerName) {
      return true;
    }
    return nodeCharacterKey == speakerName;
  }

  bool _isScriptCharacterKeyCompatible(
      String? nodeCharacterKey, String expectedCharacterKey) {
    if (nodeCharacterKey == null || expectedCharacterKey.isEmpty) {
      return false;
    }
    if (nodeCharacterKey == expectedCharacterKey) {
      return true;
    }
    if (!nodeCharacterKey.startsWith(expectedCharacterKey)) {
      return false;
    }
    if (nodeCharacterKey.length == expectedCharacterKey.length) {
      return true;
    }
    final nextChar = nodeCharacterKey[expectedCharacterKey.length];
    return RegExp(r'[A-Za-z_]').hasMatch(nextChar);
  }

  // 获取当前游戏状态（用于表情选择器）
  GameState get currentState => _currentState;

  // 获取角色配置（用于表情选择器）
  Map<String, CharacterConfig> get characterConfigs => _characterConfigs;

  /// Debug: 立即应用背景到当前运行时状态（不等待脚本推进到scene行）。
  /// 主要用于开发者面板/命令轮盘的“边改边看”体验。
  void applyDebugBackgroundImmediately(
    String backgroundName, {
    bool clearCharacters = false,
  }) {
    final normalized = backgroundName.trim();
    if (normalized.isEmpty) {
      return;
    }
    if (kEngineDebugMode) {
      print('[GameManager] Debug即时切背景: $normalized');
    }

    _currentState = _currentState.copyWith(
      background: normalized,
      clearMovieFile: true,
      clearSceneFilter: true,
      clearSceneLayers: true,
      clearSceneAnimation: true,
      clearCgCharacters: true,
      clearCharacters: clearCharacters,
      clearDialogueAndSpeaker: false,
      forceNullCurrentNode: true,
      everShownCharacters: _everShownCharacters,
    );
    _gameStateController.add(_currentState);
  }

  /// 分析脚本中CG差分的表达式变化
  /// 查找指定resourceId和pose在当前位置附近的所有表达式
  List<String> analyzeCgExpressions(String resourceId, String pose,
      {int lookAheadLines = 10}) {
    final expressions = <String>{};
    final currentIndex = _scriptIndex;

    // 向前查找
    for (int i = currentIndex;
        i < _script.children.length && i < currentIndex + lookAheadLines;
        i++) {
      final node = _script.children[i];
      if (node is CgNode) {
        // 检查是否是同一个CG的不同差分
        final nodeResourceId = _getResourceIdForCharacter(node.character);
        final nodePose = node.pose ?? 'pose1';

        if (nodeResourceId == resourceId && nodePose == pose) {
          final expression = node.expression ?? 'happy';
          expressions.add(expression);
        }
      }
    }

    // 向后也查找一些
    for (int i = currentIndex - 1; i >= 0 && i >= currentIndex - 5; i--) {
      final node = _script.children[i];
      if (node is CgNode) {
        final nodeResourceId = _getResourceIdForCharacter(node.character);
        final nodePose = node.pose ?? 'pose1';

        if (nodeResourceId == resourceId && nodePose == pose) {
          final expression = node.expression ?? 'happy';
          expressions.add(expression);
        }
      }
    }

    return expressions.toList();
  }

  /// 获取角色的resourceId
  String _getResourceIdForCharacter(String character) {
    final characterConfig = _characterConfigs[character];
    if (characterConfig != null) {
      return characterConfig.resourceId;
    }
    return character;
  }

  /// 获取角色在立绘层里的唯一槽位 key。
  /// - 配置了 `slot:` 的角色共用同一槽位（用于多套立绘自动互替）
  /// - 未配置 `slot:` 时退回到现有行为（resourceId 或原始别名）
  String _resolveCharacterRenderKey(
    String? characterAlias, {
    CharacterConfig? characterConfig,
  }) {
    if (characterAlias == null || characterAlias.isEmpty) {
      return '';
    }
    final config = characterConfig ?? _characterConfigs[characterAlias];
    final slotId = config?.slotId?.trim();
    if (slotId != null && slotId.isNotEmpty) {
      return 'slot:$slotId';
    }
    if (config != null) {
      return config.resourceId;
    }
    return characterAlias;
  }

  ({
    String alias,
    CharacterConfig config,
  })? _resolveCharacterIdentityByAliasOrResourceId(String aliasOrResourceId) {
    final normalized = aliasOrResourceId.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final byAlias = _characterConfigs[normalized];
    if (byAlias != null) {
      return (
        alias: normalized,
        config: byAlias,
      );
    }

    for (final entry in _characterConfigs.entries) {
      if (entry.value.resourceId == normalized) {
        return (
          alias: entry.key,
          config: entry.value,
        );
      }
    }
    return null;
  }

  MapEntry<String, CharacterState>? _resolveTailTargetCharacterState(
      String targetAlias) {
    final identity = _resolveCharacterIdentityByAliasOrResourceId(targetAlias);
    final resolvedAlias = identity?.alias ?? targetAlias;
    final config = identity?.config;
    final targetKey =
        _resolveCharacterRenderKey(resolvedAlias, characterConfig: config);
    final direct = _currentState.characters[targetKey];
    if (direct != null) {
      return MapEntry<String, CharacterState>(targetKey, direct);
    }

    final expectedResourceId = config?.resourceId ?? targetAlias;
    if (expectedResourceId != null && expectedResourceId.isNotEmpty) {
      for (final entry in _currentState.characters.entries) {
        if (entry.value.resourceId == expectedResourceId) {
          return entry;
        }
      }
    }
    return null;
  }

  bool _applyNarrationTailCharacterDiff({
    required String targetAlias,
    String? pose,
    String? expression,
    String? animation,
    int? repeatCount,
  }) {
    final target = _resolveTailTargetCharacterState(targetAlias);
    if (target == null) {
      return false;
    }

    final targetConfig =
        _resolveCharacterIdentityByAliasOrResourceId(targetAlias)?.config;
    final targetKey = target.key;
    final targetState = target.value;
    final nextPose = pose ?? targetState.pose ?? 'pose1';
    final nextExpression = expression ?? targetState.expression ?? 'normal';
    final nextResourceId = targetConfig?.resourceId ?? targetState.resourceId;
    final newCharacters = Map.of(_currentState.characters);
    newCharacters[targetKey] = targetState.copyWith(
      resourceId: nextResourceId,
      pose: nextPose,
      expression: nextExpression,
      clearAnimationProperties: false,
    );
    _currentState = _currentState.copyWith(
      characters: newCharacters,
      everShownCharacters: _everShownCharacters,
    );
    _gameStateController.add(_currentState);
    if (!_isFastForwardMode && animation != null && animation.isNotEmpty) {
      _playCharacterAnimation(
        targetKey,
        animation,
        repeatCount: repeatCount,
      );
    }
    if (kEngineDebugMode) {
      print(
          'GameManager: narration-tail apply target=$targetAlias key=$targetKey pose=$nextPose expression=$nextExpression animation=$animation repeat=$repeatCount');
    }
    return true;
  }

  ({
    String apiName,
    Map<String, String> params,
  })? _parseInlineApiToken(String rawToken) {
    final trimmed = rawToken.trim();
    if (trimmed.length <= 3 || !trimmed.toLowerCase().startsWith('api')) {
      return null;
    }

    final payload = trimmed.substring(3).trim();
    if (payload.isEmpty) {
      return null;
    }

    final params = <String, String>{};

    // 语法1: api<name>(k=v,k2=v2)
    final leftParenIndex = payload.indexOf('(');
    if (leftParenIndex > 0 && payload.endsWith(')')) {
      final apiName = payload.substring(0, leftParenIndex).trim();
      if (apiName.isEmpty) {
        return null;
      }
      final content = payload.substring(leftParenIndex + 1, payload.length - 1);
      _parseInlineApiPairs(content, params);
      return (
        apiName: apiName,
        params: params,
      );
    }

    // 语法2: api<name>?k=v&k2=v2
    final queryIndex = payload.indexOf('?');
    if (queryIndex > 0) {
      final apiName = payload.substring(0, queryIndex).trim();
      if (apiName.isEmpty) {
        return null;
      }
      final query = payload.substring(queryIndex + 1).trim();
      _parseInlineApiQuery(query, params);
      return (
        apiName: apiName,
        params: params,
      );
    }

    // 语法3: api<name>:k=v,color=#fff
    final colonIndex = payload.indexOf(':');
    if (colonIndex > 0) {
      final apiName = payload.substring(0, colonIndex).trim();
      if (apiName.isEmpty) {
        return null;
      }
      final content = payload.substring(colonIndex + 1).trim();
      _parseInlineApiPairs(content, params);
      return (
        apiName: apiName,
        params: params,
      );
    }

    // 语法4: api<name>
    return (
      apiName: payload,
      params: params,
    );
  }

  void _parseInlineApiPairs(String raw, Map<String, String> out) {
    if (raw.trim().isEmpty) {
      return;
    }
    bool capturedBareValue = false;
    final segments = raw.split(RegExp(r'[;,]'));
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex <= 0) {
        if (!capturedBareValue) {
          capturedBareValue = true;
          out['value'] = _trimWrappingQuotes(trimmed);
        }
        continue;
      }
      final key = trimmed.substring(0, eqIndex).trim().toLowerCase();
      final value = _trimWrappingQuotes(trimmed.substring(eqIndex + 1).trim());
      if (key.isEmpty) {
        continue;
      }
      out[key] = value;
    }
  }

  void _parseInlineApiQuery(String raw, Map<String, String> out) {
    if (raw.trim().isEmpty) {
      return;
    }
    final segments = raw.split('&');
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex <= 0) {
        final key = Uri.decodeQueryComponent(trimmed).trim().toLowerCase();
        if (key.isNotEmpty) {
          out[key] = 'true';
        }
        continue;
      }
      final key = Uri.decodeQueryComponent(trimmed.substring(0, eqIndex))
          .trim()
          .toLowerCase();
      final value =
          Uri.decodeQueryComponent(trimmed.substring(eqIndex + 1)).trim();
      if (key.isEmpty) {
        continue;
      }
      out[key] = value;
    }
  }

  String _trimWrappingQuotes(String value) {
    if (value.length < 2) {
      return value;
    }
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<void> _applyInlineApiTokenForSay({
    required String? inlineApiToken,
    required String? characterAlias,
    required String? tailCharacterAlias,
  }) async {
    final token = inlineApiToken?.trim();
    if (token == null || token.isEmpty) {
      return;
    }

    final parsed = _parseInlineApiToken(token);
    if (parsed == null) {
      return;
    }

    final params = <String, String>{};
    params.addAll(parsed.params);

    final targetAlias = (characterAlias ?? '').trim().isNotEmpty
        ? characterAlias!.trim()
        : ((tailCharacterAlias ?? '').trim().isNotEmpty
            ? tailCharacterAlias!.trim()
            : null);
    if (targetAlias != null && targetAlias.isNotEmpty) {
      params.putIfAbsent('target', () => targetAlias);
      params.putIfAbsent('character', () => targetAlias);
      final target = _resolveTailTargetCharacterState(targetAlias);
      if (target != null) {
        params.putIfAbsent('target_key', () => target.key);
        params.putIfAbsent('render_key', () => target.key);
        params.putIfAbsent('resource_id', () => target.value.resourceId);
      }
    }

    final executor = onScriptApiExecute;
    if (executor == null) {
      return;
    }

    final result = await executor(
      apiName: parsed.apiName,
      params: params,
      gameState: _currentState,
      scriptIndex: _scriptIndex,
    );

    if (!result.handled) {
      return;
    }

    if (result.nextState != null) {
      _currentState = result.nextState!;
      _gameStateController.add(_currentState);
    }

    final waitDuration = result.waitDuration;
    if (waitDuration != null && waitDuration > Duration.zero) {
      if (kEngineDebugMode) {
        print(
            '[GameManager] inline api token ${parsed.apiName} 返回了 waitDuration=$waitDuration，当前按即时模式忽略延时。');
      }
      return;
    }

    if (result.stateAfterWait != null) {
      _applyScriptApiStateAfterWait(result.stateAfterWait!);
    }
  }

  // 快进模式控制
  bool get isFastForwardMode => _isFastForwardMode;
  void setFastForwardMode(bool enabled) {
    _isFastForwardMode = enabled;
    // 更新GameState中的快进状态
    _currentState = _currentState.copyWith(
        isFastForwarding: enabled, everShownCharacters: _everShownCharacters);
    _gameStateController.add(_currentState);
    if (enabled) {
      _completeCurrentTimerWait();
    }
    //print('[FastForward] 快进模式: ${enabled ? "开启" : "关闭"}');
  }

  // 自动播放模式控制
  bool _isAutoPlayMode = false;
  bool get isAutoPlayMode => _isAutoPlayMode;
  void setAutoPlayMode(bool enabled) {
    _isAutoPlayMode = enabled;
    // 更新GameState中的自动播放状态
    _currentState = _currentState.copyWith(
        isAutoPlaying: enabled, everShownCharacters: _everShownCharacters);
    _gameStateController.add(_currentState);
    //print('[AutoPlay] 自动播放模式: ${enabled ? "开启" : "关闭"}');
  }

  void _applyScriptApiStateAfterWait(GameState stateAfterWait) {
    _currentState = stateAfterWait.copyWith(
      isFastForwarding: _isFastForwardMode,
      isAutoPlaying: _isAutoPlayMode,
      everShownCharacters: _everShownCharacters,
    );
    _gameStateController.add(_currentState);
  }

  bool _completeCurrentTimerWait() {
    if (!_isWaitingForTimer) {
      return false;
    }

    final completion = _currentTimerCompletion;
    if (_currentTimer == null && completion == null) {
      return false;
    }

    _currentTimer?.cancel();
    _currentTimer = null;
    _currentTimerCompletion = null;
    _isWaitingForTimer = false;

    if (_currentState.isPaused) {
      _currentState = _currentState.copyWith(
        isPaused: false,
        everShownCharacters: _everShownCharacters,
      );
      _gameStateController.add(_currentState);
    }

    if (completion != null) {
      completion();
    } else {
      unawaited(_executeScript());
    }
    return true;
  }

  /// 检测背景名称是否包含章节信息
  /// 检测规则：包含以下关键字之一（不区分大小写）：
  /// - "chapter"
  /// - "ch" (后跟数字)
  /// - "ep" (episode的缩写)
  /// - "prologue" (序章)
  /// - "epilogue" (尾声)
  bool _containsChapter(String backgroundName) {
    final lowerName = backgroundName.toLowerCase();

    // 检测常见的章节标识
    if (lowerName.contains('chapter') ||
        lowerName.contains('prologue') ||
        lowerName.contains('epilogue')) {
      return true;
    }

    // 检测 ch + 数字 的模式（如 ch1, ch01, chapter1 等）
    if (RegExp(r'\bch\d+\b').hasMatch(lowerName)) {
      return true;
    }

    // 检测 ep + 数字 的模式（如 ep1, ep01 等）
    if (RegExp(r'\bep\d+\b').hasMatch(lowerName)) {
      return true;
    }

    return false;
  }

  /// 检查当前场景是否包含章节标识
  /// 用于决定是否应该隐藏快捷菜单
  bool get isCurrentSceneChapter {
    // 检查当前背景是否包含章节标识
    final currentBg = _currentState.background;
    if (currentBg != null && _containsChapter(currentBg)) {
      return true;
    }

    // 检查当前视频是否包含章节标识
    final currentMovie = _currentState.movieFile;
    if (currentMovie != null && _containsChapter(currentMovie)) {
      return true;
    }

    return false;
  }

  GameManager({
    this.onReturn,
    this.onScriptApiExecute,
    String defaultSceneTransitionType = 'fade',
  }) : defaultSceneTransitionType = defaultSceneTransitionType.trim().isEmpty
            ? 'fade'
            : defaultSceneTransitionType.trim() {
    _currentState = GameState.initial(); // 提前初始化，避免late变量访问错误
    _activeLanguage = LocalizationManager().currentLanguage;
    _languageListener = _handleLanguageChange;
    LocalizationManager().addListener(_languageListener);
  }

  @visibleForTesting
  Future<void> startTestScript(
    ScriptNode script, {
    int scriptIndex = 0,
    GameState? initialState,
    bool disableRuntimeSideEffects = true,
  }) async {
    _currentTimer?.cancel();
    _currentTimer = null;
    _currentTimerCompletion = null;
    _isProcessing = false;
    _isWaitingForTimer = false;
    _isFastForwardMode = false;
    _disableRuntimeSideEffectsForTesting = disableRuntimeSideEffects;
    _activeNvlContext = _NvlContextMode.none;
    _showNvlOverlayOnNextDialogue = false;
    _script = script;
    _scriptIndex = scriptIndex.clamp(0, _script.children.length).toInt();
    _currentState = initialState ?? GameState.initial();
    _dialogueHistory = [];
    _buildLabelIndexMap();
    _buildMusicRegions();
    await _executeScript();
  }

  Future<void> startGame(String scriptName) {
    _disableRuntimeSideEffectsForTesting = false;
    return _startGameLifecycle(scriptName);
  }

  Future<void> restoreFromSnapshot(
    String scriptName,
    GameStateSnapshot snapshot, {
    bool shouldReExecute = true,
  }) {
    _disableRuntimeSideEffectsForTesting = false;
    return _restoreFromSnapshotLifecycle(
      scriptName,
      snapshot,
      shouldReExecute: shouldReExecute,
    );
  }

  @visibleForTesting
  static String? findNearestRestorableBackgroundForTest(
    ScriptNode script,
    int scriptIndex,
  ) {
    return _findNearestScriptBackground(script, scriptIndex);
  }

  static String? _findNearestScriptBackground(
    ScriptNode script,
    int scriptIndex,
  ) {
    if (script.children.isEmpty) {
      return null;
    }

    final startIndex = scriptIndex.clamp(0, script.children.length - 1).toInt();
    for (var i = startIndex; i >= 0; i--) {
      final node = script.children[i];
      if (node is BackgroundNode) {
        return node.background;
      }
    }

    return null;
  }

  Future<void> hotReload(String scriptName) {
    _disableRuntimeSideEffectsForTesting = false;
    return _hotReloadLifecycle(scriptName);
  }

  void _handleLanguageChange() {
    final newLanguage = LocalizationManager().currentLanguage;
    if (newLanguage == _activeLanguage) {
      return;
    }
    _activeLanguage = newLanguage;

    if (!_isScriptInitialized() || _isLanguageReloading) {
      return;
    }

    _isLanguageReloading = true;
    final scriptName = currentScriptFile;

    Future.microtask(() async {
      try {
        await hotReload(scriptName);
      } catch (e, stack) {
        if (kEngineDebugMode) {
          print(
              '[GameManager] Failed to reload scripts after language change: $e');
          print(stack);
        }
      } finally {
        _isLanguageReloading = false;
      }
    });
  }

  String _resolveScriptText(String text) {
    return ScriptTextLocalizer.resolve(text, language: _activeLanguage);
  }

  MenuNode _localizeMenuNode(MenuNode node) {
    final localizedChoices = node.choices
        .map(
          (choice) => ChoiceOptionNode(
            _resolveScriptText(choice.text),
            choice.targetLabel,
          ),
        )
        .toList();
    return MenuNode(localizedChoices);
  }

  /// 设置BuildContext用于转场效果
  void setContext(
    BuildContext context, [
    TickerProvider? tickerProvider,
    Future<ui.Image?> Function()? transitionFrameCapturer,
  ]) {
    //////print('[GameManager] 设置上下文用于转场效果');
    _context = context;
    _tickerProvider = tickerProvider;
    _transitionFrameCapturer = transitionFrameCapturer;

    // 如果当前状态有场景动画且之前没有TickerProvider，现在检测并启动动画
    if (tickerProvider != null && _sceneAnimationController == null) {
      // 延迟一点时间执行动画检测，确保context完全设置好
      Future.delayed(const Duration(milliseconds: 50), () async {
        if (_tickerProvider != null) {
          await _checkAndRestoreSceneAnimation();
        }
      });
    }
  }

  String _normalizeMusicFileName(String rawMusicFile) {
    var musicFile = rawMusicFile.trim();
    if ((musicFile.startsWith('"') && musicFile.endsWith('"')) ||
        (musicFile.startsWith("'") && musicFile.endsWith("'"))) {
      if (musicFile.length >= 2) {
        musicFile = musicFile.substring(1, musicFile.length - 1).trim();
      }
    }
    return musicFile;
  }

  String _buildMusicAssetPath(String rawMusicFile) {
    var musicFile = _normalizeMusicFileName(rawMusicFile);
    if (musicFile.isEmpty) {
      return '';
    }
    if (!musicFile.contains('.')) {
      musicFile = '$musicFile.mp3';
    }
    return 'Assets/music/$musicFile';
  }

  /// 构建音乐区间列表
  /// 遍历整个脚本，找出所有的play music和stop music节点，创建音乐区间
  void _buildMusicRegions() {
    _musicRegions.clear();

    MusicRegion? currentRegion;

    for (int i = 0; i < _script.children.length; i++) {
      final node = _script.children[i];

      if (node is PlayMusicNode) {
        final normalizedMusicFile = _normalizeMusicFileName(node.musicFile);
        if (normalizedMusicFile.isEmpty) {
          if (kEngineDebugMode && _musicRegionVerboseLogs) {
            print('[MusicRegion] 忽略空音乐名: raw="${node.musicFile}" at index $i');
          }
          continue;
        }
        // 结束当前区间（如果有的话）
        if (currentRegion != null) {
          _musicRegions.add(currentRegion.copyWithEndIndex(i));
        }

        // 开始新的音乐区间
        currentRegion = MusicRegion(
          musicFile: normalizedMusicFile,
          startScriptIndex: i,
        );
        if (kEngineDebugMode && _musicRegionVerboseLogs) {
          print(
              '[MusicRegion] 开始新音乐区间: raw="${node.musicFile}" normalized="$normalizedMusicFile" at index $i');
        }
      } else if (node is StopMusicNode) {
        // 结束当前区间
        if (currentRegion != null) {
          _musicRegions.add(currentRegion.copyWithEndIndex(i));
          if (kEngineDebugMode) {
            //print('[MusicRegion] 结束音乐区间: ${currentRegion.musicFile} at index $i');
          }
          currentRegion = null;
        }
      }
    }

    // 如果脚本结束时还有未结束的音乐区间，添加它
    if (currentRegion != null) {
      _musicRegions.add(currentRegion);
      if (kEngineDebugMode) {
        //print('[MusicRegion] 脚本结束，添加未结束的音乐区间: ${currentRegion.musicFile}');
      }
    }

    if (kEngineDebugMode) {
      //print('[MusicRegion] 总共构建了 ${_musicRegions.length} 个音乐区间');
      for (final region in _musicRegions) {
        //print('[MusicRegion] $region');
      }
    }
  }

  /// 获取指定脚本索引处应该播放的音乐区间
  MusicRegion? _getMusicRegionForIndex(int scriptIndex) {
    for (final region in _musicRegions) {
      if (region.containsIndex(scriptIndex)) {
        return region;
      }
    }
    return null;
  }

  /// 检查当前位置是否应该播放音乐
  /// 如果当前位置不在任何音乐区间内，则停止音乐
  Future<void> _checkMusicRegionAtCurrentIndex(
      {bool forceCheck = false}) async {
    if (!forceCheck &&
        _scriptIndex >= 0 &&
        _scriptIndex < _script.children.length &&
        _script.children[_scriptIndex] is PlayMusicNode) {
      if (kEngineDebugMode && _musicRegionVerboseLogs) {
        print(
            '[MusicRegion] 跳过区间触发播放：当前位置($_scriptIndex)是 PlayMusicNode，由节点执行阶段处理');
      }
      return;
    }

    final currentRegion = _getMusicRegionForIndex(_scriptIndex);
    final stateRegion = _currentState.currentMusicRegion;

    if (kEngineDebugMode) {
      //print('[MusicRegion] 检查位置($_scriptIndex): currentRegion=${currentRegion?.toString() ?? 'null'}, stateRegion=${stateRegion?.toString() ?? 'null'}');
    }

    // 强制检查时，即使区间相同也要验证音乐状态
    if (forceCheck || currentRegion != stateRegion) {
      if (currentRegion == null) {
        // 当前位置不在任何音乐区间内，应该停止音乐
        if (kEngineDebugMode) {
          //print('[MusicRegion] 当前位置($_scriptIndex)不在音乐区间内，停止音乐');
        }
        await MusicManager().forceStopBackgroundMusic(
          fadeOut: true,
          fadeDuration: const Duration(milliseconds: 800),
        );
        _currentState = _currentState.copyWith(currentMusicRegion: null);
      } else {
        // 当前位置在音乐区间内
        final fullMusicPath = _buildMusicAssetPath(currentRegion.musicFile);
        if (fullMusicPath.isEmpty) {
          if (kEngineDebugMode) {
            print(
                '[MusicRegion] 当前位置($_scriptIndex)音乐名为空，跳过播放: region=$currentRegion');
          }
          _currentState = _currentState.copyWith(currentMusicRegion: null);
          return;
        }

        final isExpectedMusicPlaying =
            MusicManager().isPlayingMusic(fullMusicPath);
        final shouldPlayMusic = !isExpectedMusicPlaying ||
            (stateRegion != null &&
                stateRegion.musicFile != currentRegion.musicFile);

        // 检查是否需要开始播放或切换音乐。强制检查只验证状态，不重复重播同一首正在播放的音乐。
        if (shouldPlayMusic) {
          if (kEngineDebugMode && _musicRegionVerboseLogs) {
            print(
                '[MusicRegion] 当前位置($_scriptIndex)需要播放音乐: regionMusic="${currentRegion.musicFile}", resolvedPath="$fullMusicPath", forceCheck=$forceCheck');
          }

          await MusicManager().playBackgroundMusic(
            fullMusicPath,
            fadeTransition: true,
            fadeDuration: const Duration(milliseconds: 1200),
          );
          _currentState =
              _currentState.copyWith(currentMusicRegion: currentRegion);
        } else if (currentRegion != stateRegion) {
          _currentState =
              _currentState.copyWith(currentMusicRegion: currentRegion);
        }
      }
    }
  }

  void _buildLabelIndexMap() {
    _labelIndexMap = {};
    for (int i = 0; i < _script.children.length; i++) {
      final node = _script.children[i];
      if (node is LabelNode) {
        _labelIndexMap[node.name] = i;
        if (kEngineDebugMode) {
          //////print('[GameManager] 标签映射: ${node.name} -> $i');
        }
      }
    }
  }

  int? _findFollowingMenuNodeIndex(int currentNodeIndex) {
    var nextIndex = currentNodeIndex + 1;
    while (nextIndex < _script.children.length) {
      final nextNode = _script.children[nextIndex];
      if (nextNode is CommentNode || nextNode is LabelNode) {
        nextIndex++;
        continue;
      }
      return nextNode is MenuNode ? nextIndex : null;
    }
    return null;
  }

  _MenuJumpTarget? _findReachableMenuJumpTarget(int startIndex) {
    if (!_isScriptInitialized()) {
      return null;
    }

    var nextIndex = startIndex.clamp(0, _script.children.length).toInt();
    final visitedIndexes = <int>{};
    final promptDialogues = <_MenuPromptDialogue>[];

    while (nextIndex >= 0 && nextIndex < _script.children.length) {
      if (!visitedIndexes.add(nextIndex)) {
        return null;
      }

      final nextNode = _script.children[nextIndex];
      if (nextNode is MenuNode) {
        return _MenuJumpTarget(
          menuIndex: nextIndex,
          promptDialogues: promptDialogues,
        );
      }
      if (nextNode is ReturnNode) {
        return null;
      }
      if (nextNode is JumpNode) {
        final targetIndex = _labelIndexMap[nextNode.targetLabel];
        if (targetIndex == null) {
          return null;
        }
        nextIndex = targetIndex;
        continue;
      }
      if (nextNode is SayNode) {
        promptDialogues.add(
          _buildMenuPromptDialogueFromSayNode(nextNode, nextIndex),
        );
      } else if (nextNode is ConditionalSayNode) {
        final prompt =
            _buildMenuPromptDialogueFromConditionalSayNode(nextNode, nextIndex);
        if (prompt != null) {
          promptDialogues.add(prompt);
        }
      }

      nextIndex++;
    }

    return null;
  }

  _MenuPromptDialogue _buildMenuPromptDialogueFromSayNode(
    SayNode node,
    int scriptIndex,
  ) {
    final characterConfig = _characterConfigs[node.character];
    return _MenuPromptDialogue(
      speaker: characterConfig?.name,
      dialogue: _resolveScriptText(node.dialogue),
      dialogueTag: node.dialogueTag,
      scriptIndex: scriptIndex,
      sourceScriptFile: node.sourceFile ?? currentScriptFile,
      sourceLine: node.sourceLine,
    );
  }

  _MenuPromptDialogue? _buildMenuPromptDialogueFromConditionalSayNode(
    ConditionalSayNode node,
    int scriptIndex,
  ) {
    final currentValue = GlobalVariableManager()
        .getBoolVariableSync(node.conditionVariable, defaultValue: false);
    if (currentValue != node.conditionValue) {
      return null;
    }

    final characterConfig = _characterConfigs[node.character];
    return _MenuPromptDialogue(
      speaker: characterConfig?.name,
      dialogue: _resolveScriptText(node.dialogue),
      dialogueTag: node.dialogueTag,
      scriptIndex: scriptIndex,
      sourceScriptFile: node.sourceFile ?? currentScriptFile,
      sourceLine: node.sourceLine,
    );
  }

  void _addMenuPromptDialogueToHistoryIfNeeded(
    _MenuPromptDialogue promptDialogue,
  ) {
    if (_dialogueHistory.isNotEmpty) {
      final lastDialogue = _dialogueHistory.last;
      if (lastDialogue.scriptIndex == promptDialogue.scriptIndex) {
        return;
      }
    }

    _addToDialogueHistory(
      speaker: promptDialogue.speaker,
      dialogue: promptDialogue.dialogue,
      dialogueTag: promptDialogue.dialogueTag,
      timestamp: DateTime.now(),
      currentNodeIndex: promptDialogue.scriptIndex,
      sourceScriptFile: promptDialogue.sourceScriptFile,
      sourceLine: promptDialogue.sourceLine,
    );
  }

  void _addMenuJumpDialoguesToHistory(
    List<_MenuPromptDialogue> promptDialogues,
  ) {
    for (final promptDialogue in promptDialogues) {
      _currentState = _currentState.copyWith(
        dialogue: promptDialogue.dialogue,
        dialogueTag: promptDialogue.dialogueTag,
        speaker: promptDialogue.speaker,
        forceNullSpeaker: promptDialogue.speaker == null,
        currentNode: null,
        clearDialogueAndSpeaker: false,
        everShownCharacters: _everShownCharacters,
      );
      _addMenuPromptDialogueToHistoryIfNeeded(promptDialogue);
    }
  }

  Future<bool> jumpToNextChoice() async {
    if (!_isScriptInitialized() || _isProcessing) {
      return false;
    }
    if (_currentState.currentNode is MenuNode) {
      return true;
    }

    final jumpTarget = _findReachableMenuJumpTarget(_scriptIndex);
    if (jumpTarget == null) {
      return false;
    }
    final targetMenuIndex = jumpTarget.menuIndex;

    _currentTimer?.cancel();
    _currentTimer = null;
    _currentTimerCompletion = null;
    _isWaitingForTimer = false;
    _isProcessing = false;

    final menuNode = _script.children[targetMenuIndex] as MenuNode;
    final localizedMenuNode = _localizeMenuNode(menuNode);
    _addMenuJumpDialoguesToHistory(jumpTarget.promptDialogues);

    await _createRuntimeAutoSave(reason: '分支选择');
    await _checkAndCreateAutoSave(targetMenuIndex, reason: '分支选择');

    final previousDialogueEntry = _dialogueHistory.length >= 2
        ? _dialogueHistory[_dialogueHistory.length - 2]
        : null;
    _scriptIndex = targetMenuIndex;
    if (previousDialogueEntry != null) {
      _currentState = _currentState.copyWith(
        dialogue: previousDialogueEntry.dialogue,
        dialogueTag: previousDialogueEntry.dialogueTag,
        speaker: previousDialogueEntry.speaker,
        forceNullSpeaker: previousDialogueEntry.speaker == null,
        currentNode: localizedMenuNode,
        clearDialogueAndSpeaker: false,
        clearScriptOverlay: true,
        isFastForwarding: _isFastForwardMode,
        isPaused: false,
        everShownCharacters: _everShownCharacters,
      );
    } else {
      _currentState = _currentState.copyWith(
        currentNode: localizedMenuNode,
        clearDialogueAndSpeaker: true,
        clearScriptOverlay: true,
        isFastForwarding: _isFastForwardMode,
        isPaused: false,
        everShownCharacters: _everShownCharacters,
      );
    }
    _gameStateController.add(_currentState);

    return true;
  }

  Future<void> jumpToLabel(String label) async {
    // 在合并的脚本中查找标签
    if (_labelIndexMap.containsKey(label)) {
      _scriptIndex = _labelIndexMap[label]!;
      _currentState = _currentState.copyWith(
          forceNullCurrentNode: true,
          everShownCharacters: _everShownCharacters);
      _gameStateController.add(_currentState);
      if (kEngineDebugMode) {
        //////print('[GameManager] 跳转到标签: $label, 索引: $_scriptIndex');
      }

      // 检查跳转后位置的音乐区间（强制检查）
      await _checkMusicRegionAtCurrentIndex(forceCheck: true);
      await _executeScript();
    } else {
      if (kEngineDebugMode) {
        //////print('[GameManager] 错误: 标签 $label 未找到');
      }
    }
  }

  void next() async {
    if (_isProcessing || _isWaitingForTimer) {
      return;
    }

    // 检查是否需要清除anime覆盖层（在用户交互时）
    if (_currentState.animeOverlay != null && !_currentState.animeKeep) {
      ////print('[GameManager] 用户点击继续，清除anime覆盖层: ${_currentState.animeOverlay}');
      _currentState = _currentState.copyWith(
        clearAnimeOverlay: true,
        everShownCharacters: _everShownCharacters,
      );
      _gameStateController.add(_currentState);
    }

    // 在用户点击继续时检查音乐区间
    await _checkMusicRegionAtCurrentIndex();
    _executeScript();
  }

  void exitNvlMode() {
    //print('📚 退出 NVL/NVLN 模式');
    _activeNvlContext = _NvlContextMode.none;
    _showNvlOverlayOnNextDialogue = false;
    _currentState = _currentState.copyWith(
      isNvlMode: false,
      isNvlnMode: false, // 同时确保nvln模式也关闭
      isNvlOverlayVisible: false,
      nvlDialogues: [],
      clearDialogueAndSpeaker: true,
      everShownCharacters: _everShownCharacters,
    );
    _gameStateController.add(_currentState);
    _executeScript();
  }

  /// 视频播放完成后继续执行脚本
  void executeScriptAfterMovie() {
    //print('[GameManager] 视频播放完成，开始黑屏转场');

    // 如果有context，使用转场效果；否则直接切换
    if (_context != null) {
      TransitionOverlayManager.instance.transition(
        context: _context!,
        duration: const Duration(milliseconds: 600), // 转场时长
        onMidTransition: () {
          // 在黑屏最深时清理movie状态并继续执行脚本
          //print('[GameManager] 转场中点：清理movie状态并继续执行脚本');
          _currentState = _currentState.copyWith(
            clearMovieFile: true, // 清理视频文件
          );
          _gameStateController.add(_currentState);
          _executeScript();
        },
      );
    } else {
      // 兼容性处理：如果没有context，直接切换
      //print('[GameManager] 无context，直接清理movie状态并继续执行脚本');
      _currentState = _currentState.copyWith(
        clearMovieFile: true, // 清理视频文件
      );
      _gameStateController.add(_currentState);
      _executeScript();
    }
  }

  Future<void> _executeScript() async {
    if (_isProcessing || _isWaitingForTimer) {
      return;
    }
    _isProcessing = true;

    //print('🎮 开始处理脚本，当前索引: $_scriptIndex');

    while (_scriptIndex < _script.children.length) {
      final node = _script.children[_scriptIndex];
      final currentNodeIndex = _scriptIndex; // 保存当前节点索引

      // 触发CG预分析（后台异步执行，不阻塞主流程）
      _cgPreAnalyzer.preAnalyzeScript(
        scriptNodes: _script.children,
        currentIndex: _scriptIndex,
        lookAheadLines: _isFastForwardMode ? 50 : 10,
        isSkipping: _isFastForwardMode,
      );

      // 智能预测器：每10个节点更新一次预热范围
      if (_scriptIndex % 10 == 0) {
        // 获取当前标签
        String? currentLabel;
        for (int i = _scriptIndex; i >= 0; i--) {
          final checkNode = _script.children[i];
          if (checkNode is LabelNode) {
            currentLabel = checkNode.name;
            break;
          }
        }

        // 更新智能预热
        _smartPredictor.smartPreWarm(
          scriptNodes: _script.children,
          currentIndex: _scriptIndex,
          currentLabel: currentLabel,
        );
      }

      // 跳过注释节点（文件边界标记）
      if (node is CommentNode) {
        if (kEngineDebugMode) {
          //////print('[GameManager] 跳过注释: ${node.comment}');
        }
        _scriptIndex++;
        continue;
      }

      // 跳过标签节点
      if (node is LabelNode) {
        // 通知章节自动存档管理器：经过了一个label
        _chapterAutoSaveManager.onLabelPassed(node.name);

        _scriptIndex++;
        continue;
      }

      if (node is BackgroundNode) {
        // 每次scene切换前都创建自动存档
        await _createRuntimeAutoSave(reason: 'scene');

        // 检查当前scene是否是章节末尾前最后一个没有对话的scene
        await _checkChapterEndAutoSave(_scriptIndex);

        // 检查是否要清空CG状态
        // 如果新背景不是CG且当前有CG显示，则清空CG
        final isNewBackgroundCG = node.background.toLowerCase().contains('cg');
        final shouldClearCG =
            !isNewBackgroundCG && _currentState.cgCharacters.isNotEmpty;

        if (shouldClearCG) {
          ////print('[GameManager] 切换到非CG背景，清空CG状态');
        }

        // 检查下一个节点是否是FxNode，如果是则一起处理
        SceneFilter? sceneFilter;
        int nextIndex = _scriptIndex + 1;
        if (nextIndex < _script.children.length &&
            _script.children[nextIndex] is FxNode) {
          final fxNode = _script.children[nextIndex] as FxNode;
          sceneFilter = SceneFilter.fromString(fxNode.filterString);
          if (_fxDiagLogs) {
            debugPrint(
              '[FX_DIAG] BackgroundNode(next FxNode) index=$nextIndex '
              'source=${fxNode.sourceFile ?? "unknown"}:${fxNode.sourceLine ?? -1} '
              'raw="${fxNode.filterString}" parsed=${sceneFilter?.type}/${sceneFilter?.intensity}/${sceneFilter?.animation}/${sceneFilter?.duration}',
            );
          }
        }

        // 检查是否是游戏开始时的初始背景设置
        final isInitialBackground = _currentState.background == null &&
            _currentState.cgCharacters.isEmpty;
        final isSameBackground = _currentState.background == node.background;
        // 检查是否从CG切换到场景，如果是则强制使用转场效果
        final isFromCGToScene = _currentState.cgCharacters.isNotEmpty &&
            !node.background.toLowerCase().contains('cg');

        // 快进模式下跳过转场效果，或其他需要跳过转场的情况
        // 但从CG切换到场景时必须使用转场效果
        if ((_isFastForwardMode ||
                _context == null ||
                isInitialBackground ||
                isSameBackground) &&
            !isFromCGToScene) {
          ////print('[GameManager] 跳过转场：${_isFastForwardMode ? "快进模式" : (isInitialBackground ? "初始背景" : (isSameBackground ? "相同背景" : "无context"))}');
          // 直接切换背景
          _currentState = _currentState.copyWith(
              background: node.background,
              movieFile: null, // 新增：scene命令清理视频状态
              clearMovieFile: true, // 修复：使用clearMovieFile标志确保视频状态被清理
              sceneFilter: sceneFilter,
              clearSceneFilter: sceneFilter == null,
              sceneLayers: node.layers,
              clearSceneLayers: node.layers == null,
              clearDialogueAndSpeaker: !isSameBackground,
              clearCharacters: !isSameBackground, // 新增：非相同背景时清除所有角色立绘
              sceneAnimation: node.animation,
              sceneAnimationRepeat: node.repeatCount,
              sceneAnimationProperties:
                  (node.animation != null && !isSameBackground)
                      ? <String, double>{}
                      : null,
              clearSceneAnimation: node.animation == null,
              clearCgCharacters: shouldClearCG,
              everShownCharacters: _everShownCharacters);
          //print('[GameManager] Scene命令清理movie状态: 新状态 movieFile=${_currentState.movieFile}, background=${_currentState.background}');
          _gameStateController.add(_currentState);

          // 快进模式下跳过场景动画
          if (!_isFastForwardMode &&
              node.animation != null &&
              _tickerProvider != null) {
            _startSceneAnimation(node.animation!, node.repeatCount);
          }

          // 快进模式下跳过计时器
          if (!_isFastForwardMode && node.timer != null && node.timer! > 0) {
            _startSceneTimer(node.timer!);
            return;
          }
        } else {
          // 需要使用转场效果
          // 立即递增索引，如果有fx节点也跳过
          _scriptIndex += sceneFilter != null ? 2 : 1;

          // 如果没有指定timer，默认使用0.01秒，确保转场后正确执行后续脚本
          final timerDuration = node.timer ?? 0.01;

          // 提前设置计时器等待标志
          _isWaitingForTimer = true;
          _isProcessing = false; // 释放当前处理锁，但保持timer锁

          // 检查是否是CG到CG的转场，如果是且没有指定转场类型，则使用dissolve
          // 同时检查从CG切换到普通场景的情况
          String? finalTransitionType = node.transitionType;
          final currentBg = _currentState.background;
          final newBg = node.background;
          final isCurrentCG =
              currentBg != null && currentBg.toLowerCase().contains('cg');
          final isNewCG = newBg.toLowerCase().contains('cg');
          final hasCurrentCGCharacters = _currentState.cgCharacters.isNotEmpty;

          if ((isCurrentCG && isNewCG) || (hasCurrentCGCharacters && isNewCG)) {
            if (finalTransitionType == null) {
              finalTransitionType = 'diss'; // CG到CG默认使用dissolve转场
              ////print('[GameManager] CG到CG转场，使用默认dissolve效果');
            }
          } else if (hasCurrentCGCharacters &&
              !isNewCG &&
              finalTransitionType == null) {
            // 从CG切换到普通场景，默认使用fade转场
            finalTransitionType = 'fade';
            ////print('[GameManager] 从CG切换到场景，使用默认fade效果');
          }

          _transitionToNewBackground(
                  node.background,
                  sceneFilter,
                  node.layers,
                  finalTransitionType,
                  node.animation,
                  node.repeatCount,
                  shouldClearCG)
              .then((_) {
            // 转场完成后启动计时器
            _startSceneTimer(timerDuration);
          });
          return; // 转场过程中暂停脚本执行，将在转场完成后自动恢复
        }

        // 如果有fx节点也跳过
        _scriptIndex += sceneFilter != null ? 2 : 1;
        continue;
      }

      if (node is MovieNode) {
        // 每次scene切换前都创建自动存档
        await _createRuntimeAutoSave(reason: 'movie');

        // Movie处理逻辑，类似BackgroundNode但用于视频播放
        // 检测是否包含chapter，如果是则停止快进
        if (_isFastForwardMode && _containsChapter(node.movieFile)) {
          //print('[GameManager] 检测到chapter视频，停止快进: ${node.movieFile}');
          setFastForwardMode(false);
        }

        // 检查当前movie是否是章节末尾前最后一个没有对话的scene
        await _checkChapterEndAutoSave(_scriptIndex);

        // 清空CG状态和角色立绘，因为视频会全屏显示
        final shouldClearAll = true;

        // 检查下一个节点是否是FxNode，如果是则一起处理
        SceneFilter? sceneFilter;
        int nextIndex = _scriptIndex + 1;
        if (nextIndex < _script.children.length &&
            _script.children[nextIndex] is FxNode) {
          final fxNode = _script.children[nextIndex] as FxNode;
          sceneFilter = SceneFilter.fromString(fxNode.filterString);
        }

        // 检查是否是游戏开始时的初始视频
        final isInitialMovie = _currentState.movieFile == null;
        final isSameMovie = _currentState.movieFile == node.movieFile;

        // 快进模式下跳过转场效果，或其他需要跳过转场的情况
        if (_isFastForwardMode ||
            _context == null ||
            isInitialMovie ||
            isSameMovie) {
          // 直接切换到视频
          _currentState = _currentState.copyWith(
              movieFile: node.movieFile,
              movieRepeatCount: node.repeatCount, // 新增：传递视频重复播放次数
              background: null, // 清空背景，视频优先显示
              sceneFilter: sceneFilter,
              clearSceneFilter: sceneFilter == null,
              sceneLayers: node.layers,
              clearSceneLayers: node.layers == null,
              clearDialogueAndSpeaker: true,
              clearCharacters: true, // 清除所有角色立绘
              clearCgCharacters: true, // 清除CG
              sceneAnimation: node.animation,
              sceneAnimationRepeat: node.repeatCount,
              sceneAnimationProperties: (node.animation != null && !isSameMovie)
                  ? <String, double>{}
                  : null,
              clearSceneAnimation: node.animation == null,
              everShownCharacters: _everShownCharacters);
          _gameStateController.add(_currentState);

          // 快进模式下跳过计时器，但正常模式下需要等待视频播放完成
          if (!_isFastForwardMode) {
            // 设置处理锁，等待视频播放完成后再继续
            _isProcessing = false;
            // 脚本索引推进，避免重复执行当前节点
            _scriptIndex += sceneFilter != null ? 2 : 1;
            return; // 等待视频播放完成的回调
          } else {
            // 快进模式下跳过视频等待
            if (node.timer != null && node.timer! > 0) {
              _startSceneTimer(node.timer!);
              return;
            }
          }
        } else {
          // 需要使用转场效果
          _scriptIndex += sceneFilter != null ? 2 : 1;

          final timerDuration = node.timer ?? 0.01;

          _isWaitingForTimer = true;
          _isProcessing = false;

          _transitionToNewMovie(node.movieFile, sceneFilter, node.layers,
                  node.transitionType, node.animation, node.repeatCount)
              .then((_) {
            _startSceneTimer(timerDuration);
          });
          return;
        }

        // 如果有fx节点也跳过
        _scriptIndex += sceneFilter != null ? 2 : 1;
        continue;
      }

      if (node is AnimeNode) {
        ////print('[GameManager] 处理AnimeNode: ${node.animeName}, loop: ${node.loop}, keep: ${node.keep}');

        // 快进模式下跳过anime显示
        if (!_isFastForwardMode) {
          // 正常模式下显示anime
          _currentState = _currentState.copyWith(
            animeOverlay: node.animeName,
            animeLoop: node.loop,
            animeKeep: node.keep,
            clearDialogueAndSpeaker: true,
            everShownCharacters: _everShownCharacters,
          );
          _gameStateController.add(_currentState);
        }

        // 快进模式下跳过计时器
        if (!_isFastForwardMode && node.timer != null && node.timer! > 0) {
          _isWaitingForTimer = true;
          _startSceneTimer(node.timer!);
          return; // 等待计时器结束
        }

        _scriptIndex++;
        continue;
      }

      if (node is ShowNode) {
        // 检查是否有CG正在显示，如果有则跳过立绘显示
        if (_currentState.cgCharacters.isNotEmpty) {
          ////print('[GameManager] CG正在显示，跳过ShowNode: ${node.character}');
          _scriptIndex++;
          continue;
        }

        ////print('[GameManager] 处理ShowNode: character=${node.character}, pose=${node.pose}, expression=${node.expression}, position=${node.position}, animation=${node.animation}');
        // 优先使用角色配置，如果没有配置则直接使用资源ID
        final characterConfig = _characterConfigs[node.character];
        String resourceId;
        String positionId;
        String finalCharacterKey; // 最终使用的角色key

        if (characterConfig != null) {
          ////print('[GameManager] 使用角色配置: ${characterConfig.id}');
          resourceId = characterConfig.resourceId;
          positionId = characterConfig.defaultPoseId ?? 'pose';
          finalCharacterKey = _resolveCharacterRenderKey(
            node.character,
            characterConfig: characterConfig,
          );
        } else {
          ////print('[GameManager] 直接使用资源ID: ${node.character}');
          resourceId = node.character;
          positionId = node.position ?? 'pose';
          finalCharacterKey = node.character; // 使用原始名称作为key
        }

        // 跟踪角色是否曾经显示过
        _everShownCharacters.add(finalCharacterKey);

        final newCharacters = Map.of(_currentState.characters);

        final currentCharacterState =
            _currentState.characters[finalCharacterKey] ??
                CharacterState(
                  resourceId: resourceId,
                  positionId: positionId,
                );

        // 检测角色位置变化并触发动画（如果需要）
        // 先将新角色添加到临时角色列表，然后检测位置变化
        final tempCharacters = Map.of(newCharacters);

        // 清理现有角色的动画属性，确保位置计算基于基础位置
        for (final entry in tempCharacters.entries) {
          tempCharacters[entry.key] = entry.value.copyWith(
            clearAnimationProperties: true, // 清理动画属性
          );
        }

        // 先计算目标pose和expression，确保使用默认值
        final targetPose = node.pose ?? currentCharacterState.pose ?? 'pose1';
        final targetExpression =
            node.expression ?? currentCharacterState.expression ?? 'happy';

        tempCharacters[finalCharacterKey] = currentCharacterState.copyWith(
          resourceId: resourceId,
          pose: targetPose,
          expression: targetExpression,
          clearAnimationProperties: false,
        );

        // 快进模式下跳过位置动画
        if (!_isFastForwardMode) {
          await _checkAndAnimateCharacterPositions(tempCharacters);
        }

        await CharacterCompositeCache.instance
            .preload(resourceId, targetPose, targetExpression);

        newCharacters[finalCharacterKey] = currentCharacterState.copyWith(
          resourceId: resourceId,
          pose: targetPose,
          expression: targetExpression,
          clearAnimationProperties: false,
        );

        _currentState = _currentState.copyWith(
            characters: newCharacters,
            clearDialogueAndSpeaker: true,
            everShownCharacters: _everShownCharacters);
        _gameStateController.add(_currentState);

        // 如果有动画，启动动画播放（非阻塞）
        if (!_isFastForwardMode && node.animation != null) {
          _playCharacterAnimation(finalCharacterKey, node.animation!,
              repeatCount: node.repeatCount);
        }

        _scriptIndex++;
        continue;
      }

      if (node is CgNode) {
        if (kEngineDebugMode) {
          //print('[GameManager] 处理CgNode: character=${node.character}, pose=${node.pose}, expression=${node.expression}, position=${node.position}, animation=${node.animation}');
        }

        // CG显示命令，类似ShowNode但渲染方式像scene一样铺满
        final characterConfig = _characterConfigs[node.character];
        String resourceId;
        String positionId;
        const String finalCharacterKey =
            _globalCgCharacterKey; // 统一使用全局key以复用渲染组件

        if (characterConfig != null) {
          if (kEngineDebugMode) {
            //print('[GameManager] 使用角色配置: ${characterConfig.id}');
          }
          resourceId = characterConfig.resourceId;
          positionId = characterConfig.defaultPoseId ?? 'pose';
        } else {
          if (kEngineDebugMode) {
            //print('[GameManager] 直接使用资源ID: ${node.character}');
          }
          resourceId = node.character;
          positionId = node.position ?? 'pose';
        }

        // 确保pose和expression的值被正确设置
        final newPose = node.pose ?? 'pose1';
        final newExpression = node.expression ?? 'happy';

        if (kEngineDebugMode) {
          //print('[GameManager] CG参数: resourceId=$resourceId, pose=$newPose, expression=$newExpression, finalKey=$finalCharacterKey');
        }
        if (!kIsWeb) {
          final gpuEntry = await GpuImageCompositor().getCompositeEntry(
            resourceId: resourceId,
            pose: newPose,
            expression: newExpression,
          );
          if (gpuEntry != null) {
            await CompositeCgRenderer.cachePrecomposedResult(
              resourceId: resourceId,
              pose: newPose,
              expression: newExpression,
              gpuEntry: gpuEntry,
            );
          } else {
            final compositePath =
                await CgImageCompositor().getCompositeImagePath(
              resourceId: resourceId,
              pose: newPose,
              expression: newExpression,
            );
            if (compositePath != null) {
              await CompositeCgRenderer.cachePrecomposedResult(
                resourceId: resourceId,
                pose: newPose,
                expression: newExpression,
                compositePath: compositePath,
              );
            }
          }
        }

        // CG按scene切换语义处理：清理旧场景状态，避免露出后景
        _currentState = _currentState.copyWith(
          everShownCharacters: _everShownCharacters,
          clearBackground: true,
          clearMovieFile: true,
          clearCharacters: true,
          clearSceneFilter: true,
          clearSceneLayers: true,
          clearSceneAnimation: true,
        );

        // 跟踪角色是否曾经显示过
        _everShownCharacters.add(finalCharacterKey);
        _everShownCharacters.add(resourceId);

        final newCgCharacters = Map.of(_currentState.cgCharacters);

        final currentCharacterState =
            _currentState.cgCharacters[finalCharacterKey];
        final bool isNewSlot = currentCharacterState == null;
        final bool resourceChanged = currentCharacterState != null &&
            currentCharacterState.resourceId != resourceId;
        if (isNewSlot || resourceChanged) {
          CompositeCgRenderer.resetFadeToken(finalCharacterKey);
        }

        CharacterState updatedState;

        if (resourceChanged) {
          // 切换到了全新的CG资源，创建全新的状态以触发完整渐变
          updatedState = CharacterState(
            resourceId: resourceId,
            pose: newPose,
            expression: newExpression,
            positionId: positionId,
          );
        } else if (currentCharacterState != null) {
          updatedState = currentCharacterState.copyWith(
            pose: newPose,
            expression: newExpression,
            clearAnimationProperties: false,
          );
        } else {
          updatedState = CharacterState(
            resourceId: resourceId,
            pose: newPose,
            expression: newExpression,
            positionId: positionId,
          );
        }

        if (kEngineDebugMode) {
          //print('[GameManager] CG更新前: cgCharacters数量=${_currentState.cgCharacters.length}');
        }

        newCgCharacters[finalCharacterKey] = updatedState;

        _currentState = _currentState.copyWith(
            cgCharacters: newCgCharacters,
            clearDialogueAndSpeaker: true,
            everShownCharacters: _everShownCharacters);
        _gameStateController.add(_currentState);

        if (kEngineDebugMode) {
          //print('[GameManager] CG状态已更新，当前CG角色数量: ${_currentState.cgCharacters.length}');
          //print('[GameManager] CG角色列表: ${_currentState.cgCharacters.keys.toList()}');
        }

        // 如果有动画，启动动画播放（非阻塞）
        if (!_isFastForwardMode && node.animation != null) {
          _playCharacterAnimation(finalCharacterKey, node.animation!,
              repeatCount: node.repeatCount);
        }

        _scriptIndex++;
        continue;
      }

      if (node is HideNode) {
        final newCharacters = Map.of(_currentState.characters);
        final characterConfig = _characterConfigs[node.character];
        final hideKey = _resolveCharacterRenderKey(
          node.character,
          characterConfig: characterConfig,
        );
        final character = newCharacters[hideKey];

        if (character != null) {
          // 不立即移除角色，而是标记为正在淡出
          newCharacters[hideKey] = character.copyWith(isFadingOut: true);

          _currentState = _currentState.copyWith(
              characters: newCharacters,
              clearDialogueAndSpeaker: false,
              everShownCharacters: _everShownCharacters);
          _gameStateController.add(_currentState);
        }

        _scriptIndex++;
        continue;
      }

      if (node is ConditionalSayNode) {
        final resolvedDialogue = _resolveScriptText(node.dialogue);
        final tailSpeakerAlias = node.tailCharacter?.trim();
        // 检查条件是否满足
        final currentValue = GlobalVariableManager()
            .getBoolVariableSync(node.conditionVariable, defaultValue: false);

        if (currentValue != node.conditionValue) {
          // 条件不满足，跳过这个节点
          _scriptIndex++;
          continue;
        }

        // 条件满足，按照正常SayNode处理
        final characterConfig = _characterConfigs[node.character];
        CharacterState? currentCharacterState;

        if (node.character != null) {
          final targetResourceId =
              characterConfig?.resourceId ?? node.character!;
          // 确定最终的角色key
          final finalCharacterKey = _resolveCharacterRenderKey(
            node.character,
            characterConfig: characterConfig,
          );

          currentCharacterState = _currentState.characters[finalCharacterKey];

          if (currentCharacterState != null) {
            // 角色已存在，更新表情、姿势和位置
            final newCharacters = Map.of(_currentState.characters);

            // 如果角色已存在且有正在播放的动画，继承动画属性
            final existingAnimController =
                _activeCharacterAnimations[finalCharacterKey];
            Map<String, double>? inheritedAnimationProperties;

            if (existingAnimController != null &&
                currentCharacterState.animationProperties != null) {
              // 继承当前的动画属性，这样角色的差分改变但动画位置保持
              inheritedAnimationProperties =
                  Map.from(currentCharacterState.animationProperties!);
              //print('[GameManager] ConditionalSay: 角色 $finalCharacterKey 差分切换时继承动画属性: $inheritedAnimationProperties');
            }

            final updatedCharacter = currentCharacterState.copyWith(
              resourceId: targetResourceId,
              pose: node.pose,
              expression: node.expression,
              positionId: node.position ??
                  currentCharacterState.positionId, // 如果有新position则更新，否则保持原值
              animationProperties: inheritedAnimationProperties, // 继承动画属性
              clearAnimationProperties: false,
            );
            newCharacters[finalCharacterKey] = updatedCharacter;

            // 如果位置发生变化，播放pose属性变化动画
            if (node.position != null &&
                node.position != currentCharacterState.positionId) {
              // 快进模式下跳过位置变化动画
              if (!_isFastForwardMode) {
                await _checkAndAnimatePoseAttributeChanges(
                  characterId: finalCharacterKey,
                  oldPositionId: currentCharacterState.positionId,
                  newPositionId: node.position,
                );
              }
            }

            _currentState = _currentState.copyWith(
                characters: newCharacters,
                everShownCharacters: _everShownCharacters);
            _gameStateController.add(_currentState);

            // 如果有动画，启动动画播放（非阻塞）
            if (!_isFastForwardMode && node.animation != null) {
              _playCharacterAnimation(finalCharacterKey, node.animation!,
                  repeatCount: node.repeatCount);
            }
          } else if (characterConfig != null) {
            // 角色不存在，创建新角色
            currentCharacterState = CharacterState(
              resourceId: characterConfig.resourceId,
              positionId: node.position ??
                  characterConfig.defaultPoseId, // 优先使用指定的position，否则使用默认值
            );

            final newCharacters = Map.of(_currentState.characters);

            // 清理现有角色的动画属性，确保位置计算基于基础位置
            for (final entry in newCharacters.entries) {
              newCharacters[entry.key] = entry.value.copyWith(
                clearAnimationProperties: true, // 清理动画属性
              );
            }

            newCharacters[finalCharacterKey] = currentCharacterState.copyWith(
              pose: node.pose,
              expression: node.expression,
              clearAnimationProperties: false,
            );

            // 检测角色位置变化并触发动画（如果需要）
            if (!_isFastForwardMode) {
              await _checkAndAnimateCharacterPositions(newCharacters);
            }

            _currentState = _currentState.copyWith(
                characters: newCharacters,
                everShownCharacters: _everShownCharacters);
            _gameStateController.add(_currentState);

            // 如果有动画，启动动画播放（非阻塞）
            if (!_isFastForwardMode && node.animation != null) {
              _playCharacterAnimation(finalCharacterKey, node.animation!,
                  repeatCount: node.repeatCount);
            }
          }
        } else if (tailSpeakerAlias != null && tailSpeakerAlias.isNotEmpty) {
          _applyNarrationTailCharacterDiff(
            targetAlias: tailSpeakerAlias,
            pose: node.tailPose,
            expression: node.tailExpression,
            animation: node.tailAnimation,
            repeatCount: node.tailRepeatCount,
          );
        }

        await _applyInlineApiTokenForSay(
          inlineApiToken: node.inlineApiToken,
          characterAlias: node.character,
          tailCharacterAlias: tailSpeakerAlias,
        );

        // 在 NVL 或 NVLN 模式下的特殊处理
        if (_activeNvlContext != _NvlContextMode.none) {
          final shouldRevealOverlay = _showNvlOverlayOnNextDialogue;
          if (shouldRevealOverlay) {
            _showNvlOverlayOnNextDialogue = false;
          }
          final newNvlDialogue = NvlDialogue(
            speaker: characterConfig?.name,
            speakerAlias: node.character ?? tailSpeakerAlias, // 新增：传递角色简写
            dialogue: resolvedDialogue,
            dialogueTag: node.dialogueTag,
            timestamp: DateTime.now(),
          );

          final updatedNvlDialogues =
              List<NvlDialogue>.from(_currentState.nvlDialogues);
          updatedNvlDialogues.add(newNvlDialogue);

          _currentState = _currentState.copyWith(
            nvlDialogues: updatedNvlDialogues,
            clearDialogueAndSpeaker: true,
            everShownCharacters: _everShownCharacters,
            isNvlOverlayVisible: shouldRevealOverlay ? true : null,
          );

          // 也添加到对话历史
          _addToDialogueHistory(
            speaker: characterConfig?.name,
            dialogue: resolvedDialogue,
            dialogueTag: node.dialogueTag,
            timestamp: DateTime.now(),
            currentNodeIndex: currentNodeIndex,
            sourceScriptFile: node.sourceFile ?? currentScriptFile,
            sourceLine: node.sourceLine,
          );

          _gameStateController.add(_currentState);
          // 检查是否需要创建章节开头的自动存档（NVL模式）
          try {
            await _chapterAutoSaveManager.onDialogueDisplayed(
              scriptIndex: currentNodeIndex, // 使用当前节点索引
              currentScriptFile: currentScriptFile,
              currentLabel: _findNearestLabel(currentNodeIndex),
              saveStateSnapshot: saveStateSnapshot,
              flowchartManager: _flowchartManager,
            );
          } catch (e, stackTrace) {
            if (kEngineDebugMode) {
              print('[GameManager] ❌ 章节自动存档检查失败: $e');
              print('堆栈: $stackTrace');
            }
          }

          // NVL/NVLN 模式下每句话都要停下来等待点击
          _scriptIndex++;
          _isProcessing = false;
          return;
        } else {
          // 普通对话模式
          final followingMenuNodeIndex =
              _findFollowingMenuNodeIndex(currentNodeIndex);
          if (followingMenuNodeIndex == null) {
            _currentState = _currentState.copyWith(
              dialogue: resolvedDialogue,
              dialogueTag: node.dialogueTag,
              speaker: characterConfig?.name,
              speakerAlias: node.character ?? tailSpeakerAlias, // 传入角色简写
              currentNode: null,
              clearDialogueAndSpeaker: false,
              forceNullSpeaker: node.character == null,
              everShownCharacters: _everShownCharacters,
            );
          }

          _addToDialogueHistory(
            speaker: characterConfig?.name,
            dialogue: resolvedDialogue,
            dialogueTag: node.dialogueTag,
            timestamp: DateTime.now(),
            currentNodeIndex: currentNodeIndex,
            sourceScriptFile: node.sourceFile ?? currentScriptFile,
            sourceLine: node.sourceLine,
          );

          if (followingMenuNodeIndex != null) {
            final menuNode =
                _script.children[followingMenuNodeIndex] as MenuNode;
            final localizedMenuNode = _localizeMenuNode(menuNode);
            final previousDialogueEntry = _dialogueHistory.length >= 2
                ? _dialogueHistory[_dialogueHistory.length - 2]
                : null;

            // 分支选择前创建运行时自动存档
            await _createRuntimeAutoSave(reason: '分支选择');
            // 分支选择前创建自动存档
            await _checkAndCreateAutoSave(followingMenuNodeIndex,
                reason: '分支选择');

            _currentState = _currentState.copyWith(
              dialogue: previousDialogueEntry?.dialogue,
              dialogueTag: previousDialogueEntry?.dialogueTag,
              speaker: previousDialogueEntry?.speaker,
              forceNullSpeaker: previousDialogueEntry?.speaker == null,
              currentNode: localizedMenuNode,
              clearDialogueAndSpeaker: false,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
            _scriptIndex = followingMenuNodeIndex;
          } else {
            _gameStateController.add(_currentState);
            _scriptIndex++;
          }
          _isProcessing = false;
          return;
        }
      }

      if (node is SayNode) {
        ////print('[GameManager] 处理SayNode: character=${node.character}, pose=${node.pose}, expression=${node.expression}, animation=${node.animation}');
        final resolvedDialogue = _resolveScriptText(node.dialogue);
        final characterConfig = _characterConfigs[node.character];
        final tailSpeakerAlias = node.tailCharacter?.trim();
        ////print('[GameManager] 角色配置: $characterConfig');
        CharacterState? currentCharacterState;
        final followingMenuNodeIndex =
            _findFollowingMenuNodeIndex(currentNodeIndex);
        final shouldDirectToFollowingMenu = followingMenuNodeIndex != null &&
            _activeNvlContext == _NvlContextMode.none;

        if (node.character != null) {
          final targetResourceId =
              characterConfig?.resourceId ?? node.character!;
          // 检查当前背景是否为CG，如果是CG则不更新角色立绘
          if (_isCurrentBackgroundCG()) {
            ////print('[GameManager] 当前背景为CG，跳过角色立绘更新');
            // 直接更新对话内容，不处理角色状态
            if (!shouldDirectToFollowingMenu) {
              _currentState = _currentState.copyWith(
                speaker: characterConfig?.name ?? node.character,
                speakerAlias: node.character, // 传入角色简写
                dialogue: resolvedDialogue,
                dialogueTag: node.dialogueTag,
                everShownCharacters: _everShownCharacters,
              );
            }
          } else {
            // 正常处理角色立绘逻辑
            // 确定最终的角色key
            final finalCharacterKey = _resolveCharacterRenderKey(
              node.character,
              characterConfig: characterConfig,
            );

            currentCharacterState = _currentState.characters[finalCharacterKey];
            ////print('[GameManager] 查找角色 $finalCharacterKey: ${currentCharacterState != null ? "找到" : "未找到"}');

            if (currentCharacterState != null) {
              // 角色已存在，更新表情、姿势和位置
              ////print('[GameManager] 更新已存在角色 $finalCharacterKey: pose=${node.pose}, expression=${node.expression}, position=${node.position}');
              final newCharacters = Map.of(_currentState.characters);

              // 处理时序差分切换
              String? finalExpression = node.expression;
              if (node.hasTimedExpression) {
                if (_isFastForwardMode) {
                  // 快进模式下直接使用目标差分
                  finalExpression = node.endExpression;
                  //print('[GameManager] 快进模式: 直接使用目标差分 ${node.endExpression}');
                } else {
                  // 先设置起始差分
                  finalExpression = node.startExpression;
                  //print('[GameManager] 时序差分切换: 起始差分 ${node.startExpression}, ${node.switchDelay}秒后切换到 ${node.endExpression}');

                  // 启动定时器进行差分切换
                  _scheduleExpressionSwitch(
                    characterKey: finalCharacterKey,
                    targetExpression: node.endExpression!,
                    delay: node.switchDelay!,
                  );
                }
              }

              // 如果角色已存在且有正在播放的动画，继承动画属性
              final existingAnimController =
                  _activeCharacterAnimations[finalCharacterKey];
              Map<String, double>? inheritedAnimationProperties;

              if (existingAnimController != null &&
                  currentCharacterState.animationProperties != null) {
                // 继承当前的动画属性，这样角色的差分改变但动画位置保持
                inheritedAnimationProperties =
                    Map.from(currentCharacterState.animationProperties!);
                //print('[GameManager] 角色 $finalCharacterKey 差分切换时继承动画属性: $inheritedAnimationProperties');
              }

              final updatedCharacter = currentCharacterState.copyWith(
                resourceId: targetResourceId,
                pose: node.pose,
                expression: finalExpression,
                positionId: node.position ??
                    currentCharacterState.positionId, // 如果有新position则更新，否则保持原值
                animationProperties: inheritedAnimationProperties, // 继承动画属性
                clearAnimationProperties: false,
              );
              newCharacters[finalCharacterKey] = updatedCharacter;

              // 如果位置发生变化，播放pose属性变化动画
              if (node.position != null &&
                  node.position != currentCharacterState.positionId) {
                await _checkAndAnimatePoseAttributeChanges(
                  characterId: finalCharacterKey,
                  oldPositionId: currentCharacterState.positionId,
                  newPositionId: node.position,
                );
              }

              ////print('[GameManager] 角色更新后状态: pose=${updatedCharacter.pose}, expression=${updatedCharacter.expression}, position=${updatedCharacter.positionId}');
              _currentState = _currentState.copyWith(
                  characters: newCharacters,
                  everShownCharacters: _everShownCharacters);
              _gameStateController.add(_currentState);
              ////print('[GameManager] 发送状态更新，当前角色列表: ${newCharacters.keys}');

              // 如果有动画，启动动画播放（非阻塞）
              if (!_isFastForwardMode && node.animation != null) {
                _playCharacterAnimation(finalCharacterKey, node.animation!,
                    repeatCount: node.repeatCount);
              }
            } else if (characterConfig != null) {
              // 角色不存在，创建新角色
              ////print('[GameManager] 创建新角色 $finalCharacterKey');
              currentCharacterState = CharacterState(
                resourceId: characterConfig.resourceId,
                positionId: node.position ??
                    characterConfig.defaultPoseId, // 优先使用指定的position，否则使用默认值
              );

              final newCharacters = Map.of(_currentState.characters);

              // 清理现有角色的动画属性，确保位置计算基于基础位置
              for (final entry in newCharacters.entries) {
                newCharacters[entry.key] = entry.value.copyWith(
                  clearAnimationProperties: true, // 清理动画属性
                );
              }

              // 处理时序差分切换
              String? finalExpression = node.expression;
              if (node.hasTimedExpression) {
                if (_isFastForwardMode) {
                  // 快进模式下直接使用目标差分
                  finalExpression = node.endExpression;
                  //print('[GameManager] 快进模式: 直接使用目标差分 ${node.endExpression}');
                } else {
                  // 先设置起始差分
                  finalExpression = node.startExpression;
                  //print('[GameManager] 时序差分切换: 起始差分 ${node.startExpression}, ${node.switchDelay}秒后切换到 ${node.endExpression}');

                  // 启动定时器进行差分切换
                  _scheduleExpressionSwitch(
                    characterKey: finalCharacterKey,
                    targetExpression: node.endExpression!,
                    delay: node.switchDelay!,
                  );
                }
              }

              newCharacters[finalCharacterKey] = currentCharacterState.copyWith(
                pose: node.pose,
                expression: finalExpression,
                clearAnimationProperties: false,
              );

              // 检测角色位置变化并触发动画（如果需要）
              if (!_isFastForwardMode) {
                await _checkAndAnimateCharacterPositions(newCharacters);
              }

              _currentState = _currentState.copyWith(
                  characters: newCharacters,
                  everShownCharacters: _everShownCharacters);
              _gameStateController.add(_currentState);
              ////print('[GameManager] 发送状态更新，当前角色列表: ${newCharacters.keys}');

              // 如果有动画，启动动画播放（非阻塞）
              if (!_isFastForwardMode && node.animation != null) {
                _playCharacterAnimation(finalCharacterKey, node.animation!,
                    repeatCount: node.repeatCount);
              }
            }
          }
        } else if (tailSpeakerAlias != null && tailSpeakerAlias.isNotEmpty) {
          _applyNarrationTailCharacterDiff(
            targetAlias: tailSpeakerAlias,
            pose: node.tailPose,
            expression: node.tailExpression,
            animation: node.tailAnimation,
            repeatCount: node.tailRepeatCount,
          );
        }

        await _applyInlineApiTokenForSay(
          inlineApiToken: node.inlineApiToken,
          characterAlias: node.character,
          tailCharacterAlias: tailSpeakerAlias,
        );

        // 在 NVL 或 NVLN 模式下的特殊处理
        if (_activeNvlContext != _NvlContextMode.none) {
          final shouldRevealOverlay = _showNvlOverlayOnNextDialogue;
          if (shouldRevealOverlay) {
            _showNvlOverlayOnNextDialogue = false;
          }
          final newNvlDialogue = NvlDialogue(
            speaker: characterConfig?.name,
            speakerAlias: node.character ?? tailSpeakerAlias, // 新增：传递角色简写
            dialogue: resolvedDialogue,
            dialogueTag: node.dialogueTag,
            timestamp: DateTime.now(),
          );

          final updatedNvlDialogues =
              List<NvlDialogue>.from(_currentState.nvlDialogues);
          updatedNvlDialogues.add(newNvlDialogue);

          _currentState = _currentState.copyWith(
            nvlDialogues: updatedNvlDialogues,
            clearDialogueAndSpeaker: true,
            everShownCharacters: _everShownCharacters,
            isNvlOverlayVisible: shouldRevealOverlay ? true : null,
          );

          // 也添加到对话历史
          _addToDialogueHistory(
            speaker: characterConfig?.name,
            dialogue: resolvedDialogue,
            dialogueTag: node.dialogueTag,
            timestamp: DateTime.now(),
            currentNodeIndex: currentNodeIndex,
            sourceScriptFile: node.sourceFile ?? currentScriptFile,
            sourceLine: node.sourceLine,
          );

          _gameStateController.add(_currentState);

          // 检查是否需要创建章节开头的自动存档（NVL模式-第二处）
          try {
            await _chapterAutoSaveManager.onDialogueDisplayed(
              scriptIndex: currentNodeIndex, // 使用当前节点索引，而不是_scriptIndex
              currentScriptFile: currentScriptFile,
              currentLabel: _findNearestLabel(
                  currentNodeIndex), // 也使用currentNodeIndex查找label
              saveStateSnapshot: saveStateSnapshot,
              flowchartManager: _flowchartManager,
            );
          } catch (e, stackTrace) {
            if (kEngineDebugMode) {
              print('[GameManager] ❌ 章节自动存档检查失败: $e');
              print('堆栈: $stackTrace');
            }
          }

          // NVL/NVLN 模式下每句话都要停下来等待点击
          _scriptIndex++;
          _isProcessing = false;
          return;
        } else {
          // 普通对话模式
          // 在CG背景下，如果之前已经设置了对话内容，就不要重复设置
          if (followingMenuNodeIndex == null &&
              !(_isCurrentBackgroundCG() && node.character != null)) {
            _currentState = _currentState.copyWith(
              dialogue: resolvedDialogue,
              dialogueTag: node.dialogueTag,
              speaker: characterConfig?.name,
              speakerAlias: node.character ?? tailSpeakerAlias, // 传入角色简写
              currentNode: null,
              clearDialogueAndSpeaker: false,
              forceNullSpeaker: node.character == null,
              everShownCharacters: _everShownCharacters,
            );
          }

          _addToDialogueHistory(
            speaker: characterConfig?.name,
            dialogue: resolvedDialogue,
            dialogueTag: node.dialogueTag,
            timestamp: DateTime.now(),
            currentNodeIndex: currentNodeIndex,
            sourceScriptFile: node.sourceFile ?? currentScriptFile,
            sourceLine: node.sourceLine,
          );

          // 检查是否需要创建章节开头的自动存档（普通对话模式）
          try {
            await _chapterAutoSaveManager.onDialogueDisplayed(
              scriptIndex: currentNodeIndex, // 使用当前节点索引
              currentScriptFile: currentScriptFile,
              currentLabel: _findNearestLabel(currentNodeIndex),
              saveStateSnapshot: saveStateSnapshot,
              flowchartManager: _flowchartManager,
            );
          } catch (e, stackTrace) {
            if (kEngineDebugMode) {
              print('[GameManager] ❌ 章节自动存档检查失败: $e');
              print('堆栈: $stackTrace');
            }
          }

          if (followingMenuNodeIndex != null) {
            final menuNode =
                _script.children[followingMenuNodeIndex] as MenuNode;
            final localizedMenuNode = _localizeMenuNode(menuNode);
            final previousDialogueEntry = _dialogueHistory.length >= 2
                ? _dialogueHistory[_dialogueHistory.length - 2]
                : null;

            // 分支选择前创建运行时自动存档
            await _createRuntimeAutoSave(reason: '分支选择');
            // 分支选择前创建自动存档
            await _checkAndCreateAutoSave(followingMenuNodeIndex,
                reason: '分支选择');

            _currentState = _currentState.copyWith(
              dialogue: previousDialogueEntry?.dialogue,
              dialogueTag: previousDialogueEntry?.dialogueTag,
              speaker: previousDialogueEntry?.speaker,
              forceNullSpeaker: previousDialogueEntry?.speaker == null,
              currentNode: localizedMenuNode,
              clearDialogueAndSpeaker: false,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
            _scriptIndex = followingMenuNodeIndex;
          } else {
            _gameStateController.add(_currentState);
            _scriptIndex++;
          }
          _isProcessing = false;
          return;
        }
      }

      if (node is MenuNode) {
        final localizedMenuNode = _localizeMenuNode(node);
        // 分支选择前创建运行时自动存档
        await _createRuntimeAutoSave(reason: '分支选择');

        // 分支选择前创建自动存档
        await _checkAndCreateAutoSave(_scriptIndex, reason: '分支选择');

        _currentState = _currentState.copyWith(
            currentNode: localizedMenuNode,
            // 进入选项时保留上一句对话与说话人，避免对话框被隐藏。
            clearDialogueAndSpeaker: false,
            everShownCharacters: _everShownCharacters);
        _gameStateController.add(_currentState);
        // 注意：不立即推进脚本索引，让存档能够保存到MenuNode的位置
        // _scriptIndex 将在选择完成后由 jumpToLabel 推进
        _isProcessing = false;
        return;
      }

      if (node is ReturnNode) {
        // 在回主菜单前创建运行时自动存档
        await _createRuntimeAutoSave(reason: '结局返回');

        // 在结局前创建自动存档
        await _checkAndCreateAutoSave(_scriptIndex, reason: '结局');

        _scriptIndex++;
        onReturn?.call();
        _isProcessing = false;
        return;
      }

      if (node is JumpNode) {
        _scriptIndex++;
        _isProcessing = false;
        jumpToLabel(node.targetLabel);
        return;
      }

      if (node is NvlNode) {
        final shouldDelayOverlay = _shouldDelayNvlOverlay(_scriptIndex);
        _activeNvlContext = _NvlContextMode.standard;
        _showNvlOverlayOnNextDialogue = shouldDelayOverlay;
        _currentState = _currentState.copyWith(
          isNvlMode: true,
          isNvlMovieMode: false,
          isNvlnMode: false, // 确保nvln模式关闭
          isNvlOverlayVisible: !shouldDelayOverlay,
          nvlDialogues: [],
          clearDialogueAndSpeaker: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
        _scriptIndex++;
        continue;
      }
      if (node is NvlnNode) {
        final shouldDelayOverlay = _shouldDelayNvlOverlay(_scriptIndex);
        _activeNvlContext = _NvlContextMode.noMask;
        _showNvlOverlayOnNextDialogue = shouldDelayOverlay;
        _currentState = _currentState.copyWith(
          isNvlMode: true, // nvln使用isNvlMode=true
          isNvlnMode: true, // 保持nvln标志用于UI判断无遮罩
          isNvlMovieMode: false,
          isNvlOverlayVisible: !shouldDelayOverlay,
          nvlDialogues: [],
          clearDialogueAndSpeaker: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
        _scriptIndex++;
        continue;
      }

      if (node is NvlMovieNode) {
        final shouldDelayOverlay = _shouldDelayNvlOverlay(_scriptIndex);
        _activeNvlContext = _NvlContextMode.movie;
        _showNvlOverlayOnNextDialogue = shouldDelayOverlay;
        _currentState = _currentState.copyWith(
          isNvlMode: true,
          isNvlMovieMode: true,
          isNvlnMode: false,
          isNvlOverlayVisible: !shouldDelayOverlay,
          nvlDialogues: [],
          clearDialogueAndSpeaker: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
        _scriptIndex++;
        continue;
      }

      if (node is EndNvlNode) {
        // 退出 NVL 模式并继续执行后续脚本
        _activeNvlContext = _NvlContextMode.none;
        _showNvlOverlayOnNextDialogue = false;
        _currentState = _currentState.copyWith(
          isNvlMode: false,
          isNvlMovieMode: false,
          isNvlnMode: false, // 同时确保nvln模式也关闭
          isNvlOverlayVisible: false,
          nvlDialogues: [],
          clearDialogueAndSpeaker: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
        _scriptIndex++;
        continue; // 继续执行后续节点
      }
      if (node is EndNvlnNode) {
        // 退出无遮罩NVL模式并继续执行后续脚本
        _activeNvlContext = _NvlContextMode.none;
        _showNvlOverlayOnNextDialogue = false;
        _currentState = _currentState.copyWith(
          isNvlnMode: false,
          isNvlMode: false, // 确保普通nvl模式也关闭
          isNvlMovieMode: false,
          isNvlOverlayVisible: false,
          nvlDialogues: [],
          clearDialogueAndSpeaker: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
        _scriptIndex++;
        continue; // 继续执行后续节点
      }

      if (node is EndNvlMovieNode) {
        // 退出 NVL 电影模式并继续执行后续脚本
        _activeNvlContext = _NvlContextMode.none;
        _showNvlOverlayOnNextDialogue = false;
        _currentState = _currentState.copyWith(
          isNvlMode: false,
          isNvlMovieMode: false,
          isNvlnMode: false,
          isNvlOverlayVisible: false,
          nvlDialogues: [],
          clearDialogueAndSpeaker: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
        _scriptIndex++;
        continue; // 继续执行后续节点
      }

      if (node is FxNode) {
        final filter = SceneFilter.fromString(node.filterString);
        if (_fxDiagLogs) {
          debugPrint(
            '[FX_DIAG] FxNode execute index=$_scriptIndex '
            'source=${node.sourceFile ?? "unknown"}:${node.sourceLine ?? -1} '
            'raw="${node.filterString}" parsed=${filter?.type}/${filter?.intensity}/${filter?.animation}/${filter?.duration} '
            'before=${_currentState.sceneFilter?.type}/${_currentState.sceneFilter?.intensity}/${_currentState.sceneFilter?.animation}/${_currentState.sceneFilter?.duration}',
          );
        }
        if (filter != null) {
          _currentState = _currentState.copyWith(
            sceneFilter: filter,
            everShownCharacters: _everShownCharacters,
          );
          _gameStateController.add(_currentState);
          if (_fxDiagLogs) {
            debugPrint(
              '[FX_DIAG] FxNode applied index=$_scriptIndex '
              'after=${_currentState.sceneFilter?.type}/${_currentState.sceneFilter?.intensity}/${_currentState.sceneFilter?.animation}/${_currentState.sceneFilter?.duration}',
            );
          }
        } else if (_fxDiagLogs) {
          debugPrint(
            '[FX_DIAG] FxNode ignored index=$_scriptIndex because parse result is null',
          );
        }
        _scriptIndex++;
        continue;
      }

      if (node is PlayMusicNode) {
        // 使用音乐区间系统处理音乐播放
        final musicRegion = _getMusicRegionForIndex(_scriptIndex);
        if (musicRegion != null) {
          final fullMusicPath = _buildMusicAssetPath(node.musicFile);
          if (kEngineDebugMode && _musicRegionVerboseLogs) {
            print(
                '[MusicSourceDiag] PlayMusicNode: index=$_scriptIndex, raw="${node.musicFile}", resolved="$fullMusicPath"');
          }
          if (fullMusicPath.isEmpty) {
            if (kEngineDebugMode) {
              print(
                  '[MusicRegion] PlayMusicNode音乐名为空，跳过播放: raw="${node.musicFile}" at index $_scriptIndex');
            }
            _scriptIndex++;
            continue;
          }
          if (kEngineDebugMode && _musicRegionVerboseLogs) {
            print(
                '[MusicRegion] PlayMusicNode触发播放: index=$_scriptIndex, raw="${node.musicFile}", regionMusic="${musicRegion.musicFile}", resolvedPath="$fullMusicPath"');
          }
          await MusicManager().playBackgroundMusic(
            fullMusicPath,
            fadeTransition: true,
            fadeDuration: const Duration(milliseconds: 1000),
          );
          _currentState =
              _currentState.copyWith(currentMusicRegion: musicRegion);

          if (kEngineDebugMode) {
            //print('[MusicRegion] 开始播放音乐区间: ${musicRegion.musicFile} at index $_scriptIndex');
          }
        }
        _scriptIndex++;
        continue;
      }

      if (node is StopMusicNode) {
        // 使用音乐区间系统处理音乐停止
        await MusicManager().stopBackgroundMusic(
          fadeOut: true,
          fadeDuration: const Duration(milliseconds: 800),
        );
        _currentState = _currentState.copyWith(currentMusicRegion: null);

        if (kEngineDebugMode) {
          //print('[MusicRegion] 停止音乐 at index $_scriptIndex');
        }
        _scriptIndex++;
        continue;
      }

      if (node is PlaySoundNode) {
        // 播放音效
        String soundFile = node.soundFile;
        if (!soundFile.contains('.')) {
          // 尝试 .ogg 扩展名（优先）
          soundFile = '$soundFile.mp3';
        }

        await MusicManager().playAudio(
          'Assets/sound/$soundFile',
          AudioTrackConfig.sound,
          fadeTransition: true,
          fadeDuration: const Duration(milliseconds: 300), // 音效淡入较快
          loop: node.loop,
        );
        _scriptIndex++;
        continue;
      }

      if (node is StopSoundNode) {
        // 停止音效
        await MusicManager().stopAudio(
          AudioTrackConfig.sound,
          fadeOut: true,
          fadeDuration: const Duration(milliseconds: 200),
        );
        _scriptIndex++;
        continue;
      }

      if (node is BoolNode) {
        // 设置全局bool变量
        await GlobalVariableManager()
            .setBoolVariable(node.variableName, node.value);
        _scriptIndex++;
        continue;
      }

      if (node is ApiCallNode) {
        final executor = onScriptApiExecute;
        if (executor != null) {
          final result = await executor(
            apiName: node.apiName,
            params: node.parameters,
            gameState: _currentState,
            scriptIndex: _scriptIndex,
          );

          if (result.handled) {
            if (result.nextState != null) {
              _currentState = result.nextState!;
              _gameStateController.add(_currentState);
            }

            final waitDuration = result.waitDuration;
            _scriptIndex++;

            if (waitDuration != null && waitDuration > Duration.zero) {
              if (_isFastForwardMode) {
                if (result.stateAfterWait != null) {
                  _applyScriptApiStateAfterWait(result.stateAfterWait!);
                }
                continue;
              }

              _isWaitingForTimer = true;
              _isProcessing = false;
              _currentTimer?.cancel();
              _currentTimerCompletion = () {
                if (result.stateAfterWait != null) {
                  _applyScriptApiStateAfterWait(result.stateAfterWait!);
                }
                unawaited(_executeScript());
              };
              _currentTimer = Timer(waitDuration, _completeCurrentTimerWait);
              return;
            }

            if (result.stateAfterWait != null) {
              _applyScriptApiStateAfterWait(result.stateAfterWait!);
            }

            continue;
          }
        }

        if (kEngineDebugMode) {
          print('[GameManager] 未处理的api命令: ${node.apiName}');
        }
        _scriptIndex++;
        continue;
      }

      if (node is PauseNode) {
        // 处理暂停命令：pause(0.5)
        // 设置暂停等待标志
        _isWaitingForTimer = true;
        _isProcessing = false; // 释放处理锁，但保持timer锁
        _scriptIndex++; // 预先递增索引

        _currentState = _currentState.copyWith(
          isPaused: true,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);

        // 启动计时器
        _currentTimer?.cancel();
        _currentTimerCompletion = () {
          unawaited(_executeScript()); // 恢复脚本执行
        };
        _currentTimer = Timer(
          Duration(milliseconds: (node.duration * 1000).round()),
          _completeCurrentTimerWait,
        );

        return; // 暂停期间停止脚本执行
      }

      if (node is ShakeNode) {
        // 处理震动命令
        final duration = node.duration ?? 1.0; // 默认1秒
        final intensity = node.intensity ?? 8.0; // 默认强度8
        final target = node.target ?? 'background'; // 默认震动背景

        // 设置震动状态
        _currentState = _currentState.copyWith(
          isShaking: true,
          shakeTarget: target,
          shakeDuration: duration,
          shakeIntensity: intensity,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);

        // 启动计时器，震动结束后清除震动状态
        Timer(Duration(milliseconds: (duration * 1000).round()), () {
          _currentState = _currentState.copyWith(
            isShaking: false,
            shakeTarget: null,
            shakeDuration: null,
            shakeIntensity: null,
            everShownCharacters: _everShownCharacters,
          );
          _gameStateController.add(_currentState);
        });

        _scriptIndex++;
        continue;
      }
    }
    _isProcessing = false;
  }

  GameStateSnapshot saveStateSnapshot() {
    if (kEngineDebugMode) {
      //print('[GameManager] 保存存档：cgCharacters数量 = ${_currentState.cgCharacters.length}');
      //print('[GameManager] 保存存档：cgCharacters内容 = ${_currentState.cgCharacters.keys.toList()}');
    }

    return GameStateSnapshot(
      scriptIndex: _scriptIndex,
      currentState: _currentState,
      dialogueHistory: List.from(_dialogueHistory),
      isNvlMode: _currentState.isNvlMode,
      isNvlMovieMode: _currentState.isNvlMovieMode,
      isNvlnMode: _currentState.isNvlnMode, // 新增：保存无遮罩NVL模式状态
      isNvlOverlayVisible: _currentState.isNvlOverlayVisible, // 新增：保存NVL遮罩可见性
      nvlDialogues: List.from(_currentState.nvlDialogues),
      isFastForwardMode: _isFastForwardMode, // 保存快进状态
    );
  }

  Future<void> _transitionToNewMovie(String movieFile,
      [SceneFilter? sceneFilter,
      List<String>? layers,
      String? transitionType,
      String? animation,
      int? repeatCount]) async {
    if (_context == null) return;

    //////print('[GameManager] 开始movie转场到视频: $movieFile, 转场类型: ${transitionType ?? "fade"}');

    final oldBackground = _currentState.background;

    try {
      await SceneTransitionEffectManager.instance.transition(
        context: _context!,
        transitionType: transitionType != null
            ? TransitionTypeParser.parseTransitionType(transitionType)
            : TransitionType.fade,
        oldBackground: oldBackground,
        newBackground: null, // 视频会占据整个背景
        onMidTransition: () async {
          //////print('[GameManager] movie转场中点，更新状态');
          _currentState = _currentState.copyWith(
            movieFile: movieFile,
            movieRepeatCount: repeatCount, // 新增：传递视频重复播放次数
            background: null, // 清空背景，视频优先显示
            sceneFilter: sceneFilter,
            clearSceneFilter: sceneFilter == null,
            sceneLayers: layers,
            clearSceneLayers: layers == null,
            clearDialogueAndSpeaker: true,
            clearCharacters: true,
            clearCgCharacters: true,
            sceneAnimation: animation,
            sceneAnimationRepeat: repeatCount,
            sceneAnimationProperties:
                animation != null ? <String, double>{} : null,
            clearSceneAnimation: animation == null,
            everShownCharacters: _everShownCharacters,
          );
          _gameStateController.add(_currentState);

          // 启动场景动画（如果有）
          if (animation != null && _tickerProvider != null) {
            _startSceneAnimation(animation, repeatCount);
          }
        },
      );

      //////print('[GameManager] movie转场完成');
    } catch (e) {
      //print('[GameManager] movie转场失败: $e');
      // 转场失败时直接更新状态
      _currentState = _currentState.copyWith(
        movieFile: movieFile,
        movieRepeatCount: repeatCount, // 新增：传递视频重复播放次数
        background: null,
        sceneFilter: sceneFilter,
        clearSceneFilter: sceneFilter == null,
        sceneLayers: layers,
        clearSceneLayers: layers == null,
        clearDialogueAndSpeaker: true,
        clearCharacters: true,
        clearCgCharacters: true,
        sceneAnimation: animation,
        sceneAnimationRepeat: repeatCount,
        sceneAnimationProperties: animation != null ? <String, double>{} : null,
        clearSceneAnimation: animation == null,
        everShownCharacters: _everShownCharacters,
      );
      _gameStateController.add(_currentState);

      if (animation != null && _tickerProvider != null) {
        _startSceneAnimation(animation, repeatCount);
      }
    }
  }

  void returnToPreviousScreen() {
    onReturn?.call();
  }

  void _addToDialogueHistory({
    String? speaker,
    required String dialogue,
    String? dialogueTag,
    required DateTime timestamp,
    required int currentNodeIndex,
    String? sourceScriptFile,
    int? sourceLine,
  }) {
    // 历史快照索引应与常规存档语义一致：指向“下一条待执行节点”。
    final nextScriptIndex =
        (currentNodeIndex + 1).clamp(0, _script.children.length).toInt();

    // 为历史条目创建快照时，使用正确的节点索引
    // 对于NVL模式，只保存当前单句对话而不是整个NVL列表，避免回退时重复显示
    final nvlDialoguesForSnapshot = _currentState.isNvlMode
        ? [
            NvlDialogue(
                speaker: speaker,
                speakerAlias: null,
                dialogue: dialogue,
                dialogueTag: dialogueTag,
                timestamp: timestamp)
          ]
        : List.from(_currentState.nvlDialogues);

    final snapshot = GameStateSnapshot(
      scriptIndex: nextScriptIndex,
      currentState: _currentState,
      dialogueHistory: const [], // 避免循环引用
      isNvlMode: _currentState.isNvlMode,
      isNvlMovieMode: _currentState.isNvlMovieMode,
      isNvlnMode: _currentState.isNvlnMode, // 新增：保存无遮罩NVL模式状态
      isNvlOverlayVisible: _currentState.isNvlOverlayVisible,
      nvlDialogues: List.from(_currentState.nvlDialogues),
    );

    _dialogueHistory.add(DialogueHistoryEntry(
      speaker: speaker,
      dialogue: RichTextParser.cleanText(dialogue),
      dialogueTag: dialogueTag,
      timestamp: timestamp,
      scriptIndex: currentNodeIndex,
      sourceScriptFile: sourceScriptFile,
      sourceLine: sourceLine,
      stateSnapshot: snapshot,
    ));

    if (_dialogueHistory.length > maxHistoryEntries) {
      _dialogueHistory.removeAt(0);
    }
  }

  /// 从新脚本中刷新历史记录的对话文本
  /// 用于修复剧本修改后读档时对话文本未更新的bug
  void _refreshDialogueHistoryFromScript() {
    final updatedHistory = <DialogueHistoryEntry>[];

    for (final entry in _dialogueHistory) {
      final scriptIndex = entry.scriptIndex;

      // 检查索引是否有效
      if (scriptIndex < 0 || scriptIndex >= _script.children.length) {
        // 索引无效，保留原对话
        updatedHistory.add(entry);
        continue;
      }

      final node = _script.children[scriptIndex];
      String? newDialogue;
      String? newSpeaker;

      // 根据节点类型提取最新的对话文本（只处理SayNode）
      if (node is SayNode) {
        newDialogue = _resolveScriptText(node.dialogue);
        if (node.character != null) {
          final characterConfig = _characterConfigs[node.character];
          newSpeaker = characterConfig?.name;
        }
      }

      // 如果成功获取到新对话，则更新；否则保留原对话
      if (newDialogue != null) {
        final updatedEntry = DialogueHistoryEntry(
          speaker: newSpeaker ?? entry.speaker,
          dialogue: RichTextParser.cleanText(newDialogue),
          dialogueTag: (node is SayNode) ? node.dialogueTag : entry.dialogueTag,
          timestamp: entry.timestamp,
          scriptIndex: entry.scriptIndex,
          sourceScriptFile: entry.sourceScriptFile,
          sourceLine: entry.sourceLine,
          stateSnapshot: entry.stateSnapshot,
        );
        updatedHistory.add(updatedEntry);
      } else {
        // 节点不包含对话或类型不匹配，保留原对话
        updatedHistory.add(entry);
      }
    }

    _dialogueHistory = updatedHistory;
  }

  /// 从新脚本中刷新当前状态的对话文本
  /// 用于修复剧本修改后读档时当前对话文本未更新的bug
  void _refreshCurrentStateDialogue({int? dialogueScriptIndex}) {
    final targetScriptIndex = dialogueScriptIndex ?? _scriptIndex;

    // 检查索引是否有效
    if (targetScriptIndex < 0 || targetScriptIndex >= _script.children.length) {
      return;
    }

    final node = _script.children[targetScriptIndex];
    String? newDialogue;
    String? newSpeaker;

    // 根据节点类型提取最新的对话文本（只处理SayNode）
    if (node is SayNode) {
      newDialogue = _resolveScriptText(node.dialogue);
      if (node.character != null) {
        final characterConfig = _characterConfigs[node.character];
        newSpeaker = characterConfig?.name;
      }
    }

    // 如果成功获取到新对话，则更新当前状态
    if (newDialogue != null) {
      _currentState = _currentState.copyWith(
        dialogue: newDialogue,
        dialogueTag:
            (node is SayNode) ? node.dialogueTag : _currentState.dialogueTag,
        speaker: newSpeaker,
        everShownCharacters: _everShownCharacters,
      );

      // 如果是NVL模式，同时更新nvlDialogues中的最后一条对话
      if (_currentState.isNvlMode && _currentState.nvlDialogues.isNotEmpty) {
        final updatedNvlDialogues =
            List<NvlDialogue>.from(_currentState.nvlDialogues);
        final lastDialogue = updatedNvlDialogues.last;
        updatedNvlDialogues[updatedNvlDialogues.length - 1] = NvlDialogue(
          speaker: newSpeaker,
          speakerAlias: lastDialogue.speakerAlias,
          dialogue: newDialogue,
          dialogueTag:
              (node is SayNode) ? node.dialogueTag : lastDialogue.dialogueTag,
          timestamp: lastDialogue.timestamp,
        );
        _currentState = _currentState.copyWith(
          nvlDialogues: updatedNvlDialogues,
          everShownCharacters: _everShownCharacters,
        );
      }
    }
  }

  List<DialogueHistoryEntry> getDialogueHistory() {
    return List.unmodifiable(_dialogueHistory);
  }

  Future<void> jumpToHistoryEntry(
      DialogueHistoryEntry entry, String scriptName) async {
    final targetIndex = _dialogueHistory.indexOf(entry);
    if (targetIndex != -1) {
      _dialogueHistory.removeRange(targetIndex + 1, _dialogueHistory.length);
    }

    // 检查目标场景和当前场景是否不同，如果不同则使用场景转场
    final snapshot = entry.stateSnapshot;
    final currentBackground = _currentState.background;
    final targetBackground = snapshot.currentState.background;
    final nextScriptIndex =
        (entry.scriptIndex + 1).clamp(0, _script.children.length).toInt();

    Future<void> restoreAndAlignHistoryJumpState() async {
      await restoreFromSnapshot(scriptName, snapshot, shouldReExecute: false);

      // 兼容旧历史快照语义：确保跳转后立即显示选中句，并从下一句继续推进。
      if (!snapshot.isNvlMode) {
        _refreshCurrentStateDialogue(dialogueScriptIndex: entry.scriptIndex);
        _gameStateController.add(_currentState);
      }
      _scriptIndex = nextScriptIndex;
      await _checkMusicRegionAtCurrentIndex(forceCheck: true);
    }

    if (_context != null && currentBackground != targetBackground) {
      // 需要场景转场，找出目标场景是用什么转场出现的
      String originalTransitionType = 'fade'; // 默认使用fade

      // 在历史记录中向前搜索，找到切换到目标场景时使用的转场类型
      for (int i = _scriptIndex; i >= 0; i--) {
        if (i < _script.children.length) {
          final node = _script.children[i];
          if (node is BackgroundNode && node.background == targetBackground) {
            originalTransitionType = node.transitionType ?? 'fade';
            break;
          }
        }
      }

      await SceneTransitionEffectManager.instance.transition(
        context: _context!,
        transitionType:
            TransitionTypeParser.parseTransitionType(originalTransitionType),
        oldBackground: currentBackground,
        newBackground: targetBackground,
        onMidTransition: () async {
          // 在转场中点恢复并对齐历史跳转状态
          await restoreAndAlignHistoryJumpState();
        },
        duration: const Duration(milliseconds: 600), // 回退转场稍微快一些
      );
    } else {
      // 不需要场景转场，直接恢复并对齐状态
      await restoreAndAlignHistoryJumpState();
    }
  }

  /// 启动场景计时器
  void _startSceneTimer(double seconds) {
    // 取消之前的计时器（如果存在）
    _currentTimer?.cancel();
    _currentTimerCompletion = null;

    final durationMs = (seconds * 1000).round();

    _currentTimer = Timer(Duration(milliseconds: durationMs), () async {
      // 检查计时器是否仍然有效（防止已被取消的计时器执行）
      if (_isWaitingForTimer &&
          _currentTimer != null &&
          _currentTimer!.isActive == false) {
        _isWaitingForTimer = false;
        _currentTimer = null;
        await _executeScript();
      }
    });
  }

  bool _shouldDelayNvlOverlay(int nvlNodeIndex) {
    for (int i = nvlNodeIndex + 1; i < _script.children.length; i++) {
      final candidate = _script.children[i];
      if (candidate is CommentNode || candidate is LabelNode) {
        continue;
      }
      if (candidate is BackgroundNode || candidate is MovieNode) {
        return true;
      }
      return false;
    }
    return false;
  }

  /// 定时切换角色差分表情
  void _scheduleExpressionSwitch({
    required String characterKey,
    required String targetExpression,
    required double delay,
  }) {
    final delayMs = (delay * 1000).round();

    Timer(Duration(milliseconds: delayMs), () {
      // 检查角色是否仍然存在
      final currentCharacter = _currentState.characters[characterKey];
      if (currentCharacter != null) {
        //print('[GameManager] 执行时序差分切换: $characterKey -> $targetExpression');

        final newCharacters = Map.of(_currentState.characters);
        newCharacters[characterKey] = currentCharacter.copyWith(
          expression: targetExpression,
          clearAnimationProperties: false,
        );

        _currentState = _currentState.copyWith(
          characters: newCharacters,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
      }
    });
  }

  /// 检查当前背景是否为CG
  bool _isCurrentBackgroundCG() {
    // 新的CG检测逻辑：检查是否有CG角色正在显示
    if (_currentState.cgCharacters.isNotEmpty) {
      return true;
    }

    // 保留原有逻辑作为兜底（向后兼容）
    final currentBg = _currentState.background;
    if (currentBg == null) return false;

    // 检查背景名称是否包含"cg"关键词（不区分大小写）
    return currentBg.toLowerCase().contains('cg');
  }

  /// 使用转场效果切换背景
  /// 计算包含预设属性的场景动画属性
  Map<String, double>? _calculateSceneAnimationPropertiesWithPresets(
      String? animationName) {
    if (animationName == null) return null;

    // 获取动画定义
    final animDef = AnimationManager.getAnimation(animationName);
    if (animDef == null) return null;

    // 基础属性
    final baseProperties = {
      'xcenter': 0.0,
      'ycenter': 0.0,
      'scale': 1.0,
      'alpha': 1.0,
      'rotation': 0.0,
    };

    // 应用预设属性
    final presetProperties = animDef.presetProperties;
    if (presetProperties.isNotEmpty) {
      //print('[GameManager] 场景动画 $animationName 应用预设属性: $presetProperties');
      for (final entry in presetProperties.entries) {
        final currentValue = baseProperties[entry.key] ?? 0.0;
        baseProperties[entry.key] = currentValue + entry.value;
        //print('[GameManager] 场景预设 ${entry.key}: $currentValue + ${entry.value} = ${baseProperties[entry.key]}');
      }
      //print('[GameManager] 场景最终属性: $baseProperties');
      return baseProperties;
    }

    return null;
  }

  Future<void> _transitionToNewBackground(String newBackground,
      [SceneFilter? sceneFilter,
      List<String>? layers,
      String? transitionType,
      String? animation,
      int? repeatCount,
      bool? clearCG]) async {
    if (_context == null) return;

    //////print('[GameManager] 开始scene转场到背景: $newBackground, 转场类型: ${transitionType ?? "fade"}');

    // 预加载背景图片以避免动画闪烁
    if (!ColorBackgroundRenderer.isValidHexColor(newBackground)) {
      try {
        // 先尝试使用AssetManager的智能查找，它会处理CG的特殊路径
        String? assetPath = await AssetManager().findAsset(newBackground);

        // 如果AssetManager找不到，再尝试backgrounds路径
        if (assetPath == null) {
          assetPath = await AssetManager()
              .findAsset('backgrounds/${newBackground.replaceAll(' ', '-')}');
        }

        if (assetPath != null && _context != null) {
          // 预加载图片到缓存
          if (kEngineDebugMode && !assetPath.startsWith('assets/')) {
            // Debug模式下，如果是绝对路径，使用FileImage
            await precacheImage(FileImage(File(assetPath)), _context!);
          } else {
            // 发布模式或assets路径，使用AssetImage
            await precacheImage(AssetImage(assetPath), _context!);
          }
          ////print('[GameManager] 预加载背景图片完成: $newBackground -> $assetPath');
        } else {
          ////print('[GameManager] 警告: 无法找到背景图片进行预加载: $newBackground');
        }
      } catch (e) {
        ////print('[GameManager] 预加载背景图片失败: $e');
      }
    }

    // 解析转场类型
    final effectType = TransitionTypeParser.parseTransitionType(
      transitionType ?? defaultSceneTransitionType,
    );
    ////print('[GameManager] 转场类型解析: 输入="$transitionType" -> 解析结果=${effectType.name}');

    // 如果是diss转场，需要准备旧背景和新背景名称
    String? oldBackgroundName;
    String? newBackgroundName;

    if (effectType == TransitionType.diss) {
      // 传递背景名称而不是Widget，让AssetManager智能查找正确路径
      if (_currentState.background != null) {
        // 先尝试直接使用背景名称，让AssetManager智能查找
        final oldBgPath =
            await AssetManager().findAsset(_currentState.background!);
        if (oldBgPath != null) {
          oldBackgroundName = _currentState.background!;
        } else {
          // 回退到backgrounds路径
          oldBackgroundName =
              'backgrounds/${_currentState.background!.replaceAll(' ', '-')}';
        }
      }

      // 对新背景也做同样处理
      final newBgPath = await AssetManager().findAsset(newBackground);
      if (newBgPath != null) {
        newBackgroundName = newBackground;
      } else {
        // 回退到backgrounds路径
        newBackgroundName = 'backgrounds/${newBackground.replaceAll(' ', '-')}';
      }

      ////print('[GameManager] diss转场参数: 旧背景="$oldBackgroundName", 新背景="$newBackgroundName"');
    }

    // 在转场开始前先清除对话框，避免"残留"效果
    _currentState = _currentState.copyWith(
      clearDialogueAndSpeaker: true,
      everShownCharacters: _everShownCharacters,
    );
    _gameStateController.add(_currentState);

    // 根据转场类型选择转场管理器
    if (effectType == TransitionType.fade) {
      // 使用原有的黑屏转场
      await SceneTransitionManager.instance.transition(
        context: _context!,
        onMidTransition: () {
          //////print('[GameManager] scene转场中点 - 切换背景到: $newBackground');
          // 在黑屏最深时切换背景和清除所有角色（类似Renpy）
          // 先停止并清理旧的场景动画控制器
          _sceneAnimationController?.dispose();
          _sceneAnimationController = null;

          _currentState = _currentState.copyWith(
            background: newBackground,
            clearMovieFile: true, // 新增：scene转场时清理视频状态
            sceneFilter: sceneFilter,
            clearSceneFilter: sceneFilter == null, // 如果没有滤镜，清除现有滤镜
            sceneLayers: layers,
            clearSceneLayers: layers == null, // 如果是单图层，清除多图层数据
            clearCharacters: true,
            clearCgCharacters: clearCG ?? false, // 清空CG角色
            sceneAnimation: animation,
            sceneAnimationRepeat: repeatCount,
            sceneAnimationProperties:
                _calculateSceneAnimationPropertiesWithPresets(
                    animation), // 应用预设属性
            clearSceneAnimation: animation == null,
            everShownCharacters: _everShownCharacters,
          );
          //////print('[GameManager] 状态更新 - 旧背景: ${oldState.background}, 新背景: ${_currentState.background}');
          _gameStateController.add(_currentState);
          //////print('[GameManager] 状态已发送到Stream');
        },
        duration: const Duration(milliseconds: 800),
      );
    } else {
      // 使用新的转场效果系统
      await SceneTransitionEffectManager.instance.transition(
        context: _context!,
        transitionType: effectType,
        oldBackground: oldBackgroundName,
        newBackground: newBackgroundName,
        captureFrame: _transitionFrameCapturer,
        onMidTransition: () {
          //////print('[GameManager] scene转场中点 - 切换背景到: $newBackground');
          // 对于dissolve转场，不在中点更新背景状态，避免与转场效果冲突
          // 只更新其他状态，背景更新延迟到转场完成
          if (effectType != TransitionType.diss) {
            // 在转场中点切换背景和清除所有角色（类似Renpy）
            // 先停止并清理旧的场景动画控制器
            _sceneAnimationController?.dispose();
            _sceneAnimationController = null;

            _currentState = _currentState.copyWith(
              background: newBackground,
              clearMovieFile: true, // 新增：scene转场时清理视频状态
              sceneFilter: sceneFilter,
              clearSceneFilter: sceneFilter == null, // 如果没有滤镜，清除现有滤镜
              sceneLayers: layers,
              clearSceneLayers: layers == null, // 如果是单图层，清除多图层数据
              clearCharacters: true,
              clearCgCharacters: clearCG ?? false, // 清空CG角色
              sceneAnimation: animation,
              sceneAnimationRepeat: repeatCount,
              sceneAnimationProperties:
                  _calculateSceneAnimationPropertiesWithPresets(
                      animation), // 应用预设属性
              clearSceneAnimation: animation == null,
              everShownCharacters: _everShownCharacters,
            );
            //////print('[GameManager] 状态更新 - 旧背景: ${oldState.background}, 新背景: ${_currentState.background}');
            _gameStateController.add(_currentState);
            //////print('[GameManager] 状态已发送到Stream');
          } else {
            // 对于dissolve转场，在转场中点就更新背景，避免结束时闪烁
            _sceneAnimationController?.dispose();
            _sceneAnimationController = null;

            _currentState = _currentState.copyWith(
              background: newBackground, // 在中点就更新背景，避免结束时的闪烁
              clearMovieFile: true, // 新增：scene转场时清理视频状态
              sceneFilter: sceneFilter,
              clearSceneFilter: sceneFilter == null,
              sceneLayers: layers,
              clearSceneLayers: layers == null,
              clearCharacters: true,
              clearCgCharacters: clearCG ?? false, // 清空CG角色
              sceneAnimation: animation,
              sceneAnimationRepeat: repeatCount,
              sceneAnimationProperties:
                  _calculateSceneAnimationPropertiesWithPresets(
                      animation), // 应用预设属性
              clearSceneAnimation: animation == null,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
          }
        },
        duration: const Duration(milliseconds: 800),
      );

      // dissolve转场的背景已在中点更新，这里不需要重复更新
    }

    //////print('[GameManager] scene转场完成，等待计时器结束');
    // 转场完成，等待计时器结束后自动执行后续脚本
    _isProcessing = false;

    // 如果有场景动画，延迟启动动画以确保背景图片完全加载
    if (animation != null && _tickerProvider != null) {
      // 等待足够的时间让背景图片完全加载和渲染
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_tickerProvider != null) {
          _startSceneAnimation(animation, repeatCount);
        }
      });
    }
  }

  /// 检查脚本是否已初始化
  bool _isScriptInitialized() {
    try {
      // 尝试访问_script，如果未初始化会抛出LateInitializationError
      return _script.children.isNotEmpty;
    } catch (e) {
      // 如果抛出异常，说明_script尚未初始化
      return false;
    }
  }

  /// 检测当前脚本位置的场景动画并重新启动
  Future<void> _checkAndRestoreSceneAnimation(
      {bool notifyListeners = true}) async {
    if (_tickerProvider == null) return;

    // 检查_script是否已初始化
    if (!_isScriptInitialized()) return;

    // 向前搜索最近的BackgroundNode，找出当前场景的动画设置
    BackgroundNode? lastBackgroundNode;

    for (int i = _scriptIndex; i >= 0; i--) {
      if (i < _script.children.length &&
          _script.children[i] is BackgroundNode) {
        lastBackgroundNode = _script.children[i] as BackgroundNode;
        break;
      }
    }

    if (lastBackgroundNode != null && lastBackgroundNode.animation != null) {
      ////print('[GameManager] 检测到当前场景有动画: ${lastBackgroundNode.animation}, repeat: ${lastBackgroundNode.repeatCount}');

      // 更新当前状态的场景动画信息
      _currentState = _currentState.copyWith(
        sceneAnimation: lastBackgroundNode.animation,
        sceneAnimationRepeat: lastBackgroundNode.repeatCount,
        sceneAnimationProperties: _calculateSceneAnimationPropertiesWithPresets(
            lastBackgroundNode.animation), // 应用预设属性
        everShownCharacters: _everShownCharacters,
      );

      // 立即启动场景动画
      _startSceneAnimation(
          lastBackgroundNode.animation!, lastBackgroundNode.repeatCount);

      // 发送状态更新
      if (notifyListeners) {
        _gameStateController.add(_currentState);
      }
    } else {
      ////print('[GameManager] 当前场景没有检测到动画');
    }
  }

  void stopAllSounds() {
    MusicManager().stopAudio(AudioTrackConfig.sound);
  }

  // 存储当前正在播放动画的角色控制器
  final Map<String, CharacterAnimationController> _activeCharacterAnimations =
      {};

  /// 播放角色动画
  Future<void> _playCharacterAnimation(String characterId, String animationName,
      {int? repeatCount}) async {
    CharacterState? characterState = _currentState.characters[characterId];
    bool isCgCharacter = false;

    if (characterState == null) {
      characterState = _currentState.cgCharacters[characterId];
      if (characterState == null) {
        return;
      }
      isCgCharacter = true;
    }

    // 检查该角色是否已经有动画在播放
    final existingAnimController = _activeCharacterAnimations[characterId];
    if (existingAnimController != null) {
      // 如果已经有动画在播放同一个动画，直接返回，让动画继续
      if (existingAnimController.animationName == animationName) {
        //print('[GameManager] 角色 $characterId 已在播放动画 $animationName，继承动画状态');
        return;
      } else {
        // 如果在播放不同的动画，停止旧动画
        //print('[GameManager] 角色 $characterId 切换动画: ${existingAnimController.animationName} -> $animationName');
        existingAnimController.stopInfiniteLoop();
        existingAnimController.dispose();
        _activeCharacterAnimations.remove(characterId);
      }
    }

    Map<String, double> baseProperties;

    if (!isCgCharacter) {
      // 应用自动分布逻辑，获取实际的分布后位置
      final characterOrder = _currentState.characters.keys.toList();
      final distributedPoseConfigs =
          CharacterAutoDistribution.calculateAutoDistribution(
        _currentState.characters,
        _poseConfigs,
        characterOrder,
      );

      // 优先查找角色专属的自动分布配置，如果没有则使用原始配置
      final autoDistributedPoseId = '${characterId}_auto_distributed';
      final poseConfig = distributedPoseConfigs[autoDistributedPoseId] ??
          distributedPoseConfigs[characterState.positionId] ??
          _poseConfigs[characterState.positionId];
      if (poseConfig == null) return;

      baseProperties = {
        'xcenter': poseConfig.xcenter,
        'ycenter': poseConfig.ycenter,
        'scale': poseConfig.scale,
        'alpha': 1.0,
        'rotation': characterState.animationProperties?['rotation'] ?? 0.0,
      };
    } else {
      baseProperties = {
        'xcenter': characterState.animationProperties?['xcenter'] ?? 0.0,
        'ycenter': characterState.animationProperties?['ycenter'] ?? 0.0,
        'scale': characterState.animationProperties?['scale'] ?? 1.0,
        'alpha': characterState.animationProperties?['alpha'] ?? 1.0,
        'rotation': characterState.animationProperties?['rotation'] ?? 0.0,
      };
    }

    final existingProperties = characterState.animationProperties;
    if (existingProperties != null && existingProperties.isNotEmpty) {
      baseProperties.addAll(existingProperties);
    }

    // 创建动画控制器
    final animController = CharacterAnimationController(
      characterId: characterId,
      onAnimationUpdate: (properties) {
        if (isCgCharacter) {
          final newCgCharacters = Map.of(_currentState.cgCharacters);
          final currentCgState = newCgCharacters[characterId];
          if (currentCgState != null) {
            newCgCharacters[characterId] = currentCgState.copyWith(
              animationProperties: properties,
            );
            _currentState = _currentState.copyWith(
              cgCharacters: newCgCharacters,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
          }
        } else {
          final newCharacters = Map.of(_currentState.characters);
          final currentCharacterState = newCharacters[characterId];
          if (currentCharacterState != null) {
            newCharacters[characterId] = currentCharacterState.copyWith(
              animationProperties: properties,
            );
            _currentState = _currentState.copyWith(
              characters: newCharacters,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
          }
        }
      },
      onComplete: () {
        //print('[GameManager] 角色 $characterId 动画 $animationName 播放完成');
        if (isCgCharacter) {
          final newCgCharacters = Map.of(_currentState.cgCharacters);
          final currentCgState = newCgCharacters[characterId];
          if (currentCgState != null) {
            newCgCharacters[characterId] = currentCgState.copyWith(
              clearAnimationProperties: true,
            );
            _currentState = _currentState.copyWith(
              cgCharacters: newCgCharacters,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
          }
        } else {
          final newCharacters = Map.of(_currentState.characters);
          final currentCharacterState = newCharacters[characterId];
          if (currentCharacterState != null) {
            newCharacters[characterId] = currentCharacterState.copyWith(
              clearAnimationProperties: true,
            );
            _currentState = _currentState.copyWith(
              characters: newCharacters,
              everShownCharacters: _everShownCharacters,
            );
            _gameStateController.add(_currentState);
          }
        }
        // 从活跃动画列表中移除
        _activeCharacterAnimations.remove(characterId);
      },
    );

    // 添加到活跃动画列表
    _activeCharacterAnimations[characterId] = animController;

    // 播放动画，传递repeatCount参数
    if (_tickerProvider != null) {
      await animController.playAnimation(
        animationName,
        _tickerProvider!,
        baseProperties,
        repeatCount: repeatCount,
      );
    } else {
      ////print('[GameManager] 无TickerProvider，跳过动画播放');
      // 如果无法播放动画，从活跃列表中移除
      _activeCharacterAnimations.remove(characterId);
    }

    // 动画播放完成后自动清理（如果还在活跃列表中）
    if (_activeCharacterAnimations[characterId] == animController) {
      animController.dispose();
      _activeCharacterAnimations.remove(characterId);
    }
  }

  /// 播放场景动画
  Future<void> _startSceneAnimation(
      String animationName, int? repeatCount) async {
    ////print('[GameManager] 开始播放场景动画: $animationName, repeat: $repeatCount');

    // 停止之前的场景动画
    _sceneAnimationController?.dispose();

    // 获取基础属性（场景的默认位置）
    final baseProperties = <String, double>{
      'xcenter': 0.0,
      'ycenter': 0.0,
      'scale': 1.0,
      'alpha': 1.0,
      'rotation': 0.0,
    };

    // 创建场景动画控制器
    _sceneAnimationController = SceneAnimationController(
      sceneId: 'scene_background',
      onAnimationUpdate: (properties) {
        // 实时更新场景动画属性
        _currentState = _currentState.copyWith(
          sceneAnimationProperties: properties,
          everShownCharacters: _everShownCharacters,
        );
        _gameStateController.add(_currentState);
      },
      onComplete: () {
        ////print('[GameManager] 场景动画 $animationName 播放完成');
        // 保持动画的最终状态，不清除动画属性
        final finalProperties = _sceneAnimationController?.currentProperties;
        if (finalProperties != null) {
          _currentState = _currentState.copyWith(
            sceneAnimationProperties: finalProperties,
            everShownCharacters: _everShownCharacters,
          );
          _gameStateController.add(_currentState);
        }
        _sceneAnimationController?.dispose();
        _sceneAnimationController = null;
      },
    );

    // 播放动画
    if (_tickerProvider != null) {
      await _sceneAnimationController!.playAnimation(
        animationName,
        _tickerProvider!,
        baseProperties,
        repeatCount: repeatCount,
      );
    }
  }

  /// 淡出动画完成后移除角色
  void removeCharacterAfterFadeOut(String characterId) {
    final oldCharacters = Map.of(_currentState.characters);
    final newCharacters = Map.of(_currentState.characters);
    newCharacters.remove(characterId);

    if (_tickerProvider == null || newCharacters.length < 2) {
      _currentState = _currentState.copyWith(
          characters: newCharacters,
          clearDialogueAndSpeaker: false,
          everShownCharacters: _everShownCharacters);
      _gameStateController.add(_currentState);
      return;
    }

    // 手动计算位置变化，考虑角色的实际当前位置（包括动画属性）
    final characterOrder = newCharacters.keys.toList();
    final newDistributed = CharacterAutoDistribution.calculateAutoDistribution(
      newCharacters,
      _poseConfigs,
      characterOrder,
    );

    final positionChanges = <CharacterPositionChange>[];
    for (final characterId in newCharacters.keys) {
      final character = newCharacters[characterId]!;
      final originalPose = _poseConfigs[character.positionId];

      if (originalPose != null && originalPose.isAutoAnchor) {
        // 获取角色当前的实际显示位置
        double currentX = originalPose.xcenter;
        if (character.animationProperties != null &&
            character.animationProperties!.containsKey('xcenter')) {
          currentX = character.animationProperties!['xcenter']!;
        } else {
          // 如果没有动画属性，使用当前自动分布后的位置
          final currentDistributed =
              CharacterAutoDistribution.calculateAutoDistribution(
            oldCharacters,
            _poseConfigs,
            oldCharacters.keys.toList(),
          );
          final currentAutoDistributedPoseId =
              '${characterId}_auto_distributed';
          final currentDistributedPose =
              currentDistributed[currentAutoDistributedPoseId] ?? originalPose;
          currentX = currentDistributedPose.xcenter;
        }

        // 获取新的目标位置
        final newAutoDistributedPoseId = '${characterId}_auto_distributed';
        final newDistributedPose =
            newDistributed[newAutoDistributedPoseId] ?? originalPose;
        final targetX = newDistributedPose.xcenter;

        // 如果位置有变化，添加到动画列表
        if ((currentX - targetX).abs() > 0.001) {
          positionChanges.add(CharacterPositionChange(
            characterId: characterId,
            fromX: currentX,
            toX: targetX,
          ));
        }
      }
    }

    // 如果有位置变化，播放动画
    if (positionChanges.isNotEmpty) {
      // 先移除角色，同时设置剩余角色的动画属性为当前位置，避免闪烁
      final updatedCharacters = Map<String, CharacterState>.from(newCharacters);
      for (final change in positionChanges) {
        final character = updatedCharacters[change.characterId];
        if (character != null) {
          updatedCharacters[change.characterId] = character.copyWith(
            animationProperties: {'xcenter': change.fromX}, // 设置为当前位置，避免闪烁
          );
        }
      }

      _currentState = _currentState.copyWith(
          characters: updatedCharacters,
          clearDialogueAndSpeaker: false,
          everShownCharacters: _everShownCharacters);
      _gameStateController.add(_currentState);

      // 然后播放动画
      _characterPositionAnimator?.stop();
      _characterPositionAnimator = CharacterPositionAnimator();

      _characterPositionAnimator!.animatePositionChanges(
        positionChanges: positionChanges,
        vsync: _tickerProvider!,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        onUpdate: (positions) {
          final animatingCharacters =
              Map<String, CharacterState>.from(_currentState.characters);
          for (final entry in positions.entries) {
            final targetCharacterId = entry.key;
            final xPosition = entry.value;
            final character = animatingCharacters[targetCharacterId];
            if (character != null) {
              animatingCharacters[targetCharacterId] = character.copyWith(
                animationProperties: {'xcenter': xPosition},
              );
            }
          }

          _currentState = _currentState.copyWith(
              characters: animatingCharacters,
              clearDialogueAndSpeaker: false,
              everShownCharacters: _everShownCharacters);
          _gameStateController.add(_currentState);
        },
        onComplete: () {
          // 动画完成，简单更新状态，不清理动画属性
          // 让后续的正常操作（如添加新角色）自然地处理最终状态
        },
      );
    } else {
      // 没有位置变化，直接移除角色
      _currentState = _currentState.copyWith(
          characters: newCharacters,
          clearDialogueAndSpeaker: false,
          everShownCharacters: _everShownCharacters);
      _gameStateController.add(_currentState);
    }
  }

  /// 清除anime覆盖层
  void clearAnimeOverlay() {
    _currentState = _currentState.copyWith(
      clearAnimeOverlay: true,
      everShownCharacters: _everShownCharacters,
    );
    _gameStateController.add(_currentState);
  }

  /// 预热当前游戏状态的CG
  /// 在读档后立即调用，确保当前显示的CG已经预热完成
  Future<void> _preWarmCurrentGameState() async {
    final preWarmManager = CgPreWarmManager();

    // 确保预热管理器正在运行
    preWarmManager.start();

    final preWarmTasks = <Future<bool>>[];

    // 检查当前背景是否为CG背景
    final currentBackground = _currentState.background;
    if (currentBackground != null && _isCurrentBackgroundCG()) {
      // 从背景路径推断CG参数（这需要根据实际的路径格式调整）
      final cgInfo = _extractCgInfoFromBackground(currentBackground);
      if (cgInfo != null) {
        final preWarmTask = preWarmManager.preWarmUrgent(
          resourceId: cgInfo['resourceId']!,
          pose: cgInfo['pose']!,
          expression: cgInfo['expression']!,
        );
        preWarmTasks.add(preWarmTask);
      }
    }

    // 预热当前显示的CG角色
    for (final entry in _currentState.cgCharacters.entries) {
      final characterState = entry.value;
      final resourceId = characterState.resourceId;
      final pose = characterState.pose ?? 'pose1';
      final expression = characterState.expression ?? 'happy';

      final preWarmTask = preWarmManager.preWarmUrgent(
        resourceId: resourceId,
        pose: pose,
        expression: expression,
      );
      preWarmTasks.add(preWarmTask);
    }

    // 等待所有预热任务完成
    if (preWarmTasks.isNotEmpty) {
      try {
        await Future.wait(preWarmTasks);
      } catch (e) {
        // 预热失败时静默处理，不影响游戏继续
      }
    }
  }

  /// 从背景路径中提取CG信息
  /// 返回Map包含resourceId, pose, expression，如果不是CG背景则返回null
  Map<String, String>? _extractCgInfoFromBackground(String backgroundPath) {
    try {
      // 检查是否为内存缓存路径格式：/memory_cache/cg_cache/resourceId_pose_expression.png
      if (CgImageCompositor().isCachePath(backgroundPath)) {
        final filename = backgroundPath.split('/').last;
        final cacheKey = filename.replaceAll('.png', '');
        final parts = cacheKey.split('_');

        if (parts.length >= 3) {
          final resourceId = parts.sublist(0, parts.length - 2).join('_');
          final pose = parts[parts.length - 2];
          final expression = parts[parts.length - 1];

          return {
            'resourceId': resourceId,
            'pose': pose,
            'expression': expression,
          };
        }
      }

      // 如果是其他格式的CG背景，可以在这里添加更多解析逻辑
      // 目前只处理内存缓存格式

      return null;
    } catch (e) {
      return null;
    }
  }

  void dispose() {
    LocalizationManager().removeListener(_languageListener);
    _currentTimer?.cancel(); // 取消活跃的计时器
    _currentTimerCompletion = null;
    _sceneAnimationController?.dispose(); // 清理场景动画控制器

    // 清理CG预分析器
    _cgPreAnalyzer.dispose();

    // 停止CG预热管理器
    CgPreWarmManager().stop();

    // 清理所有活跃的角色动画控制器
    for (final controller in _activeCharacterAnimations.values) {
      controller.stopInfiniteLoop();
      controller.dispose();
    }
    _activeCharacterAnimations.clear();

    stopAllSounds(); // 停止所有音效
    _gameStateController.close();
  }

  // 全局变量管理方法
  Future<bool> getBoolVariable(String name, {bool defaultValue = false}) async {
    return await GlobalVariableManager()
        .getBoolVariable(name, defaultValue: defaultValue);
  }

  bool getBoolVariableSync(String name, {bool defaultValue = false}) {
    return GlobalVariableManager()
        .getBoolVariableSync(name, defaultValue: defaultValue);
  }

  Future<void> setBoolVariable(String name, bool value) async {
    await GlobalVariableManager().setBoolVariable(name, value);
  }
}

class GameState {
  final String? background;
  final String? movieFile; // 新增：当前视频文件
  final int? movieRepeatCount; // 新增：视频重复播放次数
  final Map<String, CharacterState> characters;
  final String? dialogue;
  final String? dialogueTag; // 对话行尾扩展 token（项目层可自定义）
  final String? speaker;
  final String? speakerAlias; // 新增：角色简写
  final SksNode? currentNode;
  final bool isNvlMode;
  final bool isNvlMovieMode;
  final bool isNvlnMode; // 新增：无遮罩NVL模式
  final bool isNvlOverlayVisible; // 新增：NVL遮罩是否可见
  final List<NvlDialogue> nvlDialogues;
  final Set<String> everShownCharacters;
  final SceneFilter? sceneFilter;
  final List<String>? sceneLayers; // 新增：多图层支持
  final String? sceneTopRightStatusText; // 场景右上角状态文本（项目层可自定义）
  final MusicRegion? currentMusicRegion; // 新增：当前音乐区间
  final Map<String, double>? sceneAnimationProperties; // 新增：场景动画属性
  final String? sceneAnimation; // 新增：当前场景动画名称
  final int? sceneAnimationRepeat; // 新增：场景动画重复次数
  final String? animeOverlay; // 新增：anime覆盖动画名称
  final bool animeLoop; // 新增：anime是否循环播放
  final bool animeKeep; // 新增：anime完成后是否保留
  final Map<String, CharacterState> cgCharacters; // 新增：CG角色状态，像scene一样铺满显示
  final bool isFastForwarding; // 新增：当前是否处于快进模式
  final bool isAutoPlaying; // 新增：当前是否处于自动播放模式
  final bool isPaused; // 新增：当前是否处于脚本 pause(...) 等待状态
  final bool isShaking; // 新增：当前是否正在震动
  final String? shakeTarget; // 新增：震动目标 (dialogue/background)
  final double? shakeDuration; // 新增：震动持续时间
  final double? shakeIntensity; // 新增：震动强度
  final String? scriptOverlayText; // 脚本API驱动的覆盖层文本
  final String? scriptOverlayBackgroundColor; // 覆盖层背景色（字符串）
  final String? scriptOverlayTextColor; // 覆盖层文字颜色（字符串）
  final String? scriptOverlayAnimation; // 覆盖层动画名称
  final double scriptOverlayStretchX; // 覆盖层文字水平拉伸
  final bool scriptOverlayPlainStyle; // 覆盖层是否使用纯色无修饰文本
  final bool scriptOverlayFitScreen; // 覆盖层文本是否按屏幕约束最大化
  final bool scriptOverlayFitCover; // 覆盖层文本是否使用cover策略（允许裁切）
  final String? scriptOverlayLineWidthRatios; // 覆盖层逐行目标宽度比例（CSV）
  final bool scriptOverlayStretchEachLine; // 覆盖层逐行按目标宽度拉伸/压缩
  final int scriptOverlayRevision; // 覆盖层版本号（用于触发重播动画）

  GameState({
    this.background,
    this.movieFile, // 新增：视频文件参数
    this.movieRepeatCount, // 新增：视频重复播放次数参数
    this.characters = const {},
    this.dialogue,
    this.dialogueTag,
    this.speaker,
    this.speakerAlias, // 新增：角色简写
    this.currentNode,
    this.isNvlMode = false,
    this.isNvlMovieMode = false,
    this.isNvlnMode = false, // 新增：无遮罩NVL模式，默认false
    this.isNvlOverlayVisible = false, // 新增：NVL遮罩默认隐藏
    this.nvlDialogues = const [],
    this.everShownCharacters = const {},
    this.sceneFilter,
    this.sceneLayers,
    this.sceneTopRightStatusText,
    this.currentMusicRegion,
    this.sceneAnimationProperties,
    this.sceneAnimation,
    this.sceneAnimationRepeat,
    this.animeOverlay, // 新增
    this.animeLoop = false, // 新增，默认不循环
    this.animeKeep = false, // 新增，默认不保留
    this.cgCharacters = const {}, // 新增：CG角色状态，默认为空
    this.isFastForwarding = false, // 新增：快进状态，默认false
    this.isAutoPlaying = false, // 新增：自动播放状态，默认false
    this.isPaused = false, // 新增：脚本暂停状态，默认false
    this.isShaking = false, // 新增：震动状态，默认false
    this.shakeTarget, // 新增：震动目标
    this.shakeDuration, // 新增：震动持续时间
    this.shakeIntensity, // 新增：震动强度
    this.scriptOverlayText,
    this.scriptOverlayBackgroundColor,
    this.scriptOverlayTextColor,
    this.scriptOverlayAnimation,
    this.scriptOverlayStretchX = 1.0,
    this.scriptOverlayPlainStyle = false,
    this.scriptOverlayFitScreen = false,
    this.scriptOverlayFitCover = false,
    this.scriptOverlayLineWidthRatios,
    this.scriptOverlayStretchEachLine = false,
    this.scriptOverlayRevision = 0,
  });

  factory GameState.initial() {
    return GameState();
  }

  GameState copyWith({
    String? background,
    bool clearBackground = false,
    String? movieFile, // 新增：视频文件参数
    int? movieRepeatCount, // 新增：视频重复播放次数参数
    bool clearMovieFile = false, // 新增：清理视频文件标志
    Map<String, CharacterState>? characters,
    String? dialogue,
    String? dialogueTag,
    String? speaker,
    String? speakerAlias, // 新增：角色简写参数
    SksNode? currentNode,
    bool clearDialogueAndSpeaker = false,
    bool clearCharacters = false,
    bool forceNullCurrentNode = false,
    bool forceNullSpeaker = false,
    bool? isNvlMode,
    bool? isNvlMovieMode,
    bool? isNvlnMode, // 新增：无遮罩NVL模式参数
    bool? isNvlOverlayVisible, // 新增：NVL遮罩是否可见
    List<NvlDialogue>? nvlDialogues,
    Set<String>? everShownCharacters,
    SceneFilter? sceneFilter,
    bool clearSceneFilter = false,
    List<String>? sceneLayers,
    bool clearSceneLayers = false,
    String? sceneTopRightStatusText,
    bool clearSceneTopRightStatusText = false,
    MusicRegion? currentMusicRegion,
    Map<String, double>? sceneAnimationProperties,
    bool clearSceneAnimation = false,
    String? sceneAnimation,
    int? sceneAnimationRepeat,
    String? animeOverlay, // 新增
    bool? animeLoop, // 新增
    bool? animeKeep, // 新增
    bool clearAnimeOverlay = false, // 新增
    Map<String, CharacterState>? cgCharacters, // 新增：CG角色状态
    bool clearCgCharacters = false, // 新增：是否清空CG角色
    bool? isFastForwarding, // 新增：快进状态
    bool? isAutoPlaying, // 新增：自动播放状态
    bool? isPaused, // 新增：脚本暂停状态
    bool? isShaking, // 新增：震动状态
    String? shakeTarget, // 新增：震动目标
    double? shakeDuration, // 新增：震动持续时间
    double? shakeIntensity, // 新增：震动强度
    String? scriptOverlayText,
    String? scriptOverlayBackgroundColor,
    String? scriptOverlayTextColor,
    String? scriptOverlayAnimation,
    double? scriptOverlayStretchX,
    bool? scriptOverlayPlainStyle,
    bool? scriptOverlayFitScreen,
    bool? scriptOverlayFitCover,
    String? scriptOverlayLineWidthRatios,
    bool? scriptOverlayStretchEachLine,
    int? scriptOverlayRevision,
    bool clearScriptOverlay = false,
  }) {
    return GameState(
      background: clearBackground ? null : (background ?? this.background),
      movieFile: clearMovieFile
          ? null
          : (movieFile ?? this.movieFile), // 修复：正确处理movie文件清理
      movieRepeatCount: clearMovieFile
          ? null
          : (movieRepeatCount ?? this.movieRepeatCount), // 新增：处理视频重复次数
      characters: clearCharacters
          ? <String, CharacterState>{}
          : (characters ?? this.characters),
      dialogue: clearDialogueAndSpeaker ? null : (dialogue ?? this.dialogue),
      dialogueTag:
          clearDialogueAndSpeaker ? null : (dialogueTag ?? this.dialogueTag),
      speaker: forceNullSpeaker
          ? null
          : (clearDialogueAndSpeaker ? null : (speaker ?? this.speaker)),
      speakerAlias: clearDialogueAndSpeaker
          ? null
          : (forceNullSpeaker
              ? speakerAlias
              : (speakerAlias ?? this.speakerAlias)), // 允许“无说话人”场景显式携带角色简写
      currentNode:
          forceNullCurrentNode ? null : (currentNode ?? this.currentNode),
      isNvlMode: isNvlMode ?? this.isNvlMode,
      isNvlMovieMode: isNvlMovieMode ?? this.isNvlMovieMode,
      isNvlnMode: isNvlnMode ?? this.isNvlnMode, // 新增：无遮罩NVL模式处理
      isNvlOverlayVisible:
          isNvlOverlayVisible ?? this.isNvlOverlayVisible, // 新增：NVL遮罩可见性
      nvlDialogues: nvlDialogues ?? this.nvlDialogues,
      everShownCharacters: everShownCharacters ?? this.everShownCharacters,
      sceneFilter: clearSceneFilter ? null : (sceneFilter ?? this.sceneFilter),
      sceneLayers: clearSceneLayers ? null : (sceneLayers ?? this.sceneLayers),
      sceneTopRightStatusText: clearSceneTopRightStatusText
          ? null
          : (sceneTopRightStatusText ?? this.sceneTopRightStatusText),
      currentMusicRegion: currentMusicRegion ?? this.currentMusicRegion,
      sceneAnimationProperties: clearSceneAnimation
          ? null
          : (sceneAnimationProperties ?? this.sceneAnimationProperties),
      sceneAnimation:
          clearSceneAnimation ? null : (sceneAnimation ?? this.sceneAnimation),
      sceneAnimationRepeat: clearSceneAnimation
          ? null
          : (sceneAnimationRepeat ?? this.sceneAnimationRepeat),
      animeOverlay:
          clearAnimeOverlay ? null : (animeOverlay ?? this.animeOverlay), // 新增
      animeLoop: animeLoop ?? this.animeLoop, // 新增
      animeKeep: animeKeep ?? this.animeKeep, // 新增
      cgCharacters: clearCgCharacters
          ? <String, CharacterState>{}
          : (cgCharacters ?? this.cgCharacters), // 新增
      isFastForwarding: isFastForwarding ?? this.isFastForwarding, // 新增：快进状态
      isAutoPlaying: isAutoPlaying ?? this.isAutoPlaying, // 新增：自动播放状态
      isPaused: isPaused ?? this.isPaused, // 新增：脚本暂停状态
      isShaking: isShaking ?? this.isShaking, // 新增：震动状态
      shakeTarget: shakeTarget ?? this.shakeTarget, // 新增：震动目标
      shakeDuration: shakeDuration ?? this.shakeDuration, // 新增：震动持续时间
      shakeIntensity: shakeIntensity ?? this.shakeIntensity, // 新增：震动强度
      scriptOverlayText: clearScriptOverlay
          ? null
          : (scriptOverlayText ?? this.scriptOverlayText),
      scriptOverlayBackgroundColor: clearScriptOverlay
          ? null
          : (scriptOverlayBackgroundColor ?? this.scriptOverlayBackgroundColor),
      scriptOverlayTextColor: clearScriptOverlay
          ? null
          : (scriptOverlayTextColor ?? this.scriptOverlayTextColor),
      scriptOverlayAnimation: clearScriptOverlay
          ? null
          : (scriptOverlayAnimation ?? this.scriptOverlayAnimation),
      scriptOverlayStretchX: clearScriptOverlay
          ? 1.0
          : (scriptOverlayStretchX ?? this.scriptOverlayStretchX),
      scriptOverlayPlainStyle: clearScriptOverlay
          ? false
          : (scriptOverlayPlainStyle ?? this.scriptOverlayPlainStyle),
      scriptOverlayFitScreen: clearScriptOverlay
          ? false
          : (scriptOverlayFitScreen ?? this.scriptOverlayFitScreen),
      scriptOverlayFitCover: clearScriptOverlay
          ? false
          : (scriptOverlayFitCover ?? this.scriptOverlayFitCover),
      scriptOverlayLineWidthRatios: clearScriptOverlay
          ? null
          : (scriptOverlayLineWidthRatios ?? this.scriptOverlayLineWidthRatios),
      scriptOverlayStretchEachLine: clearScriptOverlay
          ? false
          : (scriptOverlayStretchEachLine ?? this.scriptOverlayStretchEachLine),
      scriptOverlayRevision:
          scriptOverlayRevision ?? this.scriptOverlayRevision,
    );
  }
}

class NvlDialogue {
  final String? speaker;
  final String? speakerAlias; // 新增：角色简写
  final String dialogue;
  final String? dialogueTag; // 对话行尾扩展 token（项目层可自定义）
  final DateTime timestamp;

  NvlDialogue({
    this.speaker,
    this.speakerAlias, // 新增：角色简写参数
    required this.dialogue,
    this.dialogueTag,
    required this.timestamp,
  });
}

class CharacterState {
  final String resourceId;
  final String? pose;
  final String? expression;
  final String? positionId;
  final String? maskType; // 可编程蒙版类型（例如 silhouette）
  final String? maskColor; // 可编程蒙版颜色（字符串，支持 #RRGGBB/#AARRGGBB）
  final Map<String, double>? animationProperties;
  final bool isFadingOut;

  CharacterState({
    required this.resourceId,
    this.pose,
    this.expression,
    this.positionId,
    this.maskType,
    this.maskColor,
    this.animationProperties,
    this.isFadingOut = false,
  });

  CharacterState copyWith({
    String? resourceId,
    String? pose,
    String? expression,
    String? positionId,
    String? maskType,
    String? maskColor,
    bool clearMask = false,
    Map<String, double>? animationProperties,
    bool clearAnimationProperties = false,
    bool? isFadingOut,
  }) {
    return CharacterState(
      resourceId: resourceId ?? this.resourceId,
      pose: pose ?? this.pose,
      expression: expression ?? this.expression,
      positionId: positionId ?? this.positionId,
      maskType: clearMask ? null : (maskType ?? this.maskType),
      maskColor: clearMask ? null : (maskColor ?? this.maskColor),
      animationProperties: clearAnimationProperties
          ? null
          : (animationProperties ?? this.animationProperties),
      isFadingOut: isFadingOut ?? this.isFadingOut,
    );
  }
}

class GameStateSnapshot {
  final int scriptIndex;
  final GameState currentState;
  final List<DialogueHistoryEntry> dialogueHistory;
  final bool isNvlMode;
  final bool isNvlMovieMode;
  final bool isNvlnMode; // 新增：无遮罩NVL模式状态保存
  final bool isNvlOverlayVisible; // 新增：NVL遮罩可见性
  final List<NvlDialogue> nvlDialogues;
  final bool isFastForwardMode; // 添加快进状态保存

  GameStateSnapshot({
    required this.scriptIndex,
    required this.currentState,
    this.dialogueHistory = const [],
    this.isNvlMode = false,
    this.isNvlMovieMode = false,
    this.isNvlnMode = false, // 新增：无遮罩NVL模式状态保存，默认false
    this.isNvlOverlayVisible = false, // 新增：NVL遮罩默认隐藏
    this.nvlDialogues = const [],
    this.isFastForwardMode = false, // 默认非快进状态
  });
}

class DialogueHistoryEntry {
  final String? speaker;
  final String dialogue;
  final String? dialogueTag; // 对话行尾扩展 token（项目层可自定义）
  final DateTime timestamp;
  final int scriptIndex;
  final String? sourceScriptFile; // 对话来源脚本名（不含扩展名）
  final int? sourceLine; // 对话来源脚本行号（1-based）
  final GameStateSnapshot stateSnapshot;

  DialogueHistoryEntry({
    this.speaker,
    required this.dialogue,
    this.dialogueTag,
    required this.timestamp,
    required this.scriptIndex,
    this.sourceScriptFile,
    this.sourceLine,
    required this.stateSnapshot,
  });
}
