local MOD_NAME = "BMF"

local function current_script_dirs()
  if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
    return {}
  end
  local info = debug.getinfo(1, "S")
  local source = info and tostring(info.source or "") or ""
  if source:sub(1, 1) ~= "@" then
    return {}
  end
  local slash_path = source:sub(2):gsub("\\", "/")
  local slash_dir = slash_path:match("^(.*)/[^/]+$") or ""
  if slash_dir == "" then
    return {}
  end
  return {
    slash_dir:gsub("/", "\\"),
    slash_dir,
  }
end

local runtime_candidates = {}
for _, script_dir in ipairs(current_script_dirs()) do
  local runtime_path = script_dir:find("\\", 1, true) and (script_dir .. "\\bmf\\runtime.lua")
    or (script_dir .. "/bmf/runtime.lua")
  runtime_candidates[#runtime_candidates + 1] = runtime_path
end
for _, candidate in ipairs({
  "bmf/runtime.lua",
  "Scripts/bmf/runtime.lua",
  "ue4ss/main/Mods/" .. MOD_NAME .. "/Scripts/bmf/runtime.lua",
  "ue4ss/Mods/" .. MOD_NAME .. "/Scripts/bmf/runtime.lua",
  "Mods/" .. MOD_NAME .. "/Scripts/bmf/runtime.lua",
}) do
  runtime_candidates[#runtime_candidates + 1] = candidate
end

local load_errors = {}
for _, runtime_path in ipairs(runtime_candidates) do
  local readable = "unknown"
  local open_error = nil
  if type(io) == "table" and type(io.open) == "function" then
    local file, err = io.open(runtime_path, "r")
    if file then
      readable = "true"
      file:close()
    else
      readable = "false"
      open_error = err
    end
  end
  local chunk, err = loadfile(runtime_path)
  if chunk then
    return chunk()
  end
  load_errors[#load_errors + 1] = tostring(runtime_path)
    .. " readable="
    .. tostring(readable)
    .. " open_error="
    .. tostring(open_error)
    .. " load_error="
    .. tostring(err)
end

error(
  "BMF runtime module not found. Checked: "
    .. table.concat(runtime_candidates, ", ")
    .. ". Attempts: "
    .. table.concat(load_errors, " | ")
)
