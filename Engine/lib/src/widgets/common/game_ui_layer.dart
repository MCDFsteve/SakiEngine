import 'dart:async';
import 'dart:io';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/core/game_module.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/screens/game_play_screen.dart';
import 'package:sakiengine/src/screens/save_load_screen.dart';
import 'package:sakiengine/src/screens/story_flowchart_screen.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/utils/expression_selector_manager.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/widgets/common/notification_overlay.dart';
import 'package:sakiengine/src/widgets/common/right_click_ui_manager.dart';
import 'package:sakiengine/src/widgets/debug_panel_dialog.dart';
import 'package:sakiengine/src/widgets/developer_panel.dart';
import 'package:sakiengine/src/widgets/expression_selector_dialog.dart';
import 'package:sakiengine/src/widgets/common/common_indicator.dart';
import 'package:sakiengine/src/widgets/nvl_screen.dart';
import 'package:sakiengine/src/widgets/quick_menu.dart';
import 'package:sakiengine/src/widgets/mobile_quick_menu.dart'; // 新增：手机端快捷菜单
import 'package:sakiengine/src/widgets/mobile_touch_controller.dart';

@visibleForTesting
int? resolveMenuDialogueHistoryIndex({
  required int dialogueHistoryLength,
  required bool isMenuNode,
  required bool choiceMenuDisplaysLeadingDialogue,
}) {
  if (!isMenuNode || dialogueHistoryLength <= 0) {
    return null;
  }
  if (!choiceMenuDisplaysLeadingDialogue) {
    return dialogueHistoryLength - 1;
  }
  if (dialogueHistoryLength < 2) {
    return null;
  }
  return dialogueHistoryLength - 2;
}

/// 游戏UI层组件
/// 包含所有游戏中的UI元素，支持右键隐藏
class GameUILayer extends StatefulWidget {
  final GameState gameState;
  final GameManager gameManager;
  final GameModule gameModule;
  final DialogueProgressionManager dialogueProgressionManager;
  final String currentScript;
  final GlobalKey nvlScreenKey;

  // 状态管理
  final bool showReviewOverlay;
  final bool enableReviewOverscrollClose;
  final bool showSaveOverlay;
  final bool showLoadOverlay;
  final bool showSettings;
  final bool showFlowchart; // 新增：流程图显示状态
  final bool showDeveloperPanel;
  final bool showDebugPanel;
  final bool showExpressionSelector;
  final bool isShowingMenu;

  // 回调函数
  final void Function(bool triggeredByOverscroll) onToggleReview;
  final VoidCallback onToggleSave;
  final VoidCallback onToggleLoad;
  final VoidCallback? onQuickSave; // 新增：快速存档回调
  final VoidCallback onToggleSettings;
  final VoidCallback onToggleDeveloperPanel;
  final VoidCallback onToggleDebugPanel;
  final VoidCallback onToggleExpressionSelector;
  final VoidCallback onHandleQuickMenuBack;
  final VoidCallback onHandlePreviousDialogue;
  final VoidCallback? onSkipRead; // 新增：跳过已读文本回调
  final VoidCallback? onAutoPlay; // 新增：自动播放回调
  final VoidCallback? onThemeToggle; // 新增：主题切换回调
  final VoidCallback? onFlowchart; // 新增：流程图回调
  final Function(DialogueHistoryEntry) onJumpToHistoryEntry;
  final Function(SaveSlot)? onLoadGame;
  final VoidCallback onProgressDialogue;

  // 表情选择器管理器
  final ExpressionSelectorManager? expressionSelectorManager;

  // 对话框创建函数
  final Widget Function({
    Key? key,
    String? speaker,
    String? speakerAlias,
    String? dialogueTag,
    required String dialogue,
    required bool isFastForwarding,
    required int scriptIndex,
    VoidCallback? onToggleSettings,
    VoidCallback? onToggleReview,
  })
  createDialogueBox;

