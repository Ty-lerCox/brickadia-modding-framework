import soft, {
  getOverrideGameBinary,
  getSteamGameDir,
  getSteamInstallDir,
} from '@/softconfig';
import { installLauncher } from '@cli/installer';
import * as config from '@config';
import Omegga from '@omegga/server';
import * as file from '@util/file';
import { IS_WINDOWS } from '@util/platform';
import {
  disableManagedUe4ss,
  formatUe4ssDiagnostics,
  getBrickadiaLogPath,
  getGameWin64Dir,
  getPinnedUe4ssCompatibilityBundleId,
  installManagedUe4ss,
  readBrickadiaBuildInfo,
  readUe4ssDiagnostics,
  validateUe4ssCompatibilityBundle,
  UE4SS_MANIFEST,
} from '@util/ue4ss';
import 'colors';
import commander from 'commander';
import dotenv from 'dotenv';
import hasbin from 'hasbin';
import fs from 'node:fs';
import path from 'node:path';
import prompts from 'prompts';
import updateNotifier from 'update-notifier-cjs';
import { auth, config as omeggaConfig, pluginUtil, Terminal } from './cli';
import { IConfig } from './config/types';
import Logger from './logger';
import { GAME_BIN_PATH, STEAMCMD_PATH } from './softconfig';
import {
  hasSteamUpdate,
  getSteamCmdCommand,
  steamcmdDownloadGame,
  steamcmdDownloadSelf,
} from './updater';
import { PKG, VERSION } from './version';

dotenv.config({ quiet: true });

const notifier =
  process.env.PACKAGE_NOTIFIER !== 'false'
    ? updateNotifier({
        pkg: PKG,
        updateCheckInterval: 1000 * 60 * 60 * 24,
      })
    : null;
notifier?.notify();

// TODO: let omegga bundle config (roles, bans, server config) to zip
// TODO: let omegga unbundle config from zip to current omegga dir

// write a default config file
const createDefaultConfig = () => {
  Logger.logp('Created default config file');
  config.write(soft.CONFIG_FILENAMES[0] + '.yml', config.defaultConfig);
  file.mkdir(`data/${soft.CONFIG_SAVED_DIR}/Builds`);
  file.mkdir('plugins');
  return config.defaultConfig;
};

async function resolveLaunchContext() {
  let workDir = config.store.get('defaultOmegga');
  Logger.verbose('Using working directory', workDir?.yellow);

  if (config.find('.')) workDir = '.';

  if (!fs.existsSync(workDir)) {
    Logger.errorp('configured omegga default path does not exist');
    process.exit(1);
  }
  if (!fs.statSync(workDir).isDirectory) {
    Logger.errorp('configured omegga default path is not a directory');
    process.exit(1);
  }

  const configFile = config.find(workDir);
  Logger.verbose('Target config file:', configFile?.yellow);

  let conf: IConfig;
  if (!configFile) {
    Logger.verbose('Creating a new config');
    conf = createDefaultConfig();
  } else {
    Logger.verbose('Reading config file');
    try {
      conf = config.read(configFile);
    } catch (error) {
      Logger.errorp('Error reading config file');
      Logger.verbose(error);
    }
  }

  return { workDir, conf };
}

