# Permission Role Files

**Labels:** `file-backed`, `L0 Static`, `L2 Headless`

## Who Should Read This?

Server operators should use this page for role-file planning and copied-file validation. Plugin authors should use it when building permission-aware policy.

Role-file APIs work with Brickadia `RoleSetup2.json` and
`RoleAssignments.json`. They are the safest permission surface because they can
be validated against copied files before a live server uses them.

See [Tool Guard Policies](tool-guards.md) for gameplay checks that need live
event data, and [API Validation Evidence](../../validation/api-validation.md#permissions)
for current proof level.

## When To Use

| Need | API or script |
| --- | --- |
| Describe a role's permissions | `BMF.permissions.describeRole(role)` |
| Check the no-SpawnItem role policy | `BMF.permissions.evaluateNoSpawnItemApplicator(role)` |
| Plan a role setup patch in Lua | `BMF.permissions.planRolePatch(role, patch)` |
| Patch live or copied role setup from BMF | `BMF.permissions.enforceNoSpawnItemApplicator(options)` |
| Patch copied role setup from PowerShell | `scripts/patch-role-permissions.ps1` |
| Read assigned player roles | `BMF.permissions.loadRoleAssignments(options)` |
| Plan assigned-role changes | `BMF.permissions.planPlayerRoleAssignment(assignments, patch)` |
| Patch copied assigned-role files | `scripts/patch-role-assignments.ps1` |

## Lua API

### `BMF.permissions.describeRole(role)`

Normalizes a RoleSetup2-style role table into a permission map and duplicate
report:

```lua
local described = BMF.permissions.describeRole(defaultRole)
if described.ok then
  BMF.log("permissions=" .. tostring(described.data.permissionCount))
end
```

Returned fields include `roleName`, `permissionCount`, `permissions`,
`duplicates`, and `invalid`.

### `BMF.permissions.evaluateNoSpawnItemApplicator(role)`

Checks whether a role keeps normal Applicator permissions while forbidding
`BR.Permission.SpawnItems`:

```lua
local evaluated = BMF.permissions.evaluateNoSpawnItemApplicator(defaultRole)
if evaluated.data.compliant then
  BMF.log("spawn-item applicator policy is satisfied")
end
```

This proves policy shape only. It does not prove the live Applicator component
attempt is blocked.

### `BMF.permissions.planRolePatch(role, patch)`

Plans a patched role table without mutating the original input:

```lua
local planned = BMF.permissions.planRolePatch(defaultRole, {
  noSpawnItemApplicator = true,
})
```

`noSpawnItemApplicator = true` keeps these permissions allowed:

- `BR.Permission.Building`
- `BR.Permission.Building.Applicator`
- `BR.Permission.Building.Applicator.EditBricks`
- `BR.Permission.Building.Applicator.EditEntities`

It sets `BR.Permission.SpawnItems` to `Forbidden`.

### `BMF.permissions.enforceNoSpawnItemApplicator(options)`

Patches a `RoleSetup2.json` file so the default role forbids
`BR.Permission.SpawnItems`, while named roles cannot explicitly allow it:

```lua
local enforced = BMF.permissions.enforceNoSpawnItemApplicator({
  savedDir = "C:/servers/Brickadia/Saved",
})
```

When `path` is omitted, BMF uses `brickadiaSavedDir` from
`framework/ue4ss/Mods/BMF/config.json` and writes:

```text
<brickadiaSavedDir>/Server/RoleSetup2.json
```

The enforcer writes a timestamped `.bmf-backup-*.json` next to the role file
unless `backup=false` is passed. Use `dryRun=true` to report changes without
writing.

Server-console routes:

```text
Omegga.Bridge.BMF bmf.permissions.enforce-nospawnitem
Omegga.Bridge.BMF bmf.permissions.enforce-nospawnitem path=C:/tmp/RoleSetup2.json
```

Returned fields include `path`, `changed`, `written`, `backupPath`,
`patchedRoleCount`, `patchedRoles`, `restartRequired`, and
`liveHotReloadSupported`.

!!! note
    `restartRequired=true` means the file changed. BMF does not claim that
    Brickadia hot-reloads role setup files reliably.

## Player Role Assignments

Player role assignments live in `Saved/Server/RoleAssignments.json`:

```json
{
  "savedPlayerRoles": {
    "11111111-1111-4111-8111-111111111111": {
      "roles": ["Admin"]
    }
  }
}
```

Read the configured assignment file:

```lua
local loaded = BMF.permissions.loadRoleAssignments({
  savedDir = "C:/servers/Brickadia/Saved",
})
```

When `path` is omitted, BMF reads:

```text
<brickadiaSavedDir>/Server/RoleAssignments.json
```

Server-console route:

```text
Omegga.Bridge.BMF bmf.permissions.role-assignments
```

Describe all saved assignment records:

```lua
local described = BMF.permissions.describeRoleAssignments(assignments)
```

Read one player's assigned roles by UUID or normalized player record:

```lua
local roles = BMF.permissions.getPlayerRoles(assignments, {
  uuid = "11111111-1111-4111-8111-111111111111",
})
```

Check role membership case-insensitively:

```lua
local hasRole = BMF.permissions.playerHasRole(
  assignments,
  "11111111-1111-4111-8111-111111111111",
  "Moderator"
)
```

Plan an assignment patch in Lua:

```lua
local planned = BMF.permissions.planPlayerRoleAssignment(assignments, {
  uuid = "11111111-1111-4111-8111-111111111111",
  add = { "Moderator" },
  remove = { "Admin" },
})
```

These helpers inspect file-shaped data only. They do not prove that a connected
player currently has those roles in the live server object graph.

## File Patchers

Patch a copy of a role setup file:

```powershell
.\scripts\patch-role-permissions.ps1 `
  -InputPath .\tests\fixtures\roles\default-role.json `
  -OutputPath .\artifacts\local\RoleSetup2.no-spawn-items.json `
  -RoleName Default `
  -PresetNoSpawnItemApplicator
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

Validation scripts:

```powershell
.\scripts\validate-role-permissions.ps1
.\scripts\validate-bmf-permission-policy.ps1
.\scripts\validate-role-assignments.ps1
.\scripts\validate-bmf-role-assignments.ps1
```

## Result Shape

Role-file helpers use the standard BMF result shape. Patch APIs add file-oriented
fields such as `changed`, `written`, `backupPath`, and `restartRequired`.
