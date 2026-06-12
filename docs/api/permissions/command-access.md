# Command Access Policy

**Labels:** `policy`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page when exposing BMF commands through actor-aware routes. Maintainers should use it when changing command access checks or denial behavior.

Command-access policy decides whether an identified actor may run a `bmf.*`
command. It is separate from command registration and transport.

See [Commands](../commands.md#access-checked-dispatch) for the dispatch wrapper
and [API Validation Evidence](../../validation/api-validation.md#permissions)
for current proof level.

## When To Use

Use this API when a route already has trustworthy actor identity, such as a
future authenticated chat/staff command path or a controlled admin surface.
Console and bridge command behavior remains unchanged unless the caller chooses
`BMF.commands.dispatchWithAccess`.

## Lua API

`BMF.permissions.evaluateCommandAccess(policy, actor, command)` evaluates
whether a file-shaped actor may run a command:

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
- `decision`
- `actorRoles`
- `requiredRoles`
- `matchedRoles`
- `ruleFound`
- `defaultPolicy`
- `consolePolicy`
- `roleSource`

Common decisions are `role-allowed`, `role-missing`, `explicit-allow`,
`explicit-deny`, `role-denied`, `console-source`, `console-denied`, and
unknown-command default decisions.

## Access-Checked Dispatch

Routes with actor identity can opt in through
`BMF.commands.dispatchWithAccess(policy, actor, name, args, ar)`:

```lua
local handled = BMF.commands.dispatchWithAccess(
  policy,
  "11111111-1111-4111-8111-111111111111",
  "bmf.server.save",
  "name=NightlyBackup",
  ar
)
```

Denied commands are considered handled and produce console-style output:

```text
BMF bmf.server.save ACCESS_DENIED role-missing
actor_source=player
actor_uuid=11111111-1111-4111-8111-111111111111
matched_roles=
```

The wrapper writes `command.access_granted` and `command.denied` audit records.

## Validation

Command access proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#permissions).

!!! warning
    This is not live player-authenticated command enforcement by itself. The
    route that calls it must already have trustworthy actor identity.
