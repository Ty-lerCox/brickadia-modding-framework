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

This file-backed path is useful for baseline server policy, but live
component-level denial is handled by the experimental applicator hook described
below.

## `BMF.permissions.evaluateApplicatorComponentAccess(options)`

Evaluates a component-level applicator policy. The default policy denies
`SpawnItem` and Brickadia's reflected `ItemSpawn` naming globally, while
allowing other component names:

```lua
local spawnItem = BMF.permissions.evaluateApplicatorComponentAccess({
  component = "SpawnItem",
})

local itemSpawn = BMF.permissions.evaluateApplicatorComponentAccess({
  component = "ItemSpawn",
})

local light = BMF.permissions.evaluateApplicatorComponentAccess({
  component = "Light",
})
```

Returned fields include:

- `allowed`
- `decision`: `component-denied`, `component-allowed`, or
  `component-not-allowlisted`
- `component`
- `componentKey`
- `matchedComponent`
- `actorUuid`
- `actorName`

Class-like names are normalized by suffix, so
`/Script/Brickadia.BRSpawnItemComponent` still matches a deny entry.

Custom policies can deny or allowlist component names:

```lua
local checked = BMF.permissions.evaluateApplicatorComponentAccess({
  component = "VehicleSpawn",
  deniedComponents = { "SpawnItem", "VehicleSpawn" },
})
```

This is the policy decision point used by the live applicator hook.

## `BMF.permissions.evaluateInteractConsolePrefixAccess(options)`

Evaluates the Interactable component's Print-to-Console tag policy.
`Owner`/`Admin` roles can use any prefix; everyone else must match the
configured whitelist.

```lua
local buy = BMF.permissions.evaluateInteractConsolePrefixAccess({
  tag = "buyweapon:ak",
  actor = { uuid = playerUuid, roles = { "Default" } },
  allowedPrefixes = { "buyweapon:" },
  adminRoles = { "Owner", "Admin" },
})

local teleport = BMF.permissions.evaluateInteractConsolePrefixAccess({
  tag = "teleport:spawn",
  actor = { uuid = playerUuid, roles = { "Default" } },
  allowedPrefixes = { "buyweapon:" },
})
```

Returned fields include:

- `allowed`
- `decision`: `prefix-allowed`, `prefix-denied`, `admin-bypass`,
  `empty-allowed`, or `unknown-allowed`
- `tag`
- `matchedPrefix`
- `roles`
- `matchedRole`

Matching is case-insensitive after trimming whitespace. Empty tags are allowed
by default. Unknown non-empty prefixes are denied by default unless
`denyUnknown=false` is set.

The live save-time enforcement path is the experimental native Interactable
prefix guard under `native/interact_prefix_guard/`. It wraps the reflected
`ABRTool_Applicator.ServerModifyComponent` `UFunction::Func` pointer and reads
the Interactable component type plus component-data strings from the
`FFrame.Locals` payload. On `PC-Shipping-CL13530`, the live `UFunction::Func`
offset is `0xD8`, the `FFrame.Locals` offset is `0x28`, the component type is
read from `Locals + 8`, and the component data pointer is read from
`Locals + 0x10`.

`examples/InteractConsolePrefixGuard` writes the native control file with:

- whitelisted prefixes such as `buyweapon:`;
- Owner/Admin allowed contexts;
- denial mode for unknown non-empty prefixes;
- trace/event paths for BMF feedback and validation.

Live validation on June 5, 2026 proved both sides of the policy. Owner context
allowlisting let `teleport:codex-verify` save with
`reason=ContextAllowlisted`. A one-player denied-role simulation blocked
`teleport:deny-sim` before Brickadia saved the Interactable component, and BMF
reported `native_blocked=2`, `feedback_delivered=2`, and `feedback_missed=0`
for the Omegga-backed whisper feedback path.

After a server restart, run
`scripts/sync-interact-prefix-guard-native-hook.ps1` to refresh the live
`ServerModifyComponent` pointer, rewrite the native control file, and
inject/verify the guard for the new process.

## `BMF.permissions.evaluateBrickAssetAccess(options)`

Evaluates a role-aware policy for Brickadia brick asset names. This is the
policy surface for limiting risky placeable bricks such as wheel joints, vehicle
engines, or seats while still allowing Owner/Admin roles to build freely.

```lua
local checked = BMF.permissions.evaluateBrickAssetAccess({
  asset = "B_Joint_Wheel_Micro",
  actor = { uuid = playerUuid, roles = { "Default" } },
  deniedAssets = {
    "B_Joint_Wheel_Micro",
    "B_1x1_Gate_WheelEngineSlim",
    "B_Seat",
  },
  adminRoles = { "Owner", "Admin" },
})
```

