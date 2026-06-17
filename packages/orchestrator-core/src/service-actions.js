const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const { createServerProfile, publicProfile } = require('./profiles');
const { buildServiceDiagnostics, getConfiguredPortTargets } = require('./services');
const { redactValue } = require('./traffic');

const SERVICE_ACTION_IDS = [
  'start-stack',
  'stop-stack',
  'restart-stack',
  'start-alloy',
  'stop-alloy',
  'restart-alloy',
];

const SERVICE_ACTION_GUARDRAILS = [
  'dry-run-by-default',
  'explicit-start-confirmation-required',
  'explicit-stop-confirmation-required',
  'explicit-restart-confirmation-required',
  'configured-start-script-only',
  'configured-alloy-executable-only',
  'configured-alloy-config-only',
  'append-only-launch-log',
  'journal-every-service-action',
  'read-local-process-state-only',
  'owned-pid-file-required',
  'verify-owned-process-before-stop',
  'cleanup-stale-owned-pid-only',
  'do-not-send-bmf-commands',
  'do-not-add-ui-driven-server-probes',
  'redact-secrets-before-display-or-export',
];

const SERVICE_ACTION_DEFINITIONS = {
  'start-stack': {
    title: 'Start managed Brickadia/Omegga stack',
    description: 'Launch the configured Omegga start script and write local launch evidence.',
  },
  'stop-stack': {
    title: 'Stop managed Brickadia/Omegga stack',
    description: 'Stop the previously launched BMF-owned process after PID metadata verification.',
  },
  'restart-stack': {
    title: 'Restart managed Brickadia/Omegga stack',
    description: 'Stop the verified owned process, then start the configured Omegga launch script.',
  },
  'start-alloy': {
    title: 'Start managed Grafana Alloy',
    description: 'Launch the configured Alloy executable against the rendered profile config and write local launch evidence.',
  },
  'stop-alloy': {
    title: 'Stop managed Grafana Alloy',
    description: 'Stop the previously launched BMF-owned Alloy process after PID metadata verification.',
  },
  'restart-alloy': {
    title: 'Restart managed Grafana Alloy',
    description: 'Stop the verified owned Alloy process, then start the configured Alloy command.',
  },
};

function createServiceActionPlan(actionId = 'start-stack', input = {}, options = {}) {
  const normalizedActionId = normalizeActionId(actionId);
  const definition = SERVICE_ACTION_DEFINITIONS[normalizedActionId];
  if (!definition) {
    throw new Error(`Unknown service action "${actionId}". Expected one of: ${SERVICE_ACTION_IDS.join(', ')}`);
  }

  const profile = createServerProfile(input.profile || input);
  const root = resolveRoot(options.root || profile.paths?.bmfRoot || profile.root);
  const backend = profile.backend || 'local-process';
  const backendConfig = profile.backendConfig || {};
  const createdAt = toIso(options.now || new Date());
  const dryRun = options.dryRun !== false;
  const actionRoot = path.resolve(options.serviceRoot || path.join(root, 'artifacts', 'local', 'services'));
  const actionRunId = options.actionRunId || makeActionRunId(normalizedActionId, createdAt);
  const journalPath = path.resolve(options.journalPath || path.join(actionRoot, `${actionRunId}.json`));
  const service = serviceForAction(normalizedActionId);
  const serviceSlug = serviceSlugForAction(normalizedActionId);
  const logPath = path.resolve(options.logPath || path.join(actionRoot, `${profile.id}-${serviceSlug}.log`));
  const pidPath = path.resolve(options.pidPath || path.join(actionRoot, `${profile.id}-${serviceSlug}.pid.json`));
  const omeggaRuntime = normalizeNullablePath(options.omeggaRuntime || profile.paths?.omeggaRuntime);
  const startScript = normalizeNullablePath(
    options.startScript || options.omeggaStartScript || profile.paths?.omeggaStartScript,
  );
  const alloyExecutable = normalizeNullablePath(
    options.alloyExecutable
      || options.grafanaAlloyExecutable
      || options.grafanaAlloyExe
      || profile.paths?.grafanaAlloyExecutable
      || profile.paths?.grafanaAlloyExe,
  );
  const alloyConfig = normalizeNullablePath(
    options.alloyConfig
      || options.grafanaAlloyConfig
      || profile.paths?.grafanaAlloyConfig,
  );
  const alloyStoragePath = normalizeNullablePath(
    options.alloyStoragePath || path.join(actionRoot, `${profile.id}-alloy-data`),
  );
  const command = buildServiceLaunchCommand(normalizedActionId, {
    backend,
    backendConfig,
    profileId: profile.id,
    command: options.command || options.startCommand,
    args: options.args || options.startArgs,
    cwd: options.cwd,
    omeggaRuntime,
    startScript,
    alloyExecutable,
    alloyConfig,
    alloyStoragePath,
    alloyReadyPort: profile.ports?.alloyReady,
  });
  const ownedProcess = readOwnedProcess(pidPath, profile, {
    expectedService: service,
    processInspector: options.processInspector,
  });
  const serviceDiagnostics = buildServiceDiagnostics(profile, {
    portInspection: options.portInspection || { inspected: false },
    targets: serviceDiagnosticTargetsForAction(normalizedActionId, profile),
  });
  const blockers = buildBlockers(normalizedActionId, {
    actionRoot,
    command,
    journalPath,
    logPath,
    omeggaRuntime,
    pidPath,
    profile,
    root,
    service,
    serviceDiagnostics,
    startScript,
    backend,
    backendConfig,
    alloyExecutable,
    alloyConfig,
    alloyStoragePath,
    ownedProcess,
  });
  const warnings = buildWarnings(normalizedActionId, serviceDiagnostics);
  const steps = buildSteps(normalizedActionId, blockers, warnings, backend);
  const summary = summarizeSteps(steps, warnings);
  const status = blockers.length > 0 ? 'blocked' : dryRun ? 'planned' : 'ready';

  return redactForDisplay({
    schemaVersion: 1,
    actionRunId,
    actionId: normalizedActionId,
    title: definition.title,
    description: definition.description,
    dryRun,
    status,
    createdAt,
    service,
    backend,
    backendConfig,
    profile: publicProfile(profile),
    command,
    paths: {
      root,
      actionRoot,
      omeggaRuntime,
      startScript,
      alloyExecutable,
      alloyConfig,
      alloyStoragePath,
      logPath,
      journalPath,
      pidPath,
    },
    readiness: serviceDiagnostics.startReadiness,
    ownedProcess,
    blockers,
    warnings,
    steps,
    summary,
    guardrails: SERVICE_ACTION_GUARDRAILS,
  });
}

