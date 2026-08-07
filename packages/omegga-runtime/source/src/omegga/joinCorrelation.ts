import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export const JOIN_CORRELATION_PHASES = [
  'log_to_matcher',
  'player_lookup_reconciliation',
  'connection_generation',
  'join_event_emission',
  'plugin_worker_transport',
  'plugin_join_callback',
  'player_sync_snapshot',
  'player_sync_serialization',
  'player_sync_file_publication',
  'player_sync_bridge_transport',
  'bmf_snapshot_ingestion',
  'bmf_readiness_transition',
] as const;

export type JoinCorrelationPhase = (typeof JOIN_CORRELATION_PHASES)[number];
export type JoinCorrelationOutcome = 'ok' | 'error' | 'dropped';

export type JoinCorrelationContext = {
  schemaVersion: 1;
  correlationId: string;
  logObservedAtUnixMs: number;
  matcherCompletedAtUnixMs: number;
  connectionGeneration?: number;
};

export type JoinCorrelationPhaseRecord = {
  correlationId: string;
  phase: JoinCorrelationPhase;
  outcome: JoinCorrelationOutcome;
  startedAtUnixMs: number;
  endedAtUnixMs: number;
  durationMs?: number;
  component?: string;
  callback?: string;
  detail?: Record<string, string | number | boolean>;
};

type Aggregate = {
  count: number;
  durationMsSum: number;
  durationMsMax: number;
  durationMsLast: number;
};

type OperationRecord = {
  observedAtUnixMs: number;
  operationClass: string;
  phase?: JoinCorrelationPhase;
  outcome?: JoinCorrelationOutcome;
  component?: string;
  callback?: string;
  durationMs?: number;
};

type SlowFrameRecord = {
  sequence: number;
  observed_at_unix_ms: number;
  sample: number;
  delta_ms: number;
  idle: boolean;
};

type RecentFrameSample = {
  sequence: number;
  observed_at_unix_ms: number;
  sample: number;
  delta_ms: number;
  idle: boolean;
};

const PHASE_SET = new Set<string>(JOIN_CORRELATION_PHASES);
const OUTCOME_SET = new Set<string>(['ok', 'error', 'dropped']);
const CORRELATION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9-]{0,95}$/;
const MAX_OPERATION_RECORDS = 512;
const MAX_OPERATION_AGE_MS = 10_000;
const FRAME_CONTEXT_BEFORE_MS = 500;
const FRAME_CONTEXT_AFTER_MS = 1000;
const JOIN_FRAME_CAPTURE_DELAY_MS = 1250;

const finiteTimestamp = (value: unknown, fallback = Date.now()) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
};

const boundedText = (value: unknown, fallback: string, max = 96) => {
  const normalized = String(value ?? '')
    .trim()
    .replace(/[^A-Za-z0-9_.-]+/g, '_')
    .replace(/_+/g, '_')
    .slice(0, max);
  return normalized || fallback;
};

const compactDetail = (value: unknown) => {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    return undefined;
  const output: Record<string, string | number | boolean> = {};
  for (const [rawKey, rawValue] of Object.entries(value).slice(0, 12)) {
    const key = boundedText(rawKey, '', 48);
    if (
      !key ||
      /(?:uuid|player_name|username|token|payload|command|object|path|address)/i.test(
        key,
      )
    )
      continue;
    if (typeof rawValue === 'boolean') output[key] = rawValue;
    else if (typeof rawValue === 'number' && Number.isFinite(rawValue))
      output[key] = rawValue;
    else if (typeof rawValue === 'string')
      output[key] = boundedText(rawValue, 'unknown', 96);
  }
  return Object.keys(output).length ? output : undefined;
};

