const assert = require("assert");
const { EventEmitter } = require("events");
const fs = require("fs");
const os = require("os");
const path = require("path");
const test = require("node:test");

const BmfPlayerSync = require("./omegga.plugin");

function tempRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bmf-player-sync-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function requestFiles(commandDir) {
  return fs.existsSync(commandDir)
    ? fs.readdirSync(commandDir).filter((file) => file.endsWith(".request.txt"))
    : [];
}

function testConfig(root, config = {}) {
  return {
    runtimeDir: root,
    brickadiaLogPath: path.join(root, "missing-brickadia.log"),
    ...config,
  };
}

function bridgeOmegga(commands, extras = {}) {
  return {
    ...extras,
    async getPlugin(name) {
      if (name !== "BMF Bridge" && name !== "bmf-bridge") return null;
      return {
        loaded: true,
        async emitPlugin(event, command, options) {
          commands.push({ event, command, options });
          return { ok: true, detail: "ok", transport: "socket" };
        },
      };
    },
  };
}

test("resyncs when Omegga publishes delayed raw player controller data", async (t) => {
  const root = tempRoot(t);
  const omegga = new EventEmitter();
  const adapter = new BmfPlayerSync(
    omegga,
    testConfig(root, { intervalMs: 0 }),
  );
  const reasons = [];
  adapter.scheduleSync = (reason) => reasons.push(reason);

  await adapter.init();
  omegga.emit("plugin:players:raw");

  assert.deepEqual(reasons, ["init", "raw-player-change"]);
  await adapter.stop();
  omegga.emit("plugin:players:raw");
  assert.deepEqual(reasons, ["init", "raw-player-change"]);
});

test("writes a BMF player cache from Omegga player records", async (t) => {
  const root = tempRoot(t);
  const commandDir = path.join(root, "commands");
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          [
            "Ty",
            "Ty Display",
            "33333333-3333-4333-8333-333333333333",
            "BP_PlayerController_C_1",
            "BP_PlayerState_C_1",
          ],
          ["MissingUuid", "MissingUuid", "", "", ""],
        ];
      },
    },
    testConfig(root),
  );

  await adapter.sync("unit-test");

  const cachePath = path.join(root, "players.json");
  assert.equal(fs.existsSync(cachePath), true);
  const cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));
  assert.equal(cache.schemaVersion, 1);
  assert.equal(cache.adapter, "omegga-cache");
  assert.equal(cache.source, "omegga.players.raw.unit-test");
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].playerName, "Ty");
  assert.equal(cache.players[0].uuid, "33333333-3333-4333-8333-333333333333");
  assert.deepEqual(requestFiles(commandDir), []);
});

test("tracks simultaneous reconnect generations by UUID instead of array order", () => {
  const adapter = new BmfPlayerSync({}, { connectionGeneration: true });
  const first = adapter.applyConnectionGenerations([
    {
      uuid: "11111111-1111-4111-8111-111111111111",
      controllerPath: "BP_PlayerController_C_10",
    },
    {
      uuid: "22222222-2222-4222-8222-222222222222",
      controllerPath: "BP_PlayerController_C_20",
    },
  ]);
  assert.deepEqual(
    first.map((record) => [record.uuid, record.connectionGeneration]),
    [
      ["11111111-1111-4111-8111-111111111111", 1],
      ["22222222-2222-4222-8222-222222222222", 1],
    ],
  );

  adapter.applyConnectionGenerations([]);
  const reconnected = adapter.applyConnectionGenerations([
    {
      uuid: "22222222-2222-4222-8222-222222222222",
      controllerPath: "BP_PlayerController_C_21",
    },
    {
      uuid: "11111111-1111-4111-8111-111111111111",
      controllerPath: "BP_PlayerController_C_11",
    },
  ]);
  assert.deepEqual(
    Object.fromEntries(
      reconnected.map((record) => [record.uuid, record.connectionGeneration]),
    ),
    {
      "11111111-1111-4111-8111-111111111111": 2,
      "22222222-2222-4222-8222-222222222222": 2,
    },
  );
});

