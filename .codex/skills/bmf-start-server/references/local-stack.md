# Local BMF Stack Reference

Use this file only when the main workflow needs exact local paths or BMF Desktop context.

## Repositories And Data

- Brickadia/Omegga runtime checkout: `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia`
- BMF repo: `C:\Users\tycox\OneDrive\Documents\GitHub\bmf`
- BMF Desktop app source: `C:\Users\tycox\OneDrive\Documents\GitHub\bmf\apps\bmf-desktop`
- BMF Desktop user data: `%APPDATA%\BMF Desktop`
- BMF Desktop profile store: `%APPDATA%\BMF Desktop\profiles\profiles.json`
- BMF Desktop configured Alloy template: `%APPDATA%\BMF Desktop\alloy\bmf.alloy`
- Local BMF runtime dir: `%APPDATA%\omegga\steam_installs\main\Brickadia\Binaries\Win64\ue4ss\main\Mods\BMF\runtime`

## Normal Ports

- Brickadia dedicated server UDP: `7777`
- Omegga web and metrics: `127.0.0.1:8080`
- CityRPG metrics: `127.0.0.1:3000`
- Installed Alloy service admin: `127.0.0.1:12345`
- Skill-managed user Alloy fallback admin: `127.0.0.1:12346`
- BMF socket broker: read current host/port/token from `runtime\socket.json`

## BMF Desktop Capabilities To Mirror

BMF Desktop and `bmfctl` expose guarded service actions:

- `start-stack`, `stop-stack`, `restart-stack`
- `start-alloy`, `stop-alloy`, `restart-alloy`
- telemetry Alloy config rendering/writing
- dashboard import payload generation/upload
- profile health checks with HTTP probes and port diagnostics
- traffic snapshots from BMF socket metadata and bridge status
- troubleshooting snapshots with redacted logs and runtime files

Desktop service actions are confirmed and journaled. Chat-driven startup should not need the UI, but should keep the same evidence model: PID/log/journal paths when a process is started, health checks after startup, and redacted token handling.

## CLI Equivalents

From `C:\Users\tycox\OneDrive\Documents\GitHub\bmf`:

```powershell
node .\cli\bin\bmfctl.js services start-stack --start-script C:\path\to\Start-LocalOmegga.ps1 --apply --confirm start
node .\cli\bin\bmfctl.js services start-alloy --alloy-executable "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" --alloy-config "%APPDATA%\BMF Desktop\alloy\bmf.alloy" --apply --confirm start
node .\cli\bin\bmfctl.js traffic
```

For this local machine, `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\run-omegga.cmd` is the known-good launcher because it sets the current BMF/Omegga/CityRPG environment and repairs the active UE4SS BMF payload.

## Grafana And Alloy Notes

The persisted user environment currently uses:

- `GRAFANA_CLOUD_PROMETHEUS_RW_URL`
- `GRAFANA_CLOUD_PROMETHEUS_USERNAME`
- `GRAFANA_CLOUD_API_KEY`

Older BMF templates may look for:

- `BMF_GRAFANA_REMOTE_WRITE_URL`
- `BMF_GRAFANA_REMOTE_WRITE_USERNAME`
- `BMF_GRAFANA_REMOTE_WRITE_TOKEN`

If Alloy is ready but `/api/v0/web/components` is `[]`, it is not loading the BMF scrape/remote-write pipeline. Start a user-level Alloy fallback with a generated config or repair the BMF Desktop Alloy config. Remote-write health is based on Alloy counters such as:

- `prometheus_remote_storage_samples_in_total`
- `prometheus_remote_storage_samples_total`
- `prometheus_remote_storage_samples_failed_total`
- `prometheus_remote_storage_samples_pending`

Write-scoped Grafana Cloud API keys can push samples but may return `401 invalid scope requested` for read/query API calls. Do not treat that as a remote-write failure when Alloy reports sent samples with zero failures.
