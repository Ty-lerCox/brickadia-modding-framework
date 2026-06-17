# Brickadia UE4SS signature notes

Target build:
- Brickadia EA2 (PC-Shipping-CL12960)
- UE 5.5 baseline

Resolved and now shipped via Brickadia custom signature overrides:
- `FName::FName(wchar_t*)`
- `FName::ToString`
- `GUObjectArray`

Still unresolved:
- `FUObjectHashTables::Get()`
- `GNatives`

Useful reverse-engineering findings from the shipping server exe:
- `FUObjectArrayAllocateUObjectIndex` is at `0x1404f79d0`
- `FUObjectArrayFreeUObjectIndex` is at `0x1404f7e80`
- `UObjectBaseShutdown` is at `0x1404f81c0`
- Brickadia does not use the stock `StaticFindObjectFast` resolver string. The relevant UTF-16 strings are:
  - `Illegal call to StaticFindObjectFast() while serializing object data!`
  - `Illegal call to StaticFindObjectFast() while garbage collecting!`
- The string wrapper thunk for the serialize variant is at `0x1404ff710`, and its only caller is `0x1404ff880`
- `0x1404ff880` appears to be a higher-level object lookup helper and calls `0x140535040`, which is a candidate for `StaticFindObjectFast` or a closely related lookup routine

Validation checkpoints:
- UE4SS log now reports `FName::ToString address ... <- Lua Script`
- UE4SS log now reports `GUObjectArray address ... <- Lua Script`
- Validation still fails only on `FUObjectHashTables::Get()` and `GNatives`
