import { CommonModule } from '@angular/common';
import { Component, OnDestroy, OnInit, computed, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatBadgeModule } from '@angular/material/badge';
import { MatButtonModule } from '@angular/material/button';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatCardModule } from '@angular/material/card';
import { MatChipsModule } from '@angular/material/chips';
import { MatDividerModule } from '@angular/material/divider';
import { MatExpansionModule } from '@angular/material/expansion';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatListModule } from '@angular/material/list';
import { MatProgressBarModule } from '@angular/material/progress-bar';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatTableModule } from '@angular/material/table';
import { MatTabsModule } from '@angular/material/tabs';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatTooltipModule } from '@angular/material/tooltip';
import {
  DesktopHealthCheck,
  DesktopHealthReport,
  DesktopDashboardImportPlan,
  DesktopDashboardImportUpload,
  DesktopDashboardImportWrite,
  DesktopLogRecord,
  DesktopLogSnapshot,
  DesktopLogSnapshotSource,
  DesktopLogSource,
  DesktopOperationTransaction,
  DesktopPrerequisiteCheck,
  DesktopProfilePathField,
  DesktopProfileSetupResult,
  DesktopPortDiagnostic,
  DesktopPlan,
  DesktopProfileRegistry,
  DesktopRollbackTransaction,
  DesktopServerProfile,
  DesktopServiceAction,
  DesktopTelemetryAlloyWrite,
  DesktopTelemetryPlan,
  DesktopTrafficSnapshot,
  DesktopTrafficSource,
  DesktopTrafficTraceExport,
  DesktopTroubleshootingSnapshot,
  DesktopTroubleshootingSnapshotFile,
  DesktopUpdateCheck,
  DesktopUpdateDownload,
  DesktopUpdateInstallHandoff,
  DesktopUpdateInstallPlan,
  DesktopUpdatePlan,
  DesktopWindow,
  OperationAction,
  OperationPlan,
} from './preload-api';

interface HealthCheck {
  id: string;
  component: string;
  severity?: string;
  status: 'healthy' | 'degraded' | 'unhealthy' | 'unknown';
  summary: string;
  evidence?: string[];
  nextAction?: string | null;
}

interface EventRecord {
  rowId: string;
  timestamp: string;
  type: string;
  event: string;
  command: string;
  transport: string;
  status: string;
  source: string;
  consumer: string;
  durationMs: number | null;
  redactions: number;
  payload: unknown;
}

interface ProfileDraftInput {
  id: string | null;
  name: string;
  backend: string;
  backendConfig: Record<string, never>;
  paths: {
    brickadiaWin64: string | null;
    omeggaRuntime: string | null;
    omeggaStartScript: string | null;
    bmfRoot: string | null;
    bmfRuntimeDir: string | null;
    grafanaAlloyExecutable: string | null;
    grafanaAlloyConfig: string | null;
  };
  ports: {
    brickadia: number;
    omeggaWeb: number;
    bmfSocket: number;
    alloyReady: number;
  };
  telemetry: {
    enabled: boolean;
    frameTelemetryEnabled: boolean;
    environment: string;
    instance: string;
    dashboardUrl: string | null;
  };
}

type AppMode = 'easy' | 'advanced';
type HealthStatus = HealthCheck['status'];
type EasyServiceVisibility = 'always' | 'managed-stack' | 'socket' | 'frame-telemetry' | 'telemetry' | 'dashboard';

interface EasyServiceDefinition {
  id: string;
  name: string;
  group: string;
  icon: string;
  fallbackSummary: string;
  visibility?: EasyServiceVisibility;
}

interface EasyServiceRow {
  id: string;
  name: string;
  group: string;
  icon: string;
  status: HealthStatus;
  summary: string;
  detail: string;
  evidence: string[];
  nextAction: string | null;
  severity: string;
  source: 'health' | 'port';
}

const EASY_HEALTH_RANK: Record<HealthStatus, number> = {
  healthy: 0,
  unknown: 1,
  degraded: 2,
  unhealthy: 3,
};

const EASY_SERVICE_DEFINITIONS: EasyServiceDefinition[] = [
  {
    id: 'brickadia-files',
    name: 'Brickadia server files',
    group: 'Core',
    icon: 'dns',
    fallbackSummary: 'Brickadia path has not been checked yet.',
  },
  {
    id: 'omegga-running',
    name: 'Omegga runtime',
    group: 'Core',
    icon: 'terminal',
    fallbackSummary: 'Omegga runtime state has not been checked yet.',
    visibility: 'managed-stack',
  },
  {
    id: 'ue4ss-enabled',
    name: 'UE4SS + OmeggaBridge',
    group: 'Core',
    icon: 'extension',
    fallbackSummary: 'UE4SS and bridge files have not been checked yet.',
  },
  {
    id: 'bmf-status-fresh',
    name: 'BMF runtime',
    group: 'Core',
    icon: 'deployed_code',
    fallbackSummary: 'BMF runtime status has not been checked yet.',
  },
  {
    id: 'bmf-socket-connected',
    name: 'BMFSocket transport',
    group: 'Optional',
    icon: 'settings_ethernet',
    fallbackSummary: 'Socket transport has not been checked yet.',
    visibility: 'socket',
  },
  {
    id: 'frame-telemetry-fresh',
    name: 'BMFFrameTelemetry',
    group: 'Optional',
    icon: 'speed',
    fallbackSummary: 'Frame telemetry has not been checked yet.',
    visibility: 'frame-telemetry',
  },
  {
    id: 'metrics-endpoint',
    name: 'Omegga metrics',
    group: 'Telemetry',
    icon: 'monitoring',
    fallbackSummary: 'Metrics endpoint has not been checked yet.',
    visibility: 'telemetry',
  },
  {
    id: 'alloy-ready',
    name: 'Grafana Alloy',
    group: 'Telemetry',
    icon: 'hub',
    fallbackSummary: 'Alloy readiness has not been checked yet.',
    visibility: 'telemetry',
  },
  {
    id: 'dashboard-imported',
    name: 'Grafana dashboard',
    group: 'Telemetry',
    icon: 'dashboard',
    fallbackSummary: 'Dashboard setup has not been checked yet.',
    visibility: 'dashboard',
  },
];

@Component({
  selector: 'bmf-root',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    MatBadgeModule,
    MatButtonModule,
    MatButtonToggleModule,
    MatCardModule,
    MatChipsModule,
    MatDividerModule,
    MatExpansionModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
    MatListModule,
    MatProgressBarModule,
    MatSelectModule,
    MatSlideToggleModule,
    MatTableModule,
    MatTabsModule,
    MatToolbarModule,
    MatTooltipModule,
  ],
  templateUrl: './app.component.html',
  styleUrl: './app.component.scss',
})
export class AppComponent implements OnInit, OnDestroy {
  readonly appMode = signal<AppMode>('easy');
  readonly activeProfileId = signal<string | null>(null);
  readonly profileName = signal('Local Server');
  readonly profileBackend = signal('local-process');
  readonly brickadiaWin64Path = signal('');
  readonly omeggaRuntimePath = signal('');
  readonly omeggaStartScriptPath = signal('');
  readonly bmfRootPath = signal('');
  readonly bmfRuntimeDirPath = signal('');
  readonly grafanaAlloyExecutablePath = signal('');
  readonly grafanaAlloyConfigPath = signal('');
  readonly brickadiaPort = signal('7777');
  readonly omeggaWebPort = signal('8080');
  readonly bmfSocketPort = signal('0');
  readonly alloyReadyPort = signal('12345');
  readonly telemetryEnvironment = signal('local');
  readonly telemetryInstance = signal('local-server');
  readonly dashboardUrl = signal('');
  readonly frameTelemetryEnabled = signal(false);
  readonly telemetryEnabled = signal(false);
  readonly profileFormDirty = signal(false);
  readonly selectedOperation = signal<OperationPlan | null>(null);
  readonly profileRegistry = signal<DesktopProfileRegistry | null>(null);
  readonly brickadiaSetupResult = signal<DesktopProfileSetupResult | null>(null);
  readonly brickadiaSetupInFlight = signal(false);
  readonly easyHealthRefreshInFlight = signal(false);
  readonly easyHealthRefreshError = signal('');
  readonly easyActionInFlight = signal<string | null>(null);
  readonly easyActionError = signal('');
  readonly bootstrapPlan = signal<DesktopPlan | null>(null);
  readonly operationTransaction = signal<DesktopOperationTransaction | null>(null);
  readonly operationRollback = signal<DesktopRollbackTransaction | null>(null);
  readonly healthReport = signal<DesktopHealthReport | null>(null);
  readonly serviceAction = signal<DesktopServiceAction | null>(null);
  readonly updateCheck = signal<DesktopUpdateCheck | null>(null);
  readonly updatePlan = signal<DesktopUpdatePlan | null>(null);
  readonly updateDownload = signal<DesktopUpdateDownload | null>(null);
  readonly updateInstallPlan = signal<DesktopUpdateInstallPlan | null>(null);
  readonly updateInstallHandoff = signal<DesktopUpdateInstallHandoff | null>(null);
  readonly telemetryPlan = signal<DesktopTelemetryPlan | null>(null);
  readonly telemetryAlloyWrite = signal<DesktopTelemetryAlloyWrite | null>(null);
  readonly dashboardImportPlan = signal<DesktopDashboardImportPlan | null>(null);
  readonly dashboardImportWrite = signal<DesktopDashboardImportWrite | null>(null);
  readonly dashboardImportUpload = signal<DesktopDashboardImportUpload | null>(null);
  readonly trafficSnapshot = signal<DesktopTrafficSnapshot | null>(null);
  readonly trafficTraceExport = signal<DesktopTrafficTraceExport | null>(null);
  readonly logSnapshot = signal<DesktopLogSnapshot | null>(null);
  readonly troubleshootingSnapshot = signal<DesktopTroubleshootingSnapshot | null>(null);
  readonly desktopInitialized = signal(false);
  readonly trafficPaused = signal(false);
  readonly trafficLiveEnabled = signal(true);
  readonly trafficRefreshInFlight = signal(false);
  readonly trafficLastRefresh = signal('');
  readonly trafficRefreshError = signal('');
  readonly selectedTrafficRecordId = signal<string | null>(null);
  readonly trafficFilterText = signal('');
  readonly trafficTransportFilter = signal('all');
  readonly trafficStatusFilter = signal('all');
  readonly trafficSourceFilter = signal('all');
  readonly trafficPluginFilter = signal('');
  readonly trafficPageIndex = signal(0);
  readonly runtimeLogPageIndex = signal(0);
  readonly logSources = signal<DesktopLogSource[]>([]);
  readonly logSnapshotSources = signal<DesktopLogSnapshotSource[]>([]);
  readonly trafficSources = signal<DesktopTrafficSource[]>([]);
  readonly logLines = signal([
    'BMF Desktop initialized',
    'Loaded local dry-run operation contract',
    'No server process has been launched',
  ]);

