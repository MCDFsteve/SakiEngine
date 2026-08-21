import 'dart:async';
import 'dart:io';
import 'package:sakiengine/src/config/game_path_resolver.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sakiengine/src/game/game_script_localization.dart';
import 'package:sakiengine/src/localization/script_text_localizer.dart';

/// 按键序列检测器
/// 用于检测特定按键序列，如连续按下 c-o-n-s-o-l-e
class KeySequenceDetector {
  final List<LogicalKeyboardKey> _targetSequence;
  final VoidCallback _onSequenceComplete;
  final Duration _sequenceTimeout;
  final bool Function()? _shouldIgnore;

  bool _isListening = false;
  List<LogicalKeyboardKey> _currentSequence = [];
  Timer? _timeoutTimer;

  KeySequenceDetector({
    required List<LogicalKeyboardKey> sequence,
    required VoidCallback onSequenceComplete,
    Duration sequenceTimeout = const Duration(seconds: 3),
    bool Function()? shouldIgnore,
  }) : _targetSequence = sequence,
       _onSequenceComplete = onSequenceComplete,
       _sequenceTimeout = sequenceTimeout,
       _shouldIgnore = shouldIgnore;

  /// 开始监听键盘事件
  void startListening() {
    if (_isListening) return;

    _isListening = true;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    if (kEngineDebugMode) {
      final sequenceNames = _targetSequence
          .map((key) => key.debugName)
          .join('-');
      print('按键序列检测器: 开始监听序列 $sequenceNames');
    }
  }

  /// 停止监听键盘事件
  void stopListening() {
    if (!_isListening) return;

    _isListening = false;
    _cancelTimeoutTimer();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _currentSequence.clear();

    if (kEngineDebugMode) {
      print('按键序列检测器: 停止监听');
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!_isListening) return false;

    if (_shouldIgnore?.call() ?? false) {
      if (_currentSequence.isNotEmpty) {
        _resetSequence();
      }
      return false;
    }

    // 文字序列只接受无修饰键输入，不与系统编辑或开发快捷键竞争。
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      if (_currentSequence.isNotEmpty) {
        _resetSequence();
      }
      return false;
    }

    if (event is KeyDownEvent) {
      final key = event.logicalKey;

      // 检查是否是序列中的下一个键
      if (_currentSequence.length < _targetSequence.length &&
          key == _targetSequence[_currentSequence.length]) {
        _currentSequence.add(key);
        _resetTimeout();

        if (kEngineDebugMode) {
          print(
            '按键序列检测器: 按键 ${key.debugName} 匹配，当前序列长度: ${_currentSequence.length}/${_targetSequence.length}',
          );
        }

        // 检查序列是否完成
        if (_currentSequence.length == _targetSequence.length) {
          if (kEngineDebugMode) {
            print('按键序列检测器: 序列完成！');
          }
          _onSequenceComplete();
          _resetSequence();
          return false;
        }

        // 序列检测器只旁路观察，不能阻断文本输入。
        return false;
      } else {
        // 按键不匹配，重置序列
        if (_currentSequence.isNotEmpty) {
          if (kEngineDebugMode) {
            print('按键序列检测器: 按键 ${key.debugName} 不匹配，重置序列');
          }
          _resetSequence();
        }
      }
    }

    return false;
  }

  void _resetTimeout() {
    _cancelTimeoutTimer();
    _timeoutTimer = Timer(_sequenceTimeout, () {
      if (kEngineDebugMode) {
        print('按键序列检测器: 序列超时，重置');
      }
      _resetSequence();
    });
  }

  void _cancelTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void _resetSequence() {
    _currentSequence.clear();
    _cancelTimeoutTimer();
  }

  void dispose() {
    stopListening();
  }
}

/// 长按键检测器
/// 用于检测特定按键的长按操作，如长按C键
class LongPressKeyDetector {
  final LogicalKeyboardKey _targetKey;
  final VoidCallback _onLongPress;
  final Duration _longPressDuration;

  bool _isListening = false;
  bool _isKeyPressed = false;
  Timer? _longPressTimer;

  LongPressKeyDetector({
    required LogicalKeyboardKey key,
    required VoidCallback onLongPress,
    Duration longPressDuration = const Duration(milliseconds: 800),
  }) : _targetKey = key,
       _onLongPress = onLongPress,
       _longPressDuration = longPressDuration;

  /// 开始监听键盘事件
  void startListening() {
    if (_isListening) return;

    _isListening = true;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    if (kEngineDebugMode) {
      print('长按键检测器: 开始监听 ${_targetKey.debugName} 长按事件');
    }
  }

  /// 停止监听键盘事件
  void stopListening() {
    if (!_isListening) return;

    _isListening = false;
    _cancelLongPressTimer();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _isKeyPressed = false;

    if (kEngineDebugMode) {
      print('长按键检测器: 停止监听');
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!_isListening) return false;

    if (event.logicalKey == _targetKey) {
      if (event is KeyDownEvent) {
        // 按键按下
        if (!_isKeyPressed) {
          _isKeyPressed = true;
          _startLongPressTimer();

          if (kEngineDebugMode) {
            print('长按键检测器: ${_targetKey.debugName} 按下，开始计时');
          }
        }
        return true;
      } else if (event is KeyUpEvent) {
        // 按键松开
        if (_isKeyPressed) {
          _isKeyPressed = false;
          _cancelLongPressTimer();

          if (kEngineDebugMode) {
            print('长按键检测器: ${_targetKey.debugName} 松开，取消计时');
          }
        }
        return true;
      }
    }

    return false;
  }

  void _startLongPressTimer() {
    _cancelLongPressTimer();
    _longPressTimer = Timer(_longPressDuration, () {
      if (_isKeyPressed && _isListening) {
        if (kEngineDebugMode) {
          print('长按键检测器: ${_targetKey.debugName} 长按触发');
        }
        _onLongPress();
      }
    });
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void dispose() {
    stopListening();
  }
}

/// 脚本内容修改器
/// 负责修改脚本文件中的对话行，添加或更新角色差分信息
class ScriptContentModifier {
  static const String narratorCharacterId = '__narrator__';

