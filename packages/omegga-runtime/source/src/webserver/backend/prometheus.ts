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
  const runtime = readRuntimeJson<BmfRuntimeStatus>(statusPathCandidates(server));
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
  const bmfFrameWindow = objectRecord(bmfFrameTelemetryRecord.window);
  const bmfFrameLifetime = objectRecord(bmfFrameTelemetryRecord.lifetime);
  const bmfFrameSpikes = objectRecord(bmfFrameTelemetryRecord.spikes);
  const bmfFrameLastSpike = objectRecord(bmfFrameSpikes.last);
  const bmfFrameLastSpikeAtMs = finiteNumber(
    bmfFrameLastSpike.observed_at_unix_ms,
    0,
  );
  const omeggaConsoleCommands = objectRecord(
    server.omegga.consoleCommandMetrics,
  );
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
  const bmfEventHandlerDurationLines = Object.entries(
    bmfEventsByName,
  ).flatMap(([key, value]) => {
    const record = objectRecord(value);
    const event = String(record.event ?? key);
    return prefixedDurationMetricLines(
      'bmf_event_handler_duration_milliseconds',
      { event },
      record,
      'handler',
    );
  });
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
  const bmfSchedulerDurationLines = Object.entries(
    bmfSchedulerByKey,
  ).flatMap(([_key, value]) => {
    const record = objectRecord(value);
    return durationMetricLines(
      'bmf_scheduler_callback_duration_milliseconds',
      {
        kind: String(record.kind ?? 'callback'),
        name: String(record.name ?? 'unknown'),
      },
      record,
    );
  });
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
          value: finiteMetricValue(bmfStatus?.command_worker_max_files_per_poll),
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
      'brickadia_frame_telemetry_up',
      'Whether native BMF frame telemetry is readable.',
      [{ name: 'brickadia_frame_telemetry_up', value: bmfFrameTelemetry ? 1 : 0 }],
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