  readonly healthChecks = signal<HealthCheck[]>([
    {
      id: 'brickadia-files',
      component: 'Brickadia',
      status: 'unknown',
      summary: 'Profile path not selected',
    },
    {
      id: 'omegga-running',
      component: 'Omegga',
      status: 'unknown',
      summary: 'Runtime not started',
    },
    {
      id: 'bmf-status-fresh',
      component: 'BMF',
      status: 'unknown',
      summary: 'No runtime status file observed',
    },
    {
      id: 'alloy-ready',
      component: 'Alloy',
      status: 'degraded',
      summary: 'Telemetry setup is pending',
    },
  ]);

  readonly eventRecords = signal<EventRecord[]>([]);
  readonly profileBackendOptions = [
    { value: 'local-process', label: 'Local Windows process' },
  ];
  readonly storedProfiles = computed<DesktopServerProfile[]>(() => this.profileRegistry()?.profiles ?? []);
  readonly profileDraft = computed<ProfileDraftInput>(() => this.formProfileInput());
  readonly configuredPathCount = computed(() => Object.values(this.profileDraft().paths).filter(Boolean).length);
  readonly easyProfileSetupNeeded = computed(() => !this.profileDraft().paths.brickadiaWin64);
  readonly easyProfileSetupStatus = computed(() => {
    const result = this.brickadiaSetupResult();
    const brickadiaPath = this.profileDraft().paths.brickadiaWin64;
    if (brickadiaPath) return brickadiaPath;
    if (result?.status === 'not-found') return result.warnings[0] || 'Server executable was not found.';
    if (result?.status === 'canceled') return 'Brickadia folder selection was canceled.';
    return 'Select the Brickadia Dedicated Server install folder.';
  });
  readonly easyProfileSetupWarning = computed(() => {
    const result = this.brickadiaSetupResult();
    if (!result || result.status !== 'not-found') return null;
    return result.warnings[1] || null;
  });
  readonly pendingEasyHealthChecks = computed<HealthCheck[]>(() => {
    const brickadiaPath = this.profileDraft().paths.brickadiaWin64;
    if (!brickadiaPath) return [];
    return [
      {
        id: 'brickadia-files',
        component: 'Brickadia',
        severity: 'informational',
        status: 'unknown',
        summary: 'Health check pending for the selected Brickadia folder.',
        evidence: [brickadiaPath],
        nextAction: null,
      },
      {
        id: 'ue4ss-enabled',
        component: 'BMF',
        severity: 'informational',
        status: 'unknown',
        summary: 'UE4SS and bridge files have not been checked yet.',
        evidence: [],
        nextAction: null,
      },
      {
        id: 'bmf-status-fresh',
        component: 'BMF',
        severity: 'informational',
        status: 'unknown',
        summary: 'BMF runtime status has not been checked yet.',
        evidence: [],
        nextAction: null,
      },
    ];
  });

