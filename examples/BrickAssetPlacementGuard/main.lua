local Plugin = {
  name = "BrickAssetPlacementGuard",
  policy = {
    adminRoles = { "Owner", "Admin" },
    allowedRoles = {},
    ownerIds = {},
    deniedAssets = {
      "B_Vehicle_Engine",
      "B_1x1_Gate_WheelEngineSlim",
      "B_Joint_Wheel*",
      "Entity_Wheel_*",
    },
    allowedAssets = {},
    deniedAssetLabels = {
      B_Vehicle_Engine = "Vehicle Engine",
      B_1x1_Gate_WheelEngineSlim = "Wheel Engine",
      ["B_Joint_Wheel*"] = "Wheel Joint",
      ["Entity_Wheel_*"] = "Wheel / Tire",
    },
    denyUnknown = false,
    allowSinglePlayerContextLearning = true,
    policyWriteIntervalSeconds = 2,
    allowedContexts = {},
    savedDir = "",
  },
  prefabs = {
    enabled = true,
    indexPath = "prefab-index.json",
    entries = {},
    byHash = {},
    indexCode = "NOT_LOADED",
    indexStoragePath = "",
    indexCount = 0,
    restrictedHashCount = 0,
    loaded = false,
  },
  native = {
    controlPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/placement-asset-guard-control.txt",
    statusPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/placement-asset-guard-status.txt",
    eventPath = "C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/placement-asset-guard-events.tsv",
    trace = true,
    cursor = 0,
    processed = {},
    lastWrite = "",
    lastWriteCode = "",
    lastWriteReason = "",
    writeCount = 0,
    nextWriteAt = 0,
  },
  feedback = {
    enabled = true,
    message = "BMF blocked that placement: your role cannot place that asset on this server.",
    prefabMessage = "BMF blocked that prefab: it contains an asset your role cannot place on this server.",
    adminRetryMessage = "BMF allowed that placement for your role. Try placing it again.",
  },
  contextPlayers = {},
  contextPlayerSources = {},
  roleAssignments = nil,
  roleAssignmentsLoadedAt = 0,
  stats = {
    checks = 0,
    allowed = 0,
    denied = 0,
    nativeAllowed = 0,
    nativeBlocked = 0,
    nativePrefabAllowed = 0,
    nativePrefabBlocked = 0,
    feedbackDelivered = 0,
    feedbackBroadcast = 0,
    feedbackMissed = 0,
    lastAsset = "",
    lastAssetLabel = "",
    lastDecision = "",
    lastPrefabHash = "",
    lastPlayer = "",
    lastContext = "",
    lastMatchedAsset = "",
    lastMatchedRole = "",
    roleAssignmentsCode = "",
    roleAssignmentsPath = "",
    roleAssignmentsPlayerCount = 0,
  },
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

local function normalizePrefabHash(value)
  local hex = trim(value):gsub("[^0-9A-Fa-f]", ""):upper()
  if #hex ~= 64 then
    return ""
  end
  return hex
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
    return trim(player.uuid or player.id or player.playerId or player.playerID or player.userId)
  end
  return trim(player)
end

local function playerName(player)
  if type(player) == "table" then
    return trim(player.username or player.name or player.displayName or player.playerName)
  end
  return ""
end

local function assetRuleKey(value)
  return tostring(value or ""):lower():gsub("[^a-z0-9]", "")
end

local function assetRuleMatches(asset, rule)
  local asset_key = assetRuleKey(asset)
  local text = trim(rule)
  local rule_key = assetRuleKey(text:gsub("%*", ""))
  if asset_key == "" or rule_key == "" then
    return false
  end
  local starts_wild = text:sub(1, 1) == "*"
  local ends_wild = text:sub(-1) == "*"
  if starts_wild and not ends_wild then
    return asset_key:sub(0 - #rule_key) == rule_key
  end
  if ends_wild and not starts_wild then
    return asset_key:sub(1, #rule_key) == rule_key
  end
  return asset_key:find(rule_key, 1, true) ~= nil
end

local function assetLabel(asset)
  local key = tostring(asset or "")
  local direct = Plugin.policy.deniedAssetLabels[key]
  if direct then
    return tostring(direct)
  end
  for rule, label in pairs(Plugin.policy.deniedAssetLabels or {}) do
    if tostring(rule):find("*", 1, true) and assetRuleMatches(key, rule) then
      return tostring(label)
    end
  end
  return key
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
  local policy = type(config.policy) == "table" and config.policy or config
  local admin_role_source = policy.adminRoles
  if admin_role_source == nil then
    admin_role_source = policy.bypassRoles
  end
  local admin_roles = normalizeList(admin_role_source)
  local allowed_roles = normalizeList(policy.allowedRoles or policy.allowRoles)
  local owner_ids = normalizeList(policy.ownerIds or policy.adminIds or policy.bypassPlayerIds)
  local denied_assets = normalizeList(policy.deniedAssets or policy.denyAssets or policy.blockedAssets)
  local allowed_assets = normalizeList(policy.allowedAssets or policy.allowAssets)
  local allowed_contexts = normalizeList(policy.allowedContexts or policy.contexts)

  if admin_role_source ~= nil then
    Plugin.policy.adminRoles = admin_roles
  end
  Plugin.policy.allowedRoles = allowed_roles
  Plugin.policy.ownerIds = owner_ids
  if #denied_assets > 0 then
    Plugin.policy.deniedAssets = denied_assets
  end
  Plugin.policy.allowedAssets = allowed_assets
  Plugin.policy.allowedContexts = allowed_contexts
  if type(policy.deniedAssetLabels) == "table" then
    Plugin.policy.deniedAssetLabels = policy.deniedAssetLabels
  end
  if type(policy.denyUnknown) == "boolean" then
    Plugin.policy.denyUnknown = policy.denyUnknown
  end
  if type(policy.allowSinglePlayerContextLearning) == "boolean" then
    Plugin.policy.allowSinglePlayerContextLearning = policy.allowSinglePlayerContextLearning
  end
  if tonumber(policy.policyWriteIntervalSeconds) then
    Plugin.policy.policyWriteIntervalSeconds = math.max(1, tonumber(policy.policyWriteIntervalSeconds) or 2)
  end
  if type(policy.savedDir) == "string" and trim(policy.savedDir) ~= "" then
    Plugin.policy.savedDir = policy.savedDir:gsub("\\", "/")
  end

  local prefabs = type(config.prefabs) == "table" and config.prefabs
    or type(policy.prefabs) == "table" and policy.prefabs
    or {}
  if type(prefabs.enabled) == "boolean" then
    Plugin.prefabs.enabled = prefabs.enabled
  end
  if type(prefabs.indexPath) == "string" and trim(prefabs.indexPath) ~= "" then
    Plugin.prefabs.indexPath = prefabs.indexPath
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
  if type(feedback.prefabMessage) == "string" and trim(feedback.prefabMessage) ~= "" then
    Plugin.feedback.prefabMessage = feedback.prefabMessage
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
    Plugin.stats.roleAssignmentsPath = tostring(loaded.data.path or "")
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
    return type(player) == "table" and normalizeList(player.roles or player.roleNames or player.role) or {}
  end
  local resolved = BMF.permissions.getPlayerRoles(assignments, uuid)
  if resolved and resolved.ok and resolved.data then
    return resolved.data.roles or {}
  end
  return {}
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

local function roleMatches(role, allowedRoles)
  local key = tostring(role or ""):lower()
  for _, allowed in ipairs(allowedRoles or {}) do
    if key == tostring(allowed or ""):lower() then
      return true, tostring(allowed)
    end
  end
  return false, ""
end

local function playerHasBypassRole(BMF, player)
  local roles = playerRoles(BMF, player)
  if playerIsConfiguredOwner(player) then
    roles = appendRole(roles, "Owner")
    return true, roles, "Owner"
  end

  for _, role in ipairs(roles or {}) do
    local matched, name = roleMatches(role, Plugin.policy.adminRoles)
    if matched then
      return true, roles, name
    end
  end
  for _, role in ipairs(roles or {}) do
    local matched, name = roleMatches(role, Plugin.policy.allowedRoles)
    if matched then
      return true, roles, name
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

local function liveControllerCount(listed)
  return tonumber(listed and listed.data and listed.data.liveControllerCount) or 0
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
  local players, listed = playersList(BMF)
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

  if normalized ~= ""
    and Plugin.policy.allowSinglePlayerContextLearning
    and #players == 0
    and liveControllerCount(listed) == 1
    and #(Plugin.policy.ownerIds or {}) == 1 then
    local uuid = trim(Plugin.policy.ownerIds[1])
    if uuid ~= "" then
      Plugin.contextPlayers[normalized] = uuid
      Plugin.contextPlayerSources[normalized] = "single-live-controller-owner-id"
      return { uuid = uuid }, "single-live-controller-owner-id"
    end
  end

  return nil, #players > 1 and "ambiguous-multiple-players" or "no-live-player"
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

  local players, listed = playersList(BMF)
  for context, uuid in pairs(Plugin.contextPlayers or {}) do
    local player = findPlayerById(players, uuid)
    if not player
      and #players == 0
      and liveControllerCount(listed) == 1
      and playerIsConfiguredOwner({ uuid = uuid }) then
      player = { uuid = uuid }
    end
    if player then
      local allowed = playerHasBypassRole(BMF, player)
      if allowed then
        add(context)
      end
    end
  end

  table.sort(contexts)
  return contexts
end

local restrictedPrefabHashes

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
    if key ~= "allowed_context"
      and key ~= "allow_context"
      and key ~= "denied_prefab_hash"
      and key ~= "deny_prefab_hash"
      and key ~= "denied_hash"
      and key ~= "deny_hash"
      and key ~= "enable"
      and key ~= "block"
      and key ~= "trace" then
      lines[#lines + 1] = line
    end
  end

  lines[#lines + 1] = "enable=1"
  lines[#lines + 1] = "block=1"
  lines[#lines + 1] = "trace=" .. (Plugin.native.trace and "1" or "0")
  local contexts = collectAllowedContexts(BMF)
  for _, context in ipairs(contexts) do
    lines[#lines + 1] = "allowed_context=" .. tostring(context)
  end
  for _, prefab in ipairs(restrictedPrefabHashes(BMF)) do
    lines[#lines + 1] = "denied_prefab_hash=" .. tostring(prefab.hash or "") .. "|" .. tostring(prefab.asset or "")
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

local function evaluate(BMF, asset, player, explicitRoles)
  local roles = explicitRoles or playerRoles(BMF, player)
  if playerIsConfiguredOwner(player) then
    roles = appendRole(roles, "Owner")
  end
  return BMF.permissions.evaluateBrickAssetAccess({
    asset = asset,
    assetKind = "placementAsset",
    actor = {
      uuid = playerId(player),
      username = playerName(player),
      displayName = type(player) == "table" and player.displayName or "",
      roles = roles,
    },
    roles = roles,
    policy = Plugin.policy,
  })
end

local function addAssetName(items, seen, value)
  local text = trim(value)
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

local function addAssetList(items, seen, value)
  if type(value) == "string" then
    for item in value:gmatch("[^,|]+") do
      addAssetName(items, seen, item)
    end
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      if type(item) == "table" then
        addAssetName(items, seen, item.name or item.asset or item.assetName or item.typeName or item.matchedAsset)
      else
        addAssetName(items, seen, item)
      end
    end
  end
end

local function collectPrefabEntryAssets(entry)
  local items = {}
  local seen = {}
  if type(entry) ~= "table" then
    return items
  end
  addAssetList(items, seen, entry.assetNames or entry.assets or entry.brickAssets)
  addAssetList(items, seen, entry.deniedAssets or entry.restrictedAssets)
  addAssetList(items, seen, entry.basicBrickAssetNames)
  addAssetList(items, seen, entry.proceduralBrickAssetNames)
  addAssetList(items, seen, entry.entityTypeNames)
  if type(entry.data) == "table" then
    addAssetList(items, seen, entry.data.assetNames or entry.data.assets or entry.data.brickAssets)
    addAssetList(items, seen, entry.data.deniedAssets or entry.data.restrictedAssets)
    addAssetList(items, seen, entry.data.basicBrickAssetNames)
    addAssetList(items, seen, entry.data.proceduralBrickAssetNames)
    addAssetList(items, seen, entry.data.entityTypeNames)
  end
  table.sort(items)
  return items
end

local function prefabEntriesFromIndex(value)
  if type(value) ~= "table" then
    return {}
  end
  if type(value.prefabs) == "table" then
    return value.prefabs
  end
  if type(value.data) == "table" and type(value.data.prefabs) == "table" then
    return value.data.prefabs
  end
  return value
end

local function addPrefabIndexEntry(entries, by_hash, entry)
  if type(entry) ~= "table" then
    return
  end
  local hash = normalizePrefabHash(entry.hash or entry.prefabHash or entry.brPrefabHashCandidate)
  if hash == "" then
    return
  end
  local assets = collectPrefabEntryAssets(entry)
  if #assets == 0 then
    return
  end
  if by_hash[hash] then
    local existing = by_hash[hash]
    local seen = {}
    for _, asset in ipairs(existing.assets or {}) do
      seen[tostring(asset):lower()] = true
    end
    for _, asset in ipairs(assets) do
      if not seen[tostring(asset):lower()] then
        existing.assets[#existing.assets + 1] = asset
      end
    end
    table.sort(existing.assets)
    return
  end
  local normalized = {
    hash = hash,
    name = tostring(entry.name or entry.file or entry.inputPath or ""),
    source = tostring(entry.inputPath or entry.path or ""),
    assets = assets,
  }
  entries[#entries + 1] = normalized
  by_hash[hash] = normalized
end

local function loadPrefabIndex(BMF, force)
  if not Plugin.prefabs.enabled then
    Plugin.prefabs.entries = {}
    Plugin.prefabs.byHash = {}
    Plugin.prefabs.indexCode = "DISABLED"
    Plugin.prefabs.indexCount = 0
    Plugin.prefabs.restrictedHashCount = 0
    Plugin.prefabs.loaded = true
    return false
  end
  if Plugin.prefabs.loaded and not force then
    return true
  end
  Plugin.prefabs.loaded = true

  if not BMF.storage or type(BMF.storage.readJson) ~= "function" then
    Plugin.prefabs.entries = {}
    Plugin.prefabs.byHash = {}
    Plugin.prefabs.indexCode = "STORAGE_API_UNAVAILABLE"
    Plugin.prefabs.indexCount = 0
    Plugin.prefabs.restrictedHashCount = 0
    return false
  end

  local loaded = BMF.storage.readJson(Plugin.prefabs.indexPath)
  Plugin.prefabs.indexCode = tostring(loaded and loaded.code or "")
  Plugin.prefabs.indexStoragePath = tostring(loaded and loaded.data and loaded.data.path or "")
  if not loaded or not loaded.ok or type(loaded.data) ~= "table" or type(loaded.data.value) ~= "table" then
    Plugin.prefabs.entries = {}
    Plugin.prefabs.byHash = {}
    Plugin.prefabs.indexCount = 0
    Plugin.prefabs.restrictedHashCount = 0
    return false
  end

  local entries = {}
  local by_hash = {}
  for _, entry in ipairs(prefabEntriesFromIndex(loaded.data.value)) do
    addPrefabIndexEntry(entries, by_hash, entry)
  end
  local denied = loaded.data.value.deniedPrefabHashes
    or loaded.data.value.restrictedPrefabHashes
    or (type(loaded.data.value.data) == "table" and loaded.data.value.data.deniedPrefabHashes)
    or {}
  for _, entry in ipairs(denied) do
    addPrefabIndexEntry(entries, by_hash, entry)
  end

  table.sort(entries, function(left, right)
    return tostring(left.hash or "") < tostring(right.hash or "")
  end)
  Plugin.prefabs.entries = entries
  Plugin.prefabs.byHash = by_hash
  Plugin.prefabs.indexCount = #entries
  return true
end

local function evaluatePrefab(BMF, hash, player, explicitRoles, explicitAssets)
  loadPrefabIndex(BMF, false)
  local prefab_hash = normalizePrefabHash(hash)
  local entry = Plugin.prefabs.byHash[prefab_hash]
  local assets = explicitAssets or (entry and entry.assets) or {}
  local roles = explicitRoles or playerRoles(BMF, player)

  if prefab_hash == "" and #assets == 0 then
    return BMF.result(false, "INVALID_PREFAB_POLICY", "prefab hash or asset list is required", {
      allowed = false,
      decision = "prefab-invalid",
      hash = prefab_hash,
      assetCount = 0,
      roles = roles,
    })
  end

  if #assets == 0 then
    return BMF.result(true, "OK", "Prefab asset access evaluated", {
      allowed = true,
      decision = "prefab-unknown-allowed",
      reason = "prefab hash was not present in the asset index",
      hash = prefab_hash,
      assetCount = 0,
      roles = roles,
    })
  end

  for _, asset in ipairs(assets) do
    local access = evaluate(BMF, asset, player, roles)
    local data = access.data or {}
    if data.allowed == false then
      return BMF.result(true, "OK", "Prefab asset access evaluated", {
        allowed = false,
        decision = "prefab-asset-denied",
        reason = "prefab contains a restricted asset for this actor",
        hash = prefab_hash,
        asset = tostring(data.asset or asset),
        matchedAsset = tostring(data.matchedAsset or asset),
        matchedRole = tostring(data.matchedRole or ""),
        assetCount = #assets,
        roles = roles,
        entryName = entry and entry.name or "",
        entrySource = entry and entry.source or "",
      })
    end
  end

  return BMF.result(true, "OK", "Prefab asset access evaluated", {
    allowed = true,
    decision = "prefab-assets-allowed",
    reason = "all indexed prefab assets are allowed for this actor",
    hash = prefab_hash,
    assetCount = #assets,
    roles = roles,
    entryName = entry and entry.name or "",
    entrySource = entry and entry.source or "",
  })
end

restrictedPrefabHashes = function(BMF)
  loadPrefabIndex(BMF, false)
  local hashes = {}
  for _, entry in ipairs(Plugin.prefabs.entries or {}) do
    local checked = evaluatePrefab(BMF, entry.hash, { uuid = "prefab-canary", roles = { "Default" } }, { "Default" })
    local data = checked.data or {}
    if data.allowed == false then
      hashes[#hashes + 1] = {
        hash = entry.hash,
        asset = tostring(data.asset or data.matchedAsset or ""),
      }
    end
  end
  table.sort(hashes, function(left, right)
    return tostring(left.hash or "") < tostring(right.hash or "")
  end)
  Plugin.prefabs.restrictedHashCount = #hashes
  return hashes
end

local function recordCheck(evaluated)
  Plugin.stats.checks = Plugin.stats.checks + 1
  local data = evaluated and evaluated.data or {}
  if data.allowed then
    Plugin.stats.allowed = Plugin.stats.allowed + 1
  else
    Plugin.stats.denied = Plugin.stats.denied + 1
  end
  Plugin.stats.lastAsset = tostring(data.asset or "")
  Plugin.stats.lastAssetLabel = assetLabel(data.asset or "")
  Plugin.stats.lastDecision = tostring(data.decision or "")
  Plugin.stats.lastMatchedAsset = tostring(data.matchedAsset or "")
  Plugin.stats.lastMatchedRole = tostring(data.matchedRole or "")
end

local function deliverMessage(BMF, player, message)
  if not Plugin.feedback.enabled then
    return nil
  end

  if player and BMF.chat and type(BMF.chat.whisper) == "function" then
    local whispered = BMF.chat.whisper(player, message)
    if whispered and whispered.ok then
      Plugin.stats.feedbackDelivered = Plugin.stats.feedbackDelivered + 1
      return whispered
    end
  end

  local players = playersList(BMF)
  if #players == 1 and BMF.chat and type(BMF.chat.whisper) == "function" then
    local whispered = BMF.chat.whisper(players[1], message)
    if whispered and whispered.ok then
      Plugin.stats.feedbackDelivered = Plugin.stats.feedbackDelivered + 1
      return whispered
    end
  end

  if BMF.chat and type(BMF.chat.broadcast) == "function" then
    local broadcast = BMF.chat.broadcast(message)
    if broadcast and broadcast.ok then
      Plugin.stats.feedbackBroadcast = Plugin.stats.feedbackBroadcast + 1
      return broadcast
    end
  end

  Plugin.stats.feedbackMissed = Plugin.stats.feedbackMissed + 1
  return nil
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

local function handleNativePrefabEvent(BMF, event)
  local context = normalizeContext(event.context)
  local prefab_hash = normalizePrefabHash(event.prefab_hash or event.hash or "")
  local asset = trim(event.asset_name or event.asset or "")

  Plugin.stats.lastContext = context
  Plugin.stats.lastPrefabHash = prefab_hash
  Plugin.stats.lastAsset = asset
  Plugin.stats.lastAssetLabel = assetLabel(asset)
  Plugin.stats.lastDecision = tostring(event.reason or "")

  if event.event == "allow" then
    Plugin.stats.nativePrefabAllowed = Plugin.stats.nativePrefabAllowed + 1
    return
  end
  if event.event ~= "block" then
    return
  end

  local key = tostring(event.block_id or event.policy_id or "") .. "|" .. context .. "|" .. prefab_hash
  if Plugin.native.processed[key] then
    return
  end
  Plugin.native.processed[key] = true
  Plugin.stats.nativePrefabBlocked = Plugin.stats.nativePrefabBlocked + 1

  local player, source = resolveContextPlayer(BMF, context)
  local access = evaluatePrefab(BMF, prefab_hash, player)
  local data = access.data or {}
  Plugin.stats.lastPlayer = player and playerId(player) or ""
  Plugin.stats.lastDecision = tostring(data.decision or access.code or "")
  Plugin.stats.lastMatchedAsset = tostring(data.matchedAsset or "")
  Plugin.stats.lastMatchedRole = tostring(data.matchedRole or "")
  if tostring(data.asset or "") ~= "" then
    Plugin.stats.lastAsset = tostring(data.asset)
    Plugin.stats.lastAssetLabel = assetLabel(data.asset)
  end

  BMF.audit.record("placement.prefab.native_block", {
    context = context,
    prefabHash = prefab_hash,
    asset = Plugin.stats.lastAsset,
    assetLabel = Plugin.stats.lastAssetLabel,
    reason = tostring(event.reason or ""),
    player = Plugin.stats.lastPlayer,
    playerSource = source,
    allowed = data.allowed == true,
    decision = tostring(data.decision or ""),
    roles = data.roles or {},
    matchedAsset = tostring(data.matchedAsset or ""),
    matchedRole = tostring(data.matchedRole or ""),
  })

  if data.allowed == true and player then
    Plugin.contextPlayers[context] = playerId(player)
    Plugin.contextPlayerSources[context] = source .. "-native-prefab-block"
    writeNativePolicy(BMF, "native-prefab-block-allowed-context")
    deliverMessage(BMF, player, Plugin.feedback.adminRetryMessage)
  elseif player then
    deliverMessage(BMF, player, Plugin.feedback.prefabMessage or Plugin.feedback.message)
  else
    deliverMessage(BMF, nil, Plugin.feedback.prefabMessage or Plugin.feedback.message)
  end
end

local function handleNativeEvent(BMF, event)
  if trim(event.prefab_hash or event.hash or "") ~= "" then
    handleNativePrefabEvent(BMF, event)
    return
  end

  local context = normalizeContext(event.context)
  local asset = trim(event.asset_name or event.asset or "")
  if asset == "" then
    asset = Plugin.policy.deniedAssets[1] or ""
  end

  Plugin.stats.lastContext = context
  Plugin.stats.lastAsset = asset
  Plugin.stats.lastAssetLabel = assetLabel(asset)
  Plugin.stats.lastDecision = tostring(event.reason or "")

  if event.event == "allow" then
    Plugin.stats.nativeAllowed = Plugin.stats.nativeAllowed + 1
    return
  end
  if event.event ~= "block" then
    return
  end

  local key = tostring(event.block_id or event.policy_id or "") .. "|" .. context .. "|" .. asset
  if Plugin.native.processed[key] then
    return
  end
  Plugin.native.processed[key] = true
  Plugin.stats.nativeBlocked = Plugin.stats.nativeBlocked + 1

  local player, source = resolveContextPlayer(BMF, context)
  local access = evaluate(BMF, asset, player)
  local data = access.data or {}
  Plugin.stats.lastPlayer = player and playerId(player) or ""
  Plugin.stats.lastDecision = tostring(data.decision or access.code or "")
  Plugin.stats.lastMatchedAsset = tostring(data.matchedAsset or "")
  Plugin.stats.lastMatchedRole = tostring(data.matchedRole or "")

  BMF.audit.record("placement.asset.native_block", {
    context = context,
    asset = asset,
    assetLabel = assetLabel(asset),
    reason = tostring(event.reason or ""),
    player = Plugin.stats.lastPlayer,
    playerSource = source,
    allowed = data.allowed == true,
    decision = tostring(data.decision or ""),
    roles = data.roles or {},
    matchedRole = tostring(data.matchedRole or ""),
  })

  if data.allowed == true and player then
    Plugin.contextPlayers[context] = playerId(player)
    Plugin.contextPlayerSources[context] = source .. "-native-block"
    writeNativePolicy(BMF, "native-block-allowed-context")
    deliverMessage(BMF, player, Plugin.feedback.adminRetryMessage)
  elseif player then
    deliverMessage(BMF, player, Plugin.feedback.message)
  else
    deliverMessage(BMF, nil, Plugin.feedback.message)
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
  loadPrefabIndex(BMF, true)
  local restricted_prefabs = restrictedPrefabHashes(BMF)
  local prefab_canary_hash = restricted_prefabs[1] and restricted_prefabs[1].hash or ""
  local prefab_canary = prefab_canary_hash ~= ""
    and evaluatePrefab(BMF, prefab_canary_hash, { uuid = "prefab-canary", roles = { "Default" } }, { "Default" })
    or { data = { allowed = true, decision = "prefab-canary-unavailable", asset = "" } }
  local denied_canary_asset = Plugin.policy.deniedAssets[1] or "Entity_Wheel_Steelie1"
  local allowed_canary_asset = "PB_DefaultMicroBrick"
  local denied_canary = evaluate(BMF, denied_canary_asset, { uuid = "canary", roles = { "Default" } }, { "Default" })
  local admin_canary = evaluate(BMF, denied_canary_asset, { uuid = "admin", roles = { "Admin" } }, { "Admin" })
  local allowed_canary = evaluate(BMF, allowed_canary_asset, { uuid = "canary", roles = { "Default" } }, { "Default" })
  local native = nativeStatus()
  local allowed_contexts = collectAllowedContexts(BMF)
  local context_player_count = 0
  for _ in pairs(Plugin.contextPlayers or {}) do
    context_player_count = context_player_count + 1
  end

  return {
    "policy=brickAssetPlacementGuard",
    "enforcement=serverplacesimpleentityvolume-serverpasteprefab-placeprefabaction-placebrickaction-native-policy",
    "live_hook=ServerPlaceSimpleEntityVolume,ServerPastePrefab,BrickAction_PlacePrefab,BrickAction_PlaceBrick",
    "admin_roles=" .. listText(Plugin.policy.adminRoles),
    "allowed_roles=" .. listText(Plugin.policy.allowedRoles),
    "owner_ids=" .. tostring(#(Plugin.policy.ownerIds or {})),
    "denied_assets=" .. listText(Plugin.policy.deniedAssets),
    "allowed_assets=" .. listText(Plugin.policy.allowedAssets),
    "deny_unknown=" .. tostring(Plugin.policy.denyUnknown == true),
    "allow_single_player_context_learning=" .. tostring(Plugin.policy.allowSinglePlayerContextLearning == true),
    "prefab_guard_enabled=" .. tostring(Plugin.prefabs.enabled == true),
    "prefab_index_path=" .. tostring(Plugin.prefabs.indexPath or ""),
    "prefab_index_code=" .. tostring(Plugin.prefabs.indexCode or ""),
    "prefab_index_storage_path=" .. tostring(Plugin.prefabs.indexStoragePath or ""),
    "prefab_index_count=" .. tostring(Plugin.prefabs.indexCount or 0),
    "restricted_prefab_hash_count=" .. tostring(#restricted_prefabs),
    "prefab_denied_canary_hash=" .. tostring(prefab_canary_hash),
    "prefab_denied_canary_allowed=" .. tostring(prefab_canary.data and prefab_canary.data.allowed),
    "prefab_denied_canary_decision=" .. tostring(prefab_canary.data and prefab_canary.data.decision or ""),
    "prefab_denied_canary_asset=" .. tostring(prefab_canary.data and prefab_canary.data.asset or ""),
    "denied_canary_asset=" .. tostring(denied_canary_asset),
    "denied_canary_label=" .. assetLabel(denied_canary_asset),
    "denied_canary_allowed=" .. tostring(denied_canary.data and denied_canary.data.allowed),
    "denied_canary_decision=" .. tostring(denied_canary.data and denied_canary.data.decision or ""),
    "admin_canary_allowed=" .. tostring(admin_canary.data and admin_canary.data.allowed),
    "admin_canary_decision=" .. tostring(admin_canary.data and admin_canary.data.decision or ""),
    "allowed_canary_asset=" .. tostring(allowed_canary_asset),
    "allowed_canary_allowed=" .. tostring(allowed_canary.data and allowed_canary.data.allowed),
    "allowed_context_count=" .. tostring(#allowed_contexts),
    "allowed_contexts=" .. listText(allowed_contexts),
    "context_player_count=" .. tostring(context_player_count),
    "role_assignments_saved_dir=" .. tostring(Plugin.policy.savedDir or ""),
    "checks=" .. tostring(Plugin.stats.checks),
    "allowed=" .. tostring(Plugin.stats.allowed),
    "denied=" .. tostring(Plugin.stats.denied),
    "native_allowed=" .. tostring(Plugin.stats.nativeAllowed),
    "native_blocked=" .. tostring(Plugin.stats.nativeBlocked),
    "native_prefab_allowed=" .. tostring(Plugin.stats.nativePrefabAllowed),
    "native_prefab_blocked=" .. tostring(Plugin.stats.nativePrefabBlocked),
    "feedback_delivered=" .. tostring(Plugin.stats.feedbackDelivered),
    "feedback_broadcast=" .. tostring(Plugin.stats.feedbackBroadcast),
    "feedback_missed=" .. tostring(Plugin.stats.feedbackMissed),
    "last_asset=" .. tostring(Plugin.stats.lastAsset),
    "last_asset_label=" .. tostring(Plugin.stats.lastAssetLabel),
    "last_decision=" .. tostring(Plugin.stats.lastDecision),
    "last_prefab_hash=" .. tostring(Plugin.stats.lastPrefabHash),
    "last_player=" .. tostring(Plugin.stats.lastPlayer),
    "last_context=" .. tostring(Plugin.stats.lastContext),
    "last_matched_asset=" .. tostring(Plugin.stats.lastMatchedAsset),
    "last_matched_role=" .. tostring(Plugin.stats.lastMatchedRole),
    "role_assignments_code=" .. tostring(Plugin.stats.roleAssignmentsCode),
    "role_assignments_path=" .. tostring(Plugin.stats.roleAssignmentsPath),
    "role_assignments_player_count=" .. tostring(Plugin.stats.roleAssignmentsPlayerCount),
    "native_control_path=" .. tostring(Plugin.native.controlPath),
    "native_status_path=" .. tostring(Plugin.native.statusPath),
    "native_event_path=" .. tostring(Plugin.native.eventPath),
    "native_status_installed=" .. tostring(native.installed or ""),
    "native_status_enabled=" .. tostring(native.enabled or ""),
    "native_status_block=" .. tostring(native.block or ""),
    "native_status_function=" .. tostring(native["function"] or ""),
    "native_status_denied_asset_count=" .. tostring(native.denied_asset_count or ""),
    "native_status_allowed_context_count=" .. tostring(native.allowed_context_count or ""),
    "native_status_hits=" .. tostring(native.hits or ""),
    "native_status_blocks=" .. tostring(native.blocks or ""),
    "native_status_allows=" .. tostring(native.allows or ""),
    "native_status_prefab_installed=" .. tostring(native.prefab_installed or ""),
    "native_status_denied_prefab_hash_count=" .. tostring(native.denied_prefab_hash_count or ""),
    "native_status_prefab_hits=" .. tostring(native.prefab_hits or ""),
    "native_status_prefab_blocks=" .. tostring(native.prefab_blocks or ""),
    "native_status_prefab_allows=" .. tostring(native.prefab_allows or ""),
    "native_status_action_prefab_installed=" .. tostring(native.action_prefab_installed or ""),
    "native_status_place_prefab_method_block=" .. tostring(native.place_prefab_method_block or ""),
    "native_status_place_prefab_apply_slot=" .. tostring(native.place_prefab_apply_slot or ""),
    "native_status_action_prefab_hits=" .. tostring(native.action_prefab_hits or ""),
    "native_status_action_prefab_blocks=" .. tostring(native.action_prefab_blocks or ""),
    "native_status_action_prefab_allows=" .. tostring(native.action_prefab_allows or ""),
    "native_status_action_prefab_param_read_failures=" .. tostring(native.action_prefab_param_read_failures or ""),
    "native_status_action_brick_installed=" .. tostring(native.action_brick_installed or ""),
    "native_status_place_brick_method_block=" .. tostring(native.place_brick_method_block or ""),
    "native_status_place_brick_apply_slot=" .. tostring(native.place_brick_apply_slot or ""),
    "native_status_action_brick_hits=" .. tostring(native.action_brick_hits or ""),
    "native_status_action_brick_blocks=" .. tostring(native.action_brick_blocks or ""),
    "native_status_action_brick_allows=" .. tostring(native.action_brick_allows or ""),
    "native_status_action_brick_param_read_failures=" .. tostring(native.action_brick_param_read_failures or ""),
    "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode or ""),
    "native_policy_write_count=" .. tostring(Plugin.native.writeCount or 0),
    "native_policy_write_reason=" .. tostring(Plugin.native.lastWriteReason or ""),
  }
end

function Plugin.onLoad(BMF)
  loadConfig(BMF)
  refreshRoleAssignments(BMF, true)
  loadPrefabIndex(BMF, true)
  Plugin.native.cursor = fileSize(Plugin.native.eventPath)
  writeNativePolicy(BMF, "plugin-load")

  BMF.commands.register("bmf.brickassetguard.status", "Show brick asset placement guard policy status.", function()
    refreshRoleAssignments(BMF, true)
    pollNativeEvents(BMF)
    writeNativePolicy(BMF, "status")
    return BMF.result(true, "OK", "Brick asset placement guard status", {
      lines = statusLines(BMF),
    })
  end)

  BMF.commands.register("bmf.brickassetguard.check", "Evaluate a brick asset against the placement guard policy.", function(raw)
    local args = parseArgs(raw)
    local asset = percentDecode(args.asset or args.brickasset or args.brick or args.name or "Entity_Wheel_Steelie1")
    local roles = normalizeList(percentDecode(args.roles or args.role or "Default"))
    local actor = {
      uuid = percentDecode(args.uuid or args.player or args.playerid or "00000000-0000-0000-0000-000000000000"),
      username = percentDecode(args.username or args.name or "canary"),
      roles = roles,
    }
    local evaluated = evaluate(BMF, asset, actor, roles)
    recordCheck(evaluated)
    local data = evaluated.data or {}

    return BMF.result(evaluated.ok == true, evaluated.code or "UNKNOWN", evaluated.message or "Brick asset check evaluated", {
      lines = {
        "asset=" .. tostring(data.asset or asset),
        "asset_label=" .. assetLabel(data.asset or asset),
        "allowed=" .. tostring(data.allowed == true),
        "decision=" .. tostring(data.decision or ""),
        "reason=" .. tostring(data.reason or ""),
        "matched_asset=" .. tostring(data.matchedAsset or ""),
        "matched_role=" .. tostring(data.matchedRole or ""),
        "roles=" .. listText(roles),
        "denied_asset_count=" .. tostring(data.deniedAssetCount or 0),
        "allowed_asset_count=" .. tostring(data.allowedAssetCount or 0),
        "admin_role_count=" .. tostring(data.adminRoleCount or 0),
        "allowed_role_count=" .. tostring(data.allowedRoleCount or 0),
        "deny_unknown=" .. tostring(data.denyUnknown == true),
        "enforcement=serverplacesimpleentityvolume-placebrickaction-native-policy",
      },
    })
  end)

  BMF.commands.register("bmf.brickassetguard.prefab-check", "Evaluate an indexed prefab hash against the placement guard policy.", function(raw)
    local args = parseArgs(raw)
    local hash = percentDecode(args.hash or args.prefabhash or args.prefab or "")
    local roles = normalizeList(percentDecode(args.roles or args.role or "Default"))
    local explicit_assets = normalizeList(percentDecode(args.assets or args.asset or args.contains or ""))
    local actor = {
      uuid = percentDecode(args.uuid or args.player or args.playerid or "00000000-0000-0000-0000-000000000000"),
      username = percentDecode(args.username or args.name or "canary"),
      roles = roles,
    }
    local evaluated = evaluatePrefab(BMF, hash, actor, roles, #explicit_assets > 0 and explicit_assets or nil)
    local data = evaluated.data or {}
    if data.allowed then
      Plugin.stats.allowed = Plugin.stats.allowed + 1
    else
      Plugin.stats.denied = Plugin.stats.denied + 1
    end
    Plugin.stats.lastPrefabHash = tostring(data.hash or normalizePrefabHash(hash))
    Plugin.stats.lastAsset = tostring(data.asset or "")
    Plugin.stats.lastAssetLabel = assetLabel(data.asset or "")
    Plugin.stats.lastDecision = tostring(data.decision or "")
    Plugin.stats.lastMatchedAsset = tostring(data.matchedAsset or "")
    Plugin.stats.lastMatchedRole = tostring(data.matchedRole or "")

    return BMF.result(evaluated.ok == true, evaluated.code or "UNKNOWN", evaluated.message or "Prefab asset check evaluated", {
      lines = {
        "hash=" .. tostring(data.hash or normalizePrefabHash(hash)),
        "allowed=" .. tostring(data.allowed == true),
        "decision=" .. tostring(data.decision or ""),
        "reason=" .. tostring(data.reason or ""),
        "asset=" .. tostring(data.asset or ""),
        "asset_label=" .. assetLabel(data.asset or ""),
        "matched_asset=" .. tostring(data.matchedAsset or ""),
        "matched_role=" .. tostring(data.matchedRole or ""),
        "roles=" .. listText(roles),
        "asset_count=" .. tostring(data.assetCount or 0),
        "entry_name=" .. tostring(data.entryName or ""),
        "entry_source=" .. tostring(data.entrySource or ""),
        "prefab_index_code=" .. tostring(Plugin.prefabs.indexCode or ""),
        "prefab_index_count=" .. tostring(Plugin.prefabs.indexCount or 0),
        "enforcement=serverpasteprefab-and-placeprefab-action-native-policy",
      },
    })
  end)

  BMF.commands.register("bmf.brickassetguard.allow-context", "Temporarily allow a placement context address.", function(raw)
    local args = parseArgs(raw)
    local context = normalizeContext(args.context or args.address or args[1])
    if context == "" then
      return BMF.result(false, "INVALID_CONTEXT", "context=0x... is required")
    end
    Plugin.policy.allowedContexts[#Plugin.policy.allowedContexts + 1] = context
    writeNativePolicy(BMF, "manual-allow-context")
    return BMF.result(true, "OK", "Placement context allowed", {
      lines = {
        "context=" .. context,
        "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode or ""),
      },
    })
  end)

  BMF.logInfo("BrickAssetPlacementGuard loaded", {
    deniedAssets = #Plugin.policy.deniedAssets,
    allowedAssets = #Plugin.policy.allowedAssets,
    indexedPrefabs = Plugin.prefabs.indexCount,
    restrictedPrefabHashes = Plugin.prefabs.restrictedHashCount,
    adminRoles = #Plugin.policy.adminRoles,
    enforcement = "ServerPlaceSimpleEntityVolume+ServerPastePrefab+BrickAction_PlaceBrick",
  })
end

function Plugin.onTick(BMF)
  pollNativeEvents(BMF)
  local now = os.time()
  if now >= (Plugin.native.nextWriteAt or 0) then
    Plugin.native.nextWriteAt = now + math.max(1, tonumber(Plugin.policy.policyWriteIntervalSeconds) or 2)
    writeNativePolicy(BMF, "tick")
  end
end

return Plugin
