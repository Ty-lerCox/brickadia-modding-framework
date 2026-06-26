const path = require('node:path');
const cliPackage = require('../package.json');
const { resolveContext } = require('./context');
const { runDoctor } = require('./doctor');
const { listMods, setModEnabled } = require('./mods');
const {
  createHealthReport,
  createLogReport,
  createPlan,
  createServiceAction,
  createUpdateCheck,
  createUpdateInstallPlan,
  createUpdatePlan,
  createDashboardImport,
  currentProfile,
  deleteProfile,
  downloadUpdate,
  installUpdate,
  listProfiles,
  createPrerequisiteReport,
  rollbackTransaction,
  saveProfile,
  selectProfile,
  createTelemetryPlan,
  createTrafficReport,
  createTransaction,
  uploadDashboardImport,
  writeDashboardImport,
  writeTelemetryAlloy,
  OPERATION_IDS,
  SERVICE_ACTION_IDS,
} = require('./orchestrator');
const { repair, repairAll } = require('./repair');
const { createSnapshot } = require('./snapshot');
const {
  printDoctor,
  printHealth,
  printJson,
  printLogs,
  printMods,
  printPlan,
  printPrerequisites,
  printProfiles,
  printRepair,
  printRepairAll,
  printRollback,
  printServiceAction,
  printSnapshot,
  printTelemetryDashboardImport,
  printTelemetryAlloyWrite,
  printTelemetryPlan,
  printTraffic,
  printTransaction,
  printUpdateCheck,
} = require('./format');

