#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const DEFAULT_SOCKET_PATH = path.join(
  process.env.APPDATA || "",
  "omegga",
  "steam_installs",
  "main",
  "Brickadia",
  "Binaries",
  "Win64",
  "ue4ss",
  "main",
  "Mods",
  "BMF",
  "runtime",
  "socket.json",
);

function parseArgs(argv) {
  const args = {
    brickId: 1,
    socketPath: process.env.OMEGGA_BMF_SOCKET_PATH || DEFAULT_SOCKET_PATH,
    outJson: "",
    timeoutMs: 15000,
    pollMs: 150,
    restore: true,
    guid: "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const readValue = () => {
      if (index + 1 >= argv.length) throw new Error(`Missing value for ${arg}`);
      index += 1;
      return argv[index];
    };

    if (arg === "--brick-id" || arg === "--brickid") {
      args.brickId = Number(readValue());
    } else if (arg === "--socket" || arg === "--socket-path") {
      args.socketPath = readValue();
    } else if (arg === "--out" || arg === "--out-json") {
      args.outJson = readValue();
    } else if (arg === "--timeout-ms") {
      args.timeoutMs = Number(readValue());
    } else if (arg === "--poll-ms") {
      args.pollMs = Number(readValue());
    } else if (arg === "--no-restore") {
      args.restore = false;
    } else if (arg === "--guid") {
      args.guid = readValue();
    } else if (arg === "--help" || arg === "-h") {
      args.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isInteger(args.brickId) || args.brickId <= 0) {
    throw new Error("--brick-id must be a positive integer.");
  }
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs < 1000) {
    throw new Error("--timeout-ms must be at least 1000.");
  }
  if (!Number.isFinite(args.pollMs) || args.pollMs < 25) {
    throw new Error("--poll-ms must be at least 25.");
  }
  if (args.guid && !/^[A-Za-z0-9_:%-.]+$/.test(args.guid)) {
    throw new Error("--guid must match BMF runtime GUID syntax.");
  }
  return args;
}

function usage() {
  return [
    "Usage: node scripts/validate-bmf-runtime-brick-physical.js [options]",
    "",
    "Options:",
    "  --brick-id <id>       Runtime brick id to use for the canary. Default: 1",
    "  --socket-path <path>  Path to Mods/BMF/runtime/socket.json.",
    "  --out-json <path>     Artifact path. Default: artifacts/local/bmf-runtime-brick-physical-canary.json",
    "  --timeout-ms <ms>     Per-command timeout. Default: 15000",
    "  --poll-ms <ms>        Runtime status polling interval. Default: 150",
    "  --guid <id>           Bind the brick id to a GUID and exercise bmf.bricks.runtime.set-guid.",
    "  --no-restore          Do not restore original state. Intended only for debugging.",
  ].join(os.EOL);
}

