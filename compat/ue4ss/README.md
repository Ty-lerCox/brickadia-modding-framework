# UE4SS Compatibility Package Boundary

This package owns the UE4SS compatibility component in the unified runtime
manifest while preserving the current authoritative compatibility manifest:

```text
manifests/compatibility.json
```

The current BMF Windows target is Brickadia `PC-Shipping-CL13530` with the
server executable `BrickadiaServer-Win64-Shipping.exe`. Runtime files still
stage from the existing `framework/ue4ss/Mods/*` paths until a dedicated UE4SS
bundle layout lands under `compat/ue4ss`.

Validation: `scripts/validate-ue4ss-compat-package.ps1`.
