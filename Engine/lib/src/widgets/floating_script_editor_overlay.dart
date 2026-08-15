import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/game/game_script_localization.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/key_sequence_detector.dart';
import 'package:sakiengine/src/utils/music_manager.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';

String? extractVoiceFileFromScriptLine(String line) {
  final trimmed = line.trimLeft();
  if (!trimmed.startsWith('voice') ||
      (trimmed.length > 'voice'.length &&
          trimmed['voice'.length] != ' ' &&
          trimmed['voice'.length] != '\t')) {
    return null;
  }

  var argument = trimmed.substring('voice'.length).trim();
  if (argument.isEmpty) {
    return null;
  }

  var inSingleQuotes = false;
  var inDoubleQuotes = false;
  var escaped = false;
  for (var i = 0; i < argument.length - 1; i++) {
    final ch = argument[i];
    if (ch == "'" && !inDoubleQuotes && !escaped) {
      inSingleQuotes = !inSingleQuotes;
    } else if (ch == '"' && !inSingleQuotes && !escaped) {
      inDoubleQuotes = !inDoubleQuotes;
    } else if (ch == '/' &&
        argument[i + 1] == '/' &&
        !inSingleQuotes &&
        !inDoubleQuotes) {
      argument = argument.substring(0, i).trimRight();
      break;
    }
    escaped = ch == '\\' && !escaped;
    if (ch != '\\') {
      escaped = false;
    }
  }

  return argument.isEmpty ? null : argument;
}

String? extractJumpTargetFromScriptLine(String line) {
  final trimmed = line.trimLeft();
  if (!trimmed.startsWith('jump') ||
      (trimmed.length > 'jump'.length &&
          trimmed['jump'.length] != ' ' &&
          trimmed['jump'.length] != '\t')) {
    return null;
  }

  final argument = trimmed.substring('jump'.length).trim();
  if (argument.isEmpty) {
    return null;
  }

  final target = argument.split(RegExp(r'[ \t]+')).first.trim();
  return target.isEmpty || target.startsWith('//') ? null : target;
}

/// Debug脚本编辑浮窗（Shift+P）
/// - 悬浮置顶
/// - 可拖拽
/// - 可调整尺寸
/// - 打开时自动将当前对话对应脚本行定位到中间
class FloatingScriptEditorOverlay extends StatefulWidget {
  final GameManager gameManager;
  final String currentScript;
  final Future<void> Function()? onReload;
  final VoidCallback onClose;
  final void Function(String message)? onNotify;

  const FloatingScriptEditorOverlay({
    super.key,
    required this.gameManager,
    required this.currentScript,
    required this.onClose,
    this.onReload,
    this.onNotify,
  });

  @override
  State<FloatingScriptEditorOverlay> createState() =>
      _FloatingScriptEditorOverlayState();
}

class _VisualLineLayout {
  final double top;
  final double height;

  const _VisualLineLayout({
    required this.top,
    required this.height,
  });
}

class _ScriptFileEntry {
  final String path;
  final String relativePath;

  const _ScriptFileEntry({
    required this.path,
    required this.relativePath,
  });

  String get fileName => p.basename(path);

  String get folder {
    final directory = p.dirname(relativePath).replaceAll('\\', '/');
    return directory == '.' ? '根目录' : directory;
  }
}

class _SksSyntaxHighlightController extends TextEditingController {
  static const Set<String> _commands = <String>{
    'label',
    'jump',
    'return',
    'menu',
    'endmenu',
    'scene',
    'movie',
    'anime',
    'show',
    'cg',
    'hide',
    'nvl',
    'endnvl',
    'nvln',
    'endnvln',
    'nvlm',
    'endnvlm',
    'fx',
    'play',
    'stop',
    'bool',
    'api',
    'pause',
    'shake',
    'voice',
  };

  static const Set<String> _keywords = <String>{
    'if',
    'at',
    'an',
    'repeat',
    'timer',
    'with',
    'loop',
    'keep',
    'duration',
    'intensity',
    'target',
    'music',
    'sound',
    'voice',
  };

  static final RegExp _numberRegex =
      RegExp(r'^[+-]?(?:\d+\.?\d*|\.\d+)$');
  static final RegExp _hexColorRegex =
      RegExp(r'^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');
  static final RegExp _identifierRegex = RegExp(r'^[A-Za-z_]\w*$');

  TextStyle? _cachedBaseStyle;
  List<String> _cachedLines = const <String>[];
  List<List<InlineSpan>> _cachedLineSpans = const <List<InlineSpan>>[];

  static const Color _commentColor = Color(0xFF6A9955);
  static const Color _commandColor = Color(0xFF569CD6);
  static const Color _keywordColor = Color(0xFFC586C0);
  static const Color _characterColor = Color(0xFF4EC9B0);
  static const Color _stringColor = Color(0xFFCE9178);
  static const Color _numberColor = Color(0xFFB5CEA8);
  static const Color _labelColor = Color(0xFFDCDCAA);
  static const Color _paramKeyColor = Color(0xFF9CDCFE);
  static const Color _boolColor = Color(0xFF569CD6);
  static const Color _hexColor = Color(0xFFD7BA7D);
  static const Color _punctuationColor = Color(0xFFD4D4D4);
  static const Color _tagColor = Color(0xFFE8AFD7);

  static bool _isWhitespace(String ch) {
    return ch == ' ' || ch == '\t' || ch == '\r';
  }

  static bool _isPunctuation(String ch) {
    return ch == '[' ||
        ch == ']' ||
        ch == '(' ||
        ch == ')' ||
        ch == ',' ||
        ch == ':' ||
        ch == '=';
  }

  static int _findCommentStartOutsideQuotes(String line) {
    var inQuotes = false;
    var escaped = false;
    for (var i = 0; i < line.length - 1; i++) {
      final ch = line[i];
      if (ch == '"' && !escaped) {
        inQuotes = !inQuotes;
      }
      if (!inQuotes && ch == '/' && line[i + 1] == '/') {
        return i;
      }
      escaped = ch == '\\' && !escaped;
      if (ch != '\\') {
        escaped = false;
      }
    }
    return -1;
  }

