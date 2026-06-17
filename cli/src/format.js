const path = require('node:path');

const LABELS = {
  ok: 'OK',
  info: 'INFO',
  warning: 'WARN',
  critical: 'CRIT',
};

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function printDoctor(report) {
  console.log(`BMF doctor: ${report.status.toUpperCase()}`);
  console.log(
    `Findings: ${report.summary.critical} critical, ${report.summary.warning} warning, ${report.summary.info} info, ${report.summary.ok} ok`,
  );
  console.log('');
  console.log(`BMF:    ${report.context.bmfRoot}`);
  console.log(`Omegga: ${report.context.omeggaDir}`);
  console.log(`Win64:  ${report.context.gameWin64Dir || '(not detected)'}`);
  console.log('');

  for (const item of report.findings) {
    console.log(`${LABELS[item.severity] || item.severity.toUpperCase()}  ${item.id}`);
    console.log(`       ${item.title}`);
    if (item.detail) console.log(`       ${item.detail}`);
    for (const evidence of item.evidence || []) console.log(`       evidence: ${evidence}`);
    if (item.nextAction) console.log(`       next: ${item.nextAction}`);
    if (item.repair?.id) console.log(`       repair: bmfctl repair ${item.repair.id}`);
    console.log('');
  }
}

function printHealth(report) {
  console.log(`BMF health: ${report.health.status.toUpperCase()}`);
  console.log(
    `Checks: ${report.health.summary.healthy} healthy, ${report.health.summary.degraded} degraded, ${report.health.summary.unhealthy} unhealthy, ${report.health.summary.unknown} unknown`,
  );
  console.log(`Profile: ${report.profile.name || report.profile.id}`);
  console.log(`Collected: ${report.collectedAt}`);
  console.log('');

  for (const check of report.health.checks) {
    console.log(`${check.status.toUpperCase().padEnd(9)} ${check.id} (${check.component})`);
    console.log(`          ${check.summary}`);
    for (const evidence of check.evidence || []) console.log(`          evidence: ${evidence}`);
    if (check.nextAction) console.log(`          next: bmfctl plan ${check.nextAction}`);
    console.log('');
  }

  if (report.logSources?.length) {
    console.log('Log sources:');
    for (const source of report.logSources) {
      console.log(`- ${source.exists ? 'found' : 'missing'} ${source.id}: ${source.path}`);
    }
  }

  if (report.serviceDiagnostics?.ports?.length) {
    console.log('');
    console.log(`Start readiness: ${report.serviceDiagnostics.startReadiness.status.toUpperCase()}`);
    console.log(report.serviceDiagnostics.startReadiness.summary);
    console.log('Ports:');
    for (const port of report.serviceDiagnostics.ports) {
      const owner = port.ownerSummary ? ` owner=${port.ownerSummary}` : '';
      console.log(`- ${port.status.padEnd(14)} ${port.id} ${port.protocol.toUpperCase()} ${port.port || '(none)'}${owner}`);
      console.log(`  ${port.summary}`);
    }
  }
}

function printRepair(result) {
  console.log(`${result.dryRun ? 'Dry run' : 'Applied'}: ${result.repairId}`);
  console.log(result.title);
  for (const change of result.changes) {
    const from = change.source ? ` from ${change.source}` : '';
    console.log(`- ${change.action}: ${change.path}${from}`);
    if (change.backupPath) console.log(`  backup: ${change.backupPath}`);
  }
  if (result.changes.length === 0) console.log('- no changes needed');
  if (result.logPath) console.log(`log: ${result.logPath}`);
}

function printRepairAll(result) {
  console.log(`Repairs selected: ${result.repairs.length}`);
  if (result.repairs.length === 0) {
    console.log('No repairable critical/warning findings.');
    return;
  }
  for (const repair of result.repairs) {
    printRepair(repair);
    console.log('');
  }
  if (result.after) {
    console.log(`Doctor after repairs: ${result.after.status.toUpperCase()}`);
  }
}

function printMods(modsDir, mods) {
  console.log(`UE4SS Mods: ${modsDir}`);
  if (mods.length === 0) {
    console.log('No mods found.');
    return;
  }
  for (const mod of mods) {
    const txt = mod.txtEnabled === null ? '?' : mod.txtEnabled ? 'on' : 'off';
    const json = mod.jsonEnabled === null ? '?' : mod.jsonEnabled ? 'on' : 'off';
    const folder = mod.folderExists ? 'folder' : 'missing-folder';
    console.log(`${mod.name.padEnd(32)} txt=${txt.padEnd(3)} json=${json.padEnd(3)} ${folder}`);
  }
}

