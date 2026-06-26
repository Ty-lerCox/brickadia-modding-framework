export interface BmfDesktopApi {
  getBootstrapPlan(input?: unknown): Promise<DesktopPlan>;
  getProfiles(input?: unknown): Promise<DesktopProfileRegistry>;
  saveProfile(input?: unknown): Promise<DesktopProfileRegistry>;
  selectProfile(profileId: string, input?: unknown): Promise<DesktopProfileRegistry>;
  chooseProfilePath(field: DesktopProfilePathField, input?: unknown): Promise<DesktopPathPickerResult>;
  setupProfileFromBrickadiaInstall(input?: unknown): Promise<DesktopProfileSetupResult>;
  getOperationPlan(operationId: string, input?: unknown): Promise<OperationPlan>;
  getOperationTransaction(operationId: string, input?: unknown): Promise<DesktopOperationTransaction>;
  applyOperationTransaction(operationId: string, input?: unknown): Promise<DesktopOperationTransaction>;
  getRollbackTransaction(input?: unknown): Promise<DesktopRollbackTransaction>;
  applyRollbackTransaction(input?: unknown): Promise<DesktopRollbackTransaction>;
  getServiceAction(actionId: string, input?: unknown): Promise<DesktopServiceAction>;
  applyServiceAction(actionId: string, input?: unknown): Promise<DesktopServiceAction>;
  getUpdateCheck(input?: unknown): Promise<DesktopUpdateCheck>;
  getUpdatePlan(input?: unknown): Promise<DesktopUpdatePlan>;
  downloadUpdate(input?: unknown): Promise<DesktopUpdateDownload>;
  getUpdateInstallPlan(input?: unknown): Promise<DesktopUpdateInstallPlan>;
  launchUpdateInstaller(input?: unknown): Promise<DesktopUpdateInstallHandoff>;
  getProfileHealth(input?: unknown): Promise<DesktopHealthReport>;
  getTelemetryPlan(input?: unknown): Promise<DesktopTelemetryPlan>;
  writeTelemetryAlloyConfig(input?: unknown): Promise<DesktopTelemetryAlloyWrite>;
  getDashboardImportPlan(input?: unknown): Promise<DesktopDashboardImportPlan>;
  writeDashboardImportPayload(input?: unknown): Promise<DesktopDashboardImportWrite>;
  uploadDashboardImport(input?: unknown): Promise<DesktopDashboardImportUpload>;
  getTrafficSnapshot(input?: unknown): Promise<DesktopTrafficSnapshot>;
  exportTrafficTrace(input?: unknown): Promise<DesktopTrafficTraceExport>;
  getLogSnapshot(input?: unknown): Promise<DesktopLogSnapshot>;
  getTroubleshootingSnapshot(input?: unknown): Promise<DesktopTroubleshootingSnapshot>;
  writeTroubleshootingSnapshot(input?: unknown): Promise<DesktopTroubleshootingSnapshot>;
  openExternal(url: string): Promise<void>;
}

export interface DesktopWindow extends Window {
  bmfDesktop?: BmfDesktopApi;
}

export type DesktopProfilePathField =
  'brickadiaWin64' |
  'omeggaRuntime' |
  'omeggaStartScript' |
  'bmfRoot' |
  'bmfRuntimeDir' |
  'grafanaAlloyExecutable' |
  'grafanaAlloyConfig';

export interface DesktopPathPickerResult {
  field: DesktopProfilePathField;
  canceled: boolean;
  path: string | null;
}

export interface DesktopProfileSetupResult {
  canceled: boolean;
  status: 'created' | 'updated' | 'not-found' | 'canceled' | string;
  selectedPath: string | null;
  brickadiaWin64: string | null;
  profile: DesktopServerProfile | null;
  registry: DesktopProfileRegistry | null;
  warnings: string[];
  search: {
    executable: string;
    visitedDirectories: number;
    maxDirectories: number;
    maxDepth: number;
    truncated: boolean;
    evidence: string[];
  };
}

