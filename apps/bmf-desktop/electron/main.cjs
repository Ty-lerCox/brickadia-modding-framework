const fs = require('node:fs');
const path = require('node:path');
const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');

const SOURCE_REPO_ROOT = path.resolve(__dirname, '..', '..', '..');
const DESKTOP_APP_NAME = 'BMF Desktop';
const BRICKADIA_SERVER_EXE = 'BrickadiaServer-Win64-Shipping.exe';
const BRICKADIA_INSTALL_SEARCH_MAX_DEPTH = 6;
const BRICKADIA_INSTALL_SEARCH_MAX_DIRECTORIES = 1500;
const BRICKADIA_INSTALL_SEARCH_IGNORED_DIRS = new Set([
  '.git',
  '.hg',
  '.svn',
  'Config',
  'Content',
  'DerivedDataCache',
  'Intermediate',
  'Logs',
  'node_modules',
  'Saved',
]);
const LEGACY_USER_DATA_DIRS = [
  path.join(app.getPath('appData'), '@bmf', 'desktop'),
];

app.setName(DESKTOP_APP_NAME);
app.setPath('userData', resolveDesktopUserDataPath());

function resolveDesktopUserDataPath() {
  const explicit = process.env.BMF_DESKTOP_USER_DATA_DIR || process.env.BMF_DESKTOP_PORTABLE_DATA_DIR;
  if (explicit) return path.resolve(explicit);
  if (app.isPackaged && process.env.PORTABLE_EXECUTABLE_DIR) {
    return path.join(process.env.PORTABLE_EXECUTABLE_DIR, `${DESKTOP_APP_NAME} Data`);
  }
  return path.join(app.getPath('appData'), DESKTOP_APP_NAME);
}

function loadOrchestrator() {
  try {
    const installed = require('@bmf/orchestrator-core');
    if (
      installed.collectTrafficSnapshot &&
      installed.collectLogSnapshot &&
      installed.createOperationTransaction &&
      installed.createRollbackTransaction &&
      installed.executeRollbackTransaction &&
      installed.createServiceActionPlan &&
      installed.createDashboardImportPlan &&
      installed.writeTelemetryAlloyConfig &&
      installed.writeDashboardImportPayload &&
      installed.executeDashboardImport &&
      installed.createDesktopUpdateCheck &&
      installed.createDesktopUpdatePlan &&
      installed.executeDesktopUpdateDownload &&
      installed.createDesktopUpdateInstallPlan &&
      installed.executeDesktopUpdateInstallHandoff &&
      installed.createTroubleshootingSnapshotPlan &&
      installed.writeTroubleshootingSnapshot &&
      installed.writeTrafficTraceExport &&
      installed.createPrerequisiteAudit &&
      installed.upsertStoredProfile
    ) return installed;
  } catch {
  }
  return require(path.join(SOURCE_REPO_ROOT, 'packages', 'orchestrator-core', 'src'));
}

const orchestrator = loadOrchestrator();

function bundledBmfRoot() {
  if (app.isPackaged) return path.join(process.resourcesPath, 'bmf');
  return SOURCE_REPO_ROOT;
}

function desktopRoot(input = {}) {
  const candidate = input.root
    || (app.isPackaged ? null : input.profile?.root)
    || (app.isPackaged ? null : input.profile?.paths?.bmfRoot)
    || bundledBmfRoot();
  return path.resolve(candidate);
}

function desktopDataPath(...segments) {
  return path.join(app.getPath('userData'), ...segments);
}

function profileStorePath(input = {}) {
  if (input.profileStorePath || input.profileStore) {
    return input.profileStorePath || input.profileStore;
  }
  const storePath = desktopDataPath('profiles', 'profiles.json');
  migrateLegacyProfileStore(storePath);
  return storePath;
}

function journalRoot(input = {}) {
  return input.journalRoot || desktopDataPath('transactions');
}

function serviceRoot(input = {}) {
  return input.serviceRoot || desktopDataPath('services');
}

