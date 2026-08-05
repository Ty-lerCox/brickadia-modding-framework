# Lua Crash Remediation — 2026-08-02

## Incident

Brickadia exited repeatedly on 2026-08-02. The newest complete crash at 21:04
EDT was an access violation inside Lua string-table garbage collection while
the game thread was draining a BMFSocket native event. The dump also showed
that UE4SS and BMFSocket protected the same Lua heap with different
module-local locks. BMF and OmeggaBridge each had async Lua scheduler paths,
which could enter that heap while game-thread Lua was active.

The immediately preceding 20:10 EDT failure was a GameThread hang with the
same signature as the earlier crashes that day. Taken together, the failures
justify removing cross-thread Lua execution instead of patching individual
gameplay callbacks.

While this remediation was being built, the unmodified live runtime hung again
at 21:52 EDT. Its GameThread stack was another UE4SS delayed action repeatedly
entering Lua `tostring`/`pcall` from `engine_tick_hook`, strengthening the same
execution-domain classification. The automatic recovery then hit a separate
Brickadia networking assertion when a client reconnected during initial world
travel. Evidence for both reports and the following degraded exit is preserved
under `artifacts/crash-forensics/20260802-215305`.

Source review then identified a concrete corruption mechanism in the locally
built UE4SS scheduler. `process_delayed_actions` invoked Lua from inside
`std::erase_if` over the delayed-action vector while holding a recursive mutex.
A callback could register another delayed action through that same mutex,
reallocate the vector, and invalidate the iterator and action reference still
owned by `erase_if`. This is undefined behavior on the exact GameThread path in
both complete crash reports. Delayed-action processing therefore requires a
re-entrancy-safe native queue boundary in addition to the Lua execution-domain
and lifecycle changes below.

## Safety Invariant

After mod startup, every Lua callback executes on the game thread. Native and
Node.js workers may perform byte I/O or other work off-thread only when they do
not retain or enter a Lua state and do not touch UObjects. They publish copied
messages to bounded queues that Lua drains on the game thread.

The runtime must fail closed when no game-thread scheduler is available. It
must never fall back to `ExecuteWithDelay`, `ExecuteAsync`, or `LoopAsync`.

## Remediation Phases

1. Preserve the newest reports, logs, exit record, supervisor events, dumps,
   and hashes before changing the runtime.
2. Refactor UE4SS delayed-action processing so callbacks cannot structurally
   mutate the vector being traversed. Preserve targeted cancellation,
   retrigger, pause/resume, looping, executor selection, and Lua reference
   lifetime semantics across the queue boundary.
3. Make BMF delayed callbacks, workers, socket drains, watchdogs, and plugin
   timers game-thread-only. Bound retained callbacks and active timers.
4. Scope timers to their plugin owner and cancel them during unload, failed
   load, reload, and watchdog isolation. Raw scheduler globals remain outside
   the plugin sandbox even when other unsafe globals are opted in.
5. Apply the same scheduler rule to OmeggaBridge, including its inbox poller,
   status callback, and scheduler probes.
6. Make the packaged BMF loader/runtime byte-identical to the canonical files
   and add validation that rejects async scheduler invocations or template
   drift.
7. Run syntax, static, packaging, and regression checks before installing.
   Then perform one controlled managed restart and validate BMF health,
   OmeggaBridge transport, plugins, commands, timer cleanup, logs, port state,
   and frame/queue telemetry.
8. Observe a sustained post-change window and compare crash count, retained
   callbacks, timer counts, scheduler rejections, socket backlog, and frame
   time with the pre-change baseline.

## Rollback

Keep the pre-deploy UE4SS DLL and live BMF and OmeggaBridge directories as
timestamped backups. If startup, bridge transport, or gameplay validation
fails, stop the managed stack and retain the failed deployment logs before any
rollback decision. Do not restore only one Lua mod or mix the repaired Lua
runtime with the vulnerable native scheduler: the queue and
single-execution-domain invariants span UE4SS, BMF, and OmeggaBridge.

## Acceptance Criteria

- No runtime or packaged Lua file invokes an async Lua scheduler.
- A delayed callback can register, cancel, and retrigger delayed actions without
  mutating the vector currently being traversed, leaking Lua references, or
  executing a newly registered action in the same traversal.
- BMF reports `scheduler_execution_domain=game-thread-only`, a live
  `scheduler_thread_guard_available=true`, at least one scheduler thread check,
  and zero scheduler thread violations.
- Retained callbacks and active timers remain below their hard limits, with no
  unexplained monotonic growth across reloads.
- Reloading or isolating a plugin removes all of its timers, including timers
  whose IDs the plugin discarded.
- OmeggaBridge inbox polling is bounded and reports a game-thread scheduler.
- The managed server binds its expected port, BMF loads without plugin errors,
  bridge commands complete, and the validation window creates no new crash.
