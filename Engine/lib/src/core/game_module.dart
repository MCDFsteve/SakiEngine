import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/screens/main_menu_screen.dart';
import 'package:sakiengine/src/screens/game_play_screen.dart';
import 'package:sakiengine/src/screens/save_load_screen.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/config/project_info_manager.dart';
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
import 'package:sakiengine/src/integrations/steam/steam_achievement_service.dart';

/// 游戏模块接口 - 定义项目可以覆盖的所有组件
abstract class GameModule {
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

  /// 创建自定义场景基础层（位于角色层下方）。
  /// 返回 `null` 时表示不插入自定义层。
  Widget? createSceneBaseLayer({
    required BuildContext context,
    required GameState gameState,
  });

  /// 默认的 scene 转场类型。
  /// 当脚本没有显式指定 `with` 时使用。
  String get defaultSceneTransitionType => 'fade';

  /// 是否继续使用引擎默认的 scene 背景绘制。
  /// 返回 `false` 可在模块中完全接管 scene 背景表现。
  bool shouldRenderDefaultSceneBackground(GameState gameState);

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

  /// 处理脚本 `api` 调用。
  /// 默认返回未处理，由项目模块按需覆写。
  Future<ScriptApiExecutionResult> handleScriptApiCall({
    required String apiName,
    required Map<String, String> params,
    required GameState gameState,
    required int scriptIndex,
  }) async {
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
  const keys = <String>[
    'id',
    'achievement',
    'achievement_id',
    'key',
    'name',
  ];
  for (final key in keys) {
    final value = params[key];
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return null;
}

/// 默认游戏模块实现 - 使用src/下的默认组件
class DefaultGameModule implements GameModule {
  @override
  Widget createMainMenuScreen({
    required VoidCallback onNewGame,
    required VoidCallback onLoadGame,
    Function(SaveSlot)? onLoadGameWithSave,
    VoidCallback? onContinueGame, // 新增：继续游戏回调
    bool skipMusicDelay = false,
  }) {
    return MainMenuScreen(
      onNewGame: onNewGame,
      onLoadGame: onLoadGame,
      onLoadGameWithSave: onLoadGameWithSave,
      onContinueGame: onContinueGame, // 新增：传递继续游戏回调
      //gameModule: this,
    );
  }

  @override
  Widget createGamePlayScreen({
    Key? key,
    SaveSlot? saveSlotToLoad,
    VoidCallback? onReturnToMenu,
    Function(SaveSlot)? onLoadGame,
  }) {
    return GamePlayScreen(
      key: key,
      saveSlotToLoad: saveSlotToLoad,
      onReturnToMenu: onReturnToMenu,
      onLoadGame: onLoadGame,
      gameModule: this,
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
    return SettingsScreen(
      onClose: onClose,
    );
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
  Widget? createSceneBaseLayer({
    required BuildContext context,
    required GameState gameState,
  }) {
    return null;
  }

  @override
  String get defaultSceneTransitionType => 'fade';

  @override
  bool shouldRenderDefaultSceneBackground(GameState gameState) {
    return true;
  }

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
  Future<ScriptApiExecutionResult> handleScriptApiCall({
    required String apiName,
    required Map<String, String> params,
    required GameState gameState,
    required int scriptIndex,
  }) async {
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
