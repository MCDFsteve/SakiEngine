import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/game/game_script_localization.dart';
import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';
import 'package:sakiengine/src/sks_compiler/compiled_sks_registry.dart';
import 'package:sakiengine/src/sks_parser/sks_ast.dart';
import 'package:sakiengine/src/sks_parser/sks_parser.dart';
import 'package:sakiengine/src/native/native_script_compiler.dart';
import 'package:sakiengine/src/native/native_runtime_index.dart';

class ScriptMerger {
  static ScriptNode? _sharedMergedScript;
  static Map<String, int> _sharedFileStartIndices = const {};
  static Map<String, String> _sharedGlobalLabelMap = const {};

  final Map<String, ScriptNode> _loadedScripts = {};
  final Map<String, int> _fileStartIndices = {}; // 记录每个文件在合并脚本中的起始索引
  final Map<String, String> _globalLabelMap = {}; // label -> filename
  ScriptNode? _mergedScript;
  NativeRuntimeIndex? _nativeRuntimeIndex;

  /// 构建全局标签映射，扫描所有脚本文件
  Future<void> _buildGlobalLabelMap() async {
    _globalLabelMap.clear();
    _loadedScripts.clear();

    final precompiledBundle = CompiledSksRegistry.instance.activeBundle;
    if (precompiledBundle != null && precompiledBundle.hasLabelScripts) {
      _loadFromCompiledBundle(precompiledBundle);
      if (_loadedScripts.isNotEmpty) {
        if (kEngineDebugMode) {
          //print('[ScriptMerger] 使用预编译脚本，共 ${_loadedScripts.length} 个文件');
        }
        return;
      }
    }

    try {
      // 获取所有 .sks 文件
      final scriptFiles = await AssetManager().listAssets(
        'assets/GameScript/labels/',
        '.sks',
      );
      scriptFiles.sort();

      if (await _tryBuildWithNativeCompiler(scriptFiles)) {
        return;
      }

      for (final fileName in scriptFiles) {
        final fileNameWithoutExt = fileName.replaceAll('.sks', '');
        try {
          final scriptContent = await AssetManager().loadString(
            'assets/GameScript/labels/$fileName',
          );
          final script = SksParser().parse(
            scriptContent,
            sourceFile: fileNameWithoutExt,
          );
          _loadedScripts[fileNameWithoutExt] = script;
          _collectLabels(fileNameWithoutExt, script);
        } catch (e) {
          if (kEngineDebugMode) {
            //print('[ScriptMerger] 加载脚本文件失败: $fileName - $e');
          }
        }
      }

      if (kEngineDebugMode) {
        //print('[ScriptMerger] 全局标签映射构建完成，共 ${_globalLabelMap.length} 个标签');
      }
    } catch (e) {
      if (kEngineDebugMode) {
        //print('[ScriptMerger] 构建全局标签映射失败: $e');
      }
    }
  }

  Future<bool> _tryBuildWithNativeCompiler(List<String> scriptFiles) async {
    if (scriptFiles.isEmpty) {
      return false;
    }
    try {
      final sources = await Future.wait([
        for (final fileName in scriptFiles)
          AssetManager()
              .loadString('assets/GameScript/labels/$fileName')
              .then(
                (content) =>
                    NativeScriptSource(fileName: fileName, content: content),
              ),
      ]);
      final compiled = await compileScriptsNatively(sources);
      if (compiled == null || compiled.mergedSource.isEmpty) {
        return false;
      }

      final script = SksParser().parse(compiled.mergedSource);
      _nativeRuntimeIndex = await buildRuntimeIndexNatively(script.children);
      _fileStartIndices.clear();
      String? currentFile;
      for (var index = 0; index < script.children.length; index++) {
        final node = script.children[index];
        if (node is! CommentNode) {
          if (node is LabelNode && currentFile != null) {
            _globalLabelMap[node.name] = currentFile;
          }
          continue;
        }
        final match = RegExp(r'^=== 文件: (.+) ===$').firstMatch(node.comment);
        if (match != null) {
          currentFile = match.group(1)!;
          _fileStartIndices[currentFile] = index;
        }
      }
      _mergedScript = script;
      _publishSharedScript();
      sakiDiagnosticLog(
        '[SAKI_NATIVE][SKS] files=${compiled.orderedFiles.length} '
        'nodes=${script.children.length} '
        'native=${compiled.elapsedMicros / 1000.0}ms',
      );
      final runtime = _nativeRuntimeIndex;
      if (runtime != null) {
        sakiDiagnosticLog(
          '[SAKI_NATIVE][RUNTIME] labels=${runtime.labelIndices.length} '
          'flow=${runtime.flowNodes.length} '
          'compact=${runtime.compactBytes}B '
          'native=${runtime.elapsedMicros / 1000.0}ms',
        );
      }
      if (kEngineDebugMode) {
        for (final diagnostic in compiled.diagnostics) {
          print('[SAKI_NATIVE][SKS] $diagnostic');
        }
      }
      return true;
    } catch (error, stackTrace) {
      if (kEngineDebugMode) {
        print(
          '[SAKI_NATIVE][SKS] merged parse failed; '
          'Dart fallback enabled: $error',
        );
        print(stackTrace);
      }
      _mergedScript = null;
      _fileStartIndices.clear();
      _globalLabelMap.clear();
      return false;
    }
  }