async function ensureLaunchReady(
  workDir: string,
  conf: IConfig,
  { debug, update = false }: { debug?: boolean; update?: boolean } = {},
) {
  const overrideBinary = getOverrideGameBinary();
  const isSteam = !conf?.server?.branch;

  if (overrideBinary) {
    if (!fs.existsSync(overrideBinary)) {
      Logger.error(
        'Binary',
        overrideBinary.yellow,
        'in',
        'BRICKADIA_DIR'.yellow,
        'does not exist!',
      );
      process.exit(1);
    }

    Logger.verbose(
      'Using override binary',
      overrideBinary.yellow,
      '- skipping download.',
    );
  } else if (isSteam) {
    conf.__STEAM = true;
    await setupSteam(conf, update);
  } else {
    if (IS_WINDOWS) {
      Logger.errorp(
        'Legacy launcher branches are not supported on Windows. Remove',
        'server.branch'.yellow,
        'and use SteamCMD or',
        'BRICKADIA_DIR'.yellow,
        'instead.',
      );
      process.exit(1);
    }

    Logger.warnp(
      'Brickadia will be launched with',
      'non-steam launcher'.yellow,
    );
    Logger.warnp(
      'New versions of Brickadia are not published on the old launcher.'
        .yellow,
    );

    if (fs.existsSync(soft.LOCAL_LAUNCHER)) {
      Logger.verbose("Using omegga's brickadia-launcher");
      conf.server.__LOCAL = true;
    } else {
      Logger.verbose("Installing launcher as it's missing");
      await installLauncher();
    }
  }

  const globalToken = auth.getGlobalToken();
  const hasHostingToken = Boolean(
    conf?.credentials?.token || process.env.BRICKADIA_TOKEN || globalToken,
  );

  if (hasHostingToken) {
    Logger.verbose(
      'Skipping auth token generation due to host token presence',
    );
    if (conf?.credentials?.token)
      Logger.verbose('Found token in config file');
    else if (process.env.BRICKADIA_TOKEN)
      Logger.verbose('Found token in', 'BRICKADIA_TOKEN'.yellow);
    else if (globalToken)
      Logger.verbose('Found token in omegga global config');
  } else if (
    !auth.exists(
      path.join(
        workDir,
        soft.DATA_PATH,
        conf?.server?.savedDir ?? soft.CONFIG_SAVED_DIR,
        conf?.server?.authDir ?? soft.CONFIG_AUTH_DIR,
      ),
    )
  ) {
    const success = await auth.prompt({
      debug,
      email: conf?.credentials?.['email'] ?? process.env.BRICKADIA_USER,
      password: conf?.credentials?.['password'] ?? process.env.BRICKADIA_PASS,
      isSteam,
      branch: conf?.server?.branch,
      authDir: conf?.server?.authDir,
      savedDir: conf?.server?.savedDir,
      launchArgs: conf?.server?.launchArgs,
    });
    if (!success) {
      Logger.errorp('Start aborted - could not generate auth tokens');
      process.exit(1);
    }
  } else {
    Logger.verbose(
      'Skipping auth token generation due to existing auth files',
    );
  }
}

function getLaunchOptions(conf: IConfig, debug = false) {
  return {
    noweb: typeof conf.omegga?.webui === 'boolean' && !conf.omegga?.webui,
    https: typeof conf.omegga?.https !== 'boolean' || conf.omegga?.https,
    port: conf.omegga?.port || soft.DEFAULT_PORT,
    debug,
  };
}

async function waitForEvent<T = unknown>(
  emitter: NodeJS.EventEmitter,
  event: string,
  timeoutMs: number,
) {
  return new Promise<T>((resolve, reject) => {
    const onEvent = (payload: T) => {
      cleanup();
      resolve(payload);
    };
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error(`Timed out waiting for ${event}`));
    }, timeoutMs);

    const cleanup = () => {
      clearTimeout(timer);
      emitter.off(event, onEvent);
    };

    emitter.on(event, onEvent);
  });
}

function logUe4ssCompatibilityBundleStatus() {
  const validation = validateUe4ssCompatibilityBundle();

  if (validation.workspaceRoot) {
    Logger.log('  Compatibility workspace:', validation.workspaceRoot.yellow);
  }
  if (validation.bundleDir) {
    Logger.log(
      '  Compatibility bundle:',
      `${validation.bundleId} (${validation.validated ? 'validated' : 'staged'})`.yellow,
    );
    Logger.log('  Bundle path:', validation.bundleDir.yellow);
  }
  if (validation.manifestPath) {
    Logger.log('  Bundle manifest:', validation.manifestPath.yellow);
  }
  for (const warning of validation.warnings) {
    Logger.warn('  Compatibility:', warning.yellow);
  }
  return validation;
}

