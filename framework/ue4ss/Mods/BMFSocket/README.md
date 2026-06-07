# BMFSocket

BMFSocket is the optional UE4SS C++ transport mod for BMF. Build it with:

```powershell
.\scripts\build-bmf-socket-native-mod.ps1 -Deploy
```

The deployed runtime DLL must exist at `framework/ue4ss/Mods/BMFSocket/dlls/main.dll` before Omegga enables this mod in a managed server install. If the DLL is absent, BMF falls back to the file-backed command and event bridge.
