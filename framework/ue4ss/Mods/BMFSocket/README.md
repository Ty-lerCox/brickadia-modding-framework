# BMFSocket

BMFSocket is the optional UE4SS C++ transport mod for BMF. Build it with:

```powershell
.\scripts\build-bmf-socket-native-mod.ps1 -Deploy
```

The deployed runtime DLL must exist at `framework/ue4ss/Mods/BMFSocket/dlls/main.dll` before Omegga enables this mod in a managed server install. If the DLL is absent, BMF Desktop and Omegga adapters must report the socket path as unavailable.

BMFSocket defaults to transport-only mode and registers
`BMFSocketStart`, `BMFSocketStop`,
`BMFSocketSend`, `BMFSocketReceive`, `BMFSocketStatus`, and a bounded read-only
`BMFSocketDescribeUObject` identity check. It also registers the bounded read-only
`BMFSocketDescribePlayerControllerBinding` check used to prove that a live
controller and player state contain the expected player UUID. These checks return
identity and exact-binding evidence only; native scanners, writers, probes, and
hook installers remain unavailable.

On `Release-EA3-CL-15501`, the narrow opt-in
`BMF_SOCKET_GAME_COMMAND_TUNNEL_HELPERS_ENABLED=1` additionally exposes only the
side-effect-free `ServerPushChatMessage` readiness check, the authenticated
implementation-call adapter used by `cityrpg.command.v1`, and the reserved
player-command guard. Each call fails closed unless the server PE identity,
reflected one-`FString` ABI, UFunction exec thunk, implementation signature, and
controller vtable target all match the validated CL15501 layout. It does not
enable unknown-command scanning, brick writers, setters, or unrelated hooks.

Full native helper registration requires the explicit opt-in
`BMF_SOCKET_NATIVE_HELPERS_ENABLED=1` and a validated mapping set.
`BMF_SOCKET_TRANSPORT_ONLY=1` always forces the safe transport-only mode.
