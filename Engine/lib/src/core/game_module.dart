import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/screens/main_menu_screen.dart';
import 'package:sakiengine/src/screens/game_play_screen.dart';
import 'package:sakiengine/src/screens/save_load_screen.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/config/project_info_manager.dart';
import 'package:sakiengine/src/core/script_canvas.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';
import 'package:sakiengine/src/widgets/choice_menu.dart';
import 'package:sakiengine/src/widgets/common/configurable_menu_button.dart';
import 'package:sakiengine/src/widgets/common/default_menu_buttons.dart';
import 'package:sakiengine/src/widgets/dialogue_box.dart';
import 'package:sakiengine/src/widgets/settings_screen.dart';
import 'package:sakiengine/src/widgets/about_screen.dart';
import 'package:sakiengine/src/screens/review_screen.dart';
import 'package:sakiengine/src/widgets/common/exit_confirmation_dialog.dart';
import 'package:sakiengine/src/widgets/common/virtual_game_canvas.dart';
import 'package:sakiengine/src/integrations/steam/steam_achievement_service.dart';

/// Applied to ordinary character sprites after their pose/expression layers
/// have been composited.
///
/// A color matrix is used instead of [BlendMode.multiply] directly so fully
/// transparent pixels remain transparent. [strength] blends between the
/// original sprite (0) and a full solid-color multiply (1).
@immutable
class CharacterLighting {
  final Color multiplyColor;
  final double strength;

  const CharacterLighting({required this.multiplyColor, this.strength = 1.0})
    : assert(strength >= 0.0 && strength <= 1.0);

