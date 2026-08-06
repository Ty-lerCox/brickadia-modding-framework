import Omegga from './server';
import { describe, expect, test } from 'vitest';

const player = (
  name: string,
  id: string,
  controller: string,
  state: string,
  connectionGeneration = 1,
) => ({
  name,
  displayName: name,
  id,
  controller,
  state,
  connectionGeneration,
});

describe('fail-closed private delivery identity', () => {
  test('three players receive only their own interleaved output and stale sessions drop', async () => {
    const a1 = player('A', 'uuid-a', 'Controller_A1', 'State_A1');
    const b = player('B', 'uuid-b', 'Controller_B', 'State_B');
    const c = player('C', 'uuid-c', 'Controller_C', 'State_C');
    const omegga = Object.create(Omegga.prototype) as Omegga;
    omegga.players = [a1, b, c] as any;
    omegga._privateDeliveryDropCount = 0;
    omegga._activePlayerConnections = new Map([
      [a1.id, { generation: 1, controller: a1.controller, state: a1.state }],
      [b.id, { generation: 1, controller: b.controller, state: b.state }],
      [c.id, { generation: 1, controller: c.controller, state: c.state }],
    ]);
    omegga._verifiedPrivateControllers = new Map(
      omegga._activePlayerConnections,
    );

    const deliveries: any[] = [];
    (omegga as any).deliverBmfPrivateMessage = async (envelope: unknown) => {
      deliveries.push(envelope);
    };

    await Promise.all(
      Array.from({ length: 5 }, (_, index) =>
        omegga.deliverPrivateOutput('whisper', a1 as any, `unknown-${index}`),
      ),
    );
    expect(deliveries).toHaveLength(5);
    expect(deliveries.every(item => item.senderUuid === a1.id)).toBe(true);
    expect(deliveries.every(item => item.connectionGeneration === 1)).toBe(
      true,
    );
    expect(deliveries.some(item => item.senderUuid === b.id)).toBe(false);
    expect(deliveries.some(item => item.senderUuid === c.id)).toBe(false);

    omegga.players = [b, c] as any;
    omegga._activePlayerConnections.delete(a1.id);
    omegga._verifiedPrivateControllers.delete(a1.id);
    await omegga.deliverPrivateOutput('whisper', a1 as any, 'late-old-session');
    expect(deliveries).toHaveLength(5);

    const a2 = player('A', 'uuid-a', 'Controller_A2', 'State_A2', 2);
    omegga.players = [a2, b, c] as any;
    omegga._activePlayerConnections.set(a2.id, {
      generation: 2,
      controller: a2.controller,
      state: a2.state,
    });
    omegga._verifiedPrivateControllers.set(a2.id, {
      generation: 2,
      controller: a2.controller,
      state: a2.state,
    });
    await omegga.deliverPrivateOutput(
      'whisper',
      a1 as any,
      'stale-after-rejoin',
    );
    expect(deliveries).toHaveLength(5);
    await omegga.deliverPrivateOutput('whisper', a2 as any, 'current-session');
    expect(deliveries).toHaveLength(6);
    expect(deliveries[5].connectionGeneration).toBe(2);
  });

  test('names are never accepted as private recipient identities', async () => {
    const a = player('A', 'uuid-a', 'Controller_A', 'State_A');
    const omegga = Object.create(Omegga.prototype) as Omegga;
    omegga.players = [a] as any;
    omegga._privateDeliveryDropCount = 0;
    omegga._activePlayerConnections = new Map([
      [a.id, { generation: 1, controller: a.controller, state: a.state }],
    ]);
    omegga._verifiedPrivateControllers = new Map(
      omegga._activePlayerConnections,
    );
    const deliveries: unknown[] = [];
    (omegga as any).deliverBmfPrivateMessage = async (envelope: unknown) => {
      deliveries.push(envelope);
    };

    await omegga.deliverPrivateOutput('whisper', 'A', 'name-only');
    expect(deliveries).toHaveLength(0);
    await omegga.deliverPrivateOutput('whisper', a.id, 'uuid-exact');
    expect(deliveries).toHaveLength(1);

    omegga._verifiedPrivateControllers.clear();
    await omegga.deliverPrivateOutput('whisper', a.id, 'unverified-controller');
    expect(deliveries).toHaveLength(1);
  });

  test('legacy name-only feedback helpers are disabled', async () => {
    const a = player('A', 'uuid-a', 'Controller_A', 'State_A');
    const omegga = Object.create(Omegga.prototype) as Omegga;
    omegga.players = [a] as any;
    omegga._privateDeliveryDropCount = 0;
    const deliveries: unknown[] = [];
    (omegga as any).deliverPrivateOutput = async (...args: unknown[]) => {
      deliveries.push(args);
    };

    await omegga.whisperName(a.name, 'legacy-name-only');
    await omegga.tryNativePrefabWhisper(a.name, 'native-name-only');

    expect(deliveries).toHaveLength(0);
    expect(omegga._privateDeliveryDropCount).toBe(2);
  });
});
