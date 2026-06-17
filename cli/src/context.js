const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  getStoredProfile,
  loadProfileRegistry,
} = require('../../packages/orchestrator-core/src/profiles');
const { exists, isDirectory, readJson } = require('./file');

const RUNTIME_ALIASES = [
  'Mods',
  path.join('Brickadia', 'Mods'),
  path.join('BrickadiaServer', 'Mods'),
  path.join('BrickadiaServer-Win64-Shipping', 'Mods'),
  path.join('main', 'Mods'),
];

function findBmfRoot(startDir = process.cwd()) {
  let current = path.resolve(startDir);
  while (true) {
    if (
      exists(path.join(current, 'manifests', 'bmf-package.json')) &&
      exists(path.join(current, 'framework', 'ue4ss', 'Mods', 'BMF', 'bmf.json'))
    ) {
      return current;
    }

    const parent = path.dirname(current);
    if (parent === current) return path.resolve(startDir);
    current = parent;
  }
}

function firstExisting(candidates) {
  return candidates.filter(Boolean).map(candidate => path.resolve(candidate)).find(exists) || null;
}

function resolveOmeggaDir(bmfRoot, options = {}) {
  if (options.omegga) return path.resolve(options.omegga);
  if (process.env.BMF_OMEGGA_DIR) return path.resolve(process.env.BMF_OMEGGA_DIR);
  if (process.env.OMEGGA_DIR) return path.resolve(process.env.OMEGGA_DIR);

  const githubRoot = path.dirname(bmfRoot);
  return (
    firstExisting([
      path.join(githubRoot, 'Brickadia', 'omegga-master', 'omegga-master'),
      path.join(githubRoot, 'omegga-master', 'omegga-master'),
      path.join(bmfRoot, '..', 'Brickadia', 'omegga-master', 'omegga-master'),
    ]) || path.join(githubRoot, 'Brickadia', 'omegga-master', 'omegga-master')
  );
}

function resolveCompatibilityRoot(bmfRoot, options = {}) {
  if (options.compatRoot) return path.resolve(options.compatRoot);
  if (process.env.OMEGGA_UE4SS_RE_ROOT) return path.resolve(process.env.OMEGGA_UE4SS_RE_ROOT);
  if (process.env.BMF_COMPAT_ROOT) return path.resolve(process.env.BMF_COMPAT_ROOT);

  const githubRoot = path.dirname(bmfRoot);
  return (
    firstExisting([
      path.join(githubRoot, 'Brickadia', 'brickadia-ue4ss-re'),
      path.join(bmfRoot, '..', 'Brickadia', 'brickadia-ue4ss-re'),
      path.join(bmfRoot, 'brickadia-ue4ss-re'),
    ]) || path.join(githubRoot, 'Brickadia', 'brickadia-ue4ss-re')
  );
}

function commonWin64Candidates() {
  const programFilesX86 = process.env['ProgramFiles(x86)'];
  const programFiles = process.env.ProgramFiles;
  const localAppData = process.env.LOCALAPPDATA;
  return [
    process.env.BMF_GAME_WIN64_DIR,
    process.env.BRICKADIA_WIN64_DIR,
    process.env.OMEGGA_BRICKADIA_WIN64_DIR,
    programFilesX86 &&
      path.join(
        programFilesX86,
        'Steam',
        'steamapps',
        'common',
        'Brickadia',
        'Brickadia',
        'Binaries',
        'Win64',
      ),
    programFilesX86 &&
      path.join(
        programFilesX86,
        'Steam',
        'steamapps',
        'common',
        'Brickadia Dedicated Server',
        'Brickadia',
        'Binaries',
        'Win64',
      ),
    programFiles &&
      path.join(programFiles, 'Epic Games', 'Brickadia', 'Brickadia', 'Binaries', 'Win64'),
    localAppData &&
      path.join(localAppData, 'Brickadia', 'Saved', 'Server', 'Brickadia', 'Binaries', 'Win64'),
  ];
}

function resolveGameWin64Dir(options = {}) {
  if (options.gameWin64) return path.resolve(options.gameWin64);
  return firstExisting(commonWin64Candidates());
}

function resolveSavedDir(omeggaDir, options = {}) {
  if (options.savedDir) return path.resolve(options.savedDir);
  if (process.env.BMF_BRICKADIA_SAVED_DIR) {
    return path.resolve(process.env.BMF_BRICKADIA_SAVED_DIR);
  }

  return path.join(omeggaDir, 'data', 'Saved');
}

function resolveStartScript(omeggaDir, options = {}) {
  if (options.startScript) return path.resolve(options.startScript);
  if (process.env.BMF_OMEGGA_START_SCRIPT) return path.resolve(process.env.BMF_OMEGGA_START_SCRIPT);
  if (process.env.OMEGGA_START_SCRIPT) return path.resolve(process.env.OMEGGA_START_SCRIPT);

  const installRoot = path.dirname(omeggaDir);
  const candidates = [
    path.join(installRoot, 'Start-BrickadiaOmegga.ps1'),
    path.join(omeggaDir, 'Start-BrickadiaOmegga.ps1'),
  ];
  return firstExisting(candidates) || candidates[0];
}

function profileStoreOptions(bmfRoot, options = {}) {
  return {
    root: bmfRoot,
    profileStorePath: options.profileStorePath || options.profileStore || options.storePath,
  };
}

