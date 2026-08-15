import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';

void main(List<String> args) async {
  try {
    final options = _CompileOptions.parse(args);
    if (options.showHelp) {
      _printUsage();
      return;
    }

    final result = await _SksCompiler(options).compile();
    stdout.writeln(
      '[SKS Compiler] 完成: ${result.totalFiles} 个 .sks, '
      '${result.labelScripts} 个 label 脚本 -> ${result.outputPath}',
    );
  } on _CliException catch (e) {
    stderr.writeln('[SKS Compiler] 参数错误: ${e.message}');
    _printUsage();
    exitCode = 64;
  } catch (e, st) {
    stderr.writeln('[SKS Compiler] 编译失败: $e');
    stderr.writeln(st);
    exitCode = 1;
  }
}

void _printUsage() {
  stdout.writeln('''
Usage:
  flutter pub run ../../Engine/tool/sks_compiler.dart \\
    --game-dir <path/to/GameProject> \\
    --output <path/to/compiled_sks_bundle.g.dart> \\
    [--game-name <ProjectName>]

Options:
  --game-dir   游戏项目目录 (例如: /repo/Game/SoraNoUta)
  --output     生成的 Dart 文件路径
  --game-name  生成 bundle 绑定的项目名，默认使用 game-dir 目录名
  --help       显示帮助
''');
}

class _CliException implements Exception {
  final String message;
  const _CliException(this.message);
}

class _CompileOptions {
  final Directory gameDir;
  final File outputFile;
  final String gameName;
  final bool showHelp;

  const _CompileOptions({
    required this.gameDir,
    required this.outputFile,
    required this.gameName,
    required this.showHelp,
  });

  factory _CompileOptions.parse(List<String> args) {
    String? gameDirArg;
    String? outputArg;
    String? gameNameArg;
    var showHelp = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '--help':
        case '-h':
          showHelp = true;
          break;
        case '--game-dir':
          if (i + 1 >= args.length) {
            throw const _CliException('缺少 --game-dir 的值');
          }
          gameDirArg = args[++i];
          break;
        case '--output':
          if (i + 1 >= args.length) {
            throw const _CliException('缺少 --output 的值');
          }
          outputArg = args[++i];
          break;
        case '--game-name':
          if (i + 1 >= args.length) {
            throw const _CliException('缺少 --game-name 的值');
          }
          gameNameArg = args[++i];
          break;
        default:
          throw _CliException('未知参数: $arg');
      }
    }

    if (showHelp) {
      return _CompileOptions(
        gameDir: Directory.current,
        outputFile: File('compiled_sks_bundle.g.dart'),
        gameName: '',
        showHelp: true,
      );
    }

    if (gameDirArg == null || gameDirArg.trim().isEmpty) {
      throw const _CliException('必须提供 --game-dir');
    }
    if (outputArg == null || outputArg.trim().isEmpty) {
      throw const _CliException('必须提供 --output');
    }

    final gameDir = Directory(gameDirArg).absolute;
    final outputFile = File(outputArg).absolute;
    final gameName = (gameNameArg == null || gameNameArg.trim().isEmpty)
        ? p.basename(gameDir.path)
        : gameNameArg.trim();

    return _CompileOptions(
      gameDir: gameDir,
      outputFile: outputFile,
      gameName: gameName,
      showHelp: false,
    );
  }
}

class _CompileResult {
  final int totalFiles;
  final int labelScripts;
  final String outputPath;

  const _CompileResult({
    required this.totalFiles,
    required this.labelScripts,
    required this.outputPath,
  });
}

class _SksSource {
  final String assetPath;
  final String content;
  final bool isLabelScript;

  const _SksSource({
    required this.assetPath,
    required this.content,
    required this.isLabelScript,
  });
}

class _SksCompiler {
  final _CompileOptions options;

  _SksCompiler(this.options);

