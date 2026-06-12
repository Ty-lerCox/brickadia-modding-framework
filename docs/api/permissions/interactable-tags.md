# Interactable Tags

**Labels:** `experimental hooks`, `unsafe-native`, `L2 Headless`, `L5 Negative`

Interactable tag policy restricts Print-to-Console prefixes such as
`buyweapon:` while allowing trusted roles to use broader tags.

## Who Should Read This?

Plugin authors should use this when mapping Interactable console tags into
gameplay commands. Server operators should use it to configure safe prefixes.
BMF maintainers should use it when updating the native save-time prefix guard.

## When To Use

Use this API when a plugin or native guard has an Interactable `ConsoleTag` and
needs a role-aware allow/deny decision.

## Lua API

`BMF.permissions.evaluateInteractConsolePrefixAccess(options)` evaluates the
Interactable component's Print-to-Console tag policy. Owner/Admin roles can use
any prefix; everyone else must match the configured whitelist.

```lua
local checked = BMF.permissions.evaluateInteractConsolePrefixAccess({
  tag = "buyweapon:ak",
  actor = { uuid = playerUuid, roles = { "Default" } },
  allowedPrefixes = { "buyweapon:" },
  adminRoles = { "Owner", "Admin" },
})
```

Returned fields include `allowed`, `decision`, `tag`, `matchedPrefix`, `roles`,
and `matchedRole`. Matching is case-insensitive after trimming whitespace. Empty
tags are allowed by default. Unknown non-empty prefixes are denied unless
`denyUnknown=false` is set.

## Live Guard

The live save-time path is the experimental native Interactable prefix guard.
Refresh it after restart:

```powershell
.\scripts\sync-interact-prefix-guard-native-hook.ps1
```

`examples/InteractConsolePrefixGuard` writes whitelisted prefixes, allowed
contexts, denial mode, and feedback event paths into the native control file.

Related command route:

```text
Omegga.Bridge.BMF bmf.interact.console message=<tag> player=<uuid> name=<name>
```

That command forwards Omegga-observed Interactable Print-to-Console messages
into BMF. The native guard is still the save-time enforcement path.