  readonly displayedEventColumns = ['timestamp', 'type', 'event', 'transport', 'status', 'source', 'consumer'];
  readonly pageSize = 10;
  readonly prerequisiteChecks = computed<DesktopPrerequisiteCheck[]>(() => this.bootstrapPlan()?.prerequisites?.checks ?? []);
  readonly prerequisiteSummary = computed(() => this.bootstrapPlan()?.prerequisites?.summary ?? {
    total: 0,
    required: 0,
    healthy: 0,
    degraded: 0,
    unhealthy: 0,
    unknown: 0,
    blocked: 0,
  });
  readonly planActions = computed<OperationAction[]>(() => this.selectedOperation()?.actions ?? []);
  readonly transactionSummary = computed(() => this.operationTransaction()?.summary ?? {
    total: 0,
    mutating: 0,
    readOnly: 0,
    ready: 0,
    blocked: 0,
    skipped: 0,
    backupsRequired: 0,
    unsupported: 0,
  });
  readonly transactionAppliedSummary = computed(() => {
    const applied = this.operationTransaction()?.applied ?? [];
    return {
      total: applied.length,
      applied: applied.filter(step => step.applied).length,
      skipped: applied.filter(step => step.result === 'skipped').length,
      failed: applied.filter(step => step.result === 'failed').length,
    };
  });
  readonly transactionCanApply = computed(() => {
    const transaction = this.operationTransaction();
    return Boolean(
      transaction &&
      transaction.dryRun &&
      transaction.status === 'planned' &&
      transaction.summary.ready > 0 &&
      transaction.summary.blocked === 0,
    );
  });
  readonly rollbackSummary = computed(() => this.operationRollback()?.summary ?? {
    total: 0,
    ready: 0,
    blocked: 0,
    restores: 0,
    removals: 0,
    backupsRequired: 0,
  });
  readonly rollbackCanPreview = computed(() => {
    const transaction = this.operationTransaction();
    return Boolean(
      transaction?.journalPath &&
      ['applied', 'failed', 'blocked'].includes(transaction.status),
    );
  });
  readonly rollbackCanApply = computed(() => {
    const rollback = this.operationRollback();
    return Boolean(
      rollback &&
      rollback.dryRun &&
      rollback.status === 'planned' &&
      rollback.summary.ready > 0 &&
      rollback.summary.blocked === 0,
    );
  });
  readonly healthStatus = computed(() => this.healthReport()?.health.status ?? 'unknown');
  readonly easyHealthStatus = computed<HealthStatus>(() => {
    const rows = this.easyServiceRows();
    if (rows.length === 0) return 'unknown';
    return rows.reduce<HealthStatus>((current, row) => {
      return EASY_HEALTH_RANK[row.status] > EASY_HEALTH_RANK[current] ? row.status : current;
    }, 'healthy');
  });
  readonly easyServiceRows = computed<EasyServiceRow[]>(() => {
    if (this.easyProfileSetupNeeded()) return [];
    const healthChecks = this.healthReport() ? this.healthChecks() : this.pendingEasyHealthChecks();
    const checksById = new Map(healthChecks.map(check => [check.id, check]));
    const rows = EASY_SERVICE_DEFINITIONS.filter(definition =>
      this.easyServiceDefinitionVisible(definition, checksById.get(definition.id)),
    ).map(definition => {
      const check = checksById.get(definition.id);
      return {
        id: definition.id,
        name: definition.name,
        group: definition.group,
        icon: definition.icon,
        status: check?.status ?? 'unknown',
        summary: check?.summary ?? definition.fallbackSummary,
        detail: check?.evidence?.[0] || check?.nextAction || 'No evidence collected yet.',
        evidence: check?.evidence ?? [],
        nextAction: check?.nextAction ?? null,
        severity: check?.severity ?? 'unknown',
        source: 'health' as const,
      };
    });
    const portRows = this.portDiagnostics().filter(port => this.easyPortVisible(port)).map(port => ({
      id: `port-${port.id}`,
      name: port.label,
      group: 'Ports',
      icon: this.portStatusIcon(port.status),
      status: this.portStatusToHealth(port),
      summary: port.summary,
      detail: this.portDetail(port),
      evidence: [this.portDetail(port)].filter(Boolean),
      nextAction: port.startImpact === 'none' ? null : 'start-stack',
      severity: port.startImpact === 'none' ? 'informational' : port.startImpact,
      source: 'port' as const,
    }));
    return [...rows, ...portRows];
  });
  readonly easyServiceSummary = computed(() => {
    return this.easyServiceRows().reduce(
      (summary, row) => {
        summary[row.status] += 1;
        return summary;
      },
      { healthy: 0, degraded: 0, unhealthy: 0, unknown: 0 },
    );
  });
  readonly easyLastChecked = computed(() => this.healthReport()?.collectedAt ?? 'pending');
  readonly serviceDiagnostics = computed(() => this.healthReport()?.serviceDiagnostics ?? null);
  readonly serviceCanStart = computed(() => this.canApplyServiceAction('start-stack'));
  readonly serviceCanStop = computed(() => this.canApplyServiceAction('stop-stack'));
  readonly serviceCanRestart = computed(() => this.canApplyServiceAction('restart-stack'));
  readonly alloyCanStart = computed(() => this.canApplyServiceAction('start-alloy'));
  readonly alloyCanStop = computed(() => this.canApplyServiceAction('stop-alloy'));
  readonly alloyCanRestart = computed(() => this.canApplyServiceAction('restart-alloy'));
  readonly updateStatus = computed(() => this.updateCheck()?.status ?? 'not checked');
  readonly updatePlanStatus = computed(() => this.updatePlan()?.status ?? 'not planned');
  readonly updateDownloadStatus = computed(() => this.updateDownload()?.status ?? 'not downloaded');
  readonly updateInstallStatus = computed(() => this.updateInstallHandoff()?.status || this.updateInstallPlan()?.status || 'not planned');
  readonly updateArtifactStatus = computed(() => this.updateCheck()?.artifactVerification?.status ?? 'not checked');
  readonly portDiagnostics = computed<DesktopPortDiagnostic[]>(() => this.serviceDiagnostics()?.ports ?? []);
  readonly startReadiness = computed(() => this.serviceDiagnostics()?.startReadiness ?? {
    status: 'unknown',
    summary: 'Port diagnostics have not been loaded.',
  });
  readonly telemetryStatus = computed(() => this.telemetryPlan()?.status ?? 'unknown');
  readonly telemetryAlloyWriteStatus = computed(() => this.telemetryAlloyWrite()?.status ?? 'not written');
  readonly dashboardImportStatus = computed(() => this.dashboardImportPlan()?.status ?? 'pending');
  readonly dashboardImportWriteStatus = computed(() => this.dashboardImportWrite()?.status ?? 'not written');
  readonly dashboardImportUploadStatus = computed(() => this.dashboardImportUpload()?.status ?? 'not uploaded');
  readonly dashboardOpenUrl = computed(() => {
    return this.nullableText(this.dashboardImportUpload()?.response?.dashboardUrl)
      || this.nullableText(this.dashboardImportUpload()?.dashboard?.dashboardUrl)
      || this.usableDashboardUrl(this.telemetryPlan()?.dashboard.dashboardUrl)
      || this.usableDashboardUrl(this.dashboardUrl())
      || null;
  });
  readonly dashboardCanOpen = computed(() => Boolean(this.dashboardOpenUrl()));
  readonly dashboardImportSecretStatus = computed(() => {
    const secrets = this.dashboardImportPlan()?.request.secretStatus ?? [];
    if (secrets.length === 0) return 'pending';
    return secrets.every(secret => secret.configured) ? 'configured' : 'missing';
  });
  readonly telemetryLabels = computed(() => Object.entries(this.telemetryPlan()?.labels ?? {}));
  readonly trafficSummary = computed(() => this.trafficSnapshot()?.summary ?? {
    retained: this.eventRecords().length,
    dropped: 0,
    sources: this.trafficSources().length,
    parseErrors: 0,
    redactions: 0,
    truncatedSources: 0,
  });
  readonly filteredEventRecords = computed(() => {
    const query = this.trafficFilterText().trim().toLowerCase();
    const transport = this.trafficTransportFilter();
    const status = this.trafficStatusFilter();
    const source = this.trafficSourceFilter();
    const plugin = this.trafficPluginFilter().trim().toLowerCase();
    return this.eventRecords().filter(record => {
      const searchable = [
        record.type,
        record.event,
        record.command,
        record.transport,
        record.status,
        record.source,
        record.consumer,
        this.formatJson(record.payload),
      ].join(' ').toLowerCase();
      if (query && !searchable.includes(query)) return false;
      if (transport !== 'all' && record.transport !== transport) return false;
      if (status !== 'all' && record.status !== status) return false;
      if (source !== 'all' && record.source !== source) return false;
      if (plugin && !record.consumer.toLowerCase().includes(plugin)) return false;
      return true;
    });
  });
  readonly orderedEventRecords = computed(() => {
    return [...this.filteredEventRecords()].sort((left, right) => this.compareTimestampDesc(left.timestamp, right.timestamp));
  });
  readonly paginatedEventRecords = computed(() => {
    return this.pageSlice(this.orderedEventRecords(), this.trafficPageIndex());
  });
  readonly trafficPageCount = computed(() => this.pageCount(this.orderedEventRecords().length));
  readonly trafficPageSummary = computed(() => this.pageSummary(this.orderedEventRecords().length, this.trafficPageIndex()));
  readonly selectedTrafficRecord = computed<EventRecord | null>(() => {
    const selectedId = this.selectedTrafficRecordId();
    const records = this.orderedEventRecords();
    const selected = records.find(record => record.rowId === selectedId);
    if (selected) return selected;
    return records.length > 0 ? records[0] : null;
  });
  readonly selectedTrafficPayload = computed(() => {
    const record = this.selectedTrafficRecord();
    if (!record) return 'No traffic record selected.';
    return this.formatJson(record.payload ?? {});
  });
  readonly trafficTransports = computed(() => this.uniqueTrafficField('transport'));
  readonly trafficStatuses = computed(() => this.uniqueTrafficField('status'));
  readonly trafficSourceNames = computed(() => this.uniqueTrafficField('source'));
  readonly trafficSocketState = computed(() => {
    const streamSource = this.trafficSources().find(source => source.id === 'socket-stream');
    if (streamSource?.status) return streamSource.status;
    const socketRecord = this.eventRecords().find(record => record.transport === 'socket-metadata');
    const socketSource = this.trafficSources().find(source => source.id === 'socket-metadata');
    if (!socketSource && !socketRecord) return 'unknown';
    if (!socketSource?.exists) return 'unavailable';
    return socketRecord?.status || 'observed';
  });
  readonly trafficExportStatus = computed(() => this.trafficTraceExport()?.status ?? 'not exported');
  readonly trafficLiveStatus = computed(() => {
    if (this.trafficRefreshInFlight()) return 'refreshing';
    if (this.trafficPaused()) return 'paused';
    if (this.trafficLiveEnabled()) return 'live';
    return 'manual';
  });
  readonly logSummary = computed(() => this.logSnapshot()?.summary ?? {
    retained: 0,
    dropped: 0,
    sources: this.logSnapshotSources().length,
    existingSources: 0,
    parseErrors: 0,
    redactions: 0,
    truncatedSources: 0,
  });
  readonly snapshotStatus = computed(() => this.troubleshootingSnapshot()?.status ?? 'not planned');
  readonly snapshotSummary = computed(() => this.troubleshootingSnapshot()?.summary ?? {
    healthStatus: 'unknown',
    healthChecks: 0,
    logRecords: 0,
    trafficRecords: 0,
    copiedFiles: 0,
    copiedLogs: 0,
    doctorStatus: null,
  });
  readonly snapshotCopiedFiles = computed<DesktopTroubleshootingSnapshotFile[]>(() => {
    return (this.troubleshootingSnapshot()?.copiedFiles ?? []).slice(0, 12);
  });
  readonly snapshotCopiedLogs = computed<DesktopTroubleshootingSnapshotFile[]>(() => {
    return (this.troubleshootingSnapshot()?.copiedLogs ?? []).slice(0, 12);
  });
  readonly runtimeLogLines = computed(() => {
    const records = this.logSnapshot()?.records ?? [];
    if (records.length === 0) return ['No runtime log lines observed.'];
    return [...records]
      .sort((left, right) => this.compareTimestampDesc(left.timestamp || '', right.timestamp || ''))
      .map(record => this.toLogLine(record));
  });
  readonly paginatedRuntimeLogLines = computed(() => {
    return this.pageSlice(this.runtimeLogLines(), this.runtimeLogPageIndex());
  });
  readonly runtimeLogPageCount = computed(() => this.pageCount(this.runtimeLogLines().length));
  readonly runtimeLogPageSummary = computed(() => this.pageSummary(this.runtimeLogLines().length, this.runtimeLogPageIndex()));
  readonly profileStoreSummary = computed(() => this.profileRegistry()?.summary ?? {
    total: 0,
    selectedProfileId: null,
    selectedExists: false,
  });

