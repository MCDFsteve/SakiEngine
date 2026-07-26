import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/widgets/typewriter_animation_manager.dart';
import 'package:sakiengine/src/utils/dialogue_progression_manager.dart';
import 'package:sakiengine/src/widgets/dialogue_next_arrow.dart';
import 'package:sakiengine/src/utils/rich_text_parser.dart';

// 用于外部访问NvlScreen状态的接口
abstract class NvlScreenController {
  void setCinematicBarsVisible(bool visible);
  void playMovieModeExitAnimation();
}

class NvlScreen extends StatefulWidget {
  final List<NvlDialogue> nvlDialogues;
  final DialogueProgressionManager? progressionManager;
  final bool isMovieMode;
  final bool isFastForwarding; // 快进状态
  final bool isNoMask; // 新增：是否为无遮罩模式（nvln）

  const NvlScreen({
    super.key,
    required this.nvlDialogues,
    this.progressionManager,
    this.isMovieMode = false,
    this.isFastForwarding = false, // 默认不快进
    this.isNoMask = false, // 新增：默认有遮罩
  });

  @override
  State<NvlScreen> createState() => _NvlScreenState();
}

class _NvlScreenState extends State<NvlScreen> with TickerProviderStateMixin implements NvlScreenController {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  final ScrollController _scrollController = ScrollController();
  bool _scrollToBottomScheduled = false;
  bool _animateNextScrollToBottom = false;
  
  // 文本淡入动画控制器列表，为每个对话单独管理
  final Map<int, AnimationController> _textFadeControllers = {};
  final Map<int, Animation<double>> _textFadeAnimations = {};
  
  // 电影黑边动画控制器 - 分别为上下黑边创建独立控制器
  late AnimationController _topBarController;
  late AnimationController _bottomBarController;
  late Animation<double> _topBarAnimation;
  late Animation<double> _bottomBarAnimation;
  
  // 当前打字机控制器（只有最后一句对话使用）
  TypewriterAnimationManager? _currentTypewriterController;
  
  // 记录当前打字机控制器对应的索引，避免重复创建
  int _lastTypewriterIndex = -1;
  
  // 跟踪最后一句对话是否完成（用于显示箭头）
  bool _isLastDialogueComplete = false;
  
