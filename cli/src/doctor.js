const path = require('node:path');
const { publicContext, resolveContext } = require('./context');
const { exists, isDirectory, listFilesRecursive, readJson, readText } = require('./file');
const { modStateForDir } = require('./mods');

const SEVERITY_RANK = {
  ok: 0,
  info: 1,
  warning: 2,
  critical: 3,
};

function finding(id, severity, title, detail, extra = {}) {
  return {
    id,
    severity,
    title,
    detail,
    evidence: extra.evidence || [],
    nextAction: extra.nextAction || null,
    repair: extra.repair || null,
  };
}

function statusFromFindings(findings) {
  const highest = findings.reduce(
    (current, item) =>
      SEVERITY_RANK[item.severity] > SEVERITY_RANK[current] ? item.severity : current,
    'ok',
  );
  return highest === 'ok' || highest === 'info' ? 'ok' : highest;
}

function summarize(findings) {
  return findings.reduce(
    (counts, item) => {
      counts[item.severity] = (counts[item.severity] || 0) + 1;
      return counts;
    },
    { ok: 0, info: 0, warning: 0, critical: 0 },
  );
}

function requiredFiles(root, files) {
  return files.map(relative => path.join(root, relative)).filter(filepath => !exists(filepath));
}

function compatibilityBundles(ctx) {
  if (!isDirectory(ctx.compatibilityRoot)) return [];
  const bundlesRoot = path.join(ctx.compatibilityRoot, 'bundles');
  const bundles = isDirectory(bundlesRoot)
    ? listFilesRecursive(bundlesRoot, filepath => path.basename(filepath) === 'manifest.json')
    : [];
  return bundles.map(manifestPath => {
    const manifest = readJson(manifestPath, {});
    return {
      manifestPath,
      build: manifest.brickadia_version_string || manifest.brickadia_cl || path.basename(path.dirname(manifestPath)),
      validated: Boolean(manifest.validated),
    };
  });
}

function requiredOmeggaLaunchEnv(ctx) {
  const bundles = compatibilityBundles(ctx);
  const hasValidatedBundle = bundles.some(bundle => bundle.validated);
  const required = [
    'OMEGGA_BMF_SOURCE_DIR',
    'OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS',
    'OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE',
  ];

  if (bundles.length > 0 && !hasValidatedBundle) {
    required.push('OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL');
  }

  return required;
}

function checkBmfRepo(ctx, findings) {
  const missing = requiredFiles(ctx.bmfRoot, [
    'manifests/bmf-package.json',
    'framework/ue4ss/Mods/BMF/bmf.json',
    'framework/ue4ss/Mods/BMF/config.json',
    'framework/ue4ss/Mods/BMF/Scripts/main.lua',
  ]);

  if (missing.length > 0) {
    findings.push(
      finding(
        'bmf.repo.incomplete',
        'critical',
        'BMF repo files are incomplete',
        'The selected BMF root is missing required framework or manifest files.',
        {
          evidence: missing,
          nextAction: 'Run bmfctl from the BMF repo or pass --bmf-root to the correct checkout.',
        },
      ),
    );
    return;
  }

  findings.push(
    finding('bmf.repo.detected', 'ok', 'BMF repo detected', `BMF ${ctx.bmfPackage?.version || 'unknown'} at ${ctx.bmfRoot}`),
  );
}

function checkOmegga(ctx, findings) {
  if (!isDirectory(ctx.omeggaDir)) {
    findings.push(
      finding(
        'omegga.runtime.missing',
        'critical',
        'BMF-compatible Omegga was not found',
        'BMF currently needs the custom Omegga runtime for UE4SS provisioning and bridge transport.',
        {
          evidence: [ctx.omeggaDir],
          nextAction: 'Pass --omegga to a BMF-compatible Omegga checkout or install the packaged Omegga-BMF runtime.',
        },
      ),
    );
    return;
  }

  const missing = [];
  if (!exists(path.join(ctx.omeggaTemplateBridgeDir, 'Scripts', 'main.lua'))) {
    missing.push(path.join(ctx.omeggaTemplateBridgeDir, 'Scripts', 'main.lua'));
  }
  if (!exists(path.join(ctx.omeggaTemplateBmfDir, 'Scripts', 'main.lua'))) {
    missing.push(path.join(ctx.omeggaTemplateBmfDir, 'Scripts', 'main.lua'));
  }
  if (!exists(path.join(ctx.omeggaTemplateBmfDir, 'bmf.json'))) {
    missing.push(path.join(ctx.omeggaTemplateBmfDir, 'bmf.json'));
  }

  if (missing.length > 0) {
    findings.push(
      finding(
        'omegga.runtime.notBmfCompatible',
        'critical',
        'Omegga checkout is not BMF-compatible',
        'The Omegga runtime exists, but its Windows UE4SS template is missing BMF or OmeggaBridge payloads.',
        {
          evidence: missing,
          nextAction: 'Use the custom Omegga-BMF package or rebuild the BMF-compatible Omegga fork.',
        },
      ),
    );
  } else {
    findings.push(
      finding(
        'omegga.runtime.compatible',
        'ok',
        'BMF-compatible Omegga template detected',
        `Omegga ${ctx.omeggaPackage?.version || 'unknown'} includes BMF and OmeggaBridge templates.`,
        {
          evidence: [ctx.omeggaTemplateModsDir],
        },
      ),
    );
  }

  if (!ctx.omeggaPackage?.scripts?.['package:bmf']) {
    findings.push(
      finding(
        'omegga.runtime.packageScriptMissing',
        'warning',
        'Omegga does not advertise package:bmf',
        'The checkout may work locally, but it does not expose the BMF packaging guardrail.',
        {
          evidence: [path.join(ctx.omeggaDir, 'package.json')],
          nextAction: 'Update to the BMF-compatible Omegga fork that includes npm run package:bmf.',
        },
      ),
    );
  }
}

