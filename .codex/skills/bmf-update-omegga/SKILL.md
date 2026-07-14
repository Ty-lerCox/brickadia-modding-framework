---
name: bmf-update-omegga
description: Update the BMF-supported Omegga fork from upstream brickadia-community/omegga. Use when the user asks to pull, install, update, upgrade, sync, or reset to the latest Omega/Omegga inside BMF/VMF, verify the Omegga web client version, record the supported upstream commit, or repair version skew between the local BMF Omegga runtime and upstream Omegga.
---

# BMF Update Omegga

## Overview

Update the vendored BMF Omegga runtime from `brickadia-community/omegga` while preserving the Windows/BMF/UE4SS patches that make the local server work. Treat this as repository maintenance plus live-runtime validation, not a plain `git pull`.

Use companion skills when available:

- `main-branch-workflow` before git/repository edits.
- `bmf-performance-guardrails` because Omegga, BMF sockets, metrics, and UE4SS changes can affect live server performance.
- `bmf-start-server` to stop/start/check the local stack and collect health evidence.
- `browser:control-in-app-browser` when verifying the visible Omegga web client.
- `ue4ss-brickadia-crash-forensics` if Brickadia/Omegga exits or bridge logs show crashes/timeouts.

## Local Shape

- Workspace root is usually `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia`.
- Vendored Omegga root is `omegga-master\omegga-master`.
- Upstream remote is `https://github.com/brickadia-community/omegga.git`, branch `master`.
- Runtime tracking doc is `docs\supported-omegga-runtime.md`.
- Local launch path is `run-omegga.cmd`.
- Local website is `http://127.0.0.1:8080/plugins`.

The product is spelled **Omegga**, but users often say "Omega"; treat both as the same runtime for this workflow.

## Workflow

1. Orient and protect existing work.
   - Run `git status --short --branch` and identify the primary branch.
   - Do not revert unrelated local or user changes.
   - Create `artifacts\omegga-upstream-merge-YYYYMMDD-HHMMSS`.
   - Save the current diff before editing:
     ```powershell
     git diff --binary > artifacts\omegga-upstream-merge-YYYYMMDD-HHMMSS\pre-update-working.diff
     ```

2. Verify the true latest upstream.
   - Add the remote if missing:
     ```powershell
     git remote add upstream https://github.com/brickadia-community/omegga.git
     ```
   - Fetch and identify latest:
     ```powershell
     git fetch upstream master --tags
     git ls-remote https://github.com/brickadia-community/omegga.git refs/heads/master
     git log -1 --format="%H%n%cI%n%s" upstream/master
     git show upstream/master:package.json
     ```
   - If the user asked for "latest" or a link/source, include the upstream commit URL in the final answer.

3. Identify the previous supported base.
   - Read `docs\supported-omegga-runtime.md` first.
   - Prefer `latest_upstream_commit=` from that doc as the merge base.
   - If the doc has no upstream SHA, use repository commit `47a08b84aa3a3270f433cf741c182a546262bf60` as the internal baseline for the original vendored tree.
   - Record old package version, new upstream package version, old upstream SHA, and new upstream SHA before changing files.

4. Stop the live stack before dependency/runtime replacement.
   - A request to update/install latest Omegga implies permission to reset the local Omegga/Brickadia stack.
   - Stop only the local `run-omegga.cmd`/Omegga/Brickadia process tree. Do not kill unrelated user processes.
   - Do not print Brickadia tokens from process command lines in user-facing messages.

5. Bring upstream changes into the vendored tree.
   - Preferred patch path:
     ```powershell
     git diff --binary --find-renames OLD_UPSTREAM_SHA upstream/master -- . > artifacts\omegga-upstream-merge-YYYYMMDD-HHMMSS\upstream.diff
     git apply --3way --directory=omegga-master/omegga-master artifacts\omegga-upstream-merge-YYYYMMDD-HHMMSS\upstream.diff
     ```
   - If path conflicts or nontrivial conflicts make `git apply` unreliable, use archive/manual merge:
     ```powershell
     git archive OLD_UPSTREAM_SHA | tar -x -C artifacts\omegga-upstream-merge-YYYYMMDD-HHMMSS\base
     git archive upstream/master | tar -x -C artifacts\omegga-upstream-merge-YYYYMMDD-HHMMSS\upstream
     ```
   - For generic upstream UI/API files, prefer upstream.
   - For BMF-sensitive files, inspect and preserve local behavior instead of blindly taking upstream.

