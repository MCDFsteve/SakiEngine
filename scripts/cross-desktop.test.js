const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const {
  nativePluginsFor,
  readGameIdentity,
  sanitizeBinaryName,
  validatePluginProfile,
} = require('./cross-desktop.js');

test('sanitizeBinaryName creates portable desktop executable names', () => {
  assert.strictEqual(sanitizeBinaryName('樱花 Story! 2026'), 'Story_2026');
  assert.strictEqual(sanitizeBinaryName('---'), 'saki_game');
});

test('readGameIdentity reads the two-line Saki config', () => {
  const gameDir = fs.mkdtempSync(path.join(os.tmpdir(), 'saki-identity-'));
  fs.writeFileSync(path.join(gameDir, 'game_config.txt'), 'My Game\ncom.aimes.my_game\n');
  assert.deepStrictEqual(readGameIdentity(gameDir), {
    appName: 'My Game',
    applicationId: 'com.aimes.my_game',
    binaryName: 'My_Game',
  });
});

test('plugin profile rejects target native plugins absent from the embedded runner', () => {
  const gameDir = fs.mkdtempSync(path.join(os.tmpdir(), 'saki-plugins-'));
  fs.writeFileSync(
    path.join(gameDir, '.flutter-plugins-dependencies'),
    JSON.stringify({
      plugins: {
        windows: [
          { name: 'base_plugin', native_build: true, dev_dependency: false },
          { name: 'game_plugin', native_build: true, dev_dependency: false },
          { name: 'dev_plugin', native_build: true, dev_dependency: true },
        ],
      },
    }),
  );
  assert.deepStrictEqual(nativePluginsFor(gameDir, 'windows'), ['base_plugin', 'game_plugin']);
  assert.throws(
    () => validatePluginProfile(gameDir, 'windows', { nativePlugins: ['base_plugin'] }),
    /game_plugin/,
  );
});
