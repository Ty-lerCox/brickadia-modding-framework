const path = require('node:path');
const { resolveContext } = require('./context');
const { runDoctor } = require('./doctor');
const { listMods, setModEnabled } = require('./mods');
const { repair, repairAll } = require('./repair');
const { createSnapshot } = require('./snapshot');
const {
  printDoctor,
  printJson,
  printMods,
  printRepair,
  printRepairAll,
  printSnapshot,
} = require('./format');

function usage() {
  return `bmfctl

Usage:
  bmfctl doctor [--json] [--fix] [--dry-run]
  bmfctl repair <bmf.enable|bmf.copy|bridge.enable|bridge.copy|omegga.launchEnv|all> [--dry-run]
  bmfctl snapshot [--out <dir>] [--json]
  bmfctl mods list [--mods-dir <dir>] [--json]
  bmfctl mods enable <name> [--mods-dir <dir>] [--dry-run]
  bmfctl mods disable <name> [--mods-dir <dir>] [--dry-run]
  bmfctl paths [--json]

Common options:
  --bmf-root <dir>      BMF repo root
  --omegga <dir>        BMF-compatible Omegga checkout
  --compat-root <dir>   brickadia-ue4ss-re workspace
  --game-win64 <dir>    Brickadia/Binaries/Win64 directory
  --mods-dir <dir>      Direct UE4SS Mods directory override
  --start-script <file> Omegga PowerShell start script
`;
}

function parseArgs(argv) {
  const options = {};
  const positional = [];
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }

    const key = arg.slice(2);
    if (key.startsWith('no-')) {
      options[toCamel(key.slice(3))] = false;
      continue;
    }

    const next = argv[index + 1];
    if (!next || next.startsWith('--')) {
      options[toCamel(key)] = true;
      continue;
    }

    options[toCamel(key)] = next;
    index++;
  }
  return { positional, options };
}

function toCamel(value) {
  return value.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
}

function defaultModsDir(ctx, options) {
  if (options.modsDir) return path.resolve(options.modsDir);
  return ctx.liveModsDirs.find(dir => require('node:fs').existsSync(dir)) || ctx.liveModsDirs[0] || ctx.omeggaTemplateModsDir;
}

async function main(argv) {
  const { positional, options } = parseArgs(argv);
  const command = positional[0] || 'help';

  if (command === 'help' || options.help) {
    console.log(usage());
    return;
  }

  if (command === 'version' || options.version) {
    console.log('bmfctl 0.1.0-dev');
    return;
  }

  if (command === 'doctor') {
    if (options.fix) {
      const result = repairAll(options);
      if (options.json) printJson(result);
      else printRepairAll(result);
      process.exitCode = result.after && result.after.status === 'critical' ? 2 : 0;
      return;
    }
    const report = runDoctor(options);
    if (options.json) printJson(report);
    else printDoctor(report);
    process.exitCode = report.status === 'critical' ? 2 : report.status === 'warning' ? 1 : 0;
    return;
  }

  if (command === 'repair') {
    const repairId = positional[1];
    if (!repairId) throw new Error('repair requires an id. Try bmfctl repair all --dry-run');
    if (repairId === 'all') {
      const result = repairAll(options);
      if (options.json) printJson(result);
      else printRepairAll(result);
      return;
    }
    const result = repair(repairId, options);
    if (options.json) printJson(result);
    else printRepair(result);
    return;
  }

  if (command === 'snapshot') {
    const result = createSnapshot(options);
    if (options.json) printJson(result);
    else printSnapshot(result);
    return;
  }

  if (command === 'mods') {
    const action = positional[1] || 'list';
    const modName = positional[2];
    const ctx = resolveContext(options);
    const modsDir = defaultModsDir(ctx, options);
    if (!modsDir) throw new Error('No Mods directory was resolved. Pass --mods-dir or --game-win64.');

    if (action === 'list') {
      const mods = listMods(modsDir);
      if (options.json) printJson({ modsDir, mods });
      else printMods(modsDir, mods);
      return;
    }

    if (!modName) throw new Error(`mods ${action} requires a mod name.`);
    if (action !== 'enable' && action !== 'disable') {
      throw new Error(`Unknown mods action "${action}". Expected list, enable, or disable.`);
    }

    const result = setModEnabled(modsDir, modName, action === 'enable', {
      dryRun: options.dryRun,
    });
    if (options.json) printJson(result);
    else {
      console.log(`${options.dryRun ? 'Dry run' : 'Updated'}: ${modName} ${action} in ${modsDir}`);
      for (const change of result.changes) console.log(`- ${change.action}: ${change.path}`);
      if (result.changes.length === 0) console.log('- no changes needed');
    }
    return;
  }

  if (command === 'paths') {
    const ctx = resolveContext(options);
    if (options.json) printJson(ctx);
    else {
      console.log(`BMF root: ${ctx.bmfRoot}`);
      console.log(`Omegga:   ${ctx.omeggaDir}`);
      console.log(`Win64:    ${ctx.gameWin64Dir || '(not detected)'}`);
      console.log(`Compat:   ${ctx.compatibilityRoot}`);
      console.log(`Saved:    ${ctx.savedDir}`);
      for (const dir of ctx.liveModsDirs) console.log(`Mods:     ${dir}`);
    }
    return;
  }

  throw new Error(`Unknown command "${command}".\n\n${usage()}`);
}

module.exports = {
  main,
  parseArgs,
  usage,
};
