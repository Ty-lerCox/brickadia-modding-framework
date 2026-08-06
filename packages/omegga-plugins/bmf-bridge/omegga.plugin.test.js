const assert = require("assert");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const test = require("node:test");

const BmfBridge = require("./omegga.plugin");

function tempRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bmf-bridge-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function eventRecord(event, payload = {}) {
  return {
    level: "info",
    message: `event emitted: ${event}`,
    source: "event",
    ts: "2026-06-16T12:00:00Z",
    data: {
      event,
      payload,
      handlers: 1,
      errors: [],
      ok: true,
    },
  };
}

test("normalizes event records and redacts retained payload secrets", () => {
  const envelope = BmfBridge.normalizeEnvelope(
    eventRecord("resource.hit", {
      player: {
        id: "33333333-3333-4333-8333-333333333333",
        token: "do-not-show",
      },
      endpoint: "http://192.168.1.20:3000",
      _bmf: {
        eventId: "42",
        source: "native.BMFSocketResourceNative",
      },
    }),
    {
      transport: "socket",
      redactPrivateIps: true,
    },
  );

  assert.strictEqual(envelope.id, "42");
  assert.strictEqual(envelope.type, "event");
  assert.strictEqual(envelope.event, "resource.hit");
  assert.strictEqual(envelope.transport, "socket");
  assert.strictEqual(envelope.source, "native.BMFSocketResourceNative");
  assert.strictEqual(envelope.payload.player.token, "[redacted]");
  assert.strictEqual(envelope.payload.endpoint, "http://[private-ip]:3000");
  assert.ok(envelope.redactions >= 2);
});

test("status snapshot exposes bounded retained socket records", () => {
  const bridge = new BmfBridge(
    {},
    {
      maxRecords: 4,
      statusRecordLimit: 2,
      redactPrivateIpsOnExport: true,
    },
  );

  bridge.recordEnvelope(eventRecord("status.one", { token: "one-secret" }), {
    transport: "socket",
  });
  bridge.recordEnvelope(eventRecord("status.two", { token: "two-secret" }), {
    transport: "socket",
  });
  bridge.recordEnvelope(
    eventRecord("status.three", {
      token: "three-secret",
      endpoint: "http://192.168.1.25:3000",
    }),
    { transport: "socket" },
  );

  const status = bridge.statusSnapshot();
  assert.strictEqual(status.records.retained, 3);
  assert.strictEqual(status.records.statusLimit, 2);
  assert.deepStrictEqual(
    status.recentRecords.map((record) => record.event),
    ["status.two", "status.three"],
  );
  assert.strictEqual(status.recentRecords[0].payload.token, "[redacted]");
  assert.strictEqual(
    status.recentRecords[1].payload.endpoint,
    "http://[private-ip]:3000",
  );
});

test("default command path requires a connected socket instead of file fallback", async () => {
  const bridge = new BmfBridge({}, { socketReconnectMs: 0 });
  await assert.rejects(
    () => bridge.invokeCommand("bmf.status"),
    /BMF socket is not connected/,
  );
  await assert.rejects(
    () => bridge.invokeCommand("bmf.status", { transport: "file-command" }),
    /unsupported BMF transport: file-command/,
  );
});

test("safe-plugin interop forwards pluginEvent calls to the socket command helper", async () => {
  const bridge = new BmfBridge({}, { socketReconnectMs: 0 });
  let invocation;
  bridge.invokeCommand = async (command, options) => {
    invocation = { command, options };
    return { ok: true, transport: "socket" };
  };

  const response = await bridge.pluginEvent(
    "invokeCommand",
    "BMF Player Sync",
    "bmf.players.sync players=[]",
    { timeoutMs: 1000, serviceClass: "bulk" },
  );

  assert.deepStrictEqual(invocation, {
    command: "bmf.players.sync players=[]",
    options: { timeoutMs: 1000, serviceClass: "bulk" },
  });
  assert.deepStrictEqual(response, { ok: true, transport: "socket" });
});

test("safe-plugin interop returns a bounded failure when invocation rejects", async () => {
  const bridge = new BmfBridge({}, { socketReconnectMs: 0 });
  bridge.invokeCommand = async () => {
    throw new Error(`socket failed ${"x".repeat(2048)}`);
  };

  const response = await bridge.pluginEvent(
    "invokeCommand",
    "BMF Player Sync",
    "bmf.players.sync players=[]",
  );

  assert.equal(response.ok, false);
  assert.equal(response.code, "PLUGIN_EVENT_FAILED");
  assert.match(response.detail, /^socket failed /);
  assert.equal(response.detail.length, 1024);
});

