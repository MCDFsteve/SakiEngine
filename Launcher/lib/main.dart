import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

enum RunBuildMode { debug, showcase, profile, release }

enum BuildMode { release, showcase }

class LauncherUiSettings {
  final ThemeMode themeMode;
  final Color seedColor;
  final RunBuildMode defaultRunBuildMode;

  const LauncherUiSettings({
    required this.themeMode,
    required this.seedColor,
    required this.defaultRunBuildMode,
  });

  factory LauncherUiSettings.defaults() => const LauncherUiSettings(
    themeMode: ThemeMode.system,
    seedColor: Color(0xFF17685A),
    defaultRunBuildMode: RunBuildMode.debug,
  );

  LauncherUiSettings copyWith({
    ThemeMode? themeMode,
    Color? seedColor,
    RunBuildMode? defaultRunBuildMode,
  }) {
    return LauncherUiSettings(
      themeMode: themeMode ?? this.themeMode,
      seedColor: seedColor ?? this.seedColor,
      defaultRunBuildMode: defaultRunBuildMode ?? this.defaultRunBuildMode,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'theme_mode': _themeModeToString(themeMode),
      'seed_color': seedColor.toARGB32(),
      'run_build_mode': defaultRunBuildMode.name,
    };
  }

  static LauncherUiSettings fromJson(Map<String, dynamic> json) {
    final defaults = LauncherUiSettings.defaults();
    final mode = _themeModeFromString(json['theme_mode']?.toString());
    final colorValue = json['seed_color'];
    final runModeName = json['run_build_mode']?.toString();
    RunBuildMode? runMode;
    for (final modeItem in RunBuildMode.values) {
      if (modeItem.name == runModeName) {
        runMode = modeItem;
        break;
      }
    }

    return LauncherUiSettings(
      themeMode: mode ?? defaults.themeMode,
      seedColor: colorValue is int ? Color(colorValue) : defaults.seedColor,
      defaultRunBuildMode: runMode ?? defaults.defaultRunBuildMode,
    );
  }

  static String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'system';
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
    }
  }

  static ThemeMode? _themeModeFromString(String? value) {
    switch (value) {
      case 'system':
        return ThemeMode.system;
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return null;
    }
  }
}

final ValueNotifier<LauncherUiSettings> _settingsNotifier =
    ValueNotifier<LauncherUiSettings>(LauncherUiSettings.defaults());

const Size _launcherWindowSize = Size(1200, 600);
const String _launcherWindowTitle = 'SakiEngine 开发启动器';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureDesktopWindow();
  _settingsNotifier.value = await _loadLauncherUiSettings();
  runApp(SakiLauncherApp(settingsNotifier: _settingsNotifier));
}

Future<void> _configureDesktopWindow() async {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
    return;
  }

  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: _launcherWindowSize,
    center: true,
    title: _launcherWindowTitle,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

class SakiLauncherApp extends StatelessWidget {
  const SakiLauncherApp({required this.settingsNotifier, super.key});

  final ValueNotifier<LauncherUiSettings> settingsNotifier;

  ThemeData _buildTheme({
    required Brightness brightness,
    required Color seedColor,
  }) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: brightness,
      ),
      fontFamily: 'Noto Sans',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LauncherUiSettings>(
      valueListenable: settingsNotifier,
      builder: (context, settings, _) {
        return MaterialApp(
          title: _launcherWindowTitle,
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: _buildTheme(
            brightness: Brightness.light,
            seedColor: settings.seedColor,
          ),
          darkTheme: _buildTheme(
            brightness: Brightness.dark,
            seedColor: settings.seedColor,
          ),
          home: LauncherPage(settingsNotifier: settingsNotifier),
        );
      },
    );
  }
}

class LauncherPage extends StatefulWidget {
  const LauncherPage({required this.settingsNotifier, super.key});

  final ValueNotifier<LauncherUiSettings> settingsNotifier;

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

enum RunLaunchMode { embedded, systemTerminal }

class _LauncherPageState extends State<LauncherPage> {
  static const List<String> _allBuildTargets = <String>[
    'macos',
    'linux',
    'windows',
    'android',
    'ios',
    'web',
  ];

  static const String _defaultGeneratedLoader = '''
import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';

CompiledSksBundle? loadGeneratedCompiledSksBundle() {
  return null;
}
''';

  static const List<_SeedChoice> _seedChoices = <_SeedChoice>[
    _SeedChoice('引擎青绿', Color(0xFF17685A)),
    _SeedChoice('深海蓝', Color(0xFF0E5A8A)),
    _SeedChoice('琥珀橙', Color(0xFF9A5A00)),
    _SeedChoice('石墨灰', Color(0xFF455A64)),
    _SeedChoice('绯红', Color(0xFF9F2A3F)),
  ];

  late final Directory _repoRoot;

  final List<String> _gameProjects = <String>[];
  final List<_LogSession> _logSessions = <_LogSession>[];
  final ScrollController _logScrollController = ScrollController();
  int _nextLogSessionId = 1;

  String? _selectedGame;
  String? _defaultGame;
  String _runTarget = 'web';
  RunLaunchMode _runMode = RunLaunchMode.embedded;
  RunBuildMode _runBuildMode = RunBuildMode.debug;
  String _buildTarget = 'web';
  BuildMode _buildMode = BuildMode.release;
  bool _busy = false;
  bool _isRunTask = false;
  bool _pendingSafeRestart = false;
  Process? _activeProcess;

  @override
  void initState() {
    super.initState();
    _repoRoot = _discoverRepoRoot();
    _runTarget = _recommendedRunTarget();
    _buildTarget = _recommendedBuildTarget();
    _runBuildMode = widget.settingsNotifier.value.defaultRunBuildMode;
    if (!_buildTargets.contains(_buildTarget)) {
      _buildTarget = _buildTargets.first;
    }
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _activeProcess?.kill();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    _appendLog('仓库根目录: ${_repoRoot.path}');
    await _checkToolchain();
    await _refreshProjects();
  }

  Directory _discoverRepoRoot() {
    const override = String.fromEnvironment('SAKI_REPO_ROOT');
    if (override.trim().isNotEmpty) {
      final overrideDir = Directory(override).absolute;
      if (_isRepoRoot(overrideDir)) {
        return overrideDir;
      }
    }

    final starts = <Directory>[
      Directory.current.absolute,
      File(Platform.resolvedExecutable).parent.absolute,
    ];
    final seen = <String>{};
    for (final start in starts) {
      final key = _normalizePath(start.path);
      if (!seen.add(key)) {
        continue;
      }
      final found = _findRepoRootFrom(start);
      if (found != null) {
        return found;
      }
    }

    return Directory.current.absolute;
  }

  Directory? _findRepoRootFrom(Directory start) {
    var current = start.absolute;
    while (true) {
      if (_isRepoRoot(current)) {
        return current;
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        return null;
      }
      current = parent;
    }
  }

  bool _isRepoRoot(Directory dir) {
    final hasEngine = Directory(_joinPath(dir.path, 'Engine')).existsSync();
    final hasGame = Directory(_joinPath(dir.path, 'Game')).existsSync();
    return hasEngine && hasGame;
  }

  String _recommendedRunTarget() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return 'web';
  }

