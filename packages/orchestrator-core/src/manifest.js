const crypto = require('node:crypto');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { exists, findBmfRoot, readJson } = require('./file');

const REQUIRED_COMPONENT_IDS = [
  'bmf-desktop',
  'orchestrator-core',
  'bmfctl',
  'bmf-runtime',
  'bmf-native-socket',
  'bmf-frame-telemetry',
  'omegga-runtime',
  'omegga-plugin-bmf-bridge',
  'omegga-plugin-bmf-player-sync',
  'omegga-plugin-bmf-minigame-events',
  'ue4ss-compatibility',
  'grafana-alloy',
  'grafana-dashboard',
];

const REQUIRED_RELEASE_ARTIFACTS = [
  'BMF-Desktop-<version>-x64.msi',
  'BMF-Desktop-<version>-x64.msi.sha256',
  'release-manifest.json',
  'release-catalog.json',
  'RELEASE_NOTES.md',
];

const RELEASE_CATALOG_GUARDRAILS = [
  'verify-sha256-before-install',
  'require-user-confirmation-before-desktop-update',
  'keep-desktop-update-separate-from-managed-server-updates',
  'do-not-stop-running-managed-services-without-confirmation',
];

const DESKTOP_UPDATE_DOWNLOAD_GUARDRAILS = [
  ...RELEASE_CATALOG_GUARDRAILS,
  'download-only-do-not-install',
  'verify-sha256-after-download',
  'require-confirm-download',
];

const DESKTOP_UPDATE_INSTALL_GUARDRAILS = [
  ...RELEASE_CATALOG_GUARDRAILS,
  'verify-sha256-before-installer-handoff',
  'require-confirm-install',
  'desktop-update-only',
  'do-not-update-managed-server-components',
];

function loadUnifiedRuntimeManifest(options = {}) {
  const root = path.resolve(options.root || findBmfRoot(options.cwd || process.cwd()));
  const manifestPath = path.join(root, 'manifests', 'unified-runtime.json');
  const manifest = readJson(manifestPath, null);
  if (!manifest) {
    throw new Error(`Unified runtime manifest could not be read at ${manifestPath}`);
  }

  return {
    root,
    manifestPath,
    manifest,
  };
}

function componentById(manifest, id) {
  return (manifest.components || []).find(component => component.id === id) || null;
}

function healthCheckById(manifest, id) {
  return (manifest.healthChecks || []).find(check => check.id === id) || null;
}

