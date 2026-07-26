import 'dart:async';
import 'dart:ui' as ui;
import 'dart:io';

import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/config/config_models.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/game/save_load_manager.dart';
import 'package:sakiengine/src/game/screenshot_generator.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/screens/save_load_screen.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/widgets/choice_menu.dart';
import 'package:sakiengine/src/widgets/quick_menu.dart';
import 'package:sakiengine/src/widgets/smart_image.dart';
import 'package:sakiengine/src/screens/review_screen.dart';
import 'package:sakiengine/src/screens/main_menu_screen.dart';
import 'package:sakiengine/src/core/game_module.dart';
import 'package:sakiengine/src/widgets/common/exit_confirmation_dialog.dart';
import 'package:sakiengine/src/utils/game_flowchart_mixin.dart';
import 'package:sakiengine/src/rendering/cg_character_renderer.dart';
import 'package:sakiengine/src/rendering/composite_cg_renderer.dart';
import 'package:sakiengine/src/rendering/rendering_system_integration.dart';
import 'package:sakiengine/src/widgets/confirm_dialog.dart';
import 'package:sakiengine/src/widgets/common/notification_overlay.dart';
import 'package:sakiengine/src/widgets/nvl_screen.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/widgets/common/black_screen_transition.dart';
import 'package:sakiengine/src/widgets/settings_screen.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';
import 'package:sakiengine/src/utils/smart_asset_image.dart';
import 'package:sakiengine/src/rendering/color_background_renderer.dart';
import 'package:sakiengine/src/effects/scene_filter.dart';
import 'package:sakiengine/src/effects/mouse_parallax.dart';
import 'package:sakiengine/src/rendering/scene_layer.dart';
import 'package:sakiengine/src/utils/character_composite_cache.dart';
import 'package:sakiengine/src/utils/color_parser.dart';
import 'package:sakiengine/src/widgets/developer_panel.dart';
import 'package:sakiengine/src/utils/cg_image_compositor.dart';
import 'package:sakiengine/src/widgets/debug_panel_dialog.dart';
import 'package:sakiengine/src/utils/character_auto_distribution.dart';
import 'package:sakiengine/src/widgets/expression_selector_dialog.dart';
import 'package:sakiengine/src/widgets/expression_radial_wheel.dart';
import 'package:sakiengine/src/widgets/command_grid_menu.dart';
import 'package:sakiengine/src/widgets/command_radial_wheel.dart';
import 'package:sakiengine/src/widgets/floating_script_editor_overlay.dart';
import 'package:sakiengine/src/utils/expression_selector_manager.dart';
import 'package:sakiengine/src/utils/expression_offset_manager.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';
import 'package:sakiengine/src/widgets/common/right_click_ui_manager.dart';
import 'package:sakiengine/src/utils/mouse_wheel_handler.dart';
import 'package:sakiengine/src/widgets/common/game_ui_layer.dart';
import 'package:sakiengine/src/utils/fast_forward_manager.dart';
import 'package:sakiengine/src/utils/auto_play_manager.dart'; // 新增：自动播放管理器
import 'package:sakiengine/src/utils/read_text_tracker.dart';
import 'package:sakiengine/src/utils/read_text_skip_manager.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/effects/scene_transition_effects.dart';
import 'package:sakiengine/src/widgets/movie_player.dart'; // 新增：视频播放器导入
import 'package:sakiengine/src/utils/dialogue_shake_effect.dart'; // 新增：震动效果导入
import 'package:sakiengine/src/rendering/image_sampling.dart';
import 'package:sakiengine/src/utils/music_manager.dart';

part 'game_play_screen_interactions.dart';

typedef InitialLoadingOverlayBuilder = Widget Function(
  BuildContext context,
  bool readyToComplete,
  VoidCallback onCompleted,
);

typedef SaveLoadTransitionOverlayBuilder = Widget Function(
  BuildContext context,
  VoidCallback onCompleted,
);

enum _CommandDebugMenuMode {
  expression,
  character,
  background,
  music,
}

class GamePlayScreen extends StatefulWidget {
  final SaveSlot? saveSlotToLoad;
  final VoidCallback? onReturnToMenu;
  final Function(SaveSlot)? onLoadGame;
  final GameModule? gameModule;
  final InitialLoadingOverlayBuilder? initialLoadingOverlayBuilder;
  final String? initialLoadingCompletionTransitionType;
  final Duration initialLoadingCompletionTransitionDuration;
  final bool fadeOutInitialLoadingOverlayOnCompletion;
  final SaveLoadTransitionOverlayBuilder? saveLoadTransitionOverlayBuilder;

  const GamePlayScreen({
    super.key,
    this.saveSlotToLoad,
    this.onReturnToMenu,
    this.onLoadGame,
    this.gameModule,
    this.initialLoadingOverlayBuilder,
    this.initialLoadingCompletionTransitionType,
    this.initialLoadingCompletionTransitionDuration =
        const Duration(milliseconds: 900),
    this.fadeOutInitialLoadingOverlayOnCompletion = true,
    this.saveLoadTransitionOverlayBuilder,
  });

  @override
  State<GamePlayScreen> createState() => _GamePlayScreenState();
}

