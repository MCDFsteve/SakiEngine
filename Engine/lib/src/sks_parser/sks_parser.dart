import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_line_utils.dart';

class SksParser {
  static const bool _musicParseDiagnostics = bool.fromEnvironment(
    'SAKI_MUSIC_PARSE_DIAGNOSTICS',
    defaultValue: false,
  );

  static void _logMusicParse(String message) {
    if (_musicParseDiagnostics) {
      print('[SksParser][music] $message');
    }
  }

  static bool _isValidHexColor(String color) {
    if (!color.startsWith('#')) return false;
    final hex = color.substring(1);
    return RegExp(
      r'^([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$',
    ).hasMatch(hex);
  }

  /// 为角色对话添加引号（旁白除外）
  String _formatDialogueWithQuotes(String dialogue, String? character) {
    // 如果没有角色（旁白），直接返回原文本
    if (character == null || character.isEmpty) {
      return dialogue;
    }

    // 如果已经有引号，直接返回
    if (dialogue.startsWith('「') && dialogue.endsWith('」')) {
      return dialogue;
    }

    // 为角色对话添加引号
    return '「$dialogue」';
  }

  String? _activeSourceFile;
  int _activeSourceLine = -1;

  int _findFirstWhitespaceOutsideQuotes(String input) {
    String? quoteChar;
    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (quoteChar == null) {
        if (char == '"' || char == "'") {
          quoteChar = char;
          continue;
        }
        if (char.trim().isEmpty) {
          return i;
        }
      } else if (char == quoteChar) {
        quoteChar = null;
      }
    }
    return -1;
  }

  List<String> _splitByWhitespaceRespectingQuotes(String input) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    String? quoteChar;

    void flush() {
      if (buffer.isEmpty) {
        return;
      }
      tokens.add(buffer.toString());
      buffer.clear();
    }

    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (quoteChar == null) {
        if (char == '"' || char == "'") {
          quoteChar = char;
          buffer.write(char);
          continue;
        }
        if (char.trim().isEmpty) {
          flush();
          continue;
        }
        buffer.write(char);
      } else {
        buffer.write(char);
        if (char == quoteChar) {
          quoteChar = null;
        }
      }
    }

    flush();
    return tokens;
  }

  String _stripMatchingQuotes(String value) {
    if (value.length < 2) {
      return value;
    }
    final first = value[0];
    final last = value[value.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  String _unescapeQuotedValue(String value) {
    return value
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\"', '"')
        .replaceAll(r"\'", "'")
        .replaceAll(r'\\', '\\');
  }

  String? _extractDialogueTag(String? rawTag) {
    if (rawTag == null) {
      return null;
    }
    final tag = rawTag.trim();
    if (tag.isEmpty) {
      return null;
    }
    // 仅允许简单 token，避免和现有命令语法冲突。
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(tag)) {
      return tag;
    }
    return null;
  }

  ({
    String? dialogueTag,
    String? tailCharacter,
    String? tailPose,
    String? tailExpression,
    String? tailAnimation,
    int? tailRepeatCount,
  })
  _parseDialogueTail(String? rawTail) {
    final tail = rawTail?.trim() ?? '';
    if (tail.isEmpty) {
      return (
        dialogueTag: null,
        tailCharacter: null,
        tailPose: null,
        tailExpression: null,
        tailAnimation: null,
        tailRepeatCount: null,
      );
    }

    final tokens = tail
        .split(RegExp(r'\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (tokens.isEmpty) {
      return (
        dialogueTag: null,
        tailCharacter: null,
        tailPose: null,
        tailExpression: null,
        tailAnimation: null,
        tailRepeatCount: null,
      );
    }

    bool isToken(String value) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
    final allTokensValid = tokens.every(isToken);
    if (!allTokensValid) {
      return (
        dialogueTag: null,
        tailCharacter: null,
        tailPose: null,
        tailExpression: null,
        tailAnimation: null,
        tailRepeatCount: null,
      );
    }

    // 兼容旧语法：单token仅作为dialogueTag，避免破坏既有项目语义（如头像tag）。
    if (tokens.length == 1) {
      final tag = _extractDialogueTag(tokens[0]);
      return (
        dialogueTag: tag,
        tailCharacter: null,
        tailPose: null,
        tailExpression: null,
        tailAnimation: null,
        tailRepeatCount: null,
      );
    }

    ({
      String? tailCharacter,
      String? tailPose,
      String? tailExpression,
      String? tailAnimation,
      int? tailRepeatCount,
    })
    parseTailControl(List<String> controlTokens) {
      if (controlTokens.isEmpty) {
        return (
          tailCharacter: null,
          tailPose: null,
          tailExpression: null,
          tailAnimation: null,
          tailRepeatCount: null,
        );
      }
      final baseTokens = <String>[];
      String? tailAnimation;
      int? tailRepeatCount;

      var i = 0;
      while (i < controlTokens.length) {
        final token = controlTokens[i];
        if (token == 'repeat') {
          if (i + 1 < controlTokens.length) {
            tailRepeatCount = int.tryParse(controlTokens[i + 1]);
            i += 2;
            continue;
          }
          i++;
          continue;
        }
        if (token == 'an') {
          if (i + 1 < controlTokens.length) {
            tailAnimation = controlTokens[i + 1];
            i += 2;
            continue;
          }
          i++;
          continue;
        }
        baseTokens.add(token);
        i++;
      }

      if (baseTokens.isEmpty) {
        return (
          tailCharacter: null,
          tailPose: null,
          tailExpression: null,
          tailAnimation: tailAnimation,
          tailRepeatCount: tailRepeatCount,
        );
      }

      final tailCharacter = baseTokens[0];
      String? tailPose;
      String? tailExpression;
      final rest = baseTokens.sublist(1);

      if (rest.length == 1) {
        if (rest[0].toLowerCase().startsWith('pose')) {
          tailPose = rest[0];
        } else {
          tailExpression = rest[0];
        }
      } else if (rest.length > 1) {
        tailPose = rest[0];
        tailExpression = rest.sublist(1).join('_');
      }

      return (
        tailCharacter: tailCharacter,
        tailPose: tailPose,
        tailExpression: tailExpression,
        tailAnimation: tailAnimation,
        tailRepeatCount: tailRepeatCount,
      );
    }

    // 双 token 仅支持旧语法： "..." aru normal / "..." aru pose1
    if (tokens.length == 2) {
      final parsed = parseTailControl(tokens);
      return (
        dialogueTag: null,
        tailCharacter: parsed.tailCharacter,
        tailPose: parsed.tailPose,
        tailExpression: parsed.tailExpression,
        tailAnimation: parsed.tailAnimation,
        tailRepeatCount: parsed.tailRepeatCount,
      );
    }

    // 三个及以上 token：
    // 1) 旧语法： "..." aru pose1 normal
    // 2) 新语法： "..." sad aru normal（dialogueTag + 角色差分控制）
    final secondTokenLooksLikePose = tokens[1].toLowerCase().startsWith('pose');
    if (secondTokenLooksLikePose) {
      final parsed = parseTailControl(tokens);
      return (
        dialogueTag: null,
        tailCharacter: parsed.tailCharacter,
        tailPose: parsed.tailPose,
        tailExpression: parsed.tailExpression,
        tailAnimation: parsed.tailAnimation,
        tailRepeatCount: parsed.tailRepeatCount,
      );
    }

    final dialogueTag = _extractDialogueTag(tokens[0]);
    if (dialogueTag == null) {
      final parsed = parseTailControl(tokens);
      return (
        dialogueTag: null,
        tailCharacter: parsed.tailCharacter,
        tailPose: parsed.tailPose,
        tailExpression: parsed.tailExpression,
        tailAnimation: parsed.tailAnimation,
        tailRepeatCount: parsed.tailRepeatCount,
      );
    }

    final parsed = parseTailControl(tokens.sublist(1));
    return (
      dialogueTag: dialogueTag,
      tailCharacter: parsed.tailCharacter,
      tailPose: parsed.tailPose,
      tailExpression: parsed.tailExpression,
      tailAnimation: parsed.tailAnimation,
      tailRepeatCount: parsed.tailRepeatCount,
    );
  }

  Map<String, String> _parseApiParameters(String rawParams) {
    final params = <String, String>{};
    if (rawParams.trim().isEmpty) {
      return params;
    }

    final tokens = _splitByWhitespaceRespectingQuotes(rawParams);
    for (final token in tokens) {
      if (token.isEmpty) {
        continue;
      }
      final eqIndex = token.indexOf('=');
      if (eqIndex <= 0) {
        params[token.trim()] = 'true';
        continue;
      }
      final key = token.substring(0, eqIndex).trim();
      if (key.isEmpty) {
        continue;
      }
      final rawValue = token.substring(eqIndex + 1).trim();
      final unquoted = _stripMatchingQuotes(rawValue);
      params[key] = _unescapeQuotedValue(unquoted);
    }

    return params;
  }

  ScriptNode parse(String content, {String? sourceFile}) {
    _activeSourceFile = sourceFile;
    var sourceLineOffset = 0;
    final lines = content.split('\n');
    final nodes = <SksNode>[];
    int i = 0;
    while (i < lines.length) {
      _activeSourceLine = i + 1 - sourceLineOffset;
      final originalLine = lines[i];
      final lineWithoutComment = SksLineUtils.stripLineCommentOutsideQuotes(
        originalLine,
      );
      final trimmedLine = lineWithoutComment.trim();

      if (trimmedLine.isEmpty || trimmedLine.startsWith('//')) {
        i++;
        continue;
      }
      final sourceMarker = RegExp(
        r'^__saki_source\s+"([^"]+)"$',
      ).firstMatch(trimmedLine);
      if (sourceMarker != null) {
        _activeSourceFile = sourceMarker.group(1);
        sourceLineOffset = i + 1;
        nodes.add(CommentNode('=== 文件: ${_activeSourceFile!} ==='));
        i++;
        continue;
      }
      final sourceEndMarker = RegExp(
        r'^__saki_source_end\s+"([^"]+)"$',
      ).firstMatch(trimmedLine);
      if (sourceEndMarker != null) {
        nodes.add(CommentNode('=== 文件 ${sourceEndMarker.group(1)!} 结束 ==='));
        i++;
        continue;
      }
      final parts = trimmedLine
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      final command = parts[0];
      switch (command) {
        case 'label':
          nodes.add(LabelNode(parts[1]));
          break;
        case 'jump':
          if (parts.length == 5 && parts[2] == 'if') {
            final conditionValue = switch (parts[4].toLowerCase()) {
              'true' => true,
              'false' => false,
              _ => throw FormatException(
                'jump 条件值必须是 true 或 false：$trimmedLine',
              ),
            };
            nodes.add(
              JumpNode(
                parts[1],
                conditionVariable: parts[3],
                conditionValue: conditionValue,
              ),
            );
          } else if (parts.length == 2) {
            nodes.add(JumpNode(parts[1]));
          } else {
            throw FormatException(
              'jump 语法应为 jump <label> 或 '
              'jump <label> if <variable> <true|false>：$trimmedLine',
            );
          }
          break;
        case 'return':
          nodes.add(ReturnNode());
          break;
        case 'menu':
          final choiceNodes = <ChoiceOptionNode>[];
          i++;
          while (i < lines.length) {
            final menuLineRaw = lines[i];
            final menuLine = SksLineUtils.stripLineCommentOutsideQuotes(
              menuLineRaw,
            ).trim();
            if (menuLine.isEmpty) {
              i++;
              continue;
            }
            if (menuLine.startsWith('endmenu')) {
              break;
            }
            if (menuLine.isNotEmpty && !menuLine.startsWith('//')) {
              final choiceMatch = RegExp(
                r'"([^"]*)"\s+(\w+)',
              ).firstMatch(menuLine);
              if (choiceMatch != null) {
                final text = choiceMatch.group(1)!;
                final targetLabel = choiceMatch.group(2)!;
                choiceNodes.add(ChoiceOptionNode(text, targetLabel));
              }
            }
            i++;
          }
          nodes.add(MenuNode(choiceNodes));
          break;
        case 'endmenu':
          break;
        case 'scene':
          final allParams = parts.sublist(1);
          String backgroundName = '';
          double? timerValue;
          String? fxString;
          List<String>? layers;
          String? transitionType; // 新增：转场类型
          String? animation; // 新增：动画类型
          int? repeatCount; // 新增：重复次数

          // 检查是否为多图层语法 [layer1,layer2:params,...]
          if (allParams.isNotEmpty &&
              allParams[0].startsWith('[') &&
              allParams.join(' ').contains(']')) {
            final layerContent = allParams.join(' ');
            final startBracket = layerContent.indexOf('[');
            final endBracket = layerContent.indexOf(']');

            if (startBracket >= 0 && endBracket > startBracket) {
              final layerString = layerContent.substring(
                startBracket + 1,
                endBracket,
              );
              layers = layerString.split(',').map((s) => s.trim()).toList();

              // 第一个图层作为主背景名
              if (layers.isNotEmpty) {
                backgroundName = layers[0].split(':')[0]; // 去掉可能的位置参数
              }

              // 解析后续参数（timer, fx, with, an, repeat等）
              final remainingParams = layerContent
                  .substring(endBracket + 1)
                  .trim()
                  .split(' ')
                  .where((s) => s.isNotEmpty)
                  .toList();
              int i = 0;
              while (i < remainingParams.length) {
                if (remainingParams[i] == 'timer' &&
                    i + 1 < remainingParams.length) {
                  timerValue = double.tryParse(remainingParams[i + 1]);
                  i += 2;
                } else if (remainingParams[i] == 'with' &&
                    i + 1 < remainingParams.length) {
                  transitionType = remainingParams[i + 1];
                  i += 2;
                } else if (remainingParams[i] == 'an' &&
                    i + 1 < remainingParams.length) {
                  animation = remainingParams[i + 1];
                  i += 2;
                } else if (remainingParams[i] == 'repeat' &&
                    i + 1 < remainingParams.length) {
                  repeatCount = int.tryParse(remainingParams[i + 1]);
                  i += 2;
                } else if (remainingParams[i] == 'fx') {
                  if (i + 1 < remainingParams.length) {
                    fxString = remainingParams.sublist(i + 1).join(' ');
                  }
                  break;
                } else {
                  i++;
                }
              }
            }
          } else {
            // 单图层模式 - 改进解析逻辑
            // 首先找到所有关键字的位置
            final timerIndex = allParams.indexOf('timer');
            final withIndex = allParams.indexOf('with');
            final anIndex = allParams.indexOf('an');
            final repeatIndex = allParams.indexOf('repeat');
            final fxIndex = allParams.indexOf('fx');

            // 找到第一个关键字的位置，背景名称在这之前
            final keywordIndices = [
              timerIndex,
              withIndex,
              anIndex,
              repeatIndex,
              fxIndex,
            ].where((index) => index >= 0).toList();

            final firstKeywordIndex = keywordIndices.isEmpty
                ? allParams.length
                : keywordIndices.reduce((a, b) => a < b ? a : b);

            // 背景名称是第一个关键字之前的所有参数
            backgroundName = allParams.sublist(0, firstKeywordIndex).join(' ');

            // 解析各个参数
            int i = 0;
            while (i < allParams.length) {
              if (allParams[i] == 'timer' && i + 1 < allParams.length) {
                timerValue = double.tryParse(allParams[i + 1]);
                i += 2;
              } else if (allParams[i] == 'with' && i + 1 < allParams.length) {
                transitionType = allParams[i + 1];
                i += 2;
              } else if (allParams[i] == 'an' && i + 1 < allParams.length) {
                animation = allParams[i + 1];
                i += 2;
              } else if (allParams[i] == 'repeat' && i + 1 < allParams.length) {
                repeatCount = int.tryParse(allParams[i + 1]);
                i += 2;
              } else if (allParams[i] == 'fx') {
                if (i + 1 < allParams.length) {
                  fxString = allParams.sublist(i + 1).join(' ');
                }
                break;
              } else {
                i++;
              }
            }
          }

          // 调试输出
          //print('[SksParser] scene解析结果: background="$backgroundName", transition="$transitionType", animation="$animation", repeat=$repeatCount');

          // 检查是否为十六进制颜色格式
          if (_isValidHexColor(backgroundName.trim())) {
            nodes.add(
              BackgroundNode(
                backgroundName.trim(),
                timer: timerValue,
                layers: layers,
                transitionType: transitionType,
                animation: animation,
                repeatCount: repeatCount,
              ),
            );
          } else {
            nodes.add(
              BackgroundNode(
                backgroundName,
                timer: timerValue,
                layers: layers,
                transitionType: transitionType,
                animation: animation,
                repeatCount: repeatCount,
              ),
            );
          }

          // 如果有fx参数，添加FxNode
          if (fxString != null && fxString.isNotEmpty) {
            nodes.add(FxNode(fxString));
          }
          break;
        case 'movie':
          final allParams = parts.sublist(1);
          String movieFile = '';
          double? timerValue;
          String? fxString;
          List<String>? layers;
          String? transitionType;
          String? animation;
          int? repeatCount;

          // 检查是否为多图层语法 [layer1,layer2:params,...]
          if (allParams.isNotEmpty &&
              allParams[0].startsWith('[') &&
              allParams.join(' ').contains(']')) {
            final layerContent = allParams.join(' ');
            final startBracket = layerContent.indexOf('[');
            final endBracket = layerContent.indexOf(']');

            if (startBracket >= 0 && endBracket > startBracket) {
              final layerString = layerContent.substring(
                startBracket + 1,
                endBracket,
              );
              layers = layerString.split(',').map((s) => s.trim()).toList();

              // 第一个图层作为主视频文件名
              if (layers.isNotEmpty) {
                movieFile = layers[0].split(':')[0];
              }

              // 解析后续参数（timer, fx, with, an, repeat等）
              final remainingParams = layerContent
                  .substring(endBracket + 1)
                  .trim()
                  .split(' ')
                  .where((s) => s.isNotEmpty)
                  .toList();
              int i = 0;
              while (i < remainingParams.length) {
                if (remainingParams[i] == 'timer' &&
                    i + 1 < remainingParams.length) {
                  timerValue = double.tryParse(remainingParams[i + 1]);
                  i += 2;
                } else if (remainingParams[i] == 'with' &&
                    i + 1 < remainingParams.length) {
                  transitionType = remainingParams[i + 1];
                  i += 2;
                } else if (remainingParams[i] == 'an' &&
                    i + 1 < remainingParams.length) {
                  animation = remainingParams[i + 1];
                  i += 2;
                } else if (remainingParams[i] == 'repeat' &&
                    i + 1 < remainingParams.length) {
                  repeatCount = int.tryParse(remainingParams[i + 1]);
                  i += 2;
                } else if (remainingParams[i] == 'fx') {
                  if (i + 1 < remainingParams.length) {
                    fxString = remainingParams.sublist(i + 1).join(' ');
                  }
                  break;
                } else {
                  i++;
                }
              }
            }
          } else {
            // 单文件模式
            final timerIndex = allParams.indexOf('timer');
            final withIndex = allParams.indexOf('with');
            final anIndex = allParams.indexOf('an');
            final repeatIndex = allParams.indexOf('repeat');
            final fxIndex = allParams.indexOf('fx');

            final keywordIndices = [
              timerIndex,
              withIndex,
              anIndex,
              repeatIndex,
              fxIndex,
            ].where((index) => index >= 0).toList();

            final firstKeywordIndex = keywordIndices.isEmpty
                ? allParams.length
                : keywordIndices.reduce((a, b) => a < b ? a : b);

            // 视频文件名是第一个关键字之前的所有参数
            movieFile = allParams.sublist(0, firstKeywordIndex).join(' ');

            // 解析各个参数
            int i = 0;
            while (i < allParams.length) {
              if (allParams[i] == 'timer' && i + 1 < allParams.length) {
                timerValue = double.tryParse(allParams[i + 1]);
                i += 2;
              } else if (allParams[i] == 'with' && i + 1 < allParams.length) {
                transitionType = allParams[i + 1];
                i += 2;
              } else if (allParams[i] == 'an' && i + 1 < allParams.length) {
                animation = allParams[i + 1];
                i += 2;
              } else if (allParams[i] == 'repeat' && i + 1 < allParams.length) {
                repeatCount = int.tryParse(allParams[i + 1]);
                i += 2;
              } else if (allParams[i] == 'fx') {
                if (i + 1 < allParams.length) {
                  fxString = allParams.sublist(i + 1).join(' ');
                }
                break;
              } else {
                i++;
              }
            }
          }

          nodes.add(
            MovieNode(
              movieFile,
              timer: timerValue,
              layers: layers,
              transitionType: transitionType,
              animation: animation,
              repeatCount: repeatCount,
            ),
          );

          // 如果有fx参数，添加FxNode
          if (fxString != null && fxString.isNotEmpty) {
            nodes.add(FxNode(fxString));
          }
          break;
        case 'anime':
          // anime命令：anime cg_igiari [loop] [keep] [with diss] [timer 2.0]
          if (parts.length < 2) break;

          final animeName = parts[1];
          bool isLoop = false;
          bool keepAfterComplete = false; // 新增：是否在完成后保留
          String? transitionType;
          double? timerValue;

          // 解析参数
          for (int i = 2; i < parts.length; i++) {
            if (parts[i].toLowerCase() == 'loop') {
              isLoop = true;
            } else if (parts[i].toLowerCase() == 'keep') {
              // 新增：keep参数
              keepAfterComplete = true;
            } else if (parts[i] == 'with' && i + 1 < parts.length) {
              transitionType = parts[i + 1];
              i++; // 跳过下一个参数
            } else if (parts[i] == 'timer' && i + 1 < parts.length) {
              timerValue = double.tryParse(parts[i + 1]);
              i++; // 跳过下一个参数
            }
          }

          //print('[SksParser] 解析anime命令: $animeName, loop: $isLoop, keep: $keepAfterComplete, transition: $transitionType, timer: $timerValue');
          nodes.add(
            AnimeNode(
              animeName,
              loop: isLoop,
              keep: keepAfterComplete,
              transitionType: transitionType,
              timer: timerValue,
            ),
          );
          break;
        case 'canvas':
          // canvas命令：canvas <project-registered-id>
          if (parts.length >= 2) {
            final canvasId = parts.sublist(1).join(' ').trim();
            if (canvasId.isNotEmpty) {
              nodes.add(CanvasNode(canvasId));
            }
          }
          break;
        case 'show':
          //print('[SksParser] 解析show命令: $trimmedLine');
          final character = parts[1];

          // CG显示命令保持为ShowNode，支持叠加显示
          // 但需要特殊处理以支持WebP动图的loop参数

          String? pose;
          String? expression;
          String? position;
          String? animation;
          int? repeatCount;

          // 支持an语法和repeat语法:
          // show xiayo1 pose1 happy at pose an jump repeat 3
          // x happy an jump repeat 3

          int atIndex = -1;
          int anIndex = -1;
          int repeatIndex = -1;

          for (int i = 2; i < parts.length; i++) {
            if (parts[i] == 'at') {
              atIndex = i;
            } else if (parts[i] == 'an') {
              anIndex = i;
            } else if (parts[i] == 'repeat') {
              repeatIndex = i;
              break;
            }
          }

          // 解析repeat参数
          if (repeatIndex >= 0 && repeatIndex + 1 < parts.length) {
            repeatCount = int.tryParse(parts[repeatIndex + 1]);
          }

          int endIndex = repeatIndex >= 0 ? repeatIndex : parts.length;

          if (anIndex >= 0 && anIndex < endIndex) {
            // 有an动画语法
            if (anIndex + 1 < endIndex) {
              animation = parts[anIndex + 1];
            }

            if (atIndex >= 0 && atIndex < anIndex) {
              // show character pose1 happy at pose an jump repeat 3
              final attributeParts = parts.sublist(2, atIndex);
              if (attributeParts.isNotEmpty) {
                if (attributeParts.length == 1) {
                  // 只有一个参数时，视为expression，pose使用默认值pose1
                  expression = attributeParts[0];
                } else {
                  // 有两个或更多参数时，第一个是pose，第二个是expression
                  pose = attributeParts[0];
                  expression = attributeParts[1];
                }
              }
              if (atIndex + 1 < anIndex) {
                position = parts[atIndex + 1];
              }
            } else {
              // x happy an jump repeat 3
              final attributeParts = parts.sublist(2, anIndex);
              if (attributeParts.isNotEmpty) {
                expression = attributeParts[0];
              }
            }
          } else if (atIndex >= 0 && atIndex < endIndex) {
            // 原有at语法，无动画
            final attributeParts = parts.sublist(2, atIndex);
            if (attributeParts.isNotEmpty) {
              if (attributeParts.length == 1) {
                // 只有一个参数时，视为expression，pose使用默认值pose1
                expression = attributeParts[0];
              } else {
                // 有两个或更多参数时，第一个是pose，第二个是expression
                pose = attributeParts[0];
                expression = attributeParts[1];
              }
            }
            if (atIndex + 1 < endIndex) {
              position = parts[atIndex + 1];
            }
          } else {
            // 原有pose:语法
            for (int i = 2; i < endIndex; i++) {
              if (parts[i].startsWith('pose:')) {
                pose = parts[i].substring(5);
              } else if (parts[i].startsWith('expression:')) {
                expression = parts[i].substring(11);
              }
            }
          }

          nodes.add(
            ShowNode(
              character,
              pose: pose,
              expression: expression,
              position: position,
              animation: animation,
              repeatCount: repeatCount,
            ),
          );
          break;
        case 'cg':
          //print('[SksParser] 解析cg命令: $trimmedLine');
          final character = parts[1];

          // CG显示命令，支持与show相同的参数，但渲染方式像scene一样铺满

          String? pose;
          String? expression;
          String? position;
          String? transitionType;
          String? animation;
          int? repeatCount;

          // 支持an语法和repeat语法:
          // cg xiayo1 pose1 happy at pose an jump repeat 3
          // cg x happy an jump repeat 3

          var firstModifierIndex = parts.length;
          var hasPositionModifier = false;
          var hasAnimationModifier = false;
          for (int i = 2; i < parts.length; i++) {
            final modifier = parts[i];
            if (!{'at', 'with', 'an', 'repeat'}.contains(modifier)) {
              continue;
            }
            if (i < firstModifierIndex) {
              firstModifierIndex = i;
            }
            if (i + 1 >= parts.length) {
              continue;
            }
            final value = parts[i + 1];
            if ({'at', 'with', 'an', 'repeat'}.contains(value)) {
              continue;
            }
            switch (modifier) {
              case 'at':
                position = value;
                hasPositionModifier = true;
                break;
              case 'with':
                transitionType = value;
                break;
              case 'an':
                animation = value;
                hasAnimationModifier = true;
                break;
              case 'repeat':
                repeatCount = int.tryParse(value);
                break;
            }
            i++;
          }

          final attributeParts = parts.sublist(2, firstModifierIndex);
          var hasPosePrefix = false;
          for (final attribute in attributeParts) {
            if (attribute.startsWith('pose:')) {
              pose = attribute.substring(5);
              hasPosePrefix = true;
            } else if (attribute.startsWith('expression:')) {
              expression = attribute.substring(11);
            }
          }

          if (!hasPosePrefix && attributeParts.isNotEmpty) {
            if (hasPositionModifier && attributeParts.length >= 2) {
              pose = attributeParts[0];
              expression = attributeParts[1];
            } else if (hasAnimationModifier) {
              expression = attributeParts[0];
            } else {
              // 保持既有差分语义，但不再把 `with diss` 拼进差分名。
              expression = attributeParts.join(' ');
            }
          }

          //print('[SksParser] CG解析结果: character=$character, pose=$pose, expression=$expression, position=$position, animation=$animation');
          nodes.add(
            CgNode(
              character,
              pose: pose,
              expression: expression,
              position: position,
              transitionType: transitionType,
              animation: animation,
              repeatCount: repeatCount,
            ),
          );
          break;
        case 'hide':
          if (parts.length >= 2 && parts[1].toLowerCase() == 'canvas') {
            nodes.add(HideCanvasNode());
            break;
          }
          final immediate =
              parts.length > 2 && parts[2].toLowerCase() == 'immediate';
          nodes.add(HideNode(parts[1], immediate: immediate));
          break;
        case 'nvl':
          nodes.add(NvlNode());
          break;
        case 'endnvl':
          nodes.add(EndNvlNode());
          break;
        case 'nvln': // 新增：nvln（无遮罩NVL模式）
          nodes.add(NvlnNode());
          break;
        case 'endnvln': // 新增：endnvln
          nodes.add(EndNvlnNode());
          break;
        case 'nvlm':
          nodes.add(NvlMovieNode());
          break;
        case 'endnvlm':
          nodes.add(EndNvlMovieNode());
          break;
        case 'fx':
          final filterString = parts.sublist(1).join(' ');
          nodes.add(
            FxNode(
              filterString,
              sourceFile: _activeSourceFile,
              sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
            ),
          );
          break;
        case 'play':
          _logMusicParse(
            'line=${i + 1} play raw="$originalLine" parsed="$trimmedLine" parts=${parts.join('|')}',
          );
          if (parts.length >= 3 && parts[1] == 'music') {
            final musicFile = parts.sublist(2).join(' ').trim();
            _logMusicParse('line=${i + 1} parsed play music -> "$musicFile"');
            if (musicFile.isEmpty) {
              _logMusicParse('line=${i + 1} warning: musicFile is empty');
            }
            nodes.add(PlayMusicNode(musicFile));
          } else if (parts.length >= 3 && parts[1] == 'sound') {
            // play sound filename [loop]
            final soundParts = parts.sublist(2);
            final soundFile = soundParts[0];
            final loop = soundParts.length > 1 && soundParts[1] == 'loop';
            nodes.add(PlaySoundNode(soundFile, loop: loop));
          }
          break;
        case 'voice':
          final voiceFile = trimmedLine.substring('voice'.length).trim();
          if (voiceFile.isNotEmpty) {
            nodes.add(VoiceNode(voiceFile));
          }
          break;
        case 'stop':
          if (parts.length >= 2 && parts[1] == 'music') {
            nodes.add(StopMusicNode());
          } else if (parts.length >= 2 && parts[1] == 'sound') {
            nodes.add(StopSoundNode());
          } else if (parts.length >= 2 && parts[1] == 'voice') {
            nodes.add(StopVoiceNode());
          } else if (parts.length >= 2 && parts[1] == 'anime') {
            nodes.add(StopAnimeNode());
          }
          break;
        case 'bool':
          if (parts.length >= 3) {
            final variableName = parts[1];
            final value = parts[2].toLowerCase() == 'true';
            nodes.add(BoolNode(variableName, value));
          }
          break;
        case 'api':
          // 语法：
          // api <apiName> key=value key2="value with spaces"
          final payload = trimmedLine.substring(3).trim();
          if (payload.isEmpty) {
            break;
          }
          final splitIndex = _findFirstWhitespaceOutsideQuotes(payload);
          final apiName = splitIndex < 0
              ? payload
              : payload.substring(0, splitIndex).trim();
          final rawParams = splitIndex < 0
              ? ''
              : payload.substring(splitIndex + 1).trim();
          if (apiName.isEmpty) {
            break;
          }
          nodes.add(
            ApiCallNode(apiName, parameters: _parseApiParameters(rawParams)),
          );
          break;
        case 'achievement':
          // 语法糖：
          // achievement unlock <id>
          // achievement register <id>
          // achievement clear <id>
          if (parts.length < 2) {
            break;
          }

          String action;
          String achievementId;
          if (parts.length >= 3) {
            action = parts[1].toLowerCase();
            achievementId = parts.sublist(2).join(' ').trim();
          } else {
            action = 'unlock';
            achievementId = parts[1].trim();
          }

          if (achievementId.isEmpty) {
            break;
          }

          final apiName = switch (action) {
            'register' => 'steam.achievement.register',
            'unlock' => 'steam.achievement.unlock',
            'trigger' => 'steam.achievement.unlock',
            'clear' => 'steam.achievement.clear',
            'reset' => 'steam.achievement.clear',
            'cancel' => 'steam.achievement.clear',
            _ => 'steam.achievement.unlock',
          };

          nodes.add(
            ApiCallNode(
              apiName,
              parameters: <String, String>{'id': achievementId},
            ),
          );
          break;
        case 'pause':
          // pause(1.5) - 暂停指定秒数
          if (parts.length >= 2) {
            // 支持两种格式：pause(1.5) 或 pause 1.5
            String durationStr = parts[1];

            // 如果是 pause(1.5) 格式，提取括号内的数字
            final parenRegex = RegExp(r'pause\(([0-9.]+)\)');
            final parenMatch = parenRegex.firstMatch(trimmedLine);
            if (parenMatch != null) {
              durationStr = parenMatch.group(1)!;
            }

            final duration = double.tryParse(durationStr);
            if (duration != null && duration > 0) {
              nodes.add(PauseNode(duration));
              //print('[SksParser] 解析pause命令: duration=$duration');
            } else {
              print('[SksParser] 警告: 无效的pause时长: $durationStr');
            }
          }
          break;
        case 'shake':
          // shake [duration 1.0] [intensity 8.0] [target background]
          double? duration;
          double? intensity;
          String? target;

          // 解析参数
          for (int i = 1; i < parts.length; i++) {
            if (parts[i] == 'duration' && i + 1 < parts.length) {
              duration = double.tryParse(parts[i + 1]);
              i++; // 跳过下一个参数
            } else if (parts[i] == 'intensity' && i + 1 < parts.length) {
              intensity = double.tryParse(parts[i + 1]);
              i++; // 跳过下一个参数
            } else if (parts[i] == 'target' && i + 1 < parts.length) {
              target = parts[i + 1];
              i++; // 跳过下一个参数
            }
          }

          nodes.add(
            ShakeNode(duration: duration, intensity: intensity, target: target),
          );
          break;
        default:
          final sayNode = _parseSay(trimmedLine);
          if (sayNode != null) {
            //print('[SksParser] 解析SayNode: character=${sayNode.character}, pose=${sayNode.pose}, expression=${sayNode.expression}, dialogue=${sayNode.dialogue}');
            nodes.add(sayNode);
          } else {
            //print('[SksParser] 无法解析行: $trimmedLine');
          }
          break;
      }
      i++;
    }
    _activeSourceFile = null;
    _activeSourceLine = -1;
    return ScriptNode(nodes);
  }

  SksNode? _parseSay(String line) {
    // 先处理行末注释
    final processedLine = SksLineUtils.stripLineCommentOutsideQuotes(
      line,
    ).trim();

    // 检查是否是pause语法：pause(0.5)
    final pauseRegex = RegExp(r'^pause\(([0-9.]+)\)$');
    final pauseMatch = pauseRegex.firstMatch(processedLine);
    if (pauseMatch != null) {
      final durationStr = pauseMatch.group(1)!;
      final duration = double.tryParse(durationStr);
      if (duration != null && duration > 0) {
        return PauseNode(duration);
      } else {
        print('[SksParser] 警告: 无效的pause时长: $durationStr');
        return null;
      }
    }

    ({
      String? pose,
      String? position,
      String? inlineApiToken,
      String? animation,
      int? repeatCount,
    })
    parseTimedPrefixAttributes(String raw) {
      final result = (
        pose: null as String?,
        position: null as String?,
        inlineApiToken: null as String?,
        animation: null as String?,
        repeatCount: null as int?,
      );
      final attrs = raw
          .split(RegExp(r'\s+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (attrs.isEmpty) {
        return result;
      }

      int atIndex = -1;
      int anIndex = -1;
      int repeatIndex = -1;
      for (int i = 0; i < attrs.length; i++) {
        if (attrs[i] == 'at') {
          atIndex = i;
        } else if (attrs[i] == 'an') {
          anIndex = i;
        } else if (attrs[i] == 'repeat') {
          repeatIndex = i;
          break;
        }
      }

      int? repeatCount;
      if (repeatIndex >= 0 && repeatIndex + 1 < attrs.length) {
        repeatCount = int.tryParse(attrs[repeatIndex + 1]);
      }

      final endIndex = repeatIndex >= 0 ? repeatIndex : attrs.length;

      String? animation;
      List<String> regularAttrs;
      String? position;
      if (anIndex >= 0 && anIndex < endIndex) {
        if (anIndex + 1 < endIndex) {
          animation = attrs[anIndex + 1];
        }
        if (atIndex >= 0 && atIndex < anIndex) {
          regularAttrs = attrs.sublist(0, atIndex);
          if (atIndex + 1 < anIndex) {
            position = attrs[atIndex + 1];
          }
        } else {
          regularAttrs = attrs.sublist(0, anIndex);
        }
      } else if (atIndex >= 0 && atIndex < endIndex) {
        regularAttrs = attrs.sublist(0, atIndex);
        if (atIndex + 1 < endIndex) {
          position = attrs[atIndex + 1];
        }
      } else {
        regularAttrs = attrs.sublist(0, endIndex);
      }

      String? pose;
      String? inlineApiToken;
      for (final attr in regularAttrs) {
        if (_isInlineApiToken(attr)) {
          inlineApiToken = attr;
        } else if (attr.startsWith('pose') || attr.contains('pose')) {
          pose = attr;
        }
      }

      return (
        pose: pose,
        position: position,
        inlineApiToken: inlineApiToken,
        animation: animation,
        repeatCount: repeatCount,
      );
    }

    // 检查是否是时序差分切换语法: x [wakuwaku2,0.5,think] an jump "我去。"
    final timedExpressionRegex = RegExp(
      r'^(\w+)(?:\s+([^\[]+?))?\s*\[([^,]+),([^,]+),([^\]]+)\]\s*(.*?)\s*"([^"]*)"(?:\s+(.*))?\s*$',
    );
    final timedMatch = timedExpressionRegex.firstMatch(processedLine);

    if (timedMatch != null) {
      final character = timedMatch.group(1)!.trim();
      final beforeBracketAttrsRaw = timedMatch.group(2)?.trim() ?? '';
      final startExpression = timedMatch.group(3)!.trim();
      final delayStr = timedMatch.group(4)!.trim();
      final endExpression = timedMatch.group(5)!.trim();
      final afterBracketAttrsRaw = timedMatch.group(6)?.trim() ?? '';
      final dialogue = timedMatch.group(7)!;
      final tailMeta = _parseDialogueTail(timedMatch.group(8));

      final switchDelay = double.tryParse(delayStr);
      if (switchDelay == null || switchDelay <= 0) {
        print('[SksParser] 警告: 无效的延迟时间 "$delayStr"，跳过时序差分切换');
        return null;
      }

      final beforeAttrs = parseTimedPrefixAttributes(beforeBracketAttrsRaw);
      final afterAttrs = parseTimedPrefixAttributes(afterBracketAttrsRaw);

      final pose = afterAttrs.pose ?? beforeAttrs.pose;
      final position = afterAttrs.position ?? beforeAttrs.position;
      final inlineApiToken =
          afterAttrs.inlineApiToken ?? beforeAttrs.inlineApiToken;
      final animation = afterAttrs.animation ?? beforeAttrs.animation;
      final repeatCount = afterAttrs.repeatCount ?? beforeAttrs.repeatCount;

      //print('[SksParser] 解析时序差分切换: $character [$startExpression,$switchDelay,$endExpression] "$dialogue"');

      return SayNode(
        character: character,
        dialogue: _formatDialogueWithQuotes(dialogue, character),
        pose: pose,
        inlineApiToken: inlineApiToken,
        dialogueTag: tailMeta.dialogueTag,
        tailCharacter: tailMeta.tailCharacter,
        tailPose: tailMeta.tailPose,
        tailExpression: tailMeta.tailExpression,
        tailAnimation: tailMeta.tailAnimation,
        tailRepeatCount: tailMeta.tailRepeatCount,
        sourceFile: _activeSourceFile,
        sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
        position: position,
        animation: animation,
        repeatCount: repeatCount,
        startExpression: startExpression,
        switchDelay: switchDelay,
        endExpression: endExpression,
      );
    }

    // 条件对话，支持可选行尾 tag：
    // xxx "dialogue" [tag] if var true/false
    final conditionalRegex = RegExp(
      r'^(.*?)\s*"([^"]+)"(?:\s+(.*?))?\s+if\s+(\w+)\s+(true|false)\s*$',
    );
    final conditionalMatch = conditionalRegex.firstMatch(processedLine);

    if (conditionalMatch != null) {
      final beforeQuote = conditionalMatch.group(1)!.trim();
      final dialogue = conditionalMatch.group(2)!;
      final tailMeta = _parseDialogueTail(conditionalMatch.group(3));
      final variableName = conditionalMatch.group(4)!;
      final conditionValue = conditionalMatch.group(5)! == 'true';

      String? character;
      String? pose;
      String? expression;
      String? position;
      String? inlineApiToken;
      String? animation;
      int? repeatCount;

      // 解析角色和属性（如果存在）
      if (beforeQuote.isNotEmpty) {
        final parts = beforeQuote
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) {
          character = parts[0];

          // 解析其他属性
          if (parts.length > 1) {
            final attrs = parts.sublist(1);

            // 查找at、an和repeat关键字位置
            int atIndex = -1;
            int anIndex = -1;
            int repeatIndex = -1;
            for (int i = 0; i < attrs.length; i++) {
              if (attrs[i] == 'at') {
                atIndex = i;
              } else if (attrs[i] == 'an') {
                anIndex = i;
              } else if (attrs[i] == 'repeat') {
                repeatIndex = i;
                break;
              }
            }

            // 解析repeat参数
            if (repeatIndex >= 0 && repeatIndex + 1 < attrs.length) {
              repeatCount = int.tryParse(attrs[repeatIndex + 1]);
            }

            int endIndex = repeatIndex >= 0 ? repeatIndex : attrs.length;

            List<String> regularAttrs;

            if (anIndex >= 0 && anIndex < endIndex) {
              // 有an动画语法
              if (anIndex + 1 < endIndex) {
                animation = attrs[anIndex + 1];
              }

              if (atIndex >= 0 && atIndex < anIndex) {
                // at在an之前：character pose expression at position an animation
                final attributeParts = attrs.sublist(0, atIndex);
                regularAttrs = attributeParts;
                if (atIndex + 1 < anIndex) {
                  position = attrs[atIndex + 1];
                }
              } else {
                // 没有at或at在an之后（无效）
                regularAttrs = attrs.sublist(0, anIndex);
              }
            } else if (atIndex >= 0 && atIndex < endIndex) {
              // 有at但没有an：character pose expression at position
              final attributeParts = attrs.sublist(0, atIndex);
              regularAttrs = attributeParts;
              if (atIndex + 1 < endIndex) {
                position = attrs[atIndex + 1];
              }
            } else {
              // 没有特殊语法，都是普通属性
              regularAttrs = attrs.sublist(0, endIndex);
            }

            // 解析普通属性
            for (final attr in regularAttrs) {
              if (_isInlineApiToken(attr)) {
                inlineApiToken = attr;
              } else if (attr.startsWith('pose') || attr.contains('pose')) {
                pose = attr;
              } else {
                expression = attr;
              }
            }
          }
        }
      }

      return ConditionalSayNode(
        dialogue: _formatDialogueWithQuotes(dialogue, character),
        character: character,
        inlineApiToken: inlineApiToken,
        dialogueTag: tailMeta.dialogueTag,
        tailCharacter: tailMeta.tailCharacter,
        tailPose: tailMeta.tailPose,
        tailExpression: tailMeta.tailExpression,
        tailAnimation: tailMeta.tailAnimation,
        tailRepeatCount: tailMeta.tailRepeatCount,
        sourceFile: _activeSourceFile,
        sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
        conditionVariable: variableName,
        conditionValue: conditionValue,
        pose: pose,
        expression: expression,
        position: position,
        animation: animation,
        repeatCount: repeatCount,
      );
    }

    // 继续原有的解析逻辑

    // 普通对话，支持可选行尾 tag：
    // xxx "dialogue" [tag]
    // 1: 可选角色及属性
    // 2: 对话文本
    // 3: 可选行尾 tag
    final sayRegex = RegExp(r'^(.*?)\s*"([^"]*)"(?:\s+(.*))?\s*$');
    final match = sayRegex.firstMatch(processedLine);

    if (match == null) {
      // Simple narration check for lines that are just "dialogue"
      final simpleNarrationRegex = RegExp(r'^"([^"]*)"(?:\s+(.*))?\s*$');
      final simpleMatch = simpleNarrationRegex.firstMatch(processedLine);
      if (simpleMatch != null) {
        final tailMeta = _parseDialogueTail(simpleMatch.group(2));
        return SayNode(
          dialogue: _formatDialogueWithQuotes(simpleMatch.group(1)!, null),
          dialogueTag: tailMeta.dialogueTag,
          tailCharacter: tailMeta.tailCharacter,
          tailPose: tailMeta.tailPose,
          tailExpression: tailMeta.tailExpression,
          tailAnimation: tailMeta.tailAnimation,
          tailRepeatCount: tailMeta.tailRepeatCount,
          sourceFile: _activeSourceFile,
          sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
        );
      }
      return null;
    }

    final dialogue = match.group(2)!;
    final tailMeta = _parseDialogueTail(match.group(3));
    final beforeQuote = match.group(1)!.trim();

    if (beforeQuote.isEmpty) {
      // Narration: "dialogue"
      return SayNode(
        dialogue: _formatDialogueWithQuotes(dialogue, null),
        dialogueTag: tailMeta.dialogueTag,
        tailCharacter: tailMeta.tailCharacter,
        tailPose: tailMeta.tailPose,
        tailExpression: tailMeta.tailExpression,
        tailAnimation: tailMeta.tailAnimation,
        tailRepeatCount: tailMeta.tailRepeatCount,
        sourceFile: _activeSourceFile,
        sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
      );
    }

    final parts = beforeQuote
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return null; // Should not happen with this regex, but for safety
    }

    final character = parts[0];
    String? pose;
    String? expression;
    String? position;
    String? inlineApiToken;
    int? repeatCount;

    // 解析pose、expression、position、animation和repeat属性
    if (parts.length > 1) {
      final attrs = parts.sublist(1);

      // 查找at、an和repeat关键字位置
      int atIndex = -1;
      int anIndex = -1;
      int repeatIndex = -1;
      for (int i = 0; i < attrs.length; i++) {
        if (attrs[i] == 'at') {
          atIndex = i;
        } else if (attrs[i] == 'an') {
          anIndex = i;
        } else if (attrs[i] == 'repeat') {
          repeatIndex = i;
          break;
        }
      }

      // 解析repeat参数
      if (repeatIndex >= 0 && repeatIndex + 1 < attrs.length) {
        repeatCount = int.tryParse(attrs[repeatIndex + 1]);
      }

      int endIndex = repeatIndex >= 0 ? repeatIndex : attrs.length;

      String? animation;
      List<String> regularAttrs;

      if (anIndex >= 0 && anIndex < endIndex) {
        // 有an动画语法
        if (anIndex + 1 < endIndex) {
          animation = attrs[anIndex + 1];
        }

        if (atIndex >= 0 && atIndex < anIndex) {
          // at在an之前：character pose expression at position an animation
          final attributeParts = attrs.sublist(0, atIndex);
          regularAttrs = attributeParts;
          if (atIndex + 1 < anIndex) {
            position = attrs[atIndex + 1];
          }
        } else {
          // 没有at或at在an之后（无效）
          regularAttrs = attrs.sublist(0, anIndex);
        }
      } else if (atIndex >= 0 && atIndex < endIndex) {
        // 有at但没有an：character pose expression at position
        final attributeParts = attrs.sublist(0, atIndex);
        regularAttrs = attributeParts;
        if (atIndex + 1 < endIndex) {
          position = attrs[atIndex + 1];
        }
      } else {
        // 没有特殊语法，都是普通属性
        regularAttrs = attrs.sublist(0, endIndex);
      }

      // 解析普通属性
      for (final attr in regularAttrs) {
        if (_isInlineApiToken(attr)) {
          inlineApiToken = attr;
        } else if (attr.startsWith('pose') || attr.contains('pose')) {
          pose = attr;
        } else {
          expression = attr;
        }
      }

      return SayNode(
        character: character,
        dialogue: _formatDialogueWithQuotes(dialogue, character),
        inlineApiToken: inlineApiToken,
        dialogueTag: tailMeta.dialogueTag,
        tailCharacter: tailMeta.tailCharacter,
        tailPose: tailMeta.tailPose,
        tailExpression: tailMeta.tailExpression,
        tailAnimation: tailMeta.tailAnimation,
        tailRepeatCount: tailMeta.tailRepeatCount,
        sourceFile: _activeSourceFile,
        sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
        pose: pose,
        expression: expression,
        position: position,
        animation: animation,
        repeatCount: repeatCount,
      );
    }

    return SayNode(
      character: character,
      dialogue: _formatDialogueWithQuotes(dialogue, character),
      inlineApiToken: inlineApiToken,
      dialogueTag: tailMeta.dialogueTag,
      tailCharacter: tailMeta.tailCharacter,
      tailPose: tailMeta.tailPose,
      tailExpression: tailMeta.tailExpression,
      tailAnimation: tailMeta.tailAnimation,
      tailRepeatCount: tailMeta.tailRepeatCount,
      sourceFile: _activeSourceFile,
      sourceLine: _activeSourceLine > 0 ? _activeSourceLine : null,
      pose: pose,
      expression: expression,
      position: position,
    );
  }

  bool _isInlineApiToken(String token) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    return trimmed.toLowerCase().startsWith('api');
  }
}
