# Server API

BMF server APIs cover runtime status, safe world saves, guarded shutdown
attempts, restricted console execution, and file-backed server settings
patching.

**Labels:** `experimental`, `file-backed`, `restricted`, `L2 Headless`, `L5 Negative`

## Who Should Read This?

Plugin authors should start here before using server-level helpers. Server
operators should use the child pages to understand which operations are safe
for validation servers and which still need an external supervisor. Maintainers
should keep native or command-executor details out of this overview.

## Page Map

| Page | Use it for |
| --- | --- |
| [Status And Save](server/status-and-save.md) | `BMF.server.status()` and `BMF.server.save()`. |
| [Shutdown](server/shutdown.md) | Confirmation-gated shutdown attempts and current unsupported executor behavior. |
| [Restricted Exec](server/restricted-exec.md) | `BMF.server.exec(command)` and its capability/config gates. |
| [Settings Patching](server/settings-patching.md) | `BMF.server.planSettingsPatch()` and file-backed `GameUserSettings.ini` patch tooling. |

## Examples

- [WelcomeMessage](../examples/welcome-message.md): complete plugin that plans
  a server name and welcome-message patch.
- [HealthCheck](../examples/health-check.md): logs server/runtime health fields
  at plugin load.

## Validation

Current server API proof is tracked in
[API Validation Evidence](../validation/api-validation.md#server).
