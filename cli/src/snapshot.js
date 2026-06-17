const path = require('node:path');
const { writeTroubleshootingSnapshot } = require('../../packages/orchestrator-core/src');
const { publicContext, resolveContext } = require('./context');
const { safeRelative, timestamp, writeJson, writeText } = require('./file');
const { runDoctor } = require('./doctor');
const { profileFromContext } = require('./orchestrator');

function createSnapshot(options = {}) {
  const ctx = resolveContext(options);
  const profile = profileFromContext(ctx, options);
  const snapshotRoot = options.snapshotRoot || process.env.BMF_SNAPSHOT_ROOT;
  const outRoot = options.out
    ? path.resolve(options.out)
    : path.join(snapshotRoot ? path.resolve(snapshotRoot) : path.join(ctx.bmfRoot, 'artifacts', 'bmfctl', 'snapshots'), timestamp());
  const doctor = runDoctor(options);

  const coreSnapshot = writeTroubleshootingSnapshot({ profile }, {
    root: ctx.bmfRoot,
    out: outRoot,
    confirm: 'snapshot',
    doctorReport: doctor,
    maxLogLines: options.maxLogLines || options.maxLines || options.limit,
    maxLogBytes: options.maxLogBytes || options.maxBytes,
    maxFiles: options.maxFiles,
    maxTrafficRecords: options.maxTrafficRecords || options.maxRecords || options.limit,
    maxCommandFiles: options.maxCommandFiles,
    anonymizePlayers: Boolean(options.anonymizePlayers),
    redactPrivateIps: Boolean(options.redactPrivateIps),
  });

  const snapshot = {
    ...coreSnapshot,
    tool: 'bmfctl',
    command: 'snapshot',
    context: publicContext(ctx),
    doctor: {
      status: doctor.status,
      summary: doctor.summary,
      findings: doctor.findings,
    },
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
      `Health status: ${snapshot.summary.healthStatus}`,
      '',
      'Files are bounded and redacted before export. Logs are tailed, not copied in full.',
      'No BMF commands or game-server probes were sent to create this snapshot.',
      `Relative root: ${safeRelative(ctx.bmfRoot, outRoot)}`,
      '',
    ].join('\n'),
  );

  return snapshot;
}

module.exports = {
  createSnapshot,
};