function validateUnifiedRuntimeManifest(manifest, options = {}) {
  const errors = [];
  const warnings = [];
  const root = options.root ? path.resolve(options.root) : null;

  if (!manifest || typeof manifest !== 'object') {
    return {
      ok: false,
      errors: ['Manifest is missing or invalid.'],
      warnings,
    };
  }

  if (manifest.desktop?.shell !== 'Electron') errors.push('Desktop shell must be Electron.');
  if (manifest.desktop?.renderer !== 'Angular') errors.push('Desktop renderer must be Angular.');
  if (!String(manifest.desktop?.componentSystem || '').includes('Angular Material 3')) {
    errors.push('Desktop component system must require Angular Material 3.');
  }
  if (manifest.desktop?.installer !== 'MSI') errors.push('Desktop installer must be MSI.');

  for (const id of REQUIRED_COMPONENT_IDS) {
    if (!componentById(manifest, id)) errors.push(`Missing component ${id}.`);
  }

  for (const check of manifest.healthChecks || []) {
    if (!componentById(manifest, check.component)) {
      errors.push(`Health check ${check.id} references unknown component ${check.component}.`);
    }
  }

  for (const artifact of REQUIRED_RELEASE_ARTIFACTS) {
    if (!Array.isArray(manifest.release?.requiredArtifacts) || !manifest.release.requiredArtifacts.includes(artifact)) {
      errors.push(`Missing required release artifact ${artifact}.`);
    }
  }

  if (root) {
    for (const component of manifest.components || []) {
      const source = String(component.source || '');
      if (!source || /^https?:\/\//.test(source)) continue;
      if (!exists(path.join(root, source))) {
        errors.push(`Component ${component.id} source does not exist: ${source}.`);
      }
    }
  }

  if (manifest.telemetry?.dashboardOwner !== 'Grafana') {
    errors.push('Telemetry dashboard owner must be Grafana.');
  }
  if (!String(manifest.eventTraffic?.preferredTransport || '').includes('BMFSocket')) {
    errors.push('Event traffic preferred transport must be BMFSocket.');
  }
  if (!Array.isArray(manifest.eventTraffic?.guardrails)) {
    errors.push('Event traffic guardrails are missing.');
  } else {
    for (const guardrail of [
      'socket-only-live-traffic',
      'do-not-add-ui-driven-server-probes',
      'do-not-send-bmf-commands',
      'redact-secrets-before-display-or-export',
    ]) {
      if (!manifest.eventTraffic.guardrails.includes(guardrail)) {
        errors.push(`Missing event traffic guardrail ${guardrail}.`);
      }
    }
  }

  return {
    ok: errors.length === 0,
    errors,
    warnings,
    componentCount: (manifest.components || []).length,
    healthCheckCount: (manifest.healthChecks || []).length,
    releaseArtifactCount: (manifest.release?.requiredArtifacts || []).length,
  };
}

function expectedReleaseArtifacts(manifest, version) {
  const resolvedVersion = String(version || '<version>');
  return (manifest.release?.requiredArtifacts || []).map(artifact =>
    artifact.replace(/<version>/g, resolvedVersion),
  );
}

function validateDesktopReleaseCatalog(catalog, options = {}) {
  const errors = [];
  const warnings = [];

  if (!catalog || typeof catalog !== 'object') {
    return {
      ok: false,
      errors: ['Release catalog is missing or invalid.'],
      warnings,
      releaseCount: 0,
      latestVersion: null,
      releaseChannel: null,
    };
  }

  if (Number(catalog.schemaVersion || 0) < 1) {
    errors.push('Release catalog schemaVersion must be >= 1.');
  }
  if (catalog.catalogKind !== 'bmf-desktop-release-catalog') {
    errors.push('Release catalog kind must be bmf-desktop-release-catalog.');
  }

  const expectedChannel = options.releaseChannel ? String(options.releaseChannel) : '';
  const releaseChannel = String(catalog.releaseChannel || '');
  if (!releaseChannel) {
    errors.push('Release catalog releaseChannel is missing.');
  } else if (expectedChannel && releaseChannel !== expectedChannel) {
    errors.push(`Release catalog channel ${releaseChannel} does not match expected channel ${expectedChannel}.`);
  }

  const releases = Array.isArray(catalog.releases) ? catalog.releases : [];
  if (releases.length === 0) {
    errors.push('Release catalog must include at least one release.');
  }
  const latest = catalog.latest && typeof catalog.latest === 'object'
    ? catalog.latest
    : null;
  if (!latest) {
    errors.push('Release catalog latest release is missing.');
  } else {
    validateCatalogRelease(latest, errors);
    if (releaseChannel && latest.channel && String(latest.channel) !== releaseChannel) {
      errors.push(`Latest release channel ${latest.channel} does not match catalog channel ${releaseChannel}.`);
    }
  }

  for (const guardrail of RELEASE_CATALOG_GUARDRAILS) {
    if (!Array.isArray(catalog.updateGuardrails) || !catalog.updateGuardrails.includes(guardrail)) {
      errors.push(`Release catalog is missing update guardrail ${guardrail}.`);
    }
  }

  return {
    ok: errors.length === 0,
    errors,
    warnings,
    releaseCount: releases.length,
    latestVersion: latest?.version || null,
    releaseChannel: releaseChannel || null,
  };
}

function latestDesktopRelease(catalog, options = {}) {
  const validation = validateDesktopReleaseCatalog(catalog, options);
  if (!validation.ok) {
    return {
      status: 'invalid',
      release: null,
      validation,
      guardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    };
  }

  const channel = options.releaseChannel ? String(options.releaseChannel) : String(catalog.releaseChannel || '');
  const releases = Array.isArray(catalog.releases) ? catalog.releases : [];
  const release = catalog.latest && (!channel || String(catalog.latest.channel || channel) === channel)
    ? catalog.latest
    : releases.find(item => String(item.channel || channel) === channel) || null;

  return {
    status: release ? 'ready' : 'missing',
    release,
    validation,
    guardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
  };
}

function createDesktopUpdateCheck(options = {}) {
  const root = path.resolve(options.root || findBmfRoot(options.cwd || process.cwd()));
  const catalogPath = options.catalogPath
    ? path.resolve(options.catalogPath)
    : path.join(root, 'artifacts', 'local', 'bmf-desktop-release', 'release-catalog.json');
  const currentVersion = String(options.currentVersion || readDesktopPackageVersion(root) || '0.0.0');
  const releaseChannel = String(options.releaseChannel || 'dev');
  const catalog = options.catalog || readJson(catalogPath, null);
  const base = {
    schemaVersion: 1,
    feature: 'desktop.update.check',
    root,
    catalogPath,
    currentVersion,
    releaseChannel,
    guardrails: RELEASE_CATALOG_GUARDRAILS.slice(),
    mutates: false,
    downloads: false,
    startsOrStopsServices: false,
  };

  if (!catalog) {
    return {
      ...base,
      status: 'catalog-missing',
      updateAvailable: false,
      latest: null,
      comparison: 'unknown',
      validation: {
        ok: false,
        errors: [`Release catalog could not be read at ${catalogPath}`],
        warnings: [],
      },
      artifactVerification: {
        status: 'not-checked',
        reason: 'release catalog missing',
      },
      nextActions: [
        'Build or download a release-catalog.json before checking for updates.',
      ],
    };
  }

  const latest = latestDesktopRelease(catalog, { releaseChannel });
  if (latest.status !== 'ready') {
    return {
      ...base,
      status: 'invalid-catalog',
      updateAvailable: false,
      latest: null,
      comparison: 'unknown',
      validation: latest.validation,
      artifactVerification: {
        status: 'not-checked',
        reason: 'release catalog invalid',
      },
      nextActions: [
        'Fix release-catalog.json before using it for update checks.',
      ],
    };
  }

  const release = latest.release;
  const comparison = compareVersions(release.version, currentVersion);
  const artifactVerification = verifyLocalCatalogArtifact(release, catalogPath);
  const status = comparison > 0
    ? 'update-available'
    : comparison < 0
    ? 'ahead'
    : 'up-to-date';

  return {
    ...base,
    status,
    updateAvailable: comparison > 0,
    latest: summarizeCatalogRelease(release),
    comparison: comparison > 0 ? 'newer' : comparison < 0 ? 'older' : 'same',
    validation: latest.validation,
    artifactVerification,
    nextActions: comparison > 0
      ? [
        'Verify the MSI checksum before installing.',
        'Require explicit user confirmation before running the desktop installer.',
        'Keep managed server component updates as a separate action.',
      ]
      : [],
  };
}

function createDesktopUpdatePlan(options = {}) {
  const check = createDesktopUpdateCheck(options);
  const root = check.root;
  const downloadDir = path.resolve(options.downloadDir || path.join(root, 'artifacts', 'local', 'bmf-desktop-updates'));
  const artifact = check.latest?.artifact || null;
  const downloadUrl = releaseDownloadUrl(check.latest);
  const outputPath = artifact?.fileName ? path.join(downloadDir, artifact.fileName) : null;
  const blockers = [];
  const steps = [];

  if (check.status === 'catalog-missing' || check.status === 'invalid-catalog') {
    blockers.push({
      id: check.status,
      summary: check.validation?.errors?.[0] || 'Release catalog is not usable.',
    });
  }
  if (!check.updateAvailable) {
    blockers.push({
      id: 'no-update-available',
      summary: `Current version ${check.currentVersion} is not behind the selected release.`,
    });
  }
  if (!downloadUrl) {
    blockers.push({
      id: 'download-url-missing',
      summary: 'Release catalog latest artifact does not include a download URL.',
    });
  } else if (!/^https?:\/\//i.test(downloadUrl)) {
    blockers.push({
      id: 'download-url-unsupported',
      summary: 'Release catalog latest artifact download URL must use http or https.',
    });
  }
  if (!outputPath) {
    blockers.push({
      id: 'artifact-name-missing',
      summary: 'Release catalog latest artifact does not include a file name.',
    });
  }

  steps.push({
    id: 'validate-release-catalog',
    title: 'Validate release catalog',
    status: check.validation?.ok ? 'ready' : 'blocked',
    mutates: false,
    summary: check.validation?.ok ? 'Catalog is valid.' : 'Catalog validation failed.',
  });
  steps.push({
    id: 'download-desktop-msi',
    title: 'Download BMF Desktop MSI',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    mutates: true,
    downloadUrl,
    outputPath,
    expectedSha256: artifact?.sha256 || null,
    summary: downloadUrl ? 'Download the MSI into the local update cache.' : 'No download URL is configured.',
  });
  steps.push({
    id: 'verify-desktop-msi-sha256',
    title: 'Verify BMF Desktop MSI SHA256',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    mutates: false,
    outputPath,
    expectedSha256: artifact?.sha256 || null,
    summary: 'Verify the downloaded MSI before any installer action.',
  });

  return {
    schemaVersion: 1,
    feature: 'desktop.update.download.plan',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    dryRun: true,
    root,
    catalogPath: check.catalogPath,
    downloadDir,
    currentVersion: check.currentVersion,
    latest: check.latest,
    updateCheck: check,
    artifact: artifact ? {
      fileName: artifact.fileName,
      url: downloadUrl,
      outputPath,
      bytes: artifact.bytes || null,
      sha256: artifact.sha256 || null,
    } : null,
    blockers,
    steps,
    guardrails: DESKTOP_UPDATE_DOWNLOAD_GUARDRAILS.slice(),
    mutates: false,
    downloads: false,
    installs: false,
    startsOrStopsServices: false,
  };
}

async function executeDesktopUpdateDownload(options = {}) {
  if (String(options.confirm || '').toLowerCase() !== 'download') {
    throw new Error('Refusing to download BMF Desktop update without --confirm download.');
  }

  const plan = createDesktopUpdatePlan(options);
  if (plan.status !== 'ready') {
    return {
      ...plan,
      feature: 'desktop.update.download',
      status: 'blocked',
      dryRun: false,
      confirmed: true,
      downloaded: false,
      verification: {
        status: 'not-checked',
        reason: 'download plan blocked',
      },
    };
  }

  const fetchImpl = options.fetch || globalThis.fetch;
  if (typeof fetchImpl !== 'function') {
    return {
      ...plan,
      feature: 'desktop.update.download',
      status: 'blocked',
      dryRun: false,
      confirmed: true,
      downloaded: false,
      blockers: [
        ...plan.blockers,
        {
          id: 'fetch-unavailable',
          summary: 'No fetch implementation is available for update download.',
        },
      ],
      verification: {
        status: 'not-checked',
        reason: 'fetch unavailable',
      },
    };
  }

  fs.mkdirSync(plan.downloadDir, { recursive: true });
  const response = await fetchImpl(plan.artifact.url, {
    method: 'GET',
    redirect: 'follow',
  });
  if (!response || !response.ok) {
    return {
      ...plan,
      feature: 'desktop.update.download',
      status: 'failed',
      dryRun: false,
      confirmed: true,
      downloaded: false,
      response: {
        ok: Boolean(response?.ok),
        status: response?.status || 0,
        statusText: response?.statusText || '',
      },
      verification: {
        status: 'not-checked',
        reason: 'download failed',
      },
    };
  }

  const body = Buffer.from(await response.arrayBuffer());
  fs.writeFileSync(plan.artifact.outputPath, body);
  const actualSha256 = sha256File(plan.artifact.outputPath);
  const verified = actualSha256 === String(plan.artifact.sha256 || '').toLowerCase();

  return {
    ...plan,
    feature: 'desktop.update.download',
    status: verified ? 'downloaded' : 'failed',
    dryRun: false,
    confirmed: true,
    downloaded: true,
    downloads: true,
    response: {
      ok: true,
      status: response.status,
      statusText: response.statusText || '',
    },
    verification: {
      status: verified ? 'verified' : 'mismatch',
      path: plan.artifact.outputPath,
      expectedSha256: plan.artifact.sha256,
      actualSha256,
      bytes: body.length,
    },
    installs: false,
    startsOrStopsServices: false,
  };
}

function createDesktopUpdateInstallPlan(options = {}) {
  const check = createDesktopUpdateCheck(options);
  const root = check.root;
  const downloadDir = path.resolve(options.downloadDir || path.join(root, 'artifacts', 'local', 'bmf-desktop-updates'));
  const artifact = check.latest?.artifact || null;
  const installerPath = path.resolve(options.installerPath || options.msiPath || (artifact?.fileName
    ? path.join(downloadDir, artifact.fileName)
    : path.join(downloadDir, 'BMF-Desktop-unknown-x64.msi')));
  const verification = verifyInstallerPath(installerPath, artifact?.sha256);
  const blockers = [];

  if (check.status === 'catalog-missing' || check.status === 'invalid-catalog') {
    blockers.push({
      id: check.status,
      summary: check.validation?.errors?.[0] || 'Release catalog is not usable.',
    });
  }
  if (!check.updateAvailable) {
    blockers.push({
      id: 'no-update-available',
      summary: `Current version ${check.currentVersion} is not behind the selected release.`,
    });
  }
  if (!artifact?.fileName) {
    blockers.push({
      id: 'artifact-name-missing',
      summary: 'Release catalog latest artifact does not include a file name.',
    });
  }
  if (verification.status !== 'verified') {
    blockers.push({
      id: verification.status === 'missing' ? 'installer-missing' : 'installer-sha256-mismatch',
      summary: verification.status === 'missing'
        ? 'The downloaded BMF Desktop MSI is missing.'
        : 'The downloaded BMF Desktop MSI does not match the release catalog SHA256.',
    });
  }

  const command = {
    executable: 'msiexec.exe',
    args: ['/i', installerPath],
    display: `msiexec.exe /i ${quoteCommandArg(installerPath)}`,
  };

  return {
    schemaVersion: 1,
    feature: 'desktop.update.install.plan',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    dryRun: true,
    root,
    catalogPath: check.catalogPath,
    currentVersion: check.currentVersion,
    latest: check.latest,
    updateCheck: check,
    installer: {
      path: installerPath,
      expectedSha256: artifact?.sha256 || null,
      verification,
    },
    command,
    blockers,
    steps: [
      {
        id: 'validate-release-catalog',
        title: 'Validate release catalog',
        status: check.validation?.ok ? 'ready' : 'blocked',
        mutates: false,
        summary: check.validation?.ok ? 'Catalog is valid.' : 'Catalog validation failed.',
      },
      {
        id: 'verify-downloaded-msi',
        title: 'Verify downloaded BMF Desktop MSI',
        status: verification.status === 'verified' ? 'ready' : 'blocked',
        mutates: false,
        installerPath,
        expectedSha256: artifact?.sha256 || null,
        summary: verification.status === 'verified'
          ? 'Downloaded MSI matches the release catalog SHA256.'
          : 'Downloaded MSI must match the release catalog SHA256 before install handoff.',
      },
      {
        id: 'handoff-to-windows-installer',
        title: 'Hand off to Windows Installer',
        status: blockers.length === 0 ? 'ready' : 'blocked',
        mutates: true,
        command: command.display,
        summary: 'Launch the verified BMF Desktop MSI for an explicit desktop update.',
      },
    ],
    guardrails: DESKTOP_UPDATE_INSTALL_GUARDRAILS.slice(),
    mutates: false,
    downloads: false,
    installs: false,
    startsOrStopsServices: false,
  };
}

function executeDesktopUpdateInstallHandoff(options = {}) {
  if (String(options.confirm || '').toLowerCase() !== 'install') {
    throw new Error('Refusing to launch BMF Desktop installer without --confirm install.');
  }

  const plan = createDesktopUpdateInstallPlan(options);
  if (plan.status !== 'ready') {
    return {
      ...plan,
      feature: 'desktop.update.install.handoff',
      status: 'blocked',
      dryRun: false,
      confirmed: true,
      launched: false,
      installs: false,
      launch: {
        status: 'not-started',
        reason: 'install plan blocked',
      },
    };
  }

  const launcher = options.launcher || launchWindowsInstaller;
  const launch = launcher(plan.command);
  return {
    ...plan,
    feature: 'desktop.update.install.handoff',
    status: launch.status === 'launched' ? 'handoff-started' : 'failed',
    dryRun: false,
    confirmed: true,
    launched: launch.status === 'launched',
    launch,
    mutates: true,
    downloads: false,
    installs: true,
    startsOrStopsServices: false,
  };
}

function validateCatalogRelease(release, errors) {
  if (!release.version) errors.push('Release catalog latest.version is missing.');
  if (!release.channel) errors.push('Release catalog latest.channel is missing.');
  if (!release.artifact || typeof release.artifact !== 'object') {
    errors.push('Release catalog latest.artifact is missing.');
  } else {
    if (!release.artifact.fileName) {
      errors.push('Release catalog latest.artifact.fileName is missing.');
    } else if (!/^BMF-Desktop-.+-x64\.msi$/.test(String(release.artifact.fileName))) {
      errors.push(`Release catalog latest artifact is not a BMF Desktop x64 MSI: ${release.artifact.fileName}.`);
    }
    if (!/^[a-f0-9]{64}$/i.test(String(release.artifact.sha256 || ''))) {
      errors.push('Release catalog latest.artifact.sha256 must be a SHA256 hash.');
    }
  }
  if (!release.checksum || release.checksum.fileName !== `${release.artifact?.fileName}.sha256`) {
    errors.push('Release catalog latest.checksum must point at the MSI .sha256 artifact.');
  }
  if (!release.manifest || release.manifest.fileName !== 'release-manifest.json') {
    errors.push('Release catalog latest.manifest must point at release-manifest.json.');
  }
  if (!release.releaseNotes || release.releaseNotes.fileName !== 'RELEASE_NOTES.md') {
    errors.push('Release catalog latest.releaseNotes must point at RELEASE_NOTES.md.');
  }
}

function summarizeCatalogRelease(release) {
  return {
    version: String(release.version || ''),
    channel: String(release.channel || ''),
    publishedAt: release.publishedAt || null,
    artifact: release.artifact ? {
      fileName: release.artifact.fileName || null,
      url: releaseDownloadUrl(release),
      bytes: release.artifact.bytes || null,
      sha256: release.artifact.sha256 || null,
    } : null,
    checksum: release.checksum ? {
      fileName: release.checksum.fileName || null,
      sha256: release.checksum.sha256 || null,
    } : null,
    manifest: release.manifest ? {
      fileName: release.manifest.fileName || null,
      sha256: release.manifest.sha256 || null,
    } : null,
    releaseNotes: release.releaseNotes ? {
      fileName: release.releaseNotes.fileName || null,
      sha256: release.releaseNotes.sha256 || null,
    } : null,
    supportedBrickadiaBuild: release.supportedBrickadiaBuild || null,
    bmfRuntimeVersion: release.bmfRuntimeVersion || null,
    omeggaRuntimeVersionOrCommit: release.omeggaRuntimeVersionOrCommit || null,
    ue4ssBundleId: release.ue4ssBundleId || null,
    dashboardVersion: release.dashboardVersion || null,
    minimumWindowsVersion: release.minimumWindowsVersion || null,
  };
}

function releaseDownloadUrl(release) {
  return release?.artifact?.url || release?.artifact?.downloadUrl || null;
}

function verifyLocalCatalogArtifact(release, catalogPath) {
  const fileName = release?.artifact?.fileName;
  const expectedSha256 = String(release?.artifact?.sha256 || '').toLowerCase();
  if (!fileName || !expectedSha256) {
    return {
      status: 'not-checked',
      reason: 'release artifact metadata missing',
    };
  }

  const artifactPath = path.join(path.dirname(catalogPath), fileName);
  if (!exists(artifactPath)) {
    return {
      status: 'missing',
      path: artifactPath,
      expectedSha256,
    };
  }

  const actualSha256 = sha256File(artifactPath);
  return {
    status: actualSha256 === expectedSha256 ? 'verified' : 'mismatch',
    path: artifactPath,
    expectedSha256,
    actualSha256,
    bytes: fs.statSync(artifactPath).size,
  };
}

function verifyInstallerPath(installerPath, expectedSha256) {
  const normalizedExpected = String(expectedSha256 || '').toLowerCase();
  if (!installerPath || !exists(installerPath)) {
    return {
      status: 'missing',
      path: installerPath || null,
      expectedSha256: normalizedExpected || null,
    };
  }
  const actualSha256 = sha256File(installerPath);
  return {
    status: actualSha256 === normalizedExpected ? 'verified' : 'mismatch',
    path: installerPath,
    expectedSha256: normalizedExpected || null,
    actualSha256,
    bytes: fs.statSync(installerPath).size,
  };
}

function launchWindowsInstaller(command) {
  if (process.platform !== 'win32') {
    return {
      status: 'failed',
      reason: 'Windows Installer handoff is only supported on Windows.',
    };
  }
  const child = childProcess.spawn(command.executable, command.args, {
    detached: true,
    stdio: 'ignore',
    windowsHide: false,
  });
  child.unref();
  return {
    status: 'launched',
    pid: child.pid,
    command: command.display,
  };
}

function readDesktopPackageVersion(root) {
  const packageJson = readJson(path.join(root, 'apps', 'bmf-desktop', 'package.json'), null);
  return packageJson?.version || null;
}

function sha256File(filepath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filepath)).digest('hex');
}

