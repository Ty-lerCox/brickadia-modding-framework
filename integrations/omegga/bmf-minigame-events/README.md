# BMF Minigame Events

Omegga adapter that observes safe Brickadia minigame logs, then queues BMF
command files:

```text
bmf.minigames.events.emit event=<name> payload=<percent-encoded-json>
```

BMF appends those events to `Mods/BMF/runtime/events.jsonl` as namespaced
events such as `minigames.joinminigame`. CityRPG can tail that JSONL stream
through its BMF event relay and does not need the legacy `omegga-minigameevents`
subscriber plugin.

The adapter can also emit BMF-native data events for snapshots, minigame
creation/deletion, and team assignment changes, but that mode is disabled by
default because it depends on Brickadia `GetAll` console snapshots that can
crash the current UE4SS dedicated-server runtime.

## Why This Exists

The legacy `omegga-minigameevents` plugin directly emitted Omegga plugin events
after polling Brickadia with very short default intervals. This adapter keeps
the same event names and payload shape, but moves the stable contract to BMF and
uses conservative defaults. Safe by default:

- `joinminigame`
- `leaveminigame` after a prior join event has cached the player's current
  minigame

Unsafe snapshot-derived events are opt-in only with
`allowUnsafeConsoleSnapshots=true`:

- `snapshot`
- `created`
- `deleted`
- `teamchange`
- `roundchange`
- `roundend`
- `leaderboardchange`
- `score`
- `kill`
- `death`

## Install

Copy this folder into Omegga's `plugins` directory. Configure `commandDir`, set
`OMEGGA_BMF_COMMAND_DIR`/`OMEGGA_BMF_RUNTIME_DIR`, or use the standard
Omegga-managed BMF runtime path under `%APPDATA%\omegga\steam_installs\main`.

The adapter writes request files into `Mods/BMF/runtime/commands`; the BMF
command worker consumes those files and emits the final BMF event records.

## Commands

Registered Omegga commands:

```text
/bmfminigamestatus
/bmfminigamesync
```

`/bmfminigamestatus` prints adapter counters to the requesting player, including
leave cache misses, same-minigame checks, queued switches, and queued disconnect
leaves.
`/bmfminigamesync` runs one minigame snapshot and one leaderboard snapshot only
when `allowUnsafeConsoleSnapshots=true`; otherwise it reports that snapshots are
disabled and leaves log-derived join/leave events running.
