---
name: brickadia-client-join
description: Fast, proactive reconnect and verification for the local Brickadia Steam client using the repository's Python join script. Use when Brickadia testing would benefit from quickly ensuring the client is connected, after server starts/restarts, when the client may be on the main menu or disconnected, when the user asks Codex to join/reconnect/run/monitor/validate, or when connection ambiguity is slowing iteration for the local server at 127.0.0.1:7777 from C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia.
---

# Brickadia Client Join

## Core Workflow

Use the existing repo script, not ad hoc UI tab clicking. The default command is:

- `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\run-join-brickadia-local.cmd`

That wrapper runs:

- `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\join-brickadia-local.py`

The Python script waits for any already-held mouse buttons, modifier keys, or XInput controller controls to be released, focuses `BrickadiaSteam-Win64-Shipping.exe`, temporarily blocks other keyboard/mouse input while sending automation, verifies Brickadia is still the foreground window before injecting each command step, opens the Brickadia console with the grave-accent scancode `0x29`, types `open <address>`, presses Enter, validates the client log, and returns focus to the previously focused window without changing that window's minimized/maximized state. The default address is `127.0.0.1`.

## Fast Default

Prefer the default script-first path when speed matters. If the user asks to run, join, reconnect, or continue Brickadia testing, run `.\run-join-brickadia-local.cmd 127.0.0.1` immediately instead of doing a slow UI or screenshot preflight.

Use the script proactively when it could increase iteration speed, including after server starts/restarts, after map or networking changes, when the client is on the main menu, when logs are stale or ambiguous, or before validating multiplayer behavior. Do not wait for explicit permission when the current Brickadia task clearly benefits from reconnecting the client.

Only skip the script when the freshest log evidence clearly shows the client is already connected and the user is asking for passive monitoring. In that case, leave it alone and check again after 20 seconds. If the state is ambiguous, stale, or likely disconnected, run the script.

## Quick Log Check

Check whether the client is already connected from the latest relevant client log lines:

```powershell
Select-String -Path "$env:LOCALAPPDATA\Brickadia\Saved\Logs\Brickadia.log" -Pattern "LoadMap: /Game/Maps/MainMenu|Browse: 127\.0\.0\.1|LoadMap: 127\.0\.0\.1|Ty joined the game|NetworkFailure|Connection TIMED OUT|UNetConnection::Close:.*RemoteAddr: 127\.0\.0\.1|Attempting to connect|Welcomed by server" | Select-Object -Last 80 | ForEach-Object { $_.Line }
```

Treat the client as connected when the newest connection-state evidence is a successful local sequence:

- `Browse: 127.0.0.1...`
- `Welcomed by server`
- `LoadMap: 127.0.0.1//Game/Maps/Plate/Plate`
- `Ty joined the game.`

Treat it as disconnected when newer evidence shows main menu load, local connection close, timeout, or network failure.

## Run Join

Run this default command from the Brickadia repo:

```powershell
.\run-join-brickadia-local.cmd 127.0.0.1
```

The wrapper finds Python 3 via `PYTHON_EXE`, `py -3`, or `python`, then runs `join-brickadia-local.py`.

If Python is missing, install it or set `PYTHON_EXE` to the Python executable path.

The script waits for already-held mouse buttons, modifier keys, and XInput controller buttons/triggers/sticks to release, then blocks other keyboard/mouse input while focusing the client and sending the console command. It always returns focus to the previously active window after validation. Use `--no-block-input` only when intentionally debugging the input sequence.

## Validate

After running, wait 5 seconds and re-read the client log. If the connection is still loading or unclear, wait another 10-15 seconds and check again. Report success only when a fresh post-run sequence shows local browse/connect/load/join, for example:

```text
Browse: 127.0.0.1//Game/Maps/MainMenu/MainMenu
UPendingNetGame::SendInitialJoin ... RemoteAddr: 127.0.0.1:7777
Welcomed by server
LoadMap: 127.0.0.1//Game/Maps/Plate/Plate
Ty joined the game.
```

If no fresh log attempt appears, run the script one more time quickly. If the second run still produces no fresh attempt, capture a screenshot of the Brickadia window and inspect whether it is on the main menu, in the console, loading, or already in-world. The known failure mode is the console opener or text entry not landing in the game window.

## Notes

- The grave-accent key is the working console opener; do not call it F1.
- The successful Python form sends scancode `0x29`.
- Prefer the console command path over the server browser UI.
- Use absolute paths in user-facing file references.
