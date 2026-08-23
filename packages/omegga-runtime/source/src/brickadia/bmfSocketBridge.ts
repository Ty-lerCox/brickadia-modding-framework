import { randomBytes, randomInt } from 'node:crypto';
import EventEmitter from 'node:events';
import { createServer, Server, Socket } from 'node:net';
import MotionLatestValueLane from './motionLatestValueLane';

type ClientRole = 'bmf-native' | 'plugin' | 'companion' | 'unknown';

type MotionSchemaState = {
  event: typeof MOTION_EVENT_NAME;
  schemaVersion: number;
  generation: string;
};

type MotionEventRecord = {
  type: 'event';
  event: typeof MOTION_EVENT_NAME;
  payload: Record<string, unknown>;
};

type ClientState = {
  authenticated: boolean;
  role: ClientRole;
  buffer: string;
  motionLeaseExpiresAtMs: number;
  motionPlayerId: string;
  motionRateHz: number;
  motionLastForwardedAtMs: number;
  motionRateTimer: NodeJS.Timeout | null;
  motionLane: MotionLatestValueLane;
};

type BridgeMessage = {
  type?: string;
  id?: string;
  token?: string;
  role?: string;
  command?: string;
  ok?: boolean;
  detail?: string;
  response?: string;
  deadlineMs?: number;
  senderUuid?: string;
  connectionGeneration?: number;
  operationRequestId?: string;
  offThreadMs?: number;
  source?: string;
  event?: string;
  schemaVersion?: number;
  available?: boolean;
  generation?: string;
  leaseMs?: number;
  playerId?: string;
  rateHz?: number;
  capability?: string;
  record?: unknown;
};

export type BmfCommandServiceClass = 'interactive' | 'bulk';

export type BmfCommandOptions = {
  serviceClass?: BmfCommandServiceClass;
  issuedAtMs?: number;
  deadlineMs?: number;
  senderUuid?: string;
  connectionGeneration?: number;
  operationRequestId?: string;
  offThreadMs?: number;
};

export type BmfSocketBridgeOptions = {
  host?: string;
  port?: number;
  boundedAdmissionEnabled?: boolean;
  maxPendingCommands?: number;
  maxClientBufferBytes?: number;
  maxMotionPayloadBytes?: number;
};

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT_MIN = 26000;
const DEFAULT_PORT_MAX = 61000;
const DEFAULT_COMMAND_TIMEOUT_MS = 3000;
const MIN_COMMAND_TIMEOUT_MS = 100;
const DEFAULT_TUNNEL_ROUTE_TIMEOUT_MS = 15000;
const MAX_TUNNEL_ROUTE_TIMEOUT_MS = 300000;
const MAX_PENDING_TUNNEL_ROUTES = 512;
const DEFAULT_MAX_PENDING_COMMANDS = 64;
const DEFAULT_MAX_CLIENT_BUFFER_BYTES = 256 * 1024;
const DEFAULT_MAX_MOTION_PAYLOAD_BYTES = 16 * 1024;
const MOTION_CAPABILITY = 'player-motion-v1' as const;
const MOTION_EVENT_NAME = 'players.motion.v1' as const;
const MOTION_SCHEMA_VERSION = 1;
const MOTION_SCHEMA_MESSAGE = 'motion.schema';
const MOTION_SUBSCRIBE_MESSAGE = 'motion.subscribe';
const MOTION_UNSUBSCRIBE_MESSAGE = 'motion.unsubscribe';
const DEFAULT_MOTION_LEASE_MS = 5_000;
const MIN_MOTION_LEASE_MS = 1_000;
const MAX_MOTION_LEASE_MS = 15_000;
const DEFAULT_MOTION_RATE_HZ = 10;
const MIN_MOTION_RATE_HZ = 1;
const MAX_MOTION_RATE_HZ = 20;
const MAX_MOTION_COORDINATE_ABS = 10_000_000;
const MAX_MOTION_SAMPLE_AGE_MS = 30_000;
const MAX_MOTION_SAMPLE_FUTURE_MS = 5_000;
const PLAYER_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MOTION_HEADING_SOURCES = new Set([
  'view',
  'body',
  'vehicle',
  'velocity',
  'travel',
  'none',
]);
const RETRYABLE_BIND_ERROR_CODES = new Set(['EADDRINUSE', 'EACCES']);

export default class BmfSocketBridgeHost extends EventEmitter {
  readonly token = randomBytes(16).toString('hex');
  readonly host: string;
  port: number;
  readonly boundedAdmissionEnabled: boolean;
  readonly maxPendingCommands: number;
  readonly maxClientBufferBytes: number;
  readonly maxMotionPayloadBytes: number;

