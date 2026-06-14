# Resource Lookup Tags

Use lookup tags when a gameplay script needs a stable in-world brick identity
without exposing Brickadia's live runtime brick ids. The tag is authored in
game, while BMF resolves and caches the current runtime brick id internally.

## In-Game Setup

Add an Interactable component to the brick that should represent the gameplay
target, then set **Advanced -> Print To Console** to:

```text
lookup:<uuid>:<purpose>
```

For CityRPG resources, use:

```text
lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut
lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
```

Use the same UUID on every brick that belongs to the same multi-brick resource
node. Use different UUIDs for different trees, rocks, doors, props, puzzle
parts, or other logical targets. BMF treats the `purpose` segment as opaque;
CityRPG currently gives meaning to `treecut` and `mine`.

Do not author `brickid:` tags. Runtime brick ids are process-local cache values
and can change after reloads, restarts, or world edits.

## Lua Examples

Hide a tagged resource and remove collision:

```lua
local tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine"

local hidden = BMF.bricks.setRuntimeStateByGuid({
  tag = tag,
  visible = false,
  collision = 0,
  confirm = "brick-runtime",
})
```

Restore visibility and the captured collision mask:

```lua
local restored = BMF.bricks.setRuntimeStateByGuid({
  tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine",
  visible = true,
  collision = "restore",
  confirm = "brick-runtime",
})
```

Change only visibility:

```lua
BMF.bricks.setRuntimeStateByGuid({
  uuid = "222fd538-01c1-457c-9f67-aaab9fe6bbfd",
  purpose = "treecut",
  visible = false,
  collision = "unchanged",
  confirm = "brick-runtime",
})
```

Change only collision:

```lua
BMF.bricks.setRuntimeStateByGuid({
  tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut",
  visible = "unchanged",
  collision = 0,
  confirm = "brick-runtime",
})
```

The equivalent bridge command shape is:

```text
Omegga.Bridge.BMF bmf.bricks.runtime.set-guid tag=lookup:<uuid>:<purpose> visible=false collision=0 confirm=brick-runtime
Omegga.Bridge.BMF bmf.bricks.runtime.set-guid uuid=<uuid> purpose=<purpose> visible=true collision=restore confirm=brick-runtime
```

## Lookup Rules

- `lookup:<uuid>:<purpose>` is the canonical tag format for new scripts.
- `uuid=<uuid> purpose=<purpose>` and `tag=lookup:<uuid>:<purpose>` resolve to
  the same internal GUID.
- GUID/tag-only mutation uses existing bindings, explicit `x/y/z`, or cached
  exact `ConsoleTag` hits. It does not perform broad world scans.
- Use `BMF.bricks.runtimeStateStatus()` or `bmf.bricks.runtime.status` to wait
  for the queued mutation result before retrying.
- Keep runtime mutation behind the gates documented in
  [Runtime Brick State](../api/runtime-bricks.md).

## CityRPG Compatibility

CityRPG still accepts legacy `treeid:<uuid>`, `choptree:<uuid>`, and
`mineid:<uuid>` aliases while existing worlds are migrated. New builds should
use `lookup:<uuid>:treecut` for trees and `lookup:<uuid>:mine` for mining
nodes.