Returned fields include:

- `allowed`
- `decision`: `asset-allowed`, `asset-denied`, `asset-not-allowlisted`,
  `asset-unknown-denied`, `admin-bypass`, `role-bypass`, or `player-bypass`
- `asset`
- `assetKey`
- `matchedAsset`
- `roles`
- `matchedRole`

`deniedAssets` and `allowedAssets` accept comma/pipe-delimited strings or Lua
arrays. Matching is case-insensitive and supports `*` at the start/end of a
rule. Non-wildcard rules also match contained normalized names, so a configured
`B_Seat` rule can match a fuller reflected asset path if a native hook reports
one.

`examples/BrickAssetPlacementGuard` exposes:

- `bmf.brickassetguard.status`
- `bmf.brickassetguard.check asset=B_Joint_Wheel_Micro roles=Default`

Run this L2/L5 canary for the policy and plugin command surface:

```powershell
.\scripts\validate-bmf-brick-asset-policy.ps1
```

Current enforcement status: policy-ready, not live-enforced. The missing layer
is a cancellable placement/paste hook that can resolve the incoming brick asset
or uploaded prefab hash before Brickadia mutates the world.

## `BMF.tools.onApplicatorComponentApply(handler, options)`

Registers a Lua handler for Brickadia's live applicator component RPC policy
surface. Current reverse engineering identifies the native server method as:

```text
ABRTool_Applicator.ServerAddComponent
```

The hook receives an event table with fields such as:

- `component`
- `componentAddress`
- `componentFullName`
- `componentClassName`
- `componentCandidates`
- `contextAddress`
- `contextFullName`

Return `false` or a result with `ok=false` / `data.allowed=false` to deny the
attempt if a safe live bridge is available:

```lua
local hook = BMF.tools.onApplicatorComponentApply(function(event)
  return BMF.permissions.evaluateApplicatorComponentAccess({
    component = event.component,
    deniedComponents = { "SpawnItem", "ItemSpawn" },
  })
end)
```

BMF also runs its core denied-component policy before plugin handlers.

Important current limitation: the direct UE4SS Lua `RegisterHook` path for
`ServerAddComponent` is disabled by default. Live testing on Brickadia
`PC-Shipping-CL13530` crashed while UE4SS marshaled the struct parameter into
Lua, before the BMF callback could run. The crash signature was
`UE4SS.dll!RC::LuaType::push_structproperty`. Because of that,
`BMF.tools.onApplicatorComponentApply()` still registers handlers for future
safe enforcement paths, but returns `APPLICATOR_LUA_HOOK_UNSAFE` unless
`allowUnsafeApplicatorLuaHook=true` is explicitly set in BMF `config.json`.

Live validation also proved that the file-backed
`BR.Permission.SpawnItems=Forbidden` role policy does not stop Applicator
`ItemSpawn` component placement. The working experimental live enforcement path
is the native Applicator blocker under `native/applicator_blocker/`, which wraps
the reflected `ServerAddComponent` `UFunction::Func` pointer. On
`PC-Shipping-CL13530`, the live `UFunction::Func` offset is `0xD8`, the
`FFrame.Locals` offset is `0x28`, and the component type pointer is read from
`Locals + 8`. Returning before the original function blocks `ItemSpawn` while
other components pass through.

The native blocker writes block events to:

```text
C:/Users/tycox/OneDrive/Documents/GitHub/bmf/artifacts/local/applicator-func-blocker-events.tsv
```

After each Brickadia server restart, the process-local native pointers must be
refreshed before the blocker can work. With the BMF/Omegga bridge live, run:

```powershell
.\scripts\sync-applicator-blocker-native-hook.ps1
```

The sync script asks BMF for the current `ItemSpawn` component pointer, scans
the running Brickadia process for the `ServerAddComponent` `UFunction`, updates
the native control file, builds/injects the blocker DLL if it is not already
installed, and verifies the installed status. It deliberately leaves player and
role decisions to `examples/NoSpawnItemApplicator`.

The same native control file supports hot-reloaded allowed contexts:

```text
allowed_context=0x24009D1A300
```

When the current `ServerAddComponent` context is allowlisted, native enforcement
passes the `ItemSpawn` call through and writes an `event=allow` row. Otherwise
it returns before Brickadia mutates the brick and writes `event=block`.

