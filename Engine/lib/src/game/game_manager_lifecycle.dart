part of 'game_manager.dart';

extension _GameManagerLifecycle on GameManager {
  Future<void> _loadConfigs() async {
    final charactersContent = await AssetManager()
        .loadString('assets/GameScript/configs/characters.sks');
    _characterConfigs = ConfigParser().parseCharacters(charactersContent);

    final posesContent =
        await AssetManager().loadString('assets/GameScript/configs/poses.sks');
    _poseConfigs = ConfigParser().parsePoses(posesContent);

    // 初始化差分偏移管理器
    ExpressionOffsetManager().initializeDefaultConfigs();
    CharacterCompositeCache.instance.clear();
  }

  Future<void> _startGameLifecycle(String scriptName) async {
    // 平滑清除主菜单音乐
    await MusicManager().clearBackgroundMusic(
      fadeOut: true,
      fadeDuration: const Duration(milliseconds: 1000),
    );

    await _loadConfigs();
    await GlobalVariableManager().init(); // 初始化全局变量管理器

    // 初始化剧情流程图管理器
    await _flowchartManager.initialize();

    // 初始化CG预分析器
    _cgPreAnalyzer.initialize();

    await AnimationManager.loadAnimations(); // 加载动画
    _script = await _scriptMerger.getMergedScript();
    _buildLabelIndexMap();
    _buildMusicRegions(); // 构建音乐区间

    // 分析脚本中的所有CG组合并预热
    _analyzeCgCombinationsAndPreWarm(isLoadGame: false);

    // 启动CG预热管理器
    CgPreWarmManager().start();

    // 预加载anime资源（同步执行，确保能看到错误）
    try {
      await _analyzeAndPreloadAnimeResources();
    } catch (e) {
      if (kEngineDebugMode) {
        ////print('[GameManager] 预加载anime资源失败: $e');
      }
    }

    _currentState = GameState.initial();
    _dialogueHistory = [];
    _activeNvlContext = _NvlContextMode.none;
    _showNvlOverlayOnNextDialogue = false;

    // 如果指定了非 start 脚本，跳转到对应位置
    if (scriptName != 'start') {
      final startIndex = _scriptMerger.getFileStartIndex(scriptName);
      if (startIndex != null) {
        _scriptIndex = startIndex;
      }
    }

    // 检查初始位置的音乐区间
    await _checkMusicRegionAtCurrentIndex(forceCheck: true);

    await _executeScript();
  }