  // 控制黑边显示状态 - 用于转场时临时隐藏黑边
  bool _showCinematicBars = false;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      duration: widget.isFastForwarding 
          ? Duration.zero // 快进模式下跳过动画
          : const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));
    
    // 初始化电影黑边动画 - 创建两个独立的控制器
    _topBarController = AnimationController(
      duration: widget.isFastForwarding 
          ? Duration.zero // 快进模式下跳过动画
          : const Duration(milliseconds: 400), // 从800ms加快到400ms
      vsync: this,
    );
    
    _bottomBarController = AnimationController(
      duration: widget.isFastForwarding 
          ? Duration.zero // 快进模式下跳过动画
          : const Duration(milliseconds: 400), // 从800ms加快到400ms
      vsync: this,
    );
    
    // 上方黑边从屏幕上方滑入
    _topBarAnimation = Tween<double>(
      begin: -1.0, // 从屏幕上方外开始
      end: 0.0,    // 滑入到正确位置
    ).animate(CurvedAnimation(
      parent: _topBarController,
      curve: Curves.easeOutCubic,
    ));
    
    // 下方黑边从屏幕下方滑入
    _bottomBarAnimation = Tween<double>(
      begin: 1.0,  // 从屏幕下方外开始  
      end: 0.0,    // 滑入到正确位置
    ).animate(CurvedAnimation(
      parent: _bottomBarController,
      curve: Curves.easeOutCubic,
    ));
    
    // 快进模式下直接跳到最终状态
    if (widget.isFastForwarding) {
      _fadeController.value = 1.0;
    } else {
      _fadeController.forward();
    }
    
    // 如果是电影模式，启动黑边动画并设置显示状态
    if (widget.isMovieMode) {
      _showCinematicBars = true;
      if (widget.isFastForwarding) {
        // 快进模式下直接设置最终状态
        _topBarController.value = 1.0;
        _bottomBarController.value = 1.0;
      } else {
        // 让上下黑边有个小延迟，增加视觉层次
        _topBarController.forward();
        Future.delayed(const Duration(milliseconds: 100), () {
          _bottomBarController.forward();
        });
      }
    }
    
    _scheduleScrollToBottom(animate: !widget.isFastForwarding);
  }

  @override
  void didUpdateWidget(NvlScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // 如果电影模式状态发生变化，重新启动动画
    if (widget.isMovieMode != oldWidget.isMovieMode) {
      if (widget.isMovieMode) {
        _showCinematicBars = true;
        _topBarController.forward();
        Future.delayed(const Duration(milliseconds: 100), () {
          _bottomBarController.forward();
        });
      } else {
        // 当切换到非电影模式时，先隐藏黑边再反转动画
        _showCinematicBars = false;
        _topBarController.reverse();
        _bottomBarController.reverse();
      }
    }
    
    // 当有新对话添加时，重置状态
    if (widget.nvlDialogues.length > oldWidget.nvlDialogues.length) {
      _isLastDialogueComplete = false; // 重置箭头状态
      
      // 重新播放淡入动画（可选，显示新对话的效果）
      _fadeController.forward();
      
      _scheduleScrollToBottom(animate: !widget.isFastForwarding);
    }
  }

  void _scheduleScrollToBottom({bool animate = false}) {
    _animateNextScrollToBottom = _animateNextScrollToBottom || animate;
    if (_scrollToBottomScheduled) {
      return;
    }

    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomScheduled = false;
      if (!mounted || !_scrollController.hasClients) {
        _animateNextScrollToBottom = false;
        return;
      }

      final position = _scrollController.position;
      final target = position.maxScrollExtent;
      final shouldAnimate = _animateNextScrollToBottom;
      _animateNextScrollToBottom = false;
      if ((target - position.pixels).abs() < 0.5) {
        return;
      }

      if (shouldAnimate) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _topBarController.dispose();
    _bottomBarController.dispose();
    _scrollController.dispose();
    // 从推进管理器注销打字机
    widget.progressionManager?.registerTypewriter(null);
    _currentTypewriterController?.dispose();
    // 清理所有文本淡入动画控制器
    for (final controller in _textFadeControllers.values) {
      controller.dispose();
    }
    _textFadeControllers.clear();
    _textFadeAnimations.clear();
    super.dispose();
  }

  /// 获取或创建打字机控制器，并注册到推进管理器
  TypewriterAnimationManager _getOrCreateTypewriterController(int index) {
    // 如果当前控制器存在且索引匹配，直接返回
    if (_currentTypewriterController != null && _lastTypewriterIndex == index) {
      return _currentTypewriterController!;
    }
    
    // 为了避免显示上一句对话，每次都创建新的控制器
    // 这样确保TypewriterText从空白状态开始
    
    // 先清理旧的控制器
    if (_currentTypewriterController != null) {
      final oldController = _currentTypewriterController!;
      // 延迟一帧释放，确保旧TypewriterText先完成dispose
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
    
    // 创建新的控制器
    _currentTypewriterController = TypewriterAnimationManager();
    _currentTypewriterController!.initialize(this);
    
    // 设置快进模式
    _currentTypewriterController!.setFastForwardMode(widget.isFastForwarding);
    
    // 注册到推进管理器
    widget.progressionManager?.registerTypewriter(_currentTypewriterController);
    
    // 记录当前索引
    _lastTypewriterIndex = index;
    _isLastDialogueComplete = false;
    
    return _currentTypewriterController!;
  }
  
  /// 控制电影模式黑边的显示/隐藏
  /// 用于转场时临时隐藏黑边以避免视觉问题
  @override
  void setCinematicBarsVisible(bool visible) {
    if (mounted && _showCinematicBars != visible) {
      setState(() {
        _showCinematicBars = visible;
      });
      
      if (visible) {
        // 显示黑边：从屏幕外滑入
        _topBarController.forward();
        Future.delayed(const Duration(milliseconds: 100), () {
          _bottomBarController.forward();
        });
      } else {
        // 隐藏黑边：滑出屏幕外
        _topBarController.reverse();
        _bottomBarController.reverse();
      }
    }
  }
  
  /// 播放电影模式退出动画：黑边退回屏幕外
  @override
  void playMovieModeExitAnimation() {
    if (mounted && widget.isMovieMode) {
      // 让黑边退回屏幕外
      // 上边向上滑出屏幕（从0.0回到-1.0，即从屏幕顶部滑到屏幕上方外）
      _topBarController.reverse();
      
      // 下边向下滑出屏幕（从0.0回到1.0，即从屏幕底部滑到屏幕下方外）
      _bottomBarController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = SakiEngineConfig();
    final textScale = context.scaleFor(ComponentType.text);
    final uiScale = context.scaleFor(ComponentType.ui);

    return FadeTransition(
      opacity: _fadeAnimation,
      child: Stack(
        children: [
          // 背景遮罩（仅在非无遮罩模式下显示）
          if (!widget.isNoMask)
            IgnorePointer(
              child: Container(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                ),
              ),
            ),
          
          // 如果是电影模式且允许显示黑边，添加上下黑边
          if (widget.isMovieMode && _showCinematicBars) ..._buildCinematicBars(context),
          
          // 内容区域
          _buildContent(config, textScale, uiScale),

        ],
      ),
    );
  }

  Widget _buildNvlDialogue(NvlDialogue dialogue, SakiEngineConfig config, double textScale, double uiScale, int index) {
    // 构建统一格式的文本
    String displayText;
    if (dialogue.speaker != null) {
      // 有说话人：角色名: "对话内容"
      displayText = '${dialogue.speaker}: ${dialogue.dialogue}';//写给ai的话。不要把中文双引号改成英文双引号啊 显示出来很突兀
    } else {
      // 无说话人：直接显示内容（内心想法/旁白）
      displayText = dialogue.dialogue;
    }
    
    // 只对最后一条对话使用打字机效果
    bool isLastDialogue = index == widget.nvlDialogues.length - 1;
    
    // 为每个对话创建独立的淡入动画
    if (!_textFadeControllers.containsKey(index)) {
      final controller = AnimationController(
        duration: widget.isFastForwarding 
            ? Duration.zero // 快进模式下跳过动画
            : const Duration(milliseconds: 400),
        vsync: this,
      );
      _textFadeControllers[index] = controller;
      _textFadeAnimations[index] = Tween<double>(
        begin: 0.0,
        end: 1.0,
      ).animate(CurvedAnimation(
        parent: controller,
        curve: Curves.easeInOut,
      ));
      
      // 立即启动淡入动画，避免累积延迟
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.isCompleted == false) {
          if (widget.isFastForwarding) {
            controller.value = 1.0; // 快进模式下直接设置最终状态
          } else {
            controller.forward();
          }
        }
      });
    }
    
    return Padding(
      padding: EdgeInsets.only(bottom: 16 * uiScale),
      child: FadeTransition(
        opacity: _textFadeAnimations[index]!,
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center, // 垂直居中对齐
          children: [
            isLastDialogue
              ? TypewriterText(
                  text: displayText,
                  style: config.dialogueTextStyle.copyWith(
                    fontSize: config.dialogueTextStyle.fontSize! * textScale,
                    color: Colors.white,
                    height: 1.6,
                    letterSpacing: 0.3,
                    fontFamily: config.dialogueFontFamily,
                  ),
                  autoStart: true,
                  controller: _getOrCreateTypewriterController(index),
                  onComplete: () {
                    // 使用post frame callback避免在build期间调用setState
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !_isLastDialogueComplete) {
                        setState(() {
                          _isLastDialogueComplete = true;
                        });
                      }
                    });
                  },
                )
              : RichText(
                  text: TextSpan(
                    children: RichTextParser.createTextSpans(
                      displayText,
                      config.dialogueTextStyle.copyWith(
                        fontSize: config.dialogueTextStyle.fontSize! * textScale,
                        color: Colors.white,
                        height: 1.6,
                        letterSpacing: 0.3,
                        fontFamily: config.dialogueFontFamily,
                      ),
                    ),
                  ),
                ),
            // 箭头紧跟在文本后面
            if (isLastDialogue && _isLastDialogueComplete)
              Padding(
                padding: EdgeInsets.only(left: 4 * uiScale,top:5*uiScale),
                child: DialogueNextArrow(
                  visible: true,
                  fontSize: (config.dialogueTextStyle.fontSize! * textScale) * 0.7, // 缩小到70%
                  color: Colors.white,
                  speaker: dialogue.speaker,
                  speakerAlias: dialogue.speakerAlias, // 传递角色简写
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCinematicBars(BuildContext context) {
    final barHeight = MediaQuery.of(context).size.height * 0.12; // 12% 的屏幕高度
    
    return [
      // 上方黑边 - 从屏幕上方滑入
      AnimatedBuilder(
        animation: _topBarAnimation,
        builder: (context, child) {
          // _topBarAnimation: -1.0 -> 0.0
          // 实际位置: -barHeight -> 0 (从上方外滑入到屏幕顶部)
          final topPosition = _topBarAnimation.value * barHeight;
          return Positioned(
            top: topPosition,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: barHeight,
                color: Colors.black,
              ),
            ),
          );
        },
      ),
      // 下方黑边 - 从屏幕下方滑入
      AnimatedBuilder(
        animation: _bottomBarAnimation,
        builder: (context, child) {
          // _bottomBarAnimation: 1.0 -> 0.0
          // 实际位置: -barHeight -> 0 (从下方外滑入到屏幕底部)
          final bottomPosition = -_bottomBarAnimation.value * barHeight;
          return Positioned(
            bottom: bottomPosition,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: barHeight,
                color: Colors.black,
              ),
            ),
          );
        },
      ),
    ];
  }

  Widget _buildContent(SakiEngineConfig config, double textScale, double uiScale) {
    final topPadding = widget.isMovieMode 
        ? MediaQuery.of(context).size.height * 0.12 + config.nvlTop * uiScale
        : config.nvlTop * uiScale;
    
    final bottomPadding = widget.isMovieMode 
        ? MediaQuery.of(context).size.height * 0.12 + config.nvlBottom * uiScale
        : config.nvlBottom * uiScale;
    
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: config.nvlLeft * uiScale,
          right: config.nvlRight * uiScale,
          top: topPadding,
          bottom: bottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                child: NotificationListener<SizeChangedLayoutNotification>(
                  onNotification: (_) {
                    _scheduleScrollToBottom();
                    return false;
                  },
                  child: SizeChangedLayoutNotifier(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children:
                          widget.nvlDialogues.asMap().entries.map((entry) {
                        int index = entry.key;
                        NvlDialogue dialogue = entry.value;
                        return _buildNvlDialogue(
                          dialogue,
                          config,
                          textScale,
                          uiScale,
                          index,
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
