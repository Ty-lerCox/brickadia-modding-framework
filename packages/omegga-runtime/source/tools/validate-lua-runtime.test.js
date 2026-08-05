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
  assert.notEqual(enabledStart, -1, 'socket pump must select bounded native drains');
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
  assert.equal(
    fairness.match(/"direct_socket:interactive"/g)?.length,
    4,
  );
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
  assert.equal(
    source.match(/"DEADLINE_REQUIRED"/g)?.length,
    2,
    'bounded direct and tunnel admission must fail closed when absolute deadline metadata is missing',
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
  const tunnelTerminal = source.slice(
    tunnelTerminalStart,
    tunnelTerminalEnd,
  );
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
  assert.match(directRemember, /while #admission\.completed_order > retention do/);
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
    collectTargets.match(/pcall\(FindAllOf/g)?.length,
    1,
    'global discovery must exist only in the explicit repair branch',
  );
  assert.ok(
    collectTargets.indexOf('elseif repair_needed then') <
      collectTargets.indexOf('pcall(FindAllOf'),
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

  const syncStart = source.indexOf('BMF.players.sync = function(records, options)');
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
});