function printSnapshot(snapshot) {
  console.log(`Snapshot: ${snapshot.root}`);
  console.log(`Doctor status: ${snapshot.doctor.status}`);
  console.log(`Files copied: ${snapshot.copiedFiles.length}`);
  console.log(`Logs copied: ${snapshot.copiedLogs.length}`);
  console.log(`Open: ${path.join(snapshot.root, 'snapshot.json')}`);
}

function printPlan(plan) {
  console.log(`${plan.title} (${plan.dryRun ? 'dry run' : 'ready'})`);
  console.log(`Profile: ${plan.profile?.name || plan.profile?.id || 'unknown'}`);
  if (plan.prerequisites?.summary) {
    console.log(
      `Prerequisites: ${plan.prerequisites.status.toUpperCase()} ` +
      `blocked=${plan.prerequisites.summary.blocked} healthy=${plan.prerequisites.summary.healthy}/${plan.prerequisites.summary.total}`,
    );
  }

  if (Array.isArray(plan.operations)) {
    console.log(`Operations: ${plan.operations.length}`);
    for (const operation of plan.operations) {
      console.log(`- ${operation.operationId}: ${operation.actions.length} action(s)`);
    }
    return;
  }

  console.log(`Operation: ${plan.operationId}`);
  console.log(`Actions: ${plan.actions.length}`);
  for (const action of plan.actions) {
    const suffix = action.healthCheck ? ` [${action.healthCheck}]` : '';
    console.log(`- ${action.mode}: ${action.id} (${action.component}/${action.kind})${suffix}`);
  }
}

function printPrerequisites(report) {
  console.log(`BMF prerequisites: ${report.status.toUpperCase()}`);
  console.log(`Profile: ${report.profile?.name || report.profile?.id || 'unknown'}`);
  console.log(`Root: ${report.root}`);
  console.log(
    `Checks: ${report.summary.healthy} healthy, ${report.summary.degraded} degraded, ` +
    `${report.summary.unhealthy} unhealthy, ${report.summary.unknown} unknown, ${report.summary.blocked} blocking`,
  );
  console.log('');

  for (const check of report.checks || []) {
    const marker = check.required ? 'required' : 'optional';
    console.log(`${check.status.toUpperCase().padEnd(9)} ${check.id} (${marker})`);
    console.log(`          ${check.summary}`);
    for (const evidence of check.evidence || []) console.log(`          evidence: ${evidence}`);
    if (check.remediation?.profileField) console.log(`          profile: ${check.remediation.profileField}`);
    if (check.remediation?.operationId) console.log(`          operation: bmfctl plan ${check.remediation.operationId}`);
    if (check.nextAction) console.log(`          next: ${check.nextAction}`);
    console.log('');
  }
}

function printProfiles(result, action = 'list') {
  console.log(`BMF profiles: ${result.summary?.total ?? (result.profile ? 1 : 0)} stored`);
  if (result.storePath) console.log(`Store: ${result.storePath}`);
  if (result.selectedProfileId) console.log(`Selected: ${result.selectedProfileId}`);
  console.log('');

  if (result.profile) {
    printProfile(result.profile, result.selectedProfileId);
    return;
  }

  const profiles = result.profiles || [];
  if (profiles.length === 0) {
    console.log(action === 'save' ? 'No profiles stored.' : 'No stored profiles. Use bmfctl profiles save.');
    return;
  }

  for (const profile of profiles) {
    printProfile(profile, result.selectedProfileId);
    console.log('');
  }
}

function printProfile(profile, selectedProfileId) {
  const marker = profile.id === selectedProfileId ? '*' : '-';
  console.log(`${marker} ${profile.id}: ${profile.name}`);
  console.log(`  backend: ${profile.backend}`);
  console.log(`  ports: brickadia=${profile.ports?.brickadia} omeggaWeb=${profile.ports?.omeggaWeb} bmfSocket=${profile.ports?.bmfSocket} alloyReady=${profile.ports?.alloyReady}`);
  console.log(`  win64: ${profile.paths?.brickadiaWin64 || '(not configured)'}`);
  console.log(`  omegga: ${profile.paths?.omeggaRuntime || '(not configured)'}`);
  console.log(`  runtime: ${profile.paths?.bmfRuntimeDir || '(not configured)'}`);
  console.log(`  telemetry: ${profile.telemetry?.enabled ? 'enabled' : 'disabled'} dashboard=${profile.telemetry?.dashboardUrl || '(not configured)'}`);
}

