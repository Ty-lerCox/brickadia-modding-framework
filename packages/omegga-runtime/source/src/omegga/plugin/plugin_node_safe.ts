import Logger from '@/logger';
import Omegga from '@omegga/server';
import EventEmitter from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import readline from 'readline';
import { Plugin } from './interface';
import { bootstrap } from './plugin_node_safe/proxyOmegga';
import { unwrapPluginInteropResult } from './plugin_node_safe/workerTransport';

// Main plugin file (like index.js)
// this isn't named 'index.js' or 'plugin.js' because those may be filenames
// used with other loaders (rpc loader) and are too generic
// omegga.main.js is rather unique and helps avoid collision
const MAIN_FILE = 'omegga.plugin.js';
const MAIN_FILE_TS = 'omegga.plugin.ts';

// Documentation file (contains name, description, author, command helptext)
const DOC_FILE = 'doc.json';
const ACCESS_FILE = 'access.json';
const PLUGIN_FILE = 'plugin.json';
const SAFE_WORKER_ENV_PREFIXES = ['OMEGGA_BMF_', 'OMEGGA_UE4SS_', 'CITYRPG_'];

function normalizeRegisteredCommands(value: unknown): string[] | undefined {
  if (
    !Array.isArray(value) ||
    value.some(command => typeof command !== 'string')
  ) {
    return undefined;
  }
  return [...value];
}

function getForwardedSafeWorkerEnv(): Record<string, string> {
  const forwarded: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (
      typeof value === 'string' &&
      SAFE_WORKER_ENV_PREFIXES.some(prefix => key.startsWith(prefix))
    ) {
      forwarded[key] = value;
    }
  }
  return forwarded;
}

export default class NodeVmPlugin extends Plugin {
  #worker?: Worker;

  // every node vm plugin requires a main file, a doc file, and an access file
  // may evolve this so it checks the contents of the doc file later
  static canLoad(pluginPath: string) {
    return (
      (fs.existsSync(path.join(pluginPath, MAIN_FILE)) ||
        fs.existsSync(path.join(pluginPath, MAIN_FILE_TS))) &&
      fs.existsSync(path.join(pluginPath, DOC_FILE)) &&
      fs.existsSync(path.join(pluginPath, ACCESS_FILE))
    );
  }

  // safe node plugins are limited
  static getFormat() {
    return 'node_safe';
  }

  plugin: EventEmitter;
  messageCounter: number;
  access: string[];
  isTypeScript: boolean;

