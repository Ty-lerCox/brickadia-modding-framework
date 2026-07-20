# Placement Guards

The managed placement guards are full policy plugins. They are documented as
runnable workflows instead of inline snippets because each guard combines
configuration, player policy, chat feedback, and native or hook-backed
validation.

**Maturity:** `Policy workflow`, `Experimental/native`
**Required capabilities:** Varies by guard.

Managed sources:

- [NoSpawnItemApplicator](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/framework/ue4ss/Mods/BMF/plugins/NoSpawnItemApplicator): blocks configured applicator components.
- [InteractConsolePrefixGuard](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/framework/ue4ss/Mods/BMF/plugins/InteractConsolePrefixGuard): restricts Interactable console tag prefixes.

`BrickAssetPlacementGuard` is retained under
[`deprecated/plugins/BrickAssetPlacementGuard`](https://github.com/Ty-lerCox/brickadia-modding-framework/tree/main/deprecated/plugins/BrickAssetPlacementGuard)
for historical validation only. Brickadia's built-in placement permissions are
the supported replacement.

The common command pattern for these policy plugins is:

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
