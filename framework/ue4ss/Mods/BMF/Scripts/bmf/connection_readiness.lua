local M = {}

local VALID_STATES = {
  joined = true,
  controller_resolved = true,
  native_callable = true,
  disconnecting = true,
  disconnected = true,
}

local function normalized_uuid(value)
  return tostring(value or ""):match("^%s*(.-)%s*$"):lower()
end

local function normalized_generation(value)
  local generation = tonumber(value) or 0
  if generation < 1 or generation % 1 ~= 0 then
    return 0
  end
  return math.floor(generation)
end

local function plain_path(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function transition(tracker, entry, next_state, now_ms)
  if not VALID_STATES[next_state] or entry.state == next_state then
    return false
  end
  local previous_state = entry.state
  if VALID_STATES[previous_state] then
    tracker.byState[previous_state] = math.max(
      0,
      (tonumber(tracker.byState[previous_state]) or 0) - 1)
  end
  entry.state = next_state
  entry.updatedAtMs = tonumber(now_ms) or 0
  tracker.transitions = (tonumber(tracker.transitions) or 0) + 1
  tracker.byState[next_state] = (tonumber(tracker.byState[next_state]) or 0) + 1
  return true
end

local function ensure_bucket(tracker, uuid)
  local bucket = tracker.byUuid[uuid]
  if type(bucket) ~= "table" then
    bucket = { currentGeneration = 0, generations = {} }
    tracker.byUuid[uuid] = bucket
  end
  return bucket
end

local function ensure_entry(tracker, uuid, generation, now_ms)
  local bucket = ensure_bucket(tracker, uuid)
  local entry = bucket.generations[generation]
  if type(entry) ~= "table" then
    entry = {
      uuid = uuid,
      generation = generation,
      state = "joined",
      controllerPath = "",
      playerStatePath = "",
      createdAtMs = tonumber(now_ms) or 0,
      updatedAtMs = tonumber(now_ms) or 0,
      readyAtMs = 0,
      readinessChecks = 0,
      readinessFailures = 0,
      lastFailure = "",
    }
    bucket.generations[generation] = entry
    tracker.entries = (tonumber(tracker.entries) or 0) + 1
    tracker.byState.joined = (tonumber(tracker.byState.joined) or 0) + 1
  end
  return bucket, entry
end

local function entry_copy(entry)
  if type(entry) ~= "table" then return nil end
  return {
    uuid = tostring(entry.uuid or ""),
    generation = tonumber(entry.generation) or 0,
    state = tostring(entry.state or "disconnected"),
    controllerPath = tostring(entry.controllerPath or ""),
    playerStatePath = tostring(entry.playerStatePath or ""),
    createdAtMs = tonumber(entry.createdAtMs) or 0,
    updatedAtMs = tonumber(entry.updatedAtMs) or 0,
    readyAtMs = tonumber(entry.readyAtMs) or 0,
    readinessChecks = tonumber(entry.readinessChecks) or 0,
    readinessFailures = tonumber(entry.readinessFailures) or 0,
    lastFailure = tostring(entry.lastFailure or ""),
  }
end

function M.new()
  return {
    byUuid = {},
    entries = 0,
    transitions = 0,
    syncs = 0,
    invalidRecords = 0,
    readinessChecks = 0,
    readinessFailures = 0,
    staleGenerationRejects = 0,
    disconnectedRejects = 0,
    byState = {
      joined = 0,
      controller_resolved = 0,
      native_callable = 0,
      disconnecting = 0,
      disconnected = 0,
    },
  }
end

function M.sync(tracker, players, now_ms)
  if type(tracker) ~= "table" then return false, "tracker_required" end
  players = type(players) == "table" and players or {}
  local seen = {}
  tracker.syncs = (tonumber(tracker.syncs) or 0) + 1

  for _, player in ipairs(players) do
    local uuid = normalized_uuid(player and (player.uuid or player.id or player.playerId))
    local generation = normalized_generation(player and player.connectionGeneration)
    if uuid == "" or generation == 0 then
      tracker.invalidRecords = (tonumber(tracker.invalidRecords) or 0) + 1
    else
      local bucket, entry = ensure_entry(tracker, uuid, generation, now_ms)
      seen[uuid .. ":" .. tostring(generation)] = true

      for previous_generation, previous in pairs(bucket.generations) do
        if previous_generation ~= generation
            and previous.state ~= "disconnected"
            and previous.state ~= "disconnecting" then
          transition(tracker, previous, "disconnecting", now_ms)
          transition(tracker, previous, "disconnected", now_ms)
        end
      end
      bucket.currentGeneration = generation

      local controller_path = plain_path(player.controllerPath)
      local player_state_path = plain_path(player.playerStatePath)
      local paths_changed = entry.controllerPath ~= controller_path
        or entry.playerStatePath ~= player_state_path
      entry.controllerPath = controller_path
      entry.playerStatePath = player_state_path
      entry.updatedAtMs = tonumber(now_ms) or 0

      if controller_path ~= "" and player_state_path ~= "" then
        if paths_changed or entry.state == "joined" then
          transition(tracker, entry, "controller_resolved", now_ms)
          entry.readyAtMs = 0
        end
      elseif entry.state ~= "joined" then
        transition(tracker, entry, "joined", now_ms)
        entry.readyAtMs = 0
      end
    end
  end

  for uuid, bucket in pairs(tracker.byUuid) do
    local current = tonumber(bucket.currentGeneration) or 0
    if current > 0 and not seen[uuid .. ":" .. tostring(current)] then
      local entry = bucket.generations[current]
      if type(entry) == "table" and entry.state ~= "disconnected" then
        transition(tracker, entry, "disconnecting", now_ms)
        transition(tracker, entry, "disconnected", now_ms)
      end
      bucket.currentGeneration = 0
    end
  end
  return true
end

function M.current(tracker, uuid_value, generation_value)
  if type(tracker) ~= "table" then return nil, "tracker_required" end
  local uuid = normalized_uuid(uuid_value)
  local generation = normalized_generation(generation_value)
  if uuid == "" or generation == 0 then return nil, "invalid_identity" end
  local bucket = tracker.byUuid[uuid]
  if type(bucket) ~= "table" then return nil, "unknown_current_session" end
  if tonumber(bucket.currentGeneration) ~= generation then
    tracker.staleGenerationRejects = (tonumber(tracker.staleGenerationRejects) or 0) + 1
    return nil, "connection_generation_mismatch"
  end
  local entry = bucket.generations[generation]
  if type(entry) ~= "table" then return nil, "unknown_current_session" end
  if entry.state == "disconnecting" or entry.state == "disconnected" then
    tracker.disconnectedRejects = (tonumber(tracker.disconnectedRejects) or 0) + 1
    return nil, "disconnected"
  end
  return entry_copy(entry), "ok"
end

local function normalized_operation(operation)
  operation = type(operation) == "table" and operation or {}
  return {
    requestId = plain_path(operation.requestId),
    senderUuid = normalized_uuid(operation.senderUuid),
    connectionGeneration = normalized_generation(operation.connectionGeneration),
    acceptedAtMs = tonumber(operation.acceptedAtMs) or 0,
    absoluteDeadlineMs = tonumber(operation.absoluteDeadlineMs or operation.deadlineMs) or 0,
    operationType = plain_path(operation.operationType),
  }
end

function M.admission(tracker, operation, now_ms)
  local normalized = normalized_operation(operation)
  local now = tonumber(now_ms) or 0
  if normalized.requestId == "" then return false, "REQUEST_ID_REQUIRED", normalized end
  if normalized.senderUuid == "" then return false, "SENDER_UUID_REQUIRED", normalized end
  if normalized.connectionGeneration == 0 then
    return false, "CONNECTION_GENERATION_REQUIRED", normalized
  end
  if normalized.acceptedAtMs <= 0 then return false, "ACCEPTED_AT_REQUIRED", normalized end
  if normalized.absoluteDeadlineMs <= normalized.acceptedAtMs then
    return false, "DEADLINE_INVALID", normalized
  end
  if now >= normalized.absoluteDeadlineMs then return false, "DEADLINE_EXPIRED", normalized end
  if normalized.operationType == "" then return false, "OPERATION_TYPE_REQUIRED", normalized end
  local entry, reason = M.current(
    tracker,
    normalized.senderUuid,
    normalized.connectionGeneration)
  if not entry then
    if reason == "unknown_current_session" then reason = "unknown_session" end
    return false, string.upper(reason), normalized
  end
  return true, entry.state == "native_callable" and "native_callable" or "waiting", normalized
end

function M.execution_decision(tracker, operation, now_ms)
  local ok, state, normalized = M.admission(tracker, operation, now_ms)
  if not ok then
    if state == "DEADLINE_EXPIRED" then return "expire", state, normalized end
    return "reject", state, normalized
  end
  if state ~= "native_callable" then return "wait", "NATIVE_NOT_CALLABLE", normalized end
  return "execute", "NATIVE_CALLABLE", normalized
end

function M.note_check(tracker, uuid_value, generation_value, ok, reason, now_ms)
  local uuid = normalized_uuid(uuid_value)
  local generation = normalized_generation(generation_value)
  local bucket = type(tracker) == "table" and tracker.byUuid[uuid] or nil
  local entry = type(bucket) == "table" and bucket.generations[generation] or nil
  if type(entry) ~= "table" or tonumber(bucket.currentGeneration) ~= generation then
    return false, "unknown_current_session"
  end

  tracker.readinessChecks = (tonumber(tracker.readinessChecks) or 0) + 1
  entry.readinessChecks = (tonumber(entry.readinessChecks) or 0) + 1
  entry.updatedAtMs = tonumber(now_ms) or 0
  if ok == true then
    transition(tracker, entry, "native_callable", now_ms)
    entry.readyAtMs = tonumber(now_ms) or 0
    entry.lastFailure = ""
    return true, "native_callable"
  end

  tracker.readinessFailures = (tonumber(tracker.readinessFailures) or 0) + 1
  entry.readinessFailures = (tonumber(entry.readinessFailures) or 0) + 1
  entry.lastFailure = tostring(reason or "native_not_callable")
  if entry.controllerPath ~= "" and entry.playerStatePath ~= "" then
    transition(tracker, entry, "controller_resolved", now_ms)
  else
    transition(tracker, entry, "joined", now_ms)
  end
  entry.readyAtMs = 0
  return false, entry.lastFailure
end

function M.invalidate(tracker, uuid_value, generation_value, reason, now_ms)
  if type(tracker) ~= "table" then return false end
  local uuid = normalized_uuid(uuid_value)
  local generation = normalized_generation(generation_value)
  local bucket = tracker.byUuid[uuid]
  local entry = type(bucket) == "table" and bucket.generations[generation] or nil
  if type(entry) ~= "table" then return false end
  entry.lastFailure = tostring(reason or "invalidated")
  transition(tracker, entry, "disconnecting", now_ms)
  transition(tracker, entry, "disconnected", now_ms)
  if tonumber(bucket.currentGeneration) == generation then bucket.currentGeneration = 0 end
  return true
end

function M.snapshot(tracker)
  tracker = type(tracker) == "table" and tracker or M.new()
  local active = 0
  local current = {}
  for uuid, bucket in pairs(tracker.byUuid or {}) do
    local generation = tonumber(bucket.currentGeneration) or 0
    if generation > 0 then
      local entry = bucket.generations and bucket.generations[generation] or nil
      if type(entry) == "table" then
        active = active + 1
        current[#current + 1] = entry_copy(entry)
      end
    end
  end
  table.sort(current, function(left, right)
    if left.uuid == right.uuid then return left.generation < right.generation end
    return left.uuid < right.uuid
  end)
  return {
    active = active,
    entries = tonumber(tracker.entries) or 0,
    transitions = tonumber(tracker.transitions) or 0,
    syncs = tonumber(tracker.syncs) or 0,
    invalidRecords = tonumber(tracker.invalidRecords) or 0,
    readinessChecks = tonumber(tracker.readinessChecks) or 0,
    readinessFailures = tonumber(tracker.readinessFailures) or 0,
    staleGenerationRejects = tonumber(tracker.staleGenerationRejects) or 0,
    disconnectedRejects = tonumber(tracker.disconnectedRejects) or 0,
    byState = {
      joined = tonumber(tracker.byState and tracker.byState.joined) or 0,
      controller_resolved = tonumber(tracker.byState and tracker.byState.controller_resolved) or 0,
      native_callable = tonumber(tracker.byState and tracker.byState.native_callable) or 0,
      disconnecting = tonumber(tracker.byState and tracker.byState.disconnecting) or 0,
      disconnected = tonumber(tracker.byState and tracker.byState.disconnected) or 0,
    },
    current = current,
  }
end

return M
