'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const {
  validateLuaFile,
  validateLuaSource,
} = require('./validate-lua-runtime');

function findingSignatures(source) {
  return validateLuaSource(source, '<test>').unsafeSchedulerFindings.map(
    finding => `${finding.invocation}:${finding.primitive}`,
  );
}

test('Lua 5.3 compiler rejects a chunk with more than 200 locals', () => {
  const fixture = path.join(
    __dirname,
    'fixtures',
    'lua53-main-chunk-201-locals.lua',
  );
  const result = validateLuaFile(fixture);

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
  assert.equal(result.mainChunkLocalCount, 201);
});

test('Lua 5.3 compiler accepts the supported 200-local boundary', () => {
  const fixture = path.join(
    __dirname,
    'fixtures',
    'lua53-main-chunk-200-locals.lua',
  );
  const result = validateLuaFile(fixture);

  assert.equal(result.compilerPassed, true, result.compilerError);
  assert.equal(result.syntaxPassed, true, result.syntaxError);
  assert.equal(result.mainChunkLocalCount, 200);
});

test('exact canonical and packaged BMF runtimes compile at unchanged local count', () => {
  const canonical = path.resolve(
    __dirname,
    '..',
    '..',
    '..',
    '..',
    'framework',
    'ue4ss',
    'Mods',
    'BMF',
    'Scripts',
    'bmf',
    'runtime.lua',
  );
  const packaged = path.resolve(
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

  assert.deepEqual(fs.readFileSync(canonical), fs.readFileSync(packaged));
  for (const runtimePath of [canonical, packaged]) {
    const result = validateLuaFile(runtimePath);
    assert.equal(result.compilerPassed, true, result.compilerError);
    assert.equal(result.syntaxPassed, true, result.syntaxError);
    assert.equal(
      result.mainChunkLocalCount,
      200,
      `${runtimePath} must not add a top-level local`,
    );
  }
});

test('idle socket backoff reuses the existing scheduler and stays bounded', () => {
  const runtimePath = path.resolve(
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
  const result = validateLuaFile(runtimePath);
  const updateStart = source.indexOf(
    'function BMF_socket_scheduler_update_idle_backoff(',
  );
  const updateEnd = source.indexOf(
    'function BMF_schedule_socket_worker_poll',
    updateStart,
  );
  const update = source.slice(updateStart, updateEnd);

  assert.equal(result.mainChunkLocalCount, 200);
  assert.notEqual(updateStart, -1, 'idle backoff update must exist');
  assert.notEqual(updateEnd, -1, 'idle backoff boundary must exist');
  assert.match(update, /recent_work_passes_remaining = 4/);
  assert.match(update, /next_interval = 25/);
  assert.match(
    update,
    /consecutive_empty_passes <= 6[\s\S]*?next_interval = 50/,
  );
  assert.match(
    update,
    /else[\s\S]*?next_tier = "deep_idle"[\s\S]*?next_interval = 100/,
  );
  assert.match(update, /work_wakeups_total/);
  assert.match(update, /backoff_transitions_total/);
  assert.match(
    source,
    /BMF_socket_scheduler_update_idle_backoff\([\s\S]*?BMF_socket_scheduler_total_depth\(\) > 0\)/,
  );
  assert.match(
    source,
    /BMF_schedule_socket_worker_poll\(\s*state\.telemetry\.socket_scheduler\.current_poll_interval_ms/,
  );
  assert.doesNotMatch(update, /local\s+function\s+/);
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

test('OmeggaBridge does not retain typed-chat UObjects across frames', () => {
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

  assert.doesNotMatch(
    source,
    /local\s+last_hook_(?:context|world|executor|game_mode|game_state|game_session)\s*=/,
    'hook callbacks must not retain raw UObjects in Lua locals',
  );
  assert.doesNotMatch(
    source,
    /\blast_hook_(?:context|world|executor|game_mode|game_state|game_session)\s*=/,
    'hook callbacks must not assign raw UObjects for later frames',
  );
  assert.doesNotMatch(source, /local\s+observed_chat_context\s*=/);
  assert.doesNotMatch(source, /\bobserved_chat_context\s*=/);
  assert.doesNotMatch(
    source,
    /is_valid_object\s*\(\s*(?:last_hook_|observed_chat_context)/,
    'IsValid must never run against a previously retained typed-chat UObject',
  );

  assert.match(source, /CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET\s*=\s*nil/);
  assert.match(source, /CHAT_WHISPER_LAST_PLAYER_SOURCE\s*=\s*nil/);
  assert.match(source, /CHAT_WHISPER_LAST_TARGET_KEY\s*=\s*nil/);
  assert.doesNotMatch(source, /get_cached_chat_whisper_player_source/);
  assert.doesNotMatch(source, /remember_chat_whisper_player_source/);
  assert.doesNotMatch(source, /clone_fast_chat_player_source/);
  assert.doesNotMatch(source, /normalize_chat_whisper_target_key/);

  const cachedContextStart = source.indexOf(
    'local function get_cached_command_context()',
  );
  const cachedContextEnd = source.indexOf(
    'local function get_cached_world()',
    cachedContextStart,
  );
  assert.notEqual(cachedContextStart, -1, 'cached context guard must exist');
  assert.notEqual(
    cachedContextEnd,
    -1,
    'cached context guard boundary must exist',
  );
  const cachedContextGuard = source.slice(cachedContextStart, cachedContextEnd);
  assert.doesNotMatch(cachedContextGuard, /OmeggaGetCachedCommandContext/);
  assert.match(
    cachedContextGuard,
    /Cross-frame cached command contexts are disabled/,
  );

  const resolverStart = source.indexOf(
    'local function get_chat_broadcast_objects()',
  );
  const resolverEnd = source.indexOf(
    'local function get_object_label',
    resolverStart,
  );
  const resolver = source.slice(resolverStart, resolverEnd);
  assert.doesNotMatch(resolver, /last_hook_|observed_chat_context/);
  assert.match(resolver, /cross-frame UObject caches disabled/);
  assert.match(resolver, /pcall\(UEHelpers\.GetWorld\)/);
});

test('prefab capture retains only inert snapshots and reacquires replay contexts', () => {
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

  const captureStart = source.indexOf(
    'function OmeggaRecordPrefabNativeCapture(',
  );
  const captureEnd = source.indexOf(
    'function OmeggaAddPrefabHookCandidate(',
    captureStart,
  );
  assert.ok(captureStart >= 0 && captureEnd > captureStart);
  const capture = source.slice(captureStart, captureEnd);
  assert.doesNotMatch(
    capture,
    /record\.context\s*=\s*(?!nil\b)/,
    'callback-owned contexts must never enter a persistent capture record',
  );
  assert.doesNotMatch(
    capture,
    /^\s*(?:raw|resolved|context)\s*=\s*(?:raw|resolved|context(?:_object)?)\b/m,
    'raw, resolved, and context wrappers must not be copied into record fields',
  );
  assert.match(capture, /context_label = "nil"/);
  assert.match(capture, /context_retained=false/);
  assert.match(capture, /resolver = resolver,[\s\S]*?memory = memory,/);

  const sanitizerStart = source.indexOf(
    'function OmeggaSanitizePrefabNativeCaptureRecord(',
  );
  const sanitizerEnd = source.indexOf(
    'OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS',
    sanitizerStart,
  );
  assert.ok(sanitizerStart >= 0 && sanitizerEnd > sanitizerStart);
  const sanitizer = source.slice(sanitizerStart, sanitizerEnd);
  assert.match(sanitizer, /record\.context = nil/);
  assert.match(sanitizer, /argument\.raw = nil/);
  assert.match(sanitizer, /argument\.resolved = nil/);
  assert.doesNotMatch(
    sanitizer,
    /IsValid|GetWorld|ProcessEvent/,
    'legacy wrapper cleanup must drop references without touching UObjects',
  );

  const pasteResolverStart = source.indexOf(
    'function OmeggaFindServerPastePrefabContext()',
  );
  const pasteResolverEnd = source.indexOf(
    'function OmeggaAppendPrefabPlayerContextDiagnostics(',
    pasteResolverStart,
  );
  const pasteResolver = source.slice(pasteResolverStart, pasteResolverEnd);
  assert.doesNotMatch(pasteResolver, /record\.context|state\.last/);
  assert.match(pasteResolver, /OmeggaGetPrefabContextPlayerStates\(\)/);
  assert.match(pasteResolver, /find_first_valid\(class_name\)/);

  const placeResolverStart = source.indexOf(
    'function OmeggaFindServerPlaceCurrentPrefabContext()',
  );
  const placeResolverEnd = source.indexOf(
    'function OmeggaDescribePrefabPlacementContext()',
    placeResolverStart,
  );
  const placeResolver = source.slice(placeResolverStart, placeResolverEnd);
  assert.doesNotMatch(placeResolver, /record\.context|state\.last/);
  assert.match(
    placeResolver,
    /OmeggaFindRawServerPlaceCurrentPrefabContext\(\)/,
  );
  assert.match(placeResolver, /OmeggaFindServerPastePrefabContext\(\)/);

  const replayStart = source.indexOf(
    'function OmeggaReplayLastPrefabNativeCapture(',
  );
  const replayEnd = source.indexOf(
    'function OmeggaSelfTestPrefabNativeReplayBuffer()',
    replayStart,
  );
  assert.ok(replayStart >= 0 && replayEnd > replayStart);
  const replay = source.slice(replayStart, replayEnd);
  assert.doesNotMatch(replay, /record\.context\b/);
  assert.doesNotMatch(
    replay,
    /(?:is_valid_object|get_object_label)\s*\(\s*(?:candidate\.)?record\.context\b/,
  );
  assert.doesNotMatch(
    replay,
    /OmeggaUnsafeProcessEventWithParamBytes\s*,\s*(?:candidate\.)?record\./,
  );
  assert.match(replay, /OmeggaFindServerPlaceCurrentPrefabContext\(\)/);
  assert.match(replay, /OmeggaFindServerPastePrefabContext\(\)/);
  assert.match(
    replay,
    /pcall\(OmeggaUnsafeProcessEventWithParamBytes, context, function_name, buffer_hex\)/,
  );
  assert.ok(
    replay.indexOf('OmeggaBuildPrefabNativeReplayBuffer(record, spec)') <
      replay.indexOf('OmeggaFindServerPastePrefabContext()'),
    'the byte buffer must be built before acquiring the short-lived live context',
  );

  assert.doesNotMatch(
    source,
    /is_valid_object\s*\(\s*(?:candidate\.)?record\.context/,
  );
  assert.doesNotMatch(
    source,
    /OmeggaUnsafeProcessEventWithParamBytes\s*,\s*(?:candidate\.)?record\.context/,
  );
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

test('native tree and zone drains share the socket-pump budget in one-event units', () => {
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

  assert.match(
    source,
    /BMF_SOCKET_NATIVE_DRAIN_BUDGET_ENABLED[\s\S]*?true\)/,
    'budgeted native drains must be default-on with an explicit rollback flag',
  );
  assert.match(
    source,
    /function BMF_socket_native_drain_budget_exhausted\([\s\S]*?native_drains\.budget_enabled ~= true[\s\S]*?BMF_telemetry_duration_ms\(started\) >= \(tonumber\(scheduler\.budget_ms\) or 3\)/,
    'native drains must use the same full-pump elapsed origin and budget',
  );

  const oneStart = source.indexOf('function BMF_socket_native_drain_one(');
  const oneEnd = source.indexOf(
    'function BMF_socket_native_drain_budgeted(',
    oneStart,
  );
  assert.notEqual(oneStart, -1, 'one-event native drain helper must exist');
  assert.notEqual(oneEnd, -1, 'one-event native drain boundary must exist');
  const one = source.slice(oneStart, oneEnd);
  assert.match(one, /BMF_tree_cut_native_drain_raw\(1\)/);
  assert.match(one, /BMF_zone_native_drain_raw\(1\)/);
  assert.ok(
    one.indexOf('BMF_socket_native_drain_budget_exhausted') <
      one.indexOf('BMF_tree_cut_native_drain_raw(1)'),
    'the budget must be checked before removing an individual native event',
  );
  assert.ok(
    one.lastIndexOf('BMF_socket_native_drain_budget_exhausted') >
      one.indexOf('BMF_tree_cut_native_emit_raw'),
    'the budget must be checked after the indivisible callback completes',
  );
  assert.match(
    one,
    /native_drains\.attempted[\s\S]*?native_drains\.drained[\s\S]*?native_drains\.overruns/,
  );

  const boundedStart = source.indexOf(
    'function BMF_socket_native_drain_budgeted(',
  );
  const boundedEnd = source.indexOf(
    'function BMF_drain_socket_messages(',
    boundedStart,
  );
  const bounded = source.slice(boundedStart, boundedEnd);
  assert.match(bounded, /max_events_per_pump\) or 4/);
  assert.match(bounded, /BMF_socket_native_drain_mark_skipped\("tree"\)/);
  assert.match(bounded, /BMF_socket_native_drain_mark_skipped\("zone"\)/);
  assert.match(bounded, /native_drains\.next_source = next_source/);

  const drainStart = source.indexOf('function BMF_drain_socket_messages(');
  const drainEnd = source.indexOf(
    'function BMF_schedule_socket_worker_poll',
    drainStart,
  );
  const drain = source.slice(drainStart, drainEnd);
  const enabledStart = drain.indexOf(
    'if scheduler.native_drains.budget_enabled == true then',
  );
  const rollbackStart = drain.indexOf('else', enabledStart);
  assert.notEqual(
    enabledStart,
    -1,
    'socket pump must select bounded native drains',
  );
  assert.notEqual(rollbackStart, -1, 'native drain rollback branch must exist');
  assert.doesNotMatch(
    drain.slice(enabledStart, rollbackStart),
    /limit = 64/,
    'the enabled path must not retain the post-budget 64-event burst',
  );
  assert.equal(
    drain.slice(rollbackStart).match(/limit = 64/g)?.length,
    2,
    'flag-off rollback must preserve the Phase 1.5 tree and zone drain limits',
  );
  assert.match(
    drain,
    /BMF_socket_native_drain_budgeted\(admission_started_clock\)/,
  );
  assert.match(
    drain,
    /budget_admission_stopped = budget_admission_stopped or native_budget_stopped == true/,
  );

  assert.match(
    source,
    /native_drains = \{[\s\S]*?attempted = 0[\s\S]*?drained = 0[\s\S]*?skipped = 0[\s\S]*?overruns = 0[\s\S]*?depth = -1[\s\S]*?depth_available = false/,
    'native drain telemetry must use fixed tree and zone records with depth availability',
  );
  assert.match(
    source,
    /function BMF\.tools\.treeCutNative\.drain\(options\)[\s\S]*?options\.limit or options\.max or 64/,
    'manual tree drain behavior must remain unchanged',
  );
  assert.match(
    source,
    /function BMF\.tools\.zoneNative\.drain\(options\)[\s\S]*?options\.limit or options\.max or 64/,
    'manual zone drain behavior must remain unchanged',
  );
  assert.match(
    source,
    /function BMF_zone_native_should_drain\(\)[\s\S]*?zone_process_trace[\s\S]*?enabled == true/,
    'zone process tracing must keep the bounded native drain active',
  );
});

test('unified socket admission owns direct and tunnel dispatch with bounded weighted fairness', () => {
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

  assert.match(
    source,
    /BMF_UNIFIED_SOCKET_ADMISSION_ENABLED[\s\S]*?true\)/,
    'unified admission must be default-on with an explicit rollback flag',
  );
  assert.match(
    source,
    /if state\.socket_admission\.enabled == true then\s+state\.socket\.received_commands[\s\S]*?BMF_socket_scheduler_admit_direct\(decoded\)\s+end[\s\S]*?BMF_dispatch_bmf_command_text/,
    'enabled direct commands must enqueue before the flag-off Phase 1.5 inline path',
  );
  assert.equal(
    source.match(/BMF_socket_scheduler_execute_one\(\)/g)?.length,
    3,
    'only the selector definition and two primary pump modes may execute unified work',
  );

  const fairnessStart = source.indexOf(
    'local SOCKET_ADMISSION_FAIRNESS_SLOTS = {',
  );
  const fairnessEnd = source.indexOf(
    'local GAME_THREAD_CALLBACK_RETENTION_LIMIT',
    fairnessStart,
  );
  assert.notEqual(fairnessStart, -1);
  assert.notEqual(fairnessEnd, -1);
  const fairness = source.slice(fairnessStart, fairnessEnd);
  assert.equal(fairness.match(/"direct_socket:interactive"/g)?.length, 4);
  assert.equal(fairness.match(/"tunnel:interactive"/g)?.length, 4);
  assert.equal(fairness.match(/"direct_socket:bulk"/g)?.length, 1);
  assert.equal(fairness.match(/"tunnel:bulk"/g)?.length, 1);

  assert.match(
    source,
    /BMF_UNIFIED_SOCKET_MAX_QUEUE[\s\S]*?BMF_UNIFIED_SOCKET_MAX_BYTES[\s\S]*?BMF_UNIFIED_SOCKET_MAX_DIRECT_QUEUE/,
    'unified record, byte, and direct-path bounds must be configurable',
  );
  assert.match(
    source,
    /function BMF_socket_scheduler_deadline_expired\(deadline_ms, issued_at_ms, accepted_clock\)[\s\S]*?\(os\.time\(\) \* 1000\) >= deadline[\s\S]*?\(os\.clock\(\) - accepted\) \* 1000[\s\S]*?deadline - issued/,
    'absolute deadlines must combine a certainly-old wall check with monotonic admitted TTL accounting',
  );
  assert.doesNotMatch(
    source,
    /os\.time\(\) >= math\.floor\(deadline \/ 1000\)/,
    'short deadlines in the current wall-clock second must not expire immediately',
  );
  assert.ok(
    (source.match(/"DEADLINE_REQUIRED"/g)?.length ?? 0) >= 3,
    'direct, tunnel, and identity admission must fail closed when absolute deadline metadata is missing',
  );

  const executeDirectStart = source.indexOf(
    'function BMF_socket_scheduler_execute_direct',
  );
  const executeDirectEnd = source.indexOf(
    'function BMF_socket_scheduler_note_tunnel_tick',
    executeDirectStart,
  );
  const executeDirect = source.slice(executeDirectStart, executeDirectEnd);
  assert.ok(
    executeDirect.indexOf('BMF_socket_scheduler_deadline_expired') <
      executeDirect.indexOf('BMF_dispatch_bmf_command_text'),
    'direct deadlines must be checked before command dispatch',
  );

  const terminalStart = source.indexOf(
    'function BMF_socket_scheduler_send_direct_terminal',
  );
  const terminalEnd = source.indexOf(
    'function BMF_socket_scheduler_reject_direct',
    terminalStart,
  );
  const terminal = source.slice(terminalStart, terminalEnd);
  assert.ok(
    terminal.indexOf('request.terminalSent = true') <
      terminal.indexOf('BMF_socket_scheduler_send_direct_json(record)'),
    'direct terminal state must be committed before the transport send attempt',
  );
  assert.match(
    source,
    /BMF_game_command_tunnel_dequeue\(service_class\)[\s\S]*?BMF_game_command_tunnel_drain_once\(selected_request\)/,
    'the unified selector must dequeue the exact tunnel service-class lane it selected',
  );

  const tunnelTerminalStart = source.indexOf(
    'BMF_game_command_tunnel_send_terminal = function',
  );
  const tunnelTerminalEnd = source.indexOf(
    'local function BMF_game_command_tunnel_send_rejection',
    tunnelTerminalStart,
  );
  const tunnelTerminal = source.slice(tunnelTerminalStart, tunnelTerminalEnd);
  assert.match(tunnelTerminal, /if request\.terminalSent == true then/);
  assert.ok(
    tunnelTerminal.indexOf('request.terminalSent = true') <
      tunnelTerminal.indexOf('BMF_game_command_tunnel_send_json(record)'),
    'tunnel terminal ownership must be committed before transport',
  );
});

test('command output and completed replay caches are bounded by count and bytes', () => {
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

  assert.match(
    source,
    /BMF_COMMAND_OUTPUT_MAX_LINES[\s\S]*?BMF_COMMAND_OUTPUT_MAX_BYTES/,
    'command output line and byte ceilings must be configurable',
  );
  assert.match(
    source,
    /BMF_OUTPUT_TRUNCATED omitted_lines=%d omitted_bytes_at_least=%d max_lines=%d max_bytes=%d/,
    'truncated command output must contain an explicit marker',
  );

  const dispatchStart = source.indexOf(
    'function BMF_dispatch_bmf_command_text',
  );
  const dispatchEnd = source.indexOf(
    'function process_command_request',
    dispatchStart,
  );
  const dispatch = source.slice(dispatchStart, dispatchEnd);
  assert.match(dispatch, /BMF_new_bounded_output_collector\(\)/);
  assert.match(dispatch, /BMF_bounded_output_add\(output_collector, line\)/);
  assert.match(dispatch, /BMF_bounded_output_finalize\(output_collector/);
  assert.doesNotMatch(
    dispatch,
    /lines\[#lines \+ 1\]/,
    'command handlers must not append to an unbounded output table',
  );

  assert.match(source, /BMF_UNIFIED_SOCKET_COMPLETED_MAX_BYTES/);
  assert.match(source, /BMF_GAME_COMMAND_TUNNEL_COMPLETED_MAX_BYTES/);
  assert.match(
    source,
    /BMF_REPLAY_RESPONSE_OMITTED cache_entry_byte_budget/,
    'oversized replay payloads must be replaced with an explicit omission marker',
  );

  const directRememberStart = source.indexOf(
    'function BMF_socket_scheduler_remember_direct_result',
  );
  const directRememberEnd = source.indexOf(
    'function BMF_socket_scheduler_send_direct_terminal',
    directRememberStart,
  );
  const directRemember = source.slice(directRememberStart, directRememberEnd);
  assert.match(directRemember, /retainedBytes = retained_bytes/);
  assert.match(
    directRemember,
    /while #admission\.completed_order > retention do/,
  );
  assert.match(
    directRemember,
    /BMF_socket_replay_compact_cache_to_budget\(admission, max_bytes, "direct"\)/,
  );
  assert.match(
    directRemember,
    /while \(tonumber\(admission\.completed_retained_bytes\) or 0\) > max_bytes do/,
    'direct replay eviction must enforce retained bytes after compacting payloads',
  );

  const tunnelRememberStart = source.indexOf(
    'local function BMF_game_command_tunnel_remember_result',
  );
  const tunnelRememberEnd = source.indexOf(
    'BMF_game_command_tunnel_send_terminal = function',
    tunnelRememberStart,
  );
  const tunnelRemember = source.slice(tunnelRememberStart, tunnelRememberEnd);
  assert.match(tunnelRemember, /retainedBytes = retained_bytes/);
  assert.match(tunnelRemember, /while #tunnel\.completed_order > retention do/);
  assert.match(
    tunnelRemember,
    /BMF_socket_replay_compact_cache_to_budget\(tunnel, max_bytes, "tunnel"\)/,
  );
  assert.match(
    tunnelRemember,
    /while \(tonumber\(tunnel\.completed_retained_bytes\) or 0\) > max_bytes do/,
    'tunnel replay eviction must enforce retained bytes after compacting payloads',
  );
  assert.match(
    source,
    /direct_completed_response_omitted[\s\S]*?tunnel_completed_response_omitted/,
    'replay retention, eviction, and omission counters must be exported',
  );
});

test('game command tunnel uses only an exact ephemeral controller address', () => {
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
  const source = fs.readFileSync(runtimePath, 'utf8').replace(/\r\n/g, '\n');
  const drainStart = source.indexOf(
    'BMF_game_command_tunnel_drain_once = function',
  );
  const drainEnd = source.indexOf(
    'BMF_game_command_tunnel_pump = function',
    drainStart,
  );
  const drain = source.slice(drainStart, drainEnd);

  assert.ok(drainStart >= 0 && drainEnd > drainStart);
  assert.doesNotMatch(
    source,
    /cached_controller_address/,
    'raw controller addresses must not be persisted in tunnel state',
  );
  assert.match(
    drain,
    /live_chat_resolve_authoritative_name_target[\s\S]*?final_controller_address ~= controller_address/,
    'tunnel dispatch must re-resolve and compare the exact UUID+name+generation target before invocation',
  );
  assert.doesNotMatch(
    drain,
    /request\.controllerAddress|request\["controllerAddress"\]/,
    'tunnel requests must not persist a controller address across ticks',
  );
  assert.doesNotMatch(
    drain,
    /nativeResolverOnly = true/,
    'tunnel dispatch must never ask the native layer to guess a controller',
  );
  assert.match(
    drain,
    /controller_cache_refreshes[\s\S]*?BMF_player_message_implementation_probe\(request\.line, "", \{[\s\S]*?controllerAddress = controller_address,[\s\S]*?\}\)/,
    'each tunnel dispatch must use only the controller address proven in the same synchronous turn',
  );
  assert.match(source, /controller_address_reuse_enabled = false/);
  assert.match(source, /controllerAddressReuseEnabled = false/);
  assert.ok(
    drain.indexOf('readiness_not_before_tick') <
      drain.indexOf('BMF_game_command_tunnel_readiness_probe(request)'),
    'deferred retries must skip authoritative/native readiness work before probing',
  );
  assert.match(
    source,
    /BMFConnectionReadiness\.repair_decision\([\s\S]*?identity\.uuid,[\s\S]*?identity\.connectionGeneration/,
    'repair admission must be keyed to the exact UUID and connection generation',
  );
  assert.match(
    source,
    /BMF_game_command_tunnel_defer_retry\(request, readiness_retry_detail\)/,
  );

  const probeStart = source.indexOf(
    'local function BMF_player_message_implementation_probe',
  );
  const probeEnd = source.indexOf(
    'function BMF.chat.playerMessageImplementationProbe',
    probeStart,
  );
  const probe = source.slice(probeStart, probeEnd);
  const nativeOnlyStart = probe.indexOf('if native_resolver_only then');
  const luaCandidateStart = probe.indexOf(
    '\n  else\n    if preferred_controller_address',
    nativeOnlyStart,
  );
  const nativeOnlyBranch = probe.slice(nativeOnlyStart, luaCandidateStart);
  assert.ok(nativeOnlyStart >= 0 && luaCandidateStart > nativeOnlyStart);
  assert.match(
    nativeOnlyBranch,
    /address = ""[\s\S]*?label = "native-resolver"/,
    'native-only resolution must invoke the native helper with an empty address',
  );
  assert.doesNotMatch(
    nativeOnlyBranch,
    /FindAllOf|live_chat_is_valid_object/,
    'native-only resolution must not touch Lua UObject enumeration or validation',
  );
  assert.match(probe, /native_resolver_only and "native-resolver-only"/);
});

test('native controller and tree target paths reject cross-frame UObject reuse', () => {
  const nativePath = path.join(
    __dirname,
    '..',
    '..',
    '..',
    '..',
    'native',
    'bmf_socket',
    'bmf_socket.cpp',
  );
  const source = fs.readFileSync(nativePath, 'utf8');

  const bindingStart = source.indexOf(
    'std::string build_native_player_controller_binding_text(',
  );
  const bindingEnd = source.indexOf(
    'std::string build_native_uobject_description_text(',
    bindingStart,
  );
  const binding = source.slice(bindingStart, bindingEnd);
  assert.ok(bindingStart >= 0 && bindingEnd > bindingStart);
  assert.match(binding, /find_bounded_reciprocal_player_state\(controller\)/);
  assert.match(binding, /count_bounded_ue_guid_matches/);
  assert.match(binding, /identity_uuid_match=true/);
  assert.doesNotMatch(
    binding,
    /get_object_property|export_property_text_guarded/,
  );
  assert.doesNotMatch(
    binding,
    /ForEachUObject|FindAllOf|FindFirstOf|write_player_position_memory_reference_probe/,
    'exact controller binding description must perform no global or generic memory-reference scan',
  );
  assert.match(source, /parse_canonical_uuid_as_ue_guid_bytes/);
  assert.match(
    source,
    /find_bounded_reciprocal_player_state[\s\S]*?kControllerScanEnd = 0x500[\s\S]*?kPlayerStateScanEnd = 0x600/,
    'controller binding must remain bounded to reciprocal controller/PlayerState memory',
  );
  assert.match(
    source,
    /count_bounded_ue_guid_matches[\s\S]*?kIdentityScanBytes = 0x800/,
    'UUID proof must remain bounded to the exact live PlayerState object',
  );
  assert.match(
    source,
    /register_function\("BMFSocketDescribePlayerControllerBinding", lua_socket_describe_player_controller_binding\)/,
  );

  const controllerResolverStart = source.indexOf(
    'Unreal::UObject* find_live_player_controller(uint32_t& scanned',
    source.indexOf('bool is_live_player_controller_object'),
  );
  const controllerResolverEnd = source.indexOf(
    'bool install_reserved_chat_guard',
    controllerResolverStart,
  );
  const controllerResolver = source.slice(
    controllerResolverStart,
    controllerResolverEnd,
  );
  assert.doesNotMatch(
    controllerResolver,
    /is_live_uobject/,
    'controller resolution must not enter the unguarded generic UObject predicate',
  );
  assert.ok(
    controllerResolver.indexOf(
      'player_controller_lifecycle_is_usable_guarded(object)',
    ) < controllerResolver.indexOf('object_class_has_any_cast_flags_guarded'),
    'the SEH lifecycle guard must dominate controller candidate inspection',
  );

  const implementationStart = source.indexOf(
    'std::string execute_player_chat_message_implementation_probe_text',
  );
  const implementationEnd = source.indexOf(
    'Unreal::UObject* find_kismet_system_library_default',
    implementationStart,
  );
  const implementation = source.slice(implementationStart, implementationEnd);
  assert.doesNotMatch(implementation, /is_live_uobject\(controller\)/);
  assert.match(
    implementation,
    /player_controller_lifecycle_is_usable_guarded\(controller\)[\s\S]*?read_player_controller_identity_guarded/,
    'a returned controller must be lifecycle-gated before identity logging or vtable use',
  );

  const targetStructStart = source.indexOf('struct TreeCutTargetCandidate');
  const targetStructEnd = source.indexOf(
    'std::vector<TreeCutTargetCandidate> g_treecut_target_cache',
    targetStructStart,
  );
  const targetStruct = source.slice(targetStructStart, targetStructEnd);
  assert.doesNotMatch(
    targetStruct,
    /UObject\s*\*/,
    'tree target cache entries must contain only copied primitive metadata',
  );
  assert.doesNotMatch(source, /candidate\.actor/);

  const refreshStart = source.indexOf('void treecut_refresh_target_cache');
  const refreshEnd = source.indexOf(
    'struct TreeCutResolvedTarget',
    refreshStart,
  );
  const refresh = source.slice(refreshStart, refreshEnd);
  assert.ok(
    refresh.indexOf('uobject_lifecycle_is_usable_guarded(object)') <
      refresh.indexOf('object_name(object)'),
    'tree target refresh must lifecycle-gate candidates before dereference',
  );

  const cachedResolveStart = source.indexOf(
    'TreeCutResolvedTarget treecut_resolve_target_actor',
  );
  const cachedResolveEnd = source.indexOf(
    'void write_treecut_target_json',
    cachedResolveStart,
  );
  const cachedResolve = source.slice(cachedResolveStart, cachedResolveEnd);
  assert.doesNotMatch(
    cachedResolve,
    /UObject|is_live_uobject|uobject_lifecycle_is_usable_guarded/,
    'cached target resolution must consume only copied metadata, never a UObject',
  );

  const damageTargetStart = source.indexOf(
    'void write_treecut_damage_target_json',
  );
  const damageTargetEnd = source.indexOf(
    'struct TreeCutProbeSlot',
    damageTargetStart,
  );
  const damageTarget = source.slice(damageTargetStart, damageTargetEnd);
  assert.ok(
    damageTarget.indexOf('uobject_lifecycle_is_usable_guarded(source)') <
      damageTarget.indexOf('actor_from_uobject_or_outer(source'),
    'a retained damage-target address must be SEH lifecycle-gated before dereference',
  );
});

test('player registry keeps ordinary player and chat paths cache-first with explicit bounded repair', () => {
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

  assert.doesNotMatch(
    source,
    /controller_handles/,
    'player registry must never retain UE4SS controller userdata across requests',
  );
  assert.match(source, /controller_userdata_cache_enabled = false/);

  assert.match(
    source,
    /BMF_PLAYER_REGISTRY_CACHE_FIRST_ENABLED[\s\S]*?true\)/,
    'cache-first player discovery must be default-on with a rollback flag',
  );
  assert.match(
    source,
    /BMF_PLAYER_REGISTRY_REPAIR_ENABLED[\s\S]*?true\)/,
    'explicit repair must have a default-on feature flag',
  );
  assert.match(
    source,
    /BMF_PLAYER_REGISTRY_LEGACY_DISCOVERY_ENABLED[\s\S]*?false\)/,
    'request-time log discovery must require an explicit diagnostic flag',
  );

  const cachedPlayersStart = source.indexOf(
    'function live_chat_cached_players()',
  );
  const cachedPlayersEnd = source.indexOf(
    'function live_chat_cached_controller',
    cachedPlayersStart,
  );
  assert.notEqual(cachedPlayersStart, -1);
  assert.notEqual(cachedPlayersEnd, -1);
  const cachedPlayers = source.slice(cachedPlayersStart, cachedPlayersEnd);
  assert.doesNotMatch(cachedPlayers, /read_file\s*\(/);
  assert.doesNotMatch(cachedPlayers, /json_decode\s*\(/);
  assert.match(cachedPlayers, /state\.player_cache/);

  const cachedControllerStart = cachedPlayersEnd;
  const cachedControllerEnd = source.indexOf(
    'function live_chat_exact_identity_values',
    cachedControllerStart,
  );
  const cachedController = source.slice(
    cachedControllerStart,
    cachedControllerEnd,
  );
  assert.match(cachedController, /live_chat_find_controller_by_name\(path\)/);
  assert.doesNotMatch(
    cachedController,
    /live_chat_is_valid_object/,
    'fresh path resolution must not revalidate userdata retained by a prior request',
  );

  const publishStart = source.indexOf('function publish_player_cache');
  const publishEnd = source.indexOf('function load_player_cache', publishStart);
  const publish = source.slice(publishStart, publishEnd);
  assert.doesNotMatch(
    publish,
    /live_chat_is_valid_object|controller\s*=|handle/,
    'publishing a plain player snapshot must not retain or inspect controller userdata',
  );

  const collectStart = source.indexOf(
    'function live_chat_collect_targets(options)',
  );
  const collectEnd = source.indexOf(
    'function live_chat_target_summary',
    collectStart,
  );
  assert.notEqual(collectStart, -1);
  assert.notEqual(collectEnd, -1);
  const collectTargets = source.slice(collectStart, collectEnd);
  assert.equal(
    collectTargets.match(/BMF_operation_find_all\(/g)?.length,
    1,
    'global discovery must exist only in the explicit repair branch',
  );
  assert.ok(
    collectTargets.indexOf('elseif repair_needed then') <
      collectTargets.indexOf('BMF_operation_find_all('),
    'global discovery must be dominated by the explicit repair gate',
  );
  assert.doesNotMatch(
    collectTargets,
    /FindFirstOf/,
    'ordinary or repair target collection must not add an unbounded fallback scan',
  );
  assert.match(
    source,
    /repair_running == true[\s\S]*?repair_cooldown_ms/,
    'concurrent or burst repair requests must be coalesced by ownership and cooldown',
  );

  const listStart = source.indexOf('BMF.players.list = function(options)');
  const listEnd = source.indexOf(
    'function player_position_axis_from_value',
    listStart,
  );
  const playerList = source.slice(listStart, listEnd);
  assert.ok(
    playerList.indexOf('if use_legacy_discovery then') <
      playerList.indexOf('native_player_records()'),
    'Brickadia.log parsing must remain behind the rollback or diagnostic gate',
  );
  assert.match(
    playerList,
    /live_player_controller_count\(\{\s*repair = repair_requested/,
    'only an explicit list repair request may authorize broad controller repair',
  );

  const syncStart = source.indexOf(
    'BMF.players.sync = function(records, options)',
  );
  const syncEnd = source.indexOf('function player_query_text', syncStart);
  const playerSync = source.slice(syncStart, syncEnd);
  assert.match(
    playerSync,
    /if persist then\s+synced = write_player_cache\(cache\)[\s\S]*?else\s+synced = publish_player_cache\(cache\) ~= nil/,
    'persist=false syncs must publish memory without a game-thread file write',
  );
  assert.equal(
    source.match(/load_player_cache\(\{ force = true \}\)/g)?.length,
    1,
    'the durable player cache must be force-loaded exactly once at startup',
  );

  const assignmentCacheStart = source.indexOf(
    'function BMF_minigame_player_cache_records()',
  );
  const assignmentCacheEnd = source.indexOf(
    'local function minigame_find_cached_object',
    assignmentCacheStart,
  );
  const assignmentCache = source.slice(
    assignmentCacheStart,
    assignmentCacheEnd,
  );
  assert.match(assignmentCache, /state\.player_cache/);
  assert.doesNotMatch(assignmentCache, /read_file\s*\(|json_decode\s*\(/);
  assert.match(
    source,
    /BMF_UNSAFE_PLAYER_MESSAGE_IMPL_DIAGNOSTIC_ENABLED", false/,
    'the previously monolithic native player-message route must be diagnostic-only',
  );
});

test('operation attribution stays bounded, plain-data-only, and attached to the unified broker', () => {
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

  assert.match(
    source,
    /BMF_OPERATION_ATTRIBUTION_ENABLED", true/,
    'attribution must be default-on with an explicit rollback flag',
  );
  const beginStart = source.indexOf('function BMF_operation_begin');
  const beginEnd = source.indexOf(
    'function BMF_operation_update_class',
    beginStart,
  );
  const begin = source.slice(beginStart, beginEnd);
  assert.doesNotMatch(
    begin,
    /UObject|controller\s*=|object_path|player_name|address/i,
    'cross-frame operation envelopes may contain only copied scalar attribution data',
  );
  assert.match(begin, /correlation_id = "bmf-"/);
  assert.match(begin, /request_id = request_id/);
  assert.match(begin, /sender_uuid = sender_uuid/);
  assert.match(begin, /connection_generation = connection_generation/);
  assert.match(begin, /current_stage = "accepted"/);
  assert.match(begin, /queue_wait_ms = 0/);
  assert.match(begin, /admission_defer_count = 0/);
  assert.match(begin, /global_scan_count = 0/);
  assert.match(begin, /deadline_state = "accepted"/);

  const finishStart = source.indexOf('function BMF_operation_finish');
  const finishEnd = source.indexOf('\nlocal function join_path', finishStart);
  const finish = source.slice(finishStart, finishEnd);
  assert.match(finish, /BMF_SLOW_OPERATION/);
  assert.match(finish, /game_thread_ms/);
  assert.match(finish, /total_ms/);
  assert.match(finish, /global_scan_duration_ms/);
  assert.match(finish, /budget_exceeded/);
  assert.match(finish, /frame_duration_ms_near_completion/);
  assert.match(finish, /request_id = context\.request_id/);
  assert.match(finish, /sender_uuid = context\.sender_uuid/);
  assert.match(finish, /context\.accepted_clock = nil/);
  assert.match(finish, /context\.execution_started_clock = nil/);
  assert.equal(
    source.match(/pcall\(FindAllOf/g)?.length,
    1,
    'every global UObject scan must route through the attributed scan wrapper',
  );
  assert.match(
    source,
    /function BMF_operation_find_all[\s\S]*?BMF_operation_note_global_scan\(duration_ms\)/,
  );

  const directAdmissionStart = source.indexOf(
    'function BMF_socket_scheduler_admit_direct',
  );
  const directAdmissionEnd = source.indexOf(
    'function BMF_socket_scheduler_lane_queue',
    directAdmissionStart,
  );
  const directAdmission = source.slice(
    directAdmissionStart,
    directAdmissionEnd,
  );
  assert.match(
    directAdmission,
    /request\.operationContext = BMF_operation_begin/,
  );
  assert.match(
    source,
    /BMF_operation_start_execution\(request\.operationContext\)/,
  );
  assert.match(
    source,
    /BMF_operation_finish\(request\.operationContext, normalized_state\)/,
  );
  assert.match(
    source,
    /budget_admission_stopped = true\s+BMF_operation_note_queued_budget_defer\(\)/,
    'the existing elapsed-time budget must attribute admission deferrals without a second queue',
  );
  assert.match(
    source,
    /BMF_operation_update_stage\(request\.operationContext, "queued"\)/,
  );
  assert.match(source, /BMFFrameTelemetryOperationSnapshot/);

  const prometheusPath = path.join(
    __dirname,
    '..',
    'src',
    'webserver',
    'backend',
    'prometheus.ts',
  );
  const prometheus = fs.readFileSync(prometheusPath, 'utf8');
  assert.doesNotMatch(
    prometheus,
    /labels:\s*\{[^}]*correlation_id/,
    'correlation IDs must never enter Prometheus labels',
  );
  assert.match(prometheus, /bmf_operation_duration_milliseconds/);
  assert.match(
    prometheus,
    /labels: \{ operation_class: operationClass, phase, statistic:/,
  );
});

test('private delivery requires immutable identity and bounds exact-name repair', () => {
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
  const strictStart = source.indexOf(
    'function live_chat_resolve_strict_target(identity)',
  );
  const strictEnd = source.indexOf(
    'function live_chat_validate_authoritative_identity(identity)',
    strictStart,
  );
  const targetedResolve = source.slice(strictStart, strictEnd);
  assert.match(targetedResolve, /candidate_uuid == expected_uuid/);
  assert.match(targetedResolve, /cached_generation ~= expected_generation/);
  assert.match(
    targetedResolve,
    /live_chat_cached_controller\(expected_controller_path\)/,
  );
  assert.match(targetedResolve, /snapshot_generation ~= current_generation/);
  assert.match(targetedResolve, /cached_names\[live_name\] ~= true/);
  assert.doesNotMatch(targetedResolve, /identity\.controllerPath/);
  assert.doesNotMatch(targetedResolve, /identity\.playerStatePath/);
  assert.doesNotMatch(targetedResolve, /FindAllOf|FindFirstOf/);
  assert.doesNotMatch(targetedResolve, /live_chat_collect_targets/);

  const privateStart = source.indexOf('function private_chat_result');
  const privateEnd = source.indexOf('BMF.timers = {}', privateStart);
  const privateChat = source.slice(privateStart, privateEnd);
  assert.match(privateChat, /live_chat_resolve_target\(player\)/);
  assert.doesNotMatch(privateChat, /FindAllOf|FindFirstOf/);
  assert.match(privateChat, /strictPrivateIdentity == true/);
  assert.match(privateChat, /PRIVATE_IDENTITY_REQUIRED/);
  assert.match(privateChat, /strict_envelope_required/);
  assert.doesNotMatch(privateChat, /BMF\.players\.resolve\(player\)/);
  assert.match(privateChat, /BMF\.chat\.whisper = function/);
  assert.match(privateChat, /BMF\.chat\.statusMessage = function/);

  const envelopeStart = source.indexOf(
    'local function parse_private_delivery_envelope',
  );
  const envelopeEnd = source.indexOf(
    'local function private_delivery_lines',
    envelopeStart,
  );
  const envelope = source.slice(envelopeStart, envelopeEnd);
  assert.match(envelope, /sender_uuid/);
  assert.match(envelope, /sender_name/);
  assert.match(envelope, /connection_generation/);
  assert.match(envelope, /deadline_ms/);
  assert.doesNotMatch(envelope, /controllerpath|playerstatepath|senderhash/i);

  const resolveStart = source.indexOf('function live_chat_resolve_target(player)');
  const resolveEnd = source.indexOf('function live_chat_send_to_targets', resolveStart);
  const resolveTarget = source.slice(resolveStart, resolveEnd);
  assert.match(resolveTarget, /player\.senderName/);
  assert.match(resolveTarget, /live_chat_resolve_authoritative_name_target\(player\)/);

  const collectStart = source.indexOf(
    'function live_chat_collect_targets(options)',
  );
  const collectEnd = source.indexOf(
    'function live_chat_target_summary',
    collectStart,
  );
  const collectTargets = source.slice(collectStart, collectEnd);
  assert.match(
    collectTargets,
    /repair_needed and not live_chat_repair_allowed[\s\S]*?registry\.repair_coalesced/,
    'burst misses must coalesce behind active-repair/cooldown ownership instead of scanning repeatedly',
  );
  assert.ok(
    collectTargets.indexOf('repair_detail.requested') <
      collectTargets.indexOf('BMF_operation_find_all('),
    'a global scan must remain dominated by an explicit repair request',
  );
});

test('legacy OmeggaBridge name-only private delivery is disabled', () => {
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
  const handlerStart = source.indexOf(
    'local function handle_typed_chat_whisper',
  );
  const handlerEnd = source.indexOf(
    'local function handle_typed_chat_status_message',
    handlerStart,
  );
  const handler = source.slice(handlerStart, handlerEnd);
  assert.match(handler, /Legacy name-only Chat\.Whisper is disabled/);
  assert.doesNotMatch(handler, /try_fast_typed_chat_whisper\(/);
  assert.doesNotMatch(
    source,
    /#selected_sources\s*==\s*0\s+and\s+#player_sources\s*==\s*1/,
  );
});

test('Omegga accepts the native unknown-command flag only after verified application', () => {
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
  const serverPath = path.join(
    __dirname,
    '..',
    'src',
    'brickadia',
    'server.ts',
  );
  const bridgeSource = fs.readFileSync(bridgePath, 'utf8');
  const serverSource = fs.readFileSync(serverPath, 'utf8');

  assert.match(
    bridgeSource,
    /local call_ok, applied, output = pcall\(BMFSocketSetUnknownCommandMessages, false\)/,
  );
  assert.match(bridgeSource, /if call_ok and applied then/);
  assert.match(bridgeSource, /"bmf-native-unknown-command-flag"/);
  assert.match(serverSource, /'bmf-native-unknown-command-flag'/);
});

test('frame hitch logging records 33.3 ms frames off the game thread', () => {
  const nativePath = path.join(
    __dirname,
    '..',
    '..',
    '..',
    '..',
    'native',
    'bmf_frame_telemetry',
    'bmf_frame_telemetry.cpp',
  );
  const source = fs.readFileSync(nativePath, 'utf8');
  assert.match(source, /BMF_FRAME_HITCH_ATTRIBUTION_ENABLED", true/);
  assert.match(
    source,
    /if \(delta_us >= kSlow33ThresholdUs\)[\s\S]*?record_spike\(delta_us, idle, sample\)/,
  );
  assert.doesNotMatch(
    source.slice(
      source.indexOf('void observe(float delta_seconds'),
      source.indexOf(
        'std::string status_json',
        source.indexOf('void observe(float delta_seconds'),
      ),
    ),
    /printf|BMF_SLOW_FRAME/,
    'the game-thread frame observer must not perform synchronous logging',
  );
  const writerStart = source.indexOf('void writer_loop()');
  const writerEnd = source.indexOf('void write_snapshot()', writerStart);
  assert.match(source.slice(writerStart, writerEnd), /log_pending_spikes\(\)/);
  assert.match(source, /\[BMF_SLOW_FRAME\] %s/);
  assert.match(source, /threshold_ms\\\":\" << us_to_ms\(kSlow33ThresholdUs\)/);
  assert.match(source, /BMFFrameTelemetryOperationSnapshot/);
  assert.match(source, /operation_snapshot_json\(\)/);
});

test('CityRPG tunnel resolves one exact current Omegga identity and retains no UObject', () => {
  const runtimePath = path.resolve(
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
  const resolverStart = source.indexOf(
    'function live_chat_resolve_authoritative_name_target(identity)',
  );
  const resolverEnd = source.indexOf(
    'function live_chat_resolve_target(player)',
    resolverStart,
  );
  assert.notEqual(resolverStart, -1, 'authoritative resolver must exist');
  assert.notEqual(
    resolverEnd,
    -1,
    'authoritative resolver boundary must exist',
  );
  const resolver = source.slice(resolverStart, resolverEnd);

  assert.match(
    resolver,
    /live_chat_validate_authoritative_identity\(identity\)/,
  );
  assert.match(
    resolver,
    /live_chat_collect_targets\(\{[\s\S]*?repair = true,[\s\S]*?expectedUuid = expected_uuid/,
  );
  assert.match(
    resolver,
    /live_chat_controller_authoritative_identity_matches/,
    'controller repair must require the exact live UUID after validating the current UUID/name/generation envelope',
  );
  assert.match(source, /tostring\(cached_player\.name or ""\)/);
  assert.match(source, /tostring\(metadata\.name or ""\)/);
  assert.match(
    source,
    /function live_chat_native_controller_binding_metadata\(controller, expected_uuid\)[\s\S]*?BMFSocketDescribePlayerControllerBinding/,
  );
  assert.match(
    source,
    /metadata\.controllerPath = first_string\([\s\S]*?fields\.controller_name[\s\S]*?fields\.controller_full_name/,
    'the UUID-proven binding must cache the resolvable exact controller instance name',
  );
  assert.match(
    source,
    /metadata\.playerStatePath = first_string\([\s\S]*?fields\.player_state_name[\s\S]*?fields\.player_state_full_name/,
    'the UUID-proven binding must compare a stable exact PlayerState instance name',
  );
  assert.match(resolver, /if #matches ~= 1 then/);
  assert.match(resolver, /exact_name_ambiguous/);
  assert.match(resolver, /exact_name_not_found/);
  assert.doesNotMatch(resolver, /live_chat_target_matches/);
  assert.doesNotMatch(
    resolver,
    /state\.[A-Za-z0-9_.]+\s*=\s*repaired\.controller/,
  );
  assert.doesNotMatch(resolver, /cached_player\.controller\s*=/);
  assert.match(
    resolver,
    /cached_player\.controllerPath = repaired\.controllerPath/,
  );
  assert.match(
    resolver,
    /cached_player\.playerStatePath = repaired\.playerStatePath/,
  );

  const nativeStateStart = source.indexOf(
    'local function minigame_native_player_state_from_controller(controller)',
  );
  const nativeStateEnd = source.indexOf(
    'local function minigame_cached_player_state_for_assignment(query)',
    nativeStateStart,
  );
  const nativeStateResolver = source.slice(nativeStateStart, nativeStateEnd);
  assert.match(nativeStateResolver, /\^player_state_full_name=/);
  assert.match(nativeStateResolver, /\^player_state_name=/);
  assert.match(
    source,
    /function live_chat_controller_metadata\(controller, expected_uuid\)[\s\S]*?canonical_expected_uuid ~= ""[\s\S]*?return metadata[\s\S]*?minigame_native_player_state_from_controller\(controller\)/,
    'exact UUID resolution must fail closed before the broken generic PlayerState property fallback',
  );

  const exactIdentityStart = source.indexOf(
    'function live_chat_controller_authoritative_identity_matches(',
  );
  const exactIdentityEnd = source.indexOf(
    '-- Resolve a controller without ever inferring identity',
    exactIdentityStart,
  );
  const exactIdentity = source.slice(exactIdentityStart, exactIdentityEnd);
  assert.match(
    exactIdentity,
    /live_chat_controller_metadata\(controller, expected_uuid\)/,
  );
  assert.match(exactIdentity, /live_chat_stable_uuid\(expected_uuid\)/);
  assert.match(exactIdentity, /live_uuid == ""/);
  assert.doesNotMatch(exactIdentity, /#(?:targets|controllers)\s*==\s*1/);

  const tunnelStart = source.indexOf(
    'BMF_process_game_command_tunnel_request = function(decoded)',
  );
  const tunnelEnd = source.indexOf(
    'function BMF_process_socket_message(line)',
    tunnelStart,
  );
  const tunnel = source.slice(tunnelStart, tunnelEnd);
  assert.match(
    tunnel,
    /local sender_name = trim_string\(decoded\.senderName or ""\)/,
  );
  assert.match(tunnel, /SENDER_NAME_REQUIRED/);
  assert.match(tunnel, /live_chat_validate_authoritative_identity/);
  assert.match(tunnel, /senderName = sender_name/);
  assert.doesNotMatch(tunnel, /#(?:targets|controllers)\s*==\s*1/);

  assert.equal(
    (source.match(/live_chat_resolve_authoritative_name_target\(\{/g) || [])
      .length,
    2,
    'readiness and final execution checks must both resolve the immutable envelope',
  );
  assert.match(
    source,
    /controllerAddress = controller_address/,
    'native injection must receive only the freshly resolved address',
  );
});