const program = commander
  .description(PKG.description)
  .version(VERSION)
  .option(
    '-d, --debug',
    'Print all console logs rather than just chat messages',
  )
  .option(
    '-u, --update',
    'Check for brickadia updates (on steam) and install them if available',
  )
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .action(async () => {
    const { debug, verbose, update } = program.opts();
    if (program.args.length > 0) {
      program.help();
      process.exit(1);
    }
    Logger.VERBOSE = Boolean(verbose);
    const { workDir, conf } = await resolveLaunchContext();
    await ensureLaunchReady(workDir, conf, { debug, update });
    const options = getLaunchOptions(conf, debug);

    Logger.verbose('Launching with options', options);

    // setup the server
    const server = new Omegga(workDir, conf, options);
    Logger.verbose('Created omegga object');

    if (verbose) {
      server.on(
        '*',
        (ev: string) => ev !== 'line' && Logger.verbose('EVENT'.green, ev),
      );
    }

    // create a terminal
    Logger.setTerminal(new Terminal(server, options));

    if (notifier?.update) {
      Logger.logp(
        `Omegga update is available (${('v' + notifier.update.latest).yellow})! Run`,
        'npm i -g omegga'.yellow,
        'to update!',
      );
    }

    if (
      conf.__STEAM &&
      !update &&
      !conf.server?.steambetaPassword &&
      process.env.STEAM_NOTIFIER !== 'false'
    ) {
      hasSteamUpdate(conf.server?.steambeta).then(hasUpdate => {
        if (hasUpdate) {
          Logger.logp('A server update is available!'.brightBlue);
          Logger.log(
            '  Restart with',
            'omegga --update'.yellow,
            'to update every start.',
          );
          Logger.log('  Run', '/update'.yellow, 'to update', 'now'.green + '!');
        } else {
          Logger.verbose('No server updates available.');
        }
      });
    }

    Logger.logp(
      `Launching brickadia server on port ${
        ('' + (conf.server.port || 7777)).green
      }...`,
    );

    // start the server
    Logger.verbose('Starting Omegga');
    await server.start();
  });

program
  .command('init')
  .description('Sets up the current directory as a brickadia server')
  .action(async () => {
    const configFile = config.find('.');
    if (configFile) {
      Logger.errorp('Config file already exists:', configFile.yellow.underline);
      process.exit(1);
    }
    createDefaultConfig();
  });

program
  .command('config [field] [value]')
  .description(
    "Configure Omegga's default behavior.\n" +
      'Type ' +
      'omegga config list'.yellow.underline +
      ' for current settings and available fields',
  )
  .action((field, value) => {
    if (!field) field = 'list';
    omeggaConfig(field, value, program.opts());
  });

