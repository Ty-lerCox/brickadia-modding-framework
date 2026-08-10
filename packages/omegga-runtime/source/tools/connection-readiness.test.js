'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const fengari = require('fengari');

const {
  lua,
  lauxlib,
  lualib,
  to_jsstring: toJsString,
  to_luastring: toLuaString,
} = fengari;

const modulePath = path.resolve(
  __dirname,
  '../templates/windows-ue4ss/ue4ss/Mods/BMF/Scripts/bmf/connection_readiness.lua',
);
const moduleSource = fs.readFileSync(modulePath, 'utf8');

function execute(body) {
  const state = lauxlib.luaL_newstate();
  assert.ok(state, 'Fengari should allocate a Lua state');
  lualib.luaL_openlibs(state);
  const source = `local Readiness = (function()\n${moduleSource}\nend)()\n${body}`;
  const buffer = toLuaString(source);
  const status = lauxlib.luaL_loadbuffer(
    state,
    buffer,
    buffer.length,
    toLuaString('@connection-readiness.test.lua'),
  );
  if (status !== lua.LUA_OK) {
    const message = toJsString(lua.lua_tostring(state, -1));
    lua.lua_close(state);
    assert.fail(message);
  }
  const callStatus = lua.lua_pcall(state, 0, 0, 0);
  if (callStatus !== lua.LUA_OK) {
    const message = toJsString(lua.lua_tostring(state, -1));
    lua.lua_close(state);
    assert.fail(message);
  }
  lua.lua_close(state);
}

test('missing sender UUID and generation zero are rejected before admission', () => {
  execute(`
    local tracker = Readiness.new()
    local base = {
      requestId = 'request-1', acceptedAtMs = 100, absoluteDeadlineMs = 500,
      operationType = 'cityrpg.remote.test', senderUuid = '', connectionGeneration = 1,
    }
    local ok, code = Readiness.admission(tracker, base, 101)
    assert(ok == false and code == 'SENDER_UUID_REQUIRED')
    base.senderUuid = 'not-a-uuid'
    ok, code = Readiness.admission(tracker, base, 101)
    assert(ok == false and code == 'SENDER_UUID_REQUIRED')
    base.senderUuid = '11111111-1111-4111-8111-111111111111'
    base.connectionGeneration = 0
    ok, code = Readiness.admission(tracker, base, 101)
    assert(ok == false and code == 'CONNECTION_GENERATION_REQUIRED')
    base.connectionGeneration = 1
    ok, code = Readiness.admission(tracker, base, 101)
    assert(ok == false and code == 'UNKNOWN_SESSION')
  `);
});

test('controller resolution is distinct from native callability and waits boundedly', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, connectionGeneration = 1,
      controllerPath = 'PersistentLevel.Controller_1',
      playerStatePath = 'PersistentLevel.State_1',
    }}, 100)
    local entry = assert(Readiness.current(tracker, uuid, 1))
    assert(entry.state == 'controller_resolved')
    local operation = {
      requestId = 'request-1', senderUuid = uuid, connectionGeneration = 1,
      acceptedAtMs = 100, absoluteDeadlineMs = 500,
      operationType = 'cityrpg.remote.test',
    }
    local decision = Readiness.execution_decision(tracker, operation, 200)
    assert(decision == 'wait')
    assert(Readiness.note_check(tracker, uuid, 1, true, nil, 220) == true)
    decision = Readiness.execution_decision(tracker, operation, 221)
    assert(decision == 'execute')
  `);
});

test('same-session blank sync preserves only lifecycle-validated plain paths', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = 'PersistentLevel.Controller_1',
      playerStatePath = 'PersistentLevel.State_1',
    }}, 100)
    assert(Readiness.note_check(tracker, uuid, 1, true, nil, 110) == true)
    local blank = {
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = '', playerStatePath = '',
    }
    Readiness.sync(tracker, {blank}, 120)
    local entry = assert(Readiness.current(tracker, uuid, 1))
    assert(entry.controllerPath == 'PersistentLevel.Controller_1')
    assert(entry.playerStatePath == 'PersistentLevel.State_1')
    assert(entry.state == 'native_callable')
    assert(blank.controllerPath == entry.controllerPath)
    assert(blank.playerStatePath == entry.playerStatePath)
    assert(blank.bmfControllerPathPreserved == true)
    assert(Readiness.note_path_reuse(tracker, uuid, 1, 121) == true)
    local snapshot = Readiness.snapshot(tracker)
    assert(snapshot.pathPreservations == 1 and snapshot.pathReuses == 1)
  `);
});