  void _loadFromCompiledBundle(CompiledSksBundle bundle) {
    final scriptFiles = _collectLabelFileNames(bundle);
    for (final fileName in scriptFiles) {
      final script = _resolveLocalizedLabelScript(bundle, fileName);
      if (script == null) {
        continue;
      }

      final fileNameWithoutExt = fileName.replaceAll('.sks', '');
      _loadedScripts[fileNameWithoutExt] = script;
      _collectLabels(fileNameWithoutExt, script);
    }
  }

  List<String> _collectLabelFileNames(CompiledSksBundle bundle) {
    final fileNames = <String>[];
    final seen = <String>{};
    final candidateDirs = GameScriptLocalization.candidateDirectories();

    for (final dir in candidateDirs) {
      final prefix = 'assets/$dir/labels/';
      for (final assetPath in bundle.labelAssetPaths) {
        if (!assetPath.startsWith(prefix) || !assetPath.endsWith('.sks')) {
          continue;
        }
        final fileName = assetPath.substring(prefix.length);
        if (fileName.contains('/')) {
          continue;
        }
        if (seen.add(fileName)) {
          fileNames.add(fileName);
        }
      }
    }
    fileNames.sort();
    return fileNames;
  }

  ScriptNode? _resolveLocalizedLabelScript(
    CompiledSksBundle bundle,
    String fileName,
  ) {
    final candidateDirs = GameScriptLocalization.candidateDirectories();
    for (final dir in candidateDirs) {
      final assetPath = 'assets/$dir/labels/$fileName';
      final script = bundle.loadLabelScriptByAssetPath(assetPath);
      if (script != null) {
        return script;
      }
    }
    return null;
  }

  void _collectLabels(String fileNameWithoutExt, ScriptNode script) {
    for (final node in script.children) {
      if (node is LabelNode) {
        _globalLabelMap[node.name] = fileNameWithoutExt;
        if (kEngineDebugMode) {
          //print('[ScriptMerger] 发现标签: ${node.name} 在文件 $fileNameWithoutExt 中');
        }
      }
    }
  }

  /// 合并所有脚本文件成一个连续的脚本
  Future<ScriptNode> getMergedScript() async {
    if (_mergedScript != null) {
      return _mergedScript!;
    }
    final shared = _sharedMergedScript;
    if (shared != null) {
      _mergedScript = shared;
      _fileStartIndices
        ..clear()
        ..addAll(_sharedFileStartIndices);
      _globalLabelMap
        ..clear()
        ..addAll(_sharedGlobalLabelMap);
      _nativeRuntimeIndex = await buildRuntimeIndexNatively(shared.children);
      if (kEngineDebugMode) {
        print(
          '[SAKI_NATIVE][SKS] shared nodes=${shared.children.length} '
          'runtime=${_nativeRuntimeIndex?.elapsedMicros ?? 0}us',
        );
      }
      return shared;
    }

    await _buildGlobalLabelMap();
    if (_mergedScript != null) {
      return _mergedScript!;
    }

    final mergedChildren = <SksNode>[];
    _fileStartIndices.clear();

    // 先从 start 文件按 jump 顺序拼接，保持现有存档索引稳定。
    final processedFiles = <String>{};
    await _mergeFileRecursively('start', mergedChildren, processedFiles);

    // 再稳定地追加 start 不可达的独立入口。这样章节选择、DLC 或其他
    // 声明式入口无需伪造 jump，也能通过 getFileStartIndex 正确启动。
    final remainingEntryFiles = _loadedScripts.keys.toList()..sort();
    for (final fileName in remainingEntryFiles) {
      await _mergeFileRecursively(fileName, mergedChildren, processedFiles);
    }

    _mergedScript = ScriptNode(mergedChildren);
    _nativeRuntimeIndex = await buildRuntimeIndexNatively(
      _mergedScript!.children,
    );
    _publishSharedScript();
    return _mergedScript!;
  }

  void _publishSharedScript() {
    final script = _mergedScript;
    if (script == null) {
      return;
    }
    _sharedMergedScript = script;
    _sharedFileStartIndices = Map.unmodifiable(_fileStartIndices);
    _sharedGlobalLabelMap = Map.unmodifiable(_globalLabelMap);
  }

