const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { createOperationPlan } = require('./operations');
const { createServerProfile, publicProfile } = require('./profiles');
const { collectLocalProfileStatus, resolveRuntimePaths } = require('./observations');
const { createTelemetryOnboardingPlan } = require('./telemetry');

const TRANSACTION_GUARDRAILS = [
  'dry-run-by-default',
  'explicit-apply-confirmation-required',
  'target-path-scope-validation',
  'backup-before-overwrite',
  'journal-every-applied-step',
  'rollback-instructions-generated',
  'redact-secrets-before-display-or-export',
  'do-not-add-ui-driven-server-probes',
];

const TRANSACTION_OPERATION_IDS = [
  'install-stack',
  'repair-stack',
  'update-stack',
  'configure-telemetry',
];

const ROLLBACK_GUARDRAILS = [
  'dry-run-by-default',
  'explicit-rollback-confirmation-required',
  'target-path-scope-validation',
  'restore-only-from-transaction-backups',
  'backup-before-rollback-overwrite',
  'journal-every-applied-step',
  'redact-secrets-before-display-or-export',
  'do-not-add-ui-driven-server-probes',
];

function createOperationTransaction(operationId, input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const root = resolveRoot(options.root || profile.paths?.bmfRoot || profile.root);
  const paths = resolveRuntimePaths(profile);
  const dryRun = options.dryRun !== false;
  const createdAt = toIso(options.now || new Date());
  const transactionId = options.transactionId || makeTransactionId(operationId, createdAt);
  const journalRoot = path.resolve(options.journalRoot || path.join(root, 'artifacts', 'local', 'transactions'));
  const backupRoot = path.resolve(options.backupRoot || path.join(journalRoot, transactionId, 'backups'));
  const journalPath = path.join(journalRoot, `${transactionId}.json`);
  const plan = createOperationPlan(operationId, {
    ...options,
    root,
    profile,
    dryRun: true,
  });
  const context = buildTransactionContext(root, profile, paths, {
    backupRoot,
    journalPath,
    journalRoot,
    now: createdAt,
    ...options,
  });
  const concreteSteps = buildConcreteSteps(operationId, context);
  const unsupportedActions = plan.actions
    .filter(action => !concreteSteps.some(step => step.actionId === action.id))
    .map(action => ({
      actionId: action.id,
      title: action.title,
      component: action.component,
      kind: action.kind,
      reason: unsupportedReason(action.kind),
    }));
  const steps = concreteSteps.map(step => decorateStep(step, context));
  const summary = summarizeTransactionSteps(steps, unsupportedActions);

  return {
    schemaVersion: 1,
    transactionId,
    operationId,
    title: `${plan.title} transaction`,
    dryRun,
    status: summary.blocked > 0 ? 'blocked' : dryRun ? 'planned' : 'ready',
    createdAt,
    profile: publicProfile(profile),
    journalPath,
    backupRoot,
    allowedTargetRoots: context.allowTargetRoots,
    guardrails: TRANSACTION_GUARDRAILS,
    summary,
    steps,
    unsupportedActions,
    rollback: buildRollbackPreview(steps),
  };
}

function executeOperationTransaction(operationId, input = {}, options = {}) {
  const dryRun = options.dryRun !== false;
  if (dryRun) return createOperationTransaction(operationId, input, { ...options, dryRun: true });
  if (String(options.confirm || '').toLowerCase() !== 'apply') {
    throw new Error('Refusing to apply transaction without --confirm apply.');
  }

  const transaction = createOperationTransaction(operationId, input, { ...options, dryRun: false, includeContent: true });
  const applied = [];
  const errors = [];
  const rollback = [];
  let status = transaction.status === 'blocked' ? 'blocked' : 'applied';

  ensureDir(path.dirname(transaction.journalPath));
  ensureDir(transaction.backupRoot);

  for (const step of transaction.steps) {
    if (step.status !== 'ready') {
      applied.push({
        ...step,
        applied: false,
        result: 'skipped',
        reason: step.blockedReason || 'step is not ready',
      });
      continue;
    }

    try {
      const result = applyStep(step, transaction);
      applied.push({
        ...step,
        applied: true,
        result: 'applied',
        metadata: result.metadata || step.metadata,
        backupPath: result.backupPath,
        sha256: result.sha256,
      });
      if (result.rollback) rollback.push({ stepId: step.id, ...result.rollback });
      writeTransactionJournal({
        ...transaction,
        status,
        applied,
        errors,
        rollback,
      });
    } catch (error) {
      status = 'failed';
      errors.push({
        stepId: step.id,
        message: error.message || String(error),
      });
      applied.push({
        ...step,
        applied: false,
        result: 'failed',
        error: error.message || String(error),
      });
      break;
    }
  }

  const result = {
    ...transaction,
    status,
    finishedAt: toIso(new Date()),
    applied,
    errors,
    rollback,
  };
  writeTransactionJournal(result);
  return redactTransaction(result);
}

function createRollbackTransaction(journalPath, options = {}) {
  if (!journalPath) throw new Error('Rollback requires a transaction journal path.');

  const sourceJournalPath = path.resolve(journalPath);
  const source = loadTransactionJournal(sourceJournalPath);
  const createdAt = toIso(options.now || new Date());
  const sourceId = source.transactionId || source.operationId || 'transaction';
  const rollbackId = options.rollbackId || makeTransactionId(`rollback-${sourceId}`, createdAt);
  const journalRoot = path.resolve(options.journalRoot || path.dirname(sourceJournalPath));
  const rollbackJournalPath = path.join(journalRoot, `${rollbackId}.json`);
  const backupRoot = path.resolve(options.backupRoot || path.join(journalRoot, rollbackId, 'backups'));
  const allowedRoots = compact([...(source.allowedTargetRoots || []), ...(options.allowTargetRoots || [])]).map(item => path.resolve(item));
  const sourceBackupRoot = source.backupRoot ? path.resolve(source.backupRoot) : null;
  const dryRun = options.dryRun !== false;
  const steps = buildRollbackSteps(source, {
    allowedRoots,
    sourceBackupRoot,
  });
  const summary = summarizeRollbackSteps(steps);

  return {
    schemaVersion: 1,
    rollbackId,
    sourceTransactionId: source.transactionId || null,
    operationId: source.operationId || null,
    title: `Rollback ${source.operationId || source.transactionId || 'transaction'}`,
    dryRun,
    status: summary.blocked > 0 ? 'blocked' : dryRun ? 'planned' : 'ready',
    createdAt,
    sourceJournalPath,
    journalPath: rollbackJournalPath,
    backupRoot,
    sourceBackupRoot,
    allowedTargetRoots: allowedRoots,
    guardrails: ROLLBACK_GUARDRAILS,
    summary,
    steps,
  };
}

function executeRollbackTransaction(journalPath, options = {}) {
  const dryRun = options.dryRun !== false;
  if (dryRun) return createRollbackTransaction(journalPath, { ...options, dryRun: true });
  if (String(options.confirm || '').toLowerCase() !== 'rollback') {
    throw new Error('Refusing to apply rollback without --confirm rollback.');
  }

  const rollback = createRollbackTransaction(journalPath, { ...options, dryRun: false });
  if (rollback.summary.blocked > 0) {
    throw new Error('Refusing to apply rollback while one or more rollback steps are blocked.');
  }

  const applied = [];
  const errors = [];
  let status = 'rolled-back';

  ensureDir(path.dirname(rollback.journalPath));
  ensureDir(rollback.backupRoot);

  for (const step of rollback.steps) {
    try {
      const result = applyRollbackStep(step, rollback);
      applied.push({
        ...step,
        applied: true,
        result: result.result || 'applied',
        rollbackBackupPath: result.rollbackBackupPath,
        sha256: result.sha256,
      });
      writeTransactionJournal({
        ...rollback,
        status,
        applied,
        errors,
      });
    } catch (error) {
      status = 'failed';
      errors.push({
        stepId: step.id,
        message: error.message || String(error),
      });
      applied.push({
        ...step,
        applied: false,
        result: 'failed',
        error: error.message || String(error),
      });
      break;
    }
  }

  const result = {
    ...rollback,
    status,
    finishedAt: toIso(new Date()),
    applied,
    errors,
  };
  writeTransactionJournal(result);
  return redactTransaction(result);
}