export interface OperationPlan {
  operationId: string;
  title: string;
  dryRun: boolean;
  status: string;
  actions: OperationAction[];
  summary: {
    total: number;
    mutating: number;
    readOnly: number;
  };
}

export interface DesktopPlan {
  planId: string;
  title: string;
  dryRun: boolean;
  prerequisites: DesktopPrerequisiteAudit;
  operations: OperationPlan[];
}

export interface DesktopPrerequisiteAudit {
  schemaVersion: number;
  feature: string;
  status: 'ready' | 'attention' | 'blocked' | string;
  collectedAt: string;
  root: string;
  requiredNodeMajorForOmegga: number;
  guardrails: string[];
  summary: {
    total: number;
    required: number;
    healthy: number;
    degraded: number;
    unhealthy: number;
    unknown: number;
    blocked: number;
  };
  checks: DesktopPrerequisiteCheck[];
}

export interface DesktopPrerequisiteCheck {
  id: string;
  title: string;
  component: string;
  required: boolean;
  status: 'healthy' | 'degraded' | 'unhealthy' | 'unknown' | string;
  summary: string;
  evidence: string[];
  nextAction: string | null;
  remediation: {
    kind: string;
    profileField?: string;
    operationId?: string;
    command?: string;
  } | null;
}

export interface DesktopProfileRegistry {
  schemaVersion: number;
  storePath: string;
  selectedProfileId: string | null;
  profiles: DesktopServerProfile[];
  summary: {
    total: number;
    selectedProfileId: string | null;
    selectedExists: boolean;
  };
  guardrails: string[];
}

export interface DesktopServerProfile {
  id: string;
  name: string;
  backend: string;
  backendConfig: Record<string, never>;
  ports: {
    brickadia: number;
    omeggaWeb: number;
    bmfSocket: number;
    alloyReady: number;
  };
  paths: {
    brickadiaWin64: string | null;
    omeggaRuntime: string | null;
    omeggaStartScript: string | null;
    bmfRoot: string | null;
    bmfRuntimeDir: string | null;
    grafanaAlloyExecutable: string | null;
    grafanaAlloyConfig: string | null;
  };
  telemetry: {
    enabled: boolean;
    frameTelemetryEnabled: boolean;
    environment: string;
    instance: string;
    dashboardUrl: string | null;
  };
}

export interface OperationAction {
  id: string;
  title: string;
  component: string;
  kind: string;
  mode: string;
  healthCheck: string | null;
}

export interface DesktopOperationTransaction {
  transactionId: string;
  operationId: string;
  title: string;
  dryRun: boolean;
  status: 'planned' | 'ready' | 'blocked' | 'applied' | 'failed';
  journalPath: string;
  backupRoot: string;
  guardrails: string[];
  finishedAt?: string;
  summary: {
    total: number;
    mutating: number;
    readOnly: number;
    ready: number;
    blocked: number;
    skipped: number;
    backupsRequired: number;
    unsupported: number;
  };
  steps: DesktopTransactionStep[];
  applied?: DesktopAppliedTransactionStep[];
  errors?: Array<{
    stepId: string;
    message: string;
  }>;
  unsupportedActions: Array<{
    actionId: string;
    title: string;
    component: string;
    kind: string;
    reason: string;
  }>;
  rollback: Array<{
    stepId?: string;
    action: string;
    path: string;
    backupPath?: string;
  }>;
}

export interface DesktopRollbackTransaction {
  rollbackId: string;
  sourceTransactionId: string | null;
  operationId: string | null;
  title: string;
  dryRun: boolean;
  status: 'planned' | 'ready' | 'blocked' | 'rolled-back' | 'failed';
  createdAt: string;
  finishedAt?: string;
  sourceJournalPath: string;
  journalPath: string;
  backupRoot: string;
  sourceBackupRoot: string | null;
  allowedTargetRoots: string[];
  guardrails: string[];
  summary: {
    total: number;
    ready: number;
    blocked: number;
    restores: number;
    removals: number;
    backupsRequired: number;
  };
  steps: DesktopRollbackStep[];
  applied?: DesktopAppliedRollbackStep[];
  errors?: Array<{
    stepId: string;
    message: string;
  }>;
}