  static int _consumeQuotedString(String line, int start) {
    var i = start + 1;
    var escaped = false;
    while (i < line.length) {
      final ch = line[i];
      if (ch == '"' && !escaped) {
        return i + 1;
      }
      if (ch == '\\' && !escaped) {
        escaped = true;
        i++;
        continue;
      }
      escaped = false;
      i++;
    }
    return line.length;
  }

  static String? _extractFirstWord(String line) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) {
      return null;
    }
    var i = 0;
    while (i < trimmed.length &&
        !_isWhitespace(trimmed[i]) &&
        !_isPunctuation(trimmed[i]) &&
        trimmed[i] != '"') {
      i++;
    }
    if (i == 0) {
      return null;
    }
    return trimmed.substring(0, i).toLowerCase();
  }

  TextStyle _applyColor(TextStyle baseStyle, Color color) {
    return baseStyle.copyWith(color: color);
  }

  List<InlineSpan> _highlightCodePart(String codePart, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    final firstWordLower = _extractFirstWord(codePart);
    final isCommandLine =
        firstWordLower != null && _commands.contains(firstWordLower);
    final isDialogueLike = !isCommandLine && codePart.contains('"');
    final isMenuChoiceLike = codePart.trimLeft().startsWith('"');

    var i = 0;
    var wordIndex = 0;
    var hasSeenDialogueString = false;
    var hasStyledTrailingTag = false;
    var previousWordLower = '';

    while (i < codePart.length) {
      final ch = codePart[i];

      if (_isWhitespace(ch)) {
        final start = i;
        while (i < codePart.length && _isWhitespace(codePart[i])) {
          i++;
        }
        spans.add(TextSpan(text: codePart.substring(start, i), style: baseStyle));
        continue;
      }

      if (ch == '"') {
        final end = _consumeQuotedString(codePart, i);
        spans.add(
          TextSpan(
            text: codePart.substring(i, end),
            style: _applyColor(baseStyle, _stringColor),
          ),
        );
        i = end;
        hasSeenDialogueString = true;
        previousWordLower = '';
        continue;
      }

      if (_isPunctuation(ch)) {
        spans.add(
          TextSpan(
            text: ch,
            style: _applyColor(baseStyle, _punctuationColor),
          ),
        );
        i++;
        previousWordLower = '';
        continue;
      }

      final start = i;
      while (i < codePart.length &&
          !_isWhitespace(codePart[i]) &&
          !_isPunctuation(codePart[i]) &&
          codePart[i] != '"') {
        i++;
      }
      final word = codePart.substring(start, i);
      final lower = word.toLowerCase();
      final nextIsAssignment = i < codePart.length && codePart[i] == '=';
      TextStyle style = baseStyle;

      if (_hexColorRegex.hasMatch(word)) {
        style = _applyColor(baseStyle, _hexColor);
      } else if (_numberRegex.hasMatch(word)) {
        style = _applyColor(baseStyle, _numberColor);
      } else if (lower == 'true' || lower == 'false') {
        style = _applyColor(baseStyle, _boolColor);
      } else if (!isCommandLine &&
          wordIndex == 0 &&
          _identifierRegex.hasMatch(word) &&
          i < codePart.length &&
          codePart[i] == ':') {
        style = _applyColor(baseStyle, _labelColor);
      } else if (wordIndex == 0 && isCommandLine) {
        style = _applyColor(baseStyle, _commandColor);
      } else if (_keywords.contains(lower)) {
        style = _applyColor(baseStyle, _keywordColor);
      } else if (isCommandLine && firstWordLower == 'label' && wordIndex == 1) {
        style = _applyColor(baseStyle, _labelColor);
      } else if (isCommandLine && firstWordLower == 'jump' && wordIndex == 1) {
        style = _applyColor(baseStyle, _labelColor);
      } else if (isCommandLine && firstWordLower == 'api' && wordIndex == 1) {
        style = _applyColor(baseStyle, _labelColor);
      } else if (isCommandLine &&
          (firstWordLower == 'show' ||
              firstWordLower == 'cg' ||
              firstWordLower == 'hide') &&
          wordIndex == 1) {
        style = _applyColor(baseStyle, _characterColor);
      } else if (isDialogueLike && wordIndex == 0 && !isMenuChoiceLike) {
        style = _applyColor(baseStyle, _characterColor);
      } else if ((firstWordLower == 'api' && nextIsAssignment) ||
          (previousWordLower == 'if' && _identifierRegex.hasMatch(word))) {
        style = _applyColor(baseStyle, _paramKeyColor);
      } else if (hasSeenDialogueString &&
          !hasStyledTrailingTag &&
          _identifierRegex.hasMatch(word) &&
          lower != 'if') {
        style = _applyColor(
          baseStyle,
          isMenuChoiceLike ? _labelColor : _tagColor,
        );
        hasStyledTrailingTag = true;
      }

      spans.add(TextSpan(text: word, style: style));
      wordIndex++;
      previousWordLower = lower;
    }

    return spans;
  }

  List<InlineSpan> _highlightLine(String line, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    final commentIndex = _findCommentStartOutsideQuotes(line);
    final codePart = commentIndex >= 0 ? line.substring(0, commentIndex) : line;
    final commentPart = commentIndex >= 0 ? line.substring(commentIndex) : '';

    spans.addAll(_highlightCodePart(codePart, baseStyle));

    if (commentPart.isNotEmpty) {
      spans.add(
        TextSpan(
          text: commentPart,
          style: _applyColor(baseStyle, _commentColor),
        ),
      );
    }
    return spans;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? const TextStyle();
    final lines = text.split('\n');
    final reusableLineSpans = List<List<InlineSpan>?>.filled(
      lines.length,
      null,
    );

    if (_cachedBaseStyle == baseStyle) {
      var prefixLength = 0;
      while (prefixLength < lines.length &&
          prefixLength < _cachedLines.length &&
          lines[prefixLength] == _cachedLines[prefixLength]) {
        reusableLineSpans[prefixLength] =
            _cachedLineSpans[prefixLength];
        prefixLength++;
      }

      var suffixLength = 0;
      while (suffixLength < lines.length - prefixLength &&
          suffixLength < _cachedLines.length - prefixLength &&
          lines[lines.length - 1 - suffixLength] ==
              _cachedLines[_cachedLines.length - 1 - suffixLength]) {
        reusableLineSpans[lines.length - 1 - suffixLength] =
            _cachedLineSpans[_cachedLineSpans.length - 1 - suffixLength];
        suffixLength++;
      }
    }

    final highlightedLines = <List<InlineSpan>>[];
    for (var i = 0; i < lines.length; i++) {
      highlightedLines.add(
        reusableLineSpans[i] ?? _highlightLine(lines[i], baseStyle),
      );
    }

    _cachedBaseStyle = baseStyle;
    _cachedLines = lines;
    _cachedLineSpans = highlightedLines;

    final children = <InlineSpan>[];

    for (var i = 0; i < lines.length; i++) {
      children.addAll(highlightedLines[i]);
      if (i < lines.length - 1) {
        children.add(TextSpan(text: '\n', style: baseStyle));
      }
    }

    return TextSpan(style: baseStyle, children: children);
  }
}