function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  for (let index = 0; index < Math.max(a.parts.length, b.parts.length); index++) {
    const delta = (a.parts[index] || 0) - (b.parts[index] || 0);
    if (delta !== 0) return delta > 0 ? 1 : -1;
  }
  if (a.pre === b.pre) return 0;
  if (!a.pre && b.pre) return 1;
  if (a.pre && !b.pre) return -1;
  return a.pre > b.pre ? 1 : -1;
}

function parseVersion(value) {
  const [core, pre = ''] = String(value || '0.0.0').replace(/^v/i, '').split('-', 2);
  return {
    parts: core.split('.').map(part => Number.parseInt(part, 10)).map(number => Number.isFinite(number) ? number : 0),
    pre,
  };
}

function quoteCommandArg(value) {
  const text = String(value || '');
  if (!text) return '""';
  return `"${text.replace(/"/g, '\\"')}"`;
}

module.exports = {
  DESKTOP_UPDATE_DOWNLOAD_GUARDRAILS,
  DESKTOP_UPDATE_INSTALL_GUARDRAILS,
  REQUIRED_COMPONENT_IDS,
  RELEASE_CATALOG_GUARDRAILS,
  REQUIRED_RELEASE_ARTIFACTS,
  componentById,
  createDesktopUpdateCheck,
  createDesktopUpdatePlan,
  createDesktopUpdateInstallPlan,
  executeDesktopUpdateDownload,
  executeDesktopUpdateInstallHandoff,
  expectedReleaseArtifacts,
  healthCheckById,
  latestDesktopRelease,
  loadUnifiedRuntimeManifest,
  validateDesktopReleaseCatalog,
  validateUnifiedRuntimeManifest,
};