function checkOmeggaRuntime(ctx, findings) {
  if (!isDirectory(ctx.omeggaDir)) return;

  const serverRuntime = path.join(ctx.omeggaDir, 'dist', 'brickadia', 'server.js');
  if (!exists(serverRuntime)) {
    findings.push(
      finding(
        'omegga.runtime.distMissing',
        'info',
        'Omegga built runtime was not found',
        'The checkout may be source-only. Runtime feature checks were skipped.',
        {
          evidence: [serverRuntime],
          nextAction: 'Run npm run build before packaging or deploying Omegga.',
        },
      ),
    );
    return;
  }

  const runtimeText = readText(serverRuntime);
  const missing = [];
  const requiredSignals = [
    ['OMEGGA_UE4SS_ALLOW_STAGED_OBJECT_CONTROL', 'staged compatibility override'],
    ['OMEGGA_UE4SS_NOOP_UNSAFE_CONSOLE_COMMANDS', 'unsafe console probe no-op guard'],
    ['OMEGGA_UE4SS_REQUIRE_COMMAND_SHAPE', 'non-command console.exec guard'],
    ['chat_broadcast', 'typed chat broadcast bridge capability'],
    ['chat_whisper', 'typed chat whisper bridge capability'],
    ['chat_status_message', 'typed chat status-message bridge capability'],
  ];

  for (const [needle, label] of requiredSignals) {
    if (!runtimeText.includes(needle)) missing.push(label);
  }

  if (missing.length > 0) {
    findings.push(
      finding(
        'omegga.runtime.ue4ssGuardMissing',
        'critical',
        'Omegga runtime is missing UE4SS safety/delivery guards',
        `Missing: ${missing.join(', ')}.`,
        {
          evidence: [serverRuntime],
          nextAction:
            'Deploy or rebuild the current BMF-compatible Omegga runtime before relying on /plugins or staged UE4SS object control.',
        },
      ),
    );
    return;
  }

  findings.push(
    finding(
      'omegga.runtime.ue4ssGuardPresent',
      'ok',
      'Omegga UE4SS runtime guards are present',
      'The deployed Omegga runtime includes typed chat delivery, staged compatibility override, unsafe-probe no-op, and non-command console.exec protection.',
      { evidence: [serverRuntime] },
    ),
  );
}

function checkOmeggaLaunchEnv(ctx, findings) {
  if (!ctx.startScript || !exists(ctx.startScript)) {
    findings.push(
      finding(
        'omegga.launchEnv.scriptMissing',
        'info',
        'Omegga launch script was not found',
        'Launch environment checks were skipped because no Start-BrickadiaOmegga.ps1 file was resolved.',
        {
          evidence: ctx.startScript ? [ctx.startScript] : [],
          nextAction: 'Pass --start-script to the PowerShell launcher used by the managed Brickadia/Omegga server.',
        },
      ),
    );
    return;
  }

  const text = readText(ctx.startScript);
  const missing = requiredOmeggaLaunchEnv(ctx).filter(name => !text.includes(`$env:${name}`));
  if (missing.length > 0) {
    findings.push(
      finding(
        'omegga.launchEnv.missing',
        'critical',
        'Omegga launch environment is missing required BMF/UE4SS flags',
        `Missing: ${missing.join(', ')}.`,
        {
          evidence: [ctx.startScript],
          nextAction: 'Run bmfctl repair omegga.launchEnv, then restart the managed Omegga scheduled task.',
          repair: {
            id: 'omegga.launchEnv',
            description: 'Add required BMF/Omegga UE4SS launch environment variables to the PowerShell start script.',
          },
        },
      ),
    );
    return;
  }

  findings.push(
    finding(
      'omegga.launchEnv.present',
      'ok',
      'Omegga launch environment includes BMF/UE4SS flags',
      'The PowerShell start script declares the required BMF source and UE4SS safety flags.',
      { evidence: [ctx.startScript] },
    ),
  );
}