test("uses current Brickadia interaction records for exact controller identity", async (t) => {
  const root = tempRoot(t);
  const logPath = path.join(root, "Brickadia.log");
  fs.writeFileSync(
    logPath,
    [
      "LogServerList: UserName: Ty",
      "LogServerList: DisplayName: Ty",
      "LogServerList: UserId: ff0f7114-85b9-46af-8ff1-85673e6ae0d6",
      "LogNet: Join succeeded: Ty",
      'LogBrickadia: Player "Ty" (ff0f7114-85b9-46af-8ff1-85673e6ae0d6, BP_FigureV2_C_2147473913, BP_PlayerController_C_2147473965) interacted with brick "1x Cube Micro-Brick" at -21 -20 1, message: "command:balance".',
    ].join("\n"),
    "utf8",
  );
  const adapter = new BmfPlayerSync(
    { getPlayers: () => [] },
    testConfig(root, { brickadiaLogPath: logPath }),
  );

  await adapter.sync("interaction-log-test");

  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].playerName, "Ty");
  assert.equal(
    cache.players[0].controllerPath,
    "BP_PlayerController_C_2147473965",
  );
  assert.equal(cache.players[0].pawnPath, "BP_FigureV2_C_2147473913");
});

test("clears stale interaction controller identity when the player reconnects", async (t) => {
  const root = tempRoot(t);
  const logPath = path.join(root, "Brickadia.log");
  fs.writeFileSync(
    logPath,
    [
      "LogServerList: UserName: Ty",
      "LogServerList: DisplayName: Ty",
      "LogServerList: UserId: ff0f7114-85b9-46af-8ff1-85673e6ae0d6",
      "LogNet: Join succeeded: Ty",
      'LogBrickadia: Player "Ty" (ff0f7114-85b9-46af-8ff1-85673e6ae0d6, BP_FigureV2_C_10, BP_PlayerController_C_20) interacted with brick "1x Cube Micro-Brick" at 0 0 0, message: "command:balance".',
      "LogServerList: Disconnected: Ty (ff0f7114-85b9-46af-8ff1-85673e6ae0d6)",
      "LogServerList: UserName: Ty",
      "LogServerList: DisplayName: Ty",
      "LogServerList: UserId: ff0f7114-85b9-46af-8ff1-85673e6ae0d6",
      "LogNet: Join succeeded: Ty",
    ].join("\n"),
    "utf8",
  );
  const adapter = new BmfPlayerSync(
    { getPlayers: () => [] },
    testConfig(root, { brickadiaLogPath: logPath }),
  );

  await adapter.sync("reconnect-log-test");

  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].controllerPath, "");
  assert.equal(cache.players[0].pawnPath, undefined);
});

test("writes Omegga bulk positions into the BMF player cache when enabled", async (t) => {
  const root = tempRoot(t);
  const uuid = "33333333-3333-4333-8333-333333333333";
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          [
            "Ty",
            "Ty Display",
            uuid,
            "BP_PlayerController_C_1",
            "BP_PlayerState_C_1",
          ],
        ];
      },
      async getAllPlayerPositions() {
        return [
          {
            player: {
              name: "Ty",
              displayName: "Ty Display",
              id: uuid,
              controller: "BP_PlayerController_C_1",
              state: "BP_PlayerState_C_1",
            },
            pawn: "BP_FigureV2_C_1",
            pos: [10, 20, 30],
            isDead: false,
          },
        ];
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("position-test");

  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].uuid, uuid);
  assert.deepEqual(cache.players[0].position, { x: 10, y: 20, z: 30 });
  assert.equal(cache.players[0].positionSource, "omegga.getAllPlayerPositions");
  assert.equal(cache.players[0].pawnPath, "BP_FigureV2_C_1");
  assert.equal(cache.players[0].isDead, false);

  const snapshot = JSON.parse(
    fs.readFileSync(path.join(root, "player-positions.json"), "utf8"),
  );
  assert.equal(snapshot.source, "omegga.bmf-player-sync");
  assert.equal(snapshot.players.length, 1);
  assert.equal(snapshot.players[0].ok, true);
  assert.equal(snapshot.players[0].player.id, uuid);
  assert.deepEqual(snapshot.players[0].position, { x: 10, y: 20, z: 30 });
});

