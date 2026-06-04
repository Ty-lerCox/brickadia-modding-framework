# Permissions API

BMF permission work currently has two layers:

- Lua planning helpers that can run inside UE4SS without writing files.
- PowerShell patch tools that operate on explicit `RoleSetup2.json` input and
  output paths.

The live runtime effect of changed permissions still requires a connected
player test. The file-backed patch path can be validated headlessly.

## `BMF.permissions.describeRole(role)`

Normalizes a RoleSetup2-style role table into a permission map and duplicate
report:

```lua
local described = BMF.permissions.describeRole(defaultRole)
if described.ok then
  BMF.log("permissions=" .. tostring(described.data.permissionCount))
end
```

Returned fields include:

- `roleName`
- `permissionCount`
- `permissions`: map of permission name to `true` or `false`
- `duplicates`: duplicate permission entries by name
- `invalid`: invalid permission names that were ignored

## `BMF.permissions.evaluateNoSpawnItemApplicator(role)`

Evaluates the specific default-role policy for safer applicator access:

```lua
local evaluated = BMF.permissions.evaluateNoSpawnItemApplicator(defaultRole)
if evaluated.data.compliant then
  BMF.log("spawn-item applicator policy is satisfied")
end
```

A compliant role has all safe applicator permissions allowed, has
`BR.Permission.SpawnItems` forbidden, and has no duplicate or invalid
permission entries.

This is a policy-shape check. It proves that the role data expresses the desired
policy, but it does not prove the live applicator exploit attempt is blocked
until a connected player can attempt the spawn-item component.

## `BMF.permissions.planRolePatch(role, patch)`

Plans a patched role table without mutating the original input.

```lua
local planned = BMF.permissions.planRolePatch(defaultRole, {
  noSpawnItemApplicator = true,
})

if planned.ok then
  BMF.log(planned.data.role.name .. " policy planned")
end
```

`noSpawnItemApplicator = true` keeps these permissions allowed:

- `BR.Permission.Building`
- `BR.Permission.Building.Applicator`
- `BR.Permission.Building.Applicator.EditBricks`
- `BR.Permission.Building.Applicator.EditEntities`

It sets this permission to `Forbidden`:

- `BR.Permission.SpawnItems`

The hypothesis is that this blocks the applicator spawn-item component while
leaving safer applicator components available. That final behavior needs `L3
Live Player` and `L5 Negative` validation.

## File Patcher

Patch a copy of a role setup file:

```powershell
.\scripts\patch-role-permissions.ps1 `
  -InputPath .\tests\fixtures\roles\default-role.json `
  -OutputPath .\artifacts\local\RoleSetup2.no-spawn-items.json `
  -RoleName Default `
  -PresetNoSpawnItemApplicator
```

Validate the fixture and the local Brickadia server role file when present:

```powershell
.\scripts\validate-role-permissions.ps1
```

The validator does not write to the live server config. It writes patched copies
under an artifact directory and asserts that:

- safe applicator permissions remain `Allowed`;
- `BR.Permission.SpawnItems` is exactly once with state `Forbidden`;
- duplicate permission entries are not introduced.

Runtime Lua validation is available through:

```powershell
.\scripts\validate-bmf-permission-policy.ps1
```

That canary starts a disposable headless server, loads a temporary plugin,
evaluates an unsafe role, patches it with `planRolePatch`, proves the patched
role is compliant, and proves a duplicate permission entry is rejected by the
policy evaluator.

## Player Role Assignments

Player role assignments are file-backed in `Saved/Server/RoleAssignments.json`
with this shape:

```json
{
  "savedPlayerRoles": {
    "11111111-1111-4111-8111-111111111111": {
      "roles": ["Admin"]
    }
  }
}
```

Describe all saved assignment records:

```lua
local described = BMF.permissions.describeRoleAssignments(assignments)
if described.ok then
  BMF.log("assigned players=" .. tostring(described.data.playerCount))
end
```

Read one player's assigned roles by UUID or normalized player record:

