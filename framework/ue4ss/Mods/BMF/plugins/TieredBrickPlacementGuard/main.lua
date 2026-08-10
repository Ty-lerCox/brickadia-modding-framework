local Plugin = {
  name = "TieredBrickPlacementGuard",
  policy = { savedDir = "", tiers = {} },
  native = {
    controlPath = "",
    statusPath = "",
    eventPath = "",
    trace = true,
    refreshIntervalMilliseconds = 5000,
    eventPollIntervalMilliseconds = 500,
    lastPlayerCacheGeneration = -1,
    generationChecks = 0,
    unchangedRefreshSkips = 0,
    lastGenerationCheckCode = "NOT_CHECKED",
    cursor = 0,
    lastControl = "",
    lastWriteCode = "NOT_WRITTEN",
    writeCount = 0,
  },
  prefabs = { enabled = true, indexPath = "prefab-index.json", entries = {}, code = "NOT_LOADED" },
  feedback = { enabled = true },
  roleAssignments = nil,
  roleAssignmentsLoadedAt = 0,
  contextPlayers = {},
  contextCapabilities = {},
  processed = {},
  processedCount = 0,
  stats = {
    refreshes = 0,
    matchedControllers = 0,
    unmatchedControllers = 0,
    nativeBlocks = 0,
    nativeAllows = 0,
    feedbackDelivered = 0,
    lastContext = "",
    lastRequiredCapabilities = "",
    lastAsset = "",
    lastPrefabHash = "",
  },
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeList(value)
  local out, seen = {}, {}
  local function add(item)
    local text = trim(item)
    local key = text:lower()
    if text ~= "" and not seen[key] then
      seen[key] = true
      out[#out + 1] = text
    end
  end
  if type(value) == "string" then
    for item in value:gmatch("[^,|]+") do add(item) end
  elseif type(value) == "table" then
    for _, item in ipairs(value) do add(item) end
  end
  return out
end

local function normalizeName(value)
  return trim(value):lower():gsub("[^a-z0-9]", "")
end

local function normalizeHash(value)
  local hash = trim(value):gsub("[^0-9A-Fa-f]", ""):upper()
  return #hash == 64 and hash or ""
end

local function normalizeContext(value)
  local text = trim(value)
  local decimal = text:match("@(%d+)$") or text:match("^(%d+)$")
  if decimal then
    local numeric = tonumber(decimal)
    return numeric and string.format("0x%X", numeric) or ""
  end
  local hex = text:match("0[xX]([0-9A-Fa-f]+)")
  if not hex then return "" end
  hex = hex:gsub("^0+", "")
  return hex == "" and "" or ("0x" .. hex:upper())
end

local function readText(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local text = handle:read("*a")
  handle:close()
  return text
end

local function writeText(path, text)
  local handle = io.open(path, "wb")
  if not handle then return false end
  handle:write(text)
  handle:close()
  return true
end

local function fileSize(path)
  local handle = io.open(path, "rb")
  if not handle then return 0 end
  local size = handle:seek("end") or 0
  handle:close()
  return size
end

local function parseEvent(line)
  local event = {}
  for key, value in tostring(line or ""):gmatch("([%w_]+)=([^\t\r\n]*)") do
    event[key] = value
  end
  return event
end

local function playerId(player)
  return type(player) == "table" and trim(player.uuid or player.id or player.playerId or player.playerID) or ""
end

local function playerNames(player)
  if type(player) ~= "table" then return {} end
  local names = {}
  for _, key in ipairs({ "username", "playerName", "originalName", "displayName", "name" }) do
    local value = trim(player[key])
    if value ~= "" then names[#names + 1] = value end
  end
  return normalizeList(names)
end

local function ruleMatches(asset, rule)
  local text = trim(rule)
  local assetKey = normalizeName(asset)
  local ruleKey = normalizeName(text:gsub("%*", ""))
  if assetKey == "" or ruleKey == "" then return false end
  local startsWild = text:sub(1, 1) == "*"
  local endsWild = text:sub(-1) == "*"
  if startsWild and not endsWild then return assetKey:sub(-#ruleKey) == ruleKey end
  if endsWild and not startsWild then return assetKey:sub(1, #ruleKey) == ruleKey end
  if not startsWild and not endsWild then return assetKey == ruleKey end
  return assetKey:find(ruleKey, 1, true) ~= nil
end

local function assetCapabilities(asset)
  local capabilities = {}
  for capability, tier in pairs(Plugin.policy.tiers or {}) do
    for _, rule in ipairs(tier.assets or {}) do
      if ruleMatches(asset, rule) then
        capabilities[capability] = true
        break
      end
    end
  end
  return capabilities
end

local function capabilityList(capabilities)
  local out = {}
  for capability, enabled in pairs(capabilities or {}) do
    if enabled then out[#out + 1] = capability end
  end
  table.sort(out)
  return out
end

local function capabilityText(capabilities)
  return table.concat(capabilityList(capabilities), "+")
end

local function loadConfig(BMF)
  local loaded = BMF.storage and BMF.storage.readConfig and BMF.storage.readConfig() or nil
  local config = loaded and loaded.ok and loaded.data and loaded.data.value or {}
  local policy = type(config.policy) == "table" and config.policy or {}
  Plugin.policy.savedDir = trim(policy.savedDir)
  Plugin.policy.tiers = {}
  for capability, tier in pairs(type(policy.tiers) == "table" and policy.tiers or {}) do
    local key = normalizeName(capability)
    if key ~= "" then
      Plugin.policy.tiers[key] = {
        roles = normalizeList(type(tier) == "table" and tier.roles or {}),
        assets = normalizeList(type(tier) == "table" and (tier.assets or tier.deniedAssets) or {}),
      }
    end
  end

  local native = type(config.native) == "table" and config.native or {}
  Plugin.native.controlPath = trim(native.controlPath)
  Plugin.native.statusPath = trim(native.statusPath)
  Plugin.native.eventPath = trim(native.eventPath)
  Plugin.native.trace = native.trace ~= false
  Plugin.native.refreshIntervalMilliseconds = math.max(1000, tonumber(native.refreshIntervalMilliseconds) or 5000)
  Plugin.native.eventPollIntervalMilliseconds = math.max(250, tonumber(native.eventPollIntervalMilliseconds) or 500)

  local prefabs = type(config.prefabs) == "table" and config.prefabs or {}
  Plugin.prefabs.enabled = prefabs.enabled ~= false
  Plugin.prefabs.indexPath = trim(prefabs.indexPath) ~= "" and trim(prefabs.indexPath) or "prefab-index.json"
  Plugin.feedback = type(config.feedback) == "table" and config.feedback or Plugin.feedback
end

local function refreshRoleAssignments(BMF, force)
  local now = os.time()
  if not force and Plugin.roleAssignments and now - Plugin.roleAssignmentsLoadedAt < 5 then
    return Plugin.roleAssignments
  end
  Plugin.roleAssignmentsLoadedAt = now
  local options = {}
  if Plugin.policy.savedDir ~= "" then options.savedDir = Plugin.policy.savedDir end
  local loaded = BMF.permissions and BMF.permissions.loadRoleAssignments
    and BMF.permissions.loadRoleAssignments(options) or nil
  if loaded and loaded.ok and loaded.data then
    Plugin.roleAssignments = loaded.data.assignments
  end
  return Plugin.roleAssignments
end

local function playerRoles(BMF, player)
  local assignments = refreshRoleAssignments(BMF, false)
  local uuid = playerId(player)
  if assignments and uuid ~= "" and BMF.permissions and BMF.permissions.getPlayerRoles then
    local resolved = BMF.permissions.getPlayerRoles(assignments, uuid)
    if resolved and resolved.ok and resolved.data then return resolved.data.roles or {} end
  end
  return type(player) == "table" and normalizeList(player.roles or player.roleNames or player.role) or {}
end

local function rolesToCapabilities(roles)
  local normalizedRoles = {}
  for _, role in ipairs(roles or {}) do normalizedRoles[normalizeName(role)] = true end
  local capabilities = {}
  for capability, tier in pairs(Plugin.policy.tiers or {}) do
    for _, allowedRole in ipairs(tier.roles or {}) do
      if normalizedRoles[normalizeName(allowedRole)] then
        capabilities[capability] = true
        break
      end
    end
  end
  return capabilities
end

local function loadPrefabIndex(BMF)
  Plugin.prefabs.entries = {}
  if not Plugin.prefabs.enabled then Plugin.prefabs.code = "DISABLED" return end
  local loaded = BMF.storage and BMF.storage.readJson and BMF.storage.readJson(Plugin.prefabs.indexPath) or nil
  Plugin.prefabs.code = tostring(loaded and loaded.code or "STORAGE_API_UNAVAILABLE")
  local value = loaded and loaded.ok and loaded.data and loaded.data.value or nil
  if type(value) ~= "table" then return end
  local entries = value.deniedPrefabHashes
    or value.restrictedPrefabHashes
    or (type(value.data) == "table" and value.data.deniedPrefabHashes)
    or {}
  for _, entry in ipairs(entries) do
    local hash = normalizeHash(entry.hash or entry.prefabHash or entry.brPrefabHashCandidate)
    local capabilities = {}
    for _, capability in ipairs(normalizeList(entry.requiredCapabilities)) do
      capabilities[normalizeName(capability)] = true
    end
    if next(capabilities) == nil then
      for _, asset in ipairs(normalizeList(entry.deniedAssets or entry.assets or entry.assetNames)) do
        for capability in pairs(assetCapabilities(asset)) do capabilities[capability] = true end
      end
    end
    if hash ~= "" and next(capabilities) ~= nil then
      local label = trim(entry.asset or entry.name)
      if label == "" and type(entry.deniedAssets) == "table" then label = trim(entry.deniedAssets[1]) end
      Plugin.prefabs.entries[#Plugin.prefabs.entries + 1] = {
        hash = hash,
        asset = label,
        capabilities = capabilities,
      }
    end
  end
  table.sort(Plugin.prefabs.entries, function(left, right) return left.hash < right.hash end)
end

local function indexPlayers(players)
  local byId, byName, ambiguous = {}, {}, {}
  for _, player in ipairs(players or {}) do
    local uuid = playerId(player):lower()
    if uuid ~= "" then byId[uuid] = player end
    for _, name in ipairs(playerNames(player)) do
      local key = normalizeName(name)
      if key ~= "" then
        if byName[key] and byName[key] ~= player then ambiguous[key] = true else byName[key] = player end
      end
    end
  end
  for key in pairs(ambiguous) do byName[key] = nil end
  return byId, byName
end

local function resolveControllerPlayer(controller, byId, byName)
  local uuid = trim(controller.playerId):lower()
  if uuid ~= "" and byId[uuid] then return byId[uuid] end
  for _, key in ipairs({ "name", "userName", "displayName" }) do
    local name = trim(controller[key])
    if name ~= "" then
      local player = byName[normalizeName(name)]
      if player then return player end
    end
  end
  return nil
end

local function collectContextCapabilities(BMF)
  local listed = BMF.players and BMF.players.list and BMF.players.list({ liveControllers = true }) or nil
  local data = listed and listed.ok and listed.data or {}
  local byId, byName = indexPlayers(data.players or {})
  local contexts, contextPlayers = {}, {}
  local matched, unmatched = 0, 0
  for _, controller in ipairs(data.liveControllers or {}) do
    local context = normalizeContext(controller.controllerName or controller.controllerPath)
    local player = resolveControllerPlayer(controller, byId, byName)
    if context ~= "" and player then
      local capabilities = rolesToCapabilities(playerRoles(BMF, player))
      if next(capabilities) ~= nil then contexts[context] = capabilities end
      contextPlayers[context] = player
      matched = matched + 1
    else
      unmatched = unmatched + 1
    end
  end
  Plugin.contextCapabilities = contexts
  Plugin.contextPlayers = contextPlayers
  Plugin.stats.matchedControllers = matched
  Plugin.stats.unmatchedControllers = unmatched
  return contexts
end

local function rewriteDeniedAssetLine(line)
  local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
  if key ~= "denied_asset" and key ~= "deny_asset" and key ~= "denied_entity" and key ~= "deny_entity" then
    return line
  end
  local address, asset = value:match("^([^|]+)|([^|]+)")
  if not address or not asset then return line end
  local required = assetCapabilities(asset)
  local text = capabilityText(required)
  if text == "" then text = "legacy" end
  return "denied_asset=" .. trim(address) .. "|" .. trim(asset) .. "|" .. text
end

local function writeNativePolicy(BMF, reason)
  local raw = readText(Plugin.native.controlPath)
  if not raw or trim(raw) == "" then
    Plugin.native.lastWriteCode = "CONTROL_NOT_FOUND"
    return false
  end
  local lines = {}
  for line in raw:gmatch("[^\r\n]+") do
    local key = line:match("^%s*([%w_]+)%s*=")
    if key ~= "allowed_context" and key ~= "allow_context"
      and key ~= "allowed_context_capability" and key ~= "allow_context_capability"
      and key ~= "denied_prefab_hash" and key ~= "deny_prefab_hash"
      and key ~= "denied_hash" and key ~= "deny_hash"
      and key ~= "enable" and key ~= "block" and key ~= "trace" then
      lines[#lines + 1] = rewriteDeniedAssetLine(line)
    end
  end
  lines[#lines + 1] = "enable=1"
  lines[#lines + 1] = "block=1"
  lines[#lines + 1] = "trace=" .. (Plugin.native.trace and "1" or "0")
  local contexts = collectContextCapabilities(BMF)
  local contextKeys = {}
  for context in pairs(contexts) do contextKeys[#contextKeys + 1] = context end
  table.sort(contextKeys)
  for _, context in ipairs(contextKeys) do
    for _, capability in ipairs(capabilityList(contexts[context])) do
      lines[#lines + 1] = "allowed_context_capability=" .. context .. "|" .. capability
    end
  end
  for _, prefab in ipairs(Plugin.prefabs.entries or {}) do
    lines[#lines + 1] = "denied_prefab_hash=" .. prefab.hash .. "|" .. prefab.asset .. "|" .. capabilityText(prefab.capabilities)
  end
  local desired = table.concat(lines, "\n") .. "\n"
  if desired == raw then
    Plugin.native.lastWriteCode = "UNCHANGED"
    return true
  end
  if not writeText(Plugin.native.controlPath, desired) then
    Plugin.native.lastWriteCode = "CONTROL_WRITE_FAILED"
    return false
  end
  Plugin.native.lastControl = desired
  Plugin.native.lastWriteCode = "OK"
  Plugin.native.writeCount = Plugin.native.writeCount + 1
  Plugin.stats.refreshes = Plugin.stats.refreshes + 1
  BMF.audit.record("placement.tiered_policy.refresh", {
    reason = tostring(reason or ""),
    contextCount = #contextKeys,
    prefabCount = #(Plugin.prefabs.entries or {}),
  })
  return true
end

local function currentPlayerCacheGeneration(BMF)
  local listed = BMF.players and BMF.players.list and BMF.players.list() or nil
  local generation = listed and listed.ok and listed.data
    and tonumber(listed.data.cacheGeneration) or nil
  Plugin.native.generationChecks = Plugin.native.generationChecks + 1
  if generation == nil then
    Plugin.native.lastGenerationCheckCode = "CACHE_GENERATION_UNAVAILABLE"
    return nil
  end
  return generation
end

local function rememberCurrentPlayerCacheGeneration(BMF)
  local generation = currentPlayerCacheGeneration(BMF)
  if generation ~= nil then
    Plugin.native.lastPlayerCacheGeneration = generation
    Plugin.native.lastGenerationCheckCode = "RECORDED"
  end
  return generation
end

local function refreshNativePolicyIfChanged(BMF)
  local generation = currentPlayerCacheGeneration(BMF)
  if generation == nil then return false end
  if generation == Plugin.native.lastPlayerCacheGeneration then
    Plugin.native.unchangedRefreshSkips = Plugin.native.unchangedRefreshSkips + 1
    Plugin.native.lastGenerationCheckCode = "UNCHANGED"
    return true
  end

  Plugin.native.lastGenerationCheckCode = "CHANGED"
  local written = writeNativePolicy(BMF, "player-cache-generation")
  -- A live-controller repair performed by writeNativePolicy can advance the
  -- registry generation. Record the post-refresh value so the timer does not
  -- trigger itself again on the next pass.
  rememberCurrentPlayerCacheGeneration(BMF)
  return written
end

local function readNewEvents()
  local size = fileSize(Plugin.native.eventPath)
  if size <= 0 then Plugin.native.cursor = 0 return "" end
  if Plugin.native.cursor > size then Plugin.native.cursor = 0 end
  if Plugin.native.cursor == size then return "" end
  local handle = io.open(Plugin.native.eventPath, "rb")
  if not handle then return "" end
  handle:seek("set", Plugin.native.cursor)
  local chunk = handle:read(math.min(65536, size - Plugin.native.cursor)) or ""
  Plugin.native.cursor = handle:seek("cur") or size
  handle:close()
  return chunk
end

local function capabilitiesFromText(value)
  local capabilities = {}
  for item in tostring(value or ""):gmatch("[^,+;]+") do
    local key = normalizeName(item)
    if key ~= "" and key ~= "none" then capabilities[key] = true end
  end
  return capabilities
end

local function capabilitiesSatisfied(available, required)
  for capability in pairs(required or {}) do
    if not available or not available[capability] then return false end
  end
  return true
end

local function feedbackMessage(required)
  if required.admin and required.mechanic then return Plugin.feedback.mixedMessage end
  if required.admin then return Plugin.feedback.adminMessage end
  return Plugin.feedback.mechanicMessage
end

local function handleEvent(BMF, event)
  if event.event ~= "block" and event.event ~= "allow" then return end
  local key = tostring(event.event) .. "|" .. tostring(event.policy_id or event.block_id or event.allow_id or "")
  if Plugin.processed[key] then return end
  Plugin.processed[key] = true
  Plugin.processedCount = Plugin.processedCount + 1
  if Plugin.processedCount > 4096 then Plugin.processed = {}; Plugin.processedCount = 0 end

  local context = normalizeContext(event.context)
  local required = capabilitiesFromText(event.required_capabilities)
  Plugin.stats.lastContext = context
  Plugin.stats.lastRequiredCapabilities = capabilityText(required)
  Plugin.stats.lastAsset = trim(event.asset_name or event.asset)
  Plugin.stats.lastPrefabHash = normalizeHash(event.prefab_hash)
  if event.event == "allow" then Plugin.stats.nativeAllows = Plugin.stats.nativeAllows + 1 return end
  Plugin.stats.nativeBlocks = Plugin.stats.nativeBlocks + 1

  local player = Plugin.contextPlayers[context]
  local available = Plugin.contextCapabilities[context] or {}
  if not capabilitiesSatisfied(available, required) then
    writeNativePolicy(BMF, "native-block-refresh")
    player = Plugin.contextPlayers[context] or player
    available = Plugin.contextCapabilities[context] or available
  end
  BMF.audit.record("placement.tiered_policy.block", {
    context = context,
    player = playerId(player),
    asset = Plugin.stats.lastAsset,
    prefabHash = Plugin.stats.lastPrefabHash,
    requiredCapabilities = capabilityList(required),
    availableCapabilities = capabilityList(available),
  })
  if Plugin.feedback.enabled and player and BMF.chat and type(BMF.chat.whisper) == "function" then
    local message = capabilitiesSatisfied(available, required)
      and Plugin.feedback.retryMessage or feedbackMessage(required)
    local sent = BMF.chat.whisper(player, message)
    if sent and sent.ok then Plugin.stats.feedbackDelivered = Plugin.stats.feedbackDelivered + 1 end
  end
end

local function pollEvents(BMF)
  local chunk = readNewEvents()
  for line in chunk:gmatch("[^\r\n]+") do handleEvent(BMF, parseEvent(line)) end
end

local function statusLines()
  local contexts = 0
  for _ in pairs(Plugin.contextCapabilities) do contexts = contexts + 1 end
  return {
    "policy=tieredBrickPlacementGuard",
    "enforcement=ServerPlaceSimpleEntityVolume+ServerPastePrefab-native-capabilities",
    "tiers=" .. table.concat(capabilityList((function()
      local out = {}; for capability in pairs(Plugin.policy.tiers) do out[capability] = true end; return out
    end)()), "|"),
    "context_count=" .. tostring(contexts),
    "matched_controller_count=" .. tostring(Plugin.stats.matchedControllers),
    "unmatched_controller_count=" .. tostring(Plugin.stats.unmatchedControllers),
    "prefab_index_code=" .. tostring(Plugin.prefabs.code),
    "restricted_prefab_hash_count=" .. tostring(#Plugin.prefabs.entries),
    "native_policy_write_code=" .. tostring(Plugin.native.lastWriteCode),
    "native_policy_write_count=" .. tostring(Plugin.native.writeCount),
    "player_cache_generation=" .. tostring(Plugin.native.lastPlayerCacheGeneration),
    "generation_checks=" .. tostring(Plugin.native.generationChecks),
    "unchanged_refresh_skips=" .. tostring(Plugin.native.unchangedRefreshSkips),
    "generation_check_code=" .. tostring(Plugin.native.lastGenerationCheckCode),
    "native_blocks=" .. tostring(Plugin.stats.nativeBlocks),
    "native_allows=" .. tostring(Plugin.stats.nativeAllows),
    "feedback_delivered=" .. tostring(Plugin.stats.feedbackDelivered),
    "last_context=" .. tostring(Plugin.stats.lastContext),
    "last_required_capabilities=" .. tostring(Plugin.stats.lastRequiredCapabilities),
    "last_asset=" .. tostring(Plugin.stats.lastAsset),
    "last_prefab_hash=" .. tostring(Plugin.stats.lastPrefabHash),
  }
end

function Plugin.onLoad(BMF)
  loadConfig(BMF)
  refreshRoleAssignments(BMF, true)
  loadPrefabIndex(BMF)
  Plugin.native.cursor = fileSize(Plugin.native.eventPath)
  writeNativePolicy(BMF, "plugin-load")
  rememberCurrentPlayerCacheGeneration(BMF)

  BMF.commands.register("bmf.tieredplacement.status", "Show tiered brick placement policy status.", function()
    refreshRoleAssignments(BMF, true)
    loadPrefabIndex(BMF)
    writeNativePolicy(BMF, "status-command")
    rememberCurrentPlayerCacheGeneration(BMF)
    pollEvents(BMF)
    return BMF.result(true, "OK", "Tiered brick placement guard status", { lines = statusLines() })
  end)

  BMF.commands.register("bmf.tieredplacement.refresh", "Refresh tiered placement roles and native policy.", function()
    refreshRoleAssignments(BMF, true)
    loadPrefabIndex(BMF)
    local written = writeNativePolicy(BMF, "refresh-command")
    rememberCurrentPlayerCacheGeneration(BMF)
    return BMF.result(written, written and "OK" or Plugin.native.lastWriteCode, "Tiered placement policy refreshed", {
      lines = statusLines(),
    })
  end)

  if BMF.timers and type(BMF.timers.every) == "function" then
    BMF.timers.every(Plugin.native.eventPollIntervalMilliseconds, function() pollEvents(BMF) end)
    BMF.timers.every(Plugin.native.refreshIntervalMilliseconds, function() refreshNativePolicyIfChanged(BMF) end)
  end
  BMF.logInfo("TieredBrickPlacementGuard loaded", {
    tiers = #capabilityList((function() local out = {}; for capability in pairs(Plugin.policy.tiers) do out[capability] = true end; return out end)()),
    restrictedPrefabs = #Plugin.prefabs.entries,
  })
end

return Plugin