test("writes multiple Omegga bulk positions with distinct player identities", async (t) => {
  const root = tempRoot(t);
  const latestoreId = "4d3eaaf4-458d-45b5-8482-38c7116fef8c";
  const tyId = "ff0f7114-85b9-46af-8ff1-85673e6ae0d6";
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          [
            "Latestore",
            "Latestore Display",
            latestoreId,
            "BP_PlayerController_C_1",
            "BP_PlayerState_C_1",
          ],
          [
            "Ty",
            "Ty Display",
            tyId,
            "BP_PlayerController_C_2",
            "BP_PlayerState_C_2",
          ],
        ];
      },
      async getAllPlayerPositions() {
        return [
          {
            player: {
              name: "Latestore",
              displayName: "Latestore Display",
              id: latestoreId,
              controller: "BP_PlayerController_C_1",
              state: "BP_PlayerState_C_1",
            },
            pawn: "BP_FigureV2_C_1",
            pos: [10, 20, 30],
          },
          {
            player: {
              name: "Ty",
              displayName: "Ty Display",
              id: tyId,
              controller: "BP_PlayerController_C_2",
              state: "BP_PlayerState_C_2",
            },
            pawn: "BP_FigureV2_C_2",
            pos: [40, 50, 60],
          },
        ];
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("multi-position-test");

  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players.length, 2);
  const positionById = new Map(
    cache.players.map((player) => [player.uuid, player.position]),
  );
  assert.deepEqual(positionById.get(latestoreId), { x: 10, y: 20, z: 30 });
  assert.deepEqual(positionById.get(tyId), { x: 40, y: 50, z: 60 });

  const snapshot = JSON.parse(
    fs.readFileSync(path.join(root, "player-positions.json"), "utf8"),
  );
  assert.equal(snapshot.players.length, 2);
  assert.equal(
    new Set(snapshot.players.map((record) => record.player.id)).size,
    2,
  );
  assert.equal(
    new Set(snapshot.players.map((record) => JSON.stringify(record.position)))
      .size,
    2,
  );
});

test("falls back to targeted control commands for positions when Omegga bulk positions are empty", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const uuid = "33333333-3333-4333-8333-333333333333";
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          [
            "Ty",
            "Ty Display",
            uuid,
            "BP_PlayerController_C_1",
            "BP_PlayerState_C_1",
          ],
        ];
      },
      async getAllPlayerPositions() {
        return [];
      },
      async execControlCommandWithOutput(command) {
        commands.push(command);
        if (
          command ===
          "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_1"
        ) {
          return [
            "0) BP_PlayerController_C /Game/Brickadia/Maps/Plate/Plate.Plate:PersistentLevel.BP_PlayerController_C_1.Pawn = BP_FigureV2_C'/Game/Brickadia/Maps/Plate/Plate.Plate:PersistentLevel.BP_FigureV2_C_7'",
          ].join("\n");
        }
        if (
          command ===
          "GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=BP_FigureV2_C_7"
        ) {
          return [
            "0) CapsuleComponent /Game/Brickadia/Maps/Plate/Plate.Plate:PersistentLevel.BP_FigureV2_C_7.CollisionCylinder.RelativeLocation = (X=101.500,Y=-202.250,Z=303.750)",
          ].join("\n");
        }
        throw new Error(`unexpected command ${command}`);
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("control-position-test");

  assert.deepEqual(commands, [
    "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_1",
    "GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=BP_FigureV2_C_7",
  ]);
  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].uuid, uuid);
  assert.deepEqual(cache.players[0].position, {
    x: 101.5,
    y: -202.25,
    z: 303.75,
  });
  assert.equal(
    cache.players[0].positionSource,
    "omegga.execControlCommandWithOutput",
  );
  assert.equal(cache.players[0].pawnPath, "BP_FigureV2_C_7");

  const snapshot = JSON.parse(
    fs.readFileSync(path.join(root, "player-positions.json"), "utf8"),
  );
  assert.equal(snapshot.players.length, 1);
  assert.equal(snapshot.players[0].ok, true);
  assert.equal(snapshot.players[0].player.id, uuid);
  assert.deepEqual(snapshot.players[0].position, {
    x: 101.5,
    y: -202.25,
    z: 303.75,
  });

  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.equal(status.position.method, "omegga.execControlCommandWithOutput");
  assert.equal(
    status.position.fallbackFrom.method,
    "omegga.getAllPlayerPositions",
  );
  assert.equal(status.positionSnapshot.written, true);
});