function executeServiceAction(actionId = 'start-stack', input = {}, options = {}) {
  const normalizedActionId = normalizeActionId(actionId);
  const dryRun = options.dryRun !== false;
  if (dryRun) {
    return createServiceActionPlan(normalizedActionId, input, { ...options, dryRun: true });
  }

  const expectedConfirmation = confirmationForAction(normalizedActionId);
  if (String(options.confirm || '').toLowerCase() !== expectedConfirmation) {
    throw new Error(`Refusing to ${serviceActionVerb(normalizedActionId)} service without --confirm ${expectedConfirmation}.`);
  }

  const plan = createServiceActionPlan(normalizedActionId, input, { ...options, dryRun: false });
  if (plan.status === 'blocked') {
    if (hasPathScopeBlocker(plan.blockers)) {
      return {
        ...plan,
        journal: {
          path: plan.paths.journalPath,
          written: false,
          reason: 'service action paths are outside the allowed scope',
        },
      };
    }
    writeServiceJournal({
      ...plan,
      status: 'blocked',
      finishedAt: toIso(new Date()),
      process: null,
    });
    return plan;
  }

  if (isStopAction(normalizedActionId)) {
    return executeStopPlan(plan, options);
  }
  if (isRestartAction(normalizedActionId)) {
    return executeRestartPlan(plan, options);
  }
  return executeStartPlan(plan, options, { status: 'started' });
}

function executeStartPlan(plan, options = {}, resultOptions = {}) {
  ensureDir(plan.paths.actionRoot);
  const output = fs.openSync(plan.paths.logPath, 'a');
  const commandLine = plan.command.display;
  fs.writeSync(output, `[${plan.createdAt}] BMF service action ${plan.actionRunId} starting\n`);
  fs.writeSync(output, `[${plan.createdAt}] ${commandLine}\n`);

  let child;
  try {
    child = spawnConfiguredProcess(plan, output, options);
    if (child.unref) child.unref();
  } catch (error) {
    fs.closeSync(output);
    const failed = {
      ...plan,
      status: 'failed',
      finishedAt: toIso(new Date()),
      ...(resultOptions.extra || {}),
      errors: [{ message: error.message || String(error) }],
    };
    writeServiceJournal(failed);
    return failed;
  }

  fs.closeSync(output);
  const processInfo = {
    pid: child.pid,
    detached: child.detached !== false,
    pidPath: plan.paths.pidPath,
  };
  const result = {
    ...plan,
    status: resultOptions.status || 'started',
    dryRun: false,
    startedAt: toIso(new Date()),
    ...(resultOptions.extra || {}),
    process: processInfo,
    journal: {
      path: plan.paths.journalPath,
      written: true,
    },
    log: {
      path: plan.paths.logPath,
    },
  };

  writeJson(plan.paths.pidPath, {
    schemaVersion: 1,
    profileId: plan.profile.id,
    actionRunId: plan.actionRunId,
    actionId: plan.actionId,
    service: plan.service,
    pid: child.pid,
    startedAt: result.startedAt,
    command: plan.command,
    logPath: plan.paths.logPath,
    journalPath: plan.paths.journalPath,
    guardrails: SERVICE_ACTION_GUARDRAILS,
  });
  writeServiceJournal(result);
  return redactForDisplay(result);
}

