#!/usr/bin/env node

const { spawnSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const artifactDir = path.join(root, 'artifacts', 'packages');
const npmExecPath = process.env.npm_execpath || '';
const npmCommand = npmExecPath
  ? process.execPath
  : process.platform === 'win32'
    ? 'npm.cmd'
    : 'npm';
const npmBaseArgs = npmExecPath ? [npmExecPath] : [];
const npmRequiresShell = !npmExecPath && process.platform === 'win32';
const gitCommand = process.platform === 'win32' ? 'git.exe' : 'git';

const requiredLocalFiles = [
  'templates/windows-ue4ss/ue4ss/Mods/BMF/bmf.json',
  'templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/main.lua',
  'templates/windows-ue4ss/ue4ss/Mods/BMFSocket/README.md',
  'templates/windows-ue4ss/ue4ss/Mods/BMFSocket/dlls/.gitkeep',
  'templates/windows-ue4ss/ue4ss/Mods/BMFSocket/dlls/main.dll',
  'templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua',
  'templates/windows-ue4ss/ue4ss/CustomGameConfigs/Brickadia/UE4SS-settings.ini',
];

const requiredPackedFiles = [
  ...requiredLocalFiles,
  'bin/omegga',
  'dist/main.js',
  'dist/brickadia/bmfSocketBridge.js',
  'dist/util/ue4ss.js',
  'dist/brickadia/server.js',
  'index.js',
  'package.json',
];

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    shell: options.shell ?? false,
    stdio: options.capture ? ['inherit', 'pipe', 'pipe'] : 'inherit',
  });

  if (result.status !== 0) {
    if (options.capture) {
      if (result.stdout) process.stdout.write(result.stdout);
      if (result.stderr) process.stderr.write(result.stderr);
    }
    const detail = result.error
      ? `: ${result.error.message}`
      : ` with exit ${result.status}`;
    throw new Error(`${command} ${args.join(' ')} failed${detail}`);
  }

  return result;
}

function runNpm(args, options) {
  return run(npmCommand, [...npmBaseArgs, ...args], {
    ...options,
    shell: npmRequiresShell,
  });
}

function runOptional(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });

  return result.status === 0 ? result.stdout.trim() : '';
}

function assertLocalFilesPresent() {
  const missing = requiredLocalFiles.filter(relativePath => {
    return !fs.existsSync(path.join(root, relativePath));
  });

  if (missing.length > 0) {
    throw new Error(
      `BMF-capable Omegga package is missing required local files:\n${missing
        .map(file => `  - ${file}`)
        .join('\n')}`,
    );
  }
}

function parsePackJson(stdout) {
  try {
    const parsed = JSON.parse(stdout);
    if (Array.isArray(parsed) && parsed.length > 0) return parsed[0];
  } catch (error) {
    throw new Error(`Could not parse npm pack JSON output: ${error.message}`);
  }

  throw new Error('npm pack did not return a package description.');
}

function assertPackedFilesPresent(pack) {
  const packedFiles = new Set(
    pack.files.map(file => String(file.path).replace(/\\/g, '/')),
  );
  const missing = requiredPackedFiles.filter(file => !packedFiles.has(file));

  if (missing.length > 0) {
    throw new Error(
      `BMF-capable Omegga package is missing required packed files:\n${missing
        .map(file => `  - ${file}`)
        .join('\n')}`,
    );
  }
}

function sha256(filepath) {
  return createHash('sha256').update(fs.readFileSync(filepath)).digest('hex');
}

function artifactName(pack) {
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(root, 'package.json'), 'utf8'),
  );
  const commit =
    runOptional(gitCommand, ['rev-parse', '--short', 'HEAD']) || 'local';
  const dirty = runOptional(gitCommand, ['status', '--porcelain'])
    ? '-dirty'
    : '';
  const name = String(packageJson.name || 'omegga')
    .replace(/^@/, '')
    .replace(/[\/\\]/g, '-');
  const version = String(packageJson.version || pack.version || '0.0.0');
  return `${name}-bmf-${version}-${commit}${dirty}.tgz`;
}

function main() {
  fs.mkdirSync(artifactDir, { recursive: true });
  assertLocalFilesPresent();

  runNpm(['run', 'build']);
  runNpm(['run', 'test:backend', '--', '--run', 'windows.test.ts']);

  const packResult = runNpm(
    ['pack', '--ignore-scripts', '--json', '--pack-destination', artifactDir],
    { capture: true },
  );
  const pack = parsePackJson(packResult.stdout);
  assertPackedFilesPresent(pack);

  const packedTarball = path.join(artifactDir, pack.filename);
  const namedTarball = path.join(artifactDir, artifactName(pack));
  fs.copyFileSync(packedTarball, namedTarball);

  const manifest = {
    package: {
      name: pack.name,
      version: pack.version,
      filename: path.basename(namedTarball),
      source_filename: pack.filename,
      unpacked_size: pack.unpackedSize,
      sha256: sha256(namedTarball),
    },
    required_files: requiredPackedFiles,
    created_at: new Date().toISOString(),
  };
  const manifestPath = namedTarball.replace(/\.tgz$/, '.manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');

  console.log(`BMF-capable Omegga package: ${namedTarball}`);
  console.log(`Package manifest: ${manifestPath}`);
}

main();