function printTelemetryPlan(plan) {
  console.log(`BMF telemetry: ${plan.status.toUpperCase()}`);
  console.log(`Profile: ${plan.profile.name || plan.profile.id}`);
  console.log(`Alloy output: ${plan.alloy.outputPath || '(not configured)'}`);
  console.log(`Metrics: ${plan.alloy.metricsUrl}`);
  console.log(`Alloy ready: ${plan.alloy.readyUrl}`);
  console.log(`Dashboard: ${plan.dashboard.dashboardUrl || '(not configured)'}`);
  console.log('');
  console.log('Labels:');
  for (const [key, value] of Object.entries(plan.labels)) {
    console.log(`- ${key}: ${value}`);
  }
  console.log('');
  console.log('Secret refs:');
  for (const secret of plan.alloy.secretStatus) {
    console.log(`- ${secret.configured ? 'set' : 'missing'} ${secret.ref}`);
  }
}

function printTelemetryAlloyWrite(result) {
  console.log(`${result.dryRun ? 'Dry run' : 'Wrote'} Alloy config: ${result.outputPath}`);
  console.log(`Bytes: ${result.bytes}`);
  console.log(`SHA256: ${result.sha256}`);
  if (result.missingSecretRefs?.length) {
    console.log(`Missing env refs: ${result.missingSecretRefs.join(', ')}`);
  }
}

function printTelemetryDashboardImport(result) {
  const writeMode = result.feature === 'telemetry.dashboard.import-payload.write';
  const uploadMode = result.feature === 'telemetry.dashboard.import.upload';
  console.log(uploadMode
    ? `Grafana dashboard upload: ${result.status.toUpperCase()}`
    : writeMode
    ? `${result.dryRun ? 'Dry run' : 'Wrote'} dashboard import payload: ${result.outputPath}`
    : `BMF dashboard import: ${result.status.toUpperCase()}`);
  console.log(`Dashboard: ${result.dashboard.dashboardUid} (${result.dashboard.dashboardVersion})`);
  console.log(`Endpoint: ${result.request.method} ${result.request.url || result.request.apiPath}`);
  console.log(`Payload: ${result.outputPath || result.request.outputPath || result.request.payloadSha256 || 'not written'}`);
  if (result.bytes) console.log(`Bytes: ${result.bytes}`);
  if (result.sha256) console.log(`SHA256: ${result.sha256}`);
  if (result.response) {
    console.log(`Response: HTTP ${result.response.status} ${result.response.statusText || ''}`.trim());
    if (result.response.dashboardUrl) console.log(`Dashboard URL: ${result.response.dashboardUrl}`);
  }
  if (result.errors?.length) {
    console.log('Errors:');
    for (const error of result.errors) console.log(`- ${error}`);
  }
  const missing = result.request.missingSecretRefs || [];
  if (missing.length) console.log(`Missing env refs: ${missing.join(', ')}`);
  if (result.request.commands?.powershell) {
    console.log('');
    console.log('PowerShell import command:');
    console.log(result.request.commands.powershell);
  }
}

function printTraffic(snapshot) {
  console.log(`BMF traffic: ${snapshot.summary.retained} retained, ${snapshot.summary.dropped} dropped`);
  console.log(`Collected: ${snapshot.collectedAt}`);
  console.log(`Runtime: ${snapshot.paths.runtimeDir || '(not configured)'}`);
  console.log(`Sources: ${snapshot.summary.sources}, parse errors: ${snapshot.summary.parseErrors}, redactions: ${snapshot.summary.redactions}`);
  console.log('');

  if (snapshot.sources?.length) {
    console.log('Sources:');
    for (const source of snapshot.sources) {
      const state = source.exists ? 'found' : 'missing';
      const truncated = source.truncated ? ' truncated' : '';
      console.log(`- ${state}${truncated} ${source.id}: ${source.path || '(not configured)'} records=${source.records}`);
    }
    console.log('');
  }

  if (!snapshot.records?.length) {
    console.log('No traffic records observed.');
    return;
  }

  console.log('Records:');
  for (const record of snapshot.records) {
    const label = record.event || record.command || record.type;
    const status = record.status || 'unknown';
    console.log(`- ${record.timestamp} ${record.type}/${status} ${label} via ${record.transport || 'unknown'} from ${record.source || 'unknown'}`);
  }
}

