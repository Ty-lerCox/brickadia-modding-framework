# BMF Overnight Strategy

Purpose: maximize unattended BMF progress while the user is away, without
depending on a live human-controlled Brickadia client.

Assumption: "tonight" means the next unattended overnight run from this planning
session. Use unique timestamped artifact names so repeated runs do not overwrite
evidence.

## Core Constraint

BMF has two workspaces with different jobs:

- `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia`
  - Reverse-engineering workspace and current dedicated-server control point.
  - Use this for server launches, UE4SS bridge probes, archive parsing,
    command transport, and discovery reports.
- `C:\Users\tycox\OneDrive\Documents\GitHub\bmf`
  - Product/framework workspace.
  - Use this for public API design, package structure, docs, examples, canary
    contracts, and BMF-owned generated artifacts.

Do not copy rough reverse-engineering experiments directly into BMF as stable
framework code. Promote only proven, documented surfaces.

## Current Assets

- Headless dedicated server start:
  - `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\brickadia-ue4ss-re\scripts\start-bridge-test-server.ps1`
- Bridge RPC sender:
  - `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\brickadia-ue4ss-re\scripts\send-bridge-rpc.js`
- Existing bridge directory default:
  - `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\omegga-master\omegga-master\data\ue4ss-bridge-test-7799`
- Server data directory:
  - `C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\omegga-master\omegga-master\data`
- New local world fixtures:
  - `C:\Users\tycox\AppData\Local\Brickadia\Saved\Worlds\threecars.brdb`
  - `C:\Users\tycox\AppData\Local\Brickadia\Saved\Worlds\couplecars.brdb`
- Archive/entity tools:
  - `brickadia-ue4ss-re\scripts\list-world-entities.js`
  - `brickadia-ue4ss-re\scripts\inspect-brz.js`
  - `brickadia-ue4ss-re\scripts\inspect-brdb-schema.js`
  - `brickadia-ue4ss-re\scripts\convert-brz-to-brdb.js`
  - `brickadia-ue4ss-re\scripts\build-prefab-world-brdb.js`
- Existing canary/test runners:
  - `brickadia-ue4ss-re\scripts\run-cl12960-full-tests.ps1 -Bundle CL13530`
  - `brickadia-ue4ss-re\scripts\run-cl12960-chat-canary-tests.ps1 -Bundle CL13530`
  - `brickadia-ue4ss-re\scripts\run-cl12960-world-export-canary-tests.ps1 -Bundle CL13530`

## Unattended Validation Rule

Prefer work that can reach `L0 Static`, `L1 Boot`, or `L2 Headless`.

Do not spend the overnight run blocked on true `L3 Live Player` features unless
a client/controller is already proven available before the run starts.

Player-controller dependent work can still produce value by writing discovery
reports, test harnesses, mock fixtures, and exact manual validation checklists.

## Safety Rules

- Use only timestamped names beginning with `BMF_` for new worlds, bundles,
  logs, and artifacts.
- Never overwrite `threecars.brdb`, `couplecars.brdb`, `Save.brdb`, or other
  user-authored source fixtures.
- Copy fixtures into the server data directory before loading them.
- Stage `.brdb` files before first `BR.World.LoadAdditive` attempts. Missing
  first loads can poison Brickadia's bundle cache until restart.
- Use large offsets for repeated additive loads, such as `20000 0 1000`.
- If the server exits/crashes twice in the same lane, stop that lane and switch
  to static work.
- Avoid `players.list` as a prerequisite for prefab/native readiness on CL13530
  unless the feature under test is specifically player listing.
- Keep native paste/replay under experimental reports unless a live controller
  is available and current.

## Work Lane Priority

### Lane 1: BMF Package Skeleton and Headless Canaries

Priority: highest.

Reason: this work does not need a player and creates the foundation for all
future goal-mode runs.

Tasks:

- Create BMF package skeleton.
- Add manifest shape and compatibility matrix shape.
- Add canary artifact schema.
- Add docs for install, health, and first plugin.
- Define `bmf.version` and `bmf.health` expected outputs.
- Build a static validation script or checklist.

Validation:

- `L0 Static`: files exist, manifest parses, docs exist.
- `L1 Boot` later: BMF mod loads under UE4SS.
- Artifact target: `bmf\artifacts\overnight\<timestamp>\package-skeleton.json`.

