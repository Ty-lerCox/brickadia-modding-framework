const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {
  buildServiceHealth,
  buildServiceDiagnostics,
  collectLocalProfileStatus,
  collectLogSnapshot,
  collectTrafficSnapshot,
  componentById,
  createBootstrapPlan,
  createDesktopUpdateCheck,
  createDesktopUpdateInstallPlan,
  createDesktopUpdatePlan,
  createOperationPlan,
  createOperationTransaction,
  createPrerequisiteAudit,
  createRollbackTransaction,
  createDashboardImportPlan,
  createServerProfile,
  createServiceActionPlan,
  createTelemetryOnboardingPlan,
  createTroubleshootingSnapshotPlan,
  deleteStoredProfile,
  executeDashboardImport,
  executeDesktopUpdateDownload,
  executeDesktopUpdateInstallHandoff,
  executeOperationTransaction,
  executeRollbackTransaction,
  executeServiceAction,
  __private: serviceActionInternals,
  expectedReleaseArtifacts,
  findTemplatePlaceholders,
  getStoredProfile,
  getConfiguredPortTargets,
  latestDesktopRelease,
  loadProfileRegistry,
  loadUnifiedRuntimeManifest,
  OPERATION_IDS,
  PROFILE_BACKENDS,
  RELEASE_CATALOG_GUARDRAILS,
  selectStoredProfile,
  upsertStoredProfile,
  validateDesktopReleaseCatalog,
  validateUnifiedRuntimeManifest,
  resetTrafficSocketClients,
  writeTrafficTraceExport,
  writeDashboardImportPayload,
  writeTelemetryAlloyConfig,
  writeTroubleshootingSnapshot,
} = require('../src');

const repoRoot = path.resolve(__dirname, '..', '..', '..');

async function createTrafficSocketServer(t, options = {}) {
  const token = options.token || 'socket-token';
  const received = [];
  const server = net.createServer(socket => {
    socket.setEncoding('utf8');
    let buffer = '';
    socket.on('data', chunk => {
      buffer += String(chunk || '');
      let index = buffer.indexOf('\n');
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) {
          const message = JSON.parse(line);
          received.push(message);
          if (message.type === 'hello' && message.token === token) {
            for (const envelope of options.envelopes || []) {
              socket.write(`${JSON.stringify(envelope)}\n`);
            }
          }
        }
        index = buffer.indexOf('\n');
      }
    });
  });
  t.after(() => {
    resetTrafficSocketClients();
    server.close();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    token,
    received,
    port: server.address().port,
  };
}

async function waitForTrafficSnapshot(input, options, predicate) {
  let snapshot = collectTrafficSnapshot(input, options);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate(snapshot)) return snapshot;
    await new Promise(resolve => setTimeout(resolve, 20));
    snapshot = collectTrafficSnapshot(input, options);
  }
  return snapshot;
}

test('loads and validates the repository unified runtime manifest', () => {
  const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
  const validation = validateUnifiedRuntimeManifest(manifest, { root: repoRoot });

  assert.equal(validation.ok, true, validation.errors.join('\n'));
  assert.ok(componentById(manifest, 'orchestrator-core'));
  assert.equal(manifest.desktop.renderer, 'Angular');
  assert.match(manifest.desktop.componentSystem, /Angular Material 3/);
  assert.equal(manifest.desktop.installer, 'MSI');
  assert.deepEqual(manifest.orchestration.operationIds, OPERATION_IDS);
  assert.equal(manifest.orchestration.defaultMode, 'dry-run');
});

test('resolves desktop release artifacts for a concrete version', () => {
  const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
  assert.deepEqual(expectedReleaseArtifacts(manifest, '0.1.0'), [
    'BMF-Desktop-0.1.0-x64.msi',
    'BMF-Desktop-0.1.0-x64.msi.sha256',
    'BMF-Desktop-0.1.0-portable-x64.exe',
    'BMF-Desktop-0.1.0-portable-x64.exe.sha256',
    'release-manifest.json',
    'release-catalog.json',
    'RELEASE_NOTES.md',
  ]);
});

test('validates desktop release catalogs before update checks consume them', () => {
  const release = {
    version: '0.1.0',
    channel: 'dev',
    artifact: {
      fileName: 'BMF-Desktop-0.1.0-x64.msi',
      sha256: 'a'.repeat(64),
      bytes: 1024,
    },
    checksum: {
      fileName: 'BMF-Desktop-0.1.0-x64.msi.sha256',
      sha256: 'b'.repeat(64),
      bytes: 128,
    },
    manifest: {
      fileName: 'release-manifest.json',
      sha256: 'c'.repeat(64),
      bytes: 2048,
    },
    releaseNotes: {
      fileName: 'RELEASE_NOTES.md',
      sha256: 'd'.repeat(64),
      bytes: 512,
    },
  };
  const catalog = {
    schemaVersion: 1,
    catalogKind: 'bmf-desktop-release-catalog',
    releaseChannel: 'dev',
    latest: release,
    releases: [release],
    updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
  };

  const validation = validateDesktopReleaseCatalog(catalog, { releaseChannel: 'dev' });
  assert.equal(validation.ok, true, validation.errors.join('\n'));
  assert.equal(validation.latestVersion, '0.1.0');
  const latest = latestDesktopRelease(catalog, { releaseChannel: 'dev' });
  assert.equal(latest.status, 'ready');
  assert.equal(latest.release.artifact.fileName, 'BMF-Desktop-0.1.0-x64.msi');

  const unsafe = validateDesktopReleaseCatalog({
    ...catalog,
    updateGuardrails: RELEASE_CATALOG_GUARDRAILS.filter(item => item !== 'verify-sha256-before-install'),
  });
  assert.equal(unsafe.ok, false);
  assert.ok(unsafe.errors.some(error => error.includes('verify-sha256-before-install')));
});