test('blank paths are not preserved before lifecycle validation', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = 'Controller_1', playerStatePath = 'State_1',
    }}, 100)
    local blank = {
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = '', playerStatePath = '',
    }
    Readiness.sync(tracker, {blank}, 101)
    local entry = assert(Readiness.current(tracker, uuid, 1))
    assert(entry.controllerPath == '' and entry.playerStatePath == '')
    assert(entry.state == 'joined')
    assert(blank.bmfControllerPathPreserved == false)
  `);
});

test('expired work and old generations never execute after reconnect', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, connectionGeneration = 1,
      controllerPath = 'PersistentLevel.Controller_1', playerStatePath = 'PersistentLevel.State_1',
    }}, 100)
    Readiness.note_check(tracker, uuid, 1, true, nil, 110)
    local expired = {
      requestId = 'old', senderUuid = uuid, connectionGeneration = 1,
      acceptedAtMs = 100, absoluteDeadlineMs = 300, operationType = 'cityrpg.remote.test',
    }
    assert(Readiness.execution_decision(tracker, expired, 300) == 'expire')
    local old = {
      requestId = 'old-generation', senderUuid = uuid, connectionGeneration = 1,
      acceptedAtMs = 100, absoluteDeadlineMs = 1000, operationType = 'cityrpg.remote.test',
    }
    Readiness.sync(tracker, {{
      uuid = uuid, connectionGeneration = 2,
      controllerPath = 'PersistentLevel.Controller_2', playerStatePath = 'PersistentLevel.State_2',
    }}, 320)
    local old_entry = tracker.byUuid[uuid].generations[1]
    assert(old_entry.controllerPath == '' and old_entry.playerStatePath == '')
    assert(old_entry.pathsValidated == false)
    assert(Readiness.execution_decision(tracker, old, 321) == 'reject')
    local stale, reason = Readiness.current(tracker, uuid, 1)
    assert(stale == nil and reason == 'connection_generation_mismatch')
  `);
});

test('simultaneous reconnects remain isolated and disconnect invalidates immediately', () => {
  execute(`
    local tracker = Readiness.new()
    local a = '11111111-1111-4111-8111-111111111111'
    local b = '22222222-2222-4222-8222-222222222222'
    Readiness.sync(tracker, {
      {uuid = a, connectionGeneration = 1, controllerPath = 'Controller_A1', playerStatePath = 'State_A1'},
      {uuid = b, connectionGeneration = 1, controllerPath = 'Controller_B1', playerStatePath = 'State_B1'},
    }, 100)
    Readiness.note_check(tracker, a, 1, true, nil, 110)
    Readiness.note_check(tracker, b, 1, true, nil, 110)
    Readiness.sync(tracker, {
      {uuid = a, connectionGeneration = 2, controllerPath = 'Controller_A2', playerStatePath = 'State_A2'},
      {uuid = b, connectionGeneration = 2, controllerPath = 'Controller_B2', playerStatePath = 'State_B2'},
    }, 200)
    assert(select(2, Readiness.current(tracker, a, 1)) == 'connection_generation_mismatch')
    assert(select(2, Readiness.current(tracker, b, 1)) == 'connection_generation_mismatch')
    assert(Readiness.current(tracker, a, 2).state == 'controller_resolved')
    assert(Readiness.current(tracker, b, 2).state == 'controller_resolved')
    Readiness.sync(tracker, {{
      uuid = b, connectionGeneration = 2,
      controllerPath = 'Controller_B2', playerStatePath = 'State_B2',
    }}, 210)
    local missing_a, missing_a_reason = Readiness.current(tracker, a, 2)
    assert(missing_a == nil)
    assert(missing_a_reason == 'disconnected' or missing_a_reason == 'connection_generation_mismatch')
    local disconnected = tracker.byUuid[a].generations[2]
    assert(disconnected.controllerPath == '' and disconnected.playerStatePath == '')
    assert(Readiness.current(tracker, b, 2).state == 'controller_resolved')
  `);
});

