# Common Workflows

Use this page to get from a goal to the right docs without reading the whole
site.

## Who Should Read This?

Plugin authors should use it before starting a feature. Server operators should
use it when validating installs or runtime health. Maintainers should use it as
the workflow map when reviewing docs coverage.

## Write A First Lua Plugin

1. Start with [First Plugin](../getting-started/first-plugin.md).
2. Copy a matching example from [Lua Examples](../examples/index.md).
3. Declare only the required capabilities in `bmf.json`.
4. Use [Plugin Lifecycle](../api/plugins/lifecycle.md),
   [Plugin Capabilities](../api/plugins/capabilities.md),
   [Plugin Storage](../api/plugins/storage.md), and
   [Plugin Sandbox](../api/plugins/sandbox.md) as needed.

## Call BMF From Omegga

1. Confirm the server uses the [Supported Runtime Matrix](../reference/supported-runtime.md).
2. Use [Commands](../api/commands.md) for `Omegga.Bridge.BMF` command routes.
3. Use [Architecture Patterns](../architecture/architecture-patterns.md) for the
   command and socket sequence diagrams.
4. Prefer socket transport for latency-sensitive plugin traffic and keep
   file-backed commands as fallback.

## Emit And Consume Events

1. Use [Events](../api/events.md) for the generic BMF event bus.
2. Use [Minigame Events](../api/minigames/events.md) for minigame-specific
   normalized event names and metadata.
3. Use [Architecture Patterns](../architecture/architecture-patterns.md) for
   Lua, socket, and JSONL event flow diagrams.
4. Keep durable audit/fallback behavior through `runtime/events.jsonl`.

## Validate Frame Time

1. Read [Observability and Performance](../architecture/observability-performance.md).
2. Enable `BMFFrameTelemetry` only when the native sampler is expected.
3. Capture baseline, active, and recovery windows.
4. Record the result under the [Canary Contract](../validation/canary-contract.md).

Run `L6 Frame Time` before promoting polling, live scans, native mutation, or
bursty command/event traffic.

## Debug Socket Transport

1. Confirm the runtime path in [Supported Runtime Matrix](../reference/supported-runtime.md).
2. Run `bmf.socket.status` through [Commands](../api/commands.md).
3. Check Omegga broker health and BMF native socket counters.
4. Fall back to file-backed commands or JSONL events when the socket is not
   available.

## Inspect Tree Cutting

1. Start with diagram 9 in [Architecture Patterns](../architecture/architecture-patterns.md#9-cityrpg-native-tree-cutting).
2. Use [Resource Lookup Tags](resource-lookup-tags.md) for the
   `lookup:<uuid>:treecut` and `lookup:<uuid>:mine` in-game tag format.
3. Use [Runtime Brick State](../api/runtime-bricks.md) for physical
   hide/restore rules.
4. Use [Native Hook Notes](../maintainers/native-hooks.md) for hook ownership and
   restart-sensitive maintenance.
5. Keep CityRPG-specific policy in the CityRPG tree and stone services, not BMF
   core.

## Work With Role And Tool Policy

1. Use [Permissions](../api/permissions.md) to choose the correct policy area.
2. Use [Role Files](../api/permissions/role-files.md) for `RoleSetup2.json` and
   `RoleAssignments.json`.
3. Use [Applicator Policy](../api/permissions/applicator-policy.md),
   [Interactable Tags](../api/permissions/interactable-tags.md), or
   [Brick Assets](../api/permissions/brick-assets.md) for live tool policy.
4. Check [API Validation Evidence](../validation/api-validation.md#permissions)
   before claiming live enforcement.

## Add Or Update Documentation

1. Follow [Documentation Style Guide](../maintainers/docs-style-guide.md).
2. Keep API contracts in API pages.
3. Keep validation proof in [API Validation Evidence](../validation/api-validation.md).
4. Keep native hook internals in [Native Hook Notes](../maintainers/native-hooks.md).
5. Run `python -m mkdocs build --strict` before committing.
