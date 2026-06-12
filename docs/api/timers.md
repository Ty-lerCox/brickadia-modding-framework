# Timers API

**Labels:** `stable`, `L2 Headless`

## Who Should Read This?

Plugin authors should use this page for delayed and recurring tasks. Maintainers should use it when changing lifecycle timer behavior.

BMF timers schedule callbacks on the server runtime without requiring a player.

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

Runs `callback` once after `ms`.

## `BMF.timers.every(ms, callback)`

Runs `callback(id, count)` repeatedly every `ms` until cancelled.

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

## `BMF.timers.activeCount()`

Returns the current number of scheduled timer records.

## Validation

Timer proof is tracked in
[API Validation Evidence](../validation/api-validation.md#framework-utilities).
