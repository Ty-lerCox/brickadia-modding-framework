const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const VERSION = "0.1.0";
const DEFAULT_RECORD_LIMIT = 500;
const DEFAULT_STATUS_RECORD_LIMIT = 100;
const DEFAULT_MAX_PENDING_SOCKET_COMMANDS = 64;
const DEFAULT_MAX_SOCKET_BUFFER_BYTES = 256 * 1024;
const DEFAULT_MAX_SOCKET_COMMAND_BYTES = 64 * 1024;
const GUARDRAILS = [
  "observe-existing-traffic-only",
  "socket-only-live-traffic",
  "do-not-add-ui-driven-server-probes",
  "bound-retained-record-count",
  "bound-pending-socket-commands",
  "bound-socket-input-buffer",
  "redact-secrets-before-display-or-export",
  "do-not-silently-fall-back-to-files",
];
const SECRET_KEY_PATTERN =
  /(token|secret|password|api[-_]?key|authorization|bearer|credential)/i;
const PRIVATE_IPV4_PATTERN =
  /\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b/g;

function asNumber(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function asBoolean(value, fallback) {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "1", "yes", "on"].includes(normalized)) return true;
    if (["false", "0", "no", "off"].includes(normalized)) return false;
  }
  return fallback;
}

function compactObject(value) {
  const result = {};
  for (const [key, next] of Object.entries(value || {})) {
    if (next !== undefined && next !== null && next !== "") {
      result[key] = next;
    }
  }
  return result;
}

function isoSeconds(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function safeJsonParse(text) {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch (error) {
    return { ok: false, error };
  }
}

function readJsonFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null;
  const parsed = safeJsonParse(fs.readFileSync(filePath, "utf8"));
  return parsed.ok && parsed.value && typeof parsed.value === "object"
    ? parsed.value
    : null;
}

function env(name) {
  return String(process.env[name] || "").trim();
}

function standardRuntimeDir() {
  const appData =
    env("APPDATA") || path.join(os.homedir(), "AppData", "Roaming");
  return path.resolve(
    appData,
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
  );
}

function commandName(commandText) {
  return (
    String(commandText || "")
      .trim()
      .split(/\s+/)[0] || ""
  );
}

function redactCommandText(commandText) {
  return String(commandText || "").replace(
    /\b([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|authorization|credential)[A-Za-z0-9_.-]*)=([^ \t\r\n]+)/gi,
    "$1=[redacted]",
  );
}

function redactValue(value, options = {}, seen = new WeakSet()) {
  let redactions = 0;

  function visit(next, key, depth) {
    if (SECRET_KEY_PATTERN.test(String(key || ""))) {
      redactions += 1;
      return "[redacted]";
    }

    if (next === null || next === undefined) return next;

    if (typeof next === "string") {
      let text = next.replace(
        /\b(Bearer|Token)\s+[A-Za-z0-9._~+/=-]+/gi,
        (_match, scheme) => {
          redactions += 1;
          return `${scheme} [redacted]`;
        },
      );
      text = text.replace(
        /\b([A-Za-z0-9_.-]*(?:token|secret|password|api[_-]?key|authorization|credential)[A-Za-z0-9_.-]*)=([^ \t\r\n&]+)/gi,
        (_match, name) => {
          redactions += 1;
          return `${name}=[redacted]`;
        },
      );
      if (options.redactPrivateIps) {
        text = text.replace(PRIVATE_IPV4_PATTERN, () => {
          redactions += 1;
          return "[private-ip]";
        });
      }
      return text;
    }

    if (typeof next !== "object") return next;
    if (depth > asNumber(options.maxDepth, 8)) return "[max-depth]";
    if (seen.has(next)) return "[circular]";
    seen.add(next);

    if (Array.isArray(next)) {
      return next.map((item, index) => visit(item, index, depth + 1));
    }

    const clone = {};
    for (const [childKey, childValue] of Object.entries(next)) {
      clone[childKey] = visit(childValue, childKey, depth + 1);
    }
    return clone;
  }

  return {
    value: visit(value, "", 0),
    redactions,
  };
}

function parseKeyValueResponse(text) {
  const lines = String(text || "").split(/\r?\n/);
  const fields = {};
  for (const line of lines) {
    const match = line.match(/^([^=\s]+)=(.*)$/);
    if (match) fields[match[1]] = match[2];
  }
  const okField = String(fields.ok || "")
    .trim()
    .toLowerCase();
  return {
    ok: okField === "true" || okField === "1" || okField === "yes",
    detail: fields.detail || "",
    command: fields.command || "",
    fields,
    lines: lines.filter(Boolean),
    text: String(text || ""),
  };
}

