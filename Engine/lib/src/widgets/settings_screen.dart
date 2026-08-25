import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/utils/music_manager.dart';
import 'package:sakiengine/src/utils/ui_sound_manager.dart';
import 'package:sakiengine/src/widgets/confirm_dialog.dart';
import 'package:sakiengine/src/widgets/common/overlay_scaffold.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/widgets/settings/video_settings_tab.dart';
import 'package:sakiengine/src/widgets/settings/audio_settings_tab.dart';
import 'package:sakiengine/src/widgets/settings/gameplay_settings_tab.dart';
import 'package:sakiengine/src/widgets/settings/control_settings_tab.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final bool useOverlayScaffold;
  final bool showHeader;
  final bool showFooter;

  const SettingsScreen({
    super.key,
    required this.onClose,
    this.useOverlayScaffold = true,
    this.showHeader = true,
    this.showFooter = true,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsManager _settingsManager = SettingsManager();
  final MusicManager _musicManager = MusicManager();

  bool _isLoading = true;

  // 音频设置
  bool _musicEnabled = true;
  double _musicVolume = 0.8;
  double _soundVolume = 0.8;
  double _voiceVolume = 0.8;
  Map<String, double> _voiceCharacterVolumes = const {};

  // 玩法设置
  String _fastForwardMode = SettingsManager.defaultFastForwardMode;
  String _mouseRollbackBehavior = SettingsManager.defaultMouseRollbackBehavior;

  int _selectedTabIndex = 0;
  static const List<String> _tabTitleKeys = [
    'settings.tabs.video',
    'settings.tabs.audio',
    'settings.tabs.gameplay',
    'settings.tabs.control',
  ];

  late final Listenable _combinedListenable;

  @override
  void initState() {
    super.initState();
    _combinedListenable = Listenable.merge([
      SettingsManager(),
      LocalizationManager(),
    ]);
    _loadSettings();
  }

  Future<void> _loadSettings({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _isLoading = true);
    }

    try {
      await _settingsManager.init();

      final fastForwardMode = await _settingsManager.getFastForwardMode();
      final mouseRollbackBehavior = await _settingsManager
          .getMouseRollbackBehavior();

      final musicEnabled = _musicManager.isMusicEnabled;
      final musicVolume = _musicManager.musicVolume;
      final soundVolume = _musicManager.soundVolume;
      final voiceVolume = _musicManager.voiceVolume;
      final voiceCharacterVolumes = <String, double>{
        for (final profile in _musicManager.voiceCharacterProfiles)
          profile.id: _musicManager.voiceCharacterVolume(profile.id),
      };

      if (!mounted) return;

      setState(() {
        _fastForwardMode = fastForwardMode;
        _mouseRollbackBehavior = mouseRollbackBehavior;
        _musicEnabled = musicEnabled;
        _musicVolume = musicVolume;
        _soundVolume = soundVolume;
        _voiceVolume = voiceVolume;
        _voiceCharacterVolumes = voiceCharacterVolumes;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateMusicEnabled(bool value) async {
    setState(() => _musicEnabled = value);
    await _musicManager.setMusicEnabled(value);
  }

  Future<void> _updateMusicVolume(double value) async {
    setState(() => _musicVolume = value);
    await _musicManager.setMusicVolume(value);
  }

  Future<void> _updateSoundVolume(double value) async {
    setState(() => _soundVolume = value);
    await _musicManager.setSoundVolume(value);
  }

  Future<void> _updateVoiceVolume(double value) async {
    setState(() => _voiceVolume = value);
    await _musicManager.setVoiceVolume(value);
  }

  void _previewVoiceCharacterVolume(String characterId, double value) {
    setState(() {
      _voiceCharacterVolumes = {..._voiceCharacterVolumes, characterId: value};
    });
  }

  Future<void> _commitVoiceCharacterVolume(
    String characterId,
    double value,
  ) async {
    _previewVoiceCharacterVolume(characterId, value);
    await _musicManager.setVoiceCharacterVolume(characterId, value);

    VoiceCharacterProfile? selectedProfile;
    for (final profile in _musicManager.voiceCharacterProfiles) {
      if (profile.id == characterId) {
        selectedProfile = profile;
        break;
      }
    }
    if (selectedProfile == null || selectedProfile.previewVoiceAsset.isEmpty) {
      return;
    }
    await _musicManager.playVoice(selectedProfile.previewVoiceAsset);
  }

  Future<void> _updateFastForwardMode(String value) async {
    setState(() => _fastForwardMode = value);
    await _settingsManager.setFastForwardMode(value);
  }

  Future<void> _updateMouseRollbackBehavior(String value) async {
    setState(() => _mouseRollbackBehavior = value);
    await _settingsManager.setMouseRollbackBehavior(value);
  }

  Future<void> _resetToDefault() async {
    final localization = LocalizationManager();
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ConfirmDialog(
          title: localization.t('settings.reset.title'),
          content: localization.t('settings.reset.content'),
          confirmResult: true,
          cancelResult: false,
        );
      },
    );

    if (shouldReset == true) {
      await _settingsManager.resetToDefault();
      await _musicManager.setMusicEnabled(SettingsManager.defaultMusicEnabled);
      await _musicManager.setSoundEnabled(SettingsManager.defaultSoundEnabled);
      await _musicManager.setMusicVolume(SettingsManager.defaultMusicVolume);
      await _musicManager.setSoundVolume(SettingsManager.defaultSoundVolume);
      await _musicManager.setVoiceVolume(SettingsManager.defaultVoiceVolume);
      await _musicManager.resetVoiceCharacterVolumes();
      await _loadSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _combinedListenable,
      builder: (context, child) {
        // 当设置变化时，重新更新主题配置
        SakiEngineConfig().updateThemeForDarkMode();
        final localization = LocalizationManager();
        final content = _isLoading
            ? _buildLoadingContent()
            : _buildSettingsContent();

        if (widget.useOverlayScaffold) {
          return OverlayScaffold(
            title: localization.t('settings.title'),
            showHeader: widget.showHeader,
            content: content,
            footer: (!_isLoading && widget.showFooter) ? _buildFooter() : null,
            onClose: (_) => widget.onClose(),
          );
        }

        if (_isLoading || !widget.showFooter) {
          return content;
        }

        return Column(
          children: [
            Expanded(child: content),
            _buildFooter(),
          ],
        );
      },
    );
  }

  Widget _buildLoadingContent() {
    return Center(child: Container(color: const Color.fromARGB(0, 0, 0, 0)));
  }

  Widget _buildSettingsContent() {
    final config = SakiEngineConfig();
    final scale = context.scaleFor(ComponentType.ui);

    return Column(
      children: [
        _buildTabBar(config, scale),
        Expanded(child: _buildTabContent(config, scale)),
      ],
    );
  }

  Widget _buildTabBar(SakiEngineConfig config, double scale) {
    final localization = LocalizationManager();
    final tabTitles = _tabTitleKeys.map(localization.t).toList();

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 16 * scale,
        vertical: 8 * scale,
      ),
      decoration: BoxDecoration(
        color: config.themeColors.surface.withOpacity(0.3),
        border: Border(
          bottom: BorderSide(
            color: config.themeColors.primary.withOpacity(0.2),
            width: 1,
          ),
        ),
      ),
      alignment: Alignment.centerLeft, // 添加左对齐
      child: Row(
        mainAxisSize: MainAxisSize.min, // 让 Row 不铺满宽度
        children: List.generate(tabTitles.length, (index) {
          return _SettingsTab(
            title: tabTitles[index],
            isSelected: _selectedTabIndex == index,
            onTap: () => setState(() => _selectedTabIndex = index),
            config: config,
            scale: scale,
          );
        }),
      ),
    );
  }

  Widget _buildTabContent(SakiEngineConfig config, double scale) {
    switch (_selectedTabIndex) {
      case 0: // 画面设置
        return const VideoSettingsTab();
      case 1: // 音频设置
        return AudioSettingsTab(
          musicEnabled: _musicEnabled,
          musicVolume: _musicVolume,
          soundVolume: _soundVolume,
          voiceVolume: _voiceVolume,
          onMusicEnabledChanged: _updateMusicEnabled,
          onMusicVolumeChanged: _updateMusicVolume,
          onSoundVolumeChanged: _updateSoundVolume,
          onVoiceVolumeChanged: _updateVoiceVolume,
          voiceCharacterProfiles: _musicManager.voiceCharacterProfiles,
          voiceCharacterVolumes: _voiceCharacterVolumes,
          onVoiceCharacterVolumeChanged: _previewVoiceCharacterVolume,
          onVoiceCharacterVolumeChangeEnd: _commitVoiceCharacterVolume,
        );
      case 2: // 玩法设置
        return GameplaySettingsTab(
          mouseRollbackBehavior: _mouseRollbackBehavior,
          fastForwardMode: _fastForwardMode,
          onMouseRollbackBehaviorChanged: _updateMouseRollbackBehavior,
          onFastForwardModeChanged: _updateFastForwardMode,
        );
      case 3: // 操控设置
        return const ControlSettingsTab();
      default:
        return const VideoSettingsTab();
    }
  }

  Widget _buildFooter() {
    final config = SakiEngineConfig();
    final scale = context.scaleFor(ComponentType.ui);
    final localization = LocalizationManager();

    return Container(
      padding: EdgeInsets.all(24 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.primary.withOpacity(0.05),
        border: Border(
          top: BorderSide(
            color: config.themeColors.primary.withOpacity(0.2),
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _SettingsButton(
            text: localization.t('settings.action.reset'),
            icon: Icons.restore,
            onPressed: _resetToDefault,
            scale: scale,
            config: config,
            style: _SettingsButtonStyle.secondary,
          ),
          _SettingsButton(
            text: localization.t('settings.action.apply'),
            icon: Icons.check,
            onPressed: widget.onClose,
            scale: scale,
            config: config,
            style: _SettingsButtonStyle.primary,
          ),
        ],
      ),
    );
  }
}

enum _SettingsButtonStyle { primary, secondary }

class _SettingsButton extends StatefulWidget {
  final String text;
  final IconData icon;
  final VoidCallback onPressed;
  final double scale;
  final SakiEngineConfig config;
  final _SettingsButtonStyle style;

  const _SettingsButton({
    required this.text,
    required this.icon,
    required this.onPressed,
    required this.scale,
    required this.config,
    required this.style,
  });

  @override
  State<_SettingsButton> createState() => _SettingsButtonState();
}

class _SettingsButtonState extends State<_SettingsButton> {
  bool _isHovered = false;
  final _uiSoundManager = UISoundManager();

  @override
  Widget build(BuildContext context) {
    final isPrimary = widget.style == _SettingsButtonStyle.primary;
    final textScale = context.scaleFor(ComponentType.text);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          _uiSoundManager.playButtonClick();
          widget.onPressed();
        },
        onHover: (hovering) {
          setState(() => _isHovered = hovering);
          if (hovering) {
            _uiSoundManager.playButtonHover();
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.symmetric(
            horizontal: 24 * widget.scale,
            vertical: 12 * widget.scale,
          ),
          decoration: BoxDecoration(
            color: _isHovered
                ? (isPrimary
                      ? widget.config.themeColors.primary.withOpacity(0.9)
                      : widget.config.themeColors.primary.withOpacity(0.15))
                : (isPrimary
                      ? widget.config.themeColors.primary.withOpacity(0.8)
                      : widget.config.themeColors.primary.withOpacity(0.1)),
            border: Border.all(
              color: widget.config.themeColors.primary.withOpacity(0.5),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                color: isPrimary
                    ? Colors.white
                    : widget.config.themeColors.primary,
                size: 18 * widget.scale,
              ),
              SizedBox(width: 8 * widget.scale),
              Text(
                widget.text,
                style: widget.config.reviewTitleTextStyle.copyWith(
                  fontSize:
                      widget.config.reviewTitleTextStyle.fontSize! *
                      textScale *
                      0.5,
                  color: isPrimary
                      ? Colors.white
                      : widget.config.themeColors.primary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTab extends StatefulWidget {
  final String title;
  final bool isSelected;
  final VoidCallback onTap;
  final SakiEngineConfig config;
  final double scale;

  const _SettingsTab({
    required this.title,
    required this.isSelected,
    required this.onTap,
    required this.config,
    required this.scale,
  });

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _animationController;
  late Animation<double> _glowAnimation;
  final _uiSoundManager = UISoundManager();

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    if (widget.isSelected) {
      _animationController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSelected != widget.isSelected) {
      if (widget.isSelected) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textScale = context.scaleFor(ComponentType.text);

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _uiSoundManager.playButtonHover();
      },
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: () {
          _uiSoundManager.playButtonClick();
          widget.onTap();
        },
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Container(
              margin: EdgeInsets.symmetric(horizontal: 4 * widget.scale),
              padding: EdgeInsets.symmetric(
                horizontal: 16 * widget.scale,
                vertical: 12 * widget.scale,
              ),
              decoration: BoxDecoration(
                color: widget.isSelected
                    ? widget.config.themeColors.primary.withOpacity(0.15)
                    : (_isHovered
                          ? widget.config.themeColors.primary.withOpacity(0.08)
                          : Colors.transparent),
                border: Border.all(
                  color: widget.isSelected
                      ? widget.config.themeColors.primary.withOpacity(0.6)
                      : (_isHovered
                            ? widget.config.themeColors.primary.withOpacity(0.3)
                            : Colors.transparent),
                  width: widget.isSelected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(
                  widget.config.baseWindowBorder > 0
                      ? widget.config.baseWindowBorder * widget.scale
                      : 0 * widget.scale,
                ),
                boxShadow: widget.isSelected
                    ? [
                        BoxShadow(
                          color: widget.config.themeColors.primary.withOpacity(
                            0.2 * _glowAnimation.value,
                          ),
                          blurRadius: 8 * widget.scale * _glowAnimation.value,
                          offset: Offset(0, 2 * widget.scale),
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: Text(
                  widget.title,
                  style: widget.config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        widget.config.reviewTitleTextStyle.fontSize! *
                        textScale *
                        0.65,
                    color: widget.isSelected
                        ? widget.config.themeColors.primary
                        : widget.config.themeColors.primary.withOpacity(0.7),
                    fontWeight: widget.isSelected
                        ? FontWeight.bold
                        : FontWeight.w500,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