function spawnConfiguredProcess(plan, output, options = {}) {
  if (options.processSpawner) {
    const spawned = options.processSpawner({
      command: plan.command,
      env: { ...process.env, ...(options.env || {}) },
      output,
      plan,
    });
    if (!spawned || !Number.isInteger(Number(spawned.pid))) {
      throw new Error('Custom process spawner did not return a numeric pid.');
    }
    return {
      detached: spawned.detached !== false,
      pid: Number(spawned.pid),
      unref: typeof spawned.unref === 'function' ? () => spawned.unref() : null,
    };
  }

  if (process.platform === 'win32' && options.windowsStartProcess !== false) {
    return spawnWindowsProcess(plan);
  }

  const detached = options.detached ?? true;
  const child = childProcess.spawn(plan.command.executable, plan.command.args, {
    cwd: plan.command.cwd || undefined,
    detached,
    env: { ...process.env, ...(options.env || {}) },
    stdio: ['ignore', output, output],
    windowsHide: true,
  });
  return {
    detached,
    pid: child.pid,
    unref: () => child.unref(),
  };
}

function spawnWindowsProcess(plan) {
  const argLine = plan.command.args.map(quoteArg).join(' ');
  const lines = [
    '$ErrorActionPreference = "Stop"',
    `$exe = ${powershellString(plan.command.executable)}`,
    `$cwd = ${powershellString(plan.command.cwd || '')}`,
    `$argLine = ${powershellString(argLine)}`,
    '$startInfo = @{ FilePath = $exe; WindowStyle = "Hidden"; PassThru = $true }',
    'if ($cwd -ne "") { $startInfo.WorkingDirectory = $cwd }',
    'if ($argLine -ne "") { $startInfo.ArgumentList = $argLine }',
    '$process = Start-Process @startInfo',
    '[Console]::Out.Write($process.Id)',
  ];
  const result = childProcess.spawnSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', lines.join('; ')],
    {
      encoding: 'utf8',
      windowsHide: true,
      env: process.env,
    },
  );
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `Start-Process failed with exit code ${result.status}`).trim());
  }
  const pid = Number(String(result.stdout || '').trim());
  if (!Number.isInteger(pid) || pid <= 0) {
    throw new Error(`Start-Process did not return a valid pid: ${String(result.stdout || '').trim()}`);
  }
  return {
    detached: false,
    pid,
    unref: null,
  };
}

function executeStopPlan(plan, options = {}) {
  ensureDir(plan.paths.actionRoot);
  const stoppedAt = toIso(new Date());
  const stop = stopOwnedProcess(plan, options);
  appendServiceLog(plan.paths.logPath, [
    `[${stoppedAt}] BMF service action ${plan.actionRunId} stop result=${stop.status} pid=${stop.pid || 'none'}`,
    stop.message ? `[${stoppedAt}] ${stop.message}` : null,
  ]);
  const pidFileRemoved = cleanupOwnedPidFile(plan, stop);
  const result = {
    ...plan,
    status: stop.status === 'already-stopped' ? 'already-stopped' : stop.status === 'stopped' ? 'stopped' : 'failed',
    dryRun: false,
    stoppedAt,
    finishedAt: stoppedAt,
    stop: {
      ...stop,
      pidFileRemoved,
    },
    journal: {
      path: plan.paths.journalPath,
      written: true,
    },
    log: {
      path: plan.paths.logPath,
    },
    errors: stop.status === 'failed' ? [{ message: stop.message || 'Stop failed.' }] : [],
  };
  writeServiceJournal(result);
  return redactForDisplay(result);
}

function executeRestartPlan(plan, options = {}) {
  const stopped = executeStopPlan({
    ...plan,
    actionRunId: `${plan.actionRunId}-stop`,
  }, {
    ...options,
    suppressPidCleanupError: false,
  });
  if (!['stopped', 'already-stopped'].includes(stopped.status)) {
    const failed = {
      ...plan,
      status: 'failed',
      dryRun: false,
      finishedAt: toIso(new Date()),
      stop: stopped.stop,
      errors: stopped.errors?.length ? stopped.errors : [{ message: 'Restart stop step failed.' }],
      journal: {
        path: plan.paths.journalPath,
        written: true,
      },
    };
    writeServiceJournal(failed);
    return redactForDisplay(failed);
  }

  return executeStartPlan(plan, options, {
    status: 'restarted',
    extra: {
      stoppedAt: stopped.stoppedAt,
      stop: stopped.stop,
    },
  });
}