test('stale name, UUID, or generation cannot reuse a retained path', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = 'Controller_1', playerStatePath = 'State_1',
    }}, 100)
    Readiness.note_check(tracker, uuid, 1, true, nil, 110)
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'NotTy', connectionGeneration = 1,
      controllerPath = '', playerStatePath = '',
    }}, 120)
    local renamed = assert(Readiness.current(tracker, uuid, 1))
    assert(renamed.controllerPath == '' and renamed.playerStatePath == '')

    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 2,
      controllerPath = '', playerStatePath = '',
    }}, 130)
    local next_generation = assert(Readiness.current(tracker, uuid, 2))
    assert(next_generation.controllerPath == '' and next_generation.playerStatePath == '')

    local other = '22222222-2222-4222-8222-222222222222'
    Readiness.sync(tracker, {{
      uuid = other, originalName = 'Ty', connectionGeneration = 2,
      controllerPath = '', playerStatePath = '',
    }}, 140)
    local other_entry = assert(Readiness.current(tracker, other, 2))
    assert(other_entry.controllerPath == '' and other_entry.playerStatePath == '')
  `);
});

test('one exact-session repair is admitted during a retry burst window', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = '', playerStatePath = '',
    }}, 100)
    local allowed, decision, retry_at = Readiness.repair_decision(
      tracker, uuid, 1, 1000, 5000, 'paths_unavailable')
    assert(allowed == true and decision == 'attempt' and retry_at == 6000)
    for _, now in ipairs({1025, 1050, 1100, 2000, 5999}) do
      allowed, decision, retry_at = Readiness.repair_decision(
        tracker, uuid, 1, now, 5000, 'retry_burst')
      assert(allowed == false and decision == 'deferred' and retry_at == 6000)
    end
    local snapshot = Readiness.snapshot(tracker)
    assert(snapshot.repairAttempts == 1 and snapshot.repairDeferrals == 5)
    assert(snapshot.current[1].repairAttempts == 1)
    assert(snapshot.current[1].repairDeferrals == 5)
    local repair_snapshot = Readiness.repair_snapshot(tracker, 64)
    assert(repair_snapshot.total == 1 and repair_snapshot.truncated == 0)
    assert(repair_snapshot.sessions[1].repairAttempts == 1)
    assert(repair_snapshot.sessions[1].controllerPath == nil)
    assert(repair_snapshot.sessions[1].playerStatePath == nil)
    allowed = Readiness.repair_decision(tracker, uuid, 1, 6000, 5000, 'next_window')
    assert(allowed == true)
    assert(Readiness.snapshot(tracker).repairAttempts == 2)
  `);
});

test('controller replacement demotes readiness and tracker persists plain data only', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    local raw = {IsValid = function() return true end}
    Readiness.sync(tracker, {{
      uuid = uuid, connectionGeneration = 1,
      controllerPath = 'Controller_1', playerStatePath = 'State_1', rawObject = raw,
    }}, 100)
    Readiness.note_check(tracker, uuid, 1, true, nil, 110)
    Readiness.sync(tracker, {{
      uuid = uuid, connectionGeneration = 1,
      controllerPath = 'Controller_Replacement', playerStatePath = 'State_Replacement', rawObject = raw,
    }}, 120)
    local entry = Readiness.current(tracker, uuid, 1)
    assert(entry.state == 'controller_resolved')
    assert(entry.rawObject == nil and tracker.rawObject == nil)
    local snapshot = Readiness.snapshot(tracker)
    assert(snapshot.current[1].rawObject == nil)
  `);
});

test('non-string UObject-like path values clear instead of being stringified or retained', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = 'Controller_1', playerStatePath = 'State_1',
    }}, 100)
    Readiness.note_check(tracker, uuid, 1, true, nil, 110)
    local raw = {IsValid = function() return true end}
    local incoming = {
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = raw, playerStatePath = raw,
    }
    Readiness.sync(tracker, {incoming}, 120)
    local entry = assert(Readiness.current(tracker, uuid, 1))
    assert(entry.controllerPath == '' and entry.playerStatePath == '')
    assert(incoming.controllerPath == '' and incoming.playerStatePath == '')
    assert(type(entry.controllerPath) == 'string' and type(entry.playerStatePath) == 'string')
  `);
});

test('raw address strings are rejected as paths', () => {
  execute(`
    local tracker = Readiness.new()
    local uuid = '11111111-1111-4111-8111-111111111111'
    Readiness.sync(tracker, {{
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = 'Controller_1', playerStatePath = 'State_1',
    }}, 100)
    Readiness.note_check(tracker, uuid, 1, true, nil, 110)
    local incoming = {
      uuid = uuid, originalName = 'Ty', connectionGeneration = 1,
      controllerPath = '0x000001DEADBEEF00', playerStatePath = '0x000001DEADBEEF10',
    }
    Readiness.sync(tracker, {incoming}, 120)
    local entry = assert(Readiness.current(tracker, uuid, 1))
    assert(entry.controllerPath == '' and entry.playerStatePath == '')
    assert(incoming.controllerPath == '' and incoming.playerStatePath == '')
  `);
});
