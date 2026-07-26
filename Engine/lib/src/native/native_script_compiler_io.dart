import 'package:saki_native/saki_native.dart';
import 'package:sakiengine/src/native/saki_native_runtime.dart';

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
  if (!await SakiNativeRuntime.ensureInitialized()) {
    return null;
  }
  try {
    final result = await compileSksSources(
      sources: [
        for (final source in sources)
          RustScriptSource(fileName: source.fileName, content: source.content),
      ],
    );
    return NativeCompiledScripts(
      mergedSource: result.mergedSource,
      orderedFiles: result.orderedFiles,
      elapsedMicros: result.elapsedMicros.toInt(),
      diagnostics: [
        for (final diagnostic in result.diagnostics)
          '${diagnostic.severity}: ${diagnostic.fileName}:'
              '${diagnostic.sourceLine} ${diagnostic.message}',
      ],
    );
  } catch (error, stackTrace) {
    print('[SAKI_NATIVE][SKS] compile failed; Dart fallback enabled: $error');
    print(stackTrace);
    return null;
  }
}