function mkdirp(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function readJson(filePath) {
  const text = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
  return JSON.parse(text);
}

function parseKeyValueResponse(response) {
  const lines = String(response || "").split(/\r?\n/);
  const fields = {};
  for (const line of lines) {
    const index = line.indexOf("=");
    if (index <= 0) continue;
    const key = line.slice(0, index).trim();
    if (!key) continue;
    fields[key] = line.slice(index + 1).trim();
  }
  return { fields, lines: lines.filter(Boolean) };
}

function asInt(value, fallback = null) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.trunc(parsed) : fallback;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class BmfSocketClient {
  constructor(meta, options) {
    this.meta = meta;
    this.options = options;
    this.socket = null;
    this.buffer = "";
    this.pending = new Map();
    this.records = [];
  }

  async connect() {
    await new Promise((resolve, reject) => {
      const socket = net.createConnection(
        {
          host: this.meta.host,
          port: this.meta.port,
        },
        () => {
          this.socket = socket;
          this.write({
            type: "hello",
            role: "plugin",
            source: "bmf.runtime-brick-physical-canary",
            token: this.meta.token,
            version: 1,
          });
          resolve();
        },
      );
      socket.setEncoding("utf8");
      socket.setNoDelay(true);
      socket.setTimeout(this.options.timeoutMs);
      socket.on("data", (chunk) => this.handleData(chunk));
      socket.on("timeout", () => {
        reject(
          new Error(
            `Timed out connecting to BMF socket ${this.meta.host}:${this.meta.port}.`,
          ),
        );
        socket.destroy();
      });
      socket.on("error", (error) => {
        for (const pending of this.pending.values()) pending.reject(error);
        this.pending.clear();
        reject(error);
      });
      socket.on("close", () => {
        for (const pending of this.pending.values()) {
          pending.reject(new Error("BMF socket closed before response."));
        }
        this.pending.clear();
      });
    });
    if (this.socket) this.socket.setTimeout(0);
  }

  close() {
    if (this.socket && !this.socket.destroyed) this.socket.end();
  }

  write(message) {
    if (!this.socket || this.socket.destroyed || !this.socket.writable) {
      throw new Error("BMF socket is not writable.");
    }
    this.socket.write(`${JSON.stringify(message)}\n`);
  }

  handleData(chunk) {
    this.buffer += String(chunk || "");
    let index = this.buffer.indexOf("\n");
    while (index >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (line) this.handleLine(line);
      index = this.buffer.indexOf("\n");
    }
  }

  handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.records.push({ type: "invalid-json", line });
      return;
    }

    this.records.push({
      type: message.type || "",
      id: message.id || "",
      ok: message.ok,
      detail: message.detail || "",
      source: message.source || "",
      ts: message.ts || "",
    });

    if (message.type === "ping") {
      this.write({
        type: "pong",
        source: "bmf.runtime-brick-physical-canary",
        id: message.id,
        ts: new Date().toISOString(),
      });
      return;
    }

    if (message.type !== "response" || !message.id) return;
    const pending = this.pending.get(String(message.id));
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pending.delete(String(message.id));
    pending.resolve(message);
  }

  command(command) {
    const id = `runtime-physical-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
    const startedAt = Date.now();
    this.write({
      type: "command",
      id,
      command,
      source: "bmf.runtime-brick-physical-canary",
      issuedAt: startedAt,
      issuedAtMs: startedAt,
      deadlineMs: startedAt + this.options.timeoutMs,
      serviceClass: "interactive",
    });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for BMF response to: ${command}`));
      }, this.options.timeoutMs);
      this.pending.set(id, {
        command,
        timer,
        resolve: (message) => {
          const parsed = parseKeyValueResponse(message.response || "");
          resolve({
            id,
            command,
            durationMs: Date.now() - startedAt,
            envelope: {
              ok: message.ok === true,
              detail: message.detail || "",
              source: message.source || "",
              ts: message.ts || "",
              type: message.type || "",
            },
            fields: parsed.fields,
            lines: parsed.lines,
            response: message.response || "",
          });
        },
        reject,
      });
    });
  }
}

async function waitForRuntimeSequence(client, sequence, operation, options) {
  const deadline = Date.now() + options.timeoutMs;
  let latest = null;
  while (Date.now() < deadline) {
    latest = await client.command("bmf.bricks.runtime.status");
    if (
      String(latest.fields.sequence || "") === String(sequence) &&
      (!operation || String(latest.fields.operation || "") === operation)
    ) {
      return latest;
    }
    await sleep(options.pollMs);
  }
  const latestText = latest
    ? ` latest sequence=${latest.fields.sequence || ""} operation=${latest.fields.operation || ""}`
    : "";
  throw new Error(
    `Timed out waiting for runtime operation sequence=${sequence} operation=${operation}.${latestText}`,
  );
}

async function queueAndWait(client, command, operation, options) {
  const queued = await client.command(command);
  const sequence = queued.fields.sequence;
  if (!sequence) {
    throw new Error(`Command did not return a runtime sequence: ${command}`);
  }
  const completed = await waitForRuntimeSequence(
    client,
    sequence,
    operation,
    options,
  );
  return { queued, completed };
}

async function queuePhysicalSetAndWait(
  client,
  args,
  commands,
  visible,
  collision,
  operation,
  options,
) {
  const deadline = Date.now() + options.timeoutMs;
  let latest = null;
  do {
    latest = await queueAndWait(
      client,
      physicalSetCommand(args, visible, collision),
      operation,
      options,
    );
    if (commands) {
      commands.push(slimResult(latest.queued));
      commands.push(slimResult(latest.completed));
    }

    const code = String(latest.completed.fields.code || "").toUpperCase();
    if (code !== "BRICK_GRID_CONTEXT_SCAN_PENDING") {
      return latest;
    }
    await sleep(
      Math.min(
        Math.max(options.pollMs * 4, 500),
        Math.max(0, deadline - Date.now()),
      ),
    );
  } while (Date.now() < deadline);

  return latest;
}

function slimResult(result) {
  const compact = compactRuntimeDiagnostics(result.fields, result.lines);
  return {
    id: result.id,
    command: result.command,
    durationMs: result.durationMs,
    envelope: result.envelope,
    fields: compact.fields,
    lineCount: result.lines.length,
    omittedDiagnosticLines: compact.omittedDiagnosticLines,
    lines: compact.lines,
  };
}

