const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createSnapshot } = require('../src/snapshot');

test('snapshot writes doctor output and copied diagnostics', () => {
  const env = makeEnvironment();
  write(path.join(env.omeggaDir, 'run-omegga-test.log'), 'line 1\nline 2\n');
  const out = path.join(env.root, 'snapshot');
  const snapshot = createSnapshot({ ...env.options, out });

  assert.equal(snapshot.root, out);
  assert.ok(fs.existsSync(path.join(out, 'snapshot.json')));
  assert.ok(fs.existsSync(path.join(out, 'doctor.json')));
  assert.ok(snapshot.copiedFiles.length > 0);
  assert.ok(snapshot.copiedLogs.length > 0);
});

test('snapshot uses BMF_SNAPSHOT_ROOT when --out is not provided', () => {
  const env = makeEnvironment();
  const previous = process.env.BMF_SNAPSHOT_ROOT;
  const snapshotRoot = path.join(env.root, 'appdata', 'snapshots');
  process.env.BMF_SNAPSHOT_ROOT = snapshotRoot;
  try {
    const snapshot = createSnapshot(env.options);

    assert.equal(path.dirname(snapshot.root), snapshotRoot);
    assert.ok(fs.existsSync(path.join(snapshot.root, 'snapshot.json')));
    assert.ok(fs.existsSync(path.join(snapshot.root, 'doctor.json')));
  } finally {
    if (previous === undefined) delete process.env.BMF_SNAPSHOT_ROOT;
    else process.env.BMF_SNAPSHOT_ROOT = previous;
  }
});
