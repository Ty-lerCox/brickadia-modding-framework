# Architecture Patterns

These proposed patterns are a critique surface for the BMF/Omegga architecture.
They are intentionally high level: enough to show ownership, message flow, and
trust boundaries without repeating every API detail.

## Who Should Read This?

Architects should use this page to challenge ownership and trust boundaries.
BMF maintainers should use it when deciding where a capability belongs. Plugin
authors and Omegga integrators should use it to understand which side owns a
message, command, or hook.

Use this page when reviewing whether a capability should live in BMF, in the
BMF-supported Omegga fork, in a Lua plugin, or in an external Omegga plugin.

## 1. Required BMF Runtime Stack

BMF's supported Windows runtime requires the BMF-supported Omegga Windows fork.
Omegga owns the server supervisor, UE4SS compatibility setup, command bridge,
log context, player sync, and helper surfaces that BMF depends on for current
canaries and live-player APIs. BMF owns the UE4SS Lua runtime, plugin loader,
capability gates, runtime files, and BMF API contracts.

```mermaid
sequenceDiagram
    participant Admin as Admin or Desktop
    participant Omegga as Omegga fork
    participant Server as Brickadia server
    participant UE4SS as UE4SS
    participant BMF as BMF Lua runtime
    participant Bridge as BMF Bridge/BMFSocket
    participant Cmd as BMF command dispatcher
    participant Files as runtime files

    Admin->>Omegga: Start or repair managed profile
    Omegga->>Server: Launch dedicated server with UE4SS/BMF environment
    Server->>UE4SS: Load UE4SS mods
    UE4SS->>BMF: Run Mods/BMF/Scripts/main.lua
    BMF->>BMF: Load config and plugin manifests
    BMF->>Cmd: Register bmf.* console commands
    BMF->>Files: Write status.json and telemetry.json
    Omegga->>Bridge: Send BMF-backed command request
    Bridge->>Cmd: Dispatch bmf.status / bmf.health
    Cmd->>BMF: Execute command in BMF runtime
    BMF-->>Cmd: Return ok/code/key-value response
    Cmd-->>Bridge: Return BMF result
    Bridge-->>Omegga: Return command response
    Cmd->>Files: Write audit records
```

Review questions:

- Which responsibilities are Omegga runtime requirements today?
- Which runtime files are stable contracts versus diagnostics?
- Which command handlers cross onto the game thread?

## 2. Omegga Fork On Its Own

The BMF-supported Omegga fork is still an Omegga server supervisor. Without BMF
participating, it starts Brickadia, reads logs, manages plugins, exposes web/UI
surfaces, and sends supported console/helper commands.

```mermaid
sequenceDiagram
    participant Admin as Admin or web UI
    participant Omegga as Omegga fork
    participant Plugin as Omegga plugin
    participant Server as Brickadia server
    participant Logs as Brickadia logs

    Admin->>Omegga: Start server or run admin action
    Omegga->>Server: Launch dedicated server
    Server-->>Logs: Write console and gameplay logs
    Omegga->>Logs: Tail logs and update runtime state
    Omegga->>Plugin: Emit Omegga events
    Plugin->>Omegga: Request chat, command, or helper call
    Omegga->>Server: Execute supported console/helper route
    Server-->>Omegga: Log/result observed
    Omegga-->>Plugin: Resolve plugin callback or promise
```

Review questions:

- Which Omegga behaviors are generic upstream behavior?
- Which behaviors are fork-specific Windows/UE4SS compatibility shims?
- Which plugin APIs depend on logs instead of direct server state?

## 3. BMF With Lua Plugins

BMF Lua plugins are in-process server-side extensions. They should use the
capability-gated BMF facade instead of reaching directly into globals or native
helpers.

