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
Interactable component's Print-to-Console tag policy. Moderator, Admin, and
Owner roles can use any prefix; everyone else must match the configured
whitelist.

```lua
local checked = BMF.permissions.evaluateInteractConsolePrefixAccess({
  tag = "buyweapon:ak",
  actor = { uuid = playerUuid, roles = { "Default" } },
  allowedPrefixes = { "buyweapon:" },
  adminRoles = { "Moderator", "Admin", "Owner" },
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

`framework/ue4ss/Mods/BMF/plugins/InteractConsolePrefixGuard` writes whitelisted prefixes, allowed
contexts, denial mode, and feedback event paths into the native control file.

With multiple players online, the plugin resolves the blocked Applicator actor
against live controller positions and cached controller identities. A
Moderator/Admin/Owner context is allowlisted only when it is within
`contextPlayerMaxDistance` and no non-bypass player is close enough to make the
match ambiguous. Ambiguous matches fail closed. Keep the Omegga BMF player-sync
adapter enabled so controller UUIDs remain current.

Related command route:

```text
bmf.interact.console message=<tag> player=<uuid> name=<name>
bmf.interactprefix.resolve-context context=0x...
```

That command forwards Omegga-observed Interactable Print-to-Console messages
into BMF. The native guard is still the save-time enforcement path.