  private readonly modeStorageKey = 'bmf-desktop.mode';
  private readonly trafficRefreshIntervalMs = 3000;
  private readonly easyTransactionActions = new Set(['install-stack', 'repair-stack', 'update-stack', 'configure-telemetry']);
  private readonly easyServiceActions = new Set(['start-stack', 'stop-stack', 'restart-stack', 'start-alloy', 'stop-alloy', 'restart-alloy']);
  private trafficRefreshTimer: ReturnType<typeof setInterval> | null = null;
  private advancedInitialized = false;

  constructor() {
    this.trafficRefreshTimer = setInterval(() => {
      void this.refreshTraffic({ automated: true });
    }, this.trafficRefreshIntervalMs);
  }

  ngOnInit(): void {
    this.loadStoredMode();
    void this.initializeDesktop();
  }

  ngOnDestroy(): void {
    if (this.trafficRefreshTimer) {
      clearInterval(this.trafficRefreshTimer);
      this.trafficRefreshTimer = null;
    }
  }

  async refreshCurrentMode(): Promise<void> {
    if (this.appMode() === 'advanced') {
      await this.refreshPlan();
      return;
    }
    await this.refreshEasyMode();
  }

  async setAppMode(mode: AppMode): Promise<void> {
    if (this.appMode() === mode) return;
    this.appMode.set(mode);
    this.storeMode(mode);
    if (mode === 'advanced') {
      if (!this.advancedInitialized) await this.refreshPlan();
      return;
    }
    await this.refreshEasyMode();
    await this.promptForBrickadiaSetupIfNeeded();
  }

  async refreshEasyMode(): Promise<void> {
    if (this.easyHealthRefreshInFlight()) return;
    this.easyHealthRefreshInFlight.set(true);
    this.easyHealthRefreshError.set('');
    try {
      await this.refreshProfiles();
      if (this.easyProfileSetupNeeded()) {
        this.healthReport.set(null);
        this.healthChecks.set([]);
        return;
      }
      await this.refreshHealth();
    } catch (error) {
      this.easyHealthRefreshError.set(this.errorMessage(error));
      throw error;
    } finally {
      this.easyHealthRefreshInFlight.set(false);
    }
  }

  async refreshPlan(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; using static renderer state');
      return;
    }

