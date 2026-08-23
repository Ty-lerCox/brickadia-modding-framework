import { once } from 'node:events';
import { createConnection, Socket } from 'node:net';
import { afterEach, describe, expect, it, vi } from 'vitest';
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
  senderUuid?: string;
  connectionGeneration?: number;
  operationRequestId?: string;
  offThreadMs?: number;
};

type JsonEnvelope = {
  type?: string;
  accepted?: boolean;
  code?: string;
  role?: string;
  source?: string;
  capabilities?: string[];
  capability?: string;
  event?: string;
  schemaVersion?: number | null;
  generation?: string;
  playerId?: string;
  rateHz?: number;
  leaseMs?: number;
  expiresAtMs?: number;
  available?: boolean;
  motion?: {
    available?: boolean;
    capability?: string;
    capabilities?: string[];
    event?: string;
    schemaVersion?: number | null;
    generation?: string;
    minLeaseMs?: number;
    maxLeaseMs?: number;
    minRateHz?: number;
    maxRateHz?: number;
  };
  record?: {
    type?: string;
    event?: string;
    payload?: Record<string, unknown>;
  };
};

const PLAYER_ONE = '11111111-2222-4333-8444-555555555555';
const PLAYER_TWO = '22222222-3333-4444-8555-666666666666';
const MOTION_CAPABILITY = 'player-motion-v1';
const MOTION_EVENT = 'players.motion.v1';

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

