# Timers API

**Labels:** `stable`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page for delayed and recurring tasks. Maintainers should use it when changing lifecycle timer behavior.

BMF timers schedule callbacks on the server runtime without requiring a player.
Timer callbacks execute only on the game thread. BMF does not use
`ExecuteWithDelay`, `ExecuteAsync`, or `LoopAsync` for timer callbacks.

The runtime bounds active timers per owner and process, retains at most one
outstanding callback for each timer, and caps all retained scheduler callbacks.
A native game-thread due action only enqueues the timer ID; one shared bounded
dispatcher invokes plugin callbacks. The dispatcher runs at most 16 callbacks,
at most 4 for any one owner, inspects at most 64 queue entries, and stops after
4 ms of measured callback work per frame. Excess due work remains queued and is
reported as deferred telemetry.
A recurring timer schedules its next callback only after the current callback
returns, so it cannot build a catch-up burst. Cadence is game-thread/frame
quantized and must not be treated as a real-time deadline.

## Examples

- [TimedBroadcast](../examples/timed-broadcast.md): complete plugin that
  schedules a delayed chat broadcast.

```lua
local id = BMF.timers.after(1000, function()
  BMF.log("one second passed")
end)

BMF.timers.cancel(id)
```

## `BMF.timers.after(ms, callback)`

Runs `callback` once after at least `ms`, subject to game-thread scheduling and
the retained-callback limits.

## `BMF.timers.every(ms, callback)`

Runs `callback(id, count)` repeatedly every `ms` until cancelled. Recurrence is
scheduled after the preceding invocation, so a slow callback does not create a
catch-up burst.

```lua
local timer_id
timer_id = BMF.timers.every(1000, function(id, count)
  BMF.log("tick " .. tostring(count))
  if count >= 5 then
    BMF.timers.cancel(id)
  end
end)
```

## `BMF.timers.cancel(id)`

Cancels a scheduled one-shot or recurring timer. Returns `true` if the timer was
known when cancellation was requested.

Plugin timers are associated with the loaded plugin instance that created them.
BMF cancels that owner's remaining timers during unload or reload, so callbacks
from an old plugin generation cannot execute against the replacement instance.
Plugins should still cancel timers as soon as they are no longer needed.

## `BMF.timers.activeCount()`

For a plugin, returns that plugin's current timer count. Framework callers see
the process-wide timer count.

Current hard guardrails are 128 active timers per owner, 1,024 active timers
process-wide, a 16 ms minimum recurring interval, and 4,096 retained callbacks
per scheduler class. These are safety ceilings, not recommended operating
targets; normal plugins should use only a small handful of timers.

## Callback Guardrails

- Keep callbacks short and bounded; defer analytics and bulk parsing to an
  external producer.
- Do not scan directories, read large files, enumerate broad UObject sets, or
  loop over an unbounded player collection in a timer callback.
- Prefer one shared producer/cache over several plugin-specific timers.
- Record callback duration, owner, queue depth, and deferred work for frequent
  timers.
- A missing game-thread scheduler is an error. Timers must fail closed instead
  of falling back to an async Lua scheduler.

## Validation

Timer proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
