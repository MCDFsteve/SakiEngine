import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';

/// 快进管理器
/// 
/// 负责处理视觉小说的快进功能：
/// - 监听Command/Ctrl键的按下和释放
/// - 在快进模式下自动推进对话
/// - 管理快进速度和状态
class FastForwardManager {
  final DialogueProgressionManager dialogueProgressionManager;
  
  // 快进状态
  bool _isFastForwarding = false;
  Timer? _fastForwardTimer;
  
  // 快进配置
  static const Duration _fastForwardInterval = Duration(milliseconds: 50); // 快进间隔，50ms推进一次，非常快
  static const Duration _initialDelay = Duration(milliseconds: 50); // 初始延迟减少，更快响应
  
  // Command/Ctrl键状态监听
  bool _isFastForwardKeyPressed = false;
  bool _isListening = false;
  Timer? _keyHoldTimer;
  
  // 状态回调
  final ValueChanged<bool>? onFastForwardStateChanged;
  final bool Function()? canFastForward; // 检查是否可以快进的回调
  final Function(bool)? setGameManagerFastForward; // 设置GameManager快进状态的回调
  
  FastForwardManager({
    required this.dialogueProgressionManager,
    this.onFastForwardStateChanged,
    this.canFastForward,
    this.setGameManagerFastForward,
  });
  
  /// 获取当前快进状态
  bool get isFastForwarding => _isFastForwarding;
  
  /// 开始监听键盘事件
  void startListening() {
    if (_isListening) return;
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    _isListening = true;
  }
  
  /// 停止监听键盘事件
  void stopListening() {
    if (_isListening) {
      HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
      _isListening = false;
    }
    _handleFastForwardKeyReleased();
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        !_isFastForwardKey(event.logicalKey) &&
        _isFastForwardKeyPressed) {
      // Command/Ctrl与其他按键组成快捷键时，不应误触剧情快进。
      _handleFastForwardKeyReleased();
      return false;
    }
    handleKeyEvent(event);
    // 这里只观察全局按键状态，仍让Focus/快捷键系统继续处理组合键。
    return false;
  }

  bool _isFastForwardKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.meta;
  }
  
  /// 处理键盘按键事件
  bool handleKeyEvent(KeyEvent event) {
    if (!_isFastForwardKey(event.logicalKey)) return false;
    
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _handleFastForwardKeyPressed();
    } else if (event is KeyUpEvent) {
      final keyboard = HardwareKeyboard.instance;
      if (!keyboard.isControlPressed && !keyboard.isMetaPressed) {
        _handleFastForwardKeyReleased();
      }
    }
    
    return true; // 表示已处理该键盘事件
  }
  
  /// 处理Command/Ctrl键按下
  void _handleFastForwardKeyPressed() {
    if (_isFastForwardKeyPressed) return; // 避免重复处理
    
    _isFastForwardKeyPressed = true;
    
    // 设置延迟，避免误触快进
    _keyHoldTimer?.cancel();
    _keyHoldTimer = Timer(_initialDelay, () {
      if (_isFastForwardKeyPressed && !_isFastForwarding) {
        _startFastForward();
      }
    });
  }
  
  /// 处理Command/Ctrl键释放
  void _handleFastForwardKeyReleased() {
    _isFastForwardKeyPressed = false;
    _keyHoldTimer?.cancel();
    _keyHoldTimer = null;
    
    if (_isFastForwarding) {
      _stopFastForward();
    }
  }
  
  /// 开始快进
  void _startFastForward() {
    if (_isFastForwarding) return;
    
    // 检查是否可以快进
    if (canFastForward != null && !canFastForward!()) {
      return;
    }
    
    //print('🚀 开始快进');
    _isFastForwarding = true;
    onFastForwardStateChanged?.call(true);
    setGameManagerFastForward?.call(true); // 通知GameManager进入快进模式
    
    // 立即执行第一次推进
    _performFastForwardStep();
    
    // 启动快进计时器
    _fastForwardTimer = Timer.periodic(_fastForwardInterval, (timer) {
      _performFastForwardStep();
    });
  }
  
  /// 停止快进
  void _stopFastForward() {
    if (!_isFastForwarding) return;
    
    //print('⏹️  停止快进');
    _isFastForwarding = false;
    onFastForwardStateChanged?.call(false);
    setGameManagerFastForward?.call(false); // 通知GameManager退出快进模式
    
    _fastForwardTimer?.cancel();
    _fastForwardTimer = null;
  }
  
  /// 执行快进步骤
  void _performFastForwardStep() {
    // 检查是否还在快进状态
    if (!_isFastForwarding) return;
    
    // 再次检查是否可以快进（可能状态已改变）
    if (canFastForward != null && !canFastForward!()) {
      _stopFastForward();
      return;
    }
    
    // 推进对话
    try {
      dialogueProgressionManager.progressDialogue(isAutomated: true);
    } catch (e) {
      print('快进推进对话时发生错误: $e');
      // 出错时停止快进
      _stopFastForward();
    }
  }
  
  /// 手动开始快进（用于UI按钮等）
  void startFastForward() {
    _isFastForwardKeyPressed = true; // 模拟快进键按下
    _startFastForward();
  }
  
  /// 手动停止快进（用于UI按钮等）
  void stopFastForward() {
    _isFastForwardKeyPressed = false;
    _stopFastForward();
  }
  
  /// 切换快进状态
  void toggleFastForward() {
    if (_isFastForwarding) {
      stopFastForward();
    } else {
      startFastForward();
    }
  }
  
  /// 强制停止快进（由外部逻辑调用，如检测到章节场景）
  void forceStopFastForward() {
    _isFastForwardKeyPressed = false;
    _stopFastForward();
    print('[FastForward] 快进被强制停止（检测到重要场景）');
  }
  
  /// 清理资源
  void dispose() {
    stopListening();
  }
}
