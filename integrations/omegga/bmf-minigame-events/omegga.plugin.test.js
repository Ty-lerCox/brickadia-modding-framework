const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const BmfMinigameEvents = require('./omegga.plugin');

async function waitForRequest(commandDir, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    if (fs.existsSync(commandDir)) {
      const request = fs
        .readdirSync(commandDir)
        .find(file => file.endsWith('.request.txt'));
      if (request) return path.join(commandDir, request);
    }
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('timed out waiting for request file');
}

test('seeds leave caches from BMF minigame data snapshot response', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commandDir = path.join(root, 'commands');
  const adapter = new BmfMinigameEvents(
    {},
    {
      commandDir,
      seedCacheFromBmfData: true,
      seedCacheTimeoutMs: 2000,
    }
  );

  const seed = adapter.seedCacheFromBmfData('test');
  const requestPath = await waitForRequest(commandDir);
  assert.strictEqual(fs.readFileSync(requestPath, 'utf8'), 'bmf.minigames.data.snapshot');

  const requestId = path.basename(requestPath, '.request.txt');
  fs.rmSync(requestPath, { force: true });

  const snapshot = {
    updatedAt: '2026-06-07T16:00:00Z',
    source: 'omegga.bmf-minigame-events',
    totalUpdates: 1,
    minigames: {
      'name:GLOBAL#0': {
        key: 'name:GLOBAL#0',
        name: 'GLOBAL',
        index: 0,
      },
    },
    players: {
      '33333333-3333-4333-8333-333333333333': {
        id: '33333333-3333-4333-8333-333333333333',
        name: 'Ty',
      },
    },
    memberships: {
      '33333333-3333-4333-8333-333333333333': {
        player: {
          id: '33333333-3333-4333-8333-333333333333',
          name: 'Ty',
        },
        minigame: {
          key: 'name:GLOBAL#0',
          name: 'GLOBAL',
          index: 0,
        },
        minigameKey: 'name:GLOBAL#0',
      },
    },
    teams: {
      'name:GLOBAL#0:team:Blue': {
        key: 'name:GLOBAL#0:team:Blue',
        name: 'Blue',
        minigameKey: 'name:GLOBAL#0',
      },
    },
    teamMemberships: {
      '33333333-3333-4333-8333-333333333333': {
        player: {
          id: '33333333-3333-4333-8333-333333333333',
          name: 'Ty',
        },
        minigame: {
          key: 'name:GLOBAL#0',
          name: 'GLOBAL',
          index: 0,
        },
        minigameKey: 'name:GLOBAL#0',
        team: {
          name: 'Blue',
        },
        teamKey: 'name:GLOBAL#0:team:Blue',
      },
    },
    counts: {
      minigames: 1,
      players: 1,
      memberships: 1,
      teams: 1,
      teamMemberships: 1,
    },
  };

  fs.writeFileSync(
    path.join(commandDir, `${requestId}.response.txt`),
    [
      'ok=true',
      'detail=ok',
      'command=bmf.minigames.data.snapshot',
      'BMF bmf.minigames.data.snapshot OK Minigame data snapshot collected',
      `snapshot_json=${JSON.stringify(snapshot)}`,
      '',
    ].join('\n'),
    'utf8'
  );

  const summary = await seed;
  assert.strictEqual(summary.outcome, 'success');
  assert.strictEqual(summary.memberships, 1);
  assert.strictEqual(summary.teamMemberships, 1);
  assert.strictEqual(adapter.counters.seedSuccesses, 1);
  assert.strictEqual(adapter.playerMinigameCache.get('33333333-3333-4333-8333-333333333333').name, 'GLOBAL');
  assert.strictEqual(adapter.minigameCache.get('name:GLOBAL#0').name, 'GLOBAL');
  assert.strictEqual(adapter.teamMembershipCache.get('33333333-3333-4333-8333-333333333333').team.name, 'Blue');
});
