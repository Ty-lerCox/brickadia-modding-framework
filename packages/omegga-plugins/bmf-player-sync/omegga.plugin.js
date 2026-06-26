const fs = require('fs');
const path = require('path');

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

let localEnvCache = null;

function readLocalEnv() {
  const values = new Map();
  const envPath = path.join(process.cwd(), '.env');
  try {
    const text = fs.readFileSync(envPath, 'utf8');
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      const key = trimmed.slice(0, separator).trim();
      const value = trimmed.slice(separator + 1).trim().replace(/^['"]|['"]$/g, '');
      if (key) values.set(key, value);
    }
  } catch (_error) {}
  return values;
}

function envValue(name) {
  const value = String(process.env[name] ?? '').trim();
  if (value) return value;
  localEnvCache = localEnvCache || readLocalEnv();
  return localEnvCache.get(name);
}

function envFlag(name) {
  const value = envValue(name);
  if (value == null || String(value).trim() === '') return null;
  return /^(1|true|yes|on)$/i.test(String(value).trim());
}

function commandValue(value) {
  return encodeURIComponent(String(value ?? ''));
}

function normalizePlayer(player) {
  if (Array.isArray(player)) {
    return [
      String(player[0] || ''),
      String(player[1] || player[0] || ''),
      String(player[2] || ''),
      String(player[3] || ''),
      String(player[4] || ''),
    ];
  }

  if (player && typeof player.raw === 'function') {
    return normalizePlayer(player.raw());
  }

  return [
    String(player?.name || ''),
    String(player?.displayName || player?.name || ''),
    String(player?.id || ''),
    String(player?.controller || ''),
    String(player?.state || ''),
  ];
}

function compactPlayers(players) {
  return (players || [])
    .map(normalizePlayer)
    .filter(player => player[0] && player[2]);
}

function cachePlayerRecord(player) {
  return {
    username: String(player[0] || ''),
    playerName: String(player[0] || ''),
    originalName: String(player[0] || ''),
    displayName: String(player[1] || player[0] || ''),
    id: String(player[2] || ''),
    uuid: String(player[2] || ''),
    controllerPath: String(player[3] || ''),
    playerStatePath: String(player[4] || ''),
    controllerAvailable: String(player[3] || '').trim() !== '',
    permissions: [],
    roles: [],
  };
}

function playerCacheSignature(records) {
  return JSON.stringify(records || []);
}

function readExistingPlayerCacheSignature(cachePath) {
  try {
    const cache = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
    return playerCacheSignature(Array.isArray(cache?.players) ? cache.players : []);
  } catch (_error) {
    return '';
  }
}

function isoSeconds(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function parseBrickadiaLogPlayers(logPath) {
  if (!logPath || !fs.existsSync(logPath)) return [];

  let text = '';
  try {
    const stat = fs.statSync(logPath);
    const maxBytes = 512 * 1024;
    const start = Math.max(0, stat.size - maxBytes);
    const fd = fs.openSync(logPath, 'r');
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    fs.closeSync(fd);
    text = buffer.toString('utf8');
  } catch (_error) {
    return [];
  }

  const players = new Map();
  let pending = {};
  for (const line of text.split(/\r?\n/)) {
    let match = line.match(/LogServerList:\s+UserName:\s+(.+)$/);
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
      const displayName = (pending.displayName || match[1] || pending.username || '').trim();
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

    match = line.match(/LogServerList:\s+Disconnected:\s+.+?\s+\(([0-9a-fA-F-]{36})\)/);
    if (match && players.has(match[1])) {
      players.get(match[1]).online = false;
      continue;
    }

    match = line.match(/LogChat:\s+(.+?) left the game\./);
    if (match) {
      const name = match[1].trim();
      for (const player of players.values()) {
        if (player.username === name || player.displayName === name) player.online = false;
      }
    }
  }

  return Array.from(players.values())
    .filter(player => player.online)
    .map(player => [player.username, player.displayName, player.uuid, '', '']);
}

function resolveBrickadiaLogPath(omegga, config) {
  const configured = String(config.brickadiaLogPath || '').trim();
  if (configured) return path.resolve(configured);

  const envPath = String(process.env.OMEGGA_BMF_BRICKADIA_LOG || '').trim();
  if (envPath) return path.resolve(envPath);

  const candidates = [];
  if (omegga?.dataPath) {
    candidates.push(path.join(omegga.dataPath, 'Saved', 'Logs', 'Brickadia.log'));
  }
  if (omegga?.path) {
    candidates.push(path.join(omegga.path, 'data', 'Saved', 'Logs', 'Brickadia.log'));
  }
  candidates.push(path.join(process.cwd(), 'data', 'Saved', 'Logs', 'Brickadia.log'));

  return candidates.find(candidate => fs.existsSync(candidate)) || '';
}

module.exports = class BmfPlayerSync {
  constructor(omegga, config) {
    this.omegga = omegga;
    this.config = config || {};
    this.timer = null;
    this.interval = null;
    this.lastPlayerCacheSignature = '';
    this.handlePlayerChange = this.handlePlayerChange.bind(this);
    this.handleManualSync = this.handleManualSync.bind(this);
    this.handleInteract = this.handleInteract.bind(this);
  }

  async init() {
    this.omegga.on('join', this.handlePlayerChange);
    this.omegga.on('leave', this.handlePlayerChange);
    this.omegga.on('start', this.handlePlayerChange);
    this.omegga.on('cmd:bmfsyncplayers', this.handleManualSync);
    if (this.shouldForwardInteract()) {
      this.omegga.on('interact', this.handleInteract);
    }
    this.scheduleSync('init');
    this.startPeriodicSync();
    return { registeredCommands: ['bmfsyncplayers'] };
  }

  async stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (this.interval) clearInterval(this.interval);
    this.interval = null;
    if (typeof this.omegga.off === 'function') {
      this.omegga.off('join', this.handlePlayerChange);
      this.omegga.off('leave', this.handlePlayerChange);
      this.omegga.off('start', this.handlePlayerChange);
      this.omegga.off('cmd:bmfsyncplayers', this.handleManualSync);
      this.omegga.off('interact', this.handleInteract);
    } else if (typeof this.omegga.removeListener === 'function') {
      this.omegga.removeListener('join', this.handlePlayerChange);
      this.omegga.removeListener('leave', this.handlePlayerChange);
      this.omegga.removeListener('start', this.handlePlayerChange);
      this.omegga.removeListener('cmd:bmfsyncplayers', this.handleManualSync);
      this.omegga.removeListener('interact', this.handleInteract);
    }
  }

  handlePlayerChange() {
    this.scheduleSync('player-change');
  }

  handleManualSync() {
    this.scheduleSync('manual-command');
  }

  handleInteract(interaction) {
    if (!this.shouldForwardInteract()) return;
    const commandName = String(this.config.interactCommand || 'bmf.interact.console').trim();
    if (!commandName) return;

    const player = interaction?.player || {};
    const position = Array.isArray(interaction?.position) ? interaction.position : [];
    const command = [
      commandName,
      'source=omegga.interact',
      `player=${commandValue(player.id || player.uuid || '')}`,
      `name=${commandValue(player.name || '')}`,
      `controller=${commandValue(player.controller || '')}`,
      `pawn=${commandValue(player.pawn || '')}`,
      `message=${commandValue(interaction?.message || '')}`,
      `brick=${commandValue(interaction?.brick_name || '')}`,
      `asset=${commandValue(interaction?.brick_asset || '')}`,
      `x=${commandValue(position[0] ?? '')}`,
      `y=${commandValue(position[1] ?? '')}`,
      `z=${commandValue(position[2] ?? '')}`,
    ].join(' ');

    this.queueCommand(
      'interact',
      command,
      `[bmf-player-sync] queued interact message for player=${player.id || player.name || 'unknown'}`,
    ).catch(error => {
      console.warn(`[bmf-player-sync] interact forward failed: ${error.message || error}`);
    });
  }

  startPeriodicSync() {
    const intervalMs = Math.max(
      0,
      asNumber(envValue('OMEGGA_BMF_PLAYER_SYNC_INTERVAL_MS') ?? this.config.syncIntervalMs, 5000),
    );
    if (intervalMs <= 0) {
      console.log('[bmf-player-sync] periodic sync disabled');
      return;
    }
    if (this.interval) clearInterval(this.interval);
    console.log(`[bmf-player-sync] periodic sync interval_ms=${intervalMs}`);
    this.interval = setInterval(() => this.scheduleSync('interval'), intervalMs);
  }

  shouldForwardInteract() {
    const envOverride = envFlag('OMEGGA_BMF_FORWARD_INTERACT');
    if (envOverride !== null) return envOverride;
    return this.config.forwardInteract === true;
  }

  get runtimeDir() {
    const configured = String(this.config.runtimeDir || '').trim();
    if (configured) return path.resolve(configured);

    const envRuntimeDir = String(process.env.OMEGGA_BMF_RUNTIME_DIR || '').trim();
    if (envRuntimeDir) return path.resolve(envRuntimeDir);

    return '';
  }

  get playerCachePath() {
    const configured = String(this.config.playerCachePath || '').trim();
    if (configured) return path.resolve(configured);

    const envPath = String(process.env.OMEGGA_BMF_PLAYER_CACHE_PATH || '').trim();
    if (envPath) return path.resolve(envPath);

    const runtimeDir = this.runtimeDir;
    return runtimeDir ? path.join(runtimeDir, 'players.json') : '';
  }

  async getBmfBridge() {
    if (typeof this.omegga.getPlugin !== 'function') {
      throw new Error('BMF Bridge plugin lookup is unavailable.');
    }
    const names = [
      String(this.config.bridgePluginName || '').trim(),
      'BMF Bridge',
      'bmf-bridge',
    ].filter(Boolean);
    for (const name of names) {
      const bridge = await this.omegga.getPlugin(name);
      if (bridge && bridge.loaded !== false && typeof bridge.emitPlugin === 'function') {
        return bridge;
      }
    }
    throw new Error('BMF Bridge plugin is not loaded.');
  }

  async invokeBmfCommand(command, options = {}) {
    const bridge = await this.getBmfBridge();
    const response = await bridge.emitPlugin('invokeCommand', command, {
      timeoutMs: Math.max(100, asNumber(options.timeoutMs, 5000)),
      source: 'omegga.bmf-player-sync',
    });
    if (!response || response.ok === false) {
      throw new Error(response?.detail || 'BMF bridge command failed.');
    }
    return response;
  }

  async queueCommand(prefix, command, logMessage) {
    try {
      await this.invokeBmfCommand(command, {
        idPrefix: prefix || 'command',
      });
      console.log(logMessage || `[bmf-player-sync] sent socket command ${prefix || 'command'}`);
      return true;
    } catch (error) {
      console.warn(`[bmf-player-sync] failed to send socket command: ${error.message || error}`);
      return false;
    }
  }

  writePlayerCache(players, source) {
    const cachePath = this.playerCachePath;
    if (!cachePath) {
      console.warn('[bmf-player-sync] player cache path is not configured');
      return false;
    }

    const records = players.map(cachePlayerRecord);
    const signature = playerCacheSignature(records);
    if (!this.lastPlayerCacheSignature && fs.existsSync(cachePath)) {
      this.lastPlayerCacheSignature = readExistingPlayerCacheSignature(cachePath);
    }
    if (signature === this.lastPlayerCacheSignature) return false;

    const cache = {
      schemaVersion: 1,
      adapter: 'omegga-cache',
      source,
      updatedAt: isoSeconds(),
      players: records,
      invalid: [],
    };
    const tmpPath = `${cachePath}.${process.pid}.${Date.now()}.tmp`;

    try {
      fs.mkdirSync(path.dirname(cachePath), { recursive: true });
      fs.writeFileSync(tmpPath, `${JSON.stringify(cache)}\n`, 'utf8');
      fs.renameSync(tmpPath, cachePath);
      this.lastPlayerCacheSignature = signature;
      return true;
    } catch (error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      console.warn(`[bmf-player-sync] failed to write player cache: ${error.message}`);
      return false;
    }
  }

  scheduleSync(reason) {
    if (this.timer) clearTimeout(this.timer);
    const delay = Math.max(0, asNumber(this.config.syncDelayMs, 250));
    this.timer = setTimeout(() => {
      this.timer = null;
      this.sync(reason).catch(error => {
        console.warn(`[bmf-player-sync] sync failed: ${error.message || error}`);
      });
    }, delay);
  }

  async sync(reason) {
    const omeggaPlayers = compactPlayers(
      typeof this.omegga.getPlayers === 'function'
        ? this.omegga.getPlayers()
        : this.omegga.players || []
    );
    const logPath = resolveBrickadiaLogPath(this.omegga, this.config);
    const logPlayers = parseBrickadiaLogPlayers(logPath);
    const byUuid = new Map();
    for (const player of logPlayers) byUuid.set(player[2], player);
    for (const player of omeggaPlayers) byUuid.set(player[2], player);
    const players = Array.from(byUuid.values());
    const sourceSuffix = omeggaPlayers.length > 0 ? reason || 'sync' : `${reason || 'sync'}.log-fallback`;
    const source = `omegga.players.raw.${sourceSuffix}`;

    if (envValue('OMEGGA_BMF_PLAYER_SYNC_COMMAND_BRIDGE') === '1' || this.config.commandBridge === true) {
      const command = [
        'bmf.players.sync',
        'adapter=omegga-cache',
        `source=${source}`,
        `players=${JSON.stringify(players)}`,
      ].join(' ');

      await this.queueCommand(
        'players_sync',
        command,
        `[bmf-player-sync] queued ${players.length} player(s) reason=${reason || 'sync'} omegga=${omeggaPlayers.length} log=${logPlayers.length}`,
      );
      return;
    }

    if (this.writePlayerCache(players, source)) {
      console.log(
        `[bmf-player-sync] cached ${players.length} player(s) reason=${reason || 'sync'} omegga=${omeggaPlayers.length} log=${logPlayers.length}`,
      );
    }
  }
};