program
  .command('auth')
  .option('-g, --global', 'Remove global auth files')
  .option('-l, --local', 'Remove local auth files')
  .option('-w, --workdir', 'Remove configured location auth files')
  .option('-u, --email <email>', 'User email (must provide password)')
  .option('-p, --pass <password>', 'User password (must provide email)')
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .description(
    'Generates server auth tokens from brickadia account email+password',
  )
  .action(
    async ({
      email,
      pass: password,
      local: localAuth,
      workDir,
      global: globalAuth,
    }) => {
      const { verbose, debug } = program.opts();
      Logger.VERBOSE = Boolean(verbose);

      let branch: string, authDir: string, savedDir: string, launchArgs: string;
      let isSteam: boolean;

      // if there's a config in the current directory, use that one instead
      if (config.find('.')) workDir = '.';

      // check if configured path exists
      if (fs.existsSync(workDir) && fs.statSync(workDir).isDirectory) {
        Logger.verbose('Using working directory', workDir.yellow);
        // find the config for the working directory
        const configFile = config.find(workDir);
        Logger.verbose('Target config file:', configFile?.yellow);
        try {
          // read the config and extract the branch
          const conf = config.read(configFile);
          Logger.verbose(
            'Auth config:',
            conf?.server ?? 'no server config'.grey,
          );
          branch = conf?.server?.branch;
          authDir = conf?.server?.authDir;
          savedDir = conf?.server?.savedDir;
          launchArgs = conf?.server?.launchArgs;
          isSteam = !conf?.server?.branch;

          if (localAuth && conf?.credentials?.token) {
            Logger.logp(
              "This server's auth is managed by the token in",
              configFile.yellow,
            );
            return;
          }
        } catch (error) {
          Logger.errorp('Error reading config file');
          Logger.verbose(error);
        }
      } else {
        Logger.verbose('Using default working directory', workDir.yellow);
      }

      savedDir ??= soft.CONFIG_SAVED_DIR;

      const workdirPath = path.join(
        config.store.get('defaultOmegga'),
        `data/${savedDir}/${authDir ?? soft.CONFIG_AUTH_DIR}`,
      );

      if (globalAuth || localAuth) {
        if (globalAuth) {
          const globalAuthPath = path.join(
            soft.CONFIG_HOME,
            savedDir !== soft.CONFIG_SAVED_DIR ? savedDir : '',
            authDir ?? soft.CONFIG_AUTH_DIR,
          );
          Logger.logp('Clearing auth files from', globalAuthPath.yellow);
          auth.clean(globalAuthPath);
        }
        if (workDir) {
          Logger.logp('Clearing auth files from', workdirPath.yellow);
          await file.rmdir(workdirPath);
        }
        if (localAuth) {
          const localPath = path.resolve(
            `data/${savedDir}/`,
            authDir ?? soft.CONFIG_AUTH_DIR,
          );
          Logger.logp('Clearing auth files from', localPath.yellow);
          await file.rmdir(localPath);
        }
        return;
      }

      if (!isSteam) {
        Logger.warnp('Authenticating with', 'non-steam launcher'.yellow);
      }

      auth.prompt({
        email,
        password,
        debug,
        branch,
        authDir,
        savedDir,
        launchArgs,
      });
    },
  );