export interface DesktopRollbackStep {
  id: string;
  sourceStepId: string | null;
  action: string;
  kind: 'rollback';
  mutates: boolean;
  targetPath: string | null;
  backupPath?: string | null;
  status: 'ready' | 'blocked';
  blockedReason: string | null;
  targetExists: boolean;
  backupRequired: boolean;
  guardrails: string[];
  result?: string;
}

export interface DesktopAppliedRollbackStep extends DesktopRollbackStep {
  applied: boolean;
  result: 'restored' | 'removed' | 'noop' | 'failed' | string;
  rollbackBackupPath?: string | null;
  sha256?: string | null;
  error?: string;
}

export interface DesktopServiceAction {
  actionRunId: string;
  actionId: string;
  title: string;
  description: string;
  dryRun: boolean;
  status: 'planned' | 'ready' | 'blocked' | 'started' | 'stopped' | 'already-stopped' | 'restarted' | 'failed';
  service: string;
  backend: string;
  command: {
    executable: string | null;
    args: string[];
    cwd: string | null;
    startScript: string | null;
    display: string;
  };
  paths: {
    root: string;
    actionRoot: string;
    omeggaRuntime: string | null;
    startScript: string | null;
    alloyExecutable: string | null;
    alloyConfig: string | null;
    alloyStoragePath: string | null;
    logPath: string;
    journalPath: string;
    pidPath: string;
  };
  readiness: {
    status: 'ready' | 'blocked' | 'degraded' | 'unknown';
    summary: string;
  };
  blockers: Array<{
    id: string;
    summary: string;
    nextAction: string | null;
  }>;
  warnings: Array<{
    id: string;
    summary: string;
    nextAction: string | null;
  }>;
  summary: {
    total: number;
    mutating: number;
    readOnly: number;
    ready: number;
    blocked: number;
    warnings: number;
  };
  guardrails: string[];
  startedAt?: string;
  stoppedAt?: string;
  restartedAt?: string;
  finishedAt?: string;
  process?: {
    pid: number;
    detached: boolean;
    pidPath: string;
  } | null;
  ownedProcess?: {
    pidFileExists: boolean;
    pid: number | null;
    status: 'missing' | 'invalid' | 'running' | 'not-running' | 'unknown' | string;
    verified: boolean;
    summary: string;
    pidPath?: string;
  };
  stop?: {
    pid: number | null;
    status: 'stopped' | 'already-stopped' | 'failed' | string;
    signal?: string | null;
    message?: string;
    pidFileRemoved?: boolean;
  };
  journal?: {
    path: string;
    written: boolean;
    reason?: string;
  };
  log?: {
    path: string;
  };
  errors?: Array<{
    message: string;
  }>;
}

export interface DesktopUpdateCheck {
  schemaVersion: number;
  feature: 'desktop.update.check';
  status: 'update-available' | 'up-to-date' | 'ahead' | 'invalid-catalog' | 'catalog-missing';
  root: string;
  catalogPath: string;
  currentVersion: string;
  releaseChannel: string;
  updateAvailable: boolean;
  comparison: 'newer' | 'same' | 'older' | 'unknown';
  mutates: boolean;
  downloads: boolean;
  startsOrStopsServices: boolean;
  latest: {
    version: string;
    channel: string;
    publishedAt: string | null;
    artifact: {
      fileName: string | null;
      url: string | null;
      bytes: number | null;
      sha256: string | null;
    } | null;
    supportedBrickadiaBuild: string | null;
    bmfRuntimeVersion: string | null;
    omeggaRuntimeVersionOrCommit: string | null;
    ue4ssBundleId: string | null;
    dashboardVersion: string | null;
    minimumWindowsVersion: string | null;
  } | null;
  validation: {
    ok: boolean;
    errors: string[];
    warnings: string[];
    releaseCount?: number;
    latestVersion?: string | null;
  };
  artifactVerification: {
    status: 'not-checked' | 'missing' | 'verified' | 'mismatch';
    reason?: string;
    path?: string;
    expectedSha256?: string;
    actualSha256?: string;
    bytes?: number;
  };
  guardrails: string[];
  nextActions: string[];
}

