const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const BmfMinigameEvents = require('./omegga.plugin');

async function waitForCommand(commands, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    if (commands.length > 0) return commands.shift();
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error('timed out waiting for socket command');
}

function bridgeOmegga(commands, extras = {}) {
  return {
    ...extras,
    async getPlugin(name) {
      if (name !== 'BMF Bridge' && name !== 'bmf-bridge') return null;
      return {
        loaded: true,
        async emitPlugin(event, command, options) {
          commands.push({ event, command, options });
          return {
            ok: true,
            detail: 'ok',
            transport: 'socket',
            response: {
              text: [
                'ok=true',
                'detail=ok',
                'command=bmf.minigames.data.snapshot',
                `snapshot_json=${JSON.stringify(extras.snapshotResponse || {})}`,
                '',
              ].join('\n'),
            },
          };
        },
      };
    },
  };
}

test('seeds leave caches from BMF minigame data snapshot response', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commands = [];
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
  const adapter = new BmfMinigameEvents(
    bridgeOmegga(commands, { snapshotResponse: snapshot }),
    {
      runtimeDir: root,
      seedCacheFromBmfData: true,
      seedCacheTimeoutMs: 2000,
    }
  );

  const summary = await adapter.seedCacheFromBmfData('test');
  assert.strictEqual(commands.length, 1);
  assert.strictEqual(commands[0].event, 'invokeCommand');
  assert.strictEqual(commands[0].command, 'bmf.minigames.data.snapshot');
  assert.strictEqual(summary.outcome, 'success');
  assert.strictEqual(summary.memberships, 1);
  assert.strictEqual(summary.teamMemberships, 1);
  assert.strictEqual(adapter.counters.seedSuccesses, 1);
  assert.strictEqual(adapter.playerMinigameCache.get('33333333-3333-4333-8333-333333333333').name, 'GLOBAL');
  assert.strictEqual(adapter.minigameCache.get('name:GLOBAL#0').name, 'GLOBAL');
  assert.strictEqual(adapter.teamMembershipCache.get('33333333-3333-4333-8333-333333333333').team.name, 'Blue');
});

test('imports changed unsafe minigame snapshots through BMF data apply-snapshot', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commands = [];
  const match = groups => ({ groups });
  const omegga = bridgeOmegga(commands, {
    async watchLogChunk(command) {
      if (command === 'GetAll BP_Ruleset_C RulesetName') {
        return [
          match({
            index: '0',
            ruleset: 'BP_Ruleset_C_99',
            name: 'Codex Arena',
          }),
        ];
      }
      if (command === 'GetAll BP_Ruleset_C MemberStates') {
        return [['item', match({ index: '0', ruleset: 'BP_Ruleset_C_99' })]];
      }
      if (command === 'GetAll BP_Ruleset_C bInSession') {
        return [
          match({
            index: '0',
            ruleset: 'BP_Ruleset_C_99',
            inSession: 'True',
          }),
        ];
      }
      if (command === 'GetAll BP_Team_C MemberStates') {
        return [['item', match({ index: '0', ruleset: 'BP_Ruleset_C_99', team: 'BP_Team_C_1' })]];
      }
      if (command === 'GetAll BP_Team_C TeamName') {
        return [match({ index: '0', ruleset: 'BP_Ruleset_C_99', team: 'BP_Team_C_1', name: 'Blue' })];
      }
      if (command === 'GetAll BP_Team_C TeamColor') {
        return [
          match({
            index: '0',
            ruleset: 'BP_Ruleset_C_99',
            team: 'BP_Team_C_1',
            r: '12',
            g: '34',
            b: '56',
            a: '255',
          }),
        ];
      }
      return [];
    },
  });
  const adapter = new BmfMinigameEvents(
    omegga,
    {
      runtimeDir: root,
      allowUnsafeConsoleSnapshots: true,
      applySnapshotImports: true,
      emitSnapshotEvents: false,
      minigameCheckTimeoutMs: 2000,
    }
  );

  await adapter.minigameCheck('real-minigame-validation');

  const sent = await waitForCommand(commands);
  const command = sent.command;
  assert.match(command, /^bmf\.minigames\.data\.apply-snapshot payload=/);
  assert.doesNotMatch(command, /^bmf\.minigames\.events\.emit/);

  const payload = JSON.parse(decodeURIComponent(command.match(/payload=([^ ]+)/)[1]));
  assert.strictEqual(payload.source, 'omegga.bmf-minigame-events');
  assert.strictEqual(payload.reason, 'real-minigame-validation');
  assert.strictEqual(payload.minigames.length, 1);
  assert.strictEqual(payload.minigames[0].name, 'Codex Arena');
  assert.strictEqual(payload.minigames[0].ruleset, 'BP_Ruleset_C_99');
  assert.strictEqual(payload.minigames[0].teams.length, 1);
  assert.strictEqual(payload.minigames[0].teams[0].name, 'Blue');
  assert.deepStrictEqual(payload.minigames[0].teams[0].color, [12, 34, 56, 255]);
  assert.strictEqual(adapter.counters.snapshotChanges, 1);
  assert.strictEqual(adapter.counters.snapshotImports, 1);
  assert.strictEqual(adapter.counters.queued, 0);
});

