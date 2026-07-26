import 'dart:async';
import 'dart:io' show Directory, Platform, Process, ProcessStartMode;
import 'dart:ui' show PlatformDispatcher;

import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sakiengine/src/config/runtime_project_config.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/core/game_module.dart';
import 'package:sakiengine/src/core/project_module_loader.dart';
import 'package:sakiengine/src/game/save_load_manager.dart';
import 'package:sakiengine/src/integrations/steam/steamworks_manager.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/utils/debug_logger.dart';
import 'package:sakiengine/src/utils/global_variable_manager.dart';
import 'package:sakiengine/src/utils/performance_monitor.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';
import 'package:sakiengine/src/utils/transition_prewarming.dart';
import 'package:sakiengine/src/utils/ui_sound_manager.dart';
import 'package:sakiengine/src/widgets/common/black_screen_transition.dart';
import 'package:sakiengine/src/widgets/common/exit_confirmation_dialog.dart';
import 'package:sakiengine/src/widgets/common/frame_rate_limiter.dart';
import 'package:sakiengine/src/widgets/common/fps_overlay.dart';
import 'package:sakiengine/src/rendering/image_sampling.dart';

import '../utils/platform_window_manager_io.dart'
    if (dart.library.html) '../utils/platform_window_manager_web.dart';

enum AppState { mainMenu, inGame }

bool _isTruthyFlag(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized == '1' ||
      normalized == 'true' ||
      normalized == 'yes' ||
      normalized == 'on';
}

bool _isMpvVerboseLoggingEnabled() {
  const fromDefine = String.fromEnvironment('SAKI_MPV_VERBOSE');
  if (fromDefine.isNotEmpty) {
    return _isTruthyFlag(fromDefine);
  }

  if (!kIsWeb) {
    final fromEnv = Platform.environment['SAKI_MPV_VERBOSE'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return _isTruthyFlag(fromEnv);
    }
  }

  return false;
}

bool _isNoisyMpvLogLine(String line) {
  if (!line.contains('MPV:')) {
    return false;
  }
  return line.contains('property not found _setProperty(osc') ||
      line.contains('lavf: Failed to create file cache');
}

bool _isKnownNoisyFrameworkError(Object error) {
  final message = error.toString();
  return message.contains(
        'Attempted to send a key down event when no keys are in keysPressed',
      ) ||
      message.contains('PlatformException(abort, Loading interrupted');
}

bool _isNoisyFrameworkLogLine(String line) {
  final trimmed = line.trim();
  return trimmed == 'Unable to parse JSON message:' ||
      trimmed == 'The document is empty.' ||
      line.contains(
        'Another exception was thrown: Attempted to send a key down event when no keys are in keysPressed.',
      ) ||
      line.contains('PlatformException(abort, Loading interrupted');
}

bool _showcaseResourceDirectoryOpened = false;