```mermaid
sequenceDiagram
    participant BMF as BMF runtime
    participant Loader as Plugin loader
    participant Plugin as Lua plugin
    participant API as Capability-gated BMF facade
    participant Audit as Audit and telemetry

    BMF->>Loader: Discover bmf.json manifests
    Loader->>Plugin: Load plugin in scoped environment
    Loader->>API: Build facade from requested capabilities
    Plugin->>API: Call BMF.chat / BMF.storage / BMF.server
    API->>API: Validate options, rate limits, and capability
    API->>BMF: Execute allowed operation
    BMF-->>Plugin: Return ok/code/result table
    BMF->>Audit: Record command, plugin, and error metadata
```

Review questions:

- Are capability names specific enough for review?
- Should a plugin receive a direct mutating API or a queued command API?
- What gets cleaned up automatically on plugin reload?

## 4. BMF Event Bus With Lua Plugins

The BMF event bus is the in-process coordination path. It lets framework code
and Lua plugins share events without forcing every plugin to poll files or logs.

```mermaid
sequenceDiagram
    participant Producer as BMF subsystem or plugin
    participant Bus as BMF.events
    participant PluginA as Lua plugin A
    participant PluginB as Lua plugin B
    participant Jsonl as runtime/events.jsonl
    participant Socket as Optional socket bridge

    PluginA->>Bus: BMF.events.on(name, handler)
    PluginB->>Bus: BMF.events.on(name, handler)
    Producer->>Bus: BMF.events.emit(name, payload)
    Bus->>PluginA: Invoke handler(data, eventName)
    Bus->>PluginB: Invoke handler(data, eventName)
    Bus->>Jsonl: Append durable event record
    alt socket bridge active
        Bus->>Socket: Send event envelope
    end
    Bus-->>Producer: Return handler count and errors
```

Review questions:

- Which events are framework contracts versus plugin-local conventions?
- Do event handlers need allow/deny semantics or report-only semantics?
- Which events must also leave an audit trail outside the process?

## 5. BMF And Omegga Fork For Basic Omegga Functionality

For basic Omegga functionality, the fork stays the supervisor and transport
owner. BMF provides the server-side command/API implementation when the action
needs UE4SS or Brickadia-specific access.

```mermaid
sequenceDiagram
    participant Plugin as Omegga plugin
    participant Omegga as Omegga fork
    participant Bridge as BMF Bridge plugin
    participant Socket as BMFSocket path
    participant BMF as BMF runtime
    participant Server as Brickadia server

    Plugin->>Omegga: Request BMF-backed action
    Omegga->>Bridge: emitPlugin("invokeCommand", command)
    Bridge->>Socket: Send authenticated command envelope
    Socket->>BMF: Dispatch bmf.* handler
    BMF->>Server: Use safe UE4SS/helper path when needed
    Server-->>BMF: Return state or log-confirmed effect
    BMF-->>Socket: Return ok/code/key-value response
    Socket-->>Bridge: Resolve command id
    Bridge-->>Omegga: Resolve command result
    Omegga-->>Plugin: Return Omegga-facing result
```

Review questions:

- Which layer owns retry behavior?
- Which layer converts BMF result fields into Omegga plugin errors?
- Which operations should remain Omegga-only instead of routing through BMF?

## 6. BMF And Omegga Event Bus Messaging

For low-latency messaging between in-process BMF and external Omegga plugins,
the supported fork starts an authenticated loopback socket broker. The JSONL
event file remains durable diagnostic and audit evidence.

```mermaid
sequenceDiagram
    participant BMF as BMF runtime
    participant Native as BMFSocket UE4SS mod
    participant Broker as Omegga socket broker
    participant Plugin as Omegga plugin client
    participant Jsonl as runtime/events.jsonl

    Broker->>Broker: Bind loopback and generate token
    Broker-->>BMF: Pass OMEGGA_BMF_SOCKET_* env
    BMF->>Native: Start socket client as bmf-native
    Plugin->>Broker: Connect as plugin/cityrpg with token
    BMF->>Jsonl: Append every BMF event
    BMF->>Native: Send event envelope
    Native->>Broker: Forward event envelope
    Broker->>Plugin: Deliver subscribed event
    Plugin->>Broker: Send BMF command envelope
    Broker->>Native: Forward command envelope
    Native->>BMF: Queue command for Lua/game-thread dispatch
    BMF-->>Native: Return command response
    Native-->>Broker: Forward response
    Broker-->>Plugin: Resolve command id
    alt socket unavailable
        Plugin-->>Plugin: Mark integration unhealthy and surface repair action
    end
```

