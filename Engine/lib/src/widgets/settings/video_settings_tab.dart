import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/utils/platform_window_manager_io.dart'
    if (dart.library.html) 'package:sakiengine/src/utils/platform_window_manager_web.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/widgets/game_style_switch.dart';
import 'package:sakiengine/src/widgets/game_style_slider.dart';
import 'package:sakiengine/src/widgets/typewriter_animation_manager.dart';
import 'package:sakiengine/src/widgets/typewriter_preview.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/widgets/game_style_dropdown.dart';

class VideoSettingsTab extends StatefulWidget {
  const VideoSettingsTab({super.key});

  @override
  State<VideoSettingsTab> createState() => _VideoSettingsTabState();
}

class _VideoSettingsTabState extends State<VideoSettingsTab> {
  final SettingsManager _settingsManager = SettingsManager();

  double _dialogOpacity = SettingsManager.defaultDialogOpacity;
  bool _isFullscreen = SettingsManager.defaultIsFullscreen;
  bool _darkMode = SettingsManager.defaultDarkMode;
  bool _isLoading = true;

  // 打字机设置
  double _typewriterCharsPerSecond =
      SettingsManager.defaultTypewriterCharsPerSecond;
  bool _skipPunctuationDelay = SettingsManager.defaultSkipPunctuationDelay;
  bool _speakerAnimation = SettingsManager.defaultSpeakerAnimation;
  bool _autoHideQuickMenu = SettingsManager.defaultAutoHideQuickMenu;
  bool _mouseParallaxEnabled = SettingsManager.defaultMouseParallaxEnabled;
  bool _showFpsOverlay = SettingsManager.defaultShowFpsOverlay;
  String _menuDisplayMode = SettingsManager.defaultMenuDisplayMode;
  String _windowAspectRatioPreset =
      SettingsManager.defaultGameWindowAspectRatioPreset;
  String _dialogueFontFamily = SettingsManager.defaultDialogueFontFamily;

  // 预览文本（在设置界面生命周期内固定）
  late String _previewText;

  late SupportedLanguage _selectedLanguage;
  late final Listenable _combinedListenable;

  @override
  void initState() {
    super.initState();
    // 在设置界面初始化时选择一次随机文本
    _previewText = TypewriterPreview.getRandomPreviewText();
    _selectedLanguage = LocalizationManager().currentLanguage;
    _combinedListenable = Listenable.merge([
      _settingsManager,
      LocalizationManager(),
    ]);
    _settingsManager.addListener(_handleSettingsManagerChanged);
    _loadSettings();
  }

  @override
  void dispose() {
    _settingsManager.removeListener(_handleSettingsManagerChanged);
    super.dispose();
  }

  void _handleSettingsManagerChanged() {
    if (!mounted) return;
    _loadSettings(showLoading: false);
  }

  Future<void> _loadSettings({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _isLoading = true);
    }