function usage() {
  return `bmfctl

Usage:
  bmfctl doctor [--json] [--fix] [--dry-run]
  bmfctl health [--json] [--network-checks] [--port-diagnostics]
  bmfctl prerequisites [--json]
  bmfctl profiles <list|current|save|select|delete> [id] [--json]
  bmfctl repair <bmf.enable|bmf.copy|bridge.enable|bridge.copy|omegga.launchEnv|all> [--dry-run]
  bmfctl plan <bootstrap|${OPERATION_IDS.join('|')}> [--telemetry] [--json]
  bmfctl transaction <${OPERATION_IDS.join('|')}> [--release-catalog <file>] [--release-manifest <file>] [--apply --confirm apply] [--json]
  bmfctl rollback <journal.json> [--apply --confirm rollback] [--json]
  bmfctl services <${SERVICE_ACTION_IDS.join('|')}> [--apply --confirm <start|stop|restart>] [--json]
  bmfctl update <check|plan|download|install> [--release-catalog <file>] [--current-version <version>] [--json]
  bmfctl telemetry <plan|alloy|dashboard> [--out <file>] [--apply --confirm import] [--json] [--dry-run]
  bmfctl traffic [--limit <n>] [--max-bytes <n>] [--json]
  bmfctl logs [--limit <n>] [--max-bytes <n>] [--json]
  bmfctl snapshot [--out <dir>] [--snapshot-root <dir>] [--json]
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
  --bmf-runtime-dir <dir> Direct Mods/BMF/runtime directory override
  --profile <id>        Stored server profile id
  --profile-name <name> Stored server profile display name
  --profile-store <file> Profile registry override
  --alloy-executable <file> Grafana Alloy executable path
  --alloy-config <file> Grafana Alloy config path
  --dashboard-url <url> Grafana dashboard URL stored on the profile
  --network-checks      Probe Omegga /metrics and Alloy loopback readiness
  --port-diagnostics    Inspect configured local ports and report owners when available
  --scrape-interval <duration> Alloy scrape interval, e.g. 15s
  --grafana-base-url <url> Grafana stack URL for dashboard links
  --grafana-api-token-env <name> Env var containing a Grafana API token
  --limit <n>            Maximum records for traffic snapshots
  --max-lines <n>        Maximum retained log lines
  --max-bytes <n>        Maximum bytes read per traffic/log source file
  --max-sources <n>      Maximum log sources inspected
  --journal-root <dir>   Operation transaction journal directory
  --service-root <dir>   Service action journal/log directory
  --backup-root <dir>    Operation transaction backup directory
  --release-catalog <file> Desktop release-catalog.json for update checks
  --release-manifest <file> Desktop release-manifest.json for managed stack updates
  --release-channel <name> Desktop release channel, default dev
  --current-version <version> Current desktop version override
  --download-dir <dir> Desktop update download cache
  --installer-path <file> Verified BMF Desktop MSI for install handoff
  --snapshot-root <dir> Troubleshooting snapshot parent directory
  --confirm <word>       Required for mutating actions: apply, rollback, start, stop, restart, import, or download
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
    console.log(`bmfctl ${cliPackage.version}`);
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

  if (command === 'health' || command === 'status') {
    const report = await createHealthReport(options);
    if (options.json) printJson(report);
    else printHealth(report);
    process.exitCode = report.health.status === 'unhealthy' ? 2 : report.health.status === 'healthy' ? 0 : 1;
    return;
  }

  if (command === 'prerequisites' || command === 'prereqs') {
    const report = createPrerequisiteReport(options);
    if (options.json) printJson(report);
    else printPrerequisites(report);
    process.exitCode = report.status === 'blocked' ? 1 : 0;
    return;
  }

  if (command === 'profiles') {
    const action = positional[1] || 'list';
    const id = positional[2];
    let result;
    if (action === 'list') result = listProfiles(options);
    else if (action === 'current') result = currentProfile(options);
    else if (action === 'save') result = saveProfile(options);
    else if (action === 'select') {
      if (!id) throw new Error('profiles select requires an id.');
      result = selectProfile(id, options);
    } else if (action === 'delete') {
      if (!id) throw new Error('profiles delete requires an id.');
      result = deleteProfile(id, options);
    } else {
      throw new Error(`Unknown profiles action "${action}". Expected list, current, save, select, or delete.`);
    }
    if (options.json) printJson(result);
    else printProfiles(result, action);
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

  if (command === 'plan') {
    const operationId = positional[1] || 'bootstrap';
    if (operationId !== 'bootstrap' && !OPERATION_IDS.includes(operationId)) {
      throw new Error(`Unknown plan "${operationId}". Expected bootstrap or one of: ${OPERATION_IDS.join(', ')}`);
    }
    const result = createPlan(operationId, options);
    if (options.json) printJson(result);
    else printPlan(result);
    return;
  }

  if (command === 'transaction') {
    const operationId = positional[1] || 'install-stack';
    if (!OPERATION_IDS.includes(operationId)) {
      throw new Error(`Unknown transaction "${operationId}". Expected one of: ${OPERATION_IDS.join(', ')}`);
    }
    const result = createTransaction(operationId, options);
    if (options.json) printJson(result);
    else printTransaction(result);
    return;
  }

  if (command === 'rollback') {
    const journalPath = positional[1];
    if (!journalPath) throw new Error('rollback requires a transaction journal path.');
    const result = rollbackTransaction(journalPath, options);
    if (options.json) printJson(result);
    else printRollback(result);
    return;
  }

  if (command === 'services') {
    const actionId = positional[1] || 'start-stack';
    const normalizedActionId = normalizeServiceAction(actionId);
    if (!SERVICE_ACTION_IDS.includes(normalizedActionId)) {
      throw new Error(`Unknown service action "${actionId}". Expected one of: ${SERVICE_ACTION_IDS.join(', ')}`);
    }
    const result = createServiceAction(normalizedActionId, options);
    if (options.json) printJson(result);
    else printServiceAction(result);
    process.exitCode = result.status === 'blocked' || result.status === 'failed' ? 1 : 0;
    return;
  }

  if (command === 'update') {
    const action = positional[1] || 'check';
    let result;
    if (action === 'check') {
      result = createUpdateCheck(options);
    } else if (action === 'plan') {
      result = createUpdatePlan(options);
    } else if (action === 'download') {
      result = await downloadUpdate(options);
    } else if (action === 'install') {
      result = options.apply ? installUpdate(options) : createUpdateInstallPlan(options);
    } else {
      throw new Error(`Unknown update action "${action}". Expected check, plan, download, or install.`);
    }
    if (options.json) printJson(result);
    else printUpdateCheck(result);
    process.exitCode = ['invalid-catalog', 'catalog-missing', 'blocked', 'failed'].includes(result.status) ? 1 : 0;
    return;
  }

  if (command === 'telemetry') {
    const action = positional[1] || 'plan';
    if (action === 'plan') {
      const result = createTelemetryPlan(options);
      if (options.json) printJson(result);
      else printTelemetryPlan(result);
      return;
    }
    if (action === 'alloy') {
      if (!options.out && !options.alloyConfig) {
        throw new Error('telemetry alloy requires --out <file> or --alloy-config <file>.');
      }
      const result = writeTelemetryAlloy(options);
      if (options.json) printJson(result);
      else printTelemetryAlloyWrite(result);
      return;
    }
    if (action === 'dashboard') {
      const result = options.apply
        ? await uploadDashboardImport(options)
        : (options.out || options.dashboardImportPath)
        ? writeDashboardImport(options)
        : createDashboardImport(options);
      if (options.json) printJson(result);
      else printTelemetryDashboardImport(result);
      return;
    }
    throw new Error(`Unknown telemetry action "${action}". Expected plan, alloy, or dashboard.`);
  }

  if (command === 'traffic') {
    const result = createTrafficReport(options);
    if (options.json) printJson(result);
    else printTraffic(result);
    return;
  }

  if (command === 'logs') {
    const result = createLogReport(options);
    if (options.json) printJson(result);
    else printLogs(result);
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

function normalizeServiceAction(actionId) {
  const value = String(actionId || 'start-stack').toLowerCase();
  if (value === 'start') return 'start-stack';
  if (value === 'stop') return 'stop-stack';
  if (value === 'restart') return 'restart-stack';
  if (value === 'alloy-start') return 'start-alloy';
  if (value === 'alloy-stop') return 'stop-alloy';
  if (value === 'alloy-restart') return 'restart-alloy';
  return value;
}

module.exports = {
  main,
  parseArgs,
  usage,
};
