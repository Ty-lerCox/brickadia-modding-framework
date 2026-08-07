import {
  OmeggaCore,
  OmeggaLike,
  OmeggaPlayer,
  PluginInterop,
  WatcherPattern,
} from '@/plugin';
import { EnvironmentPreset } from '@brickadia/presets';
import {
  BRBanList,
  BRPlayerNameCache,
  BRRoleAssignments,
  BRRoleSetup,
} from '@brickadia/types';
import commandInjector from '@omegga/commandInjector';
import LogWrangler from '@omegga/logWrangler';
import Player from '@omegga/player';
import Omegga from '@omegga/server';
import {
  ILogMinigame,
  IMinigameList,
  IPlayerPositions,
  IServerStatus,
} from '@omegga/types';
import { ReadSaveObject, WriteSaveObject } from 'brs-js';
import EventEmitter from 'events';

// bootstrap the proxy with initial omegga data
export const bootstrap = (omegga: Omegga): Record<string, unknown[]> => ({
  'plugin:players:raw': [omegga.players.map(p => p.raw())],
  bootstrap: [
    {
      host: Object.freeze({ ...omegga.host }),
      version: omegga.version,
      verbose: omegga.verbose,
      savePath: omegga.savePath,
      worldPath: omegga.worldPath,
      prefabPath: omegga.prefabPath,
      path: omegga.path,
      configPath: omegga.configPath,
      presetPath: omegga.presetPath,
      starting: omegga.starting,
      started: omegga.started,
      stopping: omegga.stopping,
      config: omegga.config,
      currentMap: omegga.currentMap,
    },
  ],
});

// prototypes that can be directly stolen from omegga
const STEAL_PROTOTYPES: Partial<Record<keyof Required<OmeggaCore>, true>> = {
  broadcast: true,
  getPlayer: true,
  findPlayerByName: true,
  getHostId: true,
  clearBricks: true,
  clearRegion: true,
  clearAllBricks: true,
  loadBricks: true,
  loadBricksOnPlayer: true,
  saveBricks: true,
  saveBricksAsync: true,
  getSavePath: true,
  getSaves: true,
  getWorldPath: true,
  getWorlds: true,
  getWorldRevisions: true,
  loadWorld: true,
  loadWorldRevision: true,
  saveWorldAs: true,
  saveWorld: true,
  createEmptyWorld: true,
  writeSaveData: true,
  readSaveData: true,
  loadSaveData: true,
  loadSaveDataOnPlayer: true,
  getSaveData: true,
  getRoleSetup: true,
  getRoleAssignments: true,
  getBanList: true,
  getNameCache: true,
  changeMap: true,
  saveMinigame: true,
  deleteMinigame: true,
  resetMinigame: true,
  nextRoundMinigame: true,
  loadMinigame: true,
  getMinigamePresets: true,
  resetEnvironment: true,
  saveEnvironment: true,
  readEnvironmentData: true,
  getEnvironmentData: true,
  loadEnvironment: true,
  loadEnvironmentData: true,
  getEnvironmentPresets: true,
};

const badBorrow = (name: string) =>
  new Error(`Method "${name}" not properly borrowed.`);

// this is a "soft" omegga
// it is built to mimic the core omegga
// it does not provide direct write access to
export class ProxyOmegga extends EventEmitter implements OmeggaLike {
  _tempCounter = { save: 0, environment: 0 };
  _tempSavePrefix = 'omegga_plugin_temp_';

  writeln: (line: string) => void;
  version: number;
  players: Player[];

  host: { id: string; name: string };

  verbose: boolean;

  started: boolean;
  starting: boolean;
  stopping: boolean;
  currentMap: string;

  reportJoinCorrelationPhase?: (record: Record<string, unknown>) => void;
  reportJoinAttributionOperation?: (record: Record<string, unknown>) => void;
  private readonly joinListenerWrappers = new WeakMap<
    (...args: any[]) => any,
    (...args: any[]) => any
  >();
  private joinListenerSequence = 0;

