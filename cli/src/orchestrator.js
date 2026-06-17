const {
  OPERATION_IDS,
  SERVICE_ACTION_IDS,
  collectLocalProfileStatus,
  collectLogSnapshot,
  collectTrafficSnapshot,
  createDashboardImportPlan,
  createDesktopUpdateCheck,
  createDesktopUpdateInstallPlan,
  createDesktopUpdatePlan,
  createTelemetryOnboardingPlan,
  createBootstrapPlan,
  createOperationPlan,
  createPrerequisiteAudit,
  createServerProfile,
  createServiceActionPlan,
  deleteStoredProfile,
  executeServiceAction,
  getStoredProfile,
  inspectConfiguredPorts,
  loadProfileRegistry,
  createOperationTransaction,
  createRollbackTransaction,
  executeOperationTransaction,
  executeRollbackTransaction,
  executeDashboardImport,
  executeDesktopUpdateDownload,
  executeDesktopUpdateInstallHandoff,
  probeHttpEndpoint,
  resolveRuntimePaths,
  selectStoredProfile,
  upsertStoredProfile,
  writeDashboardImportPayload,
  writeTelemetryAlloyConfig,
} = require('../../packages/orchestrator-core/src');
const { resolveContext } = require('./context');

function profileFromContext(ctx, options = {}) {
  const storedProfile = loadStoredProfileForOptions(ctx, options);
  const storedPaths = storedProfile?.paths || {};
  const storedPorts = storedProfile?.ports || {};
  const storedTelemetry = storedProfile?.telemetry || {};
  const profileId = options.profileId || options.profile || storedProfile?.id || 'local';
  const profileName = options.profileName || storedProfile?.name || options.profile || 'local';
  return createServerProfile({
    id: profileId,
    name: profileName,
    backend: 'local-process',
    backendConfig: {},
    root: options.bmfRoot || options.root ? ctx.bmfRoot : storedProfile?.root || ctx.bmfRoot,
    paths: {
      brickadiaWin64: options.gameWin64 ? ctx.gameWin64Dir : storedPaths.brickadiaWin64 || ctx.gameWin64Dir,
      omeggaRuntime: options.omegga ? ctx.omeggaDir : storedPaths.omeggaRuntime || ctx.omeggaDir,
      omeggaStartScript: options.startScript || options.omeggaStartScript || storedPaths.omeggaStartScript || null,
      bmfRoot: options.bmfRoot || options.root ? ctx.bmfRoot : storedPaths.bmfRoot || ctx.bmfRoot,
      bmfRuntimeDir: options.bmfRuntimeDir || options.runtimeDir
        ? resolveBmfRuntimeDir(ctx, options)
        : storedPaths.bmfRuntimeDir || resolveBmfRuntimeDir(ctx, options),
      grafanaAlloyExecutable: options.alloyExecutable || options.grafanaAlloyExecutable || storedPaths.grafanaAlloyExecutable || null,
      grafanaAlloyConfig: options.alloyConfig || storedPaths.grafanaAlloyConfig || null,
    },
    ports: {
      brickadia: numberOption(options.brickadiaPort, storedPorts.brickadia ?? 7777),
      omeggaWeb: numberOption(options.omeggaWebPort, storedPorts.omeggaWeb ?? 8080),
      bmfSocket: numberOption(options.bmfSocketPort, storedPorts.bmfSocket ?? 0),
      alloyReady: numberOption(options.alloyReadyPort, storedPorts.alloyReady ?? 12345),
    },
    telemetry: {
      enabled: Boolean(options.telemetry ?? storedTelemetry.enabled),
      frameTelemetryEnabled: Boolean(options.frameTelemetry ?? storedTelemetry.frameTelemetryEnabled),
      environment: options.telemetryEnvironment || storedTelemetry.environment || 'local',
      instance: options.telemetryInstance || storedTelemetry.instance || options.profile || 'local',
      dashboardUrl: options.dashboardUrl || storedTelemetry.dashboardUrl || null,
    },
  });
}

function profileStoreOptions(ctx, options = {}) {
  return {
    root: ctx.bmfRoot,
    profileStorePath: options.profileStorePath || options.profileStore || options.storePath,
  };
}