const runtimeProvenance = (writer: string) => {
  let identity: Record<string, unknown> = {};
  const identityPath = String(
    process.env.BMF_PROVENANCE_IDENTITY_PATH ?? '',
  ).trim();
  try {
    identity = JSON.parse(fs.readFileSync(identityPath, 'utf8')) as Record<
      string,
      unknown
    >;
  } catch (_error) {
    // Missing provenance remains explicitly unverified and is rejected by the harness gate.
  }
  return {
    environment: String(identity.environment ?? 'unverified'),
    brickadiaPid: Number(identity.brickadiaPid ?? 0) || 0,
    omeggaPid: Number(identity.omeggaPid ?? process.pid) || process.pid,
    processStartTimestamp: Number(identity.processStartTimestamp ?? 0) || 0,
    brickadiaStartTimestamp:
      Number(identity.brickadiaStartTimestamp ?? 0) || 0,
    omeggaStartTimestamp: Number(identity.omeggaStartTimestamp ?? 0) || 0,
    udpPort: Number(identity.udpPort ?? 0) || 0,
    installationRoot: String(identity.installationRoot ?? ''),
    runtimeRoot: String(identity.runtimeRoot ?? ''),
    runtimeHash: String(identity.runtimeHash ?? ''),
    telemetryWriterIdentity: boundedText(
      writer,
      'bmf.omegga.join_attribution',
    ),
    telemetryGenerationTimestamp: Date.now(),
  };
};

export const normalizeJoinCorrelationContext = (
  value: unknown,
): JoinCorrelationContext | undefined => {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    return undefined;
  const source = value as Record<string, unknown>;
  const correlationId = String(source.correlationId ?? '').trim();
  if (!CORRELATION_PATTERN.test(correlationId)) return undefined;
  const connectionGeneration = Number(source.connectionGeneration);
  return {
    schemaVersion: 1,
    correlationId,
    logObservedAtUnixMs: finiteTimestamp(source.logObservedAtUnixMs),
    matcherCompletedAtUnixMs: finiteTimestamp(source.matcherCompletedAtUnixMs),
    ...(Number.isSafeInteger(connectionGeneration) && connectionGeneration > 0
      ? { connectionGeneration }
      : {}),
  };
};

export const normalizeJoinCorrelationPhaseRecord = (
  value: unknown,
): JoinCorrelationPhaseRecord | undefined => {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    return undefined;
  const source = value as Record<string, unknown>;
  const correlationId = String(source.correlationId ?? '').trim();
  const phase = String(source.phase ?? '');
  const outcome = String(source.outcome ?? 'ok');
  if (
    !CORRELATION_PATTERN.test(correlationId) ||
    !PHASE_SET.has(phase) ||
    !OUTCOME_SET.has(outcome)
  ) {
    return undefined;
  }
  const startedAtUnixMs = finiteTimestamp(source.startedAtUnixMs);
  const endedAtUnixMs = Math.max(
    startedAtUnixMs,
    finiteTimestamp(source.endedAtUnixMs, startedAtUnixMs),
  );
  return {
    correlationId,
    phase: phase as JoinCorrelationPhase,
    outcome: outcome as JoinCorrelationOutcome,
    startedAtUnixMs,
    endedAtUnixMs,
    durationMs: Math.max(
      0,
      Math.min(
        60_000,
        Number.isFinite(Number(source.durationMs))
          ? Number(source.durationMs)
          : endedAtUnixMs - startedAtUnixMs,
      ),
    ),
    component: source.component
      ? boundedText(source.component, 'unknown')
      : undefined,
    callback: source.callback
      ? boundedText(source.callback, 'anonymous')
      : undefined,
    detail: compactDetail(source.detail),
  };
};

