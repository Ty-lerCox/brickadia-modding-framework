const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment } = require('./helpers');
const { runDoctor } = require('../src/doctor');
const { repair, repairAll } = require('../src/repair');

test('doctor reports disabled live BMF as repairable critical finding', () => {
  const env = makeEnvironment();
  const report = runDoctor(env.options);
  const disabled = report.findings.find(item => item.id === 'ue4ss.live.bmfDisabled');
  assert.equal(report.status, 'critical');
  assert.equal(disabled.severity, 'critical');
  assert.equal(disabled.repair.id, 'bmf.enable');
});

test('repair bmf.enable updates live mods files', () => {
  const env = makeEnvironment();
  const dryRun = repair('bmf.enable', { ...env.options, dryRun: true });
  assert.equal(dryRun.changes.length, 2);
  assert.equal(fs.readFileSync(path.join(env.liveMods, 'mods.txt'), 'utf8').includes('BMF : 1'), false);

  const result = repair('bmf.enable', env.options);
  assert.equal(result.changes.length, 2);
  assert.match(fs.readFileSync(path.join(env.liveMods, 'mods.txt'), 'utf8'), /BMF : 1/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(env.liveMods, 'mods.json'), 'utf8'))[0], {
    mod_name: 'BMF',
    mod_enabled: true,
  });
  assert.ok(result.logPath);
});

test('repair all applies doctor-selected repairs', () => {
  const env = makeEnvironment();
  const result = repairAll(env.options);
  assert.equal(result.repairs.length, 1);
  assert.equal(result.after.status, 'ok');
});

test('repair writes artifacts to user data for installed Desktop bundles', () => {
  const env = makeEnvironment();
  const installedRoot = path.join(env.root, 'Program Files', 'BMF Desktop', 'resources', 'bmf');
  fs.cpSync(env.bmfRoot, installedRoot, { recursive: true });
  const previousAppData = process.env.APPDATA;
  process.env.APPDATA = path.join(env.root, 'AppData', 'Roaming');

  try {
    const result = repair('bmf.copy', {
      ...env.options,
      bmfRoot: installedRoot,
    });
    const expectedRoot = path.join(process.env.APPDATA, 'BMF Desktop', 'bmfctl');
    assert.ok(result.backupRoot.startsWith(path.join(expectedRoot, 'backups')));
    assert.ok(result.logPath.startsWith(path.join(expectedRoot, 'repairs')));
    assert.equal(fs.existsSync(path.join(installedRoot, 'artifacts')), false);
  } finally {
    if (previousAppData === undefined) delete process.env.APPDATA;
    else process.env.APPDATA = previousAppData;
  }
});

test('doctor detects nested Omegga bridge session status files', () => {
  const env = makeEnvironment();
  const sessionDir = path.join(env.omeggaDir, 'data', 'ue4ss-bridge', 'session-1');
  fs.mkdirSync(sessionDir, { recursive: true });
  fs.writeFileSync(path.join(sessionDir, 'status.json'), '{"state":"running"}\n');

  const report = runDoctor(env.options);
  assert.ok(report.context.bridgeRuntimeDirs.includes(sessionDir));
  assert.equal(
    report.findings.find(item => item.id === 'omegga.bridge.statusPresent')?.severity,
    'ok',
  );
});

test('doctor marks missing Omegga launch flags as repairable and repair adds them', () => {
  const env = makeEnvironment();
  const startScript = path.join(env.root, 'Start-BrickadiaOmegga.ps1');
  fs.writeFileSync(
    path.join(env.compatRoot, 'bundles', 'CL13530', 'manifest.json'),
    JSON.stringify({ brickadia_cl: '13530', validated: false }, null, 2),
  );
  fs.mkdirSync(path.join(env.omeggaDir, 'dist', 'brickadia'), { recursive: true });
  fs.writeFileSync(
    path.join(env.omeggaDir, 'dist', 'brickadia', 'server.js'),
    [
      'OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL',
      'OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS',
      'OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE',
      'chat_broadcast',
      'chat_whisper',
      'chat_status_message',
    ].join('\n'),
  );
  fs.writeFileSync(
    startScript,
    "$omegga = 'C:\\\\server\\\\omegga'\n$env:OMEGGA_UE4SS_ALLOW_DEGRADED_WORLD_COMMANDS = '1'\n",
  );

  const report = runDoctor({ ...env.options, startScript });
  const missing = report.findings.find(item => item.id === 'omegga.launchEnv.missing');
  assert.equal(missing.severity, 'critical');
  assert.equal(missing.repair.id, 'omegga.launchEnv');

  const result = repair('omegga.launchEnv', { ...env.options, startScript });
  assert.ok(result.changes.some(change => change.name === 'OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE'));
  const text = fs.readFileSync(startScript, 'utf8');
  assert.match(text, /\$env:OMEGGA_BMF_SOURCE_DIR/);
  assert.match(text, /\$env:OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL = '1'/);
  assert.match(text, /\$env:OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS = '1'/);
  assert.match(text, /\$env:OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE = '1'/);
});