  Future<void> _restoreFromSnapshotLifecycle(
      String scriptName, GameStateSnapshot snapshot,
      {bool shouldReExecute = true}) async {
    //print('📚 restoreFromSnapshot: scriptName = $scriptName');
    //print('📚 restoreFromSnapshot: snapshot.scriptIndex = ${snapshot.scriptIndex}');
    //print('📚 restoreFromSnapshot: isNvlMode = ${snapshot.isNvlMode}');
    //print('📚 restoreFromSnapshot: nvlDialogues count = ${snapshot.nvlDialogues.length}');

    await _loadConfigs();
    await GlobalVariableManager().init(); // 初始化全局变量管理器
    await AnimationManager.loadAnimations(); // 加载动画
    _script = await _scriptMerger.getMergedScript();
    _buildLabelIndexMap();
    _buildMusicRegions(); // 构建音乐区间

    //print('📚 加载合并脚本后: _script.children.length = ${_script.children.length}');

    _scriptIndex = snapshot.scriptIndex;

    // 分析脚本中的所有CG组合并预热（在恢复索引后）
    _analyzeCgCombinationsAndPreWarm(isLoadGame: true);

    // 预加载anime资源（同步执行）
    try {
      await _analyzeAndPreloadAnimeResources();
    } catch (e) {
      if (kEngineDebugMode) {
        ////print('[GameManager] 存档恢复：预加载anime资源失败: $e');
      }
    }

    // 重置所有处理标志，确保恢复状态时没有遗留的锁定状态
    _isProcessing = false;
    _isWaitingForTimer = false;

    // 修复快进回退bug：强制重置快进状态为非快进
    // 回退到历史状态时，应该始终处于正常播放模式，而不是快进模式
    setFastForwardMode(false);

    // 取消当前活跃的计时器
    _currentTimer?.cancel();
    _currentTimer = null;
    _currentTimerCompletion = null;

    // 清理旧的场景动画控制器
    _sceneAnimationController?.dispose();
    _sceneAnimationController = null;

    // 恢复 NVL 状态
    if (kEngineDebugMode) {
      //print('[GameManager] 存档恢复：cgCharacters数量 = ${snapshot.currentState.cgCharacters.length}');
      //print('[GameManager] 存档恢复：cgCharacters内容 = ${snapshot.currentState.cgCharacters.keys.toList()}');
    }

    // 修复bug：从新脚本中获取当前对话文本，避免使用存档中的旧文本
    // 使用 NvlStateManager 来处理 NVL 模式的特殊逻辑
    String? freshDialogue;
    String? freshDialogueTag;
    String? freshSpeaker;
    List<NvlDialogue>? freshNvlDialogues;

    // NVL模式：使用模块化的状态管理器
    freshNvlDialogues = NvlStateManager.restoreNvlDialogues(
      snapshot: snapshot,
      script: _script,
      characterConfigs: _characterConfigs,
      scriptIndex: _scriptIndex,
    );

    // 非NVL模式：刷新当前对话
    // 注意：_scriptIndex 在大多数存档中已经指向“下一条指令”，
    // 当前显示句应优先取历史记录最后一句对应的脚本索引。
    final displayedDialogueScriptIndex = snapshot.dialogueHistory.isNotEmpty
        ? snapshot.dialogueHistory.last.scriptIndex
        : (_scriptIndex > 0 ? _scriptIndex - 1 : _scriptIndex);

    if (!snapshot.isNvlMode) {
      final dialogueScriptIndex = displayedDialogueScriptIndex;

      if (dialogueScriptIndex >= 0 &&
          dialogueScriptIndex < _script.children.length) {
        final currentNode = _script.children[dialogueScriptIndex];
        if (currentNode is SayNode) {
          freshDialogue = _resolveScriptText(currentNode.dialogue);
          freshDialogueTag = currentNode.dialogueTag;
          if (currentNode.character != null) {
            final characterConfig = _characterConfigs[currentNode.character];
            freshSpeaker = characterConfig?.name;
          }
        }
      }
    }

    _currentState = snapshot.currentState.copyWith(
      isNvlMode: snapshot.isNvlMode,
      isNvlMovieMode: snapshot.isNvlMovieMode,
      isNvlnMode: snapshot.isNvlnMode, // 新增：恢复无遮罩NVL模式状态
      isNvlOverlayVisible: snapshot.isNvlOverlayVisible,
      nvlDialogues: freshNvlDialogues ?? snapshot.nvlDialogues,
      everShownCharacters: _everShownCharacters,
      isFastForwarding: false, // 修复快进回退bug：强制设置为非快进状态
      // 明确恢复CG角色状态（修复CG存档恢复bug）
      cgCharacters: snapshot.currentState.cgCharacters,
      // 修复bug：使用从新脚本获取的对话文本
      dialogue: freshDialogue ?? snapshot.currentState.dialogue,
      dialogueTag: freshDialogueTag ?? snapshot.currentState.dialogueTag,
      speaker: freshSpeaker ?? snapshot.currentState.speaker,
    );

    // 设置NVL上下文模式
    _activeNvlContext = snapshot.isNvlMode
        ? (snapshot.isNvlMovieMode
            ? _NvlContextMode.movie
            : (snapshot.isNvlnMode
                ? _NvlContextMode.noMask
                : _NvlContextMode.standard))
        : _NvlContextMode.none;
    _showNvlOverlayOnNextDialogue = false;

    // 初始化CG渲染器的淡入状态，避免恢复存档后首次差分出现全透明
    for (final entry in _currentState.cgCharacters.entries) {
      final displayKey = entry.key;
      final state = entry.value;
      final pose = state.pose ?? 'pose1';
      final expression = state.expression ?? 'happy';
      await CompositeCgRenderer.initializeDisplayedCg(
        displayKey: displayKey,
        resourceId: state.resourceId,
        pose: pose,
        expression: expression,
      );
    }

    if (snapshot.dialogueHistory.isNotEmpty) {
      _dialogueHistory = List.from(snapshot.dialogueHistory);
      // 修复bug：从新脚本中重新获取对话文本，确保剧本修改后读档时显示最新内容
      _refreshDialogueHistoryFromScript();
    }

    // 修复bug：同时更新当前状态的对话文本
    // 但NVL模式不需要刷新，因为nvlDialogues已经在上面正确恢复了
    if (!snapshot.isNvlMode) {
      _refreshCurrentStateDialogue(
        dialogueScriptIndex: displayedDialogueScriptIndex,
      );
    }

    // 检查恢复位置的音乐区间（强制检查）
    await _checkMusicRegionAtCurrentIndex(forceCheck: true);

    // 检测并恢复当前场景的动画
    await _checkAndRestoreSceneAnimation(notifyListeners: false);

    // 预热当前游戏状态的CG（读档后立即预热，避免第一次显示黑屏）
    await _preWarmCurrentGameState();

    if (shouldReExecute) {
      // 预热完成后再推送状态，确保CG已准备好
      _gameStateController.add(_currentState);
      await _executeScript();
    } else {
      // 不重新执行脚本时，检查当前位置是否是MenuNode
      if (_scriptIndex < _script.children.length) {
        final currentNode = _script.children[_scriptIndex];
        if (currentNode is MenuNode) {
          // 如果当前位置是MenuNode，确保currentNode被正确设置
          _currentState = _currentState.copyWith(
            currentNode: currentNode,
            everShownCharacters: _everShownCharacters,
          );
          if (kEngineDebugMode) {
            //print('[GameManager] 存档恢复：检测到MenuNode，设置currentNode');
          }
        }
      }
      _gameStateController.add(_currentState);
    }
  }

