# Timers API

BMF timers schedule callbacks on the server runtime without requiring a player.

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

- `L0 Static`: package validator checks timer API markers, docs, and canary.
- `L2 Headless`: `scripts/validate-bmf-timers.ps1` loads a temporary plugin,
  verifies `after`, `every`, cancellation, and timer logging without a connected
  player.