bool _isDesktopPlatform() {
  if (kIsWeb) {
    return false;
  }
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

Future<bool> _startDetachedProcess(
  String executable,
  List<String> arguments, {
  bool runInShell = false,
}) async {
  try {
    await Process.start(
      executable,
      arguments,
      runInShell: runInShell,
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _openShowcaseResourceDirectoryIfNeeded() async {
  if (!kSakiShowMode ||
      _showcaseResourceDirectoryOpened ||
      !_isDesktopPlatform()) {
    return;
  }
  _showcaseResourceDirectoryOpened = true;

  try {
    final gamePath = await GamePathResolver.resolveGamePath();
    if (gamePath == null || gamePath.isEmpty) {
      if (kEngineDebugMode) {
        print('演出模式: 未找到游戏目录，跳过自动打开资源目录');
      }
      return;
    }

    var targetDir = Directory('$gamePath${Platform.pathSeparator}Assets');
    if (!await targetDir.exists()) {
      targetDir = Directory(gamePath);
    }
    if (!await targetDir.exists()) {
      if (kEngineDebugMode) {
        print('演出模式: 资源目录不存在，跳过自动打开: ${targetDir.path}');
      }
      return;
    }

    final path = targetDir.path;
    bool opened = false;
    if (Platform.isMacOS) {
      opened = await _startDetachedProcess('open', <String>[path]);
    } else if (Platform.isWindows) {
      opened = await _startDetachedProcess(
        'explorer',
        <String>[path],
        runInShell: true,
      );
    } else if (Platform.isLinux) {
      opened = await _startDetachedProcess('xdg-open', <String>[path]);
      if (!opened) {
        opened = await _startDetachedProcess('gio', <String>['open', path]);
      }
    }

    if (kEngineDebugMode) {
      if (opened) {
        print('演出模式: 已打开资源目录: $path');
      } else {
        print('演出模式: 打开资源目录失败: $path');
      }
    }
  } catch (e) {
    if (kEngineDebugMode) {
      print('演出模式: 自动打开资源目录异常: $e');
    }
  }
}

class GameContainer extends StatefulWidget {
  final VoidCallback? onMenuWarmupFinished;

  const GameContainer({super.key, this.onMenuWarmupFinished});

  @override
  State<GameContainer> createState() => _GameContainerState();
}

class _GameContainerState extends State<GameContainer> with WindowListener {
  AppState _currentState = AppState.mainMenu;
  SaveSlot? _saveSlotToLoad;
  bool _isReturningFromGame = false;
  bool _isClosingWindow = false;
  bool _menuWarmupRunning = false;
  bool _menuWarmupComplete = false;
  bool _menuWarmupNotified = false;
  int _menuWarmupPageIndex = 0;
  GameModule? _menuWarmupModule;
  List<Widget>? _menuWarmupExtraPages;

  @override
  void initState() {
    super.initState();
    PlatformWindowManager.addListener(this);
  }

  @override
  void dispose() {
    PlatformWindowManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_isClosingWindow) {
      return;
    }

    final shouldClose = await _showExitConfirmation();
    if (!shouldClose) {
      return;
    }

    _isClosingWindow = true;
    try {
      await PlatformWindowManager.setPreventClose(false);
      await PlatformWindowManager.close();
    } catch (_) {
      SystemNavigator.pop();
    }
  }

  Future<bool> _showExitConfirmation() async {
    final hasProgress = _currentState == AppState.inGame;
    try {
      final gameModule = await moduleLoader.getCurrentModule();
      return await gameModule.showWindowCloseConfirmation(
        context,
        hasProgress: hasProgress,
      );
    } catch (_) {
      return ExitConfirmationDialog.showExitConfirmation(
        context,
        hasProgress: hasProgress,
      );
    }
  }

  bool get _shouldPrewarmMenuPages {
    if (kIsWeb) {
      return false;
    }
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  void _notifyMenuWarmupFinished() {
    if (_menuWarmupNotified) {
      return;
    }
    _menuWarmupNotified = true;
    widget.onMenuWarmupFinished?.call();
  }

  void _ensureMenuWarmupPages(GameModule gameModule) {
    if (_menuWarmupExtraPages != null &&
        identical(_menuWarmupModule, gameModule)) {
      return;
    }

    _menuWarmupModule = gameModule;
    _menuWarmupExtraPages = <Widget>[
      gameModule.createSettingsScreen(
        onClose: () {},
      ),
      gameModule.createAboutScreen(
        onClose: () {},
      ),
    ];
    _menuWarmupPageIndex = 0;
  }

  Widget _buildMainMenuScreen(GameModule gameModule) {
    final mainMenuScreen = gameModule.createMainMenuScreen(
      onNewGame: () => _enterGame(),
      onLoadGame: () {},
      onLoadGameWithSave: (saveSlot) => _enterGame(saveSlot: saveSlot),
      onContinueGame: _continueGame,
      skipMusicDelay: _isReturningFromGame,
    );

    if (_isReturningFromGame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isReturningFromGame = false;
        });
      });
    }

    if (_menuWarmupComplete || !_shouldPrewarmMenuPages) {
      _notifyMenuWarmupFinished();
      return mainMenuScreen;
    }

    _ensureMenuWarmupPages(gameModule);
    final warmupExtraPages = _menuWarmupExtraPages;
    if (warmupExtraPages == null || warmupExtraPages.isEmpty) {
      _notifyMenuWarmupFinished();
      return mainMenuScreen;
    }

    if (!_menuWarmupRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startMenuWarmupSequence();
      });
    }

    final warmupPages = <Widget>[
      mainMenuScreen,
      ...warmupExtraPages,
    ];
    final index = _menuWarmupPageIndex.clamp(0, warmupPages.length - 1);
    return IndexedStack(
      index: index,
      children: warmupPages,
    );
  }

  Future<void> _startMenuWarmupSequence() async {
    if (!mounted ||
        _menuWarmupRunning ||
        _menuWarmupComplete ||
        _currentState != AppState.mainMenu ||
        !_shouldPrewarmMenuPages) {
      _notifyMenuWarmupFinished();
      return;
    }

    final warmupExtraPages = _menuWarmupExtraPages;
    if (warmupExtraPages == null || warmupExtraPages.isEmpty) {
      _menuWarmupComplete = true;
      _notifyMenuWarmupFinished();
      return;
    }

    _menuWarmupRunning = true;

    try {
      final lastIndex = warmupExtraPages.length;
      final warmupOrder = <int>[
        for (int i = 0; i <= lastIndex; i++) i,
        0,
      ];

      for (final pageIndex in warmupOrder) {
        if (!mounted || _currentState != AppState.mainMenu) {
          return;
        }

        if (_menuWarmupPageIndex != pageIndex) {
          setState(() {
            _menuWarmupPageIndex = pageIndex;
          });
        }

        await SchedulerBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _menuWarmupComplete = true;
        _menuWarmupPageIndex = 0;
        _menuWarmupExtraPages = null;
      });
    } finally {
      _menuWarmupRunning = false;
      _notifyMenuWarmupFinished();
    }
  }

  void _enterGame({SaveSlot? saveSlot}) {
    setState(() {
      _currentState = AppState.inGame;
      _saveSlotToLoad = saveSlot;
      _isReturningFromGame = false;
    });
  }

  Future<void> _continueGame() async {
    try {
      final quickSave = await SaveLoadManager().loadQuickSave();
      if (quickSave != null) {
        _enterGame(saveSlot: quickSave);
      }
    } catch (e) {
      debugPrint('快速读档失败: $e');
    }
  }

  void _returnToMainMenu({bool withTransition = true}) {
    void switchToMainMenu() {
      setState(() {
        _currentState = AppState.mainMenu;
        _saveSlotToLoad = null;
        _isReturningFromGame = true;
      });
    }

    if (!withTransition) {
      switchToMainMenu();
      return;
    }

    TransitionOverlayManager.instance.transition(
      context: context,
      onMidTransition: switchToMainMenu,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: moduleLoader.getCurrentModule(),
      builder: (builderContext, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(
              child: ColoredBox(color: Color.fromARGB(0, 0, 0, 0)),
            ),
          );
        }

        final gameModule = snapshot.data!;
        late final Widget currentScreen;

        switch (_currentState) {
          case AppState.mainMenu:
            currentScreen = _buildMainMenuScreen(gameModule);
            break;
          case AppState.inGame:
            _notifyMenuWarmupFinished();
            final initialScript = gameModule.initialScript.trim();
            final saveSlot = _saveSlotToLoad;
            final sessionKey = saveSlot == null
                ? 'new_game:${initialScript.isEmpty ? 'start' : initialScript}'
                : 'save:${saveSlot.id}:${saveSlot.currentScript}:'
                    '${saveSlot.saveTime.microsecondsSinceEpoch}';
            currentScreen = gameModule.createGamePlayScreen(
              key: ValueKey(sessionKey),
              saveSlotToLoad: saveSlot,
              onReturnToMenu: () => _returnToMainMenu(
                withTransition: gameModule.enableReturnToMainMenuTransition,
              ),
              onLoadGame: (saveSlot) => _enterGame(saveSlot: saveSlot),
            );
            break;
        }

        return currentScreen;
      },
    );
  }
}