Review questions:

- Which messages require socket latency, and what repair action should surface
  when the socket is unavailable?
- Where should authentication, replay protection, and backpressure live?
- Are event names stable enough for external plugins to depend on?

## 7. Brick Lookup With ConsoleTag

`ConsoleTag` should be treated as a stable logical identity, not as a magic live
pointer. Current safe patterns expose `lookup:<uuid>:<purpose>` to scripters,
then let BMF use existing bindings, explicit positions, or the native target
cache to find and validate the live runtime brick before mutation.

```mermaid
sequenceDiagram
    participant World as Saved world or BRDB export
    participant Indexer as Tag indexer
    participant CityRPG as CityRPG TreeService
    participant BMF as BMF runtime command
    participant Native as BMFSocket native lookup
    participant Server as Brickadia runtime brick

    World->>Indexer: Read bricks and component ConsoleTags
    Indexer->>CityRPG: Emit lookup tag -> position and optional runtime hint
    CityRPG->>CityRPG: Resolve native hit to lookup:<uuid>:<purpose>
    CityRPG->>BMF: bmf.bricks.runtime.set-guid tag=lookup:<uuid>:<purpose>
    BMF->>Native: Resolve cached tag/position to runtime brick
    Native->>Server: Lookup live runtime brick by bounded candidate
    Server-->>Native: Return brick pointer/state
    Native->>Native: Verify internal runtime id matches candidate
    alt id matches and context is available
        Native->>Server: Apply visible/collision mutation
        Native-->>BMF: ok=true code=OK
    else context scan needed
        Native-->>BMF: ok=false code=BRICK_GRID_CONTEXT_SCAN_PENDING
        CityRPG->>BMF: Retry same low-frequency mutation after status wait
    else id mismatch
        Native-->>BMF: ok=false code=BRICK_ID_MISMATCH
    end
    BMF-->>CityRPG: Status includes sequence, brick_id, guid, and optional tag
```

Review questions:

- What produces the trusted tag index for a given server?
- When should saved `brickIndex` be rejected as a runtime id candidate?
- How fresh does the bounded native target cache need to be for UUID-first
  resource lookup without adding game-thread scan risk?

## 8. Hooked Brickadia Events Into Lua

BMF gets gameplay events into Lua through a small number of hook ingress paths.
The key architectural rule is that hooks should capture the minimum Brickadia
state needed, then hand a normalized event to BMF Lua. Lua owns policy,
capability checks, event naming, plugin dispatch, and audit output.

```mermaid
sequenceDiagram
    participant Server as Brickadia runtime
    participant LuaHook as UE4SS Lua hook/callback
    participant NativeHook as Native C++ hook/detour
    participant Queue as Safe handoff queue
    participant BMF as BMF Lua runtime
    participant Bus as BMF.events
    participant Plugin as Lua plugin handler
    participant Audit as JSONL/socket/audit output

    alt UE4SS Lua hook path
        Server->>LuaHook: Invoke registered Lua callback
        LuaHook->>BMF: Pass raw hook payload
    else native hook path
        Server->>NativeHook: Hit native detour or function hook
        NativeHook->>NativeHook: Capture minimal fields only
        NativeHook->>Queue: Enqueue event payload for Lua/game-thread drain
        Queue->>BMF: Drain payload through BMF Lua bridge
    end

    BMF->>BMF: Normalize payload and assign event name
    BMF->>BMF: Apply feature gates, rate limits, and safety checks
    BMF->>Bus: BMF.events.emit(name, normalizedPayload)
    Bus->>Plugin: Invoke plugin-owned handlers
    Bus->>Audit: Append event record and optional socket envelope
    Bus-->>BMF: Return handler count and errors
```

