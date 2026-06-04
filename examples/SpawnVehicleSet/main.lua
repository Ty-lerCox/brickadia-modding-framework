return {
  onLoad = function(BMF)
    local spawn = BMF.vehicles.spawnSet({
      copies = {
        { name = "BMF_VehicleSpawnSet_01", position = { x = 70000, y = 0, z = 1000 } },
        { name = "BMF_VehicleSpawnSet_02", position = { x = 72000, y = 0, z = 1000 } },
        { name = "BMF_VehicleSpawnSet_03", position = { x = 74000, y = 0, z = 1000 } },
      },
    })

    BMF.log("SpawnVehicleSet ok=" .. tostring(spawn.ok) .. " code=" .. tostring(spawn.code))
  end,
}