function buildTransactionContext(root, profile, paths, options) {
  return {
    root,
    profile,
    paths,
    backupRoot: options.backupRoot,
    journalPath: options.journalPath,
    journalRoot: options.journalRoot,
    now: options.now,
    allowTargetRoots: allowedTargetRoots(root, profile, paths, [
      options.journalRoot,
      options.backupRoot,
      ...(options.allowTargetRoots || []),
    ]),
    env: options.env || process.env,
    scrapeInterval: options.scrapeInterval,
    grafanaBaseUrl: options.grafanaBaseUrl,
    folderUid: options.folderUid,
    prometheusDatasourceUid: options.prometheusDatasourceUid,
    manifest: options.manifest,
    releaseCatalogPath: normalizeNullablePath(
      options.releaseCatalogPath
      || options.releaseCatalog
      || options.catalogPath
      || path.join(root, 'artifacts', 'local', 'bmf-desktop-release', 'release-catalog.json'),
    ),
    releaseManifestPath: normalizeNullablePath(
      options.releaseManifestPath
      || options.releaseManifest
      || options.manifestPath
      || path.join(root, 'artifacts', 'local', 'bmf-desktop-release', 'release-manifest.json'),
    ),
    includeContent: Boolean(options.includeContent),
  };
}

function buildConcreteSteps(operationId, context) {
  if (!TRANSACTION_OPERATION_IDS.includes(operationId)) return [];
  if (operationId === 'configure-telemetry') return telemetrySteps(context);
  if (operationId === 'repair-stack') return repairStackSteps(context);
  if (operationId === 'install-stack' || operationId === 'update-stack') {
    return [
      ...(operationId === 'update-stack' ? updateReleaseEvidenceSteps(context) : []),
      ...omeggaRuntimeSteps(context, operationId),
      ...runtimeAssetSteps(context, operationId),
      ...omeggaPluginSteps(context, operationId),
      ...profileMetadataSteps(context, operationId),
      ...(context.profile.telemetry.enabled ? telemetrySteps(context) : []),
    ];
  }
  return [];
}

function repairStackSteps(context) {
  return [
    healthSnapshotStep('repair-preflight-health', 'run-doctor', 'Collect current repair findings', context, 'before-repair'),
    writeJsonStep(
      'snapshot-repair-mutable-files',
      'backup-mutable-files',
      'Snapshot mutable files before repair',
      repairMutableSnapshotPath(context),
      buildRepairMutableSnapshot(context),
    ),
    ...repairLaunchEnvSteps(context),
    ...repairMissingRuntimeFileSteps(context),
    ...repairModEnablementSteps(context),
    healthSnapshotStep('repair-verification-health', 'verify-after-repair', 'Collect post-repair verification findings', context, 'after-repair'),
  ];
}

