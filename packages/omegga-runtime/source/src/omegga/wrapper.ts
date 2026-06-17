/*
  The wrapper combines the things looking at or waiting for logs with the actual server logs
*/

import Logger from '@/logger';
import soft from '@/softconfig';
import BrickadiaServer from '@brickadia/server';
import { IConfig } from '@config/types';
import EventEmitter from 'events';
import path from 'path';
import LogWrangler from './logWrangler';
import type Omegga from './server';

export type OmeggaConsoleCommandMetric = {
  command: string;
  count: number;
  lastAtMs: number;
};

export const normalizeConsoleCommandFamily = (command: string) => {
  const tokens =
    String(command || '')
      .trim()
      .match(/"[^"]*"|\S+/g)
      ?.map(token => token.replace(/^"|"$/g, '')) ?? [];
  const primary = tokens[0] || 'empty';
  if (primary === 'GetAll' && tokens[1]) return `${primary} ${tokens[1]}`;
  if (primary === 'Chat.Command' && tokens[1]) {
    return `${primary} ${tokens[1]}`;
  }
  return primary.slice(0, 80);
};

class OmeggaWrapper extends EventEmitter {
  #server: BrickadiaServer;
  dataPath: string;
  path: string;
  consoleCommandMetrics: Record<string, OmeggaConsoleCommandMetric> = {};

  logWrangler: LogWrangler;
  addMatcher: LogWrangler['addMatcher'];
  addWatcher: LogWrangler['addWatcher'];
  watchLogArray: LogWrangler['watchLogArray'];
  watchLogChunk: LogWrangler['watchLogChunk'];

  config: IConfig;

  constructor(serverPath: string, cfg: IConfig) {
    super();
    this.setMaxListeners(Infinity);

    this.config = cfg;
    this.path =
      path.isAbsolute(serverPath) || serverPath.startsWith('/')
        ? serverPath
        : path.join(process.cwd(), serverPath);
    this.dataPath = path.join(this.path, soft.DATA_PATH);
    this.#server = new BrickadiaServer(this.dataPath, cfg);

    // log wrangler wrangles logs... it reads brickadia logs and clumps them together
    // this is cursed but the OmeggaWrapper will never be used without omegga...
    this.logWrangler = new LogWrangler(this as unknown as Omegga);
    this.#server.on('line', this.logWrangler.callback);
    this.#server.on('line', (line: string) => this.emit('line', line));
    this.#server.on('closed', () => this.emit('closed'));
    this.#server.on('control:ready', payload =>
      this.emit('control:ready', payload),
    );
    this.#server.on('control:degraded', payload =>
      this.emit('control:degraded', payload),
    );
    this.#server.on('control:log', payload => this.emit('control:log', payload));
    this.#server.on('control:complete', payload =>
      this.emit('control:complete', payload),
    );

    this.addMatcher = this.logWrangler.addMatcher;
    this.addWatcher = this.logWrangler.addWatcher;
    this.watchLogArray = this.logWrangler.watchLogArray;
    this.watchLogChunk = this.logWrangler.watchLogChunk;
  }

  // passthrough to server
  writeAsync(str: string) {
    return this.#server.writeAsync(str);
  }
  write(str: string) {
    this.#server.write(str);
  }
  writelnAsync(str: string) {
    this.recordConsoleCommand(str);
    return this.#server.writelnAsync(str);
  }
  writeln(str: string) {
    this.recordConsoleCommand(str);
    this.#server.writeln(str);
  }
  execControlCommandWithOutput(command: string, timeoutMs?: number) {
    this.recordConsoleCommand(command);
    return this.#server.execControlCommandWithOutput(command, timeoutMs);
  }
  start() {
    return this.#server.start();
  }
  stop() {
    return this.#server.stop();
  }
  waitUntilControlReady(timeoutMs?: number) {
    return this.#server.waitUntilControlReady(timeoutMs);
  }
  pingWindowsControl(timeoutMs?: number) {
    return this.#server.pingWindowsControl(timeoutMs);
  }
  getWindowsControlBackend() {
    return this.#server.getWindowsControlBackend();
  }

  private recordConsoleCommand(command: string) {
    const family = normalizeConsoleCommandFamily(command);
    const existing = this.consoleCommandMetrics[family] ?? {
      command: family,
      count: 0,
      lastAtMs: 0,
    };
    existing.count += 1;
    existing.lastAtMs = Date.now();
    this.consoleCommandMetrics[family] = existing;
  }

  // event emitter to catch everything
  emit(type: string, ...args: any) {
    if (type !== 'line') Logger.verbose('Emitting event', type);
    try {
      (super.emit as EventEmitter['emit'])('*', type, ...args);
    } catch (e) {
      Logger.errorp('Error in emitted event', type, e);
      // error emitting
    }
    return (super.emit as EventEmitter['emit'])(type, ...args);
  }

  /** Get which world will be loaded on startup (form file, config, or env) */
  getNextWorld() {
    return this.#server.getNextWorld();
  }

  /** Get the configured default world */
  getActiveWorld() {
    return this.#server.getActiveWorld();
  }

  /** Configure the default world  */
  setActiveWorld(world: string | null): boolean {
    return this.#server.setActiveWorld(world);
  }

  /** Check if a world exists */
  worldExists(file: string) {
    return this.#server.worldExists(file);
  }
}

export default OmeggaWrapper;
