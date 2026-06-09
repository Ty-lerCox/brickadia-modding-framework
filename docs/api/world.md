# World API

The first BMF world API wraps Brickadia console commands that have local
headless evidence on CL13530.

## Examples

- [LoadThreeCars](../examples/index.md#loadthreecars): complete plugin that
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

Validation:

- `L2 Headless`: `threecars-additive-canary.json` proves command transport,
  additive load log success, SaveAs output, and parsed dynamic actor groups.
- `L3 Live Player`: still needed to prove whether loaded vehicles are drivable.

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

Validation:

- `L2 Headless`: `threecars-additive-canary.json` proves SaveAs wrote a BRDB
  that could be parsed afterward.
- `L2 Headless`: `validate-bmf-vehicle-spawn-set-command.ps1` proves the
  command route can save a world after command-driven vehicle loads.

## Notes

Use BMF-owned names beginning with `BMF_` for automated tests. Do not overwrite
user-authored worlds during canaries.

`BR.World.SaveAs` may log `Failed to capture minigame settings` on a clean
headless plate world and still save world files. BMF world canaries should treat
that warning as non-fatal unless the test specifically covers minigame
persistence.