  Future<_CompileResult> compile() async {
    if (!await options.gameDir.exists()) {
      throw _CliException('游戏目录不存在: ${options.gameDir.path}');
    }

    final sources = await _collectSksSources();
    final parser = SksParser();
    final textByAssetPath = <String, String>{};
    final labelScriptsByAssetPath = <String, ScriptNode>{};

    for (final source in sources) {
      textByAssetPath[source.assetPath] = source.content;
      if (source.isLabelScript) {
        labelScriptsByAssetPath[source.assetPath] =
            parser.parse(source.content);
      }
    }

    final outputContent = _generateDartSource(
      gameName: options.gameName,
      textByAssetPath: textByAssetPath,
      labelScriptsByAssetPath: labelScriptsByAssetPath,
    );

    await options.outputFile.parent.create(recursive: true);
    await options.outputFile.writeAsString(outputContent);

    return _CompileResult(
      totalFiles: textByAssetPath.length,
      labelScripts: labelScriptsByAssetPath.length,
      outputPath: options.outputFile.path,
    );
  }

  Future<List<_SksSource>> _collectSksSources() async {
    final scriptRoots = <Directory>[];
    await for (final entity in options.gameDir.list(followLinks: false)) {
      if (entity is Directory &&
          p.basename(entity.path).startsWith('GameScript')) {
        scriptRoots.add(entity);
      }
    }

    scriptRoots.sort((a, b) => a.path.compareTo(b.path));
    final results = <_SksSource>[];

    for (final root in scriptRoots) {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        if (!entity.path.toLowerCase().endsWith('.sks')) {
          continue;
        }

        final relativePath = _toPosixPath(
          p.relative(entity.path, from: options.gameDir.path),
        );
        final assetPath = CompiledSksBundle.normalizeAssetPath(relativePath);
        final content = await entity.readAsString();
        final isLabelScript = relativePath.contains('/labels/');
        results.add(
          _SksSource(
            assetPath: assetPath,
            content: content,
            isLabelScript: isLabelScript,
          ),
        );
      }
    }

