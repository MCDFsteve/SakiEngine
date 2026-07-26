import 'dart:io';

import 'package:saki_save_index/saki_save_index.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/benchmark.dart <save-directory>');
    exitCode = 64;
    return;
  }

  final stopwatch = Stopwatch()..start();
  final result = await scanSakiSaveHeaders(arguments.single);
  stopwatch.stop();

  stdout.writeln(
    'slots=${result.slots.length} '
    'native_ms=${(result.elapsedMicros / 1000).toStringAsFixed(3)} '
    'total_ms=${(stopwatch.elapsedMicroseconds / 1000).toStringAsFixed(3)} '
    'invalid=${result.invalidFiles.length}',
  );
  for (final slot in result.slots) {
    stdout.writeln(
      'slot=${slot.id} version=${slot.version} '
      'screenshot=${slot.screenshotLength ?? 0} '
      'preview=${slot.previewKind}',
    );
  }
  for (final invalidFile in result.invalidFiles) {
    stderr.writeln(invalidFile);
  }
}
