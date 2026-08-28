#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.dirname(__dirname);
const destination = path.join(repoRoot, 'third_party', 'erika_flutter');

function fail(message) {
  throw new Error(`Erika vendoring: ${message}`);
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const value = argv[++index];
    if (!value || !key.startsWith('--')) fail(`无效参数: ${key}`);
    parsed[key.slice(2)] = path.resolve(value);
  }
  for (const required of ['source', 'erika-root', 'macos-runtime', 'windows-runtime']) {
    if (!parsed[required]) fail(`缺少 --${required}`);
  }
  return parsed;
}

function copyDirectory(source, target) {
  fs.mkdirSync(target, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name);
    const to = path.join(target, entry.name);
    if (entry.isDirectory()) copyDirectory(from, to);
    else if (entry.isFile()) {
      fs.copyFileSync(from, to);
      fs.chmodSync(to, fs.statSync(from).mode);
    }
  }
}

function copyItem(sourceRoot, relative) {
  const source = path.join(sourceRoot, relative);
  const target = path.join(destination, relative);
  if (!fs.existsSync(source)) fail(`源文件不存在: ${source}`);
  if (fs.statSync(source).isDirectory()) copyDirectory(source, target);
  else {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(source, target);
    fs.chmodSync(target, fs.statSync(source).mode);
  }
}