```lua
local roles = BMF.permissions.getPlayerRoles(assignments, {
  uuid = "11111111-1111-4111-8111-111111111111",
})

if roles.ok then
  BMF.log("roles=" .. tostring(roles.data.roleCount))
end
```

Check role membership case-insensitively:

```lua
local hasRole = BMF.permissions.playerHasRole(
  assignments,
  "11111111-1111-4111-8111-111111111111",
  "Moderator"
)
```

These helpers inspect file-shaped data only. They do not prove that a connected
player currently has those roles in the live server object graph.

Plan an assignment patch in Lua:

```lua
local planned = BMF.permissions.planPlayerRoleAssignment(assignments, {
  uuid = "11111111-1111-4111-8111-111111111111",
  add = { "Moderator" },
  remove = { "Admin" },
})
```

Patch a copied assignment file:

```powershell
.\scripts\patch-role-assignments.ps1 `
  -InputPath .\tests\fixtures\roles\role-assignments.json `
  -OutputPath .\artifacts\local\RoleAssignments.patched.json `
  -PlayerId 11111111-1111-4111-8111-111111111111 `
  -AddRoles Moderator `
  -RemoveRoles Admin `
  -RoleSetupPath .\tests\fixtures\roles\default-role.json
```

Validate the fixture and the local server assignment file when present:

```powershell
.\scripts\validate-role-assignments.ps1
```

Validate the runtime Lua readers and planner together:

```powershell
.\scripts\validate-bmf-role-assignments.ps1
```

As with role definitions, this proves file shape and copied-file mutation. It
does not prove that the running server hot-reloads changed assignments.

## Command Access Policy

`BMF.permissions.evaluateCommandAccess(policy, actor, command)` evaluates
whether a file-shaped actor should be allowed to run a `bmf.*` command.

```lua
local policy = {
  default = "deny",
  console = "allow",
  assignments = {
    savedPlayerRoles = {
      ["11111111-1111-4111-8111-111111111111"] = { roles = { "Admin" } },
    },
  },
  commands = {
    ["bmf.chat.broadcast"] = { roles = { "Admin", "Moderator" } },
    ["bmf.server.save"] = { roles = { "Admin" } },
    ["bmf.players.list"] = { allow = true },
    ["bmf.world.loadadditive"] = { deny = true },
  },
}

local access = BMF.permissions.evaluateCommandAccess(
  policy,
  "11111111-1111-4111-8111-111111111111",
  "bmf.server.save"
)
```

The `actor` can be a player UUID, a table with `uuid`, a table with direct
`roles`, or `{ source = "console" }`. Player roles are read from
`policy.assignments` or `policy.roleAssignments` when a UUID is available.

Returned fields include:

- `allowed`
- `decision`: `role-allowed`, `role-missing`, `explicit-allow`,
  `explicit-deny`, `role-denied`, `console-source`, `console-denied`, or an
  unknown-command default decision
- `actorRoles`
- `requiredRoles`
- `matchedRoles`
- `ruleFound`
- `defaultPolicy`
- `consolePolicy`
- `roleSource`

Validate the runtime evaluator:

```powershell
.\scripts\validate-bmf-command-access-policy.ps1
```

This is a policy evaluator for future routing. It does not change
`BMF.commands.dispatch` and does not prove live player-authenticated command
enforcement until chat/player command routing has an authenticated player
identity.

Routes that do have actor identity can opt into enforcement through
`BMF.commands.dispatchWithAccess(policy, actor, name, args, ar)`, documented in
`docs/api/commands.md`.

## Current Validation

- `L0 Static`: role fixture patching.
- `L2 Headless`: local `RoleSetup2.json` and `RoleAssignments.json` copy
  patching, runtime Lua policy evaluation, runtime Lua role-assignment
  read/query helpers, and command access policy evaluation.
- `L5 Negative`: duplicate permission entries are rejected by the policy
  evaluator, and command policy denies/default denies are exercised headlessly.
- `L3 Live Player`: still required to prove actual in-game denial.
- `L5 Negative`: still required for the live applicator spawn-item exploit
  attempt.
