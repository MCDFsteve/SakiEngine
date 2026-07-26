import 'package:sakiengine/src/sks_parser/sks_ast.dart';

class NativeRuntimeFlowNode {
  const NativeRuntimeFlowNode({
    required this.id,
    required this.label,
    required this.kind,
    required this.displayName,
    required this.scriptIndex,
    required this.chapterName,
    required this.parentId,
    required this.childIds,
    required this.branchText,
    required this.parentIds,
  });

  final String id;
  final String label;
  final String kind;
  final String displayName;
  final int scriptIndex;
  final String? chapterName;
  final String? parentId;
  final List<String> childIds;
  final String? branchText;
  final List<String> parentIds;
}

class NativeRuntimeIndex {
  const NativeRuntimeIndex({
    required this.labelIndices,
    required this.flowNodes,
    required this.rootIds,
    required this.compactBytes,
    required this.elapsedMicros,
    required this.handle,
    required this.conditionVariables,
  });

  final Map<String, int> labelIndices;
  final List<NativeRuntimeFlowNode> flowNodes;
  final List<String> rootIds;
  final int compactBytes;
  final int elapsedMicros;
  final BigInt handle;
  final List<String> conditionVariables;

  NativeMenuSeekResult seekMenu(
    int startIndex,
    Map<String, bool> boolVariables,
  ) => const NativeMenuSeekResult(found: false, menuIndex: null, prompts: []);

  void dispose() {}
}

class NativeRuntimePrompt {
  const NativeRuntimePrompt({
    required this.dialogue,
    required this.character,
    required this.dialogueTag,
    required this.scriptIndex,
    required this.sourceFile,
    required this.sourceLine,
  });

  final String dialogue;
  final String? character;
  final String? dialogueTag;
  final int scriptIndex;
  final String? sourceFile;
  final int? sourceLine;
}

class NativeMenuSeekResult {
  const NativeMenuSeekResult({
    required this.found,
    required this.menuIndex,
    required this.prompts,
  });

  final bool found;
  final int? menuIndex;
  final List<NativeRuntimePrompt> prompts;
}

Future<NativeRuntimeIndex?> buildRuntimeIndexNatively(
  List<SksNode> nodes,
) async => null;