  private instrumentJoinListener(listener: (...args: any[]) => any) {
    if (!this.reportJoinCorrelationPhase) return listener;
    const existing = this.joinListenerWrappers.get(listener);
    if (existing) return existing;
    const callback = listener.name || `callback_${++this.joinListenerSequence}`;
    const wrapped = (...args: any[]) => {
      const context =
        args[1] && typeof args[1] === 'object' && !Array.isArray(args[1])
          ? args[1]
          : undefined;
      const correlationId = String(context?.correlationId ?? '');
      if (!/^join-[A-Za-z0-9-]{1,90}$/.test(correlationId)) {
        return listener(...args);
      }
      const startedAtUnixMs = Date.now();
      const finish = (outcome: 'ok' | 'error') =>
        this.reportJoinCorrelationPhase?.({
          correlationId,
          phase: 'plugin_join_callback',
          outcome,
          startedAtUnixMs,
          endedAtUnixMs: Date.now(),
          callback,
        });
      try {
        const result = listener(...args);
        if (result && typeof result.then === 'function') {
          void Promise.resolve(result).then(
            () => finish('ok'),
            () => finish('error'),
          );
        } else {
          finish('ok');
        }
        return result;
      } catch (error) {
        finish('error');
        throw error;
      }
    };
    this.joinListenerWrappers.set(listener, wrapped);
    return wrapped;
  }

  override on(eventName: string | symbol, listener: (...args: any[]) => any) {
    return super.on(
      eventName,
      eventName === 'join' ? this.instrumentJoinListener(listener) : listener,
    );
  }

  override addListener(
    eventName: string | symbol,
    listener: (...args: any[]) => any,
  ) {
    return super.addListener(
      eventName,
      eventName === 'join' ? this.instrumentJoinListener(listener) : listener,
    );
  }

  override removeListener(
    eventName: string | symbol,
    listener: (...args: any[]) => any,
  ) {
    const wrapped =
      eventName === 'join'
        ? this.joinListenerWrappers.get(listener)
        : undefined;
    return super.removeListener(eventName, wrapped ?? listener);
  }

  override off(eventName: string | symbol, listener: (...args: any[]) => any) {
    return this.removeListener(eventName, listener);
  }

  path: string;
  configPath: string;
  savePath: string;
  worldPath: string;
  prefabPath: string;
  presetPath: string;

  logWrangler: LogWrangler;

  getPlugin: (name: string) => Promise<PluginInterop>;
  writelnAsync: (line: string) => Promise<void>;
  execControlCommandWithOutput: (
    command: string,
    timeoutMs?: number,
  ) => Promise<unknown>;
  privateWhisperTransport: (
    target: string | OmeggaPlayer,
    messages: string[],
  ) => Promise<void>;
  privateMiddlePrintTransport: (
    target: string | OmeggaPlayer,
    message: string,
  ) => Promise<void>;

