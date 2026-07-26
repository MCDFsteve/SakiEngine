class NativeScriptSource {
  final String fileName;
  final String content;

  const NativeScriptSource({required this.fileName, required this.content});
}

class NativeCompiledScripts {
  final String mergedSource;
  final List<String> orderedFiles;
  final int elapsedMicros;
  final List<String> diagnostics;

  const NativeCompiledScripts({
    required this.mergedSource,
    required this.orderedFiles,
    required this.elapsedMicros,
    required this.diagnostics,
  });
}

Future<NativeCompiledScripts?> compileScriptsNatively(
  List<NativeScriptSource> sources,
) async {
  return null;
}