  #server: Server = null;
  #configuredPort: number;
  #clients = new Map<Socket, ClientState>();
  #bmfClients = new Set<Socket>();
  #pendingCommands = new Map<
    string,
    {
      resolve: (message: BridgeMessage) => void;
      reject: (error: Error) => void;
      timeout: NodeJS.Timeout;
      native: Socket | null;
    }
  >();
  #pendingTunnelRoutes = new Map<
    string,
    {
      origin: Socket;
      native: Socket;
      timeout: NodeJS.Timeout;
    }
  >();
  #commandCounter = 0;
  #stopped = true;
  #motionSchema: MotionSchemaState | null = null;
  #motionSchemaSource: Socket | null = null;
  #motionMetrics = {
    schemaAdvertisements: 0,
    subscriptionsAccepted: 0,
    subscriptionsRejected: 0,
    forwarded: 0,
    coalesced: 0,
    expiredLeases: 0,
    droppedOversize: 0,
    droppedInvalid: 0,
    droppedUnavailable: 0,
  };

  constructor(options: BmfSocketBridgeOptions = {}) {
    super();
    this.host =
      options.host || process.env.OMEGGA_BMF_SOCKET_HOST || DEFAULT_HOST;
    this.#configuredPort =
      options.port || Number(process.env.OMEGGA_BMF_SOCKET_PORT || 0) || 0;
    this.port =
      this.#configuredPort || randomInt(DEFAULT_PORT_MIN, DEFAULT_PORT_MAX);
    this.boundedAdmissionEnabled =
      options.boundedAdmissionEnabled ??
      process.env.OMEGGA_BMF_SOCKET_BOUNDED_ADMISSION_ENABLED !== '0';
    this.maxPendingCommands = Math.max(
      1,
      Math.floor(
        Number(
          options.maxPendingCommands ??
            process.env.OMEGGA_BMF_SOCKET_MAX_PENDING_COMMANDS ??
            DEFAULT_MAX_PENDING_COMMANDS,
        ),
      ) || DEFAULT_MAX_PENDING_COMMANDS,
    );
    this.maxClientBufferBytes = Math.max(
      1,
      Math.floor(
        Number(
          options.maxClientBufferBytes ??
            process.env.OMEGGA_BMF_SOCKET_MAX_CLIENT_BUFFER_BYTES ??
            DEFAULT_MAX_CLIENT_BUFFER_BYTES,
        ),
      ) || DEFAULT_MAX_CLIENT_BUFFER_BYTES,
    );
    this.maxMotionPayloadBytes = Math.max(
      1,
      Math.floor(
        Number(
          options.maxMotionPayloadBytes ??
            process.env.OMEGGA_BMF_SOCKET_MAX_MOTION_PAYLOAD_BYTES ??
            DEFAULT_MAX_MOTION_PAYLOAD_BYTES,
        ),
      ) || DEFAULT_MAX_MOTION_PAYLOAD_BYTES,
    );
  }

  async start() {
    this.stop();
    this.#stopped = false;

    const maxAttempts = this.#configuredPort ? 1 : 20;
    let lastError: Error | null = null;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const port =
        this.#configuredPort || randomInt(DEFAULT_PORT_MIN, DEFAULT_PORT_MAX);
      this.port = port;
      this.#server = createServer(socket => this.handleConnection(socket));

      try {
        await new Promise<void>((resolve, reject) => {
          const handleError = (error: Error) => {
            this.#server?.off('listening', handleListening);
            reject(error);
          };
          const handleListening = () => {
            this.#server?.off('error', handleError);
            resolve();
          };
          this.#server.once('error', handleError);
          this.#server.once('listening', handleListening);
          this.#server.listen(port, this.host);
        });
      } catch (error) {
        lastError = error instanceof Error ? error : new Error(String(error));
        this.#server.removeAllListeners();
        try {
          this.#server.close();
        } catch {
          // The listener may not be fully running when bind fails.
        }
        this.#server = null;
        const errorCode = (lastError as NodeJS.ErrnoException).code;
        if (
          !this.#configuredPort &&
          RETRYABLE_BIND_ERROR_CODES.has(errorCode)
        ) {
          this.emit('log', {
            level: 'warn',
            message:
              `BMF socket bridge port ${this.host}:${port} failed with ${errorCode}; ` +
              `retrying (${attempt}/${maxAttempts}).`,
          });
          continue;
        }
        this.emit('log', {
          level: 'error',
          message: `BMF socket bridge failed: ${lastError.message}`,
        });
        this.#stopped = true;
        throw lastError;
      }

      this.#server.on('error', error => {
        this.emit('log', {
          level: 'error',
          message: `BMF socket bridge failed: ${
            error instanceof Error ? error.message : String(error)
          }`,
        });
      });
      this.#server.on('close', () => {
        if (!this.#stopped) {
          this.emit('log', {
            level: 'warn',
            message: 'BMF socket bridge listener closed unexpectedly.',
          });
        }
      });
      this.emit('ready', {
        host: this.host,
        port: this.port,
        transport: 'socket',
      });

      return {
        OMEGGA_BMF_SOCKET_ENABLED: '1',
        OMEGGA_BMF_SOCKET_HOST: this.host,
        OMEGGA_BMF_SOCKET_PORT: String(this.port),
        OMEGGA_BMF_SOCKET_TOKEN: this.token,
        OMEGGA_BMF_SOCKET_POLL_MS:
          process.env.OMEGGA_BMF_SOCKET_POLL_MS || '25',
      };
    }

    this.#stopped = true;
    throw lastError || new Error('BMF socket bridge failed to bind a port.');
  }

  stop() {
    for (const [id, pending] of this.#pendingCommands) {
      clearTimeout(pending.timeout);
      pending.reject(
        new Error(`BMF socket bridge stopped before command ${id} completed.`),
      );
    }
    this.#pendingCommands.clear();
    for (const route of this.#pendingTunnelRoutes.values()) {
      clearTimeout(route.timeout);
    }
    this.#pendingTunnelRoutes.clear();

    for (const [socket, client] of this.#clients) {
      if (client.role === 'companion') {
        this.clearCompanionMotionClient(client);
      }
      socket.removeAllListeners();
      socket.destroy();
    }
    this.#clients.clear();
    this.#bmfClients.clear();
    this.#motionSchema = null;
    this.#motionSchemaSource = null;

    if (this.#server) {
      this.#server.removeAllListeners();
      this.#server.close();
      this.#server = null;
    }
    this.#stopped = true;
    this.emit('stopped');
  }

  get hasBmfClients() {
    return this.#bmfClients.size > 0;
  }

  get motionStatus() {
    const nowMs = Date.now();
    let companionClients = 0;
    let activeLeases = 0;
    for (const client of this.#clients.values()) {
      if (client.role !== 'companion') continue;
      companionClients += 1;
      if (client.motionLeaseExpiresAtMs > nowMs) activeLeases += 1;
    }
    return {
      available: this.#motionSchema !== null,
      event: MOTION_EVENT_NAME,
      schemaVersion: this.#motionSchema?.schemaVersion ?? null,
      generation: this.#motionSchema?.generation ?? '',
      companionClients,
      activeLeases,
      ...this.#motionMetrics,
    };
  }

  execCommand(
    command: string,
    timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
    options: BmfCommandOptions = {},
  ) {
    const commandLabel = command.trim().split(/\s+/, 1)[0] || '<empty>';
    if (this.#stopped || !this.#server) {
      return Promise.reject(new Error('BMF socket bridge is not running.'));
    }
    if (this.#bmfClients.size === 0) {
      return Promise.reject(
        new Error('No BMF native socket clients are connected.'),
      );
    }
    if (
      this.boundedAdmissionEnabled &&
      this.#pendingCommands.size >= this.maxPendingCommands
    ) {
      return Promise.reject(
        new Error(
          `BMF socket command admission rejected: pending limit ${this.maxPendingCommands} reached.`,
        ),
      );
    }

    const requestedTimeoutMs = Number(timeoutMs);
    const effectiveTimeoutMs = Number.isFinite(requestedTimeoutMs)
      ? Math.max(MIN_COMMAND_TIMEOUT_MS, Math.ceil(requestedTimeoutMs))
      : DEFAULT_COMMAND_TIMEOUT_MS;
    const nowMs = Date.now();
    const requestedIssuedAtMs = Number(options.issuedAtMs);
    const issuedAtMs =
      Number.isFinite(requestedIssuedAtMs) && requestedIssuedAtMs > 0
        ? requestedIssuedAtMs
        : nowMs;
    const requestedDeadlineMs = Number(options.deadlineMs);
    const deadlineMs =
      Number.isFinite(requestedDeadlineMs) && requestedDeadlineMs > 0
        ? requestedDeadlineMs
        : issuedAtMs + effectiveTimeoutMs;
    if (deadlineMs <= nowMs) {
      return Promise.reject(
        new Error(
          `BMF socket command expired before dispatch: ${commandLabel}.`,
        ),
      );
    }
    const responseTimeoutMs = Math.max(
      1,
      Math.min(effectiveTimeoutMs, deadlineMs - nowMs),
    );
    const serviceClass: BmfCommandServiceClass =
      options.serviceClass === 'bulk' ? 'bulk' : 'interactive';
    const id = [
      'omegga',
      issuedAtMs,
      ++this.#commandCounter,
      randomBytes(4).toString('hex'),
    ].join('-');
    const payload = `${JSON.stringify({
      type: 'command',
      id,
      source: 'omegga-core',
      command,
      issuedAtMs,
      deadlineMs,
      serviceClass,
      ...(options.senderUuid
        ? { senderUuid: String(options.senderUuid).slice(0, 128) }
        : {}),
      ...(Number.isSafeInteger(options.connectionGeneration) &&
      Number(options.connectionGeneration) > 0
        ? { connectionGeneration: Number(options.connectionGeneration) }
        : {}),
      ...(options.operationRequestId
        ? {
            operationRequestId: String(options.operationRequestId).slice(
              0,
              128,
            ),
          }
        : {}),
      ...(Number.isFinite(options.offThreadMs) &&
      Number(options.offThreadMs) >= 0
        ? { offThreadMs: Number(options.offThreadMs) }
        : {}),
    })}\n`;

    return new Promise<BridgeMessage>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#pendingCommands.delete(id);
        reject(
          new Error(
            `Timed out waiting for BMF socket response to ${commandLabel}.`,
          ),
        );
      }, responseTimeoutMs);

      const pending = {
        resolve,
        reject,
        timeout,
        native: null as Socket | null,
      };
      this.#pendingCommands.set(id, pending);

      let sent = false;
      for (const socket of this.#bmfClients) {
        if (socket.destroyed || !socket.writable) continue;
        socket.write(payload);
        pending.native = socket;
        sent = true;
        break;
      }

      if (!sent) {
        this.#pendingCommands.delete(id);
        clearTimeout(timeout);
        reject(
          new Error('No writable BMF native socket clients are connected.'),
        );
      }
    });
  }

  private handleConnection(socket: Socket) {
    socket.setNoDelay(true);
    this.#clients.set(socket, {
      authenticated: false,
      role: 'unknown',
      buffer: '',
      motionLeaseExpiresAtMs: 0,
      motionPlayerId: '',
      motionRateHz: 0,
      motionLastForwardedAtMs: 0,
      motionRateTimer: null,
      motionLane: new MotionLatestValueLane(),
    });

    socket.on('data', chunk => this.handleData(socket, chunk));
    socket.on('drain', () => this.flushMotionLane(socket));
    socket.on('close', () => this.removeClient(socket));
    socket.on('error', error => {
      this.emit('log', {
        level: 'warn',
        message: `BMF socket client error: ${
          error instanceof Error ? error.message : String(error)
        }`,
      });
      this.removeClient(socket);
    });
  }

  private handleData(socket: Socket, chunk: Buffer) {
    const client = this.#clients.get(socket);
    if (!client) return;

    if (
      this.boundedAdmissionEnabled &&
      Buffer.byteLength(client.buffer, 'utf8') + chunk.byteLength >
        this.maxClientBufferBytes
    ) {
      socket.destroy(
        new Error('BMF socket client exceeded input buffer limit.'),
      );
      return;
    }
    client.buffer += chunk.toString('utf8');

    const lines = client.buffer.split(/\r?\n/);
    client.buffer = lines.pop() ?? '';
    for (const line of lines) {
      this.handleLine(socket, client, line);
    }
  }

  private writeJson(socket: Socket, message: Record<string, unknown>) {
    if (socket.destroyed || !socket.writable) return false;
    socket.write(`${JSON.stringify(message)}\n`);
    return true;
  }

  private publicMotionSchema() {
    return {
      available: this.#motionSchema !== null,
      capability: MOTION_CAPABILITY,
      capabilities: this.#motionSchema ? [MOTION_CAPABILITY] : [],
      event: MOTION_EVENT_NAME,
      schemaVersion: this.#motionSchema?.schemaVersion ?? null,
      generation: this.#motionSchema?.generation ?? '',
      minLeaseMs: MIN_MOTION_LEASE_MS,
      maxLeaseMs: MAX_MOTION_LEASE_MS,
      minRateHz: MIN_MOTION_RATE_HZ,
      maxRateHz: MAX_MOTION_RATE_HZ,
    };
  }

  private publishMotionSchema() {
    const message = {
      type: MOTION_SCHEMA_MESSAGE,
      source: 'omegga-broker',
      ...this.publicMotionSchema(),
    };
    for (const [socket, client] of this.#clients) {
      if (!client.authenticated || client.role !== 'companion') continue;
      this.writeJson(socket, message);
    }
  }

  private clearCompanionMotionClient(
    client: ClientState,
    countPendingAsUnavailable = false,
  ) {
    if (client.motionRateTimer) {
      clearTimeout(client.motionRateTimer);
      client.motionRateTimer = null;
    }
    client.motionLeaseExpiresAtMs = 0;
    client.motionPlayerId = '';
    client.motionRateHz = 0;
    client.motionLastForwardedAtMs = 0;
    if (client.motionLane.clear() && countPendingAsUnavailable) {
      this.#motionMetrics.droppedUnavailable += 1;
    }
  }

  private clearCompanionMotionState() {
    for (const client of this.#clients.values()) {
      if (client.role !== 'companion') continue;
      this.clearCompanionMotionClient(client, true);
    }
  }

  private setMotionSchemaUnavailable() {
    if (!this.#motionSchema && !this.#motionSchemaSource) return;
    this.#motionSchema = null;
    this.#motionSchemaSource = null;
    this.clearCompanionMotionState();
    this.publishMotionSchema();
  }

  private handleMotionSchemaAdvertisement(
    socket: Socket,
    message: BridgeMessage,
  ) {
    if (message.available !== true) {
      if (
        message.capability === MOTION_CAPABILITY &&
        message.event === MOTION_EVENT_NAME &&
        this.#motionSchemaSource === socket
      ) {
        this.setMotionSchemaUnavailable();
      }
      return;
    }

    const schemaVersion = message.schemaVersion;
    const generation =
      typeof message.generation === 'string' ? message.generation.trim() : '';
    const valid =
      message.capability === MOTION_CAPABILITY &&
      message.event === MOTION_EVENT_NAME &&
      schemaVersion === MOTION_SCHEMA_VERSION &&
      /^[A-Za-z0-9._:-]{1,80}$/.test(generation);
    if (!valid) {
      this.emit('log', {
        level: 'warn',
        message: 'BMF socket ignored invalid motion schema metadata.',
      });
      return;
    }

    if (this.#motionSchemaSource && this.#motionSchemaSource !== socket) {
      this.emit('log', {
        level: 'warn',
        message:
          'BMF socket ignored motion schema metadata from a second native source.',
      });
      return;
    }

    const changed =
      !this.#motionSchema ||
      this.#motionSchema.schemaVersion !== schemaVersion ||
      this.#motionSchema.generation !== generation ||
      this.#motionSchemaSource !== socket;
    this.#motionSchema = {
      event: MOTION_EVENT_NAME,
      schemaVersion,
      generation,
    };
    this.#motionSchemaSource = socket;
    this.#motionMetrics.schemaAdvertisements += 1;
    if (changed) this.clearCompanionMotionState();
    this.publishMotionSchema();
  }

  private handleCompanionMessage(
    socket: Socket,
    client: ClientState,
    message: BridgeMessage,
  ) {
    if (message.type === 'ping') {
      this.writeJson(socket, {
        type: 'pong',
        id: message.id,
        source: 'omegga-broker',
      });
      return;
    }

    if (message.type === MOTION_UNSUBSCRIBE_MESSAGE) {
      const playerId = client.motionPlayerId;
      this.clearCompanionMotionClient(client);
      this.writeJson(socket, {
        type: 'motion.subscribe.ack',
        accepted: true,
        playerId,
        rateHz: 0,
        leaseMs: 0,
        expiresAtMs: 0,
      });
      return;
    }

    if (message.type !== MOTION_SUBSCRIBE_MESSAGE) {
      this.writeJson(socket, {
        type: 'error',
        ok: false,
        code: 'ROLE_NOT_AUTHORIZED',
        detail: 'companion role only supports motion leases and broker ping',
      });
      return;
    }

    const playerId = String(message.playerId || '')
      .trim()
      .toLowerCase();
    if (
      !this.#motionSchema ||
      message.schemaVersion !== this.#motionSchema.schemaVersion
    ) {
      this.#motionMetrics.subscriptionsRejected += 1;
      this.clearCompanionMotionClient(client, true);
      this.writeJson(socket, {
        type: 'motion.subscribe.ack',
        accepted: false,
        playerId,
        code: 'SCHEMA_UNAVAILABLE',
        leaseMs: 0,
        expiresAtMs: 0,
      });
      return;
    }

    if (!PLAYER_ID_PATTERN.test(playerId)) {
      this.#motionMetrics.subscriptionsRejected += 1;
      this.clearCompanionMotionClient(client, true);
      this.writeJson(socket, {
        type: 'motion.subscribe.ack',
        accepted: false,
        playerId,
        code: 'INVALID_SUBSCRIPTION',
        leaseMs: 0,
        expiresAtMs: 0,
      });
      return;
    }

    const requestedLeaseMs = Number(message.leaseMs);
    const leaseMs = Math.max(
      MIN_MOTION_LEASE_MS,
      Math.min(
        MAX_MOTION_LEASE_MS,
        Number.isFinite(requestedLeaseMs)
          ? Math.floor(requestedLeaseMs)
          : DEFAULT_MOTION_LEASE_MS,
      ),
    );
    const requestedRateHz = Number(message.rateHz);
    const rateHz = Math.max(
      MIN_MOTION_RATE_HZ,
      Math.min(
        MAX_MOTION_RATE_HZ,
        Number.isFinite(requestedRateHz)
          ? Math.floor(requestedRateHz)
          : DEFAULT_MOTION_RATE_HZ,
      ),
    );
    if (client.motionPlayerId && client.motionPlayerId !== playerId) {
      this.clearCompanionMotionClient(client);
    }
    client.motionPlayerId = playerId;
    client.motionRateHz = rateHz;
    client.motionLeaseExpiresAtMs = Date.now() + leaseMs;
    this.#motionMetrics.subscriptionsAccepted += 1;
    this.writeJson(socket, {
      type: 'motion.subscribe.ack',
      accepted: true,
      playerId,
      rateHz,
      schemaVersion: this.#motionSchema.schemaVersion,
      generation: this.#motionSchema.generation,
      leaseMs,
      expiresAtMs: client.motionLeaseExpiresAtMs,
    });
  }

  private motionEventRecord(message: BridgeMessage): MotionEventRecord | null {
    if (message.type !== 'event' || !message.record) return null;
    if (message.source !== 'bmf') return null;
    if (typeof message.record !== 'object') return null;
    const record = message.record as {
      type?: unknown;
      event?: unknown;
      payload?: unknown;
    };
    if (
      record.type !== 'event' ||
      record.event !== MOTION_EVENT_NAME ||
      !record.payload ||
      typeof record.payload !== 'object' ||
      Array.isArray(record.payload)
    )
      return null;
    return record as MotionEventRecord;
  }

  private motionEventMatchesActiveSchema(message: BridgeMessage) {
    const record = this.motionEventRecord(message);
    if (!record || !this.#motionSchema) return false;
    const payload = record.payload;
    const schemaVersion = payload.schemaVersion;
    const playerId = String(payload.playerId || '')
      .trim()
      .toLowerCase();
    const sequence = payload.sequence;
    const sampledAtMs = payload.sampledAtMs;
    const x = payload.x;
    const y = payload.y;
    const z = payload.z;
    const headingDegrees = payload.headingDegrees;
    const speedMetersPerSecond = payload.speedMetersPerSecond;
    const nowMs = Date.now();
    const validHeading =
      headingDegrees === null ||
      (typeof headingDegrees === 'number' &&
        Number.isFinite(headingDegrees) &&
        headingDegrees >= 0 &&
        headingDegrees < 360);
    const headingSource = String(payload.headingSource);
    const validHeadingSource = MOTION_HEADING_SOURCES.has(headingSource);
    const headingMatchesSource =
      (headingSource === 'none' && headingDegrees === null) ||
      (headingSource !== 'none' && headingDegrees !== null);
    const matches =
      typeof schemaVersion === 'number' &&
      schemaVersion === this.#motionSchema.schemaVersion &&
      payload.generation === this.#motionSchema.generation &&
      PLAYER_ID_PATTERN.test(playerId) &&
      typeof sequence === 'number' &&
      Number.isSafeInteger(sequence) &&
      sequence >= 0 &&
      typeof sampledAtMs === 'number' &&
      Number.isSafeInteger(sampledAtMs) &&
      sampledAtMs >= nowMs - MAX_MOTION_SAMPLE_AGE_MS &&
      sampledAtMs <= nowMs + MAX_MOTION_SAMPLE_FUTURE_MS &&
      typeof x === 'number' &&
      Number.isFinite(x) &&
      Math.abs(x) <= MAX_MOTION_COORDINATE_ABS &&
      typeof y === 'number' &&
      Number.isFinite(y) &&
      Math.abs(y) <= MAX_MOTION_COORDINATE_ABS &&
      typeof z === 'number' &&
      Number.isFinite(z) &&
      Math.abs(z) <= MAX_MOTION_COORDINATE_ABS &&
      validHeading &&
      validHeadingSource &&
      headingMatchesSource &&
      typeof speedMetersPerSecond === 'number' &&
      Number.isFinite(speedMetersPerSecond) &&
      speedMetersPerSecond >= 0 &&
      speedMetersPerSecond <= 500 &&
      typeof payload.vehicleActive === 'boolean';
    return matches ? { record, playerId } : false;
  }

  private hasActiveMotionLease(client: ClientState, nowMs: number) {
    if (client.motionLeaseExpiresAtMs <= 0) return false;
    if (client.motionLeaseExpiresAtMs > nowMs) return true;
    this.clearCompanionMotionClient(client, true);
    this.#motionMetrics.expiredLeases += 1;
    return false;
  }

  private motionIntervalMs(client: ClientState) {
    return 1_000 / Math.max(MIN_MOTION_RATE_HZ, client.motionRateHz);
  }

  private scheduleMotionLaneFlush(socket: Socket, delayMs: number) {
    const client = this.#clients.get(socket);
    if (!client || client.motionRateTimer) return;
    client.motionRateTimer = setTimeout(
      () => {
        client.motionRateTimer = null;
        this.flushMotionLane(socket);
      },
      Math.max(1, Math.ceil(delayMs)),
    );
    client.motionRateTimer.unref?.();
  }

  private offerMotionPayload(
    socket: Socket,
    client: ClientState,
    payload: string,
  ) {
    const nowMs = Date.now();
    const rateDelayMs = Math.max(
      0,
      client.motionLastForwardedAtMs + this.motionIntervalMs(client) - nowMs,
    );
    const result = client.motionLane.offer(
      payload,
      socket.writableNeedDrain || rateDelayMs > 0,
      value => socket.write(value),
    );
    if (result.sent) {
      client.motionLastForwardedAtMs = nowMs;
      this.#motionMetrics.forwarded += 1;
    } else if (rateDelayMs > 0) {
      this.scheduleMotionLaneFlush(socket, rateDelayMs);
    }
    if (result.coalesced) this.#motionMetrics.coalesced += 1;
  }

  private sendMotionEvent(line: string, playerId: string) {
    const payload = `${line}\n`;
    if (Buffer.byteLength(payload, 'utf8') > this.maxMotionPayloadBytes) {
      this.#motionMetrics.droppedOversize += 1;
      return;
    }
    const nowMs = Date.now();
    for (const [socket, client] of this.#clients) {
      if (
        !client.authenticated ||
        client.role !== 'companion' ||
        client.motionPlayerId !== playerId ||
        socket.destroyed ||
        !socket.writable ||
        !this.hasActiveMotionLease(client, nowMs)
      )
        continue;
      this.offerMotionPayload(socket, client, payload);
    }
  }

  private flushMotionLane(socket: Socket) {
    const client = this.#clients.get(socket);
    if (!client) return;
    if (
      client.role !== 'companion' ||
      !this.#motionSchema ||
      !client.motionPlayerId ||
      !this.hasActiveMotionLease(client, Date.now())
    ) {
      if (client.motionLane.clear())
        this.#motionMetrics.droppedUnavailable += 1;
      return;
    }
    if (socket.destroyed || !socket.writable) {
      this.clearCompanionMotionClient(client, true);
      return;
    }
    if (socket.writableNeedDrain) return;
    const nowMs = Date.now();
    const rateDelayMs = Math.max(
      0,
      client.motionLastForwardedAtMs + this.motionIntervalMs(client) - nowMs,
    );
    if (rateDelayMs > 0) {
      this.scheduleMotionLaneFlush(socket, rateDelayMs);
      return;
    }
    const result = client.motionLane.drain(value => socket.write(value));
    if (result.sent) {
      client.motionLastForwardedAtMs = nowMs;
      this.#motionMetrics.forwarded += 1;
    }
  }

  private handleLine(socket: Socket, client: ClientState, line: string) {
    const trimmed = line.trim();
    if (!trimmed) return;

    let message: BridgeMessage;
    try {
      message = JSON.parse(trimmed) as BridgeMessage;
    } catch {
      this.emit('log', {
        level: 'warn',
        message: 'BMF socket ignored invalid JSON.',
      });
      return;
    }

    if (!client.authenticated) {
      if (message.type !== 'hello' || message.token !== this.token) {
        socket.destroy(new Error('BMF socket authentication failed.'));
        return;
      }
      client.authenticated = true;
      client.role = this.normalizeRole(message.role);
      if (client.role === 'bmf-native') {
        this.#bmfClients.add(socket);
        if (this.#bmfClients.size > 1) {
          this.emit('log', {
            level: 'warn',
            message:
              `BMF socket has ${this.#bmfClients.size} native clients; ` +
              'commands will use the first writable native client.',
          });
        }
      } else if (client.role === 'companion') {
        this.writeJson(socket, {
          type: 'hello.ack',
          role: 'companion',
          source: 'omegga-broker',
          capabilities: this.#motionSchema ? [MOTION_CAPABILITY] : [],
          motion: this.publicMotionSchema(),
        });
      }
      this.emit('client', {
        role: client.role,
        bmfClients: this.#bmfClients.size,
        clients: this.#clients.size,
      });
      return;
    }

    if (client.role === 'bmf-native') {
      if (
        (message.type === 'tunnel.ack' || message.type === 'tunnel.result') &&
        message.id
      ) {
        this.routeTunnelResponse(socket, message, trimmed);
        return;
      }
      if (message.type === 'response' && message.id) {
        this.resolvePendingCommand(message);
      }
      if (message.type === MOTION_SCHEMA_MESSAGE) {
        this.handleMotionSchemaAdvertisement(socket, message);
      }
      this.broadcast(trimmed, socket, socket => {
        const role = this.#clients.get(socket)?.role;
        return role !== 'bmf-native' && role !== 'companion';
      });
      const motionRecord = this.motionEventRecord(message);
      if (motionRecord) {
        const match = this.motionEventMatchesActiveSchema(message);
        if (match) {
          this.sendMotionEvent(trimmed, match.playerId);
        } else if (this.#motionSchema) {
          this.#motionMetrics.droppedInvalid += 1;
        } else {
          this.#motionMetrics.droppedUnavailable += 1;
        }
      }
      return;
    }

    if (client.role === 'companion') {
      this.handleCompanionMessage(socket, client, message);
      return;
    }

    if (message.type === 'tunnel.request') {
      this.routeTunnelRequest(socket, message, trimmed);
      return;
    }

    if (message.type === 'command' || message.type === 'ping') {
      if (!this.sendToFirstBmfClient(trimmed)) {
        socket.write(
          `${JSON.stringify({
            type: 'response',
            id: message.type === 'command' ? message.id : undefined,
            ok: false,
            detail: 'no bmf-native clients connected',
          })}\n`,
        );
        return;
      }
    }
  }

  private resolvePendingCommand(message: BridgeMessage) {
    const id = String(message.id || '');
    const pending = this.#pendingCommands.get(id);
    if (!pending) return;

    this.#pendingCommands.delete(id);
    clearTimeout(pending.timeout);
    pending.resolve(message);
  }

  private normalizeRole(value: string | undefined): ClientRole {
    const role = String(value || '')
      .trim()
      .toLowerCase();
    if (role === 'bmf-native') return 'bmf-native';
    if (role === 'companion') return 'companion';
    if (role === 'cityrpg' || role === 'plugin') return 'plugin';
    return 'unknown';
  }

  private firstWritableBmfClient() {
    for (const socket of this.#bmfClients) {
      if (!socket.destroyed && socket.writable) return socket;
    }
    return null;
  }

  private sendToFirstBmfClient(line: string) {
    const socket = this.firstWritableBmfClient();
    if (!socket) return false;
    const payload = `${line}\n`;
    socket.write(payload);
    return true;
  }

  private writeTunnelResult(
    socket: Socket,
    id: string | undefined,
    state: 'rejected' | 'outcome_unknown',
    code: string,
    detail: string,
  ) {
    if (socket.destroyed || !socket.writable) return;
    socket.write(
      `${JSON.stringify({
        type: 'tunnel.result',
        source: 'omegga-broker',
        v: 1,
        id,
        state,
        code,
        detail,
        queueDepth: this.#pendingTunnelRoutes.size,
      })}\n`,
    );
  }

  private routeTunnelRequest(
    origin: Socket,
    message: BridgeMessage,
    line: string,
  ) {
    const id = String(message.id || '').trim();
    if (!id) {
      this.writeTunnelResult(
        origin,
        message.id,
        'rejected',
        'INVALID_ID',
        'tunnel request id is required',
      );
      return;
    }
    if (this.#pendingTunnelRoutes.has(id)) {
      this.writeTunnelResult(
        origin,
        id,
        'rejected',
        'DUPLICATE_ID_ACTIVE',
        'tunnel request id is already active at the broker',
      );
      return;
    }
    if (this.#pendingTunnelRoutes.size >= MAX_PENDING_TUNNEL_ROUTES) {
      this.writeTunnelResult(
        origin,
        id,
        'rejected',
        'BROKER_QUEUE_FULL',
        'bounded broker tunnel route table is full',
      );
      return;
    }

    const nowMs = Date.now();
    const absoluteDeadlineMs = Number(message.deadlineMs || 0);
    if (
      Number.isFinite(absoluteDeadlineMs) &&
      absoluteDeadlineMs > 0 &&
      absoluteDeadlineMs <= nowMs
    ) {
      this.writeTunnelResult(
        origin,
        id,
        'rejected',
        'DEADLINE_EXPIRED',
        'absolute tunnel deadline elapsed before broker forwarding',
      );
      return;
    }

    const native = this.firstWritableBmfClient();
    if (!native) {
      this.writeTunnelResult(
        origin,
        id,
        'rejected',
        'TUNNEL_UNAVAILABLE',
        'no bmf-native clients connected',
      );
      return;
    }

    const routeTimeoutMs =
      Number.isFinite(absoluteDeadlineMs) && absoluteDeadlineMs > nowMs
        ? Math.max(
            100,
            Math.min(
              MAX_TUNNEL_ROUTE_TIMEOUT_MS,
              absoluteDeadlineMs - nowMs + 1000,
            ),
          )
        : DEFAULT_TUNNEL_ROUTE_TIMEOUT_MS;
    const timeout = setTimeout(() => {
      const route = this.#pendingTunnelRoutes.get(id);
      if (!route || route.origin !== origin || route.native !== native) return;
      this.#pendingTunnelRoutes.delete(id);
      this.writeTunnelResult(
        origin,
        id,
        'outcome_unknown',
        'BROKER_ROUTE_TIMEOUT',
        'broker route expired after the request was forwarded to BMF',
      );
    }, routeTimeoutMs);
    timeout.unref?.();
    this.#pendingTunnelRoutes.set(id, { origin, native, timeout });
    native.write(`${line}\n`);
  }

  private routeTunnelResponse(
    native: Socket,
    message: BridgeMessage,
    line: string,
  ) {
    const id = String(message.id || '').trim();
    const route = this.#pendingTunnelRoutes.get(id);
    if (!route || route.native !== native) return;
    if (!route.origin.destroyed && route.origin.writable) {
      route.origin.write(`${line}\n`);
    }
    if (message.type === 'tunnel.result') {
      clearTimeout(route.timeout);
      this.#pendingTunnelRoutes.delete(id);
    }
  }

  private broadcast(
    line: string,
    sender: Socket,
    predicate: (socket: Socket) => boolean,
  ) {
    const payload = `${line}\n`;
    for (const socket of this.#clients.keys()) {
      if (socket === sender) continue;
      if (!predicate(socket)) continue;
      if (socket.destroyed || !socket.writable) continue;
      socket.write(payload);
    }
  }

  private removeClient(socket: Socket) {
    if (!this.#clients.has(socket)) return;
    const wasMotionSchemaSource = this.#motionSchemaSource === socket;
    const client = this.#clients.get(socket);
    if (client?.role === 'companion') {
      this.clearCompanionMotionClient(client);
    }
    this.#clients.delete(socket);
    this.#bmfClients.delete(socket);
    if (wasMotionSchemaSource) this.setMotionSchemaUnavailable();
    for (const [id, pending] of this.#pendingCommands) {
      if (pending.native !== socket) continue;
      clearTimeout(pending.timeout);
      this.#pendingCommands.delete(id);
      pending.reject(
        new Error(
          `BMF native socket disconnected before command ${id} completed.`,
        ),
      );
    }
    for (const [id, route] of this.#pendingTunnelRoutes) {
      if (route.origin !== socket && route.native !== socket) continue;
      clearTimeout(route.timeout);
      this.#pendingTunnelRoutes.delete(id);
      if (route.native === socket && route.origin !== socket) {
        this.writeTunnelResult(
          route.origin,
          id,
          'outcome_unknown',
          'BMF_NATIVE_DISCONNECTED',
          'selected BMF native client disconnected after request forwarding',
        );
      }
    }
    socket.removeAllListeners();
    if (!this.#stopped) {
      this.emit('client', {
        bmfClients: this.#bmfClients.size,
        clients: this.#clients.size,
      });
    }
  }
}
