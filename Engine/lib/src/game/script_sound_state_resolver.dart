import 'package:sakiengine/src/sks_parser/sks_ast.dart';

/// Resolves the looped sound effects that should still be active immediately
/// before [scriptIndex] executes.
///
/// One-shot sound effects are intentionally excluded: restoring history should
/// never replay a transient cue. `stop sound` clears every active loop because
/// the runtime sound channel uses the same semantics.
class ScriptSoundStateResolver {
  const ScriptSoundStateResolver._();

  static List<String> resolveLoopingSoundFiles(
    ScriptNode script,
    int scriptIndex,
  ) {
    final endExclusive = scriptIndex.clamp(0, script.children.length).toInt();
    final activeSounds = <String>{};

    for (var index = 0; index < endExclusive; index++) {
      final node = script.children[index];
      if (node is StopSoundNode) {
        activeSounds.clear();
      } else if (node is PlaySoundNode && node.loop) {
        // Repeating the same ambience represents one active authored sound,
        // not multiple copies that should be stacked during restoration.
        activeSounds
          ..remove(node.soundFile)
          ..add(node.soundFile);
      }
    }

    return List<String>.unmodifiable(activeSounds);
  }
}
