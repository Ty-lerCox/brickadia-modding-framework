local Plugin = {
  name = "NoSpawnItemApplicator",
  enforcement = nil,
  liveHook = nil,
  native = {
    controlPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/applicator-func-blocker-control.txt",
    statusPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/applicator-func-blocker-status.txt",
    lastWrite = "",
    lastWriteCode = "",
    lastWriteReason = "",
    writeCount = 0,
  },
  policy = {
    roleAssignments = nil,
    roleAssignmentsPath = "",
    roleAssignmentsCode = "",
    roleAssignmentsPlayerCount = 0,
    roleAssignmentsLoadedAt = 0,
    contextPlayers = {},
    contextPlayerSources = {},
    allowedContexts = {},
    allowedContextCount = 0,
    lastDecision = "",
    lastActor = "",
    lastMatchedRole = "",
    lastContext = "",
  },
  feedback = {
    path = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/applicator-func-blocker-events.tsv",
    cursor = 0,
    processed = {},
    delivered = 0,
    broadcast = 0,
    missed = 0,
    allowed = 0,
    lastEvent = "",
    lastDelivery = "",
  },
}

local POLICY = {
  deniedComponents = { "SpawnItem", "ItemSpawn" },
  allowedRoles = { "Admin" },
  allowedPlayers = {},
  allowedContexts = {},
  allowSinglePlayerContextLearning = true,
}