Future<void> runSakiEngine({
  String? projectName,
  String? appName,
  String? gamePath,
  int steamAppId = 3536120,
  bool enableSteamworks = true,
  bool useNearestNeighborSampling = false,
}) async {
  setupDebugLogger();
  final mpvVerboseLogging = _isMpvVerboseLoggingEnabled();

  await runZoned(
    () async {
      final frameRateBinding = SakiEngineFrameRateBinding.ensureInitialized();
      if (kEngineDebugMode) {
        SakiPerformanceMonitor.instance.start();
      }

      final previousFlutterErrorHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        if (_isKnownNoisyFrameworkError(details.exception)) {
          return;
        }
        final handler = previousFlutterErrorHandler;
        if (handler != null) {
          handler(details);
        } else {
          FlutterError.presentError(details);
        }
      };

      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        if (_isKnownNoisyFrameworkError(error)) {
          return true;
        }
        return false;
      };

      configureRuntimeProject(
        projectName: projectName,
        appName: appName,
        gamePath: gamePath,
      );
      unawaited(_openShowcaseResourceDirectoryIfNeeded());

      if (enableSteamworks) {
        final steamworksManager = SteamworksManager.instance;
        if (steamworksManager.isSupportedPlatform) {
          final steamOptions = SteamworksInitOptions(appId: steamAppId);
          final steamInitialized =
              await steamworksManager.initialize(options: steamOptions);
          debugPrint('Seamworks: 游戏Appid：${steamOptions.appId}');
          if (!steamInitialized && kEngineDebugMode) {
            debugPrint('Steamworks 初始化未成功，可能需要用户先启动 Steam 客户端。');
          }
        }
      }

      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }

      MediaKit.ensureInitialized();
      JustAudioMediaKit.ensureInitialized(
        android: true,
        iOS: true,
        macOS: true,
        windows: true,
        linux: true,
      );

      if (!kIsWeb) {
        await PlatformWindowManager.ensureInitialized();
        await PlatformWindowManager.setPreventClose(true);
      }

      if (!kIsWeb &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        await hotKeyManager.unregisterAll();
      }

      await SakiEngineConfig().loadConfig();
      await SettingsManager().init();
      if (!kIsWeb) {
        await PlatformWindowManager.applyStartupWindowSizeForAspectRatio(
          SettingsManager().currentGameWindowAspectRatio,
        );
      }
      frameRateBinding.attachSettingsSync();
      await LocalizationManager().init();
      await UISoundManager().initialize();

      await GlobalVariableManager().init();
      final allVars = GlobalVariableManager().getAllVariables();
      print('=== 应用启动 - 全局变量状态 ===');
      if (allVars.isEmpty) {
        print('暂无全局变量');
      } else {
        allVars.forEach((name, value) {
          print('全局变量: $name = $value');
        });
      }
      print('=== 全局变量状态结束 ===');

      SakiEngineConfig().updateThemeForDarkMode();
      ImageSamplingManager().configure(
        useNearestNeighbor: useNearestNeighborSampling,
      );

      runApp(const SakiEngineApp());
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        if (!mpvVerboseLogging && _isNoisyMpvLogLine(line)) {
          return;
        }
        if (_isNoisyFrameworkLogLine(line)) {
          return;
        }
        DebugLogger().addLog(line);
        parent.print(zone, line);
      },
    ),
  );
}

