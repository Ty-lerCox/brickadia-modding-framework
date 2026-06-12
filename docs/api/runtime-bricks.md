# Runtime Brick State API

Runtime brick state commands are experimental native controls for one explicit
live runtime brick id. They are useful for canaries and CityRPG tagged-tree
validation, but they are not a general tag resolver.

For high-level `ConsoleTag` lookup flow, see
[Brick Lookup With ConsoleTag](../architecture/architecture-patterns.md#7-brick-lookup-with-consoletag).
For tree-cut usage, see
[CityRPG Native Tree Cutting](../architecture/architecture-patterns.md#9-cityrpg-native-tree-cutting).

**Labels:** `experimental`, `unsafe-native`, `L2 Headless`, `L6 required`

## Who Should Read This?

BMF maintainers and gameplay integrators should use this page before touching
runtime brick visibility or collision. Server operators should treat it as an
experimental feature-gated path, not a general admin tool.

## When To Use

Use this API only when the caller already has a plausible live runtime brick id
candidate and needs to inspect or mutate visibility/collision under explicit
feature gates.

Do not use it to mutate by tag alone. `tag=<treeid:...>` is correlation metadata
for `ConsoleTag`-backed systems, not a replacement for `brickid`.

## Lua API

The public Lua surface is:

```lua
local inspected = BMF.bricks.inspectRuntimeState({
  brickid = 56357,
  tag = "treeid:example",
})

local hidden = BMF.bricks.setRuntimeState({
  brickid = 56357,
  tag = "treeid:example",
  visible = false,
  collision = "unchanged",
  confirm = "brick-runtime",
})
```

`BMF.bricks.setRuntimeState` is labeled experimental, `unsafe-native`, and
capability-gated as `bricks.runtimeState`.

## Server-Console Commands

```text
Omegga.Bridge.BMF bmf.bricks.runtime.inspect brickid=<id> [tag=<treeid:...>]
```

Queues a game-thread inspection and reports visible/collision bytes plus native
runtime state. Runtime lookup is disabled unless
`BMF_BRICK_RUNTIME_LOOKUP_ENABLED=1` is set.

```text
Omegga.Bridge.BMF bmf.bricks.runtime.set brickid=<id> [tag=<treeid:...>] confirm=brick-runtime [visible=true|false|restore|unchanged] [collision=<0-255>|restore|unchanged]
```

Queues a visibility/collision mutation for the explicit candidate id.

```text
Omegga.Bridge.BMF bmf.bricks.runtime.status
```

Prints the last queued runtime brick-state result. Use `sequence`, `brick_id`,
and optional `tag` to correlate status output with a queued inspect/set command.

## Required Gates

```text
BMF_BRICK_RUNTIME_SET_ENABLED=1
BMF_BRICK_RUNTIME_LOOKUP_ENABLED=1     only with a verified live runtime id
BMF_BRICK_VISIBILITY_SET_ENABLED=1      required for visible=...
BMF_BRICK_COLLISION_SET_ENABLED=1       required for collision=...
BMF_BRICK_CONTEXT_BACKGROUND_SCAN_ENABLED=1  optional cold-start resolver
```

Set `BMF_BRICK_RUNTIME_DIAGNOSTICS_ENABLED=1` only when owner or sparse-grid
pointer diagnostics are needed. Those fields chase volatile native pointers and
are not always safe to read.

## Caller Rules

- Always pass a live runtime `brickid` candidate.
- Treat `tag=<treeid:...>` as correlation metadata only.
- Do not send tag-only mutations; they return `BRICK_RUNTIME_TAG_ID_REQUIRED`.
- Do not assume saved BRS `brickIndex` or `brickId` values are live runtime ids
  unless a runtime probe has confirmed them in the active server process.
- Keep `BMF_BRICK_RUNTIME_LOOKUP_ENABLED=0` for saved indices.
- Wait for the matching `sequence` in `bmf.bricks.runtime.status` before
  retrying a queued mutation.
- Retry only after a completed `BRICK_GRID_CONTEXT_SCAN_PENDING` result, and
  keep retries low-frequency.
- Keep direct byte-write gates off for gameplay. They are diagnostic only.

## Native Validation

Native validation rejects candidates whose internal runtime id field is
unreadable or does not match the requested id:

- `BRICK_ID_UNAVAILABLE`
- `BRICK_ID_MISMATCH`

The setter path also needs a plausible sparse-grid context. BMF tries cached or
hook-captured context first, then bounded fallback work, then the optional
off-game-thread background resolver.

## Result Shape

Successful commands include the requested brick id, optional tag, queued
`sequence`, and current state fields when available. Pending context scans
return `BRICK_GRID_CONTEXT_SCAN_PENDING`; callers should wait for the matching
status sequence before retrying.

!!! danger
    This API crosses into native runtime brick state. Keep it behind explicit
    feature flags and capture `L6 Frame Time` evidence before using it in
    gameplay systems. Enabling lookup for an unverified saved index can crash
    the dedicated server before BMF can return a status response.
