const fs = require("fs");
const path = require("path");

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

let localEnvCache = null;

function readLocalEnv() {
  const values = new Map();
  if (typeof process === "undefined" || typeof process.cwd !== "function") {
    return values;
  }
  const envPath = path.join(process.cwd(), ".env");
  try {
    const text = fs.readFileSync(envPath, "utf8");
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const separator = trimmed.indexOf("=");
      if (separator <= 0) continue;
      const key = trimmed.slice(0, separator).trim();
      const value = trimmed
        .slice(separator + 1)
        .trim()
        .replace(/^['"]|['"]$/g, "");
      if (key) values.set(key, value);
    }
  } catch (_error) {}
  return values;
}

function envValue(name) {
  const env =
    typeof process !== "undefined" &&
    process.env &&
    typeof process.env === "object"
      ? process.env
      : {};
  const value = String(env[name] ?? "").trim();
  if (value) return value;
  localEnvCache = localEnvCache || readLocalEnv();
  return localEnvCache.get(name);
}

function envFlag(name) {
  const value = envValue(name);
  if (value == null || String(value).trim() === "") return null;
  return /^(1|true|yes|on)$/i.test(String(value).trim());
}

function runtimeProvenance(writer) {
  let identity = {};
  const identityPath = envValue("BMF_PROVENANCE_IDENTITY_PATH");
  try {
    identity = JSON.parse(fs.readFileSync(identityPath, "utf8"));
  } catch (_error) {}
  return {
    environment: String(identity.environment || "unverified"),
    brickadiaPid: asNumber(identity.brickadiaPid, 0),
    omeggaPid: asNumber(identity.omeggaPid, process.pid),
    processStartTimestamp: asNumber(identity.processStartTimestamp, 0),
    brickadiaStartTimestamp: asNumber(identity.brickadiaStartTimestamp, 0),
    omeggaStartTimestamp: asNumber(identity.omeggaStartTimestamp, 0),
    udpPort: asNumber(identity.udpPort, 0),
    installationRoot: String(identity.installationRoot || ""),
    runtimeRoot: String(identity.runtimeRoot || ""),
    runtimeHash: String(identity.runtimeHash || ""),
    telemetryWriterIdentity: String(writer || "bmf.omegga.unknown"),
    telemetryGenerationTimestamp: Date.now(),
  };
}

function commandValue(value) {
  return encodeURIComponent(String(value ?? ""));
}

function normalizePosition(value) {
  if (!value) return null;

  let x;
  let y;
  let z;
  if (Array.isArray(value)) {
    [x, y, z] = value;
  } else if (typeof value === "object") {
    x = value.x ?? value.X ?? value[0];
    y = value.y ?? value.Y ?? value[1];
    z = value.z ?? value.Z ?? value[2];
  }

  const position = {
    x: Number(x),
    y: Number(y),
    z: Number(z),
  };
  return Number.isFinite(position.x) &&
    Number.isFinite(position.y) &&
    Number.isFinite(position.z)
    ? position
    : null;
}

function copyPlayerMetadata(target, source, positionSource) {
  if (!target || !source || typeof source !== "object") return target;

  const position = normalizePosition(
    source.position ?? source.pos ?? source.location,
  );
  if (position) {
    target.position = position;
    target.positionSource = String(
      positionSource ||
        source.positionSource ||
        source.source ||
        "omegga.player-cache",
    );
  }

  const pawn = source.pawnPath ?? source.pawnAddress ?? source.pawn;
  if (pawn != null && String(pawn).trim()) target.pawnPath = String(pawn);

  const root =
    source.rootComponentPath ??
    source.rootComponentAddress ??
    source.rootComponent;
  if (root != null && String(root).trim())
    target.rootComponentPath = String(root);

  if (typeof source.isDead === "boolean") target.isDead = source.isDead;
  const connectionGeneration = Number(source.connectionGeneration);
  if (Number.isSafeInteger(connectionGeneration) && connectionGeneration > 0) {
    target.connectionGeneration = connectionGeneration;
  }
  return target;
}

function normalizePlayer(player) {
  if (Array.isArray(player)) {
    return copyPlayerMetadata(
      [
        String(player[0] || ""),
        String(player[1] || player[0] || ""),
        String(player[2] || ""),
        String(player[3] || ""),
        String(player[4] || ""),
      ],
      player,
    );
  }

  if (player && typeof player.raw === "function") {
    return normalizePlayer(player.raw());
  }

  return copyPlayerMetadata(
    [
      String(player?.name || ""),
      String(player?.displayName || player?.name || ""),
      String(player?.id || ""),
      String(player?.controller || ""),
      String(player?.state || ""),
    ],
    player,
  );
}

function compactPlayers(players) {
  return (players || [])
    .map(normalizePlayer)
    .filter((player) => player[0] && player[2]);
}

function normalizePositionPlayer(record) {
  if (!record || typeof record !== "object") return null;
  const player = normalizePlayer(record.player || record);
  copyPlayerMetadata(player, record, "omegga.getAllPlayerPositions");
  return player.position && player[0] && player[2] ? player : null;
}

function controllerName(value) {
  const match = String(value || "").match(/\b(BP_PlayerController_C_\d+)\b/);
  return match ? match[1] : "";
}

function parsePawnOutput(output) {
  const text = String(output || "");
  const match = text.match(
    /\.Pawn\s*=\s*(?:BP_FigureV2_C'.*?:PersistentLevel\.)?(BP_FigureV2_C_\d+|None)'?/,
  );
  if (!match || match[1] === "None") return "";
  return match[1];
}

function parsePositionOutput(output) {
  const match = String(output || "").match(
    /CollisionCylinder\.RelativeLocation\s*=\s*\(X=([\d.-]+),Y=([\d.-]+),Z=([\d.-]+)\)/,
  );
  if (!match) return null;
  return normalizePosition([match[1], match[2], match[3]]);
}

function parseKeyValueOutput(output) {
  const values = new Map();
  for (const line of String(output || "").split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z0-9_.-]+)=(.*)$/);
    if (match) values.set(match[1], match[2]);
  }
  return values;
}

function parseDescribePlayerLocationOutput(output) {
  const values = parseKeyValueOutput(output);
  if (
    String(values.get("ok") || "")
      .trim()
      .toLowerCase() !== "true"
  )
    return null;
  const position = normalizePosition([
    values.get("x"),
    values.get("y"),
    values.get("z"),
  ]);
  if (!position) return null;
  return {
    position,
    source: String(
      values.get("source") || "Omegga.Bridge.DescribePlayerLocation",
    ),
  };
}

function describePlayerLocationSpec(player) {
  return String(player?.[0] || player?.[1] || player?.[2] || "")
    .replace(/[\r\n]/g, " ")
    .trim();
}

function playerMergeKeys(player) {
  return [player?.[2], player?.[0], player?.[1], player?.[3], player?.[4]]
    .map((value) =>
      String(value || "")
        .trim()
        .toLowerCase(),
    )
    .filter(Boolean);
}