function checkCompatibility(ctx, findings) {
  if (!isDirectory(ctx.compatibilityRoot)) {
    findings.push(
      finding(
        'ue4ss.compatibility.workspaceMissing',
        'warning',
        'UE4SS compatibility workspace was not found',
        'The manager could not find brickadia-ue4ss-re, so it cannot verify the pinned Brickadia compatibility bundle.',
        {
          evidence: [ctx.compatibilityRoot],
          nextAction: 'Pass --compat-root or install the compatibility workspace next to the Brickadia repo.',
        },
      ),
    );
    return;
  }

  const bundles = compatibilityBundles(ctx);
  if (bundles.length === 0) {
    findings.push(
      finding(
        'ue4ss.compatibility.bundleMissing',
        'critical',
        'No UE4SS compatibility bundle manifests were found',
        'BMF cannot verify that UE4SS signatures match the Brickadia build.',
        {
          evidence: [path.join(ctx.compatibilityRoot, 'bundles')],
          nextAction: 'Build or install a Brickadia compatibility bundle before using live object hooks.',
        },
      ),
    );
    return;
  }

  const validated = bundles.filter(bundle => bundle.validated);
  if (validated.length > 0) {
    findings.push(
      finding(
        'ue4ss.compatibility.bundleValidated',
        'ok',
        'Validated UE4SS compatibility bundle found',
        validated.map(bundle => String(bundle.build)).join(', '),
        { evidence: validated.map(bundle => bundle.manifestPath) },
      ),
    );
  } else {
    findings.push(
      finding(
        'ue4ss.compatibility.bundleStaged',
        'warning',
        'UE4SS compatibility bundles are staged but not validated',
        'The compatibility manifests exist, but none are marked validated.',
        {
          evidence: bundles.map(bundle => bundle.manifestPath),
          nextAction: 'Complete live validation for the current Brickadia CL before treating object-control hooks as production safe.',
        },
      ),
    );
  }
}

function checkLiveMods(ctx, findings) {
  if (!ctx.gameWin64Dir) {
    findings.push(
      finding(
        'brickadia.win64.unknown',
        'warning',
        'Brickadia Win64 directory was not detected',
        'Live UE4SS install and mod enablement checks were skipped.',
        {
          nextAction: 'Pass --game-win64 to the Brickadia Binaries\\Win64 directory or set BMF_GAME_WIN64_DIR.',
        },
      ),
    );
    return;
  }

  const proxyDll = path.join(ctx.gameWin64Dir, 'dwmapi.dll');
  if (!exists(proxyDll)) {
    findings.push(
      finding(
        'ue4ss.live.proxyMissing',
        'warning',
        'UE4SS proxy DLL is not installed',
        'The Brickadia Win64 directory does not contain dwmapi.dll.',
        {
          evidence: [proxyDll],
          nextAction: 'Run the BMF-compatible Omegga UE4SS install step.',
        },
      ),
    );
  }

  const existingModsDirs = ctx.liveModsDirs.filter(isDirectory);
  if (existingModsDirs.length === 0) {
    findings.push(
      finding(
        'ue4ss.live.modsMissing',
        'critical',
        'No live UE4SS Mods directories were found',
        'The selected Brickadia Win64 directory does not appear to have a managed UE4SS install.',
        {
          evidence: ctx.liveModsDirs,
          nextAction: 'Run Omegga UE4SS install, then rerun bmfctl doctor.',
        },
      ),
    );
    return;
  }

  for (const modsDir of existingModsDirs) {
    checkMod(ctx, findings, modsDir, 'BMF', ctx.bmfSourceDir, 'bmf');
    checkMod(ctx, findings, modsDir, 'OmeggaBridge', ctx.omeggaTemplateBridgeDir, 'bridge');
  }
}

