import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/widgets/typewriter_animation_manager.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/utils/read_text_tracker.dart';

/// 对话推进管理器
/// 
/// 统一管理所有对话推进逻辑，确保打字机动画的正确处理：
/// - 如果打字机正在播放，先完成当前动画再推进
/// - 如果打字机已完成，直接推进到下一句
class DialogueProgressionManager {
  final GameManager gameManager;
  final VoidCallback? onManualProgress;
  TypewriterAnimationManager? _currentTypewriter;
  DateTime? _lastTypewriterSkipAt;

  // 防止同一次点击在极短时间内触发两次推进（第一次跳字、第二次直接下一句）。
  static const Duration _rapidProgressGuardDuration = Duration(
    milliseconds: 40,
  );
  
  DialogueProgressionManager({
    required this.gameManager,
    this.onManualProgress,
  });
  
  /// 注册当前活跃的打字机动画管理器
  void registerTypewriter(TypewriterAnimationManager? typewriter) {
    _currentTypewriter = typewriter;
  }
  
  /// 统一的对话推进方法
  /// 
  /// 所有推进对话的操作都应该调用这个方法，而不是直接调用 gameManager.next()
  void progressDialogue({bool isAutomated = false}) {
    if (_currentTypewriter?.canProgressDialogue(isAutomated: isAutomated) ==
        false) {
      return;
    }
    if (!isAutomated) {
      onManualProgress?.call();
    }

    final now = DateTime.now();
    final typewriter = _currentTypewriter;
    final recentlySkippedTypewriter =
        _lastTypewriterSkipAt != null &&
        now.difference(_lastTypewriterSkipAt!) <=
            _rapidProgressGuardDuration &&
        (typewriter == null || !typewriter.isTyping);
    if (recentlySkippedTypewriter) {
      return;
    }
    
    // 安全检查：如果当前打字机为null，这可能意味着注册丢失了
    if (typewriter == null) {
      _lastTypewriterSkipAt = null;
      // 直接推进到下一句对话，因为没有打字机需要处理
      _markCurrentDialogueAsRead();
      gameManager.next();
      return;
    }
    
    // 检查是否有活跃的打字机动画
    if (typewriter.isTyping) {
      // 如果正在打字，先跳过动画显示完整文本，但不推进到下一句
      typewriter.skipToEnd();
      _lastTypewriterSkipAt = now;
      return; // 重要：这里直接返回，不继续执行
    }

    _lastTypewriterSkipAt = null;
    
    // 在推进对话前，先标记当前对话为已读（如果有对话内容的话）
    _markCurrentDialogueAsRead();
    
    // 如果没有打字机动画或动画已完成，推进到下一句对话
    gameManager.next();
  }
  
  /// 标记当前对话为已读
  void _markCurrentDialogueAsRead() {
    final currentState = gameManager.currentState;
    if (currentState.dialogue != null && currentState.dialogue!.trim().isNotEmpty) {
      ReadTextTracker.instance.markAsRead(
        currentState.speaker,
        currentState.dialogue!,
        gameManager.currentScriptIndex,
      );
      return;
    }

    if (currentState.isNvlMode || currentState.isNvlMovieMode || currentState.isNvlnMode) {
      if (currentState.nvlDialogues.isNotEmpty) {
        for (final nvlDialogue in currentState.nvlDialogues) {
          ReadTextTracker.instance.markAsRead(
            nvlDialogue.speaker ?? currentState.speaker,
            nvlDialogue.dialogue,
            gameManager.currentScriptIndex,
          );
        }
      }
    }
  }
  
  /// 检查是否可以直接推进对话（用于UI状态判断）
  bool get canProgressDirectly {
    return _currentTypewriter == null || !_currentTypewriter!.isTyping;
  }
  
  /// 检查当前是否有打字机动画正在播放
  bool get isTypewriterActive {
    return _currentTypewriter != null && _currentTypewriter!.isTyping;
  }
  
  /// 获取当前打字机（用于监听状态变化）
  TypewriterAnimationManager? get currentTypewriter => _currentTypewriter;
}
