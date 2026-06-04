# BMF Player Sync

Optional Omegga plugin that feeds safe Omegga player identity records into BMF.

Configure `commandDir` to the active `Mods/BMF/runtime/commands` directory, or
set `OMEGGA_BMF_COMMAND_DIR`. The plugin writes `bmf.players.sync` request files
whenever Omegga's player list changes.

The synced record shape is:

```json
["username", "displayName", "uuid", "BP_PlayerController_C_...", "BP_PlayerState_C_..."]
```

BMF normalizes those records into `BMF.players.list()`,
`BMF.players.summary()`, and `BMF.players.whisperSummary()` without reading
live `PlayerState` properties through UE4SS Lua.
