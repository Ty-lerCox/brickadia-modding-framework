# RuntimeBrickState

Shows the generic BMF pattern for changing runtime brick visibility and
collision. The example uses UUID-first lookup bindings as the scripter-facing
path and keeps explicit runtime brick ids as diagnostic commands; it does not
know about trees, mining, or any CityRPG-specific rules.

**Maturity:** `Runnable folder`, `Experimental/native`
**Required capability:** `bricks.runtimeState`

Runnable source:
[examples/RuntimeBrickState](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/RuntimeBrickState)

## In-Game Setup

On the brick you want the script to control, add an Interactable component and
set **Advanced -> Print To Console** to:

```text
lookup:<uuid>:<purpose>
```

For CityRPG resource examples:

```text
lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut
lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
```

Use the same tag on every brick in a multi-brick target. The example plugin
does not know what `treecut` or `mine` means; it simply passes the lookup tag
to BMF.

## Direct Lua Calls

Hide a resource brick by literal lookup tag:

```lua
local hidden = BMF.bricks.setRuntimeStateByGuid({
  tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine",
  visible = false,
  collision = 0,
  confirm = "brick-runtime",
})
```

Restore a resource brick from UUID and purpose without touching collision:

```lua
local restored = BMF.bricks.setRuntimeStateByGuid({
  uuid = "222fd538-01c1-457c-9f67-aaab9fe6bbfd",
  purpose = "mine",
  visible = true,
  collision = "unchanged",
  confirm = "brick-runtime",
})
```

Change only visibility:

```lua
BMF.bricks.setRuntimeStateByGuid({
  tag = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:treecut",
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

Bind a UUID/purpose to a resolved runtime id when a nearby position is known:

```lua
BMF.bricks.bindRuntimeGuid({
  uuid = "222fd538-01c1-457c-9f67-aaab9fe6bbfd",
  purpose = "mine",
  x = 12345,
  y = 67890,
  z = 512,
})
```

Explicit runtime brick ids are diagnostic/runtime-cache values. Use them only
after native inspection has verified the id in the current server process:

```lua
BMF.bricks.setRuntimeState({
  brickid = 56357,
  guid = "lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine",
  visible = false,
  collision = 0,
  confirm = "brick-runtime",
})
```

## Example Commands

After loading the example plugin, invoke these through the BMF command bridge:

```text
bmf.runtimebrick.example.hide-lookup tag=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
bmf.runtimebrick.example.restore-lookup tag=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
bmf.runtimebrick.example.hide-lookup uuid=222fd538-01c1-457c-9f67-aaab9fe6bbfd purpose=mine
bmf.runtimebrick.example.restore-lookup uuid=222fd538-01c1-457c-9f67-aaab9fe6bbfd purpose=mine
bmf.runtimebrick.example.hide-guid guid=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
bmf.runtimebrick.example.restore-guid guid=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
bmf.runtimebrick.example.status tag=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine
bmf.runtimebrick.example.status
```

Diagnostic commands that require a verified runtime id are still available:

```text
bmf.runtimebrick.example.visibility brickid=56357 visible=false
bmf.runtimebrick.example.collision brickid=56357 collision=0
bmf.runtimebrick.example.hide brickid=56357
bmf.runtimebrick.example.restore brickid=56357
bmf.runtimebrick.example.bind guid=lookup:222fd538-01c1-457c-9f67-aaab9fe6bbfd:mine brickids=56357,56358
```

`setRuntimeState` queues game-thread work. Use `bmf.runtimebrick.example.status`
or `bmf.bricks.runtime.status` to inspect the final sequence result before
retrying or issuing the next mutation.

!!! warning
    Runtime brick mutation is an experimental native path. UUID-first lookup
    uses existing bindings, explicit positions, or the native target cache; it
    does not scan the world. Keep calls low-frequency and collect frame-time
    evidence before using it in gameplay loops.

!!! warning
    `collision=restore` is disabled unless
    `BMF_BRICK_RUNTIME_COLLISION_RESTORE_ENABLED=1` is set. Prefer
    `collision=unchanged` when restoring visibility, or use an explicit numeric
    collision value only after live validation for the current server build.