  constructor(
    exec: (line: string) => void,
    execControlCommandWithOutput?: (
      command: string,
      timeoutMs?: number,
    ) => Promise<unknown>,
    privateWhisperTransport?: (
      target: string | OmeggaPlayer,
      messages: string[],
    ) => Promise<void>,
    privateMiddlePrintTransport?: (
      target: string | OmeggaPlayer,
      message: string,
    ) => Promise<void>,
  ) {
    super();
    this.setMaxListeners(Infinity);

    this.writeln = exec;
    this.writelnAsync = (line: string) => Promise.resolve(exec(line));
    this.execControlCommandWithOutput =
      execControlCommandWithOutput ??
      (() => Promise.reject(badBorrow('execControlCommandWithOutput')));
    this.privateWhisperTransport =
      privateWhisperTransport ??
      (() => Promise.reject(badBorrow('privateWhisperTransport')));
    this.privateMiddlePrintTransport =
      privateMiddlePrintTransport ??
      (() => Promise.reject(badBorrow('privateMiddlePrintTransport')));

    this.version = -1;

    this.players = [];

    // log wrangler wrangles logs... it reads brickadia logs and clumps them together
    this.logWrangler = new LogWrangler(this as unknown as Omegga);
    this.on('line', this.logWrangler.callback);
    this.addMatcher = this.logWrangler.addMatcher;
    this.addWatcher = this.logWrangler.addWatcher;
    this.watchLogArray = this.logWrangler.watchLogArray;
    this.watchLogChunk = this.logWrangler.watchLogChunk;

    // inject commands
    commandInjector(this, this.logWrangler);

    // blanket apply fields
    this.once('bootstrap', data => {
      for (const key in data) {
        (this as any)[key] = data[key];
      }
    });

    // data synchronization
    this.on('host', host => (this.host = host));
    this.on('version', version => (this.version = version));

    // create players from raw constructor data
    this.on(
      'plugin:players:raw',
      (players: [string, string, string, string, string, number][]) =>
        (this.players = players.map(p => new Player(this as OmeggaLike, ...p))),
    );

    this.on('start', ({ map }) => {
      this.started = true;
      this.starting = false;
      this.currentMap = map;
    });
    this.on('exit', () => {
      this.started = false;
      this.starting = false;
    });
    this.on('mapchange', ({ map }) => {
      this.currentMap = map;
    });
  }
  addMatcher<T>(
    pattern: RegExp | ((line: string, match: RegExpMatchArray) => T),
    callback:
      | ((match: RegExpMatchArray) => boolean)
      | ((match: RegExpMatchArray) => T),
  ): void {
    throw badBorrow('addMatcher');
  }
  addWatcher<T = RegExpMatchArray>(
    pattern: RegExp | WatcherPattern<T>,
    options?: {
      timeoutDelay?: number;
      bundle?: boolean;
      debounce?: boolean;
      afterMatchDelay?: number;
      last?: (match: T) => boolean;
      exec?: () => void;
    },
  ): Promise<RegExpMatchArray[] | T[]> {
    throw badBorrow('addWatcher');
  }
  watchLogChunk<T = string>(
    cmd: string,
    pattern: RegExp | WatcherPattern<T>,
    options?: {
      first?: 'index' | ((match: T) => boolean);
      last?: (match: T) => boolean;
      afterMatchDelay?: number;
      timeoutDelay?: number;
    },
  ): Promise<RegExpMatchArray[] | T[]> {
    throw badBorrow('watchLogChunk');
  }
  watchLogArray<
    Item extends Record<string, string> = Record<string, string>,
    Member extends Record<string, string> = Record<string, string>,
  >(
    cmd: string,
    itemPattern: RegExp,
    memberPattern: RegExp,
  ): Promise<{ item: Item; members: Member[] }[]> {
    throw badBorrow('watchLogArray');
  }
  getServerStatus(): Promise<IServerStatus> {
    throw badBorrow('getServerStatus');
  }
  listMinigames(): Promise<IMinigameList> {
    throw badBorrow('listMinigames');
  }
  getAllPlayerPositions(): Promise<IPlayerPositions> {
    throw badBorrow('getAllPlayerPositions');
  }
  getMinigames(): Promise<ILogMinigame[]> {
    throw badBorrow('getMinigames');
  }
  getPlayers(): {
    id: string;
    name: string;
    displayName: string;
    controller: string;
    state: string;
    connectionGeneration: number;
  }[] {
    return this.players.map(player => ({
      id: player.id,
      name: player.name,
      displayName: player.displayName,
      controller: player.controller,
      state: player.state,
      connectionGeneration: player.connectionGeneration,
    }));
  }
  getPlayer(target: string): OmeggaPlayer {
    throw badBorrow('getPlayer');
  }
  findPlayerByName(name: string): OmeggaPlayer {
    throw badBorrow('findPlayerByName');
  }
  getHostId(): string {
    throw badBorrow('getHostId');
  }
  broadcast(...messages: string[]): void {
    throw badBorrow('broadcast');
  }
  async whisper(
    target: string | OmeggaPlayer,
    ...messages: string[]
  ): Promise<void> {
    await this.privateWhisperTransport(target, messages);
  }
  async middlePrint(
    target: string | OmeggaPlayer,
    message: string,
  ): Promise<void> {
    await this.privateMiddlePrintTransport(target, message);
  }
  saveMinigame(index: number, name: string): void {
    throw badBorrow('saveMinigame');
  }
  deleteMinigame(index: number): void {
    throw badBorrow('deleteMinigame');
  }
  resetMinigame(index: number): void {
    throw badBorrow('resetMinigame');
  }
  nextRoundMinigame(index: number): void {
    throw badBorrow('nextRoundMinigame');
  }
  loadMinigame(presetName: string, owner?: string): void {
    throw badBorrow('loadMinigame');
  }
  getMinigamePresets(): string[] {
    throw badBorrow('getMinigamePresets');
  }
  resetEnvironment(): void {
    throw badBorrow('resetEnvironment');
  }
  saveEnvironment(presetName: string): Promise<void> {
    throw badBorrow('saveEnvironment');
  }
  getEnvironmentData(): Promise<EnvironmentPreset> {
    throw badBorrow('getEnvironmentData');
  }
  loadEnvironment(presetName: string): void {
    throw badBorrow('loadEnvironment');
  }
  readEnvironmentData(presetName: string): void {
    throw badBorrow('readEnvironmentData');
  }
  loadEnvironmentData(preset: EnvironmentPreset): void {
    throw badBorrow('loadEnvironmentData');
  }
  getEnvironmentPresets(): string[] {
    throw badBorrow('getEnvironmentPresets');
  }
  clearBricks(target: string | { id: string }, quiet?: boolean): void {
    throw badBorrow('clearBricks');
  }
  clearRegion(
    region: {
      center: [number, number, number];
      extent: [number, number, number];
    },
    options: {
      target: string | OmeggaPlayer;
    },
  ): void {
    throw badBorrow('clearRegion');
  }
  clearAllBricks(quiet?: boolean): void {
    throw badBorrow('clearAllBricks');
  }
  saveBricks(saveName: string, region?: {}): void {
    throw badBorrow('saveBricks');
  }
  saveBricksAsync(saveName: string, region?: {}): Promise<void> {
    throw badBorrow('saveBricksAsync');
  }
  loadBricks(
    saveName: string,
    options?: { offX?: number; offY?: number; offZ?: number; quiet?: boolean },
  ): void {
    throw badBorrow('loadBricks');
  }
  loadBricksOnPlayer(
    saveName: string,
    player: string | OmeggaPlayer,
    options?: { offX?: number; offY?: number; offZ?: number },
  ): void {
    throw badBorrow('loadBricksOnPlayer');
  }
  getSaves(): string[] {
    throw badBorrow('getSaves');
  }
  getWorlds(): string[] {
    throw badBorrow('getWorlds');
  }
  getSavePath(saveName: string): string {
    throw badBorrow('getSavePath');
  }
  getWorldPath(worldName: string): string {
    throw badBorrow('getWorldPath');
  }
  getWorldRevisions(
    worldName: string,
  ): Promise<{ index: number; date: Date; note: string }[]> {
    throw badBorrow('getWorldRevisions');
  }
  loadWorld(worldName: string): Promise<boolean> {
    throw badBorrow('loadWorld');
  }
  loadWorldRevision(worldName: string, revision: number): Promise<boolean> {
    throw badBorrow('loadWorldRevision');
  }
  saveWorldAs(worldName: string): Promise<boolean> {
    throw badBorrow('saveWorldAs');
  }
  saveWorld(): Promise<boolean> {
    throw badBorrow('saveWorld');
  }
  createEmptyWorld(worldName: string): Promise<boolean> {
    throw badBorrow('createEmptyWorld');
  }
  writeSaveData(saveName: string, saveData: WriteSaveObject) {
    throw badBorrow('writeSaveData');
  }
  readSaveData(saveName: string, nobricks?: boolean): ReadSaveObject {
    throw badBorrow('readSaveData');
  }
  loadSaveData(
    saveData: WriteSaveObject,
    options?: { offX?: number; offY?: number; offZ?: number; quiet?: boolean },
  ): Promise<void> {
    throw badBorrow('loadSaveData');
  }
  loadSaveDataOnPlayer(
    saveData: WriteSaveObject,
    player: string | OmeggaPlayer,
    options?: { offX?: number; offY?: number; offZ?: number },
  ): Promise<void> {
    throw badBorrow('loadSaveDataOnPlayer');
  }
  getSaveData(region?: {
    center: [number, number, number];
    extent: [number, number, number];
  }): Promise<ReadSaveObject> {
    throw badBorrow('getSaveData');
  }
  changeMap(map: string): Promise<boolean> {
    throw badBorrow('changeMap');
  }
  getRoleSetup(): BRRoleSetup {
    throw badBorrow('getRoleSetup');
  }
  getRoleAssignments(): BRRoleAssignments {
    throw badBorrow('getRoleAssignments');
  }
  getBanList(): BRBanList {
    throw badBorrow('getBanList');
  }
  getNameCache(): BRPlayerNameCache {
    throw badBorrow('getNameCache');
  }
}

export function injectOmeggaPrototypes(
  proxyOmegga: typeof ProxyOmegga,
  omegga: typeof Omegga,
) {
  // copy prototypes from core omegga to the proxy omegga
  for (const fn in STEAL_PROTOTYPES) {
    proxyOmegga.prototype[fn] = omegga.prototype[fn];
  }
}
