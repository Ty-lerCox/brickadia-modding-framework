# AssignRole

Plans a player role assignment patch against a copied `RoleAssignments` shape.

**Maturity:** `Runnable folder`
**Required capabilities:** None

Runnable source:
[examples/AssignRole](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/AssignRole)

```lua
local Plugin = {}

Plugin.name = "AssignRole"

function Plugin.onLoad(BMF)
  local assignments = {
    savedPlayerRoles = {
      ["11111111-1111-4111-8111-111111111111"] = {
        roles = { "Admin" },
      },
    },
  }

  local planned = BMF.permissions.planPlayerRoleAssignment(assignments, {
    uuid = "11111111-1111-4111-8111-111111111111",
    add = { "Moderator" },
    remove = { "Admin" },
  })

  if planned.ok then
    local resolved = BMF.permissions.getPlayerRoles(planned.data.assignments, planned.data.uuid)
    BMF.log("AssignRole planned roles=" .. tostring(#planned.data.roles) ..
      " resolved=" .. tostring(resolved.data and resolved.data.roleCount or 0))
  else
    BMF.log("AssignRole failed code=" .. planned.code)
  end
end

return Plugin
```
