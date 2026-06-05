const fs = require('fs');
const path = require('path');

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
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
    this.handlePlayerChange = this.handlePlayerChange.bind(this);
    this.handleManualSync = this.handleManualSync.bind(this);
    this.handleInteract = this.handleInteract.bind(this);
  }

  async init() {
    this.omegga.on('join', this.handlePlayerChange);
    this.omegga.on('leave', this.handlePlayerChange);
    this.omegga.on('start', this.handlePlayerChange);
    this.omegga.on('cmd:bmfsyncplayers', this.handleManualSync);
    if (this.config.forwardInteract !== false) {
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
    if (this.config.forwardInteract === false) return;
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
    );
  }

  startPeriodicSync() {
    const intervalMs = Math.max(0, asNumber(this.config.syncIntervalMs, 5000));
    if (intervalMs <= 0) return;
    if (this.interval) clearInterval(this.interval);
    this.interval = setInterval(() => this.scheduleSync('interval'), intervalMs);
  }

  get commandDir() {
    const configured = String(this.config.commandDir || '').trim();
    if (configured) return path.resolve(configured);

    const envCommandDir = String(process.env.OMEGGA_BMF_COMMAND_DIR || '').trim();
    if (envCommandDir) return path.resolve(envCommandDir);

    const envRuntimeDir = String(process.env.OMEGGA_BMF_RUNTIME_DIR || '').trim();
    if (envRuntimeDir) return path.resolve(envRuntimeDir, 'commands');

    return '';
  }

  queueCommand(prefix, command, logMessage) {
    const commandDir = this.commandDir;
    if (!commandDir) {
      console.warn('[bmf-player-sync] commandDir is not configured');
      return false;
    }

    const id = `${prefix || 'command'}_${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
    const tmpPath = path.join(commandDir, `${id}.request.tmp`);
    const requestPath = path.join(commandDir, `${id}.request.txt`);

    try {
      fs.mkdirSync(commandDir, { recursive: true });
      fs.writeFileSync(tmpPath, command, 'utf8');
      fs.renameSync(tmpPath, requestPath);
      console.log(logMessage || `[bmf-player-sync] queued command ${id}`);
      return true;
    } catch (error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      console.warn(`[bmf-player-sync] failed to queue command: ${error.message}`);
      return false;
    }
  }

  scheduleSync(reason) {
    if (this.timer) clearTimeout(this.timer);
    const delay = Math.max(0, asNumber(this.config.syncDelayMs, 250));
    this.timer = setTimeout(() => {
      this.timer = null;
      this.sync(reason);
    }, delay);
  }

  sync(reason) {
    const commandDir = this.commandDir;
    if (!commandDir) {
      console.warn('[bmf-player-sync] commandDir is not configured');
      return;
    }

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
    const command = [
      'bmf.players.sync',
      'adapter=omegga-cache',
      `source=omegga.players.raw.${sourceSuffix}`,
      `players=${JSON.stringify(players)}`,
    ].join(' ');

    this.queueCommand(
      'players_sync',
      command,
      `[bmf-player-sync] queued ${players.length} player(s) reason=${reason || 'sync'} omegga=${omeggaPlayers.length} log=${logPlayers.length}`,
    );
  }
};