test("socket transport sends hello, subscribes, receives events, and resolves commands", async (t) => {
  const root = tempRoot(t);
  const received = [];
  const server = net.createServer((socket) => {
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let index = buffer.indexOf("\n");
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) {
          const message = JSON.parse(line);
          received.push(message);
          if (message.type === "subscribe") {
            socket.write(
              `${JSON.stringify({ type: "event", source: "bmf", ts: "2026-06-16T12:00:00Z", record: eventRecord("serverReady", { ok: true }) })}\n`,
            );
          }
          if (message.type === "command") {
            socket.write(
              `${JSON.stringify({ type: "response", source: "bmf", id: message.id, ok: true, detail: "ok", response: "ok=true\ndetail=ok\ncommand=bmf.status\n" })}\n`,
            );
          }
        }
        index = buffer.indexOf("\n");
      }
    });
  });
  t.after(() => server.close());
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  fs.writeFileSync(
    path.join(root, "socket.json"),
    JSON.stringify({
      enabled: true,
      host: "127.0.0.1",
      port,
      token: "socket-token",
    }),
    "utf8",
  );

  const bridge = new BmfBridge(
    {},
    {
      runtimeDir: root,
      socketReconnectMs: 0,
      commandTimeoutMs: 1000,
    },
  );
  t.after(() => bridge.stop());
  await bridge.init();

  while (
    !bridge.socketReady() ||
    bridge.recentRecords({ filter: { event: "serverReady" } }).length === 0
  ) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  const response = await bridge.invokeCommand("bmf.status");
  assert.strictEqual(response.ok, true);
  assert.strictEqual(response.transport, "socket");
  assert.ok(
    received.find(
      (message) => message.type === "hello" && message.token === "socket-token",
    ),
  );
  assert.ok(received.find((message) => message.type === "subscribe"));
  const commandEnvelope = received.find(
    (message) => message.type === "command" && message.command === "bmf.status",
  );
  assert.ok(commandEnvelope);
  assert.strictEqual(commandEnvelope.serviceClass, "interactive");
  assert.ok(Number.isFinite(commandEnvelope.issuedAtMs));
  assert.strictEqual(
    commandEnvelope.deadlineMs - commandEnvelope.issuedAtMs,
    1000,
  );
  assert.strictEqual(
    bridge.recentRecords({ filter: { event: "serverReady" } })[0].transport,
    "socket",
  );
});

test("rejects socket commands before send when the pending response map is full", async () => {
  const bridge = new BmfBridge({}, { maxPendingSocketCommands: 1 });
  const writes = [];
  bridge.socket = {
    destroyed: false,
    writable: true,
    write(value) {
      writes.push(value);
      return true;
    },
  };
  bridge.socketConfig = { source: "test.bmf-bridge" };
  bridge.counters.socketConnected = true;

  const first = bridge.invokeSocketCommand("bmf.first", {
    id: "first",
    timeoutMs: 1000,
  });
  assert.throws(
    () =>
      bridge.invokeSocketCommand("bmf.second", {
        id: "second",
        timeoutMs: 1000,
      }),
    /pending socket command limit reached/,
  );
  assert.equal(writes.length, 1);
  assert.equal(bridge.counters.socketCommandsRejected, 1);

  bridge.handleSocketResponse({
    type: "response",
    source: "bmf",
    id: "first",
    ok: true,
    detail: "ok",
    response: "ok=true\n",
  });
  await first;

  const status = bridge.statusSnapshot();
  assert.equal(status.commands.pending, 0);
  assert.equal(status.commands.maxPending, 1);
  assert.equal(status.commands.pendingPeak, 1);
  assert.equal(status.commands.socketRejected, 1);
});

test("disconnects and clears an oversized partial socket record", () => {
  const bridge = new BmfBridge({}, { maxSocketBufferBytes: 1024 });
  let destroyed = false;
  bridge.socket = {
    destroyed: false,
    destroy() {
      destroyed = true;
      this.destroyed = true;
    },
  };

  bridge.handleSocketData("x".repeat(1025));

  assert.equal(destroyed, true);
  assert.equal(bridge.socketBuffer, "");
  assert.equal(bridge.counters.socketBufferOverflows, 1);
  const status = bridge.statusSnapshot();
  assert.equal(status.socket.bufferedBytes, 0);
  assert.equal(status.socket.maxBufferBytes, 1024);
  assert.equal(status.socket.bufferOverflows, 1);
});

test("rejects an oversized outbound command before socket write", () => {
  const bridge = new BmfBridge({}, { maxSocketCommandBytes: 1024 });
  const writes = [];
  bridge.socket = {
    destroyed: false,
    writable: true,
    write(value) {
      writes.push(value);
      return true;
    },
  };
  bridge.socketConfig = { source: "test.bmf-bridge" };
  bridge.counters.socketConnected = true;

  assert.throws(
    () =>
      bridge.invokeSocketCommand(`bmf.test payload=${"x".repeat(2048)}`, {
        id: "oversized",
      }),
    /socket command is .* bytes; maximum is 1024/,
  );
  assert.equal(writes.length, 0);
  assert.equal(bridge.pendingSocketCommands.size, 0);
  const status = bridge.statusSnapshot();
  assert.equal(status.commands.maxCommandBytes, 1024);
  assert.equal(status.commands.socketRejected, 1);
  assert.equal(status.commands.socketBytesRejected, 1);
});

test("pause skips subscriber delivery without unbounded retention", () => {
  const bridge = new BmfBridge({}, { maxRecords: 1 });
  const delivered = [];
  bridge.subscribe("*", (record) => delivered.push(record));
  bridge.setPaused(true);
  bridge.recordEnvelope(eventRecord("paused.one"), { transport: "socket" });
  bridge.recordEnvelope(eventRecord("paused.two"), { transport: "socket" });

  assert.deepStrictEqual(delivered, []);
  assert.strictEqual(bridge.recentRecords().length, 1);
  assert.strictEqual(bridge.recentRecords()[0].event, "paused.two");
  assert.strictEqual(bridge.counters.pausedSkipped, 2);
  assert.strictEqual(bridge.counters.dropped, 1);
});
