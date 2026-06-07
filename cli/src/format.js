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

module.exports = {
  printDoctor,
  printJson,
  printMods,
  printRepair,
  printRepairAll,
  printSnapshot,
};