class SakiEngineApp extends StatefulWidget {
  const SakiEngineApp({super.key});

  @override
  State<SakiEngineApp> createState() => _SakiEngineAppState();
}

class _SakiEngineAppState extends State<SakiEngineApp> {
  String? _lastSetTitle;
  late final Listenable _settingsAppListenable;

  @override
  void initState() {
    super.initState();
    _settingsAppListenable = Listenable.merge([
      SettingsManager(),
      LocalizationManager(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final localization = LocalizationManager();
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
    final appBackgroundColor = isDesktop ? Colors.transparent : null;

    return AnimatedBuilder(
      animation: _settingsAppListenable,
      builder: (context, child) {
        return FutureBuilder(
          future: moduleLoader.getCurrentModule(),
          builder: (builderContext, snapshot) {
            if (!snapshot.hasData) {
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                color: appBackgroundColor,
                locale: localization.currentLocale,
                supportedLocales: localization.supportedLocales,
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                home: const Scaffold(
                  body: Center(
                    child: ColoredBox(color: Colors.black),
                  ),
                ),
              );
            }

            final gameModule = snapshot.data!;

            return FutureBuilder<String>(
              future: gameModule.getAppTitle(),
              builder: (context, titleSnapshot) {
                final appTitle = titleSnapshot.data ?? 'SakiEngine';
                final customTheme = gameModule.createTheme();

                if (titleSnapshot.hasData && _lastSetTitle != appTitle) {
                  _lastSetTitle = appTitle;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (kIsWeb) {
                      Timer(const Duration(milliseconds: 500), () {
                        PlatformWindowManager.setTitle(appTitle);
                      });
                    } else {
                      PlatformWindowManager.setTitle(appTitle);
                    }
                  });
                }

                return MaterialApp(
                  title: appTitle,
                  debugShowCheckedModeBanner: false,
                  color: appBackgroundColor,
                  locale: localization.currentLocale,
                  supportedLocales: localization.supportedLocales,
                  localizationsDelegates: const [
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  theme: customTheme ??
                      ThemeData(
                        primarySwatch: Colors.blue,
                        fontFamily: 'SourceHanSansCN',
                      ),
                  home: const StartupMaskWrapper(),
                );
              },
            );
          },
        );
      },
    );
  }
}

class StartupMaskWrapper extends StatefulWidget {
  const StartupMaskWrapper({super.key});