  String _recommendedBuildTarget() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return _buildTargets.first;
  }

  List<String> get _runTargets {
    if (Platform.isMacOS) return <String>['macos', 'web'];
    if (Platform.isLinux) return <String>['linux', 'web'];
    if (Platform.isWindows) return <String>['windows', 'web'];
    return <String>['web'];
  }

  List<String> get _buildTargets {
    if (Platform.isMacOS) {
      return <String>['macos', 'linux', 'windows', 'ios', 'android', 'web'];
    }
    if (Platform.isLinux) return <String>['linux', 'android', 'web'];
    if (Platform.isWindows) return <String>['windows', 'android', 'web'];
    return _allBuildTargets;
  }

  String _runModeLabel(RunLaunchMode mode) {
    switch (mode) {
      case RunLaunchMode.embedded:
        return '内置控制台';
      case RunLaunchMode.systemTerminal:
        return '系统终端';
    }
  }

  String _runBuildModeLabel(RunBuildMode mode) {
    switch (mode) {
      case RunBuildMode.debug:
        return 'Debug';
      case RunBuildMode.showcase:
        return '演出模式';
      case RunBuildMode.profile:
        return 'Profile';
      case RunBuildMode.release:
        return 'Release';
    }
  }

  List<String> _runBuildModeArgs(RunBuildMode mode) {
    switch (mode) {
      case RunBuildMode.debug:
        return const <String>[];
      case RunBuildMode.showcase:
        return const <String>['--release'];
      case RunBuildMode.profile:
        return const <String>['--profile'];
      case RunBuildMode.release:
        return const <String>['--release'];
    }
  }

  String _runBuildModeFlag(RunBuildMode mode) {
    switch (mode) {
      case RunBuildMode.debug:
        return '';
      case RunBuildMode.showcase:
        return '--release';
      case RunBuildMode.profile:
        return '--profile';
      case RunBuildMode.release:
        return '--release';
    }
  }

  bool _isShowcaseMode(RunBuildMode mode) {
    return mode == RunBuildMode.showcase;
  }

  bool _shouldUseReleaseAssetPipeline(RunBuildMode mode) {
    return mode == RunBuildMode.profile || mode == RunBuildMode.release;
  }

  String _buildModeLabel(BuildMode mode) {
    switch (mode) {
      case BuildMode.release:
        return '发布模式';
      case BuildMode.showcase:
        return '演出模式';
    }
  }

  List<String> _buildRunDefines({
    required String game,
    required String gameDir,
    required RunBuildMode mode,
  }) {
    final defines = <String>['--dart-define=SAKI_GAME_PATH=$gameDir'];
    if (_isShowcaseMode(mode)) {
      defines.add('--dart-define=SAKI_SHOW_MODE=true');
      defines.add('--dart-define=SAKI_SHOWCASE_GAME_DIR=Game/$game');
    }
    return defines;
  }

  Future<void> _checkToolchain() async {
    final flutterReady = await _isCommandAvailable('flutter');
    if (flutterReady) {
      _appendLog('环境检测: flutter 可用');
    } else {
      _appendLog('环境检测警告: 未检测到 flutter，运行/构建会失败');
    }

    final nodeReady = await _isCommandAvailable('node');
    if (nodeReady) {
      _appendLog('环境检测: node 可用');
    } else {
      _appendLog('环境检测警告: 未检测到 node，项目准备与创建会失败');
    }
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
    }
  }

  Future<void> _saveSettings(LauncherUiSettings settings) async {
    widget.settingsNotifier.value = settings;
    await _saveLauncherUiSettings(settings);
  }

  Future<void> _showSettingsDialog() async {
    final current = widget.settingsNotifier.value;
    var selectedThemeMode = current.themeMode;
    var selectedSeedColor = current.seedColor;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('启动器设置'),
              content: SizedBox(
                width: 430,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    DropdownButtonFormField<ThemeMode>(
                      initialValue: selectedThemeMode,
                      decoration: const InputDecoration(
                        labelText: '主题模式',
                        border: OutlineInputBorder(),
                      ),
                      items: ThemeMode.values
                          .map(
                            (mode) => DropdownMenuItem<ThemeMode>(
                              value: mode,
                              child: Text(_themeModeLabel(mode)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setDialogState(() {
                          selectedThemeMode = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '主题色调',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _seedChoices.map((choice) {
                        final selected =
                            choice.color.toARGB32() ==
                            selectedSeedColor.toARGB32();
                        return ChoiceChip(
                          label: Text(choice.label),
                          selected: selected,
                          selectedColor: choice.color.withValues(alpha: 0.22),
                          side: BorderSide(
                            color: selected
                                ? choice.color
                                : Theme.of(context).dividerColor,
                          ),
                          avatar: CircleAvatar(
                            radius: 8,
                            backgroundColor: choice.color,
                          ),
                          onSelected: (_) {
                            setDialogState(() {
                              selectedSeedColor = choice.color;
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final next = current.copyWith(
                      themeMode: selectedThemeMode,
                      seedColor: selectedSeedColor,
                    );
                    await _saveSettings(next);
                    if (!mounted) {
                      return;
                    }
                    Navigator.of(dialogContext).pop();
                    final hex = (selectedSeedColor.toARGB32() & 0xFFFFFF)
                        .toRadixString(16)
                        .padLeft(6, '0')
                        .toUpperCase();
                    _appendLog(
                      '设置已更新: 主题=${_themeModeLabel(selectedThemeMode)}, 色调=#$hex',
                    );
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _refreshProjects() async {
    final gameDir = Directory(_joinPath(_repoRoot.path, 'Game'));
    final defaultGameFile = File(_joinPath(_repoRoot.path, 'default_game.txt'));
    final projects = <String>[];

    if (!gameDir.existsSync()) {
      _appendLog('未找到 Game 目录: ${gameDir.path}');
    }

    if (gameDir.existsSync()) {
      final candidates =
          gameDir
              .listSync(followLinks: false)
              .whereType<Directory>()
              .map((d) => d.path)
              .toList()
            ..sort();

      for (final path in candidates) {
        final pubspec = File(_joinPath(path, 'pubspec.yaml'));
        if (pubspec.existsSync()) {
          projects.add(_basename(path));
        }
      }
    }

    String? defaultGame;
    if (defaultGameFile.existsSync()) {
      defaultGame = defaultGameFile.readAsStringSync().trim();
      if (defaultGame.isEmpty) {
        defaultGame = null;
      }
    }

    if (mounted) {
      setState(() {
        _gameProjects
          ..clear()
          ..addAll(projects);
        _defaultGame = defaultGame;

        if (_selectedGame == null || !_gameProjects.contains(_selectedGame)) {
          if (_defaultGame != null && _gameProjects.contains(_defaultGame)) {
            _selectedGame = _defaultGame;
          } else {
            _selectedGame = _gameProjects.isEmpty ? null : _gameProjects.first;
          }
        }
      });
    }

    _appendLog('已加载 ${projects.length} 个游戏项目');
    if (projects.isEmpty) {
      _appendLog('提示: 仅识别包含 pubspec.yaml 的 Game/<项目> 目录');
    }
  }

  Future<void> _setDefaultGame() async {
    final game = _selectedGame;
    if (game == null) {
      return;
    }

    final file = File(_joinPath(_repoRoot.path, 'default_game.txt'));
    await file.writeAsString('$game\n');
    if (mounted) {
      setState(() {
        _defaultGame = game;
      });
    }
    _appendLog('默认项目已更新为: $game');
  }

  Future<void> _showEditProjectVersionDialog() async {
    if (_busy) {
      return;
    }
    final game = _selectedGame;
    if (game == null) {
      return;
    }

    final pubspecFile = File(
      _joinPath(
        _joinPath(_joinPath(_repoRoot.path, 'Game'), game),
        'pubspec.yaml',
      ),
    );
    if (!pubspecFile.existsSync()) {
      _appendLog('版本编辑失败: 未找到 pubspec.yaml (${pubspecFile.path})');
      return;
    }

    final versionController = TextEditingController(
      text: _readGameVersion(pubspecFile),
    );
    var saving = false;
    String? message;

    await showDialog<void>(
      context: context,
      barrierDismissible: !saving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('编辑版本号 - $game'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: versionController,
                      enabled: !saving,
                      decoration: const InputDecoration(
                        labelText: 'version',
                        hintText: '1.0.0+1',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '将写入 Game/$game/pubspec.yaml 的 version 字段',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          message!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: saving
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                        },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          final nextVersion = versionController.text.trim();
                          if (nextVersion.isEmpty ||
                              nextVersion.contains(' ')) {
                            setDialogState(() {
                              message = '版本号不能为空且不能包含空格（示例: 1.0.0+1）';
                            });
                            return;
                          }
                          setDialogState(() {
                            saving = true;
                            message = null;
                          });

                          final updated = await _updateGamePubspecVersion(
                            pubspecFile: pubspecFile,
                            newVersion: nextVersion,
                          );
                          if (!mounted) {
                            return;
                          }
                          if (!updated) {
                            setDialogState(() {
                              saving = false;
                              message = '未找到可更新的 version 字段';
                            });
                            return;
                          }
                          _appendLog('已更新项目版本: $game -> $nextVersion');
                          Navigator.of(dialogContext).pop();
                        },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    versionController.dispose();
  }

  Future<void> _showEditConfigsDialog() async {
    if (_busy) {
      return;
    }
    final game = _selectedGame;
    if (game == null) {
      return;
    }

    final configsFile = File(
      _joinPath(
        _joinPath(
          _joinPath(_joinPath(_repoRoot.path, 'Game'), game),
          'GameScript',
        ),
        'configs/configs.sks',
      ),
    );
    if (!configsFile.existsSync()) {
      _appendLog('配置编辑失败: 未找到 configs.sks (${configsFile.path})');
      return;
    }

    late final _ConfigsVisualDocument document;
    try {
      document = _parseConfigsSks(configsFile.readAsLinesSync());
    } catch (e) {
      _appendLog('配置编辑失败: 解析 configs.sks 出错: $e');
      return;
    }

    final entries = document.entries
        .map(
          (entry) => _ConfigEntryDraft(
            key: TextEditingController(text: entry.key),
            value: TextEditingController(text: entry.value),
            inlineComment: entry.inlineComment,
          ),
        )
        .toList();

    void disposeDrafts() {
      for (final draft in entries) {
        draft.key.dispose();
        draft.value.dispose();
      }
    }

    var saving = false;
    String? message;

    await showDialog<void>(
      context: context,
      barrierDismissible: !saving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text('可视化编辑 configs.sks - $game'),
              content: SizedBox(
                width: 860,
                height: 520,
                child: Column(
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        configsFile.path,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: <Widget>[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(7),
                                ),
                              ),
                              child: const Row(
                                children: <Widget>[
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      '配置键',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    flex: 7,
                                    child: Text(
                                      '配置值',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 40),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView.separated(
                                padding: const EdgeInsets.all(10),
                                itemCount: entries.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final draft = entries[index];
                                  return Row(
                                    children: <Widget>[
                                      Expanded(
                                        flex: 3,
                                        child: TextField(
                                          controller: draft.key,
                                          enabled: !saving,
                                          decoration: const InputDecoration(
                                            border: OutlineInputBorder(),
                                            isDense: true,
                                            hintText: '例如: base_dialogue',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        flex: 7,
                                        child: TextField(
                                          controller: draft.value,
                                          enabled: !saving,
                                          decoration: const InputDecoration(
                                            border: OutlineInputBorder(),
                                            isDense: true,
                                            hintText: '例如: size=24',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        onPressed: saving
                                            ? null
                                            : () {
                                                setDialogState(() {
                                                  final removed = entries
                                                      .removeAt(index);
                                                  removed.key.dispose();
                                                  removed.value.dispose();
                                                });
                                              },
                                        tooltip: '删除',
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : () {
                                setDialogState(() {
                                  entries.add(
                                    _ConfigEntryDraft(
                                      key: TextEditingController(),
                                      value: TextEditingController(),
                                      inlineComment: '',
                                    ),
                                  );
                                });
                              },
                        icon: const Icon(Icons.add),
                        label: const Text('新增配置项'),
                      ),
                    ),
                    if (message != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            message!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: saving
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                        },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (entries.isEmpty) {
                            setDialogState(() {
                              message = '至少需要保留 1 条配置项';
                            });
                            return;
                          }
                          final seen = <String>{};
                          final nextEntries = <_ConfigEntry>[];
                          for (final draft in entries) {
                            final key = draft.key.text.trim();
                            final value = draft.value.text.trim();
                            if (key.isEmpty) {
                              setDialogState(() {
                                message = '配置键不能为空';
                              });
                              return;
                            }
                            if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key)) {
                              setDialogState(() {
                                message = '配置键仅支持字母/数字/_/-';
                              });
                              return;
                            }
                            if (value.isEmpty) {
                              setDialogState(() {
                                message = '配置值不能为空';
                              });
                              return;
                            }
                            if (!seen.add(key)) {
                              setDialogState(() {
                                message = '存在重复配置键: $key';
                              });
                              return;
                            }
                            nextEntries.add(
                              _ConfigEntry(
                                key: key,
                                value: value,
                                inlineComment: draft.inlineComment,
                              ),
                            );
                          }

                          setDialogState(() {
                            saving = true;
                            message = null;
                          });
                          await _saveConfigsSks(
                            file: configsFile,
                            headerLines: document.headerLines,
                            trailingLines: document.trailingLines,
                            entries: nextEntries,
                          );
                          if (!mounted) {
                            return;
                          }
                          _appendLog('已更新 configs.sks: ${configsFile.path}');
                          Navigator.of(dialogContext).pop();
                        },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    disposeDrafts();
  }

  Future<bool> _updateGamePubspecVersion({
    required File pubspecFile,
    required String newVersion,
  }) async {
    final lines = await pubspecFile.readAsLines();
    final versionPattern = RegExp(r'^(\s*version:\s*)(.+?)(\s*(#.*)?)$');
    var updated = false;
    for (var i = 0; i < lines.length; i++) {
      final match = versionPattern.firstMatch(lines[i]);
      if (match == null) {
        continue;
      }
      final prefix = match.group(1)!;
      final suffix = match.group(3) ?? '';
      lines[i] = '$prefix$newVersion$suffix';
      updated = true;
      break;
    }
    if (!updated) {
      return false;
    }
    await pubspecFile.writeAsString('${lines.join('\n')}\n');
    return true;
  }

  _ConfigsVisualDocument _parseConfigsSks(List<String> lines) {
    final headerLines = <String>[];
    final trailingLines = <String>[];
    final entries = <_ConfigEntry>[];
    var seenEntry = false;

    for (final original in lines) {
      final line = original.trim();
      final lineWithoutComment = line.split('//').first.trimRight();
      final separatorIndex = lineWithoutComment.indexOf(':');
      final canParseEntry =
          line.isNotEmpty &&
          !line.startsWith('//') &&
          separatorIndex > 0 &&
          separatorIndex < lineWithoutComment.length - 1;

      if (canParseEntry) {
        seenEntry = true;
        final key = lineWithoutComment.substring(0, separatorIndex).trim();
        final value = lineWithoutComment.substring(separatorIndex + 1).trim();
        var inlineComment = '';
        final commentIndex = line.indexOf('//');
        if (commentIndex >= 0) {
          inlineComment = line.substring(commentIndex + 2).trim();
        }
        entries.add(
          _ConfigEntry(key: key, value: value, inlineComment: inlineComment),
        );
      } else {
        if (!seenEntry) {
          headerLines.add(original);
        } else {
          trailingLines.add(original);
        }
      }
    }

    if (entries.isEmpty) {
      throw const _TaskFailure('configs.sks 中未找到可编辑配置项');
    }

    return _ConfigsVisualDocument(
      headerLines: headerLines,
      trailingLines: trailingLines,
      entries: entries,
    );
  }

  Future<void> _saveConfigsSks({
    required File file,
    required List<String> headerLines,
    required List<String> trailingLines,
    required List<_ConfigEntry> entries,
  }) async {
    final output = <String>[];
    if (headerLines.isNotEmpty) {
      output.addAll(headerLines);
    } else {
      output.add('//config// SakiEngine 配置文件');
    }

    for (final entry in entries) {
      var line = '${entry.key}: ${entry.value}';
      if (entry.inlineComment.trim().isNotEmpty) {
        line = '$line // ${entry.inlineComment.trim()}';
      }
      output.add(line);
    }

    if (trailingLines.isNotEmpty) {
      output.addAll(trailingLines);
    }
    await file.writeAsString('${output.join('\n')}\n');
  }

  Future<int> _runNodeBridge(List<String> bridgeArgs) {
    return _runCommand(
      executable: 'node',
      arguments: <String>['scripts/launcher-bridge.js', ...bridgeArgs],
      workingDirectory: _repoRoot.path,
    );
  }

  Future<void> _prepareProjectForExecution(
    String game, {
    required bool generateIcons,
  }) async {
    final args = <String>['prepare-project', '--game', game];
    if (generateIcons) {
      args.add('--generate-icons');
    }

    final code = await _runNodeBridge(args);
    if (code != 0) {
      throw _TaskFailure('准备项目失败（应用身份/图标同步）');
    }
  }

  Future<void> _showCreateProjectDialog() async {
    if (_busy) {
      return;
    }

    final nameController = TextEditingController();
    final bundleController = TextEditingController(
      text: 'com.aimessoft.mygame',
    );
    final colorController = TextEditingController(text: '137B8B');
    var setDefault = true;
    var submitting = false;
    String? message;

    await showDialog<void>(
      context: context,
      barrierDismissible: !submitting,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('创建新项目'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: nameController,
                      enabled: !submitting,
                      decoration: const InputDecoration(
                        labelText: '项目名称',
                        hintText: 'MyGame',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: bundleController,
                      enabled: !submitting,
                      decoration: const InputDecoration(
                        labelText: 'Bundle ID',
                        hintText: 'com.company.game',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: colorController,
                      enabled: !submitting,
                      onChanged: (_) {
                        setDialogState(() {
                          message = null;
                        });
                      },
                      decoration: InputDecoration(
                        labelText: '主色调 (Hex)',
                        hintText: '137B8B',
                        suffixIcon: IconButton(
                          tooltip: '打开选色盘',
                          onPressed: submitting
                              ? null
                              : () async {
                                  final pickedColor =
                                      await _showColorPickerDialog(
                                        initialColor: _parseHexColor(
                                          colorController.text.trim(),
                                          fallback: const Color(0xFF137B8B),
                                        ),
                                      );
                                  if (!mounted || pickedColor == null) {
                                    return;
                                  }
                                  setDialogState(() {
                                    colorController.text = _colorToHex(
                                      pickedColor,
                                    );
                                    message = null;
                                  });
                                },
                          icon: const Icon(Icons.palette_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '颜色预览',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: _parseHexColor(
                                colorController.text.trim(),
                                fallback: const Color(0xFF137B8B),
                              ),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Theme.of(context).dividerColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: setDefault,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      enabled: !submitting,
                      title: const Text('创建后设为默认项目'),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setDialogState(() {
                          setDefault = value;
                        });
                      },
                    ),
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          message!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: submitting
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                        },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          final name = nameController.text.trim();
                          final bundle = bundleController.text.trim();
                          var color = colorController.text.trim();
                          if (color.startsWith('#')) {
                            color = color.substring(1);
                          }

                          final nameOk = RegExp(
                            r'^[a-zA-Z0-9_-]+$',
                          ).hasMatch(name);
                          final bundleOk = RegExp(
                            r'^[a-zA-Z][a-zA-Z0-9]*(\.[a-zA-Z][a-zA-Z0-9]*){2,}$',
                          ).hasMatch(bundle);
                          final colorOk = RegExp(
                            r'^[0-9A-Fa-f]{6}$',
                          ).hasMatch(color);

                          if (!nameOk || !bundleOk || !colorOk) {
                            setDialogState(() {
                              message = '请输入合法值：项目名、Bundle ID、6位十六进制颜色';
                            });
                            return;
                          }

                          setDialogState(() {
                            submitting = true;
                            message = null;
                          });

                          final success = await _createProjectNonInteractive(
                            name: name,
                            bundleId: bundle,
                            color: color,
                            setDefault: setDefault,
                          );
                          if (!mounted) {
                            return;
                          }

                          if (success) {
                            Navigator.of(dialogContext).pop();
                          } else {
                            setDialogState(() {
                              submitting = false;
                              message = '创建失败，请查看任务日志';
                            });
                          }
                        },
                  child: const Text('创建'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<Color?> _showColorPickerDialog({required Color initialColor}) async {
    var hsv = HSVColor.fromColor(initialColor);
    const pickerSize = 230.0;

    return showDialog<Color>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final preview = hsv.toColor();
            return AlertDialog(
              title: const Text('选择主题色'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: preview,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '#${_colorToHex(preview)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '拖动色盘选择颜色（左: 饱和度/明度，右: 色相）',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _buildPsColorSquare(
                          hsv: hsv,
                          size: pickerSize,
                          onChanged: (saturation, value) {
                            setDialogState(() {
                              hsv = hsv.withSaturation(saturation).withValue(
                                value,
                              );
                            });
                          },
                        ),
                        const SizedBox(width: 12),
                        _buildPsHueSlider(
                          hue: hsv.hue,
                          size: pickerSize,
                          onChanged: (hue) {
                            setDialogState(() {
                              hsv = hsv.withHue(hue);
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'H ${hsv.hue.toStringAsFixed(0)}°  '
                      'S ${(hsv.saturation * 100).toStringAsFixed(0)}%  '
                      'V ${(hsv.value * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop(preview);
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Color _parseHexColor(String input, {required Color fallback}) {
    var value = input.trim();
    if (value.startsWith('#')) {
      value = value.substring(1);
    }
    if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(value)) {
      return fallback;
    }
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) {
      return fallback;
    }
    return Color(0xFF000000 | parsed);
  }

  String _colorToHex(Color color) {
    return (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  Widget _buildPsColorSquare({
    required HSVColor hsv,
    required double size,
    required void Function(double saturation, double value) onChanged,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (details) => _handlePsSquareDrag(
        localPosition: details.localPosition,
        size: size,
        onChanged: onChanged,
      ),
      onPanUpdate: (details) => _handlePsSquareDrag(
        localPosition: details.localPosition,
        size: size,
        onChanged: onChanged,
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _PsColorSquarePainter(
            hue: hsv.hue,
            saturation: hsv.saturation,
            value: hsv.value,
          ),
        ),
      ),
    );
  }

  Widget _buildPsHueSlider({
    required double hue,
    required double size,
    required ValueChanged<double> onChanged,
  }) {
    const sliderWidth = 24.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: (details) => _handlePsHueDrag(
        localPosition: details.localPosition,
        size: size,
        onChanged: onChanged,
      ),
      onPanUpdate: (details) => _handlePsHueDrag(
        localPosition: details.localPosition,
        size: size,
        onChanged: onChanged,
      ),
      child: SizedBox(
        width: sliderWidth,
        height: size,
        child: CustomPaint(
          painter: _PsHueSliderPainter(
            hue: hue,
          ),
        ),
      ),
    );
  }

  void _handlePsSquareDrag({
    required Offset localPosition,
    required double size,
    required void Function(double saturation, double value) onChanged,
  }) {
    final clampedX = localPosition.dx.clamp(0.0, size);
    final clampedY = localPosition.dy.clamp(0.0, size);
    final saturation = clampedX / size;
    final value = 1 - (clampedY / size);
    onChanged(saturation, value);
  }

  void _handlePsHueDrag({
    required Offset localPosition,
    required double size,
    required ValueChanged<double> onChanged,
  }) {
    final clampedY = localPosition.dy.clamp(0.0, size);
    final hue = (clampedY / size) * 360;
    onChanged(hue.clamp(0, 360).toDouble());
  }

  Future<bool> _createProjectNonInteractive({
    required String name,
    required String bundleId,
    required String color,
    required bool setDefault,
  }) async {
    if (_busy) {
      return false;
    }

    setState(() {
      _busy = true;
      _isRunTask = false;
    });
    _appendLog('开始创建新项目: $name');

    try {
      final args = <String>[
        'create-project',
        '--name',
        name,
        '--bundle',
        bundleId,
        '--color',
        color,
      ];
      if (setDefault) {
        args.add('--set-default');
      }

      final code = await _runNodeBridge(args);
      if (code != 0) {
        _appendLog('创建项目失败: $name');
        return false;
      }

      await _refreshProjects();
      if (mounted) {
        setState(() {
          _selectedGame = name;
        });
      }
      _appendLog('创建项目成功: $name');
      return true;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeProcess = null;
        });
      }
    }
  }

  Future<void> _runSelectedGame() async {
    final game = _selectedGame;
    if (game == null || _busy) {
      return;
    }

    final gameDir = _joinPath(_joinPath(_repoRoot.path, 'Game'), game);
    final runDevice = _runTarget == 'web' ? 'chrome' : _runTarget;
    final runModeArgs = _runBuildModeArgs(_runBuildMode);
    final runDefineArgs = _buildRunDefines(
      game: game,
      gameDir: gameDir,
      mode: _runBuildMode,
    );

    setState(() {
      _busy = true;
      _isRunTask = true;
    });
    _appendLog(
      '开始运行游戏: $game (target=$runDevice, launch=${_runModeLabel(_runMode)}, build=${_runBuildModeLabel(_runBuildMode)})',
    );

    try {
      if (_runMode == RunLaunchMode.systemTerminal) {
        if (_shouldUseReleaseAssetPipeline(_runBuildMode)) {
          _appendLog('系统终端模式暂不支持 Profile/Release 发布运行管线，请切换到内置控制台运行');
          return;
        }
        final launched = await _launchRunInSystemTerminal(
          game: game,
          gameDir: gameDir,
          runDevice: runDevice,
          runBuildMode: _runBuildMode,
        );
        if (launched) {
          _appendLog('已在系统终端启动运行任务，可在终端中使用 r/R/q');
        } else {
          _appendLog('启动失败: 未找到可用系统终端');
        }
        return;
      }

      int runCode;
      if (!_shouldUseReleaseAssetPipeline(_runBuildMode)) {
        await _prepareProjectForExecution(game, generateIcons: false);

        final pubGetCode = await _runCommand(
          executable: 'flutter',
          arguments: const <String>['pub', 'get'],
          workingDirectory: gameDir,
        );
        if (pubGetCode != 0) {
          _appendLog('运行中止: flutter pub get 失败');
          return;
        }

        await _prepareProjectForExecution(game, generateIcons: true);

        runCode = await _runCommand(
          executable: 'flutter',
          arguments: <String>[
            'run',
            ...runModeArgs,
            '-d',
            runDevice,
            ...runDefineArgs,
          ],
          workingDirectory: gameDir,
        );
      } else {
        runCode = await _runWithReleaseAssetPipeline(
          game: game,
          gameDir: gameDir,
          runDevice: runDevice,
          runModeArgs: runModeArgs,
          runDefineArgs: runDefineArgs,
        );
      }
      if (runCode != 0) {
        _appendLog('运行中止: flutter run 失败');
      }
    } on _TaskFailure catch (e) {
      _appendLog('运行失败: ${e.message}');
    } catch (e) {
      _appendLog('运行异常: $e');
    } finally {
      final shouldSafeRestart = _pendingSafeRestart;
      _pendingSafeRestart = false;
      if (mounted) {
        setState(() {
          _busy = false;
          _isRunTask = false;
          _activeProcess = null;
        });
      }
      _appendLog('运行任务结束');
      if (shouldSafeRestart && mounted) {
        _appendLog('开始安全重启运行任务...');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        unawaited(_runSelectedGame());
      }
    }
  }

  Future<int> _runWithReleaseAssetPipeline({
    required String game,
    required String gameDir,
    required String runDevice,
    required List<String> runModeArgs,
    required List<String> runDefineArgs,
  }) async {
    final gameDirectory = Directory(gameDir);
    final gamePubspec = File(_joinPath(gameDir, 'pubspec.yaml'));
    final cacheDir = Directory(_joinPath(gameDir, '.saki_cache'));
    final cacheBundle = File(
      _joinPath(cacheDir.path, 'compiled_sks_bundle.g.dart'),
    );
    final engineLoader = File(
      _joinPath(
        _repoRoot.path,
        'Engine/lib/src/sks_compiler/generated/compiled_sks_bundle.g.dart',
      ),
    );

    if (!gameDirectory.existsSync() || !gamePubspec.existsSync()) {
      throw _TaskFailure('运行失败: 无效项目目录 $game');
    }

    cacheDir.createSync(recursive: true);

    final originalPubspec = await gamePubspec.readAsString();
    final originalEngineLoader = engineLoader.existsSync()
        ? await engineLoader.readAsString()
        : _defaultGeneratedLoader;

    _appendLog('非 Debug 运行启用发布资源管线（与发布构建一致）');

    try {
      await _prepareProjectForExecution(game, generateIcons: false);

      final firstPubGet = await _runCommand(
        executable: 'flutter',
        arguments: const <String>['pub', 'get'],
        workingDirectory: gameDir,
      );
      if (firstPubGet != 0) {
        throw _TaskFailure('flutter pub get 失败');
      }

      final compileCode = await _runCommand(
        executable: 'flutter',
        arguments: <String>[
          'pub',
          'run',
          '../../Engine/tool/sks_compiler.dart',
          '--game-dir',
          gameDir,
          '--output',
          cacheBundle.path,
          '--game-name',
          game,
        ],
        workingDirectory: gameDir,
      );
      if (compileCode != 0 || !cacheBundle.existsSync()) {
        throw _TaskFailure('.sks 预编译失败');
      }

      await cacheBundle.copy(engineLoader.path);
      if (runDevice != 'chrome') {
        final packOk = await _generateSakiPack(
          gameDir: gameDirectory,
          cacheDir: cacheDir,
        );
        if (!packOk) {
          throw _TaskFailure('SakiPack 资源打包失败');
        }
      }
      final summary = await _prepareReleasePubspec(
        gameDir: gameDirectory,
        pubspecFile: gamePubspec,
        targetPlatform: runDevice == 'chrome' ? 'web' : runDevice,
      );
      _appendLog(
        '发布运行资源清单已生成: ${summary.totalAssets} 项，图片/视频 ${summary.mediaAssets} 项',
      );

      final secondPubGet = await _runCommand(
        executable: 'flutter',
        arguments: const <String>['pub', 'get'],
        workingDirectory: gameDir,
      );
      if (secondPubGet != 0) {
        throw _TaskFailure('更新发布资源后 pub get 失败');
      }

      return await _runCommand(
        executable: 'flutter',
        arguments: <String>[
          'run',
          ...runModeArgs,
          '-d',
          runDevice,
          ...runDefineArgs,
        ],
        workingDirectory: gameDir,
      );
    } finally {
      await gamePubspec.writeAsString(originalPubspec);
      await engineLoader.writeAsString(originalEngineLoader);
      _appendLog('已恢复运行前临时修改（pubspec + 编译入口）');
    }
  }

  Future<void> _buildSelectedGame() async {
    final game = _selectedGame;
    if (game == null || _busy) {
      return;
    }
    if (!_buildTargets.contains(_buildTarget)) {
      _appendLog('构建失败: 当前主机不支持目标平台 $_buildTarget');
      return;
    }

    setState(() {
      _busy = true;
      _isRunTask = false;
    });

    try {
      await _runBuildPipeline(game, _buildTarget);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeProcess = null;
        });
      }
    }
  }

  Future<void> _runBuildPipeline(String game, String platform) async {
    final gameDir = Directory(
      _joinPath(_joinPath(_repoRoot.path, 'Game'), game),
    );
    final gamePubspec = File(_joinPath(gameDir.path, 'pubspec.yaml'));
    final cacheDir = Directory(_joinPath(gameDir.path, '.saki_cache'));
    final cacheBundle = File(
      _joinPath(cacheDir.path, 'compiled_sks_bundle.g.dart'),
    );
    final engineLoader = File(
      _joinPath(
        _repoRoot.path,
        'Engine/lib/src/sks_compiler/generated/compiled_sks_bundle.g.dart',
      ),
    );

    if (!gameDir.existsSync() || !gamePubspec.existsSync()) {
      _appendLog('构建失败: 无效项目目录 $game');
      return;
    }

    cacheDir.createSync(recursive: true);

    final originalPubspec = await gamePubspec.readAsString();
    final originalEngineLoader = engineLoader.existsSync()
        ? await engineLoader.readAsString()
        : _defaultGeneratedLoader;

    _appendLog(
      '开始构建: $game -> $platform (mode=${_buildModeLabel(_buildMode)})',
    );

    try {
      _appendLog('正在清理旧构建产物，避免残留依赖进入新构建...');
      final cleanCode = await _runCommand(
        executable: 'flutter',
        arguments: const <String>['clean'],
        workingDirectory: gameDir.path,
      );
      if (cleanCode != 0) {
        throw _TaskFailure('flutter clean 失败，已中止构建');
      }
      final staleCleanPaths = <String>[
        _joinPath(gameDir.path, 'build'),
        _joinPath(gameDir.path, '.dart_tool'),
      ].where((path) => Directory(path).existsSync()).toList();
      if (staleCleanPaths.isNotEmpty) {
        throw _TaskFailure(
          'flutter clean 未完全清除旧构建，请关闭正在运行的游戏或占用文件后重试: '
          '${staleCleanPaths.join(', ')}',
        );
      }

      await _prepareProjectForExecution(game, generateIcons: false);

      final firstPubGet = await _runCommand(
        executable: 'flutter',
        arguments: const <String>['pub', 'get'],
        workingDirectory: gameDir.path,
      );
      if (firstPubGet != 0) {
        throw _TaskFailure('flutter pub get 失败');
      }

      final useReleaseAssetPipeline = _buildMode == BuildMode.release;
      if (useReleaseAssetPipeline) {
        final compileCode = await _runCommand(
          executable: 'flutter',
          arguments: <String>[
            'pub',
            'run',
            '../../Engine/tool/sks_compiler.dart',
            '--game-dir',
            gameDir.path,
            '--output',
            cacheBundle.path,
            '--game-name',
            game,
          ],
          workingDirectory: gameDir.path,
        );
        if (compileCode != 0 || !cacheBundle.existsSync()) {
          throw _TaskFailure('.sks 预编译失败');
        }

        await cacheBundle.copy(engineLoader.path);
        if (platform != 'web') {
          final packOk = await _generateSakiPack(
            gameDir: gameDir,
            cacheDir: cacheDir,
          );
          if (!packOk) {
            throw _TaskFailure('SakiPack 资源打包失败');
          }
        }
        final summary = await _prepareReleasePubspec(
          gameDir: gameDir,
          pubspecFile: gamePubspec,
          targetPlatform: platform,
        );
        _appendLog(
          '发布资源清单已生成: ${summary.totalAssets} 项，图片/视频 ${summary.mediaAssets} 项',
        );

        final secondPubGet = await _runCommand(
          executable: 'flutter',
          arguments: const <String>['pub', 'get'],
          workingDirectory: gameDir.path,
        );
        if (secondPubGet != 0) {
          throw _TaskFailure('更新发布资源后 pub get 失败');
        }
      } else {
        _appendLog('演出模式构建: 跳过 .sks 预编译与发布资源裁剪，保留脚本直读能力');
      }

      if (!useReleaseAssetPipeline) {
        await _prepareProjectForExecution(game, generateIcons: true);
      } else {
        _appendLog('发布构建模式: 跳过二次 prepare-project，避免覆盖发布资源清单');
      }

      if (platform == 'ios') {
        final iosDir = Directory(_joinPath(gameDir.path, 'ios'));
        if (!iosDir.existsSync()) {
          throw _TaskFailure('iOS 平台目录不存在: ${iosDir.path}');
        }
        final podCode = await _runCommand(
          executable: 'pod',
          arguments: const <String>['install'],
          workingDirectory: iosDir.path,
        );
        if (podCode != 0) {
          throw _TaskFailure('pod install 失败');
        }
      }

      final useOfflineDesktopCrossCompiler =
          Platform.isMacOS && (platform == 'linux' || platform == 'windows');
      final int buildCode;
      if (useOfflineDesktopCrossCompiler) {
        final crossArgs = <String>[
          'scripts/cross-desktop.js',
          '--game-dir',
          gameDir.path,
          '--target',
          platform,
          if (_buildMode == BuildMode.showcase) ...<String>[
            '--dart-define',
            'SAKI_SHOW_MODE=true',
            '--dart-define',
            'SAKI_SHOWCASE_GAME_DIR=Game/$game',
          ],
        ];
        _appendLog('使用仓库内置离线目标包交叉编译 $platform');
        buildCode = await _runCommand(
          executable: Platform.environment['SAKI_NODE_BIN'] ?? 'node',
          arguments: crossArgs,
          workingDirectory: _repoRoot.path,
        );
      } else {
        final buildArgs = _buildArgsFor(platform, _buildMode, game);
        buildCode = await _runCommand(
          executable: 'flutter',
          arguments: buildArgs,
          workingDirectory: gameDir.path,
        );
      }

      if (buildCode != 0) {
        throw _TaskFailure('flutter build 失败');
      }

      final outputDir = _resolveBuildOutputDirectory(gameDir, platform);
      if (_buildMode == BuildMode.showcase &&
          (platform == 'macos' ||
              platform == 'windows' ||
              platform == 'linux')) {
        await _stageShowcaseGameDirectory(
          gameDir: gameDir,
          outputDir: outputDir,
          game: game,
        );
      }
      if (_buildMode == BuildMode.release) {
        await _packageReleaseBuildAsZip(
          gameDir: gameDir,
          outputDir: outputDir,
          game: game,
        );
      }

      _appendLog('构建完成: $game -> $platform');
      await _openBuildOutputInFileManager(gameDir, platform);
    } on _TaskFailure catch (e) {
      _appendLog('构建失败: ${e.message}');
    } finally {
      if (_buildMode == BuildMode.release) {
        await gamePubspec.writeAsString(originalPubspec);
        await engineLoader.writeAsString(originalEngineLoader);
        _appendLog('已恢复临时修改文件（pubspec + 编译入口）');
      }
    }
  }

  Future<_AssetRewriteResult> _prepareReleasePubspec({
    required Directory gameDir,
    required File pubspecFile,
    required String targetPlatform,
  }) async {
    final lines = await pubspecFile.readAsLines();
    var assetsStart = -1;
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^\s{2}assets:\s*$').hasMatch(lines[i])) {
        assetsStart = i;
        break;
      }
    }

    if (assetsStart < 0) {
      throw _TaskFailure('pubspec.yaml 未找到 flutter/assets 段');
    }

    var assetsEnd = assetsStart;
    while (assetsEnd + 1 < lines.length) {
      final nextLine = lines[assetsEnd + 1];
      final isAssetLine = RegExp(r'^\s{4}-\s+').hasMatch(nextLine);
      if (isAssetLine || nextLine.trim().isEmpty) {
        assetsEnd += 1;
        continue;
      }
      break;
    }

    final rawEntries = <String>[];
    for (var i = assetsStart + 1; i <= assetsEnd; i++) {
      final match = RegExp(r'^\s{4}-\s+(.+)$').firstMatch(lines[i]);
      if (match == null) {
        continue;
      }
      var entry = match.group(1)!.replaceAll(RegExp(r'\s+#.*$'), '').trim();
      if ((entry.startsWith('"') && entry.endsWith('"')) ||
          (entry.startsWith("'") && entry.endsWith("'"))) {
        entry = entry.substring(1, entry.length - 1);
      }
      if (entry.isNotEmpty) {
        rawEntries.add(entry);
      }
    }

    final expanded = <String>[];
    for (final entry in rawEntries) {
      if (_isGameScriptPath(entry)) {
        continue;
      }
      final normalized = _normalizePath(entry).replaceAll(RegExp(r'/$'), '');
      final fullPath = _joinPath(gameDir.path, normalized);
      final type = FileSystemEntity.typeSync(fullPath);

      if (type == FileSystemEntityType.notFound) {
        _appendLog('警告: 资源路径不存在，已跳过: $entry');
        continue;
      }

      if (type == FileSystemEntityType.file) {
        expanded.add(normalized);
        continue;
      }

      final files = <File>[];
      await for (final entity in Directory(
        fullPath,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File) {
          if (_basename(entity.path) == '.DS_Store') {
            continue;
          }
          files.add(entity);
        }
      }
      files.sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        final relative = _relativePath(file.path, gameDir.path);
        if (_isGameScriptPath(relative)) {
          continue;
        }
        expanded.add(_normalizePath(relative));
      }
    }

    final deduped = <String>[];
    final seen = <String>{};
    for (final entry in expanded) {
      if (entry.isEmpty) {
        continue;
      }
      if (seen.add(entry)) {
        deduped.add(entry);
      }
    }

    if (deduped.isEmpty) {
      throw _TaskFailure('发布资源清单为空，已中止构建');
    }

    final hasAssetsRoot = rawEntries.any((entry) {
      final n = _normalizePath(entry).replaceAll(RegExp(r'/$'), '');
      return n == 'Assets';
    });
    final mediaCount = deduped
        .where(
          (entry) => RegExp(
            r'^Assets/.*\.(png|jpg|jpeg|gif|bmp|webp|avif|mp4|mov|avi|mkv|webm)$',
            caseSensitive: false,
          ).hasMatch(entry),
        )
        .length;
    if (hasAssetsRoot && mediaCount == 0) {
      throw _TaskFailure('检测到配置了 Assets/，但展开后没有图片/视频资源，已中止构建');
    }

    List<String> finalEntries;
    if (targetPlatform == 'web') {
      finalEntries = deduped;
    } else {
      finalEntries = deduped.where((entry) {
      final n = entry.toLowerCase();
      if (n.startsWith('assets/')) {
        return false;
      }
        if (n.startsWith('gamescript/') || n.startsWith('gamescript_')) {
          return false;
        }
        return true;
      }).toList(growable: true);
      if (!finalEntries.contains('.saki_cache/game.sakipak')) {
        finalEntries.add('.saki_cache/game.sakipak');
      }
    }

    final output = <String>[];
    output.addAll(lines.sublist(0, assetsStart + 1));
    for (final entry in finalEntries) {
      output.add('    - $entry');
    }
    if (assetsEnd + 1 < lines.length) {
      output.addAll(lines.sublist(assetsEnd + 1));
    }

    await pubspecFile.writeAsString('${output.join('\n')}\n');
    return _AssetRewriteResult(
      totalAssets: finalEntries.length,
      mediaAssets: mediaCount,
    );
  }

  Future<bool> _generateSakiPack({
    required Directory gameDir,
    required Directory cacheDir,
  }) async {
    cacheDir.createSync(recursive: true);
    final outputFile = _joinPath(cacheDir.path, 'game.sakipak');
    final legacyFile = File(_joinPath(_joinPath(gameDir.path, 'Assets'), 'game.sakipak'));
    final code = await _runCommand(
      executable: 'node',
      arguments: <String>[
        'scripts/build_saki_pack.js',
        gameDir.path,
        outputFile,
      ],
      workingDirectory: _repoRoot.path,
    );
    if (legacyFile.existsSync()) {
      await legacyFile.delete();
    }
    return code == 0;
  }

  List<String> _buildArgsFor(String platform, BuildMode mode, String game) {
    final showModeDefine = mode == BuildMode.showcase
        ? <String>[
            '--dart-define=SAKI_SHOW_MODE=true',
            '--dart-define=SAKI_SHOWCASE_GAME_DIR=Game/$game',
          ]
        : const <String>[];
    switch (platform) {
      case 'macos':
        return <String>['build', 'macos', '--release', ...showModeDefine];
      case 'linux':
        return <String>['build', 'linux', '--release', ...showModeDefine];
      case 'windows':
        return <String>['build', 'windows', '--release', ...showModeDefine];
      case 'android':
        return <String>[
          'build',
          'apk',
          '--release',
          '--target-platform',
          'android-arm64',
          ...showModeDefine,
        ];
      case 'ios':
        return <String>[
          'build',
          'ios',
          '--release',
          '--no-codesign',
          ...showModeDefine,
        ];
      case 'web':
        return <String>['build', 'web', '--release', ...showModeDefine];
      default:
        throw _TaskFailure('不支持的平台: $platform');
    }
  }

  Future<void> _stageShowcaseGameDirectory({
    required Directory gameDir,
    required Directory outputDir,
    required String game,
  }) async {
    if (!outputDir.existsSync()) {
      throw _TaskFailure('构建产物目录不存在: ${outputDir.path}');
    }

    final sourceAssetsDir = Directory(_joinPath(gameDir.path, 'Assets'));
    if (!sourceAssetsDir.existsSync()) {
      throw _TaskFailure('演出模式资源目录不存在: ${sourceAssetsDir.path}');
    }

    final scriptDirs = gameDir
        .listSync(followLinks: false)
        .whereType<Directory>()
        .where((dir) {
          final name = _basename(dir.path);
          return name == 'GameScript' || name.startsWith('GameScript_');
        })
        .toList();
    if (scriptDirs.isEmpty) {
      throw _TaskFailure('未找到 GameScript 目录，无法生成演出模式可热更新包');
    }

    final targetGameRoot = Directory(
      _joinPath(_joinPath(outputDir.path, 'Game'), game),
    );
    if (targetGameRoot.existsSync()) {
      await targetGameRoot.delete(recursive: true);
    }
    await targetGameRoot.create(recursive: true);

    await _copyDirectoryRecursive(
      source: sourceAssetsDir,
      target: Directory(_joinPath(targetGameRoot.path, 'Assets')),
    );
    for (final dir in scriptDirs) {
      final name = _basename(dir.path);
      await _copyDirectoryRecursive(
        source: dir,
        target: Directory(_joinPath(targetGameRoot.path, name)),
      );
    }

    for (final fileName in const <String>[
      'game_config.txt',
      'default_game.txt',
      'icon.png',
    ]) {
      final sourceFile = File(_joinPath(gameDir.path, fileName));
      if (!sourceFile.existsSync()) {
        continue;
      }
      final targetFile = File(_joinPath(targetGameRoot.path, fileName));
      await targetFile.parent.create(recursive: true);
      await sourceFile.copy(targetFile.path);
    }

    _appendLog('演出模式资源已打包: ${targetGameRoot.path}');
  }

  Future<void> _copyDirectoryRecursive({
    required Directory source,
    required Directory target,
  }) async {
    if (!await source.exists()) {
      return;
    }

    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = _basename(entity.path);
      final destinationPath = _joinPath(target.path, name);
      if (entity is Directory) {
        await _copyDirectoryRecursive(
          source: entity,
          target: Directory(destinationPath),
        );
      } else if (entity is File) {
        await entity.copy(destinationPath);
      }
    }
  }

  Directory _resolveBuildOutputDirectory(Directory gameDir, String platform) {
    final candidates = <String>[];
    switch (platform) {
      case 'macos':
        candidates.add(
          _joinPath(gameDir.path, 'build/macos/Build/Products/Release'),
        );
        break;
      case 'linux':
        candidates.add(
          _joinPath(gameDir.path, 'build/linux/x64/release/bundle'),
        );
        break;
      case 'windows':
        candidates.add(
          _joinPath(gameDir.path, 'build/windows/x64/runner/Release'),
        );
        break;
      case 'android':
        candidates.add(
          _joinPath(gameDir.path, 'build/app/outputs/flutter-apk'),
        );
        candidates.add(
          _joinPath(gameDir.path, 'build/app/outputs/apk/release'),
        );
        break;
      case 'ios':
        candidates.add(_joinPath(gameDir.path, 'build/ios/iphoneos'));
        candidates.add(_joinPath(gameDir.path, 'build/ios/archive'));
        break;
      case 'web':
        candidates.add(_joinPath(gameDir.path, 'build/web'));
        break;
      default:
        break;
    }

    for (final candidate in candidates) {
      final dir = Directory(candidate);
      if (dir.existsSync()) {
        return dir;
      }
    }
    return Directory(_joinPath(gameDir.path, 'build'));
  }

  Future<void> _openBuildOutputInFileManager(
    Directory gameDir,
    String platform,
  ) async {
    final targetDir = _resolveBuildOutputDirectory(gameDir, platform);
    if (!targetDir.existsSync()) {
      _appendLog('提示: 构建输出目录不存在，跳过自动打开: ${targetDir.path}');
      return;
    }

    int code = -1;
    if (Platform.isMacOS) {
      code = await _runDetachedCommand(
        executable: 'open',
        arguments: <String>[targetDir.path],
        workingDirectory: _repoRoot.path,
      );
    } else if (Platform.isWindows) {
      code = await _runDetachedCommand(
        executable: 'explorer',
        arguments: <String>[_toWindowsPath(targetDir.path)],
        workingDirectory: _repoRoot.path,
      );
    } else if (Platform.isLinux) {
      if (await _isCommandAvailable('xdg-open')) {
        code = await _runDetachedCommand(
          executable: 'xdg-open',
          arguments: <String>[targetDir.path],
          workingDirectory: _repoRoot.path,
        );
      } else if (await _isCommandAvailable('gio')) {
        code = await _runDetachedCommand(
          executable: 'gio',
          arguments: <String>['open', targetDir.path],
          workingDirectory: _repoRoot.path,
        );
      }
    }

    if (code == 0) {
      _appendLog('已自动打开构建产物目录: ${targetDir.path}');
    } else {
      _appendLog('提示: 自动打开目录失败，请手动查看: ${targetDir.path}');
    }
  }

  Future<void> _packageReleaseBuildAsZip({
    required Directory gameDir,
    required Directory outputDir,
    required String game,
  }) async {
    if (!outputDir.existsSync()) {
      throw _TaskFailure('构建产物目录不存在，无法打包 zip: ${outputDir.path}');
    }

    final gameName = _sanitizeFileNamePart(
      _readGameDisplayName(gameDir, fallback: game),
    );
    final version = _sanitizeFileNamePart(
      _readGameVersion(File(_joinPath(gameDir.path, 'pubspec.yaml'))),
    );
    final buildDate = _formatBuildDate(DateTime.now());
    final archiveName = '$gameName-$version-$buildDate.zip';
    final archiveFile = File(_joinPath(outputDir.parent.path, archiveName));

    if (archiveFile.existsSync()) {
      await archiveFile.delete();
    }

    _appendLog('发布构建完成，正在打包 zip: $archiveName');

    int zipCode;
    if (Platform.isWindows) {
      final sourcePath = _escapePowerShellSingleQuoted(outputDir.path);
      final archivePath = _escapePowerShellSingleQuoted(archiveFile.path);
      final command =
          "Compress-Archive -Path '$sourcePath' -DestinationPath '$archivePath' -Force";
      if (await _isCommandAvailable('powershell')) {
        zipCode = await _runCommand(
          executable: 'powershell',
          arguments: <String>[
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            command,
          ],
          workingDirectory: outputDir.parent.path,
        );
      } else if (await _isCommandAvailable('pwsh')) {
        zipCode = await _runCommand(
          executable: 'pwsh',
          arguments: <String>['-NoProfile', '-Command', command],
          workingDirectory: outputDir.parent.path,
        );
      } else {
        throw _TaskFailure('未找到 PowerShell，无法自动打包 zip');
      }
    } else {
      if (!await _isCommandAvailable('zip')) {
        throw _TaskFailure('未找到 zip 命令，无法自动打包构建产物');
      }
      zipCode = await _runCommand(
        executable: 'zip',
        arguments: <String>[
          '-r',
          '-q',
          archiveFile.path,
          _basename(outputDir.path),
        ],
        workingDirectory: outputDir.parent.path,
      );
    }

    if (zipCode != 0 || !archiveFile.existsSync()) {
      throw _TaskFailure('自动打包 zip 失败');
    }

    _appendLog('已生成发布压缩包: ${archiveFile.path}');
  }

  Future<bool> _launchRunInSystemTerminal({
    required String game,
    required String gameDir,
    required String runDevice,
    required RunBuildMode runBuildMode,
  }) async {
    final scriptDir = Directory(_joinPath(_repoRoot.path, '.saki_launcher'));
    scriptDir.createSync(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;

    if (Platform.isWindows) {
      final scriptFile = File(_joinPath(scriptDir.path, 'run_$ts.cmd'));
      await scriptFile.writeAsString(
        _buildWindowsRunScript(
          game: game,
          gameDir: gameDir,
          runDevice: runDevice,
          runBuildMode: runBuildMode,
        ),
      );
      final code = await _runDetachedCommand(
        executable: 'cmd',
        arguments: <String>['/c', 'start', '', scriptFile.path],
        workingDirectory: _repoRoot.path,
      );
      return code == 0;
    }

    final scriptFile = File(_joinPath(scriptDir.path, 'run_$ts.command'));
    await scriptFile.writeAsString(
      _buildPosixRunScript(
        game: game,
        gameDir: gameDir,
        runDevice: runDevice,
        runBuildMode: runBuildMode,
      ),
    );

    final chmod = await _runCommand(
      executable: 'chmod',
      arguments: <String>['+x', scriptFile.path],
      workingDirectory: _repoRoot.path,
    );
    if (chmod != 0) {
      _appendLog('赋予脚本执行权限失败');
      return false;
    }

    if (Platform.isMacOS) {
      final code = await _runDetachedCommand(
        executable: 'open',
        arguments: <String>[scriptFile.path],
        workingDirectory: _repoRoot.path,
      );
      return code == 0;
    }

    if (Platform.isLinux) {
      final candidates = <_TerminalCandidate>[
        _TerminalCandidate('x-terminal-emulator', <String>[
          '-e',
          scriptFile.path,
        ]),
        _TerminalCandidate('gnome-terminal', <String>[
          '--',
          'bash',
          scriptFile.path,
        ]),
        _TerminalCandidate('konsole', <String>['-e', 'bash', scriptFile.path]),
        _TerminalCandidate('xterm', <String>['-e', 'bash', scriptFile.path]),
      ];
      for (final candidate in candidates) {
        if (!await _isCommandAvailable(candidate.executable)) {
          continue;
        }
        final code = await _runDetachedCommand(
          executable: candidate.executable,
          arguments: candidate.arguments,
          workingDirectory: _repoRoot.path,
        );
        if (code == 0) {
          return true;
        }
      }
      return false;
    }

    return false;
  }

  String _buildPosixRunScript({
    required String game,
    required String gameDir,
    required String runDevice,
    required RunBuildMode runBuildMode,
  }) {
    final repoEsc = _shellEscape(_repoRoot.path);
    final gameEsc = _shellEscape(game);
    final gameDirEsc = _shellEscape(gameDir);
    final bridgeEsc = _shellEscape(
      _joinPath(_repoRoot.path, 'scripts/launcher-bridge.js'),
    );
    final deviceEsc = _shellEscape(runDevice);
    final defineArgs = <String>[
      '--dart-define=SAKI_GAME_PATH=$gameDir',
      if (_isShowcaseMode(runBuildMode)) '--dart-define=SAKI_SHOW_MODE=true',
      if (_isShowcaseMode(runBuildMode))
        '--dart-define=SAKI_SHOWCASE_GAME_DIR=Game/$game',
    ];
    final defineEsc = defineArgs.map(_shellEscape).join(' ');
    final modeFlag = _runBuildModeFlag(runBuildMode);
    final modePart = modeFlag.isEmpty ? '' : '${_shellEscape(modeFlag)} ';

    return '''#!/usr/bin/env bash
set -euo pipefail

cd $repoEsc
node $bridgeEsc prepare-project --game $gameEsc
cd $gameDirEsc
flutter pub get
node $bridgeEsc prepare-project --game $gameEsc --generate-icons

echo ""
echo "启动 Flutter 运行（支持 r/R/q 热更新命令）..."
set +e
flutter run ${modePart}-d $deviceEsc $defineEsc
status=\$?
set -e

echo ""
echo "运行已结束（退出码: \$status）"
read -r -p "按回车关闭终端..." _
exit \$status
''';
  }

  String _buildWindowsRunScript({
    required String game,
    required String gameDir,
    required String runDevice,
    required RunBuildMode runBuildMode,
  }) {
    final repoPath = _toWindowsPath(_repoRoot.path);
    final gamePath = _toWindowsPath(gameDir);
    final bridgeScript = _toWindowsPath(
      _joinPath(_repoRoot.path, 'scripts/launcher-bridge.js'),
    );
    final modeFlag = _runBuildModeFlag(runBuildMode);
    final modePart = modeFlag.isEmpty ? '' : '$modeFlag ';
    final extraShowModeDefine = _isShowcaseMode(runBuildMode)
        ? ' "--dart-define=SAKI_SHOW_MODE=true" "--dart-define=SAKI_SHOWCASE_GAME_DIR=Game/$game"'
        : '';

    return '''@echo off
setlocal

cd /d "$repoPath"
if errorlevel 1 goto end

node "$bridgeScript" prepare-project --game "$game"
if errorlevel 1 goto end

cd /d "$gamePath"
if errorlevel 1 goto end

flutter pub get
if errorlevel 1 goto end

node "$bridgeScript" prepare-project --game "$game" --generate-icons
if errorlevel 1 goto end

echo.
echo 启动 Flutter 运行（支持 r/R/q 热更新命令）...
flutter run ${modePart}-d $runDevice "--dart-define=SAKI_GAME_PATH=$gamePath"$extraShowModeDefine

:end
echo.
echo 运行已结束，按任意键关闭窗口...
pause >nul
endlocal
''';
  }

  Future<bool> _isCommandAvailable(String command) async {
    final lookupExecutable = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(
        lookupExecutable,
        <String>[command],
        runInShell: true,
        workingDirectory: _repoRoot.path,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<int> _runDetachedCommand({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
  }) async {
    final command = '$executable ${arguments.join(' ')}';
    _appendLog(
      '\$ $command',
      startNewSession: true,
      sessionReason: '进程: $command',
    );
    try {
      await Process.start(
        executable,
        arguments,
        runInShell: true,
        workingDirectory: workingDirectory,
        mode: ProcessStartMode.detached,
      );
      return 0;
    } on ProcessException catch (e) {
      _appendLog('命令启动失败: ${e.message}');
      return -1;
    }
  }

  Future<int> _runCommand({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
  }) async {
    final command = '$executable ${arguments.join(' ')}';
    _appendLog(
      '\$ $command',
      startNewSession: true,
      sessionReason: '进程: $command',
    );
    Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        runInShell: true,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      _appendLog('命令启动失败: ${e.message}');
      return -1;
    }
    _activeProcess = process;

    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_appendLog);
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _appendLog('[stderr] $line'));

    final code = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    if (identical(_activeProcess, process)) {
      _activeProcess = null;
    }
    _appendLog('退出码: $code');
    return code;
  }

  Future<void> _sendRunControl(String control, String label) async {
    final process = _activeProcess;
    if (process == null || !_isRunTask) {
      _appendLog('没有可控制的运行进程');
      return;
    }

    try {
      process.stdin.write(control);
      await process.stdin.flush();
      _appendLog('已发送运行指令: $label');
    } catch (e) {
      _appendLog('发送运行指令失败: $e');
    }
  }

  Future<void> _requestSafeRestart() async {
    final process = _activeProcess;
    if (process == null || !_isRunTask) {
      _appendLog('没有可重启的运行进程');
      return;
    }
    if (_runMode != RunLaunchMode.embedded) {
      _appendLog('系统终端模式请在终端内手动重启');
      return;
    }

    _pendingSafeRestart = true;
    _appendLog('已请求安全重启：将停止当前运行并自动重新启动');
    await _sendRunControl('q', '退出运行');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (identical(process, _activeProcess)) {
      await _stopActiveTask();
    }
  }

  Future<void> _requestHotRestart() async {
    final process = _activeProcess;
    if (process == null || !_isRunTask) {
      _appendLog('没有可重启的运行进程');
      return;
    }
    if (_runMode != RunLaunchMode.embedded) {
      _appendLog('系统终端模式请在终端内手动热重启');
      return;
    }
    if (_runBuildMode != RunBuildMode.debug) {
      _appendLog('仅 Debug 运行配置支持热重启');
      return;
    }
    await _sendRunControl('R', '热重启');
  }

  Future<void> _stopActiveTask() async {
    final process = _activeProcess;
    if (process == null) {
      return;
    }
    _appendLog('请求停止任务...');
    try {
      process.kill(ProcessSignal.sigint);
    } catch (_) {
      process.kill();
    }

    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (identical(process, _activeProcess)) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {
        process.kill();
      }
    }
  }

  void _clearLogs() {
    setState(() {
      _logSessions.clear();
    });
  }

  void _appendLog(
    String line, {
    bool startNewSession = false,
    String? sessionReason,
  }) {
    if (!mounted) {
      return;
    }
    final sanitized = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
    final shouldSplitForHotReload = _isHotReloadBoundary(sanitized);
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    final mustCreateSession =
        _logSessions.isEmpty || startNewSession || shouldSplitForHotReload;

    setState(() {
      if (mustCreateSession) {
        final reason =
            sessionReason ??
            (shouldSplitForHotReload
                ? _resolveHotReloadSessionReason(sanitized)
                : '新进程');
        _logSessions.add(
          _LogSession(
            id: _nextLogSessionId++,
            reason: reason,
            startedAt: DateTime.now(),
            lines: <String>[],
          ),
        );
      }
      _logSessions.last.lines.add('[$time] $sanitized');
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScrollController.hasClients) {
        return;
      }
      _logScrollController.jumpTo(
        _logScrollController.position.maxScrollExtent,
      );
    });
  }

  bool _isHotReloadBoundary(String line) {
    final normalized = line.toLowerCase();
    return normalized.contains('performing hot reload...') ||
        normalized.contains('performing hot restart...') ||
        normalized.contains('performing reassemble...');
  }

  String _resolveHotReloadSessionReason(String line) {
    final normalized = line.toLowerCase();
    if (normalized.contains('hot restart')) {
      return '热重启';
    }
    if (normalized.contains('hot reload')) {
      return '热重载';
    }
    return '热更新';
  }

  String _joinPath(String a, String b) {
    if (a.endsWith(Platform.pathSeparator)) {
      return '$a$b';
    }
    return '$a${Platform.pathSeparator}$b';
  }

  String _basename(String path) {
    final normalized = _normalizePath(path).replaceAll(RegExp(r'/$'), '');
    final index = normalized.lastIndexOf('/');
    if (index < 0) {
      return normalized;
    }
    return normalized.substring(index + 1);
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/');
  }

  String _toWindowsPath(String path) {
    return path.replaceAll('/', '\\');
  }

  String _shellEscape(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String _escapePowerShellSingleQuoted(String value) {
    return value.replaceAll("'", "''");
  }

  String _readGameDisplayName(Directory gameDir, {required String fallback}) {
    final configFile = File(_joinPath(gameDir.path, 'game_config.txt'));
    if (!configFile.existsSync()) {
      return fallback;
    }

    try {
      final lines = configFile
          .readAsLinesSync()
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (lines.isNotEmpty) {
        return lines.first;
      }
    } catch (_) {
      // ignore and fallback.
    }
    return fallback;
  }

  String _readGameVersion(File pubspecFile) {
    if (!pubspecFile.existsSync()) {
      return '0.0.0';
    }

    try {
      final versionPattern = RegExp(r'^\s*version:\s*(.+?)\s*$');
      for (final line in pubspecFile.readAsLinesSync()) {
        final match = versionPattern.firstMatch(line);
        if (match == null) {
          continue;
        }

        var version = match.group(1)!.replaceAll(RegExp(r'\s+#.*$'), '').trim();
        if ((version.startsWith('"') && version.endsWith('"')) ||
            (version.startsWith("'") && version.endsWith("'"))) {
          version = version.substring(1, version.length - 1).trim();
        }
        if (version.isNotEmpty) {
          return version;
        }
      }
    } catch (_) {
      // ignore and fallback.
    }
    return '0.0.0';
  }

  String _formatBuildDate(DateTime time) {
    final year = time.year.toString().padLeft(4, '0');
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '$year$month$day';
  }

  String _sanitizeFileNamePart(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return sanitized.isEmpty ? 'unknown' : sanitized;
  }

  String _relativePath(String fullPath, String basePath) {
    final full = _normalizePath(fullPath);
    final base = _normalizePath(basePath).replaceAll(RegExp(r'/$'), '');
    if (full.startsWith('$base/')) {
      return full.substring(base.length + 1);
    }
    return full;
  }

  bool _isGameScriptPath(String path) {
    final n = _normalizePath(path).replaceAll(RegExp(r'/$'), '');
    return n == 'GameScript' ||
        n.startsWith('GameScript/') ||
        n.startsWith('GameScript_');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? <Color>[
                    Color.alphaBlend(
                      scheme.primary.withValues(alpha: 0.08),
                      scheme.surface,
                    ),
                    scheme.surface,
                    Color.alphaBlend(
                      scheme.tertiary.withValues(alpha: 0.07),
                      scheme.surface,
                    ),
                  ]
                : <Color>[
                    Color.alphaBlend(
                      scheme.primary.withValues(alpha: 0.10),
                      scheme.surface,
                    ),
                    Color.alphaBlend(
                      scheme.secondary.withValues(alpha: 0.08),
                      scheme.surface,
                    ),
                    Color.alphaBlend(
                      scheme.tertiary.withValues(alpha: 0.10),
                      scheme.surface,
                    ),
                  ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final leftFlex = constraints.maxWidth >= 1200
                    ? 36
                    : constraints.maxWidth >= 900
                    ? 40
                    : 44;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _buildHeader(),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Expanded(flex: leftFlex, child: _buildControlPanel()),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 100 - leftFlex,
                            child: _buildLogPanel(),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final engineIconFile = File(_joinPath(_repoRoot.path, 'Engine/icon.png'));
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: isDark ? 0.86 : 0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.52 : 0.34),
        ),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: engineIconFile.existsSync()
                ? Image.file(
                    engineIconFile,
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      Icons.rocket_launch_rounded,
                      color: scheme.onPrimary,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'SakiEngine 开发启动器',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '统一执行创建、运行与发布构建任务',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _showSettingsDialog,
            tooltip: '设置',
            icon: const Icon(Icons.tune_rounded),
          ),
          if (_busy)
            const Row(
              children: <Widget>[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('任务执行中'),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    final defaultLabel = _defaultGame == null ? '未设置' : _defaultGame!;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: isDark ? 0.88 : 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: isDark ? 0.48 : 0.3),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            '项目控制',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            _repoRoot.path,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: _selectedGame,
            decoration: const InputDecoration(
              labelText: '游戏项目',
              border: OutlineInputBorder(),
            ),
            items: _gameProjects
                .map(
                  (name) =>
                      DropdownMenuItem<String>(value: name, child: Text(name)),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    setState(() {
                      _selectedGame = value;
                    });
                  },
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshProjects,
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新项目'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || _selectedGame == null
                      ? null
                      : _setDefaultGame,
                  icon: const Icon(Icons.push_pin_outlined),
                  label: const Text('设为默认'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _showCreateProjectDialog,
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('创建新项目'),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || _selectedGame == null
                      ? null
                      : _showEditProjectVersionDialog,
                  icon: const Icon(Icons.new_releases_outlined),
                  label: const Text('编辑版本号'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy || _selectedGame == null
                      ? null
                      : _showEditConfigsDialog,
                  icon: const Icon(Icons.tune_outlined),
                  label: const Text('编辑 configs'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('默认项目: $defaultLabel'),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 16),
          const Text('运行', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _runTarget,
            decoration: const InputDecoration(
              labelText: '运行目标',
              border: OutlineInputBorder(),
            ),
            items: _runTargets
                .map(
                  (target) => DropdownMenuItem<String>(
                    value: target,
                    child: Text(target),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _runTarget = value;
                    });
                  },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<RunLaunchMode>(
            initialValue: _runMode,
            decoration: const InputDecoration(
              labelText: '运行模式',
              border: OutlineInputBorder(),
            ),
            items: RunLaunchMode.values
                .map(
                  (mode) => DropdownMenuItem<RunLaunchMode>(
                    value: mode,
                    child: Text(_runModeLabel(mode)),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _runMode = value;
                    });
                  },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<RunBuildMode>(
            initialValue: _runBuildMode,
            decoration: const InputDecoration(
              labelText: '运行配置',
              border: OutlineInputBorder(),
            ),
            items: RunBuildMode.values
                .map(
                  (mode) => DropdownMenuItem<RunBuildMode>(
                    value: mode,
                    child: Text(_runBuildModeLabel(mode)),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) async {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _runBuildMode = value;
                    });
                    final next = widget.settingsNotifier.value.copyWith(
                      defaultRunBuildMode: value,
                    );
                    await _saveSettings(next);
                  },
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy || _selectedGame == null ? null : _runSelectedGame,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('运行游戏'),
          ),
          if (_isRunTask &&
              _runMode == RunLaunchMode.embedded &&
              _activeProcess != null) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _runBuildMode == RunBuildMode.debug
                      ? () {
                          unawaited(_requestHotRestart());
                        }
                      : null,
                  child: const Text('热重启 R'),
                ),
                OutlinedButton(
                  onPressed: _runBuildMode == RunBuildMode.debug
                      ? () {
                          unawaited(_sendRunControl('r', '热重载'));
                        }
                      : null,
                  child: const Text('热重载 r'),
                ),
                OutlinedButton(
                  onPressed: () {
                    unawaited(_requestSafeRestart());
                  },
                  child: const Text('安全重启'),
                ),
                OutlinedButton(
                  onPressed: () {
                    unawaited(_sendRunControl('q', '退出运行'));
                  },
                  child: const Text('退出 q'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          const Text('构建', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<BuildMode>(
            initialValue: _buildMode,
            decoration: const InputDecoration(
              labelText: '构建模式',
              border: OutlineInputBorder(),
            ),
            items: BuildMode.values
                .map(
                  (mode) => DropdownMenuItem<BuildMode>(
                    value: mode,
                    child: Text(_buildModeLabel(mode)),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _buildMode = value;
                    });
                  },
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _buildTarget,
            decoration: const InputDecoration(
              labelText: '构建目标',
              border: OutlineInputBorder(),
            ),
            items: _buildTargets
                .map(
                  (target) => DropdownMenuItem<String>(
                    value: target,
                    child: Text(target),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _buildTarget = value;
                    });
                  },
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _busy || _selectedGame == null
                ? null
                : _buildSelectedGame,
            icon: const Icon(Icons.build_circle_outlined),
            label: Text(_buildMode == BuildMode.showcase ? '演出构建' : '发布构建'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? _stopActiveTask : null,
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(_isRunTask ? '停止运行任务' : '停止当前任务'),
          ),
          const SizedBox(height: 10),
          Text(
            '说明: 启动器已覆盖 run.sh/build.sh 主要流程，可直接在此完成创建、运行、构建。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelBackground = Color.alphaBlend(
      (isDark ? Colors.black : scheme.primary).withValues(
        alpha: isDark ? 0.22 : 0.06,
      ),
      scheme.surfaceContainerLow,
    );
    final panelBorder = scheme.outlineVariant.withValues(
      alpha: isDark ? 0.6 : 0.36,
    );
    final headerTextColor = scheme.onSurface;
    final bodyTextColor = scheme.onSurface.withValues(
      alpha: isDark ? 0.92 : 0.95,
    );

    return Container(
      decoration: BoxDecoration(
        color: panelBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: panelBorder),
      ),
      child: Column(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: panelBorder)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '终端输出',
                    style: TextStyle(
                      color: headerTextColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _clearLogs,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                  label: const Text('清空'),
                ),
                TextButton.icon(
                  onPressed: _currentLogSessionLines.isEmpty
                      ? null
                      : () {
                          unawaited(_copyCurrentRunLogs());
                        },
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('复制当前运行日志'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _logScrollController,
              child: SingleChildScrollView(
                controller: _logScrollController,
                padding: const EdgeInsets.all(12),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (
                        var sessionIndex = 0;
                        sessionIndex < _logSessions.length;
                        sessionIndex++
                      ) ...<Widget>[
                        if (sessionIndex > 0)
                          _buildSessionDivider(_logSessions[sessionIndex]),
                        SelectableText.rich(
                          _buildSessionLogSpan(_logSessions[sessionIndex]),
                          style: TextStyle(
                            color: bodyTextColor,
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyCurrentRunLogs() async {
    final currentLogs = _currentLogSessionLines.join('\n');
    await Clipboard.setData(ClipboardData(text: currentLogs));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('当前运行日志已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  List<String> get _currentLogSessionLines {
    if (_logSessions.isEmpty) {
      return const <String>[];
    }
    return _logSessions.last.lines;
  }

  TextSpan _buildSessionLogSpan(_LogSession session) {
    final children = <InlineSpan>[];
    for (var lineIndex = 0; lineIndex < session.lines.length; lineIndex++) {
      children.add(_buildLogLineSpan(session.lines[lineIndex]));
      if (lineIndex != session.lines.length - 1) {
        children.add(const TextSpan(text: '\n'));
      }
    }
    return TextSpan(children: children);
  }

  Widget _buildSessionDivider(_LogSession session) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final start = session.startedAt;
    final startTime =
        '${start.hour.toString().padLeft(2, '0')}:'
        '${start.minute.toString().padLeft(2, '0')}:'
        '${start.second.toString().padLeft(2, '0')}';
    final labelStyle = TextStyle(
      color: scheme.outline.withValues(alpha: isDark ? 0.95 : 0.88),
      fontFamily: 'monospace',
      fontSize: 12.0,
      height: 1.25,
      fontWeight: FontWeight.w600,
    );
    final dividerColor = scheme.outlineVariant.withValues(
      alpha: isDark ? 0.7 : 0.6,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(child: Divider(color: dividerColor, thickness: 1)),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '会话 #${session.id} ${session.reason} ($startTime)',
              style: labelStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: dividerColor, thickness: 1)),
        ],
      ),
    );
  }

  TextSpan _buildLogLineSpan(String line) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final timeColor = scheme.outline.withValues(alpha: isDark ? 0.95 : 0.85);
    final timeMatch = RegExp(r'^\[\d{2}:\d{2}:\d{2}\]\s?').firstMatch(line);
    final children = <InlineSpan>[];
    var body = line;
    if (timeMatch != null) {
      final prefix = line.substring(0, timeMatch.end);
      body = line.substring(timeMatch.end);
      children.add(
        TextSpan(
          text: prefix,
          style: TextStyle(
            color: timeColor,
            fontFamily: 'monospace',
            fontSize: 12.5,
            height: 1.35,
          ),
        ),
      );
    }

    final bodyStyle = _resolveLogBodyStyle(body);
    children.add(TextSpan(text: body, style: bodyStyle));
    return TextSpan(children: children);
  }

  TextStyle _resolveLogBodyStyle(String body) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = TextStyle(
      color: scheme.onSurface.withValues(alpha: isDark ? 0.92 : 0.95),
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.35,
    );
    final normalized = body.toLowerCase();

    if (body.startsWith('\$ ') || normalized.contains('flutter run')) {
      return base.copyWith(color: scheme.primary);
    }
    if (body.startsWith('[stderr]') ||
        normalized.contains('error') ||
        normalized.contains('exception') ||
        body.contains('失败') ||
        body.contains('错误') ||
        RegExp(r'退出码:\s*[1-9]\d*').hasMatch(body)) {
      return base.copyWith(color: scheme.error);
    }
    if (normalized.contains('warning') || body.contains('警告')) {
      return base.copyWith(color: scheme.tertiary);
    }
    if (body.contains('成功') ||
        body.contains('完成') ||
        body.contains('可用') ||
        body.contains('已复制') ||
        body.contains('退出码: 0')) {
      return base.copyWith(color: scheme.secondary);
    }

    return base;
  }
}

class _SeedChoice {
  final String label;
  final Color color;

  const _SeedChoice(this.label, this.color);
}

class _LogSession {
  final int id;
  final String reason;
  final DateTime startedAt;
  final List<String> lines;

  _LogSession({
    required this.id,
    required this.reason,
    required this.startedAt,
    required this.lines,
  });
}

class _PsColorSquarePainter extends CustomPainter {
  final double hue;
  final double saturation;
  final double value;

  const _PsColorSquarePainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final borderPaint = Paint()
      ..color = const Color(0x33000000)
      ..style = PaintingStyle.stroke;

    final base = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    final huePaint = Paint()..color = base;
    canvas.drawRect(rect, huePaint);

    final whiteGradient = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: <Color>[Colors.white, Color(0x00FFFFFF)],
      ).createShader(rect);
    canvas.drawRect(rect, whiteGradient);

    final blackGradient = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0x00000000), Colors.black],
      ).createShader(rect);
    canvas.drawRect(rect, blackGradient);

    canvas.drawRect(rect, borderPaint);

    final selector = Offset(saturation * size.width, (1 - value) * size.height);
    final ringPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final ringShadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(selector, 7, ringShadow);
    canvas.drawCircle(selector, 6, ringPaint);
  }

  @override
  bool shouldRepaint(covariant _PsColorSquarePainter oldDelegate) {
    return oldDelegate.hue != hue ||
        oldDelegate.saturation != saturation ||
        oldDelegate.value != value;
  }
}

class _PsHueSliderPainter extends CustomPainter {
  final double hue;

  const _PsHueSliderPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hueGradient = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFFFF0000),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF00FFFF),
          Color(0xFF0000FF),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, hueGradient);

    final borderPaint = Paint()
      ..color = const Color(0x33000000)
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, borderPaint);

    final y = (hue / 360) * size.height;
    final clampedY = y.clamp(0, size.height).toDouble();
    final markerRect = Rect.fromLTWH(0, clampedY - 2, size.width, 4);
    canvas.drawRect(
      markerRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      markerRect,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _PsHueSliderPainter oldDelegate) {
    return oldDelegate.hue != hue;
  }
}

String _launcherSettingsFilePath() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';
  return '$home/.sakiengine_launcher_settings.json';
}

Future<LauncherUiSettings> _loadLauncherUiSettings() async {
  final file = File(_launcherSettingsFilePath());
  if (!file.existsSync()) {
    return LauncherUiSettings.defaults();
  }

  try {
    final raw = await file.readAsString();
    final jsonMap = jsonDecode(raw);
    if (jsonMap is Map<String, dynamic>) {
      return LauncherUiSettings.fromJson(jsonMap);
    }
    if (jsonMap is Map) {
      return LauncherUiSettings.fromJson(
        jsonMap.map((key, value) => MapEntry('$key', value)),
      );
    }
  } catch (_) {
    // ignore and fallback to defaults.
  }
  return LauncherUiSettings.defaults();
}

Future<void> _saveLauncherUiSettings(LauncherUiSettings settings) async {
  final file = File(_launcherSettingsFilePath());
  try {
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  } catch (_) {
    // ignore write failure; runtime settings still applied in memory.
  }
}

class _AssetRewriteResult {
  final int totalAssets;
  final int mediaAssets;

  const _AssetRewriteResult({
    required this.totalAssets,
    required this.mediaAssets,
  });
}

class _ConfigEntry {
  final String key;
  final String value;
  final String inlineComment;

  const _ConfigEntry({
    required this.key,
    required this.value,
    required this.inlineComment,
  });
}

class _ConfigEntryDraft {
  final TextEditingController key;
  final TextEditingController value;
  final String inlineComment;

  const _ConfigEntryDraft({
    required this.key,
    required this.value,
    required this.inlineComment,
  });
}

class _ConfigsVisualDocument {
  final List<String> headerLines;
  final List<String> trailingLines;
  final List<_ConfigEntry> entries;

  const _ConfigsVisualDocument({
    required this.headerLines,
    required this.trailingLines,
    required this.entries,
  });
}

class _TerminalCandidate {
  final String executable;
  final List<String> arguments;

  const _TerminalCandidate(this.executable, this.arguments);
}

class _TaskFailure implements Exception {
  final String message;

  const _TaskFailure(this.message);
}