test("uses BMF snapshot controller hints when Omegga player records have no controller", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const uuid = "33333333-3333-4333-8333-333333333333";
  fs.writeFileSync(
    path.join(root, "player-positions.json"),
    JSON.stringify({
      source: "bmf.players.positions",
      players: [
        {
          ok: false,
          controllerFullName:
            "BP_PlayerController_C /Game/Maps/Plate/Plate.Plate:PersistentLevel.BP_PlayerController_C_2147476489",
          player: {
            id: uuid,
            uuid,
            name: "Ty",
            displayName: "Ty Display",
          },
        },
      ],
    }),
    "utf8",
  );
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [["Ty", "Ty Display", uuid, "", "BP_PlayerState_C_1"]];
      },
      async getAllPlayerPositions() {
        return [];
      },
      async execControlCommandWithOutput(command) {
        commands.push(command);
        if (
          command ===
          "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_2147476489"
        ) {
          return [
            "0) BP_PlayerController_C /Game/Maps/Plate/Plate.Plate:PersistentLevel.BP_PlayerController_C_2147476489.Pawn = BP_FigureV2_C'/Game/Maps/Plate/Plate.Plate:PersistentLevel.BP_FigureV2_C_9'",
          ].join("\n");
        }
        if (
          command ===
          "GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=BP_FigureV2_C_9"
        ) {
          return [
            "0) CapsuleComponent /Game/Maps/Plate/Plate.Plate:PersistentLevel.BP_FigureV2_C_9.CollisionCylinder.RelativeLocation = (X=11.000,Y=22.000,Z=33.000)",
          ].join("\n");
        }
        throw new Error(`unexpected command ${command}`);
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("controller-hint-test");

  assert.deepEqual(commands, [
    "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_2147476489",
    "GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=BP_FigureV2_C_9",
  ]);
  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(
    cache.players[0].controllerPath,
    "BP_PlayerController_C_2147476489",
  );
  assert.deepEqual(cache.players[0].position, { x: 11, y: 22, z: 33 });
  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.ok(status.position.controllerHints >= 3);
  assert.equal(status.position.hinted, 1);
});

test("falls back to BMF player-position snapshot when Omegga position probes are empty", async (t) => {
  const root = tempRoot(t);
  const uuid = "33333333-3333-4333-8333-333333333333";
  fs.writeFileSync(
    path.join(root, "player-positions.json"),
    JSON.stringify({
      source: "bmf.players.positions",
      snapshot: {
        generatedAt: "2026-07-04T19:05:45Z",
        intervalMs: 2000,
      },
      players: [
        {
          ok: true,
          player: {
            id: uuid,
            uuid,
            name: "Ty",
            displayName: "Ty Display",
          },
          position: { x: 100, y: 2, z: 10 },
          source: "native.BMFSocketPlayerLocation.fast-cache.pawnAddress",
          pawnPath: "BP_PlayerController_C_2147476489",
        },
      ],
    }),
    "utf8",
  );
  const commands = [];
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          ["Ty", "Ty Display", uuid, "BP_PlayerController_C_2147476489", ""],
        ];
      },
      async getAllPlayerPositions() {
        return [];
      },
      async execControlCommandWithOutput(command) {
        commands.push(command);
        return "";
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("snapshot-fallback-test");

  assert.deepEqual(commands, [
    "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_2147476489",
    "Omegga.Bridge.DescribePlayerLocation Ty",
  ]);
  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players[0].uuid, uuid);
  assert.deepEqual(cache.players[0].position, { x: 100, y: 2, z: 10 });
  assert.equal(
    cache.players[0].positionSource,
    "native.BMFSocketPlayerLocation.fast-cache.pawnAddress",
  );

  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.equal(status.position.method, "bmf.player-position-snapshot");
  assert.equal(status.position.normalizedCount, 1);
  assert.equal(
    status.position.fallbackFrom.targeted.method,
    "omegga.execControlCommandWithOutput",
  );
  assert.equal(status.positionSnapshot.written, false);
  assert.equal(status.positionSnapshot.reason, "bmf-snapshot-source");
});