    try {
      await _settingsManager.init();

      final dialogOpacity = await _settingsManager.getDialogOpacity();
      final isFullscreen = await _settingsManager.getIsFullscreen();
      final darkMode = await _settingsManager.getDarkMode();
      final typewriterSpeed =
          await _settingsManager.getTypewriterCharsPerSecond();
      final skipPunctuation = await _settingsManager.getSkipPunctuationDelay();
      final speakerAnimation = await _settingsManager.getSpeakerAnimation();
      final autoHideQuickMenu = await _settingsManager.getAutoHideQuickMenu();
      final mouseParallax = await _settingsManager.getMouseParallaxEnabled();
      final showFpsOverlay = await _settingsManager.getShowFpsOverlay();
      final menuDisplayMode = await _settingsManager.getMenuDisplayMode();
      final windowAspectRatioPreset =
          await _settingsManager.getGameWindowAspectRatioPreset();
      final dialogueFont = await _settingsManager.getDialogueFontFamily();

      final selectedLanguage = LocalizationManager().currentLanguage;
      final previewText =
          showLoading ? TypewriterPreview.getRandomPreviewText() : _previewText;

      if (!mounted) return;

      setState(() {
        _dialogOpacity = dialogOpacity;
        _isFullscreen = isFullscreen;
        _darkMode = darkMode;
        _typewriterCharsPerSecond = typewriterSpeed;
        _skipPunctuationDelay = skipPunctuation;
        _speakerAnimation = speakerAnimation;
        _autoHideQuickMenu = autoHideQuickMenu;
        _mouseParallaxEnabled = mouseParallax;
        _showFpsOverlay = showFpsOverlay;
        _menuDisplayMode = menuDisplayMode;
        _windowAspectRatioPreset = windowAspectRatioPreset;
        _dialogueFontFamily = dialogueFont;
        _selectedLanguage = selectedLanguage;
        _previewText = previewText;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateDialogOpacity(double value) async {
    setState(() => _dialogOpacity = value);
    await _settingsManager.setDialogOpacity(value);
  }

  Future<void> _updateFullscreen(bool value) async {
    setState(() => _isFullscreen = value);
    await _settingsManager.setIsFullscreen(value);
  }

  Future<void> _updateDarkMode(bool value) async {
    setState(() => _darkMode = value);
    await _settingsManager.setDarkMode(value);
    // 确保主题配置立即更新
    SakiEngineConfig().updateThemeForDarkMode();
    // 强制重建当前设置屏幕
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _updateTypewriterCharsPerSecond(double value) async {
    setState(() => _typewriterCharsPerSecond = value);
    await _settingsManager.setTypewriterCharsPerSecond(value);
    // 通知所有TypewriterAnimationManager实例更新设置
    TypewriterAnimationManager.notifySettingsChanged();
  }

  Future<void> _updateSkipPunctuationDelay(bool value) async {
    setState(() => _skipPunctuationDelay = value);
    await _settingsManager.setSkipPunctuationDelay(value);
    // 通知所有TypewriterAnimationManager实例更新设置
    TypewriterAnimationManager.notifySettingsChanged();
  }

  Future<void> _updateSpeakerAnimation(bool value) async {
    setState(() => _speakerAnimation = value);
    await _settingsManager.setSpeakerAnimation(value);
  }

  Future<void> _updateAutoHideQuickMenu(bool value) async {
    setState(() => _autoHideQuickMenu = value);
    await _settingsManager.setAutoHideQuickMenu(value);
  }

  Future<void> _updateMouseParallax(bool value) async {
    setState(() => _mouseParallaxEnabled = value);
    await _settingsManager.setMouseParallaxEnabled(value);
  }

  Future<void> _updateShowFpsOverlay(bool value) async {
    setState(() => _showFpsOverlay = value);
    await _settingsManager.setShowFpsOverlay(value);
  }

  Future<void> _updateMenuDisplayMode(String value) async {
    setState(() => _menuDisplayMode = value);
    await _settingsManager.setMenuDisplayMode(value);
  }

  Future<void> _updateWindowAspectRatioPreset(String value) async {
    final ratio = SettingsManager.gameWindowAspectRatioPresets[value];
    if (ratio == null) {
      return;
    }
    setState(() => _windowAspectRatioPreset = value);
    await _settingsManager.setGameWindowAspectRatioPreset(value);
    await PlatformWindowManager.applyAspectRatioPresetByKeepingHeight(ratio);
  }

  Future<void> _updateDialogueFontFamily(String value) async {
    setState(() => _dialogueFontFamily = value);
    await _settingsManager.setDialogueFontFamily(value);
    // 更新config
    SakiEngineConfig().updateThemeForDarkMode();
  }

  Future<void> _updateLanguage(SupportedLanguage language) async {
    if (_selectedLanguage == language) {
      return;
    }
    await LocalizationManager().switchLanguage(language);
    if (!mounted) return;
    setState(() {
      _selectedLanguage = language;
      _previewText = TypewriterPreview.getRandomPreviewText();
    });
  }

  String _fpsOverlayTitle(SupportedLanguage language) {
    switch (language) {
      case SupportedLanguage.zhHant:
        return 'FPS 顯示';
      case SupportedLanguage.en:
        return 'FPS Overlay';
      case SupportedLanguage.ja:
        return 'FPS 表示';
      case SupportedLanguage.zhHans:
        return 'FPS 显示';
    }
  }

  String _fpsOverlayDescription(SupportedLanguage language) {
    switch (language) {
      case SupportedLanguage.zhHant:
        return '在畫面右上角顯示即時幀率資訊';
      case SupportedLanguage.en:
        return 'Show real-time frame rate in the top-right corner';
      case SupportedLanguage.ja:
        return '画面右上にリアルタイム FPS を表示します';
      case SupportedLanguage.zhHans:
        return '在画面右上角显示实时帧率信息';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _combinedListenable,
      builder: (context, child) {
        // 当设置变化时，重新更新主题配置
        SakiEngineConfig().updateThemeForDarkMode();

        if (_isLoading) {
          return Center(
            child: Container(color: const Color.fromARGB(0, 0, 0, 0)),
          );
        }

        return _buildVideoSettings();
      },
    );
  }

  Widget _buildVideoSettings() {
    final config = SakiEngineConfig();
    final scale = context.scaleFor(ComponentType.ui);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideLayout = constraints.maxWidth > constraints.maxHeight;

        if (isWideLayout) {
          return _buildVideoSettingsDualColumn(config, scale, constraints);
        } else {
          return _buildVideoSettingsSingleColumn(config, scale);
        }
      },
    );
  }

  Widget _buildVideoSettingsSingleColumn(
      SakiEngineConfig config, double scale) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(32 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLanguageSelector(config, scale),
            SizedBox(height: 40 * scale),
            _buildDialogueFontSelector(config, scale),
            SizedBox(height: 40 * scale),
            _buildOpacitySlider(config, scale),
            SizedBox(height: 40 * scale),
            _buildMenuDisplayModeDropdown(config, scale),
            SizedBox(height: 40 * scale),
            _buildFullscreenToggle(config, scale),
            SizedBox(height: 40 * scale),
            if (!_isFullscreen &&
                PlatformWindowManager.supportsWindowAspectRatioPresetSwitching)
              _buildWindowAspectRatioDropdown(config, scale),
            if (!_isFullscreen &&
                PlatformWindowManager.supportsWindowAspectRatioPresetSwitching)
              SizedBox(height: 40 * scale),
            _buildDarkModeToggle(config, scale),
            SizedBox(height: 40 * scale),
            _buildSpeakerAnimationToggle(config, scale),
            SizedBox(height: 40 * scale),
            _buildAutoHideQuickMenuSetting(config, scale),
            SizedBox(height: 40 * scale),
            _buildMouseParallaxToggle(config, scale),
            SizedBox(height: 40 * scale),
            _buildFpsOverlayToggle(config, scale),
            SizedBox(height: 40 * scale),
            _buildTypewriterSpeedSlider(config, scale),
            SizedBox(height: 40 * scale), // 底部间距
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSettingsDualColumn(
      SakiEngineConfig config, double scale, BoxConstraints constraints) {
    return Stack(
      children: [
        // 主要内容区域
        Row(
          crossAxisAlignment: CrossAxisAlignment.start, // 确保顶对齐
          children: [
            // 左列
            Expanded(
              child: ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    left: 32 * scale,
                    top: 32 * scale,
                    bottom: 32 * scale,
                    right: 32 * scale,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildOpacitySlider(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildTypewriterSpeedSlider(config, scale),
                      SizedBox(height: 40 * scale), // 底部间距
                    ],
                  ),
                ),
              ),
            ),

            // 右列间距
            SizedBox(width: 0), // 移除间距，让分割线居中

            // 右列
            Expanded(
              child: ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    left: 32 * scale,
                    top: 32 * scale,
                    bottom: 32 * scale,
                    right: 32 * scale,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLanguageSelector(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildDialogueFontSelector(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildMenuDisplayModeDropdown(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildFullscreenToggle(config, scale),
                      SizedBox(height: 40 * scale),
                      if (!_isFullscreen &&
                          PlatformWindowManager
                              .supportsWindowAspectRatioPresetSwitching)
                        _buildWindowAspectRatioDropdown(config, scale),
                      if (!_isFullscreen &&
                          PlatformWindowManager
                              .supportsWindowAspectRatioPresetSwitching)
                        SizedBox(height: 40 * scale),
                      _buildDarkModeToggle(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildSpeakerAnimationToggle(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildAutoHideQuickMenuSetting(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildMouseParallaxToggle(config, scale),
                      SizedBox(height: 40 * scale),
                      _buildFpsOverlayToggle(config, scale),
                      SizedBox(height: 40 * scale),
                      // 可以在这里添加更多右列设置项
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),

        // 固定的中间分割线 - 简化居中定位
        Positioned.fill(
          child: Align(
            alignment: Alignment.center,
            child: Container(
              width: 1 * scale,
              height: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    config.themeColors.primary.withOpacity(0.3),
                    config.themeColors.primary.withOpacity(0.6),
                    config.themeColors.primary.withOpacity(0.3),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.2, 0.5, 0.8, 1.0],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOpacitySlider(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.opacity,
                color: config.themeColors.primary,
                size: 24 * scale,
              ),
              SizedBox(width: 16 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localization.t('settings.opacity.title'),
                      style: config.reviewTitleTextStyle.copyWith(
                        fontSize: config.reviewTitleTextStyle.fontSize! *
                            textScale *
                            0.7,
                        color: config.themeColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      localization.t('settings.opacity.description'),
                      style: config.dialogueTextStyle.copyWith(
                        fontSize: config.dialogueTextStyle.fontSize! *
                            textScale *
                            0.6,
                        color: config.themeColors.primary.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16 * scale),
          GameStyleSlider(
            value: _dialogOpacity,
            min: 0.3,
            max: 1.0,
            divisions: 7,
            scale: scale,
            config: config,
            onChanged: _updateDialogOpacity,
            showValue: false,
          ),
          SizedBox(height: 8 * scale),
          Text(
            localization.t('settings.opacity.current', params: {
              'value': (_dialogOpacity * 100).round().toString(),
            }),
            style: config.dialogueTextStyle.copyWith(
              fontSize: config.dialogueTextStyle.fontSize! * textScale * 0.5,
              color: config.themeColors.primary.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreenToggle(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.fullscreen.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.fullscreen.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleSwitch(
            value: _isFullscreen,
            onChanged: _updateFullscreen,
            scale: scale,
            config: config,
          ),
        ],
      ),
    );
  }

  Widget _buildDarkModeToggle(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _darkMode ? Icons.dark_mode : Icons.light_mode,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.darkMode.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.darkMode.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleSwitch(
            value: _darkMode,
            onChanged: _updateDarkMode,
            scale: scale,
            config: config,
          ),
        ],
      ),
    );
  }

  Widget _buildSpeakerAnimationToggle(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _speakerAnimation ? Icons.animation : Icons.text_fields,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.speakerAnimation.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.speakerAnimation.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleSwitch(
            value: _speakerAnimation,
            onChanged: _updateSpeakerAnimation,
            scale: scale,
            config: config,
          ),
        ],
      ),
    );
  }

  Widget _buildAutoHideQuickMenuSetting(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome,
            color: config.themeColors.primary,
            size: 20 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.autoHideQuickMenu.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.autoHideQuickMenu.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleSwitch(
            value: _autoHideQuickMenu,
            onChanged: _updateAutoHideQuickMenu,
            scale: scale,
            config: config,
          ),
        ],
      ),
    );
  }

  Widget _buildMouseParallaxToggle(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _mouseParallaxEnabled ? Icons.layers : Icons.layers_clear,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.mouseParallax.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.mouseParallax.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleSwitch(
            value: _mouseParallaxEnabled,
            onChanged: _updateMouseParallax,
            scale: scale,
            config: config,
          ),
        ],
      ),
    );
  }

  Widget _buildFpsOverlayToggle(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final title = _fpsOverlayTitle(_selectedLanguage);
    final description = _fpsOverlayDescription(_selectedLanguage);

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _showFpsOverlay ? Icons.speed : Icons.speed_outlined,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  description,
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleSwitch(
            value: _showFpsOverlay,
            onChanged: _updateShowFpsOverlay,
            scale: scale,
            config: config,
          ),
        ],
      ),
    );
  }

  Widget _buildTypewriterSpeedSlider(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.speed,
                color: config.themeColors.primary,
                size: 24 * scale,
              ),
              SizedBox(width: 16 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localization.t('settings.typewriterSpeed.title'),
                      style: config.reviewTitleTextStyle.copyWith(
                        fontSize: config.reviewTitleTextStyle.fontSize! *
                            textScale *
                            0.7,
                        color: config.themeColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      localization.t('settings.typewriterSpeed.description'),
                      style: config.dialogueTextStyle.copyWith(
                        fontSize: config.dialogueTextStyle.fontSize! *
                            textScale *
                            0.6,
                        color: config.themeColors.primary.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 16 * scale),
          GameStyleSlider(
            value: _typewriterCharsPerSecond,
            min: 10.0,
            max: 200.0,
            divisions: 19,
            onChanged: _updateTypewriterCharsPerSecond,
            config: config,
            scale: scale,
            showValue: false, // 关闭内置的值显示
          ),
          SizedBox(height: 8 * scale),
          Text(
            _typewriterCharsPerSecond >= 200.0
                ? localization.t('settings.typewriterSpeed.instant')
                : localization.t('settings.typewriterSpeed.current', params: {
                    'value': _typewriterCharsPerSecond.round().toString(),
                  }),
            style: config.dialogueTextStyle.copyWith(
              fontSize: config.dialogueTextStyle.fontSize! * textScale * 0.5,
              color: config.themeColors.primary.withOpacity(0.8),
            ),
          ),
          SizedBox(height: 16 * scale),
          // 标点符号停顿设置
          Row(
            children: [
              Expanded(
                child: Text(
                  localization.t('settings.punctuationPause.title'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary,
                  ),
                ),
              ),
              GameStyleSwitch(
                value: !_skipPunctuationDelay, // 注意：这里取反，因为设置是"跳过"，但UI显示为"停顿"
                onChanged: (value) => _updateSkipPunctuationDelay(!value),
                config: config,
                scale: scale * 0.8,
              ),
            ],
          ),
          Text(
            localization.t('settings.punctuationPause.description'),
            style: config.dialogueTextStyle.copyWith(
              fontSize: config.dialogueTextStyle.fontSize! * textScale * 0.5,
              color: config.themeColors.primary.withOpacity(0.6),
            ),
          ),
          // Add live preview widget
          TypewriterPreview(
            charsPerSecond: _typewriterCharsPerSecond,
            skipPunctuationDelay: _skipPunctuationDelay,
            config: config,
            scale: scale,
            previewText: _previewText, // 传入预选的文本
            fontFamily: _dialogueFontFamily, // 传入选定的字体
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageSelector(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();
    final languages = localization.loadedLanguages;

    if (languages.isEmpty) {
      return const SizedBox.shrink();
    }

    final selectedLanguage = languages.contains(_selectedLanguage)
        ? _selectedLanguage
        : languages.first;

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.language,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.language.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.language.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleDropdown<SupportedLanguage>(
            items: languages
                .map(
                  (language) => GameStyleDropdownItem<SupportedLanguage>(
                    value: language,
                    label: localization.displayName(language),
                  ),
                )
                .toList(),
            value: selectedLanguage,
            onChanged: _updateLanguage,
            scale: scale,
            textScale: textScale,
            config: config,
            width: 200 * scale,
          ),
        ],
      ),
    );
  }

  Widget _buildMenuDisplayModeDropdown(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    final items = [
      GameStyleDropdownItem<String>(
        value: 'windowed',
        label: localization.t('settings.menuDisplay.window'),
        icon: Icons.crop_free,
      ),
      GameStyleDropdownItem<String>(
        value: 'fullscreen',
        label: localization.t('settings.menuDisplay.fill'),
        icon: Icons.aspect_ratio,
      ),
    ];

    final currentModeText = _menuDisplayMode == 'fullscreen'
        ? localization.t('settings.menuDisplay.fill')
        : localization.t('settings.menuDisplay.window');

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _menuDisplayMode == 'fullscreen'
                ? Icons.aspect_ratio
                : Icons.crop_free,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.menuDisplay.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  '${localization.t('settings.menuDisplay.description')} (${localization.t('settings.menuDisplay.current')}: $currentModeText)',
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleDropdown<String>(
            items: items,
            value: _menuDisplayMode,
            onChanged: _updateMenuDisplayMode,
            scale: scale,
            textScale: textScale,
            config: config,
            width: 200 * scale,
          ),
        ],
      ),
    );
  }

  Widget _buildWindowAspectRatioDropdown(
    SakiEngineConfig config,
    double scale,
  ) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();
    final items = SettingsManager.gameWindowAspectRatioPresets.keys
        .map(
          (preset) => GameStyleDropdownItem<String>(
            value: preset,
            label: preset,
            icon: Icons.aspect_ratio,
          ),
        )
        .toList();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.aspect_ratio,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.aspectRatio.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.aspectRatio.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleDropdown<String>(
            items: items,
            value: _windowAspectRatioPreset,
            onChanged: _updateWindowAspectRatioPreset,
            scale: scale,
            textScale: textScale,
            config: config,
            width: 160 * scale,
          ),
        ],
      ),
    );
  }

  Widget _buildDialogueFontSelector(SakiEngineConfig config, double scale) {
    final textScale = context.scaleFor(ComponentType.text);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.5),
        border: Border.all(
          color: config.themeColors.primary.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.font_download_outlined,
            color: config.themeColors.primary,
            size: 24 * scale,
          ),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  localization.t('settings.dialogueFont.title'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! * textScale * 0.7,
                    color: config.themeColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  localization.t('settings.dialogueFont.description'),
                  style: config.dialogueTextStyle.copyWith(
                    fontSize:
                        config.dialogueTextStyle.fontSize! * textScale * 0.6,
                    color: config.themeColors.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 16 * scale),
          GameStyleDropdown<String>(
            items: [
              GameStyleDropdownItem<String>(
                value: 'SourceHanSansCN',
                label: localization.t('settings.dialogueFont.sourceHanSans'),
              ),
              GameStyleDropdownItem<String>(
                value: 'ChillJinshuSongPro_Soft',
                label: localization.t('settings.dialogueFont.hanChanJinShu'),
              ),
            ],
            value: _dialogueFontFamily,
            onChanged: _updateDialogueFontFamily,
            scale: scale,
            textScale: textScale,
            config: config,
            width: 200 * scale,
          ),
        ],
      ),
    );
  }
}