  const GameUILayer({
    super.key,
    required this.gameState,
    required this.gameManager,
    required this.gameModule,
    required this.dialogueProgressionManager,
    required this.currentScript,
    required this.nvlScreenKey,
    required this.showReviewOverlay,
    this.enableReviewOverscrollClose = false,
    required this.showSaveOverlay,
    required this.showLoadOverlay,
    required this.showSettings,
    required this.showFlowchart,
    required this.showDeveloperPanel,
    required this.showDebugPanel,
    required this.showExpressionSelector,
    required this.isShowingMenu,
    required this.onToggleReview,
    required this.onToggleSave,
    required this.onToggleLoad,
    this.onQuickSave, // 新增：快速存档回调（可选）
    required this.onToggleSettings,
    required this.onToggleDeveloperPanel,
    required this.onToggleDebugPanel,
    required this.onToggleExpressionSelector,
    required this.onHandleQuickMenuBack,
    required this.onHandlePreviousDialogue,
    this.onSkipRead, // 新增：跳过已读文本回调（可选）
    this.onAutoPlay, // 新增：自动播放回调（可选）
    this.onThemeToggle, // 新增：主题切换回调（可选）
    this.onFlowchart, // 新增：流程图回调（可选）
    required this.onJumpToHistoryEntry,
    required this.onLoadGame,
    required this.onProgressDialogue,
    required this.expressionSelectorManager,
    required this.createDialogueBox,
  });

  @override
  State<GameUILayer> createState() => GameUILayerState();
}

class GameUILayerState extends State<GameUILayer> {
  final _notificationOverlayKey = GlobalKey<NotificationOverlayState>();
  bool _isChoiceSelectionPending = false;

  /// 检查是否有弹窗显示或正在播放视频
  bool get _hasOverlayOpen {
    return widget.isShowingMenu ||
        widget.showSaveOverlay ||
        widget.showLoadOverlay ||
        widget.showReviewOverlay ||
        widget.showSettings ||
        widget.showDeveloperPanel ||
        widget.showDebugPanel ||
        widget.showExpressionSelector ||
        // 轮盘由外层 GamePlayScreen 控制并阻断输入，UI层无需额外状态字段。
        widget.gameState.movieFile != null ||
        (widget.gameState.scriptCanvasId != null &&
            widget.gameState.scriptCanvasDurationSeconds > 0);
  }

  @override
  void didUpdateWidget(covariant GameUILayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentNode = widget.gameState.currentNode;
    if (currentNode is! MenuNode ||
        currentNode != oldWidget.gameState.currentNode) {
      _isChoiceSelectionPending = false;
    }
  }