test('checks desktop updates from a local release catalog without mutating files', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-desktop-update-check-'));
  try {
    fs.mkdirSync(path.join(root, 'apps', 'bmf-desktop'), { recursive: true });
    fs.writeFileSync(
      path.join(root, 'apps', 'bmf-desktop', 'package.json'),
      JSON.stringify({ version: '0.1.0' }),
    );
    const releaseDir = path.join(root, 'release');
    fs.mkdirSync(releaseDir, { recursive: true });
    const msiName = 'BMF-Desktop-0.2.0-x64.msi';
    const msiPath = path.join(releaseDir, msiName);
    fs.writeFileSync(msiPath, 'MSI fixture bytes');
    const msiSha256 = crypto.createHash('sha256').update(fs.readFileSync(msiPath)).digest('hex');
    const release = {
      version: '0.2.0',
      channel: 'dev',
    artifact: {
      fileName: msiName,
      url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
      sha256: msiSha256,
      bytes: fs.statSync(msiPath).size,
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
    fs.writeFileSync(catalogPath, JSON.stringify({
      schemaVersion: 1,
      catalogKind: 'bmf-desktop-release-catalog',
      releaseChannel: 'dev',
      latest: release,
      releases: [release],
      updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    }));

    const check = createDesktopUpdateCheck({
      root,
      catalogPath,
      releaseChannel: 'dev',
    });

    assert.equal(check.status, 'update-available');
    assert.equal(check.updateAvailable, true);
    assert.equal(check.currentVersion, '0.1.0');
    assert.equal(check.latest.version, '0.2.0');
    assert.equal(check.artifactVerification.status, 'verified');
    assert.equal(check.mutates, false);
    assert.equal(check.downloads, false);
    assert.equal(check.startsOrStopsServices, false);
    assert.ok(check.guardrails.includes('verify-sha256-before-install'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('checks desktop updates from the default desktop release artifact layout', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-desktop-default-update-check-'));
  try {
    fs.mkdirSync(path.join(root, 'apps', 'bmf-desktop'), { recursive: true });
    fs.writeFileSync(
      path.join(root, 'apps', 'bmf-desktop', 'package.json'),
      JSON.stringify({ version: '0.1.0' }),
    );
    const releaseDir = path.join(root, 'artifacts', 'local', 'bmf-desktop-release');
    fs.mkdirSync(releaseDir, { recursive: true });
    const msiName = 'BMF-Desktop-0.2.0-x64.msi';
    const msiPath = path.join(releaseDir, msiName);
    fs.writeFileSync(msiPath, 'MSI fixture bytes');
    const msiSha256 = crypto.createHash('sha256').update(fs.readFileSync(msiPath)).digest('hex');
    const release = {
      version: '0.2.0',
      channel: 'dev',
      artifact: {
        fileName: msiName,
        url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
        sha256: msiSha256,
        bytes: fs.statSync(msiPath).size,
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
    fs.writeFileSync(catalogPath, JSON.stringify({
      schemaVersion: 1,
      catalogKind: 'bmf-desktop-release-catalog',
      releaseChannel: 'dev',
      latest: release,
      releases: [release],
      updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    }));

    const check = createDesktopUpdateCheck({
      root,
      releaseChannel: 'dev',
    });

    assert.equal(check.catalogPath, catalogPath);
    assert.equal(check.status, 'update-available');
    assert.equal(check.artifactVerification.status, 'verified');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans desktop update downloads without installing or stopping services', () => {
  const release = {
    version: '0.2.0',
    channel: 'dev',
    artifact: {
      fileName: 'BMF-Desktop-0.2.0-x64.msi',
      url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
      sha256: 'a'.repeat(64),
    },
    checksum: {
      fileName: 'BMF-Desktop-0.2.0-x64.msi.sha256',
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
  const plan = createDesktopUpdatePlan({
    root: repoRoot,
    currentVersion: '0.1.0',
    catalog: {
      schemaVersion: 1,
      catalogKind: 'bmf-desktop-release-catalog',
      releaseChannel: 'dev',
      latest: release,
      releases: [release],
      updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    },
  });

  assert.equal(plan.status, 'ready');
  assert.equal(plan.dryRun, true);
  assert.equal(plan.downloads, false);
  assert.equal(plan.installs, false);
  assert.equal(plan.startsOrStopsServices, false);
  assert.equal(plan.artifact.url, 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi');
  assert.ok(plan.guardrails.includes('download-only-do-not-install'));
  assert.ok(plan.steps.some(step => step.id === 'verify-desktop-msi-sha256'));
});

test('downloads desktop update only with confirmation and verifies SHA256', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-desktop-update-download-'));
  try {
    const body = Buffer.from('downloaded MSI fixture');
    const sha256 = crypto.createHash('sha256').update(body).digest('hex');
    const release = {
      version: '0.2.0',
      channel: 'dev',
      artifact: {
        fileName: 'BMF-Desktop-0.2.0-x64.msi',
        url: 'https://downloads.example/BMF-Desktop-0.2.0-x64.msi',
        sha256,
      },
      checksum: {
        fileName: 'BMF-Desktop-0.2.0-x64.msi.sha256',
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
    const catalog = {
      schemaVersion: 1,
      catalogKind: 'bmf-desktop-release-catalog',
      releaseChannel: 'dev',
      latest: release,
      releases: [release],
      updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    };

    await assert.rejects(
      () => executeDesktopUpdateDownload({
        root,
        currentVersion: '0.1.0',
        catalog,
        fetch: async () => {
          throw new Error('fetch should not run without confirmation');
        },
      }),
      /--confirm download/,
    );

    const requests = [];
    const result = await executeDesktopUpdateDownload({
      root,
      currentVersion: '0.1.0',
      catalog,
      confirm: 'download',
      fetch: async (url, request) => {
        requests.push({ url, request });
        return {
          ok: true,
          status: 200,
          statusText: 'OK',
          async arrayBuffer() {
            return body;
          },
        };
      },
    });

    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, release.artifact.url);
    assert.equal(result.status, 'downloaded');
    assert.equal(result.verification.status, 'verified');
    assert.equal(result.downloads, true);
    assert.equal(result.installs, false);
    assert.equal(result.startsOrStopsServices, false);
    assert.equal(fs.existsSync(result.artifact.outputPath), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans and launches desktop update installer handoff only after MSI verification', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-desktop-update-install-'));
  try {
    const body = Buffer.from('downloaded MSI fixture');
    const sha256 = crypto.createHash('sha256').update(body).digest('hex');
    const downloadDir = path.join(root, 'updates');
    const msiName = 'BMF-Desktop-0.2.0-x64.msi';
    const msiPath = path.join(downloadDir, msiName);
    fs.mkdirSync(downloadDir, { recursive: true });
    fs.writeFileSync(msiPath, body);
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
    const catalog = {
      schemaVersion: 1,
      catalogKind: 'bmf-desktop-release-catalog',
      releaseChannel: 'dev',
      latest: release,
      releases: [release],
      updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    };

    const plan = createDesktopUpdateInstallPlan({
      root,
      currentVersion: '0.1.0',
      downloadDir,
      catalog,
    });
    assert.equal(plan.status, 'ready');
    assert.equal(plan.installer.verification.status, 'verified');
    assert.match(plan.command.display, /msiexec\.exe \/i/);
    assert.equal(plan.installs, false);
    assert.equal(plan.startsOrStopsServices, false);

    assert.throws(
      () => executeDesktopUpdateInstallHandoff({
        root,
        currentVersion: '0.1.0',
        downloadDir,
        catalog,
        launcher: () => {
          throw new Error('launcher should not run without confirmation');
        },
      }),
      /--confirm install/,
    );

    const launches = [];
    const handoff = executeDesktopUpdateInstallHandoff({
      root,
      currentVersion: '0.1.0',
      downloadDir,
      catalog,
      confirm: 'install',
      launcher: command => {
        launches.push(command);
        return {
          status: 'launched',
          pid: 1234,
          command: command.display,
        };
      },
    });

    assert.equal(launches.length, 1);
    assert.equal(handoff.status, 'handoff-started');
    assert.equal(handoff.launched, true);
    assert.equal(handoff.installs, true);
    assert.equal(handoff.startsOrStopsServices, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('reports missing desktop release catalog as a non-mutating update check', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-desktop-update-missing-'));
  try {
    const check = createDesktopUpdateCheck({
      root,
      catalogPath: path.join(root, 'missing-release-catalog.json'),
      currentVersion: '0.1.0',
    });

    assert.equal(check.status, 'catalog-missing');
    assert.equal(check.updateAvailable, false);
    assert.equal(check.validation.ok, false);
    assert.equal(check.artifactVerification.status, 'not-checked');
    assert.equal(check.mutates, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('creates normalized server profile defaults for desktop and CLI use', () => {
  const profile = createServerProfile({
    name: 'Local Dev Server',
    telemetry: { enabled: true, dashboardUrl: 'https://grafana.example/d/bmf' },
  });

  assert.equal(profile.id, 'local-dev-server');
  assert.equal(profile.backend, 'local-process');
  assert.deepEqual(PROFILE_BACKENDS, ['local-process']);
  assert.equal(profile.ports.brickadia, 7777);
  assert.equal(profile.ports.omeggaWeb, 8080);
  assert.equal(profile.telemetry.enabled, true);
});

test('unsupported launcher backend input normalizes to local process', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-local-profile-'));
  try {
    const profile = createServerProfile({
      name: 'Local Server',
      backend: 'unsupported-container-backend',
      paths: {
        bmfRoot: root,
      },
    });

    assert.equal(profile.backend, 'local-process');
    assert.deepEqual(profile.backendConfig, {});

    const plan = createServiceActionPlan('start-stack', { profile }, {
      root,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(plan.backend, 'local-process');
    assert.equal(plan.status, 'blocked');
    assert.equal(plan.command.display, '(not configured)');
    assert.ok(plan.blockers.some(item => item.id === 'omegga-runtime-not-configured'));
    assert.ok(plan.blockers.some(item => item.id === 'start-command-not-configured'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('persists local server profiles with selection and secret redaction', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-profiles-'));
  try {
    const storePath = path.join(root, 'profiles', 'profiles.json');
    const empty = loadProfileRegistry({ root, profileStorePath: storePath });
    assert.equal(empty.summary.total, 0);
    assert.equal(empty.selectedProfileId, null);

    const saved = upsertStoredProfile({
      name: 'Local Test Server',
      paths: {
        brickadiaWin64: path.join(root, 'Brickadia', 'Binaries', 'Win64'),
        omeggaRuntime: path.join(root, 'omegga'),
        bmfRoot: root,
        grafanaAlloyConfig: path.join(root, 'alloy', 'bmf.alloy'),
      },
      ports: {
        brickadia: 17777,
        omeggaWeb: 18080,
      },
      telemetry: {
        enabled: true,
        dashboardUrl: 'https://grafana.example/d/bmf?token=secret-token',
      },
    }, {
      root,
      profileStorePath: storePath,
    });

    assert.equal(saved.summary.total, 1);
    assert.equal(saved.selectedProfileId, 'local-test-server');
    assert.equal(fs.existsSync(storePath), true);
    assert.equal(JSON.stringify(saved).includes('secret-token'), false);
    assert.equal(saved.profiles[0].telemetry.dashboardUrl, 'https://grafana.example/d/bmf?token=[redacted]');
    assert.equal(path.isAbsolute(saved.profiles[0].paths.brickadiaWin64), true);

    upsertStoredProfile({
      id: 'secondary',
      name: 'Secondary',
      paths: {
        bmfRoot: root,
      },
    }, {
      root,
      profileStorePath: storePath,
      select: false,
    });
    const selected = selectStoredProfile('secondary', { root, profileStorePath: storePath });
    assert.equal(selected.selectedProfileId, 'secondary');
    assert.equal(getStoredProfile(null, { root, profileStorePath: storePath }).id, 'secondary');

    const deleted = deleteStoredProfile('secondary', { root, profileStorePath: storePath });
    assert.equal(deleted.summary.total, 1);
    assert.equal(deleted.selectedProfileId, 'local-test-server');
    assert.equal(getStoredProfile('secondary', { root, profileStorePath: storePath }), null);
    assert.ok(deleted.guardrails.includes('do-not-store-secret-values'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans service start as an explicit dry-run launch contract', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-service-plan-'));
  try {
    const omeggaRuntime = path.join(root, 'omegga');
    fs.mkdirSync(omeggaRuntime, { recursive: true });

    const plan = createServiceActionPlan('start-stack', {
      name: 'Service Server',
      paths: {
        bmfRoot: root,
        omeggaRuntime,
        omeggaStartScript: path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1'),
      },
    }, {
      root,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(plan.dryRun, true);
    assert.equal(plan.status, 'blocked');
    assert.ok(plan.blockers.some(item => item.id === 'start-script-missing'));
    assert.ok(plan.command.display.includes('powershell.exe'));
    assert.ok(plan.paths.logPath.endsWith('service-server-omegga.log'));
    assert.ok(plan.guardrails.includes('configured-start-script-only'));
    assert.ok(plan.guardrails.includes('do-not-send-bmf-commands'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans installed service actions with user-data service roots outside the BMF asset root', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-installed-root-'));
  const serviceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-user-services-'));
  try {
    const omeggaRuntime = path.join(root, 'omegga');
    const startScript = path.join(omeggaRuntime, 'Start-LocalOmegga.ps1');
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(startScript, 'Write-Output "installed service fixture"\n', 'utf8');

    const plan = createServiceActionPlan('start-stack', {
      name: 'Installed Service Server',
      paths: {
        bmfRoot: root,
        omeggaRuntime,
        omeggaStartScript: startScript,
      },
    }, {
      root,
      serviceRoot,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(plan.status, 'planned');
    assert.equal(plan.paths.actionRoot, serviceRoot);
    assert.ok(plan.paths.logPath.startsWith(serviceRoot));
    assert.ok(plan.paths.journalPath.startsWith(serviceRoot));
    assert.ok(plan.paths.pidPath.startsWith(serviceRoot));
    assert.equal(plan.blockers.some(item => item.id === 'service-root-outside-bmf-root'), false);
    assert.ok(plan.warnings.some(item => item.id === 'port-diagnostics-not-inspected'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(serviceRoot, { recursive: true, force: true });
  }
});

test('starts service action only with explicit confirmation and writes launch evidence', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-service-start-'));
  try {
    const omeggaRuntime = path.join(root, 'omegga');
    const scriptPath = path.join(root, 'start.js');
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(scriptPath, 'console.log("BMF service action test start");\n', 'utf8');

    assert.throws(
      () => executeServiceAction('start-stack', {
        name: 'Service Server',
        paths: {
          bmfRoot: root,
          omeggaRuntime,
        },
      }, {
        root,
        dryRun: false,
        command: process.execPath,
        args: [scriptPath],
        cwd: os.tmpdir(),
      }),
      /--confirm start/,
    );

    const result = executeServiceAction('start-stack', {
      name: 'Service Server',
      paths: {
        bmfRoot: root,
        omeggaRuntime,
      },
    }, {
      root,
      dryRun: false,
      confirm: 'start',
      command: process.execPath,
      args: [scriptPath],
      cwd: os.tmpdir(),
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(result.status, 'started');
    assert.equal(result.process.detached, process.platform !== 'win32');
    assert.equal(fs.existsSync(result.paths.logPath), true);
    assert.equal(fs.existsSync(result.paths.journalPath), true);
    assert.equal(fs.existsSync(result.paths.pidPath), true);
    assert.equal(JSON.parse(fs.readFileSync(result.paths.pidPath, 'utf8')).pid, result.process.pid);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('stops only verified BMF-owned service processes and cleans PID metadata', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-service-stop-'));
  try {
    const omeggaRuntime = path.join(root, 'omegga');
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    const profile = createServerProfile({
      name: 'Service Server',
      paths: {
        bmfRoot: root,
        omeggaRuntime,
      },
    });
    const actionRoot = path.join(root, 'artifacts', 'local', 'services');
    const pidPath = path.join(actionRoot, `${profile.id}-omegga.pid.json`);
    fs.mkdirSync(actionRoot, { recursive: true });
    fs.writeFileSync(pidPath, JSON.stringify({
      schemaVersion: 1,
      profileId: profile.id,
      actionRunId: 'start-stack-2026',
      actionId: 'start-stack',
      service: 'omegga-runtime',
      pid: 4321,
      startedAt: '2026-06-16T12:00:00Z',
      command: {
        executable: process.execPath,
        args: [],
        cwd: omeggaRuntime,
        startScript: null,
        display: process.execPath,
      },
      logPath: path.join(actionRoot, `${profile.id}-omegga.log`),
      journalPath: path.join(actionRoot, 'start-stack-2026.json'),
    }));

    const unverified = createServiceActionPlan('stop-stack', { profile }, {
      root,
      processInspector: () => ({
        status: 'running',
        verified: false,
        summary: 'test inspector refused verification',
      }),
    });
    assert.equal(unverified.status, 'blocked');
    assert.ok(unverified.blockers.some(item => item.id === 'owned-process-unverified'));

    assert.throws(
      () => executeServiceAction('stop-stack', { profile }, {
        root,
        dryRun: false,
        processInspector: () => ({ status: 'running', verified: true }),
      }),
      /--confirm stop/,
    );

    const killed = [];
    const stopped = executeServiceAction('stop-stack', { profile }, {
      root,
      dryRun: false,
      confirm: 'stop',
      processInspector: () => ({
        status: 'running',
        verified: true,
        summary: 'test inspector verified owned process',
      }),
      processKiller: pid => {
        killed.push(pid);
        return { status: 'stopped', signal: 'test' };
      },
      now: '2026-06-16T12:05:00Z',
    });

    assert.equal(stopped.status, 'stopped');
    assert.deepEqual(killed, [4321]);
    assert.equal(stopped.stop.pidFileRemoved, true);
    assert.equal(fs.existsSync(pidPath), false);
    assert.equal(fs.existsSync(stopped.paths.journalPath), true);
    assert.ok(stopped.guardrails.includes('verify-owned-process-before-stop'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('matches Windows PowerShell JSON date PID metadata for owned service verification', () => {
  const startScript = 'C:\\Users\\tycox\\AppData\\Roaming\\BMFDesktop\\scripts\\Start-LocalOmegga.ps1';
  const startedAt = '2026-06-17T13:24:17.781Z';
  const createdMs = Date.parse(startedAt);

  assert.equal(serviceActionInternals.processCreationTime(`/Date(${createdMs})/`), createdMs);
  assert.equal(
    serviceActionInternals.processRecordMatchesMetadata(
      {
        ExecutablePath: 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        CommandLine: `"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ${startScript} `,
        CreationDate: `/Date(${createdMs})/`,
      },
      {
        startedAt,
        command: {
          executable: 'powershell.exe',
          startScript,
        },
      },
    ),
    true,
  );
});

test('uses forceful Windows taskkill arguments for verified owned process trees', () => {
  assert.deepEqual(serviceActionInternals.taskkillArgs(24180), ['/PID', '24180', '/T', '/F']);
});

test('restarts verified owned services by stopping then writing fresh launch metadata', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-service-restart-'));
  try {
    const omeggaRuntime = path.join(root, 'omegga');
    const startScript = path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1');
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(startScript, 'Write-Output "restart fixture"\n', 'utf8');
    const profile = createServerProfile({
      name: 'Restart Server',
      paths: {
        bmfRoot: root,
        omeggaRuntime,
        omeggaStartScript: startScript,
      },
    });
    const actionRoot = path.join(root, 'artifacts', 'local', 'services');
    const pidPath = path.join(actionRoot, `${profile.id}-omegga.pid.json`);
    fs.mkdirSync(actionRoot, { recursive: true });
    fs.writeFileSync(pidPath, JSON.stringify({
      schemaVersion: 1,
      profileId: profile.id,
      actionRunId: 'start-stack-2026',
      actionId: 'start-stack',
      service: 'omegga-runtime',
      pid: 4322,
      startedAt: '2026-06-16T12:00:00Z',
      command: {
        executable: 'powershell.exe',
        args: ['-File', startScript],
        cwd: omeggaRuntime,
        startScript,
        display: `powershell.exe -File ${startScript}`,
      },
      logPath: path.join(actionRoot, `${profile.id}-omegga.log`),
      journalPath: path.join(actionRoot, 'start-stack-2026.json'),
    }));

    assert.throws(
      () => executeServiceAction('restart-stack', { profile }, {
        root,
        dryRun: false,
        processInspector: () => ({ status: 'running', verified: true }),
      }),
      /--confirm restart/,
    );

    const killed = [];
    const restarted = executeServiceAction('restart-stack', { profile }, {
      root,
      dryRun: false,
      confirm: 'restart',
      processInspector: () => ({
        status: 'running',
        verified: true,
        summary: 'test inspector verified owned process',
      }),
      processKiller: pid => {
        killed.push(pid);
        return { status: 'stopped', signal: 'test' };
      },
      processSpawner: () => ({
        pid: 5555,
        detached: true,
      }),
      now: '2026-06-16T12:05:00Z',
    });

    assert.equal(restarted.status, 'restarted');
    assert.deepEqual(killed, [4322]);
    assert.equal(restarted.stop.status, 'stopped');
    assert.equal(restarted.process.pid, 5555);
    assert.equal(fs.existsSync(restarted.paths.journalPath), true);
    const nextPid = JSON.parse(fs.readFileSync(pidPath, 'utf8'));
    assert.equal(nextPid.pid, 5555);
    assert.equal(nextPid.actionId, 'restart-stack');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('builds service health from manifest checks and observations', () => {
  const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
  const health = buildServiceHealth(manifest, {
    'brickadia-files': { healthy: true, evidence: ['BrickadiaServer-Win64-Shipping.exe'] },
    'omegga-running': { healthy: false, summary: 'Omegga process is not running.' },
    'frame-telemetry-fresh': { healthy: false, summary: 'Frame telemetry disabled by profile.' },
  });

  assert.equal(health.status, 'unhealthy');
  assert.equal(health.summary.healthy, 1);
  assert.equal(
    health.checks.find(check => check.id === 'omegga-running').status,
    'unhealthy',
  );
  assert.equal(
    health.checks.find(check => check.id === 'frame-telemetry-fresh').status,
    'degraded',
  );
});

test('plans dry-run install actions for the full local runtime stack', () => {
  const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
  const plan = createOperationPlan('install-stack', {
    manifest,
    profile: {
      name: 'Local Dev Server',
      telemetry: { enabled: true },
    },
    now: '2026-01-01T00:00:00.000Z',
  });

  assert.equal(plan.dryRun, true);
  assert.equal(plan.status, 'planned');
  assert.ok(plan.actions.some(action => action.component === 'omegga-runtime'));
  assert.ok(plan.actions.some(action => action.component === 'bmf-runtime'));
  assert.ok(plan.actions.some(action => action.component === 'bmf-native-socket'));
  assert.ok(plan.actions.some(action => action.component === 'omegga-plugin-bmf-bridge'));
  assert.ok(plan.actions.some(action => action.component === 'grafana-alloy'));
  assert.ok(plan.actions.every(action => action.mode === 'would-run'));
});

test('plans event traffic inspection as observe-only bounded work', () => {
  const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
  const plan = createOperationPlan('inspect-event-traffic', { manifest });

  assert.equal(plan.summary.mutating, 0);
  assert.ok(plan.guardrails.includes('observe-existing-traffic-only'));
  assert.ok(plan.guardrails.includes('do-not-add-ui-driven-server-probes'));
  assert.ok(plan.actions.some(action => action.kind === 'socket-read'));
  assert.ok(plan.actions.some(action => action.kind === 'buffer-policy'));
});

test('builds a dry-run filesystem transaction for install-stack without mutating targets', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-transaction-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    const alloyConfig = path.join(root, 'alloy', 'bmf.alloy');
    fs.mkdirSync(win64, { recursive: true });
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');

    const transaction = createOperationTransaction('install-stack', {
      name: 'Transaction Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
        grafanaAlloyConfig: alloyConfig,
      },
      telemetry: {
        enabled: true,
      },
    }, {
      root: repoRoot,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(transaction.dryRun, true);
    assert.equal(transaction.status, 'planned');
    assert.ok(transaction.summary.mutating > 0);
    assert.ok(transaction.guardrails.includes('backup-before-overwrite'));
    assert.ok(transaction.guardrails.includes('rollback-instructions-generated'));
    assert.ok(transaction.steps.some(step => step.id === 'install-omegga-runtime'));
    assert.ok(transaction.steps.some(step => step.id === 'write-omegga-start-script'));
    assert.ok(transaction.steps.some(step => step.id === 'stage-bmf-runtime'));
    assert.ok(transaction.steps.some(step => step.id === 'write-alloy-config'));
    assert.equal(transaction.steps.some(step => step.content), false);
    assert.equal(fs.existsSync(path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'bmf.json')), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans update-stack with verified release evidence and component snapshot', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-update-transaction-'));
  try {
    const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
    writeMinimalTransactionSources(root);
    const release = writeDesktopReleaseEvidence(root);
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const modsDir = path.join(win64, 'ue4ss', 'main', 'Mods');
    const runtimeDir = path.join(modsDir, 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    writeFixtureFile(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    writeFixtureFile(path.join(modsDir, 'BMF', 'bmf.json'), '{"version":"old"}\n');
    writeFixtureFile(path.join(modsDir, 'BMFSocket', 'README.md'), 'old socket\n');
    writeFixtureFile(path.join(modsDir, 'BMFFrameTelemetry', 'README.md'), 'old frame telemetry\n');
    writeFixtureFile(path.join(omeggaRuntime, 'package.json'), '{"version":"old"}\n');
    writeFixtureFile(path.join(omeggaRuntime, 'package-lock.json'), '{}\n');

    const transaction = createOperationTransaction('update-stack', {
      name: 'Update Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
      },
    }, {
      root,
      manifest,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(transaction.status, 'planned');
    assert.equal(transaction.dryRun, true);
    const stepById = new Map(transaction.steps.map(step => [step.id, step]));
    assert.equal(stepById.get('read-release-catalog').targetPath, release.catalogPath);
    assert.equal(stepById.get('read-release-manifest').targetPath, release.manifestPath);
    assert.equal(stepById.get('verify-release-checksums').status, 'ready');
    assert.equal(stepById.get('snapshot-current-components').status, 'ready');
    assert.equal(stepById.get('snapshot-current-components').actionId, 'backup-current-components');
    assert.equal(stepById.get('install-omegga-runtime').actionId, 'update-omegga-runtime');
    assert.equal(stepById.get('stage-bmf-runtime').actionId, 'update-bmf-runtime');
    assert.equal(stepById.get('stage-bmf-socket').actionId, 'update-native-helpers');
    assert.equal(stepById.get('stage-frame-telemetry').actionId, 'update-native-helpers');

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
      assert.equal(unsupportedIds.includes(actionId), false, `${actionId} should have a concrete transaction step`);
    }
    assert.equal(unsupportedIds.includes('validate-updated-stack'), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans repair-stack with concrete health, snapshot, enablement, and runtime repair steps', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-repair-transaction-'));
  try {
    const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
    writeMinimalTransactionSources(root);
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const modsDir = path.join(win64, 'ue4ss', 'main', 'Mods');
    const runtimeDir = path.join(modsDir, 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    writeFixtureFile(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    writeFixtureFile(path.join(win64, 'dwmapi.dll'), 'dll');
    fs.mkdirSync(omeggaRuntime, { recursive: true });

    const transaction = createOperationTransaction('repair-stack', {
      name: 'Repair Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
      },
    }, {
      root,
      manifest,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(transaction.status, 'planned');
    assert.equal(transaction.dryRun, true);
    const stepById = new Map(transaction.steps.map(step => [step.id, step]));
    assert.equal(stepById.get('repair-preflight-health').kind, 'health-snapshot');
    assert.equal(stepById.get('repair-preflight-health').actionId, 'run-doctor');
    assert.equal(stepById.get('snapshot-repair-mutable-files').actionId, 'backup-mutable-files');
    assert.equal(stepById.get('repair-omegga-start-script').actionId, 'repair-launch-env');
    assert.equal(stepById.get('repair-bmf-runtime-files').actionId, 'repair-missing-runtime-files');
    assert.equal(stepById.get('repair-bmf-socket-files').actionId, 'repair-missing-runtime-files');
    assert.equal(stepById.get('repair-generic-bridge-plugin').actionId, 'repair-missing-runtime-files');
    assert.equal(stepById.get('repair-bmf-enabled-file').actionId, 'repair-mod-enablement');
    assert.equal(stepById.get('repair-mods-txt').actionId, 'repair-mod-enablement');
    assert.equal(stepById.get('repair-mods-json').actionId, 'repair-mod-enablement');
    assert.equal(stepById.get('repair-verification-health').kind, 'health-snapshot');
    assert.equal(stepById.get('repair-verification-health').actionId, 'verify-after-repair');
    assert.equal(transaction.steps.some(step => step.content), false);

    const unsupportedIds = transaction.unsupportedActions.map(action => action.actionId);
    for (const actionId of [
      'run-doctor',
      'backup-mutable-files',
      'repair-launch-env',
      'repair-mod-enablement',
      'repair-missing-runtime-files',
      'verify-after-repair',
    ]) {
      assert.equal(unsupportedIds.includes(actionId), false, `${actionId} should have a concrete transaction step`);
    }

    const appDataJournalRoot = path.join(os.tmpdir(), 'bmf-desktop-appdata-transactions');
    const installedTransaction = createOperationTransaction('repair-stack', {
      name: 'Installed Repair Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
      },
    }, {
      root,
      journalRoot: appDataJournalRoot,
      manifest,
      now: '2026-06-16T12:00:00Z',
    });
    const snapshotStep = installedTransaction.steps.find(step => step.id === 'snapshot-repair-mutable-files');
    assert.equal(installedTransaction.status, 'planned');
    assert.equal(snapshotStep.status, 'ready');
    assert.ok(installedTransaction.allowedTargetRoots.includes(path.resolve(appDataJournalRoot)));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('applies repair-stack transaction and verifies repaired UE4SS and bridge files', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-repair-apply-'));
  try {
    const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
    writeMinimalTransactionSources(root);
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const modsDir = path.join(win64, 'ue4ss', 'main', 'Mods');
    const runtimeDir = path.join(modsDir, 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    writeFixtureFile(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    writeFixtureFile(path.join(win64, 'dwmapi.dll'), 'dll');
    writeFixtureFile(path.join(modsDir, 'mods.txt'), 'BMF : 0\nOmeggaBridge : 1\n');
    writeFixtureFile(path.join(modsDir, 'mods.json'), `${JSON.stringify([
      { mod_name: 'BMF', mod_enabled: false },
      { mod_name: 'OmeggaBridge', mod_enabled: true },
    ], null, 2)}\n`);
    writeFixtureFile(path.join(modsDir, 'BMF', 'old.txt'), 'old runtime\n');
    writeFixtureFile(path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1'), 'old start\n');

    const result = executeOperationTransaction('repair-stack', {
      name: 'Repair Apply Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
      },
    }, {
      root,
      manifest,
      dryRun: false,
      confirm: 'apply',
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(result.status, 'applied');
    assert.equal(result.errors.length, 0);
    assert.equal(fs.existsSync(path.join(modsDir, 'BMF', 'bmf.json')), true);
    assert.equal(fs.existsSync(path.join(modsDir, 'BMF', 'enabled.txt')), true);
    assert.equal(fs.existsSync(path.join(modsDir, 'BMFSocket', 'README.md')), true);
    assert.equal(fs.existsSync(path.join(modsDir, 'BMFFrameTelemetry', 'README.md')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-bridge', 'omegga.plugin.js')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-player-sync', 'omegga.plugin.js')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-minigame-events', 'omegga.plugin.js')), true);
    assert.match(fs.readFileSync(path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1'), 'utf8'), /BMF_OMEGGA_RUNTIME/);
    assert.match(fs.readFileSync(path.join(modsDir, 'mods.txt'), 'utf8'), /BMF : 1/);
    const modsJson = JSON.parse(fs.readFileSync(path.join(modsDir, 'mods.json'), 'utf8'));
    assert.equal(modsJson.find(item => item.mod_name === 'BMF').mod_enabled, true);

    const snapshotStep = result.applied.find(step => step.id === 'snapshot-repair-mutable-files');
    assert.ok(snapshotStep);
    const snapshot = JSON.parse(fs.readFileSync(snapshotStep.targetPath, 'utf8'));
    assert.equal(snapshot.feature, 'repair.mutable-files.snapshot');
    assert.ok(snapshot.files.some(file => file.path.endsWith('mods.txt') && file.exists));

    const preflight = result.applied.find(step => step.id === 'repair-preflight-health');
    const verification = result.applied.find(step => step.id === 'repair-verification-health');
    assert.equal(preflight.metadata.stage, 'before-repair');
    assert.equal(verification.metadata.stage, 'after-repair');
    assert.equal(preflight.metadata.observations['ue4ss-enabled'].status, 'unhealthy');
    assert.equal(verification.metadata.observations['ue4ss-enabled'].status, 'healthy');
    assert.equal(fs.existsSync(result.journalPath), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('skips Omegga runtime copy when target is the packaged source itself', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-omegga-same-source-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const packagedOmeggaSource = path.join(repoRoot, 'packages', 'omegga-runtime', 'source');
    fs.mkdirSync(win64, { recursive: true });
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');

    const transaction = createOperationTransaction('install-stack', {
      name: 'Packaged Source Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime: packagedOmeggaSource,
        bmfRuntimeDir: runtimeDir,
      },
    }, {
      root: repoRoot,
      now: '2026-06-16T12:00:00Z',
    });

    const omeggaStep = transaction.steps.find(step => step.id === 'install-omegga-runtime');
    assert.ok(omeggaStep);
    assert.equal(omeggaStep.status, 'skipped');
    assert.equal(omeggaStep.blockedReason, null);
    assert.equal(transaction.status, 'blocked');
    assert.ok(transaction.steps.some(step =>
      step.id === 'stage-generic-bridge' &&
      step.status === 'blocked' &&
      step.blockedReason.includes('packaged source tree'),
    ));
    assert.ok(transaction.steps.some(step =>
      step.id === 'write-omegga-start-script' &&
      step.status === 'blocked' &&
      step.blockedReason.includes('packaged source tree'),
    ));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('applies install-stack transaction with backups, journal, and rollback metadata', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-transaction-apply-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    const alloyConfig = path.join(root, 'alloy', 'bmf.alloy');
    const existingBmfDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF');
    fs.mkdirSync(existingBmfDir, { recursive: true });
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    fs.writeFileSync(path.join(existingBmfDir, 'old.txt'), 'previous install');

    assert.throws(
      () => executeOperationTransaction('install-stack', {
        name: 'Apply Server',
        paths: {
          brickadiaWin64: win64,
          omeggaRuntime,
          bmfRuntimeDir: runtimeDir,
          grafanaAlloyConfig: alloyConfig,
        },
        telemetry: {
          enabled: true,
        },
      }, {
        root: repoRoot,
        dryRun: false,
      }),
      /--confirm apply/,
    );

    const result = executeOperationTransaction('install-stack', {
      name: 'Apply Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
        grafanaAlloyConfig: alloyConfig,
      },
      telemetry: {
        enabled: true,
      },
    }, {
      root: repoRoot,
      dryRun: false,
      confirm: 'apply',
      now: '2026-06-16T12:00:00Z',
      env: {},
    });

    assert.equal(result.status, 'applied');
    assert.equal(result.errors.length, 0);
    assert.equal(fs.existsSync(path.join(existingBmfDir, 'bmf.json')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'package.json')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'src', 'omegga', 'index.ts')), true);
    const startScriptPath = path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1');
    assert.equal(fs.existsSync(startScriptPath), true);
    const startScript = fs.readFileSync(startScriptPath, 'utf8');
    assert.match(startScript, /npm is required to install Omegga dependencies/);
    assert.match(startScript, /BMF_OMEGGA_BOOTSTRAP_BUILD_SCRIPT/);
    assert.match(startScript, /Invoke-BmfCommand \$npmCommand\.Source @\("start"\)/);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-bridge', 'plugin.json')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-player-sync', 'plugin.json')), true);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-minigame-events', 'plugin.json')), true);
    assert.equal(fs.existsSync(alloyConfig), true);
    assert.equal(fs.readFileSync(alloyConfig, 'utf8').includes('sys.env("BMF_GRAFANA_REMOTE_WRITE_TOKEN")'), true);
    assert.equal(fs.existsSync(result.journalPath), true);
    assert.equal(result.steps.some(step => step.content), false);
    assert.ok(result.applied.some(step => step.id === 'stage-bmf-runtime' && step.backupPath));
    assert.ok(result.rollback.some(item => item.action === 'restore-directory'));
    const journal = JSON.parse(fs.readFileSync(result.journalPath, 'utf8'));
    assert.equal(journal.status, 'applied');
    assert.equal(JSON.stringify(journal).includes('previous install'), false);

    const startPlan = createServiceActionPlan('start-stack', {
      name: 'Apply Server',
      paths: {
        omeggaRuntime,
      },
    }, {
      root,
      portInspection: { inspected: false },
      now: '2026-06-16T12:02:00Z',
    });
    assert.equal(startPlan.status, 'planned');
    assert.equal(startPlan.paths.startScript, startScriptPath);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('rolls back an applied install-stack transaction from its journal', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-transaction-rollback-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    const alloyConfig = path.join(root, 'alloy', 'bmf.alloy');
    const existingBmfDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF');
    fs.mkdirSync(existingBmfDir, { recursive: true });
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    fs.writeFileSync(path.join(existingBmfDir, 'old.txt'), 'previous install');

    const applyResult = executeOperationTransaction('install-stack', {
      name: 'Rollback Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        bmfRuntimeDir: runtimeDir,
        grafanaAlloyConfig: alloyConfig,
      },
      telemetry: {
        enabled: true,
      },
    }, {
      root: repoRoot,
      dryRun: false,
      confirm: 'apply',
      now: '2026-06-16T12:00:00Z',
      env: {},
    });

    const rollbackPlan = createRollbackTransaction(applyResult.journalPath, {
      now: '2026-06-16T12:05:00Z',
    });
    assert.equal(rollbackPlan.status, 'planned');
    assert.equal(rollbackPlan.summary.blocked, 0);
    assert.equal(rollbackPlan.steps.some(step => step.action === 'restore-directory'), true);
    assert.equal(rollbackPlan.steps.some(step => step.action === 'remove-created-path'), true);

    assert.throws(
      () => executeRollbackTransaction(applyResult.journalPath, {
        dryRun: false,
      }),
      /--confirm rollback/,
    );

    const rollbackResult = executeRollbackTransaction(applyResult.journalPath, {
      dryRun: false,
      confirm: 'rollback',
      now: '2026-06-16T12:05:00Z',
    });

    assert.equal(rollbackResult.status, 'rolled-back');
    assert.equal(rollbackResult.errors.length, 0);
    assert.equal(fs.existsSync(rollbackResult.journalPath), true);
    assert.equal(fs.existsSync(path.join(existingBmfDir, 'old.txt')), true);
    assert.equal(fs.existsSync(path.join(existingBmfDir, 'bmf.json')), false);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1')), false);
    assert.equal(fs.existsSync(path.join(win64, 'ue4ss', 'main', 'Mods', 'BMFSocket')), false);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-bridge')), false);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-player-sync')), false);
    assert.equal(fs.existsSync(path.join(omeggaRuntime, 'plugins', 'bmf-minigame-events')), false);
    assert.equal(fs.existsSync(alloyConfig), false);
    assert.ok(rollbackResult.applied.some(step => step.rollbackBackupPath));
    const rollbackJournal = JSON.parse(fs.readFileSync(rollbackResult.journalPath, 'utf8'));
    assert.equal(rollbackJournal.status, 'rolled-back');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('collects redacted event traffic from the live socket stream', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-traffic-'));
  try {
    const runtimeDir = path.join(root, 'runtime');
    const commandDir = path.join(runtimeDir, 'commands');
    fs.mkdirSync(commandDir, { recursive: true });
    const socketServer = await createTrafficSocketServer(t, {
      envelopes: [
        {
          type: 'event',
          source: 'bmf',
          ts: '2026-06-16T12:00:00Z',
          record: {
            ts: '2026-06-16T12:00:00Z',
            level: 'info',
            source: 'event',
            message: 'event emitted: serverReady',
            data: {
              event: 'serverReady',
              payload: { version: '0.1.0-ea2.cl13530', token: 'event-secret-token' },
              handlers: 1,
              ok: true,
            },
          },
        },
        {
          type: 'event',
          source: 'bmf',
          ts: '2026-06-16T12:01:00Z',
          record: {
            ts: '2026-06-16T12:01:00Z',
            level: 'error',
            source: 'event',
            message: 'event emitted: interactConsole',
            data: {
              event: 'interactConsole',
              payload: { message: 'hit', apiKey: 'event-api-key' },
              ok: false,
            },
          },
        },
        {
          type: 'response',
          source: 'bmf',
          ts: '2026-06-16T12:04:00Z',
          id: 'socket-response',
          ok: true,
          detail: 'ok',
          response: [
            'ok=true',
            'detail=ok',
            'command=bmf.status token=response-token',
            'bmf_command_transport=socket',
            'bmf_command_total_ms=12',
          ].join('\n'),
        },
      ],
    });

    fs.writeFileSync(
      path.join(runtimeDir, 'events.jsonl'),
      [
        JSON.stringify({
          ts: '2026-06-16T12:00:00Z',
          level: 'info',
          source: 'event',
          message: 'event emitted: serverReady',
          data: {
            event: 'serverReady',
            payload: { version: '0.1.0-ea2.cl13530', token: 'event-secret-token' },
            handlers: 1,
            ok: true,
          },
        }),
        JSON.stringify({
          ts: '2026-06-16T12:01:00Z',
          level: 'error',
          source: 'event',
          message: 'event emitted: interactConsole',
          data: {
            event: 'interactConsole',
            payload: { message: 'hit', apiKey: 'event-api-key' },
            ok: false,
          },
        }),
      ].join('\n') + '\n',
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'audit.jsonl'),
      JSON.stringify({
        ts: '2026-06-16T12:02:00Z',
        action: 'command.dispatch',
        source: 'command',
        ok: true,
        data: { command: 'bmf.status', password: 'audit-password' },
      }) + '\n',
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'bmf-bridge-status.json'),
      JSON.stringify({
        updatedAt: '2026-06-16T12:03:00Z',
        transport: 'socket',
        socket: { connected: true, token: 'bridge-token' },
      }),
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'socket.json'),
      JSON.stringify({
        enabled: true,
        host: '127.0.0.1',
        port: socketServer.port,
        token: socketServer.token,
      }),
    );
    fs.writeFileSync(
      path.join(commandDir, 'bmf_bridge_1781611440000_1.request.txt'),
      'bmf.status token=request-token',
    );
    fs.writeFileSync(
      path.join(commandDir, 'bmf_bridge_1781611440000_1.response.txt'),
      [
        'ok=true',
        'detail=ok',
        'command=bmf.status token=response-token',
        'bmf_command_transport=file',
        'bmf_command_total_ms=12',
      ].join('\n') + '\n',
    );

    const commandTime = new Date('2026-06-16T12:04:00Z');
    fs.utimesSync(path.join(runtimeDir, 'socket.json'), commandTime, new Date('2026-06-16T12:03:30Z'));
    for (const file of fs.readdirSync(commandDir)) {
      fs.utimesSync(path.join(commandDir, file), commandTime, commandTime);
    }

    const snapshot = await waitForTrafficSnapshot({
      name: 'Traffic Server',
      paths: { bmfRuntimeDir: runtimeDir },
    }, {
      maxRecords: 20,
      maxBytesPerFile: 64 * 1024,
    }, snapshot => snapshot.records.some(record => record.event === 'serverReady'));

    assert.equal(snapshot.schemaVersion, 1);
    assert.ok(snapshot.summary.retained >= 4);
    assert.ok(snapshot.guardrails.includes('socket-only-live-traffic'));
    assert.ok(snapshot.guardrails.includes('do-not-add-ui-driven-server-probes'));
    assert.ok(snapshot.sources.some(source => source.id === 'socket-stream' && source.status === 'connected'));
    assert.equal(snapshot.sources.some(source => source.id === 'events-jsonl'), false);
    assert.equal(snapshot.sources.some(source => source.id === 'command-files'), false);

    const event = snapshot.records.find(record => record.event === 'serverReady');
    assert.equal(event.type, 'event');
    assert.equal(event.payload.token, '[redacted]');
    assert.equal(snapshot.records.find(record => record.type === 'response').durationMs, 12);
    assert.ok(socketServer.received.find(message => message.type === 'hello' && message.token === socketServer.token));
    assert.ok(socketServer.received.find(message => message.type === 'subscribe'));
    assert.equal(JSON.stringify(snapshot).includes('event-secret-token'), false);
    assert.equal(JSON.stringify(snapshot).includes('event-api-key'), false);
    assert.equal(JSON.stringify(snapshot).includes('audit-password'), false);
    assert.equal(JSON.stringify(snapshot).includes('bridge-token'), false);
    assert.equal(JSON.stringify(snapshot).includes('socket-token'), false);
    assert.equal(JSON.stringify(snapshot).includes('request-token'), false);
    assert.equal(JSON.stringify(snapshot).includes('response-token'), false);
  } finally {
    resetTrafficSocketClients();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('collects retained bridge socket records after Desktop restart', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-bridge-traffic-'));
  try {
    const runtimeDir = path.join(root, 'runtime');
    fs.mkdirSync(runtimeDir, { recursive: true });
    fs.writeFileSync(
      path.join(runtimeDir, 'bmf-bridge-status.json'),
      JSON.stringify({
        updatedAt: '2026-06-16T12:02:00Z',
        transport: 'socket',
        socket: { connected: true, token: 'bridge-token' },
        records: { retained: 2, statusLimit: 2, dropped: 0 },
        recentRecords: [
          {
            id: 'retained-older',
            timestamp: '2026-06-16T12:00:00Z',
            type: 'event',
            event: 'minigames.joinminigame',
            source: 'native.BMFSocketResourceNative',
            transport: 'socket',
            status: 'ok',
            payload: { playerId: 'player-secret-id', token: 'older-secret' },
          },
          {
            id: 'retained-newer',
            timestamp: '2026-06-16T12:01:00Z',
            type: 'event',
            event: 'resource.hit',
            source: 'native.BMFSocketResourceNative',
            transport: 'socket',
            status: 'ok',
            payload: { apiKey: 'newer-api-key' },
          },
        ],
      }),
    );

    const snapshot = collectTrafficSnapshot({
      name: 'Retained Traffic Server',
      paths: { bmfRuntimeDir: runtimeDir },
    }, {
      maxRecords: 10,
      maxBytesPerFile: 64 * 1024,
    });

    assert.equal(snapshot.summary.retained, 2);
    assert.ok(snapshot.sources.some(source => source.id === 'bmf-bridge-status' && source.records === 2));
    assert.deepEqual(snapshot.records.map(record => record.event), ['resource.hit', 'minigames.joinminigame']);
    assert.equal(snapshot.records[0].payload.apiKey, '[redacted]');
    assert.equal(snapshot.records[1].payload.token, '[redacted]');
    assert.equal(JSON.stringify(snapshot).includes('newer-api-key'), false);
    assert.equal(JSON.stringify(snapshot).includes('older-secret'), false);
    assert.equal(JSON.stringify(snapshot).includes('bridge-token'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('exports a confirmed redacted socket traffic trace for support bundles', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-traffic-export-'));
  try {
    const runtimeDir = path.join(root, 'runtime');
    const out = path.join(root, 'exports', 'trace.json');
    fs.mkdirSync(runtimeDir, { recursive: true });
    const socketServer = await createTrafficSocketServer(t, {
      envelopes: [
        {
          type: 'event',
          source: 'bmf',
          ts: '2026-06-16T12:00:00Z',
          record: {
            ts: '2026-06-16T12:00:00Z',
            source: 'event',
            data: {
              event: 'player.hit',
              payload: {
                playerId: 'player-secret-id',
                displayName: 'Player Secret',
                remoteAddress: '192.168.10.25',
                apiKey: 'traffic-api-key',
              },
              ok: true,
            },
          },
        },
      ],
    });
    fs.writeFileSync(
      path.join(runtimeDir, 'events.jsonl'),
      JSON.stringify({
        ts: '2026-06-16T12:00:00Z',
        source: 'event',
        data: {
          event: 'player.hit',
          payload: {
            playerId: 'player-secret-id',
            displayName: 'Player Secret',
            remoteAddress: '192.168.10.25',
            apiKey: 'traffic-api-key',
          },
          ok: true,
        },
      }) + '\n',
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'socket.json'),
      JSON.stringify({
        enabled: true,
        host: '127.0.0.1',
        port: socketServer.port,
        token: socketServer.token,
      }),
    );

    assert.throws(
      () => writeTrafficTraceExport({
        name: 'Trace Export Server',
        paths: { bmfRuntimeDir: runtimeDir },
      }, {
        out,
        dryRun: false,
      }),
      /--confirm export/,
    );
    assert.equal(fs.existsSync(out), false);

    await waitForTrafficSnapshot({
      name: 'Trace Export Server',
      paths: { bmfRuntimeDir: runtimeDir },
    }, {
      anonymizePlayers: true,
      redactPrivateIps: true,
      maxRecords: 10,
    }, snapshot => snapshot.records.some(record => record.event === 'player.hit'));

    const result = writeTrafficTraceExport({
      name: 'Trace Export Server',
      paths: { bmfRuntimeDir: runtimeDir },
    }, {
      out,
      dryRun: false,
      confirm: 'export',
      anonymizePlayers: true,
      redactPrivateIps: true,
      maxRecords: 10,
      now: '2026-06-16T12:05:00Z',
    });

    assert.equal(result.status, 'written');
    assert.equal(result.confirmed, true);
    assert.ok(result.summary.retained >= 1);
    assert.equal(result.sha256.length, 64);
    assert.equal(fs.existsSync(out), true);
    const exported = fs.readFileSync(out, 'utf8');
    assert.equal(exported.includes('traffic-api-key'), false);
    assert.equal(exported.includes('player-secret-id'), false);
    assert.equal(exported.includes('Player Secret'), false);
    assert.equal(exported.includes('192.168.10.25'), false);
    assert.equal(exported.includes('[anonymized]'), true);
    assert.equal(exported.includes('[private-ip]'), true);
    assert.ok(result.guardrails.includes('explicit-export-confirmation-required'));
    assert.ok(result.guardrails.includes('export-redacted-snapshot-only'));
  } finally {
    resetTrafficSocketClients();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('collects bounded redacted log snapshots from runtime files and journals', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-logs-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const journalRoot = path.join(root, 'artifacts', 'local', 'transactions');
    fs.mkdirSync(runtimeDir, { recursive: true });
    fs.mkdirSync(journalRoot, { recursive: true });

    fs.writeFileSync(
      path.join(runtimeDir, 'bmf.log'),
      [
        '2026-06-16T12:00:00Z INFO server ready token=plain-secret',
        '2026-06-16T12:01:00Z ERROR launch failed password=log-password',
      ].join('\n') + '\n',
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'events.jsonl'),
      JSON.stringify({
        ts: '2026-06-16T12:02:00Z',
        level: 'info',
        source: 'event',
        message: 'event emitted',
        data: {
          event: 'interactConsole',
          payload: { apiKey: 'event-api-key' },
        },
      }) + '\n',
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'bmf-bridge-status.json'),
      JSON.stringify({
        updatedAt: '2026-06-16T12:03:00Z',
        status: 'connected',
        socket: { token: 'bridge-token' },
      }),
    );
    fs.writeFileSync(
      path.join(journalRoot, 'install-stack-2026.json'),
      JSON.stringify({
        transactionId: 'install-stack-2026',
        operationId: 'install-stack',
        status: 'applied',
        createdAt: '2026-06-16T12:04:00Z',
        summary: { ready: 3, blocked: 0 },
        errors: [],
      }),
    );

    const snapshot = collectLogSnapshot({
      name: 'Log Server',
      paths: {
        brickadiaWin64: win64,
      },
    }, {
      root,
      journalRoot,
      maxLines: 20,
    });

    assert.equal(snapshot.schemaVersion, 1);
    assert.equal(snapshot.summary.retained, 5);
    assert.ok(snapshot.summary.redactions >= 4);
    assert.ok(snapshot.sources.some(source => source.id === 'bmf-log' && source.lines === 2));
    assert.ok(snapshot.sources.some(source => source.id === 'events-jsonl' && source.lines === 1));
    assert.ok(snapshot.sources.some(source => source.id.startsWith('transaction-journal:') && source.lines === 1));
    assert.ok(snapshot.records.some(record => record.severity === 'error' && record.message.includes('launch failed')));
    assert.ok(snapshot.records.some(record => record.sourceId.startsWith('transaction-journal:') && record.message.includes('operation=install-stack')));
    assert.equal(JSON.stringify(snapshot).includes('plain-secret'), false);
    assert.equal(JSON.stringify(snapshot).includes('log-password'), false);
    assert.equal(JSON.stringify(snapshot).includes('event-api-key'), false);
    assert.equal(JSON.stringify(snapshot).includes('bridge-token'), false);
    assert.ok(snapshot.guardrails.includes('bounded-line-retention'));
    assert.ok(snapshot.guardrails.includes('do-not-add-ui-driven-server-probes'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('plans and writes redacted troubleshooting snapshots through the shared core', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-snapshot-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    const out = path.join(root, 'snapshot');
    fs.mkdirSync(runtimeDir, { recursive: true });
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    fs.writeFileSync(path.join(win64, 'dwmapi.dll'), '');
    fs.writeFileSync(path.join(runtimeDir, 'status.json'), JSON.stringify({
      state: 'running',
      version: '0.1.0-test',
      token: 'status-secret-token',
    }));
    fs.writeFileSync(
      path.join(runtimeDir, 'events.jsonl'),
      JSON.stringify({
        ts: '2026-06-16T12:00:00Z',
        source: 'event',
        data: {
          event: 'snapshotTest',
          payload: { apiKey: 'event-api-key' },
        },
      }) + '\n',
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'bmf.log'),
      '2026-06-16T12:00:00Z INFO snapshot token=log-secret\n',
    );
    fs.writeFileSync(path.join(omeggaRuntime, 'package.json'), JSON.stringify({
      name: 'omegga',
      token: 'omegga-package-token',
    }));
    fs.writeFileSync(path.join(omeggaRuntime, 'omegga.log'), 'password=omegga-log-password\n');

    const profile = createServerProfile({
      name: 'Snapshot Server',
      paths: {
        brickadiaWin64: win64,
        bmfRoot: repoRoot,
        bmfRuntimeDir: runtimeDir,
        omeggaRuntime,
      },
    });

    const plan = createTroubleshootingSnapshotPlan({ profile }, {
      root: repoRoot,
      out,
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(plan.status, 'planned');
    assert.equal(plan.dryRun, true);
    assert.equal(fs.existsSync(path.join(out, 'snapshot.json')), false);
    assert.ok(plan.guardrails.includes('explicit-snapshot-write-confirmation-required'));
    assert.ok(plan.copiedFiles.some(file => file.source.endsWith('status.json')));
    assert.ok(plan.copiedLogs.some(file => file.source.endsWith('bmf.log')));

    assert.throws(
      () => writeTroubleshootingSnapshot({ profile }, {
        root: repoRoot,
        out,
      }),
      /--confirm snapshot/,
    );

    const written = writeTroubleshootingSnapshot({ profile }, {
      root: repoRoot,
      out,
      confirm: 'snapshot',
      now: '2026-06-16T12:00:00Z',
    });

    assert.equal(written.status, 'written');
    assert.equal(written.dryRun, false);
    assert.equal(fs.existsSync(written.files.snapshot), true);
    assert.equal(fs.existsSync(written.files.profile), true);
    assert.equal(fs.existsSync(written.files.health), true);
    assert.equal(fs.existsSync(written.files.logs), true);
    assert.equal(fs.existsSync(written.files.traffic), true);
    assert.ok(written.copiedFiles.every(file => fs.existsSync(file.absoluteSnapshotPath)));
    assert.ok(written.copiedLogs.every(file => fs.existsSync(file.absoluteSnapshotPath)));

    const snapshotText = fs.readFileSync(written.files.snapshot, 'utf8');
    const statusCopy = written.copiedFiles.find(file => file.source.endsWith('status.json'));
    const logCopy = written.copiedLogs.find(file => file.source.endsWith('omegga.log'));
    assert.ok(statusCopy);
    assert.ok(logCopy);
    assert.equal(fs.readFileSync(statusCopy.absoluteSnapshotPath, 'utf8').includes('status-secret-token'), false);
    assert.equal(fs.readFileSync(logCopy.absoluteSnapshotPath, 'utf8').includes('omegga-log-password'), false);
    assert.equal(snapshotText.includes('status-secret-token'), false);
    assert.equal(snapshotText.includes('event-api-key'), false);
    assert.equal(snapshotText.includes('omegga-package-token'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('retains only the newest bounded socket traffic records', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-traffic-limit-'));
  try {
    const runtimeDir = path.join(root, 'runtime');
    fs.mkdirSync(runtimeDir, { recursive: true });
    const envelopes = [];
    for (let index = 0; index < 6; index++) {
      envelopes.push({
        type: 'event',
        source: 'bmf',
        ts: `2026-06-16T12:0${index}:00Z`,
        record: {
          ts: `2026-06-16T12:0${index}:00Z`,
          source: 'event',
          data: {
            event: `event.${index}`,
            payload: { index },
            ok: true,
          },
        },
      });
    }
    const socketServer = await createTrafficSocketServer(t, { envelopes });
    fs.writeFileSync(
      path.join(runtimeDir, 'socket.json'),
      JSON.stringify({
        enabled: true,
        host: '127.0.0.1',
        port: socketServer.port,
        token: socketServer.token,
      }),
    );

    const snapshot = await waitForTrafficSnapshot({
      name: 'Traffic Limit Server',
      paths: { bmfRuntimeDir: runtimeDir },
    }, {
      maxRecords: 3,
    }, snapshot => snapshot.records.some(record => record.event === 'event.5'));

    assert.equal(snapshot.summary.retained, 3);
    assert.ok(snapshot.summary.dropped >= 3);
    assert.deepEqual(snapshot.records.map(record => record.event), ['event.5', 'event.4', 'event.3']);
  } finally {
    resetTrafficSocketClients();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('builds service diagnostics from configured port ownership snapshots', () => {
  const profile = createServerProfile({
    name: 'Port Conflict Server',
    ports: {
      brickadia: 7777,
      omeggaWeb: 8080,
      bmfSocket: 49152,
      alloyReady: 12345,
    },
    telemetry: { enabled: true },
  });
  const diagnostics = buildServiceDiagnostics(profile, {
    portInspection: {
      inspected: true,
      targetIdsInspected: getConfiguredPortTargets(profile).filter(target => target.enabled).map(target => target.id),
      snapshots: [
        {
          id: 'omegga-web',
          protocol: 'tcp',
          port: 8080,
          owningProcess: 1234,
          processName: 'node',
        },
      ],
    },
  });

  assert.equal(diagnostics.startReadiness.status, 'blocked');
  assert.equal(diagnostics.startReadiness.blockers[0].portId, 'omegga-web');
  assert.equal(
    diagnostics.ports.find(port => port.id === 'omegga-web').ownerSummary,
    'node pid=1234',
  );
  assert.equal(
    diagnostics.ports.find(port => port.id === 'brickadia').status,
    'available',
  );
  assert.ok(diagnostics.guardrails.includes('bounded-local-port-inspection'));
});

test('renders Grafana Alloy onboarding without embedding secret values', () => {
  const plan = createTelemetryOnboardingPlan({
    name: 'Telemetry Server',
    ports: {
      omeggaWeb: 18080,
      alloyReady: 19090,
    },
    paths: {
      grafanaAlloyConfig: path.join(os.tmpdir(), 'bmf-test-alloy.alloy'),
    },
    telemetry: {
      enabled: true,
      environment: 'dev lab',
      instance: 'local instance',
      dashboardUrl: 'https://grafana.example/d/bmf-standard?token=secret',
    },
  }, {
    root: repoRoot,
    env: {
      BMF_GRAFANA_REMOTE_WRITE_URL: 'https://prometheus.example/api/prom/push',
      BMF_GRAFANA_REMOTE_WRITE_USERNAME: '12345',
      BMF_GRAFANA_REMOTE_WRITE_TOKEN: 'super-secret-token',
    },
    scrapeInterval: '20s',
  });

  assert.equal(plan.status, 'ready');
  assert.equal(plan.labels.environment, 'dev-lab');
  assert.match(plan.alloy.config, /127\.0\.0\.1:18080/);
  assert.match(plan.alloy.config, /127\.0\.0\.1:19090/);
  assert.match(plan.alloy.config, /scrape_interval = "20s"/);
  assert.match(plan.alloy.config, /sys\.env\("BMF_GRAFANA_REMOTE_WRITE_TOKEN"\)/);
  assert.equal(plan.alloy.config.includes('super-secret-token'), false);
  assert.deepEqual(findTemplatePlaceholders(plan.alloy.config), []);
  assert.equal(plan.dashboard.dashboardUrl, 'https://grafana.example/d/bmf-standard?token=[redacted]');
  assert.ok(plan.guardrails.includes('do-not-store-secret-values'));
});

test('writes Grafana Alloy config with env secret references only', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-alloy-write-'));
  try {
    const out = path.join(root, 'telemetry', 'bmf.alloy');
    const result = writeTelemetryAlloyConfig({
      name: 'Alloy Writer',
      ports: {
        omeggaWeb: 18080,
        alloyReady: 19090,
      },
      paths: {
        grafanaAlloyConfig: out,
      },
      telemetry: {
        enabled: true,
        environment: 'dev lab',
        instance: 'writer one',
      },
    }, {
      root: repoRoot,
      env: {
        BMF_GRAFANA_REMOTE_WRITE_URL: 'https://prometheus.example/api/prom/push',
        BMF_GRAFANA_REMOTE_WRITE_USERNAME: '12345',
        BMF_GRAFANA_REMOTE_WRITE_TOKEN: 'super-secret-token',
      },
      scrapeInterval: '30s',
      dryRun: false,
    });

    assert.equal(result.status, 'written');
    assert.equal(result.dryRun, false);
    assert.equal(result.outputPath, out);
    assert.equal(result.sha256.length, 64);
    assert.equal(fs.existsSync(out), true);
    const config = fs.readFileSync(out, 'utf8');
    assert.match(config, /127\.0\.0\.1:18080/);
    assert.match(config, /127\.0\.0\.1:19090/);
    assert.match(config, /scrape_interval = "30s"/);
    assert.match(config, /sys\.env\("BMF_GRAFANA_REMOTE_WRITE_TOKEN"\)/);
    assert.equal(config.includes('super-secret-token'), false);
    assert.ok(result.guardrails.includes('render-config-with-env-secret-refs'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('builds a redacted Grafana dashboard import plan and payload', () => {
  const plan = createDashboardImportPlan({
    name: 'Dashboard Server',
    telemetry: {
      enabled: true,
      environment: 'dev lab',
      instance: 'local instance',
    },
  }, {
    root: repoRoot,
    grafanaBaseUrl: 'https://grafana.example',
    env: {
      BMF_GRAFANA_API_TOKEN: 'super-secret-token',
    },
    now: '2026-06-16T12:00:00Z',
  });

  assert.equal(plan.status, 'ready');
  assert.equal(plan.request.method, 'POST');
  assert.equal(plan.request.apiPath, '/api/dashboards/db');
  assert.equal(plan.request.url, 'https://grafana.example/api/dashboards/db');
  assert.equal(plan.request.secretStatus[0].configured, true);
  assert.equal(plan.payload.dashboard.uid, 'bmf-standard');
  assert.equal(plan.payload.dashboard.id, null);
  assert.equal(plan.payload.folderUid, 'bmf');
  assert.equal(plan.payload.overwrite, true);
  assert.equal(plan.payloadSummary.labels.environment, 'dev-lab');
  assert.ok(plan.request.commands.powershell.includes('$env:BMF_GRAFANA_API_TOKEN'));
  assert.ok(plan.guardrails.includes('dashboard-import-dry-run-only'));
  assert.equal(JSON.stringify(plan).includes('super-secret-token'), false);
});

test('writes Grafana dashboard import payload only outside dry-run', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-dashboard-import-'));
  try {
    const out = path.join(root, 'payloads', 'dashboard-import.json');
    const dryRun = writeDashboardImportPayload({
      name: 'Dashboard Writer',
      telemetry: { enabled: true },
    }, {
      root: repoRoot,
      out,
      grafanaBaseUrl: 'https://grafana.example',
      dryRun: true,
      env: {},
    });

    assert.equal(dryRun.status, 'planned');
    assert.equal(fs.existsSync(out), false);
    assert.equal(dryRun.outputPath, out);

    const written = writeDashboardImportPayload({
      name: 'Dashboard Writer',
      telemetry: { enabled: true },
    }, {
      root: repoRoot,
      out,
      grafanaBaseUrl: 'https://grafana.example',
      dryRun: false,
      env: {},
    });

    assert.equal(written.status, 'written');
    assert.equal(fs.existsSync(out), true);
    assert.equal(written.sha256.length, 64);
    const payload = JSON.parse(fs.readFileSync(out, 'utf8'));
    assert.equal(payload.dashboard.uid, 'bmf-standard');
    assert.equal(payload.folderUid, 'bmf');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('uploads Grafana dashboard only with explicit confirmation and redacts token', async () => {
  await assert.rejects(
    () => executeDashboardImport({
      name: 'Dashboard Upload',
      telemetry: { enabled: true },
    }, {
      root: repoRoot,
      grafanaBaseUrl: 'https://grafana.example',
      grafanaApiToken: 'super-secret-token',
      fetch: async () => {
        throw new Error('fetch should not run without confirmation');
      },
    }),
    /--confirm import/,
  );

  const requests = [];
  const result = await executeDashboardImport({
    name: 'Dashboard Upload',
    telemetry: { enabled: true },
  }, {
    root: repoRoot,
    grafanaBaseUrl: 'https://grafana.example',
    grafanaApiToken: 'super-secret-token',
    confirm: 'import',
    fetch: async (url, request) => {
      requests.push({ url, request });
      return {
        ok: true,
        status: 200,
        statusText: 'OK',
        async text() {
          return JSON.stringify({
            status: 'success',
            uid: 'bmf-standard',
            url: '/d/bmf-standard/bmf-standard-server-telemetry?token=server-token',
            version: 2,
          });
        },
      };
    },
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'https://grafana.example/api/dashboards/db');
  assert.equal(requests[0].request.method, 'POST');
  assert.equal(requests[0].request.headers.Authorization, 'Bearer super-secret-token');
  assert.equal(result.status, 'uploaded');
  assert.equal(result.response.ok, true);
  assert.equal(result.response.dashboardUid, 'bmf-standard');
  assert.equal(result.dashboard.dashboardVersion, 2);
  assert.equal(result.response.dashboardUrl, 'https://grafana.example/d/bmf-standard/bmf-standard-server-telemetry?token=[redacted]');
  assert.equal(JSON.stringify(result).includes('super-secret-token'), false);
  assert.equal(JSON.stringify(result).includes('server-token'), false);
  assert.ok(result.guardrails.includes('grafana-upload-requires-confirm-import'));
});

test('builds a bootstrap operation sequence for telemetry-enabled profiles', () => {
  const { manifest } = loadUnifiedRuntimeManifest({ root: repoRoot });
  const plan = createBootstrapPlan({
    manifest,
    profile: {
      name: 'Telemetry Server',
      telemetry: { enabled: true },
    },
  });

  assert.deepEqual(plan.operations.map(operation => operation.operationId), [
    'install-stack',
    'configure-telemetry',
    'start-stack',
    'inspect-event-traffic',
  ]);
  assert.ok(OPERATION_IDS.includes('repair-stack'));
  assert.ok(OPERATION_IDS.includes('update-stack'));
  assert.ok(OPERATION_IDS.includes('snapshot-stack'));
  assert.equal(plan.prerequisites.feature, 'prerequisites.audit');
});

test('audits local prerequisites before install and start operations', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-prereq-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const omeggaTarget = path.join(root, 'managed', 'omegga');
    const alloyExe = path.join(root, 'tools', 'alloy.exe');
    fs.mkdirSync(path.join(root, 'manifests'), { recursive: true });
    fs.mkdirSync(path.join(root, 'packages', 'omegga-runtime', 'source'), { recursive: true });
    fs.mkdirSync(win64, { recursive: true });
    fs.mkdirSync(omeggaTarget, { recursive: true });
    fs.mkdirSync(path.dirname(alloyExe), { recursive: true });
    fs.writeFileSync(path.join(root, 'manifests', 'unified-runtime.json'), '{}\n');
    fs.writeFileSync(path.join(root, 'manifests', 'bmf-package.json'), '{}\n');
    fs.writeFileSync(path.join(root, 'packages', 'omegga-runtime', 'source', 'package.json'), '{}\n');
    fs.writeFileSync(path.join(root, 'packages', 'omegga-runtime', 'source', 'package-lock.json'), '{}\n');
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    fs.writeFileSync(alloyExe, '');

    const blocked = createPrerequisiteAudit({
      profile: {
        name: 'Blocked Server',
        paths: {
          brickadiaWin64: win64,
          omeggaRuntime: path.join(root, 'packages', 'omegga-runtime', 'source'),
        },
        telemetry: { enabled: true },
      },
    }, {
      root,
      nodeVersion: '22.0.0',
      commandResolver: () => null,
    });
    assert.equal(blocked.status, 'blocked');
    assert.ok(blocked.summary.blocked >= 3);
    assert.equal(blocked.checks.find(check => check.id === 'node-runtime').status, 'unhealthy');
    assert.equal(blocked.checks.find(check => check.id === 'omegga-install-target').status, 'unhealthy');

    const ready = createPrerequisiteAudit({
      profile: {
        name: 'Ready Server',
        paths: {
          brickadiaWin64: win64,
          omeggaRuntime: omeggaTarget,
          grafanaAlloyExecutable: alloyExe,
        },
        telemetry: { enabled: true },
      },
    }, {
      root,
      nodeVersion: '24.15.0',
      commandResolver: command => path.join(root, 'bin', command),
    });
    assert.equal(ready.status, 'ready');
    assert.equal(ready.summary.blocked, 0);
    assert.equal(ready.checks.find(check => check.id === 'grafana-alloy-executable').status, 'healthy');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('collects local profile observations from existing runtime files', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-orchestrator-health-'));
  try {
    const win64 = path.join(root, 'Brickadia', 'Binaries', 'Win64');
    const runtimeDir = path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'runtime');
    const omeggaRuntime = path.join(root, 'omegga');
    const alloyConfig = path.join(root, 'alloy', 'bmf.alloy');
    fs.mkdirSync(runtimeDir, { recursive: true });
    fs.mkdirSync(omeggaRuntime, { recursive: true });
    fs.mkdirSync(path.dirname(alloyConfig), { recursive: true });
    fs.writeFileSync(path.join(win64, 'BrickadiaServer-Win64-Shipping.exe'), '');
    fs.writeFileSync(path.join(win64, 'dwmapi.dll'), '');
    fs.writeFileSync(path.join(win64, 'ue4ss', 'main', 'Mods', 'BMF', 'enabled.txt'), '\n');
    fs.writeFileSync(alloyConfig, 'prometheus.scrape "bmf" {}\n');
    fs.writeFileSync(path.join(runtimeDir, 'events.jsonl'), '');
    fs.writeFileSync(path.join(runtimeDir, 'bmf.log'), '');
    fs.writeFileSync(
      path.join(runtimeDir, 'status.json'),
      JSON.stringify({
        state: 'running',
        version: '0.1.0-ea2.cl13530',
        updated_at: '2026-06-16T12:00:00Z',
        server_ready: true,
        command_worker_mode: 'async',
        socket_worker_started: true,
      }),
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'socket.json'),
      JSON.stringify({
        enabled: true,
        host: '127.0.0.1',
        port: 49152,
        token: 'secret-token',
        lastStatus: JSON.stringify({ connected: true }),
      }),
    );
    fs.writeFileSync(
      path.join(runtimeDir, 'frame-telemetry.json'),
      JSON.stringify({ sampleCount: 8, maxFrameMs: 14 }),
    );

    const now = new Date('2026-06-16T12:00:20.000Z');
    for (const file of ['status.json', 'socket.json', 'frame-telemetry.json']) {
      fs.utimesSync(path.join(runtimeDir, file), now, now);
    }

    const report = collectLocalProfileStatus({
      name: 'Observed Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        grafanaAlloyConfig: alloyConfig,
      },
      telemetry: {
        enabled: true,
        frameTelemetryEnabled: true,
        dashboardUrl: 'https://grafana.example/d/bmf?token=secret',
      },
    }, {
      root: repoRoot,
      now,
      freshnessMs: {
        bmfStatus: 60_000,
        socketMetadata: 60_000,
        frameTelemetry: 60_000,
      },
    });

    assert.equal(report.observations['brickadia-files'].status, 'healthy');
    assert.equal(report.observations['ue4ss-enabled'].status, 'healthy');
    assert.equal(report.observations['bmf-status-fresh'].status, 'healthy');
    assert.equal(report.observations['bmf-socket-connected'].status, 'healthy');
    assert.equal(report.observations['frame-telemetry-fresh'].status, 'healthy');
    assert.equal(report.observations['dashboard-imported'].status, 'healthy');
    assert.equal(report.observations['dashboard-imported'].evidence[0], 'https://grafana.example/d/bmf?token=[redacted]');
    assert.equal(report.observations['metrics-endpoint'].status, 'unknown');
    assert.equal(report.serviceDiagnostics.startReadiness.status, 'unknown');
    assert.ok(report.serviceDiagnostics.ports.some(port => port.id === 'brickadia'));
    assert.ok(report.logSources.some(source => source.id === 'events-jsonl' && source.exists));
    assert.ok(report.guardrails.includes('read-existing-runtime-files-only'));
    assert.ok(report.guardrails.includes('bounded-local-port-inspection'));

    const networkReport = collectLocalProfileStatus({
      name: 'Observed Server',
      paths: {
        brickadiaWin64: win64,
        omeggaRuntime,
        grafanaAlloyConfig: alloyConfig,
      },
      telemetry: {
        enabled: true,
        frameTelemetryEnabled: true,
        dashboardUrl: 'https://grafana.example/d/bmf?token=secret',
      },
    }, {
      root: repoRoot,
      now,
      metricsProbe: { ok: true, statusCode: 200 },
      alloyProbe: { ok: true, statusCode: 200 },
      freshnessMs: {
        bmfStatus: 60_000,
        socketMetadata: 60_000,
        frameTelemetry: 60_000,
      },
    });
    assert.equal(networkReport.observations['omegga-running'].status, 'healthy');
    assert.equal(networkReport.health.status, 'healthy');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function writeFixtureFile(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, contents, 'utf8');
}

function writeFixtureJson(filePath, value) {
  writeFixtureFile(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeFixtureBomJson(filePath, value) {
  writeFixtureFile(filePath, `\uFEFF${JSON.stringify(value, null, 2)}\n`);
}

function sha256FixtureFile(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function fixtureFileRecord(filePath, role) {
  return {
    role,
    fileName: path.basename(filePath),
    path: path.basename(filePath),
    bytes: fs.statSync(filePath).size,
    sha256: sha256FixtureFile(filePath),
  };
}

function writeMinimalTransactionSources(root) {
  writeFixtureJson(path.join(root, 'packages', 'omegga-runtime', 'source', 'package.json'), {
    name: 'omegga',
    version: 'test',
    scripts: { 'package:bmf': 'node tools/package-bmf-omegga.js' },
  });
  writeFixtureFile(path.join(root, 'packages', 'omegga-runtime', 'source', 'index.js'), 'module.exports = require("./src/omegga");\n');
  writeFixtureFile(path.join(root, 'packages', 'omegga-runtime', 'source', 'src', 'omegga', 'index.ts'), 'export const omegga = true;\n');
  writeFixtureFile(path.join(root, 'packages', 'omegga-runtime', 'source', 'src', 'brickadia', 'ue4ssBridge.ts'), 'export const bridge = true;\n');
  writeFixtureFile(path.join(root, 'packages', 'omegga-runtime', 'source', 'tools', 'package-bmf-omegga.js'), 'console.log("package bmf omegga");\n');
  writeFixtureFile(path.join(root, 'framework', 'ue4ss', 'Mods', 'BMF', 'bmf.json'), '{"name":"BMF"}\n');
  writeFixtureFile(path.join(root, 'framework', 'ue4ss', 'Mods', 'BMF', 'Scripts', 'main.lua'), 'return nil\n');
  writeFixtureFile(path.join(root, 'framework', 'ue4ss', 'Mods', 'BMFSocket', 'README.md'), 'socket helper\n');
  writeFixtureFile(path.join(root, 'framework', 'ue4ss', 'Mods', 'BMFFrameTelemetry', 'README.md'), 'frame telemetry helper\n');
  for (const name of ['bmf-bridge', 'bmf-player-sync', 'bmf-minigame-events']) {
    writeFixtureJson(path.join(root, 'packages', 'omegga-plugins', name, 'plugin.json'), { name });
    writeFixtureFile(path.join(root, 'packages', 'omegga-plugins', name, 'omegga.plugin.js'), 'module.exports = class {}\n');
  }
}

function writeDesktopReleaseEvidence(root) {
  const releaseDir = path.join(root, 'artifacts', 'local', 'bmf-desktop-release');
  const artifactName = 'BMF-Desktop-0.2.0-x64.msi';
  const artifactPath = path.join(releaseDir, artifactName);
  const checksumPath = `${artifactPath}.sha256`;
  const manifestPath = path.join(releaseDir, 'release-manifest.json');
  const catalogPath = path.join(releaseDir, 'release-catalog.json');
  const releaseNotesPath = path.join(releaseDir, 'RELEASE_NOTES.md');
  writeFixtureFile(artifactPath, 'MSI fixture bytes');
  const artifactRecord = fixtureFileRecord(artifactPath, 'installer');
  writeFixtureFile(checksumPath, `${artifactRecord.sha256}  ${artifactName}\n`);
  const checksumRecord = fixtureFileRecord(checksumPath, 'checksum');
  writeFixtureFile(releaseNotesPath, '# Fixture Release\n');
  const releaseNotesRecord = fixtureFileRecord(releaseNotesPath, 'release-notes');
  writeFixtureBomJson(manifestPath, {
    schemaVersion: 1,
    releaseKind: 'bmf-desktop-msi',
    bmfDesktopVersion: '0.2.0',
    primaryArtifact: artifactRecord,
    releaseCatalog: 'release-catalog.json',
    requiredArtifacts: [artifactName, `${artifactName}.sha256`, 'release-manifest.json', 'release-catalog.json', 'RELEASE_NOTES.md'],
  });
  const manifestRecord = fixtureFileRecord(manifestPath, 'release-manifest');
  const release = {
    version: '0.2.0',
    channel: 'dev',
    artifact: artifactRecord,
    checksum: checksumRecord,
    manifest: manifestRecord,
    releaseNotes: releaseNotesRecord,
  };
  writeFixtureBomJson(catalogPath, {
    schemaVersion: 1,
    catalogKind: 'bmf-desktop-release-catalog',
    releaseChannel: 'dev',
    latest: release,
    releases: [release],
    updateGuardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
  });
  return {
    releaseDir,
    artifactPath,
    manifestPath,
    catalogPath,
  };
}
