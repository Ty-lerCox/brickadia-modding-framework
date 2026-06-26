# BMFSocket Package Boundary

This package owns the BMFSocket component in the unified runtime manifest. The
current source remains split between the C++ helper source and the deployable
UE4SS mod folder:

```text
native/bmf_socket
framework/ue4ss/Mods/BMFSocket
```

The boundary manifest records both roots, the native build script, the expected
runtime DLL entrypoint, and the transport requirement: live BMF/Omegga traffic
uses BMFSocket. When BMFSocket is absent, Desktop and Omegga integrations must
report the socket path as unavailable instead of treating JSONL or command files
as the live transport.

Validation: `scripts/validate-bmf-runtime-packages.ps1`.
