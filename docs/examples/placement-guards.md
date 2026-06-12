# Placement Guards

The placement guard examples are full policy plugins. They are documented as
runnable workflows instead of inline snippets because each guard combines
configuration, player policy, chat feedback, and native or hook-backed
validation.

**Maturity:** `Policy workflow`, `Experimental/native`
**Required capabilities:** Varies by guard.

Runnable sources:

- [examples/NoSpawnItemApplicator](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/NoSpawnItemApplicator): blocks configured applicator components.
- [examples/InteractConsolePrefixGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/InteractConsolePrefixGuard): restricts Interactable console tag prefixes.
- [examples/BrickAssetPlacementGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/examples/BrickAssetPlacementGuard): blocks configured placement assets and indexed prefab hashes.

The common command pattern for these policy examples is:

```lua
BMF.commands.register("bmf.guard.status", "Show guard status.", function()
  return BMF.result(true, "OK", "Guard status", {
    lines = {
      "policy=example",
      "enforcement=policy-ready",
    },
  })
end)
```

!!! warning
    Treat these as architecture and validation examples first. Live enforcement
    depends on the current supported runtime and the specific native hook path
    documented by the matching API page.
