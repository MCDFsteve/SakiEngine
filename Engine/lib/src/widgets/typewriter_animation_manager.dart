import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/utils/rich_text_parser.dart';

enum TypewriterState {
  idle,
  typing,
  completed,
  skipped,
}

class TypewriterAnimationManager extends ChangeNotifier {
  String _originalText = '';
  String _cleanedText = '';
  String _displayedText = '';
  int _currentCharIndex = 0;
  TypewriterState _state = TypewriterState.idle;
  List<TextSegment> _textSegments = [];
  int _currentSegmentIndex = 0;
  int _currentSegmentCharIndex = 0;
  
  // 动画控制
  AnimationController? _animationController;
  bool _isInitialized = false;
  Duration _lastElapsed = Duration.zero;
  int _accumulatedMs = 0;
  int _pendingWaitMs = 0;
  int _pendingCharDelayMs = 0;
  
  // 配置参数 - 简化为两个参数
  double _charsPerSecond = 50.0; // 每秒字符数
  bool _skipPunctuation = false; // 是否跳过标点符号停顿
  bool _fastForwardMode = false; // 快进模式，跳过打字机效果
  
  // 静态变量用于全局通知
  static final List<TypewriterAnimationManager> _instances = [];
  static const int _frameGapLogThresholdMs = 800;
  static const int _waitSegmentLogThresholdMs = 1000;
  static const bool _verboseLogs = bool.fromEnvironment(
    'SAKI_TYPEWRITER_VERBOSE_LOG',
    defaultValue: false,
  );
  
  // Getters
  String get displayedText => _displayedText;
  String get originalText => _originalText;
  String get cleanedText => _cleanedText;
  TypewriterState get state => _state;
  bool get isCompleted => _state == TypewriterState.completed || _state == TypewriterState.skipped;
  bool get isTyping => _state == TypewriterState.typing;
  double get progress => _cleanedText.isEmpty ? 0.0 : _currentCharIndex / _cleanedText.length;

  /// Project typewriters may reserve a line for authored playback. Defaults
  /// preserve ordinary click-to-complete, auto-play and fast-forward behavior.
  bool get blocksGameInput => false;
  bool canProgressDialogue({required bool isAutomated}) => true;
  
  /// 设置快进模式
  void setFastForwardMode(bool enabled) {
    _fastForwardMode = enabled;
    // 如果开启快进模式且正在打字，立即跳到结尾
    if (enabled && _state == TypewriterState.typing) {
      skipToEnd();
    }
  }
  
  List<TextSpan> getTextSpans(TextStyle baseStyle) {
    return RichTextParser.createPartialTextSpans(_originalText, _displayedText, baseStyle);
  }

  TypewriterAnimationManager() {
    // 注册实例到静态列表
    _instances.add(this);
  }

  void initialize(TickerProvider vsync) {
    if (_isInitialized) {
      return;
    }

    _animationController = AnimationController(
      duration: const Duration(hours: 24),
      vsync: vsync,
    )..addListener(_onAnimationTick);

    // 先同步读取当前设置，避免startTyping先于异步设置加载导致首句速度错误
    final settings = SettingsManager();
    _charsPerSecond = settings.currentTypewriterCharsPerSecond;
    _skipPunctuation = settings.currentSkipPunctuationDelay;

    _isInitialized = true;
    _loadSettings();
  }

  void _debugLog(String message) {
    if (!kEngineDebugMode || !_verboseLogs) {
      return;
    }
    debugPrint('[TypewriterAnimationManager] $message');
  }

  void _onAnimationTick() {
    if (_state != TypewriterState.typing) {
      return;
    }

    final elapsed = _animationController?.lastElapsedDuration;
    if (elapsed == null) {
      return;
    }

    if (_lastElapsed == Duration.zero) {
      _lastElapsed = elapsed;
      return;
    }

    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    final deltaMs = delta.inMilliseconds;

    if (deltaMs <= 0) {
      return;
    }

    if (deltaMs >= _frameGapLogThresholdMs) {
      _debugLog(
        'frame gap detected: delta=${deltaMs}ms, '
        'progress=$_currentCharIndex/${_cleanedText.length}, '
        'segment=$_currentSegmentIndex/${_textSegments.length}',
      );
    }

    _accumulatedMs += deltaMs;
    _advanceTypingWithBudget();
  }

