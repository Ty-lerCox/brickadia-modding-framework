# Player Fixtures And Validation

Player APIs are split between headless-safe cache behavior and live-player
features that require a running Brickadia client/server session.

**Labels:** `experimental`, `L2 Headless`, `L3 pending`

## Who Should Read This?

Maintainers should use this page when validating player identity changes.
Plugin authors should use it to understand which player behaviors are proven
headlessly and which need live-player testing.

## Validation Split

- Empty player listing can be proven at `L2 Headless`.
- Brickadia saved/log identity discovery is BMF core behavior inside the
  supported Omegga data directory. It should be validated against
  `Brickadia.log` plus `PlayerNameCache.json` fixtures and then confirmed with
  `L3 Live Player`.
- Cache sync, normalization, summary formatting, and lookup can be proven from
  `L0 Static` and `L2 Headless` command-worker tests.
- Name normalization, query matching, missing-field handling, and permission map
  interpretation can be tested with `L0 Static` fixtures.
- `scripts/validate-bmf-player-messaging.ps1` proves direct-record name
  resolution, exact lookup, UUID lookup, partial display-name lookup, and
  empty-server `PLAYER_NOT_FOUND` command behavior.
- Real UUID, username, and display name can be supplied by Brickadia logs when
  `brickadiaSavedDir` is configured. Controller path and player-state path
  mapping should come from the Omegga adapter until BMF has native
  controller-to-identity binding.
- Health, position, pawn, role-effect reads, whisper delivery, join/leave
  events, avatar mutation, and tool policy require `L3 Live Player` or higher.

Omegga player sync was live-tested after a full Omegga restart on June 4, 2026.
The active Windows runtime populated `runtime/players.json` with one player
from `source=omegga.players.raw.interval.log-fallback`.

## Fixtures

Source fixtures live in `tests/fixtures/players/`.

- `empty.json`: expected output for a headless server with no players.
- `one-player.json`: synthetic complete record for wrapper tests.
- `malformed.json`: invalid and partial records for hardening tests.

Run:

```powershell
.\scripts\validate-player-fixtures.ps1
```

The validator writes a canary JSON when `-OutJson` is supplied.