function playerIdentityKeys(player) {
  return [player?.[2], player?.[0], player?.[1]]
    .map((value) =>
      String(value || "")
        .trim()
        .toLowerCase(),
    )
    .filter(Boolean);
}

function mergePlayerMetadata(target, source) {
  if (!target || !source) return target;
  for (let index = 0; index < 5; index += 1) {
    if (!target[index] && source[index]) target[index] = source[index];
  }
  if (source.position) {
    target.position = source.position;
    target.positionSource = source.positionSource || "omegga.player-cache";
  }
  if (source.pawnPath) target.pawnPath = source.pawnPath;
  if (source.rootComponentPath)
    target.rootComponentPath = source.rootComponentPath;
  if (typeof source.isDead === "boolean") target.isDead = source.isDead;
  const connectionGeneration = Number(source.connectionGeneration);
  if (Number.isSafeInteger(connectionGeneration) && connectionGeneration > 0) {
    target.connectionGeneration = connectionGeneration;
  }
  return target;
}

function mergePlayers(...groups) {
  const players = [];
  const byKey = new Map();

  for (const group of groups) {
    for (const raw of group || []) {
      const player = normalizePlayer(raw);
      if (!player[0] || !player[2]) continue;

      const keys = playerMergeKeys(player);
      let existing = null;
      for (const key of keys) {
        if (byKey.has(key)) {
          existing = byKey.get(key);
          break;
        }
      }

      if (!existing) {
        existing = player;
        players.push(existing);
      } else {
        mergePlayerMetadata(existing, player);
      }

      for (const key of playerMergeKeys(existing)) byKey.set(key, existing);
    }
  }

  return players;
}

function cachePlayerRecord(player) {
  const record = {
    username: String(player[0] || ""),
    playerName: String(player[0] || ""),
    originalName: String(player[0] || ""),
    displayName: String(player[1] || player[0] || ""),
    id: String(player[2] || ""),
    uuid: String(player[2] || ""),
    controllerPath: String(player[3] || ""),
    playerStatePath: String(player[4] || ""),
    controllerAvailable: String(player[3] || "").trim() !== "",
    permissions: [],
    roles: [],
  };

  if (
    Number.isSafeInteger(Number(player.connectionGeneration)) &&
    Number(player.connectionGeneration) > 0
  ) {
    record.connectionGeneration = Number(player.connectionGeneration);
  }

  if (player.position) {
    record.position = player.position;
    record.positionSource = String(
      player.positionSource || "omegga.player-cache",
    );
  }
  if (player.pawnPath) record.pawnPath = String(player.pawnPath);
  if (player.rootComponentPath)
    record.rootComponentPath = String(player.rootComponentPath);
  if (typeof player.isDead === "boolean") record.isDead = player.isDead;

  return record;
}

function commandPlayerRecord(record) {
  const compact = {
    uuid: record.uuid,
    username: record.username,
    controllerAvailable: record.controllerAvailable === true,
  };
  if (record.displayName && record.displayName !== record.username) {
    compact.displayName = record.displayName;
  }
  if (record.controllerPath) compact.controllerPath = record.controllerPath;
  if (record.playerStatePath) compact.playerStatePath = record.playerStatePath;
  if (Number.isFinite(record.connectionGeneration)) {
    compact.connectionGeneration = Math.max(
      0,
      Math.floor(record.connectionGeneration),
    );
  }
  if (record.position) compact.position = record.position;
  return compact;
}

function positionSnapshotRecord(player) {
  const record = cachePlayerRecord(player);
  if (!record.position) return null;
  return {
    ok: true,
    player: {
      id: record.uuid,
      uuid: record.uuid,
      name: record.playerName,
      username: record.username,
      displayName: record.displayName,
    },
    position: record.position,
    source: record.positionSource || "omegga.player-cache",
    pawnPath: record.pawnPath || "",
    rootComponentPath: record.rootComponentPath || "",
    isDead: typeof record.isDead === "boolean" ? record.isDead : undefined,
  };
}

function controllerHintFromRecord(record) {
  if (!record || typeof record !== "object") return "";
  const direct = [
    record.controller,
    record.controllerName,
    record.controllerPath,
    record.controllerFullName,
    record.sourceObject,
    record.sourceFullName,
  ];
  for (const value of direct) {
    const controller = controllerName(value);
    if (controller) return controller;
  }

  const native = record.native;
  const nativeValues = [
    native?.controller,
    native?.controllerName,
    native?.controllerFullName,
    native?.sourceObject,
    native?.sourceFullName,
  ];
  for (const value of nativeValues) {
    const controller = controllerName(value);
    if (controller) return controller;
  }

  for (const attempt of native?.attempts || []) {
    const controller = controllerHintFromRecord(attempt);
    if (controller) return controller;
  }
  return "";
}

function stablePlayerRecords(records) {
  return [...(records || [])].sort((left, right) => {
    const leftKey = [left?.uuid, left?.username, left?.controllerPath]
      .map((value) => String(value || "").toLowerCase())
      .join("\u0000");
    const rightKey = [right?.uuid, right?.username, right?.controllerPath]
      .map((value) => String(value || "").toLowerCase())
      .join("\u0000");
    return leftKey.localeCompare(rightKey);
  });
}

function playerCacheSignature(records) {
  return JSON.stringify(stablePlayerRecords(records));
}

function readExistingPlayerCacheSignature(cachePath) {
  try {
    const cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));
    return playerCacheSignature(
      Array.isArray(cache?.players) ? cache.players : [],
    );
  } catch (_error) {
    return "";
  }
}