function resolveStoredProfile(bmfRoot, options = {}) {
  const shouldLoadProfile = options.profile
    || options.profileId
    || options.profileStore
    || options.profileStorePath
    || options.storePath;
  if (!shouldLoadProfile) return null;

  const storeOptions = profileStoreOptions(bmfRoot, options);
  const registry = loadProfileRegistry(storeOptions);
  const profileId = options.profileId || options.profile || registry.selectedProfileId;
  if (!profileId) return null;
  return getStoredProfile(profileId, storeOptions);
}

function runtimeModsDirs(gameWin64Dir, options = {}) {
  if (options.modsDir) return [path.resolve(options.modsDir)];
  if (!gameWin64Dir) return [];
  return RUNTIME_ALIASES.map(alias => path.join(gameWin64Dir, 'ue4ss', alias));
}

function profileRuntimeModsDirs(profilePaths = {}) {
  if (!profilePaths.bmfRuntimeDir) return [];

  const runtimeDir = path.resolve(profilePaths.bmfRuntimeDir);
  const bmfModDir = path.dirname(runtimeDir);
  if (path.basename(bmfModDir).toLowerCase() !== 'bmf') return [];
  return [path.dirname(bmfModDir)];
}

function bridgeRuntimeDirs(omeggaDir) {
  const bridgeRoot = path.join(omeggaDir, 'data', 'ue4ss-bridge');
  if (!isDirectory(bridgeRoot)) return [];

  const dirs = [];
  if (
    exists(path.join(bridgeRoot, 'status.json')) ||
    exists(path.join(bridgeRoot, 'inbox.ndjson')) ||
    exists(path.join(bridgeRoot, 'outbox.ndjson'))
  ) {
    dirs.push(bridgeRoot);
  }

  for (const entry of fs.readdirSync(bridgeRoot, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const sessionDir = path.join(bridgeRoot, entry.name);
    if (
      exists(path.join(sessionDir, 'status.json')) ||
      exists(path.join(sessionDir, 'inbox.ndjson')) ||
      exists(path.join(sessionDir, 'outbox.ndjson'))
    ) {
      dirs.push(sessionDir);
    }
  }

  return dirs;
}

function readBmfPackage(bmfRoot) {
  return readJson(path.join(bmfRoot, 'manifests', 'bmf-package.json'), null);
}

function readOmeggaPackage(omeggaDir) {
  return readJson(path.join(omeggaDir, 'package.json'), null);
}

function resolveContext(options = {}) {
  const bmfRoot = path.resolve(options.bmfRoot || options.root || process.env.BMF_ROOT || findBmfRoot());
  const storedProfile = resolveStoredProfile(bmfRoot, options);
  const profilePaths = storedProfile?.paths || {};
  const omeggaDir = options.omegga
    ? resolveOmeggaDir(bmfRoot, options)
    : profilePaths.omeggaRuntime
      ? path.resolve(profilePaths.omeggaRuntime)
      : resolveOmeggaDir(bmfRoot, options);
  const compatibilityRoot = resolveCompatibilityRoot(bmfRoot, options);
  const gameWin64Dir = options.gameWin64
    ? resolveGameWin64Dir(options)
    : profilePaths.brickadiaWin64
      ? path.resolve(profilePaths.brickadiaWin64)
      : resolveGameWin64Dir(options);
  const savedDir = resolveSavedDir(omeggaDir, options);
  const startScript = options.startScript
    ? resolveStartScript(omeggaDir, options)
    : profilePaths.omeggaStartScript
      ? path.resolve(profilePaths.omeggaStartScript)
      : resolveStartScript(omeggaDir, options);
  const bmfSourceDir = path.join(bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMF');
  const omeggaTemplateUe4ssDir = path.join(omeggaDir, 'templates', 'windows-ue4ss', 'ue4ss');
  const omeggaTemplateModsDir = path.join(omeggaTemplateUe4ssDir, 'Mods');
  const omeggaTemplateBmfDir = path.join(omeggaTemplateModsDir, 'BMF');
  const omeggaTemplateBridgeDir = path.join(omeggaTemplateModsDir, 'OmeggaBridge');
  const liveModsDirs = [
    ...profileRuntimeModsDirs(profilePaths),
    ...runtimeModsDirs(gameWin64Dir, options),
  ].filter((dir, index, dirs) => dirs.indexOf(dir) === index);

  return {
    cwd: process.cwd(),
    platform: os.platform(),
    node: process.version,
    bmfRoot,
    bmfPackage: readBmfPackage(bmfRoot),
    bmfSourceDir,
    omeggaDir,
    omeggaPackage: readOmeggaPackage(omeggaDir),
    omeggaTemplateUe4ssDir,
    omeggaTemplateModsDir,
    omeggaTemplateBmfDir,
    omeggaTemplateBridgeDir,
    compatibilityRoot,
    gameWin64Dir,
    savedDir,
    startScript,
    liveModsDirs,
    bridgeRuntimeDirs: bridgeRuntimeDirs(omeggaDir),
    requestedModsDir: options.modsDir ? path.resolve(options.modsDir) : null,
  };
}

function publicContext(ctx) {
  return {
    bmfRoot: ctx.bmfRoot,
    bmfVersion: ctx.bmfPackage?.version || null,
    omeggaDir: ctx.omeggaDir,
    omeggaVersion: ctx.omeggaPackage?.version || null,
    compatibilityRoot: ctx.compatibilityRoot,
    gameWin64Dir: ctx.gameWin64Dir,
    savedDir: ctx.savedDir,
    startScript: ctx.startScript,
    liveModsDirs: ctx.liveModsDirs,
    bridgeRuntimeDirs: ctx.bridgeRuntimeDirs,
  };
}

module.exports = {
  publicContext,
  resolveContext,
  RUNTIME_ALIASES,
  resolveStartScript,
};