  static bool _isNarratorCharacterId(String? characterId) {
    if (characterId == null) {
      return true;
    }
    final normalized = characterId.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    return normalized == narratorCharacterId || normalized == 'narrator';
  }

  static String _normalizeDialogueText(String text) {
    final localized = ScriptTextLocalizer.resolve(text);
    return localized
        .replaceAll('"', '')
        .replaceAll('「', '')
        .replaceAll('」', '')
        .trim();
  }

  static bool _lineHasTargetDialogue(String line, String targetDialogue) {
    final trimmedLine = line.trim();
    final quoteStart = trimmedLine.indexOf('"');
    final quoteEnd = trimmedLine.lastIndexOf('"');
    if (quoteStart >= 0 && quoteEnd > quoteStart) {
      final dialogueContent = trimmedLine.substring(quoteStart + 1, quoteEnd);
      return _normalizeDialogueText(dialogueContent) ==
          _normalizeDialogueText(targetDialogue);
    }
    return false;
  }

  static bool _lineStartsWithCharacterToken(String line) {
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || trimmed.startsWith('"')) {
      return false;
    }
    final quoteIndex = trimmed.indexOf('"');
    if (quoteIndex <= 0) {
      return false;
    }
    final beforeQuote = trimmed.substring(0, quoteIndex).trimRight();
    if (beforeQuote.isEmpty) {
      return false;
    }
    final token = beforeQuote.split(RegExp(r'\s+')).first;
    return token.isNotEmpty;
  }