function stopOwnedProcess(plan, options = {}) {
  const owned = plan.ownedProcess || {};
  const pid = Number(owned.pid);
  if (owned.status === 'not-running') {
    return {
      pid,
      status: 'already-stopped',
      message: 'Owned PID metadata was present, but the process is no longer running.',
    };
  }
  if (owned.status !== 'running' || !owned.verified) {
    return {
      pid,
      status: 'failed',
      message: owned.summary || 'Owned process could not be verified for safe shutdown.',
    };
  }

  return killOwnedProcess(pid, options);
}

function killOwnedProcess(pid, options = {}) {
  if (options.processKiller) {
    return normalizeKillResult(options.processKiller(pid), pid);
  }
  if (process.platform === 'win32') {
    const result = childProcess.spawnSync('taskkill.exe', taskkillArgs(pid), {
      encoding: 'utf8',
      timeout: boundedInteger(options.killTimeoutMs, 5000, 1000, 30000),
      windowsHide: true,
    });
    if (result.status === 0) {
      return { pid, status: 'stopped', signal: 'taskkill', message: 'Stopped owned process tree with taskkill.' };
    }
    return {
      pid,
      status: 'failed',
      signal: 'taskkill',
      message: (result.stderr || result.stdout || result.error?.message || 'taskkill failed').trim(),
    };
  }
  try {
    process.kill(pid, 'SIGTERM');
    return { pid, status: 'stopped', signal: 'SIGTERM', message: 'Sent SIGTERM to owned process.' };
  } catch (error) {
    if (error.code === 'ESRCH') {
      return { pid, status: 'already-stopped', message: 'Owned process was already stopped.' };
    }
    return { pid, status: 'failed', signal: 'SIGTERM', message: error.message || String(error) };
  }
}

function taskkillArgs(pid) {
  return ['/PID', String(pid), '/T', '/F'];
}

function normalizeKillResult(result, pid) {
  if (!result || typeof result !== 'object') {
    return { pid, status: result === false ? 'failed' : 'stopped', message: '' };
  }
  return {
    pid: Number(result.pid || pid),
    status: ['stopped', 'already-stopped', 'failed'].includes(result.status) ? result.status : 'stopped',
    signal: result.signal || null,
    message: result.message || '',
  };
}

function cleanupOwnedPidFile(plan, stop) {
  if (!['stopped', 'already-stopped'].includes(stop.status)) return false;
  try {
    fs.rmSync(plan.paths.pidPath, { force: true });
    return true;
  } catch {
    return false;
  }
}

function appendServiceLog(logPath, lines) {
  ensureDir(path.dirname(logPath));
  fs.appendFileSync(logPath, `${lines.filter(Boolean).join('\n')}\n`, 'utf8');
}

function buildServiceLaunchCommand(actionId, input) {
  if (isAlloyAction(actionId)) return buildAlloyLaunchCommand(input);
  return buildOmeggaLaunchCommand(input);
}

function buildOmeggaLaunchCommand(input) {
  const cwd = normalizeNullablePath(input.cwd || input.omeggaRuntime || (input.startScript ? path.dirname(input.startScript) : null));
  if (input.command) {
    const args = Array.isArray(input.args) ? input.args.map(String) : [];
    return decorateCommand(input.command, args, cwd, null);
  }
  if (!input.startScript) {
    return decorateCommand(null, [], cwd, input.startScript);
  }
  return decorateCommand(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', input.startScript],
    cwd,
    input.startScript,
  );
}

function buildAlloyLaunchCommand(input) {
  const cwd = normalizeNullablePath(input.cwd || (input.alloyConfig ? path.dirname(input.alloyConfig) : null));
  if (input.command) {
    const args = Array.isArray(input.args) ? input.args.map(String) : [];
    return decorateCommand(input.command, args, cwd, null, {
      alloyConfig: input.alloyConfig || null,
      alloyStoragePath: input.alloyStoragePath || null,
    });
  }
  if (!input.alloyExecutable) {
    return decorateCommand(null, [], cwd, null, {
      alloyConfig: input.alloyConfig || null,
      alloyStoragePath: input.alloyStoragePath || null,
    });
  }
  const args = [
    'run',
    input.alloyConfig,
    `--storage.path=${input.alloyStoragePath}`,
    `--server.http.listen-addr=127.0.0.1:${boundedInteger(input.alloyReadyPort, 12345, 1, 65535)}`,
  ];
  return decorateCommand(input.alloyExecutable, args, cwd, null, {
    alloyConfig: input.alloyConfig || null,
    alloyStoragePath: input.alloyStoragePath || null,
  });
}

function decorateCommand(executable, args, cwd, startScript, extra = {}) {
  const normalizedArgs = args.filter(arg => arg !== null && arg !== undefined).map(String);
  return {
    executable: executable ? String(executable) : null,
    args: normalizedArgs,
    cwd,
    startScript,
    ...extra,
    display: executable ? commandDisplay(executable, normalizedArgs) : '(not configured)',
  };
}

