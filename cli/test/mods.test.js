const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeTempRoot, write } = require('./helpers');
const { parseModsJson, parseModsTxt, setModEnabled, setModInTxt } = require('../src/mods');

test('parses UE4SS mods.txt and mods.json enablement', () => {
  const txt = parseModsTxt('BMF : 1\nOmeggaBridge : 0\n');
  assert.equal(txt.get('BMF'), true);
  assert.equal(txt.get('OmeggaBridge'), false);

  const json = parseModsJson('[{"mod_name":"BMF","mod_enabled":true}]');
  assert.equal(json.get('BMF'), true);
});

test('adds mod entries before Keybinds in mods.txt', () => {
  const rewritten = setModInTxt('Keybinds : 1\n', 'BMF', true);
  assert.equal(rewritten, 'BMF : 1\nKeybinds : 1\n');
});

test('setModEnabled updates both mod files and creates backups', () => {
  const root = makeTempRoot();
  const modsDir = path.join(root, 'Mods');
  write(path.join(modsDir, 'mods.txt'), 'BMF : 0\n');
  write(path.join(modsDir, 'mods.json'), '[{"mod_name":"BMF","mod_enabled":false}]\n');

  const result = setModEnabled(modsDir, 'BMF', true);
  assert.equal(result.changes.length, 2);
  assert.match(fs.readFileSync(path.join(modsDir, 'mods.txt'), 'utf8'), /BMF : 1/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(modsDir, 'mods.json'), 'utf8')), [
    { mod_name: 'BMF', mod_enabled: true },
  ]);
  assert.ok(result.changes.every(change => change.backupPath));
});