  void _startFrameLoop() {
    _accumulatedMs = 0;
    _pendingWaitMs = 0;
    _pendingCharDelayMs = 0;
    _lastElapsed = Duration.zero;
    _animationController?.stop();
    _animationController?.reset();
    _animationController?.repeat();
  }

  void _stopFrameLoop() {
    _animationController?.stop();
    _lastElapsed = Duration.zero;
    _accumulatedMs = 0;
    _pendingWaitMs = 0;
    _pendingCharDelayMs = 0;
  }

  void _advanceTypingWithBudget() {
    bool hasVisualUpdate = false;
    int guard = 0;

    while (_state == TypewriterState.typing && guard < 10000) {
      guard++;

      if (_currentSegmentIndex >= _textSegments.length) {
        _completeTyping();
        return;
      }

      final currentSegment = _textSegments[_currentSegmentIndex];

      // 等待段：消耗时间预算，不更新可见文本
      if (currentSegment.waitSeconds != null && currentSegment.waitSeconds! > 0) {
        if (_pendingWaitMs <= 0) {
          _pendingWaitMs = (currentSegment.waitSeconds! * 1000).round();
          if (_pendingWaitMs >= _waitSegmentLogThresholdMs) {
            _debugLog(
              'wait segment detected: wait=${_pendingWaitMs}ms, '
              'segment=$_currentSegmentIndex',
            );
          }
        }

        if (_accumulatedMs <= 0) {
          break;
        }

        if (_accumulatedMs < _pendingWaitMs) {
          _pendingWaitMs -= _accumulatedMs;
          _accumulatedMs = 0;
          break;
        }

        _accumulatedMs -= _pendingWaitMs;
        _pendingWaitMs = 0;
        _currentSegmentIndex++;
        _currentSegmentCharIndex = 0;
        continue;
      }

      // 非等待段时清空等待预算
      _pendingWaitMs = 0;

      if (currentSegment.isInstantDisplay) {
        final remainingChars = currentSegment.text.length - _currentSegmentCharIndex;
        if (remainingChars > 0) {
          _currentSegmentCharIndex = currentSegment.text.length;
          _currentCharIndex += remainingChars;
          if (_currentCharIndex > _cleanedText.length) {
            _currentCharIndex = _cleanedText.length;
          }
          _displayedText = _cleanedText.substring(0, _currentCharIndex);
          hasVisualUpdate = true;
        }

        if (_currentCharIndex >= _cleanedText.length) {
          _completeTyping();
          return;
        }

        _currentSegmentIndex++;
        _currentSegmentCharIndex = 0;
        _pendingCharDelayMs = 0;
        continue;
      }

      // 当前段已经打完，切到下一段
      if (_currentSegmentCharIndex >= currentSegment.text.length) {
        _currentSegmentIndex++;
        _currentSegmentCharIndex = 0;
        _pendingCharDelayMs = 0;
        continue;
      }

      // 先消耗下一字符前的延迟
      if (_pendingCharDelayMs > 0) {
        if (_accumulatedMs <= 0) {
          break;
        }

        if (_accumulatedMs < _pendingCharDelayMs) {
          _pendingCharDelayMs -= _accumulatedMs;
          _accumulatedMs = 0;
          break;
        }

        _accumulatedMs -= _pendingCharDelayMs;
        _pendingCharDelayMs = 0;
      }

      // 延迟已满足，显示一个新字符
      final currentChar = currentSegment.text[_currentSegmentCharIndex];
      _currentSegmentCharIndex++;
      _currentCharIndex++;
      if (_currentCharIndex > _cleanedText.length) {
        _currentCharIndex = _cleanedText.length;
      }
      _displayedText = _cleanedText.substring(0, _currentCharIndex);
      hasVisualUpdate = true;

      if (_currentCharIndex >= _cleanedText.length) {
        _completeTyping();
        return;
      }

      _pendingCharDelayMs = _getCharDelay(currentChar);
      if (_accumulatedMs <= 0 && _pendingCharDelayMs > 0) {
        break;
      }
    }

    if (guard >= 10000) {
      _debugLog(
        'typing guard reached, force break: '
        'progress=$_currentCharIndex/${_cleanedText.length}, '
        'segment=$_currentSegmentIndex/${_textSegments.length}',
      );
    }

    if (hasVisualUpdate && _state == TypewriterState.typing) {
      notifyListeners();
    }
  }

