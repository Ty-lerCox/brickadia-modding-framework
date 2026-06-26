# BMF Minigame Events

Omegga adapter that observes safe Brickadia minigame logs, then sends BMF
commands through the loaded `BMF Bridge` socket path:

```text
bmf.minigames.events.emit event=<name> payload=<percent-encoded-json>
bmf.minigames.data.apply-snapshot payload=<percent-encoded-json>
```

BMF emits those events through the in-process event bus and BMFSocket as
namespaced events such as `minigames.joinminigame`. JSONL output, when enabled
by BMF itself, is diagnostic evidence rather than this adapter's live transport.

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

Copy this folder into Omegga's `plugins` directory together with `bmf-bridge`.
Configure `runtimeDir` or set `OMEGGA_BMF_RUNTIME_DIR` if adapter status should
be written outside the standard Omegga-managed BMF runtime path under
`%APPDATA%\omegga\steam_installs\main`.

The adapter requires the loaded `BMF Bridge` plugin for BMF command delivery.
Startup cache seeding and safe manual syncs call `bmf.minigames.data.snapshot`
through that socket bridge and wait for the socket response.

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