function isoSeconds(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function parseBrickadiaLogPlayers(logPath) {
  if (!logPath || !fs.existsSync(logPath)) return [];

  let text = "";
  try {
    const stat = fs.statSync(logPath);
    const maxBytes = 512 * 1024;
    const start = Math.max(0, stat.size - maxBytes);
    const fd = fs.openSync(logPath, "r");
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    fs.closeSync(fd);
    text = buffer.toString("utf8");
  } catch (_error) {
    return [];
  }

  const players = new Map();
  let pending = {};
  for (const line of text.split(/\r?\n/)) {
    let match = line.match(
      /LogBrickadia:\s+Player\s+"([^"]+)"\s+\(([0-9a-fA-F-]{36}),\s*([^,)]*),\s*(BP_PlayerController_C_\d+)\)\s+interacted with brick\b/,
    );
    if (match) {
      const username = match[1].trim();
      const uuid = match[2].trim();
      const existing = players.get(uuid);
      players.set(uuid, {
        username,
        displayName: existing?.displayName || username,
        uuid,
        pawnPath: match[3].trim(),
        controllerPath: match[4].trim(),
        online: true,
      });
      continue;
    }

    match = line.match(/LogServerList:\s+UserName:\s+(.+)$/);
    if (match) {
      pending.username = match[1].trim();
      continue;
    }

    match = line.match(/LogServerList:\s+DisplayName:\s+(.+)$/);
    if (match) {
      pending.displayName = match[1].trim();
      continue;
    }

    match = line.match(/LogServerList:\s+UserId:\s+([0-9a-fA-F-]{36})$/);
    if (match) {
      pending.uuid = match[1].trim();
      continue;
    }

    match = line.match(/LogNet:\s+Join succeeded:\s+(.+)$/);
    if (match && pending.uuid) {
      const displayName = (
        pending.displayName ||
        match[1] ||
        pending.username ||
        ""
      ).trim();
      const username = (pending.username || displayName).trim();
      players.set(pending.uuid, {
        username,
        displayName,
        uuid: pending.uuid,
        online: true,
      });
      pending = {};
      continue;
    }

    match = line.match(
      /LogServerList:\s+Disconnected:\s+.+?\s+\(([0-9a-fA-F-]{36})\)/,
    );
    if (match && players.has(match[1])) {
      players.get(match[1]).online = false;
      continue;
    }

    match = line.match(/LogChat:\s+(.+?) left the game\./);
    if (match) {
      const name = match[1].trim();
      for (const player of players.values()) {
        if (player.username === name || player.displayName === name)
          player.online = false;
      }
    }
  }

  return Array.from(players.values())
    .filter((player) => player.online)
    .map((player) => {
      const record = [
        player.username,
        player.displayName,
        player.uuid,
        player.controllerPath || "",
        "",
      ];
      if (player.pawnPath) record.pawnPath = player.pawnPath;
      return record;
    });
}

function resolveBrickadiaLogPath(omegga, config) {
  const configured = String(config.brickadiaLogPath || "").trim();
  if (configured) return path.resolve(configured);

  const envPath = String(process.env.OMEGGA_BMF_BRICKADIA_LOG || "").trim();
  if (envPath) return path.resolve(envPath);

  const candidates = [];
  if (omegga?.dataPath) {
    candidates.push(
      path.join(omegga.dataPath, "Saved", "Logs", "Brickadia.log"),
    );
  }
  if (omegga?.path) {
    candidates.push(
      path.join(omegga.path, "data", "Saved", "Logs", "Brickadia.log"),
    );
  }
  candidates.push(
    path.join(process.cwd(), "data", "Saved", "Logs", "Brickadia.log"),
  );

  return candidates.find((candidate) => fs.existsSync(candidate)) || "";
}