test('observed JoinTeam command emits BMF-compatible teamchange over the socket bridge', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commands = [];
  const player = {
    name: 'Ty',
    displayName: 'Ty',
    id: '33333333-3333-4333-8333-333333333333',
  };
  const adapter = new BmfMinigameEvents(
    bridgeOmegga(commands, {
      getPlayer(ref) {
        return ref === 'Ty' ? player : null;
      },
    }),
    { runtimeDir: root }
  );

  adapter.playerMinigameCache.set(player.id, {
    name: 'Codex Arena',
    index: 0,
  });

  assert.strictEqual(adapter.handleJoinTeamCommand('Ty', 'Blue'), true);

  const sent = await waitForCommand(commands);
  const command = sent.command;
  assert.match(command, /^bmf\.minigames\.events\.emit event=teamchange payload=/);
  const payload = JSON.parse(decodeURIComponent(command.match(/payload=([^ ]+)/)[1]));
  assert.strictEqual(payload.source, 'omegga.bmf-minigame-events');
  assert.strictEqual(payload.reason, 'jointeam-command');
  assert.strictEqual(payload.player.id, player.id);
  assert.strictEqual(payload.minigame.name, 'Codex Arena');
  assert.strictEqual(payload.team.name, 'Blue');
  assert.ok(payload._telemetry.adapterEventQueuedAtMs > 0);
  assert.strictEqual(adapter.counters.lastEvent.transport, 'socket');
  assert.strictEqual(adapter.counters.teamChanges, 1);
  assert.strictEqual(adapter.teamMembershipCache.get(player.id).team.name, 'Blue');

  assert.strictEqual(adapter.handleJoinTeamCommand('Ty', 'Blue'), false);
  assert.strictEqual(adapter.counters.teamChanges, 1);
});

test('manual unsafe sync runs during startup delay after server start', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const messages = [];
  const adapter = new BmfMinigameEvents(
    {
      whisper(_target, message) {
        messages.push(message);
      },
    },
    {
      commandDir: path.join(root, 'commands'),
      allowUnsafeConsoleSnapshots: true,
    }
  );

  const calls = [];
  adapter.serverStarted = true;
  adapter.pollingStarted = false;
  adapter.minigameCheck = async reason => calls.push(`minigame:${reason}`);
  adapter.leaderboardCheck = async reason => calls.push(`leaderboard:${reason}`);

  adapter.handleManualSync('Ty');
  await new Promise(resolve => setImmediate(resolve));

  assert.deepStrictEqual(calls, ['minigame:manual', 'leaderboard:manual']);
  assert.deepStrictEqual(messages, ['BMF minigame snapshot queued.']);
});