function updateDownloadDir(input = {}) {
  return input.downloadDir || desktopDataPath('updates');
}

function migrateLegacyProfileStore(storePath) {
  if (fs.existsSync(storePath)) return;
  const legacyStorePath = LEGACY_USER_DATA_DIRS
    .map(directory => path.join(directory, 'profiles', 'profiles.json'))
    .find(candidate => fs.existsSync(candidate));
  if (!legacyStorePath) return;

  fs.mkdirSync(path.dirname(storePath), { recursive: true });
  fs.copyFileSync(legacyStorePath, storePath, fs.constants.COPYFILE_EXCL);
}

const PROFILE_PATH_PICKERS = {
  brickadiaWin64: {
    title: 'Select Brickadia Win64 folder',
    properties: ['openDirectory'],
  },
  omeggaRuntime: {
    title: 'Select Omegga runtime folder',
    properties: ['openDirectory'],
  },
  omeggaStartScript: {
    title: 'Select Omegga start script',
    properties: ['openFile'],
    filters: [
      { name: 'PowerShell scripts', extensions: ['ps1'] },
      { name: 'All files', extensions: ['*'] },
    ],
  },
  bmfRoot: {
    title: 'Select BMF repository folder',
    properties: ['openDirectory'],
  },
  bmfRuntimeDir: {
    title: 'Select BMF runtime folder',
    properties: ['openDirectory'],
  },
  grafanaAlloyExecutable: {
    title: 'Select Grafana Alloy executable',
    properties: ['openFile'],
    filters: [
      { name: 'Executables', extensions: ['exe'] },
      { name: 'All files', extensions: ['*'] },
    ],
  },
  grafanaAlloyConfig: {
    title: 'Choose Grafana Alloy config path',
    mode: 'save',
    filters: [
      { name: 'Alloy config', extensions: ['alloy'] },
      { name: 'All files', extensions: ['*'] },
    ],
  },
};

function createWindow() {
  const window = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 1100,
    minHeight: 720,
    title: 'BMF Desktop',
    backgroundColor: '#f8faf8',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  const devServerUrl = process.env.BMF_DESKTOP_DEV_SERVER_URL;
  if (devServerUrl) {
    window.loadURL(devServerUrl);
    return window;
  }

  window.loadFile(path.join(__dirname, '..', 'dist', 'bmf-desktop', 'browser', 'index.html'));
  return window;
}

