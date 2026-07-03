# BMF Player Sync

Status: supported Omegga adapter.

This plugin is part of the current BMF-vendored Omegga Windows runtime direction:
<https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/packages/omegga-runtime>. It feeds safe Omegga player
identity records into BMF without requiring BMF Lua to read unsafe live
`PlayerState` properties directly.

Omegga plugin that feeds safe Omegga player identity records into BMF.

Canonical package path:

```text
packages/omegga-plugins/bmf-player-sync
```

Configure `runtimeDir` or set `OMEGGA_BMF_RUNTIME_DIR` when direct cache output
should write to a specific BMF runtime. When command bridge mode is enabled, the
plugin sends `bmf.players.sync` through the loaded `BMF Bridge` plugin, which in
turn uses the authenticated loopback socket. It does not write command request
files.

On the current Windows UE4SS runtime, Omegga's built-in player list may stay
empty when the `BRPlayerState`/`PlayerController` join matcher cannot complete.
The adapter therefore also reads Omegga's Brickadia log path and syncs online
`UserName`, `DisplayName`, and `UserId` records as
`source=omegga.players.raw.<reason>.log-fallback`.

The synced record shape is:

```json
["username", "displayName", "uuid", "BP_PlayerController_C_...", "BP_PlayerState_C_..."]
```

BMF normalizes those records into `BMF.players.list()`,
`BMF.players.summary()`, and `BMF.players.whisperSummary()` without reading
live `PlayerState` properties through UE4SS Lua.

The adapter can also forward Omegga `interact` events into BMF as
`bmf.interact.console` socket commands through BMF Bridge. Forwarded messages
are percent-encoded so Interactable Print-to-Console tags with spaces remain one command token. The
`examples/InteractConsolePrefixGuard` plugin consumes those events to audit and
message players when non-admin roles use a prefix outside the configured
whitelist.