function printLogs(snapshot) {
  console.log(`BMF logs: ${snapshot.summary.retained} retained, ${snapshot.summary.dropped} dropped`);
  console.log(`Collected: ${snapshot.collectedAt}`);
  console.log(`Runtime: ${snapshot.paths.runtimeDir || '(not configured)'}`);
  console.log(`Sources: ${snapshot.summary.existingSources}/${snapshot.summary.sources}, parse errors: ${snapshot.summary.parseErrors}, redactions: ${snapshot.summary.redactions}`);
  console.log('');

  if (snapshot.sources?.length) {
    console.log('Sources:');
    for (const source of snapshot.sources) {
      const state = source.exists ? 'found' : 'missing';
      const truncated = source.truncated ? ' truncated' : '';
      console.log(`- ${state}${truncated} ${source.id}: ${source.path || '(not configured)'} lines=${source.lines}`);
    }
    console.log('');
  }

  if (!snapshot.records?.length) {
    console.log('No log lines observed.');
    return;
  }

  console.log('Lines:');
  for (const record of snapshot.records) {
    const timestamp = record.timestamp || snapshot.collectedAt;
    const severity = String(record.severity || 'info').toUpperCase().padEnd(7);
    console.log(`- ${timestamp} ${severity} ${record.component}/${record.sourceId}: ${record.message}`);
  }
}

function printServiceAction(action) {
  console.log(`BMF service action: ${action.actionId} ${action.status.toUpperCase()}`);
  console.log(`Mode: ${action.dryRun ? 'dry-run' : 'apply'}`);
  console.log(`Profile: ${action.profile?.name || action.profile?.id || 'unknown'}`);
  console.log(`Backend: ${action.backend}`);
  console.log(`Command: ${action.command?.display || '(not configured)'}`);
  console.log(`CWD: ${action.command?.cwd || '(not configured)'}`);
  console.log(`Log: ${action.paths?.logPath || '(not configured)'}`);
  console.log(`Journal: ${action.paths?.journalPath || '(not configured)'}`);
  console.log(`PID file: ${action.paths?.pidPath || '(not configured)'}`);
  if (action.ownedProcess?.pid) {
    console.log(`Owned PID: ${action.ownedProcess.pid} (${action.ownedProcess.status}, verified=${action.ownedProcess.verified ? 'yes' : 'no'})`);
  }
  console.log(`Readiness: ${action.readiness?.status || 'unknown'} - ${action.readiness?.summary || 'not inspected'}`);
  console.log(
    `Steps: ${action.summary.ready} ready, ${action.summary.blocked} blocked, ${action.summary.warnings} warning(s)`,
  );

  if (action.blockers?.length) {
    console.log('');
    console.log('Blockers:');
    for (const blocker of action.blockers) console.log(`- ${blocker.id}: ${blocker.summary}`);
  }

  if (action.warnings?.length) {
    console.log('');
    console.log('Warnings:');
    for (const warning of action.warnings) console.log(`- ${warning.id}: ${warning.summary}`);
  }

  if (action.process?.pid) {
    console.log('');
    console.log(`Started PID: ${action.process.pid}`);
  }

  if (action.stop) {
    console.log('');
    console.log(`Stop result: ${action.stop.status} PID ${action.stop.pid || 'n/a'} pidFileRemoved=${action.stop.pidFileRemoved ? 'yes' : 'no'}`);
  }
}

function printUpdateCheck(check) {
  const title = check.feature === 'desktop.update.download.plan'
    ? 'BMF Desktop update plan'
    : check.feature === 'desktop.update.download'
    ? 'BMF Desktop update download'
    : check.feature === 'desktop.update.install.plan'
    ? 'BMF Desktop update install plan'
    : check.feature === 'desktop.update.install.handoff'
    ? 'BMF Desktop update install handoff'
    : 'BMF Desktop update';
  console.log(`${title}: ${check.status.toUpperCase()}`);
  console.log(`Current: ${check.currentVersion}`);
  console.log(`Channel: ${check.releaseChannel}`);
  console.log(`Catalog: ${check.catalogPath}`);
  if (check.latest) {
    console.log(`Latest: ${check.latest.version}`);
    console.log(`Artifact: ${check.latest.artifact?.fileName || '(not specified)'}`);
    console.log(`SHA256: ${check.latest.artifact?.sha256 || '(not specified)'}`);
  }
  if (check.artifact?.outputPath) console.log(`Download path: ${check.artifact.outputPath}`);
  if (check.installer?.path) console.log(`Installer: ${check.installer.path}`);
  if (check.command?.display) console.log(`Command: ${check.command.display}`);
  console.log(`Artifact verification: ${check.verification?.status || check.artifactVerification?.status || 'not-checked'}`);
  if (check.installer?.verification?.status) console.log(`Installer verification: ${check.installer.verification.status}`);
  if (check.verification?.path || check.artifactVerification?.path) {
    console.log(`Artifact path: ${check.verification?.path || check.artifactVerification?.path}`);
  }
  if (check.launch?.status) console.log(`Launch: ${check.launch.status}${check.launch.pid ? ` pid=${check.launch.pid}` : ''}`);
  if (check.blockers?.length) {
    console.log('Blockers:');
    for (const blocker of check.blockers) console.log(`- ${blocker.id}: ${blocker.summary}`);
  }
  if (check.steps?.length) {
    console.log('Steps:');
    for (const step of check.steps) console.log(`- ${step.status}: ${step.id} - ${step.summary}`);
  }
  if (check.validation?.errors?.length) {
    console.log('Errors:');
    for (const error of check.validation.errors) console.log(`- ${error}`);
  }
  if (check.nextActions?.length) {
    console.log('Next actions:');
    for (const action of check.nextActions) console.log(`- ${action}`);
  }
}