function readOwnedProcess(pidPath, profile, options = {}) {
  const expectedService = options.expectedService || 'omegga-runtime';
  const base = {
    pidPath,
    pidFileExists: exists(pidPath),
    pid: null,
    status: 'missing',
    verified: false,
    summary: `No owned BMF PID file exists at ${pidPath}.`,
    metadata: null,
    error: null,
  };
  if (!base.pidFileExists) return base;

  let metadata;
  try {
    metadata = JSON.parse(fs.readFileSync(pidPath, 'utf8'));
  } catch (error) {
    return {
      ...base,
      status: 'invalid',
      summary: `Owned PID metadata could not be parsed: ${error.message || String(error)}`,
      error: error.message || String(error),
    };
  }

  const pid = Number(metadata.pid);
  const metadataIssues = [];
  if (!Number.isInteger(pid) || pid <= 0) metadataIssues.push('pid must be a positive integer');
  if (metadata.service !== expectedService) metadataIssues.push(`service must be ${expectedService}`);
  if (metadata.profileId !== profile.id) metadataIssues.push(`profileId must match ${profile.id}`);
  if (!metadata.actionRunId) metadataIssues.push('actionRunId is required');
  if (!metadata.startedAt) metadataIssues.push('startedAt is required');

  if (metadataIssues.length > 0) {
    return {
      ...base,
      pid: Number.isFinite(pid) ? pid : null,
      status: 'invalid',
      summary: `Owned PID metadata is invalid: ${metadataIssues.join('; ')}.`,
      metadata: publicOwnedMetadata(metadata),
    };
  }

  const inspected = inspectOwnedProcess(pid, metadata, options);
  return {
    ...base,
    pid,
    status: inspected.status,
    verified: inspected.verified,
    summary: inspected.summary,
    metadata: publicOwnedMetadata(metadata),
    processName: inspected.processName || null,
    executablePath: inspected.executablePath || null,
    creationTime: inspected.creationTime || null,
    verification: inspected.verification || null,
  };
}

function inspectOwnedProcess(pid, metadata, options = {}) {
  if (options.processInspector) {
    return normalizeProcessInspection(options.processInspector(pid, metadata), pid, metadata);
  }
  if (process.platform === 'win32') {
    return inspectWindowsProcess(pid, metadata);
  }
  return inspectPortableProcess(pid, metadata);
}

function inspectWindowsProcess(pid, metadata) {
  const script = [
    `$p = Get-CimInstance Win32_Process -Filter "ProcessId = ${pid}"`,
    'if ($null -eq $p) { "null" } else { $p | Select-Object ProcessId,Name,ExecutablePath,CommandLine,CreationDate | ConvertTo-Json -Compress }',
  ].join('; ');
  const result = childProcess.spawnSync('powershell.exe', ['-NoProfile', '-Command', script], {
    encoding: 'utf8',
    timeout: 5000,
    windowsHide: true,
  });
  if (result.error) {
    return {
      status: 'unknown',
      verified: false,
      summary: `Unable to inspect owned process ${pid}: ${result.error.message}`,
    };
  }
  const text = String(result.stdout || '').trim();
  if (!text || text === 'null') {
    return {
      status: 'not-running',
      verified: true,
      summary: `Owned process ${pid} is not running.`,
    };
  }

  let record;
  try {
    record = JSON.parse(text);
  } catch (error) {
    return {
      status: 'unknown',
      verified: false,
      summary: `Unable to parse process inspection for PID ${pid}: ${error.message || String(error)}`,
    };
  }

  return normalizeProcessInspection({
    status: 'running',
    verified: processRecordMatchesMetadata(record, metadata),
    processName: record.Name || null,
    executablePath: record.ExecutablePath || null,
    commandLine: record.CommandLine || null,
    creationTime: processCreationTime(record.CreationDate),
    verification: 'win32-cim-command-and-creation-time',
  }, pid, metadata);
}

function inspectPortableProcess(pid) {
  try {
    process.kill(pid, 0);
    return {
      status: 'running',
      verified: false,
      summary: `Process ${pid} exists, but this platform cannot verify creation time and command metadata.`,
      verification: 'portable-pid-existence-only',
    };
  } catch (error) {
    if (error.code === 'ESRCH') {
      return {
        status: 'not-running',
        verified: true,
        summary: `Owned process ${pid} is not running.`,
        verification: 'portable-pid-not-running',
      };
    }
    return {
      status: 'unknown',
      verified: false,
      summary: error.message || String(error),
      verification: 'portable-pid-check-failed',
    };
  }
}