class _FloatingScriptEditorOverlayState
    extends State<FloatingScriptEditorOverlay> {
  final _SksSyntaxHighlightController _scriptController =
      _SksSyntaxHighlightController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _fileListScrollController = ScrollController();
  Timer? _editorRefreshDebounce;

  String _currentScriptPath = '';
  bool _isLoading = true;
  bool _isDirty = false;
  bool _showFilePanel = true;
  bool _isLoadingScriptFiles = true;
  String? _scriptFilesError;
  String _scriptRootPath = '';
  List<_ScriptFileEntry> _scriptFiles = const <_ScriptFileEntry>[];
  final Set<String> _expandedScriptFolders = <String>{
    'labels',
    'configs',
    '根目录',
  };

  bool _rectInitialized = false;
  double _windowLeft = 96;
  double _windowTop = 72;
  double _windowWidth = 960;
  double _windowHeight = 640;

  static const double _minWidth = 500;
  static const double _minHeight = 340;
  static const double _lineHeightMultiplier = 1.5;
  static const double _editorFontSize = 14.0;
  static const double _gutterWidth = 84.0;
  bool _hasPreviewedVoice = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeEditor());
  }

  Future<void> _initializeEditor() async {
    await _loadCurrentScriptAndCenter();
    if (mounted) {
      await _refreshScriptFiles();
    }
  }

  @override
  void dispose() {
    if (_hasPreviewedVoice) {
      unawaited(MusicManager().stopVoice());
    }
    _editorRefreshDebounce?.cancel();
    _scriptController.dispose();
    _scrollController.dispose();
    _fileListScrollController.dispose();
    super.dispose();
  }

  void _notify(String message) {
    widget.onNotify?.call(message);
  }

  double _filePanelWidth(double uiScale) {
    return (210 * uiScale).clamp(160.0, _windowWidth * 0.42).toDouble();
  }

  double _collapsedFilePanelWidth(double uiScale) => 32 * uiScale;

  double _editorPaneWidth(double uiScale) {
    final occupiedWidth = _showFilePanel
        ? _filePanelWidth(uiScale)
        : _collapsedFilePanelWidth(uiScale);
    return _windowWidth - occupiedWidth - 1;
  }

  bool _isCurrentDialogueScriptPath(String path) {
    if (path.isEmpty) {
      return false;
    }
    final currentName = p.basenameWithoutExtension(path);
    final sourceName = widget.gameManager.currentDialogueSourceScriptFile;
    if (sourceName != null && sourceName.isNotEmpty) {
      return currentName == p.basenameWithoutExtension(sourceName);
    }
    return currentName ==
        p.basenameWithoutExtension(widget.gameManager.currentScriptFile);
  }

  Future<void> _refreshScriptFiles() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoadingScriptFiles = true;
      _scriptFilesError = null;
    });

    try {
      final gamePath = await GamePathResolver.resolveGamePath();
      if (gamePath == null || gamePath.isEmpty) {
        throw const FileSystemException('找不到游戏项目目录');
      }

      final scriptRoots = <Directory>[];
      for (final directoryName
          in GameScriptLocalization.candidateDirectories()) {
        final directory = Directory(p.join(gamePath, directoryName));
        if (await directory.exists()) {
          scriptRoots.add(directory);
        }
      }
      if (scriptRoots.isEmpty) {
        throw FileSystemException('找不到 GameScript 目录', gamePath);
      }

      Directory scriptRoot = scriptRoots.first;
      if (_currentScriptPath.isNotEmpty) {
        for (final candidate in scriptRoots) {
          if (p.isWithin(candidate.path, _currentScriptPath)) {
            scriptRoot = candidate;
            break;
          }
        }
      }

      final entries = <_ScriptFileEntry>[];
      await for (final entity
          in scriptRoot.list(recursive: true, followLinks: false)) {
        if (entity is! File ||
            p.extension(entity.path).toLowerCase() != '.sks') {
          continue;
        }
        entries.add(
          _ScriptFileEntry(
            path: p.normalize(entity.path),
            relativePath: p.relative(entity.path, from: scriptRoot.path),
          ),
        );
      }
      entries.sort((a, b) {
        final folderOrder = a.folder.compareTo(b.folder);
        if (folderOrder != 0) {
          return folderOrder;
        }
        return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
      });

      if (!mounted) {
        return;
      }
      setState(() {
        _scriptRootPath = scriptRoot.path;
        _scriptFiles = entries;
        _isLoadingScriptFiles = false;
        _scriptFilesError = entries.isEmpty ? '没有找到 .sks 文件' : null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scriptFiles = const <_ScriptFileEntry>[];
        _isLoadingScriptFiles = false;
        _scriptFilesError = e.toString();
      });
    }
  }

  Future<bool> _confirmDiscardChangesBeforeSwitch(
    _ScriptFileEntry entry,
  ) async {
    if (!_isDirty) {
      return true;
    }
    final config = SakiEngineConfig();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: config.themeColors.background,
          title: Text(
            '当前文件尚未保存',
            style: TextStyle(color: config.themeColors.primary),
          ),
          content: Text(
            '切换到 ${entry.fileName} 会放弃当前修改。',
            style: TextStyle(color: config.themeColors.onSurface),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('放弃修改并切换'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _selectScriptFile(_ScriptFileEntry entry) async {
    if (_isLoading || p.equals(entry.path, _currentScriptPath)) {
      return;
    }
    if (!await _confirmDiscardChangesBeforeSwitch(entry) || !mounted) {
      return;
    }

    setState(() {
      _isLoading = true;
    });
    try {
      final content = await File(entry.path).readAsString();
      if (!mounted) {
        return;
      }
      _scriptController.value = TextEditingValue(
        text: content,
        selection: const TextSelection.collapsed(offset: 0),
      );
      setState(() {
        _currentScriptPath = entry.path;
        _isDirty = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          return;
        }
        if (_isCurrentDialogueScriptPath(entry.path)) {
          _centerCurrentDialogueInEditor();
        } else {
          _scrollController.jumpTo(0);
        }
      });
      _notify('已切换到 ${entry.relativePath}');
    } catch (e) {
      _notify('读取脚本失败: $e');
      if (kEngineDebugMode) {
        print('浮窗脚本编辑器: 读取 ${entry.path} 失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _previewVoice(String rawVoiceFile) async {
    final assetPath = MusicManager.buildVoiceAssetPath(rawVoiceFile);
    if (assetPath.isEmpty) {
      _notify('语音路径为空，无法预览');
      return;
    }

    try {
      final musicManager = MusicManager();
      await musicManager.initialize();
      if (!musicManager.isSoundEnabled) {
        _notify('音效已关闭，请先开启音效后再预览语音');
        return;
      }
      await musicManager.playVoice(assetPath);
      _hasPreviewedVoice = true;
      _notify('语音预览: ${p.basename(assetPath)}');
    } catch (e) {
      _notify('语音预览失败: $e');
      if (kEngineDebugMode) {
        print('浮窗脚本编辑器: 语音预览失败: $assetPath, error=$e');
      }
    }
  }

  Future<void> _jumpToScriptLabel(String targetLabel) async {
    if (!widget.gameManager.hasLabel(targetLabel)) {
      _notify('未找到标签 $targetLabel，请先保存并重载脚本');
      return;
    }

    try {
      await widget.gameManager.jumpToLabel(targetLabel);
      if (!mounted) {
        return;
      }

      final destinationScript =
          widget.gameManager.currentDialogueSourceScriptFile;
      final loadedScript = _currentScriptPath.isEmpty
          ? null
          : p.basenameWithoutExtension(_currentScriptPath);
      if (!_isDirty &&
          destinationScript != null &&
          destinationScript.isNotEmpty &&
          destinationScript != loadedScript) {
        await _loadCurrentScriptAndCenter();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _centerCurrentDialogueInEditor();
          }
        });
      }

      if (_isDirty && destinationScript != loadedScript) {
        _notify('已跳转到 $targetLabel；当前脚本有未保存修改，未切换编辑文件');
      } else {
        _notify('已跳转到 $targetLabel');
      }
    } catch (e) {
      _notify('跳转失败: $e');
      if (kEngineDebugMode) {
        print('浮窗脚本编辑器: 跳转失败: $targetLabel, error=$e');
      }
    }
  }

  void _onScriptTextChanged(String _) {
    _isDirty = true;
    _editorRefreshDebounce?.cancel();
    _editorRefreshDebounce = Timer(const Duration(milliseconds: 120), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _ensureInitialRect(Size size) {
    if (_rectInitialized) {
      return;
    }
    _rectInitialized = true;
    _windowWidth = (size.width * 0.58).clamp(_minWidth, size.width - 32);
    _windowHeight = (size.height * 0.68).clamp(_minHeight, size.height - 32);
    _windowLeft = (size.width - _windowWidth) / 2;
    _windowTop = (size.height - _windowHeight) / 2;
  }

  void _clampRect(Size size) {
    final maxLeft = (size.width - _windowWidth).clamp(0.0, double.infinity);
    final maxTop = (size.height - _windowHeight).clamp(0.0, double.infinity);
    _windowLeft = _windowLeft.clamp(0.0, maxLeft);
    _windowTop = _windowTop.clamp(0.0, maxTop);
  }

  Future<void> _loadCurrentScriptAndCenter() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = true;
    });

    try {
      final preferredScriptFile =
          widget.gameManager.currentDialogueSourceScriptFile;
      final candidateScriptNames = <String>[
        if (preferredScriptFile != null && preferredScriptFile.isNotEmpty)
          preferredScriptFile,
        widget.gameManager.currentScriptFile,
        widget.currentScript,
      ].toSet().toList();

      String? matchedScriptPath;
      for (final scriptName in candidateScriptNames) {
        matchedScriptPath =
            await ScriptContentModifier.getCurrentScriptFilePath(scriptName);
        if (matchedScriptPath != null) {
          break;
        }
      }

      if (matchedScriptPath == null) {
        _scriptController.text =
            '// 未找到当前脚本文件\n// 已尝试: ${candidateScriptNames.join(', ')}';
        _currentScriptPath = '';
        return;
      }

      final file = File(matchedScriptPath);
      final content = await file.readAsString();
      _scriptController.text = content;
      _currentScriptPath = matchedScriptPath;
      _isDirty = false;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerCurrentDialogueInEditor();
      });
    } catch (e) {
      _scriptController.text = '// 读取脚本失败: $e';
      _currentScriptPath = '';
      _isDirty = false;
      if (kEngineDebugMode) {
        print('浮窗脚本编辑器: 加载脚本失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  int _findLineByDialogueText(List<String> lines, String dialogueText) {
    final target = dialogueText.trim();
    if (target.isEmpty) {
      return -1;
    }

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.contains('"')) {
        continue;
      }
      final quoteStart = line.indexOf('"');
      final quoteEnd = line.lastIndexOf('"');
      if (quoteStart < 0 || quoteEnd <= quoteStart) {
        continue;
      }
      final lineDialogue = line.substring(quoteStart + 1, quoteEnd);
      if (lineDialogue.contains(target) || target.contains(lineDialogue)) {
        return i;
      }
    }

    return -1;
  }

  int _findLineByPartialText(List<String> lines, String dialogueText) {
    final target = dialogueText.trim();
    if (target.length < 4) {
      return -1;
    }
    final half = target.substring(0, (target.length / 2).round());
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].contains(half)) {
        return i;
      }
    }
    return -1;
  }

  List<_VisualLineLayout> _computeVisualLineLayouts({
    required String text,
    required TextStyle textStyle,
    required double maxTextWidth,
  }) {
    final lines = text.split('\n');
    if (lines.isEmpty || maxTextWidth <= 0) {
      return const <_VisualLineLayout>[];
    }

    final layouts = <_VisualLineLayout>[];
    var top = 0.0;
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
      textScaler: MediaQuery.textScalerOf(context),
    );

    for (final line in lines) {
      final measurable = line.isEmpty ? ' ' : line;
      painter.text = TextSpan(text: measurable, style: textStyle);
      painter.layout(maxWidth: maxTextWidth);

      final height = painter.height;
      layouts.add(_VisualLineLayout(top: top, height: height));
      top += height;
    }

    return layouts;
  }

  int _resolveTargetLine(List<String> lines, {bool verbose = false}) {
    if (_currentScriptPath.isNotEmpty &&
        !_isCurrentDialogueScriptPath(_currentScriptPath)) {
      return -1;
    }
    int targetLine = -1;
    final sourceLine = widget.gameManager.currentDialogueSourceLine;
    if (sourceLine != null && sourceLine >= 1 && sourceLine <= lines.length) {
      targetLine = sourceLine - 1;
      if (verbose && kEngineDebugMode) {
        print('浮窗脚本编辑器: 使用sourceLine定位，line=$sourceLine');
      }
      return targetLine;
    }

    final currentDialogue = widget.gameManager.currentDialogueText;
    targetLine = _findLineByDialogueText(lines, currentDialogue);
    if (targetLine < 0) {
      targetLine = _findLineByPartialText(lines, currentDialogue);
    }
    if (verbose && kEngineDebugMode) {
      print('浮窗脚本编辑器: 回退文本定位，line=$targetLine');
    }
    return targetLine;
  }

  void _centerCurrentDialogueInEditor() {
    if (!_scrollController.hasClients) {
      return;
    }
    final lines = _scriptController.text.split('\n');
    if (lines.isEmpty) {
      return;
    }
    final targetLine = _resolveTargetLine(lines, verbose: true);
    if (targetLine < 0) {
      return;
    }

    final textScale = context.scaleFor(ComponentType.text);
    final uiScale = context.scaleFor(ComponentType.ui);
    final textStyle = TextStyle(
      fontSize: _editorFontSize * textScale,
      fontFamily: 'Courier New',
      height: _lineHeightMultiplier,
      letterSpacing: 0.4,
    );

    final lineNumberWidth = _gutterWidth * uiScale;
    final horizontalPadding = 12 * uiScale;
    final availableWidth =
        (_editorPaneWidth(uiScale) -
                lineNumberWidth -
                horizontalPadding * 2)
            .clamp(120.0, double.infinity);

    final layouts = _computeVisualLineLayouts(
      text: _scriptController.text,
      textStyle: textStyle,
      maxTextWidth: availableWidth,
    );
    if (targetLine < 0 || targetLine >= layouts.length) {
      return;
    }

    final viewport = _scrollController.position.viewportDimension;
    final targetLayout = layouts[targetLine];
    final centeredOffset =
        targetLayout.top + targetLayout.height / 2 - viewport / 2;
    final targetOffset = centeredOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _saveScript({required bool reloadAfterSave}) async {
    if (_currentScriptPath.isEmpty) {
      _notify('未加载脚本文件，无法保存');
      return;
    }

    try {
      final file = File(_currentScriptPath);
      if (!await file.exists()) {
        throw FileSystemException('目标脚本不存在', _currentScriptPath);
      }
      await _atomicWriteScript(file, _scriptController.text);
      if (mounted) {
        setState(() {
          _isDirty = false;
        });
      } else {
        _isDirty = false;
      }
      _notify('脚本已保存: ${p.basename(_currentScriptPath)}');

      if (reloadAfterSave && widget.onReload != null) {
        await widget.onReload!();
        _notify('重载完成');
      }
    } catch (e) {
      _notify('保存失败: $e');
      if (kEngineDebugMode) {
        print('浮窗脚本编辑器: 保存失败: $e');
      }
    }
  }

  Future<void> _atomicWriteScript(File targetFile, String content) async {
    final tmpPath =
        '${targetFile.path}.tmp_${DateTime.now().microsecondsSinceEpoch}';
    final tmpFile = File(tmpPath);
    Object? atomicError;

    try {
      await tmpFile.writeAsString(content, flush: true);
      await tmpFile.rename(targetFile.path);
      return;
    } catch (e) {
      atomicError = e;
      if (kEngineDebugMode) {
        print('浮窗脚本编辑器: 原子写入失败，尝试回退: $e');
      }
    }

    try {
      if (await tmpFile.exists()) {
        await tmpFile.copy(targetFile.path);
        await tmpFile.delete();
        return;
      }
      await targetFile.writeAsString(content, flush: true);
      return;
    } catch (fallbackError) {
      final message =
          '原子写入失败: $atomicError; 回退失败: $fallbackError; path=${targetFile.path}';
      throw FileSystemException(message, targetFile.path);
    } finally {
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    }
  }

  Widget _buildLineAction(
    String sourceLine,
    double uiScale,
    double lineHeight,
  ) {
    final voiceFile = extractVoiceFileFromScriptLine(sourceLine);
    if (voiceFile != null) {
      return Tooltip(
        message: '播放语音',
        child: InkWell(
          onTap: () => unawaited(_previewVoice(voiceFile)),
          borderRadius: BorderRadius.circular(4 * uiScale),
          child: SizedBox(
            width: 24 * uiScale,
            height: lineHeight,
            child: Icon(
              Icons.play_arrow_rounded,
              size: 17 * uiScale,
              color: Colors.lightGreenAccent.shade400,
            ),
          ),
        ),
      );
    }

    final jumpTarget = extractJumpTargetFromScriptLine(sourceLine);
    if (jumpTarget != null) {
      return Tooltip(
        message: '跳转到 $jumpTarget',
        child: InkWell(
          onTap: () => unawaited(_jumpToScriptLabel(jumpTarget)),
          borderRadius: BorderRadius.circular(4 * uiScale),
          child: SizedBox(
            width: 24 * uiScale,
            height: lineHeight,
            child: Icon(
              Icons.subdirectory_arrow_right_rounded,
              size: 17 * uiScale,
              color: Colors.lightBlueAccent.shade200,
            ),
          ),
        ),
      );
    }

    return SizedBox(width: 24 * uiScale);
  }

  Widget _buildLineNumbers(
    double uiScale,
    double textScale,
    List<_VisualLineLayout> lineLayouts,
    List<String> sourceLines,
    int highlightedLineIndex,
  ) {
    return Container(
      width: _gutterWidth * uiScale,
      padding: EdgeInsets.symmetric(
        vertical: 12 * uiScale,
        horizontal: 8 * uiScale,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF252526),
        border: Border(
          right: BorderSide(color: Color(0xFF3E3E42), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < lineLayouts.length; i++)
            Container(
              height: lineLayouts[i].height,
              alignment: Alignment.centerRight,
              padding: EdgeInsets.only(right: 2 * uiScale),
              decoration: i == highlightedLineIndex
                  ? BoxDecoration(
                      color: const Color(0xFFAB20A1).withOpacity(0.16),
                      border: const Border(
                        left: BorderSide(
                          color: Color(0xFFAB20A1),
                          width: 2,
                        ),
                      ),
                    )
                  : null,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (i < sourceLines.length)
                    _buildLineAction(
                      sourceLines[i],
                      uiScale,
                      lineLayouts[i].height,
                    )
                  else
                    SizedBox(width: 24 * uiScale),
                  SizedBox(width: 4 * uiScale),
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i == highlightedLineIndex
                          ? const Color(0xFFE9A6E2)
                          : const Color(0xFF858585),
                      fontSize: 12 * textScale,
                      fontFamily: 'Courier New',
                      height: _lineHeightMultiplier,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScriptFilePanel(
    SakiEngineConfig config,
    double uiScale,
    double textScale,
  ) {
    final groupedFiles = <String, List<_ScriptFileEntry>>{};
    for (final entry in _scriptFiles) {
      groupedFiles.putIfAbsent(entry.folder, () => <_ScriptFileEntry>[]).add(
            entry,
          );
    }

    final listChildren = <Widget>[];
    for (final group in groupedFiles.entries) {
      final isExpanded = _expandedScriptFolders.contains(group.key);
      listChildren.add(
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedScriptFolders.remove(group.key);
              } else {
                _expandedScriptFolders.add(group.key);
              }
            });
          },
          child: SizedBox(
            height: 30 * uiScale,
            child: Row(
              children: [
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 17 * uiScale,
                  color: config.themeColors.primary.withOpacity(0.85),
                ),
                Icon(
                  isExpanded
                      ? Icons.folder_open_outlined
                      : Icons.folder_outlined,
                  size: 16 * uiScale,
                  color: Colors.amber.shade300,
                ),
                SizedBox(width: 5 * uiScale),
                Expanded(
                  child: Text(
                    group.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: config.themeColors.onSurface.withOpacity(0.9),
                      fontSize: 11.5 * textScale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (!isExpanded) {
        continue;
      }
      for (final entry in group.value) {
        final isSelected = p.equals(entry.path, _currentScriptPath);
        listChildren.add(
          Tooltip(
            message: entry.relativePath,
            waitDuration: const Duration(milliseconds: 450),
            child: Material(
              color: isSelected
                  ? config.themeColors.primary.withOpacity(0.2)
                  : Colors.transparent,
              child: InkWell(
                onTap: _isLoading
                    ? null
                    : () => unawaited(_selectScriptFile(entry)),
                child: Container(
                  height: 29 * uiScale,
                  padding: EdgeInsets.only(
                    left: 24 * uiScale,
                    right: 6 * uiScale,
                  ),
                  decoration: isSelected
                      ? BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: config.themeColors.primary,
                              width: 2 * uiScale,
                            ),
                          ),
                        )
                      : null,
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 15 * uiScale,
                        color: isSelected
                            ? config.themeColors.primary
                            : const Color(0xFF9CDCFE),
                      ),
                      SizedBox(width: 6 * uiScale),
                      Expanded(
                        child: Text(
                          '${entry.fileName}${isSelected && _isDirty ? ' •' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? config.themeColors.primary
                                : config.themeColors.onSurface.withOpacity(0.82),
                            fontSize: 11 * textScale,
                            fontFamily: 'Courier New',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    return Container(
      width: _filePanelWidth(uiScale),
      color: const Color(0xFF202021),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34 * uiScale,
            padding: EdgeInsets.only(left: 9 * uiScale, right: 3 * uiScale),
            decoration: const BoxDecoration(
              color: Color(0xFF252526),
              border: Border(
                bottom: BorderSide(color: Color(0xFF3E3E42)),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 16 * uiScale,
                  color: config.themeColors.primary,
                ),
                SizedBox(width: 6 * uiScale),
                Expanded(
                  child: Text(
                    _scriptRootPath.isEmpty
                        ? 'SKS 文件'
                        : p.basename(_scriptRootPath),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: config.themeColors.onSurface.withOpacity(0.9),
                      fontSize: 11 * textScale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新文件列表',
                  onPressed: _isLoadingScriptFiles
                      ? null
                      : () => unawaited(_refreshScriptFiles()),
                  icon: const Icon(Icons.refresh_rounded),
                  iconSize: 15 * uiScale,
                  visualDensity: VisualDensity.compact,
                  color: config.themeColors.primary,
                ),
                IconButton(
                  tooltip: '隐藏文件栏',
                  onPressed: () {
                    setState(() {
                      _showFilePanel = false;
                    });
                  },
                  icon: const Icon(Icons.chevron_left_rounded),
                  iconSize: 17 * uiScale,
                  visualDensity: VisualDensity.compact,
                  color: config.themeColors.primary,
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoadingScriptFiles
                ? Center(
                    child: SizedBox(
                      width: 20 * uiScale,
                      height: 20 * uiScale,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _scriptFilesError != null
                    ? Padding(
                        padding: EdgeInsets.all(10 * uiScale),
                        child: Text(
                          _scriptFilesError!,
                          style: TextStyle(
                            color: Colors.orange.shade300,
                            fontSize: 10.5 * textScale,
                          ),
                        ),
                      )
                    : Scrollbar(
                        controller: _fileListScrollController,
                        thumbVisibility: true,
                        interactive: true,
                        child: ListView(
                          controller: _fileListScrollController,
                          padding: EdgeInsets.symmetric(
                            vertical: 4 * uiScale,
                          ),
                          children: listChildren,
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsedFilePanelHandle(
    SakiEngineConfig config,
    double uiScale,
  ) {
    return Container(
      width: _collapsedFilePanelWidth(uiScale),
      color: const Color(0xFF252526),
      alignment: Alignment.topCenter,
      child: Tooltip(
        message: '展开文件栏',
        child: InkWell(
          onTap: () {
            setState(() {
              _showFilePanel = true;
            });
            if (_scriptFiles.isEmpty && !_isLoadingScriptFiles) {
              unawaited(_refreshScriptFiles());
            }
          },
          child: SizedBox(
            width: _collapsedFilePanelWidth(uiScale),
            height: 42 * uiScale,
            child: Icon(
              Icons.keyboard_double_arrow_right_rounded,
              size: 21 * uiScale,
              color: config.themeColors.primary,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final config = SakiEngineConfig();
    final uiScale = context.scaleFor(ComponentType.ui);
    final textScale = context.scaleFor(ComponentType.text);
    final editorTextStyle = TextStyle(
      color: const Color(0xFFD4D4D4),
      fontSize: _editorFontSize * textScale,
      fontFamily: 'Courier New',
      height: _lineHeightMultiplier,
      letterSpacing: 0.4,
    );

    _ensureInitialRect(screenSize);
    _windowWidth = _windowWidth.clamp(_minWidth, screenSize.width);
    _windowHeight = _windowHeight.clamp(_minHeight, screenSize.height);
    _clampRect(screenSize);

    final lineNumberWidth = _gutterWidth * uiScale;
    final editorPadding = 12 * uiScale;
    final editorTextMaxWidth =
        (_editorPaneWidth(uiScale) - lineNumberWidth - editorPadding * 2).clamp(
      120.0,
      double.infinity,
    );
    final sourceLines = _scriptController.text.split('\n');
    final lineLayouts = _computeVisualLineLayouts(
      text: _scriptController.text,
      textStyle: editorTextStyle,
      maxTextWidth: editorTextMaxWidth,
    );
    final highlightedLineIndex = _resolveTargetLine(sourceLines);
    final hasHighlight = highlightedLineIndex >= 0 &&
        highlightedLineIndex < lineLayouts.length;
    final highlightTop =
        hasHighlight ? lineLayouts[highlightedLineIndex].top : 0.0;
    final highlightHeight =
        hasHighlight ? lineLayouts[highlightedLineIndex].height : 0.0;

    return Positioned(
      left: _windowLeft,
      top: _windowTop,
      width: _windowWidth,
      height: _windowHeight,
      child: Material(
        elevation: 30,
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: config.themeColors.background.withOpacity(0.96),
            borderRadius: BorderRadius.circular(config.baseWindowBorder),
            border: Border.all(
              color: config.themeColors.primary.withOpacity(0.55),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(config.baseWindowBorder),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      onPanUpdate: (details) {
                        setState(() {
                          _windowLeft += details.delta.dx;
                          _windowTop += details.delta.dy;
                          _clampRect(screenSize);
                        });
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10 * uiScale,
                          vertical: 8 * uiScale,
                        ),
                        color: config.themeColors.primary.withOpacity(0.16),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip:
                                  _showFilePanel ? '隐藏文件栏' : '展开文件栏',
                              onPressed: () {
                                final shouldShow = !_showFilePanel;
                                setState(() {
                                  _showFilePanel = shouldShow;
                                });
                                if (shouldShow &&
                                    _scriptFiles.isEmpty &&
                                    !_isLoadingScriptFiles) {
                                  unawaited(_refreshScriptFiles());
                                }
                              },
                              icon: Icon(
                                _showFilePanel
                                    ? Icons.folder_open_outlined
                                    : Icons.folder_outlined,
                              ),
                              visualDensity: VisualDensity.compact,
                              color: config.themeColors.primary,
                            ),
                            Expanded(
                              child: Text(
                                '脚本编辑浮窗 (Shift+P)',
                                style: config.reviewTitleTextStyle.copyWith(
                                  fontSize:
                                      config.reviewTitleTextStyle.fontSize! *
                                          textScale *
                                          0.62,
                                  color: config.themeColors.primary,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '定位当前句',
                              onPressed: _centerCurrentDialogueInEditor,
                              icon: const Icon(Icons.center_focus_strong),
                              visualDensity: VisualDensity.compact,
                              color: config.themeColors.primary,
                            ),
                            IconButton(
                              tooltip: '保存',
                              onPressed: () =>
                                  _saveScript(reloadAfterSave: false),
                              icon: const Icon(Icons.save_alt),
                              visualDensity: VisualDensity.compact,
                              color: Colors.green.shade500,
                            ),
                            IconButton(
                              tooltip: '保存并重载',
                              onPressed: () =>
                                  _saveScript(reloadAfterSave: true),
                              icon: const Icon(Icons.refresh),
                              visualDensity: VisualDensity.compact,
                              color: Colors.lightBlue.shade400,
                            ),
                            IconButton(
                              tooltip: '关闭',
                              onPressed: widget.onClose,
                              icon: const Icon(Icons.close),
                              visualDensity: VisualDensity.compact,
                              color: config.themeColors.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10 * uiScale,
                        vertical: 6 * uiScale,
                      ),
                      color: Colors.black.withOpacity(0.2),
                      child: Text(
                        _currentScriptPath.isNotEmpty
                            ? '${_isDirty ? '● ' : ''}$_currentScriptPath'
                            : '未加载脚本文件',
                        style: TextStyle(
                          color: config.themeColors.primary.withOpacity(0.86),
                          fontSize: 11 * textScale,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          if (_showFilePanel)
                            _buildScriptFilePanel(
                              config,
                              uiScale,
                              textScale,
                            )
                          else
                            _buildCollapsedFilePanelHandle(config, uiScale),
                          const VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: Color(0xFF3E3E42),
                          ),
                          Expanded(
                            child: _isLoading
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : Container(
                              color: const Color(0xFF1E1E1E),
                              child: ScrollbarTheme(
                                data: ScrollbarThemeData(
                                  thumbColor:
                                      WidgetStateProperty.resolveWith((states) {
                                    if (states.contains(WidgetState.dragged)) {
                                      return config.themeColors.primary;
                                    }
                                    if (states.contains(WidgetState.hovered)) {
                                      return config.themeColors.primary
                                          .withOpacity(0.86);
                                    }
                                    return config.themeColors.primary
                                        .withOpacity(0.62);
                                  }),
                                  trackColor: WidgetStateProperty.all(
                                    Colors.black.withOpacity(0.32),
                                  ),
                                  trackBorderColor: WidgetStateProperty.all(
                                    config.themeColors.primary.withOpacity(0.2),
                                  ),
                                  thickness:
                                      WidgetStateProperty.resolveWith((states) {
                                    return (states.contains(WidgetState.dragged)
                                            ? 11
                                            : 9) *
                                        uiScale;
                                  }),
                                  radius: Radius.circular(5 * uiScale),
                                  crossAxisMargin: 3 * uiScale,
                                  mainAxisMargin: 6 * uiScale,
                                  minThumbLength: 40 * uiScale,
                                  interactive: true,
                                ),
                                child: Scrollbar(
                                  controller: _scrollController,
                                  thumbVisibility: true,
                                  trackVisibility: true,
                                  interactive: true,
                                  child: SingleChildScrollView(
                                    controller: _scrollController,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _buildLineNumbers(
                                          uiScale,
                                          textScale,
                                          lineLayouts,
                                          sourceLines,
                                          highlightedLineIndex,
                                        ),
                                        Expanded(
                                          child: Stack(
                                            children: [
                                              if (hasHighlight)
                                                Positioned(
                                                  left: 0,
                                                  right: 0,
                                                  top: highlightTop +
                                                      editorPadding,
                                                  height: highlightHeight,
                                                  child: IgnorePointer(
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        color: const Color(
                                                          0xFFAB20A1,
                                                        ).withOpacity(0.12),
                                                        border: const Border(
                                                          left: BorderSide(
                                                            color: Color(
                                                              0xFFAB20A1,
                                                            ),
                                                            width: 3,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              TextField(
                                                controller: _scriptController,
                                                maxLines: null,
                                                keyboardType:
                                                    TextInputType.multiline,
                                                style: editorTextStyle,
                                                decoration: InputDecoration(
                                                  border: InputBorder.none,
                                                  contentPadding: EdgeInsets.all(
                                                    editorPadding,
                                                  ),
                                                  hintText: '脚本内容...',
                                                  hintStyle: TextStyle(
                                                    color: const Color(
                                                      0xFF6A9955,
                                                    ),
                                                    fontSize: _editorFontSize *
                                                        textScale,
                                                    fontFamily: 'Courier New',
                                                  ),
                                                  isDense: true,
                                                ),
                                                onChanged: _onScriptTextChanged,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeUpLeftDownRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          final maxWidth = (screenSize.width - _windowLeft)
                              .clamp(_minWidth, screenSize.width);
                          final maxHeight = (screenSize.height - _windowTop)
                              .clamp(_minHeight, screenSize.height);
                          _windowWidth = (_windowWidth + details.delta.dx)
                              .clamp(_minWidth, maxWidth);
                          _windowHeight = (_windowHeight + details.delta.dy)
                              .clamp(_minHeight, maxHeight);
                        });
                      },
                      child: Container(
                        width: 22 * uiScale,
                        height: 22 * uiScale,
                        alignment: Alignment.bottomRight,
                        padding: EdgeInsets.only(
                          right: 5 * uiScale,
                          bottom: 5 * uiScale,
                        ),
                        child: Icon(
                          Icons.drag_handle,
                          size: 14 * uiScale,
                          color: config.themeColors.primary.withOpacity(0.75),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
