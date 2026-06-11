local MOD_NAME = "BMF"
local VERSION = "0.1.0-dev"
local ROOT = "ue4ss/main/Mods/" .. MOD_NAME
local RUNTIME_DIR = ROOT .. "/runtime"
local PLUGINS_DIR = ROOT .. "/plugins"
local CONFIG_PATH = ROOT .. "/config.json"
local STATUS_PATH = RUNTIME_DIR .. "/status.json"
BMF_TELEMETRY_PATH = RUNTIME_DIR .. "/telemetry.json"
local LOG_PATH = RUNTIME_DIR .. "/bmf.log"
local EVENT_LOG_PATH = RUNTIME_DIR .. "/events.jsonl"
local AUDIT_LOG_PATH = RUNTIME_DIR .. "/audit.jsonl"
local PLUGIN_LOG_DIR = RUNTIME_DIR .. "/logs/plugins"
local COMMAND_DIR = RUNTIME_DIR .. "/commands"
local PLAYER_CACHE_PATH = RUNTIME_DIR .. "/players.json"
local MINIGAME_DEFINITIONS_PATH = RUNTIME_DIR .. "/minigames/definitions.json"
local TARGET_BRICKADIA_BUILD = "PC-Shipping-CL13530"
local TARGET_BRICKADIA_NAME = "Brickadia EA2"
local TARGET_SERVER_EXECUTABLE = "BrickadiaServer-Win64-Shipping.exe"
local TARGET_PLATFORM = "windows-dedicated-server"
local BUILD_DETECTION_MODE = "declared-target-only"
local UNSUPPORTED_BUILD_POLICY = "report-only"
local COMMAND_EMPTY_READ_RETRY_LIMIT = 5
BMF_COMMAND_WORKER_DEFAULT_POLL_MS = 250
BMF_COMMAND_WORKER_FALLBACK_POLL_MS = 1000
BMF_COMMAND_WORKER_DEFAULT_MAX_FILES_PER_POLL = 1
local SOCKET_DEFAULT_POLL_MS = 25

local state = {
  started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  started_epoch = os.time(),
  plugins = {},
  plugin_errors = {},
  plugin_watchdog = {},
  plugin_unsafe_global_denials = {},
  timers = {},
  next_timer_id = 1,
  event_handlers = {},
  next_event_handler_id = 1,
  audit_records = {},
  audit_max_records = 200,
  minigame_events = {
    total = 0,
    by_event = {},
    recent = {},
    max_recent = 50,
    last = nil,
  },
  telemetry = {
    schema_version = 1,
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    updated_at = "",
    last_write_epoch = 0,
    write_interval_seconds = 5,
    commands = {
      total = 0,
      ok = 0,
      error = 0,
      by_name = {},
      by_transport = {},
      last = nil,
    },
    events = {
      total = 0,
      ok = 0,
      error = 0,
      handler_calls = 0,
      handler_errors = 0,
      by_event = {},
      last = nil,
    },
    plugins = {
      hook_total = 0,
      hook_ok = 0,
      hook_error = 0,
      by_plugin = {},
      by_hook = {},
      last = nil,
    },
    scheduler = {
      callback_total = 0,
      callback_ok = 0,
      callback_error = 0,
      by_key = {},
      last = nil,
    },
    workers = {
      command_polls = {
        count = 0,
        ok = 0,
        error = 0,
        duration_ms_sum = 0,
        duration_ms_max = 0,
        last_ms = 0,
        files_processed = 0,
      },
      socket_drains = {
        count = 0,
        ok = 0,
        error = 0,
        duration_ms_sum = 0,
        duration_ms_max = 0,
        last_ms = 0,
        messages = 0,
      },
    },
  },
  minigame_data = {
    updated_at = "",
    source = "",
    total_updates = 0,
    last_event = nil,
    minigames_by_key = {},
    players_by_key = {},
    memberships_by_player = {},
    teams_by_key = {},
    team_memberships_by_player = {},
    leaderboards_by_player = {},
    rounds_by_key = {},
  },
  minigame_definitions = {
    loaded = false,
    updated_at = "",
    source = "",
    total_updates = 0,
    last_error = "",
    records_by_key = {},
  },
  rate_limits = {},
  game_thread_callbacks = {},
  game_thread_callback_order = {},
  game_thread_callback_retention_limit = 65536,
  next_game_thread_callback_id = 1,
  delayed_callbacks = {},
  delayed_callback_order = {},
  delayed_callback_retention_limit = 65536,
  next_delayed_callback_id = 1,
  commands = {},
  console_command_callbacks = {},
  command_worker_started = false,
  command_worker_mode = "stopped",
  command_worker_poll_interval_ms = BMF_COMMAND_WORKER_DEFAULT_POLL_MS,
  command_worker_fallback_poll_interval_ms = BMF_COMMAND_WORKER_FALLBACK_POLL_MS,
  command_worker_max_files_per_poll = BMF_COMMAND_WORKER_DEFAULT_MAX_FILES_PER_POLL,
  command_dir_ensured = false,
  command_inflight_files = {},
  socket_worker_started = false,
  command_empty_reads = {},
  socket = {
    enabled = false,
    available = false,
    started = false,
    host = "",
    port = 0,
    token = "",
    poll_interval_ms = SOCKET_DEFAULT_POLL_MS,
    sent_events = 0,
    sent_responses = 0,
    received_commands = 0,
    received_messages = 0,
    poll_count = 0,
    last_poll_at = "",
    last_drain_count = 0,
    last_error = "",
    last_status = "",
    last_started_at = "",
  },
  player_cache = nil,
  player_cache_error = "",
  server_ready = false,
  server_ready_data = nil,
  plugin_tick_timer_id = nil,
  plugin_tick_count = 0,
  plugin_tick_interval_ms = 1000,
  tools = {
    applicator = {
      enabled = false,
      registered = false,
      registering = false,
      hook_path = "",
      pre_id = nil,
      post_id = nil,
      callback = nil,
      handlers = {},
      next_handler_id = 1,
      events = {},
      max_events = 50,
      total_events = 0,
      denied_events = 0,
      param_null_events = 0,
      allowed_events = 0,
      component_cache = {},
      component_cache_notes = {},
      last_error = "",
      last_event = nil,
    },
    tree_cut_trace = {
      enabled = false,
      registered = false,
      registering = false,
      include_apply_damage = true,
      include_melee = false,
      hooks = {},
      events = {},
      max_events = 100,
      sample_limit = 200,
      sample_count = 0,
      total_events = 0,
      apply_damage_events = 0,
      melee_events = 0,
      handaxe_events = 0,
      tree_like_events = 0,
      candidate_events = 0,
      last_error = "",
      last_event = nil,
      last_enabled_at = "",
      last_disabled_at = "",
    },
    tree_cut_native = {
      enabled = false,
      available = false,
      started = false,
      total_events = 0,
      drained_events = 0,
      emitted_events = 0,
      decode_errors = 0,
      last_event = nil,
      last_started_at = "",
      last_handaxe_resolved_at = "",
      last_target_refresh_at = "",
      last_error = "",
      last_status = "",
      physical_sequence = 0,
      last_physical_result = nil,
    },
    brick_runtime = {
      sequence = 0,
      last_result = nil,
      last_error = "",
    },
  },
  config = {
    allowPluginServerExec = false,
    allowPluginServerShutdown = false,
    jsonlLogs = true,
    pluginWatchdogEnabled = true,
    pluginWatchdogMaxErrors = 3,
    allowPluginUnsafeGlobals = false,
    allowUnsafeApplicatorLuaHook = false,
    allowUnsafeMinigameConsoleCommands = false,
    allowUnsafeMinigameObjectSnapshot = false,
    brickadiaSavedDir = "",
  },
}

local write_status
local API_REGISTRY

local UNSAFE_PLUGIN_GLOBAL_NAMES = {
  "EGameThreadMethod",
  "ExecuteInGameThread",
  "ExecuteInGameThreadWithDelay",
  "ExecuteWithDelay",
  "FindAllOf",
  "FindFirstOf",
  "LoadAsset",
  "NotifyOnNewObject",
  "OmeggaExecuteCachedConsoleExec",
  "OmeggaExecuteConsoleManagerInput",
  "OmeggaExecuteKismetConsoleCommand",
  "RegisterConsoleCommandGlobalHandler",
  "RegisterHook",
  "StaticConstructObject",
  "StaticFindObject",
  "UnregisterHook",
}
local UNSAFE_PLUGIN_GLOBALS = {}
for _, name in ipairs(UNSAFE_PLUGIN_GLOBAL_NAMES) do
  UNSAFE_PLUGIN_GLOBALS[name] = true
end

local function normalize_parent(path)
  local normalized = tostring(path or ""):gsub("/", "\\")
  return normalized:match("^(.*)\\[^\\]+$")
end

local function ensure_parent(path)
  local parent = normalize_parent(path)
  if parent and parent ~= "" then
    os.execute('if not exist "' .. parent .. '" mkdir "' .. parent .. '"')
  end
end

local function append_file(path, value)
  ensure_parent(path)
  local handle = io.open(path, "a")
  if not handle then
    return false
  end
  handle:write(value)
  handle:close()
  return true
end

local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then
    return nil
  end
  local data = handle:read("*a")
  handle:close()
  return data
end

local function write_file(path, value)
  ensure_parent(path)
  local handle = io.open(path, "w")
  if not handle then
    return false
  end
  handle:write(value)
  handle:close()
  return true
end

local function safe_name(value, label)
  local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil, label .. " is required"
  end
  if text:match("[%c]") or text:match("[/\\]") or text:match("%.%.") then
    return nil, label .. " must not contain control characters or path separators"
  end
  return text
end

local function safe_relative_path(value, label)
  local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil, label .. " is required"
  end
  if text:match("[%c]") or text:match("^/") or text:match("^\\") or text:match("%.%.") then
    return nil, label .. " must be a relative path without traversal"
  end
  return text:gsub("\\", "/")
end

local function json_escape(value)
  local ok, text = pcall(tostring, value or "")
  if not ok or type(text) ~= "string" then
    text = "<unstringifiable:" .. type(value) .. ">"
  end
  text = text:gsub("\\", "\\\\")
  text = text:gsub("\"", "\\\"")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\t", "\\t")
  return text
end

local function json_string(value)
  return "\"" .. json_escape(value) .. "\""
end

local function json_encode(value, depth)
  depth = depth or 0
  if depth > 6 then
    return json_string("<max-depth>")
  end

  local value_type = type(value)
  if value_type == "nil" then
    return "null"
  end
  if value_type == "boolean" then
    return value and "true" or "false"
  end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return tostring(value)
  end
  if value_type == "string" then
    return json_string(value)
  end
  if value_type ~= "table" then
    return json_string(tostring(value))
  end

  local is_array = true
  local max_index = 0
  local count = 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      is_array = false
      break
    end
    if key > max_index then
      max_index = key
    end
  end
  if is_array and max_index == count then
    local items = {}
    for index = 1, max_index do
      items[#items + 1] = json_encode(value[index], depth + 1)
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = json_string(key) .. ":" .. json_encode(value[key], depth + 1)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function json_decode(raw)
  local text = tostring(raw or ""):gsub("^\239\187\191", "")
  local length = #text
  local pos = 1

  local function skip_ws()
    while pos <= length do
      local c = text:sub(pos, pos)
      if c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then
        break
      end
      pos = pos + 1
    end
  end

  local parse_value

  local function parse_string()
    if text:sub(pos, pos) ~= "\"" then
      return nil, "expected string"
    end
    pos = pos + 1
    local parts = {}
    while pos <= length do
      local c = text:sub(pos, pos)
      if c == "\"" then
        pos = pos + 1
        return table.concat(parts), nil
      end
      if c == "\\" then
        local escaped = text:sub(pos + 1, pos + 1)
        if escaped == "\"" or escaped == "\\" or escaped == "/" then
          parts[#parts + 1] = escaped
          pos = pos + 2
        elseif escaped == "b" then
          parts[#parts + 1] = "\b"
          pos = pos + 2
        elseif escaped == "f" then
          parts[#parts + 1] = "\f"
          pos = pos + 2
        elseif escaped == "n" then
          parts[#parts + 1] = "\n"
          pos = pos + 2
        elseif escaped == "r" then
          parts[#parts + 1] = "\r"
          pos = pos + 2
        elseif escaped == "t" then
          parts[#parts + 1] = "\t"
          pos = pos + 2
        elseif escaped == "u" then
          local hex = text:sub(pos + 2, pos + 5)
          if not hex:match("^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$") then
            return nil, "invalid unicode escape"
          end
          local code = tonumber(hex, 16) or 63
          if code >= 32 and code <= 126 then
            parts[#parts + 1] = string.char(code)
          else
            parts[#parts + 1] = "?"
          end
          pos = pos + 6
        else
          return nil, "invalid escape"
        end
      else
        if c < " " then
          return nil, "control character in string"
        end
        parts[#parts + 1] = c
        pos = pos + 1
      end
    end
    return nil, "unterminated string"
  end

  local function parse_number()
    local start_pos = pos
    if text:sub(pos, pos) == "-" then
      pos = pos + 1
    end
    if text:sub(pos, pos) == "0" then
      pos = pos + 1
    else
      if not text:sub(pos, pos):match("%d") then
        return nil, "invalid number"
      end
      while pos <= length and text:sub(pos, pos):match("%d") do
        pos = pos + 1
      end
    end
    if text:sub(pos, pos) == "." then
      pos = pos + 1
      if not text:sub(pos, pos):match("%d") then
        return nil, "invalid number fraction"
      end
      while pos <= length and text:sub(pos, pos):match("%d") do
        pos = pos + 1
      end
    end
    local exponent = text:sub(pos, pos)
    if exponent == "e" or exponent == "E" then
      pos = pos + 1
      local sign = text:sub(pos, pos)
      if sign == "+" or sign == "-" then
        pos = pos + 1
      end
      if not text:sub(pos, pos):match("%d") then
        return nil, "invalid number exponent"
      end
      while pos <= length and text:sub(pos, pos):match("%d") do
        pos = pos + 1
      end
    end
    local number = tonumber(text:sub(start_pos, pos - 1))
    if number == nil then
      return nil, "invalid number"
    end
    return number, nil
  end

  local function parse_array()
    pos = pos + 1
    local array = {}
    skip_ws()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return array, nil
    end
    while pos <= length do
      local value, err = parse_value()
      if err then
        return nil, err
      end
      array[#array + 1] = value
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "]" then
        pos = pos + 1
        return array, nil
      end
      if c ~= "," then
        return nil, "expected array separator"
      end
      pos = pos + 1
    end
    return nil, "unterminated array"
  end

  local function parse_object()
    pos = pos + 1
    local object = {}
    skip_ws()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return object, nil
    end
    while pos <= length do
      skip_ws()
      local key, key_err = parse_string()
      if key_err then
        return nil, key_err
      end
      skip_ws()
      if text:sub(pos, pos) ~= ":" then
        return nil, "expected object colon"
      end
      pos = pos + 1
      local value, value_err = parse_value()
      if value_err then
        return nil, value_err
      end
      object[key] = value
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "}" then
        pos = pos + 1
        return object, nil
      end
      if c ~= "," then
        return nil, "expected object separator"
      end
      pos = pos + 1
    end
    return nil, "unterminated object"
  end

  parse_value = function()
    skip_ws()
    local c = text:sub(pos, pos)
    if c == "\"" then
      return parse_string()
    end
    if c == "{" then
      return parse_object()
    end
    if c == "[" then
      return parse_array()
    end
    if c == "-" or c:match("%d") then
      return parse_number()
    end
    if text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true, nil
    end
    if text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false, nil
    end
    if text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil, nil
    end
    return nil, "unexpected token"
  end

  local value, err = parse_value()
  if err then
    return nil, err
  end
  skip_ws()
  if pos <= length then
    return nil, "trailing data"
  end
  return value, nil
end

local function result(ok, code, message, data)
  return {
    ok = ok and true or false,
    code = tostring(code or (ok and "OK" or "ERROR")),
    message = tostring(message or ""),
    data = data or {},
  }
end

local function write_text_log(path, timestamp, level, message)
  local line = string.format(
    "%s [%s] %s\n",
    timestamp,
    tostring(level or "info"),
    tostring(message or "")
  )
  return append_file(path, line)
end

local function write_log_event(timestamp, level, message, context)
  if state.config.jsonlLogs == false then
    return true
  end
  context = context or {}
  local event = {
    ts = timestamp,
    level = tostring(level or "info"),
    source = tostring(context.source or "framework"),
    message = tostring(message or ""),
  }
  if context.plugin then
    event.plugin = tostring(context.plugin)
  end
  if type(context.data) == "table" then
    event.data = context.data
  end
  local encoded = json_encode(event)
  if BMF_socket_send_event_record then
    BMF_socket_send_event_record(event, encoded)
  end
  return append_file(EVENT_LOG_PATH, encoded .. "\n")
end

local function log(level, message, data)
  local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  write_text_log(LOG_PATH, timestamp, level, message)
  write_log_event(timestamp, level, message, {
    source = "framework",
    data = data,
  })
  print("[" .. MOD_NAME .. "] " .. tostring(message or ""))
end

local function plugin_log_path(plugin_name)
  local name, err = safe_name(plugin_name, "plugin name")
  if not name then
    return nil, err
  end
  return PLUGIN_LOG_DIR .. "/" .. name .. ".log", nil
end

local function log_plugin(plugin_name, level, message, data)
  local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local name = tostring(plugin_name or "")
  local plugin_path = plugin_log_path(name)
  if plugin_path then
    write_text_log(plugin_path, timestamp, level, message)
  end
  write_text_log(LOG_PATH, timestamp, level, "[" .. name .. "] " .. tostring(message or ""))
  write_log_event(timestamp, level, message, {
    source = "plugin",
    plugin = name,
    data = data,
  })
  print("[" .. MOD_NAME .. "/" .. name .. "] " .. tostring(message or ""))
end

local function audit_record(action, data, context)
  context = context or {}
  local record = {
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    action = tostring(action or "unknown"),
    source = tostring(context.source or "framework"),
    severity = tostring(context.severity or "info"),
  }
  if context.plugin then
    record.plugin = tostring(context.plugin)
  end
  if context.actor then
    record.actor = tostring(context.actor)
  end
  if context.ok ~= nil then
    record.ok = context.ok and true or false
  end
  if context.code then
    record.code = tostring(context.code)
  end
  if type(data) == "table" then
    record.data = data
  elseif data ~= nil then
    record.data = { value = tostring(data) }
  end

  local written = append_file(AUDIT_LOG_PATH, json_encode(record) .. "\n")
  state.audit_records[#state.audit_records + 1] = record
  while #state.audit_records > state.audit_max_records do
    table.remove(state.audit_records, 1)
  end
  write_status()

  return result(written, written and "OK" or "AUDIT_WRITE_FAILED", written and "Audit record written" or "Audit record could not be written", {
    path = AUDIT_LOG_PATH,
    record = record,
  })
end

local function normalize_log_args(default_level, a, b, c)
  if b == nil then
    return default_level, tostring(a or ""), nil
  end
  local first = tostring(a or ""):lower()
  if first == "debug" or first == "info" or first == "warn" or first == "error" then
    return first, tostring(b or ""), c
  end
  return default_level, tostring(a or ""), b
end

local function plugin_count()
  local count = 0
  for _ in pairs(state.plugins) do
    count = count + 1
  end
  return count
end

local function command_names()
  local names = {}
  for name in pairs(state.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function rate_limit_bucket_count()
  local count = 0
  for _ in pairs(state.rate_limits) do
    count = count + 1
  end
  return count
end

local function plugin_watchdog_isolated_count()
  local count = 0
  for _, item in pairs(state.plugin_watchdog) do
    if type(item) == "table" and item.isolated == true then
      count = count + 1
    end
  end
  return count
end

local function plugin_unsafe_global_denial_count()
  local count = 0
  for _ in pairs(state.plugin_unsafe_global_denials) do
    count = count + 1
  end
  return count
end

function BMF_telemetry_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function BMF_telemetry_duration_ms(start_clock)
  local started = tonumber(start_clock)
  if not started then
    return 0
  end
  local duration = (os.clock() - started) * 1000
  if duration < 0 then
    duration = 0
  end
  return math.floor(duration + 0.5)
end

function BMF_telemetry_key(value, fallback)
  local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    text = tostring(fallback or "unknown")
  end
  return text
end

function BMF_telemetry_series(map, key, fields)
  if type(map) ~= "table" then
    return nil
  end
  local normalized_key = BMF_telemetry_key(key, "unknown")
  local item = map[normalized_key]
  if type(item) ~= "table" then
    item = {}
    map[normalized_key] = item
  end
  if type(fields) == "table" then
    for field, value in pairs(fields) do
      item[field] = value
    end
  end
  return item
end

function BMF_telemetry_observe(item, duration_ms, ok)
  if type(item) ~= "table" then
    return
  end
  local ms = tonumber(duration_ms) or 0
  if ms < 0 then
    ms = 0
  end
  item.count = (tonumber(item.count) or 0) + 1
  if ok == false then
  item.error = (tonumber(item.error) or 0) + 1
  else
    item.ok = (tonumber(item.ok) or 0) + 1
  end
  item.duration_ms_sum = (tonumber(item.duration_ms_sum) or 0) + ms
  item.duration_ms_max = math.max(tonumber(item.duration_ms_max) or 0, ms)
  item.last_ms = ms
  item.last_at = BMF_telemetry_now()
end

function BMF_telemetry_add(item, field, value)
  if type(item) ~= "table" then
    return
  end
  item[field] = (tonumber(item[field]) or 0) + (tonumber(value) or 0)
end

function BMF_telemetry_snapshot()
  local telemetry = state.telemetry
  telemetry.updated_at = BMF_telemetry_now()
  telemetry.paths = {
    status = STATUS_PATH,
    telemetry = BMF_TELEMETRY_PATH,
  }
  telemetry.runtime = {
    plugins_loaded = plugin_count(),
    plugin_errors = #state.plugin_errors,
    plugin_tick_active = state.plugin_tick_timer_id ~= nil,
    plugin_tick_count = state.plugin_tick_count,
    server_ready = state.server_ready and true or false,
  }
  telemetry.socket = {
    started = state.socket.started and true or false,
    received_messages = tonumber(state.socket.received_messages) or 0,
    received_commands = tonumber(state.socket.received_commands) or 0,
    sent_responses = tonumber(state.socket.sent_responses) or 0,
    poll_count = tonumber(state.socket.poll_count) or 0,
    last_drain_count = tonumber(state.socket.last_drain_count) or 0,
  }
  return telemetry
end

function BMF_telemetry_write(force)
  local telemetry = state.telemetry
  local now_epoch = os.time()
  local interval = tonumber(telemetry.write_interval_seconds) or 5
  if not force and tonumber(telemetry.last_write_epoch or 0) > 0 and (now_epoch - telemetry.last_write_epoch) < interval then
    return false
  end
  telemetry.last_write_epoch = now_epoch
  return write_file(BMF_TELEMETRY_PATH, json_encode(BMF_telemetry_snapshot()) .. "\n")
end

function BMF_telemetry_record_command(command_name, transport, ok, detail, duration_ms, dispatch_ms, request_age_ms)
  local telemetry = state.telemetry.commands
  local normalized_command = BMF_telemetry_key(command_name, "unknown"):lower()
  local normalized_transport = BMF_telemetry_key(transport, "file"):lower()
  telemetry.total = (tonumber(telemetry.total) or 0) + 1
  if ok == false then
    telemetry.error = (tonumber(telemetry.error) or 0) + 1
  else
    telemetry.ok = (tonumber(telemetry.ok) or 0) + 1
  end

  BMF_telemetry_observe(BMF_telemetry_series(telemetry.by_name, normalized_command, {
    command = normalized_command,
  }), duration_ms, ok)
  BMF_telemetry_observe(BMF_telemetry_series(telemetry.by_transport, normalized_transport, {
    transport = normalized_transport,
  }), duration_ms, ok)

  telemetry.last = {
    command = normalized_command,
    transport = normalized_transport,
    ok = ok ~= false,
    detail = tostring(detail or ""),
    duration_ms = tonumber(duration_ms) or 0,
    dispatch_ms = tonumber(dispatch_ms) or 0,
    request_age_ms = tonumber(request_age_ms) or 0,
    at = BMF_telemetry_now(),
  }
  BMF_telemetry_write(true)
end

function BMF_telemetry_record_event_handler(event_name, owner, duration_ms, ok)
  local telemetry = state.telemetry.events
  local normalized_event = BMF_telemetry_key(event_name, "unknown")
  local item = BMF_telemetry_series(telemetry.by_event, normalized_event, {
    event = normalized_event,
  })
  BMF_telemetry_add(item, "handler_calls", 1)
  if ok == false then
    telemetry.handler_errors = (tonumber(telemetry.handler_errors) or 0) + 1
    BMF_telemetry_add(item, "handler_errors", 1)
  end
  BMF_telemetry_add(item, "handler_duration_ms_sum", duration_ms)
  item.handler_duration_ms_max = math.max(tonumber(item.handler_duration_ms_max) or 0, tonumber(duration_ms) or 0)
  item.handler_last_ms = tonumber(duration_ms) or 0

  if owner then
    BMF_telemetry_record_plugin_hook(owner, "event:" .. normalized_event, duration_ms, ok)
  end
end

function BMF_telemetry_record_event(event_name, handlers, errors, duration_ms)
  local telemetry = state.telemetry.events
  local normalized_event = BMF_telemetry_key(event_name, "unknown")
  local error_count = tonumber(errors) or 0
  local ok = error_count == 0
  telemetry.total = (tonumber(telemetry.total) or 0) + 1
  telemetry.handler_calls = (tonumber(telemetry.handler_calls) or 0) + (tonumber(handlers) or 0)
  if ok then
    telemetry.ok = (tonumber(telemetry.ok) or 0) + 1
  else
    telemetry.error = (tonumber(telemetry.error) or 0) + 1
  end

  local item = BMF_telemetry_series(telemetry.by_event, normalized_event, {
    event = normalized_event,
  })
  BMF_telemetry_observe(item, duration_ms, ok)
  BMF_telemetry_add(item, "handlers", handlers)
  telemetry.last = {
    event = normalized_event,
    ok = ok,
    handlers = tonumber(handlers) or 0,
    errors = error_count,
    duration_ms = tonumber(duration_ms) or 0,
    at = BMF_telemetry_now(),
  }
  BMF_telemetry_write(true)
end

function BMF_telemetry_record_plugin_hook(plugin_name, hook, duration_ms, ok)
  local telemetry = state.telemetry.plugins
  local normalized_plugin = BMF_telemetry_key(plugin_name, "unknown")
  local normalized_hook = BMF_telemetry_key(hook, "unknown")
  telemetry.hook_total = (tonumber(telemetry.hook_total) or 0) + 1
  if ok == false then
    telemetry.hook_error = (tonumber(telemetry.hook_error) or 0) + 1
  else
    telemetry.hook_ok = (tonumber(telemetry.hook_ok) or 0) + 1
  end

  BMF_telemetry_observe(BMF_telemetry_series(telemetry.by_plugin, normalized_plugin, {
    plugin = normalized_plugin,
  }), duration_ms, ok)
  BMF_telemetry_observe(BMF_telemetry_series(telemetry.by_hook, normalized_plugin .. "|" .. normalized_hook, {
    plugin = normalized_plugin,
    hook = normalized_hook,
  }), duration_ms, ok)

  telemetry.last = {
    plugin = normalized_plugin,
    hook = normalized_hook,
    ok = ok ~= false,
    duration_ms = tonumber(duration_ms) or 0,
    at = BMF_telemetry_now(),
  }
  BMF_telemetry_write(false)
end

function BMF_telemetry_record_scheduler(kind, name, duration_ms, ok)
  local telemetry = state.telemetry.scheduler
  local normalized_kind = BMF_telemetry_key(kind, "callback")
  local normalized_name = BMF_telemetry_key(name, "unknown")
  telemetry.callback_total = (tonumber(telemetry.callback_total) or 0) + 1
  if ok == false then
    telemetry.callback_error = (tonumber(telemetry.callback_error) or 0) + 1
  else
    telemetry.callback_ok = (tonumber(telemetry.callback_ok) or 0) + 1
  end

  BMF_telemetry_observe(BMF_telemetry_series(telemetry.by_key, normalized_kind .. "|" .. normalized_name, {
    kind = normalized_kind,
    name = normalized_name,
  }), duration_ms, ok)
  telemetry.last = {
    kind = normalized_kind,
    name = normalized_name,
    ok = ok ~= false,
    duration_ms = tonumber(duration_ms) or 0,
    at = BMF_telemetry_now(),
  }
  BMF_telemetry_write(false)
end

function BMF_telemetry_record_worker(name, duration_ms, ok, count_field, count_value)
  local workers = state.telemetry.workers
  local normalized_name = BMF_telemetry_key(name, "worker")
  local item = workers[normalized_name]
  if type(item) ~= "table" then
    item = {
      count = 0,
      ok = 0,
      error = 0,
      duration_ms_sum = 0,
      duration_ms_max = 0,
      last_ms = 0,
    }
    workers[normalized_name] = item
  end
  BMF_telemetry_observe(item, duration_ms, ok)
  if count_field then
    BMF_telemetry_add(item, count_field, count_value)
  end
  BMF_telemetry_write(false)
end

local function unsafe_plugin_global_names()
  local names = {}
  for _, name in ipairs(UNSAFE_PLUGIN_GLOBAL_NAMES) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local RUNTIME_HELPER_GROUPS = {
  {
    id = "consoleExecutor",
    required = true,
    anyOf = {
      "OmeggaExecuteConsoleManagerInput",
      "OmeggaExecuteKismetConsoleCommand",
      "OmeggaExecuteCachedConsoleExec",
    },
    summary = "Executes Brickadia console commands used by typed BMF wrappers.",
  },
  {
    id = "timerScheduler",
    required = true,
    anyOf = {
      "ExecuteWithDelay",
      "ExecuteInGameThreadWithDelay",
    },
    summary = "Schedules BMF timers and the file command worker.",
  },
  {
    id = "consoleCommandRegistration",
    required = false,
    anyOf = {
      "RegisterConsoleCommandGlobalHandler",
    },
    summary = "Registers direct bmf.* console commands when available.",
  },
  {
    id = "gameThread",
    required = false,
    anyOf = {
      "ExecuteInGameThread",
      "ExecuteInGameThreadWithDelay",
    },
    summary = "Runs callbacks on the game thread when native access needs it.",
  },
  {
    id = "objectLookup",
    required = false,
    anyOf = {
      "StaticFindObject",
      "FindFirstOf",
      "FindAllOf",
    },
    summary = "Supports future live-object discovery; plugins cannot use it directly by default.",
  },
}

local function runtime_helper_type(name)
  return type(_G and _G[name])
end

local function runtime_helper_available(name)
  return runtime_helper_type(name) == "function"
end

local function collect_runtime_helper_groups()
  local groups = {}
  local required_count = 0
  local required_available = 0
  local missing_required = {}

  for _, group in ipairs(RUNTIME_HELPER_GROUPS) do
    local helpers = {}
    local available_helpers = {}
    local group_available = false
    for _, helper_name in ipairs(group.anyOf or {}) do
      local helper = {
        name = helper_name,
        type = runtime_helper_type(helper_name),
        available = runtime_helper_available(helper_name),
      }
      helpers[#helpers + 1] = helper
      if helper.available then
        group_available = true
        available_helpers[#available_helpers + 1] = helper_name
      end
    end

    local item = {
      id = group.id,
      required = group.required == true,
      available = group_available,
      helpers = helpers,
      availableHelpers = available_helpers,
      summary = group.summary,
    }
    groups[#groups + 1] = item

    if group.required == true then
      required_count = required_count + 1
      if group_available then
        required_available = required_available + 1
      else
        missing_required[#missing_required + 1] = group.id
      end
    end
  end

  return groups, required_count, required_available, missing_required
end

local function compatibility_snapshot()
  local groups, required_count, required_available, missing_required = collect_runtime_helper_groups()
  local status = "ok"
  local ok = true
  if #missing_required > 0 then
    status = "missing-required-runtime-helpers"
    ok = false
  end

  return {
    ok = ok,
    status = status,
    version = VERSION,
    targetName = TARGET_BRICKADIA_NAME,
    targetBuild = TARGET_BRICKADIA_BUILD,
    supportedBuilds = { TARGET_BRICKADIA_BUILD },
    platform = TARGET_PLATFORM,
    serverExecutable = TARGET_SERVER_EXECUTABLE,
    buildDetection = BUILD_DETECTION_MODE,
    buildDetected = false,
    detectedBuild = "",
    unsupportedBuildPolicy = UNSUPPORTED_BUILD_POLICY,
    validationLevel = "L2 Headless",
    ue4ss = {
      required = true,
      status = "patched-runtime-required",
      helperGroups = groups,
      requiredGroupCount = required_count,
      requiredGroupsAvailable = required_available,
      missingRequiredGroups = missing_required,
    },
  }
end

write_status = function()
  local compatibility = compatibility_snapshot()
  local parts = {
    "\"state\":\"running\"",
    "\"mod\":\"BMF\"",
    "\"version\":" .. json_string(VERSION),
    "\"target_build\":" .. json_string(TARGET_BRICKADIA_BUILD),
    "\"build_detection\":" .. json_string(BUILD_DETECTION_MODE),
    "\"compatibility_status\":" .. json_string(compatibility.status),
    "\"runtime_required_helper_groups\":" .. tostring(compatibility.ue4ss.requiredGroupCount or 0),
    "\"runtime_required_helper_groups_available\":" .. tostring(compatibility.ue4ss.requiredGroupsAvailable or 0),
    "\"runtime_missing_required_helper_groups\":" .. tostring(#(compatibility.ue4ss.missingRequiredGroups or {})),
    "\"started_at\":" .. json_string(state.started_at),
    "\"updated_at\":" .. json_string(os.date("!%Y-%m-%dT%H:%M:%SZ")),
    "\"telemetry_path\":" .. json_string(BMF_TELEMETRY_PATH),
    "\"plugins_loaded\":" .. tostring(plugin_count()),
    "\"plugin_errors\":" .. tostring(#state.plugin_errors),
    "\"server_ready\":" .. tostring(state.server_ready and true or false),
    "\"command_worker_started\":" .. tostring(state.command_worker_started and true or false),
    "\"command_worker_mode\":" .. json_string(state.command_worker_mode or "unknown"),
    "\"command_worker_poll_interval_ms\":" .. tostring(state.command_worker_poll_interval_ms or 0),
    "\"command_worker_fallback_poll_interval_ms\":" .. tostring(state.command_worker_fallback_poll_interval_ms or 0),
    "\"command_worker_max_files_per_poll\":" .. tostring(state.command_worker_max_files_per_poll or 0),
    "\"plugin_tick_count\":" .. tostring(state.plugin_tick_count),
    "\"plugin_tick_active\":" .. tostring(state.plugin_tick_timer_id ~= nil),
    "\"audit_records\":" .. tostring(#state.audit_records),
    "\"rate_limit_buckets\":" .. tostring(rate_limit_bucket_count()),
    "\"plugin_watchdog_isolated\":" .. tostring(plugin_watchdog_isolated_count()),
    "\"api_labels\":" .. tostring(API_REGISTRY and #API_REGISTRY or 0),
    "\"plugin_unsafe_global_denials\":" .. tostring(plugin_unsafe_global_denial_count()),
    "\"plugin_unsafe_globals_allowed\":" .. tostring(state.config.allowPluginUnsafeGlobals == true)
  }
  write_file(STATUS_PATH, "{" .. table.concat(parts, ",") .. "}\n")
end

local function quote_console_string(value)
  return "\"" .. tostring(value or ""):gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\""
end

local function quote_console_token(value)
  local text = tostring(value or "")
  if text:match("^[A-Za-z0-9_%-]+$") then
    return text
  end
  return quote_console_string(text)
end

local function normalize_world_name(value)
  local name = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub("%.brdb$", "")
  if name == "" then
    return nil, "world name is required"
  end
  if name:match("[/\\]") or name:match("%.%.") then
    return nil, "world name must not contain path separators"
  end
  return name
end

local function finite_number(value, default)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    return default
  end
  return number
end

local function format_number(value)
  local number = finite_number(value, 0)
  if math.floor(number) == number then
    return tostring(math.floor(number))
  end
  return string.format("%.6f", number)
end

local function normalize_integer(value, label)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    return nil, label .. " must be a number"
  end
  number = math.floor(number)
  if number < 0 then
    return nil, label .. " must be zero or greater"
  end
  return number
end

local function trim_string(value)
  local text = tostring(value or ""):gsub("^\239\187\191", "")
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function BMF_env_string(name)
  if type(os.getenv) ~= "function" then
    return ""
  end
  return trim_string(os.getenv(name) or "")
end

function BMF_env_bool(name, default_value)
  local value = BMF_env_string(name)
  if value == "" then
    return default_value == true
  end
  local normalized = value:lower()
  if normalized == "0" or normalized == "false" or normalized == "no" or normalized == "off" then
    return false
  end
  if normalized == "1" or normalized == "true" or normalized == "yes" or normalized == "on" then
    return true
  end
  return default_value == true
end

function BMF_env_number(name, default_value, minimum)
  local value = tonumber(BMF_env_string(name))
  if value == nil or value ~= value or value == math.huge or value == -math.huge then
    value = tonumber(default_value) or 0
  end
  if minimum ~= nil and value < minimum then
    value = minimum
  end
  return math.floor(value + 0.5)
end

local function join_path(base, child)
  local left = tostring(base or ""):gsub("\\", "/"):gsub("/+$", "")
  local right = tostring(child or ""):gsub("\\", "/"):gsub("^/+", "")
  if left == "" then
    return right
  end
  if right == "" then
    return left
  end
  return left .. "/" .. right
end

local function first_string(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and trim_string(value) ~= "" then
      return value
    end
  end
  return nil
end

local function is_uuid(value)
  if type(value) ~= "string" then
    return false
  end
  return value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function copy_table(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy_table(child)
  end
  return out
end

local function table_count(values)
  local count = 0
  if type(values) == "table" then
    for _ in pairs(values) do
      count = count + 1
    end
  end
  return count
end

function BMF_socket_env(name)
  return BMF_env_string(name)
end

function BMF_socket_enabled_from_env()
  local explicit = BMF_socket_env("OMEGGA_BMF_SOCKET_ENABLED")
  if explicit == "0" or explicit:lower() == "false" then
    return false
  end
  return explicit == "1" or explicit:lower() == "true" or BMF_socket_env("OMEGGA_BMF_SOCKET_PORT") ~= ""
end

function BMF_socket_native_available()
  return type(BMFSocketStart) == "function"
    and type(BMFSocketSend) == "function"
    and type(BMFSocketReceive) == "function"
end

function BMF_socket_configure_from_env()
  state.socket.enabled = BMF_socket_enabled_from_env()
  state.socket.available = BMF_socket_native_available()
  state.socket.host = BMF_socket_env("OMEGGA_BMF_SOCKET_HOST")
  if state.socket.host == "" then
    state.socket.host = "127.0.0.1"
  end
  state.socket.port = tonumber(BMF_socket_env("OMEGGA_BMF_SOCKET_PORT")) or 0
  state.socket.token = BMF_socket_env("OMEGGA_BMF_SOCKET_TOKEN")
  state.socket.poll_interval_ms = math.max(5, tonumber(BMF_socket_env("OMEGGA_BMF_SOCKET_POLL_MS")) or SOCKET_DEFAULT_POLL_MS)
  write_file(RUNTIME_DIR .. "/socket.json", json_encode({
    enabled = state.socket.enabled,
    available = state.socket.available,
    host = state.socket.host,
    port = state.socket.port,
    token = state.socket.token,
    pollIntervalMs = state.socket.poll_interval_ms,
    updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }))
end

function BMF_socket_send_json(record)
  if not state.socket.started or type(BMFSocketSend) ~= "function" then
    return false
  end
  local ok, sent_or_error = pcall(BMFSocketSend, json_encode(record or {}))
  if ok and sent_or_error ~= false then
    return true
  end
  state.socket.last_error = tostring(sent_or_error or "BMFSocketSend failed")
  return false
end

function BMF_socket_send_event_record(event, encoded)
  if not state.socket.started then
    return false
  end
  local sent = BMF_socket_send_json({
    type = "event",
    source = "bmf",
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    record = event,
    record_json = encoded,
  })
  if sent then
    state.socket.sent_events = state.socket.sent_events + 1
  end
  return sent
end

function BMF_socket_status_snapshot()
  local native_status = ""
  if type(BMFSocketStatus) == "function" then
    local ok, value = pcall(BMFSocketStatus)
    native_status = ok and tostring(value or "") or ("status error: " .. tostring(value))
  end
  return {
    enabled = state.socket.enabled,
    available = state.socket.available,
    started = state.socket.started,
    host = state.socket.host,
    port = state.socket.port,
    pollIntervalMs = state.socket.poll_interval_ms,
    sentEvents = state.socket.sent_events,
    sentResponses = state.socket.sent_responses,
    receivedCommands = state.socket.received_commands,
    receivedMessages = state.socket.received_messages,
    pollCount = state.socket.poll_count,
    lastPollAt = state.socket.last_poll_at,
    lastDrainCount = state.socket.last_drain_count,
    workerStarted = state.socket_worker_started,
    lastError = state.socket.last_error,
    lastStatus = state.socket.last_status,
    lastStartedAt = state.socket.last_started_at,
    nativeStatus = native_status,
  }
end

local function permission_state_to_bool(value)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "string" then
    local lower = value:lower()
    if lower == "allowed" or lower == "allow" or lower == "true" then
      return true
    end
    if lower == "forbidden" or lower == "deny" or lower == "denied" or lower == "false" then
      return false
    end
  end
  return nil
end

local function exec_console(command)
  if type(OmeggaExecuteKismetConsoleCommand) == "function" then
    local ok, success, output = pcall(OmeggaExecuteKismetConsoleCommand, command)
    if ok and success then
      return result(true, "OK", "Command executed", { executor = "kismet", output = output or "" })
    end
    return result(false, "CONSOLE_EXEC_FAILED", tostring(output or success), { executor = "kismet" })
  end

  if type(OmeggaExecuteCachedConsoleExec) == "function" then
    local ok, success, output = pcall(OmeggaExecuteCachedConsoleExec, command)
    if ok and success then
      return result(true, "OK", "Command executed", { executor = "cached_console", output = output or "" })
    end
    return result(false, "CONSOLE_EXEC_FAILED", tostring(output or success), { executor = "cached_console" })
  end

  return result(false, "CONSOLE_EXEC_UNAVAILABLE", "No supported console executor is available.")
end

local function exec_console_manager(command)
  if type(OmeggaExecuteConsoleManagerInput) == "function" then
    local ok, success, output = pcall(OmeggaExecuteConsoleManagerInput, command)
    if ok and success then
      return result(true, "OK", "Command executed", { executor = "console_manager", output = output or "" })
    end
    return result(false, "CONSOLE_EXEC_FAILED", tostring(output or success), { executor = "console_manager" })
  end

  return exec_console(command)
end

local function run_on_game_thread(callback)
  if type(ExecuteInGameThread) == "function" and type(EGameThreadMethod) == "table" and EGameThreadMethod.EngineTick ~= nil then
    local id = state.next_game_thread_callback_id
    state.next_game_thread_callback_id = state.next_game_thread_callback_id + 1
    state.game_thread_callback_order[#state.game_thread_callback_order + 1] = id
    while #state.game_thread_callback_order > state.game_thread_callback_retention_limit do
      local old_id = table.remove(state.game_thread_callback_order, 1)
      state.game_thread_callbacks[old_id] = nil
    end
    state.game_thread_callbacks[id] = function()
      local retained = state.game_thread_callbacks[id]
      if retained then
        local ok, err = pcall(callback)
        if not ok then
          log("error", "game-thread callback failed: " .. tostring(err))
        end
      end
    end
    local scheduled = pcall(ExecuteInGameThread, state.game_thread_callbacks[id], EGameThreadMethod.EngineTick)
    if scheduled then
      return
    end
    state.game_thread_callbacks[id] = nil
  end

  if type(ExecuteInGameThreadWithDelay) == "function" then
    local scheduled = pcall(ExecuteInGameThreadWithDelay, 0, callback)
    if scheduled then
      return
    end
  end

  callback()
end

function BMF_retain_delayed_callback(prefix, callback)
  local key = tostring(prefix or "delay") .. ":" .. tostring(state.next_delayed_callback_id)
  state.next_delayed_callback_id = state.next_delayed_callback_id + 1
  state.delayed_callback_order[#state.delayed_callback_order + 1] = key
  while #state.delayed_callback_order > state.delayed_callback_retention_limit do
    local old_key = table.remove(state.delayed_callback_order, 1)
    state.delayed_callbacks[old_key] = nil
  end

  local wrapped
  wrapped = function(...)
    local ok, err = pcall(callback, ...)
    if not ok then
      log("error", "delayed callback failed: " .. tostring(err))
    end
  end
  state.delayed_callbacks[key] = wrapped
  return wrapped, key
end

function BMF_schedule_delayed_callback(prefix, delay_ms, callback)
  if type(callback) ~= "function" then
    return false
  end

  local delay = tonumber(delay_ms) or 0
  local wrapped, key = BMF_retain_delayed_callback(prefix, callback)

  if type(ExecuteWithDelay) == "function" then
    local scheduled = pcall(ExecuteWithDelay, delay, wrapped)
    if scheduled then
      return true
    end
  end

  if type(ExecuteInGameThreadWithDelay) == "function" then
    local scheduled = pcall(ExecuteInGameThreadWithDelay, delay, wrapped)
    if scheduled then
      return true
    end
  end

  if type(MakeActionHandle) == "function" and type(ExecuteInGameThreadWithDelay) == "function" then
    local ok, action_handle = pcall(MakeActionHandle)
    if ok and action_handle ~= nil then
      local scheduled = pcall(ExecuteInGameThreadWithDelay, action_handle, delay, wrapped)
      if scheduled then
        return true
      end
    end
  end

  state.delayed_callbacks[key] = nil
  return false
end

function BMF_start_async_loop(prefix, interval_ms, callback, default_enabled)
  if type(callback) ~= "function" or type(LoopAsync) ~= "function" then
    return false
  end
  local explicit_loop_async = BMF_env_string("BMF_ALLOW_LOOPASYNC")
  local allow_loop_async = default_enabled == true
  if explicit_loop_async ~= "" then
    allow_loop_async = BMF_env_bool("BMF_ALLOW_LOOPASYNC", false)
  end
  if not allow_loop_async then
    return false
  end

  local key = "loop:" .. tostring(prefix or "worker")
  local interval = tonumber(interval_ms) or 250
  local wrapped
  wrapped = function()
    local ok, should_stop_or_error = pcall(callback)
    if not ok then
      log("error", tostring(prefix or "worker") .. " loop failed: " .. tostring(should_stop_or_error))
      return true
    end
    if should_stop_or_error == true then
      return true
    end
    return false
  end

  state.delayed_callbacks[key] = wrapped
  local scheduled = pcall(LoopAsync, interval, wrapped)
  if scheduled then
    return true
  end

  state.delayed_callbacks[key] = nil
  return false
end

function BMF_start_game_thread_loop(prefix, interval_ms, callback)
  if type(callback) ~= "function" then
    return false
  end
  if not BMF_env_bool("BMF_ALLOW_GAME_THREAD_LOOP", false) then
    return false
  end

  local key = "game_loop:" .. tostring(prefix or "worker")
  local interval = tonumber(interval_ms) or 250
  local wrapped
  wrapped = function()
    local ok, should_stop_or_error = pcall(callback)
    if not ok then
      log("error", tostring(prefix or "worker") .. " game-thread loop failed: " .. tostring(should_stop_or_error))
      return true
    end
    if should_stop_or_error == true then
      return true
    end
    return false
  end

  state.delayed_callbacks[key] = wrapped
  if type(LoopInGameThreadWithDelay) == "function" then
    local scheduled = pcall(LoopInGameThreadWithDelay, interval, wrapped)
    if scheduled then
      return true
    end
  end

  if type(LoopInGameThreadAfterFrames) == "function" then
    local frames = math.max(1, math.floor((interval / 16) + 0.5))
    local scheduled = pcall(LoopInGameThreadAfterFrames, frames, wrapped)
    if scheduled then
      return true
    end
  end

  state.delayed_callbacks[key] = nil
  return false
end

local BMF = {
  version = VERSION,
  started_at = state.started_at,
}

BMF.result = result
BMF.log = function(a, b, c)
  local level, message, data = normalize_log_args("info", a, b, c)
  log(level, message, data)
end
BMF.logInfo = function(message, data)
  log("info", message, data)
end
BMF.logWarn = function(message, data)
  log("warn", message, data)
end
BMF.logError = function(message, data)
  log("error", message, data)
end

BMF.logging = {
  eventLogPath = EVENT_LOG_PATH,
  auditLogPath = AUDIT_LOG_PATH,
  frameworkLogPath = LOG_PATH,
  pluginLogDir = PLUGIN_LOG_DIR,
}

API_REGISTRY = {
  { name = "BMF.version", namespace = "framework", kind = "string", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Current BMF package/runtime version." },
  { name = "BMF.health", namespace = "framework", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Runtime health and loaded-plugin counts." },
  { name = "BMF.result", namespace = "framework", kind = "function", stability = "stable", risk = "low", validation = "L0 Static", requiresPlayer = false, capability = "", summary = "Structured result constructor." },
  { name = "BMF.compatibility.check", namespace = "compatibility", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Report target Brickadia build and UE4SS helper availability." },
  { name = "BMF.compatibility.helpers", namespace = "compatibility", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "List required and optional UE4SS/BMF runtime helper groups." },
  { name = "BMF.log", namespace = "logging", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Framework/plugin text logging." },
  { name = "BMF.logging", namespace = "logging", kind = "table", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Runtime log paths." },
  { name = "BMF.audit.record", namespace = "audit", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Write structured audit records." },
  { name = "BMF.audit.recent", namespace = "audit", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Read recent in-memory audit records." },
  { name = "BMF.rateLimits.check", namespace = "rateLimits", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "", summary = "Check framework or plugin action limits." },
  { name = "BMF.rateLimits.recent", namespace = "rateLimits", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "", summary = "Inspect active rate-limit buckets." },
  { name = "BMF.events.on", namespace = "events", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Register framework event handler." },
  { name = "BMF.events.off", namespace = "events", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Remove framework event handler." },
  { name = "BMF.events.emit", namespace = "events", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Emit framework event." },
  { name = "BMF.events.listenerCount", namespace = "events", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Count event listeners." },
  { name = "BMF.timers.after", namespace = "timers", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "One-shot timer helper." },
  { name = "BMF.timers.every", namespace = "timers", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Recurring timer helper." },
  { name = "BMF.timers.cancel", namespace = "timers", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Cancel a timer." },
  { name = "BMF.commands.register", namespace = "commands", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "plugins.lifecycle", summary = "Register BMF console command." },
  { name = "BMF.commands.dispatch", namespace = "commands", kind = "function", stability = "restricted", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Dispatch registered BMF command." },
  { name = "BMF.commands.dispatchWithAccess", namespace = "commands", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless + L5 Negative; L3 Live Player for authenticated player command routing", requiresPlayer = false, capability = "", summary = "Opt-in command dispatch wrapper gated by BMF.permissions.evaluateCommandAccess." },
  { name = "BMF.plugins.list", namespace = "plugins", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "List loaded plugins and metadata." },
  { name = "BMF.plugins.watchdog", namespace = "plugins", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "", summary = "Inspect plugin error and isolation state." },
  { name = "BMF.plugins.hasCapability", namespace = "plugins", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "", summary = "Check declared plugin capability." },
  { name = "BMF.loadPlugins", namespace = "plugins", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Load plugins from disk and dispatch server-ready hooks." },
  { name = "BMF.unloadPlugins", namespace = "plugins", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Unload all loaded plugins and remove plugin-owned commands/events." },
  { name = "BMF.sandbox.policy", namespace = "sandbox", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "", summary = "Inspect plugin unsafe-global policy." },
  { name = "BMF.sandbox.denials", namespace = "sandbox", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "", summary = "Inspect plugin unsafe-global denial records." },
  { name = "BMF.storage.readText", namespace = "storage", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "plugins.storage", summary = "Read plugin-scoped text file." },
  { name = "BMF.storage.writeText", namespace = "storage", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "plugins.storage", summary = "Write plugin-scoped text file." },
  { name = "BMF.storage.readJson", namespace = "storage", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "plugins.storage", summary = "Read and decode plugin-scoped JSON data file." },
  { name = "BMF.storage.writeJson", namespace = "storage", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "plugins.storage", summary = "Encode and write plugin-scoped JSON data file." },
  { name = "BMF.storage.readConfig", namespace = "storage", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "plugins.storage", summary = "Read and decode plugin config.json." },
  { name = "BMF.storage.writeConfig", namespace = "storage", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "plugins.storage", summary = "Encode and write plugin config.json." },
  { name = "BMF.server.status", namespace = "server", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Structured BMF/server status with unknown live fields marked." },
  { name = "BMF.server.save", namespace = "server", kind = "function", stability = "experimental", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "server.save", summary = "Save current world through BMF.world.saveAs." },
  { name = "BMF.server.shutdown", namespace = "server", kind = "function", stability = "restricted", risk = "high", validation = "L2 Headless + L5 Negative safe-failure on CL13530", requiresPlayer = false, capability = "server.shutdown", summary = "Attempt a confirmed server exit command and report unsupported executors explicitly." },
  { name = "BMF.server.exec", namespace = "server", kind = "function", stability = "restricted", risk = "unsafe-native", validation = "L2 Headless + L5 Negative", requiresPlayer = false, capability = "server.exec", summary = "Raw console execution; prefer typed wrappers." },
  { name = "BMF.server.planSettingsPatch", namespace = "server", kind = "function", stability = "file-backed", risk = "medium", validation = "L0 Static", requiresPlayer = false, capability = "", summary = "Plan copied GameUserSettings.ini changes." },
  { name = "BMF.chat.broadcast", namespace = "chat", kind = "function", stability = "experimental", risk = "medium", validation = "L3 Live Player UI confirmed", requiresPlayer = false, capability = "chat.broadcast", summary = "Broadcasts by fanning out ClientPushChatMessage once per live player controller." },
  { name = "BMF.chat.whisper", namespace = "chat", kind = "function", stability = "experimental", risk = "live-player", validation = "L3 Live Player UI confirmed with one local player; two-player targeting pending", requiresPlayer = true, capability = "chat.whisper", summary = "Sends ClientPushChatMessage to one matched live player controller." },
  { name = "BMF.chat.statusMessage", namespace = "chat", kind = "function", stability = "scaffold", risk = "live-player", validation = "L2 Headless + L0 Fixture; L3 Live Player for delivery", requiresPlayer = true, capability = "chat.statusMessage", summary = "Private status-message scaffold; visible delivery unproven." },
  { name = "BMF.players.sync", namespace = "players", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; optional adapter cache path", requiresPlayer = false, capability = "", summary = "Sync optional external player identity records into the BMF cache." },
  { name = "BMF.players.list", namespace = "players", kind = "function", stability = "experimental", risk = "low", validation = "L2 Headless empty adapter; L3 Live Player for native Brickadia log identity", requiresPlayer = false, capability = "", summary = "List safe player identity records and live controller count." },
  { name = "BMF.players.normalize", namespace = "players", kind = "function", stability = "stable", risk = "low", validation = "L0 Fixture", requiresPlayer = false, capability = "", summary = "Normalize synthetic/player record shape." },
  { name = "BMF.players.find", namespace = "players", kind = "function", stability = "scaffold", risk = "live-player", validation = "L0 Fixture + L2 Headless negative; L3 Live Player for real records", requiresPlayer = true, capability = "", summary = "Fixture-proven lookup plus empty live adapter safety." },
  { name = "BMF.players.resolve", namespace = "players", kind = "function", stability = "scaffold", risk = "live-player", validation = "L0 Fixture + L2 Headless negative; L3 Live Player for real records", requiresPlayer = true, capability = "", summary = "Resolve direct or current-list player query." },
  { name = "BMF.players.getName", namespace = "players", kind = "function", stability = "scaffold", risk = "live-player", validation = "L0 Fixture + L2 Headless negative; L3 Live Player for real records", requiresPlayer = true, capability = "", summary = "Return normalized identity fields." },
  { name = "BMF.players.summary", namespace = "players", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for whispered delivery", requiresPlayer = false, capability = "", summary = "Resolve one player and include known-player/live-controller counts." },
  { name = "BMF.players.positions", namespace = "players", kind = "function", stability = "experimental", risk = "live-player", validation = "L0 Static + L3 Live Player", requiresPlayer = true, capability = "", summary = "Read live player pawn positions from safe PlayerState/Controller references." },
  { name = "BMF.players.whisperSummary", namespace = "players", kind = "function", stability = "experimental", risk = "live-player", validation = "L0 Static + L3 Live Player for visible delivery", requiresPlayer = true, capability = "chat.whisper", summary = "Whisper a cached identity summary back to the selected player." },
  { name = "BMF.permissions.describeRole", namespace = "permissions", kind = "function", stability = "stable", risk = "low", validation = "L0 Fixture + L2 Headless", requiresPlayer = false, capability = "", summary = "Normalize a RoleSetup2-style role permission map." },
  { name = "BMF.permissions.evaluateNoSpawnItemApplicator", namespace = "permissions", kind = "function", stability = "stable", risk = "medium", validation = "L0 Fixture + L2 Headless; L3 Live Player + L5 Negative for runtime exploit denial", requiresPlayer = false, capability = "", summary = "Evaluate the default-role policy that keeps applicator access but forbids spawn items." },
  { name = "BMF.permissions.evaluateApplicatorComponentAccess", namespace = "permissions", kind = "function", stability = "stable", risk = "low", validation = "L2 Headless + L5 Negative; L3 Live Player when wired into a live applicator hook", requiresPlayer = false, capability = "", summary = "Evaluate global allow/deny policy for an applicator component name." },
  { name = "BMF.permissions.evaluateInteractConsolePrefixAccess", namespace = "permissions", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless + L5 Negative; L3 Live Player + native ServerModifyComponent hook for save-time Interactable prefix blocking", requiresPlayer = false, capability = "", summary = "Evaluate Interactable Print-to-Console prefix policy with Owner/Admin bypass and a whitelist for everyone else." },
  { name = "BMF.permissions.evaluateBrickAssetAccess", namespace = "permissions", kind = "function", stability = "stable", risk = "low", validation = "L0 Archive Fixture + L2 Headless; L3 Live Player when wired into a live placement hook", requiresPlayer = false, capability = "", summary = "Evaluate role-aware allow/deny policy for Brickadia brick asset names such as B_Joint_Wheel_Micro." },
  { name = "BMF.permissions.enforceNoSpawnItemApplicator", namespace = "permissions", kind = "function", stability = "file-backed", risk = "high", validation = "L2 Headless copied RoleSetup2 patching; L3 Live Player + L5 Negative for live tool denial", requiresPlayer = false, capability = "", summary = "Patch RoleSetup2 so applicator access stays allowed while SpawnItems is denied by default and named roles cannot override it." },
  { name = "BMF.tools.onApplicatorComponentApply", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "L2 Headless registration shape; L3 Live Player + L5 Negative for denied component mutation", requiresPlayer = true, capability = "tools.applicator", summary = "Register a Lua handler for live applicator ServerAddComponent attempts." },
  { name = "BMF.tools.applicator.status", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "L2 Headless command; L3 Live Player for native hook evidence", requiresPlayer = false, capability = "", summary = "Inspect the live applicator hook, handlers, recent events, and denied component cache." },
  { name = "BMF.tools.applicator.nativeTargets", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "L3 Live Server pre-injection target discovery", requiresPlayer = false, capability = "", summary = "Resolve native addresses used by the ServerAddComponent function-slot blocker." },
  { name = "BMF.tools.applicator.scanObjects", namespace = "tools", kind = "function", stability = "experimental", risk = "low", validation = "L3 Live Server read-only reflection scan", requiresPlayer = false, capability = "", summary = "Scan live UE objects for applicator/component function discovery." },
  { name = "BMF.tools.applicator.refreshComponentCache", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "L2 Headless safe failure; L3 Live Player for reflected component type addresses", requiresPlayer = false, capability = "", summary = "Resolve denied Brickadia component type objects such as ItemSpawn for live applicator enforcement." },
  { name = "BMF.tools.uobject.describe", namespace = "tools", kind = "function", stability = "diagnostic", risk = "low", validation = "L3 Live Server address-only native diagnostic", requiresPlayer = false, capability = "", summary = "Describe one explicit live UObject pointer without global scans; used to decode native trace context pointers." },
  { name = "BMF.bricks.inspectRuntimeState", namespace = "bricks", kind = "function", stability = "diagnostic", risk = "medium", validation = "L3 Live Server explicit brick id inspect", requiresPlayer = false, capability = "", summary = "Inspect one explicit runtime brick id for visible/collision state without scanning live UObjects." },
  { name = "BMF.bricks.setRuntimeState", namespace = "bricks", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "Env-gated L3 Live Server canary only", requiresPlayer = false, capability = "bricks.runtimeState", summary = "Set one explicit runtime brick id visibility and/or collision state through BMFSocket." },
  { name = "BMF.bricks.runtimeStateStatus", namespace = "bricks", kind = "function", stability = "diagnostic", risk = "low", validation = "L2 Headless safe failure; L3 Live Server result inspection", requiresPlayer = false, capability = "", summary = "Inspect the last queued runtime brick state operation result." },
  { name = "BMF.tools.treeCutTrace.enable", namespace = "tools", kind = "function", stability = "diagnostic", risk = "unsafe-native", validation = "L3 Live Player handaxe/tree trace", requiresPlayer = true, capability = "", summary = "Temporarily register bounded native hooks that summarize handaxe/tree-cut evidence." },
  { name = "BMF.tools.treeCutTrace.disable", namespace = "tools", kind = "function", stability = "diagnostic", risk = "unsafe-native", validation = "L3 Live Server cleanup", requiresPlayer = false, capability = "", summary = "Unregister active tree-cut trace hooks." },
  { name = "BMF.tools.treeCutTrace.status", namespace = "tools", kind = "function", stability = "diagnostic", risk = "low", validation = "L2 Headless command; L3 Live Player for event counts", requiresPlayer = false, capability = "", summary = "Inspect tree-cut trace hook state and counters." },
  { name = "BMF.tools.treeCutTrace.recent", namespace = "tools", kind = "function", stability = "diagnostic", risk = "low", validation = "L3 Live Player trace review", requiresPlayer = false, capability = "", summary = "List recent tree-cut trace records." },
  { name = "BMF.tools.treeCutTrace.clear", namespace = "tools", kind = "function", stability = "diagnostic", risk = "low", validation = "L2 Headless reset", requiresPlayer = false, capability = "", summary = "Clear tree-cut trace counters and recent events." },
  { name = "BMF.tools.treeCutNative.start", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "L3 Live Player handaxe/tree hit event", requiresPlayer = true, capability = "", summary = "Install and enable the native melee-hit queue used for CityRPG tree-cut events." },
  { name = "BMF.tools.treeCutNative.stop", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "L3 Live Server cleanup", requiresPlayer = false, capability = "", summary = "Disable native tree-cut event capture without unloading the native detour." },
  { name = "BMF.tools.treeCutNative.status", namespace = "tools", kind = "function", stability = "experimental", risk = "low", validation = "L2 Headless safe failure; L3 Live Player event counts", requiresPlayer = false, capability = "", summary = "Inspect native tree-cut hook install state, counters, and queue depth." },
  { name = "BMF.tools.treeCutNative.resolveHandaxe", namespace = "tools", kind = "function", stability = "experimental", risk = "medium", validation = "L3 Live Server game-thread asset resolve", requiresPlayer = false, capability = "", summary = "Load and resolve the handaxe generated class for strict native tree-cut item checks." },
  { name = "BMF.tools.treeCutNative.refreshTargets", namespace = "tools", kind = "function", stability = "diagnostic", risk = "unsafe-native", validation = "Disabled by default; manual native diagnostics only", requiresPlayer = false, capability = "", summary = "Opt-in unsafe native tree actor cache refresh for diagnostics; CityRPG should prefer bounded runtime anchors." },
  { name = "BMF.tools.treeCutNative.findTag", namespace = "tools", kind = "function", stability = "diagnostic", risk = "unsafe-native", validation = "L3 Live Server bounded exact ConsoleTag lookup", requiresPlayer = false, capability = "", summary = "Find live UObject candidates that directly carry a specific treeid ConsoleTag for physical-state research." },
  { name = "BMF.tools.treeCutNative.inspectPhysical", namespace = "tools", kind = "function", stability = "experimental", risk = "medium", validation = "Delegates to BMF.bricks.inspectRuntimeState", requiresPlayer = false, capability = "", summary = "Compatibility wrapper for explicit runtime brick visible/collision inspection." },
  { name = "BMF.tools.treeCutNative.setPhysical", namespace = "tools", kind = "function", stability = "experimental", risk = "unsafe-native", validation = "Delegates to BMF.bricks.setRuntimeState", requiresPlayer = false, capability = "", summary = "Compatibility wrapper for tagged-tree runtime brick visible/collision mutation." },
  { name = "BMF.tools.treeCutNative.drain", namespace = "tools", kind = "function", stability = "experimental", risk = "medium", validation = "L3 Live Player socket relay", requiresPlayer = false, capability = "", summary = "Drain queued native tree-cut hit events and emit them into the BMF event bus." },
  { name = "BMF.tools.treeCutProbe.start", namespace = "tools", kind = "function", stability = "diagnostic", risk = "unsafe-native", validation = "L3 Live Player handaxe/tree function attribution", requiresPlayer = true, capability = "", summary = "Install and enable bounded native counters for likely Brickadia melee/tree-hit UFunctions." },
  { name = "BMF.tools.treeCutProbe.stop", namespace = "tools", kind = "function", stability = "diagnostic", risk = "low", validation = "L3 Live Server cleanup", requiresPlayer = false, capability = "", summary = "Disable tree-cut probe counting without unloading the native detours." },
  { name = "BMF.tools.treeCutProbe.status", namespace = "tools", kind = "function", stability = "diagnostic", risk = "low", validation = "L3 Live Player handaxe/tree function attribution", requiresPlayer = false, capability = "", summary = "Inspect native tree-cut probe candidate install state and hit counters." },
  { name = "BMF.interact.handleConsoleMessage", namespace = "interact", kind = "function", stability = "experimental", risk = "medium", validation = "L2 Headless command; L3 Live Player through Omegga interact forwarder", requiresPlayer = false, capability = "", summary = "Forward an Interactable Print-to-Console message into BMF's interactConsole event." },
  { name = "BMF.permissions.describeRoleAssignments", namespace = "permissions", kind = "function", stability = "stable", risk = "low", validation = "L0 Fixture + L2 Headless", requiresPlayer = false, capability = "", summary = "Normalize RoleAssignments.json-style player role records." },
  { name = "BMF.permissions.loadRoleAssignments", namespace = "permissions", kind = "function", stability = "file-backed", risk = "low", validation = "L2 Headless + L3 Live Player policy lookup", requiresPlayer = false, capability = "", summary = "Read and normalize the configured Brickadia RoleAssignments.json file." },
  { name = "BMF.permissions.getPlayerRoles", namespace = "permissions", kind = "function", stability = "stable", risk = "low", validation = "L0 Fixture + L2 Headless", requiresPlayer = false, capability = "", summary = "Read assigned role names for a player UUID from RoleAssignments-style data." },
  { name = "BMF.permissions.playerHasRole", namespace = "permissions", kind = "function", stability = "stable", risk = "low", validation = "L0 Fixture + L2 Headless", requiresPlayer = false, capability = "", summary = "Case-insensitive role membership check over RoleAssignments-style data." },
  { name = "BMF.permissions.evaluateCommandAccess", namespace = "permissions", kind = "function", stability = "stable", risk = "medium", validation = "L2 Headless + L5 Negative; L3 Live Player for authenticated player command routing", requiresPlayer = false, capability = "", summary = "Evaluate role-based command access from file-shaped assignments or actor roles." },
  { name = "BMF.permissions.planRolePatch", namespace = "permissions", kind = "function", stability = "file-backed", risk = "medium", validation = "L2 Headless copied file patching", requiresPlayer = false, capability = "", summary = "Plan role permission changes without live mutation." },
  { name = "BMF.permissions.planPlayerRoleAssignment", namespace = "permissions", kind = "function", stability = "file-backed", risk = "medium", validation = "L2 Headless copied file patching", requiresPlayer = false, capability = "", summary = "Plan player role assignment file changes." },
  { name = "BMF.minigames.list", namespace = "minigames", kind = "function", stability = "experimental", risk = "medium", validation = "L2 Headless fail-closed; unsafe opt-in required for Brickadia console execution", requiresPlayer = false, capability = "", summary = "Server.Minigames.List wrapper disabled by default due Brickadia crash risk." },
  { name = "BMF.minigames.loadPreset", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless command transport + L5 Negative argument validation; L3 Live Player for effects", requiresPlayer = false, capability = "", summary = "Minigame preset load command wrapper." },
  { name = "BMF.minigames.savePreset", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless command transport + L5 Negative argument validation; L3 Live Player for effects", requiresPlayer = false, capability = "", summary = "Minigame preset save command wrapper." },
  { name = "BMF.minigames.reset", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless command transport + L5 Negative argument validation; L3 Live Player for effects", requiresPlayer = false, capability = "", summary = "Minigame reset command wrapper." },
  { name = "BMF.minigames.nextRound", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless command transport + L5 Negative argument validation; L3 Live Player for effects", requiresPlayer = false, capability = "", summary = "Minigame next-round command wrapper." },
  { name = "BMF.minigames.delete", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless command transport + L5 Negative argument validation; L3 Live Player for effects", requiresPlayer = false, capability = "", summary = "Minigame delete command wrapper." },
  { name = "BMF.minigames.emitEvent", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless event-log; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Emit a namespaced minigame event for external relays such as CityRPG." },
  { name = "BMF.minigames.on", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless event canary; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Subscribe to normalized BMF minigame events using canonical names or aliases." },
  { name = "BMF.minigames.off", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless event canary", requiresPlayer = false, capability = "", summary = "Unsubscribe a BMF minigame event handler by id." },
  { name = "BMF.minigames.listenerCount", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless event canary", requiresPlayer = false, capability = "", summary = "Count handlers for a normalized BMF minigame event." },
  { name = "BMF.minigames.eventStatus", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Inspect BMF minigame event counters and recent event metadata." },
  { name = "BMF.minigames.syntheticFlow", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless synthetic-flow", requiresPlayer = false, capability = "", summary = "Emit a self-contained minigame lifecycle canary and restore data by default." },
  { name = "BMF.minigames.define", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Upsert a BMF-owned desired minigame definition without mutating Brickadia." },
  { name = "BMF.minigames.definitions", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "List BMF-owned desired minigame definitions." },
  { name = "BMF.minigames.definition", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Find one BMF-owned desired minigame definition." },
  { name = "BMF.minigames.deleteDefinition", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Delete one BMF-owned desired minigame definition with confirmation." },
  { name = "BMF.minigames.definitionStatus", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Inspect BMF-owned minigame definition registry counts and persistence path." },
  { name = "BMF.minigames.reconcileDefinitions", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Compare BMF-owned desired minigame definitions with observed BMF minigame data." },
  { name = "BMF.minigames.applySnapshot", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless", requiresPlayer = false, capability = "", summary = "Apply a BMF-owned observed minigame data snapshot without emitting an event." },
  { name = "BMF.minigames.data", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Read BMF-owned minigame data learned from observed gameplay events and snapshots." },
  { name = "BMF.minigames.dataStatus", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Inspect compact counts for the BMF-owned minigame data snapshot." },
  { name = "BMF.minigames.dataList", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "List BMF-owned event-fed minigames without unsafe Brickadia console calls." },
  { name = "BMF.minigames.get", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Find one event-fed minigame and return members, teams, rounds, and leaderboard context." },
  { name = "BMF.minigames.getPlayer", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Find one event-fed minigame player and return membership, team, and leaderboard context." },
  { name = "BMF.minigames.players", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "List known event-fed minigame players, optionally filtered by minigame." },
  { name = "BMF.minigames.teams", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "List known event-fed minigame teams, optionally filtered by minigame." },
  { name = "BMF.minigames.leaderboard", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "List event-fed leaderboard rows with minigame and player filters." },
  { name = "BMF.minigames.membership", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Resolve one player's current event-fed minigame membership." },
  { name = "BMF.minigames.playerState", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "Resolve whether one known player is currently in a minigame without confusing historical leaderboard context for membership." },
  { name = "BMF.minigames.recentEvents", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L0 Static + L2 Headless; L3 Live Player for gameplay producers", requiresPlayer = false, capability = "", summary = "List recent accepted minigame events with optional event/minigame/player filters." },
  { name = "BMF.minigames.clearData", namespace = "minigames", kind = "function", stability = "experimental", risk = "low", validation = "L2 Headless validation reset only", requiresPlayer = false, capability = "", summary = "Explicitly clear BMF-owned minigame cache data for validation and troubleshooting." },
  { name = "BMF.minigames.livePlayerSnapshot", namespace = "minigames", kind = "function", stability = "experimental", risk = "medium", validation = "L3 Live Server read-only PlayerArray diagnostics", requiresPlayer = false, capability = "ue4ss-player-state-read", summary = "Read live PlayerState team/minigame candidate fields without console GetAll." },
  { name = "BMF.minigames.assignTeam", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L3 Live Server CallFunctionByNameWithArguments; native ProcessEvent fallback", requiresPlayer = true, capability = "ue4ss-minigame-team-native", summary = "Assign a live player to a minigame team through the native minigame team API." },
  { name = "BMF.minigames.objectSnapshot", namespace = "minigames", kind = "function", stability = "experimental", risk = "high", validation = "L3 Live Server fail-closed; unsafe opt-in required due UE4SS crash risk", requiresPlayer = false, capability = "ue4ss-object-read", summary = "BP_Ruleset_C and BP_Team_C object snapshot disabled by default due dedicated-server crash risk." },
  { name = "BMF.world.loadAdditive", namespace = "world", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless; L3 Live Player for visual behavior", requiresPlayer = false, capability = "world.loadAdditive", summary = "Load staged world additively through proven console path." },
  { name = "BMF.world.saveAs", namespace = "world", kind = "function", stability = "experimental", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "world.saveAs", summary = "Save current world for offline BRDB parsing." },
  { name = "BMF.prefabs.planLoadBrz", namespace = "prefabs", kind = "function", stability = "experimental", risk = "medium", validation = "L2 Headless after staging", requiresPlayer = false, capability = "", summary = "Plan staged BRZ-derived world load." },
  { name = "BMF.prefabs.loadBrdb", namespace = "prefabs", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless; L3 Live Player for visual behavior", requiresPlayer = false, capability = "prefabs.loadBrdb", summary = "Load staged BRDB world bundle." },
  { name = "BMF.prefabs.loadBrz", namespace = "prefabs", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless after staging; L3 Live Player for drivable behavior", requiresPlayer = false, capability = "prefabs.loadBrz", summary = "Load BRZ-derived staged world bundle; raw BRZ conversion stays outside Lua." },
  { name = "BMF.vehicles.planSpawnSet", namespace = "vehicles", kind = "function", stability = "experimental", risk = "medium", validation = "L2 Headless", requiresPlayer = false, capability = "", summary = "Plan staged vehicle-copy load set." },
  { name = "BMF.vehicles.spawnSet", namespace = "vehicles", kind = "function", stability = "experimental", risk = "high", validation = "L2 Headless; L3 Live Player for drivable behavior", requiresPlayer = false, capability = "vehicles.spawnSet", summary = "Load staged remapped vehicle copies and prove saved graph counts." },
}

local function normalize_api_filter_value(value)
  local text = trim_string(value or "")
  if text == "" then
    return ""
  end
  return text:lower()
end

local function api_filter_bool(value)
  if type(value) == "boolean" then
    return value
  end
  local text = normalize_api_filter_value(value)
  if text == "true" or text == "1" or text == "yes" then
    return true
  end
  if text == "false" or text == "0" or text == "no" then
    return false
  end
  return nil
end

local function api_item_matches(item, filters)
  if type(filters) ~= "table" then
    return true
  end
  local name = normalize_api_filter_value(filters.name or filters.api)
  if name ~= "" and normalize_api_filter_value(item.name) ~= name then
    return false
  end
  local namespace = normalize_api_filter_value(filters.namespace or filters.ns)
  if namespace ~= "" and normalize_api_filter_value(item.namespace) ~= namespace then
    return false
  end
  local stability = normalize_api_filter_value(filters.stability or filters.status)
  if stability ~= "" and normalize_api_filter_value(item.stability) ~= stability then
    return false
  end
  local risk = normalize_api_filter_value(filters.risk)
  if risk ~= "" and normalize_api_filter_value(item.risk) ~= risk then
    return false
  end
  local capability = normalize_api_filter_value(filters.capability)
  if capability ~= "" and normalize_api_filter_value(item.capability) ~= capability then
    return false
  end
  local requires_player = api_filter_bool(filters.requiresPlayer or filters.requiresplayer or filters.player)
  if requires_player ~= nil and (item.requiresPlayer == true) ~= requires_player then
    return false
  end
  return true
end

local function api_registry_summary(items)
  local summary = {
    total = #items,
    stability = {},
    risk = {},
    requiresPlayer = 0,
  }
  for _, item in ipairs(items) do
    local stability = tostring(item.stability or "unknown")
    local risk = tostring(item.risk or "unknown")
    summary.stability[stability] = (summary.stability[stability] or 0) + 1
    summary.risk[risk] = (summary.risk[risk] or 0) + 1
    if item.requiresPlayer == true then
      summary.requiresPlayer = summary.requiresPlayer + 1
    end
  end
  return summary
end

BMF.apis = {}
BMF.apis.list = function(filters)
  local items = {}
  for _, item in ipairs(API_REGISTRY) do
    if api_item_matches(item, filters) then
      items[#items + 1] = copy_table(item)
    end
  end
  return result(true, "OK", "API labels listed", {
    apis = items,
    count = #items,
    summary = api_registry_summary(items),
  })
end
BMF.apis.get = function(name)
  local requested = normalize_api_filter_value(name)
  if requested == "" then
    return result(false, "INVALID_API_NAME", "API name is required")
  end
  for _, item in ipairs(API_REGISTRY) do
    if normalize_api_filter_value(item.name) == requested then
      return result(true, "OK", "API label found", { api = copy_table(item) })
    end
  end
  return result(false, "API_NOT_FOUND", "API label was not found", { name = tostring(name or "") })
end
BMF.apis.summary = function()
  return result(true, "OK", "API label summary collected", api_registry_summary(API_REGISTRY))
end

BMF.compatibility = {}
BMF.compatibility.check = function()
  local data = compatibility_snapshot()
  return result(
    data.ok,
    data.ok and "OK" or "RUNTIME_HELPERS_MISSING",
    data.ok and "Compatibility diagnostics passed" or "Required runtime helpers are missing",
    data
  )
end
BMF.compatibility.helpers = function()
  local data = compatibility_snapshot()
  return result(data.ok, data.ok and "OK" or "RUNTIME_HELPERS_MISSING", "Runtime helper diagnostics collected", {
    helperGroups = data.ue4ss.helperGroups,
    requiredGroupCount = data.ue4ss.requiredGroupCount,
    requiredGroupsAvailable = data.ue4ss.requiredGroupsAvailable,
    missingRequiredGroups = data.ue4ss.missingRequiredGroups,
  })
end

BMF.sandbox = {}
BMF.sandbox.policy = function()
  return result(true, "OK", "Plugin sandbox policy collected", {
    allowPluginUnsafeGlobals = state.config.allowPluginUnsafeGlobals == true,
    requiredCapability = "unsafe.globals",
    blockedGlobals = unsafe_plugin_global_names(),
    deniedLookups = plugin_unsafe_global_denial_count(),
  })
end
BMF.sandbox.denials = function()
  local items = {}
  for _, item in pairs(state.plugin_unsafe_global_denials) do
    items[#items + 1] = copy_table(item)
  end
  table.sort(items, function(a, b)
    local left = tostring(a.plugin or "") .. tostring(a.global or "")
    local right = tostring(b.plugin or "") .. tostring(b.global or "")
    return left < right
  end)
  return result(true, "OK", "Plugin unsafe-global denials listed", {
    denials = items,
    count = #items,
  })
end

BMF.audit = {
  path = AUDIT_LOG_PATH,
}
BMF.audit.record = function(action, data)
  return audit_record(action, data, { source = "framework" })
end
BMF.audit.recent = function(limit)
  local count = tonumber(limit) or 20
  if count < 1 then
    count = 1
  end
  if count > 100 then
    count = 100
  end

  local records = {}
  local first = #state.audit_records - count + 1
  if first < 1 then
    first = 1
  end
  for index = first, #state.audit_records do
    records[#records + 1] = copy_table(state.audit_records[index])
  end
  return result(true, "OK", "Audit records listed", {
    path = AUDIT_LOG_PATH,
    records = records,
    count = #records,
  })
end

local RATE_LIMIT_POLICIES = {
  ["server.exec"] = { limit = 3, windowSeconds = 10 },
  ["server.save"] = { limit = 3, windowSeconds = 30 },
  ["server.shutdown"] = { limit = 1, windowSeconds = 60 },
  ["world.loadAdditive"] = { limit = 30, windowSeconds = 30 },
  ["world.saveAs"] = { limit = 10, windowSeconds = 30 },
  ["chat.broadcast"] = { limit = 10, windowSeconds = 10 },
  ["chat.whisper"] = { limit = 20, windowSeconds = 10 },
  ["chat.statusMessage"] = { limit = 20, windowSeconds = 10 },
}

local rate_limit_context_stack = {}

local function current_rate_limit_context()
  local context = rate_limit_context_stack[#rate_limit_context_stack]
  if type(context) == "table" then
    return context
  end
  return {
    source = "framework",
    subject = "framework",
  }
end

local function with_rate_limit_context(context, callback)
  rate_limit_context_stack[#rate_limit_context_stack + 1] = context or {}
  local ok, value = pcall(callback)
  rate_limit_context_stack[#rate_limit_context_stack] = nil
  if not ok then
    error(value, 0)
  end
  return value
end

local function normalize_rate_limit_policy(action, options)
  local policy = RATE_LIMIT_POLICIES[action] or { limit = 60, windowSeconds = 60 }
  if type(options) == "table" then
    policy = {
      limit = options.limit or options.max or policy.limit,
      windowSeconds = options.windowSeconds or policy.windowSeconds,
    }
    if options.windowMs ~= nil then
      policy.windowSeconds = math.ceil((tonumber(options.windowMs) or 0) / 1000)
    end
  else
    policy = {
      limit = policy.limit,
      windowSeconds = policy.windowSeconds,
    }
  end

  policy.limit = tonumber(policy.limit) or 1
  policy.windowSeconds = tonumber(policy.windowSeconds) or 60
  if policy.limit < 1 then
    policy.limit = 1
  end
  if policy.windowSeconds < 1 then
    policy.windowSeconds = 1
  end
  return policy
end

local function rate_limit_check(action, options, context)
  local name = trim_string(action)
  if name == "" then
    return result(false, "INVALID_RATE_LIMIT", "rate limit action is required")
  end

  local policy = normalize_rate_limit_policy(name, options)
  local now = os.time()
  local active_context = context or current_rate_limit_context()
  local subject = tostring(active_context.subject or active_context.plugin or active_context.source or "framework")
  local key = subject .. "|" .. name
  local bucket = state.rate_limits[key]
  if type(bucket) ~= "table" or tonumber(bucket.resetAt or 0) <= now then
    bucket = {
      action = name,
      subject = subject,
      count = 0,
      resetAt = now + policy.windowSeconds,
    }
    state.rate_limits[key] = bucket
  end

  local remaining = policy.limit - bucket.count
  if remaining <= 0 then
    local retry_after = bucket.resetAt - now
    if retry_after < 0 then
      retry_after = 0
    end
    audit_record("rate_limit.denied", {
      action = name,
      subject = subject,
      limit = policy.limit,
      windowSeconds = policy.windowSeconds,
      retryAfterSeconds = retry_after,
    }, {
      source = tostring(active_context.source or "framework"),
      plugin = active_context.plugin,
      severity = "warn",
      ok = false,
      code = "RATE_LIMITED",
    })
    return result(false, "RATE_LIMITED", "Rate limit exceeded for " .. name, {
      action = name,
      subject = subject,
      limit = policy.limit,
      remaining = 0,
      resetAt = bucket.resetAt,
      retryAfterSeconds = retry_after,
    })
  end

  bucket.count = bucket.count + 1
  return result(true, "OK", "Rate limit accepted", {
    action = name,
    subject = subject,
    limit = policy.limit,
    remaining = policy.limit - bucket.count,
    resetAt = bucket.resetAt,
  })
end

BMF.rateLimits = {}
BMF.rateLimits.check = function(action, options)
  return rate_limit_check(action, options)
end
BMF.rateLimits.recent = function()
  local buckets = {}
  local now = os.time()
  for key, bucket in pairs(state.rate_limits) do
    buckets[#buckets + 1] = {
      key = key,
      action = bucket.action,
      subject = bucket.subject,
      count = bucket.count,
      resetAt = bucket.resetAt,
      retryAfterSeconds = math.max(0, (bucket.resetAt or now) - now),
    }
  end
  table.sort(buckets, function(a, b)
    return tostring(a.key) < tostring(b.key)
  end)
  return result(true, "OK", "Rate limit buckets listed", { buckets = buckets })
end

BMF.events = {}

local function normalize_event_name(value)
  local name = trim_string(value)
  if name == "" then
    return nil, "event name is required"
  end
  if name:match("[%c]") or not name:match("^[A-Za-z0-9_.:%-]+$") then
    return nil, "event name must use simple tokens"
  end
  return name
end

local function register_event_handler(name, handler, owner)
  local event_name = normalize_event_name(name)
  if not event_name or type(handler) ~= "function" then
    return nil
  end
  local id = state.next_event_handler_id
  state.next_event_handler_id = state.next_event_handler_id + 1
  if type(state.event_handlers[event_name]) ~= "table" then
    state.event_handlers[event_name] = {}
  end
  state.event_handlers[event_name][id] = {
    handler = handler,
    owner = owner,
  }
  return id
end

BMF.events.on = function(name, handler)
  return register_event_handler(name, handler, nil)
end

BMF.events.off = function(id)
  for _, handlers in pairs(state.event_handlers) do
    if handlers[id] then
      handlers[id] = nil
      return true
    end
  end
  return false
end

BMF.events.emit = function(name, data)
  local event_name, event_error = normalize_event_name(name)
  if not event_name then
    return result(false, "INVALID_EVENT", event_error)
  end
  local event_started_clock = os.clock()
  local handlers = state.event_handlers[event_name] or {}
  local calls = {}
  for id, entry in pairs(handlers) do
    if type(entry) == "function" then
      calls[#calls + 1] = { id = id, handler = entry, owner = nil }
    elseif type(entry) == "table" and type(entry.handler) == "function" then
      calls[#calls + 1] = { id = id, handler = entry.handler, owner = entry.owner }
    end
  end
  table.sort(calls, function(a, b)
    return a.id < b.id
  end)

  local errors = {}
  for _, item in ipairs(calls) do
    local handler_started_clock = os.clock()
    local ok, err = pcall(item.handler, copy_table(data or {}), event_name)
    BMF_telemetry_record_event_handler(event_name, item.owner, BMF_telemetry_duration_ms(handler_started_clock), ok)
    if not ok then
      errors[#errors + 1] = {
        id = item.id,
        error = tostring(err),
      }
      log("error", "event handler failed event=" .. event_name .. " id=" .. tostring(item.id) .. ": " .. tostring(err))
    end
  end
  BMF_telemetry_record_event(event_name, #calls, #errors, BMF_telemetry_duration_ms(event_started_clock))

  write_log_event(os.date("!%Y-%m-%dT%H:%M:%SZ"), #errors == 0 and "info" or "error", "event emitted: " .. event_name, {
    source = "event",
    data = {
      event = event_name,
      payload = copy_table(data or {}),
      handlers = #calls,
      errors = copy_table(errors),
      ok = #errors == 0,
    },
  })

  return result(#errors == 0, #errors == 0 and "OK" or "EVENT_HANDLER_ERROR", "Event emitted", {
    event = event_name,
    handlers = #calls,
    errors = errors,
  })
end

BMF.events.listenerCount = function(name)
  local event_name = normalize_event_name(name)
  if not event_name then
    return 0
  end
  local count = 0
  for _ in pairs(state.event_handlers[event_name] or {}) do
    count = count + 1
  end
  return count
end

local function remove_event_handlers_for_owner(owner)
  if owner == nil then
    return 0
  end
  local removed = 0
  for _, handlers in pairs(state.event_handlers) do
    for id, entry in pairs(handlers) do
      if type(entry) == "table" and entry.owner == owner then
        handlers[id] = nil
        removed = removed + 1
      end
    end
  end
  return removed
end

local function plugin_watchdog_enabled()
  return state.config.pluginWatchdogEnabled ~= false
end

local function plugin_watchdog_max_errors()
  local value = tonumber(state.config.pluginWatchdogMaxErrors or 3) or 3
  if value < 1 then
    value = 1
  end
  return math.floor(value)
end

local function plugin_watchdog_state(name)
  local plugin_name = tostring(name or "")
  if plugin_name == "" then
    plugin_name = "unknown"
  end
  local item = state.plugin_watchdog[plugin_name]
  if type(item) ~= "table" then
    item = {
      name = plugin_name,
      errorCount = 0,
      isolated = false,
      isolatedAt = "",
      isolatedReason = "",
      lastError = nil,
    }
    state.plugin_watchdog[plugin_name] = item
  end
  return item
end

local function plugin_watchdog_isolated(name)
  local item = state.plugin_watchdog[tostring(name or "")]
  return type(item) == "table" and item.isolated == true
end

local function plugin_watchdog_note_error(name, hook, err)
  local item = plugin_watchdog_state(name)
  local hook_name = tostring(hook or "unknown")
  item.errorCount = (tonumber(item.errorCount) or 0) + 1
  item.lastError = {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    hook = hook_name,
    error = tostring(err),
  }

  local isolated_now = false
  if plugin_watchdog_enabled() and item.isolated ~= true and item.errorCount >= plugin_watchdog_max_errors() then
    item.isolated = true
    item.isolatedAt = item.lastError.at
    item.isolatedReason = "max-errors"
    isolated_now = true
    audit_record("plugin.isolated", {
      plugin = item.name,
      errorCount = item.errorCount,
      threshold = plugin_watchdog_max_errors(),
      hook = hook_name,
      error = tostring(err),
    }, {
      source = "plugin",
      plugin = item.name,
      severity = "error",
      ok = false,
      code = "PLUGIN_ISOLATED",
    })
    log(
      "error",
      "plugin " .. item.name .. " isolated by watchdog errors=" ..
        tostring(item.errorCount) .. " threshold=" .. tostring(plugin_watchdog_max_errors())
    )
  end

  return item, isolated_now
end

local function plugin_watchdog_snapshot(name)
  local item = plugin_watchdog_state(name)
  local last = item.lastError
  return {
    name = item.name,
    errorCount = tonumber(item.errorCount) or 0,
    isolated = item.isolated == true,
    isolatedAt = tostring(item.isolatedAt or ""),
    isolatedReason = tostring(item.isolatedReason or ""),
    lastError = type(last) == "table" and copy_table(last) or nil,
    threshold = plugin_watchdog_max_errors(),
    enabled = plugin_watchdog_enabled(),
  }
end

local function plugin_watchdog_list()
  local names = {}
  for name in pairs(state.plugins) do
    names[#names + 1] = name
  end
  for name in pairs(state.plugin_watchdog) do
    local seen = false
    for _, existing in ipairs(names) do
      if existing == name then
        seen = true
        break
      end
    end
    if not seen then
      names[#names + 1] = name
    end
  end
  table.sort(names)

  local items = {}
  for _, name in ipairs(names) do
    items[#items + 1] = plugin_watchdog_snapshot(name)
  end
  return items
end

local function record_plugin_error(name, hook, err, data, plugin)
  local plugin_name = tostring(name or "")
  local hook_name = tostring(hook or "unknown")
  local entry = {
    name = plugin_name,
    hook = hook_name,
    error = tostring(err),
  }
  if type(data) == "table" then
    entry.data = copy_table(data)
  end
  state.plugin_errors[#state.plugin_errors + 1] = entry
  log("error", "plugin " .. plugin_name .. " " .. hook_name .. " failed: " .. tostring(err))
  audit_record("plugin.error", {
    plugin = plugin_name,
    hook = hook_name,
    error = tostring(err),
    data = type(data) == "table" and data or {},
  }, {
    source = "plugin",
    plugin = plugin_name,
    severity = "error",
    ok = false,
    code = "PLUGIN_ERROR",
  })

  local target = plugin or state.plugins[plugin_name]
  if hook_name ~= "onError" and type(target) == "table" and type(target.onError) == "function" then
    local context = {
      plugin = plugin_name,
      hook = hook_name,
      error = tostring(err),
      data = type(data) == "table" and copy_table(data) or {},
    }
    local ok, on_error_err = pcall(target.onError, target.bmf_api or BMF, context)
    if not ok then
      local on_error_watchdog = plugin_watchdog_note_error(plugin_name, "onError", on_error_err)
      state.plugin_errors[#state.plugin_errors + 1] = {
        name = plugin_name,
        hook = "onError",
        error = tostring(on_error_err),
        watchdog = {
          errorCount = on_error_watchdog.errorCount,
          isolated = on_error_watchdog.isolated == true,
        },
      }
      log("error", "plugin " .. plugin_name .. " onError failed: " .. tostring(on_error_err))
    end
  end

  local watchdog = plugin_watchdog_note_error(plugin_name, hook_name, err)
  entry.watchdog = {
    errorCount = watchdog.errorCount,
    isolated = watchdog.isolated == true,
  }

  write_status()
  return entry
end

local function run_plugin_hook(name, plugin, hook, data)
  if type(plugin) ~= "table" or type(plugin[hook]) ~= "function" then
    return true, nil
  end
  if plugin_watchdog_isolated(name) then
    return false, "PLUGIN_ISOLATED"
  end
  local hook_started_clock = os.clock()
  local ok, err = pcall(plugin[hook], plugin.bmf_api or BMF, copy_table(data or {}))
  BMF_telemetry_record_plugin_hook(name, hook, BMF_telemetry_duration_ms(hook_started_clock), ok)
  if not ok then
    record_plugin_error(name, hook, err, data, plugin)
    return false, err
  end
  return true, nil
end

BMF.health = function()
  local compatibility = compatibility_snapshot()
  return result(true, "OK", "BMF runtime is loaded", {
    version = VERSION,
    target_build = TARGET_BRICKADIA_BUILD,
    compatibility_status = compatibility.status,
    build_detection = BUILD_DETECTION_MODE,
    plugins_loaded = plugin_count(),
    plugin_errors = #state.plugin_errors,
    plugin_watchdog_isolated = plugin_watchdog_isolated_count(),
    runtime_required_helper_groups = compatibility.ue4ss.requiredGroupCount,
    runtime_required_helper_groups_available = compatibility.ue4ss.requiredGroupsAvailable,
    runtime_missing_required_helper_groups = #(compatibility.ue4ss.missingRequiredGroups or {}),
    status_path = STATUS_PATH,
    telemetry_path = BMF_TELEMETRY_PATH,
    log_path = LOG_PATH,
    audit_path = AUDIT_LOG_PATH,
    audit_records = #state.audit_records,
  })
end

BMF.telemetry = function()
  BMF_telemetry_write(true)
  local telemetry = BMF_telemetry_snapshot()
  return result(true, "OK", "BMF telemetry collected", {
    telemetry_path = BMF_TELEMETRY_PATH,
    schema_version = telemetry.schema_version,
    commands_total = telemetry.commands.total,
    events_total = telemetry.events.total,
    plugin_hook_total = telemetry.plugins.hook_total,
    scheduler_callback_total = telemetry.scheduler.callback_total,
    telemetry = telemetry,
  })
end

BMF.server = {}
BMF.server.exec = function(command)
  local limited = rate_limit_check("server.exec")
  if not limited.ok then
    return limited
  end
  local response = exec_console(command)
  audit_record("server.exec", {
    command = tostring(command or ""),
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  return response
end

BMF.server.save = function(options)
  local limited = rate_limit_check("server.save")
  if not limited.ok then
    return limited
  end
  local save_name = nil
  local generated = false
  if type(options) == "table" then
    save_name = options.name or options.saveName or options.world or options.worldName
  elseif type(options) == "string" then
    save_name = options
  end
  if save_name == nil or tostring(save_name) == "" then
    save_name = "BMF_ServerSave_" .. os.date("!%Y%m%d%H%M%S")
    generated = true
  end

  local response = BMF.world.saveAs(save_name)
  response.data.api = "BMF.server.save"
  response.data.generatedName = generated
  response.data.saveName = response.data.world
  audit_record("server.save", {
    world = response.data.world,
    generatedName = generated,
    command = response.data.command,
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  return response
end

BMF.server.shutdown = function(options)
  local confirm = nil
  local reason = ""
  local delay_ms = 1000
  if type(options) == "table" then
    confirm = options.confirm or options.confirmation
    reason = trim_string(options.reason or "")
    delay_ms = tonumber(options.delayMs or options.delay_ms or options.delay) or delay_ms
  elseif type(options) == "string" then
    confirm = options
  end

  if tostring(confirm or "") ~= "BMF_SHUTDOWN" then
    return result(false, "CONFIRMATION_REQUIRED", "Server shutdown requires confirm=BMF_SHUTDOWN", {
      requiredConfirmation = "BMF_SHUTDOWN",
    })
  end

  local limited = rate_limit_check("server.shutdown")
  if not limited.ok then
    return limited
  end

  if delay_ms < 250 then
    delay_ms = 250
  end
  if delay_ms > 30000 then
    delay_ms = 30000
  end
  delay_ms = math.floor(delay_ms)

  local command = "exit"
  audit_record("server.shutdown", {
    command = command,
    reason = reason,
    delayMs = delay_ms,
  }, {
    source = "framework",
    severity = "warn",
    ok = true,
    code = "OK",
  })
  log("warn", "executing guarded server shutdown command=" .. command)
  local executed = exec_console_manager(command)
  audit_record("server.shutdown.executed", {
    command = command,
    executor = executed.data and executed.data.executor or "",
  }, {
    source = "framework",
    severity = executed.ok and "warn" or "error",
    ok = executed.ok,
    code = executed.code,
  })
  if not executed.ok then
    return result(false, "SHUTDOWN_UNAVAILABLE", "Console shutdown command is not available through the current executor", {
      command = command,
      reason = reason,
      delayMs = delay_ms,
      api = "BMF.server.shutdown",
      shutdownScheduled = false,
      executor = executed.data and executed.data.executor or "",
      executorCode = executed.code,
      executorMessage = executed.message,
    })
  end

  BMF.events.emit("shutdownRequested", {
    reason = reason,
    delayMs = delay_ms,
    command = command,
  })

  return result(true, "OK", "Server shutdown scheduled", {
    command = command,
    reason = reason,
    delayMs = delay_ms,
    api = "BMF.server.shutdown",
    shutdownScheduled = true,
  })
end

BMF.server.status = function()
  local names = command_names()
  local compatibility = compatibility_snapshot()
  local player_response = nil
  if BMF.players and type(BMF.players.list) == "function" then
    player_response = BMF.players.list()
  else
    player_response = result(false, "PLAYER_ADAPTER_UNAVAILABLE", "Player adapter is not initialized", { players = {} })
  end

  local players = {}
  if player_response.ok and player_response.data and type(player_response.data.players) == "table" then
    players = player_response.data.players
  end

  local uptime = os.time() - state.started_epoch
  if uptime < 0 then
    uptime = 0
  end

  local data = {
    version = VERSION,
    startedAt = state.started_at,
    uptimeSeconds = uptime,
    buildId = TARGET_BRICKADIA_BUILD,
    executable = TARGET_SERVER_EXECUTABLE,
    serverName = "",
    serverNameStatus = "unknown",
    description = "",
    descriptionStatus = "unknown",
    worldName = "",
    worldNameStatus = "unknown",
    brickCount = nil,
    brickCountStatus = "unknown",
    componentCount = nil,
    componentCountStatus = "unknown",
    playerCount = #players,
    playerAdapter = player_response.data and player_response.data.adapter or "headless-empty",
    bmfStatus = "running",
    paths = {
      status = STATUS_PATH,
      telemetry = BMF_TELEMETRY_PATH,
      log = LOG_PATH,
      events = EVENT_LOG_PATH,
      audit = AUDIT_LOG_PATH,
      pluginLogs = PLUGIN_LOG_DIR,
      commands = COMMAND_DIR,
    },
    runtime = {
      version = VERSION,
      startedAt = state.started_at,
      uptimeSeconds = uptime,
      pluginsLoaded = plugin_count(),
      pluginErrors = #state.plugin_errors,
      commandsRegistered = #names,
      timersActive = BMF.timers and BMF.timers.activeCount() or 0,
      serverReady = state.server_ready and true or false,
      pluginTickActive = state.plugin_tick_timer_id ~= nil,
      pluginTickCount = state.plugin_tick_count,
      pluginTickIntervalMs = state.plugin_tick_interval_ms,
      auditRecords = #state.audit_records,
      rateLimitBuckets = rate_limit_bucket_count(),
      pluginWatchdogIsolated = plugin_watchdog_isolated_count(),
      apiLabels = #API_REGISTRY,
      unsafeGlobalDenials = plugin_unsafe_global_denial_count(),
      compatibilityStatus = compatibility.status,
      targetBuild = compatibility.targetBuild,
      buildDetection = compatibility.buildDetection,
      requiredHelperGroups = compatibility.ue4ss.requiredGroupCount,
      requiredHelperGroupsAvailable = compatibility.ue4ss.requiredGroupsAvailable,
      missingRequiredHelperGroups = #(compatibility.ue4ss.missingRequiredGroups or {}),
    },
    players = {
      count = #players,
      adapter = player_response.data and player_response.data.adapter or "headless-empty",
      code = player_response.code,
      ok = player_response.ok,
    },
    plugins = {
      loaded = plugin_count(),
      errors = #state.plugin_errors,
      watchdog = {
        enabled = plugin_watchdog_enabled(),
        threshold = plugin_watchdog_max_errors(),
        isolated = plugin_watchdog_isolated_count(),
      },
    },
    commands = {
      registered = #names,
      names = names,
    },
    config = {
      allowPluginServerExec = state.config.allowPluginServerExec and true or false,
      allowPluginServerShutdown = state.config.allowPluginServerShutdown and true or false,
      jsonlLogs = state.config.jsonlLogs ~= false,
      pluginWatchdogEnabled = plugin_watchdog_enabled(),
      pluginWatchdogMaxErrors = plugin_watchdog_max_errors(),
      allowPluginUnsafeGlobals = state.config.allowPluginUnsafeGlobals == true,
    },
    server = {
      name = "",
      nameStatus = "unknown",
      description = "",
      descriptionStatus = "unknown",
      buildId = TARGET_BRICKADIA_BUILD,
      executable = TARGET_SERVER_EXECUTABLE,
    },
    world = {
      name = "",
      nameStatus = "unknown",
      brickCount = nil,
      brickCountStatus = "unknown",
      componentCount = nil,
      componentCountStatus = "unknown",
    },
    limitations = {
      "serverName requires live server object or config adapter",
      "worldName, brickCount, and componentCount require world-state discovery",
      "Brickadia build detection is report-only until a reliable runtime build source is proven",
    },
    compatibility = compatibility,
  }

  return result(true, "OK", "Server status collected", data)
end

BMF.plugins = {}

BMF.plugins.list = function()
  local items = {}
  local names = {}
  for name in pairs(state.plugins) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local plugin = state.plugins[name]
    local manifest = plugin.manifest or {}
    local watchdog = plugin_watchdog_snapshot(name)
    items[#items + 1] = {
      name = name,
      displayName = manifest.name or plugin.name or name,
      version = manifest.version or plugin.version or "",
      description = manifest.description or plugin.description or "",
      capabilities = copy_table(manifest.capabilities or plugin.capabilities or {}),
      errorCount = watchdog.errorCount,
      isolated = watchdog.isolated,
      isolatedAt = watchdog.isolatedAt,
      isolatedReason = watchdog.isolatedReason,
      lastError = watchdog.lastError,
    }
  end
  return result(true, "OK", "Plugins listed", { plugins = items })
end

BMF.plugins.watchdog = function()
  local items = plugin_watchdog_list()
  return result(true, "OK", "Plugin watchdog status listed", {
    enabled = plugin_watchdog_enabled(),
    threshold = plugin_watchdog_max_errors(),
    isolated = plugin_watchdog_isolated_count(),
    plugins = items,
  })
end

BMF.plugins.hasCapability = function(plugin_name, capability)
  local plugin = state.plugins[tostring(plugin_name or "")]
  if not plugin then
    return false
  end
  local manifest = plugin.manifest or {}
  local capabilities = manifest.capabilities or plugin.capabilities or {}
  for _, item in ipairs(capabilities) do
    if item == capability or item == "*" then
      return true
    end
    if capability == "server.exec" and item == "server.exec.restricted" then
      return true
    end
  end
  return false
end

BMF.storage = {}

local function plugin_root_path(plugin_name)
  local name, err = safe_name(plugin_name, "plugin name")
  if not name then
    return nil, err
  end
  return PLUGINS_DIR .. "/" .. name, nil
end

local function plugin_data_path(plugin_name, relative_path)
  local root, root_err = plugin_root_path(plugin_name)
  if not root then
    return nil, root_err
  end
  local relative, relative_err = safe_relative_path(relative_path, "data path")
  if not relative then
    return nil, relative_err
  end
  return root .. "/data/" .. relative, nil
end

BMF.storage.readText = function(plugin_name, relative_path)
  local path, path_error = plugin_data_path(plugin_name, relative_path)
  if not path then
    return result(false, "INVALID_STORAGE_PATH", path_error)
  end
  local data = read_file(path)
  if data == nil then
    return result(false, "STORAGE_NOT_FOUND", "storage file was not found", { path = path })
  end
  return result(true, "OK", "Storage file read", { path = path, text = data })
end

BMF.storage.writeText = function(plugin_name, relative_path, text)
  local path, path_error = plugin_data_path(plugin_name, relative_path)
  if not path then
    return result(false, "INVALID_STORAGE_PATH", path_error)
  end
  if not write_file(path, tostring(text or "")) then
    return result(false, "STORAGE_WRITE_FAILED", "storage file could not be written", { path = path })
  end
  return result(true, "OK", "Storage file written", { path = path, bytes = #tostring(text or "") })
end

BMF.storage.readJson = function(plugin_name, relative_path)
  local read = BMF.storage.readText(plugin_name, relative_path)
  if not read.ok then
    return read
  end
  local value, err = json_decode(read.data.text or "")
  if err then
    return result(false, "JSON_PARSE_FAILED", "storage JSON could not be parsed", {
      path = read.data.path,
      error = err,
    })
  end
  return result(true, "OK", "Storage JSON read", {
    path = read.data.path,
    value = value,
  })
end

BMF.storage.writeJson = function(plugin_name, relative_path, value)
  local encoded = json_encode(value or {})
  local written = BMF.storage.writeText(plugin_name, relative_path, encoded)
  if not written.ok then
    return written
  end
  written.message = "Storage JSON written"
  written.data.json = encoded
  return written
end

BMF.storage.appendText = function(plugin_name, relative_path, text)
  local path, path_error = plugin_data_path(plugin_name, relative_path)
  if not path then
    return result(false, "INVALID_STORAGE_PATH", path_error)
  end
  if not append_file(path, tostring(text or "")) then
    return result(false, "STORAGE_WRITE_FAILED", "storage file could not be appended", { path = path })
  end
  return result(true, "OK", "Storage file appended", { path = path, bytes = #tostring(text or "") })
end

BMF.storage.readConfigText = function(plugin_name)
  local root, root_error = plugin_root_path(plugin_name)
  if not root then
    return result(false, "INVALID_STORAGE_PATH", root_error)
  end
  local path = root .. "/config.json"
  local data = read_file(path)
  if data == nil then
    return result(false, "CONFIG_NOT_FOUND", "config.json was not found", { path = path })
  end
  return result(true, "OK", "Plugin config read", { path = path, text = data })
end

BMF.storage.writeConfigText = function(plugin_name, text)
  local root, root_error = plugin_root_path(plugin_name)
  if not root then
    return result(false, "INVALID_STORAGE_PATH", root_error)
  end
  local path = root .. "/config.json"
  if not write_file(path, tostring(text or "")) then
    return result(false, "CONFIG_WRITE_FAILED", "config.json could not be written", { path = path })
  end
  return result(true, "OK", "Plugin config written", { path = path, bytes = #tostring(text or "") })
end

BMF.storage.readConfig = function(plugin_name)
  local read = BMF.storage.readConfigText(plugin_name)
  if not read.ok then
    return read
  end
  local value, err = json_decode(read.data.text or "")
  if err then
    return result(false, "JSON_PARSE_FAILED", "plugin config JSON could not be parsed", {
      path = read.data.path,
      error = err,
    })
  end
  return result(true, "OK", "Plugin config JSON read", {
    path = read.data.path,
    value = value,
  })
end

BMF.storage.writeConfig = function(plugin_name, value)
  local encoded = json_encode(value or {})
  local written = BMF.storage.writeConfigText(plugin_name, encoded)
  if not written.ok then
    return written
  end
  written.message = "Plugin config JSON written"
  written.data.json = encoded
  return written
end

BMF.commands = {}

local function command_output(ar, line)
  local text = tostring(line or "")
  if ar and ar.Log then
    ar:Log(text)
  end
  if not (ar and (ar.NoEventLog == true or ar.suppressEventLog == true)) then
    log("command", text)
  end
end

local function command_args_to_text(params)
  if type(params) == "string" then
    return trim_string(params)
  end
  if type(params) == "table" then
    local parts = {}
    for index, value in ipairs(params) do
      parts[index] = tostring(value)
    end
    return table.concat(parts, " ")
  end
  return ""
end

local function sorted_command_names()
  local names = {}
  for name in pairs(state.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function parse_command_options(args)
  local text = trim_string(args or "")
  local options = {}
  local positional = {}

  for token in text:gmatch("%S+") do
    local key, value = token:match("^([A-Za-z0-9_.%-]+)=(.*)$")
    if key then
      options[key:lower()] = value
    else
      positional[#positional + 1] = token
    end
  end

  options._positional = positional
  return options
end

local function percent_decode(value)
  local text = tostring(value or "")
  text = text:gsub("+", " ")
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function option_number(options, key, default)
  local value = options[key]
  if value == nil or value == "" then
    return default
  end
  return finite_number(value, default)
end

function option_boolean(options, key, default)
  local value = options[key]
  if value == nil or value == "" then
    return default == true
  end
  if type(value) == "boolean" then
    return value == true
  end
  local text = tostring(value):lower()
  return text == "1" or text == "true" or text == "yes" or text == "on"
end

local function register_console_handler_for_command(name)
  if state.console_command_callbacks[name] then
    return true
  end
  if type(RegisterConsoleCommandGlobalHandler) ~= "function" then
    return false
  end

  state.console_command_callbacks[name] = function(command, params, ar)
    return BMF.commands.dispatch(name, command_args_to_text(params), ar)
  end

  local ok, err = pcall(RegisterConsoleCommandGlobalHandler, name, state.console_command_callbacks[name])
  if not ok then
    state.console_command_callbacks[name] = nil
    log("warn", "failed to register console command " .. name .. ": " .. tostring(err))
    return false
  end

  log("info", "registered console command " .. name)
  return true
end

local function register_command(name, description, handler, owner)
  local command_name = trim_string(name):lower()
  if command_name == "" then
    return result(false, "INVALID_COMMAND", "command name is required")
  end
  if not command_name:match("^bmf%.[a-z0-9_.%-]+$") then
    return result(false, "INVALID_COMMAND", "command name must start with bmf. and use simple tokens")
  end
  if type(handler) ~= "function" then
    return result(false, "INVALID_HANDLER", "command handler function is required")
  end

  state.commands[command_name] = {
    name = command_name,
    description = tostring(description or ""),
    handler = handler,
    owner = owner,
    console_registered = register_console_handler_for_command(command_name),
  }

  return result(true, "OK", "Command registered", {
    name = command_name,
    owner = owner,
    console_registered = state.commands[command_name].console_registered,
  })
end

BMF.commands.register = function(name, description, handler)
  return register_command(name, description, handler, nil)
end

local function remove_commands_for_owner(owner)
  if owner == nil then
    return 0
  end
  local removed = 0
  for name, command in pairs(state.commands) do
    if type(command) == "table" and command.owner == owner then
      state.commands[name] = nil
      removed = removed + 1
    end
  end
  return removed
end

BMF.commands.list = function()
  local items = {}
  for _, name in ipairs(sorted_command_names()) do
    local command = state.commands[name]
    items[#items + 1] = {
      name = name,
      description = command.description,
      owner = command.owner,
      console_registered = command.console_registered and true or false,
    }
  end
  return result(true, "OK", "Commands listed", { commands = items })
end

BMF.commands.dispatch = function(name, args, ar)
  local command_name = trim_string(name):lower()
  local command = state.commands[command_name]
  if not command then
    command_output(ar, "BMF ERROR UNKNOWN_COMMAND " .. command_name)
    audit_record("command.unknown", {
      command = command_name,
      args = args or "",
    }, {
      source = "command",
      severity = "warn",
      ok = false,
      code = "UNKNOWN_COMMAND",
    })
    return false
  end

  if command.owner and plugin_watchdog_isolated(command.owner) then
    local watchdog = plugin_watchdog_snapshot(command.owner)
    command_output(ar, "BMF " .. command_name .. " PLUGIN_ISOLATED Plugin is isolated by watchdog")
    command_output(ar, "plugin=" .. tostring(command.owner))
    command_output(ar, "error_count=" .. tostring(watchdog.errorCount or 0))
    command_output(ar, "isolated=true")
    command_output(ar, "isolated_reason=" .. tostring(watchdog.isolatedReason or ""))
    audit_record("command.blocked", {
      command = command_name,
      args = args or "",
      owner = command.owner,
      reason = "plugin-isolated",
      errorCount = watchdog.errorCount or 0,
    }, {
      source = "command",
      plugin = command.owner,
      severity = "warn",
      ok = false,
      code = "PLUGIN_ISOLATED",
    })
    return true
  end

  command_output(ar, "BMF " .. command_name .. " begin")
  local handler_started_clock = os.clock()
  local ok, response_or_error = pcall(command.handler, args or "", ar)
  local handler_duration_ms = BMF_telemetry_duration_ms(handler_started_clock)
  if command.owner then
    BMF_telemetry_record_plugin_hook(command.owner, "command:" .. command_name, handler_duration_ms, ok)
  end
  if not ok then
    if command.owner then
      record_plugin_error(command.owner, "command:" .. command_name, response_or_error, {
        command = command_name,
        args = args or "",
      })
    end
    command_output(ar, "BMF " .. command_name .. " ERROR " .. tostring(response_or_error))
    audit_record("command.error", {
      command = command_name,
      args = args or "",
      owner = command.owner,
      error = tostring(response_or_error),
    }, {
      source = "command",
      plugin = command.owner,
      severity = "error",
      ok = false,
      code = "COMMAND_ERROR",
    })
    return true
  end

  local response = response_or_error
  if type(response) ~= "table" then
    response = result(true, "OK", tostring(response or "Command completed"))
  end

  command_output(
    ar,
    "BMF " .. command_name .. " " .. tostring(response.code or (response.ok and "OK" or "ERROR")) ..
      " " .. tostring(response.message or "")
  )

  local lines = response.data and response.data.lines
  if type(lines) == "table" then
    for _, line in ipairs(lines) do
      command_output(ar, tostring(line))
    end
  end

  audit_record("command.dispatch", {
    command = command_name,
    args = args or "",
    owner = command.owner,
    responseCode = tostring(response.code or ""),
    responseOk = response.ok and true or false,
  }, {
    source = "command",
    plugin = command.owner,
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })

  return true
end

BMF.commands.dispatchWithAccess = function(policy, actor, name, args, ar)
  local command_name = trim_string(name):lower()
  local evaluator = BMF.permissions and BMF.permissions.evaluateCommandAccess
  if type(evaluator) ~= "function" then
    command_output(ar, "BMF " .. command_name .. " ACCESS_ERROR COMMAND_ACCESS_UNAVAILABLE")
    audit_record("command.denied", {
      command = command_name,
      args = args or "",
      reason = "command-access-unavailable",
    }, {
      source = "command",
      severity = "error",
      ok = false,
      code = "COMMAND_ACCESS_UNAVAILABLE",
    })
    return false
  end

  local access = evaluator(policy, actor, command_name)
  if not access.ok then
    command_output(ar, "BMF " .. command_name .. " ACCESS_ERROR " .. tostring(access.code or "ACCESS_ERROR"))
    command_output(ar, "reason=" .. tostring(access.message or ""))
    audit_record("command.denied", {
      command = command_name,
      args = args or "",
      reason = tostring(access.code or "ACCESS_ERROR"),
      message = tostring(access.message or ""),
    }, {
      source = "command",
      severity = "warn",
      ok = false,
      code = tostring(access.code or "ACCESS_ERROR"),
    })
    return false
  end

  local data = access.data or {}
  if data.allowed ~= true then
    local decision = tostring(data.decision or data.reason or "access-denied")
    command_output(ar, "BMF " .. command_name .. " ACCESS_DENIED " .. decision)
    command_output(ar, "actor_source=" .. tostring(data.actorSource or ""))
    command_output(ar, "actor_uuid=" .. tostring(data.uuid or ""))
    command_output(ar, "matched_roles=" .. table.concat(data.matchedRoles or {}, ","))
    audit_record("command.denied", {
      command = command_name,
      args = args or "",
      reason = decision,
      actorSource = data.actorSource or "",
      uuid = data.uuid or "",
      actorRoles = data.actorRoles or {},
      requiredRoles = data.requiredRoles or {},
      matchedRoles = data.matchedRoles or {},
      ruleFound = data.ruleFound == true,
    }, {
      source = "command",
      severity = "warn",
      ok = false,
      code = "ACCESS_DENIED",
    })
    return true
  end

  audit_record("command.access_granted", {
    command = command_name,
    args = args or "",
    reason = tostring(data.decision or ""),
    actorSource = data.actorSource or "",
    uuid = data.uuid or "",
    actorRoles = data.actorRoles or {},
    matchedRoles = data.matchedRoles or {},
    ruleFound = data.ruleFound == true,
  }, {
    source = "command",
    severity = "info",
    ok = true,
    code = "ACCESS_GRANTED",
  })

  return BMF.commands.dispatch(command_name, args, ar)
end

local function register_builtin_commands()
  local function health_command_response()
    local health = BMF.health()
    return result(true, "OK", "BMF runtime is loaded", {
      lines = {
        "version=" .. tostring(health.data.version),
        "target_build=" .. tostring(health.data.target_build),
        "compatibility_status=" .. tostring(health.data.compatibility_status),
        "build_detection=" .. tostring(health.data.build_detection),
        "runtime_required_helper_groups=" .. tostring(health.data.runtime_required_helper_groups),
        "runtime_required_helper_groups_available=" .. tostring(health.data.runtime_required_helper_groups_available),
        "plugins_loaded=" .. tostring(health.data.plugins_loaded),
        "plugin_errors=" .. tostring(health.data.plugin_errors),
        "status_path=" .. tostring(health.data.status_path),
        "telemetry_path=" .. tostring(health.data.telemetry_path),
        "log_path=" .. tostring(health.data.log_path),
      },
    })
  end

  local function version_command_response()
    local compatibility = compatibility_snapshot()
    return result(true, "OK", "BMF version", {
      version = VERSION,
      targetBuild = TARGET_BRICKADIA_BUILD,
      targetName = TARGET_BRICKADIA_NAME,
      platform = TARGET_PLATFORM,
      serverExecutable = TARGET_SERVER_EXECUTABLE,
      compatibilityStatus = compatibility.status,
      buildDetection = BUILD_DETECTION_MODE,
      lines = {
        "version=" .. tostring(VERSION),
        "target_name=" .. tostring(TARGET_BRICKADIA_NAME),
        "target_build=" .. tostring(TARGET_BRICKADIA_BUILD),
        "platform=" .. tostring(TARGET_PLATFORM),
        "server_executable=" .. tostring(TARGET_SERVER_EXECUTABLE),
        "compatibility_status=" .. tostring(compatibility.status),
        "build_detection=" .. tostring(BUILD_DETECTION_MODE),
      },
    })
  end

  BMF.commands.register("bmf.status", "Show BMF runtime health.", function()
    return health_command_response()
  end)

  BMF.commands.register("bmf.health", "Show BMF runtime health.", function()
    return health_command_response()
  end)

  BMF.commands.register("bmf.telemetry", "Show BMF aggregate telemetry.", function(args)
    local options = parse_command_options(args)
    local telemetry = BMF.telemetry()
    local data = telemetry.data or {}
    local snapshot = data.telemetry or {}
    local commands = snapshot.commands or {}
    local events = snapshot.events or {}
    local plugins = snapshot.plugins or {}
    local scheduler = snapshot.scheduler or {}
    local last_command = commands.last or {}
    local lines = {
      "telemetry_path=" .. tostring(data.telemetry_path or BMF_TELEMETRY_PATH),
      "schema_version=" .. tostring(data.schema_version or 0),
      "commands_total=" .. tostring(commands.total or 0),
      "commands_ok=" .. tostring(commands.ok or 0),
      "commands_error=" .. tostring(commands.error or 0),
      "events_total=" .. tostring(events.total or 0),
      "event_handler_calls=" .. tostring(events.handler_calls or 0),
      "event_handler_errors=" .. tostring(events.handler_errors or 0),
      "plugin_hook_total=" .. tostring(plugins.hook_total or 0),
      "plugin_hook_error=" .. tostring(plugins.hook_error or 0),
      "scheduler_callback_total=" .. tostring(scheduler.callback_total or 0),
      "scheduler_callback_error=" .. tostring(scheduler.callback_error or 0),
      "last_command=" .. tostring(last_command.command or ""),
      "last_command_total_ms=" .. tostring(last_command.duration_ms or 0),
      "last_command_dispatch_ms=" .. tostring(last_command.dispatch_ms or 0),
    }
    if option_boolean(options, "json", false) then
      lines[#lines + 1] = "telemetry_json=" .. json_encode(snapshot)
    end
    telemetry.data.lines = lines
    return telemetry
  end)

  BMF.commands.register("bmf.version", "Show BMF version and target build.", function()
    return version_command_response()
  end)

  BMF.commands.register("bmf.compatibility", "Show Brickadia and UE4SS compatibility diagnostics.", function()
    local checked = BMF.compatibility.check()
    local data = checked.data or {}
    local ue4ss = data.ue4ss or {}
    local missing = ue4ss.missingRequiredGroups or {}
    local lines = {
      "compatibility_status=" .. tostring(data.status or ""),
      "target_name=" .. tostring(data.targetName or ""),
      "target_build=" .. tostring(data.targetBuild or ""),
      "platform=" .. tostring(data.platform or ""),
      "server_executable=" .. tostring(data.serverExecutable or ""),
      "build_detection=" .. tostring(data.buildDetection or ""),
      "build_detected=" .. tostring(data.buildDetected == true),
      "detected_build=" .. tostring(data.detectedBuild or ""),
      "unsupported_build_policy=" .. tostring(data.unsupportedBuildPolicy or ""),
      "ue4ss_required=" .. tostring(ue4ss.required == true),
      "ue4ss_status=" .. tostring(ue4ss.status or ""),
      "required_helper_groups=" .. tostring(ue4ss.requiredGroupCount or 0),
      "required_helper_groups_available=" .. tostring(ue4ss.requiredGroupsAvailable or 0),
      "missing_required_helper_groups=" .. table.concat(missing, "|"),
    }

    for _, group in ipairs(ue4ss.helperGroups or {}) do
      lines[#lines + 1] = "helper_" .. tostring(group.id or "") .. "_available=" .. tostring(group.available == true)
      lines[#lines + 1] = "helper_" .. tostring(group.id or "") .. "_required=" .. tostring(group.required == true)
      lines[#lines + 1] = "helper_" .. tostring(group.id or "") .. "_available_helpers=" .. table.concat(group.availableHelpers or {}, ",")
      for _, helper in ipairs(group.helpers or {}) do
        local safe_name = tostring(helper.name or ""):gsub("[^A-Za-z0-9_]", "_")
        lines[#lines + 1] = "helper_" .. safe_name .. "_type=" .. tostring(helper.type or "nil")
      end
    end

    checked.data.lines = lines
    return checked
  end)

  BMF.commands.register("bmf.server.status", "Show structured BMF server status.", function()
    local status = BMF.server.status()
    local data = status.data or {}
    local lines = {
      "version=" .. tostring(data.version or ""),
      "bmf_status=" .. tostring(data.bmfStatus or ""),
      "uptime_seconds=" .. tostring(data.uptimeSeconds or 0),
      "build_id=" .. tostring(data.buildId or ""),
      "executable=" .. tostring(data.executable or ""),
      "server_name_status=" .. tostring(data.serverNameStatus or ""),
      "description_status=" .. tostring(data.descriptionStatus or ""),
      "world_name_status=" .. tostring(data.worldNameStatus or ""),
      "brick_count_status=" .. tostring(data.brickCountStatus or ""),
      "component_count_status=" .. tostring(data.componentCountStatus or ""),
      "player_count=" .. tostring(data.playerCount or 0),
      "player_adapter=" .. tostring(data.playerAdapter or ""),
      "plugins_loaded=" .. tostring((data.plugins and data.plugins.loaded) or 0),
      "plugin_errors=" .. tostring((data.plugins and data.plugins.errors) or 0),
      "commands_registered=" .. tostring((data.commands and data.commands.registered) or 0),
      "timers_active=" .. tostring((data.runtime and data.runtime.timersActive) or 0),
      "server_ready=" .. tostring((data.runtime and data.runtime.serverReady) or false),
      "plugin_tick_active=" .. tostring((data.runtime and data.runtime.pluginTickActive) or false),
      "plugin_tick_count=" .. tostring((data.runtime and data.runtime.pluginTickCount) or 0),
      "plugin_tick_interval_ms=" .. tostring((data.runtime and data.runtime.pluginTickIntervalMs) or 0),
      "audit_records=" .. tostring((data.runtime and data.runtime.auditRecords) or 0),
      "rate_limit_buckets=" .. tostring((data.runtime and data.runtime.rateLimitBuckets) or 0),
      "api_labels=" .. tostring((data.runtime and data.runtime.apiLabels) or 0),
      "compatibility_status=" .. tostring((data.runtime and data.runtime.compatibilityStatus) or ""),
      "target_build=" .. tostring((data.runtime and data.runtime.targetBuild) or ""),
      "build_detection=" .. tostring((data.runtime and data.runtime.buildDetection) or ""),
      "required_helper_groups=" .. tostring((data.runtime and data.runtime.requiredHelperGroups) or 0),
      "required_helper_groups_available=" .. tostring((data.runtime and data.runtime.requiredHelperGroupsAvailable) or 0),
      "missing_required_helper_groups=" .. tostring((data.runtime and data.runtime.missingRequiredHelperGroups) or 0),
      "unsafe_global_denials=" .. tostring((data.runtime and data.runtime.unsafeGlobalDenials) or 0),
      "unsafe_globals_allowed=" .. tostring((data.config and data.config.allowPluginUnsafeGlobals) == true),
      "status_path=" .. tostring((data.paths and data.paths.status) or ""),
      "telemetry_path=" .. tostring((data.paths and data.paths.telemetry) or ""),
      "event_log_path=" .. tostring((data.paths and data.paths.events) or ""),
      "audit_log_path=" .. tostring((data.paths and data.paths.audit) or ""),
    }
    return result(true, "OK", "Server status collected", {
      lines = lines,
      status = data,
    })
  end)

  BMF.commands.register("bmf.server.save", "Save the running world through BMF.server.save.", function(args)
    local options = parse_command_options(args)
    local name = options.name or options.savename or options.world
    local saved = BMF.server.save({ name = name })
    local lines = {
      "world=" .. tostring((saved.data and saved.data.world) or ""),
      "save_name=" .. tostring((saved.data and saved.data.saveName) or ""),
      "generated_name=" .. tostring((saved.data and saved.data.generatedName) or false),
    }
    if saved.data then
      lines[#lines + 1] = "command=" .. tostring(saved.data.command or "")
      lines[#lines + 1] = "api=" .. tostring(saved.data.api or "")
    end
    saved.data.lines = lines
    return saved
  end)

  BMF.commands.register("bmf.server.shutdown", "Gracefully stop the Brickadia server after explicit confirmation.", function(args)
    local options = parse_command_options(args)
    local shutdown = BMF.server.shutdown({
      confirm = options.confirm or options.confirmation,
      reason = options.reason or "",
      delayMs = option_number(options, "delayms", option_number(options, "delay", 1000)),
    })
    local data = shutdown.data or {}
    local lines = {
      "shutdown_scheduled=" .. tostring(data.shutdownScheduled == true),
      "required_confirmation=" .. tostring(data.requiredConfirmation or ""),
      "command=" .. tostring(data.command or ""),
      "delay_ms=" .. tostring(data.delayMs or ""),
      "reason=" .. tostring(data.reason or ""),
      "api=" .. tostring(data.api or ""),
      "executor=" .. tostring(data.executor or ""),
      "executor_code=" .. tostring(data.executorCode or ""),
    }
    shutdown.data = shutdown.data or {}
    shutdown.data.lines = lines
    return shutdown
  end)

  BMF.commands.register("bmf.plugins", "List loaded BMF plugins.", function()
    local lines = {}
    local listed = BMF.plugins.list()
    local plugins = listed.data.plugins or {}
    if #plugins == 0 then
      lines[#lines + 1] = "plugins_loaded=0"
    else
      lines[#lines + 1] = "plugins_loaded=" .. tostring(#plugins)
      for _, plugin in ipairs(plugins) do
        lines[#lines + 1] = "plugin=" .. tostring(plugin.name) ..
          " version=" .. tostring(plugin.version or "") ..
          " capabilities=" .. tostring(#(plugin.capabilities or {})) ..
          " errors=" .. tostring(plugin.errorCount or 0) ..
          " isolated=" .. tostring(plugin.isolated == true)
      end
    end
    if #state.plugin_errors > 0 then
      lines[#lines + 1] = "plugin_errors=" .. tostring(#state.plugin_errors)
    end
    return result(true, "OK", "Plugins listed", { lines = lines })
  end)

  BMF.commands.register("bmf.plugins.watchdog", "Show plugin watchdog state.", function()
    local watched = BMF.plugins.watchdog()
    local lines = {
      "watchdog_enabled=" .. tostring((watched.data and watched.data.enabled) == true),
      "watchdog_threshold=" .. tostring((watched.data and watched.data.threshold) or 0),
      "watchdog_isolated=" .. tostring((watched.data and watched.data.isolated) or 0),
    }
    for index, plugin in ipairs((watched.data and watched.data.plugins) or {}) do
      local last = plugin.lastError or {}
      lines[#lines + 1] =
        "plugin_" .. tostring(index) ..
        "=" .. tostring(plugin.name or "") ..
        "|errors=" .. tostring(plugin.errorCount or 0) ..
        "|isolated=" .. tostring(plugin.isolated == true) ..
        "|last_hook=" .. tostring(last.hook or "") ..
        "|last_error=" .. tostring(last.error or "")
    end
    watched.data.lines = lines
    return watched
  end)

  BMF.commands.register("bmf.apis", "List BMF API stability and crash-risk labels.", function(args)
    local options = parse_command_options(args)
    if (options.name == nil or options.name == "") and options._positional and options._positional[1] then
      options.name = options._positional[1]
    end

    local listed = nil
    if options.name and tostring(options.name) ~= "" then
      listed = BMF.apis.get(options.name)
      if listed.ok and listed.data and listed.data.api then
        listed.data.apis = { listed.data.api }
        listed.data.count = 1
        listed.data.summary = api_registry_summary(listed.data.apis)
      end
    else
      listed = BMF.apis.list(options)
    end

    local apis = (listed.data and listed.data.apis) or {}
    local summary = (listed.data and listed.data.summary) or api_registry_summary(apis)
    local limit = option_number(options, "limit", 50)
    if limit < 1 then
      limit = 1
    end
    if limit > 100 then
      limit = 100
    end

    local lines = {
      "api_count=" .. tostring(#apis),
      "summary_total=" .. tostring(summary.total or #apis),
      "summary_requires_player=" .. tostring(summary.requiresPlayer or 0),
      "summary_stability_stable=" .. tostring((summary.stability and summary.stability.stable) or 0),
      "summary_stability_experimental=" .. tostring((summary.stability and summary.stability.experimental) or 0),
      "summary_stability_scaffold=" .. tostring((summary.stability and summary.stability.scaffold) or 0),
      "summary_stability_file_backed=" .. tostring((summary.stability and summary.stability["file-backed"]) or 0),
      "summary_stability_restricted=" .. tostring((summary.stability and summary.stability.restricted) or 0),
      "summary_risk_unsafe_native=" .. tostring((summary.risk and summary.risk["unsafe-native"]) or 0),
      "summary_risk_live_player=" .. tostring((summary.risk and summary.risk["live-player"]) or 0),
    }
    local count = math.min(#apis, limit)
    for index = 1, count do
      local api = apis[index]
      lines[#lines + 1] =
        "api_" .. tostring(index) ..
        "=" .. tostring(api.name or "") ..
        "|namespace=" .. tostring(api.namespace or "") ..
        "|stability=" .. tostring(api.stability or "") ..
        "|risk=" .. tostring(api.risk or "") ..
        "|validation=" .. tostring(api.validation or "") ..
        "|requires_player=" .. tostring(api.requiresPlayer == true) ..
        "|capability=" .. tostring(api.capability or "")
    end
    if #apis > count then
      lines[#lines + 1] = "api_truncated=" .. tostring(#apis - count)
    end
    listed.data = listed.data or {}
    listed.data.lines = lines
    return listed
  end)

  BMF.commands.register("bmf.sandbox", "Show BMF plugin sandbox policy.", function()
    local policy = BMF.sandbox.policy()
    local denials = BMF.sandbox.denials()
    local blocked = (policy.data and policy.data.blockedGlobals) or {}
    local lines = {
      "unsafe_globals_allowed=" .. tostring((policy.data and policy.data.allowPluginUnsafeGlobals) == true),
      "required_capability=" .. tostring((policy.data and policy.data.requiredCapability) or ""),
      "blocked_globals_count=" .. tostring(#blocked),
      "denied_lookup_count=" .. tostring((denials.data and denials.data.count) or 0),
    }
    for index, name in ipairs(blocked) do
      lines[#lines + 1] = "blocked_global_" .. tostring(index) .. "=" .. tostring(name)
    end
    for index, denial in ipairs((denials.data and denials.data.denials) or {}) do
      lines[#lines + 1] =
        "denial_" .. tostring(index) ..
        "=" .. tostring(denial.plugin or "") ..
        "|global=" .. tostring(denial.global or "") ..
        "|count=" .. tostring(denial.count or 0)
    end
    policy.data.lines = lines
    return policy
  end)

  BMF.commands.register("bmf.commands", "List registered BMF console commands.", function()
    local lines = {}
    for _, name in ipairs(sorted_command_names()) do
      local command = state.commands[name]
      lines[#lines + 1] = name .. " - " .. tostring(command.description or "")
    end
    return result(true, "OK", "Commands listed", { lines = lines })
  end)

  BMF.commands.register("bmf.audit.tail", "Show recent BMF audit records.", function(args)
    local options = parse_command_options(args)
    local recent = BMF.audit.recent(option_number(options, "limit", 10))
    local lines = {
      "audit_count=" .. tostring((recent.data and recent.data.count) or 0),
      "audit_path=" .. AUDIT_LOG_PATH,
    }
    if recent.data and type(recent.data.records) == "table" then
      for index, record in ipairs(recent.data.records) do
        lines[#lines + 1] =
          "audit_" .. tostring(index) ..
          "=" .. tostring(record.action or "") ..
          "|severity=" .. tostring(record.severity or "") ..
          "|source=" .. tostring(record.source or "") ..
          "|code=" .. tostring(record.code or "") ..
          "|plugin=" .. tostring(record.plugin or "")
      end
    end
    recent.data.lines = lines
    return recent
  end)

  BMF.commands.register("bmf.ratelimits", "Show active BMF rate-limit buckets.", function()
    local listed = BMF.rateLimits.recent()
    local buckets = (listed.data and listed.data.buckets) or {}
    local lines = {
      "bucket_count=" .. tostring(#buckets),
    }
    for index, bucket in ipairs(buckets) do
      lines[#lines + 1] =
        "bucket_" .. tostring(index) ..
        "=" .. tostring(bucket.action or "") ..
        "|subject=" .. tostring(bucket.subject or "") ..
        "|count=" .. tostring(bucket.count or 0) ..
        "|retry_after=" .. tostring(bucket.retryAfterSeconds or 0)
    end
    listed.data.lines = lines
    return listed
  end)

  BMF.commands.register("bmf.socket.status", "Show BMF socket transport status.", function()
    local status = BMF_socket_status_snapshot()
    return result(true, "OK", "BMF socket status", {
      socket = status,
      lines = {
        "enabled=" .. tostring(status.enabled),
        "available=" .. tostring(status.available),
        "started=" .. tostring(status.started),
        "host=" .. tostring(status.host),
        "port=" .. tostring(status.port),
        "poll_interval_ms=" .. tostring(status.pollIntervalMs),
        "sent_events=" .. tostring(status.sentEvents),
        "sent_responses=" .. tostring(status.sentResponses),
        "received_commands=" .. tostring(status.receivedCommands),
        "received_messages=" .. tostring(status.receivedMessages),
        "poll_count=" .. tostring(status.pollCount),
        "last_poll_at=" .. tostring(status.lastPollAt),
        "last_drain_count=" .. tostring(status.lastDrainCount),
        "worker_started=" .. tostring(status.workerStarted),
        "last_error=" .. tostring(status.lastError),
        "native_status=" .. tostring(status.nativeStatus),
      },
    })
  end)

  BMF.commands.register("bmf.tools.uobject.describe", "Describe one explicit live UObject pointer without scanning.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.uobject.describe(options)
  end)

  BMF.commands.register("bmf.tools.applicator.status", "Show live applicator hook status.", function(args)
    local options = parse_command_options(args)
    local refresh = tostring(options.refresh or ""):lower()
    local status = BMF.tools.applicator.status({
      refresh = refresh == "1" or refresh == "true" or refresh == "yes",
      limit = option_number(options, "limit", 10),
    })
    return status
  end)

  BMF.commands.register("bmf.tools.applicator.refresh", "Refresh denied applicator component type cache.", function()
    local refreshed = BMF.tools.applicator.refreshComponentCache()
    local data = refreshed.data or {}
    local lines = {
      "cached_count=" .. tostring(data.cachedCount or 0),
    }
    local index = 0
    for address, cached in pairs(data.cache or {}) do
      index = index + 1
      lines[#lines + 1] =
        "component_cache_" .. tostring(index) .. "=" ..
        tostring(cached.name or "") .. "|" .. tostring(address) .. "|source=" .. tostring(cached.source or "")
    end
    refreshed.data.lines = lines
    return refreshed
  end)

  BMF.commands.register("bmf.tools.applicator.native-targets", "Resolve native ServerAddComponent blocker targets.", function(args)
    local options = parse_command_options(args)
    local refresh = tostring(options.refresh or "true"):lower()
    return BMF.tools.applicator.nativeTargets({
      refresh = not (refresh == "0" or refresh == "false" or refresh == "no"),
    })
  end)

  BMF.commands.register("bmf.tools.applicator.scan-objects", "Scan live UE objects for applicator target discovery.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.applicator.scanObjects({
      pattern = options.pattern or options.patterns or "",
      name = options.name or options.fullname or "",
      class = options.class or options.classname or "",
      any = options.any or "",
      unsafe = options.unsafe or "",
      limit = option_number(options, "limit", 50),
      max = option_number(options, "max", option_number(options, "maxscan", 250000)),
    })
  end)

  BMF.commands.register("bmf.tools.treecut.trace.enable", "Enable bounded handaxe/tree-cut trace hooks.", function(args)
    local options = parse_command_options(args)
    local melee_only = option_boolean(options, "meleeonly", false)
    return BMF.tools.treeCutTrace.enable({
      includeApplyDamage = not (
        melee_only
        or option_boolean(options, "applydamage", true) == false
        or option_boolean(options, "damage", true) == false
      ),
      includeMelee = melee_only or option_boolean(options, "melee", false) or option_boolean(options, "includemelee", false),
      maxEvents = option_number(options, "maxevents", option_number(options, "max", 100)),
      sampleLimit = option_number(options, "samplelimit", option_number(options, "samples", 200)),
    })
  end)

  BMF.commands.register("bmf.tools.treecut.trace.disable", "Disable handaxe/tree-cut trace hooks.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutTrace.disable({
      reason = options.reason or "command",
    })
  end)

  BMF.commands.register("bmf.tools.treecut.trace.status", "Show handaxe/tree-cut trace hook status.", function()
    return BMF.tools.treeCutTrace.status()
  end)

  BMF.commands.register("bmf.tools.treecut.trace.recent", "Show recent handaxe/tree-cut trace events.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutTrace.recent({
      limit = option_number(options, "limit", 10),
    })
  end)

  BMF.commands.register("bmf.tools.treecut.trace.clear", "Clear handaxe/tree-cut trace counters.", function()
    return BMF.tools.treeCutTrace.clear()
  end)

  BMF.commands.register("bmf.tools.treecut.native.start", "Start native CityRPG tree-cut hit event capture.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutNative.start({
      reason = options.reason or "command",
    })
  end)

  BMF.commands.register("bmf.tools.treecut.native.stop", "Stop native CityRPG tree-cut hit event capture.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutNative.stop({
      reason = options.reason or "command",
    })
  end)

  BMF.commands.register("bmf.tools.treecut.native.status", "Show native CityRPG tree-cut hit event capture status.", function()
    return BMF.tools.treeCutNative.status()
  end)

  BMF.commands.register("bmf.tools.treecut.native.resolve-handaxe", "Resolve the native handaxe class used by tree-cut hit capture.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutNative.resolveHandaxe({
      reason = options.reason or "command",
      loadAsset = option_boolean(options, "loadasset", false),
    })
  end)

  BMF.commands.register("bmf.tools.treecut.native.refresh-targets", "Refresh cached native tree actors used by tree-cut hit target resolution.", function()
    return BMF.tools.treeCutNative.refreshTargets()
  end)

  BMF.commands.register("bmf.tools.treecut.native.find-tag", "Find live UObject candidates for one treeid ConsoleTag.", function(args)
    local options = parse_command_options(args)
    local positional = type(options._positional) == "table" and options._positional or {}
    return BMF.tools.treeCutNative.findTag({
      tag = options.tag or options.treeid or options.treeId or positional[1] or "",
      limit = option_number(options, "limit", option_number(options, "maxresults", 8)),
      maxScan = option_number(options, "maxscan", option_number(options, "max", 250000)),
    })
  end)

  BMF.commands.register("bmf.bricks.runtime.inspect", "Inspect one explicit runtime brick id for visible/collision state.", function(args)
    local options = parse_command_options(args)
    return BMF.bricks.inspectRuntimeState(options)
  end)

  BMF.commands.register("bmf.bricks.runtime.set", "Set one explicit runtime brick id visible/collision state.", function(args)
    local options = parse_command_options(args)
    return BMF.bricks.setRuntimeState(options)
  end)

  BMF.commands.register("bmf.bricks.runtime.status", "Show last runtime brick-state operation.", function()
    return BMF.bricks.runtimeStateStatus()
  end)

  BMF.commands.register("bmf.tools.treecut.physical.inspect", "Inspect one explicit runtime brick id for visible/collision state.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutNative.inspectPhysical(options)
  end)

  BMF.commands.register("bmf.tools.treecut.physical.set", "Set one explicit runtime brick id visible/collision state.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutNative.setPhysical(options)
  end)

  BMF.commands.register("bmf.tools.treecut.physical.status", "Show last explicit brick physical-state operation.", function()
    return BMF.tools.treeCutNative.physicalStatus()
  end)

  BMF.commands.register("bmf.tools.treecut.native.drain", "Drain native CityRPG tree-cut hit events into the BMF event bus.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutNative.drain({
      limit = option_number(options, "limit", 64),
    })
  end)

  BMF.commands.register("bmf.tools.treecut.probe.start", "Start bounded native tree-cut function attribution counters.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutProbe.start({
      reason = options.reason or "command",
    })
  end)

  BMF.commands.register("bmf.tools.treecut.probe.stop", "Stop native tree-cut function attribution counters.", function(args)
    local options = parse_command_options(args)
    return BMF.tools.treeCutProbe.stop({
      reason = options.reason or "command",
    })
  end)

  BMF.commands.register("bmf.tools.treecut.probe.status", "Show native tree-cut function attribution counters.", function()
    return BMF.tools.treeCutProbe.status()
  end)

  BMF.commands.register("bmf.unload", "Unload BMF plugins from memory.", function()
    local unloaded = BMF.unloadPlugins("command")
    return result(unloaded.ok, unloaded.code, unloaded.message, {
      lines = {
        "plugins_unloaded=" .. tostring(unloaded.data.plugins_unloaded or 0),
        "unload_errors=" .. tostring(unloaded.data.unload_errors or 0),
      },
    })
  end)

  BMF.commands.register("bmf.load", "Load BMF plugins from disk.", function()
    local loaded = BMF.loadPlugins()
    return result(loaded.ok, loaded.code, "Plugins loaded", {
      lines = {
        "plugins_loaded=" .. tostring(loaded.data.plugins_loaded or 0),
        "plugin_errors=" .. tostring(loaded.data.plugin_errors or 0),
      },
    })
  end)

  BMF.commands.register("bmf.reload", "Reload BMF plugins from disk.", function()
    state.plugin_errors = {}
    local unloaded = BMF.unloadPlugins("reload")
    state.plugin_watchdog = {}
    local reload = BMF.loadPlugins()
    return result(true, "OK", "Plugins reloaded", {
      lines = {
        "plugins_unloaded=" .. tostring(unloaded.data.plugins_unloaded),
        "unload_errors=" .. tostring(unloaded.data.unload_errors),
        "plugins_loaded=" .. tostring(reload.data.plugins_loaded),
        "plugin_errors=" .. tostring(reload.data.plugin_errors),
      },
    })
  end)

  BMF.commands.register("bmf.chat.broadcast", "Broadcast a server chat message.", function(args)
    local raw = trim_string(args or "")
    local options = parse_command_options(raw)
    local message = raw
    local prefixed = raw:match("^message=(.*)$")
    if prefixed ~= nil then
      message = percent_decode(trim_string(prefixed))
    elseif options.message ~= nil then
      message = percent_decode(options.message)
    end

    local broadcast = BMF.chat.broadcast(message)
    local lines = {
      "message=" .. tostring(message),
    }
    if broadcast.data then
      lines[#lines + 1] = "executor=" .. tostring(broadcast.data.executor or "")
      lines[#lines + 1] = "command=" .. tostring(broadcast.data.command or "")
      lines[#lines + 1] = "delivered=" .. tostring(broadcast.data.delivered or false)
      lines[#lines + 1] = "delivered_count=" .. tostring(broadcast.data.deliveredCount or 0)
      lines[#lines + 1] = "attempted_count=" .. tostring(broadcast.data.attemptedCount or 0)
      lines[#lines + 1] = "delivery_mode=" .. tostring(broadcast.data.deliveryMode or "")
      lines[#lines + 1] = "validation=" .. tostring(broadcast.data.validation or "")
    end
    broadcast.data.lines = lines
    return broadcast
  end)

  BMF.commands.register("bmf.chat.whisper", "Send a private chat message to a player.", function(args)
    local text = tostring(args or "")
    local options = parse_command_options(text)
    local target = options.target or options.player or options.uuid or text:match("target=([^%s]+)") or text:match("player=([^%s]+)") or text:match("uuid=([^%s]+)")
    if target ~= nil then
      target = percent_decode(target)
    end
    local message = text:match("message=(.*)$") or options.message or ""
    message = percent_decode(message)
    local whispered = BMF.chat.whisper(target, trim_string(message))
    local lines = {
      "target=" .. tostring(target or ""),
      "message=" .. tostring(trim_string(message)),
      "code=" .. tostring(whispered.code or ""),
    }
    if whispered.data then
      lines[#lines + 1] = "delivered=" .. tostring(whispered.data.delivered or false)
      lines[#lines + 1] = "delivered_count=" .. tostring(whispered.data.deliveredCount or 0)
      lines[#lines + 1] = "attempted_count=" .. tostring(whispered.data.attemptedCount or 0)
      lines[#lines + 1] = "delivery_mode=" .. tostring(whispered.data.deliveryMode or "")
      lines[#lines + 1] = "validation=" .. tostring(whispered.data.validation or "")
      if whispered.data.adapter ~= nil then
        lines[#lines + 1] = "adapter=" .. tostring(whispered.data.adapter or "")
      end
      if whispered.data.validationRequired ~= nil then
        lines[#lines + 1] = "validation_required=" .. tostring(whispered.data.validationRequired or "")
      end
    end
    whispered.data = whispered.data or {}
    whispered.data.lines = lines
    return whispered
  end)

  BMF.commands.register("bmf.chat.statusmessage", "Send a private status message to a player.", function(args)
    local text = tostring(args or "")
    local options = parse_command_options(text)
    local target = options.target or options.player or options.uuid or text:match("target=([^%s]+)") or text:match("player=([^%s]+)") or text:match("uuid=([^%s]+)")
    if target ~= nil then
      target = percent_decode(target)
    end
    local message = text:match("message=(.*)$") or options.message or ""
    message = percent_decode(message)
    local sent = BMF.chat.statusMessage(target, trim_string(message))
    local lines = {
      "target=" .. tostring(target or ""),
      "message=" .. tostring(trim_string(message)),
      "code=" .. tostring(sent.code or ""),
    }
    if sent.data then
      lines[#lines + 1] = "delivered=" .. tostring(sent.data.delivered or false)
      lines[#lines + 1] = "delivered_count=" .. tostring(sent.data.deliveredCount or 0)
      lines[#lines + 1] = "attempted_count=" .. tostring(sent.data.attemptedCount or 0)
      lines[#lines + 1] = "delivery_mode=" .. tostring(sent.data.deliveryMode or "")
      lines[#lines + 1] = "validation=" .. tostring(sent.data.validation or "")
      if sent.data.adapter ~= nil then
        lines[#lines + 1] = "adapter=" .. tostring(sent.data.adapter or "")
      end
      if sent.data.validationRequired ~= nil then
        lines[#lines + 1] = "validation_required=" .. tostring(sent.data.validationRequired or "")
      end
    end
    sent.data = sent.data or {}
    sent.data.lines = lines
    return sent
  end)

  BMF.commands.register("bmf.players.list", "List known BMF player records.", function(args)
    local options = parse_command_options(args)
    local listed = BMF.players.list({
      liveControllers = option_boolean(options, "livecontrollers", false) or option_boolean(options, "includelivecontrollers", false),
    })
    local players = {}
    if listed.data and type(listed.data.players) == "table" then
      players = listed.data.players
    end

    local lines = {
      "players_count=" .. tostring(#players),
      "known_players_count=" .. tostring((listed.data and listed.data.knownPlayerCount) or #players),
      "live_controllers_count=" .. tostring((listed.data and listed.data.liveControllerCount) or 0),
      "live_controllers_included=" .. tostring((listed.data and listed.data.liveControllersIncluded) == true),
      "adapter=" .. tostring((listed.data and listed.data.adapter) or "headless-empty"),
      "cache_path=" .. tostring((listed.data and listed.data.cachePath) or PLAYER_CACHE_PATH),
    }
    if listed.data and listed.data.updatedAt then
      lines[#lines + 1] = "updated_at=" .. tostring(listed.data.updatedAt or "")
    end
    if listed.data and listed.data.cacheError and tostring(listed.data.cacheError) ~= "" then
      lines[#lines + 1] = "cache_error=" .. tostring(listed.data.cacheError)
    end
    if listed.data and type(listed.data.liveControllers) == "table" then
      for index, controller in ipairs(listed.data.liveControllers) do
        lines[#lines + 1] =
          "live_controller_" .. tostring(index) ..
          "=label=" .. tostring(controller.label or "") ..
          "|controller=" .. tostring(controller.controllerPath or "") ..
          "|controller_name=" .. tostring(controller.controllerName or "") ..
          "|controller_full_name=" .. tostring(controller.controllerFullName or "") ..
          "|player_state=" .. tostring(controller.playerStatePath or "") ..
          "|name=" .. tostring(controller.name or controller.userName or controller.displayName or "") ..
          "|source=" .. tostring(controller.source or "")
      end
    end
    for index, player in ipairs(players) do
      lines[#lines + 1] =
        "player_" .. tostring(index) ..
        "=" .. tostring(player.uuid or player.id or "") ..
        "|username=" .. tostring(player.username or "") ..
        "|display_name=" .. tostring(player.displayName or "") ..
        "|controller=" .. tostring(player.controllerPath or "")
    end
    listed.data.lines = lines
    return listed
  end)

  BMF.commands.register("bmf.players.positions", "Read live player pawn positions.", function(args)
    local options = parse_command_options(args)
    local positional = type(options._positional) == "table" and options._positional or {}
    local player_query = options.player or options.query or options.name or positional[1] or ""
    local snapshot = BMF.players.positions({
      player = player_query,
      limit = option_number(options, "limit", 32),
      nativeController = option_boolean(options, "nativecontroller", true),
      nativeCache = option_boolean(options, "nativecache", true),
      unsafe = option_boolean(options, "unsafe", false),
      allowLivePawnRead = option_boolean(options, "allowlivepawnread", false),
      liveController = option_boolean(options, "livecontroller", false),
      callMethods = option_boolean(options, "methods", false) or option_boolean(options, "callmethods", false),
      includeMissing = option_boolean(options, "includemissing", false),
      fallbackFindAll = option_boolean(options, "fallbackfindall", true),
    })
    local data = snapshot.data or {}
    data.lines = data.lines or {
      "source=bmf.players.positions",
      "query=" .. tostring(player_query or ""),
      "players=0",
      "returned=0",
    }
    snapshot.data = data
    return snapshot
  end)

  BMF.commands.register("bmf.players.sync", "Sync safe external player identity records into BMF.", function(args)
    local text = tostring(args or "")
    local options = parse_command_options(args)
    local raw = ""
    local source = tostring(options.source or "command")
    local adapter = tostring(options.adapter or "external-cache")

    if options.file and tostring(options.file) ~= "" then
      raw = read_file(tostring(options.file)) or ""
      source = "file:" .. tostring(options.file)
    else
      raw = text:match("json=(.*)$") or text:match("players=(.*)$") or ""
    end

    if trim_string(raw) == "" then
      local response = result(false, "INVALID_OPTIONS", "players JSON or file is required", {
        lines = {
          "source=" .. source,
          "adapter=" .. adapter,
          "cache_path=" .. PLAYER_CACHE_PATH,
        },
      })
      return response
    end

    local decoded, err = json_decode(raw)
    if err ~= nil then
      local response = result(false, "JSON_PARSE_FAILED", "player sync JSON could not be parsed", {
        error = err,
        lines = {
          "source=" .. source,
          "adapter=" .. adapter,
          "error=" .. tostring(err),
          "cache_path=" .. PLAYER_CACHE_PATH,
        },
      })
      return response
    end

    local records = decoded
    if type(decoded) == "table" and type(decoded.players) == "table" then
      records = decoded.players
      source = tostring(decoded.source or source)
      adapter = tostring(decoded.adapter or adapter)
    end

    local synced = BMF.players.sync(records, {
      source = source,
      adapter = adapter,
    })
    local lines = {
      "source=" .. source,
      "adapter=" .. adapter,
      "players_count=" .. tostring((synced.data and synced.data.playerCount) or 0),
      "invalid_count=" .. tostring((synced.data and synced.data.invalidCount) or 0),
      "cache_path=" .. tostring((synced.data and synced.data.cachePath) or PLAYER_CACHE_PATH),
    }
    if synced.data and synced.data.updatedAt then
      lines[#lines + 1] = "updated_at=" .. tostring(synced.data.updatedAt or "")
    end
    synced.data = synced.data or {}
    synced.data.lines = lines
    return synced
  end)

  BMF.commands.register("bmf.interact.console", "Forward an Interactable Print-to-Console event into BMF.", function(args)
    local options = parse_command_options(args)
    local forwarded = BMF.interact.handleConsoleMessage({
      source = percent_decode(options.source or options.adapter or "command"),
      message = percent_decode(options.message or options.tag or options.consoletag or options.value or ""),
      player = {
        uuid = tostring(options.player or options.uuid or options.id or options.playerid or ""),
        username = percent_decode(options.username or options.name or options.playername or ""),
        displayName = percent_decode(options.displayname or options.display or options.name or ""),
        controller = percent_decode(options.controller or ""),
        pawn = percent_decode(options.pawn or ""),
      },
      brickName = percent_decode(options.brick or options.brickname or ""),
      brickAsset = percent_decode(options.asset or options.brickasset or ""),
      x = options.x,
      y = options.y,
      z = options.z,
    })
    forwarded.data = forwarded.data or {}
    forwarded.data.lines = forwarded.data.lines or {}
    forwarded.data.lines[#forwarded.data.lines + 1] = "code=" .. tostring(forwarded.code or "")
    forwarded.data.lines[#forwarded.data.lines + 1] = "ok=" .. tostring(forwarded.ok == true)
    return forwarded
  end)

  BMF.commands.register("bmf.players.find", "Find a known BMF player record.", function(args)
    local query = tostring(args or ""):match("query=(.*)$") or tostring(args or "")
    local found = BMF.players.find(trim_string(query))
    local lines = {
      "query=" .. tostring(trim_string(query)),
      "code=" .. tostring(found.code or ""),
    }
    if found.data then
      lines[#lines + 1] = "adapter=" .. tostring(found.data.adapter or "")
      if found.data.player then
        lines[#lines + 1] = "player_uuid=" .. tostring(found.data.player.uuid or "")
        lines[#lines + 1] = "display_name=" .. tostring(found.data.player.displayName or "")
        lines[#lines + 1] = "match=" .. tostring(found.data.match or "")
      end
    end
    found.data = found.data or {}
    found.data.lines = lines
    return found
  end)

  BMF.commands.register("bmf.players.getname", "Resolve known BMF player names.", function(args)
    local query = tostring(args or ""):match("query=(.*)$") or tostring(args or "")
    local named = BMF.players.getName(trim_string(query))
    local lines = {
      "query=" .. tostring(trim_string(query)),
      "code=" .. tostring(named.code or ""),
    }
    if named.data then
      lines[#lines + 1] = "adapter=" .. tostring(named.data.adapter or "")
      lines[#lines + 1] = "uuid=" .. tostring(named.data.uuid or "")
      lines[#lines + 1] = "username=" .. tostring(named.data.username or "")
      lines[#lines + 1] = "player_name=" .. tostring(named.data.playerName or "")
      lines[#lines + 1] = "display_name=" .. tostring(named.data.displayName or "")
      lines[#lines + 1] = "original_name=" .. tostring(named.data.originalName or "")
    end
    named.data = named.data or {}
    named.data.lines = lines
    return named
  end)

  BMF.commands.register("bmf.players.summary", "Resolve and optionally whisper a player identity summary.", function(args)
    local options = parse_command_options(args)
    local target = trim_string(options.target or options.query or table.concat(options._positional or {}, " "))
    local whisper = tostring(options.whisper or options.tell or ""):lower()
    local should_whisper = whisper == "true" or whisper == "1" or whisper == "yes"
    local summarized = should_whisper and BMF.players.whisperSummary(target) or BMF.players.summary(target)
    local data = summarized.data or {}
    local summary_data = data.summary or data
    local player = summary_data.player or data.player or {}

    local lines = {
      "target=" .. target,
      "code=" .. tostring(summarized.code or ""),
      "player_uuid=" .. tostring(player.uuid or player.id or ""),
      "username=" .. tostring(player.username or ""),
      "player_name=" .. tostring(player.playerName or ""),
      "display_name=" .. tostring(player.displayName or ""),
      "original_name=" .. tostring(player.originalName or ""),
      "known_players_count=" .. tostring(summary_data.knownPlayerCount or summary_data.playerCount or 0),
      "live_controllers_count=" .. tostring(summary_data.liveControllerCount or 0),
      "adapter=" .. tostring(summary_data.adapter or data.adapter or ""),
    }
    if data.message or summary_data.message then
      lines[#lines + 1] = "message=" .. tostring(data.message or summary_data.message or "")
    end
    if should_whisper then
      lines[#lines + 1] = "whispered=" .. tostring(data.delivered == true)
      lines[#lines + 1] = "whisper_code=" .. tostring(data.whisperCode or "")
      lines[#lines + 1] = "delivered_count=" .. tostring(data.deliveredCount or 0)
      lines[#lines + 1] = "delivery_mode=" .. tostring(data.deliveryMode or "")
    end
    summarized.data = summarized.data or {}
    summarized.data.lines = lines
    return summarized
  end)

  BMF.commands.register("bmf.permissions.role-assignments", "Show configured player role assignments.", function(args)
    local options = parse_command_options(args)
    local loaded = BMF.permissions.loadRoleAssignments({
      path = options.path or options.assignments or options.file,
      savedDir = options.saveddir or options.saved,
    })
    local lines = {
      "code=" .. tostring(loaded.code or ""),
      "ok=" .. tostring(loaded.ok == true),
    }
    if loaded.data and type(loaded.data.lines) == "table" then
      for _, line in ipairs(loaded.data.lines) do
        lines[#lines + 1] = line
      end
    end
    if loaded.data and type(loaded.data.players) == "table" then
      local limit = tonumber(options.limit or 10) or 10
      if limit < 0 then
        limit = 0
      end
      for index, player in ipairs(loaded.data.players) do
        if index > limit then
          break
        end
        lines[#lines + 1] = "player_" .. tostring(index) .. "=" ..
          tostring(player.uuid or "") .. "|roles=" .. table.concat(player.roles or {}, "|")
      end
    end
    loaded.data = loaded.data or {}
    loaded.data.lines = lines
    return loaded
  end)

  BMF.commands.register("bmf.permissions.enforce-nospawnitem", "Patch RoleSetup2 so applicator remains allowed while spawn items are forbidden.", function(args)
    local options = parse_command_options(args)
    local enforced = BMF.permissions.enforceNoSpawnItemApplicator({
      path = options.path or options.rolesetup or options.file,
      savedDir = options.saveddir or options.saved,
      dryRun = options.dryrun or options["dry-run"],
      backup = options.backup,
    })
    local lines = {
      "code=" .. tostring(enforced.code or ""),
      "ok=" .. tostring(enforced.ok == true),
    }
    if enforced.data and type(enforced.data.lines) == "table" then
      for _, line in ipairs(enforced.data.lines) do
        lines[#lines + 1] = line
      end
    end
    enforced.data = enforced.data or {}
    enforced.data.lines = lines
    return enforced
  end)

  BMF.commands.register("bmf.minigames.list", "List minigames through the server console when unsafe opt-in is enabled.", function()
    local listed = BMF.minigames.list()
    local lines = {}
    if listed.data then
      lines[#lines + 1] = "code=" .. tostring(listed.code or "")
      lines[#lines + 1] = "command=" .. tostring(listed.data.command or "")
      lines[#lines + 1] = "executor=" .. tostring(listed.data.executor or "")
      if listed.data.allowUnsafeMinigameConsoleCommands ~= nil then
        lines[#lines + 1] = "allowUnsafeMinigameConsoleCommands=" .. tostring(listed.data.allowUnsafeMinigameConsoleCommands)
      end
      if listed.data.output and tostring(listed.data.output) ~= "" then
        lines[#lines + 1] = "output=" .. tostring(listed.data.output)
      end
    end
    listed.data.lines = lines
    return listed
  end)

  local function minigame_command_lines(response, action, index, preset, owner)
    local lines = {
      "action=" .. tostring(action or ""),
    }
    if index ~= nil then
      lines[#lines + 1] = "index=" .. tostring(index)
    end
    if preset ~= nil then
      lines[#lines + 1] = "preset=" .. tostring(preset)
    end
    if owner ~= nil then
      lines[#lines + 1] = "owner=" .. tostring(owner)
    end
    lines[#lines + 1] = "code=" .. tostring(response.code or "")
    if response.data then
      lines[#lines + 1] = "command=" .. tostring(response.data.command or "")
      lines[#lines + 1] = "executor=" .. tostring(response.data.executor or "")
      if response.data.allowUnsafeMinigameConsoleCommands ~= nil then
        lines[#lines + 1] = "allowUnsafeMinigameConsoleCommands=" .. tostring(response.data.allowUnsafeMinigameConsoleCommands)
      end
      if response.data.output and tostring(response.data.output) ~= "" then
        lines[#lines + 1] = "output=" .. tostring(response.data.output)
      end
    end
    response.data = response.data or {}
    response.data.lines = lines
    return response
  end

  BMF.commands.register("bmf.minigames.loadpreset", "Load a minigame preset through the server console when unsafe opt-in is enabled.", function(args)
    local options = parse_command_options(args)
    local preset = options.name or options.preset
    if (not preset or preset == "") and options._positional[1] then
      preset = options._positional[1]
    end
    local owner = options.owner or options.player or ""
    local loaded = BMF.minigames.loadPreset(preset, owner)
    return minigame_command_lines(loaded, "loadPreset", nil, preset, owner)
  end)

  BMF.commands.register("bmf.minigames.savepreset", "Save a minigame preset through the server console when unsafe opt-in is enabled.", function(args)
    local options = parse_command_options(args)
    local index = options.index or options.minigame
    if (index == nil or index == "") and options._positional[1] then
      index = options._positional[1]
    end
    local preset = options.name or options.preset
    if (not preset or preset == "") and options._positional[2] then
      preset = options._positional[2]
    end
    local saved = BMF.minigames.savePreset(index, preset)
    return minigame_command_lines(saved, "savePreset", index, preset, nil)
  end)

  BMF.commands.register("bmf.minigames.reset", "Reset a minigame through the server console when unsafe opt-in is enabled.", function(args)
    local options = parse_command_options(args)
    local index = options.index or options.minigame
    if (index == nil or index == "") and options._positional[1] then
      index = options._positional[1]
    end
    local reset = BMF.minigames.reset(index)
    return minigame_command_lines(reset, "reset", index, nil, nil)
  end)

  BMF.commands.register("bmf.minigames.nextround", "Advance a minigame to the next round through the server console when unsafe opt-in is enabled.", function(args)
    local options = parse_command_options(args)
    local index = options.index or options.minigame
    if (index == nil or index == "") and options._positional[1] then
      index = options._positional[1]
    end
    local advanced = BMF.minigames.nextRound(index)
    return minigame_command_lines(advanced, "nextRound", index, nil, nil)
  end)

  BMF.commands.register("bmf.minigames.delete", "Delete a minigame through the server console when unsafe opt-in is enabled.", function(args)
    local options = parse_command_options(args)
    local index = options.index or options.minigame
    if (index == nil or index == "") and options._positional[1] then
      index = options._positional[1]
    end
    local deleted = BMF.minigames.delete(index)
    return minigame_command_lines(deleted, "delete", index, nil, nil)
  end)

  local function minigame_definition_options_from_command(options)
    local positional_name = options._positional and options._positional[1] or ""
    return {
      key = percent_decode(options.key or ""),
      name = percent_decode(options.name or options.minigame or positional_name or ""),
      index = options.index,
      ruleset = percent_decode(options.ruleset or options.id or ""),
      owner = percent_decode(options.owner or ""),
      mode = percent_decode(options.mode or options.type or ""),
      teams = percent_decode(options.teams or options.teamnames or ""),
      persistent = options.persistent,
      ownerOnly = options.owneronly or options.ownerOnly,
      includedBrickMode = options.includedbrickmode or options.brickmode,
      includedBricks = percent_decode(options.includedbricks or options.bricks or ""),
      maxPlayers = options.maxplayers,
      source = percent_decode(options.source or "bmf-command"),
      limit = options.limit,
      confirm = options.confirm or options.token,
    }
  end

  local function minigame_definition_response_lines(response, data, definition)
    definition = definition or data.definition or {}
    local lines = {
      "code=" .. tostring(response.code or ""),
      "key=" .. tostring(data.key or definition.key or ""),
      "name=" .. tostring(definition.name or ""),
      "index=" .. tostring(definition.index or ""),
      "ruleset=" .. tostring(definition.ruleset or ""),
      "teams=" .. tostring(definition.teamCount or #(definition.teams or {})),
      "persistent=" .. tostring(definition.persistent == true),
      "owner_only=" .. tostring(definition.ownerOnly == true),
      "included_brick_mode=" .. tostring(definition.includedBrickMode or ""),
      "live_enforcement=" .. tostring(definition.liveEnforcement or ""),
    }
    return lines
  end

  BMF.commands.register("bmf.minigames.definitions.status", "Show BMF-owned minigame definition registry status.", function()
    local status = BMF.minigames.definitionStatus()
    local data = status.data or {}
    local counts = data.counts or {}
    data.lines = {
      "code=" .. tostring(status.code or ""),
      "path=" .. tostring(data.path or ""),
      "definitions=" .. tostring(counts.definitions or 0),
      "teams=" .. tostring(counts.teams or 0),
      "total_updates=" .. tostring(data.totalUpdates or 0),
      "last_error=" .. tostring(data.lastError or ""),
    }
    status.data = data
    return status
  end)

  BMF.commands.register("bmf.minigames.definitions.set", "Upsert a BMF-owned minigame definition without mutating Brickadia.", function(args)
    local options = parse_command_options(args)
    local defined = BMF.minigames.define(minigame_definition_options_from_command(options))
    local data = defined.data or {}
    local lines = minigame_definition_response_lines(defined, data, data.definition or {})
    lines[#lines + 1] = "updated=" .. tostring(data.updated == true)
    lines[#lines + 1] = "definition_json=" .. json_encode(data)
    data.lines = lines
    defined.data = data
    return defined
  end)

  BMF.commands.register("bmf.minigames.definitions.list", "List BMF-owned minigame definitions.", function(args)
    local options = parse_command_options(args)
    local listed = BMF.minigames.definitions(minigame_definition_options_from_command(options))
    local data = listed.data or {}
    local definitions = data.definitions or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(listed.code or ""),
      "definitions=" .. tostring((data.counts and data.counts.definitions) or data.total or 0),
      "returned=" .. tostring(data.count or #definitions),
    }
    for index, definition in ipairs(definitions) do
      if index > 10 then
        break
      end
      lines[#lines + 1] =
        "definition_" .. tostring(index) ..
        "=" .. tostring(definition.key or "") ..
        "|name=" .. tostring(definition.name or "") ..
        "|index=" .. tostring(definition.index or "") ..
        "|teams=" .. tostring(definition.teamCount or #(definition.teams or {})) ..
        "|persistent=" .. tostring(definition.persistent == true)
    end
    lines[#lines + 1] = "definitions_json=" .. json_encode(json_payload)
    data.lines = lines
    listed.data = data
    return listed
  end)

  BMF.commands.register("bmf.minigames.definitions.get", "Find one BMF-owned minigame definition.", function(args)
    local options = parse_command_options(args)
    local found = BMF.minigames.definition(minigame_definition_options_from_command(options))
    local data = found.data or {}
    local lines = minigame_definition_response_lines(found, data, data.definition or {})
    lines[#lines + 1] = "definition_json=" .. json_encode(data)
    data.lines = lines
    found.data = data
    return found
  end)

  BMF.commands.register("bmf.minigames.definitions.delete", "Delete one BMF-owned minigame definition after confirmation.", function(args)
    local options = parse_command_options(args)
    local query = minigame_definition_options_from_command(options)
    local deleted = BMF.minigames.deleteDefinition(query, query.confirm)
    local data = deleted.data or {}
    if deleted.ok then
      local lines = minigame_definition_response_lines(deleted, data, data.definition or {})
      lines[#lines + 1] = "deleted=" .. tostring(data.deleted == true)
      lines[#lines + 1] = "definition_json=" .. json_encode(data)
      data.lines = lines
    else
      data.lines = {
        "code=" .. tostring(deleted.code or ""),
        "confirm_required=DELETE_MINIGAME_DEFINITION",
        "deleted=false",
      }
    end
    deleted.data = data
    return deleted
  end)

  BMF.commands.register("bmf.minigames.definitions.reconcile", "Compare BMF-owned minigame definitions with observed BMF minigame data.", function(args)
    local options = parse_command_options(args)
    local reconciled = BMF.minigames.reconcileDefinitions(minigame_definition_options_from_command(options))
    local data = reconciled.data or {}
    local summary = data.summary or {}
    local items = data.items or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(reconciled.code or ""),
      "definitions=" .. tostring(summary.definitions or data.count or #items),
      "checked=" .. tostring(summary.checked or #items),
      "present=" .. tostring(summary.present or 0),
      "missing=" .. tostring(summary.missing or 0),
      "team_mismatches=" .. tostring(summary.teamMismatches or 0),
      "data_minigames=" .. tostring((data.dataCounts and data.dataCounts.minigames) or 0),
      "data_teams=" .. tostring((data.dataCounts and data.dataCounts.teams) or 0),
    }
    for index, item in ipairs(items) do
      if index > 10 then
        break
      end
      lines[#lines + 1] =
        "definition_" .. tostring(index) ..
        "=" .. tostring(item.key or "") ..
        "|status=" .. tostring(item.status or "") ..
        "|observed=" .. tostring(item.observedKey or "") ..
        "|expected_teams=" .. tostring((item.counts and item.counts.expectedTeams) or 0) ..
        "|observed_teams=" .. tostring((item.counts and item.counts.observedTeams) or 0) ..
        "|members=" .. tostring((item.counts and item.counts.members) or 0) ..
        "|missing_teams=" .. table.concat(item.missingTeams or {}, ",")
    end
    lines[#lines + 1] = "reconcile_json=" .. json_encode(json_payload)
    data.lines = lines
    reconciled.data = data
    return reconciled
  end)

  local function parse_number_list(value)
    local text = trim_string(value or "")
    local numbers = {}
    if text == "" then
      return numbers
    end
    for item in text:gmatch("[^,|]+") do
      numbers[#numbers + 1] = finite_number(item, 0)
    end
    return numbers
  end

  local function minigame_event_payload_from_options(options)
    if options.payload and trim_string(options.payload) ~= "" then
      local decoded, err = json_decode(percent_decode(options.payload))
      if err then
        return nil, "payload JSON could not be parsed: " .. tostring(err)
      end
      if type(decoded) ~= "table" then
        return nil, "payload JSON must decode to an object"
      end
      return decoded, nil
    end

    local payload = {}
    local player_name = percent_decode(options.player or options.playername or options.name or "")
    local player_id = percent_decode(options.playerid or options.uuid or options.id or "")
    if player_name ~= "" or player_id ~= "" then
      payload.player = {
        name = player_name,
        id = player_id,
      }
    end

    local minigame_name = percent_decode(options.minigame or options.minigamename or "")
    local ruleset = percent_decode(options.ruleset or "")
    local index = options.index
    if minigame_name ~= "" or ruleset ~= "" or index ~= nil then
      payload.minigame = {
        name = minigame_name,
        ruleset = ruleset,
        index = tonumber(index) or 0,
      }
    end

    local leaderboard = parse_number_list(options.leaderboard or "")
    if #leaderboard > 0 then
      payload.leaderboard = leaderboard
    end
    local old_leaderboard = parse_number_list(options.oldleaderboard or options.old or "")
    if #old_leaderboard > 0 then
      payload.oldLeaderboard = old_leaderboard
    end
    payload.source = percent_decode(options.source or "bmf-command")
    return payload, nil
  end

  local function minigame_data_query_from_options(options, mode)
    local query = {}
    if options.key and trim_string(options.key) ~= "" then
      query.key = percent_decode(options.key)
    end
    if options.minigamekey and trim_string(options.minigamekey) ~= "" then
      query.minigameKey = percent_decode(options.minigamekey)
    end
    if options.ruleset and trim_string(options.ruleset) ~= "" then
      query.ruleset = percent_decode(options.ruleset)
    end
    if options.minigame and trim_string(options.minigame) ~= "" then
      query.minigame = percent_decode(options.minigame)
    end
    if options.name and trim_string(options.name) ~= "" then
      query.name = percent_decode(options.name)
    end
    if options.index and trim_string(options.index) ~= "" then
      query.index = options.index
    end
    if options.id and trim_string(options.id) ~= "" then
      query.id = percent_decode(options.id)
    end
    if options.uuid and trim_string(options.uuid) ~= "" then
      query.uuid = percent_decode(options.uuid)
    end
    if options.playerid and trim_string(options.playerid) ~= "" then
      query.playerid = percent_decode(options.playerid)
    end
    if options.player and trim_string(options.player) ~= "" then
      query.player = percent_decode(options.player)
    end
    if options.state and trim_string(options.state) ~= "" then
      query.state = percent_decode(options.state)
    end
    if options.controller and trim_string(options.controller) ~= "" then
      query.controller = percent_decode(options.controller)
    end
    if options.displayname and trim_string(options.displayname) ~= "" then
      query.displayName = percent_decode(options.displayname)
    end
    if options.username and trim_string(options.username) ~= "" then
      query.username = percent_decode(options.username)
    end
    if options.team and trim_string(options.team) ~= "" then
      query.team = percent_decode(options.team)
    end
    if options.teamkey and trim_string(options.teamkey) ~= "" then
      query.teamKey = percent_decode(options.teamkey)
    end
    if options.limit and trim_string(options.limit) ~= "" then
      query.limit = options.limit
    end
    if next(query) == nil and options._positional[1] then
      if mode == "player" then
        query.player = percent_decode(options._positional[1])
      elseif mode == "team" then
        query.team = percent_decode(options._positional[1])
      else
        query.key = percent_decode(options._positional[1])
      end
    end
    return query
  end

  local function minigame_snapshot_payload_from_options(options)
    local raw = ""
    local source = percent_decode(options.source or "bmf-command")
    if options.file and trim_string(options.file) ~= "" then
      local file_path = percent_decode(options.file)
      raw = read_file(file_path) or ""
      source = "file:" .. file_path
    elseif options.payload and trim_string(options.payload) ~= "" then
      raw = percent_decode(options.payload)
    elseif options.json and trim_string(options.json) ~= "" then
      raw = percent_decode(options.json)
    elseif options.snapshot and trim_string(options.snapshot) ~= "" then
      raw = percent_decode(options.snapshot)
    end

    if trim_string(raw) ~= "" then
      local decoded, err = json_decode(raw)
      if err then
        return nil, "snapshot JSON could not be parsed: " .. tostring(err)
      end
      if type(decoded) ~= "table" then
        return nil, "snapshot JSON must decode to an object"
      end
      if trim_string(decoded.source or "") == "" then
        decoded.source = source
      end
      return decoded, nil
    end

    local positional_name = options._positional and options._positional[1] or ""
    local name = percent_decode(options.name or options.minigame or positional_name or "")
    local ruleset = percent_decode(options.ruleset or options.id or "")
    if name == "" and ruleset == "" then
      return nil, "snapshot payload, file, name, or ruleset is required"
    end

    local minigame = {
      name = name,
      index = tonumber(options.index) or 0,
      teams = {},
    }
    if ruleset ~= "" then
      minigame.ruleset = ruleset
    end
    for _, team in ipairs(minigame_definition_text_list(percent_decode(options.teams or options.teamnames or ""))) do
      local team_record = {}
      if type(team) == "table" then
        team_record = copy_table(team)
        team_record.name = trim_string(team_record.name or team_record.team or team_record.id or team_record.key or "")
      else
        team_record.name = trim_string(team)
      end
      if team_record.name ~= "" then
        team_record.members = type(team_record.members) == "table" and team_record.members or {}
        minigame.teams[#minigame.teams + 1] = team_record
      end
    end

    return {
      source = source,
      minigames = { minigame },
    }, nil
  end

  BMF.commands.register("bmf.minigames.events.status", "Show BMF minigame event relay status.", function()
    local status = BMF.minigames.eventStatus()
    local data = status.data or {}
    local lines = {
      "total=" .. tostring(data.total or 0),
      "recent_count=" .. tostring(data.recentCount or 0),
      "event_log_path=" .. tostring(data.eventLogPath or ""),
    }
    local names = data.eventNames or {}
    for _, name in ipairs(names) do
      local count = (data.byEvent and data.byEvent[name]) or 0
      lines[#lines + 1] = tostring(name) .. "=" .. tostring(count)
    end
    if data.last then
      lines[#lines + 1] = "last_event=" .. tostring(data.last.event or "")
      lines[#lines + 1] = "last_emitted_at=" .. tostring(data.last.emittedAt or "")
    end
    status.data.lines = lines
    return status
  end)

  BMF.commands.register("bmf.minigames.events.recent", "Show recent BMF minigame events.", function(args)
    local options = parse_command_options(args)
    local recent = BMF.minigames.recentEvents(options)
    local data = recent.data or {}
    local events = data.events or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(recent.code or ""),
      "total=" .. tostring(data.total or 0),
      "returned=" .. tostring(data.count or 0),
      "limit=" .. tostring(data.limit or option_number(options, "limit", 10)),
    }
    for index, entry in ipairs(events) do
      if index > 10 then
        break
      end
      local payload = type(entry.payload) == "table" and entry.payload or {}
      local player = type(payload.player) == "table" and payload.player or {}
      local minigame = type(payload.minigame) == "table" and payload.minigame or {}
      lines[#lines + 1] =
        "event_" .. tostring(index) ..
        "=" .. tostring(entry.event or "") ..
        "|id=" .. tostring(entry.eventId or "") ..
        "|player=" .. tostring(player.name or player.displayName or player.id or "") ..
        "|minigame=" .. tostring(minigame.name or minigame.minigame or "")
    end
    lines[#lines + 1] = "events_json=" .. json_encode(json_payload)
    data.lines = lines
    recent.data = data
    return recent
  end)

  BMF.commands.register("bmf.minigames.events.canary", "Exercise BMF minigame event subscription metadata.", function(args)
    local options = parse_command_options(args)
    local event = options.event or options.type or options._positional[1] or "join"
    local payload, payload_error = minigame_event_payload_from_options(options)
    if not payload then
      return result(false, "INVALID_EVENT_PAYLOAD", payload_error, {
        lines = {
          "code=INVALID_EVENT_PAYLOAD",
          "error=" .. tostring(payload_error or ""),
        },
      })
    end
    if type(payload.player) ~= "table" then
      payload.player = {
        name = "MinigameApiCanary",
        id = "33333333-3333-4333-8333-333333333333",
      }
    end
    if type(payload.minigame) ~= "table" then
      payload.minigame = {
        name = "CanaryArena",
        index = 0,
      }
    end
    if not options.source then
      payload.source = "bmf-minigame-event-canary"
    end
    local persist_value = string.lower(trim_string(options.persist or options.keep or ""))
    local cleanup_value = string.lower(trim_string(options.cleanup or ""))
    local restore_data_after_emit = persist_value ~= "true" and persist_value ~= "1" and persist_value ~= "yes" and cleanup_value ~= "false"
    local data_before_emit = restore_data_after_emit and copy_table(state.minigame_data or new_minigame_data_state()) or nil

    local calls = 0
    local handler_legacy = ""
    local handler_event = ""
    local handler_metadata = {}
    local before_count = BMF.minigames.listenerCount(event)
    local handler_id, subscribe_error = BMF.minigames.on(event, function(next_payload, legacy_name, event_name)
      calls = calls + 1
      handler_legacy = tostring(legacy_name or "")
      handler_event = tostring(event_name or "")
      handler_metadata = copy_table((next_payload and next_payload._bmf) or {})
    end)
    if not handler_id then
      return result(false, "SUBSCRIBE_FAILED", subscribe_error or "Could not subscribe to minigame event", {
        lines = {
          "code=SUBSCRIBE_FAILED",
          "error=" .. tostring(subscribe_error or ""),
        },
      })
    end

    local subscribed_count = BMF.minigames.listenerCount(event)
    local emitted = BMF.minigames.emitEvent(event, payload)
    if restore_data_after_emit and data_before_emit then
      state.minigame_data = data_before_emit
      if write_status then
        write_status()
      end
    end
    local removed = BMF.minigames.off(handler_id)
    local after_count = BMF.minigames.listenerCount(event)
    local data = emitted.data or {}
    local metadata = data.payload and data.payload._bmf or {}
    local lines = {
      "code=" .. tostring(emitted.code or ""),
      "event=" .. tostring(data.event or ""),
      "legacy_event=" .. tostring(data.legacyEvent or ""),
      "handler_id=" .. tostring(handler_id or ""),
      "handler_calls=" .. tostring(calls),
      "handler_event=" .. tostring(handler_event),
      "handler_legacy=" .. tostring(handler_legacy),
      "listener_count_before=" .. tostring(before_count),
      "listener_count_subscribed=" .. tostring(subscribed_count),
      "listener_removed=" .. tostring(removed == true),
      "listener_count_after=" .. tostring(after_count),
      "data_restored=" .. tostring(restore_data_after_emit == true),
      "data_persisted=" .. tostring(restore_data_after_emit ~= true),
      "metadata_event_id=" .. tostring(metadata.eventId or metadata.event_id or ""),
      "metadata_legacy_event=" .. tostring(metadata.legacyEvent or metadata.legacy_event or ""),
      "metadata_player_key=" .. tostring(metadata.playerKey or metadata.player_key or ""),
      "metadata_minigame_key=" .. tostring(metadata.minigameKey or metadata.minigame_key or ""),
      "handler_metadata_event_id=" .. tostring(handler_metadata.eventId or handler_metadata.event_id or ""),
      "handler_metadata_player_key=" .. tostring(handler_metadata.playerKey or handler_metadata.player_key or ""),
      "handler_metadata_minigame_key=" .. tostring(handler_metadata.minigameKey or handler_metadata.minigame_key or ""),
    }
    data.lines = lines
    data.handlerCalls = calls
    data.handlerId = handler_id
    data.listenerRemoved = removed == true
    data.listenerCountBefore = before_count
    data.listenerCountSubscribed = subscribed_count
    data.listenerCountAfter = after_count
    data.handlerMetadata = handler_metadata
    data.dataRestored = restore_data_after_emit == true
    data.dataPersisted = restore_data_after_emit ~= true
    emitted.data = data
    return emitted
  end)

  BMF.commands.register("bmf.minigames.data.status", "Show BMF-owned minigame data status.", function()
    return BMF.minigames.dataStatus()
  end)

  BMF.commands.register("bmf.minigames.events.synthetic-flow", "Exercise a full BMF minigame event/data flow and restore data by default.", function(args)
    local options = parse_command_options(args)
    return BMF.minigames.syntheticFlow(options)
  end)

  BMF.commands.register("bmf.minigames.data.snapshot", "Show BMF-owned minigame data snapshot JSON.", function()
    local snapshot = BMF.minigames.data()
    local data = snapshot.data or {}
    local counts = data.counts or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    data.lines = {
      "total_updates=" .. tostring(data.totalUpdates or 0),
      "updated_at=" .. tostring(data.updatedAt or ""),
      "source=" .. tostring(data.source or ""),
      "minigames=" .. tostring(counts.minigames or 0),
      "players=" .. tostring(counts.players or 0),
      "memberships=" .. tostring(counts.memberships or 0),
      "teams=" .. tostring(counts.teams or 0),
      "team_memberships=" .. tostring(counts.teamMemberships or 0),
      "leaderboards=" .. tostring(counts.leaderboards or 0),
      "rounds=" .. tostring(counts.rounds or 0),
      "snapshot_json=" .. json_encode(json_payload),
    }
    snapshot.data = data
    return snapshot
  end)

  BMF.commands.register("bmf.minigames.data.apply-snapshot", "Apply a BMF-owned observed minigame data snapshot without emitting an event.", function(args)
    local options = parse_command_options(args)
    local payload, payload_error = minigame_snapshot_payload_from_options(options)
    if not payload then
      return result(false, "INVALID_MINIGAME_SNAPSHOT", payload_error, {
        lines = {
          "code=INVALID_MINIGAME_SNAPSHOT",
          "error=" .. tostring(payload_error or ""),
        },
      })
    end

    local applied = BMF.minigames.applySnapshot(payload)
    local data = applied.data or {}
    local counts = data.counts or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    data.lines = {
      "code=" .. tostring(applied.code or ""),
      "applied_at=" .. tostring(data.appliedAt or ""),
      "source=" .. tostring(data.source or ""),
      "snapshot_minigames=" .. tostring(data.snapshotMinigames or 0),
      "minigames=" .. tostring(counts.minigames or 0),
      "players=" .. tostring(counts.players or 0),
      "memberships=" .. tostring(counts.memberships or 0),
      "teams=" .. tostring(counts.teams or 0),
      "team_memberships=" .. tostring(counts.teamMemberships or 0),
      "leaderboards=" .. tostring(counts.leaderboards or 0),
      "rounds=" .. tostring(counts.rounds or 0),
      "data_json=" .. json_encode(json_payload),
    }
    applied.data = data
    return applied
  end)

  BMF.commands.register("bmf.minigames.data.list", "List BMF-owned minigame data records.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "minigame")
    local listed = BMF.minigames.dataList(query)
    local data = listed.data or {}
    local items = data.items or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(listed.code or ""),
      "total_updates=" .. tostring(data.totalUpdates or 0),
      "minigames=" .. tostring((data.counts and data.counts.minigames) or data.total or 0),
      "returned=" .. tostring(data.count or #items),
    }
    for index, item in ipairs(items) do
      if index > 10 then
        break
      end
      local minigame = item.minigame or {}
      lines[#lines + 1] =
        "minigame_" .. tostring(index) ..
        "=" .. tostring(item.key or "") ..
        "|name=" .. tostring(minigame.name or minigame.minigame or "") ..
        "|ruleset=" .. tostring(minigame.ruleset or minigame.id or "") ..
        "|members=" .. tostring(item.members or 0) ..
        "|teams=" .. tostring(item.teams or 0)
    end
    lines[#lines + 1] = "list_json=" .. json_encode(json_payload)
    data.lines = lines
    listed.data = data
    return listed
  end)

  BMF.commands.register("bmf.minigames.data.get", "Find one BMF-owned minigame data record.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "minigame")
    local found = BMF.minigames.get(query)
    local data = found.data or {}
    local counts = data.counts or {}
    local minigame = data.minigame or {}
    data.lines = {
      "code=" .. tostring(found.code or ""),
      "key=" .. tostring(data.key or ""),
      "name=" .. tostring(minigame.name or minigame.minigame or ""),
      "ruleset=" .. tostring(minigame.ruleset or minigame.id or ""),
      "index=" .. tostring(minigame.index or ""),
      "members=" .. tostring(counts.members or 0),
      "teams=" .. tostring(counts.teams or 0),
      "team_memberships=" .. tostring(counts.teamMemberships or 0),
      "leaderboards=" .. tostring(counts.leaderboards or 0),
      "matches=" .. tostring(counts.matches or 0),
      "minigame_json=" .. json_encode(data),
    }
    found.data = data
    return found
  end)

  BMF.commands.register("bmf.minigames.data.players", "List known BMF-owned minigame players.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "player")
    local listed = BMF.minigames.players(query)
    local data = listed.data or {}
    local players = data.players or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(listed.code or ""),
      "players=" .. tostring((data.counts and data.counts.players) or data.total or 0),
      "returned=" .. tostring(data.count or #players),
      "minigame_key=" .. tostring(data.minigameKey or ""),
    }
    for index, item in ipairs(players) do
      if index > 10 then
        break
      end
      local player = item.player or {}
      lines[#lines + 1] =
        "player_" .. tostring(index) ..
        "=" .. tostring(item.playerKey or "") ..
        "|name=" .. tostring(player.name or player.displayName or player.username or "") ..
        "|minigame=" .. tostring(item.minigameKey or "") ..
        "|team=" .. tostring(item.teamKey or "")
    end
    lines[#lines + 1] = "players_json=" .. json_encode(json_payload)
    data.lines = lines
    listed.data = data
    return listed
  end)

  BMF.commands.register("bmf.minigames.data.teams", "List known BMF-owned minigame teams.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "team")
    local listed = BMF.minigames.teams(query)
    local data = listed.data or {}
    local teams = data.teams or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(listed.code or ""),
      "teams=" .. tostring((data.counts and data.counts.teams) or data.total or 0),
      "returned=" .. tostring(data.count or #teams),
      "minigame_key=" .. tostring(data.minigameKey or ""),
    }
    for index, team in ipairs(teams) do
      if index > 10 then
        break
      end
      lines[#lines + 1] =
        "team_" .. tostring(index) ..
        "=" .. tostring(team.key or "") ..
        "|name=" .. tostring(team.name or team.team or team.id or "") ..
        "|members=" .. tostring(team.memberCount or 0) ..
        "|minigame=" .. tostring(team.minigameKey or "")
    end
    lines[#lines + 1] = "teams_json=" .. json_encode(json_payload)
    data.lines = lines
    listed.data = data
    return listed
  end)

  BMF.commands.register("bmf.minigames.data.leaderboard", "List known BMF-owned minigame leaderboard rows.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "player")
    local listed = BMF.minigames.leaderboard(query)
    local data = listed.data or {}
    local leaderboards = data.leaderboards or {}
    local json_payload = copy_table(data)
    json_payload.lines = nil
    local lines = {
      "code=" .. tostring(listed.code or ""),
      "leaderboards=" .. tostring((data.counts and data.counts.leaderboards) or data.total or 0),
      "returned=" .. tostring(data.count or #leaderboards),
      "minigame_key=" .. tostring(data.minigameKey or ""),
    }
    for index, item in ipairs(leaderboards) do
      if index > 10 then
        break
      end
      local player = item.player or {}
      lines[#lines + 1] =
        "leaderboard_" .. tostring(index) ..
        "=" .. tostring(item.playerKey or "") ..
        "|name=" .. tostring(player.name or player.displayName or player.username or "") ..
        "|score=" .. tostring(item.score or 0) ..
        "|values=" .. tostring(item.valueCount or 0) ..
        "|minigame=" .. tostring(item.minigameKey or "") ..
        "|team=" .. tostring(item.teamKey or "")
    end
    lines[#lines + 1] = "leaderboards_json=" .. json_encode(json_payload)
    data.lines = lines
    listed.data = data
    return listed
  end)

  BMF.commands.register("bmf.minigames.data.player", "Find one BMF-owned minigame player data record.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "player")
    local found = BMF.minigames.getPlayer(query)
    local data = found.data or {}
    local player = data.player or {}
    local leaderboard = data.leaderboard or {}
    local leaderboard_values = type(leaderboard.leaderboard) == "table" and leaderboard.leaderboard or {}
    data.lines = {
      "code=" .. tostring(found.code or ""),
      "player_key=" .. tostring(data.playerKey or ""),
      "player_name=" .. tostring(player.name or player.displayName or player.username or ""),
      "player_id=" .. tostring(player.id or player.uuid or ""),
      "minigame_key=" .. tostring(data.minigameKey or ""),
      "team_key=" .. tostring(data.teamKey or ""),
      "leaderboard_values=" .. tostring(#leaderboard_values),
      "player_json=" .. json_encode(data),
    }
    found.data = data
    return found
  end)

  BMF.commands.register("bmf.minigames.data.playerstate", "Resolve one player's current BMF-owned minigame membership state.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "player")
    local found = BMF.minigames.playerState(query)
    local data = found.data or {}
    local player = data.player or {}
    data.lines = {
      "code=" .. tostring(found.code or ""),
      "player_key=" .. tostring(data.playerKey or ""),
      "player_name=" .. tostring(player.name or player.displayName or player.username or ""),
      "in_minigame=" .. tostring(data.inMinigame == true),
      "minigame_key=" .. tostring(data.minigameKey or ""),
      "team_key=" .. tostring(data.teamKey or ""),
      "activity_minigame_key=" .. tostring(data.activityMinigameKey or ""),
      "has_leaderboard=" .. tostring(data.hasLeaderboard == true),
      "reason=" .. tostring(data.reason or ""),
      "player_state_json=" .. json_encode(data),
    }
    found.data = data
    return found
  end)

  BMF.commands.register("bmf.minigames.data.membership", "Find one player's BMF-owned minigame membership.", function(args)
    local options = parse_command_options(args)
    local query = minigame_data_query_from_options(options, "player")
    local found = BMF.minigames.membership(query)
    local data = found.data or {}
    local player = data.player or {}
    data.lines = {
      "code=" .. tostring(found.code or ""),
      "player_key=" .. tostring(data.playerKey or ""),
      "player_name=" .. tostring(player.name or player.displayName or player.username or ""),
      "minigame_key=" .. tostring(data.minigameKey or ""),
      "team_key=" .. tostring(data.teamKey or ""),
      "membership_found=" .. tostring(type(data.membership) == "table"),
      "membership_json=" .. json_encode(data),
    }
    found.data = data
    return found
  end)

  BMF.commands.register("bmf.minigames.data.clear", "Clear BMF-owned minigame data after explicit confirmation.", function(args)
    local options = parse_command_options(args)
    local cleared = BMF.minigames.clearData(options.confirm or options.token)
    cleared.data = cleared.data or {}
    cleared.data.lines = {
      "code=" .. tostring(cleared.code or ""),
      "cleared_at=" .. tostring(cleared.data.clearedAt or ""),
      "source=" .. tostring(cleared.data.source or ""),
      "confirm_required=CLEAR_MINIGAME_DATA",
    }
    return cleared
  end)

  BMF.commands.register("bmf.minigames.objects.snapshot", "Read BP_Ruleset_C and BP_Team_C objects without console GetAll.", function(args)
    local options = parse_command_options(args)
    local snapshot = BMF.minigames.objectSnapshot({
      limit = option_number(options, "limit", 64),
      includeProperties = option_boolean(options, "includeproperties", false),
      targeted = option_boolean(options, "targeted", false),
    })
    local data = snapshot.data or {}
    data.lines = data.lines or {
      "source=bmf.objectSnapshot",
      "rulesets=0",
      "teams=0",
    }
    snapshot.data = data
    return snapshot
  end)

  BMF.commands.register("bmf.minigames.live.team-state", "Read a live player's referenced minigame team and ruleset objects.", function(args)
    local options = parse_command_options(args)
    local positional = type(options._positional) == "table" and options._positional or {}
    local player_query = options.player or options.query or options.name or positional[1] or ""
    local snapshot = BMF.minigames.liveTeamState({
      player = player_query,
      includeMissing = option_boolean(options, "includemissing", false),
    })
    local data = snapshot.data or {}
    data.lines = data.lines or {
      "source=bmf.liveTeamState",
      "teams=0",
      "rulesets=0",
    }
    snapshot.data = data
    return snapshot
  end)

  BMF.commands.register("bmf.minigames.live.players", "Read live PlayerState team/minigame candidate fields without console GetAll.", function(args)
    local options = parse_command_options(args)
    local positional = type(options._positional) == "table" and options._positional or {}
    local player_query = options.player or options.query or options.name or positional[1] or ""
    local snapshot = BMF.minigames.livePlayerSnapshot({
      player = player_query,
      limit = option_number(options, "limit", 16),
      arrayLimit = option_number(options, "arraylimit", 6),
      includeMissing = option_boolean(options, "includemissing", false),
      reflect = option_boolean(options, "reflect", false),
      reflectValues = option_boolean(options, "reflectvalues", false),
      reflectLimit = option_number(options, "reflectlimit", 32),
      functions = option_boolean(options, "functions", false),
      functionLimit = option_number(options, "functionlimit", 32),
      fallbackFindAll = option_boolean(options, "fallbackfindall", true),
      verbose = option_boolean(options, "verbose", false),
    })
    local data = snapshot.data or {}
    data.lines = data.lines or {
      "source=bmf.livePlayerSnapshot",
      "players=0",
      "returned=0",
    }
    snapshot.data = data
    return snapshot
  end)

  local function minigame_assign_team_command(args)
    local options = parse_command_options(args)
    local positional = type(options._positional) == "table" and options._positional or {}
    local player_query = options.player or options.query or options.name or positional[1] or ""
    local team_index = options.teamindex or options.team or options.index or positional[2] or ""
    local assigned = BMF.minigames.assignTeam(player_query, team_index, {
      dryRun = option_boolean(options, "dryrun", false),
      method = options.method or options.assignmethod or options.nativemethod,
      flag1 = option_boolean(options, "flag1", true),
      flag2 = option_boolean(options, "flag2", true),
    })
    local data = assigned.data or {}
    data.lines = data.lines or {
      "code=" .. tostring(assigned.code or ""),
      "player=" .. tostring(player_query or ""),
      "team_index=" .. tostring(team_index or ""),
    }
    assigned.data = data
    return assigned
  end

  BMF.commands.register("bmf.minigames.live.assign-team", "Assign a live player to a minigame team through the native minigame team API.", minigame_assign_team_command)
  BMF.commands.register("bmf.minigames.assign-team", "Assign a live player to a minigame team through the native minigame team API.", minigame_assign_team_command)

  BMF.commands.register("bmf.minigames.events.emit", "Emit a BMF minigame event for relay validation.", function(args)
    local options = parse_command_options(args)
    local event = options.event or options.type or options._positional[1]
    local payload, payload_error = minigame_event_payload_from_options(options)
    if not payload then
      return result(false, "INVALID_EVENT_PAYLOAD", payload_error, {
        lines = {
          "code=INVALID_EVENT_PAYLOAD",
          "error=" .. tostring(payload_error or ""),
        },
      })
    end
    local emitted = BMF.minigames.emitEvent(event, payload)
    emitted.data = emitted.data or {}
    emitted.data.lines = {
      "event=" .. tostring(emitted.data.event or ""),
      "legacy_event=" .. tostring(emitted.data.legacyEvent or ""),
      "total=" .. tostring(emitted.data.total or 0),
      "count=" .. tostring(emitted.data.count or 0),
      "handlers=" .. tostring(emitted.data.handlers or 0),
      "code=" .. tostring(emitted.code or ""),
    }
    return emitted
  end)

  BMF.commands.register("bmf.world.saveas", "Save the running world as a named BRDB.", function(args)
    local options = parse_command_options(args)
    local name = options.name or options.world or options.save
    if not name and options._positional[1] then
      name = options._positional[1]
    end

    local save = BMF.world.saveAs(name)
    local lines = {}
    if save.data then
      lines[#lines + 1] = "world=" .. tostring(save.data.world or "")
      lines[#lines + 1] = "command=" .. tostring(save.data.command or "")
    end
    save.data.lines = lines
    return save
  end)

  BMF.commands.register("bmf.prefabs.loadbrz", "Load a staged BRZ-derived prefab world.", function(args)
    local options = parse_command_options(args)
    local source = options.source or options.brz or options.prefab or options._positional[1] or "Car.brz"
    local world = options.name or options.world or options.stage or options.stagedworld or options.bundle or options._positional[2]
    local x = option_number(options, "x", option_number(options, "loadx", 0))
    local y = option_number(options, "y", option_number(options, "loady", 0))
    local z = option_number(options, "z", option_number(options, "loadz", 1000))
    local yaw = option_number(options, "yaw", option_number(options, "loadyaw", 0))

    local loaded = BMF.prefabs.loadBrz({
      source = source,
      name = world,
      position = { x = x, y = y, z = z },
      yaw = yaw,
    })

    loaded.data = loaded.data or {}
    local prefab = loaded.data.prefab or {}
    local lines = {
      "source=" .. tostring(source or ""),
      "world=" .. tostring(world or ""),
      "x=" .. tostring(x),
      "y=" .. tostring(y),
      "z=" .. tostring(z),
      "yaw=" .. tostring(yaw),
    }
    if loaded.data.requiresStaging ~= nil then
      lines[#lines + 1] = "staging_required=" .. tostring(loaded.data.requiresStaging)
    end
    if prefab.stagedWorld then
      lines[#lines + 1] = "staged_world=" .. tostring(prefab.stagedWorld)
    end
    if loaded.data.command then
      lines[#lines + 1] = "command=" .. tostring(loaded.data.command)
    end
    if loaded.data.api then
      lines[#lines + 1] = "api=" .. tostring(loaded.data.api)
    end
    if loaded.ok then
      lines[#lines + 1] = "next=bmf.world.saveas"
    elseif loaded.code == "PREFAB_STAGING_REQUIRED" then
      lines[#lines + 1] = "next=stage-brz-prefab"
    end

    loaded.data.lines = lines
    return loaded
  end)

  BMF.commands.register("bmf.prefabs.loadbrdb", "Load a staged BRDB prefab world.", function(args)
    local options = parse_command_options(args)
    local world = options.name or options.world or options.stage or options.stagedworld or options.bundle or options._positional[1]
    local x = option_number(options, "x", option_number(options, "loadx", 0))
    local y = option_number(options, "y", option_number(options, "loady", 0))
    local z = option_number(options, "z", option_number(options, "loadz", 1000))
    local yaw = option_number(options, "yaw", option_number(options, "loadyaw", 0))

    local loaded = BMF.prefabs.loadBrdb({
      name = world,
      position = { x = x, y = y, z = z },
      yaw = yaw,
    })

    loaded.data = loaded.data or {}
    local prefab = loaded.data.prefab or {}
    local lines = {
      "world=" .. tostring(world or ""),
      "x=" .. tostring(x),
      "y=" .. tostring(y),
      "z=" .. tostring(z),
      "yaw=" .. tostring(yaw),
    }
    if prefab.stagedWorld then
      lines[#lines + 1] = "staged_world=" .. tostring(prefab.stagedWorld)
    end
    if loaded.data.command then
      lines[#lines + 1] = "command=" .. tostring(loaded.data.command)
    end
    if loaded.data.api then
      lines[#lines + 1] = "api=" .. tostring(loaded.data.api)
    end
    if loaded.ok then
      lines[#lines + 1] = "next=bmf.world.saveas"
    end

    loaded.data.lines = lines
    return loaded
  end)

  BMF.commands.register("bmf.vehicles.spawnset", "Load a staged vehicle spawn set.", function(args)
    local options = parse_command_options(args)
    local prefix = options.prefix or options.worldnameprefix or options.world or options.name or "BMF_VehicleSpawnSet"
    local count = math.floor(option_number(options, "count", option_number(options, "vehiclecount", 3)))
    local start_x = option_number(options, "startx", option_number(options, "x", 70000))
    local y = option_number(options, "y", option_number(options, "loady", 0))
    local z = option_number(options, "z", option_number(options, "loadz", 1000))
    local step_x = option_number(options, "stepx", 2000)
    local yaw = option_number(options, "yaw", option_number(options, "loadyaw", 0))

    local spawned = BMF.vehicles.spawnSet({
      worldNamePrefix = prefix,
      vehicleCount = count,
      start = { x = start_x, y = y, z = z },
      step = { x = step_x },
      yaw = yaw,
    })

    local lines = {
      "prefix=" .. tostring(prefix),
      "requested_count=" .. tostring(count),
      "loaded_count=" .. tostring(spawned.data and spawned.data.vehicleCount or 0),
    }
    if spawned.data and type(spawned.data.responses) == "table" then
      for _, item in ipairs(spawned.data.responses) do
        local data = item.data or {}
        local position = data.position or {}
        lines[#lines + 1] = table.concat({
          "vehicle=" .. tostring(data.vehicleIndex or ""),
          "world=" .. tostring(data.stagedWorld or ""),
          "ok=" .. tostring(item.ok),
          "x=" .. tostring(position.x or ""),
          "y=" .. tostring(position.y or ""),
          "z=" .. tostring(position.z or ""),
        }, " ")
      end
    end
    spawned.data.lines = lines
    return spawned
  end)

  BMF.commands.register("bmf.vehicles.snapshot", "Save the running world for vehicle inventory parsing.", function(args)
    local options = parse_command_options(args)
    local name = options.name or options.world or options.save
    if not name and options._positional[1] then
      name = options._positional[1]
    end
    if not name or trim_string(name) == "" then
      name = "BMF_VehicleSnapshot_" .. os.date("!%Y%m%d%H%M%S")
    end

    local save = BMF.world.saveAs(name)
    local lines = {}
    if save.data then
      lines[#lines + 1] = "world=" .. tostring(save.data.world or "")
      lines[#lines + 1] = "command=" .. tostring(save.data.command or "")
      lines[#lines + 1] = "next=summarize-vehicle-graphs"
      lines[#lines + 1] = "inventory=export-vehicle-inventory"
    end
    save.data.lines = lines
    return save
  end)
end

local function normalize_settings_text(value, label, max_length)
  if value == nil then
    return nil, nil
  end
  if type(value) ~= "string" then
    return nil, label .. " must be a string"
  end
  local text = value:gsub("\r", " "):gsub("\n", " ")
  if text:match("[%z\001-\008\011\012\014-\031]") then
    return nil, label .. " contains unsupported control characters"
  end
  if max_length and #text > max_length then
    return nil, label .. " must be " .. tostring(max_length) .. " characters or fewer"
  end
  return text, nil
end

local function normalize_settings_bool(value, label)
  if value == nil then
    return nil, nil
  end
  if type(value) == "boolean" then
    return value, nil
  end
  if type(value) == "string" then
    local lower = trim_string(value):lower()
    if lower == "true" or lower == "1" or lower == "yes" or lower == "public" then
      return true, nil
    end
    if lower == "false" or lower == "0" or lower == "no" or lower == "private" then
      return false, nil
    end
  end
  return nil, label .. " must be a boolean"
end

BMF.server.planSettingsPatch = function(options)
  if type(options) ~= "table" then
    return result(false, "INVALID_OPTIONS", "settings options table is required")
  end

  local settings = {}
  local changes = {}
  local errors = {}

  local function set_text(field, ini_key, label, max_length)
    local text, err = normalize_settings_text(options[field], label, max_length)
    if err then
      errors[#errors + 1] = err
      return
    end
    if text ~= nil then
      settings[ini_key] = text
      changes[#changes + 1] = ini_key
    end
  end

  set_text("serverName", "ServerName", "serverName", 128)
  if settings.ServerName == nil then
    set_text("name", "ServerName", "name", 128)
  end
  set_text("serverDescription", "ServerDescription", "serverDescription", 512)
  if settings.ServerDescription == nil then
    set_text("description", "ServerDescription", "description", 512)
  end
  set_text("password", "ServerPassword", "password", 128)
  set_text("welcomeMessage", "WelcomeMessage", "welcomeMessage", 512)

  local max_players_source = options.maxPlayers
  if max_players_source == nil then
    max_players_source = options.players
  end
  if max_players_source ~= nil then
    local max_players, err = normalize_integer(max_players_source, "maxPlayers")
    if err then
      errors[#errors + 1] = err
    elseif max_players < 1 or max_players > 255 then
      errors[#errors + 1] = "maxPlayers must be between 1 and 255"
    else
      settings.MaxPlayers = max_players
      changes[#changes + 1] = "MaxPlayers"
    end
  end

  local public_source = options.publiclyListed
  if public_source == nil then
    public_source = options.public
  end
  if public_source ~= nil then
    local publicly_listed, err = normalize_settings_bool(public_source, "publiclyListed")
    if err then
      errors[#errors + 1] = err
    else
      settings.bPubliclyListed = publicly_listed
      changes[#changes + 1] = "bPubliclyListed"
    end
  end

  if #errors > 0 then
    return result(false, "INVALID_SETTINGS", table.concat(errors, "; "), {
      errors = errors,
    })
  end

  if #changes == 0 then
    return result(false, "NO_SETTINGS", "at least one setting is required")
  end

  return result(true, "OK", "Server settings patch planned", {
    settings = settings,
    changes = changes,
  })
end

BMF.permissions = {}
BMF.permissions.SPAWN_ITEMS = "BR.Permission.SpawnItems"
BMF.permissions.APPLICATOR_SAFE = {
  "BR.Permission.Building",
  "BR.Permission.Building.Applicator",
  "BR.Permission.Building.Applicator.EditBricks",
  "BR.Permission.Building.Applicator.EditEntities",
}
BMF.permissions.APPLICATOR_DENIED_COMPONENTS = {
  "SpawnItem",
  "ItemSpawn",
}
BMF.permissions.INTERACT_CONSOLE_ADMIN_ROLES = {
  "Owner",
  "Admin",
}
BMF.permissions.INTERACT_CONSOLE_ALLOWED_PREFIXES = {}
BMF.permissions.BRICK_ASSET_ADMIN_ROLES = {
  "Owner",
  "Admin",
}
BMF.permissions.BRICK_ASSET_DENIED_ASSETS = {}

BMF.permissions.normalizeName = function(name)
  local value = trim_string(name)
  if value == "" then
    return result(false, "INVALID_PERMISSION", "permission name is required")
  end
  if value:match("[%c]") or value:match("[/\\]") then
    return result(false, "INVALID_PERMISSION", "permission name contains unsupported characters")
  end
  return result(true, "OK", "Permission name is valid", { name = value })
end

BMF.permissions.normalizeRoleName = function(name)
  local value = trim_string(name)
  if value == "" then
    return result(false, "INVALID_ROLE_NAME", "role name is required")
  end
  if #value > 64 then
    return result(false, "INVALID_ROLE_NAME", "role name must be 64 characters or fewer")
  end
  if value:match("[%c]") or value:match("[/\\]") then
    return result(false, "INVALID_ROLE_NAME", "role name contains unsupported characters")
  end
  return result(true, "OK", "Role name is valid", { name = value })
end

BMF.permissions.toMap = function(permissions)
  local map = {}
  if type(permissions) ~= "table" then
    return map
  end

  for key, value in pairs(permissions) do
    if type(key) == "string" then
      local allowed = permission_state_to_bool(value)
      if allowed ~= nil then
        map[key] = allowed
      end
    elseif type(value) == "string" then
      map[value] = true
    elseif type(value) == "table" and type(value.name) == "string" then
      local allowed = permission_state_to_bool(value.state)
      if allowed == nil then
        allowed = permission_state_to_bool(value.allowed)
      end
      if allowed ~= nil then
        map[value.name] = allowed
      end
    end
  end

  return map
end

do
local function permission_bool_to_state(value)
  if value == true then
    return "Allowed"
  end
  if value == false then
    return "Forbidden"
  end
  return "missing"
end

BMF.permissions.describeRole = function(role)
  if type(role) ~= "table" then
    return result(false, "INVALID_ROLE", "role table is required")
  end

  local role_name = first_string(role.name, role.roleName, role.displayName) or ""
  local entries = {}
  local permissions = {}
  local counts = {}
  local invalid = {}

  if type(role.permissions) == "table" then
    for _, permission in ipairs(role.permissions) do
      local permission_name = nil
      local state = nil
      local allowed = nil

      if type(permission) == "string" then
        permission_name = permission
        state = "Allowed"
        allowed = true
      elseif type(permission) == "table" and type(permission.name) == "string" then
        permission_name = permission.name
        state = first_string(permission.state, permission.status, permission.value) or ""
        allowed = permission_state_to_bool(permission.state)
        if allowed == nil then
          allowed = permission_state_to_bool(permission.allowed)
        end
        if state == "" then
          state = permission_bool_to_state(allowed)
        end
      end

      if permission_name then
        local normalized = BMF.permissions.normalizeName(permission_name)
        if normalized.ok then
          permission_name = normalized.data.name
          counts[permission_name] = (counts[permission_name] or 0) + 1
          if permissions[permission_name] == nil and allowed ~= nil then
            permissions[permission_name] = allowed
          end
          entries[#entries + 1] = {
            name = permission_name,
            state = state,
            allowed = allowed,
          }
        else
          invalid[#invalid + 1] = tostring(permission_name)
        end
      end
    end
  end

  local duplicates = {}
  for name, count in pairs(counts) do
    if count > 1 then
      duplicates[#duplicates + 1] = {
        name = name,
        count = count,
      }
    end
  end
  table.sort(duplicates, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)

  return result(true, "OK", "Role permissions described", {
    roleName = role_name,
    permissionCount = #entries,
    permissions = permissions,
    entries = entries,
    duplicates = duplicates,
    duplicateCount = #duplicates,
    invalid = invalid,
    invalidCount = #invalid,
  })
end

local function evaluate_no_spawn_item_role_policy(role, options)
  options = type(options) == "table" and options or {}
  local described = BMF.permissions.describeRole(role)
  if not described.ok then
    return described
  end

  local data = described.data or {}
  local permissions = data.permissions or {}
  local allow_inherited_spawn_items = options.allowInheritedSpawnItems == true
  local required = {}
  local missing_allowed = {}
  for _, permission_name in ipairs(BMF.permissions.APPLICATOR_SAFE) do
    local allowed = permissions[permission_name] == true
    required[#required + 1] = {
      name = permission_name,
      allowed = allowed,
      state = permission_bool_to_state(permissions[permission_name]),
    }
    if not allowed then
      missing_allowed[#missing_allowed + 1] = permission_name
    end
  end

  local spawn_items_allowed = permissions[BMF.permissions.SPAWN_ITEMS]
  local spawn_items_missing = spawn_items_allowed == nil
  local spawn_items_forbidden = spawn_items_allowed == false
    or (allow_inherited_spawn_items and spawn_items_missing)
  local spawn_items_state = permission_bool_to_state(spawn_items_allowed)
  if allow_inherited_spawn_items and spawn_items_missing then
    spawn_items_state = "Inherited"
  end
  local spawn_items_entry_count = 0
  for _, entry in ipairs(data.entries or {}) do
    if entry.name == BMF.permissions.SPAWN_ITEMS then
      spawn_items_entry_count = spawn_items_entry_count + 1
    end
  end
  local compliant = #missing_allowed == 0 and spawn_items_forbidden and (data.duplicateCount or 0) == 0 and (data.invalidCount or 0) == 0

  return result(true, "OK", "No-spawn-item applicator policy evaluated", {
    policy = "noSpawnItemApplicator",
    compliant = compliant,
    roleName = data.roleName or "",
    safeApplicatorAllowed = #missing_allowed == 0,
    spawnItemsForbidden = spawn_items_forbidden,
    spawnItemsState = spawn_items_state,
    spawnItemsInherited = allow_inherited_spawn_items and spawn_items_missing,
    spawnItemsEntryCount = spawn_items_entry_count,
    spawnItemsDuplicateCount = math.max(spawn_items_entry_count - 1, 0),
    allowInheritedSpawnItems = allow_inherited_spawn_items,
    requiredAllowed = required,
    missingAllowed = missing_allowed,
    duplicateCount = data.duplicateCount or 0,
    duplicates = data.duplicates or {},
    invalidCount = data.invalidCount or 0,
    invalid = data.invalid or {},
    permissionCount = data.permissionCount or 0,
  })
end

BMF.permissions.evaluateNoSpawnItemApplicator = function(role)
  return evaluate_no_spawn_item_role_policy(role)
end

local function normalize_component_key(value)
  local text = trim_string(value)
  if text == "" then
    return result(false, "INVALID_COMPONENT", "component name is required")
  end
  if text:match("[%c]") then
    return result(false, "INVALID_COMPONENT", "component name contains unsupported characters")
  end

  local key = text:lower():gsub("[^a-z0-9]", "")
  if key == "" then
    return result(false, "INVALID_COMPONENT", "component name did not contain searchable characters")
  end
  if key:sub(-9) == "component" then
    key = key:sub(1, #key - 9)
  end

  return result(true, "OK", "Component name normalized", {
    name = text,
    key = key,
  })
end

local function component_rule_list(value, fallback)
  if type(value) == "table" then
    return value
  end
  if type(fallback) == "table" then
    return fallback
  end
  return {}
end

BMF.permissions._normalizeComponentKey = normalize_component_key
BMF.permissions._componentRuleList = component_rule_list

local function normalize_component_rules(values)
  local rules = {}
  if type(values) ~= "table" then
    return rules
  end

  for _, value in ipairs(values) do
    local normalized = normalize_component_key(value)
    if normalized.ok then
      rules[#rules + 1] = normalized.data
    end
  end
  return rules
end

local function component_matches_rule(component_key, rule_key)
  if not component_key or not rule_key or rule_key == "" then
    return false
  end
  if component_key == rule_key then
    return true
  end
  return component_key:sub(0 - #rule_key) == rule_key
end

local function find_component_rule(component_key, rules)
  for _, rule in ipairs(rules or {}) do
    if component_matches_rule(component_key, rule.key) then
      return rule
    end
  end
  return nil
end

BMF.permissions.evaluateApplicatorComponentAccess = function(options)
  if type(options) == "string" then
    options = { component = options }
  end
  if type(options) ~= "table" then
    return result(false, "INVALID_COMPONENT_POLICY", "options table or component string is required")
  end

  local component_source = options.component or options.componentName or options.name or options.type
  local component = normalize_component_key(component_source)
  if not component.ok then
    return component
  end

  local policy = type(options.policy) == "table" and options.policy or {}
  local denied_components = component_rule_list(
    options.deniedComponents or options.denyComponents or options.blockedComponents or policy.deniedComponents or policy.denyComponents or policy.blockedComponents,
    BMF.permissions.APPLICATOR_DENIED_COMPONENTS
  )
  local allowed_components = component_rule_list(
    options.allowedComponents or options.allowComponents or policy.allowedComponents or policy.allowComponents,
    nil
  )

  local denied_rules = normalize_component_rules(denied_components)
  local allowed_rules = normalize_component_rules(allowed_components)
  local denied_match = find_component_rule(component.data.key, denied_rules)
  local allowed_match = find_component_rule(component.data.key, allowed_rules)

  local actor = options.actor or options.player or {}
  local actor_uuid = ""
  local actor_name = ""
  if type(actor) == "table" then
    actor_uuid = first_string(actor.uuid, actor.id, actor.playerId, actor.playerID) or ""
    actor_name = first_string(actor.username, actor.name, actor.displayName, actor.playerName) or ""
  elseif type(actor) == "string" then
    actor_uuid = actor
  end

  local allowed = true
  local decision = "component-allowed"
  local reason = "component is not denied"
  local matched_component = ""

  if denied_match then
    allowed = false
    decision = "component-denied"
    reason = "component matched denied applicator component policy"
    matched_component = denied_match.name
  elseif #allowed_rules > 0 and not allowed_match then
    allowed = false
    decision = "component-not-allowlisted"
    reason = "component did not match allowlisted applicator components"
  elseif allowed_match then
    matched_component = allowed_match.name
    reason = "component matched allowlisted applicator component policy"
  end

  return result(true, "OK", "Applicator component access evaluated", {
    policy = "applicatorComponentAccess",
    allowed = allowed,
    decision = decision,
    reason = reason,
    component = component.data.name,
    componentKey = component.data.key,
    matchedComponent = matched_component,
    deniedComponentCount = #denied_rules,
    allowedComponentCount = #allowed_rules,
    actorUuid = actor_uuid,
    actorName = actor_name,
    global = true,
  })
end

local function normalize_interact_prefix(value)
  local text = trim_string(value)
  if text == "" then
    return nil
  end
  if text:match("[%c]") then
    return nil
  end
  return {
    name = text,
    key = text:lower(),
  }
end

local function normalize_interact_prefix_rules(values)
  local rules = {}
  if type(values) ~= "table" then
    return rules
  end
  for _, value in ipairs(values) do
    local rule = normalize_interact_prefix(value)
    if rule then
      rules[#rules + 1] = rule
    end
  end
  return rules
end

local function normalize_role_list(value)
  local roles = {}
  local seen = {}
  local function add(role)
    local normalized = BMF.permissions.normalizeRoleName(role)
    if normalized.ok then
      local name = normalized.data.name
      local key = name:lower()
      if not seen[key] then
        seen[key] = true
        roles[#roles + 1] = name
      end
    end
  end

  if type(value) == "string" then
    for role in value:gmatch("[^,|]+") do
      add(role)
    end
  elseif type(value) == "table" then
    for _, role in ipairs(value) do
      add(role)
    end
  end
  return roles
end

local function actor_role_list(actor, explicit_roles)
  local roles = normalize_role_list(explicit_roles)
  if #roles > 0 then
    return roles
  end
  if type(actor) == "table" then
    roles = normalize_role_list(actor.roles or actor.roleNames or actor.role)
    if #roles > 0 then
      return roles
    end
  end
  return {}
end

local function find_role_match(roles, allowed_roles)
  local map = {}
  for _, role in ipairs(roles or {}) do
    map[tostring(role):lower()] = tostring(role)
  end
  for _, allowed in ipairs(allowed_roles or {}) do
    local matched = map[tostring(allowed):lower()]
    if matched then
      return matched
    end
  end
  return ""
end

local function find_interact_prefix_match(tag_key, rules)
  for _, rule in ipairs(rules or {}) do
    if tag_key:sub(1, #rule.key) == rule.key then
      return rule
    end
  end
  return nil
end

BMF.permissions.evaluateInteractConsolePrefixAccess = function(options)
  if type(options) == "string" then
    options = { tag = options }
  end
  if type(options) ~= "table" then
    return result(false, "INVALID_INTERACT_CONSOLE_POLICY", "options table or tag string is required")
  end

  local policy = type(options.policy) == "table" and options.policy or {}
  local raw_tag = first_string(options.tag, options.consoleTag, options.message, options.value, policy.tag) or ""
  local tag = trim_string(raw_tag)
  if tag:match("[%c]") then
    return result(false, "INVALID_INTERACT_CONSOLE_TAG", "Interact console tag contains unsupported characters", {
      tag = tostring(raw_tag or ""),
    })
  end

  local actor = options.actor or options.player or {}
  local actor_uuid = ""
  local actor_name = ""
  if type(actor) == "table" then
    actor_uuid = first_string(actor.uuid, actor.id, actor.playerId, actor.playerID) or ""
    actor_name = first_string(actor.username, actor.name, actor.displayName, actor.playerName) or ""
  elseif type(actor) == "string" then
    actor_uuid = actor
  end

  local allowed_prefixes = component_rule_list(
    options.allowedPrefixes or options.allowPrefixes or options.prefixes or policy.allowedPrefixes or policy.allowPrefixes or policy.prefixes,
    BMF.permissions.INTERACT_CONSOLE_ALLOWED_PREFIXES
  )
  local admin_roles = component_rule_list(
    options.adminRoles or options.bypassRoles or policy.adminRoles or policy.bypassRoles,
    BMF.permissions.INTERACT_CONSOLE_ADMIN_ROLES
  )
  local prefix_rules = normalize_interact_prefix_rules(allowed_prefixes)
  local bypass_roles = normalize_role_list(admin_roles)
  local roles = actor_role_list(actor, options.roles or policy.roles)
  local matched_role = find_role_match(roles, bypass_roles)
  local allow_empty = options.allowEmpty
  if allow_empty == nil then
    allow_empty = policy.allowEmpty
  end
  allow_empty = allow_empty ~= false
  local deny_unknown = options.denyUnknown
  if deny_unknown == nil then
    deny_unknown = policy.denyUnknown
  end
  deny_unknown = deny_unknown ~= false

  local tag_key = tag:lower()
  local matched_prefix = ""
  local allowed = false
  local decision = "prefix-denied"
  local reason = "interact console tag did not match an allowed prefix"

  if tag == "" and allow_empty then
    allowed = true
    decision = "empty-allowed"
    reason = "empty interact console tag is allowed"
  elseif matched_role ~= "" then
    allowed = true
    decision = "admin-bypass"
    reason = "actor matched an interact console bypass role"
  else
    local rule = find_interact_prefix_match(tag_key, prefix_rules)
    if rule then
      allowed = true
      decision = "prefix-allowed"
      reason = "interact console tag matched an allowed prefix"
      matched_prefix = rule.name
    elseif not deny_unknown then
      allowed = true
      decision = "unknown-allowed"
      reason = "unknown interact console prefixes are allowed by policy"
    end
  end

  return result(true, "OK", "Interact console prefix access evaluated", {
    policy = "interactConsolePrefixAccess",
    allowed = allowed,
    decision = decision,
    reason = reason,
    tag = tag,
    normalizedTag = tag_key,
    matchedPrefix = matched_prefix,
    actorUuid = actor_uuid,
    actorName = actor_name,
    roles = roles,
    matchedRole = matched_role,
    allowedPrefixCount = #prefix_rules,
    adminRoleCount = #bypass_roles,
    denyUnknown = deny_unknown,
    allowEmpty = allow_empty,
  })
end

local function normalize_brick_asset_key(value)
  local text = trim_string(value)
  if text == "" then
    return result(false, "INVALID_BRICK_ASSET", "brick asset name is required")
  end
  if text:match("[%c]") then
    return result(false, "INVALID_BRICK_ASSET", "brick asset name contains unsupported characters")
  end

  local key = text:lower():gsub("[^a-z0-9]", "")
  if key == "" then
    return result(false, "INVALID_BRICK_ASSET", "brick asset name did not contain searchable characters")
  end

  return result(true, "OK", "Brick asset name normalized", {
    name = text,
    key = key,
  })
end

local function brick_asset_rule_list(value, fallback)
  if type(value) == "table" then
    return value
  end
  if type(value) == "string" then
    local items = {}
    for item in value:gmatch("[^,|]+") do
      items[#items + 1] = item
    end
    return items
  end
  if type(fallback) == "table" then
    return fallback
  end
  return {}
end

local function normalize_brick_asset_rule(value)
  local text = trim_string(value)
  if text == "" or text:match("[%c]") then
    return nil
  end

  local starts_wild = text:sub(1, 1) == "*"
  local ends_wild = text:sub(-1) == "*"
  local core = trim_string(text:gsub("%*", ""))
  local normalized = normalize_brick_asset_key(core)
  if not normalized.ok then
    return nil
  end

  local mode = "contains"
  if starts_wild and ends_wild then
    mode = "contains"
  elseif starts_wild then
    mode = "suffix"
  elseif ends_wild then
    mode = "prefix"
  end

  return {
    name = text,
    key = normalized.data.key,
    mode = mode,
  }
end

local function normalize_brick_asset_rules(values)
  local rules = {}
  for _, value in ipairs(brick_asset_rule_list(values, nil)) do
    local rule = normalize_brick_asset_rule(value)
    if rule then
      rules[#rules + 1] = rule
    end
  end
  return rules
end

local function brick_asset_matches_rule(asset_key, rule)
  if not asset_key or not rule or not rule.key or rule.key == "" then
    return false
  end
  if rule.mode == "prefix" then
    return asset_key:sub(1, #rule.key) == rule.key
  end
  if rule.mode == "suffix" then
    return asset_key:sub(0 - #rule.key) == rule.key
  end
  return asset_key:find(rule.key, 1, true) ~= nil
end

local function find_brick_asset_rule(asset_key, rules)
  for _, rule in ipairs(rules or {}) do
    if brick_asset_matches_rule(asset_key, rule) then
      return rule
    end
  end
  return nil
end

local function normalize_plain_string_list(value)
  local items = {}
  local seen = {}
  local function add(item)
    local text = trim_string(item)
    if text == "" or text:match("[%c]") then
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

local function find_plain_string_match(values, allowed)
  local map = {}
  for _, value in ipairs(values or {}) do
    local key = trim_string(value):lower()
    if key ~= "" then
      map[key] = trim_string(value)
    end
  end
  for _, value in ipairs(allowed or {}) do
    local matched = map[trim_string(value):lower()]
    if matched then
      return matched
    end
  end
  return ""
end

BMF.permissions.evaluateBrickAssetAccess = function(options)
  if type(options) == "string" then
    options = { asset = options }
  end
  if type(options) ~= "table" then
    return result(false, "INVALID_BRICK_ASSET_POLICY", "options table or asset string is required")
  end

  local policy = type(options.policy) == "table" and options.policy or {}
  local asset_source = first_string(
    options.asset,
    options.brickAsset,
    options.brickName,
    options.name,
    options.type,
    policy.asset
  )
  local asset = normalize_brick_asset_key(asset_source)
  if not asset.ok then
    return asset
  end

  local actor = options.actor or options.player or {}
  local actor_uuid = ""
  local actor_name = ""
  if type(actor) == "table" then
    actor_uuid = first_string(actor.uuid, actor.id, actor.playerId, actor.playerID, actor.userId) or ""
    actor_name = first_string(actor.username, actor.name, actor.displayName, actor.playerName) or ""
  elseif type(actor) == "string" then
    actor_uuid = actor
  end

  local denied_assets = brick_asset_rule_list(
    options.deniedAssets or options.denyAssets or options.blockedAssets or policy.deniedAssets or policy.denyAssets or policy.blockedAssets,
    BMF.permissions.BRICK_ASSET_DENIED_ASSETS
  )
  local allowed_assets = brick_asset_rule_list(
    options.allowedAssets or options.allowAssets or policy.allowedAssets or policy.allowAssets,
    nil
  )
  local denied_rules = normalize_brick_asset_rules(denied_assets)
  local allowed_rules = normalize_brick_asset_rules(allowed_assets)
  local denied_match = find_brick_asset_rule(asset.data.key, denied_rules)
  local allowed_match = find_brick_asset_rule(asset.data.key, allowed_rules)

  local admin_roles = brick_asset_rule_list(
    options.adminRoles or options.bypassRoles or policy.adminRoles or policy.bypassRoles,
    BMF.permissions.BRICK_ASSET_ADMIN_ROLES
  )
  local allowed_roles = brick_asset_rule_list(
    options.allowedRoles or options.allowRoles or policy.allowedRoles or policy.allowRoles,
    nil
  )
  local roles = actor_role_list(actor, options.roles or policy.roles)
  local bypass_roles = normalize_role_list(admin_roles)
  local role_allowlist = normalize_role_list(allowed_roles)
  local matched_admin_role = find_role_match(roles, bypass_roles)
  local matched_allowed_role = find_role_match(roles, role_allowlist)
  local matched_role = matched_admin_role ~= "" and matched_admin_role or matched_allowed_role

  local bypass_ids = normalize_plain_string_list(
    options.ownerIds or options.adminIds or options.bypassPlayerIds or options.allowedPlayers
      or policy.ownerIds or policy.adminIds or policy.bypassPlayerIds or policy.allowedPlayers
  )
  local matched_player_id = find_plain_string_match({ actor_uuid }, bypass_ids)

  local deny_unknown = options.denyUnknown
  if deny_unknown == nil then
    deny_unknown = policy.denyUnknown
  end
  deny_unknown = deny_unknown == true

  local allowed = true
  local decision = "asset-allowed"
  local reason = "brick asset is not denied"
  local matched_asset = ""

  if matched_player_id ~= "" then
    decision = "player-bypass"
    reason = "actor matched a brick asset bypass player id"
  elseif matched_admin_role ~= "" then
    decision = "admin-bypass"
    reason = "actor matched a brick asset admin role"
  elseif matched_allowed_role ~= "" then
    decision = "role-bypass"
    reason = "actor matched a brick asset allowed role"
  elseif denied_match then
    allowed = false
    decision = "asset-denied"
    reason = "brick asset matched denied policy"
    matched_asset = denied_match.name
  elseif #allowed_rules > 0 and not allowed_match then
    allowed = false
    decision = "asset-not-allowlisted"
    reason = "brick asset did not match allowlisted policy"
  elseif deny_unknown and not allowed_match then
    allowed = false
    decision = "asset-unknown-denied"
    reason = "unknown brick assets are denied by policy"
  elseif allowed_match then
    matched_asset = allowed_match.name
    reason = "brick asset matched allowlisted policy"
  end

  return result(true, "OK", "Brick asset access evaluated", {
    policy = "brickAssetAccess",
    allowed = allowed,
    decision = decision,
    reason = reason,
    asset = asset.data.name,
    assetKey = asset.data.key,
    assetKind = tostring(options.assetKind or options.kind or policy.assetKind or ""),
    matchedAsset = matched_asset,
    actorUuid = actor_uuid,
    actorName = actor_name,
    roles = roles,
    matchedRole = matched_role,
    matchedPlayerId = matched_player_id,
    deniedAssetCount = #denied_rules,
    allowedAssetCount = #allowed_rules,
    adminRoleCount = #bypass_roles,
    allowedRoleCount = #role_allowlist,
    denyUnknown = deny_unknown,
  })
end

local function role_assignments_path_from_options(options)
  options = type(options) == "table" and options or {}
  local explicit = first_string(options.path, options.roleAssignmentsPath, options.file)
  if explicit then
    return explicit:gsub("\\", "/"), nil
  end

  local saved_dir = first_string(options.savedDir, state.config.brickadiaSavedDir)
  if not saved_dir then
    return nil, "brickadiaSavedDir is not configured"
  end

  return join_path(saved_dir, "Server/RoleAssignments.json"), nil
end

BMF.permissions.loadRoleAssignments = function(options)
  options = type(options) == "table" and options or {}
  local path, path_error = role_assignments_path_from_options(options)
  if not path then
    return result(false, "ROLE_ASSIGNMENTS_PATH_UNAVAILABLE", path_error or "RoleAssignments path is unavailable", {
      configuredSavedDir = tostring(state.config.brickadiaSavedDir or ""),
      lines = {
        "ok=false",
        "code=ROLE_ASSIGNMENTS_PATH_UNAVAILABLE",
        "configured_saved_dir=" .. tostring(state.config.brickadiaSavedDir or ""),
      },
    })
  end

  local raw = read_file(path)
  if raw == nil or trim_string(raw) == "" then
    return result(false, "ROLE_ASSIGNMENTS_NOT_FOUND", "RoleAssignments.json was not found or empty", {
      path = path,
      lines = {
        "ok=false",
        "code=ROLE_ASSIGNMENTS_NOT_FOUND",
        "path=" .. tostring(path),
      },
    })
  end

  local decoded, err = json_decode(raw)
  if err ~= nil or type(decoded) ~= "table" then
    return result(false, "JSON_PARSE_FAILED", "RoleAssignments.json could not be parsed", {
      path = path,
      error = tostring(err or "decoded value was not an object"),
      lines = {
        "ok=false",
        "code=JSON_PARSE_FAILED",
        "path=" .. tostring(path),
        "error=" .. tostring(err or "decoded value was not an object"),
      },
    })
  end

  local described = BMF.permissions.describeRoleAssignments(decoded)
  if not described.ok then
    return described
  end

  local lines = {
    "path=" .. tostring(path),
    "player_count=" .. tostring(described.data and described.data.playerCount or 0),
    "invalid_player_count=" .. tostring(described.data and described.data.invalidPlayerCount or 0),
    "invalid_role_count=" .. tostring(described.data and described.data.invalidRoleCount or 0),
    "duplicate_role_count=" .. tostring(described.data and described.data.duplicateRoleCount or 0),
  }

  return result(true, "OK", "Role assignments loaded", {
    path = path,
    assignments = decoded,
    players = described.data and described.data.players or {},
    playerCount = described.data and described.data.playerCount or 0,
    invalidPlayers = described.data and described.data.invalidPlayers or {},
    invalidPlayerCount = described.data and described.data.invalidPlayerCount or 0,
    invalidRoleCount = described.data and described.data.invalidRoleCount or 0,
    duplicateRoleCount = described.data and described.data.duplicateRoleCount or 0,
    lines = lines,
  })
end

local function role_setup_path_from_options(options)
  options = type(options) == "table" and options or {}
  local explicit = first_string(options.path, options.roleSetupPath, options.file)
  if explicit then
    return explicit:gsub("\\", "/"), nil
  end

  local saved_dir = first_string(options.savedDir, state.config.brickadiaSavedDir)
  if not saved_dir then
    return nil, "brickadiaSavedDir is not configured"
  end

  return join_path(saved_dir, "Server/RoleSetup2.json"), nil
end

local function role_name_or_default(role, fallback)
  if type(role) == "table" then
    return first_string(role.name, role.roleName, role.displayName, fallback) or tostring(fallback or "")
  end
  return tostring(fallback or "")
end

local function patch_no_spawn_item_role(role, fallback_name, options)
  options = type(options) == "table" and options or {}
  if type(role) ~= "table" then
    return nil, result(false, "INVALID_ROLE", "role table is required")
  end

  local allow_inherited_spawn_items = options.allowInheritedSpawnItems == true
  local before = evaluate_no_spawn_item_role_policy(role, {
    allowInheritedSpawnItems = allow_inherited_spawn_items,
  })
  local before_data = before.data or {}
  local patch = nil
  if allow_inherited_spawn_items then
    patch = {
      allow = BMF.permissions.APPLICATOR_SAFE,
    }
    if before_data.spawnItemsState == "Allowed" or (before_data.spawnItemsDuplicateCount or 0) > 0 then
      patch.forbid = {
        BMF.permissions.SPAWN_ITEMS,
      }
    end
  else
    patch = {
      noSpawnItemApplicator = true,
    }
  end

  local planned = BMF.permissions.planRolePatch(role, patch)
  if not planned.ok then
    return nil, planned
  end

  local after = evaluate_no_spawn_item_role_policy(planned.data and planned.data.role or {}, {
    allowInheritedSpawnItems = allow_inherited_spawn_items,
  })
  local after_data = after.data or {}
  local changed = before_data.compliant ~= true
    or before_data.spawnItemsState ~= after_data.spawnItemsState
    or before_data.safeApplicatorAllowed ~= after_data.safeApplicatorAllowed
    or before_data.duplicateCount ~= after_data.duplicateCount
    or before_data.invalidCount ~= after_data.invalidCount

  return planned.data.role, result(true, "OK", "Role patched", {
    roleName = role_name_or_default(role, fallback_name),
    changed = changed,
    beforeCompliant = before_data.compliant == true,
    afterCompliant = after_data.compliant == true,
    beforeSpawnItemsState = tostring(before_data.spawnItemsState or ""),
    afterSpawnItemsState = tostring(after_data.spawnItemsState or ""),
    allowInheritedSpawnItems = allow_inherited_spawn_items,
    spawnItemsInherited = after_data.spawnItemsInherited == true,
    safeApplicatorAllowed = after_data.safeApplicatorAllowed == true,
  })
end

BMF.permissions.enforceNoSpawnItemApplicator = function(options)
  options = type(options) == "table" and options or {}
  local path, path_error = role_setup_path_from_options(options)
  if not path then
    return result(false, "ROLE_SETUP_PATH_UNAVAILABLE", path_error or "RoleSetup2 path is unavailable", {
      configuredSavedDir = tostring(state.config.brickadiaSavedDir or ""),
      lines = {
        "ok=false",
        "code=ROLE_SETUP_PATH_UNAVAILABLE",
        "configured_saved_dir=" .. tostring(state.config.brickadiaSavedDir or ""),
      },
    })
  end

  local raw = read_file(path)
  if raw == nil or trim_string(raw) == "" then
    return result(false, "ROLE_SETUP_NOT_FOUND", "RoleSetup2.json was not found or empty", {
      path = path,
      lines = {
        "ok=false",
        "code=ROLE_SETUP_NOT_FOUND",
        "path=" .. tostring(path),
      },
    })
  end

  local decoded, err = json_decode(raw)
  if err ~= nil or type(decoded) ~= "table" then
    return result(false, "JSON_PARSE_FAILED", "RoleSetup2.json could not be parsed", {
      path = path,
      error = tostring(err or "decoded value was not an object"),
      lines = {
        "ok=false",
        "code=JSON_PARSE_FAILED",
        "path=" .. tostring(path),
        "error=" .. tostring(err or "decoded value was not an object"),
      },
    })
  end

  local role_reports = {}
  local patched_roles = {}
  local errors = {}
  local changed_count = 0

  if type(decoded.defaultRole) == "table" then
    local patched, report = patch_no_spawn_item_role(decoded.defaultRole, "Default")
    if patched then
      role_reports[#role_reports + 1] = report.data
      if report.data and report.data.changed then
        decoded.defaultRole = patched
        changed_count = changed_count + 1
        patched_roles[#patched_roles + 1] = report.data.roleName
      end
    else
      errors[#errors + 1] = tostring(report.code or "DEFAULT_ROLE_PATCH_FAILED")
    end
  else
    errors[#errors + 1] = "defaultRole missing"
  end

  if type(decoded.roles) == "table" then
    for index, role in ipairs(decoded.roles) do
      if type(role) == "table" then
        local patched, report = patch_no_spawn_item_role(role, "role_" .. tostring(index), {
          allowInheritedSpawnItems = true,
        })
        if patched then
          role_reports[#role_reports + 1] = report.data
          if report.data and report.data.changed then
            decoded.roles[index] = patched
            changed_count = changed_count + 1
            patched_roles[#patched_roles + 1] = report.data.roleName
          end
        else
          errors[#errors + 1] = tostring(report.code or "ROLE_PATCH_FAILED") .. ":" .. tostring(index)
        end
      end
    end
  end

  if #errors > 0 then
    return result(false, "ROLE_PATCH_FAILED", "One or more roles could not be patched", {
      path = path,
      errors = errors,
      lines = {
        "ok=false",
        "code=ROLE_PATCH_FAILED",
        "path=" .. tostring(path),
        "errors=" .. table.concat(errors, "|"),
      },
    })
  end

  local dry_run = options.dryRun == true or options.dryrun == true
    or tostring(options.dryRun or options.dryrun or ""):lower() == "true"
    or tostring(options.write or ""):lower() == "false"
  local backup_enabled = not (
    options.backup == false
      or tostring(options.backup or ""):lower() == "false"
      or tostring(options.backup or "") == "0"
  )
  local backup_path = ""
  local written = false

  if not dry_run and changed_count > 0 then
    if backup_enabled then
      backup_path = path .. ".bmf-backup-" .. os.date("!%Y%m%d%H%M%S") .. ".json"
      if not write_file(backup_path, raw) then
        return result(false, "ROLE_SETUP_BACKUP_FAILED", "Could not write RoleSetup2 backup", {
          path = path,
          backupPath = backup_path,
          lines = {
            "ok=false",
            "code=ROLE_SETUP_BACKUP_FAILED",
            "path=" .. tostring(path),
            "backup_path=" .. tostring(backup_path),
          },
        })
      end
    end

    if not write_file(path, json_encode(decoded) .. "\n") then
      return result(false, "ROLE_SETUP_WRITE_FAILED", "Could not write patched RoleSetup2.json", {
        path = path,
        backupPath = backup_path,
        lines = {
          "ok=false",
          "code=ROLE_SETUP_WRITE_FAILED",
          "path=" .. tostring(path),
          "backup_path=" .. tostring(backup_path),
        },
      })
    end
    written = true
  end

  local lines = {
    "path=" .. tostring(path),
    "dry_run=" .. tostring(dry_run),
    "changed=" .. tostring(changed_count > 0),
    "written=" .. tostring(written),
    "patched_role_count=" .. tostring(changed_count),
    "role_count=" .. tostring(#role_reports),
    "patched_roles=" .. table.concat(patched_roles, "|"),
    "backup_path=" .. tostring(backup_path),
    "restart_required=" .. tostring(changed_count > 0),
    "live_hot_reload_supported=false",
  }

  return result(true, "OK", "No-spawn-item applicator role policy enforced", {
    path = path,
    dryRun = dry_run,
    changed = changed_count > 0,
    written = written,
    backupPath = backup_path,
    roleCount = #role_reports,
    patchedRoleCount = changed_count,
    patchedRoles = patched_roles,
    roles = role_reports,
    restartRequired = changed_count > 0,
    liveHotReloadSupported = false,
    lines = lines,
  })
end

end

BMF.permissions.planRolePatch = function(role, patch)
  if type(role) ~= "table" then
    return result(false, "INVALID_ROLE", "role table is required")
  end
  if type(patch) ~= "table" then
    patch = {}
  end

  local planned = copy_table(role)
  if type(planned.permissions) ~= "table" then
    planned.permissions = {}
  end

  local permissions = {}
  local by_name = {}
  for _, permission in ipairs(planned.permissions) do
    if type(permission) == "table" and type(permission.name) == "string" and by_name[permission.name] == nil then
      local entry = {
        name = permission.name,
        state = first_string(permission.state, "Allowed") or "Allowed",
      }
      permissions[#permissions + 1] = entry
      by_name[entry.name] = entry
    end
  end

  local changes = {
    allowed = {},
    forbidden = {},
    removed = {},
  }

  local function list_or_empty(value)
    if type(value) == "table" then
      return value
    end
    return {}
  end

  local function set_permission(name, state, bucket)
    local normalized = BMF.permissions.normalizeName(name)
    if not normalized.ok then
      return
    end
    local permission_name = normalized.data.name
    local entry = by_name[permission_name]
    if not entry then
      entry = { name = permission_name, state = state }
      permissions[#permissions + 1] = entry
      by_name[permission_name] = entry
    else
      entry.state = state
    end
    changes[bucket][#changes[bucket] + 1] = permission_name
  end

  local function remove_permission(name)
    local normalized = BMF.permissions.normalizeName(name)
    if not normalized.ok then
      return
    end
    local permission_name = normalized.data.name
    local next_permissions = {}
    for _, permission in ipairs(permissions) do
      if permission.name ~= permission_name then
        next_permissions[#next_permissions + 1] = permission
      end
    end
    permissions = next_permissions
    by_name[permission_name] = nil
    changes.removed[#changes.removed + 1] = permission_name
  end

  if patch.noSpawnItemApplicator then
    for _, permission in ipairs(BMF.permissions.APPLICATOR_SAFE) do
      set_permission(permission, "Allowed", "allowed")
    end
    set_permission(BMF.permissions.SPAWN_ITEMS, "Forbidden", "forbidden")
  end

  for _, permission in ipairs(list_or_empty(patch.allow)) do
    set_permission(permission, "Allowed", "allowed")
  end
  for _, permission in ipairs(list_or_empty(patch.forbid)) do
    set_permission(permission, "Forbidden", "forbidden")
  end
  for _, permission in ipairs(list_or_empty(patch.remove)) do
    remove_permission(permission)
  end

  planned.permissions = permissions
  return result(true, "OK", "Role patch planned", {
    role = planned,
    changes = changes,
  })
end

do
local function normalize_role_list(value)
  local roles = {}
  local seen = {}
  local invalid = {}
  local duplicates = {}

  if type(value) ~= "table" then
    return roles, invalid, duplicates
  end

  for _, role in ipairs(value) do
    local normalized = BMF.permissions.normalizeRoleName(role)
    if normalized.ok then
      local role_name = normalized.data.name
      local key = role_name:lower()
      if seen[key] then
        duplicates[#duplicates + 1] = role_name
      else
        seen[key] = true
        roles[#roles + 1] = role_name
      end
    else
      invalid[#invalid + 1] = tostring(role)
    end
  end

  return roles, invalid, duplicates
end

local function player_uuid_from_value(value)
  if type(value) == "string" then
    return trim_string(value)
  end
  if type(value) == "table" then
    return first_string(value.uuid, value.playerId, value.playerID, value.id)
  end
  return nil
end

BMF.permissions.describeRoleAssignments = function(assignments)
  if type(assignments) ~= "table" then
    return result(false, "INVALID_ASSIGNMENTS", "role assignments table is required")
  end

  local source = assignments.savedPlayerRoles
  if type(source) ~= "table" then
    source = {}
  end

  local players = {}
  local invalid_players = {}
  local duplicate_role_count = 0
  local invalid_role_count = 0
  local player_ids = {}

  for player_id in pairs(source) do
    player_ids[#player_ids + 1] = tostring(player_id)
  end
  table.sort(player_ids)

  for _, player_id in ipairs(player_ids) do
    local record = source[player_id]
    if not is_uuid(player_id) then
      invalid_players[#invalid_players + 1] = player_id
    else
      local role_values = {}
      if type(record) == "table" and type(record.roles) == "table" then
        role_values = record.roles
      end
      local roles, invalid, duplicates = normalize_role_list(role_values)
      duplicate_role_count = duplicate_role_count + #duplicates
      invalid_role_count = invalid_role_count + #invalid
      players[#players + 1] = {
        uuid = player_id,
        roles = roles,
        roleCount = #roles,
        invalidRoles = invalid,
        invalidRoleCount = #invalid,
        duplicateRoles = duplicates,
        duplicateRoleCount = #duplicates,
      }
    end
  end

  return result(true, "OK", "Role assignments described", {
    players = players,
    playerCount = #players,
    invalidPlayers = invalid_players,
    invalidPlayerCount = #invalid_players,
    duplicateRoleCount = duplicate_role_count,
    invalidRoleCount = invalid_role_count,
  })
end

BMF.permissions.getPlayerRoles = function(assignments, player)
  local uuid = player_uuid_from_value(player)
  if not is_uuid(uuid) then
    return result(false, "INVALID_PLAYER_ID", "player UUID is missing or invalid")
  end

  if type(assignments) ~= "table" then
    return result(false, "INVALID_ASSIGNMENTS", "role assignments table is required")
  end

  local source = assignments.savedPlayerRoles
  local record = type(source) == "table" and source[uuid] or nil
  local roles, invalid, duplicates = {}, {}, {}
  local found = type(record) == "table"
  if found then
    roles, invalid, duplicates = normalize_role_list(record.roles)
  end

  return result(true, "OK", "Player roles resolved", {
    uuid = uuid,
    found = found,
    roles = roles,
    roleCount = #roles,
    invalidRoles = invalid,
    invalidRoleCount = #invalid,
    duplicateRoles = duplicates,
    duplicateRoleCount = #duplicates,
  })
end

BMF.permissions.playerHasRole = function(assignments, player, role)
  local normalized = BMF.permissions.normalizeRoleName(role)
  if not normalized.ok then
    return result(false, "INVALID_ROLE_NAME", normalized.message)
  end

  local resolved = BMF.permissions.getPlayerRoles(assignments, player)
  if not resolved.ok then
    return resolved
  end

  local requested = normalized.data.name:lower()
  local matched = ""
  for _, item in ipairs((resolved.data and resolved.data.roles) or {}) do
    if tostring(item):lower() == requested then
      matched = item
      break
    end
  end

  return result(true, "OK", "Player role membership checked", {
    uuid = resolved.data.uuid,
    role = normalized.data.name,
    hasRole = matched ~= "",
    matchedRole = matched,
    roles = resolved.data.roles or {},
    roleCount = resolved.data.roleCount or 0,
    found = resolved.data.found == true,
  })
end

local function normalize_command_policy_value(value, default)
  if type(value) == "boolean" then
    return value and "allow" or "deny"
  end

  local text = trim_string(value):lower()
  if text == "" then
    return default
  end

  if text == "allow" or text == "allowed" or text == "true" or text == "yes" then
    return "allow"
  end
  if text == "deny" or text == "denied" or text == "forbid" or text == "forbidden" or text == "false" or text == "no" then
    return "deny"
  end

  return default
end

local function command_policy_deny_enabled(value)
  if type(value) == "boolean" then
    return value
  end

  local text = trim_string(value):lower()
  return text == "true" or text == "yes" or text == "deny" or text == "denied" or text == "forbid" or text == "forbidden"
end

local function normalize_command_policy_name(value)
  local command_name = trim_string(value):lower()
  if command_name == "" then
    return result(false, "INVALID_COMMAND", "command name is required")
  end
  if not command_name:match("^bmf%.[a-z0-9_.%-]+$") then
    return result(false, "INVALID_COMMAND", "command name must start with bmf. and use simple tokens")
  end
  return result(true, "OK", "Command name is valid", { name = command_name })
end

local function append_role_values(target, value)
  if type(value) == "string" then
    target[#target + 1] = value
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      target[#target + 1] = item
    end
  end
end

local function normalize_command_role_fields(source, fields)
  local values = {}
  if type(source) == "table" then
    for _, field in ipairs(fields) do
      append_role_values(values, source[field])
    end
  end
  return normalize_role_list(values)
end

local function role_map_from_list(roles)
  local map = {}
  for _, role in ipairs(roles or {}) do
    map[tostring(role):lower()] = tostring(role)
  end
  return map
end

local function intersect_roles(actor_roles, required_roles)
  local matched = {}
  local actor_map = role_map_from_list(actor_roles)
  for _, role in ipairs(required_roles or {}) do
    local actor_role = actor_map[tostring(role):lower()]
    if actor_role then
      matched[#matched + 1] = actor_role
    end
  end
  return matched
end

local function find_command_policy_rule(commands, command_name)
  if type(commands) ~= "table" then
    return nil
  end

  local direct = commands[command_name]
  if direct ~= nil then
    return direct
  end

  for key, value in pairs(commands) do
    if type(key) == "string" and trim_string(key):lower() == command_name then
      return value
    end
  end
  return nil
end

BMF.permissions.evaluateCommandAccess = function(policy, actor, command)
  if type(policy) ~= "table" then
    return result(false, "INVALID_POLICY", "command policy table is required")
  end

  local normalized_command = normalize_command_policy_name(command)
  if not normalized_command.ok then
    return normalized_command
  end
  local command_name = normalized_command.data.name

  local actor_source = ""
  local actor_uuid = player_uuid_from_value(actor)
  local actor_role_values = {}
  if type(actor) == "table" then
    actor_source = first_string(actor.source, actor.actorSource, actor.kind) or ""
    append_role_values(actor_role_values, actor.roles)
    append_role_values(actor_role_values, actor.roleNames)
  end
  actor_source = trim_string(actor_source):lower()
  if actor_source == "" then
    actor_source = "player"
  end

  local actor_roles, invalid_actor_roles, duplicate_actor_roles = normalize_role_list(actor_role_values)
  local role_source = #actor_roles > 0 and "actor" or "none"
  local assignment_found = false
  local assignments = policy.assignments
  if type(assignments) ~= "table" then
    assignments = policy.roleAssignments
  end
  if type(assignments) == "table" and is_uuid(actor_uuid) then
    local resolved = BMF.permissions.getPlayerRoles(assignments, actor_uuid)
    if resolved.ok then
      assignment_found = resolved.data and resolved.data.found == true
      local merged = {}
      append_role_values(merged, actor_roles)
      append_role_values(merged, resolved.data and resolved.data.roles)
      actor_roles, invalid_actor_roles, duplicate_actor_roles = normalize_role_list(merged)
      if assignment_found then
        role_source = role_source == "actor" and "actor+assignments" or "assignments"
      end
    end
  end

  local default_value = policy.default
  if default_value == nil then
    default_value = policy.defaultAccess
  end
  local console_value = policy.console
  if console_value == nil then
    console_value = policy.consoleAccess
  end
  local default_policy = normalize_command_policy_value(default_value, "deny")
  local console_policy = normalize_command_policy_value(console_value, nil)
  local rule = find_command_policy_rule(policy.commands, command_name)
  local rule_found = rule ~= nil

  local required_roles = {}
  local denied_roles = {}
  local invalid_policy_roles = {}
  local duplicate_policy_roles = {}
  local matched_roles = {}
  local explicit = nil

  if actor_source == "console" and console_policy ~= nil then
    local allowed = console_policy == "allow"
    return result(true, "OK", "Command access evaluated", {
      command = command_name,
      actorSource = actor_source,
      uuid = actor_uuid or "",
      allowed = allowed,
      decision = allowed and "console-source" or "console-denied",
      reason = allowed and "console-source" or "console-denied",
      ruleFound = rule_found,
      defaultPolicy = default_policy,
      consolePolicy = console_policy,
      actorRoles = actor_roles,
      actorRoleCount = #actor_roles,
      requiredRoles = required_roles,
      matchedRoles = matched_roles,
      deniedRoles = denied_roles,
      invalidActorRoles = invalid_actor_roles,
      duplicateActorRoles = duplicate_actor_roles,
      invalidPolicyRoles = invalid_policy_roles,
      duplicatePolicyRoles = duplicate_policy_roles,
      assignmentFound = assignment_found,
      roleSource = role_source,
    })
  end

  if type(rule) == "boolean" then
    explicit = rule and "allow" or "deny"
  elseif type(rule) == "string" then
    explicit = normalize_command_policy_value(rule, nil)
  elseif type(rule) == "table" then
    local rule_policy_value = rule.access
    if rule_policy_value == nil then
      rule_policy_value = rule.effect
    end
    if rule_policy_value == nil then
      rule_policy_value = rule.policy
    end
    explicit = normalize_command_policy_value(rule_policy_value, nil)
    local allow_setting = normalize_command_policy_value(rule.allow, nil)
    if allow_setting ~= nil then
      explicit = allow_setting
    end
    if command_policy_deny_enabled(rule.deny) or explicit == "deny" then
      explicit = "deny"
    end

    local invalid_required = {}
    local duplicate_required = {}
    required_roles, invalid_required, duplicate_required = normalize_command_role_fields(rule, {
      "roles",
      "allowedRoles",
      "requiredRoles",
      "anyRole",
      "anyRoles",
    })
    local invalid_denied = {}
    local duplicate_denied = {}
    denied_roles, invalid_denied, duplicate_denied = normalize_command_role_fields(rule, {
      "denyRoles",
      "deniedRoles",
      "blockedRoles",
    })
    append_role_values(invalid_policy_roles, invalid_required)
    append_role_values(invalid_policy_roles, invalid_denied)
    append_role_values(duplicate_policy_roles, duplicate_required)
    append_role_values(duplicate_policy_roles, duplicate_denied)
  end

  local allowed = false
  local decision = ""
  if explicit == "deny" then
    allowed = false
    decision = "explicit-deny"
  else
    local denied_matches = intersect_roles(actor_roles, denied_roles)
    if #denied_matches > 0 then
      allowed = false
      decision = "role-denied"
      matched_roles = denied_matches
    elseif #required_roles > 0 then
      matched_roles = intersect_roles(actor_roles, required_roles)
      allowed = #matched_roles > 0
      decision = allowed and "role-allowed" or "role-missing"
    elseif explicit == "allow" then
      allowed = true
      decision = "explicit-allow"
    else
      allowed = default_policy == "allow"
      decision = rule_found and ("default-" .. default_policy) or ("unknown-command-default-" .. default_policy)
    end
  end

  return result(true, "OK", "Command access evaluated", {
    command = command_name,
    actorSource = actor_source,
    uuid = actor_uuid or "",
    allowed = allowed,
    decision = decision,
    reason = decision,
    ruleFound = rule_found,
    defaultPolicy = default_policy,
    consolePolicy = console_policy or "",
    actorRoles = actor_roles,
    actorRoleCount = #actor_roles,
    requiredRoles = required_roles,
    matchedRoles = matched_roles,
    deniedRoles = denied_roles,
    invalidActorRoles = invalid_actor_roles,
    duplicateActorRoles = duplicate_actor_roles,
    invalidPolicyRoles = invalid_policy_roles,
    duplicatePolicyRoles = duplicate_policy_roles,
    assignmentFound = assignment_found,
    roleSource = role_source,
  })
end

BMF.permissions.planPlayerRoleAssignment = function(assignments, patch)
  if type(assignments) ~= "table" then
    assignments = {}
  end
  if type(patch) ~= "table" then
    return result(false, "INVALID_OPTIONS", "assignment patch table is required")
  end

  local uuid = first_string(patch.uuid, patch.id, patch.playerId, patch.playerID)
  if not is_uuid(uuid) then
    return result(false, "INVALID_PLAYER_ID", "player UUID is missing or invalid")
  end

  local planned = copy_table(assignments)
  if type(planned.savedPlayerRoles) ~= "table" then
    planned.savedPlayerRoles = {}
  end

  local record = planned.savedPlayerRoles[uuid]
  if type(record) ~= "table" then
    record = { roles = {} }
    planned.savedPlayerRoles[uuid] = record
  end
  if type(record.roles) ~= "table" then
    record.roles = {}
  end

  local roles = {}
  local seen = {}
  local errors = {}

  local function push_role(role)
    local normalized = BMF.permissions.normalizeRoleName(role)
    if not normalized.ok then
      errors[#errors + 1] = normalized.message
      return
    end
    local role_name = normalized.data.name
    local key = role_name:lower()
    if not seen[key] then
      roles[#roles + 1] = role_name
      seen[key] = true
    end
  end

  local function list_or_empty(value)
    if type(value) == "table" then
      return value
    end
    return {}
  end

  if type(patch.set) == "table" then
    for _, role in ipairs(patch.set) do
      push_role(role)
    end
  elseif type(patch.roles) == "table" then
    for _, role in ipairs(patch.roles) do
      push_role(role)
    end
  else
    for _, role in ipairs(record.roles) do
      push_role(role)
    end
  end

  local removed = {}
  local remove_map = {}
  for _, role in ipairs(list_or_empty(patch.remove or patch.revoke)) do
    local normalized = BMF.permissions.normalizeRoleName(role)
    if normalized.ok then
      remove_map[normalized.data.name:lower()] = normalized.data.name
    else
      errors[#errors + 1] = normalized.message
    end
  end

  if patch.clear then
    for _, role in ipairs(roles) do
      removed[#removed + 1] = role
    end
    roles = {}
    seen = {}
  elseif next(remove_map) ~= nil then
    local kept = {}
    for _, role in ipairs(roles) do
      if remove_map[role:lower()] then
        removed[#removed + 1] = role
      else
        kept[#kept + 1] = role
      end
    end
    roles = kept
    seen = {}
    for _, role in ipairs(roles) do
      seen[role:lower()] = true
    end
  end

  local added = {}
  for _, role in ipairs(list_or_empty(patch.add or patch.grant)) do
    local before_count = #roles
    push_role(role)
    if #roles > before_count then
      added[#added + 1] = roles[#roles]
    end
  end

  if #errors > 0 then
    return result(false, "INVALID_ROLE_ASSIGNMENT", table.concat(errors, "; "), {
      errors = errors,
    })
  end

  record.roles = roles
  if #roles == 0 and patch.deleteWhenEmpty then
    planned.savedPlayerRoles[uuid] = nil
  end

  return result(true, "OK", "Player role assignment patch planned", {
    assignments = planned,
    uuid = uuid,
    roles = roles,
    added = added,
    removed = removed,
  })
end

end

local remove_tool_handlers_for_owner

BMF.bricks = {}
BMF.tools = {}
BMF.tools.uobject = {}
BMF.tools.applicator = {}
BMF.tools.treeCutTrace = {}
BMF.tools.treeCutNative = {}
BMF.tools.treeCutProbe = {}

do

local function native_uobject_parse_lines(text)
  local lines = {}
  local fields = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
    local key, value = line:match("^([A-Za-z0-9_]+)=(.*)$")
    if key ~= nil then
      fields[key] = value or ""
    end
  end
  return lines, fields
end

function BMF.tools.uobject.describe(options)
  options = type(options) == "table" and options or {}
  local positional = type(options._positional) == "table" and options._positional or {}
  local address = trim_string(options.address or options.addr or options.pointer or positional[1] or "")
  if address == "" then
    return result(false, "NATIVE_UOBJECT_ADDRESS_REQUIRED", "Provide address=0x... for one live UObject pointer.", {
      lines = {
        "ok=false",
        "code=NATIVE_UOBJECT_ADDRESS_REQUIRED",
      },
    })
  end

  if type(BMFSocketDescribeUObject) ~= "function" then
    return result(false, "NATIVE_UOBJECT_DESCRIBE_UNAVAILABLE", "BMFSocketDescribeUObject native helper is unavailable.", {
      address = address,
      lines = {
        "ok=false",
        "code=NATIVE_UOBJECT_DESCRIBE_UNAVAILABLE",
        "address=" .. tostring(address),
      },
    })
  end

  local ok, response = pcall(BMFSocketDescribeUObject, address)
  if not ok then
    return result(false, "NATIVE_UOBJECT_DESCRIBE_FAILED", tostring(response or "native helper failed"), {
      address = address,
      lines = {
        "ok=false",
        "code=NATIVE_UOBJECT_DESCRIBE_FAILED",
        "address=" .. tostring(address),
        "detail=" .. tostring(response or "native helper failed"),
      },
    })
  end

  local lines, fields = native_uobject_parse_lines(response)
  local describe_ok = tostring(fields.ok or "") == "true"
  return result(describe_ok, describe_ok and "OK" or "NATIVE_UOBJECT_DESCRIBE_FAILED", tostring(fields.detail or "Native UObject description"), {
    address = address,
    fields = fields,
    lines = lines,
  })
end

local APPLICATOR_TRACE_PATH = RUNTIME_DIR .. "/logs/applicator.jsonl"
local APPLICATOR_HOOK_CANDIDATES = {
  "Function /Script/Brickadia.BRTool_Applicator.ServerAddComponent",
  "Function /Script/Brickadia.BRTool_Applicator:ServerAddComponent",
  "/Script/Brickadia.BRTool_Applicator:ServerAddComponent",
  "/Script/Brickadia.BRTool_Applicator.ServerAddComponent",
  "ServerAddComponent",
}

local APPLICATOR_MODIFY_HOOK_CANDIDATES = {
  "Function /Script/Brickadia.BRTool_Applicator.ServerModifyComponent",
  "Function /Script/Brickadia.BRTool_Applicator:ServerModifyComponent",
  "/Script/Brickadia.BRTool_Applicator:ServerModifyComponent",
  "/Script/Brickadia.BRTool_Applicator.ServerModifyComponent",
  "ServerModifyComponent",
}

local APPLICATOR_CONTEXT_CANDIDATES = {
  "BRTool_Applicator",
  "Tool_Applicator_C",
}

local function tool_object_valid(object)
  if object == nil or type(object) ~= "userdata" then
    return false
  end
  if type(object.IsValid) ~= "function" then
    return true
  end
  local ok, is_valid = pcall(function()
    return object:IsValid()
  end)
  return ok and is_valid == true
end

local function tool_object_address_from_string(object)
  local hex = tostring(object or ""):match("UObject:%s*([0-9A-Fa-f]+)")
  if hex and hex ~= "" then
    return "0x" .. hex
  end
  return ""
end

local function tool_object_address(object)
  if object == nil or type(object) ~= "userdata" then
    return ""
  end
  if type(object.GetAddress) == "function" then
    local ok, address = pcall(function()
      return object:GetAddress()
    end)
    if ok and type(address) == "number" then
      return string.format("0x%X", address)
    end
    if ok and type(address) == "string" then
      local hex = address:match("0x[0-9A-Fa-f]+") or address:match("([0-9A-Fa-f]+)")
      if hex and hex ~= "" then
        if hex:match("^0x") then
          return hex
        end
        return "0x" .. hex
      end
    end
  end
  return tool_object_address_from_string(object)
end

local function tool_object_full_name(object)
  if not tool_object_valid(object) or type(object.GetFullName) ~= "function" then
    return ""
  end
  local ok, full_name = pcall(function()
    return object:GetFullName()
  end)
  if ok and full_name ~= nil then
    local text = trim_string(full_name)
    if text ~= "." and text ~= "" then
      return text
    end
  end
  return ""
end

local function tool_object_class_full_name(object)
  if not tool_object_valid(object) or type(object.GetClass) ~= "function" then
    return ""
  end
  local ok, class_object = pcall(function()
    return object:GetClass()
  end)
  if ok and tool_object_valid(class_object) then
    return tool_object_full_name(class_object)
  end
  return ""
end

local function tool_param_get(value)
  if value ~= nil and type(value.get) == "function" then
    local ok, unwrapped = pcall(function()
      return value:get()
    end)
    if ok then
      return unwrapped, true
    end
  end
  if value ~= nil and type(value.Get) == "function" then
    local ok, unwrapped = pcall(function()
      return value:Get()
    end)
    if ok then
      return unwrapped, true
    end
  end
  return value, false
end

local function tool_param_set(value, replacement)
  if value ~= nil and type(value.set) == "function" then
    local ok = pcall(function()
      value:set(replacement)
    end)
    if ok then
      return true
    end
  end
  if value ~= nil and type(value.Set) == "function" then
    local ok = pcall(function()
      value:Set(replacement)
    end)
    if ok then
      return true
    end
  end
  return false
end

local function tool_try_property(object, name)
  if not tool_object_valid(object) then
    return nil
  end
  if type(object.GetPropertyValue) == "function" then
    local ok, value = pcall(function()
      return object:GetPropertyValue(name)
    end)
    if ok and value ~= nil then
      return value
    end
  end
  local ok, value = pcall(function()
    return object[name]
  end)
  if ok and value ~= nil then
    return value
  end
  return nil
end

local function applicator_add_candidate(candidates, seen, value, source)
  local text = trim_string(value or "")
  if text == "" or text == "." then
    return
  end
  local key = source .. ":" .. text
  if seen[key] then
    return
  end
  seen[key] = true
  candidates[#candidates + 1] = {
    value = text,
    source = source,
  }
end

local function applicator_component_aliases(name)
  local aliases = {}
  local seen = {}
  local function add(value)
    local text = trim_string(value or "")
    if text == "" then
      return
    end
    local normalized = BMF.permissions._normalizeComponentKey(text)
    local key = normalized.ok and normalized.data.key or text:lower()
    if seen[key] then
      return
    end
    seen[key] = true
    aliases[#aliases + 1] = text:gsub("[^A-Za-z0-9_]", "")
  end

  add(name)
  local normalized = BMF.permissions._normalizeComponentKey(name)
  local key = normalized.ok and normalized.data.key or ""
  if key == "spawnitem" then
    add("ItemSpawn")
  elseif key == "itemspawn" then
    add("SpawnItem")
  end
  return aliases
end

local function applicator_component_class_candidates(name)
  local candidates = {}
  local seen = {}
  local function add(value)
    local text = trim_string(value or "")
    if text == "" or seen[text] then
      return
    end
    seen[text] = true
    candidates[#candidates + 1] = text
  end

  for _, alias in ipairs(applicator_component_aliases(name)) do
    add("BrickComponentType_" .. alias)
    add("UBrickComponentType_" .. alias)
    add("BrickComponentData_" .. alias)
    add("UBrickComponentData_" .. alias)
  end
  return candidates
end

local function applicator_cache_component_address(name, object, source)
  local address = tool_object_address(object)
  if address == "" then
    return false
  end
  local cache = state.tools.applicator.component_cache
  cache[address] = {
    name = tostring(name or ""),
    address = address,
    source = tostring(source or ""),
    fullName = tool_object_full_name(object),
    className = tool_object_class_full_name(object),
  }
  return true
end

local function applicator_find_first_of(class_name)
  if type(FindFirstOf) ~= "function" then
    return nil, "FindFirstOf unavailable"
  end
  local ok, object = pcall(FindFirstOf, class_name)
  if ok and (tool_object_valid(object) or tool_object_address_from_string(object) ~= "") then
    return object, nil
  end
  return nil, tostring(object or "not found")
end

local function applicator_static_find(name)
  if type(StaticFindObject) ~= "function" then
    return nil, "StaticFindObject unavailable"
  end
  for _, candidate in ipairs({
    name,
    "/Script/Brickadia." .. tostring(name or ""),
    "/Script/Brickadia:" .. tostring(name or ""),
  }) do
    local ok, object = pcall(StaticFindObject, candidate)
    if ok and tool_object_valid(object) then
      return object, candidate
    end
  end
  return nil, "not found"
end

function BMF.tools.applicator.refreshComponentCache(options)
  options = type(options) == "table" and options or {}
  local denied = BMF.permissions._componentRuleList(options.deniedComponents, BMF.permissions.APPLICATOR_DENIED_COMPONENTS)
  local cached = 0
  local notes = {}

  for _, component in ipairs(denied) do
    for _, class_name in ipairs(applicator_component_class_candidates(component)) do
      local object, find_error = applicator_find_first_of(class_name)
      if object then
        if applicator_cache_component_address(component, object, "FindFirstOf(" .. class_name .. ")") then
          cached = cached + 1
        end
      else
        notes[#notes + 1] = class_name .. ":" .. tostring(find_error)
      end

      local static_object, static_source = applicator_static_find(class_name)
      if static_object then
        if applicator_cache_component_address(component, static_object, "StaticFindObject(" .. static_source .. ")") then
          cached = cached + 1
        end
      end
    end
  end

  state.tools.applicator.component_cache_notes = notes
  return result(true, "OK", "Applicator component cache refreshed", {
    cachedCount = cached,
    cache = copy_table(state.tools.applicator.component_cache),
    notes = notes,
  })
end

local function applicator_resolve_component_type(name)
  local notes = {}
  for _, class_name in ipairs(applicator_component_class_candidates(name)) do
    local object, find_error = applicator_find_first_of(class_name)
    if object then
      local cached = {
        name = tostring(name or ""),
        address = tool_object_address(object),
        source = "FindFirstOf(" .. class_name .. ")",
        fullName = tool_object_full_name(object),
        className = tool_object_class_full_name(object),
      }
      if cached.address ~= "" then
        return cached, notes
      end
    else
      notes[#notes + 1] = class_name .. ":" .. tostring(find_error or "not found")
    end

    local static_object, static_source = applicator_static_find(class_name)
    if static_object then
      local cached = {
        name = tostring(name or ""),
        address = tool_object_address(static_object),
        source = "StaticFindObject(" .. tostring(static_source or class_name) .. ")",
        fullName = tool_object_full_name(static_object),
        className = tool_object_class_full_name(static_object),
      }
      if cached.address ~= "" then
        return cached, notes
      end
    end
  end
  return nil, notes
end

local applicator_scan_uobjects_raw

local function applicator_find_server_function(function_name, candidates)
  local errors = {}
  local lowered_function_name = tostring(function_name or ""):lower()
  for _, hook_path in ipairs(candidates or {}) do
    local object, source = applicator_static_find(hook_path)
    if object then
      return object, "StaticFindObject(" .. tostring(source or hook_path) .. ")", errors
    end
    errors[#errors + 1] = hook_path .. ":" .. tostring(source or "not found")
  end

  if type(FindAllOf) == "function" then
    for _, class_name in ipairs({ "Function", "UFunction" }) do
      local ok, objects = pcall(FindAllOf, class_name)
      if ok and type(objects) == "table" then
        for _, object in pairs(objects) do
          local full_name = tool_object_full_name(object)
          local lowered = full_name:lower()
          if lowered:find(lowered_function_name, 1, true)
            and lowered:find("applicator", 1, true) then
            return object, "FindAllOf(" .. class_name .. "):" .. full_name, errors
          end
        end
        errors[#errors + 1] = "FindAllOf(" .. class_name .. "):no applicator " .. tostring(function_name or "")
      else
        errors[#errors + 1] = "FindAllOf(" .. class_name .. "):" .. tostring(objects or "failed")
      end
    end
  else
    errors[#errors + 1] = "FindAllOf unavailable"
  end

  errors[#errors + 1] = "ForEachUObject scanner disabled; it aborts UE4SS simple-action cleanup on this dedicated server build"

  return nil, "", errors
end

local function applicator_find_server_add_component_function()
  return applicator_find_server_function("ServerAddComponent", APPLICATOR_HOOK_CANDIDATES)
end

local function applicator_find_server_modify_component_function()
  return applicator_find_server_function("ServerModifyComponent", APPLICATOR_MODIFY_HOOK_CANDIDATES)
end

local function applicator_scan_tokens(value)
  local tokens = {}
  local raw = trim_string(value or "")
  if raw == "" then
    return tokens
  end
  for token in raw:gmatch("[^,|]+") do
    local text = trim_string(token):lower()
    if text ~= "" then
      tokens[#tokens + 1] = text
    end
  end
  return tokens
end

local function applicator_tokens_match(value, tokens, any)
  if #tokens == 0 then
    return true
  end
  local text = tostring(value or ""):lower()
  if any then
    for _, token in ipairs(tokens) do
      if text:find(token, 1, true) then
        return true
      end
    end
    return false
  end
  for _, token in ipairs(tokens) do
    if not text:find(token, 1, true) then
      return false
    end
  end
  return true
end

applicator_scan_uobjects_raw = function(options)
  options = type(options) == "table" and options or {}
  if type(ForEachUObject) ~= "function" then
    return {
      ok = false,
      code = "FOREACHUOBJECT_UNAVAILABLE",
      message = "ForEachUObject is unavailable",
      data = {
        matches = {},
        lines = { "ok=false", "code=FOREACHUOBJECT_UNAVAILABLE" },
      },
    }
end

  local limit = tonumber(options.limit) or 50
  if limit < 1 then
    limit = 1
  elseif limit > 250 then
    limit = 250
  end

  local max_scan = tonumber(options.max or options.maxScan) or 250000
  if max_scan < 1 then
    max_scan = 1
  elseif max_scan > 1000000 then
    max_scan = 1000000
  end

  local any = tostring(options.any or ""):lower()
  local match_any = any == "1" or any == "true" or any == "yes"
  local patterns = applicator_scan_tokens(options.patterns or options.pattern or "")
  local name_patterns = applicator_scan_tokens(options.name or options.fullName or "")
  local class_patterns = applicator_scan_tokens(options.class or options.className or "")
  local matches = {}
  local visited = 0
  local scanned = 0
  local matched = 0
  local errors = 0
  local truncated = false

  local ok, err = pcall(ForEachUObject, function(object, chunk_index, object_index)
    visited = visited + 1
    if visited > max_scan then
      truncated = true
      return
    end
    scanned = scanned + 1

    local inspect_ok, include = pcall(function()
      local full_name = tool_object_full_name(object)
      local class_name = tool_object_class_full_name(object)
      local combined = full_name .. " " .. class_name
      if not applicator_tokens_match(combined, patterns, match_any) then
        return false
      end
      if not applicator_tokens_match(full_name, name_patterns, match_any) then
        return false
      end
      if not applicator_tokens_match(class_name, class_patterns, match_any) then
        return false
      end
      matched = matched + 1
      if #matches < limit then
        matches[#matches + 1] = {
          object = object,
          address = tool_object_address(object),
          fullName = full_name,
          className = class_name,
          chunkIndex = chunk_index,
          objectIndex = object_index,
        }
      end
      return true
    end)

    if not inspect_ok then
      errors = errors + 1
    end
  end)

  if not ok then
    return {
      ok = false,
      code = "UOBJECT_SCAN_FAILED",
      message = tostring(err or "ForEachUObject failed"),
      data = {
        matches = matches,
        visited = visited,
        scanned = scanned,
        matched = matched,
        errors = errors,
        truncated = truncated,
      },
    }
  end

  return {
    ok = true,
    code = "OK",
    message = "UE object scan completed",
    data = {
      matches = matches,
      visited = visited,
      scanned = scanned,
      matched = matched,
      errors = errors,
      truncated = truncated,
      limit = limit,
      maxScan = max_scan,
      pattern = tostring(options.patterns or options.pattern or ""),
      name = tostring(options.name or options.fullName or ""),
      class = tostring(options.class or options.className or ""),
      any = match_any,
    },
  }
end

local function applicator_scan_public_data(data)
  data = type(data) == "table" and data or {}
  local public_matches = {}
  for index, match in ipairs(data.matches or {}) do
    public_matches[#public_matches + 1] = {
      address = tostring(match.address or ""),
      fullName = tostring(match.fullName or ""),
      className = tostring(match.className or ""),
      chunkIndex = match.chunkIndex,
      objectIndex = match.objectIndex,
    }
  end

  local lines = {
    "ok=true",
    "visited=" .. tostring(data.visited or 0),
    "scanned=" .. tostring(data.scanned or 0),
    "matched=" .. tostring(data.matched or 0),
    "returned=" .. tostring(#public_matches),
    "errors=" .. tostring(data.errors or 0),
    "truncated=" .. tostring(data.truncated == true),
    "pattern=" .. tostring(data.pattern or ""),
    "name=" .. tostring(data.name or ""),
    "class=" .. tostring(data.class or ""),
    "any=" .. tostring(data.any == true),
  }
  for index, match in ipairs(public_matches) do
    lines[#lines + 1] =
      "match_" .. tostring(index) .. "=" ..
      tostring(match.address or "") ..
      "|class=" .. tostring(match.className or "") ..
      "|name=" .. tostring(match.fullName or "") ..
      "|chunk=" .. tostring(match.chunkIndex or "") ..
      "|index=" .. tostring(match.objectIndex or "")
  end

  return {
    matches = public_matches,
    visited = data.visited or 0,
    scanned = data.scanned or 0,
    matched = data.matched or 0,
    errors = data.errors or 0,
    truncated = data.truncated == true,
    limit = data.limit,
    maxScan = data.maxScan,
    pattern = tostring(data.pattern or ""),
    name = tostring(data.name or ""),
    class = tostring(data.class or ""),
    any = data.any == true,
    lines = lines,
  }
end

function BMF.tools.applicator.scanObjects(options)
  options = type(options) == "table" and options or {}
  local unsafe = tostring(options.unsafe or ""):lower()
  if not (unsafe == "1" or unsafe == "true" or unsafe == "yes") then
    return result(false, "UOBJECT_SCAN_UNSAFE", "ForEachUObject scan is disabled unless unsafe=1 is explicitly set", {
      lines = {
        "ok=false",
        "code=UOBJECT_SCAN_UNSAFE",
        "reason=ForEachUObject aborts UE4SS simple-action cleanup on this dedicated server build",
      },
    })
  end
  local scanned = applicator_scan_uobjects_raw(options)
  local public_data = applicator_scan_public_data(scanned.data or {})
  if not scanned.ok then
    public_data.lines[1] = "ok=false"
    public_data.lines[#public_data.lines + 1] = "code=" .. tostring(scanned.code or "")
    public_data.lines[#public_data.lines + 1] = "message=" .. tostring(scanned.message or "")
  end
  return result(scanned.ok, scanned.code, scanned.message, public_data)
end

local function applicator_denied_component_target()
  for address, cached in pairs(state.tools.applicator.component_cache or {}) do
    local normalized = BMF.permissions._normalizeComponentKey(cached and cached.name or "")
    local key = normalized.ok and normalized.data.key or ""
    if key == "itemspawn" or key == "spawnitem" then
      return tostring(address), cached
    end
  end
  return "", nil
end

local function applicator_process_event_context_candidates()
  local candidates = {}
  for _, class_name in ipairs(APPLICATOR_CONTEXT_CANDIDATES) do
    local object, error_text = applicator_find_first_of(class_name)
    if object then
      candidates[#candidates + 1] = {
        className = class_name,
        address = tool_object_address(object),
        fullName = tool_object_full_name(object),
        objectClassName = tool_object_class_full_name(object),
        source = "FindFirstOf(" .. class_name .. ")",
      }
    else
      candidates[#candidates + 1] = {
        className = class_name,
        address = "",
        fullName = "",
        objectClassName = "",
        source = "FindFirstOf(" .. class_name .. ")",
        error = tostring(error_text or "not found"),
      }
    end
  end
  return candidates
end

function BMF.tools.applicator.nativeTargets(options)
  options = type(options) == "table" and options or {}
  if options.refresh ~= false then
    BMF.tools.applicator.refreshComponentCache(options)
  end

  local function_object, function_source, function_errors = applicator_find_server_add_component_function()
  local function_address = tool_object_address(function_object)
  local modify_function_object, modify_function_source, modify_function_errors = applicator_find_server_modify_component_function()
  local modify_function_address = tool_object_address(modify_function_object)
  local denied_component_address, denied_component = applicator_denied_component_target()
  local interact_component, interact_component_errors = applicator_resolve_component_type("Interact")
  local context_candidates = applicator_process_event_context_candidates()
  local process_event_context_address = ""
  local process_event_context_source = ""
  for _, candidate in ipairs(context_candidates) do
    if candidate.address ~= "" and process_event_context_address == "" then
      process_event_context_address = candidate.address
      process_event_context_source = candidate.source
    end
  end
  local ok = function_address ~= "" and denied_component_address ~= ""
  local lines = {
    "ok=" .. tostring(ok),
    "function=" .. tostring(function_address),
    "function_source=" .. tostring(function_source or ""),
    "modify_function=" .. tostring(modify_function_address),
    "modify_function_source=" .. tostring(modify_function_source or ""),
    "denied_component=" .. tostring(denied_component_address),
    "denied_component_name=" .. tostring(denied_component and denied_component.name or ""),
    "denied_component_source=" .. tostring(denied_component and denied_component.source or ""),
    "interact_component=" .. tostring(interact_component and interact_component.address or ""),
    "interact_component_name=" .. tostring(interact_component and interact_component.name or ""),
    "interact_component_source=" .. tostring(interact_component and interact_component.source or ""),
    "process_event_context=" .. tostring(process_event_context_address),
    "process_event_context_source=" .. tostring(process_event_context_source),
    "func_offset=0xD8",
    "locals_offset=0x28",
  }
  for index, candidate in ipairs(context_candidates) do
    lines[#lines + 1] =
      "process_event_context_candidate_" .. tostring(index) .. "=" ..
      tostring(candidate.address or "") ..
      "|source=" .. tostring(candidate.source or "") ..
      "|class=" .. tostring(candidate.objectClassName or "") ..
      "|name=" .. tostring(candidate.fullName or "") ..
      "|error=" .. tostring(candidate.error or "")
  end
  for index, item in ipairs(function_errors or {}) do
    lines[#lines + 1] = "function_error_" .. tostring(index) .. "=" .. tostring(item)
  end
  for index, item in ipairs(modify_function_errors or {}) do
    lines[#lines + 1] = "modify_function_error_" .. tostring(index) .. "=" .. tostring(item)
  end
  for index, item in ipairs(interact_component_errors or {}) do
    lines[#lines + 1] = "interact_component_error_" .. tostring(index) .. "=" .. tostring(item)
  end

  return result(ok, ok and "OK" or "NATIVE_TARGETS_INCOMPLETE", "Applicator native targets resolved", {
    functionAddress = function_address,
    functionSource = function_source or "",
    modifyFunctionAddress = modify_function_address,
    modifyFunctionSource = modify_function_source or "",
    deniedComponentAddress = denied_component_address,
    deniedComponent = copy_table(denied_component or {}),
    interactComponentAddress = tostring(interact_component and interact_component.address or ""),
    interactComponent = copy_table(interact_component or {}),
    processEventContextAddress = process_event_context_address,
    processEventContextSource = process_event_context_source,
    processEventContextCandidates = context_candidates,
    funcOffset = "0xD8",
    localsOffset = "0x28",
    functionErrors = function_errors or {},
    modifyFunctionErrors = modify_function_errors or {},
    interactComponentErrors = interact_component_errors or {},
    lines = lines,
  })
end

local function applicator_recent_events(limit)
  limit = tonumber(limit) or 10
  if limit < 1 then
    limit = 1
  end
  if limit > state.tools.applicator.max_events then
    limit = state.tools.applicator.max_events
  end
  local events = {}
  local source = state.tools.applicator.events
  local start_index = math.max(1, #source - limit + 1)
  for index = start_index, #source do
    events[#events + 1] = copy_table(source[index])
  end
  return events
end

local function applicator_record_event(event)
  local app = state.tools.applicator
  app.total_events = app.total_events + 1
  event.sequence = app.total_events
  event.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  app.last_event = copy_table(event)
  app.events[#app.events + 1] = copy_table(event)
  while #app.events > app.max_events do
    table.remove(app.events, 1)
  end
  append_file(APPLICATOR_TRACE_PATH, json_encode(event) .. "\n")
end

local function applicator_build_event(context_param, brick_handle_param, component_type_param)
  local context, context_unwrapped = tool_param_get(context_param)
  local component_object, component_unwrapped = tool_param_get(component_type_param)
  local data_struct = tool_try_property(component_object, "DataStruct")
    or tool_try_property(component_object, "ComponentDataStruct")
    or tool_try_property(component_object, "Data")

  local candidates = {}
  local seen = {}
  local component_address = tool_object_address(component_object)
  local data_struct_address = tool_object_address(data_struct)
  local cached = state.tools.applicator.component_cache[component_address]
    or state.tools.applicator.component_cache[data_struct_address]

  if cached then
    applicator_add_candidate(candidates, seen, cached.name, "cache")
  end
  applicator_add_candidate(candidates, seen, tool_object_full_name(component_object), "component.fullName")
  applicator_add_candidate(candidates, seen, tool_object_class_full_name(component_object), "component.className")
  applicator_add_candidate(candidates, seen, tool_object_full_name(data_struct), "dataStruct.fullName")
  applicator_add_candidate(candidates, seen, tool_object_class_full_name(data_struct), "dataStruct.className")

  local component_name = ""
  if candidates[1] then
    component_name = candidates[1].value
  elseif component_address ~= "" then
    component_name = component_address
  end

  return {
    kind = "applicator.component.apply",
    functionName = "ServerAddComponent",
    component = component_name,
    componentAddress = component_address,
    componentFullName = tool_object_full_name(component_object),
    componentClassName = tool_object_class_full_name(component_object),
    componentDataStructAddress = data_struct_address,
    componentDataStructName = tool_object_full_name(data_struct),
    componentCandidates = candidates,
    contextAddress = tool_object_address(context),
    contextFullName = tool_object_full_name(context),
    contextClassName = tool_object_class_full_name(context),
    contextUnwrapped = context_unwrapped == true,
    componentUnwrapped = component_unwrapped == true,
    hasBrickHandleParam = brick_handle_param ~= nil,
    decision = "pending",
    denied = false,
    paramNulled = false,
    blockMode = "",
  }
end

local function applicator_evaluate_candidate(event)
  for _, candidate in ipairs(event.componentCandidates or {}) do
    local access = BMF.permissions.evaluateApplicatorComponentAccess({
      component = candidate.value,
    })
    if access.ok and access.data and access.data.allowed == false then
      return access, candidate
    end
  end
  if event.component and event.component ~= "" and not tostring(event.component):match("^0x") then
    local access = BMF.permissions.evaluateApplicatorComponentAccess({
      component = event.component,
    })
    if access.ok and access.data and access.data.allowed == false then
      return access, { value = event.component, source = "event.component" }
    end
  end
  return nil, nil
end

local function applicator_run_handlers(event)
  local handler_results = {}
  local denied = false
  local denial = nil

  local access, candidate = applicator_evaluate_candidate(event)
  if access then
    denied = true
    denial = {
      owner = "core-policy",
      code = tostring(access.code or "APPLICATOR_COMPONENT_DENIED"),
      message = tostring(access.message or "Applicator component denied"),
      candidate = candidate,
      access = access.data or {},
    }
  end

  for id, registered in pairs(state.tools.applicator.handlers or {}) do
    local ok, response = pcall(registered.handler, copy_table(event))
    if not ok then
      record_plugin_error(registered.owner or "unknown", "onApplicatorComponentApply", response, event)
      handler_results[#handler_results + 1] = {
        id = id,
        owner = registered.owner or "",
        ok = false,
        error = tostring(response),
      }
    else
      local response_denied = false
      if response == false then
        response_denied = true
      elseif type(response) == "table" then
        response_denied = response.ok == false
          or (type(response.data) == "table" and response.data.allowed == false)
      end
      handler_results[#handler_results + 1] = {
        id = id,
        owner = registered.owner or "",
        ok = true,
        denied = response_denied,
        code = type(response) == "table" and tostring(response.code or "") or "",
      }
      if response_denied and not denied then
        denied = true
        denial = {
          owner = registered.owner or "",
          code = type(response) == "table" and tostring(response.code or "APPLICATOR_COMPONENT_DENIED") or "APPLICATOR_COMPONENT_DENIED",
          message = type(response) == "table" and tostring(response.message or "Applicator component denied") or "Applicator component denied",
          access = type(response) == "table" and type(response.data) == "table" and response.data or {},
        }
      end
    end
  end

  return denied, denial, handler_results
end

local function applicator_handle_server_add_component(context_param, brick_handle_param, component_type_param)
  local event = applicator_build_event(context_param, brick_handle_param, component_type_param)
  local denied, denial, handler_results = applicator_run_handlers(event)

  event.handlerResults = handler_results
  event.denied = denied == true
  if denial then
    event.decision = tostring(denial.code or "APPLICATOR_COMPONENT_DENIED")
    event.deniedBy = tostring(denial.owner or "")
    event.denialMessage = tostring(denial.message or "")
    if type(denial.candidate) == "table" then
      event.deniedCandidate = tostring(denial.candidate.value or "")
      event.deniedCandidateSource = tostring(denial.candidate.source or "")
    end
  else
    event.decision = "allowed"
  end

  if denied then
    state.tools.applicator.denied_events = state.tools.applicator.denied_events + 1
    if tool_param_set(component_type_param, nil) then
      event.paramNulled = true
      event.blockMode = "component-param-nulled"
      state.tools.applicator.param_null_events = state.tools.applicator.param_null_events + 1
    else
      event.blockMode = "deny-recorded-param-set-unavailable"
    end
    audit_record("applicator.component.denied", event, {
      source = "framework",
      severity = "warn",
      ok = event.paramNulled == true,
      code = event.decision,
    })
  else
    state.tools.applicator.allowed_events = state.tools.applicator.allowed_events + 1
  end

  applicator_record_event(event)
  return nil
end

local function ensure_applicator_component_hook()
  local app = state.tools.applicator
  if app.registered then
    return result(true, "OK", "Applicator component hook already registered", {
      hookPath = app.hook_path,
      preId = app.pre_id,
      postId = app.post_id,
    })
  end
  if app.registering then
    return result(false, "HOOK_REGISTERING", "Applicator component hook registration is already in progress")
  end
  if state.config.allowUnsafeApplicatorLuaHook ~= true then
    app.enabled = false
    app.last_error = "Unsafe UE4SS Lua RegisterHook path is disabled; ServerAddComponent struct parameters crash while being marshaled to Lua on Brickadia CL13530"
    return result(false, "APPLICATOR_LUA_HOOK_UNSAFE", app.last_error, {
      hookMode = "unsafe-lua-registerhook-disabled",
      optInConfig = "allowUnsafeApplicatorLuaHook",
      crashSignature = "UE4SS.dll!RC::LuaType::push_structproperty",
    })
  end
  if type(RegisterHook) ~= "function" then
    app.last_error = "RegisterHook is unavailable"
    return result(false, "REGISTER_HOOK_UNAVAILABLE", app.last_error)
  end

  app.registering = true
  BMF.tools.applicator.refreshComponentCache()
  local errors = {}
  for _, hook_path in ipairs(APPLICATOR_HOOK_CANDIDATES) do
    local callback = function(Context, BrickHandle, ComponentType)
      return applicator_handle_server_add_component(Context, BrickHandle, ComponentType)
    end
    local ok, pre_id, post_id = pcall(RegisterHook, hook_path, callback)
    if ok and type(pre_id) == "number" and type(post_id) == "number" then
      app.callback = callback
      app.hook_path = hook_path
      app.pre_id = pre_id
      app.post_id = post_id
      app.registered = true
      app.enabled = true
      app.registering = false
      app.last_error = ""
      log("info", "registered applicator component hook path=" .. hook_path)
      return result(true, "OK", "Applicator component hook registered", {
        hookPath = hook_path,
        preId = pre_id,
        postId = post_id,
      })
    end
    errors[#errors + 1] = hook_path .. ":" .. tostring(pre_id or "unknown")
  end

  app.registering = false
  app.last_error = table.concat(errors, " | ")
  return result(false, "APPLICATOR_HOOK_REGISTER_FAILED", app.last_error, {
    errors = errors,
  })
end

function BMF.tools.onApplicatorComponentApply(handler, options)
  if type(handler) ~= "function" then
    return result(false, "INVALID_HANDLER", "handler function is required")
  end
  options = type(options) == "table" and options or {}
  local app = state.tools.applicator
  local id = app.next_handler_id
  app.next_handler_id = id + 1
  app.handlers[id] = {
    id = id,
    owner = tostring(options.owner or options.plugin or "anonymous"),
    handler = handler,
  }
  local hook = ensure_applicator_component_hook()
  return result(hook.ok, hook.code, hook.message, {
    handlerId = id,
    owner = app.handlers[id].owner,
    hookRegistered = app.registered == true,
    unsafeLuaHookAllowed = state.config.allowUnsafeApplicatorLuaHook == true,
    hookPath = app.hook_path,
    hook = hook.data or {},
    lines = {
      "handler_id=" .. tostring(id),
      "owner=" .. tostring(app.handlers[id].owner),
      "hook_registered=" .. tostring(app.registered == true),
      "unsafe_lua_hook_allowed=" .. tostring(state.config.allowUnsafeApplicatorLuaHook == true),
      "hook_path=" .. tostring(app.hook_path or ""),
      "code=" .. tostring(hook.code or ""),
    },
  })
end

remove_tool_handlers_for_owner = function(owner)
  local removed = 0
  local owner_name = tostring(owner or "")
  for id, registered in pairs(state.tools.applicator.handlers or {}) do
    if tostring(registered.owner or "") == owner_name then
      state.tools.applicator.handlers[id] = nil
      removed = removed + 1
    end
  end
  return removed
end

function BMF.tools.applicator.status(options)
  options = type(options) == "table" and options or {}
  if options.refresh == true then
    BMF.tools.applicator.refreshComponentCache()
  end

  local app = state.tools.applicator
  local handler_count = 0
  local handlers = {}
  for id, registered in pairs(app.handlers or {}) do
    handler_count = handler_count + 1
    handlers[#handlers + 1] = {
      id = id,
      owner = tostring(registered.owner or ""),
    }
  end
  table.sort(handlers, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)

  local cache_count = 0
  local cache_lines = {}
  for address, cached in pairs(app.component_cache or {}) do
    cache_count = cache_count + 1
    cache_lines[#cache_lines + 1] =
      "component_cache_" .. tostring(cache_count) .. "=" ..
      tostring(cached.name or "") .. "|" .. tostring(address) .. "|source=" .. tostring(cached.source or "")
  end
  table.sort(cache_lines)

  local last = app.last_event or {}
  local lines = {
    "registered=" .. tostring(app.registered == true),
    "enabled=" .. tostring(app.enabled == true),
    "unsafe_lua_hook_allowed=" .. tostring(state.config.allowUnsafeApplicatorLuaHook == true),
    "hook_path=" .. tostring(app.hook_path or ""),
    "pre_id=" .. tostring(app.pre_id or ""),
    "post_id=" .. tostring(app.post_id or ""),
    "handler_count=" .. tostring(handler_count),
    "total_events=" .. tostring(app.total_events or 0),
    "allowed_events=" .. tostring(app.allowed_events or 0),
    "denied_events=" .. tostring(app.denied_events or 0),
    "param_null_events=" .. tostring(app.param_null_events or 0),
    "last_component=" .. tostring(last.component or ""),
    "last_component_address=" .. tostring(last.componentAddress or ""),
    "last_denied=" .. tostring(last.denied == true),
    "last_decision=" .. tostring(last.decision or ""),
    "last_block_mode=" .. tostring(last.blockMode or ""),
    "cache_count=" .. tostring(cache_count),
    "trace_path=" .. tostring(APPLICATOR_TRACE_PATH),
    "last_error=" .. tostring(app.last_error or ""),
  }
  for _, cache_line in ipairs(cache_lines) do
    lines[#lines + 1] = cache_line
  end

  return result(true, "OK", "Applicator hook status collected", {
    registered = app.registered == true,
    enabled = app.enabled == true,
    unsafeLuaHookAllowed = state.config.allowUnsafeApplicatorLuaHook == true,
    hookPath = app.hook_path,
    preId = app.pre_id,
    postId = app.post_id,
    handlerCount = handler_count,
    handlers = handlers,
    totalEvents = app.total_events or 0,
    allowedEvents = app.allowed_events or 0,
    deniedEvents = app.denied_events or 0,
    paramNullEvents = app.param_null_events or 0,
    recentEvents = applicator_recent_events(options.limit or 10),
    lastEvent = copy_table(last),
    componentCache = copy_table(app.component_cache or {}),
    componentCacheNotes = copy_table(app.component_cache_notes or {}),
    tracePath = APPLICATOR_TRACE_PATH,
    lastError = app.last_error or "",
    lines = lines,
  })
end

local TREE_CUT_TRACE_PATH = RUNTIME_DIR .. "/logs/treecut-trace.jsonl"
local TREE_CUT_APPLY_DAMAGE_HOOK_CANDIDATES = {
  "Function /Script/Engine.GameplayStatics.ApplyDamage",
  "Function /Script/Engine.GameplayStatics:ApplyDamage",
  "/Script/Engine.GameplayStatics:ApplyDamage",
  "/Script/Engine.GameplayStatics.ApplyDamage",
  "ApplyDamage",
}

local TREE_CUT_MELEE_HOOK_CANDIDATES = {
  "Function /Script/Brickadia.BRWeaponBase.MulticastReplicateAcceleratedMeleeExplosion",
  "Function /Script/Brickadia.BRWeaponBase:MulticastReplicateAcceleratedMeleeExplosion",
  "/Script/Brickadia.BRWeaponBase:MulticastReplicateAcceleratedMeleeExplosion",
  "/Script/Brickadia.BRWeaponBase.MulticastReplicateAcceleratedMeleeExplosion",
  "MulticastReplicateAcceleratedMeleeExplosion",
}
local TREE_CUT_MELEE_LUA_HOOK_SUPPORTED = false
local TREE_CUT_MELEE_LUA_HOOK_DISABLED_REASON =
  "MulticastReplicateAcceleratedMeleeExplosion has struct parameters that crash UE4SS Lua RegisterHook; use raw ProcessEvent/native capture instead"

local TREE_CUT_SUMMARY_PROPERTIES = {
  "DamageType",
  "DamageTypeClass",
  "DamageClass",
  "TargetComponent",
  "Target",
  "Owner",
  "Instigator",
  "Weapon",
  "WeaponClass",
  "Item",
  "ItemClass",
  "ItemType",
  "DisplayName",
  "Name",
}

local function tree_cut_trim_line(value, max_length)
  local text = trim_string(value or "")
  text = text:gsub("[\r\n|]", " ")
  max_length = tonumber(max_length) or 180
  if #text > max_length then
    return text:sub(1, max_length - 3) .. "..."
  end
  return text
end

local function tree_cut_value_string(value)
  local ok, text = pcall(tostring, value)
  if ok then
    return tree_cut_trim_line(text, 180)
  end
  return "<unstringifiable:" .. type(value) .. ">"
end

local function tree_cut_object_name(object)
  if not tool_object_valid(object) or type(object.GetName) ~= "function" then
    return ""
  end
  local ok, name = pcall(function()
    return object:GetName()
  end)
  if ok and name ~= nil then
    local text = tree_cut_trim_line(name, 160)
    if text ~= "." and text ~= "" then
      return text
    end
  end
  return ""
end

local function tree_cut_value_label(value)
  local resolved = tool_param_get(value)
  local value_type = type(resolved)
  if resolved == nil then
    return ""
  end
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return tree_cut_value_string(resolved)
  end
  if value_type == "userdata" then
    local parts = {}
    local full_name = tool_object_full_name(resolved)
    local name = tree_cut_object_name(resolved)
    local class_name = tool_object_class_full_name(resolved)
    local address = tool_object_address(resolved)
    if full_name ~= "" then
      parts[#parts + 1] = full_name
    end
    if name ~= "" and name ~= full_name then
      parts[#parts + 1] = "name=" .. name
    end
    if class_name ~= "" then
      parts[#parts + 1] = "class=" .. class_name
    end
    if address ~= "" then
      parts[#parts + 1] = "addr=" .. address
    end
    if #parts > 0 then
      return tree_cut_trim_line(table.concat(parts, " "), 220)
    end
  end
  return tree_cut_value_string(resolved)
end

local function tree_cut_outer_summary(object)
  if not tool_object_valid(object) or type(object.GetOuter) ~= "function" then
    return nil
  end
  local ok, outer = pcall(function()
    return object:GetOuter()
  end)
  if not ok or not tool_object_valid(outer) then
    return nil
  end
  return {
    address = tool_object_address(outer),
    name = tree_cut_object_name(outer),
    fullName = tool_object_full_name(outer),
    className = tool_object_class_full_name(outer),
  }
end

local function tree_cut_try_property(object, property_name)
  if not tool_object_valid(object) or type(object.GetPropertyValue) ~= "function" then
    return nil
  end
  local ok, value = pcall(function()
    return object:GetPropertyValue(property_name)
  end)
  if ok and value ~= nil then
    return value
  end
  return nil
end

local function tree_cut_collect_properties(object)
  local properties = {}
  if not tool_object_valid(object) then
    return properties
  end
  for _, property_name in ipairs(TREE_CUT_SUMMARY_PROPERTIES) do
    local value = tree_cut_try_property(object, property_name)
    if value ~= nil then
      properties[property_name] = tree_cut_value_label(value)
    end
  end
  return properties
end

local function tree_cut_summary(value, label)
  local raw_type = type(value)
  local resolved, unwrapped = tool_param_get(value)
  local resolved_type = type(resolved)
  local summary = {
    label = tostring(label or ""),
    rawType = raw_type,
    resolvedType = resolved_type,
    unwrapped = unwrapped == true,
    address = tool_object_address(resolved),
    fullName = tool_object_full_name(resolved),
    name = tree_cut_object_name(resolved),
    className = tool_object_class_full_name(resolved),
    outer = tree_cut_outer_summary(resolved),
    properties = tree_cut_collect_properties(resolved),
    valid = tool_object_valid(resolved),
    text = "",
  }

  if resolved_type == "string" or resolved_type == "number" or resolved_type == "boolean" then
    summary.text = tree_cut_value_string(resolved)
  elseif summary.fullName == "" and summary.className == "" and summary.address == "" and summary.name == "" then
    summary.text = tree_cut_value_string(resolved)
  end

  return summary
end

local function tree_cut_summary_text(summary)
  if type(summary) ~= "table" then
    return ""
  end
  if trim_string(summary.fullName or "") ~= "" then
    return summary.fullName
  end
  if trim_string(summary.name or "") ~= "" then
    return summary.name
  end
  if trim_string(summary.className or "") ~= "" then
    return summary.className
  end
  if trim_string(summary.text or "") ~= "" then
    return summary.text
  end
  return tostring(summary.address or "")
end

local function tree_cut_summary_has_terms(summary, terms)
  local property_text = ""
  if type(summary and summary.properties) == "table" then
    local parts = {}
    for key, value in pairs(summary.properties) do
      parts[#parts + 1] = tostring(key or "") .. "=" .. tostring(value or "")
    end
    property_text = table.concat(parts, " ")
  end
  local outer = type(summary and summary.outer) == "table" and summary.outer or {}
  local text = (
    tostring(summary and summary.fullName or "") .. " " ..
    tostring(summary and summary.name or "") .. " " ..
    tostring(summary and summary.className or "") .. " " ..
    tostring(summary and summary.text or "") .. " " ..
    tostring(summary and summary.address or "") .. " " ..
    tostring(outer.fullName or "") .. " " ..
    tostring(outer.name or "") .. " " ..
    tostring(outer.className or "") .. " " ..
    property_text
  ):lower()
  for _, term in ipairs(terms or {}) do
    if text:find(tostring(term):lower(), 1, true) then
      return true
    end
  end
  return false
end

local function tree_cut_hook_count()
  local count = 0
  for _ in ipairs(state.tools.tree_cut_trace.hooks or {}) do
    count = count + 1
  end
  return count
end

local function tree_cut_has_hook(kind)
  for _, hook in ipairs(state.tools.tree_cut_trace.hooks or {}) do
    if tostring(hook.kind or "") == tostring(kind or "") then
      return true
    end
  end
  return false
end

local function tree_cut_set_limits(options)
  local trace = state.tools.tree_cut_trace
  local max_events = math.floor(finite_number(options and options.maxEvents, trace.max_events or 100))
  if max_events < 10 then
    max_events = 10
  elseif max_events > 500 then
    max_events = 500
  end
  trace.max_events = max_events

  local sample_limit = math.floor(finite_number(options and options.sampleLimit, trace.sample_limit or 200))
  if sample_limit < 1 then
    sample_limit = 1
  elseif sample_limit > 5000 then
    sample_limit = 5000
  end
  trace.sample_limit = sample_limit
end

local function tree_cut_record_event(event)
  local trace = state.tools.tree_cut_trace
  trace.sample_count = (trace.sample_count or 0) + 1
  trace.total_events = (trace.total_events or 0) + 1
  event.sequence = trace.total_events
  event.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

  if event.kind == "applyDamage" then
    trace.apply_damage_events = (trace.apply_damage_events or 0) + 1
  elseif event.kind == "meleeExplosion" then
    trace.melee_events = (trace.melee_events or 0) + 1
  end
  if event.handaxe == true then
    trace.handaxe_events = (trace.handaxe_events or 0) + 1
  end
  if event.treeLike == true then
    trace.tree_like_events = (trace.tree_like_events or 0) + 1
  end
  if event.candidate == true then
    trace.candidate_events = (trace.candidate_events or 0) + 1
  end

  trace.last_event = copy_table(event)
  trace.events[#trace.events + 1] = copy_table(event)
  while #trace.events > trace.max_events do
    table.remove(trace.events, 1)
  end
  append_file(TREE_CUT_TRACE_PATH, json_encode(event) .. "\n")

  if trace.sample_count >= trace.sample_limit then
    trace.enabled = false
    trace.last_error = "sample limit reached; callbacks are idle until bmf.tools.treecut.trace.enable or disable"
    log("warn", "tree-cut trace sample limit reached; trace callbacks idled", {
      sampleLimit = trace.sample_limit,
      totalEvents = trace.total_events,
    })
  end
end

local function tree_cut_build_apply_damage_event(Context, DamagedActor, BaseDamage, EventInstigator, DamageCauser, DamageTypeClass)
  local event = {
    kind = "applyDamage",
    hitEvent = false,
    damageEvent = true,
    context = tree_cut_summary(Context, "context"),
    damagedActor = tree_cut_summary(DamagedActor, "damagedActor"),
    baseDamage = tree_cut_summary(BaseDamage, "baseDamage"),
    eventInstigator = tree_cut_summary(EventInstigator, "eventInstigator"),
    damageCauser = tree_cut_summary(DamageCauser, "damageCauser"),
    damageTypeClass = tree_cut_summary(DamageTypeClass, "damageTypeClass"),
  }
  event.handaxe = tree_cut_summary_has_terms(event.damageTypeClass, { "handaxe", "hand axe" })
    or tree_cut_summary_has_terms(event.damageCauser, { "handaxe", "hand axe" })
  event.treeLike = tree_cut_summary_has_terms(event.damagedActor, { "tree", "target" })
  event.candidate = event.handaxe == true and event.treeLike == true
  return event
end

local function tree_cut_handle_apply_damage(Context, DamagedActor, BaseDamage, EventInstigator, DamageCauser, DamageTypeClass)
  local trace = state.tools.tree_cut_trace
  if trace.enabled ~= true then
    return nil
  end
  local ok, event_or_error = pcall(tree_cut_build_apply_damage_event, Context, DamagedActor, BaseDamage, EventInstigator, DamageCauser, DamageTypeClass)
  if ok and type(event_or_error) == "table" then
    tree_cut_record_event(event_or_error)
  else
    trace.last_error = tostring(event_or_error or "ApplyDamage trace callback failed")
  end
  return nil
end

local function tree_cut_build_melee_event(Context, ParamA, ParamB, ParamC, ParamD)
  local event = {
    kind = "meleeExplosion",
    hitEvent = true,
    damageEvent = false,
    context = tree_cut_summary(Context, "context"),
    paramA = tree_cut_summary(ParamA, "paramA"),
    paramB = tree_cut_summary(ParamB, "paramB"),
    paramC = tree_cut_summary(ParamC, "paramC"),
    paramD = tree_cut_summary(ParamD, "paramD"),
  }
  event.handaxe = tree_cut_summary_has_terms(event.context, { "handaxe", "hand axe" })
    or tree_cut_summary_has_terms(event.paramA, { "handaxe", "hand axe" })
    or tree_cut_summary_has_terms(event.paramB, { "handaxe", "hand axe" })
  event.treeLike = tree_cut_summary_has_terms(event.context, { "tree", "target" })
    or tree_cut_summary_has_terms(event.paramA, { "tree", "target" })
    or tree_cut_summary_has_terms(event.paramB, { "tree", "target" })
  event.candidate = event.handaxe == true and event.treeLike == true
  return event
end

local function tree_cut_handle_melee(Context, ParamA, ParamB, ParamC, ParamD)
  local trace = state.tools.tree_cut_trace
  if trace.enabled ~= true then
    return nil
  end
  local ok, event_or_error = pcall(tree_cut_build_melee_event, Context, ParamA, ParamB, ParamC, ParamD)
  if ok and type(event_or_error) == "table" then
    tree_cut_record_event(event_or_error)
  else
    trace.last_error = tostring(event_or_error or "melee trace callback failed")
  end
  return nil
end

local function tree_cut_register_hook(kind, candidates, callback)
  if type(RegisterHook) ~= "function" then
    return nil, { "RegisterHook unavailable" }
  end
  local errors = {}
  for _, hook_path in ipairs(candidates or {}) do
    local ok, pre_id, post_id = pcall(RegisterHook, hook_path, callback)
    if ok and type(pre_id) == "number" and type(post_id) == "number" then
      return {
        kind = kind,
        path = hook_path,
        preId = pre_id,
        postId = post_id,
        callback = callback,
      }, errors
    end
    errors[#errors + 1] = hook_path .. ":" .. tostring(pre_id or "unknown")
  end
  return nil, errors
end

local function tree_cut_recent_events(limit)
  limit = tonumber(limit) or 10
  if limit < 1 then
    limit = 1
  elseif limit > state.tools.tree_cut_trace.max_events then
    limit = state.tools.tree_cut_trace.max_events
  end
  local events = {}
  local source = state.tools.tree_cut_trace.events or {}
  local start_index = math.max(1, #source - limit + 1)
  for index = start_index, #source do
    events[#events + 1] = copy_table(source[index])
  end
  return events
end

local function tree_cut_event_line(event, index)
  local damaged = tree_cut_trim_line(tree_cut_summary_text(event.damagedActor), 140)
  local damage_type = tree_cut_trim_line(tree_cut_summary_text(event.damageTypeClass), 140)
  local causer = tree_cut_trim_line(tree_cut_summary_text(event.damageCauser), 140)
  local context = tree_cut_trim_line(tree_cut_summary_text(event.context), 140)
  return "event_" .. tostring(index) ..
    "=seq=" .. tostring(event.sequence or "") ..
    "|kind=" .. tostring(event.kind or "") ..
    "|hit_event=" .. tostring(event.hitEvent == true) ..
    "|damage_event=" .. tostring(event.damageEvent == true) ..
    "|handaxe=" .. tostring(event.handaxe == true) ..
    "|tree_like=" .. tostring(event.treeLike == true) ..
    "|candidate=" .. tostring(event.candidate == true) ..
    "|damaged=" .. damaged ..
    "|damage_type=" .. damage_type ..
    "|causer=" .. causer ..
    "|context=" .. context
end

local function tree_cut_hook_lines()
  local lines = {}
  for index, hook in ipairs(state.tools.tree_cut_trace.hooks or {}) do
    lines[#lines + 1] =
      "hook_" .. tostring(index) ..
      "=" .. tostring(hook.kind or "") ..
      "|path=" .. tostring(hook.path or "") ..
      "|pre_id=" .. tostring(hook.preId or "") ..
      "|post_id=" .. tostring(hook.postId or "")
  end
  return lines
end

function BMF.tools.treeCutTrace.enable(options)
  options = type(options) == "table" and options or {}
  local trace = state.tools.tree_cut_trace
  tree_cut_set_limits(options)
  local requested_apply_damage = options.includeApplyDamage ~= false
  trace.include_apply_damage = false
  local requested_melee_hook = options.includeMelee == true
  trace.include_melee = requested_melee_hook and TREE_CUT_MELEE_LUA_HOOK_SUPPORTED == true
  trace.last_error = ""

  if requested_apply_damage then
    trace.last_error = "Lua ApplyDamage trace is disabled after a UE4SS Lua callback crash; use the BMFSocket native tree-cut probe instead"
    return result(false, "TREE_CUT_TRACE_APPLYDAMAGE_DISABLED", trace.last_error, {
      lines = {
        "enabled=false",
        "registered=" .. tostring(trace.registered == true),
        "include_apply_damage=false",
        "native_probe=BMFSocket",
        "last_error=" .. tostring(trace.last_error or ""),
      },
    })
  end

  if trace.registering then
    return result(false, "TREE_CUT_TRACE_REGISTERING", "Tree-cut trace hook registration is already in progress")
  end
  if type(RegisterHook) ~= "function" then
    trace.last_error = "RegisterHook is unavailable"
    return result(false, "REGISTER_HOOK_UNAVAILABLE", trace.last_error)
  end

  trace.registering = true
  local errors = {}
  if requested_melee_hook and TREE_CUT_MELEE_LUA_HOOK_SUPPORTED ~= true then
    errors[#errors + 1] = "meleeExplosion:" .. TREE_CUT_MELEE_LUA_HOOK_DISABLED_REASON
  end

  if trace.include_apply_damage == true and not tree_cut_has_hook("applyDamage") then
    local callback = function(Context, DamagedActor, BaseDamage, EventInstigator, DamageCauser, DamageTypeClass)
      return tree_cut_handle_apply_damage(Context, DamagedActor, BaseDamage, EventInstigator, DamageCauser, DamageTypeClass)
    end
    local hook, hook_errors = tree_cut_register_hook("applyDamage", TREE_CUT_APPLY_DAMAGE_HOOK_CANDIDATES, callback)
    if hook then
      trace.hooks[#trace.hooks + 1] = hook
      log("info", "registered tree-cut ApplyDamage trace hook path=" .. tostring(hook.path or ""))
    else
      for _, item in ipairs(hook_errors or {}) do
        errors[#errors + 1] = "applyDamage:" .. tostring(item)
      end
    end
  end

  if trace.include_melee == true and not tree_cut_has_hook("meleeExplosion") then
    local callback = function(Context, ParamA, ParamB, ParamC, ParamD)
      return tree_cut_handle_melee(Context, ParamA, ParamB, ParamC, ParamD)
    end
    local hook, hook_errors = tree_cut_register_hook("meleeExplosion", TREE_CUT_MELEE_HOOK_CANDIDATES, callback)
    if hook then
      trace.hooks[#trace.hooks + 1] = hook
      log("info", "registered tree-cut melee trace hook path=" .. tostring(hook.path or ""))
    else
      for _, item in ipairs(hook_errors or {}) do
        errors[#errors + 1] = "meleeExplosion:" .. tostring(item)
      end
    end
  end

  trace.registering = false
  trace.registered = tree_cut_hook_count() > 0
  if tree_cut_hook_count() == 0 then
    trace.enabled = false
    trace.last_error = table.concat(errors, " | ")
    return result(false, "TREE_CUT_TRACE_HOOK_FAILED", trace.last_error, {
      errors = errors,
      lines = {
        "enabled=false",
        "registered=" .. tostring(trace.registered == true),
        "last_error=" .. tostring(trace.last_error or ""),
      },
    })
  end

  if #errors > 0 then
    trace.last_error = table.concat(errors, " | ")
  end
  trace.enabled = true
  trace.sample_count = 0
  trace.last_enabled_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  write_status()

  local lines = {
    "enabled=true",
    "registered=" .. tostring(trace.registered == true),
    "include_apply_damage=" .. tostring(trace.include_apply_damage == true),
    "include_melee=" .. tostring(trace.include_melee == true),
    "melee_lua_hook_supported=" .. tostring(TREE_CUT_MELEE_LUA_HOOK_SUPPORTED == true),
    "hook_count=" .. tostring(tree_cut_hook_count()),
    "max_events=" .. tostring(trace.max_events or 0),
    "sample_limit=" .. tostring(trace.sample_limit or 0),
    "trace_path=" .. tostring(TREE_CUT_TRACE_PATH),
    "last_error=" .. tostring(trace.last_error or ""),
  }
  for _, line in ipairs(tree_cut_hook_lines()) do
    lines[#lines + 1] = line
  end

  return result(true, "OK", "Tree-cut trace enabled", {
    enabled = trace.enabled == true,
    registered = trace.registered == true,
    includeApplyDamage = trace.include_apply_damage == true,
    includeMelee = trace.include_melee == true,
    meleeLuaHookSupported = TREE_CUT_MELEE_LUA_HOOK_SUPPORTED == true,
    hookCount = tree_cut_hook_count(),
    maxEvents = trace.max_events,
    sampleLimit = trace.sample_limit,
    tracePath = TREE_CUT_TRACE_PATH,
    errors = errors,
    lines = lines,
  })
end

function BMF.tools.treeCutTrace.disable(options)
  options = type(options) == "table" and options or {}
  local trace = state.tools.tree_cut_trace
  trace.enabled = false
  trace.last_disabled_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local errors = {}
  local remaining = {}
  if type(UnregisterHook) == "function" then
    for _, hook in ipairs(trace.hooks or {}) do
      local ok, err = pcall(UnregisterHook, hook.path, hook.preId, hook.postId)
      if not ok then
        errors[#errors + 1] = tostring(hook.kind or "") .. ":" .. tostring(err or "unregister failed")
        remaining[#remaining + 1] = hook
      end
    end
    trace.hooks = remaining
  elseif tree_cut_hook_count() > 0 then
    errors[#errors + 1] = "UnregisterHook unavailable; callbacks remain registered but idle"
  end

  trace.registered = tree_cut_hook_count() > 0
  trace.registering = false
  if #errors > 0 then
    trace.last_error = table.concat(errors, " | ")
  else
    trace.last_error = ""
  end
  write_status()

  local lines = {
    "enabled=false",
    "registered=" .. tostring(trace.registered == true),
    "hook_count=" .. tostring(tree_cut_hook_count()),
    "reason=" .. tostring(options.reason or ""),
    "last_error=" .. tostring(trace.last_error or ""),
  }
  for _, line in ipairs(tree_cut_hook_lines()) do
    lines[#lines + 1] = line
  end

  return result(#errors == 0, #errors == 0 and "OK" or "TREE_CUT_TRACE_DISABLE_PARTIAL", "Tree-cut trace disabled", {
    enabled = trace.enabled == true,
    registered = trace.registered == true,
    hookCount = tree_cut_hook_count(),
    errors = errors,
    lines = lines,
  })
end

function BMF.tools.treeCutTrace.status()
  local trace = state.tools.tree_cut_trace
  local last = trace.last_event or {}
  local lines = {
    "enabled=" .. tostring(trace.enabled == true),
    "registered=" .. tostring(trace.registered == true),
    "registering=" .. tostring(trace.registering == true),
    "include_apply_damage=" .. tostring(trace.include_apply_damage == true),
    "include_melee=" .. tostring(trace.include_melee == true),
    "melee_lua_hook_supported=" .. tostring(TREE_CUT_MELEE_LUA_HOOK_SUPPORTED == true),
    "hook_count=" .. tostring(tree_cut_hook_count()),
    "total_events=" .. tostring(trace.total_events or 0),
    "apply_damage_events=" .. tostring(trace.apply_damage_events or 0),
    "melee_events=" .. tostring(trace.melee_events or 0),
    "handaxe_events=" .. tostring(trace.handaxe_events or 0),
    "tree_like_events=" .. tostring(trace.tree_like_events or 0),
    "candidate_events=" .. tostring(trace.candidate_events or 0),
    "recent_count=" .. tostring(#(trace.events or {})),
    "sample_count=" .. tostring(trace.sample_count or 0),
    "sample_limit=" .. tostring(trace.sample_limit or 0),
    "max_events=" .. tostring(trace.max_events or 0),
    "last_kind=" .. tostring(last.kind or ""),
    "last_handaxe=" .. tostring(last.handaxe == true),
    "last_tree_like=" .. tostring(last.treeLike == true),
    "last_candidate=" .. tostring(last.candidate == true),
    "last_enabled_at=" .. tostring(trace.last_enabled_at or ""),
    "last_disabled_at=" .. tostring(trace.last_disabled_at or ""),
    "trace_path=" .. tostring(TREE_CUT_TRACE_PATH),
    "last_error=" .. tostring(trace.last_error or ""),
  }
  for _, line in ipairs(tree_cut_hook_lines()) do
    lines[#lines + 1] = line
  end

  return result(true, "OK", "Tree-cut trace status collected", {
    enabled = trace.enabled == true,
    registered = trace.registered == true,
    registering = trace.registering == true,
    includeApplyDamage = trace.include_apply_damage == true,
    includeMelee = trace.include_melee == true,
    meleeLuaHookSupported = TREE_CUT_MELEE_LUA_HOOK_SUPPORTED == true,
    hookCount = tree_cut_hook_count(),
    totalEvents = trace.total_events or 0,
    applyDamageEvents = trace.apply_damage_events or 0,
    meleeEvents = trace.melee_events or 0,
    handaxeEvents = trace.handaxe_events or 0,
    treeLikeEvents = trace.tree_like_events or 0,
    candidateEvents = trace.candidate_events or 0,
    recentCount = #(trace.events or {}),
    sampleCount = trace.sample_count or 0,
    sampleLimit = trace.sample_limit or 0,
    maxEvents = trace.max_events or 0,
    lastEvent = copy_table(last),
    hooks = copy_table(trace.hooks or {}),
    tracePath = TREE_CUT_TRACE_PATH,
    lastError = trace.last_error or "",
    lines = lines,
  })
end

function BMF.tools.treeCutTrace.recent(options)
  options = type(options) == "table" and options or {}
  local events = tree_cut_recent_events(options.limit or 10)
  local lines = {
    "recent_count=" .. tostring(#events),
    "total_events=" .. tostring(state.tools.tree_cut_trace.total_events or 0),
    "trace_path=" .. tostring(TREE_CUT_TRACE_PATH),
  }
  for index, event in ipairs(events) do
    lines[#lines + 1] = tree_cut_event_line(event, index)
  end
  return result(true, "OK", "Recent tree-cut trace events collected", {
    events = events,
    count = #events,
    totalEvents = state.tools.tree_cut_trace.total_events or 0,
    tracePath = TREE_CUT_TRACE_PATH,
    lines = lines,
  })
end

function BMF.tools.treeCutTrace.clear()
  local trace = state.tools.tree_cut_trace
  trace.events = {}
  trace.sample_count = 0
  trace.total_events = 0
  trace.apply_damage_events = 0
  trace.melee_events = 0
  trace.handaxe_events = 0
  trace.tree_like_events = 0
  trace.candidate_events = 0
  trace.last_event = nil
  trace.last_error = ""
  return result(true, "OK", "Tree-cut trace counters cleared", {
    enabled = trace.enabled == true,
    registered = trace.registered == true,
    lines = {
      "enabled=" .. tostring(trace.enabled == true),
      "registered=" .. tostring(trace.registered == true),
      "total_events=0",
      "recent_count=0",
    },
  })
end

local function tree_cut_native_available()
  return type(BMFSocketTreeCutStart) == "function"
    and type(BMFSocketTreeCutStop) == "function"
    and type(BMFSocketTreeCutStatus) == "function"
    and type(BMFSocketTreeCutDrain) == "function"
end

local function tree_cut_handaxe_resolver_available()
  return type(BMFSocketTreeCutResolveHandaxe) == "function"
    and type(BMFSocketTreeCutSetHandaxeClass) == "function"
end

local function tree_cut_target_resolver_available()
  return type(BMFSocketTreeCutRefreshTargets) == "function"
end

local function tree_cut_tag_lookup_available()
  return type(BMFSocketTreeCutFindTag) == "function"
end

local function tree_cut_physical_available()
  return type(BMFSocketBrickPhysicalInspect) == "function"
    and type(BMFSocketBrickPhysicalSet) == "function"
end

local function tree_cut_probe_available()
  return type(BMFSocketTreeCutProbeStart) == "function"
    and type(BMFSocketTreeCutProbeStop) == "function"
    and type(BMFSocketTreeCutProbeStatus) == "function"
end

local TREE_CUT_HANDAXE_ASSET_CANDIDATES = {
  "/Game/Weapons/Melee/Handaxe/Weapon_Handaxe",
}

local TREE_CUT_HANDAXE_CLASS_CANDIDATES = {
  "/Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C",
  "Weapon_Handaxe_C",
  "Weapon_Handaxe",
}

local TREE_CUT_HANDAXE_FIND_OBJECT_SPECS = {
  { class = "BlueprintGeneratedClass", name = "Weapon_Handaxe_C" },
  { class = "Class", name = "Weapon_Handaxe_C" },
  { class = nil, name = "Weapon_Handaxe_C" },
  { class = nil, name = "Weapon_Handaxe" },
}

local function tree_cut_native_object_valid(object)
  if object == nil or type(object) ~= "userdata" then
    return false
  end
  if type(object.IsValid) ~= "function" then
    return true
  end
  local ok, valid = pcall(function()
    return object:IsValid()
  end)
  return ok and valid == true
end

local function tree_cut_native_object_address(object)
  if not tree_cut_native_object_valid(object) or type(object.GetAddress) ~= "function" then
    return ""
  end
  local ok, address = pcall(function()
    return object:GetAddress()
  end)
  if ok and address ~= nil then
    return tostring(address)
  end
  return ""
end

local function tree_cut_native_status_lines(status_text)
  local lines, fields = native_uobject_parse_lines(status_text)
  return lines, fields
end

local function tree_cut_native_update_status(status_text)
  local native = state.tools.tree_cut_native
  local lines, fields = tree_cut_native_status_lines(status_text)
  native.available = tree_cut_native_available()
  native.enabled = tostring(fields.enabled or "") == "true"
  native.started = tostring(fields.installed or "") == "true"
  native.last_status = tostring(status_text or "")
  native.last_error = tostring(fields.last_error or "")
  native.total_events = tonumber(fields.events) or native.total_events or 0
  return lines, fields
end

local function tree_cut_native_next_physical_sequence()
  local native = state.tools.tree_cut_native
  native.physical_sequence = (tonumber(native.physical_sequence) or 0) + 1
  return native.physical_sequence
end

local function tree_cut_native_store_physical_result(sequence, operation, brick_id, ok, response_or_error)
  local native = state.tools.tree_cut_native
  local text = tostring(response_or_error or "")
  local lines, fields = tree_cut_native_status_lines(text)
  local native_ok = ok == true and tostring(fields.ok or "") == "true"
  native.last_physical_result = {
    sequence = sequence,
    operation = tostring(operation or ""),
    brickId = tonumber(brick_id) or 0,
    ok = native_ok,
    code = tostring(fields.code or (ok and "" or "LUA_ERROR")),
    fields = fields,
    lines = lines,
    response = text,
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  if not native_ok then
    native.last_error = tostring(fields.detail or fields.code or text or "")
  end
  write_status()
  return native.last_physical_result
end

local function tree_cut_parse_brick_id(options)
  options = type(options) == "table" and options or {}
  local positional = type(options._positional) == "table" and options._positional or {}
  local brick_id = tonumber(options.brickid or options.brickId or options.id or positional[1] or 0) or 0
  if brick_id < 0 then
    brick_id = 0
  end
  return math.floor(brick_id)
end

local function brick_runtime_available()
  return tree_cut_physical_available()
end

local function brick_runtime_next_sequence()
  local runtime = state.tools.brick_runtime
  runtime.sequence = (tonumber(runtime.sequence) or 0) + 1
  return runtime.sequence
end

local function brick_runtime_store_result(sequence, operation, brick_id, ok, response_or_error)
  local runtime = state.tools.brick_runtime
  local text = tostring(response_or_error or "")
  local lines, fields = tree_cut_native_status_lines(text)
  local native_ok = ok == true and tostring(fields.ok or "") == "true"
  runtime.last_result = {
    sequence = sequence,
    operation = tostring(operation or ""),
    brickId = tonumber(brick_id) or 0,
    ok = native_ok,
    code = tostring(fields.code or (ok and "" or "LUA_ERROR")),
    fields = fields,
    lines = lines,
    response = text,
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  if not native_ok then
    runtime.last_error = tostring(fields.detail or fields.code or text or "")
  else
    runtime.last_error = ""
  end
  state.tools.tree_cut_native.last_physical_result = runtime.last_result
  write_status()
  return runtime.last_result
end

local function brick_runtime_parse_visible_arg(options, default_value)
  options = type(options) == "table" and options or {}
  local raw = options.visible
  if raw == nil then raw = options.visibility end
  if raw == nil then raw = options.isVisible end
  if raw == nil then
    return default_value or -1
  end
  if type(raw) == "boolean" then
    return raw and 1 or 0
  end
  local text = trim_string(raw)
  local lower = text:lower()
  if lower == "" or lower == "unchanged" or lower == "skip" or lower == "same" then
    return -1
  end
  if lower == "restore" or lower == "captured" then
    return -2
  end
  if lower == "1" or lower == "true" or lower == "yes" or lower == "on" or lower == "visible" then
    return 1
  end
  return 0
end

local function brick_runtime_parse_collision_arg(options, default_value)
  options = type(options) == "table" and options or {}
  local raw = options.collision
  if raw == nil then raw = options.collisionchannels end
  if raw == nil then raw = options.collisionChannels end
  if raw == nil then raw = options.channels end
  if raw == nil then
    return default_value or -2
  end
  local text = trim_string(raw)
  local lower = text:lower()
  if lower == "" or lower == "restore" or lower == "captured" then
    return -1
  end
  if lower == "unchanged" or lower == "skip" or lower == "same" then
    return -2
  end
  local value = tonumber(text) or 0
  if value < -2 then
    value = -2
  elseif value > 255 then
    value = 255
  end
  return math.floor(value)
end

local function brick_runtime_parse_context_arg(options)
  options = type(options) == "table" and options or {}
  local raw = options.context
  if raw == nil then raw = options.gridcontext end
  if raw == nil then raw = options.grid_context end
  if raw == nil then raw = options.gridcontextaddress end
  if raw == nil then raw = options.grid_context_address end
  local text = trim_string(raw or "")
  if text == "" or text:lower() == "none" then
    return ""
  end
  return text
end

function BMF.bricks.inspectRuntimeState(options)
  options = type(options) == "table" and options or {}
  local runtime = state.tools.brick_runtime
  local brick_id = tree_cut_parse_brick_id(options)
  if brick_id <= 0 then
    return result(false, "BRICK_RUNTIME_ID_REQUIRED", "brickid is required for runtime brick-state inspect", {
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_ID_REQUIRED",
        "brick_id=" .. tostring(brick_id),
      },
    })
  end
  if not brick_runtime_available() then
    runtime.last_error = "BMFSocket brick runtime helpers are unavailable"
    return result(false, "BRICK_RUNTIME_UNAVAILABLE", runtime.last_error, {
      brickId = brick_id,
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_UNAVAILABLE",
        "brick_id=" .. tostring(brick_id),
      },
    })
  end

  local sequence = brick_runtime_next_sequence()
  run_on_game_thread(function()
    local ok, response = pcall(BMFSocketBrickPhysicalInspect, brick_id)
    brick_runtime_store_result(sequence, "inspect", brick_id, ok, ok and response or tostring(response))
  end)

  return result(true, "OK", "Runtime brick-state inspect queued on the game thread", {
    queued = true,
    sequence = sequence,
    brickId = brick_id,
    lines = {
      "ok=true",
      "code=OK",
      "queued=true",
      "operation=inspect",
      "sequence=" .. tostring(sequence),
      "brick_id=" .. tostring(brick_id),
    },
  })
end

function BMF.bricks.setRuntimeState(options)
  options = type(options) == "table" and options or {}
  local runtime = state.tools.brick_runtime
  local brick_id = tree_cut_parse_brick_id(options)
  if brick_id <= 0 then
    return result(false, "BRICK_RUNTIME_ID_REQUIRED", "brickid is required for runtime brick-state set", {
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_ID_REQUIRED",
        "brick_id=" .. tostring(brick_id),
      },
    })
  end

  local confirm = tostring(options.confirm or "")
  local legacy_tree_confirm = options.legacyTreePhysical == true
  local required_confirm = legacy_tree_confirm and "tree-physical" or "brick-runtime"
  if confirm ~= required_confirm then
    return result(false, "BRICK_RUNTIME_CONFIRM_REQUIRED", "confirm=" .. required_confirm .. " is required for runtime brick-state set", {
      brickId = brick_id,
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_CONFIRM_REQUIRED",
        "brick_id=" .. tostring(brick_id),
        "required_confirm=" .. required_confirm,
      },
    })
  end
  if not brick_runtime_available() then
    runtime.last_error = "BMFSocket brick runtime helpers are unavailable"
    return result(false, "BRICK_RUNTIME_UNAVAILABLE", runtime.last_error, {
      brickId = brick_id,
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_UNAVAILABLE",
        "brick_id=" .. tostring(brick_id),
      },
    })
  end

  local visible = brick_runtime_parse_visible_arg(options, legacy_tree_confirm and 0 or -1)
  local collision = brick_runtime_parse_collision_arg(options, legacy_tree_confirm and -1 or -2)
  local context = brick_runtime_parse_context_arg(options)
  if context ~= "" and tostring(options.contextconfirm or options.context_confirm or "") ~= "brick-runtime-context" then
    return result(false, "BRICK_RUNTIME_CONTEXT_CONFIRM_REQUIRED", "contextConfirm=brick-runtime-context is required for explicit diagnostic grid contexts", {
      brickId = brick_id,
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_CONTEXT_CONFIRM_REQUIRED",
        "brick_id=" .. tostring(brick_id),
        "required_context_confirm=brick-runtime-context",
      },
    })
  end
  if visible == -1 and collision == -2 then
    return result(false, "BRICK_RUNTIME_STATE_NOOP", "Provide visible or collision to change runtime brick state", {
      brickId = brick_id,
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_STATE_NOOP",
        "brick_id=" .. tostring(brick_id),
        "visible_arg=" .. tostring(visible),
        "collision_channels=" .. tostring(collision),
      },
    })
  end

  local sequence = brick_runtime_next_sequence()
  run_on_game_thread(function()
    local ok, response = pcall(BMFSocketBrickPhysicalSet, brick_id, visible, collision, context)
    brick_runtime_store_result(sequence, "set", brick_id, ok, ok and response or tostring(response))
  end)

  return result(true, "OK", "Runtime brick-state set queued on the game thread", {
    queued = true,
    sequence = sequence,
    brickId = brick_id,
    visible = visible,
    collision = collision,
    context = context,
    lines = {
      "ok=true",
      "code=OK",
      "queued=true",
      "operation=set",
      "sequence=" .. tostring(sequence),
      "brick_id=" .. tostring(brick_id),
      "visible_arg=" .. tostring(visible),
      "collision_channels=" .. tostring(collision),
      "grid_context_override=" .. tostring(context),
    },
  })
end

function BMF.bricks.runtimeStateStatus()
  local last = state.tools.brick_runtime.last_result
  if type(last) ~= "table" then
    return result(false, "BRICK_RUNTIME_NO_RESULT", "No runtime brick-state operation has completed yet.", {
      lines = {
        "ok=false",
        "code=BRICK_RUNTIME_NO_RESULT",
      },
    })
  end
  local lines = {
    "sequence=" .. tostring(last.sequence or ""),
    "operation=" .. tostring(last.operation or ""),
    "brick_id=" .. tostring(last.brickId or ""),
    "completed_at=" .. tostring(last.at or ""),
  }
  for _, line in ipairs(last.lines or {}) do
    lines[#lines + 1] = tostring(line)
  end
  return result(last.ok == true, last.ok == true and "OK" or tostring(last.code or "BRICK_RUNTIME_FAILED"), "Last runtime brick-state operation result", {
    last = copy_table(last),
    fields = copy_table(last.fields or {}),
    lines = lines,
  })
end

function BMF.tools.treeCutNative.start(options)
  options = type(options) == "table" and options or {}
  local native = state.tools.tree_cut_native
  native.available = tree_cut_native_available()
  if not native.available then
    native.last_error = "BMFSocket tree-cut native helpers are unavailable"
    return result(false, "TREE_CUT_NATIVE_UNAVAILABLE", native.last_error, {
      lines = {
        "available=false",
        "enabled=false",
        "started=false",
        "last_error=" .. native.last_error,
      },
    })
  end

  local ok, started_or_error, status = pcall(BMFSocketTreeCutStart)
  if not ok or started_or_error == false then
    native.last_error = tostring(status or started_or_error or "BMFSocketTreeCutStart failed")
    return result(false, "TREE_CUT_NATIVE_START_FAILED", native.last_error, {
      lines = {
        "available=true",
        "enabled=false",
        "started=false",
        "last_error=" .. native.last_error,
      },
    })
  end

  native.last_started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local lines, fields = tree_cut_native_update_status(status or "")
  local auto_refresh = options.refreshTargets ~= false and BMF_env_bool("BMF_TREECUT_TARGET_AUTO_REFRESH", false)
  if auto_refresh and tree_cut_target_resolver_available() then
    local delay_ms = BMF_env_number("BMF_TREECUT_TARGET_REFRESH_DELAY_MS", 3000, 0)
    local scheduled = BMF_schedule_delayed_callback("tree_cut_target_refresh", delay_ms, function()
      run_on_game_thread(function()
        local refresh_ok, refresh_result = pcall(BMF.tools.treeCutNative.refreshTargets, {
          reason = tostring(options.reason or "start") .. "-auto",
        })
        if not refresh_ok or not refresh_result or refresh_result.ok ~= true then
          local detail = refresh_ok and tostring(refresh_result and refresh_result.message or "unknown") or tostring(refresh_result)
          log("warn", "tree-cut target auto-refresh failed: " .. detail)
        else
          log("info", "tree-cut target cache auto-refreshed")
        end
      end)
      return true
    end)
    if not scheduled then
      log("warn", "tree-cut target auto-refresh was not scheduled")
    end
  end
  log("info", "tree-cut native capture started reason=" .. tostring(options.reason or "manual"))
  write_status()
  return result(true, "OK", "Tree-cut native capture started", {
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutNative.stop(options)
  options = type(options) == "table" and options or {}
  local native = state.tools.tree_cut_native
  if not tree_cut_native_available() then
    native.available = false
    native.enabled = false
    native.last_error = "BMFSocket tree-cut native helpers are unavailable"
    return result(false, "TREE_CUT_NATIVE_UNAVAILABLE", native.last_error, {
      lines = {
        "available=false",
        "enabled=false",
        "started=false",
      },
    })
  end

  local ok, stopped_or_error, status = pcall(BMFSocketTreeCutStop)
  if not ok or stopped_or_error == false then
    native.last_error = tostring(status or stopped_or_error or "BMFSocketTreeCutStop failed")
    return result(false, "TREE_CUT_NATIVE_STOP_FAILED", native.last_error, {
      lines = {
        "available=true",
        "last_error=" .. native.last_error,
      },
    })
  end

  local lines, fields = tree_cut_native_update_status(status or "")
  log("info", "tree-cut native capture stopped reason=" .. tostring(options.reason or "manual"))
  write_status()
  return result(true, "OK", "Tree-cut native capture stopped", {
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutNative.status()
  local native = state.tools.tree_cut_native
  native.available = tree_cut_native_available()
  if not native.available then
    return result(false, "TREE_CUT_NATIVE_UNAVAILABLE", "BMFSocket tree-cut native helpers are unavailable", {
      lines = {
        "available=false",
        "enabled=false",
        "started=false",
      },
    })
  end

  local ok, status_or_error = pcall(BMFSocketTreeCutStatus)
  if not ok then
    native.last_error = tostring(status_or_error or "BMFSocketTreeCutStatus failed")
    return result(false, "TREE_CUT_NATIVE_STATUS_FAILED", native.last_error, {
      lines = {
        "available=true",
        "last_error=" .. native.last_error,
      },
    })
  end

  local lines, fields = tree_cut_native_update_status(status_or_error or "")
  return result(true, "OK", "Tree-cut native status collected", {
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutNative.refreshTargets(options)
  options = type(options) == "table" and options or {}
  local native = state.tools.tree_cut_native
  native.available = tree_cut_native_available()
  if not native.available or not tree_cut_target_resolver_available() then
    native.last_error = "BMFSocket tree-cut target resolver helpers are unavailable"
    return result(false, "TREE_CUT_TARGET_RESOLVER_UNAVAILABLE", native.last_error, {
      lines = {
        "available=" .. tostring(native.available == true),
        "target_resolver_available=" .. tostring(tree_cut_target_resolver_available()),
        "last_error=" .. native.last_error,
      },
    })
  end

  local ok, refreshed_or_error, status = pcall(BMFSocketTreeCutRefreshTargets)
  if not ok or refreshed_or_error == false then
    local lines, fields = tree_cut_native_update_status(status or "")
    native.last_error = fields.last_error or tostring(status or refreshed_or_error or "BMFSocketTreeCutRefreshTargets failed")
    if native.last_error == "" then
      native.last_error = "BMFSocketTreeCutRefreshTargets failed"
    end
    return result(false, "TREE_CUT_TARGET_REFRESH_FAILED", native.last_error, {
      fields = fields,
      lines = {
        "available=true",
        "target_resolver_available=true",
        "last_error=" .. native.last_error,
      },
    })
  end

  native.last_target_refresh_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local lines, fields = tree_cut_native_update_status(status or "")
  write_status()
  return result(true, "OK", "Tree-cut target cache refreshed", {
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutNative.findTag(options)
  options = type(options) == "table" and options or {}
  local positional = type(options._positional) == "table" and options._positional or {}
  local tag = trim_string(options.tag or options.treeId or options.treeid or positional[1] or "")
  if tag == "" then
    return result(false, "TREE_CUT_FIND_TAG_REQUIRED", "treeid ConsoleTag is required", {
      lines = {
        "available=" .. tostring(tree_cut_tag_lookup_available()),
        "code=TREE_CUT_FIND_TAG_REQUIRED",
        "tag=",
      },
    })
  end

  local native = state.tools.tree_cut_native
  native.available = tree_cut_native_available()
  if not tree_cut_tag_lookup_available() then
    native.last_error = "BMFSocket tree-cut tag lookup helper is unavailable"
    return result(false, "TREE_CUT_TAG_LOOKUP_UNAVAILABLE", native.last_error, {
      tag = tag,
      lines = {
        "available=" .. tostring(native.available == true),
        "tag_lookup_available=false",
        "tag=" .. tag,
        "last_error=" .. native.last_error,
      },
    })
  end

  local limit = tonumber(options.limit or options.maxResults or options.maxresults or 8) or 8
  if limit < 1 then
    limit = 1
  elseif limit > 32 then
    limit = 32
  end
  local max_scan = tonumber(options.maxScan or options.maxscan or options.max or 250000) or 250000
  if max_scan < 1 then
    max_scan = 250000
  end

  local ok, response = pcall(BMFSocketTreeCutFindTag, tag, limit, max_scan)
  if not ok then
    native.last_error = tostring(response or "BMFSocketTreeCutFindTag failed")
    return result(false, "TREE_CUT_TAG_LOOKUP_FAILED", native.last_error, {
      tag = tag,
      lines = {
        "available=true",
        "tag_lookup_available=true",
        "tag=" .. tag,
        "last_error=" .. native.last_error,
      },
    })
  end

  local lines, fields = tree_cut_native_status_lines(response or "")
  local matches = tonumber(fields.matches or 0) or 0
  return result(true, "OK", "Tree-cut ConsoleTag lookup completed", {
    tag = tag,
    matches = matches,
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutNative.inspectPhysical(options)
  return BMF.bricks.inspectRuntimeState(options)
end

function BMF.tools.treeCutNative.setPhysical(options)
  options = type(options) == "table" and options or {}
  local forwarded = copy_table(options)
  forwarded.legacyTreePhysical = true
  return BMF.bricks.setRuntimeState(forwarded)
end

function BMF.tools.treeCutNative.physicalStatus()
  return BMF.bricks.runtimeStateStatus()
end

function BMF.tools.treeCutNative.resolveHandaxe(options)
  options = type(options) == "table" and options or {}
  local native = state.tools.tree_cut_native
  native.available = tree_cut_native_available()
  if not native.available or not tree_cut_handaxe_resolver_available() then
    native.last_error = "BMFSocket tree-cut handaxe resolver helpers are unavailable"
    return result(false, "TREE_CUT_HANDAXE_RESOLVER_UNAVAILABLE", native.last_error, {
      lines = {
        "available=" .. tostring(native.available == true),
        "resolver_available=" .. tostring(tree_cut_handaxe_resolver_available()),
        "last_error=" .. native.last_error,
      },
    })
  end

  local detail_lines = {
    "available=true",
    "resolver_available=true",
    "reason=" .. tostring(options.reason or "command"),
  }

  local loaded = 0
  local load_errors = 0
  local load_assets = options.loadAsset == true or tostring(options.loadAsset or options.loadasset or ""):lower() == "true" or tostring(options.loadasset or "") == "1"
  if load_assets and type(LoadAsset) == "function" then
    for _, asset_path in ipairs(TREE_CUT_HANDAXE_ASSET_CANDIDATES) do
      local ok, err = pcall(LoadAsset, asset_path)
      if ok then
        loaded = loaded + 1
        detail_lines[#detail_lines + 1] = "load_asset_ok=" .. tostring(asset_path)
      else
        load_errors = load_errors + 1
        detail_lines[#detail_lines + 1] = "load_asset_error=" .. tostring(asset_path) .. "|" .. tostring(err)
      end
    end
  elseif load_assets then
    detail_lines[#detail_lines + 1] = "load_asset_error=LoadAsset unavailable"
  else
    detail_lines[#detail_lines + 1] = "load_asset_skipped=true"
  end

  local static_hits = 0
  local set_attempts = 0
  local set_errors = 0
  if type(StaticFindObject) == "function" then
    for _, candidate in ipairs(TREE_CUT_HANDAXE_CLASS_CANDIDATES) do
      local find_ok, object = pcall(StaticFindObject, candidate)
      if find_ok and tree_cut_native_object_valid(object) then
        static_hits = static_hits + 1
        local address = tree_cut_native_object_address(object)
        detail_lines[#detail_lines + 1] = "static_find_hit=" .. tostring(candidate) .. "|address=" .. tostring(address)
        if address ~= "" then
          set_attempts = set_attempts + 1
          local set_ok, accepted_or_error, status = pcall(
            BMFSocketTreeCutSetHandaxeClass,
            address,
            "StaticFindObject(" .. tostring(candidate) .. ")"
          )
          if set_ok then
            local status_lines, fields = tree_cut_native_update_status(status or "")
            for _, line in ipairs(status_lines) do
              detail_lines[#detail_lines + 1] = line
            end
            if accepted_or_error == true then
              native.last_error = ""
              native.last_handaxe_resolved_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
              write_status()
              return result(true, "OK", "Tree-cut handaxe class resolved", {
                fields = fields,
                loaded = loaded,
                loadErrors = load_errors,
                staticFindHits = static_hits,
                setAttempts = set_attempts,
                lines = detail_lines,
              })
            end
          else
            set_errors = set_errors + 1
            detail_lines[#detail_lines + 1] = "set_handaxe_class_error=" .. tostring(candidate) .. "|" .. tostring(accepted_or_error)
          end
        end
      elseif not find_ok then
        detail_lines[#detail_lines + 1] = "static_find_error=" .. tostring(candidate) .. "|" .. tostring(object)
      end
    end
  else
    detail_lines[#detail_lines + 1] = "static_find_error=StaticFindObject unavailable"
  end

  local find_objects_hits = 0
  if type(FindObjects) == "function" and type(EObjectFlags) == "table" then
    local no_flags = EObjectFlags.RF_NoFlags
    for _, spec in ipairs(TREE_CUT_HANDAXE_FIND_OBJECT_SPECS) do
      local find_ok, objects = pcall(FindObjects, 8, spec.class, spec.name, no_flags, no_flags, false)
      if find_ok and type(objects) == "table" then
        for index, object in ipairs(objects) do
          if tree_cut_native_object_valid(object) then
            find_objects_hits = find_objects_hits + 1
            local address = tree_cut_native_object_address(object)
            detail_lines[#detail_lines + 1] = "find_objects_hit=" .. tostring(spec.class or "*") .. "|" .. tostring(spec.name) .. "|" .. tostring(index) .. "|address=" .. tostring(address)
            if address ~= "" then
              set_attempts = set_attempts + 1
              local set_ok, accepted_or_error, status = pcall(
                BMFSocketTreeCutSetHandaxeClass,
                address,
                "FindObjects(" .. tostring(spec.class or "*") .. "," .. tostring(spec.name) .. ")"
              )
              if set_ok then
                local status_lines, fields = tree_cut_native_update_status(status or "")
                for _, line in ipairs(status_lines) do
                  detail_lines[#detail_lines + 1] = line
                end
                if accepted_or_error == true then
                  native.last_error = ""
                  native.last_handaxe_resolved_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
                  write_status()
                  return result(true, "OK", "Tree-cut handaxe class resolved", {
                    fields = fields,
                    loaded = loaded,
                    loadErrors = load_errors,
                    staticFindHits = static_hits,
                    findObjectsHits = find_objects_hits,
                    setAttempts = set_attempts,
                    lines = detail_lines,
                  })
                end
              else
                set_errors = set_errors + 1
                detail_lines[#detail_lines + 1] = "set_handaxe_class_error=" .. tostring(spec.class or "*") .. "|" .. tostring(spec.name) .. "|" .. tostring(accepted_or_error)
              end
            end
          end
        end
      elseif not find_ok then
        detail_lines[#detail_lines + 1] = "find_objects_error=" .. tostring(spec.class or "*") .. "|" .. tostring(spec.name) .. "|" .. tostring(objects)
      end
    end
  else
    detail_lines[#detail_lines + 1] = "find_objects_error=FindObjects or EObjectFlags unavailable"
  end

  local resolve_ok, resolved_or_error, status = pcall(BMFSocketTreeCutResolveHandaxe)
  if not resolve_ok then
    native.last_error = tostring(resolved_or_error or "BMFSocketTreeCutResolveHandaxe failed")
    detail_lines[#detail_lines + 1] = "native_resolve_error=" .. native.last_error
    return result(false, "TREE_CUT_HANDAXE_RESOLVE_FAILED", native.last_error, {
      loaded = loaded,
      loadErrors = load_errors,
      staticFindHits = static_hits,
      findObjectsHits = find_objects_hits,
      setAttempts = set_attempts,
      setErrors = set_errors,
      lines = detail_lines,
    })
  end

  local status_lines, fields = tree_cut_native_update_status(status or "")
  for _, line in ipairs(status_lines) do
    detail_lines[#detail_lines + 1] = line
  end
  if resolved_or_error == true then
    native.last_handaxe_resolved_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  end
  write_status()

  return result(resolved_or_error == true, resolved_or_error == true and "OK" or "TREE_CUT_HANDAXE_UNRESOLVED", "Tree-cut handaxe class resolve attempted", {
    fields = fields,
    loaded = loaded,
    loadErrors = load_errors,
    staticFindHits = static_hits,
    findObjectsHits = find_objects_hits,
    setAttempts = set_attempts,
    setErrors = set_errors,
    lines = detail_lines,
  })
end

function BMF.tools.treeCutNative.drain(options)
  options = type(options) == "table" and options or {}
  local native = state.tools.tree_cut_native
  native.available = tree_cut_native_available()
  if not native.available then
    native.last_error = "BMFSocket tree-cut native helpers are unavailable"
    return result(false, "TREE_CUT_NATIVE_UNAVAILABLE", native.last_error, {
      drained = 0,
      emitted = 0,
      lines = {
        "available=false",
        "drained=0",
        "emitted=0",
      },
    })
  end

  local limit = tonumber(options.limit or options.max or 64) or 64
  if limit < 1 then
    limit = 1
  elseif limit > 256 then
    limit = 256
  end

  local ok, events_or_error = pcall(BMFSocketTreeCutDrain, limit)
  if not ok or type(events_or_error) ~= "table" then
    native.last_error = tostring(events_or_error or "BMFSocketTreeCutDrain failed")
    return result(false, "TREE_CUT_NATIVE_DRAIN_FAILED", native.last_error, {
      drained = 0,
      emitted = 0,
      lines = {
        "available=true",
        "drained=0",
        "emitted=0",
        "last_error=" .. native.last_error,
      },
    })
  end

  local drained = 0
  local emitted = 0
  local decode_errors = 0
  for _, raw in ipairs(events_or_error) do
    if trim_string(raw) ~= "" then
      drained = drained + 1
      local decoded, err = json_decode(raw)
      if type(decoded) == "table" then
        decoded._bmf = decoded._bmf or {}
        decoded._bmf.emittedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
        decoded._bmf.source = "BMFSocketTreeCutNative"
        local event_name = tostring(decoded.event or "cityrpg.treecut.hit")
        BMF.events.emit(event_name, decoded)
        emitted = emitted + 1
        native.last_event = copy_table(decoded)
      else
        decode_errors = decode_errors + 1
        native.last_error = tostring(err or "native tree-cut event decode failed")
      end
    end
  end

  native.drained_events = (tonumber(native.drained_events) or 0) + drained
  native.emitted_events = (tonumber(native.emitted_events) or 0) + emitted
  native.decode_errors = (tonumber(native.decode_errors) or 0) + decode_errors
  if drained > 0 and options.silent ~= true then
    log("info", "tree-cut native drained events=" .. tostring(drained) .. " emitted=" .. tostring(emitted))
  end
  return result(decode_errors == 0, decode_errors == 0 and "OK" or "TREE_CUT_NATIVE_DECODE_ERRORS", "Tree-cut native queue drained", {
    drained = drained,
    emitted = emitted,
    decodeErrors = decode_errors,
    lines = {
      "available=true",
      "drained=" .. tostring(drained),
      "emitted=" .. tostring(emitted),
      "decode_errors=" .. tostring(decode_errors),
      "total_drained=" .. tostring(native.drained_events or 0),
      "total_emitted=" .. tostring(native.emitted_events or 0),
    },
  })
end

function BMF.tools.treeCutProbe.start(options)
  options = type(options) == "table" and options or {}
  if not tree_cut_probe_available() then
    return result(false, "TREE_CUT_PROBE_UNAVAILABLE", "BMFSocket tree-cut probe helpers are unavailable", {
      lines = {
        "available=false",
        "enabled=false",
        "installed=0",
      },
    })
  end

  local ok, started_or_error, status = pcall(BMFSocketTreeCutProbeStart)
  if not ok or started_or_error == false then
    return result(false, "TREE_CUT_PROBE_START_FAILED", tostring(status or started_or_error or "BMFSocketTreeCutProbeStart failed"), {
      lines = {
        "available=true",
        "enabled=false",
        "last_error=" .. tostring(status or started_or_error or ""),
      },
    })
  end

  local lines, fields = tree_cut_native_status_lines(status or "")
  log("info", "tree-cut native probe started reason=" .. tostring(options.reason or "manual"))
  return result(true, "OK", "Tree-cut native probe started", {
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutProbe.stop(options)
  options = type(options) == "table" and options or {}
  if not tree_cut_probe_available() then
    return result(false, "TREE_CUT_PROBE_UNAVAILABLE", "BMFSocket tree-cut probe helpers are unavailable", {
      lines = {
        "available=false",
        "enabled=false",
      },
    })
  end

  local ok, stopped_or_error, status = pcall(BMFSocketTreeCutProbeStop)
  if not ok or stopped_or_error == false then
    return result(false, "TREE_CUT_PROBE_STOP_FAILED", tostring(status or stopped_or_error or "BMFSocketTreeCutProbeStop failed"), {
      lines = {
        "available=true",
        "last_error=" .. tostring(status or stopped_or_error or ""),
      },
    })
  end

  local lines, fields = tree_cut_native_status_lines(status or "")
  log("info", "tree-cut native probe stopped reason=" .. tostring(options.reason or "manual"))
  return result(true, "OK", "Tree-cut native probe stopped", {
    fields = fields,
    lines = lines,
  })
end

function BMF.tools.treeCutProbe.status()
  if not tree_cut_probe_available() then
    return result(false, "TREE_CUT_PROBE_UNAVAILABLE", "BMFSocket tree-cut probe helpers are unavailable", {
      lines = {
        "available=false",
        "enabled=false",
      },
    })
  end

  local ok, status_or_error = pcall(BMFSocketTreeCutProbeStatus)
  if not ok then
    return result(false, "TREE_CUT_PROBE_STATUS_FAILED", tostring(status_or_error or "BMFSocketTreeCutProbeStatus failed"), {
      lines = {
        "available=true",
        "last_error=" .. tostring(status_or_error or ""),
      },
    })
  end

  local lines, fields = tree_cut_native_status_lines(status_or_error or "")
  return result(true, "OK", "Tree-cut native probe status collected", {
    fields = fields,
    lines = lines,
  })
end

end

BMF.minigames = {}

local function normalize_preset_name(value)
  local name = trim_string(value)
  if name == "" then
    return nil, "preset name is required"
  end
  if name:match("[%c]") or name:match("[/\\]") or name:match("%.%.") then
    return nil, "preset name must not contain control characters or path separators"
  end
  return name
end

local function minigame_command_response(command)
  if state.config.allowUnsafeMinigameConsoleCommands ~= true then
    return result(false, "UNSAFE_MINIGAME_COMMAND_DISABLED", "Brickadia minigame console commands are disabled by default.", {
      command = command,
      allowUnsafeMinigameConsoleCommands = false,
      lines = {
        "code=UNSAFE_MINIGAME_COMMAND_DISABLED",
        "command=" .. tostring(command or ""),
        "allowUnsafeMinigameConsoleCommands=false",
      },
    })
  end
  local response = exec_console_manager(command)
  response.data.command = command
  return response
end

BMF.minigames.list = function()
  return minigame_command_response("Server.Minigames.List")
end

BMF.minigames.loadPreset = function(name, owner)
  local preset_name, name_error = normalize_preset_name(name)
  if not preset_name then
    return result(false, "INVALID_PRESET_NAME", name_error)
  end

  local command = "Server.Minigames.LoadPreset " .. quote_console_string(preset_name)
  local owner_name = trim_string(owner)
  if owner_name ~= "" then
    command = command .. " " .. quote_console_string(owner_name)
  end
  local response = minigame_command_response(command)
  response.data.preset = preset_name
  response.data.owner = owner_name
  return response
end

BMF.minigames.savePreset = function(index, name)
  local minigame_index, index_error = normalize_integer(index, "minigame index")
  if minigame_index == nil then
    return result(false, "INVALID_MINIGAME_INDEX", index_error)
  end
  local preset_name, name_error = normalize_preset_name(name)
  if not preset_name then
    return result(false, "INVALID_PRESET_NAME", name_error)
  end

  local command = "Server.Minigames.SavePreset " .. tostring(minigame_index) .. " " .. quote_console_string(preset_name)
  local response = minigame_command_response(command)
  response.data.index = minigame_index
  response.data.preset = preset_name
  return response
end

BMF.minigames.reset = function(index)
  local minigame_index, index_error = normalize_integer(index, "minigame index")
  if minigame_index == nil then
    return result(false, "INVALID_MINIGAME_INDEX", index_error)
  end
  local response = minigame_command_response("Server.Minigames.Reset " .. tostring(minigame_index))
  response.data.index = minigame_index
  return response
end

BMF.minigames.nextRound = function(index)
  local minigame_index, index_error = normalize_integer(index, "minigame index")
  if minigame_index == nil then
    return result(false, "INVALID_MINIGAME_INDEX", index_error)
  end
  local response = minigame_command_response("Server.Minigames.NextRound " .. tostring(minigame_index))
  response.data.index = minigame_index
  return response
end

BMF.minigames.delete = function(index)
  local minigame_index, index_error = normalize_integer(index, "minigame index")
  if minigame_index == nil then
    return result(false, "INVALID_MINIGAME_INDEX", index_error)
  end
  local response = minigame_command_response("Server.Minigames.Delete " .. tostring(minigame_index))
  response.data.index = minigame_index
  return response
end

local function minigame_compact_value(value)
  local text = tostring(value or "")
  text = text:gsub("[%r\n]+", " "):gsub("%s+", " ")
  if #text > 500 then
    text = text:sub(1, 497) .. "..."
  end
  return text
end

local function minigame_object_valid(object)
  if object == nil or type(object) ~= "userdata" then
    return false
  end
  if type(object.IsValid) ~= "function" then
    return true
  end
  local ok, is_valid = pcall(function()
    return object:IsValid()
  end)
  return ok and is_valid == true
end

local function minigame_object_full_name(object)
  if not minigame_object_valid(object) or type(object.GetFullName) ~= "function" then
    return ""
  end
  local ok, full_name = pcall(function()
    return object:GetFullName()
  end)
  if ok and full_name ~= nil then
    return minigame_compact_value(full_name)
  end
  return ""
end

function minigame_object_name(object)
  if not minigame_object_valid(object) or type(object.GetName) ~= "function" then
    return ""
  end
  local ok, object_name = pcall(function()
    return object:GetName()
  end)
  if ok and object_name ~= nil then
    return minigame_compact_value(object_name)
  end
  return ""
end

local function minigame_object_address(object)
  if object == nil or type(object) ~= "userdata" then
    return ""
  end
  if type(object.GetAddress) == "function" then
    local ok, address = pcall(function()
      return object:GetAddress()
    end)
    if ok and type(address) == "number" then
      return string.format("0x%X", address)
    end
    if ok and type(address) == "string" then
      return address
    end
  end
  return tostring(object or ""):match("UObject:%s*([0-9A-Fa-f]+)") or ""
end

local function minigame_try_property(object, name)
  if not minigame_object_valid(object) then
    return nil
  end
  if type(object.GetPropertyValue) == "function" then
    local ok, value = pcall(function()
      return object:GetPropertyValue(name)
    end)
    if ok and value ~= nil then
      return value
    end
  end
  local ok, value = pcall(function()
    return object[name]
  end)
  if ok and value ~= nil then
    return value
  end
  return nil
end

local function minigame_userdata_method(value, name)
  if type(value) ~= "userdata" then
    return nil
  end
  local ok, method = pcall(function()
    return value[name]
  end)
  if ok and type(method) == "function" then
    return method
  end
  return nil
end

local function minigame_value_to_string(value)
  if value == nil then
    return ""
  end
  local value_type = type(value)
  if value_type == "string" or value_type == "number" or value_type == "boolean" then
    return tostring(value)
  end
  if value_type == "userdata" then
    if minigame_userdata_method(value, "ToString") then
      local ok, text = pcall(function()
        return value:ToString()
      end)
      if ok and text ~= nil and tostring(text) ~= "" then
        return tostring(text)
      end
    end
    if minigame_userdata_method(value, "GetFullName") then
      local ok, full_name = pcall(function()
        return value:GetFullName()
      end)
      if ok and full_name ~= nil and tostring(full_name) ~= "" then
        return tostring(full_name)
      end
    end
    if minigame_userdata_method(value, "GetComparisonIndex") then
      local ok, comparison_index = pcall(function()
        return value:GetComparisonIndex()
      end)
      if ok and comparison_index ~= nil then
        return "FName#" .. tostring(comparison_index)
      end
    end
  end
  local ok, text = pcall(function()
    return tostring(value)
  end)
  if ok then
    return tostring(text or "")
  end
  return "<" .. value_type .. ">"
end

local function minigame_object_property(object, name)
  return minigame_compact_value(minigame_value_to_string(minigame_try_property(object, name)))
end

local function minigame_find_objects(class_name, limit)
  local max_count = tonumber(limit) or 64
  local objects = {}
  local seen = {}

  local function add_object(object)
    if not minigame_object_valid(object) then
      return
    end
    local full_name = minigame_object_full_name(object)
    if full_name == "" or full_name:match("Default__") then
      return
    end
    local key = minigame_object_address(object)
    if key == "" then
      key = full_name
    end
    if seen[key] then
      return
    end
    seen[key] = true
    objects[#objects + 1] = object
  end

  if type(FindAllOf) == "function" then
    local ok, found = pcall(FindAllOf, class_name)
    if ok and type(found) == "table" then
      for _, object in ipairs(found) do
        add_object(object)
        if #objects >= max_count then
          break
        end
      end
    end
  end

  if #objects == 0 and type(FindFirstOf) == "function" then
    local ok, object = pcall(FindFirstOf, class_name)
    if ok then
      add_object(object)
    end
  end

  return objects
end

MINIGAME_LIVE_PLAYER_PROPERTIES = {
  "UserName",
  "PlayerNamePrivate",
  "PlayerName",
  "DisplayName",
  "Owner",
  "PawnPrivate",
  "Pawn",
  "CurrentRuleset",
  "CurrentMinigame",
  "CurrentTeam",
  "CurrentRulesetTeam",
  "Ruleset",
  "RulesetTeam",
  "Minigame",
  "MinigameIndex",
  "Team",
  "TeamIndex",
  "TeamState",
  "ActiveTeam",
  "SelectedTeam",
  "MemberRuleset",
  "PlayerRuleset",
  "BRRuleset",
  "BRTeam",
}

MINIGAME_LIVE_OWNER_PROPERTIES = {
  "PlayerState",
  "AcknowledgedPawn",
  "Pawn",
  "CurrentRuleset",
  "CurrentMinigame",
  "CurrentTeam",
  "CurrentRulesetTeam",
  "Ruleset",
  "RulesetTeam",
  "Minigame",
  "Team",
  "TeamIndex",
}

MINIGAME_LIVE_REFLECTION_HINTS = {
  "team",
  "ruleset",
  "minigame",
  "member",
  "owner",
  "player",
  "state",
}

MINIGAME_LIVE_FUNCTION_HINTS = {
  "team",
  "ruleset",
  "minigame",
}

function minigame_terminal_name(value)
  local text = trim_string(value or "")
  if text == "" then
    return ""
  end
  text = text:gsub("^Function%s+", ""):gsub("^Class%s+", ""):gsub("^ObjectProperty%s+", "")
  return text:match("([^%.:/%s]+)$") or text
end

function minigame_get_fname_string(object)
  if object == nil or type(object.GetFName) ~= "function" then
    return ""
  end
  local ok, fname = pcall(function()
    return object:GetFName()
  end)
  if not ok or fname == nil then
    return ""
  end
  if type(fname.ToString) == "function" then
    local string_ok, rendered = pcall(function()
      return fname:ToString()
    end)
    if string_ok and rendered ~= nil and tostring(rendered) ~= "" then
      return tostring(rendered)
    end
  end
  return ""
end

function minigame_property_name(property)
  if property == nil then
    return "unknown"
  end
  if type(property.GetName) == "function" then
    local ok, name = pcall(function()
      return property:GetName()
    end)
    if ok and name ~= nil and tostring(name) ~= "" then
      return tostring(name)
    end
  end
  local fname = minigame_get_fname_string(property)
  if fname ~= "" and not fname:match("^FName#%d+$") then
    return fname
  end
  local full_name = minigame_object_full_name(property)
  local terminal = minigame_terminal_name(full_name)
  if terminal ~= "" then
    return terminal
  end
  return "unknown"
end

function minigame_object_class_name(object)
  if not minigame_object_valid(object) or type(object.GetClass) ~= "function" then
    return ""
  end
  local ok, class_object = pcall(function()
    return object:GetClass()
  end)
  if not ok or not minigame_object_valid(class_object) then
    return ""
  end
  local fname = minigame_get_fname_string(class_object)
  if fname ~= "" and not fname:match("^FName#%d+$") then
    return fname
  end
  return minigame_terminal_name(minigame_object_full_name(class_object))
end

function minigame_property_type(property)
  return minigame_object_class_name(property)
end

function minigame_try_property_detail(object, name)
  if not minigame_object_valid(object) then
    return nil, "", "invalid object"
  end
  local last_error = ""
  if type(object.GetPropertyValue) == "function" then
    local ok, value = pcall(function()
      return object:GetPropertyValue(name)
    end)
    if ok and value ~= nil then
      return value, "GetPropertyValue", ""
    end
    if not ok then
      last_error = tostring(value)
    end
  end
  local ok, value = pcall(function()
    return object[name]
  end)
  if ok and value ~= nil then
    return value, "index", ""
  end
  if not ok and last_error == "" then
    last_error = tostring(value)
  end
  return nil, "", last_error
end

function minigame_value_debug_record(value, array_limit)
  local value_type = type(value)
  local record = {
    type = value_type,
    text = minigame_compact_value(minigame_value_to_string(value)),
  }

  if value_type == "userdata" then
    record.fullName = minigame_object_full_name(value)
    record.objectName = minigame_object_name(value)
    record.address = minigame_object_address(value)
    record.className = minigame_object_class_name(value)

    local count_ok, count = pcall(function()
      return #value
    end)
    if count_ok and type(count) == "number" and count > 0 then
      record.arrayCount = count
      record.items = {}
      local max_items = math.min(count, tonumber(array_limit) or 6)
      for index = 1, max_items do
        local item_ok, item = pcall(function()
          return value[index]
        end)
        if item_ok then
          record.items[#record.items + 1] = minigame_value_debug_record(item, 0)
        end
      end
    end
  end

  return record
end

function minigame_live_collect_property_values(object, property_names, array_limit, include_missing)
  local values = {}
  local missing = {}
  for _, property_name in ipairs(property_names or {}) do
    local value, source, err = minigame_try_property_detail(object, property_name)
    if value ~= nil then
      local record = minigame_value_debug_record(value, array_limit)
      record.source = source
      values[property_name] = record
    elseif include_missing == true then
      missing[property_name] = tostring(err or "")
    end
  end
  return values, missing
end

function minigame_live_name_matches_hints(name, hints)
  local lower = tostring(name or ""):lower()
  if lower == "" then
    return false
  end
  for _, hint in ipairs(hints or {}) do
    if lower:find(tostring(hint):lower(), 1, true) then
      return true
    end
  end
  return false
end

function minigame_live_reflected_properties(object, hints, limit, include_values, array_limit)
  local items = {}
  if not minigame_object_valid(object) or type(object.GetClass) ~= "function" then
    return items
  end
  local ok, class_object = pcall(function()
    return object:GetClass()
  end)
  if not ok or not minigame_object_valid(class_object) or type(class_object.ForEachProperty) ~= "function" then
    return items
  end

  local seen = {}
  local max_count = tonumber(limit) or 32
  local iter_ok, iter_err = pcall(function()
    class_object:ForEachProperty(function(property)
      local property_name = minigame_property_name(property)
      if seen[property_name] or not minigame_live_name_matches_hints(property_name, hints) then
        return false
      end
      seen[property_name] = true
      local item = {
        name = property_name,
        type = minigame_property_type(property),
      }
      if include_values == true then
        local value, source, err = minigame_try_property_detail(object, property_name)
        if value ~= nil then
          item.value = minigame_value_debug_record(value, array_limit)
          item.value.source = source
        elseif err ~= "" then
          item.error = tostring(err)
        end
      end
      items[#items + 1] = item
      return #items >= max_count
    end)
  end)
  if not iter_ok then
    items[#items + 1] = {
      name = "<reflection-error>",
      error = tostring(iter_err),
    }
  end
  return items
end

function minigame_live_reflected_functions(object, hints, limit)
  local items = {}
  if not minigame_object_valid(object) or type(object.GetClass) ~= "function" then
    return items
  end
  local ok, class_object = pcall(function()
    return object:GetClass()
  end)
  if not ok or not minigame_object_valid(class_object) or type(class_object.ForEachFunction) ~= "function" then
    return items
  end

  local seen = {}
  local max_count = tonumber(limit) or 32
  local iter_ok, iter_err = pcall(function()
    class_object:ForEachFunction(function(func)
      local function_name = minigame_property_name(func)
      if seen[function_name] or not minigame_live_name_matches_hints(function_name, hints) then
        return false
      end
      seen[function_name] = true
      items[#items + 1] = {
        name = function_name,
        fullName = minigame_object_full_name(func),
      }
      return #items >= max_count
    end)
  end)
  if not iter_ok then
    items[#items + 1] = {
      name = "<reflection-error>",
      error = tostring(iter_err),
    }
  end
  return items
end

function minigame_live_uehelpers()
  local ok, helpers = pcall(require, "UEHelpers")
  if ok and type(helpers) == "table" then
    return helpers, ""
  end
  if type(UEHelpers) == "table" then
    return UEHelpers, ""
  end
  return nil, tostring(helpers or "UEHelpers unavailable")
end

function minigame_live_game_state()
  local helpers, helper_error = minigame_live_uehelpers()
  if type(helpers) ~= "table" or type(helpers.GetGameStateBase) ~= "function" then
    return nil, helper_error ~= "" and helper_error or "UEHelpers.GetGameStateBase unavailable"
  end
  local ok, game_state = pcall(helpers.GetGameStateBase)
  if ok and minigame_object_valid(game_state) then
    return game_state, ""
  end
  return nil, ok and "game state unavailable" or tostring(game_state)
end

function minigame_live_player_states(options)
  local opts = type(options) == "table" and options or {}
  local game_state, game_state_error = minigame_live_game_state()
  local records = {}
  local seen = {}
  local source = "game_state.PlayerArray"
  local player_array_count = 0
  local errors = {}

  local function add_player_state(player_state, index, item_source)
    if not minigame_object_valid(player_state) then
      return
    end
    local key = minigame_object_address(player_state)
    if key == "" then
      key = minigame_object_full_name(player_state)
    end
    if key == "" or seen[key] then
      return
    end
    seen[key] = true
    records[#records + 1] = {
      object = player_state,
      index = index or #records + 1,
      source = item_source or source,
    }
  end

  if minigame_object_valid(game_state) then
    local ok_array, player_array = pcall(function()
      return game_state.PlayerArray
    end)
    if ok_array and player_array ~= nil then
      local ok_count, count = pcall(function()
        return #player_array
      end)
      if ok_count and type(count) == "number" then
        player_array_count = count
        for index = 1, count do
          local ok_player, player_state = pcall(function()
            return player_array[index]
          end)
          if ok_player then
            add_player_state(player_state, index, source)
          else
            errors[#errors + 1] = "PlayerArray[" .. tostring(index) .. "]=" .. tostring(player_state)
          end
        end
      else
        errors[#errors + 1] = "PlayerArray count failed: " .. tostring(count)
      end
    else
      errors[#errors + 1] = "PlayerArray unavailable: " .. tostring(player_array)
    end
  end

  if #records == 0 and opts.fallbackFindAll == true and type(FindAllOf) == "function" then
    source = "FindAllOf"
    for _, class_name in ipairs({ "BP_PlayerState_C", "BRPlayerState", "PlayerState" }) do
      local ok, found = pcall(FindAllOf, class_name)
      if ok and type(found) == "table" then
        for index, player_state in ipairs(found) do
          add_player_state(player_state, index, "FindAllOf(" .. class_name .. ")")
        end
      elseif not ok then
        errors[#errors + 1] = "FindAllOf(" .. class_name .. ")=" .. tostring(found)
      end
    end
  end

  if #records == 0 and game_state_error ~= "" then
    errors[#errors + 1] = game_state_error
  end

  return records, {
    gameState = game_state,
    gameStateFullName = minigame_object_full_name(game_state),
    playerArrayCount = player_array_count,
    source = source,
    errors = errors,
  }
end

function minigame_live_first_property_text(values, names)
  for _, name in ipairs(names or {}) do
    local value = values[name]
    if type(value) == "table" and tostring(value.text or "") ~= "" then
      return tostring(value.text or ""), name
    end
  end
  return "", ""
end

function minigame_live_collect_candidates(values, pattern)
  local candidates = {}
  local lower_pattern = tostring(pattern or ""):lower()
  for name, value in pairs(values or {}) do
    local lower = tostring(name or ""):lower()
    if lower:find(lower_pattern, 1, true) and type(value) == "table" and tostring(value.text or "") ~= "" then
      candidates[#candidates + 1] = {
        property = name,
        text = tostring(value.text or ""),
        fullName = tostring(value.fullName or ""),
        objectName = tostring(value.objectName or ""),
        className = tostring(value.className or ""),
      }
    end
  end
  table.sort(candidates, function(a, b)
    return tostring(a.property or "") < tostring(b.property or "")
  end)
  return candidates
end

function minigame_live_player_matches(record, query)
  local needle = trim_string(query or ""):lower()
  if needle == "" then
    return true
  end
  local haystacks = {
    record.playerName,
    record.playerStateFullName,
    record.playerStateObjectName,
    record.playerStateAddress,
    record.ownerFullName,
    record.ownerObjectName,
  }
  for _, candidate in ipairs(record.teamCandidates or {}) do
    haystacks[#haystacks + 1] = candidate.text
    haystacks[#haystacks + 1] = candidate.fullName
    haystacks[#haystacks + 1] = candidate.objectName
  end
  for _, candidate in ipairs(record.rulesetCandidates or {}) do
    haystacks[#haystacks + 1] = candidate.text
    haystacks[#haystacks + 1] = candidate.fullName
    haystacks[#haystacks + 1] = candidate.objectName
  end
  for _, value in ipairs(haystacks) do
    local text = trim_string(value or ""):lower()
    if text ~= "" and (text == needle or text:find(needle, 1, true) ~= nil) then
      return true
    end
  end
  return false
end

MINIGAME_LIVE_TEAM_STATE_TEAM_PROPERTIES = {
  "TeamName",
  "TeamId",
  "TeamID",
  "Id",
  "TeamIndex",
  "Name",
  "DisplayName",
  "bIsUnaffiliatedTeam",
  "bGameTypeTeam",
}

MINIGAME_LIVE_TEAM_STATE_RULESET_PROPERTIES = {
  "RulesetName",
  "Name",
  "DisplayName",
  "bInSession",
  "bRoundInProgress",
}

MINIGAME_LIVE_TEAM_STATE_PLAYER_TEAM_PROPERTIES = {
  "Team",
  "CurrentTeam",
  "CurrentRulesetTeam",
  "RulesetTeam",
  "ActiveTeam",
  "SelectedTeam",
  "BRTeam",
  "TeamState",
}

MINIGAME_LIVE_TEAM_STATE_PLAYER_RULESET_PROPERTIES = {
  "Ruleset",
  "CurrentRuleset",
  "BRRuleset",
  "MemberRuleset",
  "PlayerRuleset",
}

MINIGAME_LIVE_TEAM_STATE_OWNER_TEAM_PROPERTIES = {
  "Team",
  "CurrentTeam",
  "CurrentRulesetTeam",
  "RulesetTeam",
}

MINIGAME_LIVE_TEAM_STATE_OWNER_RULESET_PROPERTIES = {
  "Ruleset",
  "CurrentRuleset",
}

function minigame_live_add_referenced_object(list, seen, object, source)
  if not minigame_object_valid(object) then
    return
  end
  local key = minigame_object_address(object)
  if key == "" then
    key = minigame_object_full_name(object)
  end
  if key == "" then
    key = tostring(object or "")
  end
  if key == "" or seen[key] then
    return
  end
  seen[key] = true
  list[#list + 1] = {
    object = object,
    source = tostring(source or ""),
  }
end

function minigame_live_collect_references_from_properties(targets, seen, source_prefix, object, property_names)
  if not minigame_object_valid(object) then
    return
  end
  for _, property_name in ipairs(property_names or {}) do
    local value = minigame_try_property(object, property_name)
    minigame_live_add_referenced_object(targets, seen, value, tostring(source_prefix or "") .. "." .. tostring(property_name))
  end
end

function minigame_live_describe_referenced_object(reference, property_names, include_missing)
  local object = reference and reference.object or nil
  local values, missing = minigame_live_collect_property_values(object, property_names, 0, include_missing == true)
  return {
    source = tostring(reference and reference.source or ""),
    address = minigame_object_address(object),
    fullName = minigame_object_full_name(object),
    objectName = minigame_object_name(object),
    className = minigame_object_class_name(object),
    properties = values,
    missing = missing,
  }
end

function minigame_live_scalar_property_text(record, property_name)
  local value = record and record.properties and record.properties[property_name] or nil
  if type(value) == "table" then
    return tostring(value.text or "")
  end
  return ""
end

BMF.minigames.liveTeamState = function(options)
  local opts = type(options) == "table" and options or {}
  local query = trim_string(opts.player or opts.query or opts.name or "")
  local include_missing = opts.includeMissing == true
  local player_item, candidates, meta = minigame_live_resolve_player_state_for_assignment(query)
  if not player_item or not minigame_object_valid(player_item.object) then
    return result(false, "PLAYER_NOT_FOUND", "live player state was not found", {
      player = query,
      candidates = candidates or {},
      sourceMode = meta and meta.source or "",
      lines = {
        "code=PLAYER_NOT_FOUND",
        "source=bmf.liveTeamState",
        "player=" .. query,
        "source_mode=" .. tostring(meta and meta.source or ""),
        "candidates=" .. table.concat(candidates or {}, "|"),
      },
    })
  end

  local player_state = player_item.object
  local owner = minigame_try_property(player_state, "Owner")
  local team_refs = {}
  local team_seen = {}
  local ruleset_refs = {}
  local ruleset_seen = {}

  minigame_live_collect_references_from_properties(
    team_refs,
    team_seen,
    "player",
    player_state,
    MINIGAME_LIVE_TEAM_STATE_PLAYER_TEAM_PROPERTIES
  )
  minigame_live_collect_references_from_properties(
    ruleset_refs,
    ruleset_seen,
    "player",
    player_state,
    MINIGAME_LIVE_TEAM_STATE_PLAYER_RULESET_PROPERTIES
  )

  if minigame_object_valid(owner) then
    minigame_live_collect_references_from_properties(
      team_refs,
      team_seen,
      "owner",
      owner,
      MINIGAME_LIVE_TEAM_STATE_OWNER_TEAM_PROPERTIES
    )
    minigame_live_collect_references_from_properties(
      ruleset_refs,
      ruleset_seen,
      "owner",
      owner,
      MINIGAME_LIVE_TEAM_STATE_OWNER_RULESET_PROPERTIES
    )
  end

  local teams = {}
  for _, reference in ipairs(team_refs) do
    teams[#teams + 1] = minigame_live_describe_referenced_object(
      reference,
      MINIGAME_LIVE_TEAM_STATE_TEAM_PROPERTIES,
      include_missing
    )
  end

  local rulesets = {}
  for _, reference in ipairs(ruleset_refs) do
    rulesets[#rulesets + 1] = minigame_live_describe_referenced_object(
      reference,
      MINIGAME_LIVE_TEAM_STATE_RULESET_PROPERTIES,
      include_missing
    )
  end

  local lines = {
    "code=OK",
    "source=bmf.liveTeamState",
    "player=" .. query,
    "source_mode=" .. tostring(meta and meta.source or ""),
    "player_state=" .. minigame_object_address(player_state),
    "controller=" .. minigame_object_address(owner),
    "teams=" .. tostring(#teams),
    "rulesets=" .. tostring(#rulesets),
  }

  for index, team in ipairs(teams) do
    lines[#lines + 1] = "team_" .. tostring(index) .. "_source=" .. tostring(team.source or "")
    lines[#lines + 1] = "team_" .. tostring(index) .. "_address=" .. tostring(team.address or "")
    lines[#lines + 1] = "team_" .. tostring(index) .. "_class=" .. tostring(team.className or "")
    lines[#lines + 1] = "team_" .. tostring(index) .. "_object=" .. tostring(team.objectName or "")
    lines[#lines + 1] = "team_" .. tostring(index) .. "_full=" .. tostring(team.fullName or "")
    for _, property_name in ipairs(MINIGAME_LIVE_TEAM_STATE_TEAM_PROPERTIES) do
      local text = minigame_live_scalar_property_text(team, property_name)
      if text ~= "" then
        lines[#lines + 1] = "team_" .. tostring(index) .. "_property_" .. tostring(property_name) .. "=" .. text
      end
    end
  end

  for index, ruleset in ipairs(rulesets) do
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_source=" .. tostring(ruleset.source or "")
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_address=" .. tostring(ruleset.address or "")
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_class=" .. tostring(ruleset.className or "")
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_object=" .. tostring(ruleset.objectName or "")
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_full=" .. tostring(ruleset.fullName or "")
    for _, property_name in ipairs(MINIGAME_LIVE_TEAM_STATE_RULESET_PROPERTIES) do
      local text = minigame_live_scalar_property_text(ruleset, property_name)
      if text ~= "" then
        lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_property_" .. tostring(property_name) .. "=" .. text
      end
    end
  end

  local data = {
    source = "bmf.liveTeamState",
    checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    query = query,
    sourceMode = tostring(meta and meta.source or ""),
    playerState = minigame_object_address(player_state),
    controller = minigame_object_address(owner),
    teams = teams,
    rulesets = rulesets,
    counts = {
      teams = #teams,
      rulesets = #rulesets,
    },
    lines = lines,
  }
  lines[#lines + 1] = "snapshot_json=" .. json_encode(data)

  return result(true, "OK", "Live minigame team state collected", data)
end

function minigame_int32_le_hex(value)
  local number = tonumber(value) or 0
  if number < 0 then
    number = 0
  end
  number = math.floor(number)
  local b1 = number % 256
  local b2 = math.floor(number / 256) % 256
  local b3 = math.floor(number / 65536) % 256
  local b4 = math.floor(number / 16777216) % 256
  return string.format("%02X%02X%02X%02X", b1, b2, b3, b4)
end

function minigame_bool_byte_hex(value)
  return value == true and "01" or "00"
end

function minigame_uint64_le_hex(value)
  local number = tonumber(value) or 0
  if number < 0 then
    number = 0
  end
  number = math.floor(number)
  local bytes = {}
  for index = 1, 8 do
    bytes[index] = string.format("%02X", number % 256)
    number = math.floor(number / 256)
  end
  return table.concat(bytes, "")
end

function minigame_object_pointer_le_hex(object)
  local address = minigame_object_address(object)
  local number = nil
  if address ~= "" then
    number = tonumber(address)
    if number == nil and address:match("^0x") then
      number = tonumber(address:sub(3), 16)
    elseif number == nil then
      number = tonumber(address, 16)
    end
  end
  if number == nil or number <= 0 then
    return nil, "object address is unavailable"
  end
  return minigame_uint64_le_hex(number), ""
end

function minigame_live_resolve_ruleset_for_assignment(player_state)
  for _, property_name in ipairs({
    "Ruleset",
    "CurrentRuleset",
    "BRRuleset",
    "MemberRuleset",
    "PlayerRuleset",
  }) do
    local value = minigame_try_property(player_state, property_name)
    if minigame_object_valid(value) then
      return value, property_name
    end
  end
  return nil, ""
end

function minigame_native_assign_team_param_hex(team, method, first_flag, second_flag, player_state)
  if method == "serverrpc" then
    return minigame_int32_le_hex(team), 4, "ServerJoinRulesetTeam", ""
  end

  if method == "handleplayerswitchteam" then
    local pointer_hex, pointer_error = minigame_object_pointer_le_hex(player_state)
    if not pointer_hex then
      return nil, 0, "HandlePlayerSwitchTeam", pointer_error
    end
    return
      pointer_hex
        .. minigame_int32_le_hex(team)
        .. minigame_bool_byte_hex(first_flag)
        .. minigame_bool_byte_hex(second_flag),
      14,
      "HandlePlayerSwitchTeam",
      ""
  end

  return
    minigame_int32_le_hex(team)
      .. minigame_bool_byte_hex(first_flag)
      .. minigame_bool_byte_hex(second_flag),
    6,
    "JoinRulesetTeam",
    ""
end

function minigame_live_player_assignment_candidates(player_state)
  local candidates = {}

  local function add(value)
    local text = trim_string(value)
    if text ~= "" then
      candidates[#candidates + 1] = text
    end
  end

  add(minigame_object_address(player_state))
  add(minigame_object_name(player_state))
  add(minigame_object_full_name(player_state))

  for _, property_name in ipairs({
    "UserName",
    "PlayerNamePrivate",
    "PlayerName",
    "DisplayName",
  }) do
    add(minigame_value_to_string(minigame_try_property(player_state, property_name)))
  end

  local owner = minigame_try_property(player_state, "Owner")
  if minigame_object_valid(owner) then
    add(minigame_object_address(owner))
    add(minigame_object_name(owner))
    add(minigame_object_full_name(owner))
  end

  return candidates
end

function minigame_cached_single_player_match(query)
  local needle = trim_string(query or ""):lower()
  if needle == "" then
    return false, "player_cache.empty_query"
  end
  if type(read_file) ~= "function" or type(json_decode) ~= "function" then
    return false, "player_cache.unavailable"
  end

  local raw = read_file(PLAYER_CACHE_PATH)
  if not raw or trim_string(raw) == "" then
    return false, "player_cache.missing"
  end

  local ok, decoded = pcall(json_decode, raw)
  if not ok or type(decoded) ~= "table" then
    return false, "player_cache.invalid"
  end

  local players = decoded.players
  if type(players) ~= "table" then
    players = decoded
  end
  if type(players) ~= "table" or #players ~= 1 then
    return false, "player_cache.count=" .. tostring(type(players) == "table" and #players or 0)
  end

  local player = players[1]
  if type(player) ~= "table" then
    return false, "player_cache.invalid_player"
  end

  for _, field in ipairs({
    "uuid",
    "id",
    "playerId",
    "playerID",
    "username",
    "userName",
    "displayName",
    "playerName",
    "originalName",
    "name",
  }) do
    local text = trim_string(tostring(player[field] or "")):lower()
    if text ~= "" and (text == needle or text:find(needle, 1, true) ~= nil) then
      return true, "player_cache.single." .. field
    end
  end

  return false, "player_cache.single_no_match"
end

function minigame_live_controller_candidates_for_assignment()
  local candidates = {}
  local seen = {}
  local classes = { "BP_PlayerController_C", "BRPlayerController", "PlayerController" }

  local function add(controller, source)
    if not minigame_object_valid(controller) then
      return
    end
    local key = minigame_object_address(controller)
    if key == "" then
      key = minigame_object_full_name(controller)
    end
    if key == "" then
      key = tostring(controller or "")
    end
    if key == "" or seen[key] then
      return
    end
    seen[key] = true
    candidates[#candidates + 1] = {
      object = controller,
      source = tostring(source or ""),
      address = minigame_object_address(controller),
      name = minigame_object_name(controller),
      fullName = minigame_object_full_name(controller),
    }
  end

  if type(FindAllOf) == "function" then
    for _, class_name in ipairs(classes) do
      local ok, found = pcall(FindAllOf, class_name)
      if ok and type(found) == "table" then
        for index, controller in ipairs(found) do
          add(controller, "FindAllOf(" .. class_name .. ")[" .. tostring(index) .. "]")
        end
      end
    end
  end

  if #candidates == 0 and type(FindFirstOf) == "function" then
    for _, class_name in ipairs(classes) do
      local ok, controller = pcall(FindFirstOf, class_name)
      if ok then
        add(controller, "FindFirstOf(" .. class_name .. ")")
      end
    end
  end

  return candidates
end

function minigame_live_resolve_controller_for_assignment(query)
  local single_cached_player, cache_source = minigame_cached_single_player_match(query)
  if not single_cached_player then
    return nil, "", cache_source
  end

  local candidates = minigame_live_controller_candidates_for_assignment()
  if #candidates == 1 then
    return candidates[1].object, "live_controller." .. tostring(candidates[1].source or ""), cache_source .. ".single_live_controller"
  end

  return nil, "", cache_source .. ".live_controllers=" .. tostring(#candidates)
end

function minigame_live_first_player_state_for_assignment(source_hint)
  local errors = {}
  local source = "FindFirstOf"
  if type(FindFirstOf) ~= "function" then
    return nil, {
      source = source,
      fastPath = tostring(source_hint or ""),
      errors = { "FindFirstOf unavailable" },
    }
  end

  for _, class_name in ipairs({ "BP_PlayerState_C", "BRPlayerState", "PlayerState" }) do
    local ok, player_state = pcall(FindFirstOf, class_name)
    if ok and minigame_object_valid(player_state) then
      local item_source = "FindFirstOf(" .. class_name .. ")"
      return {
        object = player_state,
        index = 1,
        source = item_source,
      }, {
        source = item_source,
        fastPath = tostring(source_hint or ""),
        errors = errors,
      }
    elseif not ok then
      errors[#errors + 1] = "FindFirstOf(" .. class_name .. ")=" .. tostring(player_state)
    end
  end

  return nil, {
    source = source,
    fastPath = tostring(source_hint or ""),
    errors = errors,
  }
end

function minigame_assignment_candidate_match_kind(candidates, needle)
  local query = trim_string(needle or ""):lower()
  if query == "" then
    return true, "empty"
  end

  local partial = false
  for _, candidate in ipairs(candidates or {}) do
    local lower = trim_string(candidate):lower()
    if lower ~= "" then
      if lower == query then
        return true, "exact"
      end
      if lower:find(query, 1, true) ~= nil then
        partial = true
      end
    end
  end

  return partial, partial and "partial" or ""
end

function minigame_assignment_player_state_score(item, candidates, match_kind)
  local player_state = item and item.object or nil
  local score = 0

  if match_kind == "exact" then
    score = score + 1000
  elseif match_kind == "partial" then
    score = score + 800
  elseif match_kind == "empty" then
    score = score + 100
  end

  local owner = minigame_try_property(player_state, "Owner")
  if minigame_object_valid(owner) then
    score = score + 250
  end

  for _, property_name in ipairs({ "Pawn", "PawnPrivate", "Character", "AcknowledgedPawn" }) do
    if minigame_object_valid(minigame_try_property(player_state, property_name)) then
      score = score + 50
      break
    end
  end

  local ruleset = minigame_live_resolve_ruleset_for_assignment(player_state)
  if minigame_object_valid(ruleset) then
    score = score + 50
  end

  if tostring(item and item.source or ""):find("PlayerArray", 1, true) then
    score = score + 25
  end

  if #(candidates or {}) > 0 then
    score = score + math.min(#candidates, 10)
  end

  return score
end

function minigame_assignment_better_candidate(candidate, current)
  if candidate == nil then
    return current
  end
  if current == nil then
    return candidate
  end
  if tonumber(candidate.score or 0) > tonumber(current.score or 0) then
    return candidate
  end
  return current
end

function minigame_live_resolve_player_state_for_assignment(query)
  local needle = trim_string(query or ""):lower()
  local single_cached_player, cache_source = minigame_cached_single_player_match(query)
  local player_states, meta = minigame_live_player_states({
    fallbackFindAll = true,
  })
  meta = type(meta) == "table" and meta or {}
  meta.fastPath = single_cached_player and cache_source or ""
  local fallback = nil
  local matched = nil

  for _, item in ipairs(player_states or {}) do
    local player_state = item.object
    local candidates = minigame_live_player_assignment_candidates(player_state)
    local matches, match_kind = minigame_assignment_candidate_match_kind(candidates, needle)
    local scored = {
      item = item,
      candidates = candidates,
      matchKind = match_kind,
      score = minigame_assignment_player_state_score(item, candidates, match_kind),
    }
    fallback = minigame_assignment_better_candidate(scored, fallback)
    if matches then
      matched = minigame_assignment_better_candidate(scored, matched)
    end
  end

  if matched ~= nil then
    meta.fastPath = tostring(meta.fastPath or "") .. ".filtered." .. tostring(matched.matchKind or "")
    return matched.item, matched.candidates, meta
  end

  if single_cached_player and fallback ~= nil then
    meta.fastPath = tostring(meta.fastPath or "") .. ".single_filtered"
    return fallback.item, fallback.candidates, meta
  end

  if single_cached_player and #(player_states or {}) == 0 then
    local first_item, first_meta = minigame_live_first_player_state_for_assignment(cache_source)
    if first_item and minigame_object_valid(first_item.object) then
      return first_item, { cache_source }, first_meta
    end
  end

  return nil, fallback and fallback.candidates or {}, meta
end

BMF.minigames.assignTeam = function(player_query, team_index, options)
  local assign_started_clock = os.clock()
  local opts = type(options) == "table" and options or {}
  local query = trim_string(player_query or "")
  if query == "" then
    return result(false, "INVALID_PLAYER", "player query is required", {
      lines = {
        "code=INVALID_PLAYER",
        "player=",
      },
    })
  end

  local team, team_error = normalize_integer(team_index, "team index")
  if team == nil then
    return result(false, "INVALID_TEAM_INDEX", team_error, {
      player = query,
      teamIndex = tostring(team_index or ""),
      lines = {
        "code=INVALID_TEAM_INDEX",
        "player=" .. query,
        "team_index=" .. tostring(team_index or ""),
        "error=" .. tostring(team_error or ""),
      },
    })
  end

  local resolve_started_clock = os.clock()
  local player_item, candidates, meta = minigame_live_resolve_player_state_for_assignment(query)
  local resolve_duration_ms = math.floor(((os.clock() - resolve_started_clock) * 1000) + 0.5)
  if not player_item or not minigame_object_valid(player_item.object) then
    return result(false, "PLAYER_NOT_FOUND", "live player state was not found", {
      player = query,
      teamIndex = team,
      candidates = candidates or {},
      sourceMode = meta and meta.source or "",
      lines = {
        "code=PLAYER_NOT_FOUND",
        "player=" .. query,
        "team_index=" .. tostring(team),
        "source_mode=" .. tostring(meta and meta.source or ""),
        "assign_resolve_ms=" .. tostring(resolve_duration_ms),
        "candidates=" .. table.concat(candidates or {}, "|"),
      },
    })
  end

  local player_state = player_item.object
  local controller = minigame_try_property(player_state, "Owner")
  local controller_source = "player_state.Owner"
  local controller_fallback = ""
  local ruleset, ruleset_source = minigame_live_resolve_ruleset_for_assignment(player_state)
  local requested_method = trim_string(opts.method or opts.assignMethod or opts.nativeMethod or ""):lower()
  local method = requested_method
  if method == "" or method == "local" or method == "join" or method == "joinrulesetteam" or method == "join-ruleset-team" then
    method = "joinrulesetteam"
  elseif method == "server" or method == "rpc" or method == "server-rpc" or method == "serverjoinrulesetteam" or method == "server-join-ruleset-team" then
    method = "serverrpc"
  elseif method == "handle" or method == "switch" or method == "ruleset" or method == "handleplayerswitchteam" or method == "handle-player-switch-team" then
    method = "handleplayerswitchteam"
  elseif method == "call" or method == "callbyname" or method == "servercall" or method == "servercallbyname" or method == "server-call-by-name" then
    method = "servercallbyname"
  elseif method == "joincall" or method == "joincallbyname" or method == "join-call-by-name" then
    method = "joincallbyname"
  else
    return result(false, "INVALID_ASSIGN_METHOD", "unsupported minigame team assignment method", {
      player = query,
      teamIndex = team,
      method = requested_method,
      lines = {
        "code=INVALID_ASSIGN_METHOD",
        "player=" .. query,
        "team_index=" .. tostring(team),
        "method=" .. tostring(requested_method),
        "supported_methods=joinrulesetteam|serverrpc|handleplayerswitchteam|servercallbyname|joincallbyname",
      },
    })
  end

  if method ~= "handleplayerswitchteam" and not minigame_object_valid(controller) then
    local fallback_controller, fallback_source, fallback_detail = minigame_live_resolve_controller_for_assignment(query)
    controller_fallback = tostring(fallback_detail or fallback_source or "")
    if minigame_object_valid(fallback_controller) then
      controller = fallback_controller
      controller_source = tostring(fallback_source or "live_controller")
    end
  end

  local flag1 = opts.flag1
  if flag1 == nil then
    flag1 = true
  end
  local flag2 = opts.flag2
  if flag2 == nil then
    flag2 = true
  end
  local call_context = controller
  local call_context_kind = "controller"
  if method == "handleplayerswitchteam" then
    call_context = ruleset
    call_context_kind = "ruleset"
  end
  local is_call_by_name = method == "servercallbyname" or method == "joincallbyname"
  local call_by_name_command = ""
  local buffer_hex, param_bytes, function_name, param_error = nil, 0, "", ""
  if is_call_by_name then
    function_name = "CallFunctionByNameWithArguments"
    if method == "joincallbyname" then
      call_by_name_command = "JoinRulesetTeam "
        .. tostring(team)
        .. " "
        .. tostring(flag1 == true)
        .. " "
        .. tostring(flag2 == true)
    else
      call_by_name_command = "ServerJoinRulesetTeam " .. tostring(team)
    end
    buffer_hex = ""
  else
    buffer_hex, param_bytes, function_name, param_error = minigame_native_assign_team_param_hex(team, method, flag1 == true, flag2 == true, player_state)
  end
  local dry_run = opts.dryRun == true
  local lines = {
    "code=OK",
    "player=" .. query,
    "team_index=" .. tostring(team),
    "method=" .. method,
    "function=" .. function_name,
    "param_bytes=" .. tostring(param_bytes),
    "param_hex=" .. tostring(buffer_hex or ""),
    "flag1=" .. tostring(flag1 == true),
    "flag2=" .. tostring(flag2 == true),
    "dry_run=" .. tostring(dry_run),
    "source=" .. tostring(player_item.source or ""),
    "source_mode=" .. tostring(meta and meta.source or ""),
    "fast_path=" .. tostring(meta and meta.fastPath or ""),
    "assign_resolve_ms=" .. tostring(resolve_duration_ms),
    "player_state=" .. minigame_object_address(player_state),
    "player_state_name=" .. minigame_object_name(player_state),
    "controller=" .. minigame_object_address(controller),
    "controller_name=" .. minigame_object_name(controller),
    "controller_source=" .. tostring(controller_source or ""),
    "controller_fallback=" .. tostring(controller_fallback or ""),
    "ruleset=" .. minigame_object_address(ruleset),
    "ruleset_name=" .. minigame_object_name(ruleset),
    "ruleset_source=" .. tostring(ruleset_source or ""),
    "context_kind=" .. tostring(call_context_kind),
    "context=" .. minigame_object_address(call_context),
    "call_command=" .. tostring(call_by_name_command or ""),
  }

  if buffer_hex == nil then
    lines[1] = "code=INVALID_NATIVE_PARAMS"
    lines[#lines + 1] = "error=" .. tostring(param_error or "")
    return result(false, "INVALID_NATIVE_PARAMS", tostring(param_error or "native parameter packing failed"), {
      player = query,
      teamIndex = team,
      method = method,
      lines = lines,
    })
  end

  if not minigame_object_valid(call_context) then
    local code = method == "handleplayerswitchteam" and "RULESET_NOT_FOUND" or "PLAYER_CONTROLLER_NOT_FOUND"
    lines[1] = "code=" .. code
    lines[#lines + 1] = "candidates=" .. table.concat(candidates or {}, "|")
    return result(false, code, method == "handleplayerswitchteam" and "live player ruleset was not found" or "live player controller was not found", {
      player = query,
      teamIndex = team,
      playerState = minigame_object_address(player_state),
      method = method,
      lines = lines,
    })
  end

  if dry_run then
    lines[#lines + 1] = "ok=true"
    lines[#lines + 1] = "result=dry-run"
    lines[#lines + 1] = "assign_call_ms=0"
    lines[#lines + 1] = "assign_total_ms=" .. tostring(math.floor(((os.clock() - assign_started_clock) * 1000) + 0.5))
    return result(true, "OK", "Minigame team assignment dry run completed", {
      player = query,
      teamIndex = team,
      playerState = minigame_object_address(player_state),
      controller = minigame_object_address(controller),
      controllerSource = controller_source,
      controllerFallback = controller_fallback,
      ruleset = minigame_object_address(ruleset),
      context = minigame_object_address(call_context),
      contextKind = call_context_kind,
      method = method,
      functionName = function_name,
      paramHex = buffer_hex,
      paramBytes = param_bytes,
      flag1 = flag1 == true,
      flag2 = flag2 == true,
      dryRun = true,
      lines = lines,
    })
  end

  if is_call_by_name then
    if type(OmeggaCallFunctionByNameWithArguments) ~= "function" then
      lines[1] = "code=CALL_BY_NAME_HELPER_UNAVAILABLE"
      lines[#lines + 1] = "helper_available=false"
      return result(false, "CALL_BY_NAME_HELPER_UNAVAILABLE", "native CallFunctionByNameWithArguments helper is unavailable", {
        player = query,
        teamIndex = team,
        method = method,
        lines = lines,
      })
    end

    local call_started_clock = os.clock()
    local ok, call_result, detail = pcall(
      OmeggaCallFunctionByNameWithArguments,
      call_context,
      call_by_name_command,
      call_context
    )
    local call_duration_ms = math.floor(((os.clock() - call_started_clock) * 1000) + 0.5)
    local assigned = ok and call_result ~= false
    lines[1] = "code=" .. tostring(assigned and "OK" or "CALL_BY_NAME_FAILED")
    lines[#lines + 1] = "ok=" .. tostring(ok)
    lines[#lines + 1] = "result=" .. tostring(call_result)
    lines[#lines + 1] = "assign_call_ms=" .. tostring(call_duration_ms)
    lines[#lines + 1] = "assign_total_ms=" .. tostring(math.floor(((os.clock() - assign_started_clock) * 1000) + 0.5))
    if detail ~= nil then
      lines[#lines + 1] = "detail=" .. tostring(detail)
    end

    return result(assigned, assigned and "OK" or "CALL_BY_NAME_FAILED", assigned and "Minigame team assignment invoked" or "Minigame team assignment failed", {
      player = query,
      teamIndex = team,
      playerState = minigame_object_address(player_state),
      controller = minigame_object_address(controller),
      controllerSource = controller_source,
      controllerFallback = controller_fallback,
      ruleset = minigame_object_address(ruleset),
      context = minigame_object_address(call_context),
      contextKind = call_context_kind,
      method = method,
      functionName = function_name,
      callCommand = call_by_name_command,
      flag1 = flag1 == true,
      flag2 = flag2 == true,
      callByNameOk = ok,
      callByNameResult = call_result,
      callByNameDetail = detail,
      lines = lines,
    })
  end

  if type(OmeggaUnsafeProcessEventWithParamBytes) ~= "function" then
    lines[1] = "code=PROCESS_EVENT_HELPER_UNAVAILABLE"
    lines[#lines + 1] = "helper_available=false"
    return result(false, "PROCESS_EVENT_HELPER_UNAVAILABLE", "native ProcessEvent helper is unavailable", {
      player = query,
      teamIndex = team,
      lines = lines,
    })
  end

  local call_started_clock = os.clock()
  local ok, call_result, detail = pcall(
    OmeggaUnsafeProcessEventWithParamBytes,
    call_context,
    function_name,
    buffer_hex
  )
  local call_duration_ms = math.floor(((os.clock() - call_started_clock) * 1000) + 0.5)
  local assigned = ok and call_result ~= false
  lines[1] = "code=" .. tostring(assigned and "OK" or "PROCESS_EVENT_FAILED")
  lines[#lines + 1] = "ok=" .. tostring(ok)
  lines[#lines + 1] = "result=" .. tostring(call_result)
  lines[#lines + 1] = "assign_call_ms=" .. tostring(call_duration_ms)
  lines[#lines + 1] = "assign_total_ms=" .. tostring(math.floor(((os.clock() - assign_started_clock) * 1000) + 0.5))
  if detail ~= nil then
    lines[#lines + 1] = "detail=" .. tostring(detail)
  end

  return result(assigned, assigned and "OK" or "PROCESS_EVENT_FAILED", assigned and "Minigame team assignment invoked" or "Minigame team assignment failed", {
      player = query,
      teamIndex = team,
      playerState = minigame_object_address(player_state),
      controller = minigame_object_address(controller),
      controllerSource = controller_source,
      controllerFallback = controller_fallback,
      ruleset = minigame_object_address(ruleset),
      context = minigame_object_address(call_context),
      contextKind = call_context_kind,
    method = method,
    functionName = function_name,
    paramHex = buffer_hex,
    paramBytes = param_bytes,
    flag1 = flag1 == true,
    flag2 = flag2 == true,
    processEventOk = ok,
    processEventResult = call_result,
    processEventDetail = detail,
    lines = lines,
  })
end

BMF.minigames.livePlayerSnapshot = function(options)
  local opts = type(options) == "table" and options or {}
  local query = trim_string(opts.player or opts.query or opts.name or "")
  local limit = tonumber(opts.limit) or 16
  local array_limit = tonumber(opts.arrayLimit) or 6
  local include_missing = opts.includeMissing == true
  local include_reflection = opts.reflect == true
  local include_reflection_values = opts.reflectValues == true
  local include_functions = opts.functions == true
  local verbose = opts.verbose == true
  local player_states, meta = minigame_live_player_states({
    fallbackFindAll = opts.fallbackFindAll ~= false,
  })

  local players = {}
  for _, item in ipairs(player_states) do
    if #players >= limit then
      break
    end
    local player_state = item.object
    local property_values, missing = minigame_live_collect_property_values(
      player_state,
      MINIGAME_LIVE_PLAYER_PROPERTIES,
      array_limit,
      include_missing
    )
    local player_name = minigame_live_first_property_text(property_values, {
      "UserName",
      "PlayerNamePrivate",
      "PlayerName",
      "DisplayName",
    })
    local owner_value = property_values.Owner
    local owner = nil
    if type(owner_value) == "table" and owner_value.type == "userdata" then
      local raw_owner = minigame_try_property(player_state, "Owner")
      if minigame_object_valid(raw_owner) then
        owner = raw_owner
      end
    end

    local owner_properties = {}
    local owner_missing = {}
    if minigame_object_valid(owner) then
      owner_properties, owner_missing = minigame_live_collect_property_values(
        owner,
        MINIGAME_LIVE_OWNER_PROPERTIES,
        array_limit,
        include_missing
      )
    end

    local record = {
      index = item.index,
      source = item.source,
      playerName = player_name,
      playerStateFullName = minigame_object_full_name(player_state),
      playerStateObjectName = minigame_object_name(player_state),
      playerStateAddress = minigame_object_address(player_state),
      playerStateClass = minigame_object_class_name(player_state),
      ownerFullName = minigame_object_full_name(owner),
      ownerObjectName = minigame_object_name(owner),
      ownerAddress = minigame_object_address(owner),
      ownerClass = minigame_object_class_name(owner),
      properties = property_values,
      teamCandidates = minigame_live_collect_candidates(property_values, "team"),
      rulesetCandidates = minigame_live_collect_candidates(property_values, "ruleset"),
      minigameCandidates = minigame_live_collect_candidates(property_values, "minigame"),
    }
    if include_missing then
      record.missing = missing
      record.ownerMissing = owner_missing
    end
    if next(owner_properties) ~= nil then
      record.ownerProperties = owner_properties
      record.ownerTeamCandidates = minigame_live_collect_candidates(owner_properties, "team")
      record.ownerRulesetCandidates = minigame_live_collect_candidates(owner_properties, "ruleset")
      record.ownerMinigameCandidates = minigame_live_collect_candidates(owner_properties, "minigame")
    end
    if include_reflection then
      record.reflectedProperties = minigame_live_reflected_properties(
        player_state,
        MINIGAME_LIVE_REFLECTION_HINTS,
        tonumber(opts.reflectLimit) or 32,
        include_reflection_values,
        array_limit
      )
      if minigame_object_valid(owner) then
        record.ownerReflectedProperties = minigame_live_reflected_properties(
          owner,
          MINIGAME_LIVE_REFLECTION_HINTS,
          tonumber(opts.reflectLimit) or 32,
          include_reflection_values,
          array_limit
        )
      end
    end
    if include_functions then
      record.reflectedFunctions = minigame_live_reflected_functions(
        player_state,
        MINIGAME_LIVE_FUNCTION_HINTS,
        tonumber(opts.functionLimit) or 32
      )
      if minigame_object_valid(owner) then
        record.ownerReflectedFunctions = minigame_live_reflected_functions(
          owner,
          MINIGAME_LIVE_FUNCTION_HINTS,
          tonumber(opts.functionLimit) or 32
        )
      end
    end

    if minigame_live_player_matches(record, query) then
      players[#players + 1] = record
    end
  end

  local lines = {
    "source=bmf.livePlayerSnapshot",
    "query=" .. query,
    "game_state=" .. tostring(meta.gameStateFullName or ""),
    "source_mode=" .. tostring(meta.source or ""),
    "player_array_count=" .. tostring(meta.playerArrayCount or 0),
    "players=" .. tostring(#player_states),
    "returned=" .. tostring(#players),
    "reflect=" .. tostring(include_reflection),
    "reflect_values=" .. tostring(include_reflection_values),
    "functions=" .. tostring(include_functions),
  }

  for index, error_text in ipairs(meta.errors or {}) do
    lines[#lines + 1] = "error_" .. tostring(index) .. "=" .. tostring(error_text)
  end

  for index, player in ipairs(players) do
    local team = player.teamCandidates[1] or {}
    local ruleset = player.rulesetCandidates[1] or player.minigameCandidates[1] or {}
    lines[#lines + 1] =
      "player_" .. tostring(index) ..
      "=" .. tostring(player.playerName or "") ..
      "|state=" .. tostring(player.playerStateObjectName or "") ..
      "|team_candidate=" .. tostring(team.property or "") .. ":" .. tostring(team.text or "") ..
      "|ruleset_candidate=" .. tostring(ruleset.property or "") .. ":" .. tostring(ruleset.text or "") ..
      "|owner=" .. tostring(player.ownerObjectName or "")

    if verbose then
      for name, value in pairs(player.properties or {}) do
        lines[#lines + 1] = "player_" .. tostring(index) .. "_property_" .. tostring(name) .. "=" .. tostring(value.text or "")
      end
      for name, value in pairs(player.ownerProperties or {}) do
        lines[#lines + 1] = "player_" .. tostring(index) .. "_owner_property_" .. tostring(name) .. "=" .. tostring(value.text or "")
      end
    end
  end

  local data = {
    source = "bmf.livePlayerSnapshot",
    checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    query = query,
    gameState = tostring(meta.gameStateFullName or ""),
    playerArrayCount = tonumber(meta.playerArrayCount) or 0,
    sourceMode = tostring(meta.source or ""),
    players = players,
    counts = {
      observed = #player_states,
      returned = #players,
    },
    options = {
      fallbackFindAll = opts.fallbackFindAll == true,
      reflect = include_reflection,
      reflectValues = include_reflection_values,
      functions = include_functions,
      includeMissing = include_missing,
      verbose = verbose,
      limit = limit,
    },
    errors = meta.errors or {},
    lines = lines,
  }
  lines[#lines + 1] = "snapshot_json=" .. json_encode(data)

  return result(true, "OK", "Live minigame player snapshot collected", data)
end

BMF.minigames.objectSnapshot = function(options)
  local opts = type(options) == "table" and options or {}
  local targeted_read = opts.targeted == true or option_boolean(opts, "targeted", false)
  if state.config.allowUnsafeMinigameObjectSnapshot ~= true then
    return result(false, "UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED", "Direct UE4SS minigame object snapshots are disabled by default.", {
      allowUnsafeMinigameObjectSnapshot = false,
      lines = {
        "code=UNSAFE_MINIGAME_OBJECT_SNAPSHOT_DISABLED",
        "allowUnsafeMinigameObjectSnapshot=false",
        "targeted=" .. tostring(targeted_read),
        "reason=global BP_Ruleset_C/BP_Team_C enumeration can abort the dedicated server",
        "use=bmf.minigames.live.team-state",
      },
    })
  end

  local limit = tonumber(opts.limit) or 64
  local include_properties = opts.includeProperties == true or option_boolean(opts, "includeproperties", false)
  local rulesets = minigame_find_objects("BP_Ruleset_C", limit)
  local teams = minigame_find_objects("BP_Team_C", limit)
  local snapshot = {
    source = "bmf.objectSnapshot",
    checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    unsafePropertiesIncluded = include_properties,
    rulesets = {},
    teams = {},
  }
  local lines = {
    "source=bmf.objectSnapshot",
    "targeted=" .. tostring(targeted_read),
    "unsafe_properties_included=" .. tostring(include_properties),
    "rulesets=" .. tostring(#rulesets),
    "teams=" .. tostring(#teams),
  }

  for index, object in ipairs(rulesets) do
    local item = {
      fullName = minigame_object_full_name(object),
      objectName = minigame_object_name(object),
      address = minigame_object_address(object),
    }
    if include_properties then
      item.name = minigame_object_property(object, "RulesetName")
      item.inSession = minigame_object_property(object, "bInSession")
      item.memberStates = minigame_object_property(object, "MemberStates")
      item.customTeams = minigame_object_property(object, "CustomTeams")
      item.unaffiliatedTeam = minigame_object_property(object, "UnaffiliatedTeam")
    end
    snapshot.rulesets[#snapshot.rulesets + 1] = item
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_full=" .. item.fullName
    lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_object=" .. item.objectName
    if include_properties then
      lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_name=" .. tostring(item.name or "")
      lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_in_session=" .. tostring(item.inSession or "")
      lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_members=" .. tostring(item.memberStates or "")
      lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_custom_teams=" .. tostring(item.customTeams or "")
      lines[#lines + 1] = "ruleset_" .. tostring(index) .. "_unaffiliated_team=" .. tostring(item.unaffiliatedTeam or "")
    end
  end

  for index, object in ipairs(teams) do
    local item = {
      fullName = minigame_object_full_name(object),
      objectName = minigame_object_name(object),
      address = minigame_object_address(object),
    }
    if include_properties then
      item.name = minigame_object_property(object, "TeamName")
      item.teamId = minigame_object_property(object, "TeamId")
      item.teamID = minigame_object_property(object, "TeamID")
      item.id = minigame_object_property(object, "Id")
      item.index = minigame_object_property(object, "TeamIndex")
      item.color = minigame_object_property(object, "TeamColor")
      item.memberStates = minigame_object_property(object, "MemberStates")
      item.ruleset = minigame_object_property(object, "Ruleset")
      item.isUnaffiliated = minigame_object_property(object, "bIsUnaffiliatedTeam")
      item.isGameTypeTeam = minigame_object_property(object, "bGameTypeTeam")
    end
    snapshot.teams[#snapshot.teams + 1] = item
    lines[#lines + 1] = "team_" .. tostring(index) .. "_full=" .. item.fullName
    lines[#lines + 1] = "team_" .. tostring(index) .. "_object=" .. item.objectName
    if include_properties then
      lines[#lines + 1] = "team_" .. tostring(index) .. "_name=" .. tostring(item.name or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_team_id=" .. tostring(item.teamId or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_team_ID=" .. tostring(item.teamID or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_id=" .. tostring(item.id or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_index=" .. tostring(item.index or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_color=" .. tostring(item.color or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_members=" .. tostring(item.memberStates or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_ruleset=" .. tostring(item.ruleset or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_unaffiliated=" .. tostring(item.isUnaffiliated or "")
      lines[#lines + 1] = "team_" .. tostring(index) .. "_gametype=" .. tostring(item.isGameTypeTeam or "")
    end
  end

  lines[#lines + 1] = "snapshot_json=" .. json_encode(snapshot)

  return result(true, "OK", "Minigame object snapshot collected", {
    source = snapshot.source,
    checkedAt = snapshot.checkedAt,
    targeted = targeted_read,
    unsafePropertiesIncluded = include_properties,
    rulesets = snapshot.rulesets,
    teams = snapshot.teams,
    counts = {
      rulesets = #rulesets,
      teams = #teams,
    },
    lines = lines,
  })
end

local MINIGAME_EVENT_NAMES = {
  snapshot = true,
  created = true,
  deleted = true,
  joinminigame = true,
  leaveminigame = true,
  teamchange = true,
  roundchange = true,
  roundend = true,
  leaderboardchange = true,
  score = true,
  kill = true,
  death = true,
}

local MINIGAME_EVENT_ALIASES = {
  create = "created",
  delete = "deleted",
  join = "joinminigame",
  leave = "leaveminigame",
  leaderboard = "leaderboardchange",
  round = "roundchange",
  roundstart = "roundchange",
  team = "teamchange",
}

local function normalize_minigame_event_name(value)
  local name = trim_string(value):lower()
  name = name:gsub("^minigames%.", "")
  name = MINIGAME_EVENT_ALIASES[name] or name
  if name == "" then
    return nil, "minigame event name is required"
  end
  if not MINIGAME_EVENT_NAMES[name] then
    return nil, "unsupported minigame event: " .. tostring(value or "")
  end
  return name
end

local function minigame_key(value)
  if type(value) ~= "table" then
    return ""
  end
  local ruleset = trim_string(value.ruleset or value.id or "")
  if ruleset ~= "" then
    return "ruleset:" .. ruleset
  end
  local name = trim_string(value.name or value.minigame or "")
  local index = value.index
  if name == "" and index == nil then
    return ""
  end
  return "name:" .. name .. "#" .. tostring(tonumber(index) or 0)
end

local function player_key(value)
  if type(value) ~= "table" then
    return trim_string(value or "")
  end
  return trim_string(value.id or value.uuid or value.state or value.controller or value.name or value.displayName or "")
end

local function team_key(value, minigame)
  if type(value) ~= "table" then
    return ""
  end
  local team = trim_string(value.team or value.id or value.name or "")
  if team == "" then
    return ""
  end
  local parent = minigame_key(minigame or value.minigame or {})
  if parent ~= "" and not team:match("^BP_Team") then
    return parent .. ":team:" .. team
  end
  return "team:" .. team
end

function minigame_definitions_state()
  state.minigame_definitions = state.minigame_definitions or {}
  local definitions = state.minigame_definitions
  definitions.records_by_key = definitions.records_by_key or {}
  definitions.updated_at = definitions.updated_at or ""
  definitions.source = definitions.source or ""
  definitions.total_updates = tonumber(definitions.total_updates) or 0
  definitions.last_error = tostring(definitions.last_error or "")
  return definitions
end

function normalize_minigame_definition_bool(value, label)
  if value == nil or value == "" then
    return nil, nil
  end
  if type(value) == "boolean" then
    return value, nil
  end
  local lower = trim_string(value):lower()
  if lower == "true" or lower == "1" or lower == "yes" or lower == "on" then
    return true, nil
  end
  if lower == "false" or lower == "0" or lower == "no" or lower == "off" then
    return false, nil
  end
  return nil, label .. " must be a boolean"
end

function minigame_definition_text_list(value)
  local items = {}
  if type(value) == "table" then
    for _, item in ipairs(value) do
      if type(item) == "table" then
        local name = trim_string(item.name or item.team or item.id or item.key or "")
        if name ~= "" then
          local copied = copy_table(item)
          copied.name = name
          items[#items + 1] = copied
        end
      else
        local text = trim_string(item)
        if text ~= "" then
          items[#items + 1] = text
        end
      end
    end
    return items
  end

  local text = trim_string(value or "")
  if text == "" then
    return items
  end
  for item in text:gmatch("[^,|]+") do
    local decoded = trim_string(percent_decode(item))
    if decoded ~= "" then
      items[#items + 1] = decoded
    end
  end
  return items
end

function normalize_minigame_definition_teams(value)
  local teams = {}
  for index, item in ipairs(minigame_definition_text_list(value)) do
    local team = {}
    if type(item) == "table" then
      team = copy_table(item)
      team.name = trim_string(team.name or team.team or team.id or team.key or "")
    else
      team.name = tostring(item)
    end
    if team.name ~= "" then
      team.index = tonumber(team.index) or index
      team.key = trim_string(team.key or team.id or team.team or team.name)
      teams[#teams + 1] = team
    end
  end
  return teams
end

function minigame_definition_counts(definitions)
  definitions = definitions or minigame_definitions_state()
  local team_count = 0
  for _, record in pairs(definitions.records_by_key or {}) do
    if type(record) == "table" and type(record.teams) == "table" then
      team_count = team_count + #record.teams
    end
  end
  return {
    definitions = table_count(definitions.records_by_key),
    teams = team_count,
  }
end

function load_minigame_definitions()
  local definitions = minigame_definitions_state()
  if definitions.loaded then
    return definitions
  end
  definitions.loaded = true
  definitions.records_by_key = definitions.records_by_key or {}

  local raw = read_file(MINIGAME_DEFINITIONS_PATH)
  if not raw or trim_string(raw) == "" then
    return definitions
  end

  local decoded, err = json_decode(raw)
  if err or type(decoded) ~= "table" then
    definitions.last_error = "definition JSON could not be parsed: " .. tostring(err or "not an object")
    return definitions
  end

  definitions.updated_at = tostring(decoded.updatedAt or decoded.updated_at or "")
  definitions.source = tostring(decoded.source or "")
  definitions.total_updates = tonumber(decoded.totalUpdates or decoded.total_updates) or 0
  definitions.records_by_key = {}
  local records = decoded.definitions or decoded.records or {}
  if type(records) == "table" then
    for key, record in pairs(records) do
      if type(record) == "table" then
        local copied = copy_table(record)
        copied.key = trim_string(copied.key or key)
        if copied.key ~= "" then
          definitions.records_by_key[copied.key] = copied
        end
      end
    end
  end
  definitions.last_error = ""
  return definitions
end

function save_minigame_definitions(definitions)
  definitions = definitions or minigame_definitions_state()
  local payload = {
    updatedAt = definitions.updated_at or "",
    source = definitions.source or "",
    totalUpdates = tonumber(definitions.total_updates) or 0,
    definitions = definitions.records_by_key or {},
    counts = minigame_definition_counts(definitions),
  }
  if not write_file(MINIGAME_DEFINITIONS_PATH, json_encode(payload) .. "\n") then
    definitions.last_error = "could not write minigame definitions"
    return false
  end
  definitions.last_error = ""
  return true
end

function normalize_minigame_definition(input)
  if type(input) ~= "table" then
    return nil, "definition options table is required"
  end

  local errors = {}
  local name = trim_string(input.name or input.minigame or input.displayName or "")
  if name ~= "" and name:match("[%c]") then
    errors[#errors + 1] = "name contains unsupported control characters"
  end
  local ruleset = trim_string(input.ruleset or input.id or input.minigameId or "")
  local index = tonumber(input.index or input.minigameIndex)
  if index == nil then
    index = 0
  else
    index = math.floor(index)
  end
  if name == "" and ruleset == "" then
    errors[#errors + 1] = "name or ruleset is required"
  end

  local persistent, persistent_error = normalize_minigame_definition_bool(input.persistent, "persistent")
  if persistent_error then
    errors[#errors + 1] = persistent_error
  end
  local owner_only, owner_only_error = normalize_minigame_definition_bool(input.ownerOnly or input.owneronly, "ownerOnly")
  if owner_only_error then
    errors[#errors + 1] = owner_only_error
  end

  local included_brick_mode = trim_string(input.includedBrickMode or input.includedbrickmode or input.brickMode or input.brickmode or "")
  if included_brick_mode ~= "" then
    included_brick_mode = included_brick_mode:lower()
    local valid_modes = {
      all = true,
      none = true,
      listed = true,
      include = true,
      exclude = true,
    }
    if not valid_modes[included_brick_mode] then
      errors[#errors + 1] = "includedBrickMode must be all, none, listed, include, or exclude"
    end
  end

  local max_players = tonumber(input.maxPlayers or input.maxplayers or "")
  if max_players ~= nil then
    max_players = math.floor(max_players)
    if max_players < 0 then
      errors[#errors + 1] = "maxPlayers must be zero or greater"
    end
  end

  if #errors > 0 then
    return nil, table.concat(errors, "; ")
  end

  local minigame = {
    name = name,
    index = index,
  }
  if ruleset ~= "" then
    minigame.ruleset = ruleset
  end
  local key = trim_string(input.key or "")
  if key == "" then
    key = minigame_key(minigame)
  end

  local teams = normalize_minigame_definition_teams(input.teams or input.teamNames or input.teamnames)
  local included_bricks = minigame_definition_text_list(input.includedBricks or input.includedbricks or input.bricks)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local definition = {
    key = key,
    name = name,
    index = index,
    ruleset = ruleset,
    owner = trim_string(input.owner or ""),
    mode = trim_string(input.mode or input.type or ""),
    persistent = persistent,
    ownerOnly = owner_only,
    includedBrickMode = included_brick_mode,
    includedBricks = included_bricks,
    maxPlayers = max_players,
    teams = teams,
    teamCount = #teams,
    source = trim_string(input.source or "bmf-definition"),
    updatedAt = now,
    liveEnforcement = "definition-only",
  }
  return definition, nil
end

function minigame_definition_matches(record, query)
  query = type(query) == "table" and query or {}
  record = type(record) == "table" and record or {}
  local direct = normalize_api_filter_value(minigame_query_value(query, "key") or "")
  local ruleset = normalize_api_filter_value(minigame_query_value(query, "ruleset", "minigameid", "id") or "")
  local name = normalize_api_filter_value(minigame_query_value(query, "name", "minigame", "displayName") or "")
  local index_value = minigame_query_value(query, "index", "minigameIndex")
  local wanted_index = tonumber(index_value)
  if direct ~= "" and normalize_api_filter_value(record.key) ~= direct then
    return false
  end
  if ruleset ~= "" and normalize_api_filter_value(record.ruleset) ~= ruleset then
    return false
  end
  if name ~= "" and normalize_api_filter_value(record.name) ~= name then
    return false
  end
  if index_value ~= nil and (wanted_index == nil or tonumber(record.index or 0) ~= wanted_index) then
    return false
  end
  return true
end

function minigame_definition_query_has_filter(query)
  return minigame_query_value(query, "key", "ruleset", "minigameid", "id", "name", "minigame", "displayName", "index", "minigameIndex") ~= nil
end

function minigame_definition_find(query)
  local definitions = load_minigame_definitions()
  local normalized = normalize_minigame_lookup_query(query, "key")
  local key = trim_string(minigame_query_value(normalized, "key") or "")
  if key ~= "" and definitions.records_by_key[key] then
    return key, definitions.records_by_key[key], normalized
  end
  for _, record_key in ipairs(minigame_sorted_keys(definitions.records_by_key)) do
    local record = definitions.records_by_key[record_key]
    if minigame_definition_matches(record, normalized) then
      return record_key, record, normalized
    end
  end
  return "", nil, normalized
end

function BMF.minigames.definitionStatus()
  local definitions = load_minigame_definitions()
  return result(true, "OK", "Minigame definition status collected", {
    path = MINIGAME_DEFINITIONS_PATH,
    updatedAt = definitions.updated_at or "",
    source = definitions.source or "",
    totalUpdates = tonumber(definitions.total_updates) or 0,
    loaded = definitions.loaded == true,
    lastError = tostring(definitions.last_error or ""),
    counts = minigame_definition_counts(definitions),
  })
end

function BMF.minigames.define(options)
  local definition, normalize_error = normalize_minigame_definition(options)
  if not definition then
    return result(false, "INVALID_MINIGAME_DEFINITION", normalize_error)
  end

  local definitions = load_minigame_definitions()
  local previous = definitions.records_by_key[definition.key]
  definition.revision = (previous and tonumber(previous.revision) or 0) + 1
  definitions.records_by_key[definition.key] = definition
  definitions.updated_at = definition.updatedAt
  definitions.source = definition.source
  definitions.total_updates = (tonumber(definitions.total_updates) or 0) + 1
  if not save_minigame_definitions(definitions) then
    return result(false, "MINIGAME_DEFINITION_WRITE_FAILED", definitions.last_error, {
      path = MINIGAME_DEFINITIONS_PATH,
      definition = definition,
    })
  end
  if write_status then
    write_status()
  end
  return result(true, "OK", "Minigame definition upserted", {
    definition = copy_table(definition),
    key = definition.key,
    updated = previous ~= nil,
    counts = minigame_definition_counts(definitions),
    path = MINIGAME_DEFINITIONS_PATH,
  })
end

function BMF.minigames.definitions(query)
  local definitions = load_minigame_definitions()
  local normalized = normalize_minigame_lookup_query(query, "key")
  local limit = minigame_query_limit(normalized, 50, 100)
  local has_filter = minigame_query_has_minigame_filter(normalized)
  local items = {}
  for _, key in ipairs(minigame_sorted_keys(definitions.records_by_key)) do
    if #items >= limit then
      break
    end
    local record = definitions.records_by_key[key]
    if type(record) == "table" and (not has_filter or minigame_definition_matches(record, normalized)) then
      items[#items + 1] = copy_table(record)
    end
  end
  return result(true, "OK", "Minigame definitions listed", {
    definitions = items,
    count = #items,
    total = table_count(definitions.records_by_key),
    query = normalized,
    counts = minigame_definition_counts(definitions),
    path = MINIGAME_DEFINITIONS_PATH,
    updatedAt = definitions.updated_at or "",
    source = definitions.source or "",
    totalUpdates = tonumber(definitions.total_updates) or 0,
    lastError = tostring(definitions.last_error or ""),
  })
end

function BMF.minigames.definition(query)
  local normalized = normalize_minigame_lookup_query(query, "key")
  if not minigame_definition_query_has_filter(normalized) then
    return result(false, "INVALID_MINIGAME_DEFINITION_QUERY", "Minigame definition key, name, ruleset, or index is required", {
      query = normalized,
      counts = minigame_definition_counts(load_minigame_definitions()),
    })
  end
  local key, record, normalized = minigame_definition_find(query)
  if not record then
    return result(false, "MINIGAME_DEFINITION_NOT_FOUND", "Minigame definition not found", {
      query = normalized,
      counts = minigame_definition_counts(load_minigame_definitions()),
    })
  end
  return result(true, "OK", "Minigame definition found", {
    key = key,
    definition = copy_table(record),
    query = normalized,
    counts = minigame_definition_counts(load_minigame_definitions()),
    path = MINIGAME_DEFINITIONS_PATH,
  })
end

function BMF.minigames.deleteDefinition(query, confirm)
  local token = confirm
  if type(query) == "table" then
    token = token or query.confirm or query.token
  end
  local normalized = normalize_minigame_lookup_query(query, "key")
  if not minigame_definition_query_has_filter(normalized) then
    return result(false, "INVALID_MINIGAME_DEFINITION_QUERY", "Minigame definition key, name, ruleset, or index is required", {
      query = normalized,
      counts = minigame_definition_counts(load_minigame_definitions()),
    })
  end
  if tostring(token or "") ~= "DELETE_MINIGAME_DEFINITION" then
    return result(false, "CONFIRMATION_REQUIRED", "Pass confirm=DELETE_MINIGAME_DEFINITION to delete a minigame definition.", {
      confirmRequired = "DELETE_MINIGAME_DEFINITION",
    })
  end

  local key, record, normalized = minigame_definition_find(query)
  if not record then
    return result(false, "MINIGAME_DEFINITION_NOT_FOUND", "Minigame definition not found", {
      query = normalized,
      counts = minigame_definition_counts(load_minigame_definitions()),
    })
  end
  local definitions = load_minigame_definitions()
  definitions.records_by_key[key] = nil
  definitions.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  definitions.source = "definition-delete"
  definitions.total_updates = (tonumber(definitions.total_updates) or 0) + 1
  if not save_minigame_definitions(definitions) then
    return result(false, "MINIGAME_DEFINITION_WRITE_FAILED", definitions.last_error, {
      path = MINIGAME_DEFINITIONS_PATH,
      key = key,
    })
  end
  if write_status then
    write_status()
  end
  return result(true, "OK", "Minigame definition deleted", {
    key = key,
    definition = copy_table(record),
    deleted = true,
    counts = minigame_definition_counts(definitions),
    path = MINIGAME_DEFINITIONS_PATH,
  })
end

function minigame_definition_team_label(team)
  if type(team) == "table" then
    return trim_string(team.name or team.team or team.id or team.key or "")
  end
  return trim_string(team or "")
end

function minigame_definition_team_labels(teams)
  local labels = {}
  local by_normalized = {}
  if type(teams) ~= "table" then
    return labels, by_normalized
  end
  for _, team in ipairs(teams) do
    local label = minigame_definition_team_label(team)
    local normalized = normalize_api_filter_value(label)
    if label ~= "" and not by_normalized[normalized] then
      labels[#labels + 1] = label
      by_normalized[normalized] = label
    end
  end
  return labels, by_normalized
end

function minigame_definition_observed_minigame(data, definition)
  data = type(data) == "table" and data or new_minigame_data_state()
  definition = type(definition) == "table" and definition or {}
  local queries = {}
  local direct_key = trim_string(definition.key or "")
  local ruleset = trim_string(definition.ruleset or "")
  local name = trim_string(definition.name or "")
  if direct_key ~= "" then
    queries[#queries + 1] = { key = direct_key }
  end
  if ruleset ~= "" then
    queries[#queries + 1] = { ruleset = ruleset }
  end
  if name ~= "" then
    queries[#queries + 1] = { name = name, index = definition.index or 0 }
    queries[#queries + 1] = { name = name }
  end

  local last_matches = {}
  local last_query = {}
  for _, query in ipairs(queries) do
    local key, record, matches, _, normalized = minigame_find_by_query(data, query)
    last_matches = matches or last_matches
    last_query = normalized or query
    if record then
      return key, record, matches or {}, last_query
    end
  end
  return "", nil, last_matches, last_query
end

function minigame_definition_reconcile_item(data, definition)
  definition = type(definition) == "table" and definition or {}
  local key = trim_string(definition.key or "")
  local observed_key, observed, matches, lookup_query = minigame_definition_observed_minigame(data, definition)
  local context = nil
  if observed then
    context = minigame_context_for_key(data, observed_key, observed, matches)
  end

  local expected_teams = minigame_definition_team_labels(definition.teams or {})
  local observed_teams = {}
  local observed_map = {}
  if context then
    observed_teams, observed_map = minigame_definition_team_labels(context.teams or {})
  end

  local missing_teams = {}
  for _, team in ipairs(expected_teams) do
    if not observed_map[normalize_api_filter_value(team)] then
      missing_teams[#missing_teams + 1] = team
    end
  end

  local status = "missing"
  if observed then
    status = #missing_teams > 0 and "team-mismatch" or "present"
  end

  return {
    key = key,
    definition = copy_table(definition),
    status = status,
    present = observed ~= nil,
    observedKey = observed_key,
    observedMinigame = observed and copy_table(observed) or nil,
    expectedTeams = expected_teams,
    observedTeams = observed_teams,
    missingTeams = missing_teams,
    query = copy_table(lookup_query or {}),
    counts = {
      expectedTeams = #expected_teams,
      observedTeams = #observed_teams,
      missingTeams = #missing_teams,
      members = context and context.counts and context.counts.members or 0,
      teamMemberships = context and context.counts and context.counts.teamMemberships or 0,
      leaderboards = context and context.counts and context.counts.leaderboards or 0,
    },
  }
end

function BMF.minigames.reconcileDefinitions(query)
  local listed = BMF.minigames.definitions(query)
  if not listed.ok then
    return listed
  end
  local definitions_data = listed.data or {}
  local definitions = definitions_data.definitions or {}
  local data = state.minigame_data or new_minigame_data_state()
  local items = {}
  local summary = {
    definitions = #definitions,
    checked = 0,
    present = 0,
    missing = 0,
    teamMismatches = 0,
    expectedTeams = 0,
    observedTeams = 0,
  }

  for _, definition in ipairs(definitions) do
    local item = minigame_definition_reconcile_item(data, definition)
    items[#items + 1] = item
    summary.checked = summary.checked + 1
    summary.expectedTeams = summary.expectedTeams + ((item.counts and item.counts.expectedTeams) or 0)
    summary.observedTeams = summary.observedTeams + ((item.counts and item.counts.observedTeams) or 0)
    if item.status == "present" then
      summary.present = summary.present + 1
    elseif item.status == "team-mismatch" then
      summary.teamMismatches = summary.teamMismatches + 1
    else
      summary.missing = summary.missing + 1
    end
  end

  return result(true, "OK", "Minigame definitions reconciled", {
    items = items,
    count = #items,
    summary = summary,
    query = definitions_data.query or normalize_minigame_lookup_query(query, "key"),
    definitionCounts = definitions_data.counts or {},
    dataCounts = minigame_data_counts(data),
    definitionsPath = MINIGAME_DEFINITIONS_PATH,
    definitionsUpdatedAt = definitions_data.updatedAt or "",
    dataUpdatedAt = data.updated_at or "",
    dataSource = data.source or "",
    dataTotalUpdates = tonumber(data.total_updates) or 0,
  })
end

function minigame_event_metadata(legacy_name, event_name, payload, emitted_at, event_id)
  payload = type(payload) == "table" and payload or {}
  local minigame = type(payload.minigame) == "table" and payload.minigame or payload
  local player = type(payload.player) == "table" and payload.player or {}
  local team = type(payload.team) == "table" and payload.team or {}
  local mkey = minigame_key(minigame)
  local pkey = player_key(player)
  local tkey = team_key(team, minigame)
  local source = tostring(payload.source or "")
  return {
    event = event_name,
    legacyEvent = legacy_name,
    legacy_event = legacy_name,
    eventId = tostring(event_id or ""),
    event_id = tostring(event_id or ""),
    emittedAt = emitted_at,
    emitted_at = emitted_at,
    source = source,
    minigameKey = mkey,
    minigame_key = mkey,
    playerKey = pkey,
    player_key = pkey,
    teamKey = tkey,
    team_key = tkey,
  }
end

function minigame_enrich_event_payload(legacy_name, event_name, payload, emitted_at, event_id)
  local event_payload = type(payload) == "table" and copy_table(payload) or {}
  local metadata = minigame_event_metadata(legacy_name, event_name, event_payload, emitted_at, event_id)
  event_payload._bmf = type(event_payload._bmf) == "table" and event_payload._bmf or {}
  for key, value in pairs(metadata) do
    event_payload._bmf[key] = value
  end
  return event_payload
end

local function remember_minigame_player(data, player)
  local key = player_key(player)
  if key ~= "" then
    data.players_by_key[key] = copy_table(player or {})
  end
  return key
end

local function remember_minigame(data, minigame)
  local key = minigame_key(minigame)
  if key ~= "" then
    local next_value = copy_table(minigame or {})
    next_value.key = key
    data.minigames_by_key[key] = next_value
  end
  return key
end

local function remember_team(data, team, minigame)
  local key = team_key(team, minigame)
  if key ~= "" then
    local next_value = copy_table(team or {})
    next_value.key = key
    local minigame_parent = minigame_key(minigame or team.minigame or {})
    if minigame_parent ~= "" then
      next_value.minigameKey = minigame_parent
    end
    data.teams_by_key[key] = next_value
  end
  return key
end

local function remember_membership(data, player, minigame, team)
  local pkey = remember_minigame_player(data, player)
  local mkey = remember_minigame(data, minigame)
  if pkey ~= "" and mkey ~= "" then
    data.memberships_by_player[pkey] = {
      player = copy_table(player or {}),
      minigame = copy_table(minigame or {}),
      minigameKey = mkey,
    }
    local tkey = remember_team(data, team, minigame)
    if tkey ~= "" then
      data.team_memberships_by_player[pkey] = {
        player = copy_table(player or {}),
        minigame = copy_table(minigame or {}),
        minigameKey = mkey,
        team = copy_table(team or {}),
        teamKey = tkey,
      }
    else
      data.team_memberships_by_player[pkey] = nil
    end
  end
end

local function forget_membership(data, player, minigame)
  local pkey = player_key(player)
  if pkey == "" then
    return
  end
  local existing = data.memberships_by_player[pkey]
  local leaving = minigame_key(minigame)
  if not existing or leaving == "" or existing.minigameKey == leaving then
    data.memberships_by_player[pkey] = nil
    data.team_memberships_by_player[pkey] = nil
  end
end

function minigame_snapshot_records(payload)
  payload = type(payload) == "table" and payload or {}
  local minigames = payload.minigames
  if type(minigames) ~= "table" and type(payload.snapshot) == "table" then
    minigames = payload.snapshot.minigames
  end
  local records = {}
  if type(minigames) ~= "table" then
    return records
  end

  for _, minigame in ipairs(minigames) do
    if type(minigame) == "table" then
      records[#records + 1] = minigame
    end
  end
  if #records == 0 then
    for _, minigame in pairs(minigames) do
      if type(minigame) == "table" then
        records[#records + 1] = minigame
      end
    end
  end
  return records
end

local function remember_minigame_snapshot(data, payload)
  local minigames = minigame_snapshot_records(payload)
  if #minigames == 0 then
    return
  end

  local snapshot_data = {
    minigames_by_key = {},
    players_by_key = data.players_by_key or {},
    memberships_by_player = {},
    teams_by_key = {},
    team_memberships_by_player = {},
    leaderboards_by_player = data.leaderboards_by_player or {},
    rounds_by_key = data.rounds_by_key or {},
  }

  for _, minigame in ipairs(minigames) do
    local mkey = remember_minigame(snapshot_data, minigame)
    if mkey ~= "" then
      local members = type(minigame.members) == "table" and minigame.members or {}
      for _, player in ipairs(members) do
        remember_membership(snapshot_data, player, minigame, nil)
      end
      local teams = type(minigame.teams) == "table" and minigame.teams or {}
      for _, team in ipairs(teams) do
        remember_team(snapshot_data, team, minigame)
        local team_members = type(team.members) == "table" and team.members or {}
        for _, player in ipairs(team_members) do
          remember_membership(snapshot_data, player, minigame, team)
        end
      end
    end
  end

  data.minigames_by_key = snapshot_data.minigames_by_key
  data.players_by_key = snapshot_data.players_by_key
  data.memberships_by_player = snapshot_data.memberships_by_player
  data.teams_by_key = snapshot_data.teams_by_key
  data.team_memberships_by_player = snapshot_data.team_memberships_by_player
end

local function remember_minigame_data(name, payload, emitted_at)
  local data = state.minigame_data
  local event_payload = type(payload) == "table" and payload or {}
  local now = emitted_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  data.updated_at = now
  data.source = tostring(event_payload.source or data.source or "")
  data.total_updates = (tonumber(data.total_updates) or 0) + 1
  data.last_event = {
    name = name,
    event = "minigames." .. tostring(name or ""),
    emittedAt = now,
    source = event_payload.source,
  }

  if name == "snapshot" then
    remember_minigame_snapshot(data, event_payload)
  elseif name == "created" then
    remember_minigame(data, event_payload.minigame or event_payload)
  elseif name == "deleted" then
    local key = minigame_key(event_payload.minigame or event_payload)
    if key ~= "" then
      data.minigames_by_key[key] = nil
      data.rounds_by_key[key] = nil
      for player, membership in pairs(data.memberships_by_player or {}) do
        if type(membership) == "table" and membership.minigameKey == key then
          data.memberships_by_player[player] = nil
        end
      end
      for player, membership in pairs(data.team_memberships_by_player or {}) do
        if type(membership) == "table" and membership.minigameKey == key then
          data.team_memberships_by_player[player] = nil
        end
      end
      for team, value in pairs(data.teams_by_key or {}) do
        if type(value) == "table" and value.minigameKey == key then
          data.teams_by_key[team] = nil
        end
      end
      for player, value in pairs(data.leaderboards_by_player or {}) do
        if type(value) == "table" and value.minigameKey == key then
          data.leaderboards_by_player[player] = nil
        end
      end
    end
  elseif name == "joinminigame" then
    remember_membership(data, event_payload.player, event_payload.minigame, event_payload.team)
  elseif name == "leaveminigame" then
    forget_membership(data, event_payload.player, event_payload.minigame)
    if type(event_payload.newMinigame) == "table" then
      remember_membership(data, event_payload.player, event_payload.newMinigame, event_payload.newTeam)
    end
  elseif name == "teamchange" then
    remember_membership(data, event_payload.player, event_payload.minigame, event_payload.team)
  elseif name == "roundchange" or name == "roundend" then
    local minigame = event_payload.minigame or event_payload
    local key = remember_minigame(data, minigame)
    if key ~= "" then
      data.rounds_by_key[key] = {
        minigame = copy_table(minigame or {}),
        minigameKey = key,
        roundEnded = name == "roundend",
        event = name,
        updatedAt = now,
      }
    end
  elseif name == "leaderboardchange" or name == "score" or name == "kill" or name == "death" then
    local pkey = remember_minigame_player(data, event_payload.player)
    local mkey = remember_minigame(data, event_payload.minigame)
    if pkey ~= "" then
      data.leaderboards_by_player[pkey] = {
        player = copy_table(event_payload.player or {}),
        minigame = copy_table(event_payload.minigame or {}),
        minigameKey = mkey,
        leaderboard = copy_table(event_payload.leaderboard or {}),
        oldLeaderboard = copy_table(event_payload.oldLeaderboard or {}),
        updatedAt = now,
      }
    end
  end
end

local function record_minigame_event(name, event_name, payload)
  local now = payload and payload._bmf and payload._bmf.emittedAt or os.date("!%Y-%m-%dT%H:%M:%SZ")
  local stats = state.minigame_events
  stats.total = (tonumber(stats.total) or 0) + 1
  stats.by_event[name] = (tonumber(stats.by_event[name]) or 0) + 1
  local entry = {
    eventId = tostring(payload and payload._bmf and payload._bmf.eventId or stats.total),
    event = event_name,
    name = name,
    emittedAt = now,
    source = tostring(payload and payload.source or payload and payload._bmf and payload._bmf.source or ""),
    minigameKey = tostring(payload and payload._bmf and payload._bmf.minigameKey or ""),
    playerKey = tostring(payload and payload._bmf and payload._bmf.playerKey or ""),
    teamKey = tostring(payload and payload._bmf and payload._bmf.teamKey or ""),
    payload = copy_table(payload or {}),
  }
  stats.last = entry
  stats.recent[#stats.recent + 1] = entry
  while #stats.recent > (tonumber(stats.max_recent) or 50) do
    table.remove(stats.recent, 1)
  end
  if write_status then
    write_status()
  end
  return entry
end

BMF.minigames.on = function(name, handler)
  local legacy_name, name_error = normalize_minigame_event_name(name)
  if not legacy_name then
    return nil, name_error
  end
  if type(handler) ~= "function" then
    return nil, "handler function is required"
  end
  local event_name = "minigames." .. legacy_name
  return BMF.events.on(event_name, function(payload, emitted_event_name)
    return handler(payload, legacy_name, emitted_event_name)
  end)
end

BMF.minigames.off = function(id)
  return BMF.events.off(id)
end

BMF.minigames.listenerCount = function(name)
  local legacy_name = normalize_minigame_event_name(name)
  if not legacy_name then
    return 0
  end
  return BMF.events.listenerCount("minigames." .. legacy_name)
end

BMF.minigames.emitEvent = function(name, payload)
  local legacy_name, name_error = normalize_minigame_event_name(name)
  if not legacy_name then
    return result(false, "INVALID_MINIGAME_EVENT", name_error)
  end

  local event_name = "minigames." .. legacy_name
  local emitted_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local event_id = tostring((tonumber(state.minigame_events.total) or 0) + 1)
  local event_payload = minigame_enrich_event_payload(legacy_name, event_name, payload, emitted_at, event_id)

  local emitted = BMF.events.emit(event_name, event_payload)
  remember_minigame_data(legacy_name, event_payload, event_payload._bmf.emittedAt)
  local entry = record_minigame_event(legacy_name, event_name, event_payload)
  return result(emitted.ok, emitted.ok and "OK" or emitted.code, "Minigame event emitted", {
    event = event_name,
    legacyEvent = legacy_name,
    payload = event_payload,
    handlers = emitted.data and emitted.data.handlers or 0,
    errors = emitted.data and emitted.data.errors or {},
    total = state.minigame_events.total,
    count = state.minigame_events.by_event[legacy_name] or 0,
    last = entry,
  })
end

BMF.minigames.eventStatus = function()
  return result(true, "OK", "Minigame event status collected", {
    total = state.minigame_events.total or 0,
    byEvent = copy_table(state.minigame_events.by_event or {}),
    recent = copy_table(state.minigame_events.recent or {}),
    recentCount = #(state.minigame_events.recent or {}),
    last = type(state.minigame_events.last) == "table" and copy_table(state.minigame_events.last) or nil,
    eventLogPath = EVENT_LOG_PATH,
    eventNames = {
      "joinminigame",
      "leaveminigame",
      "roundchange",
      "roundend",
      "leaderboardchange",
      "score",
      "kill",
      "death",
      "snapshot",
      "created",
      "deleted",
      "teamchange",
    },
  })
end

function new_minigame_data_state()
  return {
    updated_at = "",
    source = "",
    total_updates = 0,
    last_event = nil,
    minigames_by_key = {},
    players_by_key = {},
    memberships_by_player = {},
    teams_by_key = {},
    team_memberships_by_player = {},
    leaderboards_by_player = {},
    rounds_by_key = {},
  }
end

function minigame_data_counts(data)
  return {
    minigames = table_count(data.minigames_by_key),
    players = table_count(data.players_by_key),
    memberships = table_count(data.memberships_by_player),
    teams = table_count(data.teams_by_key),
    teamMemberships = table_count(data.team_memberships_by_player),
    leaderboards = table_count(data.leaderboards_by_player),
    rounds = table_count(data.rounds_by_key),
  }
end

function minigame_sorted_keys(values)
  local keys = {}
  if type(values) ~= "table" then
    return keys
  end
  for key in pairs(values) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

function minigame_query_value(query, ...)
  if type(query) ~= "table" then
    return nil
  end
  for index = 1, select("#", ...) do
    local key = select(index, ...)
    local value = query[key]
    if value ~= nil and trim_string(value) ~= "" then
      return value
    end
  end
  return nil
end

function normalize_minigame_lookup_query(query, default_key)
  local normalized = {}
  if type(query) == "table" then
    normalized = copy_table(query)
  elseif query ~= nil then
    normalized[default_key or "key"] = tostring(query)
  end
  local has_named_value = false
  for key, value in pairs(normalized) do
    if key ~= "_positional" and value ~= nil and trim_string(value) ~= "" then
      has_named_value = true
      break
    end
  end
  if not has_named_value and type(normalized._positional) == "table" and normalized._positional[1] then
    normalized[default_key or "key"] = normalized._positional[1]
  end
  return normalized
end

function minigame_record_summary(key, record)
  record = type(record) == "table" and record or {}
  return {
    key = key,
    name = record.name or record.minigame or record.displayName or "",
    ruleset = record.ruleset or record.id or "",
    index = record.index,
  }
end

function minigame_find_by_query(data, query)
  local normalized = normalize_minigame_lookup_query(query, "key")
  local minigames = data.minigames_by_key or {}
  local direct_key = trim_string(minigame_query_value(normalized, "key") or "")
  if direct_key ~= "" and minigames[direct_key] then
    return direct_key, minigames[direct_key], { minigame_record_summary(direct_key, minigames[direct_key]) }, nil, normalized
  end

  local ruleset = trim_string(minigame_query_value(normalized, "ruleset", "minigameid", "id") or "")
  if ruleset ~= "" then
    local ruleset_key = minigame_key({ ruleset = ruleset })
    if minigames[ruleset_key] then
      return ruleset_key, minigames[ruleset_key], { minigame_record_summary(ruleset_key, minigames[ruleset_key]) }, nil, normalized
    end
  end

  local name = trim_string(minigame_query_value(normalized, "name", "minigame", "displayName") or "")
  local index_value = minigame_query_value(normalized, "index", "minigameIndex")
  local wanted_index = tonumber(index_value)
  if name ~= "" and index_value ~= nil and wanted_index ~= nil then
    local name_key = minigame_key({ name = name, index = wanted_index })
    if minigames[name_key] then
      return name_key, minigames[name_key], { minigame_record_summary(name_key, minigames[name_key]) }, nil, normalized
    end
  end

  local has_filter = direct_key ~= "" or ruleset ~= "" or name ~= "" or index_value ~= nil
  if not has_filter then
    return "", nil, {}, "minigame key, ruleset, name, or index is required", normalized
  end

  local direct_filter = normalize_api_filter_value(direct_key)
  local ruleset_filter = normalize_api_filter_value(ruleset)
  local name_filter = normalize_api_filter_value(name)
  local matches = {}
  for _, key in ipairs(minigame_sorted_keys(minigames)) do
    local record = minigames[key]
    if type(record) == "table" then
      local ok = true
      if direct_filter ~= "" then
        ok = normalize_api_filter_value(key) == direct_filter
          or normalize_api_filter_value(record.key) == direct_filter
          or normalize_api_filter_value(record.ruleset or record.id) == direct_filter
          or normalize_api_filter_value(record.name or record.minigame or record.displayName) == direct_filter
      end
      if ok and ruleset_filter ~= "" then
        ok = normalize_api_filter_value(record.ruleset or record.id) == ruleset_filter
      end
      if ok and name_filter ~= "" then
        ok = normalize_api_filter_value(record.name or record.minigame or record.displayName) == name_filter
      end
      if ok and index_value ~= nil then
        ok = wanted_index ~= nil and tonumber(record.index or record.minigameIndex) == wanted_index
      end
      if ok then
        matches[#matches + 1] = minigame_record_summary(key, record)
      end
    end
  end

  if #matches == 0 then
    return "", nil, matches, "minigame not found", normalized
  end
  local first_key = matches[1].key
  return first_key, minigames[first_key], matches, nil, normalized
end

function minigame_context_for_key(data, key, record, matches)
  local members = {}
  local teams = {}
  local team_memberships = {}
  local leaderboards = {}

  for _, player_key_name in ipairs(minigame_sorted_keys(data.memberships_by_player)) do
    local membership = data.memberships_by_player[player_key_name]
    if type(membership) == "table" and membership.minigameKey == key then
      local item = copy_table(membership)
      item.playerKey = player_key_name
      members[#members + 1] = item
    end
  end

  for _, team_key_name in ipairs(minigame_sorted_keys(data.teams_by_key)) do
    local team = data.teams_by_key[team_key_name]
    if type(team) == "table" and team.minigameKey == key then
      local item = copy_table(team)
      item.key = item.key or team_key_name
      teams[#teams + 1] = item
    end
  end

  for _, player_key_name in ipairs(minigame_sorted_keys(data.team_memberships_by_player)) do
    local membership = data.team_memberships_by_player[player_key_name]
    if type(membership) == "table" and membership.minigameKey == key then
      local item = copy_table(membership)
      item.playerKey = player_key_name
      team_memberships[#team_memberships + 1] = item
    end
  end

  for _, player_key_name in ipairs(minigame_sorted_keys(data.leaderboards_by_player)) do
    local leaderboard = data.leaderboards_by_player[player_key_name]
    if type(leaderboard) == "table" and leaderboard.minigameKey == key then
      local item = copy_table(leaderboard)
      item.playerKey = player_key_name
      leaderboards[#leaderboards + 1] = item
    end
  end

  return {
    key = key,
    minigame = copy_table(record or {}),
    members = members,
    teams = teams,
    teamMemberships = team_memberships,
    leaderboards = leaderboards,
    round = type(data.rounds_by_key[key]) == "table" and copy_table(data.rounds_by_key[key]) or nil,
    matches = copy_table(matches or {}),
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
    counts = {
      members = #members,
      teams = #teams,
      teamMemberships = #team_memberships,
      leaderboards = #leaderboards,
      matches = #(matches or {}),
    },
  }
end

function player_matches_query(key, player, normalized)
  local direct = normalize_api_filter_value(minigame_query_value(normalized, "key", "player", "playerid", "uuid", "id") or "")
  local name = normalize_api_filter_value(minigame_query_value(normalized, "name", "displayName", "username") or "")
  local state_value = normalize_api_filter_value(minigame_query_value(normalized, "state") or "")
  local controller = normalize_api_filter_value(minigame_query_value(normalized, "controller") or "")
  if direct == "" and name == "" and state_value == "" and controller == "" then
    return false
  end

  player = type(player) == "table" and player or {}
  if direct ~= "" then
    return normalize_api_filter_value(key) == direct
      or normalize_api_filter_value(player.id or player.uuid) == direct
      or normalize_api_filter_value(player.name or player.displayName or player.username) == direct
      or normalize_api_filter_value(player.state) == direct
      or normalize_api_filter_value(player.controller) == direct
  end
  if name ~= "" and normalize_api_filter_value(player.name or player.displayName or player.username) ~= name then
    return false
  end
  if state_value ~= "" and normalize_api_filter_value(player.state) ~= state_value then
    return false
  end
  if controller ~= "" and normalize_api_filter_value(player.controller) ~= controller then
    return false
  end
  return true
end

function minigame_find_player_by_query(data, query)
  local normalized = normalize_minigame_lookup_query(query, "player")
  local players = data.players_by_key or {}
  local direct = trim_string(minigame_query_value(normalized, "key", "player", "playerid", "uuid", "id") or "")
  if direct ~= "" and players[direct] then
    return direct, players[direct], nil, normalized
  end

  for _, key in ipairs(minigame_sorted_keys(players)) do
    local player = players[key]
    if player_matches_query(key, player, normalized) then
      return key, player, nil, normalized
    end
  end

  for _, key in ipairs(minigame_sorted_keys(data.memberships_by_player)) do
    local membership = data.memberships_by_player[key]
    if type(membership) == "table" and player_matches_query(key, membership.player, normalized) then
      return key, membership.player, nil, normalized
    end
  end

  for _, key in ipairs(minigame_sorted_keys(data.leaderboards_by_player)) do
    local leaderboard = data.leaderboards_by_player[key]
    if type(leaderboard) == "table" and player_matches_query(key, leaderboard.player, normalized) then
      return key, leaderboard.player, nil, normalized
    end
  end

  if direct == "" and minigame_query_value(normalized, "name", "displayName", "username", "state", "controller") == nil then
    return "", nil, "player id, name, state, or controller is required", normalized
  end
  return "", nil, "minigame player not found", normalized
end

function minigame_player_context(data, player_key_name, player)
  local membership = type(data.memberships_by_player[player_key_name]) == "table" and copy_table(data.memberships_by_player[player_key_name]) or nil
  local team_membership = type(data.team_memberships_by_player[player_key_name]) == "table" and copy_table(data.team_memberships_by_player[player_key_name]) or nil
  local leaderboard = type(data.leaderboards_by_player[player_key_name]) == "table" and copy_table(data.leaderboards_by_player[player_key_name]) or nil
  local minigame_key_name = ""
  if membership and membership.minigameKey then
    minigame_key_name = membership.minigameKey
  elseif team_membership and team_membership.minigameKey then
    minigame_key_name = team_membership.minigameKey
  elseif leaderboard and leaderboard.minigameKey then
    minigame_key_name = leaderboard.minigameKey
  end

  local team_key_name = team_membership and team_membership.teamKey or ""
  return {
    playerKey = player_key_name,
    player = copy_table(player or {}),
    membership = membership,
    teamMembership = team_membership,
    leaderboard = leaderboard,
    minigameKey = minigame_key_name,
    minigame = minigame_key_name ~= "" and copy_table(data.minigames_by_key[minigame_key_name] or {}) or nil,
    teamKey = team_key_name,
    team = team_key_name ~= "" and copy_table(data.teams_by_key[team_key_name] or {}) or nil,
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
  }
end

function minigame_query_limit(query, fallback, max_limit)
  local raw = minigame_query_value(query, "limit", "max", "count")
  local limit = tonumber(raw) or fallback or 25
  if limit < 1 then
    limit = 1
  end
  max_limit = max_limit or 100
  if limit > max_limit then
    limit = max_limit
  end
  return limit
end

function minigame_query_has_player_filter(query)
  return minigame_query_value(query, "player", "playerid", "uuid", "id", "state", "controller", "displayName", "username") ~= nil
end

function minigame_query_has_minigame_filter(query)
  return minigame_query_value(query, "minigameKey", "minigamekey", "ruleset", "minigameid", "minigame", "name", "index", "minigameIndex", "key") ~= nil
end

function minigame_query_minigame_key(data, query)
  local normalized = normalize_minigame_lookup_query(query, "key")
  local explicit_key = minigame_query_value(normalized, "minigameKey", "minigamekey")
  if explicit_key ~= nil and trim_string(explicit_key) ~= "" then
    normalized.key = explicit_key
  end
  if not minigame_query_has_minigame_filter(normalized) then
    return "", nil, nil, normalized
  end
  local key, record, matches, lookup_error = minigame_find_by_query(data, normalized)
  if not record then
    return "", nil, lookup_error or "minigame not found", normalized, matches
  end
  return key, record, nil, normalized, matches
end

function minigame_list_item(data, key, record, matches)
  local context = minigame_context_for_key(data, key, record, matches or { minigame_record_summary(key, record) })
  return {
    key = key,
    minigame = context.minigame,
    members = context.counts.members or 0,
    teams = context.counts.teams or 0,
    teamMemberships = context.counts.teamMemberships or 0,
    leaderboards = context.counts.leaderboards or 0,
    round = context.round,
  }
end

function minigame_event_matches_minigame(entry, query)
  if not minigame_query_has_minigame_filter(query) then
    return true
  end
  local payload = type(entry) == "table" and type(entry.payload) == "table" and entry.payload or {}
  local minigame = type(payload.minigame) == "table" and payload.minigame or payload
  local direct = normalize_api_filter_value(minigame_query_value(query, "minigameKey", "minigamekey", "key") or "")
  local ruleset = normalize_api_filter_value(minigame_query_value(query, "ruleset", "minigameid") or "")
  local name = normalize_api_filter_value(minigame_query_value(query, "minigame", "name") or "")
  local index_value = minigame_query_value(query, "index", "minigameIndex")
  local wanted_index = tonumber(index_value)
  local key = minigame_key(minigame)
  if direct ~= "" and normalize_api_filter_value(key) ~= direct then
    return false
  end
  if ruleset ~= "" and normalize_api_filter_value(minigame.ruleset or minigame.id) ~= ruleset then
    return false
  end
  if name ~= "" and normalize_api_filter_value(minigame.name or minigame.minigame or minigame.displayName) ~= name then
    return false
  end
  if index_value ~= nil and (wanted_index == nil or tonumber(minigame.index or minigame.minigameIndex) ~= wanted_index) then
    return false
  end
  return true
end

BMF.minigames.dataList = function(query)
  local data = state.minigame_data
  local normalized = normalize_minigame_lookup_query(query, "key")
  local limit = minigame_query_limit(normalized, 50, 100)
  local items = {}

  if minigame_query_has_minigame_filter(normalized) then
    local key, record, lookup_error, _, matches = minigame_query_minigame_key(data, normalized)
    if not record then
      return result(false, "MINIGAME_NOT_FOUND", lookup_error or "Minigame not found", {
        query = normalized,
        matches = copy_table(matches or {}),
        counts = minigame_data_counts(data),
      })
    end
    for _, match in ipairs(matches or { minigame_record_summary(key, record) }) do
      if #items >= limit then
        break
      end
      local match_key = match.key or key
      local match_record = data.minigames_by_key[match_key]
      if type(match_record) == "table" then
        items[#items + 1] = minigame_list_item(data, match_key, match_record, matches)
      end
    end
  else
    for _, key in ipairs(minigame_sorted_keys(data.minigames_by_key)) do
      if #items >= limit then
        break
      end
      local record = data.minigames_by_key[key]
      if type(record) == "table" then
        items[#items + 1] = minigame_list_item(data, key, record)
      end
    end
  end

  return result(true, "OK", "Minigame data listed", {
    items = items,
    count = #items,
    total = table_count(data.minigames_by_key),
    counts = minigame_data_counts(data),
    query = normalized,
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
  })
end

BMF.minigames.players = function(query)
  local data = state.minigame_data
  local normalized = normalize_minigame_lookup_query(query, "player")
  local limit = minigame_query_limit(normalized, 50, 100)
  local minigame_key_name = ""
  local lookup_error = nil
  if minigame_query_has_minigame_filter(normalized) and minigame_query_value(normalized, "player", "playerid", "uuid", "state", "controller", "username") == nil then
    local found_key, _, err = minigame_query_minigame_key(data, normalized)
    if err ~= nil then
      lookup_error = err
    else
      minigame_key_name = found_key
    end
  elseif minigame_query_value(normalized, "minigameKey", "minigamekey", "ruleset", "minigame") ~= nil then
    local found_key, _, err = minigame_query_minigame_key(data, normalized)
    if err ~= nil then
      lookup_error = err
    else
      minigame_key_name = found_key
    end
  end
  if lookup_error ~= nil then
    return result(false, "MINIGAME_NOT_FOUND", lookup_error, {
      query = normalized,
      counts = minigame_data_counts(data),
    })
  end

  local keys = {}
  local seen = {}
  for _, source in ipairs({ data.players_by_key, data.memberships_by_player, data.team_memberships_by_player, data.leaderboards_by_player }) do
    for key in pairs(source or {}) do
      if not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  local items = {}
  local player_filter = minigame_query_has_player_filter(normalized)
  for _, key in ipairs(keys) do
    if #items >= limit then
      break
    end
    local player = data.players_by_key[key] or (data.memberships_by_player[key] and data.memberships_by_player[key].player) or {}
    local context = minigame_player_context(data, key, player)
    local ok = true
    if minigame_key_name ~= "" and context.minigameKey ~= minigame_key_name then
      ok = false
    end
    if ok and player_filter and not player_matches_query(key, context.player or {}, normalized) then
      ok = false
    end
    if ok then
      items[#items + 1] = context
    end
  end

  return result(true, "OK", "Minigame players listed", {
    players = items,
    count = #items,
    total = #keys,
    minigameKey = minigame_key_name,
    query = normalized,
    counts = minigame_data_counts(data),
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
  })
end

BMF.minigames.teams = function(query)
  local data = state.minigame_data
  local normalized = normalize_minigame_lookup_query(query, "team")
  local limit = minigame_query_limit(normalized, 50, 100)
  local minigame_key_name = ""
  if minigame_query_value(normalized, "minigameKey", "minigamekey", "ruleset", "minigame") ~= nil then
    local found_key, _, lookup_error = minigame_query_minigame_key(data, normalized)
    if lookup_error ~= nil then
      return result(false, "MINIGAME_NOT_FOUND", lookup_error, {
        query = normalized,
        counts = minigame_data_counts(data),
      })
    end
    minigame_key_name = found_key
  end

  local team_filter = normalize_api_filter_value(minigame_query_value(normalized, "team", "teamKey", "teamkey", "id") or "")
  local items = {}
  for _, key in ipairs(minigame_sorted_keys(data.teams_by_key)) do
    if #items >= limit then
      break
    end
    local team = data.teams_by_key[key]
    if type(team) == "table" then
      local ok = true
      if minigame_key_name ~= "" and team.minigameKey ~= minigame_key_name then
        ok = false
      end
      if ok and team_filter ~= "" then
        ok = normalize_api_filter_value(key) == team_filter
          or normalize_api_filter_value(team.key) == team_filter
          or normalize_api_filter_value(team.team or team.id or team.name) == team_filter
      end
      if ok then
        local item = copy_table(team)
        item.key = item.key or key
        item.memberCount = 0
        for _, membership in pairs(data.team_memberships_by_player or {}) do
          if type(membership) == "table" and membership.teamKey == key then
            item.memberCount = item.memberCount + 1
          end
        end
        items[#items + 1] = item
      end
    end
  end

  return result(true, "OK", "Minigame teams listed", {
    teams = items,
    count = #items,
    total = table_count(data.teams_by_key),
    minigameKey = minigame_key_name,
    query = normalized,
    counts = minigame_data_counts(data),
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
  })
end

local function minigame_leaderboard_score(row)
  row = type(row) == "table" and row or {}
  local values = type(row.leaderboard) == "table" and row.leaderboard or {}
  if tonumber(values[1]) ~= nil then
    return tonumber(values[1])
  end
  if tonumber(values.score) ~= nil then
    return tonumber(values.score)
  end
  if tonumber(values.points) ~= nil then
    return tonumber(values.points)
  end
  return 0
end

BMF.minigames.leaderboard = function(query)
  local data = state.minigame_data
  local normalized = normalize_minigame_lookup_query(query, "player")
  local limit = minigame_query_limit(normalized, 50, 100)
  local minigame_key_name = ""
  local lookup_error = nil
  if minigame_query_has_minigame_filter(normalized) and minigame_query_value(normalized, "player", "playerid", "uuid", "state", "controller", "username") == nil then
    local found_key, _, err = minigame_query_minigame_key(data, normalized)
    if err ~= nil then
      lookup_error = err
    else
      minigame_key_name = found_key
    end
  elseif minigame_query_value(normalized, "minigameKey", "minigamekey", "ruleset", "minigame") ~= nil then
    local found_key, _, err = minigame_query_minigame_key(data, normalized)
    if err ~= nil then
      lookup_error = err
    else
      minigame_key_name = found_key
    end
  end
  if lookup_error ~= nil then
    return result(false, "MINIGAME_NOT_FOUND", lookup_error, {
      query = normalized,
      counts = minigame_data_counts(data),
    })
  end

  local player_filter = minigame_query_has_player_filter(normalized)
  local team_filter = normalize_api_filter_value(minigame_query_value(normalized, "team", "teamKey", "teamkey") or "")
  local collected = {}
  for _, player_key_name in ipairs(minigame_sorted_keys(data.leaderboards_by_player)) do
    local leaderboard = data.leaderboards_by_player[player_key_name]
    if type(leaderboard) == "table" then
      local player = type(leaderboard.player) == "table" and leaderboard.player or data.players_by_key[player_key_name] or {}
      local team_membership = type(data.team_memberships_by_player[player_key_name]) == "table" and data.team_memberships_by_player[player_key_name] or nil
      local ok = true
      if minigame_key_name ~= "" and leaderboard.minigameKey ~= minigame_key_name then
        ok = false
      end
      if ok and player_filter and not player_matches_query(player_key_name, player, normalized) then
        ok = false
      end
      if ok and team_filter ~= "" then
        if not team_membership then
          ok = false
        else
          local team = type(team_membership.team) == "table" and team_membership.team or {}
          ok = normalize_api_filter_value(team_membership.teamKey) == team_filter
            or normalize_api_filter_value(team.key) == team_filter
            or normalize_api_filter_value(team.team or team.id or team.name) == team_filter
        end
      end
      if ok then
        local item = copy_table(leaderboard)
        item.playerKey = player_key_name
        item.player = copy_table(player)
        item.minigame = copy_table(item.minigame or data.minigames_by_key[item.minigameKey] or {})
        item.teamKey = team_membership and tostring(team_membership.teamKey or "") or ""
        item.team = team_membership and copy_table(team_membership.team or data.teams_by_key[item.teamKey] or {}) or nil
        item.values = copy_table(type(item.leaderboard) == "table" and item.leaderboard or {})
        item.oldValues = copy_table(type(item.oldLeaderboard) == "table" and item.oldLeaderboard or {})
        item.valueCount = #(item.values or {})
        item.score = minigame_leaderboard_score(item)
        collected[#collected + 1] = item
      end
    end
  end

  table.sort(collected, function(a, b)
    local a_score = tonumber(a.score) or 0
    local b_score = tonumber(b.score) or 0
    if a_score ~= b_score then
      return a_score > b_score
    end
    return tostring(a.playerKey or "") < tostring(b.playerKey or "")
  end)

  local items = {}
  for index, item in ipairs(collected) do
    if #items >= limit then
      break
    end
    item.rank = index
    items[#items + 1] = item
  end

  return result(true, "OK", "Minigame leaderboard listed", {
    leaderboards = items,
    count = #items,
    total = #collected,
    minigameKey = minigame_key_name,
    query = normalized,
    counts = minigame_data_counts(data),
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
  })
end

BMF.minigames.membership = function(query)
  local found = BMF.minigames.getPlayer(query)
  if not found.ok then
    return found
  end
  local data = found.data or {}
  if type(data.membership) ~= "table" then
    return result(false, "MINIGAME_MEMBERSHIP_NOT_FOUND", "Player has no known minigame membership", data)
  end
  found.message = "Minigame membership found"
  return found
end

BMF.minigames.recentEvents = function(filter)
  local normalized = normalize_minigame_lookup_query(filter, "event")
  local limit = minigame_query_limit(normalized, 10, 50)
  local event_filter = trim_string(minigame_query_value(normalized, "event", "name", "type") or "")
  local legacy_filter = ""
  if event_filter ~= "" then
    local normalized_event, event_error = normalize_minigame_event_name(event_filter)
    if not normalized_event then
      return result(false, "INVALID_MINIGAME_EVENT", event_error, {
        query = normalized,
      })
    end
    legacy_filter = normalized_event
  end
  local source_filter = normalize_api_filter_value(minigame_query_value(normalized, "source") or "")
  local player_filter = minigame_query_has_player_filter(normalized)
  local items = {}
  local recent = state.minigame_events.recent or {}
  for index = #recent, 1, -1 do
    if #items >= limit then
      break
    end
    local entry = recent[index]
    if type(entry) == "table" then
      local ok = true
      if legacy_filter ~= "" and entry.name ~= legacy_filter then
        ok = false
      end
      local payload = type(entry.payload) == "table" and entry.payload or {}
      if ok and source_filter ~= "" and normalize_api_filter_value(payload.source or entry.source) ~= source_filter then
        ok = false
      end
      if ok and player_filter and not player_matches_query(player_key(payload.player), payload.player or {}, normalized) then
        ok = false
      end
      if ok and not minigame_event_matches_minigame(entry, normalized) then
        ok = false
      end
      if ok then
        items[#items + 1] = copy_table(entry)
      end
    end
  end

  return result(true, "OK", "Recent minigame events listed", {
    events = items,
    count = #items,
    total = state.minigame_events.total or 0,
    query = normalized,
    limit = limit,
    event = legacy_filter,
    counts = copy_table(state.minigame_events.by_event or {}),
    last = type(state.minigame_events.last) == "table" and copy_table(state.minigame_events.last) or nil,
  })
end

BMF.minigames.data = function()
  local data = state.minigame_data
  return result(true, "OK", "Minigame data snapshot collected", {
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
    minigames = copy_table(data.minigames_by_key or {}),
    players = copy_table(data.players_by_key or {}),
    memberships = copy_table(data.memberships_by_player or {}),
    teams = copy_table(data.teams_by_key or {}),
    teamMemberships = copy_table(data.team_memberships_by_player or {}),
    leaderboards = copy_table(data.leaderboards_by_player or {}),
    rounds = copy_table(data.rounds_by_key or {}),
    counts = minigame_data_counts(data),
  })
end

BMF.minigames.applySnapshot = function(payload)
  if type(payload) ~= "table" then
    return result(false, "INVALID_MINIGAME_SNAPSHOT", "snapshot payload table is required", {
      counts = minigame_data_counts(state.minigame_data or new_minigame_data_state()),
    })
  end

  local snapshot_payload = copy_table(payload)
  local minigames = minigame_snapshot_records(snapshot_payload)
  if #minigames == 0 then
    return result(false, "INVALID_MINIGAME_SNAPSHOT", "snapshot must include at least one minigame", {
      counts = minigame_data_counts(state.minigame_data or new_minigame_data_state()),
    })
  end

  if trim_string(snapshot_payload.source or "") == "" then
    snapshot_payload.source = "bmf-snapshot-import"
  end
  state.minigame_data = state.minigame_data or new_minigame_data_state()
  local applied_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  remember_minigame_data("snapshot", snapshot_payload, applied_at)
  if write_status then
    write_status()
  end

  local data = state.minigame_data
  return result(true, "OK", "Minigame data snapshot applied", {
    appliedAt = applied_at,
    source = data.source or "",
    snapshotMinigames = #minigames,
    updatedAt = data.updated_at or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
    counts = minigame_data_counts(data),
  })
end

BMF.minigames.get = function(query)
  local data = state.minigame_data
  local key, record, matches, lookup_error, normalized = minigame_find_by_query(data, query)
  if not record then
    return result(false, "MINIGAME_NOT_FOUND", lookup_error or "Minigame not found", {
      query = normalized,
      matches = copy_table(matches or {}),
      counts = minigame_data_counts(data),
    })
  end
  return result(true, "OK", "Minigame data found", minigame_context_for_key(data, key, record, matches))
end

BMF.minigames.getPlayer = function(query)
  local data = state.minigame_data
  local key, player, lookup_error, normalized = minigame_find_player_by_query(data, query)
  if not player then
    return result(false, "MINIGAME_PLAYER_NOT_FOUND", lookup_error or "Minigame player not found", {
      query = normalized,
      counts = minigame_data_counts(data),
    })
  end
  return result(true, "OK", "Minigame player data found", minigame_player_context(data, key, player))
end

BMF.minigames.playerState = function(query)
  local data = state.minigame_data
  local key, player, lookup_error, normalized = minigame_find_player_by_query(data, query)
  if not player then
    return result(false, "MINIGAME_PLAYER_NOT_FOUND", lookup_error or "Minigame player not found", {
      query = normalized,
      inMinigame = false,
      reason = "player-not-found",
      counts = minigame_data_counts(data),
    })
  end

  local context = minigame_player_context(data, key, player)
  local membership = type(context.membership) == "table" and context.membership or nil
  local team_membership = type(context.teamMembership) == "table" and context.teamMembership or nil
  local leaderboard = type(context.leaderboard) == "table" and context.leaderboard or nil
  local current_minigame_key = membership and tostring(membership.minigameKey or "") or ""
  local current_team_key = ""
  if current_minigame_key ~= "" and team_membership and team_membership.minigameKey == current_minigame_key then
    current_team_key = tostring(team_membership.teamKey or "")
  end
  local activity_minigame_key = tostring(context.minigameKey or "")

  local current_minigame = nil
  if current_minigame_key ~= "" then
    current_minigame = copy_table(data.minigames_by_key[current_minigame_key] or membership.minigame or {})
  end

  local current_team = nil
  if current_team_key ~= "" then
    current_team = copy_table(data.teams_by_key[current_team_key] or team_membership.team or {})
  end

  return result(true, "OK", "Minigame player state resolved", {
    playerKey = key,
    player = copy_table(player or {}),
    inMinigame = membership ~= nil,
    minigameKey = current_minigame_key,
    minigame = current_minigame,
    teamKey = current_team_key,
    team = current_team,
    membership = membership,
    teamMembership = team_membership,
    leaderboard = leaderboard,
    activityMinigameKey = activity_minigame_key,
    activityMinigame = activity_minigame_key ~= "" and copy_table(data.minigames_by_key[activity_minigame_key] or context.minigame or {}) or nil,
    hasTeam = current_team_key ~= "",
    hasLeaderboard = leaderboard ~= nil,
    reason = membership and "membership" or "known-player-no-membership",
    query = normalized,
    updatedAt = data.updated_at or "",
    source = data.source or "",
    totalUpdates = data.total_updates or 0,
    lastEvent = type(data.last_event) == "table" and copy_table(data.last_event) or nil,
    counts = minigame_data_counts(data),
  })
end

BMF.minigames.clearData = function(confirm)
  local token = confirm
  if type(confirm) == "table" then
    token = confirm.confirm or confirm.token
  end
  if token ~= true and tostring(token or "") ~= "CLEAR_MINIGAME_DATA" then
    return result(false, "CONFIRMATION_REQUIRED", "Pass confirm=CLEAR_MINIGAME_DATA to clear minigame data.", {
      confirmRequired = "CLEAR_MINIGAME_DATA",
    })
  end

  local cleared_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  state.minigame_data = new_minigame_data_state()
  state.minigame_data.updated_at = cleared_at
  state.minigame_data.source = "manual-clear"
  return result(true, "OK", "Minigame data cache cleared", {
    clearedAt = cleared_at,
    source = state.minigame_data.source,
    counts = minigame_data_counts(state.minigame_data),
  })
end

BMF.minigames.dataStatus = function()
  local snapshot = BMF.minigames.data()
  local data = snapshot.data or {}
  local counts = data.counts or {}
  data.lines = {
    "total_updates=" .. tostring(data.totalUpdates or 0),
    "updated_at=" .. tostring(data.updatedAt or ""),
    "source=" .. tostring(data.source or ""),
    "minigames=" .. tostring(counts.minigames or 0),
    "players=" .. tostring(counts.players or 0),
    "memberships=" .. tostring(counts.memberships or 0),
    "teams=" .. tostring(counts.teams or 0),
    "team_memberships=" .. tostring(counts.teamMemberships or 0),
    "leaderboards=" .. tostring(counts.leaderboards or 0),
    "rounds=" .. tostring(counts.rounds or 0),
  }
  if data.lastEvent then
    data.lines[#data.lines + 1] = "last_event=" .. tostring(data.lastEvent.event or "")
    data.lines[#data.lines + 1] = "last_emitted_at=" .. tostring(data.lastEvent.emittedAt or "")
  end
  return result(true, "OK", "Minigame data status collected", data)
end

BMF.minigames.syntheticFlow = function(options)
  local opts = type(options) == "table" and options or {}
  local persist_value = string.lower(trim_string(opts.persist or opts.keep or ""))
  local cleanup_value = string.lower(trim_string(opts.cleanup or ""))
  local restore_data_after_emit = persist_value ~= "true" and persist_value ~= "1" and persist_value ~= "yes" and cleanup_value ~= "false"
  local data_before_emit = restore_data_after_emit and copy_table(state.minigame_data or new_minigame_data_state()) or nil
  local source = trim_string(opts.source or "")
  if source == "" then
    source = "bmf-minigame-synthetic-flow"
  end

  local minigame = {
    name = trim_string(opts.minigame or opts.minigamename or opts.name or "SyntheticArena"),
    index = tonumber(opts.index or opts.minigameindex) or 0,
  }
  if trim_string(opts.ruleset or opts.id or "") ~= "" then
    minigame.ruleset = trim_string(opts.ruleset or opts.id)
  end

  local player = {
    name = trim_string(opts.player or opts.playername or "MinigameFlowPlayer"),
    id = trim_string(opts.playerid or opts.uuid or "44444444-4444-4444-8444-444444444444"),
  }
  local victim = {
    name = trim_string(opts.victim or opts.victimname or "MinigameFlowVictim"),
    id = trim_string(opts.victimid or "55555555-5555-4555-8555-555555555555"),
  }
  local team = {
    name = trim_string(opts.team or "Red"),
  }

  local mkey = minigame_key(minigame)
  local pkey = player_key(player)
  local tkey = team_key(team, minigame)
  local checkpoints = {}
  local emitted_events = {}
  local handler_counts = {}
  local handler_metadata = {}
  local handler_ids = {}
  local listener_counts_before = {}
  local listener_counts_after = {}
  local handler_calls = 0
  local removed_all = true
  local failed_code = ""

  local sequence = {
    { name = "created", payload = { source = source, minigame = minigame } },
    { name = "joinminigame", payload = { source = source, player = player, minigame = minigame } },
    { name = "teamchange", payload = { source = source, player = player, minigame = minigame, team = team } },
    { name = "roundchange", payload = { source = source, minigame = minigame, round = 1 } },
    { name = "leaderboardchange", payload = { source = source, player = player, minigame = minigame, leaderboard = { 5, 2, 1 }, oldLeaderboard = { 0, 0, 0 } } },
    { name = "kill", payload = { source = source, player = player, victim = victim, minigame = minigame, leaderboard = { 6, 2, 1 }, oldLeaderboard = { 5, 2, 1 } } },
    { name = "leaveminigame", payload = { source = source, player = player, minigame = minigame, team = team, reason = "synthetic-flow" } },
    { name = "deleted", payload = { source = source, minigame = minigame } },
  }

  for _, item in ipairs(sequence) do
    listener_counts_before[item.name] = BMF.minigames.listenerCount(item.name)
    local handler_id, subscribe_error = BMF.minigames.on(item.name, function(payload, legacy_name)
      handler_calls = handler_calls + 1
      handler_counts[legacy_name] = (tonumber(handler_counts[legacy_name]) or 0) + 1
      handler_metadata[legacy_name] = copy_table((payload and payload._bmf) or {})
    end)
    if not handler_id then
      for _, existing_id in ipairs(handler_ids) do
        BMF.minigames.off(existing_id)
      end
      if restore_data_after_emit and data_before_emit then
        state.minigame_data = data_before_emit
        if write_status then
          write_status()
        end
      end
      return result(false, "SUBSCRIBE_FAILED", subscribe_error or "Could not subscribe to minigame flow event", {
        event = item.name,
        error = subscribe_error,
        lines = {
          "code=SUBSCRIBE_FAILED",
          "event=" .. tostring(item.name),
          "error=" .. tostring(subscribe_error or ""),
        },
      })
    end
    handler_ids[#handler_ids + 1] = handler_id
  end

  local function capture_checkpoint(name)
    local data = state.minigame_data or new_minigame_data_state()
    checkpoints[name] = {
      minigame = type(data.minigames_by_key[mkey]) == "table",
      player = type(data.players_by_key[pkey]) == "table",
      membership = type(data.memberships_by_player[pkey]) == "table",
      team = type(data.teams_by_key[tkey]) == "table",
      teamMembership = type(data.team_memberships_by_player[pkey]) == "table",
      leaderboard = type(data.leaderboards_by_player[pkey]) == "table",
      round = type(data.rounds_by_key[mkey]) == "table",
      counts = minigame_data_counts(data),
    }
  end

  for _, item in ipairs(sequence) do
    local emitted = BMF.minigames.emitEvent(item.name, item.payload)
    if not emitted.ok and failed_code == "" then
      failed_code = tostring(emitted.code or "FLOW_EMIT_FAILED")
    end
    local data = emitted.data or {}
    local metadata = data.payload and data.payload._bmf or {}
    emitted_events[#emitted_events + 1] = {
      event = data.event or ("minigames." .. item.name),
      legacyEvent = data.legacyEvent or item.name,
      code = emitted.code or "",
      ok = emitted.ok == true,
      handlers = data.handlers or 0,
      eventId = metadata.eventId or metadata.event_id or "",
    }
    capture_checkpoint("after_" .. item.name)
  end

  for index, handler_id in ipairs(handler_ids) do
    local item = sequence[index]
    local removed = BMF.minigames.off(handler_id)
    if removed ~= true then
      removed_all = false
    end
    if item then
      listener_counts_after[item.name] = BMF.minigames.listenerCount(item.name)
    end
  end

  local flow_counts = minigame_data_counts(state.minigame_data or new_minigame_data_state())
  local ok = failed_code == ""
  local code = ok and "OK" or failed_code
  local lines = {
    "code=" .. tostring(code),
    "source=" .. tostring(source),
    "emitted=" .. tostring(#emitted_events),
    "handler_calls=" .. tostring(handler_calls),
    "listeners_removed=" .. tostring(removed_all == true),
    "data_restored=" .. tostring(restore_data_after_emit == true),
    "data_persisted=" .. tostring(restore_data_after_emit ~= true),
    "minigame_key=" .. tostring(mkey),
    "player_key=" .. tostring(pkey),
    "team_key=" .. tostring(tkey),
    "after_created_minigame=" .. tostring(checkpoints.after_created and checkpoints.after_created.minigame == true),
    "after_join_membership=" .. tostring(checkpoints.after_joinminigame and checkpoints.after_joinminigame.membership == true),
    "after_team_membership=" .. tostring(checkpoints.after_teamchange and checkpoints.after_teamchange.teamMembership == true),
    "after_round_found=" .. tostring(checkpoints.after_roundchange and checkpoints.after_roundchange.round == true),
    "after_leaderboard_found=" .. tostring(checkpoints.after_leaderboardchange and checkpoints.after_leaderboardchange.leaderboard == true),
    "after_kill_leaderboard=" .. tostring(checkpoints.after_kill and checkpoints.after_kill.leaderboard == true),
    "after_leave_membership=" .. tostring(checkpoints.after_leaveminigame and checkpoints.after_leaveminigame.membership == true),
    "after_delete_minigame=" .. tostring(checkpoints.after_deleted and checkpoints.after_deleted.minigame == true),
    "after_delete_team=" .. tostring(checkpoints.after_deleted and checkpoints.after_deleted.team == true),
    "after_delete_round=" .. tostring(checkpoints.after_deleted and checkpoints.after_deleted.round == true),
    "after_delete_leaderboard=" .. tostring(checkpoints.after_deleted and checkpoints.after_deleted.leaderboard == true),
    "flow_minigames=" .. tostring(flow_counts.minigames or 0),
    "flow_players=" .. tostring(flow_counts.players or 0),
    "flow_memberships=" .. tostring(flow_counts.memberships or 0),
    "flow_teams=" .. tostring(flow_counts.teams or 0),
    "flow_team_memberships=" .. tostring(flow_counts.teamMemberships or 0),
    "flow_leaderboards=" .. tostring(flow_counts.leaderboards or 0),
    "flow_rounds=" .. tostring(flow_counts.rounds or 0),
  }

  for index, entry in ipairs(emitted_events) do
    lines[#lines + 1] =
      "event_" .. tostring(index) ..
      "=" .. tostring(entry.event or "") ..
      "|legacy=" .. tostring(entry.legacyEvent or "") ..
      "|code=" .. tostring(entry.code or "") ..
      "|handlers=" .. tostring(entry.handlers or 0)
  end

  local response_data = {
    source = source,
    minigame = copy_table(minigame),
    player = copy_table(player),
    victim = copy_table(victim),
    team = copy_table(team),
    minigameKey = mkey,
    playerKey = pkey,
    teamKey = tkey,
    emitted = emitted_events,
    handlerCalls = handler_calls,
    handlerCounts = handler_counts,
    handlerMetadata = handler_metadata,
    listenerCountsBefore = listener_counts_before,
    listenerCountsAfter = listener_counts_after,
    listenersRemoved = removed_all == true,
    checkpoints = checkpoints,
    flowCounts = flow_counts,
    dataRestored = restore_data_after_emit == true,
    dataPersisted = restore_data_after_emit ~= true,
    lines = lines,
  }

  if restore_data_after_emit and data_before_emit then
    state.minigame_data = data_before_emit
    if write_status then
      write_status()
    end
  end

  return result(ok, code, ok and "Synthetic minigame flow emitted" or "Synthetic minigame flow had errors", response_data)
end

BMF.world = {}
BMF.world.loadAdditive = function(options)
  if type(options) == "string" then
    options = { name = options }
  end
  if type(options) ~= "table" then
    return result(false, "INVALID_OPTIONS", "options table is required")
  end

  local name, name_error = normalize_world_name(options.name or options.bundle or options.world)
  if not name then
    return result(false, "INVALID_WORLD_NAME", name_error)
  end

  local position = options.position
  if type(position) ~= "table" then
    position = {}
  end
  local x = finite_number(options.x or position.x or position.X, 0)
  local y = finite_number(options.y or position.y or position.Y, 0)
  local z = finite_number(options.z or position.z or position.Z, 0)
  local yaw = finite_number(options.yaw or options.orientation or options.rotation, 0)

  local command = table.concat({
    "BR.World.LoadAdditive",
    quote_console_token(name),
    format_number(x),
    format_number(y),
    format_number(z),
    format_number(yaw),
  }, " ")

  local limited = rate_limit_check("world.loadAdditive")
  if not limited.ok then
    return limited
  end

  local response = exec_console_manager(command)
  response.data.command = command
  response.data.world = name
  response.data.position = { x = x, y = y, z = z, yaw = yaw }
  audit_record("world.loadAdditive", {
    world = name,
    command = command,
    position = response.data.position,
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  if response.ok then
    BMF.events.emit("worldLoaded", {
      mode = "additive",
      world = name,
      command = command,
      position = response.data.position,
    })
  end
  return response
end

BMF.world.saveAs = function(name)
  local world_name, name_error = normalize_world_name(name)
  if not world_name then
    return result(false, "INVALID_WORLD_NAME", name_error)
  end

  local command = "BR.World.SaveAs " .. quote_console_string(world_name)
  local limited = rate_limit_check("world.saveAs")
  if not limited.ok then
    return limited
  end
  local response = exec_console_manager(command)
  response.data.command = command
  response.data.world = world_name
  audit_record("world.saveAs", {
    world = world_name,
    command = command,
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  if response.ok then
    BMF.events.emit("worldSaved", {
      world = world_name,
      command = command,
    })
  end
  return response
end

BMF.prefabs = {}

local function normalize_prefab_source(value)
  local source = trim_string(value)
  if source == "" then
    return nil, "prefab source is required"
  end
  if source:match("[%c]") or source:match("[/\\]") or source:match("%.%.") then
    return nil, "prefab source must not contain control characters or path separators"
  end
  local lower = source:lower()
  if lower:match("%.") and not lower:match("%.brz$") then
    return nil, "prefab source must be a .brz file"
  end
  return source
end

local function prefab_position_from_options(options)
  local position = options.position
  if type(position) ~= "table" then
    position = {}
  end
  return {
    x = finite_number(options.x or position.x or position.X, 0),
    y = finite_number(options.y or position.y or position.Y, 0),
    z = finite_number(options.z or position.z or position.Z, 0),
    yaw = finite_number(options.yaw or options.orientation or options.rotation, 0),
  }
end

local function normalize_staged_prefab_world(options)
  return normalize_world_name(options.stagedWorld or options.stage or options.name or options.bundle or options.world)
end

local function has_staged_prefab_world_option(options)
  return options.stagedWorld ~= nil or options.stage ~= nil or options.name ~= nil or options.bundle ~= nil or options.world ~= nil
end

BMF.prefabs.planLoadBrz = function(options)
  if type(options) ~= "table" then
    return result(false, "INVALID_OPTIONS", "options table is required")
  end

  local source, source_error = normalize_prefab_source(options.source or options.brz or options.prefab)
  if not source then
    return result(false, "INVALID_PREFAB_SOURCE", source_error)
  end

  local staged_world = nil
  local staged_world_error = nil
  if has_staged_prefab_world_option(options) then
    staged_world, staged_world_error = normalize_staged_prefab_world(options)
    if not staged_world then
      return result(false, "INVALID_WORLD_NAME", staged_world_error)
    end
  end

  local position = prefab_position_from_options(options)
  local load_options = nil
  if staged_world then
    load_options = {
      name = staged_world,
      position = { x = position.x, y = position.y, z = position.z },
      yaw = position.yaw,
    }
  end

  return result(true, "OK", "BRZ prefab load planned", {
    source = source,
    stagedWorld = staged_world,
    requiresStaging = staged_world == nil,
    position = position,
    loadOptions = load_options,
  })
end

BMF.prefabs.loadBrdb = function(options)
  if type(options) == "string" then
    options = { name = options }
  end
  if type(options) ~= "table" then
    return result(false, "INVALID_OPTIONS", "options table is required")
  end

  local staged_world, staged_world_error = normalize_staged_prefab_world(options)
  if not staged_world then
    return result(false, "INVALID_WORLD_NAME", staged_world_error)
  end

  local position = prefab_position_from_options(options)
  local response = BMF.world.loadAdditive({
    name = staged_world,
    position = { x = position.x, y = position.y, z = position.z },
    yaw = position.yaw,
  })
  response.data.api = "BMF.prefabs.loadBrdb"
  response.data.prefab = {
    stagedWorld = staged_world,
  }
  return response
end

BMF.prefabs.loadBrz = function(options)
  local planned = BMF.prefabs.planLoadBrz(options)
  if not planned.ok then
    return planned
  end

  if planned.data.requiresStaging then
    return result(false, "PREFAB_STAGING_REQUIRED", "BRZ prefab must be staged as a BRDB world before runtime load", planned.data)
  end

  local response = BMF.world.loadAdditive(planned.data.loadOptions)
  response.data.api = "BMF.prefabs.loadBrz"
  response.data.prefab = {
    source = planned.data.source,
    stagedWorld = planned.data.stagedWorld,
  }
  return response
end

BMF.vehicles = {}

local function vehicle_spawn_position(options, fallback)
  options = options or {}
  fallback = fallback or {}
  local position = options.position
  if type(position) ~= "table" then
    position = {}
  end

  return {
    x = finite_number(options.x or position.x or position.X, fallback.x or 0),
    y = finite_number(options.y or position.y or position.Y, fallback.y or 0),
    z = finite_number(options.z or position.z or position.Z, fallback.z or 0),
    yaw = finite_number(options.yaw or options.orientation or options.rotation, fallback.yaw or 0),
  }
end

local function vehicle_spawn_load(name, position, index)
  local load_options = {
    name = name,
    position = { x = position.x, y = position.y, z = position.z },
    yaw = position.yaw,
  }
  local command = table.concat({
    "BR.World.LoadAdditive",
    quote_console_token(name),
    format_number(position.x),
    format_number(position.y),
    format_number(position.z),
    format_number(position.yaw),
  }, " ")

  return {
    index = index,
    worldName = name,
    position = position,
    command = command,
    loadOptions = load_options,
  }
end

BMF.vehicles.planSpawnSet = function(options)
  if type(options) ~= "table" then
    return result(false, "INVALID_OPTIONS", "options table is required")
  end

  local loads = {}
  local errors = {}
  local copies = options.copies or options.stagedWorlds or options.worlds

  if type(copies) == "table" then
    for index, copy in ipairs(copies) do
      local copy_options = copy
      if type(copy_options) == "string" then
        copy_options = { name = copy_options }
      end
      if type(copy_options) ~= "table" then
        errors[#errors + 1] = "copy " .. tostring(index) .. " must be a table or world name"
      else
        local world_name, name_error = normalize_world_name(copy_options.worldName or copy_options.stagedWorld or copy_options.name or copy_options.world or copy_options.bundle)
        if not world_name then
          errors[#errors + 1] = "copy " .. tostring(index) .. ": " .. name_error
        else
          local position = vehicle_spawn_position(copy_options, vehicle_spawn_position(options, {}))
          loads[#loads + 1] = vehicle_spawn_load(world_name, position, index)
        end
      end
    end
  else
    local count, count_error = normalize_integer(options.count or options.vehicleCount, "vehicle count")
    if count == nil then
      return result(false, "INVALID_VEHICLE_COUNT", count_error)
    end
    if count < 1 then
      return result(false, "INVALID_VEHICLE_COUNT", "vehicle count must be at least 1")
    end

    local prefix, prefix_error = normalize_world_name(options.worldNamePrefix or options.prefix)
    if not prefix then
      return result(false, "INVALID_WORLD_NAME", prefix_error)
    end

    local start = options.start or options.position or {}
    if type(start) ~= "table" then
      start = {}
    end
    local step = options.step or {}
    if type(step) ~= "table" then
      step = {}
    end

    local base = {
      x = finite_number(options.x or start.x or start.X, 0),
      y = finite_number(options.y or start.y or start.Y, 0),
      z = finite_number(options.z or start.z or start.Z, 0),
      yaw = finite_number(options.yaw or options.orientation or options.rotation, 0),
    }
    local delta = {
      x = finite_number(options.stepX or step.x or step.X, 0),
      y = finite_number(options.stepY or step.y or step.Y, 0),
      z = finite_number(options.stepZ or step.z or step.Z, 0),
      yaw = finite_number(options.stepYaw or step.yaw or step.Yaw, 0),
    }

    for index = 1, count do
      local world_name = string.format("%s_%02d", prefix, index)
      local position = {
        x = base.x + ((index - 1) * delta.x),
        y = base.y + ((index - 1) * delta.y),
        z = base.z + ((index - 1) * delta.z),
        yaw = base.yaw + ((index - 1) * delta.yaw),
      }
      loads[#loads + 1] = vehicle_spawn_load(world_name, position, index)
    end
  end

  if #errors > 0 then
    return result(false, "INVALID_VEHICLE_SPAWN_SET", table.concat(errors, "; "), {
      errors = errors,
    })
  end
  if #loads == 0 then
    return result(false, "INVALID_VEHICLE_SPAWN_SET", "at least one staged vehicle world is required")
  end

  return result(true, "OK", "Vehicle spawn set planned", {
    vehicleCount = #loads,
    loads = loads,
    requiresStaging = false,
  })
end

BMF.vehicles.spawnSet = function(options)
  local planned = BMF.vehicles.planSpawnSet(options)
  if not planned.ok then
    return planned
  end

  local responses = {}
  for _, spawn in ipairs(planned.data.loads) do
    local response = BMF.world.loadAdditive(spawn.loadOptions)
    response.data.api = "BMF.vehicles.spawnSet"
    response.data.vehicleIndex = spawn.index
    response.data.stagedWorld = spawn.worldName
    responses[#responses + 1] = response
    if not response.ok then
      return result(false, "VEHICLE_SPAWN_FAILED", "Vehicle spawn failed at copy " .. tostring(spawn.index), {
        planned = planned.data,
        responses = responses,
        failedIndex = spawn.index,
      })
    end
  end

  return result(true, "OK", "Vehicle spawn set loaded", {
    vehicleCount = #responses,
    planned = planned.data,
    responses = responses,
  })
end

BMF.chat = {}

local LIVE_CHAT_CONTROLLER_CLASSES = { "BP_PlayerController_C", "BRPlayerController", "PlayerController" }

local function live_chat_is_valid_object(object)
  if object == nil then
    return false
  end
  if type(object.IsValid) ~= "function" then
    return false
  end
  local ok, is_valid = pcall(function()
    return object:IsValid()
  end)
  return ok and is_valid == true
end

local function live_chat_object_key(object, fallback)
  if live_chat_is_valid_object(object) and type(object.GetAddress) == "function" then
    local ok, address = pcall(function()
      return object:GetAddress()
    end)
    if ok and address ~= nil then
      return tostring(address)
    end
  end
  return tostring(fallback or object or "")
end

local function live_chat_object_label(object, fallback)
  local address = live_chat_object_key(object, "")
  if address ~= "" then
    return tostring(fallback or "object") .. "@" .. address
  end
  return tostring(fallback or "object")
end

local function live_chat_object_full_name(object)
  if live_chat_is_valid_object(object) and type(object.GetFullName) == "function" then
    local ok, full_name = pcall(function()
      return object:GetFullName()
    end)
    if ok and full_name ~= nil then
      return tostring(full_name)
    end
  end
  return ""
end

local function live_chat_find_controller_by_name(object_name)
  local name = trim_string(tostring(object_name or ""))
  if name == "" then
    return nil
  end

  if type(FindObject) == "function" then
    local ok, object = pcall(FindObject, nil, name, nil, nil)
    if ok and live_chat_is_valid_object(object) then
      return object
    end

    for _, class_name in ipairs(LIVE_CHAT_CONTROLLER_CLASSES) do
      ok, object = pcall(FindObject, class_name, name, nil, nil)
      if ok and live_chat_is_valid_object(object) then
        return object
      end
    end
  end

  if type(StaticFindObject) == "function" then
    local ok, object = pcall(StaticFindObject, name)
    if ok and live_chat_is_valid_object(object) then
      return object
    end
  end

  return nil
end

local function live_chat_cached_players()
  local raw = read_file(PLAYER_CACHE_PATH)
  if not raw or trim_string(raw) == "" then
    return {}
  end

  local cache = json_decode(raw)
  if type(cache) ~= "table" or type(cache.players) ~= "table" then
    return {}
  end
  return cache.players
end

local function live_chat_collect_targets()
  local targets = {}
  local seen = {}

  local function add_target(controller, source, metadata)
    if not live_chat_is_valid_object(controller) then
      return
    end
    local key = live_chat_object_key(controller, tostring(controller))
    if seen[key] then
      return
    end
    seen[key] = true

    metadata = type(metadata) == "table" and metadata or {}
    local full_name = live_chat_object_full_name(controller)
    local label = full_name ~= "" and full_name or live_chat_object_label(controller, source or "player_controller")

    targets[#targets + 1] = {
      controller = controller,
      name = tostring(metadata.name or metadata.playerName or metadata.username or ""),
      userName = tostring(metadata.userName or metadata.username or metadata.playerName or ""),
      displayName = tostring(metadata.displayName or metadata.name or metadata.username or ""),
      playerId = tostring(metadata.uuid or metadata.id or metadata.playerId or ""),
      controllerPath = tostring(metadata.controllerPath or ""),
      playerStatePath = tostring(metadata.playerStatePath or ""),
      label = label,
      source = tostring(source or ""),
    }
  end

  for _, player in ipairs(live_chat_cached_players()) do
    local controller_path = tostring(player.controllerPath or "")
    local controller = live_chat_find_controller_by_name(controller_path)
    if controller ~= nil then
      add_target(controller, "player_cache.controllerPath", player)
    end
  end

  if type(FindFirstOf) == "function" then
    for _, class_name in ipairs(LIVE_CHAT_CONTROLLER_CLASSES) do
      local ok, controller = pcall(FindFirstOf, class_name)
      if ok then
        add_target(controller, "FindFirstOf(" .. class_name .. ")")
      end
    end
  end

  return targets
end

local function live_chat_target_summary(target)
  return {
    name = tostring(target.name or ""),
    userName = tostring(target.userName or ""),
    displayName = tostring(target.displayName or ""),
    playerId = tostring(target.playerId or ""),
    controllerPath = tostring(target.controllerPath or ""),
    controllerName = live_chat_object_label(target.controller, ""),
    controllerFullName = live_chat_object_full_name(target.controller),
    playerStatePath = tostring(target.playerStatePath or ""),
    label = tostring(target.label or ""),
    source = tostring(target.source or ""),
  }
end

local function live_chat_target_matches(target, query)
  local normalized = trim_string(tostring(query or "")):lower()
  if normalized == "" then
    return false
  end
  for _, value in ipairs({
    target.name,
    target.userName,
    target.displayName,
    target.playerId,
    target.controllerPath,
    target.playerStatePath,
    target.label,
  }) do
    local text = trim_string(tostring(value or "")):lower()
    if text ~= "" and (text == normalized or text:find(normalized, 1, true) ~= nil) then
      return true
    end
  end
  return false
end

local function live_chat_query_text(player)
  if type(player) == "table" then
    return first_string(
      player.uuid,
      player.id,
      player.userId,
      player.userID,
      player.playerId,
      player.playerID,
      player.username,
      player.userName,
      player.displayName,
      player.playerName,
      player.originalName,
      player.name,
      player.query
    ) or ""
  end
  return tostring(player or "")
end

local function live_chat_resolve_target(player)
  local query = live_chat_query_text(player)
  local targets = live_chat_collect_targets()
  if trim_string(query) ~= "" and #targets == 1 then
    return targets[1], targets
  end
  for _, target in ipairs(targets) do
    if live_chat_target_matches(target, query) then
      return target, targets
    end
  end
  return nil, targets
end

local function live_chat_send_to_controller(controller, message)
  if type(OmeggaCallFunctionByNameWithArguments) ~= "function" then
    return false, "OmeggaCallFunctionByNameWithArguments is unavailable"
  end
  if not live_chat_is_valid_object(controller) then
    return false, "target controller is unavailable"
  end

  local command = "ClientPushChatMessage " .. quote_console_string(message)
  local ok, success, output = pcall(OmeggaCallFunctionByNameWithArguments, controller, command, controller)
  if ok and success ~= false then
    return true, tostring(output or ""), command
  end
  if ok then
    return false, tostring(output or "native call returned false"), command
  end
  return false, tostring(success), command
end

local function live_chat_send_to_targets(targets, message)
  local delivered = {}
  local failed = {}
  local command = ""
  for _, target in ipairs(targets or {}) do
    local ok, detail, used_command = live_chat_send_to_controller(target.controller, message)
    command = used_command or command
    if ok then
      delivered[#delivered + 1] = live_chat_target_summary(target)
    else
      local failure = live_chat_target_summary(target)
      failure.error = detail
      failed[#failed + 1] = failure
    end
  end
  return delivered, failed, command
end

BMF.chat.broadcast = function(message)
  if tostring(message or "") == "" then
    return result(false, "INVALID_OPTIONS", "message is required")
  end
  local limited = rate_limit_check("chat.broadcast")
  if not limited.ok then
    return limited
  end

  local live_targets = live_chat_collect_targets()
  if #live_targets > 0 and type(OmeggaCallFunctionByNameWithArguments) == "function" then
    local delivered, failed, command = live_chat_send_to_targets(live_targets, message)
    local response = result(#delivered > 0, #delivered > 0 and "OK" or "PLAYER_DELIVERY_UNAVAILABLE", #delivered > 0 and "Message delivered to live player controllers" or "No live player controller accepted the message", {
      message = tostring(message or ""),
      delivered = #delivered > 0,
      deliveredCount = #delivered,
      attemptedCount = #live_targets,
      failedCount = #failed,
      targets = delivered,
      failures = failed,
      command = command,
      executor = "player_controller.client_push_chat_message",
      deliveryMode = "player-controller-client-push-chat-message",
      validation = "L3 Live Player UI confirmed",
    })
    audit_record("chat.broadcast", {
      command = command,
      message = tostring(message or ""),
      deliveredCount = #delivered,
      attemptedCount = #live_targets,
      deliveryMode = response.data.deliveryMode,
    }, {
      source = "framework",
      severity = response.ok and "info" or "warn",
      ok = response.ok,
      code = response.code,
    })
    return response
  end

  local command = "Chat.Broadcast " .. quote_console_string(message)
  local response = exec_console(command)
  if not response.ok and response.code == "CONSOLE_EXEC_UNAVAILABLE" then
    response = exec_console_manager(command)
  end
  response.data.command = command
  response.data.message = tostring(message or "")
  response.data.delivered = false
  response.data.deliveredCount = 0
  response.data.attemptedCount = #live_targets
  response.data.deliveryMode = "legacy-console-fallback"
  response.data.validation = "L2 command acceptance only; visible delivery not implied"
  audit_record("chat.broadcast", {
    command = command,
    message = tostring(message or ""),
    deliveredCount = 0,
    attemptedCount = #live_targets,
    deliveryMode = response.data.deliveryMode,
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  return response
end

BMF.players = {}

local function external_player_record(record)
  if type(record) ~= "table" then
    return record
  end

  if record[1] ~= nil or record[2] ~= nil or record[3] ~= nil then
    return {
      username = tostring(record[1] or ""),
      playerName = tostring(record[1] or ""),
      originalName = tostring(record[1] or ""),
      displayName = tostring(record[2] or record[1] or ""),
      id = tostring(record[3] or ""),
      uuid = tostring(record[3] or ""),
      controllerPath = tostring(record[4] or ""),
      playerStatePath = tostring(record[5] or ""),
      controllerAvailable = trim_string(record[4] or "") ~= "",
    }
  end

  return record
end

local function load_player_cache()
  local raw = read_file(PLAYER_CACHE_PATH)
  if raw == nil or trim_string(raw) == "" then
    state.player_cache = nil
    state.player_cache_error = ""
    return nil, ""
  end

  local decoded, err = json_decode(raw)
  if err ~= nil then
    state.player_cache = nil
    state.player_cache_error = tostring(err)
    return nil, tostring(err)
  end

  state.player_cache = decoded
  state.player_cache_error = ""
  return decoded, ""
end

local function write_player_cache(cache)
  local ok = write_file(PLAYER_CACHE_PATH, json_encode(cache or {}) .. "\n")
  if ok then
    state.player_cache = cache
    state.player_cache_error = ""
  end
  return ok
end

local function configured_saved_dir()
  local saved_dir = trim_string(state.config.brickadiaSavedDir or "")
  if saved_dir == "" then
    return ""
  end
  return saved_dir:gsub("\\", "/"):gsub("/+$", "")
end

local function load_player_name_cache(saved_dir)
  local path = join_path(saved_dir, "Server/PlayerNameCache.json")
  local raw = read_file(path)
  if not raw or trim_string(raw) == "" then
    return {}, path, "missing"
  end

  local decoded, err = json_decode(raw)
  if err ~= nil or type(decoded) ~= "table" or type(decoded.savedPlayerNames) ~= "table" then
    return {}, path, tostring(err or "invalid name cache")
  end
  return decoded.savedPlayerNames, path, ""
end

local function player_name_cache_lookup(name_cache, uuid)
  if type(name_cache) ~= "table" then
    return ""
  end
  return tostring(name_cache[tostring(uuid or "")] or "")
end

local function record_from_pending_login(pending, name_cache)
  if type(pending) ~= "table" or not is_uuid(pending.uuid) then
    return nil
  end
  local original_name = player_name_cache_lookup(name_cache, pending.uuid)
  local username = first_string(pending.username, original_name, pending.displayName) or ""
  local display_name = first_string(pending.displayName, username, original_name) or ""
  return {
    id = pending.uuid,
    uuid = pending.uuid,
    username = username,
    playerName = username,
    displayName = display_name,
    originalName = first_string(original_name, username) or "",
    controllerAvailable = false,
    source = "brickadia-log",
  }
end

local function remove_active_player_by_name(active, order, player_name)
  local lowered = trim_string(player_name):lower()
  if lowered == "" then
    return
  end
  for uuid, player in pairs(active) do
    for _, value in ipairs({ player.username, player.playerName, player.displayName, player.originalName }) do
      if trim_string(value):lower() == lowered then
        active[uuid] = nil
        for index = #order, 1, -1 do
          if order[index] == uuid then
            table.remove(order, index)
          end
        end
        return
      end
    end
  end
end

local function parse_brickadia_log_players(saved_dir)
  local path = join_path(saved_dir, "Logs/Brickadia.log")
  local raw = read_file(path)
  if not raw or trim_string(raw) == "" then
    return {}, {
      adapter = "brickadia-log",
      path = path,
      error = "missing",
    }
  end

  local name_cache = load_player_name_cache(saved_dir)
  local active = {}
  local order = {}
  local pending = nil

  local function upsert_player(player)
    if not player or not is_uuid(player.uuid) then
      return
    end
    if active[player.uuid] == nil then
      order[#order + 1] = player.uuid
    end
    active[player.uuid] = player
  end

  for line in raw:gmatch("[^\r\n]+") do
    if line:find("LogServerList:%s+Auth payload valid%. Result:") then
      pending = {}
    elseif pending ~= nil then
      local username = line:match("LogServerList:%s+UserName:%s*(.-)%s*$")
      local display_name = line:match("LogServerList:%s+DisplayName:%s*(.-)%s*$")
      local user_id = line:match("LogServerList:%s+UserId:%s*([0-9a-fA-F%-]+)")
      if username then
        pending.username = username
      elseif display_name then
        pending.displayName = display_name
      elseif user_id then
        pending.uuid = user_id:lower()
      end
    end

    local joined = line:match("LogChat:%s*(.-)%s+joined the game%.")
    if joined then
      local player = record_from_pending_login(pending, name_cache)
      if player ~= nil then
        upsert_player(player)
      end
      pending = nil
    end

    local left = line:match("LogChat:%s*(.-)%s+left the game%.")
    if left then
      remove_active_player_by_name(active, order, left)
    end
  end

  local players = {}
  for _, uuid in ipairs(order) do
    if active[uuid] ~= nil then
      players[#players + 1] = active[uuid]
    end
  end

  return players, {
    adapter = "brickadia-log",
    path = path,
    error = "",
  }
end

local function native_player_records()
  local saved_dir = configured_saved_dir()
  if saved_dir == "" then
    return {}, {
      adapter = "none",
      source = "native-disabled",
      error = "brickadiaSavedDir is not configured",
    }
  end

  local players, detail = parse_brickadia_log_players(saved_dir)
  detail = type(detail) == "table" and detail or {}
  detail.source = "brickadia-log"
  detail.savedDir = saved_dir
  return players, detail
end

local function live_player_controller_count()
  local targets = live_chat_collect_targets()
  return #targets, targets
end

local function player_cache_records(cache)
  if type(cache) ~= "table" then
    return {}
  end
  if type(cache.players) == "table" then
    return cache.players
  end
  return cache
end

BMF.players.list = function(options)
  local opts = type(options) == "table" and options or {}
  local native_records, native_detail = native_player_records()
  local cache, cache_err = load_player_cache()
  local raw_records = #native_records > 0 and native_records or player_cache_records(cache)
  local adapter = "headless-empty"
  local source = ""
  local updated_at = ""
  local cache_path = PLAYER_CACHE_PATH
  local cache_error = cache_err
  if #native_records > 0 then
    adapter = tostring(native_detail.adapter or "brickadia-log")
    source = tostring(native_detail.source or "brickadia-log")
    cache_path = tostring(native_detail.path or "")
    cache_error = tostring(native_detail.error or "")
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  elseif type(cache) == "table" and type(cache.players) == "table" then
    adapter = tostring(cache.adapter or "external-cache")
    source = tostring(cache.source or "")
    updated_at = tostring(cache.updatedAt or "")
  elseif type(raw_records) == "table" and #raw_records > 0 then
    adapter = "external-cache"
  end

  local normalized = BMF.players.normalizeList(raw_records)
  local players = {}
  local invalid = {}
  if normalized.ok and normalized.data then
    players = normalized.data.players or {}
    invalid = normalized.data.invalid or {}
  end
  if #players == 0 then
    adapter = "headless-empty"
  end

  local include_live_controllers =
    opts.liveControllers == true or
    opts.includeLiveControllers == true or
    option_boolean(opts, "livecontrollers", false) or
    option_boolean(opts, "includelivecontrollers", false) or
    os.getenv("BMF_PLAYERS_LIST_LIVE_CONTROLLERS") == "1"
  local live_count = 0
  local live_targets = {}
  local live_controllers = {}
  if include_live_controllers then
    live_count, live_targets = live_player_controller_count()
    for _, target in ipairs(live_targets or {}) do
      live_controllers[#live_controllers + 1] = live_chat_target_summary(target)
    end
  end
  return result(true, "OK", #players > 0 and "Known player records listed" or "No cached player identity records are available", {
    players = players,
    invalid = invalid,
    playerCount = #players,
    knownPlayerCount = #players,
    invalidCount = #invalid,
    liveControllerCount = live_count,
    liveControllers = live_controllers,
    liveControllersIncluded = include_live_controllers,
    adapter = adapter,
    source = source,
    updatedAt = updated_at,
    cachePath = cache_path,
    cacheError = cache_error,
    native = native_detail,
  })
end

function player_position_axis_from_value(value, names, index)
  if type(value) == "number" then
    return finite_number(value, nil)
  end
  if type(value) == "table" then
    local direct = finite_number(value[index], nil)
    if direct ~= nil then
      return direct
    end
    for _, name in ipairs(names or {}) do
      local number = finite_number(value[name], nil)
      if number ~= nil then
        return number
      end
    end
    return nil
  end
  if type(value) ~= "userdata" then
    return nil
  end

  for _, name in ipairs(names or {}) do
    local raw = minigame_try_property(value, name)
    local number = finite_number(raw, nil)
    if number ~= nil then
      return number
    end
  end
  return nil
end

function player_position_from_text(value)
  local text = minigame_value_to_string(value)
  if trim_string(text) == "" then
    text = tostring(value or "")
  end
  local x = text:match("[Xx]%s*=%s*([%-%+]?%d+%.?%d*)")
  local y = text:match("[Yy]%s*=%s*([%-%+]?%d+%.?%d*)")
  local z = text:match("[Zz]%s*=%s*([%-%+]?%d+%.?%d*)")
  if x and y and z then
    return {
      x = finite_number(x, 0),
      y = finite_number(y, 0),
      z = finite_number(z, 0),
    }
  end

  local a, b, c = text:match("^%s*%(%s*([%-%+]?%d+%.?%d*)%s*,%s*([%-%+]?%d+%.?%d*)%s*,%s*([%-%+]?%d+%.?%d*)%s*%)%s*$")
  if not a then
    a, b, c = text:match("^%s*([%-%+]?%d+%.?%d*)%s*,%s*([%-%+]?%d+%.?%d*)%s*,%s*([%-%+]?%d+%.?%d*)%s*$")
  end
  if a and b and c then
    return {
      x = finite_number(a, 0),
      y = finite_number(b, 0),
      z = finite_number(c, 0),
    }
  end
  return nil
end

function player_position_from_vector(value)
  if value == nil then
    return nil
  end

  local x = player_position_axis_from_value(value, { "X", "x" }, 1)
  local y = player_position_axis_from_value(value, { "Y", "y" }, 2)
  local z = player_position_axis_from_value(value, { "Z", "z" }, 3)
  if x ~= nil and y ~= nil and z ~= nil then
    return { x = x, y = y, z = z }
  end

  return player_position_from_text(value)
end

function player_position_call_vector(object, method_name)
  if not minigame_object_valid(object) then
    return nil, "invalid object"
  end

  local method = minigame_userdata_method(object, method_name)
  if type(method) ~= "function" then
    return nil, "method unavailable"
  end

  local ok, value = pcall(function()
    return method(object)
  end)
  if not ok then
    return nil, tostring(value)
  end

  local position = player_position_from_vector(value)
  if position ~= nil then
    return position, ""
  end
  return nil, "method returned non-vector " .. minigame_compact_value(minigame_value_to_string(value))
end

function player_position_property_vector(object, property_name)
  if not minigame_object_valid(object) then
    return nil, "invalid object"
  end
  local value = minigame_try_property(object, property_name)
  if value == nil then
    return nil, "property unavailable"
  end
  local position = player_position_from_vector(value)
  if position ~= nil then
    return position, ""
  end
  return nil, "property returned non-vector " .. minigame_compact_value(minigame_value_to_string(value))
end

function player_position_component_vector(object, component_property, vector_property)
  if not minigame_object_valid(object) then
    return nil, "invalid object"
  end
  local component = minigame_try_property(object, component_property)
  if not minigame_object_valid(component) then
    return nil, "component unavailable"
  end
  return player_position_property_vector(component, vector_property)
end

function player_position_add_candidate(candidates, seen, object, source)
  if not minigame_object_valid(object) then
    return
  end
  local key = minigame_object_address(object)
  if key == "" then
    key = minigame_object_full_name(object)
  end
  if key == "" then
    key = tostring(object or "")
  end
  if key == "" or seen[key] then
    return
  end
  seen[key] = true
  candidates[#candidates + 1] = {
    object = object,
    source = tostring(source or ""),
    address = minigame_object_address(object),
    objectName = minigame_object_name(object),
    fullName = minigame_object_full_name(object),
    className = minigame_object_class_name(object),
  }
end

function player_position_candidate_pawns(player_state)
  local candidates = {}
  local seen = {}
  local controller = minigame_try_property(player_state, "Owner")

  for _, property_name in ipairs({ "PawnPrivate", "Pawn", "Character", "DefaultPawn" }) do
    player_position_add_candidate(
      candidates,
      seen,
      minigame_try_property(player_state, property_name),
      "player_state." .. property_name
    )
  end

  if minigame_object_valid(controller) then
    for _, property_name in ipairs({ "AcknowledgedPawn", "Pawn", "Character", "ControlledPawn" }) do
      player_position_add_candidate(
        candidates,
        seen,
        minigame_try_property(controller, property_name),
        "controller." .. property_name
      )
    end
  end

  return candidates, controller
end

function player_position_read_from_pawn(pawn, options)
  local attempts = {}
  local opts = type(options) == "table" and options or {}
  local allow_method_calls =
    opts.callMethods == true or
    option_boolean(opts, "callmethods", false) or
    option_boolean(opts, "methods", false)

  if allow_method_calls then
    for _, method_name in ipairs({
      "K2_GetActorLocation",
      "GetActorLocation",
      "GetTransform",
    }) do
      local position, err = player_position_call_vector(pawn, method_name)
      attempts[#attempts + 1] = {
        source = "pawn." .. method_name,
        ok = position ~= nil,
        error = tostring(err or ""),
      }
      if position ~= nil then
        return position, "pawn." .. method_name, attempts
      end
    end
  else
    for _, method_name in ipairs({
      "K2_GetActorLocation",
      "GetActorLocation",
      "GetTransform",
    }) do
      attempts[#attempts + 1] = {
        source = "pawn." .. method_name,
        ok = false,
        error = "skipped-unsafe-struct-return",
      }
    end
  end

  for _, chain in ipairs({
    { component = "RootComponent", vector = "RelativeLocation" },
    { component = "CollisionCylinder", vector = "RelativeLocation" },
    { component = "CapsuleComponent", vector = "RelativeLocation" },
    { component = "Mesh", vector = "RelativeLocation" },
  }) do
    local position, err = player_position_component_vector(pawn, chain.component, chain.vector)
    attempts[#attempts + 1] = {
      source = "pawn." .. chain.component .. "." .. chain.vector,
      ok = position ~= nil,
      error = tostring(err or ""),
    }
    if position ~= nil then
      return position, "pawn." .. chain.component .. "." .. chain.vector, attempts
    end
  end

  for _, property_name in ipairs({
    "Location",
    "RelativeLocation",
    "ReplicatedMovement",
    "ActorLocation",
    "K2Node_ComponentBoundEvent_Location",
  }) do
    local position, err = player_position_property_vector(pawn, property_name)
    attempts[#attempts + 1] = {
      source = "pawn." .. property_name,
      ok = position ~= nil,
      error = tostring(err or ""),
    }
    if position ~= nil then
      return position, "pawn." .. property_name, attempts
    end
  end

  return nil, "", attempts
end

function player_position_identity_from_cache(players, player_name, candidates)
  local lowered_name = trim_string(player_name or ""):lower()
  local candidate_map = {}
  for _, candidate in ipairs(candidates or {}) do
    local lowered = trim_string(candidate):lower()
    if lowered ~= "" then
      candidate_map[lowered] = true
    end
  end

  for _, player in ipairs(players or {}) do
    local values = {
      player.uuid,
      player.id,
      player.username,
      player.playerName,
      player.displayName,
      player.originalName,
      player.playerStatePath,
      player.controllerPath,
    }
    for _, value in ipairs(values) do
      local lowered = trim_string(value or ""):lower()
      if lowered ~= "" and (candidate_map[lowered] or lowered == lowered_name) then
        return player, lowered == lowered_name and "cache.name" or "cache.candidate"
      end
    end
  end

  return nil, ""
end

function player_position_candidate_pawns_from_controller(controller)
  local candidates = {}
  local seen = {}
  if not minigame_object_valid(controller) then
    return candidates
  end

  for _, property_name in ipairs({ "AcknowledgedPawn", "Pawn", "Character", "ControlledPawn" }) do
    player_position_add_candidate(
      candidates,
      seen,
      minigame_try_property(controller, property_name),
      "controller." .. property_name
    )
  end

  return candidates
end

function player_position_identity_from_live_target(known_players, target, target_count)
  target = type(target) == "table" and target or {}
  known_players = type(known_players) == "table" and known_players or {}

  local candidates = {
    target.playerId,
    target.name,
    target.userName,
    target.displayName,
    target.controllerPath,
    target.playerStatePath,
    target.label,
  }
  local identity, identity_source = player_position_identity_from_cache(known_players, target.name, candidates)
  if identity ~= nil then
    return identity, identity_source
  end

  if tonumber(target_count) == 1 and #known_players == 1 then
    return known_players[1], "cache.single-live-controller"
  end

  return nil, ""
end

function player_position_parse_native_lines(text)
  local fields = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([A-Za-z0-9_]+)=(.*)$")
    if key ~= nil then
      fields[key] = value or ""
    end
  end
  return fields
end

function player_position_parse_pipe_fields(text)
  local fields = {}
  for part in tostring(text or ""):gmatch("[^|]+") do
    local key, value = part:match("^([A-Za-z0-9_]+)=(.*)$")
    if key ~= nil then
      fields[key] = value or ""
    end
  end
  return fields
end

function player_position_native_attempt(fields, source_value, source_label, raw)
  fields = type(fields) == "table" and fields or {}
  local detail = tostring(fields.detail or "native helper returned ok=false")
  return {
    source = "native.BMFSocketPlayerLocation." .. tostring(source_label or "source"),
    ok = tostring(fields.ok or "") == "true",
    address = tostring(source_value or ""),
    sourceKind = tostring(fields.source_kind or ""),
    sourceObject = tostring(fields.source_object or ""),
    sourceFullName = tostring(fields.source_full_name or ""),
    controller = tostring(fields.controller or ""),
    controllerFullName = tostring(fields.controller_full_name or ""),
    pawn = tostring(fields.pawn or ""),
    pawnFullName = tostring(fields.pawn_full_name or ""),
    detail = detail,
    raw = tostring(raw or ""),
  }
end

function player_position_native_position_from_attempt(attempt, fields)
  if not (attempt and attempt.ok == true) then
    return nil
  end
  local position = {
    x = finite_number(fields.x, nil),
    y = finite_number(fields.y, nil),
    z = finite_number(fields.z, nil),
  }
  if position.x ~= nil and position.y ~= nil and position.z ~= nil then
    attempt.detail = "ok"
    return position
  end
  attempt.ok = false
  attempt.detail = "native helper returned incomplete coordinates"
  return nil
end

function player_position_native_from_source(source_value, query, source_label)
  if type(BMFSocketPlayerLocation) ~= "function" then
    return nil, "BMFSocketPlayerLocation unavailable", {
      source = "native.BMFSocketPlayerLocation." .. tostring(source_label or "source"),
      ok = false,
      address = tostring(source_value or ""),
      detail = "native helper unavailable",
    }
  end

  local ok, response = pcall(BMFSocketPlayerLocation, tostring(source_value or ""), tostring(query or ""))
  if not ok then
    return nil, tostring(response or "native helper failed"), {
      source = "native.BMFSocketPlayerLocation." .. tostring(source_label or "source"),
      ok = false,
      address = tostring(source_value or ""),
      detail = tostring(response or "native helper failed"),
    }
  end

  local fields = player_position_parse_native_lines(response)
  local attempt = player_position_native_attempt(fields, source_value, source_label, response)
  local position = player_position_native_position_from_attempt(attempt, fields)
  if position ~= nil then
    return position, attempt.source, attempt
  end

  return nil, attempt.detail, attempt
end

function player_position_native_from_controller(controller, query)
  if type(BMFSocketPlayerLocation) ~= "function" then
    return nil, "BMFSocketPlayerLocation unavailable", {
      source = "native.BMFSocketPlayerLocation",
      ok = false,
      address = "",
      detail = "native helper unavailable",
    }
  end
  if not minigame_object_valid(controller) then
    return nil, "controller unavailable", {
      source = "native.BMFSocketPlayerLocation",
      ok = false,
      address = "",
      detail = "controller unavailable",
    }
  end

  local sources = {}
  local seen = {}
  local function add_source(object, source)
    if not minigame_object_valid(object) then
      return
    end
    local address = minigame_object_address(object)
    if address == "" then
      address = live_chat_object_key(object, "")
    end
    if address == "" or seen[address] then
      return
    end
    seen[address] = true
    sources[#sources + 1] = {
      address = address,
      source = tostring(source or ""),
      objectName = minigame_object_name(object),
      fullName = minigame_object_full_name(object),
    }
  end

  add_source(controller, "controller")
  for _, property_name in ipairs({ "Pawn", "AcknowledgedPawn", "Character", "ControlledPawn" }) do
    add_source(minigame_try_property(controller, property_name), "controller." .. property_name)
  end

  if #sources == 0 then
    return nil, "controller address unavailable", {
      source = "native.BMFSocketPlayerLocation",
      ok = false,
      address = "",
      detail = "controller address unavailable",
    }
  end

  local attempts = {}
  local last_detail = "native helper returned no position"
  for _, source in ipairs(sources) do
    local ok, response = pcall(BMFSocketPlayerLocation, source.address, tostring(query or ""))
    if not ok then
      last_detail = tostring(response or "native helper failed")
      attempts[#attempts + 1] = {
        source = "native.BMFSocketPlayerLocation." .. source.source,
        ok = false,
        address = source.address,
        objectName = source.objectName,
        fullName = source.fullName,
        detail = last_detail,
      }
    else
      local fields = player_position_parse_native_lines(response)
      local detail = tostring(fields.detail or "native helper returned ok=false")
      local attempt = {
        source = "native.BMFSocketPlayerLocation." .. source.source,
        ok = tostring(fields.ok or "") == "true",
        address = source.address,
        objectName = source.objectName,
        fullName = source.fullName,
        sourceKind = tostring(fields.source_kind or ""),
        sourceObject = tostring(fields.source_object or ""),
        sourceFullName = tostring(fields.source_full_name or ""),
        controller = tostring(fields.controller or ""),
        controllerFullName = tostring(fields.controller_full_name or ""),
        pawn = tostring(fields.pawn or ""),
        pawnFullName = tostring(fields.pawn_full_name or ""),
        detail = detail,
        raw = tostring(response or ""),
      }
      attempts[#attempts + 1] = attempt

      if attempt.ok then
        local position = {
          x = finite_number(fields.x, nil),
          y = finite_number(fields.y, nil),
          z = finite_number(fields.z, nil),
        }
        if position.x ~= nil and position.y ~= nil and position.z ~= nil then
          attempt.detail = "ok"
          attempt.attempts = attempts
          return position, attempt.source, attempt
        end
        last_detail = "native helper returned incomplete coordinates"
        attempt.ok = false
        attempt.detail = last_detail
      else
        last_detail = detail
      end
    end
  end

  return nil, last_detail, {
    source = "native.BMFSocketPlayerLocation",
    ok = false,
    address = sources[1].address,
    detail = last_detail,
    attempts = attempts,
  }
end

function player_position_known_records_snapshot(opts, query, limit)
  opts = type(opts) == "table" and opts or {}
  query = trim_string(query or "")
  limit = tonumber(limit) or 32

  local listed = BMF.players.list()
  local known_players = listed.data and type(listed.data.players) == "table" and listed.data.players or {}
  local selected = {}
  local resolve_candidates = {}
  if query ~= "" then
    local found = BMF.players.find(known_players, query)
    if found.ok and found.data and found.data.player then
      selected[#selected + 1] = found.data.player
    else
      resolve_candidates = found.data and found.data.players or {}
    end
  else
    for _, player in ipairs(known_players or {}) do
      selected[#selected + 1] = player
    end
  end

  local players = {}
  local positioned = 0
  local max_count = math.min(limit, #(selected or {}))
  local native_available = type(BMFSocketPlayerLocation) == "function"

  for index = 1, max_count do
    local player = selected[index]
    local attempts = {}
    local position = nil
    local source = ""
    local native_detail = nil
    local source_values = {}

    local controller_path = trim_string(player and player.controllerPath or "")
    local player_state_path = trim_string(player and player.playerStatePath or "")
    if controller_path ~= "" then
      source_values[#source_values + 1] = { value = controller_path, label = "cache.controllerPath" }
    end
    if player_state_path ~= "" then
      source_values[#source_values + 1] = { value = player_state_path, label = "cache.playerStatePath" }
    end

    for _, source_value in ipairs(source_values) do
      position, source, native_detail = player_position_native_from_source(
        source_value.value,
        query ~= "" and query or player and (player.username or player.playerName or player.displayName or player.uuid) or "",
        source_value.label
      )
      attempts[#attempts + 1] = native_detail
      if position ~= nil then
        break
      end
    end

    if position ~= nil then
      positioned = positioned + 1
    end

    players[#players + 1] = {
      player = {
        id = tostring(player and (player.uuid or player.id) or ""),
        uuid = tostring(player and (player.uuid or player.id) or ""),
        name = tostring(player and (player.playerName or player.username or player.displayName) or ""),
        username = tostring(player and (player.username or player.playerName) or ""),
        displayName = tostring(player and (player.displayName or player.username or player.playerName) or ""),
        identitySource = "cache",
      },
      ok = position ~= nil,
      position = position,
      source = source,
      playerState = tostring(player_state_path or ""),
      playerStateName = tostring(player_state_path or ""),
      controller = native_detail and native_detail.address or tostring(controller_path or ""),
      controllerName = native_detail and native_detail.controller or tostring(controller_path or ""),
      controllerFullName = native_detail and native_detail.controllerFullName or "",
      pawn = native_detail and native_detail.pawn or "",
      pawnName = native_detail and native_detail.pawn or "",
      pawnFullName = native_detail and native_detail.pawnFullName or "",
      pawnSource = native_detail and native_detail.sourceKind or "",
      attempts = opts.includeMissing == true and attempts or nil,
      native = native_detail,
    }
  end

  local lines = {
    "source=bmf.players.positions",
    "query=" .. query,
    "source_mode=native-cache",
    "player_array_count=0",
    "live_controllers=0",
    "players=" .. tostring(#(selected or {})),
    "returned=" .. tostring(#players),
    "positioned=" .. tostring(positioned),
    "known_players=" .. tostring(#known_players),
    "native_available=" .. tostring(native_available),
    "adapter=" .. tostring((listed.data and listed.data.adapter) or ""),
  }
  if query ~= "" and #players == 0 then
    lines[#lines + 1] = "code=PLAYER_NOT_FOUND"
    local candidate_texts = {}
    for _, candidate in ipairs(resolve_candidates or {}) do
      if type(candidate) == "table" then
        candidate_texts[#candidate_texts + 1] = first_string(
          candidate.uuid,
          candidate.id,
          candidate.username,
          candidate.playerName,
          candidate.displayName,
          candidate.controllerPath,
          candidate.playerStatePath
        ) or ""
      else
        candidate_texts[#candidate_texts + 1] = tostring(candidate or "")
      end
    end
    lines[#lines + 1] = "candidates=" .. table.concat(candidate_texts, "|")
  end
  for index, player in ipairs(players) do
    local pos = player.position or {}
    lines[#lines + 1] =
      "position_" .. tostring(index) ..
      "=" .. tostring(player.player.name or "") ..
      "|id=" .. tostring(player.player.id or "") ..
      "|ok=" .. tostring(player.ok == true) ..
      "|x=" .. tostring(pos.x or "") ..
      "|y=" .. tostring(pos.y or "") ..
      "|z=" .. tostring(pos.z or "") ..
      "|source=" .. tostring(player.source or "") ..
      "|pawn=" .. tostring(player.pawn or "") ..
      "|pawn_source=" .. tostring(player.pawnSource or "")
  end

  local data = {
    source = "bmf.players.positions",
    checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    query = query,
    sourceMode = "native-cache",
    playerArrayCount = 0,
    liveControllerCount = 0,
    nativeAvailable = native_available,
    players = players,
    counts = {
      observed = #(selected or {}),
      returned = #players,
      positioned = positioned,
      knownPlayers = #known_players,
    },
    lines = lines,
  }
  lines[#lines + 1] = "positions_json=" .. json_encode(data)
  return data
end

function player_position_live_controller_snapshot(opts, query, limit)
  opts = type(opts) == "table" and opts or {}
  query = trim_string(query or "")
  limit = tonumber(limit) or 32

  local listed = BMF.players.list()
  local known_players = listed.data and type(listed.data.players) == "table" and listed.data.players or {}
  local targets = {}
  local selected = {}

  if query ~= "" then
    local target, resolved_targets = live_chat_resolve_target(query)
    targets = resolved_targets or {}
    if target ~= nil then
      selected[#selected + 1] = target
    end
  else
    targets = live_chat_collect_targets()
    for _, target in ipairs(targets or {}) do
      selected[#selected + 1] = target
    end
  end

  local players = {}
  local positioned = 0
  local max_count = math.min(limit, #(selected or {}))
  local native_available = type(BMFSocketPlayerLocation) == "function"
  local allow_lua_pawn_read =
    opts.luaPawnRead == true or
    opts.luaVectors == true or
    option_boolean(opts, "luapawnread", false) or
    option_boolean(opts, "luavectors", false)

  for index = 1, max_count do
    local target = selected[index]
    local identity, identity_source = player_position_identity_from_live_target(known_players, target, #(targets or {}))
    local pawn_candidates = {}
    local position = nil
    local source = ""
    local attempts = {}
    local pawn_record = nil
    local native_detail = nil

    position, source, native_detail = player_position_native_from_controller(
      target and target.controller or nil,
      query ~= "" and query or target and (target.name or target.userName or target.displayName or target.playerId) or ""
    )
    attempts[#attempts + 1] = native_detail or {
      source = "native.BMFSocketPlayerLocation",
      ok = false,
      detail = "native detail missing",
    }

    if position == nil and allow_lua_pawn_read then
      pawn_candidates = player_position_candidate_pawns_from_controller(target and target.controller or nil)
      for _, candidate in ipairs(pawn_candidates) do
        local lua_position, lua_source, lua_attempts = player_position_read_from_pawn(candidate.object, opts)
        for _, attempt in ipairs(lua_attempts or {}) do
          attempts[#attempts + 1] = attempt
        end
        if lua_position ~= nil then
          position = lua_position
          source = lua_source
          pawn_record = candidate
          break
        end
      end
    end

    if position ~= nil then
      positioned = positioned + 1
    end

    local player_name = first_string(
      identity and identity.username,
      identity and identity.playerName,
      identity and identity.displayName,
      target and target.name,
      target and target.userName,
      target and target.displayName
    ) or ""

    players[#players + 1] = {
      player = {
        id = tostring(identity and (identity.uuid or identity.id) or target and target.playerId or ""),
        uuid = tostring(identity and (identity.uuid or identity.id) or target and target.playerId or ""),
        name = tostring(player_name or ""),
        username = tostring(identity and identity.username or target and target.userName or player_name or ""),
        displayName = tostring(identity and identity.displayName or target and target.displayName or player_name or ""),
        identitySource = identity_source,
      },
      ok = position ~= nil,
      position = position,
      source = source,
      playerState = tostring(target and target.playerStatePath or ""),
      playerStateName = tostring(target and target.playerStatePath or ""),
      controller = native_detail and native_detail.address or live_chat_object_key(target and target.controller or nil, ""),
      controllerName = native_detail and native_detail.controller or live_chat_object_label(target and target.controller or nil, ""),
      controllerFullName = native_detail and native_detail.controllerFullName or live_chat_object_full_name(target and target.controller or nil),
      pawn = native_detail and native_detail.pawn or pawn_record and pawn_record.address or "",
      pawnName = native_detail and native_detail.pawn or pawn_record and pawn_record.objectName or "",
      pawnFullName = native_detail and native_detail.pawnFullName or "",
      pawnSource = pawn_record and pawn_record.source or "",
      pawnCandidates = pawn_candidates,
      attempts = opts.includeMissing == true and attempts or nil,
      native = native_detail,
    }
  end

  local lines = {
    "source=bmf.players.positions",
    "query=" .. query,
    "source_mode=native-controller",
    "player_array_count=0",
    "live_controllers=" .. tostring(#(targets or {})),
    "players=" .. tostring(#(selected or {})),
    "returned=" .. tostring(#players),
    "positioned=" .. tostring(positioned),
    "known_players=" .. tostring(#known_players),
    "native_available=" .. tostring(native_available),
  }
  if query ~= "" and #players == 0 then
    lines[#lines + 1] = "code=PLAYER_NOT_FOUND"
  end
  for index, player in ipairs(players) do
    local pos = player.position or {}
    lines[#lines + 1] =
      "position_" .. tostring(index) .. "=" ..
      tostring(player.player.name or "") ..
      "|id=" .. tostring(player.player.id or "") ..
      "|ok=" .. tostring(player.ok == true) ..
      "|x=" .. tostring(pos.x or "") ..
      "|y=" .. tostring(pos.y or "") ..
      "|z=" .. tostring(pos.z or "") ..
      "|source=" .. tostring(player.source or "") ..
      "|pawn=" .. tostring(player.pawn or "") ..
      "|pawn_source=" .. tostring(player.pawnSource or "")
  end

  local data = {
    source = "bmf.players.positions",
    checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    query = query,
    sourceMode = "native-controller",
    playerArrayCount = 0,
    liveControllerCount = #(targets or {}),
    nativeAvailable = native_available,
    players = players,
    counts = {
      observed = #(selected or {}),
      returned = #players,
      positioned = positioned,
      knownPlayers = #known_players,
    },
    lines = lines,
  }
  lines[#lines + 1] = "positions_json=" .. json_encode(data)
  return data
end

BMF.players.positions = function(options)
  local opts = type(options) == "table" and options or {}
  local query = trim_string(opts.player or opts.query or opts.name or "")
  local limit = tonumber(opts.limit) or 32
  if limit < 1 then
    limit = 1
  elseif limit > 128 then
    limit = 128
  end

  local allow_live_pawn_read =
    opts.unsafe == true or
    opts.allowLivePawnRead == true or
    option_boolean(opts, "unsafe", false) or
    option_boolean(opts, "allowlivepawnread", false)

  local allow_native_cache =
    opts.nativeController ~= false and
    opts.nativeCache ~= false and
    os.getenv("BMF_PLAYERS_POSITIONS_NATIVE_CACHE") ~= "0"
  if allow_native_cache then
    local native_cache_data = player_position_known_records_snapshot(opts, query, limit)
    local native_cache_counts = native_cache_data.counts or {}
    if tonumber(native_cache_counts.positioned) and tonumber(native_cache_counts.positioned) > 0 then
      return result(true, "OK", "Native cached player positions collected", native_cache_data)
    end

    if not allow_live_pawn_read and opts.liveController ~= true and os.getenv("BMF_PLAYERS_POSITIONS_LIVE_CONTROLLER") ~= "1" then
      native_cache_data.lines[#native_cache_data.lines + 1] = "code=POSITION_UNAVAILABLE"
      native_cache_data.lines[#native_cache_data.lines + 1] =
        "reason=native cached player position was unavailable; live Lua controller reads require livecontroller=1"
      return result(false, "POSITION_UNAVAILABLE", "Native cached player position was unavailable", native_cache_data)
    end
  end

  local allow_live_controller_read =
    opts.liveController == true or
    option_boolean(opts, "livecontroller", false) or
    os.getenv("BMF_PLAYERS_POSITIONS_LIVE_CONTROLLER") == "1"
  if allow_live_controller_read then
    local live_controller_data = player_position_live_controller_snapshot(opts, query, limit)
    local live_controller_counts = live_controller_data.counts or {}
    if tonumber(live_controller_counts.positioned) and tonumber(live_controller_counts.positioned) > 0 then
      return result(true, "OK", "Live controller player positions collected", live_controller_data)
    end

    if not allow_live_pawn_read then
      live_controller_data.lines[#live_controller_data.lines + 1] = "code=POSITION_UNAVAILABLE"
      live_controller_data.lines[#live_controller_data.lines + 1] =
        "reason=live controller pawn position was unavailable; broad PlayerState reads require unsafe=1"
      return result(false, "POSITION_UNAVAILABLE", "Live controller pawn position was unavailable", live_controller_data)
    end
  end

  if not allow_live_pawn_read then
    local lines = {
      "source=bmf.players.positions",
      "query=" .. query,
      "source_mode=disabled-safe-default",
      "player_array_count=0",
      "players=0",
      "returned=0",
      "positioned=0",
      "known_players=0",
      "code=POSITION_UNAVAILABLE",
      "reason=live pawn position reads require native support or unsafe=1",
    }
    local data = {
      source = "bmf.players.positions",
      checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      query = query,
      sourceMode = "disabled-safe-default",
      playerArrayCount = 0,
      players = {},
      counts = {
        observed = 0,
        returned = 0,
        positioned = 0,
        knownPlayers = 0,
      },
      lines = lines,
    }
    lines[#lines + 1] = "positions_json=" .. json_encode(data)
    return result(false, "POSITION_UNAVAILABLE", "Live pawn position reads require native support or unsafe=1", data)
  end

  local player_items = {}
  local meta = {
    source = "",
    playerArrayCount = 0,
    errors = {},
  }
  local resolve_candidates = {}
  if query ~= "" then
    local item, candidates, item_meta = minigame_live_resolve_player_state_for_assignment(query)
    resolve_candidates = candidates or {}
    meta = item_meta or meta
    if item and minigame_object_valid(item.object) then
      player_items[#player_items + 1] = item
    end
  else
    player_items, meta = minigame_live_player_states({
      fallbackFindAll = opts.fallbackFindAll ~= false,
    })
  end

  local listed = BMF.players.list()
  local known_players = listed.data and listed.data.players or {}
  local players = {}
  local positioned = 0

  for _, item in ipairs(player_items or {}) do
    if #players >= limit then
      break
    end
    local player_state = item.object
    local property_values = minigame_live_collect_property_values(
      player_state,
      {
        "UserName",
        "PlayerNamePrivate",
        "PlayerName",
        "DisplayName",
      },
      0,
      false
    )
    local player_name = minigame_live_first_property_text(property_values, {
      "UserName",
      "PlayerNamePrivate",
      "PlayerName",
      "DisplayName",
    })
    local assignment_candidates = minigame_live_player_assignment_candidates(player_state)
    local identity, identity_source = player_position_identity_from_cache(known_players, player_name, assignment_candidates)
    local pawn_candidates, controller = player_position_candidate_pawns(player_state)
    local position = nil
    local source = ""
    local attempts = {}
    local pawn_record = nil

    for _, candidate in ipairs(pawn_candidates) do
      position, source, attempts = player_position_read_from_pawn(candidate.object, opts)
      if position ~= nil then
        pawn_record = candidate
        break
      end
    end

    if position ~= nil then
      positioned = positioned + 1
    end

    local record = {
      player = {
        id = tostring(identity and (identity.uuid or identity.id) or ""),
        uuid = tostring(identity and (identity.uuid or identity.id) or ""),
        name = tostring(player_name or ""),
        username = tostring(identity and identity.username or player_name or ""),
        displayName = tostring(identity and identity.displayName or player_name or ""),
        identitySource = identity_source,
      },
      ok = position ~= nil,
      position = position,
      source = source,
      playerState = minigame_object_address(player_state),
      playerStateName = minigame_object_name(player_state),
      controller = minigame_object_address(controller),
      controllerName = minigame_object_name(controller),
      pawn = pawn_record and pawn_record.address or "",
      pawnName = pawn_record and pawn_record.objectName or "",
      pawnSource = pawn_record and pawn_record.source or "",
      pawnCandidates = pawn_candidates,
      attempts = opts.includeMissing == true and attempts or nil,
    }
    players[#players + 1] = record
  end

  local lines = {
    "source=bmf.players.positions",
    "query=" .. query,
    "source_mode=" .. tostring(meta and meta.source or ""),
    "player_array_count=" .. tostring(meta and meta.playerArrayCount or 0),
    "players=" .. tostring(#(player_items or {})),
    "returned=" .. tostring(#players),
    "positioned=" .. tostring(positioned),
    "known_players=" .. tostring(#known_players),
  }

  if query ~= "" and #players == 0 then
    lines[#lines + 1] = "code=PLAYER_NOT_FOUND"
    lines[#lines + 1] = "candidates=" .. table.concat(resolve_candidates or {}, "|")
  end
  for index, error_text in ipairs((meta and meta.errors) or {}) do
    lines[#lines + 1] = "error_" .. tostring(index) .. "=" .. tostring(error_text)
  end
  for index, player in ipairs(players) do
    local pos = player.position or {}
    lines[#lines + 1] =
      "position_" .. tostring(index) .. "=" ..
      tostring(player.player.name or "") ..
      "|id=" .. tostring(player.player.id or "") ..
      "|ok=" .. tostring(player.ok == true) ..
      "|x=" .. tostring(pos.x or "") ..
      "|y=" .. tostring(pos.y or "") ..
      "|z=" .. tostring(pos.z or "") ..
      "|source=" .. tostring(player.source or "") ..
      "|pawn=" .. tostring(player.pawn or "") ..
      "|pawn_source=" .. tostring(player.pawnSource or "")
  end

  local data = {
    source = "bmf.players.positions",
    checkedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    query = query,
    sourceMode = tostring(meta and meta.source or ""),
    playerArrayCount = meta and meta.playerArrayCount or 0,
    players = players,
    counts = {
      observed = #(player_items or {}),
      returned = #players,
      positioned = positioned,
      knownPlayers = #known_players,
    },
    lines = lines,
  }
  lines[#lines + 1] = "positions_json=" .. json_encode(data)

  local ok = #players > 0 and (query == "" or positioned > 0)
  return result(ok, ok and "OK" or "POSITION_UNAVAILABLE", ok and "Live player positions collected" or "Live player positions were unavailable", data)
end

BMF.players.normalize = function(record)
  if type(record) ~= "table" then
    return result(false, "INVALID_PLAYER", "player record table is required")
  end

  local uuid = first_string(record.uuid, record.id, record.playerId, record.playerID)
  if not is_uuid(uuid) then
    return result(false, "INVALID_PLAYER_ID", "player UUID is missing or invalid")
  end

  local username = first_string(record.username, record.playerName, record.originalName, record.name)
  local display_name = first_string(record.displayName, record.display_name, record.name, username)
  local original_name = first_string(record.originalName, record.playerName, username)

  local roles = {}
  if type(record.roles) == "table" then
    for _, role in ipairs(record.roles) do
      if type(role) == "string" and trim_string(role) ~= "" then
        roles[#roles + 1] = role
      end
    end
  end

  local normalized = {
    id = uuid,
    uuid = uuid,
    username = username or "",
    playerName = first_string(record.playerName, username) or "",
    displayName = display_name or "",
    originalName = original_name or "",
    roles = roles,
    permissions = BMF.permissions.toMap(record.permissions),
    controllerAvailable = record.controllerAvailable and true or false,
  }

  if type(record.pingMs) == "number" then
    normalized.pingMs = record.pingMs
  end
  if type(record.onlineTimeMs) == "number" then
    normalized.onlineTimeMs = record.onlineTimeMs
  end
  if type(record.address) == "string" then
    normalized.address = record.address
  end
  if type(record.health) == "number" then
    normalized.health = record.health
  end
  if type(record.playerStatePath) == "string" then
    normalized.playerStatePath = record.playerStatePath
  end
  if type(record.controllerPath) == "string" then
    normalized.controllerPath = record.controllerPath
  end
  if type(record.position) == "table" then
    normalized.position = {
      x = finite_number(record.position.x or record.position.X, 0),
      y = finite_number(record.position.y or record.position.Y, 0),
      z = finite_number(record.position.z or record.position.Z, 0),
    }
  end

  return result(true, "OK", "Player record normalized", { player = normalized })
end

BMF.players.normalizeList = function(records)
  if type(records) ~= "table" then
    return result(false, "INVALID_PLAYERS", "players array is required")
  end

  local players = {}
  local invalid = {}
  for index, record in ipairs(records) do
    local normalized = BMF.players.normalize(external_player_record(record))
    if normalized.ok then
      players[#players + 1] = normalized.data.player
    else
      invalid[#invalid + 1] = {
        index = index,
        code = normalized.code,
        message = normalized.message,
      }
    end
  end

  return result(true, "OK", "Player list normalized", {
    players = players,
    invalid = invalid,
  })
end

BMF.players.sync = function(records, options)
  if type(records) ~= "table" then
    return result(false, "INVALID_PLAYERS", "players array is required", {
      cachePath = PLAYER_CACHE_PATH,
    })
  end

  options = type(options) == "table" and options or {}
  local normalized = BMF.players.normalizeList(records)
  if not normalized.ok then
    return normalized
  end

  local players = normalized.data.players or {}
  local invalid = normalized.data.invalid or {}
  local cache = {
    schemaVersion = 1,
    adapter = tostring(options.adapter or "external-cache"),
    source = tostring(options.source or "external"),
    updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    players = players,
    invalid = invalid,
  }

  local written = write_player_cache(cache)
  local response = result(written, written and (#invalid > 0 and "PARTIAL" or "OK") or "CACHE_WRITE_FAILED", written and "Player identity cache synced" or "Player identity cache could not be written", {
    players = players,
    invalid = invalid,
    playerCount = #players,
    knownPlayerCount = #players,
    invalidCount = #invalid,
    adapter = cache.adapter,
    source = cache.source,
    updatedAt = cache.updatedAt,
    cachePath = PLAYER_CACHE_PATH,
  })
  audit_record("players.sync", {
    playerCount = #players,
    invalidCount = #invalid,
    adapter = cache.adapter,
    source = cache.source,
    cachePath = PLAYER_CACHE_PATH,
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  return response
end

local function player_query_text(query)
  if type(query) == "table" then
    return first_string(
      query.uuid,
      query.id,
      query.playerId,
      query.playerID,
      query.username,
      query.displayName,
      query.playerName,
      query.originalName,
      query.playerStatePath,
      query.controllerPath,
      query.name,
      query.query
    ) or ""
  end
  return tostring(query or "")
end

local function player_matches_query(player, needle)
  local lowered = tostring(needle or ""):lower()
  if lowered == "" then
    return false, ""
  end

  local exact_fields = {
    "uuid",
    "id",
    "username",
    "playerName",
    "displayName",
    "originalName",
    "playerStatePath",
    "controllerPath",
  }
  for _, field in ipairs(exact_fields) do
    local value = tostring(player[field] or "")
    if value ~= "" and value:lower() == lowered then
      return true, field
    end
  end

  if #lowered >= 2 then
    for _, field in ipairs({ "username", "playerName", "displayName", "originalName" }) do
      local value = tostring(player[field] or "")
      if value ~= "" and value:lower():find(lowered, 1, true) then
        return true, "partial:" .. field
      end
    end
  end

  return false, ""
end

BMF.players.find = function(records, query)
  local source = "provided"
  local raw_records = records
  local raw_query = query
  local adapter = "provided"

  if query == nil then
    source = "current"
    raw_query = records
    local listed = BMF.players.list()
    if not listed.ok then
      return listed
    end
    raw_records = (listed.data and listed.data.players) or {}
    adapter = (listed.data and listed.data.adapter) or "unknown"
  end

  local normalized = BMF.players.normalizeList(raw_records)
  if not normalized.ok then
    return normalized
  end

  local needle = trim_string(player_query_text(raw_query))
  if needle == "" then
    return result(false, "PLAYER_REQUIRED", "player query is required", {
      source = source,
      adapter = adapter,
      players = normalized.data.players,
      invalid = normalized.data.invalid,
    })
  end

  for _, player in ipairs(normalized.data.players) do
    local matched, match_field = player_matches_query(player, needle)
    if matched then
      return result(true, "OK", "Player found", {
        player = player,
        query = needle,
        match = match_field,
        source = source,
        adapter = adapter,
      })
    end
  end

  return result(false, "PLAYER_NOT_FOUND", "No normalized player matched query", {
    query = needle,
    source = source,
    adapter = adapter,
    players = normalized.data.players,
    invalid = normalized.data.invalid,
  })
end

BMF.players.resolve = function(player)
  if type(player) == "table" then
    local direct = BMF.players.normalize(player)
    if direct.ok then
      direct.data.source = "direct"
      direct.data.adapter = "direct"
      return direct
    end
  end
  return BMF.players.find(player)
end

BMF.players.getName = function(player)
  local resolved = BMF.players.resolve(player)
  if not resolved.ok then
    return resolved
  end
  local record = resolved.data.player
  return result(true, "OK", "Player names resolved", {
    player = record,
    id = record.id,
    uuid = record.uuid,
    username = record.username,
    playerName = record.playerName,
    displayName = record.displayName,
    originalName = record.originalName,
    source = resolved.data.source,
    adapter = resolved.data.adapter,
  })
end

BMF.players.summary = function(player)
  local listed = BMF.players.list()
  if not listed.ok then
    return listed
  end

  local players = (listed.data and listed.data.players) or {}
  local query = trim_string(player_query_text(player))
  local found = nil
  local match = ""

  if query == "" and #players == 1 then
    found = players[1]
    match = "single-player-cache"
  elseif query ~= "" then
    local lookup = BMF.players.find(players, query)
    if lookup.ok then
      found = lookup.data.player
      match = lookup.data.match or ""
    else
      lookup.data = lookup.data or {}
      lookup.data.knownPlayerCount = #players
      lookup.data.playerCount = #players
      lookup.data.liveControllerCount = (listed.data and listed.data.liveControllerCount) or 0
      lookup.data.adapter = (listed.data and listed.data.adapter) or ""
      lookup.data.cachePath = PLAYER_CACHE_PATH
      return lookup
    end
  else
    return result(false, "PLAYER_REQUIRED", "player query is required when the cache has zero or multiple players", {
      players = players,
      knownPlayerCount = #players,
      playerCount = #players,
      liveControllerCount = (listed.data and listed.data.liveControllerCount) or 0,
      adapter = (listed.data and listed.data.adapter) or "",
      cachePath = PLAYER_CACHE_PATH,
    })
  end

  local data = {
    player = found,
    id = found.id,
    uuid = found.uuid,
    username = found.username,
    playerName = found.playerName,
    displayName = found.displayName,
    originalName = found.originalName,
    match = match,
    query = query,
    knownPlayerCount = #players,
    playerCount = #players,
    liveControllerCount = (listed.data and listed.data.liveControllerCount) or 0,
    adapter = (listed.data and listed.data.adapter) or "",
    source = (listed.data and listed.data.source) or "",
    updatedAt = (listed.data and listed.data.updatedAt) or "",
    cachePath = PLAYER_CACHE_PATH,
  }
  return result(true, "OK", "Player summary resolved", data)
end

BMF.players.formatSummary = function(summary)
  local data = summary or {}
  local player = data.player or data
  local username = first_string(player.username, player.playerName, player.originalName, player.name) or "unknown"
  local display_name = first_string(player.displayName, player.name, username) or "unknown"
  local player_id = first_string(player.uuid, player.id, player.playerId, player.playerID) or "unknown"
  local known_count = tonumber(data.knownPlayerCount or data.playerCount or 0) or 0
  local live_count = tonumber(data.liveControllerCount or 0) or 0
  return "BMF player summary: username=" .. tostring(username) ..
    " displayName=" .. tostring(display_name) ..
    " id=" .. tostring(player_id) ..
    " knownPlayers=" .. tostring(known_count) ..
    " liveControllers=" .. tostring(live_count)
end

BMF.players.whisperSummary = function(player)
  local summarized = BMF.players.summary(player)
  if not summarized.ok then
    return summarized
  end

  local message = BMF.players.formatSummary(summarized.data)
  local whispered = BMF.chat.whisper(summarized.data.player, message)
  local response = result(whispered.ok, whispered.code or (whispered.ok and "OK" or "ERROR"), whispered.ok and "Player summary whispered" or "Player summary resolved but whisper failed", {
    player = summarized.data.player,
    summary = summarized.data,
    message = message,
    delivered = whispered.ok == true and whispered.data and whispered.data.delivered == true,
    deliveredCount = whispered.data and whispered.data.deliveredCount or 0,
    attemptedCount = whispered.data and whispered.data.attemptedCount or 0,
    deliveryMode = whispered.data and whispered.data.deliveryMode or "",
    whisperCode = whispered.code,
    whisper = whispered.data,
  })
  audit_record("players.summary.whisper", {
    target = summarized.data.uuid,
    username = summarized.data.username,
    displayName = summarized.data.displayName,
    knownPlayerCount = summarized.data.knownPlayerCount,
    liveControllerCount = summarized.data.liveControllerCount,
    deliveredCount = response.data.deliveredCount,
    deliveryMode = response.data.deliveryMode,
  }, {
    source = "framework",
    severity = response.ok and "info" or "warn",
    ok = response.ok,
    code = response.code,
  })
  return response
end

BMF.interact = {}

local function interact_event_player(event)
  local player = event.player
  if type(player) == "table" then
    return {
      uuid = first_string(player.uuid, player.id, player.playerId, player.playerID) or "",
      username = first_string(player.username, player.playerName, player.originalName, player.name) or "",
      displayName = first_string(player.displayName, player.name, player.username) or "",
      controller = first_string(player.controller, player.controllerName) or "",
      pawn = first_string(player.pawn, player.pawnName) or "",
    }
  end
  return {
    uuid = first_string(event.playerUuid, event.playerId, event.uuid, event.id, event.player) or "",
    username = first_string(event.username, event.playerName, event.name) or "",
    displayName = first_string(event.displayName, event.name, event.username) or "",
    controller = first_string(event.controller, event.controllerName) or "",
    pawn = first_string(event.pawn, event.pawnName) or "",
  }
end

BMF.interact.handleConsoleMessage = function(event)
  if type(event) ~= "table" then
    return result(false, "INVALID_INTERACT_EVENT", "interact event table is required")
  end

  local message = first_string(event.message, event.consoleTag, event.tag, event.value) or ""
  local player = interact_event_player(event)
  local position = event.position
  if type(position) ~= "table" then
    position = {
      tonumber(event.x) or 0,
      tonumber(event.y) or 0,
      tonumber(event.z) or 0,
    }
  end

  local payload = {
    source = first_string(event.source, event.adapter) or "unknown",
    message = tostring(message or ""),
    player = player,
    brickName = first_string(event.brickName, event.brick) or "",
    brickAsset = first_string(event.brickAsset, event.asset) or "",
    position = position,
  }

  local emitted = BMF.events.emit("interactConsole", payload)
  audit_record("interact.console", {
    source = payload.source,
    playerUuid = player.uuid,
    playerName = player.username,
    message = payload.message,
    brickName = payload.brickName,
    brickAsset = payload.brickAsset,
    handlerCount = emitted.data and emitted.data.handlers or 0,
    errorCount = emitted.data and #(emitted.data.errors or {}) or 0,
  }, {
    source = "framework",
    actor = player.uuid,
    severity = emitted.ok and "info" or "warn",
    ok = emitted.ok,
    code = emitted.code,
  })

  local lines = {
    "event=interactConsole",
    "source=" .. tostring(payload.source or ""),
    "player_uuid=" .. tostring(player.uuid or ""),
    "player_name=" .. tostring(player.username or ""),
    "message=" .. tostring(payload.message or ""),
    "handler_count=" .. tostring(emitted.data and emitted.data.handlers or 0),
    "error_count=" .. tostring(emitted.data and #(emitted.data.errors or {}) or 0),
  }

  return result(emitted.ok, emitted.code, "Interact console message forwarded", {
    event = payload,
    handlerCount = emitted.data and emitted.data.handlers or 0,
    errors = emitted.data and emitted.data.errors or {},
    lines = lines,
  })
end

local function private_chat_result(kind, player, message)
  local text = tostring(message or "")
  if trim_string(text) == "" then
    return result(false, "INVALID_OPTIONS", "message is required")
  end
  if player_query_text(player) == "" then
    return result(false, "INVALID_OPTIONS", "player target is required")
  end
  local limited = rate_limit_check("chat." .. tostring(kind or "private"))
  if not limited.ok then
    return limited
  end

  local live_target, live_targets = live_chat_resolve_target(player)
  if live_target ~= nil then
    local delivered, failed, command = live_chat_send_to_targets({ live_target }, text)
    local response = result(#delivered > 0, #delivered > 0 and "OK" or "PLAYER_DELIVERY_UNAVAILABLE", #delivered > 0 and "Private message delivered to live player controller" or "Live player controller rejected private message", {
      channel = kind,
      query = player_query_text(player),
      target = live_chat_target_summary(live_target),
      message = text,
      delivered = #delivered > 0,
      deliveredCount = #delivered,
      attemptedCount = 1,
      failedCount = #failed,
      targets = delivered,
      failures = failed,
      command = command,
      executor = "player_controller.client_push_chat_message",
      deliveryMode = "player-controller-client-push-chat-message",
      validation = "L3 Live Player UI confirmed",
    })
    audit_record("chat." .. tostring(kind or "private"), {
      channel = kind,
      query = player_query_text(player),
      target = response.data.target,
      message = text,
      deliveredCount = #delivered,
      deliveryMode = response.data.deliveryMode,
    }, {
      source = "framework",
      severity = response.ok and "info" or "warn",
      ok = response.ok,
      code = response.code,
    })
    return response
  end

  local resolved = BMF.players.resolve(player)
  if not resolved.ok then
    audit_record("chat." .. tostring(kind or "private") .. ".target_not_found", {
      channel = kind,
      query = player_query_text(player),
      message = text,
      adapter = resolved.data and resolved.data.adapter or "",
      liveTargets = #(live_targets or {}),
    }, {
      source = "framework",
      severity = "warn",
      ok = false,
      code = resolved.code,
    })
    return resolved
  end

  local response = result(false, "PLAYER_DELIVERY_UNAVAILABLE", "Private player message delivery requires a live player adapter", {
    channel = kind,
    player = resolved.data.player,
    target = resolved.data.player.uuid,
    message = text,
    delivered = false,
    deliveredCount = 0,
    source = resolved.data.source,
    adapter = resolved.data.adapter,
    liveTargets = #(live_targets or {}),
    validationRequired = "L3 Live Player",
  })
  audit_record("chat." .. tostring(kind or "private") .. ".delivery_unavailable", {
    channel = kind,
    target = response.data.target,
    message = text,
    adapter = response.data.adapter,
    validationRequired = response.data.validationRequired,
  }, {
    source = "framework",
    severity = "warn",
    ok = false,
    code = response.code,
  })
  return response
end

BMF.chat.whisper = function(player, message)
  return private_chat_result("whisper", player, message)
end

BMF.chat.statusMessage = function(player, message)
  return private_chat_result("statusMessage", player, message)
end

BMF.timers = {}
BMF.timers.after = function(ms, callback)
  if type(callback) ~= "function" then
    return nil
  end
  local id = state.next_timer_id
  state.next_timer_id = state.next_timer_id + 1
  state.timers[id] = { cancelled = false }

  local function wrapped()
    if state.timers[id] and not state.timers[id].cancelled then
      pcall(callback)
    end
    state.timers[id] = nil
  end

  if not BMF_schedule_delayed_callback("timer_after", tonumber(ms) or 0, wrapped) then
    state.timers[id] = nil
    return nil
  end

  return id
end

BMF.timers.every = function(ms, callback)
  if type(callback) ~= "function" then
    return nil
  end
  local id = state.next_timer_id
  state.next_timer_id = state.next_timer_id + 1
  local interval = tonumber(ms) or 0
  state.timers[id] = { cancelled = false, interval = interval, count = 0 }

  local function schedule()
    return BMF_schedule_delayed_callback("timer_every", interval, function()
      local timer = state.timers[id]
      if not timer or timer.cancelled then
        state.timers[id] = nil
        return
      end
      timer.count = timer.count + 1
      local ok, err = pcall(callback, id, timer.count)
      if not ok then
        log("error", "timer callback failed: " .. tostring(err))
        state.timers[id] = nil
        return
      end
      timer = state.timers[id]
      if timer and not timer.cancelled then
        schedule()
      else
        state.timers[id] = nil
      end
    end)
  end

  if not schedule() then
    state.timers[id] = nil
    return nil
  end

  return id
end

BMF.timers.cancel = function(id)
  if state.timers[id] then
    state.timers[id].cancelled = true
    return true
  end
  return false
end

BMF.timers.activeCount = function()
  local count = 0
  for _ in pairs(state.timers) do
    count = count + 1
  end
  return count
end

local function list_command_request_files()
  local command_dir = COMMAND_DIR:gsub("/", "\\")
  if not state.command_dir_ensured then
    os.execute('if not exist "' .. command_dir .. '" mkdir "' .. command_dir .. '"')
    state.command_dir_ensured = true
  end

  local handle = io.popen('dir /b /a-d "' .. command_dir .. '\\*.request.txt" 2>nul')
  if not handle then
    return {}
  end

  local files = {}
  for line in handle:lines() do
    if line and line:match("%.request%.txt$") then
      files[#files + 1] = line
    end
  end
  handle:close()
  table.sort(files)
  return files
end

function BMF_dispatch_bmf_command_text(request_id, command_text, transport)
  local process_started_clock = os.clock()
  local process_started_epoch = os.time()
  local lines = {}
  local output_device = {
    suppressEventLog = true,
    Log = function(_, line)
      lines[#lines + 1] = tostring(line or "")
    end,
  }

  local command_name, args = command_text:match("^(%S+)%s*(.*)$")
  local ok = false
  local detail = ""
  local dispatch_started_clock = os.clock()
  if not command_name or command_name == "" then
    detail = "command name is required"
  else
    local dispatch_ok, handled_or_error = pcall(BMF.commands.dispatch, command_name, args or "", output_device)
    ok = dispatch_ok and handled_or_error and true or false
    if not dispatch_ok then
      detail = "dispatch crashed: " .. tostring(handled_or_error)
      lines[#lines + 1] = "BMF " .. tostring(command_name) .. " ERROR " .. detail
    elseif not handled_or_error then
      detail = "command was not handled"
    else
      detail = "ok"
    end
  end
  local dispatch_duration_ms = math.floor(((os.clock() - dispatch_started_clock) * 1000) + 0.5)
  local total_duration_ms = math.floor(((os.clock() - process_started_clock) * 1000) + 0.5)
  local request_created_ms = tonumber(tostring(request_id):match("_(%d%d%d%d%d%d%d%d%d%d%d%d%d)_"))
  local processed_at_ms = tonumber(process_started_epoch) and (tonumber(process_started_epoch) * 1000) or nil
  local request_age_ms = request_created_ms and processed_at_ms and (processed_at_ms - request_created_ms) or nil
  if request_age_ms and request_age_ms < 0 then
    request_age_ms = 0
  end
  BMF_telemetry_record_command(command_name or "unknown", transport or "file", ok, detail, total_duration_ms, dispatch_duration_ms, request_age_ms)

  local response = {
    "ok=" .. tostring(ok),
    "detail=" .. tostring(detail),
    "command=" .. tostring(command_text),
    "bmf_command_request_id=" .. tostring(request_id),
    "bmf_command_transport=" .. tostring(transport or "file"),
    "bmf_command_processed_at=" .. tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", process_started_epoch)),
    "bmf_command_request_age_ms=" .. tostring(request_age_ms or ""),
    "bmf_command_dispatch_ms=" .. tostring(dispatch_duration_ms),
    "bmf_command_total_ms=" .. tostring(total_duration_ms),
  }
  for _, line in ipairs(lines) do
    response[#response + 1] = tostring(line)
  end
  return table.concat(response, "\n") .. "\n", ok, detail
end

local function process_command_request(file_name)
  local request_id = tostring(file_name or ""):match("^(.*)%.request%.txt$")
  if not request_id or request_id == "" then
    return false
  end

  local request_path = COMMAND_DIR .. "/" .. file_name
  local response_path = COMMAND_DIR .. "/" .. request_id .. ".response.txt"
  local command_text = trim_string(read_file(request_path) or "")

  if command_text == "" then
    local empty_reads = tonumber(state.command_empty_reads[request_id] or 0) + 1
    state.command_empty_reads[request_id] = empty_reads
    if empty_reads < COMMAND_EMPTY_READ_RETRY_LIMIT then
      return false
    end
  else
    state.command_empty_reads[request_id] = nil
  end

  os.remove(request_path)
  state.command_empty_reads[request_id] = nil

  local response = BMF_dispatch_bmf_command_text(request_id, command_text, "file")
  write_file(response_path, response)
  return true
end

local poll_command_requests

function BMF_command_worker_poll_interval_ms()
  return BMF_env_number(
    "BMF_COMMAND_WORKER_POLL_MS",
    BMF_COMMAND_WORKER_DEFAULT_POLL_MS,
    25
  )
end

function BMF_command_worker_fallback_poll_interval_ms()
  local fallback = BMF_env_string("BMF_COMMAND_WORKER_FALLBACK_POLL_MS")
  if fallback ~= "" then
    return BMF_env_number("BMF_COMMAND_WORKER_FALLBACK_POLL_MS", BMF_COMMAND_WORKER_FALLBACK_POLL_MS, 250)
  end
  return BMF_env_number("BMF_COMMAND_WORKER_POLL_MS", BMF_COMMAND_WORKER_FALLBACK_POLL_MS, 250)
end

function BMF_command_worker_max_files_per_poll()
  return BMF_env_number(
    "BMF_COMMAND_WORKER_MAX_FILES_PER_POLL",
    BMF_COMMAND_WORKER_DEFAULT_MAX_FILES_PER_POLL,
    1
  )
end

local function schedule_command_worker_poll(delay_ms)
  local delay = tonumber(delay_ms) or state.command_worker_fallback_poll_interval_ms or BMF_COMMAND_WORKER_FALLBACK_POLL_MS
  return BMF_schedule_delayed_callback("command_worker", delay, function()
    run_on_game_thread(function()
      if poll_command_requests then
        poll_command_requests()
      end
    end)
  end)
end

function BMF_poll_command_requests_once()
  local poll_started_clock = os.clock()
  local processed_files = 0
  local poll_ok = true
  local max_files = state.command_worker_max_files_per_poll or BMF_COMMAND_WORKER_DEFAULT_MAX_FILES_PER_POLL
  for _, file_name in ipairs(list_command_request_files()) do
    local ok, processed_or_error = pcall(process_command_request, file_name)
    if not ok then
      poll_ok = false
      log("error", "command worker failed for " .. tostring(file_name) .. ": " .. tostring(processed_or_error))
    elseif processed_or_error == true then
      processed_files = processed_files + 1
    end
    if processed_files >= max_files then
      break
    end
  end

  if state.socket.started and type(BMF_drain_socket_messages) == "function" then
    local ok, err = pcall(BMF_drain_socket_messages, 128)
    if not ok then
      poll_ok = false
      state.socket.last_error = "socket command-worker watchdog failed: " .. tostring(err)
    end
  end
  if processed_files > 0 or not poll_ok then
    BMF_telemetry_record_worker("command_polls", BMF_telemetry_duration_ms(poll_started_clock), poll_ok, "files_processed", processed_files)
  end
end

poll_command_requests = function()
  BMF_poll_command_requests_once()

  if state.command_worker_started then
    if not schedule_command_worker_poll(state.command_worker_fallback_poll_interval_ms) then
      state.command_worker_started = false
      state.command_worker_mode = "stopped"
      log("error", "command worker stopped: no game-thread scheduler available")
    end
  end
end

function BMF_poll_command_requests_async()
  if not state.command_worker_started then
    return true
  end

  local request_files = list_command_request_files()
  if #request_files == 0 then
    return false
  end

  local scheduled_files = 0
  local max_files = state.command_worker_max_files_per_poll or BMF_COMMAND_WORKER_DEFAULT_MAX_FILES_PER_POLL
  for _, file_name in ipairs(request_files) do
    local claimed_file = file_name
    if not state.command_inflight_files[claimed_file] then
      state.command_inflight_files[claimed_file] = true
    else
      claimed_file = nil
    end

    if claimed_file ~= nil then
      run_on_game_thread(function()
        local ok, err = pcall(process_command_request, claimed_file)
        state.command_inflight_files[claimed_file] = nil
        if not ok then
          log("error", "command worker failed for " .. tostring(claimed_file) .. ": " .. tostring(err))
        end
      end)
      scheduled_files = scheduled_files + 1
      if scheduled_files >= max_files then
        break
      end
    end
  end

  return false
end

local function start_command_worker()
  if state.command_worker_started then
    return
  end
  state.command_worker_started = true
  state.command_worker_poll_interval_ms = BMF_command_worker_poll_interval_ms()
  state.command_worker_fallback_poll_interval_ms = BMF_command_worker_fallback_poll_interval_ms()
  state.command_worker_max_files_per_poll = BMF_command_worker_max_files_per_poll()
  state.command_worker_mode = "starting"
  log("info", "command worker started path=" .. COMMAND_DIR)
  if BMF_start_async_loop(
    "command_worker",
    state.command_worker_poll_interval_ms,
    BMF_poll_command_requests_async,
    BMF_env_bool("BMF_COMMAND_WORKER_ASYNC", true)
  ) then
    state.command_worker_mode = "LoopAsync"
    log(
      "info",
      "command worker polling via LoopAsync interval_ms="
        .. tostring(state.command_worker_poll_interval_ms)
        .. " max_files_per_poll="
        .. tostring(state.command_worker_max_files_per_poll)
    )
    return
  end
  if BMF_start_game_thread_loop("command_worker", state.command_worker_fallback_poll_interval_ms, function()
    if not state.command_worker_started then
      return true
    end
    BMF_poll_command_requests_once()
    return false
  end) then
    state.command_worker_mode = "LoopInGameThread"
    log(
      "info",
      "command worker polling via LoopInGameThread interval_ms="
        .. tostring(state.command_worker_fallback_poll_interval_ms)
        .. " max_files_per_poll="
        .. tostring(state.command_worker_max_files_per_poll)
    )
    return
  end
  state.command_worker_mode = "ExecuteInGameThreadWithDelay"
  log(
    "warn",
    "command worker using game-thread delayed fallback interval_ms="
      .. tostring(state.command_worker_fallback_poll_interval_ms)
      .. " max_files_per_poll="
      .. tostring(state.command_worker_max_files_per_poll)
  )
  if not schedule_command_worker_poll(state.command_worker_fallback_poll_interval_ms) then
    state.command_worker_started = false
    state.command_worker_mode = "stopped"
    log("error", "command worker unavailable: no game-thread scheduler available")
  end
end

function BMF_process_socket_message(line)
  local trimmed = trim_string(line)
  if trimmed == "" then
    return
  end

  state.socket.received_messages = state.socket.received_messages + 1
  local decoded, err = json_decode(trimmed)
  if type(decoded) ~= "table" then
    state.socket.last_error = "socket decode failed: " .. tostring(err or "invalid JSON")
    return
  end

  local message_type = tostring(decoded.type or "")
  if message_type == "ping" then
    BMF_socket_send_json({
      type = "pong",
      source = "bmf",
      ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      id = decoded.id,
    })
    return
  end

  if message_type ~= "command" then
    return
  end

  local request_id = trim_string(decoded.id or "")
  local command_text = trim_string(decoded.command or "")
  if request_id == "" or command_text == "" then
    state.socket.last_error = "socket command missing id or command"
    return
  end

  state.socket.received_commands = state.socket.received_commands + 1
  local response, ok, detail = BMF_dispatch_bmf_command_text(request_id, command_text, "socket")
  local sent = BMF_socket_send_json({
    type = "response",
    source = "bmf",
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    id = request_id,
    ok = ok == true,
    detail = tostring(detail or ""),
    response = response,
  })
  if sent then
    state.socket.sent_responses = state.socket.sent_responses + 1
  end
end

function BMF_drain_socket_messages(max_count)
  if not state.socket.started or type(BMFSocketReceive) ~= "function" then
    state.socket_worker_started = false
    return 0
  end

  local drain_started_clock = os.clock()
  local drain_ok = true
  local requested_count = math.max(1, tonumber(max_count) or 64)
  state.socket.poll_count = (tonumber(state.socket.poll_count) or 0) + 1
  state.socket.last_poll_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  local ok, messages_or_error = pcall(BMFSocketReceive, requested_count)
  if ok and type(messages_or_error) == "table" then
    local drained = 0
    for _, line in ipairs(messages_or_error) do
      if trim_string(line) ~= "" then
        drained = drained + 1
        local processed, err = pcall(BMF_process_socket_message, line)
        if not processed then
          drain_ok = false
          state.socket.last_error = "socket message failed: " .. tostring(err)
        end
      end
    end
    state.socket.last_drain_count = drained
    local native_drained = 0
    if state.tools.tree_cut_native and state.tools.tree_cut_native.enabled == true then
      local native_ok, native_result = pcall(BMF.tools.treeCutNative.drain, {
        limit = 64,
        silent = true,
      })
      if native_ok and native_result and native_result.data then
        native_drained = tonumber(native_result.data.drained) or 0
      elseif not native_ok then
        drain_ok = false
        state.tools.tree_cut_native.last_error = "native tree-cut drain failed: " .. tostring(native_result)
      end
    end
    if drained > 0 or native_drained > 0 or not drain_ok then
      BMF_telemetry_record_worker("socket_drains", BMF_telemetry_duration_ms(drain_started_clock), drain_ok, "messages", drained + native_drained)
    end
    return drained + native_drained
  elseif not ok then
    drain_ok = false
    state.socket.last_error = "BMFSocketReceive failed: " .. tostring(messages_or_error)
  end

  state.socket.last_drain_count = 0
  if not drain_ok then
    BMF_telemetry_record_worker("socket_drains", BMF_telemetry_duration_ms(drain_started_clock), drain_ok, "messages", 0)
  end
  return 0
end

function BMF_schedule_socket_worker_poll(delay_ms)
  local delay = tonumber(delay_ms) or state.socket.poll_interval_ms or SOCKET_DEFAULT_POLL_MS
  return BMF_schedule_delayed_callback("socket_worker", delay, function()
    run_on_game_thread(function()
      if BMF_poll_socket_messages then
        BMF_poll_socket_messages()
      end
    end)
  end)
end

function BMF_poll_socket_messages()
  if not state.socket.started or type(BMFSocketReceive) ~= "function" then
    state.socket_worker_started = false
    return
  end

  BMF_drain_socket_messages(64)

  if state.socket_worker_started then
    if not BMF_schedule_socket_worker_poll(state.socket.poll_interval_ms) then
      state.socket_worker_started = false
      log("error", "socket worker stopped: no game-thread scheduler available")
    end
  end
end

function BMF_poll_socket_messages_async()
  if not state.socket_worker_started then
    return true
  end

  if not state.socket.started or type(BMFSocketReceive) ~= "function" then
    state.socket_worker_started = false
    return true
  end

  local ok, messages_or_error = pcall(BMFSocketReceive, 64)
  if ok and type(messages_or_error) == "table" then
    for _, line in ipairs(messages_or_error) do
      if trim_string(line) ~= "" then
        run_on_game_thread(function()
          local processed, err = pcall(BMF_process_socket_message, line)
          if not processed then
            state.socket.last_error = "socket message failed: " .. tostring(err)
          end
        end)
      end
    end
  elseif not ok then
    state.socket.last_error = "BMFSocketReceive failed: " .. tostring(messages_or_error)
  end

  if state.tools.tree_cut_native and state.tools.tree_cut_native.enabled == true then
    run_on_game_thread(function()
      pcall(BMF.tools.treeCutNative.drain, {
        limit = 64,
        silent = true,
      })
    end)
  end

  return false
end

function BMF_start_socket_transport()
  BMF_socket_configure_from_env()
  if not state.socket.enabled then
    return
  end
  if state.socket.started then
    return
  end
  if not state.socket.available then
    state.socket.last_error = "BMFSocket native functions are unavailable"
    log("warn", "socket transport disabled: " .. state.socket.last_error)
    return
  end
  if state.socket.port <= 0 then
    state.socket.last_error = "OMEGGA_BMF_SOCKET_PORT is required"
    log("warn", "socket transport disabled: " .. state.socket.last_error)
    return
  end

  local ok, started_or_error, status = pcall(BMFSocketStart, state.socket.host, state.socket.port, state.socket.token)
  if not ok or started_or_error == false then
    state.socket.last_error = tostring(status or started_or_error or "BMFSocketStart failed")
    log("error", "socket transport failed: " .. state.socket.last_error)
    return
  end

  state.socket.started = true
  state.socket.last_error = ""
  state.socket.last_status = tostring(status or "")
  state.socket.last_started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  state.socket_worker_started = true
  log("info", "socket transport started host=" .. tostring(state.socket.host) .. " port=" .. tostring(state.socket.port) .. " poll_ms=" .. tostring(state.socket.poll_interval_ms))
  if BMF_env_bool("BMF_TREECUT_NATIVE_ENABLED", true) then
    local treecut_ok, treecut_result = pcall(BMF.tools.treeCutNative.start, {
      reason = "socket-start",
    })
    if not treecut_ok or not treecut_result or treecut_result.ok ~= true then
      local detail = treecut_ok and tostring(treecut_result and treecut_result.message or "unknown") or tostring(treecut_result)
      log("warn", "tree-cut native capture did not start: " .. detail)
    end
  end
  if BMF_start_async_loop("socket_worker", state.socket.poll_interval_ms, BMF_poll_socket_messages_async) then
    log("info", "socket worker polling via LoopAsync")
    return
  end
  if BMF_start_game_thread_loop("socket_worker", state.socket.poll_interval_ms, function()
    if not state.socket_worker_started then
      return true
    end
    if not state.socket.started or type(BMFSocketReceive) ~= "function" then
      state.socket_worker_started = false
      return true
    end
    BMF_drain_socket_messages(64)
    return false
  end) then
    log("info", "socket worker polling via LoopInGameThread")
    return
  end
  if not BMF_schedule_socket_worker_poll(state.socket.poll_interval_ms) then
    state.socket_worker_started = false
    log("error", "socket worker unavailable: no game-thread scheduler available")
  end
end

local function sorted_loaded_plugin_names()
  local names = {}
  for name in pairs(state.plugins) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

local function loaded_plugin_with_tick_count()
  local count = 0
  for name, plugin in pairs(state.plugins) do
    if type(plugin) == "table" and type(plugin.onTick) == "function" and not plugin_watchdog_isolated(name) then
      count = count + 1
    end
  end
  return count
end

local function dispatch_server_ready_hooks(data)
  local ready_data = copy_table(data or state.server_ready_data or {})
  for _, name in ipairs(sorted_loaded_plugin_names()) do
    run_plugin_hook(name, state.plugins[name], "onServerReady", ready_data)
  end
end

local function ensure_plugin_tick_worker()
  if state.plugin_tick_timer_id ~= nil then
    return
  end
  if loaded_plugin_with_tick_count() == 0 then
    return
  end

  local timer_id = BMF.timers.every(state.plugin_tick_interval_ms, function(id, count)
    if loaded_plugin_with_tick_count() == 0 then
      state.plugin_tick_timer_id = nil
      BMF.timers.cancel(id)
      write_status()
      return
    end

    state.plugin_tick_count = tonumber(count) or (state.plugin_tick_count + 1)
    local tick_data = {
      tick = state.plugin_tick_count,
      intervalMs = state.plugin_tick_interval_ms,
      serverReady = state.server_ready and true or false,
    }
    for _, name in ipairs(sorted_loaded_plugin_names()) do
      run_plugin_hook(name, state.plugins[name], "onTick", tick_data)
    end
  end)

  if timer_id then
    state.plugin_tick_timer_id = timer_id
    log("info", "plugin tick worker started interval_ms=" .. tostring(state.plugin_tick_interval_ms))
    write_status()
  end
end

local function mark_server_ready(data)
  state.server_ready = true
  state.server_ready_data = copy_table(data or {})
  BMF.events.emit("serverReady", state.server_ready_data)
  dispatch_server_ready_hooks(state.server_ready_data)
  write_status()
end

local function list_plugin_dirs()
  local command = 'dir /b /ad "' .. PLUGINS_DIR:gsub("/", "\\") .. '" 2>nul'
  local handle = io.popen(command)
  if not handle then
    return {}
  end
  local names = {}
  for line in handle:lines() do
    if line and line ~= "" then
      names[#names + 1] = line
    end
  end
  handle:close()
  table.sort(names)
  return names
end

local function parse_json_string_field(raw, field)
  if type(raw) ~= "string" then
    return nil
  end
  local pattern = '"' .. field .. '"%s*:%s*"([^"]*)"'
  return raw:match(pattern)
end

local function parse_json_string_array_field(raw, field)
  if type(raw) ~= "string" then
    return {}
  end
  local body = raw:match('"' .. field .. '"%s*:%s*%[(.-)%]')
  local values = {}
  if not body then
    return values
  end
  for value in body:gmatch('"([^"]*)"') do
    values[#values + 1] = value
  end
  return values
end

local function parse_json_boolean_field(raw, field)
  if type(raw) ~= "string" then
    return nil
  end
  local token = raw:match('"' .. field .. '"%s*:%s*([A-Za-z]+)')
  if not token then
    return nil
  end
  token = token:lower()
  if token == "true" then
    return true
  end
  if token == "false" then
    return false
  end
  return nil
end

local function parse_json_number_field(raw, field)
  if type(raw) ~= "string" then
    return nil
  end
  local token = raw:match('"' .. field .. '"%s*:%s*([%-%.%d]+)')
  if not token then
    return nil
  end
  return tonumber(token)
end

local function read_framework_config()
  local raw = read_file(CONFIG_PATH) or ""
  local jsonl_logs = parse_json_boolean_field(raw, "jsonlLogs")
  if jsonl_logs == nil then
    jsonl_logs = true
  end
  local watchdog_enabled = parse_json_boolean_field(raw, "pluginWatchdogEnabled")
  if watchdog_enabled == nil then
    watchdog_enabled = true
  end
  local watchdog_max_errors = parse_json_number_field(raw, "pluginWatchdogMaxErrors") or 3
  if watchdog_max_errors < 1 then
    watchdog_max_errors = 1
  end
  return {
    path = CONFIG_PATH,
    allowPluginServerExec = parse_json_boolean_field(raw, "allowPluginServerExec") == true,
    allowPluginServerShutdown = parse_json_boolean_field(raw, "allowPluginServerShutdown") == true,
    jsonlLogs = jsonl_logs,
    pluginWatchdogEnabled = watchdog_enabled,
    pluginWatchdogMaxErrors = math.floor(watchdog_max_errors),
    allowPluginUnsafeGlobals = parse_json_boolean_field(raw, "allowPluginUnsafeGlobals") == true,
    allowUnsafeApplicatorLuaHook = parse_json_boolean_field(raw, "allowUnsafeApplicatorLuaHook") == true,
    allowUnsafeMinigameConsoleCommands = parse_json_boolean_field(raw, "allowUnsafeMinigameConsoleCommands") == true,
    allowUnsafeMinigameObjectSnapshot = parse_json_boolean_field(raw, "allowUnsafeMinigameObjectSnapshot") == true,
    brickadiaSavedDir = parse_json_string_field(raw, "brickadiaSavedDir") or "",
  }
end

local function read_plugin_manifest(name)
  local path = PLUGINS_DIR .. "/" .. name .. "/bmf.json"
  local raw = read_file(path)
  if not raw then
    return {
      path = path,
      raw = "",
      capabilities = {},
    }
  end
  return {
    path = path,
    raw = raw,
    name = parse_json_string_field(raw, "name"),
    version = parse_json_string_field(raw, "version"),
    author = parse_json_string_field(raw, "author"),
    description = parse_json_string_field(raw, "description"),
    capabilities = parse_json_string_array_field(raw, "capabilities"),
  }
end

local function has_manifest_capability(manifest, capability)
  local capabilities = {}
  if type(manifest) == "table" and type(manifest.capabilities) == "table" then
    capabilities = manifest.capabilities
  end
  for _, item in ipairs(capabilities) do
    if item == capability or item == "*" then
      return true
    end
    if capability == "server.exec" and item == "server.exec.restricted" then
      return true
    end
  end
  return false
end

local function plugin_can_access_unsafe_global(plugin_name, manifest, key)
  local global_name = tostring(key or "")
  if not UNSAFE_PLUGIN_GLOBALS[global_name] then
    return true
  end
  if state.config.allowPluginUnsafeGlobals == true and has_manifest_capability(manifest, "unsafe.globals") then
    return true
  end

  local denial_key = tostring(plugin_name or "") .. "|" .. global_name
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local denial = state.plugin_unsafe_global_denials[denial_key]
  if type(denial) ~= "table" then
    denial = {
      plugin = tostring(plugin_name or ""),
      global = global_name,
      count = 0,
      firstAt = now,
      lastAt = now,
    }
    state.plugin_unsafe_global_denials[denial_key] = denial
    audit_record("plugin.unsafe_global_denied", {
      plugin = denial.plugin,
      global = global_name,
      requiredCapability = "unsafe.globals",
      config = "allowPluginUnsafeGlobals",
    }, {
      source = "plugin",
      plugin = denial.plugin,
      severity = "warn",
      ok = false,
      code = "UNSAFE_GLOBAL_DENIED",
    })
    log("warn", "plugin " .. denial.plugin .. " denied unsafe global " .. global_name)
  end
  denial.count = (tonumber(denial.count) or 0) + 1
  denial.lastAt = now
  write_status()
  return false
end

local function plugin_global_lookup(plugin_name, manifest, key)
  if not plugin_can_access_unsafe_global(plugin_name, manifest, key) then
    return nil
  end
  return _G[key]
end

local function capability_denied(plugin_name, capability, manifest)
  audit_record("capability.denied", {
    plugin = plugin_name,
    capability = capability,
    declared = copy_table((manifest and manifest.capabilities) or {}),
  }, {
    source = "plugin",
    plugin = plugin_name,
    severity = "warn",
    ok = false,
    code = "CAPABILITY_REQUIRED",
  })
  return result(false, "CAPABILITY_REQUIRED", "Plugin capability is required: " .. tostring(capability), {
    plugin = plugin_name,
    capability = capability,
    declared = copy_table((manifest and manifest.capabilities) or {}),
  })
end

local function config_opt_in_denied(plugin_name, option)
  audit_record("config.opt_in_denied", {
    plugin = plugin_name,
    option = option,
    configPath = CONFIG_PATH,
  }, {
    source = "plugin",
    plugin = plugin_name,
    severity = "warn",
    ok = false,
    code = "CONFIG_OPT_IN_REQUIRED",
  })
  return result(false, "CONFIG_OPT_IN_REQUIRED", "BMF config option is required: " .. tostring(option), {
    plugin = plugin_name,
    option = option,
    configPath = CONFIG_PATH,
  })
end

local function require_capability(plugin_name, manifest, capability, callback)
  if not has_manifest_capability(manifest, capability) then
    return capability_denied(plugin_name, capability, manifest)
  end
  return callback()
end

local function plugin_storage_args(plugin_name, a, b, c)
  if c ~= nil then
    return tostring(a or ""), b, c
  end
  return plugin_name, a, b
end

local function create_plugin_api(plugin_name, manifest)
  local api = {}
  for key, value in pairs(BMF) do
    api[key] = value
  end
  local function run_plugin_action(callback)
    return with_rate_limit_context({
      source = "plugin",
      plugin = plugin_name,
      subject = "plugin:" .. tostring(plugin_name),
    }, callback)
  end
  api.log = function(a, b, c)
    local level, message, data = normalize_log_args("info", a, b, c)
    log_plugin(plugin_name, level, message, data)
  end
  api.logInfo = function(message, data)
    log_plugin(plugin_name, "info", message, data)
  end
  api.logWarn = function(message, data)
    log_plugin(plugin_name, "warn", message, data)
  end
  api.logError = function(message, data)
    log_plugin(plugin_name, "error", message, data)
  end
  api.logger = {
    debug = function(message, data)
      log_plugin(plugin_name, "debug", message, data)
    end,
    info = function(message, data)
      log_plugin(plugin_name, "info", message, data)
    end,
    warn = function(message, data)
      log_plugin(plugin_name, "warn", message, data)
    end,
    error = function(message, data)
      log_plugin(plugin_name, "error", message, data)
    end,
  }

  api.audit = {
    path = AUDIT_LOG_PATH,
    record = function(action, data)
      return audit_record(action, data, {
        source = "plugin",
        plugin = plugin_name,
      })
    end,
    recent = function(limit)
      return BMF.audit.recent(limit)
    end,
  }

  api.rateLimits = {}
  for key, value in pairs(BMF.rateLimits) do
    api.rateLimits[key] = value
  end
  api.rateLimits.check = function(action, options)
    return run_plugin_action(function()
      return BMF.rateLimits.check(action, options)
    end)
  end

  api.events = {}
  for key, value in pairs(BMF.events) do
    api.events[key] = value
  end
  api.events.on = function(name, handler)
    return register_event_handler(name, handler, plugin_name)
  end

  api.commands = {}
  for key, value in pairs(BMF.commands) do
    api.commands[key] = value
  end
  api.commands.register = function(name, description, handler)
    return register_command(name, description, handler, plugin_name)
  end

  api.tools = {}
  for key, value in pairs(BMF.tools) do
    api.tools[key] = value
  end
  api.tools.uobject = {}
  for key, value in pairs(BMF.tools.uobject) do
    api.tools.uobject[key] = value
  end
  api.tools.applicator = {}
  for key, value in pairs(BMF.tools.applicator) do
    api.tools.applicator[key] = value
  end
  api.tools.treeCutNative = {}
  for key, value in pairs(BMF.tools.treeCutNative) do
    api.tools.treeCutNative[key] = value
  end
  api.tools.treeCutTrace = {}
  for key, value in pairs(BMF.tools.treeCutTrace) do
    api.tools.treeCutTrace[key] = value
  end
  api.tools.treeCutProbe = {}
  for key, value in pairs(BMF.tools.treeCutProbe) do
    api.tools.treeCutProbe[key] = value
  end
  api.tools.onApplicatorComponentApply = function(handler, options)
    return require_capability(plugin_name, manifest, "tools.applicator", function()
      local opts = type(options) == "table" and copy_table(options) or {}
      opts.owner = plugin_name
      return BMF.tools.onApplicatorComponentApply(handler, opts)
    end)
  end

  api.server = {}
  for key, value in pairs(BMF.server) do
    api.server[key] = value
  end
  api.server.exec = function(command)
    return require_capability(plugin_name, manifest, "server.exec", function()
      if not state.config.allowPluginServerExec then
        return config_opt_in_denied(plugin_name, "allowPluginServerExec")
      end
      return run_plugin_action(function()
        return BMF.server.exec(command)
      end)
    end)
  end
  api.server.save = function(options)
    return require_capability(plugin_name, manifest, "server.save", function()
      return run_plugin_action(function()
        return BMF.server.save(options)
      end)
    end)
  end
  api.server.shutdown = function(options)
    return require_capability(plugin_name, manifest, "server.shutdown", function()
      if not state.config.allowPluginServerShutdown then
        return config_opt_in_denied(plugin_name, "allowPluginServerShutdown")
      end
      return run_plugin_action(function()
        return BMF.server.shutdown(options)
      end)
    end)
  end

  api.chat = {}
  for key, value in pairs(BMF.chat) do
    api.chat[key] = value
  end
  api.chat.broadcast = function(message)
    return require_capability(plugin_name, manifest, "chat.broadcast", function()
      return run_plugin_action(function()
        return BMF.chat.broadcast(message)
      end)
    end)
  end
  api.chat.whisper = function(player, message)
    return require_capability(plugin_name, manifest, "chat.whisper", function()
      return run_plugin_action(function()
        return BMF.chat.whisper(player, message)
      end)
    end)
  end
  api.chat.statusMessage = function(player, message)
    return require_capability(plugin_name, manifest, "chat.statusMessage", function()
      return run_plugin_action(function()
        return BMF.chat.statusMessage(player, message)
      end)
    end)
  end

  api.players = {}
  for key, value in pairs(BMF.players) do
    api.players[key] = value
  end

  api.world = {}
  for key, value in pairs(BMF.world) do
    api.world[key] = value
  end
  api.world.loadAdditive = function(options)
    return require_capability(plugin_name, manifest, "world.loadAdditive", function()
      return run_plugin_action(function()
        return BMF.world.loadAdditive(options)
      end)
    end)
  end
  api.world.saveAs = function(name)
    return require_capability(plugin_name, manifest, "world.saveAs", function()
      return run_plugin_action(function()
        return BMF.world.saveAs(name)
      end)
    end)
  end

  api.bricks = {}
  for key, value in pairs(BMF.bricks) do
    api.bricks[key] = value
  end
  api.bricks.setRuntimeState = function(options)
    return require_capability(plugin_name, manifest, "bricks.runtimeState", function()
      return run_plugin_action(function()
        return BMF.bricks.setRuntimeState(options)
      end)
    end)
  end

  api.prefabs = {}
  for key, value in pairs(BMF.prefabs) do
    api.prefabs[key] = value
  end
  api.prefabs.loadBrdb = function(options)
    return require_capability(plugin_name, manifest, "prefabs.loadBrdb", function()
      return run_plugin_action(function()
        return BMF.prefabs.loadBrdb(options)
      end)
    end)
  end
  api.prefabs.loadBrz = function(options)
    return require_capability(plugin_name, manifest, "prefabs.loadBrz", function()
      return run_plugin_action(function()
        return BMF.prefabs.loadBrz(options)
      end)
    end)
  end

  api.vehicles = {}
  for key, value in pairs(BMF.vehicles) do
    api.vehicles[key] = value
  end
  api.vehicles.spawnSet = function(options)
    return require_capability(plugin_name, manifest, "vehicles.spawnSet", function()
      return run_plugin_action(function()
        return BMF.vehicles.spawnSet(options)
      end)
    end)
  end

  api.storage = {}
  for key, value in pairs(BMF.storage) do
    api.storage[key] = value
  end
  api.storage.readText = function(a, b)
    local scoped_plugin = plugin_name
    local relative = a
    if b ~= nil then
      scoped_plugin = tostring(a or "")
      relative = b
    end
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.readText(scoped_plugin, relative)
    end)
  end
  api.storage.writeText = function(a, b, c)
    local scoped_plugin, relative, text = plugin_storage_args(plugin_name, a, b, c)
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.writeText(scoped_plugin, relative, text)
    end)
  end
  api.storage.readJson = function(a, b)
    local scoped_plugin = plugin_name
    local relative = a
    if b ~= nil then
      scoped_plugin = tostring(a or "")
      relative = b
    end
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.readJson(scoped_plugin, relative)
    end)
  end
  api.storage.writeJson = function(a, b, c)
    local scoped_plugin, relative, value = plugin_storage_args(plugin_name, a, b, c)
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.writeJson(scoped_plugin, relative, value)
    end)
  end
  api.storage.appendText = function(a, b, c)
    local scoped_plugin, relative, text = plugin_storage_args(plugin_name, a, b, c)
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.appendText(scoped_plugin, relative, text)
    end)
  end
  api.storage.readConfigText = function(a)
    local scoped_plugin = a or plugin_name
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.readConfigText(scoped_plugin)
    end)
  end
  api.storage.writeConfigText = function(a, b)
    local scoped_plugin = plugin_name
    local text = a
    if b ~= nil then
      scoped_plugin = tostring(a or "")
      text = b
    end
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.writeConfigText(scoped_plugin, text)
    end)
  end
  api.storage.readConfig = function(a)
    local scoped_plugin = a or plugin_name
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.readConfig(scoped_plugin)
    end)
  end
  api.storage.writeConfig = function(a, b)
    local scoped_plugin = plugin_name
    local value = a
    if b ~= nil then
      scoped_plugin = tostring(a or "")
      value = b
    end
    if scoped_plugin ~= plugin_name then
      return capability_denied(plugin_name, "plugins.storage", manifest)
    end
    return require_capability(plugin_name, manifest, "plugins.storage", function()
      return BMF.storage.writeConfig(scoped_plugin, value)
    end)
  end

  api.capabilities = {
    has = function(capability)
      return has_manifest_capability(manifest, capability)
    end,
    require = function(capability)
      if has_manifest_capability(manifest, capability) then
        return result(true, "OK", "Capability is declared", {
          plugin = plugin_name,
          capability = capability,
        })
      end
      return capability_denied(plugin_name, capability, manifest)
    end,
    list = function()
      return result(true, "OK", "Capabilities listed", {
        plugin = plugin_name,
        capabilities = copy_table((manifest and manifest.capabilities) or {}),
      })
    end,
  }

  return api
end

local function unload_plugin(name, plugin, reason)
  if type(plugin) == "table" and type(plugin.onUnload) == "function" then
    local api = plugin.bmf_api or BMF
    local ok, err = pcall(plugin.onUnload, api, reason or "unload")
    if not ok then
      record_plugin_error(name, "onUnload", err, { reason = reason or "unload" }, plugin)
      remove_event_handlers_for_owner(name)
      remove_commands_for_owner(name)
      remove_tool_handlers_for_owner(name)
      return false, err
    end
  end
  BMF.events.emit("pluginUnloaded", {
    name = name,
    reason = reason or "unload",
  })
  local removed_handlers = remove_event_handlers_for_owner(name)
  local removed_commands = remove_commands_for_owner(name)
  local removed_tool_handlers = remove_tool_handlers_for_owner(name)
  audit_record("plugin.unloaded", {
    plugin = name,
    reason = reason or "unload",
    eventHandlersRemoved = removed_handlers,
    commandsRemoved = removed_commands,
    toolHandlersRemoved = removed_tool_handlers,
  }, {
    source = "framework",
    plugin = name,
    severity = "info",
    ok = true,
    code = "OK",
  })
  log(
    "info",
    "unloaded plugin " .. name ..
      " event_handlers_removed=" .. tostring(removed_handlers) ..
      " commands_removed=" .. tostring(removed_commands) ..
      " tool_handlers_removed=" .. tostring(removed_tool_handlers)
  )
  return true, nil
end

local function load_plugin(name)
  local plugin_path = PLUGINS_DIR .. "/" .. name .. "/main.lua"
  local manifest = read_plugin_manifest(name)
  local plugin_api = create_plugin_api(name, manifest)
  state.plugin_watchdog[name] = nil
  plugin_watchdog_state(name)
  local plugin_env = {
    BMF = plugin_api,
    print = print,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    pairs = pairs,
    ipairs = ipairs,
    pcall = pcall,
    string = string,
    table = table,
    math = math,
    os = os,
  }
  plugin_env._G = plugin_env
  setmetatable(plugin_env, {
    __index = function(_, key)
      return plugin_global_lookup(name, manifest, key)
    end,
  })

  local chunk, load_error = loadfile(plugin_path, "t", plugin_env)
  if not chunk then
    return false, load_error
  end

  local ok, plugin_or_error = pcall(chunk)
  if not ok then
    return false, plugin_or_error
  end

  local plugin = plugin_or_error
  if type(plugin) ~= "table" then
    plugin = plugin_env.Plugin or {}
  end
  plugin.name = plugin.name or manifest.name or name
  plugin.manifest = manifest
  plugin.path = PLUGINS_DIR .. "/" .. name
  plugin.bmf_api = plugin_api

  local load_ok, load_error = run_plugin_hook(name, plugin, "onLoad", {
    reason = "load",
    serverReady = state.server_ready and true or false,
  })
  if not load_ok then
    return false, {
      error = tostring(load_error),
      hook = "onLoad",
      recorded = true,
    }
  end

  state.plugins[name] = plugin
  audit_record("plugin.loaded", {
    plugin = name,
    version = manifest.version or "",
    capabilities = copy_table(manifest.capabilities or {}),
  }, {
    source = "framework",
    plugin = name,
    severity = "info",
    ok = true,
    code = "OK",
  })
  BMF.events.emit("pluginLoaded", {
    name = name,
    version = manifest.version or "",
  })

  return true, plugin
end

function BMF.unloadPlugins(reason)
  local names = {}
  for name in pairs(state.plugins) do
    names[#names + 1] = name
  end
  table.sort(names)

  local unloaded = 0
  local unload_errors = 0
  for _, name in ipairs(names) do
    local ok = unload_plugin(name, state.plugins[name], reason or "unload")
    if ok then
      unloaded = unloaded + 1
    else
      unload_errors = unload_errors + 1
    end
  end
  state.plugins = {}
  write_status()
  return result(true, "OK", "Plugins unloaded", {
    plugins_unloaded = unloaded,
    unload_errors = unload_errors,
  })
end

function BMF.loadPlugins()
  for _, name in ipairs(list_plugin_dirs()) do
    local ok, value = load_plugin(name)
    if ok then
      log("info", "loaded plugin " .. name)
    else
      local error_text = tostring(value)
      if type(value) == "table" then
        error_text = tostring(value.error or value.message or value)
      end
      if type(value) ~= "table" or value.recorded ~= true then
        state.plugin_errors[#state.plugin_errors + 1] = { name = name, error = error_text }
      end
      log("error", "failed to load plugin " .. name .. ": " .. error_text)
    end
  end
  if state.server_ready then
    dispatch_server_ready_hooks(state.server_ready_data)
  end
  ensure_plugin_tick_worker()
  write_status()
  return BMF.health()
end

_G.BMF = BMF

state.config = read_framework_config()
register_builtin_commands()
log("info", "BMF loaded version=" .. VERSION)
audit_record("framework.loaded", {
  version = VERSION,
  commandsRegistered = #command_names(),
}, {
  source = "framework",
  severity = "info",
  ok = true,
  code = "OK",
})
write_status()
BMF.loadPlugins()
BMF_start_socket_transport()
start_command_worker()
mark_server_ready({
  version = VERSION,
  pluginsLoaded = plugin_count(),
  commandsRegistered = #command_names(),
})
BMF_telemetry_write(true)