export interface DesktopUpdatePlan {
  schemaVersion: number;
  feature: 'desktop.update.download.plan' | 'desktop.update.download';
  status: 'ready' | 'blocked' | 'downloaded' | 'failed';
  dryRun: boolean;
  root: string;
  catalogPath: string;
  downloadDir: string;
  currentVersion: string;
  latest: DesktopUpdateCheck['latest'];
  updateCheck: DesktopUpdateCheck;
  artifact: {
    fileName: string;
    url: string | null;
    outputPath: string;
    bytes: number | null;
    sha256: string | null;
  } | null;
  blockers: Array<{
    id: string;
    summary: string;
  }>;
  steps: DesktopUpdateStep[];
  guardrails: string[];
  mutates: boolean;
  downloads: boolean;
  installs: boolean;
  startsOrStopsServices: boolean;
}

export interface DesktopUpdateDownload extends DesktopUpdatePlan {
  feature: 'desktop.update.download';
  status: 'downloaded' | 'failed' | 'blocked';
  confirmed: boolean;
  downloaded: boolean;
  response?: {
    ok: boolean;
    status: number;
    statusText: string;
  };
  verification: {
    status: 'not-checked' | 'verified' | 'mismatch';
    reason?: string;
    path?: string;
    expectedSha256?: string;
    actualSha256?: string;
    bytes?: number;
  };
}

export interface DesktopUpdateStep {
  id: string;
  title: string;
  status: 'ready' | 'blocked';
  mutates: boolean;
  downloadUrl?: string | null;
  outputPath?: string | null;
  expectedSha256?: string | null;
  summary: string;
}

export interface DesktopUpdateInstallPlan {
  schemaVersion: number;
  feature: 'desktop.update.install.plan' | 'desktop.update.install.handoff';
  status: 'ready' | 'blocked' | 'handoff-started' | 'failed';
  dryRun: boolean;
  root: string;
  catalogPath: string;
  currentVersion: string;
  latest: DesktopUpdateCheck['latest'];
  updateCheck: DesktopUpdateCheck;
  installer: {
    path: string;
    expectedSha256: string | null;
    verification: {
      status: 'missing' | 'verified' | 'mismatch';
      path: string | null;
      expectedSha256: string | null;
      actualSha256?: string;
      bytes?: number;
    };
  };
  command: {
    executable: string;
    args: string[];
    display: string;
  };
  blockers: Array<{
    id: string;
    summary: string;
  }>;
  steps: DesktopUpdateStep[];
  guardrails: string[];
  mutates: boolean;
  downloads: boolean;
  installs: boolean;
  startsOrStopsServices: boolean;
}

export interface DesktopUpdateInstallHandoff extends DesktopUpdateInstallPlan {
  feature: 'desktop.update.install.handoff';
  confirmed: boolean;
  launched: boolean;
  launch: {
    status: 'launched' | 'failed' | 'not-started';
    reason?: string;
    pid?: number;
    command?: string;
  };
}

export interface DesktopTransactionStep {
  id: string;
  actionId: string;
  title: string;
  kind: string;
  mutates: boolean;
  sourcePath?: string;
  targetPath?: string;
  status: 'ready' | 'blocked' | 'skipped';
  blockedReason: string | null;
  targetExists: boolean;
  backupRequired: boolean;
  contentSha256?: string;
}

export interface DesktopAppliedTransactionStep extends DesktopTransactionStep {
  applied: boolean;
  result: 'applied' | 'skipped' | 'failed' | string;
  reason?: string;
  error?: string;
  backupPath?: string | null;
  sha256?: string | null;
}

