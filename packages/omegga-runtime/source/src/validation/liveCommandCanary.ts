import Logger from '@/logger';
import type Omegga from '@omegga/server';
import fs from 'node:fs';
import path from 'node:path';

export type LiveCommandCanaryRoute =
  | 'writeln'
  | 'broadcast'
  | 'whisper'
  | 'status-message'
  | 'control-output';

export type LiveCommandCanaryCase = {
  id: string;
  description: string;
  route: LiveCommandCanaryRoute;
  command?: string;
  message?: string;
  target?: string;
  timeoutMs?: number;
  expectCommandError?: boolean;
};

type LiveCommandCanaryResult = {
  id: string;
  description: string;
  route: LiveCommandCanaryRoute;
  status: 'passed' | 'failed';
  commandError?: string;
  healthError?: string;
  durationMs: number;
};

type LiveCommandCanaryReport = {
  startedAt: string;
  completedAt: string;
  status: 'passed' | 'failed';
  baselineMs: number;
  spacingMs: number;
  targetPlayer: string;
  metricsUrl: string | null;
  metricsBefore: Record<string, number | null>;
  metricsAfter: Record<string, number | null>;
  results: LiveCommandCanaryResult[];
};

const DEFAULT_COMMAND_TIMEOUT_MS = 5000;
const DEFAULT_HEALTH_TIMEOUT_MS = 3000;
const DEFAULT_BASELINE_MS = 30000;
const DEFAULT_SPACING_MS = 500;

const METRIC_NAMES = [
  'brickadia_server_up',
  'bmf_runtime_status_up',
  'bmf_telemetry_up',
  'brickadia_frame_telemetry_hook_registered',
];

const envPositiveNumber = (name: string, fallback: number) => {
  const parsed = Number(process.env[name] ?? fallback);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
};

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

export const isDangerousLiveCommandCanaryLine = (line: string) =>
  /^(?:exit|quit)\b/i.test(line.trim()) ||
  /^ServerTravel\b/i.test(line.trim()) ||
  /^(?:br\.)?Server\.Shutdown\b/i.test(line.trim()) ||
  /^(?:br\.)?BR\.World\.(?:Load|LoadAdditive|SaveAs)\b/i.test(line.trim()) ||
  /^(?:br\.)?Bricks\.(?:Clear|ClearRegion|Load)\b/i.test(line.trim());

export function buildDefaultLiveCommandCanaries(
  targetPlayer: string,
): LiveCommandCanaryCase[] {
  const suffix = Date.now().toString(36);
  const safeMessage = `"live-command-canary ${suffix}"`;

  return [
    {
      id: 'chat-broadcast-legacy',
      description: 'legacy Chat.Broadcast routes without killing the stack',
      route: 'writeln',
      command: `Chat.Broadcast ${safeMessage}`,
    },
    {
      id: 'chat-broadcast-namespaced',
      description:
        'namespaced br.Chat.Broadcast routes without killing the stack',
      route: 'writeln',
      command: `br.Chat.Broadcast ${safeMessage}`,
    },
    {
      id: 'chat-whisper-legacy',
      description: 'legacy Chat.Whisper routes through typed chat/BMF fallback',
      route: 'writeln',
      command: `Chat.Whisper "${targetPlayer}" ${safeMessage}`,
    },
    {
      id: 'chat-whisper-namespaced',
      description:
        'namespaced br.Chat.Whisper routes through typed chat/BMF fallback',
      route: 'writeln',
      command: `br.Chat.Whisper "${targetPlayer}" ${safeMessage}`,
    },
    {
      id: 'chat-status-namespaced',
      description:
        'namespaced br.Chat.StatusMessage routes through typed chat/BMF fallback',
      route: 'writeln',
      command: `br.Chat.StatusMessage "${targetPlayer}" ${safeMessage}`,
    },
    {
      id: 'omegga-broadcast-api',
      description: 'Omegga broadcast API survives command-name migration',
      route: 'broadcast',
      message: safeMessage,
    },
    {
      id: 'omegga-whisper-api',
      description: 'Omegga whisper API survives command-name migration',
      route: 'whisper',
      target: targetPlayer,
      message: safeMessage,
    },
    {
      id: 'synthetic-player-status-control-output',
      description:
        'safe control-output query returns or fails without process death',
      route: 'control-output',
      command: 'GetAll BRPlayerState UserName',
    },
    {
      id: 'bmf-status-control-output',
      description:
        'BMF socket status command returns or fails without process death',
      route: 'control-output',
      command: 'Omegga.Bridge.BMF bmf.status',
    },
  ];
}

