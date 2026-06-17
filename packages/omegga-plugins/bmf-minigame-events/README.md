# BMF Minigame Events

Omegga adapter that observes safe Brickadia minigame logs, then queues BMF
command files:

```text
bmf.minigames.events.emit event=<name> payload=<percent-encoded-json>
bmf.minigames.data.apply-snapshot payload=<percent-encoded-json>
```

BMF appends those events to `Mods/BMF/runtime/events.jsonl` as namespaced
events such as `minigames.joinminigame`. CityRPG can tail that JSONL stream
through its BMF event relay and does not need the legacy `omegga-minigameevents`
subscriber plugin.

Canonical package path:

```text
packages/omegga-plugins/bmf-minigame-events
```

The adapter can also import BMF-owned observed minigame snapshots and emit
BMF-native events for creation/deletion and team assignment changes, but that
mode is disabled by default because it depends on Brickadia `GetAll` console
snapshots that can crash the current UE4SS dedicated-server runtime.

In the safe default mode, the adapter also asks BMF for
`bmf.minigames.data.snapshot` at startup. That read-only seed hydrates the
adapter's join/leave cache from BMF's existing event-fed minigame data, so an
Omegga plugin reload does not forget already-known memberships.

## Why This Exists

The legacy `omegga-minigameevents` plugin directly emitted Omegga plugin events
after polling Brickadia with very short default intervals. This adapter keeps
the same event names and payload shape, but moves the stable contract to BMF and
uses conservative defaults. Safe by default:

- `joinminigame`
- `leaveminigame` after a prior join event has cached the player's current
  minigame
- `teamchange` from observed `/JoinTeam <team>` commands after a player has a
  cached current minigame

Unsafe snapshot imports and snapshot-derived events are opt-in only with
`allowUnsafeConsoleSnapshots=true`:

- observed data import through `bmf.minigames.data.apply-snapshot`
- `created`
- `deleted`
- snapshot-derived `teamchange`
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
command worker consumes those files and writes the final BMF data/event records.
Startup cache seeding and safe manual syncs use the same command worker and
wait for the matching `.response.txt` file from `bmf.minigames.data.snapshot`.

## Commands

Registered Omegga commands:

```text
/bmfminigamestatus
/bmfminigamesync
```

`/bmfminigamestatus` prints adapter counters to the requesting player, including
leave cache misses, same-minigame checks, queued switches, and queued disconnect
leaves, plus BMF data seed attempts, successes, and the latest seed result.
`/bmfminigamesync` seeds the adapter cache from BMF-owned minigame data when
`allowUnsafeConsoleSnapshots=false`. When `allowUnsafeConsoleSnapshots=true`, it
runs one minigame snapshot and one leaderboard snapshot.
