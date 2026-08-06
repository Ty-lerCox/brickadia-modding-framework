# Brickadia's Reconnect Crash: The Old-Address Problem

Date: 2026-08-06
Status: root cause fixed, deployed, and reconnect-tested; longer performance
monitoring continues

## The short version

We found two different problems that looked related on the graphs but need two
different fixes.

The request queues caused real hitching. Too much work could bunch up on the
game thread, making frame time jump and FPS dip. The bounded Phase 2 scheduler
is meant to control that performance problem.

The latest server crash had a different immediate cause. BMF's Omegga bridge
remembered a live Brickadia player-controller object, the player disconnected
and reconnected, and a later whisper tried to inspect the old object. The server
crashed while Unreal was checking that stale object.

In plain English: the queue explains some slow frames; an old address explains
this crash.

## The old-address analogy

Imagine writing down a friend's apartment number. They move, but their name is
still in your contacts. Five minutes later, you send a delivery to the apartment
number you saved instead of looking up their new one.

That is close to what happened here. Brickadia created a controller object for
the player. The bridge saved that live object's "address." When the player
reconnected, Brickadia retired the old controller and created a new one. The
bridge still reached for the old address.

Even asking the old object, "Are you still valid?" was unsafe. The pointer could
already be broken before Unreal got a chance to answer the question.

## Exact timeline from the crash logs

The timestamps below are UTC on 2026-08-06.

- `00:12:55`: A whisper to `Ty` resolved the current player controller and
  succeeded. The bridge remembered that controller.
- `00:17:43`: Another whisper explicitly used the cached controller and
  succeeded because it was still the same live object.
- `00:19:14`: `Ty` disconnected. Brickadia closed the old controller,
  `BP_PlayerController_C_2147475224`, removed the connection, and logged the
  player leaving.
- `00:19:16`: `Ty` rejoined and received a new live connection/controller.
- `00:24:22`: The next whisper began resolving `Ty`. The bridge checked its
  remembered controller, entered Unreal's `IsValid()`/`IsUnreachable()` path,
  and the dedicated server exited with an access-violation read at `0x4` before
  the whisper could complete.

The crash stack ends in UE4SS Lua calling into Unreal object lifecycle code.
That lines up with the bridge trace stopping exactly as it tried to reuse the
remembered player source after the reconnect.

## Why a normal error handler did not save us

Lua can catch ordinary Lua errors. This was a native access violation inside
Unreal/UE4SS. Once code follows an invalid native pointer, a Lua `pcall` cannot
reliably turn that into a harmless error message.

That is why the safe rule must be "do not keep the old pointer," not "keep it and
check it later."

## What we changed

1. Keep only plain data across frames: player name, ID, timestamps, and other
   serializable snapshot fields.
2. Never retain a raw UE object, controller wrapper, or controller address for a
   later request.
3. Resolve the live controller fresh on the game thread for each command, use it
   during that one dispatch, and immediately discard it.
4. Put native lifecycle checks around the fresh resolver. If it cannot safely
   find the current controller, fail the whisper or team command closed.
5. Apply the same rule to Omegga bridge context caches and BMF's player registry
   and tunnel paths, not only the one whisper function that crashed.
6. Test the exact failure sequence: whisper, disconnect, reconnect, whisper
   again. Also repeat it with team assignment and ordinary player sync.
7. Perform one controlled deployment, verify server settings and roles are
   unchanged, then soak while watching frame time and crash-folder creation.

## What the live test proved

The bounded queue and scheduler work addresses the traffic problem. Separately,
the lifecycle hardening removed saved live Unreal objects from the chat bridge,
player registry, command tunnel, native tree-target cache, and prefab replay.
Worker-to-worker replies were also bounded so a failed plugin call cannot leak a
listener or turn into an unhandled rejection.

We then restarted once, connected `Ty`, disconnected and reconnected, and sent
whisper requests on both sides of that new connection. The bridge explicitly
used fresh discovery both times. The unsupported operation failed harmlessly,
the new-session team assignment and player sync completed, and the server stayed
alive. No new crash folder appeared. The server name and role files were also
unchanged.

This does not mean every frame spike has vanished. A few expensive one-time
startup and reconnect operations still crossed 100 milliseconds even though the
queues were empty. That is remaining performance work, not the stale-pointer
crash returning.

## Podcast-ready takeaway

"We originally saw one ugly symptom: the server would stutter and sometimes
crash. It turned out to be two bugs standing next to each other. The queue could
make the server late, like too many cars entering one lane. But the crash was an
old-address problem: after a player reconnected, the bridge sometimes called an
Unreal object that belonged to the player's previous connection. We are fixing
the traffic problem with strict work budgets, and the crash problem by never
carrying live Unreal pointers from one request to the next. We deployed that
rule, repeated the exact reconnect sequence that used to crash, and the server
stayed up. The traffic is now bounded, although a few expensive one-time jobs
still need longer performance monitoring."