function printTransaction(transaction) {
  console.log(`BMF transaction: ${transaction.operationId} ${transaction.status.toUpperCase()}`);
  console.log(`Mode: ${transaction.dryRun ? 'dry-run' : 'apply'}`);
  console.log(`Profile: ${transaction.profile?.name || transaction.profile?.id || 'unknown'}`);
  console.log(`Journal: ${transaction.journalPath}`);
  console.log(`Backup root: ${transaction.backupRoot}`);
  console.log(
    `Steps: ${transaction.summary.ready} ready, ${transaction.summary.blocked} blocked, ${transaction.summary.skipped} skipped, ${transaction.summary.unsupported} unsupported action(s)`,
  );
  console.log('');

  for (const step of transaction.steps || []) {
    const target = step.targetPath ? ` -> ${step.targetPath}` : '';
    const source = step.sourcePath ? ` from ${step.sourcePath}` : '';
    console.log(`- ${step.status.padEnd(7)} ${step.id} (${step.kind})${source}${target}`);
    if (step.blockedReason) console.log(`  blocked: ${step.blockedReason}`);
    if (step.backupRequired) console.log('  backup: required before overwrite');
    if (step.backupPath) console.log(`  backup: ${step.backupPath}`);
  }

  if (transaction.unsupportedActions?.length) {
    console.log('');
    console.log('Unsupported actions:');
    for (const action of transaction.unsupportedActions) {
      console.log(`- ${action.actionId}: ${action.reason}`);
    }
  }

  if (transaction.rollback?.length) {
    console.log('');
    console.log(`Rollback instructions: ${transaction.rollback.length}`);
  }

  if (transaction.errors?.length) {
    console.log('');
    console.log('Errors:');
    for (const error of transaction.errors) {
      console.log(`- ${error.stepId}: ${error.message}`);
    }
  }
}

function printRollback(rollback) {
  console.log(`BMF rollback: ${rollback.sourceTransactionId || rollback.operationId || 'transaction'} ${rollback.status.toUpperCase()}`);
  console.log(`Mode: ${rollback.dryRun ? 'dry-run' : 'apply'}`);
  console.log(`Source journal: ${rollback.sourceJournalPath}`);
  console.log(`Rollback journal: ${rollback.journalPath}`);
  console.log(`Rollback backup root: ${rollback.backupRoot}`);
  console.log(
    `Steps: ${rollback.summary.ready} ready, ${rollback.summary.blocked} blocked, ${rollback.summary.restores} restore(s), ${rollback.summary.removals} removal(s)`,
  );
  console.log('');

  for (const step of rollback.steps || []) {
    const backup = step.backupPath ? ` from ${step.backupPath}` : '';
    const target = step.targetPath ? ` -> ${step.targetPath}` : '';
    console.log(`- ${step.status.padEnd(7)} ${step.id} (${step.action})${backup}${target}`);
    if (step.blockedReason) console.log(`  blocked: ${step.blockedReason}`);
    if (step.backupRequired) console.log('  backup: current target will be preserved before rollback');
    if (step.rollbackBackupPath) console.log(`  rollback backup: ${step.rollbackBackupPath}`);
  }

  if (rollback.errors?.length) {
    console.log('');
    console.log('Errors:');
    for (const error of rollback.errors) {
      console.log(`- ${error.stepId}: ${error.message}`);
    }
  }
}

module.exports = {
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
};