app.whenReady().then(() => {
  registerIpcHandlers();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

function registerIpcHandlers() {
  ipcMain.handle('bmf:bootstrap-plan', (_event, input = {}) => {
    return orchestrator.createBootstrapPlan({
      root: desktopRoot(input),
      profile: desktopProfileInput(input),
    });
  });

  ipcMain.handle('bmf:profiles-list', (_event, input = {}) => {
    const registry = orchestrator.loadProfileRegistry({
      root: desktopRoot(input),
      profileStorePath: profileStorePath(input),
    });
    return normalizeDesktopProfileRegistry(registry, input);
  });

  ipcMain.handle('bmf:profile-save', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    const registry = orchestrator.upsertStoredProfile(profile, {
      root: desktopRoot(input),
      profileStorePath: profileStorePath(input),
      select: input.select !== false,
    });
    return normalizeDesktopProfileRegistry(registry, input);
  });

  ipcMain.handle('bmf:profile-select', (_event, profileId, input = {}) => {
    const registry = orchestrator.selectStoredProfile(profileId, {
      root: desktopRoot(input),
      profileStorePath: profileStorePath(input),
    });
    return normalizeDesktopProfileRegistry(registry, input);
  });

  ipcMain.handle('bmf:choose-path', async (event, input = {}) => {
    const field = String(input.field || input.id || '');
    const picker = PROFILE_PATH_PICKERS[field];
    if (!picker) {
      throw new Error(`Unknown profile path picker: ${field || '(missing)'}`);
    }

    const window = BrowserWindow.fromWebContents(event.sender);
    const options = {
      title: picker.title,
      defaultPath: input.currentPath || input.defaultPath || undefined,
      filters: picker.filters,
    };
    const result = picker.mode === 'save'
      ? await dialog.showSaveDialog(window, options)
      : await dialog.showOpenDialog(window, {
        ...options,
        properties: picker.properties,
      });

    const selectedPath = picker.mode === 'save'
      ? result.filePath
      : result.filePaths?.[0];
    return {
      field,
      canceled: Boolean(result.canceled),
      path: result.canceled ? null : selectedPath || null,
    };
  });

  ipcMain.handle('bmf:profile-from-brickadia-install', async (event, input = {}) => {
    const window = BrowserWindow.fromWebContents(event.sender);
    const picker = await dialog.showOpenDialog(window, {
      title: 'Select Brickadia Dedicated Server install folder',
      defaultPath: input.currentPath || input.defaultPath || input.profile?.paths?.brickadiaWin64 || undefined,
      properties: ['openDirectory'],
    });
    const selectedPath = picker.filePaths?.[0] || null;
    if (picker.canceled || !selectedPath) {
      return emptyBrickadiaInstallSetupResult('canceled', selectedPath, { canceled: true });
    }

    const search = findBrickadiaWin64Path(selectedPath);
    if (!search.brickadiaWin64) {
      return {
        canceled: false,
        status: 'not-found',
        selectedPath,
        brickadiaWin64: null,
        profile: null,
        registry: null,
        warnings: [
          `Could not find ${BRICKADIA_SERVER_EXE} under ${selectedPath}.`,
          ...search.warnings,
        ],
        search: publicBrickadiaInstallSearch(search),
      };
    }

    const root = desktopRoot(input);
    const storePath = profileStorePath(input);
    const baseProfile = desktopProfileInput(input);
    const profile = orchestrator.createServerProfile({
      root,
      ...baseProfile,
      paths: {
        ...(baseProfile.paths || {}),
        brickadiaWin64: search.brickadiaWin64,
        bmfRoot: baseProfile.paths?.bmfRoot || root,
      },
    });
    const existingProfile = typeof orchestrator.getStoredProfile === 'function'
      ? orchestrator.getStoredProfile(profile.id, {
        root,
        profileStorePath: storePath,
      })
      : null;
    const registry = orchestrator.upsertStoredProfile(profile, {
      root,
      profileStorePath: storePath,
      select: true,
    });
    const normalizedRegistry = normalizeDesktopProfileRegistry(registry, input);
    const selectedProfile = normalizedRegistry.profiles.find(entry => entry.id === normalizedRegistry.selectedProfileId) || profile;

    return {
      canceled: false,
      status: existingProfile ? 'updated' : 'created',
      selectedPath,
      brickadiaWin64: search.brickadiaWin64,
      profile: selectedProfile,
      registry: normalizedRegistry,
      warnings: search.warnings,
      search: publicBrickadiaInstallSearch(search),
    };
  });

  ipcMain.handle('bmf:operation-plan', (_event, operationId, input = {}) => {
    return orchestrator.createOperationPlan(operationId, {
      root: desktopRoot(input),
      profile: input.profile,
    });
  });

  ipcMain.handle('bmf:operation-transaction', (_event, operationId, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    if (input.apply && String(input.confirm || '').toLowerCase() !== 'apply') {
      throw new Error('Refusing to apply transaction without explicit confirmation.');
    }
    const options = {
      root: desktopRoot(input),
      journalRoot: journalRoot(input),
      backupRoot: input.backupRoot,
      releaseCatalogPath: input.releaseCatalogPath || input.releaseCatalog || input.catalogPath,
      releaseManifestPath: input.releaseManifestPath || input.releaseManifest || input.manifestPath,
      scrapeInterval: input.scrapeInterval || '15s',
      grafanaBaseUrl: input.grafanaBaseUrl,
      folderUid: input.folderUid,
      prometheusDatasourceUid: input.prometheusDatasourceUid,
      env: process.env,
    };
    if (input.apply) {
      return orchestrator.executeOperationTransaction(operationId, { profile }, {
        ...options,
        dryRun: false,
        confirm: input.confirm,
      });
    }
    return orchestrator.createOperationTransaction(operationId, { profile }, {
      ...options,
      dryRun: true,
    });
  });

  ipcMain.handle('bmf:rollback-transaction', (_event, input = {}) => {
    const journalPath = input.journalPath || input.sourceJournalPath;
    if (!journalPath) {
      throw new Error('Rollback requires a transaction journal path.');
    }
    const options = {
      journalRoot: journalRoot(input),
      backupRoot: input.backupRoot,
    };
    if (input.apply) {
      if (String(input.confirm || '').toLowerCase() !== 'rollback') {
        throw new Error('Refusing to apply rollback without explicit confirmation.');
      }
      return orchestrator.executeRollbackTransaction(journalPath, {
        ...options,
        dryRun: false,
        confirm: input.confirm,
      });
    }
    return orchestrator.createRollbackTransaction(journalPath, {
      ...options,
      dryRun: true,
    });
  });

  ipcMain.handle('bmf:service-action', (_event, actionId, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    const options = {
      root: desktopRoot(input),
      serviceRoot: serviceRoot(input),
      journalPath: input.journalPath,
      logPath: input.logPath,
      pidPath: input.pidPath,
      startScript: input.startScript || input.omeggaStartScript,
      cwd: input.cwd,
      commandTimeoutMs: input.commandTimeoutMs,
      alloyExecutable: input.alloyExecutable || input.grafanaAlloyExecutable,
      alloyConfig: input.alloyConfig || input.grafanaAlloyConfig,
      alloyStoragePath: input.alloyStoragePath,
    };
    if (input.apply) {
      const expectedConfirm = serviceConfirmForAction(actionId);
      if (String(input.confirm || '').toLowerCase() !== expectedConfirm) {
        throw new Error(`Refusing to ${expectedConfirm} service without explicit confirmation.`);
      }
      return orchestrator.executeServiceAction(actionId, { profile }, {
        ...options,
        dryRun: false,
        confirm: input.confirm,
        env: process.env,
      });
    }
    return orchestrator.createServiceActionPlan(actionId, { profile }, {
      ...options,
      dryRun: true,
    });
  });

  ipcMain.handle('bmf:update-check', (_event, input = {}) => {
    return orchestrator.createDesktopUpdateCheck({
      root: desktopRoot(input),
      catalogPath: input.releaseCatalogPath || input.releaseCatalog || input.catalogPath,
      currentVersion: input.currentVersion || app.getVersion(),
      releaseChannel: input.releaseChannel || 'dev',
    });
  });

  ipcMain.handle('bmf:update-plan', (_event, input = {}) => {
    return orchestrator.createDesktopUpdatePlan({
      root: desktopRoot(input),
      catalogPath: input.releaseCatalogPath || input.releaseCatalog || input.catalogPath,
      currentVersion: input.currentVersion || app.getVersion(),
      releaseChannel: input.releaseChannel || 'dev',
      downloadDir: updateDownloadDir(input),
    });
  });

  ipcMain.handle('bmf:update-download', (_event, input = {}) => {
    if (String(input.confirm || '').toLowerCase() !== 'download') {
      throw new Error('Refusing to download desktop update without explicit confirmation.');
    }
    return orchestrator.executeDesktopUpdateDownload({
      root: desktopRoot(input),
      catalogPath: input.releaseCatalogPath || input.releaseCatalog || input.catalogPath,
      currentVersion: input.currentVersion || app.getVersion(),
      releaseChannel: input.releaseChannel || 'dev',
      downloadDir: updateDownloadDir(input),
      confirm: input.confirm,
    });
  });

  ipcMain.handle('bmf:update-install-plan', (_event, input = {}) => {
    return orchestrator.createDesktopUpdateInstallPlan({
      root: desktopRoot(input),
      catalogPath: input.releaseCatalogPath || input.releaseCatalog || input.catalogPath,
      currentVersion: input.currentVersion || app.getVersion(),
      releaseChannel: input.releaseChannel || 'dev',
      downloadDir: updateDownloadDir(input),
      installerPath: input.installerPath || input.msiPath,
    });
  });

  ipcMain.handle('bmf:update-install-handoff', (_event, input = {}) => {
    if (String(input.confirm || '').toLowerCase() !== 'install') {
      throw new Error('Refusing to launch desktop installer without explicit confirmation.');
    }
    return orchestrator.executeDesktopUpdateInstallHandoff({
      root: desktopRoot(input),
      catalogPath: input.releaseCatalogPath || input.releaseCatalog || input.catalogPath,
      currentVersion: input.currentVersion || app.getVersion(),
      releaseChannel: input.releaseChannel || 'dev',
      downloadDir: updateDownloadDir(input),
      installerPath: input.installerPath || input.msiPath,
      confirm: input.confirm,
    });
  });

  ipcMain.handle('bmf:profile-health', async (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    const probeOptions = {};
    if (input.includeNetworkChecks || input.includePortDiagnostics) {
      const paths = orchestrator.resolveRuntimePaths(profile);
      const [metricsProbe, alloyProbe, portInspection] = await Promise.all([
        input.includeNetworkChecks
          ? orchestrator.probeHttpEndpoint(paths.omeggaMetricsUrl, { timeoutMs: 500 })
          : Promise.resolve(null),
        input.includeNetworkChecks && profile.telemetry.enabled
          ? orchestrator.probeHttpEndpoint(paths.alloyReadyUrl, { timeoutMs: 500 })
          : Promise.resolve(null),
        input.includePortDiagnostics
          ? orchestrator.inspectConfiguredPorts(profile, { timeoutMs: 5000 })
          : Promise.resolve(null),
      ]);
      if (metricsProbe) probeOptions.metricsProbe = metricsProbe;
      if (alloyProbe) probeOptions.alloyProbe = alloyProbe;
      if (portInspection) probeOptions.portInspection = portInspection;
    }

    return orchestrator.collectLocalProfileStatus({ profile }, {
      root: desktopRoot(input),
      ...probeOptions,
    });
  });

  ipcMain.handle('bmf:telemetry-plan', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    return orchestrator.createTelemetryOnboardingPlan({ profile }, {
      root: desktopRoot(input),
      out: alloyConfigOutputPath(profile, input),
      scrapeInterval: input.scrapeInterval || '15s',
      grafanaBaseUrl: input.grafanaBaseUrl,
      folderUid: input.folderUid,
      prometheusDatasourceUid: input.prometheusDatasourceUid,
      env: process.env,
    });
  });

  ipcMain.handle('bmf:telemetry-alloy-write', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    if (String(input.confirm || '').toLowerCase() !== 'write-alloy') {
      throw new Error('Refusing to write Alloy config without explicit confirmation.');
    }
    return orchestrator.writeTelemetryAlloyConfig({ profile }, {
      root: desktopRoot(input),
      out: alloyConfigOutputPath(profile, input),
      dryRun: false,
      scrapeInterval: input.scrapeInterval || '15s',
      grafanaBaseUrl: input.grafanaBaseUrl,
      folderUid: input.folderUid,
      prometheusDatasourceUid: input.prometheusDatasourceUid,
      env: process.env,
    });
  });

  ipcMain.handle('bmf:dashboard-import-plan', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    return orchestrator.createDashboardImportPlan({ profile }, {
      root: desktopRoot(input),
      out: dashboardImportOutputPath(profile, input),
      grafanaBaseUrl: input.grafanaBaseUrl,
      grafanaApiTokenEnv: input.grafanaApiTokenEnv,
      folderUid: input.folderUid,
      prometheusDatasourceUid: input.prometheusDatasourceUid,
      prometheusDatasourceName: input.prometheusDatasourceName,
      env: process.env,
    });
  });

  ipcMain.handle('bmf:dashboard-import-payload', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    return orchestrator.writeDashboardImportPayload({ profile }, {
      root: desktopRoot(input),
      out: dashboardImportOutputPath(profile, input),
      dryRun: Boolean(input.dryRun),
      grafanaBaseUrl: input.grafanaBaseUrl,
      grafanaApiTokenEnv: input.grafanaApiTokenEnv,
      folderUid: input.folderUid,
      prometheusDatasourceUid: input.prometheusDatasourceUid,
      prometheusDatasourceName: input.prometheusDatasourceName,
      env: process.env,
    });
  });

  ipcMain.handle('bmf:dashboard-import-upload', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    if (String(input.confirm || '').toLowerCase() !== 'import') {
      throw new Error('Refusing to upload dashboard without explicit confirmation.');
    }
    return orchestrator.executeDashboardImport({ profile }, {
      root: desktopRoot(input),
      out: dashboardImportOutputPath(profile, input),
      confirm: input.confirm,
      timeoutMs: input.timeoutMs || 10000,
      grafanaBaseUrl: input.grafanaBaseUrl,
      grafanaApiTokenEnv: input.grafanaApiTokenEnv,
      folderUid: input.folderUid,
      prometheusDatasourceUid: input.prometheusDatasourceUid,
      prometheusDatasourceName: input.prometheusDatasourceName,
      env: process.env,
    });
  });

  ipcMain.handle('bmf:traffic-snapshot', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    return orchestrator.collectTrafficSnapshot({ profile }, {
      root: desktopRoot(input),
      maxRecords: input.maxRecords || input.limit,
      maxBytesPerFile: input.maxBytesPerFile || input.maxBytes,
      maxCommandFiles: input.maxCommandFiles,
      anonymizePlayers: Boolean(input.anonymizePlayers),
      redactPrivateIps: Boolean(input.redactPrivateIps),
    });
  });

  ipcMain.handle('bmf:traffic-export', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    if (String(input.confirm || '').toLowerCase() !== 'export') {
      throw new Error('Refusing to export traffic trace without explicit confirmation.');
    }
    return orchestrator.writeTrafficTraceExport({ profile }, {
      root: desktopRoot(input),
      out: trafficTraceOutputPath(profile, input),
      dryRun: false,
      confirm: input.confirm,
      maxRecords: input.maxRecords || input.limit,
      maxBytesPerFile: input.maxBytesPerFile || input.maxBytes,
      maxCommandFiles: input.maxCommandFiles,
      anonymizePlayers: input.anonymizePlayers !== false,
      redactPrivateIps: input.redactPrivateIps !== false,
    });
  });

  ipcMain.handle('bmf:log-snapshot', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    return orchestrator.collectLogSnapshot({ profile }, {
      root: desktopRoot(input),
      maxLines: input.maxLines || input.limit,
      maxBytesPerFile: input.maxBytesPerFile || input.maxBytes,
      maxSources: input.maxSources,
      maxJournalFiles: input.maxJournalFiles,
      journalRoot: journalRoot(input),
      redactPrivateIps: Boolean(input.redactPrivateIps),
    });
  });

  ipcMain.handle('bmf:troubleshooting-snapshot-plan', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    return orchestrator.createTroubleshootingSnapshotPlan({ profile }, snapshotOptions(profile, input));
  });

  ipcMain.handle('bmf:troubleshooting-snapshot-write', (_event, input = {}) => {
    const profile = orchestrator.createServerProfile({
      root: desktopRoot(input),
      ...desktopProfileInput(input),
    });
    if (String(input.confirm || '').toLowerCase() !== 'snapshot') {
      throw new Error('Refusing to write troubleshooting snapshot without explicit confirmation.');
    }
    return orchestrator.writeTroubleshootingSnapshot({ profile }, {
      ...snapshotOptions(profile, input),
      confirm: input.confirm,
    });
  });

  ipcMain.handle('bmf:open-external', (_event, url) => {
    if (!/^https?:\/\//.test(String(url || ''))) {
      throw new Error('Only http and https links can be opened externally.');
    }
    return shell.openExternal(url);
  });
}