  /// 递归合并文件，按照 jump 顺序
  Future<void> _mergeFileRecursively(
    String fileName,
    List<SksNode> mergedChildren,
    Set<String> processedFiles,
  ) async {
    if (processedFiles.contains(fileName) ||
        !_loadedScripts.containsKey(fileName)) {
      return;
    }

    processedFiles.add(fileName);
    final script = _loadedScripts[fileName]!;
    _fileStartIndices[fileName] = mergedChildren.length;

    // 添加文件开始标记
    mergedChildren.add(CommentNode('=== 文件: $fileName ==='));

    // 收集当前文件中的所有 jump 目标
    final jumpTargets = <String>[];

    for (final node in script.children) {
      // 先添加当前节点
      mergedChildren.add(_cloneNode(node));

      // 如果是 jump 节点，记录目标但不立即处理
      if (node is JumpNode) {
        final targetLabel = node.targetLabel;
        if (_globalLabelMap.containsKey(targetLabel)) {
          final targetFile = _globalLabelMap[targetLabel]!;
          if (!jumpTargets.contains(targetFile) && targetFile != fileName) {
            jumpTargets.add(targetFile);
          }
        }
      }

      // 如果是 menu 节点，也要处理选项中的目标标签
      if (node is MenuNode) {
        for (final choice in node.choices) {
          final targetLabel = choice.targetLabel;
          if (_globalLabelMap.containsKey(targetLabel)) {
            final targetFile = _globalLabelMap[targetLabel]!;
            if (!jumpTargets.contains(targetFile) && targetFile != fileName) {
              jumpTargets.add(targetFile);
            }
          }
        }
      }
    }

    // 添加文件结束标记
    mergedChildren.add(CommentNode('=== 文件 $fileName 结束 ==='));

    // 递归处理所有被 jump 的文件
    for (final targetFile in jumpTargets) {
      await _mergeFileRecursively(targetFile, mergedChildren, processedFiles);
    }
  }

  /// 递归查找脚本中的所有跳转目标（保留用于其他可能的用途）
  void _findJumpTargets(ScriptNode script, Set<String> targets) {
    for (final node in script.children) {
      if (node is JumpNode) {
        targets.add(node.targetLabel);
      } else if (node is MenuNode) {
        for (final option in node.choices) {
          targets.add(option.targetLabel);
        }
      }
    }
  }

  /// 深拷贝节点
  SksNode _cloneNode(SksNode node) {
    // 这里简化实现，实际中可能需要更完整的克隆逻辑
    return node;
  }

  /// 将节点转换为可读的字符串（调试用）
  String _nodeToString(SksNode node) {
    if (node is CommentNode) {
      return 'Comment: ${node.comment}';
    } else if (node is LabelNode) {
      return 'Label: ${node.name}';
    } else if (node is SayNode) {
      final speaker = node.character != null ? '${node.character}: ' : '';
      return 'Say: $speaker"${node.dialogue}"';
    } else if (node is BackgroundNode) {
      return 'Background: ${node.background}';
    } else if (node is CanvasNode) {
      return 'Canvas: ${node.canvasId}';
    } else if (node is HideCanvasNode) {
      return 'Canvas: hidden';
    } else if (node is ShowNode) {
      return 'Show: ${node.character} (${node.pose ?? 'default'}, ${node.expression ?? 'default'})';
    } else if (node is CgNode) {
      return 'CG: ${node.character} (${node.pose ?? 'default'}, ${node.expression ?? 'default'})';
    } else if (node is HideNode) {
      return 'Hide: ${node.character}${node.immediate ? ' (immediate)' : ''}';
    } else if (node is JumpNode) {
      return 'Jump: ${node.targetLabel}';
    } else if (node is MenuNode) {
      return 'Menu: ${node.choices.length} choices';
    } else if (node is ReturnNode) {
      return 'Return';
    } else if (node is NvlNode) {
      return 'NVL: Start';
    } else if (node is NvlMovieNode) {
      return 'NVLM: Start';
    } else if (node is EndNvlNode) {
      return 'NVL: End';
    } else if (node is EndNvlMovieNode) {
      return 'NVLM: End';
    } else {
      return 'Unknown: ${node.runtimeType}';
    }
  }

  /// 获取指定文件在合并脚本中的起始索引
  int? getFileStartIndex(String fileName) {
    return _fileStartIndices[fileName];
  }

  /// 获取所有文件的起始索引映射
  Map<String, int> get fileStartIndices => Map.unmodifiable(_fileStartIndices);

  Map<String, int> get nativeLabelIndices =>
      Map.unmodifiable(_nativeRuntimeIndex?.labelIndices ?? const {});

  NativeRuntimeIndex? get nativeRuntimeIndex => _nativeRuntimeIndex;

  /// 根据合并脚本中的索引找到对应的原始文件名
  String? getFileNameByIndex(int index) {
    String? result;
    int maxStartIndex = -1;

    for (final entry in _fileStartIndices.entries) {
      if (entry.value <= index && entry.value > maxStartIndex) {
        maxStartIndex = entry.value;
        result = entry.key;
      }
    }

    return result;
  }

  /// 清理缓存，强制重新合并
  void clearCache() {
    _nativeRuntimeIndex?.dispose();
    _sharedMergedScript = null;
    _sharedFileStartIndices = const {};
    _sharedGlobalLabelMap = const {};
    _mergedScript = null;
    _loadedScripts.clear();
    _fileStartIndices.clear();
    _globalLabelMap.clear();
    _nativeRuntimeIndex = null;
  }
}
