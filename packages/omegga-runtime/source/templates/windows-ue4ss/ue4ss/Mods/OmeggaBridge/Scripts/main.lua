local MOD_NAME = "OmeggaBridge"
local BRIDGE_DIR = os.getenv("OMEGGA_UE4SS_BRIDGE_DIR") or ("Mods/" .. MOD_NAME .. "/runtime")
local INBOX_PATH = os.getenv("OMEGGA_UE4SS_INBOX") or (BRIDGE_DIR .. "/inbox.ndjson")
local OUTBOX_PATH = os.getenv("OMEGGA_UE4SS_OUTBOX") or (BRIDGE_DIR .. "/outbox.ndjson")
local STATUS_PATH = os.getenv("OMEGGA_UE4SS_STATUS") or (BRIDGE_DIR .. "/status.json")
local TRACE_PATH = os.getenv("OMEGGA_UE4SS_TRACE") or (BRIDGE_DIR .. "/bridge.log")
local CHAT_TRACE_PATH = os.getenv("OMEGGA_UE4SS_CHAT_TRACE_PATH") or (BRIDGE_DIR .. "/chat-trace.log")
PREFAB_CAPTURE_PATH = os.getenv("OMEGGA_UE4SS_PREFAB_CAPTURE_PATH") or (BRIDGE_DIR .. "/prefab-native-captures.ndjson")
PREFAB_CAPTURE_LATEST_PATH = os.getenv("OMEGGA_UE4SS_PREFAB_CAPTURE_LATEST_PATH") or (BRIDGE_DIR .. "/prefab-native-last.txt")
NATIVE_PREFAB_COMMAND_PATH = os.getenv("OMEGGA_NATIVE_PREFAB_COMMAND_PATH") or "C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\placeprefab-native-hook-outer-command.txt"
NATIVE_PREFAB_STATUS_PATH = os.getenv("OMEGGA_NATIVE_PREFAB_STATUS_PATH") or "C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\placeprefab-native-hook-outer-status.txt"
local SESSION = os.getenv("OMEGGA_UE4SS_SESSION") or ""
local TOKEN = os.getenv("OMEGGA_UE4SS_TOKEN") or ""
local TRANSPORT = os.getenv("OMEGGA_UE4SS_TRANSPORT") or "file"
local PIPE_NAME = os.getenv("OMEGGA_UE4SS_PIPE") or ""

local CONTEXT_CANDIDATES = {
    "GameModeBase",
    "GameMode",
    "GameStateBase",
    "GameState",
    "World",
    "GameEngine",
    "Engine",
    "PlayerController",
    "LocalPlayer"
}

local GAME_THREAD_HOOK_CANDIDATES = {
    "/Script/Engine.GameModeBase:InitGameState",
    "/Script/Engine.GameModeBase:StartPlay",
    "/Script/Engine.Actor:BeginPlay",
    "/Script/Engine.Actor:ReceiveBeginPlay",
}

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
if type(OMEGGA_BRIDGE_STOP_POLLER) == "function" then
    pcall(OMEGGA_BRIDGE_STOP_POLLER, "replacement")
end
OMEGGA_BRIDGE_LOOP_STATE = type(OMEGGA_BRIDGE_LOOP_STATE) == "table" and OMEGGA_BRIDGE_LOOP_STATE or {}
OMEGGA_BRIDGE_LOOP_STATE.active = OMEGGA_BRIDGE_LOOP_STATE.active == true
OMEGGA_BRIDGE_LOOP_STATE.generation = tonumber(OMEGGA_BRIDGE_LOOP_STATE.generation) or 0
OMEGGA_BRIDGE_LOOP_STATE.starts_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.starts_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.stops_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.stops_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.cancel_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.cancel_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.cancel_error_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.cancel_error_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.callback_error_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.callback_error_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.thread_violation_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.thread_violation_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.thread_check_unavailable_total =
    tonumber(OMEGGA_BRIDGE_LOOP_STATE.thread_check_unavailable_total) or 0
OMEGGA_BRIDGE_LOOP_STATE.polls_total = tonumber(OMEGGA_BRIDGE_LOOP_STATE.polls_total) or 0
OMEGGA_BRIDGE_SCHEDULER_MODE = "game_thread_only"
OMEGGA_BRIDGE_INBOX_SCHEDULER = "unavailable"
OMEGGA_BRIDGE_MAX_INBOX_MESSAGES_PER_TICK = 1
local inbox_offset = 0
local pending_console_execs = {}
local queue_hook_path = nil
local queue_hook_pre_id = nil
local queue_hook_post_id = nil
local queue_hook_fired = false
local is_draining_console_execs = false
local queue_hook_attempted = false
local status_snapshot_logged = false
local DEBUG_STATUS_SNAPSHOT = os.getenv("OMEGGA_UE4SS_DEBUG_STATUS_SNAPSHOT") == "1"
local DEBUG_SCHEDULER = os.getenv("OMEGGA_UE4SS_DEBUG_SCHEDULER") == "1"
local ALLOW_UNSAFE_PROBES = os.getenv("OMEGGA_UE4SS_UNSAFE_PROBES") == "1"
ALLOW_PREFAB_PASTE =
    ALLOW_UNSAFE_PROBES or os.getenv("OMEGGA_UE4SS_PREFAB_PASTE") == "1"
local CHAT_TRACE_ENABLED = os.getenv("OMEGGA_UE4SS_CHAT_TRACE") == "1"
local DEBUG_BRIDGE_HOOKS = true
local ENABLE_CHAT_DISCOVERY_HOOKS = os.getenv("OMEGGA_UE4SS_ENABLE_CHAT_DISCOVERY_HOOKS") == "1"
local ENABLE_REFLECTION_CHAT_DISCOVERY = os.getenv("OMEGGA_UE4SS_ENABLE_REFLECTION_CHAT_DISCOVERY") == "1"
local PREFER_TYPED_CHAT_BROADCAST = os.getenv("OMEGGA_UE4SS_PREFER_TYPED_CHAT_BROADCAST") == "1"
local PREFAB_DUMP_CALL_LOCATION_UFUNCTIONS = os.getenv("OMEGGA_UE4SS_PREFAB_DUMP_CALL_LOCATION_UFUNCTIONS") == "1"
-- Keep new top-level flags global; this chunk is at UE4SS Lua's local-variable limit.
PREFAB_DUMP_READ_OBJECT_PROPERTIES = os.getenv("OMEGGA_UE4SS_PREFAB_DUMP_READ_OBJECT_PROPERTIES") == "1"

local STATUS_PROPERTY_HINTS = {
    "server",
    "name",
    "desc",
    "player",
    "ping",
    "role",
    "time",
    "brick",
    "component",
    "session",
    "owner",
    "address",
    "id",
    "unique"
}

local CHAT_FUNCTION_HINTS = {
    "chat",
    "broadcast",
    "pushchatmessage",
    "chatcommand",
    "processchatmessage",
    "whisper",
    "statusmessage",
}

local CHAT_PROPERTY_HINTS = {
    "chat",
    "message",
    "command",
    "session",
    "worldsubsystem",
    "subsystem",
}

local CHAT_CANDIDATE_FUNCTIONS = {
    "ServerPushChatMessage",
    "PushChatMessage",
    "MulticastPushChatMessage",
    "MulticastPushChatMessageText",
    "ClientPushChatMessage",
    "ClientPushPlayerChatMessage",
    "PushStatusMessage",
    "CallChatCommand",
    "CallChatCommandWithArgs",
    "HandlePlayerChatMessage",
    "ProcessChatMessage",
}

local CHAT_FAST_SOURCE_NAMES = {
    "ChatCommandWorldSubsystem",
    "BRChatCommandWorldSubsystem",
    "BP_ChatCommandWorldSubsystem_C",
    "ChatWorldSubsystem",
    "ChatSubsystem",
    "BRChatSubsystem",
    "ChatManager",
}

local CHAT_FAST_FUNCTION_NAMES = {
    "PushChatMessage",
    "ServerPushChatMessage",
    "MulticastPushChatMessage",
    "MulticastPushChatMessageText",
    "CallChatCommandWithArgs",
    "CallChatCommand",
    "ClientPushChatMessage",
    "ClientPushPlayerChatMessage",
}

local STATUS_SNAPSHOT_CANDIDATE_PROPERTIES = {
    "ServerName",
    "SessionName",
    "Description",
    "ServerDescription",
    "NumBricks",
    "BrickCount",
    "NumComponents",
    "ComponentCount",
    "TimeSeconds",
    "RealTimeSeconds",
    "PlayerNum",
    "UserName",
    "PlayerNamePrivate",
    "PlayerName",
    "SavedNetworkAddress",
    "ExactPing",
    "CompressedPing",
    "Ping",
    "UniqueId",
    "SessionId",
    "PlayerId",
    "StartTime",
    "Owner",
}

local SYNTHETIC_STATE_BASE = 2147483000
local SYNTHETIC_CONTROLLER_BASE = 2147484000
local SYNTHETIC_PATH_PREFIX = "Omegga:PersistentLevel."
local last_hook_context = nil
local last_hook_world = nil
local last_hook_executor = nil
local last_hook_game_mode = nil
local last_hook_game_state = nil
local last_hook_game_session = nil
local last_hook_command = ""
local last_hook_source = ""
local retained_callbacks = {}
local retained_once_callback_order = {}
local retained_once_callback_limit = 65536
local retained_callback_serial = 0
local chat_trace_sequence = 0
local chat_hook_poll_counter = 0
local chat_hook_attempts = {}
local chat_logged_candidates = {}
local observed_chat_function_name = nil
local observed_chat_function_path = nil
local observed_chat_context = nil
local observed_chat_source = nil
local call_by_name_helper_available = nil
CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET = CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET or {}
CHAT_WHISPER_LAST_PLAYER_SOURCE = CHAT_WHISPER_LAST_PLAYER_SOURCE or nil
CHAT_WHISPER_LAST_TARGET_KEY = CHAT_WHISPER_LAST_TARGET_KEY or ""
local call_by_name_helper_error = nil

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, value)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    file:write(value)
    file:close()
    return true
end

local function append_file(path, value)
    local file = io.open(path, "a")
    if not file then
        return false
    end

    file:write(value)
    file:close()
    return true
end

local function retain_callback(key, callback)
    retained_callbacks[tostring(key or "")] = callback
    return callback
end

local function release_callback(key)
    retained_callbacks[tostring(key or "")] = nil
end

local function retain_once_callback(prefix, callback)
    retained_callback_serial = retained_callback_serial + 1
    local key = tostring(prefix or "callback") .. ":" .. tostring(retained_callback_serial)
    retained_once_callback_order[#retained_once_callback_order + 1] = key
    while #retained_once_callback_order > retained_once_callback_limit do
        release_callback(table.remove(retained_once_callback_order, 1))
    end

    local wrapped
    local fired = false
    wrapped = retain_callback(key, function(...)
        if fired then
            return
        end

        fired = true
        release_callback(key)
        local once_callback = callback
        callback = nil
        local results = table.pack(pcall(once_callback, ...))

        if not results[1] then
            error(results[2])
        end

        return table.unpack(results, 2, results.n)
    end)
    return wrapped, key
end

local function now_utc()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function json_escape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub("\"", "\\\"")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\n", "\\n")
    value = value:gsub("\t", "\\t")
    return value
end

local function json_object(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function json_string_field(key, value)
    return string.format("\"%s\":\"%s\"", key, json_escape(value))
end

local function json_bool_field(key, value)
    return string.format("\"%s\":%s", key, value and "true" or "false")
end

local function base64_encode(data)
    return ((data:gsub(".", function(char)
        local byte = char:byte()
        local bits = ""
        for bit = 8, 1, -1 do
            bits = bits .. ((byte % 2 ^ bit - byte % 2 ^ (bit - 1) > 0) and "1" or "0")
        end
        return bits
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
        if #bits < 6 then
            return ""
        end

        local value = 0
        for bit = 1, 6 do
            value = value + ((bits:sub(bit, bit) == "1") and 2 ^ (6 - bit) or 0)
        end
        return BASE64_ALPHABET:sub(value + 1, value + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local function base64_decode(data)
    data = data:gsub("[^" .. BASE64_ALPHABET .. "=]", "")
    local output = {}

    for index = 1, #data, 4 do
        local c1 = data:sub(index, index)
        local c2 = data:sub(index + 1, index + 1)
        local c3 = data:sub(index + 2, index + 2)
        local c4 = data:sub(index + 3, index + 3)

        if c1 == "" or c2 == "" then
            break
        end

        local v1 = (BASE64_ALPHABET:find(c1, 1, true) or 1) - 1
        local v2 = (BASE64_ALPHABET:find(c2, 1, true) or 1) - 1
        local v3 = c3 == "=" and 0 or ((BASE64_ALPHABET:find(c3, 1, true) or 1) - 1)
        local v4 = c4 == "=" and 0 or ((BASE64_ALPHABET:find(c4, 1, true) or 1) - 1)

        local combined = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
        local b1 = math.floor(combined / 65536) % 256
        local b2 = math.floor(combined / 256) % 256
        local b3 = combined % 256

        table.insert(output, string.char(b1))
        if c3 ~= "=" and c3 ~= "" then
            table.insert(output, string.char(b2))
        end
        if c4 ~= "=" and c4 ~= "" then
            table.insert(output, string.char(b3))
        end
    end

    return table.concat(output)
end

local function set_status(state, extra)
    extra = extra or {}
    local parts = {
        json_string_field("state", state),
        json_string_field("updated_at", now_utc()),
        json_string_field("session", SESSION),
        json_string_field("transport", TRANSPORT),
        json_string_field("pipe", PIPE_NAME),
        json_string_field("scheduler_mode", OMEGGA_BRIDGE_SCHEDULER_MODE),
        json_string_field("inbox_scheduler", OMEGGA_BRIDGE_INBOX_SCHEDULER),
        json_bool_field("inbox_loop_active", OMEGGA_BRIDGE_LOOP_STATE.active == true),
        json_bool_field(
            "inbox_loop_handle_owned",
            OMEGGA_BRIDGE_LOOP_STATE.handle == nil
                or OMEGGA_BRIDGE_LOOP_STATE.handle_owner == "omegga_bridge_inbox"
        ),
        string.format("\"inbox_loop_generation\":%d", tonumber(OMEGGA_BRIDGE_LOOP_STATE.generation) or 0),
        string.format("\"inbox_loop_starts_total\":%d", tonumber(OMEGGA_BRIDGE_LOOP_STATE.starts_total) or 0),
        string.format("\"inbox_loop_stops_total\":%d", tonumber(OMEGGA_BRIDGE_LOOP_STATE.stops_total) or 0),
        string.format("\"inbox_loop_cancel_total\":%d", tonumber(OMEGGA_BRIDGE_LOOP_STATE.cancel_total) or 0),
        string.format(
            "\"inbox_loop_cancel_error_total\":%d",
            tonumber(OMEGGA_BRIDGE_LOOP_STATE.cancel_error_total) or 0
        ),
        string.format(
            "\"inbox_loop_callback_error_total\":%d",
            tonumber(OMEGGA_BRIDGE_LOOP_STATE.callback_error_total) or 0
        ),
        string.format(
            "\"inbox_loop_thread_violation_total\":%d",
            tonumber(OMEGGA_BRIDGE_LOOP_STATE.thread_violation_total) or 0
        ),
        string.format(
            "\"inbox_loop_thread_check_unavailable_total\":%d",
            tonumber(OMEGGA_BRIDGE_LOOP_STATE.thread_check_unavailable_total) or 0
        ),
        string.format("\"inbox_loop_polls_total\":%d", tonumber(OMEGGA_BRIDGE_LOOP_STATE.polls_total) or 0),
        json_string_field("inbox_loop_stop_api", "OMEGGA_BRIDGE_STOP_POLLER"),
        string.format(
            "\"inbox_max_messages_per_tick\":%d",
            OMEGGA_BRIDGE_MAX_INBOX_MESSAGES_PER_TICK
        ),
        string.format("\"inbox_poll_interval_ms\":%d", 100),
    }

    for key, value in pairs(extra) do
        if type(value) == "boolean" then
            table.insert(parts, json_bool_field(key, value))
        else
            table.insert(parts, json_string_field(key, value))
        end
    end

    write_file(STATUS_PATH, json_object(parts))
end

local function trace(message)
    append_file(TRACE_PATH, string.format("%s %s\n", now_utc(), message))
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function chat_trace(message)
    if not CHAT_TRACE_ENABLED then
        return
    end

    chat_trace_sequence = chat_trace_sequence + 1
    append_file(
        CHAT_TRACE_PATH,
        string.format("%s [%04d] %s\n", now_utc(), chat_trace_sequence, tostring(message))
    )
end

local function send_notification(method, params)
    append_file(
        OUTBOX_PATH,
        json_object({
            json_string_field("jsonrpc", "2.0"),
            json_string_field("method", method),
            string.format("\"params\":%s", params),
        }) .. "\n"
    )
end

local function send_response(id, payload, is_error)
    local key = is_error and "error" or "result"
    append_file(
        OUTBOX_PATH,
        json_object({
            json_string_field("jsonrpc", "2.0"),
            string.format("\"id\":%d", id),
            string.format("\"%s\":%s", key, payload),
        }) .. "\n"
    )
end

local function bridge_log(level, message)
    trace(message)
    send_notification(
        "bridge.log",
        json_object({
            json_string_field("level", level),
            json_string_field("message", message),
            json_string_field("updated_at", now_utc()),
        })
    )
end

function OMEGGA_BRIDGE_STOP_POLLER(reason)
    local loop_state = OMEGGA_BRIDGE_LOOP_STATE
    if type(loop_state) ~= "table" then
        return false
    end

    local action_handle = loop_state.handle
    local release = loop_state.release_callback
    local was_active = loop_state.active == true
    local owns_handle = loop_state.handle_owner == "omegga_bridge_inbox"
    local cleaned = action_handle == nil
    loop_state.active = false
    loop_state.generation = (tonumber(loop_state.generation) or 0) + 1
    loop_state.stop_reason = tostring(reason or "shutdown")

    if type(action_handle) == "number" and owns_handle then
        if type(CancelDelayedAction) == "function" then
            local cancel_ok, cancel_result = pcall(CancelDelayedAction, action_handle)
            cleaned = cancel_ok and cancel_result == true
        else
            cleaned = false
        end

        if cleaned then
            loop_state.cancel_total = (tonumber(loop_state.cancel_total) or 0) + 1
        else
            loop_state.cancel_error_total = (tonumber(loop_state.cancel_error_total) or 0) + 1
        end
    elseif action_handle ~= nil then
        cleaned = false
        loop_state.cancel_error_total = (tonumber(loop_state.cancel_error_total) or 0) + 1
    end

    if cleaned then
        loop_state.handle = nil
        loop_state.handle_owner = nil
        loop_state.release_callback = nil
        if type(release) == "function" then
            pcall(release)
        end
    end

    if was_active or action_handle ~= nil then
        loop_state.stops_total = (tonumber(loop_state.stops_total) or 0) + 1
        bridge_log(
            cleaned and "info" or "error",
            "Inbox poller stop reason="
                .. loop_state.stop_reason
                .. " cancelled="
                .. tostring(cleaned)
                .. " owned_handle="
                .. tostring(owns_handle)
        )
    end

    return cleaned
end

local function send_console_chunks(id, command, output)
    local chunk_count = 0
    if not output or output == "" then
        return chunk_count
    end

    for line in tostring(output):gmatch("[^\r\n]+") do
        if line ~= "" then
            chunk_count = chunk_count + 1
            send_notification(
                "console.chunk",
                json_object({
                    string.format("\"request_id\":%d", id),
                    string.format("\"chunk_index\":%d", chunk_count),
                    json_string_field("command_b64", base64_encode(command)),
                    json_string_field("line_b64", base64_encode(line)),
                })
            )
        end
    end

    return chunk_count
end

local function send_hello()
    send_notification(
        "bridge.hello",
        json_object({
            json_string_field("session", SESSION),
            json_string_field("token", TOKEN),
            json_string_field("transport", TRANSPORT),
            json_string_field("protocol_version", "1"),
            json_string_field("mod_name", MOD_NAME),
        })
    )
    send_notification(
        "bridge.capabilities",
        json_object({
            json_bool_field("chat_broadcast", true),
            json_bool_field("chat_broadcast_native", false),
            json_bool_field("chat_whisper", true),
            json_bool_field("chat_whisper_native", false),
            json_bool_field("chat_status_message", true),
            json_bool_field("chat_status_message_native", false),
            json_bool_field("console_exec", true),
            json_bool_field("console_chunks", true),
            json_bool_field("players_list", true),
            json_bool_field("players_list_native", false),
            json_bool_field("server_status", true),
            json_bool_field("server_status_native", false),
            json_bool_field("future_brickadia_namespace", true),
            json_string_field("transport", TRANSPORT),
        })
    )
end

local function parse_message(line)
    local params = line:match("\"params\":(%b{})") or ""
    return {
        id = tonumber(line:match("\"id\":(%d+)") or ""),
        method = line:match("\"method\":\"([^\"]+)\""),
        nonce = params:match("\"nonce\":\"([^\"]+)\"") or line:match("\"nonce\":\"([^\"]+)\""),
        command_b64 = params:match("\"command_b64\":\"([^\"]*)\"") or line:match("\"command_b64\":\"([^\"]*)\""),
        command_raw = params:match("\"command\":\"([^\"]*)\"") or line:match("\"command\":\"([^\"]*)\""),
        target_b64 = params:match("\"target_b64\":\"([^\"]*)\"") or line:match("\"target_b64\":\"([^\"]*)\""),
        message_b64 = params:match("\"message_b64\":\"([^\"]*)\"") or line:match("\"message_b64\":\"([^\"]*)\""),
        state_name_b64 = params:match("\"state_name_b64\":\"([^\"]*)\"")
            or line:match("\"state_name_b64\":\"([^\"]*)\""),
        format = params:match("\"format\":\"([^\"]+)\"") or line:match("\"format\":\"([^\"]+)\""),
    }
end

local function find_first_valid(name)
    local ok, object = pcall(function()
        return FindFirstOf(name)
    end)

    if not ok or not object or not object.IsValid or not object:IsValid() then
        return nil
    end

    return object
end

local function find_command_context()
    for _, name in ipairs(CONTEXT_CANDIDATES) do
        local object = find_first_valid(name)
        if object then
            return object
        end
    end

    return nil
end

local function schedule_on_game_thread(callback)
    local wrapped_callback = callback

    if type(ExecuteInGameThread) == "function"
        and type(EGameThreadMethod) == "table"
        and EGameThreadMethod.EngineTick ~= nil then
        bridge_log("info", "Scheduling callback via ExecuteInGameThread EngineTick")
        wrapped_callback = select(1, retain_once_callback("schedule_on_game_thread_engine_tick", callback))
        ExecuteInGameThread(wrapped_callback, EGameThreadMethod.EngineTick)
        return true
    end

    error("No supported UE4SS EngineTick scheduler is available")
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function should_use_kismet_fallback(command)
    local normalized = trim(command)
    if normalized == "" then
        return false
    end

    if normalized:match("^Chat%.") then
        return false
    end

    if normalized:match("^ServerTravel") or normalized:match("^Server%.") then
        return false
    end

    if normalized:match("^Bricks%.") or normalized:match("^BR%.") then
        return false
    end

    return true
end

local function should_trace_console_command(command)
    local normalized = trim(command)
    if normalized == "" then
        return false
    end

    return normalized == "Server.Status"
        or normalized == "Omegga.Bridge.Echo"
        or normalized:match("^Omegga%.Bridge%.ProbeConsoleExec")
        or normalized:match("^Chat%.")
        or normalized:match("^ServerTravel")
        or normalized:match("^Server%.")
        or normalized:match("^BR%.")
        or normalized:match("^Bricks%.")
end

local function should_avoid_cached_console_exec(command)
    local normalized = trim(tostring(command or ""))
    return normalized:match("^Chat%.") ~= nil
end

local function should_handle_emulated_immediately(command)
    local normalized = trim(tostring(command or ""))
    if normalized == "Omegga.Bridge.Echo" then
        return true
    end

    if normalized == "Omegga.Bridge.ProbeChatApi" then
        return true
    end

    if normalized == "Server.Status" then
        return true
    end

    if normalized == "GetAll BRPlayerState UserName" then
        return true
    end

    if normalized:match("^GetAll BRPlayerState Owner Name=") then
        return true
    end

    if normalized:match("^Omegga%.Bridge%.ProbeConsoleExec%s+") then
        return true
    end

    return false
end

local function split_once(value, separator)
    local index = string.find(value, separator, 1, true)
    if not index then
        return value, nil
    end

    return value:sub(1, index - 1), value:sub(index + #separator)
end

local function extract_short_name(full_name)
    local match = tostring(full_name or ""):match("%.([%w_]+)$")
    if match and match ~= "" then
        return match
    end
    return tostring(full_name or "")
end

local function try_get_property_value(object, property_name)
    if not object or not object.IsValid or not object:IsValid() then
        return nil
    end

    local ok, value = pcall(function()
        return object:GetPropertyValue(property_name)
    end)
    if not ok or value == nil then
        return nil
    end

    return value
end

local function try_get_first_property_value(object, property_names)
    for _, property_name in ipairs(property_names) do
        local value = try_get_property_value(object, property_name)
        if value ~= nil then
            return value, property_name
        end
    end

    return nil, nil
end

local function value_to_string(value)
    if value == nil then
        return ""
    end

    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end

    if value_type == "userdata" then
        if type(value.GetComparisonIndex) == "function" then
            if value.ToString and type(value.ToString) == "function" then
                local string_ok, string_value = pcall(function()
                    return value:ToString()
                end)
                if string_ok and string_value and tostring(string_value) ~= "" then
                    return tostring(string_value)
                end
            end

            local index_ok, comparison_index = pcall(function()
                return value:GetComparisonIndex()
            end)
            if index_ok and type(comparison_index) == "number" then
                return string.format("FName#%d", comparison_index)
            end
        end

        if value.ToString and type(value.ToString) == "function" then
            local string_ok, string_value = pcall(function()
                return value:ToString()
            end)
            if string_ok and string_value and tostring(string_value) ~= "" then
                return tostring(string_value)
            end
        end

        if value.GetFullName and type(value.GetFullName) == "function" then
            local full_name_ok, full_name = pcall(function()
                return value:GetFullName()
            end)
            if full_name_ok and full_name and tostring(full_name) ~= "" then
                return tostring(full_name)
            end
        end
    end

    return tostring(value)
end

local function value_to_number(value)
    if type(value) == "number" then
        return value
    end

    local parsed = tonumber(value_to_string(value))
    if parsed == nil then
        return nil
    end

    return parsed
end

local function quote_name(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub("\"", "\\\"")
end

function quote_console_string(value)
    return "\"" .. quote_name(value) .. "\""
end

function unquote_console_string(value)
    local result = trim(tostring(value or ""))
    if #result >= 2 and result:sub(1, 1) == "\"" and result:sub(-1) == "\"" then
        result = result:sub(2, -2)
        result = result:gsub("\\n", "\n")
        result = result:gsub("\\r", "\r")
        result = result:gsub("\\t", "\t")
        result = result:gsub("\\\"", "\"")
        result = result:gsub("\\\\", "\\")
    end
    return result
end

function flatten_rich_chat_text(value)
    local result = unquote_console_string(value)
    result = result:gsub("<[^>]*>", "")
    result = result:gsub("%s+", " ")
    return trim(result)
end

local function format_duration_ms(milliseconds)
    local total_ms = math.max(0, math.floor(tonumber(milliseconds) or 0))
    local total_seconds = math.floor(total_ms / 1000)
    local days = math.floor(total_seconds / 86400)
    local hours = math.floor((total_seconds % 86400) / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds % 60
    local remainder_ms = total_ms % 1000
    local chunks = {}

    if days > 0 then
        table.insert(chunks, tostring(days) .. "d")
    end
    if hours > 0 then
        table.insert(chunks, tostring(hours) .. "h")
    end
    if minutes > 0 then
        table.insert(chunks, tostring(minutes) .. "m")
    end
    if seconds > 0 or #chunks == 0 then
        table.insert(chunks, tostring(seconds) .. "s")
    end
    if remainder_ms > 0 and #chunks == 0 then
        table.insert(chunks, tostring(remainder_ms) .. "ms")
    end

    return table.concat(chunks, " ")
end

local function pad_status_column(value, width)
    local string_value = tostring(value or "")
    if #string_value > width then
        if width <= 1 then
            return string_value:sub(1, width)
        end
        return string_value:sub(1, width - 1) .. "~"
    end
    return string_value .. string.rep(" ", width - #string_value)
end

local function get_uehelpers()
    local ok, UEHelpers = pcall(require, "UEHelpers")
    if not ok then
        return nil, tostring(UEHelpers)
    end

    return UEHelpers, nil
end

local function dirname(path)
    return tostring(path or ""):match("^(.*)[/\\][^/\\]+$")
end

local function join_path(...)
    local parts = { ... }
    local separator = "\\"
    local cleaned = {}

    for _, part in ipairs(parts) do
        if tostring(part or ""):find("/", 1, true) then
            separator = "/"
            break
        end
    end

    for index, part in ipairs(parts) do
        local value = tostring(part or "")
        if value ~= "" then
            value = value:gsub("[/\\]+$", "")
            if index > 1 then
                value = value:gsub("^[/\\]+", "")
            end
            if value ~= "" then
                table.insert(cleaned, value)
            end
        end
    end

    return table.concat(cleaned, separator)
end

local function get_data_root()
    local bridge_root = dirname(BRIDGE_DIR)
    if not bridge_root then
        return nil
    end

    if tostring(bridge_root):match("[/\\]ue4ss%-bridge$") then
        return dirname(bridge_root) or bridge_root
    end

    return bridge_root
end

local function get_brickadia_log_path()
    local data_root = get_data_root()
    if not data_root then
        return nil
    end

    return join_path(data_root, "Saved", "Logs", "Brickadia.log")
end

local function parse_log_timestamp(line)
    local raw_timestamp = tostring(line or ""):match("^%[(%d+%.%d+%.%d+%-%d+%.%d+%.%d+:%d+)%]")
    if not raw_timestamp then
        return nil
    end

    local year, month, day, hour, min, sec = raw_timestamp:match("^(%d+)%.(%d+)%.(%d+)%-(%d+)%.(%d+)%.(%d+):%d+$")
    if not year then
        return nil
    end

    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    })
end

local function build_status_output_from_log()
    local log_path = get_brickadia_log_path()
    if not log_path then
        return nil, "Could not determine Brickadia log path."
    end

    local contents = read_file(log_path)
    if not contents or contents == "" then
        return nil, "Brickadia log file is unavailable."
    end

    local latest_world_start = nil
    for line in contents:gmatch("[^\r\n]+") do
        if line:match("LogWorld: Bringing World .+ up for play") then
            latest_world_start = parse_log_timestamp(line)
        end
    end

    local uptime_ms = 0
    if latest_world_start then
        uptime_ms = math.max(0, (os.time() - latest_world_start) * 1000)
    end

    local lines = {
        "Server Name: Brickadia Windows UE4SS",
        "Description: ",
        "Bricks: 0",
        "Components: 0",
        "Time: " .. format_duration_ms(uptime_ms),
        table.concat({
            "* ",
            pad_status_column("Name", 24),
            " | ",
            pad_status_column("Ping", 6),
            " | ",
            pad_status_column("Time", 8),
            " | ",
            pad_status_column("Roles", 18),
            " | ",
            pad_status_column("Address", 22),
            " | ",
            pad_status_column("Id", 32),
        }),
    }

    return table.concat(lines, "\n")
end

local function is_valid_object(object)
    return object and type(object.IsValid) == "function" and object:IsValid()
end

local function remember_cached_world(world)
    if not is_valid_object(world) then
        return false
    end

    last_hook_world = world

    local game_mode = try_get_property_value(world, "AuthorityGameMode") or try_get_property_value(world, "GameMode")
    if is_valid_object(game_mode) then
        last_hook_game_mode = game_mode
        local game_session = try_get_property_value(game_mode, "GameSession")
        if is_valid_object(game_session) then
            last_hook_game_session = game_session
        end
    end

    local game_state = try_get_property_value(world, "GameState")
    if is_valid_object(game_state) then
        last_hook_game_state = game_state
    end

    return true
end

local function remember_object_world(object)
    if not is_valid_object(object) then
        return false
    end

    local ok, world = pcall(function()
        if type(object.GetWorld) == "function" then
            return object:GetWorld()
        end

        return nil
    end)

    if ok and is_valid_object(world) then
        return remember_cached_world(world)
    end

    return false
end

local function remember_command_context(context, executor, command, source)
    if is_valid_object(context) then
        last_hook_context = context
        remember_object_world(context)
    end

    if is_valid_object(executor) then
        last_hook_executor = executor
        if not is_valid_object(last_hook_world) then
            remember_object_world(executor)
        end
    end

    local normalized = trim(command)
    if normalized ~= "" then
        last_hook_command = normalized
    end

    if source and tostring(source) ~= "" then
        last_hook_source = tostring(source)
    end
end

local function remember_command_context_shallow(context, executor, command, source)
    if is_valid_object(context) then
        last_hook_context = context
    end

    if is_valid_object(executor) then
        last_hook_executor = executor
    end

    local normalized = trim(command)
    if normalized ~= "" then
        last_hook_command = normalized
    end

    if source and tostring(source) ~= "" then
        last_hook_source = tostring(source)
    end
end

local function safe_value_to_string(value)
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end

    return ""
end

local function contains_any_hint(value, hints)
    local normalized = string.lower(tostring(value or ""))
    for _, hint in ipairs(hints) do
        if string.find(normalized, hint, 1, true) then
            return true
        end
    end

    return false
end

local function extract_terminal_name(full_name, fallback)
    local normalized = tostring(full_name or ""):gsub("^%s*[%w_]+%s+", "")
    local tail = normalized:match("[:.]([%w_]+)$")
    if tail and tail ~= "" then
        return tail
    end

    local short_name = extract_short_name(normalized)
    if short_name and short_name ~= "" and short_name ~= normalized then
        return short_name
    end

    return fallback or normalized
end

local function get_fname_string(object)
    if not object or type(object.GetFName) ~= "function" then
        return nil
    end

    local name_ok, fname = pcall(function()
        return object:GetFName()
    end)
    if not name_ok or not fname then
        return nil
    end

    if type(fname.ToString) == "function" then
        local string_ok, rendered = pcall(function()
            return fname:ToString()
        end)
        if string_ok and rendered and tostring(rendered) ~= "" then
            return tostring(rendered)
        end
    end

    if type(fname.GetComparisonIndex) == "function" then
        local index_ok, comparison_index = pcall(function()
            return fname:GetComparisonIndex()
        end)
        if index_ok and type(comparison_index) == "number" then
            return string.format("FName#%d", comparison_index)
        end
    end

    return nil
end

local function get_full_name_string(object)
    if not object or type(object.GetFullName) ~= "function" then
        return nil
    end

    local full_name_ok, full_name = pcall(function()
        return object:GetFullName()
    end)
    if full_name_ok and full_name and tostring(full_name) ~= "" then
        return tostring(full_name)
    end

    return nil
end

local function get_object_address_string(object)
    if not is_valid_object(object) then
        return nil
    end

    local ok, address = pcall(function()
        return object:GetAddress()
    end)
    if ok and type(address) == "number" then
        return string.format("0x%X", address)
    end

    return nil
end

local function get_property_name(property)
    if not property then
        return "unknown"
    end

    if type(property.GetName) == "function" then
        local ok, name = pcall(function()
            return property:GetName()
        end)
        if ok and name and tostring(name) ~= "" then
            return tostring(name)
        end
    end

    local short_name = get_fname_string(property)
    if short_name and short_name ~= "" and not short_name:match("^FName#%d+$") then
        return short_name
    end

    local full_name = get_full_name_string(property)
    local terminal_name = extract_terminal_name(full_name, nil)
    if terminal_name and terminal_name ~= "" then
        return terminal_name
    end

    return "unknown"
end

local function get_property_class_name(property)
    if not property or type(property.GetClass) ~= "function" then
        return "unknown"
    end

    local ok, property_class = pcall(function()
        return property:GetClass()
    end)
    if ok and property_class then
        local valid = true
        if type(property_class.IsValid) == "function" then
            local valid_ok, valid_result = pcall(function()
                return property_class:IsValid()
            end)
            valid = valid_ok and valid_result
        end
        if not valid then
            return "unknown"
        end

        local short_name = get_fname_string(property_class)
        if short_name and short_name ~= "" and not short_name:match("^FName#%d+$") then
            return short_name
        end

        local full_name = get_full_name_string(property_class)
        local terminal_name = extract_terminal_name(full_name, nil)
        if terminal_name and terminal_name ~= "" then
            return terminal_name
        end

        local rendered = tostring(property_class)
        if rendered and rendered ~= "" then
            return rendered
        end
    end

    return "unknown"
end

local function get_object_property_class_name(property)
    if not property or type(property.GetPropertyClass) ~= "function" then
        return nil
    end

    local ok, property_class = pcall(function()
        return property:GetPropertyClass()
    end)
    if ok and property_class then
        local valid = true
        if type(property_class.IsValid) == "function" then
            local valid_ok, valid_result = pcall(function()
                return property_class:IsValid()
            end)
            valid = valid_ok and valid_result
        end
        if not valid then
            return nil
        end

        local short_name = get_fname_string(property_class)
        if short_name and short_name ~= "" and not short_name:match("^FName#%d+$") then
            return short_name
        end

        local full_name = get_full_name_string(property_class)
        local terminal_name = extract_terminal_name(full_name, nil)
        if terminal_name and terminal_name ~= "" then
            return terminal_name
        end

        local rendered = tostring(property_class)
        if rendered and rendered ~= "" then
            return rendered
        end
    end

    return nil
end

local function get_struct_property_name(property)
    if not property or type(property.GetStruct) ~= "function" then
        return nil
    end

    local ok, struct = pcall(function()
        return property:GetStruct()
    end)
    if ok and struct then
        local valid = true
        if type(struct.IsValid) == "function" then
            local valid_ok, valid_result = pcall(function()
                return struct:IsValid()
            end)
            valid = valid_ok and valid_result
        end
        if not valid then
            return nil
        end

        local short_name = get_fname_string(struct)
        if short_name and short_name ~= "" and not short_name:match("^FName#%d+$") then
            return short_name
        end

        local full_name = get_full_name_string(struct)
        local terminal_name = extract_terminal_name(full_name, nil)
        if terminal_name and terminal_name ~= "" then
            return terminal_name
        end

        local rendered = tostring(struct)
        if rendered and rendered ~= "" then
            return rendered
        end
    end

    return nil
end

local function normalize_hook_function_path(full_name)
    local normalized = tostring(full_name or ""):gsub("^Function%s+", "")
    if normalized:find(":", 1, true) then
        return normalized
    end

    local head, tail = normalized:match("^(.*)%.([^.]+)$")
    if head and tail then
        return head .. ":" .. tail
    end

    return normalized
end

local function build_function_parameters(func)
    local params = {}
    if not func or not func.IsValid or not func:IsValid() or type(func.ForEachProperty) ~= "function" then
        return params
    end

    local ok = pcall(function()
        func:ForEachProperty(function(property)
            table.insert(params, {
                name = get_property_name(property),
                property = property,
                property_class = get_property_class_name(property),
                object_class = get_object_property_class_name(property),
                struct_name = get_struct_property_name(property),
            })
            return false
        end)
    end)

    if not ok then
        return {}
    end

    return params
end

local function describe_function_parameters(parameters)
    local parts = {}
    for _, parameter in ipairs(parameters or {}) do
        local type_name = parameter.property_class or "unknown"
        if parameter.object_class then
            type_name = type_name .. "<" .. parameter.object_class .. ">"
        elseif parameter.struct_name then
            type_name = type_name .. "<" .. parameter.struct_name .. ">"
        end
        table.insert(parts, parameter.name .. ":" .. type_name)
    end
    return table.concat(parts, ", ")
end

function OmeggaDescribePropertyType(property)
    local property_class = get_property_class_name(property)
    local object_class = get_object_property_class_name(property)
    local struct_name = get_struct_property_name(property)
    local type_name = tostring(property_class or "unknown")
    if object_class then
        type_name = type_name .. "<" .. tostring(object_class) .. ">"
    elseif struct_name then
        type_name = type_name .. "<" .. tostring(struct_name) .. ">"
    end
    return type_name
end

function OmeggaDescribeStructFieldsFromProperty(property, depth, max_fields)
    depth = depth or 0
    if not property or type(property.GetStruct) ~= "function" or depth > 2 then
        return {}
    end

    local ok, struct = pcall(function()
        return property:GetStruct()
    end)
    if not ok or not is_valid_object(struct) or type(struct.ForEachProperty) ~= "function" then
        return {}
    end

    local lines = {}
    local struct_label = get_object_label(struct, get_struct_property_name(property) or "struct")
    table.insert(lines, string.rep("  ", depth) .. "struct=" .. tostring(struct_label))

    local index = 0
    local iter_ok, iter_err = pcall(function()
        struct:ForEachProperty(function(child)
            index = index + 1
            local child_ok, child_error = pcall(function()
                local child_name = get_property_name(child)
                local child_line = string.rep("  ", depth)
                    .. "field["
                    .. tostring(index)
                    .. "] "
                    .. tostring(child_name)
                    .. ":"
                    .. OmeggaDescribePropertyType(child)
                table.insert(lines, child_line)

                local child_struct_fields = OmeggaDescribeStructFieldsFromProperty(child, depth + 1, max_fields)
                for _, nested in ipairs(child_struct_fields) do
                    table.insert(lines, nested)
                end
            end)
            if not child_ok then
                table.insert(lines, string.rep("  ", depth) .. "field_error[" .. tostring(index) .. "]=" .. tostring(child_error))
            end

            return max_fields and index >= max_fields
        end)
    end)

    if not iter_ok then
        table.insert(lines, string.rep("  ", depth) .. "fields_error=" .. tostring(iter_err))
    elseif index == 0 then
        table.insert(lines, string.rep("  ", depth) .. "fields=0")
    end

    return lines
end

local function get_cached_command_context()
    local helper_error = nil

    if type(OmeggaGetCachedCommandContext) == "function" then
        local ok, context = pcall(OmeggaGetCachedCommandContext)
        if not ok then
            helper_error = tostring(context)
        elseif is_valid_object(context) then
            last_hook_context = context
            if last_hook_source == nil or last_hook_source == "" then
                last_hook_source = "native-helper"
            end
            return context, nil
        else
            helper_error = "No cached command context is available yet."
        end
    end

    if is_valid_object(last_hook_context) then
        return last_hook_context, nil
    end

    if helper_error then
        return nil, helper_error
    end

    return nil, "Cached command context helper is unavailable and no hook-cached context exists yet."
end

local function get_cached_world()
    if type(UEHelpers) == "table" and type(UEHelpers.GetWorld) == "function" then
        local ok, world = pcall(UEHelpers.GetWorld)
        if ok and is_valid_object(world) then
            remember_cached_world(world)
            return world, nil
        end
    end

    if is_valid_object(last_hook_world) then
        return last_hook_world, nil
    end

    local context, context_error = get_cached_command_context()
    if context then
        local ok, world = pcall(function()
            return context:GetWorld()
        end)
        if ok and is_valid_object(world) then
            remember_cached_world(world)
            return world, nil
        elseif not ok then
            bridge_log("warn", "Cached command context GetWorld failed: " .. tostring(world))
        end
    end

    if context_error then
        return nil, context_error
    end

    return nil, "Cached command context has no world."
end

local function get_cached_game_objects()
    local world, world_error = get_cached_world()
    if not world then
        return nil, world_error
    end

    local game_mode = nil
    local game_state = nil

    game_mode = try_get_property_value(world, "AuthorityGameMode") or try_get_property_value(world, "GameMode")
    if not is_valid_object(game_mode) and is_valid_object(last_hook_game_mode) then
        game_mode = last_hook_game_mode
    end

    game_state = try_get_property_value(world, "GameState")
    if not is_valid_object(game_state) and is_valid_object(last_hook_game_state) then
        game_state = last_hook_game_state
    end

    local game_session = is_valid_object(game_mode) and try_get_property_value(game_mode, "GameSession") or nil
    if not is_valid_object(game_session) and is_valid_object(last_hook_game_session) then
        game_session = last_hook_game_session
    end

    if is_valid_object(world) then
        remember_cached_world(world)
    end

    return {
        world = world,
        game_mode = game_mode,
        game_state = game_state,
        game_session = game_session,
    }, nil
end

local function log_typed_chat_resolution(step)
    bridge_log("info", "Typed chat resolution " .. tostring(step or ""))
end

local function remember_cached_world_shallow(world)
    if not is_valid_object(world) then
        return false
    end

    last_hook_world = world
    return true
end

local function get_chat_broadcast_objects()
    local world = is_valid_object(last_hook_world) and last_hook_world or nil
    local game_mode = is_valid_object(last_hook_game_mode) and last_hook_game_mode or nil
    local game_state = is_valid_object(last_hook_game_state) and last_hook_game_state or nil
    local game_session = is_valid_object(last_hook_game_session) and last_hook_game_session or nil

    log_typed_chat_resolution("begin")
    log_typed_chat_resolution(
        "hook-cached world="
            .. tostring(is_valid_object(world))
            .. " game_mode="
            .. tostring(is_valid_object(game_mode))
            .. " game_state="
            .. tostring(is_valid_object(game_state))
            .. " game_session="
            .. tostring(is_valid_object(game_session))
    )

    if is_valid_object(world) or is_valid_object(game_mode) or is_valid_object(game_state) or is_valid_object(game_session) then
        log_typed_chat_resolution(
            "resolved world="
                .. tostring(is_valid_object(world))
                .. " game_mode="
                .. tostring(is_valid_object(game_mode))
                .. " game_state="
                .. tostring(is_valid_object(game_state))
                .. " game_session="
                .. tostring(is_valid_object(game_session))
        )
        return {
            world = world,
            game_mode = game_mode,
            game_state = game_state,
            game_session = game_session,
        }, nil
    end

    -- Native command-context caches can outlive the UObject they reference.
    -- Typed chat must only use hook-cached objects or objects discovered fresh
    -- on this game-thread callback; otherwise fail closed without dereferencing
    -- a cross-frame context.
    game_mode = find_first_valid("GameModeBase")
    game_state = find_first_valid("GameStateBase")
    if is_valid_object(game_mode) then
        last_hook_game_mode = game_mode
        game_session = try_get_property_value(game_mode, "GameSession")
        if is_valid_object(game_session) then
            last_hook_game_session = game_session
        end
    end
    if is_valid_object(game_state) then
        last_hook_game_state = game_state
    end
    world = is_valid_object(last_hook_world) and last_hook_world or nil

    if is_valid_object(world) or is_valid_object(game_mode) or is_valid_object(game_state) then
        log_typed_chat_resolution(
            "resolved via bounded discovery world="
                .. tostring(is_valid_object(world))
                .. " game_mode="
                .. tostring(is_valid_object(game_mode))
                .. " game_state="
                .. tostring(is_valid_object(game_state))
                .. " game_session="
                .. tostring(is_valid_object(game_session))
        )
        return {
            world = world,
            game_mode = game_mode,
            game_state = game_state,
            game_session = game_session,
        }, nil
    end

    log_typed_chat_resolution("fail-closed: no fresh server objects")
    return nil,
        "Typed chat refused stale cached command context because no fresh world, game mode, or game state was available."
end

local function get_object_label(object, fallback)
    if not is_valid_object(object) then
        return fallback or "nil"
    end

    local short_name = get_fname_string(object)
    if not short_name or short_name == "" or short_name:match("^FName#%d+$") then
        local full_name = get_full_name_string(object)
        local terminal_name = extract_terminal_name(full_name, nil)
        if terminal_name and terminal_name ~= "" then
            short_name = terminal_name
        elseif full_name and full_name ~= "" then
            short_name = full_name
        end
    end

    local address = get_object_address_string(object)
    if short_name and short_name ~= "" and address and address ~= "" then
        return short_name .. "@" .. address
    end

    if short_name and short_name ~= "" then
        return short_name
    end

    if address and address ~= "" then
        return address
    end

    return fallback or "nil"
end

local function get_object_short_name(object, fallback)
    if not is_valid_object(object) then
        return fallback or "nil"
    end

    local short_name = get_fname_string(object)
    if not short_name or short_name == "" or short_name:match("^FName#%d+$") then
        local full_name = get_full_name_string(object)
        local terminal_name = extract_terminal_name(full_name, nil)
        if terminal_name and terminal_name ~= "" then
            short_name = terminal_name
        end
    end

    if short_name and short_name ~= "" then
        return short_name
    end

    local address = get_object_address_string(object)
    if address and address ~= "" then
        return address
    end

    return fallback or "nil"
end

local function describe_named_object_hits(short_name, include_properties)
    if not ALLOW_UNSAFE_PROBES then
        return "DescribeObjectName is disabled by default on Brickadia Windows because unresolved UE4SS signatures still make object discovery unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    short_name = trim(tostring(short_name or ""))
    if short_name == "" then
        return "describe-object-name requires a short object name"
    end

    local lines = { "Describe object name: " .. short_name }
    local banned_flags = EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject
    local ok, objects = pcall(function()
        return FindObjects(8, nil, short_name, EObjectFlags.RF_NoFlags, banned_flags, false)
    end)

    if not ok then
        return "FindObjects crashed: " .. tostring(objects)
    end

    if type(objects) ~= "table" or #objects == 0 then
        return table.concat({ lines[1], "hits=0" }, "\n")
    end

    table.insert(lines, "hits=" .. tostring(#objects))
    for index, object in ipairs(objects) do
        local class_name = "unknown"
        local outer_name = "none"
        local class_ok, class_object = pcall(function()
            return object:GetClass()
        end)
        if class_ok and is_valid_object(class_object) then
            class_name = get_object_short_name(class_object, "unknown")
        end

        local outer_ok, outer_object = pcall(function()
            return object:GetOuter()
        end)
        if outer_ok and is_valid_object(outer_object) then
            outer_name = get_object_short_name(outer_object, "unknown")
        end

        table.insert(
            lines,
            string.format(
                "hit[%d] addr=0x%X name=%s class=%s outer=%s",
                index,
                object:GetAddress(),
                get_object_short_name(object, short_name),
                class_name,
                outer_name
            )
        )

        if include_properties ~= false and type(object.ForEachProperty) == "function" then
            local properties = {}
            local prop_ok, prop_err = pcall(function()
                object:ForEachProperty(function(property)
                    local property_name = get_property_name(property)
                    local property_type = "unknown"
                    local type_ok, property_class = pcall(function()
                        return property:GetClass()
                    end)
                    if type_ok and is_valid_object(property_class) then
                        property_type = get_object_short_name(property_class, "unknown")
                    end
                    table.insert(properties, property_name .. ":" .. property_type)
                    if #properties >= 12 then
                        return true
                    end
                    return false
                end)
            end)

            if prop_ok and #properties > 0 then
                table.insert(lines, "  params=" .. table.concat(properties, ", "))
            elseif not prop_ok then
                table.insert(lines, "  params_error=" .. tostring(prop_err))
            else
                table.insert(lines, "  params=<none>")
            end
        end
    end

    return table.concat(lines, "\n")
end

OMEGGA_PREFAB_PROBE_SOURCE_CLASSES = {
    "BRBundleManager",
    "BRWorldManager",
    "BRBundleTransferComponent",
    "BRPrefabCache",
    "BRPrefabCacheInMemoryPrefab",
    "BRPrefabHashAndMetadata",
    "BRPrefabDetachedPasteInfo",
    "BRBundleArchive",
    "BrickGridActor",
    "BrickGridComponent",
    "BrickGridDynamicActor",
    "PlayerController",
    "BP_PlayerController_C",
    "BRPlayerController",
}

function OmeggaParseProbeMethodSpec(spec)
    local cleaned = trim(tostring(spec or ""))
    local method_name, class_list_raw = cleaned:match("^(%S+)%s+(.+)$")
    if not method_name then
        return cleaned, OMEGGA_PREFAB_PROBE_SOURCE_CLASSES
    end

    class_list_raw = trim((class_list_raw or ""):gsub("^on%s+", ""))
    local classes = {}
    local seen = {}
    for token in class_list_raw:gmatch("[^,%s]+") do
        local class_name = trim(token)
        if class_name ~= "" and not seen[class_name] then
            seen[class_name] = true
            table.insert(classes, class_name)
        end
    end

    if #classes == 0 then
        classes = OMEGGA_PREFAB_PROBE_SOURCE_CLASSES
    end

    return method_name, classes
end

local function probe_callable_method(method_name)
    if not ALLOW_UNSAFE_PROBES then
        return "ProbeMethod is disabled by default on Brickadia Windows because unresolved UE4SS signatures still make reflected member lookup unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    local source_classes
    method_name, source_classes = OmeggaParseProbeMethodSpec(method_name)
    method_name = trim(tostring(method_name or ""))
    if method_name == "" then
        return "probe-method requires a method name"
    end

    local lines = { "Probe method: " .. method_name }
    local objects, object_error = get_cached_game_objects()
    if not objects then
        table.insert(lines, "cached_game_objects_error=" .. tostring(object_error))
    end

    local candidates = {}
    local seen_candidates = {}

    local function add_probe_candidate(label, object)
        if not is_valid_object(object) then
            return
        end

        local key = get_object_address_string(object) or label or tostring(object)
        if seen_candidates[key] then
            return
        end

        seen_candidates[key] = true
        table.insert(candidates, { label = label, object = object })
    end

    if objects then
        add_probe_candidate("world", objects.world)
        add_probe_candidate("game_mode", objects.game_mode)
        add_probe_candidate("game_state", objects.game_state)
        add_probe_candidate("game_session", objects.game_session)
    end

    local context = select(1, get_cached_command_context())
    add_probe_candidate("cached_context", context)

    if type(FindFirstOf) == "function" then
        for _, source_name in ipairs({ "BRChatCommandWorldSubsystem", "ChatCommandWorldSubsystem", "BP_ChatCommandWorldSubsystem_C" }) do
            local ok, source_object = pcall(FindFirstOf, source_name)
            if ok then
                add_probe_candidate("FindFirstOf(" .. source_name .. ")", source_object)
            end
        end

        for _, source_name in ipairs(source_classes or {}) do
            local ok, source_object = pcall(FindFirstOf, source_name)
            if ok then
                add_probe_candidate("FindFirstOf(" .. source_name .. ")", source_object)
            end
        end
    end

    if type(FindAllOf) == "function" then
        for _, source_name in ipairs(source_classes or {}) do
            local ok, source_objects = pcall(FindAllOf, source_name)
            if ok and type(source_objects) == "table" then
                for index, source_object in ipairs(source_objects) do
                    if index > 5 then
                        break
                    end
                    add_probe_candidate("FindAllOf(" .. source_name .. ")[" .. tostring(index) .. "]", source_object)
                end
            end
        end
    end

    if type(prefab_probe_collect_objects) == "function" then
        for _, source_name in ipairs(source_classes or {}) do
            local ok, source_objects = pcall(prefab_probe_collect_objects, source_name)
            if ok and type(source_objects) == "table" then
                for index, source_object in ipairs(source_objects) do
                    if index > 5 then
                        break
                    end
                    add_probe_candidate(
                        "prefab_probe_collect_objects(" .. source_name .. ")[" .. tostring(index) .. "]",
                        source_object
                    )
                end
            end
        end
    end

    for _, candidate in ipairs(candidates) do
        local object = candidate.object
        if not is_valid_object(object) then
            table.insert(lines, candidate.label .. "=invalid")
        else
            local ok, value = pcall(function()
                return object[method_name]
            end)
            if not ok then
                table.insert(lines, candidate.label .. "=error:" .. tostring(value))
            elseif value == nil then
                table.insert(lines, candidate.label .. "=nil")
            else
                local summary = candidate.label
                    .. "=value-type:"
                    .. tostring(type(value))
                    .. " object="
                    .. get_object_short_name(object, candidate.label)

                if is_valid_object(value) then
                    local member_address = get_object_address_string(value)
                    if member_address and member_address ~= "" then
                        summary = summary .. " member=" .. member_address
                    end
                    local parameters = build_function_parameters(value)
                    if #parameters > 0 then
                        summary = summary .. " params=[" .. describe_function_parameters(parameters) .. "]"
                    end
                end

                table.insert(
                    lines,
                    summary
                )
            end
        end
    end

    return table.concat(lines, "\n")
end

function OmeggaListFunctionsByHint(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "ListFunctionsByHint is disabled by default on Brickadia Windows because reflected lookup is unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    local class_raw, hint_raw, limit_raw = trim(tostring(spec or "")):match("^(%S+)%s+(%S+)%s*(%d*)$")
    if not class_raw or not hint_raw then
        return "list-functions-by-hint requires: <ClassName[,ClassName...]> <hint[,hint...]> [Limit]"
    end

    local classes = prefab_probe_parse_classes(class_raw)
    local hints = prefab_probe_parse_classes(hint_raw)
    local limit = tonumber(limit_raw or "") or 80
    if limit < 1 then
        limit = 1
    elseif limit > 240 then
        limit = 240
    end

    local lower_hints = {}
    for _, hint in ipairs(hints) do
        table.insert(lower_hints, string.lower(tostring(hint or "")))
    end

    local function matches_hint(value)
        local lowered = string.lower(tostring(value or ""))
        for _, hint in ipairs(lower_hints) do
            if hint ~= "" and lowered:find(hint, 1, true) then
                return true
            end
        end
        return false
    end

    local lines = {
        "List functions by hint",
        "classes=" .. table.concat(classes, ","),
        "hints=" .. table.concat(hints, ","),
        "limit=" .. tostring(limit),
    }
    local seen_objects = {}
    local seen_functions = {}
    local total = 0

    local function append_holder_functions(source_label, holder)
        if total >= limit or not is_valid_object(holder) or type(holder.ForEachFunction) ~= "function" then
            return
        end

        local holder_label = get_object_label(holder, source_label)
        local ok, iter_error = pcall(function()
            holder:ForEachFunction(function(func)
                local entry_ok, stop = pcall(function()
                    if total >= limit then
                        return true
                    end

                    local short_name = get_object_short_name(func, "")
                    local full_name = get_object_label(func, short_name)
                    if not matches_hint(short_name) and not matches_hint(full_name) then
                        return false
                    end

                    local function_key = get_object_address_string(func) or full_name
                    if seen_functions[function_key] then
                        return false
                    end
                    seen_functions[function_key] = true
                    total = total + 1

                    local params = "<signature unavailable>"
                    local params_ok, params_or_error = pcall(function()
                        return describe_function_parameters(build_function_parameters(func))
                    end)
                    if params_ok then
                        params = tostring(params_or_error or "")
                    end

                    table.insert(
                        lines,
                        "hit["
                            .. tostring(total)
                            .. "] source="
                            .. tostring(source_label)
                            .. " holder="
                            .. holder_label
                            .. " function="
                            .. tostring(full_name)
                            .. " params=["
                            .. params
                            .. "]"
                    )
                    return false
                end)
                if not entry_ok then
                    table.insert(lines, tostring(source_label) .. " function_entry_error=" .. tostring(stop))
                    return false
                end
                return stop == true
            end)
        end)

        if not ok then
            table.insert(lines, tostring(source_label) .. " iteration_error=" .. tostring(iter_error))
        end
    end

    local function append_object(source_label, object)
        if not is_valid_object(object) then
            return
        end

        local object_key = get_object_address_string(object) or tostring(object)
        if seen_objects[object_key] then
            return
        end
        seen_objects[object_key] = true

        append_holder_functions(source_label .. ":object", object)

        local ok_class, class_object = pcall(function()
            return object:GetClass()
        end)
        if ok_class and is_valid_object(class_object) then
            append_holder_functions(source_label .. ":class", class_object)
        end
    end

    for _, class_name in ipairs(classes) do
        local found_count = 0
        if type(prefab_probe_collect_objects) == "function" then
            local ok, objects = pcall(prefab_probe_collect_objects, class_name)
            if ok and type(objects) == "table" then
                for index, object in ipairs(objects) do
                    found_count = found_count + 1
                    append_object("prefab_probe_collect_objects(" .. class_name .. ")[" .. tostring(index) .. "]", object)
                    if total >= limit then
                        break
                    end
                end
            end
        end

        if found_count == 0 and type(FindObjects) == "function" then
            local banned_flags = EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject
            local ok, objects = pcall(function()
                return FindObjects(8, nil, class_name, EObjectFlags.RF_NoFlags, banned_flags, false)
            end)
            if ok and type(objects) == "table" then
                for index, object in ipairs(objects) do
                    found_count = found_count + 1
                    append_object("FindObjects(" .. class_name .. ")[" .. tostring(index) .. "]", object)
                    if total >= limit then
                        break
                    end
                end
            end
        end

        if found_count == 0 then
            table.insert(lines, "class=" .. tostring(class_name) .. " found=0")
        end

        if total >= limit then
            break
        end
    end

    table.insert(lines, "hits=" .. tostring(total))
    return table.concat(lines, "\n")
end

function prefab_probe_compact(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n]+", " ")
    text = text:gsub("%s+", " ")
    if #text > 180 then
        return text:sub(1, 177) .. "..."
    end
    return trim(text)
end

function prefab_probe_try_axis(value, axis)
    if value == nil then
        return nil
    end

    local candidates = {
        axis,
        string.lower(axis),
    }

    for _, key in ipairs(candidates) do
        local ok, result = pcall(function()
            return value[key]
        end)
        local number_value = ok and value_to_number(result) or nil
        if number_value ~= nil then
            return number_value
        end
    end

    if type(value) == "userdata" and type(value.GetPropertyValue) == "function" then
        local ok, result = pcall(function()
            return value:GetPropertyValue(axis)
        end)
        local number_value = ok and value_to_number(result) or nil
        if number_value ~= nil then
            return number_value
        end
    end

    return nil
end

function prefab_probe_vector_from_value(value)
    if value == nil then
        return nil
    end

    local x = prefab_probe_try_axis(value, "X")
    local y = prefab_probe_try_axis(value, "Y")
    local z = prefab_probe_try_axis(value, "Z")
    if x ~= nil and y ~= nil and z ~= nil then
        return { x = x, y = y, z = z }
    end

    local text = value_to_string(value)
    if text and text ~= "" then
        local parsed_x = tonumber(text:match("[Xx]%s*=?%s*(-?%d+%.?%d*)"))
        local parsed_y = tonumber(text:match("[Yy]%s*=?%s*(-?%d+%.?%d*)"))
        local parsed_z = tonumber(text:match("[Zz]%s*=?%s*(-?%d+%.?%d*)"))
        if parsed_x ~= nil and parsed_y ~= nil and parsed_z ~= nil then
            return { x = parsed_x, y = parsed_y, z = parsed_z }
        end
    end

    return nil
end

function prefab_probe_nested_value(value, property_name)
    if value == nil then
        return nil
    end

    local ok, result = pcall(function()
        return value[property_name]
    end)
    if ok and result ~= nil then
        return result
    end

    if type(value) == "userdata" and type(value.GetPropertyValue) == "function" then
        local property_ok, property_value = pcall(function()
            return value:GetPropertyValue(property_name)
        end)
        if property_ok and property_value ~= nil then
            return property_value
        end
    end

    return nil
end

function prefab_probe_vector_from_nested_value(value)
    local direct = prefab_probe_vector_from_value(value)
    if direct then
        return direct, nil
    end

    for _, property_name in ipairs({ "Location", "Translation", "RelativeLocation" }) do
        local nested = prefab_probe_nested_value(value, property_name)
        local vector = prefab_probe_vector_from_value(nested)
        if vector then
            return vector, property_name
        end
    end

    return nil, nil
end

function prefab_probe_call_zero_arg(object, method_name)
    if not is_valid_object(object) then
        return nil, "invalid-object"
    end

    local lookup_ok, member = pcall(function()
        return object[method_name]
    end)
    if lookup_ok and is_valid_object(member) then
        local call_ok, result = pcall(function()
            return object:CallFunction(member)
        end)
        if call_ok then
            return result, nil
        end
        return nil, prefab_probe_compact(result)
    end

    if lookup_ok and type(member) == "function" then
        local call_ok, result = pcall(function()
            return member(object)
        end)
        if call_ok then
            return result, nil
        end
        return nil, prefab_probe_compact(result)
    end

    local direct_ok, result = pcall(function()
        return object[method_name](object)
    end)
    if direct_ok then
        return result, nil
    end

    return nil, lookup_ok and "method-not-callable" or prefab_probe_compact(member)
end

function prefab_probe_object_location(object)
    local attempts = {}

    if PREFAB_DUMP_CALL_LOCATION_UFUNCTIONS then
        for _, method_name in ipairs({ "K2_GetActorLocation", "GetActorLocation" }) do
            local result, error_text = prefab_probe_call_zero_arg(object, method_name)
            local vector, nested_property = prefab_probe_vector_from_nested_value(result)
            if vector then
                local source = method_name
                if nested_property then
                    source = source .. "." .. nested_property
                end
                return vector, source, attempts
            end
            table.insert(
                attempts,
                method_name
                    .. "="
                    .. prefab_probe_compact(value_to_string(result) ~= "" and value_to_string(result) or error_text)
            )
        end
    else
        table.insert(attempts, "K2_GetActorLocation=skipped-unsafe-struct-return")
        table.insert(attempts, "GetActorLocation=skipped-unsafe-struct-return")
    end

    if not PREFAB_DUMP_READ_OBJECT_PROPERTIES then
        table.insert(attempts, "ObjectProperties=skipped-unsafe-property-read")
        return nil, "skipped-unsafe-property-read", attempts
    end

    local root_component = try_get_property_value(object, "RootComponent")
    if is_valid_object(root_component) then
        for _, property_name in ipairs({ "RelativeLocation", "ComponentToWorld", "ComponentVelocity" }) do
            local result = try_get_property_value(root_component, property_name)
            local vector, nested_property = prefab_probe_vector_from_nested_value(result)
            if vector then
                local source = "RootComponent." .. property_name
                if nested_property then
                    source = source .. "." .. nested_property
                end
                return vector, source, attempts
            end
            table.insert(
                attempts,
                "RootComponent." .. property_name .. "=" .. prefab_probe_compact(value_to_string(result))
            )
        end
    else
        table.insert(attempts, "RootComponent=unavailable")
    end

    for _, property_name in ipairs({ "Location", "RelativeLocation", "ReplicatedMovement" }) do
        local result = try_get_property_value(object, property_name)
        local vector, nested_property = prefab_probe_vector_from_nested_value(result)
        if vector then
            local source = property_name
            if nested_property then
                source = source .. "." .. nested_property
            end
            return vector, source, attempts
        end
        table.insert(attempts, property_name .. "=" .. prefab_probe_compact(value_to_string(result)))
    end

    return nil, "unresolved", attempts
end

function prefab_probe_parse_classes(raw)
    local classes = {}
    local seen = {}
    local cleaned = trim(tostring(raw or ""))
    if cleaned == "" then
        cleaned = "BrickGridDynamicActor,Entity_DynamicBrickGrid,BP_Entity_Wheel_Deep1_C,BP_Entity_Wheel_Deep2_C,BP_Entity_Wheel_C"
    end

    for token in cleaned:gmatch("[^,%s]+") do
        local class_name = trim(token)
        if class_name ~= "" and not seen[class_name] then
            seen[class_name] = true
            table.insert(classes, class_name)
        end
    end

    return classes
end

function prefab_probe_collect_objects(class_name)
    local objects = {}
    local seen = {}
    local max_objects = 12

    local function add_object(object)
        if not is_valid_object(object) then
            return
        end
        if type(object.HasAnyFlags) == "function" then
            local flags_ok, has_banned_flags = pcall(function()
                return object:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject)
            end)
            if flags_ok and has_banned_flags then
                return
            end
        end
        if #objects >= max_objects then
            return
        end
        local key = get_object_address_string(object) or tostring(object)
        if seen[key] then
            return
        end
        seen[key] = true
        table.insert(objects, object)
    end

    if type(FindAllOf) == "function" then
        local ok, found = pcall(FindAllOf, class_name)
        if ok and type(found) == "table" then
            for _, object in ipairs(found) do
                add_object(object)
                if #objects >= max_objects then
                    break
                end
            end
        end
    end

    if type(FindObjects) == "function" then
        local banned_flags = EObjectFlags.RF_ClassDefaultObject | EObjectFlags.RF_ArchetypeObject
        local ok, found = pcall(function()
            return FindObjects(8, nil, class_name, EObjectFlags.RF_NoFlags, banned_flags, false)
        end)
        if ok and type(found) == "table" then
            for _, object in ipairs(found) do
                add_object(object)
                if #objects >= max_objects then
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

function prefab_probe_find_object(class_name)
    local object = find_first_valid(class_name)
    if is_valid_object(object) then
        return object, "FindFirstOf(" .. tostring(class_name) .. ")"
    end

    if type(prefab_probe_collect_objects) == "function" then
        local collect_ok, objects = pcall(prefab_probe_collect_objects, class_name)
        if collect_ok and type(objects) == "table" then
            for _, candidate in ipairs(objects) do
                if is_valid_object(candidate) then
                    return candidate, "prefab_probe_collect_objects(" .. tostring(class_name) .. ")"
                end
            end
        end
    end

    return nil, "unavailable"
end

function prefab_probe_object_flag_summary(object)
    if not is_valid_object(object) then
        return "valid=false"
    end

    local parts = { "valid=true" }
    if type(object.IsAnyClass) == "function" then
        local ok, is_any_class = pcall(function()
            return object:IsAnyClass()
        end)
        table.insert(parts, "is_any_class=" .. tostring(ok and is_any_class or false))
    end
    if type(object.IsClass) == "function" then
        local ok, is_class = pcall(function()
            return object:IsClass()
        end)
        table.insert(parts, "is_class=" .. tostring(ok and is_class or false))
    end
    if type(object.HasAnyFlags) == "function" then
        local flag_checks = {
            { "cdo", EObjectFlags.RF_ClassDefaultObject },
            { "archetype", EObjectFlags.RF_ArchetypeObject },
            { "transient", EObjectFlags.RF_Transient },
            { "was_loaded", EObjectFlags.RF_WasLoaded },
        }
        for _, entry in ipairs(flag_checks) do
            local ok, has_flag = pcall(function()
                return object:HasAnyFlags(entry[2])
            end)
            table.insert(parts, entry[1] .. "=" .. tostring(ok and has_flag or false))
        end
    end
    return table.concat(parts, " ")
end

function prefab_probe_append_raw_value_lines(lines, prefix, value)
    if value == nil then
        table.insert(lines, prefix .. "=nil")
        return
    end

    table.insert(lines, prefix .. "=" .. prefab_probe_compact(value_to_string(value)))

    if type(value) ~= "userdata" then
        return
    end

    if type(value.GetAddress) == "function" then
        local ok, address = pcall(function()
            return value:GetAddress()
        end)
        if ok and address ~= nil then
            table.insert(lines, prefix .. ".address=" .. tostring(address))
        end
    end

    if type(value.GetSize) == "function" then
        local ok, size = pcall(function()
            return value:GetSize()
        end)
        if ok and size ~= nil then
            table.insert(lines, prefix .. ".size=" .. tostring(size))
        end
    end

    if type(value.GetPropertyName) == "function" then
        local ok, property_name = pcall(function()
            return value:GetPropertyName()
        end)
        if ok and property_name ~= nil and tostring(property_name) ~= "" then
            table.insert(lines, prefix .. ".property=" .. tostring(property_name))
        end
    end

    if type(value.ReadBytesHex) == "function" then
        local ok, bytes = pcall(function()
            return value:ReadBytesHex()
        end)
        if ok and bytes ~= nil and tostring(bytes) ~= "" then
            table.insert(lines, prefix .. ".bytes=" .. tostring(bytes))
        end
    end
end

function prefab_probe_append_object_property_lines(lines, prefix, object, property_names)
    if not is_valid_object(object) then
        return
    end

    for _, property_name in ipairs(property_names or {}) do
        local value = try_get_property_value(object, property_name)
        prefab_probe_append_raw_value_lines(lines, prefix .. "." .. tostring(property_name), value)
    end
end

function dump_prefab_actor_locations(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "DumpPrefabActors is disabled by default on Brickadia Windows. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to enable it."
    end

    local classes = prefab_probe_parse_classes(spec)
    local lines = {
        "Prefab actor dump classes=" .. table.concat(classes, ","),
        "location_ufunctions=" .. (PREFAB_DUMP_CALL_LOCATION_UFUNCTIONS and "enabled" or "disabled"),
        "object_property_reads=" .. (PREFAB_DUMP_READ_OBJECT_PROPERTIES and "enabled" or "disabled"),
    }
    local total = 0

    for _, class_name in ipairs(classes) do
        local objects = prefab_probe_collect_objects(class_name)
        table.insert(lines, "class " .. class_name .. " count=" .. tostring(#objects))
        for index, object in ipairs(objects) do
            total = total + 1
            local location, source, attempts = prefab_probe_object_location(object)
            local actor_class = "unknown"
            local class_ok, class_object = pcall(function()
                return object:GetClass()
            end)
            if class_ok and is_valid_object(class_object) then
                actor_class = get_object_short_name(class_object, "unknown")
            end

            local location_text = "unresolved"
            if location then
                location_text = string.format("x=%.3f y=%.3f z=%.3f", location.x, location.y, location.z)
            end

            table.insert(
                lines,
                string.format(
                    "actor[%d] requested=%s class=%s addr=%s name=%s location=%s source=%s attempts=%s",
                    total,
                    class_name,
                    actor_class,
                    get_object_address_string(object) or "",
                    get_object_short_name(object, ""),
                    location_text,
                    tostring(source or ""),
                    prefab_probe_compact(table.concat(attempts or {}, ";"))
                )
            )
            table.insert(lines, "actor[" .. tostring(total) .. "].flags=" .. prefab_probe_object_flag_summary(object))
            if PREFAB_DUMP_READ_OBJECT_PROPERTIES then
                prefab_probe_append_object_property_lines(lines, "actor[" .. tostring(total) .. "].raw", object, {
                    "RootComponent",
                    "Location",
                    "RelativeLocation",
                    "ReplicatedMovement",
                    "AttachmentReplication",
                    "bReplicateMovement",
                    "bIsPhysicsGrid",
                    "BrickGrid",
                    "BrickGridComponent",
                    "Grid",
                    "Owner",
                    "ParentActor",
                })
            else
                table.insert(lines, "actor[" .. tostring(total) .. "].raw.properties=skipped-unsafe-property-read")
            end
        end
    end

    return table.concat(lines, "\n")
end

function describe_prefab_runtime(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "DescribePrefabRuntime is disabled by default on Brickadia Windows. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to enable it."
    end

    local class_spec = trim(tostring(spec or ""))
    if class_spec == "" then
        class_spec = table.concat({
            "PlayerController",
            "BP_PlayerController_C",
            "BRPlayerController",
            "BRTool_Placer",
            "BRTool_Placer_C",
            "Tool_Placer_C",
            "BP_Tool_Placer_C",
            "BRPrefabCache",
            "BRWorldManager",
            "BrickGridActor",
            "BrickGridDynamicActor",
            "Entity_DynamicBrickGrid",
            "BP_Entity_Wheel_Deep1_C",
            "BP_Entity_Wheel_Deep2_C",
            "BP_Entity_Wheel_C",
        }, ",")
    end

    local classes = prefab_probe_parse_classes(class_spec)
    local lines = {
        "Prefab runtime classes=" .. table.concat(classes, ","),
        "location_ufunctions=" .. (PREFAB_DUMP_CALL_LOCATION_UFUNCTIONS and "enabled" or "disabled"),
        "object_property_reads=" .. (PREFAB_DUMP_READ_OBJECT_PROPERTIES and "enabled" or "disabled"),
    }
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}

    table.insert(lines, "hooks_registered=" .. tostring(state.registered == true))
    table.insert(lines, "capture_events=" .. tostring(#(state.hooks or {})))
    table.insert(lines, "last_capture=" .. (state.last and tostring(state.last.kind or "unknown") or "<none>"))
    table.insert(lines, "last_hook_context_valid=" .. tostring(is_valid_object(last_hook_context)))
    table.insert(lines, "last_hook_world_valid=" .. tostring(is_valid_object(last_hook_world)))
    table.insert(lines, "last_hook_game_mode_valid=" .. tostring(is_valid_object(last_hook_game_mode)))
    table.insert(lines, "cached_command_context_valid=" .. tostring(select(1, get_cached_command_context()) ~= nil))

    local total = 0
    for _, class_name in ipairs(classes) do
        local objects = prefab_probe_collect_objects(class_name)
        table.insert(lines, "class " .. tostring(class_name) .. " count=" .. tostring(#objects))
        for index, object in ipairs(objects) do
            total = total + 1
            local object_class = "unknown"
            local class_ok, class_object = pcall(function()
                return object:GetClass()
            end)
            if class_ok and is_valid_object(class_object) then
                object_class = get_object_short_name(class_object, "unknown")
            end

            table.insert(
                lines,
                string.format(
                    "object[%d] requested=%s index=%d class=%s addr=%s name=%s",
                    total,
                    tostring(class_name),
                    index,
                    object_class,
                    get_object_address_string(object) or "",
                    get_object_short_name(object, "")
                )
            )
            table.insert(lines, "object[" .. tostring(total) .. "].flags=" .. prefab_probe_object_flag_summary(object))

            if tostring(class_name):find("Actor", 1, true)
                or tostring(class_name):find("Entity_", 1, true)
                or tostring(class_name):find("Wheel", 1, true) then
                local location, source, attempts = prefab_probe_object_location(object)
                if location then
                    table.insert(
                        lines,
                        string.format(
                            "object[%d].location=x=%.3f y=%.3f z=%.3f source=%s",
                            total,
                            location.x,
                            location.y,
                            location.z,
                            tostring(source or "")
                        )
                    )
                else
                    table.insert(
                        lines,
                        "object[" .. tostring(total) .. "].location=unresolved attempts="
                            .. prefab_probe_compact(table.concat(attempts or {}, ";"))
                    )
                end

                if PREFAB_DUMP_READ_OBJECT_PROPERTIES then
                    prefab_probe_append_object_property_lines(lines, "object[" .. tostring(total) .. "].raw", object, {
                        "RootComponent",
                        "Location",
                        "RelativeLocation",
                        "ReplicatedMovement",
                        "AttachmentReplication",
                        "bReplicateMovement",
                        "bIsPhysicsGrid",
                        "BrickGrid",
                        "BrickGridComponent",
                        "Grid",
                        "Owner",
                        "ParentActor",
                    })
                else
                    table.insert(lines, "object[" .. tostring(total) .. "].raw.properties=skipped-unsafe-property-read")
                end
            end
        end
    end

    return table.concat(lines, "\n")
end

local function add_console_exec_candidate(candidates, seen, label, object)
    if not is_valid_object(object) then
        return
    end

    local full_name = get_object_label(object, label)
    if seen[full_name] then
        return
    end

    seen[full_name] = true
    table.insert(candidates, {
        label = label,
        full_name = full_name,
        object = object,
    })
end

local function collect_console_exec_candidates()
    local candidates = {}
    local seen = {}

    if type(UEHelpers) == "table" then
        if type(UEHelpers.GetGameModeBase) == "function" then
            local ok, game_mode = pcall(UEHelpers.GetGameModeBase)
            if ok then
                add_console_exec_candidate(candidates, seen, "UEHelpers.GetGameModeBase()", game_mode)
                if is_valid_object(game_mode) then
                    add_console_exec_candidate(
                        candidates,
                        seen,
                        "UEHelpers.GetGameModeBase().GameSession",
                        try_get_property_value(game_mode, "GameSession")
                    )
                end
            end
        end

        if type(UEHelpers.GetGameStateBase) == "function" then
            local ok, game_state = pcall(UEHelpers.GetGameStateBase)
            if ok then
                add_console_exec_candidate(candidates, seen, "UEHelpers.GetGameStateBase()", game_state)
            end
        end

        if type(UEHelpers.GetWorld) == "function" then
            local ok, world = pcall(UEHelpers.GetWorld)
            if ok then
                add_console_exec_candidate(candidates, seen, "UEHelpers.GetWorld()", world)
            end
        end
    end

    local cached_objects = select(1, get_cached_game_objects())
    if cached_objects then
        add_console_exec_candidate(candidates, seen, "cached.game_mode", cached_objects.game_mode)
        add_console_exec_candidate(candidates, seen, "cached.game_session", cached_objects.game_session)
        add_console_exec_candidate(candidates, seen, "cached.game_state", cached_objects.game_state)
        add_console_exec_candidate(candidates, seen, "cached.world", cached_objects.world)
    end

    for _, name in ipairs(CONTEXT_CANDIDATES) do
        add_console_exec_candidate(candidates, seen, "FindFirstOf(" .. name .. ")", find_first_valid(name))
    end

    return candidates
end

function describe_console_exec_candidates()
    local candidates = collect_console_exec_candidates()
    local lines = { "Console exec candidates=" .. tostring(#candidates) }

    for index, candidate in ipairs(candidates) do
        local object = candidate.object
        local class_name = "unknown"
        local short_name = ""
        if is_valid_object(object) then
            short_name = get_object_short_name(object, "")
            local class_ok, class_object = pcall(function()
                return object:GetClass()
            end)
            if class_ok and is_valid_object(class_object) then
                class_name = get_object_short_name(class_object, "unknown")
            end
        end

        table.insert(
            lines,
            string.format(
                "candidate[%d] label=%s addr=%s class=%s name=%s full_name=%s flags=%s",
                index,
                tostring(candidate.label or ""),
                get_object_address_string(object) or "",
                tostring(class_name),
                tostring(short_name),
                prefab_probe_compact(tostring(candidate.full_name or "")),
                prefab_probe_object_flag_summary(object)
            )
        )
    end

    return table.concat(lines, "\n")
end

local function compact_probe_value(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n]+", " ")
    text = text:gsub("%s+", " ")
    return trim(text)
end

local function probe_console_exec(command)
    local lines = { "Probe target: " .. tostring(command) }
    local skip_cached_console_exec = trim(tostring(command or "")):match("^Chat%.") ~= nil

    local function push(label, success, detail)
        table.insert(
            lines,
            string.format(
                "%s success=%s detail=%s",
                tostring(label),
                success and "true" or "false",
                compact_probe_value(detail)
            )
        )
    end

    if type(OmeggaHasCachedEngineExecContext) == "function" then
        local ok, has_context = pcall(OmeggaHasCachedEngineExecContext)
        push("engine_context_available", ok and has_context or false, ok and "ok" or has_context)
    else
        push("engine_context_available", false, "helper missing")
    end

    if type(OmeggaExecuteCachedEngineExec) == "function" then
        local ok, success, output = pcall(OmeggaExecuteCachedEngineExec, command)
        push("engine_exec", ok and success or false, ok and (output or "") or success)
    else
        push("engine_exec", false, "helper missing")
    end

    if type(OmeggaHasCachedCommandContext) == "function" then
        local ok, has_context = pcall(OmeggaHasCachedCommandContext)
        push("cached_command_context_available", ok and has_context or false, ok and "ok" or has_context)
    else
        push("cached_command_context_available", false, "helper missing")
    end

    if skip_cached_console_exec then
        push(
            "cached_console_exec",
            false,
            "skipped because ProcessConsoleExec crashes on Chat.* for this Brickadia build"
        )
    elseif type(OmeggaExecuteCachedConsoleExec) == "function" then
        local ok, success, output = pcall(OmeggaExecuteCachedConsoleExec, command)
        push("cached_console_exec", ok and success or false, ok and (output or "") or success)
    else
        push("cached_console_exec", false, "helper missing")
    end

    if skip_cached_console_exec then
        push(
            "kismet_console_exec",
            false,
            "skipped because side-effect chat probes are limited to GameEngine::Exec"
        )
    elseif type(OmeggaExecuteKismetConsoleCommand) == "function" then
        local ok, success, output = pcall(OmeggaExecuteKismetConsoleCommand, command)
        push("kismet_console_exec", ok and success or false, ok and (output or "") or success)
    else
        push("kismet_console_exec", false, "helper missing")
    end

    return table.concat(lines, "\n")
end

local function get_cached_player_states(game_state)
    local function add_player_state_candidate(results, seen, player_state)
        if not is_valid_object(player_state) then
            return
        end

        local full_name = get_object_label(player_state, tostring(player_state))
        if seen[full_name] then
            return
        end

        local user_name = trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
            "UserName",
            "PlayerNamePrivate",
            "PlayerName",
            "DisplayName",
        }))))
        local owner = try_get_property_value(player_state, "Owner")

        if user_name == "" and not is_valid_object(owner) then
            return
        end

        seen[full_name] = true
        table.insert(results, player_state)
    end

    local function collect_player_states_from_find_all(results, seen)
        if type(FindAllOf) ~= "function" then
            return
        end

        for _, class_name in ipairs({ "BRPlayerState", "PlayerState", "BP_PlayerState_C" }) do
            local ok, found = pcall(FindAllOf, class_name)
            if ok and type(found) == "table" then
                for _, player_state in ipairs(found) do
                    add_player_state_candidate(results, seen, player_state)
                end
            end
        end
    end

    local results = {}
    local seen = {}

    if not is_valid_object(game_state) then
        collect_player_states_from_find_all(results, seen)
        return results
    end

    local array_ok, player_array = pcall(function()
        return game_state.PlayerArray
    end)
    if array_ok and player_array ~= nil then
        local count_ok, player_count = pcall(function()
            return #player_array
        end)
        if count_ok and type(player_count) == "number" and player_count > 0 then
            for index = 1, player_count do
                local player_state_ok, player_state = pcall(function()
                    return player_array[index]
                end)
                if player_state_ok then
                    add_player_state_candidate(results, seen, player_state)
                end
            end
        end
    end

    if #results == 0 then
        collect_player_states_from_find_all(results, seen)
    end

    return results
end

local function get_direct_game_state_player_states(game_state)
    local results = {}
    local seen = {}

    if not is_valid_object(game_state) then
        return results
    end

    local array_ok, player_array = pcall(function()
        return game_state.PlayerArray
    end)
    if not array_ok or player_array == nil then
        return results
    end

    local count_ok, player_count = pcall(function()
        return #player_array
    end)
    if not count_ok or type(player_count) ~= "number" or player_count <= 0 then
        return results
    end

    for index = 1, player_count do
        local player_state_ok, player_state = pcall(function()
            return player_array[index]
        end)
        if player_state_ok and is_valid_object(player_state) then
            local full_name = get_object_label(player_state, tostring(player_state))
            if not seen[full_name] then
                seen[full_name] = true
                table.insert(results, player_state)
            end
        end
    end

    return results
end

local function build_synthetic_object_path(class_name, object_name)
    return class_name .. " " .. SYNTHETIC_PATH_PREFIX .. object_name
end

local function get_player_state_record(player_state, index, uptime_seconds)
    local raw_player_id = value_to_number(select(1, try_get_first_property_value(player_state, {
        "PlayerId",
        "PlayerID",
        "PlayerNum",
        "ControllerId",
    })))
    local numeric_id = math.max(0, math.floor(raw_player_id or 0)) + index

    local player_name = trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
        "UserName",
        "PlayerNamePrivate",
        "PlayerName",
        "DisplayName",
    }))))
    if player_name == "" then
        player_name = "Player " .. tostring(index)
    end

    local exact_ping = value_to_number(select(1, try_get_first_property_value(player_state, {
        "ExactPing",
        "Ping",
    })))
    local compressed_ping = value_to_number(try_get_property_value(player_state, "CompressedPing"))
    local ping_ms = math.max(0, math.floor(exact_ping or ((compressed_ping or 0) * 4)))

    local start_time_seconds = value_to_number(select(1, try_get_first_property_value(player_state, {
        "StartTime",
        "ReplicatedJoinTime",
    })))
    local online_time_ms = 0
    if start_time_seconds ~= nil then
        online_time_ms = math.max(0, math.floor((uptime_seconds - start_time_seconds) * 1000))
    end

    local roles = trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
        "Roles",
        "RoleNames",
    }))))
    local address = trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
        "SavedNetworkAddress",
        "NetworkAddress",
        "Address",
    }))))
    local unique_id = trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
        "UniqueId",
        "SessionId",
        "UserId",
        "PlayerId",
    }))))
    if unique_id == "" then
        unique_id = tostring(numeric_id)
    end

    local owner = try_get_property_value(player_state, "Owner")
    local pawn = try_get_property_value(player_state, "PawnPrivate")
        or try_get_property_value(player_state, "Pawn")
        or try_get_property_value(player_state, "Character")
        or (is_valid_object(owner) and try_get_property_value(owner, "Pawn") or nil)
        or (is_valid_object(owner) and try_get_property_value(owner, "AcknowledgedPawn") or nil)
        or (is_valid_object(owner) and try_get_property_value(owner, "Character") or nil)

    return {
        index = index,
        player_name = player_name,
        ping_ms = ping_ms,
        online_time_ms = online_time_ms,
        roles = roles,
        address = address,
        unique_id = unique_id,
        state_name = "BP_PlayerState_C_" .. tostring(SYNTHETIC_STATE_BASE + numeric_id),
        controller_name = "BP_PlayerController_C_" .. tostring(SYNTHETIC_CONTROLLER_BASE + numeric_id),
        pawn_name = "BP_FigureV2_C_" .. tostring(SYNTHETIC_CONTROLLER_BASE + 1000 + numeric_id),
        player_state = player_state,
        owner = owner,
        pawn = pawn,
    }
end

function get_player_state_chat_name(player_state)
    return trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
        "UserName",
        "PlayerNamePrivate",
        "PlayerName",
        "DisplayName",
    }))))
end

local function get_cached_player_state_records(game_state, world)
    local uptime_seconds = value_to_number(select(1, try_get_first_property_value(world, {
        "TimeSeconds",
        "RealTimeSeconds",
    }))) or 0
    if uptime_seconds <= 0 then
        local status_output = build_status_output_from_log()
        if status_output ~= nil then
            local log_path = get_brickadia_log_path()
            local contents = log_path and read_file(log_path) or nil
            local latest_world_start = nil
            if contents then
                for line in contents:gmatch("[^\r\n]+") do
                    if line:match("LogWorld: Bringing World .+ up for play") then
                        latest_world_start = parse_log_timestamp(line)
                    end
                end
            end
            if latest_world_start then
                uptime_seconds = math.max(0, os.time() - latest_world_start)
            end
        end
    end
    local player_states = get_cached_player_states(game_state)
    local records = {}

    for index, player_state in ipairs(player_states) do
        table.insert(records, get_player_state_record(player_state, index, uptime_seconds))
    end

    return records, uptime_seconds
end

local function build_status_output()
    -- CL13530 object-backed player status can crash while reading live
    -- PlayerState/Controller properties. Keep status log-backed and inert.
    local output, log_error = build_status_output_from_log()
    if output then
        return output
    end
    return nil, log_error
end

function build_status_output_unsafe()
    local objects, object_error = get_cached_game_objects()
    if not objects then
        local output, log_error = build_status_output_from_log()
        if output then
            return output
        end
        return nil, object_error or log_error
    end

    local world = objects.world
    local game_mode = objects.game_mode
    local game_state = objects.game_state
    local game_session = objects.game_session

    local server_name = trim(safe_value_to_string(select(1, try_get_first_property_value(game_session, {
        "ServerName",
        "SessionName",
        "ServerTitle",
    }))))
    if server_name == "" then
        server_name = trim(safe_value_to_string(select(1, try_get_first_property_value(game_state, {
            "ServerName",
            "SessionName",
        }))))
    end
    if server_name == "" then
        server_name = trim(safe_value_to_string(select(1, try_get_first_property_value(game_mode, {
            "ServerName",
            "SessionName",
        }))))
    end
    if server_name == "" then
        server_name = "Brickadia Windows UE4SS"
    end

    local description = trim(safe_value_to_string(select(1, try_get_first_property_value(game_session, {
        "Description",
        "ServerDescription",
        "SessionDescription",
    }))))
    if description == "" then
        description = trim(safe_value_to_string(select(1, try_get_first_property_value(game_state, {
            "Description",
            "ServerDescription",
        }))))
    end

    local bricks = value_to_number(select(1, try_get_first_property_value(game_state, {
        "NumBricks",
        "BrickCount",
    }))) or 0
    local components = value_to_number(select(1, try_get_first_property_value(game_state, {
        "NumComponents",
        "ComponentCount",
    }))) or 0

    local player_records, uptime_seconds = get_cached_player_state_records(game_state, world)
    local lines = {
        "Server Name: " .. server_name,
        "Description: " .. description,
        "Bricks: " .. tostring(math.floor(bricks)),
        "Components: " .. tostring(math.floor(components)),
        "Time: " .. format_duration_ms(uptime_seconds * 1000),
    }

    local header = table.concat({
        "* ",
        pad_status_column("Name", 24),
        " | ",
        pad_status_column("Ping", 6),
        " | ",
        pad_status_column("Time", 8),
        " | ",
        pad_status_column("Roles", 18),
        " | ",
        pad_status_column("Address", 22),
        " | ",
        pad_status_column("Id", 32),
    })
    table.insert(lines, header)

    for _, player in ipairs(player_records) do
        table.insert(lines, table.concat({
            "* ",
            pad_status_column(player.player_name, 24),
            " | ",
            pad_status_column(format_duration_ms(player.ping_ms), 6),
            " | ",
            pad_status_column(format_duration_ms(player.online_time_ms), 8),
            " | ",
            pad_status_column(player.roles, 18),
            " | ",
            pad_status_column(player.address, 22),
            " | ",
            pad_status_column(player.unique_id, 32),
        }))
    end

    return table.concat(lines, "\n")
end

local function build_brplayerstate_username_output()
    local player_records = get_omegga_compat_player_state_records()
    local lines = {}
    for _, player in ipairs(player_records) do
        table.insert(
            lines,
            tostring(player.index - 1)
                .. ") "
                .. build_synthetic_object_path("BP_PlayerState_C", player.state_name)
                .. ".UserName = "
                .. player.player_name
        )
    end

    return table.concat(lines, "\n")
end

local function build_brplayerstate_owner_output(target_state_name)
    local player_records = get_omegga_compat_player_state_records()
    local lines = {}
    for _, player in ipairs(player_records) do
        if target_state_name == nil or target_state_name == player.state_name then
            table.insert(
                lines,
                tostring(player.index - 1)
                    .. ") "
                    .. build_synthetic_object_path("BP_PlayerState_C", player.state_name)
                    .. ".Owner = BP_PlayerController_C'"
                    .. SYNTHETIC_PATH_PREFIX
                    .. player.controller_name
                    .. "'"
            )
        end
    end

    return table.concat(lines, "\n")
end

function get_omegga_compat_player_state_records()
    local objects = select(1, get_cached_game_objects())
    if objects then
        local cached_records = get_cached_player_state_records(objects.game_state, objects.world)
        if #cached_records > 0 then
            return cached_records
        end
    end

    -- Join/controller recovery is event-driven and only reaches this path when
    -- the cached game-state list is unavailable. Keep the fallback bounded to
    -- the existing player-state classes instead of leaving Omegga's player
    -- records permanently without controller and state identifiers.
    return get_cached_player_state_records(nil, nil)
end

function build_bp_playercontroller_pawn_output(target_controller_name)
    local player_records = get_omegga_compat_player_state_records()
    local lines = {}
    for _, player in ipairs(player_records) do
        if target_controller_name == nil or target_controller_name == "" or target_controller_name == player.controller_name then
            local pawn_text = "None"
            if is_valid_object(player.pawn) then
                pawn_text = "BP_FigureV2_C'" .. SYNTHETIC_PATH_PREFIX .. player.pawn_name .. "'"
            end
            table.insert(
                lines,
                tostring(player.index - 1)
                    .. ") BP_PlayerController_C "
                    .. SYNTHETIC_PATH_PREFIX
                    .. player.controller_name
                    .. ".Pawn = "
                    .. pawn_text
            )
        end
    end

    return table.concat(lines, "\n")
end

function build_bp_figure_dead_output(target_pawn_name)
    local player_records = get_omegga_compat_player_state_records()
    local lines = {}
    for _, player in ipairs(player_records) do
        if is_valid_object(player.pawn)
            and (target_pawn_name == nil or target_pawn_name == "" or target_pawn_name == player.pawn_name) then
            local dead_value = try_get_property_value(player.pawn, "bIsDead")
            local dead_text = "False"
            if dead_value == true or tostring(dead_value) == "true" or tostring(dead_value) == "True" then
                dead_text = "True"
            end
            table.insert(
                lines,
                tostring(player.index - 1)
                    .. ") BP_FigureV2_C "
                    .. SYNTHETIC_PATH_PREFIX
                    .. player.pawn_name
                    .. ".bIsDead = "
                    .. dead_text
            )
        end
    end

    return table.concat(lines, "\n")
end

function build_collision_cylinder_location_output(target_pawn_name)
    if os.getenv("OMEGGA_UE4SS_ALLOW_UNSAFE_POSITION_PROBES") ~= "1" then
        return nil, "position probes are disabled"
    end

    local player_records = get_omegga_compat_player_state_records()
    local lines = {}
    for _, player in ipairs(player_records) do
        if is_valid_object(player.pawn)
            and (target_pawn_name == nil or target_pawn_name == "" or target_pawn_name == player.pawn_name) then
            local vector = nil
            if type(OmeggaResolveObjectLocationForSpawn) == "function" then
                vector = select(1, OmeggaResolveObjectLocationForSpawn(player.pawn))
            end
            if vector then
                table.insert(
                    lines,
                    tostring(player.index - 1)
                        .. ") CapsuleComponent "
                        .. SYNTHETIC_PATH_PREFIX
                        .. player.pawn_name
                        .. ".CollisionCylinder.RelativeLocation = (X="
                        .. string.format("%.3f", value_to_number(vector.x) or 0)
                        .. ",Y="
                        .. string.format("%.3f", value_to_number(vector.y) or 0)
                        .. ",Z="
                        .. string.format("%.3f", value_to_number(vector.z) or 0)
                        .. ")"
                )
            end
        end
    end

    return table.concat(lines, "\n")
end

local function describe_function_signature(func)
    if not func or not func.IsValid or not func:IsValid() then
        return "invalid"
    end

    local params = {}
    local ok = pcall(function()
        func:ForEachProperty(function(property)
            local property_name = get_property_name(property)
            local property_type = get_property_class_name(property)
            table.insert(params, property_name .. ":" .. property_type)
        end)
    end)

    if not ok then
        return "<signature unavailable>"
    end

    return table.concat(params, ", ")
end

local function append_hinted_functions(lines, label, object, hints, limit)
    if not is_valid_object(object) then
        return 0
    end

    local class = object:GetClass()
    if not is_valid_object(class) or type(class.ForEachFunction) ~= "function" then
        return 0
    end

    local added = 0
    local seen = {}
    class:ForEachFunction(function(func)
        local function_name = get_object_short_name(func, "unknown")
        local function_label = get_object_label(func, function_name)
        if seen[function_label] or not contains_any_hint(function_name, hints) then
            return false
        end

        seen[function_label] = true
        added = added + 1
        table.insert(lines, label .. " => " .. function_label .. " [" .. describe_function_signature(func) .. "]")
        if added >= (limit or 12) then
            return true
        end

        return false
    end)

    return added
end

local function describe_chat_value(value)
    if value == nil then
        return "nil"
    end

    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end

    if value_type == "userdata" and value.IsValid and type(value.IsValid) == "function" then
        local valid_ok, valid = pcall(function()
            return value:IsValid()
        end)
        if valid_ok and valid then
            local address = get_object_address_string(value)
            if address and address ~= "" then
                return address
            end
            return "userdata"
        end
    end

    return tostring(value)
end

local function add_chat_source(candidates, seen, label, object, executor)
    if not is_valid_object(object) then
        return
    end

    local address_key = get_object_address_string(object) or label
    if seen[address_key] then
        return
    end

    seen[address_key] = true
    table.insert(candidates, {
        label = label,
        object = object,
        executor = is_valid_object(executor) and executor or object,
    })
end

local function collect_chat_property_sources(candidates, seen, root_label, root_object, depth)
    if depth <= 0 or not is_valid_object(root_object) then
        return
    end

    local class = root_object:GetClass()
    if not is_valid_object(class) or type(class.ForEachProperty) ~= "function" then
        return
    end

    local ok = pcall(function()
        class:ForEachProperty(function(property)
            local property_name = get_property_name(property)
            if not contains_any_hint(property_name, CHAT_PROPERTY_HINTS) then
                return false
            end

            local property_value = try_get_property_value(root_object, property_name)
            if is_valid_object(property_value) then
                local child_label = root_label .. "." .. property_name
                add_chat_source(candidates, seen, child_label, property_value, root_object)
                collect_chat_property_sources(candidates, seen, child_label, property_value, depth - 1)
            end

            return false
        end)
    end)

    if not ok then
        return
    end
end

local function build_chat_runtime_context(objects, message)
    local cached_context = is_valid_object(last_hook_context) and last_hook_context or nil

    local cached_executor = is_valid_object(last_hook_executor) and last_hook_executor or nil
    if not is_valid_object(cached_executor) and is_valid_object(cached_context) then
        cached_executor = cached_context
    end

    local context = {
        objects = objects,
        message = tostring(message or ""),
        player_state = nil,
        player_controller = nil,
        cheat_manager = nil,
        player_pawn = nil,
        engine = nil,
        game_instance = nil,
        cached_context = cached_context,
        cached_executor = cached_executor,
    }

    local function object_class_matches(object, hint)
        if not is_valid_object(object) then
            return false
        end

        local class_ok, class_object = pcall(function()
            return object:GetClass()
        end)
        if not class_ok or not is_valid_object(class_object) then
            return false
        end

        local short_name = string.lower(get_object_short_name(class_object, ""))
        local full_name = string.lower(get_object_label(class_object, ""))
        local expected = string.lower(tostring(hint or ""))
        return short_name:find(expected, 1, true) ~= nil or full_name:find(expected, 1, true) ~= nil
    end

    if object_class_matches(context.cached_executor, "playercontroller") then
        context.player_controller = context.cached_executor
    elseif object_class_matches(context.cached_context, "playercontroller") then
        context.player_controller = context.cached_context
    end

    if object_class_matches(context.cached_executor, "cheatmanager") then
        context.cheat_manager = context.cached_executor
    elseif object_class_matches(context.cached_context, "cheatmanager") then
        context.cheat_manager = context.cached_context
    end

    local player_states = get_direct_game_state_player_states(objects.game_state)
    for _, player_state in ipairs(player_states) do
        if is_valid_object(player_state) then
            context.player_state = player_state
            local owner = try_get_property_value(player_state, "Owner")
            if is_valid_object(owner) then
                context.player_controller = owner
                context.cheat_manager = try_get_property_value(owner, "CheatManager")
                context.player_pawn = try_get_property_value(player_state, "PawnPrivate")
                    or try_get_property_value(owner, "Pawn")
                    or try_get_property_value(owner, "AcknowledgedPawn")
                break
            end
        end
    end

    if is_valid_object(context.player_controller) and not is_valid_object(context.cheat_manager) then
        context.cheat_manager = try_get_property_value(context.player_controller, "CheatManager")
    end

    if is_valid_object(context.player_controller) and not is_valid_object(context.player_pawn) then
        context.player_pawn = try_get_property_value(context.player_controller, "Pawn")
            or try_get_property_value(context.player_controller, "AcknowledgedPawn")
    end

    local engine_ok, engine = pcall(function()
        return UEHelpers.GetEngine()
    end)
    if engine_ok and is_valid_object(engine) then
        context.engine = engine
    end

    context.game_instance = try_get_property_value(objects.world, "OwningGameInstance")
        or try_get_property_value(objects.world, "GameInstance")

    return context
end

local function collect_chat_sources(objects, context)
    local candidates = {}
    local seen = {}

    add_chat_source(candidates, seen, "cached_executor", context.cached_executor, context.cached_executor)
    add_chat_source(candidates, seen, "cached_context", context.cached_context, context.cached_executor)
    add_chat_source(candidates, seen, "player_controller", context.player_controller, context.player_controller)
    add_chat_source(
        candidates,
        seen,
        "player_controller.CheatManager",
        context.cheat_manager,
        context.player_controller
    )
    add_chat_source(candidates, seen, "player_state", context.player_state, context.player_controller)
    add_chat_source(candidates, seen, "game_mode", objects.game_mode, objects.game_mode)
    add_chat_source(candidates, seen, "game_session", objects.game_session, objects.game_mode)
    add_chat_source(candidates, seen, "game_state", objects.game_state, objects.game_mode)
    add_chat_source(candidates, seen, "world", objects.world, objects.game_mode)

    return candidates
end

local function get_named_function_hits(object, function_name)
    if not is_valid_object(object) then
        return {}
    end

    local class = object:GetClass()
    if not is_valid_object(class) or type(class.ForEachFunction) ~= "function" then
        return {}
    end

    local hits = {}
    local expected = string.lower(tostring(function_name or ""))

    local ok, err = pcall(function()
        class:ForEachFunction(function(func)
            if not func then
                return false
            end

            local short_name = tostring(get_fname_string(func) or "")
            if short_name == "" or short_name:match("^FName#%d+$") then
                short_name = tostring(extract_terminal_name(get_full_name_string(func), "") or "")
            end
            if string.lower(short_name) ~= expected then
                return false
            end

            local function_label = tostring(get_full_name_string(func) or short_name or "")
            if function_label == "" then
                function_label = short_name
            end
            table.insert(hits, {
                func = func,
                function_name = short_name,
                function_path = normalize_hook_function_path(function_label),
                parameters = {},
            })

            return false
        end)
    end)
    if not ok then
        chat_trace("get_named_function_hits crashed error=" .. tostring(err))
    end

    return hits
end

local function log_chat_candidate(source_label, hit)
    local key = source_label .. " => " .. tostring(hit.function_path)
    if chat_logged_candidates[key] then
        return
    end

    chat_logged_candidates[key] = true
    chat_trace(
        "candidate "
            .. source_label
            .. " => "
            .. tostring(hit.function_path)
            .. " ["
            .. describe_function_parameters(hit.parameters)
            .. "]"
    )
end

local function register_chat_function_hook(function_path)
    local hook_path = normalize_hook_function_path(function_path)
    if chat_hook_attempts[hook_path] or type(RegisterHook) ~= "function" then
        return false
    end

    chat_hook_attempts[hook_path] = true
    local callback_key = "chat_hook:" .. hook_path
    local callback = retain_callback(callback_key, function(Context, ...)
        local context_object = nil
        if Context and type(Context.get) == "function" then
            local context_ok, context_value = pcall(function()
                return Context:get()
            end)
            if context_ok and is_valid_object(context_value) then
                context_object = context_value
                remember_command_context_shallow(
                    context_value,
                    nil,
                    extract_short_name(hook_path),
                    "chat-function-hook"
                )
            end
        end

        observed_chat_function_name = extract_short_name(hook_path)
        observed_chat_function_path = hook_path
        observed_chat_context = context_object
        observed_chat_source = "hook"

        local args = {}
        local arg_count = math.min(select("#", ...), 6)
        for index = 1, arg_count do
            table.insert(args, describe_chat_value(select(index, ...)))
        end

        chat_trace(
            "hook "
                .. hook_path
                .. " context="
                .. get_object_label(context_object, "nil")
                .. " args="
                .. table.concat(args, " | ")
        )
    end)
    local ok, pre_id, post_id = pcall(RegisterHook, hook_path, callback)

    if ok and type(pre_id) == "number" and type(post_id) == "number" then
        chat_trace("registered hook " .. hook_path)
        return true
    end

    release_callback(callback_key)
    chat_trace("failed hook " .. hook_path .. " error=" .. tostring(pre_id))
    return false
end

local function ensure_chat_hooks_installed()
    local objects = select(1, get_cached_game_objects())
    if not objects then
        return 0
    end

    local context = build_chat_runtime_context(objects, "")
    local sources = collect_chat_sources(objects, context)
    local registered = 0

    for _, source in ipairs(sources) do
        for _, function_name in ipairs(CHAT_CANDIDATE_FUNCTIONS) do
            for _, hit in ipairs(get_named_function_hits(source.object, function_name)) do
                log_chat_candidate(source.label, hit)
                if register_chat_function_hook(hit.function_path) then
                    registered = registered + 1
                end
            end
        end
    end

    return registered
end

local function build_chat_argument_options(parameter, candidate, context)
    local property_class = string.lower(tostring(parameter.property_class or ""))
    local property_name = string.lower(tostring(parameter.name or ""))
    local object_class = string.lower(tostring(parameter.object_class or ""))
    local struct_name = string.lower(tostring(parameter.struct_name or ""))

    if property_name == "returnvalue" then
        return "__skip__", nil
    end

    if property_class:find("textproperty", 1, true) then
        local options = {}
        if type(FText) == "function" then
            local ok, value = pcall(FText, context.message)
            if ok then
                table.insert(options, value)
            end
        end
        table.insert(options, context.message)
        return options, nil
    end

    if property_class:find("strproperty", 1, true) then
        local options = {}
        if type(FString) == "function" then
            local ok, value = pcall(FString, context.message)
            if ok then
                table.insert(options, value)
            end
        end
        table.insert(options, context.message)
        return options, nil
    end

    if property_class:find("nameproperty", 1, true) then
        local seed = property_name:find("command", 1, true) and "broadcast" or "SERVER"
        local options = {}
        if type(FName) == "function" then
            local ok, value = pcall(FName, seed, EFindName and EFindName.FNAME_Add or 1)
            if ok then
                table.insert(options, value)
            end
        end
        table.insert(options, seed)
        return options, nil
    end

    if property_class:find("boolproperty", 1, true) then
        if property_name:find("system", 1, true)
            or property_name:find("broadcast", 1, true)
            or property_name:find("reliable", 1, true) then
            return { true, false }, nil
        end
        return { false, true }, nil
    end

    if property_class:find("byteproperty", 1, true)
        or property_class:find("intproperty", 1, true)
        or property_class:find("enumproperty", 1, true)
        or property_class:find("floatproperty", 1, true)
        or property_class:find("doubleproperty", 1, true) then
        return { 0 }, nil
    end

    if property_class:find("objectproperty", 1, true)
        or property_class:find("weakobjectproperty", 1, true)
        or property_class:find("softobjectproperty", 1, true)
        or property_class:find("classproperty", 1, true)
        or property_class:find("interfaceproperty", 1, true) then
        local options = {}
        local seen = {}
        local function push(value)
            if not is_valid_object(value) then
                return
            end
            local key = get_object_label(value, tostring(value))
            if seen[key] then
                return
            end
            seen[key] = true
            table.insert(options, value)
        end

        if object_class:find("playercontroller", 1, true) or property_name:find("controller", 1, true) then
            push(context.player_controller)
        end
        if object_class:find("playerstate", 1, true)
            or property_name:find("playerstate", 1, true)
            or property_name:find("sender", 1, true)
            or property_name:find("author", 1, true) then
            push(context.player_state)
        end
        if object_class:find("cheatmanager", 1, true) or property_name:find("cheat", 1, true) then
            push(context.cheat_manager)
        end
        if object_class:find("pawn", 1, true)
            or object_class:find("character", 1, true)
            or property_name:find("pawn", 1, true)
            or property_name:find("instigator", 1, true) then
            push(context.player_pawn)
        end
        if object_class:find("gamemode", 1, true) or property_name:find("gamemode", 1, true) then
            push(context.objects.game_mode)
        end
        if object_class:find("gamesession", 1, true) or property_name:find("session", 1, true) then
            push(context.objects.game_session)
        end
        if object_class:find("gamestate", 1, true)
            or property_name:find("gamestate", 1, true)
            or property_name:find("state", 1, true) then
            push(context.objects.game_state)
        end
        if object_class:find("world", 1, true) or property_name:find("world", 1, true) then
            push(context.objects.world)
        end
        if object_class:find("engine", 1, true) or property_name:find("engine", 1, true) then
            push(context.engine)
        end
        if property_name:find("context", 1, true) or property_name:find("executor", 1, true) then
            push(candidate.object)
            push(candidate.executor)
        end

        push(candidate.object)
        push(candidate.executor)

        if #options == 0 then
            if property_name == "ar" or property_name:find("output", 1, true) then
                return { nil }, nil
            end
            return nil, "No object value available for parameter " .. parameter.name
        end

        return options, nil
    end

    if property_class:find("structproperty", 1, true) then
        if struct_name:find("text", 1, true) then
            local options = {}
            if type(FText) == "function" then
                local ok, value = pcall(FText, context.message)
                if ok then
                    table.insert(options, value)
                end
            end
            table.insert(options, context.message)
            return options, nil
        end

        return nil, "Unsupported struct parameter " .. tostring(parameter.struct_name or parameter.name)
    end

    return nil, "Unsupported parameter " .. tostring(parameter.name) .. ":" .. tostring(parameter.property_class)
end

local function build_chat_argument_variants(candidate, context)
    local parameter_options = {}

    for _, parameter in ipairs(candidate.parameters or {}) do
        local options, reason = build_chat_argument_options(parameter, candidate, context)
        if options ~= "__skip__" then
            if not options then
                return nil, reason
            end
            table.insert(parameter_options, options)
        end
    end

    local variants = { {} }
    local max_variants = 8

    for _, options in ipairs(parameter_options) do
        local next_variants = {}
        for _, variant in ipairs(variants) do
            for _, value in ipairs(options) do
                local next_variant = {}
                for _, existing in ipairs(variant) do
                    table.insert(next_variant, existing)
                end
                table.insert(next_variant, value)
                table.insert(next_variants, next_variant)
                if #next_variants >= max_variants then
                    break
                end
            end
            if #next_variants >= max_variants then
                break
            end
        end
        variants = next_variants
    end

    return variants, nil
end

local function build_call_function_by_name_variants(candidate, context)
    local parameters = {}
    for _, parameter in ipairs(candidate.parameters or {}) do
        if string.lower(tostring(parameter.name or "")) ~= "returnvalue" then
            table.insert(parameters, parameter)
        end
    end

    if #parameters == 0 then
        return { candidate.function_name }, nil
    end

    if #parameters == 1 then
        local property_class = string.lower(tostring(parameters[1].property_class or ""))
        if property_class:find("textproperty", 1, true)
            or property_class:find("strproperty", 1, true)
            or property_class:find("nameproperty", 1, true) then
            return {
                candidate.function_name .. " " .. quote_name(context.message),
                candidate.function_name .. " \"" .. quote_name(context.message) .. "\"",
            }, nil
        end
    end

    return nil, "CallFunctionByNameWithArguments fallback only supports simple text signatures."
end

local function try_direct_chat_call(candidate, context)
    local variants, variant_error = build_chat_argument_variants(candidate, context)
    if not variants then
        return false, variant_error
    end

    local last_error = "no direct call variants were attempted"
    for index, variant in ipairs(variants) do
        local args = {}
        for _, value in ipairs(variant) do
            table.insert(args, describe_chat_value(value))
        end
        chat_trace(
            "attempt direct "
                .. candidate.function_path
                .. " via "
                .. candidate.object_label
                .. " variant="
                .. tostring(index)
                .. " args="
                .. table.concat(args, " | ")
        )

        local ok, result = pcall(function()
            return candidate.object:CallFunction(candidate.func, table.unpack(variant))
        end)

        if ok and result ~= false then
            remember_command_context(
                candidate.object,
                candidate.executor,
                candidate.function_name,
                "typed-chat-call"
            )
            observed_chat_function_name = candidate.function_name
            observed_chat_function_path = candidate.function_path
            observed_chat_context = candidate.object
            observed_chat_source = "bridge-direct"
            chat_trace(
                "attempt direct succeeded "
                    .. candidate.function_path
                    .. " via "
                    .. candidate.object_label
            )
            return true,
                "typed-chat-call:" .. candidate.object_label .. "->" .. candidate.function_name
        end

        last_error = ok and "returned false" or tostring(result)
        chat_trace("attempt direct failed " .. candidate.function_path .. " error=" .. tostring(last_error))
    end

    return false, last_error
end

local function invoke_native_call_by_name(object, command, executor)
    if call_by_name_helper_available == false then
        return false, nil, call_by_name_helper_error or "native helper unavailable"
    end

    if type(OmeggaCallFunctionByNameWithArguments) ~= "function" then
        call_by_name_helper_available = false
        call_by_name_helper_error = "native helper missing"
        return false, nil, "native helper missing"
    end

    local ok, success, output = pcall(
        OmeggaCallFunctionByNameWithArguments,
        object,
        command,
        executor or object
    )
    if not ok then
        local error_text = tostring(success)
        return false, nil, error_text
    end

    call_by_name_helper_available = true
    return true, success ~= false, output or ""
end

function OmeggaProbeCallByName(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "ProbeCallByName is disabled by default on Brickadia Windows because unresolved UE4SS signatures still make reflected invocation unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    local class_name, command = trim(tostring(spec or "")):match("^(%S+)%s+(.+)$")
    if not class_name or trim(command or "") == "" then
        return "probe-call-by-name requires: <ClassName> <FunctionName args...>"
    end

    local lines = {
        "Probe call-by-name: " .. tostring(class_name) .. " -> " .. tostring(command),
    }

    local ok, object = pcall(FindFirstOf, class_name)
    local target_source = "FindFirstOf(" .. tostring(class_name) .. ")"
    if not ok or not is_valid_object(object) then
        if type(prefab_probe_collect_objects) == "function" then
            local collect_ok, objects = pcall(prefab_probe_collect_objects, class_name)
            if collect_ok and type(objects) == "table" then
                for _, candidate in ipairs(objects) do
                    if is_valid_object(candidate) then
                        object = candidate
                        ok = true
                        target_source = "prefab_probe_collect_objects(" .. tostring(class_name) .. ")"
                        break
                    end
                end
            end
        end
    end
    if not ok or not is_valid_object(object) then
        table.insert(lines, "target=unavailable detail=" .. tostring(ok and object or object))
        return table.concat(lines, "\n")
    end

    table.insert(lines, "target=" .. get_object_label(object, class_name))
    table.insert(lines, "target_source=" .. target_source)

    local executors = {}
    local seen_executors = {}
    local function add_executor(label, value)
        if not is_valid_object(value) then
            return
        end

        local key = get_object_address_string(value) or label or tostring(value)
        if seen_executors[key] then
            return
        end

        seen_executors[key] = true
        table.insert(executors, { label = label, object = value })
    end

    add_executor("self", object)
    add_executor("cached_context", select(1, get_cached_command_context()))
    local objects = select(1, get_cached_game_objects())
    if objects then
        add_executor("game_mode", objects.game_mode)
        add_executor("game_session", objects.game_session)
        add_executor("game_state", objects.game_state)
        add_executor("world", objects.world)
    end

    if #executors == 0 then
        table.insert(lines, "executors=none")
        return table.concat(lines, "\n")
    end

    for _, executor in ipairs(executors) do
        local helper_ok, did_succeed, output_or_error = invoke_native_call_by_name(object, command, executor.object)
        table.insert(
            lines,
            tostring(executor.label)
                .. " helper_ok="
                .. tostring(helper_ok)
                .. " success="
                .. tostring(did_succeed)
                .. " detail="
                .. compact_probe_value(output_or_error)
        )
    end

    return table.concat(lines, "\n")
end

function OmeggaProbeFunctionSignature(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "ProbeFunctionSignature is disabled by default on Brickadia Windows because unresolved UE4SS signatures still make reflected lookup unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    local class_name, function_name = trim(tostring(spec or "")):match("^(%S+)%s+(.+)$")
    function_name = trim(function_name or "")
    if not class_name or function_name == "" then
        return "probe-function-signature requires: <ClassName> <FunctionName>"
    end

    local lines = {
        "Probe function signature: " .. tostring(class_name) .. " -> " .. tostring(function_name),
    }

    local object, object_source = prefab_probe_find_object(class_name)
    if not is_valid_object(object) then
        table.insert(lines, "target=unavailable detail=" .. tostring(object_source))
        return table.concat(lines, "\n")
    end

    table.insert(lines, "target=" .. get_object_label(object, class_name))
    table.insert(lines, "target_source=" .. tostring(object_source))

    local class = object:GetClass()
    if not is_valid_object(class) or type(class.ForEachFunction) ~= "function" then
        table.insert(lines, "class-functions=unavailable")
        return table.concat(lines, "\n")
    end

    local expected = string.lower(function_name)
    local count = 0
    local ok_iter, iter_error = pcall(function()
        class:ForEachFunction(function(func)
            local short_name = tostring(get_fname_string(func) or "")
            if short_name == "" or short_name:match("^FName#%d+$") then
                short_name = tostring(extract_terminal_name(get_full_name_string(func), "") or "")
            end

            if string.lower(short_name) ~= expected then
                return false
            end

            count = count + 1
            local function_label = tostring(get_full_name_string(func) or short_name or "")
            if function_label == "" then
                function_label = short_name
            end
            table.insert(
                lines,
                "hit[" .. tostring(count) .. "] "
                    .. normalize_hook_function_path(function_label)
                    .. " params=["
                    .. describe_function_parameters(build_function_parameters(func))
                    .. "]"
            )
            return false
        end)
    end)

    if not ok_iter then
        table.insert(lines, "iteration_error=" .. tostring(iter_error))
    end
    if count == 0 then
        table.insert(lines, "hits=0")
    end

    return table.concat(lines, "\n")
end

function OmeggaDescribeFunctionObject(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "DescribeFunctionObject is disabled by default on Brickadia Windows because unresolved UE4SS signatures still make reflected lookup unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    local function_name = trim(tostring(spec or ""))
    if function_name == "" then
        return "describe-function-object requires: <FunctionName> [MaxStructDepth] [MaxHits]"
    end

    local name_text, depth_text, hits_text = function_name:match("^(%S+)%s+(%d+)%s+(%d+)$")
    if name_text then
        function_name = trim(name_text)
    else
        name_text, depth_text = function_name:match("^(%S+)%s+(%d+)$")
        if name_text then
            function_name = trim(name_text)
        end
    end

    local max_depth = tonumber(depth_text or "") or 2
    local max_hits = tonumber(hits_text or "") or 16

    if type(OmeggaDescribeUFunctionSignature) ~= "function" then
        return "OmeggaDescribeUFunctionSignature helper missing; rebuild/install the patched UE4SS DLL."
    end

    local ok, output = pcall(OmeggaDescribeUFunctionSignature, function_name, max_depth, max_hits)
    if not ok then
        return "describe-function-object crashed: " .. tostring(output)
    end
    return tostring(output or "")
end

function OmeggaProbeFunctionFields(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "ProbeFunctionFields is disabled by default on Brickadia Windows because unresolved UE4SS signatures still make reflected lookup unsafe. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to re-enable it."
    end

    local class_name, function_name = trim(tostring(spec or "")):match("^(%S+)%s+(.+)$")
    function_name = trim(function_name or "")
    local max_fields = nil
    local parsed_function_name, parsed_limit = function_name:match("^(.-)%s+(%d+)$")
    if parsed_function_name and parsed_function_name ~= "" then
        function_name = trim(parsed_function_name)
        max_fields = tonumber(parsed_limit)
    end
    if not class_name or function_name == "" then
        return "probe-function-fields requires: <ClassName> <FunctionName> [MaxFields]"
    end

    local lines = {
        "Probe function fields: " .. tostring(class_name) .. " -> " .. tostring(function_name),
    }

    local object, object_source = prefab_probe_find_object(class_name)
    if not is_valid_object(object) then
        table.insert(lines, "target=unavailable detail=" .. tostring(object_source))
        return table.concat(lines, "\n")
    end

    table.insert(lines, "target=" .. get_object_label(object, class_name))
    table.insert(lines, "target_source=" .. tostring(object_source))

    local member_ok, func = pcall(function()
        return object[function_name]
    end)
    if not member_ok then
        table.insert(lines, "member_error=" .. tostring(func))
        return table.concat(lines, "\n")
    end
    if not is_valid_object(func) then
        table.insert(lines, "member=unavailable type=" .. tostring(type(func)))
        return table.concat(lines, "\n")
    end

    table.insert(lines, "function=" .. get_object_label(func, function_name))

    if type(func.ForEachProperty) ~= "function" then
        table.insert(lines, "properties=unavailable")
        return table.concat(lines, "\n")
    end

    local count = 0
    local iter_ok, iter_error = pcall(function()
        func:ForEachProperty(function(property)
            count = count + 1
            local property_ok, property_error = pcall(function()
                table.insert(
                    lines,
                    "param["
                        .. tostring(count)
                        .. "] "
                        .. tostring(get_property_name(property))
                        .. ":"
                        .. OmeggaDescribePropertyType(property)
                )

                local struct_lines = OmeggaDescribeStructFieldsFromProperty(property, 1, max_fields)
                for _, struct_line in ipairs(struct_lines) do
                    table.insert(lines, struct_line)
                end
            end)
            if not property_ok then
                table.insert(lines, "param_error[" .. tostring(count) .. "]=" .. tostring(property_error))
            end

            return max_fields and count >= max_fields
        end)
    end)

    if not iter_ok then
        table.insert(lines, "properties_error=" .. tostring(iter_error))
    elseif count == 0 then
        table.insert(lines, "properties=0")
    end

    return table.concat(lines, "\n")
end

function OmeggaForceConsoleExecutor(spec)
    local executor, command = trim(tostring(spec or "")):match("^(%S+)%s+(.+)$")
    command = trim(command or "")
    if not executor or command == "" then
        return "force-console-executor requires: <engine|cached|kismet|consolemanager> <command...>"
    end

    executor = string.lower(trim(executor))
    local consolemanager_offset = nil
    local consolemanager_offset_text = nil
    do
        local offset_text = executor:match("^consolemanager:(.+)$") or executor:match("^console:(.+)$")
        if offset_text then
            consolemanager_offset_text = trim(offset_text)
            local hex_digits = consolemanager_offset_text:match("^0x([0-9a-f]+)$")
            if hex_digits then
                consolemanager_offset = tonumber(hex_digits, 16)
            else
                consolemanager_offset = tonumber(consolemanager_offset_text)
            end
            if not consolemanager_offset then
                return "consolemanager invalid_offset=" .. tostring(consolemanager_offset_text)
            end
            executor = executor:match("^(.-):") or executor
        end
    end
    if executor == "engine" then
        if type(OmeggaExecuteCachedEngineExec) ~= "function" then
            return "engine helper missing"
        end
        local ok, success, output = pcall(OmeggaExecuteCachedEngineExec, command)
        return "engine ok=" .. tostring(ok) .. " success=" .. tostring(success) .. " detail=" .. trim(tostring(output or ""))
    end

    if executor == "cached" then
        if type(OmeggaExecuteCachedConsoleExec) ~= "function" then
            return "cached helper missing"
        end
        local ok, success, output = pcall(OmeggaExecuteCachedConsoleExec, command)
        return "cached ok=" .. tostring(ok) .. " success=" .. tostring(success) .. " detail=" .. trim(tostring(output or ""))
    end

    if executor == "kismet" then
        if type(OmeggaExecuteKismetConsoleCommand) ~= "function" then
            return "kismet helper missing"
        end
        local ok, success, output = pcall(OmeggaExecuteKismetConsoleCommand, command)
        return "kismet ok=" .. tostring(ok) .. " success=" .. tostring(success) .. " detail=" .. trim(tostring(output or ""))
    end

    if executor == "consolemanager" or executor == "console" then
        if type(OmeggaExecuteConsoleManagerInput) ~= "function" then
            return "consolemanager helper missing"
        end
        local ok, success, output
        if consolemanager_offset then
            ok, success, output = pcall(OmeggaExecuteConsoleManagerInput, command, consolemanager_offset)
        else
            ok, success, output = pcall(OmeggaExecuteConsoleManagerInput, command)
        end
        local offset_detail = consolemanager_offset and (" offset=" .. tostring(consolemanager_offset_text)) or ""
        return "consolemanager ok=" .. tostring(ok) .. " success=" .. tostring(success) .. offset_detail .. " detail=" .. trim(tostring(output or ""))
    end

    return "unknown executor: " .. tostring(executor)
end

function OmeggaBridgeDispatchBmfCommand(spec)
    local text = trim(tostring(spec or ""))
    if text == "" then
        return "dispatch_ok=false\ncode=BMF_COMMAND_REQUIRED\ndetail=usage: Omegga.Bridge.BmfDispatch <bmf.command> [args...]"
    end
    if type(BMF) ~= "table" or type(BMF.commands) ~= "table" or type(BMF.commands.dispatch) ~= "function" then
        return "dispatch_ok=false\ncode=BMF_RUNTIME_UNAVAILABLE\ndetail=BMF.commands.dispatch is unavailable"
    end

    local command_name, args = text:match("^(%S+)%s*(.*)$")
    command_name = string.lower(trim(command_name or ""))
    if command_name == "" then
        return "dispatch_ok=false\ncode=BMF_COMMAND_REQUIRED\ndetail=command name is required"
    end

    local lines = {}
    local ar = {
        NoEventLog = true,
        Log = function(_, line)
            table.insert(lines, tostring(line or ""))
        end,
    }
    local ok, success_or_error = pcall(BMF.commands.dispatch, command_name, trim(args or ""), ar)
    table.insert(lines, 1, "dispatch_ok=" .. tostring(ok))
    if not ok then
        table.insert(lines, "dispatch_error=" .. tostring(success_or_error))
    else
        table.insert(lines, "dispatch_return=" .. tostring(success_or_error))
    end
    return table.concat(lines, "\n")
end

function OmeggaClientTravel(spec)
    local url = trim(tostring(spec or ""))
    if url == "" then
        return "client_travel ok=false code=CLIENT_TRAVEL_URL_REQUIRED detail=usage: Omegga.Bridge.ClientTravel <url>"
    end

    local controller = nil
    local controller_source = ""
    for _, class_name in ipairs({ "BP_PlayerController_C", "BRPlayerController", "PlayerController" }) do
        local candidate = find_first_valid(class_name)
        if is_valid_object(candidate) then
            controller = candidate
            controller_source = class_name
            break
        end
    end

    if not is_valid_object(controller) then
        return "client_travel ok=false code=CLIENT_TRAVEL_CONTROLLER_UNAVAILABLE detail=no live PlayerController was available"
    end

    local commands = {
        "ClientTravel " .. url .. " 0 false (A=0,B=0,C=0,D=0)",
        "ClientTravel " .. url .. " TRAVEL_Absolute false",
        "ClientTravel " .. url,
    }
    local lines = {
        "client_travel url=" .. url,
        "client_travel controller_source=" .. controller_source,
        "client_travel controller=" .. get_object_label(controller, controller_source),
    }

    for index, travel_command in ipairs(commands) do
        local helper_ok, did_succeed, output_or_error =
            invoke_native_call_by_name(controller, travel_command, controller)
        table.insert(lines, "client_travel.attempt." .. tostring(index) .. ".command=" .. travel_command)
        table.insert(lines, "client_travel.attempt." .. tostring(index) .. ".helper_ok=" .. tostring(helper_ok))
        table.insert(lines, "client_travel.attempt." .. tostring(index) .. ".success=" .. tostring(did_succeed))
        table.insert(lines, "client_travel.attempt." .. tostring(index) .. ".detail=" .. trim(tostring(output_or_error or "")))
        if helper_ok and did_succeed then
            table.insert(lines, "client_travel ok=true code=OK")
            return table.concat(lines, "\n")
        end
    end

    table.insert(lines, "client_travel ok=false code=CLIENT_TRAVEL_FAILED")
    return table.concat(lines, "\n")
end

local function try_call_function_by_name(candidate, context)
    if not candidate.object then
        return false, "CallFunctionByNameWithArguments target is unavailable on " .. candidate.object_label
    end

    local commands, command_error = build_call_function_by_name_variants(candidate, context)
    if not commands then
        return false, command_error
    end

    local last_error = "no CallFunctionByNameWithArguments variants were attempted"
    for _, command in ipairs(commands) do
        chat_trace(
            "attempt call-by-name "
                .. candidate.function_path
                .. " via "
                .. candidate.object_label
                .. " command="
                .. command
        )

        local helper_ok, did_succeed, helper_output_or_error = invoke_native_call_by_name(
            candidate.object,
            command,
            candidate.executor or candidate.object
        )

        if helper_ok and did_succeed then
            remember_command_context(
                candidate.object,
                candidate.executor,
                candidate.function_name,
                "typed-chat-call-by-name"
            )
            observed_chat_function_name = candidate.function_name
            observed_chat_function_path = candidate.function_path
            observed_chat_context = candidate.object
            observed_chat_source = "bridge-call-by-name"
            chat_trace(
                "attempt call-by-name succeeded "
                    .. candidate.function_path
                    .. " via "
                    .. candidate.object_label
            )
            return true,
                "typed-chat-call-by-name:" .. candidate.object_label .. "->" .. candidate.function_name
        end

        last_error = helper_ok and tostring(helper_output_or_error or "returned false") or tostring(helper_output_or_error)
        chat_trace("attempt call-by-name failed " .. candidate.function_path .. " error=" .. tostring(last_error))
    end

    return false, last_error
end

local function get_object_address_key(object, fallback)
    local address = get_object_address_string(object)
    if address and address ~= "" then
        return address
    end

    return fallback or tostring(object)
end

local function add_fast_chat_source(candidates, seen, label, object, executor, extra_contexts, player_name)
    if not is_valid_object(object) then
        return
    end

    local key = get_object_address_key(object, label)
    local label_text = tostring(label or "")
    if label_text == "player_controller" or label_text:find("^player_controller%[") ~= nil then
        key = label_text .. ":" .. key
    end
    if seen[key] then
        return
    end

    seen[key] = true
    table.insert(candidates, {
        label = label,
        object = object,
        executor = is_valid_object(executor) and executor or object,
        extra_contexts = extra_contexts or {},
        player_name = tostring(player_name or ""),
    })
end

function build_fast_chat_player_controller_sources(objects, context, fallback_contexts)
    local results = {}
    local seen = {}

    local function push_controller_source(label, controller, player_state, player_pawn, cheat_manager, player_name)
        if not is_valid_object(controller) then
            return
        end

        local key = get_object_address_key(controller, label)
        if seen[key] then
            return
        end

        seen[key] = true
        if not is_valid_object(player_state) then
            player_state = try_get_property_value(controller, "PlayerState")
        end
        if not is_valid_object(cheat_manager) then
            cheat_manager = try_get_property_value(controller, "CheatManager")
        end
        if not is_valid_object(player_pawn) then
            player_pawn = try_get_property_value(controller, "Pawn")
                or try_get_property_value(controller, "AcknowledgedPawn")
        end

        local resolved_player_name = trim(tostring(player_name or ""))
        if resolved_player_name == "" and is_valid_object(player_state) then
            resolved_player_name = get_player_state_chat_name(player_state)
        end
        if resolved_player_name == "" then
            resolved_player_name = trim(safe_value_to_string(select(1, try_get_first_property_value(controller, {
                "UserName",
                "PlayerNamePrivate",
                "PlayerName",
                "DisplayName",
            }))))
        end

        local extra_contexts = {}
        for _, value in ipairs(fallback_contexts or {}) do
            table.insert(extra_contexts, value)
        end
        if is_valid_object(player_state) then
            table.insert(extra_contexts, player_state)
        end
        if is_valid_object(player_pawn) then
            table.insert(extra_contexts, player_pawn)
        end
        if is_valid_object(cheat_manager) then
            table.insert(extra_contexts, cheat_manager)
        end

        table.insert(results, {
            label = label,
            object = controller,
            executor = controller,
            extra_contexts = extra_contexts,
            player_name = tostring(resolved_player_name or ""),
        })
    end

    if type(context) == "table" then
        push_controller_source(
            "player_controller[context]",
            context.player_controller,
            context.player_state,
            context.player_pawn,
            context.cheat_manager,
            get_player_state_chat_name(context.player_state)
        )
    end

    for index, player_state in ipairs(get_direct_game_state_player_states(objects.game_state)) do
        if is_valid_object(player_state) then
            local owner = try_get_property_value(player_state, "Owner")
            local cheat_manager = is_valid_object(owner) and try_get_property_value(owner, "CheatManager") or nil
            local player_pawn = try_get_property_value(player_state, "PawnPrivate")
                or (is_valid_object(owner) and try_get_property_value(owner, "Pawn") or nil)
                or (is_valid_object(owner) and try_get_property_value(owner, "AcknowledgedPawn") or nil)
            push_controller_source(
                "player_controller[" .. tostring(index) .. "]",
                owner,
                player_state,
                player_pawn,
                cheat_manager,
                get_player_state_chat_name(player_state)
            )
        end
    end

    for _, class_name in ipairs({ "BRPlayerController", "BP_PlayerController_C", "PlayerController" }) do
        local controller = find_first_valid(class_name)
        if is_valid_object(controller) then
            push_controller_source(
                "player_controller[FindFirstOf(" .. tostring(class_name) .. ")]",
                controller,
                nil,
                nil,
                nil,
                nil
            )
        end
    end

    return results
end

local function build_fast_chat_sources(objects, context)
    local candidates = {}
    local seen = {}
    local cached_context = nil
    if type(context) == "table" and is_valid_object(context.cached_context) then
        cached_context = context.cached_context
    end
    local fallback_contexts = {}
    local fallback_seen = {}

    local function push_fallback_context(value)
        if not is_valid_object(value) then
            return
        end

        local key = get_object_address_key(value, "fallback")
        if fallback_seen[key] then
            return
        end

        fallback_seen[key] = true
        table.insert(fallback_contexts, value)
    end

    push_fallback_context(cached_context)
    if type(context) == "table" then
        push_fallback_context(context.cached_executor)
        push_fallback_context(context.cached_context)
        push_fallback_context(context.player_controller)
        push_fallback_context(context.player_state)
        push_fallback_context(context.cheat_manager)
        push_fallback_context(context.player_pawn)
        push_fallback_context(context.engine)
        push_fallback_context(context.game_instance)
    end
    push_fallback_context(objects.game_mode)
    push_fallback_context(objects.game_session)
    push_fallback_context(objects.game_state)
    push_fallback_context(objects.world)

    add_fast_chat_source(
        candidates,
        seen,
        "cached_executor",
        type(context) == "table" and context.cached_executor or nil,
        type(context) == "table" and context.cached_executor or nil,
        fallback_contexts
    )
    add_fast_chat_source(
        candidates,
        seen,
        "cached_context",
        type(context) == "table" and context.cached_context or cached_context,
        type(context) == "table" and (context.cached_executor or context.cached_context) or cached_context,
        fallback_contexts
    )
    add_fast_chat_source(
        candidates,
        seen,
        "engine",
        type(context) == "table" and context.engine or nil,
        type(context) == "table" and context.engine or nil,
        fallback_contexts
    )
    add_fast_chat_source(
        candidates,
        seen,
        "game_instance",
        type(context) == "table" and context.game_instance or nil,
        type(context) == "table" and context.game_instance or nil,
        fallback_contexts
    )

    for _, source_name in ipairs(CHAT_FAST_SOURCE_NAMES) do
        add_fast_chat_source(
            candidates,
            seen,
            "FindFirstOf(" .. source_name .. ")",
            find_first_valid(source_name),
            nil,
            fallback_contexts
        )
    end

    add_fast_chat_source(candidates, seen, "cached_context", cached_context, cached_context, fallback_contexts)
    add_fast_chat_source(candidates, seen, "game_mode", objects.game_mode, objects.game_mode, fallback_contexts)
    add_fast_chat_source(candidates, seen, "game_session", objects.game_session, objects.game_mode, fallback_contexts)
    add_fast_chat_source(candidates, seen, "game_state", objects.game_state, objects.game_mode, fallback_contexts)
    add_fast_chat_source(candidates, seen, "world", objects.world, objects.game_mode, fallback_contexts)

    for _, player_controller_source in ipairs(build_fast_chat_player_controller_sources(objects, context, fallback_contexts)) do
        add_fast_chat_source(
            candidates,
            seen,
            player_controller_source.label,
            player_controller_source.object,
            player_controller_source.executor,
            player_controller_source.extra_contexts,
            player_controller_source.player_name
        )
    end

    add_fast_chat_source(
        candidates,
        seen,
        "player_controller.CheatManager",
        type(context) == "table" and context.cheat_manager or nil,
        type(context) == "table" and (context.player_controller or context.cheat_manager) or nil,
        fallback_contexts
    )
    add_fast_chat_source(
        candidates,
        seen,
        "player_state",
        type(context) == "table" and context.player_state or nil,
        type(context) == "table" and (context.player_controller or context.player_state) or nil,
        fallback_contexts
    )
    add_fast_chat_source(
        candidates,
        seen,
        "player_pawn",
        type(context) == "table" and context.player_pawn or nil,
        type(context) == "table" and (context.player_controller or context.player_pawn) or nil,
        fallback_contexts
    )

    return candidates
end

local function build_fast_chat_call_by_name_commands(function_name, message)
    local escaped_message = quote_name(message)
    local commands = {}

    if function_name == "CallChatCommand" or function_name == "CallChatCommandWithArgs" then
        table.insert(commands, function_name .. " Broadcast \"" .. escaped_message .. "\"")
        table.insert(commands, function_name .. " broadcast \"" .. escaped_message .. "\"")
        table.insert(commands, function_name .. " \"Broadcast\" \"" .. escaped_message .. "\"")
        table.insert(commands, function_name .. " \"broadcast\" \"" .. escaped_message .. "\"")
        return commands
    end

    table.insert(commands, function_name .. " \"" .. escaped_message .. "\"")
    table.insert(commands, function_name .. " SERVER \"" .. escaped_message .. "\"")
    table.insert(commands, function_name .. " \"SERVER\" \"" .. escaped_message .. "\"")
    return commands
end

local function try_fast_chat_call_by_name(source, function_name, message)
    if not source.object then
        return false, "CallFunctionByNameWithArguments target unavailable"
    end

    local commands = build_fast_chat_call_by_name_commands(function_name, message)
    local executors = {}
    local executor_seen = {}

    local function push_executor(value)
        if not is_valid_object(value) then
            return
        end

        local key = get_object_address_key(value, "executor")
        if executor_seen[key] then
            return
        end

        executor_seen[key] = true
        table.insert(executors, value)
    end

    push_executor(source.executor)
    push_executor(source.object)
    for _, value in ipairs(source.extra_contexts or {}) do
        push_executor(value)
    end

    if #executors == 0 then
        table.insert(executors, source.object)
    end

    local last_error = "no fast chat commands attempted"
    for _, command in ipairs(commands) do
        for _, executor in ipairs(executors) do
            local executor_label = get_object_label(executor, "executor")
            chat_trace(
                "fast call-by-name "
                    .. tostring(source.label)
                    .. " -> "
                    .. tostring(command)
                    .. " executor="
                    .. executor_label
            )

            local helper_ok, did_succeed, helper_output_or_error = invoke_native_call_by_name(
                source.object,
                command,
                executor
            )

            if helper_ok and did_succeed then
                remember_command_context_shallow(
                    source.object,
                    executor,
                    function_name,
                    "typed-chat-fast-call-by-name"
                )
                observed_chat_function_name = function_name
                observed_chat_function_path = tostring(source.label) .. ":" .. tostring(function_name)
                observed_chat_context = source.object
                observed_chat_source = "bridge-fast-call-by-name"
                chat_trace(
                    "fast call-by-name succeeded "
                        .. tostring(source.label)
                        .. " -> "
                        .. tostring(command)
                        .. " executor="
                        .. executor_label
                )
                return true, "typed-chat-fast-call-by-name:" .. tostring(source.label) .. "->" .. tostring(function_name)
            end

            last_error = helper_ok and tostring(helper_output_or_error or "returned false") or tostring(helper_output_or_error)
            chat_trace(
                "fast call-by-name failed "
                    .. tostring(source.label)
                    .. " -> "
                    .. tostring(command)
                    .. " executor="
                    .. executor_label
                    .. " error="
                    .. tostring(last_error)
            )
        end
    end

    return false, last_error
end

function is_client_targeted_chat_function(function_name)
    return function_name == "ClientPushChatMessage" or function_name == "ClientPushPlayerChatMessage"
end

function is_player_controller_fast_source(source)
    local label = type(source) == "table" and tostring(source.label or "") or ""
    return label == "player_controller" or label:find("^player_controller%[") ~= nil
end

function normalize_chat_whisper_target_key(value)
    return string.lower(trim(tostring(value or "")))
end

function clone_fast_chat_player_source(source, player_name)
    if type(source) ~= "table" or not is_player_controller_fast_source(source) or not is_valid_object(source.object) then
        return nil
    end

    local extra_contexts = {}
    for _, value in ipairs(source.extra_contexts or {}) do
        if is_valid_object(value) then
            table.insert(extra_contexts, value)
        end
    end

    return {
        label = tostring(source.label or "player_controller[cached]"),
        object = source.object,
        executor = is_valid_object(source.executor) and source.executor or source.object,
        extra_contexts = extra_contexts,
        player_name = tostring(player_name or source.player_name or ""),
    }
end

function remember_chat_whisper_player_source(target, source)
    local resolved_player_name = trim(tostring(type(source) == "table" and source.player_name or ""))
    if resolved_player_name == "" then
        resolved_player_name = trim(tostring(target or ""))
    end

    local cached_source = clone_fast_chat_player_source(source, resolved_player_name)
    if not cached_source then
        return false
    end

    CHAT_WHISPER_LAST_PLAYER_SOURCE = cached_source
    CHAT_WHISPER_LAST_TARGET_KEY = normalize_chat_whisper_target_key(target)

    local target_key = CHAT_WHISPER_LAST_TARGET_KEY
    if target_key ~= "" then
        CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET[target_key] = cached_source
    end

    local player_key = normalize_chat_whisper_target_key(resolved_player_name)
    if player_key ~= "" then
        CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET[player_key] = cached_source
    end

    return true
end

function get_cached_chat_whisper_player_source(target)
    local target_key = normalize_chat_whisper_target_key(target)
    local cached_source = nil
    if target_key ~= "" then
        cached_source = CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET[target_key]
    end
    if not cached_source and target_key ~= "" and CHAT_WHISPER_LAST_TARGET_KEY == target_key then
        cached_source = CHAT_WHISPER_LAST_PLAYER_SOURCE
    end

    if cached_source and is_valid_object(cached_source.object) then
        return clone_fast_chat_player_source(cached_source, cached_source.player_name)
    end

    if target_key ~= "" then
        CHAT_WHISPER_PLAYER_SOURCE_BY_TARGET[target_key] = nil
    end
    if cached_source == CHAT_WHISPER_LAST_PLAYER_SOURCE then
        CHAT_WHISPER_LAST_PLAYER_SOURCE = nil
        CHAT_WHISPER_LAST_TARGET_KEY = ""
    end

    return nil
end

function try_fast_chat_client_fanout(sources, function_name, message)
    local successes = {}
    local failures = {}
    local attempted = {}

    for _, source in ipairs(sources or {}) do
        if is_player_controller_fast_source(source) and is_valid_object(source.object) then
            local key = get_object_address_key(source.object, source.label)
            if not attempted[key] then
                attempted[key] = true
                local ok, executor_or_error = try_fast_chat_call_by_name(source, function_name, message)
                if ok then
                    table.insert(successes, tostring(source.label))
                else
                    table.insert(failures, tostring(source.label) .. "=" .. tostring(executor_or_error))
                end
            end
        end
    end

    if #successes > 0 then
        chat_trace(
            "fast client fanout succeeded function="
                .. tostring(function_name)
                .. " count="
                .. tostring(#successes)
                .. " targets="
                .. table.concat(successes, ",")
        )
        return true,
            "typed-chat-fast-call-by-name:fanout["
                .. tostring(#successes)
                .. "]->"
                .. tostring(function_name)
    end

    if #failures > 0 then
        return false, table.concat(failures, "; ")
    end

    return false, "No player-controller fanout targets are available."
end

local FAST_DIRECT_CHAT = {}

function FAST_DIRECT_CHAT.is_callable_function_object(value)
    if not value then
        return false
    end

    if type(value.IsValid) == "function" then
        local ok, is_valid = pcall(function()
            return value:IsValid()
        end)
        if ok and is_valid then
            return true
        end
    end

    return type(value.ForEachProperty) == "function"
        or type(value.GetFName) == "function"
        or type(value.GetFullName) == "function"
end

function FAST_DIRECT_CHAT.should_allow_scoped_fast_direct(source, function_name)
    if ALLOW_UNSAFE_PROBES then
        return true
    end

    local label = type(source) == "table" and tostring(source.label or "") or ""
    if label == "FindFirstOf(BRChatCommandWorldSubsystem)"
        or label == "FindFirstOf(ChatCommandWorldSubsystem)"
        or label == "FindFirstOf(BP_ChatCommandWorldSubsystem_C)" then
        return function_name == "CallChatCommand"
            or function_name == "CallChatCommandWithArgs"
            or function_name == "PushChatMessage"
            or function_name == "MulticastPushChatMessage"
            or function_name == "MulticastPushChatMessageText"
    end

    return false
end

function FAST_DIRECT_CHAT.try_make_name(seed)
    if type(FName) ~= "function" then
        return nil
    end

    local ok, value = pcall(FName, tostring(seed or ""), EFindName and EFindName.FNAME_Add or 1)
    if ok then
        return value
    end

    return nil
end

function FAST_DIRECT_CHAT.try_make_text(message)
    if type(FText) ~= "function" then
        return nil
    end

    local ok, value = pcall(FText, tostring(message or ""))
    if ok then
        return value
    end

    return nil
end

function FAST_DIRECT_CHAT.try_make_string(message)
    if type(FString) ~= "function" then
        return nil
    end

    local ok, value = pcall(FString, tostring(message or ""))
    if ok then
        return value
    end

    return nil
end

function FAST_DIRECT_CHAT.build_variants(source, function_name, message)
    local variants = {}
    local seen = {}
    local message_string = tostring(message or "")
    local message_text = FAST_DIRECT_CHAT.try_make_text(message_string)
    local message_fstring = FAST_DIRECT_CHAT.try_make_string(message_string)
    local server_name = FAST_DIRECT_CHAT.try_make_name("SERVER")
    local broadcast_name = FAST_DIRECT_CHAT.try_make_name("Broadcast")
        or FAST_DIRECT_CHAT.try_make_name("broadcast")
    local context_candidates = {}
    local context_seen = {}

    local function push_context_candidate(value)
        if not is_valid_object(value) then
            return
        end

        local key = get_object_address_key(value, "context")
        if context_seen[key] then
            return
        end

        context_seen[key] = true
        table.insert(context_candidates, value)
    end

    if type(source) == "table" then
        push_context_candidate(source.executor)
        push_context_candidate(source.object)
        for _, value in ipairs(source.extra_contexts or {}) do
            push_context_candidate(value)
        end
    end

    local function variant_key(variant)
        local parts = {}
        for _, value in ipairs(variant) do
            if is_valid_object(value) then
                table.insert(parts, "userdata:" .. get_object_address_key(value, "object"))
            else
                table.insert(parts, type(value) .. ":" .. tostring(value))
            end
        end
        return table.concat(parts, "|")
    end

    local function push_variant(...)
        local variant = { ... }
        local key = variant_key(variant)
        if seen[key] then
            return
        end

        seen[key] = true
        table.insert(variants, variant)
    end

    if function_name == "CallChatCommand" or function_name == "CallChatCommandWithArgs" then
        local function push_command_message_variants(command_value, message_value)
            for _, context_value in ipairs(context_candidates) do
                push_variant(context_value, command_value, message_value)
            end
            for _, context_value in ipairs(context_candidates) do
                push_variant(command_value, message_value, context_value)
            end
            for _, context_value in ipairs(context_candidates) do
                push_variant(context_value, message_value, command_value)
            end
            push_variant(command_value, message_value)
        end

        push_command_message_variants("Broadcast", message_string)
        push_command_message_variants("broadcast", message_string)
        push_variant('Broadcast "' .. quote_name(message_string) .. '"')
        push_variant('broadcast "' .. quote_name(message_string) .. '"')
        if broadcast_name then
            push_command_message_variants(broadcast_name, message_string)
        end
        if message_fstring then
            push_command_message_variants("Broadcast", message_fstring)
            push_command_message_variants("broadcast", message_fstring)
            if broadcast_name then
                push_command_message_variants(broadcast_name, message_fstring)
            end
        end
        if message_text then
            push_command_message_variants("Broadcast", message_text)
            push_command_message_variants("broadcast", message_text)
            if broadcast_name then
                push_command_message_variants(broadcast_name, message_text)
            end
        end
        return variants
    end

    push_variant(message_string)
    if message_fstring then
        push_variant(message_fstring)
    end
    if message_text then
        push_variant(message_text)
    end

    push_variant("SERVER", message_string)
    if server_name then
        push_variant(server_name, message_string)
    end
    if message_fstring then
        push_variant("SERVER", message_fstring)
        if server_name then
            push_variant(server_name, message_fstring)
        end
    end
    if message_text then
        push_variant("SERVER", message_text)
        if server_name then
            push_variant(server_name, message_text)
        end
    end

    return variants
end

function FAST_DIRECT_CHAT.resolve_function(source, function_name)
    if not source.object or type(function_name) ~= "string" or function_name == "" then
        return nil, "direct function target unavailable"
    end

    local ok, value = pcall(function()
        return source.object[function_name]
    end)
    if not ok then
        return nil, tostring(value)
    end

    if FAST_DIRECT_CHAT.is_callable_function_object(value) then
        return value, nil
    end

    if value == nil then
        return nil, "member not found"
    end

    return nil, "member is not a valid function object"
end

function FAST_DIRECT_CHAT.try_call(source, function_name, message)
    if function_name == "CallChatCommand" or function_name == "CallChatCommandWithArgs" then
        return false, "direct command-function path disabled"
    end

    local func, function_error = FAST_DIRECT_CHAT.resolve_function(source, function_name)
    if not func then
        return false, function_error
    end

    local variants = FAST_DIRECT_CHAT.build_variants(source, function_name, message)
    local last_error = "no direct chat variants were attempted"
    for index, variant in ipairs(variants) do
        local args = {}
        for _, value in ipairs(variant) do
            table.insert(args, describe_chat_value(value))
        end
        chat_trace(
            "fast direct "
                .. tostring(source.label)
                .. " -> "
                .. tostring(function_name)
                .. " variant="
                .. tostring(index)
                .. " args="
                .. table.concat(args, " | ")
        )

        local ok, result = pcall(function()
            return source.object:CallFunction(func, table.unpack(variant))
        end)

        if ok and result ~= false then
            remember_command_context_shallow(source.object, source.executor, function_name, "typed-chat-fast-direct")
            observed_chat_function_name = function_name
            observed_chat_function_path = tostring(source.label) .. ":" .. tostring(function_name)
            observed_chat_context = source.object
            observed_chat_source = "bridge-fast-direct"
            chat_trace("fast direct succeeded " .. tostring(source.label) .. " -> " .. tostring(function_name))
            return true, "typed-chat-fast-direct:" .. tostring(source.label) .. "->" .. tostring(function_name)
        end

        last_error = ok and "returned false" or tostring(result)
        chat_trace(
            "fast direct failed "
                .. tostring(source.label)
                .. " -> "
                .. tostring(function_name)
                .. " error="
                .. tostring(last_error)
        )
    end

    return false, last_error
end

local function try_fast_typed_chat_broadcast(message)
    bridge_log("info", "Typed chat broadcast fast-path begin")
    message = flatten_rich_chat_text(message)
    local objects, object_error = get_chat_broadcast_objects()
    if not objects then
        return false, object_error or "Cached game objects are unavailable."
    end

    local context = build_chat_runtime_context(objects, message)
    local sources = build_fast_chat_sources(objects, context)
    bridge_log("info", "Typed chat broadcast fast-path source count=" .. tostring(#sources))
    if #sources == 0 then
        return false, "No fast chat sources are available."
    end

    local attempts = {}
    local client_fanout_attempted = {}
    for _, function_name in ipairs(CHAT_FAST_FUNCTION_NAMES) do
        if call_by_name_helper_available ~= false and is_client_targeted_chat_function(function_name) then
            client_fanout_attempted[function_name] = true
            local ok, executor_or_error = try_fast_chat_client_fanout(sources, function_name, message)
            if ok then
                return true, executor_or_error
            end
            table.insert(
                attempts,
                "fanout-preferred->" .. tostring(function_name) .. "=callbyname:" .. tostring(executor_or_error)
            )
        end
    end

    for _, source in ipairs(sources) do
        for _, function_name in ipairs(CHAT_FAST_FUNCTION_NAMES) do
            if call_by_name_helper_available ~= false then
                if is_client_targeted_chat_function(function_name) and is_player_controller_fast_source(source) then
                    if not client_fanout_attempted[function_name] then
                        client_fanout_attempted[function_name] = true
                        local ok, executor_or_error = try_fast_chat_client_fanout(sources, function_name, message)
                        if ok then
                            return true, executor_or_error
                        end
                        table.insert(
                            attempts,
                            "fanout->" .. tostring(function_name) .. "=callbyname:" .. tostring(executor_or_error)
                        )
                    end
                else
                    local ok, executor_or_error = try_fast_chat_call_by_name(source, function_name, message)
                    if ok then
                        return true, executor_or_error
                    end
                    table.insert(
                        attempts,
                        tostring(source.label) .. "->" .. tostring(function_name) .. "=callbyname:" .. tostring(executor_or_error)
                    )
                end
            end

            if not ALLOW_UNSAFE_PROBES then
                table.insert(
                    attempts,
                    tostring(source.label) .. "->" .. tostring(function_name) .. "=direct:disabled"
                )
            else
                local direct_ok, direct_executor_or_error = FAST_DIRECT_CHAT.try_call(source, function_name, message)
                if direct_ok then
                    return true, direct_executor_or_error
                end
                table.insert(
                    attempts,
                    tostring(source.label) .. "->" .. tostring(function_name) .. "=direct:" .. tostring(direct_executor_or_error)
                )
            end
        end
    end

    return false, table.concat(attempts, "; ")
end

function try_fast_typed_chat_whisper(target, message)
    bridge_log("info", "Typed chat whisper fast-path begin target=" .. tostring(target or ""))
    local target_lower = string.lower(trim(tostring(target or "")))
    local clean_message = flatten_rich_chat_text(message)
    local objects, object_error = get_chat_broadcast_objects()
    if not objects then
        return false, object_error or "Cached game objects are unavailable."
    end

    local context = build_chat_runtime_context(objects, clean_message)
    local sources = build_fast_chat_sources(objects, context)
    local exact_sources = {}
    local player_sources = {}
    local player_seen = {}

    for _, source in ipairs(sources) do
        if is_player_controller_fast_source(source) and is_valid_object(source.object) then
            local source_key = get_object_address_key(source.object, source.label)
            if not player_seen[source_key] then
                player_seen[source_key] = true
                table.insert(player_sources, source)
            end
            local player_name = string.lower(trim(tostring(source.player_name or "")))
            if target_lower ~= "" and player_name == target_lower then
                table.insert(exact_sources, source)
            end
        end
    end

    if #exact_sources == 0 then
        local cached_source = get_cached_chat_whisper_player_source(target_lower)
        if cached_source then
            bridge_log("info", "Typed chat whisper using cached player-controller source for target=" .. tostring(target or ""))
            table.insert(player_sources, cached_source)
            table.insert(exact_sources, cached_source)
        end
    end

    local selected_sources = exact_sources
    if #selected_sources == 0 and #player_sources == 1 then
        selected_sources = player_sources
    end

    if #selected_sources == 0 then
        return false,
            "No player-controller source matched whisper target "
                .. tostring(target or "")
                .. " among "
                .. tostring(#player_sources)
                .. " player controller(s)."
    end

    local attempts = {}
    for _, source in ipairs(selected_sources) do
        local ok, executor_or_error = try_fast_chat_call_by_name(source, "ClientPushChatMessage", clean_message)
        if ok then
            remember_chat_whisper_player_source(target, source)
            return true,
                "typed-chat-whisper:"
                    .. tostring(source.label)
                    .. "["
                    .. tostring(source.player_name or "")
                    .. "]->ClientPushChatMessage"
        end
        table.insert(
            attempts,
            tostring(source.label)
                .. "["
                .. tostring(source.player_name or "")
                .. "]->ClientPushChatMessage="
                .. tostring(executor_or_error)
        )
    end

    return false, table.concat(attempts, "; ")
end

local function collect_chat_broadcast_candidates(message)
    bridge_log("info", "Typed chat broadcast candidate collection begin")
    local objects, object_error = get_chat_broadcast_objects()
    if not objects then
        return nil, object_error or "Cached game objects are unavailable."
    end

    bridge_log("info", "Typed chat broadcast cached game objects resolved")
    local context = build_chat_runtime_context(objects, message)
    bridge_log("info", "Typed chat broadcast runtime context built")
    local sources = collect_chat_sources(objects, context)
    bridge_log("info", "Typed chat broadcast source count=" .. tostring(#sources))
    local candidates = {}
    local seen = {}

    local function push_candidate(source, hit)
        local key = get_object_label(source.object, source.label) .. "::" .. hit.function_path
        if seen[key] then
            return
        end

        seen[key] = true
        table.insert(candidates, {
            object = source.object,
            executor = source.executor,
            object_label = source.label,
            function_name = hit.function_name,
            function_path = hit.function_path,
            func = hit.func,
            parameters = hit.parameters,
        })
    end

    if is_valid_object(observed_chat_context) and observed_chat_function_name then
        local observed_source = {
            label = "observed:" .. tostring(observed_chat_source or "unknown"),
            object = observed_chat_context,
            executor = observed_chat_context,
        }
        for _, hit in ipairs(get_named_function_hits(observed_chat_context, observed_chat_function_name)) do
            push_candidate(observed_source, hit)
        end
    end

    for _, source in ipairs(sources) do
        bridge_log("info", "Typed chat broadcast enumerating source " .. tostring(source.label))
        for _, function_name in ipairs(CHAT_CANDIDATE_FUNCTIONS) do
            for _, hit in ipairs(get_named_function_hits(source.object, function_name)) do
                log_chat_candidate(source.label, hit)
                push_candidate(source, hit)
            end
        end
    end

    bridge_log("info", "Typed chat broadcast candidate count=" .. tostring(#candidates))
    return candidates, context
end

local function handle_typed_chat_broadcast(message)
    bridge_log("info", "Typed chat broadcast begin")
    message = flatten_rich_chat_text(message)
    local fast_ok, fast_executor_or_error = try_fast_typed_chat_broadcast(message)
    if fast_ok then
        return true, fast_executor_or_error
    end
    bridge_log("warn", "Typed chat broadcast fast-path failed: " .. tostring(fast_executor_or_error))

    if not ENABLE_REFLECTION_CHAT_DISCOVERY then
        return false, tostring(fast_executor_or_error or "Fast typed chat broadcast failed.")
    end

    if ENABLE_CHAT_DISCOVERY_HOOKS then
        local hook_ok, hook_result = pcall(ensure_chat_hooks_installed)
        if hook_ok then
            chat_trace("ensure_chat_hooks_installed registered=" .. tostring(hook_result))
        else
            chat_trace("ensure_chat_hooks_installed crashed error=" .. tostring(hook_result))
        end
    end

    local candidates, context_or_error = collect_chat_broadcast_candidates(message)
    if not candidates then
        bridge_log("warn", "Typed chat broadcast candidate collection failed: " .. tostring(context_or_error))
        return false, tostring(context_or_error or "No chat candidates are available.")
    end

    if #candidates == 0 then
        bridge_log("warn", "Typed chat broadcast found zero candidates")
        return false,
            "No direct chat broadcast candidates were discovered. Enable OMEGGA_UE4SS_CHAT_TRACE=1 and inspect chat-trace.log."
    end

    local attempts = {}
    for _, candidate in ipairs(candidates) do
        bridge_log(
            "info",
            "Typed chat broadcast trying " .. tostring(candidate.object_label) .. " -> " .. tostring(candidate.function_name)
        )
        local direct_ok, direct_executor_or_error = try_direct_chat_call(candidate, context_or_error)
        if direct_ok then
            return true, direct_executor_or_error
        end
        table.insert(
            attempts,
            candidate.object_label
                .. "->"
                .. candidate.function_name
                .. "=direct:"
                .. tostring(direct_executor_or_error)
        )

        local by_name_ok, by_name_executor_or_error = try_call_function_by_name(candidate, context_or_error)
        if by_name_ok then
            return true, by_name_executor_or_error
        end
        table.insert(
            attempts,
            candidate.object_label
                .. "->"
                .. candidate.function_name
                .. "=callbyname:"
                .. tostring(by_name_executor_or_error)
        )
    end

    return false,
        "No proven chat broadcast path succeeded. "
            .. table.concat(attempts, "; ")
            .. ". See chat-trace.log for candidate signatures and call attempts."
end

local function handle_typed_chat_whisper(target, message)
    local success, executor_or_error = try_fast_typed_chat_whisper(target, message)
    if success then
        return true, executor_or_error
    end

    return false, tostring(executor_or_error)
end

local function handle_typed_chat_status_message(target, message)
    return false,
        "Typed Windows status message is intentionally disabled until the direct broadcast canary is proven. Target="
            .. tostring(target or "")
            .. " message="
            .. tostring(message or "")
end

local function probe_chat_api()
    local lines = {}

    local function push(line)
        table.insert(lines, tostring(line))
    end

    push("chat_trace_enabled=" .. tostring(CHAT_TRACE_ENABLED))
    push("chat_trace_path=" .. tostring(CHAT_TRACE_PATH))
    push("last_hook_source=" .. tostring(last_hook_source or ""))
    push("last_hook_command=" .. tostring(last_hook_command or ""))
    push("last_hook_context_valid=" .. tostring(is_valid_object(last_hook_context)))
    push("last_hook_executor_valid=" .. tostring(is_valid_object(last_hook_executor)))
    push("last_hook_world_valid=" .. tostring(is_valid_object(last_hook_world)))
    push("last_hook_game_mode_valid=" .. tostring(is_valid_object(last_hook_game_mode)))
    push("last_hook_game_state_valid=" .. tostring(is_valid_object(last_hook_game_state)))
    push("last_hook_game_session_valid=" .. tostring(is_valid_object(last_hook_game_session)))
    push("observed_chat_function=" .. tostring(observed_chat_function_path or "none"))
    push("observed_chat_source=" .. tostring(observed_chat_source or "none"))
    push("observed_chat_context_valid=" .. tostring(is_valid_object(observed_chat_context)))

    if type(OmeggaHasCachedCommandContext) == "function" then
        local ok, has_context = pcall(OmeggaHasCachedCommandContext)
        push("cached_command_context_available=" .. tostring(ok and has_context or false))
    else
        push("cached_command_context_available=missing-helper")
    end

    if type(OmeggaHasCachedEngineExecContext) == "function" then
        local ok, has_context = pcall(OmeggaHasCachedEngineExecContext)
        push("cached_engine_exec_context_available=" .. tostring(ok and has_context or false))
    else
        push("cached_engine_exec_context_available=missing-helper")
    end

    push("chat_hooks_registered=" .. (ENABLE_CHAT_DISCOVERY_HOOKS and "enabled" or "disabled"))
    push("unsafe_descriptor_probes=" .. (ALLOW_UNSAFE_PROBES and "enabled" or "disabled"))

    return table.concat(lines, "\n")
end

local function try_emulate_command(command)
    local probe_target = command:match("^Omegga%.Bridge%.ProbeConsoleExec%s+(.+)$")
    if probe_target and trim(probe_target) ~= "" then
        return true, "emulated-probe-console-exec", probe_console_exec(trim(probe_target))
    end

    if command == "Omegga.Bridge.ProbeChatApi" then
        return true, "emulated-probe-chat-api", probe_chat_api()
    end

    if command == "Omegga.Bridge.Echo" then
        return true, "emulated-bridge-echo", "Omegga bridge self-test ok"
    end

    local bmf_command = command:match("^Omegga%.Bridge%.BMF%s+(.+)$")
    if bmf_command and trim(bmf_command) ~= "" then
        return true,
            "emulated-bmf-socket-required",
            table.concat({
                "ok=false",
                "detail=BMF commands require the BMF Bridge socket plugin.",
                "command=" .. trim(bmf_command),
            }, "\n")
    end

    local spawn_native_prefab = command:match("^Omegga%.Bridge%.SpawnLastNativePrefab%s*(.*)$")
    if spawn_native_prefab ~= nil then
        local spec = trim(spawn_native_prefab)
        local x_offset = tonumber(spec:match("x_offset%s*=?%s*(-?%d+)") or "0") or 0
        local y_offset = tonumber(spec:match("y_offset%s*=?%s*(-?%d+)") or spec:match("^(-?%d+)$") or "520") or 520
        local z_offset = tonumber(spec:match("z_offset%s*=?%s*(-?%d+)") or "0") or 0
        local nonce = tostring(os.time()) .. "-" .. tostring(math.random(1000000))
        local body = table.concat({
            "spawn=1",
            "nonce=" .. nonce,
            "x_offset=" .. tostring(x_offset),
            "y_offset=" .. tostring(y_offset),
            "z_offset=" .. tostring(z_offset),
            "",
        }, "\n")
        if not write_file(NATIVE_PREFAB_COMMAND_PATH, body) then
            return true, "emulated-spawn-last-native-prefab", "ok=0 error=command_file_open_failed path=" .. tostring(NATIVE_PREFAB_COMMAND_PATH)
        end
        return true,
            "emulated-spawn-last-native-prefab",
            "queued_native_spawn nonce=" .. nonce .. " offset=" .. x_offset .. "," .. y_offset .. "," .. z_offset
    end

    if command == "Omegga.Bridge.DescribeConsoleManager" then
        if type(OmeggaDescribeConsoleManager) ~= "function" then
            return true, "emulated-describe-console-manager", "consolemanager helper missing"
        end
        local ok, output = pcall(OmeggaDescribeConsoleManager)
        return true, "emulated-describe-console-manager", "ok=" .. tostring(ok) .. " detail=" .. trim(tostring(output or ""))
    end

    if command == "Omegga.Bridge.DescribeConsoleExecCandidates" then
        return true, "emulated-describe-console-exec-candidates", describe_console_exec_candidates()
    end

    local describe_bmf_socket_ufunction = command:match("^Omegga%.Bridge%.DescribeBmfSocketUFunction%s+(.+)$")
    if describe_bmf_socket_ufunction and trim(describe_bmf_socket_ufunction) ~= "" then
        if type(BMFSocketDescribeUFunction) ~= "function" then
            return true, "emulated-describe-bmf-socket-ufunction", "BMFSocketDescribeUFunction helper missing"
        end
        local ok, output = pcall(BMFSocketDescribeUFunction, trim(describe_bmf_socket_ufunction), 32)
        return true,
            "emulated-describe-bmf-socket-ufunction",
            ok and tostring(output or "") or ("BMFSocketDescribeUFunction crashed: " .. tostring(output))
    end

    local bmf_chat_command_probe = command:match("^Omegga%.Bridge%.BmfChatCommandProbe%s+(.+)$")
    if bmf_chat_command_probe and trim(bmf_chat_command_probe) ~= "" then
        if type(BMFSocketChatCommandProbe) ~= "function" then
            return true, "emulated-bmf-chat-command-probe", "BMFSocketChatCommandProbe helper missing"
        end
        local ok, output = pcall(BMFSocketChatCommandProbe, trim(bmf_chat_command_probe), "chat-command-probe")
        return true,
            "emulated-bmf-chat-command-probe",
            ok and tostring(output or "") or ("BMFSocketChatCommandProbe crashed: " .. tostring(output))
    end

    local bmf_player_console_command_probe = command:match("^Omegga%.Bridge%.BmfPlayerConsoleCommandProbe%s+(.+)$")
    if bmf_player_console_command_probe and trim(bmf_player_console_command_probe) ~= "" then
        if type(BMFSocketPlayerConsoleCommandProbe) ~= "function" then
            return true, "emulated-bmf-player-console-command-probe", "BMFSocketPlayerConsoleCommandProbe helper missing"
        end
        local ok, output = pcall(BMFSocketPlayerConsoleCommandProbe, trim(bmf_player_console_command_probe), "player-console-command-probe")
        return true,
            "emulated-bmf-player-console-command-probe",
            ok and tostring(output or "") or ("BMFSocketPlayerConsoleCommandProbe crashed: " .. tostring(output))
    end

    local bmf_player_chat_message_probe = command:match("^Omegga%.Bridge%.BmfPlayerChatMessageProbe%s+(.+)$")
    if bmf_player_chat_message_probe and trim(bmf_player_chat_message_probe) ~= "" then
        if type(BMFSocketPlayerChatMessageProbe) ~= "function" then
            return true, "emulated-bmf-player-chat-message-probe", "BMFSocketPlayerChatMessageProbe helper missing"
        end
        local ok, output = pcall(BMFSocketPlayerChatMessageProbe, trim(bmf_player_chat_message_probe), "player-chat-message-probe")
        return true,
            "emulated-bmf-player-chat-message-probe",
            ok and tostring(output or "") or ("BMFSocketPlayerChatMessageProbe crashed: " .. tostring(output))
    end

    local bmf_kismet_console_command_probe = command:match("^Omegga%.Bridge%.BmfKismetConsoleCommandProbe%s+(.+)$")
    if bmf_kismet_console_command_probe and trim(bmf_kismet_console_command_probe) ~= "" then
        if type(BMFSocketKismetConsoleCommandProbe) ~= "function" then
            return true, "emulated-bmf-kismet-console-command-probe", "BMFSocketKismetConsoleCommandProbe helper missing"
        end
        local probe_command = trim(bmf_kismet_console_command_probe)
        local explicit_context, remaining_command = probe_command:match("^context=([^%s]+)%s+(.+)$")
        local world_pointer = ""
        if explicit_context and trim(remaining_command or "") ~= "" then
            world_pointer = trim(explicit_context)
            probe_command = trim(remaining_command)
        end
        local helpers = type(UEHelpers) == "table" and UEHelpers or nil
        if world_pointer == "" and not helpers then
            local helpers_ok, loaded_helpers = pcall(require, "UEHelpers")
            if helpers_ok and type(loaded_helpers) == "table" then
                helpers = loaded_helpers
            end
        end
        if world_pointer == "" and helpers and type(helpers.GetWorld) == "function" then
            local world_ok, world = pcall(helpers.GetWorld)
            if world_ok and world then
                world_pointer = OmeggaNormalizeObjectPointer(world) or ""
            end
        end
        local ok, output = pcall(BMFSocketKismetConsoleCommandProbe, probe_command, "kismet-console-command-probe", world_pointer)
        return true,
            "emulated-bmf-kismet-console-command-probe",
            ok and tostring(output or "") or ("BMFSocketKismetConsoleCommandProbe crashed: " .. tostring(output))
    end

    local bmf_process_console_exec_probe = command:match("^Omegga%.Bridge%.BmfProcessConsoleExecProbe%s+(.+)$")
    if bmf_process_console_exec_probe and trim(bmf_process_console_exec_probe) ~= "" then
        if type(BMFSocketProcessConsoleExecProbe) ~= "function" then
            return true, "emulated-bmf-process-console-exec-probe", "BMFSocketProcessConsoleExecProbe helper missing"
        end
        local probe_command = trim(bmf_process_console_exec_probe)
        local explicit_context, remaining_command = probe_command:match("^context=([^%s]+)%s+(.+)$")
        local context_pointer = ""
        if explicit_context and trim(remaining_command or "") ~= "" then
            context_pointer = trim(explicit_context)
            probe_command = trim(remaining_command)
        end
        local ok, output = pcall(BMFSocketProcessConsoleExecProbe, probe_command, "process-console-exec-probe", context_pointer)
        return true,
            "emulated-bmf-process-console-exec-probe",
            ok and tostring(output or "") or ("BMFSocketProcessConsoleExecProbe crashed: " .. tostring(output))
    end

    local bmf_console_manager_input_probe = command:match("^Omegga%.Bridge%.BmfConsoleManagerInputProbe%s+(.+)$")
    if bmf_console_manager_input_probe and trim(bmf_console_manager_input_probe) ~= "" then
        if type(BMFSocketConsoleManagerInputProbe) ~= "function" then
            return true, "emulated-bmf-console-manager-input-probe", "BMFSocketConsoleManagerInputProbe helper missing"
        end
        local probe_command = trim(bmf_console_manager_input_probe)
        local offset_text = ""
        local world_mode = ""
        for _ = 1, 2 do
            local key, value, rest = probe_command:match("^([%w_%-]+)=([^%s]+)%s+(.+)$")
            if not key or trim(rest or "") == "" then
                break
            end
            key = trim(key)
            if key == "offset" then
                offset_text = trim(value)
                probe_command = trim(rest)
            elseif key == "world" then
                world_mode = trim(value)
                probe_command = trim(rest)
            else
                break
            end
        end
        local ok, output = pcall(BMFSocketConsoleManagerInputProbe, probe_command, "console-manager-input-probe", offset_text, world_mode)
        return true,
            "emulated-bmf-console-manager-input-probe",
            ok and tostring(output or "") or ("BMFSocketConsoleManagerInputProbe crashed: " .. tostring(output))
    end

    local bmf_dispatch = command:match("^Omegga%.Bridge%.BmfDispatch%s+(.+)$")
    if bmf_dispatch and trim(bmf_dispatch) ~= "" then
        return true, "emulated-bmf-dispatch", OmeggaBridgeDispatchBmfCommand(trim(bmf_dispatch))
    end

    local describe_name = command:match("^Omegga%.Bridge%.DescribeObjectName%s+(.+)$")
    if describe_name and trim(describe_name) ~= "" then
        return true, "emulated-describe-object-name", describe_named_object_hits(trim(describe_name), true)
    end

    local describe_lite_name = command:match("^Omegga%.Bridge%.DescribeObjectNameLite%s+(.+)$")
    if describe_lite_name and trim(describe_lite_name) ~= "" then
        return true, "emulated-describe-object-name-lite", describe_named_object_hits(trim(describe_lite_name), false)
    end

    local probe_method = command:match("^Omegga%.Bridge%.ProbeMethod%s+(.+)$")
    if probe_method and trim(probe_method) ~= "" then
        return true, "emulated-probe-method", probe_callable_method(trim(probe_method))
    end

    local dump_prefab_actors = command:match("^Omegga%.Bridge%.DumpPrefabActors%s*(.*)$")
    if dump_prefab_actors ~= nil then
        return true, "emulated-dump-prefab-actors", dump_prefab_actor_locations(trim(dump_prefab_actors))
    end

    local describe_prefab_runtime_spec = command:match("^Omegga%.Bridge%.DescribePrefabRuntime%s*(.*)$")
    if describe_prefab_runtime_spec ~= nil then
        if type(describe_prefab_runtime_spec) ~= "string" then
            describe_prefab_runtime_spec = ""
        end
        return true, "emulated-describe-prefab-runtime", describe_prefab_runtime(trim(describe_prefab_runtime_spec))
    end

    local install_prefab_native_hooks = command:match("^Omegga%.Bridge%.InstallPrefabNativeHooks%s*(.*)$")
    if install_prefab_native_hooks ~= nil then
        if type(OmeggaInstallPrefabNativeHooks) ~= "function" then
            return true, "emulated-install-prefab-native-hooks", "prefab native hook helper missing"
        end
        local ok, output = pcall(OmeggaInstallPrefabNativeHooks, trim(install_prefab_native_hooks))
        return true,
            "emulated-install-prefab-native-hooks",
            ok and tostring(output or "") or ("prefab native hook install crashed: " .. tostring(output))
    end

    local describe_prefab_native_hooks = command:match("^Omegga%.Bridge%.DescribePrefabNativeHooks%s*(.*)$")
    if describe_prefab_native_hooks ~= nil then
        if type(OmeggaDescribePrefabNativeHooks) ~= "function" then
            return true, "emulated-describe-prefab-native-hooks", "prefab native hook describe helper missing"
        end
        local ok, output = pcall(OmeggaDescribePrefabNativeHooks, trim(describe_prefab_native_hooks))
        return true,
            "emulated-describe-prefab-native-hooks",
            ok and tostring(output or "") or ("prefab native hook describe crashed: " .. tostring(output))
    end

    local describe_prefab_native_capture =
        command:match("^Omegga%.Bridge%.DescribeLastPrefabNativeCapture%s*(.*)$")
    if describe_prefab_native_capture ~= nil then
        if type(OmeggaDescribeLastPrefabNativeCapture) ~= "function" then
            return true, "emulated-describe-prefab-native-capture", "prefab native capture helper missing"
        end
        local ok, output = pcall(OmeggaDescribeLastPrefabNativeCapture, trim(describe_prefab_native_capture))
        return true,
            "emulated-describe-prefab-native-capture",
            ok and tostring(output or "") or ("prefab native capture describe crashed: " .. tostring(output))
    end

    if command == "Omegga.Bridge.DescribePrefabNativeReplay" then
        if type(OmeggaDescribePrefabNativeReplay) ~= "function" then
            return true, "emulated-describe-prefab-native-replay", "prefab native replay helper missing"
        end
        local ok, output = pcall(OmeggaDescribePrefabNativeReplay)
        return true,
            "emulated-describe-prefab-native-replay",
            ok and tostring(output or "") or ("prefab native replay describe crashed: " .. tostring(output))
    end

    if command == "Omegga.Bridge.DescribeServerPastePrefabContext"
        or command == "Omegga.Bridge.DescribePrefabNativeContext" then
        if type(OmeggaDescribeServerPastePrefabContext) ~= "function" then
            return true, "emulated-describe-prefab-native-context", "prefab native context helper missing"
        end
        local ok, output = pcall(OmeggaDescribeServerPastePrefabContext)
        return true,
            "emulated-describe-prefab-native-context",
            ok and tostring(output or "") or ("prefab native context describe crashed: " .. tostring(output))
    end

    local describe_player_location = command:match("^Omegga%.Bridge%.DescribePlayerLocation%s*(.*)$")
    if describe_player_location ~= nil then
        if type(OmeggaDescribePlayerLocation) ~= "function" then
            return true, "emulated-describe-player-location", "player location helper missing"
        end
        local ok, output = pcall(OmeggaDescribePlayerLocation, trim(describe_player_location))
        return true,
            "emulated-describe-player-location",
            ok and tostring(output or "") or ("player location describe crashed: " .. tostring(output))
    end

    if command == "Omegga.Bridge.DescribePrefabPlacementContext" then
        if type(OmeggaDescribePrefabPlacementContext) ~= "function" then
            return true, "emulated-describe-prefab-placement-context", "prefab placement context helper missing"
        end
        local ok, output = pcall(OmeggaDescribePrefabPlacementContext)
        return true,
            "emulated-describe-prefab-placement-context",
            ok and tostring(output or "") or ("prefab placement context describe crashed: " .. tostring(output))
    end

    if command == "Omegga.Bridge.SelfTestPrefabNativeReplay" then
        if type(OmeggaSelfTestPrefabNativeReplayBuffer) ~= "function" then
            return true, "emulated-self-test-prefab-native-replay", "prefab native replay self-test missing"
        end
        local ok, output = pcall(OmeggaSelfTestPrefabNativeReplayBuffer)
        return true,
            "emulated-self-test-prefab-native-replay",
            ok and tostring(output or "") or ("prefab native replay self-test crashed: " .. tostring(output))
    end

    local arm_raw_process_event_capture = command:match("^Omegga%.Bridge%.ArmRawProcessEventCapture%s*(.*)$")
    if arm_raw_process_event_capture ~= nil then
        if type(OmeggaArmRawProcessEventCapture) ~= "function" then
            return true, "emulated-arm-raw-process-event-capture", "raw ProcessEvent capture helper missing"
        end
        local ok, output = pcall(OmeggaArmRawProcessEventCapture, trim(arm_raw_process_event_capture))
        return true,
            "emulated-arm-raw-process-event-capture",
            ok and tostring(output or "") or ("raw ProcessEvent capture arm crashed: " .. tostring(output))
    end

    if command == "Omegga.Bridge.DescribeRawProcessEventCapture" then
        if type(OmeggaDescribeRawProcessEventCapture) ~= "function" then
            return true, "emulated-describe-raw-process-event-capture", "raw ProcessEvent capture helper missing"
        end
        local ok, output = pcall(OmeggaDescribeRawProcessEventCapture)
        return true,
            "emulated-describe-raw-process-event-capture",
            ok and tostring(output or "") or ("raw ProcessEvent capture describe crashed: " .. tostring(output))
    end

    local describe_raw_process_event_capture_for =
        command:match("^Omegga%.Bridge%.DescribeRawProcessEventCaptureFor%s+(.+)$")
    if describe_raw_process_event_capture_for and trim(describe_raw_process_event_capture_for) ~= "" then
        if type(OmeggaDescribeRawProcessEventCaptureFor) ~= "function" then
            return true, "emulated-describe-raw-process-event-capture-for", "raw ProcessEvent capture-for helper missing"
        end
        local ok, output = pcall(OmeggaDescribeRawProcessEventCaptureFor, trim(describe_raw_process_event_capture_for))
        return true,
            "emulated-describe-raw-process-event-capture-for",
            ok and tostring(output or "") or ("raw ProcessEvent capture-for describe crashed: " .. tostring(output))
    end

    local replay_raw_process_event_capture = command:match("^Omegga%.Bridge%.ReplayLastRawProcessEventCapture%s*(.*)$")
    if replay_raw_process_event_capture ~= nil then
        if type(OmeggaReplayLastRawProcessEventCapture) ~= "function" then
            return true, "emulated-replay-raw-process-event-capture", "raw ProcessEvent replay helper missing"
        end
        local ok, output = pcall(OmeggaReplayLastRawProcessEventCapture, trim(replay_raw_process_event_capture))
        return true,
            "emulated-replay-raw-process-event-capture",
            ok and tostring(output or "") or ("raw ProcessEvent capture replay crashed: " .. tostring(output))
    end

    local replay_raw_native_function_capture = command:match("^Omegga%.Bridge%.ReplayLastRawNativeFunctionCapture%s*(.*)$")
    if replay_raw_native_function_capture ~= nil then
        if type(OmeggaReplayLastRawNativeFunctionCapture) ~= "function" then
            return true, "emulated-replay-raw-native-function-capture", "raw native function replay helper missing"
        end
        local ok, output = pcall(OmeggaReplayLastRawNativeFunctionCapture, trim(replay_raw_native_function_capture))
        return true,
            "emulated-replay-raw-native-function-capture",
            ok and tostring(output or "") or ("raw native function capture replay crashed: " .. tostring(output))
    end

    if command == "Omegga.Bridge.DisableRawProcessEventCapture" then
        if type(OmeggaDisableRawProcessEventCapture) ~= "function" then
            return true, "emulated-disable-raw-process-event-capture", "raw ProcessEvent capture helper missing"
        end
        local ok, output = pcall(OmeggaDisableRawProcessEventCapture)
        return true,
            "emulated-disable-raw-process-event-capture",
            ok and tostring(output or "") or ("raw ProcessEvent capture disable crashed: " .. tostring(output))
    end

    local paste_prefab_hash = command:match("^Omegga%.Bridge%.PastePrefabHash%s+(.+)$")
        or command:match("^Omegga%.Bridge%.ServerPastePrefabHash%s+(.+)$")
    if paste_prefab_hash ~= nil then
        if type(OmeggaPastePrefabHash) ~= "function" then
            return true, "emulated-paste-prefab-hash", "prefab hash paste helper missing"
        end
        local ok, output = pcall(OmeggaPastePrefabHash, trim(paste_prefab_hash))
        return true,
            "emulated-paste-prefab-hash",
            ok and tostring(output or "") or ("prefab hash paste crashed: " .. tostring(output))
    end

    local place_current_prefab = command:match("^Omegga%.Bridge%.PlaceCurrentPrefab%s+(.+)$")
        or command:match("^Omegga%.Bridge%.ServerPlaceCurrentPrefab%s+(.+)$")
        or command:match("^Omegga%.Bridge%.PlaceCurrentPrefabHash%s+(.+)$")
    if place_current_prefab ~= nil then
        if type(OmeggaPlaceCurrentPrefab) ~= "function" then
            return true, "emulated-place-current-prefab", "place current prefab helper missing"
        end
        local ok, output = pcall(OmeggaPlaceCurrentPrefab, trim(place_current_prefab))
        return true,
            "emulated-place-current-prefab",
            ok and tostring(output or "") or ("place current prefab crashed: " .. tostring(output))
    end

    local paste_and_place_prefab_hash =
        command:match("^Omegga%.Bridge%.PasteAndPlacePrefabHash%s+(.+)$")
        or command:match("^Omegga%.Bridge%.ServerPasteAndPlacePrefabHash%s+(.+)$")
    if paste_and_place_prefab_hash ~= nil then
        if type(OmeggaPasteAndPlacePrefabHash) ~= "function" then
            return true, "emulated-paste-and-place-prefab-hash", "prefab hash paste/place helper missing"
        end
        local ok, output = pcall(OmeggaPasteAndPlacePrefabHash, trim(paste_and_place_prefab_hash))
        return true,
            "emulated-paste-and-place-prefab-hash",
            ok and tostring(output or "") or ("prefab hash paste/place crashed: " .. tostring(output))
    end

    local replay_prefab_native_capture = command:match("^Omegga%.Bridge%.ReplayLastPrefabNativeCapture%s*(.*)$")
    if replay_prefab_native_capture ~= nil then
        if type(OmeggaReplayLastPrefabNativeCapture) ~= "function" then
            return true, "emulated-replay-prefab-native-capture", "prefab native replay helper missing"
        end
        local ok, output = pcall(OmeggaReplayLastPrefabNativeCapture, trim(replay_prefab_native_capture))
        return true,
            "emulated-replay-prefab-native-capture",
            ok and tostring(output or "") or ("prefab native replay crashed: " .. tostring(output))
    end

    local probe_call_by_name = command:match("^Omegga%.Bridge%.ProbeCallByName%s+(.+)$")
    if probe_call_by_name and trim(probe_call_by_name) ~= "" then
        return true, "emulated-probe-call-by-name", OmeggaProbeCallByName(trim(probe_call_by_name))
    end

    local client_travel = command:match("^Omegga%.Bridge%.ClientTravel%s+(.+)$")
    if client_travel and trim(client_travel) ~= "" then
        local ok, output = pcall(OmeggaClientTravel, trim(client_travel))
        return true,
            "emulated-client-travel",
            ok and tostring(output or "") or ("client travel crashed: " .. tostring(output))
    end

    local probe_function_signature = command:match("^Omegga%.Bridge%.ProbeFunctionSignature%s+(.+)$")
    if probe_function_signature and trim(probe_function_signature) ~= "" then
        return true, "emulated-probe-function-signature", OmeggaProbeFunctionSignature(trim(probe_function_signature))
    end

    local describe_function_object = command:match("^Omegga%.Bridge%.DescribeFunctionObject%s+(.+)$")
        or command:match("^Omegga%.Bridge%.DescribeUFunctionSignature%s+(.+)$")
    if describe_function_object and trim(describe_function_object) ~= "" then
        return true, "emulated-describe-function-object", OmeggaDescribeFunctionObject(trim(describe_function_object))
    end

    local probe_function_fields = command:match("^Omegga%.Bridge%.ProbeFunctionFields%s+(.+)$")
    if probe_function_fields and trim(probe_function_fields) ~= "" then
        return true, "emulated-probe-function-fields", OmeggaProbeFunctionFields(trim(probe_function_fields))
    end

    local list_functions_by_hint = command:match("^Omegga%.Bridge%.ListFunctionsByHint%s+(.+)$")
        or command:match("^Omegga%.Bridge%.ListFunctions%s+(.+)$")
    if list_functions_by_hint and trim(list_functions_by_hint) ~= "" then
        return true, "emulated-list-functions-by-hint", OmeggaListFunctionsByHint(trim(list_functions_by_hint))
    end

    local force_console_executor = command:match("^Omegga%.Bridge%.ForceConsoleExecutor%s+(.+)$")
    if force_console_executor and trim(force_console_executor) ~= "" then
        return true, "emulated-force-console-executor", OmeggaForceConsoleExecutor(trim(force_console_executor))
    end

    if command == "Server.Status" then
        local output, detail = build_status_output()
        if output then
            return true, "emulated-server-status", output
        end
        return false, detail or "status emulation failed", ""
    end

    if command == "GetAll BRPlayerState UserName" then
        local output, detail = build_brplayerstate_username_output()
        if output then
            return true, "emulated-brplayerstate-username", output
        end
        bridge_log("warn", "BRPlayerState UserName emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    local owner_target = command:match("^GetAll BRPlayerState Owner Name=(.+)$")
    if owner_target then
        local output, detail = build_brplayerstate_owner_output(trim(owner_target))
        if output then
            return true, "emulated-brplayerstate-owner", output
        end
        bridge_log("warn", "BRPlayerState Owner emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    local controller_pawn_target = command:match("^GetAll BP_PlayerController_C Pawn Name=(.+)$")
    if controller_pawn_target then
        local output, detail = build_bp_playercontroller_pawn_output(trim(controller_pawn_target))
        if output then
            return true, "emulated-bp-playercontroller-pawn", output
        end
        bridge_log("warn", "BP_PlayerController_C Pawn emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    if command == "GetAll BP_PlayerController_C Pawn" then
        local output, detail = build_bp_playercontroller_pawn_output("")
        if output then
            return true, "emulated-bp-playercontroller-pawns", output
        end
        bridge_log("warn", "BP_PlayerController_C Pawn list emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    local position_target = command:match("^GetAll SceneComponent RelativeLocation Name=CollisionCylinder Outer=(.+)$")
    if position_target then
        local output, detail = build_collision_cylinder_location_output(trim(position_target))
        if output then
            return true, "emulated-collision-cylinder-location", output
        end
        bridge_log("warn", "CollisionCylinder RelativeLocation emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    if command == "GetAll SceneComponent RelativeLocation Name=CollisionCylinder" then
        local output, detail = build_collision_cylinder_location_output("")
        if output then
            return true, "emulated-collision-cylinder-locations", output
        end
        bridge_log("warn", "CollisionCylinder RelativeLocation list emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    if command == "GetAll BP_FigureV2_C bIsDead" then
        local output, detail = build_bp_figure_dead_output("")
        if output then
            return true, "emulated-bp-figure-dead", output
        end
        bridge_log("warn", "BP_FigureV2_C bIsDead emulation unavailable: " .. tostring(detail))
        return nil, nil, nil
    end

    return nil, nil, nil
end

local function finish_command_success(id, command, executor, output)
    bridge_log("info", "Executed console command via " .. executor .. ": " .. command)
    set_status("running", { last_command = command, executor = executor })
    send_response(
        id,
        json_object({
            json_bool_field("accepted", true),
            json_string_field("executor", executor),
        }),
        false
    )
    local chunk_count = send_console_chunks(id, command, output)
    send_notification(
        "console.complete",
        json_object({
            string.format("\"request_id\":%d", id),
            string.format("\"chunk_count\":%d", chunk_count),
            json_bool_field("success", true),
            json_string_field("executor", executor),
            json_string_field("command_b64", base64_encode(command)),
        })
    )
end

local function finish_command_error(id, command, message, detail, code)
    bridge_log("error", message)
    set_status("error", { last_command = command, detail = detail or message })
    send_response(
        id,
        json_object({
            string.format("\"code\":%d", code or -32002),
            json_string_field("message", message),
            json_string_field("data", detail or ""),
        }),
        true
    )
    send_notification(
        "console.complete",
        json_object({
            string.format("\"request_id\":%d", id),
            json_bool_field("success", false),
            json_string_field("detail", detail or message),
            json_string_field("command_b64", base64_encode(command)),
        })
    )
end

local function try_execute_chat_broadcast_command(command)
    if PREFER_TYPED_CHAT_BROADCAST then
        local broadcast_text = command:match("^Chat%.Broadcast%s+(.+)$")
        if broadcast_text and trim(broadcast_text) ~= "" then
            local success, broadcast_executor_or_error = handle_typed_chat_broadcast(broadcast_text)
            if success then
                return true, broadcast_executor_or_error, ""
            end
            bridge_log(
                "warn",
                "Typed chat broadcast failed, falling back to console executors: " .. tostring(broadcast_executor_or_error)
            )
        end
    end

    if type(OmeggaExecuteKismetConsoleCommand) == "function" then
        local exec_ok, success, output = pcall(OmeggaExecuteKismetConsoleCommand, command)
        if not exec_ok then
            bridge_log("warn", "Kismet chat broadcast helper failed: " .. tostring(success))
        elseif success then
            bridge_log("info", "Chat.Broadcast executed via Kismet ExecuteConsoleCommand")
            return true, "cached-kismet-system-library", output or ""
        else
            bridge_log("warn", "Kismet chat broadcast rejected command: " .. tostring(command))
            return false, tostring(output or "command rejected"), output or ""
        end
    end

    if type(OmeggaHasCachedEngineExecContext) == "function"
        and type(OmeggaExecuteCachedEngineExec) == "function" then
        local has_engine_ok, has_engine = pcall(OmeggaHasCachedEngineExecContext)
        if has_engine_ok and has_engine then
            local exec_ok, success, output = pcall(OmeggaExecuteCachedEngineExec, command)
            if not exec_ok then
                bridge_log("warn", "GameEngine::Exec chat broadcast helper failed: " .. tostring(success))
            elseif success then
                bridge_log("info", "Chat.Broadcast executed via GameEngine::Exec")
                return true, "cached-game-engine", output or ""
            else
                bridge_log("warn", "GameEngine::Exec chat broadcast rejected command: " .. tostring(command))
                return false, tostring(output or "command rejected"), output or ""
            end
        end
    end

    return nil, "No non-typed chat broadcast executor is available.", ""
end

local function try_execute_console_command(command)
    local emulated, executor, output = try_emulate_command(command)
    if emulated ~= nil then
        return emulated, executor, output or ""
    end

    local broadcast_text = command:match("^Chat%.Broadcast%s+(.+)$")
    if broadcast_text then
        if trim(broadcast_text) == "" then
            return false, "Chat.Broadcast requires a message."
        end

        local success, broadcast_executor_or_error, broadcast_output = try_execute_chat_broadcast_command(command)
        if success ~= nil then
            return success, broadcast_executor_or_error, broadcast_output or ""
        end

        return false, tostring(broadcast_executor_or_error or "No non-typed chat broadcast executor is available.")
    end

    local whisper_target, whisper_text = command:match("^Chat%.Whisper%s+\"([^\"]+)\"%s+(.+)$")
    if whisper_target and whisper_text then
        local success, whisper_executor_or_error = handle_typed_chat_whisper(whisper_target, whisper_text)
        if success then
            return true, whisper_executor_or_error, ""
        end

        return false, tostring(whisper_executor_or_error)
    end

    local status_target, status_text = command:match("^Chat%.StatusMessage%s+\"([^\"]+)\"%s+(.+)$")
    if status_target and status_text then
        local success, status_executor_or_error = handle_typed_chat_status_message(status_target, status_text)
        if success then
            return true, status_executor_or_error, ""
        end

        return false, tostring(status_executor_or_error)
    end

    if type(OmeggaHasCachedCommandContext) ~= "function"
        or type(OmeggaExecuteCachedConsoleExec) ~= "function" then
        return nil, "Managed UE4SS command helpers are not available."
    end

    if type(OmeggaHasCachedEngineExecContext) == "function"
        and type(OmeggaExecuteCachedEngineExec) == "function" then
        local has_engine_ok, has_engine = pcall(OmeggaHasCachedEngineExecContext)
        if has_engine_ok and has_engine then
            local exec_ok, success, output = pcall(OmeggaExecuteCachedEngineExec, command)
            if not exec_ok then
                bridge_log("warn", "GameEngine::Exec helper failed: " .. tostring(success))
            elseif success then
                return true, "cached-game-engine", output or ""
            else
                bridge_log("warn", "GameEngine::Exec rejected command: " .. tostring(command))
            end
        end
    end

    local has_context_ok, has_context = pcall(OmeggaHasCachedCommandContext)
    if not has_context_ok then
        return nil, tostring(has_context)
    end

    if not has_context then
        return nil, "No cached command context is available yet."
    end

    if should_avoid_cached_console_exec(command) then
        return false,
            "Windows UE4SS bridge avoids ProcessConsoleExec for Chat.* commands because it crashes on this Brickadia build."
    end

    local exec_ok, success, output = pcall(OmeggaExecuteCachedConsoleExec, command)
    if not exec_ok then
        return nil, tostring(success)
    end

    if success then
        return true, "cached-init-game-state", output or ""
    end

    local detail = output
    if not detail or detail == "" then
        detail = "command rejected"
    end

    if not should_use_kismet_fallback(command) then
        bridge_log(
            "info",
            "Skipping Kismet ExecuteConsoleCommand fallback for side-effect command: " .. tostring(command)
        )
        return false, detail
    end

    if type(OmeggaExecuteKismetConsoleCommand) == "function" then
        local exec_ok, kismet_success, kismet_output = pcall(OmeggaExecuteKismetConsoleCommand, command)
        if not exec_ok then
            bridge_log("warn", "Kismet ExecuteConsoleCommand helper failed: " .. tostring(kismet_success))
        elseif kismet_success then
            return true, "cached-kismet-system-library", kismet_output or ""
        else
            bridge_log("warn", "Kismet ExecuteConsoleCommand rejected command: " .. tostring(command))
        end
    end

    return false, detail
end

local function is_in_thread(label, fn)
    if type(fn) ~= "function" then
        return "unknown"
    end

    local ok, value = pcall(fn)
    if not ok then
        bridge_log("warn", "Failed to query " .. label .. ": " .. tostring(value))
        return "error"
    end

    return value and "true" or "false"
end

local function drain_pending_console_execs(trigger)
    if is_draining_console_execs or #pending_console_execs == 0 then
        return
    end

    is_draining_console_execs = true
    local request = table.remove(pending_console_execs, 1)

    local ok, result, detail, output = pcall(try_execute_console_command, request.command)
    if not ok then
        finish_command_error(
            request.id,
            request.command,
            "Command execution crashed before completion: " .. tostring(result),
            tostring(result),
            -32002
        )
        is_draining_console_execs = false
        return
    end

    if result then
        finish_command_success(
            request.id,
            request.command,
            tostring(detail) .. " [" .. trigger .. "]",
            output or ""
        )
    else
        finish_command_error(
            request.id,
            request.command,
            "ProcessConsoleExec returned false",
            tostring(detail),
            -32001
        )
    end

    is_draining_console_execs = false
end

local function install_game_thread_exec_hook()
    if queue_hook_path or queue_hook_attempted or type(RegisterHook) ~= "function" then
        return queue_hook_path ~= nil
    end

    queue_hook_attempted = true

    for _, hook_path in ipairs(GAME_THREAD_HOOK_CANDIDATES) do
        local ok, pre_id, post_id = pcall(RegisterHook, hook_path, function(Context, DeltaSeconds)
            remember_command_context(Context, nil, nil, "game-thread-exec-hook")
            if not queue_hook_fired then
                queue_hook_fired = true
                bridge_log("info", "Game-thread exec hook fired via " .. hook_path)
            end

            drain_pending_console_execs(hook_path)
        end)

        if ok and type(pre_id) == "number" and type(post_id) == "number" then
            queue_hook_path = hook_path
            queue_hook_pre_id = pre_id
            queue_hook_post_id = post_id
            bridge_log(
                "info",
                "Installed game-thread exec hook "
                    .. hook_path
                    .. " (pre="
                    .. tostring(pre_id)
                    .. ", post="
                    .. tostring(post_id)
                    .. ")"
            )
            return true
        end

        bridge_log("warn", "Failed to install game-thread exec hook " .. hook_path .. ": " .. tostring(pre_id))
    end

    return false
end

local function execute_command(id, command)
    set_status("executing", { last_command = command })

    if command == "Chat.MessageForUnknownCommands 0"
        or command == "br.Chat.MessageForUnknownCommands 0" then
        if type(BMFSocketSetUnknownCommandMessages) == "function" then
            local call_ok, applied, output = pcall(BMFSocketSetUnknownCommandMessages, false)
            if call_ok and applied then
                finish_command_success(
                    id,
                    command,
                    "bmf-native-unknown-command-flag",
                    tostring(output or "")
                )
                return
            end

            bridge_log(
                "warn",
                "Native Chat.MessageForUnknownCommands backing-flag update failed: "
                    .. tostring(call_ok and output or applied)
            )
        else
            bridge_log("warn", "BMFSocketSetUnknownCommandMessages helper is unavailable")
        end

        local has_engine_tick_scheduler = type(ExecuteInGameThread) == "function"
            and type(EGameThreadMethod) == "table"
            and EGameThreadMethod.EngineTick ~= nil
        if not has_engine_tick_scheduler then
            bridge_log("warn", "Cannot apply Chat.MessageForUnknownCommands without a game-thread scheduler")
            finish_command_success(id, command, "noop", "")
            return
        end

        local scheduled_ok, scheduled_error = pcall(function()
            schedule_on_game_thread(function()
                if type(IsInGameThread) == "function" then
                    local thread_ok, on_game_thread = pcall(IsInGameThread)
                    if not thread_ok or not on_game_thread then
                        bridge_log("warn", "Refusing to apply Chat.MessageForUnknownCommands outside the game thread")
                        finish_command_success(id, command, "noop", "")
                        return
                    end
                end

                if type(OmeggaExecuteKismetConsoleCommand) == "function" then
                    local exec_ok, success, output = pcall(OmeggaExecuteKismetConsoleCommand, command)
                    if exec_ok and success then
                        finish_command_success(id, command, "kismet-message-for-unknown-commands", output or "")
                        return
                    end

                    bridge_log(
                        "warn",
                        "Cached-context Kismet Chat.MessageForUnknownCommands bootstrap failed: "
                            .. tostring(exec_ok and output or success)
                    )
                end

                if type(BMFSocketKismetConsoleCommandProbe) == "function" then
                    local world_pointer = ""
                    local helpers = type(UEHelpers) == "table" and UEHelpers or nil
                    if not helpers then
                        local helpers_ok, loaded_helpers = pcall(require, "UEHelpers")
                        if helpers_ok and type(loaded_helpers) == "table" then
                            helpers = loaded_helpers
                        end
                    end
                    if helpers and type(helpers.GetWorld) == "function" then
                        local world_ok, world = pcall(helpers.GetWorld)
                        if world_ok and world and type(OmeggaNormalizeObjectPointer) == "function" then
                            local normalize_ok, normalized_world = pcall(OmeggaNormalizeObjectPointer, world)
                            if normalize_ok then
                                world_pointer = normalized_world or ""
                            end
                        end
                    end
                    local native_ok, native_output = pcall(
                        BMFSocketKismetConsoleCommandProbe,
                        command,
                        "kismet-console-command-probe-fast",
                        world_pointer
                    )
                    local output = tostring(native_output or "")
                    local output_lines = "\n" .. output .. "\n"
                    if native_ok and output_lines:find("\nok=true\n", 1, true) then
                        finish_command_success(id, command, "bmf-kismet-message-for-unknown-commands", output)
                        return
                    end

                    bridge_log(
                        "warn",
                        "Native Kismet Chat.MessageForUnknownCommands bootstrap failed: "
                            .. tostring(native_ok and output or native_output)
                    )
                else
                    bridge_log("warn", "BMFSocketKismetConsoleCommandProbe helper is unavailable")
                end

                finish_command_success(id, command, "noop", "")
            end)
        end)

        if not scheduled_ok then
            finish_command_error(
                id,
                command,
                "Failed to schedule Chat.MessageForUnknownCommands on the game thread",
                tostring(scheduled_error),
                -32002
            )
        end
        return
    end

    if should_handle_emulated_immediately(command) then
        local emulation_ok, emulated_result, emulated_executor, emulated_output =
            pcall(try_emulate_command, command)
        if not emulation_ok then
            bridge_log(
                "warn",
                "Immediate emulated command handling crashed before UE4SS game-thread scheduling: "
                    .. tostring(emulated_result)
            )
            finish_command_error(
                id,
                command,
                "Immediate emulated command handling crashed",
                tostring(emulated_result),
                -32002
            )
            return
        end

        if emulated_result ~= nil then
            if emulated_result then
                bridge_log(
                    "info",
                    "Handled command without UE4SS game-thread scheduling via " .. tostring(emulated_executor)
                )
                set_status("running", { last_command = command, executor = emulated_executor })
                finish_command_success(id, command, emulated_executor, emulated_output or "")
                return
            end

            bridge_log(
                "warn",
                "Emulated command handling failed before UE4SS game-thread scheduling: "
                    .. tostring(emulated_executor)
            )
            finish_command_error(
                id,
                command,
                "Emulated command handling failed",
                tostring(emulated_executor),
                -32001
            )
            return
        end
    end

    bridge_log(
        "info",
        "Scheduling command execution via UE4SS "
            .. "(has_cached_context="
            .. ((type(OmeggaHasCachedCommandContext) == "function"
                    and pcall(OmeggaHasCachedCommandContext)
                    and OmeggaHasCachedCommandContext()) and "true" or "false")
            .. ", is_game_thread="
            .. is_in_thread("IsInGameThread", IsInGameThread)
            .. ", is_async_thread="
            .. is_in_thread("IsInAsyncThread", IsInAsyncThread)
            .. ")"
    )

    local ok, err = pcall(function()
        schedule_on_game_thread(function()
            local inner_ok, inner_result, inner_detail, inner_output = pcall(try_execute_console_command, command)

            if not inner_ok then
                finish_command_error(
                    id,
                    command,
                    "Command execution crashed before completion: " .. tostring(inner_result),
                    tostring(inner_result),
                    -32002
                )
                return
            end

            if inner_result then
                finish_command_success(id, command, inner_detail, inner_output or "")
                return
            end

            finish_command_error(
                id,
                command,
                "ProcessConsoleExec returned false",
                tostring(inner_detail),
                -32001
            )
        end)
    end)

    if not ok then
        finish_command_error(
            id,
            command,
            "Command execution crashed before completion: " .. tostring(err),
            tostring(err),
            -32002
        )
    end
end

function unsafe_console_exec_block_reason(command)
    local lower = trim(command or ""):lower()
    if lower:match("^server%.players%.setteam%s+") then
        return "Server.Players.SetTeam is blocked in the UE4SS bridge because this Brickadia dedicated-server build crashes in ProcessConsoleExec; use a BMF/native minigame team API instead"
    end
    if lower:match("^getall%s+bp_ruleset_c") then
        return "GetAll BP_Ruleset_C is blocked in the UE4SS bridge because it can crash this Brickadia dedicated-server build; use BMF minigame live/data commands instead"
    end
    if lower:match("^getall%s+bp_team_c") then
        return "GetAll BP_Team_C is blocked in the UE4SS bridge because it can crash this Brickadia dedicated-server build; use BMF minigame live/data commands instead"
    end
    return nil
end

local function handle_message(line)
    local message = parse_message(line)
    if not message.method then
        bridge_log("warn", "Ignoring malformed bridge message: " .. line)
        return
    end

    bridge_log("info", "Handling bridge message " .. message.method .. " id=" .. tostring(message.id or "nil"))

    if message.method == "bridge.ping" then
        send_response(
            message.id,
            json_object({
                json_bool_field("pong", true),
                json_string_field("nonce", message.nonce or ""),
                json_string_field("updated_at", now_utc()),
            }),
            false
        )
        return
    end

    if message.method == "server.status" then
        execute_command(message.id, "Server.Status")
        return
    end

    if message.method == "players.list" then
        local params = type(message.params) == "table" and message.params or {}
        local format = trim(params.format or message.format or "records")
        local state_name = trim(base64_decode(params.state_name_b64 or message.state_name_b64 or ""))

        if format == "usernames" then
            local output, detail = build_brplayerstate_username_output()
            if output then
                finish_command_success(
                    message.id,
                    "GetAll BRPlayerState UserName",
                    "typed-players-usernames",
                    output
                )
            else
                finish_command_error(
                    message.id,
                    "GetAll BRPlayerState UserName",
                    "Typed player list failed",
                    tostring(detail or "player state emulation failed"),
                    -32001
                )
            end
            return
        end

        if format == "owners" then
            local output, detail = build_brplayerstate_owner_output(state_name)
            if output then
                finish_command_success(
                    message.id,
                    "GetAll BRPlayerState Owner Name=" .. tostring(state_name),
                    "typed-players-owners",
                    output
                )
            else
                finish_command_error(
                    message.id,
                    "GetAll BRPlayerState Owner Name=" .. tostring(state_name),
                    "Typed player owner lookup failed",
                    tostring(detail or "player owner emulation failed"),
                    -32001
                )
            end
            return
        end

        local player_records = {}
        local objects = select(1, get_cached_game_objects())
        if objects then
            player_records = get_cached_player_state_records(objects.game_state, objects.world)
        end
        if #player_records == 0 then
            player_records = get_cached_player_state_records(nil, nil)
        end

        send_response(
            message.id,
            json_object({
                json_bool_field("accepted", true),
                json_string_field("executor", "typed-player-records"),
                json_string_field("count", tostring(#player_records)),
            }),
            false
        )
        return
    end

    if message.method == "chat.broadcast" then
        local text = base64_decode(message.message_b64 or "")
        execute_command(message.id, "Chat.Broadcast " .. quote_console_string(text))
        return
    end

    if message.method == "chat.whisper" then
        local target = base64_decode(message.target_b64 or "")
        local text = base64_decode(message.message_b64 or "")
        execute_command(message.id, "Chat.Whisper \"" .. quote_name(target) .. "\" " .. quote_console_string(text))
        return
    end

    if message.method == "chat.status_message" then
        local target = base64_decode(message.target_b64 or "")
        local text = base64_decode(message.message_b64 or "")
        execute_command(message.id, "Chat.StatusMessage \"" .. quote_name(target) .. "\" " .. quote_console_string(text))
        return
    end

    if message.method == "console.exec" then
        local command = base64_decode(message.command_b64 or "")
        if trim(command) == "" then
            command = trim(message.command_raw or "")
        end
        if command == "" then
            finish_command_error(
                message.id or 0,
                "",
                "Console command is empty",
                "console.exec requires command_b64 or command",
                -32602
            )
            return
        end
        local unsafe_reason = unsafe_console_exec_block_reason(command)
        if unsafe_reason ~= nil then
            finish_command_error(
                message.id or 0,
                command,
                "Console command blocked by OmeggaBridge safety policy",
                unsafe_reason,
                -32004
            )
            return
        end
        execute_command(message.id or 0, command)
        return
    end

    send_response(
        message.id or 0,
        json_object({
            string.format("\"code\":%d", -32601),
            json_string_field("message", "Method not found"),
            json_string_field("data", message.method),
        }),
        true
    )
end

local function schedule_game_thread_scheduler_probes()
    if not DEBUG_SCHEDULER then
        return
    end

    -- Capability inspection is deliberately non-registering. A repeating action
    -- used as a probe is still a real loop and can outlive a failed callback.
    bridge_log(
        "info",
        "Scheduler capability audit"
            .. " execute_game_thread=" .. tostring(type(ExecuteInGameThread) == "function")
            .. " execute_delay=" .. tostring(type(ExecuteInGameThreadWithDelay) == "function")
            .. " execute_frames=" .. tostring(type(ExecuteInGameThreadAfterFrames) == "function")
            .. " loop_delay=" .. tostring(type(LoopInGameThreadWithDelay) == "function")
            .. " loop_frames=" .. tostring(type(LoopInGameThreadAfterFrames) == "function")
            .. " cancel=" .. tostring(type(CancelDelayedAction) == "function")
            .. " engine_tick=" .. tostring(EngineTickAvailable == true)
    )
end

local function describe_remote_object(param)
    if not param or type(param.get) ~= "function" then
        return "nil"
    end

    local ok, object = pcall(function()
        return param:get()
    end)
    if not ok or not object then
        return "nil"
    end

    if object.IsValid and not object:IsValid() then
        return "invalid"
    end

    local name_ok, full_name = pcall(function()
        return object:GetFullName()
    end)
    if name_ok and full_name and full_name ~= "" then
        return tostring(full_name)
    end

    return tostring(object)
end

local function describe_value(value)
    local value_type = type(value)
    if value == nil then
        return "nil"
    end

    if value_type == "table" then
        local length_ok, length = pcall(function()
            return #value
        end)
        if length_ok then
            return "table(len=" .. tostring(length) .. ")"
        end
        return "table"
    end

    if value_type == "userdata" and value.IsValid and type(value.IsValid) == "function" then
        local valid_ok, valid = pcall(function()
            return value:IsValid()
        end)
        if valid_ok and valid and value.GetFullName and type(value.GetFullName) == "function" then
            local name_ok, full_name = pcall(function()
                return value:GetFullName()
            end)
            if name_ok and full_name and full_name ~= "" then
                return tostring(full_name)
            end
        end
    end

    return tostring(value)
end

OMEGGA_PREFAB_NATIVE_CAPTURE = OMEGGA_PREFAB_NATIVE_CAPTURE or {
    registered = false,
    hooks = {},
    last = nil,
    last_client = nil,
    last_replayable_client = nil,
    last_replay_capture = nil,
    last_replay = nil,
    replay_active = false,
    replay_sequence = 0,
}

OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS = OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS or {}
OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS.ServerPastePrefab = true
OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS.ServerPlaceCurrentPrefab = true
OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS.ServerPlaceSimpleEntityVolume = true

OMEGGA_PREFAB_DEFAULT_PLACE_CURRENT_PREFAB_HEX =
    "00 00 00 00 00 00 00 00 00 B4 9E 0C B7 01 00 00 " ..
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 " ..
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 F0 3F " ..
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 " ..
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 " ..
    "00 00 00 00 00 00 F0 3F 00 00 00 00 00 00 F0 3F " ..
    "00 00 00 00 00 00 F0 3F 00 00 00 00 00 00 00 00 " ..
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 " ..
    "C4 FE FF FF 20 00 00 00 22 00 00 00 00 00 00 00 " ..
    "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 " ..
    "00 00 00 00 00 00 00 00 10 00 00 00 48 00 00 00 " ..
    "CC 00 00 00 44 00 00 00 00 00 00 00 00 00 00 00 " ..
    "00 00 00 00 01 00 00 00 01 00 00 00 01 00 00 00 " ..
    "01 00 00 00 01 00 00 00 FF FF FF FF 01 00 00"

function OmeggaResolveHookParamValue(value)
    if value ~= nil and type(value.get) == "function" then
        local ok, resolved = pcall(function()
            return value:get()
        end)
        if ok then
            return resolved, "param_get"
        end
    end

    if value ~= nil and type(value.Get) == "function" then
        local ok, resolved = pcall(function()
            return value:Get()
        end)
        if ok then
            return resolved, "param_Get"
        end
    end

    return value, "direct"
end

function OmeggaPrefabCaptureScalar(value)
    local value_type = type(value)
    return value == nil
        or value_type == "string"
        or value_type == "number"
        or value_type == "boolean"
end

function OmeggaPrefabCaptureValueSummary(value)
    local value_type = type(value)
    if value == nil then
        return "nil"
    end
    if value_type == "string" then
        return string.format("%q", value)
    end
    if value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    return value_type .. ":" .. safe_value_to_string(value)
end

function OmeggaPrefabCaptureTableKeys(value)
    local keys = {}
    for key, _ in pairs(value) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    return keys
end

function OmeggaPrefabCaptureAppendTableLines(lines, prefix, value, depth, seen, budget)
    if type(value) ~= "table" then
        return
    end

    seen = seen or {}
    budget = budget or { count = 0, max = 40 }
    if seen[value] then
        table.insert(lines, prefix .. "=<cycle>")
        return
    end
    seen[value] = true

    local keys = OmeggaPrefabCaptureTableKeys(value)
    table.insert(lines, prefix .. ".keys=" .. (#keys > 0 and table.concat(keys, ",") or "<none>"))

    for _, key in ipairs(keys) do
        if budget.count >= budget.max then
            table.insert(lines, prefix .. ".truncated=true")
            return
        end

        local child_ok, child_value = pcall(function()
            return value[key]
        end)
        if child_ok then
            budget.count = budget.count + 1
            local child_prefix = prefix .. "." .. tostring(key)
            if OmeggaPrefabCaptureScalar(child_value) then
                table.insert(lines, child_prefix .. "=" .. OmeggaPrefabCaptureValueSummary(child_value))
            elseif type(child_value) == "table" and depth > 0 then
                OmeggaPrefabCaptureAppendTableLines(lines, child_prefix, child_value, depth - 1, seen, budget)
            else
                table.insert(lines, child_prefix .. "=" .. OmeggaPrefabCaptureValueSummary(child_value))
            end
        end
    end
end

function OmeggaReadHookParamMemory(value)
    if value == nil then
        return nil
    end

    local memory = {}

    if type(value.GetAddress) == "function" then
        local ok, address = pcall(function()
            return value:GetAddress()
        end)
        if ok and address ~= nil then
            memory.address = address
        end
    end

    if type(value.GetSize) == "function" then
        local ok, size = pcall(function()
            return value:GetSize()
        end)
        if ok and size ~= nil then
            memory.size = size
        end
    end

    if type(value.GetPropertyName) == "function" then
        local ok, property_name = pcall(function()
            return value:GetPropertyName()
        end)
        if ok and property_name ~= nil and tostring(property_name) ~= "" then
            memory.property = tostring(property_name)
        end
    end

    if type(value.ReadBytesHex) == "function" then
        local ok, bytes = pcall(function()
            return value:ReadBytesHex()
        end)
        if ok and bytes ~= nil and tostring(bytes) ~= "" then
            memory.bytes = tostring(bytes)
        end
    end

    if next(memory) == nil then
        return nil
    end

    return memory
end

function OmeggaPrefabCaptureAppendMemoryLines(lines, label, value, prefix, memory)
    local snapshot = memory or OmeggaReadHookParamMemory(value)
    if not snapshot then
        return
    end

    local base = tostring(label) .. "." .. tostring(prefix or "param")

    if snapshot.address ~= nil then
        table.insert(lines, base .. ".address=" .. tostring(snapshot.address))
    end

    if snapshot.size ~= nil then
        table.insert(lines, base .. ".size=" .. tostring(snapshot.size))
    end

    if snapshot.property ~= nil and tostring(snapshot.property) ~= "" then
        table.insert(lines, base .. ".property=" .. tostring(snapshot.property))
    end

    if snapshot.bytes ~= nil and tostring(snapshot.bytes) ~= "" then
        table.insert(lines, base .. ".bytes=" .. tostring(snapshot.bytes))
    end
end

function OmeggaDescribeHookParam(label, value)
    local resolved, resolver = OmeggaResolveHookParamValue(value)
    local lines = {
        tostring(label) .. ".lua_type=" .. tostring(type(value)) .. " resolver=" .. tostring(resolver),
        tostring(label) .. ".value=" .. safe_value_to_string(resolved),
    }
    local memory = {
        raw = OmeggaReadHookParamMemory(value),
    }

    OmeggaPrefabCaptureAppendMemoryLines(lines, label, value, "raw", memory.raw)
    if resolved ~= value then
        memory.resolved = OmeggaReadHookParamMemory(resolved)
        OmeggaPrefabCaptureAppendMemoryLines(lines, label, resolved, "resolved", memory.resolved)
    end

    if resolved ~= value then
        table.insert(lines, tostring(label) .. ".raw=" .. safe_value_to_string(value))
    end

    if type(resolved) == "table" then
        OmeggaPrefabCaptureAppendTableLines(lines, tostring(label) .. ".table", resolved, 3)
    end

    if is_valid_object(resolved) then
        local class_ok, class_object = pcall(function()
            return resolved:GetClass()
        end)
        if class_ok and is_valid_object(class_object) then
            table.insert(lines, tostring(label) .. ".class=" .. get_object_short_name(class_object, "unknown"))
        end
    end

    if PREFAB_DUMP_READ_OBJECT_PROPERTIES then
        for _, property_name in ipairs({ "GridOffset", "PlacementOrientation", "Location", "Translation" }) do
            local property_value = try_get_property_value(resolved, property_name)
            if property_value ~= nil then
                table.insert(
                    lines,
                    tostring(label) .. "." .. tostring(property_name) .. "=" .. safe_value_to_string(property_value)
                )
            end
        end
    else
        table.insert(lines, tostring(label) .. ".properties=skipped-unsafe-property-read")
    end

    if PREFAB_DUMP_READ_OBJECT_PROPERTIES then
        local vector, nested_property = prefab_probe_vector_from_nested_value(resolved)
        if vector then
            table.insert(
                lines,
                tostring(label)
                    .. ".vector"
                    .. (nested_property and ("." .. tostring(nested_property)) or "")
                    .. "="
                    .. tostring(vector.x)
                    .. ","
                    .. tostring(vector.y)
                    .. ","
                    .. tostring(vector.z)
            )
        end
    end

    return lines, resolved, resolver, memory
end

function OmeggaRecordPrefabNativeCapture(kind, hook_path, Context, ...)
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    local source = state.replay_active and "replay" or "client"
    local record = {
        kind = tostring(kind or "prefab-native"),
        hook_path = tostring(hook_path or ""),
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        source = source,
        replay_id = state.active_replay_id,
        lines = {},
        args = {},
    }

    local context_object = nil
    if Context and type(Context.get) == "function" then
        local context_ok, context_value = pcall(function()
            return Context:get()
        end)
        if context_ok and is_valid_object(context_value) then
            context_object = context_value
        end
    end

    record.context = context_object
    table.insert(record.lines, "Prefab native capture: " .. record.kind)
    table.insert(record.lines, "source=" .. record.source)
    if record.replay_id ~= nil then
        table.insert(record.lines, "replay_id=" .. tostring(record.replay_id))
    end
    table.insert(record.lines, "hook=" .. record.hook_path)
    table.insert(record.lines, "timestamp=" .. record.timestamp)
    table.insert(record.lines, "capture_path=" .. PREFAB_CAPTURE_PATH)
    table.insert(record.lines, "capture_latest_path=" .. PREFAB_CAPTURE_LATEST_PATH)
    table.insert(record.lines, "context=" .. get_object_label(context_object, "nil"))

    local count = select("#", ...)
    table.insert(record.lines, "arg_count=" .. tostring(count))
    for index = 1, count do
        local raw = select(index, ...)
        local lines, resolved, resolver, memory = OmeggaDescribeHookParam("arg[" .. tostring(index) .. "]", raw)
        table.insert(record.args, {
            raw = raw,
            resolved = resolved,
            resolver = resolver,
            memory = memory,
        })
        for _, line in ipairs(lines) do
            table.insert(record.lines, line)
        end
    end

    state.last = record
    if source == "replay" then
        state.last_replay_capture = record
    else
        state.last_client = record
        if OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS[record.kind] then
            state.last_replayable_client = record
        end
    end
    table.insert(state.hooks, {
        event = "capture",
        source = source,
        kind = record.kind,
        hook_path = record.hook_path,
        timestamp = record.timestamp,
        replay_id = record.replay_id,
        arg_count = count,
    })
    while #state.hooks > 32 do
        table.remove(state.hooks, 1)
    end

    local detail = table.concat(record.lines, "\n")
    write_file(PREFAB_CAPTURE_LATEST_PATH, detail .. "\n")
    if source ~= "replay" and OMEGGA_PREFAB_NATIVE_REPLAYABLE_KINDS[record.kind] then
        write_file((BRIDGE_DIR .. "/prefab-native-last-replayable.txt"), detail .. "\n")
    end
    local capture_json_parts = {
        json_string_field("event", "capture"),
        json_string_field("source", record.source),
        json_string_field("kind", record.kind),
        json_string_field("hook_path", record.hook_path),
        json_string_field("timestamp", record.timestamp),
    }
    if record.replay_id ~= nil then
        table.insert(capture_json_parts, string.format("\"replay_id\":%d", record.replay_id))
    end
    table.insert(capture_json_parts, string.format("\"arg_count\":%d", count))
    table.insert(capture_json_parts, json_string_field("detail_b64", base64_encode(detail)))
    append_file(
        PREFAB_CAPTURE_PATH,
        json_object(capture_json_parts) .. "\n"
    )

    local summary = table.concat(record.lines, " | ")
    bridge_log("info", "Prefab native capture " .. summary)
    local notification_parts = {
        json_string_field("source", record.source),
        json_string_field("kind", record.kind),
        json_string_field("hook_path", record.hook_path),
    }
    if record.replay_id ~= nil then
        table.insert(notification_parts, string.format("\"replay_id\":%d", record.replay_id))
    end
    table.insert(notification_parts, string.format("\"arg_count\":%d", count))
    table.insert(notification_parts, json_string_field("summary_b64", base64_encode(summary)))
    table.insert(notification_parts, json_string_field("updated_at", record.timestamp))
    send_notification(
        "prefab.native.capture",
        json_object(notification_parts)
    )
end

function OmeggaAddPrefabHookCandidate(candidates, seen, kind, path, source)
    local function add_candidate(path_value, source_value)
        local path_text = trim(tostring(path_value or ""))
        if path_text == "" or seen[path_text] then
            return
        end

        seen[path_text] = true
        table.insert(candidates, {
            kind = kind,
            path = path_text,
            source = tostring(source_value or "candidate"),
        })
    end

    local raw = trim(tostring(path or ""))
    add_candidate(raw, source)

    local no_type = raw:gsub("^Function%s+", "")
    if no_type ~= raw then
        add_candidate(no_type, tostring(source or "candidate") .. ":without-type")
    end

    local colon_head, colon_tail = no_type:match("^(.-):([^:]+)$")
    if colon_head and colon_tail then
        add_candidate(colon_head .. "." .. colon_tail, tostring(source or "candidate") .. ":dot")
        add_candidate("Function " .. colon_head .. "." .. colon_tail, tostring(source or "candidate") .. ":function-dot")
        return
    end

    local dot_head, dot_tail = no_type:match("^(.*)%.([^.]+)$")
    if dot_head and dot_tail then
        add_candidate(dot_head .. ":" .. dot_tail, tostring(source or "candidate") .. ":colon")
        add_candidate("Function " .. dot_head .. "." .. dot_tail, tostring(source or "candidate") .. ":function-dot")
    end
end

function OmeggaBuildPrefabHookCandidates(descriptor)
    local candidates = {}
    local seen = {}
    local method = tostring(descriptor.method or descriptor.kind or "")
    local packages = descriptor.packages or { "/Script/Brickadia" }

    for _, class_name in ipairs(descriptor.classes or {}) do
        local class_text = trim(tostring(class_name or ""))
        if class_text ~= "" then
            if class_text:sub(1, 1) == "/" then
                OmeggaAddPrefabHookCandidate(
                    candidates,
                    seen,
                    descriptor.kind,
                    class_text .. ":" .. method,
                    "class"
                )
            else
                for _, package_name in ipairs(packages) do
                    OmeggaAddPrefabHookCandidate(
                        candidates,
                        seen,
                        descriptor.kind,
                        tostring(package_name or "") .. "." .. class_text .. ":" .. method,
                        "class"
                    )
                end
            end
        end
    end

    for _, raw_path in ipairs(descriptor.paths or {}) do
        OmeggaAddPrefabHookCandidate(candidates, seen, descriptor.kind, raw_path, "explicit")
    end

    OmeggaAddPrefabHookCandidate(candidates, seen, descriptor.kind, method, "short-name")
    return candidates
end

function OmeggaDescribePrefabStaticLookup(path)
    if type(StaticFindObject) ~= "function" then
        return "static=unavailable"
    end

    local ok, object = pcall(StaticFindObject, path)
    if not ok then
        return "static=error:" .. prefab_probe_compact(object)
    end
    if object == nil then
        return "static=miss"
    end

    local address = nil
    if type(object.GetAddress) == "function" then
        local address_ok, address_value = pcall(function()
            return object:GetAddress()
        end)
        if address_ok and type(address_value) == "number" then
            if address_value == 0 then
                return "static=miss-null"
            end
            address = string.format("0x%X", address_value)
        end
    end

    return "static=hit:" .. tostring(address or prefab_probe_compact(object))
end

function OmeggaInstallPrefabNativeHooks(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "InstallPrefabNativeHooks is disabled by default on Brickadia Windows. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to enable it."
    end

    if type(RegisterHook) ~= "function" then
        return "RegisterHook is unavailable"
    end

    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    local lines = { "Install prefab native hooks" }
    local requested = string.lower(trim(tostring(spec or "")))
    local allow_unsafe_param_hooks = requested:find("unsafe", 1, true) ~= nil
    local requested_match = trim(requested:gsub("unsafe", ""):gsub("%s+", " "))
    state.registered_kinds = state.registered_kinds or {}
    state.registration_events = state.registration_events or {}

    local descriptors = {
        {
            kind = "ServerPastePrefab",
            method = "ServerPastePrefab",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
            paths = {
                "/Script/Brickadia.BRPlayerController.ServerPastePrefab",
                "/Script/Brickadia.BRPlayerController:ServerPastePrefab",
                "/Script/Brickadia.PlayerController.ServerPastePrefab",
                "/Script/Brickadia.PlayerController:ServerPastePrefab",
                "/Script/Brickadia.BP_PlayerController_C.ServerPastePrefab",
                "/Script/Brickadia.BP_PlayerController_C:ServerPastePrefab",
            },
            unsafe_lua_param_hook = true,
        },
        {
            kind = "ServerPlaceCurrentPrefab",
            method = "ServerPlaceCurrentPrefab",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "Tool_Placer_C",
                "BP_Tool_Placer_C",
            },
            paths = {
                "/Script/Brickadia.BRTool_Placer.ServerPlaceCurrentPrefab",
                "/Script/Brickadia.BRTool_Placer:ServerPlaceCurrentPrefab",
            },
            unsafe_lua_param_hook = true,
        },
        {
            kind = "ServerUploadPrefab",
            method = "ServerUploadPrefab",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
            unsafe_lua_param_hook = true,
        },
        {
            kind = "ClientUploadPrefab",
            method = "ClientUploadPrefab",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
            unsafe_lua_param_hook = true,
        },
        {
            kind = "ServerPasteBrick",
            method = "ServerPasteBrick",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
        },
        {
            kind = "ServerPasteEntity",
            method = "ServerPasteEntity",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
        },
        {
            kind = "CommitPlacement",
            method = "CommitPlacement",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "BRPlacerComponent",
                "BRPlacerPlaceable",
            },
        },
        {
            kind = "PreviewPlacement",
            method = "PreviewPlacement",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "BRPlacerComponent",
                "BRPlacerPreviewInfo",
            },
        },
        {
            kind = "ApplyPrefabState",
            method = "ApplyPrefabState",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "BRPrefabCacheInMemoryPrefab",
                "BRPrefabPreviewBrickGrid",
            },
        },
        {
            kind = "HandleAttachedPlacement",
            method = "HandleAttachedPlacement",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "BRPlacerComponent",
            },
        },
        {
            kind = "SetPlaceAsPhysicsAvailable",
            method = "SetPlaceAsPhysicsAvailable",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "Tool_Placer_C",
                "BP_Tool_Placer_C",
            },
            unsafe_lua_param_hook = true,
        },
        {
            kind = "SetPlaceAsPhysicsEnabled",
            method = "SetPlaceAsPhysicsEnabled",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "Tool_Placer_C",
                "BP_Tool_Placer_C",
            },
        },
        {
            kind = "ServerModifyEntity",
            method = "ServerModifyEntity",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
        },
        {
            kind = "ServerPlaceSimpleEntityVolume",
            method = "ServerPlaceSimpleEntityVolume",
            classes = {
                "BRTool_Placer",
                "BRTool_Placer_C",
                "Tool_Placer_C",
                "BP_Tool_Placer_C",
            },
            unsafe_lua_param_hook = true,
        },
        {
            kind = "CapturePrefab",
            method = "CapturePrefab",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BRPrefabThumbnailCapturer",
                "BRWorldManager",
            },
        },
        {
            kind = "ClientNotifyPrefabCaptureComplete",
            method = "ClientNotifyPrefabCaptureComplete",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
        },
        {
            kind = "ClientNotifyPrefabCaptureFailed",
            method = "ClientNotifyPrefabCaptureFailed",
            classes = {
                "BRPlayerController",
                "PlayerController",
                "BP_PlayerController_C",
            },
        },
    }

    for _, descriptor in ipairs(descriptors) do
        if requested_match == "" or requested_match == "all" or string.lower(descriptor.kind):find(requested_match, 1, true) then
            if descriptor.unsafe_lua_param_hook and not allow_unsafe_param_hooks then
                table.insert(state.registration_events, {
                    event = "skipped-unsafe-lua-param-hook",
                    kind = descriptor.kind,
                    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                })
                while #state.registration_events > 64 do
                    table.remove(state.registration_events, 1)
                end
                table.insert(
                    lines,
                    descriptor.kind
                        .. " skipped unsafe_lua_param_hook=true detail=CL13530 UE4SS Lua RegisterHook crashes while pushing prefab struct params; pass unsafe to force"
                )
            elseif state.registered_kinds[descriptor.kind] then
                table.insert(
                    lines,
                    descriptor.kind .. " already_registered " .. tostring(state.registered_kinds[descriptor.kind])
                )
            else
                local registered = false
                local candidates = OmeggaBuildPrefabHookCandidates(descriptor)
                for _, hook in ipairs(candidates) do
                    local key = "prefab_native_hook:" .. hook.path
                    local lookup = OmeggaDescribePrefabStaticLookup(hook.path)
                    if state[key] then
                        state.registered_kinds[descriptor.kind] = hook.path
                        registered = true
                        table.insert(lines, hook.kind .. " already_registered " .. hook.path .. " " .. lookup)
                        break
                    end

                    local callback = retain_callback(key, function(Context, ...)
                        OmeggaRecordPrefabNativeCapture(hook.kind, hook.path, Context, ...)
                    end)
                    local ok, pre_id, post_id = pcall(RegisterHook, hook.path, callback)
                    if ok and type(pre_id) == "number" and type(post_id) == "number" then
                        state[key] = true
                        state.registered = true
                        state.registered_kinds[descriptor.kind] = hook.path
                        registered = true
                        table.insert(state.registration_events, {
                            event = "registered",
                            kind = hook.kind,
                            hook_path = hook.path,
                            source = hook.source,
                            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                            pre_id = pre_id,
                            post_id = post_id,
                        })
                        while #state.registration_events > 64 do
                            table.remove(state.registration_events, 1)
                        end
                        table.insert(
                            lines,
                            hook.kind
                                .. " registered "
                                .. hook.path
                                .. " source="
                                .. tostring(hook.source)
                                .. " "
                                .. lookup
                                .. " pre="
                                .. tostring(pre_id)
                                .. " post="
                                .. tostring(post_id)
                        )
                        break
                    else
                        release_callback(key)
                        local error_text = prefab_probe_compact((tostring(pre_id or ""):match("^[^\r\n]*")))
                        table.insert(
                            lines,
                            hook.kind
                                .. " failed "
                                .. hook.path
                                .. " source="
                                .. tostring(hook.source)
                                .. " "
                                .. lookup
                                .. " error="
                                .. error_text
                        )
                    end
                end

                if not registered then
                    table.insert(state.registration_events, {
                        event = "not-registered",
                        kind = descriptor.kind,
                        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                    })
                    while #state.registration_events > 64 do
                        table.remove(state.registration_events, 1)
                    end
                    table.insert(lines, descriptor.kind .. " no candidate registered")
                end
            end
        end
    end

    return table.concat(lines, "\n")
end

function OmeggaDescribePrefabNativeHooks(spec)
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}
    local lines = {
        "Prefab native hooks",
        "registered=" .. tostring(state.registered == true),
    }

    local registered = state.registered_kinds or {}
    local kinds = {}
    for kind, _ in pairs(registered) do
        table.insert(kinds, tostring(kind))
    end
    table.sort(kinds)

    if #kinds == 0 then
        table.insert(lines, "registered_kinds=<none>")
    else
        for _, kind in ipairs(kinds) do
            table.insert(lines, "registered_kind " .. kind .. "=" .. tostring(registered[kind]))
        end
    end

    local max_events_text = trim(tostring(spec or ""))
    local max_events = tonumber(max_events_text) or 16
    if max_events < 1 then
        max_events = 1
    end
    if max_events > 64 then
        max_events = 64
    end

    local registration_events = state.registration_events or {}
    table.insert(lines, "registration_events=" .. tostring(#registration_events))
    local registration_start = math.max(1, #registration_events - max_events + 1)
    for index = registration_start, #registration_events do
        local event = registration_events[index] or {}
        table.insert(
            lines,
            string.format(
                "registration[%d] event=%s kind=%s path=%s source=%s pre=%s post=%s timestamp=%s",
                index,
                tostring(event.event or ""),
                tostring(event.kind or ""),
                tostring(event.hook_path or ""),
                tostring(event.source or ""),
                tostring(event.pre_id or ""),
                tostring(event.post_id or ""),
                tostring(event.timestamp or "")
            )
        )
    end

    local capture_events = state.hooks or {}
    table.insert(lines, "capture_events=" .. tostring(#capture_events))
    local capture_start = math.max(1, #capture_events - max_events + 1)
    for index = capture_start, #capture_events do
        local event = capture_events[index] or {}
        table.insert(
            lines,
            string.format(
                "capture[%d] event=%s source=%s kind=%s path=%s args=%s replay_id=%s timestamp=%s",
                index,
                tostring(event.event or ""),
                tostring(event.source or ""),
                tostring(event.kind or ""),
                tostring(event.hook_path or ""),
                tostring(event.arg_count or ""),
                tostring(event.replay_id or ""),
                tostring(event.timestamp or "")
            )
        )
    end

    if state.last then
        table.insert(
            lines,
            "last_capture=" .. tostring(state.last.kind or "unknown") .. " source=" .. tostring(state.last.source or "")
        )
    else
        table.insert(lines, "last_capture=<none>")
    end

    if state.last_client then
        table.insert(lines, "last_client_capture=" .. tostring(state.last_client.kind or "unknown"))
    else
        table.insert(lines, "last_client_capture=<none>")
    end

    if state.last_replayable_client then
        table.insert(lines, "last_replayable_client_capture=" .. tostring(state.last_replayable_client.kind or "unknown"))
    else
        table.insert(lines, "last_replayable_client_capture=<none>")
    end

    if state.last_replay_capture then
        table.insert(
            lines,
            "last_replay_capture="
                .. tostring(state.last_replay_capture.kind or "unknown")
                .. " replay_id="
                .. tostring(state.last_replay_capture.replay_id or "")
        )
    else
        table.insert(lines, "last_replay_capture=<none>")
    end

    return table.concat(lines, "\n")
end

function OmeggaDescribeLastPrefabNativeCapture()
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    if not state or not state.last then
        return "Prefab native capture: none"
    end

    return table.concat(state.last.lines or {}, "\n")
end

function OmeggaHexBytesToNumbers(hex)
    local clean = tostring(hex or ""):gsub("0[xX]", ""):gsub("[^0-9a-fA-F]", "")
    if clean == "" then
        return {}, nil
    end
    if (#clean % 2) ~= 0 then
        return nil, "odd number of hex digits"
    end

    local bytes = {}
    for index = 1, #clean, 2 do
        local value = tonumber(clean:sub(index, index + 1), 16)
        if value == nil then
            return nil, "invalid hex byte at offset " .. tostring(index)
        end
        table.insert(bytes, value)
    end
    return bytes, nil
end

function OmeggaByteNumbersToHex(bytes)
    local parts = {}
    for index = 1, #bytes do
        parts[index] = string.format("%02X", tonumber(bytes[index] or 0) or 0)
    end
    return table.concat(parts, " ")
end

function OmeggaPrefabNativeInt32(value, label)
    local number = tonumber(value)
    if number == nil then
        return nil, tostring(label or "value") .. " is not a number"
    end
    number = math.floor(number)
    if number < -2147483648 or number > 2147483647 then
        return nil, tostring(label or "value") .. " is outside int32 range"
    end
    return number, nil
end

function OmeggaReadInt32LE(bytes, offset)
    if #bytes < offset + 4 then
        return nil, "buffer too short for int32 at offset 0x" .. string.format("%X", offset)
    end

    local unsigned = (bytes[offset + 1] or 0)
        + ((bytes[offset + 2] or 0) * 256)
        + ((bytes[offset + 3] or 0) * 65536)
        + ((bytes[offset + 4] or 0) * 16777216)
    if unsigned >= 2147483648 then
        return unsigned - 4294967296, nil
    end
    return unsigned, nil
end

function OmeggaWriteInt32LE(bytes, offset, value, label)
    local number, error_text = OmeggaPrefabNativeInt32(value, label)
    if number == nil then
        return false, error_text
    end
    if #bytes < offset + 4 then
        return false, "buffer too short for int32 at offset 0x" .. string.format("%X", offset)
    end

    if number < 0 then
        number = number + 4294967296
    end

    for byte_index = 0, 3 do
        bytes[offset + 1 + byte_index] = number % 256
        number = math.floor(number / 256)
    end
    return true, nil
end

function OmeggaReadUInt8(bytes, offset)
    if #bytes < offset + 1 then
        return nil, "buffer too short for uint8 at offset 0x" .. string.format("%X", offset)
    end
    return bytes[offset + 1] or 0, nil
end

function OmeggaWriteUInt8(bytes, offset, value, label)
    local number = tonumber(value)
    if number == nil then
        return false, tostring(label or "value") .. " is not a number"
    end
    number = math.floor(number)
    if number < 0 or number > 255 then
        return false, tostring(label or "value") .. " is outside uint8 range"
    end
    if #bytes < offset + 1 then
        return false, "buffer too short for uint8 at offset 0x" .. string.format("%X", offset)
    end

    bytes[offset + 1] = number
    return true, nil
end

function OmeggaParsePrefabNativeReplaySpec(spec)
    local cleaned = trim(tostring(spec or ""))
    local parsed = {
        mode = "exact",
        function_name = nil,
        orientation = nil,
    }
    if cleaned == "" then
        return parsed, nil
    end

    local tokens = {}
    for token in cleaned:gmatch("%S+") do
        table.insert(tokens, token)
    end
    if #tokens == 0 then
        return parsed, nil
    end

    local first = string.lower(tokens[1])
    local numeric_start = 1
    if first == "offset" or first == "relative" or first == "delta" then
        parsed.mode = "offset"
        numeric_start = 2
    elseif first == "grid" or first == "at" or first == "absolute" then
        parsed.mode = "grid"
        numeric_start = 2
    elseif first == "exact" then
        parsed.mode = "exact"
        return parsed, nil
    elseif tonumber(tokens[1]) ~= nil then
        parsed.mode = "offset"
    else
        parsed.function_name = cleaned
        return parsed, nil
    end

    if (#tokens - numeric_start + 1) < 3 then
        return nil, "expected " .. parsed.mode .. " x y z [orientation]"
    end

    local x, x_error = OmeggaPrefabNativeInt32(tokens[numeric_start], "x")
    local y, y_error = OmeggaPrefabNativeInt32(tokens[numeric_start + 1], "y")
    local z, z_error = OmeggaPrefabNativeInt32(tokens[numeric_start + 2], "z")
    if x == nil or y == nil or z == nil then
        return nil, x_error or y_error or z_error
    end

    parsed.x = x
    parsed.y = y
    parsed.z = z

    if tokens[numeric_start + 3] ~= nil then
        local orientation = tonumber(tokens[numeric_start + 3])
        if orientation == nil then
            return nil, "orientation is not a number"
        end
        orientation = math.floor(orientation)
        if orientation < 0 or orientation > 255 then
            return nil, "orientation is outside uint8 range"
        end
        parsed.orientation = orientation
    end

    return parsed, nil
end

function OmeggaPrefabNativeReplayLayout(kind)
    local kind_text = tostring(kind or "")
    if kind_text == "ServerPastePrefab" then
        return {
            kind = "ServerPastePrefab",
            function_name = "ServerPastePrefab",
            min_size = 0x40,
            grid_x_offset = 0x30,
            grid_y_offset = 0x34,
            grid_z_offset = 0x38,
            grid_offsets = {
                { label = "PasteInfo.GridOffset", x = 0x30, y = 0x34, z = 0x38 },
            },
            orientation_offset = 0x3C,
            label = "ServerPastePrefab PasteInfo.GridOffset",
        }
    end

    if kind_text == "ServerPlaceCurrentPrefab" then
        return {
            kind = "ServerPlaceCurrentPrefab",
            function_name = "ServerPlaceCurrentPrefab",
            min_size = 0xDF,
            grid_x_offset = 0x80,
            grid_y_offset = 0x84,
            grid_z_offset = 0x88,
            grid_offsets = {
                { label = "PrimaryGrid", x = 0x80, y = 0x84, z = 0x88 },
                { label = "ExtraGrid5", x = 0xAC, y = 0xB0, z = 0xB4 },
                { label = "ExtraGrid6", x = 0xB8, y = 0xBC, z = 0xC0 },
                { label = "ExtraGrid7", x = 0xC4, y = 0xC8, z = 0xCC },
                { label = "ExtraGrid8", x = 0xD0, y = 0xD4, z = 0xD8 },
            },
            vector_offsets = {
                { label = "PlacementState.Transform.Translation", x = 0x30, y = 0x38, z = 0x40 },
                { label = "PlacementVector", x = 0x90, y = 0x98, z = 0xA0 },
            },
            orientation_offset = 0xA8,
            label = "ServerPlaceCurrentPrefab primary grid parameter",
            warning = "ServerPlaceCurrentPrefab has several placement parameters; offset replay adjusts known grid and vector placement fields by the same delta",
        }
    end

    if kind_text == "ServerPlaceSimpleEntityVolume" then
        return {
            kind = "ServerPlaceSimpleEntityVolume",
            function_name = "ServerPlaceSimpleEntityVolume",
            min_size = 0xE4,
            grid_x_offset = 0x8C,
            grid_y_offset = 0x90,
            grid_z_offset = 0x94,
            grid_offsets = {
                { label = "PrimaryGrid", x = 0x8C, y = 0x90, z = 0x94 },
                { label = "ExtraGrid7", x = 0xB4, y = 0xB8, z = 0xBC },
                { label = "ExtraGrid8", x = 0xC0, y = 0xC4, z = 0xC8 },
                { label = "ExtraGrid9", x = 0xCC, y = 0xD0, z = 0xD4 },
                { label = "ExtraGrid10", x = 0xD8, y = 0xDC, z = 0xE0 },
            },
            vector_offsets = {
                { label = "PlacementState.Transform.Translation", x = 0x30, y = 0x38, z = 0x40 },
                { label = "PlacementVector", x = 0x98, y = 0xA0, z = 0xA8 },
            },
            orientation_offset = 0x88,
            label = "ServerPlaceSimpleEntityVolume primary grid parameter",
            warning = "ServerPlaceSimpleEntityVolume replay layout is inferred from CL13530 reflection; offset replay adjusts known grid and vector placement fields by the same delta",
        }
    end

    return nil
end

function OmeggaReadPrefabNativeReplayGrid(buffer, grid_offsets)
    local grid_x, grid_x_error = OmeggaReadInt32LE(buffer, grid_offsets.x)
    local grid_y, grid_y_error = OmeggaReadInt32LE(buffer, grid_offsets.y)
    local grid_z, grid_z_error = OmeggaReadInt32LE(buffer, grid_offsets.z)
    if grid_x == nil or grid_y == nil or grid_z == nil then
        return nil, grid_x_error or grid_y_error or grid_z_error
    end
    return { x = grid_x, y = grid_y, z = grid_z }, nil
end

function OmeggaWritePrefabNativeReplayGrid(buffer, grid_offsets, grid, label)
    local ok, error_text = OmeggaWriteInt32LE(buffer, grid_offsets.x, grid.x, tostring(label or "grid") .. ".x")
    if not ok then
        return false, error_text
    end
    ok, error_text = OmeggaWriteInt32LE(buffer, grid_offsets.y, grid.y, tostring(label or "grid") .. ".y")
    if not ok then
        return false, error_text
    end
    ok, error_text = OmeggaWriteInt32LE(buffer, grid_offsets.z, grid.z, tostring(label or "grid") .. ".z")
    if not ok then
        return false, error_text
    end
    return true, nil
end

function OmeggaReadDoubleLE(bytes, offset)
    if type(string.unpack) ~= "function" then
        return nil, "string.unpack is unavailable; cannot read double at offset 0x" .. string.format("%X", offset)
    end
    if #bytes < offset + 8 then
        return nil, "buffer too short for double at offset 0x" .. string.format("%X", offset)
    end

    local chars = {}
    for byte_index = 0, 7 do
        chars[byte_index + 1] = string.char(bytes[offset + 1 + byte_index] or 0)
    end
    local ok, value = pcall(string.unpack, "<d", table.concat(chars))
    if not ok then
        return nil, "could not read double at offset 0x" .. string.format("%X", offset) .. ": " .. tostring(value)
    end
    return value, nil
end

function OmeggaWriteDoubleLE(bytes, offset, value, label)
    if type(string.pack) ~= "function" then
        return false, "string.pack is unavailable; cannot write double at offset 0x" .. string.format("%X", offset)
    end
    local number = tonumber(value)
    if number == nil then
        return false, tostring(label or "value") .. " is not a number"
    end
    if #bytes < offset + 8 then
        return false, "buffer too short for double at offset 0x" .. string.format("%X", offset)
    end

    local ok, packed = pcall(string.pack, "<d", number)
    if not ok then
        return false, "could not write double for " .. tostring(label or "value") .. ": " .. tostring(packed)
    end
    for byte_index = 0, 7 do
        bytes[offset + 1 + byte_index] = string.byte(packed, byte_index + 1)
    end
    return true, nil
end

function OmeggaReadPrefabNativeReplayVector(buffer, vector_offsets)
    local vector_x, vector_x_error = OmeggaReadDoubleLE(buffer, vector_offsets.x)
    local vector_y, vector_y_error = OmeggaReadDoubleLE(buffer, vector_offsets.y)
    local vector_z, vector_z_error = OmeggaReadDoubleLE(buffer, vector_offsets.z)
    if vector_x == nil or vector_y == nil or vector_z == nil then
        return nil, vector_x_error or vector_y_error or vector_z_error
    end
    return { x = vector_x, y = vector_y, z = vector_z }, nil
end

function OmeggaWritePrefabNativeReplayVector(buffer, vector_offsets, vector, label)
    local ok, error_text = OmeggaWriteDoubleLE(buffer, vector_offsets.x, vector.x, tostring(label or "vector") .. ".x")
    if not ok then
        return false, error_text
    end
    ok, error_text = OmeggaWriteDoubleLE(buffer, vector_offsets.y, vector.y, tostring(label or "vector") .. ".y")
    if not ok then
        return false, error_text
    end
    ok, error_text = OmeggaWriteDoubleLE(buffer, vector_offsets.z, vector.z, tostring(label or "vector") .. ".z")
    if not ok then
        return false, error_text
    end
    return true, nil
end

function OmeggaApplyPrefabNativeReplaySpec(buffer, meta, parsed)
    parsed = parsed or { mode = "exact" }
    meta.replay_mode = parsed.mode or "exact"
    local layout = OmeggaPrefabNativeReplayLayout(meta.kind)
    if not layout then
        return false, "No native prefab replay layout is known for " .. tostring(meta.kind or "unknown")
    end
    meta.layout = layout.kind
    meta.layout_label = layout.label
    meta.function_name = parsed.function_name or layout.function_name
    if layout.warning then
        meta.layout_warning = layout.warning
    end

    if meta.total < layout.min_size then
        return false,
            tostring(layout.kind)
                .. " replay buffer is shorter than expected 0x"
                .. string.format("%X", layout.min_size)
                .. " bytes"
    end

    local grid_offsets = layout.grid_offsets or {
        { label = layout.label, x = layout.grid_x_offset, y = layout.grid_y_offset, z = layout.grid_z_offset },
    }
    local primary_grid_offsets = grid_offsets[1]
    local original_primary_grid, primary_grid_error = OmeggaReadPrefabNativeReplayGrid(buffer, primary_grid_offsets)
    local orientation, orientation_error = OmeggaReadUInt8(buffer, layout.orientation_offset)
    if original_primary_grid == nil or orientation == nil then
        return false, primary_grid_error or orientation_error
    end

    meta.original_grid = original_primary_grid
    meta.original_orientation = orientation
    meta.final_grid = { x = original_primary_grid.x, y = original_primary_grid.y, z = original_primary_grid.z }
    meta.final_orientation = orientation

    if parsed.mode == "offset" then
        meta.final_grid = {
            x = original_primary_grid.x + parsed.x,
            y = original_primary_grid.y + parsed.y,
            z = original_primary_grid.z + parsed.z,
        }
    elseif parsed.mode == "grid" then
        meta.final_grid = {
            x = parsed.x,
            y = parsed.y,
            z = parsed.z,
        }
    elseif parsed.mode ~= "exact" then
        return false, "unknown replay mode " .. tostring(parsed.mode)
    end

    local delta = {
        x = meta.final_grid.x - original_primary_grid.x,
        y = meta.final_grid.y - original_primary_grid.y,
        z = meta.final_grid.z - original_primary_grid.z,
    }
    meta.grid_delta = delta
    meta.adjusted_grids = {}
    for index, offsets in ipairs(grid_offsets) do
        local original_grid, read_error = OmeggaReadPrefabNativeReplayGrid(buffer, offsets)
        if original_grid == nil then
            return false, read_error
        end
        local final_grid = {
            x = original_grid.x + delta.x,
            y = original_grid.y + delta.y,
            z = original_grid.z + delta.z,
        }
        local ok, error_text = OmeggaWritePrefabNativeReplayGrid(
            buffer,
            offsets,
            final_grid,
            offsets.label or ("grid[" .. tostring(index) .. "]")
        )
        if not ok then
            return false, error_text
        end
        table.insert(meta.adjusted_grids, {
            label = tostring(offsets.label or ("grid[" .. tostring(index) .. "]")),
            original = original_grid,
            final = final_grid,
        })
    end

    meta.adjusted_vectors = {}
    for index, offsets in ipairs(layout.vector_offsets or {}) do
        local original_vector, read_error = OmeggaReadPrefabNativeReplayVector(buffer, offsets)
        if original_vector == nil then
            return false, read_error
        end
        local final_vector = {
            x = original_vector.x + delta.x,
            y = original_vector.y + delta.y,
            z = original_vector.z + delta.z,
        }
        local ok, error_text = OmeggaWritePrefabNativeReplayVector(
            buffer,
            offsets,
            final_vector,
            offsets.label or ("vector[" .. tostring(index) .. "]")
        )
        if not ok then
            return false, error_text
        end
        table.insert(meta.adjusted_vectors, {
            label = tostring(offsets.label or ("vector[" .. tostring(index) .. "]")),
            original = original_vector,
            final = final_vector,
        })
    end

    if parsed.orientation ~= nil then
        local ok, error_text = OmeggaWriteUInt8(buffer, layout.orientation_offset, parsed.orientation, "orientation")
        if not ok then
            return false, error_text
        end
        meta.final_orientation = parsed.orientation
    end

    return true, nil
end

function OmeggaBuildPrefabNativeReplayBuffer(record, replay_spec)
    if type(record) ~= "table" then
        return nil, "no capture record"
    end

    local descriptors = {}
    for index, arg in ipairs(record.args or {}) do
        local memory = arg and arg.memory and (arg.memory.raw or arg.memory.resolved) or nil
        local address = memory and tonumber(memory.address) or nil
        local size = memory and tonumber(memory.size) or nil
        local bytes = memory and tostring(memory.bytes or "") or ""
        if address ~= nil and size ~= nil and size > 0 and bytes ~= "" then
            table.insert(descriptors, {
                index = index,
                address = address,
                size = size,
                bytes = bytes,
                property = tostring(memory.property or ""),
            })
        end
    end

    if #descriptors == 0 then
        return nil, "capture has no parameter memory snapshots"
    end

    table.sort(descriptors, function(left, right)
        return left.address < right.address
    end)

    local base = descriptors[1].address
    local total = 0
    for _, descriptor in ipairs(descriptors) do
        local relative = descriptor.address - base
        if relative < 0 then
            return nil, "capture parameter addresses are inconsistent"
        end
        total = math.max(total, relative + descriptor.size)
    end

    local buffer = {}
    for index = 1, total do
        buffer[index] = 0
    end

    for _, descriptor in ipairs(descriptors) do
        local byte_values, parse_error = OmeggaHexBytesToNumbers(descriptor.bytes)
        if not byte_values then
            return nil, "arg[" .. tostring(descriptor.index) .. "] bytes invalid: " .. tostring(parse_error)
        end
        if #byte_values < descriptor.size then
            return nil,
                "arg[" .. tostring(descriptor.index) .. "] has "
                    .. tostring(#byte_values)
                    .. " byte(s) but declared size "
                    .. tostring(descriptor.size)
        end

        local relative = descriptor.address - base
        for byte_index = 1, descriptor.size do
            buffer[relative + byte_index] = byte_values[byte_index] or 0
        end
    end

    local parsed_spec, spec_error = OmeggaParsePrefabNativeReplaySpec(replay_spec)
    if not parsed_spec then
        return nil, spec_error
    end

    local meta = {
        base = base,
        total = total,
        descriptors = descriptors,
        kind = tostring(record.kind or ""),
    }
    local ok, apply_error = OmeggaApplyPrefabNativeReplaySpec(buffer, meta, parsed_spec)
    if not ok then
        return nil, apply_error
    end

    meta.buffer = buffer
    meta.function_name = parsed_spec.function_name or meta.function_name
    return OmeggaByteNumbersToHex(buffer), meta
end

function OmeggaNormalizePrefabHashHex(value)
    local clean = tostring(value or ""):gsub("[^0-9a-fA-F]", "")
    if #clean ~= 64 then
        return nil, "prefab hash must be exactly 32 bytes / 64 hex characters"
    end
    return string.upper(clean), nil
end

function OmeggaPrefabHashHexToBytes(hash_hex)
    local clean, error_text = OmeggaNormalizePrefabHashHex(hash_hex)
    if not clean then
        return nil, error_text
    end

    local bytes = {}
    for index = 1, #clean, 2 do
        table.insert(bytes, tonumber(clean:sub(index, index + 1), 16) or 0)
    end
    return bytes, nil
end

function OmeggaPrefabBoolFromToken(value, label)
    local text = string.lower(trim(tostring(value or "")))
    if text == "1" or text == "true" or text == "yes" or text == "on" then
        return true, nil
    end
    if text == "0" or text == "false" or text == "no" or text == "off" then
        return false, nil
    end
    return nil, tostring(label or "boolean") .. " must be true/false or 1/0"
end

function OmeggaLastServerPastePrefabTargetBytes()
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}
    local candidates = {
        state.last_replayable_client,
        state.last_client,
        state.last,
    }

    for _, record in ipairs(candidates) do
        if record and tostring(record.kind or "") == "ServerPastePrefab" then
            local _, meta = OmeggaBuildPrefabNativeReplayBuffer(record)
            if meta and meta.buffer and #meta.buffer >= 0x30 then
                local bytes = {}
                for index = 1, 8 do
                    bytes[index] = meta.buffer[0x28 + index] or 0
                end
                return bytes, "last-server-paste-prefab-capture"
            end
        end
    end

    return nil, "no ServerPastePrefab capture has a target pointer"
end

function OmeggaPointerBytesFromSpec(target_spec)
    local text = trim(tostring(target_spec or ""))
    local lower = string.lower(text)
    if text == "" or lower == "0" or lower == "0x0" or lower == "null" or lower == "none" then
        return { 0, 0, 0, 0, 0, 0, 0, 0 }, "zero"
    end

    if lower == "last" or lower == "capture" or lower == "captured" then
        return OmeggaLastServerPastePrefabTargetBytes()
    end

    if lower == "rawlast" or lower == "lastraw" or lower == "raw-capture" or lower == "last-raw-capture" then
        if type(OmeggaGetLastRawServerPastePrefabTargetHex) ~= "function" then
            return nil, "raw ProcessEvent capture target helper is unavailable"
        end
        local ok, target_hex = pcall(OmeggaGetLastRawServerPastePrefabTargetHex)
        if not ok or trim(tostring(target_hex or "")) == "" then
            return nil, "no raw ServerPastePrefab capture has a target pointer"
        end
        return OmeggaPointerBytesFromSpec(target_hex)
    end

    local clean = text:gsub("^0[xX]", ""):gsub("[^0-9a-fA-F]", "")
    if clean == "" or #clean > 16 then
        return nil, "target pointer must be 0, last, rawlast, or up to 16 hex characters"
    end
    if (#clean % 2) ~= 0 then
        clean = "0" .. clean
    end
    while #clean < 16 do
        clean = "00" .. clean
    end

    local bytes = {}
    for index = 0, 7 do
        local start = #clean - (index * 2) - 1
        bytes[index + 1] = tonumber(clean:sub(start, start + 1), 16) or 0
    end
    return bytes, "explicit"
end

function OmeggaParseServerPastePrefabHashSpec(spec)
    local cleaned = trim(tostring(spec or ""))
    if cleaned == "" then
        return nil,
            "usage: PastePrefabHash <64hex_hash> [grid] x y z [orientation] [ownership=1] [temp=0] [target=0|last|rawlast] [pasteseed=hex:<hex>] [placeseed=default|last|hex:<hex>] [placeadjust=primary|full] [placeonly=0|1] [dry-run]"
    end

    local tokens = {}
    for token in cleaned:gmatch("%S+") do
        table.insert(tokens, token)
    end
    if #tokens == 0 then
        return nil, "missing prefab hash"
    end

    local hash_hex, hash_error = OmeggaNormalizePrefabHashHex(tokens[1])
    if not hash_hex then
        return nil, hash_error
    end

    local parsed = {
        hash = hash_hex,
        mode = "grid",
        withOwnership = true,
        inTemp = false,
        orientation = 0,
        orientationSpecified = false,
        target = nil,
        targetSpecified = false,
        ownershipSpecified = false,
        tempSpecified = false,
        pasteSeed = nil,
        placeSeed = nil,
        placeAdjust = "primary",
        placeOnly = false,
        dryRun = false,
    }
    local numeric_tokens = {}

    for index = 2, #tokens do
        local token = tokens[index]
        local lower = string.lower(token)

        if lower == "grid" or lower == "at" or lower == "absolute" then
            parsed.mode = "grid"
        elseif lower == "offset" or lower == "relative" or lower == "delta" then
            parsed.mode = "offset-from-zero"
        elseif lower == "dry-run" or lower == "dryrun" or lower == "--dry-run" then
            parsed.dryRun = true
        elseif token:find("=", 1, true) then
            local key, value = token:match("^([^=]+)=(.*)$")
            key = string.lower(tostring(key or "")):gsub("[_%-%s]", "")
            value = tostring(value or "")
            if key == "ownership" or key == "withownership" then
                local bool_value, bool_error = OmeggaPrefabBoolFromToken(value, "ownership")
                if bool_value == nil then
                    return nil, bool_error
                end
                parsed.withOwnership = bool_value
                parsed.ownershipSpecified = true
            elseif key == "temp" or key == "intemp" then
                local bool_value, bool_error = OmeggaPrefabBoolFromToken(value, "temp")
                if bool_value == nil then
                    return nil, bool_error
                end
                parsed.inTemp = bool_value
                parsed.tempSpecified = true
            elseif key == "target" or key == "targetpointer" then
                parsed.target = value
                parsed.targetSpecified = true
            elseif key == "pasteseed" or key == "pasteparamhex" or key == "pastebuffer" then
                parsed.pasteSeed = value
            elseif key == "placeseed" or key == "placeparamhex" or key == "seed" then
                parsed.placeSeed = value
            elseif key == "placeadjust" or key == "placeadjustment" or key == "adjustplace" then
                local adjust = string.lower(trim(value))
                if adjust == "primary" or adjust == "primaryonly" or adjust == "minimal" then
                    parsed.placeAdjust = "primary"
                elseif adjust == "full" or adjust == "all" or adjust == "legacy" then
                    parsed.placeAdjust = "full"
                else
                    return nil, "placeadjust must be primary or full"
                end
            elseif key == "placeonly" or key == "onlyplace" or key == "skippaste" then
                local bool_value, bool_error = OmeggaPrefabBoolFromToken(value, "placeonly")
                if bool_value == nil then
                    return nil, bool_error
                end
                parsed.placeOnly = bool_value
            elseif key == "paste" or key == "dopaste" then
                local bool_value, bool_error = OmeggaPrefabBoolFromToken(value, "paste")
                if bool_value == nil then
                    return nil, bool_error
                end
                parsed.placeOnly = not bool_value
            elseif key == "orientation" or key == "orient" then
                local orientation = tonumber(value)
                if orientation == nil then
                    return nil, "orientation is not a number"
                end
                orientation = math.floor(orientation)
                if orientation < 0 or orientation > 255 then
                    return nil, "orientation is outside uint8 range"
                end
                parsed.orientation = orientation
                parsed.orientationSpecified = true
            elseif key == "dryrun" then
                local bool_value, bool_error = OmeggaPrefabBoolFromToken(value, "dryrun")
                if bool_value == nil then
                    return nil, bool_error
                end
                parsed.dryRun = bool_value
            else
                return nil, "unknown PastePrefabHash option: " .. tostring(key)
            end
        else
            table.insert(numeric_tokens, token)
        end
    end

    if #numeric_tokens < 3 then
        return nil, "expected placement grid x y z after prefab hash"
    end

    local x, x_error = OmeggaPrefabNativeInt32(numeric_tokens[1], "x")
    local y, y_error = OmeggaPrefabNativeInt32(numeric_tokens[2], "y")
    local z, z_error = OmeggaPrefabNativeInt32(numeric_tokens[3], "z")
    if x == nil or y == nil or z == nil then
        return nil, x_error or y_error or z_error
    end
    parsed.grid = { x = x, y = y, z = z }

    if numeric_tokens[4] ~= nil then
        local orientation = tonumber(numeric_tokens[4])
        if orientation == nil then
            return nil, "orientation is not a number"
        end
        orientation = math.floor(orientation)
        if orientation < 0 or orientation > 255 then
            return nil, "orientation is outside uint8 range"
        end
        parsed.orientation = orientation
        parsed.orientationSpecified = true
    end
    if numeric_tokens[5] ~= nil then
        local bool_value, bool_error = OmeggaPrefabBoolFromToken(numeric_tokens[5], "ownership")
        if bool_value == nil then
            return nil, bool_error
        end
        parsed.withOwnership = bool_value
        parsed.ownershipSpecified = true
    end
    if numeric_tokens[6] ~= nil then
        local bool_value, bool_error = OmeggaPrefabBoolFromToken(numeric_tokens[6], "temp")
        if bool_value == nil then
            return nil, bool_error
        end
        parsed.inTemp = bool_value
        parsed.tempSpecified = true
    end

    local target_bytes, target_source
    if parsed.target == nil and trim(tostring(parsed.pasteSeed or "")) ~= "" then
        target_bytes = nil
        target_source = "paste-seed"
    elseif parsed.target == nil then
        target_bytes, target_source = OmeggaLastServerPastePrefabTargetBytes()
        if not target_bytes then
            target_bytes, target_source = OmeggaPointerBytesFromSpec("0")
        end
    else
        target_bytes, target_source = OmeggaPointerBytesFromSpec(parsed.target)
        if not target_bytes then
            return nil, tostring(target_source)
        end
    end
    parsed.targetBytes = target_bytes
    parsed.targetSource = target_source

    return parsed, nil
end

function OmeggaPasteSeedBytesFromSpec(paste_seed_spec)
    local text = trim(tostring(paste_seed_spec or ""))
    if text == "" then
        return nil, "default"
    end
    local lower = string.lower(text)
    if lower:sub(1, 4) == "hex:" then
        text = text:sub(5)
    end

    local bytes, parse_error = OmeggaHexBytesToNumbers(text)
    if not bytes then
        return nil, parse_error
    end
    if #bytes ~= 0x40 then
        return nil, "ServerPastePrefab paste seed must be exactly 0x40 bytes"
    end
    return bytes, "explicit-server-paste-prefab-seed"
end

function OmeggaBuildServerPastePrefabHashBuffer(parsed)
    if type(parsed) ~= "table" then
        return nil, "missing parsed PastePrefabHash spec"
    end

    local hash_bytes, hash_error = OmeggaPrefabHashHexToBytes(parsed.hash)
    if not hash_bytes then
        return nil, hash_error
    end

    local buffer, paste_seed_source_or_error = OmeggaPasteSeedBytesFromSpec(parsed.pasteSeed)
    local paste_seed_source = "default"
    if buffer then
        paste_seed_source = paste_seed_source_or_error
    elseif trim(tostring(parsed.pasteSeed or "")) ~= "" then
        return nil, paste_seed_source_or_error
    else
        buffer = {}
        for index = 1, 0x40 do
            buffer[index] = 0
        end
    end

    for index = 1, 0x20 do
        buffer[index] = hash_bytes[index] or 0
    end

    if paste_seed_source == "default" or parsed.ownershipSpecified then
        buffer[0x20 + 1] = parsed.withOwnership and 1 or 0
    end
    if paste_seed_source == "default" or parsed.tempSpecified then
        buffer[0x21 + 1] = parsed.inTemp and 1 or 0
    end

    if parsed.targetBytes ~= nil then
        local target_bytes = parsed.targetBytes
        for index = 1, 8 do
            buffer[0x28 + index] = target_bytes[index] or 0
        end
    end

    local ok, error_text = OmeggaWriteInt32LE(buffer, 0x30, parsed.grid.x, "grid.x")
    if not ok then
        return nil, error_text
    end
    ok, error_text = OmeggaWriteInt32LE(buffer, 0x34, parsed.grid.y, "grid.y")
    if not ok then
        return nil, error_text
    end
    ok, error_text = OmeggaWriteInt32LE(buffer, 0x38, parsed.grid.z, "grid.z")
    if not ok then
        return nil, error_text
    end
    if paste_seed_source == "default" or parsed.orientationSpecified then
        ok, error_text = OmeggaWriteUInt8(buffer, 0x3C, parsed.orientation or 0, "orientation")
        if not ok then
            return nil, error_text
        end
    end

    return OmeggaByteNumbersToHex(buffer), {
        total = 0x40,
        buffer = buffer,
        kind = "ServerPastePrefab",
        function_name = "ServerPastePrefab",
        layout = "ServerPastePrefab",
        hash = parsed.hash,
        mode = parsed.mode or "grid",
        final_grid = parsed.grid,
        final_orientation = buffer[0x3C + 1] or 0,
        with_ownership = (buffer[0x20 + 1] or 0) ~= 0,
        in_temp = (buffer[0x21 + 1] or 0) ~= 0,
        target_source = parsed.targetSource or "zero",
        paste_seed_source = paste_seed_source,
    }
end

function OmeggaBuildPrefabNativeReplayRecordFromParamHex(kind, param_hex, source)
    local byte_values, parse_error = OmeggaHexBytesToNumbers(param_hex)
    if not byte_values then
        return nil, parse_error
    end
    if #byte_values == 0 then
        return nil, "parameter seed is empty"
    end

    return {
        kind = tostring(kind or ""),
        source = tostring(source or "param-hex-seed"),
        args = {
            {
                memory = {
                    raw = {
                        address = 0x5000,
                        size = #byte_values,
                        bytes = OmeggaByteNumbersToHex(byte_values),
                    },
                },
            },
        },
    }, nil
end

function OmeggaLatestServerPlaceCurrentPrefabCaptureRecord()
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}
    local candidates = {
        { label = "last-replayable-client-place-capture", record = state.last_replayable_client },
        { label = "last-client-place-capture", record = state.last_client },
        { label = "last-place-capture", record = state.last },
    }

    for _, candidate in ipairs(candidates) do
        local record = candidate.record
        if record and tostring(record.kind or "") == "ServerPlaceCurrentPrefab" then
            return record, candidate.label
        end
    end

    return nil, "no Lua ServerPlaceCurrentPrefab capture is available"
end

function OmeggaBuildServerPlaceCurrentPrefabSeedRecord(place_seed_spec)
    local text = trim(tostring(place_seed_spec or ""))
    local lower = string.lower(text)

    if text == "" or lower == "default" or lower == "static" or lower == "seed" then
        local record, record_error = OmeggaBuildPrefabNativeReplayRecordFromParamHex(
            "ServerPlaceCurrentPrefab",
            OMEGGA_PREFAB_DEFAULT_PLACE_CURRENT_PREFAB_HEX,
            "default-server-place-current-prefab-seed"
        )
        if not record then
            return nil, record_error
        end
        return record, "default-server-place-current-prefab-seed"
    end

    if lower == "last" or lower == "capture" or lower == "captured" or lower == "latest" then
        local record, record_source = OmeggaLatestServerPlaceCurrentPrefabCaptureRecord()
        if record then
            return record, record_source
        end
        return nil, tostring(record_source)
    end

    if lower == "rawlast" or lower == "lastraw" or lower == "raw-capture" or lower == "last-raw-capture" then
        if type(OmeggaGetLastRawProcessEventCaptureParamHex) ~= "function" then
            return nil, "raw ProcessEvent param helper is unavailable; pass placeseed=hex:<param_hex> from DescribeRawProcessEventCapture"
        end
        local ok, param_hex = pcall(OmeggaGetLastRawProcessEventCaptureParamHex, "ServerPlaceCurrentPrefab")
        if not ok or trim(tostring(param_hex or "")) == "" then
            return nil, "no raw ServerPlaceCurrentPrefab parameter capture is available"
        end
        local record, record_error = OmeggaBuildPrefabNativeReplayRecordFromParamHex(
            "ServerPlaceCurrentPrefab",
            param_hex,
            "raw-server-place-current-prefab-seed"
        )
        if not record then
            return nil, record_error
        end
        return record, "raw-server-place-current-prefab-seed"
    end

    local hex = text
    if lower:sub(1, 4) == "hex:" then
        hex = text:sub(5)
    end
    local clean = tostring(hex or ""):gsub("[^0-9a-fA-F]", "")
    if clean == "" then
        return nil, "place seed must be default, last, rawlast, or hex:<param_hex>"
    end

    local record, record_error = OmeggaBuildPrefabNativeReplayRecordFromParamHex(
        "ServerPlaceCurrentPrefab",
        clean,
        "explicit-server-place-current-prefab-seed"
    )
    if not record then
        return nil, record_error
    end
    return record, "explicit-server-place-current-prefab-seed"
end

function OmeggaBuildServerPlaceCurrentPrefabPrimarySeedBuffer(record, record_source, parsed)
    if type(record) ~= "table" then
        return nil, "missing ServerPlaceCurrentPrefab seed record"
    end
    if type(parsed) ~= "table" or type(parsed.grid) ~= "table" then
        return nil, "missing parsed PastePrefabHash placement grid"
    end

    local buffer_hex, meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(record, "exact")
    if not buffer_hex then
        return nil, meta_or_error
    end

    local buffer = meta_or_error.buffer
    if type(buffer) ~= "table" or #buffer < 0xDF then
        return nil, "ServerPlaceCurrentPrefab seed buffer is shorter than expected 0xDF bytes"
    end

    local original_grid, primary_grid_error = OmeggaReadPrefabNativeReplayGrid(buffer, {
        x = 0x80,
        y = 0x84,
        z = 0x88,
    })
    local original_orientation, orientation_error = OmeggaReadUInt8(buffer, 0xA8)
    if original_grid == nil or original_orientation == nil then
        return nil, primary_grid_error or orientation_error
    end

    local ok, error_text = OmeggaWritePrefabNativeReplayGrid(buffer, {
        x = 0x80,
        y = 0x84,
        z = 0x88,
    }, parsed.grid, "PrimaryGrid")
    if not ok then
        return nil, error_text
    end

    local final_orientation = original_orientation
    if parsed.orientationSpecified then
        final_orientation = parsed.orientation
    end
    ok, error_text = OmeggaWriteUInt8(buffer, 0xA8, final_orientation, "orientation")
    if not ok then
        return nil, error_text
    end

    local meta = meta_or_error
    meta.seed_source = tostring(record_source or "")
    meta.adjustment_mode = "primary"
    meta.layout = "ServerPlaceCurrentPrefab"
    meta.layout_label = "ServerPlaceCurrentPrefab primary grid parameter"
    meta.original_grid = original_grid
    meta.final_grid = {
        x = parsed.grid.x,
        y = parsed.grid.y,
        z = parsed.grid.z,
    }
    meta.original_orientation = original_orientation
    meta.final_orientation = final_orientation
    meta.adjusted_grids = {
        {
            label = "PrimaryGrid",
            original = original_grid,
            final = meta.final_grid,
        },
    }
    meta.adjusted_vectors = {}
    meta.buffer = buffer
    meta.total = #buffer
    meta.function_name = "ServerPlaceCurrentPrefab"

    return OmeggaByteNumbersToHex(buffer), meta
end

function OmeggaBuildServerPlaceCurrentPrefabSeedBuffer(parsed)
    if type(parsed) ~= "table" or type(parsed.grid) ~= "table" then
        return nil, "missing parsed PastePrefabHash placement grid"
    end

    local record, record_source_or_error = OmeggaBuildServerPlaceCurrentPrefabSeedRecord(parsed.placeSeed)
    if not record then
        return nil, record_source_or_error
    end

    if tostring(parsed.placeAdjust or "primary") == "primary" then
        return OmeggaBuildServerPlaceCurrentPrefabPrimarySeedBuffer(record, record_source_or_error, parsed)
    end

    local replay_spec = "grid "
        .. tostring(parsed.grid.x)
        .. " "
        .. tostring(parsed.grid.y)
        .. " "
        .. tostring(parsed.grid.z)
        .. " "
        .. tostring(parsed.orientation or 0)
    local buffer_hex, meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(record, replay_spec)
    if meta_or_error and type(meta_or_error) == "table" then
        meta_or_error.seed_source = tostring(record_source_or_error or "")
        meta_or_error.adjustment_mode = "full"
    end
    return buffer_hex, meta_or_error
end

function OmeggaGetPrefabContextPlayerStates()
    local objects = select(1, get_cached_game_objects())
    if objects and objects.game_state then
        local player_states = get_cached_player_states(objects.game_state)
        if #player_states > 0 then
            return player_states, "game-state"
        end
    end

    local player_states = get_cached_player_states(nil)
    return player_states, "find-all"
end

function OmeggaFindServerPastePrefabContext()
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}
    local candidates = {
        { label = "last-replayable-client-capture", record = state.last_replayable_client },
        { label = "last-client-capture", record = state.last_client },
        { label = "last-capture", record = state.last },
    }
    for _, candidate in ipairs(candidates) do
        if candidate.record and is_valid_object(candidate.record.context) then
            return candidate.record.context, candidate.label
        end
    end

    local player_states, player_state_source = OmeggaGetPrefabContextPlayerStates()
    for _, player_state in ipairs(player_states) do
        local owner = try_get_property_value(player_state, "Owner")
        if is_valid_object(owner) then
            if tostring(player_state_source or "") == "find-all" then
                return owner, "player-state-owner.find-all"
            end
            return owner, "player-state-owner"
        end
    end

    for _, class_name in ipairs({ "BRPlayerController", "BP_PlayerController_C", "PlayerController" }) do
        local object = find_first_valid(class_name)
        if is_valid_object(object) then
            return object, "FindFirstOf(" .. class_name .. ")"
        end
    end

    for _, class_name in ipairs({ "BP_PlayerController_C", "BRPlayerController", "PlayerController" }) do
        local objects = prefab_probe_collect_objects(class_name)
        for _, object in ipairs(objects) do
            if is_valid_object(object) then
                return object, "FindAllOf(" .. class_name .. ")"
            end
        end
    end

    return nil, "no valid player controller context is available"
end

function OmeggaAppendPrefabPlayerContextDiagnostics(lines)
    for _, class_name in ipairs({
        "BRPlayerState",
        "BP_PlayerState_C",
        "PlayerState",
        "BRPlayerController",
        "BP_PlayerController_C",
        "PlayerController",
        "BRCharacter",
        "BP_Character_C",
        "Character",
        "Pawn",
    }) do
        local class_key = tostring(class_name):gsub("[^%w_]", "_")
        local objects = prefab_probe_collect_objects(class_name)
        table.insert(lines, "diagnostic_class_" .. class_key .. "_count=" .. tostring(#objects))
        for index, object in ipairs(objects) do
            if index > 3 then
                break
            end
            local prefix = "diagnostic_" .. class_key .. "_" .. tostring(index)
            table.insert(
                lines,
                prefix
                    .. "="
                    .. get_object_label(object, "nil")
                    .. " addr="
                    .. tostring(get_object_address_string(object) or "")
            )

            for _, property_name in ipairs({
                "Owner",
                "PlayerState",
                "Pawn",
                "AcknowledgedPawn",
                "Character",
                "Controller",
                "CurrentTool",
                "ActiveTool",
            }) do
                local value = try_get_property_value(object, property_name)
                if is_valid_object(value) then
                    table.insert(
                        lines,
                        prefix
                            .. "_"
                            .. property_name
                            .. "="
                            .. get_object_label(value, "nil")
                            .. " addr="
                            .. tostring(get_object_address_string(value) or "")
                    )
                end
            end
        end
    end
end

function OmeggaResolveObjectLocationForSpawn(object)
    local attempts = {}

    if not is_valid_object(object) then
        table.insert(attempts, "object=invalid")
        return nil, "invalid-object", attempts
    end

    local root_component = try_get_property_value(object, "RootComponent")
    if is_valid_object(root_component) then
        for _, property_name in ipairs({ "ComponentToWorld", "RelativeLocation", "ComponentVelocity" }) do
            local value = try_get_property_value(root_component, property_name)
            local vector, nested_property = prefab_probe_vector_from_nested_value(value)
            if vector then
                local source = "RootComponent." .. property_name
                if nested_property then
                    source = source .. "." .. nested_property
                end
                return vector, source, attempts
            end
            table.insert(attempts, "RootComponent." .. property_name .. "=" .. prefab_probe_compact(value_to_string(value)))
        end
    else
        table.insert(attempts, "RootComponent=unavailable")
    end

    for _, property_name in ipairs({ "Location", "RelativeLocation", "ReplicatedMovement" }) do
        local value = try_get_property_value(object, property_name)
        local vector, nested_property = prefab_probe_vector_from_nested_value(value)
        if vector then
            local source = property_name
            if nested_property then
                source = source .. "." .. nested_property
            end
            return vector, source, attempts
        end
        table.insert(attempts, property_name .. "=" .. prefab_probe_compact(value_to_string(value)))
    end

    return nil, "unresolved", attempts
end

function OmeggaTryPlayerLocationObject(lines, label, object)
    if not is_valid_object(object) then
        table.insert(lines, "candidate_" .. tostring(label) .. "_valid=false")
        return nil, nil
    end

    local vector, source, attempts = OmeggaResolveObjectLocationForSpawn(object)
    table.insert(lines, "candidate_" .. tostring(label) .. "_valid=true")
    table.insert(lines, "candidate_" .. tostring(label) .. "_object=" .. get_object_label(object, "nil"))
    table.insert(lines, "candidate_" .. tostring(label) .. "_location_ok=" .. tostring(vector ~= nil))
    table.insert(lines, "candidate_" .. tostring(label) .. "_location_source=" .. tostring(source or ""))
    if vector then
        return vector, tostring(label) .. "." .. tostring(source or "")
    end
    if attempts and #attempts > 0 then
        table.insert(lines, "candidate_" .. tostring(label) .. "_attempts=" .. table.concat(attempts, " | "))
    end
    return nil, nil
end

function OmeggaPushLivePlayerLocationSource(results, seen, label, controller, player_name)
    if not is_valid_object(controller) then
        return
    end

    local key = get_object_address_key(controller, label)
    if seen[key] then
        return
    end
    seen[key] = true

    local player_state = try_get_property_value(controller, "PlayerState")
    local resolved_player_name = trim(tostring(player_name or ""))
    if resolved_player_name == "" and is_valid_object(player_state) then
        resolved_player_name = get_player_state_chat_name(player_state)
    end
    if resolved_player_name == "" then
        resolved_player_name = trim(safe_value_to_string(select(1, try_get_first_property_value(controller, {
            "UserName",
            "PlayerNamePrivate",
            "PlayerName",
            "DisplayName",
        }))))
    end

    local pawn = try_get_property_value(controller, "Pawn")
        or try_get_property_value(controller, "AcknowledgedPawn")
        or try_get_property_value(controller, "Character")
        or try_get_property_value(player_state, "PawnPrivate")
        or try_get_property_value(player_state, "Pawn")
        or try_get_property_value(player_state, "Character")

    table.insert(results, {
        label = tostring(label or "player_controller"),
        controller = controller,
        player_state = player_state,
        pawn = pawn,
        player_name = resolved_player_name,
    })
end

function OmeggaCollectLivePlayerLocationSources(requested_name)
    local results = {}
    local seen = {}
    local requested = trim(tostring(requested_name or ""))

    local cached_source = get_cached_chat_whisper_player_source(requested)
    if cached_source and is_valid_object(cached_source.object) then
        OmeggaPushLivePlayerLocationSource(
            results,
            seen,
            "cached_whisper_player_controller",
            cached_source.object,
            cached_source.player_name
        )
    end

    for _, class_name in ipairs({ "BRPlayerController", "BP_PlayerController_C", "PlayerController" }) do
        OmeggaPushLivePlayerLocationSource(
            results,
            seen,
            "FindFirstOf(" .. tostring(class_name) .. ")",
            find_first_valid(class_name),
            nil
        )
    end

    return results
end

function OmeggaTryLivePlayerControllerLocation(lines, requested_name)
    local requested_lower = string.lower(trim(tostring(requested_name or "")))
    local sources = OmeggaCollectLivePlayerLocationSources(requested_name)
    local selected = {}

    table.insert(lines, "live_controller_sources=" .. tostring(#sources))
    for index, source in ipairs(sources) do
        local player_name = trim(tostring(source.player_name or ""))
        table.insert(
            lines,
            "live_controller_" .. tostring(index) .. "_label=" .. tostring(source.label or "")
        )
        table.insert(
            lines,
            "live_controller_" .. tostring(index) .. "_name=" .. tostring(player_name)
        )

        if requested_lower == ""
            or (player_name ~= "" and string.lower(player_name) == requested_lower) then
            table.insert(selected, source)
        end
    end

    if #selected == 0 and #sources == 1 then
        selected = sources
        table.insert(lines, "selected_by=single-live-controller-fallback")
    end

    table.insert(lines, "selected_live_controller_sources=" .. tostring(#selected))
    for index, source in ipairs(selected) do
        table.insert(lines, "selected_live_controller_" .. tostring(index) .. "=" .. tostring(source.label or ""))

        local candidates = {
            { "live_controller." .. tostring(index) .. ".pawn", source.pawn },
            { "live_controller." .. tostring(index) .. ".controller.Pawn", try_get_property_value(source.controller, "Pawn") },
            {
                "live_controller." .. tostring(index) .. ".controller.AcknowledgedPawn",
                try_get_property_value(source.controller, "AcknowledgedPawn"),
            },
            { "live_controller." .. tostring(index) .. ".controller.Character", try_get_property_value(source.controller, "Character") },
            {
                "live_controller." .. tostring(index) .. ".player_state.PawnPrivate",
                try_get_property_value(source.player_state, "PawnPrivate"),
            },
            { "live_controller." .. tostring(index) .. ".controller", source.controller },
            { "live_controller." .. tostring(index) .. ".player_state", source.player_state },
        }

        for _, candidate in ipairs(candidates) do
            local vector, source_label = OmeggaTryPlayerLocationObject(lines, candidate[1], candidate[2])
            if vector then
                return vector, source_label
            end
        end
    end

    return nil, nil
end

function OmeggaDescribePlayerLocation(spec)
    if os.getenv("OMEGGA_UE4SS_ALLOW_UNSAFE_PLAYER_LOCATION") ~= "1" then
        return table.concat({
            "Player location",
            "ok=false",
            "detail=disabled because UE4SS struct-property reads are unsafe on this Brickadia build",
        }, "\n")
    end

    local requested_name = trim(tostring(spec or ""))
    local requested_lower = string.lower(requested_name)
    local lines = {
        "Player location",
        "requested_name=" .. requested_name,
    }

    if type(BMFSocketPlayerLocation) == "function" then
        local native_ok, native_output = pcall(BMFSocketPlayerLocation, requested_name)
        if native_ok and type(native_output) == "string" and native_output ~= "" then
            if native_output:match("ok=true") then
                return native_output
            end
            table.insert(lines, "native_detail=" .. tostring(native_output:gsub("[\r\n]+", " | ")))
        else
            table.insert(lines, "native_detail=" .. tostring(native_output or "native location helper returned empty output"))
        end
    end

    if os.getenv("OMEGGA_UE4SS_PLAYER_LOCATION_USE_LUA_UOBJECTS") ~= "1" then
        table.insert(lines, "ok=false")
        table.insert(lines, "detail=native location helper unavailable")
        return table.concat(lines, "\n")
    end

    local live_vector, live_source = OmeggaTryLivePlayerControllerLocation(lines, requested_name)
    if live_vector then
        table.insert(lines, "ok=true")
        table.insert(lines, "source=" .. tostring(live_source or "live-controller"))
        table.insert(lines, "x=" .. tostring(live_vector.x))
        table.insert(lines, "y=" .. tostring(live_vector.y))
        table.insert(lines, "z=" .. tostring(live_vector.z))
        return table.concat(lines, "\n")
    end

    local objects = select(1, get_cached_game_objects())
    local player_states = {}
    if objects and objects.game_state then
        player_states = get_cached_player_states(objects.game_state)
    else
        player_states = get_cached_player_states(nil)
    end
    table.insert(lines, "player_states=" .. tostring(#player_states))

    local selected_player_state = nil
    local selected_index = 0
    local selected_name = ""
    for index, player_state in ipairs(player_states) do
        local player_name = trim(safe_value_to_string(select(1, try_get_first_property_value(player_state, {
            "UserName",
            "PlayerNamePrivate",
            "PlayerName",
            "DisplayName",
        }))))
        table.insert(lines, "player_state_" .. tostring(index) .. "_name=" .. tostring(player_name))
        if is_valid_object(player_state) and selected_player_state == nil then
            if requested_lower == "" or string.lower(player_name) == requested_lower then
                selected_player_state = player_state
                selected_index = index
                selected_name = player_name
            end
        end
    end

    if not is_valid_object(selected_player_state) and #player_states == 1 then
        selected_player_state = player_states[1]
        selected_index = 1
        selected_name = "<only-player>"
        table.insert(lines, "selected_by=only-player-fallback")
    end

    if not is_valid_object(selected_player_state) then
        table.insert(lines, "ok=false")
        table.insert(lines, "detail=no matching player state")
        return table.concat(lines, "\n")
    end

    table.insert(lines, "selected_index=" .. tostring(selected_index))
    table.insert(lines, "selected_name=" .. tostring(selected_name))
    table.insert(lines, "selected_player_state=" .. get_object_label(selected_player_state, "nil"))

    local owner = try_get_property_value(selected_player_state, "Owner")
    table.insert(lines, "owner_valid=" .. tostring(is_valid_object(owner) == true))
    table.insert(lines, "owner=" .. get_object_label(owner, "nil"))

    local candidates = {
        { "player_state.PawnPrivate", try_get_property_value(selected_player_state, "PawnPrivate") },
        { "owner.Pawn", try_get_property_value(owner, "Pawn") },
        { "owner.AcknowledgedPawn", try_get_property_value(owner, "AcknowledgedPawn") },
        { "owner.Character", try_get_property_value(owner, "Character") },
        { "player_state", selected_player_state },
        { "owner", owner },
    }

    for _, candidate in ipairs(candidates) do
        local vector, source = OmeggaTryPlayerLocationObject(lines, candidate[1], candidate[2])
        if vector then
            table.insert(lines, "ok=true")
            table.insert(lines, "source=" .. tostring(source or ""))
            table.insert(lines, "x=" .. tostring(vector.x))
            table.insert(lines, "y=" .. tostring(vector.y))
            table.insert(lines, "z=" .. tostring(vector.z))
            return table.concat(lines, "\n")
        end
    end

    table.insert(lines, "ok=false")
    table.insert(lines, "detail=no candidate exposed a vector location")
    return table.concat(lines, "\n")
end

function OmeggaObjectLooksLikePlacer(object)
    if not is_valid_object(object) then
        return false
    end

    local labels = { get_object_label(object, "") }
    local ok, class_object = pcall(function()
        return object:GetClass()
    end)
    if ok and is_valid_object(class_object) then
        table.insert(labels, get_object_label(class_object, ""))
    end

    for _, label in ipairs(labels) do
        local lower = string.lower(tostring(label or ""))
        if lower:find("placer", 1, true) then
            return true
        end
    end
    return false
end

function OmeggaObjectFullDebugLabel(object, fallback)
    if not is_valid_object(object) then
        return fallback or "nil"
    end

    local parts = {}
    local full_name = get_full_name_string(object)
    if full_name and full_name ~= "" then
        table.insert(parts, full_name)
    else
        table.insert(parts, get_object_label(object, fallback or "object"))
    end

    local address = get_object_address_string(object)
    if address and address ~= "" then
        table.insert(parts, "addr=" .. address)
    end

    local ok_class, class_object = pcall(function()
        return object:GetClass()
    end)
    if ok_class and is_valid_object(class_object) then
        local class_name = get_full_name_string(class_object) or get_object_label(class_object, "unknown")
        table.insert(parts, "class=" .. tostring(class_name))
    end

    local ok_outer, outer_object = pcall(function()
        return object:GetOuter()
    end)
    if ok_outer and is_valid_object(outer_object) then
        local outer_name = get_full_name_string(outer_object) or get_object_label(outer_object, "unknown")
        table.insert(parts, "outer=" .. tostring(outer_name))
    end

    return table.concat(parts, " ")
end

function OmeggaPropertyNameLooksToolRelated(property_name)
    local lower = string.lower(tostring(property_name or ""))
    for _, hint in ipairs({
        "tool",
        "placer",
        "place",
        "build",
        "brick",
        "inventory",
        "slot",
        "quick",
        "equipped",
        "selected",
        "active",
        "held",
    }) do
        if lower:find(hint, 1, true) then
            return true
        end
    end
    return false
end

function OmeggaAppendToolRelatedProperties(lines, label, object)
    if not is_valid_object(object) then
        table.insert(lines, tostring(label) .. "_tool_properties=unavailable")
        return
    end

    local ok_class, class_object = pcall(function()
        return object:GetClass()
    end)
    if not ok_class or not is_valid_object(class_object) or type(class_object.ForEachProperty) ~= "function" then
        table.insert(lines, tostring(label) .. "_tool_properties=unavailable")
        return
    end

    local added = 0
    local iter_ok, iter_error = pcall(function()
        class_object:ForEachProperty(function(property)
            local property_name = get_property_name(property)
            if not OmeggaPropertyNameLooksToolRelated(property_name) then
                return nil
            end

            added = added + 1
            local prefix = tostring(label) .. "_tool_property[" .. tostring(added) .. "]"
            table.insert(
                lines,
                prefix .. "=" .. tostring(property_name) .. ":" .. OmeggaDescribePropertyType(property)
            )

            local value = try_get_property_value(object, property_name)
            if is_valid_object(value) then
                table.insert(lines, prefix .. "_value=" .. OmeggaObjectFullDebugLabel(value, "value"))
                table.insert(lines, prefix .. "_looks_like_placer=" .. tostring(OmeggaObjectLooksLikePlacer(value) == true))
            elseif value ~= nil then
                table.insert(lines, prefix .. "_value=" .. prefab_probe_compact(value_to_string(value)))
            end

            return added >= 24 and true or nil
        end)
    end)

    if not iter_ok then
        table.insert(lines, tostring(label) .. "_tool_properties_error=" .. tostring(iter_error))
    elseif added == 0 then
        table.insert(lines, tostring(label) .. "_tool_properties=0")
    end
end

function OmeggaNormalizeObjectPointer(value)
    local text = tostring(value or "")
    local hex = text:match("0[xX]([0-9a-fA-F]+)") or text:match("^%s*([0-9a-fA-F]+)%s*$")
    if not hex then
        return nil
    end

    hex = string.upper(hex):gsub("^0+", "")
    if hex == "" then
        return "0"
    end
    return hex
end

function OmeggaDescribeRawProcessEventCaptureFor(spec)
    local label = trim(tostring(spec or ""))
    if label == "" then
        return "raw_process_event_capture_for\nerror=missing_label"
    end

    local lines = {
        "raw_process_event_capture_for",
        "target_label=" .. label,
    }

    if type(OmeggaGetLastRawProcessEventCaptureParamHex) ~= "function" then
        table.insert(lines, "available=false")
        table.insert(lines, "error=raw ProcessEvent param helper is unavailable")
        return table.concat(lines, "\n")
    end

    local ok, param_hex = pcall(OmeggaGetLastRawProcessEventCaptureParamHex, label)
    local clean = tostring(param_hex or ""):gsub("[^0-9a-fA-F]", "")
    if not ok or clean == "" then
        table.insert(lines, "available=false")
        table.insert(lines, "error=" .. prefab_probe_compact(tostring(ok and "no captured parameter buffer" or param_hex)))
        return table.concat(lines, "\n")
    end

    table.insert(lines, "available=true")
    table.insert(lines, "param_bytes=" .. tostring(math.floor(#clean / 2)))
    table.insert(lines, "param_hex=" .. string.upper(clean))
    if label == "ServerPastePrefab" then
        table.insert(lines, "raw_replay_layout=ServerPastePrefab")
    elseif label == "ServerPlaceCurrentPrefab" then
        table.insert(lines, "raw_replay_layout=ServerPlaceCurrentPrefab")
    end
    return table.concat(lines, "\n")
end

function OmeggaGetLastRawServerPlaceCurrentPrefabContextPointer()
    if type(OmeggaDescribeRawProcessEventCapture) ~= "function" then
        return nil, "raw ProcessEvent describe helper is unavailable"
    end

    local ok, output = pcall(OmeggaDescribeRawProcessEventCapture)
    if not ok then
        return nil, "raw ProcessEvent describe failed: " .. tostring(output)
    end

    local state = {}
    local latest_history_pointer = nil
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
            state[key] = value
        end

        local source, label, pointer, bytes = line:match(
            "^history%[%d+%]=seq=%d+ source=([^ ]+) label=([^ ]+) function=.- context_pointer=([^ ]+) bytes=(%d+)$"
        )
        if source == "client" and label == "ServerPlaceCurrentPrefab" and tonumber(bytes) == 223 then
            latest_history_pointer = pointer
        end
    end

    if state.target_label == "ServerPlaceCurrentPrefab"
        and state.source == "client"
        and tonumber(state.param_bytes) == 223
        and OmeggaNormalizeObjectPointer(state.context_pointer) then
        return state.context_pointer, "raw-process-event-current"
    end

    if OmeggaNormalizeObjectPointer(latest_history_pointer) then
        return latest_history_pointer, "raw-process-event-history"
    end

    return nil, "no recent client ServerPlaceCurrentPrefab raw context pointer is available"
end

function OmeggaFindRawServerPlaceCurrentPrefabContext()
    local raw_pointer, pointer_source = OmeggaGetLastRawServerPlaceCurrentPrefabContextPointer()
    local wanted = OmeggaNormalizeObjectPointer(raw_pointer)
    if not wanted then
        return nil, pointer_source
    end

    local seen = {}
    for _, class_name in ipairs({
        "BRTool_Placer",
        "BRTool_Placer_C",
        "Tool_Placer_C",
        "BP_Tool_Placer_C",
    }) do
        local objects = prefab_probe_collect_objects(class_name)
        for _, object in ipairs(objects) do
            if is_valid_object(object) then
                local address = get_object_address_string(object)
                local key = OmeggaNormalizeObjectPointer(address)
                if key and not seen[key] then
                    seen[key] = true
                    if key == wanted then
                        return object, tostring(pointer_source or "raw-process-event") .. "." .. class_name
                    end
                end
            end
        end
    end

    return nil, "raw place context pointer " .. tostring(raw_pointer) .. " is not loaded as a placer object"
end

function OmeggaFindServerPlaceCurrentPrefabContext()
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}
    local candidates = {
        { label = "last-replayable-client-place-capture", record = state.last_replayable_client },
        { label = "last-client-place-capture", record = state.last_client },
        { label = "last-place-capture", record = state.last },
    }
    for _, candidate in ipairs(candidates) do
        local record = candidate.record
        if record
            and tostring(record.kind or "") == "ServerPlaceCurrentPrefab"
            and is_valid_object(record.context) then
            return record.context, candidate.label
        end
    end

    local raw_context, raw_context_source = OmeggaFindRawServerPlaceCurrentPrefabContext()
    if is_valid_object(raw_context) then
        return raw_context, raw_context_source
    end

    local controller = OmeggaFindServerPastePrefabContext()
    if is_valid_object(controller) then
        for _, property_name in ipairs({
            "CurrentTool",
            "ActiveTool",
            "EquippedTool",
            "Tool",
            "SelectedTool",
        }) do
            local value = try_get_property_value(controller, property_name)
            if OmeggaObjectLooksLikePlacer(value) then
                return value, "player-controller." .. property_name
            end
        end
    end

    for _, class_name in ipairs({
        "BRTool_Placer",
        "BRTool_Placer_C",
        "Tool_Placer_C",
        "BP_Tool_Placer_C",
    }) do
        local objects = prefab_probe_collect_objects(class_name)
        for _, object in ipairs(objects) do
            if is_valid_object(object) then
                return object, "FindAllOf(" .. class_name .. ")"
            end
        end
    end

    return nil, "no valid placer tool context is available"
end

function OmeggaDescribePrefabPlacementContext()
    local lines = {
        "Prefab placement context",
    }

    local paste_context, paste_context_source = OmeggaFindServerPastePrefabContext()
    table.insert(lines, "paste_context_available=" .. tostring(is_valid_object(paste_context) == true))
    table.insert(lines, "paste_context_source=" .. tostring(paste_context_source or ""))
    table.insert(lines, "paste_context=" .. get_object_label(paste_context, "nil"))
    table.insert(lines, "paste_context_full=" .. OmeggaObjectFullDebugLabel(paste_context, "nil"))
    OmeggaAppendToolRelatedProperties(lines, "paste_context", paste_context)

    local place_context, place_context_source = OmeggaFindServerPlaceCurrentPrefabContext()
    table.insert(lines, "place_context_available=" .. tostring(is_valid_object(place_context) == true))
    table.insert(lines, "place_context_source=" .. tostring(place_context_source or ""))
    table.insert(lines, "place_context=" .. get_object_label(place_context, "nil"))
    table.insert(lines, "place_context_full=" .. OmeggaObjectFullDebugLabel(place_context, "nil"))
    OmeggaAppendToolRelatedProperties(lines, "place_context", place_context)

    for _, class_name in ipairs({
        "BRTool_Placer",
        "BRTool_Placer_C",
        "Tool_Placer_C",
        "BP_Tool_Placer_C",
    }) do
        local objects = prefab_probe_collect_objects(class_name)
        table.insert(lines, "class " .. class_name .. " count=" .. tostring(#objects))
        for index, object in ipairs(objects) do
            if index > 3 then
                break
            end
            table.insert(
                lines,
                "class "
                    .. class_name
                    .. " object["
                    .. tostring(index)
                    .. "]="
                    .. get_object_label(object, "nil")
                    .. " looks_like_placer="
                    .. tostring(OmeggaObjectLooksLikePlacer(object) == true)
            )
            table.insert(
                lines,
                "class "
                    .. class_name
                    .. " object["
                    .. tostring(index)
                    .. "]_full="
                    .. OmeggaObjectFullDebugLabel(object, "nil")
            )
        end
    end

    return table.concat(lines, "\n")
end

function OmeggaDescribeServerPastePrefabContext()
    local lines = {
        "ServerPastePrefab context",
    }

    local context, context_source = OmeggaFindServerPastePrefabContext()
    table.insert(lines, "context_available=" .. tostring(is_valid_object(context) == true))
    table.insert(lines, "context_source=" .. tostring(context_source or ""))
    table.insert(lines, "context=" .. get_object_label(context, "nil"))
    table.insert(lines, "context_addr=" .. tostring(get_object_address_string(context) or ""))

    local place_context, place_context_source = OmeggaFindServerPlaceCurrentPrefabContext()
    table.insert(lines, "place_context_available=" .. tostring(is_valid_object(place_context) == true))
    table.insert(lines, "place_context_source=" .. tostring(place_context_source or ""))
    table.insert(lines, "place_context=" .. get_object_label(place_context, "nil"))
    table.insert(lines, "place_context_addr=" .. tostring(get_object_address_string(place_context) or ""))

    local prefab_cache = find_first_valid("BRPrefabCache")
    table.insert(lines, "prefab_cache_available=" .. tostring(is_valid_object(prefab_cache) == true))
    table.insert(lines, "prefab_cache=" .. get_object_label(prefab_cache, "nil"))
    table.insert(lines, "prefab_cache_addr=" .. tostring(get_object_address_string(prefab_cache) or ""))

    local player_states, player_state_source = OmeggaGetPrefabContextPlayerStates()
    table.insert(lines, "cached_player_states=" .. tostring(#player_states))
    table.insert(lines, "cached_player_states_source=" .. tostring(player_state_source or ""))

    local limit = math.min(#player_states, 3)
    for index = 1, limit do
        local player_state = player_states[index]
        local owner = try_get_property_value(player_state, "Owner")
        table.insert(
            lines,
            "player_state_"
                .. tostring(index)
                .. "="
                .. get_object_label(player_state, "nil")
                .. " owner_valid="
                .. tostring(is_valid_object(owner) == true)
                .. " owner="
                .. get_object_label(owner, "nil")
        )
    end

    for _, class_name in ipairs({ "BRPlayerController", "BP_PlayerController_C", "PlayerController", "BRPrefabCache" }) do
        local object = find_first_valid(class_name)
        table.insert(
            lines,
            "find_first "
                .. class_name
                .. "="
                .. tostring(is_valid_object(object) == true)
                .. " object="
                .. get_object_label(object, "nil")
        )
    end

    OmeggaAppendPrefabPlayerContextDiagnostics(lines)

    return table.concat(lines, "\n")
end

function OmeggaPastePrefabHash(spec)
    if not ALLOW_PREFAB_PASTE then
        return "PastePrefabHash is disabled by default. Set OMEGGA_UE4SS_PREFAB_PASTE=1 to enable it."
    end
    if type(OmeggaUnsafeProcessEventWithParamBytes) ~= "function" then
        return "OmeggaUnsafeProcessEventWithParamBytes helper is unavailable"
    end

    local parsed, parse_error = OmeggaParseServerPastePrefabHashSpec(spec)
    if not parsed then
        return "Could not parse PastePrefabHash spec: " .. tostring(parse_error)
    end

    local buffer_hex, meta_or_error = OmeggaBuildServerPastePrefabHashBuffer(parsed)
    if not buffer_hex then
        return "Could not build PastePrefabHash buffer: " .. tostring(meta_or_error)
    end

    local lines = {
        "Paste prefab hash native",
        "kind=ServerPastePrefab",
        "source=hash",
        "function=ServerPastePrefab",
        "hash=" .. tostring(meta_or_error.hash or ""),
        "buffer_bytes=" .. tostring(meta_or_error.total or 0),
        "layout=" .. tostring(meta_or_error.layout or ""),
        "target_source=" .. tostring(meta_or_error.target_source or ""),
        "paste_seed_source=" .. tostring(meta_or_error.paste_seed_source or ""),
        "grid=" .. tostring(meta_or_error.final_grid.x) .. "," .. tostring(meta_or_error.final_grid.y) .. "," .. tostring(meta_or_error.final_grid.z),
        "orientation=" .. tostring(meta_or_error.final_orientation),
        "with_ownership=" .. tostring(meta_or_error.with_ownership),
        "in_temp=" .. tostring(meta_or_error.in_temp),
        "dry_run=" .. tostring(parsed.dryRun == true),
    }

    if parsed.dryRun then
        table.insert(lines, "ok=true")
        table.insert(lines, "result=dry-run")
        table.insert(lines, "hex_prefix=" .. tostring(buffer_hex:sub(1, 47)))
        return table.concat(lines, "\n")
    end

    local context, context_source = OmeggaFindServerPastePrefabContext()
    table.insert(lines, "context_source=" .. tostring(context_source or ""))
    table.insert(lines, "context=" .. get_object_label(context, "nil"))
    if not is_valid_object(context) then
        table.insert(lines, "ok=false")
        table.insert(lines, "result=no-context")
        table.insert(lines, "detail=Join the server or capture a native paste once before invoking PastePrefabHash.")
        return table.concat(lines, "\n")
    end

    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    local replay_id = (tonumber(state.replay_sequence) or 0) + 1
    state.replay_sequence = replay_id
    state.replay_active = true
    state.active_replay_id = replay_id
    state.last_hash_paste = {
        id = replay_id,
        requested_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        hash = meta_or_error.hash,
        function_name = "ServerPastePrefab",
        final_grid = meta_or_error.final_grid,
        final_orientation = meta_or_error.final_orientation,
        target_source = meta_or_error.target_source,
        ok = false,
        result = nil,
        detail = nil,
    }
    state.last_replay = {
        id = replay_id,
        requested_at = state.last_hash_paste.requested_at,
        function_name = "ServerPastePrefab",
        mode = "hash",
        final_grid = meta_or_error.final_grid,
        final_orientation = meta_or_error.final_orientation,
        ok = false,
        result = nil,
        detail = nil,
    }

    local ok, result, detail = pcall(OmeggaUnsafeProcessEventWithParamBytes, context, "ServerPastePrefab", buffer_hex)
    state.replay_active = false
    state.active_replay_id = nil

    state.last_hash_paste.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    state.last_hash_paste.ok = ok
    state.last_hash_paste.result = result
    state.last_hash_paste.detail = detail
    state.last_replay.completed_at = state.last_hash_paste.completed_at
    state.last_replay.ok = ok
    state.last_replay.result = result
    state.last_replay.detail = detail

    table.insert(lines, "replay_id=" .. tostring(replay_id))
    table.insert(lines, "ok=" .. tostring(ok))
    table.insert(lines, "result=" .. tostring(result))
    if detail ~= nil then
        table.insert(lines, "detail=" .. tostring(detail))
    end
    return table.concat(lines, "\n")
end

function OmeggaPlaceCurrentPrefab(spec)
    if not ALLOW_PREFAB_PASTE then
        return "PlaceCurrentPrefab is disabled by default. Set OMEGGA_UE4SS_PREFAB_PASTE=1 to enable it."
    end
    if type(OmeggaUnsafeProcessEventWithParamBytes) ~= "function" then
        return "OmeggaUnsafeProcessEventWithParamBytes helper is unavailable"
    end

    local parsed, parse_error = OmeggaParseServerPastePrefabHashSpec(spec)
    if not parsed then
        return "Could not parse PlaceCurrentPrefab spec: " .. tostring(parse_error)
    end

    local place_buffer_hex, place_meta_or_error = OmeggaBuildServerPlaceCurrentPrefabSeedBuffer(parsed)
    if not place_buffer_hex then
        return "Could not build ServerPlaceCurrentPrefab buffer: " .. tostring(place_meta_or_error)
    end

    local lines = {
        "Place current prefab native",
        "kind=ServerPlaceCurrentPrefab",
        "function=ServerPlaceCurrentPrefab",
        "grid=" .. tostring(parsed.grid.x) .. "," .. tostring(parsed.grid.y) .. "," .. tostring(parsed.grid.z),
        "orientation=" .. tostring(parsed.orientation or 0),
        "place_buffer_bytes=" .. tostring(place_meta_or_error.total or 0),
        "place_seed_source=" .. tostring(place_meta_or_error.seed_source or ""),
        "place_adjustment_mode=" .. tostring(place_meta_or_error.adjustment_mode or ""),
        "place_seed_layout=" .. tostring(place_meta_or_error.layout or ""),
        "dry_run=" .. tostring(parsed.dryRun == true),
    }

    if place_meta_or_error.original_grid and place_meta_or_error.final_grid then
        table.insert(
            lines,
            "place_original_grid="
                .. tostring(place_meta_or_error.original_grid.x)
                .. ","
                .. tostring(place_meta_or_error.original_grid.y)
                .. ","
                .. tostring(place_meta_or_error.original_grid.z)
        )
        table.insert(
            lines,
            "place_final_grid="
                .. tostring(place_meta_or_error.final_grid.x)
                .. ","
                .. tostring(place_meta_or_error.final_grid.y)
                .. ","
                .. tostring(place_meta_or_error.final_grid.z)
        )
    end
    table.insert(lines, "place_original_orientation=" .. tostring(place_meta_or_error.original_orientation))
    table.insert(lines, "place_final_orientation=" .. tostring(place_meta_or_error.final_orientation))

    if parsed.dryRun then
        table.insert(lines, "ok=true")
        table.insert(lines, "result=dry-run")
        table.insert(lines, "place_hex_prefix=" .. tostring(place_buffer_hex:sub(1, 47)))
        return table.concat(lines, "\n")
    end

    local place_context, place_context_source = OmeggaFindServerPlaceCurrentPrefabContext()
    table.insert(lines, "place_context_source=" .. tostring(place_context_source or ""))
    table.insert(lines, "place_context=" .. get_object_label(place_context, "nil"))
    if not is_valid_object(place_context) then
        table.insert(lines, "ok=false")
        table.insert(lines, "result=no-place-context")
        table.insert(lines, "detail=no valid placer tool context is available")
        return table.concat(lines, "\n")
    end

    local state = OMEGGA_PREFAB_NATIVE_CAPTURE or {}
    OMEGGA_PREFAB_NATIVE_CAPTURE = state
    local replay_id = (tonumber(state.replay_sequence) or 0) + 1
    state.replay_sequence = replay_id
    state.replay_active = true
    state.active_replay_id = replay_id
    state.last_hash_place = {
        id = replay_id,
        requested_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        final_grid = place_meta_or_error.final_grid,
        final_orientation = place_meta_or_error.final_orientation,
        place_seed_source = place_meta_or_error.seed_source,
        place_adjustment_mode = place_meta_or_error.adjustment_mode,
        place_context_source = place_context_source,
        place_ok = false,
    }
    state.last_replay = {
        id = replay_id,
        requested_at = state.last_hash_place.requested_at,
        function_name = "ServerPlaceCurrentPrefab",
        mode = "place-current",
        final_grid = place_meta_or_error.final_grid,
        final_orientation = place_meta_or_error.final_orientation,
        ok = false,
        result = nil,
        detail = nil,
    }

    local place_call_ok, place_result, place_detail =
        pcall(OmeggaUnsafeProcessEventWithParamBytes, place_context, "ServerPlaceCurrentPrefab", place_buffer_hex)
    state.replay_active = false
    state.active_replay_id = nil

    local overall_ok = place_call_ok and place_result == true
    state.last_hash_place.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    state.last_hash_place.place_ok = overall_ok
    state.last_hash_place.place_result = place_result
    state.last_hash_place.place_detail = place_detail
    state.last_replay.completed_at = state.last_hash_place.completed_at
    state.last_replay.ok = overall_ok
    state.last_replay.result = place_result
    state.last_replay.detail = place_detail

    table.insert(lines, "replay_id=" .. tostring(replay_id))
    table.insert(lines, "ok=" .. tostring(overall_ok))
    table.insert(lines, "place_call_ok=" .. tostring(place_call_ok))
    table.insert(lines, "place_result=" .. tostring(place_result))
    if place_detail ~= nil then
        table.insert(lines, "place_detail=" .. tostring(place_detail))
    end
    return table.concat(lines, "\n")
end

function OmeggaPasteAndPlacePrefabHash(spec)
    if not ALLOW_PREFAB_PASTE then
        return "PasteAndPlacePrefabHash is disabled by default. Set OMEGGA_UE4SS_PREFAB_PASTE=1 to enable it."
    end
    if type(OmeggaUnsafeProcessEventWithParamBytes) ~= "function" then
        return "OmeggaUnsafeProcessEventWithParamBytes helper is unavailable"
    end

    local parsed, parse_error = OmeggaParseServerPastePrefabHashSpec(spec)
    if not parsed then
        return "Could not parse PasteAndPlacePrefabHash spec: " .. tostring(parse_error)
    end

    local paste_buffer_hex, paste_meta_or_error = OmeggaBuildServerPastePrefabHashBuffer(parsed)
    if not paste_buffer_hex then
        return "Could not build ServerPastePrefab buffer: " .. tostring(paste_meta_or_error)
    end

    local place_buffer_hex, place_meta_or_error = OmeggaBuildServerPlaceCurrentPrefabSeedBuffer(parsed)
    if not place_buffer_hex then
        return "Could not build ServerPlaceCurrentPrefab buffer: " .. tostring(place_meta_or_error)
    end

    local lines = {
        "Paste and place prefab hash native",
        "hash=" .. tostring(paste_meta_or_error.hash or ""),
        "grid=" .. tostring(parsed.grid.x) .. "," .. tostring(parsed.grid.y) .. "," .. tostring(parsed.grid.z),
        "orientation=" .. tostring(parsed.orientation or 0),
        "with_ownership=" .. tostring(parsed.withOwnership == true),
        "in_temp=" .. tostring(parsed.inTemp == true),
        "target_source=" .. tostring(parsed.targetSource or ""),
        "paste_seed_source=" .. tostring(paste_meta_or_error.paste_seed_source or ""),
        "place_only=" .. tostring(parsed.placeOnly == true),
        "paste_buffer_bytes=" .. tostring(paste_meta_or_error.total or 0),
        "place_buffer_bytes=" .. tostring(place_meta_or_error.total or 0),
        "place_seed_source=" .. tostring(place_meta_or_error.seed_source or ""),
        "place_adjustment_mode=" .. tostring(place_meta_or_error.adjustment_mode or ""),
        "place_seed_layout=" .. tostring(place_meta_or_error.layout or ""),
        "dry_run=" .. tostring(parsed.dryRun == true),
    }

    if place_meta_or_error.original_grid and place_meta_or_error.final_grid then
        table.insert(
            lines,
            "place_original_grid="
                .. tostring(place_meta_or_error.original_grid.x)
                .. ","
                .. tostring(place_meta_or_error.original_grid.y)
                .. ","
                .. tostring(place_meta_or_error.original_grid.z)
        )
        table.insert(
            lines,
            "place_final_grid="
                .. tostring(place_meta_or_error.final_grid.x)
                .. ","
                .. tostring(place_meta_or_error.final_grid.y)
                .. ","
                .. tostring(place_meta_or_error.final_grid.z)
        )
    end
    table.insert(lines, "place_original_orientation=" .. tostring(place_meta_or_error.original_orientation))
    table.insert(lines, "place_final_orientation=" .. tostring(place_meta_or_error.final_orientation))

    if parsed.dryRun then
        table.insert(lines, "ok=true")
        table.insert(lines, "result=dry-run")
        table.insert(lines, "paste_hex_prefix=" .. tostring(paste_buffer_hex:sub(1, 47)))
        table.insert(lines, "place_hex_prefix=" .. tostring(place_buffer_hex:sub(1, 47)))
        return table.concat(lines, "\n")
    end

    local paste_context, paste_context_source = nil, "skipped-place-only"
    if not parsed.placeOnly then
        paste_context, paste_context_source = OmeggaFindServerPastePrefabContext()
        table.insert(lines, "paste_context_source=" .. tostring(paste_context_source or ""))
        table.insert(lines, "paste_context=" .. get_object_label(paste_context, "nil"))
        if not is_valid_object(paste_context) then
            table.insert(lines, "ok=false")
            table.insert(lines, "result=no-paste-context")
            table.insert(lines, "detail=Join the server before invoking PasteAndPlacePrefabHash.")
            return table.concat(lines, "\n")
        end
    else
        table.insert(lines, "paste_context_source=" .. tostring(paste_context_source or ""))
        table.insert(lines, "paste_context=skipped")
    end

    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    local replay_id = (tonumber(state.replay_sequence) or 0) + 1
    state.replay_sequence = replay_id
    state.replay_active = true
    state.active_replay_id = replay_id
    local place_context = nil
    local place_context_source = "pending-after-paste"
    state.last_hash_paste_and_place = {
        id = replay_id,
        requested_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        hash = paste_meta_or_error.hash,
        final_grid = place_meta_or_error.final_grid,
        final_orientation = place_meta_or_error.final_orientation,
        place_seed_source = place_meta_or_error.seed_source,
        place_adjustment_mode = place_meta_or_error.adjustment_mode,
        paste_context_source = paste_context_source,
        place_context_source = place_context_source,
        paste_ok = false,
        place_ok = false,
    }
    state.last_replay = {
        id = replay_id,
        requested_at = state.last_hash_paste_and_place.requested_at,
        function_name = "ServerPastePrefab+ServerPlaceCurrentPrefab",
        mode = "hash-place",
        final_grid = place_meta_or_error.final_grid,
        final_orientation = place_meta_or_error.final_orientation,
        ok = false,
        result = nil,
        detail = nil,
    }

    local paste_call_ok, paste_result, paste_detail = true, true, "skipped-place-only"
    if not parsed.placeOnly then
        paste_call_ok, paste_result, paste_detail =
            pcall(OmeggaUnsafeProcessEventWithParamBytes, paste_context, "ServerPastePrefab", paste_buffer_hex)
    end
    local place_call_ok, place_result, place_detail = false, nil, "skipped"
    if paste_call_ok and paste_result == true then
        place_context, place_context_source = OmeggaFindServerPlaceCurrentPrefabContext()
        state.last_hash_paste_and_place.place_context_source = place_context_source
        table.insert(lines, "place_context_source=" .. tostring(place_context_source or ""))
        table.insert(lines, "place_context=" .. get_object_label(place_context, "nil"))
        if is_valid_object(place_context) then
            place_call_ok, place_result, place_detail =
                pcall(OmeggaUnsafeProcessEventWithParamBytes, place_context, "ServerPlaceCurrentPrefab", place_buffer_hex)
        else
            place_call_ok = true
            place_result = false
            place_detail = "no valid placer tool context is available after ServerPastePrefab"
        end
    end
    state.replay_active = false
    state.active_replay_id = nil

    local overall_ok = paste_call_ok and paste_result == true and place_call_ok and place_result == true
    state.last_hash_paste_and_place.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    state.last_hash_paste_and_place.paste_ok = paste_call_ok and paste_result == true
    state.last_hash_paste_and_place.paste_result = paste_result
    state.last_hash_paste_and_place.paste_detail = paste_detail
    state.last_hash_paste_and_place.place_ok = place_call_ok and place_result == true
    state.last_hash_paste_and_place.place_result = place_result
    state.last_hash_paste_and_place.place_detail = place_detail
    state.last_replay.completed_at = state.last_hash_paste_and_place.completed_at
    state.last_replay.ok = overall_ok
    state.last_replay.result = overall_ok and "paste-and-place-complete" or "paste-and-place-failed"
    state.last_replay.detail = tostring(paste_detail or "") .. " | " .. tostring(place_detail or "")

    table.insert(lines, "replay_id=" .. tostring(replay_id))
    table.insert(lines, "ok=" .. tostring(overall_ok))
    table.insert(lines, "paste_call_ok=" .. tostring(paste_call_ok))
    table.insert(lines, "paste_result=" .. tostring(paste_result))
    if paste_detail ~= nil then
        table.insert(lines, "paste_detail=" .. tostring(paste_detail))
    end
    table.insert(lines, "place_call_ok=" .. tostring(place_call_ok))
    table.insert(lines, "place_result=" .. tostring(place_result))
    if place_detail ~= nil then
        table.insert(lines, "place_detail=" .. tostring(place_detail))
    end
    return table.concat(lines, "\n")
end

function OmeggaDescribePrefabNativeReplay()
    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    local lines = {
        "Prefab native replay",
        "unsafe_probes=" .. tostring(ALLOW_UNSAFE_PROBES),
        "prefab_paste=" .. tostring(ALLOW_PREFAB_PASTE),
        "helper_available=" .. tostring(type(OmeggaUnsafeProcessEventWithParamBytes) == "function"),
    }

    if state and state.last_replay then
        table.insert(lines, "last_replay_id=" .. tostring(state.last_replay.id or ""))
        table.insert(lines, "last_replay_ok=" .. tostring(state.last_replay.ok))
        table.insert(lines, "last_replay_mode=" .. tostring(state.last_replay.mode or ""))
        if state.last_replay.final_grid then
            table.insert(
                lines,
                "last_replay_grid="
                    .. tostring(state.last_replay.final_grid.x)
                    .. ","
                    .. tostring(state.last_replay.final_grid.y)
                    .. ","
                    .. tostring(state.last_replay.final_grid.z)
            )
        end
    else
        table.insert(lines, "last_replay=<none>")
    end

    if state and state.last_hash_paste then
        table.insert(lines, "last_hash_paste_id=" .. tostring(state.last_hash_paste.id or ""))
        table.insert(lines, "last_hash_paste_ok=" .. tostring(state.last_hash_paste.ok))
        table.insert(lines, "last_hash_paste_hash=" .. tostring(state.last_hash_paste.hash or ""))
        if state.last_hash_paste.final_grid then
            table.insert(
                lines,
                "last_hash_paste_grid="
                    .. tostring(state.last_hash_paste.final_grid.x)
                    .. ","
                    .. tostring(state.last_hash_paste.final_grid.y)
                    .. ","
                    .. tostring(state.last_hash_paste.final_grid.z)
            )
        end
    end

    if not state or not state.last then
        table.insert(lines, "last_capture=<none>")
        return table.concat(lines, "\n")
    end

    local record = state.last_replayable_client or state.last_client or state.last
    table.insert(lines, "last_capture=" .. tostring(record.kind or "unknown"))
    table.insert(lines, "last_capture_source=" .. tostring(record.source or ""))
    table.insert(lines, "hook=" .. tostring(record.hook_path or ""))
    table.insert(lines, "context=" .. get_object_label(record.context, "nil"))

    local buffer_hex, meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(record)
    if not buffer_hex then
        table.insert(lines, "buffer_error=" .. tostring(meta_or_error))
        return table.concat(lines, "\n")
    end

    table.insert(lines, "buffer_bytes=" .. tostring(meta_or_error.total or 0))
    table.insert(lines, "param_segments=" .. tostring(#(meta_or_error.descriptors or {})))
    if meta_or_error.layout then
        table.insert(lines, "layout=" .. tostring(meta_or_error.layout))
    end
    if meta_or_error.layout_warning then
        table.insert(lines, "layout_warning=" .. tostring(meta_or_error.layout_warning))
    end
    if meta_or_error.original_grid then
        table.insert(
            lines,
            "captured_grid="
                .. tostring(meta_or_error.original_grid.x)
                .. ","
                .. tostring(meta_or_error.original_grid.y)
                .. ","
                .. tostring(meta_or_error.original_grid.z)
        )
        table.insert(lines, "captured_orientation=" .. tostring(meta_or_error.original_orientation))
    end
    if meta_or_error.adjusted_grids then
        table.insert(lines, "known_grid_params=" .. tostring(#meta_or_error.adjusted_grids))
        for index, grid in ipairs(meta_or_error.adjusted_grids) do
            if index > 8 then
                break
            end
            local original = grid.original or {}
            table.insert(
                lines,
                "grid_param["
                    .. tostring(index)
                    .. "]="
                    .. tostring(grid.label or "")
                    .. ":"
                    .. tostring(original.x)
                    .. ","
                    .. tostring(original.y)
                    .. ","
                    .. tostring(original.z)
            )
        end
    end
    if meta_or_error.adjusted_vectors then
        table.insert(lines, "known_vector_params=" .. tostring(#meta_or_error.adjusted_vectors))
        for index, vector in ipairs(meta_or_error.adjusted_vectors) do
            if index > 8 then
                break
            end
            local original = vector.original or {}
            table.insert(
                lines,
                "vector_param["
                    .. tostring(index)
                    .. "]="
                    .. tostring(vector.label or "")
                    .. ":"
                    .. tostring(original.x)
                    .. ","
                    .. tostring(original.y)
                    .. ","
                    .. tostring(original.z)
            )
        end
    end
    table.insert(lines, "usage=ReplayLastPrefabNativeCapture [exact|offset dx dy dz [orientation]|grid x y z [orientation]]")
    return table.concat(lines, "\n")
end

function OmeggaReplayLastPrefabNativeCapture(spec)
    if not ALLOW_UNSAFE_PROBES then
        return "ReplayLastPrefabNativeCapture is disabled by default. Set OMEGGA_UE4SS_UNSAFE_PROBES=1 to enable it."
    end
    if type(OmeggaUnsafeProcessEventWithParamBytes) ~= "function" then
        return "OmeggaUnsafeProcessEventWithParamBytes helper is unavailable"
    end

    local state = OMEGGA_PREFAB_NATIVE_CAPTURE
    if not state or not state.last then
        return "No prefab native capture is available to replay"
    end

    local record = state.last_replayable_client or state.last_client or state.last
    if not OmeggaPrefabNativeReplayLayout(record.kind) then
        return "Last capture is " .. tostring(record.kind or "unknown") .. "; no replay layout is known for this capture kind"
    end
    if not is_valid_object(record.context) then
        return "Captured context is no longer valid; paste once from a connected client to refresh it"
    end

    local buffer_hex, meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(record, spec)
    if not buffer_hex then
        return "Could not build replay buffer: " .. tostring(meta_or_error)
    end

    local function_name = trim(tostring(meta_or_error.function_name or ""))
    if function_name == "" then
        function_name = tostring(record.hook_path or "")
    end
    if function_name == "" then
        function_name = "ServerPastePrefab"
    end

    local replay_id = (tonumber(state.replay_sequence) or 0) + 1
    state.replay_sequence = replay_id
    state.replay_active = true
    state.active_replay_id = replay_id
    state.last_replay = {
        id = replay_id,
        requested_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        function_name = function_name,
        mode = tostring(meta_or_error.replay_mode or "exact"),
        original_grid = meta_or_error.original_grid,
        final_grid = meta_or_error.final_grid,
        grid_delta = meta_or_error.grid_delta,
        adjusted_grids = meta_or_error.adjusted_grids,
        adjusted_vectors = meta_or_error.adjusted_vectors,
        original_orientation = meta_or_error.original_orientation,
        final_orientation = meta_or_error.final_orientation,
        ok = false,
        result = nil,
        detail = nil,
    }

    local ok, result, detail = pcall(OmeggaUnsafeProcessEventWithParamBytes, record.context, function_name, buffer_hex)
    state.replay_active = false
    state.active_replay_id = nil
    state.last_replay.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    state.last_replay.ok = ok
    state.last_replay.result = result
    state.last_replay.detail = detail

    local lines = {
        "Replay last prefab native capture",
        "replay_id=" .. tostring(replay_id),
        "kind=" .. tostring(record.kind or ""),
        "source=" .. tostring(record.source or ""),
        "function=" .. tostring(function_name),
        "context=" .. get_object_label(record.context, "nil"),
        "buffer_bytes=" .. tostring(meta_or_error.total or 0),
        "segments=" .. tostring(#(meta_or_error.descriptors or {})),
        "layout=" .. tostring(meta_or_error.layout or ""),
        "replay_mode=" .. tostring(meta_or_error.replay_mode or "exact"),
        "ok=" .. tostring(ok),
        "result=" .. tostring(result),
    }
    if meta_or_error.layout_warning then
        table.insert(lines, "layout_warning=" .. tostring(meta_or_error.layout_warning))
    end
    if meta_or_error.original_grid and meta_or_error.final_grid then
        table.insert(
            lines,
            "original_grid="
                .. tostring(meta_or_error.original_grid.x)
                .. ","
                .. tostring(meta_or_error.original_grid.y)
                .. ","
                .. tostring(meta_or_error.original_grid.z)
        )
        table.insert(
            lines,
            "final_grid="
                .. tostring(meta_or_error.final_grid.x)
                .. ","
                .. tostring(meta_or_error.final_grid.y)
                .. ","
                .. tostring(meta_or_error.final_grid.z)
        )
        table.insert(lines, "original_orientation=" .. tostring(meta_or_error.original_orientation))
        table.insert(lines, "final_orientation=" .. tostring(meta_or_error.final_orientation))
    end
    if meta_or_error.grid_delta then
        table.insert(
            lines,
            "grid_delta="
                .. tostring(meta_or_error.grid_delta.x)
                .. ","
                .. tostring(meta_or_error.grid_delta.y)
                .. ","
                .. tostring(meta_or_error.grid_delta.z)
        )
    end
    if meta_or_error.adjusted_grids then
        table.insert(lines, "adjusted_grid_params=" .. tostring(#meta_or_error.adjusted_grids))
        for index, grid in ipairs(meta_or_error.adjusted_grids) do
            if index > 8 then
                break
            end
            local original = grid.original or {}
            local final = grid.final or {}
            table.insert(
                lines,
                "adjusted_grid["
                    .. tostring(index)
                    .. "]="
                    .. tostring(grid.label or "")
                    .. ":"
                    .. tostring(original.x)
                    .. ","
                    .. tostring(original.y)
                    .. ","
                    .. tostring(original.z)
                    .. "->"
                    .. tostring(final.x)
                    .. ","
                    .. tostring(final.y)
                    .. ","
                    .. tostring(final.z)
            )
        end
    end
    if meta_or_error.adjusted_vectors then
        table.insert(lines, "adjusted_vector_params=" .. tostring(#meta_or_error.adjusted_vectors))
        for index, vector in ipairs(meta_or_error.adjusted_vectors) do
            if index > 8 then
                break
            end
            local original = vector.original or {}
            local final = vector.final or {}
            table.insert(
                lines,
                "adjusted_vector["
                    .. tostring(index)
                    .. "]="
                    .. tostring(vector.label or "")
                    .. ":"
                    .. tostring(original.x)
                    .. ","
                    .. tostring(original.y)
                    .. ","
                    .. tostring(original.z)
                    .. "->"
                    .. tostring(final.x)
                    .. ","
                    .. tostring(final.y)
                    .. ","
                    .. tostring(final.z)
            )
        end
    end
    if detail ~= nil then
        table.insert(lines, "detail=" .. tostring(detail))
    end
    return table.concat(lines, "\n")
end

function OmeggaSelfTestPrefabNativeReplayBuffer()
    local record = {
        kind = "ServerPastePrefab",
        args = {
            {
                memory = {
                    raw = {
                        address = 0x1000,
                        size = 0x20,
                        bytes = "00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x1020,
                        size = 0x01,
                        bytes = "01",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x1021,
                        size = 0x01,
                        bytes = "00",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x1028,
                        size = 0x18,
                        bytes = "88 77 66 55 44 33 22 11 64 00 00 00 38 FF FF FF 2C 01 00 00 02 00 00 00",
                    },
                },
            },
        },
    }

    local lines = { "Prefab native replay self-test" }
    local buffer_hex, meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(record, "offset 10 20 30 4")
    if not buffer_hex then
        table.insert(lines, "status=FAIL")
        table.insert(lines, "error=" .. tostring(meta_or_error))
        return table.concat(lines, "\n")
    end

    local ok = meta_or_error.total == 0x40
        and meta_or_error.original_grid
        and meta_or_error.final_grid
        and meta_or_error.function_name == "ServerPastePrefab"
        and meta_or_error.original_grid.x == 100
        and meta_or_error.original_grid.y == -200
        and meta_or_error.original_grid.z == 300
        and meta_or_error.final_grid.x == 110
        and meta_or_error.final_grid.y == -180
        and meta_or_error.final_grid.z == 330
        and meta_or_error.original_orientation == 2
        and meta_or_error.final_orientation == 4

    table.insert(lines, "status=" .. (ok and "PASS" or "FAIL"))
    table.insert(lines, "layout=" .. tostring(meta_or_error.layout))
    table.insert(lines, "function=" .. tostring(meta_or_error.function_name))
    table.insert(lines, "buffer_bytes=" .. tostring(meta_or_error.total))
    table.insert(
        lines,
        "original_grid="
            .. tostring(meta_or_error.original_grid and meta_or_error.original_grid.x)
            .. ","
            .. tostring(meta_or_error.original_grid and meta_or_error.original_grid.y)
            .. ","
            .. tostring(meta_or_error.original_grid and meta_or_error.original_grid.z)
    )
    table.insert(
        lines,
        "final_grid="
            .. tostring(meta_or_error.final_grid and meta_or_error.final_grid.x)
            .. ","
            .. tostring(meta_or_error.final_grid and meta_or_error.final_grid.y)
            .. ","
            .. tostring(meta_or_error.final_grid and meta_or_error.final_grid.z)
    )
    table.insert(lines, "original_orientation=" .. tostring(meta_or_error.original_orientation))
    table.insert(lines, "final_orientation=" .. tostring(meta_or_error.final_orientation))
    table.insert(lines, "hex_prefix=" .. tostring(buffer_hex:sub(1, 47)))

    local place_record = {
        kind = "ServerPlaceCurrentPrefab",
        args = {
            {
                memory = {
                    raw = {
                        address = 0x2000,
                        size = 0x80,
                        bytes = string.rep("00 ", 0x80),
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x2080,
                        size = 0x0C,
                        bytes = "64 00 00 00 38 FF FF FF 2C 01 00 00",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x2090,
                        size = 0x18,
                        bytes = string.rep("00 ", 0x18),
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x20A8,
                        size = 0x01,
                        bytes = "02",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x20AC,
                        size = 0x33,
                        bytes = string.rep("00 ", 0x33),
                    },
                },
            },
        },
    }

    local place_buffer_hex, place_meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(
        place_record,
        "offset 10 20 30 4"
    )
    if not place_buffer_hex then
        table.insert(lines, "place_status=FAIL")
        table.insert(lines, "place_error=" .. tostring(place_meta_or_error))
        return table.concat(lines, "\n")
    end

    local place_ok = place_meta_or_error.total == 0xDF
        and place_meta_or_error.original_grid
        and place_meta_or_error.final_grid
        and place_meta_or_error.function_name == "ServerPlaceCurrentPrefab"
        and place_meta_or_error.original_grid.x == 100
        and place_meta_or_error.original_grid.y == -200
        and place_meta_or_error.original_grid.z == 300
        and place_meta_or_error.final_grid.x == 110
        and place_meta_or_error.final_grid.y == -180
        and place_meta_or_error.final_grid.z == 330
        and place_meta_or_error.original_orientation == 2
        and place_meta_or_error.final_orientation == 4
        and place_meta_or_error.adjusted_grids
        and #place_meta_or_error.adjusted_grids == 5
        and place_meta_or_error.adjusted_vectors
        and #place_meta_or_error.adjusted_vectors == 2
        and place_meta_or_error.adjusted_vectors[1].final.x == 10
        and place_meta_or_error.adjusted_vectors[1].final.y == 20
        and place_meta_or_error.adjusted_vectors[1].final.z == 30

    table.insert(lines, "place_status=" .. (place_ok and "PASS" or "FAIL"))
    table.insert(lines, "place_layout=" .. tostring(place_meta_or_error.layout))
    table.insert(lines, "place_function=" .. tostring(place_meta_or_error.function_name))
    table.insert(lines, "place_buffer_bytes=" .. tostring(place_meta_or_error.total))
    table.insert(
        lines,
        "place_adjusted_grid_params=" .. tostring(place_meta_or_error.adjusted_grids and #place_meta_or_error.adjusted_grids)
    )
    table.insert(
        lines,
        "place_adjusted_vector_params=" .. tostring(place_meta_or_error.adjusted_vectors and #place_meta_or_error.adjusted_vectors)
    )
    table.insert(
        lines,
        "place_original_grid="
            .. tostring(place_meta_or_error.original_grid and place_meta_or_error.original_grid.x)
            .. ","
            .. tostring(place_meta_or_error.original_grid and place_meta_or_error.original_grid.y)
            .. ","
            .. tostring(place_meta_or_error.original_grid and place_meta_or_error.original_grid.z)
    )
    table.insert(
        lines,
        "place_final_grid="
            .. tostring(place_meta_or_error.final_grid and place_meta_or_error.final_grid.x)
            .. ","
            .. tostring(place_meta_or_error.final_grid and place_meta_or_error.final_grid.y)
            .. ","
            .. tostring(place_meta_or_error.final_grid and place_meta_or_error.final_grid.z)
    )
    table.insert(lines, "place_original_orientation=" .. tostring(place_meta_or_error.original_orientation))
    table.insert(lines, "place_final_orientation=" .. tostring(place_meta_or_error.final_orientation))

    local simple_record = {
        kind = "ServerPlaceSimpleEntityVolume",
        args = {
            {
                memory = {
                    raw = {
                        address = 0x3000,
                        size = 0x80,
                        bytes = string.rep("00 ", 0x80),
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x3080,
                        size = 0x08,
                        bytes = string.rep("00 ", 0x08),
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x3088,
                        size = 0x04,
                        bytes = "02 00 00 00",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x308C,
                        size = 0x0C,
                        bytes = "64 00 00 00 38 FF FF FF 2C 01 00 00",
                    },
                },
            },
            {
                memory = {
                    raw = {
                        address = 0x3098,
                        size = 0x4C,
                        bytes = string.rep("00 ", 0x4C),
                    },
                },
            },
        },
    }

    local simple_buffer_hex, simple_meta_or_error = OmeggaBuildPrefabNativeReplayBuffer(
        simple_record,
        "offset 10 20 30 4"
    )
    if not simple_buffer_hex then
        table.insert(lines, "simple_entity_status=FAIL")
        table.insert(lines, "simple_entity_error=" .. tostring(simple_meta_or_error))
        return table.concat(lines, "\n")
    end

    local simple_ok = simple_meta_or_error.total == 0xE4
        and simple_meta_or_error.original_grid
        and simple_meta_or_error.final_grid
        and simple_meta_or_error.function_name == "ServerPlaceSimpleEntityVolume"
        and simple_meta_or_error.original_grid.x == 100
        and simple_meta_or_error.original_grid.y == -200
        and simple_meta_or_error.original_grid.z == 300
        and simple_meta_or_error.final_grid.x == 110
        and simple_meta_or_error.final_grid.y == -180
        and simple_meta_or_error.final_grid.z == 330
        and simple_meta_or_error.original_orientation == 2
        and simple_meta_or_error.final_orientation == 4
        and simple_meta_or_error.adjusted_grids
        and #simple_meta_or_error.adjusted_grids == 5
        and simple_meta_or_error.adjusted_vectors
        and #simple_meta_or_error.adjusted_vectors == 2
        and simple_meta_or_error.adjusted_vectors[1].final.x == 10
        and simple_meta_or_error.adjusted_vectors[1].final.y == 20
        and simple_meta_or_error.adjusted_vectors[1].final.z == 30

    table.insert(lines, "simple_entity_status=" .. (simple_ok and "PASS" or "FAIL"))
    table.insert(lines, "simple_entity_layout=" .. tostring(simple_meta_or_error.layout))
    table.insert(lines, "simple_entity_function=" .. tostring(simple_meta_or_error.function_name))
    table.insert(lines, "simple_entity_buffer_bytes=" .. tostring(simple_meta_or_error.total))
    table.insert(
        lines,
        "simple_entity_adjusted_grid_params="
            .. tostring(simple_meta_or_error.adjusted_grids and #simple_meta_or_error.adjusted_grids)
    )
    table.insert(
        lines,
        "simple_entity_adjusted_vector_params="
            .. tostring(simple_meta_or_error.adjusted_vectors and #simple_meta_or_error.adjusted_vectors)
    )
    table.insert(
        lines,
        "simple_entity_original_grid="
            .. tostring(simple_meta_or_error.original_grid and simple_meta_or_error.original_grid.x)
            .. ","
            .. tostring(simple_meta_or_error.original_grid and simple_meta_or_error.original_grid.y)
            .. ","
            .. tostring(simple_meta_or_error.original_grid and simple_meta_or_error.original_grid.z)
    )
    table.insert(
        lines,
        "simple_entity_final_grid="
            .. tostring(simple_meta_or_error.final_grid and simple_meta_or_error.final_grid.x)
            .. ","
            .. tostring(simple_meta_or_error.final_grid and simple_meta_or_error.final_grid.y)
            .. ","
            .. tostring(simple_meta_or_error.final_grid and simple_meta_or_error.final_grid.z)
    )
    table.insert(lines, "simple_entity_original_orientation=" .. tostring(simple_meta_or_error.original_orientation))
    table.insert(lines, "simple_entity_final_orientation=" .. tostring(simple_meta_or_error.final_orientation))

    local direct_spec, direct_spec_error = OmeggaParseServerPastePrefabHashSpec(
        "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F grid 100 -200 300 2 ownership=1 temp=0 target=1122334455667788 dry-run"
    )
    if not direct_spec then
        table.insert(lines, "hash_paste_status=FAIL")
        table.insert(lines, "hash_paste_error=" .. tostring(direct_spec_error))
        return table.concat(lines, "\n")
    end

    local direct_buffer_hex, direct_meta_or_error = OmeggaBuildServerPastePrefabHashBuffer(direct_spec)
    if not direct_buffer_hex then
        table.insert(lines, "hash_paste_status=FAIL")
        table.insert(lines, "hash_paste_error=" .. tostring(direct_meta_or_error))
        return table.concat(lines, "\n")
    end

    local direct_ok = direct_meta_or_error.total == 0x40
        and direct_meta_or_error.hash == "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F"
        and direct_meta_or_error.final_grid
        and direct_meta_or_error.final_grid.x == 100
        and direct_meta_or_error.final_grid.y == -200
        and direct_meta_or_error.final_grid.z == 300
        and direct_meta_or_error.final_orientation == 2
        and direct_meta_or_error.with_ownership == true
        and direct_meta_or_error.in_temp == false
        and direct_meta_or_error.buffer[0x20 + 1] == 1
        and direct_meta_or_error.buffer[0x21 + 1] == 0
        and direct_meta_or_error.buffer[0x28 + 1] == 0x88
        and direct_meta_or_error.buffer[0x2F + 1] == 0x11

    table.insert(lines, "hash_paste_status=" .. (direct_ok and "PASS" or "FAIL"))
    table.insert(lines, "hash_paste_layout=" .. tostring(direct_meta_or_error.layout))
    table.insert(lines, "hash_paste_function=" .. tostring(direct_meta_or_error.function_name))
    table.insert(lines, "hash_paste_buffer_bytes=" .. tostring(direct_meta_or_error.total))
    table.insert(
        lines,
        "hash_paste_grid="
            .. tostring(direct_meta_or_error.final_grid and direct_meta_or_error.final_grid.x)
            .. ","
            .. tostring(direct_meta_or_error.final_grid and direct_meta_or_error.final_grid.y)
            .. ","
            .. tostring(direct_meta_or_error.final_grid and direct_meta_or_error.final_grid.z)
    )
    table.insert(lines, "hash_paste_orientation=" .. tostring(direct_meta_or_error.final_orientation))
    return table.concat(lines, "\n")
end

local function should_log_status_property(name)
    local lower = string.lower(tostring(name or ""))
    for _, hint in ipairs(STATUS_PROPERTY_HINTS) do
        if string.find(lower, hint, 1, true) then
            return true
        end
    end
    return false
end

local function log_status_object_snapshot(label, object)
    if not object or not object.IsValid or not object:IsValid() then
        bridge_log("info", "Status snapshot " .. label .. " unavailable")
        return
    end

    local class = object:GetClass()
    local class_name = class and class:IsValid() and class:GetFullName() or "unknown"
    bridge_log(
        "info",
        "Status snapshot " .. label .. " object=" .. tostring(object:GetFullName()) .. " class=" .. tostring(class_name)
    )

    if not class or not class.IsValid or not class:IsValid() or type(class.ForEachProperty) ~= "function" then
        return
    end

    class:ForEachProperty(function(property)
        local property_name = get_property_name(property)
        if not should_log_status_property(property_name) then
            return
        end

        local value_ok, value = pcall(function()
            return object:GetPropertyValue(property_name)
        end)
        bridge_log(
            "info",
            "Status snapshot "
                .. label
                .. "."
                .. tostring(property_name)
                .. "="
                .. (value_ok and describe_value(value) or ("<error:" .. tostring(value) .. ">"))
        )
    end)
end

local function log_status_candidate_properties(label, object, property_names)
    if not object or not object.IsValid or not object:IsValid() then
        bridge_log("info", "Status snapshot " .. label .. " unavailable")
        return
    end

    local full_name_ok, full_name = pcall(function()
        return object:GetFullName()
    end)
    bridge_log(
        "info",
        "Status snapshot " .. label .. " object=" .. (full_name_ok and tostring(full_name) or "<unknown>")
    )

    for _, property_name in ipairs(property_names) do
        local value_ok, value = pcall(function()
            return object:GetPropertyValue(property_name)
        end)
        if value_ok and value ~= nil then
            bridge_log(
                "info",
                "Status snapshot "
                    .. label
                    .. "."
                    .. tostring(property_name)
                    .. "="
                    .. describe_value(value)
            )
        end
    end
end

local function log_runtime_status_snapshot()
    if status_snapshot_logged then
        return
    end
    status_snapshot_logged = true

    if os.getenv("OMEGGA_UE4SS_STATUS_SNAPSHOT_WORLD_READS") ~= "1" then
        bridge_log("info", "Status snapshot skipped because UEHelpers world reads are disabled")
        return
    end

    local ok, UEHelpers = pcall(require, "UEHelpers")
    if not ok then
        bridge_log("warn", "Status snapshot could not load UEHelpers: " .. tostring(UEHelpers))
        return
    end

    local world = UEHelpers.GetWorld()
    log_status_candidate_properties("world", world, STATUS_SNAPSHOT_CANDIDATE_PROPERTIES)

    local game_mode = UEHelpers.GetGameModeBase()
    log_status_candidate_properties("game_mode", game_mode, STATUS_SNAPSHOT_CANDIDATE_PROPERTIES)
    if game_mode and game_mode.IsValid and game_mode:IsValid() and game_mode.GameSession then
        log_status_candidate_properties("game_session", game_mode.GameSession, STATUS_SNAPSHOT_CANDIDATE_PROPERTIES)
    end

    local game_state = UEHelpers.GetGameStateBase()
    log_status_candidate_properties("game_state", game_state, STATUS_SNAPSHOT_CANDIDATE_PROPERTIES)
    if game_state and game_state.IsValid and game_state:IsValid() and game_state.PlayerArray then
        local player_count_ok, player_count = pcall(function()
            return #game_state.PlayerArray
        end)
        bridge_log(
            "info",
            "Status snapshot player_array_count="
                .. (player_count_ok and tostring(player_count) or ("<error:" .. tostring(player_count) .. ">"))
        )

        if player_count_ok and player_count > 0 then
            local limit = math.min(player_count, 3)
            for index = 1, limit do
                local player_state_ok, player_state = pcall(function()
                    return game_state.PlayerArray[index]
                end)
                if player_state_ok and player_state then
                    log_status_candidate_properties(
                        "player_state_" .. tostring(index),
                        player_state,
                        STATUS_SNAPSHOT_CANDIDATE_PROPERTIES
                    )
                    local owner_ok, owner = pcall(function()
                        return player_state.Owner
                    end)
                    if owner_ok and owner and owner.IsValid and owner:IsValid() then
                        log_status_candidate_properties(
                            "player_state_" .. tostring(index) .. "_owner",
                            owner,
                            STATUS_SNAPSHOT_CANDIDATE_PROPERTIES
                        )
                    end
                else
                    bridge_log(
                        "warn",
                        "Status snapshot failed to read player_state_" .. tostring(index) .. ": " .. tostring(player_state)
                    )
                end
            end
        end
    end

    local engine = UEHelpers.GetEngine()
    log_status_candidate_properties("engine", engine, STATUS_SNAPSHOT_CANDIDATE_PROPERTIES)
end

local function schedule_runtime_status_snapshot()
    if not DEBUG_STATUS_SNAPSHOT then
        return
    end

    local callback = select(1, retain_once_callback("runtime_status_snapshot", function()
        local ok, err = pcall(log_runtime_status_snapshot)
        if not ok then
            bridge_log("warn", "Status snapshot failed: " .. tostring(err))
        end
    end))

    if type(ExecuteInGameThreadAfterFrames) == "function" then
        ExecuteInGameThreadAfterFrames(300, callback)
        return
    end

    bridge_log("warn", "Runtime status snapshot skipped: no game-thread delayed scheduler is available")
end

local function register_bridge_console_features()
    if not DEBUG_BRIDGE_HOOKS then
        bridge_log("info", "Bridge console hooks disabled by default; set OMEGGA_UE4SS_DEBUG_BRIDGE_HOOKS=1 to enable")
        return
    end

    if type(RegisterConsoleCommandGlobalHandler) == "function" then
        local ok, err = pcall(function()
            RegisterConsoleCommandGlobalHandler(
                "Omegga.Bridge.Echo",
                retain_callback("console_handler:Omegga.Bridge.Echo", function(command, params, ar)
                bridge_log(
                    "info",
                    "Self-test console handler invoked (has_output_device="
                        .. ((ar and ar.Log) and "true" or "false")
                        .. ")"
                )
                if ar and ar.Log then
                    ar:Log("Omegga bridge self-test ok")
                else
                    bridge_log("warn", "Self-test console handler did not receive an output device")
                end

                return true
            end)
            )
        end)

        if ok then
            bridge_log("info", "Registered Omegga.Bridge.Echo console self-test command")
        else
            bridge_log("warn", "Failed to register Omegga.Bridge.Echo console self-test command: " .. tostring(err))
        end
    else
        bridge_log("warn", "RegisterConsoleCommandGlobalHandler is unavailable")
    end

    if type(RegisterProcessConsoleExecPreHook) == "function" then
        local ok, err = pcall(function()
            RegisterProcessConsoleExecPreHook(retain_callback("hook:process_console_exec_pre", function(Context, Cmd, CommandParts, Ar, Executor)
                remember_command_context(Context, Executor, Cmd, "process-console-exec-pre")
                if should_trace_console_command(Cmd) then
                    bridge_log(
                        "info",
                        "ProcessConsoleExec pre cmd="
                            .. tostring(Cmd)
                            .. " context="
                            .. describe_remote_object(Context)
                            .. " executor="
                            .. describe_remote_object(Executor)
                            .. " has_output_device="
                            .. ((Ar and Ar.Log) and "true" or "false")
                    )
                end
            end))
        end)

        if ok then
            bridge_log("info", "Registered ProcessConsoleExec pre hook")
        else
            bridge_log("warn", "Failed to register ProcessConsoleExec pre hook: " .. tostring(err))
        end
    else
        bridge_log("warn", "RegisterProcessConsoleExecPreHook is unavailable")
    end

    if type(RegisterProcessConsoleExecPostHook) == "function" then
        local ok, err = pcall(function()
            RegisterProcessConsoleExecPostHook(retain_callback("hook:process_console_exec_post", function(Context, Cmd, CommandParts, Ar, Executor)
                remember_command_context(Context, Executor, Cmd, "process-console-exec-post")
                if should_trace_console_command(Cmd) then
                    bridge_log(
                        "info",
                        "ProcessConsoleExec post cmd="
                            .. tostring(Cmd)
                            .. " context="
                            .. describe_remote_object(Context)
                            .. " executor="
                            .. describe_remote_object(Executor)
                    )
                end
            end))
        end)

        if ok then
            bridge_log("info", "Registered ProcessConsoleExec post hook")
        else
            bridge_log("warn", "Failed to register ProcessConsoleExec post hook: " .. tostring(err))
        end
    else
        bridge_log("warn", "RegisterProcessConsoleExecPostHook is unavailable")
    end

    if type(RegisterCallFunctionByNameWithArgumentsPreHook) == "function" then
        local ok, err = pcall(function()
            RegisterCallFunctionByNameWithArgumentsPreHook(retain_callback(
                "hook:call_function_by_name_with_arguments_pre",
                function(Context, Str, Ar, Executor, Force)
                remember_command_context(Context, Executor, Str, "call-function-by-name-with-arguments-pre")
                if should_trace_console_command(Str) then
                    bridge_log(
                        "info",
                        "CallFunctionByNameWithArguments observed "
                            .. tostring(Str)
                            .. " context="
                            .. describe_remote_object(Context)
                            .. " executor="
                            .. describe_remote_object(Executor)
                            .. " has_output_device="
                            .. ((Ar and Ar.Log) and "true" or "false")
                    )
                end
            end
            ))
        end)

        if ok then
            bridge_log("info", "Registered CallFunctionByNameWithArguments trace hook")
        else
            bridge_log("warn", "Failed to register CallFunctionByNameWithArguments trace hook: " .. tostring(err))
        end
    else
        bridge_log("warn", "RegisterCallFunctionByNameWithArgumentsPreHook is unavailable")
    end
end

poll_inbox = nil

function start_game_thread_inbox_poller()
    local loop_state = OMEGGA_BRIDGE_LOOP_STATE

    local function run_poll_cycle()
        loop_state.polls_total = (tonumber(loop_state.polls_total) or 0) + 1
        loop_state.last_error = nil
        if type(IsInGameThread) == "function" then
            local thread_ok, on_game_thread = pcall(IsInGameThread)
            if not thread_ok or not on_game_thread then
                loop_state.thread_violation_total =
                    (tonumber(loop_state.thread_violation_total) or 0) + 1
                loop_state.last_error = "inbox_poller_left_game_thread"
                bridge_log("error", "Inbox poller refused to run outside the game thread")
                return false
            end
        else
            loop_state.thread_check_unavailable_total =
                (tonumber(loop_state.thread_check_unavailable_total) or 0) + 1
            if not loop_state.thread_check_unavailable_logged then
                loop_state.thread_check_unavailable_logged = true
                bridge_log("warn", "IsInGameThread is unavailable; relying on the game-thread-only delayed scheduler")
            end
        end

        local ok, keep_running_or_error = pcall(poll_inbox)
        if not ok then
            loop_state.callback_error_total =
                (tonumber(loop_state.callback_error_total) or 0) + 1
            loop_state.last_error = "inbox_poller_crashed"
            bridge_log("error", "Inbox poller crashed: " .. tostring(keep_running_or_error))
            return false
        end

        return keep_running_or_error ~= false
    end

    local stopped = OMEGGA_BRIDGE_STOP_POLLER("replacement")
    if not stopped then
        bridge_log("error", "Refusing to replace an inbox poller whose delayed action could not be cancelled")
        return false
    end

    if type(CancelDelayedAction) ~= "function" then
        bridge_log("error", "Inbox poller requires CancelDelayedAction for explicit lifecycle ownership")
        return false
    end

    if type(ExecuteInGameThreadAfterFrames) ~= "function"
        or type(ExecuteInGameThread) ~= "function"
        or type(EGameThreadMethod) ~= "table"
        or EGameThreadMethod.EngineTick == nil then
        return false
    end

    OMEGGA_BRIDGE_INBOX_SCHEDULER = "ExecuteInGameThreadAfterFramesChain"
    loop_state.generation = (tonumber(loop_state.generation) or 0) + 1
    local generation = loop_state.generation
    local callback_key = "game_thread_inbox_delay_chain:" .. tostring(generation)
    local callback
    local schedule_next_tick

    schedule_next_tick = function()
        if loop_state.active ~= true or loop_state.generation ~= generation then
            return false, "inbox_poller_inactive"
        end

        -- Each link is a distinct owned one-shot. Six EngineTick frames is the
        -- bounded equivalent of the prior 100 ms poll cadence.
        local scheduled, handle_or_error = pcall(ExecuteInGameThreadAfterFrames, 6, callback)
        if not scheduled or type(handle_or_error) ~= "number" then
            return false, tostring(handle_or_error or "missing action handle")
        end

        loop_state.handle = handle_or_error
        loop_state.handle_owner = "omegga_bridge_inbox"
        return true, handle_or_error
    end

    callback = retain_callback(callback_key, function()
        if loop_state.active ~= true or loop_state.generation ~= generation then
            return
        end

        -- The one-shot that entered this callback is complete, so it is no
        -- longer an outstanding action for the stop path to cancel.
        loop_state.handle = nil
        loop_state.handle_owner = nil

        -- Leave the native delayed traversal before polling or registering the
        -- successor. This trampoline is safe with both the old and patched DLL.
        local dispatch_ok, dispatched_or_error = pcall(schedule_on_game_thread, function()
            if loop_state.active ~= true or loop_state.generation ~= generation then
                return
            end
            if not run_poll_cycle() then
                local detail = tostring(loop_state.last_error or "inbox_poller_stopped")
                OMEGGA_BRIDGE_STOP_POLLER(detail)
                set_status("error", { detail = detail })
                return
            end

            local rescheduled, handle_or_error = schedule_next_tick()
            if not rescheduled then
                local detail = "inbox_poller_reschedule_failed: " .. tostring(handle_or_error)
                loop_state.last_error = detail
                OMEGGA_BRIDGE_STOP_POLLER(detail)
                set_status("error", { detail = detail })
                bridge_log("error", "Inbox poller one-shot reschedule failed: " .. tostring(handle_or_error))
            end
        end)
        if not dispatch_ok or dispatched_or_error ~= true then
            local detail = "inbox_poller_engine_tick_dispatch_failed: " .. tostring(dispatched_or_error)
            loop_state.last_error = detail
            OMEGGA_BRIDGE_STOP_POLLER(detail)
            set_status("error", { detail = detail })
        end
    end)

    loop_state.active = true
    loop_state.last_error = nil
    loop_state.release_callback = function()
        release_callback(callback_key)
    end
    local scheduled, handle_or_error = schedule_next_tick()
    if not scheduled then
        loop_state.handle = nil
        loop_state.last_error = "inbox_poller_missing_action_handle"
        OMEGGA_BRIDGE_STOP_POLLER("start_failed")
        bridge_log(
            "error",
            "Inbox poller one-shot scheduler did not return a cancellable action handle: "
                .. tostring(handle_or_error)
        )
        return false
    end

    loop_state.starts_total = (tonumber(loop_state.starts_total) or 0) + 1
    bridge_log(
        "info",
        "Starting game-thread-only inbox poller via "
            .. OMEGGA_BRIDGE_INBOX_SCHEDULER
            .. " handle="
            .. tostring(handle_or_error)
    )
    return true
end

set_status("starting", { detail = "initializing" })
bridge_log("info", "bridge mod loaded")
send_hello()
schedule_game_thread_scheduler_probes()
schedule_runtime_status_snapshot()
register_bridge_console_features()

poll_inbox = function()
    chat_hook_poll_counter = chat_hook_poll_counter + 1
    if chat_hook_poll_counter <= 3 then
        bridge_log("info", "Inbox poll tick " .. tostring(chat_hook_poll_counter))
    end
    if ENABLE_CHAT_DISCOVERY_HOOKS and (chat_hook_poll_counter == 1 or chat_hook_poll_counter % 10 == 0) then
        local hook_ok, hook_result = pcall(ensure_chat_hooks_installed)
        if hook_ok then
            if tonumber(hook_result) and tonumber(hook_result) > 0 then
                chat_trace("poll ensure_chat_hooks_installed registered=" .. tostring(hook_result))
            end
        else
            chat_trace("poll ensure_chat_hooks_installed crashed error=" .. tostring(hook_result))
        end
    end

    local file = io.open(INBOX_PATH, "rb")
    if not file then
        return true
    end

    local file_size = file:seek("end")
    if not file_size then
        file:close()
        return true
    end

    if file_size < inbox_offset then
        inbox_offset = 0
    end
    if file_size <= inbox_offset then
        file:close()
        return true
    end

    if not file:seek("set", inbox_offset) then
        file:close()
        error("Unable to seek OmeggaBridge inbox")
    end

    -- Process exactly one record per tick. This matches the existing BMF
    -- command-worker bound and prevents a burst from monopolizing the game thread.
    local line = file:read("*l")
    local next_offset = file:seek()
    file:close()
    inbox_offset = next_offset or file_size

    if line then
        line = line:gsub("\r$", "")
        if line ~= "" then
            handle_message(line)
        end
    end

    return true
end

OMEGGA_BRIDGE_POLLER_START_OK, OMEGGA_BRIDGE_POLLER_STARTED_OR_ERROR = pcall(start_game_thread_inbox_poller)
if not OMEGGA_BRIDGE_POLLER_START_OK or not OMEGGA_BRIDGE_POLLER_STARTED_OR_ERROR then
    bridge_log(
        "error",
        "No supported UE4SS game-thread delayed function is available for inbox polling: "
            .. tostring(OMEGGA_BRIDGE_POLLER_STARTED_OR_ERROR)
    )
    set_status("error", { detail = "missing_loop_scheduler" })
else
    set_status("running", { detail = "awaiting commands" })
end
