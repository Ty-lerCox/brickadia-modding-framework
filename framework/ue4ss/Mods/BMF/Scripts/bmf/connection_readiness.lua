local M = {}

local VALID_STATES = {
  joined = true,
  controller_resolved = true,
  native_callable = true,
  disconnecting = true,
  disconnected = true,
}

local MAX_PLAIN_PATH_BYTES = 1024

local function normalized_uuid(value)
  if type(value) ~= "string" then return "" end
  local normalized = value:match("^%s*(.-)%s*$"):lower()
  return normalized:match(
    "^(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or ""
end

local function normalized_generation(value)
  local generation = tonumber(value) or 0
  if generation < 1 or generation % 1 ~= 0 then
    return 0
  end
  return math.floor(generation)
end

local function plain_path(value)
  if value == nil then return "", "blank" end
  if type(value) ~= "string" then return "", "invalid" end
  local path = value:match("^%s*(.-)%s*$")
  if path == "" then return "", "blank" end
  if #path > MAX_PLAIN_PATH_BYTES or path:find("[%c]") ~= nil
      or path:match("^0[xX]%x+$") ~= nil then
    return "", "invalid"
  end
  return path, "value"
end

local function normalized_player_name(player)
  if type(player) ~= "table" then return "" end
  for _, field in ipairs({
    "originalName",
    "username",
    "userName",
    "playerName",
    "displayName",
    "name",
  }) do
    local value = player[field]
    if type(value) == "string" then
      local normalized = value:match("^%s*(.-)%s*$"):lower()
      if normalized ~= "" and #normalized <= 128
          and normalized:find("[%c]") == nil then
        return normalized
      end
    end
  end
  return ""
end

local function clear_paths(tracker, entry)
  local had_paths = entry.controllerPath ~= "" or entry.playerStatePath ~= ""
  entry.controllerPath = ""
  entry.playerStatePath = ""
  entry.pathsValidated = false
  entry.pathPreserved = false
  if had_paths then
    tracker.pathClears = (tonumber(tracker.pathClears) or 0) + 1
  end
  return had_paths
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
      identityName = "",
      pathsValidated = false,
      pathPreserved = false,
      preservedSyncs = 0,
      pathReuses = 0,
      repairAttempts = 0,
      repairDeferrals = 0,
      repairWindowStartedAtMs = 0,
      repairNextAllowedAtMs = 0,
      lastRepairReason = "",
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
    identityName = tostring(entry.identityName or ""),
    pathsValidated = entry.pathsValidated == true,
    pathPreserved = entry.pathPreserved == true,
    preservedSyncs = tonumber(entry.preservedSyncs) or 0,
    pathReuses = tonumber(entry.pathReuses) or 0,
    repairAttempts = tonumber(entry.repairAttempts) or 0,
    repairDeferrals = tonumber(entry.repairDeferrals) or 0,
    repairWindowStartedAtMs = tonumber(entry.repairWindowStartedAtMs) or 0,
    repairNextAllowedAtMs = tonumber(entry.repairNextAllowedAtMs) or 0,
    lastRepairReason = tostring(entry.lastRepairReason or ""),
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
    pathPreservations = 0,
    pathReplacements = 0,
    pathClears = 0,
    pathReuses = 0,
    repairAttempts = 0,
    repairDeferrals = 0,
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
          clear_paths(tracker, previous)
          transition(tracker, previous, "disconnecting", now_ms)
          transition(tracker, previous, "disconnected", now_ms)
        end
      end
      bucket.currentGeneration = generation

      local controller_path, controller_status = plain_path(player.controllerPath)
      local player_state_path, player_state_status = plain_path(player.playerStatePath)
      local incoming_name = normalized_player_name(player)
      local identity_matches = entry.identityName ~= ""
        and incoming_name ~= ""
        and entry.identityName == incoming_name
      local complete_paths = controller_status == "value"
        and player_state_status == "value"
      local both_blank = controller_status == "blank"
        and player_state_status == "blank"
      local paths_changed = false

      if complete_paths then
        paths_changed = entry.controllerPath ~= controller_path
          or entry.playerStatePath ~= player_state_path
          or (entry.identityName ~= "" and entry.identityName ~= incoming_name)
        if paths_changed and (entry.controllerPath ~= "" or entry.playerStatePath ~= "") then
          tracker.pathReplacements = (tonumber(tracker.pathReplacements) or 0) + 1
        end
        entry.controllerPath = controller_path
        entry.playerStatePath = player_state_path
        entry.identityName = incoming_name
        entry.pathPreserved = false
        if paths_changed then entry.pathsValidated = false end
        player.controllerPath = controller_path
        player.playerStatePath = player_state_path
        player.bmfControllerPathPreserved = false
      elseif both_blank
          and identity_matches
          and entry.pathsValidated == true
          and entry.controllerPath ~= ""
          and entry.playerStatePath ~= "" then
        -- Snapshot writers can temporarily omit controller metadata while the
        -- exact UUID/generation remains live. Retain only the previously
        -- lifecycle-validated plain strings, never a UObject wrapper/address.
        player.controllerPath = entry.controllerPath
        player.playerStatePath = entry.playerStatePath
        player.bmfControllerPathPreserved = true
        entry.pathPreserved = true
        entry.preservedSyncs = (tonumber(entry.preservedSyncs) or 0) + 1
        tracker.pathPreservations = (tonumber(tracker.pathPreservations) or 0) + 1
      else
        paths_changed = clear_paths(tracker, entry)
        entry.identityName = incoming_name
        player.controllerPath = ""
        player.playerStatePath = ""
        player.bmfControllerPathPreserved = false
      end
      entry.updatedAtMs = tonumber(now_ms) or 0

      if entry.controllerPath ~= "" and entry.playerStatePath ~= "" then
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
        clear_paths(tracker, entry)
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
    if entry.controllerPath == "" or entry.playerStatePath == "" then
      return false, "paths_unavailable"
    end
    transition(tracker, entry, "native_callable", now_ms)
    entry.pathsValidated = true
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
  clear_paths(tracker, entry)
  transition(tracker, entry, "disconnecting", now_ms)
  transition(tracker, entry, "disconnected", now_ms)
  if tonumber(bucket.currentGeneration) == generation then bucket.currentGeneration = 0 end
  return true
end

function M.invalidate_paths(tracker, uuid_value, generation_value, reason, now_ms)
  local entry, current_reason = M.current(tracker, uuid_value, generation_value)
  if entry == nil then return false, current_reason end
  local uuid = normalized_uuid(uuid_value)
  local generation = normalized_generation(generation_value)
  local bucket = tracker.byUuid[uuid]
  local retained = bucket.generations[generation]
  clear_paths(tracker, retained)
  retained.lastFailure = tostring(reason or "paths_invalidated")
  retained.updatedAtMs = tonumber(now_ms) or 0
  retained.readyAtMs = 0
  transition(tracker, retained, "joined", now_ms)
  return true, "paths_invalidated"
end

function M.note_path_reuse(tracker, uuid_value, generation_value, now_ms)
  local uuid = normalized_uuid(uuid_value)
  local generation = normalized_generation(generation_value)
  local bucket = type(tracker) == "table" and tracker.byUuid[uuid] or nil
  local entry = type(bucket) == "table" and bucket.generations[generation] or nil
  if type(entry) ~= "table" or tonumber(bucket.currentGeneration) ~= generation
      or entry.pathsValidated ~= true or entry.pathPreserved ~= true then
    return false
  end
  entry.pathPreserved = false
  entry.pathReuses = (tonumber(entry.pathReuses) or 0) + 1
  entry.updatedAtMs = tonumber(now_ms) or entry.updatedAtMs or 0
  tracker.pathReuses = (tonumber(tracker.pathReuses) or 0) + 1
  return true
end

function M.repair_decision(tracker, uuid_value, generation_value, now_ms, window_ms, reason)
  local uuid = normalized_uuid(uuid_value)
  local generation = normalized_generation(generation_value)
  local now = math.max(0, tonumber(now_ms) or 0)
  local window = math.max(1000, tonumber(window_ms) or 0)
  local bucket = type(tracker) == "table" and tracker.byUuid[uuid] or nil
  local entry = type(bucket) == "table" and bucket.generations[generation] or nil
  if uuid == "" or generation == 0 or type(entry) ~= "table"
      or tonumber(bucket.currentGeneration) ~= generation
      or entry.state == "disconnecting" or entry.state == "disconnected" then
    return false, "invalid_session", 0
  end

  local next_allowed = tonumber(entry.repairNextAllowedAtMs) or 0
  if next_allowed > now then
    entry.repairDeferrals = (tonumber(entry.repairDeferrals) or 0) + 1
    entry.lastRepairReason = tostring(reason or "repair_deferred")
    tracker.repairDeferrals = (tonumber(tracker.repairDeferrals) or 0) + 1
    return false, "deferred", next_allowed
  end

  entry.repairAttempts = (tonumber(entry.repairAttempts) or 0) + 1
  entry.repairWindowStartedAtMs = now
  entry.repairNextAllowedAtMs = now + window
  entry.lastRepairReason = tostring(reason or "repair_attempt")
  tracker.repairAttempts = (tonumber(tracker.repairAttempts) or 0) + 1
  return true, "attempt", entry.repairNextAllowedAtMs
end

function M.repair_snapshot(tracker, max_sessions)
  local limit = math.max(1, math.min(64, math.floor(tonumber(max_sessions) or 64)))
  local sessions = {}
  local total = 0
  for uuid, bucket in pairs(type(tracker) == "table" and tracker.byUuid or {}) do
    local generation = tonumber(bucket.currentGeneration) or 0
    local entry = generation > 0 and bucket.generations[generation] or nil
    if type(entry) == "table"
        and ((tonumber(entry.repairAttempts) or 0) > 0
          or (tonumber(entry.repairDeferrals) or 0) > 0) then
      total = total + 1
      if #sessions < limit then
        sessions[#sessions + 1] = {
          uuid = tostring(uuid),
          generation = generation,
          repairAttempts = tonumber(entry.repairAttempts) or 0,
          repairDeferrals = tonumber(entry.repairDeferrals) or 0,
          repairWindowStartedAtMs = tonumber(entry.repairWindowStartedAtMs) or 0,
          repairNextAllowedAtMs = tonumber(entry.repairNextAllowedAtMs) or 0,
          lastRepairReason = tostring(entry.lastRepairReason or ""),
        }
      end
    end
  end
  table.sort(sessions, function(left, right)
    if left.uuid == right.uuid then return left.generation < right.generation end
    return left.uuid < right.uuid
  end)
  return {
    sessions = sessions,
    total = total,
    truncated = math.max(0, total - #sessions),
  }
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
    pathPreservations = tonumber(tracker.pathPreservations) or 0,
    pathReplacements = tonumber(tracker.pathReplacements) or 0,
    pathClears = tonumber(tracker.pathClears) or 0,
    pathReuses = tonumber(tracker.pathReuses) or 0,
    repairAttempts = tonumber(tracker.repairAttempts) or 0,
    repairDeferrals = tonumber(tracker.repairDeferrals) or 0,
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
