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
};

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT_MIN = 26000;
const DEFAULT_PORT_MAX = 61000;
const DEFAULT_COMMAND_TIMEOUT_MS = 3000;
const RETRYABLE_BIND_ERROR_CODES = new Set(['EADDRINUSE', 'EACCES']);

export default class BmfSocketBridgeHost extends EventEmitter {
  readonly token = randomBytes(16).toString('hex');
  readonly host: string;
  port: number;

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
    }
  >();
  #commandCounter = 0;
  #stopped = true;

  constructor(options: { host?: string; port?: number } = {}) {
    super();
    this.host = options.host || process.env.OMEGGA_BMF_SOCKET_HOST || DEFAULT_HOST;
    this.#configuredPort =
      options.port ||
      Number(process.env.OMEGGA_BMF_SOCKET_PORT || 0) ||
      0;
    this.port = this.#configuredPort || randomInt(DEFAULT_PORT_MIN, DEFAULT_PORT_MAX);
  }

  async start() {
    this.stop();
    this.#stopped = false;

    const maxAttempts = this.#configuredPort ? 1 : 20;
    let lastError: Error | null = null;
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const port = this.#configuredPort || randomInt(DEFAULT_PORT_MIN, DEFAULT_PORT_MAX);
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
        if (!this.#configuredPort && RETRYABLE_BIND_ERROR_CODES.has(errorCode)) {
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
        OMEGGA_BMF_SOCKET_POLL_MS: process.env.OMEGGA_BMF_SOCKET_POLL_MS || '25',
      };
    }

    this.#stopped = true;
    throw lastError || new Error('BMF socket bridge failed to bind a port.');
  }

  stop() {
    for (const [id, pending] of this.#pendingCommands) {
      clearTimeout(pending.timeout);
      pending.reject(new Error(`BMF socket bridge stopped before command ${id} completed.`));
    }
    this.#pendingCommands.clear();

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

  execCommand(command: string, timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS) {
    if (this.#stopped || !this.#server) {
      return Promise.reject(new Error('BMF socket bridge is not running.'));
    }
    if (this.#bmfClients.size === 0) {
      return Promise.reject(new Error('No BMF native socket clients are connected.'));
    }

    const id = [
      'omegga',
      Date.now(),
      ++this.#commandCounter,
      randomBytes(4).toString('hex'),
    ].join('-');
    const payload = `${JSON.stringify({
      type: 'command',
      id,
      source: 'omegga-core',
      command,
    })}\n`;

    return new Promise<BridgeMessage>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#pendingCommands.delete(id);
        reject(new Error(`Timed out waiting for BMF socket response to ${command}.`));
      }, timeoutMs);

      this.#pendingCommands.set(id, { resolve, reject, timeout });

      let sent = false;
      for (const socket of this.#bmfClients) {
        if (socket.destroyed || !socket.writable) continue;
        socket.write(payload);
        sent = true;
        break;
      }

      if (!sent) {
        this.#pendingCommands.delete(id);
        clearTimeout(timeout);
        reject(new Error('No writable BMF native socket clients are connected.'));
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

    client.buffer += chunk.toString('utf8');
    if (client.buffer.length > 1024 * 1024) {
      socket.destroy(new Error('BMF socket client exceeded input buffer limit.'));
      return;
    }

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
      this.emit('log', { level: 'warn', message: 'BMF socket ignored invalid JSON.' });
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
      if (message.type === 'response' && message.id) {
        this.resolvePendingCommand(message);
      }
      this.broadcast(trimmed, socket, socket => this.#clients.get(socket)?.role !== 'bmf-native');
      return;
    }

    if (message.type === 'command' || message.type === 'ping') {
      if (this.#bmfClients.size === 0) {
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
      this.broadcast(trimmed, socket, socket => this.#bmfClients.has(socket));
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
    const role = String(value || '').trim().toLowerCase();
    if (role === 'bmf-native') return 'bmf-native';
    if (role === 'cityrpg' || role === 'plugin') return 'plugin';
    return 'unknown';
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
    socket.removeAllListeners();
    if (!this.#stopped) {
      this.emit('client', {
        bmfClients: this.#bmfClients.size,
        clients: this.#clients.size,
      });
    }
  }
}
