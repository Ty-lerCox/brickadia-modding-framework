local Plugin = {}

Plugin.name = "NoSpawnItemApplicator"

function Plugin.onLoad(BMF)
  local default_role = {
    name = "Default",
    permissions = {
      { name = "BR.Permission.Building", state = "Allowed" },
      { name = "BR.Permission.Building.Applicator", state = "Allowed" },
      { name = "BR.Permission.Building.Applicator.EditBricks", state = "Allowed" },
      { name = "BR.Permission.Building.Applicator.EditEntities", state = "Allowed" },
      { name = "BR.Permission.SpawnItems", state = "Allowed" },
    },
  }

  local planned = BMF.permissions.planRolePatch(default_role, {
    noSpawnItemApplicator = true,
  })

  if planned.ok then
    local evaluated = BMF.permissions.evaluateNoSpawnItemApplicator(planned.data.role)
    BMF.log("NoSpawnItemApplicator planned default-role policy compliant=" .. tostring(evaluated.data and evaluated.data.compliant or false))
  else
    BMF.log("NoSpawnItemApplicator failed: " .. planned.code)
  end
end

return Plugin