function normalizeEventRecord(record, message, options) {
  const data = record && typeof record.data === "object" ? record.data : {};
  const payload =
    data.payload && typeof data.payload === "object" ? data.payload : {};
  const bmf =
    payload._bmf && typeof payload._bmf === "object" ? payload._bmf : {};
  const redacted = redactValue(payload, options);
  return {
    id: String(bmf.eventId || bmf.event_id || message.id || data.id || ""),
    timestamp: String(
      record.ts ||
        bmf.emittedAt ||
        bmf.emitted_at ||
        message.ts ||
        isoSeconds(),
    ),
    type: "event",
    event: String(data.event || bmf.event || message.event || ""),
    command: "",
    source: String(bmf.source || record.source || message.source || "bmf"),
    transport: options.transport || "unknown",
    status: data.ok === false ? "error" : "ok",
    payload: redacted.value,
    durationMs: Number.isFinite(Number(data.durationMs))
      ? Number(data.durationMs)
      : undefined,
    consumer: String(data.consumer || ""),
    redactions: redacted.redactions,
  };
}

function normalizeCommandRecord(message, options) {
  const commandText = String(message.command || options.command || "");
  const redacted = redactValue(
    {
      id: message.id || options.id || "",
      command: redactCommandText(commandText),
    },
    options,
  );
  return {
    id: String(message.id || options.id || ""),
    timestamp: String(message.ts || options.timestamp || isoSeconds()),
    type: "command",
    event: "",
    command: commandName(commandText),
    source: String(message.source || options.source || "omegga.bmf-bridge"),
    transport: options.transport || "unknown",
    status: String(options.status || message.status || "pending"),
    payload: redacted.value,
    durationMs: Number.isFinite(Number(options.durationMs))
      ? Number(options.durationMs)
      : undefined,
    consumer: String(options.consumer || "bmf"),
    redactions: redacted.redactions,
  };
}

function normalizeResponseRecord(message, options) {
  const responseText =
    typeof message.response === "string" ? message.response : "";
  const parsed = responseText ? parseKeyValueResponse(responseText) : null;
  const ok =
    typeof message.ok === "boolean" ? message.ok : parsed ? parsed.ok : false;
  const commandText = String(
    options.command || parsed?.command || message.command || "",
  );
  const payload = {
    id: message.id || options.id || "",
    ok,
    detail: message.detail || parsed?.detail || "",
    command: commandText ? redactCommandText(commandText) : undefined,
    response: parsed || message.response || null,
  };
  const redacted = redactValue(payload, options);
  return {
    id: String(message.id || options.id || ""),
    timestamp: String(message.ts || options.timestamp || isoSeconds()),
    type: "response",
    event: "",
    command: commandName(commandText),
    source: String(message.source || "bmf"),
    transport: options.transport || "unknown",
    status: ok ? "ok" : "error",
    payload: redacted.value,
    durationMs: Number.isFinite(Number(options.durationMs))
      ? Number(options.durationMs)
      : undefined,
    consumer: String(options.consumer || "omegga.bmf-bridge"),
    redactions: redacted.redactions,
  };
}

function normalizeDropRecord(message, options) {
  const redacted = redactValue(message.payload || {}, options);
  return {
    id: String(message.id || ""),
    timestamp: String(message.ts || isoSeconds()),
    type: "drop",
    event: "",
    command: "",
    source: String(message.source || "omegga.bmf-bridge"),
    transport: options.transport || message.transport || "unknown",
    status: "dropped",
    payload: redacted.value,
    durationMs: undefined,
    consumer: "",
    redactions: redacted.redactions,
  };
}

function normalizeStatusRecord(message, options) {
  const redacted = redactValue(message.payload || message, options);
  return {
    id: String(message.id || ""),
    timestamp: String(message.ts || isoSeconds()),
    type: String(message.type || "status"),
    event: "",
    command: "",
    source: String(message.source || "omegga.bmf-bridge"),
    transport: options.transport || message.transport || "unknown",
    status: String(message.status || "ok"),
    payload: redacted.value,
    durationMs: undefined,
    consumer: "",
    redactions: redacted.redactions,
  };
}

