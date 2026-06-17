import { randomBytes } from 'node:crypto';
import EventEmitter from 'node:events';
import fs from 'node:fs';
import path from 'node:path';

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
};

type BridgeCapabilities = Record<string, unknown> | null;

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
const DEFAULT_POLL_INTERVAL_MS = 100;

export default class Ue4ssBridgeHost extends EventEmitter {
  readonly session = randomBytes(12).toString('hex');
  readonly token = randomBytes(16).toString('hex');
  readonly pipeName = `\\\\.\\pipe\\omegga-ue4ss-${process.pid}-${randomBytes(6).toString('hex')}`;

  readonly bridgeRoot: string;
  readonly sessionDir: string;
  readonly inboxPath: string;
  readonly outboxPath: string;
  readonly statusPath: string;
  readonly tracePath: string;

  #nextRequestId = 1;
  #pending = new Map<number, PendingRequest>();
  #outboxOffset = 0;
  #outboxRemainder = '';
  #poller: NodeJS.Timeout = null;
  #readyInfo: Record<string, unknown> | null = null;
  #stopped = false;

  capabilities: BridgeCapabilities = null;

  constructor(bridgeRoot: string) {
    super();

    this.bridgeRoot = bridgeRoot;
    this.sessionDir = path.join(bridgeRoot, this.session);
    this.inboxPath = path.join(this.sessionDir, 'inbox.ndjson');
    this.outboxPath = path.join(this.sessionDir, 'outbox.ndjson');
    this.statusPath = path.join(this.sessionDir, 'status.json');
    this.tracePath = path.join(this.sessionDir, 'bridge-trace.log');
  }

  start() {
    this.stop();
    this.#stopped = false;
    this.#outboxOffset = 0;
    this.#outboxRemainder = '';
    this.#readyInfo = null;
    this.capabilities = null;

    fs.mkdirSync(this.sessionDir, { recursive: true });
    fs.writeFileSync(this.inboxPath, '');
    fs.writeFileSync(this.outboxPath, '');
    fs.writeFileSync(this.tracePath, '');
    fs.writeFileSync(
      this.statusPath,
      JSON.stringify(
        {
          state: 'awaiting-hello',
          session: this.session,
          token: this.token,
          transport: 'file',
          pipe: this.pipeName,
          updatedAt: new Date().toISOString(),
        },
        null,
        2,
      ) + '\n',
    );

    this.#poller = setInterval(() => this.pollOutbox(), DEFAULT_POLL_INTERVAL_MS);
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
      OMEGGA_UE4SS_TRACE: this.tracePath,
    };
  }

  stop() {
    if (this.#poller) {
      clearInterval(this.#poller);
      this.#poller = null;
    }

    for (const [id, pending] of this.#pending) {
      if (pending.timeout) clearTimeout(pending.timeout);
      pending.reject(new Error(`UE4SS bridge stopped while waiting for ${pending.method}`));
      this.#pending.delete(id);
    }

    this.#stopped = true;
    this.emit('stopped');
  }

  isReady() {
    return this.#readyInfo !== null;
  }

  getReadyInfo() {
    return this.#readyInfo;
  }

  waitUntilReady(timeoutMs = DEFAULT_READY_TIMEOUT_MS) {
    if (this.#readyInfo) return Promise.resolve(this.#readyInfo);
    if (this.#stopped) return Promise.reject(new Error('UE4SS bridge is stopped.'));

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

  async ping(timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS) {
    await this.waitUntilReady(timeoutMs);
    const nonce = randomBytes(8).toString('hex');
    return this.request('bridge.ping', { nonce }, timeoutMs);
  }

  async execCommand(command: string, timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS) {
    await this.waitUntilReady(timeoutMs);
    const normalizedCommand = command.replace(/\r?\n$/, '');
    const commandB64 = Buffer.from(normalizedCommand, 'utf8').toString('base64');
    return this.request(
      'console.exec',
      {
        command_b64: commandB64,
        issued_at: new Date().toISOString(),
      },
      timeoutMs,
    );
  }

  async execCommandWithOutput(
    command: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  ) {
    await this.waitUntilReady(timeoutMs);
    const normalizedCommand = command.replace(/\r?\n$/, '');
    const commandB64 = Buffer.from(normalizedCommand, 'utf8').toString('base64');
    return this.request(
      'console.exec',
      {
        command_b64: commandB64,
        issued_at: new Date().toISOString(),
      },
      timeoutMs,
      { consoleOutput: true },
    );
  }

  async broadcast(message: string, timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'chat.broadcast',
      {
        message_b64: Buffer.from(message, 'utf8').toString('base64'),
      },
      timeoutMs,
    );
  }

  async whisper(
    target: string,
    message: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'chat.whisper',
      {
        target_b64: Buffer.from(target, 'utf8').toString('base64'),
        message_b64: Buffer.from(message, 'utf8').toString('base64'),
      },
      timeoutMs,
    );
  }

  async statusMessage(
    target: string,
    message: string,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
  ) {
    await this.waitUntilReady(timeoutMs);
    return this.request(
      'chat.status_message',
      {
        target_b64: Buffer.from(target, 'utf8').toString('base64'),
        message_b64: Buffer.from(message, 'utf8').toString('base64'),
      },
      timeoutMs,
    );
  }

  async requestServerStatus(timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS) {
    await this.waitUntilReady(timeoutMs);
    return this.request('server.status', {}, timeoutMs);
  }

  async requestPlayers(
    format: 'records' | 'usernames' | 'owners' = 'records',
    options: { stateName?: string } = {},
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
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
    options: { consoleOutput?: boolean } = {},
  ) {
    if (this.#stopped) {
      return Promise.reject(new Error('UE4SS bridge is stopped.'));
    }

    const id = this.#nextRequestId++;
    const message: JsonRpcMessage = {
      jsonrpc: '2.0',
      id,
      method,
      params,
    };

    return new Promise((resolve, reject) => {
      const timeout =
        timeoutMs > 0
          ? setTimeout(() => {
              this.#pending.delete(id);
              reject(new Error(`Timed out waiting for UE4SS response to ${method}.`));
            }, timeoutMs)
          : null;

      this.#pending.set(id, {
        method,
        resolve,
        reject,
        timeout,
        consoleOutput: options.consoleOutput === true,
        chunks: options.consoleOutput === true ? [] : undefined,
      });

      this.appendInboxMessage(message);
    });
  }

  private appendInboxMessage(message: JsonRpcMessage) {
    fs.appendFileSync(this.inboxPath, JSON.stringify(message) + '\n');
  }

  private pollOutbox() {
    if (!fs.existsSync(this.outboxPath)) return;

    const buffer = fs.readFileSync(this.outboxPath);
    if (buffer.length <= this.#outboxOffset) return;

    const nextChunk = buffer.subarray(this.#outboxOffset).toString('utf8');
    this.#outboxOffset = buffer.length;
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
        pending.reject(
          new Error(
            `${pending.method} failed: ${message.error.message}${
              message.error.data ? ` (${JSON.stringify(message.error.data)})` : ''
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
      this.statusPath,
      JSON.stringify(
        {
          state,
          session: this.session,
          token: this.token,
          updatedAt: new Date().toISOString(),
          ...extra,
        },
        null,
        2,
      ) + '\n',
    );
  }
}
