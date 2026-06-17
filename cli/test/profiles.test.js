const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment } = require('./helpers');
const {
  currentProfile,
  deleteProfile,
  listProfiles,
  saveProfile,
  selectProfile,
} = require('../src/orchestrator');
const { resolveContext } = require('../src/context');

test('bmfctl profiles persist, select, resolve, and delete local server profiles', () => {
  const env = makeEnvironment();
  const profileStore = path.join(env.root, 'profiles', 'profiles.json');

  const saved = saveProfile({
    ...env.options,
    profile: 'local-one',
    profileName: 'Local One',
    telemetry: true,
    dashboardUrl: 'https://grafana.example/d/bmf?token=profile-token',
    brickadiaPort: '17777',
    omeggaWebPort: '18080',
    profileStore,
  });

  assert.equal(saved.selectedProfileId, 'local-one');
  assert.equal(saved.summary.total, 1);
  assert.equal(fs.existsSync(profileStore), true);
  assert.equal(JSON.stringify(saved).includes('profile-token'), false);
  assert.equal(saved.profiles[0].paths.brickadiaWin64, env.gameWin64);
  assert.equal(saved.profiles[0].ports.brickadia, 17777);

  saveProfile({
    ...env.options,
    profile: 'secondary',
    profileName: 'Secondary',
    profileStore,
    noSelect: true,
  });

  const listed = listProfiles({
    ...env.options,
    profileStore,
  });
  assert.equal(listed.summary.total, 2);
  assert.equal(listed.selectedProfileId, 'local-one');

  const selected = selectProfile('secondary', {
    ...env.options,
    profileStore,
  });
  assert.equal(selected.selectedProfileId, 'secondary');

  const current = currentProfile({
    ...env.options,
    profileStore,
  });
  assert.equal(current.profile.id, 'secondary');
  assert.equal(current.profile.paths.omeggaRuntime, env.omeggaDir);

  const resolved = currentProfile({
    ...env.options,
    profile: 'local-one',
    profileStore,
  });
  assert.equal(resolved.profile.id, 'local-one');
  assert.equal(resolved.profile.telemetry.dashboardUrl, 'https://grafana.example/d/bmf?token=[redacted]');

  const deleted = deleteProfile('secondary', {
    ...env.options,
    profileStore,
  });
  assert.equal(deleted.summary.total, 1);
  assert.equal(deleted.selectedProfileId, 'local-one');
});

test('context resolver hydrates selected profile paths for legacy commands', () => {
  const env = makeEnvironment();
  const profileStore = path.join(env.root, 'profiles', 'profiles.json');
  const runtimeDir = path.join(env.liveMods, 'BMF', 'runtime');

  saveProfile({
    ...env.options,
    profile: 'installed-local',
    profileName: 'Installed Local',
    bmfRuntimeDir: runtimeDir,
    profileStore,
  });

  const ctx = resolveContext({
    bmfRoot: env.bmfRoot,
    profile: 'installed-local',
    profileStore,
  });

  assert.equal(ctx.gameWin64Dir, env.gameWin64);
  assert.equal(ctx.omeggaDir, env.omeggaDir);
  assert.equal(ctx.liveModsDirs[0], env.liveMods);
});