  @override
  State<StartupMaskWrapper> createState() => _StartupMaskWrapperState();
}

class _StartupMaskWrapperState extends State<StartupMaskWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  bool _prewarmingComplete = false;
  final Completer<void> _menuWarmupCompleter = Completer<void>();

  void _onMenuWarmupFinished() {
    if (_menuWarmupCompleter.isCompleted) {
      return;
    }
    _menuWarmupCompleter.complete();
  }

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(
      CurvedAnimation(
        parent: _fadeController,
        curve: Curves.easeOut,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startMaskAndPrewarm();
    });
  }

  Future<void> _startMaskAndPrewarm() async {
    if (!mounted) {
      return;
    }

    try {
      final delay = kIsWeb ? 1500 : 1000;
      await Future.delayed(Duration(milliseconds: delay));
      if (mounted) {
        await Future.wait<void>([
          TransitionPrewarmingManager.instance.prewarm(context),
          _menuWarmupCompleter.future.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          ),
        ]);
      }
      if (mounted) {
        _prewarmingComplete = true;
        _fadeController.forward();
      }
    } catch (_) {
      if (mounted) {
        _prewarmingComplete = true;
        _fadeController.forward();
      }
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GameContainer(
          onMenuWarmupFinished: _onMenuWarmupFinished,
        ),
        AnimatedBuilder(
          animation: SettingsManager(),
          builder: (context, child) {
            if (!SettingsManager().currentShowFpsOverlay) {
              return const SizedBox.shrink();
            }
            return const FpsOverlay();
          },
        ),
        AnimatedBuilder(
          animation: _fadeAnimation,
          builder: (context, child) {
            if (!_prewarmingComplete || _fadeAnimation.value > 0) {
              return Material(
                color: Colors.black.withOpacity(
                    _prewarmingComplete ? _fadeAnimation.value : 1.0),
                child: const SizedBox(
                  width: double.infinity,
                  height: double.infinity,
                ),
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }
}
