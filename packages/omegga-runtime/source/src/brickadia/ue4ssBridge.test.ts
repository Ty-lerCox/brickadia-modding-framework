import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import Ue4ssBridgeHost from './ue4ssBridge';

const tempDirs: string[] = [];
const bridges: Ue4ssBridgeHost[] = [];

const waitFor = async (predicate: () => boolean, timeoutMs = 1_000) => {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt >= timeoutMs)
      throw new Error('waitFor timed out');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
};

const startReadyBridge = async (options = {}) => {
  const tempDir = fs.mkdtempSync(
    path.join(os.tmpdir(), 'omegga-ue4ss-admission-'),
  );
  tempDirs.push(tempDir);
  const bridge = new Ue4ssBridgeHost(tempDir, options);
  bridges.push(bridge);
  const env = bridge.start();
  fs.appendFileSync(
    env.OMEGGA_UE4SS_OUTBOX,
    `${JSON.stringify({
      jsonrpc: '2.0',
      method: 'bridge.hello',
      params: { session: env.OMEGGA_UE4SS_SESSION, transport: 'file' },
    })}\n`,
  );
  await bridge.waitUntilReady(500);
  return { bridge, env };
};

afterEach(() => {
  for (const bridge of bridges.splice(0)) bridge.stop();
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

describe('UE4SS bridge outbox reader', () => {
  it('consumes outbox writes without waiting for the fallback poll', async () => {
    const tempDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'omegga-ue4ss-outbox-'),
    );
    tempDirs.push(tempDir);
    const bridge = new Ue4ssBridgeHost(tempDir, {
      fallbackPollIntervalMs: 5_000,
    });
    bridges.push(bridge);
    const env = bridge.start();

    fs.appendFileSync(
      env.OMEGGA_UE4SS_OUTBOX,
      `${JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.hello',
        params: {
          session: env.OMEGGA_UE4SS_SESSION,
          transport: 'file',
        },
      })}\n`,
    );

    await expect(bridge.waitUntilReady(400)).resolves.toMatchObject({
      transport: 'file',
    });
    expect(bridge.getOutboxReaderStatus()).toMatchObject({
      mode: 'watch+poll',
      fallbackPolls: 0,
      reads: 1,
    });
    expect(bridge.getOutboxReaderStatus().watchEvents).toBeGreaterThan(0);
  });

  it('drains a multi-chunk append without waiting for fallback polling', async () => {
    const tempDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'omegga-ue4ss-outbox-large-'),
    );
    tempDirs.push(tempDir);
    const bridge = new Ue4ssBridgeHost(tempDir, {
      fallbackPollIntervalMs: 5_000,
    });
    bridges.push(bridge);
    const env = bridge.start();
    const padding = Array.from({ length: 1_500 }, (_, index) =>
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.log',
        params: { index, message: 'x'.repeat(160) },
      }),
    );

    fs.appendFileSync(
      env.OMEGGA_UE4SS_OUTBOX,
      `${padding.join('\n')}\n${JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.hello',
        params: { session: env.OMEGGA_UE4SS_SESSION, transport: 'file' },
      })}\n`,
    );

    await expect(bridge.waitUntilReady(1_000)).resolves.toMatchObject({
      transport: 'file',
    });
    expect(bridge.getOutboxReaderStatus().reads).toBeGreaterThan(1);
    expect(bridge.getOutboxReaderStatus().fallbackPolls).toBe(0);
  });
});

