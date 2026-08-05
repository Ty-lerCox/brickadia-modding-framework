import { randomBytes } from 'node:crypto';
import EventEmitter from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';
import {
  inferUe4ssServiceClass,
  isSafeUe4ssAdmissionExempt,
  type Ue4ssAdmissionContext,
  type Ue4ssServiceClass,
} from './ue4ssAdmission';

type JsonRpcMessage = {
  jsonrpc: '2.0';
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
};

type PendingRequest = {
  method: string;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout | null;
  consoleOutput?: boolean;
  result?: unknown;
  chunks?: Record<string, unknown>[];
  requestBytes: number;
  serviceClass: Ue4ssServiceClass;
  admissionExempt: boolean;
  issuedAtMs: number;
};

type BridgeCapabilities = Record<string, unknown> | null;

export type Ue4ssBridgeHostOptions = {
  fallbackPollIntervalMs?: number;
  watchOutbox?: boolean;
  maxPendingRequests?: number;
  maxPendingBytes?: number;
  maxRequestBytes?: number;
  exemptMaxPendingRequests?: number;
  exemptMaxPendingBytes?: number;
  queueDeadlineMs?: number;
  boundedAdmissionEnabled?: boolean;
};

const envPositiveNumber = (name: string, fallback: number) => {
  const value = Number(process.env[name] ?? fallback);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

const DEFAULT_READY_TIMEOUT_MS = envPositiveNumber(
  'OMEGGA_UE4SS_READY_TIMEOUT_MS',
  30000,
);
const DEFAULT_REQUEST_TIMEOUT_MS = envPositiveNumber(
  'OMEGGA_UE4SS_REQUEST_TIMEOUT_MS',
  30000,
);
const DEFAULT_FALLBACK_POLL_INTERVAL_MS = 100;
const MAX_OUTBOX_READ_BYTES = 256 * 1024;
const DEFAULT_MAX_PENDING_REQUESTS = envPositiveNumber(
  'OMEGGA_UE4SS_MAX_PENDING_REQUESTS',
  64,
);
const DEFAULT_MAX_PENDING_BYTES = envPositiveNumber(
  'OMEGGA_UE4SS_MAX_PENDING_BYTES',
  256 * 1024,
);
const MAX_INBOX_RECORD_BYTES = 64 * 1024;
const DEFAULT_MAX_REQUEST_BYTES = Math.min(
  MAX_INBOX_RECORD_BYTES,
  envPositiveNumber(
    'OMEGGA_UE4SS_MAX_INBOX_RECORD_BYTES',
    MAX_INBOX_RECORD_BYTES,
  ),
);
const DEFAULT_EXEMPT_MAX_PENDING_REQUESTS = envPositiveNumber(
  'OMEGGA_UE4SS_EXEMPT_MAX_PENDING_REQUESTS',
  4,
);
const DEFAULT_EXEMPT_MAX_PENDING_BYTES = envPositiveNumber(
  'OMEGGA_UE4SS_EXEMPT_MAX_PENDING_BYTES',
  16 * 1024,
);
const DEFAULT_QUEUE_DEADLINE_MS = envPositiveNumber(
  'OMEGGA_UE4SS_QUEUE_DEADLINE_MS',
  3000,
);
const DEFAULT_BOUNDED_ADMISSION_ENABLED =
  process.env.OMEGGA_UE4SS_BOUNDED_ADMISSION_ENABLED !== '0';

export default class Ue4ssBridgeHost extends EventEmitter {
  readonly session = randomBytes(12).toString('hex');
  readonly token = randomBytes(16).toString('hex');
  readonly pipeName = `\\\\.\\pipe\\omegga-ue4ss-${process.pid}-${randomBytes(6).toString('hex')}`;

  readonly bridgeRoot: string;
  readonly sessionDir: string;
  readonly inboxPath: string;
  readonly outboxPath: string;
  readonly statusPath: string;
  readonly hostStatusPath: string;
  readonly tracePath: string;

  #nextRequestId = 1;
  #pending = new Map<number, PendingRequest>();
  #outboxOffset = 0;
  #outboxRemainder = '';
  #outboxDecoder = new StringDecoder('utf8');
  #poller: NodeJS.Timeout = null;
  #outboxWatcher: fs.FSWatcher = null;
  #scheduledOutboxPoll: NodeJS.Immediate = null;
  #outboxWatchEvents = 0;
  #outboxFallbackPolls = 0;
  #outboxReads = 0;
  #outboxBytesRead = 0;
  #lastOutboxReadAt = '';
  #readyInfo: Record<string, unknown> | null = null;
  #stopped = false;
  #admittedInteractive = 0;
  #admittedBulk = 0;
  #admittedExempt = 0;
  #rejectedDepth = 0;
  #rejectedBytes = 0;
  #clientTimeouts = 0;
  #expiredBeforeInbox = 0;
  #completed = 0;
  #writeErrors = 0;
  #highWaterRequests = 0;
  #highWaterBytes = 0;

  readonly fallbackPollIntervalMs: number;
  readonly watchOutbox: boolean;
  readonly maxPendingRequests: number;
  readonly maxPendingBytes: number;
  readonly maxRequestBytes: number;
  readonly exemptMaxPendingRequests: number;
  readonly exemptMaxPendingBytes: number;
  readonly queueDeadlineMs: number;
  readonly boundedAdmissionEnabled: boolean;

  capabilities: BridgeCapabilities = null;

  constructor(bridgeRoot: string, options: Ue4ssBridgeHostOptions = {}) {
    super();

    this.bridgeRoot = bridgeRoot;
    this.sessionDir = path.join(bridgeRoot, this.session);
    this.inboxPath = path.join(this.sessionDir, 'inbox.ndjson');
    this.outboxPath = path.join(this.sessionDir, 'outbox.ndjson');
    this.statusPath = path.join(this.sessionDir, 'status.json');
    this.hostStatusPath = path.join(this.sessionDir, 'host-status.json');
    this.tracePath = path.join(this.sessionDir, 'bridge-trace.log');
    this.fallbackPollIntervalMs = Math.max(
      10,
      Number(options.fallbackPollIntervalMs) ||
        DEFAULT_FALLBACK_POLL_INTERVAL_MS,
    );
    this.watchOutbox = options.watchOutbox !== false;
    this.maxPendingRequests = Math.max(
      1,
      Number(options.maxPendingRequests) || DEFAULT_MAX_PENDING_REQUESTS,
    );
    this.maxPendingBytes = Math.max(
      1,
      Number(options.maxPendingBytes) || DEFAULT_MAX_PENDING_BYTES,
    );
    this.maxRequestBytes = Math.max(
      1,
      Math.min(
        MAX_INBOX_RECORD_BYTES,
        Number(options.maxRequestBytes) || DEFAULT_MAX_REQUEST_BYTES,
      ),
    );
    this.exemptMaxPendingRequests = Math.max(
      1,
      Number(options.exemptMaxPendingRequests) ||
        DEFAULT_EXEMPT_MAX_PENDING_REQUESTS,
    );
    this.exemptMaxPendingBytes = Math.max(
      1,
      Number(options.exemptMaxPendingBytes) || DEFAULT_EXEMPT_MAX_PENDING_BYTES,
    );
    this.queueDeadlineMs = Math.max(
      100,
      Number(options.queueDeadlineMs) || DEFAULT_QUEUE_DEADLINE_MS,
    );
    this.boundedAdmissionEnabled =
      options.boundedAdmissionEnabled ?? DEFAULT_BOUNDED_ADMISSION_ENABLED;
  }

  start() {
    this.stop();
    this.#stopped = false;
    this.#outboxOffset = 0;
    this.#outboxRemainder = '';
    this.#outboxDecoder = new StringDecoder('utf8');
    this.#outboxWatchEvents = 0;
    this.#outboxFallbackPolls = 0;
    this.#outboxReads = 0;
    this.#outboxBytesRead = 0;
    this.#lastOutboxReadAt = '';
    this.#readyInfo = null;
    this.capabilities = null;
    this.#admittedInteractive = 0;
    this.#admittedBulk = 0;
    this.#admittedExempt = 0;
    this.#rejectedDepth = 0;
    this.#rejectedBytes = 0;
    this.#clientTimeouts = 0;
    this.#expiredBeforeInbox = 0;
    this.#completed = 0;
    this.#writeErrors = 0;
    this.#highWaterRequests = 0;
    this.#highWaterBytes = 0;

    fs.mkdirSync(this.sessionDir, { recursive: true });
    fs.writeFileSync(this.inboxPath, '');
    fs.writeFileSync(this.outboxPath, '');
    fs.writeFileSync(this.tracePath, '');
    this.startOutboxWatcher();
    fs.writeFileSync(
      this.hostStatusPath,
      JSON.stringify(
        {
          state: 'awaiting-hello',
          session: this.session,
          token: this.token,
          transport: 'file',
          pipe: this.pipeName,
          updatedAt: new Date().toISOString(),
          outboxReader: this.getOutboxReaderStatus(),
          admission: this.getAdmissionStatus(),
        },
        null,
        2,
      ) + '\n',
    );

    this.#poller = setInterval(() => {
      this.#outboxFallbackPolls += 1;
      this.pollOutbox();
    }, this.fallbackPollIntervalMs);
    this.#poller.unref?.();

    return {
      OMEGGA_UE4SS_TRANSPORT: 'file',
      OMEGGA_UE4SS_PIPE: this.pipeName,
      OMEGGA_UE4SS_SESSION: this.session,
      OMEGGA_UE4SS_TOKEN: this.token,
      OMEGGA_UE4SS_BRIDGE_DIR: this.sessionDir,
      OMEGGA_UE4SS_INBOX: this.inboxPath,
      OMEGGA_UE4SS_OUTBOX: this.outboxPath,
      OMEGGA_UE4SS_STATUS: this.statusPath,
      OMEGGA_UE4SS_HOST_STATUS: this.hostStatusPath,
      OMEGGA_UE4SS_TRACE: this.tracePath,
    };
  }

  stop() {
    this.#stopped = true;
    if (this.#poller) {
      clearInterval(this.#poller);
      this.#poller = null;
    }
    if (this.#outboxWatcher) {
      this.#outboxWatcher.close();
      this.#outboxWatcher = null;
    }
    if (this.#scheduledOutboxPoll) {
      clearImmediate(this.#scheduledOutboxPoll);
      this.#scheduledOutboxPoll = null;
    }

    for (const [id, pending] of this.#pending) {
      if (pending.timeout) clearTimeout(pending.timeout);
      pending.reject(
        new Error(`UE4SS bridge stopped while waiting for ${pending.method}`),
      );
      this.#pending.delete(id);
    }

    this.emit('stopped');
  }

  getOutboxReaderStatus() {
    return {
      mode: this.#outboxWatcher ? 'watch+poll' : 'poll',
      fallbackPollIntervalMs: this.fallbackPollIntervalMs,
      watchEvents: this.#outboxWatchEvents,
      fallbackPolls: this.#outboxFallbackPolls,
      reads: this.#outboxReads,
      bytesRead: this.#outboxBytesRead,
      lastReadAt: this.#lastOutboxReadAt,
    };
  }

  isReady() {
    return this.#readyInfo !== null;
  }

  getReadyInfo() {
    return this.#readyInfo;
  }

  getAdmissionStatus() {
    const pending = [...this.#pending.values()];
    const regular = pending.filter(request => !request.admissionExempt);
    const exempt = pending.filter(request => request.admissionExempt);
    const interactive = regular.filter(
      request => request.serviceClass === 'interactive',
    );
    const bulk = regular.filter(request => request.serviceClass === 'bulk');
    const sumBytes = (requests: PendingRequest[]) =>
      requests.reduce((sum, request) => sum + request.requestBytes, 0);
    const oldestIssuedAtMs = pending.reduce(
      (oldest, request) => Math.min(oldest, request.issuedAtMs),
      Number.POSITIVE_INFINITY,
    );

    return {
      limits: {
        enabled: this.boundedAdmissionEnabled,
        maxPendingRequests: this.maxPendingRequests,
        maxPendingBytes: this.maxPendingBytes,
        maxRequestBytes: this.maxRequestBytes,
        exemptMaxPendingRequests: this.exemptMaxPendingRequests,
        exemptMaxPendingBytes: this.exemptMaxPendingBytes,
        queueDeadlineMs: this.queueDeadlineMs,
      },
      pending: {
        totalRequests: pending.length,
        totalBytes: sumBytes(pending),
        interactiveRequests: interactive.length,
        interactiveBytes: sumBytes(interactive),
        bulkRequests: bulk.length,
        bulkBytes: sumBytes(bulk),
        exemptRequests: exempt.length,
        exemptBytes: sumBytes(exempt),
        oldestAgeMs: Number.isFinite(oldestIssuedAtMs)
          ? Math.max(0, Date.now() - oldestIssuedAtMs)
          : 0,
      },
      admitted: {
        interactive: this.#admittedInteractive,
        bulk: this.#admittedBulk,
        exempt: this.#admittedExempt,
      },
      rejected: {
        depth: this.#rejectedDepth,
        bytes: this.#rejectedBytes,
      },
      clientTimeouts: this.#clientTimeouts,
      expired: this.#expiredBeforeInbox,
      completed: this.#completed,
      writeErrors: this.#writeErrors,
      highWater: {
        requests: this.#highWaterRequests,
        bytes: this.#highWaterBytes,
      },
    };
  }

  getRuntimeAdmissionStatus() {
    try {
      const status = JSON.parse(
        fs.readFileSync(this.statusPath, 'utf8'),
      ) as Record<string, unknown>;
      if (typeof status.inbox_bounded_admission_enabled !== 'boolean') {
        return null;
      }
      const number = (field: string) => {
        const value = Number(status[field]);
        return Number.isFinite(value) ? value : 0;
      };
      return {
        enabled: status.inbox_bounded_admission_enabled === true,
        processed: number('inbox_processed_total'),
        admittedInteractive: number('inbox_admitted_interactive_total'),
        admittedBulk: number('inbox_admitted_bulk_total'),
        expired: number('inbox_expired_total'),
        deadlineMissing: number('inbox_deadline_missing_total'),
        oversize: number('inbox_oversize_total'),
        bmfDispatchBlocked: number('inbox_bmf_dispatch_blocked_total'),
        pendingBytes: number('inbox_pending_bytes'),
        pendingBytesHighWater: number('inbox_pending_bytes_high_water'),
        lastQueueAgeMs: number('inbox_last_queue_age_ms'),
        maxQueueAgeMs: number('inbox_max_queue_age_ms'),
      };
    } catch (_error) {
      return null;
    }
  }

  waitUntilReady(timeoutMs = DEFAULT_READY_TIMEOUT_MS) {
    if (this.#readyInfo) return Promise.resolve(this.#readyInfo);
    if (this.#stopped)
      return Promise.reject(new Error('UE4SS bridge is stopped.'));

    return new Promise((resolve, reject) => {
      const onReady = (info: Record<string, unknown>) => {
        cleanup();
        resolve(info);
      };
      const onStopped = () => {
        cleanup();
        reject(new Error('UE4SS bridge stopped before it became ready.'));
      };
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error('Timed out waiting for UE4SS bridge hello.'));
      }, timeoutMs);

      const cleanup = () => {
        clearTimeout(timer);
        this.off('ready', onReady);
        this.off('stopped', onStopped);
      };

      this.on('ready', onReady);
      this.on('stopped', onStopped);
    });
  }

  async ping(
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    const nonce = randomBytes(8).toString('hex');
    return this.request('bridge.ping', { nonce }, timeoutMs, {
      ...admission,
      admissionExempt: true,
      serviceClass: 'interactive',
    });
  }

  async execCommand(
    command: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    const normalizedCommand = command.replace(/\r?\n$/, '');
    const commandB64 = Buffer.from(normalizedCommand, 'utf8').toString(
      'base64',
    );
    return this.request(
      'console.exec',
      {
        command_b64: commandB64,
        issued_at: new Date().toISOString(),
      },
      timeoutMs,
      {
        admissionExempt: isSafeUe4ssAdmissionExempt(normalizedCommand),
        serviceClass: inferUe4ssServiceClass(normalizedCommand),
        ...admission,
      },
    );
  }

  async execCommandWithOutput(
    command: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    const normalizedCommand = command.replace(/\r?\n$/, '');
    const commandB64 = Buffer.from(normalizedCommand, 'utf8').toString(
      'base64',
    );
    return this.request(
      'console.exec',
      {
        command_b64: commandB64,
        issued_at: new Date().toISOString(),
      },
      timeoutMs,
      {
        consoleOutput: true,
        admissionExempt: isSafeUe4ssAdmissionExempt(normalizedCommand),
        serviceClass: inferUe4ssServiceClass(normalizedCommand),
        ...admission,
      },
    );
  }

  async broadcast(
    message: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'chat.broadcast',
      {
        message_b64: Buffer.from(message, 'utf8').toString('base64'),
      },
      timeoutMs,
      { serviceClass: 'interactive', ...admission },
    );
  }

  async whisper(
    target: string,
    message: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'chat.whisper',
      {
        target_b64: Buffer.from(target, 'utf8').toString('base64'),
        message_b64: Buffer.from(message, 'utf8').toString('base64'),
      },
      timeoutMs,
      { serviceClass: 'interactive', ...admission },
    );
  }

  async statusMessage(
    target: string,
    message: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'chat.status_message',
      {
        target_b64: Buffer.from(target, 'utf8').toString('base64'),
        message_b64: Buffer.from(message, 'utf8').toString('base64'),
      },
      timeoutMs,
      { serviceClass: 'interactive', ...admission },
    );
  }

  async requestServerStatus(
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request('server.status', {}, timeoutMs, {
      ...admission,
      admissionExempt: true,
      serviceClass: 'interactive',
    });
  }

  async requestPlayers(
    format: 'records' | 'usernames' | 'owners' = 'records',
    options: { stateName?: string } = {},
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    admission: Partial<Ue4ssAdmissionContext> = {},
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'players.list',
      {
        format,
        ...(options.stateName
          ? {
              state_name_b64: Buffer.from(options.stateName, 'utf8').toString(
                'base64',
              ),
            }
          : {}),
      },
      timeoutMs,
      { serviceClass: 'bulk', ...admission },
    );
  }

  hasCapability(capability: string) {
    return Boolean(this.capabilities?.[capability]);
  }

  hasNativeCapability(capability: string) {
    return Boolean(this.capabilities?.[`${capability}_native`]);
  }

  getCapabilities() {
    return this.capabilities;
  }

  private request(
    method: string,
    params: Record<string, unknown>,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    options: Partial<Ue4ssAdmissionContext> & {
      consoleOutput?: boolean;
    } = {},
  ) {
    if (this.#stopped) {
      return Promise.reject(new Error('UE4SS bridge is stopped.'));
    }

    const id = this.#nextRequestId++;
    const nowMs = Date.now();
    const requestedIssuedAtMs = Number(options.issuedAtMs);
    const issuedAtMs =
      Number.isFinite(requestedIssuedAtMs) && requestedIssuedAtMs > 0
        ? requestedIssuedAtMs
        : nowMs;
    const normalizedTimeoutMs =
      Number.isFinite(timeoutMs) && timeoutMs > 0
        ? Math.max(100, timeoutMs)
        : 0;
    const deadlineTtlMs = Math.min(
      normalizedTimeoutMs || this.queueDeadlineMs,
      this.queueDeadlineMs,
    );
    const requestedDeadlineMs = Number(options.deadlineMs);
    const deadlineMs = this.boundedAdmissionEnabled
      ? Number.isFinite(requestedDeadlineMs) && requestedDeadlineMs > 0
        ? requestedDeadlineMs
        : issuedAtMs + deadlineTtlMs
      : 0;
    if (this.boundedAdmissionEnabled && deadlineMs <= nowMs) {
      this.#expiredBeforeInbox += 1;
      return Promise.reject(
        new Error(`UE4SS request expired before inbox append: ${method}.`),
      );
    }
    const serviceClass =
      options.serviceClass === 'bulk' ? 'bulk' : 'interactive';
    const admissionExempt = options.admissionExempt === true;
    const message: JsonRpcMessage = {
      jsonrpc: '2.0',
      id,
      method,
      params: {
        ...params,
        issued_at_ms: issuedAtMs,
        deadline_ms: deadlineMs,
        service_class: serviceClass,
        admission_exempt: admissionExempt,
      },
    };
    const serializedMessage = JSON.stringify(message) + '\n';
    const requestBytes = Buffer.byteLength(serializedMessage, 'utf8');
    const responseTimeoutMs =
      normalizedTimeoutMs > 0
        ? Math.max(
            1,
            Math.min(
              normalizedTimeoutMs,
              deadlineMs > 0 ? deadlineMs - nowMs : normalizedTimeoutMs,
            ),
          )
        : 0;
    const sameAdmissionClass = [...this.#pending.values()].filter(
      request => request.admissionExempt === admissionExempt,
    );
    const pendingBytes = sameAdmissionClass.reduce(
      (sum, request) => sum + request.requestBytes,
      0,
    );
    const requestLimit = admissionExempt
      ? this.exemptMaxPendingRequests
      : this.maxPendingRequests;
    const byteLimit = admissionExempt
      ? this.exemptMaxPendingBytes
      : this.maxPendingBytes;
    if (
      this.boundedAdmissionEnabled &&
      sameAdmissionClass.length >= requestLimit
    ) {
      this.#rejectedDepth += 1;
      return Promise.reject(
        new Error(
          `UE4SS inbox admission rejected: ${admissionExempt ? 'reserved' : 'regular'} pending request limit ${requestLimit} reached.`,
        ),
      );
    }
    if (
      this.boundedAdmissionEnabled &&
      (requestBytes > this.maxRequestBytes ||
        requestBytes > byteLimit ||
        pendingBytes + requestBytes > byteLimit)
    ) {
      this.#rejectedBytes += 1;
      return Promise.reject(
        new Error(
          `UE4SS inbox admission rejected: ${admissionExempt ? 'reserved' : 'regular'} pending byte limit ${byteLimit} reached.`,
        ),
      );
    }

    if (admissionExempt) this.#admittedExempt += 1;
    else if (serviceClass === 'bulk') this.#admittedBulk += 1;
    else this.#admittedInteractive += 1;

    return new Promise((resolve, reject) => {
      const timeout =
        responseTimeoutMs > 0
          ? setTimeout(() => {
              this.#pending.delete(id);
              this.#clientTimeouts += 1;
              reject(
                new Error(`Timed out waiting for UE4SS response to ${method}.`),
              );
            }, responseTimeoutMs)
          : null;

      this.#pending.set(id, {
        method,
        resolve,
        reject,
        timeout,
        consoleOutput: options.consoleOutput === true,
        chunks: options.consoleOutput === true ? [] : undefined,
        requestBytes,
        serviceClass,
        admissionExempt,
        issuedAtMs,
      });
      const status = this.getAdmissionStatus();
      this.#highWaterRequests = Math.max(
        this.#highWaterRequests,
        status.pending.totalRequests,
      );
      this.#highWaterBytes = Math.max(
        this.#highWaterBytes,
        status.pending.totalBytes,
      );

      try {
        this.appendInboxMessage(serializedMessage);
      } catch (error) {
        if (timeout) clearTimeout(timeout);
        this.#pending.delete(id);
        this.#writeErrors += 1;
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private appendInboxMessage(serializedMessage: string) {
    fs.appendFileSync(this.inboxPath, serializedMessage);
  }

  private startOutboxWatcher() {
    if (!this.watchOutbox) return;

    try {
      this.#outboxWatcher = fs.watch(this.outboxPath, () => {
        this.#outboxWatchEvents += 1;
        this.scheduleOutboxPoll();
      });
      this.#outboxWatcher.on('error', error => {
        this.emit('log', {
          level: 'warn',
          message: `UE4SS outbox watcher degraded to polling: ${String(error)}`,
        });
        this.#outboxWatcher?.close();
        this.#outboxWatcher = null;
      });
    } catch (error) {
      this.#outboxWatcher = null;
      this.emit('log', {
        level: 'warn',
        message: `UE4SS outbox watcher unavailable; using polling: ${String(error)}`,
      });
    }
  }

  private scheduleOutboxPoll() {
    if (this.#stopped || this.#scheduledOutboxPoll) return;
    this.#scheduledOutboxPoll = setImmediate(() => {
      this.#scheduledOutboxPoll = null;
      this.pollOutbox();
    });
    this.#scheduledOutboxPoll.unref?.();
  }

  private pollOutbox() {
    if (this.#stopped || !fs.existsSync(this.outboxPath)) return;

    try {
      this.consumeOutbox();
    } catch (error) {
      this.emit('log', {
        level: 'warn',
        message: `UE4SS outbox read failed; fallback polling remains active: ${String(error)}`,
      });
    }
  }

  private consumeOutbox() {
    const size = fs.statSync(this.outboxPath).size;
    if (size < this.#outboxOffset) {
      this.#outboxOffset = 0;
      this.#outboxRemainder = '';
      this.#outboxDecoder = new StringDecoder('utf8');
    }
    if (size <= this.#outboxOffset) return;

    const nextLength = Math.min(
      size - this.#outboxOffset,
      MAX_OUTBOX_READ_BYTES,
    );
    const buffer = Buffer.allocUnsafe(nextLength);
    const descriptor = fs.openSync(this.outboxPath, 'r');
    let bytesRead = 0;
    try {
      bytesRead = fs.readSync(
        descriptor,
        buffer,
        0,
        nextLength,
        this.#outboxOffset,
      );
    } finally {
      fs.closeSync(descriptor);
    }
    if (bytesRead <= 0) return;

    const nextChunk = this.#outboxDecoder.write(buffer.subarray(0, bytesRead));
    this.#outboxOffset += bytesRead;
    this.#outboxReads += 1;
    this.#outboxBytesRead += bytesRead;
    this.#lastOutboxReadAt = new Date().toISOString();
    const combinedChunk = this.#outboxRemainder + nextChunk;
    const lines = combinedChunk.split(/\r?\n/);
    this.#outboxRemainder = lines.pop() ?? '';

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      let message: JsonRpcMessage;
      try {
        message = JSON.parse(trimmed) as JsonRpcMessage;
      } catch (error) {
        this.emit('log', {
          level: 'warn',
          message: `UE4SS bridge emitted invalid JSON: ${trimmed}`,
          error,
        });
        continue;
      }

      this.handleMessage(message);
    }

    if (size > this.#outboxOffset) this.scheduleOutboxPoll();
  }

  private handleMessage(message: JsonRpcMessage) {
    if (
      typeof message.id === 'number' &&
      (!message.method || 'result' in message || 'error' in message)
    ) {
      const pending = this.#pending.get(message.id);
      if (!pending) return;

      if (message.error) {
        if (pending.timeout) clearTimeout(pending.timeout);
        this.#pending.delete(message.id);
        this.#completed += 1;
        pending.reject(
          new Error(
            `${pending.method} failed: ${message.error.message}${
              message.error.data
                ? ` (${JSON.stringify(message.error.data)})`
                : ''
            }`,
          ),
        );
        return;
      }

      if (pending.consoleOutput) {
        pending.result = message.result;
        return;
      }

      if (pending.timeout) clearTimeout(pending.timeout);
      this.#pending.delete(message.id);
      this.#completed += 1;
      pending.resolve(message.result);
      return;
    }

    if (!message.method) return;
    const params = (message.params ?? {}) as Record<string, unknown>;

    switch (message.method) {
      case 'bridge.hello': {
        if (params.session && params.session !== this.session) {
          this.emit('log', {
            level: 'warn',
            message: `UE4SS bridge hello session mismatch: ${String(params.session)}`,
          });
          return;
        }

        this.#readyInfo = params;
        this.emit('ready', params);
        this.writeStatus('ready', params);
        break;
      }

      case 'bridge.capabilities':
        this.capabilities = params;
        this.emit('capabilities', params);
        break;

      case 'bridge.log':
        this.emit('log', params);
        break;

      case 'console.chunk': {
        const line =
          typeof params.line_b64 === 'string'
            ? Buffer.from(params.line_b64, 'base64').toString('utf8')
            : String(params.line ?? '');
        const payload = {
          ...params,
          line,
        };
        const requestId = Number(params.request_id);
        const pending = this.#pending.get(requestId);
        if (pending?.consoleOutput) {
          pending.chunks?.push(payload);
        }
        this.emit('console.chunk', payload);
        break;
      }

      case 'console.complete': {
        const requestId = Number(params.request_id);
        const pending = this.#pending.get(requestId);
        if (pending?.consoleOutput) {
          if (pending.timeout) clearTimeout(pending.timeout);
          this.#pending.delete(requestId);
          this.#completed += 1;
          pending.resolve({
            result: pending.result ?? null,
            chunks: pending.chunks ?? [],
            complete: params,
          });
        }
        this.emit('console.complete', params);
        break;
      }

      default:
        this.emit('log', {
          level: 'warn',
          message: `Unhandled UE4SS bridge method ${message.method}`,
        });
    }
  }

  private writeStatus(state: string, extra: Record<string, unknown> = {}) {
    fs.writeFileSync(
      this.hostStatusPath,
      JSON.stringify(
        {
          state,
          session: this.session,
          token: this.token,
          updatedAt: new Date().toISOString(),
          outboxReader: this.getOutboxReaderStatus(),
          admission: this.getAdmissionStatus(),
          ...extra,
        },
        null,
        2,
      ) + '\n',
    );
  }
}