  void _handleChoiceSelected(String targetLabel) {
    if (_isChoiceSelectionPending) {
      return;
    }

    setState(() {
      _isChoiceSelectionPending = true;
    });

    unawaited(
      widget.gameManager.jumpToLabel(targetLabel).whenComplete(() {
        if (!mounted || widget.gameState.currentNode is! MenuNode) {
          return;
        }
        setState(() {
          _isChoiceSelectionPending = false;
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    final uiScale = context.scaleFor(ComponentType.menu);
    final mediaPadding = MediaQuery.of(context).padding;
    final shouldShowQuickMenu =
        widget.gameModule.showQuickMenu &&
        widget.gameState.movieFile == null &&
        !(widget.gameState.scriptCanvasId != null &&
            widget.gameState.scriptCanvasDurationSeconds > 0) &&
        !widget.gameManager.isCurrentSceneChapter;
    final quickMenuAreaWidth = shouldShowQuickMenu
        ? 100.0 * uiScale + (isMobile ? mediaPadding.left : 0.0)
        : 0.0;
    final dialogueHistory = widget.gameManager.getDialogueHistory();
    final isMenuNode =
        widget.gameState.currentNode is MenuNode && !_isChoiceSelectionPending;
    final latestDialogueEntry = dialogueHistory.isNotEmpty
        ? dialogueHistory.last
        : null;
    final choiceMenuDisplaysLeadingDialogue =
        isMenuNode && widget.gameModule.choiceMenuDisplaysLeadingDialogue;
    final menuDialogueHistoryIndex = resolveMenuDialogueHistoryIndex(
      dialogueHistoryLength: dialogueHistory.length,
      isMenuNode: isMenuNode,
      choiceMenuDisplaysLeadingDialogue: choiceMenuDisplaysLeadingDialogue,
    );
    final menuDialogueEntry = menuDialogueHistoryIndex == null
        ? null
        : dialogueHistory[menuDialogueHistoryIndex];
    final leadingDialogueBeforeMenu = choiceMenuDisplaysLeadingDialogue
        ? latestDialogueEntry?.dialogue
        : null;
    final dialogueForDialogueBox =
        menuDialogueEntry?.dialogue ?? widget.gameState.dialogue;
    final speakerForDialogueBox =
        menuDialogueEntry?.speaker ?? widget.gameState.speaker;
    final dialogueTagForDialogueBox =
        menuDialogueEntry?.dialogueTag ?? widget.gameState.dialogueTag;
    final speakerAliasForDialogueBox = widget.gameState.speakerAlias;
    final scriptIndexForDialogueBox =
        menuDialogueEntry?.scriptIndex ??
        latestDialogueEntry?.scriptIndex ??
        widget.gameManager.currentScriptIndex;
    final shouldShowNormalDialogue =
        dialogueForDialogueBox != null && !widget.gameState.isNvlMode;
    final enableDialogueSwitcherAnimation =
        widget.gameModule.enableDialogueSwitcherAnimation &&
        !widget.gameState.isFastForwarding;
    final enableDialogueSwitcherSlideAnimation =
        enableDialogueSwitcherAnimation &&
        widget.gameModule.enableDialogueSwitcherSlideAnimation;
    final customStatusIndicatorLayer = widget.gameModule
        .createStatusIndicatorLayer(
          context: context,
          gameState: widget.gameState,
          gameManager: widget.gameManager,
        );

    final stackContent = Stack(
      children: [
        // 对话框 - 使用 AnimatedSwitcher 为对话框切换添加过渡动画
        HideableUI(
          child: AnimatedSwitcher(
            duration: enableDialogueSwitcherAnimation
                ? const Duration(milliseconds: 300)
                : Duration.zero,
            transitionBuilder: (Widget child, Animation<double> animation) {
              // 关闭切换动画时直接显示
              if (!enableDialogueSwitcherAnimation) {
                return child;
              }

              if (!enableDialogueSwitcherSlideAnimation) {
                return FadeTransition(opacity: animation, child: child);
              }

              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, 0.1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOut,
                        ),
                      ),
                  child: child,
                ),
              );
            },
            child: shouldShowNormalDialogue
                ? widget.createDialogueBox(
                    key: const ValueKey('normal_dialogue'),
                    speaker: speakerForDialogueBox,
                    speakerAlias: speakerAliasForDialogueBox, // 传递角色简写
                    dialogueTag: dialogueTagForDialogueBox,
                    dialogue: dialogueForDialogueBox!,
                    isFastForwarding:
                        widget.gameState.isFastForwarding, // 传递快进状态
                    scriptIndex: scriptIndexForDialogueBox, // 传递脚本索引
                    onToggleSettings: () {
                      if (!widget.showSettings) {
                        widget.onToggleSettings();
                      }
                    },
                    onToggleReview: () {
                      if (!widget.showReviewOverlay) {
                        widget.onToggleReview(false);
                      }
                    },
                  )
                : const SizedBox.shrink(key: ValueKey('no_dialogue')),
          ),
        ),

        // 选择菜单
        if (isMenuNode)
          HideableUI(
            child: widget.gameModule.createChoiceMenu(
              key: const ValueKey('choice_menu'),
              menuNode: widget.gameState.currentNode as MenuNode,
              onChoiceSelected: _handleChoiceSelected,
              isFastForwarding: widget.gameState.isFastForwarding, // 传递快进状态
              leadingDialogue: leadingDialogueBeforeMenu,
            ),
          ),

        // NVL 模式覆盖层 - 使用 AnimatedSwitcher 添加过渡动画
        HideableUI(
          child: AnimatedSwitcher(
            duration: widget.gameState.isFastForwarding
                ? Duration
                      .zero // 快进模式下跳过动画
                : const Duration(milliseconds: 400),
            transitionBuilder: (Widget child, Animation<double> animation) {
              // 快进模式下跳过淡入淡出动画，直接显示
              if (widget.gameState.isFastForwarding) {
                return child;
              }

              return FadeTransition(opacity: animation, child: child);
            },
            child: widget.gameState.isNvlOverlayVisible
                ? NvlScreen(
                    key: widget.nvlScreenKey,
                    nvlDialogues: widget.gameState.nvlDialogues,
                    isMovieMode: widget.gameState.isNvlMovieMode,
                    progressionManager: widget.dialogueProgressionManager,
                    isFastForwarding:
                        widget.gameState.isFastForwarding, // 传递快进状态
                    isNoMask: widget.gameState.isNvlnMode, // 新增：传递无遮罩状态
                  )
                : const SizedBox.shrink(key: ValueKey('no_nvl')),
          ),
        ),

        // 快捷菜单 - 在播放视频或章节场景时隐藏
        // 手机端使用 MobileQuickMenu，桌面端使用 QuickMenu
        if (shouldShowQuickMenu)
          isMobile
              ? Positioned(
                  left: 10 * uiScale + mediaPadding.left, // 左边距 + 刘海安全区
                  top:
                      (MediaQuery.of(context).size.height -
                          MediaQuery.of(context).size.height * 0.9) /
                      2, // 垂直居中
                  child: HideableUI(
                    child: MobileQuickMenu(
                      onSave: widget.onToggleSave,
                      onLoad: widget.onToggleLoad,
                      onQuickSave: widget.onQuickSave, // 新增：传递快速存档回调
                      onReview: () => widget.onToggleReview(false),
                      onSettings: widget.onToggleSettings,
                      onBack: widget.onHandleQuickMenuBack,
                      onPreviousDialogue: widget.onHandlePreviousDialogue,
                      onSkipRead: widget.onSkipRead, // 传递跳过已读文本回调
                      isFastForwarding:
                          widget.gameState.isFastForwarding, // 传递快进状态
                      onAutoPlay: widget.onAutoPlay, // 传递自动播放回调
                      isAutoPlaying: widget.gameState.isAutoPlaying, // 传递自动播放状态
                      onThemeToggle: widget.onThemeToggle, // 传递主题切换回调
                    ),
                  ),
                )
              : HideableUI(
                  child: QuickMenu(
                    onSave: widget.onToggleSave,
                    onLoad: widget.onToggleLoad,
                    onQuickSave: widget.onQuickSave, // 新增：传递快速存档回调
                    onReview: () => widget.onToggleReview(false),
                    onSettings: widget.onToggleSettings,
                    onBack: widget.onHandleQuickMenuBack,
                    onPreviousDialogue: widget.onHandlePreviousDialogue,
                    onSkipRead: widget.onSkipRead, // 传递跳过已读文本回调
                    isFastForwarding:
                        widget.gameState.isFastForwarding, // 传递快进状态
                    onAutoPlay: widget.onAutoPlay, // 传递自动播放回调
                    isAutoPlaying: widget.gameState.isAutoPlaying, // 传递自动播放状态
                    onThemeToggle: widget.onThemeToggle, // 传递主题切换回调
                    onFlowchart: widget.onFlowchart, // 传递流程图回调
                  ),
                ),

        // 快进指示器 - 顶部显示
        if (widget.gameModule.showDefaultStatusIndicators &&
            widget.gameState.isFastForwarding)
          Positioned(
            left: 100 * context.scaleFor(ComponentType.menu),
            top: 20 * context.scaleFor(ComponentType.menu),
            child: HideableUI(
              child: CommonIndicator(
                isVisible: widget.gameState.isFastForwarding,
                icon: Icons.fast_forward_rounded, // 使用圆滑的图标
                text: LocalizationManager().t('indicator.fastForwarding'),
              ),
            ),
          ),

        // 自动播放指示器 - 顶部显示
        if (widget.gameModule.showDefaultStatusIndicators &&
            widget.gameState.isAutoPlaying)
          Positioned(
            left: 100 * context.scaleFor(ComponentType.menu),
            top: 20 * context.scaleFor(ComponentType.menu),
            child: HideableUI(
              child: CommonIndicator(
                isVisible: widget.gameState.isAutoPlaying,
                icon: Icons.play_arrow_rounded, // 使用圆滑的图标
                text: LocalizationManager().t('indicator.autoPlaying'),
              ),
            ),
          ),

        if (customStatusIndicatorLayer != null)
          Positioned.fill(child: HideableUI(child: customStatusIndicatorLayer)),

        // 回顾界面
        if (widget.showReviewOverlay)
          HideableUI(
            child: widget.gameModule.createReviewOverlay(
              dialogueHistory: widget.gameManager.getDialogueHistory(),
              onClose: (triggeredByOverscroll) =>
                  widget.onToggleReview(triggeredByOverscroll),
              onJumpToEntry: widget.onJumpToHistoryEntry,
              enableBottomScrollClose: widget.enableReviewOverscrollClose,
            ),
          ),

        // 存档界面
        if (widget.showSaveOverlay)
          HideableUI(
            child: widget.gameModule.createSaveLoadScreen(
              mode: SaveLoadMode.save,
              gameManager: widget.gameManager,
              onClose: widget.onToggleSave,
              onLoadSlot:
                  widget.onLoadGame ??
                  (saveSlot) {
                    // 如果没有回调，使用传统的导航方式（兼容性）
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (context) =>
                            GamePlayScreen(saveSlotToLoad: saveSlot),
                      ),
                      (route) => false,
                    );
                  },
            ),
          ),

        // 读档界面
        if (widget.showLoadOverlay)
          HideableUI(
            child: widget.gameModule.createSaveLoadScreen(
              mode: SaveLoadMode.load,
              gameManager: widget.gameManager,
              onClose: widget.onToggleLoad,
              onLoadSlot:
                  widget.onLoadGame ??
                  (saveSlot) {
                    // 如果没有回调，使用传统的导航方式（兼容性）
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (context) =>
                            GamePlayScreen(saveSlotToLoad: saveSlot),
                      ),
                      (route) => false,
                    );
                  },
            ),
          ),

