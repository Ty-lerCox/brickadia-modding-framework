# Players API

BMF player APIs use safe normalized records. In the current supported Windows
runtime, player identity should come from BMF-compatible Omegga player sync and
Brickadia saved/log context, not direct live `PlayerState` property reads.

**Labels:** `experimental`, `live-player`, `L2 Headless`, `L3 pending`

## Who Should Read This?

Plugin authors should start here before looking up players, sending player
summaries, or consuming Omegga player sync data. Maintainers should use the
child pages when changing identity ingestion, normalization, lookup, or live
player validation.

## Page Map

| Page | Use it for |
| --- | --- |
| [Identity Sources](players/identity-sources.md) | Safe player caches, Omegga sync, Brickadia logs, and `BMF.players.list()`. |
| [Normalize And Lookup](players/normalize-and-lookup.md) | `normalize`, `normalizeList`, `find`, `resolve`, and `getName`. |
| [Summaries And Messaging](players/summaries-and-messaging.md) | `summary` and `whisperSummary`. |
| [Fixtures And Validation](players/fixtures-and-validation.md) | Validation levels, player fixtures, and live-player caveats. |

## Examples

- [PlayerSummary](../examples/player-summary.md): complete plugin that lists
  known players and logs normalized display names.

## Safe Identity Rule

Configure `brickadiaSavedDir` so BMF can read Brickadia's own
`Saved/Logs/Brickadia.log` plus `Saved/Server/PlayerNameCache.json`, and run
the Omegga player sync adapter so `runtime/players.json` stays populated.

!!! warning
    Player identity should come from Omegga sync and Brickadia saved/log context
    until BMF has a proven native identity path. Avoid direct live
    `PlayerState` property reads in plugin code.