const extractRuntimeSummary = (runtimeDir: string) => {
  const read = (name: string) => {
    try {
      return JSON.parse(
        fs.readFileSync(path.join(runtimeDir, name), 'utf8'),
      ) as Record<string, unknown>;
    } catch (_error) {
      return {};
    }
  };
  const status = read('status.json');
  const telemetry = read('telemetry.json');
  const playerSync = read('bmf-player-sync-status.json');
  const direct = (status.direct ?? {}) as Record<string, unknown>;
  const tunnel = (status.tunnel ?? {}) as Record<string, unknown>;
  const operations = (telemetry.operations ?? {}) as Record<string, unknown>;
  const scheduler = (telemetry.scheduler ?? {}) as Record<string, unknown>;
  const syncCounters = (playerSync.syncCounters ?? {}) as Record<
    string,
    unknown
  >;
  return {
    directDepth: Number(direct.depth ?? direct.queue_depth ?? 0) || 0,
    directOldestAgeMs:
      Number(direct.oldest_age_ms ?? direct.oldestAgeMs ?? 0) || 0,
    tunnelDepth: Number(tunnel.depth ?? tunnel.queue_depth ?? 0) || 0,
    tunnelOldestAgeMs:
      Number(tunnel.oldest_age_ms ?? tunnel.oldestAgeMs ?? 0) || 0,
    controllerResolutions:
      Number(operations.controller_resolutions_total ?? 0) || 0,
    globalScans: Number(operations.global_scan_total ?? 0) || 0,
    repairs: Number(operations.repair_total ?? 0) || 0,
    schedulerTier: boundedText(
      scheduler.current_tier ?? scheduler.tier ?? 'unknown',
      'unknown',
    ),
    playerSyncTriggersCoalesced:
      Number(syncCounters.triggersCoalesced ?? 0) || 0,
  };
};

export class JoinCorrelationTracker {
  readonly enabled: boolean;
  readonly outputDir: string;
  readonly runtimeDir: string;
  private readonly aggregates = new Map<string, Aggregate>();
  private readonly operations: OperationRecord[] = [];
  private readonly pendingFrameSequences = new Set<number>();
  private readonly pendingJoinFrameWindows = new Set<string>();
  private writeChain: Promise<void> = Promise.resolve();
  private droppedWrites = 0;

  constructor(
    options: {
      enabled?: boolean;
      outputDir?: string;
      runtimeDir?: string;
    } = {},
  ) {
    this.enabled =
      options.enabled ??
      ['1', 'true', 'on', 'yes'].includes(
        String(process.env.OMEGGA_BMF_JOIN_HITCH_ATTRIBUTION_ENABLED ?? '')
          .trim()
          .toLowerCase(),
      );
    const configuredStatusPath = process.env.OMEGGA_BMF_STATUS_PATH?.trim();
    this.runtimeDir =
      options.runtimeDir ||
      (configuredStatusPath
        ? path.dirname(configuredStatusPath)
        : process.cwd());
    this.outputDir =
      options.outputDir ||
      process.env.OMEGGA_BMF_JOIN_CORRELATION_DIR?.trim() ||
      this.runtimeDir;
  }

  create(logObservedAtUnixMs = Date.now()): JoinCorrelationContext | undefined {
    if (!this.enabled) return undefined;
    const matcherCompletedAtUnixMs = Date.now();
    const context: JoinCorrelationContext = {
      schemaVersion: 1,
      correlationId: `join-${randomUUID()}`,
      logObservedAtUnixMs,
      matcherCompletedAtUnixMs,
    };
    this.record({
      correlationId: context.correlationId,
      phase: 'log_to_matcher',
      outcome: 'ok',
      startedAtUnixMs: logObservedAtUnixMs,
      endedAtUnixMs: matcherCompletedAtUnixMs,
      component: 'omegga_join_matcher',
    });
    this.scheduleJoinFrameWindow(context);
    return context;
  }

  record(value: unknown) {
    if (!this.enabled) return false;
    const record = normalizeJoinCorrelationPhaseRecord(value);
    if (!record) return false;
    const durationMs = Number(record.durationMs) || 0;
    const aggregateKey = `${record.phase}:${record.outcome}`;
    const aggregate = this.aggregates.get(aggregateKey) ?? {
      count: 0,
      durationMsSum: 0,
      durationMsMax: 0,
      durationMsLast: 0,
    };
    aggregate.count += 1;
    aggregate.durationMsSum += durationMs;
    aggregate.durationMsMax = Math.max(aggregate.durationMsMax, durationMs);
    aggregate.durationMsLast = durationMs;
    this.aggregates.set(aggregateKey, aggregate);
    this.noteOperation({
      observedAtUnixMs: record.endedAtUnixMs,
      operationClass: record.phase,
      phase: record.phase,
      outcome: record.outcome,
      component: record.component,
      callback: record.callback,
      durationMs,
    });
    this.appendJsonLine('join-correlation.ndjson', {
      schemaVersion: 1,
      type: 'join_phase',
      ...record,
      recordedAtUnixMs: Date.now(),
    });
    return true;
  }

