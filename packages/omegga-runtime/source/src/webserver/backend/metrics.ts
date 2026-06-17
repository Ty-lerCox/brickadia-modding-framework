import Logger from '@/logger';
import { AutoRestartConfig, IServerStatus } from '@/plugin';
import soft from '@/softconfig';
import { IS_WINDOWS } from '@util/platform';
import {
  clearLastSteamUpdateCheck,
  getLastSteamUpdateCheck,
  hasSteamUpdate,
  steamcmdDownloadGame,
} from '@/updater/steam';
import type Webserver from './index';
import { IStoreAutoRestartConfig, OmeggaSocketIo } from './types';

const error = (...args: any[]) => Logger.error(...args);
let lastRestart = 0;

const sleep = t => new Promise(resolve => setTimeout(resolve, t));
const envFlagEnabled = (name: string, fallback = true) => {
  const value = process.env[name]?.trim();
  if (value === undefined || value === '') return fallback;
  return !['0', 'false', 'no', 'off'].includes(value.toLowerCase());
};

const resolveMetricHeartbeatIntervalMs = () => {
  const configured = Number(process.env.OMEGGA_METRIC_HEARTBEAT_INTERVAL_MS);
  if (Number.isFinite(configured) && configured > 0) {
    return Math.max(1000, configured);
  }
  return soft.METRIC_HEARTBEAT_INTERVAL;
};

const recordServerStatusPoll = (
  server: Webserver,
  ok: boolean,
  durationMs: number,
) => {
  const metrics = server.serverStatusPollMetrics;
  metrics.count += 1;
  if (ok) metrics.ok += 1;
  else metrics.error += 1;
  metrics.durationMsSum += durationMs;
  metrics.durationMsMax = Math.max(metrics.durationMsMax, durationMs);
  metrics.lastMs = durationMs;
  metrics.lastAtMs = Date.now();
};

const buildCachedServerStatus = (server: Webserver): IServerStatus | null => {
  const omegga = server.omegga as typeof server.omegga & {
    _startedAtMs?: number;
    _playerJoinedAt?: Map<string, number>;
  };
  const previous = server.lastReportedStatus;
  const startedAtMs = Number(omegga._startedAtMs ?? 0);
  const uptimeMs =
    startedAtMs > 0 ? Math.max(0, Date.now() - startedAtMs) : previous?.time ?? 0;
  const joinedAt = omegga._playerJoinedAt;
  const players = (omegga.players ?? []).map(player => {
    let roles: string[] = [];
    try {
      roles = [...player.getRoles()];
    } catch (_error) {}
    return {
      name: player.name,
      ping: 0,
      time:
        joinedAt instanceof Map && typeof joinedAt.get(player.id) === 'number'
          ? Math.max(0, Date.now() - Number(joinedAt.get(player.id)))
          : 0,
      roles,
      address: '',
      id: player.id,
    };
  });

  return {
    serverName: previous?.serverName ?? '',
    description: previous?.description ?? '',
    bricks: previous?.bricks ?? 0,
    components: previous?.components ?? 0,
    time: uptimeMs,
    players,
  };
};

