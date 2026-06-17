import commandInjector from './commandInjector';
import { describe, expect, it, vi } from 'vitest';

const asLogMatch = (line: string) =>
  ['', line] as unknown as RegExpMatchArray;

describe('commandInjector getServerStatus', () => {
  it('supplements empty runtime fields from the Omegga player cache', async () => {
    const now = Date.now();
    const fakePlayer = {
      name: 'Ty',
      displayName: 'Ty',
      id: 'player-1',
      controller: 'BP_PlayerController_C_1',
      state: 'BP_PlayerState_C_1',
      getRoles: () => ['Admin'],
    };
    const fakeOmegga = {
      players: [fakePlayer],
      _startedAtMs: now - 65_000,
      _playerJoinedAt: new Map([[fakePlayer.id, now - 12_000]]),
    };
    const fakeLogWrangler = {
      omegga: fakeOmegga,
      watchLogChunk: vi.fn().mockResolvedValue([
        asLogMatch('Server Name: Brickadia Windows UE4SS'),
        asLogMatch('Description: '),
        asLogMatch('Bricks: 0'),
        asLogMatch('Components: 0'),
        asLogMatch('Time: 0s'),
        asLogMatch(
          '* Name                     | Ping   | Time     | Roles              | Address                | Id                              ',
        ),
      ]),
    };

    const target = {};
    commandInjector(target as any, fakeLogWrangler as any);

    const status = await (target as { getServerStatus: () => Promise<any> }).getServerStatus();

    expect(status.time).toBeGreaterThanOrEqual(60_000);
    expect(status.players).toEqual([
      expect.objectContaining({
        name: 'Ty',
        ping: 0,
        roles: ['Admin'],
        address: '',
        id: 'player-1',
      }),
    ]);
    expect(status.players[0].time).toBeGreaterThanOrEqual(10_000);
  });

  it('falls back when Brickadia omits the player table header', async () => {
    const fakePlayer = {
      name: 'Ty',
      displayName: 'Ty',
      id: 'player-1',
      controller: 'BP_PlayerController_C_1',
      state: 'BP_PlayerState_C_1',
      getRoles: () => ['Admin'],
    };
    const fakeOmegga = {
      players: [fakePlayer],
      _startedAtMs: Date.now() - 30_000,
      _playerJoinedAt: new Map([[fakePlayer.id, Date.now() - 5_000]]),
    };
    const fakeLogWrangler = {
      omegga: fakeOmegga,
      watchLogChunk: vi.fn().mockResolvedValue([
        asLogMatch('Server Name: Brickadia Windows UE4SS'),
        asLogMatch('Description: '),
        asLogMatch('Bricks: 0'),
        asLogMatch('Components: 0'),
        asLogMatch('Time: 0s'),
      ]),
    };

    const target = {};
    commandInjector(target as any, fakeLogWrangler as any);

    const status = await (target as { getServerStatus: () => Promise<any> }).getServerStatus();

    expect(status.players).toEqual([
      expect.objectContaining({
        name: 'Ty',
        id: 'player-1',
      }),
    ]);
  });
});
