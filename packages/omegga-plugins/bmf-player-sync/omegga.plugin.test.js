const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const BmfPlayerSync = require('./omegga.plugin');

function tempRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-player-sync-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function requestFiles(commandDir) {
  return fs.existsSync(commandDir)
    ? fs.readdirSync(commandDir).filter(file => file.endsWith('.request.txt'))
    : [];
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
          return { ok: true, detail: 'ok', transport: 'socket' };
        },
      };
    },
  };
}

test('writes a BMF player cache from Omegga player records', async t => {
  const root = tempRoot(t);
  const commandDir = path.join(root, 'commands');
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          ['Ty', 'Ty Display', '33333333-3333-4333-8333-333333333333', 'BP_PlayerController_C_1', 'BP_PlayerState_C_1'],
          ['MissingUuid', 'MissingUuid', '', '', ''],
        ];
      },
    },
    { runtimeDir: root }
  );

  await adapter.sync('unit-test');

  const cachePath = path.join(root, 'players.json');
  assert.equal(fs.existsSync(cachePath), true);
  const cache = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
  assert.equal(cache.schemaVersion, 1);
  assert.equal(cache.adapter, 'omegga-cache');
  assert.equal(cache.source, 'omegga.players.raw.unit-test');
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].playerName, 'Ty');
  assert.equal(cache.players[0].uuid, '33333333-3333-4333-8333-333333333333');
  assert.deepEqual(requestFiles(commandDir), []);
});

test('skips unchanged BMF player cache writes', async t => {
  const root = tempRoot(t);
  const cachePath = path.join(root, 'players.json');
  const player = ['Ty', 'Ty Display', '33333333-3333-4333-8333-333333333333', 'BP_PlayerController_C_1', 'BP_PlayerState_C_1'];
  const adapter = new BmfPlayerSync({}, { runtimeDir: root });

  assert.equal(adapter.writePlayerCache([player], 'unit-test'), true);
  const first = fs.readFileSync(cachePath, 'utf8');

  assert.equal(adapter.writePlayerCache([player], 'interval'), false);
  assert.equal(fs.readFileSync(cachePath, 'utf8'), first);

  const restartedAdapter = new BmfPlayerSync({}, { runtimeDir: root });
  assert.equal(restartedAdapter.writePlayerCache([player], 'interval-after-restart'), false);
  assert.equal(fs.readFileSync(cachePath, 'utf8'), first);
});

test('sends bmf.players.sync over the BMF bridge socket when command bridge mode is enabled', async t => {
  const root = tempRoot(t);
  const commandDir = path.join(root, 'commands');
  const commands = [];
  const adapter = new BmfPlayerSync(
    bridgeOmegga(commands, {
      players: [
        {
          name: 'Ty',
          displayName: 'Ty',
          id: '33333333-3333-4333-8333-333333333333',
          controller: 'BP_PlayerController_C_1',
          state: 'BP_PlayerState_C_1',
        },
      ],
    }),
    {
      runtimeDir: root,
      commandBridge: true,
    }
  );

  await adapter.sync('bridge-test');

  assert.equal(requestFiles(commandDir).length, 0);
  assert.equal(commands.length, 1);
  const command = commands[0].command;
  assert.match(command, /^bmf\.players\.sync adapter=omegga-cache source=omegga\.players\.raw\.bridge-test players=/);
  assert.equal(commands[0].event, 'invokeCommand');
  assert.equal(commands[0].options.source, 'omegga.bmf-player-sync');
  assert.equal(fs.existsSync(path.join(root, 'players.json')), false);
});

test('forwards interact events as percent-encoded BMF socket commands when explicitly enabled', async t => {
  const root = tempRoot(t);
  const commandDir = path.join(root, 'commands');
  const commands = [];
  const adapter = new BmfPlayerSync(
    bridgeOmegga(commands),
    {
      runtimeDir: root,
      forwardInteract: true,
    }
  );

  adapter.handleInteract({
    player: {
      id: '33333333-3333-4333-8333-333333333333',
      name: 'Ty Cox',
      controller: 'BP_PlayerController_C_1',
    },
    message: 'cityrpg:bank vault',
    brick_name: 'Console Brick',
    brick_asset: 'B_1x1_Brick',
    position: [1, 2, 3],
  });

  await new Promise(resolve => setImmediate(resolve));

  assert.equal(requestFiles(commandDir).length, 0);
  assert.equal(commands.length, 1);
  const command = commands[0].command;
  assert.match(command, /^bmf\.interact\.console source=omegga\.interact /);
  assert.match(command, /player=33333333-3333-4333-8333-333333333333/);
  assert.match(command, /name=Ty%20Cox/);
  assert.match(command, /message=cityrpg%3Abank%20vault/);
  assert.match(command, /brick=Console%20Brick/);
});
