const fs = require('fs');
const os = require('os');
const path = require('path');

const MINIGAME_JOIN_REGEX =
  /^Ruleset (?<rulesetName>.+) (?:no saved checkpoint for player|loading saved checkpoint for player) (?<playerName>.+) \((?<id>[0-9a-fA-F-]{36})\)!*$/;

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function asBoolean(value, fallback) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase();
    if (['true', '1', 'yes', 'on'].includes(normalized)) return true;
    if (['false', '0', 'no', 'off'].includes(normalized)) return false;
  }
  return fallback;
}

function unsafeConsoleSnapshotsEnabled(config) {
  return asBoolean(config?.allowUnsafeConsoleSnapshots, false);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function responseLineValue(text, key) {
  const prefix = `${key}=`;
  for (const line of String(text || '').split(/\r?\n/)) {
    if (line.startsWith(prefix)) return line.slice(prefix.length);
  }
  return '';
}

function compactObject(value) {
  const result = {};
  for (const [key, next] of Object.entries(value || {})) {
    if (next !== undefined && next !== null && next !== '') {
      result[key] = next;
    }
  }
  return result;
}

function normalizePlayer(player) {
  if (!player) return null;

  if (Array.isArray(player)) {
    return compactObject({
      name: String(player[0] || player[1] || ''),
      displayName: String(player[1] || player[0] || ''),
      id: String(player[2] || ''),
      controller: String(player[3] || ''),
      state: String(player[4] || ''),
    });
  }

  if (typeof player.raw === 'function') {
    return normalizePlayer(player.raw());
  }

  return compactObject({
    name: String(player.name || player.displayName || ''),
    displayName: String(player.displayName || player.name || ''),
    id: String(player.id || player.uuid || ''),
    controller: String(player.controller || ''),
    state: String(player.state || ''),
  });
}

function sameMinigame(a, b) {
  if (!a || !b) return false;
  if (a.ruleset && b.ruleset) return a.ruleset === b.ruleset;
  return String(a.name || '') === String(b.name || '') && Number(a.index || 0) === Number(b.index || 0);
}

function teamKey(team, minigame) {
  if (!team) return '';
  const id = String(team.team || team.id || team.name || '');
  if (!id) return '';
  const ruleset = String(minigame?.ruleset || team.minigame?.ruleset || '');
  return ruleset && !id.startsWith('BP_Team') ? `${ruleset}:${id}` : id;
}

function playerKey(player) {
  return String(player?.id || player?.state || player?.controller || player?.name || player?.displayName || '');
}

function minigameFromKey(key) {
  const text = String(key || '');
  if (text.startsWith('ruleset:')) return { key: text, ruleset: text.slice('ruleset:'.length) };

  const nameMatch = text.match(/^name:(.*)#(-?\d+)$/);
  if (nameMatch) {
    return {
      key: text,
      name: nameMatch[1],
      index: Number(nameMatch[2]),
    };
  }

  return text ? { key: text } : {};
}

function snapshotEntries(value) {
  if (Array.isArray(value)) {
    return value.map((item, index) => [String(item?.key || index), item]);
  }
  return Object.entries(value || {});
}

function colorFromGroups(groups) {
  return ['r', 'g', 'b', 'a'].map(key => asNumber(groups?.[key], 0));
}

function stableSnapshotSignature(minigames) {
  return JSON.stringify(
    (minigames || []).map(minigame => ({
      name: minigame.name || '',
      ruleset: minigame.ruleset || '',
      index: Number(minigame.index || 0),
      roundEnded: !!minigame.roundEnded,
      members: (minigame.members || []).map(playerKey).sort(),
      teams: (minigame.teams || []).map(team => ({
        key: teamKey(team, minigame),
        name: team.name || '',
        color: team.color || [],
        members: (team.members || []).map(playerKey).sort(),
      })).sort((a, b) => a.key.localeCompare(b.key)),
    })).sort((a, b) => String(a.ruleset || a.name).localeCompare(String(b.ruleset || b.name)))
  );
}

module.exports = class BmfMinigameEvents {
  constructor(omegga, config) {
    this.omegga = omegga;
    this.config = config || {};
    this.minigameCache = new Map();
    this.playerStateCache = new Map();
    this.playerMinigameCache = new Map();
    this.teamMembershipCache = new Map();
    this.joinTracker = new Map();
    this.snapshotSignature = '';
    this.lastRawSnapshot = null;
    this.lastSnapshot = null;
    this.lastStatusWriteError = null;
    this.minigameInterval = null;
    this.leaderboardInterval = null;
    this.startupTimer = null;
    this.pollingStarted = false;
    this.serverStarted = false;
    this.joinTimers = new Set();
    this.minigameCheckInFlight = false;
    this.leaderboardCheckInFlight = false;
    this.counters = {
      queued: 0,
      failed: 0,
      byEvent: {},
      minigameChecks: 0,
      leaderboardChecks: 0,
      snapshotChanges: 0,
      teamChanges: 0,
      joinMatches: 0,
      leaveChecks: 0,
      leaveQueued: 0,
      leaveCacheMisses: 0,
      leaveNoPlayer: 0,
      leaveSameMinigame: 0,
      leaveSwitches: 0,
      leaveDisconnects: 0,
      seedAttempts: 0,
      seedSuccesses: 0,
      seedFailures: 0,
      seedPlayers: 0,
      seedMemberships: 0,
      seedTeamMemberships: 0,
      lastSeed: null,
      lastLeaveCheck: null,
      lastEvent: null,
      lastError: null,
    };
    this.handleLeave = this.handleLeave.bind(this);
    this.handleStart = this.handleStart.bind(this);
    this.handleStatusCommand = this.handleStatusCommand.bind(this);
    this.handleManualSync = this.handleManualSync.bind(this);
  }

  async init() {
    if (!asBoolean(this.config.enabled, true)) {
      console.log('[bmf-minigame-events] adapter disabled by config');
      return { registeredCommands: ['bmfminigamestatus', 'bmfminigamesync'] };
    }

    if (this.config.emitJoinEvents !== false && typeof this.omegga.addMatcher === 'function') {
      this.omegga.addMatcher(
        (line, logMatch) => this.matchJoinLog(line, logMatch),
        joinEvent => {
          if (joinEvent) this.onMinigameJoin(joinEvent);
        }
      );
    }

    this.omegga.on('leave', this.handleLeave);
    this.omegga.on('start', this.handleStart);
    this.omegga.on('cmd:bmfminigamestatus', this.handleStatusCommand);
    this.omegga.on('cmd:bmfminigamesync', this.handleManualSync);

    if (this.omegga.started) {
      this.handleStart();
    } else {
      this.writeStatusFile({ polling: 'waiting-for-server-start' });
    }
    return { registeredCommands: ['bmfminigamestatus', 'bmfminigamesync'] };
  }

  async stop() {
    if (this.startupTimer) clearTimeout(this.startupTimer);
    this.startupTimer = null;
    if (this.minigameInterval) clearInterval(this.minigameInterval);
    this.minigameInterval = null;
    if (this.leaderboardInterval) clearInterval(this.leaderboardInterval);
    this.leaderboardInterval = null;
    this.pollingStarted = false;
    this.serverStarted = false;
    for (const timer of this.joinTimers) clearTimeout(timer);
    this.joinTimers.clear();

    const off = typeof this.omegga.off === 'function' ? this.omegga.off.bind(this.omegga) : null;
    const removeListener =
      typeof this.omegga.removeListener === 'function'
        ? this.omegga.removeListener.bind(this.omegga)
        : null;
    const remove = off || removeListener;
    if (remove) {
      remove('leave', this.handleLeave);
      remove('start', this.handleStart);
      remove('cmd:bmfminigamestatus', this.handleStatusCommand);
      remove('cmd:bmfminigamesync', this.handleManualSync);
    }
  }

  get commandDir() {
    const configured = String(this.config.commandDir || '').trim();
    if (configured) return path.resolve(configured);

    const envCommandDir = String(process.env.OMEGGA_BMF_COMMAND_DIR || '').trim();
    if (envCommandDir) return path.resolve(envCommandDir);

    const envRuntimeDir = String(process.env.OMEGGA_BMF_RUNTIME_DIR || '').trim();
    if (envRuntimeDir) return path.resolve(envRuntimeDir, 'commands');

    const appData =
      String(process.env.APPDATA || '').trim() ||
      path.join(os.homedir(), 'AppData', 'Roaming');
    if (appData) {
      return path.resolve(
        appData,
        'omegga',
        'steam_installs',
        'main',
        'Brickadia',
        'Binaries',
        'Win64',
        'ue4ss',
        'main',
        'Mods',
        'BMF',
        'runtime',
        'commands'
      );
    }

    return '';
  }

  get statusPath() {
    const commandDir = this.commandDir;
    return commandDir ? path.join(path.dirname(commandDir), 'minigame-adapter-status.json') : '';
  }

  currentPollingMode() {
    const allowUnsafeConsoleSnapshots = this.unsafeConsoleSnapshotsEnabled();
    if (!this.serverStarted) return 'waiting-for-server-start';
    if (!allowUnsafeConsoleSnapshots) return 'log-events-only';
    return this.pollingStarted ? 'running' : 'startup-delay';
  }

  writeStatusFile(extra = {}) {
    const statusPath = this.statusPath;
    if (!statusPath) return;

    const status = {
      updatedAt: new Date().toISOString(),
      commandDir: this.commandDir,
      polling: this.currentPollingMode(),
      allowUnsafeConsoleSnapshots: this.unsafeConsoleSnapshotsEnabled(),
      serverStarted: this.serverStarted,
      pollingStarted: this.pollingStarted,
      counters: this.counters,
      cache: {
        minigames: this.minigameCache.size,
        playerStates: this.playerStateCache.size,
        playerMinigames: this.playerMinigameCache.size,
        teamMemberships: this.teamMembershipCache.size,
      },
      lastRawSnapshot: this.lastRawSnapshot,
      lastSnapshot: this.lastSnapshot,
      lastError: this.counters.lastError,
      ...extra,
    };

    try {
      fs.mkdirSync(path.dirname(statusPath), { recursive: true });
      fs.writeFileSync(statusPath, `${JSON.stringify(status, null, 2)}\n`, 'utf8');
      this.lastStatusWriteError = null;
    } catch (error) {
      this.lastStatusWriteError = error.message || String(error);
    }
  }

  unsafeConsoleSnapshotsEnabled() {
    return unsafeConsoleSnapshotsEnabled(this.config);
  }

  startPolling() {
    if (this.startupTimer) clearTimeout(this.startupTimer);
    if (this.minigameInterval) clearInterval(this.minigameInterval);
    if (this.leaderboardInterval) clearInterval(this.leaderboardInterval);
    this.startupTimer = null;
    this.minigameInterval = null;
    this.leaderboardInterval = null;

    const startupDelayMs = Math.max(0, asNumber(this.config.startupDelayMs, 15000));
    const allowUnsafeConsoleSnapshots = this.unsafeConsoleSnapshotsEnabled();
    this.pollingStarted = false;

    if (!allowUnsafeConsoleSnapshots) {
      this.pollingStarted = true;
      this.writeStatusFile({
        polling: 'log-events-only',
        allowUnsafeConsoleSnapshots,
      });
      this.seedCacheFromBmfData('start').catch(error => {
        console.warn(`[bmf-minigame-events] BMF data seed failed: ${error.message || error}`);
      });
      return;
    }

    this.writeStatusFile({
      polling: 'startup-delay',
      startupDelayMs,
      allowUnsafeConsoleSnapshots,
    });
    this.startupTimer = setTimeout(() => {
      this.startupTimer = null;
      this.pollingStarted = true;

      const minigameIntervalMs = Math.max(0, asNumber(this.config.minigameCheckIntervalMs, 10000));
      const needsMinigamePolling =
        allowUnsafeConsoleSnapshots &&
        (this.config.emitRoundEvents !== false ||
          this.config.emitSnapshotEvents !== false ||
          this.config.emitCreateEvents !== false ||
          this.config.emitDeleteEvents !== false ||
          this.config.emitTeamEvents !== false);
      if (needsMinigamePolling) this.minigameCheck('startup');
      if (minigameIntervalMs > 0 && needsMinigamePolling) {
        this.minigameInterval = setInterval(
          () => this.minigameCheck('interval'),
          Math.max(5000, minigameIntervalMs)
        );
      }

      const leaderboardIntervalMs = Math.max(
        0,
        asNumber(this.config.leaderboardCheckIntervalMs, 10000)
      );
      const needsLeaderboardPolling =
        allowUnsafeConsoleSnapshots && this.config.emitLeaderboardEvents !== false;
      if (needsLeaderboardPolling) this.leaderboardCheck('startup');
      if (leaderboardIntervalMs > 0 && needsLeaderboardPolling) {
        this.leaderboardInterval = setInterval(
          () => this.leaderboardCheck('interval'),
          Math.max(5000, leaderboardIntervalMs)
        );
      }
      this.writeStatusFile({
        polling: allowUnsafeConsoleSnapshots ? 'running' : 'log-events-only',
        allowUnsafeConsoleSnapshots,
      });
    }, startupDelayMs);
  }

  handleStart() {
    this.serverStarted = true;
    this.minigameCache.clear();
    this.playerStateCache.clear();
    this.playerMinigameCache.clear();
    this.teamMembershipCache.clear();
    this.snapshotSignature = '';
    this.startPolling();
  }

  handleLeave(playerRef) {
    const player = this.lookupPlayer(playerRef) || normalizePlayer(playerRef);
    this.onMinigameLeave(player, null, 'player-leave');
  }

  handleStatusCommand(speaker) {
    const lines = [
      `BMF minigame adapter: queued=${this.counters.queued} failed=${this.counters.failed}`,
      `cached: minigames=${this.minigameCache.size} playerStates=${this.playerStateCache.size} players=${this.playerMinigameCache.size} teamMemberships=${this.teamMembershipCache.size}`,
      `checks: minigames=${this.counters.minigameChecks} leaderboards=${this.counters.leaderboardChecks} snapshots=${this.counters.snapshotChanges} teamChanges=${this.counters.teamChanges}`,
      `leaves: checks=${this.counters.leaveChecks} queued=${this.counters.leaveQueued} misses=${this.counters.leaveCacheMisses} noPlayer=${this.counters.leaveNoPlayer} same=${this.counters.leaveSameMinigame} switches=${this.counters.leaveSwitches} disconnects=${this.counters.leaveDisconnects}`,
      `seed: attempts=${this.counters.seedAttempts} successes=${this.counters.seedSuccesses} failures=${this.counters.seedFailures} players=${this.counters.seedPlayers} memberships=${this.counters.seedMemberships} teamMemberships=${this.counters.seedTeamMemberships}`,
      `unsafeConsoleSnapshots=${this.unsafeConsoleSnapshotsEnabled() ? 'enabled' : 'disabled'}`,
      `commandDir=${this.commandDir || '(not configured)'}`,
      `statusPath=${this.statusPath || '(not configured)'}`,
    ];
    if (this.counters.lastEvent) {
      lines.push(`lastEvent=${this.counters.lastEvent.event} player=${this.counters.lastEvent.player || ''}`);
    }
    if (this.counters.lastLeaveCheck) {
      const last = this.counters.lastLeaveCheck;
      lines.push(`lastLeave=${last.outcome} reason=${last.reason} player=${last.player || ''} minigame=${last.minigame || ''}`);
    }
    if (this.counters.lastSeed) {
      const last = this.counters.lastSeed;
      lines.push(`lastSeed=${last.outcome} reason=${last.reason} memberships=${last.memberships || 0} at=${last.finishedAt || last.startedAt || ''}`);
    }
    if (this.counters.lastError) {
      lines.push(`lastError=${this.counters.lastError}`);
    }
    this.sayToSpeaker(speaker, lines);
  }

  handleManualSync(speaker) {
    if (!this.serverStarted || !this.pollingStarted) {
      this.sayToSpeaker(speaker, ['BMF minigame adapter is waiting for the server to finish startup.']);
      this.writeStatusFile({ manualSyncSkipped: 'server-startup' });
      return;
    }

    if (!this.unsafeConsoleSnapshotsEnabled()) {
      this.seedCacheFromBmfData('manual')
        .then(summary => {
          this.sayToSpeaker(speaker, [
            `BMF minigame cache seed read ${summary.memberships} memberships from BMF data.`,
            'Log-derived join/leave events are still active.',
          ]);
        })
        .catch(error => {
          const message = error.message || String(error);
          this.sayToSpeaker(speaker, [`BMF minigame cache seed failed: ${message}`]);
        });
      return;
    }

    Promise.all([this.minigameCheck('manual'), this.leaderboardCheck('manual')])
      .then(() => {
        this.sayToSpeaker(speaker, ['BMF minigame snapshot queued.']);
      })
      .catch(error => {
        this.counters.lastError = error.message || String(error);
        this.sayToSpeaker(speaker, [`BMF minigame snapshot failed: ${this.counters.lastError}`]);
      });
  }

  sayToSpeaker(speaker, lines) {
    const target = typeof speaker === 'string' ? speaker : speaker?.name || speaker?.displayName || '';
    if (target && typeof this.omegga.whisper === 'function') {
      for (const line of lines) this.omegga.whisper(target, line);
      return;
    }
    if (typeof this.omegga.broadcast === 'function') {
      for (const line of lines) this.omegga.broadcast(line);
      return;
    }
    for (const line of lines) console.log(`[bmf-minigame-events] ${line}`);
  }

  matchJoinLog(_line, logMatch) {
    if (!logMatch?.groups) return null;
    const { generator, data } = logMatch.groups;
    if (generator !== 'LogBrickadia') return null;

    const match = String(data || '').match(MINIGAME_JOIN_REGEX);
    if (!match?.groups) return null;

    const now = Date.now();
    const duplicateWindowMs = Math.max(0, asNumber(this.config.duplicateJoinWindowMs, 250));
    const key = `${match.groups.id}:${match.groups.rulesetName}:${match.groups.playerName}`;
    const previous = this.joinTracker.get(key) || 0;
    if (previous && now - previous <= duplicateWindowMs) return null;
    this.joinTracker.set(key, now);
    while (this.joinTracker.size > 128) {
      const oldest = this.joinTracker.keys().next().value;
      this.joinTracker.delete(oldest);
    }

    this.counters.joinMatches += 1;
    return {
      player: {
        name: match.groups.playerName,
        id: match.groups.id,
      },
      minigame: {
        name: match.groups.rulesetName,
        index: 0,
        ruleset: null,
      },
    };
  }

  onMinigameJoin(joinMinigame, retryCount = 0) {
    if (this.config.emitJoinEvents === false) return;

    const playerRef = joinMinigame?.player || {};
    const player = this.lookupPlayer(playerRef.id) || this.lookupPlayer(playerRef.name) || normalizePlayer(playerRef);
    const minigame =
      this.findMinigameByName(joinMinigame?.minigame?.name) ||
      compactObject({
        name: joinMinigame?.minigame?.name,
        index: joinMinigame?.minigame?.index ?? 0,
        ruleset: joinMinigame?.minigame?.ruleset,
      });

    const maxRetries = Math.max(0, asNumber(this.config.joinRetryCount, 20));
    if ((!player || !minigame?.ruleset) && retryCount < maxRetries) {
      const delayMs = Math.max(0, asNumber(this.config.joinRetryDelayMs, 100));
      const timer = setTimeout(() => {
        this.joinTimers.delete(timer);
        this.onMinigameJoin(joinMinigame, retryCount + 1);
      }, delayMs);
      this.joinTimers.add(timer);
      return;
    }

    if (!player || !minigame?.name) return;

    const joinEvent = {
      player,
      minigame,
      source: 'omegga.bmf-minigame-events',
    };

    this.onMinigameLeave(player, joinEvent, 'minigame-switch');
    this.queueEvent('joinminigame', joinEvent);

    const playerKey = this.playerKey(player);
    if (playerKey) this.playerMinigameCache.set(playerKey, minigame);
    if (player.state && minigame.ruleset) {
      const previous = this.playerStateCache.get(player.state) || {};
      this.playerStateCache.set(player.state, {
        ...previous,
        player,
        ruleset: minigame.ruleset,
      });
    }
  }

  onMinigameLeave(player, joinEvent, reason = 'unknown') {
    this.counters.leaveChecks += 1;
    if (!player) {
      this.counters.leaveNoPlayer += 1;
      this.counters.lastLeaveCheck = {
        reason,
        outcome: 'no-player',
        player: '',
        minigame: '',
        newMinigame: '',
      };
      this.writeStatusFile({ skippedLeaveEvent: 'no-player', leaveReason: reason });
      return false;
    }

    const playerKey = this.playerKey(player);
    const cachedByPlayer = playerKey ? this.playerMinigameCache.get(playerKey) : null;
    const cachedByState = player.state ? this.playerStateCache.get(player.state) : null;
    const minigame = cachedByPlayer || this.minigameCache.get(cachedByState?.ruleset);
    const newMinigame = joinEvent?.minigame || null;
    const summary = {
      reason,
      outcome: '',
      player: playerKey || player.name || player.displayName || '',
      minigame: minigame?.name || minigame?.ruleset || '',
      newMinigame: newMinigame?.name || newMinigame?.ruleset || '',
      cachedByPlayer: !!cachedByPlayer,
      cachedByState: !!cachedByState,
    };

    if (!minigame) {
      this.counters.leaveCacheMisses += 1;
      summary.outcome = 'cache-miss';
    } else if (newMinigame && sameMinigame(minigame, newMinigame)) {
      this.counters.leaveSameMinigame += 1;
      summary.outcome = 'same-minigame';
    } else {
      const queued = this.queueEvent('leaveminigame', {
        player,
        minigame,
        newMinigame,
        source: 'omegga.bmf-minigame-events',
      });
      if (queued) {
        this.counters.leaveQueued += 1;
        if (joinEvent) this.counters.leaveSwitches += 1;
        else this.counters.leaveDisconnects += 1;
      }
      summary.outcome = queued ? 'queued' : 'queue-failed';
    }

    this.counters.lastLeaveCheck = summary;

    if (joinEvent) {
      if (playerKey) this.playerMinigameCache.set(playerKey, newMinigame);
      if (player.state && newMinigame?.ruleset) {
        this.playerStateCache.set(player.state, {
          ...(cachedByState || {}),
          player,
          ruleset: newMinigame.ruleset,
        });
      }
    } else {
      if (playerKey) this.playerMinigameCache.delete(playerKey);
      if (player.state) this.playerStateCache.delete(player.state);
    }

    this.writeStatusFile({ lastLeaveCheck: summary });
    return summary.outcome === 'queued';
  }

  normalizeSeedPlayer(player, fallbackKey) {
    const normalized = normalizePlayer(player) || {};
    const key = String(fallbackKey || '');
    if (!normalized.id && /^[0-9a-fA-F-]{36}$/.test(key)) normalized.id = key;
    if (!normalized.name && typeof player === 'string') normalized.name = player;
    return compactObject(normalized);
  }

  normalizeSeedMinigame(minigame, fallbackKey) {
    const source = typeof minigame === 'object' && minigame ? minigame : {};
    const parsed = minigameFromKey(fallbackKey || source.key);
    const normalized = compactObject({
      ...parsed,
      ...source,
      key: source.key || parsed.key || fallbackKey,
    });
    if (normalized.index !== undefined) normalized.index = asNumber(normalized.index, 0);
    return normalized;
  }

  cacheSeedMinigame(minigame, fallbackKey) {
    const normalized = this.normalizeSeedMinigame(minigame, fallbackKey);
    const key =
      String(normalized.ruleset || '') ||
      String(normalized.key || '') ||
      String(fallbackKey || '') ||
      (normalized.name ? `name:${normalized.name}#${asNumber(normalized.index, 0)}` : '');
    if (!key) return null;
    this.minigameCache.set(key, normalized);
    return normalized;
  }

  seedCachesFromSnapshot(snapshot, reason = 'manual') {
    const data = typeof snapshot === 'object' && snapshot ? snapshot : {};
    const players = data.players || {};
    const minigames = data.minigames || {};
    const memberships = data.memberships || {};
    const teamMemberships = data.teamMemberships || {};
    const summary = {
      reason,
      outcome: 'success',
      minigames: 0,
      players: 0,
      memberships: 0,
      teamMemberships: 0,
      updatedAt: data.updatedAt || '',
      source: data.source || '',
      totalUpdates: data.totalUpdates || 0,
      finishedAt: new Date().toISOString(),
    };

    for (const [key, minigame] of snapshotEntries(minigames)) {
      if (this.cacheSeedMinigame(minigame, key)) summary.minigames += 1;
    }

    for (const [key, player] of snapshotEntries(players)) {
      const normalized = this.normalizeSeedPlayer(player, key);
      const nextKey = this.playerKey(normalized) || String(key || '');
      if (!nextKey) continue;
      if (normalized.state) {
        const previous = this.playerStateCache.get(normalized.state) || {};
        this.playerStateCache.set(normalized.state, {
          ...previous,
          player: normalized,
        });
      }
      summary.players += 1;
    }

    for (const [key, membership] of snapshotEntries(memberships)) {
      if (!membership || typeof membership !== 'object') continue;
      const player = this.normalizeSeedPlayer(membership.player || players[key], key);
      const playerCacheKey = this.playerKey(player) || String(key || '');
      if (!playerCacheKey) continue;

      const minigameKey = String(membership.minigameKey || membership.key || '');
      const minigame = this.cacheSeedMinigame(
        membership.minigame || (minigameKey ? minigames[minigameKey] : null),
        minigameKey
      );
      if (!minigame) continue;

      this.playerMinigameCache.set(playerCacheKey, minigame);
      if (player.state) {
        this.playerStateCache.set(player.state, {
          ...(this.playerStateCache.get(player.state) || {}),
          player,
          ruleset: minigame.ruleset || minigame.key || minigameKey,
        });
      }
      summary.memberships += 1;
    }

    for (const [key, membership] of snapshotEntries(teamMemberships)) {
      if (!membership || typeof membership !== 'object') continue;
      const player = this.normalizeSeedPlayer(membership.player || players[key], key);
      const playerCacheKey = this.playerKey(player) || String(key || '');
      if (!playerCacheKey) continue;

      const minigameKey = String(membership.minigameKey || '');
      const minigame = this.cacheSeedMinigame(
        membership.minigame || (minigameKey ? minigames[minigameKey] : null),
        minigameKey
      );
      if (!minigame) continue;

      this.teamMembershipCache.set(playerCacheKey, {
        player,
        minigame,
        team: compactObject(membership.team || {}),
      });
      summary.teamMemberships += 1;
    }

    this.counters.seedPlayers = summary.players;
    this.counters.seedMemberships = summary.memberships;
    this.counters.seedTeamMemberships = summary.teamMemberships;
    this.counters.lastSeed = summary;
    this.writeStatusFile({ lastSeed: summary });
    return summary;
  }

  async seedCacheFromBmfData(reason = 'manual') {
    if (!asBoolean(this.config.seedCacheFromBmfData, true)) {
      const summary = {
        reason,
        outcome: 'disabled',
        memberships: 0,
        finishedAt: new Date().toISOString(),
      };
      this.counters.lastSeed = summary;
      this.writeStatusFile({ lastSeed: summary });
      return summary;
    }

    this.counters.seedAttempts += 1;
    const startedAt = new Date().toISOString();
    this.counters.lastSeed = { reason, outcome: 'started', startedAt };
    this.writeStatusFile({ lastSeed: this.counters.lastSeed });

    try {
      const timeoutMs = Math.max(1000, asNumber(this.config.seedCacheTimeoutMs, 5000));
      const response = await this.invokeBmfCommand(
        'bmf.minigames.data.snapshot',
        'minigame_seed',
        timeoutMs
      );
      const snapshotJson = responseLineValue(response.text, 'snapshot_json');
      if (!snapshotJson) {
        throw new Error('snapshot_json was missing from BMF response');
      }
      const snapshot = JSON.parse(snapshotJson);
      const summary = this.seedCachesFromSnapshot(snapshot, reason);
      summary.startedAt = startedAt;
      this.counters.seedSuccesses += 1;
      this.counters.lastSeed = summary;
      this.writeStatusFile({ lastSeed: summary });
      return summary;
    } catch (error) {
      const message = error.message || String(error);
      const summary = {
        reason,
        outcome: 'failed',
        startedAt,
        finishedAt: new Date().toISOString(),
        error: message,
      };
      this.counters.seedFailures += 1;
      this.counters.lastSeed = summary;
      this.counters.lastError = `BMF minigame data seed failed: ${message}`;
      this.writeStatusFile({ lastSeed: summary });
      throw error;
    }
  }

  async minigameCheck(reason) {
    if (!this.unsafeConsoleSnapshotsEnabled()) {
      this.writeStatusFile({ skippedMinigameCheck: reason, allowUnsafeConsoleSnapshots: false });
      return;
    }
    if (this.minigameCheckInFlight) return;
    this.minigameCheckInFlight = true;
    try {
      const minigames = await this.getMinigameSnapshot();
      this.counters.minigameChecks += 1;

      const previousRulesets = new Set(this.minigameCache.keys());
      const hadSnapshot = this.snapshotSignature !== '' || this.minigameCache.size > 0;
      const currentTeamMemberships = this.teamAssignmentsFromSnapshot(minigames);
      const signature = stableSnapshotSignature(minigames);
      const snapshotChanged = signature !== this.snapshotSignature;

      this.lastSnapshot = {
        checkedAt: new Date().toISOString(),
        reason,
        hadSnapshot,
        minigameCount: minigames.length,
        teamAssignments: currentTeamMemberships.size,
        snapshotChanged,
        minigames: minigames.map(minigame => ({
          name: minigame.name || '',
          ruleset: minigame.ruleset || '',
          members: (minigame.members || []).length,
          teams: (minigame.teams || []).map(team => ({
            name: team.name || '',
            team: team.team || '',
            members: (team.members || []).length,
          })),
        })),
      };

      for (const minigame of minigames) {
        const previous = this.minigameCache.get(minigame.ruleset);
        previousRulesets.delete(minigame.ruleset);
        if (previous) {
          if (this.config.emitRoundEvents !== false) {
            if (previous.roundEnded && !minigame.roundEnded) {
              this.queueEvent('roundchange', {
                minigame,
                ...minigame,
                source: 'omegga.bmf-minigame-events',
                reason,
              });
            } else if (!previous.roundEnded && minigame.roundEnded) {
              this.queueEvent('roundend', {
                minigame,
                ...minigame,
                source: 'omegga.bmf-minigame-events',
                reason,
              });
            }
          }
        } else if (hadSnapshot && this.config.emitCreateEvents !== false) {
          this.queueEvent('created', {
            minigame,
            source: 'omegga.bmf-minigame-events',
            reason,
          });
        }
        this.minigameCache.set(minigame.ruleset, minigame);
      }

      if (hadSnapshot && this.config.emitDeleteEvents !== false) {
        for (const ruleset of previousRulesets) {
          const minigame = this.minigameCache.get(ruleset);
          if (minigame) {
            this.queueEvent('deleted', {
              minigame,
              source: 'omegga.bmf-minigame-events',
              reason,
            });
          }
          this.minigameCache.delete(ruleset);
        }
      }

      if (this.config.emitTeamEvents !== false && hadSnapshot) {
        this.detectTeamChanges(currentTeamMemberships, reason);
      }
      this.teamMembershipCache = currentTeamMemberships;

      if (this.config.emitSnapshotEvents !== false && snapshotChanged) {
        this.snapshotSignature = signature;
        this.counters.snapshotChanges += 1;
        this.queueEvent('snapshot', {
          minigames,
          source: 'omegga.bmf-minigame-events',
          reason,
        });
      }
      this.writeStatusFile();
    } catch (error) {
      this.counters.lastError = `minigame check failed: ${error.message || error}`;
      console.warn(`[bmf-minigame-events] ${this.counters.lastError}`);
      this.writeStatusFile({ failedCheckReason: reason });
    } finally {
      this.minigameCheckInFlight = false;
    }
  }

  teamAssignmentsFromSnapshot(minigames) {
    const assignments = new Map();
    for (const minigame of minigames || []) {
      for (const team of minigame.teams || []) {
        for (const player of team.members || []) {
          const key = playerKey(player);
          if (!key) continue;
          assignments.set(key, { player, minigame, team });
        }
      }
    }
    return assignments;
  }

  detectTeamChanges(currentAssignments, reason) {
    for (const [key, assignment] of currentAssignments.entries()) {
      const previous = this.teamMembershipCache.get(key);
      const previousTeamKey = previous ? teamKey(previous.team, previous.minigame) : '';
      const nextTeamKey = teamKey(assignment.team, assignment.minigame);
      const previousMinigame = previous?.minigame?.ruleset || previous?.minigame?.name || '';
      const nextMinigame = assignment.minigame?.ruleset || assignment.minigame?.name || '';
      if (previous && (previousTeamKey !== nextTeamKey || previousMinigame !== nextMinigame)) {
        this.counters.teamChanges += 1;
        this.queueEvent('teamchange', {
          player: assignment.player,
          minigame: assignment.minigame,
          oldMinigame: previous.minigame,
          team: assignment.team,
          oldTeam: previous.team,
          source: 'omegga.bmf-minigame-events',
          reason,
        });
      }
    }

    for (const [key, previous] of this.teamMembershipCache.entries()) {
      if (currentAssignments.has(key)) continue;
      this.counters.teamChanges += 1;
      this.queueEvent('teamchange', {
        player: previous.player,
        minigame: previous.minigame,
        oldMinigame: previous.minigame,
        team: null,
        oldTeam: previous.team,
        source: 'omegga.bmf-minigame-events',
        reason,
      });
    }
  }

  async getMinigameSnapshot() {
    if (!this.unsafeConsoleSnapshotsEnabled()) {
      throw new Error('unsafe console snapshots are disabled');
    }

    if (typeof this.omegga.watchLogChunk !== 'function') {
      throw new Error('omegga.watchLogChunk is unavailable');
    }

    const ruleNameRegExp =
      /^(?<index>\d+)\) BP_Ruleset_C (.+):PersistentLevel.(?<ruleset>BP_Ruleset_C_\d+)\.RulesetName = (?<name>.*)$/;
    const ruleMembersRegExp =
      /^(?<index>\d+)\) BP_Ruleset_C (.+):PersistentLevel.(?<ruleset>BP_Ruleset_C_\d+)\.MemberStates =$/;
    const roundEndedRegExp =
      /^(?<index>\d+)\) BP_Ruleset_C (.+):PersistentLevel.(?<ruleset>BP_Ruleset_C_\d+)\.bInSession = (?<inSession>True|False)$/;
    const teamNameRegExp =
      /^(?<index>\d+)\) BP_Team(_\w+)?_C (.+):PersistentLevel.(?<ruleset>BP_Ruleset_C_\d+)\.(?<team>BP_Team(_\w+)?_C_\d+)\.TeamName = (?<name>.*)$/;
    const teamColorRegExp =
      /^(?<index>\d+)\) BP_Team(_\w+)?_C (.+):PersistentLevel.(?<ruleset>BP_Ruleset_C_\d+)\.(?<team>BP_Team(_\w+)?_C_\d+)\.TeamColor = \(B=(?<b>\d+),G=(?<g>\d+),R=(?<r>\d+),A=(?<a>\d+)\)$/;
    const teamMembersRegExp =
      /^(?<index>\d+)\) BP_Team(_\w+)?_C (.+):PersistentLevel.(?<ruleset>BP_Ruleset_C_\d+)\.(?<team>BP_Team(_\w+)?_C_\d+)\.MemberStates =$/;
    const playerStateRegExp =
      /^\t(?<index>\d+): .*?BP_PlayerState_C'(.+):PersistentLevel\.(?<state>BP_PlayerState_C_\d+)'$/;
    const options = {
      first: 'index',
      timeoutDelay: Math.max(100, asNumber(this.config.minigameCheckTimeoutMs, 5000)),
      afterMatchDelay: Math.max(0, asNumber(this.config.afterMatchDelayMs, 100)),
    };

    const [rulesets, ruleMembers, roundEndeds, teamMembers, teamNames, teamColors] = await Promise.all([
      this.omegga.watchLogChunk('GetAll BP_Ruleset_C RulesetName', ruleNameRegExp, options),
      this.watchLogArray('GetAll BP_Ruleset_C MemberStates', ruleMembersRegExp, playerStateRegExp, options),
      this.omegga.watchLogChunk('GetAll BP_Ruleset_C bInSession', roundEndedRegExp, options),
      this.watchLogArray('GetAll BP_Team_C MemberStates', teamMembersRegExp, playerStateRegExp, options),
      this.omegga.watchLogChunk('GetAll BP_Team_C TeamName', teamNameRegExp, options),
      this.omegga.watchLogChunk('GetAll BP_Team_C TeamColor', teamColorRegExp, options),
    ]);

    this.lastRawSnapshot = {
      checkedAt: new Date().toISOString(),
      rulesets: rulesets.length,
      ruleMembers: ruleMembers.length,
      roundEndeds: roundEndeds.length,
      teamMembers: teamMembers.length,
      teamNames: teamNames.length,
      teamColors: teamColors.length,
    };

    const sortedRulesets = [...rulesets].sort((a, b) =>
      String(b.groups?.ruleset || '').localeCompare(String(a.groups?.ruleset || ''))
    );
    const globalIndex = sortedRulesets.findIndex(ruleset => ruleset.groups?.name === 'GLOBAL');

    return sortedRulesets
      .map((ruleset, index) => {
        let adjustedIndex = index;
        if (globalIndex > -1) {
          if (index > globalIndex) adjustedIndex = index - 1;
          else if (index === globalIndex) adjustedIndex = -1;
        }

        const minigame = compactObject({
          index: adjustedIndex,
          ruleset: ruleset.groups?.ruleset,
          name: ruleset.groups?.name,
          roundEnded:
            roundEndeds.find(roundEnd => roundEnd.groups?.ruleset === ruleset.groups?.ruleset)
              ?.groups?.inSession === 'False',
        });

        const members = ruleMembers
          .find(item => item.item?.ruleset === ruleset.groups?.ruleset)
          ?.members
          ?.map(member => this.lookupPlayer(member.state) || compactObject({ state: member.state }))
          .filter(Boolean) || [];
        const teams = teamMembers
          .filter(item => item.item?.ruleset === ruleset.groups?.ruleset)
          .map(item => {
            const name = teamNames.find(team => team.groups?.team === item.item?.team)?.groups?.name;
            const color = colorFromGroups(
              teamColors.find(team => team.groups?.team === item.item?.team)?.groups || {}
            );
            return compactObject({
              name,
              team: item.item?.team,
              color,
              members: (item.members || [])
                .map(member => this.lookupPlayer(member.state) || compactObject({ state: member.state }))
                .filter(Boolean),
            });
          });

        return compactObject({
          ...minigame,
          members,
          teams,
        });
      })
      .filter(minigame => minigame.ruleset);
  }

  async leaderboardCheck(reason) {
    if (!this.unsafeConsoleSnapshotsEnabled()) {
      this.writeStatusFile({ skippedLeaderboardCheck: reason, allowUnsafeConsoleSnapshots: false });
      return;
    }
    if (this.config.emitLeaderboardEvents === false || this.leaderboardCheckInFlight) return;
    this.leaderboardCheckInFlight = true;
    try {
      const leaderboardInfo = await this.getLeaderboardInfo();
      this.counters.leaderboardChecks += 1;

      for (const { state, leaderboard } of leaderboardInfo) {
        const playerState = this.playerStateCache.get(state);
        const minigame = this.minigameCache.get(playerState?.ruleset);
        if (!minigame || !playerState || !Array.isArray(leaderboard)) continue;

        const oldLeaderboard = Array.isArray(playerState.leaderboard)
          ? playerState.leaderboard
          : [0, 0, 0];
        const changes = leaderboard.map((value, index) => value !== oldLeaderboard[index]);
        if (!changes.some(Boolean)) continue;

        const player = this.lookupPlayer(state) || normalizePlayer(playerState.player);
        const event = {
          player,
          leaderboard,
          oldLeaderboard,
          minigame,
          source: 'omegga.bmf-minigame-events',
          reason,
        };

        this.queueEvent('leaderboardchange', event);
        ['score', 'kill', 'death'].forEach((eventName, index) => {
          if (changes[index] && leaderboard[index] > (oldLeaderboard[index] || 0)) {
            this.queueEvent(eventName, event);
          }
        });

        this.playerStateCache.set(state, {
          ...playerState,
          player,
          leaderboard,
        });
      }
    } catch (error) {
      this.counters.lastError = `leaderboard check failed: ${error.message || error}`;
      console.warn(`[bmf-minigame-events] ${this.counters.lastError}`);
    } finally {
      this.leaderboardCheckInFlight = false;
    }
  }

  async getLeaderboardInfo() {
    const playerStateLeaderboardRegExp =
      /^(?<index>\d+)\) BP_PlayerState_C (.+):PersistentLevel.(?<state>BP_PlayerState_C_\d+)\.LeaderboardData =$/;
    const leaderboardRegExp = /^\t(?<index>\d+): (?<column>-?\d+)$/;

    const leaderboards = await this.watchLogArray(
      'GetAll BP_PlayerState_C LeaderboardData',
      playerStateLeaderboardRegExp,
      leaderboardRegExp,
      {
        timeoutDelay: Math.max(100, asNumber(this.config.leaderboardCheckTimeoutMs, 5000)),
        afterMatchDelay: Math.max(0, asNumber(this.config.afterMatchDelayMs, 100)),
      }
    );

    return leaderboards
      .map(leaderboard => ({
        state: leaderboard?.item?.state,
        leaderboard: (leaderboard?.members || []).map(member => Number(member.column)),
      }))
      .filter(item => item.state && item.leaderboard.length > 0);
  }

  async watchLogArray(cmd, itemPattern, memberPattern, options) {
    if (typeof this.omegga.watchLogChunk !== 'function') {
      throw new Error('omegga.watchLogChunk is unavailable');
    }

    const results = await this.omegga.watchLogChunk(
      cmd,
      line => {
        const itemMatch = line.match(itemPattern);
        if (itemMatch) return ['item', itemMatch];

        const memberMatch = line.match(memberPattern);
        if (memberMatch) return ['member', memberMatch];
        return undefined;
      },
      {
        first: arr => arr[0] === 'item' && arr[1].groups?.index === '0',
        timeoutDelay: options?.timeoutDelay,
        afterMatchDelay: options?.afterMatchDelay,
      }
    );

    const array = [];
    for (const [type, match] of results) {
      if (type === 'item') {
        array.push({ item: match.groups || {}, members: [] });
      } else if (type === 'member' && array.length > 0) {
        array[array.length - 1].members.push(match.groups || {});
      }
    }
    return array;
  }

  lookupPlayer(ref) {
    if (!ref && ref !== 0) return null;
    if (typeof ref === 'object') return normalizePlayer(ref);
    if (typeof this.omegga.getPlayer === 'function') {
      const found = this.omegga.getPlayer(ref);
      if (found) return normalizePlayer(found);
    }

    if (typeof this.omegga.getPlayers === 'function') {
      const players = this.omegga.getPlayers() || [];
      for (const player of players) {
        const normalized = normalizePlayer(player);
        if (
          normalized &&
          (normalized.id === ref ||
            normalized.name === ref ||
            normalized.displayName === ref ||
            normalized.state === ref ||
            normalized.controller === ref)
        ) {
          return normalized;
        }
      }
    }

    return null;
  }

  findMinigameByName(name) {
    const wanted = String(name || '');
    if (!wanted) return null;
    for (const minigame of this.minigameCache.values()) {
      if (String(minigame.name || '') === wanted) return minigame;
    }
    return null;
  }

  playerKey(player) {
    return String(player?.id || player?.uuid || player?.state || player?.controller || player?.name || player?.displayName || '');
  }

  writeCommandRequest(command, idPrefix) {
    const commandDir = this.commandDir;
    if (!commandDir) {
      throw new Error('commandDir is not configured');
    }

    const safePrefix = String(idPrefix || 'bmf_command').replace(/[^a-zA-Z0-9_-]/g, '_');
    const id = `${safePrefix}_${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
    const tmpPath = path.join(commandDir, `${id}.request.tmp`);
    const requestPath = path.join(commandDir, `${id}.request.txt`);
    const responsePath = path.join(commandDir, `${id}.response.txt`);

    try {
      fs.mkdirSync(commandDir, { recursive: true });
      fs.writeFileSync(tmpPath, command, 'utf8');
      fs.renameSync(tmpPath, requestPath);
      return { id, requestPath, responsePath };
    } catch (error) {
      try {
        if (fs.existsSync(tmpPath)) fs.unlinkSync(tmpPath);
      } catch (_cleanupError) {}
      throw error;
    }
  }

  async invokeBmfCommand(command, idPrefix, timeoutMs) {
    const request = this.writeCommandRequest(command, idPrefix);
    const deadline = Date.now() + Math.max(100, timeoutMs || 5000);

    while (Date.now() <= deadline) {
      if (fs.existsSync(request.responsePath)) {
        const text = fs.readFileSync(request.responsePath, 'utf8');
        try {
          fs.unlinkSync(request.responsePath);
        } catch (_cleanupError) {}

        const ok = responseLineValue(text, 'ok').trim().toLowerCase();
        if (ok === 'false') {
          throw new Error(responseLineValue(text, 'detail') || 'BMF command failed');
        }
        return {
          ...request,
          text,
        };
      }
      await sleep(Math.min(100, Math.max(1, deadline - Date.now())));
    }

    throw new Error(`timed out waiting for BMF command response: ${command}`);
  }

  queueEvent(eventName, payload) {
    const command = [
      'bmf.minigames.events.emit',
      `event=${encodeURIComponent(eventName)}`,
      `payload=${encodeURIComponent(JSON.stringify(payload || {}))}`,
    ].join(' ');

    try {
      this.writeCommandRequest(command, `minigame_${eventName}`);
      this.counters.queued += 1;
      this.counters.byEvent[eventName] = (this.counters.byEvent[eventName] || 0) + 1;
      this.counters.lastEvent = {
        event: eventName,
        player: payload?.player?.id || payload?.player?.name || '',
        minigame: payload?.minigame?.name || payload?.name || '',
      };
      console.log(
        `[bmf-minigame-events] queued ${eventName} player=${this.counters.lastEvent.player || 'unknown'} minigame=${this.counters.lastEvent.minigame || 'unknown'}`
      );
      this.writeStatusFile({ lastQueuedEvent: eventName });
      return true;
    } catch (error) {
      this.counters.failed += 1;
      this.counters.lastError = error.message || String(error);
      console.warn(`[bmf-minigame-events] failed to queue ${eventName}: ${this.counters.lastError}`);
      this.writeStatusFile({ failedEvent: eventName });
      return false;
    }
  }
};
