part of 'game_manager.dart';

extension _GameManagerChoiceSeek on GameManager {
  void _emitCurrentState() {
    if (!_disposed && !_isSeekingNextChoice) {
      _gameStateController.add(_currentState);
    }
  }

  /// A read-only check keeps a click with no following choice a no-op. Bool
  /// assignments are simulated locally. APIs may change conditions, so their
  /// subsequent branches are conservatively explored in both directions.
  bool _hasReachableChoice(int startIndex) {
    final variables = <String>{
      for (final node in _script.children)
        if (node is JumpNode && node.isConditional) node.conditionVariable!,
    }.toList()..sort();
    final initialValues = <String, bool?>{
      for (final name in variables)
        name: GlobalVariableManager().getBoolVariableSync(name),
    };
    final pending = [(startIndex, initialValues)];
    final visited = <(int, String)>{};
    while (pending.isNotEmpty) {
      var (index, values) = pending.removeLast();
      while (index >= 0 && index < _script.children.length) {
        final signature = variables.map((name) => values[name]).join(',');
        if (!visited.add((index, signature))) break;
        final node = _script.children[index];
        if (node is MenuNode) return true;
        if (node is ReturnNode) break;
        if (node is BoolNode && values.containsKey(node.variableName)) {
          values[node.variableName] = node.value;
        } else if (node is ApiCallNode ||
            node is SayNode && node.inlineApiToken != null ||
            node is ConditionalSayNode && node.inlineApiToken != null) {
          values.updateAll((_, _) => null);
        } else if (node is JumpNode) {
          final target = _labelIndexMap[node.targetLabel];
          if (!node.isConditional) {
            if (target == null) break;
            index = target;
            continue;
          }
          final value = values[node.conditionVariable];
          if (value == null) {
            if (target != null) pending.add((target, Map.of(values)));
          } else if (value == node.conditionValue) {
            if (target == null) break;
            index = target;
            continue;
          }
        }
        index++;
      }
    }
    return false;
  }

  Future<bool> _seekNextChoice() async {
    if (_disposed ||
        !_isScriptInitialized() ||
        _isProcessing ||
        _isSeekingNextChoice) {
      return false;
    }
    if (_currentState.currentNode is MenuNode) return true;
    // A transition has advanced its index but has not committed the new scene
    // yet. Let that atomic change finish before allowing navigation.
    if (_isWaitingForTimer &&
        _currentTimer == null &&
        _currentTimerCompletion == null) {
      return false;
    }
    if (!_hasReachableChoice(_scriptIndex)) return false;

    _isSeekingNextChoice = true;
    _choiceSeekRevision++;
    _choiceSeekNodesRemaining = 100000;
    try {
      // Complete a pending API's final state before traversing further. Any
      // continuation it schedules is held by the seek's execution lock.
      _completeCurrentTimerWait();
      _currentTimer?.cancel();
      _currentTimer = null;
      _currentTimerCompletion = null;
      _isWaitingForTimer = false;
      _settlePresentationBeforeChoiceSeek();

      if (!_disableRuntimeSideEffectsForTesting) {
        await MusicManager().stopVoice();
        await MusicManager().stopAudio(AudioTrackConfig.sound, fadeOut: false);
      }

      // Every dialogue still runs its ordinary character/CG/inline-API and
      // history logic. Only the click between dialogues is omitted.
      while (!_disposed && _scriptIndex < _script.children.length) {
        final previousIndex = _scriptIndex;
        if (!_currentState.animeKeep) {
          _currentState = _currentState.copyWith(clearAnimeOverlay: true);
        }
        _isProcessing = true;
        await _processScriptNodes();
        if (_currentState.currentNode is MenuNode) break;
        if (_scriptIndex == previousIndex) break;
      }
      if (_disposed) return false;

      _isProcessing = true;
      await _prepareChoiceSeekPresentation();
      if (_disposed) return false;

      final reachedChoice = _currentState.currentNode is MenuNode;
      // Save the fully reconstructed scene at the menu index, never an
      // intermediate scene paired with the destination's script index.
      _isSeekingNextChoice = false;
      if (reachedChoice) {
        await _createRuntimeAutoSave(reason: '分支选择');
        if (!_disposed) {
          await _checkAndCreateAutoSave(_scriptIndex, reason: '分支选择');
        }
      }
      return reachedChoice && !_disposed;
    } finally {
      _isSeekingNextChoice = false;
      _isProcessing = false;
      if (!_disposed) _resumeChoiceSeekLoops();
      _emitCurrentState();
    }
  }