        // 设置界面
        if (widget.showSettings)
          HideableUI(
            child: widget.gameModule.createSettingsScreen(
              onClose: widget.onToggleSettings,
              gameManager: widget.gameManager,
              onLoadSlot:
                  widget.onLoadGame ??
                  (saveSlot) {
                    // 如果没有回调，使用传统的导航方式（兼容性）
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (context) =>
                            GamePlayScreen(saveSlotToLoad: saveSlot),
                      ),
                      (route) => false,
                    );
                  },
            ),
          ),

        // 流程图界面
        if (widget.showFlowchart)
          HideableUI(
            child: StoryFlowchartScreen(
              isInGame: true, // 游戏内调用，显示"进度将丢失"提示
              onClose: () {
                if (widget.onFlowchart != null) {
                  widget.onFlowchart!();
                }
              },
              onLoadSave: widget.onLoadGame, // onLoadGame 回调内部已经会关闭流程图
            ),
          ),

        // 开发者面板 (仅Debug模式)
        if (kEngineDebugMode && widget.showDeveloperPanel)
          HideableUI(
            child: DeveloperPanel(
              onClose: widget.onToggleDeveloperPanel,
              gameManager: widget.gameManager,
              onReload: () =>
                  widget.gameManager.hotReload(widget.currentScript),
            ),
          ),

        // 调试面板 (发行版也可用，方便玩家复制日志)
        if (widget.showDebugPanel)
          HideableUI(
            child: DebugPanelDialog(onClose: widget.onToggleDebugPanel),
          ),

        // 表情选择器 (仅Debug模式)
        if (kEngineDebugMode && widget.showExpressionSelector)
          HideableUI(
            child: Builder(
              builder: (context) {
                final speakerInfo = widget.expressionSelectorManager
                    ?.getCurrentSpeakerInfo();
                if (speakerInfo == null) {
                  return const SizedBox.shrink();
                }
                final dialogueContext =
                    widget.gameManager.currentDialogueContext;
                return ExpressionSelectorDialog(
                  characterId: speakerInfo.characterId,
                  characterName: speakerInfo.speakerName,
                  currentPose: speakerInfo.currentPose,
                  currentExpression: speakerInfo.currentExpression,
                  currentAnimation: speakerInfo.currentAnimation,
                  previousDialogue: dialogueContext?.previousDialogue,
                  currentDialogue:
                      dialogueContext?.currentDialogue ??
                      widget.gameManager.currentDialogueText,
                  nextDialogue: dialogueContext?.nextDialogue,
                  onSelectionChanged: (pose, expression, animation) {
                    widget.expressionSelectorManager
                        ?.handleExpressionSelectionChanged(
                          speakerInfo.characterId,
                          pose,
                          expression,
                          animation,
                        );
                  },
                  onClose: widget.onToggleExpressionSelector,
                );
              },
            ),
          ),

        // 通知覆盖层
        HideableUI(
          child: NotificationOverlay(
            key: _notificationOverlayKey,
            scale: context.scaleFor(ComponentType.ui),
          ),
        ),
      ],
    );

    // 移动端包装触屏控制器
    if (isMobile) {
      return MobileTouchController(
        quickMenuAreaWidth: quickMenuAreaWidth,
        hasOverlayOpen: _hasOverlayOpen, // 传递弹窗状态
        onLongPress: () {
          // 长按屏幕，切换UI显示/隐藏
          final globalManager = GlobalRightClickUIManager();
          globalManager.setUIHidden(!globalManager.isUIHidden);
        },
        onOtherAreaTap: widget.onProgressDialogue,
        child: stackContent,
      );
    }

    // 桌面端直接返回 Stack
    return stackContent;
  }

  /// 显示通知消息（公开给外部调用）
  void showNotification(String message) {
    _notificationOverlayKey.currentState?.show(message);
  }

  /// 显示通知消息（内部方法）
  void _showNotificationMessage(String message) {
    showNotification(message);
  }
}
