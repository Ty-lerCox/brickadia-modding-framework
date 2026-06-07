const path = require('node:path');
const fs = require('node:fs');
const { publicContext, resolveContext } = require('./context');
const {
  ensureDir,
  exists,
  isDirectory,
  listFilesRecursive,
  readText,
  safeRelative,
  tailFile,
  timestamp,
  writeJson,
  writeText,
} = require('./file');
const { runDoctor } = require('./doctor');

function safeSnapshotName(label) {
  return String(label || 'file').replace(/^[A-Za-z]:/, '').replace(/[\\/:"*?<>|]+/g, '__');
}

function writeFileCopy(snapshotRoot, sourcePath, contents, record) {
  if (!exists(sourcePath)) return;
  const relative = path.join('files', safeSnapshotName(sourcePath));
  const destination = path.join(snapshotRoot, relative);
  ensureDir(path.dirname(destination));
  writeText(destination, contents ?? readText(sourcePath));
  record.push({
    source: sourcePath,
    snapshotPath: relative.replace(/\\/g, '/'),
  });
}

function collectKnownFiles(ctx, snapshotRoot) {
  const copied = [];
  const files = [
    path.join(ctx.bmfRoot, 'manifests', 'bmf-package.json'),
    path.join(ctx.bmfRoot, 'manifests', 'dependencies.json'),
    path.join(ctx.bmfRoot, 'manifests', 'compatibility.json'),
    path.join(ctx.bmfSourceDir, 'bmf.json'),
    path.join(ctx.bmfSourceDir, 'config.json'),
    path.join(ctx.omeggaDir, 'package.json'),
    path.join(ctx.omeggaTemplateModsDir, 'mods.txt'),
    path.join(ctx.omeggaTemplateModsDir, 'mods.json'),
    path.join(ctx.omeggaTemplateBmfDir, 'bmf.json'),
    path.join(ctx.omeggaTemplateBmfDir, 'config.json'),
  ];

  for (const modsDir of ctx.liveModsDirs) {
    files.push(path.join(modsDir, 'mods.txt'));
    files.push(path.join(modsDir, 'mods.json'));
    files.push(path.join(modsDir, 'BMF', 'bmf.json'));
    files.push(path.join(modsDir, 'BMF', 'config.json'));
  }

  if (isDirectory(ctx.compatibilityRoot)) {
    files.push(
      ...listFilesRecursive(ctx.compatibilityRoot, filepath => {
        return ['manifest.json', 'validation-report.json', 'validation-report.md'].includes(
          path.basename(filepath),
        );
      }),
    );
  }

  for (const file of Array.from(new Set(files))) {
    writeFileCopy(snapshotRoot, file, null, copied);
  }

  return copied;
}

function collectLogs(ctx, snapshotRoot) {
  const copied = [];
  const logCandidates = [];
  if (isDirectory(ctx.omeggaDir)) {
    for (const entry of fs.readdirSync(ctx.omeggaDir, { withFileTypes: true })) {
      const basename = entry.name.toLowerCase();
      if (entry.isFile() && basename.endsWith('.log')) {
        logCandidates.push(path.join(ctx.omeggaDir, entry.name));
      }
    }
  }
  if (ctx.gameWin64Dir) {
    logCandidates.push(
      ...listFilesRecursive(path.join(ctx.gameWin64Dir, 'ue4ss'), filepath => {
        return path.basename(filepath).toLowerCase().endsWith('.log');
      }),
    );
  }
  if (ctx.savedDir) {
    const brickadiaLog = path.join(ctx.savedDir, 'Logs', 'Brickadia.log');
    if (exists(brickadiaLog)) logCandidates.push(brickadiaLog);
  }
  for (const dir of ctx.bridgeRuntimeDirs) {
    logCandidates.push(
      ...listFilesRecursive(dir, filepath => path.basename(filepath).toLowerCase().endsWith('.log')),
    );
  }

  for (const file of Array.from(new Set(logCandidates)).slice(-25)) {
    const relative = path.join('logs', `${safeSnapshotName(file)}.tail.log`);
    const destination = path.join(snapshotRoot, relative);
    ensureDir(path.dirname(destination));
    writeText(destination, tailFile(file, 300));
    copied.push({
      source: file,
      snapshotPath: relative.replace(/\\/g, '/'),
      mode: 'tail',
      lines: 300,
    });
  }

  return copied;
}

function createSnapshot(options = {}) {
  const ctx = resolveContext(options);
  const outRoot = options.out
    ? path.resolve(options.out)
    : path.join(ctx.bmfRoot, 'artifacts', 'bmfctl', 'snapshots', timestamp());
  ensureDir(outRoot);

  const doctor = runDoctor(options);
  const copiedFiles = collectKnownFiles(ctx, outRoot);
  const copiedLogs = collectLogs(ctx, outRoot);
  const snapshot = {
    tool: 'bmfctl',
    command: 'snapshot',
    createdAt: new Date().toISOString(),
    root: outRoot,
    context: publicContext(ctx),
    doctor: {
      status: doctor.status,
      summary: doctor.summary,
      findings: doctor.findings,
    },
    copiedFiles,
    copiedLogs,
  };

  writeJson(path.join(outRoot, 'snapshot.json'), snapshot);
  writeJson(path.join(outRoot, 'doctor.json'), doctor);
  writeText(
    path.join(outRoot, 'README.txt'),
    [
      'BMF troubleshooting snapshot',
      '',
      `Created: ${snapshot.createdAt}`,
      `Doctor status: ${doctor.status}`,
      '',
      'Files are intentionally copied as diagnostics. Logs are tailed, not copied in full.',
      `Relative root: ${safeRelative(ctx.bmfRoot, outRoot)}`,
      '',
    ].join('\n'),
  );

  return snapshot;
}

module.exports = {
  createSnapshot,
};
