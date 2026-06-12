# World API

**Labels:** `experimental`, `L2 Headless`, `L3 pending`

## Who Should Read This?

Plugin authors should use this page for staged world loads and SaveAs snapshots. Maintainers should use it when changing command-backed world wrappers or canaries.

The first BMF world API wraps Brickadia console commands that have local
headless evidence on CL13530.

## Examples

- [LoadThreeCars](../examples/load-three-cars.md): complete plugin that
  loads a staged world bundle and saves the result.

## `BMF.world.loadAdditive(options)`

Loads a staged `.brdb` world additively.

```lua
BMF.world.loadAdditive({
  name = "BMF_ThreeCarsFixture",
  position = { x = 20000, y = 0, z = 1000 },
  yaw = 0,
})
```

Accepted aliases:

- `name`, `bundle`, or `world` for the staged world name.
- `x`, `y`, `z`, `yaw` as top-level numeric fields.
- `position = { x, y, z }`.

The wrapper strips a trailing `.brdb`, rejects path separators, and records the
exact console command in the result data. On the current Windows bridge it uses
the console-manager executor because that is the proven path for `BR.World.*`
commands.

Validation proof is tracked in
[API Validation Evidence](../validation/api-validation.md#archives-vehicles-and-prefabs).

## `BMF.world.saveAs(name)`

Saves the current world to a new `.brdb`.

```lua
BMF.world.saveAs("BMF_AfterThreeCarsAdditive")
```

The same wrapper is exposed to unattended bridge tests through the BMF command
worker:

```text
Omegga.Bridge.BMF bmf.world.saveas name=BMF_AfterThreeCarsAdditive
```

Save proof is tracked in
[API Validation Evidence](../validation/api-validation.md#archives-vehicles-and-prefabs).

## Notes

Use BMF-owned names beginning with `BMF_` for automated tests. Do not overwrite
user-authored worlds during canaries.

`BR.World.SaveAs` may log `Failed to capture minigame settings` on a clean
headless plate world and still save world files. BMF world canaries should treat
that warning as non-fatal unless the test specifically covers minigame
persistence.
