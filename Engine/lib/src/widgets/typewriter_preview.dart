import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'dart:math';

typedef TypewriterPreviewTextProvider = List<String> Function(
  SupportedLanguage language,
);

class TypewriterPreview extends StatefulWidget {
  final double charsPerSecond;
  final bool skipPunctuationDelay;
  final SakiEngineConfig config;
  final double scale;
  final String? previewText; // 新增：预选的展示文本
  final String? fontFamily; // 新增：字体

  const TypewriterPreview({
    super.key,
    required this.charsPerSecond,
    required this.skipPunctuationDelay,
    required this.config,
    required this.scale,
    this.previewText, // 可选参数
    this.fontFamily, // 可选参数
  });

  @override
  State<TypewriterPreview> createState() => _TypewriterPreviewState();

  // 静态方法：获取随机文本，供外部使用。项目可注册自定义预览文本；未注册时使用引擎默认文案。
  static final Random _randomGenerator = Random();
  static TypewriterPreviewTextProvider? _previewTextProvider;

  static void setPreviewTextProvider(
    TypewriterPreviewTextProvider? provider,
  ) {
    _previewTextProvider = provider;
  }

  static void setPreviewTexts(
    Map<SupportedLanguage, List<String>> previewTexts,
  ) {
    final normalized = <SupportedLanguage, List<String>>{};
    for (final entry in previewTexts.entries) {
      final texts = entry.value
          .where((text) => text.trim().isNotEmpty)
          .toList(growable: false);
      if (texts.isNotEmpty) {
        normalized[entry.key] = List.unmodifiable(texts);
      }
    }

    _previewTextProvider =
        (language) => normalized[language] ?? const <String>[];
  }

  static void clearPreviewTextProvider() {
    _previewTextProvider = null;
  }

  static String getRandomPreviewText([SupportedLanguage? language]) {
    final localization = LocalizationManager();
    final resolvedLanguage = language ?? localization.currentLanguage;
    final customTexts = _previewTextProvider?.call(resolvedLanguage);
    if (customTexts != null && customTexts.isNotEmpty) {
      return customTexts[_randomGenerator.nextInt(customTexts.length)];
    }
    if (_previewTextKeys.isEmpty) {
      return '';
    }
    final key =
        _previewTextKeys[_randomGenerator.nextInt(_previewTextKeys.length)];
    return localization.t(key);
  }

  // 预设的示例文本列表
  static const List<String> _previewTextKeys = [
    'quotes.preview.1',
    'quotes.preview.2',
    'quotes.preview.3',
    'quotes.preview.4',
    'quotes.preview.5',
    'quotes.preview.6',
    'quotes.preview.7',
    'quotes.preview.8',
  ];
}

class _TypewriterPreviewState extends State<TypewriterPreview>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<int> _charAnimation;

  late String _currentPreviewText;

  @override
  void initState() {
    super.initState();
    // 使用传入的文本，如果没有则随机选择
    _currentPreviewText =
        widget.previewText ?? TypewriterPreview.getRandomPreviewText();
    _initAnimation();
    _startAnimation();
  }

  void _initAnimation() {
    _animationController = AnimationController(
      duration: Duration(
        milliseconds: widget.charsPerSecond >= 200.0
            ? 100 // 瞬间显示时的最小持续时间
            : (_currentPreviewText.length * 1000 / widget.charsPerSecond)
                .round(),
      ),
      vsync: this,
    );

    _charAnimation = IntTween(
      begin: 0,
      end: _currentPreviewText.length,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: widget.charsPerSecond >= 200.0 ? Curves.easeInOut : Curves.linear,
    ));
  }

  void _startAnimation() {
    _animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        // 动画完成后等待1秒再重新开始，但不更换文本
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) {
            _animationController.reset();
            _animationController.forward();
          }
        });
      }
    });

    _animationController.forward();
  }

  @override
  void didUpdateWidget(TypewriterPreview oldWidget) {
    super.didUpdateWidget(oldWidget);

    bool shouldRestart = false;
    String? updatedText;

    if (oldWidget.previewText != widget.previewText) {
      updatedText =
          widget.previewText ?? TypewriterPreview.getRandomPreviewText();
      shouldRestart = true;
    }

    if (oldWidget.charsPerSecond != widget.charsPerSecond ||
        oldWidget.skipPunctuationDelay != widget.skipPunctuationDelay ||
        oldWidget.fontFamily != widget.fontFamily) {
      shouldRestart = true;
    }

    if (shouldRestart) {
      _animationController.dispose();
      if (updatedText != null) {
        _currentPreviewText = updatedText;
      }
      _initAnimation();
      _startAnimation();
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  String _getVisibleText(int charCount) {
    if (charCount <= 0) return '';
    if (charCount >= _currentPreviewText.length) return _currentPreviewText;

    String visibleText = _currentPreviewText.substring(0, charCount);

    // 如果启用标点符号延迟效果，在标点符号处添加适当的停顿感
    if (!widget.skipPunctuationDelay &&
        charCount < _currentPreviewText.length) {
      final currentChar = _currentPreviewText[charCount - 1];
      if (RegExp(r'[。！？；，、]').hasMatch(currentChar)) {
        // 在标点符号后添加一个光标闪烁效果来模拟停顿
        return visibleText;
      }
    }

    return visibleText;
  }

  @override
  Widget build(BuildContext context) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(12 * widget.scale),
      margin: EdgeInsets.only(top: 12 * widget.scale),
      decoration: BoxDecoration(
        color: widget.config.themeColors.surface.withOpacity(0.3),
        border: Border.all(
          color: widget.config.themeColors.primary.withOpacity(0.2),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(0 * widget.scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.preview,
                color: widget.config.themeColors.primary.withOpacity(0.7),
                size: 16 * widget.scale,
              ),
              SizedBox(width: 8 * widget.scale),
              Text(
                localization.t('settings.typewriterPreview.title'),
                style: widget.config.dialogueTextStyle.copyWith(
                  fontSize: widget.config.dialogueTextStyle.fontSize! *
                      textScale *
                      0.55,
                  color: widget.config.themeColors.primary.withOpacity(0.7),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SizedBox(height: 8 * widget.scale),
          Container(
            width: double.infinity,
            constraints: BoxConstraints(minHeight: 60 * widget.scale),
            padding: EdgeInsets.all(8 * widget.scale),
            decoration: BoxDecoration(
              color: widget.config.themeColors.background.withOpacity(0.5),
              borderRadius: BorderRadius.circular(2 * widget.scale),
            ),
            child: AnimatedBuilder(
              animation: _charAnimation,
              builder: (context, child) {
                final visibleText = _getVisibleText(_charAnimation.value);
                final showCursor =
                    _charAnimation.value < _currentPreviewText.length;

                return RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: visibleText,
                        style: widget.config.dialogueTextStyle.copyWith(
                          fontSize: widget.config.dialogueTextStyle.fontSize! *
                              textScale *
                              0.5,
                          color: widget.config.themeColors.onSurface,
                          height: 1.4,
                          fontFamily: widget.fontFamily ??
                              widget.config.dialogueFontFamily,
                        ),
                      ),
                      if (showCursor && widget.charsPerSecond < 200.0)
                        TextSpan(
                          text: '|',
                          style: widget.config.dialogueTextStyle.copyWith(
                            fontSize:
                                widget.config.dialogueTextStyle.fontSize! *
                                    textScale *
                                    0.5,
                            color: widget.config.themeColors.primary,
                            fontFamily: widget.fontFamily ??
                                widget.config.dialogueFontFamily,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
