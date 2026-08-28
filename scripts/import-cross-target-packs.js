#!/usr/bin/env node

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const repoRoot = path.dirname(__dirname);

function copyDirectory(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name);
    const to = path.join(destination, entry.name);
    if (entry.isDirectory()) copyDirectory(from, to);
    else if (entry.isFile()) {
      fs.copyFileSync(from, to);
      fs.chmodSync(to, fs.statSync(from).mode);
    }
  }
}

function sha256(filePath) {
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(filePath, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    while (true) {
      const count = fs.readSync(fd, buffer, 0, buffer.length, null);
      if (count === 0) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    fs.closeSync(fd);
  }
  return hash.digest('hex');
}

function listFiles(root) {
  const files = [];
  function walk(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) walk(absolute);
      else if (entry.isFile()) files.push(absolute);
    }
  }
  walk(root);
  return files.sort();
}

function readJson(filePath) {
  if (!fs.existsSync(filePath)) throw new Error(`缺少工作流产物: ${filePath}`);
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function relativeToRepo(filePath) {
  return path.relative(repoRoot, filePath).split(path.sep).join('/');
}

function main() {
  const artifactRoot = path.resolve(process.argv[2] || '');
  if (!artifactRoot || !fs.existsSync(artifactRoot)) {
    throw new Error('用法: node scripts/import-cross-target-packs.js <gh-run-download-directory>');
  }

  const snapshotSource = path.join(artifactRoot, 'saki-cross-snapshotter');
  const linuxSource = path.join(artifactRoot, 'saki-cross-linux-x64');
  const windowsSource = path.join(artifactRoot, 'saki-cross-windows-x64');
  const snapshotMetadata = readJson(path.join(snapshotSource, 'metadata.json'));
  const linuxMetadata = readJson(path.join(linuxSource, 'metadata.json'));
  const windowsMetadata = readJson(path.join(windowsSource, 'metadata.json'));

  const packName = `${snapshotMetadata.flutterVersion}-${snapshotMetadata.engineRevision}`;
  const packRoot = path.join(repoRoot, 'toolchains', 'cross', 'packs', packName);
  fs.rmSync(packRoot, { recursive: true, force: true });
  fs.mkdirSync(packRoot, { recursive: true });
  copyDirectory(snapshotSource, path.join(packRoot, 'snapshotter'));
  copyDirectory(linuxSource, path.join(packRoot, 'linux-x64'));
  copyDirectory(windowsSource, path.join(packRoot, 'windows-x64'));

  const checksums = {};
  for (const filePath of listFiles(packRoot)) {
    if (path.basename(filePath) === 'metadata.json') continue;
    checksums[relativeToRepo(filePath)] = sha256(filePath);
  }

  const rootRelative = relativeToRepo(packRoot);
  const manifest = {
    schemaVersion: 1,
    flutterVersion: snapshotMetadata.flutterVersion,
    engineRevision: snapshotMetadata.engineRevision,
    host: 'darwin',
    hostArchitectures: ['arm64', 'x64'],
    flutterSnapshotDirectory: snapshotMetadata.flutterSnapshotDirectory,
    snapshotter: `${rootRelative}/snapshotter/gen_snapshot`,
    targets: {
      linux: {
        targetPlatform: linuxMetadata.targetPlatform,
        flutterSnapshotDirectory: 'linux-x64-release',
        template: `${rootRelative}/linux-x64/template`,
        runnerExecutable: linuxMetadata.runnerExecutable,
        nativePlugins: linuxMetadata.nativePlugins,
        output: 'build/linux/x64/release/bundle',
        assetsDestination: 'data/flutter_assets',
        aotDestination: 'lib/libapp.so',
      },
      windows: {
        targetPlatform: windowsMetadata.targetPlatform,
        flutterSnapshotDirectory: 'windows-x64-release',
        template: `${rootRelative}/windows-x64/template`,
        runnerExecutable: windowsMetadata.runnerExecutable,
        nativePlugins: windowsMetadata.nativePlugins,
        output: 'build/windows/x64/runner/Release',
        assetsDestination: 'data/flutter_assets',
        aotDestination: 'data/app.so',
      },
    },
    checksums,
  };
  const manifestPath = path.join(repoRoot, 'toolchains', 'cross', 'manifest.json');
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  process.stdout.write(`已导入离线目标包: ${packRoot}\n`);
  process.stdout.write(`文件数量: ${Object.keys(checksums).length}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