  ColorFilter get colorFilter {
    final argb = multiplyColor.toARGB32();
    final red = (argb >> 16 & 0xFF) / 255.0;
    final green = (argb >> 8 & 0xFF) / 255.0;
    final blue = (argb & 0xFF) / 255.0;
    final retained = 1.0 - strength;

    return ColorFilter.matrix(<double>[
      retained + red * strength,
      0,
      0,
      0,
      0,
      0,
      retained + green * strength,
      0,
      0,
      0,
      0,
      0,
      retained + blue * strength,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
  }
}

/// 游戏模块接口 - 定义项目可以覆盖的所有组件
abstract class GameModule {
  /// 新游戏使用的入口脚本。读取存档时仍以存档中的脚本为准。
  String get initialScript;

  /// 返回当前脚本使用的快速存档命名空间。
  ///
  /// 默认返回 null，继续使用全局快速存档。多章节项目可按入口脚本返回
  /// 不同命名空间，使各章节的“继续游戏”进度互不覆盖。
  String? quickSaveNamespaceForScript(String currentScript);

  /// 主菜单屏幕工厂
  Widget createMainMenuScreen({
    required VoidCallback onNewGame,
    required VoidCallback onLoadGame,
    Function(SaveSlot)? onLoadGameWithSave,
    VoidCallback? onContinueGame, // 新增：继续游戏回调
    bool skipMusicDelay = false,
  });

  /// 游戏界面屏幕工厂
  Widget createGamePlayScreen({
    Key? key,
    SaveSlot? saveSlotToLoad,
    VoidCallback? onReturnToMenu,
    Function(SaveSlot)? onLoadGame,
  });

  /// 存档界面屏幕工厂
  Widget createSaveLoadScreen({
    required SaveLoadMode mode,
    GameManager? gameManager,
    VoidCallback? onClose,
    Function(SaveSlot)? onLoadSlot,
  });

  /// 设置界面屏幕工厂
  Widget createSettingsScreen({
    required VoidCallback onClose,
    GameManager? gameManager,
    Function(SaveSlot)? onLoadSlot,
  });

  /// 关于页面工厂（可选覆盖）
  Widget createAboutScreen({
    required VoidCallback onClose,
    bool useOverlayScaffold = true,
    bool showHeader = true,
    bool showFooter = false,
  }) {
    return AboutScreen(
      onClose: onClose,
      useOverlayScaffold: useOverlayScaffold,
      showHeader: showHeader,
      showFooter: showFooter,
    );
  }

  /// 回顾界面工厂（可选覆盖）
  Widget createReviewOverlay({
    required List<DialogueHistoryEntry> dialogueHistory,
    required void Function(bool triggeredByOverscroll) onClose,
    Function(DialogueHistoryEntry)? onJumpToEntry,
    bool enableBottomScrollClose = false,
  }) {
    return ReviewOverlay(
      dialogueHistory: dialogueHistory,
      onClose: onClose,
      onJumpToEntry: onJumpToEntry,
      enableBottomScrollClose: enableBottomScrollClose,
    );
  }

  /// 对话框组件工厂
  Widget createDialogueBox({
    Key? key,
    String? speaker,
    String? speakerAlias, // 新增：角色简写参数
    String? dialogueTag, // 对话行尾扩展 token（项目层可自定义）
    required String dialogue,
    DialogueProgressionManager? progressionManager,
    required bool isFastForwarding,
    required int scriptIndex, // 新增：脚本索引参数
    VoidCallback? onToggleSettings,
    VoidCallback? onToggleReview,
  });

  /// 选项菜单组件工厂（可选覆盖）。
  /// 默认使用引擎 ChoiceMenu；项目可返回自定义实现完全接管选项 UI。
  Widget createChoiceMenu({
    Key? key,
    required MenuNode menuNode,
    required ValueChanged<String> onChoiceSelected,
    required bool isFastForwarding,
    String? leadingDialogue,
  }) {
    return ChoiceMenu(
      key: key,
      menuNode: menuNode,
      onChoiceSelected: onChoiceSelected,
      isFastForwarding: isFastForwarding,
    );
  }

  /// 选项菜单是否接管菜单前最后一句台词的显示。
  ///
  /// 返回 `false` 时，最后一句继续显示在普通对话框，选项菜单仅负责选项。
  /// 默认保留现有行为，避免改变既有项目的自定义选项布局。
  bool get choiceMenuDisplaysLeadingDialogue => true;

  /// 创建自定义场景基础层（位于角色层下方）。
  /// 返回 `null` 时表示不插入自定义层。
  Widget? createSceneBaseLayer({
    required BuildContext context,
    required GameState gameState,
  });

  /// 默认的 scene 转场类型。
  /// 当脚本没有显式指定 `with` 时使用。
  String get defaultSceneTransitionType => 'fade';

  /// 返回开发用背景选择网格中显示的名称。
  ///
  /// 默认直接使用背景资源 ID；项目可返回与背景左上角一致的本地化名称。
  String resolveBackgroundDisplayName(String backgroundId) => backgroundId;

  /// 是否继续使用引擎默认的 scene 背景绘制。
  /// 返回 `false` 可在模块中完全接管 scene 背景表现。
  bool shouldRenderDefaultSceneBackground(GameState gameState);

  /// 返回当前场景应用于普通角色立绘的环境光色。
  ///
  /// 返回 `null` 时保持角色原色。CG、背景、scene 挂件与 anime 不受影响。
  CharacterLighting? resolveCharacterLighting(GameState gameState);

  /// 创建 scene 挂件层。
  /// 渲染位置：背景层之上、角色层之下。
  /// 返回 `null` 时表示不渲染挂件。
  Widget? createDialogueAttachment({
    required BuildContext context,
    required GameState gameState,
    required int scriptIndex,
  });

  /// 创建 scene 前景层（位于角色/CG/anime层之上、UI层之下）。
  /// 返回 `null` 时表示不渲染前景层。
  Widget? createSceneForegroundLayer({
    required BuildContext context,
    required GameState gameState,
    required int scriptIndex,
  }) {
    return null;
  }

  /// Resolves artwork for an active `canvas <id>` effect or
  /// `api canvas.play` performance.
  ///
  /// The engine supplies a full-screen [Canvas], its exact [Size], and a
  /// normalized 0–1 timeline through [ScriptCanvasDefinition]. Projects
  /// register named artwork here; the engine owns scene placement, lifecycle,
  /// and cinematic input blocking.
  ScriptCanvasDefinition? resolveScriptCanvas({
    required String canvasId,
    required GameState gameState,
    required int scriptIndex,
  }) {
    final normalizedId = canvasId.trim();
    for (final registration in scriptCanvases) {
      if (registration.id == normalizedId) {
        return registration.definition;
      }
    }
    return null;
  }

  /// Named canvas effects available to `canvas <id>` and Shift+V tooling.
  List<ScriptCanvasRegistration> get scriptCanvases => const [];

  /// 创建自定义状态指示器层（如快进/自动播放/暂停）。
  /// 返回 `null` 时使用引擎默认处理。
  Widget? createStatusIndicatorLayer({
    required BuildContext context,
    required GameState gameState,
    required GameManager gameManager,
  }) {
    return null;
  }

  /// 处理脚本 `api` 调用。
  /// 默认返回未处理，由项目模块按需覆写。
  Future<ScriptApiExecutionResult> handleScriptApiCall({
    required String apiName,
    required Map<String, String> params,
    required GameState gameState,
    required int scriptIndex,
  }) async {
    final canvasResult = _handleScriptCanvasApi(
      apiName: apiName,
      params: params,
      gameState: gameState,
    );
    if (canvasResult != null) {
      return canvasResult;
    }

    final normalizedApiName = apiName.trim().toLowerCase();
    if (normalizedApiName.startsWith('steam.achievement.')) {
      final service = SteamAchievementService.instance;
      final achievementId = resolveSteamAchievementId(params);
      if (achievementId == null) {
        if (kEngineDebugMode) {
          debugPrint(
            '[DefaultGameModule] steam achievement api missing id: api=$apiName params=$params',
          );
        }
        return ScriptApiExecutionResult.handled();
      }

      switch (normalizedApiName) {
        case 'steam.achievement.register':
          service.registerAchievement(achievementId);
          return ScriptApiExecutionResult.handled();
        case 'steam.achievement.unlock':
        case 'steam.achievement.trigger':
          await service.unlockAchievement(achievementId);
          return ScriptApiExecutionResult.handled();
        case 'steam.achievement.clear':
        case 'steam.achievement.reset':
        case 'steam.achievement.cancel':
          await service.clearAchievement(achievementId);
          return ScriptApiExecutionResult.handled();
        default:
          return ScriptApiExecutionResult.handled();
      }
    }

    return const ScriptApiExecutionResult.unhandled();
  }

  /// 自定义配置（可选）
  SakiEngineConfig? createCustomConfig() => null;

  /// 是否启用调试功能
  bool get enableDebugFeatures => true;

  /// 项目特定的主题配置
  ThemeData? createTheme() => null;

  /// 窗口关闭时的退出确认弹窗。
  /// 项目可覆写，以统一自定义弹窗样式。
  Future<bool> showWindowCloseConfirmation(
    BuildContext context, {
    required bool hasProgress,
  }) async {
    return ExitConfirmationDialog.showExitConfirmation(
      context,
      hasProgress: hasProgress,
    );
  }

  /// 获取应用标题
  Future<String> getAppTitle() async {
    try {
      return await ProjectInfoManager().getAppName();
    } catch (e) {
      return 'SakiEngine'; // 默认标题
    }
  }

  /// 模块初始化（可选）
  Future<void> initialize() async {}

  /// 创建主菜单按钮配置列表
  List<MenuButtonConfig> createMainMenuButtonConfigs({
    required VoidCallback onNewGame,
    VoidCallback? onContinueGame,
    required VoidCallback onLoadGame,
    required VoidCallback onSettings,
    required VoidCallback onAbout,
    required VoidCallback onExit,
    required SakiEngineConfig config,
    required double scale,
  });

  /// 获取主菜单按钮布局配置
  MenuButtonsLayoutConfig getMenuButtonsLayoutConfig() {
    return const MenuButtonsLayoutConfig(
      isVertical: false,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 20,
      bottom: 0.05,
      right: 0.01,
    );
  }

  /// 是否显示底部横条
  bool get showBottomBar => true;

  /// 是否把下一句提示图标切换为下划线样式
  bool shouldUseUnderscoreNextArrow({String? speaker, String? speakerAlias}) =>
      false;

  /// 是否显示快捷菜单
  bool get showQuickMenu => true;

  /// 隐藏游戏 UI 后是否允许玩家缩放、拖动画面。
  bool get enableHiddenUiSceneZoom => true;

  /// 隐藏游戏 UI 时允许的最大画面倍率。
  double get hiddenUiSceneMaxZoom => 3.0;

  /// 是否显示引擎默认的快进/自动播放状态指示器。
  /// 项目层自行绘制状态提示时可返回 false，避免重复显示。
  bool get showDefaultStatusIndicators => true;

  /// 返回主菜单时是否启用全局黑屏淡出淡入。
  /// 返回 `false` 时立即切换到主菜单，由项目层自行提供转场表现。
  bool get enableReturnToMainMenuTransition => true;

  /// 是否启用普通对话框切换动画（Fade/Slide）。
  /// 返回 `false` 时，对话框切换将无过渡、立即更新。
  bool get enableDialogueSwitcherAnimation => true;

  /// 是否启用普通对话框切换时的位移动画（Slide）。
  /// 返回 `false` 时仍会保留淡入淡出，但不会产生上下位移。
  bool get enableDialogueSwitcherSlideAnimation => true;
}

String? resolveSteamAchievementId(Map<String, String> params) {
  const keys = <String>['id', 'achievement', 'achievement_id', 'key', 'name'];
  for (final key in keys) {
    final value = params[key];
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}

ScriptApiExecutionResult? _handleScriptCanvasApi({
  required String apiName,
  required Map<String, String> params,
  required GameState gameState,
}) {
  final normalizedApiName = apiName.trim().toLowerCase();
  if (normalizedApiName == 'canvas.clear' ||
      normalizedApiName == 'canvas.stop') {
    return ScriptApiExecutionResult.handled(
      nextState: gameState.copyWith(clearScriptCanvas: true),
    );
  }
  if (normalizedApiName != 'canvas.play') {
    return null;
  }

  final canvasId = (params['id'] ?? params['name'])?.trim();
  if (canvasId == null || canvasId.isEmpty) {
    if (kEngineDebugMode) {
      debugPrint('[ScriptCanvas] canvas.play requires a non-empty id');
    }
    return ScriptApiExecutionResult.handled();
  }

  final parsedDuration = double.tryParse(params['duration']?.trim() ?? '');
  final durationSeconds = parsedDuration != null && parsedDuration.isFinite
      ? parsedDuration.clamp(0.0, 3600.0).toDouble()
      : 0.0;
  final shouldWait = _parseScriptApiBool(
    params['wait'],
    defaultValue: durationSeconds > 0,
  );
  final shouldClear = _parseScriptApiBool(
    params['clear'],
    defaultValue: shouldWait,
  );
  final duration = Duration(milliseconds: (durationSeconds * 1000).round());
  final activeState = gameState.copyWith(
    scriptCanvasId: canvasId,
    scriptCanvasDurationSeconds: durationSeconds,
    scriptCanvasRevision: gameState.scriptCanvasRevision + 1,
    clearDialogueAndSpeaker: true,
  );

  return ScriptApiExecutionResult.handled(
    nextState: activeState,
    waitDuration: shouldWait ? duration : null,
    stateAfterWait: shouldWait && shouldClear
        ? activeState.copyWith(clearScriptCanvas: true)
        : null,
  );
}

bool _parseScriptApiBool(String? raw, {required bool defaultValue}) {
  switch (raw?.trim().toLowerCase()) {
    case 'true':
    case '1':
    case 'yes':
    case 'on':
      return true;
    case 'false':
    case '0':
    case 'no':
    case 'off':
      return false;
    default:
      return defaultValue;
  }
}

/// 默认游戏模块实现 - 使用src/下的默认组件
class DefaultGameModule implements GameModule {
  @override
  String get initialScript => 'start';

  @override
  String? quickSaveNamespaceForScript(String currentScript) => null;

  @override
  Widget createMainMenuScreen({
    required VoidCallback onNewGame,
    required VoidCallback onLoadGame,
    Function(SaveSlot)? onLoadGameWithSave,
    VoidCallback? onContinueGame, // 新增：继续游戏回调
    bool skipMusicDelay = false,
  }) {
    return SakiVirtualGameCanvas(
      child: MainMenuScreen(
        onNewGame: onNewGame,
        onLoadGame: onLoadGame,
        onLoadGameWithSave: onLoadGameWithSave,
        onContinueGame: onContinueGame, // 新增：传递继续游戏回调
        //gameModule: this,
      ),
    );
  }

  @override
  Widget createGamePlayScreen({
    Key? key,
    SaveSlot? saveSlotToLoad,
    VoidCallback? onReturnToMenu,
    Function(SaveSlot)? onLoadGame,
  }) {
    return SakiVirtualGameCanvas(
      child: GamePlayScreen(
        key: key,
        saveSlotToLoad: saveSlotToLoad,
        onReturnToMenu: onReturnToMenu,
        onLoadGame: onLoadGame,
        gameModule: this,
      ),
    );
  }

  @override
  Widget createSaveLoadScreen({
    required SaveLoadMode mode,
    GameManager? gameManager,
    VoidCallback? onClose,
    Function(SaveSlot)? onLoadSlot,
  }) {
    return SaveLoadScreen(
      mode: mode,
      gameManager: gameManager,
      onClose: onClose ?? () {},
      onLoadSlot: onLoadSlot,
    );
  }

  @override
  Widget createSettingsScreen({
    required VoidCallback onClose,
    GameManager? gameManager,
    Function(SaveSlot)? onLoadSlot,
  }) {
    return SettingsScreen(onClose: onClose);
  }

  @override
  Widget createAboutScreen({
    required VoidCallback onClose,
    bool useOverlayScaffold = true,
    bool showHeader = true,
    bool showFooter = false,
  }) {
    return AboutScreen(
      onClose: onClose,
      useOverlayScaffold: useOverlayScaffold,
      showHeader: showHeader,
      showFooter: showFooter,
    );
  }

  @override
  Widget createReviewOverlay({
    required List<DialogueHistoryEntry> dialogueHistory,
    required void Function(bool triggeredByOverscroll) onClose,
    Function(DialogueHistoryEntry)? onJumpToEntry,
    bool enableBottomScrollClose = false,
  }) {
    return ReviewOverlay(
      dialogueHistory: dialogueHistory,
      onClose: onClose,
      onJumpToEntry: onJumpToEntry,
      enableBottomScrollClose: enableBottomScrollClose,
    );
  }

  @override
  Widget createDialogueBox({
    Key? key,
    String? speaker,
    String? speakerAlias, // 新增：角色简写参数
    String? dialogueTag, // 对话行尾扩展 token（项目层可自定义）
    required String dialogue,
    DialogueProgressionManager? progressionManager,
    required bool isFastForwarding,
    required int scriptIndex, // 新增：脚本索引参数
    VoidCallback? onToggleSettings,
    VoidCallback? onToggleReview,
  }) {
    return DialogueBox(
      key: key,
      speaker: speaker,
      speakerAlias: speakerAlias, // 新增：传递角色简写
      dialogueTag: dialogueTag,
      dialogue: dialogue,
      progressionManager: progressionManager,
      isFastForwarding: isFastForwarding,
      scriptIndex: scriptIndex, // 传递脚本索引
    );
  }

  @override
  Widget createChoiceMenu({
    Key? key,
    required MenuNode menuNode,
    required ValueChanged<String> onChoiceSelected,
    required bool isFastForwarding,
    String? leadingDialogue,
  }) {
    return ChoiceMenu(
      key: key,
      menuNode: menuNode,
      onChoiceSelected: onChoiceSelected,
      isFastForwarding: isFastForwarding,
    );
  }

  @override
  bool get choiceMenuDisplaysLeadingDialogue => true;

  @override
  Widget? createSceneBaseLayer({
    required BuildContext context,
    required GameState gameState,
  }) {
    return null;
  }

  @override
  String get defaultSceneTransitionType => 'fade';

  @override
  String resolveBackgroundDisplayName(String backgroundId) => backgroundId;

  @override
  bool shouldRenderDefaultSceneBackground(GameState gameState) {
    return true;
  }

  @override
  CharacterLighting? resolveCharacterLighting(GameState gameState) => null;

  @override
  Widget? createDialogueAttachment({
    required BuildContext context,
    required GameState gameState,
    required int scriptIndex,
  }) {
    return null;
  }

  @override
  Widget? createSceneForegroundLayer({
    required BuildContext context,
    required GameState gameState,
    required int scriptIndex,
  }) {
    return null;
  }

  @override
  ScriptCanvasDefinition? resolveScriptCanvas({
    required String canvasId,
    required GameState gameState,
    required int scriptIndex,
  }) {
    final normalizedId = canvasId.trim();
    for (final registration in scriptCanvases) {
      if (registration.id == normalizedId) {
        return registration.definition;
      }
    }
    return null;
  }

  @override
  List<ScriptCanvasRegistration> get scriptCanvases => const [];

  @override
  Widget? createStatusIndicatorLayer({
    required BuildContext context,
    required GameState gameState,
    required GameManager gameManager,
  }) {
    return null;
  }

  @override
  Future<ScriptApiExecutionResult> handleScriptApiCall({
    required String apiName,
    required Map<String, String> params,
    required GameState gameState,
    required int scriptIndex,
  }) async {
    final canvasResult = _handleScriptCanvasApi(
      apiName: apiName,
      params: params,
      gameState: gameState,
    );
    if (canvasResult != null) {
      return canvasResult;
    }

    final normalizedApiName = apiName.trim().toLowerCase();
    if (normalizedApiName.startsWith('steam.achievement.')) {
      final service = SteamAchievementService.instance;
      final achievementId = resolveSteamAchievementId(params);
      if (achievementId == null) {
        if (kEngineDebugMode) {
          debugPrint(
            '[DefaultGameModule] steam achievement api missing id: api=$apiName params=$params',
          );
        }
        return ScriptApiExecutionResult.handled();
      }

      switch (normalizedApiName) {
        case 'steam.achievement.register':
          service.registerAchievement(achievementId);
          return ScriptApiExecutionResult.handled();
        case 'steam.achievement.unlock':
        case 'steam.achievement.trigger':
          await service.unlockAchievement(achievementId);
          return ScriptApiExecutionResult.handled();
        case 'steam.achievement.clear':
        case 'steam.achievement.reset':
        case 'steam.achievement.cancel':
          await service.clearAchievement(achievementId);
          return ScriptApiExecutionResult.handled();
        default:
          return ScriptApiExecutionResult.handled();
      }
    }

    return const ScriptApiExecutionResult.unhandled();
  }

  @override
  SakiEngineConfig? createCustomConfig() => null;

  @override
  bool get enableDebugFeatures => true;

  @override
  ThemeData? createTheme() => null;

  @override
  Future<bool> showWindowCloseConfirmation(
    BuildContext context, {
    required bool hasProgress,
  }) async {
    return ExitConfirmationDialog.showExitConfirmation(
      context,
      hasProgress: hasProgress,
    );
  }

  @override
  Future<String> getAppTitle() async {
    try {
      return await ProjectInfoManager().getAppName();
    } catch (e) {
      return 'SakiEngine'; // 默认标题
    }
  }

  @override
  Future<void> initialize() async {
    // 默认模块无需特殊初始化
  }

  @override
  List<MenuButtonConfig> createMainMenuButtonConfigs({
    required VoidCallback onNewGame,
    VoidCallback? onContinueGame,
    required VoidCallback onLoadGame,
    required VoidCallback onSettings,
    required VoidCallback onAbout,
    required VoidCallback onExit,
    required SakiEngineConfig config,
    required double scale,
  }) {
    return DefaultMenuButtons.createDefaultConfigs(
      onNewGame: onNewGame,
      onContinueGame: onContinueGame,
      onLoadGame: onLoadGame,
      onSettings: onSettings,
      onAbout: onAbout,
      onExit: onExit,
      config: config,
      scale: scale,
    );
  }

  @override
  MenuButtonsLayoutConfig getMenuButtonsLayoutConfig() {
    return const MenuButtonsLayoutConfig(
      isVertical: false,
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: 20,
      bottom: 0.05,
      right: 0.01,
    );
  }

  @override
  bool get showBottomBar => true;

  @override
  bool get showQuickMenu => true;

  @override
  bool get enableHiddenUiSceneZoom => true;

  @override
  double get hiddenUiSceneMaxZoom => 3.0;

  @override
  bool get showDefaultStatusIndicators => true;

  @override
  bool get enableReturnToMainMenuTransition => true;

  @override
  bool get enableDialogueSwitcherAnimation => true;

  @override
  bool get enableDialogueSwitcherSlideAnimation => true;

  @override
  bool shouldUseUnderscoreNextArrow({String? speaker, String? speakerAlias}) {
    return false;
  }
}
