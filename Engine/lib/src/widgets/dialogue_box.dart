import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/widgets/typewriter_animation_manager.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';
import 'package:sakiengine/src/utils/dialogue_shake_effect.dart';
import 'package:sakiengine/src/utils/read_text_tracker.dart';
import 'package:sakiengine/src/widgets/read_status_indicator.dart';
import 'package:sakiengine/src/widgets/dialogue_background.dart';
import 'package:sakiengine/src/widgets/dialogue_speaker_header.dart';
import 'package:sakiengine/src/widgets/dialogue_content.dart';

class DialogueBox extends StatefulWidget {
  final String? speaker;
  final String? speakerAlias; // 新增：角色简写
  final String? dialogueTag; // 对话行尾扩展 token（默认对话框不消费）
  final String dialogue;
  final DialogueProgressionManager? progressionManager;
  final bool isFastForwarding;
  final int scriptIndex;

  const DialogueBox({
    super.key,
    this.speaker,
    this.speakerAlias, // 新增：角色简写参数
    this.dialogueTag,
    required this.dialogue,
    this.progressionManager,
    this.isFastForwarding = false,
    required this.scriptIndex,
  });

  @override
  State<DialogueBox> createState() => _DialogueBoxState();
}

class _DialogueBoxState extends State<DialogueBox>
    with TickerProviderStateMixin {
  bool _isHovered = false;
  bool _isDialogueComplete = false;
  double _dialogOpacity = SettingsManager.defaultDialogOpacity;
  bool _isRead = false;

  late TypewriterAnimationManager _typewriterController;
  final bool _enableTypewriter = true;

  late AnimationController _textFadeController;
  late Animation<double> _textFadeAnimation;

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {
        _dialogOpacity = SettingsManager().currentDialogOpacity;
      });
    }
  }

  void _onReadTextTrackerChanged() {
    final isRead = ReadTextTracker.instance.isRead(
      widget.speaker,
      widget.dialogue,
      widget.scriptIndex,
    );
    if (mounted && isRead != _isRead) {
      setState(() => _isRead = isRead);
    }
  }

  @override
  void initState() {
    super.initState();

    // 检查已读状态
    _isRead = ReadTextTracker.instance.isRead(
      widget.speaker,
      widget.dialogue,
      widget.scriptIndex,
    );
    ReadTextTracker.instance.addListener(_onReadTextTrackerChanged);

    // 初始化打字机动画管理器
    _typewriterController = TypewriterAnimationManager();
    _typewriterController.initialize(this);
    _typewriterController.addListener(_onTypewriterStateChanged);

    // 注册打字机到推进管理器
    widget.progressionManager?.registerTypewriter(_typewriterController);

    // 初始化文本淡入动画
    _textFadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _textFadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _textFadeController,
      curve: Curves.easeInOut,
    ));

    // 监听设置变化
    SettingsManager().addListener(_onSettingsChanged);

    // 加载设置
    _loadSettings();

    // 开始文本淡入和打字机动画
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _typewriterController.setFastForwardMode(widget.isFastForwarding);

      if (widget.isFastForwarding) {
        _textFadeController.value = 1.0;
      } else {
        _textFadeController.forward();
      }

      if (_enableTypewriter) {
        _typewriterController.startTyping(widget.dialogue);
      }
    });
  }

  @override
  void dispose() {
    widget.progressionManager?.registerTypewriter(null);
    SettingsManager().removeListener(_onSettingsChanged);
    ReadTextTracker.instance.removeListener(_onReadTextTrackerChanged);
    _typewriterController.removeListener(_onTypewriterStateChanged);
    _typewriterController.dispose();
    _textFadeController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DialogueBox oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 总是重新注册打字机，确保在对话框被重新创建后能正常工作
    widget.progressionManager?.registerTypewriter(_typewriterController);

    if (widget.isFastForwarding != oldWidget.isFastForwarding) {
      _typewriterController.setFastForwardMode(widget.isFastForwarding);
      if (widget.isFastForwarding) {
        _textFadeController.value = 1.0;
      }
    }

    if (widget.dialogue != oldWidget.dialogue ||
        widget.scriptIndex != oldWidget.scriptIndex) {
      _isRead = ReadTextTracker.instance.isRead(
        widget.speaker,
        widget.dialogue,
        widget.scriptIndex,
      );

      if (widget.isFastForwarding) {
        _textFadeController.value = 1.0;
      } else {
        _textFadeController.reset();
        _textFadeController.forward();
      }

      if (_enableTypewriter) {
        _typewriterController.startTyping(widget.dialogue);
      }
    }
  }

  Widget _buildReadStatusTag() {
    final uiScale = context.scaleFor(ComponentType.ui);
    final textScale = context.scaleFor(ComponentType.text);

    return Positioned(
      left: 12.0 * uiScale,
      top: -8.0 * uiScale,
      child: ReadStatusIndicator(
        isRead: _isRead,
        uiScale: uiScale,
        textScale: textScale,
        positioned: false, // 不要自动定位，我们手动定位
      ),
    );
  }

  void _onTypewriterStateChanged() {
    if (mounted) {
      setState(() {
        _isDialogueComplete = _typewriterController.isCompleted;
      });
    }
  }

  Future<void> _loadSettings() async {
    final settings = SettingsManager();
    final opacity = await settings.getDialogOpacity();

    if (mounted) {
      setState(() {
        _dialogOpacity = opacity;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = SakiEngineConfig();
    final uiScale = context.scaleFor(ComponentType.ui);
    final textScale = context.scaleFor(ComponentType.text);

    final dialogueStyle = config.dialogueTextStyle.copyWith(
      fontSize: config.dialogueTextStyle.fontSize! * textScale,
      color: config.themeColors.onSurface,
      height: 1.6,
      letterSpacing: 0.3,
    );

    return DialogueShakeEffect(
      dialogue: widget.dialogue,
      displayedText: _typewriterController.displayedText, // 传递当前显示的文本
      enabled: true,
      intensity: 4.0 * uiScale,
      duration: const Duration(milliseconds: 600),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Stack(
            clipBehavior: Clip.none, // 允许子组件超出边界
            children: [
              Container(
                child: DialogueBackground(
                  isHovered: _isHovered,
                  dialogOpacity: _dialogOpacity,
                  uiScale: uiScale,
                  overlay: null, // 移除原来的已读标签
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DialogueSpeakerHeader(
                        speaker: widget.speaker,
                        uiScale: uiScale,
                        textScale: textScale,
                      ),
                      DialogueContent(
                        dialogue: widget.dialogue,
                        speaker: widget.speaker,
                        speakerAlias: widget.speakerAlias, // 新增：传递角色简写
                        dialogueStyle: dialogueStyle,
                        typewriterController: _typewriterController,
                        textFadeAnimation: _textFadeAnimation,
                        enableTypewriter: _enableTypewriter,
                        isDialogueComplete: _isDialogueComplete,
                        uiScale: uiScale,
                        isRead: _isRead,
                      ),
                    ],
                  ),
                ),
              ),
              // 已读标签 - 使用坐标计算
              if (_isRead) _buildReadStatusTag(),
            ],
          ),
        ),
      ),
    );
  }
}