program
  .command('ue4ss <action>')
  .description(
    'Manage the Windows UE4SS integration. Actions: install, validate, disable',
  )
  .action(async action => {
    const { debug, verbose, update } = program.opts();
    Logger.VERBOSE = Boolean(verbose);

    if (!IS_WINDOWS) {
      Logger.errorp('UE4SS provisioning is only available on Windows.');
      process.exit(1);
    }

    const normalizedAction = String(action || '').toLowerCase();
    const { workDir, conf } = await resolveLaunchContext();
    const win64Dir = getGameWin64Dir(conf);

    if (normalizedAction === 'disable') {
      disableManagedUe4ss(win64Dir);
      Logger.logp('Disabled managed UE4SS in', win64Dir.yellow);
      return;
    }

    await ensureLaunchReady(workDir, conf, { debug, update });
    const bundleValidation = logUe4ssCompatibilityBundleStatus();

    if (!bundleValidation.ok) {
      Logger.errorp(
        'UE4SS compatibility bundle',
        getPinnedUe4ssCompatibilityBundleId().yellow,
        'is incomplete.',
      );
      for (const error of bundleValidation.errors) {
        Logger.error('  Compatibility:', error.yellow);
      }
      process.exit(1);
    }

    if (normalizedAction === 'install') {
      const install = installManagedUe4ss(win64Dir);
      Logger.logp(
        'Installed managed UE4SS',
        UE4SS_MANIFEST.version.yellow,
        'into',
        install.targetWin64Dir.yellow,
      );
      Logger.log('  Source:', install.sourceRoot.yellow);
      Logger.log('  Cache:', install.cacheRoot.yellow);
      Logger.log('  Proxy:', install.targetProxyDll.yellow);
      Logger.log(
        '  Compatibility status:',
        `${install.compatibilityBundle.bundleId} (${install.compatibilityBundle.manifest.validated ? 'validated' : 'staged'})`
          .yellow,
      );
      Logger.log(
        '  Compatibility report:',
        install.compatibilityBundle.validationReportMarkdownPath.yellow,
      );
      Logger.log(
        '  Reverse-engineering UE baseline:',
        UE4SS_MANIFEST.reverseEngineeringEnginePath.yellow,
      );
      return;
    }

    if (normalizedAction !== 'validate') {
      Logger.errorp(
        'Unknown UE4SS action',
        normalizedAction.yellow,
        '- expected install, validate, or disable.',
      );
      process.exit(1);
    }

      const install = installManagedUe4ss(win64Dir);
      Logger.logp(
        'Validating managed UE4SS',
        UE4SS_MANIFEST.version.yellow,
        'in',
      install.targetWin64Dir.yellow,
    );
      if (fs.existsSync(UE4SS_MANIFEST.reverseEngineeringEnginePath)) {
        Logger.log(
          '  Reverse-engineering UE baseline:',
          UE4SS_MANIFEST.reverseEngineeringEnginePath.yellow,
        );
      }
      Logger.log(
        '  Compatibility report:',
        install.compatibilityBundle.validationReportMarkdownPath.yellow,
      );

      const options = {
        ...getLaunchOptions(conf, debug),
        noweb: true,
      noplugin: true,
    };
    const server = new Omegga(workDir, conf, options);
    const startedPromise = waitForEvent(server, 'start', 45000);

    try {
      await server.start();
      await server.waitUntilControlReady(20000);
      await startedPromise;
      const buildInfo = readBrickadiaBuildInfo(
        getBrickadiaLogPath(
          path.join(workDir, soft.DATA_PATH),
          conf?.server?.savedDir ?? soft.CONFIG_SAVED_DIR,
        ),
      );
      let capabilities = server.getWindowsControlCapabilities();
      for (let attempt = 0; !capabilities && attempt < 20; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 100));
        capabilities = server.getWindowsControlCapabilities();
      }

      const expectedBuildCl = install.compatibilityBundle.manifest.brickadia_cl;
      if (expectedBuildCl && buildInfo.cl && buildInfo.cl !== expectedBuildCl) {
        throw new Error(
          `Unsupported Brickadia build CL${buildInfo.cl}; expected CL${expectedBuildCl} for compatibility bundle ${install.compatibilityBundle.bundleId}.`,
        );
      }

      if (!capabilities) {
        throw new Error('UE4SS bridge did not report capabilities.');
      }

      const missingCapabilities = [
        'console_exec',
        'server_status',
        'players_list',
        'chat_broadcast',
        'chat_whisper',
        'chat_status_message',
      ].filter(capability => !capabilities[capability]);

      if (missingCapabilities.length > 0) {
        throw new Error(
          `UE4SS bridge is missing required capabilities: ${missingCapabilities.join(', ')}`,
        );
      }

      if (!install.compatibilityBundle.manifest.validated) {
        throw new Error(
          `Compatibility bundle ${install.compatibilityBundle.bundleId} is staged but not validated. Complete stages 1-4 in ${install.compatibilityBundle.validationReportMarkdownPath} before re-enabling Windows object control.`,
        );
      }

      const ping = await server.pingWindowsControl(5000);
      const status = await server.getServerStatus();

      Logger.logp('UE4SS validation succeeded.');
      Logger.log('  Backend:', String(server.getWindowsControlBackend()).yellow);
      Logger.log('  Ping:', JSON.stringify(ping).yellow);
      if (buildInfo.branchLabel) {
        Logger.log('  Brickadia build:', buildInfo.branchLabel.yellow);
      }
      Logger.log('  Server:', status.serverName.yellow);
      Logger.log('  Players:', String(status.players.length).yellow);
      Logger.log(
        '  Capabilities:',
        JSON.stringify({
          server_status_native: capabilities.server_status_native ?? false,
          players_list_native: capabilities.players_list_native ?? false,
          chat_broadcast_native: capabilities.chat_broadcast_native ?? false,
          chat_whisper_native: capabilities.chat_whisper_native ?? false,
          chat_status_message_native:
            capabilities.chat_status_message_native ?? false,
        }).yellow,
      );
      return;
    } catch (error) {
      const diagnostics = readUe4ssDiagnostics(win64Dir);
      const buildInfo = readBrickadiaBuildInfo(
        getBrickadiaLogPath(
          path.join(workDir, soft.DATA_PATH),
          conf?.server?.savedDir ?? soft.CONFIG_SAVED_DIR,
        ),
      );
      const detail = formatUe4ssDiagnostics(diagnostics, buildInfo);

      Logger.errorp('UE4SS validation failed.');
      if (buildInfo.branchLabel) {
        Logger.error('  Brickadia build:', buildInfo.branchLabel.yellow);
      }
      if (diagnostics.engineVersion) {
        Logger.error('  UE version:', diagnostics.engineVersion.yellow);
      }
      if (diagnostics.logPath) {
        Logger.error('  UE4SS log:', diagnostics.logPath.yellow);
      }
      if (bundleValidation.bundleDir) {
        Logger.error('  Compatibility bundle:', bundleValidation.bundleDir.yellow);
      }
      if (bundleValidation.manifestPath) {
        Logger.error('  Bundle manifest:', bundleValidation.manifestPath.yellow);
      }
      for (const warning of bundleValidation.warnings) {
        Logger.error('  Compatibility:', warning.yellow);
      }
      for (const errorDetail of bundleValidation.errors) {
        Logger.error('  Compatibility:', errorDetail.yellow);
      }
      if (diagnostics.missingSymbols.length > 0) {
        Logger.error(
          '  Missing signatures:',
          diagnostics.missingSymbols.join(', ').yellow,
        );
      }
      if (diagnostics.signatureHints.length > 0) {
        Logger.error(
          '  Signature file hints:',
          diagnostics.signatureHints.join(', ').yellow,
        );
      }
      if (detail) Logger.error('  Details:', detail);
      Logger.verbose(error);
      process.exitCode = 1;
    } finally {
      try {
        await server.stop();
      } catch (error) {
        Logger.verbose('Error while stopping validation server', error);
      }
    }

    if (process.exitCode) process.exit(process.exitCode);
  });