function sha256(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function requireBinarySymbol(filePath, symbol) {
  const binary = fs.readFileSync(filePath);
  if (!binary.includes(Buffer.from(symbol, 'ascii'))) {
    fail(`原生运行库缺少必需导出 ${symbol}: ${filePath}`);
  }
}

function patchMacosPodspec(expectedSha256) {
  const podspecPath = path.join(destination, 'macos', 'erika_flutter.podspec');
  const podspec = fs.readFileSync(podspecPath, 'utf8');
  const prebuiltBranch = /elif \[ "\$USE_SOURCE_BUILD" != "1" \]; then\n\s+sh "\$PACKAGE_ROOT\/native\/prepare_apple_prebuilt\.sh"\s+macos macos "\$PREBUILT_ARCH" "\$DEST_DYLIB"\nelse/;
  if (!prebuiltBranch.test(podspec)) {
    fail('无法定位 macOS podspec 的预构建下载分支');
  }
  const offlineBranch = `elif [ "$USE_SOURCE_BUILD" != "1" ]; then
  SOURCE_DYLIB="$PACKAGE_ROOT/native/macos/liberika_capi.dylib"
  if [ ! -f "$SOURCE_DYLIB" ]; then
    echo "error: bundled Erika runtime is missing: $SOURCE_DYLIB" >&2
    exit 1
  fi
  ACTUAL_SHA256="$(shasum -a 256 "$SOURCE_DYLIB" | awk '{print $1}')"
  if [ "$ACTUAL_SHA256" != "${expectedSha256}" ]; then
    echo "error: bundled Erika runtime checksum mismatch" >&2
    exit 1
  fi
else`;
  fs.writeFileSync(podspecPath, podspec.replace(prebuiltBranch, offlineBranch));
}

function patchWindowsRuntimeBuild(expectedSha256) {
  const cmakePath = path.join(destination, 'windows', 'build_erika_runtime.cmake');
  const cmake = fs.readFileSync(cmakePath, 'utf8');
  const marker = 'set(ERIKA_ARTIFACT_MANIFEST\n';
  const index = cmake.indexOf(marker);
  if (index < 0) fail('无法定位 Windows Erika runtime 构建入口');
  const offlineBranch = `if(NOT "$ENV{ERIKA_FORCE_SOURCE_BUILD}" STREQUAL "1")
  if(ERIKA_NATIVE_TARGET STREQUAL "x86_64-pc-windows-msvc")
    set(ERIKA_BUNDLED_RUNTIME
      "\${ERIKA_PACKAGE_ROOT}/native/windows/x64/erika_capi.dll")
    set(ERIKA_BUNDLED_SHA256 "${expectedSha256}")
  else()
    set(ERIKA_BUNDLED_RUNTIME
      "\${ERIKA_PACKAGE_ROOT}/native/windows/arm64/erika_capi.dll")
    set(ERIKA_BUNDLED_SHA256 "")
  endif()
  if(NOT EXISTS "\${ERIKA_BUNDLED_RUNTIME}")
    message(FATAL_ERROR
      "Bundled Erika runtime is missing: \${ERIKA_BUNDLED_RUNTIME}. "
      "SakiEngine desktop builds never download native binaries.")
  endif()
  file(SHA256 "\${ERIKA_BUNDLED_RUNTIME}" ERIKA_BUNDLED_ACTUAL_SHA256)
  if(ERIKA_BUNDLED_SHA256 STREQUAL "" OR
      NOT ERIKA_BUNDLED_ACTUAL_SHA256 STREQUAL ERIKA_BUNDLED_SHA256)
    message(FATAL_ERROR "Bundled Erika runtime checksum mismatch")
  endif()
  get_filename_component(ERIKA_RUNTIME_DIR "\${ERIKA_RUNTIME_OUT}" DIRECTORY)
  file(MAKE_DIRECTORY "\${ERIKA_RUNTIME_DIR}")
  configure_file("\${ERIKA_BUNDLED_RUNTIME}" "\${ERIKA_RUNTIME_OUT}" COPYONLY)
  message(STATUS "Erika: using bundled offline runtime -> \${ERIKA_RUNTIME_OUT}")
  return()
endif()

`;
  fs.writeFileSync(cmakePath, `${cmake.slice(0, index)}${offlineBranch}${cmake.slice(index)}`);
}

function gitRevision(erikaRoot) {
  const result = spawnSync('git', ['-C', erikaRoot, 'rev-parse', 'HEAD'], {
    encoding: 'utf8',
  });
  if (result.status !== 0) fail('无法读取 Erika Git revision');
  return result.stdout.trim();
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  requireBinarySymbol(
    args['macos-runtime'],
    'erika_presenter_attach_flutter_texture',
  );
  requireBinarySymbol(
    args['windows-runtime'],
    'erika_presenter_windows_composition_swapchain_iunknown',
  );
  const items = [
    'CHANGELOG.md',
    'LICENSE',
    'README.md',
    'README.ja.md',
    'README.zh.md',
    'pubspec.yaml',
    'native_artifacts.properties',
    'android',
    'ios',
    'lib',
    'macos',
    'ohos',
    'tvos',
    'windows',
    'native/include',
  ];

  fs.rmSync(destination, { recursive: true, force: true });
  for (const item of items) copyItem(args.source, item);
  fs.rmSync(path.join(destination, 'tvos', 'native'), { recursive: true, force: true });

  const macosTarget = path.join(destination, 'native', 'macos', 'liberika_capi.dylib');
  const windowsTarget = path.join(
    destination,
    'native',
    'windows',
    'x64',
    'erika_capi.dll',
  );
  fs.mkdirSync(path.dirname(macosTarget), { recursive: true });
  fs.mkdirSync(path.dirname(windowsTarget), { recursive: true });
  fs.copyFileSync(args['macos-runtime'], macosTarget);
  fs.copyFileSync(args['windows-runtime'], windowsTarget);

  const licensesTarget = path.join(destination, 'native', 'licenses');
  fs.mkdirSync(licensesTarget, { recursive: true });
  for (const entry of fs.readdirSync(path.join(args['erika-root'], 'packaging'))) {
    if (entry === 'THIRD_PARTY_NOTICES.md' || entry.startsWith('LICENSE.')) {
      fs.copyFileSync(
        path.join(args['erika-root'], 'packaging', entry),
        path.join(licensesTarget, entry),
      );
    }
  }

  patchMacosPodspec(sha256(macosTarget));
  patchWindowsRuntimeBuild(sha256(windowsTarget));
  const provenance = {
    schemaVersion: 1,
    packageVersion:
      fs.readFileSync(path.join(destination, 'pubspec.yaml'), 'utf8')
        .match(/^version:\s*(.+)$/m)?.[1]?.trim() || 'unknown',
    erikaRevision: gitRevision(args['erika-root']),
    runtimes: {
      macosUniversal: {
        path: 'native/macos/liberika_capi.dylib',
        sha256: sha256(macosTarget),
      },
      windowsX64: {
        path: 'native/windows/x64/erika_capi.dll',
        sha256: sha256(windowsTarget),
      },
    },
  };
  fs.writeFileSync(
    path.join(destination, 'VENDORED_FROM.json'),
    `${JSON.stringify(provenance, null, 2)}\n`,
  );
  process.stdout.write(`已内嵌 Erika Flutter 桥接层: ${destination}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