Stop condition:

- None, unless the BMF folder is unexpectedly not writable.

### Lane 2: Headless Server Boot and Bridge Health

Priority: highest.

Reason: every future runtime feature needs a reliable hidden server launch and
bridge health proof.

Tasks:

- Start a clean hidden dedicated server with `start-bridge-test-server.ps1`.
- Verify bridge status, `bridge.ping`, and `Omegga.Bridge.Echo`.
- Save PID, port, bridge directory, UE4SS log path, Brickadia log path.
- Produce an unattended health artifact.

Validation:

- `L1 Boot`: server stays running and bridge status exists.
- `L2 Headless`: `bridge.ping` and echo command return successfully.
- Artifact target: `bmf\artifacts\overnight\<timestamp>\server-health.json`.

Stop condition:

- If the server fails to boot twice, do not keep restarting. Switch to static
  archive and BMF skeleton work.

### Lane 3: Three-Cars Offline Archive Fixture

Priority: high.

Reason: the new `threecars.brdb` fixture lets BMF validate vehicle/entity
archive parsing without a connected player.

Tasks:

- Copy, do not move, `threecars.brdb` into a BMF fixture artifact directory.
- Run `list-world-entities.js` against `threecars.brdb`.
- Run the same against `couplecars.brdb`.
- Compare entity counts, dynamic actor groups, grid IDs, component chunk counts,
  wire counts, and entity graph completeness.
- Write a normalized fixture summary for BMF tests.

Validation:

- `L0 Static`: both BRDB files parse and produce JSON.
- Pass criteria:
  - `threecars.brdb` parses with no schema/decompression error.
  - Dynamic actor groups are detected or the report clearly proves none were
    found.
  - The report identifies stable entity graph fields that BMF can use later.
- Artifact targets:
  - `bmf\artifacts\overnight\<timestamp>\threecars-entities.json`
  - `bmf\artifacts\overnight\<timestamp>\couplecars-entities.json`
  - `bmf\artifacts\overnight\<timestamp>\vehicle-fixture-comparison.md`

Stop condition:

- If parsing fails, capture the exact error and move to schema/tooling work.

### Lane 4: Three-Cars Additive Load Transport

Priority: high after Lane 2 passes.

Reason: this is the best unattended runtime proof for world/prefab work.

Tasks:

- Copy `threecars.brdb` into:
  - `omegga-master\omegga-master\data\Saved\Worlds\BMF_ThreeCarsFixture.brdb`
- Start hidden server and bridge.
- Send:
  - `Omegga.Bridge.ForceConsoleExecutor consolemanager BR.World.LoadAdditive BMF_ThreeCarsFixture 20000 0 1000 0`
- Watch `Brickadia.log` for additive load success lines.
- Send:
  - `BR.World.SaveAs "BMF_AfterThreeCarsAdditive_<timestamp>"`
- Parse the saved output `.brdb` with `list-world-entities.js`.
- Compare the saved output against the original `threecars.brdb`.

Validation:

- `L2 Headless`: command accepted and server log shows additive load success.
- Pass criteria:
  - Server remains alive.
  - Additive load logs the expected success sequence.
  - SaveAs writes a new `.brdb`.
  - Saved output parses.
- Artifact targets:
  - `bmf\artifacts\overnight\<timestamp>\threecars-additive-rpc.json`
  - `bmf\artifacts\overnight\<timestamp>\threecars-additive-log-evidence.txt`
  - `bmf\artifacts\overnight\<timestamp>\after-threecars-entities.json`

Stop condition:

- If `LoadAdditive` fails once because the bundle is missing, restart the server
  before retrying with a correctly staged bundle.
- If `LoadAdditive` crashes the server twice, stop runtime vehicle work and
  continue offline parsing.

### Lane 5: Mock Player Fixtures for API Wrapper Tests

Priority: medium.

Reason: fake player data cannot prove Brickadia behavior, but it can validate
BMF API wrapper semantics while no human player is available.

Tasks:

- Create fixture shapes for:
  - empty player list
  - one player with UUID, username, display name, player state path, controller
    path, role list
  - malformed/incomplete player record
- Define how `BMF.players.list()`, `BMF.players.find()`, and name-normalization
  should behave against those fixtures.
- Write expected output examples into docs/tests.