function loadStoredProfileForOptions(ctx, options = {}) {
  const registry = loadProfileRegistry(profileStoreOptions(ctx, options));
  const id = options.profileId || options.profile || registry.selectedProfileId;
  if (!id) return null;
  return getStoredProfile(id, profileStoreOptions(ctx, options));
}

function listProfiles(options = {}) {
  const ctx = resolveContext(options);
  return loadProfileRegistry(profileStoreOptions(ctx, options));
}

function currentProfile(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  const registry = loadProfileRegistry(profileStoreOptions(ctx, options));
  return {
    schemaVersion: 1,
    storePath: registry.storePath,
    selectedProfileId: registry.selectedProfileId,
    profile,
    guardrails: registry.guardrails,
  };
}

function saveProfile(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  return upsertStoredProfile(profile, {
    ...profileStoreOptions(ctx, options),
    select: options.select !== false && options.noSelect !== true,
  });
}

function selectProfile(profileId, options = {}) {
  const ctx = resolveContext(options);
  return selectStoredProfile(profileId, profileStoreOptions(ctx, options));
}

function deleteProfile(profileId, options = {}) {
  const ctx = resolveContext(options);
  return deleteStoredProfile(profileId, profileStoreOptions(ctx, options));
}

function createPlan(operationId = 'bootstrap', options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  const manifestOptions = {
    root: ctx.bmfRoot,
    manifest: options.manifest,
    profile,
    dryRun: true,
  };

  if (operationId === 'bootstrap') {
    return createBootstrapPlan(manifestOptions);
  }

  return createOperationPlan(operationId, manifestOptions);
}

function createPrerequisiteReport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  return createPrerequisiteAudit({ profile }, {
    root: ctx.bmfRoot,
    env: process.env,
  });
}

function createUpdateCheck(options = {}) {
  const ctx = resolveContext(options);
  return createDesktopUpdateCheck({
    root: ctx.bmfRoot,
    catalogPath: options.releaseCatalog || options.releaseCatalogPath || options.catalogPath,
    currentVersion: options.currentVersion,
    releaseChannel: options.releaseChannel,
  });
}

function createUpdatePlan(options = {}) {
  const ctx = resolveContext(options);
  return createDesktopUpdatePlan({
    root: ctx.bmfRoot,
    catalogPath: options.releaseCatalog || options.releaseCatalogPath || options.catalogPath,
    currentVersion: options.currentVersion,
    releaseChannel: options.releaseChannel,
    downloadDir: options.outDir || options.downloadDir,
  });
}

function downloadUpdate(options = {}) {
  const ctx = resolveContext(options);
  return executeDesktopUpdateDownload({
    root: ctx.bmfRoot,
    catalogPath: options.releaseCatalog || options.releaseCatalogPath || options.catalogPath,
    currentVersion: options.currentVersion,
    releaseChannel: options.releaseChannel,
    downloadDir: options.outDir || options.downloadDir,
    confirm: options.confirm,
    fetch: options.fetch,
  });
}

function createUpdateInstallPlan(options = {}) {
  const ctx = resolveContext(options);
  return createDesktopUpdateInstallPlan({
    root: ctx.bmfRoot,
    catalogPath: options.releaseCatalog || options.releaseCatalogPath || options.catalogPath,
    currentVersion: options.currentVersion,
    releaseChannel: options.releaseChannel,
    downloadDir: options.outDir || options.downloadDir,
    installerPath: options.installerPath || options.msiPath,
  });
}

function installUpdate(options = {}) {
  const ctx = resolveContext(options);
  return executeDesktopUpdateInstallHandoff({
    root: ctx.bmfRoot,
    catalogPath: options.releaseCatalog || options.releaseCatalogPath || options.catalogPath,
    currentVersion: options.currentVersion,
    releaseChannel: options.releaseChannel,
    downloadDir: options.outDir || options.downloadDir,
    installerPath: options.installerPath || options.msiPath,
    confirm: options.confirm,
    launcher: options.launcher,
  });
}

function createTelemetryPlan(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, {
    ...options,
    telemetry: options.telemetry !== false,
  });
  return createTelemetryOnboardingPlan({ profile }, {
    root: ctx.bmfRoot,
    out: options.out || options.alloyConfig || null,
    env: process.env,
    scrapeInterval: options.scrapeInterval,
    grafanaBaseUrl: options.grafanaBaseUrl,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
  });
}

