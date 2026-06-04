local Plugin = {
  name = "HelloBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.log("HelloBroadcast loaded")
  BMF.chat.broadcast("[BMF] HelloBroadcast loaded")
end

return Plugin