function normalizeEnvelope(input, options = {}) {
  let message = input;
  if (typeof input === "string") {
    const parsed = safeJsonParse(input);
    message = parsed.ok ? parsed.value : { type: "log", message: input };
  }
  if (!message || typeof message !== "object") {
    message = { type: "log", message: String(input || "") };
  }

  let record = message;
  if (typeof message.record_json === "string") {
    const parsed = safeJsonParse(message.record_json);
    if (parsed.ok) record = parsed.value;
  } else if (message.record && typeof message.record === "object") {
    record = message.record;
  }

  if (
    (message.type === "event" || record.source === "event") &&
    record &&
    typeof record === "object" &&
    record.data &&
    typeof record.data === "object" &&
    record.data.event
  ) {
    return compactObject(normalizeEventRecord(record, message, options));
  }

  if (message.type === "response" || options.kind === "response") {
    return compactObject(normalizeResponseRecord(message, options));
  }

  if (message.type === "command" || options.kind === "command") {
    return compactObject(normalizeCommandRecord(message, options));
  }

  if (message.type === "drop" || options.kind === "drop") {
    return compactObject(normalizeDropRecord(message, options));
  }

  return compactObject(normalizeStatusRecord(message, options));
}

function coalesceKey(record) {
  if (!record || !["status", "log"].includes(record.type)) return "";
  const payload = record.payload || {};
  return [
    record.type,
    record.source || "",
    record.transport || "",
    record.status || "",
    payload.message || payload.detail || "",
  ].join("|");
}