  constructor(pluginPath: string, omegga: Omegga) {
    super(pluginPath, omegga);

    // event emitter and message counter for keeping track of worker events
    this.plugin = new EventEmitter();
    this.messageCounter = 0;

    // TODO: validate documentation
    this.documentation = Plugin.readJSON(path.join(pluginPath, DOC_FILE));
    this.isTypeScript = fs.existsSync(path.join(pluginPath, MAIN_FILE_TS));
    this.pluginConfig = Plugin.readJSON(path.join(pluginPath, PLUGIN_FILE));

    // access list is a list of builtin requires
    // can be ['*'] for everything
    this.access = Plugin.readJSON(path.join(pluginPath, ACCESS_FILE)) || [];

    // list of registered commands
    this.commands = [];

    // verify access is an array of strings
    if (
      !(this.access instanceof Array) ||
      !this.access.every(s => typeof s === 'string')
    ) {
      throw new Error('access list not a string array');
    }

    // plugin name
    const name = this.getName();

    // when the worker emits an error or a log, pass it up to omegga
    this.plugin.on('error', (resp, ...args) => {
      Logger.error(name.brightRed.underline, '!>'.red, ...args);
      this.notify(resp);
    });
    this.plugin.on('log', (resp, ...args) => {
      Logger.log(name.underline, '>>'.green, ...args);
      this.notify(resp);
    });

    // let the worker write commands to brickadia
    this.plugin.on('exec', async (resp, cmd) => {
      try {
        await omegga.writelnAsync(cmd);
      } finally {
        this.notify(resp);
      }
    });
    this.plugin.on(
      'execControlCommandWithOutput',
      async (resp, command, timeoutMs) => {
        try {
          const output = await omegga.execControlCommandWithOutput(
            String(command ?? ''),
            Number.isFinite(Number(timeoutMs)) ? Number(timeoutMs) : undefined,
          );
          this.notify(resp, { ok: true, output });
        } catch (err) {
          this.notify(resp, {
            ok: false,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      },
    );
    this.plugin.on('getAllPlayerPositions', async resp => {
      try {
        this.notify(resp, {
          ok: true,
          positions: await omegga.getAllPlayerPositions(),
        });
      } catch (err) {
        this.notify(resp, {
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    });
    this.plugin.on('private.whisper', async (resp, target, messages) => {
      try {
        const lines = Array.isArray(messages)
          ? messages
              .flatMap(value => String(value).split('\n'))
              .filter(value => value.length > 0 && value.length < 512)
          : [];
        if (lines.length === 0 || lines.length > 16) {
          throw new Error('private whisper payload is invalid or unbounded');
        }
        for (const line of lines) {
          if (!(await omegga.deliverPrivateOutput('whisper', target, line))) {
            throw new Error(
              'private whisper identity or transport was rejected',
            );
          }
        }
        this.notify(resp, { ok: true });
      } catch (err) {
        this.notify(resp, {
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    });
    this.plugin.on('private.middlePrint', async (resp, target, message) => {
      try {
        const text = String(message ?? '');
        if (text.length < 1 || text.length >= 512) {
          throw new Error('private status payload is invalid');
        }
        if (
          !(await omegga.deliverPrivateOutput('statusmessage', target, text))
        ) {
          throw new Error('private status identity or transport was rejected');
        }
        this.notify(resp, { ok: true });
      } catch (err) {
        this.notify(resp, {
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    });

    // storage interface
    this.plugin.on('store.get', async (resp, key) => {
      try {
        this.notify(resp, await this.storage.get(key));
      } catch (e) {
        Logger.error(
          name.brightRed.underline,
          '!>'.red,
          'error in store.get of',
          key,
          e,
        );
      }
    });
    this.plugin.on('store.set', async (resp, key, value) => {
      try {
        await this.storage.set(key, JSON.parse(value));
      } catch (e) {
        Logger.error(
          name.brightRed.underline,
          '!>'.red,
          'error in store.set of',
          key,
          value,
          e,
        );
      }
      this.notify(resp);
    });
    this.plugin.on('store.delete', async (resp, key) => {
      try {
        await this.storage.delete(key);
      } catch (e) {
        Logger.error(
          name.brightRed.underline,
          '!>'.red,
          'error in store.delete of',
          key,
          e,
        );
      }
      this.notify(resp);
    });
    this.plugin.on('store.wipe', async resp => {
      try {
        await this.storage.wipe();
      } catch (e) {
        Logger.error(
          name.brightRed.underline,
          '!>'.red,
          'error in store.wipe',
          e,
        );
      }
      this.notify(resp);
    });
    this.plugin.on('store.count', async resp => {
      try {
        this.notify(resp, await this.storage.count());
      } catch (e) {
        Logger.error(
          name.brightRed.underline,
          '!>'.red,
          'error in store.count',
          e,
        );
      }
    });
    this.plugin.on('store.keys', async resp => {
      try {
        this.notify(resp, await this.storage.keys());
      } catch (e) {
        Logger.error(
          name.brightRed.underline,
          '!>'.red,
          'error in store.keys',
          e,
        );
      }
    });

    // plugin fetching
    this.plugin.on('getPlugin', async (resp, name) => {
      const plugin = this.omegga.pluginLoader.plugins.find(
        p => p.getName() === name,
      );

      if (plugin) {
        this.notify(resp, {
          name,
          documentation: plugin.getDocumentation(),
          loaded: plugin.isLoaded(),
        });
      } else {
        this.notify(resp);
      }
    });

    this.plugin.on('emitPlugin', async (resp, target, ev, args) => {
      const plugin = this.omegga.pluginLoader.plugins.find(
        p => p.getName() === target,
      );

      if (plugin) {
        let r = await plugin.emitPlugin(ev, name, args);
        this.notify(resp, r);
      } else {
        Logger.error(name.brightRed.underline, '!>'.red, 'error in emitPlugin');
      }
    });

    // command registration
    this.plugin.on('command.registers', async (resp, blob) => {
      if (typeof blob !== 'string') return;
      const registers = normalizeRegisteredCommands(JSON.parse(blob));
      if (!registers) return;

      this.commands = registers;
      this.notify(resp, true);
    });

    // listen on every message, post them to to the worker
    this.eventPassthrough = this.eventPassthrough.bind(this);
  }

  // emit a custom plugin event
  async emitPlugin(ev: string, from: string, args: any[]) {
    const [r]: any[] = (await this.emit('emitPlugin', ev, from, args)) ?? [];
    return unwrapPluginInteropResult(r);
  }

  // documentation is based on doc.json file
  getDocumentation() {
    return this.documentation;
  }

  // loaded state is based on if a worker exists
  isLoaded() {
    return !!this.#worker;
  }

  // determing if a command is registered
  isCommand(cmd: string) {
    return this.commands.includes(cmd);
  }

  // require the plugin into the system, run the init func
  async load() {
    // can't load the plugin if it's already loaded
    if (typeof this.#worker !== 'undefined') return false;

    // vm restriction settings, default is access to everything
    const vmOptions = {
      builtin: this.access, // TODO: reference access file
      external: true, // TODO: reference access file
      isTypeScript: this.isTypeScript,
    };
    this.commands = [];

    let worker: Worker | undefined;
    try {
      const config = await this.storage.getConfig();
      if (this.pluginConfig?.emitConfig) {
        await fs.promises.writeFile(
          path.join(this.path, this.pluginConfig.emitConfig),
          JSON.stringify(config),
        );
      }
      worker = this.createWorker();

      // tell the worker its name :)
      await this.emit('name', this.getName());

      // create the vm, export the plugin's class
      Logger.verbose('Loading safe plugin');
      if (!(await this.emit('load', this.path, vmOptions))[0]) throw '';

      // get some initial information to create an omegga proxy
      const initialData = bootstrap(this.omegga);
      // send all of the mock events to the proxy omegga
      Logger.verbose('Sending initial data to safe plugin');
      for (const ev in initialData) {
        try {
          worker.postMessage({
            action: 'brickadiaEvent',
            args: [ev, ...initialData[ev]],
          });
        } catch (e) {
          /* just writing 'safe' code :) */
        }
      }

      // pass events through
      this.omegga.on('*', this.eventPassthrough);
      Logger.verbose('Starting safe plugin');
      // actually start the plugin
      const startResult = await this.emit('start', config);
      if (!startResult?.[0]) throw 'plugin failed start';

      const registeredCommands = normalizeRegisteredCommands(startResult[1]);
      if (registeredCommands) {
        this.commands = registeredCommands;
      }

      this.emitStatus();
      return true;
    } catch (e) {
      if (worker && worker.threadId !== -1) {
        await worker.terminate();
      }

      Logger.error(
        '!>'.red,
        'error loading node vm plugin',
        this.getName().brightRed.underline,
        e,
      );
      this.emitStatus();
      return false;
    }
  }

  // disrequire the plugin into the system, run the stop func
  async unload() {
    const worker = this.#worker;
    if (!worker) return false;

    let timeout: NodeJS.Timeout | undefined;
    let stopTimedOut = false;
    try {
      const stop = this.emit('stop');
      if (stop) {
        await Promise.race([
          stop,
          new Promise<never>((_, reject) => {
            timeout = setTimeout(() => {
              stopTimedOut = true;
              reject(new Error('plugin stop timed out'));
            }, 5000);
          }),
        ]);
      }
    } catch (e) {
      Logger.error(
        '!>'.red,
        stopTimedOut
          ? 'plugin stop timed out; terminating worker'
          : 'error stopping node plugin; terminating worker',
        this.getName().brightRed.underline,
        e,
      );
    } finally {
      if (timeout) clearTimeout(timeout);
      this.omegga.off('*', this.eventPassthrough);
      this.commands = [];
    }

    try {
      if (worker.threadId !== -1) await worker.terminate();
      return true;
    } catch (e) {
      Logger.error(
        '!>'.red,
        'error terminating node plugin worker',
        this.getName().brightRed.underline,
        e,
      );
      return false;
    }
  }

  // emit an action to the worker and return a promise with its response
  emit(action: string, ...args: any[]) {
    if (!this.#worker) return;

    const messageId = 'message:' + this.messageCounter++;

    // promise waits for the message to resolve
    const promise = new Promise<unknown[]>(resolve =>
      this.plugin.once(messageId, (_, ...x) => resolve(x)),
    );

    // post the message
    try {
      this.#worker.postMessage({
        action,
        args: [messageId, ...args],
      });
    } catch (e) {
      return Promise.reject(e);
    }

    // return the promise
    return promise;
  }

  // notify a response to the worker
  notify(action: string, ...args: any[]) {
    if (!this.#worker) return;

    // post the message
    try {
      this.#worker.postMessage({
        action,
        args: [...args],
      });
    } catch (e) {
      // do nothing here
    }
  }

  // create the worker for this plugin, attach emitter
  createWorker() {
    const worker = new Worker(
      // vite transpiles worker.ts to dist/worker.js
      path.join(__dirname, '../../worker.js'),
      {
        stdout: true,
        env: {
          ...getForwardedSafeWorkerEnv(),
          VERBOSE: Logger.VERBOSE + '',
        },
      },
    );

    // pipe plugin output into omegga
    this.#worker = worker;

    const outInterface = readline.createInterface({
      input: worker.stdout,
      terminal: false,
    });
    const errInterface = readline.createInterface({
      input: worker.stderr,
      terminal: false,
    });
    outInterface.on('line', Logger.log);
    errInterface.on('line', Logger.error);

    // attach message emitter
    worker.on('message', ({ action, args }) => {
      if (this.#worker === worker) this.plugin.emit(action, ...args);
    });

    // broadcast an error if there is one
    worker.on('error', err => {
      Logger.error(
        '!>'.red,
        'error in plugin',
        this.getName().brightRed.underline,
        err,
      );
    });

    // when the worker exits - set its variable to undefined this knows it's stopped
    worker.on('exit', () => {
      outInterface.removeAllListeners('line');
      errInterface.removeAllListeners('line');
      outInterface.close();
      errInterface.close();

      // A late exit from an old worker must not tear down its replacement.
      if (this.#worker !== worker) return;

      this.omegga.off('*', this.eventPassthrough);
      this.#worker = undefined;
      this.commands = [];
      this.emitStatus();
    });

    return worker;
  }

  eventPassthrough(...args: any[]) {
    // worker does not exist
    if (!this.#worker) return;

    try {
      // post the message
      this.#worker.postMessage({
        action: 'brickadiaEvent',
        args,
      });
    } catch (e) {
      // make sure post message doesn't crash the entire app
      Logger.error('!>'.red, 'error sending to plugin', ...args, e);
    }
  }
}
