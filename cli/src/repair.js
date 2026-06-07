const path = require('node:path');
const { resolveContext } = require('./context');
const {
  backupDirectory,
  backupFile,
  copyDirectory,
  ensureDir,
  exists,
  isDirectory,
  readText,
  timestamp,
  writeJson,
  writeText,
} = require('./file');
const { setModEnabled } = require('./mods');
const { runDoctor } = require('./doctor');

const REPAIR_DEFINITIONS = {
  'bmf.enable': {
    title: 'Enable BMF in live UE4SS mods.txt and mods.json',
    modName: 'BMF',
    kind: 'enable',
  },
  'bridge.enable': {
    title: 'Enable OmeggaBridge in live UE4SS mods.txt and mods.json',
    modName: 'OmeggaBridge',
    kind: 'enable',
  },
  'bmf.copy': {
    title: 'Copy BMF into live UE4SS Mods directories',
    modName: 'BMF',
    kind: 'copy',
    source: ctx => ctx.bmfSourceDir,
  },
  'bridge.copy': {
    title: 'Copy OmeggaBridge into live UE4SS Mods directories',
    modName: 'OmeggaBridge',
    kind: 'copy',
    source: ctx => ctx.omeggaTemplateBridgeDir,
  },
  'omegga.launchEnv': {
    title: 'Add BMF/Omegga UE4SS launch environment flags',
    kind: 'start-script-env',
  },
};

const OMEGGA_LAUNCH_ENV = {
  OMEGGA_BMF_SOURCE_DIR: ctx => `Join-Path $omegga 'templates\\windows-ue4ss\\ue4ss\\Mods\\BMF'`,
  OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL: () => "'1'",
  OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS: () => "'1'",
  OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE: () => "'1'",
};

function requiredLaunchEnvNames(ctx) {
  const compatibilityRoot = ctx.compatibilityRoot;
  const bundlesRoot = path.join(compatibilityRoot, 'bundles');
  const fs = require('node:fs');
  let hasValidatedBundle = false;
  let hasBundles = false;
  if (isDirectory(bundlesRoot)) {
    for (const entry of fs.readdirSync(bundlesRoot, { withFileTypes: true })) {
      const manifestPath = path.join(bundlesRoot, entry.name, 'manifest.json');
      if (!entry.isDirectory() || !exists(manifestPath)) continue;
      hasBundles = true;
      try {
        hasValidatedBundle = hasValidatedBundle || Boolean(JSON.parse(readText(manifestPath)).validated);
      } catch {}
    }
  }

  const names = [
    'OMEGGA_BMF_SOURCE_DIR',
    'OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS',
    'OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE',
  ];
  if (hasBundles && !hasValidatedBundle) names.push('OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL');
  return names;
}

function upsertPowerShellEnv(text, name, valueExpression) {
  const line = `$env:${name} = ${valueExpression}`;
  const pattern = new RegExp(`^\\s*\\$env:${name}\\s*=.*$`, 'm');
  if (pattern.test(text)) {
    return {
      text: text.replace(pattern, line),
      changed: !text.match(pattern)?.[0]?.includes(valueExpression),
      action: 'update-env',
    };
  }

  const newline = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const anchor = lines.findIndex(current =>
    /\$env:(?:OMEGGA_UE4SS_ALLOW_DEGRADED_WORLD_COMMANDS|OMEGGA_BMF_SOURCE_DIR)\b/.test(current),
  );
  const insertAt = anchor >= 0 ? anchor + 1 : lines.length;
  lines.splice(insertAt, 0, line);
  return {
    text: lines.join(newline),
    changed: true,
    action: 'add-env',
  };
}

function targetModsDirs(ctx, options = {}) {
  if (options.modsDir) return [path.resolve(options.modsDir)];
  const existing = ctx.liveModsDirs.filter(isDirectory);
  if (existing.length > 0) return existing;
  return ctx.liveModsDirs;
}

