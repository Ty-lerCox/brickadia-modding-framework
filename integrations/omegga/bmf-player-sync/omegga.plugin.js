const fs = require('fs');
const path = require('path');

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
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

module.exports = class BmfPlayerSync {
  constructor(omegga, config) {
    this.omegga = omegga;
    this.config = config || {};
    this.timer = null;
    this.handlePlayerChange = this.handlePlayerChange.bind(this);
    this.handleManualSync = this.handleManualSync.bind(this);
  }

  async init() {
    this.omegga.on('join', this.handlePlayerChange);
    this.omegga.on('leave', this.handlePlayerChange);
    this.omegga.on('start', this.handlePlayerChange);
    this.omegga.on('cmd:bmfsyncplayers', this.handleManualSync);
    this.scheduleSync('init');
    return { registeredCommands: ['bmfsyncplayers'] };
  }

  async stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (typeof this.omegga.off === 'function') {
      this.omegga.off('join', this.handlePlayerChange);
      this.omegga.off('leave', this.handlePlayerChange);
      this.omegga.off('start', this.handlePlayerChange);
      this.omegga.off('cmd:bmfsyncplayers', this.handleManualSync);
    } else if (typeof this.omegga.removeListener === 'function') {
      this.omegga.removeListener('join', this.handlePlayerChange);
      this.omegga.removeListener('leave', this.handlePlayerChange);
      this.omegga.removeListener('start', this.handlePlayerChange);
      this.omegga.removeListener('cmd:bmfsyncplayers', this.handleManualSync);
    }
  }

  handlePlayerChange() {
    this.scheduleSync('player-change');
  }

  handleManualSync() {
    this.scheduleSync('manual-command');
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

    const players = compactPlayers(
      typeof this.omegga.getPlayers === 'function'
        ? this.omegga.getPlayers()
        : this.omegga.players || []
    );
    const command = [
      'bmf.players.sync',
      'adapter=omegga-cache',
      `source=omegga.players.raw.${reason || 'sync'}`,
      `players=${JSON.stringify(players)}`,
    ].join(' ');

    const id = `players_sync_${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
    const tmpPath = path.join(commandDir, `${id}.request.tmp`);
    const requestPath = path.join(commandDir, `${id}.request.txt`);

    try {
      fs.mkdirSync(commandDir, { recursive: true });
      fs.writeFileSync(tmpPath, command, 'utf8');
      fs.renameSync(tmpPath, requestPath);
      console.log(`[bmf-player-sync] queued ${players.length} player(s) reason=${reason || 'sync'}`);
    } catch (error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      console.warn(`[bmf-player-sync] failed to queue player sync: ${error.message}`);
    }
  }
};
