import { once } from 'node:events';
import { createConnection, Socket } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import BmfSocketBridgeHost from './bmfSocketBridge';
import type { BmfSocketBridgeOptions } from './bmfSocketBridge';

type DirectCommandEnvelope = {
  type: 'command';
  id: string;
  source: string;
  command: string;
  issuedAtMs: number;
  deadlineMs: number;
  serviceClass: 'interactive' | 'bulk';
};

const bridges: BmfSocketBridgeHost[] = [];
const sockets: Socket[] = [];

const readNextEnvelope = (socket: Socket) =>
  new Promise<DirectCommandEnvelope>((resolve, reject) => {
    let buffer = '';
    const cleanup = () => {
      socket.off('data', onData);
      socket.off('error', onError);
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const onData = (chunk: Buffer) => {
      buffer += chunk.toString('utf8');
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      cleanup();
      resolve(JSON.parse(buffer.slice(0, newline)) as DirectCommandEnvelope);
    };
    socket.on('data', onData);
    socket.on('error', onError);
  });

const connectNativeClient = async (bridge: BmfSocketBridgeHost) => {
  const socket = createConnection({ host: bridge.host, port: bridge.port });
  sockets.push(socket);
  await once(socket, 'connect');

  const authenticated = new Promise<void>(resolve => {
    const onClient = () => {
      if (!bridge.hasBmfClients) return;
      bridge.off('client', onClient);
      resolve();
    };
    bridge.on('client', onClient);
  });
  socket.write(
    `${JSON.stringify({
      type: 'hello',
      token: bridge.token,
      role: 'bmf-native',
    })}\n`,
  );
  await authenticated;
  return socket;
};

const startBridge = async (options: BmfSocketBridgeOptions = {}) => {
  const bridge = new BmfSocketBridgeHost(options);
  bridges.push(bridge);
  await bridge.start();
  const socket = await connectNativeClient(bridge);
  return { bridge, socket };
};

const completeCommand = (socket: Socket, envelope: DirectCommandEnvelope) => {
  socket.write(
    `${JSON.stringify({
      type: 'response',
      id: envelope.id,
      ok: true,
      response: 'ok=true',
    })}\n`,
  );
};

afterEach(() => {
  for (const socket of sockets.splice(0)) socket.destroy();
  for (const bridge of bridges.splice(0)) bridge.stop();
});

describe('BmfSocketBridgeHost direct command metadata', () => {
  it('adds the default timeout deadline and interactive service class', async () => {
    const { bridge, socket } = await startBridge();
    const before = Date.now();
    const envelopePromise = readNextEnvelope(socket);
    const commandPromise = bridge.execCommand('bmf.status');
    const envelope = await envelopePromise;

    expect(envelope).toMatchObject({
      type: 'command',
      source: 'omegga-core',
      command: 'bmf.status',
      serviceClass: 'interactive',
    });
    expect(envelope.issuedAtMs).toBeGreaterThanOrEqual(before);
    expect(envelope.deadlineMs - envelope.issuedAtMs).toBe(3000);

    completeCommand(socket, envelope);
    await expect(commandPromise).resolves.toMatchObject({ ok: true });
  });

  it('allows an explicit bulk service class with a request timeout deadline', async () => {
    const { bridge, socket } = await startBridge();
    const envelopePromise = readNextEnvelope(socket);
    const commandPromise = bridge.execCommand('bmf.players.sync', 750, {
      serviceClass: 'bulk',
    });
    const envelope = await envelopePromise;

    expect(envelope.serviceClass).toBe('bulk');
    expect(envelope.deadlineMs - envelope.issuedAtMs).toBe(750);

    completeCommand(socket, envelope);
    await expect(commandPromise).resolves.toMatchObject({ ok: true });
  });

  it('preserves an outer absolute admission deadline unchanged', async () => {
    const { bridge, socket } = await startBridge();
    const issuedAtMs = Date.now();
    const deadlineMs = issuedAtMs + 2_000;
    const envelopePromise = readNextEnvelope(socket);
    const commandPromise = bridge.execCommand('bmf.status', 5_000, {
      issuedAtMs,
      deadlineMs,
      serviceClass: 'interactive',
    });
    const envelope = await envelopePromise;

    expect(envelope).toMatchObject({ issuedAtMs, deadlineMs });
    completeCommand(socket, envelope);
    await expect(commandPromise).resolves.toMatchObject({ ok: true });
  });

  it('applies the minimum timeout to short direct commands', async () => {
    const { bridge, socket } = await startBridge();
    const envelopePromise = readNextEnvelope(socket);
    const commandPromise = bridge.execCommand('bmf.health', 1);
    const envelope = await envelopePromise;

    expect(envelope.deadlineMs - envelope.issuedAtMs).toBe(100);

    completeCommand(socket, envelope);
    await expect(commandPromise).resolves.toMatchObject({ ok: true });
  });

  it('rejects terminally when the direct pending-command cap is full', async () => {
    const { bridge, socket } = await startBridge({ maxPendingCommands: 1 });
    const firstEnvelopePromise = readNextEnvelope(socket);
    const first = bridge.execCommand('bmf.first');
    const firstEnvelope = await firstEnvelopePromise;

    await expect(bridge.execCommand('bmf.second')).rejects.toThrow(
      /pending limit 1 reached/,
    );
    completeCommand(socket, firstEnvelope);
    await expect(first).resolves.toMatchObject({ ok: true });
  });

  it('disconnects an over-buffer client and rejects its active command', async () => {
    const { bridge, socket } = await startBridge({
      maxClientBufferBytes: 256,
    });
    const envelopePromise = readNextEnvelope(socket);
    const command = bridge.execCommand('bmf.waiting');
    const commandRejected = expect(command).rejects.toThrow(
      /disconnected before command/,
    );
    await envelopePromise;
    const closed = once(socket, 'close');

    socket.write(Buffer.alloc(257, 120));
    await closed;
    await commandRejected;
    expect(bridge.hasBmfClients).toBe(false);
  });
});