describe('UE4SS inbox admission', () => {
  it('never configures a record larger than the Lua 64 KiB reader cap', () => {
    const tempDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'omegga-ue4ss-record-cap-'),
    );
    tempDirs.push(tempDir);
    const bridge = new Ue4ssBridgeHost(tempDir, {
      maxRequestBytes: 128 * 1024,
    });
    bridges.push(bridge);

    expect(bridge.maxRequestBytes).toBe(64 * 1024);
  });

  it('keeps host status separate from the Lua admission snapshot', async () => {
    const tempDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'omegga-ue4ss-runtime-status-'),
    );
    tempDirs.push(tempDir);
    const bridge = new Ue4ssBridgeHost(tempDir);
    bridges.push(bridge);
    const env = bridge.start();

    expect(env.OMEGGA_UE4SS_HOST_STATUS).not.toBe(env.OMEGGA_UE4SS_STATUS);
    expect(fs.existsSync(env.OMEGGA_UE4SS_HOST_STATUS)).toBe(true);
    expect(fs.existsSync(env.OMEGGA_UE4SS_STATUS)).toBe(false);
    expect(bridge.getRuntimeAdmissionStatus()).toBeNull();
    const runtimeSnapshot = JSON.stringify({
      inbox_bounded_admission_enabled: true,
      inbox_processed_total: 7,
      inbox_expired_total: 2,
    });
    fs.writeFileSync(env.OMEGGA_UE4SS_STATUS, runtimeSnapshot);

    fs.appendFileSync(
      env.OMEGGA_UE4SS_OUTBOX,
      `${JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.hello',
        params: { session: env.OMEGGA_UE4SS_SESSION, transport: 'file' },
      })}\n`,
    );
    await bridge.waitUntilReady(500);

    expect(fs.readFileSync(env.OMEGGA_UE4SS_STATUS, 'utf8')).toBe(
      runtimeSnapshot,
    );
    expect(bridge.getRuntimeAdmissionStatus()).toMatchObject({
      enabled: true,
      processed: 7,
      expired: 2,
    });
  });

  it('rejects an oversized record before appending it to the inbox', async () => {
    const { bridge, env } = await startReadyBridge({
      maxRequestBytes: 256,
      maxPendingBytes: 4_096,
    });

    await expect(bridge.broadcast('x'.repeat(512))).rejects.toThrow(
      /pending byte limit/,
    );
    expect(fs.readFileSync(env.OMEGGA_UE4SS_INBOX, 'utf8')).toBe('');
    expect(bridge.getAdmissionStatus()).toMatchObject({
      rejected: { bytes: 1 },
      pending: { totalRequests: 0, totalBytes: 0 },
    });
  });

  it('attaches deadlines and keeps a bounded health lane under regular saturation', async () => {
    const { bridge, env } = await startReadyBridge({
      maxPendingRequests: 1,
      maxPendingBytes: 4096,
      exemptMaxPendingRequests: 1,
      exemptMaxPendingBytes: 4096,
      queueDeadlineMs: 500,
    });
    const issuedAtMs = Date.now();
    const deadlineMs = issuedAtMs + 2_000;
    const regular = bridge.execCommand('Chat.Broadcast hello', 1_000, {
      issuedAtMs,
      deadlineMs,
    });
    await expect(
      bridge.execCommand('Chat.Broadcast rejected', 1_000),
    ).rejects.toThrow(/pending request limit 1/);
    const ping = bridge.ping(1_000);

    await waitFor(
      () =>
        fs.readFileSync(env.OMEGGA_UE4SS_INBOX, 'utf8').trim().split(/\r?\n/)
          .length === 2,
    );
    const messages = fs
      .readFileSync(env.OMEGGA_UE4SS_INBOX, 'utf8')
      .trim()
      .split(/\r?\n/)
      .map(line => JSON.parse(line));
    expect(messages[0].params).toMatchObject({
      service_class: 'interactive',
      admission_exempt: false,
    });
    expect(messages[0].params).toMatchObject({
      issued_at_ms: issuedAtMs,
      deadline_ms: deadlineMs,
    });
    expect(messages[1]).toMatchObject({
      method: 'bridge.ping',
      params: { service_class: 'interactive', admission_exempt: true },
    });

    fs.appendFileSync(
      env.OMEGGA_UE4SS_OUTBOX,
      messages
        .map(message =>
          JSON.stringify({
            jsonrpc: '2.0',
            id: message.id,
            result: { ok: true },
          }),
        )
        .join('\n') + '\n',
    );
    await expect(regular).resolves.toEqual({ ok: true });
    await expect(ping).resolves.toEqual({ ok: true });
    expect(bridge.getAdmissionStatus()).toMatchObject({
      admitted: { interactive: 1, exempt: 1 },
      rejected: { depth: 1 },
      pending: { totalRequests: 0, totalBytes: 0 },
      highWater: { requests: 2 },
    });
  });
});
