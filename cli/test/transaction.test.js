const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createTransaction, rollbackTransaction } = require('../src/orchestrator');

const repoRoot = path.resolve(__dirname, '..', '..');
const manifest = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'manifests', 'unified-runtime.json'), 'utf8'),
);

test('bmfctl transaction dry-run plans shared install filesystem steps', () => {
  const env = makeEnvironment();
  writeTransactionSources(env);

  const transaction = createTransaction('install-stack', {
    ...env.options,
    manifest,
    telemetry: true,
    alloyConfig: path.join(env.root, 'alloy', 'bmf.alloy'),
  });

  assert.equal(transaction.dryRun, true);
  assert.equal(transaction.status, 'planned');
  assert.ok(transaction.steps.some(step => step.id === 'install-omegga-runtime'));
  assert.ok(transaction.steps.some(step => step.id === 'write-omegga-start-script'));
  assert.ok(transaction.steps.some(step => step.id === 'stage-bmf-runtime'));
  assert.ok(transaction.steps.some(step => step.id === 'stage-generic-bridge'));
  assert.ok(transaction.steps.some(step => step.id === 'write-alloy-config'));
  assert.equal(transaction.steps.some(step => step.content), false);
  assert.ok(transaction.guardrails.includes('explicit-apply-confirmation-required'));
});

test('bmfctl update-stack transaction verifies release evidence before component staging', () => {
  const env = makeEnvironment();
  writeTransactionSources(env);
  const release = writeDesktopReleaseEvidence(env);

  const transaction = createTransaction('update-stack', {
    ...env.options,
    manifest,
    releaseCatalog: release.catalogPath,
    releaseManifest: release.manifestPath,
  });

  assert.equal(transaction.status, 'planned');
  const stepById = new Map(transaction.steps.map(step => [step.id, step]));
  assert.equal(stepById.get('read-release-catalog').targetPath, release.catalogPath);
  assert.equal(stepById.get('read-release-manifest').targetPath, release.manifestPath);
  assert.equal(stepById.get('verify-release-checksums').status, 'ready');
  assert.equal(stepById.get('snapshot-current-components').actionId, 'backup-current-components');
  assert.equal(stepById.get('install-omegga-runtime').actionId, 'update-omegga-runtime');
  assert.equal(stepById.get('stage-bmf-runtime').actionId, 'update-bmf-runtime');
  assert.equal(stepById.get('stage-bmf-socket').actionId, 'update-native-helpers');

  const unsupportedIds = transaction.unsupportedActions.map(action => action.actionId);
  for (const actionId of [
    'fetch-release-catalog',
    'fetch-release-manifest',
    'verify-release-checksums',
    'backup-current-components',
    'update-bmf-runtime',
    'update-omegga-runtime',
    'update-native-helpers',
  ]) {
    assert.equal(unsupportedIds.includes(actionId), false, `${actionId} should be implemented by bmfctl transactions`);
  }
});

test('bmfctl repair-stack transaction maps repair actions to concrete steps', () => {
  const env = makeEnvironment();
  writeTransactionSources(env);

  const transaction = createTransaction('repair-stack', {
    ...env.options,
    manifest,
  });

  assert.equal(transaction.status, 'planned');
  const stepById = new Map(transaction.steps.map(step => [step.id, step]));
  assert.equal(stepById.get('repair-preflight-health').actionId, 'run-doctor');
  assert.equal(stepById.get('snapshot-repair-mutable-files').actionId, 'backup-mutable-files');
  assert.equal(stepById.get('repair-omegga-start-script').actionId, 'repair-launch-env');
  assert.equal(stepById.get('repair-bmf-runtime-files').actionId, 'repair-missing-runtime-files');
  assert.equal(stepById.get('repair-generic-bridge-plugin').actionId, 'repair-missing-runtime-files');
  assert.equal(stepById.get('repair-bmf-enabled-file').actionId, 'repair-mod-enablement');
  assert.equal(stepById.get('repair-mods-txt').actionId, 'repair-mod-enablement');
  assert.equal(stepById.get('repair-mods-json').actionId, 'repair-mod-enablement');
  assert.equal(stepById.get('repair-verification-health').actionId, 'verify-after-repair');

  const unsupportedIds = transaction.unsupportedActions.map(action => action.actionId);
  for (const actionId of [
    'run-doctor',
    'backup-mutable-files',
    'repair-launch-env',
    'repair-mod-enablement',
    'repair-missing-runtime-files',
    'verify-after-repair',
  ]) {
    assert.equal(unsupportedIds.includes(actionId), false, `${actionId} should be implemented by bmfctl transactions`);
  }
});