function compactRuntimeDiagnostics(fields, lines) {
  const noisyPrefixes = ["grid_context_candidate."];
  const keepFields = {};
  for (const [key, value] of Object.entries(fields || {})) {
    if (noisyPrefixes.some((prefix) => key.startsWith(prefix))) continue;
    keepFields[key] = value;
  }

  const compactLines = [];
  let omittedDiagnosticLines = 0;
  for (const line of lines || []) {
    const index = line.indexOf("=");
    const key = index > 0 ? line.slice(0, index).trim() : "";
    if (noisyPrefixes.some((prefix) => key.startsWith(prefix))) {
      omittedDiagnosticLines += 1;
      continue;
    }
    compactLines.push(line);
  }

  return {
    fields: keepFields,
    lines: compactLines,
    omittedDiagnosticLines,
  };
}

function assertField(errors, fields, key, expected, label) {
  if (String(fields[key] || "") !== String(expected)) {
    errors.push(
      `${label}: expected ${key}=${expected}, got ${fields[key] || "<missing>"}.`,
    );
  }
}

async function bindGuidIfRequested(client, args, commands, errors) {
  if (!args.guid) return;
  const bind = await client.command(
    `bmf.bricks.runtime.bind guid=${args.guid} tag=${args.guid} brickid=${args.brickId}`,
  );
  commands.push(slimResult(bind));
  assertField(errors, bind.fields, "ok", "true", "runtime guid bind");
  assertField(errors, bind.fields, "code", "OK", "runtime guid bind");
}

function physicalSetCommand(args, visible, collision) {
  if (args.guid) {
    return [
      "bmf.bricks.runtime.set-guid",
      `guid=${args.guid}`,
      `tag=${args.guid}`,
      `visible=${visible}`,
      `collision=${collision}`,
      "confirm=brick-runtime",
    ].join(" ");
  }
  return [
    "bmf.bricks.runtime.set",
    `brickid=${args.brickId}`,
    `visible=${visible}`,
    `collision=${collision}`,
    "confirm=brick-runtime",
  ].join(" ");
}

function afterVisibleField(args) {
  return args.guid ? "item.1.after_visible" : "after_visible";
}