test("uses only current identified players from BMF all-player position snapshots", async (t) => {
  const root = tempRoot(t);
  const latestoreId = "4d3eaaf4-458d-45b5-8482-38c7116fef8c";
  const staleTyId = "ff0f7114-85b9-46af-8ff1-85673e6ae0d6";
  fs.writeFileSync(
    path.join(root, "player-positions.json"),
    JSON.stringify({
      source: "bmf.players.positions",
      snapshot: {
        generatedAt: "2026-07-04T19:05:45Z",
        intervalMs: 2000,
      },
      players: [
        {
          ok: true,
          player: {
            id: latestoreId,
            uuid: latestoreId,
            name: "Latestore",
            displayName: "Latestore Display",
          },
          position: { x: 37182.114, y: 44355.323, z: 370.262 },
          source: "native.BMFSocketPlayerLocation.controller",
          controllerPath: "BP_PlayerController_C_2147476489",
          pawnPath: "BP_FigureV2_C_2147476467",
        },
        {
          ok: true,
          player: {
            id: staleTyId,
            uuid: staleTyId,
            name: "Ty",
            displayName: "Ty Display",
          },
          position: { x: 999, y: 999, z: 999 },
          source: "cache.position",
        },
        {
          ok: true,
          player: {},
          position: { x: 36811.959, y: 44825.046, z: 394.404 },
          source: "native.BMFSocketPlayerLocation.controller",
        },
      ],
    }),
    "utf8",
  );
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          [
            "Latestore",
            "Latestore Display",
            latestoreId,
            "BP_PlayerController_C_2147476489",
            "",
          ],
        ];
      },
      async getAllPlayerPositions() {
        return [];
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("snapshot-all-player-test");

  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players.length, 1);
  assert.equal(cache.players[0].uuid, latestoreId);
  assert.equal(cache.players[0].playerName, "Latestore");
  assert.deepEqual(cache.players[0].position, {
    x: 37182.114,
    y: 44355.323,
    z: 370.262,
  });
  assert.equal(
    cache.players.some((player) => player.uuid === staleTyId),
    false,
  );

  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.equal(status.position.method, "bmf.player-position-snapshot");
  assert.equal(status.position.rawCount, 3);
  assert.equal(status.position.normalizedCount, 1);
  assert.equal(status.positionSnapshot.written, false);
  assert.equal(status.positionSnapshot.reason, "bmf-snapshot-source");
});