    await this.refreshProfiles();
    const profile = this.activeProfileInput();
    const plan = await api.getBootstrapPlan({
      telemetryEnabled: this.telemetryEnabled(),
      profile,
    });
    this.bootstrapPlan.set(plan);
    this.selectedOperation.set(plan.operations[0] ?? null);
    this.appendLog(`Loaded ${plan.operations.length} planned operation(s); prerequisites=${plan.prerequisites?.status || 'unknown'}`);
    await this.refreshOperationTransaction(plan.operations[0]?.operationId ?? 'install-stack');
    await this.refreshTelemetryPlan();
    await this.refreshDashboardImportPlan();
    await this.refreshHealth();
    await this.refreshServiceAction('start-stack');
    await this.refreshUpdateCheck();
    await this.refreshUpdatePlan();
    await this.refreshUpdateInstallPlan();
    await this.refreshTraffic();
    await this.refreshLogs();
    await this.refreshTroubleshootingSnapshot();
    this.advancedInitialized = true;
  }

  async refreshProfiles(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; profiles remain static');
      return;
    }

    const registry = await api.getProfiles();
    this.profileRegistry.set(registry);
    this.applySelectedProfileIfClean(registry);
    this.appendLog(`Profiles loaded=${registry.summary.total} selected=${registry.selectedProfileId || 'none'}`);
  }

  async saveCurrentProfile(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; profile was not saved');
      return;
    }

    const registry = await api.saveProfile({
      select: true,
      profile: this.formProfileInput(),
    });
    this.profileRegistry.set(registry);
    this.applySelectedProfileIfClean(registry, true);
    this.appendLog(`Profile saved=${registry.selectedProfileId || this.profileName()}`);
  }

  async setupProfileFromBrickadiaInstall(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; Brickadia setup was not opened');
      return;
    }
    if (this.brickadiaSetupInFlight()) {
      this.appendLog('Brickadia setup is already running');
      return;
    }

    this.brickadiaSetupInFlight.set(true);
    try {
      const result = await api.setupProfileFromBrickadiaInstall({
        currentPath: this.profileDraft().paths.brickadiaWin64,
        profile: this.formProfileInput(),
      });
      this.brickadiaSetupResult.set(result);
      if (result.canceled) {
        this.appendLog('Brickadia setup canceled');
        return;
      }
      if (!result.registry || !result.profile || !result.brickadiaWin64) {
        this.appendLog(`Brickadia setup ${result.status}: ${result.warnings[0] || 'server executable not found'}`);
        return;
      }

      this.profileRegistry.set(result.registry);
      this.applyProfileToForm(result.profile, false);
      this.resetHealthForSelectedPath();
      this.appendLog(`Brickadia setup ${result.status}: ${result.brickadiaWin64}`);
      try {
        await this.refreshEasyMode();
      } catch (error) {
        this.appendLog(`Health refresh after setup failed: ${this.errorMessage(error)}`);
      }
    } catch (error) {
      this.appendLog(`Brickadia setup failed: ${this.errorMessage(error)}`);
    } finally {
      this.brickadiaSetupInFlight.set(false);
    }
  }

  async runEasyAction(actionId: string | null): Promise<void> {
    if (!actionId || this.easyActionInFlight()) return;
    this.easyActionInFlight.set(actionId);
    this.easyActionError.set('');
    try {
      if (this.easyTransactionActions.has(actionId)) {
        await this.applyEasyTransaction(actionId);
      } else if (this.easyServiceActions.has(actionId)) {
        await this.applyEasyServiceAction(actionId);
      } else {
        this.appendLog(`Easy action ${actionId} is available from Advanced mode`);
        await this.setAppMode('advanced');
      }
      await this.refreshEasyMode();
    } catch (error) {
      const message = this.errorMessage(error);
      this.easyActionError.set(message);
      this.appendLog(`Easy action ${actionId} failed: ${message}`);
    } finally {
      this.easyActionInFlight.set(null);
    }
  }

  easyActionLabel(actionId: string | null): string {
    switch (actionId) {
      case 'install-stack':
        return 'Install';
      case 'repair-stack':
        return 'Repair';
      case 'update-stack':
        return 'Update';
      case 'start-stack':
      case 'start-alloy':
        return 'Start';
      case 'restart-stack':
      case 'restart-alloy':
        return 'Restart';
      case 'configure-telemetry':
        return 'Configure';
      default:
        return 'Open';
    }
  }

  easyActionIcon(actionId: string | null): string {
    switch (actionId) {
      case 'install-stack':
        return 'download';
      case 'repair-stack':
        return 'build';
      case 'update-stack':
        return 'system_update_alt';
      case 'start-stack':
      case 'start-alloy':
        return 'play_arrow';
      case 'restart-stack':
      case 'restart-alloy':
        return 'restart_alt';
      case 'configure-telemetry':
        return 'settings';
      default:
        return 'open_in_new';
    }
  }

  async selectStoredProfile(profile: DesktopServerProfile): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    this.applyProfileToForm(profile, false);
    if (!api) {
      this.appendLog(`Selected static profile ${profile.id}`);
      return;
    }

    const registry = await api.selectProfile(profile.id);
    this.profileRegistry.set(registry);
    this.appendLog(`Profile selected=${profile.id}`);
    await this.refreshPlan();
  }

  async refreshTelemetryPlan(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; telemetry plan remains static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const plan = await api.getTelemetryPlan({
      telemetryEnabled: this.telemetryEnabled(),
      profile: this.activeProfileInput(),
    });
    this.telemetryPlan.set(plan);
    this.appendLog(`Telemetry ${plan.status}: missingSecrets=${plan.alloy.missingSecretRefs.length}`);
  }

  async writeTelemetryAlloyConfig(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; Alloy config was not written');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const result = await api.writeTelemetryAlloyConfig({
      telemetryEnabled: this.telemetryEnabled(),
      profile: this.activeProfileInput(),
      confirm: 'write-alloy',
    });
    this.telemetryAlloyWrite.set(result);
    if (!this.nullableText(this.grafanaAlloyConfigPath()) && result.outputPath) {
      this.grafanaAlloyConfigPath.set(result.outputPath);
      this.markProfileDirty();
    }
    await this.refreshTelemetryPlan();
    this.appendLog(`Alloy config ${result.status}: bytes=${result.bytes} path=${result.outputPath}`);
  }

  async refreshDashboardImportPlan(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; dashboard import plan remains static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const plan = await api.getDashboardImportPlan({
      telemetryEnabled: this.telemetryEnabled(),
      profile: this.activeProfileInput(),
    });
    this.dashboardImportPlan.set(plan);
    this.appendLog(`Dashboard import ${plan.status}: uid=${plan.dashboard.dashboardUid} payload=${plan.request.outputPath || 'pending'}`);
  }

  async writeDashboardImportPayload(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; dashboard payload was not written');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const result = await api.writeDashboardImportPayload({
      telemetryEnabled: this.telemetryEnabled(),
      profile: this.activeProfileInput(),
      dryRun: false,
    });
    this.dashboardImportWrite.set(result);
    await this.refreshDashboardImportPlan();
    this.appendLog(`Dashboard payload ${result.status}: bytes=${result.bytes} path=${result.outputPath}`);
  }

  async uploadDashboardImport(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; dashboard was not uploaded');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const result = await api.uploadDashboardImport({
      telemetryEnabled: this.telemetryEnabled(),
      profile: this.activeProfileInput(),
      confirm: 'import',
      timeoutMs: 10000,
    });
    this.dashboardImportUpload.set(result);
    this.adoptDashboardUrl(result.response?.dashboardUrl || result.dashboard.dashboardUrl || null);
    this.appendLog(
      `Dashboard upload ${result.status}: http=${result.response?.status ?? 'n/a'} url=${result.response?.dashboardUrl || result.dashboard.dashboardUrl || 'pending'}`,
    );
  }

  async refreshHealth(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; health remains static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const report = await api.getProfileHealth({
      includeNetworkChecks: true,
      includePortDiagnostics: true,
      profile: this.activeProfileInput(),
    });
    this.healthReport.set(report);
    this.healthChecks.set(report.health.checks.map(check => this.toHealthCheck(check)));
    this.logSources.set(report.logSources);
    const summary = report.health.summary;
    this.appendLog(
      `Health ${report.health.status}: healthy=${summary['healthy']} degraded=${summary['degraded']} unhealthy=${summary['unhealthy']} unknown=${summary['unknown']}`,
    );
  }

  async refreshOperationTransaction(operationId: string): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; transaction preview remains static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const transaction = await api.getOperationTransaction(operationId, {
      profile: this.activeProfileInput(),
    });
    this.operationTransaction.set(transaction);
    this.operationRollback.set(null);
    this.appendLog(
      `Transaction ${transaction.operationId}: ready=${transaction.summary.ready} blocked=${transaction.summary.blocked} rollback=${transaction.rollback.length}`,
    );
  }

  async applySelectedTransaction(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; transaction was not applied');
      return;
    }

    const operationId = this.selectedOperation()?.operationId || this.operationTransaction()?.operationId || 'install-stack';
    const current = this.operationTransaction();
    if (current?.summary.blocked) {
      this.appendLog(`Transaction ${operationId} is blocked; apply skipped`);
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const result = await api.applyOperationTransaction(operationId, {
      profile: this.activeProfileInput(),
      confirm: 'apply',
    });
    this.operationTransaction.set(result);
    this.appendLog(
      `Transaction ${result.operationId} ${result.status}: applied=${this.transactionAppliedSummary().applied} failed=${this.transactionAppliedSummary().failed} journal=${result.journalPath}`,
    );
    await this.refreshRollbackTransaction(result.journalPath);
    await this.refreshHealth();
    await this.refreshLogs();
  }

  async refreshRollbackTransaction(journalPath = this.operationTransaction()?.journalPath || ''): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; rollback preview remains static');
      return;
    }
    if (!journalPath || !this.rollbackCanPreview()) {
      this.appendLog('Rollback preview requires an applied transaction journal');
      return;
    }

    const rollback = await api.getRollbackTransaction({
      journalPath,
    });
    this.operationRollback.set(rollback);
    this.appendLog(
      `Rollback ${rollback.status}: ready=${rollback.summary.ready} blocked=${rollback.summary.blocked} restores=${rollback.summary.restores} removals=${rollback.summary.removals}`,
    );
  }

  async applyRollbackTransaction(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; rollback was not applied');
      return;
    }
    const journalPath = this.operationRollback()?.sourceJournalPath || this.operationTransaction()?.journalPath;
    if (!journalPath) {
      this.appendLog('Rollback apply requires a transaction journal');
      return;
    }
    const rollback = this.operationRollback();
    if (rollback?.summary.blocked) {
      this.appendLog('Rollback is blocked; apply skipped');
      return;
    }

    const result = await api.applyRollbackTransaction({
      journalPath,
      confirm: 'rollback',
    });
    this.operationRollback.set(result);
    this.appendLog(
      `Rollback ${result.status}: applied=${result.applied?.filter(step => step.applied).length ?? 0} errors=${result.errors?.length ?? 0} journal=${result.journalPath}`,
    );
    await this.refreshHealth();
    await this.refreshLogs();
  }

  async refreshServiceAction(actionId = 'start-stack'): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; service launch contract remains static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const action = await api.getServiceAction(actionId, {
      profile: this.activeProfileInput(),
    });
    this.serviceAction.set(action);
    this.appendLog(
      `Service ${action.actionId}: status=${action.status} ready=${action.summary.ready} blocked=${action.summary.blocked}`,
    );
  }

  async startStackService(): Promise<void> {
    await this.applyServiceAction('start-stack', 'start');
  }

  async stopStackService(): Promise<void> {
    await this.applyServiceAction('stop-stack', 'stop');
  }

  async restartStackService(): Promise<void> {
    await this.applyServiceAction('restart-stack', 'restart');
  }

  async startAlloyService(): Promise<void> {
    await this.applyServiceAction('start-alloy', 'start');
  }

  async stopAlloyService(): Promise<void> {
    await this.applyServiceAction('stop-alloy', 'stop');
  }

  async restartAlloyService(): Promise<void> {
    await this.applyServiceAction('restart-alloy', 'restart');
  }

  private async applyEasyTransaction(operationId: string): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog(`Preload API unavailable; ${operationId} was not applied`);
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const preview = await api.getOperationTransaction(operationId, {
      profile: this.activeProfileInput(),
    });
    this.operationTransaction.set(preview);
    this.operationRollback.set(null);
    if (preview.summary.ready <= 0) {
      this.appendLog(`Easy ${operationId}: no ready steps to apply; blocked=${preview.summary.blocked}`);
      return;
    }

    const result = await api.applyOperationTransaction(operationId, {
      profile: this.activeProfileInput(),
      confirm: 'apply',
    });
    this.operationTransaction.set(result);
    this.appendLog(
      `Easy ${result.operationId} ${result.status}: applied=${result.applied?.filter(step => step.applied).length ?? 0} skipped=${result.applied?.filter(step => !step.applied).length ?? 0} failed=${result.errors?.length ?? 0} journal=${result.journalPath}`,
    );
    if (result.journalPath) {
      await this.refreshRollbackTransaction(result.journalPath);
    }
    await this.refreshHealth();
    await this.refreshLogs();
  }

  private async applyEasyServiceAction(actionId: string): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog(`Preload API unavailable; ${actionId} was not applied`);
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const preview = await api.getServiceAction(actionId, {
      profile: this.activeProfileInput(),
    });
    this.serviceAction.set(preview);
    if (preview.summary.ready <= 0 || preview.summary.blocked > 0) {
      this.appendLog(`Easy ${actionId}: service action is blocked; ready=${preview.summary.ready} blocked=${preview.summary.blocked}`);
      return;
    }

    const result = await api.applyServiceAction(actionId, {
      profile: this.activeProfileInput(),
      confirm: this.serviceActionConfirm(actionId),
    });
    this.serviceAction.set(result);
    this.appendLog(this.serviceActionResultLog(result));
    await this.refreshHealth();
    await this.refreshLogs();
  }

  private async applyServiceAction(actionId: string, confirm: 'start' | 'stop' | 'restart'): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog(`Preload API unavailable; service ${confirm} was not applied`);
      return;
    }

    const current = this.serviceAction();
    if (current && current.actionId !== actionId) {
      this.appendLog(`Service action ${current.actionId} is not a ${actionId} preview; ${confirm} skipped`);
      return;
    }
    if (current?.summary.blocked) {
      this.appendLog(`Service ${confirm} is blocked; ${confirm} skipped`);
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const result = await api.applyServiceAction(actionId, {
      profile: this.activeProfileInput(),
      confirm,
    });
    this.serviceAction.set(result);
    this.appendLog(this.serviceActionResultLog(result));
    await this.refreshHealth();
    await this.refreshLogs();
  }

  private serviceActionConfirm(actionId: string): 'start' | 'stop' | 'restart' {
    if (actionId.startsWith('stop-')) return 'stop';
    if (actionId.startsWith('restart-')) return 'restart';
    return 'start';
  }

  private serviceActionResultLog(result: DesktopServiceAction): string {
    if (result.stop) {
      return `Service ${result.actionId} ${result.status}: stopped=${result.stop.status || 'n/a'} pid=${result.process?.pid ?? result.stop.pid ?? 'n/a'} journal=${result.journal?.path || result.paths.journalPath}`;
    }
    return `Service ${result.actionId} ${result.status}: pid=${result.process?.pid ?? 'n/a'} journal=${result.journal?.path || result.paths.journalPath}`;
  }

  private canApplyServiceAction(actionId: string): boolean {
    const action = this.serviceAction();
    return Boolean(
      action &&
      action.actionId === actionId &&
      action.dryRun &&
      action.status === 'planned' &&
      action.summary.ready > 0 &&
      action.summary.blocked === 0,
    );
  }

  async refreshUpdateCheck(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; update check remains static');
      return;
    }

    const check = await api.getUpdateCheck({
      releaseChannel: 'dev',
    });
    this.updateCheck.set(check);
    this.appendLog(
      `Update ${check.status}: current=${check.currentVersion} latest=${check.latest?.version || 'none'} artifact=${check.artifactVerification.status}`,
    );
  }

  async refreshUpdatePlan(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; update plan remains static');
      return;
    }

    const plan = await api.getUpdatePlan({
      releaseChannel: 'dev',
    });
    this.updatePlan.set(plan);
    this.appendLog(
      `Update plan ${plan.status}: steps=${plan.steps.length} blockers=${plan.blockers.length}`,
    );
  }

  async downloadDesktopUpdate(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; desktop update was not downloaded');
      return;
    }

    const result = await api.downloadUpdate({
      releaseChannel: 'dev',
      confirm: 'download',
    });
    this.updateDownload.set(result);
    await this.refreshUpdateCheck();
    this.appendLog(
      `Update download ${result.status}: verification=${result.verification.status} path=${result.verification.path || 'pending'}`,
    );
  }

  async refreshUpdateInstallPlan(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; update install plan remains static');
      return;
    }

    const plan = await api.getUpdateInstallPlan({
      releaseChannel: 'dev',
      installerPath: this.updateDownload()?.verification?.path,
    });
    this.updateInstallPlan.set(plan);
    this.appendLog(
      `Update install plan ${plan.status}: installer=${plan.installer.verification.status} blockers=${plan.blockers.length}`,
    );
  }

  async launchUpdateInstaller(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; desktop installer was not launched');
      return;
    }

    const result = await api.launchUpdateInstaller({
      releaseChannel: 'dev',
      installerPath: this.updateInstallPlan()?.installer.path || this.updateDownload()?.verification?.path,
      confirm: 'install',
    });
    this.updateInstallHandoff.set(result);
    this.appendLog(
      `Update installer ${result.status}: launch=${result.launch.status} command=${result.command.display}`,
    );
  }

  async refreshTraffic(options: { automated?: boolean } = {}): Promise<void> {
    if (options.automated && !this.desktopInitialized()) return;
    if (options.automated && this.appMode() !== 'advanced') return;
    if (options.automated && !this.trafficLiveEnabled()) return;
    if (this.trafficPaused()) {
      if (!options.automated) this.appendLog('Traffic refresh paused');
      return;
    }
    if (this.trafficRefreshInFlight()) {
      if (!options.automated) this.appendLog('Traffic refresh already running');
      return;
    }

    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      if (!options.automated) this.appendLog('Preload API unavailable; traffic remains static');
      return;
    }

    this.trafficRefreshInFlight.set(true);
    try {
      await this.ensureSelectedProfileLoaded();
      const snapshot = await api.getTrafficSnapshot({
        maxRecords: 100,
        profile: this.activeProfileInput(),
      });
      this.trafficSnapshot.set(snapshot);
      this.trafficSources.set(snapshot.sources);
      const records = snapshot.records.map((record, index) => this.toEventRecord(record, index));
      this.eventRecords.set(records);
      this.trafficPageIndex.set(0);
      this.trafficLastRefresh.set(this.utcClockTime());
      this.trafficRefreshError.set('');
      if (!records.some(record => record.rowId === this.selectedTrafficRecordId())) {
        this.selectedTrafficRecordId.set(this.orderedEventRecords()[0]?.rowId ?? null);
      }
      if (!options.automated) {
        this.appendLog(
          `Traffic retained=${snapshot.summary.retained} dropped=${snapshot.summary.dropped} redactions=${snapshot.summary.redactions}`,
        );
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message !== this.trafficRefreshError()) {
        this.appendLog(`Traffic refresh failed: ${message}`);
      }
      this.trafficRefreshError.set(message);
    } finally {
      this.trafficRefreshInFlight.set(false);
    }
  }

  async refreshLogs(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; logs remain static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const snapshot = await api.getLogSnapshot({
      maxLines: 250,
      profile: this.activeProfileInput(),
    });
    this.logSnapshot.set(snapshot);
    this.logSnapshotSources.set(snapshot.sources);
    this.runtimeLogPageIndex.set(0);
    this.appendLog(
      `Logs retained=${snapshot.summary.retained} sources=${snapshot.summary.existingSources}/${snapshot.summary.sources} redactions=${snapshot.summary.redactions}`,
    );
  }

  async refreshTroubleshootingSnapshot(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; troubleshooting snapshot remains static');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const snapshot = await api.getTroubleshootingSnapshot({
      maxLogLines: 250,
      maxTrafficRecords: 100,
      profile: this.activeProfileInput(),
    });
    this.troubleshootingSnapshot.set(snapshot);
    this.appendLog(
      `Snapshot ${snapshot.status}: files=${snapshot.summary.copiedFiles} logs=${snapshot.summary.copiedLogs} root=${snapshot.root}`,
    );
  }

  async writeTroubleshootingSnapshot(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; troubleshooting snapshot was not written');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const snapshot = await api.writeTroubleshootingSnapshot({
      maxLogLines: 250,
      maxTrafficRecords: 100,
      profile: this.activeProfileInput(),
      confirm: 'snapshot',
    });
    this.troubleshootingSnapshot.set(snapshot);
    this.appendLog(
      `Snapshot ${snapshot.status}: ${snapshot.files.snapshot}`,
    );
  }

  toggleTrafficPause(): void {
    this.trafficPaused.update(paused => !paused);
    this.appendLog(`Traffic ${this.trafficPaused() ? 'paused' : 'resumed'}`);
    if (!this.trafficPaused() && this.trafficLiveEnabled()) {
      void this.refreshTraffic({ automated: true });
    }
  }

  toggleTrafficLive(enabled: boolean): void {
    this.trafficLiveEnabled.set(Boolean(enabled));
    this.appendLog(`Traffic live refresh ${this.trafficLiveEnabled() ? 'enabled' : 'disabled'}`);
    if (this.trafficLiveEnabled() && !this.trafficPaused()) {
      void this.refreshTraffic({ automated: true });
    }
  }

  clearTraffic(): void {
    this.eventRecords.set([]);
    this.selectedTrafficRecordId.set(null);
    this.appendLog('Traffic view cleared');
  }

  selectTrafficRecord(record: EventRecord): void {
    this.selectedTrafficRecordId.set(record.rowId);
  }

  async copySelectedTrafficPayload(): Promise<void> {
    const record = this.selectedTrafficRecord();
    if (!record) {
      this.appendLog('No traffic payload selected');
      return;
    }
    await this.copyText(this.selectedTrafficPayload(), 'Selected traffic payload copied');
  }

  async copyTrafficTrace(): Promise<void> {
    const snapshot = this.trafficSnapshot();
    if (!snapshot) {
      this.appendLog('Traffic snapshot unavailable; refresh traffic before copying trace');
      return;
    }
    await this.copyText(this.formatJson(snapshot), 'Redacted traffic trace copied');
  }

  async exportTrafficTrace(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; traffic trace was not exported');
      return;
    }

    await this.ensureSelectedProfileLoaded();
    const result = await api.exportTrafficTrace({
      maxRecords: 100,
      anonymizePlayers: true,
      redactPrivateIps: true,
      confirm: 'export',
      profile: this.activeProfileInput(),
    });
    this.trafficTraceExport.set(result);
    this.trafficSnapshot.set(result.snapshot);
    this.trafficSources.set(result.snapshot.sources);
    const records = result.snapshot.records.map((record, index) => this.toEventRecord(record, index));
    this.eventRecords.set(records);
    this.trafficPageIndex.set(0);
    if (!records.some(record => record.rowId === this.selectedTrafficRecordId())) {
      this.selectedTrafficRecordId.set(this.orderedEventRecords()[0]?.rowId ?? null);
    }
    this.appendLog(`Traffic export ${result.status}: ${result.outputPath}`);
  }

  selectOperation(operation: OperationPlan): void {
    this.selectedOperation.set(operation);
    void this.refreshOperationTransaction(operation.operationId);
  }

  setTrafficFilterText(value: string): void {
    this.trafficFilterText.set(value);
    this.resetTrafficPage();
  }

  setTrafficTransportFilter(value: string): void {
    this.trafficTransportFilter.set(value);
    this.resetTrafficPage();
  }

  setTrafficStatusFilter(value: string): void {
    this.trafficStatusFilter.set(value);
    this.resetTrafficPage();
  }

  setTrafficSourceFilter(value: string): void {
    this.trafficSourceFilter.set(value);
    this.resetTrafficPage();
  }

  setTrafficPluginFilter(value: string): void {
    this.trafficPluginFilter.set(value);
    this.resetTrafficPage();
  }

  setTrafficPage(delta: number): void {
    this.trafficPageIndex.set(this.clampPage(this.trafficPageIndex() + delta, this.orderedEventRecords().length));
  }

  setRuntimeLogPage(delta: number): void {
    this.runtimeLogPageIndex.set(this.clampPage(this.runtimeLogPageIndex() + delta, this.runtimeLogLines().length));
  }

  markProfileDirty(): void {
    this.profileFormDirty.set(true);
  }

  async chooseProfilePath(field: DesktopProfilePathField): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog(`Preload API unavailable; ${field} picker was not opened`);
      return;
    }

    const result = await api.chooseProfilePath(field, {
      currentPath: this.currentProfilePath(field),
    });
    if (result.canceled || !result.path) {
      this.appendLog(`Path picker canceled=${field}`);
      return;
    }

    this.setProfilePath(field, result.path);
    this.markProfileDirty();
    this.appendLog(`Path selected=${field}`);
  }

  async openDashboard(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api) {
      this.appendLog('Preload API unavailable; dashboard was not opened');
      return;
    }
    const url = this.dashboardOpenUrl();
    if (!url) {
      this.appendLog('Dashboard URL is not configured yet');
      return;
    }
    try {
      await api.openExternal(url);
      this.appendLog(`Dashboard opened: ${url}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.appendLog(`Dashboard open failed: ${message}`);
    }
  }

  private adoptDashboardUrl(url: string | null): void {
    const cleanUrl = this.nullableText(url || '');
    if (!cleanUrl || cleanUrl === this.nullableText(this.dashboardUrl())) return;
    this.dashboardUrl.set(cleanUrl);
    this.markProfileDirty();
  }

  private appendLog(message: string): void {
    this.logLines.update(lines => [...lines.slice(-49), message]);
  }

  serviceStatusIcon(status: HealthStatus): string {
    switch (status) {
      case 'healthy':
        return 'check_circle';
      case 'degraded':
        return 'warning';
      case 'unhealthy':
        return 'error';
      default:
        return 'help';
    }
  }

  private portStatusToHealth(port: DesktopPortDiagnostic): HealthStatus {
    switch (port.status) {
      case 'in-use':
        return 'healthy';
      case 'available':
        return 'unknown';
      case 'not-configured':
        return 'degraded';
      default:
        return 'unknown';
    }
  }

  private portStatusIcon(status: DesktopPortDiagnostic['status']): string {
    switch (status) {
      case 'in-use':
        return 'radio_button_checked';
      case 'available':
        return 'radio_button_unchecked';
      case 'not-configured':
        return 'block';
      default:
        return 'help';
    }
  }

  private portDetail(port: DesktopPortDiagnostic): string {
    const endpoint = port.port ? `${port.protocol.toUpperCase()} ${port.port}` : `${port.protocol.toUpperCase()} not configured`;
    return [endpoint, port.ownerSummary].filter(Boolean).join(' / ');
  }

  private easyServiceDefinitionVisible(definition: EasyServiceDefinition, check?: HealthCheck): boolean {
    switch (definition.visibility || 'always') {
      case 'always':
        return true;
      case 'managed-stack':
        return this.easyManagedStackInScope(check);
      case 'socket':
        return this.easySocketInScope(check);
      case 'frame-telemetry':
        return this.easyFrameTelemetryInScope(check);
      case 'telemetry':
        return this.easyTelemetryInScope(check);
      case 'dashboard':
        return this.easyDashboardInScope(check);
    }
  }

  private easyManagedStackInScope(check?: HealthCheck): boolean {
    const paths = this.profileDraft().paths;
    return Boolean(paths.omeggaRuntime || paths.omeggaStartScript || check?.status === 'healthy');
  }

  private easySocketInScope(check?: HealthCheck): boolean {
    return this.numberValue(this.bmfSocketPort(), 0) > 0
      || check?.status === 'healthy'
      || Boolean(check?.evidence?.length);
  }

  private easyFrameTelemetryInScope(check?: HealthCheck): boolean {
    return this.profileDraft().telemetry.frameTelemetryEnabled
      || check?.status === 'healthy'
      || Boolean(check?.evidence?.length);
  }

  private easyTelemetryInScope(check?: HealthCheck): boolean {
    return this.profileDraft().telemetry.enabled
      && (this.easyTelemetryConfigured() || check?.status === 'healthy');
  }

  private easyDashboardInScope(check?: HealthCheck): boolean {
    return this.profileDraft().telemetry.enabled && (
      Boolean(this.profileDraft().telemetry.dashboardUrl)
      || check?.status === 'healthy'
      || Boolean(this.dashboardImportUpload()?.response?.dashboardUrl)
    );
  }

  private easyTelemetryConfigured(): boolean {
    const profile = this.profileDraft();
    return profile.telemetry.enabled && Boolean(
      profile.paths.grafanaAlloyConfig
      || profile.telemetry.dashboardUrl
      || this.telemetryAlloyWrite()
      || this.dashboardImportUpload(),
    );
  }

  private easyPortVisible(port: DesktopPortDiagnostic): boolean {
    if (port.status === 'not-configured') return false;
    if (port.status === 'available') return false;
    if (port.id === 'bmf-socket' && this.numberValue(this.bmfSocketPort(), 0) <= 0) return false;
    if (port.id === 'alloy-ready' && !this.easyTelemetryConfigured()) return false;
    if (port.id === 'omegga-web' && !this.easyManagedStackInScope()) return false;
    return true;
  }

  private toHealthCheck(check: DesktopHealthCheck): HealthCheck {
    return {
      id: check.id,
      component: check.component,
      severity: check.severity,
      status: check.status,
      summary: check.summary,
      evidence: check.evidence,
      nextAction: check.nextAction,
    };
  }

  private toEventRecord(record: DesktopTrafficSnapshot['records'][number], index: number): EventRecord {
    return {
      rowId: `${record.id || 'record'}:${record.timestamp || 'no-time'}:${index}`,
      timestamp: record.timestamp || '',
      type: record.type || 'unknown',
      event: record.event || '',
      command: record.command || '',
      transport: record.transport || 'unknown',
      status: record.status || 'unknown',
      source: record.source || 'unknown',
      consumer: record.consumer || '',
      durationMs: typeof record.durationMs === 'number' ? record.durationMs : null,
      redactions: Number(record.redactions || 0),
      payload: record.payload ?? {},
    };
  }

  private uniqueTrafficField(field: 'transport' | 'status' | 'source'): string[] {
    const values = this.eventRecords()
      .map(record => record[field])
      .filter(Boolean)
      .sort((left, right) => left.localeCompare(right));
    return Array.from(new Set(values));
  }

  private formatJson(value: unknown): string {
    try {
      return JSON.stringify(value, null, 2);
    } catch {
      return String(value ?? '');
    }
  }

  private async copyText(text: string, successMessage: string): Promise<void> {
    if (!navigator.clipboard?.writeText) {
      this.appendLog('Clipboard API unavailable');
      return;
    }
    await navigator.clipboard.writeText(text);
    this.appendLog(successMessage);
  }

  private toLogLine(record: DesktopLogRecord): string {
    const timestamp = record.timestamp || '';
    const severity = String(record.severity || 'info').toUpperCase().padEnd(7);
    return `${timestamp} ${severity} ${record.component}/${record.sourceId}: ${record.message}`;
  }

  private activeProfileInput(): ProfileDraftInput {
    return this.formProfileInput();
  }

  private formProfileInput(): ProfileDraftInput {
    return {
      id: this.activeProfileId(),
      name: this.profileName(),
      backend: this.profileBackend(),
      backendConfig: {},
      paths: {
        brickadiaWin64: this.nullableText(this.brickadiaWin64Path()),
        omeggaRuntime: this.nullableText(this.omeggaRuntimePath()),
        omeggaStartScript: this.nullableText(this.omeggaStartScriptPath()),
        bmfRoot: this.nullableText(this.bmfRootPath()),
        bmfRuntimeDir: this.nullableText(this.bmfRuntimeDirPath()),
        grafanaAlloyExecutable: this.nullableText(this.grafanaAlloyExecutablePath()),
        grafanaAlloyConfig: this.nullableText(this.grafanaAlloyConfigPath()),
      },
      ports: {
        brickadia: this.numberValue(this.brickadiaPort(), 7777),
        omeggaWeb: this.numberValue(this.omeggaWebPort(), 8080),
        bmfSocket: this.numberValue(this.bmfSocketPort(), 0),
        alloyReady: this.numberValue(this.alloyReadyPort(), 12345),
      },
      telemetry: {
        enabled: this.telemetryEnabled(),
        frameTelemetryEnabled: this.frameTelemetryEnabled(),
        environment: this.telemetryEnvironment() || 'local',
        instance: this.telemetryInstance() || this.profileName(),
        dashboardUrl: this.nullableText(this.dashboardUrl()),
      },
    };
  }

  private applySelectedProfileIfClean(registry: DesktopProfileRegistry, force = false): void {
    if (this.profileFormDirty() && !force) return;
    const selected = registry.profiles.find(profile => profile.id === registry.selectedProfileId);
    if (selected) this.applyProfileToForm(selected, false);
  }

  private applyProfileToForm(profile: DesktopServerProfile, dirty: boolean): void {
    const previousBrickadiaPath = this.brickadiaWin64Path();
    const nextBrickadiaPath = profile.paths?.brickadiaWin64 || '';
    this.activeProfileId.set(profile.id || null);
    this.profileName.set(profile.name || profile.id);
    this.profileBackend.set('local-process');
    this.brickadiaWin64Path.set(nextBrickadiaPath);
    this.omeggaRuntimePath.set(profile.paths?.omeggaRuntime || '');
    this.omeggaStartScriptPath.set(profile.paths?.omeggaStartScript || '');
    this.bmfRootPath.set(profile.paths?.bmfRoot || '');
    this.bmfRuntimeDirPath.set(profile.paths?.bmfRuntimeDir || '');
    this.grafanaAlloyExecutablePath.set(profile.paths?.grafanaAlloyExecutable || '');
    this.grafanaAlloyConfigPath.set(profile.paths?.grafanaAlloyConfig || '');
    this.brickadiaPort.set(String(profile.ports?.brickadia ?? 7777));
    this.omeggaWebPort.set(String(profile.ports?.omeggaWeb ?? 8080));
    this.bmfSocketPort.set(String(profile.ports?.bmfSocket ?? 0));
    this.alloyReadyPort.set(String(profile.ports?.alloyReady ?? 12345));
    this.telemetryEnabled.set(Boolean(profile.telemetry?.enabled));
    this.frameTelemetryEnabled.set(Boolean(profile.telemetry?.frameTelemetryEnabled));
    this.telemetryEnvironment.set(profile.telemetry?.environment || 'local');
    this.telemetryInstance.set(profile.telemetry?.instance || profile.id);
    this.dashboardUrl.set(profile.telemetry?.dashboardUrl || '');
    this.profileFormDirty.set(dirty);
    if (previousBrickadiaPath !== nextBrickadiaPath) this.resetHealthForSelectedPath();
  }

  private resetHealthForSelectedPath(): void {
    this.healthReport.set(null);
    this.healthChecks.set(this.pendingEasyHealthChecks());
  }

  private async initializeDesktop(): Promise<void> {
    try {
      await this.refreshCurrentMode();
    } catch (error) {
      this.appendLog(`Startup refresh failed: ${this.errorMessage(error)}`);
    } finally {
      this.desktopInitialized.set(true);
    }
    try {
      await this.promptForBrickadiaSetupIfNeeded();
    } catch (error) {
      this.appendLog(`Brickadia setup prompt failed: ${this.errorMessage(error)}`);
    }
  }

  private loadStoredMode(): void {
    try {
      const stored = localStorage.getItem(this.modeStorageKey);
      if (stored === 'easy' || stored === 'advanced') {
        this.appMode.set(stored);
      }
    } catch {
    }
  }

  private storeMode(mode: AppMode): void {
    try {
      localStorage.setItem(this.modeStorageKey, mode);
    } catch {
    }
  }

  private async promptForBrickadiaSetupIfNeeded(): Promise<void> {
    const api = (window as DesktopWindow).bmfDesktop;
    if (!api || this.appMode() !== 'easy' || !this.easyProfileSetupNeeded() || this.brickadiaSetupPrompted()) return;
    this.storeBrickadiaSetupPrompted();
    await this.setupProfileFromBrickadiaInstall();
  }

  private brickadiaSetupPrompted(): boolean {
    try {
      return localStorage.getItem('bmf-desktop.brickadiaSetupPrompted') === 'true';
    } catch {
      return true;
    }
  }

  private storeBrickadiaSetupPrompted(): void {
    try {
      localStorage.setItem('bmf-desktop.brickadiaSetupPrompted', 'true');
    } catch {
    }
  }

  private async ensureSelectedProfileLoaded(): Promise<void> {
    if (this.profileRegistry() || this.profileFormDirty()) return;
    await this.refreshProfiles();
  }

  private errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
  }

  private currentProfilePath(field: DesktopProfilePathField): string | null {
    switch (field) {
      case 'brickadiaWin64':
        return this.nullableText(this.brickadiaWin64Path());
      case 'omeggaRuntime':
        return this.nullableText(this.omeggaRuntimePath());
      case 'omeggaStartScript':
        return this.nullableText(this.omeggaStartScriptPath());
      case 'bmfRoot':
        return this.nullableText(this.bmfRootPath());
      case 'bmfRuntimeDir':
        return this.nullableText(this.bmfRuntimeDirPath());
      case 'grafanaAlloyExecutable':
        return this.nullableText(this.grafanaAlloyExecutablePath());
      case 'grafanaAlloyConfig':
        return this.nullableText(this.grafanaAlloyConfigPath());
    }
  }

  private setProfilePath(field: DesktopProfilePathField, value: string): void {
    switch (field) {
      case 'brickadiaWin64':
        this.brickadiaWin64Path.set(value);
        break;
      case 'omeggaRuntime':
        this.omeggaRuntimePath.set(value);
        break;
      case 'omeggaStartScript':
        this.omeggaStartScriptPath.set(value);
        break;
      case 'bmfRoot':
        this.bmfRootPath.set(value);
        break;
      case 'bmfRuntimeDir':
        this.bmfRuntimeDirPath.set(value);
        break;
      case 'grafanaAlloyExecutable':
        this.grafanaAlloyExecutablePath.set(value);
        break;
      case 'grafanaAlloyConfig':
        this.grafanaAlloyConfigPath.set(value);
        break;
    }
  }

  private usableDashboardUrl(value: string | null | undefined): string | null {
    const url = this.nullableText(value);
    if (!url) return null;
    return this.isUnverifiedLocalGrafanaUrl(url) ? null : url;
  }

  private isUnverifiedLocalGrafanaUrl(value: string): boolean {
    try {
      const url = new URL(value);
      return ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) && url.port === '3000';
    } catch {
      return false;
    }
  }

  private nullableText(value: string | null | undefined): string | null {
    const text = String(value || '').trim();
    return text || null;
  }

  private numberValue(value: string, fallback: number): number {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  private resetTrafficPage(): void {
    this.trafficPageIndex.set(0);
  }

  private pageSlice<T>(items: T[], requestedPage: number): T[] {
    const page = this.clampPage(requestedPage, items.length);
    const start = page * this.pageSize;
    return items.slice(start, start + this.pageSize);
  }

  private pageCount(total: number): number {
    return Math.max(1, Math.ceil(total / this.pageSize));
  }

  private pageSummary(total: number, requestedPage: number): string {
    if (total === 0) return '0-0 of 0';
    const page = this.clampPage(requestedPage, total);
    const start = page * this.pageSize;
    const end = Math.min(start + this.pageSize, total);
    return `${start + 1}-${end} of ${total}`;
  }

  private clampPage(requestedPage: number, total: number): number {
    const lastPage = this.pageCount(total) - 1;
    return Math.max(0, Math.min(lastPage, requestedPage));
  }

  private compareTimestampDesc(left: string, right: string): number {
    return this.timestampMs(right) - this.timestampMs(left);
  }

  private timestampMs(value: string): number {
    const parsed = Date.parse(value || '');
    return Number.isFinite(parsed) ? parsed : 0;
  }

  private utcClockTime(): string {
    return `${new Date().toISOString().slice(11, 19)}Z`;
  }
}