6. Preserve BMF/Windows patches.
   - Keep Windows-aware config helpers in `src\softconfig.ts`: `getConfigHome(PROJECT_NAME)`, `getSteamCmdFilename()`, and `getGameBinaryPath()`.
   - Keep `src\util\platform.ts` Windows helpers for config home, SteamCMD filename, game binary path, server config directory, post-install scripts, and RPC plugin executable candidates.
   - Keep BMF launcher environment in `run-omegga.cmd`.
   - Keep BMF/UE4SS behavior in `src\brickadia\server.ts`, `src\brickadia\config.ts`, `src\main.ts`, `src\omegga\server.ts`, `src\omegga\wrapper.ts`, `src\omegga\commandInjector.ts`, `src\omegga\commands.ts`, `src\omegga\plugin\plugin_node_safe\proxyOmegga.ts`, `src\omegga\plugin\plugin_node_safe\worker.ts`, `src\omegga\plugin\plugin_node_unsafe.ts`, `src\plugin.ts`, and `templates\windows-ue4ss\...`.
   - Keep BMF package additions in `package.json`: `@noble/hashes`, `socket.io`, `socket.io-client`, `build:bridge`, and `package:bmf` unless the local code no longer needs them.
   - Regenerate `package-lock.json` with `npm install`; do not hand-merge lockfile conflicts.
   - For `src\omegga\plugin.ts`, prefer upstream 1.8+ SQLite plugin storage and NeDB import behavior, but keep local tolerance for plugin docs whose `commands` entries are strings.
   - If local `src\main.ts` imports `getSteamCmdCommand`, ensure `src\updater\steam.ts` exports it and `src\updater\index.ts` re-exports it.
   - Keep the Prometheus exporter wired in `src\webserver\backend\index.ts`: import `setupPrometheusExporter` from `.\prometheus`, call `setupPrometheusExporter(this)` immediately after `setupMetrics(this)`, and keep both calls before the frontend catch-all route. Without this, `/metrics` returns the Omegga web app HTML and Alloy/Grafana do not receive Omegga/BMF metrics.

7. Clean conflicts and rebuild.
   - Remove all conflict markers:
     ```powershell
     rg --hidden -n "<<<<<<<|>>>>>>>|=======" omegga-master\omegga-master docs -g "!node_modules/**" -g "!dist/**"
     ```
   - Install/update dependencies:
     ```powershell
     npm install
     ```
     Run from `omegga-master\omegga-master`.
   - Validate:
     ```powershell
     npm run build:frontend
     npm run build
     npm run dts
     node -p "require('./package.json').version"
     node -p "require('./dist/version.js').VERSION"
     ```

8. Update support tracking.
   - Update `docs\supported-omegga-runtime.md` with the current date, upstream URL/branch, latest upstream SHA/date/subject, upstream package version, supported package version, and validation status.
   - If a commit is created, update `current_supported_fork_commit` to the new local fork commit.
   - If no commit is created, do not imply that `current_supported_fork_commit` includes uncommitted work; say the working tree contains the update.

9. Restart and prove the installed version.
   - Start/check with the BMF helper:
     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\tycox\.codex\skills\bmf-start-server\scripts\Start-BmfLocalStack.ps1" -Mode StartOrCheck -Json
     ```
   - If startup hangs or health is unhealthy, inspect the latest `artifacts\service-start\omegga-skill-*.out.log` and `.err.log`.
   - Common regressions to check first:
     - SteamCMD prompt/path regression from lost Windows `softconfig.ts` helpers.
     - Plugin storage mismatch after upstream DB/SQLite changes.
     - Missing BMF package dependency/script after `package.json` replacement.
     - UE4SS/BMF template provisioning errors.
   - Verify endpoints:
     ```powershell
     Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8080/plugins
     Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8080/metrics
     Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3000/metrics
     Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8080/trpc/session.info
     ```
   - Treat `http://127.0.0.1:8080/metrics` as healthy only when it returns Prometheus text such as `# Omegga / Brickadia Prometheus metrics` with a `text/plain` content type. If it returns `text/html` or `<!DOCTYPE html>`, re-check the `setupPrometheusExporter(this)` wiring in `src\webserver\backend\index.ts`.
   - Use the in-app browser to reload `http://127.0.0.1:8080/plugins?reset=<timestamp>` and verify the visible `.version` text, for example `Omegga v1.8.1 Brickadia CL13530`.

## Final Report

Report only the high-signal facts:

- Omegga website link.
- Visible web-client version.
- Latest upstream commit SHA and link.
- Previous supported SHA/version if relevant.
- Build and live validation results.
- Whether the stack is currently running.
- Any remaining degraded health checks or uncommitted work that affects follow-up.
