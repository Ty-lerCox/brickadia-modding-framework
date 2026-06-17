/*
  Brickadia Server Wrapper
  Manages IO with the game server
*/

import Logger from '@/logger';
import { ACTIVE_WORLD_FILE, CONFIG_SAVED_DIR } from '@/softconfig';
import { getGlobalToken } from '@cli/auth';
import { IConfig } from '@config/types';
import { terminateChildProcess } from '@util/process';
import { IS_WINDOWS } from '@util/platform';
import {
  formatUe4ssDiagnostics,
  getBrickadiaLogPath,
  installManagedUe4ss,
  readBrickadiaBuildInfo,
  readUe4ssDiagnostics,
  resolveGameBinary,
  resolveWindowsControlBackend,
  type WindowsControlBackend,
} from '@util/ue4ss';
import { ensureWindowsConsoleBridgeBinary } from '@util/windowsBridge';
import { checkWsl } from '@util/wsl';
import 'colors';
import { ChildProcessWithoutNullStreams, spawn } from 'node:child_process';
import { randomInt } from 'node:crypto';
import EventEmitter from 'node:events';
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { createConnection, Socket } from 'node:net';
import path from 'node:path';
import { env } from 'node:process';
import readline from 'readline';
import stripAnsi from 'strip-ansi';
import BmfSocketBridgeHost from './bmfSocketBridge';
import Ue4ssBridgeHost from './ue4ssBridge';

// list of errors that can be solved by yelling at the user
const knownErrors: {
  name: string;
  solution?: string;
  match: RegExp;
  message?: string;
}[] = [
  {
    name: 'MISSING_LIBGL',
    solution: 'apt-get install libgl1-mesa-glx libglib2.0-0',
    match:
      /error while loading shared libraries: libGL\.so\.1: cannot open shared object file/,
  },
  {
    name: 'MISSING_GLIB',
    solution: 'apt-get install libgl1-mesa-glx libglib2.0-0',
    match:
      /error while loading shared libraries: libgthread-2\.0\.so\.0: cannot open shared object file/,
  },
];