class _GamePlayScreenState extends State<GamePlayScreen>
    with TickerProviderStateMixin, GameFlowchartMixin {
  static const bool _fxDiagLogs = bool.fromEnvironment(
    'SAKI_FX_DIAG',
    defaultValue: true,
  );
  late final GameManager _gameManager;
  late final DialogueProgressionManager _dialogueProgressionManager;
  final _gameUILayerKey = GlobalKey<GameUILayerState>();
  final GlobalKey _saveThumbnailCaptureBoundaryKey = GlobalKey();
  final GlobalKey _sceneTransitionCaptureBoundaryKey = GlobalKey();
  String _currentScript = 'start';
  bool _showReviewOverlay = false;
  bool _showSaveOverlay = false;
  bool _showLoadOverlay = false;
  bool _showSettings = false;
  bool _showFlowchart = false; // 流程图显示状态
  bool _isShowingMenu = false;
  bool _showDeveloperPanel = false; // 开发者面板显示状态
  bool _showDebugPanel = false; // 调试面板显示状态
  bool _showExpressionSelector = false; // 表情选择器显示状态
  bool _showExpressionWheel = false; // 差分快捷轮盘显示状态（Debug）
  bool _showCharacterWheel = false; // 角色切换轮盘显示状态（Debug）
  bool _showBackgroundGridMenu = false; // 背景选择网格菜单显示状态（Debug）
  bool _showMusicGridMenu = false; // 音乐选择网格菜单显示状态（Debug）
  bool _showFloatingScriptEditor = false; // 悬浮脚本编辑器显示状态（Debug）
  bool _isMetaKeyPressed = false; // Command/Meta按键按住状态（Debug）
  _CommandDebugMenuMode? _activeCommandMenuMode;
  HotKey? _reloadHotKey;
  HotKey? _developerPanelHotKey; // Shift+D快捷键
  HotKey? _floatingScriptEditorHotKey; // Shift+P 快捷键
  KeySequenceDetector? _consoleSequenceDetector; // console序列检测器
  ExpressionSelectorManager? _expressionSelectorManager; // 表情选择器管理器
  FastForwardManager? _fastForwardManager; // 快进管理器
  AutoPlayManager? _autoPlayManager; // 新增：自动播放管理器
  ReadTextSkipManager? _readTextSkipManager; // 已读文本快进管理器
  late MouseWheelHandler _mouseWheelHandler; // 鼠标滚轮处理器
  final SettingsManager _settingsManager = SettingsManager();
  String _mouseRollbackBehavior = SettingsManager.defaultMouseRollbackBehavior;
  DateTime? _reviewReopenSuppressedUntil;
  bool _reviewOpenedByMouseRollback = false;
  final GlobalKey _nvlScreenKey = GlobalKey();
  bool _isParallaxEnabled = SettingsManager.defaultMouseParallaxEnabled;
  bool _isHiddenUiSceneTransformActive = false;
  Timer? _expressionWheelOpenTimer;
  SpeakerInfo? _expressionWheelSpeakerInfo;
  List<String> _expressionWheelExpressions = const [];
  Map<String, String> _expressionWheelImagePaths = const {};
  String? _expressionWheelHighlightedExpression;
  List<CommandWheelOption> _characterWheelOptions = const [];
  String? _characterWheelCurrentId;
  String? _characterWheelHighlightedId;
  String? _lastSceneFilterDiagSignature;
  List<CommandWheelOption> _backgroundGridOptions = const [];
  String? _backgroundGridCurrentId;
  String? _backgroundGridHighlightedId;
  List<CommandWheelOption> _musicGridOptions = const [];
  String? _musicGridCurrentId;
  String? _musicGridHighlightedId;
  String? _musicGridOriginalAssetPath;
  String? _musicPreviewPlayingId;
  Offset? _lastPointerPosition;
  Offset? _expressionWheelCenter;

  // 跟踪上一次的NVL状态，用于检测转场
  bool _previousIsNvlMode = false;
  bool _previousIsNvlMovieMode = false;

  // 快进状态
  bool _isFastForwarding = false;

  // 自动播放状态
  bool _isAutoPlaying = false;

  // 背景资源路径缓存，避免在build阶段频繁FutureBuilder查找资源
  final Map<String, String?> _backgroundPathCache = {};
  final Set<String> _backgroundPathResolving = <String>{};

  // 加载淡出动画控制
  late AnimationController _loadingFadeController;
  late Animation<double> _loadingFadeAnimation;
  bool _isInitialLoading = false;
  bool _initialLoadingReleaseScheduled = false;
  bool _initialLoadingReadyToComplete = false;
  bool _initialLoadingCompletionTransitionRunning = false;
  SaveSlot? _saveLoadTransitionSlot;
  Uint8List? _frozenSaveThumbnailFrame;

  bool get _isAnyCommandMenuOpen =>
      _showExpressionWheel ||
      _showCharacterWheel ||
      _showBackgroundGridMenu ||
      _showMusicGridMenu;

  bool get _hasThumbnailBlockingOverlayOpen {
    return _showSaveOverlay ||
        _showLoadOverlay ||
        _showReviewOverlay ||
        _showSettings ||
        _showFlowchart ||
        _showDeveloperPanel ||
        _showDebugPanel ||
        _showExpressionSelector ||
        _isAnyCommandMenuOpen;
  }

  Future<Uint8List?> _captureSaveThumbnailFromBoundary() async {
    try {
      final boundaryContext = _saveThumbnailCaptureBoundaryKey.currentContext;
      if (boundaryContext == null) {
        return null;
      }

      final renderObject = boundaryContext.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        return null;
      }

      var needsPaint = false;
      assert(() {
        needsPaint = renderObject.debugNeedsPaint;
        return true;
      }());
      if (needsPaint) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }

      final size = renderObject.size;
      if (size.width <= 0 || size.height <= 0) {
        return null;
      }

      final pixelRatio =
          (ScreenshotGenerator.targetWidth / size.width).clamp(0.5, 2.0);
      final image = await renderObject.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      if (kEngineDebugMode) {
        print('[GamePlayScreen] 捕获实时缩略图失败: $e');
      }
      return null;
    }
  }

  Future<Uint8List?> _captureCurrentGameFrameForSaveThumbnail() async {
    if (_hasThumbnailBlockingOverlayOpen) {
      // 存档可能从 Save/Load/Settings 三种覆盖层中触发（例如 Menhera 的设置页切 Tab 到 SAVE）。
      // 这三种场景都应复用“打开覆盖层前”冻结的游戏画面，确保缩略图包含游戏UI且不拍到菜单覆盖层。
      if (_showSaveOverlay || _showLoadOverlay || _showSettings) {
        return _frozenSaveThumbnailFrame;
      }
      return null;
    }

    final bytes = await _captureSaveThumbnailFromBoundary();
    if (bytes != null && bytes.isNotEmpty) {
      _frozenSaveThumbnailFrame = bytes;
    }
    return bytes;
  }

  Future<void> _toggleSaveOverlayForCapture() async {
    if (_showSaveOverlay) {
      _setStateIfMounted(() {
        _showSaveOverlay = false;
      });
      _frozenSaveThumbnailFrame = null;
      return;
    }

    // 每次打开存档面板前先清空旧冻结帧，避免捕获失败时误复用历史截图。
    _frozenSaveThumbnailFrame = null;
    final frozenFrame = await _captureSaveThumbnailFromBoundary();
    if (frozenFrame != null && frozenFrame.isNotEmpty) {
      _frozenSaveThumbnailFrame = frozenFrame;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _showSaveOverlay = true;
    });
  }

  Future<void> _toggleLoadOverlayForCapture() async {
    if (_showLoadOverlay) {
      _setStateIfMounted(() {
        _showLoadOverlay = false;
      });
      _frozenSaveThumbnailFrame = null;
      return;
    }

    _frozenSaveThumbnailFrame = null;
    final frozenFrame = await _captureSaveThumbnailFromBoundary();
    if (frozenFrame != null && frozenFrame.isNotEmpty) {
      _frozenSaveThumbnailFrame = frozenFrame;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _showLoadOverlay = true;
    });
  }

  Future<void> _toggleSettingsOverlayForCapture() async {
    if (_showSettings) {
      _setStateIfMounted(() {
        _showSettings = false;
      });
      _frozenSaveThumbnailFrame = null;
      return;
    }

    _frozenSaveThumbnailFrame = null;
    final frozenFrame = await _captureSaveThumbnailFromBoundary();
    if (frozenFrame != null && frozenFrame.isNotEmpty) {
      _frozenSaveThumbnailFrame = frozenFrame;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _showSettings = true;
    });
  }

  @override
  void initState() {
    super.initState();

    final configuredInitialScript =
        (widget.gameModule ?? DefaultGameModule()).initialScript.trim();
    _currentScript =
        configuredInitialScript.isEmpty ? 'start' : configuredInitialScript;

    _isInitialLoading = widget.initialLoadingOverlayBuilder != null;
    if (_isInitialLoading) {
      debugPrint('[GamePlayScreen] initial loading overlay enabled');
    }

    _settingsManager.addListener(_handleSettingsChanged);
    _loadMouseRollbackBehavior();

    // 初始化加载淡出动画
    _loadingFadeController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _loadingFadeAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _loadingFadeController, curve: Curves.easeOut),
    );

    _gameManager = GameManager(
      onReturn: _returnToMainMenu,
      onScriptApiExecute: ({
        required String apiName,
        required Map<String, String> params,
        required GameState gameState,
        required int scriptIndex,
      }) async {
        final module = widget.gameModule ?? DefaultGameModule();
        return module.handleScriptApiCall(
          apiName: apiName,
          params: params,
          gameState: gameState,
          scriptIndex: scriptIndex,
        );
      },
      defaultSceneTransitionType:
          (widget.gameModule ?? DefaultGameModule()).defaultSceneTransitionType,
    );
    ScreenshotGenerator.registerLiveGameViewCaptureProvider(
      owner: this,
      provider: _captureCurrentGameFrameForSaveThumbnail,
    );

    // 初始化对话推进管理器
    _dialogueProgressionManager = DialogueProgressionManager(
      gameManager: _gameManager,
      onManualProgress: () {
        _autoPlayManager?.onManualProgress();
      },
    );

    // 注册系统级热键 Shift+R
    _setupHotkey();

    // 初始化表情选择器管理器（仅在Debug模式下）
    if (kEngineDebugMode) {
      _setupExpressionSelectorManager();
    }

    // 初始化console序列检测器（发行版也可用，方便玩家复制日志）
    _setupConsoleSequenceDetector();

    // 初始化快进管理器
    _setupFastForwardManager();

    // 初始化自动播放管理器
    _setupAutoPlayManager();

    // 初始化已读文本跟踪器和已读文本快进管理器
    _setupReadTextTracking();

    // 初始化鼠标滚轮处理器
    _setupMouseWheelHandler();

    if (widget.saveSlotToLoad != null) {
      _currentScript = widget.saveSlotToLoad!.currentScript;
      //print('🎮 读取存档: currentScript = $_currentScript');
      //print('🎮 存档中的scriptIndex = ${widget.saveSlotToLoad!.snapshot.scriptIndex}');
      _gameManager.restoreFromSnapshot(
        _currentScript,
        widget.saveSlotToLoad!.snapshot,
        shouldReExecute: false,
      );

      // 延迟显示读档成功通知，确保UI已经构建完成
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNotificationMessage('读档成功');
        // 设置context用于转场效果
        _setGameManagerTransitionContext();
      });
    } else {
      _gameManager.startGame(_currentScript);
      // 延迟设置context，确保组件已mounted
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _setGameManagerTransitionContext();
      });
    }
  }

  void _setGameManagerTransitionContext() {
    if (!mounted) {
      return;
    }

    final transitionContext =
        _saveThumbnailCaptureBoundaryKey.currentContext ?? context;
    _gameManager.setContext(
      transitionContext,
      this as TickerProvider,
      _captureCurrentGameFrameForTransition,
    );
  }

  Future<ui.Image?> _captureCurrentGameFrameForTransition() async {
    try {
      final boundaryContext = _sceneTransitionCaptureBoundaryKey.currentContext;
      if (boundaryContext == null) {
        return null;
      }

      final renderObject = boundaryContext.findRenderObject();
      if (renderObject is! RenderRepaintBoundary) {
        return null;
      }

      var needsPaint = false;
      assert(() {
        needsPaint = renderObject.debugNeedsPaint;
        return true;
      }());
      if (needsPaint) {
        await WidgetsBinding.instance.endOfFrame;
      }

      final size = renderObject.size;
      if (size.width <= 0 || size.height <= 0) {
        return null;
      }

      final devicePixelRatio = View.of(context).devicePixelRatio;
      final pixelRatio = devicePixelRatio.clamp(0.75, 1.25).toDouble();
      return renderObject.toImage(pixelRatio: pixelRatio);
    } catch (e) {
      if (kEngineDebugMode) {
        print('[GamePlayScreen] 捕获转场帧失败: $e');
      }
      return null;
    }
  }

  void _setStateIfMounted(VoidCallback update) {
    if (!mounted) {
      return;
    }
    setState(update);
  }

  bool _hasVisibleStartupText(GameState gameState) {
    final hasNormalDialogue = !gameState.isNvlMode &&
        (gameState.dialogue?.trim().isNotEmpty ?? false);
    final hasNvlDialogue = gameState.isNvlMode &&
        gameState.nvlDialogues.any(
          (dialogue) => dialogue.dialogue.trim().isNotEmpty,
        );
    final hasMenuLeadingDialogue = gameState.currentNode is MenuNode &&
        _gameManager.getDialogueHistory().any(
              (entry) => entry.dialogue.trim().isNotEmpty,
            );
    final hasChoiceText = gameState.currentNode is MenuNode &&
        (gameState.currentNode as MenuNode).choices.any(
              (choice) => choice.text.trim().isNotEmpty,
            );
    final hasScriptOverlayText =
        gameState.scriptOverlayText?.trim().isNotEmpty ?? false;

    return hasNormalDialogue ||
        hasNvlDialogue ||
        hasMenuLeadingDialogue ||
        hasChoiceText ||
        hasScriptOverlayText;
  }

  Widget _buildStableInitialLoadingOverlay(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey('game_initial_loading_overlay'),
      child: _buildInitialLoadingOverlayLayer(context),
    );
  }

  void _scheduleInitialLoadingReleaseIfReady(GameState gameState) {
    if (widget.initialLoadingOverlayBuilder == null ||
        !_isInitialLoading ||
        _initialLoadingReleaseScheduled ||
        !_hasVisibleStartupText(gameState)) {
      return;
    }

    _initialLoadingReleaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isInitialLoading) {
        return;
      }

      final loadingBuilder = widget.initialLoadingOverlayBuilder;
      if (loadingBuilder == null) {
        _startInitialLoadingFadeOut();
        return;
      }

      setState(() {
        _initialLoadingReadyToComplete = true;
      });
    });
  }

  Widget _buildInitialLoadingOverlayLayer(BuildContext context) {
    final loadingBuilder = widget.initialLoadingOverlayBuilder;
    final overlayContent = loadingBuilder == null
        ? const ColoredBox(color: Colors.black)
        : loadingBuilder(
            context,
            _initialLoadingReadyToComplete,
            _handleInitialLoadingAnimationCompleted,
          );

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _loadingFadeAnimation,
        child: overlayContent,
        builder: (context, child) {
          final opacity = _loadingFadeAnimation.value;
          if (opacity <= 0.0) {
            return const SizedBox.shrink();
          }

          return AbsorbPointer(
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0).toDouble(),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void _handleInitialLoadingAnimationCompleted() {
    if (!mounted ||
        !_isInitialLoading ||
        _initialLoadingCompletionTransitionRunning) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isInitialLoading) {
        return;
      }
      _startInitialLoadingCompletion();
    });
  }

  void _startInitialLoadingCompletion() {
    final transitionType =
        widget.initialLoadingCompletionTransitionType?.trim();
    if (transitionType == null || transitionType.isEmpty) {
      if (widget.fadeOutInitialLoadingOverlayOnCompletion) {
        _startInitialLoadingFadeOut();
      } else {
        _completeInitialLoadingImmediately();
      }
      return;
    }
    _startInitialLoadingCompletionTransition(transitionType);
  }

  void _completeInitialLoadingImmediately() {
    if (!_isInitialLoading) {
      return;
    }

    _isInitialLoading = false;
    _loadingFadeController.value = 1.0;
  }

  Future<void> _startInitialLoadingCompletionTransition(
    String transitionType,
  ) async {
    if (_initialLoadingCompletionTransitionRunning) {
      return;
    }

    _initialLoadingCompletionTransitionRunning = true;
    try {
      if (SceneTransitionEffectManager.instance.isTransitioning) {
        _startInitialLoadingFadeOut();
        return;
      }
      await SceneTransitionEffectManager.instance.transition(
        context: context,
        transitionType:
            TransitionTypeParser.parseTransitionType(transitionType),
        duration: widget.initialLoadingCompletionTransitionDuration,
        captureFrame: _captureCurrentGameFrameForTransition,
        onMidTransition: () {
          _completeInitialLoadingImmediately();
        },
      );
    } finally {
      _initialLoadingCompletionTransitionRunning = false;
    }
  }

  void _startInitialLoadingFadeOut() {
    if (!_isInitialLoading) {
      return;
    }

    _isInitialLoading = false;
    _loadingFadeController.forward();
  }

  void _restoreFromSaveSlot(SaveSlot saveSlot) {
    _currentScript = saveSlot.currentScript;
    _gameManager.restoreFromSnapshot(
      saveSlot.currentScript,
      saveSlot.snapshot,
      shouldReExecute: false,
    );
    _showNotificationMessage('读档成功');
    _setStateIfMounted(() => _showFlowchart = false);
  }

  void _handleLoadGame(SaveSlot saveSlot) {
    if (widget.saveLoadTransitionOverlayBuilder == null) {
      _restoreFromSaveSlot(saveSlot);
      return;
    }
    if (_saveLoadTransitionSlot != null) {
      return;
    }
    setState(() {
      _saveLoadTransitionSlot = saveSlot;
    });
  }

  void _completeSaveLoadTransition() {
    final saveSlot = _saveLoadTransitionSlot;
    if (saveSlot == null) {
      return;
    }
    _restoreFromSaveSlot(saveSlot);
    _setStateIfMounted(() {
      _saveLoadTransitionSlot = null;
    });
  }

  Widget _buildSaveLoadTransitionOverlay(BuildContext context) {
    final builder = widget.saveLoadTransitionOverlayBuilder;
    if (_saveLoadTransitionSlot == null || builder == null) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: AbsorbPointer(
        child: KeyedSubtree(
          key: const ValueKey('game_save_load_transition_overlay'),
          child: builder(context, _completeSaveLoadTransition),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _settingsManager.removeListener(_handleSettingsChanged);

    // 取消注册系统热键（只在桌面平台）
    if (_isDesktopPlatform()) {
      if (_reloadHotKey != null) {
        hotKeyManager.unregister(_reloadHotKey!);
      }
      // 取消注册开发者面板热键
      if (_developerPanelHotKey != null) {
        hotKeyManager.unregister(_developerPanelHotKey!);
      }
      if (_floatingScriptEditorHotKey != null) {
        hotKeyManager.unregister(_floatingScriptEditorHotKey!);
      }
    }
    // 清理表情选择器管理器
    _expressionSelectorManager?.dispose();
    // 清理console序列检测器
    _consoleSequenceDetector?.dispose();
    // 清理快进管理器
    _fastForwardManager?.dispose();

    // 清理自动播放管理器
    _autoPlayManager?.dispose();

    // 清理已读文本快进管理器
    _readTextSkipManager?.dispose();
    _expressionWheelOpenTimer?.cancel();

    // 清理加载淡出动画控制器
    _loadingFadeController.dispose();

    _gameManager.dispose();
    ScreenshotGenerator.registerLiveGameViewCaptureProvider(
      owner: this,
      provider: null,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (signal) {
        if (signal is PointerScrollEvent) {
          _lastPointerPosition = signal.localPosition;
        }
        _mouseWheelHandler.handlePointerSignal(signal);
      },
      onPointerHover: (event) {
        _lastPointerPosition = event.localPosition;
      },
      onPointerDown: (event) {
        _lastPointerPosition = event.localPosition;
      },
      onPointerMove: (event) {
        _lastPointerPosition = event.localPosition;
      },
      onPointerPanZoomUpdate: (event) {
        _lastPointerPosition = event.localPosition;
        _mouseWheelHandler.handlePanZoomUpdate(event);
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, dynamic result) async {
          if (!didPop) {
            final shouldExit = await _onWillPop();
            if (shouldExit && mounted) {
              Navigator.of(context).pop();
            }
          }
        },
        child: Focus(
          autofocus: true, // 确保能接收键盘事件
          onKeyEvent: (node, event) {
            if (kEngineDebugMode && _handleExpressionWheelKeyEvent(event)) {
              return KeyEventResult.handled;
            }

            // 处理快进键盘事件
            if (_fastForwardManager != null) {
              final handled = _fastForwardManager!.handleKeyEvent(event);
              if (handled) {
                return KeyEventResult.handled;
              }
            }

            // 处理回车和空格键推进剧情
            if (event is KeyDownEvent) {
              final hasOverlayOpen = _isShowingMenu ||
                  _showSaveOverlay ||
                  _showLoadOverlay ||
                  _showReviewOverlay ||
                  _showSettings ||
                  _showDeveloperPanel ||
                  _showDebugPanel ||
                  _showExpressionSelector ||
                  _isAnyCommandMenuOpen;
              // 选项界面允许“回滚->观看记录”，但仍视为推进输入的阻断态。
              final hasOverlayOpenExceptMenu = _showSaveOverlay ||
                  _showLoadOverlay ||
                  _showReviewOverlay ||
                  _showSettings ||
                  _showDeveloperPanel ||
                  _showDebugPanel ||
                  _showExpressionSelector ||
                  _isAnyCommandMenuOpen;

              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                if (!hasOverlayOpen &&
                    _gameManager.currentState.movieFile == null) {
                  _dialogueProgressionManager.progressDialogue();
                  _autoPlayManager?.onManualProgress();
                }
                return hasOverlayOpen
                    ? KeyEventResult.ignored
                    : KeyEventResult.handled;
              }

              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                if (!hasOverlayOpenExceptMenu &&
                    _gameManager.currentState.movieFile == null) {
                  unawaited(_handleMouseRollbackAction());
                }
                return hasOverlayOpenExceptMenu
                    ? KeyEventResult.ignored
                    : KeyEventResult.handled;
              }

              if (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space) {
                // 检查是否正在播放视频，如果是则不推进剧情
                if (!hasOverlayOpen &&
                    _gameManager.currentState.movieFile == null) {
                  _dialogueProgressionManager.progressDialogue();
                  // 通知自动播放管理器有手动推进
                  _autoPlayManager?.onManualProgress();
                }
                return hasOverlayOpen
                    ? KeyEventResult.ignored
                    : KeyEventResult.handled;
              }
            }

            return KeyEventResult.ignored;
          },
          child: Scaffold(
            backgroundColor: Colors.black, // 添加黑色背景，这样震动时露出的就是黑色
            body: Stack(
              fit: StackFit.expand,
              children: [
                StreamBuilder<GameState>(
                  stream: _gameManager.gameStateStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      final module = widget.gameModule ?? DefaultGameModule();
                      final fallbackSceneBaseLayer =
                          module.createSceneBaseLayer(
                        context: context,
                        gameState: GameState.initial(),
                      );
                      return fallbackSceneBaseLayer ??
                          const ColoredBox(color: Colors.black);
                    }
                    final gameState = snapshot.data!;
                    final gameModule = widget.gameModule ?? DefaultGameModule();

                    _scheduleInitialLoadingReleaseIfReady(gameState);

                    // 检测从电影模式退出，播放退出动画
                    if (_previousIsNvlMode &&
                        _previousIsNvlMovieMode &&
                        (!gameState.isNvlMode || !gameState.isNvlMovieMode)) {
                      // 即将从电影模式退出，播放黑边退出动画
                      final state =
                          _nvlScreenKey.currentState as NvlScreenController?;
                      state?.playMovieModeExitAnimation();
                    }

                    // 更新状态跟踪
                    _previousIsNvlMode = gameState.isNvlMode;
                    _previousIsNvlMovieMode = gameState.isNvlMovieMode;

                    // 同步快进状态：如果GameManager停止了快进，同步到FastForwardManager和UI
                    if (_isFastForwarding && !gameState.isFastForwarding) {
                      // 使用post frame callback延迟处理，避免在build中调用setState
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          // 只需要停止FastForwardManager，不需要再次调用forceStopFastForward
                          // 因为GameManager已经处理了状态更新
                          _fastForwardManager?.stopFastForward();
                          setState(() {
                            _isFastForwarding = false;
                          });
                        }
                      });
                    }

                    // 更新选项显示状态（仅在状态变化时调度）
                    final newIsShowingMenu = gameState.currentNode is MenuNode;
                    if (_isShowingMenu != newIsShowingMenu) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted || _isShowingMenu == newIsShowingMenu) {
                          return;
                        }
                        if (!_isShowingMenu && newIsShowingMenu) {
                          // 选择菜单出现，强制停止自动播放
                          _autoPlayManager?.forceStopOnBlocking();
                        }
                        setState(() {
                          _isShowingMenu = newIsShowingMenu;
                        });
                      });
                    }

                    return MouseParallax(
                      maxOffset: const Offset(26, 16),
                      enabled: _isParallaxEnabled &&
                          !_isHiddenUiSceneTransformActive,
                      child: RepaintBoundary(
                        key: _saveThumbnailCaptureBoundaryKey,
                        child: Stack(
                          children: [
                            RightClickUIManager(
                              // 背景层 - 不会被隐藏的内容（场景、角色等）
                              backgroundChild: RepaintBoundary(
                                key: _sceneTransitionCaptureBoundaryKey,
                                child: _buildSceneWithFilter(gameState),
                              ),
                              enableHiddenUiSceneZoom:
                                  gameModule.enableHiddenUiSceneZoom,
                              hiddenUiSceneMaxZoom:
                                  gameModule.hiddenUiSceneMaxZoom,
                              onHiddenUiSceneTransformChanged: (isActive) {
                                if (!mounted ||
                                    _isHiddenUiSceneTransformActive ==
                                        isActive) {
                                  return;
                                }
                                setState(() {
                                  _isHiddenUiSceneTransformActive = isActive;
                                });
                              },
                              // 左键点击回调 - 推进剧情
                              onLeftClick: () {
                                // 检查是否有弹窗或菜单显示
                                final hasOverlayOpen = _isShowingMenu ||
                                    _showSaveOverlay ||
                                    _showLoadOverlay ||
                                    _showReviewOverlay ||
                                    _showSettings ||
                                    _showDeveloperPanel ||
                                    _showDebugPanel ||
                                    _showExpressionSelector ||
                                    _isAnyCommandMenuOpen;

                                // 检查是否正在播放视频
                                final isPlayingMovie =
                                    gameState.movieFile != null;

                                // 只有在没有弹窗且没有播放视频时才推进剧情
                                if (!hasOverlayOpen && !isPlayingMovie) {
                                  _dialogueProgressionManager
                                      .progressDialogue();
                                  // 通知自动播放管理器有手动推进
                                  _autoPlayManager?.onManualProgress();
                                }
                              },
                              // UI层 - 使用GameUILayer组件
                              child: Stack(
                                children: [
                                  GameUILayer(
                                    key: _gameUILayerKey,
                                    gameState: gameState,
                                    gameManager: _gameManager,
                                    gameModule: gameModule,
                                    dialogueProgressionManager:
                                        _dialogueProgressionManager,
                                    currentScript: _currentScript,
                                    nvlScreenKey: _nvlScreenKey,
                                    showReviewOverlay: _showReviewOverlay,
                                    enableReviewOverscrollClose:
                                        _mouseRollbackBehavior == 'history' &&
                                            _reviewOpenedByMouseRollback,
                                    showSaveOverlay: _showSaveOverlay,
                                    showLoadOverlay: _showLoadOverlay,
                                    showSettings: _showSettings,
                                    showFlowchart: _showFlowchart,
                                    showDeveloperPanel: _showDeveloperPanel,
                                    showDebugPanel: _showDebugPanel,
                                    showExpressionSelector:
                                        _showExpressionSelector,
                                    isShowingMenu: _isShowingMenu,
                                    onToggleReview: _toggleReviewOverlay,
                                    onToggleSave: _toggleSaveOverlayForCapture,
                                    onToggleLoad: () {
                                      _toggleLoadOverlayForCapture();
                                    },
                                    onQuickSave: _handleQuickSave, // 新增：快速存档回调
                                    onToggleSettings: () {
                                      _toggleSettingsOverlayForCapture();
                                    },
                                    onToggleDeveloperPanel: () => setState(
                                      () => _showDeveloperPanel =
                                          !_showDeveloperPanel,
                                    ),
                                    onToggleDebugPanel: () => setState(
                                      () => _showDebugPanel = !_showDebugPanel,
                                    ),
                                    onToggleExpressionSelector: () => setState(
                                      () => _showExpressionSelector =
                                          !_showExpressionSelector,
                                    ),
                                    onHandleQuickMenuBack: _handleQuickMenuBack,
                                    onHandlePreviousDialogue:
                                        _handlePreviousDialogue,
                                    onSkipRead:
                                        _handleSkipReadText, // 新增：跳过已读文本回调
                                    onAutoPlay: _handleAutoPlay, // 新增：自动播放回调
                                    onThemeToggle: () => setState(
                                        () {}), // 新增：主题切换回调 - 触发重建以更新UI
                                    onFlowchart: () => setState(
                                      () => _showFlowchart = !_showFlowchart,
                                    ), // 新增：流程图回调
                                    onJumpToHistoryEntry: _jumpToHistoryEntry,
                                    onLoadGame: _handleLoadGame,
                                    onProgressDialogue: () =>
                                        _dialogueProgressionManager
                                            .progressDialogue(),
                                    expressionSelectorManager:
                                        _expressionSelectorManager,
                                    createDialogueBox: _createDialogueBox,
                                  ),
                                  if (kEngineDebugMode &&
                                      _showExpressionWheel &&
                                      _expressionWheelSpeakerInfo != null &&
                                      _expressionWheelExpressions.isNotEmpty)
                                    ExpressionRadialWheel(
                                      characterName:
                                          _expressionWheelSpeakerInfo!
                                              .speakerName,
                                      currentExpression:
                                          _expressionWheelSpeakerInfo!
                                              .currentExpression,
                                      expressions: _expressionWheelExpressions,
                                      expressionImagePaths:
                                          _expressionWheelImagePaths,
                                      center: _expressionWheelCenter ??
                                          Offset(
                                            MediaQuery.of(context).size.width /
                                                2,
                                            MediaQuery.of(context).size.height /
                                                2,
                                          ),
                                      onHighlightedExpressionChanged:
                                          (expression) {
                                        _expressionWheelHighlightedExpression =
                                            expression;
                                      },
                                    ),
                                  if (kEngineDebugMode &&
                                      _showCharacterWheel &&
                                      _characterWheelOptions.isNotEmpty)
                                    CommandRadialWheel(
                                      title: '切换角色',
                                      options: _characterWheelOptions,
                                      currentOptionId: _characterWheelCurrentId,
                                      center: _expressionWheelCenter ??
                                          Offset(
                                            MediaQuery.of(context).size.width /
                                                2,
                                            MediaQuery.of(context).size.height /
                                                2,
                                          ),
                                      onHighlightedOptionChanged: (optionId) {
                                        _characterWheelHighlightedId = optionId;
                                      },
                                    ),
                                  if (kEngineDebugMode &&
                                      _showBackgroundGridMenu &&
                                      _backgroundGridOptions.isNotEmpty)
                                    CommandGridMenu(
                                      title: '切换背景',
                                      applyHint: 'Double Click To Apply',
                                      options: _backgroundGridOptions,
                                      currentOptionId: _backgroundGridCurrentId,
                                      center: _expressionWheelCenter ??
                                          Offset(
                                            MediaQuery.of(context).size.width /
                                                2,
                                            MediaQuery.of(context).size.height /
                                                2,
                                          ),
                                      onHighlightedOptionChanged: (optionId) {
                                        _backgroundGridHighlightedId = optionId;
                                      },
                                      onOptionDoubleTap: (_) {
                                        unawaited(
                                            _applyBackgroundGridSelectionAndClose());
                                      },
                                    ),
                                  if (kEngineDebugMode &&
                                      _showMusicGridMenu &&
                                      _musicGridOptions.isNotEmpty)
                                    CommandGridMenu(
                                      title: '切换音乐',
                                      applyHint: 'Double Click To Apply',
                                      options: _musicGridOptions,
                                      currentOptionId: _musicGridCurrentId,
                                      center: _expressionWheelCenter ??
                                          Offset(
                                            MediaQuery.of(context).size.width /
                                                2,
                                            MediaQuery.of(context).size.height /
                                                2,
                                          ),
                                      onHighlightedOptionChanged: (optionId) {
                                        _musicGridHighlightedId = optionId;
                                        unawaited(
                                          _previewMusicSelectionIfNeeded(
                                              optionId),
                                        );
                                      },
                                      onOptionDoubleTap: (_) {
                                        unawaited(
                                            _applyMusicGridSelectionAndClose());
                                      },
                                    ),
                                  if (kEngineDebugMode &&
                                      _showFloatingScriptEditor)
                                    FloatingScriptEditorOverlay(
                                      gameManager: _gameManager,
                                      currentScript: _currentScript,
                                      onReload: _handleHotReload,
                                      onNotify: _showNotificationMessage,
                                      onClose: () => _setStateIfMounted(
                                        () => _showFloatingScriptEditor = false,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            // 全局 scene filter 覆盖层：当模块禁用默认背景时启用，
                            // 覆盖 UI + 背景，作为全屏后处理。
                            if (gameState.sceneFilter != null &&
                                !gameModule.shouldRenderDefaultSceneBackground(
                                    gameState))
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: _FilteredBackground(
                                    filter: gameState.sceneFilter!,
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                // 加载覆盖层固定在 StreamBuilder 外，避免脚本首帧到达时重建进度动画。
                if (widget.initialLoadingOverlayBuilder != null)
                  _buildStableInitialLoadingOverlay(context),
                _buildSaveLoadTransitionOverlay(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 淡出动画完成后移除角色
  void _removeCharacterAfterFadeOut(String characterId) {
    _gameManager.removeCharacterAfterFadeOut(characterId);
  }

  Widget _buildSceneWithFilter(GameState gameState) {
    final module = widget.gameModule ?? DefaultGameModule();
    final customSceneBaseLayer = module.createSceneBaseLayer(
      context: context,
      gameState: gameState,
    );
    final sceneAttachmentLayer = module.createDialogueAttachment(
      context: context,
      gameState: gameState,
      scriptIndex: _gameManager.currentScriptIndex,
    );
    final sceneForegroundLayer = module.createSceneForegroundLayer(
      context: context,
      gameState: gameState,
      scriptIndex: _gameManager.currentScriptIndex,
    );
    final shouldRenderDefaultSceneBackground =
        module.shouldRenderDefaultSceneBackground(gameState);
    final characterLighting = module.resolveCharacterLighting(gameState);
    if (_fxDiagLogs) {
      final filter = gameState.sceneFilter;
      final signature =
          '${module.runtimeType}|$shouldRenderDefaultSceneBackground|${gameState.background}|'
          '${filter?.type}|${filter?.intensity}|${filter?.animation}|${filter?.duration}|'
          '${customSceneBaseLayer?.runtimeType}|${sceneAttachmentLayer?.runtimeType}';
      if (_lastSceneFilterDiagSignature != signature) {
        _lastSceneFilterDiagSignature = signature;
        debugPrint(
          '[FX_DIAG] Scene build '
          'module=${module.runtimeType} '
          'defaultBg=$shouldRenderDefaultSceneBackground '
          'background=${gameState.background} '
          'filter=${filter?.type}/${filter?.intensity}/${filter?.animation}/${filter?.duration} '
          'customBase=${customSceneBaseLayer?.runtimeType} '
          'attachment=${sceneAttachmentLayer?.runtimeType}',
        );
        if (filter != null && !shouldRenderDefaultSceneBackground) {
          debugPrint(
            '[FX_DIAG] Scene build note: default background is disabled; '
            'filter only works if custom scene layer applies it explicitly.',
          );
        }
      }
    }

    return SimpleShakeWrapper(
      trigger: gameState.isShaking &&
          (gameState.shakeTarget == 'background' ||
              gameState.shakeTarget == null),
      intensity: gameState.shakeIntensity ?? 8.0,
      duration: Duration(
        milliseconds: ((gameState.shakeDuration ?? 1.0) * 1000).round(),
      ),
      child: Stack(
        children: [
          // 模块自定义 scene 基础层（可选）
          if (customSceneBaseLayer != null) customSceneBaseLayer,

          // 引擎默认背景层（可由模块关闭）
          if (shouldRenderDefaultSceneBackground &&
              gameState.background != null)
            Builder(
              builder: (context) {
                //print('[GamePlayScreen] 正在渲染背景: ${gameState.background}');
                return _buildBackground(
                  gameState.background!,
                  gameState.sceneFilter,
                  gameState.sceneLayers,
                  gameState.sceneAnimationProperties,
                );
              },
            )
          else
            const SizedBox.shrink(),

          // scene 挂件层（位于背景之上、角色之下，避免遮挡角色）
          if (sceneAttachmentLayer != null) sceneAttachmentLayer,

          // 角色和CG层 - 只有在没有视频时才显示
          if (gameState.movieFile == null) ...[
            ..._buildCharacters(
              context,
              gameState.characters,
              _gameManager.poseConfigs,
              gameState.everShownCharacters,
              characterLighting,
            ),
            // CG角色渲染，使用新的层叠渲染系统
            // 支持在预合成和层叠渲染间智能切换，优化快进性能
            ...RenderingSystemManager()
                .buildCgCharacters(
                  context,
                  gameState.cgCharacters,
                  _gameManager,
                )
                .map((widget) => _wrapWithParallax(widget, 0.55)),
          ],

          // 视频播放器 - 最高优先级，如果有视频则覆盖在背景之上
          if (gameState.movieFile != null)
            Positioned.fill(
              child: _buildMoviePlayer(
                gameState.movieFile!,
                gameState.movieRepeatCount,
              ),
            )
          else
            // 当没有视频时，放置一个透明容器确保视频层被清除
            Positioned.fill(
              child: const ColoredBox(
                color: Colors.transparent,
                // 添加key确保每次状态变化时重建
                key: ValueKey('no_movie'),
              ),
            ),

          // anime覆盖层 - 最顶层
          if (gameState.animeOverlay != null)
            _buildAnimeOverlay(
              gameState.animeOverlay!,
              gameState.animeLoop,
              keep: gameState.animeKeep,
            ),

          // scene 前景层（位于场景元素之上，UI层之下）
          if (sceneForegroundLayer != null) sceneForegroundLayer,
        ],
      ),
    );
  }

  /// 构建视频播放器
  Widget _buildMoviePlayer(String movieFile, int? repeatCount) {
    return MoviePlayer(
      key: ValueKey(
        '$movieFile-$repeatCount',
      ), // 添加key确保视频切换时正确重建组件，包含repeatCount确保参数变化时重建
      movieFile: movieFile,
      repeatCount: repeatCount, // 新增：传递重复播放次数
      autoPlay: true,
      looping: false,
      onVideoEnd: () {
        // 视频播放结束，继续执行脚本（不使用next()，直接调用内部方法）
        _gameManager.executeScriptAfterMovie();
      },
    );
  }

  /// 构建anime覆盖层 - 全屏显示，支持WebP动图播放
  Widget _buildAnimeOverlay(String animeName, bool loop, {bool keep = false}) {
    return Positioned.fill(
      child: SmartAssetImage(
        assetName: animeName,
        fit: BoxFit.cover, // 和scene一样，贴满屏幕
        loop: loop, // 传递loop参数
        onAnimationComplete: !loop && !keep
            ? () {
                // 非循环且非keep模式下，动画完成后清除覆盖层
                _clearAnimeOverlay();
              }
            : null,
        errorWidget: Container(
          color: Colors.transparent,
          child: Center(
            child: Text(
              'Anime not found: $animeName',
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ),
      ),
    );
  }

  /// 清除anime覆盖层
  void _clearAnimeOverlay() {
    // 通过GameManager清除anime覆盖层
    _gameManager.clearAnimeOverlay();
  }

  /// 构建背景Widget - 支持图片背景和十六进制颜色背景，以及多图层场景和动画
  Widget _buildBackground(
    String background, [
    SceneFilter? sceneFilter,
    List<String>? sceneLayers,
    Map<String, double>? animationProperties,
  ]) {
    ////print('[_buildBackground] 开始构建背景: $background');
    Widget backgroundWidget;

    // 如果有多图层数据，使用多图层渲染器
    if (sceneLayers != null && sceneLayers.isNotEmpty) {
      ////print('[_buildBackground] 使用多图层渲染器');
      final layers = sceneLayers
          .map((layerString) => SceneLayer.fromString(layerString))
          .where((layer) => layer != null)
          .cast<SceneLayer>()
          .toList();

      if (layers.isNotEmpty) {
        backgroundWidget = MultiLayerRenderer.buildMultiLayerScene(
          layers: layers,
          screenSize: MediaQuery.of(context).size,
        );
      } else {
        ////print('[_buildBackground] 多图层为空，使用黑色背景');
        backgroundWidget = const ColoredBox(color: Colors.black);
      }
    } else {
      ////print('[_buildBackground] 单图层模式，背景内容: $background');
      // 单图层模式（原有逻辑）
      // 检查是否为十六进制颜色格式
      if (ColorBackgroundRenderer.isValidHexColor(background)) {
        ////print('[_buildBackground] 识别为十六进制颜色背景');
        backgroundWidget = ColorBackgroundRenderer.createColorBackgroundWidget(
          background,
        );
      } else {
        ////print('[_buildBackground] 识别为图片背景，开始处理图片路径');

        // 检查是否为内存缓存路径
        if (CgImageCompositor().isCachePath(background)) {
          //print('[_buildBackground] 🐛 检测到内存缓存路径，使用SmartImage加载: $background');
          // 使用SmartImage处理内存缓存路径
          backgroundWidget = SmartImage.asset(
            background,
            key: ValueKey('memory_cache_bg_$background'),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorWidget: const ColoredBox(color: Colors.black),
          );
        } else if (background.startsWith('/')) {
          //print('[_buildBackground] 🐛 检测到绝对文件路径，直接使用Image.file加载: $background');
          // 直接使用Image.file，不预缓存，避免FutureBuilder导致的黑屏
          backgroundWidget = Image.file(
            File(background),
            key: ValueKey('direct_bg_$background'),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            filterQuality: ImageSamplingManager().resolveWidgetFilterQuality(
              defaultQuality: FilterQuality.high,
            ),
            // 关键：不使用frameBuilder，让图像立即显示
            errorBuilder: (context, error, stackTrace) {
              //print('[_buildBackground] ❌ 直接文件加载失败: $background, 错误: $error');
              return const ColoredBox(color: Colors.black);
            },
          );
        } else {
          final cachedPath = _backgroundPathCache[background];
          final hasResolved = _backgroundPathCache.containsKey(background);
          if (!hasResolved) {
            _ensureBackgroundPathCached(background);
          }

          if (cachedPath != null) {
            backgroundWidget = SmartImage.asset(
              cachedPath,
              key: ValueKey(cachedPath),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorWidget: const ColoredBox(color: Colors.black),
            );
          } else {
            backgroundWidget = const ColoredBox(color: Colors.black);
          }
        }
      }

      backgroundWidget = ParallaxAware(depth: 0.22, child: backgroundWidget);
    }

    // 始终应用动画变换以避免Widget结构变化导致的闪烁
    backgroundWidget = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translate(
          ((animationProperties?['xcenter'] ?? 0.0)) *
              MediaQuery.of(context).size.width,
          ((animationProperties?['ycenter'] ?? 0.0)) *
              MediaQuery.of(context).size.height,
        )
        ..scale((animationProperties?['scale'] ?? 1.0))
        ..rotateZ((animationProperties?['rotation'] ?? 0.0)),
      child: Opacity(
        opacity: ((animationProperties?['alpha'] ?? 1.0)).clamp(0.0, 1.0),
        child: backgroundWidget,
      ),
    );

    // 应用场景滤镜
    if (sceneFilter != null) {
      backgroundWidget = _FilteredBackground(
        filter: sceneFilter,
        child: backgroundWidget,
      );
    }

    return backgroundWidget;
  }

  void _ensureBackgroundPathCached(String background) {
    if (_backgroundPathCache.containsKey(background) ||
        _backgroundPathResolving.contains(background)) {
      return;
    }

    _backgroundPathResolving.add(background);
    final assetName = 'backgrounds/${background.replaceAll(' ', '-')}';

    AssetManager().findAsset(assetName).then((resolvedPath) {
      _backgroundPathResolving.remove(background);
      if (!mounted) {
        _backgroundPathCache[background] = resolvedPath;
        return;
      }
      if (_backgroundPathCache[background] == resolvedPath) {
        return;
      }
      setState(() {
        _backgroundPathCache[background] = resolvedPath;
      });
    }).catchError((_) {
      _backgroundPathResolving.remove(background);
      if (!mounted) {
        _backgroundPathCache[background] = null;
        return;
      }
      if (_backgroundPathCache.containsKey(background)) {
        return;
      }
      setState(() {
        _backgroundPathCache[background] = null;
      });
    });
  }

  /// 预缓存背景图像到Flutter的ImageCache中
  Future<void> _precacheBackgroundImage(
    String imagePath,
    BuildContext context,
  ) async {
    try {
      print('[_precacheBackgroundImage] 开始预缓存: $imagePath');

      final file = File(imagePath);
      if (await file.exists()) {
        await precacheImage(FileImage(file), context);
        print('[_precacheBackgroundImage] 预缓存完成: $imagePath');
      } else {
        print('[_precacheBackgroundImage] 文件不存在: $imagePath');
      }
    } catch (e) {
      print('[_precacheBackgroundImage] 预缓存失败: $imagePath, 错误: $e');
    }
  }

  List<Widget> _buildCharacters(
    BuildContext context,
    Map<String, CharacterState> characters,
    Map<String, PoseConfig> poseConfigs,
    Set<String> everShownCharacters,
    CharacterLighting? characterLighting,
  ) {
    // 应用自动分布逻辑
    final characterOrder = characters.keys.toList();
    final distributedPoseConfigs =
        CharacterAutoDistribution.calculateAutoDistribution(
      characters,
      poseConfigs,
      characterOrder,
    );

    // 按resourceId分组，保留最新的角色状态
    final Map<String, MapEntry<String, CharacterState>> charactersByResourceId =
        {};

    for (final entry in characters.entries) {
      final resourceId = entry.value.resourceId;
      // 总是保留最新的状态（覆盖之前的）
      charactersByResourceId[resourceId] = entry;
    }

    return charactersByResourceId.values.map((entry) {
      final characterId = entry.key;
      final characterState = entry.value;

      final autoDistributedPoseId = '${characterId}_auto_distributed';
      final poseConfig = distributedPoseConfigs[autoDistributedPoseId] ??
          distributedPoseConfigs[characterState.positionId] ??
          PoseConfig(id: 'default');

      final animProps = characterState.animationProperties;
      double finalXCenter = poseConfig.xcenter;
      double finalYCenter = poseConfig.ycenter;
      double finalScale = poseConfig.scale;
      double alpha = 1.0;

      if (animProps != null) {
        finalXCenter = animProps['xcenter'] ?? finalXCenter;
        finalYCenter = animProps['ycenter'] ?? finalYCenter;
        finalScale = animProps['scale'] ?? finalScale;
        alpha = animProps['alpha'] ?? alpha;
      }

      final characterWidget = _CompositeCharacterWidget(
        key: ValueKey('composite-${characterState.resourceId}'),
        characterKey: characterId,
        resourceId: characterState.resourceId,
        pose: characterState.pose ?? 'pose1',
        expression: characterState.expression ?? 'happy',
        heightFactor: finalScale,
        isFadingOut: characterState.isFadingOut,
        skipAnimation: _isFastForwarding,
        onFadeOutComplete: characterState.isFadingOut
            ? () => _removeCharacterAfterFadeOut(characterId)
            : null,
      );

      Widget finalWidget = characterWidget;

      final maskType = (characterState.maskType ?? '').trim().toLowerCase();
      if (maskType == 'silhouette') {
        final parsedMaskColor = parseColor(characterState.maskColor?.trim()) ??
            const Color(0xFFFFFFFF);
        finalWidget = ColorFiltered(
          colorFilter: ColorFilter.mode(parsedMaskColor, BlendMode.srcIn),
          child: finalWidget,
        );
      }

      if (characterLighting != null) {
        finalWidget = ColorFiltered(
          colorFilter: characterLighting.colorFilter,
          child: finalWidget,
        );
      }

      if (alpha < 1.0) {
        finalWidget = Opacity(opacity: alpha, child: finalWidget);
      }

      finalWidget = _wrapWithParallax(finalWidget, 0.65);

      return Positioned(
        key: ValueKey('positioned-${characterState.resourceId}'),
        left: finalXCenter * MediaQuery.of(context).size.width,
        top: finalYCenter * MediaQuery.of(context).size.height,
        child: FractionalTranslation(
          translation: _anchorToTranslation(poseConfig.anchor),
          child: finalWidget,
        ),
      );
    }).toList();
  }

  Offset _anchorToTranslation(String anchor) {
    switch (anchor) {
      case 'topCenter':
        return const Offset(-0.5, 0);
      case 'bottomCenter':
        return const Offset(-0.5, -1.0);
      case 'centerLeft':
        return const Offset(0, -0.5);
      case 'centerRight':
        return const Offset(-1.0, -0.5);
      case 'center':
      default:
        return const Offset(-0.5, -0.5);
    }
  }

  Widget _wrapWithParallax(Widget widget, double depth, {bool invert = true}) {
    if (depth == 0) {
      return widget;
    }
    if (widget is ParallaxAware) {
      return widget;
    }
    if (widget is Positioned) {
      return Positioned(
        key: widget.key,
        left: widget.left,
        top: widget.top,
        right: widget.right,
        bottom: widget.bottom,
        width: widget.width,
        height: widget.height,
        child: _wrapWithParallax(
          widget.child ?? const SizedBox.shrink(),
          depth,
          invert: invert,
        ),
      );
    }
    if (widget is PositionedDirectional) {
      return PositionedDirectional(
        key: widget.key,
        start: widget.start,
        end: widget.end,
        top: widget.top,
        bottom: widget.bottom,
        width: widget.width,
        height: widget.height,
        child: _wrapWithParallax(
          widget.child ?? const SizedBox.shrink(),
          depth,
          invert: invert,
        ),
      );
    }
    return ParallaxAware(depth: depth, invert: invert, child: widget);
  }
}

class _CompositeCharacterWidget extends StatefulWidget {
  final String characterKey;
  final String resourceId;
  final String pose;
  final String expression;
  final double heightFactor;
  final bool isFadingOut;
  final bool skipAnimation;
  final VoidCallback? onFadeOutComplete;

  const _CompositeCharacterWidget({
    super.key,
    required this.characterKey,
    required this.resourceId,
    required this.pose,
    required this.expression,
    required this.heightFactor,
    required this.isFadingOut,
    required this.skipAnimation,
    this.onFadeOutComplete,
  });

  @override
  State<_CompositeCharacterWidget> createState() =>
      _CompositeCharacterWidgetState();
}

class _CompositeCharacterWidgetState extends State<_CompositeCharacterWidget> {
  ui.Image? _currentImage;
  int _loadRequestId = 0;

  @override
  void initState() {
    super.initState();
    _loadComposite();
  }

  @override
  void didUpdateWidget(covariant _CompositeCharacterWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.resourceId != oldWidget.resourceId ||
        widget.pose != oldWidget.pose ||
        widget.expression != oldWidget.expression) {
      _loadComposite();
    }

    if (!oldWidget.isFadingOut && widget.isFadingOut) {
      Future.delayed(const Duration(milliseconds: 220), () {
        if (mounted && widget.isFadingOut) {
          widget.onFadeOutComplete?.call();
        }
      });
    }
  }

  Future<void> _loadComposite() async {
    final requestId = ++_loadRequestId;
    //print('[_CompositeCharacterWidget] 开始加载合成图像 - 角色: ${widget.characterKey}, resourceId: ${widget.resourceId}, pose: ${widget.pose}, expression: ${widget.expression}');

    final image = await CharacterCompositeCache.instance.preload(
      widget.resourceId,
      widget.pose,
      widget.expression,
    );

    //print('[_CompositeCharacterWidget] 合成图像加载完成 - 角色: ${widget.characterKey}, 结果: ${image != null ? "成功" : "失败"}');

    if (!mounted || requestId != _loadRequestId) return;
    setState(() {
      _currentImage = image;
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _currentImage;
    //print('[_CompositeCharacterWidget] build调用 - 角色: ${widget.characterKey}, image: ${image != null ? "已加载" : "null"}');

    if (image == null) {
      //print('[_CompositeCharacterWidget] 图像为null，返回空组件 - 角色: ${widget.characterKey}');
      return const SizedBox.shrink();
    }

    final screenHeight = MediaQuery.of(context).size.height;
    final targetHeight = screenHeight * widget.heightFactor;
    if (targetHeight <= 0) {
      return const SizedBox.shrink();
    }
    final aspectRatio = image.width / image.height;
    final targetWidth = targetHeight * aspectRatio;

    //print('[_CompositeCharacterWidget] 渲染角色: ${widget.characterKey}, 尺寸: ${targetWidth}x${targetHeight}');
    return SizedBox(
      width: targetWidth,
      height: targetHeight,
      child: DirectCgDisplay(
        key: ValueKey('direct_${widget.characterKey}'),
        image: image,
        resourceId: widget.characterKey,
        isFadingOut: widget.isFadingOut,
        enableFadeIn: !widget.isFadingOut,
        skipAnimation: widget.skipAnimation,
      ),
    );
  }
}

class _FilteredBackground extends StatefulWidget {
  final SceneFilter filter;
  final Widget child;

  const _FilteredBackground({required this.filter, required this.child});

  @override
  State<_FilteredBackground> createState() => _FilteredBackgroundState();
}

class _FilteredBackgroundState extends State<_FilteredBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    if (_GamePlayScreenState._fxDiagLogs) {
      debugPrint(
        '[FX_DIAG] _FilteredBackground init '
        'filter=${widget.filter.type}/${widget.filter.intensity}/${widget.filter.animation}/${widget.filter.duration}',
      );
    }
    _animationController = AnimationController(
      duration: Duration(milliseconds: (widget.filter.duration * 1000).round()),
      vsync: this,
    );

    if (widget.filter.animation != AnimationType.none) {
      _animationController.repeat();
    }
  }

  @override
  void didUpdateWidget(_FilteredBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filter != widget.filter) {
      if (_GamePlayScreenState._fxDiagLogs) {
        debugPrint(
          '[FX_DIAG] _FilteredBackground update '
          'old=${oldWidget.filter.type}/${oldWidget.filter.intensity}/${oldWidget.filter.animation}/${oldWidget.filter.duration} '
          'new=${widget.filter.type}/${widget.filter.intensity}/${widget.filter.animation}/${widget.filter.duration}',
        );
      }
      _animationController.duration = Duration(
        milliseconds: (widget.filter.duration * 1000).round(),
      );
      if (widget.filter.animation != AnimationType.none) {
        _animationController.repeat();
      } else {
        _animationController.stop();
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FilterRenderer.applyFilter(
      child: widget.child,
      filter: widget.filter,
      animationController: _animationController,
    );
  }
}