  void _settlePresentationBeforeChoiceSeek() {
    _currentState = _buildDialogueHistorySnapshotState();
    _choiceSeekLoopingAnimations.clear();
    for (final entry in _activeCharacterAnimations.entries) {
      final character =
          _currentState.characters[entry.key] ??
          _currentState.cgCharacters[entry.key];
      final name = entry.value.animationName;
      if (character != null &&
          name != null &&
          entry.value.finiteFinalProperties == null) {
        _choiceSeekLoopingAnimations[entry.key] = (character.resourceId, name);
      }
    }
    final animations = _activeCharacterAnimations.values.toList();
    _activeCharacterAnimations.clear();
    for (final animation in animations) {
      animation.stopInfiniteLoop();
      animation.dispose();
    }
    _sceneAnimationController?.dispose();
    _sceneAnimationController = null;
    _characterPositionAnimator?.stop();
    _activeCgTransitionType = null;

    final characters = Map.of(_currentState.characters)
      ..removeWhere((_, character) => character.isFadingOut);
    // The currently displayed line may still have a delayed expression.
    if (_dialogueHistory.isNotEmpty) {
      final index = _dialogueHistory.last.scriptIndex;
      final node = _script.children[index];
      if (node is SayNode && node.hasTimedExpression) {
        final key = _resolveCharacterRenderKey(
          node.character,
          characterConfig: _characterConfigs[node.character],
        );
        final character = characters[key];
        if (character != null) {
          characters[key] = character.copyWith(expression: node.endExpression);
        }
      }
    }
    _currentState = _currentState.copyWith(
      characters: characters,
      isPaused: false,
      isShaking: false,
      forceNullCurrentNode: true,
    );
    _settleSceneAnimationForChoiceSeek();
  }

  void _settleSceneAnimationForChoiceSeek() {
    final name = _currentState.sceneAnimation;
    if (name == null) return;
    final properties = AnimationManager.resolveFinalProperties(name, {
      'xcenter': 0.0,
      'ycenter': 0.0,
      'scale': 1.0,
      'alpha': 1.0,
      'rotation': 0.0,
    });
    if (properties != null) {
      _currentState = _currentState.copyWith(
        sceneAnimationProperties: properties,
      );
    }
  }

  void _resumeChoiceSeekLoops() {
    if (_tickerProvider != null) {
      for (final entry in _choiceSeekLoopingAnimations.entries) {
        final character =
            _currentState.characters[entry.key] ??
            _currentState.cgCharacters[entry.key];
        if (character?.resourceId == entry.value.$1) {
          _playCharacterAnimation(entry.key, entry.value.$2, repeatCount: 0);
        }
      }
      final sceneAnimation = _currentState.sceneAnimation;
      if (sceneAnimation != null && _currentState.sceneAnimationRepeat == 0) {
        unawaited(_startSceneAnimation(sceneAnimation, 0));
      }
    }
    _choiceSeekLoopingAnimations.clear();
  }

  Future<void> _prepareChoiceSeekPresentation() async {
    if (_disableRuntimeSideEffectsForTesting) return;
    for (final character in [
      ..._currentState.characters.values,
      ..._currentState.cgCharacters.values,
    ]) {
      if (_disposed) return;
      await CharacterCompositeCache.instance.preload(
        character.resourceId,
        character.pose ?? 'pose1',
        character.expression ?? 'happy',
      );
    }
    if (_disposed) return;
    final music = _currentState.currentMusicRegion;
    if (music == null) {
      await MusicManager().stopBackgroundMusic(fadeOut: false);
    } else {
      final path = _buildMusicAssetPath(music.musicFile);
      if (path.isNotEmpty && !MusicManager().isPlayingMusic(path)) {
        await MusicManager().playBackgroundMusic(path, fadeTransition: false);
      }
    }
    if (_disposed) return;
    await _restoreLoopingSoundsAfterHistoryJump(_activeLoopingSounds.toList());
  }
}