export interface DesktopHealthReport {
  collectedAt: string;
  health: {
    status: 'healthy' | 'degraded' | 'unhealthy' | 'unknown';
    summary: Record<string, number>;
    checks: DesktopHealthCheck[];
  };
  serviceDiagnostics?: DesktopServiceDiagnostics;
  logSources: DesktopLogSource[];
  guardrails: string[];
}

export interface DesktopHealthCheck {
  id: string;
  component: string;
  severity: string;
  status: 'healthy' | 'degraded' | 'unhealthy' | 'unknown';
  summary: string;
  evidence: string[];
  nextAction: string | null;
}

export interface DesktopLogSource {
  id: string;
  component: string;
  path: string;
  exists: boolean;
}

export interface DesktopLogSnapshot {
  collectedAt: string;
  records: DesktopLogRecord[];
  summary: DesktopLogSummary;
  sources: DesktopLogSnapshotSource[];
  guardrails: string[];
}

export interface DesktopLogSummary {
  retained: number;
  dropped: number;
  sources: number;
  existingSources: number;
  parseErrors: number;
  redactions: number;
  truncatedSources: number;
}

export interface DesktopLogRecord {
  id: string;
  timestamp: string;
  sourceId: string;
  component: string;
  severity: 'info' | 'warning' | 'error' | 'debug' | string;
  message: string;
  lineNumber: number | null;
  payload?: unknown;
  redactions: number;
}

export interface DesktopLogSnapshotSource {
  id: string;
  component: string;
  path: string | null;
  kind: string;
  exists: boolean;
  bytes: number;
  lines: number;
  parseErrors: number;
  redactions: number;
  truncated: boolean;
  mtime: string | null;
  error: string | null;
}

export interface DesktopTroubleshootingSnapshot {
  schemaVersion: number;
  feature: 'troubleshooting.snapshot';
  status: 'planned' | 'written';
  dryRun: boolean;
  snapshotId: string;
  createdAt: string;
  root: string;
  summary: {
    healthStatus: string;
    healthChecks: number;
    logRecords: number;
    trafficRecords: number;
    copiedFiles: number;
    copiedLogs: number;
    doctorStatus: string | null;
  };
  files: {
    snapshot: string;
    profile: string;
    health: string;
    logs: string;
    traffic: string;
    manifest: string;
    doctor: string | null;
    readme: string;
  };
  copiedFiles: DesktopTroubleshootingSnapshotFile[];
  copiedLogs: DesktopTroubleshootingSnapshotFile[];
  limits: {
    maxLogBytes: number;
    maxFiles: number;
    maxLogLines: number;
    maxTrafficRecords: number;
  };
  guardrails: string[];
}

export interface DesktopTroubleshootingSnapshotFile {
  source: string;
  snapshotPath: string;
  absoluteSnapshotPath: string;
  mode?: string;
  bytes?: number;
  lines?: number;
}

export interface DesktopServiceDiagnostics {
  backend: string;
  startReadiness: {
    status: 'ready' | 'blocked' | 'degraded' | 'unknown';
    summary: string;
  };
  ports: DesktopPortDiagnostic[];
}

export interface DesktopPortDiagnostic {
  id: string;
  label: string;
  component: string;
  protocol: string;
  port: number;
  status: 'available' | 'in-use' | 'not-configured' | 'unknown';
  summary: string;
  ownerSummary: string | null;
  startImpact: string;
}

export interface DesktopTelemetryPlan {
  status: 'ready' | 'needs-secrets' | 'disabled';
  labels: Record<string, string>;
  alloy: {
    outputPath: string | null;
    metricsUrl: string;
    readyUrl: string;
    scrapeInterval: string;
    configSha256: string;
    missingSecretRefs: string[];
    secretStatus: Array<{
      ref: string;
      configured: boolean;
    }>;
  };
  dashboard: {
    dashboardUid: string;
    dashboardVersion: string;
    dashboardUrl: string | null;
    endpoint: string;
  };
}

