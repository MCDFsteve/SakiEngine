import 'dart:async';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';

/// 自动播放管理器
/// 等待打字机完成后，停留一段时间让用户阅读，然后自动推进对话
class AutoPlayManager {
  final DialogueProgressionManager dialogueProgressionManager;
  final VoidCallback? onAutoPlayStateChanged;
  final bool Function()? canAutoPlay;

  bool _isAutoPlaying = false;
  Timer? _readingTimer;
  bool _isWaitingForTypewriter = false;

  // 阅读等待时间（打字机完成后的停留时间）
  static const Duration _readingDelay = Duration(milliseconds: 1500);

  AutoPlayManager({
    required this.dialogueProgressionManager,
    this.onAutoPlayStateChanged,
    this.canAutoPlay,
  });

  /// 是否正在自动播放
  bool get isAutoPlaying => _isAutoPlaying;

  /// 开始自动播放
  void startAutoPlay() {
    if (_isAutoPlaying) return;

    // 检查是否可以自动播放
    if (canAutoPlay != null && !canAutoPlay!()) {
      sakiDiagnosticLog('AutoPlayManager: 当前状态不允许自动播放');
      return;
    }

    _isAutoPlaying = true;
    onAutoPlayStateChanged?.call();

    sakiDiagnosticLog('AutoPlayManager: 开始自动播放');

    // 监听当前打字机状态
    _checkTypewriterAndScheduleNext();
  }

  /// 停止自动播放
  void stopAutoPlay() {
    if (!_isAutoPlaying) return;

    _isAutoPlaying = false;
    _isWaitingForTypewriter = false;
    _cancelReadingTimer();
    onAutoPlayStateChanged?.call();

    sakiDiagnosticLog('AutoPlayManager: 停止自动播放');
  }

  /// 切换自动播放状态
  void toggleAutoPlay() {
    if (_isAutoPlaying) {
      stopAutoPlay();
    } else {
      startAutoPlay();
    }
  }

  /// 检查打字机状态并安排下次推进
  void _checkTypewriterAndScheduleNext() {
    if (!_isAutoPlaying) return;

    // 检查打字机是否在播放
    if (dialogueProgressionManager.isTypewriterActive) {
      // 打字机正在播放，等待完成
      _isWaitingForTypewriter = true;
      sakiDiagnosticLog('AutoPlayManager: 等待打字机完成...');

      // 监听打字机完成事件
      if (dialogueProgressionManager.currentTypewriter != null) {
        dialogueProgressionManager.currentTypewriter!.addListener(
          _onTypewriterStateChanged,
        );
      }
    } else {
      // 打字机已完成或不存在，直接开始阅读等待
      _startReadingDelay();
    }
  }

  /// 打字机状态变化回调
  void _onTypewriterStateChanged() {
    if (!_isAutoPlaying || !_isWaitingForTypewriter) return;

    if (!dialogueProgressionManager.isTypewriterActive) {
      // 打字机完成，移除监听器并开始阅读等待
      if (dialogueProgressionManager.currentTypewriter != null) {
        dialogueProgressionManager.currentTypewriter!.removeListener(
          _onTypewriterStateChanged,
        );
      }
      _isWaitingForTypewriter = false;

      sakiDiagnosticLog('AutoPlayManager: 打字机完成，开始阅读等待');

      _startReadingDelay();
    }
  }

  /// 开始阅读等待计时器
  void _startReadingDelay() {
    if (!_isAutoPlaying) return;

    _cancelReadingTimer();

    _readingTimer = Timer(_readingDelay, () {
      _onReadingDelayComplete();
    });
  }

  /// 阅读等待完成，自动推进对话
  void _onReadingDelayComplete() {
    if (!_isAutoPlaying) return;

    // 再次检查是否可以自动播放
    if (canAutoPlay != null && !canAutoPlay!()) {
      sakiDiagnosticLog('AutoPlayManager: 检测到不允许自动播放的状态，停止自动播放');
      stopAutoPlay();
      return;
    }

    // 推进对话
    try {
      dialogueProgressionManager.progressDialogue(isAutomated: true);

      // 推进后，等待一帧再检查下一个状态
      Future.delayed(Duration(milliseconds: 50), () {
        if (_isAutoPlaying) {
          _checkTypewriterAndScheduleNext();
        }
      });
    } catch (e) {
      if (kEngineDebugMode) {
        print('AutoPlayManager: 推进对话时发生错误: $e');
      }
      stopAutoPlay();
    }
  }

  /// 取消阅读计时器
  void _cancelReadingTimer() {
    _readingTimer?.cancel();
    _readingTimer = null;
  }

  /// 手动推进对话时的处理 - 停止自动播放
  void onManualProgress() {
    if (_isAutoPlaying) {
      sakiDiagnosticLog('AutoPlayManager: 检测到手动推进，停止自动播放');
      stopAutoPlay();
    }
  }

  /// 当遇到选择菜单或其他阻塞情况时强制停止自动播放
  void forceStopOnBlocking() {
    if (_isAutoPlaying) {
      sakiDiagnosticLog('AutoPlayManager: 遇到阻塞情况，强制停止自动播放');
      stopAutoPlay();
    }
  }

  /// 释放资源
  void dispose() {
    // 清理打字机监听器
    if (_isWaitingForTypewriter) {
      final typewriter = dialogueProgressionManager.currentTypewriter;
      typewriter?.removeListener(_onTypewriterStateChanged);
    }

    _cancelReadingTimer();

    sakiDiagnosticLog('AutoPlayManager: 已释放资源');
  }
}
