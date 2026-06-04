local Plugin = {}

Plugin.name = "ListMinigames"

function Plugin.onLoad(BMF)
  BMF.timers.after(5000, function()
    local result = BMF.minigames.list()
    if result.ok then
      BMF.log("ListMinigames command=" .. result.data.command)
    else
      BMF.log("ListMinigames failed code=" .. result.code)
    end
  end)
end

return Plugin