  static List<String> _tailTokensFromNarrationLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('"')) {
      return const [];
    }
    final quoteEnd = trimmed.lastIndexOf('"');
    if (quoteEnd <= 0 || quoteEnd >= trimmed.length - 1) {
      return const [];
    }
    final tail = trimmed.substring(quoteEnd + 1).trim();
    if (tail.isEmpty) {
      return const [];
    }
    return tail.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  static bool _isNarrationTailLineForCharacter(
    String line,
    String? expectedCharacterId,
  ) {
    final tokens = _tailTokensFromNarrationLine(line);
    if (tokens.isEmpty) {
      return false;
    }
    if (_isNarratorCharacterId(expectedCharacterId)) {
      return true;
    }
    if (_isCharacterIdCompatible(
      lineCharacterId: tokens.first,
      expectedCharacterId: expectedCharacterId,
    )) {
      return true;
    }
    if (tokens.length >= 2 &&
        _isCharacterIdCompatible(
          lineCharacterId: tokens[1],
          expectedCharacterId: expectedCharacterId,
        )) {
      return true;
    }
    return false;
  }

  static String _modifyNarrationTailLine(
    String line,
    String characterId,
    String? newPose,
    String? newExpression, {
    String? writeCharacterId,
    bool updateAnimation = false,
    String? newAnimation,
  }) {
    final trimmed = line.trim();
    final quoteEnd = trimmed.lastIndexOf('"');
    if (quoteEnd <= 0) {
      return line;
    }
    final quoted = trimmed.substring(0, quoteEnd + 1);
    final tokens = _tailTokensFromNarrationLine(trimmed);
    final desiredCharacterId =
        (writeCharacterId == null || writeCharacterId.trim().isEmpty)
        ? characterId
        : writeCharacterId.trim();
    final wantsNarration = _isNarratorCharacterId(desiredCharacterId);

    if (tokens.isEmpty) {
      if (wantsNarration) {
        return line;
      }
      final pose = newPose ?? 'pose1';
      final expression = newExpression ?? 'normal';
      final nextTail = <String>[desiredCharacterId, pose, expression];
      final animation = newAnimation?.trim();
      if (updateAnimation && animation != null && animation.isNotEmpty) {
        nextTail
          ..add('an')
          ..add(animation);
      }
      return '$quoted ${nextTail.join(' ')}';
    }

    int aliasIndex = -1;
    if (!wantsNarration) {
      if (_isCharacterIdCompatible(
        lineCharacterId: tokens.first,
        expectedCharacterId: characterId,
      )) {
        aliasIndex = 0;
      } else if (tokens.length >= 2 &&
          _isCharacterIdCompatible(
            lineCharacterId: tokens[1],
            expectedCharacterId: characterId,
          )) {
        // 兼容： "..." tag alias ...
        aliasIndex = 1;
      }
    }

    if (aliasIndex < 0) {
      // 兼容：只有 dialogueTag 的行（例如 "..." fuzu），补全角色尾语法。
      if (!wantsNarration && tokens.length == 1) {
        final nextPose = newPose ?? 'pose1';
        final nextExpression = newExpression ?? 'normal';
        final nextTail = <String>[
          tokens.first,
          desiredCharacterId,
          nextPose,
          nextExpression,
        ];
        final animation = newAnimation?.trim();
        if (updateAnimation && animation != null && animation.isNotEmpty) {
          nextTail
            ..add('an')
            ..add(animation);
        }
        return '$quoted ${nextTail.join(' ')}';
      }
      return line;
    }

    final leadingTokens = tokens.sublist(0, aliasIndex);
    final alias = desiredCharacterId;
    final rest = tokens.sublist(aliasIndex + 1);
    String? animation;
    String? repeatRaw;
    final baseTokens = <String>[];
    for (var i = 0; i < rest.length; i++) {
      final token = rest[i];
      final lower = token.toLowerCase();
      if (lower == 'an' && i + 1 < rest.length) {
        animation = rest[i + 1];
        i++;
        continue;
      }
      if (lower == 'repeat' && i + 1 < rest.length) {
        repeatRaw = rest[i + 1];
        i++;
        continue;
      }
      baseTokens.add(token);
    }

    String? pose;
    String? expression;
    final extraTokens = <String>[];
    if (baseTokens.isNotEmpty) {
      if (baseTokens.length == 1) {
        if (baseTokens[0].toLowerCase().startsWith('pose')) {
          pose = baseTokens[0];
        } else {
          expression = baseTokens[0];
        }
      } else {
        pose = baseTokens[0];
        expression = baseTokens[1];
        if (baseTokens.length > 2) {
          extraTokens.addAll(baseTokens.sublist(2));
        }
      }
    }

    final nextPose = newPose ?? pose;
    final nextExpression = newExpression ?? expression;
    final nextTail = <String>[...leadingTokens];
    nextTail.add(alias);
    if (nextPose != null && nextPose.isNotEmpty) {
      nextTail.add(nextPose);
    }
    if (nextExpression != null && nextExpression.isNotEmpty) {
      nextTail.add(nextExpression);
    }
    if (extraTokens.isNotEmpty) {
      nextTail.addAll(extraTokens);
    }
    final nextAnimation = updateAnimation ? newAnimation?.trim() : animation;
    if (nextAnimation != null && nextAnimation.isNotEmpty) {
      nextTail
        ..add('an')
        ..add(nextAnimation);
    }
    if (nextAnimation != null &&
        nextAnimation.isNotEmpty &&
        repeatRaw != null &&
        repeatRaw.isNotEmpty) {
      nextTail
        ..add('repeat')
        ..add(repeatRaw);
    }

    return '$quoted ${nextTail.join(' ')}';
  }

  /// 修改脚本文件中的对话行，添加差分信息
  ///
  /// [scriptFilePath] 脚本文件的完整路径
  /// [targetDialogue] 目标对话文本
  /// [characterId] 角色ID
  /// [newExpression] 新的表情差分
  static Future<bool> modifyDialogueLine({
    required String scriptFilePath,
    required String targetDialogue,
    required String characterId,
    required String newExpression,
  }) async {
    try {
      final file = File(scriptFilePath);
      if (!await file.exists()) {
        if (kEngineDebugMode) {
          print('脚本修改器: 文件不存在 $scriptFilePath');
        }
        return false;
      }

      final content = await file.readAsString();
      final lines = content.split('\n');
      bool modified = false;

      for (int i = 0; i < lines.length; i++) {
        final originalLine = lines[i];
        final line = originalLine.trim();

        // 检查是否是包含目标对话的行，同时验证角色ID
        if (_isTargetDialogueLine(line, targetDialogue, characterId)) {
          final modifiedLine = _modifyDialogueLine(
            line,
            characterId,
            null,
            newExpression,
          );
          if (modifiedLine != line) {
            lines[i] = originalLine.replaceFirst(line, modifiedLine);
            modified = true;

            if (kEngineDebugMode) {
              print('脚本修改器: 修改对话行');
              print('原始行: $line');
              print('修改后: $modifiedLine');
            }
            break; // 只修改第一个匹配的行
          }
        }
      }

      if (modified) {
        final modifiedContent = lines.join('\n');
        await _writeScriptFile(file, modifiedContent);

        if (kEngineDebugMode) {
          print('脚本修改器: 成功保存修改的脚本文件');
        }
        return true;
      } else {
        if (kEngineDebugMode) {
          print('脚本修改器: 未找到匹配的对话行');
        }
        return false;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('脚本修改器: 修改脚本文件失败: $e');
      }
      return false;
    }
  }

  /// 检查是否是目标对话行
  static bool _isTargetDialogueLine(
    String line,
    String targetDialogue, [
    String? expectedCharacterId,
  ]) {
    // 去除前后空白
    final trimmedLine = line.trim();
    final trimmedDialogue = targetDialogue.trim();

    if (kEngineDebugMode && line.contains(targetDialogue.replaceAll('"', ''))) {
      print('ScriptModifier: 检查行匹配');
      print('ScriptModifier: 行内容: "$trimmedLine"');
      print('ScriptModifier: 目标对话: "$trimmedDialogue"');
      print('ScriptModifier: 期望角色ID: $expectedCharacterId');
    }

    final expectsNarration = _isNarratorCharacterId(expectedCharacterId);

    // 检查不同的对话格式
    // 格式1: "对话内容" - 只有在没有指定expectedCharacterId时才匹配
    if (trimmedLine.startsWith('"')) {
      final quoteEnd = trimmedLine.lastIndexOf('"');
      if (quoteEnd > 0) {
        final dialogueContent = trimmedLine.substring(1, quoteEnd);
        if (_normalizeDialogueText(dialogueContent) ==
            _normalizeDialogueText(trimmedDialogue)) {
          if (_isNarratorCharacterId(expectedCharacterId)) {
            if (kEngineDebugMode) {
              final hasTail = quoteEnd < trimmedLine.length - 1;
              print(
                hasTail
                    ? 'ScriptModifier: 匹配格式1b（旁白+尾语法）'
                    : 'ScriptModifier: 匹配格式1（纯对话）',
              );
            }
            return true;
          }
          if (_isNarrationTailLineForCharacter(
            trimmedLine,
            expectedCharacterId,
          )) {
            if (kEngineDebugMode) {
              print('ScriptModifier: 匹配格式1c（尾语法角色对话）');
            }
            return true;
          }
          if (kEngineDebugMode) {
            print('ScriptModifier: 匹配格式1d（纯旁白，允许补尾语法）');
          }
          return true;
        }
      }
    }

    // 格式2: character "对话内容"
    // 格式3: character expression "对话内容"
    if (trimmedLine.contains('"') && !trimmedLine.startsWith('"')) {
      final parts = trimmedLine.split(' ');
      if (parts.isNotEmpty) {
        final lineCharacterId = parts[0];

        if (kEngineDebugMode &&
            line.contains(targetDialogue.replaceAll('"', ''))) {
          print('ScriptModifier: 行角色ID: "$lineCharacterId"');
        }

        // 如果指定了expectedCharacterId，必须匹配
        if (expectsNarration) {
          if (kEngineDebugMode &&
              line.contains(targetDialogue.replaceAll('"', ''))) {
            print('ScriptModifier: 期望旁白行，但命中角色行，跳过');
          }
          return false;
        }

        if (!_isCharacterIdCompatible(
          lineCharacterId: lineCharacterId,
          expectedCharacterId: expectedCharacterId,
        )) {
          if (kEngineDebugMode &&
              line.contains(targetDialogue.replaceAll('"', ''))) {
            print(
              'ScriptModifier: 角色ID不匹配: "$lineCharacterId" !~ "$expectedCharacterId"',
            );
          }
          return false;
        }

        final quoteStart = trimmedLine.indexOf('"');
        final quoteEnd = trimmedLine.lastIndexOf('"');
        if (quoteStart >= 0 && quoteEnd > quoteStart) {
          final dialogueContent = trimmedLine.substring(
            quoteStart + 1,
            quoteEnd,
          );
          if (kEngineDebugMode &&
              line.contains(targetDialogue.replaceAll('"', ''))) {
            print('ScriptModifier: 提取的对话内容: "$dialogueContent"');
            print(
              'ScriptModifier: 标准化后的对话内容: "${_normalizeDialogueText(dialogueContent)}"',
            );
            print(
              'ScriptModifier: 标准化后的目标对话: "${_normalizeDialogueText(trimmedDialogue)}"',
            );
            print(
              'ScriptModifier: 是否匹配: ${_normalizeDialogueText(dialogueContent) == _normalizeDialogueText(trimmedDialogue)}',
            );
          }

          // 使用标准化后的文本进行比较
          if (_normalizeDialogueText(dialogueContent) ==
              _normalizeDialogueText(trimmedDialogue)) {
            if (kEngineDebugMode) {
              print('ScriptModifier: 匹配格式2/3（角色+对话）');
            }
            return true;
          }
        }
      }
    }

    return false;
  }

  /// 角色ID兼容匹配：
  /// - 完全相等
  /// - expected 作为前缀，后缀首字符为字母或下划线（例如 q3 -> q3r / q3_alt）
  static bool _isCharacterIdCompatible({
    required String lineCharacterId,
    String? expectedCharacterId,
  }) {
    if (expectedCharacterId == null || expectedCharacterId.isEmpty) {
      return true;
    }
    if (lineCharacterId == expectedCharacterId) {
      return true;
    }
    if (!lineCharacterId.startsWith(expectedCharacterId)) {
      return false;
    }
    if (lineCharacterId.length == expectedCharacterId.length) {
      return true;
    }
    final nextChar = lineCharacterId[expectedCharacterId.length];
    return RegExp(r'[A-Za-z_]').hasMatch(nextChar);
  }

  /// 修改对话行，添加或更新pose和表情信息
  static String _modifyDialogueLine(
    String line,
    String characterId,
    String? newPose,
    String? newExpression, {
    String? writeCharacterId,
    bool updateAnimation = false,
    String? newAnimation,
  }) {
    final trimmedLine = line.trim();
    final wantsNarration = _isNarratorCharacterId(characterId);
    final desiredCharacterId =
        (writeCharacterId == null || writeCharacterId.trim().isEmpty)
        ? characterId
        : writeCharacterId.trim();
    final parts = trimmedLine.split(' ');
    final lineCharacterId =
        trimmedLine.contains('"') &&
            !trimmedLine.startsWith('"') &&
            parts.isNotEmpty
        ? parts[0]
        : null;
    final effectiveWriteCharacterId =
        (lineCharacterId != null &&
            _isCharacterIdCompatible(
              lineCharacterId: lineCharacterId,
              expectedCharacterId: characterId,
            ))
        ? lineCharacterId
        : desiredCharacterId;

    ({
      String? pose,
      String? expression,
      String? position,
      String? animation,
      String? repeatRaw,
    })
    parseCharacterPrefixAttrs(List<String> attrs) {
      final baseTokens = <String>[];
      String? position;
      String? animation;
      String? repeatRaw;

      var i = 0;
      while (i < attrs.length) {
        final token = attrs[i];
        final lower = token.toLowerCase();
        if (lower == 'at' && i + 1 < attrs.length) {
          position = attrs[i + 1];
          i += 2;
          continue;
        }
        if (lower == 'an' && i + 1 < attrs.length) {
          animation = attrs[i + 1];
          i += 2;
          continue;
        }
        if (lower == 'repeat' && i + 1 < attrs.length) {
          repeatRaw = attrs[i + 1];
          i += 2;
          continue;
        }
        baseTokens.add(token);
        i++;
      }

      String? pose;
      String? expression;
      if (baseTokens.isNotEmpty) {
        var lastPoseIndex = -1;
        for (var j = 0; j < baseTokens.length; j++) {
          if (baseTokens[j].toLowerCase().startsWith('pose')) {
            lastPoseIndex = j;
          }
        }

        if (lastPoseIndex >= 0) {
          pose = baseTokens[lastPoseIndex];
          if (lastPoseIndex + 1 < baseTokens.length) {
            expression = baseTokens[lastPoseIndex + 1];
          } else if (lastPoseIndex > 0) {
            expression = baseTokens[lastPoseIndex - 1];
          }
        } else if (baseTokens.length == 1) {
          expression = baseTokens[0];
        } else {
          pose = baseTokens[0];
          expression = baseTokens[1];
        }
      }

      return (
        pose: pose,
        expression: expression,
        position: position,
        animation: animation,
        repeatRaw: repeatRaw,
      );
    }

    // 如果已经包含该角色的信息，更新它
    if (lineCharacterId != null &&
        _isCharacterIdCompatible(
          lineCharacterId: lineCharacterId,
          expectedCharacterId: characterId,
        )) {
      final quoteIndex = trimmedLine.indexOf('"');
      if (quoteIndex > 0) {
        final beforeQuote = trimmedLine.substring(0, quoteIndex).trimRight();
        final quotedPart = trimmedLine.substring(quoteIndex);
        final prefixTokens = beforeQuote
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList();
        final parsed = parseCharacterPrefixAttrs(
          prefixTokens.length > 1 ? prefixTokens.sublist(1) : const [],
        );

        final pose = (newPose ?? parsed.pose ?? 'pose1').trim();
        final expression = (newExpression ?? parsed.expression ?? 'normal')
            .trim();
        final rebuiltPrefix = <String>[effectiveWriteCharacterId];
        if (pose.isNotEmpty) {
          rebuiltPrefix.add(pose);
        }
        if (expression.isNotEmpty) {
          rebuiltPrefix.add(expression);
        }
        if (parsed.position != null && parsed.position!.trim().isNotEmpty) {
          rebuiltPrefix
            ..add('at')
            ..add(parsed.position!.trim());
        }
        final nextAnimation = updateAnimation
            ? newAnimation?.trim()
            : parsed.animation?.trim();
        if (nextAnimation != null && nextAnimation.isNotEmpty) {
          rebuiltPrefix
            ..add('an')
            ..add(nextAnimation);
        }
        if (nextAnimation != null &&
            nextAnimation.isNotEmpty &&
            parsed.repeatRaw != null &&
            parsed.repeatRaw!.trim().isNotEmpty) {
          rebuiltPrefix
            ..add('repeat')
            ..add(parsed.repeatRaw!.trim());
        }
        return '${rebuiltPrefix.join(' ')} $quotedPart';
      }
    }

    // 如果是纯对话格式，添加角色、pose和表情信息
    if (trimmedLine.startsWith('"')) {
      final modifiedNarrationTail = _modifyNarrationTailLine(
        trimmedLine,
        characterId,
        newPose,
        newExpression,
        writeCharacterId: effectiveWriteCharacterId,
        updateAnimation: updateAnimation,
        newAnimation: newAnimation,
      );
      if (modifiedNarrationTail != line &&
          modifiedNarrationTail != trimmedLine) {
        return modifiedNarrationTail;
      }
      return trimmedLine;
    }

    // 其他情况，尝试智能添加
    if (trimmedLine.contains('"')) {
      final quoteIndex = trimmedLine.indexOf('"');
      final pose = newPose ?? 'pose1';
      final expression = newExpression ?? 'normal';
      return '${trimmedLine.substring(0, quoteIndex)}$effectiveWriteCharacterId $pose $expression ${trimmedLine.substring(quoteIndex)}';
    }

    // 如果无法识别格式，返回原始行
    return line;
  }

  static String _replaceLeadingCharacterId(
    String line,
    String? oldCharacterId,
    String newCharacterId,
  ) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return line;
    }

    final wantsNarration = _isNarratorCharacterId(newCharacterId);
    final oldIsNarration = _isNarratorCharacterId(oldCharacterId);
    final hasCharacterPrefix = _lineStartsWithCharacterToken(trimmed);
    final quoteIndex = trimmed.indexOf('"');
    if (quoteIndex < 0) {
      return line;
    }

    if (!hasCharacterPrefix) {
      if (wantsNarration) {
        return line;
      }
      final insertPrefix = '$newCharacterId ';
      return '$insertPrefix$trimmed';
    }

    if (quoteIndex <= 0) {
      return line;
    }

    final beforeQuote = trimmed.substring(0, quoteIndex).trimRight();
    final tokens = beforeQuote.split(RegExp(r'\s+'));
    if (tokens.isEmpty) {
      return line;
    }
    final lineCharacterId = tokens.first;

    if (!oldIsNarration &&
        !_isCharacterIdCompatible(
          lineCharacterId: lineCharacterId,
          expectedCharacterId: oldCharacterId,
        )) {
      return line;
    }

    if (wantsNarration) {
      return trimmed.substring(quoteIndex);
    }
    final replacedPrefix = beforeQuote.replaceFirst(
      lineCharacterId,
      newCharacterId,
    );
    return '$replacedPrefix ${trimmed.substring(quoteIndex)}';
  }

  static String _modifySceneOrMovieBackground(
    String line,
    String newBackground,
  ) {
    final trimmed = line.trim();
    final prefix = trimmed.startsWith('scene ') ? 'scene ' : 'movie ';
    if (!trimmed.startsWith(prefix)) {
      return line;
    }

    final params = trimmed.substring(prefix.length).trim();
    if (params.isEmpty) {
      return '$prefix$newBackground';
    }

    final tokens = params.split(RegExp(r'\s+'));
    final keywordSet = {'timer', 'with', 'an', 'repeat', 'fx'};
    int keywordIndex = -1;
    for (int i = 0; i < tokens.length; i++) {
      if (keywordSet.contains(tokens[i])) {
        keywordIndex = i;
        break;
      }
    }

    final tail = keywordIndex >= 0
        ? tokens.sublist(keywordIndex).join(' ')
        : '';
    if (tail.isEmpty) {
      return '$prefix$newBackground';
    }
    return '$prefix$newBackground $tail';
  }

  static bool _isSceneOrMovieLine(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('scene ') || trimmed.startsWith('movie ');
  }

  static bool _isPlayMusicLine(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('play music ');
  }

  static bool _isStopMusicLine(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith('stop music');
  }

  /// 修改指定对话行的pose和表情信息
  /// 支持同时修改pose和expression
  static Future<bool> modifyDialogueLineWithPose({
    required String scriptFilePath,
    required String targetDialogue,
    required String characterId,
    String? writeCharacterId,
    String? newPose,
    String? newExpression,
    bool updateAnimation = false,
    String? newAnimation,
    int? targetLineNumber,
  }) async {
    try {
      if (kEngineDebugMode) {
        print('ScriptModifier: 开始修改对话行');
        print('ScriptModifier: 文件路径: $scriptFilePath');
        print('ScriptModifier: 目标对话: "$targetDialogue"');
        print('ScriptModifier: 角色ID: $characterId');
        print('ScriptModifier: 写入角色ID: $writeCharacterId');
        print('ScriptModifier: 新pose: $newPose');
        print('ScriptModifier: 新expression: $newExpression');
        print('ScriptModifier: 目标行号: $targetLineNumber');
      }

      final file = File(scriptFilePath);
      if (!await file.exists()) {
        if (kEngineDebugMode) {
          print('ScriptModifier: 文件不存在');
        }
        return false;
      }

      final content = await file.readAsString();
      final lines = content.split('\n');
      bool modified = false;

      if (kEngineDebugMode) {
        print('ScriptModifier: 读取到 ${lines.length} 行脚本');
      }

      final alternateCharacterId = writeCharacterId?.trim();

      String? matchingCharacterId(String line) {
        if (_isTargetDialogueLine(line, targetDialogue, characterId)) {
          return characterId;
        }
        if (alternateCharacterId != null &&
            alternateCharacterId.isNotEmpty &&
            alternateCharacterId != characterId &&
            _isTargetDialogueLine(line, targetDialogue, alternateCharacterId)) {
          return alternateCharacterId;
        }
        return null;
      }

      if (targetLineNumber != null && targetLineNumber > 0) {
        final targetIndex = targetLineNumber - 1;
        if (targetIndex >= 0 && targetIndex < lines.length) {
          final originalLine = lines[targetIndex];
          final line = originalLine.trim();
          if (kEngineDebugMode) {
            print('ScriptModifier: 尝试按精确行号匹配 line=$targetLineNumber: "$line"');
          }
          final matchedCharacterId = matchingCharacterId(line);
          if (matchedCharacterId != null) {
            final modifiedLine = _modifyDialogueLine(
              line,
              matchedCharacterId,
              newPose,
              newExpression,
              writeCharacterId: writeCharacterId,
              updateAnimation: updateAnimation,
              newAnimation: newAnimation,
            );
            if (modifiedLine != line) {
              lines[targetIndex] = originalLine.replaceFirst(
                line,
                modifiedLine,
              );
              modified = true;
              if (kEngineDebugMode) {
                print('ScriptModifier: 精确行号命中并修改成功');
                print('ScriptModifier: 原始行: $line');
                print('ScriptModifier: 修改后: $modifiedLine');
              }
            } else if (kEngineDebugMode) {
              print('ScriptModifier: 精确行号命中，但内容无变化');
            }
          } else if (kEngineDebugMode) {
            print('ScriptModifier: 精确行号未通过对话/角色校验，回退到全文匹配');
          }
        } else if (kEngineDebugMode) {
          print('ScriptModifier: 精确行号越界，回退到全文匹配');
        }

        // 行号未命中时，优先在附近窗口内定位（行号漂移容错）
        if (!modified) {
          const nearbyWindow = 24;
          final searchStart = (targetIndex - nearbyWindow).clamp(
            0,
            lines.length - 1,
          );
          final searchEnd = (targetIndex + nearbyWindow).clamp(
            0,
            lines.length - 1,
          );
          if (kEngineDebugMode) {
            print('ScriptModifier: 尝试附近窗口定位 [$searchStart, $searchEnd]');
          }
          for (int i = searchStart; i <= searchEnd; i++) {
            final originalLine = lines[i];
            final line = originalLine.trim();
            final matchedCharacterId = matchingCharacterId(line);
            if (matchedCharacterId == null) {
              continue;
            }
            final modifiedLine = _modifyDialogueLine(
              line,
              matchedCharacterId,
              newPose,
              newExpression,
              writeCharacterId: writeCharacterId,
              updateAnimation: updateAnimation,
              newAnimation: newAnimation,
            );
            if (modifiedLine == line) {
              continue;
            }
            lines[i] = originalLine.replaceFirst(line, modifiedLine);
            modified = true;
            if (kEngineDebugMode) {
              print('ScriptModifier: 附近窗口命中行 ${i + 1} 并修改成功');
              print('ScriptModifier: 原始行: $line');
              print('ScriptModifier: 修改后: $modifiedLine');
            }
            break;
          }
        }
      }

      if (!modified) {
        if (kEngineDebugMode) {
          print('ScriptModifier: 开始回退全文匹配流程');
        }

        for (int i = 0; i < lines.length; i++) {
          final originalLine = lines[i];
          final line = originalLine.trim();

          // 检查是否包含对话的关键部分（不含引号和特殊符号）
          final dialogueCore = targetDialogue
              .replaceAll('"', '')
              .replaceAll('「', '')
              .replaceAll('」', '');
          if (kEngineDebugMode && line.contains(dialogueCore)) {
            print('ScriptModifier: 找到包含关键词的行 $i: "$line"');
          }

          // 检查是否是包含目标对话的行，同时验证角色ID
          final matchedCharacterId = matchingCharacterId(line);
          if (matchedCharacterId != null) {
            if (kEngineDebugMode) {
              print('ScriptModifier: 确认匹配行 $i: "$line"');
            }

            final modifiedLine = _modifyDialogueLine(
              line,
              matchedCharacterId,
              newPose,
              newExpression,
              writeCharacterId: writeCharacterId,
              updateAnimation: updateAnimation,
              newAnimation: newAnimation,
            );
            if (modifiedLine != line) {
              lines[i] = originalLine.replaceFirst(line, modifiedLine);
              modified = true;

              if (kEngineDebugMode) {
                print('ScriptModifier: 修改对话行（pose+expression）');
                print('ScriptModifier: 原始行: $line');
                print('ScriptModifier: 修改后: $modifiedLine');
              }
              break; // 只修改第一个匹配的行
            } else {
              if (kEngineDebugMode) {
                print('ScriptModifier: 修改后的行与原始行相同，无需更改');
              }
            }
          }
        }
      }

      if (modified) {
        final modifiedContent = lines.join('\n');
        await _writeScriptFile(file, modifiedContent);

        if (kEngineDebugMode) {
          print('ScriptModifier: 成功保存修改的脚本文件（pose+expression）');
        }
        return true;
      } else {
        if (kEngineDebugMode) {
          print('ScriptModifier: 未找到匹配的对话行或无需修改');
        }
      }

      return false;
    } catch (e) {
      if (kEngineDebugMode) {
        print('ScriptModifier: 修改对话行失败: $e');
      }
      return false;
    }
  }

  /// 按当前对话定位，替换角色ID但尽量保持pose/expression/文本不变
  static Future<bool> modifyDialogueCharacterWithPose({
    required String scriptFilePath,
    required String targetDialogue,
    String? oldCharacterId,
    required String newCharacterId,
    int? targetLineNumber,
  }) async {
    try {
      if (kEngineDebugMode) {
        print('ScriptModifier: 开始修改对话角色');
        print('ScriptModifier: 文件路径: $scriptFilePath');
        print('ScriptModifier: 目标对话: "$targetDialogue"');
        print('ScriptModifier: 原角色ID: $oldCharacterId');
        print('ScriptModifier: 新角色ID: $newCharacterId');
        print('ScriptModifier: 目标行号: $targetLineNumber');
      }
      final file = File(scriptFilePath);
      if (!await file.exists()) {
        if (kEngineDebugMode) {
          print('ScriptModifier: 文件不存在');
        }
        return false;
      }
      final content = await file.readAsString();
      final lines = content.split('\n');
      bool modified = false;
      final oldIsNarration = _isNarratorCharacterId(oldCharacterId);
      final newIsNarration = _isNarratorCharacterId(newCharacterId);
      final effectiveOldCharacterId = oldIsNarration ? null : oldCharacterId;

      bool canModifyCandidateLine(String line) {
        final hasDialogue = _lineHasTargetDialogue(line, targetDialogue);
        if (!hasDialogue) {
          return false;
        }
        final hasCharacter = _lineStartsWithCharacterToken(line);
        if (!hasCharacter) {
          if (newIsNarration) {
            return false;
          }
          // 旁白行转角色：不依赖 oldCharacterId，直接允许。
          return true;
        }
        if (newIsNarration) {
          if (effectiveOldCharacterId == null ||
              effectiveOldCharacterId.trim().isEmpty) {
            return true;
          }
          final quoteIndex = line.trim().indexOf('"');
          final beforeQuote = line.trim().substring(0, quoteIndex).trimRight();
          final token = beforeQuote.split(RegExp(r'\s+')).first;
          return _isCharacterIdCompatible(
            lineCharacterId: token,
            expectedCharacterId: effectiveOldCharacterId,
          );
        }

        if (effectiveOldCharacterId == null ||
            effectiveOldCharacterId.trim().isEmpty) {
          return true;
        }
        final quoteIndex = line.trim().indexOf('"');
        final beforeQuote = line.trim().substring(0, quoteIndex).trimRight();
        final token = beforeQuote.split(RegExp(r'\s+')).first;
        return _isCharacterIdCompatible(
          lineCharacterId: token,
          expectedCharacterId: effectiveOldCharacterId,
        );
      }

      bool tryModifyAtIndex(int i, {String reason = ''}) {
        if (i < 0 || i >= lines.length) {
          return false;
        }
        final originalLine = lines[i];
        final trimmedLine = originalLine.trim();
        if (!canModifyCandidateLine(trimmedLine)) {
          return false;
        }
        final changed = _replaceLeadingCharacterId(
          trimmedLine,
          effectiveOldCharacterId,
          newCharacterId,
        );
        if (changed == trimmedLine) {
          return false;
        }
        lines[i] = originalLine.replaceFirst(trimmedLine, changed);
        if (kEngineDebugMode) {
          print(
            'ScriptModifier: 角色修改命中行 ${i + 1}${reason.isNotEmpty ? ' ($reason)' : ''}',
          );
          print('ScriptModifier: 原始行: $trimmedLine');
          print('ScriptModifier: 修改后: $changed');
        }
        return true;
      }

      if (targetLineNumber != null &&
          targetLineNumber > 0 &&
          targetLineNumber <= lines.length) {
        final idx = targetLineNumber - 1;
        modified = tryModifyAtIndex(idx, reason: 'exact-line');

        if (!modified) {
          const nearbyWindow = 24;
          final start = (idx - nearbyWindow).clamp(0, lines.length - 1);
          final end = (idx + nearbyWindow).clamp(0, lines.length - 1);
          for (int i = start; i <= end; i++) {
            if (i == idx) {
              continue;
            }
            if (tryModifyAtIndex(i, reason: 'nearby-window')) {
              modified = true;
              break;
            }
          }
        }
      }

      if (!modified) {
        for (int i = 0; i < lines.length; i++) {
          if (tryModifyAtIndex(i, reason: 'full-scan')) {
            modified = true;
            break;
          }
        }
      }

      if (!modified) {
        if (kEngineDebugMode) {
          print('ScriptModifier: 未找到可修改的目标对话行（角色切换）');
        }
        return false;
      }
      await _writeScriptFile(file, lines.join('\n'));
      if (kEngineDebugMode) {
        print('ScriptModifier: 成功保存修改的脚本文件（角色切换）');
      }
      return true;
    } catch (e) {
      if (kEngineDebugMode) {
        print('ScriptModifier: 修改对话角色失败: $e');
      }
      return false;
    }
  }

  /// 以当前对话行为锚点修改背景：
  /// 1) 若目标行正上方连续命令块中存在scene/movie，则只替换该条；
  /// 2) 否则在目标行前插入新的scene命令（不会改远处旧场景行）。
  static Future<bool> modifyBackgroundNearDialogue({
    required String scriptFilePath,
    required String newBackground,
    int? targetLineNumber,
  }) async {
    try {
      final file = File(scriptFilePath);
      if (!await file.exists()) {
        return false;
      }
      final content = await file.readAsString();
      final lines = content.split('\n');
      if (lines.isEmpty) {
        return false;
      }

      final hasAnchor =
          targetLineNumber != null &&
          targetLineNumber > 0 &&
          targetLineNumber <= lines.length;
      final targetIndex = hasAnchor ? targetLineNumber - 1 : lines.length;

      int? replaceIndex;
      if (hasAnchor) {
        // 只在当前对话上方紧邻命令块中寻找可替换scene/movie，避免误改远处已有场景。
        for (int i = targetIndex - 1; i >= 0; i--) {
          final trimmed = lines[i].trim();
          if (trimmed.isEmpty) {
            continue;
          }
          if (trimmed.startsWith('//') || trimmed.startsWith('#')) {
            continue;
          }
          if (_isSceneOrMovieLine(trimmed)) {
            replaceIndex = i;
          }
          break;
        }
      }

      if (replaceIndex != null) {
        final originalLine = lines[replaceIndex];
        final changed = _modifySceneOrMovieBackground(
          originalLine.trim(),
          newBackground,
        );
        if (changed == originalLine.trim()) {
          return false;
        }
        lines[replaceIndex] = originalLine.replaceFirst(
          originalLine.trim(),
          changed,
        );
      } else {
        final insertAt = targetIndex.clamp(0, lines.length);
        lines.insert(insertAt, 'scene $newBackground');
      }

      await _writeScriptFile(file, lines.join('\n'));
      return true;
    } catch (e) {
      if (kEngineDebugMode) {
        print('ScriptModifier: 修改背景失败: $e');
      }
      return false;
    }
  }

  /// 以当前对话行为锚点修改音乐：
  /// 1) 若目标行正上方连续命令块中存在play music，则只替换该条；
  /// 2) 否则在目标行前插入新的play music（不会去改很远处旧命令）。
  static Future<bool> modifyMusicNearDialogue({
    required String scriptFilePath,
    required String newMusic,
    int? targetLineNumber,
  }) async {
    try {
      final normalized = newMusic.trim();
      if (normalized.isEmpty) {
        return false;
      }
      final file = File(scriptFilePath);
      if (!await file.exists()) {
        return false;
      }
      final content = await file.readAsString();
      final lines = content.split('\n');
      if (lines.isEmpty) {
        return false;
      }

      int targetIndex;
      if (targetLineNumber != null &&
          targetLineNumber > 0 &&
          targetLineNumber <= lines.length) {
        targetIndex = targetLineNumber - 1;
      } else {
        targetIndex = lines.length;
      }

      // 只在目标行上方紧邻命令块里查找可替换的play music。
      int? replaceIndex;
      for (int i = targetIndex - 1; i >= 0; i--) {
        final trimmed = lines[i].trim();
        if (trimmed.isEmpty) {
          continue;
        }
        if (trimmed.startsWith('//') || trimmed.startsWith('#')) {
          continue;
        }
        if (_isPlayMusicLine(trimmed)) {
          replaceIndex = i;
        }
        break;
      }

      if (replaceIndex != null) {
        final originalLine = lines[replaceIndex];
        final trimmed = originalLine.trim();
        final changed = 'play music $normalized';
        if (trimmed == changed) {
          return false;
        }
        lines[replaceIndex] = originalLine.replaceFirst(trimmed, changed);
      } else {
        final insertAt = targetIndex.clamp(0, lines.length);
        lines.insert(insertAt, 'play music $normalized');
      }

      await _writeScriptFile(file, lines.join('\n'));
      return true;
    } catch (e) {
      if (kEngineDebugMode) {
        print('ScriptModifier: 修改音乐失败: $e');
      }
      return false;
    }
  }

  /// 写入脚本文件，使用多种方法确保成功
  static Future<void> _writeScriptFile(File file, String content) async {
    bool writeSuccess = false;
    String lastError = '';

    // 方法1: 直接文件写入
    try {
      await file.writeAsString(content);
      writeSuccess = true;
      if (kEngineDebugMode) {
        print('脚本修改器: 直接文件写入成功');
      }
    } catch (e) {
      lastError = '直接写入失败: $e';
      if (kEngineDebugMode) {
        print('脚本修改器: $lastError');
      }
    }

    if (!writeSuccess) {
      // 方法2: 使用临时文件 + 移动
      try {
        final tempFile = File('${file.path}.tmp');
        await tempFile.writeAsString(content);
        await tempFile.rename(file.path);
        writeSuccess = true;
        if (kEngineDebugMode) {
          print('脚本修改器: 临时文件写入成功');
        }
      } catch (e) {
        lastError += ', 临时文件写入失败: $e';
        if (kEngineDebugMode) {
          print('脚本修改器: 临时文件写入失败: $e');
        }
      }
    }

    if (!writeSuccess) {
      // 方法3: 使用命令行
      try {
        // 转义特殊字符
        final escapedContent = content
            .replaceAll('\\', '\\\\')
            .replaceAll('\$', '\\\$')
            .replaceAll('"', '\\"');

        final result = await Process.run('sh', [
          '-c',
          'printf "%s" "\$1" > "\$2"',
          '--',
          escapedContent,
          file.path,
        ]);

        if (result.exitCode == 0) {
          writeSuccess = true;
          if (kEngineDebugMode) {
            print('脚本修改器: 命令行写入成功');
          }
        } else {
          lastError += ', 命令行写入失败: ${result.stderr}';
        }
      } catch (e) {
        lastError += ', 命令行写入异常: $e';
      }
    }

    if (!writeSuccess) {
      throw Exception('所有写入方法均失败: $lastError');
    }
  }

  /// 获取当前脚本文件路径
  static Future<String?> getCurrentScriptFilePath(String scriptName) async {
    try {
      // 获取游戏路径
      final gamePath = await _getGamePathFromAssetManager();
      if (gamePath == null) return null;

      final candidateDirs = GameScriptLocalization.candidateDirectories();
      for (final dirName in candidateDirs) {
        final scriptPath = p.join(
          gamePath,
          dirName,
          'labels',
          '$scriptName.sks',
        );
        final scriptFile = File(scriptPath);

        if (await scriptFile.exists()) {
          return scriptPath;
        }
      }

      if (kEngineDebugMode) {
        print(
          '脚本修改器: 未找到脚本文件 $scriptName.sks (尝试目录: ${candidateDirs.join(', ')})',
        );
      }
      return null;
    } catch (e) {
      if (kEngineDebugMode) {
        print('脚本修改器: 获取脚本文件路径失败: $e');
      }
      return null;
    }
  }

  /// 从AssetManager获取游戏路径
  static Future<String?> _getGamePathFromAssetManager() async {
    try {
      final gamePath = await GamePathResolver.resolveGamePath();
      if (gamePath != null && gamePath.isNotEmpty) {
        if (kEngineDebugMode) {
          print("脚本修改器: 解析到游戏路径: $gamePath");
        }
        return gamePath;
      }
    } catch (e) {
      if (kEngineDebugMode) {
        print('脚本修改器: 无法获取游戏路径: $e');
      }
    }
    return null;
  }
}
