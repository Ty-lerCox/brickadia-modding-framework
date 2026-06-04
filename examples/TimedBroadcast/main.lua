local Plugin = {
  name = "TimedBroadcast",
}

function Plugin.onLoad(BMF)
  BMF.timers.after(10000, function()
    BMF.chat.broadcast("[BMF] TimedBroadcast fired after startup")
  end)
end

return Plugin