    results.sort((a, b) => a.assetPath.compareTo(b.assetPath));
    return results;
  }

  String _generateDartSource({
    required String gameName,
    required Map<String, String> textByAssetPath,
    required Map<String, ScriptNode> labelScriptsByAssetPath,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.');
    buffer.writeln('// Generated by Engine/tool/sks_compiler.dart.');
    buffer.writeln();
    buffer.writeln(
      "import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';",
    );
    buffer.writeln("import 'package:sakiengine/src/sks_parser/sks_ast.dart';");
    buffer.writeln();
    buffer.writeln('CompiledSksBundle? loadGeneratedCompiledSksBundle() {');

    if (textByAssetPath.isEmpty && labelScriptsByAssetPath.isEmpty) {
      buffer.writeln('  return null;');
      buffer.writeln('}');
      return buffer.toString();
    }

    buffer.writeln('  return CompiledSksBundle(');
    buffer.writeln('    gameName: ${_str(gameName)},');
    buffer.writeln('    textByAssetPath: <String, String>{');
    for (final entry in textByAssetPath.entries) {
      buffer.writeln('      ${_str(entry.key)}: ${_str(entry.value)},');
    }
    buffer.writeln('    },');

    buffer.writeln('    labelScriptsByAssetPath: <String, ScriptNode>{');
    for (final entry in labelScriptsByAssetPath.entries) {
      buffer.writeln('      ${_str(entry.key)}: ScriptNode(<SksNode>[');
      for (final node in entry.value.children) {
        buffer.writeln('        ${_emitNode(node)},');
      }
      buffer.writeln('      ]),');
    }
    buffer.writeln('    },');
    buffer.writeln('  );');
    buffer.writeln('}');
    return buffer.toString();
  }

  String _emitNode(SksNode node) {
    if (node is ScriptNode) {
      final children =
          node.children.map((child) => _emitNode(child)).join(', ');
      return 'ScriptNode(<SksNode>[$children])';
    }
    if (node is AnimeNode) {
      return 'AnimeNode(${_str(node.animeName)}, loop: ${node.loop}, keep: ${node.keep}, '
          'transitionType: ${_nullableString(node.transitionType)}, timer: ${_nullableDouble(node.timer)})';
    }
    if (node is StopAnimeNode) {
      return 'StopAnimeNode()';
    }
    if (node is ShowNode) {
      return 'ShowNode(${_str(node.character)}, pose: ${_nullableString(node.pose)}, '
          'expression: ${_nullableString(node.expression)}, position: ${_nullableString(node.position)}, '
          'animation: ${_nullableString(node.animation)}, repeatCount: ${_nullableInt(node.repeatCount)})';
    }
    if (node is CgNode) {
      return 'CgNode(${_str(node.character)}, pose: ${_nullableString(node.pose)}, '
          'expression: ${_nullableString(node.expression)}, position: ${_nullableString(node.position)}, '
          'transitionType: ${_nullableString(node.transitionType)}, '
          'animation: ${_nullableString(node.animation)}, repeatCount: ${_nullableInt(node.repeatCount)})';
    }
    if (node is HideNode) {
      return 'HideNode(${_str(node.character)})';
    }
    if (node is MovieNode) {
      return 'MovieNode(${_str(node.movieFile)}, timer: ${_nullableDouble(node.timer)}, '
          'layers: ${_nullableStringList(node.layers)}, transitionType: ${_nullableString(node.transitionType)}, '
          'animation: ${_nullableString(node.animation)}, repeatCount: ${_nullableInt(node.repeatCount)})';
    }
    if (node is BackgroundNode) {
      return 'BackgroundNode(${_str(node.background)}, timer: ${_nullableDouble(node.timer)}, '
          'layers: ${_nullableStringList(node.layers)}, transitionType: ${_nullableString(node.transitionType)}, '
          'animation: ${_nullableString(node.animation)}, repeatCount: ${_nullableInt(node.repeatCount)})';
    }
    if (node is SayNode) {
      return 'SayNode(character: ${_nullableString(node.character)}, dialogue: ${_str(node.dialogue)}, '
          'dialogueTag: ${_nullableString(node.dialogueTag)}, '
          'tailCharacter: ${_nullableString(node.tailCharacter)}, '
          'tailPose: ${_nullableString(node.tailPose)}, '
          'tailExpression: ${_nullableString(node.tailExpression)}, '
          'tailAnimation: ${_nullableString(node.tailAnimation)}, '
          'tailRepeatCount: ${_nullableInt(node.tailRepeatCount)}, '
          'sourceFile: ${_nullableString(node.sourceFile)}, '
          'sourceLine: ${_nullableInt(node.sourceLine)}, '
          'pose: ${_nullableString(node.pose)}, expression: ${_nullableString(node.expression)}, '
          'position: ${_nullableString(node.position)}, animation: ${_nullableString(node.animation)}, '
          'repeatCount: ${_nullableInt(node.repeatCount)}, startExpression: ${_nullableString(node.startExpression)}, '
          'switchDelay: ${_nullableDouble(node.switchDelay)}, endExpression: ${_nullableString(node.endExpression)})';
    }
    if (node is MenuNode) {
      return 'MenuNode(<ChoiceOptionNode>[${node.choices.map(_emitChoice).join(', ')}])';
    }
    if (node is LabelNode) {
      return 'LabelNode(${_str(node.name)})';
    }
    if (node is ReturnNode) {
      return 'ReturnNode()';
    }
    if (node is JumpNode) {
      if (node.isConditional) {
        return 'JumpNode(${_str(node.targetLabel)}, '
            'conditionVariable: ${_str(node.conditionVariable!)}, '
            'conditionValue: ${node.conditionValue})';
      }
      return 'JumpNode(${_str(node.targetLabel)})';
    }
    if (node is CommentNode) {
      return 'CommentNode(${_str(node.comment)})';
    }
    if (node is NvlNode) {
      return 'NvlNode()';
    }
    if (node is EndNvlNode) {
      return 'EndNvlNode()';
    }
    if (node is NvlnNode) {
      return 'NvlnNode()';
    }
    if (node is EndNvlnNode) {
      return 'EndNvlnNode()';
    }
    if (node is NvlMovieNode) {
      return 'NvlMovieNode()';
    }
    if (node is EndNvlMovieNode) {
      return 'EndNvlMovieNode()';
    }
    if (node is FxNode) {
      return 'FxNode(${_str(node.filterString)}, sourceFile: ${_nullableString(node.sourceFile)}, '
          'sourceLine: ${_nullableInt(node.sourceLine)})';
    }
    if (node is PlayMusicNode) {
      return 'PlayMusicNode(${_str(node.musicFile)})';
    }
    if (node is StopMusicNode) {
      return 'StopMusicNode()';
    }
    if (node is PlaySoundNode) {
      return 'PlaySoundNode(${_str(node.soundFile)}, loop: ${node.loop})';
    }
    if (node is StopSoundNode) {
      return 'StopSoundNode()';
    }
    if (node is VoiceNode) {
      return 'VoiceNode(${_str(node.voiceFile)})';
    }
    if (node is StopVoiceNode) {
      return 'StopVoiceNode()';
    }
    if (node is ApiCallNode) {
      return 'ApiCallNode(${_str(node.apiName)}, parameters: ${_stringMap(node.parameters)})';
    }
    if (node is BoolNode) {
      return 'BoolNode(${_str(node.variableName)}, ${node.value})';
    }
    if (node is ConditionalSayNode) {
      return 'ConditionalSayNode(dialogue: ${_str(node.dialogue)}, '
          'character: ${_nullableString(node.character)}, '
          'dialogueTag: ${_nullableString(node.dialogueTag)}, '
          'tailCharacter: ${_nullableString(node.tailCharacter)}, '
          'tailPose: ${_nullableString(node.tailPose)}, '
          'tailExpression: ${_nullableString(node.tailExpression)}, '
          'tailAnimation: ${_nullableString(node.tailAnimation)}, '
          'tailRepeatCount: ${_nullableInt(node.tailRepeatCount)}, '
          'sourceFile: ${_nullableString(node.sourceFile)}, '
          'sourceLine: ${_nullableInt(node.sourceLine)}, '
          'conditionVariable: ${_str(node.conditionVariable)}, '
          'conditionValue: ${node.conditionValue}, '
          'pose: ${_nullableString(node.pose)}, expression: ${_nullableString(node.expression)}, '
          'position: ${_nullableString(node.position)}, animation: ${_nullableString(node.animation)}, '
          'repeatCount: ${_nullableInt(node.repeatCount)})';
    }
    if (node is ShakeNode) {
      return 'ShakeNode(duration: ${_nullableDouble(node.duration)}, '
          'intensity: ${_nullableDouble(node.intensity)}, target: ${_nullableString(node.target)})';
    }
    if (node is PauseNode) {
      return 'PauseNode(${_doubleValue(node.duration)})';
    }
    throw UnsupportedError('Unsupported SksNode: ${node.runtimeType}');
  }

  String _emitChoice(ChoiceOptionNode choice) {
    return 'ChoiceOptionNode(${_str(choice.text)}, ${_str(choice.targetLabel)})';
  }

  String _str(String value) => jsonEncode(value);

  String _nullableString(String? value) => value == null ? 'null' : _str(value);

  String _nullableInt(int? value) => value == null ? 'null' : value.toString();

  String _nullableDouble(double? value) =>
      value == null ? 'null' : _doubleValue(value);

  String _nullableStringList(List<String>? values) {
    if (values == null) {
      return 'null';
    }
    if (values.isEmpty) {
      return '<String>[]';
    }
    return '<String>[${values.map(_str).join(', ')}]';
  }

  String _stringMap(Map<String, String> values) {
    if (values.isEmpty) {
      return '<String, String>{}';
    }
    final entries = values.entries
        .map((entry) => '${_str(entry.key)}: ${_str(entry.value)}')
        .join(', ');
    return '<String, String>{$entries}';
  }

  String _doubleValue(double value) {
    if (value.isNaN || value.isInfinite) {
      throw UnsupportedError('Unsupported double value: $value');
    }
    return value.toString();
  }

  String _toPosixPath(String input) {
    return input.replaceAll('\\', '/');
  }
}
