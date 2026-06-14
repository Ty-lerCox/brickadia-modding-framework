local Plugin = {
  name = "RuntimeBrickState",
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parseArgs(raw)
  local args = {
    positional = {},
  }
  local consumed = {}
  local text = tostring(raw or "")

  for key, quoted in text:gmatch("([%w_.%-]+)%s*=%s*\"([^\"]*)\"") do
    local lowered = key:lower()
    args[lowered] = quoted
    consumed[lowered] = true
  end

  for token in text:gmatch("%S+") do
    local key, value = token:match("^([%w_.%-]+)=(.+)$")
    if key then
      local lowered = key:lower()
      if not consumed[lowered] then
        args[lowered] = value
      end
    else
      args.positional[#args.positional + 1] = token
    end
  end

  return args
end

local function arg(args, ...)
  for index = 1, select("#", ...) do
    local key = select(index, ...)
    local value = args[string.lower(key)]
    if value ~= nil and trim(value) ~= "" then
      return value
    end
  end
  return nil
end

local function brickId(args)
  return tonumber(arg(args, "brickid", "brick", "id") or args.positional[1] or "")
end

local function guid(args)
  return trim(arg(args, "guid", "uuid", "resource") or "")
end

local function lookupTag(args)
  return trim(arg(args, "tag", "lookuptag", "consoletag") or "")
end

local function purpose(args)
  return trim(arg(args, "purpose", "role", "kind") or "")
end

local function withOptionalGuid(options, args)
  local tagValue = lookupTag(args)
  if tagValue ~= "" then
    options.tag = tagValue
  end
  local value = guid(args)
  if value ~= "" and options.guid == nil and options.uuid == nil then
    options.guid = value
  end
  local lookupPurpose = purpose(args)
  if lookupPurpose ~= "" then
    options.purpose = lookupPurpose
  end
  return options
end

local function requireBrickId(BMF, args, commandName)
  local id = brickId(args)
  if not id or id <= 0 then
    return nil, BMF.result(false, "BRICK_ID_REQUIRED", "diagnostic brickid=<runtime-id> is required.", {
      lines = {
        "command=" .. commandName,
        "usage=" .. commandName .. " brickid=<runtime-id>",
      },
    })
  end
  return math.floor(id), nil
end

local function requireLookup(BMF, args, commandName)
  local tagValue = lookupTag(args)
  if tagValue ~= "" then
    return tagValue, nil, "tag"
  end

  local value = guid(args)
  if value == "" then
    return nil, BMF.result(false, "LOOKUP_REQUIRED", "tag=lookup:<uuid>:<purpose> or uuid=<uuid> purpose=<purpose> is required.", {
      lines = {
        "command=" .. commandName,
        "usage=" .. commandName .. " tag=lookup:<uuid>:<purpose>",
        "usage_alt=" .. commandName .. " uuid=<uuid> purpose=<purpose>",
      },
    })
  end
  return value, nil, "guid"
end

local function setOneBrick(BMF, args, commandName, visible, collision)
  local id, invalid = requireBrickId(BMF, args, commandName)
  if invalid then
    return invalid
  end

  return BMF.bricks.setRuntimeState(withOptionalGuid({
    brickid = id,
    visible = visible,
    collision = collision,
    confirm = "brick-runtime",
  }, args))
end

local function setGuid(BMF, args, commandName, visible, collision)
  local value, invalid, kind = requireLookup(BMF, args, commandName)
  if invalid then
    return invalid
  end

  local options = {
    visible = visible,
    collision = collision,
    confirm = "brick-runtime",
  }
  if kind == "tag" then
    options.tag = value
  else
    options.guid = value
  end

  return BMF.bricks.setRuntimeStateByGuid(withOptionalGuid(options, args))
end

function Plugin.onLoad(BMF)
  BMF.commands.register("bmf.runtimebrick.example.visibility", "Diagnostic: set visibility for one verified runtime brick id.", function(raw)
    local args = parseArgs(raw)
    local visible = arg(args, "visible", "visibility")
    if visible == nil then
      visible = "false"
    end
    return setOneBrick(BMF, args, "bmf.runtimebrick.example.visibility", visible, "unchanged")
  end)

  BMF.commands.register("bmf.runtimebrick.example.collision", "Diagnostic: set collision channels for one verified runtime brick id.", function(raw)
    local args = parseArgs(raw)
    local collision = arg(args, "collision", "channels", "collisionchannels")
    if collision == nil then
      collision = "0"
    end
    return setOneBrick(BMF, args, "bmf.runtimebrick.example.collision", "unchanged", collision)
  end)

  BMF.commands.register("bmf.runtimebrick.example.hide", "Hide one runtime brick and disable all collision channels.", function(raw)
    local args = parseArgs(raw)
    return setOneBrick(BMF, args, "bmf.runtimebrick.example.hide", false, 0)
  end)

  BMF.commands.register("bmf.runtimebrick.example.restore", "Show one runtime brick and restore captured collision channels.", function(raw)
    local args = parseArgs(raw)
    return setOneBrick(BMF, args, "bmf.runtimebrick.example.restore", true, "restore")
  end)

  BMF.commands.register("bmf.runtimebrick.example.bind", "Diagnostic: bind verified runtime brick ids to an opaque GUID.", function(raw)
    local args = parseArgs(raw)
    local value, invalid, kind = requireLookup(BMF, args, "bmf.runtimebrick.example.bind")
    if invalid then
      return invalid
    end

    local ids = arg(args, "brickids", "ids") or arg(args, "brickid", "brick", "id") or args.positional[1]
    if trim(ids) == "" then
      return BMF.result(false, "BRICK_ID_REQUIRED", "diagnostic brickid=<id> or brickids=<id,id> is required.", {
        lines = {
          "command=bmf.runtimebrick.example.bind",
          "usage=bmf.runtimebrick.example.bind tag=lookup:<uuid>:<purpose> brickids=<runtime-id[,runtime-id]>",
          "usage_alt=bmf.runtimebrick.example.bind guid=<opaque-id> brickids=<runtime-id[,runtime-id]>",
        },
      })
    end

    local options = {
      brickids = ids,
    }
    if kind == "tag" then
      options.tag = value
    else
      options.guid = value
    end
    return BMF.bricks.bindRuntimeGuid(withOptionalGuid(options, args))
  end)

  BMF.commands.register("bmf.runtimebrick.example.hide-guid", "Hide all runtime bricks bound to one GUID and disable collision.", function(raw)
    local args = parseArgs(raw)
    return setGuid(BMF, args, "bmf.runtimebrick.example.hide-guid", false, 0)
  end)

  BMF.commands.register("bmf.runtimebrick.example.restore-guid", "Show all runtime bricks bound to one GUID and restore captured collision.", function(raw)
    local args = parseArgs(raw)
    return setGuid(BMF, args, "bmf.runtimebrick.example.restore-guid", true, "restore")
  end)

  BMF.commands.register("bmf.runtimebrick.example.hide-lookup", "Hide one runtime brick resolved from tag=lookup:<uuid>:<purpose> or uuid=<id> purpose=<purpose>.", function(raw)
    local args = parseArgs(raw)
    return setGuid(BMF, args, "bmf.runtimebrick.example.hide-lookup", false, 0)
  end)

  BMF.commands.register("bmf.runtimebrick.example.restore-lookup", "Restore one runtime brick resolved from tag=lookup:<uuid>:<purpose> or uuid=<id> purpose=<purpose>.", function(raw)
    local args = parseArgs(raw)
    return setGuid(BMF, args, "bmf.runtimebrick.example.restore-lookup", true, "restore")
  end)

  BMF.commands.register("bmf.runtimebrick.example.status", "Show the last runtime brick-state operation result.", function(raw)
    local args = parseArgs(raw)
    local tagValue = lookupTag(args)
    if tagValue ~= "" then
      return BMF.bricks.runtimeGuidStatus({
        tag = tagValue,
      })
    end
    local value = guid(args)
    if value ~= "" then
      return BMF.bricks.runtimeGuidStatus(withOptionalGuid({
        guid = value,
      }, args))
    end
    return BMF.bricks.runtimeStateStatus()
  end)
end

return Plugin
