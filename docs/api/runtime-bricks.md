# Runtime Brick State API

Runtime brick state commands are experimental native controls for live brick
visibility/collision. Scripter-facing integrations should pass a UUID plus a
purpose, or a canonical lookup tag such as `lookup:<uuid>:mine`, and let BMF
bind a bounded lookup result to that opaque GUID. BMF does not assign gameplay
meaning to the purpose segment; gameplay layers decide whether it represents a
resource node, prop, puzzle part, or anything else.

For high-level `ConsoleTag` lookup flow, see
[Resource Lookup Tags](../guides/resource-lookup-tags.md) and
[Brick Lookup With ConsoleTag](../architecture/architecture-patterns.md#7-brick-lookup-with-consoletag).
**Labels:** `experimental`, `unsafe-native`, `L2 Headless`, `L6 required`

## Who Should Read This?

BMF maintainers and gameplay integrators should use this page before touching
runtime brick visibility or collision. Server operators should treat it as an
experimental feature-gated path, not a general admin tool.

## When To Use

Use this API when the caller has a resource UUID/purpose, a previously bound
GUID, an explicit nearby resolve position, or a `ConsoleTag` that is already
present in BMF's bounded native target cache. Explicit live runtime brick ids
are supported for diagnostics and internal cache handoff, but they should not
be the public contract exposed to gameplay scripters.

BMF never performs broad world discovery from a GUID. UUID-first calls use the
canonical tag `lookup:<uuid>:<purpose>` and only consult existing bindings,
explicit positions, or the cached native target list before running the bounded
runtime-id resolver.

Cold native runtime-id resolve is disabled by default and requires both
`BMF_BRICK_RUNTIME_RESOLVE_ENABLED=1` and
`BMF_BRICK_RUNTIME_RESOLVE_UNSAFE_NATIVE_ENABLED=1`. The second flag is
intentional friction: the live array resolver has stalled server-side validation
runs, so enable it only in isolated validation sessions.

## In-Game ConsoleTag Contract

Author gameplay targets in Brickadia with an Interactable component and set
**Advanced -> Print To Console** to the canonical lookup tag:

```text
lookup:<uuid>:<purpose>
```

CityRPG currently uses:

```text
lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut
lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
```

Use one UUID for one logical target. A custom multi-brick tree or rock can put
the same lookup tag on every participating brick so the gameplay layer treats
all hits as the same resource node. BMF treats `purpose` as an opaque string;
CityRPG owns meanings such as `treecut` and `mine`.

## Lua API

Runnable example:
[RuntimeBrickState](../examples/runtime-brick-state.md)

The public Lua surface is:

```lua
local hiddenByUuid = BMF.bricks.setRuntimeStateByGuid({
  uuid = "222fd538-01c1-457c-9f67-aaab9fe6bbfd",
  purpose = "mine",
  visible = false,
  collision = 0,
  confirm = "brick-runtime",
})

local restoredByTag = BMF.bricks.setRuntimeStateByGuid({
  tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine",
  visible = true,
  collision = "unchanged",
  confirm = "brick-runtime",
})

local visibilityOnly = BMF.bricks.setRuntimeStateByGuid({
  tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut",
  visible = false,
  collision = "unchanged",
  confirm = "brick-runtime",
})

local collisionOnly = BMF.bricks.setRuntimeStateByGuid({
  uuid = "222fd538-01c1-457c-9f67-aaab9fe6bbfd",
  purpose = "treecut",
  visible = "unchanged",
  collision = 0,
  confirm = "brick-runtime",
})

local boundByUuid = BMF.bricks.bindRuntimeGuid({
  uuid = "222fd538-01c1-457c-9f67-aaab9fe6bbfd",
  purpose = "mine",
  x = 12345,
  y = 67890,
  z = 512,
})

local diagnosticExplicitId = BMF.bricks.setRuntimeState({
  brickid = 56357,
  guid = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine",
  visible = false,
  collision = 0,
  confirm = "brick-runtime",
})
```

`BMF.bricks.setRuntimeState`, `BMF.bricks.bindRuntimeGuid`, and
`BMF.bricks.setRuntimeStateByGuid` are labeled experimental and
capability-gated as `bricks.runtimeState`. Mutation calls are also
`unsafe-native`.

## Server-Console Commands

```text
bmf.bricks.runtime.set-guid uuid=<uuid> purpose=<purpose> confirm=brick-runtime [visible=true|false|restore|unchanged] [collision=<0-255>|unchanged]
bmf.bricks.runtime.set-guid tag=lookup:<uuid>:<purpose> confirm=brick-runtime [visible=true|false|restore|unchanged] [collision=<0-255>|unchanged]
```

Queues visibility/collision mutation for every runtime brick currently bound to
the lookup GUID. If no binding exists, BMF attempts only enabled lookup paths.
The cold native array resolver is validation-only and fails fast unless the
unsafe native resolve flag is explicitly enabled.

Common examples:

```text
bmf.bricks.runtime.set-guid tag=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut visible=false collision=0 confirm=brick-runtime
bmf.bricks.runtime.set-guid tag=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut visible=true collision=unchanged confirm=brick-runtime
bmf.bricks.runtime.set-guid uuid=222fd538-01c1-457c-9f67-aaab9fe6bbfd purpose=mine visible=false collision=unchanged confirm=brick-runtime
bmf.bricks.runtime.set-guid uuid=222fd538-01c1-457c-9f67-aaab9fe6bbfd purpose=mine visible=unchanged collision=0 confirm=brick-runtime
```

```text
bmf.bricks.runtime.bind uuid=<uuid> purpose=<purpose> [x=<x> y=<y> z=<z>]
bmf.bricks.runtime.bind tag=lookup:<uuid>:<purpose> [x=<x> y=<y> z=<z>]
```

Binds one bounded lookup result to an opaque GUID. This is an in-memory runtime
cache, not persistent world state.

```text
bmf.bricks.runtime.set [uuid=<uuid> purpose=<purpose>|tag=lookup:<uuid>:<purpose>|guid=<opaque-id>] confirm=brick-runtime [visible=true|false|restore|unchanged] [collision=<0-255>|unchanged]
```

Queues a visibility/collision mutation through the UUID/GUID path. BMF attempts
existing bindings, explicit `x/y/z`, or a cached exact `ConsoleTag` lookup.

`collision=restore` is rejected unless
`BMF_BRICK_RUNTIME_COLLISION_RESTORE_ENABLED=1` is set. Keep captured collision
restore disabled in normal gameplay until it has been live-validated against
the current Brickadia build; prefer `collision=unchanged` on visibility restore
or an explicit numeric collision value after validation.

```text
bmf.bricks.runtime.resolve guid=<opaque-id> x=<x> y=<y> z=<z> radius=<n> maxscan=<n> [hint=<slot>] [hintwindow=<n>] [hintonly=true]
```

Queues a bounded runtime-id resolve near one world position. When `guid` is
supplied and the resolve succeeds, BMF binds the resolved runtime id to that
GUID. This command fails fast with `BRICK_RUNTIME_RESOLVE_UNSAFE_DISABLED`
unless `BMF_BRICK_RUNTIME_RESOLVE_UNSAFE_NATIVE_ENABLED=1` is set in addition
to `BMF_BRICK_RUNTIME_RESOLVE_ENABLED=1`.

```text
bmf.bricks.runtime.scan-region guid=<opaque-id> x=<x> y=<y> z=<z> ex=<n> ey=<n> ez=<n> maxscan=<n> limit=<n> maxms=<n> confirm=brick-runtime-region
```

Queues a read-only active runtime brick scan inside one box region. This exists
only as a diagnostic over runtime-local brick fields. Current CL13530 live
validation showed these coordinates are not the same world-space coordinates
used by `Bricks.ClearRegion`, so this command must not be used as a destructive
world-edit safety proof unless a future world-transform decoder proves the
mapping. Use a world-space save snapshot/BRDB proof before `Bricks.ClearRegion`.
It is disabled unless `BMF_BRICK_RUNTIME_REGION_SCAN_ENABLED=1` is set.

```text
bmf.bricks.world.scan-region key=<lookup-id-or-legacy-tree-key> x=<x> y=<y> z=<z> ex=<n> ey=<n> ez=<n> confirm=brick-world-region
```

Queues a bounded world-space proof for destructive region edits. BMF issues one
`Bricks.SaveRegion`, waits for the generated `.brs`, parses it with `brs-js`,
and stores a `world-scan-region` result in `bmf.bricks.runtime.status`. The
result is ClearRegion-safe only when `ok=true`, `coordinate_space=world`,
`clear_region_safe=true`, `exact_target_only=true`, and `expected_key` matches
the caller's target key. This command is disabled unless
`BMF_BRICK_WORLD_REGION_SCAN_ENABLED=1` is set and the Builds directory is
configured with `BMF_BRICK_WORLD_REGION_SCAN_BUILDS_DIR` or
`BMF_BRICKADIA_BUILDS_DIR`.

### Validated ClearRegion Contract

BMF supports `Bricks.ClearRegion` as a caller action only after a successful
world-region proof. The safe flow is:

1. The caller computes one intended world-space center and extent for the target
   tree key.
2. The caller queues `bmf.bricks.world.scan-region ... confirm=brick-world-region`.
3. The caller polls `bmf.bricks.runtime.status` for the returned `sequence`.
4. The caller may issue `Bricks.ClearRegion` for the same center and extent only
   when the matching status output contains:

```text
ok=true
coordinate_space=world
clear_region_safe=true
exact_target_only=true
expected_key=<target tree key>
target_bricks>=1
untagged_bricks=0
```

Any missing response, timeout, mismatched `sequence`, mismatched `expected_key`,
non-world coordinate space, extra observed key, untagged brick, or `ok=false`
result is a hard denial. Callers must leave the region intact and retry later or
fall back to a non-destructive path.

Do not substitute `bmf.bricks.runtime.scan-region` for this proof. That command
inspects runtime-local brick fields and CL13530 live validation showed those
coordinates do not match the world-space coordinates consumed by
`Bricks.ClearRegion`.

Live validation on June 23, 2026 used the `lookup:1234:treecut` tree at
`36650,44740,362`: extent `24,24,64` proved exactly one tagged tree brick, while
extent `48,48,128` failed because it included 47 untagged bricks. The caller
then issued `ClearRegion` and a follow-up exact `SaveRegion` probe returned
`WORLD_REGION_SAVE_FILE_TIMEOUT`; treat that post-delete timeout as a fail-closed
"no proof file was produced" signal, not as a reusable empty-region proof.

```text
bmf.bricks.runtime.inspect brickid=<id> [guid=<opaque-id>] [tag=<opaque-tag>]
bmf.bricks.runtime.set brickid=<id> [guid=<opaque-id>] confirm=brick-runtime [visible=true|false|restore|unchanged] [collision=<0-255>|unchanged]
bmf.bricks.runtime.bind guid=<opaque-id> brickid=<id>
bmf.bricks.runtime.bind guid=<opaque-id> brickids=<id,id,...>
```

These explicit `brickid` forms are for internal runtime caches and diagnostics.
Do not expose them as a gameplay scripting contract; runtime ids are process
local and can change after reloads.

```text
bmf.bricks.runtime.guid-status [guid=<opaque-id>]
```

Prints GUID binding state.

```text
bmf.bricks.runtime.status
```

Prints the last queued runtime brick-state result. Use `sequence`, `brick_id`,
`guid`, and optional `tag` to correlate status output with a queued inspect/set
command.

## Required Gates

```text
BMF_BRICK_RUNTIME_SET_ENABLED=1
BMF_BRICK_RUNTIME_RESOLVE_ENABLED=1     validation-only runtime-id resolving gate
BMF_BRICK_RUNTIME_RESOLVE_UNSAFE_NATIVE_ENABLED=1  second validation-only gate required for native array resolve
BMF_BRICK_RUNTIME_RESOLVE_SCAN_MAX_MS=75 hard cap for normal slot scans
BMF_BRICK_RUNTIME_RESOLVE_DIRECT_ARRAY_MAX_MS=75 hard cap for sparse direct-array scans
BMF_BRICK_RUNTIME_REGION_SCAN_ENABLED=1 explicit gate for diagnostic runtime-local region scans
BMF_BRICK_RUNTIME_REGION_SCAN_MAX_SCAN=4000000 max runtime slots for diagnostic region scans
BMF_BRICK_RUNTIME_REGION_SCAN_LIMIT=512 max returned matches before fail-closed truncation
BMF_BRICK_RUNTIME_REGION_SCAN_MAX_MS=750 native time budget for diagnostic region scans
BMF_BRICK_WORLD_REGION_SCAN_ENABLED=1 explicit gate for world-space SaveRegion proof scans
BMF_BRICK_WORLD_REGION_SCAN_BUILDS_DIR=<path> Builds directory where Bricks.SaveRegion writes .brs files
BMF_BRICK_WORLD_REGION_SCAN_TIMEOUT_MS=5000 max wait for the proof .brs file after SaveRegion
BMF_BRICK_WORLD_REGION_SCAN_MAX_EXTENT=128 max X/Y proof extent accepted by BMF
BMF_BRICK_WORLD_REGION_SCAN_MAX_EXTENT_Z=256 max Z proof extent accepted by BMF
BMF_BRS_JS_MODULE_DIR=<path> node_modules directory containing brs-js for proof parsing
BMF_BRICK_RUNTIME_LOOKUP_ENABLED=1     only with a verified live runtime id
BMF_BRICK_VISIBILITY_SET_ENABLED=1      required for visible=...
BMF_BRICK_COLLISION_SET_ENABLED=1       required for collision=...
BMF_BRICK_VISIBILITY_DIRECT_WRITE_ENABLED=1  optional fallback when no grid context is available
BMF_BRICK_COLLISION_DIRECT_WRITE_ENABLED=1   optional fallback when no grid context is available
BMF_BRICK_CONTEXT_BACKGROUND_SCAN_ENABLED=1  optional cold-start resolver
BMF_BRICK_RUNTIME_SCAN_BEFORE_DIRECT_WRITE_ENABLED=1  optionally defer direct writes while the background resolver runs
BMF_BRICK_CONTEXT_SCAN_MAX_MS=3000      time budget for native context scans
BMF_BRICK_CONTEXT_HINT_FULL_FALLBACK_ENABLED=0  keep background scans near owner hints
BMF_BRICK_GRID_CONTEXT_CACHE_TTL_MS=300000   max sparse-grid context cache age
BMF_BRICK_OWNER_CONTEXT_SCAN_FOR_SET_ENABLED=1  optionally try the bounded owner scan before direct fallback
BMF_BRICK_RUNTIME_GUID_MAX_BRICKS=64          max runtime ids bound to one GUID
BMF_BRICK_RUNTIME_GUID_CACHE_MAX_GUIDS=1024   max GUID bindings retained in memory
BMF_RESOURCE_TARGET_AUTO_REFRESH=1            optional startup target-cache refresh; lookup reads the cache only
BMF_TREECUT_TARGET_AUTO_REFRESH=1             compatibility alias for the same cache refresh path
```

Set `BMF_BRICK_RUNTIME_DIAGNOSTICS_ENABLED=1` only when owner or sparse-grid
pointer diagnostics are needed. Those fields chase volatile native pointers and
are not always safe to read.

## Caller Rules

- Prefer `uuid=<uuid> purpose=<purpose>` or `tag=lookup:<uuid>:<purpose>` for
  scripter-facing resource APIs. BMF canonicalizes `uuid + purpose` into the
  lookup tag and uses that as the opaque GUID.
- Treat `guid=<opaque-id>` as a generic gameplay identifier. BMF does not attach
  CityRPG meaning to purposes such as `treecut` or `mine`.
- GUID/tag-only mutations are allowed, but they only use existing bindings,
  explicit `x/y/z`, or the native target cache. They do not scan the world.
- When no binding, position, or cached exact tag is available, the queued result
  returns `BRICK_RUNTIME_GUID_LOOKUP_MISS`.
- Do not assume saved BRS `brickIndex` or `brickId` values are live runtime ids
  unless a runtime probe has confirmed them in the active server process.
- Keep `BMF_BRICK_RUNTIME_LOOKUP_ENABLED=0` for saved indices.
- Wait for the matching `sequence` in `bmf.bricks.runtime.status` before
  retrying a queued mutation.
- Keep cached sparse-grid context bounded. The default
  `BMF_BRICK_GRID_CONTEXT_CACHE_TTL_MS=300000` keeps gameplay retries reliable
  while still preventing long-running servers from reusing stale native context
  pointers indefinitely.
- Keep hint-seeded background scans bounded. For gameplay, leave
  `BMF_BRICK_CONTEXT_HINT_FULL_FALLBACK_ENABLED=0` so a near-hint miss does not
  fall into a process-wide scan.
- Use direct owner-context scan for explicit runtime-id gameplay setters only
  when the target count is bounded. If no fresh cached context is available and
  no direct byte-write fallback is enabled, let the setter return
  `BRICK_GRID_CONTEXT_SCAN_PENDING` and retry after the background scan primes
  the cache.
- Retry only after a completed `BRICK_GRID_CONTEXT_SCAN_PENDING` result, and
  keep retries low-frequency.
- Enable direct byte-write gates only for narrow, explicit runtime-id workflows
  that have live validation coverage. When those gates are enabled, BMF still
  prefers Brickadia's setter if a plausible grid context is available. With
  `BMF_BRICK_RUNTIME_SCAN_BEFORE_DIRECT_WRITE_ENABLED=1`, BMF defers the direct
  write while the bounded background scan runs, then falls back to known runtime
  visibility/collision bytes only after that scan fails for the same brick cell.

## Native Validation

Native validation rejects candidates whose internal runtime id field is
unreadable or does not match the requested id:

- `BRICK_ID_UNAVAILABLE`
- `BRICK_ID_MISMATCH`

The setter path also needs a plausible sparse-grid context. BMF tries cached or
hook-captured context first, then bounded fallback work, then the optional
off-game-thread background resolver.

## Result Shape

Successful commands include the requested brick id or GUID, optional tag, queued
`sequence`, and current state fields when available. Pending context scans
return `BRICK_GRID_CONTEXT_SCAN_PENDING`; callers should wait for the matching
status sequence before retrying.

!!! danger
    This API crosses into native runtime brick state. Keep it behind explicit
    feature flags and capture `L6 Frame Time` evidence before using it in
    gameplay systems. Enabling lookup for an unverified saved index can crash
    the dedicated server before BMF can return a status response.
