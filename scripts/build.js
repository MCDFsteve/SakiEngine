#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');

const assetUtils = require('./asset-utils.js');
const { buildCrossDesktop } = require('./cross-desktop.js');

const colors = {
  reset: '\x1b[0m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
};

function colorLog(message, color = 'reset') {
  process.stdout.write(`${colors[color] || colors.reset}${message}${colors.reset}\n`);
}

const projectRoot = path.dirname(__dirname);
const defaultGameFile = path.join(projectRoot, 'default_game.txt');

const supportedPlatforms = new Set(['macos', 'linux', 'windows', 'android', 'ios', 'web']);

function isWindowsBatchExecutable(executable) {
  return process.platform === 'win32' && /\.(bat|cmd)$/i.test(String(executable || ''));
}

function quoteCmdArg(value) {
  const text = String(value ?? '');
  if (text.length === 0) return '""';
  if (/[\s"&|<>^()]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
  return text;
}

function spawnCompat(executable, args, options) {
  const safeArgs = Array.isArray(args) ? args : [];
  if (isWindowsBatchExecutable(executable)) {
    const commandLine = [quoteCmdArg(executable), ...safeArgs.map(quoteCmdArg)].join(' ');
    return spawnSync('cmd.exe', ['/d', '/s', '/c', commandLine], options);
  }
  return spawnSync(executable, safeArgs, options);
}

function detectHostPlatform() {
  switch (os.platform()) {
    case 'darwin':
      return 'macos';
    case 'linux':
      return 'linux';
    case 'win32':
      return 'windows';
    default:
      return 'unknown';
  }
}

function platformDisplayName(platform) {
  switch (platform) {
    case 'macos':
      return 'macOS';
    case 'linux':
      return 'Linux';
    case 'windows':
      return 'Windows';
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    case 'web':
      return 'Web';
    default:
      return platform;
  }
}

function runCommand(executable, args, cwd) {
  const result = spawnCompat(executable, args, {
    cwd,
    env: process.env,
    stdio: 'inherit',
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`命令执行失败: ${executable} ${args.join(' ')}`);
  }
}

function runFlutter(args, cwd) {
  const flutter = process.env.SAKI_FLUTTER_BIN || 'flutter';
  runCommand(flutter, args, cwd);
}

function normalizeRelPath(rel) {
  return rel.split(path.sep).join('/');
}

function walkFilesSorted(dir) {
  const result = [];
  function walk(current) {
    const entries = fs.readdirSync(current, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile()) {
        result.push(full);
      }
    }
  }
  walk(dir);
  return result;
}

function parseAssetsSectionLines(pubspecLines) {
  const assetsStart = pubspecLines.findIndex((line) => /^  assets:\s*$/.test(line));
  if (assetsStart < 0) {
    throw new Error('pubspec.yaml 未找到 flutter/assets 段');
  }

  let assetsEnd = assetsStart;
  while (assetsEnd + 1 < pubspecLines.length) {
    const next = pubspecLines[assetsEnd + 1];
    if (/^\s*$/.test(next) || /^ {4}-\s+/.test(next)) {
      assetsEnd += 1;
      continue;
    }
    break;
  }

  return { assetsStart, assetsEnd };
}

function isGameScriptEntry(entry) {
  return (
    entry === 'GameScript' ||
    entry === 'GameScript/' ||
    entry.startsWith('GameScript/') ||
    entry.startsWith('GameScript_')
  );
}

function prepareReleasePubspecAssets(gameDir, cacheDir, pubspecPath, platform) {
  const pubspecRaw = fs.readFileSync(pubspecPath, 'utf8');
  const pubspecLines = pubspecRaw.split(/\r?\n/);
  const { assetsStart, assetsEnd } = parseAssetsSectionLines(pubspecLines);

  ensureDir(cacheDir);

  const rawEntries = [];
  for (let i = assetsStart + 1; i <= assetsEnd; i += 1) {
    const line = pubspecLines[i];
    const match = line.match(/^ {4}-\s+(.+)$/);
    if (!match) continue;
    let entry = match[1];
    entry = entry.replace(/\s+#.*$/, '').trim();
    entry = entry.replace(/^['"](.+)['"]$/, '$1');
    if (!entry) continue;
    rawEntries.push(entry);
  }

  const expanded = [];
  for (const entryRaw of rawEntries) {
    const entry = entryRaw.trim();
    if (!entry) continue;
    if (isGameScriptEntry(entry)) continue;

    const normalized = entry.replace(/[\\/]+$/, '');
    const fullPath = path.join(gameDir, normalized);

    if (fs.existsSync(fullPath) && fs.statSync(fullPath).isDirectory()) {
      for (const filePath of walkFilesSorted(fullPath)) {
        const rel = normalizeRelPath(path.relative(gameDir, filePath));
        if (path.basename(filePath) === '.DS_Store') continue;
        if (rel.startsWith('GameScript/') || rel.startsWith('GameScript_')) continue;
        expanded.push(rel);
      }
      continue;
    }

    if (fs.existsSync(fullPath) && fs.statSync(fullPath).isFile()) {
      expanded.push(normalizeRelPath(normalized));
      continue;
    }

    colorLog(`警告: 资源路径不存在，已跳过: ${entry}`, 'yellow');
  }

  const unique = [];
  const seen = new Set();
  for (const item of expanded) {
    if (item && !seen.has(item)) {
      seen.add(item);
      unique.push(item);
    }
  }

  if (unique.length === 0) {
    throw new Error('发布资源清单为空，已中止构建。');
  }

  const mediaRegex = /^Assets\/.*\.(png|jpg|jpeg|gif|bmp|webp|avif|mp4|mov|avi|mkv|webm)$/i;
  const imageCount = unique.filter((p) => mediaRegex.test(p)).length;
  const hasAssetsRoot = rawEntries.some((entry) => entry === 'Assets' || entry === 'Assets/');
  if (hasAssetsRoot && imageCount === 0) {
    throw new Error(
      '检测到配置了 Assets/，但展开后没有任何图片/视频资源。为防止发布包缺少美术素材，已中止构建。',
    );
  }

  let releaseEntries;
  if (platform === 'web') {
    releaseEntries = [...unique];
  } else {
    releaseEntries = unique.filter((item) => {
      const normalized = item.toLowerCase();
      if (normalized.startsWith('gamescript/') || normalized.startsWith('gamescript_')) {
        return false;
      }
      if (normalized.startsWith('assets/')) {
        return false;
      }
      return true;
    });
    if (!releaseEntries.includes('.saki_cache/game.sakipak')) {
      releaseEntries.push('.saki_cache/game.sakipak');
    }
  }

  const newLines = [
    ...pubspecLines.slice(0, assetsStart + 1),
    ...releaseEntries.map((p) => `    - ${p}`),
    ...pubspecLines.slice(assetsEnd + 1),
  ];
  fs.writeFileSync(pubspecPath, `${newLines.join('\n')}\n`);
  if (platform === 'web') {
    colorLog(`已更新发布资源清单（Web 保留原始资源）：${releaseEntries.length} 项`, 'yellow');
  } else {
    colorLog(
      `已更新发布资源清单：原始 ${unique.length} 项，发布 ${releaseEntries.length} 项（含 .saki_cache/game.sakipak）`,
      'yellow',
    );
  }
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function generateSakiPack(gameDir, cacheDir) {
  ensureDir(cacheDir);
  const packPath = path.join(cacheDir, 'game.sakipak');
  const legacyPackPath = path.join(gameDir, 'Assets', 'game.sakipak');
  colorLog('正在生成 SakiPack 资源包...', 'yellow');
  runCommand('node', [path.join(projectRoot, 'scripts', 'build_saki_pack.js'), gameDir, packPath], projectRoot);
  if (fs.existsSync(legacyPackPath)) {
    fs.rmSync(legacyPackPath, { force: true });
  }
}

function listGameProjects() {
  const gameDir = path.join(projectRoot, 'Game');
  if (!fs.existsSync(gameDir)) {
    throw new Error('未找到 Game 目录');
  }
  return fs
    .readdirSync(gameDir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((name) => fs.existsSync(path.join(gameDir, name, 'pubspec.yaml')))
    .sort();
}

function ask(rl, prompt) {
  return new Promise((resolve) => rl.question(prompt, resolve));
}

async function chooseGameProject() {
  const projects = listGameProjects();
  if (projects.length === 0) {
    throw new Error('未找到可构建的游戏项目（Game/*/pubspec.yaml）');
  }

  let currentDefault = '';
  if (fs.existsSync(defaultGameFile)) {
    currentDefault = fs.readFileSync(defaultGameFile, 'utf8').trim();
  }

  let defaultIndex = 1;
  if (currentDefault) {
    const idx = projects.indexOf(currentDefault);
    if (idx >= 0) defaultIndex = idx + 1;
  }

  colorLog('请选择要编译的游戏项目:', 'yellow');
  projects.forEach((p, i) => {
    const marker = i + 1 === defaultIndex ? ' (默认)' : '';
    colorLog(`  ${i + 1}. ${p}${marker}`, 'blue');
  });

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  try {
    const answer = (await ask(rl, `请输入项目编号 (默认 ${defaultIndex}): `)).trim();
    const finalIndex = answer ? Number(answer) : defaultIndex;
    if (!Number.isInteger(finalIndex) || finalIndex < 1 || finalIndex > projects.length) {
      throw new Error(`无效的项目编号 ${answer || finalIndex}`);
    }
    const game = projects[finalIndex - 1];
    fs.writeFileSync(defaultGameFile, `${game}\n`);
    return game;
  } finally {
    rl.close();
  }
}

async function choosePlatform() {
  const host = detectHostPlatform();
  let options = [];
  if (host === 'macos') options = ['macos', 'linux', 'windows', 'ios', 'android', 'web'];
  else if (host === 'linux') options = ['linux', 'android', 'web'];
  else if (host === 'windows') options = ['windows', 'android', 'web'];
  else options = ['macos', 'linux', 'windows', 'android', 'ios', 'web'];

  let defaultIndex = 1;
  const hostIndex = options.indexOf(host);
  if (hostIndex >= 0) defaultIndex = hostIndex + 1;

  colorLog('请选择要构建的平台:', 'yellow');
  options.forEach((opt, i) => {
    const marker = i + 1 === defaultIndex ? ' (默认)' : '';
    colorLog(`  ${i + 1}. ${platformDisplayName(opt)}${marker}`, 'blue');
  });

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  try {
    const answer = (await ask(rl, `请输入平台编号 (默认 ${defaultIndex}): `)).trim();
    const finalIndex = answer ? Number(answer) : defaultIndex;
    if (!Number.isInteger(finalIndex) || finalIndex < 1 || finalIndex > options.length) {
      throw new Error(`无效的平台编号 ${answer || finalIndex}`);
    }
    return options[finalIndex - 1];
  } finally {
    rl.close();
  }
}

function restoreEngineCompiledLoader(engineCompiledLoader) {
  const content = `import 'package:sakiengine/src/sks_compiler/compiled_sks_bundle.dart';

CompiledSksBundle? loadGeneratedCompiledSksBundle() {
  return null;
}
`;
  fs.writeFileSync(engineCompiledLoader, content);
}

async function main() {
  const args = process.argv.slice(2);
  let gameName = '';
  let platform = '';

  if (args.length >= 1) {
    if (supportedPlatforms.has(args[0])) {
      platform = args[0];
    } else {
      gameName = args[0];
    }
  }
  if (args.length >= 2) {
    platform = args[1];
  }

  if (!gameName) {
    gameName = await chooseGameProject();
  }

  const gameDir = path.join(projectRoot, 'Game', gameName);
  if (!fs.existsSync(path.join(gameDir, 'pubspec.yaml'))) {
    throw new Error(`游戏项目无效: ${gameDir}`);
  }

  if (!platform) {
    platform = await choosePlatform();
  } else if (!supportedPlatforms.has(platform)) {
    throw new Error(`不支持的平台 '${platform}'`);
  }

  colorLog(`使用游戏项目: ${gameName}`, 'green');
  colorLog(`目标平台: ${platformDisplayName(platform)}`, 'green');

  const gameConfig = assetUtils.readGameConfig(gameDir);
  if (gameConfig) {
    assetUtils.setAppIdentity(gameDir, gameConfig.appName, gameConfig.bundleId);
  } else {
    colorLog('未找到有效 game_config.txt，跳过应用身份同步', 'yellow');
  }
  assetUtils.ensureProjectIcon(gameDir, projectRoot);

  const engineCompiledLoader = path.join(
    projectRoot,
    'Engine',
    'lib',
    'src',
    'sks_compiler',
    'generated',
    'compiled_sks_bundle.g.dart',
  );
  const gameCacheDir = path.join(gameDir, '.saki_cache');
  const gameBundleFile = path.join(gameCacheDir, 'compiled_sks_bundle.g.dart');
  const gamePubspecFile = path.join(gameDir, 'pubspec.yaml');
  const gamePubspecBackupFile = path.join(gameCacheDir, 'pubspec.yaml.backup');

  let pubspecBackedUp = false;
  try {
    colorLog('准备脚本编译环境（首次依赖解析）...', 'yellow');
    runFlutter(['pub', 'get'], gameDir);

    colorLog('正在预编译 .sks 脚本为 Dart...', 'yellow');
    ensureDir(gameCacheDir);
    runFlutter(
      [
        'pub',
        'run',
        '../../Engine/tool/sks_compiler.dart',
        '--game-dir',
        gameDir,
        '--output',
        gameBundleFile,
        '--game-name',
        gameName,
      ],
      gameDir,
    );

    if (!fs.existsSync(gameBundleFile)) {
      throw new Error(`预编译产物不存在: ${gameBundleFile}`);
    }

    fs.copyFileSync(gameBundleFile, engineCompiledLoader);

    colorLog('正在生成发布资源清单...', 'yellow');
    generateSakiPack(gameDir, gameCacheDir);
    fs.copyFileSync(gamePubspecFile, gamePubspecBackupFile);
    pubspecBackedUp = true;
    prepareReleasePubspecAssets(gameDir, gameCacheDir, gamePubspecFile, platform);

    colorLog('正在获取依赖...', 'yellow');
    runFlutter(['pub', 'get'], gameDir);
    assetUtils.generateAppIcons(gameDir);

    colorLog(`正在构建 ${platform} ...`, 'yellow');
    if (platform === 'macos') runFlutter(['build', 'macos', '--release'], gameDir);
    else if (
      detectHostPlatform() === 'macos' &&
      (platform === 'linux' || platform === 'windows')
    ) {
      buildCrossDesktop({
        gameDir,
        target: platform,
        flutterBin: process.env.SAKI_FLUTTER_BIN || 'flutter',
      });
    } else if (platform === 'linux') runFlutter(['build', 'linux', '--release'], gameDir);
    else if (platform === 'windows') runFlutter(['build', 'windows', '--release'], gameDir);
    else if (platform === 'android') {
      runFlutter(['build', 'apk', '--release', '--target-platform', 'android-arm64'], gameDir);
    } else if (platform === 'ios') {
      runCommand('pod', ['install'], path.join(gameDir, 'ios'));
      runFlutter(['build', 'ios', '--release', '--no-codesign'], gameDir);
    } else if (platform === 'web') runFlutter(['build', 'web', '--release'], gameDir);
    else throw new Error(`不支持的平台 '${platform}'`);

    colorLog(`构建完成: ${platform}`, 'green');
  } finally {
    restoreEngineCompiledLoader(engineCompiledLoader);
    if (pubspecBackedUp && fs.existsSync(gamePubspecBackupFile)) {
      fs.copyFileSync(gamePubspecBackupFile, gamePubspecFile);
      fs.rmSync(gamePubspecBackupFile, { force: true });
    }
  }
}

main().catch((error) => {
  colorLog(`错误: ${error.message}`, 'red');
  process.exit(1);
});
