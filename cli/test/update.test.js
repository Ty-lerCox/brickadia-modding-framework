const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const {
  createUpdateCheck,
  createUpdateInstallPlan,
  createUpdatePlan,
  downloadUpdate,
  installUpdate,
} = require('../src/orchestrator');

test('bmfctl update check reads a release catalog without mutating services', () => {
  const env = makeEnvironment();
  const releaseDir = path.join(env.root, 'release');
  fs.mkdirSync(releaseDir, { recursive: true });
  const msiName = 'BMF-Desktop-0.2.0-x64.msi';
  const msiPath = path.join(releaseDir, msiName);
  write(msiPath, 'MSI fixture bytes');
  const sha256 = crypto.createHash('sha256').update(fs.readFileSync(msiPath)).digest('hex');
  const release = {
    version: '0.2.0',
    channel: 'dev',
    artifact: {
      fileName: msiName,
      url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
      bytes: fs.statSync(msiPath).size,
      sha256,
    },
    checksum: {
      fileName: `${msiName}.sha256`,
      sha256: 'b'.repeat(64),
    },
    manifest: {
      fileName: 'release-manifest.json',
      sha256: 'c'.repeat(64),
    },
    releaseNotes: {
      fileName: 'RELEASE_NOTES.md',
      sha256: 'd'.repeat(64),
    },
  };
  const catalogPath = path.join(releaseDir, 'release-catalog.json');
  write(catalogPath, JSON.stringify({
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
  }, null, 2));

  const check = createUpdateCheck({
    ...env.options,
    releaseCatalog: catalogPath,
    currentVersion: '0.1.0',
    releaseChannel: 'dev',
  });

  assert.equal(check.status, 'update-available');
  assert.equal(check.updateAvailable, true);
  assert.equal(check.latest.artifact.fileName, msiName);
  assert.equal(check.artifactVerification.status, 'verified');
  assert.equal(check.downloads, false);
  assert.equal(check.startsOrStopsServices, false);
});

test('bmfctl update plan and download stay download-only', async () => {
  const env = makeEnvironment();
  const body = Buffer.from('downloaded MSI fixture');
  const sha256 = crypto.createHash('sha256').update(body).digest('hex');
  const releaseDir = path.join(env.root, 'release');
  const msiName = 'BMF-Desktop-0.2.0-x64.msi';
  const release = {
    version: '0.2.0',
    channel: 'dev',
    artifact: {
      fileName: msiName,
      url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
      sha256,
    },
    checksum: {
      fileName: `${msiName}.sha256`,
      sha256: 'b'.repeat(64),
    },
    manifest: {
      fileName: 'release-manifest.json',
      sha256: 'c'.repeat(64),
    },
    releaseNotes: {
      fileName: 'RELEASE_NOTES.md',
      sha256: 'd'.repeat(64),
    },
  };
  const catalogPath = path.join(releaseDir, 'release-catalog.json');
  write(catalogPath, JSON.stringify({
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
  }, null, 2));

  const plan = createUpdatePlan({
    ...env.options,
    releaseCatalog: catalogPath,
    currentVersion: '0.1.0',
    downloadDir: path.join(env.root, 'downloads'),
  });
  assert.equal(plan.status, 'ready');
  assert.equal(plan.downloads, false);
  assert.equal(plan.installs, false);

  const result = await downloadUpdate({
    ...env.options,
    releaseCatalog: catalogPath,
    currentVersion: '0.1.0',
    downloadDir: path.join(env.root, 'downloads'),
    confirm: 'download',
    fetch: async () => ({
      ok: true,
      status: 200,
      statusText: 'OK',
      async arrayBuffer() {
        return body;
      },
    }),
  });

  assert.equal(result.status, 'downloaded');
  assert.equal(result.verification.status, 'verified');
  assert.equal(result.downloads, true);
  assert.equal(result.installs, false);
  assert.equal(fs.existsSync(result.artifact.outputPath), true);
});

test('bmfctl update install previews and launches only with confirmation', () => {
  const env = makeEnvironment();
  const body = Buffer.from('downloaded MSI fixture');
  const sha256 = crypto.createHash('sha256').update(body).digest('hex');
  const releaseDir = path.join(env.root, 'release');
  const downloadDir = path.join(env.root, 'downloads');
  const msiName = 'BMF-Desktop-0.2.0-x64.msi';
  const msiPath = path.join(downloadDir, msiName);
  write(msiPath, body);
  const release = {
    version: '0.2.0',
    channel: 'dev',
    artifact: {
      fileName: msiName,
      url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
      sha256,
    },
    checksum: {
      fileName: `${msiName}.sha256`,
      sha256: 'b'.repeat(64),
    },
    manifest: {
      fileName: 'release-manifest.json',
      sha256: 'c'.repeat(64),
    },
    releaseNotes: {
      fileName: 'RELEASE_NOTES.md',
      sha256: 'd'.repeat(64),
    },
  };
  const catalogPath = path.join(releaseDir, 'release-catalog.json');
  write(catalogPath, JSON.stringify({
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
  }, null, 2));

  const plan = createUpdateInstallPlan({
    ...env.options,
    releaseCatalog: catalogPath,
    currentVersion: '0.1.0',
    downloadDir,
  });
  assert.equal(plan.status, 'ready');
  assert.equal(plan.installer.verification.status, 'verified');
  assert.equal(plan.installs, false);

  assert.throws(
    () => installUpdate({
      ...env.options,
      releaseCatalog: catalogPath,
      currentVersion: '0.1.0',
      downloadDir,
      launcher: () => {
        throw new Error('launcher should not run without confirmation');
      },
    }),
    /--confirm install/,
  );

  const result = installUpdate({
    ...env.options,
    releaseCatalog: catalogPath,
    currentVersion: '0.1.0',
    downloadDir,
    confirm: 'install',
    launcher: command => ({
      status: 'launched',
      pid: 4321,
      command: command.display,
    }),
  });
  assert.equal(result.status, 'handoff-started');
  assert.equal(result.installs, true);
  assert.equal(result.startsOrStopsServices, false);
});
