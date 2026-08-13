import type Webserver from './index';
import type { Request, Response } from 'express';
import { existsSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';

const METRICS_CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

type MetricLine = {
  name: string;
  value: number | boolean | null | undefined;
  labels?: Record<string, string | number | boolean | null | undefined>;
};

type BmfRuntimeStatus = Record<string, unknown>;
type BmfRuntimeTelemetry = Record<string, unknown>;
type BmfFrameTelemetry = Record<string, unknown>;

const boolGauge = (value: unknown) => (value ? 1 : 0);

const finiteNumber = (value: unknown, fallback = 0) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const finiteMetricValue = (value: unknown) => finiteNumber(value, NaN);

const labelValue = (value: unknown) =>
  String(value ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/\n/g, '\\n')
    .replace(/"/g, '\\"');

const labelSet = (
  labels?: Record<string, string | number | boolean | null | undefined>,
) => {
  if (!labels) return '';
  const entries = Object.entries(labels).filter(
    ([, value]) => value !== undefined && value !== null,
  );
  if (entries.length === 0) return '';
  return `{${entries
    .map(([key, value]) => `${key}="${labelValue(value)}"`)
    .join(',')}}`;
};

const metric = ({ name, value, labels }: MetricLine) => {
  const numeric = typeof value === 'boolean' ? boolGauge(value) : Number(value);
  if (!Number.isFinite(numeric)) return '';
  return `${name}${labelSet(labels)} ${numeric}`;
};

const section = (name: string, help: string, type = 'gauge') => [
  `# HELP ${name} ${help}`,
  `# TYPE ${name} ${type}`,
];

const metricBlock = (
  name: string,
  help: string,
  lines: MetricLine[],
  type = 'gauge',
) => {
  const values = lines.map(line => metric(line)).filter(Boolean);
  if (values.length === 0) return [];
  return [...section(name, help, type), ...values];
};

const uniquePaths = (candidates: Array<string | undefined>) =>
  Array.from(
    new Set(candidates.map(candidate => candidate?.trim()).filter(Boolean)),
  ) as string[];

const objectRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};

const durationMetricLines = (
  metricName: string,
  labels: Record<string, string | number | boolean | null | undefined>,
  source: Record<string, unknown>,
): MetricLine[] => {
  const count = finiteNumber(source.count, 0);
  const sum = finiteNumber(source.duration_ms_sum, 0);
  return [
    {
      name: metricName,
      labels: { ...labels, statistic: 'avg' },
      value: count > 0 ? sum / count : NaN,
    },
    {
      name: metricName,
      labels: { ...labels, statistic: 'max' },
      value: finiteMetricValue(source.duration_ms_max),
    },
    {
      name: metricName,
      labels: { ...labels, statistic: 'last' },
      value: finiteMetricValue(source.last_ms),
    },
  ];
};

const prefixedDurationMetricLines = (
  metricName: string,
  labels: Record<string, string | number | boolean | null | undefined>,
  source: Record<string, unknown>,
  prefix: string,
  countField = `${prefix}_calls`,
): MetricLine[] => {
  const count = finiteNumber(source[countField], 0);
  const sum = finiteNumber(source[`${prefix}_duration_ms_sum`], 0);
  return [
    {
      name: metricName,
      labels: { ...labels, statistic: 'avg' },
      value: count > 0 ? sum / count : NaN,
    },
    {
      name: metricName,
      labels: { ...labels, statistic: 'max' },
      value: finiteMetricValue(source[`${prefix}_duration_ms_max`]),
    },
    {
      name: metricName,
      labels: { ...labels, statistic: 'last' },
      value: finiteMetricValue(source[`${prefix}_last_ms`]),
    },
  ];
};

const outcomeMetricLines = (
  metricName: string,
  labels: Record<string, string | number | boolean | null | undefined>,
  source: Record<string, unknown>,
): MetricLine[] => [
  {
    name: metricName,
    labels: { ...labels, status: 'ok' },
    value: finiteMetricValue(source.ok),
  },
  {
    name: metricName,
    labels: { ...labels, status: 'error' },
    value: finiteMetricValue(source.error),
  },
];

const readRuntimeJson = <T extends Record<string, unknown>>(
  candidates: string[],
) => {
  for (const candidate of candidates) {
    try {
      if (!existsSync(candidate)) continue;
      const parsed = JSON.parse(readFileSync(candidate, 'utf8')) as T;
      return {
        path: candidate,
        mtimeMs: statSync(candidate).mtimeMs,
        data: parsed,
      };
    } catch (_error) {
      return {
        path: candidate,
        mtimeMs: 0,
        data: null,
      };
    }
  }
  return {
    path: '',
    mtimeMs: 0,
    data: null,
  };
};

const statusPathCandidates = (server: Webserver) => {
  const configured = process.env.OMEGGA_BMF_STATUS_PATH?.trim();
  const beta = String(server.omegga.config?.server?.steambeta || 'main');
  const appData = process.env.APPDATA;
  return uniquePaths([
    configured,
    appData
      ? path.join(
          appData,
          'omegga',
          'steam_installs',
          beta,
          'Brickadia',
          'Binaries',
          'Win64',
          'ue4ss',
          'main',
          'Mods',
          'BMF',
          'runtime',
          'status.json',
        )
      : '',
    path.join(
      server.omegga.path,
      'Brickadia',
      'Binaries',
      'Win64',
      'ue4ss',
      'main',
      'Mods',
      'BMF',
      'runtime',
      'status.json',
    ),
  ]);
};

const telemetryPathCandidates = (server: Webserver, statusPath = '') => {
  const configured = process.env.OMEGGA_BMF_TELEMETRY_PATH?.trim();
  const beta = String(server.omegga.config?.server?.steambeta || 'main');
  const appData = process.env.APPDATA;
  return uniquePaths([
    configured,
    statusPath ? path.join(path.dirname(statusPath), 'telemetry.json') : '',
    appData
      ? path.join(
          appData,
          'omegga',
          'steam_installs',
          beta,
          'Brickadia',
          'Binaries',
          'Win64',
          'ue4ss',
          'main',
          'Mods',
          'BMF',
          'runtime',
          'telemetry.json',
        )
      : '',
    path.join(
      server.omegga.path,
      'Brickadia',
      'Binaries',
      'Win64',
      'ue4ss',
      'main',
      'Mods',
      'BMF',
      'runtime',
      'telemetry.json',
    ),
  ]);
};

const frameTelemetryPathCandidates = (server: Webserver, statusPath = '') => {
  const configured = process.env.OMEGGA_BMF_FRAME_TELEMETRY_PATH?.trim();
  const beta = String(server.omegga.config?.server?.steambeta || 'main');
  const appData = process.env.APPDATA;
  return uniquePaths([
    configured,
    statusPath
      ? path.join(path.dirname(statusPath), 'frame-telemetry.json')
      : '',
    appData
      ? path.join(
          appData,
          'omegga',
          'steam_installs',
          beta,
          'Brickadia',
          'Binaries',
          'Win64',
          'ue4ss',
          'main',
          'Mods',
          'BMF',
          'runtime',
          'frame-telemetry.json',
        )
      : '',
    path.join(
      server.omegga.path,
      'Brickadia',
      'Binaries',
      'Win64',
      'ue4ss',
      'main',
      'Mods',
      'BMF',
      'runtime',
      'frame-telemetry.json',
    ),
  ]);
};

const readBmfRuntimeStatus = (server: Webserver) => {
  const runtime = readRuntimeJson<BmfRuntimeStatus>(
    statusPathCandidates(server),
  );
  return {
    path: runtime.path,
    mtimeMs: runtime.mtimeMs,
    status: runtime.data,
  };
};

const readBmfRuntimeTelemetry = (server: Webserver, statusPath = '') => {
  const runtime = readRuntimeJson<BmfRuntimeTelemetry>(
    telemetryPathCandidates(server, statusPath),
  );
  return {
    path: runtime.path,
    mtimeMs: runtime.mtimeMs,
    telemetry: runtime.data,
  };
};

const readBmfFrameTelemetry = (server: Webserver, statusPath = '') => {
  const runtime = readRuntimeJson<BmfFrameTelemetry>(
    frameTelemetryPathCandidates(server, statusPath),
  );
  return {
    path: runtime.path,
    mtimeMs: runtime.mtimeMs,
    telemetry: runtime.data,
  };
};

const isLocalRequest = (req: Request) => {
  if (process.env.OMEGGA_METRICS_ALLOW_REMOTE === '1') return true;
  const remote = req.socket.remoteAddress || '';
  const normalized = remote.replace(/^::ffff:/, '');
  return normalized === '127.0.0.1' || normalized === '::1';
};

const assertMetricsAccess = (req: Request, res: Response) => {
  if (!isLocalRequest(req)) {
    res
      .status(403)
      .type('text/plain')
      .send('metrics endpoint is localhost-only\n');
    return false;
  }

  const token = process.env.OMEGGA_METRICS_TOKEN;
  if (!token) return true;

  const auth = req.header('authorization') || '';
  if (auth === `Bearer ${token}`) return true;

  res.status(401).type('text/plain').send('metrics token required\n');
  return false;
};

export function buildPrometheusMetrics(server: Webserver) {
  const status = server.lastReportedStatus;
  const players = status?.players || [];
  const playerPings = players
    .map(player => finiteNumber(player.ping, NaN) / 1000)
    .filter(Number.isFinite);
  const pingSum = playerPings.reduce((sum, value) => sum + value, 0);
  const pingAvg = playerPings.length > 0 ? pingSum / playerPings.length : 0;
  const pingMax = playerPings.length > 0 ? Math.max(...playerPings) : 0;
  const uptimeSeconds = status ? finiteNumber(status.time) / 1000 : 0;
  const lastStatusAt = finiteNumber(server.lastReportedStatusAt, 0);
  const statusPollDurationSeconds =
    finiteNumber(server.lastServerStatusPollDurationMs, 0) / 1000;
  const statusPollMetrics = server.serverStatusPollMetrics;
  const statusPollCount = finiteNumber(statusPollMetrics?.count, 0);
  const statusPollDurationStatLines: MetricLine[] = [
    {
      name: 'omegga_server_status_poll_duration_stat_seconds',
      labels: { statistic: 'avg' },
      value:
        statusPollCount > 0
          ? finiteNumber(statusPollMetrics.durationMsSum, 0) /
            statusPollCount /
            1000
          : NaN,
    },
    {
      name: 'omegga_server_status_poll_duration_stat_seconds',
      labels: { statistic: 'max' },
      value: finiteMetricValue(statusPollMetrics?.durationMsMax) / 1000,
    },
    {
      name: 'omegga_server_status_poll_duration_stat_seconds',
      labels: { statistic: 'last' },
      value: finiteMetricValue(statusPollMetrics?.lastMs) / 1000,
    },
  ];
  const now = Date.now();
  const memory = process.memoryUsage();
  const cpu = process.cpuUsage();
  const getJoinCorrelationMetrics = server.omegga?.getJoinCorrelationMetrics;
  const joinCorrelation =
    typeof getJoinCorrelationMetrics === 'function'
      ? getJoinCorrelationMetrics.call(server.omegga)
      : { enabled: false, droppedWrites: 0, phases: {} };
  const joinCorrelationPhases = objectRecord(joinCorrelation.phases);
  const bmf = readBmfRuntimeStatus(server);
  const bmfStatus = bmf.status;
  const bmfFileAgeSeconds =
    bmf.mtimeMs > 0 ? Math.max(0, (now - bmf.mtimeMs) / 1000) : 0;
  const bmfTelemetryFile = readBmfRuntimeTelemetry(server, bmf.path);
  const bmfTelemetry = bmfTelemetryFile.telemetry;
  const bmfTelemetryRecord = objectRecord(bmfTelemetry);
  const bmfTelemetryAgeSeconds =
    bmfTelemetryFile.mtimeMs > 0
      ? Math.max(0, (now - bmfTelemetryFile.mtimeMs) / 1000)
      : 0;
  const bmfFrameTelemetryFile = readBmfFrameTelemetry(server, bmf.path);
  const bmfFrameTelemetry = bmfFrameTelemetryFile.telemetry;
  const bmfFrameTelemetryRecord = objectRecord(bmfFrameTelemetry);
  const bmfFrameTelemetryAgeSeconds =
    bmfFrameTelemetryFile.mtimeMs > 0
      ? Math.max(0, (now - bmfFrameTelemetryFile.mtimeMs) / 1000)
      : 0;
  const bmfInfoLabels = bmfStatus
    ? {
        version: String(bmfStatus.version || ''),
        target_build: String(bmfStatus.target_build || ''),
        compatibility_status: String(bmfStatus.compatibility_status || ''),
      }
    : undefined;
  const bmfCommandWorkerLabels = bmfStatus
    ? {
        mode: String(bmfStatus.command_worker_mode || 'unknown'),
      }
    : undefined;
  const bmfCommands = objectRecord(bmfTelemetryRecord.commands);
  const bmfCommandByName = objectRecord(bmfCommands.by_name);
  const bmfCommandByTransport = objectRecord(bmfCommands.by_transport);
  const bmfEvents = objectRecord(bmfTelemetryRecord.events);
  const bmfEventsByName = objectRecord(bmfEvents.by_event);
  const bmfPlugins = objectRecord(bmfTelemetryRecord.plugins);
  const bmfPluginsByPlugin = objectRecord(bmfPlugins.by_plugin);
  const bmfPluginsByHook = objectRecord(bmfPlugins.by_hook);
  const bmfScheduler = objectRecord(bmfTelemetryRecord.scheduler);
  const bmfSchedulerByKey = objectRecord(bmfScheduler.by_key);
  const bmfWorkers = objectRecord(bmfTelemetryRecord.workers);
  const bmfOperations = objectRecord(bmfTelemetryRecord.operations);
  const bmfOperationsByClass = objectRecord(bmfOperations.by_class);
  const bmfOperationsBySource = objectRecord(bmfOperations.by_source);
  const bmfOperationsByOutcome = objectRecord(bmfOperations.by_outcome);
  const bmfOperationsByCacheResult = objectRecord(
    bmfOperations.by_cache_result,
  );
  const bmfOperationsLast = objectRecord(bmfOperations.last);
  const bmfPlayerRegistry = objectRecord(bmfTelemetryRecord.player_registry);
  const bmfConnectionReadiness = objectRecord(
    bmfTelemetryRecord.connection_readiness,
  );
  const bmfGameCommandTunnel = objectRecord(
    bmfTelemetryRecord.game_command_tunnel,
  );
  const bmfSocketScheduler = objectRecord(bmfTelemetryRecord.socket_scheduler);
  const bmfSocketSchedulerByPath = objectRecord(bmfSocketScheduler.by_path);
  const bmfNativeDrains = objectRecord(bmfSocketScheduler.native_drains);
  const bmfNativeDrainsBySource = objectRecord(bmfNativeDrains.by_source);
  const bmfSocketIngressByType = objectRecord(
    bmfSocketScheduler.ingress_by_type,
  );
  const bmfSocketQueues = objectRecord(bmfSocketScheduler.queues);
  const bmfSocketSlice = objectRecord(bmfSocketScheduler.slice);
  const bmfFrameWindow = objectRecord(bmfFrameTelemetryRecord.window);
  const bmfFrameLifetime = objectRecord(bmfFrameTelemetryRecord.lifetime);
  const bmfFrameSpikes = objectRecord(bmfFrameTelemetryRecord.spikes);
  const bmfFrameLastSpike = objectRecord(bmfFrameSpikes.last);
  const bmfFramePacing = objectRecord(bmfFrameTelemetryRecord.pacing);
  const bmfFrameLastSpikeAtMs = finiteNumber(
    bmfFrameLastSpike.observed_at_unix_ms,
    0,
  );
  const omeggaConsoleCommands = objectRecord(
    server.omegga.consoleCommandMetrics,
  );
  const ue4ssAdmission = objectRecord(
    server.omegga.getWindowsControlAdmissionStatus?.(),
  );
  const ue4ssWriteQueue = objectRecord(ue4ssAdmission.writeQueue);
  const ue4ssWriteLimits = objectRecord(ue4ssWriteQueue.limits);
  const ue4ssWritePending = objectRecord(ue4ssWriteQueue.pending);
  const ue4ssWriteAdmitted = objectRecord(ue4ssWriteQueue.admitted);
  const ue4ssWriteRejected = objectRecord(ue4ssWriteQueue.rejected);
  const ue4ssWriteHighWater = objectRecord(ue4ssWriteQueue.highWater);
  const ue4ssInbox = objectRecord(ue4ssAdmission.ue4ssInbox);
  const ue4ssInboxLimits = objectRecord(ue4ssInbox.limits);
  const ue4ssInboxPending = objectRecord(ue4ssInbox.pending);
  const ue4ssInboxAdmitted = objectRecord(ue4ssInbox.admitted);
  const ue4ssInboxRejected = objectRecord(ue4ssInbox.rejected);
  const ue4ssInboxHighWater = objectRecord(ue4ssInbox.highWater);
  const ue4ssRuntime = objectRecord(ue4ssAdmission.ue4ssRuntime);
  const ue4ssAdmissionEnabledLines: MetricLine[] = [
    {
      name: 'omegga_ue4ss_admission_enabled',
      labels: { stage: 'write_queue' },
      value:
        typeof ue4ssWriteLimits.enabled === 'boolean'
          ? boolGauge(ue4ssWriteLimits.enabled)
          : NaN,
    },
    {
      name: 'omegga_ue4ss_admission_enabled',
      labels: { stage: 'node_inbox' },
      value:
        typeof ue4ssInboxLimits.enabled === 'boolean'
          ? boolGauge(ue4ssInboxLimits.enabled)
          : NaN,
    },
    {
      name: 'omegga_ue4ss_admission_enabled',
      labels: { stage: 'ue4ss_runtime' },
      value:
        typeof ue4ssRuntime.enabled === 'boolean'
          ? boolGauge(ue4ssRuntime.enabled)
          : NaN,
    },
  ];
  const ue4ssQueueDepthLines: MetricLine[] = [
    ['write_queue', 'interactive', ue4ssWritePending.interactiveDepth],
    ['write_queue', 'bulk', ue4ssWritePending.bulkDepth],
    ['write_queue', 'exempt', ue4ssWritePending.exemptDepth],
    ['write_queue', 'total', ue4ssWritePending.totalDepth],
    ['node_inbox', 'interactive', ue4ssInboxPending.interactiveRequests],
    ['node_inbox', 'bulk', ue4ssInboxPending.bulkRequests],
    ['node_inbox', 'exempt', ue4ssInboxPending.exemptRequests],
    ['node_inbox', 'total', ue4ssInboxPending.totalRequests],
  ].map(([stage, serviceClass, value]) => ({
    name: 'omegga_ue4ss_queue_depth',
    labels: { stage: String(stage), service_class: String(serviceClass) },
    value: finiteMetricValue(value),
  }));
  const ue4ssQueueByteLines: MetricLine[] = [
    ['write_queue', 'interactive', ue4ssWritePending.interactiveBytes],
    ['write_queue', 'bulk', ue4ssWritePending.bulkBytes],
    ['write_queue', 'exempt', ue4ssWritePending.exemptBytes],
    ['write_queue', 'total', ue4ssWritePending.totalBytes],
    ['node_inbox', 'interactive', ue4ssInboxPending.interactiveBytes],
    ['node_inbox', 'bulk', ue4ssInboxPending.bulkBytes],
    ['node_inbox', 'exempt', ue4ssInboxPending.exemptBytes],
    ['node_inbox', 'total', ue4ssInboxPending.totalBytes],
    ['ue4ss_runtime', 'total', ue4ssRuntime.pendingBytes],
  ].map(([stage, serviceClass, value]) => ({
    name: 'omegga_ue4ss_queue_bytes',
    labels: { stage: String(stage), service_class: String(serviceClass) },
    value: finiteMetricValue(value),
  }));
  const ue4ssQueueAgeLines: MetricLine[] = [
    {
      name: 'omegga_ue4ss_queue_oldest_age_milliseconds',
      labels: { stage: 'write_queue' },
      value: finiteMetricValue(ue4ssWritePending.oldestAgeMs),
    },
    {
      name: 'omegga_ue4ss_queue_oldest_age_milliseconds',
      labels: { stage: 'node_inbox' },
      value: finiteMetricValue(ue4ssInboxPending.oldestAgeMs),
    },
    {
      name: 'omegga_ue4ss_queue_oldest_age_milliseconds',
      labels: { stage: 'ue4ss_runtime' },
      value: finiteMetricValue(ue4ssRuntime.lastQueueAgeMs),
    },
  ];
  const ue4ssQueueHighWaterLines: MetricLine[] = [
    ['write_queue', 'depth', ue4ssWriteHighWater.depth],
    ['write_queue', 'bytes', ue4ssWriteHighWater.bytes],
    ['node_inbox', 'depth', ue4ssInboxHighWater.requests],
    ['node_inbox', 'bytes', ue4ssInboxHighWater.bytes],
    ['ue4ss_runtime', 'bytes', ue4ssRuntime.pendingBytesHighWater],
  ].map(([stage, unit, value]) => ({
    name: 'omegga_ue4ss_queue_high_water',
    labels: { stage: String(stage), unit: String(unit) },
    value: finiteMetricValue(value),
  }));
  const ue4ssAdmittedLines: MetricLine[] = [
    ['write_queue', 'interactive', ue4ssWriteAdmitted.interactive],
    ['write_queue', 'bulk', ue4ssWriteAdmitted.bulk],
    ['write_queue', 'exempt', ue4ssWriteAdmitted.exempt],
    ['node_inbox', 'interactive', ue4ssInboxAdmitted.interactive],
    ['node_inbox', 'bulk', ue4ssInboxAdmitted.bulk],
    ['node_inbox', 'exempt', ue4ssInboxAdmitted.exempt],
    ['ue4ss_runtime', 'interactive', ue4ssRuntime.admittedInteractive],
    ['ue4ss_runtime', 'bulk', ue4ssRuntime.admittedBulk],
  ].map(([stage, serviceClass, value]) => ({
    name: 'omegga_ue4ss_admitted_total',
    labels: { stage: String(stage), service_class: String(serviceClass) },
    value: finiteMetricValue(value),
  }));
  const ue4ssRejectedLines: MetricLine[] = [
    ['write_queue', 'depth', ue4ssWriteRejected.depth],
    ['write_queue', 'bytes', ue4ssWriteRejected.bytes],
    ['node_inbox', 'depth', ue4ssInboxRejected.depth],
    ['node_inbox', 'bytes', ue4ssInboxRejected.bytes],
    ['ue4ss_runtime', 'oversize', ue4ssRuntime.oversize],
    ['ue4ss_runtime', 'bmf_dispatch', ue4ssRuntime.bmfDispatchBlocked],
  ].map(([stage, reason, value]) => ({
    name: 'omegga_ue4ss_rejected_total',
    labels: { stage: String(stage), reason: String(reason) },
    value: finiteMetricValue(value),
  }));
  const omeggaConsoleCommandSentLines = Object.entries(
    omeggaConsoleCommands,
  ).map(([key, value]) => {
    const record = objectRecord(value);
    return {
      name: 'omegga_console_command_sent_total',
      labels: { command: String(record.command ?? key) },
      value: finiteMetricValue(record.count),
    };
  });
  const omeggaConsoleCommandAgeLines = Object.entries(
    omeggaConsoleCommands,
  ).map(([key, value]) => {
    const record = objectRecord(value);
    const lastAtMs = finiteNumber(record.lastAtMs, 0);
    return {
      name: 'omegga_console_command_last_sent_age_seconds',
      labels: { command: String(record.command ?? key) },
      value: lastAtMs > 0 ? Math.max(0, (now - lastAtMs) / 1000) : NaN,
    };
  });

  const bmfCommandProcessedLines = Object.entries(bmfCommandByName).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const command = String(record.command ?? key);
      return outcomeMetricLines(
        'bmf_command_processed_total',
        { command },
        record,
      );
    },
  );
  const bmfCommandDurationLines = Object.entries(bmfCommandByName).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const command = String(record.command ?? key);
      return durationMetricLines(
        'bmf_command_duration_milliseconds',
        { command },
        record,
      );
    },
  );
  const bmfCommandTransportLines = Object.entries(
    bmfCommandByTransport,
  ).flatMap(([key, value]) => {
    const record = objectRecord(value);
    const transport = String(record.transport ?? key);
    return outcomeMetricLines(
      'bmf_command_transport_total',
      { transport },
      record,
    );
  });
  const bmfCommandTransportDurationLines = Object.entries(
    bmfCommandByTransport,
  ).flatMap(([key, value]) => {
    const record = objectRecord(value);
    const transport = String(record.transport ?? key);
    return durationMetricLines(
      'bmf_command_transport_duration_milliseconds',
      { transport },
      record,
    );
  });
  const bmfEventTotalLines = Object.entries(bmfEventsByName).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const event = String(record.event ?? key);
      return outcomeMetricLines('bmf_event_emitted_total', { event }, record);
    },
  );
  const bmfEventDurationLines = Object.entries(bmfEventsByName).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const event = String(record.event ?? key);
      return durationMetricLines(
        'bmf_event_duration_milliseconds',
        { event },
        record,
      );
    },
  );
  const bmfEventHandlerTotalLines = Object.entries(bmfEventsByName).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const event = String(record.event ?? key);
      const handlers = finiteNumber(record.handler_calls, 0);
      const errors = finiteNumber(record.handler_errors, 0);
      return [
        {
          name: 'bmf_event_handler_total',
          labels: { event, status: 'ok' },
          value: Math.max(0, handlers - errors),
        },
        {
          name: 'bmf_event_handler_total',
          labels: { event, status: 'error' },
          value: errors,
        },
      ];
    },
  );
  const bmfEventHandlerDurationLines = Object.entries(bmfEventsByName).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const event = String(record.event ?? key);
      return prefixedDurationMetricLines(
        'bmf_event_handler_duration_milliseconds',
        { event },
        record,
        'handler',
      );
    },
  );
  const bmfPluginTotalLines = Object.entries(bmfPluginsByPlugin).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const plugin = String(record.plugin ?? key);
      return outcomeMetricLines('bmf_plugin_lua_total', { plugin }, record);
    },
  );
  const bmfPluginDurationLines = Object.entries(bmfPluginsByPlugin).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      const plugin = String(record.plugin ?? key);
      return durationMetricLines(
        'bmf_plugin_lua_duration_milliseconds',
        { plugin },
        record,
      );
    },
  );
  const bmfPluginHookTotalLines = Object.entries(bmfPluginsByHook).flatMap(
    ([_key, value]) => {
      const record = objectRecord(value);
      return outcomeMetricLines(
        'bmf_plugin_hook_total',
        {
          plugin: String(record.plugin ?? 'unknown'),
          hook: String(record.hook ?? 'unknown'),
        },
        record,
      );
    },
  );
  const bmfPluginHookDurationLines = Object.entries(bmfPluginsByHook).flatMap(
    ([_key, value]) => {
      const record = objectRecord(value);
      return durationMetricLines(
        'bmf_plugin_hook_duration_milliseconds',
        {
          plugin: String(record.plugin ?? 'unknown'),
          hook: String(record.hook ?? 'unknown'),
        },
        record,
      );
    },
  );
  const bmfSchedulerTotalLines = Object.entries(bmfSchedulerByKey).flatMap(
    ([_key, value]) => {
      const record = objectRecord(value);
      return outcomeMetricLines(
        'bmf_scheduler_callback_total',
        {
          kind: String(record.kind ?? 'callback'),
          name: String(record.name ?? 'unknown'),
        },
        record,
      );
    },
  );
  const bmfSchedulerDurationLines = Object.entries(bmfSchedulerByKey).flatMap(
    ([_key, value]) => {
      const record = objectRecord(value);
      return durationMetricLines(
        'bmf_scheduler_callback_duration_milliseconds',
        {
          kind: String(record.kind ?? 'callback'),
          name: String(record.name ?? 'unknown'),
        },
        record,
      );
    },
  );
  const bmfWorkerTotalLines = Object.entries(bmfWorkers).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      return outcomeMetricLines(
        'bmf_worker_poll_total',
        { worker: key },
        record,
      );
    },
  );
  const bmfWorkerDurationLines = Object.entries(bmfWorkers).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      return durationMetricLines(
        'bmf_worker_poll_duration_milliseconds',
        { worker: key },
        record,
      );
    },
  );
  const bmfWorkerItemLines = Object.entries(bmfWorkers).flatMap(
    ([key, value]) => {
      const record = objectRecord(value);
      return [
        {
          name: 'bmf_worker_items_total',
          labels: { worker: key, item: 'files_processed' },
          value: finiteMetricValue(record.files_processed),
        },
        {
          name: 'bmf_worker_items_total',
          labels: { worker: key, item: 'messages' },
          value: finiteMetricValue(record.messages),
        },
      ];
    },
  );
  const bmfSocketPaths = ['direct_socket', 'tunnel'] as const;
  const bmfSocketWorkTotalLines = bmfSocketPaths.flatMap(pathName => {
    const record = objectRecord(bmfSocketSchedulerByPath[pathName]);
    return outcomeMetricLines(
      'bmf_socket_work_total',
      { path: pathName },
      record,
    );
  });
  const bmfSocketWorkDurationLines = bmfSocketPaths.flatMap(pathName => {
    const record = objectRecord(bmfSocketSchedulerByPath[pathName]);
    return durationMetricLines(
      'bmf_socket_work_duration_milliseconds',
      { path: pathName },
      record,
    );
  });
  const bmfSocketAdmissionLines = bmfSocketPaths.map(pathName => ({
    name: 'bmf_socket_admitted_total',
    labels: { path: pathName },
    value: finiteMetricValue(
      objectRecord(bmfSocketSchedulerByPath[pathName]).admitted,
    ),
  }));
  const bmfSocketMonolithicOverrunLines = bmfSocketPaths.map(pathName => ({
    name: 'bmf_game_thread_monolithic_overrun_total',
    labels: { path: pathName },
    value: finiteMetricValue(
      objectRecord(bmfSocketSchedulerByPath[pathName]).monolithic_overruns,
    ),
  }));
  const bmfSocketIngressTypes = [
    ['command', 'command'],
    ['tunnel_request', 'tunnel.request'],
    ['ping', 'ping'],
    ['other', 'other'],
  ] as const;
  const bmfSocketIngressTypeLines = bmfSocketIngressTypes.map(
    ([recordName, messageType]) => ({
      name: 'bmf_socket_ingress_messages_total',
      labels: { type: messageType },
      value: finiteMetricValue(
        objectRecord(bmfSocketIngressByType[recordName]).count,
      ),
    }),
  );
  const bmfNativeDrainSources = ['tree', 'zone'] as const;
  const bmfNativeDrainOutcomeLines: MetricLine[] =
    bmfNativeDrainSources.flatMap(source => {
      const record = objectRecord(bmfNativeDrainsBySource[source]);
      return [
        ['attempted', 'attempted'],
        ['drained', 'drained'],
        ['skipped', 'skipped'],
        ['overrun', 'overruns'],
      ].map(([outcome, field]) => ({
        name: 'bmf_native_event_drain_total',
        labels: { source, outcome },
        value: finiteMetricValue(record[field]),
      }));
    });
  const bmfNativeDrainDepthLines: MetricLine[] = bmfNativeDrainSources.flatMap(
    source => {
      const record = objectRecord(bmfNativeDrainsBySource[source]);
      if (record.depth_available !== true) return [];
      return [
        {
          name: 'bmf_native_event_queue_depth',
          labels: { source },
          value: finiteMetricValue(record.depth),
        },
      ];
    },
  );
  const bmfSocketQueueLines: MetricLine[] = [
    {
      name: 'bmf_socket_queue_depth',
      labels: { path: 'direct_socket', service_class: 'direct' },
      value: finiteMetricValue(bmfSocketQueues.direct_depth),
    },
    {
      name: 'bmf_socket_queue_depth',
      labels: { path: 'direct_socket', service_class: 'interactive' },
      value: finiteMetricValue(bmfSocketQueues.direct_interactive_depth),
    },
    {
      name: 'bmf_socket_queue_depth',
      labels: { path: 'direct_socket', service_class: 'bulk' },
      value: finiteMetricValue(bmfSocketQueues.direct_bulk_depth),
    },
    {
      name: 'bmf_socket_queue_depth',
      labels: { path: 'tunnel', service_class: 'total' },
      value: finiteMetricValue(bmfSocketQueues.tunnel_depth),
    },
    {
      name: 'bmf_socket_queue_depth',
      labels: { path: 'tunnel', service_class: 'interactive' },
      value: finiteMetricValue(bmfSocketQueues.tunnel_interactive_depth),
    },
    {
      name: 'bmf_socket_queue_depth',
      labels: { path: 'tunnel', service_class: 'bulk' },
      value: finiteMetricValue(bmfSocketQueues.tunnel_bulk_depth),
    },
  ];
  const bmfSocketQueueAgeLines: MetricLine[] = [
    {
      name: 'bmf_socket_queue_oldest_age_milliseconds',
      labels: { path: 'direct_socket', service_class: 'direct' },
      value: finiteMetricValue(bmfSocketQueues.direct_oldest_age_ms),
    },
    {
      name: 'bmf_socket_queue_oldest_age_milliseconds',
      labels: { path: 'direct_socket', service_class: 'interactive' },
      value: finiteMetricValue(
        bmfSocketQueues.direct_interactive_oldest_age_ms,
      ),
    },
    {
      name: 'bmf_socket_queue_oldest_age_milliseconds',
      labels: { path: 'direct_socket', service_class: 'bulk' },
      value: finiteMetricValue(bmfSocketQueues.direct_bulk_oldest_age_ms),
    },
    {
      name: 'bmf_socket_queue_oldest_age_milliseconds',
      labels: { path: 'tunnel', service_class: 'total' },
      value: finiteMetricValue(bmfSocketQueues.tunnel_oldest_age_ms),
    },
    {
      name: 'bmf_socket_queue_oldest_age_milliseconds',
      labels: { path: 'tunnel', service_class: 'interactive' },
      value: finiteMetricValue(
        bmfSocketQueues.tunnel_interactive_oldest_age_ms,
      ),
    },
    {
      name: 'bmf_socket_queue_oldest_age_milliseconds',
      labels: { path: 'tunnel', service_class: 'bulk' },
      value: finiteMetricValue(bmfSocketQueues.tunnel_bulk_oldest_age_ms),
    },
  ];
  const bmfSocketQueueHighWaterLines: MetricLine[] = [
    ['direct_socket', 'direct', 'direct_peak_depth'],
    ['direct_socket', 'interactive', 'direct_interactive_peak_depth'],
    ['direct_socket', 'bulk', 'direct_bulk_peak_depth'],
    ['tunnel', 'total', 'tunnel_peak_depth'],
    ['tunnel', 'interactive', 'tunnel_interactive_peak_depth'],
    ['tunnel', 'bulk', 'tunnel_bulk_peak_depth'],
  ].map(([pathName, serviceClass, field]) => ({
    name: 'bmf_socket_queue_high_watermark',
    labels: { path: pathName, service_class: serviceClass },
    value: finiteMetricValue(bmfSocketQueues[field]),
  }));
  const bmfSocketAdmissionOutcomeLines: MetricLine[] = bmfSocketPaths.flatMap(
    pathName => {
      const record = objectRecord(bmfSocketSchedulerByPath[pathName]);
      return [
        ['accepted', 'admitted'],
        ['rejected', 'rejected'],
        ['dropped', 'dropped'],
        ['expired', 'expired'],
      ].map(([outcome, field]) => ({
        name: 'bmf_socket_admission_outcome_total',
        labels: { path: pathName, outcome },
        value: finiteMetricValue(record[field]),
      }));
    },
  );
  const bmfSocketTerminalLines: MetricLine[] = bmfSocketPaths.flatMap(
    pathName => {
      const record = objectRecord(bmfSocketSchedulerByPath[pathName]);
      return [
        ['completed', 'terminal_completed'],
        ['failed', 'terminal_failed'],
        ['rejected', 'terminal_rejected'],
        ['expired', 'terminal_expired'],
        ['outcome_unknown', 'terminal_outcome_unknown'],
      ].map(([resultState, field]) => ({
        name: 'bmf_socket_terminal_total',
        labels: { path: pathName, state: resultState },
        value: finiteMetricValue(record[field]),
      }));
    },
  );
  const bmfSocketFairnessLines: MetricLine[] = bmfSocketPaths.flatMap(
    pathName => {
      const fairness = objectRecord(
        objectRecord(bmfSocketSchedulerByPath[pathName]).fairness,
      );
      return ['interactive', 'bulk'].map(serviceClass => ({
        name: 'bmf_socket_fairness_selection_total',
        labels: { path: pathName, service_class: serviceClass },
        value: finiteMetricValue(fairness[serviceClass]),
      }));
    },
  );
  const bmfPlayerRegistryBooleanMetricDefinitions = [
    [
      'bmf_player_registry_cache_first_enabled',
      'Whether cache-first player resolution is enabled.',
      'cache_first_enabled',
    ],
    [
      'bmf_player_registry_repair_enabled',
      'Whether player-registry repair is enabled.',
      'repair_enabled',
    ],
    [
      'bmf_player_registry_legacy_discovery_enabled',
      'Whether legacy broad player discovery is enabled.',
      'legacy_discovery_enabled',
    ],
    [
      'bmf_player_registry_cache_loaded',
      'Whether the persisted player-registry cache loaded successfully.',
      'cache_loaded',
    ],
    [
      'bmf_player_registry_repair_running',
      'Whether a player-registry repair is currently running.',
      'repair_running',
    ],
  ] as const;
  const bmfPlayerRegistryGaugeMetricDefinitions = [
    [
      'bmf_player_registry_generation',
      'Current player-registry generation.',
      'generation',
    ],
    [
      'bmf_player_registry_entries',
      'Current number of cached player-registry entries.',
      'entries',
    ],
    [
      'bmf_player_registry_repair_cooldown_milliseconds',
      'Configured player-registry repair cooldown in milliseconds.',
      'repair_cooldown_ms',
    ],
    [
      'bmf_player_registry_unresolved_players',
      'Current unresolved players in the player-registry snapshot.',
      'unresolved_players',
    ],
    [
      'bmf_player_registry_repair_backoff_milliseconds',
      'Current bounded player-registry repair backoff.',
      'repair_backoff_ms',
    ],
    [
      'bmf_player_registry_repair_failure_streak',
      'Current consecutive player-registry repair failure count.',
      'repair_failure_streak',
    ],
  ] as const;
  const bmfPlayerRegistryCounterMetricDefinitions = [
    [
      'bmf_player_registry_cache_hits_total',
      'Player-registry cache hits.',
      'cache_hits',
    ],
    [
      'bmf_player_registry_cache_misses_total',
      'Player-registry cache misses.',
      'cache_misses',
    ],
    [
      'bmf_player_registry_disk_loads_total',
      'Player-registry disk cache loads.',
      'disk_loads',
    ],
    [
      'bmf_player_registry_disk_load_failures_total',
      'Failed player-registry disk cache loads.',
      'disk_load_failures',
    ],
    [
      'bmf_player_registry_memory_syncs_total',
      'Player-registry in-memory synchronizations.',
      'memory_syncs',
    ],
    [
      'bmf_player_registry_persisted_syncs_total',
      'Player-registry synchronizations persisted to disk.',
      'persisted_syncs',
    ],
    [
      'bmf_player_registry_controller_handle_hits_total',
      'Player-registry controller-handle cache hits.',
      'controller_handle_hits',
    ],
    [
      'bmf_player_registry_controller_handle_misses_total',
      'Player-registry controller-handle cache misses.',
      'controller_handle_misses',
    ],
    [
      'bmf_player_registry_targeted_resolutions_total',
      'Targeted player-registry resolutions.',
      'targeted_resolutions',
    ],
    [
      'bmf_player_registry_targeted_failures_total',
      'Failed targeted player-registry resolutions.',
      'targeted_failures',
    ],
    [
      'bmf_player_registry_broad_repairs_total',
      'Broad player-registry repair attempts.',
      'broad_repairs',
    ],
    [
      'bmf_player_registry_broad_repair_skipped_total',
      'Broad player-registry repairs skipped by guardrails.',
      'broad_repair_skipped',
    ],
    [
      'bmf_player_registry_broad_repair_failures_total',
      'Failed broad player-registry repairs.',
      'broad_repair_failures',
    ],
    [
      'bmf_player_registry_broad_repair_matches_total',
      'Player matches found by broad player-registry repairs.',
      'broad_repair_matches',
    ],
    [
      'bmf_player_registry_global_scans_total',
      'Global player scans performed by the player registry.',
      'global_scans',
    ],
    [
      'bmf_player_registry_repair_requests_total',
      'Explicit player-registry repair requests.',
      'repair_requests',
    ],
    [
      'bmf_player_registry_repair_coalesced_total',
      'Player-registry repair requests coalesced by an active repair or cooldown.',
      'repair_coalesced',
    ],
    [
      'bmf_player_registry_connection_generation_mismatches_total',
      'Controller resolutions rejected because the cached connection generation was not current.',
      'connection_generation_mismatches',
    ],
    [
      'bmf_private_delivery_delivered_total',
      'Private replies delivered after exact UUID and connection-generation validation.',
      'private_delivery_delivered',
    ],
    [
      'bmf_private_delivery_dropped_total',
      'Private replies dropped instead of guessing or falling back to another recipient.',
      'private_delivery_dropped',
    ],
    [
      'bmf_private_delivery_expired_total',
      'Private replies dropped because their immutable delivery deadline elapsed.',
      'private_delivery_expired',
    ],
    [
      'bmf_private_delivery_invalid_total',
      'Private replies rejected because the strict identity envelope was invalid.',
      'private_delivery_invalid',
    ],
    [
      'bmf_private_delivery_stale_total',
      'Private replies rejected because the UUID session or controller identity was stale.',
      'private_delivery_stale',
    ],
  ] as const;
  const bmfPlayerRegistryMetricBlocks = [
    ...bmfPlayerRegistryBooleanMetricDefinitions.flatMap(
      ([name, help, field]) =>
        metricBlock(name, help, [
          {
            name,
            value:
              typeof bmfPlayerRegistry[field] === 'boolean'
                ? boolGauge(bmfPlayerRegistry[field])
                : NaN,
          },
        ]),
    ),
    ...bmfPlayerRegistryGaugeMetricDefinitions.flatMap(([name, help, field]) =>
      metricBlock(name, help, [
        { name, value: finiteMetricValue(bmfPlayerRegistry[field]) },
      ]),
    ),
    ...bmfPlayerRegistryCounterMetricDefinitions.flatMap(
      ([name, help, field]) =>
        metricBlock(
          name,
          help,
          [{ name, value: finiteMetricValue(bmfPlayerRegistry[field]) }],
          'counter',
        ),
    ),
  ];
  const bmfConnectionReadinessCounterMetricDefinitions = [
    [
      'bmf_connection_readiness_path_preservations_total',
      'Validated plain controller/player-state path pairs preserved across same-session blank snapshots.',
      'pathPreservations',
    ],
    [
      'bmf_connection_readiness_path_replacements_total',
      'Retained path pairs replaced by nonblank same-session snapshot paths.',
      'pathReplacements',
    ],
    [
      'bmf_connection_readiness_path_clears_total',
      'Retained path pairs cleared on lifecycle or identity invalidation.',
      'pathClears',
    ],
    [
      'bmf_connection_readiness_path_reuses_total',
      'Preserved plain path pairs successfully re-resolved and lifecycle-validated.',
      'pathReuses',
    ],
    [
      'bmf_connection_readiness_session_repair_attempts_total',
      'Exact UUID and connection-generation repair attempts admitted by the per-session window.',
      'repairAttempts',
    ],
    [
      'bmf_connection_readiness_session_repair_deferrals_total',
      'Exact-session repair attempts deferred inside the active repair window.',
      'repairDeferrals',
    ],
  ] as const;
  const bmfConnectionReadinessMetricBlocks =
    bmfConnectionReadinessCounterMetricDefinitions.flatMap(
      ([name, help, field]) =>
        metricBlock(
          name,
          help,
          [{ name, value: finiteMetricValue(bmfConnectionReadiness[field]) }],
          'counter',
        ),
    );
  const bmfTunnelReadinessCounterMetricDefinitions = [
    ['probes', 'readiness_probes'],
    ['retries', 'readiness_retries'],
    ['deferrals', 'readiness_deferrals'],
    ['event_wakeups', 'readiness_event_wakeups'],
  ] as const;
  const bmfTunnelReadinessMetricBlocks = [
    ...metricBlock(
      'bmf_game_command_tunnel_readiness_total',
      'Game-command tunnel readiness probes, retries, deferred pump passes, and cache-sync wakeups.',
      bmfTunnelReadinessCounterMetricDefinitions.map(([outcome, field]) => ({
        name: 'bmf_game_command_tunnel_readiness_total',
        labels: { outcome },
        value: finiteMetricValue(bmfGameCommandTunnel[field]),
      })),
      'counter',
    ),
    ...metricBlock(
      'bmf_game_command_tunnel_readiness_retry_milliseconds',
      'Configured bounded readiness retry delay.',
      [
        {
          name: 'bmf_game_command_tunnel_readiness_retry_milliseconds',
          labels: { bound: 'base' },
          value: finiteMetricValue(
            bmfGameCommandTunnel.readiness_retry_base_ms,
          ),
        },
        {
          name: 'bmf_game_command_tunnel_readiness_retry_milliseconds',
          labels: { bound: 'max' },
          value: finiteMetricValue(bmfGameCommandTunnel.readiness_retry_max_ms),
        },
      ],
    ),
    ...metricBlock(
      'bmf_game_command_tunnel_readiness_retries_per_request_max',
      'Maximum readiness retries observed for one tunnel request.',
      [
        {
          name: 'bmf_game_command_tunnel_readiness_retries_per_request_max',
          value: finiteMetricValue(
            bmfGameCommandTunnel.max_readiness_retries_per_request,
          ),
        },
      ],
    ),
  ];
  const bmfPlayerRegistryDurationLines: MetricLine[] = [
    [
      'repair',
      'repair_duration_ms_sum',
      'repair_duration_ms_max',
      'broad_repairs',
    ],
    [
      'global_scan',
      'global_scan_duration_ms_sum',
      'global_scan_duration_ms_max',
      'global_scans',
    ],
  ].flatMap(([phase, sumField, maxField, countField]) => {
    const count = finiteNumber(bmfPlayerRegistry[countField], 0);
    return [
      {
        name: 'bmf_player_registry_duration_milliseconds',
        labels: { phase, statistic: 'avg' },
        value:
          count > 0
            ? finiteNumber(bmfPlayerRegistry[sumField], 0) / count
            : NaN,
      },
      {
        name: 'bmf_player_registry_duration_milliseconds',
        labels: { phase, statistic: 'max' },
        value: finiteMetricValue(bmfPlayerRegistry[maxField]),
      },
    ];
  });
  const bmfOperationClassTotalLines: MetricLine[] = Object.entries(
    bmfOperationsByClass,
  ).map(([operationClass, value]) => ({
    name: 'bmf_operation_total',
    labels: { operation_class: operationClass },
    value: finiteMetricValue(objectRecord(value).count),
  }));
  const bmfOperationSourceTotalLines: MetricLine[] = Object.entries(
    bmfOperationsBySource,
  ).map(([source, value]) => ({
    name: 'bmf_operation_source_total',
    labels: { source },
    value: finiteMetricValue(objectRecord(value).count),
  }));
  const bmfOperationOutcomeLines: MetricLine[] = Object.entries(
    bmfOperationsByOutcome,
  ).map(([outcome, value]) => ({
    name: 'bmf_operation_outcome_total',
    labels: { outcome },
    value: finiteMetricValue(objectRecord(value).count),
  }));
  const bmfOperationCacheResultLines: MetricLine[] = Object.entries(
    bmfOperationsByCacheResult,
  ).map(([cacheResult, value]) => ({
    name: 'bmf_operation_cache_result_total',
    labels: { cache_result: cacheResult },
    value: finiteMetricValue(objectRecord(value).count),
  }));
  const bmfOperationDurationLines: MetricLine[] = Object.entries(
    bmfOperationsByClass,
  ).flatMap(([operationClass, value]) => {
    const record = objectRecord(value);
    const count = finiteNumber(record.count, 0);
    return [
      ['queue_wait', 'queue_wait_ms_sum', 'queue_wait_ms_max'],
      ['admission_defer', 'admission_defer_ms_sum', 'admission_defer_ms_max'],
      ['game_thread', 'game_thread_ms_sum', 'game_thread_ms_max'],
      ['off_thread', 'off_thread_ms_sum', 'off_thread_ms_max'],
      ['total', 'total_ms_sum', 'total_ms_max'],
      [
        'global_scan',
        'global_scan_duration_ms_sum',
        'global_scan_duration_ms_max',
      ],
    ].flatMap(([phase, sumField, maxField]) => [
      {
        name: 'bmf_operation_duration_milliseconds',
        labels: { operation_class: operationClass, phase, statistic: 'avg' },
        value: count > 0 ? finiteNumber(record[sumField], 0) / count : NaN,
      },
      {
        name: 'bmf_operation_duration_milliseconds',
        labels: { operation_class: operationClass, phase, statistic: 'max' },
        value: finiteMetricValue(record[maxField]),
      },
    ]);
  });
  const bmfOperationLastDurationLines: MetricLine[] = Object.entries(
    bmfOperationsByClass,
  ).map(([operationClass, value]) => ({
    name: 'bmf_operation_last_duration_milliseconds',
    labels: { operation_class: operationClass },
    value: finiteMetricValue(objectRecord(value).last_ms),
  }));
  const bmfOperationLastTimestampLines: MetricLine[] = Object.entries(
    bmfOperationsByClass,
  ).map(([operationClass, value]) => {
    const timestampMs = Date.parse(String(objectRecord(value).last_at ?? ''));
    return {
      name: 'bmf_operation_last_timestamp_seconds',
      labels: { operation_class: operationClass },
      value: Number.isFinite(timestampMs) ? timestampMs / 1_000 : NaN,
    };
  });
  const bmfLastOperationClass = String(
    bmfOperationsLast.operation_class ?? 'unknown',
  );
  const bmfFrameDurationLines: MetricLine[] = [
    {
      name: 'brickadia_frame_delta_milliseconds',
      labels: { scope: 'window', statistic: 'avg' },
      value: finiteMetricValue(bmfFrameWindow.delta_ms_avg),
    },
    {
      name: 'brickadia_frame_delta_milliseconds',
      labels: { scope: 'window', statistic: 'max' },
      value: finiteMetricValue(bmfFrameWindow.delta_ms_max),
    },
    {
      name: 'brickadia_frame_delta_milliseconds',
      labels: { scope: 'window', statistic: 'last' },
      value: finiteMetricValue(bmfFrameWindow.delta_ms_last),
    },
    {
      name: 'brickadia_frame_delta_milliseconds',
      labels: { scope: 'lifetime', statistic: 'avg' },
      value: finiteMetricValue(bmfFrameLifetime.delta_ms_avg),
    },
    {
      name: 'brickadia_frame_delta_milliseconds',
      labels: { scope: 'lifetime', statistic: 'max' },
      value: finiteMetricValue(bmfFrameLifetime.delta_ms_max),
    },
    {
      name: 'brickadia_frame_delta_milliseconds',
      labels: { scope: 'lifetime', statistic: 'last' },
      value: finiteMetricValue(bmfFrameLifetime.delta_ms_last),
    },
  ];
  const bmfFrameSlowLines: MetricLine[] = [
    {
      name: 'brickadia_frame_slow_total',
      labels: { threshold_ms: '16.67' },
      value: finiteMetricValue(bmfFrameLifetime.slow_16_67_total),
    },
    {
      name: 'brickadia_frame_slow_total',
      labels: { threshold_ms: '33.33' },
      value: finiteMetricValue(bmfFrameLifetime.slow_33_33_total),
    },
    {
      name: 'brickadia_frame_slow_total',
      labels: { threshold_ms: '50' },
      value: finiteMetricValue(bmfFrameLifetime.slow_50_total),
    },
    {
      name: 'brickadia_frame_slow_total',
      labels: { threshold_ms: '100' },
      value: finiteMetricValue(bmfFrameLifetime.slow_100_total),
    },
  ];
  const joinCorrelationTotalLines: MetricLine[] = Object.entries(
    joinCorrelationPhases,
  ).flatMap(([phase, outcomes]) =>
    Object.entries(objectRecord(outcomes)).map(([outcome, aggregate]) => ({
      name: 'omegga_join_phase_total',
      labels: { phase, outcome },
      value: finiteMetricValue(objectRecord(aggregate).count),
    })),
  );
  const joinCorrelationDurationLines: MetricLine[] = Object.entries(
    joinCorrelationPhases,
  ).flatMap(([phase, outcomes]) =>
    Object.entries(objectRecord(outcomes)).flatMap(([outcome, aggregate]) => {
      const record = objectRecord(aggregate);
      const count = finiteNumber(record.count, 0);
      return [
        {
          name: 'omegga_join_phase_duration_milliseconds',
          labels: { phase, outcome, statistic: 'avg' },
          value:
            count > 0 ? finiteNumber(record.durationMsSum, 0) / count : NaN,
        },
        {
          name: 'omegga_join_phase_duration_milliseconds',
          labels: { phase, outcome, statistic: 'max' },
          value: finiteMetricValue(record.durationMsMax),
        },
        {
          name: 'omegga_join_phase_duration_milliseconds',
          labels: { phase, outcome, statistic: 'last' },
          value: finiteMetricValue(record.durationMsLast),
        },
      ];
    }),
  );

  const lines: string[] = [
    '# Omegga / Brickadia Prometheus metrics',
    ...metricBlock(
      'brickadia_server_up',
      'Whether Omegga considers the Brickadia server started.',
      [
        {
          name: 'brickadia_server_up',
          value: boolGauge(server.omegga.started),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_server_starting',
      'Whether Omegga is currently starting the Brickadia server.',
      [
        {
          name: 'brickadia_server_starting',
          value: boolGauge(server.omegga.starting),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_server_stopping',
      'Whether Omegga is currently stopping the Brickadia server.',
      [
        {
          name: 'brickadia_server_stopping',
          value: boolGauge(server.omegga.stopping),
        },
      ],
    ),
    ...metricBlock('brickadia_server_players', 'Current player count.', [
      { name: 'brickadia_server_players', value: players.length },
    ]),
    ...metricBlock('brickadia_server_bricks', 'Current brick count.', [
      { name: 'brickadia_server_bricks', value: status?.bricks ?? 0 },
    ]),
    ...metricBlock('brickadia_server_components', 'Current component count.', [
      { name: 'brickadia_server_components', value: status?.components ?? 0 },
    ]),
    ...metricBlock(
      'brickadia_server_uptime_seconds',
      'Server uptime in seconds.',
      [{ name: 'brickadia_server_uptime_seconds', value: uptimeSeconds }],
    ),
    ...metricBlock(
      'brickadia_player_ping_seconds',
      'Aggregate player ping values from the latest server status.',
      [
        {
          name: 'brickadia_player_ping_seconds',
          labels: { statistic: 'avg' },
          value: pingAvg,
        },
        {
          name: 'brickadia_player_ping_seconds',
          labels: { statistic: 'max' },
          value: pingMax,
        },
      ],
    ),
    ...metricBlock(
      'omegga_last_server_status_age_seconds',
      'Age of the latest cached Brickadia server status.',
      [
        {
          name: 'omegga_last_server_status_age_seconds',
          value:
            lastStatusAt > 0 ? Math.max(0, (now - lastStatusAt) / 1000) : 0,
        },
      ],
    ),
    ...metricBlock(
      'omegga_server_status_poll_duration_seconds',
      'Duration of the latest Brickadia server status poll.',
      [
        {
          name: 'omegga_server_status_poll_duration_seconds',
          value: statusPollDurationSeconds,
        },
      ],
    ),
    ...metricBlock(
      'omegga_server_status_poll_enabled',
      'Whether Omegga sends Server.Status console polls for heartbeat data.',
      [
        {
          name: 'omegga_server_status_poll_enabled',
          value: boolGauge(server.serverStatusPollEnabled),
        },
      ],
    ),
    ...metricBlock(
      'omegga_join_attribution_enabled',
      'Whether bounded join and frame-hitch attribution is enabled.',
      [
        {
          name: 'omegga_join_attribution_enabled',
          value: boolGauge(joinCorrelation.enabled),
        },
      ],
    ),
    ...metricBlock(
      'omegga_join_attribution_dropped_writes_total',
      'Structured join-attribution records dropped after an asynchronous write failure.',
      [
        {
          name: 'omegga_join_attribution_dropped_writes_total',
          value: finiteMetricValue(joinCorrelation.droppedWrites),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'omegga_join_phase_total',
      'Join correlation phase outcomes using fixed-cardinality phase and outcome labels.',
      joinCorrelationTotalLines,
      'counter',
    ),
    ...metricBlock(
      'omegga_join_phase_duration_milliseconds',
      'Join correlation phase duration using fixed-cardinality phase, outcome, and statistic labels.',
      joinCorrelationDurationLines,
    ),
    ...metricBlock(
      'omegga_server_status_poll_total',
      'Brickadia server status poll outcomes.',
      [
        {
          name: 'omegga_server_status_poll_total',
          labels: { status: 'ok' },
          value: finiteMetricValue(statusPollMetrics?.ok),
        },
        {
          name: 'omegga_server_status_poll_total',
          labels: { status: 'error' },
          value: finiteMetricValue(statusPollMetrics?.error),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'omegga_server_status_poll_duration_stat_seconds',
      'Aggregate Brickadia server status poll durations.',
      statusPollDurationStatLines,
    ),
    ...metricBlock(
      'omegga_console_command_sent_total',
      'Omegga console commands sent to Brickadia by normalized command family.',
      omeggaConsoleCommandSentLines,
      'counter',
    ),
    ...metricBlock(
      'omegga_console_command_last_sent_age_seconds',
      'Age of the latest Omegga console command by normalized command family.',
      omeggaConsoleCommandAgeLines,
    ),
    ...metricBlock(
      'omegga_ue4ss_admission_enabled',
      'Whether bounded UE4SS admission is enabled at each fixed stage.',
      ue4ssAdmissionEnabledLines,
    ),
    ...metricBlock(
      'omegga_ue4ss_queue_depth',
      'Current bounded UE4SS queue depth by fixed stage and service class.',
      ue4ssQueueDepthLines,
    ),
    ...metricBlock(
      'omegga_ue4ss_queue_bytes',
      'Current bounded UE4SS queue bytes by fixed stage and service class.',
      ue4ssQueueByteLines,
    ),
    ...metricBlock(
      'omegga_ue4ss_queue_oldest_age_milliseconds',
      'Oldest or most recently observed UE4SS queue age by fixed stage.',
      ue4ssQueueAgeLines,
    ),
    ...metricBlock(
      'omegga_ue4ss_queue_high_water',
      'UE4SS admission high-water marks by fixed stage and unit.',
      ue4ssQueueHighWaterLines,
    ),
    ...metricBlock(
      'omegga_ue4ss_admitted_total',
      'UE4SS admission totals by fixed stage and service class.',
      ue4ssAdmittedLines,
      'counter',
    ),
    ...metricBlock(
      'omegga_ue4ss_rejected_total',
      'UE4SS admission rejection totals by fixed stage and reason.',
      ue4ssRejectedLines,
      'counter',
    ),
    ...metricBlock(
      'omegga_ue4ss_expired_total',
      'UE4SS work expired before execution by fixed stage.',
      [
        {
          name: 'omegga_ue4ss_expired_total',
          labels: { stage: 'write_queue' },
          value: finiteMetricValue(ue4ssWriteQueue.expired),
        },
        {
          name: 'omegga_ue4ss_expired_total',
          labels: { stage: 'node_inbox' },
          value: finiteMetricValue(ue4ssInbox.expired),
        },
        {
          name: 'omegga_ue4ss_expired_total',
          labels: { stage: 'ue4ss_runtime' },
          value: finiteMetricValue(ue4ssRuntime.expired),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'omegga_ue4ss_client_timeouts_total',
      'Node-side UE4SS response timeouts after inbox admission.',
      [
        {
          name: 'omegga_ue4ss_client_timeouts_total',
          labels: { stage: 'node_inbox' },
          value: finiteMetricValue(ue4ssInbox.clientTimeouts),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'omegga_ue4ss_deadline_missing_total',
      'Legacy UE4SS runtime records observed without admission deadline metadata.',
      [
        {
          name: 'omegga_ue4ss_deadline_missing_total',
          labels: { stage: 'ue4ss_runtime' },
          value: finiteMetricValue(ue4ssRuntime.deadlineMissing),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'omegga_ue4ss_queue_age_high_water_milliseconds',
      'Maximum UE4SS queue age observed before runtime execution.',
      [
        {
          name: 'omegga_ue4ss_queue_age_high_water_milliseconds',
          labels: { stage: 'ue4ss_runtime' },
          value: finiteMetricValue(ue4ssRuntime.maxQueueAgeMs),
        },
      ],
    ),
    ...metricBlock('omegga_process_uptime_seconds', 'Omegga process uptime.', [
      { name: 'omegga_process_uptime_seconds', value: process.uptime() },
    ]),
    ...metricBlock(
      'omegga_process_memory_bytes',
      'Omegga process memory usage.',
      [
        {
          name: 'omegga_process_memory_bytes',
          labels: { area: 'rss' },
          value: memory.rss,
        },
        {
          name: 'omegga_process_memory_bytes',
          labels: { area: 'heap_total' },
          value: memory.heapTotal,
        },
        {
          name: 'omegga_process_memory_bytes',
          labels: { area: 'heap_used' },
          value: memory.heapUsed,
        },
        {
          name: 'omegga_process_memory_bytes',
          labels: { area: 'external' },
          value: memory.external,
        },
      ],
    ),
    ...metricBlock(
      'omegga_process_cpu_seconds_total',
      'Cumulative Omegga process CPU time.',
      [
        {
          name: 'omegga_process_cpu_seconds_total',
          labels: { mode: 'user' },
          value: cpu.user / 1_000_000,
        },
        {
          name: 'omegga_process_cpu_seconds_total',
          labels: { mode: 'system' },
          value: cpu.system / 1_000_000,
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_runtime_status_up',
      'Whether BMF runtime status is readable.',
      [{ name: 'bmf_runtime_status_up', value: bmfStatus ? 1 : 0 }],
    ),
    ...metricBlock(
      'bmf_runtime_status_age_seconds',
      'Age of the BMF runtime status file.',
      [{ name: 'bmf_runtime_status_age_seconds', value: bmfFileAgeSeconds }],
    ),
    ...metricBlock(
      'bmf_runtime_info',
      'BMF runtime build and compatibility labels.',
      [
        {
          name: 'bmf_runtime_info',
          labels: bmfInfoLabels,
          value: bmfStatus ? 1 : 0,
        },
      ],
    ),
    ...metricBlock(
      'bmf_command_worker_info',
      'BMF command worker scheduler mode.',
      [
        {
          name: 'bmf_command_worker_info',
          labels: bmfCommandWorkerLabels,
          value: bmfStatus ? 1 : 0,
        },
      ],
    ),
    ...metricBlock(
      'bmf_command_worker_poll_interval_milliseconds',
      'BMF command worker async poll interval.',
      [
        {
          name: 'bmf_command_worker_poll_interval_milliseconds',
          value: finiteMetricValue(bmfStatus?.command_worker_poll_interval_ms),
        },
      ],
    ),
    ...metricBlock(
      'bmf_command_worker_fallback_poll_interval_milliseconds',
      'BMF command worker game-thread fallback poll interval.',
      [
        {
          name: 'bmf_command_worker_fallback_poll_interval_milliseconds',
          value: finiteMetricValue(
            bmfStatus?.command_worker_fallback_poll_interval_ms,
          ),
        },
      ],
    ),
    ...metricBlock(
      'bmf_command_worker_max_files_per_poll',
      'Maximum BMF command request files scheduled per worker poll.',
      [
        {
          name: 'bmf_command_worker_max_files_per_poll',
          value: finiteMetricValue(
            bmfStatus?.command_worker_max_files_per_poll,
          ),
        },
      ],
    ),
    ...metricBlock('bmf_telemetry_up', 'Whether BMF telemetry is readable.', [
      { name: 'bmf_telemetry_up', value: bmfTelemetry ? 1 : 0 },
    ]),
    ...metricBlock(
      'bmf_telemetry_age_seconds',
      'Age of the BMF telemetry file.',
      [{ name: 'bmf_telemetry_age_seconds', value: bmfTelemetryAgeSeconds }],
    ),
    ...metricBlock(
      'bmf_telemetry_schema_version',
      'BMF telemetry schema version.',
      [
        {
          name: 'bmf_telemetry_schema_version',
          value: finiteMetricValue(bmfTelemetryRecord.schema_version),
        },
      ],
    ),
    ...metricBlock(
      'bmf_operation_attribution_enabled',
      'Whether bounded BMF operation attribution is enabled.',
      [
        {
          name: 'bmf_operation_attribution_enabled',
          value:
            typeof bmfOperations.enabled === 'boolean'
              ? boolGauge(bmfOperations.enabled)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'bmf_operation_in_flight',
      'Current attributed BMF operations in flight.',
      [
        {
          name: 'bmf_operation_in_flight',
          value: finiteMetricValue(bmfOperations.active),
        },
      ],
    ),
    ...metricBlock(
      'bmf_operation_total',
      'Attributed BMF operations by bounded handler class.',
      bmfOperationClassTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_source_total',
      'Attributed BMF operations by fixed source path.',
      bmfOperationSourceTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_outcome_total',
      'Attributed BMF operations by bounded terminal outcome.',
      bmfOperationOutcomeLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_cache_result_total',
      'Attributed BMF operations by cache result.',
      bmfOperationCacheResultLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_duration_milliseconds',
      'Attributed operation phase duration by bounded handler class.',
      bmfOperationDurationLines,
    ),
    ...metricBlock(
      'bmf_operation_last_duration_milliseconds',
      'Most recent attributed operation duration by bounded handler class.',
      bmfOperationLastDurationLines,
    ),
    ...metricBlock(
      'bmf_operation_last_timestamp_seconds',
      'Completion timestamp of the most recent attributed operation by bounded handler class.',
      bmfOperationLastTimestampLines,
    ),
    ...metricBlock(
      'bmf_operation_last_frame_delta_milliseconds',
      'Native frame delta sampled nearest the most recently completed attributed operation.',
      [
        {
          name: 'bmf_operation_last_frame_delta_milliseconds',
          labels: { operation_class: bmfLastOperationClass },
          value: finiteMetricValue(
            bmfOperationsLast.frame_duration_ms_near_completion,
          ),
        },
      ],
    ),
    ...metricBlock(
      'bmf_operation_last_frame_timestamp_seconds',
      'Native frame sample timestamp nearest the most recently completed attributed operation.',
      [
        {
          name: 'bmf_operation_last_frame_timestamp_seconds',
          labels: { operation_class: bmfLastOperationClass },
          value:
            finiteMetricValue(bmfOperationsLast.frame_observed_at_ms) / 1_000,
        },
      ],
    ),
    ...metricBlock(
      'bmf_operation_slow_total',
      'Attributed operations that crossed a slow-operation threshold.',
      [
        {
          name: 'bmf_operation_slow_total',
          value: finiteMetricValue(bmfOperations.slow_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_budget_overrun_total',
      'Attributed operations exceeding the configured game-thread budget.',
      [
        {
          name: 'bmf_operation_budget_overrun_total',
          value: finiteMetricValue(bmfOperations.budget_overrun_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_admission_defer_total',
      'Budget admission deferrals observed by attributed operations.',
      [
        {
          name: 'bmf_operation_admission_defer_total',
          value: finiteMetricValue(bmfOperations.admission_defer_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_operation_lifetime_guard_rejections_total',
      'Raw-object lifetime guard rejections observed by attributed operations.',
      [
        {
          name: 'bmf_operation_lifetime_guard_rejections_total',
          value: finiteMetricValue(
            bmfOperations.lifetime_guard_rejections_total,
          ),
        },
      ],
      'counter',
    ),
    ...bmfPlayerRegistryMetricBlocks,
    ...bmfConnectionReadinessMetricBlocks,
    ...bmfTunnelReadinessMetricBlocks,
    ...metricBlock(
      'bmf_player_registry_duration_milliseconds',
      'Player-registry repair and global-scan duration.',
      bmfPlayerRegistryDurationLines,
    ),
    ...metricBlock(
      'brickadia_frame_telemetry_up',
      'Whether native BMF frame telemetry is readable.',
      [
        {
          name: 'brickadia_frame_telemetry_up',
          value: bmfFrameTelemetry ? 1 : 0,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_telemetry_age_seconds',
      'Age of the native BMF frame telemetry file.',
      [
        {
          name: 'brickadia_frame_telemetry_age_seconds',
          value: bmfFrameTelemetryAgeSeconds,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_telemetry_hook_registered',
      'Whether the native BMF frame telemetry engine tick hook registered.',
      [
        {
          name: 'brickadia_frame_telemetry_hook_registered',
          value: boolGauge(bmfFrameTelemetryRecord.hook_registered),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_telemetry_schema_version',
      'Native BMF frame telemetry schema version.',
      [
        {
          name: 'brickadia_frame_telemetry_schema_version',
          value: finiteMetricValue(bmfFrameTelemetryRecord.schema_version),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_enabled',
      'Whether native BMF server frame pacing is enabled.',
      [
        {
          name: 'brickadia_frame_pacing_enabled',
          value:
            typeof bmfFramePacing.enabled === 'boolean'
              ? boolGauge(bmfFramePacing.enabled)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_config_valid',
      'Whether the native BMF frame target configuration was valid.',
      [
        {
          name: 'brickadia_frame_pacing_config_valid',
          value:
            typeof bmfFramePacing.config_valid === 'boolean'
              ? boolGauge(bmfFramePacing.config_valid)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_target_fps',
      'Requested native BMF server frame target in frames per second.',
      [
        {
          name: 'brickadia_frame_pacing_target_fps',
          value: finiteMetricValue(bmfFramePacing.target_fps),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_target_override_attempted',
      'Whether BMF attempted its one-shot engine frame target override.',
      [
        {
          name: 'brickadia_frame_pacing_target_override_attempted',
          value:
            typeof bmfFramePacing.target_override_attempted === 'boolean'
              ? boolGauge(bmfFramePacing.target_override_attempted)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_target_override_applied',
      'Whether BMF verified the one-shot engine frame target override.',
      [
        {
          name: 'brickadia_frame_pacing_target_override_applied',
          value:
            typeof bmfFramePacing.target_override_applied === 'boolean'
              ? boolGauge(bmfFramePacing.target_override_applied)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_layout_calibrated',
      'Whether BMF calibrated the named engine layout against the independently scanned Tick function.',
      [
        {
          name: 'brickadia_frame_pacing_layout_calibrated',
          value:
            typeof bmfFramePacing.layout_calibrated === 'boolean'
              ? boolGauge(bmfFramePacing.layout_calibrated)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_layout_adjustment_bytes',
      'Signed byte adjustment from the named UE4SS engine layout to the live calibrated layout.',
      [
        {
          name: 'brickadia_frame_pacing_layout_adjustment_bytes',
          value: finiteMetricValue(bmfFramePacing.layout_adjustment_bytes),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_entry_signatures_valid',
      'Whether the calibrated t.MaxFPS getter and setter matched validated native signatures.',
      [
        {
          name: 'brickadia_frame_pacing_entry_signatures_valid',
          value:
            typeof bmfFramePacing.entry_signatures_valid === 'boolean'
              ? boolGauge(bmfFramePacing.entry_signatures_valid)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_observed_max_fps',
      'Engine t.MaxFPS read back after the BMF frame target override.',
      [
        {
          name: 'brickadia_frame_pacing_observed_max_fps',
          value: finiteMetricValue(bmfFramePacing.observed_max_fps),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_observed_max_tick_rate',
      'Engine max tick rate read back after the BMF frame target override.',
      [
        {
          name: 'brickadia_frame_pacing_observed_max_tick_rate',
          value: finiteMetricValue(bmfFramePacing.observed_max_tick_rate),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_timer_policy_applied',
      'Whether BMF made Windows honor process timer-resolution requests.',
      [
        {
          name: 'brickadia_frame_pacing_timer_policy_applied',
          value:
            typeof bmfFramePacing.timer_policy_applied === 'boolean'
              ? boolGauge(bmfFramePacing.timer_policy_applied)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_pacing_timer_resolution_request_succeeded',
      'Whether the BMF one-millisecond timer-resolution request succeeded.',
      [
        {
          name: 'brickadia_frame_pacing_timer_resolution_request_succeeded',
          value:
            typeof bmfFramePacing.timer_resolution_request_succeeded ===
            'boolean'
              ? boolGauge(bmfFramePacing.timer_resolution_request_succeeded)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_delta_milliseconds',
      'Native Unreal engine tick DeltaSeconds converted to milliseconds.',
      bmfFrameDurationLines,
    ),
    ...metricBlock('brickadia_frame_fps', 'Native frame-rate estimate.', [
      {
        name: 'brickadia_frame_fps',
        labels: { scope: 'window', statistic: 'avg' },
        value: finiteMetricValue(bmfFrameWindow.fps_avg),
      },
    ]),
    ...metricBlock(
      'brickadia_frame_samples_total',
      'Native frame telemetry sample count.',
      [
        {
          name: 'brickadia_frame_samples_total',
          value: finiteMetricValue(bmfFrameLifetime.samples_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'brickadia_frame_idle_samples_total',
      'Native frame telemetry idle sample count.',
      [
        {
          name: 'brickadia_frame_idle_samples_total',
          value: finiteMetricValue(bmfFrameLifetime.idle_samples_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'brickadia_frame_slow_total',
      'Native frame samples at or above each frame-time threshold.',
      bmfFrameSlowLines,
      'counter',
    ),
    ...metricBlock(
      'brickadia_frame_spikes_total',
      'Native frame spikes recorded by the BMF frame sampler.',
      [
        {
          name: 'brickadia_frame_spikes_total',
          labels: {
            threshold_ms: finiteNumber(bmfFrameSpikes.threshold_ms, 100),
          },
          value: finiteMetricValue(bmfFrameSpikes.total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'brickadia_frame_spike_last_delta_milliseconds',
      'Most recent native frame spike delta in milliseconds.',
      [
        {
          name: 'brickadia_frame_spike_last_delta_milliseconds',
          value: finiteMetricValue(bmfFrameLastSpike.delta_ms),
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_spike_last_timestamp_seconds',
      'Unix timestamp of the most recent native frame spike.',
      [
        {
          name: 'brickadia_frame_spike_last_timestamp_seconds',
          value:
            bmfFrameLastSpikeAtMs > 0 ? bmfFrameLastSpikeAtMs / 1_000 : NaN,
        },
      ],
    ),
    ...metricBlock(
      'brickadia_frame_spike_last_age_seconds',
      'Age of the most recent native frame spike.',
      [
        {
          name: 'brickadia_frame_spike_last_age_seconds',
          value:
            bmfFrameLastSpikeAtMs > 0
              ? Math.max(0, (now - bmfFrameLastSpikeAtMs) / 1000)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'bmf_command_processed_total',
      'BMF command outcomes by command name.',
      bmfCommandProcessedLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_command_duration_milliseconds',
      'BMF command total duration in milliseconds.',
      bmfCommandDurationLines,
    ),
    ...metricBlock(
      'bmf_command_transport_total',
      'BMF command outcomes by transport.',
      bmfCommandTransportLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_command_transport_duration_milliseconds',
      'BMF command duration in milliseconds by transport.',
      bmfCommandTransportDurationLines,
    ),
    ...metricBlock(
      'bmf_event_emitted_total',
      'BMF framework event outcomes by event name.',
      bmfEventTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_event_duration_milliseconds',
      'BMF framework event duration in milliseconds.',
      bmfEventDurationLines,
    ),
    ...metricBlock(
      'bmf_event_handler_total',
      'BMF framework event handler outcomes by event name.',
      bmfEventHandlerTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_event_handler_duration_milliseconds',
      'BMF framework event handler duration in milliseconds.',
      bmfEventHandlerDurationLines,
    ),
    ...metricBlock(
      'bmf_plugin_lua_total',
      'BMF plugin-owned Lua handler outcomes by plugin.',
      bmfPluginTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_plugin_lua_duration_milliseconds',
      'BMF plugin-owned Lua handler duration in milliseconds by plugin.',
      bmfPluginDurationLines,
    ),
    ...metricBlock(
      'bmf_plugin_hook_total',
      'BMF plugin-owned Lua handler outcomes by plugin and hook.',
      bmfPluginHookTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_plugin_hook_duration_milliseconds',
      'BMF plugin-owned Lua handler duration in milliseconds by plugin and hook.',
      bmfPluginHookDurationLines,
    ),
    ...metricBlock(
      'bmf_scheduler_callback_total',
      'BMF scheduler callback outcomes by callback kind and name.',
      bmfSchedulerTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_scheduler_callback_duration_milliseconds',
      'BMF scheduler callback duration in milliseconds.',
      bmfSchedulerDurationLines,
    ),
    ...metricBlock(
      'bmf_worker_poll_total',
      'BMF bridge worker poll outcomes by worker.',
      bmfWorkerTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_worker_poll_duration_milliseconds',
      'BMF bridge worker poll duration in milliseconds.',
      bmfWorkerDurationLines,
    ),
    ...metricBlock(
      'bmf_worker_items_total',
      'BMF bridge worker processed item totals.',
      bmfWorkerItemLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_scheduler_interval_milliseconds',
      'Current bounded socket scheduler wake interval in milliseconds.',
      [
        {
          name: 'bmf_socket_scheduler_interval_milliseconds',
          value: finiteMetricValue(bmfSocketScheduler.current_poll_interval_ms),
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_scheduler_passes_total',
      'Total bounded socket scheduler passes.',
      [
        {
          name: 'bmf_socket_scheduler_passes_total',
          value: finiteMetricValue(bmfSocketScheduler.poll_passes_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_scheduler_idle_passes_total',
      'Socket scheduler passes with no current or recent work.',
      [
        {
          name: 'bmf_socket_scheduler_idle_passes_total',
          value: finiteMetricValue(bmfSocketScheduler.idle_passes_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_scheduler_active_passes_total',
      'Socket scheduler passes with work, queued work, or recent work.',
      [
        {
          name: 'bmf_socket_scheduler_active_passes_total',
          value: finiteMetricValue(bmfSocketScheduler.active_passes_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_scheduler_backoff_transitions_total',
      'Socket scheduler transitions among active, short-idle, and deep-idle tiers.',
      [
        {
          name: 'bmf_socket_scheduler_backoff_transitions_total',
          value: finiteMetricValue(
            bmfSocketScheduler.backoff_transitions_total,
          ),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_scheduler_work_wakeups_total',
      'Backed-off socket scheduler wakeups that discover work.',
      [
        {
          name: 'bmf_socket_scheduler_work_wakeups_total',
          value: finiteMetricValue(bmfSocketScheduler.work_wakeups_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_ingress_messages_total',
      'Socket envelopes admitted from the native receive queue by fixed message type.',
      bmfSocketIngressTypeLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_native_event_drain_budget_enabled',
      'Whether native tree and zone event drains share the socket-pump elapsed budget.',
      [
        {
          name: 'bmf_native_event_drain_budget_enabled',
          value:
            typeof bmfNativeDrains.budget_enabled === 'boolean'
              ? boolGauge(bmfNativeDrains.budget_enabled)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'bmf_native_event_drain_total',
      'Native event drain outcomes by fixed tree or zone source.',
      bmfNativeDrainOutcomeLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_native_event_queue_depth',
      'Last exact native event queue depth when the runtime could observe it.',
      bmfNativeDrainDepthLines,
    ),
    ...metricBlock(
      'bmf_native_event_drain_max_events_per_pump',
      'Hard event-count cap for budgeted native drains in one socket-pump slice.',
      [
        {
          name: 'bmf_native_event_drain_max_events_per_pump',
          value: finiteMetricValue(bmfNativeDrains.max_events_per_pump),
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_admitted_total',
      'Executable socket work admitted by direct-command or tunnel path.',
      bmfSocketAdmissionLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_admission_outcome_total',
      'Bounded socket admission outcomes by fixed path and outcome.',
      bmfSocketAdmissionOutcomeLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_terminal_total',
      'Terminal socket request outcomes by fixed path and state.',
      bmfSocketTerminalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_fairness_selection_total',
      'Weighted-fair scheduler selections by fixed path and service class.',
      bmfSocketFairnessLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_work_total',
      'Executed socket work outcomes by direct-command or tunnel path.',
      bmfSocketWorkTotalLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_work_duration_milliseconds',
      'Socket work duration by direct-command or tunnel path.',
      bmfSocketWorkDurationLines,
    ),
    ...metricBlock(
      'bmf_game_thread_slice_duration_milliseconds',
      'Total game-thread scheduler slice duration for the socket pump.',
      durationMetricLines(
        'bmf_game_thread_slice_duration_milliseconds',
        { worker: 'socket_pump' },
        bmfSocketSlice,
      ),
    ),
    ...metricBlock(
      'bmf_game_thread_budget_milliseconds',
      'Configured soft game-thread budget used for attribution.',
      [
        {
          name: 'bmf_game_thread_budget_milliseconds',
          labels: { worker: 'socket_pump' },
          value: finiteMetricValue(bmfSocketScheduler.budget_ms),
        },
      ],
    ),
    ...metricBlock(
      'bmf_game_thread_budget_enforced',
      'Whether elapsed-time admission enforcement is enabled for the game-thread socket pump.',
      [
        {
          name: 'bmf_game_thread_budget_enforced',
          labels: { worker: 'socket_pump' },
          value:
            typeof bmfSocketScheduler.budget_enforced === 'boolean'
              ? boolGauge(bmfSocketScheduler.budget_enforced)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_unified_admission_enabled',
      'Whether direct and tunnel socket work share the unified admission scheduler.',
      [
        {
          name: 'bmf_socket_unified_admission_enabled',
          value:
            typeof bmfSocketScheduler.unified_enabled === 'boolean'
              ? boolGauge(bmfSocketScheduler.unified_enabled)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'bmf_game_thread_budget_exhausted_total',
      'Socket pump slices whose elapsed time exceeded the soft game-thread budget.',
      [
        {
          name: 'bmf_game_thread_budget_exhausted_total',
          labels: { worker: 'socket_pump' },
          value: finiteMetricValue(bmfSocketScheduler.budget_exhausted_total),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_game_thread_admission_stopped_total',
      'Socket pump admissions stopped after the elapsed game-thread budget was exhausted.',
      [
        {
          name: 'bmf_game_thread_admission_stopped_total',
          labels: { worker: 'socket_pump', reason: 'budget' },
          value: finiteMetricValue(
            bmfSocketScheduler.budget_admission_stopped_total,
          ),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_game_thread_dispatch_skipped_total',
      'Pending path dispatches skipped after the elapsed game-thread budget was exhausted.',
      [
        {
          name: 'bmf_game_thread_dispatch_skipped_total',
          labels: {
            worker: 'socket_pump',
            path: 'tunnel',
            reason: 'budget',
          },
          value: finiteMetricValue(
            bmfSocketScheduler.budget_tunnel_dispatch_skipped_total,
          ),
        },
        {
          name: 'bmf_game_thread_dispatch_skipped_total',
          labels: {
            worker: 'socket_pump',
            path: 'unified',
            reason: 'budget',
          },
          value: finiteMetricValue(
            bmfSocketScheduler.budget_dispatch_skipped_total,
          ),
        },
      ],
      'counter',
    ),
    ...metricBlock(
      'bmf_game_thread_monolithic_overrun_total',
      'Individual direct-command or tunnel calls exceeding the soft game-thread budget.',
      bmfSocketMonolithicOverrunLines,
      'counter',
    ),
    ...metricBlock(
      'bmf_socket_queue_depth',
      'Current queue depth by bounded socket execution path and service class.',
      bmfSocketQueueLines,
    ),
    ...metricBlock(
      'bmf_socket_queue_oldest_age_milliseconds',
      'Age of the oldest queued socket request by path and service class.',
      bmfSocketQueueAgeLines,
    ),
    ...metricBlock(
      'bmf_socket_queue_high_watermark',
      'Lifetime queue high-water mark by fixed socket path and service class.',
      bmfSocketQueueHighWaterLines,
    ),
    ...metricBlock(
      'bmf_socket_configured_ingress_per_pump',
      'Configured native socket receive limit before direct-ingress containment.',
      [
        {
          name: 'bmf_socket_configured_ingress_per_pump',
          value: finiteMetricValue(
            bmfSocketScheduler.configured_ingress_per_pump,
          ),
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_effective_ingress_per_pump',
      'Effective native socket receive limit after direct-ingress containment.',
      [
        {
          name: 'bmf_socket_effective_ingress_per_pump',
          value: finiteMetricValue(
            bmfSocketScheduler.effective_ingress_per_pump,
          ),
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_ingress_last',
      'Actual socket envelopes admitted by the most recent pump.',
      [
        {
          name: 'bmf_socket_ingress_last',
          value: finiteMetricValue(bmfSocketScheduler.ingress_last),
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_direct_admitted_last',
      'Actual direct commands admitted by the most recent pump.',
      [
        {
          name: 'bmf_socket_direct_admitted_last',
          value: finiteMetricValue(bmfSocketScheduler.direct_admitted_last),
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_direct_ingress_cap_enabled',
      'Whether the default-on direct socket ingress containment cap is enabled.',
      [
        {
          name: 'bmf_socket_direct_ingress_cap_enabled',
          value:
            typeof bmfSocketScheduler.direct_ingress_cap_enabled === 'boolean'
              ? boolGauge(bmfSocketScheduler.direct_ingress_cap_enabled)
              : NaN,
        },
      ],
    ),
    ...metricBlock(
      'bmf_socket_direct_ingress_cap_per_pump',
      'Configured default-on direct socket ingress cap per game-thread pump.',
      [
        {
          name: 'bmf_socket_direct_ingress_cap_per_pump',
          value: finiteMetricValue(
            bmfSocketScheduler.direct_ingress_cap_per_pump,
          ),
        },
      ],
    ),
    ...metricBlock('bmf_plugins_loaded', 'Loaded BMF plugin count.', [
      {
        name: 'bmf_plugins_loaded',
        value: finiteMetricValue(bmfStatus?.plugins_loaded),
      },
    ]),
    ...metricBlock('bmf_plugin_errors_total', 'BMF plugin error count.', [
      {
        name: 'bmf_plugin_errors_total',
        value: finiteMetricValue(bmfStatus?.plugin_errors),
      },
    ]),
    ...metricBlock(
      'bmf_plugin_tick_active',
      'Whether BMF plugin ticking is active.',
      [
        {
          name: 'bmf_plugin_tick_active',
          value: boolGauge(bmfStatus?.plugin_tick_active),
        },
      ],
    ),
    ...metricBlock('bmf_plugin_tick_total', 'BMF plugin tick count.', [
      {
        name: 'bmf_plugin_tick_total',
        value: finiteMetricValue(bmfStatus?.plugin_tick_count),
      },
    ]),
    ...metricBlock('bmf_audit_records_total', 'BMF audit record count.', [
      {
        name: 'bmf_audit_records_total',
        value: finiteMetricValue(bmfStatus?.audit_records),
      },
    ]),
    ...metricBlock(
      'bmf_plugin_watchdog_isolated',
      'BMF isolated plugin watchdog count.',
      [
        {
          name: 'bmf_plugin_watchdog_isolated',
          value: finiteMetricValue(bmfStatus?.plugin_watchdog_isolated),
        },
      ],
    ),
  ];

  return `${lines.filter(Boolean).join('\n')}\n`;
}

export default function setupPrometheusExporter(server: Webserver) {
  if (process.env.OMEGGA_METRICS_ENABLED === '0') return;

  server.app.get('/metrics', (req, res) => {
    if (!assertMetricsAccess(req, res)) return;
    res.setHeader('Content-Type', METRICS_CONTENT_TYPE);
    res.send(buildPrometheusMetrics(server));
  });

  server.app.get('/health', (_req, res) => {
    res.json({
      ok: true,
      serverStarted: server.omegga.started,
      lastStatusAt: server.lastReportedStatusAt || 0,
    });
  });
}