program
  .command('info')
  .alias('n')
  .description(
    'Shows server name, description, port, install info, and installed plugins',
  )
  .action(async () => {
    Logger.errorp('not implemented yet');
    // TODO: implement config parsing
  });

program
  .command('install <pluginUrl...>')
  .alias('i')
  .option('-f, --force', 'Forcefully re-install existing plugin') // TODO: implement install --force
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .description('Installs a plugin to the current brickadia server')
  .action(async plugins => {
    if (!hasbin.sync('git')) {
      Logger.errorp('git'.yellow, 'must be installed to install plugins.');
      process.exit(1);
    }

    if (!config.find('.')) {
      Logger.errorp(
        'Not an omegga directory, run ',
        'omegga init'.yellow,
        'to setup one.',
      );
      process.exit(1);
    }
    const { verbose, force } = program.opts();
    Logger.VERBOSE = Boolean(verbose);
    pluginUtil.install(plugins, { verbose, force });
  });

program
  .command('update [pluginNames...]')
  .alias('u')
  .option('-f, --force', 'Forcefully re-upgrade existing plugin') // TODO: implement update --force
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .description('Updates all or selected installed plugins to latest versions')
  .action(async plugins => {
    if (!config.find('.')) {
      Logger.errorp(
        'Not an omegga directory, run ',
        'omegga init'.yellow,
        'to setup one.',
      );
      process.exit(1);
    }
    const { verbose, force } = program.opts();
    Logger.VERBOSE = Boolean(verbose);
    pluginUtil.update(plugins, { verbose, force });
  });

program
  .command('check [pluginNames...]')
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .description('Checks plugins for compatibility issues')
  .action(async plugins => {
    if (!config.find('.')) {
      Logger.errorp(
        'Not an omegga directory, run ',
        'omegga init'.yellow,
        'to setup one.',
      );
      process.exit(1);
    }
    const { verbose } = program.opts();
    Logger.VERBOSE = Boolean(verbose);
    pluginUtil.check(plugins, { verbose });
  });

program
  .command('init-plugin')
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .description('Initializes a new plugin with the given name and settings')
  .action(async () => {
    const { verbose } = program.opts();
    Logger.VERBOSE = Boolean(verbose);

    pluginUtil.init();
  });

program
  .command('plugin-init')
  .description('Alias for ' + 'init-plugin'.yellow.underline)
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .action(async () => {
    const { verbose } = program.opts();
    Logger.VERBOSE = Boolean(verbose);

    pluginUtil.init();
  });

