# Proposed Patterns

These diagrams are a critique surface for the BMF/Omegga architecture. They are
intentionally high level: enough to show ownership, message flow, and trust
boundaries without repeating every API detail.

Use this page when reviewing whether a capability should live in BMF, in the
BMF-supported Omegga fork, in a Lua plugin, or in an external Omegga plugin.

## 1. BMF On Its Own

BMF can run inside a UE4SS-enabled Brickadia server without Omegga. In this
mode, BMF owns Lua bootstrap, plugin loading, command registration, runtime
files, and audit/telemetry output.

```mermaid
sequenceDiagram
    participant Server as Brickadia server
    participant UE4SS as UE4SS
    participant BMF as BMF Lua runtime
    participant Cmd as BMF command worker
    participant Files as runtime files

    Server->>UE4SS: Load UE4SS mods
    UE4SS->>BMF: Run Mods/BMF/Scripts/main.lua
    BMF->>BMF: Load config and plugin manifests
    BMF->>Cmd: Register bmf.* console commands
    BMF->>Files: Write status.json and telemetry.json
    Cmd->>BMF: Dispatch bmf.status / bmf.health
    BMF-->>Cmd: Return ok/code/key-value response
    Cmd->>Files: Write command response and audit records
```

Review questions:

- Which features still require Omegga when BMF runs standalone?
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
    participant Bridge as Omegga.Bridge.BMF
    participant Worker as BMF command worker
    participant BMF as BMF runtime
    participant Server as Brickadia server

    Plugin->>Omegga: Request BMF-backed action
    Omegga->>Bridge: Format Omegga.Bridge.BMF command
    Bridge->>Worker: Queue command file or socket command
    Worker->>BMF: Dispatch bmf.* handler
    BMF->>Server: Use safe UE4SS/helper path when needed
    Server-->>BMF: Return state or log-confirmed effect
    BMF-->>Worker: Return ok/code/key-value response
    Worker-->>Bridge: Write or send response
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
event file remains the durable fallback and audit trail.

```mermaid
sequenceDiagram
    participant BMF as BMF runtime
    participant Native as BMFSocket UE4SS mod
    participant Broker as Omegga socket broker
    participant Plugin as Omegga plugin client
    participant Jsonl as runtime/events.jsonl
    participant Fallback as runtime/commands

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
        Plugin->>Fallback: Write command file
        Fallback-->>Plugin: Read response file
    end
```

Review questions:

- Which messages require socket latency, and which can use file fallback?
- Where should authentication, replay protection, and backpressure live?
- Are event names stable enough for external plugins to depend on?

## 7. Brick Lookup With ConsoleTag

`ConsoleTag` should be treated as a stable logical identity, not as a magic live
pointer. Current safe patterns use the tag to find or confirm a candidate
runtime brick id, then let BMF native code validate that candidate before
mutation.

```mermaid
sequenceDiagram
    participant World as Saved world or BRDB export
    participant Indexer as Tag indexer
    participant CityRPG as CityRPG TreeService
    participant BMF as BMF runtime command
    participant Native as BMFSocket native lookup
    participant Server as Brickadia runtime brick

    World->>Indexer: Read bricks and component ConsoleTags
    Indexer->>CityRPG: Emit treeid -> position and runtime id candidate
    CityRPG->>CityRPG: Resolve native hit to treeid:<uuid>
    CityRPG->>BMF: bmf.bricks.runtime.set brickid=<candidate> tag=<treeid>
    BMF->>Native: Request inspect/set for explicit brick id
    Native->>Server: Lookup live runtime brick by id
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
    BMF-->>CityRPG: Status includes sequence, brick_id, and tag
```

Review questions:

- What produces the trusted tag index for a given server?
- When should saved `brickIndex` be rejected as a runtime id candidate?
- Is a future tag-only resolver worth the game-thread scan risk?

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

## Consolidation Rule

Detailed API pages should document exact parameters, flags, and validation
levels. This page should own the high-level flow explanations. If another doc
starts re-explaining one of these flows in prose, link back here and keep the
local text focused on the command or configuration at hand.
