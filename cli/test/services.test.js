const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createServiceAction } = require('../src/orchestrator');

test('bmfctl services previews blocked start contract without mutating', () => {
  const env = makeEnvironment();
  const startScript = path.join(env.omeggaDir, 'Start-BrickadiaOmegga.ps1');

  const action = createServiceAction('start-stack', {
    ...env.options,
    startScript,
  });

  assert.equal(action.dryRun, true);
  assert.equal(action.status, 'blocked');
  assert.equal(action.profile.paths.omeggaStartScript, startScript);
  assert.ok(action.command.display.includes('powershell.exe'));
  assert.ok(action.blockers.some(blocker => blocker.id === 'start-script-missing'));
  assert.ok(action.guardrails.includes('explicit-start-confirmation-required'));
});

test('bmfctl services allow installed user-data service roots outside bundled BMF assets', () => {
  const env = makeEnvironment();
  const startScript = path.join(env.omeggaDir, 'Start-LocalOmegga.ps1');
  const serviceRoot = path.join(env.root, 'BMF Desktop', 'services');
  write(startScript, 'Write-Output "bmfctl installed service root"\n');

  const action = createServiceAction('start-stack', {
    ...env.options,
    startScript,
    serviceRoot,
  });

  assert.equal(action.status, 'planned');
  assert.equal(action.paths.actionRoot, serviceRoot);
  assert.equal(action.blockers.some(blocker => blocker.id === 'service-root-outside-bmf-root'), false);
  assert.ok(action.paths.logPath.startsWith(serviceRoot));
  assert.ok(action.paths.journalPath.startsWith(serviceRoot));
  assert.ok(action.paths.pidPath.startsWith(serviceRoot));
});

test('bmfctl services start requires confirmation and writes journal metadata', () => {
  const env = makeEnvironment();
  const startScript = path.join(env.root, 'fake-start.js');
  write(startScript, 'console.log("bmfctl service start");\n');

  assert.throws(
    () => createServiceAction('start-stack', {
      ...env.options,
      apply: true,
      command: process.execPath,
      args: startScript,
    }),
    /--confirm start/,
  );

  const action = createServiceAction('start-stack', {
    ...env.options,
    apply: true,
    confirm: 'start',
    command: process.execPath,
    args: startScript,
  });

  assert.equal(action.status, 'started');
  assert.equal(fs.existsSync(action.paths.journalPath), true);
  assert.equal(fs.existsSync(action.paths.logPath), true);
  assert.equal(fs.existsSync(action.paths.pidPath), true);
});

test('bmfctl services stop and restart require owned PID confirmation', () => {
  const env = makeEnvironment();
  const actionRoot = path.join(env.bmfRoot, 'artifacts', 'local', 'services');
  const pidPath = path.join(actionRoot, 'local-omegga.pid.json');
  const pidMetadata = {
    schemaVersion: 1,
    profileId: 'local',
    actionRunId: 'start-stack-test',
    actionId: 'start-stack',
    service: 'omegga-runtime',
    pid: 8765,
    startedAt: '2026-06-16T12:00:00Z',
    command: {
      executable: process.execPath,
      args: [],
      cwd: env.omeggaDir,
      startScript: null,
      display: process.execPath,
    },
    logPath: path.join(actionRoot, 'local-omegga.log'),
    journalPath: path.join(actionRoot, 'start-stack-test.json'),
  };
  write(pidPath, JSON.stringify(pidMetadata, null, 2));

  assert.throws(
    () => createServiceAction('stop-stack', {
      ...env.options,
      apply: true,
      processInspector: () => ({ status: 'running', verified: true }),
    }),
    /--confirm stop/,
  );

  const killed = [];
  const stopped = createServiceAction('stop-stack', {
    ...env.options,
    apply: true,
    confirm: 'stop',
    processInspector: () => ({ status: 'running', verified: true }),
    processKiller: pid => {
      killed.push(pid);
      return { status: 'stopped', signal: 'test' };
    },
  });

  assert.equal(stopped.status, 'stopped');
  assert.deepEqual(killed, [8765]);
  assert.equal(fs.existsSync(pidPath), false);

  write(pidPath, JSON.stringify({ ...pidMetadata, pid: 8766 }, null, 2));
  const restarted = createServiceAction('restart-stack', {
    ...env.options,
    apply: true,
    confirm: 'restart',
    command: process.execPath,
    processInspector: () => ({ status: 'running', verified: true }),
    processKiller: pid => {
      killed.push(pid);
      return { status: 'stopped', signal: 'test' };
    },
    processSpawner: () => ({ pid: 9001, detached: true }),
  });

  assert.equal(restarted.status, 'restarted');
  assert.equal(restarted.stop.status, 'stopped');
  assert.equal(restarted.process.pid, 9001);
  assert.equal(JSON.parse(fs.readFileSync(pidPath, 'utf8')).pid, 9001);
});

test('bmfctl services preview Alloy launch contract', () => {
  const env = makeEnvironment();
  const alloyConfig = path.join(env.root, 'alloy', 'bmf.alloy');
  write(alloyConfig, 'logging { level = "info" }\n');

  const blocked = createServiceAction('start-alloy', {
    ...env.options,
    alloyExecutable: path.join(env.root, 'missing-alloy.exe'),
    alloyConfig,
  });

  assert.equal(blocked.status, 'blocked');
  assert.equal(blocked.service, 'grafana-alloy');
  assert.ok(blocked.blockers.some(blocker => blocker.id === 'alloy-executable-missing'));

  const action = createServiceAction('start-alloy', {
    ...env.options,
    alloyExecutable: process.execPath,
    alloyConfig,
    alloyReadyPort: 19090,
  });

  assert.equal(action.status, 'planned');
  assert.equal(action.service, 'grafana-alloy');
  assert.equal(action.paths.alloyExecutable, process.execPath);
  assert.equal(action.paths.alloyConfig, alloyConfig);
  assert.equal(path.basename(action.paths.pidPath), 'local-alloy.pid.json');
  assert.deepEqual(action.command.args, [
    'run',
    alloyConfig,
    `--storage.path=${action.paths.alloyStoragePath}`,
    '--server.http.listen-addr=127.0.0.1:19090',
  ]);
});

test('bmfctl services start and stop Alloy with owned PID metadata', () => {
  const env = makeEnvironment();
  const alloyConfig = path.join(env.root, 'alloy', 'bmf.alloy');
  write(alloyConfig, 'logging { level = "info" }\n');

  const started = createServiceAction('start-alloy', {
    ...env.options,
    apply: true,
    confirm: 'start',
    alloyExecutable: process.execPath,
    alloyConfig,
    processSpawner: () => ({ pid: 9010, detached: true }),
  });

  assert.equal(started.status, 'started');
  assert.equal(started.service, 'grafana-alloy');
  assert.equal(started.process.pid, 9010);
  assert.equal(JSON.parse(fs.readFileSync(started.paths.pidPath, 'utf8')).service, 'grafana-alloy');

  const killed = [];
  const stopped = createServiceAction('stop-alloy', {
    ...env.options,
    apply: true,
    confirm: 'stop',
    processInspector: () => ({ status: 'running', verified: true }),
    processKiller: pid => {
      killed.push(pid);
      return { status: 'stopped', signal: 'test' };
    },
  });

  assert.equal(stopped.status, 'stopped');
  assert.deepEqual(killed, [9010]);
  assert.equal(fs.existsSync(started.paths.pidPath), false);
});