test('bmfctl transaction apply requires confirmation and writes a journal', () => {
  const env = makeEnvironment();
  writeTransactionSources(env);
  const alloyConfig = path.join(env.root, 'alloy', 'bmf.alloy');

  assert.throws(
    () => createTransaction('install-stack', {
      ...env.options,
      manifest,
      telemetry: true,
      alloyConfig,
      apply: true,
    }),
    /--confirm apply/,
  );

  const result = createTransaction('install-stack', {
    ...env.options,
    manifest,
    telemetry: true,
    alloyConfig,
    apply: true,
    confirm: 'apply',
  });

  assert.equal(result.status, 'applied');
  assert.equal(result.errors.length, 0);
  assert.equal(fs.existsSync(path.join(env.liveMods, 'BMF', 'bmf.json')), true);
  assert.equal(fs.existsSync(path.join(env.liveMods, 'BMFSocket', 'README.md')), true);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'package.json')), true);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'src', 'omegga', 'index.ts')), true);
  const startScript = path.join(env.omeggaDir, 'Start-BrickadiaOmegga.ps1');
  assert.equal(fs.existsSync(startScript), true);
  assert.match(fs.readFileSync(startScript, 'utf8'), /BMF_OMEGGA_BOOTSTRAP_BUILD_SCRIPT/);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'plugins', 'bmf-bridge', 'plugin.json')), true);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'plugins', 'bmf-player-sync', 'plugin.json')), true);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'plugins', 'bmf-minigame-events', 'plugin.json')), true);
  assert.equal(fs.existsSync(alloyConfig), true);
  assert.equal(fs.existsSync(result.journalPath), true);
  assert.ok(result.applied.some(step => step.id === 'stage-bmf-runtime' && step.backupPath));
  assert.ok(result.rollback.length > 0);
});

test('bmfctl rollback previews and applies a transaction journal rollback', () => {
  const env = makeEnvironment();
  writeTransactionSources(env);
  write(path.join(env.liveMods, 'BMF', 'old-marker.txt'), 'old install\n');
  const alloyConfig = path.join(env.root, 'alloy', 'bmf.alloy');

  const applyResult = createTransaction('install-stack', {
    ...env.options,
    manifest,
    telemetry: true,
    alloyConfig,
    apply: true,
    confirm: 'apply',
  });

  const rollbackPlan = rollbackTransaction(applyResult.journalPath);
  assert.equal(rollbackPlan.dryRun, true);
  assert.equal(rollbackPlan.status, 'planned');
  assert.equal(rollbackPlan.summary.blocked, 0);
  assert.ok(rollbackPlan.steps.some(step => step.action === 'restore-directory'));

  assert.throws(
    () => rollbackTransaction(applyResult.journalPath, {
      apply: true,
    }),
    /--confirm rollback/,
  );

  const rollbackResult = rollbackTransaction(applyResult.journalPath, {
    apply: true,
    confirm: 'rollback',
  });

  assert.equal(rollbackResult.status, 'rolled-back');
  assert.equal(rollbackResult.errors.length, 0);
  assert.equal(fs.existsSync(path.join(env.liveMods, 'BMF', 'old-marker.txt')), true);
  assert.equal(fs.existsSync(path.join(env.liveMods, 'BMFSocket')), false);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'Start-BrickadiaOmegga.ps1')), false);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'plugins', 'bmf-bridge')), false);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'plugins', 'bmf-player-sync')), false);
  assert.equal(fs.existsSync(path.join(env.omeggaDir, 'plugins', 'bmf-minigame-events')), false);
  assert.equal(fs.existsSync(alloyConfig), false);
  assert.equal(fs.existsSync(rollbackResult.journalPath), true);
});