function desktopProfileInput(input = {}) {
  const root = desktopRoot(input);
  const base = input.profile || {
    name: 'Local Server',
    telemetry: {
      enabled: Boolean(input.telemetryEnabled),
    },
  };
  return {
    ...base,
    root: base.root || root,
    paths: {
      ...(base.paths || {}),
      bmfRoot: desktopProfileBmfRoot(base.paths?.bmfRoot, root),
    },
  };
}

function desktopProfileBmfRoot(profileBmfRoot, root) {
  if (app.isPackaged) return root;
  return profileBmfRoot || root;
}

function normalizeDesktopProfileRegistry(registry, input = {}) {
  const root = desktopRoot(input);
  return {
    ...registry,
    profiles: (registry.profiles || []).map(profile => normalizeDesktopProfile(profile, root)),
  };
}

function normalizeDesktopProfile(profile, root) {
  return {
    ...profile,
    root: app.isPackaged ? root : profile.root,
    paths: {
      ...(profile.paths || {}),
      bmfRoot: desktopProfileBmfRoot(profile.paths?.bmfRoot, root),
    },
  };
}

function emptyBrickadiaInstallSetupResult(status, selectedPath = null, options = {}) {
  return {
    canceled: Boolean(options.canceled),
    status,
    selectedPath,
    brickadiaWin64: null,
    profile: null,
    registry: null,
    warnings: [],
    search: {
      executable: BRICKADIA_SERVER_EXE,
      visitedDirectories: 0,
      maxDirectories: BRICKADIA_INSTALL_SEARCH_MAX_DIRECTORIES,
      maxDepth: BRICKADIA_INSTALL_SEARCH_MAX_DEPTH,
      truncated: false,
      evidence: [],
    },
  };
}