test("uses OmeggaBridge DescribePlayerLocation when pawn lookup is empty", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const uuid = "33333333-3333-4333-8333-333333333333";
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [
          ["Ty", "Ty", uuid, "BP_PlayerController_C_1", "BP_PlayerState_C_1"],
        ];
      },
      async getAllPlayerPositions() {
        return [];
      },
      async execControlCommandWithOutput(command) {
        commands.push(command);
        if (
          command ===
          "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_1"
        ) {
          return "";
        }
        if (command === "Omegga.Bridge.DescribePlayerLocation Ty") {
          return [
            "Player location",
            "requested_name=Ty",
            "ok=true",
            "source=live_controller.1.controller.RelativeLocation",
            "x=111.25",
            "y=-222.5",
            "z=333.75",
          ].join("\n");
        }
        throw new Error(`unexpected command ${command}`);
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("describe-location-test");

  assert.deepEqual(commands, [
    "GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_1",
    "Omegga.Bridge.DescribePlayerLocation Ty",
  ]);
  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.deepEqual(cache.players[0].position, {
    x: 111.25,
    y: -222.5,
    z: 333.75,
  });
  assert.match(
    cache.players[0].positionSource,
    /^omegga\.bridge\.describe-player-location\./,
  );

  const snapshot = JSON.parse(
    fs.readFileSync(path.join(root, "player-positions.json"), "utf8"),
  );
  assert.deepEqual(snapshot.players[0].position, {
    x: 111.25,
    y: -222.5,
    z: 333.75,
  });
  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.equal(status.position.described, 1);
  assert.equal(status.position.describeResolved, 1);
});

test("uses OmeggaBridge DescribePlayerLocation when controller path is missing", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const uuid = "33333333-3333-4333-8333-333333333333";
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [["Ty", "Ty", uuid, "", ""]];
      },
      async getAllPlayerPositions() {
        return [];
      },
      async execControlCommandWithOutput(command) {
        commands.push(command);
        if (command === "Omegga.Bridge.DescribePlayerLocation Ty") {
          return [
            "Player location",
            "requested_name=Ty",
            "ok=true",
            "source=native.live-controller",
            "x=11",
            "y=22",
            "z=33",
          ].join("\n");
        }
        throw new Error(`unexpected command ${command}`);
      },
    },
    testConfig(root, {
      includePositions: true,
    }),
  );

  await adapter.sync("describe-location-no-controller-test");

  assert.deepEqual(commands, ["Omegga.Bridge.DescribePlayerLocation Ty"]);
  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.deepEqual(cache.players[0].position, { x: 11, y: 22, z: 33 });

  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.equal(status.position.attempted, 1);
  assert.equal(status.position.described, 1);
  assert.equal(status.position.describeResolved, 1);
});

test("derives runtimeDir from legacy commandDir config", async (t) => {
  const root = tempRoot(t);
  const adapter = new BmfPlayerSync(
    {
      getPlayers() {
        return [["Ty", "Ty", "33333333-3333-4333-8333-333333333333", "", ""]];
      },
    },
    testConfig(root, {
      runtimeDir: undefined,
      commandDir: path.join(root, "commands"),
    }),
  );

  await adapter.sync("legacy-command-dir");

  assert.equal(fs.existsSync(path.join(root, "players.json")), true);
});

test("skips unchanged BMF player cache writes", async (t) => {
  const root = tempRoot(t);
  const cachePath = path.join(root, "players.json");
  const player = [
    "Ty",
    "Ty Display",
    "33333333-3333-4333-8333-333333333333",
    "BP_PlayerController_C_1",
    "BP_PlayerState_C_1",
  ];
  const other = [
    "Other",
    "Other Display",
    "44444444-4444-4444-8444-444444444444",
    "BP_PlayerController_C_2",
    "BP_PlayerState_C_2",
  ];
  const players = [player, other];
  const adapter = new BmfPlayerSync({}, testConfig(root));

  assert.equal(adapter.writePlayerCache(players, "unit-test"), true);
  const first = fs.readFileSync(cachePath, "utf8");

  assert.equal(
    adapter.writePlayerCache([...players].reverse(), "interval"),
    false,
  );
  assert.equal(fs.readFileSync(cachePath, "utf8"), first);

  const restartedAdapter = new BmfPlayerSync({}, testConfig(root));
  assert.equal(
    restartedAdapter.writePlayerCache(
      [...players].reverse(),
      "interval-after-restart",
    ),
    false,
  );
  assert.equal(fs.readFileSync(cachePath, "utf8"), first);

  fs.unlinkSync(cachePath);
  assert.equal(
    adapter.writePlayerCache(players, "interval-after-external-delete"),
    true,
  );
  assert.equal(fs.existsSync(cachePath), true);
});

