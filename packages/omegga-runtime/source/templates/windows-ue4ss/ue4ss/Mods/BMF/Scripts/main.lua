local MOD_NAME = "BMF"

local runtime_candidates = {
  "bmf/runtime.lua",
  "Scripts/bmf/runtime.lua",
  "ue4ss/main/Mods/" .. MOD_NAME .. "/Scripts/bmf/runtime.lua",
  "ue4ss/Mods/" .. MOD_NAME .. "/Scripts/bmf/runtime.lua",
  "Mods/" .. MOD_NAME .. "/Scripts/bmf/runtime.lua",
}

local last_error = nil
for _, runtime_path in ipairs(runtime_candidates) do
  local chunk, err = loadfile(runtime_path)
  if chunk then
    return chunk()
  end
  last_error = err
end

error(
  "BMF runtime module not found. Checked: "
    .. table.concat(runtime_candidates, ", ")
    .. ". Last error: "
    .. tostring(last_error)
)
