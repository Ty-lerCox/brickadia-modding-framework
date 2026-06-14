# Lua Examples

This catalog points to focused Lua examples for each public BMF surface. Use it
to find the smallest pattern that matches the API you are using.

## Who Should Read This?

Plugin authors should use this catalog for copyable patterns and runnable
example folders. API maintainers should use it to check whether a public
surface has a documented example.

## Maturity Labels

| Label | Meaning |
| --- | --- |
| `Copy-paste` | A complete `main.lua` sample that can be copied into a plugin. |
| `Runnable folder` | A matching folder exists under `examples/`. |
| `Policy workflow` | The example models server policy and usually needs config. |
| `Experimental/native` | The workflow touches an experimental native or hook-backed surface. |
| `Validation pattern` | The example is mainly useful for testing framework behavior. |

## Catalog

| API area | Example | Maturity | Required capabilities |
| --- | --- | --- | --- |
| Chat | [HelloBroadcast](hello-broadcast.md) | `Runnable folder` | `chat.broadcast` |
| Timers | [TimedBroadcast](timed-broadcast.md) | `Runnable folder` | `chat.broadcast`, `timers.basic` |
| Commands | [Plugin Command](plugin-command.md) | `Copy-paste` | None |
| Plugins and storage | [Plugin Storage](plugin-storage.md) | `Copy-paste` | `plugins.storage` |
| Server settings | [WelcomeMessage](welcome-message.md) | `Runnable folder` | None |
| World loading | [LoadThreeCars](load-three-cars.md) | `Runnable folder` | `world.loadAdditive`, `world.saveAs` |
| Prefabs | [LoadCarBrz](load-car-brz.md) | `Runnable folder` | `prefabs.loadBrz`, `world.saveAs` |
| Vehicles | [SpawnVehicleSet](spawn-vehicle-set.md) | `Runnable folder` | `vehicles.spawnSet` |
| Minigames | [ListMinigames](list-minigames.md) | `Runnable folder` | None |
| Permissions | [AssignRole](assign-role.md) | `Runnable folder` | None |
| Placement policy | [Placement Guards](placement-guards.md) | `Policy workflow`, `Experimental/native` | Varies by guard |
| Runtime bricks | [RuntimeBrickState](runtime-brick-state.md) | `Runnable folder`, `Experimental/native` | `bricks.runtimeState`; uses `lookup:<uuid>:<purpose>` tags |
| API labels | [InspectApiLabels](inspect-api-labels.md) | `Validation pattern` | None |
| Players | [PlayerSummary](player-summary.md) | `Copy-paste` | None |
| Health and compatibility | [HealthCheck](health-check.md) | `Copy-paste` | None |
| Events and audit | [EventAudit](event-audit.md) | `Copy-paste` | None |
| Rate limits | [RateLimitedCommand](rate-limited-command.md) | `Copy-paste` | None |

## Documentation Standard

Every new API page should link to one focused example page and include:

- the required `bmf.json` capabilities when the API is capability-gated;
- the validation command or built-in BMF command that proves the example works;
- a short note when the example depends on Omegga, live players, or native
  hooks.