test("sends bmf.players.sync over the BMF bridge socket when command bridge mode is enabled", async (t) => {
  const root = tempRoot(t);
  const commandDir = path.join(root, "commands");
  const commands = [];
  const uuid = "33333333-3333-4333-8333-333333333333";
  const adapter = new BmfPlayerSync(
    bridgeOmegga(commands, {
      players: [
        {
          name: "Ty",
          displayName: "Ty",
          id: uuid,
          controller: "BP_PlayerController_C_1",
          state: "BP_PlayerState_C_1",
        },
      ],
      async getAllPlayerPositions() {
        return [
          {
            player: {
              name: "Ty",
              displayName: "Ty",
              id: uuid,
              controller: "BP_PlayerController_C_1",
              state: "BP_PlayerState_C_1",
            },
            pawn: "BP_FigureV2_C_1",
            pos: [1, 2, 3],
            isDead: false,
          },
        ];
      },
    }),
    testConfig(root, {
      commandBridge: true,
      includePositions: true,
    }),
  );

  await adapter.sync("bridge-test");

  assert.equal(requestFiles(commandDir).length, 0);
  assert.equal(commands.length, 1);
  const command = commands[0].command;
  assert.match(
    command,
    /^bmf\.players\.sync adapter=omegga-cache source=omegga\.players\.raw\.bridge-test persist=false players=/,
  );
  const records = JSON.parse(command.match(/players=(.*)$/)[1]);
  assert.deepEqual(records[0].position, { x: 1, y: 2, z: 3 });
  assert.equal(records[0].pawnPath, undefined);
  assert.equal(records[0].playerName, undefined);
  assert.equal(records[0].id, undefined);
  assert.equal(commands[0].event, "invokeCommand");
  assert.equal(commands[0].options.source, "omegga.bmf-player-sync");
  assert.equal(commands[0].options.serviceClass, "bulk");
  assert.equal(fs.existsSync(path.join(root, "players.json")), true);
  const cache = JSON.parse(
    fs.readFileSync(path.join(root, "players.json"), "utf8"),
  );
  assert.equal(cache.players[0].uuid, uuid);
  assert.equal(cache.players[0].pawnPath, "BP_FigureV2_C_1");
});

test("publishes a bounded worst-case 30-player roster without the legacy 16 KiB rejection", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const longControllerPrefix =
    "BP_PlayerController_C'/Game/Maps/CityRPG/" +
    "ControllerSegment".repeat(15);
  const longStatePrefix =
    "BP_PlayerState_C'/Game/Maps/CityRPG/" + "PlayerStateSegment".repeat(15);
  const players = Array.from({ length: 30 }, (_, index) => ({
    name: `Player_${String(index).padStart(2, "0")}_${"N".repeat(20)}`,
    displayName: `Display_${String(index).padStart(2, "0")}_${"D".repeat(40)}`,
    id: `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    controller: `${longControllerPrefix}:PersistentLevel.BP_PlayerController_C_${index}'`,
    state: `${longStatePrefix}:PersistentLevel.BP_PlayerState_C_${index}'`,
  }));
  const adapter = new BmfPlayerSync(
    bridgeOmegga(commands, { players }),
    testConfig(root, { commandBridge: true, maxCommandBytes: 64 * 1024 }),
  );

  await adapter.sync("max-roster");

  assert.equal(commands.length, 1);
  const commandBytes = Buffer.byteLength(commands[0].command, "utf8");
  assert.ok(commandBytes > 16 * 1024);
  assert.ok(commandBytes <= 64 * 1024);
});

test("preflights an oversized player snapshot without retrying the BMF queue", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const adapter = new BmfPlayerSync(
    bridgeOmegga(commands, {
      players: [
        {
          name: "Oversized",
          id: "33333333-3333-4333-8333-333333333333",
          controller: `BP_PlayerController_C_${"x".repeat(2048)}`,
        },
      ],
    }),
    testConfig(root, { commandBridge: true, maxCommandBytes: 1024 }),
  );

  await adapter.sync("oversized");
  await adapter.sync("oversized-retry");

  assert.equal(commands.length, 0);
  assert.notEqual(adapter.lastRejectedPlayerCommandSignature, "");
  assert.equal(adapter.syncCounters.socketOversizedRejected, 2);
});

