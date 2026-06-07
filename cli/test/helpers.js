const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function makeTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'bmfctl-'));
}

function write(filepath, contents) {
  fs.mkdirSync(path.dirname(filepath), { recursive: true });
  fs.writeFileSync(filepath, contents, 'utf8');
}

function makeEnvironment() {
  const root = makeTempRoot();
  const bmfRoot = path.join(root, 'bmf');
  const omeggaDir = path.join(root, 'Brickadia', 'omegga-master', 'omegga-master');
  const compatRoot = path.join(root, 'Brickadia', 'brickadia-ue4ss-re');
  const gameWin64 = path.join(root, 'BrickadiaServer', 'Brickadia', 'Binaries', 'Win64');
  const liveMods = path.join(gameWin64, 'ue4ss', 'Mods');

  write(
    path.join(bmfRoot, 'manifests', 'bmf-package.json'),
    JSON.stringify({ name: 'bmf', version: 'test' }, null, 2),
  );
  write(path.join(bmfRoot, 'manifests', 'dependencies.json'), '{}\n');
  write(path.join(bmfRoot, 'manifests', 'compatibility.json'), '{}\n');
  write(path.join(bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMF', 'bmf.json'), '{"name":"BMF"}\n');
  write(path.join(bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMF', 'config.json'), '{}\n');
  write(path.join(bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMF', 'Scripts', 'main.lua'), 'return nil\n');

  write(
    path.join(omeggaDir, 'package.json'),
    JSON.stringify({ name: 'omegga', version: 'test', scripts: { 'package:bmf': 'node noop.js' } }, null, 2),
  );
  write(
    path.join(omeggaDir, 'templates', 'windows-ue4ss', 'ue4ss', 'Mods', 'BMF', 'bmf.json'),
    '{"name":"BMF"}\n',
  );
  write(
    path.join(omeggaDir, 'templates', 'windows-ue4ss', 'ue4ss', 'Mods', 'BMF', 'Scripts', 'main.lua'),
    'return nil\n',
  );
  write(
    path.join(
      omeggaDir,
      'templates',
      'windows-ue4ss',
      'ue4ss',
      'Mods',
      'OmeggaBridge',
      'Scripts',
      'main.lua',
    ),
    'return nil\n',
  );

  write(
    path.join(compatRoot, 'bundles', 'CL13530', 'manifest.json'),
    JSON.stringify({ brickadia_cl: '13530', validated: true }, null, 2),
  );

  write(path.join(gameWin64, 'dwmapi.dll'), 'dll');
  write(path.join(liveMods, 'mods.txt'), 'BMF : 0\nOmeggaBridge : 1\nKeybinds : 1\n');
  write(
    path.join(liveMods, 'mods.json'),
    JSON.stringify(
      [
        { mod_name: 'BMF', mod_enabled: false },
        { mod_name: 'OmeggaBridge', mod_enabled: true },
      ],
      null,
      2,
    ),
  );
  write(path.join(liveMods, 'BMF', 'bmf.json'), '{"name":"BMF"}\n');
  write(path.join(liveMods, 'BMF', 'Scripts', 'main.lua'), 'return nil\n');
  write(path.join(liveMods, 'OmeggaBridge', 'Scripts', 'main.lua'), 'return nil\n');

  return {
    root,
    bmfRoot,
    omeggaDir,
    compatRoot,
    gameWin64,
    liveMods,
    options: {
      bmfRoot,
      omegga: omeggaDir,
      compatRoot,
      gameWin64,
      modsDir: liveMods,
    },
  };
}

module.exports = {
  makeEnvironment,
  makeTempRoot,
  write,
};
