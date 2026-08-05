"use strict";

const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");

function readArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`Invalid argument near ${key || "<end>"}`);
    }
    args[key.slice(2)] = value;
  }
  return args;
}

async function main() {
  const args = readArgs(process.argv.slice(2));
  const runtimeDir =
    args["runtime-dir"] ||
    path.join(
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
    );
  const command = String(args.command || "").trim();
  const timeoutMs = Math.max(1000, Number(args["timeout-ms"]) || 30000);
  if (!command) throw new Error("--command is required.");

  const metadataPath = path.join(runtimeDir, "socket.json");
  const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
  if (
    !metadata.enabled ||
    !metadata.host ||
    !metadata.port ||
    !metadata.token
  ) {
    throw new Error(`BMF socket metadata is incomplete: ${metadataPath}`);
  }

  const issuedAtMs = Date.now();
  const id = `bmf_sync_${issuedAtMs}_${process.pid}`;
  await new Promise((resolve, reject) => {
    const socket = net.createConnection({
      host: metadata.host,
      port: metadata.port,
    });
    let buffer = "";
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      if (error) reject(error);
      else resolve();
    };
    const timer = setTimeout(
      () =>
        finish(
          new Error(`Timed out waiting for BMF socket response: ${command}`),
        ),
      timeoutMs,
    );

    socket.on("connect", () => {
      socket.write(
        `${JSON.stringify({
          type: "hello",
          role: "tool",
          source: "bmf.native-hook-sync",
          version: "1",
          token: metadata.token,
        })}\n`,
      );
      socket.write(
        `${JSON.stringify({
          type: "command",
          source: "bmf.native-hook-sync",
          id,
          command,
          issuedAtMs,
          deadlineMs: issuedAtMs + timeoutMs,
          serviceClass: "interactive",
        })}\n`,
      );
    });
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      while (buffer.includes("\n")) {
        const split = buffer.indexOf("\n");
        const line = buffer.slice(0, split).trim();
        buffer = buffer.slice(split + 1);
        if (!line) continue;
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }
        if (message.type !== "response" || message.id !== id) continue;
        process.stdout.write(
          `${JSON.stringify({
            id,
            ok: message.ok === true,
            detail: message.detail || "",
            response: message.response || "",
          })}\n`,
        );
        finish();
      }
    });
    socket.on("error", finish);
  });
}

main().catch((error) => {
  process.stderr.write(`${error.message || error}\n`);
  process.exitCode = 1;
});