function writeTelemetryAlloy(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, {
    ...options,
    telemetry: options.telemetry !== false,
  });
  return writeTelemetryAlloyConfig({ profile }, {
    root: ctx.bmfRoot,
    out: options.out || options.alloyConfig || null,
    env: process.env,
    scrapeInterval: options.scrapeInterval,
    dryRun: Boolean(options.dryRun),
    grafanaBaseUrl: options.grafanaBaseUrl,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
  });
}

function createDashboardImport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, {
    ...options,
    telemetry: options.telemetry !== false,
  });
  return createDashboardImportPlan({ profile }, {
    root: ctx.bmfRoot,
    out: options.out || options.dashboardImportPath || null,
    env: process.env,
    grafanaBaseUrl: options.grafanaBaseUrl,
    grafanaApiTokenEnv: options.grafanaApiTokenEnv,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
    prometheusDatasourceName: options.prometheusDatasourceName,
  });
}

function writeDashboardImport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, {
    ...options,
    telemetry: options.telemetry !== false,
  });
  return writeDashboardImportPayload({ profile }, {
    root: ctx.bmfRoot,
    out: options.out || options.dashboardImportPath || null,
    env: process.env,
    dryRun: Boolean(options.dryRun),
    grafanaBaseUrl: options.grafanaBaseUrl,
    grafanaApiTokenEnv: options.grafanaApiTokenEnv,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
    prometheusDatasourceName: options.prometheusDatasourceName,
  });
}

function uploadDashboardImport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, {
    ...options,
    telemetry: options.telemetry !== false,
  });
  return executeDashboardImport({ profile }, {
    root: ctx.bmfRoot,
    out: options.out || options.dashboardImportPath || null,
    env: process.env,
    confirm: options.confirm,
    timeoutMs: options.timeoutMs,
    fetch: options.fetch,
    grafanaBaseUrl: options.grafanaBaseUrl,
    grafanaApiTokenEnv: options.grafanaApiTokenEnv,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
    prometheusDatasourceName: options.prometheusDatasourceName,
  });
}

async function createHealthReport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  const probeOptions = {};
  const includePortDiagnostics = Boolean(options.portDiagnostics || options.includePortDiagnostics || options.networkChecks);
  const paths = resolveRuntimePaths(profile);

  if (options.networkChecks || options.includeNetworkChecks) {
    const [metricsProbe, alloyProbe] = await Promise.all([
      probeHttpEndpoint(paths.omeggaMetricsUrl, { timeoutMs: numberOption(options.probeTimeoutMs, 500) }),
      profile.telemetry.enabled
        ? probeHttpEndpoint(paths.alloyReadyUrl, { timeoutMs: numberOption(options.probeTimeoutMs, 500) })
        : Promise.resolve(null),
    ]);
    probeOptions.metricsProbe = metricsProbe;
    if (alloyProbe) probeOptions.alloyProbe = alloyProbe;
  }
  if (includePortDiagnostics) {
    probeOptions.portInspection = await inspectConfiguredPorts(profile, {
      timeoutMs: numberOption(options.portProbeTimeoutMs || options.probeTimeoutMs, 1200),
    });
  }

  return collectLocalProfileStatus({ profile }, {
    root: ctx.bmfRoot,
    manifest: options.manifest,
    ...probeOptions,
  });
}

function createTrafficReport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  return collectTrafficSnapshot({ profile }, {
    root: ctx.bmfRoot,
    maxRecords: options.maxRecords || options.limit,
    maxBytesPerFile: options.maxBytesPerFile || options.maxBytes,
    maxCommandFiles: options.maxCommandFiles,
    anonymizePlayers: Boolean(options.anonymizePlayers),
    redactPrivateIps: Boolean(options.redactPrivateIps),
  });
}

function createLogReport(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  return collectLogSnapshot({ profile }, {
    root: ctx.bmfRoot,
    maxLines: options.maxLines || options.limit,
    maxBytesPerFile: options.maxBytesPerFile || options.maxBytes,
    maxSources: options.maxSources,
    maxJournalFiles: options.maxJournalFiles,
    journalRoot: options.journalRoot,
    redactPrivateIps: Boolean(options.redactPrivateIps),
  });
}