function writeTransactionSources(env) {
  write(
    path.join(env.bmfRoot, 'packages', 'omegga-runtime', 'source', 'package.json'),
    JSON.stringify({ name: 'omegga', version: 'test', scripts: { 'package:bmf': 'node tools/package-bmf-omegga.js' } }, null, 2),
  );
  write(path.join(env.bmfRoot, 'packages', 'omegga-runtime', 'source', 'index.js'), 'module.exports = require("./src/omegga");\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-runtime', 'source', 'src', 'omegga', 'index.ts'), 'export const omegga = true;\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-runtime', 'source', 'src', 'brickadia', 'ue4ssBridge.ts'), 'export const bridge = true;\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-runtime', 'source', 'tools', 'package-bmf-omegga.js'), 'console.log("package bmf omegga");\n');
  write(path.join(env.bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMFSocket', 'README.md'), 'socket helper\n');
  write(path.join(env.bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMFSocket', 'dlls', '.gitkeep'), '');
  write(path.join(env.bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMFFrameTelemetry', 'README.md'), 'frame telemetry\n');
  write(path.join(env.bmfRoot, 'framework', 'ue4ss', 'Mods', 'BMFFrameTelemetry', 'dlls', '.gitkeep'), '');
  write(path.join(env.bmfRoot, 'packages', 'omegga-plugins', 'bmf-bridge', 'plugin.json'), '{"name":"bmf-bridge"}\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-plugins', 'bmf-bridge', 'omegga.plugin.js'), 'module.exports = class {}\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-plugins', 'bmf-player-sync', 'plugin.json'), '{"name":"bmf-player-sync"}\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-plugins', 'bmf-player-sync', 'omegga.plugin.js'), 'module.exports = class {}\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-plugins', 'bmf-minigame-events', 'plugin.json'), '{"name":"bmf-minigame-events"}\n');
  write(path.join(env.bmfRoot, 'packages', 'omegga-plugins', 'bmf-minigame-events', 'omegga.plugin.js'), 'module.exports = class {}\n');
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function fileRecord(filePath, role) {
  return {
    role,
    fileName: path.basename(filePath),
    path: path.basename(filePath),
    bytes: fs.statSync(filePath).size,
    sha256: sha256File(filePath),
  };
}

function writeJson(filePath, value) {
  write(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeBomJson(filePath, value) {
  write(filePath, `\uFEFF${JSON.stringify(value, null, 2)}\n`);
}

function writeDesktopReleaseEvidence(env) {
  const releaseDir = path.join(env.bmfRoot, 'artifacts', 'local', 'bmf-desktop-release');
  const artifactName = 'BMF-Desktop-0.2.0-x64.msi';
  const artifactPath = path.join(releaseDir, artifactName);
  const checksumPath = `${artifactPath}.sha256`;
  const manifestPath = path.join(releaseDir, 'release-manifest.json');
  const catalogPath = path.join(releaseDir, 'release-catalog.json');
  const releaseNotesPath = path.join(releaseDir, 'RELEASE_NOTES.md');
  write(artifactPath, 'MSI fixture bytes');
  const artifact = fileRecord(artifactPath, 'installer');
  write(checksumPath, `${artifact.sha256}  ${artifactName}\n`);
  const checksum = fileRecord(checksumPath, 'checksum');
  write(releaseNotesPath, '# Fixture Release\n');
  const releaseNotes = fileRecord(releaseNotesPath, 'release-notes');
  writeBomJson(manifestPath, {
    schemaVersion: 1,
    releaseKind: 'bmf-desktop-msi',
    bmfDesktopVersion: '0.2.0',
    primaryArtifact: artifact,
    releaseCatalog: 'release-catalog.json',
    requiredArtifacts: [artifactName, `${artifactName}.sha256`, 'release-manifest.json', 'release-catalog.json', 'RELEASE_NOTES.md'],
  });
  const manifestRecord = fileRecord(manifestPath, 'release-manifest');
  const release = {
    version: '0.2.0',
    channel: 'dev',
    artifact,
    checksum,
    manifest: manifestRecord,
    releaseNotes,
  };
  writeBomJson(catalogPath, {
    schemaVersion: 1,
    catalogKind: 'bmf-desktop-release-catalog',
    releaseChannel: 'dev',
    latest: release,
    releases: [release],
    updateGuardrails: [
      'verify-sha256-before-install',
      'require-user-confirmation-before-desktop-update',
      'keep-desktop-update-separate-from-managed-server-updates',
      'do-not-stop-running-managed-services-without-confirmation',
    ],
  });
  return {
    catalogPath,
    manifestPath,
  };
}
