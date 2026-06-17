local Plugin = {
  name = "InteractConsolePrefixGuard",
  policy = {
    adminRoles = { "Owner", "Admin" },
    ownerIds = {},
    savedDir = "",
    allowedPrefixes = { "buyweapon:" },
    allowedContexts = {},
    denyUnknown = true,
    allowEmpty = true,
    allowSinglePlayerContextLearning = true,
    proactivePrimeAllowedContexts = true,
    proactivePrimeIntervalSeconds = 2,
  },
  native = {
    controlPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/interact-prefix-guard-control.txt",
    statusPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/interact-prefix-guard-status.txt",
    eventPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/interact-prefix-guard-events.tsv",
    trace = true,
    cursor = 0,
    processed = {},
    lastWrite = "",
    lastWriteCode = "",
    lastWriteReason = "",
    writeCount = 0,
  },
  feedback = {
    enabled = true,
    message = "BMF blocked that Interactable console tag: your role can only use whitelisted prefixes.",
    adminRetryMessage = "BMF allowed that Interactable console tag for your role. Try applying it again.",
  },
  contextPlayers = {},
  contextPlayerSources = {},
  prime = {
    nextAt = 0,
    attempts = 0,
    successes = 0,
    clears = 0,
    lastCode = "",
    lastReason = "",
    lastContext = "",
    lastPlayer = "",
  },
  stats = {
    received = 0,
    allowed = 0,
    denied = 0,
    nativeAllowed = 0,
    nativeBlocked = 0,
    feedbackDelivered = 0,
    feedbackMissed = 0,
    lastDecision = "",
    lastPlayer = "",
    lastTag = "",
    lastMatchedPrefix = "",
    lastMatchedRole = "",
    lastContext = "",
    roleAssignmentsCode = "",
    roleAssignmentsPlayerCount = 0,
  },
  roleAssignments = nil,
  roleAssignmentsLoadedAt = 0,
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function percentDecode(value)
  local text = tostring(value or ""):gsub("+", " ")
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
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

local function parseEventLine(line)
  local event = {}
  for key, value in tostring(line or ""):gmatch("([%w_]+)=([^\t\r\n]*)") do
    event[key] = value
  end
  return event
end

local function playerId(player)
  if type(player) == "table" then
    return trim(player.uuid or player.id or player.playerId or player.playerID)
  end
  return trim(player)
end

local function playerName(player)
  if type(player) == "table" then
    return trim(player.username or player.name or player.displayName or player.playerName)
  end
  return ""
end

local function loadConfig(BMF)
  if not BMF.storage or type(BMF.storage.readConfig) ~= "function" then
    return
  end
  local loaded = BMF.storage.readConfig()
  if not loaded or not loaded.ok or type(loaded.data) ~= "table" or type(loaded.data.value) ~= "table" then
    return
  end

  local config = loaded.data.value
  local policy = type(config.policy) == "table" and config.policy or {}
  local admin_roles = normalizeList(policy.adminRoles or policy.bypassRoles)
  local owner_ids = normalizeList(policy.ownerIds or policy.ownerUUIDs or policy.adminIds)
  local allowed_prefixes = normalizeList(policy.allowedPrefixes or policy.prefixes)
  local allowed_contexts = normalizeList(policy.allowedContexts or policy.contexts)
  if #admin_roles > 0 then
    Plugin.policy.adminRoles = admin_roles
  end
  Plugin.policy.ownerIds = owner_ids
  if type(policy.savedDir) == "string" and trim(policy.savedDir) ~= "" then
    Plugin.policy.savedDir = policy.savedDir
  end
  if #allowed_prefixes > 0 then
    Plugin.policy.allowedPrefixes = allowed_prefixes
  end
  if #allowed_contexts > 0 then
    Plugin.policy.allowedContexts = allowed_contexts
  end
  if type(policy.denyUnknown) == "boolean" then
    Plugin.policy.denyUnknown = policy.denyUnknown
  end
  if type(policy.allowEmpty) == "boolean" then
    Plugin.policy.allowEmpty = policy.allowEmpty
  end
  if type(policy.allowSinglePlayerContextLearning) == "boolean" then
    Plugin.policy.allowSinglePlayerContextLearning = policy.allowSinglePlayerContextLearning
  end
  if type(policy.proactivePrimeAllowedContexts) == "boolean" then
    Plugin.policy.proactivePrimeAllowedContexts = policy.proactivePrimeAllowedContexts
  end
  if tonumber(policy.proactivePrimeIntervalSeconds) then
    Plugin.policy.proactivePrimeIntervalSeconds = math.max(1, tonumber(policy.proactivePrimeIntervalSeconds) or 2)
  end

  local native = type(config.native) == "table" and config.native or {}
  if type(native.controlPath) == "string" and trim(native.controlPath) ~= "" then
    Plugin.native.controlPath = native.controlPath
  end
  if type(native.statusPath) == "string" and trim(native.statusPath) ~= "" then
    Plugin.native.statusPath = native.statusPath
  end
  if type(native.eventPath) == "string" and trim(native.eventPath) ~= "" then
    Plugin.native.eventPath = native.eventPath
  end
  if type(native.trace) == "boolean" then
    Plugin.native.trace = native.trace
  end

  local feedback = type(config.feedback) == "table" and config.feedback or {}
  if type(feedback.enabled) == "boolean" then
    Plugin.feedback.enabled = feedback.enabled
  end
  if type(feedback.message) == "string" and trim(feedback.message) ~= "" then
    Plugin.feedback.message = feedback.message
  end
  if type(feedback.adminRetryMessage) == "string" and trim(feedback.adminRetryMessage) ~= "" then
    Plugin.feedback.adminRetryMessage = feedback.adminRetryMessage
  end
end

local function refreshRoleAssignments(BMF, force)
  local now = os.time()
  if not force and Plugin.roleAssignments and now - (Plugin.roleAssignmentsLoadedAt or 0) < 5 then
    return Plugin.roleAssignments
  end
  Plugin.roleAssignmentsLoadedAt = now

  if not BMF.permissions or type(BMF.permissions.loadRoleAssignments) ~= "function" then
    Plugin.stats.roleAssignmentsCode = "ROLE_ASSIGNMENTS_API_UNAVAILABLE"
    return nil
  end
  local options = {}
  if trim(Plugin.policy.savedDir or "") ~= "" then
    options.savedDir = Plugin.policy.savedDir
  end
  local loaded = BMF.permissions.loadRoleAssignments(options)
  Plugin.stats.roleAssignmentsCode = tostring(loaded and loaded.code or "")
  if loaded and loaded.ok and loaded.data then
    Plugin.roleAssignments = loaded.data.assignments
    Plugin.stats.roleAssignmentsPlayerCount = tonumber(loaded.data.playerCount) or 0
    return Plugin.roleAssignments
  end
  return nil
end

local function playerRoles(BMF, player)
  local uuid = playerId(player)
  if uuid == "" then
    return {}
  end
  local assignments = refreshRoleAssignments(BMF, false)
  if not assignments then
    return {}
  end
  local resolved = BMF.permissions.getPlayerRoles(assignments, uuid)
  if resolved and resolved.ok and resolved.data then
    return resolved.data.roles or {}
  end
  return {}
end

local function roleIsAdmin(role)
  local key = tostring(role or ""):lower()
  for _, admin_role in ipairs(Plugin.policy.adminRoles or {}) do
    if key == tostring(admin_role):lower() then
      return true, tostring(admin_role)
    end
  end
  return false, ""
end

local function playerIsConfiguredOwner(player)
  local uuid = playerId(player):lower()
  if uuid == "" then
    return false
  end

  for _, owner_id in ipairs(Plugin.policy.ownerIds or {}) do
    if uuid == tostring(owner_id or ""):lower() then
      return true
    end
  end
  return false
end

local function appendRole(roles, role)
  local wanted = tostring(role or "")
  if wanted == "" then
    return roles
  end
  for _, existing in ipairs(roles or {}) do
    if tostring(existing):lower() == wanted:lower() then
      return roles
    end
  end
  roles[#roles + 1] = wanted
  return roles
end

local function playerIsAdmin(BMF, player)
  local roles = playerRoles(BMF, player)
  if playerIsConfiguredOwner(player) then
    roles = appendRole(roles, "Owner")
    return true, roles, "Owner"
  end
  for _, role in ipairs(roles or {}) do
    local matched, admin_role = roleIsAdmin(role)
    if matched then
      return true, roles, admin_role
    end
  end
  return false, roles, ""
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
    if playerId(player):lower() == wanted then
      return player
    end
  end
  return nil
end

local function resolveContextPlayer(BMF, context)
  local players = playersList(BMF)
  local normalized = normalizeContext(context)
  local known_uuid = Plugin.contextPlayers[normalized]
  if known_uuid then
    return findPlayerById(players, known_uuid) or { uuid = known_uuid }, "known-context"
  end

  if normalized ~= "" and Plugin.policy.allowSinglePlayerContextLearning and #players == 1 then
    local player = players[1]
    local uuid = playerId(player)
    if uuid ~= "" then
      Plugin.contextPlayers[normalized] = uuid
      Plugin.contextPlayerSources[normalized] = "single-live-player"
      return player, "single-live-player"
    end
  end

  return nil, #players > 1 and "ambiguous-multiple-players" or "no-live-player"
end

local function currentApplicatorContext(BMF)
  if not BMF.tools or not BMF.tools.applicator or type(BMF.tools.applicator.nativeTargets) ~= "function" then
    return "", nil
  end

  local targets = BMF.tools.applicator.nativeTargets({
    refresh = false,
  })
  local context = ""
  if targets and targets.data then
    context = normalizeContext(targets.data.processEventContextAddress)
  end
  return context, targets
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

  for _, context in ipairs(Plugin.policy.allowedContexts or {}) do
    add(context)
  end

  local players = playersList(BMF)
  for context, uuid in pairs(Plugin.contextPlayers or {}) do
    local player = findPlayerById(players, uuid)
    if player then
      local is_admin = playerIsAdmin(BMF, player)
      if is_admin then
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

  local lines = {}
  for line in raw:gmatch("[^\r\n]+") do
    local key = line:match("^%s*([%w_]+)%s*=")
    if key ~= "allowed_prefix"
      and key ~= "allow_prefix"
      and key ~= "allowed_context"
      and key ~= "allow_context"
      and key ~= "enable"
      and key ~= "block"
      and key ~= "trace"
      and key ~= "deny_unknown"
      and key ~= "allow_empty" then
      lines[#lines + 1] = line
    end
  end

  lines[#lines + 1] = "enable=1"
  lines[#lines + 1] = "block=1"
  lines[#lines + 1] = "trace=" .. (Plugin.native.trace and "1" or "0")
  lines[#lines + 1] = "deny_unknown=" .. (Plugin.policy.denyUnknown and "1" or "0")
  lines[#lines + 1] = "allow_empty=" .. (Plugin.policy.allowEmpty and "1" or "0")
  for _, prefix in ipairs(Plugin.policy.allowedPrefixes or {}) do
    lines[#lines + 1] = "allowed_prefix=" .. tostring(prefix)
  end
  local contexts = collectAllowedContexts(BMF)
  for _, context in ipairs(contexts) do
    lines[#lines + 1] = "allowed_context=" .. tostring(context)
  end

  local desired = table.concat(lines, "\n") .. "\n"
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

local function proactivePrimeAllowedContext(BMF, reason, force)
  if not Plugin.policy.proactivePrimeAllowedContexts then
    Plugin.prime.lastCode = "DISABLED"
    Plugin.prime.lastReason = tostring(reason or "")
    return false
  end
  if not Plugin.policy.allowSinglePlayerContextLearning then
    Plugin.prime.lastCode = "CONTEXT_LEARNING_DISABLED"
    Plugin.prime.lastReason = tostring(reason or "")
    return false
  end

  local now = os.time()
  if not force and now < (Plugin.prime.nextAt or 0) then
    return false
  end
  Plugin.prime.nextAt = now + math.max(1, tonumber(Plugin.policy.proactivePrimeIntervalSeconds) or 2)
  Plugin.prime.attempts = Plugin.prime.attempts + 1

  local players = playersList(BMF)
  if #players ~= 1 then
    if #players == 0 then
      writeNativePolicy(BMF, "prime-no-live-player")
      Plugin.prime.clears = Plugin.prime.clears + 1
    end
    Plugin.prime.lastCode = #players > 1 and "AMBIGUOUS_PLAYERS" or "NO_LIVE_PLAYER"
    Plugin.prime.lastReason = tostring(reason or "")
    return false
  end

  local player = players[1]
  local is_admin, roles, matched_role = playerIsAdmin(BMF, player)
  Plugin.stats.lastPlayer = playerId(player)
  Plugin.stats.lastMatchedRole = tostring(matched_role or "")
  if not is_admin then
    writeNativePolicy(BMF, "prime-player-not-admin")
    Plugin.prime.clears = Plugin.prime.clears + 1
    Plugin.prime.lastCode = "PLAYER_NOT_ADMIN"
    Plugin.prime.lastReason = tostring(reason or "")
    Plugin.prime.lastPlayer = playerId(player)
    Plugin.prime.lastContext = ""
    return false
  end

  local context, targets = currentApplicatorContext(BMF)
  if context == "" or context == "0x0" then
    Plugin.prime.lastCode = "NO_APPLICATOR_CONTEXT:" .. tostring(targets and targets.code or "")
    Plugin.prime.lastReason = tostring(reason or "")
    Plugin.prime.lastPlayer = playerId(player)
    Plugin.prime.lastContext = context
    return false
  end

  local uuid = playerId(player)
  Plugin.contextPlayers[context] = uuid
  Plugin.contextPlayerSources[context] = "single-live-player-prime"
  Plugin.stats.lastContext = context
  Plugin.stats.lastMatchedRole = tostring(matched_role or "")
  if writeNativePolicy(BMF, tostring(reason or "prime-context")) then
    Plugin.prime.successes = Plugin.prime.successes + 1
    Plugin.prime.lastCode = Plugin.native.lastWriteCode
    Plugin.prime.lastReason = tostring(reason or "")
    Plugin.prime.lastPlayer = uuid
    Plugin.prime.lastContext = context
    return true
  end

  Plugin.prime.lastCode = Plugin.native.lastWriteCode
  Plugin.prime.lastReason = tostring(reason or "")
  Plugin.prime.lastPlayer = uuid
  Plugin.prime.lastContext = context
  return false
end

local function evaluate(BMF, event, explicitRoles)
  local player = type(event.player) == "table" and event.player or {
    uuid = event.playerUuid or event.playerId or event.uuid or event.id,
    username = event.username or event.name,
    displayName = event.displayName,
  }
  local roles = explicitRoles or playerRoles(BMF, player)
  if playerIsConfiguredOwner(player) then
    roles = appendRole(roles, "Owner")
  end
  return BMF.permissions.evaluateInteractConsolePrefixAccess({
    tag = event.message or event.consoleTag or event.tag or event.value or "",
    actor = {
      uuid = playerId(player),
      username = playerName(player),
      displayName = player.displayName,
      roles = roles,
    },
    roles = roles,
    allowedPrefixes = Plugin.policy.allowedPrefixes,
    adminRoles = Plugin.policy.adminRoles,
    denyUnknown = Plugin.policy.denyUnknown,
    allowEmpty = Plugin.policy.allowEmpty,
  })
end

local function deliverMessage(BMF, player, message)
  if not Plugin.feedback.enabled then
    return nil
  end
  if not player then
    Plugin.stats.feedbackMissed = Plugin.stats.feedbackMissed + 1
    return nil
  end
  local whispered = BMF.chat.whisper(player, message)
  if whispered and whispered.ok then
    Plugin.stats.feedbackDelivered = Plugin.stats.feedbackDelivered + 1
  else
    Plugin.stats.feedbackMissed = Plugin.stats.feedbackMissed + 1
  end
  return whispered
end

local function deliverFeedback(BMF, event, access)
  local player = type(event.player) == "table" and event.player or nil
  if not player then
    local uuid = trim(event.playerUuid or event.playerId or event.uuid or event.id)
    if uuid ~= "" then
      player = { uuid = uuid, id = uuid, username = event.username or event.name }
    end
  end
  return deliverMessage(BMF, player, Plugin.feedback.message)
end

local function handleEvent(BMF, event, explicitRoles)
  local payload = type(event) == "table" and event or {}
  Plugin.stats.received = Plugin.stats.received + 1
  local access = evaluate(BMF, payload, explicitRoles)
  local data = access.data or {}

  Plugin.stats.lastDecision = tostring(data.decision or access.code or "")
  Plugin.stats.lastPlayer = tostring(data.actorUuid or "")
  Plugin.stats.lastTag = tostring(data.tag or "")
  Plugin.stats.lastMatchedPrefix = tostring(data.matchedPrefix or "")
  Plugin.stats.lastMatchedRole = tostring(data.matchedRole or "")

  if access.ok and data.allowed then
    Plugin.stats.allowed = Plugin.stats.allowed + 1
    BMF.audit.record("interact.console_prefix.allowed", data)
  else
    Plugin.stats.denied = Plugin.stats.denied + 1
    BMF.audit.record("interact.console_prefix.denied", data)
    deliverFeedback(BMF, payload, access)
  end

  return access
end

local function readNewNativeEventChunk()
  local path = Plugin.native.eventPath
  local size = fileSize(path)
  if size <= 0 then
    Plugin.native.cursor = 0
    return ""
  end
  if Plugin.native.cursor > size then
    Plugin.native.cursor = 0
  end
  if Plugin.native.cursor == size then
    return ""
  end

  local handle = io.open(path, "rb")
  if not handle then
    return ""
  end
  handle:seek("set", Plugin.native.cursor)
  local chunk = handle:read("*a") or ""
  Plugin.native.cursor = handle:seek("cur") or size
  handle:close()
  return chunk
end

local function handleNativeEvent(BMF, event)
  local context = normalizeContext(event.context)
  local tag = tostring(event.tag or "")
  Plugin.stats.lastContext = context
  Plugin.stats.lastTag = tag
  Plugin.stats.lastDecision = tostring(event.reason or "")

  if event.event == "allow" then
    Plugin.stats.nativeAllowed = Plugin.stats.nativeAllowed + 1
    return
  end
  if event.event ~= "block" then
    return
  end

  local key = tostring(event.block_id or event.policy_id or "") .. "|" .. context .. "|" .. tag
  if Plugin.native.processed[key] then
    return
  end
  Plugin.native.processed[key] = true
  Plugin.stats.nativeBlocked = Plugin.stats.nativeBlocked + 1

  local player, source = resolveContextPlayer(BMF, context)
  local is_admin, roles, matched_role = false, {}, ""
  if player then
    is_admin, roles, matched_role = playerIsAdmin(BMF, player)
  end
  Plugin.stats.lastPlayer = player and playerId(player) or ""
  Plugin.stats.lastMatchedRole = tostring(matched_role or "")

  BMF.audit.record("interact.console_prefix.native_block", {
    context = context,
    tag = tag,
    reason = tostring(event.reason or ""),
    player = Plugin.stats.lastPlayer,
    playerSource = source,
    roles = roles,
    matchedRole = matched_role,
    adminAllowed = is_admin,
  })

  if is_admin and player then
    Plugin.contextPlayers[context] = playerId(player)
    Plugin.contextPlayerSources[context] = source .. "-native-block"
    writeNativePolicy(BMF, "native-block-admin-context")
    deliverMessage(BMF, player, Plugin.feedback.adminRetryMessage)
  elseif player then
    deliverMessage(BMF, player, Plugin.feedback.message)
  else
    Plugin.stats.feedbackMissed = Plugin.stats.feedbackMissed + 1
  end
end

local function pollNativeEvents(BMF)
  local chunk = readNewNativeEventChunk()
  if chunk == "" then
    return
  end
  for line in chunk:gmatch("[^\r\n]+") do
    handleNativeEvent(BMF, parseEventLine(line))
  end
end

local function nativeStatus()
  local raw = readText(Plugin.native.statusPath)
  if not raw then
    return {}
  end
  return parseKvText(raw)
end

local function statusLines(BMF)
  local native = nativeStatus()
  local current_context = ""
  local targets = nil
  current_context, targets = currentApplicatorContext(BMF)
  local allowed_contexts = collectAllowedContexts(BMF)
  local context_player_count = 0
  for _ in pairs(Plugin.contextPlayers or {}) do
    context_player_count = context_player_count + 1
  end

  return {
    "code=OK",
    "ok=true",
    "policy=interactConsolePrefixGuard",
    "enforcement=servermodifycomponent-native-prefix-policy",
    "save_time_hook=ufunction-func-native",
    "admin_roles=" .. listText(Plugin.policy.adminRoles),
    "owner_ids_count=" .. tostring(#(Plugin.policy.ownerIds or {})),
    "saved_dir=" .. tostring(Plugin.policy.savedDir or ""),
    "allowed_prefixes=" .. listText(Plugin.policy.allowedPrefixes),
    "deny_unknown=" .. tostring(Plugin.policy.denyUnknown == true),
    "allow_empty=" .. tostring(Plugin.policy.allowEmpty == true),
    "allow_single_player_context_learning=" .. tostring(Plugin.policy.allowSinglePlayerContextLearning == true),
    "proactive_prime_enabled=" .. tostring(Plugin.policy.proactivePrimeAllowedContexts == true),
    "proactive_prime_interval_seconds=" .. tostring(Plugin.policy.proactivePrimeIntervalSeconds or 0),
    "proactive_prime_attempts=" .. tostring(Plugin.prime.attempts or 0),
    "proactive_prime_successes=" .. tostring(Plugin.prime.successes or 0),
    "proactive_prime_clears=" .. tostring(Plugin.prime.clears or 0),
    "proactive_prime_last_code=" .. tostring(Plugin.prime.lastCode or ""),
    "proactive_prime_last_context=" .. tostring(Plugin.prime.lastContext or ""),
    "proactive_prime_last_player=" .. tostring(Plugin.prime.lastPlayer or ""),
    "current_applicator_context=" .. tostring(current_context or ""),
    "current_native_targets_code=" .. tostring(targets and targets.code or ""),
    "allowed_context_count=" .. tostring(#allowed_contexts),
    "allowed_contexts=" .. listText(allowed_contexts),
    "context_player_count=" .. tostring(context_player_count),
    "received=" .. tostring(Plugin.stats.received),
    "allowed=" .. tostring(Plugin.stats.allowed),
    "denied=" .. tostring(Plugin.stats.denied),
    "native_allowed=" .. tostring(Plugin.stats.nativeAllowed),
    "native_blocked=" .. tostring(Plugin.stats.nativeBlocked),
    "feedback_delivered=" .. tostring(Plugin.stats.feedbackDelivered),
    "feedback_missed=" .. tostring(Plugin.stats.feedbackMissed),
    "last_decision=" .. tostring(Plugin.stats.lastDecision),
    "last_player=" .. tostring(Plugin.stats.lastPlayer),
    "last_context=" .. tostring(Plugin.stats.lastContext),
    "last_tag=" .. tostring(Plugin.stats.lastTag),
    "last_matched_prefix=" .. tostring(Plugin.stats.lastMatchedPrefix),
    "last_matched_role=" .. tostring(Plugin.stats.lastMatchedRole),
    "role_assignments_code=" .. tostring(Plugin.stats.roleAssignmentsCode),
    "role_assignments_player_count=" .. tostring(Plugin.stats.roleAssignmentsPlayerCount),
    "native_control_path=" .. tostring(Plugin.native.controlPath),
    "native_status_path=" .. tostring(Plugin.native.statusPath),
    "native_event_path=" .. tostring(Plugin.native.eventPath),
    "native_status_installed=" .. tostring(native.installed or ""),
    "native_status_enabled=" .. tostring(native.enabled or ""),
    "native_status_block=" .. tostring(native.block or ""),
    "native_status_function=" .. tostring(native["function"] or ""),
    "native_status_component=" .. tostring(native.component or ""),
    "native_status_hits=" .. tostring(native.hits or ""),
    "native_status_blocks=" .. tostring(native.blocks or ""),
    "native_status_allows=" .. tostring(native.allows or ""),
    "native_status_tag_misses=" .. tostring(native.tag_misses or ""),
    "native_status_allowed_context_count=" .. tostring(native.allowed_context_count or ""),
    "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode or ""),
    "native_policy_write_count=" .. tostring(Plugin.native.writeCount or 0),
    "native_policy_write_reason=" .. tostring(Plugin.native.lastWriteReason or ""),
  }
end

function Plugin.onLoad(BMF)
  loadConfig(BMF)
  refreshRoleAssignments(BMF, true)
  Plugin.native.cursor = fileSize(Plugin.native.eventPath)

  BMF.events.on("interactConsole", function(event)
    return handleEvent(BMF, event)
  end)

  writeNativePolicy(BMF, "plugin-load")
  proactivePrimeAllowedContext(BMF, "plugin-load", true)
  if BMF.timers and type(BMF.timers.after) == "function" then
    BMF.timers.after(1000, function()
      proactivePrimeAllowedContext(BMF, "plugin-load-delay", true)
    end)
  end

  BMF.commands.register("bmf.interactprefix.status", "Show Interactable console prefix guard status.", function()
    refreshRoleAssignments(BMF, true)
    pollNativeEvents(BMF)
    proactivePrimeAllowedContext(BMF, "status", true)
    writeNativePolicy(BMF, "status")
    return BMF.result(true, "OK", "Interact console prefix guard status", {
      lines = statusLines(BMF),
    })
  end)

  BMF.commands.register("bmf.interactprefix.prime-context", "Bind the current Applicator context for an admin player.", function(raw)
    local args = parseArgs(raw)
    local ok = proactivePrimeAllowedContext(BMF, args.reason or "manual-prime-context", true)
    return BMF.result(ok, ok and "OK" or tostring(Plugin.prime.lastCode or "PRIME_FAILED"), "Interact prefix context prime attempted", {
      lines = {
        "ok=" .. tostring(ok),
        "code=" .. tostring(Plugin.prime.lastCode or ""),
        "context=" .. tostring(Plugin.prime.lastContext or ""),
        "player=" .. tostring(Plugin.prime.lastPlayer or ""),
        "matched_role=" .. tostring(Plugin.stats.lastMatchedRole or ""),
        "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode or ""),
      },
    })
  end)

  BMF.commands.register("bmf.interactprefix.check", "Evaluate an Interactable console tag prefix.", function(raw)
    local args = parseArgs(raw)
    local tag = percentDecode(args.tag or args.message or args.value or "buyweapon:test")
    local roles = normalizeList(percentDecode(args.roles or ""))
    local player = {
      uuid = args.player or args.uuid or args.id or "00000000-0000-0000-0000-000000000000",
      username = percentDecode(args.name or args.username or "canary"),
      roles = roles,
    }
    local checked = BMF.permissions.evaluateInteractConsolePrefixAccess({
      tag = tag,
      actor = player,
      roles = roles,
      allowedPrefixes = Plugin.policy.allowedPrefixes,
      adminRoles = Plugin.policy.adminRoles,
      denyUnknown = Plugin.policy.denyUnknown,
      allowEmpty = Plugin.policy.allowEmpty,
    })
    local data = checked.data or {}
    checked.data = data
    data.lines = {
      "code=" .. tostring(checked.code or ""),
      "ok=" .. tostring(checked.ok == true),
      "tag=" .. tostring(data.tag or tag),
      "allowed=" .. tostring(data.allowed == true),
      "decision=" .. tostring(data.decision or ""),
      "matched_prefix=" .. tostring(data.matchedPrefix or ""),
      "matched_role=" .. tostring(data.matchedRole or ""),
      "allowed_prefix_count=" .. tostring(data.allowedPrefixCount or 0),
      "admin_role_count=" .. tostring(data.adminRoleCount or 0),
    }
    return checked
  end)

  BMF.commands.register("bmf.interactprefix.handle", "Handle a forwarded Interactable console event.", function(raw)
    local args = parseArgs(raw)
    local roles = normalizeList(percentDecode(args.roles or ""))
    local event = {
      source = percentDecode(args.source or "command"),
      message = percentDecode(args.message or args.tag or args.value or ""),
      player = {
        uuid = args.player or args.uuid or args.id or "",
        username = percentDecode(args.name or args.username or ""),
        displayName = percentDecode(args.displayname or args.display or ""),
      },
      brickName = percentDecode(args.brick or ""),
      brickAsset = percentDecode(args.asset or ""),
      position = {
        tonumber(args.x) or 0,
        tonumber(args.y) or 0,
        tonumber(args.z) or 0,
      },
    }
    local handled = handleEvent(BMF, event, #roles > 0 and roles or nil)
    handled.data = handled.data or {}
    handled.data.lines = handled.data.lines or {
      "code=" .. tostring(handled.code or ""),
      "ok=" .. tostring(handled.ok == true),
      "allowed=" .. tostring(handled.data.allowed == true),
      "decision=" .. tostring(handled.data.decision or ""),
      "matched_prefix=" .. tostring(handled.data.matchedPrefix or ""),
      "matched_role=" .. tostring(handled.data.matchedRole or ""),
    }
    return handled
  end)

  BMF.log("InteractConsolePrefixGuard loaded allowed_prefixes=" ..
    listText(Plugin.policy.allowedPrefixes) .. " admin_roles=" .. listText(Plugin.policy.adminRoles))
end

function Plugin.onTick(BMF)
  pollNativeEvents(BMF)
  proactivePrimeAllowedContext(BMF, "tick", false)
end

return Plugin