  noteOperation(value: Partial<OperationRecord> & { operationClass: string }) {
    if (!this.enabled) return;
    this.operations.push({
      observedAtUnixMs: finiteTimestamp(value.observedAtUnixMs),
      operationClass: boundedText(value.operationClass, 'unknown'),
      phase: value.phase,
      outcome: value.outcome,
      component: value.component
        ? boundedText(value.component, 'unknown')
        : undefined,
      callback: value.callback
        ? boundedText(value.callback, 'anonymous')
        : undefined,
      durationMs: Number.isFinite(Number(value.durationMs))
        ? Math.max(0, Number(value.durationMs))
        : undefined,
    });
    const cutoff = Date.now() - MAX_OPERATION_AGE_MS;
    while (
      this.operations.length > MAX_OPERATION_RECORDS ||
      (this.operations[0]?.observedAtUnixMs ?? cutoff) < cutoff
    ) {
      this.operations.shift();
    }
  }

  handleLine(line: string) {
    if (!this.enabled) return;
    const text = String(line ?? '');
    const marker = text.match(/\[BMF_SLOW_FRAME\]\s+(\{.*\})/);
    if (marker) {
      try {
        const parsed = JSON.parse(marker[1]) as SlowFrameRecord;
        this.scheduleFrameContext(parsed);
      } catch (_error) {
        // Malformed native diagnostic lines are ignored rather than retried.
      }
      return;
    }
    const operationClass = /autosave|saving world|saveworld/i.test(text)
      ? 'autosave'
      : /server\.status|server status|status poll/i.test(text)
        ? 'server_status_poll'
        : /role|assignment/i.test(text)
          ? 'role_assignment_refresh'
          : /BMF.*(?:callback|hook)/i.test(text)
            ? 'native_callback'
            : '';
    if (operationClass) this.noteOperation({ operationClass });
  }

  metricsSnapshot() {
    const phases: Record<string, Record<string, Aggregate>> = {};
    for (const [key, aggregate] of this.aggregates) {
      const [phase, outcome] = key.split(':');
      phases[phase] ??= {};
      phases[phase][outcome] = { ...aggregate };
    }
    return {
      enabled: this.enabled,
      droppedWrites: this.droppedWrites,
      phases,
    };
  }

  async flush() {
    await this.writeChain;
  }

  private scheduleFrameContext(frame: SlowFrameRecord) {
    const sequence = Number(frame.sequence);
    const observedAtUnixMs = Number(frame.observed_at_unix_ms);
    const deltaMs = Number(frame.delta_ms);
    if (
      !Number.isSafeInteger(sequence) ||
      sequence < 1 ||
      !Number.isFinite(observedAtUnixMs) ||
      !Number.isFinite(deltaMs) ||
      deltaMs < 33.3 ||
      this.pendingFrameSequences.has(sequence)
    ) {
      return;
    }
    this.pendingFrameSequences.add(sequence);
    const scheduledAt = Date.now();
    const cpuStart = process.cpuUsage();
    const delayMs = Math.max(
      0,
      observedAtUnixMs + FRAME_CONTEXT_AFTER_MS - scheduledAt,
    );
    const timer = setTimeout(() => {
      this.pendingFrameSequences.delete(sequence);
      const capturedAt = Date.now();
      const cpu = process.cpuUsage(cpuStart);
      const operations = this.operations.filter(
        operation =>
          operation.observedAtUnixMs >=
            observedAtUnixMs - FRAME_CONTEXT_BEFORE_MS &&
          operation.observedAtUnixMs <=
            observedAtUnixMs + FRAME_CONTEXT_AFTER_MS,
      );
      this.appendJsonLine('frame-spike-context.ndjson', {
        schemaVersion: 1,
        type: 'frame_spike_context',
        frame: {
          sequence,
          sample: Number(frame.sample) || 0,
          observedAtUnixMs,
          deltaMs,
          idle: frame.idle === true,
        },
        window: {
          beforeMs: FRAME_CONTEXT_BEFORE_MS,
          afterMs: FRAME_CONTEXT_AFTER_MS,
        },
        operations,
        runtime: extractRuntimeSummary(this.runtimeDir),
        process: {
          pid: process.pid,
          cpuUserMs: cpu.user / 1000,
          cpuSystemMs: cpu.system / 1000,
          eventLoopLagMs: Math.max(0, capturedAt - (scheduledAt + delayMs)),
        },
        capturedAtUnixMs: capturedAt,
      });
    }, delayMs);
    timer.unref?.();
  }