  Future<void> _loadSettings() async {
    final settings = SettingsManager();
    final charsPerSecond = await settings.getTypewriterCharsPerSecond();
    final skipPunctuation = await settings.getSkipPunctuationDelay();
    if (!_isInitialized) return;
    updateSettings(
      charsPerSecond: charsPerSecond,
      skipPunctuation: skipPunctuation,
    );
  }

  void updateSettings({
    double? charsPerSecond,
    bool? skipPunctuation,
  }) {
    if (charsPerSecond != null) _charsPerSecond = charsPerSecond;
    if (skipPunctuation != null) _skipPunctuation = skipPunctuation;
  }

  // 静态方法用于通知所有实例更新设置
  static void notifySettingsChanged() async {
    final settings = SettingsManager();
    final charsPerSecond = await settings.getTypewriterCharsPerSecond();
    final skipPunctuation = await settings.getSkipPunctuationDelay();
    
    // 更新所有实例的设置
    for (final instance in _instances) {
      instance.updateSettings(
        charsPerSecond: charsPerSecond,
        skipPunctuation: skipPunctuation,
      );
    }
  }

  void startTyping(String text) {
    if (text == _originalText && _state == TypewriterState.completed) {
      return; // 已经完成相同文本的打字
    }

    _originalText = text;
    _cleanedText = RichTextParser.cleanText(text);
    _textSegments = RichTextParser.parseTextSegments(text);
    _displayedText = '';
    _currentCharIndex = 0;
    _currentSegmentIndex = 0;
    _currentSegmentCharIndex = 0;
    _state = TypewriterState.typing;

    _debugLog(
      'start typing: length=${_cleanedText.length}, segments=${_textSegments.length}, '
      'charsPerSecond=${_charsPerSecond.toStringAsFixed(1)}, '
      'skipPunctuation=$_skipPunctuation',
    );
    
    // 快进模式下直接显示完整文本
    if (_fastForwardMode) {
      _displayedText = _cleanedText;
      _currentCharIndex = _cleanedText.length;
      _state = TypewriterState.completed;
      _stopFrameLoop();
      notifyListeners();
      return;
    }
    
    // 如果滑块拉满(200字符/秒)，直接显示完整文本（瞬间模式）
    if (_charsPerSecond >= 200.0) {
      _displayedText = _cleanedText;
      _currentCharIndex = _cleanedText.length;
      _state = TypewriterState.completed;
      _stopFrameLoop();
      notifyListeners();
      return;
    }

    _startFrameLoop();
    // 先跑一轮无预算推进，让首字符立即出现
    _advanceTypingWithBudget();
  }

