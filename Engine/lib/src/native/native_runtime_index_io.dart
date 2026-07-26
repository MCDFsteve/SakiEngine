import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/native/saki_native_runtime.dart';
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
  ) {
    final result = runtimeSeekMenu(
      handle: handle,
      startIndex: startIndex,
      boolVariables: boolVariables,
      maxSteps: 100000,
    );
    return NativeMenuSeekResult(
      found: result.found,
      menuIndex: result.menuIndex,
      prompts: [
        for (final prompt in result.prompts)
          NativeRuntimePrompt(
            dialogue: prompt.dialogue,
            character: prompt.speaker,
            dialogueTag: prompt.dialogueTag,
            scriptIndex: prompt.scriptIndex,
            sourceFile: prompt.sourceFile,
            sourceLine: prompt.sourceLine,
          ),
      ],
    );
  }

  void dispose() {
    closeScriptRuntime(handle: handle);
  }
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
) async {
  if (!await SakiNativeRuntime.ensureInitialized()) {
    return null;
  }
  try {
    final descriptors = <RustRuntimeNode>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      String? kind;
      String? value;
      var choices = const <RustRuntimeChoice>[];
      if (node is LabelNode) {
        kind = 'label';
        value = node.name;
      } else if (node is BackgroundNode) {
        kind = 'background';
        value = node.background;
      } else if (node is MenuNode) {
        kind = 'menu';
        choices = [
          for (final choice in node.choices)
            RustRuntimeChoice(
              text: choice.text,
              targetLabel: choice.targetLabel,
            ),
        ];
      } else if (node is JumpNode) {
        kind = 'jump';
        value = node.targetLabel;
      } else if (node is ReturnNode) {
        kind = 'return';
      } else if (node is SayNode) {
        kind = 'say';
        value = node.dialogue;
      } else if (node is ConditionalSayNode) {
        kind = 'conditional_say';
        value = node.dialogue;
      }
      if (kind != null) {
        descriptors.add(
          RustRuntimeNode(
            scriptIndex: index,
            kind: kind,
            value: value,
            secondary: node is SayNode
                ? node.character
                : node is ConditionalSayNode
                ? node.character
                : null,
            dialogueTag: node is SayNode
                ? node.dialogueTag
                : node is ConditionalSayNode
                ? node.dialogueTag
                : null,
            sourceFile: node is SayNode
                ? node.sourceFile
                : node is ConditionalSayNode
                ? node.sourceFile
                : null,
            sourceLine: node is SayNode
                ? node.sourceLine
                : node is ConditionalSayNode
                ? node.sourceLine
                : null,
            conditionVariable: node is JumpNode
                ? node.conditionVariable
                : node is ConditionalSayNode
                ? node.conditionVariable
                : null,
            conditionValue: node is JumpNode
                ? node.conditionValue
                : node is ConditionalSayNode
                ? node.conditionValue
                : null,
            choices: choices,
          ),
        );
      }
    }

    final result = await buildRuntimeIndex(nodes: descriptors);
    return NativeRuntimeIndex(
      labelIndices: {
        for (final entry in result.labels)
          entry.label: entry.scriptIndex.toInt(),
      },
      flowNodes: [
        for (final node in result.flowNodes)
          NativeRuntimeFlowNode(
            id: node.id,
            label: node.label,
            kind: node.kind,
            displayName: node.displayName,
            scriptIndex: node.scriptIndex.toInt(),
            chapterName: node.chapterName,
            parentId: node.parentId,
            childIds: node.childIds,
            branchText: node.branchText,
            parentIds: node.parentIds,
          ),
      ],
      rootIds: result.rootIds,
      compactBytes: result.compactBytes.toInt(),
      elapsedMicros: result.elapsedMicros.toInt(),
      handle: result.handle,
      conditionVariables: result.conditionVariables,
    );
  } catch (error, stackTrace) {
    print('[SAKI_NATIVE][RUNTIME] index failed; Dart fallback enabled: $error');
    print(stackTrace);
    return null;
  }
}