local DESIRED_DEFAULT_ROLE = {
  name = "Default",
  permissions = {
    { name = "BR.Permission.Building", state = "Allowed" },
    { name = "BR.Permission.Building.Applicator", state = "Allowed" },
    { name = "BR.Permission.Building.Applicator.EditBricks", state = "Allowed" },
    { name = "BR.Permission.Building.Applicator.EditEntities", state = "Allowed" },
    { name = "BR.Permission.SpawnItems", state = "Forbidden" },
  },
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parseArgs(raw)
  local args = {}
  for key, quoted in tostring(raw or ""):gmatch("([%w_.%-]+)%s*=%s*\"([^\"]*)\"") do
    args[key:lower()] = quoted
  end
  for key, value in tostring(raw or ""):gmatch("([%w_.%-]+)%s*=%s*([^%s]+)") do
    local lowered = key:lower()
    if args[lowered] == nil then
      args[lowered] = value
    end
  end
  return args
end

local function fileSize(path)
  local handle = io.open(path, "rb")
  if not handle then
    return 0
  end
  local size = handle:seek("end") or 0
  handle:close()
  return size
end

local function readText(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return text
end

local function writeText(path, text)
  local handle = io.open(path, "wb")
  if not handle then
    return false
  end
  handle:write(tostring(text or ""))
  handle:close()
  return true
end

local function normalizeList(value)
  local items = {}
  local seen = {}
  local function add(item)
    local text = trim(item)
    if text == "" then
      return
    end
    local key = text:lower()
    if seen[key] then
      return
    end
    seen[key] = true
    items[#items + 1] = text
  end

  if type(value) == "string" then
    for item in value:gmatch("[^,|]+") do
      add(item)
    end
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      add(item)
    end
  end
  return items
end

local function normalizeContext(value)
  local text = trim(value):lower()
  if text == "" then
    return ""
  end
  local hex = text:match("^0x([0-9a-f]+)$") or text:match("^([0-9a-f]+)$")
  if not hex then
    return ""
  end
  hex = hex:gsub("^0+", "")
  if hex == "" then
    return ""
  end
  return "0x" .. hex:upper()
end

local function idFromPlayer(player)
  if type(player) == "table" then
    return trim(player.uuid or player.id or player.playerId or player.userId)
  end
  return trim(player)
end

local function listText(items)
  local copy = {}
  for _, item in ipairs(items or {}) do
    copy[#copy + 1] = tostring(item)
  end
  table.sort(copy)
  return table.concat(copy, "|")
end

local function parseKvText(text)
  local values = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key then
      values[key] = value
    end
  end
  return values
end

local function readNewBlockEventChunk()
  local path = Plugin.feedback.path
  local size = fileSize(path)
  if size <= 0 then
    Plugin.feedback.cursor = 0
    return ""
  end
  if Plugin.feedback.cursor > size then
    Plugin.feedback.cursor = 0
  end
  if Plugin.feedback.cursor == size then
    return ""
  end

  local handle = io.open(path, "rb")
  if not handle then
    return ""
  end
  handle:seek("set", Plugin.feedback.cursor)
  local chunk = handle:read("*a") or ""
  Plugin.feedback.cursor = handle:seek("cur") or size
  handle:close()
  return chunk
end

local function parseEventLine(line)
  local event = {}
  for key, value in tostring(line or ""):gmatch("([%w_]+)=([^\t\r\n]*)") do
    event[key] = value
  end
  return event
end

local function loadPluginConfig(BMF)
  if not BMF.storage or type(BMF.storage.readConfig) ~= "function" then
    return
  end
  local loaded = BMF.storage.readConfig()
  if not loaded or not loaded.ok or type(loaded.data) ~= "table" or type(loaded.data.value) ~= "table" then
    return
  end

  local config = loaded.data.value
  local policy = type(config.policy) == "table" and config.policy or config
  local allowed_roles = normalizeList(policy.allowedRoles or policy.roles)
  local allowed_players = normalizeList(policy.allowedPlayers or policy.players)
  local allowed_contexts = normalizeList(policy.allowedContexts or policy.contexts)

  if #allowed_roles > 0 then
    POLICY.allowedRoles = allowed_roles
  end
  if #allowed_players > 0 then
    POLICY.allowedPlayers = allowed_players
  end
  if #allowed_contexts > 0 then
    POLICY.allowedContexts = allowed_contexts
  end
  if type(policy.allowSinglePlayerContextLearning) == "boolean" then
    POLICY.allowSinglePlayerContextLearning = policy.allowSinglePlayerContextLearning
  end
end

local function refreshRoleAssignments(BMF, force)
  local now = os.time()
  if not force
    and Plugin.policy.roleAssignments ~= nil
    and (now - (Plugin.policy.roleAssignmentsLoadedAt or 0)) < 5 then
    return Plugin.policy.roleAssignments
  end

  if not BMF.permissions or type(BMF.permissions.loadRoleAssignments) ~= "function" then
    Plugin.policy.roleAssignmentsCode = "ROLE_ASSIGNMENTS_API_UNAVAILABLE"
    return nil
  end

  local loaded = BMF.permissions.loadRoleAssignments()
  Plugin.policy.roleAssignmentsLoadedAt = now
  Plugin.policy.roleAssignmentsCode = tostring(loaded and loaded.code or "")
  if loaded and loaded.ok and loaded.data then
    Plugin.policy.roleAssignments = loaded.data.assignments
    Plugin.policy.roleAssignmentsPath = tostring(loaded.data.path or "")
    Plugin.policy.roleAssignmentsPlayerCount = tonumber(loaded.data.playerCount) or 0
    return Plugin.policy.roleAssignments
  end
  return nil
end

local function playerHasAllowedId(player)
  local uuid = idFromPlayer(player):lower()
  if uuid == "" then
    return false
  end
  for _, allowed in ipairs(POLICY.allowedPlayers or {}) do
    if trim(allowed):lower() == uuid then
      return true
    end
  end
  return false
end

local function playerRoleDecision(BMF, player)
  local uuid = idFromPlayer(player)
  if uuid == "" then
    return false, {}, ""
  end
  local assignments = refreshRoleAssignments(BMF, false)
  if not assignments then
    return false, {}, ""
  end

  local resolved = BMF.permissions.getPlayerRoles(assignments, uuid)
  local roles = resolved and resolved.data and resolved.data.roles or {}
  local role_map = {}
  for _, role in ipairs(roles) do
    role_map[tostring(role):lower()] = tostring(role)
  end

  for _, allowed_role in ipairs(POLICY.allowedRoles or {}) do
    local matched = role_map[tostring(allowed_role):lower()]
    if matched then
      return true, roles, matched
    end
  end
  return false, roles, ""
end

local function playerAllowed(BMF, player)
  if playerHasAllowedId(player) then
    return true, {
      decision = "allowed-player-id",
      roles = {},
      matchedRole = "",
    }
  end

  local role_allowed, roles, matched_role = playerRoleDecision(BMF, player)
  if role_allowed then
    return true, {
      decision = "allowed-role",
      roles = roles,
      matchedRole = matched_role,
    }
  end

  return false, {
    decision = "denied-role-policy",
    roles = roles,
    matchedRole = "",
  }
end

local function playersList(BMF)
  local listed = BMF.players and BMF.players.list and BMF.players.list() or nil
  if listed and listed.ok and listed.data and type(listed.data.players) == "table" then
    return listed.data.players, listed
  end
  return {}, listed
end

local function findPlayerById(players, uuid)
  local wanted = trim(uuid):lower()
  if wanted == "" then
    return nil
  end
  for _, player in ipairs(players or {}) do
    if idFromPlayer(player):lower() == wanted then
      return player
    end
  end
  return nil
end

local function resolveEventPlayer(BMF, event)
  local players = playersList(BMF)
  local context = normalizeContext(event.context)
  local known_uuid = Plugin.policy.contextPlayers[context]
  if known_uuid then
    return findPlayerById(players, known_uuid) or { uuid = known_uuid }, "known-context"
  end

  if context ~= "" and POLICY.allowSinglePlayerContextLearning and #players == 1 then
    local player = players[1]
    local uuid = idFromPlayer(player)
    if uuid ~= "" then
      Plugin.policy.contextPlayers[context] = uuid
      Plugin.policy.contextPlayerSources[context] = "single-live-player"
      return player, "single-live-player"
    end
  end

  return nil, #players > 1 and "ambiguous-multiple-players" or "no-live-player"
end

local function contextAllowedByStaticPolicy(context)
  local normalized = normalizeContext(context)
  if normalized == "" then
    return false
  end
  for _, allowed in ipairs(POLICY.allowedContexts or {}) do
    if normalizeContext(allowed) == normalized then
      return true
    end
  end
  return false
end

local function collectAllowedContexts(BMF)
  local contexts = {}
  local seen = {}
  local function add(context)
    local normalized = normalizeContext(context)
    if normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      contexts[#contexts + 1] = normalized
    end
  end

  for _, context in ipairs(POLICY.allowedContexts or {}) do
    add(context)
  end

  local players = playersList(BMF)
  for context, uuid in pairs(Plugin.policy.contextPlayers or {}) do
    local player = findPlayerById(players, uuid)
    if player then
      local allowed = playerAllowed(BMF, player)
      if allowed then
        add(context)
      end
    end
  end

  table.sort(contexts)
  return contexts
end

local function writeNativePolicy(BMF, reason)
  local raw = readText(Plugin.native.controlPath)
  if not raw or trim(raw) == "" then
    Plugin.native.lastWriteCode = "CONTROL_NOT_FOUND"
    Plugin.native.lastWriteReason = tostring(reason or "")
    return false
  end

  local contexts = collectAllowedContexts(BMF)
  local lines = {}
  for line in raw:gmatch("[^\r\n]+") do
    local key = line:match("^%s*([%w_]+)%s*=")
    if key ~= "allowed_context" and key ~= "allow_context" then
      lines[#lines + 1] = line
    end
  end
  for _, context in ipairs(contexts) do
    lines[#lines + 1] = "allowed_context=" .. context
  end

  local desired = table.concat(lines, "\n") .. "\n"
  Plugin.policy.allowedContexts = contexts
  Plugin.policy.allowedContextCount = #contexts

  if desired == raw then
    Plugin.native.lastWriteCode = "UNCHANGED"
    Plugin.native.lastWriteReason = tostring(reason or "")
    return true
  end

  if not writeText(Plugin.native.controlPath, desired) then
    Plugin.native.lastWriteCode = "CONTROL_WRITE_FAILED"
    Plugin.native.lastWriteReason = tostring(reason or "")
    return false
  end

  Plugin.native.lastWrite = os.date("!%Y-%m-%dT%H:%M:%SZ")
  Plugin.native.lastWriteCode = "OK"
  Plugin.native.lastWriteReason = tostring(reason or "")
  Plugin.native.writeCount = Plugin.native.writeCount + 1
  return true
end

local function evaluateEventPolicy(BMF, event)
  local context = normalizeContext(event.context)
  local player, source = resolveEventPlayer(BMF, event)
  local allowed = false
  local data = {
    context = context,
    player = player,
    playerSource = source,
    decision = "",
    roles = {},
    matchedRole = "",
  }

  if contextAllowedByStaticPolicy(context) then
    allowed = true
    data.decision = "allowed-context"
  elseif player then
    allowed, data = playerAllowed(BMF, player)
    data.context = context
    data.player = player
    data.playerSource = source
  else
    data.decision = "denied-unresolved-player"
  end

  Plugin.policy.lastDecision = tostring(data.decision or "")
  Plugin.policy.lastActor = player and idFromPlayer(player) or ""
  Plugin.policy.lastMatchedRole = tostring(data.matchedRole or "")
  Plugin.policy.lastContext = context
  return allowed, data
end

local function feedbackMessage(event, decision)
  local reason = tostring(event.reason or "")
  if decision and decision.allowed then
    return "BMF Item Spawn is allowed for your role. I enabled this Applicator context; try applying it again."
  end
  if decision and decision.decision == "denied-unresolved-player" then
    return "BMF blocked Item Spawn: the server could not safely verify the Applicator user's role."
  end
  if reason == "ItemSpawnDenied" then
    return "BMF blocked Item Spawn: your roles do not allow item-spawner components on this server."
  end
  return "BMF blocked that Applicator component: this server policy does not allow it."
end

local function deliverFeedback(BMF, event, decision)
  local message = feedbackMessage(event, decision)
  local players = playersList(BMF)
  local target = decision and decision.player or nil

  Plugin.feedback.lastEvent = "block_id=" .. tostring(event.block_id or event.policy_id or "") ..
    " component=" .. tostring(event.component or "") ..
    " reason=" .. tostring(event.reason or "") ..
    " decision=" .. tostring(decision and decision.decision or "")

  if target then
    local whispered = BMF.chat.whisper(target, message)
    if whispered.ok then
      Plugin.feedback.delivered = Plugin.feedback.delivered + 1
      Plugin.feedback.lastDelivery = "whisper:" .. idFromPlayer(target)
    else
      Plugin.feedback.missed = Plugin.feedback.missed + 1
      Plugin.feedback.lastDelivery = "whisper_failed:" .. tostring(whispered.code or "")
    end
    return whispered
  end

  if #players == 1 then
    local whispered = BMF.chat.whisper(players[1], message)
    if whispered.ok then
      Plugin.feedback.delivered = Plugin.feedback.delivered + 1
      Plugin.feedback.lastDelivery = "whisper:" .. idFromPlayer(players[1])
    else
      Plugin.feedback.missed = Plugin.feedback.missed + 1
      Plugin.feedback.lastDelivery = "whisper_failed:" .. tostring(whispered.code or "")
    end
    return whispered
  end

  if BMF.chat and type(BMF.chat.broadcast) == "function" then
    local broadcast = BMF.chat.broadcast(message)
    if broadcast.ok then
      Plugin.feedback.broadcast = Plugin.feedback.broadcast + 1
      Plugin.feedback.lastDelivery = "broadcast:" .. tostring(#players)
    else
      Plugin.feedback.missed = Plugin.feedback.missed + 1
      Plugin.feedback.lastDelivery = "broadcast_failed:" .. tostring(broadcast.code or "")
    end
    return broadcast
  end

  Plugin.feedback.missed = Plugin.feedback.missed + 1
  Plugin.feedback.lastDelivery = "no_live_player"
  return BMF.result(false, "NO_LIVE_PLAYER", "No live player available for applicator denial feedback", {
    message = message,
  })
end

local function pollNativeFeedback(BMF)
  local chunk = readNewBlockEventChunk()
  if chunk == "" then
    return
  end

  for line in chunk:gmatch("[^\r\n]+") do
    local event = parseEventLine(line)
    if event.event == "block" then
      local key = tostring(event.block_id or event.policy_id or "") .. "|" .. tostring(event.context or "") .. "|" .. tostring(event.component or "")
      if not Plugin.feedback.processed[key] then
        Plugin.feedback.processed[key] = true
        local allowed, decision = evaluateEventPolicy(BMF, event)
        decision.allowed = allowed
        if allowed then
          Plugin.feedback.allowed = Plugin.feedback.allowed + 1
          writeNativePolicy(BMF, "allowed-blocked-context")
        end
        BMF.audit.record("applicator.component.block_feedback", {
          event = event,
          decision = {
            allowed = allowed,
            code = decision.decision,
            context = decision.context,
            player = decision.player and idFromPlayer(decision.player) or "",
            playerSource = decision.playerSource or "",
            roles = decision.roles or {},
            matchedRole = decision.matchedRole or "",
          },
        })
        deliverFeedback(BMF, event, decision)
      end
    elseif event.event == "allow" then
      Plugin.feedback.allowed = Plugin.feedback.allowed + 1
      Plugin.feedback.lastEvent = "allow_id=" .. tostring(event.allow_id or event.policy_id or "") ..
        " context=" .. tostring(event.context or "")
    end
  end
end

local function evaluateRolePolicy(BMF)
  return BMF.permissions.evaluateNoSpawnItemApplicator(DESIRED_DEFAULT_ROLE)
end

local function evaluateComponent(BMF, component, actor)
  return BMF.permissions.evaluateApplicatorComponentAccess({
    component = component,
    actor = actor,
    deniedComponents = POLICY.deniedComponents,
  })
end

local function liveRoleAdapterAvailable(BMF)
  return type(BMF.permissions.applyNoSpawnItemApplicator) == "function"
    or type(BMF.permissions.writeRoleSetup) == "function"
end

local function liveHookAvailable(BMF)
  return type(BMF.tools) == "table"
    and type(BMF.tools.onApplicatorComponentApply) == "function"
end

local function nativeStatus()
  local raw = readText(Plugin.native.statusPath)
  if not raw then
    return {}
  end
  return parseKvText(raw)
end

local function statusLines(BMF)
  local role = evaluateRolePolicy(BMF)
  local spawn_item = evaluateComponent(BMF, "SpawnItem")
  local light = evaluateComponent(BMF, "Light")
  local enforcement = Plugin.enforcement or {}
  local enforcement_data = enforcement.data or {}
  local live_hook = Plugin.liveHook or {}
  local hook_status = nil
  if type(BMF.tools) == "table"
    and type(BMF.tools.applicator) == "table"
    and type(BMF.tools.applicator.status) == "function" then
    hook_status = BMF.tools.applicator.status()
  end
  local hook_data = (hook_status and hook_status.data) or {}
  local native = nativeStatus()

  return {
    "policy=noSpawnItemApplicator",
    "allowed_roles=" .. listText(POLICY.allowedRoles),
    "allowed_players=" .. listText(POLICY.allowedPlayers),
    "allow_single_player_context_learning=" .. tostring(POLICY.allowSinglePlayerContextLearning == true),
    "allowed_context_count=" .. tostring(Plugin.policy.allowedContextCount or 0),
    "allowed_contexts=" .. listText(Plugin.policy.allowedContexts),
    "context_player_count=" .. tostring((function()
      local count = 0
      for _ in pairs(Plugin.policy.contextPlayers or {}) do
        count = count + 1
      end
      return count
    end)()),
    "last_policy_decision=" .. tostring(Plugin.policy.lastDecision or ""),
    "last_policy_actor=" .. tostring(Plugin.policy.lastActor or ""),
    "last_policy_matched_role=" .. tostring(Plugin.policy.lastMatchedRole or ""),
    "last_policy_context=" .. tostring(Plugin.policy.lastContext or ""),
    "role_assignments_code=" .. tostring(Plugin.policy.roleAssignmentsCode or ""),
    "role_assignments_path=" .. tostring(Plugin.policy.roleAssignmentsPath or ""),
    "role_assignments_player_count=" .. tostring(Plugin.policy.roleAssignmentsPlayerCount or 0),
    "role_compliant=" .. tostring(role.data and role.data.compliant or false),
    "safe_applicator_allowed=" .. tostring(role.data and role.data.safeApplicatorAllowed or false),
    "spawn_items_permission_state=" .. tostring(role.data and role.data.spawnItemsState or ""),
    "spawn_item_component_allowed=" .. tostring(spawn_item.data and spawn_item.data.allowed or false),
    "spawn_item_component_decision=" .. tostring(spawn_item.data and spawn_item.data.decision or ""),
    "light_component_allowed=" .. tostring(light.data and light.data.allowed or false),
    "live_role_adapter_available=" .. tostring(liveRoleAdapterAvailable(BMF)),
    "live_applicator_hook_available=" .. tostring(liveHookAvailable(BMF)),
    "live_hook_code=" .. tostring(live_hook.code or ""),
    "live_hook_registered=" .. tostring((live_hook.data and live_hook.data.hookRegistered) == true),
    "applicator_hook_registered=" .. tostring(hook_data.registered == true),
    "applicator_hook_handler_count=" .. tostring(hook_data.handlerCount or 0),
    "applicator_hook_denied_events=" .. tostring(hook_data.deniedEvents or 0),
    "applicator_hook_param_null_events=" .. tostring(hook_data.paramNullEvents or 0),
    "applicator_hook_last_component=" .. tostring((hook_data.lastEvent and hook_data.lastEvent.component) or ""),
    "applicator_hook_last_denied=" .. tostring((hook_data.lastEvent and hook_data.lastEvent.denied) == true),
    "applicator_hook_last_block_mode=" .. tostring((hook_data.lastEvent and hook_data.lastEvent.blockMode) or ""),
    "native_status_installed=" .. tostring(native.installed or ""),
    "native_status_blocks=" .. tostring(native.blocks or ""),
    "native_status_allowed_itemspawn=" .. tostring(native.allowed_itemspawn or ""),
    "native_status_allowed_context_count=" .. tostring(native.allowed_context_count or ""),
    "native_control_path=" .. tostring(Plugin.native.controlPath),
    "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode or ""),
    "native_policy_write_count=" .. tostring(Plugin.native.writeCount or 0),
    "native_policy_write_reason=" .. tostring(Plugin.native.lastWriteReason or ""),
    "feedback_event_path=" .. tostring(Plugin.feedback.path),
    "feedback_delivered=" .. tostring(Plugin.feedback.delivered),
    "feedback_broadcast=" .. tostring(Plugin.feedback.broadcast),
    "feedback_missed=" .. tostring(Plugin.feedback.missed),
    "feedback_allowed=" .. tostring(Plugin.feedback.allowed),
    "feedback_last_event=" .. tostring(Plugin.feedback.lastEvent),
    "feedback_last_delivery=" .. tostring(Plugin.feedback.lastDelivery),
    "enforcement_code=" .. tostring(enforcement.code or ""),
    "enforcement_ok=" .. tostring(enforcement.ok == true),
    "enforcement_written=" .. tostring(enforcement_data.written == true),
    "enforcement_changed=" .. tostring(enforcement_data.changed == true),
    "enforcement_restart_required=" .. tostring(enforcement_data.restartRequired == true),
    "enforcement_path=" .. tostring(enforcement_data.path or ""),
    "enforcement=role-setup-file",
  }
end

local function denyAttempt(BMF, access)
  local data = access.data or {}
  BMF.audit.record("applicator.component.denied", {
    component = data.component or "",
    componentKey = data.componentKey or "",
    matchedComponent = data.matchedComponent or "",
    actorUuid = data.actorUuid or "",
    actorName = data.actorName or "",
    decision = data.decision or "",
  })

  return BMF.result(false, "APPLICATOR_COMPONENT_DENIED", "Applicator component denied", data)
end

function Plugin.evaluateApplicatorAttempt(BMF, event)
  local payload = type(event) == "table" and event or {}
  local component = payload.component or payload.componentName or payload.name or payload.type
  local actor = payload.actor or payload.player
  local access = evaluateComponent(BMF, component, actor)
  if not access.ok then
    return access
  end
  if access.data and access.data.allowed == false then
    return denyAttempt(BMF, access)
  end
  return access
end

function Plugin.onApplicatorComponentApply(BMF, event)
  return Plugin.evaluateApplicatorAttempt(BMF, event)
end

function Plugin.onLoad(BMF)
  loadPluginConfig(BMF)
  refreshRoleAssignments(BMF, true)
  Plugin.feedback.cursor = fileSize(Plugin.feedback.path)

  Plugin.enforcement = BMF.permissions.enforceNoSpawnItemApplicator({
    backup = true,
  })
  if type(BMF.tools) == "table" and type(BMF.tools.onApplicatorComponentApply) == "function" then
    Plugin.liveHook = BMF.tools.onApplicatorComponentApply(function(event)
      return Plugin.onApplicatorComponentApply(BMF, event)
    end, {
      owner = Plugin.name,
    })
  end
  writeNativePolicy(BMF, "plugin-load")

  BMF.commands.register("bmf.nospawnitem.status", "Show no-spawn-item applicator guard status.", function()
    refreshRoleAssignments(BMF, true)
    writeNativePolicy(BMF, "status")
    return BMF.result(true, "OK", "NoSpawnItemApplicator status", {
      lines = statusLines(BMF),
    })
  end)

  BMF.commands.register("bmf.nospawnitem.check", "Evaluate an applicator component against the guard policy.", function(raw)
    local args = parseArgs(raw)
    local component = trim(args.component or args.name or args.type)
    if component == "" then
      component = "SpawnItem"
    end

    local access = evaluateComponent(BMF, component)
    if not access.ok then
      return access
    end

    return BMF.result(true, "OK", "Applicator component policy checked", {
      lines = {
        "component=" .. tostring(access.data and access.data.component or component),
        "component_key=" .. tostring(access.data and access.data.componentKey or ""),
        "allowed=" .. tostring(access.data and access.data.allowed or false),
        "decision=" .. tostring(access.data and access.data.decision or ""),
        "matched_component=" .. tostring(access.data and access.data.matchedComponent or ""),
      },
    })
  end)

  BMF.commands.register("bmf.nospawnitem.allow-context", "Temporarily allow an Applicator context address for ItemSpawn.", function(raw)
    local args = parseArgs(raw)
    local context = normalizeContext(args.context or args.address or args[1])
    if context == "" then
      return BMF.result(false, "INVALID_CONTEXT", "context=0x... is required")
    end
    POLICY.allowedContexts[#POLICY.allowedContexts + 1] = context
    writeNativePolicy(BMF, "manual-allow-context")
    return BMF.result(true, "OK", "Applicator context allowed", {
      lines = {
        "context=" .. context,
        "allowed_context_count=" .. tostring(Plugin.policy.allowedContextCount or 0),
        "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode or ""),
      },
    })
  end)

  local role = evaluateRolePolicy(BMF)
  local spawn_item = evaluateComponent(BMF, "SpawnItem")
  BMF.log("NoSpawnItemApplicator loaded role_compliant=" ..
    tostring(role.data and role.data.compliant or false) ..
    " spawn_item_allowed=" .. tostring(spawn_item.data and spawn_item.data.allowed or false) ..
    " allowed_roles=" .. listText(POLICY.allowedRoles) ..
    " enforcement_code=" .. tostring(Plugin.enforcement and Plugin.enforcement.code or "") ..
    " enforcement_written=" .. tostring(Plugin.enforcement and Plugin.enforcement.data and Plugin.enforcement.data.written == true) ..
    " live_hook=" .. tostring(liveHookAvailable(BMF)) ..
    " live_hook_code=" .. tostring(Plugin.liveHook and Plugin.liveHook.code or ""))
end

function Plugin.onTick(BMF)
  refreshRoleAssignments(BMF, false)
  pollNativeFeedback(BMF)
  writeNativePolicy(BMF, "tick")
end

return Plugin
