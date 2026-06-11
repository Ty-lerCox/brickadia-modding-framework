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

function readEventLogRecords(eventLogPath) {
  return fs
    .readFileSync(eventLogPath, 'utf8')
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map(line => JSON.parse(line));
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

test('imports changed unsafe minigame snapshots through BMF data apply-snapshot', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commandDir = path.join(root, 'commands');
  const match = groups => ({ groups });
  const omegga = {
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
  };
  const adapter = new BmfMinigameEvents(
    omegga,
    {
      commandDir,
      allowUnsafeConsoleSnapshots: true,
      applySnapshotImports: true,
      emitSnapshotEvents: false,
      minigameCheckTimeoutMs: 2000,
    }
  );

  await adapter.minigameCheck('real-minigame-validation');

  const requestPath = await waitForRequest(commandDir);
  const command = fs.readFileSync(requestPath, 'utf8');
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

test('observed JoinTeam command writes BMF-compatible teamchange event log by default', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commandDir = path.join(root, 'commands');
  const player = {
    name: 'Ty',
    displayName: 'Ty',
    id: '33333333-3333-4333-8333-333333333333',
  };
  const adapter = new BmfMinigameEvents(
    {
      getPlayer(ref) {
        return ref === 'Ty' ? player : null;
      },
    },
    { commandDir }
  );

  adapter.playerMinigameCache.set(player.id, {
    name: 'Codex Arena',
    index: 0,
  });

  assert.strictEqual(adapter.handleJoinTeamCommand('Ty', 'Blue'), true);

  const records = readEventLogRecords(path.join(root, 'events.jsonl'));
  assert.strictEqual(records.length, 1);
  assert.strictEqual(records[0].source, 'event');
  assert.strictEqual(records[0].data.event, 'minigames.teamchange');
  assert.strictEqual(records[0].data.handlers, 0);
  assert.deepStrictEqual(records[0].data.errors, []);
  assert.strictEqual(records[0].data.ok, true);

  const payload = records[0].data.payload;
  assert.strictEqual(payload.source, 'omegga.bmf-minigame-events');
  assert.strictEqual(payload.reason, 'jointeam-command');
  assert.strictEqual(payload.player.id, player.id);
  assert.strictEqual(payload.minigame.name, 'Codex Arena');
  assert.strictEqual(payload.team.name, 'Blue');
  assert.strictEqual(payload._bmf.event, 'minigames.teamchange');
  assert.strictEqual(payload._bmf.legacyEvent, 'teamchange');
  assert.strictEqual(payload._bmf.minigameKey, 'name:Codex Arena#0');
  assert.strictEqual(payload._bmf.playerKey, player.id);
  assert.strictEqual(adapter.counters.lastEvent.transport, 'event-log');
  assert.strictEqual(adapter.counters.teamChanges, 1);
  assert.strictEqual(adapter.teamMembershipCache.get(player.id).team.name, 'Blue');
  assert.strictEqual(
    fs.existsSync(commandDir)
      ? fs.readdirSync(commandDir).filter(file => file.endsWith('.request.txt')).length
      : 0,
    0
  );

  assert.strictEqual(adapter.handleJoinTeamCommand('Ty', 'Blue'), false);
  assert.strictEqual(adapter.counters.teamChanges, 1);
});

test('command transport queues BMF teamchange event for Lua handlers', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-minigame-events-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  const commandDir = path.join(root, 'commands');
  const player = {
    name: 'Ty',
    displayName: 'Ty',
    id: '33333333-3333-4333-8333-333333333333',
  };
  const adapter = new BmfMinigameEvents(
    {
      getPlayer(ref) {
        return ref === 'Ty' ? player : null;
      },
    },
    { commandDir, eventTransport: 'command' }
  );

  adapter.playerMinigameCache.set(player.id, {
    name: 'Codex Arena',
    index: 0,
  });

  assert.strictEqual(adapter.handleJoinTeamCommand('Ty', 'Blue'), true);

  const requestPath = await waitForRequest(commandDir);
  const command = fs.readFileSync(requestPath, 'utf8');
  assert.match(command, /^bmf\.minigames\.events\.emit event=teamchange payload=/);

  const payload = JSON.parse(decodeURIComponent(command.match(/payload=([^ ]+)/)[1]));
  assert.strictEqual(payload.source, 'omegga.bmf-minigame-events');
  assert.strictEqual(payload.reason, 'jointeam-command');
  assert.strictEqual(payload.player.id, player.id);
  assert.strictEqual(payload.minigame.name, 'Codex Arena');
  assert.strictEqual(payload.team.name, 'Blue');
  assert.ok(payload._telemetry.adapterEventQueuedAtMs > 0);
  assert.strictEqual(adapter.counters.lastEvent.transport, 'command');
  assert.strictEqual(adapter.counters.teamChanges, 1);
  assert.strictEqual(adapter.teamMembershipCache.get(player.id).team.name, 'Blue');

  assert.strictEqual(adapter.handleJoinTeamCommand('Ty', 'Blue'), false);
  assert.strictEqual(
    fs.readdirSync(commandDir).filter(file => file.endsWith('.request.txt')).length,
    1
  );
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