module.exports = class BmfBridge {
  constructor(omegga, config) {
    this.omegga = omegga || {};
    this.config = config || {};
    this.records = [];
    this.subscribers = new Map();
    this.nextSubscriptionId = 1;
    this.pendingSocketCommands = new Map();
    this.commandSequence = 0;
    this.socket = null;
    this.socketBuffer = "";
    this.socketConfig = null;
    this.reconnectTimer = null;
    this.statusInterval = null;
    this.statusFlushTimer = null;
    this.started = false;
    this.paused = false;
    this.lastStatusWriteError = null;
    this.counters = {
      retained: 0,
      dropped: 0,
      coalesced: 0,
      pausedSkipped: 0,
      socketConnects: 0,
      socketDisconnects: 0,
      socketErrors: 0,
      socketMessages: 0,
      socketEvents: 0,
      socketResponses: 0,
      socketCommandsSent: 0,
      socketCommandsRejected: 0,
      socketCommandBytesRejected: 0,
      socketPendingPeak: 0,
      socketBufferOverflows: 0,
      parseErrors: 0,
      redactions: 0,
      statusWrites: 0,
      lastRecord: null,
      lastError: null,
      transport: "initializing",
      socketConnected: false,
    };
    this.handleStatusCommand = this.handleStatusCommand.bind(this);
  }

  async init() {
    if (!asBoolean(this.config.enabled, true)) {
      console.log("[bmf-bridge] disabled by config");
      return { registeredCommands: ["bmfbridge"] };
    }

    this.started = true;
    if (typeof this.omegga.on === "function") {
      this.omegga.on("cmd:bmfbridge", this.handleStatusCommand);
    }

    this.startStatusWrites();
    if (this.preferredTransport === "socket") {
      this.connectSocket();
    } else {
      this.counters.transport = "socket-required";
      this.counters.lastError = `unsupported transport: ${this.preferredTransport}`;
    }

    this.writeStatusFile({ lifecycle: "started" });
    return {
      registeredCommands: ["bmfbridge"],
      helpers: [
        "subscribe",
        "unsubscribe",
        "invokeCommand",
        "recentRecords",
        "statusSnapshot",
      ],
    };
  }

  async stop() {
    this.started = false;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.statusInterval) clearInterval(this.statusInterval);
    if (this.statusFlushTimer) clearTimeout(this.statusFlushTimer);
    this.reconnectTimer = null;
    this.statusInterval = null;
    this.statusFlushTimer = null;

    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
    }
    this.socket = null;
    this.socketBuffer = "";
    this.counters.socketConnected = false;

    for (const [id, pending] of this.pendingSocketCommands.entries()) {
      clearTimeout(pending.timer);
      pending.reject(
        new Error(`BMF socket command cancelled during bridge stop: ${id}`),
      );
    }
    this.pendingSocketCommands.clear();

    const remove =
      (typeof this.omegga.off === "function" &&
        this.omegga.off.bind(this.omegga)) ||
      (typeof this.omegga.removeListener === "function" &&
        this.omegga.removeListener.bind(this.omegga));
    if (remove) remove("cmd:bmfbridge", this.handleStatusCommand);
    this.writeStatusFile({ lifecycle: "stopped" });
  }

  async emitPlugin(event, _from, args = []) {
    const argv = Array.isArray(args) ? args : [];
    const name = String(event || "").trim();
    if (name === "invokeCommand") {
      return this.invokeCommand(argv[0], argv[1] || {});
    }
    if (name === "recentRecords") {
      return this.recentRecords(argv[0] || {});
    }
    if (name === "statusSnapshot") {
      return this.statusSnapshot(argv[0] || {});
    }
    throw new Error(`unsupported BMF bridge plugin event: ${name}`);
  }

  async pluginEvent(event, from, ...args) {
    // Omegga's safe Node worker dispatches inter-plugin calls through
    // pluginEvent(event, from, ...args), while the unsafe loader calls
    // emitPlugin(event, from, args). Support both loader contracts.
    try {
      return await this.emitPlugin(event, from, args);
    } catch (error) {
      return {
        ok: false,
        code: "PLUGIN_EVENT_FAILED",
        detail: String(error?.message ?? error ?? "unknown error").slice(
          0,
          1024,
        ),
      };
    }
  }

  get preferredTransport() {
    return String(this.config.preferredTransport || "socket")
      .trim()
      .toLowerCase();
  }

  get maxRecords() {
    return Math.max(1, asNumber(this.config.maxRecords, DEFAULT_RECORD_LIMIT));
  }

  get statusRecordLimit() {
    const configured = Math.floor(
      asNumber(this.config.statusRecordLimit, DEFAULT_STATUS_RECORD_LIMIT),
    );
    return Math.max(0, Math.min(this.maxRecords, configured));
  }

  get maxPendingSocketCommands() {
    return Math.max(
      1,
      Math.floor(
        asNumber(
          this.config.maxPendingSocketCommands ||
            env("OMEGGA_BMF_BRIDGE_MAX_PENDING_COMMANDS") ||
            env("OMEGGA_BMF_SOCKET_MAX_PENDING_COMMANDS"),
          DEFAULT_MAX_PENDING_SOCKET_COMMANDS,
        ),
      ),
    );
  }

  get maxSocketBufferBytes() {
    return Math.max(
      1024,
      Math.floor(
        asNumber(
          this.config.maxSocketBufferBytes ||
            env("OMEGGA_BMF_BRIDGE_MAX_BUFFER_BYTES") ||
            env("OMEGGA_BMF_SOCKET_MAX_CLIENT_BUFFER_BYTES"),
          DEFAULT_MAX_SOCKET_BUFFER_BYTES,
        ),
      ),
    );
  }

  get maxSocketCommandBytes() {
    return Math.max(
      1024,
      Math.floor(
        asNumber(
          this.config.maxSocketCommandBytes ||
            env("OMEGGA_BMF_BRIDGE_MAX_COMMAND_BYTES") ||
            env("BMF_UNIFIED_SOCKET_MAX_COMMAND_BYTES"),
          DEFAULT_MAX_SOCKET_COMMAND_BYTES,
        ),
      ),
    );
  }

  get runtimeDir() {
    const configured = String(this.config.runtimeDir || "").trim();
    if (configured) return path.resolve(configured);

    const envRuntimeDir = env("OMEGGA_BMF_RUNTIME_DIR");
    if (envRuntimeDir) return path.resolve(envRuntimeDir);

    return standardRuntimeDir();
  }

  get socketMetadataPath() {
    const configured = String(this.config.socketPath || "").trim();
    if (configured) return path.resolve(configured);
    return path.join(this.runtimeDir, "socket.json");
  }

  get statusPath() {
    const configured = String(this.config.statusPath || "").trim();
    if (configured) return path.resolve(configured);
    return path.join(this.runtimeDir, "bmf-bridge-status.json");
  }

  discoverSocketConfig() {
    const metadata = readJsonFile(this.socketMetadataPath) || {};
    const host = String(
      this.config.socketHost ||
        env("OMEGGA_BMF_SOCKET_HOST") ||
        metadata.host ||
        "127.0.0.1",
    ).trim();
    const port = asNumber(
      this.config.socketPort || env("OMEGGA_BMF_SOCKET_PORT") || metadata.port,
      0,
    );
    const token = String(
      this.config.socketToken ||
        env("OMEGGA_BMF_SOCKET_TOKEN") ||
        metadata.token ||
        "",
    ).trim();
    let explicitEnabled = this.config.socketEnabled;
    if (
      explicitEnabled === undefined ||
      explicitEnabled === null ||
      explicitEnabled === ""
    ) {
      explicitEnabled = env("OMEGGA_BMF_SOCKET_ENABLED");
    }
    if (explicitEnabled === "") {
      explicitEnabled = metadata.enabled;
    }
    const enabled = asBoolean(explicitEnabled, port > 0 && token !== "");
    return {
      enabled,
      host,
      port,
      token,
      pollIntervalMs: asNumber(
        metadata.pollIntervalMs || env("OMEGGA_BMF_SOCKET_POLL_MS"),
        200,
      ),
      role: String(this.config.socketRole || "plugin"),
      source: String(this.config.socketSource || "omegga.bmf-bridge"),
    };
  }

  socketReady() {
    return !!(
      this.socket &&
      this.counters.socketConnected &&
      !this.socket.destroyed &&
      this.socket.writable
    );
  }

  connectSocket() {
    if (!this.started) return;
    if (this.socketReady()) return;

    const socketConfig = this.discoverSocketConfig();
    this.socketConfig = socketConfig;
    if (!socketConfig.enabled || !socketConfig.port || !socketConfig.token) {
      this.counters.transport = "socket-unavailable";
      this.counters.lastError = "BMF socket metadata is missing or disabled.";
      this.writeStatusFile({ socketState: "unavailable" });
      this.scheduleReconnect();
      return;
    }

    if (this.socket) {
      this.socket.removeAllListeners();
      this.socket.destroy();
      this.socket = null;
    }

    const socket = net.createConnection(
      {
        host: socketConfig.host,
        port: socketConfig.port,
      },
      () => {
        this.counters.socketConnected = true;
        this.counters.socketConnects += 1;
        this.counters.transport = "socket";
        this.counters.lastError = "";
        this.sendSocketMessage({
          type: "hello",
          role: socketConfig.role,
          source: socketConfig.source,
          version: VERSION,
          token: socketConfig.token,
        });
        this.sendSocketMessage({
          type: "subscribe",
          source: socketConfig.source,
          events: Array.isArray(this.config.socketEvents)
            ? this.config.socketEvents
            : ["*"],
        });
        this.writeStatusFile({ socketState: "connected" });
      },
    );
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => this.handleSocketData(chunk));
    socket.on("error", (error) => {
      this.counters.socketErrors += 1;
      this.counters.lastError = error.message || String(error);
      this.writeStatusFile({ socketError: this.counters.lastError });
    });
    socket.on("close", () => {
      const wasConnected = this.counters.socketConnected;
      this.counters.socketConnected = false;
      this.counters.transport = "socket-disconnected";
      if (wasConnected) this.counters.socketDisconnects += 1;
      this.rejectPendingSocketCommands(
        "BMF socket disconnected before response.",
      );
      this.writeStatusFile({ socketState: "closed" });
      this.scheduleReconnect();
    });
    this.socket = socket;
  }

  scheduleReconnect() {
    if (!this.started || this.preferredTransport !== "socket") return;
    if (this.reconnectTimer) return;
    const reconnectMs = Math.max(
      0,
      asNumber(this.config.socketReconnectMs, 2500),
    );
    if (reconnectMs <= 0) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connectSocket();
    }, reconnectMs);
  }

  sendSocketMessage(message) {
    if (!this.socket || this.socket.destroyed || !this.socket.writable)
      return false;
    this.socket.write(`${JSON.stringify(message)}\n`);
    return true;
  }

  handleSocketData(chunk) {
    this.socketBuffer += String(chunk || "");
    let index = this.socketBuffer.indexOf("\n");
    while (index >= 0) {
      const line = this.socketBuffer.slice(0, index).trim();
      this.socketBuffer = this.socketBuffer.slice(index + 1);
      if (line) {
        const lineBytes = Buffer.byteLength(line, "utf8");
        if (lineBytes > this.maxSocketBufferBytes) {
          this.rejectOversizedSocketInput(lineBytes);
          return;
        }
        this.handleSocketLine(line);
      }
      index = this.socketBuffer.indexOf("\n");
    }
    const bufferedBytes = Buffer.byteLength(this.socketBuffer, "utf8");
    if (bufferedBytes > this.maxSocketBufferBytes) {
      this.rejectOversizedSocketInput(bufferedBytes);
    }
  }

  rejectOversizedSocketInput(bytes) {
    this.socketBuffer = "";
    this.counters.socketBufferOverflows += 1;
    this.counters.lastError =
      `BMF bridge socket input exceeded ${this.maxSocketBufferBytes} bytes ` +
      `(observed ${Math.max(0, Number(bytes) || 0)}).`;
    this.writeStatusFile({ socketState: "input-overflow" });
    if (this.socket && !this.socket.destroyed) this.socket.destroy();
  }

  handleSocketLine(line) {
    const parsed = safeJsonParse(line);
    if (!parsed.ok || !parsed.value || typeof parsed.value !== "object") {
      this.counters.parseErrors += 1;
      this.counters.lastError = `socket JSON parse failed: ${parsed.error?.message || "invalid JSON"}`;
      return;
    }

    const message = parsed.value;
    this.counters.socketMessages += 1;
    this.counters.lastError = "";
    if (message.type === "ping") {
      this.sendSocketMessage({
        type: "pong",
        source: this.socketConfig?.source || "omegga.bmf-bridge",
        ts: isoSeconds(),
        id: message.id,
      });
      return;
    }

    if (message.type === "response") {
      this.handleSocketResponse(message);
      return;
    }

    if (message.type === "event") {
      this.counters.socketEvents += 1;
      const structuredRecord =
        message.record && typeof message.record === "object"
          ? message.record
          : null;
      if (
        structuredRecord?.source === "operation" &&
        structuredRecord?.message === "BMF_SLOW_OPERATION"
      ) {
        // The Lua game thread only enqueues the existing socket event. Perform
        // the actual log I/O here on Node so attribution cannot lengthen the
        // frame it is measuring.
        console.warn(
          `[BMF_SLOW_OPERATION] ${JSON.stringify(structuredRecord.data || {})}`,
        );
      }
      this.recordEnvelope(message, { transport: "socket" });
      return;
    }

    if (
      message.type === "hello" ||
      message.type === "ack" ||
      message.type === "status"
    ) {
      this.recordEnvelope(message, { transport: "socket" });
    }
  }

  handleSocketResponse(message) {
    this.counters.socketResponses += 1;
    const id = String(message.id || "");
    const pending = this.pendingSocketCommands.get(id);
    const durationMs = pending ? Date.now() - pending.startedAtMs : undefined;
    if (pending) {
      clearTimeout(pending.timer);
      this.pendingSocketCommands.delete(id);
    }
    const envelope = this.recordEnvelope(message, {
      kind: "response",
      transport: "socket",
      command: pending?.command || message.command || "",
      durationMs,
    });
    const response = {
      ok: envelope.status === "ok",
      detail: envelope.payload?.detail || "",
      transport: "socket",
      response:
        typeof message.response === "string"
          ? parseKeyValueResponse(message.response)
          : message.response,
      envelope,
    };
    if (pending) pending.resolve(response);
  }

  rejectPendingSocketCommands(message) {
    for (const [id, pending] of this.pendingSocketCommands.entries()) {
      clearTimeout(pending.timer);
      this.pendingSocketCommands.delete(id);
      pending.reject(new Error(`${message} id=${id}`));
    }
  }

  recordEnvelope(input, options = {}) {
    const envelope = normalizeEnvelope(input, {
      ...options,
      redactPrivateIps: asBoolean(
        options.redactPrivateIps,
        asBoolean(this.config.redactPrivateIpsOnExport, false),
      ),
    });
    this.counters.redactions += asNumber(envelope.redactions, 0);

    const previous = this.records[this.records.length - 1];
    const previousKey = coalesceKey(previous);
    const nextKey = coalesceKey(envelope);
    if (previousKey && previousKey === nextKey) {
      previous.coalesced = asNumber(previous.coalesced, 1) + 1;
      previous.timestamp = envelope.timestamp;
      this.counters.coalesced += 1;
      return previous;
    }

    this.records.push(envelope);
    while (this.records.length > this.maxRecords) {
      this.records.shift();
      this.counters.dropped += 1;
    }
    this.counters.retained = this.records.length;
    this.counters.lastRecord = compactObject({
      id: envelope.id,
      timestamp: envelope.timestamp,
      type: envelope.type,
      event: envelope.event,
      command: envelope.command,
      transport: envelope.transport,
      status: envelope.status,
    });

    this.deliverEnvelope(envelope);
    this.queueStatusWrite();
    return envelope;
  }

  deliverEnvelope(envelope) {
    if (this.paused) {
      this.counters.pausedSkipped += 1;
      return;
    }
    for (const [id, subscriber] of this.subscribers.entries()) {
      if (!this.matchesFilter(envelope, subscriber.filter)) continue;
      try {
        subscriber.handler(envelope);
      } catch (error) {
        this.counters.lastError = `subscriber ${id} failed: ${error.message || error}`;
      }
    }
  }

  subscribe(filter, handler) {
    if (typeof handler !== "function") {
      throw new Error("BMF bridge subscriber must be a function.");
    }
    const id = String(this.nextSubscriptionId++);
    this.subscribers.set(id, {
      filter: filter || "*",
      handler,
    });
    return id;
  }

  unsubscribe(id) {
    return this.subscribers.delete(String(id));
  }

  matchesFilter(envelope, filter) {
    if (!filter || filter === "*") return true;
    if (typeof filter === "function") return filter(envelope) === true;
    if (typeof filter === "string") {
      return (
        envelope.event === filter ||
        envelope.type === filter ||
        envelope.command === filter
      );
    }
    if (Array.isArray(filter)) {
      return filter.some((item) => this.matchesFilter(envelope, item));
    }
    if (typeof filter === "object") {
      for (const [key, expected] of Object.entries(filter)) {
        if (expected === undefined || expected === null || expected === "")
          continue;
        if (Array.isArray(expected)) {
          if (!expected.includes(envelope[key])) return false;
        } else if (expected !== envelope[key]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  recentRecords(options = {}) {
    const limit = Math.max(0, asNumber(options.limit, this.records.length));
    const filter = options.filter || "*";
    const records = this.records.filter((record) =>
      this.matchesFilter(record, filter),
    );
    return limit > 0 ? records.slice(-limit) : records;
  }

  setPaused(paused) {
    this.paused = !!paused;
    this.writeStatusFile({ paused: this.paused });
  }

  async invokeCommand(commandText, options = {}) {
    const command = String(commandText || "").trim();
    if (!command) throw new Error("BMF command text is required.");

    const transport = String(
      options.transport || this.preferredTransport,
    ).toLowerCase();
    if (transport !== "socket") {
      const detail = `unsupported BMF transport: ${transport}`;
      this.counters.lastError = detail;
      throw new Error(detail);
    }

    if (this.socketReady()) {
      return this.invokeSocketCommand(command, options);
    }

    const detail = "BMF socket is not connected.";
    this.counters.lastError = detail;
    throw new Error(detail);
  }

  invokeSocketCommand(command, options = {}) {
    if (!this.socketReady()) {
      throw new Error("BMF socket is not connected.");
    }

    const id = String(
      options.id || `bmf_bridge_${Date.now()}_${++this.commandSequence}`,
    );
    if (this.pendingSocketCommands.has(id)) {
      this.counters.socketCommandsRejected += 1;
      throw new Error(`BMF bridge socket command id is already pending: ${id}`);
    }
    if (this.pendingSocketCommands.size >= this.maxPendingSocketCommands) {
      this.counters.socketCommandsRejected += 1;
      const detail =
        `BMF bridge pending socket command limit reached ` +
        `(${this.maxPendingSocketCommands}).`;
      this.counters.lastError = detail;
      throw new Error(detail);
    }
    const timeoutMs = Math.max(
      100,
      asNumber(options.timeoutMs, asNumber(this.config.commandTimeoutMs, 5000)),
    );
    const startedAtMs = Date.now();
    const serviceClass =
      options.serviceClass === "bulk" ? "bulk" : "interactive";
    const message = {
      type: "command",
      source: this.socketConfig?.source || "omegga.bmf-bridge",
      id,
      command,
      issuedAtMs: startedAtMs,
      deadlineMs: startedAtMs + timeoutMs,
      serviceClass,
    };
    const commandBytes = Buffer.byteLength(command, "utf8");
    if (commandBytes > this.maxSocketCommandBytes) {
      this.counters.socketCommandsRejected += 1;
      this.counters.socketCommandBytesRejected += 1;
      const detail =
        `BMF bridge socket command is ${commandBytes} bytes; maximum is ` +
        `${this.maxSocketCommandBytes}.`;
      this.counters.lastError = detail;
      throw new Error(detail);
    }

    this.recordEnvelope(message, {
      kind: "command",
      transport: "socket",
      status: "pending",
      command,
    });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingSocketCommands.delete(id);
        const error = new Error(
          `timed out waiting for BMF socket response: ${commandName(command)}`,
        );
        this.recordEnvelope(
          {
            type: "response",
            source: "bmf",
            id,
            ok: false,
            detail: error.message,
          },
          {
            kind: "response",
            transport: "socket",
            command,
            durationMs: Date.now() - startedAtMs,
          },
        );
        reject(error);
      }, timeoutMs);

      this.pendingSocketCommands.set(id, {
        command,
        startedAtMs,
        timer,
        resolve,
        reject,
      });
      this.counters.socketPendingPeak = Math.max(
        this.counters.socketPendingPeak,
        this.pendingSocketCommands.size,
      );

      if (!this.sendSocketMessage(message)) {
        clearTimeout(timer);
        this.pendingSocketCommands.delete(id);
        reject(new Error("failed to write BMF socket command."));
        return;
      }
      this.counters.socketCommandsSent += 1;
    });
  }

  handleStatusCommand(speaker, action = "status") {
    const verb = String(action || "status")
      .trim()
      .toLowerCase();
    if (verb === "pause") this.setPaused(true);
    if (verb === "resume") this.setPaused(false);

    const status = this.statusSnapshot();
    const lines = [
      `BMF bridge: transport=${status.transport} socket=${status.socket.connected ? "connected" : "disconnected"} paused=${status.paused ? "true" : "false"}`,
      `records: retained=${status.records.retained} dropped=${status.records.dropped} coalesced=${status.records.coalesced} paused_skipped=${status.records.pausedSkipped}`,
      `commands: pending=${status.commands.pending}/${status.commands.maxPending} socket_sent=${status.commands.socketSent} socket_responses=${status.commands.socketResponses} rejected=${status.commands.socketRejected}`,
      `events: socket=${status.events.socket} parse_errors=${status.events.parseErrors}`,
      `paths: runtime=${status.paths.runtimeDir}`,
      `paths: socket=${status.paths.socketMetadataPath}`,
    ];
    if (status.lastError) lines.push(`last_error=${status.lastError}`);
    this.sayToSpeaker(speaker, lines);
  }

  sayToSpeaker(speaker, lines) {
    const target =
      typeof speaker === "string"
        ? speaker
        : speaker?.name || speaker?.displayName || "";
    if (target && typeof this.omegga.whisper === "function") {
      for (const line of lines) this.omegga.whisper(target, line);
      return;
    }
    if (typeof this.omegga.broadcast === "function") {
      for (const line of lines) this.omegga.broadcast(line);
      return;
    }
    for (const line of lines) console.log(`[bmf-bridge] ${line}`);
  }

  startStatusWrites() {
    const intervalMs = Math.max(
      0,
      asNumber(this.config.statusWriteIntervalMs, 5000),
    );
    if (intervalMs <= 0) return;
    this.statusInterval = setInterval(() => this.writeStatusFile(), intervalMs);
  }

  queueStatusWrite() {
    if (!this.started || !this.statusPath || this.statusFlushTimer) return;
    const intervalMs = Math.max(
      250,
      asNumber(this.config.statusRecordFlushIntervalMs, 1000),
    );
    this.statusFlushTimer = setTimeout(() => {
      this.statusFlushTimer = null;
      this.writeStatusFile({ lifecycle: "recorded" });
    }, intervalMs);
    if (typeof this.statusFlushTimer.unref === "function")
      this.statusFlushTimer.unref();
  }

  statusSnapshot(extra = {}) {
    const socket = this.socketConfig || this.discoverSocketConfig();
    const recentRecordLimit = this.statusRecordLimit;
    return {
      updatedAt: isoSeconds(),
      version: VERSION,
      guardrails: GUARDRAILS,
      transport: this.counters.transport,
      paused: this.paused,
      records: {
        retained: this.records.length,
        max: this.maxRecords,
        statusLimit: recentRecordLimit,
        dropped: this.counters.dropped,
        coalesced: this.counters.coalesced,
        pausedSkipped: this.counters.pausedSkipped,
      },
      socket: {
        enabled: !!socket.enabled,
        connected: this.counters.socketConnected,
        host: socket.host,
        port: socket.port,
        token: socket.token ? "[redacted]" : "",
        connects: this.counters.socketConnects,
        disconnects: this.counters.socketDisconnects,
        errors: this.counters.socketErrors,
        bufferedBytes: Buffer.byteLength(this.socketBuffer, "utf8"),
        maxBufferBytes: this.maxSocketBufferBytes,
        bufferOverflows: this.counters.socketBufferOverflows,
      },
      commands: {
        pending: this.pendingSocketCommands.size,
        maxPending: this.maxPendingSocketCommands,
        maxCommandBytes: this.maxSocketCommandBytes,
        pendingPeak: this.counters.socketPendingPeak,
        socketSent: this.counters.socketCommandsSent,
        socketResponses: this.counters.socketResponses,
        socketRejected: this.counters.socketCommandsRejected,
        socketBytesRejected: this.counters.socketCommandBytesRejected,
      },
      events: {
        socket: this.counters.socketEvents,
        parseErrors: this.counters.parseErrors,
        redactions: this.counters.redactions,
      },
      subscribers: this.subscribers.size,
      paths: {
        runtimeDir: this.runtimeDir,
        socketMetadataPath: this.socketMetadataPath,
        statusPath: this.statusPath,
      },
      lastRecord: this.counters.lastRecord,
      recentRecords:
        recentRecordLimit > 0
          ? this.recentRecords({ limit: recentRecordLimit })
          : [],
      lastError: this.counters.lastError || this.lastStatusWriteError,
      ...extra,
    };
  }

  writeStatusFile(extra = {}) {
    const statusPath = this.statusPath;
    if (!statusPath) return;
    try {
      fs.mkdirSync(path.dirname(statusPath), { recursive: true });
      fs.writeFileSync(
        statusPath,
        `${JSON.stringify(this.statusSnapshot(extra), null, 2)}\n`,
        "utf8",
      );
      this.counters.statusWrites += 1;
      this.lastStatusWriteError = null;
    } catch (error) {
      this.lastStatusWriteError = error.message || String(error);
    }
  }
};

module.exports.VERSION = VERSION;
module.exports.normalizeEnvelope = normalizeEnvelope;
module.exports.redactValue = redactValue;
module.exports.parseKeyValueResponse = parseKeyValueResponse;
module.exports.commandName = commandName;