Validation:

- `L0 Static`: fixture JSON parses and expected output is documented.
- This is not an `L3 Live Player` substitute.
- Artifact target: `bmf\artifacts\overnight\<timestamp>\player-fixtures.json`.

Stop condition:

- None.

### Lane 6: Player-Controller Dependency Research

Priority: medium, report-only unless a controller is already available.

Reason: future work needs to know exactly which features cannot be validated
unattended.

Tasks:

- Audit scripts and notes for current player-controller requirements.
- Classify each TODO feature as:
  - no player needed
  - mockable only
  - live player needed
  - live player plus second client needed
  - unsafe native context needed
- Investigate whether an automated client can reliably connect using
  `start-client-bridge-connect.ps1`.
- Do not make the overnight run depend on this unless a short preflight proves
  it works.

Validation:

- `L0 Static`: classification report exists.
- Optional `L3 Live Player`: only if client connect preflight is already
  successful.
- Artifact target: `bmf\artifacts\overnight\<timestamp>\player-controller-dependency-report.md`.

Stop condition:

- If client launch asks for auth, UI interaction, update prompts, or exits
  early, stop live-client work immediately.

### Lane 7: Permissions, Applicator, and Minigame Static Discovery

Priority: medium.

Reason: this prepares the high-value moderation work without pretending it can
be proven headlessly.

Tasks:

- Search binary strings, prior notes, dumps, and scripts for:
  - applicator
  - component
  - SpawnItem
  - role
  - permission
  - manipulator
  - connector
  - minigame
  - team
- Produce a discovery report with candidate classes/functions/properties.
- List what each candidate would need for safe live validation.

Validation:

- `L0 Static`: report exists and cites evidence paths/lines.
- `L3 Live Player` remains required for real enforcement.
- Artifact targets:
  - `bmf\artifacts\overnight\<timestamp>\applicator-permission-discovery.md`
  - `bmf\artifacts\overnight\<timestamp>\minigame-discovery.md`

Stop condition:

- None.

## Features to Avoid Overnight Unless Pre-Seeded

These are poor unattended targets without a live, connected client:

- Visible whisper delivery.
- Player health reads.
- Player position reads.
- Avatar reads/mutation.
- Applicator `SpawnItem` enforcement.
- Manipulator/connector enforcement.
- Role assignment runtime effect.
- Minigame join/team/scoring flow.
- Native prefab paste from client/controller context.

If the user wants one of these validated overnight, the best setup is a
pre-seeded live session before leaving:

1. Start hidden dedicated server.
2. Launch/connect one Brickadia client.
3. Prove server-side player/controller context exists.
4. Leave both server and client running.
5. Overnight tasks may use that live context, but must stop if the context goes
   stale.

Without that pre-seed, treat these as discovery/report work only.

## Recommended Overnight Queue

Run in this order:

1. Lane 1: package skeleton and static canary contracts.
2. Lane 2: server boot and bridge health.
3. Lane 3: offline `threecars.brdb` and `couplecars.brdb` entity reports.
4. Lane 4: staged `BMF_ThreeCarsFixture` additive load and SaveAs proof.
5. Lane 5: mock player fixtures for BMF wrapper tests.
6. Lane 7: static discovery for applicator permissions and minigames.
7. Lane 6: client automation research only if the earlier lanes are stable.

This order keeps the run productive even if the server crashes or the client
cannot be automated.

## Overnight Summary Template

Every unattended run should end by writing:

```text
Run started:
Run finished:
Server build:
UE4SS bundle:
Lanes attempted:
Lanes passed:
Lanes blocked:
Artifacts:
Crashes/exits:
Next recommended task:
Manual validation needed:
```

Summary artifact target:

```text
bmf\artifacts\overnight\<timestamp>\summary.md
```

## Immediate Next Decision

For the actual overnight work, choose one of these modes:

- `Headless Only`: safest. No client launch. Focus on BMF skeleton, bridge
  health, archive parsing, additive load, and discovery reports.
- `Pre-Seeded Client`: user joins or allows the client to connect before
  leaving. Allows some player/controller checks, but still fragile.
- `Experimental Client Automation`: Codex tries to launch/connect the client.
  Highest risk of stalling on auth, UI, update, focus, or graphics issues.

Recommended mode for tonight: `Headless Only`.
