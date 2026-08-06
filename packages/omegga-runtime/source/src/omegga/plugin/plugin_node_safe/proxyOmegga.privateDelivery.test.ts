import { describe, expect, test, vi } from 'vitest';

import { ProxyOmegga } from './proxyOmegga';

describe('safe-worker private delivery boundary', () => {
  test('keeps connection generation in plain player snapshots and forwards the captured session', async () => {
    const whisperTransport = vi.fn(async () => undefined);
    const statusTransport = vi.fn(async () => undefined);
    const omegga = new ProxyOmegga(
      () => undefined,
      undefined,
      whisperTransport,
      statusTransport,
    );

    omegga.emit('plugin:players:raw', [
      ['A', 'A', 'uuid-a', 'Controller_A1', 'State_A1', 1],
      ['B', 'B', 'uuid-b', 'Controller_B', 'State_B', 1],
      ['C', 'C', 'uuid-c', 'Controller_C', 'State_C', 1],
    ]);
    const capturedA = omegga.getPlayers()[0];

    omegga.emit('plugin:players:raw', [
      ['A', 'A', 'uuid-a', 'Controller_A2', 'State_A2', 2],
      ['B', 'B', 'uuid-b', 'Controller_B', 'State_B', 1],
      ['C', 'C', 'uuid-c', 'Controller_C', 'State_C', 1],
    ]);

    await omegga.whisper(capturedA, 'delayed');
    expect(whisperTransport).toHaveBeenCalledWith(capturedA, ['delayed']);
    expect(capturedA).toMatchObject({
      id: 'uuid-a',
      controller: 'Controller_A1',
      state: 'State_A1',
      connectionGeneration: 1,
    });
    expect(omegga.getPlayers()[0]).toMatchObject({
      id: 'uuid-a',
      controller: 'Controller_A2',
      state: 'State_A2',
      connectionGeneration: 2,
    });

    await omegga.middlePrint(omegga.getPlayers()[1], 'status');
    expect(statusTransport).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'uuid-b', connectionGeneration: 1 }),
      'status',
    );
  });
});