module.exports = class BmfPlayerSync {
  constructor(omegga, config) {
    this.omegga = omegga;
    this.config = config || {};
    this.timer = null;
    this.interval = null;
    this.provenanceTimer = null;
    this.lastPlayerCacheSignature = "";
    this.lastPublishedPlayerCacheSignature = "";
    this.lastRejectedPlayerCommandSignature = "";
    this.syncInFlight = null;
    this.pendingSyncReason = "";
    this.pendingSyncContext = null;
    this.scheduledSyncContext = null;
    this.connectionGenerationByUuid = new Map();
    this.syncCounters = {
      triggersCoalesced: 0,
      cacheWrites: 0,
      cacheWritesSuppressed: 0,
      socketPublishes: 0,
      socketPublishFailures: 0,
      socketUnchangedSuppressed: 0,
      socketOversizedRejected: 0,
      followUpsRescheduled: 0,
    };
    this.lastPositionStatus = {
      available: false,
      reason: "not-run",
    };
    this.handlePlayerChange = this.handlePlayerChange.bind(this);
    this.handleRawPlayersChanged = this.handleRawPlayersChanged.bind(this);
    this.handleManualSync = this.handleManualSync.bind(this);
    this.handleInteract = this.handleInteract.bind(this);
  }

  async init() {
    this.omegga.on("join", this.handlePlayerChange);
    this.omegga.on("leave", this.handlePlayerChange);
    this.omegga.on("start", this.handlePlayerChange);
    this.omegga.on("plugin:players:raw", this.handleRawPlayersChanged);
    this.omegga.on("cmd:bmfsyncplayers", this.handleManualSync);
    if (this.shouldForwardInteract()) {
      this.omegga.on("interact", this.handleInteract);
    }
    this.scheduleSync("init");
    this.startPeriodicSync();
    if (envValue("BMF_PROVENANCE_IDENTITY_PATH")) {
      this.provenanceTimer = setTimeout(() => {
        this.provenanceTimer = null;
        this.writeStatus("provenance-refresh");
      }, 10000);
      if (typeof this.provenanceTimer.unref === "function") {
        this.provenanceTimer.unref();
      }
    }
    return { registeredCommands: ["bmfsyncplayers"] };
  }

  async stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (this.interval) clearInterval(this.interval);
    this.interval = null;
    if (this.provenanceTimer) clearTimeout(this.provenanceTimer);
    this.provenanceTimer = null;
    if (typeof this.omegga.off === "function") {
      this.omegga.off("join", this.handlePlayerChange);
      this.omegga.off("leave", this.handlePlayerChange);
      this.omegga.off("start", this.handlePlayerChange);
      this.omegga.off("plugin:players:raw", this.handleRawPlayersChanged);
      this.omegga.off("cmd:bmfsyncplayers", this.handleManualSync);
      this.omegga.off("interact", this.handleInteract);
    } else if (typeof this.omegga.removeListener === "function") {
      this.omegga.removeListener("join", this.handlePlayerChange);
      this.omegga.removeListener("leave", this.handlePlayerChange);
      this.omegga.removeListener("start", this.handlePlayerChange);
      this.omegga.removeListener(
        "plugin:players:raw",
        this.handleRawPlayersChanged,
      );
      this.omegga.removeListener("cmd:bmfsyncplayers", this.handleManualSync);
      this.omegga.removeListener("interact", this.handleInteract);
    }
  }

  handlePlayerChange(_player, context) {
    this.scheduleSync("player-change", context);
  }

  handleRawPlayersChanged(_players, context) {
    this.scheduleSync("raw-player-change", context);
  }

  handleManualSync() {
    this.scheduleSync("manual-command");
  }

  handleInteract(interaction) {
    if (!this.shouldForwardInteract()) return;
    const commandName = String(
      this.config.interactCommand || "bmf.interact.console",
    ).trim();
    if (!commandName) return;

    const player = interaction?.player || {};
    const position = Array.isArray(interaction?.position)
      ? interaction.position
      : [];
    const command = [
      commandName,
      "source=omegga.interact",
      `player=${commandValue(player.id || player.uuid || "")}`,
      `name=${commandValue(player.name || "")}`,
      `controller=${commandValue(player.controller || "")}`,
      `pawn=${commandValue(player.pawn || "")}`,
      `message=${commandValue(interaction?.message || "")}`,
      `brick=${commandValue(interaction?.brick_name || "")}`,
      `asset=${commandValue(interaction?.brick_asset || "")}`,
      `x=${commandValue(position[0] ?? "")}`,
      `y=${commandValue(position[1] ?? "")}`,
      `z=${commandValue(position[2] ?? "")}`,
    ].join(" ");

    this.queueCommand(
      "interact",
      command,
      `[bmf-player-sync] queued interact message for player=${player.id || player.name || "unknown"}`,
    ).catch((error) => {
      console.warn(
        `[bmf-player-sync] interact forward failed: ${error.message || error}`,
      );
    });
  }

  startPeriodicSync() {
    const intervalMs = Math.max(
      0,
      asNumber(
        envValue("OMEGGA_BMF_PLAYER_SYNC_INTERVAL_MS") ??
          this.config.syncIntervalMs,
        5000,
      ),
    );
    if (intervalMs <= 0) {
      console.log("[bmf-player-sync] periodic sync disabled");
      return;
    }
    if (this.interval) clearInterval(this.interval);
    console.log(`[bmf-player-sync] periodic sync interval_ms=${intervalMs}`);
    this.interval = setInterval(
      () => this.scheduleSync("interval"),
      intervalMs,
    );
  }

  shouldForwardInteract() {
    const envOverride = envFlag("OMEGGA_BMF_FORWARD_INTERACT");
    if (envOverride !== null) return envOverride;
    return this.config.forwardInteract === true;
  }

  positionSyncSetting() {
    const rawEnvValue = envValue("OMEGGA_BMF_PLAYER_SYNC_POSITIONS");
    const hasEnvOverride =
      rawEnvValue != null && String(rawEnvValue).trim() !== "";
    const envEnabled = hasEnvOverride
      ? /^(1|true|yes|on)$/i.test(String(rawEnvValue).trim())
      : null;
    const configEnabled = this.config.includePositions === true;
    return {
      enabled: hasEnvOverride ? envEnabled : configEnabled,
      source: hasEnvOverride ? "env" : "config",
      envValue: hasEnvOverride ? String(rawEnvValue).trim() : "",
      configValue: configEnabled,
    };
  }

  shouldIncludePositions() {
    return this.positionSyncSetting().enabled;
  }

  async getControlPositionPlayers(omeggaPlayers) {
    if (typeof this.omegga.execControlCommandWithOutput !== "function") {
      return {
        players: [],
        status: {
          available: false,
          reason: "execControlCommandWithOutput unavailable",
          method: "omegga.execControlCommandWithOutput",
        },
      };
    }

    const controllerHints = this.readControllerHints();
    let hinted = 0;
    const playersWithHints = (omeggaPlayers || []).map((raw) => {
      const player = normalizePlayer(raw);
      if (controllerName(player?.[3])) return player;
      for (const key of playerIdentityKeys(player)) {
        const controller = controllerHints.get(key);
        if (controller) {
          const copy = normalizePlayer(player);
          copy[3] = controller;
          hinted += 1;
          return copy;
        }
      }
      return player;
    });
    const limit = Math.max(
      1,
      Math.min(
        128,
        asNumber(
          envValue("OMEGGA_BMF_PLAYER_SYNC_POSITION_LIMIT") ??
            this.config.positionLimit,
          64,
        ),
      ),
    );
    const timeoutMs = Math.max(
      100,
      Math.min(
        5000,
        asNumber(
          envValue("OMEGGA_BMF_PLAYER_SYNC_POSITION_TIMEOUT_MS") ??
            this.config.positionTimeoutMs,
          1200,
        ),
      ),
    );
    const candidates = playersWithHints
      .map(normalizePlayer)
      .filter(
        (player) =>
          controllerName(player?.[3]) || describePlayerLocationSpec(player),
      )
      .slice(0, limit);
    const players = [];
    const errors = [];
    let missingPawn = 0;
    let missingPosition = 0;
    let described = 0;
    let describeResolved = 0;
    const startedAt = Date.now();

    for (const player of candidates) {
      const controller = controllerName(player[3]);
      try {
        if (!controller) {
          const describedPlayer = await this.getDescribedPositionPlayer(
            player,
            timeoutMs,
          );
          if (describedPlayer) {
            described += 1;
            describeResolved += 1;
            players.push(describedPlayer);
          } else if (describePlayerLocationSpec(player)) {
            described += 1;
          }
          continue;
        }

        const pawnOutput = await this.omegga.execControlCommandWithOutput(
          `GetAll BP_PlayerController_C Pawn Name=${controller}`,
          timeoutMs,
        );
        const pawn = parsePawnOutput(pawnOutput);
        if (!pawn) {
          missingPawn += 1;
          const describedPlayer = await this.getDescribedPositionPlayer(
            player,
            timeoutMs,
          );
          if (describedPlayer) {
            described += 1;
            describeResolved += 1;
            players.push(describedPlayer);
          } else if (describePlayerLocationSpec(player)) {
            described += 1;
          }
          continue;
        }

        const positionOutput = await this.omegga.execControlCommandWithOutput(
          `GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=${pawn}`,
          timeoutMs,
        );
        const position = parsePositionOutput(positionOutput);
        if (!position) {
          missingPosition += 1;
          const describedPlayer = await this.getDescribedPositionPlayer(
            player,
            timeoutMs,
          );
          if (describedPlayer) {
            described += 1;
            describeResolved += 1;
            players.push(describedPlayer);
          } else if (describePlayerLocationSpec(player)) {
            described += 1;
          }
          continue;
        }

        const positioned = normalizePlayer(player);
        positioned.position = position;
        positioned.positionSource = "omegga.execControlCommandWithOutput";
        positioned.pawnPath = pawn;
        players.push(positioned);
      } catch (error) {
        if (errors.length < 3) {
          errors.push(error.message || String(error));
        }
      }
    }

    return {
      players,
      status: {
        available: players.length > 0,
        reason: players.length > 0 ? "ok" : "empty",
        method: "omegga.execControlCommandWithOutput",
        attempted: candidates.length,
        resolved: players.length,
        controllerHints: controllerHints.size,
        hinted,
        missingPawn,
        missingPosition,
        described,
        describeResolved,
        errorCount: errors.length,
        errors,
        limit,
        timeoutMs,
        durationMs: Math.max(0, Date.now() - startedAt),
        sample: players.slice(0, 3).map((player) => ({
          name: player?.[0] || "",
          id: player?.[2] || "",
          hasPosition: !!player.position,
          position: player.position || null,
          pawnPath: player.pawnPath || "",
          isDead: typeof player.isDead === "boolean" ? player.isDead : null,
        })),
      },
    };
  }

  async getDescribedPositionPlayer(player, timeoutMs) {
    const spec = describePlayerLocationSpec(player);
    if (!spec) return null;

    const output = await this.omegga.execControlCommandWithOutput(
      `Omegga.Bridge.DescribePlayerLocation ${spec}`,
      timeoutMs,
    );
    const described = parseDescribePlayerLocationOutput(output);
    if (!described) return null;

    const positioned = normalizePlayer(player);
    positioned.position = described.position;
    positioned.positionSource = `omegga.bridge.describe-player-location.${described.source}`;
    return positioned;
  }

  async getPositionPlayers(omeggaPlayers = []) {
    const setting = this.positionSyncSetting();
    if (!setting.enabled) {
      this.lastPositionStatus = { available: false, reason: "disabled" };
      this.writeStatus("positions-disabled", {
        positionSync: setting,
        position: this.lastPositionStatus,
      });
      return [];
    }

    let bulkStatus = {
      available: false,
      reason: "getAllPlayerPositions unavailable",
      method: "omegga.getAllPlayerPositions",
    };
    if (typeof this.omegga.getAllPlayerPositions === "function") {
      try {
        const positions = await this.omegga.getAllPlayerPositions();
        const normalized = (positions || [])
          .map(normalizePositionPlayer)
          .filter(Boolean);
        bulkStatus = {
          available: normalized.length > 0,
          reason: normalized.length > 0 ? "ok" : "empty",
          method: "omegga.getAllPlayerPositions",
          rawCount: Array.isArray(positions) ? positions.length : 0,
          normalizedCount: normalized.length,
          sample: normalized.slice(0, 3).map((player) => ({
            name: player?.[0] || "",
            id: player?.[2] || "",
            hasPosition: !!player.position,
            position: player.position || null,
            pawnPath: player.pawnPath || "",
            isDead: typeof player.isDead === "boolean" ? player.isDead : null,
          })),
        };
        if (normalized.length > 0) {
          this.lastPositionStatus = bulkStatus;
          this.writeStatus("positions-ok", {
            positionSync: setting,
            position: this.lastPositionStatus,
          });
          return normalized;
        }
      } catch (error) {
        console.warn(
          `[bmf-player-sync] bulk position sync failed: ${error.message || error}`,
        );
        bulkStatus = {
          available: false,
          reason: "error",
          method: "omegga.getAllPlayerPositions",
          error: error.message || String(error),
        };
      }
    }

    try {
      const targeted = await this.getControlPositionPlayers(omeggaPlayers);
      if (targeted.players.length === 0) {
        const snapshot = this.getSnapshotPositionPlayers(omeggaPlayers);
        if (snapshot.players.length > 0) {
          this.lastPositionStatus = {
            ...snapshot.status,
            fallbackFrom: {
              ...bulkStatus,
              targeted: targeted.status,
            },
          };
          this.writeStatus("positions-ok", {
            positionSync: setting,
            position: this.lastPositionStatus,
          });
          return snapshot.players;
        }

        this.lastPositionStatus = {
          ...targeted.status,
          fallbackFrom: bulkStatus,
          snapshotFallback: snapshot.status,
        };
        this.writeStatus("positions-empty", {
          positionSync: setting,
          position: this.lastPositionStatus,
        });
        return [];
      }

      this.lastPositionStatus = {
        ...targeted.status,
        fallbackFrom: bulkStatus,
      };
      this.writeStatus(
        targeted.players.length > 0 ? "positions-ok" : "positions-empty",
        {
          positionSync: setting,
          position: this.lastPositionStatus,
        },
      );
      return targeted.players;
    } catch (error) {
      console.warn(
        `[bmf-player-sync] position sync failed: ${error.message || error}`,
      );
      this.lastPositionStatus = {
        available: false,
        reason: "error",
        error: error.message || String(error),
        fallbackFrom: bulkStatus,
      };
      this.writeStatus("positions-error", {
        positionSync: setting,
        position: this.lastPositionStatus,
      });
      return [];
    }
  }

  get runtimeDir() {
    const configured = String(this.config.runtimeDir || "").trim();
    if (configured) return path.resolve(configured);

    const configuredCommandDir = String(this.config.commandDir || "").trim();
    if (configuredCommandDir) {
      const commandDir = path.resolve(configuredCommandDir);
      return path.basename(commandDir).toLowerCase() === "commands"
        ? path.dirname(commandDir)
        : commandDir;
    }

    const envRuntimeDir = String(
      envValue("OMEGGA_BMF_RUNTIME_DIR") || "",
    ).trim();
    if (envRuntimeDir) return path.resolve(envRuntimeDir);

    const commandDir = this.commandDir;
    if (commandDir) {
      return path.basename(commandDir).toLowerCase() === "commands"
        ? path.dirname(commandDir)
        : commandDir;
    }

    return "";
  }

  get commandDir() {
    const configured = String(this.config.commandDir || "").trim();
    if (configured) return path.resolve(configured);

    const envCommandDir = String(
      envValue("OMEGGA_BMF_COMMAND_DIR") || "",
    ).trim();
    if (envCommandDir) return path.resolve(envCommandDir);

    const runtimeDir = String(
      this.config.runtimeDir || envValue("OMEGGA_BMF_RUNTIME_DIR") || "",
    ).trim();
    return runtimeDir ? path.join(path.resolve(runtimeDir), "commands") : "";
  }

  get playerCachePath() {
    const configured = String(this.config.playerCachePath || "").trim();
    if (configured) return path.resolve(configured);

    const hasConfiguredRuntime =
      String(this.config.runtimeDir || "").trim() !== "" ||
      String(this.config.commandDir || "").trim() !== "";
    if (hasConfiguredRuntime) {
      const runtimeDir = this.runtimeDir;
      return runtimeDir ? path.join(runtimeDir, "players.json") : "";
    }

    const envPath = String(
      envValue("OMEGGA_BMF_PLAYER_CACHE_PATH") || "",
    ).trim();
    if (envPath) return path.resolve(envPath);

    const runtimeDir = this.runtimeDir;
    return runtimeDir ? path.join(runtimeDir, "players.json") : "";
  }

  get statusPath() {
    const runtimeDir = this.runtimeDir;
    return runtimeDir
      ? path.join(runtimeDir, "bmf-player-sync-status.json")
      : "";
  }

  get positionSnapshotPath() {
    const configured = String(this.config.positionSnapshotPath || "").trim();
    if (configured) return path.resolve(configured);

    const bmfSnapshotPath = String(
      envValue("BMF_PLAYERS_POSITIONS_SNAPSHOT_PATH") || "",
    ).trim();
    if (bmfSnapshotPath) return path.resolve(bmfSnapshotPath);

    const citySnapshotPath = String(
      envValue("CITYRPG_BMF_POSITION_SNAPSHOT_PATH") || "",
    ).trim();
    if (citySnapshotPath) return path.resolve(citySnapshotPath);

    const runtimeDir = this.runtimeDir;
    return runtimeDir ? path.join(runtimeDir, "player-positions.json") : "";
  }

  readControllerHints() {
    const hints = new Map();
    const snapshotPath = this.positionSnapshotPath;
    if (!snapshotPath) return hints;

    try {
      const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
      for (const record of snapshot?.players || []) {
        const controller = controllerHintFromRecord(record);
        if (!controller) continue;
        const player = record?.player || {};
        const keys = [
          player.id,
          player.uuid,
          player.name,
          player.username,
          player.displayName,
          record.id,
          record.uuid,
          record.name,
          record.username,
          record.displayName,
        ];
        for (const value of keys) {
          const key = String(value || "")
            .trim()
            .toLowerCase();
          if (key) hints.set(key, controller);
        }
      }
    } catch (_error) {}
    return hints;
  }

  getSnapshotPositionPlayers(omeggaPlayers = []) {
    const snapshotPath = this.positionSnapshotPath;
    if (!snapshotPath) {
      return {
        players: [],
        status: {
          available: false,
          reason: "path-unavailable",
          method: "bmf.player-position-snapshot",
        },
      };
    }

    const currentKeys = new Set();
    for (const player of omeggaPlayers || []) {
      for (const key of playerIdentityKeys(player)) currentKeys.add(key);
    }

    try {
      const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
      const records = Array.isArray(snapshot?.players) ? snapshot.players : [];
      const players = [];
      for (const record of records) {
        if (!record || record.ok === false) continue;
        const player = record.player || {};
        const normalized = normalizePlayer({
          name:
            player.name ||
            player.username ||
            player.displayName ||
            record.name ||
            record.username ||
            "",
          displayName:
            player.displayName ||
            player.name ||
            record.displayName ||
            record.name ||
            "",
          id: player.id || player.uuid || record.id || record.uuid || "",
          controller:
            record.controllerPath ||
            record.controllerName ||
            record.controllerFullName ||
            record.controller ||
            "",
          state:
            record.playerStatePath ||
            record.playerStateName ||
            record.playerState ||
            "",
          position: record.position,
          positionSource:
            record.source ||
            record.positionSource ||
            snapshot.source ||
            "bmf.player-position-snapshot",
          pawnPath: record.pawnPath || record.pawnAddress || record.pawn || "",
          rootComponentPath:
            record.rootComponentPath ||
            record.rootComponentAddress ||
            record.rootComponent ||
            "",
          isDead: record.isDead,
        });
        if (!normalized.position || !normalized[0] || !normalized[2]) continue;
        if (
          currentKeys.size > 0 &&
          !playerIdentityKeys(normalized).some((key) => currentKeys.has(key))
        ) {
          continue;
        }
        players.push(normalized);
      }

      return {
        players,
        status: {
          available: players.length > 0,
          reason: players.length > 0 ? "ok" : "empty",
          method: "bmf.player-position-snapshot",
          path: snapshotPath,
          source: String(snapshot?.source || snapshot?.snapshot?.source || ""),
          generatedAt: String(
            snapshot?.generatedAt || snapshot?.snapshot?.generatedAt || "",
          ),
          rawCount: records.length,
          normalizedCount: players.length,
          sample: players.slice(0, 3).map((player) => ({
            name: player?.[0] || "",
            id: player?.[2] || "",
            hasPosition: !!player.position,
            position: player.position || null,
            pawnPath: player.pawnPath || "",
            isDead: typeof player.isDead === "boolean" ? player.isDead : null,
          })),
        },
      };
    } catch (error) {
      return {
        players: [],
        status: {
          available: false,
          reason: "error",
          method: "bmf.player-position-snapshot",
          path: snapshotPath,
          error: error.message || String(error),
        },
      };
    }
  }

  writeStatus(reason, extra = {}) {
    const statusPath = this.statusPath;
    if (!statusPath) return false;

    const positionSync = extra.positionSync || this.positionSyncSetting();
    const status = {
      schemaVersion: 1,
      adapter: "bmf-player-sync",
      updatedAt: isoSeconds(),
      provenance: runtimeProvenance("bmf.omegga.player_sync_status"),
      reason: reason || "sync",
      runtimeDir: this.runtimeDir,
      playerCachePath: this.playerCachePath,
      positionSnapshotPath: this.positionSnapshotPath,
      includePositions: positionSync.enabled,
      positionSync,
      syncCounters: { ...this.syncCounters },
      ...extra,
    };
    const tmpPath = `${statusPath}.${process.pid}.${Date.now()}.tmp`;

    try {
      fs.mkdirSync(path.dirname(statusPath), { recursive: true });
      fs.writeFileSync(tmpPath, `${JSON.stringify(status)}\n`, "utf8");
      fs.renameSync(tmpPath, statusPath);
      return true;
    } catch (_error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      return false;
    }
  }

  writePositionSnapshot(players, source, reason) {
    if (!this.shouldIncludePositions()) {
      return {
        written: false,
        reason: "disabled",
        path: this.positionSnapshotPath,
        players: 0,
      };
    }

    const snapshotPath = this.positionSnapshotPath;
    if (!snapshotPath) {
      return {
        written: false,
        reason: "path-unavailable",
        path: "",
        players: 0,
      };
    }

    if (this.lastPositionStatus?.method === "bmf.player-position-snapshot") {
      return {
        written: false,
        reason: "bmf-snapshot-source",
        path: snapshotPath,
        players: (players || []).length,
      };
    }

    const records = (players || []).map(positionSnapshotRecord).filter(Boolean);
    if (records.length === 0) {
      return {
        written: false,
        reason: "empty",
        path: snapshotPath,
        players: 0,
      };
    }

    const generatedAt = isoSeconds();
    const snapshot = {
      schemaVersion: 1,
      source: "omegga.bmf-player-sync",
      generatedAt,
      players: records,
      counts: {
        players: records.length,
        ok: records.filter((record) => record.ok).length,
        positioned: records.length,
      },
      snapshot: {
        source: "omegga.bmf-player-sync",
        upstreamSource: source,
        reason: String(reason || ""),
        generatedAt,
        intervalMs: Math.max(
          0,
          asNumber(
            envValue("OMEGGA_BMF_PLAYER_SYNC_INTERVAL_MS") ??
              this.config.syncIntervalMs,
            5000,
          ),
        ),
        ok: true,
        code: "OK",
        message: "Omegga player positions collected",
      },
    };
    const tmpPath = `${snapshotPath}.${process.pid}.${Date.now()}.tmp`;

    try {
      fs.mkdirSync(path.dirname(snapshotPath), { recursive: true });
      fs.writeFileSync(tmpPath, `${JSON.stringify(snapshot)}\n`, "utf8");
      fs.renameSync(tmpPath, snapshotPath);
      return {
        written: true,
        reason: "ok",
        path: snapshotPath,
        players: records.length,
      };
    } catch (error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      console.warn(
        `[bmf-player-sync] failed to write position snapshot: ${error.message || error}`,
      );
      return {
        written: false,
        reason: "error",
        path: snapshotPath,
        players: records.length,
        error: error.message || String(error),
      };
    }
  }

  async getBmfBridge() {
    if (typeof this.omegga.getPlugin !== "function") {
      throw new Error("BMF Bridge plugin lookup is unavailable.");
    }
    const names = [
      String(this.config.bridgePluginName || "").trim(),
      "BMF Bridge",
      "bmf-bridge",
    ].filter(Boolean);
    for (const name of names) {
      const bridge = await this.omegga.getPlugin(name);
      if (
        bridge &&
        bridge.loaded !== false &&
        typeof bridge.emitPlugin === "function"
      ) {
        return bridge;
      }
    }
    throw new Error("BMF Bridge plugin is not loaded.");
  }

  async invokeBmfCommand(command, options = {}) {
    const bridge = await this.getBmfBridge();
    const response = await bridge.emitPlugin("invokeCommand", command, {
      timeoutMs: Math.max(100, asNumber(options.timeoutMs, 5000)),
      source: "omegga.bmf-player-sync",
      serviceClass: options.serviceClass === "bulk" ? "bulk" : "interactive",
    });
    if (!response || response.ok === false) {
      throw new Error(response?.detail || "BMF bridge command failed.");
    }
    return response;
  }

  async queueCommand(prefix, command, logMessage, options = {}) {
    try {
      await this.invokeBmfCommand(command, {
        idPrefix: prefix || "command",
        serviceClass: options.serviceClass,
      });
      console.log(
        logMessage ||
          `[bmf-player-sync] sent socket command ${prefix || "command"}`,
      );
      return true;
    } catch (error) {
      console.warn(
        `[bmf-player-sync] failed to send socket command: ${error.message || error}`,
      );
      return false;
    }
  }

  applyConnectionGenerations(records) {
    const enabled =
      envValue("OMEGGA_BMF_PLAYER_CONNECTION_GENERATION_ENABLED") === "1" ||
      this.config.connectionGeneration === true;
    if (!enabled) return records;

    const present = new Set();
    for (const record of records || []) {
      const uuid = String(record?.uuid || record?.id || "")
        .trim()
        .toLowerCase();
      if (!uuid) continue;
      present.add(uuid);
      const controllerPath = String(record.controllerPath || "").trim();
      const previous = this.connectionGenerationByUuid.get(uuid);
      const authoritativeGeneration = Number(record.connectionGeneration);
      let generation;
      if (
        Number.isSafeInteger(authoritativeGeneration) &&
        authoritativeGeneration > 0
      ) {
        generation = authoritativeGeneration;
      } else {
        generation = Math.max(1, Number(previous?.generation) || 1);
        if (
          previous &&
          (previous.present === false ||
            (previous.controllerPath &&
              controllerPath &&
              previous.controllerPath !== controllerPath))
        ) {
          generation += 1;
        }
      }
      record.connectionGeneration = generation;
      this.connectionGenerationByUuid.set(uuid, {
        generation,
        controllerPath: controllerPath || previous?.controllerPath || "",
        present: true,
      });
    }
    for (const [uuid, previous] of this.connectionGenerationByUuid) {
      if (!present.has(uuid)) {
        this.connectionGenerationByUuid.set(uuid, {
          ...previous,
          present: false,
        });
      }
    }
    return records;
  }

  writePlayerCache(players, source, preparedRecords = null, contextValue = null) {
    const cachePath = this.playerCachePath;
    if (!cachePath) {
      console.warn("[bmf-player-sync] player cache path is not configured");
      return false;
    }

    const records =
      preparedRecords ||
      this.applyConnectionGenerations(
        stablePlayerRecords(players.map(cachePlayerRecord)),
      );
    const signature = playerCacheSignature(records);
    if (!this.lastPlayerCacheSignature && fs.existsSync(cachePath)) {
      this.lastPlayerCacheSignature =
        readExistingPlayerCacheSignature(cachePath);
    }
    if (signature === this.lastPlayerCacheSignature && fs.existsSync(cachePath))
      return false;

    const context = this.normalizeJoinContext(contextValue);
    const cache = {
      schemaVersion: 1,
      adapter: "omegga-cache",
      source,
      updatedAt: isoSeconds(),
      ...(context ? { correlationId: context.correlationId } : {}),
      players: records,
      invalid: [],
    };
    const tmpPath = `${cachePath}.${process.pid}.${Date.now()}.tmp`;

    try {
      fs.mkdirSync(path.dirname(cachePath), { recursive: true });
      fs.writeFileSync(tmpPath, `${JSON.stringify(cache)}\n`, "utf8");
      fs.renameSync(tmpPath, cachePath);
      this.lastPlayerCacheSignature = signature;
      return true;
    } catch (error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      console.warn(
        `[bmf-player-sync] failed to write player cache: ${error.message}`,
      );
      return false;
    }
  }

  normalizeJoinContext(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const correlationId = String(value.correlationId || "").trim();
    if (!/^join-[A-Za-z0-9-]{1,90}$/.test(correlationId)) return null;
    const generation = Number(value.connectionGeneration);
    return {
      schemaVersion: 1,
      correlationId,
      logObservedAtUnixMs: Number(value.logObservedAtUnixMs) || Date.now(),
      matcherCompletedAtUnixMs:
        Number(value.matcherCompletedAtUnixMs) || Date.now(),
      ...(Number.isSafeInteger(generation) && generation > 0
        ? { connectionGeneration: generation }
        : {}),
    };
  }

  reportJoinPhase(contextValue, phase, startedAtUnixMs, outcome = "ok", detail) {
    const context = this.normalizeJoinContext(contextValue);
    if (!context || typeof this.omegga.reportJoinCorrelationPhase !== "function") {
      return;
    }
    this.omegga.reportJoinCorrelationPhase({
      correlationId: context.correlationId,
      phase,
      outcome,
      startedAtUnixMs,
      endedAtUnixMs: Date.now(),
      ...(detail && typeof detail === "object" ? { detail } : {}),
    });
  }

  scheduleSync(reason, contextValue) {
    if (this.timer) clearTimeout(this.timer);
    const context = this.normalizeJoinContext(contextValue);
    if (context) this.scheduledSyncContext = context;
    const delay = Math.max(0, asNumber(this.config.syncDelayMs, 250));
    this.timer = setTimeout(() => {
      this.timer = null;
      const scheduledContext = this.scheduledSyncContext;
      this.scheduledSyncContext = null;
      this.sync(reason, scheduledContext).catch((error) => {
        console.warn(
          `[bmf-player-sync] sync failed: ${error.message || error}`,
        );
      });
    }, delay);
  }

  async sync(reason, contextValue) {
    const requestedReason = String(reason || "sync");
    const requestedContext = this.normalizeJoinContext(contextValue);
    if (this.syncInFlight) {
      // Collapse bursts while a snapshot is being assembled. The currently
      // running sync finishes, then one pass publishes the newest state.
      this.syncCounters.triggersCoalesced += 1;
      this.pendingSyncReason = requestedReason;
      if (requestedContext) this.pendingSyncContext = requestedContext;
      return this.syncInFlight;
    }

    let nextReason = requestedReason;
    let nextContext = requestedContext;
    const run = (async () => {
      let passes = 0;
      while (nextReason && passes < 2) {
        passes += 1;
        this.pendingSyncReason = "";
        this.pendingSyncContext = null;
        await this.performSync(nextReason, nextContext);
        nextReason = this.pendingSyncReason;
        nextContext = this.pendingSyncContext;
      }
      if (nextReason) {
        this.pendingSyncReason = "";
        const followUpContext = this.pendingSyncContext;
        this.pendingSyncContext = null;
        this.syncCounters.followUpsRescheduled += 1;
        this.scheduleSync(nextReason, followUpContext);
      }
    })();
    this.syncInFlight = run;
    try {
      await run;
    } finally {
      if (this.syncInFlight === run) this.syncInFlight = null;
    }
  }

  async performSync(reason, contextValue) {
    const context = this.normalizeJoinContext(contextValue);
    const snapshotStartedAtUnixMs = Date.now();
    const omeggaPlayers = compactPlayers(
      typeof this.omegga.getPlayers === "function"
        ? this.omegga.getPlayers()
        : this.omegga.players || [],
    );
    const logPath = resolveBrickadiaLogPath(this.omegga, this.config);
    const logPlayers = parseBrickadiaLogPlayers(logPath);
    const positionPlayers = await this.getPositionPlayers(omeggaPlayers);
    const players = mergePlayers(logPlayers, omeggaPlayers, positionPlayers);
    const hasLiveSource =
      omeggaPlayers.length > 0 || positionPlayers.length > 0;
    const sourceSuffix = hasLiveSource
      ? reason || "sync"
      : `${reason || "sync"}.log-fallback`;
    const source = `omegga.players.raw.${sourceSuffix}`;
    const records = this.applyConnectionGenerations(
      stablePlayerRecords(players.map(cachePlayerRecord)),
    );
    this.reportJoinPhase(context, "player_sync_snapshot", snapshotStartedAtUnixMs, "ok", {
      players: records.length,
    });
    const positionSnapshot = this.writePositionSnapshot(
      positionPlayers,
      source,
      reason,
    );
    const syncStatus = {
      source,
      counts: {
        omeggaPlayers: omeggaPlayers.length,
        logPlayers: logPlayers.length,
        positionPlayers: positionPlayers.length,
        players: players.length,
      },
      position: this.lastPositionStatus,
      positionSnapshot,
    };

    if (
      envValue("OMEGGA_BMF_PLAYER_SYNC_COMMAND_BRIDGE") === "1" ||
      this.config.commandBridge === true
    ) {
      // Keep the durable JSON snapshot on the Node side so the game-thread
      // command only publishes the already-copied records into BMF memory.
      const cacheWriteStartedAtUnixMs = Date.now();
      const cacheWritten = this.writePlayerCache(players, source, records, context);
      this.reportJoinPhase(
        context,
        "player_sync_file_publication",
        cacheWriteStartedAtUnixMs,
        cacheWritten ? "ok" : "dropped",
      );
      if (cacheWritten) this.syncCounters.cacheWrites += 1;
      else this.syncCounters.cacheWritesSuppressed += 1;
      const commandRecords = records.map(commandPlayerRecord);
      const publishedSignature = playerCacheSignature(commandRecords);
      if (publishedSignature === this.lastPublishedPlayerCacheSignature) {
        this.syncCounters.socketUnchangedSuppressed += 1;
        this.writeStatus("sync", { ...syncStatus, outcome: "unchanged" });
        return;
      }
      const serializationStartedAtUnixMs = Date.now();
      const serializedCommandRecords = JSON.stringify(commandRecords);
      this.reportJoinPhase(
        context,
        "player_sync_serialization",
        serializationStartedAtUnixMs,
      );
      const command = [
        "bmf.players.sync",
        "adapter=omegga-cache",
        `source=${source}`,
        "persist=false",
        ...(context
          ? [`correlation=${encodeURIComponent(context.correlationId)}`]
          : []),
        `players=${serializedCommandRecords}`,
      ].join(" ");
      const maxCommandBytes = Math.max(
        1024,
        Math.min(
          128 * 1024,
          asNumber(
            envValue("OMEGGA_BMF_PLAYER_SYNC_MAX_COMMAND_BYTES") ??
              envValue("BMF_UNIFIED_SOCKET_MAX_COMMAND_BYTES") ??
              this.config.maxCommandBytes,
            64 * 1024,
          ),
        ),
      );
      const commandBytes = Buffer.byteLength(command, "utf8");
      if (commandBytes > maxCommandBytes) {
        this.syncCounters.socketOversizedRejected += 1;
        if (publishedSignature !== this.lastRejectedPlayerCommandSignature) {
          console.warn(
            `[bmf-player-sync] player snapshot is ${commandBytes} bytes; maximum is ${maxCommandBytes}. Durable cache was updated but the BMF memory publish was skipped.`,
          );
          this.lastRejectedPlayerCommandSignature = publishedSignature;
        }
        this.writeStatus("sync", {
          ...syncStatus,
          outcome: "oversized",
          commandBytes,
          maxCommandBytes,
        });
        return;
      }
      this.lastRejectedPlayerCommandSignature = "";

      const bridgeStartedAtUnixMs = Date.now();
      const published = await this.queueCommand(
        "players_sync",
        command,
        `[bmf-player-sync] queued ${players.length} player(s) reason=${reason || "sync"} omegga=${omeggaPlayers.length} log=${logPlayers.length} positions=${positionPlayers.length}`,
        { serviceClass: "bulk" },
      );
      this.reportJoinPhase(
        context,
        "player_sync_bridge_transport",
        bridgeStartedAtUnixMs,
        published ? "ok" : "error",
      );
      if (published) {
        this.lastPublishedPlayerCacheSignature = publishedSignature;
        this.syncCounters.socketPublishes += 1;
      } else {
        this.syncCounters.socketPublishFailures += 1;
      }
      this.writeStatus("sync", {
        ...syncStatus,
        outcome: published ? "published" : "publish-failed",
        commandBytes,
        maxCommandBytes,
      });
      return;
    }

    const cacheWriteStartedAtUnixMs = Date.now();
    const cacheWritten = this.writePlayerCache(players, source, records, context);
    this.reportJoinPhase(
      context,
      "player_sync_file_publication",
      cacheWriteStartedAtUnixMs,
      cacheWritten ? "ok" : "dropped",
    );
    if (cacheWritten) {
      this.syncCounters.cacheWrites += 1;
      console.log(
        `[bmf-player-sync] cached ${players.length} player(s) reason=${reason || "sync"} omegga=${omeggaPlayers.length} log=${logPlayers.length} positions=${positionPlayers.length}`,
      );
    } else {
      this.syncCounters.cacheWritesSuppressed += 1;
    }
    this.writeStatus("sync", {
      ...syncStatus,
      outcome: cacheWritten ? "cached" : "unchanged",
    });
  }
};
