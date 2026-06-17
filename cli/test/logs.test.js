const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const { makeEnvironment, write } = require('./helpers');
const { createLogReport } = require('../src/orchestrator');

test('bmfctl logs returns bounded redacted runtime and transaction lines', () => {
  const env = makeEnvironment();
  const runtimeDir = path.join(env.liveMods, 'BMF', 'runtime');
  const journalRoot = path.join(env.bmfRoot, 'artifacts', 'local', 'transactions');

  write(
    path.join(runtimeDir, 'bmf.log'),
    [
      '2026-06-16T12:00:00Z INFO BMF started token=runtime-token',
      '2026-06-16T12:01:00Z WARN port retry apiKey=runtime-api-key',
    ].join('\n') + '\n',
  );
  write(
    path.join(runtimeDir, 'audit.jsonl'),
    JSON.stringify({
      ts: '2026-06-16T12:02:00Z',
      action: 'command.dispatch',
      data: {
        command: 'bmf.status password=audit-password',
      },
    }) + '\n',
  );
  write(
    path.join(journalRoot, 'install-stack.json'),
    JSON.stringify({
      transactionId: 'install-stack',
      operationId: 'install-stack',
      status: 'applied',
      createdAt: '2026-06-16T12:03:00Z',
      summary: { ready: 2, blocked: 0 },
      errors: [],
    }),
  );

  const snapshot = createLogReport({
    ...env.options,
    limit: 10,
    journalRoot,
  });

  assert.equal(snapshot.summary.retained, 4);
  assert.ok(snapshot.sources.some(source => source.id === 'bmf-log' && source.lines === 2));
  assert.ok(snapshot.sources.some(source => source.id === 'audit-jsonl' && source.lines === 1));
  assert.ok(snapshot.records.some(record => record.sourceId.startsWith('transaction-journal:')));
  assert.equal(JSON.stringify(snapshot).includes('runtime-token'), false);
  assert.equal(JSON.stringify(snapshot).includes('runtime-api-key'), false);
  assert.equal(JSON.stringify(snapshot).includes('audit-password'), false);
  assert.ok(snapshot.guardrails.includes('read-existing-log-files-only'));
});