const runWithTimeout = async <T>(
  label: string,
  timeoutMs: number,
  work: Promise<T>,
) => {
  let timer: NodeJS.Timeout | null = null;
  try {
    return await Promise.race([
      work,
      new Promise<T>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`${label} timed out after ${timeoutMs}ms`)),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
};

async function waitUntilStarted(server: Omegga, timeoutMs: number) {
  if ((server as any).started) return;
  await runWithTimeout(
    'waiting for server start',
    timeoutMs,
    new Promise<void>((resolve, reject) => {
      const onStart = () => {
        cleanup();
        resolve();
      };
      const onExit = () => {
        cleanup();
        reject(new Error('server exited before live command canary started'));
      };
      const cleanup = () => {
        server.off('start', onStart);
        server.off('exit', onExit);
      };
      server.once('start', onStart);
      server.once('exit', onExit);
    }),
  );
}

async function assertStackHealthy(server: Omegga) {
  if (!(server as any).started) {
    throw new Error('Omegga reports Brickadia is not started');
  }
  if ((server as any).stopping) {
    throw new Error('Omegga reports Brickadia is stopping');
  }

  if (typeof (server as any).pingWindowsControl === 'function') {
    await runWithTimeout(
      'Windows control ping',
      DEFAULT_HEALTH_TIMEOUT_MS,
      (server as any).pingWindowsControl(DEFAULT_HEALTH_TIMEOUT_MS),
    );
  }
}

async function runCanaryCase(server: Omegga, item: LiveCommandCanaryCase) {
  const startedAt = Date.now();
  let commandError: string | undefined;

  if (item.command && isDangerousLiveCommandCanaryLine(item.command)) {
    return {
      id: item.id,
      description: item.description,
      route: item.route,
      status: 'failed' as const,
      commandError: `refused dangerous live command: ${item.command}`,
      durationMs: Date.now() - startedAt,
    };
  }

  try {
    const timeoutMs = item.timeoutMs ?? DEFAULT_COMMAND_TIMEOUT_MS;
    switch (item.route) {
      case 'writeln':
        await runWithTimeout(
          item.id,
          timeoutMs,
          (server as any).writelnAsync(String(item.command ?? '')),
        );
        break;
      case 'broadcast':
        await runWithTimeout(
          item.id,
          timeoutMs,
          (server as any).broadcast(String(item.message ?? '')),
        );
        break;
      case 'whisper':
        await runWithTimeout(
          item.id,
          timeoutMs,
          (server as any).whisper(
            String(item.target ?? ''),
            String(item.message ?? ''),
          ),
        );
        break;
      case 'status-message':
        await runWithTimeout(
          item.id,
          timeoutMs,
          (server as any).middlePrint(
            String(item.target ?? ''),
            String(item.message ?? ''),
          ),
        );
        break;
      case 'control-output':
        await runWithTimeout(
          item.id,
          timeoutMs,
          (server as any).execControlCommandWithOutput(
            String(item.command ?? ''),
            timeoutMs,
          ),
        );
        break;
    }
  } catch (error) {
    commandError = error instanceof Error ? error.message : String(error);
  }

  try {
    await assertStackHealthy(server);
  } catch (error) {
    return {
      id: item.id,
      description: item.description,
      route: item.route,
      status: 'failed' as const,
      commandError,
      healthError: error instanceof Error ? error.message : String(error),
      durationMs: Date.now() - startedAt,
    };
  }

  const commandFailed = Boolean(commandError);
  const expectedFailure = item.expectCommandError === true;
  return {
    id: item.id,
    description: item.description,
    route: item.route,
    status:
      commandFailed && !expectedFailure
        ? ('failed' as const)
        : ('passed' as const),
    commandError,
    durationMs: Date.now() - startedAt,
  };
}

function parseMetricValue(metrics: string, metricName: string) {
  const escaped = metricName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = metrics.match(
    new RegExp(`^${escaped}(?:\\{[^\\n]*\\})?\\s+(-?\\d+(?:\\.\\d+)?)`, 'm'),
  );
  return match ? Number(match[1]) : null;
}

async function readMetrics(metricsUrl: string | null) {
  if (!metricsUrl) return {};
  try {
    const response = await fetch(metricsUrl);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const text = await response.text();
    return Object.fromEntries(
      METRIC_NAMES.map(name => [name, parseMetricValue(text, name)]),
    );
  } catch (error) {
    Logger.warnp(
      'live command canary metrics read failed'.yellow,
      error instanceof Error ? error.message : String(error),
    );
    return {};
  }
}

function getMetricsUrl(server: Omegga) {
  const configured = process.env.OMEGGA_LIVE_COMMAND_CANARY_METRICS_URL?.trim();
  if (configured) return configured;
  const webserver = (server as any).webserver;
  if (!webserver?.port) return null;
  return `http://127.0.0.1:${webserver.port}/metrics`;
}

function getReportPath() {
  const configured = process.env.OMEGGA_LIVE_COMMAND_CANARY_REPORT?.trim();
  if (configured) return configured;
  return path.join(
    process.cwd(),
    'artifacts',
    'live-command-canary-latest.json',
  );
}

export async function runLiveCommandCanary(server: Omegga) {
  const baselineMs = envPositiveNumber(
    'OMEGGA_LIVE_COMMAND_CANARY_BASELINE_MS',
    DEFAULT_BASELINE_MS,
  );
  const spacingMs = envPositiveNumber(
    'OMEGGA_LIVE_COMMAND_CANARY_SPACING_MS',
    DEFAULT_SPACING_MS,
  );
  const targetPlayer =
    process.env.OMEGGA_LIVE_COMMAND_CANARY_PLAYER?.trim() ||
    (server as any).players?.[0]?.name ||
    'Ty';
  const metricsUrl = getMetricsUrl(server);
  const reportPath = getReportPath();
  const startedAt = new Date().toISOString();

  Logger.logp('Live command canary starting.');
  Logger.log('  Target player:', targetPlayer.yellow);
  Logger.log('  Baseline ms:', String(baselineMs).yellow);
  Logger.log('  Report:', reportPath.yellow);

  await waitUntilStarted(
    server,
    envPositiveNumber('OMEGGA_LIVE_COMMAND_CANARY_START_TIMEOUT_MS', 60000),
  );
  await assertStackHealthy(server);

  if (baselineMs > 0) await sleep(baselineMs);
  const metricsBefore = await readMetrics(metricsUrl);
  const canaries = buildDefaultLiveCommandCanaries(targetPlayer);
  const results: LiveCommandCanaryResult[] = [];

  for (const item of canaries) {
    Logger.logp('Live command canary:', item.id.yellow);
    const result = await runCanaryCase(server, item);
    results.push(result);
    if (result.status === 'failed') {
      Logger.warnp(
        'Live command canary failed'.yellow,
        item.id,
        result.commandError || result.healthError || 'unknown failure',
      );
    }
    if (spacingMs > 0) await sleep(spacingMs);
  }

  const metricsAfter = await readMetrics(metricsUrl);
  const failed = results.filter(result => result.status === 'failed');
  const report: LiveCommandCanaryReport = {
    startedAt,
    completedAt: new Date().toISOString(),
    status: failed.length > 0 ? 'failed' : 'passed',
    baselineMs,
    spacingMs,
    targetPlayer,
    metricsUrl,
    metricsBefore,
    metricsAfter,
    results,
  };

  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');

  if (failed.length > 0) {
    Logger.warnp(
      'Live command canary completed with failures'.yellow,
      `${failed.length}/${results.length}`,
    );
    if (process.env.OMEGGA_LIVE_COMMAND_CANARY_FAIL_FAST === '1') {
      throw new Error(
        `live command canary failed: ${failed.map(item => item.id).join(', ')}`,
      );
    }
  } else {
    Logger.logp('Live command canary passed.');
  }

  return report;
}