function normalizeProcessInspection(value, pid, metadata) {
  const status = ['running', 'not-running', 'unknown'].includes(value?.status)
    ? value.status
    : value?.running === false ? 'not-running' : 'running';
  const verified = Boolean(value?.verified) || status === 'not-running';
  const summary = value?.summary
    || (status === 'running' && verified
      ? `Owned process ${pid} was verified for ${metadata.profileId}.`
      : status === 'running'
        ? `Process ${pid} is running but was not verified as the BMF-owned process.`
        : status === 'not-running'
          ? `Owned process ${pid} is not running.`
          : `Owned process ${pid} state is unknown.`);
  return {
    status,
    verified,
    summary,
    processName: value?.processName || null,
    executablePath: value?.executablePath || null,
    creationTime: value?.creationTime || null,
    verification: value?.verification || null,
  };
}

function processRecordMatchesMetadata(record, metadata) {
  const commandLine = normalizeMatchText(record.CommandLine || '');
  const executablePath = normalizeMatchText(record.ExecutablePath || '');
  const expectedExecutable = normalizeMatchText(metadata.command?.executable || '');
  const expectedStartScript = normalizeMatchText(metadata.command?.startScript || '');
  const commandMatches = expectedStartScript
    ? commandLine.includes(expectedStartScript)
    : expectedExecutable && executablePath.endsWith(path.basename(expectedExecutable));
  const recordMs = processCreationTime(record.CreationDate);
  const metadataMs = Date.parse(metadata.startedAt);
  const creationMatches = Number.isFinite(recordMs)
    && Number.isFinite(metadataMs)
    && Math.abs(recordMs - metadataMs) <= 5 * 60 * 1000;
  return Boolean(commandMatches && creationMatches);
}

function processCreationTime(value) {
  if (!value) return NaN;
  const jsonDateMatch = String(value).match(/^\/Date\((-?\d+)(?:[+-]\d+)?\)\/$/);
  if (jsonDateMatch) return Number(jsonDateMatch[1]);
  const parsed = Date.parse(value);
  if (Number.isFinite(parsed)) return parsed;
  const match = String(value).match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\.\d+)?([+-]\d{3})?$/);
  if (!match) return NaN;
  const utcMs = Date.UTC(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6]),
  );
  const offsetMinutes = match[7] ? Number(match[7]) : 0;
  return utcMs - offsetMinutes * 60 * 1000;
}