program
  .command('get-config <pluginName> [configName]')
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .option('-j, --json', 'Print config as json')
  .description(
    'Gets a config for a plugin. If ' +
      'configName'.yellow.underline +
      ' is omitted, returns all config values.',
  )
  .action(async (pluginName, configName) => {
    if (!config.find('.')) {
      Logger.errorp(
        'Not an omegga directory, run ',
        'omegga init'.yellow,
        'to setup one.',
      );
      process.exit(1);
    }
    const { verbose } = program.opts();
    const json = program.args.includes('-j') || program.args.includes('--json');
    Logger.VERBOSE = Boolean(verbose);
    if (!configName) {
      pluginUtil.listConfig(pluginName, json);
    } else {
      pluginUtil.getConfig(pluginName, configName, json);
    }
  });

program
  .command('set-config <pluginName> [configName] [configValue]')
  .option('-y, --yes', 'Skip confirmation prompt')
  .option('-v, --verbose', 'Print extra messages for debugging purposes')
  .description(
    'Sets a config for a plugin. If ' +
      'configValue'.yellow.underline +
      ' is omitted, the config will be reset. If ' +
      'configName'.yellow.underline +
      ' is omitted, the entire plugin config will be reset.',
  )
  .action(async (pluginName, configName, configValue) => {
    if (!config.find('.')) {
      Logger.errorp(
        'Not an omegga directory, run ',
        'omegga init'.yellow,
        'to setup one.',
      );
      process.exit(1);
    }
    const { verbose } = program.opts();
    const yes = program.args.includes('-y') || program.args.includes('--yes');
    Logger.VERBOSE = Boolean(verbose);
    if (!configName) {
      pluginUtil.resetAllConfigs(pluginName, yes);
    } else if (!configValue) {
      pluginUtil.resetConfig(pluginName, configName);
    } else {
      pluginUtil.setConfig(pluginName, configName, configValue);
    }
  });

program.parseAsync(process.argv);

async function setupSteam(config: config.IConfig, forceUpdate = false) {
  const steambeta = config?.server?.steambeta;
  const steambetaPassword = config?.server?.steambetaPassword;
  const steamcmdCommand = getSteamCmdCommand();

  const binaryPath = path.join(
    getSteamInstallDir(), // steam install directory
    steambeta ?? 'main', // steam beta branch (or main)
    getSteamGameDir(), // Brickadia
    GAME_BIN_PATH, // path to binary
  );

  if (!forceUpdate && fs.existsSync(binaryPath)) {
    Logger.verbose(
      'Game binary already exists at',
      binaryPath.yellow,
      '- skipping download.',
    );
    return;
  }

  // Check if steamcmd is installed
  if (!fs.existsSync(STEAMCMD_PATH)) {
    // Lookup steamcmd in path
    const hasSteamcmd =
      hasbin.sync(path.basename(steamcmdCommand)) || hasbin.sync('steamcmd');

    if (!hasSteamcmd) {
      // Prompt to install steamcmd
      const { install } =
        process.env.SKIP_STEAMCMD_PROMPT === 'true'
          ? { install: true }
          : await prompts({
              type: 'confirm',
              name: 'install',
              message: 'SteamCMD is not installed. OK to download it?',
              initial: true,
            });

      if (!install) {
        Logger.errorp('SteamCMD is required for steam support. Exiting...');
        process.exit(1);
      }

      Logger.logp('Downloading SteamCMD...');
    }

    try {
      steamcmdDownloadSelf();
      if (!fs.existsSync(STEAMCMD_PATH)) {
        Logger.errorp('Failed to setup SteamCMD. Exiting...');
        process.exit(1);
      }
    } catch (err) {
      Logger.errorp('Error setting up SteamCMD:', err);
      process.exit(1);
    }
  }

  Logger.logp('Downloading Brickadia', (steambeta ?? 'main').yellow, '...');
  try {
    steamcmdDownloadGame({ steambeta, steambetaPassword });
  } catch (err) {
    Logger.errorp('Error downloading Brickadia:', err);
    process.exit(1);
  }
}
