part of 'game_play_screen.dart';

extension _GamePlayScreenInteractions on _GamePlayScreenState {
  static const Duration _commandMenuOpenDelay = Duration(milliseconds: 120);
  static const String _narratorWheelId =
      ScriptContentModifier.narratorCharacterId;

  Future<void> _loadMouseRollbackBehavior() async {
    try {
      await _settingsManager.init();
      final behavior = await _settingsManager.getMouseRollbackBehavior();
      final parallaxEnabled = await _settingsManager.getMouseParallaxEnabled();
      if (!mounted) {
        _mouseRollbackBehavior = behavior;
        _isParallaxEnabled = parallaxEnabled;
        return;
      }
      _setStateIfMounted(() {
        _mouseRollbackBehavior = behavior;
        _isParallaxEnabled = parallaxEnabled;
      });
    } catch (_) {
      // 使用默认设置
      _mouseRollbackBehavior = SettingsManager.defaultMouseRollbackBehavior;
      _isParallaxEnabled = SettingsManager.defaultMouseParallaxEnabled;
    }
  }

  void _handleSettingsChanged() {
    final behavior = _settingsManager.currentMouseRollbackBehavior;
    final parallaxEnabled = _settingsManager.currentMouseParallaxEnabled;
    if (_mouseRollbackBehavior == behavior &&
        _isParallaxEnabled == parallaxEnabled) {
      return;
    }
    if (!mounted) {
      _mouseRollbackBehavior = behavior;
      _isParallaxEnabled = parallaxEnabled;
      return;
    }
    _setStateIfMounted(() {
      _mouseRollbackBehavior = behavior;
      _isParallaxEnabled = parallaxEnabled;
    });
  }