  private scheduleJoinFrameWindow(context: JoinCorrelationContext) {
    if (this.pendingJoinFrameWindows.has(context.correlationId)) return;
    this.pendingJoinFrameWindows.add(context.correlationId);
    const timer = setTimeout(() => {
      this.pendingJoinFrameWindows.delete(context.correlationId);
      const framePath =
        String(process.env.BMF_FRAME_TELEMETRY_PATH ?? '').trim() ||
        path.join(this.runtimeDir, 'frame-telemetry.json');
      let samples: RecentFrameSample[] = [];
      try {
        const document = JSON.parse(
          fs.readFileSync(framePath, 'utf8'),
        ) as Record<string, unknown>;
        const recentSamples = (document.recent_samples ?? {}) as Record<
          string,
          unknown
        >;
        samples = Array.isArray(recentSamples.recent)
          ? (recentSamples.recent as RecentFrameSample[])
          : [];
      } catch (_error) {
        // The record is still emitted; the provenance gate rejects a missing sample window.
      }
      const windowStart =
        context.logObservedAtUnixMs - FRAME_CONTEXT_BEFORE_MS;
      const windowEnd = context.logObservedAtUnixMs + FRAME_CONTEXT_AFTER_MS;
      const windowSamples = samples.filter(sample => {
        const observedAt = Number(sample.observed_at_unix_ms);
        return observedAt >= windowStart && observedAt <= windowEnd;
      });
      const maxDeltaMs = windowSamples.reduce(
        (maximum, sample) => Math.max(maximum, Number(sample.delta_ms) || 0),
        0,
      );
      this.appendJsonLine('join-correlation.ndjson', {
        schemaVersion: 1,
        type: 'join_frame_window',
        correlationId: context.correlationId,
        joinObservedAtUnixMs: context.logObservedAtUnixMs,
        window: {
          beforeMs: FRAME_CONTEXT_BEFORE_MS,
          afterMs: FRAME_CONTEXT_AFTER_MS,
          samples: windowSamples.length,
          maxDeltaMs,
          threshold33Count: windowSamples.filter(
            sample => Number(sample.delta_ms) >= 33.3,
          ).length,
          threshold100Count: windowSamples.filter(
            sample => Number(sample.delta_ms) >= 100,
          ).length,
        },
        frameTelemetryPath: framePath,
        capturedAtUnixMs: Date.now(),
      });
    }, JOIN_FRAME_CAPTURE_DELAY_MS);
    timer.unref?.();
  }

  private appendJsonLine(fileName: string, value: unknown) {
    if (!this.enabled) return;
    const record =
      value && typeof value === 'object' && !Array.isArray(value)
        ? {
            ...(value as Record<string, unknown>),
            provenance: runtimeProvenance(`bmf.omegga.${fileName}`),
          }
        : value;
    const line = `${JSON.stringify(record)}\n`;
    this.writeChain = this.writeChain
      .then(async () => {
        await fs.promises.mkdir(this.outputDir, { recursive: true });
        await fs.promises.appendFile(
          path.join(this.outputDir, fileName),
          line,
          'utf8',
        );
      })
      .catch(() => {
        this.droppedWrites += 1;
      });
  }
}