function afterCollisionField(args) {
  return args.guid
    ? "item.1.after_collision_channels"
    : "after_collision_channels";
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return 0;
  }

  const root = path.resolve(__dirname, "..");
  const outJson = args.outJson
    ? path.resolve(args.outJson)
    : path.join(
        root,
        "artifacts",
        "local",
        "bmf-runtime-brick-physical-canary.json",
      );
  const startedAt = new Date().toISOString();
  const errors = [];
  const commands = [];
  const evidence = [];
  let originalVisible = null;
  let originalCollision = null;
  let client = null;

  const socketPath = path.resolve(args.socketPath);
  const socketMeta = readJson(socketPath);
  const publicSocketMeta = {
    path: socketPath,
    enabled: socketMeta.enabled === true,
    available: socketMeta.available === true,
    started: socketMeta.started === true,
    host: socketMeta.host,
    port: socketMeta.port,
    workerMode: socketMeta.workerMode,
    workerStarted: socketMeta.workerStarted,
    updatedAt: socketMeta.updatedAt,
    tokenPresent:
      typeof socketMeta.token === "string" && socketMeta.token.length > 0,
  };
  evidence.push({
    kind: "json",
    path: socketPath,
    summary:
      "BMF socket metadata used for live canary; token redacted in artifact.",
  });

  if (
    !publicSocketMeta.enabled ||
    !publicSocketMeta.started ||
    !publicSocketMeta.port ||
    !publicSocketMeta.tokenPresent
  ) {
    errors.push(
      "BMF socket metadata is not enabled, started, or authenticated.",
    );
  }

  try {
    if (errors.length === 0) {
      client = new BmfSocketClient(socketMeta, args);
      await client.connect();

      const serverStatus = await client.command("bmf.server.status");
      commands.push(slimResult(serverStatus));
      if (serverStatus.fields.bmf_status !== "running") {
        errors.push(
          `Expected bmf_status=running, got ${serverStatus.fields.bmf_status || "<missing>"}.`,
        );
      }

      const initial = await queueAndWait(
        client,
        `bmf.bricks.runtime.inspect brickid=${args.brickId}`,
        "inspect",
        args,
      );
      commands.push(slimResult(initial.queued));
      commands.push(slimResult(initial.completed));

      originalVisible = asInt(initial.completed.fields.visible);
      originalCollision = asInt(initial.completed.fields.collision_channels);
      if (originalVisible === null || originalCollision === null) {
        errors.push(
          "Initial runtime inspect did not report visible and collision_channels.",
        );
      }

      await bindGuidIfRequested(client, args, commands, errors);

      const hide = await queuePhysicalSetAndWait(
        client,
        args,
        commands,
        "false",
        "0",
        args.guid ? "set-guid" : "set",
        args,
      );
      assertField(
        errors,
        hide.completed.fields,
        "ok",
        "true",
        "hide set result",
      );
      assertField(
        errors,
        hide.completed.fields,
        "code",
        "OK",
        "hide set result",
      );
      assertField(
        errors,
        hide.completed.fields,
        afterVisibleField(args),
        "0",
        "hide set result",
      );
      assertField(
        errors,
        hide.completed.fields,
        afterCollisionField(args),
        "0",
        "hide set result",
      );

      const hiddenInspect = await queueAndWait(
        client,
        `bmf.bricks.runtime.inspect brickid=${args.brickId}`,
        "inspect",
        args,
      );
      commands.push(slimResult(hiddenInspect.queued));
      commands.push(slimResult(hiddenInspect.completed));
      assertField(
        errors,
        hiddenInspect.completed.fields,
        "visible",
        "0",
        "hidden inspect",
      );
      assertField(
        errors,
        hiddenInspect.completed.fields,
        "collision_channels",
        "0",
        "hidden inspect",
      );

      if (
        args.restore &&
        originalVisible !== null &&
        originalCollision !== null
      ) {
        const visibleArg = originalVisible === 0 ? "false" : "true";
        const restore = await queuePhysicalSetAndWait(
          client,
          args,
          commands,
          visibleArg,
          String(originalCollision),
          args.guid ? "set-guid" : "set",
          args,
        );
        assertField(
          errors,
          restore.completed.fields,
          "ok",
          "true",
          "restore set result",
        );
        assertField(
          errors,
          restore.completed.fields,
          "code",
          "OK",
          "restore set result",
        );
        assertField(
          errors,
          restore.completed.fields,
          afterVisibleField(args),
          String(originalVisible),
          "restore set result",
        );
        assertField(
          errors,
          restore.completed.fields,
          afterCollisionField(args),
          String(originalCollision),
          "restore set result",
        );

        const restoredInspect = await queueAndWait(
          client,
          `bmf.bricks.runtime.inspect brickid=${args.brickId}`,
          "inspect",
          args,
        );
        commands.push(slimResult(restoredInspect.queued));
        commands.push(slimResult(restoredInspect.completed));
        assertField(
          errors,
          restoredInspect.completed.fields,
          "visible",
          String(originalVisible),
          "restored inspect",
        );
        assertField(
          errors,
          restoredInspect.completed.fields,
          "collision_channels",
          String(originalCollision),
          "restored inspect",
        );
      }
    }
  } catch (error) {
    errors.push(error && error.message ? error.message : String(error));
  } finally {
    if (
      client &&
      args.restore &&
      originalVisible !== null &&
      originalCollision !== null
    ) {
      try {
        const visibleArg = originalVisible === 0 ? "false" : "true";
        await queuePhysicalSetAndWait(
          client,
          args,
          null,
          visibleArg,
          String(originalCollision),
          args.guid ? "set-guid" : "set",
          args,
        );
      } catch {
        // The main command log above already captures the failure path. Avoid
        // hiding it with a best-effort cleanup error.
      }
    }
    if (client) client.close();
  }

  const result = {
    schemaVersion: 1,
    feature: "bmf.runtime-brick-physical",
    status: errors.length === 0 ? "passed" : "failed",
    validationLevel: "L3 Live Server; no player required",
    startedAt,
    finishedAt: new Date().toISOString(),
    guardrails: {
      broadUObjectScans: false,
      clearRegion: false,
      explicitRuntimeBrickOnly: true,
      restoresOriginalState: args.restore,
      socketOnly: true,
    },
    data: {
      brickId: args.brickId,
      guid: args.guid || null,
      socket: publicSocketMeta,
      original: {
        visible: originalVisible,
        collisionChannels: originalCollision,
      },
      commands,
      socketRecords: client ? client.records.slice(-100) : [],
    },
    evidence,
    errors,
  };

  mkdirp(outJson);
  fs.writeFileSync(outJson, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  console.log(JSON.stringify(result, null, 2));
  return errors.length === 0 ? 0 : 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error) => {
    console.error(error && error.stack ? error.stack : error);
    process.exitCode = 1;
  });