  void _returnToMainMenu() async {
    try {
      await _gameManager.createAutoSaveBeforeMainMenu();
    } catch (_) {
      // 忽略自动存档失败，保持返回流程可用
    }

    // 返回主菜单时清理游戏内音频，避免游戏BGM残留到主菜单。
    try {
      await MusicManager().clearBackgroundMusic(fadeOut: false);
    } catch (_) {
      // 忽略停止背景音乐失败，保持返回流程可用
    }

    // 停止所有音效
    _gameManager.stopAllSounds();

    if (mounted && widget.onReturnToMenu != null) {
      widget.onReturnToMenu!();
    } else if (mounted) {
      // 兼容性后退方案：使用传统的页面导航
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => MainMenuScreen(
            onNewGame: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) =>
                    GamePlayScreen(gameModule: widget.gameModule),
              ),
            ),
            onLoadGame: () => _setStateIfMounted(() => _showLoadOverlay = true),
          ),
        ),
        (Route<dynamic> route) => false,
      );
    }
  }

  Widget _createDialogueBox({
    Key? key,
    String? speaker,
    String? speakerAlias, // 新增：角色简写参数
    String? dialogueTag, // 对话行尾扩展 token（项目层可自定义）
    required String dialogue,
    required bool isFastForwarding, // 新增快进状态参数
    required int scriptIndex, // 新增脚本索引参数
    VoidCallback? onToggleSettings,
    VoidCallback? onToggleReview,
  }) {
    // 不在这里标记为已读！应该在用户推进对话时才标记
    final module = widget.gameModule ?? DefaultGameModule();
    return module.createDialogueBox(
      key: key,
      speaker: speaker,
      speakerAlias: speakerAlias,
      dialogueTag: dialogueTag,
      dialogue: dialogue,
      progressionManager: _dialogueProgressionManager,
      isFastForwarding: isFastForwarding,
      scriptIndex: scriptIndex,
      onToggleSettings: onToggleSettings,
      onToggleReview: onToggleReview,
    );
  }

  void _handleQuickMenuBack() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ConfirmDialog(
          title: '返回主菜单',
          content: '确定要返回主菜单吗？未保存的游戏进度将会丢失。',
          onConfirm: _returnToMainMenu,
        );
      },
    );
  }

  Future<void> _handleMouseRollbackAction() async {
    var behavior = _mouseRollbackBehavior;
    try {
      behavior = await _settingsManager.getMouseRollbackBehavior();
    } catch (_) {
      behavior = _mouseRollbackBehavior;
    }

    if (!mounted) {
      _mouseRollbackBehavior = behavior;
      return;
    }

    if (_mouseRollbackBehavior != behavior) {
      _setStateIfMounted(() {
        _mouseRollbackBehavior = behavior;
      });
    }

    // 选项界面特例：允许通过回滚动作唤起观看记录，但仍遵循玩家设置。
    if (_isShowingMenu) {
      if (behavior == 'history') {
        if (mounted && !_showReviewOverlay) {
          final now = DateTime.now();
          if (_reviewReopenSuppressedUntil != null &&
              now.isBefore(_reviewReopenSuppressedUntil!)) {
            if (kSakiDiagnosticLogs) {
              debugPrint(
                '[MouseRollback] (menu) suppressed until $_reviewReopenSuppressedUntil',
              );
            }
            return;
          }
          _setStateIfMounted(() {
            _reviewOpenedByMouseRollback = true;
            _showReviewOverlay = true;
          });
          if (kSakiDiagnosticLogs) {
            debugPrint('[MouseRollback] (menu) opened review overlay');
          }
        }
      } else {
        _handlePreviousDialogue();
      }
      return;
    }

    if (kSakiDiagnosticLogs) {
      debugPrint(
        '[MouseRollback] action behavior=$behavior, '
        'showReview=$_showReviewOverlay, history=${_gameManager.getDialogueHistory().length}',
      );
    }

    if (behavior == 'history') {
      if (mounted && !_showReviewOverlay) {
        final now = DateTime.now();
        if (_reviewReopenSuppressedUntil != null &&
            now.isBefore(_reviewReopenSuppressedUntil!)) {
          if (kSakiDiagnosticLogs) {
            debugPrint(
              '[MouseRollback] suppressed until $_reviewReopenSuppressedUntil',
            );
          }
          return;
        }
        _setStateIfMounted(() {
          _reviewOpenedByMouseRollback = true;
          _showReviewOverlay = true;
        });
        if (kSakiDiagnosticLogs) {
          debugPrint('[MouseRollback] opened review overlay');
        }
      }
      return;
    }

    _handlePreviousDialogue();
  }

  void _toggleReviewOverlay(bool triggeredByOverscroll) {
    _setStateIfMounted(() {
      final newValue = !_showReviewOverlay;
      _showReviewOverlay = newValue;
      if (newValue) {
        if (!triggeredByOverscroll) {
          _reviewOpenedByMouseRollback = false;
        }
      } else {
        _reviewOpenedByMouseRollback = false;
      }
    });

    if (triggeredByOverscroll) {
      _reviewReopenSuppressedUntil = DateTime.now().add(
        const Duration(milliseconds: 250),
      );
    } else {
      _reviewReopenSuppressedUntil = null;
    }
  }

  void _handlePreviousDialogue() {
    final history = _gameManager.getDialogueHistory();

    // 菜单中“回退剧情”应真正回退一步：
    // 当前菜单对应的是 history.last（选项上方展示句），
    // 因此回退目标应是 history[-2]（若存在）。
    if (_isShowingMenu) {
      if (history.length >= 2) {
        final previousEntry = history[history.length - 2];
        _jumpToHistoryEntryQuiet(previousEntry);
      } else if (history.isNotEmpty) {
        _jumpToHistoryEntryQuiet(history.first);
      }
    }
    // 如果没有选项，正常回到上一句
    else if (history.length >= 2) {
      final previousEntry = history[history.length - 2];
      _jumpToHistoryEntryQuiet(previousEntry);
    }
  }

  // 检查是否为桌面平台
  bool _isDesktopPlatform() {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  // 设置系统级热键
  Future<void> _setupHotkey() async {
    // hotkey_manager 只在桌面平台可用
    if (!_isDesktopPlatform()) {
      sakiDiagnosticLog('跳过热键注册：当前平台不支持 hotkey_manager');
      return;
    }
    _reloadHotKey = HotKey(
      key: PhysicalKeyboardKey.keyR,
      modifiers: [HotKeyModifier.shift],
      scope: HotKeyScope.inapp, // 先使用应用内热键，避免权限问题
    );

    try {
      await hotKeyManager.register(
        _reloadHotKey!,
        keyDownHandler: (hotKey) {
          sakiDiagnosticLog('热键触发: ${hotKey.toJson()}');
          if (mounted) {
            _handleHotReload();
          }
        },
      );
      sakiDiagnosticLog('快捷键 Shift+R 注册成功');
    } catch (e) {
      print('快捷键注册失败: $e');
      // 如果系统级热键失败，尝试应用内热键
      _reloadHotKey = HotKey(
        key: PhysicalKeyboardKey.keyR,
        modifiers: [HotKeyModifier.shift],
        scope: HotKeyScope.inapp,
      );
      try {
        await hotKeyManager.register(
          _reloadHotKey!,
          keyDownHandler: (hotKey) {
            sakiDiagnosticLog('应用内热键触发: ${hotKey.toJson()}');
            if (mounted) {
              _handleHotReload();
            }
          },
        );
        sakiDiagnosticLog('应用内快捷键 Shift+R 注册成功');
      } catch (e2) {
        print('应用内快捷键注册也失败: $e2');
      }
    }

    // 注册开发者面板快捷键 Shift+D (仅在Debug模式下)
    if (kEngineDebugMode) {
      _developerPanelHotKey = HotKey(
        key: PhysicalKeyboardKey.keyD,
        modifiers: [HotKeyModifier.shift],
        scope: HotKeyScope.inapp,
      );

      try {
        await hotKeyManager.register(
          _developerPanelHotKey!,
          keyDownHandler: (hotKey) {
            print('开发者面板热键触发: ${hotKey.toJson()}');
            _setStateIfMounted(() {
              _showDeveloperPanel = !_showDeveloperPanel;
            });
          },
        );
        sakiDiagnosticLog('快捷键 Shift+D 注册成功 (开发者面板)');
      } catch (e) {
        print('开发者面板快捷键注册失败: $e');
      }

      // 注册悬浮脚本编辑器快捷键 Shift+P（仅Debug）
      _floatingScriptEditorHotKey = HotKey(
        key: PhysicalKeyboardKey.keyP,
        modifiers: [HotKeyModifier.shift],
        scope: HotKeyScope.inapp,
      );
      try {
        await hotKeyManager.register(
          _floatingScriptEditorHotKey!,
          keyDownHandler: (hotKey) {
            if (kSakiDiagnosticLogs) {
              print('悬浮脚本编辑器热键触发: ${hotKey.toJson()}');
            }
            _setStateIfMounted(() {
              _showFloatingScriptEditor = !_showFloatingScriptEditor;
              _isShiftKeyPressed = false;
            });
            _showNotificationMessage(
              '脚本浮窗 ${_showFloatingScriptEditor ? '开启' : '关闭'}',
            );
          },
        );
        sakiDiagnosticLog('快捷键 Shift+P 注册成功 (脚本浮窗)');
      } catch (e) {
        print('脚本浮窗快捷键注册失败: $e');
      }
    }

    // 上下方向键改由 Focus.onKeyEvent 统一处理，避免平台热键差异。
    sakiDiagnosticLog('箭头键输入由 Focus.onKeyEvent 处理');
  }

  // 设置表情选择器管理器（Debug模式下的表情选择功能）
  void _setupExpressionSelectorManager() {
    _expressionSelectorManager = ExpressionSelectorManager(
      gameManager: _gameManager,
      showNotificationCallback: _showNotificationMessage,
      triggerReloadCallback: _handleHotReload,
      getCurrentGameState: () {
        // 获取当前游戏状态
        return _gameManager.currentState;
      },
      shouldIgnoreHotkey: () =>
          _showFloatingScriptEditor ||
          _showDeveloperPanel ||
          _showDebugPanel ||
          _showSettings ||
          _showSaveOverlay ||
          _showLoadOverlay ||
          _showReviewOverlay,
      setExpressionSelectorVisibility: (show) {
        if (mounted) {
          // 检查是否可以显示表情选择器
          final canShow =
              show &&
              !_isAnyCommandMenuOpen &&
              _expressionSelectorManager!.canShowExpressionSelector(
                showSaveOverlay: _showSaveOverlay,
                showLoadOverlay: _showLoadOverlay,
                showReviewOverlay: _showReviewOverlay,
                showSettings: _showSettings,
                showDeveloperPanel: _showDeveloperPanel,
                showDebugPanel: _showDebugPanel,
                showFloatingScriptEditor: _showFloatingScriptEditor,
                isShowingMenu: _isShowingMenu,
              );

          _setStateIfMounted(() {
            _showExpressionSelector = canShow;
          });

          _expressionSelectorManager!.setExpressionSelectorVisible(canShow);
        }
      },
    );

    _expressionSelectorManager!.initialize();
  }

  bool _handleDebugEditorEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }

    final hadEditorOpen =
        _showFloatingScriptEditor ||
        _showDeveloperPanel ||
        _showDebugPanel ||
        _showExpressionSelector ||
        _isAnyCommandMenuOpen;
    if (!hadEditorOpen) {
      return false;
    }

    _expressionWheelOpenTimer?.cancel();
    if (_showMusicGridMenu) {
      unawaited(_restoreMusicPreviewIfNeeded());
    }
    _restoreCanvasPreviewIfNeeded();
    _setStateIfMounted(() {
      _showFloatingScriptEditor = false;
      _showDeveloperPanel = false;
      _showDebugPanel = false;
      _showExpressionSelector = false;
      _isShiftKeyPressed = false;
      _resetCommandMenuFields();
    });
    _expressionSelectorManager?.setExpressionSelectorVisible(false);
    return true;
  }

  bool _handleExpressionWheelKeyEvent(KeyEvent event) {
    final logicalKey = event.logicalKey;
    final isShiftKey =
        logicalKey == LogicalKeyboardKey.shiftLeft ||
        logicalKey == LogicalKeyboardKey.shiftRight ||
        logicalKey == LogicalKeyboardKey.shift;
    final isShortcutA = logicalKey == LogicalKeyboardKey.keyA;
    final isShortcutC = logicalKey == LogicalKeyboardKey.keyC;
    final isShortcutB = logicalKey == LogicalKeyboardKey.keyB;
    final isShortcutV = logicalKey == LogicalKeyboardKey.keyV;
    final isShortcut1 =
        logicalKey == LogicalKeyboardKey.digit1 ||
        logicalKey == LogicalKeyboardKey.exclamation ||
        event.physicalKey == PhysicalKeyboardKey.digit1;

    if (kSakiDiagnosticLogs &&
        (isShiftKey ||
            isShortcutA ||
            isShortcutC ||
            isShortcutB ||
            isShortcutV ||
            isShortcut1)) {
      print(
        'ExpressionWheel: key event type=${event.runtimeType}, key=${logicalKey.debugName}, isShiftPressed=${HardwareKeyboard.instance.isShiftPressed}, internalPressed=$_isShiftKeyPressed, mode=$_activeCommandMenuMode, visible=$_isAnyCommandMenuOpen',
      );
    }

    if (isShiftKey) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        if (_isShiftKeyPressed) {
          return true;
        }
        _isShiftKeyPressed = true;
        return true;
      }

      if (event is KeyUpEvent) {
        _isShiftKeyPressed = HardwareKeyboard.instance.isShiftPressed;
        if (_isShiftKeyPressed) {
          if (kSakiDiagnosticLogs) {
            print('ExpressionWheel: keyUp ignored, shift still pressed');
          }
          return true;
        }
        _expressionWheelOpenTimer?.cancel();
        if (_showExpressionWheel) {
          if (kSakiDiagnosticLogs) {
            print('ExpressionWheel: keyUp apply expression selection');
          }
          unawaited(_applyExpressionWheelSelectionAndClose());
        } else if (_showCharacterWheel) {
          if (kSakiDiagnosticLogs) {
            print('ExpressionWheel: keyUp apply character selection');
          }
          unawaited(_applyCharacterWheelSelectionAndClose());
        } else if (_showBackgroundGridMenu ||
            _showCanvasGridMenu ||
            _showMusicGridMenu) {
          // 网格菜单采用“常驻+双击应用”，Shift松开不做自动应用。
          if (kSakiDiagnosticLogs) {
            print(
              'ExpressionWheel: keyUp keep grid menu open (background/canvas/music persistent mode)',
            );
          }
        } else {
          _clearCommandMenuState();
        }
        return true;
      }
    }

    if (event is KeyRepeatEvent &&
        _isShiftKeyPressed &&
        (isShortcutA ||
            isShortcutC ||
            isShortcutB ||
            isShortcutV ||
            isShortcut1)) {
      return true;
    }

    if (event is KeyDownEvent && _isShiftKeyPressed) {
      _CommandDebugMenuMode? requestedMode;
      if (isShortcutA) {
        requestedMode = _CommandDebugMenuMode.expression;
      } else if (isShortcutC) {
        requestedMode = _CommandDebugMenuMode.character;
      } else if (isShortcutB) {
        requestedMode = _CommandDebugMenuMode.background;
      } else if (isShortcutV) {
        requestedMode = _CommandDebugMenuMode.canvas;
      } else if (isShortcut1) {
        requestedMode = _CommandDebugMenuMode.music;
      }

      if (requestedMode != null) {
        if (_isGridMenuMode(requestedMode)) {
          if (_activeCommandMenuMode == requestedMode &&
              _isGridMenuVisibleForMode(requestedMode)) {
            if (requestedMode == _CommandDebugMenuMode.music) {
              unawaited(_restoreMusicPreviewIfNeeded());
            }
            _clearCommandMenuState();
          } else {
            if (_showMusicGridMenu &&
                requestedMode != _CommandDebugMenuMode.music) {
              unawaited(_restoreMusicPreviewIfNeeded());
            }
            _clearCommandMenuState();
            _activeCommandMenuMode = requestedMode;
            _scheduleCommandMenuOpen(requestedMode);
          }
          return true;
        }

        final currentMode = _activeCommandMenuMode;
        if (_isAnyCommandMenuOpen && currentMode != requestedMode) {
          if (_showMusicGridMenu) {
            unawaited(_restoreMusicPreviewIfNeeded());
          }
          _clearCommandMenuState();
        }

        bool isTargetVisible;
        switch (requestedMode) {
          case _CommandDebugMenuMode.expression:
            isTargetVisible = _showExpressionWheel;
            break;
          case _CommandDebugMenuMode.character:
            isTargetVisible = _showCharacterWheel;
            break;
          case _CommandDebugMenuMode.background:
            isTargetVisible = _showBackgroundGridMenu;
            break;
          case _CommandDebugMenuMode.canvas:
            isTargetVisible = _showCanvasGridMenu;
            break;
          case _CommandDebugMenuMode.music:
            isTargetVisible = _showMusicGridMenu;
            break;
        }

        if (_activeCommandMenuMode != requestedMode || !isTargetVisible) {
          _activeCommandMenuMode = requestedMode;
          if (kSakiDiagnosticLogs) {
            final modeName = switch (requestedMode) {
              _CommandDebugMenuMode.expression => 'expression',
              _CommandDebugMenuMode.character => 'character',
              _CommandDebugMenuMode.background => 'background',
              _CommandDebugMenuMode.canvas => 'canvas',
              _CommandDebugMenuMode.music => 'music',
            };
            print('ExpressionWheel: switch mode -> $modeName');
          }
          _scheduleCommandMenuOpen(requestedMode);
        }
        return true;
      }
    }

    if (_isAnyCommandMenuOpen) {
      // 命令菜单开启时阻断其他键盘输入，避免误推进剧情。
      return true;
    }
    return false;
  }

  bool _isGridMenuMode(_CommandDebugMenuMode mode) {
    return mode == _CommandDebugMenuMode.background ||
        mode == _CommandDebugMenuMode.canvas ||
        mode == _CommandDebugMenuMode.music;
  }

  bool _isGridMenuVisibleForMode(_CommandDebugMenuMode mode) {
    switch (mode) {
      case _CommandDebugMenuMode.background:
        return _showBackgroundGridMenu;
      case _CommandDebugMenuMode.canvas:
        return _showCanvasGridMenu;
      case _CommandDebugMenuMode.music:
        return _showMusicGridMenu;
      case _CommandDebugMenuMode.expression:
        return _showExpressionWheel;
      case _CommandDebugMenuMode.character:
        return _showCharacterWheel;
    }
  }

  void _scheduleCommandMenuOpen(_CommandDebugMenuMode mode) {
    _expressionWheelOpenTimer?.cancel();
    _expressionWheelOpenTimer = Timer(_commandMenuOpenDelay, () {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: open timer fired mode=$mode');
      }
      switch (mode) {
        case _CommandDebugMenuMode.expression:
          unawaited(_openExpressionWheelIfPossible());
          break;
        case _CommandDebugMenuMode.character:
          unawaited(_openCharacterWheelIfPossible());
          break;
        case _CommandDebugMenuMode.background:
          unawaited(_openBackgroundGridIfPossible());
          break;
        case _CommandDebugMenuMode.canvas:
          _openCanvasGridIfPossible();
          break;
        case _CommandDebugMenuMode.music:
          unawaited(_openMusicGridIfPossible());
          break;
      }
    });
  }

  bool _canShowExpressionWheel() {
    return !_isAnyCommandMenuOpen &&
        !_showSaveOverlay &&
        !_showLoadOverlay &&
        !_showReviewOverlay &&
        !_showSettings &&
        !_showFlowchart &&
        !_showDeveloperPanel &&
        !_showDebugPanel &&
        !_showExpressionSelector &&
        !_isShowingMenu &&
        !_isBlockingCinematicInput;
  }

  Future<void> _openCharacterWheelIfPossible() async {
    if (!_isShiftKeyPressed || !mounted) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: character open aborted (shiftPressed=$_isShiftKeyPressed, mounted=$mounted)',
        );
      }
      return;
    }
    if (!_canShowExpressionWheel()) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: character open blocked by overlays');
      }
      return;
    }

    final options = await _buildCharacterWheelOptions();
    if (options.isEmpty) {
      _showNotificationMessage('当前场景没有可切换角色');
      return;
    }

    final current = _resolveCurrentCharacterWheelId(options);
    if (!mounted || !_isShiftKeyPressed) {
      return;
    }

    _setStateIfMounted(() {
      _showExpressionWheel = false;
      _showBackgroundGridMenu = false;
      _showCanvasGridMenu = false;
      _showMusicGridMenu = false;
      _expressionWheelSpeakerInfo = null;
      _expressionWheelExpressions = const [];
      _expressionWheelImagePaths = const {};
      _expressionWheelHighlightedExpression = null;

      _characterWheelOptions = options;
      _characterWheelCurrentId = current;
      _characterWheelHighlightedId = current ?? options.first.id;
      _expressionWheelCenter = _lastPointerPosition;
      _showCharacterWheel = true;
      _activeCommandMenuMode = _CommandDebugMenuMode.character;
    });
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: character wheel opened options=${options.length}, current=$_characterWheelCurrentId',
      );
    }
  }

  Future<void> _openBackgroundGridIfPossible() async {
    if (!mounted) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: background open aborted (mounted=$mounted)');
      }
      return;
    }
    if (!_canShowExpressionWheel()) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: background open blocked by overlays');
      }
      return;
    }

    final options = await _buildBackgroundGridOptions();
    if (options.isEmpty) {
      _showNotificationMessage('未找到可用背景资源');
      return;
    }
    final currentBackground = _gameManager.currentState.background ?? '';
    final current = _resolveCurrentBackgroundOptionId(
      options,
      currentBackground,
    );

    if (!mounted) {
      return;
    }

    _setStateIfMounted(() {
      _showExpressionWheel = false;
      _showCharacterWheel = false;
      _showCanvasGridMenu = false;
      _showMusicGridMenu = false;
      _expressionWheelSpeakerInfo = null;
      _expressionWheelExpressions = const [];
      _expressionWheelImagePaths = const {};
      _expressionWheelHighlightedExpression = null;

      _backgroundGridOptions = options;
      _backgroundGridCurrentId = current;
      _backgroundGridHighlightedId = current ?? options.first.id;
      _expressionWheelCenter = _lastPointerPosition;
      _showBackgroundGridMenu = true;
      _activeCommandMenuMode = _CommandDebugMenuMode.background;
    });
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: background grid opened options=${options.length}, current=$_backgroundGridCurrentId',
      );
    }
  }

  void _openCanvasGridIfPossible() {
    if (!mounted) {
      return;
    }
    if (!_canShowExpressionWheel()) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: canvas open blocked by overlays');
      }
      return;
    }

    final module = widget.gameModule ?? DefaultGameModule();
    final options =
        module.scriptCanvases
            .where((registration) => registration.id.trim().isNotEmpty)
            .map(
              (registration) => CommandWheelOption(
                id: registration.id.trim(),
                label: registration.displayName.trim().isEmpty
                    ? registration.id.trim()
                    : registration.displayName.trim(),
              ),
            )
            .toList()
          ..sort((a, b) => a.label.compareTo(b.label));
    if (options.isEmpty) {
      _showNotificationMessage('当前项目没有注册 Canvas');
      return;
    }

    final originalId = _gameManager.currentState.scriptCanvasId;
    final currentId = options.any((option) => option.id == originalId)
        ? originalId
        : null;
    final highlightedId = currentId ?? options.first.id;
    _setStateIfMounted(() {
      _showExpressionWheel = false;
      _showCharacterWheel = false;
      _showBackgroundGridMenu = false;
      _showMusicGridMenu = false;
      _expressionWheelSpeakerInfo = null;
      _expressionWheelExpressions = const [];
      _expressionWheelImagePaths = const {};
      _expressionWheelHighlightedExpression = null;

      _canvasGridOptions = options;
      _canvasGridCurrentId = currentId;
      _canvasGridHighlightedId = highlightedId;
      _canvasGridOriginalId = originalId;
      _expressionWheelCenter = _lastPointerPosition;
      _showCanvasGridMenu = true;
      _activeCommandMenuMode = _CommandDebugMenuMode.canvas;
    });
    _previewCanvasSelection(highlightedId);
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: canvas grid opened options=${options.length}, current=$currentId',
      );
    }
  }

  Future<void> _openMusicGridIfPossible() async {
    if (!mounted) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: music open aborted (mounted=$mounted)');
      }
      return;
    }
    if (!_canShowExpressionWheel()) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: music open blocked by overlays');
      }
      return;
    }

    final options = await _buildMusicGridOptions();
    if (options.isEmpty) {
      _showNotificationMessage('未找到可用音乐资源');
      return;
    }
    final currentMusic = MusicManager().currentBackgroundMusic ?? '';
    final current = _resolveCurrentMusicOptionId(options, currentMusic);

    if (!mounted) {
      return;
    }

    _setStateIfMounted(() {
      _showExpressionWheel = false;
      _showCharacterWheel = false;
      _showBackgroundGridMenu = false;
      _showCanvasGridMenu = false;
      _expressionWheelSpeakerInfo = null;
      _expressionWheelExpressions = const [];
      _expressionWheelImagePaths = const {};
      _expressionWheelHighlightedExpression = null;

      _musicGridOptions = options;
      _musicGridCurrentId = current;
      _musicGridHighlightedId = current ?? options.first.id;
      _musicGridOriginalAssetPath = currentMusic;
      _musicPreviewPlayingId = null;
      _expressionWheelCenter = _lastPointerPosition;
      _showMusicGridMenu = true;
      _activeCommandMenuMode = _CommandDebugMenuMode.music;
    });
    await _previewMusicSelectionIfNeeded(_musicGridHighlightedId);
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: music grid opened options=${options.length}, current=$_musicGridCurrentId, original=$_musicGridOriginalAssetPath',
      );
    }
  }

  Future<void> _openExpressionWheelIfPossible() async {
    if (!_isShiftKeyPressed || !mounted) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: open aborted (shiftPressed=$_isShiftKeyPressed, mounted=$mounted)',
        );
      }
      return;
    }

    if (!_canShowExpressionWheel()) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: open blocked overlays menu=$_isShowingMenu save=$_showSaveOverlay load=$_showLoadOverlay review=$_showReviewOverlay settings=$_showSettings flowchart=$_showFlowchart dev=$_showDeveloperPanel debug=$_showDebugPanel selector=$_showExpressionSelector wheel=$_showExpressionWheel cinematic=$_isBlockingCinematicInput',
        );
      }
      return;
    }

    final manager = _expressionSelectorManager;
    if (manager == null) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: manager is null');
      }
      return;
    }

    final speakerInfo = manager.getCurrentSpeakerInfo();
    if (speakerInfo == null) {
      if (kSakiDiagnosticLogs) {
        final state = _gameManager.currentState;
        print(
          'ExpressionWheel: no target speaker (speaker=${state.speaker}, speakerAlias=${state.speakerAlias}, characters=${state.characters.keys.join(',')})',
        );
      }
      _showNotificationMessage('没有当前可操作立绘');
      return;
    }
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: speaker=${speakerInfo.speakerName}, characterId=${speakerInfo.characterId}, currentPose=${speakerInfo.currentPose}, currentExpression=${speakerInfo.currentExpression}, scriptCharacterKey=${speakerInfo.scriptCharacterKey}',
      );
    }

    final expressions = await _loadExpressionWheelExpressions(
      speakerInfo.characterId,
    );
    final expressionImagePaths = await _buildExpressionImagePaths(
      speakerInfo.characterId,
      speakerInfo.currentPose,
      expressions,
    );
    if (expressions.isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: no layers for ${speakerInfo.characterId}');
      }
      _showNotificationMessage('未找到可用差分');
      return;
    }
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: loaded ${expressions.length} layers, first=${expressions.first}, last=${expressions.last}',
      );
    }

    if (!mounted || !_isShiftKeyPressed) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: open cancelled after load (mounted=$mounted, shiftPressed=$_isShiftKeyPressed)',
        );
      }
      return;
    }

    final highlightedExpression =
        expressions.contains(speakerInfo.currentExpression)
        ? speakerInfo.currentExpression
        : expressions.contains(speakerInfo.currentPose)
        ? speakerInfo.currentPose
        : expressions.first;

    _setStateIfMounted(() {
      _expressionWheelSpeakerInfo = speakerInfo;
      _expressionWheelExpressions = expressions;
      _expressionWheelImagePaths = expressionImagePaths;
      _expressionWheelHighlightedExpression = highlightedExpression;
      _characterWheelOptions = const [];
      _characterWheelCurrentId = null;
      _characterWheelHighlightedId = null;
      _backgroundGridOptions = const [];
      _backgroundGridCurrentId = null;
      _backgroundGridHighlightedId = null;
      _canvasGridOptions = const [];
      _canvasGridCurrentId = null;
      _canvasGridHighlightedId = null;
      _canvasGridOriginalId = null;
      _musicGridOptions = const [];
      _musicGridCurrentId = null;
      _musicGridHighlightedId = null;
      _expressionWheelCenter = _lastPointerPosition;
      _showExpressionWheel = true;
      _showCharacterWheel = false;
      _showBackgroundGridMenu = false;
      _showCanvasGridMenu = false;
      _showMusicGridMenu = false;
      _activeCommandMenuMode = _CommandDebugMenuMode.expression;
    });
    if (kSakiDiagnosticLogs) {
      print('ExpressionWheel: opened highlight=$highlightedExpression');
    }
  }

  Future<List<String>> _loadExpressionWheelExpressions(
    String characterId,
  ) async {
    final layers = await AssetManager.getAvailableCharacterLayersRecursive(
      characterId,
    );
    final expressions = <String>{};

    for (final layer in layers) {
      if (layer.isEmpty) {
        continue;
      }
      expressions.add(layer);
    }

    final result = expressions.toList()
      ..sort((a, b) {
        final aIsPose = a.toLowerCase().startsWith('pose');
        final bIsPose = b.toLowerCase().startsWith('pose');
        if (aIsPose != bIsPose) {
          return aIsPose ? -1 : 1;
        }
        return a.compareTo(b);
      });
    return result;
  }

  Future<Map<String, String>> _buildExpressionImagePaths(
    String characterId,
    String currentPose,
    List<String> expressions,
  ) async {
    final result = <String, String>{};
    for (final expression in expressions) {
      final resolved = await _resolveExpressionPreviewImage(
        characterId: characterId,
        currentPose: currentPose,
        expression: expression,
      );
      if (resolved != null && resolved.isNotEmpty) {
        result[expression] = resolved;
      }
    }
    return result;
  }

  Future<String?> _resolveExpressionPreviewImage({
    required String characterId,
    required String currentPose,
    required String expression,
  }) async {
    final isPose = expression.toLowerCase().startsWith('pose');
    final pose = isPose ? expression : currentPose;
    final exp = isPose ? 'normal' : expression;

    final candidates = <String>[
      'characters/$characterId-$pose',
      'characters/$characterId-$exp',
      'characters/$characterId-$pose-$exp',
      'characters/$characterId-$expression',
    ];
    for (final candidate in candidates) {
      final found = await AssetManager().findAsset(candidate);
      if (found != null && found.isNotEmpty) {
        return found;
      }
    }
    return null;
  }

  Future<List<CommandWheelOption>> _buildCharacterWheelOptions() async {
    final options = <CommandWheelOption>[];
    final seen = <String>{};
    final state = _gameManager.currentState;
    final configEntries = _gameManager.characterConfigs.entries.toList();

    for (final entry in configEntries) {
      final characterKey = entry.key;
      final cfg = entry.value;
      if (cfg.resourceId == 'narrator') {
        continue;
      }
      if (!seen.add(characterKey)) {
        continue;
      }
      final preview = await _resolveCharacterPreviewImage(
        resourceId: cfg.resourceId,
        pose: _resolveCurrentPoseForResource(cfg.resourceId),
      );
      options.add(
        CommandWheelOption(
          id: characterKey,
          label: cfg.name.isNotEmpty ? cfg.name : characterKey,
          imagePath: preview,
        ),
      );
    }

    for (final entry in state.characters.entries) {
      final characterState = entry.value;
      final resourceId = characterState.resourceId;
      if (resourceId == 'narrator') {
        continue;
      }
      final key = _resolveCharacterKeyByResourceId(resourceId) ?? entry.key;
      if (!seen.add(key)) {
        continue;
      }
      final preview = await _resolveCharacterPreviewImage(
        resourceId: resourceId,
        pose: characterState.pose ?? 'pose1',
      );
      options.add(
        CommandWheelOption(
          id: key,
          label: _resolveCharacterDisplayName(key, resourceId),
          imagePath: preview,
        ),
      );
    }

    options.sort((a, b) => a.label.compareTo(b.label));
    return <CommandWheelOption>[
      const CommandWheelOption(id: _narratorWheelId, label: '旁白'),
      ...options,
    ];
  }

  String? _resolveCharacterKeyByResourceId(String resourceId) {
    for (final entry in _gameManager.characterConfigs.entries) {
      if (entry.value.resourceId == resourceId) {
        return entry.key;
      }
    }
    return null;
  }

  String _resolveCharacterDisplayName(String characterKey, String resourceId) {
    final cfg = _gameManager.characterConfigs[characterKey];
    if (cfg != null && cfg.name.isNotEmpty) {
      return cfg.name;
    }
    return characterKey.isNotEmpty ? characterKey : resourceId;
  }

  String _resolveCurrentPoseForResource(String resourceId) {
    final state = _gameManager.currentState;
    for (final entry in state.characters.entries) {
      if (entry.value.resourceId == resourceId) {
        return entry.value.pose ?? 'pose1';
      }
    }
    return 'pose1';
  }

  Future<String?> _resolveCharacterPreviewImage({
    required String resourceId,
    required String pose,
  }) async {
    final candidates = <String>[
      'characters/$resourceId-$pose',
      'characters/$resourceId-normal',
      'characters/$resourceId-pose1',
      'characters/$resourceId',
      'items/$resourceId',
    ];
    for (final candidate in candidates) {
      final found = await AssetManager().findAsset(candidate);
      if (found != null && found.isNotEmpty) {
        return found;
      }
    }
    return null;
  }

  String? _resolveCurrentCharacterWheelId(List<CommandWheelOption> options) {
    final currentSpeakerAlias = _gameManager.currentState.speakerAlias;
    final currentSpeakerName = _gameManager.currentState.speaker;
    if ((currentSpeakerAlias == null || currentSpeakerAlias.isEmpty) &&
        (currentSpeakerName == null || currentSpeakerName.isEmpty) &&
        options.any((o) => o.id == _narratorWheelId)) {
      return _narratorWheelId;
    }
    if (currentSpeakerAlias != null &&
        currentSpeakerAlias.isNotEmpty &&
        options.any((o) => o.id == currentSpeakerAlias)) {
      return currentSpeakerAlias;
    }
    if (currentSpeakerName != null && currentSpeakerName.isNotEmpty) {
      for (final entry in _gameManager.characterConfigs.entries) {
        if (entry.value.name == currentSpeakerName &&
            options.any((o) => o.id == entry.key)) {
          return entry.key;
        }
      }
    }
    return options.isNotEmpty ? options.first.id : null;
  }

  Future<List<CommandWheelOption>> _buildBackgroundGridOptions() async {
    const primaryDir = 'Assets/images/backgrounds/';
    const legacyDir = 'assets/images/backgrounds/';
    final files = await AssetManager().listAssets(primaryDir, '.png');
    final imageFiles = <String>{
      ...files,
      ...await AssetManager().listAssets(primaryDir, '.jpg'),
      ...await AssetManager().listAssets(primaryDir, '.jpeg'),
      ...await AssetManager().listAssets(primaryDir, '.webp'),
      ...await AssetManager().listAssets(primaryDir, '.avif'),
      ...await AssetManager().listAssets(primaryDir, '.bmp'),
      // 向后兼容旧写法，避免项目路径大小写/前缀差异导致扫空。
      ...await AssetManager().listAssets(legacyDir, '.png'),
      ...await AssetManager().listAssets(legacyDir, '.jpg'),
      ...await AssetManager().listAssets(legacyDir, '.jpeg'),
      ...await AssetManager().listAssets(legacyDir, '.webp'),
      ...await AssetManager().listAssets(legacyDir, '.avif'),
      ...await AssetManager().listAssets(legacyDir, '.bmp'),
    };
    final supported = <String>{
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.avif',
      '.bmp',
    };
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: background scan files=${imageFiles.length}, samples=${imageFiles.take(6).join(',')}',
      );
    }
    final options = <CommandWheelOption>[];
    final module = widget.gameModule ?? DefaultGameModule();
    for (final fileName in imageFiles) {
      final lower = fileName.toLowerCase();
      if (!supported.any((ext) => lower.endsWith(ext))) {
        continue;
      }
      final base = fileName.substring(
        0,
        fileName.length - fileName.split('.').last.length - 1,
      );
      final resolved = await AssetManager().findAsset('backgrounds/$base');
      if (resolved == null || resolved.isEmpty) {
        if (kSakiDiagnosticLogs) {
          print('ExpressionWheel: background preview missing for $base');
        }
        continue;
      }
      final displayName = module.resolveBackgroundDisplayName(base);
      options.add(
        CommandWheelOption(
          id: base,
          label: displayName.isNotEmpty ? displayName : base,
          imagePath: resolved,
        ),
      );
    }
    options.sort((a, b) => a.label.compareTo(b.label));
    return options;
  }

  Future<List<CommandWheelOption>> _buildMusicGridOptions() async {
    const primaryDir = 'Assets/music/';
    const legacyDir = 'assets/music/';
    final audioFiles = <String>{
      ...await AssetManager().listAssets(primaryDir, '.mp3'),
      ...await AssetManager().listAssets(primaryDir, '.ogg'),
      ...await AssetManager().listAssets(primaryDir, '.wav'),
      ...await AssetManager().listAssets(primaryDir, '.flac'),
      ...await AssetManager().listAssets(primaryDir, '.m4a'),
      ...await AssetManager().listAssets(legacyDir, '.mp3'),
      ...await AssetManager().listAssets(legacyDir, '.ogg'),
      ...await AssetManager().listAssets(legacyDir, '.wav'),
      ...await AssetManager().listAssets(legacyDir, '.flac'),
      ...await AssetManager().listAssets(legacyDir, '.m4a'),
    };
    final supported = <String>{'.mp3', '.ogg', '.wav', '.flac', '.m4a'};
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: music scan files=${audioFiles.length}, samples=${audioFiles.take(8).join(',')}',
      );
    }
    final options = <CommandWheelOption>[];
    for (final fileName in audioFiles) {
      final lower = fileName.toLowerCase();
      if (!supported.any((ext) => lower.endsWith(ext))) {
        continue;
      }
      final dot = fileName.lastIndexOf('.');
      if (dot <= 0) {
        continue;
      }
      final base = fileName.substring(0, dot).trim();
      final id = fileName.trim();
      if (id.isEmpty || base.isEmpty) {
        continue;
      }
      options.add(CommandWheelOption(id: id, label: base));
    }
    options.sort((a, b) => a.label.compareTo(b.label));
    return options;
  }

  String? _resolveCurrentBackgroundOptionId(
    List<CommandWheelOption> options,
    String currentBackgroundRaw,
  ) {
    if (currentBackgroundRaw.isEmpty) {
      return options.isNotEmpty ? options.first.id : null;
    }
    final normalized = currentBackgroundRaw
        .split('/')
        .last
        .split('.')
        .first
        .trim();
    for (final option in options) {
      if (option.id == normalized ||
          option.id == currentBackgroundRaw ||
          currentBackgroundRaw.contains(option.id)) {
        return option.id;
      }
    }
    return options.isNotEmpty ? options.first.id : null;
  }

  String? _resolveCurrentMusicOptionId(
    List<CommandWheelOption> options,
    String currentMusicAssetPath,
  ) {
    if (options.isEmpty) {
      return null;
    }
    if (currentMusicAssetPath.trim().isEmpty) {
      return null;
    }
    final fileName = currentMusicAssetPath.split('/').last.trim();
    final dot = fileName.lastIndexOf('.');
    final normalized = dot > 0 ? fileName.substring(0, dot) : fileName;
    for (final option in options) {
      final optionFile = option.id.trim();
      final optionDot = optionFile.lastIndexOf('.');
      final optionBase = optionDot > 0
          ? optionFile.substring(0, optionDot)
          : optionFile;
      if (optionFile == fileName ||
          optionBase == normalized ||
          currentMusicAssetPath.contains(option.id)) {
        return option.id;
      }
    }
    return null;
  }

  String _buildMusicAssetPathFromOptionId(String optionId) {
    final trimmed = optionId.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    if (trimmed.contains('.')) {
      return 'Assets/music/$trimmed';
    }
    return 'Assets/music/$trimmed.mp3';
  }

  Future<void> _previewMusicSelectionIfNeeded(String? optionId) async {
    if (!_showMusicGridMenu) {
      return;
    }
    if (optionId == null || optionId.isEmpty) {
      return;
    }
    if (_musicPreviewPlayingId == optionId) {
      return;
    }
    final assetPath = _buildMusicAssetPathFromOptionId(optionId);
    if (assetPath.isEmpty) {
      return;
    }
    if (kSakiDiagnosticLogs) {
      print('ExpressionWheel: music preview -> $optionId ($assetPath)');
    }
    try {
      await MusicManager().playBackgroundMusic(
        assetPath,
        fadeTransition: false,
      );
      _musicPreviewPlayingId = optionId;
    } catch (e) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: music preview failed: $e');
      }
    }
  }

  Future<void> _restoreMusicPreviewIfNeeded() async {
    await _restoreMusicToOriginal(
      originalAssetPath: _musicGridOriginalAssetPath,
      previewId: _musicPreviewPlayingId,
    );
  }

  Future<void> _restoreMusicToOriginal({
    required String? originalAssetPath,
    required String? previewId,
  }) async {
    if (previewId == null || previewId.isEmpty) {
      return;
    }
    if (originalAssetPath == null || originalAssetPath.isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: restore music preview -> stop');
      }
      await MusicManager().stopBackgroundMusic(fadeOut: false);
      return;
    }
    if (kSakiDiagnosticLogs) {
      print('ExpressionWheel: restore music preview -> $originalAssetPath');
    }
    await MusicManager().playBackgroundMusic(
      originalAssetPath,
      fadeTransition: false,
    );
  }

  Future<void> _applyExpressionWheelSelectionAndClose() async {
    final speakerInfo = _expressionWheelSpeakerInfo;
    final selectedExpression = _expressionWheelHighlightedExpression;
    _clearCommandMenuState();
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: apply requested selected=$selectedExpression speaker=${speakerInfo?.speakerName}/${speakerInfo?.characterId}',
      );
    }

    if (speakerInfo == null ||
        selectedExpression == null ||
        selectedExpression.isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: apply skipped (missing speaker or selection)');
      }
      return;
    }
    if (selectedExpression == speakerInfo.currentExpression) {
      if (!selectedExpression.toLowerCase().startsWith('pose')) {
        if (kSakiDiagnosticLogs) {
          print(
            'ExpressionWheel: apply skipped (expression unchanged: $selectedExpression)',
          );
        }
        return;
      }
    }

    if (selectedExpression == speakerInfo.currentPose &&
        selectedExpression.toLowerCase().startsWith('pose')) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: apply skipped (pose unchanged: $selectedExpression)',
        );
      }
      return;
    }

    final selectedIsPose = selectedExpression.toLowerCase().startsWith('pose');
    final nextPose = selectedIsPose
        ? selectedExpression
        : speakerInfo.currentPose;
    final nextExpression = selectedIsPose
        ? speakerInfo.currentExpression
        : selectedExpression;
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: apply -> nextPose=$nextPose, nextExpression=$nextExpression',
      );
    }

    await _expressionSelectorManager?.handleExpressionSelectionChanged(
      speakerInfo.characterId,
      nextPose,
      nextExpression,
      speakerInfo.currentAnimation,
    );
  }

  Future<void> _applyCharacterWheelSelectionAndClose() async {
    final selectedCharacterKey = _characterWheelHighlightedId;
    final currentCharacterKey = _characterWheelCurrentId;
    String selectedLabel = selectedCharacterKey ?? '';
    if (selectedCharacterKey != null) {
      for (final option in _characterWheelOptions) {
        if (option.id == selectedCharacterKey) {
          selectedLabel = option.label;
          break;
        }
      }
    }
    _clearCommandMenuState();
    if (selectedCharacterKey == null || selectedCharacterKey.isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: apply character skipped (empty selection)');
      }
      return;
    }
    if (selectedCharacterKey == currentCharacterKey) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: apply character skipped (selection unchanged: $selectedCharacterKey)',
        );
      }
      return;
    }
    final success = await _applyCharacterChangeForCurrentDialogue(
      selectedCharacterKey,
    );
    if (success) {
      _showNotificationMessage('已切换角色: $selectedLabel');
      await _handleHotReload();
    } else {
      _showNotificationMessage('角色切换失败');
    }
  }

  Future<void> _applyBackgroundGridSelectionAndClose() async {
    final selectedBackground = _backgroundGridHighlightedId;
    _clearCommandMenuState();
    if (selectedBackground == null || selectedBackground.isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: apply background skipped (empty selection)');
      }
      return;
    }
    final success = await _applyBackgroundChangeForCurrentDialogue(
      selectedBackground,
    );
    if (success) {
      // 先即时更新当前画面，再触发脚本热重载，避免“改了但仍显示旧背景”的感知延迟。
      _gameManager.applyDebugBackgroundImmediately(selectedBackground);
      _showNotificationMessage('已切换背景: $selectedBackground');
      await _handleHotReload();
    } else {
      _showNotificationMessage('背景切换失败');
    }
  }

  void _previewCanvasSelection(String canvasId) {
    if (!_showCanvasGridMenu || canvasId.trim().isEmpty) {
      return;
    }
    if (_gameManager.currentState.scriptCanvasId == canvasId &&
        _gameManager.currentState.scriptCanvasDurationSeconds <= 0) {
      return;
    }
    _gameManager.applyDebugCanvasImmediately(canvasId);
  }

  void _restoreCanvasPreviewIfNeeded() {
    if (!_showCanvasGridMenu) {
      return;
    }
    final originalId = _canvasGridOriginalId;
    if (_gameManager.currentState.scriptCanvasId == originalId &&
        _gameManager.currentState.scriptCanvasDurationSeconds <= 0) {
      return;
    }
    _gameManager.applyDebugCanvasImmediately(originalId);
  }

  Future<void> _applyCanvasGridSelectionAndClose() async {
    final selectedCanvas = _canvasGridHighlightedId;
    if (selectedCanvas == null || selectedCanvas.isEmpty) {
      _clearCommandMenuState();
      return;
    }

    final previousCanvas = _canvasGridOriginalId;
    // Treat the selected canvas as the new restore target while the source
    // rewrite and hot reload complete.
    _canvasGridOriginalId = selectedCanvas;
    _clearCommandMenuState();
    final success = await _applyCanvasChangeForCurrentDialogue(selectedCanvas);
    if (success) {
      _gameManager.applyDebugCanvasImmediately(selectedCanvas);
      _showNotificationMessage('已放置 Canvas: $selectedCanvas');
      await _handleHotReload();
    } else {
      _gameManager.applyDebugCanvasImmediately(previousCanvas);
      _showNotificationMessage('Canvas 放置失败');
    }
  }

  Future<void> _applyMusicGridSelectionAndClose() async {
    final selectedMusic = _musicGridHighlightedId;
    final currentMusic = _musicGridCurrentId;
    final originalAssetPath = _musicGridOriginalAssetPath;
    final previewId = _musicPreviewPlayingId;
    _clearCommandMenuState();
    if (selectedMusic == null || selectedMusic.isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: apply music skipped (empty selection)');
      }
      await _restoreMusicToOriginal(
        originalAssetPath: originalAssetPath,
        previewId: previewId,
      );
      return;
    }
    if (selectedMusic == currentMusic) {
      if (kSakiDiagnosticLogs) {
        print(
          'ExpressionWheel: apply music skipped (selection unchanged: $selectedMusic)',
        );
      }
      await _restoreMusicToOriginal(
        originalAssetPath: originalAssetPath,
        previewId: previewId,
      );
      return;
    }
    final success = await _applyMusicChangeForCurrentDialogue(selectedMusic);
    if (success) {
      _showNotificationMessage('已切换音乐: $selectedMusic');
      await _handleHotReload();
      return;
    }
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: apply music failed, rollback preview to $originalAssetPath',
      );
    }
    await _restoreMusicToOriginal(
      originalAssetPath: originalAssetPath,
      previewId: previewId,
    );
    _showNotificationMessage('音乐切换失败');
  }

  Future<bool> _applyCharacterChangeForCurrentDialogue(
    String selectedCharacterKey,
  ) async {
    final sourceScriptFile = _gameManager.currentDialogueSourceScriptFile;
    final scriptFileForWrite =
        (sourceScriptFile != null && sourceScriptFile.trim().isNotEmpty)
        ? sourceScriptFile
        : _gameManager.currentScriptFile;
    final scriptPath = await ScriptContentModifier.getCurrentScriptFilePath(
      scriptFileForWrite,
    );
    if (scriptPath == null) {
      return false;
    }

    final targetDialogue = _gameManager.currentDialogueText;
    final targetLine = _gameManager.currentDialogueSourceLine;
    if (targetDialogue.trim().isEmpty) {
      if (kSakiDiagnosticLogs) {
        print('ExpressionWheel: apply character aborted (empty dialogue)');
      }
      return false;
    }
    final writeCharacterId = selectedCharacterKey == _narratorWheelId
        ? ScriptContentModifier.narratorCharacterId
        : selectedCharacterKey;
    final currentSpeaker = _expressionSelectorManager?.getCurrentSpeakerInfo();
    final fallbackCharacter =
        currentSpeaker?.scriptCharacterKey ??
        _gameManager.currentState.speakerAlias;
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: apply character -> sourceScript=$sourceScriptFile, line=$targetLine, oldCharacter=$fallbackCharacter, newCharacter=$writeCharacterId, dialogue="$targetDialogue"',
      );
    }

    return ScriptContentModifier.modifyDialogueCharacterWithPose(
      scriptFilePath: scriptPath,
      targetDialogue: targetDialogue,
      oldCharacterId: fallbackCharacter,
      newCharacterId: writeCharacterId,
      targetLineNumber: targetLine,
    );
  }

  Future<bool> _applyBackgroundChangeForCurrentDialogue(
    String selectedBackground,
  ) async {
    final sourceScriptFile = _gameManager.currentDialogueSourceScriptFile;
    final scriptFileForWrite =
        (sourceScriptFile != null && sourceScriptFile.trim().isNotEmpty)
        ? sourceScriptFile
        : _gameManager.currentScriptFile;
    final scriptPath = await ScriptContentModifier.getCurrentScriptFilePath(
      scriptFileForWrite,
    );
    if (scriptPath == null) {
      return false;
    }
    final targetLine = _gameManager.currentDialogueSourceLine;
    return ScriptContentModifier.modifyBackgroundNearDialogue(
      scriptFilePath: scriptPath,
      targetLineNumber: targetLine,
      newBackground: selectedBackground,
    );
  }

  Future<bool> _applyMusicChangeForCurrentDialogue(String selectedMusic) async {
    final sourceScriptFile = _gameManager.currentDialogueSourceScriptFile;
    final scriptFileForWrite =
        (sourceScriptFile != null && sourceScriptFile.trim().isNotEmpty)
        ? sourceScriptFile
        : _gameManager.currentScriptFile;
    final scriptPath = await ScriptContentModifier.getCurrentScriptFilePath(
      scriptFileForWrite,
    );
    if (scriptPath == null) {
      return false;
    }
    final targetLine = _gameManager.currentDialogueSourceLine;
    if (kSakiDiagnosticLogs) {
      print(
        'ExpressionWheel: apply music -> script=$sourceScriptFile, line=$targetLine, music=$selectedMusic',
      );
    }
    return ScriptContentModifier.modifyMusicNearDialogue(
      scriptFilePath: scriptPath,
      targetLineNumber: targetLine,
      newMusic: selectedMusic,
    );
  }

  Future<bool> _applyCanvasChangeForCurrentDialogue(String canvasId) async {
    final sourceScriptFile = _gameManager.currentDialogueSourceScriptFile;
    final scriptFileForWrite =
        (sourceScriptFile != null && sourceScriptFile.trim().isNotEmpty)
        ? sourceScriptFile
        : _gameManager.currentScriptFile;
    final scriptPath = await ScriptContentModifier.getCurrentScriptFilePath(
      scriptFileForWrite,
    );
    if (scriptPath == null) {
      return false;
    }
    return ScriptContentModifier.modifyCanvasNearDialogue(
      scriptFilePath: scriptPath,
      targetLineNumber: _gameManager.currentDialogueSourceLine,
      canvasId: canvasId,
    );
  }

  void _clearCommandMenuState() {
    _expressionWheelOpenTimer?.cancel();
    _restoreCanvasPreviewIfNeeded();
    _setStateIfMounted(_resetCommandMenuFields);
    if (kSakiDiagnosticLogs) {
      print('ExpressionWheel: state cleared');
    }
  }

  void _dismissCommandMenuForEscape() {
    if (_showMusicGridMenu) {
      unawaited(_restoreMusicPreviewIfNeeded());
    }
    _clearCommandMenuState();
  }

  void _resetCommandMenuFields() {
    _showExpressionWheel = false;
    _showCharacterWheel = false;
    _showBackgroundGridMenu = false;
    _showCanvasGridMenu = false;
    _showMusicGridMenu = false;
    _activeCommandMenuMode = null;
    _expressionWheelSpeakerInfo = null;
    _expressionWheelExpressions = const [];
    _expressionWheelImagePaths = const {};
    _expressionWheelHighlightedExpression = null;
    _characterWheelOptions = const [];
    _characterWheelCurrentId = null;
    _characterWheelHighlightedId = null;
    _backgroundGridOptions = const [];
    _backgroundGridCurrentId = null;
    _backgroundGridHighlightedId = null;
    _canvasGridOptions = const [];
    _canvasGridCurrentId = null;
    _canvasGridHighlightedId = null;
    _canvasGridOriginalId = null;
    _musicGridOptions = const [];
    _musicGridCurrentId = null;
    _musicGridHighlightedId = null;
    _musicGridOriginalAssetPath = null;
    _musicPreviewPlayingId = null;
    _expressionWheelCenter = null;
  }

  // 设置console按键序列检测器（发行版也可用，方便玩家复制日志）
  void _setupConsoleSequenceDetector() {
    // 定义 c-o-n-s-o-l-e 按键序列
    final consoleSequence = [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyO,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyE,
    ];

    _consoleSequenceDetector = KeySequenceDetector(
      sequence: consoleSequence,
      onSequenceComplete: () {
        _setStateIfMounted(() {
          _showDebugPanel = !_showDebugPanel;
        });
        if (mounted) {
          _showNotificationMessage('调试面板 ${_showDebugPanel ? '开启' : '关闭'}');
        }
      },
      sequenceTimeout: const Duration(seconds: 3),
      shouldIgnore: () =>
          _showFloatingScriptEditor ||
          _showDeveloperPanel ||
          _showExpressionSelector ||
          _showDebugPanel ||
          _showSettings,
    );

    _consoleSequenceDetector!.startListening();

    sakiDiagnosticLog('Console按键序列检测器已启动 (c-o-n-s-o-l-e)');
  }

  // 设置快进管理器
  void _setupFastForwardManager() {
    _fastForwardManager = FastForwardManager(
      dialogueProgressionManager: _dialogueProgressionManager,
      onFastForwardStateChanged: (isFastForwarding) {
        // 使用post frame callback延迟处理，避免在build期间调用setState
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _setStateIfMounted(() {
            _isFastForwarding = isFastForwarding;
          });
        });
      },
      canFastForward: () {
        // 检查是否有弹窗或菜单显示，如果有则不能快进
        final hasOverlayOpen =
            _isShowingMenu ||
            _showSaveOverlay ||
            _showLoadOverlay ||
            _showReviewOverlay ||
            _showSettings ||
            _showDeveloperPanel ||
            _showDebugPanel ||
            _showExpressionSelector ||
            _showFloatingScriptEditor ||
            _isAnyCommandMenuOpen;
        return !hasOverlayOpen && !_isBlockingCinematicInput;
      },
      setGameManagerFastForward: (isFastForwarding) {
        // 通知GameManager快进状态变化
        _gameManager.setFastForwardMode(isFastForwarding);
      },
    );

    _fastForwardManager!.startListening();
    sakiDiagnosticLog('快进管理器已初始化 - 按住Command/Ctrl键可强制快进对话');
  }

  // 设置已读文本跟踪
  void _setupReadTextTracking() async {
    // 初始化已读文本跟踪器
    await ReadTextTracker.instance.initialize();

    // 初始化已读文本快进管理器
    _readTextSkipManager = ReadTextSkipManager(
      gameManager: _gameManager,
      dialogueProgressionManager: _dialogueProgressionManager,
      readTextTracker: ReadTextTracker.instance,
      onSkipStateChanged: (isSkipping) {
        // 更新UI状态
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _setStateIfMounted(() {
            _isFastForwarding = isSkipping; // 同步快进状态到UI
          });
        });
      },
      canSkip: () {
        // 检查是否有弹窗或菜单显示，如果有则不能快进
        final hasOverlayOpen =
            _isShowingMenu ||
            _showSaveOverlay ||
            _showLoadOverlay ||
            _showReviewOverlay ||
            _showSettings ||
            _showDeveloperPanel ||
            _showDebugPanel ||
            _showExpressionSelector ||
            _showFloatingScriptEditor ||
            _isAnyCommandMenuOpen;
        return !hasOverlayOpen && !_isBlockingCinematicInput;
      },
    );

    sakiDiagnosticLog('已读文本跟踪器已初始化');
  }

  // 设置鼠标滚轮处理器
  void _setupMouseWheelHandler() {
    _mouseWheelHandler = MouseWheelHandler(
      onScrollForward: () {
        // 选项界面允许滚轮事件进入以支持“回滚->观看记录”，
        // 但前滚推进剧情在选项界面仍需禁用。
        final hasOverlayOpen =
            _isShowingMenu ||
            _showSaveOverlay ||
            _showLoadOverlay ||
            _showReviewOverlay ||
            _showSettings ||
            _showDeveloperPanel ||
            _showDebugPanel ||
            _showExpressionSelector ||
            _showFloatingScriptEditor ||
            _isAnyCommandMenuOpen;
        if (hasOverlayOpen || _isBlockingCinematicInput) {
          return;
        }
        // 向前滚动: 推进对话
        _dialogueProgressionManager.progressDialogue();
        _autoPlayManager?.onManualProgress();
      },
      onScrollBackward: () {
        // 向后滚动: 根据设置执行行为
        unawaited(_handleMouseRollbackAction());
      },
      shouldHandleScroll: () {
        // 选项界面不再阻止滚轮回滚，以便唤起观看记录。
        // 这里仍阻止其他弹窗，避免误触。
        final hasOverlayOpen =
            _showSaveOverlay ||
            _showLoadOverlay ||
            _showReviewOverlay ||
            _showSettings ||
            _showDeveloperPanel ||
            _showDebugPanel ||
            _showExpressionSelector ||
            _showFloatingScriptEditor ||
            _isAnyCommandMenuOpen;

        final isUIHidden = GlobalRightClickUIManager().isUIHidden;

        // 隐藏 UI 后滚轮与触控板手势专用于查看画面，不得推进或回滚剧情。
        return !hasOverlayOpen && !_isBlockingCinematicInput && !isUIHidden;
      },
    );
  }

  // 设置自动播放管理器
  void _setupAutoPlayManager() {
    _autoPlayManager = AutoPlayManager(
      dialogueProgressionManager: _dialogueProgressionManager,
      onAutoPlayStateChanged: () {
        // 使用post frame callback延迟处理，避免在build期间调用setState
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _setStateIfMounted(() {
            _isAutoPlaying = _autoPlayManager!.isAutoPlaying;
            // 同步到GameManager
            _gameManager.setAutoPlayMode(_isAutoPlaying);
          });
        });
      },
      canAutoPlay: () {
        // 检查是否有弹窗或菜单显示，如果有则不能自动播放
        final hasOverlayOpen =
            _isShowingMenu ||
            _showSaveOverlay ||
            _showLoadOverlay ||
            _showReviewOverlay ||
            _showSettings ||
            _showDeveloperPanel ||
            _showDebugPanel ||
            _showExpressionSelector ||
            _isAnyCommandMenuOpen ||
            _isFastForwarding; // 快进时不能自动播放
        return !hasOverlayOpen && !_isBlockingCinematicInput;
      },
    );

    sakiDiagnosticLog('自动播放管理器已初始化');
  }

  // 处理跳过已读文本
  void _handleSkipReadText() async {
    print('🎯 快进按钮被点击');

    // 获取快进模式设置
    final fastForwardMode = await SettingsManager().getFastForwardMode();
    print('🎯 当前快进模式: $fastForwardMode');

    if (fastForwardMode == 'force') {
      // 强制快进模式：使用FastForwardManager
      print(
        '🎯 使用强制快进模式 - _fastForwardManager: ${_fastForwardManager?.hashCode}',
      );
      _fastForwardManager?.toggleFastForward();
    } else {
      // 快进已读模式：使用ReadTextSkipManager
      print(
        '🎯 使用快进已读模式 - _readTextSkipManager: ${_readTextSkipManager?.hashCode}',
      );
      _readTextSkipManager?.toggleSkipping();
    }
  }

  // 获取当前有效的快进状态
  bool _getCurrentFastForwardState() {
    // 返回任意一个快进管理器的活动状态
    return (_fastForwardManager?.isFastForwarding ?? false) ||
        (_readTextSkipManager?.isSkipping ?? false);
  }

  // 处理自动播放
  void _handleAutoPlay() {
    print('🎯 自动播放按钮被点击 - _autoPlayManager: ${_autoPlayManager?.hashCode}');
    _autoPlayManager?.toggleAutoPlay();
  }

  // 新增：处理快速存档
  Future<void> _handleQuickSave() async {
    try {
      final saveLoadManager = SaveLoadManager();
      final snapshot = _gameManager.saveStateSnapshot();
      final poseConfigs = _gameManager.poseConfigs;
      final currentScriptFile = _gameManager.currentScriptFile;
      final gameModule = widget.gameModule ?? DefaultGameModule();
      final quickSaveNamespace = gameModule.quickSaveNamespaceForScript(
        currentScriptFile,
      );

      await saveLoadManager.quickSave(
        currentScriptFile,
        snapshot,
        poseConfigs,
        namespace: quickSaveNamespace,
      );
      _showNotificationMessage('快速存档成功');
    } catch (e) {
      _showNotificationMessage('快速存档失败: $e');
    }
  }

  // 显示通知消息
  void _showNotificationMessage(String message) {
    // 调用GameUILayer的showNotification方法
    _gameUILayerKey.currentState?.showNotification(message);
  }

  Future<void> _handleHotReload() async {
    await _gameManager.hotReload(_currentScript);
    _showNotificationMessage('重载完成');
  }

  Future<void> _jumpToHistoryEntry(DialogueHistoryEntry entry) async {
    _setStateIfMounted(() => _showReviewOverlay = false);
    await _gameManager.jumpToHistoryEntry(entry, _currentScript);
    _showNotificationMessage('跳转成功');
  }

  Future<void> _jumpToHistoryEntryQuiet(DialogueHistoryEntry entry) async {
    await _gameManager.jumpToHistoryEntry(entry, _currentScript);
  }

  Future<bool> _onWillPop() async {
    return await ExitConfirmationDialog.showExitConfirmation(
      context,
      hasProgress: true,
    );
  }
}