const envPositiveNumber = (value: string | undefined, fallback: number) => {
  const parsed = Number(value ?? fallback);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

const WINDOWS_BRIDGE_CONNECT_RETRIES = 100;
const WINDOWS_BRIDGE_CONNECT_RETRY_MS = 50;
const WINDOWS_BRIDGE_CONTROL_PORT_MIN = 20000;
const WINDOWS_BRIDGE_CONTROL_PORT_MAX = 60000;
const WINDOWS_UE4SS_READY_TIMEOUT_MS = envPositiveNumber(
  env.OMEGGA_UE4SS_READY_TIMEOUT_MS,
  30000,
);
const DEFAULT_WINDOWS_UE4SS_WRITE_SPACING_MS = 75;
const SYNTHETIC_PLAYER_STATE_BASE = 2147483000;
const SYNTHETIC_PLAYER_CONTROLLER_BASE = 2147484000;
const SYNTHETIC_PATH_PREFIX = 'Omegga:PersistentLevel.';

type SyntheticPlayerLookup = {
  name?: string;
  displayName?: string;
  id?: string;
  state?: string;
  controller?: string;
};

const delay = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

const encodeBmfCommandArg = (value: string) =>
  encodeURIComponent(value).replace(
    /[!'()*]/g,
    char => `%${char.charCodeAt(0).toString(16).toUpperCase()}`,
  );

const parseConsoleArgs = (value: string) => {
  const args: string[] = [];
  let current = '';
  let quoted = false;
  let escaped = false;

  for (const char of value.trim()) {
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (quoted && char === '\\') {
      escaped = true;
      continue;
    }
    if (char === '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && /\s/.test(char)) {
      if (current) {
        args.push(current);
        current = '';
      }
      continue;
    }
    current += char;
  }

  if (current) args.push(current);
  return args;
};

const getBmfCommandFromOmeggaLine = (line: string) => {
  const bmfBridgeMatch = line.match(/^Omegga\.Bridge\.BMF\s+(.+)$/i);
  if (bmfBridgeMatch) return bmfBridgeMatch[1].trim();

  if (/^bmf\.[A-Za-z0-9_.-]+(?:\s|$)/.test(line)) {
    return line.trim();
  }

  const minigameMatch = line.match(/^Server\.Minigames\.(\w+)\b\s*(.*)$/i);
  if (minigameMatch) {
    const action = minigameMatch[1].toLowerCase();
    const args = parseConsoleArgs(minigameMatch[2] || '');
    switch (action) {
      case 'savepreset':
        if (args[0] && args[1]) {
          return `bmf.minigames.savepreset index=${encodeBmfCommandArg(args[0])} preset=${encodeBmfCommandArg(args[1])}`;
        }
        break;
      case 'delete':
        if (args[0])
          return `bmf.minigames.delete index=${encodeBmfCommandArg(args[0])}`;
        break;
      case 'reset':
        if (args[0])
          return `bmf.minigames.reset index=${encodeBmfCommandArg(args[0])}`;
        break;
      case 'nextround':
        if (args[0])
          return `bmf.minigames.nextround index=${encodeBmfCommandArg(args[0])}`;
        break;
      case 'loadpreset':
        if (args[0]) {
          const owner = args[1] ? ` owner=${encodeBmfCommandArg(args[1])}` : '';
          return `bmf.minigames.loadpreset preset=${encodeBmfCommandArg(args[0])}${owner}`;
        }
        break;
    }
  }

  const setTeamMatch = line.match(/^Server\.Players\.SetTeam\b\s*(.*)$/i);
  if (setTeamMatch) {
    const args = parseConsoleArgs(setTeamMatch[1] || '');
    if (args[0] && args[1]) {
      return `bmf.minigames.live.assign-team player=${encodeBmfCommandArg(args[0])} team=${encodeBmfCommandArg(args[1])} method=servercallbyname`;
    }
  }

  return '';
};

const getWindowsUe4ssWriteSpacingMs = () => {
  const value = Number(
    env.OMEGGA_UE4SS_WRITE_SPACING_MS ?? DEFAULT_WINDOWS_UE4SS_WRITE_SPACING_MS,
  );

  return Number.isFinite(value) && value > 0 ? value : 0;
};

const MINIGAME_GETALL_COMMANDS = new Set([
  'GetAll BP_Ruleset_C RulesetName',
  'GetAll BP_Ruleset_C MemberStates',
  'GetAll BP_Ruleset_C bInSession',
  'GetAll BP_Team_C MemberStates',
  'GetAll BP_Team_C TeamName',
  'GetAll BP_Team_C TeamColor',
]);

const isAllowedMinigameGetAllCommand = (line: string) =>
  MINIGAME_GETALL_COMMANDS.has(line);

const STAGED_PLAYER_MUTATION_COMMAND =
  /^Server\.Players\.(?:SetTeam|SetMinigame|SetLeaderboardValue|GiveItem|RemoveItem)\b/;

/** Start a brickadia server */
export default class BrickadiaServer extends EventEmitter {
  #child: ChildProcessWithoutNullStreams = null;
  #errInterface: readline.Interface = null;
  #outInterface: readline.Interface = null;
  #windowsBackend: WindowsControlBackend = null;
  #windowsControlPort: number = null;
  #windowsControlSocket: Socket = null;
  #windowsControlConnected = false;
  #windowsControlQueue: string[] = [];
  #windowsControlEndRequested = false;
  #windowsControlRetryTimer: NodeJS.Timeout = null;
  #ue4ssBridge: Ue4ssBridgeHost = null;
  #bmfSocketBridge: BmfSocketBridgeHost = null;
  #ue4ssWin64Dir: string = null;
  #syntheticLogCounter = 0;
  #ue4ssDegraded = false;
  #ue4ssCompatibilityValidated = true;
  #ue4ssCompatibilityBundleId: string = null;
  #ue4ssCompatibilityCl: string = null;
  #ue4ssCompatibilityReportPath: string = null;
  #ue4ssStagedObjectControlOverride = false;
  #writeQueue: Promise<void> = Promise.resolve();

  config: IConfig;
  path: string;

  constructor(dataPath: string, config: IConfig) {
    super();

    this.config = config;
    // use the data path if it's absolute, otherwise build an absolute path
    this.path =
      path.isAbsolute(dataPath) || dataPath.startsWith('/')
        ? dataPath
        : path.join(process.cwd(), dataPath);

    this.lineListener = this.lineListener.bind(this);
    this.errorListener = this.errorListener.bind(this);
    this.exitListener = this.exitListener.bind(this);
  }

  getWindowsControlBackend(): WindowsControlBackend {
    return this.#windowsBackend;
  }

  getWindowsControlCapabilities() {
    if (!IS_WINDOWS || this.#windowsBackend !== 'ue4ss' || !this.#ue4ssBridge) {
      return null;
    }

    return this.#ue4ssBridge.getCapabilities();
  }

  async waitUntilControlReady(timeoutMs = WINDOWS_UE4SS_READY_TIMEOUT_MS) {
    if (!IS_WINDOWS || !this.#windowsBackend) return null;

    if (this.#windowsBackend === 'ue4ss') {
      if (!this.#ue4ssBridge) {
        throw new Error('UE4SS bridge has not been initialized.');
      }

      return this.#ue4ssBridge.waitUntilReady(timeoutMs);
    }

    if (this.#windowsControlConnected) {
      return { backend: 'bridge' };
    }

    await new Promise((resolve, reject) => {
      const startedAt = Date.now();
      const timer = setInterval(() => {
        if (this.#windowsControlConnected) {
          clearInterval(timer);
          resolve(null);
          return;
        }

        if (Date.now() - startedAt >= timeoutMs) {
          clearInterval(timer);
          reject(
            new Error('Timed out waiting for the Windows control socket.'),
          );
        }
      }, 100);
      timer.unref?.();
    });

    return { backend: 'bridge' };
  }

  async pingWindowsControl(timeoutMs = 5000) {
    if (!IS_WINDOWS || this.#windowsBackend !== 'ue4ss' || !this.#ue4ssBridge) {
      throw new Error('UE4SS control backend is not active.');
    }

    return this.#ue4ssBridge.ping(timeoutMs);
  }

  getWindowsControlPort(): number {
    return randomInt(
      WINDOWS_BRIDGE_CONTROL_PORT_MIN,
      WINDOWS_BRIDGE_CONTROL_PORT_MAX + 1,
    );
  }

  clearWindowsControlRetry() {
    if (!this.#windowsControlRetryTimer) return;

    clearTimeout(this.#windowsControlRetryTimer);
    this.#windowsControlRetryTimer = null;
  }

  flushWindowsControlQueue() {
    if (
      !this.#windowsControlSocket ||
      !this.#windowsControlConnected ||
      this.#windowsControlSocket.destroyed ||
      this.#windowsControlSocket.writableEnded
    ) {
      return;
    }

    Logger.verbose(
      'Flushing Windows console bridge queue',
      this.#windowsControlQueue.length,
      'pending line(s)',
    );

    while (this.#windowsControlQueue.length > 0) {
      const line = this.#windowsControlQueue.shift();
      Logger.verbose(
        'Windows console bridge flush write',
        JSON.stringify(line.replace(/\n$/, '')),
      );
      this.#windowsControlSocket.write(line);
    }
  }

  connectWindowsControlSocket(port: number, attempt = 0) {
    if (!IS_WINDOWS || !this.#child || this.#child.exitCode !== null) return;

    const socket = createConnection({
      host: '127.0.0.1',
      port,
    });

    socket.setNoDelay(true);

    socket.once('connect', () => {
      if (this.#windowsControlSocket !== socket) {
        socket.destroy();
        return;
      }

      this.clearWindowsControlRetry();
      this.#windowsControlConnected = true;
      Logger.verbose(
        'Connected to Windows console bridge control port',
        port,
        'local',
        `${socket.localAddress}:${socket.localPort}`,
        'remote',
        `${socket.remoteAddress}:${socket.remotePort}`,
      );
      this.flushWindowsControlQueue();

      if (this.#windowsControlEndRequested && !socket.writableEnded) {
        socket.end();
      }
    });

    socket.on('error', (err: NodeJS.ErrnoException) => {
      Logger.verbose(
        'Windows console bridge socket error',
        err.code || 'UNKNOWN',
        err.message,
      );
      if (this.#windowsControlSocket === socket) {
        this.#windowsControlSocket = null;
      }

      this.#windowsControlConnected = false;
      socket.destroy();

      if (!this.#child || this.#child.exitCode !== null) return;

      if (
        err.code === 'ECONNREFUSED' &&
        attempt < WINDOWS_BRIDGE_CONNECT_RETRIES
      ) {
        this.#windowsControlRetryTimer = setTimeout(
          () => this.connectWindowsControlSocket(port, attempt + 1),
          WINDOWS_BRIDGE_CONNECT_RETRY_MS,
        );
        this.#windowsControlRetryTimer.unref?.();
        return;
      }

      Logger.error(
        'Failed to connect to Windows console bridge control port',
        String(port).yellow,
        err.message,
      );
    });

    socket.on('close', () => {
      Logger.verbose('Windows console bridge socket closed');
      if (this.#windowsControlSocket === socket) {
        this.#windowsControlSocket = null;
      }

      this.#windowsControlConnected = false;
    });

    this.#windowsControlSocket = socket;
  }

  writeToWindowsControl(line: string) {
    if (
      this.#windowsControlSocket &&
      this.#windowsControlConnected &&
      !this.#windowsControlSocket.destroyed &&
      !this.#windowsControlSocket.writableEnded
    ) {
      Logger.verbose(
        'Windows console bridge direct write',
        JSON.stringify(line.replace(/\n$/, '')),
      );
      this.#windowsControlSocket.write(line);
      return;
    }

    Logger.verbose(
      'Queueing Windows console bridge write',
      JSON.stringify(line.replace(/\n$/, '')),
      'connected=',
      this.#windowsControlConnected,
      'socket=',
      !!this.#windowsControlSocket,
    );
    this.#windowsControlQueue.push(line);
  }

  requestWindowsShutdown() {
    if (!IS_WINDOWS) return;

    this.#windowsControlEndRequested = true;
    this.writeToWindowsControl('exit\n');

    if (
      this.#windowsControlSocket &&
      this.#windowsControlConnected &&
      !this.#windowsControlSocket.destroyed &&
      !this.#windowsControlSocket.writableEnded
    ) {
      this.#windowsControlSocket.end();
    }
  }

  cleanupWindowsControl() {
    this.clearWindowsControlRetry();
    this.#windowsControlPort = null;
    this.#windowsControlQueue = [];
    this.#windowsControlEndRequested = false;
    this.#windowsControlConnected = false;

    if (this.#windowsControlSocket) {
      this.#windowsControlSocket.removeAllListeners();
      this.#windowsControlSocket.destroy();
      this.#windowsControlSocket = null;
    }
  }

  cleanupUe4ssBridge() {
    if (!this.#ue4ssBridge) return;

    this.#ue4ssBridge.removeAllListeners();
    this.#ue4ssBridge.stop();
    this.#ue4ssBridge = null;
  }

  cleanupBmfSocketBridge() {
    if (!this.#bmfSocketBridge) return;

    this.#bmfSocketBridge.removeAllListeners();
    this.#bmfSocketBridge.stop();
    this.#bmfSocketBridge = null;
  }

  emitSyntheticConsoleLine(line: string) {
    this.emit('line', this.formatSyntheticConsoleLine(line));
  }

  getSyntheticPlayerLookups(): SyntheticPlayerLookup[] {
    const runtime = this as unknown as { players?: SyntheticPlayerLookup[] };
    return Array.isArray(runtime.players) ? runtime.players : [];
  }

  getSyntheticPlayerNames(player: SyntheticPlayerLookup, index: number) {
    const seed = `${player.id ?? ''}:${player.name ?? ''}:${index}`;
    let hash = 0;

    for (let i = 0; i < seed.length; i += 1) {
      hash = (hash * 31 + seed.charCodeAt(i)) % 100000;
    }

    const numericId = index + 1 + hash;

    return {
      state:
        player.state ||
        `BP_PlayerState_C_${SYNTHETIC_PLAYER_STATE_BASE + numericId}`,
      controller:
        player.controller ||
        `BP_PlayerController_C_${SYNTHETIC_PLAYER_CONTROLLER_BASE + numericId}`,
    };
  }

  getSyntheticPlayerStateUserNameLines() {
    const lines: string[] = [];

    for (const [index, player] of this.getSyntheticPlayerLookups().entries()) {
      const { state } = this.getSyntheticPlayerNames(player, index);
      const name = String(
        player.name || player.displayName || `Player ${index + 1}`,
      )
        .replace(/[\r\n]+/g, ' ')
        .trim();

      lines.push(
        `${index}) BP_PlayerState_C ${SYNTHETIC_PATH_PREFIX}${state}.UserName = ${name}`,
      );
    }

    return lines;
  }

  emitSyntheticPlayerStateUserNames() {
    for (const line of this.getSyntheticPlayerStateUserNameLines()) {
      this.emitSyntheticConsoleLine(line);
    }
  }

  getSyntheticPlayerStateOwnerLines(stateName: string) {
    const players = this.getSyntheticPlayerLookups();

    for (const [index, player] of players.entries()) {
      const names = this.getSyntheticPlayerNames(player, index);

      if (names.state !== stateName) continue;

      return [
        `${index}) BP_PlayerState_C ${SYNTHETIC_PATH_PREFIX}${names.state}.Owner = BP_PlayerController_C'${SYNTHETIC_PATH_PREFIX}${names.controller}'`,
      ];
    }

    return [];
  }

  emitSyntheticPlayerStateOwner(stateName: string) {
    for (const line of this.getSyntheticPlayerStateOwnerLines(stateName)) {
      this.emitSyntheticConsoleLine(line);
    }
  }

  buildSyntheticControlOutput(
    command: string,
    executor: string,
    lines: string[],
  ) {
    return {
      result: {
        accepted: true,
        command,
        executor,
      },
      chunks: lines.map((line, index) => ({
        chunk_index: index + 1,
        line,
      })),
      complete: {
        success: true,
        executor,
        line_count: lines.length,
      },
    };
  }

  formatSyntheticConsoleLine(line: string) {
    if (/^\[\d{4}\.\d\d.\d\d-\d\d.\d\d.\d\d:\d{3}\]\[\s*\d+\]/.test(line)) {
      return line;
    }

    const now = new Date();
    const pad = (value: number, size = 2) => String(value).padStart(size, '0');
    const timestamp = `${now.getFullYear()}.${pad(now.getMonth() + 1)}.${pad(
      now.getDate(),
    )}-${pad(now.getHours())}.${pad(now.getMinutes())}.${pad(
      now.getSeconds(),
    )}:${pad(now.getMilliseconds(), 3)}`;

    this.#syntheticLogCounter += 1;
    const payload = line.startsWith('LogConsoleCommands:')
      ? line
      : `LogConsoleCommands: ${line}`;

    return `[${timestamp}][${this.#syntheticLogCounter}]${payload}`;
  }

  handleUe4ssDegraded(reason: string) {
    if (
      !IS_WINDOWS ||
      this.#windowsBackend !== 'ue4ss' ||
      this.#ue4ssDegraded
    ) {
      return;
    }

    this.#ue4ssDegraded = true;

    const diagnostics = this.#ue4ssWin64Dir
      ? readUe4ssDiagnostics(this.#ue4ssWin64Dir)
      : null;
    const buildInfo = readBrickadiaBuildInfo(
      getBrickadiaLogPath(
        this.path,
        this.config?.server?.savedDir ?? CONFIG_SAVED_DIR,
      ),
    );
    const detail = diagnostics
      ? formatUe4ssDiagnostics(diagnostics, buildInfo)
      : '';
    const message = [reason, detail].filter(Boolean).join(' ');

    Logger.warnp('UE4SS control backend is degraded.'.yellow, message);
    this.emit('control:degraded', {
      backend: 'ue4ss',
      reason,
      detail,
      diagnostics,
      buildInfo,
    });
  }

  async writeToUe4ssControl(line: string) {
    if (!this.#ue4ssBridge) {
      this.handleUe4ssDegraded('UE4SS bridge was not initialized.');
      return;
    }

    const normalizedLine = line.replace(/\r?\n$/, '');
    const execBmfCommand = async (
      command: string,
      options: {
        timeoutMs?: number;
        fallbackToFile?: boolean;
        fallbackLogLabel?: string;
      } = {},
    ) => {
      const timeoutMs = Math.max(
        100,
        Number(
          options.timeoutMs ??
            process.env.OMEGGA_BMF_SOCKET_COMMAND_TIMEOUT_MS ??
            1200,
        ),
      );
      if (this.#bmfSocketBridge?.hasBmfClients) {
        try {
          return await this.#bmfSocketBridge.execCommand(command, timeoutMs);
        } catch (error) {
          if (options.fallbackToFile === false) throw error;
          Logger.warnp(
            (
              options.fallbackLogLabel ||
              'BMF socket command failed; falling back to file bridge'
            ).yellow,
            error instanceof Error ? error.message : String(error),
          );
        }
      }

      if (options.fallbackToFile === false) {
        throw new Error('BMF socket bridge has no connected native client.');
      }

      await this.#ue4ssBridge.execCommand(`Omegga.Bridge.BMF ${command}`);
      return null;
    };

    const runBridgeBookkeepingCommand = async () => {
      const bmfCommand = getBmfCommandFromOmeggaLine(normalizedLine);
      if (bmfCommand) {
        await execBmfCommand(bmfCommand);
        return true;
      }

      if (
        normalizedLine === 'Server.Status' &&
        this.#ue4ssBridge.hasCapability('server_status')
      ) {
        await this.#ue4ssBridge.requestServerStatus();
        return true;
      }

      if (normalizedLine === 'GetAll BRPlayerState UserName') {
        this.emitSyntheticPlayerStateUserNames();
        return true;
      }

      const syntheticOwnerMatch = normalizedLine.match(
        /^GetAll BRPlayerState Owner Name=(.+)$/,
      );
      if (syntheticOwnerMatch) {
        this.emitSyntheticPlayerStateOwner(syntheticOwnerMatch[1]);
        return true;
      }

      const allowUnsafePlayersList =
        process.env.OMEGGA_UE4SS_ALLOW_UNSAFE_PLAYERS_LIST === '1';
      if (
        allowUnsafePlayersList &&
        normalizedLine === 'GetAll BRPlayerState UserName' &&
        this.#ue4ssBridge.hasCapability('players_list')
      ) {
        await this.#ue4ssBridge.requestPlayers('usernames');
        return true;
      }

      const ownerMatch = normalizedLine.match(
        /^GetAll BRPlayerState Owner Name=(.+)$/,
      );
      if (
        allowUnsafePlayersList &&
        ownerMatch &&
        this.#ue4ssBridge.hasCapability('players_list')
      ) {
        await this.#ue4ssBridge.requestPlayers('owners', {
          stateName: ownerMatch[1],
        });
        return true;
      }

      const allowDegradedWorldCommands =
        process.env.OMEGGA_UE4SS_ALLOW_DEGRADED_WORLD_COMMANDS === '1';
      const forceWorldCommand = normalizedLine.match(
        /^Omegga\.Bridge\.ForceConsoleExecutor\s+(?:consolemanager|console)\s+((?:BR\.World\.(?:SaveAs|LoadAdditive)|Bricks\.(?:Save|SaveRegion|Load|ClearRegion))\b.*)$/,
      );
      const directWorldCommand = normalizedLine.match(
        /^(?:BR\.World\.(?:SaveAs|LoadAdditive)|Bricks\.(?:Save|SaveRegion|Load|ClearRegion))\b.*$/,
      );
      if (
        allowDegradedWorldCommands &&
        (forceWorldCommand || directWorldCommand)
      ) {
        const command = forceWorldCommand
          ? normalizedLine
          : `Omegga.Bridge.ForceConsoleExecutor consolemanager ${normalizedLine}`;
        await this.#ue4ssBridge.execCommand(command);
        return true;
      }

      const directEnvironmentCommand = normalizedLine.match(
        /^(Server\.Environment\.(?:LoadPreset|Reset)\b.*)$/i,
      );
      if (directEnvironmentCommand) {
        await this.#ue4ssBridge.execCommand(
          `Omegga.Bridge.ForceConsoleExecutor consolemanager ${directEnvironmentCommand[1]}`,
        );
        return true;
      }

      return false;
    };
    const allowUnsafePositionProbes =
      process.env.OMEGGA_UE4SS_ALLOW_UNSAFE_POSITION_PROBES === '1';
    const isDegradedSafePositionProbe =
      (allowUnsafePositionProbes &&
        /^GetAll BP_PlayerController_C Pawn Name=BP_PlayerController_C_\d+$/.test(
          normalizedLine,
        )) ||
      (allowUnsafePositionProbes &&
        /^GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=BP_FigureV2_C_\d+$/.test(
          normalizedLine,
        ));
    const requireConsoleCommandShape =
      env.OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE === '1';
    const looksLikeConsoleCommand =
      /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+(?:\s|$)/.test(
        normalizedLine,
      ) || /^(?:GetAll|ServerTravel|exit|quit)\b/i.test(normalizedLine);
    const buildInfo = readBrickadiaBuildInfo(
      getBrickadiaLogPath(
        this.path,
        this.config?.server?.savedDir ?? CONFIG_SAVED_DIR,
      ),
    );

    if (
      this.#ue4ssCompatibilityCl &&
      buildInfo.cl &&
      buildInfo.cl !== this.#ue4ssCompatibilityCl
    ) {
      const reason =
        `Detected Brickadia build CL${buildInfo.cl}, but the installed UE4SS compatibility bundle ` +
        `${this.#ue4ssCompatibilityBundleId ?? 'unknown'} targets CL${this.#ue4ssCompatibilityCl}.`;
      this.handleUe4ssDegraded(reason);
      throw new Error(reason);
    }

    const tryTypedChatCommand = async (): Promise<boolean> => {
      const decodeConsoleChatText = (value: string) => {
        const trimmed = value.trim();
        if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
          try {
            const parsed = JSON.parse(trimmed);
            if (typeof parsed === 'string') return parsed;
          } catch (_error) {
            return value;
          }
        }
        return value;
      };
      const shouldRouteBmfChat = process.env.OMEGGA_BMF_CHAT_BRIDGE !== '0';
      const routeBmfChatCommand = (command: string) =>
        execBmfCommand(command, {
          timeoutMs: Number(
            process.env.OMEGGA_BMF_CHAT_SOCKET_TIMEOUT_MS || 1200,
          ),
          fallbackLogLabel:
            'BMF chat socket bridge failed; falling back to file bridge',
        });

      const broadcastMatch = normalizedLine.match(/^Chat\.Broadcast\s+(.+)$/);
      if (broadcastMatch && shouldRouteBmfChat) {
        const message = decodeConsoleChatText(broadcastMatch[1]);
        try {
          await routeBmfChatCommand(
            `bmf.chat.broadcast message=${encodeBmfCommandArg(message)}`,
          );
        } catch (error) {
          Logger.warnp(
            'BMF chat broadcast bridge failed'.yellow,
            error instanceof Error ? error.message : String(error),
          );
        }
        return true;
      }
      if (broadcastMatch && this.#ue4ssBridge.hasCapability('chat_broadcast')) {
        await this.#ue4ssBridge.broadcast(
          decodeConsoleChatText(broadcastMatch[1]),
        );
        return true;
      }

      const whisperMatch = normalizedLine.match(
        /^Chat\.Whisper\s+"([^"]+)"\s+(.+)$/,
      );
      if (whisperMatch && shouldRouteBmfChat) {
        const target = whisperMatch[1];
        const message = decodeConsoleChatText(whisperMatch[2]);
        try {
          await routeBmfChatCommand(
            `bmf.chat.whisper target=${encodeBmfCommandArg(target)} message=${encodeBmfCommandArg(message)}`,
          );
        } catch (error) {
          Logger.warnp(
            'BMF chat whisper bridge failed'.yellow,
            error instanceof Error ? error.message : String(error),
          );
        }
        return true;
      }
      if (whisperMatch && this.#ue4ssBridge.hasCapability('chat_whisper')) {
        await this.#ue4ssBridge.whisper(
          whisperMatch[1],
          decodeConsoleChatText(whisperMatch[2]),
        );
        return true;
      }

      const statusMessageMatch = normalizedLine.match(
        /^Chat\.StatusMessage\s+"([^"]+)"\s+(.+)$/,
      );
      if (statusMessageMatch && shouldRouteBmfChat) {
        const target = statusMessageMatch[1];
        const message = decodeConsoleChatText(statusMessageMatch[2]);
        try {
          await routeBmfChatCommand(
            `bmf.chat.statusmessage target=${encodeBmfCommandArg(target)} message=${encodeBmfCommandArg(message)}`,
          );
        } catch (error) {
          Logger.warnp(
            'BMF chat status bridge failed'.yellow,
            error instanceof Error ? error.message : String(error),
          );
        }
        return true;
      }
      if (
        statusMessageMatch &&
        this.#ue4ssBridge.hasCapability('chat_status_message')
      ) {
        await this.#ue4ssBridge.statusMessage(
          statusMessageMatch[1],
          decodeConsoleChatText(statusMessageMatch[2]),
        );
        return true;
      }

      return false;
    };

    try {
      if (await runBridgeBookkeepingCommand()) {
        return;
      }

      if (await tryTypedChatCommand()) {
        return;
      }

      const allowMinigameGetAll =
        env.OMEGGA_UE4SS_ALLOW_MINIGAME_GETALL === '1' &&
        isAllowedMinigameGetAllCommand(normalizedLine);
      const noopUnsafeConsoleCommands =
        env.OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS === '1' ||
        this.#ue4ssStagedObjectControlOverride;
      if (noopUnsafeConsoleCommands && /^Chat\./i.test(normalizedLine)) {
        Logger.warnp(
          'UE4SS bridge skipped unsafe chat console command'.yellow,
          normalizedLine,
        );
        return;
      }
      if (
        noopUnsafeConsoleCommands &&
        /^GetAll\s+/i.test(normalizedLine) &&
        !allowMinigameGetAll &&
        !isDegradedSafePositionProbe
      ) {
        Logger.verbose(
          'UE4SS bridge skipping unsafe console probe',
          normalizedLine,
        );
        return;
      }

      if (requireConsoleCommandShape && !looksLikeConsoleCommand) {
        Logger.verbose(
          'UE4SS bridge skipping non-command line',
          normalizedLine,
        );
        return;
      }

      if (
        this.#ue4ssStagedObjectControlOverride &&
        STAGED_PLAYER_MUTATION_COMMAND.test(normalizedLine)
      ) {
        Logger.warnp(
          'UE4SS bridge skipped staged player mutation command'.yellow,
          normalizedLine,
        );
        return;
      }

      if (!this.#ue4ssCompatibilityValidated) {
        if (isDegradedSafePositionProbe) {
          await this.#ue4ssBridge.execCommand(normalizedLine);
          return;
        }

        const reason = [
          `Brickadia UE4SS compatibility bundle ${this.#ue4ssCompatibilityBundleId ?? 'unknown'} is staged but not validated.`,
          'Windows object-dependent control is paused until the baseline passes.',
          this.#ue4ssCompatibilityReportPath
            ? `See ${this.#ue4ssCompatibilityReportPath}.`
            : null,
        ]
          .filter(Boolean)
          .join(' ');
        this.handleUe4ssDegraded(reason);
        throw new Error(reason);
      }

      await this.#ue4ssBridge.execCommand(normalizedLine);
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      this.handleUe4ssDegraded(reason);

      if (/^Chat\.(?:Broadcast|Whisper|StatusMessage)\b/.test(normalizedLine)) {
        Logger.warn('UE4SS chat delivery failed', reason);
        return;
      }

      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async execControlCommandWithOutput(
    command: string,
    timeoutMs = WINDOWS_UE4SS_READY_TIMEOUT_MS,
  ) {
    if (!IS_WINDOWS || this.#windowsBackend !== 'ue4ss' || !this.#ue4ssBridge) {
      await this.writelnAsync(command);
      return null;
    }

    const normalizedCommand = command.replace(/\r?\n$/, '');
    if (normalizedCommand === 'GetAll BRPlayerState UserName') {
      return this.buildSyntheticControlOutput(
        normalizedCommand,
        'synthetic-brplayerstate-username',
        this.getSyntheticPlayerStateUserNameLines(),
      );
    }

    const syntheticOwnerMatch = normalizedCommand.match(
      /^GetAll BRPlayerState Owner Name=(.+)$/,
    );
    if (syntheticOwnerMatch) {
      return this.buildSyntheticControlOutput(
        normalizedCommand,
        'synthetic-brplayerstate-owner',
        this.getSyntheticPlayerStateOwnerLines(syntheticOwnerMatch[1]),
      );
    }

    const bmfCommand = getBmfCommandFromOmeggaLine(normalizedCommand);
    if (bmfCommand) {
      if (this.#bmfSocketBridge?.hasBmfClients) {
        try {
          const response = await this.#bmfSocketBridge.execCommand(
            bmfCommand,
            timeoutMs,
          );
          return response.response ?? '';
        } catch (error) {
          Logger.warnp(
            'BMF socket command with output failed; falling back to file bridge'
              .yellow,
            error instanceof Error ? error.message : String(error),
          );
        }
      }

      return this.#ue4ssBridge.execCommandWithOutput(
        `Omegga.Bridge.BMF ${bmfCommand}`,
        timeoutMs,
      );
    }

    return this.#ue4ssBridge.execCommandWithOutput(command, timeoutMs);
  }

  getActiveWorldFile(): string {
    return path.join(this.path, ACTIVE_WORLD_FILE);
  }

  /** A world specified by the active world file */
  getActiveWorld(): string | null {
    const activeWorldFile = this.getActiveWorldFile();
    if (existsSync(activeWorldFile)) {
      try {
        return readFileSync(activeWorldFile, 'utf8').trim();
      } catch (err) {
        Logger.errorp(
          'Failed to read active world file',
          activeWorldFile.yellow,
          err,
        );
        return null;
      }
    }
    return null;
  }

  /** Set the world to use next startup */
  setActiveWorld(world: string | null): boolean {
    const activeWorldFile = this.getActiveWorldFile();
    if (!world || world === null) {
      if (existsSync(activeWorldFile)) {
        Logger.verbose('Removing active world file', activeWorldFile.yellow);
        unlinkSync(activeWorldFile);
      }
      return true;
    }

    if (!this.worldExists(world)) {
      Logger.verbose(
        'Cannot set active world to',
        world.yellow,
        'as it does not exist',
      );
      return false;
    }

    Logger.verbose('Setting active world to', world.yellow);
    try {
      writeFileSync(activeWorldFile, world, 'utf8');
      return true;
    } catch (err) {
      Logger.errorp(
        'Failed to write active world file',
        activeWorldFile.yellow,
        err,
      );
      return false;
    }
  }

  /** A world specified by the config */
  getConfigWorld(): string | null {
    return this.config?.server?.world ?? null;
  }

  /** A world specified by the BRICKADIA_WORLD env variable */
  getEnvWorld(): string | null {
    return env.BRICKADIA_WORLD || null;
  }

  /** Check if a world exists */
  worldExists(world: string): boolean {
    const savedDir = this.config?.server?.savedDir ?? CONFIG_SAVED_DIR;
    const worldPath = path.join(this.path, savedDir, 'Worlds', world + '.brdb');
    return existsSync(worldPath);
  }

  /** Get the world that will be used next startup */
  getNextWorld() {
    const candidates = [
      { source: 'file', file: this.getActiveWorld() },
      { source: 'config', file: this.getConfigWorld() },
      { source: 'env', file: this.getEnvWorld() },
    ];

    return (
      candidates.find(({ file }) => file && this.worldExists(file)) ?? null
    );
  }

  // start the server child process
  async start() {
    const {
      email,
      password,
      token: confToken,
    }: { email?: string; password?: string; token?: string } = this.config
      .credentials || {};

    const token = confToken || process.env.BRICKADIA_TOKEN || getGlobalToken();

    if (token) {
      Logger.verbose('Starting server with hosting token');
    } else {
      Logger.verbose(
        'Starting server',
        (!email && !password ? 'without' : 'with').yellow,
        'credentials',
      );
    }

    const { gameBinary, isSteam, overrideBinary, steamBinary, steamBeta } =
      resolveGameBinary(this.config);

    if (overrideBinary) {
      if (!existsSync(overrideBinary)) {
        Logger.error(
          'Override binary',
          overrideBinary.yellow,
          'does not exist!',
        );
        throw new Error(`Override binary ${overrideBinary} does not exist!`);
      }

      Logger.verbose(
        'Using override binary',
        overrideBinary.yellow,
        'instead of',
        steamBinary.yellow,
      );
    } else if (isSteam) {
      Logger.verbose('Using steam binary', steamBeta.yellow);
    } else {
      if (IS_WINDOWS) {
        throw new Error(
          'Legacy launcher branches are not supported on Windows. Use SteamCMD or BRICKADIA_DIR.',
        );
      }

      Logger.verbose(
        'Running',
        (this.config.server.__LOCAL
          ? path.join(__dirname, '../../tools/brickadia.sh')
          : 'brickadia launcher'
        ).yellow,
      );
      if (typeof this.config.server.branch === 'string')
        Logger.verbose('Using branch', this.config.server.branch.yellow);
    }

    const command = isSteam
      ? gameBinary
      : this.config.server.__LOCAL
        ? path.join(__dirname, '../../tools/brickadia.sh')
        : 'brickadia';
    const launchArgs = isSteam
      ? []
      : [
          this.config.server.branch && `--branch=${this.config.server.branch}`,
          '--server',
          '--',
        ];

    const world = this.getNextWorld();
    if (world) {
      Logger.verbose(
        'Using world',
        world.file.yellow,
        'from',
        world.source.yellow,
      );
    } else if (this.config.server.map) {
      Logger.verbose('Using map', this.config.server.map.yellow, 'from config');
    }

    const gameArgs = [
      !world &&
        this.config.server.map &&
        `-Environment="${this.config.server.map}"`,
      world && `-World="${world.file}"`,
      '-NotInstalled',
      IS_WINDOWS ? '-stdout' : null,
      IS_WINDOWS ? '-FullStdOutLogOutput' : null,
      '-log',
      checkWsl() === 1 ? '-OneThread' : null,
      this.path ? `-UserDir="${this.path}"` : null,
      token ? `-Token="${token}"` : null, // remove token argument if not provided
      !token && email ? `-User="${email}"` : null, // remove email argument if not provided or token is provided
      !token && password ? `-Password="${password}"` : null, // remove password argument if not provided or token is provided
      `-port="${this.config.server.port}"`,
      this.config.server.launchArgs,
    ].filter(Boolean); // remove unused arguments
    const params = [...launchArgs, ...gameArgs];

    Logger.verbose(
      'Params for spawn',
      [command, ...params]
        .join(' ')
        .replace(/-User=".*?"/, '-User="<hidden>"')
        .replace(/-Password=".*?"/, '-Password="<hidden>"')
        .replace(/-Token=".*?"/, '-Token="<hidden>"'),
    );

    this.cleanupWindowsControl();
    this.cleanupUe4ssBridge();
    this.cleanupBmfSocketBridge();
    this.#windowsBackend = IS_WINDOWS ? resolveWindowsControlBackend() : null;
    this.#windowsControlPort =
      IS_WINDOWS && this.#windowsBackend === 'bridge'
        ? this.getWindowsControlPort()
        : null;
    this.#ue4ssWin64Dir = IS_WINDOWS ? path.dirname(command) : null;
    this.#syntheticLogCounter = 0;
    this.#ue4ssDegraded = false;
    this.#ue4ssCompatibilityValidated = true;
    this.#ue4ssCompatibilityBundleId = null;
    this.#ue4ssCompatibilityCl = null;
    this.#ue4ssCompatibilityReportPath = null;
    this.#ue4ssStagedObjectControlOverride = false;

    let spawnCommand = 'stdbuf';
    let spawnArgs = ['--output=L', '--', command, ...params];
    const spawnEnv = { ...process.env };

    if (IS_WINDOWS && this.#windowsBackend === 'ue4ss') {
      const install = installManagedUe4ss(this.#ue4ssWin64Dir);
      const allowStagedObjectControl =
        env.OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL === '1';
      this.#ue4ssStagedObjectControlOverride =
        !install.compatibilityBundle.manifest.validated &&
        allowStagedObjectControl;
      this.#ue4ssCompatibilityValidated =
        install.compatibilityBundle.manifest.validated ||
        allowStagedObjectControl;
      this.#ue4ssCompatibilityBundleId = install.compatibilityBundle.bundleId;
      this.#ue4ssCompatibilityCl =
        install.compatibilityBundle.manifest.brickadia_cl;
      this.#ue4ssCompatibilityReportPath =
        install.compatibilityBundle.validationReportMarkdownPath;
      Logger.verbose(
        'Using Windows control backend',
        'ue4ss'.yellow,
        'from',
        install.sourceRoot.yellow,
      );
      Logger.verbose(
        'Using Brickadia UE4SS compatibility bundle',
        `${install.compatibilityBundle.bundleId} (${install.compatibilityBundle.manifest.validated ? 'validated' : allowStagedObjectControl ? 'staged, local override' : 'staged'})`
          .yellow,
      );
      if (this.#ue4ssStagedObjectControlOverride) {
        Logger.warnp(
          'Brickadia UE4SS compatibility bundle'.yellow,
          install.compatibilityBundle.bundleId.yellow,
          'is staged but local object control is enabled by OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL=1.',
        );
      } else if (!this.#ue4ssCompatibilityValidated) {
        Logger.warnp(
          'Brickadia UE4SS compatibility bundle'.yellow,
          install.compatibilityBundle.bundleId.yellow,
          'is staged but not validated. Windows object-dependent control stays degraded until',
          install.compatibilityBundle.validationReportMarkdownPath.yellow,
          'passes the baseline gates.',
        );
      }

      this.#ue4ssBridge = new Ue4ssBridgeHost(
        path.join(this.path, 'ue4ss-bridge'),
      );
      this.#ue4ssBridge.on('ready', info => {
        Logger.verbose('UE4SS bridge ready', info);
        this.emit('control:ready', {
          backend: 'ue4ss',
          transport: info.transport ?? 'file',
          capabilities: this.#ue4ssBridge.capabilities,
        });
      });
      this.#ue4ssBridge.on('capabilities', capabilities => {
        Logger.verbose('UE4SS bridge capabilities', capabilities);
      });
      this.#ue4ssBridge.on('log', payload => {
        const message =
          typeof payload === 'string'
            ? payload
            : String(
                (payload as { message?: string })?.message ??
                  JSON.stringify(payload),
              );
        Logger.verbose('UE4SS bridge', message);
        this.emit('control:log', { backend: 'ue4ss', payload });
      });
      this.#ue4ssBridge.on('console.chunk', payload => {
        if (typeof payload.line === 'string' && payload.line.length > 0) {
          this.emitSyntheticConsoleLine(payload.line);
        }
      });
      this.#ue4ssBridge.on('console.complete', payload => {
        this.emit('control:complete', { backend: 'ue4ss', payload });
      });

      Object.assign(spawnEnv, this.#ue4ssBridge.start());
      if (env.OMEGGA_BMF_SOCKET_ENABLED !== '0') {
        this.#bmfSocketBridge = new BmfSocketBridgeHost();
        this.#bmfSocketBridge.on('ready', info => {
          Logger.logp(
            'BMF socket bridge ready',
            `${info.host}:${info.port}`.yellow,
          );
        });
        this.#bmfSocketBridge.on('client', info => {
          Logger.verbose('BMF socket bridge client', info);
        });
        this.#bmfSocketBridge.on('log', payload => {
          const message =
            typeof payload === 'string'
              ? payload
              : String(
                  (payload as { message?: string })?.message ??
                    JSON.stringify(payload),
                );
          const level = (payload as { level?: string })?.level;
          if (level === 'error') {
            Logger.errorp('BMF socket bridge', message);
          } else if (level === 'warn') {
            Logger.warnp('BMF socket bridge', message);
          } else {
            Logger.verbose('BMF socket bridge', message);
          }
        });
        const bmfSocketEnv = await this.#bmfSocketBridge.start();
        Object.assign(spawnEnv, bmfSocketEnv);
        Object.assign(process.env, bmfSocketEnv);
      }
      spawnCommand = command;
      spawnArgs = params;
    } else if (IS_WINDOWS) {
      Logger.verbose(
        'Using Windows control backend',
        'bridge'.yellow,
        '(legacy fallback)',
      );
      spawnCommand = ensureWindowsConsoleBridgeBinary();
      spawnArgs = [
        '--control-port',
        String(this.#windowsControlPort),
        '--cwd',
        process.cwd(),
        '--',
        command,
        ...params,
      ];
    }

    Logger.verbose(
      'Spawn command',
      [spawnCommand, ...spawnArgs]
        .join(' ')
        .replace(/-User=".*?"/, '-User="<hidden>"')
        .replace(/-Password=".*?"/, '-Password="<hidden>"')
        .replace(/-Token=".*?"/, '-Token="<hidden>"'),
    );

    this.#child = spawn(spawnCommand, spawnArgs, {
      stdio: 'pipe',
      windowsHide: IS_WINDOWS,
      env: spawnEnv,
    });

    Logger.verbose(
      'Spawn process',
      this.#child ? this.#child.pid : 'failed'.red,
    );
    if (!this.#child)
      throw new Error('Failed to spawn Brickadia server process');

    this.#child.stdin.setDefaultEncoding('utf8');
    if (IS_WINDOWS && this.#windowsBackend === 'bridge')
      this.connectWindowsControlSocket(this.#windowsControlPort);
    this.#outInterface = readline.createInterface({
      input: this.#child.stdout,
      terminal: false,
    });
    this.#errInterface = readline.createInterface({
      input: this.#child.stderr,
      terminal: false,
    });
    this.attachListeners();
    Logger.verbose('Attached listeners');

    if (IS_WINDOWS && this.#windowsBackend === 'ue4ss' && this.#ue4ssBridge) {
      void this.#ue4ssBridge
        .waitUntilReady(WINDOWS_UE4SS_READY_TIMEOUT_MS)
        .catch(error =>
          this.handleUe4ssDegraded(
            error instanceof Error ? error.message : String(error),
          ),
        );
    }
  }

  // write a string to the child process
  async writeAsync(line: string) {
    const runWrite = async () => {
      if (line.length >= 512) {
        // show a warning
        Logger.warn(
          'WARNING'.yellow,
          'The following line was called and is',
          'longer than allowed limit'.red,
        );
        Logger.warn(line.replace(/\n$/, ''));
        // throw a fake error to get the line number
        try {
          throw new Error('Console Line Too Long');
        } catch (err) {
          Logger.warn(err);
        }
        return;
      }

      if (this.#child) {
        Logger.verbose('WRITE'.green, line.replace(/\n$/, ''));
        if (IS_WINDOWS) {
          if (this.#windowsBackend === 'ue4ss') {
            await this.writeToUe4ssControl(line);

            const spacingMs = getWindowsUe4ssWriteSpacingMs();
            if (spacingMs > 0) await delay(spacingMs);
          } else {
            this.writeToWindowsControl(line);
          }
        } else {
          this.#child.stdin.write(line);
        }
      }
    };

    const queuedWrite = this.#writeQueue.then(runWrite, runWrite);
    this.#writeQueue = queuedWrite.catch(() => {});
    return queuedWrite;
  }

  write(line: string) {
    void this.writeAsync(line).catch(() => {});
  }

  // write a line to the child process
  async writelnAsync(line: string) {
    await this.writeAsync(line + '\n');
  }

  writeln(line: string) {
    this.write(line + '\n');
  }

  // forcibly kills the server
  stop() {
    if (!this.#child) {
      Logger.verbose('Cannot stop server as no subprocess exists');
      return;
    }

    Logger.verbose('Stopping server process');
    if (IS_WINDOWS && this.#windowsBackend === 'ue4ss') {
      if (this.#ue4ssBridge) {
        void this.#ue4ssBridge
          .execCommand('exit', 2000)
          .catch(error =>
            Logger.verbose(
              'UE4SS exit command failed',
              error instanceof Error ? error.message : String(error),
            ),
          );
      }
      void terminateChildProcess(this.#child, {
        forceAfterMs: 5000,
        immediateSignal: false,
      });
    } else if (IS_WINDOWS) {
      this.requestWindowsShutdown();
      void terminateChildProcess(this.#child, {
        forceAfterMs: 5000,
        immediateSignal: false,
      });
    } else {
      void terminateChildProcess(this.#child, {
        gracefulLine: 'exit',
        forceAfterMs: 5000,
        immediateSignal: false,
      });
    }
  }

  // detaches listeners
  cleanup() {
    if (!this.#child) return;

    Logger.verbose('Cleaning up brickadia server');

    // detach listener
    this.detachListeners();
    this.cleanupWindowsControl();
    this.cleanupUe4ssBridge();
    this.cleanupBmfSocketBridge();
    this.#windowsBackend = null;
    this.#ue4ssWin64Dir = null;
    this.#ue4ssCompatibilityValidated = true;
    this.#ue4ssCompatibilityBundleId = null;
    this.#ue4ssCompatibilityCl = null;
    this.#ue4ssCompatibilityReportPath = null;

    this.#child = null;
    this.#outInterface = null;
    this.#errInterface = null;
  }

  // attaches proxy event listeners
  attachListeners() {
    this.#outInterface.on('line', this.lineListener);
    this.#errInterface.on('line', this.errorListener);
    this.#child.on('exit', this.exitListener);
    this.#child.on('close', () => {});
  }

  // removes previously attached proxy event listeners
  detachListeners() {
    this.#outInterface.off('line', this.lineListener);
    this.#errInterface.off('line', this.errorListener);
    this.#child.off('exit', this.exitListener);
    this.#child.removeAllListeners('close');
  }

  // -- listeners for basic events (line, err, exit)
  errorListener(line: string) {
    Logger.verbose('ERROR'.red, line);
    this.emit('err', line);
    for (const { match, solution, name, message } of knownErrors) {
      if (line.match(match)) {
        Logger.error(
          `Encountered ${name.red}. ${
            solution ? 'Known fix:\n  ' + solution : message || 'Unknown error.'
          }`,
        );
      }
    }
  }

  exitListener(...args: any[]) {
    Logger.verbose('Exit listener fired');
    this.emit('closed', ...args);
    this.cleanup();
  }

  lineListener(line: string) {
    this.emit('line', stripAnsi(line));
  }
}
