#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.dirname(__dirname);
const manifestPath = path.join(repoRoot, 'toolchains', 'cross', 'manifest.json');

function fail(message) {
  throw new Error(`SakiEngine 交叉编译: ${message}`);
}

function sanitizeBinaryName(value) {
  return String(value || '')
    .replace(/[^A-Za-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '') || 'saki_game';
}

function readGameIdentity(gameDir) {
  const configPath = path.join(gameDir, 'game_config.txt');
  if (!fs.existsSync(configPath)) {
    return {
      appName: path.basename(gameDir),
      applicationId: 'com.sakiengine.game',
      binaryName: sanitizeBinaryName(path.basename(gameDir)),
    };
  }
  const lines = fs
    .readFileSync(configPath, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const appName = lines[0] || path.basename(gameDir);
  return {
    appName,
    applicationId: lines[1] || 'com.sakiengine.game',
    binaryName: sanitizeBinaryName(appName),
  };
}

function resolveExecutable(command) {
  if (!command) return null;
  const hasSeparator = command.includes('/') || command.includes('\\');
  if (hasSeparator) {
    const absolute = path.resolve(command);
    return fs.existsSync(absolute) ? fs.realpathSync(absolute) : null;
  }
  const result = spawnSync('which', [command], { encoding: 'utf8' });
  if (result.status !== 0) return null;
  const candidate = String(result.stdout || '').split(/\r?\n/).find(Boolean);
  return candidate && fs.existsSync(candidate) ? fs.realpathSync(candidate) : null;
}

function resolveFlutter(flutterBin = process.env.SAKI_FLUTTER_BIN || 'flutter') {
  const executable = resolveExecutable(flutterBin);
  if (!executable) {
    fail('未找到 Flutter。请先安装项目要求的 Flutter SDK；交叉目标包不会联网下载 SDK。');
  }
  const flutterRoot = path.dirname(path.dirname(executable));
  const engineStamp = path.join(flutterRoot, 'bin', 'cache', 'engine.stamp');
  if (!fs.existsSync(engineStamp)) {
    fail(`Flutter Engine 标记不存在: ${engineStamp}`);
  }
  return {
    executable,
    flutterRoot,
    engineRevision: fs.readFileSync(engineStamp, 'utf8').trim(),
  };
}

function readManifest(filePath = manifestPath) {
  if (!fs.existsSync(filePath)) {
    fail(`仓库内置目标包清单不存在: ${filePath}`);
  }
  const manifest = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  if (manifest.schemaVersion !== 1 || !manifest.targets || !manifest.engineRevision) {
    fail(`目标包清单格式无效: ${filePath}`);
  }
  return manifest;
}

function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(filePath, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    while (true) {
      const read = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (read === 0) break;
      hash.update(buffer.subarray(0, read));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}

function verifyEmbeddedFiles(manifest, targetConfig) {
  const required = new Set([
    manifest.snapshotter,
    ...Object.keys(manifest.checksums || {}).filter((relative) =>
      relative.startsWith(`${targetConfig.template}/`),
    ),
  ]);
  if (required.size < 2) {
    fail('目标包校验清单为空；拒绝使用未校验的二进制。');
  }
  for (const relative of required) {
    const absolute = path.join(repoRoot, relative);
    if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
      fail(`内置二进制缺失: ${relative}`);
    }
    const expected = manifest.checksums[relative];
    if (!expected) {
      fail(`内置二进制没有 SHA-256: ${relative}`);
    }
    const actual = sha256File(absolute);
    if (actual !== expected) {
      fail(`内置二进制校验失败: ${relative}`);
    }
  }
}

function copyDirectory(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  const entries = fs.readdirSync(source, { withFileTypes: true });
  for (const entry of entries) {
    const from = path.join(source, entry.name);
    const to = path.join(destination, entry.name);
    if (entry.isDirectory()) {
      copyDirectory(from, to);
    } else if (entry.isSymbolicLink()) {
      fs.symlinkSync(fs.readlinkSync(from), to);
    } else if (entry.isFile()) {
      fs.copyFileSync(from, to);
      fs.chmodSync(to, fs.statSync(from).mode);
    }
  }
}

function nativePluginsFor(gameDir, target) {
  const dependenciesPath = path.join(gameDir, '.flutter-plugins-dependencies');
  if (!fs.existsSync(dependenciesPath)) {
    fail('缺少 .flutter-plugins-dependencies；请先执行 flutter pub get。');
  }
  const dependencies = JSON.parse(fs.readFileSync(dependenciesPath, 'utf8'));
  const plugins = dependencies.plugins && dependencies.plugins[target];
  if (!Array.isArray(plugins)) return [];
  return plugins
    .filter((plugin) => plugin && plugin.native_build === true && plugin.dev_dependency !== true)
    .map((plugin) => plugin.name)
    .sort();
}

function validatePluginProfile(gameDir, target, targetConfig) {
  const available = new Set(targetConfig.nativePlugins || []);
  const required = nativePluginsFor(gameDir, target);
  const missing = required.filter((name) => !available.has(name));
  if (missing.length > 0) {
    fail(
      `${target} 游戏包含目标包未预构建的原生插件: ${missing.join(', ')}。` +
        '请重新运行仓库的离线目标包工作流。',
    );
  }
}

function run(executable, args, cwd, env = process.env) {
  const result = spawnSync(executable, args, {
    cwd,
    env,
    stdio: 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    fail(`命令失败 (${result.status}): ${executable} ${args.join(' ')}`);
  }
}

function writeLinuxCompilerProbe(outputDir) {
  const find = (tool) => {
    const result = spawnSync('xcrun', ['-f', tool], { encoding: 'utf8' });
    if (result.status !== 0) fail(`xcrun 无法找到 ${tool}`);
    return String(result.stdout).trim();
  };
  const cacheDir = path.join(outputDir, 'linux', 'x64', 'release');
  fs.mkdirSync(cacheDir, { recursive: true });
  fs.writeFileSync(
    path.join(cacheDir, 'CMakeCache.txt'),
    [
      `CMAKE_AR:FILEPATH=${find('ar')}`,
      `CMAKE_CXX_COMPILER:FILEPATH=${find('clang++')}`,
      `CMAKE_LINKER:FILEPATH=${find('ld')}`,
      '',
    ].join('\n'),
  );
}

function withFlutterOverlay(flutter, manifest, target, callback) {
  const engineCache = path.join(flutter.flutterRoot, 'bin', 'cache');
  const snapshotDestination = path.join(
    engineCache,
    'artifacts',
    'engine',
    manifest.flutterSnapshotDirectory,
    'gen_snapshot',
  );
  const stampPath = path.join(engineCache, `${target}-sdk.stamp`);
  const sourceSnapshot = path.join(repoRoot, manifest.snapshotter);
  const backups = [];

  const overlay = (destination, sourceBuffer, mode) => {
    const existed = fs.existsSync(destination);
    backups.push({
      destination,
      existed,
      contents: existed ? fs.readFileSync(destination) : null,
      mode: existed ? fs.statSync(destination).mode : null,
    });
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, sourceBuffer);
    if (mode) fs.chmodSync(destination, mode);
  };

  overlay(snapshotDestination, fs.readFileSync(sourceSnapshot), 0o755);
  overlay(stampPath, Buffer.from(`${manifest.engineRevision}\n`, 'utf8'));
  try {
    return callback();
  } finally {
    for (const backup of backups.reverse()) {
      if (backup.existed) {
        fs.writeFileSync(backup.destination, backup.contents);
        if (backup.mode) fs.chmodSync(backup.destination, backup.mode);
      } else {
        fs.rmSync(backup.destination, { force: true });
      }
    }
  }
}

function stageBundle({ gameDir, target, targetConfig, buildDir, identity }) {
  const outputDir = path.join(gameDir, targetConfig.output);
  const stagingDir = `${outputDir}.saki-staging-${process.pid}`;
  fs.rmSync(stagingDir, { recursive: true, force: true });
  copyDirectory(path.join(repoRoot, targetConfig.template), stagingDir);

  const flutterAssets = path.join(buildDir, 'flutter_assets');
  const appSo = path.join(buildDir, 'app.so');
  if (!fs.existsSync(flutterAssets) || !fs.existsSync(appSo)) {
    fail('Flutter AOT 输出不完整（缺少 flutter_assets 或 app.so）。');
  }
  copyDirectory(flutterAssets, path.join(stagingDir, targetConfig.assetsDestination));
  const aotDestination = path.join(stagingDir, targetConfig.aotDestination);
  fs.mkdirSync(path.dirname(aotDestination), { recursive: true });
  fs.copyFileSync(appSo, aotDestination);

  const originalRunner = path.join(stagingDir, targetConfig.runnerExecutable);
  const runnerName = target === 'windows' ? `${identity.binaryName}.exe` : identity.binaryName;
  const finalRunner = path.join(stagingDir, runnerName);
  if (!fs.existsSync(originalRunner)) {
    fail(`Runner 模板入口不存在: ${targetConfig.runnerExecutable}`);
  }
  if (originalRunner !== finalRunner) fs.renameSync(originalRunner, finalRunner);
  if (target !== 'windows') fs.chmodSync(finalRunner, 0o755);

  fs.writeFileSync(path.join(stagingDir, 'saki_product_name.txt'), `${identity.appName}\n`);
  fs.writeFileSync(path.join(stagingDir, 'saki_application_id.txt'), `${identity.applicationId}\n`);

  fs.rmSync(outputDir, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(outputDir), { recursive: true });
  fs.renameSync(stagingDir, outputDir);
  return outputDir;
}

function buildCrossDesktop({
  gameDir,
  target,
  dartDefines = [],
  flutterBin = process.env.SAKI_FLUTTER_BIN || 'flutter',
}) {
  if (process.platform !== 'darwin') {
    fail('当前离线交叉目标包只支持 macOS 主机。');
  }
  if (target !== 'linux' && target !== 'windows') {
    fail(`不支持的交叉目标: ${target}`);
  }
  const absoluteGameDir = path.resolve(gameDir);
  if (!fs.existsSync(path.join(absoluteGameDir, 'pubspec.yaml'))) {
    fail(`无效 Flutter 游戏目录: ${absoluteGameDir}`);
  }

  const manifest = readManifest();
  const targetConfig = manifest.targets[target];
  if (!targetConfig) fail(`仓库没有内置 ${target} 目标包。`);
  const flutter = resolveFlutter(flutterBin);
  if (flutter.engineRevision !== manifest.engineRevision) {
    fail(
      `Flutter Engine 版本不匹配。需要 ${manifest.flutterVersion} ` +
        `(${manifest.engineRevision})，当前为 ${flutter.engineRevision}。`,
    );
  }
  verifyEmbeddedFiles(manifest, targetConfig);
  validatePluginProfile(absoluteGameDir, target, targetConfig);

  const targetPlatform = targetConfig.targetPlatform;
  const assembleOutput = path.join(
    absoluteGameDir,
    '.saki_cache',
    'cross',
    targetPlatform,
  );
  fs.rmSync(assembleOutput, { recursive: true, force: true });
  fs.mkdirSync(assembleOutput, { recursive: true });
  if (target === 'linux') writeLinuxCompilerProbe(assembleOutput);

  const env = {
    ...process.env,
    SAKI_CROSS_OFFLINE: '1',
    FLUTTER_DISABLE_ANALYTICS: 'true',
    // A missing embedded artifact must fail instead of silently reaching the network.
    FLUTTER_STORAGE_BASE_URL: 'https://127.0.0.1:9',
  };
  if (target === 'windows' && !env['PROGRAMFILES(X86)']) {
    const emptyProgramFiles = path.join(repoRoot, '.saki_toolchain', 'empty-program-files-x86');
    fs.mkdirSync(emptyProgramFiles, { recursive: true });
    env['PROGRAMFILES(X86)'] = emptyProgramFiles;
  }
  const args = [
    '--no-version-check',
    '--suppress-analytics',
    'assemble',
    `--output=${assembleOutput}`,
    `-dTargetPlatform=${targetPlatform}`,
    '-dBuildMode=release',
    '-dTargetFile=lib/main.dart',
    '-dTrackWidgetCreation=false',
    '-dTreeShakeIcons=true',
    '-dDartObfuscation=false',
    ...dartDefines.map((value) => `--dart-define=${value}`),
    'copy_assets',
    'aot_elf_release',
  ];

  withFlutterOverlay(flutter, manifest, target, () => {
    run(flutter.executable, args, absoluteGameDir, env);
  });

  const buildIdPath = path.join(assembleOutput, '.last_build_id');
  if (!fs.existsSync(buildIdPath)) fail('Flutter 没有写入 .last_build_id。');
  const buildId = fs.readFileSync(buildIdPath, 'utf8').trim();
  const flutterBuildDir = path.join(absoluteGameDir, '.dart_tool', 'flutter_build', buildId);
  const identity = readGameIdentity(absoluteGameDir);
  const outputDir = stageBundle({
    gameDir: absoluteGameDir,
    target,
    targetConfig,
    buildDir: flutterBuildDir,
    identity,
  });
  process.stdout.write(`SakiEngine 离线交叉构建完成: ${outputDir}\n`);
  return outputDir;
}

function parseCli(argv) {
  const parsed = { dartDefines: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--game-dir') parsed.gameDir = argv[++index];
    else if (arg === '--target') parsed.target = argv[++index];
    else if (arg === '--flutter') parsed.flutterBin = argv[++index];
    else if (arg === '--dart-define') parsed.dartDefines.push(argv[++index]);
    else fail(`未知参数: ${arg}`);
  }
  if (!parsed.gameDir || !parsed.target) {
    fail('用法: node scripts/cross-desktop.js --game-dir <目录> --target <linux|windows>');
  }
  return parsed;
}

if (require.main === module) {
  try {
    buildCrossDesktop(parseCli(process.argv.slice(2)));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}

module.exports = {
  buildCrossDesktop,
  nativePluginsFor,
  readGameIdentity,
  sanitizeBinaryName,
  sha256File,
  validatePluginProfile,
};