const readNextJson = (socket: Socket) =>
  new Promise<JsonEnvelope>((resolve, reject) => {
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
      resolve(JSON.parse(buffer.slice(0, newline)) as JsonEnvelope);
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

const connectCompanionClient = async (bridge: BmfSocketBridgeHost) => {
  const socket = createConnection({ host: bridge.host, port: bridge.port });
  sockets.push(socket);
  await once(socket, 'connect');
  const helloAck = readNextJson(socket);
  socket.write(
    `${JSON.stringify({
      type: 'hello',
      token: bridge.token,
      role: 'companion',
    })}\n`,
  );
  return { socket, helloAck: await helloAck };
};

const advertiseMotionSchema = (
  socket: Socket,
  available = true,
  generation = 'test-generation-1',
) => {
  socket.write(
    `${JSON.stringify({
      type: 'motion.schema',
      source: 'bmf',
      capability: MOTION_CAPABILITY,
      available,
      event: MOTION_EVENT,
      schemaVersion: 1,
      generation,
    })}\n`,
  );
};

const subscribeToMotion = (
  socket: Socket,
  playerId = PLAYER_ONE,
  leaseMs = 5_000,
  schemaVersion = 1,
  rateHz = 10,
) => {
  const ack = readNextJson(socket);
  socket.write(
    `${JSON.stringify({
      type: 'motion.subscribe',
      schemaVersion,
      playerId,
      leaseMs,
      rateHz,
    })}\n`,
  );
  return ack;
};

const sendMotionEvent = (
  socket: Socket,
  sequence: number,
  options: {
    generation?: string;
    schemaVersion?: number;
    playerId?: string;
    sampledAtMs?: number;
    x?: number;
    y?: number;
    z?: number;
    padding?: string;
  } = {},
) => {
  socket.write(
    `${JSON.stringify({
      type: 'event',
      source: 'bmf',
      record: {
        type: 'event',
        event: MOTION_EVENT,
        payload: {
          schemaVersion: options.schemaVersion ?? 1,
          playerId: options.playerId ?? PLAYER_ONE,
          generation: options.generation ?? 'test-generation-1',
          sequence,
          sampledAtMs: options.sampledAtMs ?? Date.now(),
          x: options.x ?? 123.5 + sequence,
          y: options.y ?? -456.25,
          z: options.z ?? 78,
          headingDegrees: 271.5,
          headingSource: 'view',
          speedMetersPerSecond: 6.25,
          vehicleActive: false,
          ...(options.padding ? { padding: options.padding } : {}),
        },
      },
    })}\n`,
  );
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
  vi.restoreAllMocks();
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

  it('carries only copied private identity attribution metadata', async () => {
    const { bridge, socket } = await startBridge();
    const envelopePromise = readNextEnvelope(socket);
    const commandPromise = bridge.execCommand('bmf.chat.whisper', 1_000, {
      senderUuid: '11111111-2222-4333-8444-555555555555',
      connectionGeneration: 7,
      operationRequestId: 'private-request-7',
      offThreadMs: 2.5,
    });
    const envelope = await envelopePromise;

    expect(envelope).toMatchObject({
      senderUuid: '11111111-2222-4333-8444-555555555555',
      connectionGeneration: 7,
      operationRequestId: 'private-request-7',
      offThreadMs: 2.5,
    });
    expect(JSON.stringify(envelope)).not.toMatch(
      /controller|playerState|UObject/i,
    );

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

describe('BmfSocketBridgeHost companion motion protocol', () => {
  it('keeps the companion role isolated and fails closed without metadata', async () => {
    const { bridge } = await startBridge();
    const { socket, helloAck } = await connectCompanionClient(bridge);

    expect(helloAck).toMatchObject({
      type: 'hello.ack',
      role: 'companion',
      source: 'omegga-broker',
      capabilities: [],
      motion: {
        available: false,
        capability: MOTION_CAPABILITY,
        capabilities: [],
        event: MOTION_EVENT,
        schemaVersion: null,
      },
    });

    await expect(subscribeToMotion(socket)).resolves.toMatchObject({
      type: 'motion.subscribe.ack',
      accepted: false,
      playerId: PLAYER_ONE,
      code: 'SCHEMA_UNAVAILABLE',
      leaseMs: 0,
      expiresAtMs: 0,
    });

    const denied = readNextJson(socket);
    socket.write(
      `${JSON.stringify({ type: 'command', command: 'bmf.status' })}\n`,
    );
    await expect(denied).resolves.toMatchObject({
      type: 'error',
      code: 'ROLE_NOT_AUTHORIZED',
    });
    expect(bridge.motionStatus).toMatchObject({
      available: false,
      activeLeases: 0,
      subscriptionsRejected: 1,
    });
    expect(bridge.maxMotionPayloadBytes).toBe(16 * 1_024);
  });

  it('requires exact schema metadata and forwards only exact scoped events', async () => {
    const { bridge, socket: native } = await startBridge();
    const { socket: companion } = await connectCompanionClient(bridge);

    const schemaUpdate = readNextJson(companion);
    advertiseMotionSchema(native, true, 'x'.repeat(81));
    advertiseMotionSchema(native);
    await expect(schemaUpdate).resolves.toMatchObject({
      type: 'motion.schema',
      available: true,
      capability: MOTION_CAPABILITY,
      capabilities: [MOTION_CAPABILITY],
      event: MOTION_EVENT,
      schemaVersion: 1,
      generation: 'test-generation-1',
    });

    const subscribeAck = await subscribeToMotion(
      companion,
      PLAYER_ONE,
      7_000,
      1,
      10,
    );
    expect(subscribeAck).toMatchObject({
      type: 'motion.subscribe.ack',
      accepted: true,
      playerId: PLAYER_ONE,
      rateHz: 10,
      leaseMs: 7_000,
      schemaVersion: 1,
      generation: 'test-generation-1',
    });
    expect(subscribeAck.expiresAtMs).toBeGreaterThan(Date.now());

    const forwarded = readNextJson(companion);
    sendMotionEvent(native, 1, { generation: 'wrong-generation' });
    sendMotionEvent(native, 2, { playerId: PLAYER_TWO });
    sendMotionEvent(native, 3);

    await expect(forwarded).resolves.toMatchObject({
      type: 'event',
      source: 'bmf',
      record: {
        type: 'event',
        event: MOTION_EVENT,
        payload: {
          schemaVersion: 1,
          playerId: PLAYER_ONE,
          generation: 'test-generation-1',
          sequence: 3,
          x: 126.5,
          y: -456.25,
          z: 78,
          headingDegrees: 271.5,
          headingSource: 'view',
          speedMetersPerSecond: 6.25,
          vehicleActive: false,
        },
      },
    });
    expect(bridge.motionStatus).toMatchObject({
      subscriptionsAccepted: 1,
      forwarded: 1,
    });
  });

  it('isolates subscriptions by player id', async () => {
    const { bridge, socket: native } = await startBridge();
    const { socket: first } = await connectCompanionClient(bridge);
    const firstSchema = readNextJson(first);
    advertiseMotionSchema(native);
    await firstSchema;
    const { socket: second, helloAck } = await connectCompanionClient(bridge);
    expect(helloAck.capabilities).toEqual([MOTION_CAPABILITY]);

    await subscribeToMotion(first, PLAYER_ONE, 5_000, 1, 20);
    await subscribeToMotion(second, PLAYER_TWO, 5_000, 1, 20);
    const firstEvent = readNextJson(first);
    const secondEvent = readNextJson(second);
    sendMotionEvent(native, 11, { playerId: PLAYER_ONE });
    sendMotionEvent(native, 22, { playerId: PLAYER_TWO });

    await expect(firstEvent).resolves.toMatchObject({
      record: { payload: { playerId: PLAYER_ONE, sequence: 11 } },
    });
    await expect(secondEvent).resolves.toMatchObject({
      record: { payload: { playerId: PLAYER_TWO, sequence: 22 } },
    });
  });

  it('rate-bounds and coalesces pending motion to the newest value', async () => {
    const { bridge, socket: native } = await startBridge();
    const { socket: companion } = await connectCompanionClient(bridge);
    const schema = readNextJson(companion);
    advertiseMotionSchema(native);
    await schema;
    await subscribeToMotion(companion, PLAYER_ONE, 5_000, 1, 20);

    const first = readNextJson(companion);
    sendMotionEvent(native, 31);
    await expect(first).resolves.toMatchObject({
      record: { payload: { sequence: 31 } },
    });

    const newest = readNextJson(companion);
    sendMotionEvent(native, 32);
    sendMotionEvent(native, 33);
    await expect(newest).resolves.toMatchObject({
      record: { payload: { sequence: 33 } },
    });
    expect(bridge.motionStatus.coalesced).toBeGreaterThanOrEqual(1);
  });

  it('revokes leases when the native schema source disconnects', async () => {
    const { bridge, socket: native } = await startBridge();
    const { socket: companion } = await connectCompanionClient(bridge);
    const available = readNextJson(companion);
    advertiseMotionSchema(native);
    await available;
    await subscribeToMotion(companion);

    const unavailable = readNextJson(companion);
    native.destroy();
    await expect(unavailable).resolves.toMatchObject({
      type: 'motion.schema',
      available: false,
      capabilities: [],
      schemaVersion: null,
    });
    await expect(subscribeToMotion(companion)).resolves.toMatchObject({
      type: 'motion.subscribe.ack',
      accepted: false,
      code: 'SCHEMA_UNAVAILABLE',
      leaseMs: 0,
      expiresAtMs: 0,
    });
    expect(bridge.motionStatus.activeLeases).toBe(0);
  });

  it('expires leases without leaking a queued sample into a renewal', async () => {
    const baseNowMs = Date.now();
    const now = vi.spyOn(Date, 'now').mockReturnValue(baseNowMs);
    const { bridge, socket: native } = await startBridge();
    const { socket: companion } = await connectCompanionClient(bridge);
    const schema = readNextJson(companion);
    advertiseMotionSchema(native);
    await schema;
    await expect(
      subscribeToMotion(companion, PLAYER_ONE, 1, 1, 10),
    ).resolves.toMatchObject({
      accepted: true,
      leaseMs: 1_000,
      expiresAtMs: baseNowMs + 1_000,
    });

    now.mockReturnValue(baseNowMs + 1_001);
    sendMotionEvent(native, 61);
    await vi.waitFor(() => {
      expect(bridge.motionStatus.expiredLeases).toBe(1);
    });
    await expect(
      subscribeToMotion(companion, PLAYER_ONE, 7_000, 1, 10),
    ).resolves.toMatchObject({
      type: 'motion.subscribe.ack',
      accepted: true,
      playerId: PLAYER_ONE,
      leaseMs: 7_000,
    });

    const forwarded = readNextJson(companion);
    sendMotionEvent(native, 62);
    await expect(forwarded).resolves.toMatchObject({
      record: { payload: { sequence: 62 } },
    });
    expect(bridge.motionStatus.expiredLeases).toBe(1);
  });

  it('drops oversized motion frames without blocking the next valid frame', async () => {
    const { bridge, socket: native } = await startBridge({
      maxMotionPayloadBytes: 1_024,
    });
    const { socket: companion } = await connectCompanionClient(bridge);
    const schema = readNextJson(companion);
    advertiseMotionSchema(native);
    await schema;
    await subscribeToMotion(companion);

    const forwarded = readNextJson(companion);
    sendMotionEvent(native, 41, { padding: 'x'.repeat(2_000) });
    sendMotionEvent(native, 42);
    await expect(forwarded).resolves.toMatchObject({
      record: { payload: { sequence: 42 } },
    });
    expect(bridge.motionStatus).toMatchObject({
      droppedOversize: 1,
      forwarded: 1,
    });
  });

  it('rejects stale, future, and out-of-bounds samples before fanout', async () => {
    const { bridge, socket: native } = await startBridge();
    const { socket: companion } = await connectCompanionClient(bridge);
    const schema = readNextJson(companion);
    advertiseMotionSchema(native);
    await schema;
    await subscribeToMotion(companion);

    const forwarded = readNextJson(companion);
    const nowMs = Date.now();
    sendMotionEvent(native, 51, { sampledAtMs: nowMs - 30_001 });
    sendMotionEvent(native, 52, { sampledAtMs: nowMs + 6_000 });
    sendMotionEvent(native, 53, { x: 10_000_001 });
    sendMotionEvent(native, 54);

    await expect(forwarded).resolves.toMatchObject({
      record: { payload: { sequence: 54 } },
    });
    expect(bridge.motionStatus).toMatchObject({
      droppedInvalid: 3,
      forwarded: 1,
    });
  });
});