  Future<void> _hotReloadLifecycle(String scriptName) async {
    if (_dialogueHistory.isNotEmpty) {
      _dialogueHistory.removeLast();
    }

    _savedSnapshot = saveStateSnapshot();

    // 清理缓存并重新合并脚本
    _scriptMerger.clearCache();
    AnimationManager.clearCache(); // 清除动画缓存
    SaveLoadManager.clearCache(); // 清除存档管理器的脚本缓存，确保对话预览使用最新脚本
    await _loadConfigs();
    await GlobalVariableManager().init(); // 初始化全局变量管理器
    await AnimationManager.loadAnimations(); // 加载动画
    _script = await _scriptMerger.getMergedScript();
    _buildLabelIndexMap();
    _buildMusicRegions(); // 构建音乐区间

    if (_savedSnapshot != null) {
      _scriptIndex = _savedSnapshot!.scriptIndex;
      _dialogueHistory = List.from(_savedSnapshot!.dialogueHistory);

      if (_scriptIndex > 0) {
        _scriptIndex--;
      }

      _currentState = _savedSnapshot!.currentState.copyWith(
        clearDialogueAndSpeaker: true,
        forceNullCurrentNode: true,
        // 恢复 NVL 状态
        isNvlMode: _savedSnapshot!.isNvlMode,
        isNvlMovieMode: _savedSnapshot!.isNvlMovieMode,
        isNvlnMode: _savedSnapshot!.isNvlnMode,
        isNvlOverlayVisible: _savedSnapshot!.isNvlOverlayVisible,
        nvlDialogues: _savedSnapshot!.nvlDialogues,
        everShownCharacters: _everShownCharacters,
        isFastForwarding: false, // 修复快进回退bug：强制设置为非快进状态
      );

      // 热重载时会回放当前显示句；若该句已被改为旁白，需要回滚旧句对子立绘的副作用。
      // 否则会出现“脚本已无说话人，但旧立绘仍停留”的状态残留。
      if (_scriptIndex >= 0 && _scriptIndex < _script.children.length) {
        final replayNode = _script.children[_scriptIndex];
        if (replayNode is SayNode && replayNode.character == null) {
          Map<String, CharacterState>? rollbackCharacters;

          if (_savedSnapshot!.dialogueHistory.length >= 2) {
            final previousDialogueState = _savedSnapshot!
                .dialogueHistory[_savedSnapshot!.dialogueHistory.length - 1]
                .stateSnapshot
                .currentState;
            rollbackCharacters = Map<String, CharacterState>.from(
              previousDialogueState.characters,
            );
            if (kEngineDebugMode) {
              print(
                  '[GameManager] HotReload: narration replay detected, rollback characters from previous dialogue snapshot.');
            }
          } else {
            // 历史不足时兜底：尝试移除旧的说话人立绘。
            final previousSpeakerAlias =
                _savedSnapshot!.currentState.speakerAlias;
            if (previousSpeakerAlias != null &&
                previousSpeakerAlias.isNotEmpty) {
              final fallbackCharacters = Map<String, CharacterState>.from(
                _savedSnapshot!.currentState.characters,
              );
              final speakerConfig = _characterConfigs[previousSpeakerAlias];
              final speakerRenderKey = _resolveCharacterRenderKey(
                previousSpeakerAlias,
                characterConfig: speakerConfig,
              );
              fallbackCharacters.remove(speakerRenderKey);
              rollbackCharacters = fallbackCharacters;
              if (kEngineDebugMode) {
                print(
                    '[GameManager] HotReload: narration replay fallback, removed previous speaker render key=$speakerRenderKey.');
              }
            }
          }

          if (rollbackCharacters != null) {
            _currentState = _currentState.copyWith(
              characters: rollbackCharacters,
              everShownCharacters: _everShownCharacters,
            );
          }
        }
      }

      // 设置NVL上下文模式
      _activeNvlContext = _savedSnapshot!.isNvlMode
          ? (_savedSnapshot!.isNvlMovieMode
              ? _NvlContextMode.movie
              : (_savedSnapshot!.isNvlnMode
                  ? _NvlContextMode.noMask
                  : _NvlContextMode.standard))
          : _NvlContextMode.none;
      _showNvlOverlayOnNextDialogue = false;

      _isProcessing = false;
      _isWaitingForTimer = false; // 重置计时器标志

      // 取消当前活跃的计时器
      _currentTimer?.cancel();
      _currentTimer = null;
      _currentTimerCompletion = null;

      // 清理旧的场景动画控制器
      _sceneAnimationController?.dispose();
      _sceneAnimationController = null;

      // 检测并恢复当前场景的动画
      await _checkAndRestoreSceneAnimation();

      await _executeScript();
    }
  }
}
