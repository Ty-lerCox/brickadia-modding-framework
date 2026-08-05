# Why the Brickadia Server Kept Crashing

> A podcast-ready explanation of the August 2, 2026 incident. This version is
> intentionally conversational and avoids most of the low-level programming
> language.

## The Short Version

The server kept crashing because its scripting system was changing a task list
while it was still walking through that same task list.

Imagine someone reading jobs from a whiteboard, one line at a time. While they
are halfway down the board, one of those jobs erases a line, moves the board,
and adds more jobs. The reader still thinks the old board is in the old place.
Their next step can land on missing or unrelated information.

That is essentially what happened inside UE4SS, the layer that lets our
Brickadia server run Lua scripts. A scheduled Lua callback could add or cancel
another callback while UE4SS was processing its internal list. That could move
the list in memory and leave UE4SS holding directions to a location that was no
longer valid. In programming terms, this is undefined behavior. In practical
terms, it can corrupt memory, freeze the game thread, or crash the server.

The server was not failing because one CityRPG feature was too heavy or because
one particular plugin was broken. The problem was in the shared scheduling
machinery underneath all of those features.

## What People Saw

There were several server failures on August 2. They did not all look exactly
the same from the outside.

One failure was an access violation inside Lua's memory-cleanup code. Another
looked like the main game thread was stuck while Lua was turning a value into
text and running a protected function call. After one automatic recovery, the
server also hit a Brickadia networking assertion while a client was reconnecting
during the new world's startup.

That variety initially made the incident look like several separate bugs. It
was more like one loose electrical connection causing different appliances to
flicker. The exact place where the failure became visible changed, but the
repeated path underneath it was the same: UE4SS was processing delayed Lua work
on the game thread.

The networking assertion was a follow-on problem during a fast recovery and
reconnect. It was real, but it was not the root cause of the recurring crashes.

## What Was Actually Going Wrong

Lua is the scripting language used by BMF and its plugins. UE4SS provides a
scheduler so a script can say, in effect, "run this on a later game frame."

Before the fix, UE4SS processed those scheduled actions directly inside the
same list where they were stored. It also allowed the action currently running
to schedule or cancel more actions. The lock around that list was recursive,
meaning the callback was allowed to re-enter the scheduler instead of being
stopped.

That combination was dangerous. Adding a new action could force the list to
move somewhere else in memory. UE4SS would then continue walking through the
old location. Sometimes it survived. Sometimes Lua's garbage collector later
found damaged state. Sometimes the game thread stopped making progress.

There was a second risk on top of that. UE4SS, BMF's socket module, and some
asynchronous script paths each had their own idea of when Lua was safe to use.
Their locks did not coordinate with one another, even though they could touch
the same Lua state. A lock can only protect a room if every entrance uses the
same lock.

So the real issue had two parts:

1. The scheduler could invalidate its own task list while processing it.
2. More than one execution path could potentially enter the same Lua world
   without a single shared safety boundary.

This also explains why the crashes became frequent instead of happening in one
perfectly repeatable spot. Memory corruption is messy. The original mistake
can happen first, while the visible crash appears seconds later in whatever
code touches the damaged memory next.

## What We Changed

The fix was broader than changing one line, because the safe rule has to hold
across UE4SS, BMF, its plugins, and OmeggaBridge.

First, the native UE4SS scheduler now has a waiting area. If a callback creates
new scheduled work while the current batch is running, that work goes into a
separate pending queue. It cannot rearrange the list that UE4SS is currently
walking. Once the active batch is finished, pending work can be moved into the
next batch safely.

Second, all Lua callbacks now run on the game thread. Background workers may
still handle ordinary byte input and output, but they are not allowed to enter
Lua or touch game objects. They hand copied messages to a bounded queue, and
Lua picks those messages up later from the game thread.

Third, old asynchronous Lua scheduling routes were shut off. Repeating jobs
now schedule one future step at a time. This is closer to setting one alarm,
letting it ring, and then setting the next alarm. It avoids keeping a fragile
loop alive inside the native scheduler.

Fourth, timers now belong to the plugin that created them. When a plugin is
unloaded, reloaded, fails to start, or is isolated by the watchdog, all of its
timers are removed. That prevents abandoned callbacks from firing after their
plugin is gone.

Finally, we applied the same model to OmeggaBridge. Its message polling is
bounded, runs on the game thread, and uses the same one-step-at-a-time
scheduling pattern.

## How We Tested the Repair

The repair was built, installed, and checked at several levels.

- The full validation suite and package build passed.
- All 83 core and command-line tests passed.
- A timer test confirmed that one-time and repeating timers fired the expected
  number of times, canceled timers stayed canceled, and work continued after
  the test completed.
- A watchdog test deliberately failed a plugin three times. The plugin was
  isolated, further calls were blocked, and a reload recovered it cleanly.
- Live BMF load and reload commands were each run twice.
- The installed UE4SS, BMF, and OmeggaBridge files were checked against the
  newly built versions to make sure the server was actually running the repair.
- During a three-minute live observation window, the scheduler completed more
  than 81,000 safety checks with zero thread violations or dispatch errors.
- More than 1,300 timer callbacks and thousands of socket and bridge polling
  cycles completed without callback errors.
- No new crash appeared during the validation window.

The server was left running, listening on its normal port, with BMF healthy,
three plugins loaded, and no plugin errors. Normal frame performance stayed
around 57 to 61 frames per second after startup and reload activity settled.

## What This Means Going Forward

The important improvement is not simply that the latest crash stopped. We now
have a clear rule for the scripting system: Lua runs in one controlled place,
on the game thread, and callbacks cannot mutate the scheduler list that is
currently being processed.

We also added checks around the failure modes that made this incident hard to
understand. Timer ownership, callback limits, scheduler thread checks, plugin
watchdog behavior, and bridge polling can all be observed and validated.

No software repair makes future crashes impossible. But this was a concrete,
reproducible design flaw on the exact path shown in the crash reports, and the
new design removes that flaw instead of hiding one symptom.

## The Takeaway

The crashes looked random because memory damage often becomes visible far away
from the original mistake. The underlying problem was not random: the server
was letting scripts rearrange the scheduler's task list while the scheduler was
still using it, with additional unsafe paths into the same Lua state.

The repair separates new work from work already in progress, keeps Lua on the
game thread, cleans up timers with their plugins, and limits how much queued
work can run at once. The result is a simpler and much safer foundation for BMF,
CityRPG, and OmeggaBridge.

## Pronunciation Notes

- **Lua:** "LOO-ah"
- **UE4SS:** "U-E-four-S-S"
- **BMF:** Say each letter: "B-M-F"
- **Omegga:** "oh-MEG-uh"
- **CityRPG:** "City R-P-G"