`examples/NoSpawnItemApplicator` polls the event file and uses BMF/Omegga chat
delivery to tell the affected player why the component was blocked. It also
feeds role/player policy decisions back into the native control file. With one
live Omegga-synced player, it can learn the blocked Applicator context and allow
it on retry when that player is permitted. With multiple players and no exact
native context-to-player mapping yet, it stays conservative unless the context
was already learned or explicitly allowlisted.

The example plugin config supports:

```json
{
  "policy": {
    "allowedRoles": ["Admin"],
    "allowedPlayers": [],
    "allowedContexts": [],
    "allowSinglePlayerContextLearning": true
  }
}
```

`allowedRoles` is resolved from Brickadia `RoleAssignments.json`; `Admin` is the
default allowed role.

## `BMF.permissions.loadRoleAssignments(options)`

Reads and normalizes the configured Brickadia `RoleAssignments.json` file:

```lua
local loaded = BMF.permissions.loadRoleAssignments({
  savedDir = "C:/servers/Brickadia/Saved",
})
```

When `path` is omitted, BMF uses `brickadiaSavedDir` from
`framework/ue4ss/Mods/BMF/config.json` and reads:

```text
<brickadiaSavedDir>/Server/RoleAssignments.json
```

Server-console route:

```text
Omegga.Bridge.BMF bmf.permissions.role-assignments
```

## `BMF.tools.applicator.status(options)`

Returns hook registration, handler count, cache entries, event counters, and
recent attempts. It also reports whether the unsafe Lua hook opt-in is enabled.
Use `refresh=true` to rescan reflected component type objects:

```lua
local status = BMF.tools.applicator.status({ refresh = true })
```

Server-console routes:

```text
Omegga.Bridge.BMF bmf.tools.applicator.status refresh=true
Omegga.Bridge.BMF bmf.tools.applicator.refresh
```

## `BMF.permissions.enforceNoSpawnItemApplicator(options)`

Patches a `RoleSetup2.json` file so the applicator permission surface remains
allowed while `BR.Permission.SpawnItems` is denied by the default role and named
roles cannot override it to `Allowed`:

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

The enforcer evaluates:

- `defaultRole`
- every entry in `roles`

For `defaultRole`, `BR.Permission.SpawnItems` must be explicitly `Forbidden`.
For named roles, `BR.Permission.SpawnItems` may be missing because Brickadia
normalizes redundant inherited forbids after restart. A named role is compliant
when safe applicator permissions are `Allowed` and it does not explicitly allow
`BR.Permission.SpawnItems`.

It writes a timestamped `.bmf-backup-*.json` next to the role file before
mutating it, unless `backup=false` is passed. Use `dryRun=true` to report the
changes without writing.

Server-console route:

```text
Omegga.Bridge.BMF bmf.permissions.enforce-nospawnitem
Omegga.Bridge.BMF bmf.permissions.enforce-nospawnitem path=C:/tmp/RoleSetup2.json
```

Returned fields include:

- `path`
- `changed`
- `written`
- `backupPath`
- `patchedRoleCount`
- `patchedRoles`
- `restartRequired`
- `liveHotReloadSupported`

`restartRequired=true` means the file was changed. BMF does not yet prove that
Brickadia hot-reloads role setup files, so the reliable enforcement path is:
patch `RoleSetup2.json`, then restart the server.

The example plugin at `examples/NoSpawnItemApplicator` registers:

- `bmf.nospawnitem.status`
- `bmf.nospawnitem.check component=SpawnItem`
- `bmf.nospawnitem.check component=ItemSpawn`

On load, the plugin calls `BMF.permissions.enforceNoSpawnItemApplicator()`. It
also registers `Plugin.onApplicatorComponentApply(BMF, event)` through
`BMF.tools.onApplicatorComponentApply()` when the hook API is available. On the
current Brickadia build, that handler is staged but the direct Lua hook is kept
disabled to avoid the confirmed UE4SS struct marshaling crash.

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
- `BR.Permission.SpawnItems` is exactly once with state `Forbidden` on the
  default role;
- named roles either omit `BR.Permission.SpawnItems` to inherit the default
  denial or carry it exactly once with state `Forbidden`;
- duplicate permission entries are not introduced.

Runtime Lua validation is available through:

```powershell
.\scripts\validate-bmf-permission-policy.ps1
```

That canary starts a disposable headless server, loads a temporary plugin,
evaluates an unsafe role, patches it with `planRolePatch`, proves the patched
role is compliant, proves a duplicate permission entry is rejected by the policy
evaluator, proves `SpawnItem` component access is denied, proves a normal
component such as `Light` is allowed, and proves a copied `RoleSetup2.json`
can be patched with backups through `bmf.permissions.enforce-nospawnitem`.

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
