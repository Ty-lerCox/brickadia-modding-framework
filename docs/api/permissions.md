# Permissions API

BMF permission APIs are split by enforcement boundary. File-backed helpers plan
or patch Brickadia role files. Tool-guard helpers evaluate live gameplay policy
for native or adapter paths. Command-access helpers decide whether an identified
actor may run a `bmf.*` command.

For architecture-level hook flow, see
[Hooked Brickadia Events Into Lua](../architecture/architecture-patterns.md#8-hooked-brickadia-events-into-lua).
For proof level and canary history, see
[API Validation Evidence](../validation/api-validation.md#permissions).

**Labels:** `file-backed`, `experimental hooks`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should use this page to choose the right permission API. Server
operators should use it to separate file-backed policy from live enforcement.
BMF maintainers should use it as the map for role files, tool guards, and
command access.

## When To Use

| Goal | Start here | Runtime effect |
| --- | --- | --- |
| Inspect or patch `RoleSetup2.json` | [Role Files](permissions/role-files.md) | File-backed; restart may be required. |
| Inspect or patch `RoleAssignments.json` | [Role Files](permissions/role-files.md#player-role-assignments) | File-backed; live hot-reload is not claimed. |
| Deny Applicator components | [Applicator Policy](permissions/applicator-policy.md) | Policy evaluator plus experimental native enforcement. |
| Limit Interactable console tags | [Interactable Tags](permissions/interactable-tags.md) | Prefix policy plus experimental native save-time guard. |
| Limit risky brick assets | [Brick Assets](permissions/brick-assets.md) | Policy evaluator; live placement hook still pending. |
| Gate `bmf.*` command execution by actor role | [Command Access](permissions/command-access.md) | Evaluator-only unless the caller uses `dispatchWithAccess`. |

## Examples

- [AssignRole](../examples/assign-role.md): plans a copied player role
  assignment change.
- [Placement Guards](../examples/placement-guards.md): runnable policy
  plugins for applicator components, Interactable console prefixes, brick
  assets, and restricted prefab hashes.

## API Pages

- [Role Files](permissions/role-files.md): role description, role setup patching,
  role-assignment patching, and file-backed enforcers.
- [Tool Guard Policies](permissions/tool-guards.md): map of gameplay guard
  policy pages.
- [Applicator Policy](permissions/applicator-policy.md): Applicator component
  policy and hook state.
- [Interactable Tags](permissions/interactable-tags.md): Interactable
  `ConsoleTag` prefix policy.
- [Brick Assets](permissions/brick-assets.md): role-aware brick asset policy.
- [Command Access](permissions/command-access.md): role-aware `bmf.*` command
  policy and opt-in dispatch.

## Result Shape

Permission helpers return the standard BMF result table:

```lua
{
  ok = true,
  code = "OK",
  message = "policy evaluated",
  data = {}
}
```

Policy helpers put the important decision in `data.allowed` and
`data.decision`. File patchers also report `changed`, `written`, backup paths,
and whether a server restart is required.

## Safety Model

File-backed helpers are safe to validate headlessly against copied files. Live
gameplay enforcement needs a proven event source or hook. BMF should prefer a
small native hook that captures only the required context, then let Lua policy
decide what to allow or deny.

!!! warning
    Do not treat file-backed role edits as proof of live gameplay denial. They
    prove file shape only until a connected-player validation confirms the
    running server behavior.