function createServiceAction(actionId = 'start-stack', options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  const actionOptions = {
    root: ctx.bmfRoot,
    serviceRoot: options.serviceRoot,
    journalPath: options.journalPath,
    logPath: options.logPath,
    pidPath: options.pidPath,
    startScript: options.startScript || options.omeggaStartScript,
    command: options.command || options.startCommand,
    args: normalizeArgs(options.args || options.startArgs),
    cwd: options.cwd,
    alloyExecutable: options.alloyExecutable || options.grafanaAlloyExecutable,
    alloyConfig: options.alloyConfig || options.grafanaAlloyConfig,
    alloyStoragePath: options.alloyStoragePath,
    now: options.now,
    killTimeoutMs: options.killTimeoutMs,
    commandTimeoutMs: options.commandTimeoutMs,
    commandRunner: options.commandRunner,
    processInspector: options.processInspector,
    processKiller: options.processKiller,
    processSpawner: options.processSpawner,
  };

  if (options.apply) {
    return executeServiceAction(actionId, { profile }, {
      ...actionOptions,
      dryRun: false,
      confirm: options.confirm,
      env: process.env,
    });
  }

  return createServiceActionPlan(actionId, { profile }, {
    ...actionOptions,
    dryRun: true,
  });
}

function normalizeArgs(value) {
  if (!value) return undefined;
  if (Array.isArray(value)) return value;
  return String(value).split(',').map(item => item.trim()).filter(Boolean);
}

function createTransaction(operationId = 'install-stack', options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  const transactionOptions = {
    root: ctx.bmfRoot,
    manifest: options.manifest,
    journalRoot: options.journalRoot,
    backupRoot: options.backupRoot,
    releaseCatalogPath: options.releaseCatalog || options.releaseCatalogPath || options.catalogPath,
    releaseManifestPath: options.releaseManifest || options.releaseManifestPath || options.manifestPath,
    scrapeInterval: options.scrapeInterval,
    grafanaBaseUrl: options.grafanaBaseUrl,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
    env: process.env,
  };

  if (options.apply) {
    return executeOperationTransaction(operationId, { profile }, {
      ...transactionOptions,
      dryRun: false,
      confirm: options.confirm,
    });
  }

  return createOperationTransaction(operationId, { profile }, {
    ...transactionOptions,
    dryRun: true,
  });
}

function rollbackTransaction(journalPath, options = {}) {
  if (!journalPath) throw new Error('rollback requires a transaction journal path.');
  if (options.apply) {
    return executeRollbackTransaction(journalPath, {
      dryRun: false,
      confirm: options.confirm,
      journalRoot: options.journalRoot,
      backupRoot: options.backupRoot,
    });
  }

  return createRollbackTransaction(journalPath, {
    dryRun: true,
    journalRoot: options.journalRoot,
    backupRoot: options.backupRoot,
  });
}

function resolveBmfRuntimeDir(ctx, options = {}) {
  const fs = require('node:fs');
  if (options.bmfRuntimeDir) return require('node:path').resolve(options.bmfRuntimeDir);
  if (options.runtimeDir) return require('node:path').resolve(options.runtimeDir);
  const modsDir = options.modsDir || ctx.liveModsDirs.find(dir => fs.existsSync(dir));
  return modsDir ? require('node:path').join(modsDir, 'BMF', 'runtime') : null;
}

function numberOption(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

module.exports = {
  OPERATION_IDS,
  SERVICE_ACTION_IDS,
  createHealthReport,
  createLogReport,
  createPlan,
  createPrerequisiteReport,
  createServiceAction,
  createUpdateCheck,
  createUpdateInstallPlan,
  createUpdatePlan,
  createDashboardImport,
  currentProfile,
  deleteProfile,
  downloadUpdate,
  installUpdate,
  listProfiles,
  createTelemetryPlan,
  createTrafficReport,
  createTransaction,
  profileFromContext,
  rollbackTransaction,
  saveProfile,
  selectProfile,
  uploadDashboardImport,
  writeDashboardImport,
  writeTelemetryAlloy,
};