function findBrickadiaWin64Path(selectedPath) {
  const root = path.resolve(selectedPath);
  const evidence = [];
  const warnings = [];
  const directCandidates = uniquePaths([
    root,
    path.join(root, 'Binaries', 'Win64'),
    path.join(root, 'Brickadia', 'Binaries', 'Win64'),
    path.join(root, 'WindowsServer', 'Brickadia', 'Binaries', 'Win64'),
    path.join(root, 'steamapps', 'common', 'Brickadia Dedicated Server', 'Brickadia', 'Binaries', 'Win64'),
  ]);

  for (const candidate of directCandidates) {
    const found = brickadiaExecutableDirectory(candidate);
    evidence.push(candidate);
    if (found) {
      return brickadiaInstallSearchResult(found, {
        evidence,
        warnings,
        visitedDirectories: evidence.length,
        truncated: false,
      });
    }
  }

  const queue = [{ directory: root, depth: 0 }];
  const visited = new Set();
  let visitedDirectories = 0;
  let truncated = false;

  while (queue.length > 0) {
    const { directory, depth } = queue.shift();
    const resolved = path.resolve(directory);
    const key = resolved.toLowerCase();
    if (visited.has(key)) continue;
    visited.add(key);
    visitedDirectories += 1;
    if (evidence.length < 40) evidence.push(resolved);

    const found = brickadiaExecutableDirectory(resolved);
    if (found) {
      return brickadiaInstallSearchResult(found, {
        evidence,
        warnings,
        visitedDirectories,
        truncated,
      });
    }

    if (visitedDirectories >= BRICKADIA_INSTALL_SEARCH_MAX_DIRECTORIES) {
      truncated = true;
      break;
    }
    if (depth >= BRICKADIA_INSTALL_SEARCH_MAX_DEPTH) continue;

    let entries;
    try {
      entries = fs.readdirSync(resolved, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (BRICKADIA_INSTALL_SEARCH_IGNORED_DIRS.has(entry.name)) continue;
      queue.push({
        directory: path.join(resolved, entry.name),
        depth: depth + 1,
      });
    }
  }

  if (truncated) {
    warnings.push(`Search stopped after ${BRICKADIA_INSTALL_SEARCH_MAX_DIRECTORIES} directories.`);
  }
  return brickadiaInstallSearchResult(null, {
    evidence,
    warnings,
    visitedDirectories,
    truncated,
  });
}

function brickadiaExecutableDirectory(directory) {
  if (!directory) return null;
  try {
    const candidate = path.join(directory, BRICKADIA_SERVER_EXE);
    return fs.existsSync(candidate) ? path.resolve(directory) : null;
  } catch {
    return null;
  }
}

function brickadiaInstallSearchResult(brickadiaWin64, options = {}) {
  return {
    brickadiaWin64,
    warnings: options.warnings || [],
    evidence: options.evidence || [],
    visitedDirectories: options.visitedDirectories || 0,
    truncated: Boolean(options.truncated),
  };
}

function publicBrickadiaInstallSearch(search) {
  return {
    executable: BRICKADIA_SERVER_EXE,
    visitedDirectories: search.visitedDirectories,
    maxDirectories: BRICKADIA_INSTALL_SEARCH_MAX_DIRECTORIES,
    maxDepth: BRICKADIA_INSTALL_SEARCH_MAX_DEPTH,
    truncated: search.truncated,
    evidence: search.evidence.slice(0, 40),
  };
}

function uniquePaths(values) {
  const seen = new Set();
  return values.filter(value => {
    const resolved = path.resolve(value);
    const key = resolved.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function dashboardImportOutputPath(profile, input = {}) {
  if (input.out || input.dashboardImportPath) {
    return path.resolve(input.out || input.dashboardImportPath);
  }
  const profileId = String(profile?.id || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-');
  return path.join(app.getPath('userData'), 'telemetry', `${profileId}-grafana-dashboard-import.json`);
}

function alloyConfigOutputPath(profile, input = {}) {
  if (input.out || input.alloyConfig || input.outputPath) {
    return path.resolve(input.out || input.alloyConfig || input.outputPath);
  }
  if (profile?.paths?.grafanaAlloyConfig) {
    return path.resolve(profile.paths.grafanaAlloyConfig);
  }
  const profileId = String(profile?.id || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-');
  return path.join(app.getPath('userData'), 'telemetry', `${profileId}-bmf.alloy`);
}

function snapshotOptions(profile, input = {}) {
  return {
    root: desktopRoot(input),
    out: troubleshootingSnapshotOutputPath(profile, input),
    maxLogLines: input.maxLogLines || input.maxLines || input.limit,
    maxLogBytes: input.maxLogBytes || input.maxBytes,
    maxFiles: input.maxFiles,
    maxTrafficRecords: input.maxTrafficRecords || input.maxRecords || input.limit,
    maxCommandFiles: input.maxCommandFiles,
    anonymizePlayers: Boolean(input.anonymizePlayers),
    redactPrivateIps: Boolean(input.redactPrivateIps),
  };
}

function troubleshootingSnapshotOutputPath(profile, input = {}) {
  if (input.out || input.snapshotOut || input.snapshotPath) {
    return path.resolve(input.out || input.snapshotOut || input.snapshotPath);
  }
  const profileId = String(profile?.id || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(app.getPath('userData'), 'snapshots', `${profileId}-${stamp}`);
}

function trafficTraceOutputPath(profile, input = {}) {
  if (input.out || input.tracePath || input.outputPath) {
    return path.resolve(input.out || input.tracePath || input.outputPath);
  }
  const profileId = String(profile?.id || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(app.getPath('userData'), 'traffic-traces', `${profileId}-${stamp}.json`);
}

function serviceConfirmForAction(actionId) {
  const value = String(actionId || '').toLowerCase();
  if (value === 'stop' || value === 'stop-stack') return 'stop';
  if (value === 'restart' || value === 'restart-stack') return 'restart';
  return 'start';
}