function checkMod(ctx, findings, modsDir, modName, sourceDir, repairPrefix) {
  const state = modStateForDir(modsDir, modName);
  if (!state.folderExists) {
    findings.push(
      finding(
        `ue4ss.live.${repairPrefix}Missing`,
        'critical',
        `${modName} is missing from live UE4SS Mods`,
        `${modsDir} does not contain a ${modName} folder.`,
        {
          evidence: [state.folderPath],
          nextAction: `Run bmfctl repair ${repairPrefix}.copy`,
          repair: {
            id: `${repairPrefix}.copy`,
            description: `Copy ${modName} from the managed source into live UE4SS Mods directories.`,
            sourceDir,
          },
        },
      ),
    );
    return;
  }

  const disabledEvidence = [];
  if (state.txtEnabled !== true) disabledEvidence.push(`${state.modsTxtPath}: ${modName} is not enabled`);
  if (state.jsonEnabled !== true) disabledEvidence.push(`${state.modsJsonPath}: ${modName} is not enabled`);

  if (disabledEvidence.length > 0) {
    findings.push(
      finding(
        `ue4ss.live.${repairPrefix}Disabled`,
        'critical',
        `${modName} is installed but not enabled`,
        `${modName} exists in ${modsDir}, but mods.txt or mods.json does not enable it.`,
        {
          evidence: disabledEvidence,
          nextAction: `Run bmfctl repair ${repairPrefix}.enable`,
          repair: {
            id: `${repairPrefix}.enable`,
            description: `Enable ${modName} in mods.txt and mods.json.`,
          },
        },
      ),
    );
  } else {
    findings.push(
      finding(
        `ue4ss.live.${repairPrefix}Enabled`,
        'ok',
        `${modName} is installed and enabled`,
        `${modName} is enabled in ${modsDir}.`,
        { evidence: [modsDir] },
      ),
    );
  }
}

function checkLogs(ctx, findings) {
  if (!ctx.gameWin64Dir) return;
  const ue4ssRoot = path.join(ctx.gameWin64Dir, 'ue4ss');
  const logs = listFilesRecursive(ue4ssRoot, filepath => path.basename(filepath).toLowerCase() === 'ue4ss.log');
  if (logs.length === 0) {
    findings.push(
      finding(
        'ue4ss.logs.missing',
        'info',
        'No UE4SS log was found',
        'This is normal before the first server launch after UE4SS installation.',
        { evidence: [ue4ssRoot] },
      ),
    );
    return;
  }

  for (const logPath of logs) {
    const text = readText(logPath);
    const badSignals = ['Scan failed', 'Fatal error', 'Unhandled Exception', 'Failed to find FName'];
    const matched = badSignals.filter(signal => text.includes(signal));
    if (matched.length > 0) {
      findings.push(
        finding(
          'ue4ss.logs.failureSignals',
          'warning',
          'UE4SS log contains failure signals',
          matched.join(', '),
          {
            evidence: [logPath],
            nextAction: 'Inspect the UE4SS compatibility bundle and Brickadia CL before trusting live hooks.',
          },
        ),
      );
    }
  }
}

function checkBridgeRuntime(ctx, findings) {
  if (ctx.bridgeRuntimeDirs.length === 0) {
    findings.push(
      finding(
        'omegga.bridge.runtimeMissing',
        'info',
        'No Omegga bridge runtime sessions were found',
        'This is normal before the managed server has been launched.',
        { evidence: [path.join(ctx.omeggaDir, 'data')] },
      ),
    );
    return;
  }

  const statuses = ctx.bridgeRuntimeDirs
    .map(dir => ({ dir, statusPath: path.join(dir, 'status.json') }))
    .filter(item => exists(item.statusPath));

  if (statuses.length === 0) {
    findings.push(
      finding(
        'omegga.bridge.statusMissing',
        'warning',
        'Omegga bridge sessions exist without status files',
        'The bridge runtime directories exist, but no status.json was found.',
        {
          evidence: ctx.bridgeRuntimeDirs,
          nextAction: 'Restart the managed Omegga server and check UE4SS bridge startup logs.',
        },
      ),
    );
    return;
  }

  findings.push(
    finding(
      'omegga.bridge.statusPresent',
      'ok',
      'Omegga bridge status files found',
      `${statuses.length} bridge status file(s) found.`,
      { evidence: statuses.map(item => item.statusPath) },
    ),
  );
}

function runDoctor(options = {}) {
  const ctx = resolveContext(options);
  const findings = [];
  checkBmfRepo(ctx, findings);
  checkOmegga(ctx, findings);
  checkOmeggaRuntime(ctx, findings);
  checkCompatibility(ctx, findings);
  checkOmeggaLaunchEnv(ctx, findings);
  checkLiveMods(ctx, findings);
  checkLogs(ctx, findings);
  checkBridgeRuntime(ctx, findings);

  return {
    tool: 'bmfctl',
    command: 'doctor',
    status: statusFromFindings(findings),
    summary: summarize(findings),
    context: publicContext(ctx),
    findings,
  };
}

module.exports = {
  runDoctor,
  statusFromFindings,
};
