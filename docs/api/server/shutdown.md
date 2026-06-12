# Server Shutdown

`BMF.server.shutdown(options)` attempts a graceful `exit` console command after
an explicit confirmation token.

**Labels:** `restricted`, `experimental`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Server operators should use this page before wiring BMF into validation-server
shutdown automation. Plugin authors should avoid this surface unless they are
building trusted admin workflows.

## Contract

This is intended for disposable validation servers and trusted admin
automation, but the current CL13530 executor path reports
`SHUTDOWN_UNAVAILABLE` instead of stopping the process.

!!! warning
    This is not a proven production restart primitive. Use it only for trusted
    automation, and keep an external supervisor such as Omegga or a service
    manager responsible for actual process lifecycle.

```lua
BMF.server.shutdown({
  confirm = "BMF_SHUTDOWN",
  reason = "nightly-canary-complete",
  delayMs = 1500,
})
```

Without `confirm = "BMF_SHUTDOWN"`, the function returns
`CONFIRMATION_REQUIRED` and does not attempt shutdown. On the current runtime,
the confirmed path records `server.shutdown.executed` with
`CONSOLE_EXEC_FAILED` and returns `SHUTDOWN_UNAVAILABLE`.

Plugins must declare `server.shutdown`, and `Mods/BMF/config.json` must opt in
with `allowPluginServerShutdown: true`; otherwise scoped plugin calls return
`CAPABILITY_REQUIRED` or `CONFIG_OPT_IN_REQUIRED`.

The `bmf.server.shutdown` command exposes the same guarded path:

```text
Omegga.Bridge.BMF bmf.server.shutdown confirm=BMF_SHUTDOWN delayms=1500 reason=maintenance
```

Actual stop/restart is not claimed yet. A true stop/restart still requires an
external supervisor such as Omegga, a service manager, or a future BMF companion
process.

## Validation

Current shutdown proof is tracked in
[API Validation Evidence](../../validation/api-validation.md#server).