export default function (server: Webserver, io: OmeggaSocketIo) {
  const { database, omegga } = server;

  // server status is checked every minute
  clearInterval(server.serverStatusInterval);
  // heartbeat happens every 60 seconds
  let empties = 0;
  let lastStatusError = '';
  let lastStatusErrorAt = 0;

  // last heartbeat hour
  let lastHour = -1;
  // players that have joined in the last hour
  let hourlyPlayers: string[] = [];

  const exitOnStop = () => {
    if (omegga.stopping || !omegga.started)
      throw new Error('Omegga is already closing');
  };

  async function restartServer(
    config: IStoreAutoRestartConfig,
    update?: boolean,
  ) {
    lastRestart = Date.now();
    const iconfig: AutoRestartConfig = {
      players: config.playersEnabled,
      announcement: config.announcementEnabled,
      saveWorld: config.saveWorld,
    };
    omegga.emit('autorestart', iconfig);
    await sleep(1000);
    exitOnStop();

    const action = update ? 'Updating' : 'Restarting';

    if (config.announcementEnabled) {
      database.addChatLog('server', {}, action + ' in 30 seconds...');
      Logger.logp(action + ' in 30 seconds...');
      const announce = (t: number) =>
        omegga.broadcast(
          `<size="20">${action} in <b><color="ffffbb">${t} second${
            t !== 1 ? 's' : ''
          }</></></>`,
        );
      announce(30);
      await sleep(15000);
      announce(15);
      await sleep(10000);
      announce(5);
      await sleep(1000);
      announce(4);
      await sleep(1000);
      announce(3);
      await sleep(1000);
      announce(2);
      await sleep(1000);
      announce(1);
      await sleep(1000);
    }

    exitOnStop();

    await omegga.saveServer(iconfig);

    Logger.logp(action + '...');
    database.addChatLog('server', {}, action + ' server...');
    omegga.once('mapchange', () => {
      omegga.restoreServer();
    });

    if (
      update &&
      omegga.config.__STEAM &&
      !omegga.config.server?.steambetaPassword
    ) {
      Logger.logp('Stopping server for auto-update...');
      await omegga.stop();
      Logger.logp('Downloading update...');
      try {
        steamcmdDownloadGame({
          steambeta: omegga.config.server?.steambeta,
        });
      } catch (e) {
        error('An error occurred while downloading the update:', e);
      }
      Logger.logp('Starting server after update...');
      await omegga.start();
    } else {
      await omegga.restartServer();
    }
  }

  async function checkAutoRestart(status: IServerStatus) {
    const now = new Date();
    const currHour = now.getHours();
    const currMinute = now.getMinutes();

    /// skip restart check if we sent restart command within 5 minutes
    if (lastRestart > now.getTime() - 5 * 60 * 1000) {
      Logger.verbose('Skipping autorestart');
      return;
    }

    const config = await database.getAutoRestartConfig();
    Logger.verbose('Autorestart check', config);

    const uptimeMinutes = Math.floor(status.time / 1000 / 60);
    const uptimeHours = Math.floor(uptimeMinutes / 60);

    if (config.maxUptimeEnabled && uptimeHours >= config.maxUptime) {
      Logger.verbose('Restarting due to max uptime');
      return await restartServer(config);
    }

    if (
      config.emptyUptimeEnabled &&
      uptimeHours >= config.emptyUptime &&
      status.players.length === 0
    ) {
      Logger.verbose('Restarting due to max empty uptime');
      return await restartServer(config);
    }

    if (
      config.dailyHourEnabled &&
      currHour === config.dailyHour &&
      uptimeMinutes > currMinute
    ) {
      Logger.verbose('Restarting due to daily schedule');
      return await restartServer(config);
    }

    // Cannot auto-update on steam betas with passwords
    const lastCheck = getLastSteamUpdateCheck();
    if (
      omegga.config.__STEAM &&
      config.autoUpdateEnabled &&
      !omegga.config.server?.steambetaPassword
    ) {
      const now = Date.now();
      if (
        // If there is no update
        !lastCheck.available &&
        // And the last update was too recent
        now - lastCheck.attempt < config.autoUpdateIntervalMins * 60 * 1000
      ) {
        // Skip this check
        Logger.verbose(
          `Skipping auto update check, last check was ${Math.floor(
            (now - lastCheck.attempt) / 1000 / 60,
          )} minutes ago`,
        );
        return;
      }
      Logger.verbose('Checking for steam update');
      const hasUpdate = await hasSteamUpdate(omegga.config.server?.steambeta);
      if (hasUpdate) {
        clearLastSteamUpdateCheck();
        return await restartServer(config, true);
      }
      Logger.verbose('No steam update found');
    }
  }

  server.lastReportedStatus = null;
  server.lastReportedStatusAt = 0;
  server.lastServerStatusPollDurationMs = 0;
  server.serverStatusPollEnabled = envFlagEnabled(
    'OMEGGA_SERVER_STATUS_POLL_ENABLED',
    true,
  );
  const metricHeartbeatIntervalMs = resolveMetricHeartbeatIntervalMs();
  if (!server.serverStatusPollEnabled) {
    Logger.warn(
      'Omegga Server.Status polling disabled; using cached player heartbeat data.',
    );
  }
  server.serverStatusInterval = setInterval(async () => {
    if (!omegga.started) return;
    const statusPollStartedAt = Date.now();
    try {
      // get the server status
      let status;
      if (server.serverStatusPollEnabled) {
        try {
          status = await omegga.getServerStatus();
          const durationMs = Date.now() - statusPollStartedAt;
          server.lastServerStatusPollDurationMs = durationMs;
          recordServerStatusPoll(server, true, durationMs);
        } catch (statusError) {
          const durationMs = Date.now() - statusPollStartedAt;
          server.lastServerStatusPollDurationMs = durationMs;
          recordServerStatusPoll(server, false, durationMs);
          throw statusError;
        }
      } else {
        server.lastServerStatusPollDurationMs = 0;
        status = buildCachedServerStatus(server);
      }
      if (!status) return;

      try {
        await checkAutoRestart(status);
      } catch (err) {
        error('Error in autorestart check', err);
      }

      // get players by id
      const players = status.players.map(p => p.id);

      // send the unaltered status to the frontend
      server.lastReportedStatus = status;
      server.lastReportedStatusAt = Date.now();
      io.to('status').emit('server.status', status);
      try {
        omegga.emit('metrics:heartbeat', status);
      } catch (e) {
        // prevent the omegga callback handlers from crashing this
        error('Error in heartbeat emit', e);
      }

      // stop recording metrics after 3 empty server statuses
      if (
        players.length === 0 &&
        ++empties > soft.METRIC_EMPTIES_BEFORE_PAUSE
      ) {
        return;
      }

      const now = new Date();
      const hour = now.getUTCHours();
      // check if it's a new hour (for punchcard unique player tracking)
      if (hour !== lastHour) {
        lastHour = hour;
        hourlyPlayers = [];
      }

      // find all the players unique to this hour
      const newPlayers = players.filter(p => !hourlyPlayers.includes(p));
      if (newPlayers.length > 0) {
        // update the punchcard
        await database.updatePlayerPunchcard(newPlayers.length);
        // mark those players as previously joined players
        hourlyPlayers.push(...newPlayers);
      }

      // server is not empty, reset the counter
      empties = 0;

      const data = {
        // number of bricks
        bricks: status.bricks,
        // unique players by id
        players: players.filter((p, i) => players.indexOf(p) === i),
        // addresses by player id
        ips: Object.fromEntries(status.players.map(p => [p.id, p.address])),
      };

      // hand the server status off to the database
      await database.addHeartbeat(data);
    } catch (e) {
      server.lastServerStatusPollDurationMs = Date.now() - statusPollStartedAt;
      const message =
        e instanceof Error && e.message ? e.message : String(e ?? 'unknown');
      const detail =
        message === 'timed out'
          ? 'timed out waiting for console command output'
          : message;
      const fullMessage =
        IS_WINDOWS && detail.includes('timed out')
          ? detail +
            '; the current Windows adapter is receiving logs but not command responses'
          : detail;
      const now = Date.now();

      if (
        fullMessage !== lastStatusError ||
        now - lastStatusErrorAt > 5 * 60 * 1000
      ) {
        error('Server status check failed:', fullMessage);
        lastStatusError = fullMessage;
        lastStatusErrorAt = now;
      }
    }
  }, metricHeartbeatIntervalMs);

  // chat events
  omegga.on('chat', async (name, message, id) => {
    const p =
      omegga.getPlayer(name) ??
      (typeof id === 'string'
        ? omegga.players.find(player => player.id === id)
        : null);
    const user = {
      id: p?.id ?? (typeof id === 'string' ? id : name),
      name: p?.name ?? name,
      displayName: p?.displayName ?? name,
      color: p?.getNameColor() ?? '#ffffff',
    };

    // tell web users about a chat message
    io.to('chat').emit('chat', await database.addChatLog('msg', user, message));
  });

  // player leave events
  omegga.on('leave', async ({ id, name, displayName }) => {
    // tell web users a player left
    io.to('chat').emit(
      'chat',
      await database.addChatLog('leave', { id, name, displayName }),
    );
  });

  // player join events
  omegga.on('join', async ({ id, name, displayName }) => {
    // add the visit to the database
    const isFirst = await database.addVisit({ id, name, displayName });

    // tell web users a player joined (and if it's their first time joining)
    io.to('chat').emit(
      'chat',
      await database.addChatLog('join', {
        id,
        name,
        displayName,
        ...(isFirst ? { isFirst } : {}),
      }),
    );
  });

  // tell web users plugin status
  omegga.on(
    'plugin:status',
    (
      shortPath: string,
      info: { name: string; isLoaded: boolean; isEnabled: boolean },
    ) => {
      io.to('plugins').emit('plugin', shortPath, info);
    },
  );

  // server status events
  omegga.on('start', () =>
    io
      .to('server')
      .emit('status', { started: true, starting: false, stopping: false }),
  );
  omegga.on('server:starting', () =>
    io
      .to('server')
      .emit('status', { started: false, starting: true, stopping: false }),
  );
  omegga.on('mapchange', () =>
    io
      .to('server')
      .emit('status', { started: true, starting: false, stopping: false }),
  );
  omegga.on('server:stopped', () =>
    io
      .to('server')
      .emit('status', { started: false, starting: false, stopping: false }),
  );
  omegga.on('server:stopping', () =>
    io
      .to('server')
      .emit('status', { started: true, starting: false, stopping: true }),
  );
}