function writeRepairLog(ctx, repairId, result, backupRoot, dryRun) {
  if (dryRun) return null;
  const logDir = path.join(ctx.bmfRoot, 'artifacts', 'bmfctl', 'repairs');
  ensureDir(logDir);
  const logPath = path.join(logDir, `${timestamp()}-${repairId.replace(/[^\w.-]/g, '_')}.json`);
  writeJson(logPath, {
    tool: 'bmfctl',
    command: 'repair',
    repairId,
    backupRoot,
    result,
    createdAt: new Date().toISOString(),
  });
  return logPath;
}

function repair(repairId, options = {}) {
  const ctx = resolveContext(options);
  const definition = REPAIR_DEFINITIONS[repairId];
  if (!definition) {
    throw new Error(
      `Unknown repair "${repairId}". Known repairs: ${Object.keys(REPAIR_DEFINITIONS).join(', ')}`,
    );
  }

  const dryRun = Boolean(options.dryRun);
  const backupRoot = path.join(ctx.bmfRoot, 'artifacts', 'bmfctl', 'backups', timestamp());
  const result = {
    repairId,
    title: definition.title,
    dryRun,
    targets: [],
    changes: [],
    backupRoot: dryRun ? null : backupRoot,
    logPath: null,
  };

  if (definition.kind === 'start-script-env') {
    if (!ctx.startScript || !exists(ctx.startScript)) {
      throw new Error('No Omegga PowerShell start script was resolved. Pass --start-script.');
    }

    const before = readText(ctx.startScript);
    let after = before;
    const backupPath = dryRun ? null : backupFile(ctx.startScript, backupRoot);
    for (const name of requiredLaunchEnvNames(ctx)) {
      const valueExpression = OMEGGA_LAUNCH_ENV[name](ctx);
      const updated = upsertPowerShellEnv(after, name, valueExpression);
      after = updated.text;
      if (updated.changed) {
        result.changes.push({
          action: dryRun ? `would-${updated.action}` : updated.action,
          path: ctx.startScript,
          name,
          value: valueExpression,
          backupPath,
        });
      }
    }

    result.targets.push(ctx.startScript);
    if (!dryRun && after !== before) writeText(ctx.startScript, after);
    result.logPath = writeRepairLog(ctx, repairId, result, backupRoot, dryRun);
    return result;
  }

  const targets = targetModsDirs(ctx, options);
  if (targets.length === 0) {
    throw new Error('No target UE4SS Mods directories were resolved. Pass --mods-dir or --game-win64.');
  }

  for (const modsDir of targets) {
    if (definition.kind === 'enable') {
      const change = setModEnabled(modsDir, definition.modName, true, {
        dryRun,
        backupRoot,
      });
      result.targets.push(modsDir);
      result.changes.push(...change.changes);
      continue;
    }

    if (definition.kind === 'copy') {
      const sourceDir = definition.source(ctx);
      if (!isDirectory(sourceDir)) {
        throw new Error(`Cannot apply ${repairId}: source directory is missing: ${sourceDir}`);
      }

      const destination = path.join(modsDir, definition.modName);
      const backupPath = exists(destination) && !dryRun ? backupDirectory(destination, backupRoot) : null;
      result.targets.push(destination);
      result.changes.push({
        action: dryRun ? 'would-copy' : 'copy',
        source: sourceDir,
        path: destination,
        backupPath,
      });
      if (!dryRun) copyDirectory(sourceDir, destination);
    }
  }

  result.logPath = writeRepairLog(ctx, repairId, result, backupRoot, dryRun);
  return result;
}

function repairIdsFromDoctor(report) {
  return Array.from(
    new Set(
      report.findings
        .filter(item => item.repair?.id && (item.severity === 'critical' || item.severity === 'warning'))
        .map(item => item.repair.id),
    ),
  );
}

function repairAll(options = {}) {
  const before = runDoctor(options);
  const repairIds = repairIdsFromDoctor(before);
  const repairs = repairIds.map(id => repair(id, options));
  const after = options.dryRun ? null : runDoctor(options);
  return {
    before,
    repairs,
    after,
  };
}

module.exports = {
  REPAIR_DEFINITIONS,
  repair,
  repairAll,
  repairIdsFromDoctor,
};