export interface DesktopTelemetryAlloyWrite {
  schemaVersion: number;
  feature: 'telemetry.alloy.write';
  status: 'planned' | 'written';
  dryRun: boolean;
  outputPath: string;
  bytes: number;
  sha256: string;
  missingSecretRefs: string[];
  guardrails: string[];
}

export interface DesktopDashboardImportPlan {
  status: 'ready' | 'needs-secrets' | 'needs-grafana-url' | 'disabled';
  dashboard: {
    dashboardUid: string;
    dashboardVersion: string;
    dashboardUrl: string | null;
    endpoint: string;
    folderUid: string;
    prometheusDatasourceUid: string;
  };
  request: {
    method: string;
    apiPath: string;
    url: string | null;
    outputPath: string | null;
    contentType: string;
    tokenEnvRef: string;
    secretStatus: Array<{
      field: string;
      ref: string;
      configured: boolean;
    }>;
    missingSecretRefs: string[];
    commands: {
      powershell: string;
      bash: string;
    };
  };
  payloadSummary: {
    dashboardUid: string;
    dashboardVersion: string;
    folderUid: string;
    prometheusDatasourceUid: string;
    labels: Record<string, string>;
    bytes: number;
    sha256: string;
  };
  guardrails: string[];
}

export interface DesktopDashboardImportWrite {
  status: 'planned' | 'written';
  dryRun: boolean;
  outputPath: string;
  bytes: number;
  sha256: string;
  dashboard: {
    dashboardUid: string;
    dashboardVersion: string;
    dashboardUrl: string | null;
    endpoint: string;
    folderUid: string;
    prometheusDatasourceUid: string;
  };
  request: DesktopDashboardImportPlan['request'];
  guardrails: string[];
}

export interface DesktopDashboardImportUpload {
  status: 'uploaded' | 'failed' | 'blocked';
  confirmed: boolean;
  dashboard: {
    dashboardUid: string;
    dashboardVersion: string | number;
    dashboardUrl: string | null;
    endpoint: string;
    folderUid: string;
    prometheusDatasourceUid: string;
  };
  request: {
    method: string;
    apiPath: string;
    url: string | null;
    contentType: string;
    tokenEnvRef: string;
    payloadSha256: string;
    payloadBytes: number;
    timeoutMs: number | null;
  };
  response: {
    ok: boolean;
    status: number;
    statusText: string;
    dashboardUid: string | null;
    dashboardUrl: string | null;
    version: string | number | null;
    slug: string | null;
    message: string;
    bodySnippet: string;
  } | null;
  errors: string[];
  guardrails: string[];
}

export interface DesktopTrafficSnapshot {
  collectedAt: string;
  records: DesktopTrafficRecord[];
  summary: DesktopTrafficSummary;
  sources: DesktopTrafficSource[];
  guardrails: string[];
}

export interface DesktopTrafficTraceExport {
  schemaVersion: number;
  feature: 'traffic.trace.export';
  status: 'planned' | 'written';
  dryRun: boolean;
  confirmed: boolean;
  createdAt: string;
  outputPath: string;
  bytes: number;
  sha256: string;
  summary: DesktopTrafficSummary;
  snapshot: DesktopTrafficSnapshot;
  guardrails: string[];
}

export interface DesktopTrafficSummary {
  retained: number;
  dropped: number;
  sources: number;
  parseErrors: number;
  redactions: number;
  truncatedSources: number;
}

export interface DesktopTrafficRecord {
  id?: string;
  timestamp: string;
  type: string;
  event?: string;
  command?: string;
  source?: string;
  transport?: string;
  status?: string;
  payload?: unknown;
  durationMs?: number;
  consumer?: string;
  redactions?: number;
}

export interface DesktopTrafficSource {
  id: string;
  path: string | null;
  exists: boolean;
  bytes: number;
  records: number;
  socketRecords?: number;
  parseErrors: number;
  truncated: boolean;
  transports: string[];
  mtime: string | null;
  error: string | null;
  status?: string;
  connects?: number;
  disconnects?: number;
}
