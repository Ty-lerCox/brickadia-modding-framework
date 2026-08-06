import { randomBytes, randomInt } from 'node:crypto';
import EventEmitter from 'node:events';
import { createServer, Server, Socket } from 'node:net';

type ClientRole = 'bmf-native' | 'plugin' | 'unknown';

type ClientState = {
  authenticated: boolean;
  role: ClientRole;
  buffer: string;
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
const RETRYABLE_BIND_ERROR_CODES = new Set(['EADDRINUSE', 'EACCES']);

export default class BmfSocketBridgeHost extends EventEmitter {
  readonly token = randomBytes(16).toString('hex');
  readonly host: string;
  port: number;
  readonly boundedAdmissionEnabled: boolean;
  readonly maxPendingCommands: number;
  readonly maxClientBufferBytes: number;

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

    for (const socket of this.#clients.keys()) {
      socket.removeAllListeners();
      socket.destroy();
    }
    this.#clients.clear();
    this.#bmfClients.clear();

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
    });

    socket.on('data', chunk => this.handleData(socket, chunk));
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
      this.broadcast(
        trimmed,
        socket,
        socket => this.#clients.get(socket)?.role !== 'bmf-native',
      );
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
    this.#clients.delete(socket);
    this.#bmfClients.delete(socket);
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