Review questions:

- Which hook paths are safe to call Lua directly, and which must queue first?
- What is the minimal payload each hook should capture before returning?
- Which layer owns policy decisions: the hook, BMF normalization, or plugins?
- How are duplicate native callbacks coalesced before they become gameplay
  events?

## 9. CityRPG Native Tree Cutting

Tree cutting is the current concrete example of the hook-ingress pattern. BMF
does not get this event from Omegga logs first. It captures the Brickadia melee
impact in native code, drains the native queue into BMF Lua, emits a BMF event,
and lets CityRPG consume that event over the socket.

```mermaid
sequenceDiagram
    participant Player as Player with handaxe
    participant Server as Brickadia melee runtime
    participant Native as BMFSocket treecut detour
    participant Queue as Native treecut queue
    participant BMF as BMF Lua runtime
    participant Bus as BMF.events
    participant Relay as CityRPG BMF relay
    participant Tree as CityRPG TreeService
    participant Physical as BMF runtime brick state

    BMF->>Native: Start resource native capture
    Native->>Server: Install detour on melee impact function
    Player->>Server: Swing handaxe or pickaxe at resource
    Server->>Native: Call detoured melee impact
    Native->>Server: Call original Brickadia function
    Native->>Native: Read impact, normal, context, ConsoleTag candidates
    Native->>Native: Verify weapon context is handaxe or pickaxe
    Native->>Queue: Enqueue cityrpg.treecut.hit or cityrpg.mine.hit JSON payload

    BMF->>Queue: Drain with BMFSocketResourceNativeDrain
    Queue-->>BMF: Return queued native payloads
    BMF->>BMF: Decode payload and mark source BMFSocketResourceNative
    BMF->>Bus: Emit cityrpg.treecut.hit or cityrpg.mine.hit
    Bus->>Bus: Append runtime/events.jsonl as evidence and send socket envelope
    Bus-->>Relay: Deliver event by socket
    Relay->>CityRPG: Emit local treecut or minehit event

    Tree->>Tree: Verify itemType=handaxe and itemVerified=true
    Tree->>Tree: Resolve player from payload
    Tree->>Tree: Resolve treeid tag or cached anchor
    Tree->>Tree: Apply per-player/per-tree duplicate-hit cooldown
    Tree->>Tree: Process chop, health, XP, and drops

    alt tree still has health
        Tree-->>Player: Show progress or feedback
    else tree is depleted
        Tree-->>Player: Award lumber, seed chance, and XP
        Tree->>Tree: Save tree state and schedule respawn
        opt physical state enabled
            Tree->>Physical: bmf.bricks.runtime.set-guid tag=lookup:<uuid>:treecut
            Physical->>Physical: Resolve lookup binding and validate sparse-grid context
            alt context ready
                Physical-->>Tree: visible=false result OK
            else background context scan pending
                Physical-->>Tree: BRICK_GRID_CONTEXT_SCAN_PENDING
                Tree->>Physical: Wait for matching status sequence and retry later
            end
        end
    end
```

Review questions:

- Should BMF emit a more generic event than `cityrpg.treecut.hit` before
  CityRPG-specific naming?
- Which fields in the native payload are stable enough to document as a
  contract?
- Where should duplicate-hit coalescing live: native queue, BMF Lua, or
  CityRPG?
- Should physical hide/restore be part of tree-cut handling, or a separate
  resource-node lifecycle pattern?

## Consolidation Rule

Detailed API pages should document exact parameters, flags, and validation
levels. This page should own the high-level flow explanations. If another doc
starts re-explaining one of these flows in prose, link back here and keep the
local text focused on the command or configuration at hand.
