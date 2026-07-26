import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

const _assetName = 'saki_save_index.dart';
const _libraryName = 'saki_save_index';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final code = input.config.code;
    if (code.targetOS != OS.macOS) {
      // SakiEngine keeps its existing Dart implementation as the fallback on
      // platforms where this focused native indexer is not built yet.
      return;
    }

    final rustTarget = switch (code.targetArchitecture) {
      Architecture.arm64 => 'aarch64-apple-darwin',
      Architecture.x64 => 'x86_64-apple-darwin',
      _ => throw UnsupportedError(
        'Unsupported macOS Rust architecture: ${code.targetArchitecture}',
      ),
    };

    final manifest = input.packageRoot.resolve('rust/Cargo.toml');
    final rustSource = input.packageRoot.resolve('rust/src/lib.rs');
    final targetDirectory = input.outputDirectoryShared.resolve('rust-target/');

    await Directory.fromUri(targetDirectory).create(recursive: true);

    final result = await Process.run('cargo', <String>[
      'build',
      '--manifest-path',
      manifest.toFilePath(),
      '--release',
      '--target',
      rustTarget,
      '--target-dir',
      targetDirectory.toFilePath(),
    ], workingDirectory: input.packageRoot.toFilePath());

    if (result.exitCode != 0) {
      throw StateError(
        'Rust save index build failed (${result.exitCode}).\n'
        '${result.stdout}\n${result.stderr}',
      );
    }

    final library = targetDirectory.resolve(
      '$rustTarget/release/lib$_libraryName.dylib',
    );
    if (!File.fromUri(library).existsSync()) {
      throw StateError('Rust save index library was not produced: $library');
    }

    output.dependencies
      ..add(manifest)
      ..add(rustSource);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        file: library,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}
