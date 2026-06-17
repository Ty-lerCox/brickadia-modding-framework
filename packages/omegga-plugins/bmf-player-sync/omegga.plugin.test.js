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

test('writes a BMF player cache from Omegga player records', t => {
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
    { commandDir }
  );

  adapter.sync('unit-test');

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

test('queues bmf.players.sync when command bridge mode is enabled', t => {
  const root = tempRoot(t);
  const commandDir = path.join(root, 'commands');
  const adapter = new BmfPlayerSync(
    {
      players: [
        {
          name: 'Ty',
          displayName: 'Ty',
          id: '33333333-3333-4333-8333-333333333333',
          controller: 'BP_PlayerController_C_1',
          state: 'BP_PlayerState_C_1',
        },
      ],
    },
    {
      commandDir,
      commandBridge: true,
    }
  );

  adapter.sync('bridge-test');

  const files = requestFiles(commandDir);
  assert.equal(files.length, 1);
  const command = fs.readFileSync(path.join(commandDir, files[0]), 'utf8');
  assert.match(command, /^bmf\.players\.sync adapter=omegga-cache source=omegga\.players\.raw\.bridge-test players=/);
  assert.equal(fs.existsSync(path.join(root, 'players.json')), false);
});

test('forwards interact events as percent-encoded BMF command requests when explicitly enabled', t => {
  const root = tempRoot(t);
  const commandDir = path.join(root, 'commands');
  const adapter = new BmfPlayerSync(
    {},
    {
      commandDir,
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

  const files = requestFiles(commandDir);
  assert.equal(files.length, 1);
  const command = fs.readFileSync(path.join(commandDir, files[0]), 'utf8');
  assert.match(command, /^bmf\.interact\.console source=omegga\.interact /);
  assert.match(command, /player=33333333-3333-4333-8333-333333333333/);
  assert.match(command, /name=Ty%20Cox/);
  assert.match(command, /message=cityrpg%3Abank%20vault/);
  assert.match(command, /brick=Console%20Brick/);
});