test("does not republish an unchanged player snapshot to the BMF socket", async (t) => {
  const root = tempRoot(t);
  const commands = [];
  const players = [
    ["Ty", "Ty", "33333333-3333-4333-8333-333333333333", "", ""],
    ["Other", "Other", "44444444-4444-4444-8444-444444444444", "", ""],
  ];
  const omegga = bridgeOmegga(commands, { players });
  const adapter = new BmfPlayerSync(
    omegga,
    testConfig(root, { commandBridge: true }),
  );

  await adapter.sync("first");
  omegga.players = [...players].reverse();
  await adapter.sync("unchanged-interval");

  assert.equal(commands.length, 1);
  assert.equal(adapter.syncCounters.socketUnchangedSuppressed, 1);
  const status = JSON.parse(
    fs.readFileSync(path.join(root, "bmf-player-sync-status.json"), "utf8"),
  );
  assert.equal(status.syncCounters.socketUnchangedSuppressed, 1);
});

test("coalesces overlapping syncs into the newest pending snapshot", async (t) => {
  const root = tempRoot(t);
  const adapter = new BmfPlayerSync({}, testConfig(root));
  const reasons = [];
  let releaseFirst;
  const firstGate = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  adapter.performSync = async (reason) => {
    reasons.push(reason);
    if (reasons.length === 1) await firstGate;
  };

  const first = adapter.sync("first");
  await new Promise((resolve) => setImmediate(resolve));
  const superseded = adapter.sync("superseded");
  const newest = adapter.sync("newest");
  releaseFirst();
  await Promise.all([first, superseded, newest]);

  assert.deepEqual(reasons, ["first", "newest"]);
  assert.equal(adapter.syncCounters.triggersCoalesced, 2);
});

test("bounds one sync chain to two passes and reschedules later churn", async (t) => {
  const root = tempRoot(t);
  const adapter = new BmfPlayerSync(
    {},
    testConfig(root, { syncDelayMs: 60_000 }),
  );
  const reasons = [];
  adapter.performSync = async (reason) => {
    reasons.push(reason);
    if (reason === "first") adapter.pendingSyncReason = "second";
    if (reason === "second") adapter.pendingSyncReason = "third";
  };

  await adapter.sync("first");

  assert.deepEqual(reasons, ["first", "second"]);
  assert.ok(adapter.timer);
  assert.equal(adapter.syncCounters.followUpsRescheduled, 1);
  clearTimeout(adapter.timer);
  adapter.timer = null;
});

test("forwards interact events as percent-encoded BMF socket commands when explicitly enabled", async (t) => {
  const root = tempRoot(t);
  const commandDir = path.join(root, "commands");
  const commands = [];
  const adapter = new BmfPlayerSync(
    bridgeOmegga(commands),
    testConfig(root, {
      forwardInteract: true,
    }),
  );

  adapter.handleInteract({
    player: {
      id: "33333333-3333-4333-8333-333333333333",
      name: "Ty Cox",
      controller: "BP_PlayerController_C_1",
    },
    message: "cityrpg:bank vault",
    brick_name: "Console Brick",
    brick_asset: "B_1x1_Brick",
    position: [1, 2, 3],
  });

  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(requestFiles(commandDir).length, 0);
  assert.equal(commands.length, 1);
  const command = commands[0].command;
  assert.match(command, /^bmf\.interact\.console source=omegga\.interact /);
  assert.match(command, /player=33333333-3333-4333-8333-333333333333/);
  assert.match(command, /name=Ty%20Cox/);
  assert.match(command, /message=cityrpg%3Abank%20vault/);
  assert.match(command, /brick=Console%20Brick/);
});