function repairLaunchEnvSteps(context) {
  if (!context.profile.paths?.omeggaRuntime) {
    return [
      blockedStep('repair-omegga-start-script', 'repair-launch-env', 'Repair BMF Omegga bootstrap start script', 'Omegga runtime path is not configured.'),
    ];
  }
  if (isPackagedOmeggaSource(context.root, context.profile.paths.omeggaRuntime)) {
    return [
      blockedStep('repair-omegga-start-script', 'repair-launch-env', 'Repair BMF Omegga bootstrap start script', 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
    ];
  }
  return [
    writeTextStep(
      'repair-omegga-start-script',
      'repair-launch-env',
      'Repair BMF Omegga bootstrap start script',
      path.join(path.resolve(context.profile.paths.omeggaRuntime), 'Start-BrickadiaOmegga.ps1'),
      renderOmeggaStartScript(),
    ),
  ];
}

function repairModEnablementSteps(context) {
  const modsDir = context.paths.ue4ssModsDir;
  if (!modsDir) {
    return [
      blockedStep('repair-bmf-enabled-file', 'repair-mod-enablement', 'Repair BMF UE4SS enabled marker', 'UE4SS Mods directory is not configured.'),
      blockedStep('repair-mods-txt', 'repair-mod-enablement', 'Repair UE4SS mods.txt BMF enablement', 'UE4SS Mods directory is not configured.'),
      blockedStep('repair-mods-json', 'repair-mod-enablement', 'Repair UE4SS mods.json BMF enablement', 'UE4SS Mods directory is not configured.'),
    ];
  }
  const modsTxtPath = path.join(modsDir, 'mods.txt');
  const modsJsonPath = path.join(modsDir, 'mods.json');
  return [
    writeTextStep(
      'repair-bmf-enabled-file',
      'repair-mod-enablement',
      'Repair BMF UE4SS enabled marker',
      context.paths.bmfEnabled,
      '\n',
    ),
    writeTextStep(
      'repair-mods-txt',
      'repair-mod-enablement',
      'Repair UE4SS mods.txt BMF enablement',
      modsTxtPath,
      setModInTxt(readTextFile(modsTxtPath, ''), 'BMF', true),
    ),
    writeJsonStep(
      'repair-mods-json',
      'repair-mod-enablement',
      'Repair UE4SS mods.json BMF enablement',
      modsJsonPath,
      setModInJson(readTextFile(modsJsonPath, '[]\n'), 'BMF', true),
    ),
  ];
}

function repairMissingRuntimeFileSteps(context) {
  const modsDir = context.paths.ue4ssModsDir;
  const steps = [
    copyDirectoryStep(
      'repair-bmf-runtime-files',
      'repair-missing-runtime-files',
      'Repair missing BMF Lua runtime files',
      path.join(context.root, 'framework', 'ue4ss', 'Mods', 'BMF'),
      context.paths.bmfModDir,
    ),
    copyDirectoryStep(
      'repair-bmf-socket-files',
      'repair-missing-runtime-files',
      'Repair missing BMFSocket helper files',
      path.join(context.root, 'framework', 'ue4ss', 'Mods', 'BMFSocket'),
      modsDir ? path.join(modsDir, 'BMFSocket') : null,
    ),
    copyDirectoryStep(
      'repair-frame-telemetry-files',
      'repair-missing-runtime-files',
      'Repair missing BMFFrameTelemetry helper files',
      path.join(context.root, 'framework', 'ue4ss', 'Mods', 'BMFFrameTelemetry'),
      modsDir ? path.join(modsDir, 'BMFFrameTelemetry') : null,
      { optional: true },
    ),
  ];

  if (!context.profile.paths?.omeggaRuntime) {
    steps.push(
      blockedStep('repair-generic-bridge-plugin', 'repair-missing-runtime-files', 'Repair generic BMF bridge Omegga plugin', 'Omegga runtime path is not configured.'),
      blockedStep('repair-player-sync-adapter', 'repair-missing-runtime-files', 'Repair BMF player sync Omegga adapter', 'Omegga runtime path is not configured.'),
      blockedStep('repair-minigame-events-adapter', 'repair-missing-runtime-files', 'Repair BMF minigame events Omegga adapter', 'Omegga runtime path is not configured.'),
    );
    return steps;
  }
  if (isPackagedOmeggaSource(context.root, context.profile.paths.omeggaRuntime)) {
    steps.push(
      blockedStep('repair-generic-bridge-plugin', 'repair-missing-runtime-files', 'Repair generic BMF bridge Omegga plugin', 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
      blockedStep('repair-player-sync-adapter', 'repair-missing-runtime-files', 'Repair BMF player sync Omegga adapter', 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
      blockedStep('repair-minigame-events-adapter', 'repair-missing-runtime-files', 'Repair BMF minigame events Omegga adapter', 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
    );
    return steps;
  }

  const pluginsDir = path.join(path.resolve(context.profile.paths.omeggaRuntime), 'plugins');
  steps.push(
    copyDirectoryStep(
      'repair-generic-bridge-plugin',
      'repair-missing-runtime-files',
      'Repair generic BMF bridge Omegga plugin',
      path.join(context.root, 'packages', 'omegga-plugins', 'bmf-bridge'),
      path.join(pluginsDir, 'bmf-bridge'),
    ),
    copyDirectoryStep(
      'repair-player-sync-adapter',
      'repair-missing-runtime-files',
      'Repair BMF player sync Omegga adapter',
      path.join(context.root, 'packages', 'omegga-plugins', 'bmf-player-sync'),
      path.join(pluginsDir, 'bmf-player-sync'),
    ),
    copyDirectoryStep(
      'repair-minigame-events-adapter',
      'repair-missing-runtime-files',
      'Repair BMF minigame events Omegga adapter',
      path.join(context.root, 'packages', 'omegga-plugins', 'bmf-minigame-events'),
      path.join(pluginsDir, 'bmf-minigame-events'),
    ),
  );
  return steps;
}

function updateReleaseEvidenceSteps(context) {
  const steps = [
    verifyJsonStep(
      'read-release-catalog',
      'fetch-release-catalog',
      'Read BMF Desktop release catalog',
      context.releaseCatalogPath,
      ['schemaVersion', 'catalogKind', 'latest'],
    ),
    verifyJsonStep(
      'read-release-manifest',
      'fetch-release-manifest',
      'Read BMF release manifest',
      context.releaseManifestPath,
      ['schemaVersion'],
    ),
    verifyReleaseChecksumsStep(
      'verify-release-checksums',
      'verify-release-checksums',
      'Verify release manifest and artifact checksums',
      context.releaseCatalogPath,
      context.releaseManifestPath,
    ),
  ];

  const runtimeDir = context.paths.runtimeDir;
  if (!runtimeDir) {
    steps.push(blockedStep('snapshot-current-components', 'backup-current-components', 'Snapshot current component versions', 'BMF runtime directory is not configured.'));
  } else {
    steps.push(writeJsonStep(
      'snapshot-current-components',
      'backup-current-components',
      'Snapshot current component versions',
      path.join(runtimeDir, 'component-update-snapshot.json'),
      buildComponentSnapshot(context),
    ));
  }
  return steps;
}

function omeggaRuntimeSteps(context, operationId) {
  const actionId = operationId === 'update-stack' ? 'update-omegga-runtime' : 'install-omegga-runtime';
  if (!context.profile.paths?.omeggaRuntime) {
    return [
      blockedStep('install-omegga-runtime', actionId, operationVerb(operationId, 'BMF-compatible Omegga runtime'), 'Omegga runtime path is not configured.'),
      blockedStep('write-omegga-start-script', actionId, operationVerb(operationId, 'BMF Omegga bootstrap start script'), 'Omegga runtime path is not configured.'),
    ];
  }
  const runtimeRoot = path.resolve(context.profile.paths.omeggaRuntime);
  const startScriptPath = path.join(runtimeRoot, 'Start-BrickadiaOmegga.ps1');
  if (isPackagedOmeggaSource(context.root, runtimeRoot)) {
    return [
      copyDirectoryStep(
        'install-omegga-runtime',
        actionId,
        operationVerb(operationId, 'BMF-compatible Omegga runtime'),
        path.join(context.root, 'packages', 'omegga-runtime', 'source'),
        runtimeRoot,
        { skipWhenSame: true },
      ),
      blockedStep('write-omegga-start-script', actionId, operationVerb(operationId, 'BMF Omegga bootstrap start script'), 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
    ];
  }
  return [
    copyDirectoryStep(
      'install-omegga-runtime',
      actionId,
      operationVerb(operationId, 'BMF-compatible Omegga runtime'),
      path.join(context.root, 'packages', 'omegga-runtime', 'source'),
      runtimeRoot,
      { skipWhenSame: true },
    ),
    writeTextStep(
      'write-omegga-start-script',
      actionId,
      operationVerb(operationId, 'BMF Omegga bootstrap start script'),
      startScriptPath,
      renderOmeggaStartScript(),
    ),
  ];
}

function renderOmeggaStartScript() {
  return [
    '[CmdletBinding()]',
    'param(',
    '  [switch]$ForceInstallDependencies,',
    '  [switch]$ForceBuild,',
    '  [switch]$SkipDependencyInstall,',
    '  [switch]$SkipBuild',
    ')',
    '',
    "$ErrorActionPreference = 'Stop'",
    '$runtimeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path',
    'Set-Location -LiteralPath $runtimeRoot',
    '',
    'function Invoke-BmfCommand([string]$File, [string[]]$Arguments) {',
    '  Write-Host ("[bmf] {0} {1}" -f $File, ($Arguments -join " "))',
    '  & $File @Arguments',
    '  $exitCode = $LASTEXITCODE',
    '  if ($exitCode -ne 0) {',
    '    throw ("Command failed with exit code {0}: {1} {2}" -f $exitCode, $File, ($Arguments -join " "))',
    '  }',
    '}',
    '',
    "if (!(Test-Path -LiteralPath (Join-Path $runtimeRoot 'package.json'))) {",
    "  throw \"Omegga package.json is missing from $runtimeRoot. Run the BMF install transaction before starting the stack.\"",
    '}',
    '',
    '$nodeCommand = Get-Command node -ErrorAction SilentlyContinue',
    'if (!$nodeCommand) { throw "Node.js 23 or newer is required to run the BMF-compatible Omegga runtime." }',
    '$nodeVersionText = (& $nodeCommand.Source -p "process.versions.node" 2>&1 | Select-Object -First 1)',
    '$nodeMajor = [int](([string]$nodeVersionText).Split(".")[0])',
    'if ($nodeMajor -lt 23) { throw "Node.js 23 or newer is required to run Omegga. Found $nodeVersionText at $($nodeCommand.Source)." }',
    '',
    '$npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue',
    'if (!$npmCommand) { $npmCommand = Get-Command npm -ErrorAction SilentlyContinue }',
    'if (!$npmCommand) { throw "npm is required to install Omegga dependencies." }',
    '',
    "$env:BMF_MANAGED_OMEGGA = '1'",
    "$env:BMF_OMEGGA_RUNTIME = $runtimeRoot",
    '$nodeModules = Join-Path $runtimeRoot "node_modules"',
    '$distMain = Join-Path $runtimeRoot "dist/main.js"',
    '',
    'if (!$SkipDependencyInstall -and ($ForceInstallDependencies -or !(Test-Path -LiteralPath $nodeModules))) {',
    '  $installMode = $env:BMF_OMEGGA_BOOTSTRAP_INSTALL_MODE',
    '  if (!$installMode) { $installMode = if (Test-Path -LiteralPath (Join-Path $runtimeRoot "package-lock.json")) { "ci" } else { "install" } }',
    '  if ($installMode -eq "install") {',
    '    Invoke-BmfCommand $npmCommand.Source @("install")',
    '  } else {',
    '    Invoke-BmfCommand $npmCommand.Source @("ci")',
    '  }',
    '}',
    '',
    'if (!$SkipBuild -and ($ForceBuild -or !(Test-Path -LiteralPath $distMain))) {',
    '  $buildScript = $env:BMF_OMEGGA_BOOTSTRAP_BUILD_SCRIPT',
    '  if (!$buildScript) { $buildScript = "dist" }',
    '  Invoke-BmfCommand $npmCommand.Source @("run", $buildScript)',
    '}',
    '',
    'Invoke-BmfCommand $npmCommand.Source @("start")',
    '',
  ].join('\n');
}

function runtimeAssetSteps(context, operationId) {
  const modsDir = context.paths.ue4ssModsDir;
  const runtimeDir = context.paths.runtimeDir;
  const bmfRuntimeActionId = operationId === 'update-stack' ? 'update-bmf-runtime' : 'stage-bmf-runtime';
  const nativeHelperActionId = operationId === 'update-stack' ? 'update-native-helpers' : 'stage-bmf-socket';
  return [
    verifyStep('verify-brickadia-win64', 'resolve-brickadia-files', 'Verify Brickadia Win64 directory', context.paths.brickadiaWin64),
    copyDirectoryStep(
      'stage-bmf-runtime',
      bmfRuntimeActionId,
      operationVerb(operationId, 'BMF Lua runtime'),
      path.join(context.root, 'framework', 'ue4ss', 'Mods', 'BMF'),
      context.paths.bmfModDir,
    ),
    writeTextStep(
      'enable-bmf-runtime',
      bmfRuntimeActionId,
      'Enable BMF UE4SS mod',
      context.paths.bmfEnabled,
      '\n',
    ),
    copyDirectoryStep(
      'stage-bmf-socket',
      nativeHelperActionId,
      operationVerb(operationId, 'BMFSocket transport helper'),
      path.join(context.root, 'framework', 'ue4ss', 'Mods', 'BMFSocket'),
      modsDir ? path.join(modsDir, 'BMFSocket') : null,
    ),
    copyDirectoryStep(
      'stage-frame-telemetry',
      nativeHelperActionId,
      operationVerb(operationId, 'BMFFrameTelemetry helper'),
      path.join(context.root, 'framework', 'ue4ss', 'Mods', 'BMFFrameTelemetry'),
      modsDir ? path.join(modsDir, 'BMFFrameTelemetry') : null,
      { optional: true },
    ),
    ensureDirectoryStep(
      'ensure-bmf-runtime-dir',
      'write-server-profile',
      'Ensure BMF runtime directory',
      runtimeDir,
    ),
  ];
}

function omeggaPluginSteps(context, operationId) {
  if (!context.profile.paths?.omeggaRuntime) {
    return [
      blockedStep('stage-generic-bridge', 'stage-generic-bridge', 'Install generic BMF bridge Omegga plugin', 'Omegga runtime path is not configured.'),
      blockedStep('stage-omegga-adapters', 'stage-omegga-adapters', 'Install bundled BMF Omegga adapters', 'Omegga runtime path is not configured.'),
    ];
  }
  if (isPackagedOmeggaSource(context.root, context.profile.paths.omeggaRuntime)) {
    return [
      blockedStep('stage-generic-bridge', 'stage-generic-bridge', 'Install generic BMF bridge Omegga plugin', 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
      blockedStep('stage-omegga-adapters', 'stage-omegga-adapters', 'Install bundled BMF Omegga adapters', 'Choose a writable Omegga runtime install path instead of the packaged source tree.'),
    ];
  }
  const pluginsDir = path.join(path.resolve(context.profile.paths.omeggaRuntime), 'plugins');
  return [
    copyDirectoryStep(
      'stage-generic-bridge',
      'stage-generic-bridge',
      operationVerb(operationId, 'generic BMF bridge Omegga plugin'),
      path.join(context.root, 'packages', 'omegga-plugins', 'bmf-bridge'),
      path.join(pluginsDir, 'bmf-bridge'),
    ),
    copyDirectoryStep(
      'stage-player-sync-adapter',
      'stage-omegga-adapters',
      operationVerb(operationId, 'BMF player sync Omegga adapter'),
      path.join(context.root, 'packages', 'omegga-plugins', 'bmf-player-sync'),
      path.join(pluginsDir, 'bmf-player-sync'),
    ),
    copyDirectoryStep(
      'stage-minigame-events-adapter',
      'stage-omegga-adapters',
      operationVerb(operationId, 'BMF minigame events Omegga adapter'),
      path.join(context.root, 'packages', 'omegga-plugins', 'bmf-minigame-events'),
      path.join(pluginsDir, 'bmf-minigame-events'),
    ),
  ];
}

function isPackagedOmeggaSource(root, candidate) {
  if (!candidate) return false;
  const packagedSource = path.join(root, 'packages', 'omegga-runtime', 'source');
  return isSameOrChild(packagedSource, candidate) && isSameOrChild(candidate, packagedSource);
}

function profileMetadataSteps(context, operationId) {
  const runtimeDir = context.paths.runtimeDir;
  if (!runtimeDir) {
    return [
      blockedStep('write-profile-metadata', 'write-server-profile', 'Write BMF managed profile metadata', 'BMF runtime directory is not configured.'),
    ];
  }
  return [
    writeJsonStep(
      'write-profile-metadata',
      'write-server-profile',
      operationVerb(operationId, 'managed server profile metadata'),
      path.join(runtimeDir, 'managed-profile.json'),
      {
        schemaVersion: 1,
        managedBy: 'bmf-desktop',
        updatedAt: context.now,
        profile: publicProfile(context.profile),
      },
    ),
  ];
}

function telemetrySteps(context) {
  const plan = createTelemetryOnboardingPlan({ profile: context.profile }, {
    root: context.root,
    out: context.profile.paths?.grafanaAlloyConfig,
    env: context.env,
    scrapeInterval: context.scrapeInterval,
    grafanaBaseUrl: context.grafanaBaseUrl,
    folderUid: context.folderUid,
    prometheusDatasourceUid: context.prometheusDatasourceUid,
  });
  const steps = [];
  if (!plan.alloy.outputPath) {
    steps.push(blockedStep('write-alloy-config', 'write-alloy-config', 'Write profile Alloy config', 'Grafana Alloy config path is not configured.'));
  } else {
    steps.push(writeTextStep(
      'write-alloy-config',
      'write-alloy-config',
      'Write profile Alloy config',
      plan.alloy.outputPath,
      plan.alloy.config,
      {
        metadata: {
          sha256: plan.alloy.configSha256,
          missingSecretRefs: plan.alloy.missingSecretRefs,
        },
      },
    ));
  }
  const runtimeDir = context.paths.runtimeDir;
  if (runtimeDir) {
    steps.push(writeJsonStep(
      'write-dashboard-import-plan',
      'save-dashboard-url',
      'Write Grafana dashboard import plan',
      path.join(runtimeDir, 'grafana-dashboard-import-plan.json'),
      {
        schemaVersion: 1,
        generatedAt: context.now,
        dashboard: plan.dashboard,
        labels: plan.labels,
        status: plan.status,
      },
    ));
  }
  return steps;
}

function verifyStep(id, actionId, title, targetPath) {
  return {
    id,
    actionId,
    title,
    kind: 'verify-exists',
    mutates: false,
    targetPath: normalizeNullablePath(targetPath),
  };
}

function verifyJsonStep(id, actionId, title, targetPath, requiredFields = []) {
  return {
    id,
    actionId,
    title,
    kind: 'verify-json',
    mutates: false,
    targetPath: normalizeNullablePath(targetPath),
    requiredFields,
  };
}

function verifyReleaseChecksumsStep(id, actionId, title, catalogPath, manifestPath) {
  return {
    id,
    actionId,
    title,
    kind: 'verify-release-checksums',
    mutates: false,
    targetPath: normalizeNullablePath(manifestPath),
    catalogPath: normalizeNullablePath(catalogPath),
  };
}

function healthSnapshotStep(id, actionId, title, context, stage) {
  const snapshotContext = {
    root: context.root,
    manifest: context.manifest || null,
    now: context.now,
    stage,
    profile: publicProfile(context.profile),
  };
  return {
    id,
    actionId,
    title,
    kind: 'health-snapshot',
    mutates: false,
    targetPath: null,
    metadata: buildHealthSnapshot(snapshotContext),
    snapshotContext,
  };
}

function ensureDirectoryStep(id, actionId, title, targetPath) {
  return {
    id,
    actionId,
    title,
    kind: 'ensure-directory',
    mutates: true,
    targetPath: normalizeNullablePath(targetPath),
  };
}

function copyDirectoryStep(id, actionId, title, sourcePath, targetPath, extra = {}) {
  return {
    id,
    actionId,
    title,
    kind: 'copy-directory',
    mutates: true,
    sourcePath: normalizeNullablePath(sourcePath),
    targetPath: normalizeNullablePath(targetPath),
    optional: Boolean(extra.optional),
    skipWhenSame: Boolean(extra.skipWhenSame),
  };
}

function writeTextStep(id, actionId, title, targetPath, content, extra = {}) {
  return {
    id,
    actionId,
    title,
    kind: 'write-text',
    mutates: true,
    targetPath: normalizeNullablePath(targetPath),
    content,
    bytes: Buffer.byteLength(String(content || ''), 'utf8'),
    metadata: extra.metadata || {},
  };
}

function writeJsonStep(id, actionId, title, targetPath, value) {
  const content = `${JSON.stringify(value, null, 2)}\n`;
  return {
    id,
    actionId,
    title,
    kind: 'write-json',
    mutates: true,
    targetPath: normalizeNullablePath(targetPath),
    content,
    bytes: Buffer.byteLength(content, 'utf8'),
  };
}

function blockedStep(id, actionId, title, blockedReason) {
  return {
    id,
    actionId,
    title,
    kind: 'blocked',
    mutates: false,
    targetPath: null,
    blockedReason,
  };
}

function decorateStep(step, context) {
  const errors = [];
  if (step.kind === 'blocked') errors.push(step.blockedReason || 'step is blocked');
  if (!step.targetPath && step.kind !== 'verify-exists' && step.kind !== 'blocked' && step.kind !== 'health-snapshot') {
    errors.push('target path is not configured');
  }
  const sameSourceAndTarget = Boolean(step.sourcePath && step.targetPath && isSameOrChild(step.sourcePath, step.targetPath) && isSameOrChild(step.targetPath, step.sourcePath));
  if (step.sourcePath && !exists(step.sourcePath)) {
    if (!step.optional) errors.push(`source path is missing: ${step.sourcePath}`);
  }
  if (sameSourceAndTarget && !step.skipWhenSame) {
    errors.push(`source and target paths are the same: ${step.targetPath}`);
  }
  if (step.targetPath && step.mutates && !isAllowedTarget(step.targetPath, context.allowTargetRoots)) {
    errors.push(`target path is outside allowed roots: ${step.targetPath}`);
  }
  if (step.kind === 'verify-exists' && step.targetPath && !exists(step.targetPath)) {
    errors.push(`required path is missing: ${step.targetPath}`);
  }
  if (step.kind === 'verify-json') {
    errors.push(...verifyJsonErrors(step.targetPath, step.requiredFields));
  }
  if (step.kind === 'verify-release-checksums') {
    errors.push(...verifyReleaseChecksumErrors(step.catalogPath, step.targetPath));
  }

  const targetExists = step.targetPath ? exists(step.targetPath) : false;
  return {
    ...(context.includeContent ? withContentHash(step) : withoutContent(step)),
    status: sameSourceAndTarget && step.skipWhenSame ? 'skipped' : errors.length > 0 ? step.optional ? 'skipped' : 'blocked' : 'ready',
    blockedReason: errors.join('; ') || null,
    targetExists,
    backupRequired: Boolean(step.mutates && targetExists),
    guardrails: step.mutates ? TRANSACTION_GUARDRAILS : ['read-only-verification'],
  };
}

function applyStep(step, transaction) {
  if (step.mutates && !isAllowedTarget(step.targetPath, allowedTargetRootsFromTransaction(transaction))) {
    throw new Error(`Target path is outside allowed roots: ${step.targetPath}`);
  }

  if (step.kind === 'verify-exists') {
    if (!exists(step.targetPath)) throw new Error(`Required path does not exist: ${step.targetPath}`);
    return { sha256: null, rollback: null };
  }

  if (step.kind === 'verify-json') {
    const errors = verifyJsonErrors(step.targetPath, step.requiredFields);
    if (errors.length) throw new Error(errors.join('; '));
    return { sha256: sha256File(step.targetPath), rollback: null };
  }

  if (step.kind === 'verify-release-checksums') {
    const errors = verifyReleaseChecksumErrors(step.catalogPath, step.targetPath);
    if (errors.length) throw new Error(errors.join('; '));
    return { sha256: sha256File(step.targetPath), rollback: null };
  }

  if (step.kind === 'health-snapshot') {
    const metadata = buildHealthSnapshot(step.snapshotContext || {
      root: resolveRoot(transaction.profile?.paths?.bmfRoot),
      profile: transaction.profile,
      now: new Date(),
      stage: step.id,
    });
    return {
      metadata,
      sha256: sha256String(JSON.stringify(metadata)),
      rollback: null,
    };
  }

  if (step.kind === 'ensure-directory') {
    const existed = exists(step.targetPath);
    ensureDir(step.targetPath);
    return {
      sha256: null,
      rollback: existed ? null : { action: 'remove-created-path', path: step.targetPath },
    };
  }

  if (step.kind === 'copy-directory') {
    if (!isDirectory(step.sourcePath)) throw new Error(`Source directory does not exist: ${step.sourcePath}`);
    const backupPath = backupExisting(step.targetPath, transaction.backupRoot);
    if (exists(step.targetPath)) fs.rmSync(step.targetPath, { recursive: true, force: true });
    ensureDir(path.dirname(step.targetPath));
    fs.cpSync(step.sourcePath, step.targetPath, { recursive: true, force: true });
    return {
      backupPath,
      sha256: hashDirectory(step.targetPath),
      rollback: backupPath
        ? { action: 'restore-directory', path: step.targetPath, backupPath }
        : { action: 'remove-created-path', path: step.targetPath },
    };
  }

  if (step.kind === 'write-text' || step.kind === 'write-json') {
    const backupPath = backupExisting(step.targetPath, transaction.backupRoot);
    ensureDir(path.dirname(step.targetPath));
    fs.writeFileSync(step.targetPath, step.content || '', 'utf8');
    return {
      backupPath,
      sha256: sha256File(step.targetPath),
      rollback: backupPath
        ? { action: 'restore-file', path: step.targetPath, backupPath }
        : { action: 'remove-created-path', path: step.targetPath },
    };
  }

  throw new Error(`Unsupported transaction step kind: ${step.kind}`);
}

function buildRollbackSteps(source, context) {
  const entries = Array.isArray(source.rollback) ? source.rollback : [];
  return entries
    .map((entry, index) => ({ ...entry, originalIndex: index }))
    .reverse()
    .map((entry, index) => decorateRollbackStep({
      id: `rollback-${String(index + 1).padStart(2, '0')}-${sanitizeId(entry.stepId || entry.action || 'step')}`,
      sourceStepId: entry.stepId || null,
      action: entry.action,
      mutates: true,
      targetPath: normalizeNullablePath(entry.path),
      backupPath: normalizeNullablePath(entry.backupPath),
      originalIndex: entry.originalIndex,
    }, context));
}

function decorateRollbackStep(step, context) {
  const errors = [];
  if (context.allowedRoots.length === 0) errors.push('source transaction has no allowed target roots');
  if (!step.targetPath) {
    errors.push('target path is not configured');
  } else if (!isAllowedTarget(step.targetPath, context.allowedRoots)) {
    errors.push(`target path is outside allowed roots: ${step.targetPath}`);
  }

  if (step.action === 'restore-directory' || step.action === 'restore-file') {
    if (!step.backupPath) {
      errors.push('backup path is not recorded');
    } else {
      if (context.sourceBackupRoot && !isSameOrChild(context.sourceBackupRoot, step.backupPath)) {
        errors.push(`backup path is outside source backup root: ${step.backupPath}`);
      }
      if (!exists(step.backupPath)) {
        errors.push(`backup path is missing: ${step.backupPath}`);
      } else if (step.action === 'restore-directory' && !isDirectory(step.backupPath)) {
        errors.push(`directory backup is not a directory: ${step.backupPath}`);
      } else if (step.action === 'restore-file' && isDirectory(step.backupPath)) {
        errors.push(`file backup is a directory: ${step.backupPath}`);
      }
    }
  } else if (step.action !== 'remove-created-path') {
    errors.push(`unsupported rollback action: ${step.action || '(missing)'}`);
  }

  const targetExists = step.targetPath ? exists(step.targetPath) : false;
  return {
    ...step,
    kind: 'rollback',
    status: errors.length > 0 ? 'blocked' : 'ready',
    blockedReason: errors.join('; ') || null,
    targetExists,
    backupRequired: targetExists,
    guardrails: ROLLBACK_GUARDRAILS,
  };
}

function applyRollbackStep(step, rollback) {
  if (!isAllowedTarget(step.targetPath, allowedTargetRootsFromTransaction(rollback))) {
    throw new Error(`Target path is outside allowed roots: ${step.targetPath}`);
  }
  if (step.backupPath && rollback.sourceBackupRoot && !isSameOrChild(rollback.sourceBackupRoot, step.backupPath)) {
    throw new Error(`Backup path is outside source backup root: ${step.backupPath}`);
  }

  if (step.action === 'restore-directory') {
    if (!isDirectory(step.backupPath)) throw new Error(`Directory backup does not exist: ${step.backupPath}`);
    const rollbackBackupPath = backupExisting(step.targetPath, rollback.backupRoot);
    if (exists(step.targetPath)) fs.rmSync(step.targetPath, { recursive: true, force: true });
    ensureDir(path.dirname(step.targetPath));
    fs.cpSync(step.backupPath, step.targetPath, { recursive: true, force: true });
    return {
      result: 'restored',
      rollbackBackupPath,
      sha256: hashDirectory(step.targetPath),
    };
  }

  if (step.action === 'restore-file') {
    if (!exists(step.backupPath) || isDirectory(step.backupPath)) throw new Error(`File backup does not exist: ${step.backupPath}`);
    const rollbackBackupPath = backupExisting(step.targetPath, rollback.backupRoot);
    if (exists(step.targetPath)) fs.rmSync(step.targetPath, { recursive: true, force: true });
    ensureDir(path.dirname(step.targetPath));
    fs.copyFileSync(step.backupPath, step.targetPath);
    return {
      result: 'restored',
      rollbackBackupPath,
      sha256: sha256File(step.targetPath),
    };
  }

  if (step.action === 'remove-created-path') {
    const rollbackBackupPath = backupExisting(step.targetPath, rollback.backupRoot);
    const removed = exists(step.targetPath);
    if (removed) fs.rmSync(step.targetPath, { recursive: true, force: true });
    return {
      result: removed ? 'removed' : 'noop',
      rollbackBackupPath,
      sha256: null,
    };
  }

  throw new Error(`Unsupported rollback action: ${step.action}`);
}

function backupExisting(targetPath, backupRoot) {
  if (!exists(targetPath)) return null;
  const backupPath = path.join(backupRoot, `${pathKey(targetPath)}.bak`);
  ensureDir(path.dirname(backupPath));
  if (isDirectory(targetPath)) {
    fs.cpSync(targetPath, backupPath, { recursive: true, force: true });
  } else {
    fs.copyFileSync(targetPath, backupPath);
  }
  return backupPath;
}

function writeTransactionJournal(transaction) {
  const journalDir = path.dirname(transaction.journalPath);
  ensureDir(journalDir);
  const payload = `${JSON.stringify(redactTransaction(transaction), null, 2)}\n`;
  const tempPath = path.join(journalDir, `.${path.basename(transaction.journalPath)}.${process.pid}.${Date.now()}.tmp`);
  try {
    fs.writeFileSync(tempPath, payload, 'utf8');
    fs.renameSync(tempPath, transaction.journalPath);
  } catch (error) {
    if (exists(tempPath)) {
      try {
        fs.rmSync(tempPath, { force: true });
      } catch {
        // Best-effort cleanup only; keep the original write error.
      }
    }
    throw error;
  }
}

function summarizeTransactionSteps(steps, unsupportedActions) {
  const summary = steps.reduce(
    (counts, step) => {
      counts.total += 1;
      if (step.mutates) counts.mutating += 1;
      else counts.readOnly += 1;
      if (step.status === 'blocked') counts.blocked += 1;
      if (step.status === 'ready') counts.ready += 1;
      if (step.status === 'skipped') counts.skipped += 1;
      if (step.backupRequired) counts.backupsRequired += 1;
      return counts;
    },
    {
      total: 0,
      mutating: 0,
      readOnly: 0,
      ready: 0,
      blocked: 0,
      skipped: 0,
      backupsRequired: 0,
      unsupported: unsupportedActions.length,
    },
  );
  return summary;
}

function summarizeRollbackSteps(steps) {
  return steps.reduce(
    (counts, step) => {
      counts.total += 1;
      if (step.status === 'ready') counts.ready += 1;
      if (step.status === 'blocked') counts.blocked += 1;
      if (step.action === 'restore-directory' || step.action === 'restore-file') counts.restores += 1;
      if (step.action === 'remove-created-path') counts.removals += 1;
      if (step.backupRequired) counts.backupsRequired += 1;
      return counts;
    },
    {
      total: 0,
      ready: 0,
      blocked: 0,
      restores: 0,
      removals: 0,
      backupsRequired: 0,
    },
  );
}

function buildRollbackPreview(steps) {
  return steps
    .filter(step => step.mutates && step.status === 'ready')
    .map(step => ({
      stepId: step.id,
      action: step.targetExists ? 'restore-backup' : 'remove-created-path',
      path: step.targetPath,
    }));
}

function buildHealthSnapshot(snapshotContext = {}) {
  try {
    const report = collectLocalProfileStatus({ profile: snapshotContext.profile || {} }, {
      root: snapshotContext.root,
      manifest: snapshotContext.manifest || undefined,
      now: snapshotContext.now || new Date(),
    });
    return {
      schemaVersion: 1,
      feature: 'repair.health-snapshot',
      stage: snapshotContext.stage || 'health',
      collectedAt: report.collectedAt,
      status: report.health?.status || 'unknown',
      summary: report.health?.summary || null,
      observations: summarizeHealthObservations(report.observations || {}),
    };
  } catch (error) {
    return {
      schemaVersion: 1,
      feature: 'repair.health-snapshot',
      stage: snapshotContext.stage || 'health',
      collectedAt: toIso(snapshotContext.now || new Date()),
      status: 'unavailable',
      summary: error.message || String(error),
      observations: {},
    };
  }
}

function summarizeHealthObservations(observations) {
  return Object.fromEntries(Object.entries(observations).map(([id, value]) => [id, {
    status: value.status,
    summary: value.summary,
    nextAction: value.nextAction || null,
    evidence: Array.isArray(value.evidence) ? value.evidence : [],
  }]));
}

function repairMutableSnapshotPath(context) {
  const journalPath = context.journalPath || path.join(context.root, 'artifacts', 'local', 'transactions', 'repair-stack.json');
  const base = path.basename(journalPath, '.json');
  return path.join(path.dirname(journalPath), `${base}-mutable-files.json`);
}

function buildRepairMutableSnapshot(context) {
  const modsDir = context.paths.ue4ssModsDir;
  const omeggaRuntime = normalizeNullablePath(context.profile.paths?.omeggaRuntime);
  const startScriptPath = omeggaRuntime ? path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1') : null;
  const targets = compact([
    context.paths.bmfEnabled,
    modsDir ? path.join(modsDir, 'mods.txt') : null,
    modsDir ? path.join(modsDir, 'mods.json') : null,
    startScriptPath,
    context.paths.bmfModDir,
    modsDir ? path.join(modsDir, 'BMFSocket') : null,
    modsDir ? path.join(modsDir, 'BMFFrameTelemetry') : null,
    omeggaRuntime ? path.join(omeggaRuntime, 'plugins', 'bmf-bridge') : null,
    omeggaRuntime ? path.join(omeggaRuntime, 'plugins', 'bmf-player-sync') : null,
    omeggaRuntime ? path.join(omeggaRuntime, 'plugins', 'bmf-minigame-events') : null,
  ]);
  return {
    schemaVersion: 1,
    feature: 'repair.mutable-files.snapshot',
    generatedAt: context.now,
    profile: publicProfile(context.profile),
    files: targets.map(repairMutableRecord),
  };
}

function repairMutableRecord(targetPath) {
  const resolved = normalizeNullablePath(targetPath);
  const targetExists = exists(resolved);
  const directory = targetExists && isDirectory(resolved);
  return {
    path: resolved,
    exists: targetExists,
    kind: !targetExists ? 'missing' : directory ? 'directory' : 'file',
    bytes: targetExists && !directory ? fs.statSync(resolved).size : null,
    sha256: !targetExists ? null : directory ? hashDirectory(resolved) : sha256File(resolved),
  };
}

function buildComponentSnapshot(context) {
  const modsDir = context.paths.ue4ssModsDir;
  return {
    schemaVersion: 1,
    feature: 'component-update.snapshot',
    generatedAt: context.now,
    profile: publicProfile(context.profile),
    release: {
      catalogPath: context.releaseCatalogPath,
      manifestPath: context.releaseManifestPath,
    },
    components: [
      componentSnapshotRecord('bmf-runtime', context.paths.bmfModDir),
      componentSnapshotRecord('bmf-socket', modsDir ? path.join(modsDir, 'BMFSocket') : null),
      componentSnapshotRecord('bmf-frame-telemetry', modsDir ? path.join(modsDir, 'BMFFrameTelemetry') : null),
      componentSnapshotRecord('omegga-runtime', context.profile.paths?.omeggaRuntime || null),
    ],
  };
}

function componentSnapshotRecord(id, targetPath) {
  const resolved = normalizeNullablePath(targetPath);
  const targetExists = exists(resolved);
  const fingerprint = componentFingerprint(id, resolved);
  return {
    id,
    path: resolved,
    exists: targetExists,
    kind: !targetExists ? 'missing' : isDirectory(resolved) ? 'directory' : 'file',
    sha256: fingerprint.sha256,
    fingerprintStrategy: fingerprint.strategy,
    fingerprintInputs: fingerprint.inputs,
  };
}

function componentFingerprint(id, targetPath) {
  if (!targetPath || !exists(targetPath)) {
    return { sha256: null, strategy: 'missing', inputs: [] };
  }
  if (!isDirectory(targetPath)) {
    return { sha256: sha256File(targetPath), strategy: 'file', inputs: [path.basename(targetPath)] };
  }
  if (id === 'omegga-runtime') {
    return hashSelectedFiles(targetPath, [
      'package.json',
      'package-lock.json',
      'pnpm-lock.yaml',
      'yarn.lock',
      path.join('src', 'omegga', 'index.ts'),
      path.join('src', 'brickadia', 'ue4ssBridge.ts'),
    ]);
  }
  return {
    sha256: hashDirectory(targetPath),
    strategy: 'directory-tree',
    inputs: listFiles(targetPath).map(file => path.relative(targetPath, file).replace(/\\/g, '/')),
  };
}

function hashSelectedFiles(root, relativeFiles) {
  const files = relativeFiles
    .map(relative => path.join(root, relative))
    .filter(filePath => exists(filePath) && !isDirectory(filePath));
  if (files.length === 0) {
    return { sha256: null, strategy: 'selected-runtime-files-missing', inputs: [] };
  }
  const hash = crypto.createHash('sha256');
  for (const file of files) {
    const relative = path.relative(root, file).replace(/\\/g, '/');
    hash.update(relative);
    hash.update('\0');
    hash.update(fs.readFileSync(file));
    hash.update('\0');
  }
  return {
    sha256: hash.digest('hex'),
    strategy: 'selected-runtime-files',
    inputs: files.map(file => path.relative(root, file).replace(/\\/g, '/')),
  };
}

function verifyJsonErrors(targetPath, requiredFields = []) {
  const result = readJsonForVerification(targetPath, 'JSON file');
  if (result.error) return [result.error];

  const errors = [];
  for (const field of requiredFields) {
    if (!hasJsonField(result.value, field)) {
      errors.push(`JSON file is missing required field: ${field}`);
    }
  }
  return errors;
}

function verifyReleaseChecksumErrors(catalogPath, manifestPath) {
  const errors = [];
  const catalogResult = readJsonForVerification(catalogPath, 'release catalog');
  const manifestResult = readJsonForVerification(manifestPath, 'release manifest');
  if (catalogResult.error) errors.push(catalogResult.error);
  if (manifestResult.error) errors.push(manifestResult.error);
  if (errors.length > 0) return errors;

  const expectations = releaseCatalogChecksumExpectations(catalogPath, catalogResult.value, manifestPath, manifestResult.value);
  errors.push(...expectations.errors);
  for (const item of expectations.items) {
    if (!exists(item.path)) {
      errors.push(`${item.label} is missing: ${item.path}`);
      continue;
    }
    if (isDirectory(item.path)) {
      errors.push(`${item.label} is a directory, expected a file: ${item.path}`);
      continue;
    }
    const actual = sha256File(item.path);
    if (actual !== item.expectedSha256) {
      errors.push(`${item.label} sha256 mismatch: expected ${item.expectedSha256}, got ${actual}`);
    }
  }
  return errors;
}

function releaseCatalogChecksumExpectations(catalogPath, catalog, manifestPath, manifest) {
  const errors = [];
  const items = [];
  const latest = catalog?.latest && typeof catalog.latest === 'object' ? catalog.latest : null;
  if (!latest) {
    return {
      errors: ['release catalog latest release is missing'],
      items,
    };
  }

  const manifestRecord = latest.manifest && typeof latest.manifest === 'object' ? latest.manifest : null;
  if (!manifestRecord || !isSha256(manifestRecord.sha256)) {
    errors.push('release catalog latest.manifest.sha256 must be a SHA256 hash');
  } else {
    items.push({
      label: 'release manifest',
      path: manifestPath,
      expectedSha256: String(manifestRecord.sha256).toLowerCase(),
    });
  }

  const artifactRecord = latest.artifact && typeof latest.artifact === 'object'
    ? latest.artifact
    : null;
  const primaryArtifact = manifest?.primaryArtifact && typeof manifest.primaryArtifact === 'object'
    ? manifest.primaryArtifact
    : null;
  if (!artifactRecord || !isSha256(artifactRecord.sha256)) {
    errors.push('release catalog latest.artifact.sha256 must be a SHA256 hash');
  } else {
    items.push({
      label: 'release artifact',
      path: resolveReleaseRecordPath(catalogPath, artifactRecord),
      expectedSha256: String(artifactRecord.sha256).toLowerCase(),
    });
  }

  if (primaryArtifact) {
    if (primaryArtifact.fileName && artifactRecord?.fileName && primaryArtifact.fileName !== artifactRecord.fileName) {
      errors.push(`release manifest primaryArtifact ${primaryArtifact.fileName} does not match catalog artifact ${artifactRecord.fileName}`);
    }
    if (primaryArtifact.sha256 && artifactRecord?.sha256 && String(primaryArtifact.sha256).toLowerCase() !== String(artifactRecord.sha256).toLowerCase()) {
      errors.push('release manifest primaryArtifact.sha256 does not match catalog latest.artifact.sha256');
    }
  }

  return { errors, items };
}

function readJsonForVerification(targetPath, label) {
  if (!targetPath) return { error: `${label} path is not configured.` };
  if (!exists(targetPath)) return { error: `${label} is missing: ${targetPath}` };
  if (isDirectory(targetPath)) return { error: `${label} is a directory, expected a JSON file: ${targetPath}` };
  try {
    return { value: JSON.parse(fs.readFileSync(targetPath, 'utf8').replace(/^\uFEFF/, '')) };
  } catch (error) {
    return { error: `Unable to read ${label}: ${error.message || String(error)}` };
  }
}

function readTextFile(filePath, fallback = '') {
  if (!filePath || !exists(filePath) || isDirectory(filePath)) return fallback;
  return fs.readFileSync(filePath, 'utf8');
}

function setModInTxt(text, modName, enabled) {
  const newline = String(text || '').includes('\r\n') ? '\r\n' : '\n';
  const normalized = String(text || '').replace(/\r\n/g, '\n').replace(/\n$/, '');
  const lines = normalized ? normalized.split('\n') : [];
  let found = false;
  const desired = enabled ? '1' : '0';
  const updated = lines.map((line) => {
    const match = /^(\s*)([^:#][^:]*?)(\s*:\s*)([01])(\s*)$/.exec(line);
    if (!match || match[2].trim().toLowerCase() !== String(modName).toLowerCase()) return line;
    found = true;
    return `${match[1]}${match[2].trim()}${match[3]}${desired}${match[5]}`;
  });
  if (!found) updated.push(`${modName} : ${desired}`);
  return `${updated.join(newline)}${newline}`;
}

function setModInJson(text, modName, enabled) {
  let mods = [];
  try {
    const parsed = JSON.parse(String(text || '[]').replace(/^\uFEFF/, ''));
    mods = Array.isArray(parsed) ? parsed : [];
  } catch {
    mods = [];
  }
  let found = false;
  const updated = mods.map((entry) => {
    if (!entry || typeof entry !== 'object') return entry;
    const name = entry.mod_name || entry.name || entry.id;
    if (String(name || '').toLowerCase() !== String(modName).toLowerCase()) return entry;
    found = true;
    if (Object.hasOwn(entry, 'mod_enabled')) return { ...entry, mod_enabled: Boolean(enabled) };
    if (Object.hasOwn(entry, 'enabled')) return { ...entry, enabled: Boolean(enabled) };
    return { ...entry, mod_enabled: Boolean(enabled) };
  });
  if (!found) updated.push({ mod_name: modName, mod_enabled: Boolean(enabled) });
  return updated;
}

function hasJsonField(value, field) {
  const parts = String(field || '').split('.').filter(Boolean);
  let current = value;
  for (const part of parts) {
    if (!current || typeof current !== 'object' || current[part] === undefined || current[part] === null) {
      return false;
    }
    current = current[part];
  }
  return true;
}

function resolveReleaseRecordPath(catalogPath, record) {
  const candidate = record?.path || record?.fileName;
  if (!candidate) return null;
  if (path.isAbsolute(candidate)) return path.resolve(candidate);
  return path.resolve(path.dirname(catalogPath), candidate);
}

function isSha256(value) {
  return /^[a-f0-9]{64}$/i.test(String(value || ''));
}

function allowedTargetRoots(root, profile, paths, extraRoots) {
  return compact([
    paths.ue4ssModsDir,
    paths.runtimeDir,
    profile.paths?.omeggaRuntime,
    profile.paths?.grafanaAlloyConfig ? path.dirname(path.resolve(profile.paths.grafanaAlloyConfig)) : null,
    path.join(root, 'artifacts'),
    ...extraRoots,
  ]).map(item => path.resolve(item));
}

function allowedTargetRootsFromTransaction(transaction) {
  return (transaction.allowedTargetRoots || []).map(item => path.resolve(item));
}

function isAllowedTarget(targetPath, roots) {
  const target = path.resolve(targetPath);
  return roots.some(root => isSameOrChild(root, target));
}

function isSameOrChild(parent, child) {
  const parentFull = path.resolve(parent);
  const childFull = path.resolve(child);
  if (parentFull.toLowerCase() === childFull.toLowerCase()) return true;
  const withSep = parentFull.endsWith(path.sep) ? parentFull : `${parentFull}${path.sep}`;
  return childFull.toLowerCase().startsWith(withSep.toLowerCase());
}

function unsupportedReason(kind) {
  if (['start-process', 'stop-process', 'process-check', 'http-check', 'api-call'].includes(kind)) {
    return 'process, HTTP, and external API operations are not applied by the filesystem transaction runner yet';
  }
  if (['doctor', 'port-check', 'read-file', 'log-tail', 'redact', 'transform', 'buffer-policy', 'socket-read', 'read-manifest', 'verify'].includes(kind)) {
    return 'read-only diagnostic action remains represented by the operation plan';
  }
  return 'no concrete transaction step is registered for this action yet';
}

function operationVerb(operationId, noun) {
  if (operationId === 'repair-stack') return `Repair ${noun}`;
  if (operationId === 'update-stack') return `Update ${noun}`;
  return `Install ${noun}`;
}

function normalizeProfile(input = {}) {
  if (input && input.schemaVersion === 1 && input.id && input.ports && input.paths && input.telemetry) {
    return input;
  }
  return createServerProfile(input);
}

function resolveRoot(root) {
  return path.resolve(root || path.join(__dirname, '..', '..', '..'));
}

function normalizeNullablePath(value) {
  return value ? path.resolve(value) : null;
}

function withoutContent(step) {
  const clone = { ...step };
  if (clone.content !== undefined) {
    clone.contentSha256 = sha256String(clone.content);
    delete clone.content;
  }
  return clone;
}

function withContentHash(step) {
  const clone = { ...step };
  if (clone.content !== undefined) {
    clone.contentSha256 = sha256String(clone.content);
  }
  return clone;
}

function loadTransactionJournal(journalPath) {
  if (!exists(journalPath)) throw new Error(`Transaction journal does not exist: ${journalPath}`);
  try {
    return JSON.parse(fs.readFileSync(journalPath, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read transaction journal: ${error.message || String(error)}`);
  }
}

function redactTransaction(transaction) {
  const clone = JSON.parse(JSON.stringify(transaction));
  for (const collectionName of ['steps', 'applied']) {
    for (const step of clone[collectionName] || []) {
      if (step.content !== undefined) delete step.content;
    }
  }
  return clone;
}

function makeTransactionId(operationId, createdAt) {
  const safeTime = String(createdAt).replace(/[:.]/g, '-');
  return `${String(operationId || 'operation').replace(/[^A-Za-z0-9_.-]+/g, '-')}-${safeTime}`;
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function exists(filePath) {
  return Boolean(filePath) && fs.existsSync(filePath);
}

function isDirectory(filePath) {
  return exists(filePath) && fs.statSync(filePath).isDirectory();
}

function sha256String(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function hashDirectory(dir) {
  const files = listFiles(dir);
  const hash = crypto.createHash('sha256');
  for (const file of files) {
    const relative = path.relative(dir, file).replace(/\\/g, '/');
    hash.update(relative);
    hash.update('\0');
    hash.update(fs.readFileSync(file));
    hash.update('\0');
  }
  return hash.digest('hex');
}

function listFiles(dir) {
  if (!isDirectory(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const filePath = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listFiles(filePath));
    else if (entry.isFile()) out.push(filePath);
  }
  return out.sort();
}

function pathKey(filePath) {
  return path.resolve(filePath).replace(/^[A-Za-z]:/, '').replace(/[\\/]+/g, '__').replace(/^__/, '');
}

function sanitizeId(value) {
  return String(value || 'step').replace(/[^A-Za-z0-9_.-]+/g, '-');
}

function compact(items) {
  return items.filter(item => item !== undefined && item !== null && item !== '');
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  ROLLBACK_GUARDRAILS,
  TRANSACTION_GUARDRAILS,
  TRANSACTION_OPERATION_IDS,
  createOperationTransaction,
  createRollbackTransaction,
  executeRollbackTransaction,
  executeOperationTransaction,
};