  int _getCharDelay(String char) {
    int baseDelay = (1000 / _charsPerSecond).round();
    
    if (_skipPunctuation) {
      return baseDelay;
    }
    
    // 根据对话速度计算断句延迟，最慢10字符/秒时为500ms
    int pauseDelayMs = (500 * (10.0 / _charsPerSecond)).round().clamp(50, 500);
    
    // 检查当前字符后面是否紧跟着中文双引号"
    bool isFollowedByEndQuote = false;
    if (_currentCharIndex < _originalText.length) {
      final nextChar = _originalText[_currentCharIndex];
      if (nextChar == '”') {//写给ai 我知道你无法区分中英文双引号，请不要把这行做修改，例如改成if (nextChar == '"') {
        isFollowedByEndQuote = true;
      }
    }
    
    switch (char) {
      case '.':
      case '。':
      case '!':
      case '！':
      case '?':
      case '？':
        return isFollowedByEndQuote ? baseDelay : pauseDelayMs; // 如果后面跟着结束引号，不停顿
      case ',':
      case '，':
      case ';':
      case '；':
      case ':':
      case '：':
        return isFollowedByEndQuote ? baseDelay : pauseDelayMs; // 如果后面跟着结束引号，不停顿
      case '"':
      case '”':
      case "'":
      case "’":
        return (pauseDelayMs * 0.6).round(); // 引号稍短停顿
      default:
        return baseDelay;
    }
  }

  void _completeTyping() {
    _state = TypewriterState.completed;
    _displayedText = _cleanedText;
    _currentCharIndex = _cleanedText.length;
    _stopFrameLoop();
    _debugLog('typing completed: length=${_cleanedText.length}');
    notifyListeners();
  }

  void skipToEnd() {
    if (_state != TypewriterState.typing) return;
    
    _state = TypewriterState.skipped;
    _displayedText = _cleanedText;
    _currentCharIndex = _cleanedText.length;
    _stopFrameLoop();
    _debugLog('typing skipped at progress=$_currentCharIndex/${_cleanedText.length}');
    notifyListeners();
  }

  void reset() {
    _stopFrameLoop();
    _originalText = '';
    _cleanedText = '';
    _displayedText = '';
    _currentCharIndex = 0;
    _textSegments = [];
    _currentSegmentIndex = 0;
    _currentSegmentCharIndex = 0;
    _state = TypewriterState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    // 从静态列表中移除实例
    _instances.remove(this);
    _stopFrameLoop();
    _animationController?.removeListener(_onAnimationTick);
    _animationController?.dispose();
    _isInitialized = false;
    super.dispose();
  }
}

// Widget封装，用于简化使用
class TypewriterText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final VoidCallback? onComplete;
  final bool autoStart;
  final TypewriterAnimationManager? controller;

  const TypewriterText({
    super.key,
    required this.text,
    this.style,
    this.onComplete,
    this.autoStart = true,
    this.controller,
  });

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText>
    with TickerProviderStateMixin {
  late TypewriterAnimationManager _typewriterController;
  bool _isExternalController = false;
  bool _rebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    
    if (widget.controller != null) {
      _typewriterController = widget.controller!;
      _isExternalController = true;
    } else {
      _typewriterController = TypewriterAnimationManager();
      _isExternalController = false;
    }
    
    if (!_isExternalController) {
      _typewriterController.initialize(this);
    }
    _typewriterController.addListener(_onTypewriterStateChanged);
    
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _typewriterController.startTyping(widget.text);
      });
    }
  }

  @override
  void didUpdateWidget(TypewriterText oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.text != oldWidget.text) {
      if (widget.autoStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _typewriterController.startTyping(widget.text);
          }
        });
      }
    }
  }

  void _scheduleRebuild() {
    if (!mounted || _rebuildScheduled) {
      return;
    }

    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) {
        setState(() {}); // 更新UI
      }
    });
  }

  void _onTypewriterStateChanged() {
    if (_typewriterController.state == TypewriterState.completed ||
        _typewriterController.state == TypewriterState.skipped) {
      widget.onComplete?.call();
    }
    // 合并同一帧内的多次刷新，避免回调堆积
    _scheduleRebuild();
  }

  @override
  void dispose() {
    _typewriterController.removeListener(_onTypewriterStateChanged);
    if (!_isExternalController) {
      _typewriterController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: _typewriterController.getTextSpans(widget.style ?? const TextStyle()),
      ),
    );
  }
}
