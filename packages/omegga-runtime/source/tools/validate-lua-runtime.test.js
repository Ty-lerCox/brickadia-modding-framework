'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { validateLuaSource } = require('./validate-lua-runtime');

function findingSignatures(source) {
  return validateLuaSource(source, '<test>').unsafeSchedulerFindings.map(
    finding => `${finding.invocation}:${finding.primitive}`,
  );
}

test('Lua 5.3 compiler rejects a chunk with more than 200 locals', () => {
  const source = Array.from(
    { length: 201 },
    (_, index) => `local local_${index} = ${index}`,
  ).join('\n');
  const result = validateLuaSource(source, 'too-many-locals.lua');

  assert.equal(result.compilerPassed, false);
  assert.equal(
    result.astPassed,
    true,
    'AST parsing alone must not satisfy the gate',
  );
  assert.match(
    result.compilerError,
    /too many local variables \(limit is 200\)/,
  );
});

test('scheduler scan catches direct, pcall, alias, indexed, and broad-clear use', () => {
  const cases = [
    ['ExecuteAsync(function() end)', 'direct:ExecuteAsync'],
    ['pcall(LoopAsync, 10, function() end)', 'pcall:LoopAsync'],
    [
      'local schedule = ExecuteWithDelay; schedule(10, function() end)',
      'alias-reference:ExecuteWithDelay',
    ],
    ["local schedule = _G['ExecuteAsync']", '_G-index-reference:ExecuteAsync'],
    ['local schedule = _G["LoopAsync"]', '_G-index-reference:LoopAsync'],
    ['ClearAllDelayedActions()', 'direct:ClearAllDelayedActions'],
  ];

  for (const [source, expected] of cases) {
    assert.ok(
      findingSignatures(source).includes(expected),
      `${source} should produce ${expected}`,
    );
  }
});

test('scheduler policy keys and documentation strings are not calls', () => {
  const result = validateLuaSource(
    [
      'local blocked = {',
      '  ExecuteAsync = true,',
      '  ClearAllDelayedActions = true,',
      '}',
      'local documentation = { "ExecuteWithDelay", "LoopAsync" }',
      'return blocked, documentation',
    ].join('\n'),
    'safe-policy.lua',
  );

  assert.equal(result.syntaxPassed, true);
  assert.deepEqual(result.unsafeSchedulerFindings, []);
});