function normalizeMatchText(value) {
  return String(value || '').replace(/\//g, '\\').toLowerCase();
}

function publicOwnedMetadata(metadata) {
  return redactForDisplay({
    schemaVersion: metadata?.schemaVersion || null,
    profileId: metadata?.profileId || null,
    actionRunId: metadata?.actionRunId || null,
    actionId: metadata?.actionId || null,
    service: metadata?.service || null,
    pid: metadata?.pid || null,
    startedAt: metadata?.startedAt || null,
    command: metadata?.command || null,
    logPath: metadata?.logPath || null,
    journalPath: metadata?.journalPath || null,
  });
}

function buildBlockers(actionId, context) {
  const blockers = [];
  for (const [id, targetPath] of [
    ['journal-path-outside-service-root', context.journalPath],
    ['log-path-outside-service-root', context.logPath],
    ['pid-path-outside-service-root', context.pidPath],
  ]) {
    if (!isSameOrChild(context.actionRoot, targetPath)) {
      blockers.push(blocker(id, `Service path is outside the service action root: ${targetPath}`));
    }
  }

  if (isStopAction(actionId) || isRestartAction(actionId)) {
    addOwnedProcessBlockers(blockers, context.ownedProcess);
  }

  if (isStopAction(actionId)) {
    return blockers;
  }

  if (isAlloyAction(actionId)) {
    if (!context.command.executable) {
      blockers.push(blocker('alloy-command-not-configured', 'profile.paths.grafanaAlloyExecutable or --alloy-executable is required before launch.'));
    } else if (context.alloyExecutable && !exists(context.alloyExecutable)) {
      blockers.push(blocker('alloy-executable-missing', `Grafana Alloy executable does not exist: ${context.alloyExecutable}`));
    }

    if (!context.alloyConfig) {
      blockers.push(blocker('alloy-config-not-configured', 'profile.paths.grafanaAlloyConfig or --alloy-config is required before launch.'));
    } else if (!exists(context.alloyConfig)) {
      blockers.push(blocker('alloy-config-missing', `Grafana Alloy config does not exist: ${context.alloyConfig}`));
    }

    if (!isSameOrChild(context.actionRoot, context.alloyStoragePath)) {
      blockers.push(blocker('alloy-storage-path-outside-service-root', `Alloy storage path is outside the service action root: ${context.alloyStoragePath}`));
    }

    if (context.serviceDiagnostics.startReadiness.status === 'blocked' || context.serviceDiagnostics.startReadiness.status === 'degraded') {
      for (const blockedPort of context.serviceDiagnostics.startReadiness.warnings || []) {
        if (blockedPort.portId === 'alloy-ready' || blockedPort.id === 'alloy-ready') {
          blockers.push(blocker('port-alloy-ready-in-use', blockedPort.summary, blockedPort));
        }
      }
    }

    return blockers;
  }

  if (!context.omeggaRuntime) {
    blockers.push(blocker('omegga-runtime-not-configured', 'profile.paths.omeggaRuntime is required before launch.'));
  } else if (!exists(context.omeggaRuntime)) {
    blockers.push(blocker('omegga-runtime-missing', `Omegga runtime path does not exist: ${context.omeggaRuntime}`));
  }

  if (!context.command.executable) {
    blockers.push(blocker('start-command-not-configured', 'profile.paths.omeggaStartScript or --start-script is required before launch.'));
  }

  if (!context.command.startScript && !context.command.executable) {
    blockers.push(blocker('start-script-not-configured', 'No Omegga start script is configured for this profile.'));
  } else if (context.command.startScript && !exists(context.command.startScript)) {
    blockers.push(blocker('start-script-missing', `Omegga start script does not exist: ${context.command.startScript}`));
  }

  if (actionId === 'start-stack' && context.serviceDiagnostics.startReadiness.status === 'blocked') {
    for (const blockedPort of context.serviceDiagnostics.startReadiness.blockers || []) {
      blockers.push(blocker(`port-${blockedPort.portId}-in-use`, blockedPort.summary, blockedPort));
    }
  }

  return blockers;
}

function addOwnedProcessBlockers(blockers, ownedProcess = {}) {
  if (!ownedProcess.pidFileExists) {
    blockers.push(blocker('owned-pid-missing', ownedProcess.summary || 'No BMF-owned PID file exists.'));
    return;
  }
  if (ownedProcess.status === 'invalid') {
    blockers.push(blocker('owned-pid-invalid', ownedProcess.summary || 'Owned PID metadata is invalid.'));
    return;
  }
  if (ownedProcess.status === 'unknown') {
    blockers.push(blocker('owned-process-state-unknown', ownedProcess.summary || 'Owned process state is unknown.'));
    return;
  }
  if (ownedProcess.status === 'running' && !ownedProcess.verified) {
    blockers.push(blocker('owned-process-unverified', ownedProcess.summary || 'Running process could not be verified as BMF-owned.'));
  }
}

function buildWarnings(actionId, diagnostics) {
  const warnings = [];
  for (const warning of diagnostics.startReadiness.warnings || []) {
    warnings.push({
      id: `port-${warning.portId}-${warning.status}`,
      summary: warning.summary,
      nextAction: warning.nextAction || actionId,
    });
  }
  if (diagnostics.startReadiness.status === 'unknown') {
    warnings.push({
      id: 'port-diagnostics-not-inspected',
      summary: diagnostics.startReadiness.summary,
      nextAction: 'health --port-diagnostics',
    });
  }
  return warnings;
}

function buildSteps(actionId, blockers, warnings, _backend = 'local-process') {
  const component = serviceForAction(actionId);
  const serviceLabel = isAlloyAction(actionId) ? 'Grafana Alloy' : 'Omegga';
  const spawnStepId = isAlloyAction(actionId) ? 'spawn-alloy' : 'spawn-omegga';
  const validateTitle = isAlloyAction(actionId)
    ? 'Validate configured Alloy command and scoped log paths'
    : 'Validate configured launch command and scoped log paths';

  if (isStopAction(actionId)) {
    return [
      step('read-owned-pid', 'Read BMF-owned PID metadata', 'read-file', false, blockers, [], component),
      step('stop-owned-process', `Stop owned ${serviceLabel} process`, 'stop-process', true, blockers, [], component),
      step('append-stop-log', 'Append stop result to local service log', 'log-append', true, blockers, [], component),
    ];
  }
  if (isRestartAction(actionId)) {
    return [
      step('read-owned-pid', 'Read BMF-owned PID metadata', 'read-file', false, blockers, [], component),
      step('stop-owned-process', `Stop owned ${serviceLabel} process`, 'stop-process', true, blockers, [], component),
      step(spawnStepId, `Spawn configured ${serviceLabel} command`, 'start-process', true, blockers, [], component),
      step('write-launch-metadata', 'Write launch journal and PID metadata', 'write-json', true, blockers, [], component),
    ];
  }
  return [
    step('check-launch-contract', validateTitle, 'verify', false, blockers, [], component),
    step('review-port-readiness', 'Review supplied local port diagnostics', 'port-check', false, [], warnings, 'orchestrator-core'),
    step(spawnStepId, `Spawn configured ${serviceLabel} command`, 'start-process', true, blockers, [], component),
    step('write-launch-metadata', 'Write launch journal and PID metadata', 'write-json', true, blockers, [], component),
  ];
}

function step(id, title, kind, mutates, blockers, warnings = [], component = null) {
  return {
    id,
    title,
    component: component || (kind === 'port-check' ? 'orchestrator-core' : 'omegga-runtime'),
    kind,
    mutates,
    status: blockers.length > 0 ? 'blocked' : 'ready',
    blockedReason: blockers.map(item => item.summary).join('; ') || null,
    warnings: warnings.map(warning => ({ ...warning })),
  };
}

function summarizeSteps(steps, warnings) {
  return steps.reduce((summary, item) => {
    summary.total += 1;
    if (item.mutates) summary.mutating += 1;
    else summary.readOnly += 1;
    if (item.status === 'ready') summary.ready += 1;
    if (item.status === 'blocked') summary.blocked += 1;
    summary.warnings = warnings.length;
    return summary;
  }, {
    total: 0,
    mutating: 0,
    readOnly: 0,
    ready: 0,
    blocked: 0,
    warnings: warnings.length,
  });
}

function blocker(id, summary, details = {}) {
  return {
    id,
    summary,
    nextAction: details.nextAction || null,
    port: details.port || null,
    protocol: details.protocol || null,
  };
}

function hasPathScopeBlocker(blockers = []) {
  return blockers.some(item => /outside-service-root$/.test(item.id));
}

function writeServiceJournal(action) {
  writeJson(action.paths.journalPath, redactForDisplay(action));
}

function writeJson(filepath, value) {
  ensureDir(path.dirname(filepath));
  fs.writeFileSync(filepath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function redactForDisplay(value) {
  return redactValue(value).value;
}

function commandDisplay(executable, args) {
  return [executable, ...args].map(quoteArg).join(' ');
}

function quoteArg(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_./:=\\-]+$/.test(text)) return text;
  return `"${text.replace(/"/g, '\\"')}"`;
}

function powershellString(value) {
  return `'${String(value || '').replace(/'/g, "''")}'`;
}

function normalizeActionId(actionId) {
  const value = String(actionId || 'start-stack').toLowerCase();
  if (value === 'start') return 'start-stack';
  if (value === 'stop') return 'stop-stack';
  if (value === 'restart') return 'restart-stack';
  if (value === 'alloy-start') return 'start-alloy';
  if (value === 'alloy-stop') return 'stop-alloy';
  if (value === 'alloy-restart') return 'restart-alloy';
  return value;
}

function serviceDiagnosticTargetsForAction(actionId, profile) {
  const targets = getConfiguredPortTargets(profile);
  if (!isAlloyAction(actionId)) return targets;
  return targets
    .filter(target => target.id === 'alloy-ready')
    .map(target => ({
      ...target,
      enabled: Number(target.port) > 0,
      requiredForTelemetryStart: true,
      nextAction: 'start-alloy',
    }));
}

function serviceForAction(actionId) {
  return isAlloyAction(actionId) ? 'grafana-alloy' : 'omegga-runtime';
}

function serviceSlugForAction(actionId) {
  return isAlloyAction(actionId) ? 'alloy' : 'omegga';
}

function isAlloyAction(actionId) {
  return String(actionId || '').endsWith('-alloy');
}

function isStopAction(actionId) {
  return String(actionId || '').startsWith('stop-');
}

function isRestartAction(actionId) {
  return String(actionId || '').startsWith('restart-');
}

function normalizeNullablePath(value) {
  return value ? path.resolve(String(value)) : null;
}

function resolveRoot(root) {
  return path.resolve(root || path.join(__dirname, '..', '..', '..'));
}

function exists(filepath) {
  return Boolean(filepath) && fs.existsSync(filepath);
}

function isSameOrChild(root, candidate) {
  if (!root || !candidate) return false;
  const relative = path.relative(path.resolve(root), path.resolve(candidate));
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function makeActionRunId(actionId, createdAt) {
  return `${sanitizeId(actionId)}-${createdAt.replace(/[:.]/g, '-')}`;
}

function sanitizeId(value) {
  return String(value || 'service-action').replace(/[^a-zA-Z0-9_.-]+/g, '-');
}

function confirmationForAction(actionId) {
  if (isStopAction(actionId)) return 'stop';
  if (isRestartAction(actionId)) return 'restart';
  return 'start';
}

function serviceActionVerb(actionId) {
  if (isStopAction(actionId)) return 'stop';
  if (isRestartAction(actionId)) return 'restart';
  return 'start';
}

function boundedInteger(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  SERVICE_ACTION_DEFINITIONS,
  SERVICE_ACTION_GUARDRAILS,
  SERVICE_ACTION_IDS,
  createServiceActionPlan,
  executeServiceAction,
  __private: {
    processCreationTime,
    processRecordMatchesMetadata,
    taskkillArgs,
  },
};