test('typed chat resolution refuses stale cached command contexts', () => {
  const bridgePath = path.join(
    __dirname,
    '..',
    'templates',
    'windows-ue4ss',
    'ue4ss',
    'Mods',
    'OmeggaBridge',
    'Scripts',
    'main.lua',
  );
  const source = fs.readFileSync(bridgePath, 'utf8');
  const start = source.indexOf('local function get_chat_broadcast_objects()');
  const end = source.indexOf('local function get_object_label', start);

  assert.notEqual(start, -1, 'typed chat resolver must exist');
  assert.notEqual(end, -1, 'typed chat resolver boundary must exist');

  const resolver = source.slice(start, end);
  assert.doesNotMatch(resolver, /get_cached_game_objects\s*\(/);
  assert.doesNotMatch(resolver, /get_cached_command_context\s*\(/);
  assert.doesNotMatch(resolver, /remember_object_world\s*\(/);
  assert.doesNotMatch(resolver, /:\s*GetWorld\s*\(/);
  assert.match(resolver, /find_first_valid\("GameModeBase"\)/);
  assert.match(resolver, /find_first_valid\("GameStateBase"\)/);
  assert.match(resolver, /Typed chat refused stale cached command context/);

  const runtimeContextStart = source.indexOf(
    'local function build_chat_runtime_context',
  );
  const runtimeContextEnd = source.indexOf(
    'local function collect_chat_sources',
    runtimeContextStart,
  );
  assert.notEqual(runtimeContextStart, -1, 'chat runtime context must exist');
  assert.notEqual(
    runtimeContextEnd,
    -1,
    'chat runtime context boundary must exist',
  );
  const runtimeContext = source.slice(runtimeContextStart, runtimeContextEnd);
  assert.doesNotMatch(runtimeContext, /get_cached_command_context\s*\(/);

  const fastSourcesStart = source.indexOf(
    'local function build_fast_chat_sources',
  );
  const fastSourcesEnd = source.indexOf(
    'local function build_fast_chat_call_by_name_commands',
    fastSourcesStart,
  );
  assert.notEqual(fastSourcesStart, -1, 'fast chat source builder must exist');
  assert.notEqual(fastSourcesEnd, -1, 'fast chat source boundary must exist');
  const fastSources = source.slice(fastSourcesStart, fastSourcesEnd);
  assert.doesNotMatch(fastSources, /get_cached_command_context\s*\(/);
});

test('socket pump enforces the elapsed budget only between completed envelopes', () => {
  const runtimePath = path.join(
    __dirname,
    '..',
    'templates',
    'windows-ue4ss',
    'ue4ss',
    'Mods',
    'BMF',
    'Scripts',
    'bmf',
    'runtime.lua',
  );
  const source = fs.readFileSync(runtimePath, 'utf8');
  const drainStart = source.indexOf('function BMF_drain_socket_messages(');
  const drainEnd = source.indexOf(
    'function BMF_schedule_socket_worker_poll',
    drainStart,
  );

  assert.notEqual(drainStart, -1, 'socket drain must exist');
  assert.notEqual(drainEnd, -1, 'socket drain boundary must exist');
  assert.doesNotMatch(
    source,
    /BMF_drain_socket_messages\(\s*\d+/,
    'no socket drain caller may supply a literal or legacy unbounded batch',
  );
  assert.doesNotMatch(
    source,
    /pcall\(BMF_drain_socket_messages/,
    'the file-command worker must not compete with the primary socket pump',
  );
  assert.equal(
    source.match(/BMF_drain_socket_messages\(/g)?.length,
    3,
    'only the function definition and two bounded primary pump callers may exist',
  );
  assert.match(
    source,
    /BMF_GAME_THREAD_PUMP_BUDGET_ENFORCED[\s\S]*?true\)/,
    'elapsed-time enforcement must have an explicit default-on rollback flag',
  );

  const drain = source.slice(drainStart, drainEnd);
  assert.match(
    drain,
    /direct_ingress_cap_enabled == true[\s\S]*?requested_count = math\.min\([\s\S]*?effective_ingress_per_pump/,
    'the count cap must remain an independent admission bound',
  );
  assert.match(
    drain,
    /budget_enforced == true[\s\S]*?receive_limit = math\.min\(1, receive_limit\)/,
    'enforced pumps must dequeue at most one indivisible envelope at a time',
  );
  assert.match(
    drain,
    /if scheduler\.budget_enforced ~= true then\s+break\s+end/,
    'disabling enforcement must restore one bounded bulk receive',
  );
  assert.match(
    source,
    /function BMF_socket_scheduler_budget_exhausted_for_admission\([\s\S]*?if scheduler\.budget_enforced ~= true then\s+return false/,
    'the rollback flag must disable elapsed-time admission checks everywhere',
  );
  const processIndex = drain.indexOf('pcall(BMF_process_socket_message, line)');
  const budgetCheckIndex = drain.indexOf(
    'BMF_socket_scheduler_budget_exhausted_for_admission',
  );
  assert.notEqual(processIndex, -1, 'socket envelope processing must exist');
  assert.ok(
    budgetCheckIndex > processIndex,
    'the elapsed budget must be checked after the current envelope completes',
  );
  assert.match(
    drain,
    /return drained \+ native_drained, drained, direct_admitted, budget_admission_stopped/,
  );

  assert.equal(
    source.match(/budget_tunnel_dispatch_skipped = true/g)?.length,
    2,
    'both socket pump modes must expose budget-skipped tunnel dispatches',
  );
  assert.equal(
    source.match(
      /BMF_drain_socket_messages\(\s*(?:state\.telemetry\.socket_scheduler\.effective_ingress_per_pump|ingress_per_tick),\s*pump_started_clock\)/g,
    )?.length,
    2,
    'both socket pump modes must share the full-pump elapsed-time origin',
  );
  assert.match(
    source,
    /budget_elapsed_ms > \(tonumber\(scheduler\.budget_ms\) or 3\)/,
    'an indivisible operation overrun must use its exact elapsed duration',
  );
});
