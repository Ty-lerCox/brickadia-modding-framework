import { write as writeServerConfig } from '@brickadia/config';
import Ue4ssBridgeHost from '@brickadia/ue4ssBridge';
import RpcPlugin from '@omegga/plugin/plugin_jsonrpc_stdio';
import { getProcessInvocation } from '@util/process';
import {
  getGameBinaryPath,
  getServerConfigDirectory,
  IS_WINDOWS,
} from '@util/platform';
import {
  getPinnedUe4ssCompatibilityBundleId,
  disableManagedUe4ss,
  installManagedUe4ss,
  readUe4ssDiagnostics,
  resolveUe4ssCompatibilityBundle,
  validateUe4ssCompatibilityBundle,
} from '@util/ue4ss';
import {
  getWindowsConsoleBridgeBinaryPath,
  getWindowsConsoleBridgeProjectDir,
} from '@util/windowsBridge';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

const windowsDescribe = IS_WINDOWS ? describe : describe.skip;
const tempDirs: string[] = [];
const originalUe4ssSource = process.env.OMEGGA_UE4SS_SOURCE;
const originalUe4ssReRoot = process.env.OMEGGA_UE4SS_RE_ROOT;
const originalBmfSource = process.env.OMEGGA_BMF_SOURCE_DIR;

const makeTempDir = () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omegga-windows-'));
  tempDirs.push(dir);
  return dir;
};

const sha256 = (value: string | Buffer) =>
  createHash('sha256').update(value).digest('hex');

const createTempCompatibilityWorkspace = ({
  validated = false,
  bundleId = getPinnedUe4ssCompatibilityBundleId(),
} = {}) => {
  const workspaceRoot = makeTempDir();
  const bundleRoot = path.join(workspaceRoot, 'bundles', bundleId);
  const bundleFiles: Record<string, string> = {
    'VTableLayout.ini': '; test vtable layout\n',
    'CustomGameConfigs/Brickadia/UE4SS-settings.ini':
      '[General]\nHookProcessConsoleExec = 1\n',
    'CustomGameConfigs/Brickadia/UE4SS_Signatures/CallFunctionByNameWithArguments.lua':
      'return nil\n',
    'CustomGameConfigs/Brickadia/UE4SS_Signatures/FName_Constructor.lua':
      'return 0x140000001\n',
    'CustomGameConfigs/Brickadia/UE4SS_Signatures/FName_ToString.lua':
      'return 0x140000002\n',
    'CustomGameConfigs/Brickadia/UE4SS_Signatures/GNatives.lua': 'return nil\n',
    'CustomGameConfigs/Brickadia/UE4SS_Signatures/GUObjectArray.lua':
      'return 0x140000003\n',
    'CustomGameConfigs/Brickadia/UE4SS_Signatures/GUObjectHashTables.lua':
      'return nil\n',
    'validation-report.json': JSON.stringify(
      {
        bundle_id: bundleId,
        validated,
      },
      null,
      2,
    ),
    'validation-report.md': '# test report\n',
  };

  for (const [relativePath, contents] of Object.entries(bundleFiles)) {
    const absolutePath = path.join(bundleRoot, ...relativePath.split('/'));
    fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
    fs.writeFileSync(absolutePath, contents);
  }

  const manifest = {
    brickadia_cl: bundleId.replace(/^CL/i, ''),
    brickadia_version_string: `Brickadia EA2 (PC-Shipping-${bundleId})`,
    ue_baseline: '5.5',
    ue4ss_commit: '01e0a584',
    validated,
    validation_timestamp: validated ? '2026-03-07T00:00:00Z' : null,
    files: Object.fromEntries(
      Object.entries(bundleFiles).map(([relativePath, contents]) => [
        relativePath,
        sha256(contents),
      ]),
    ),
  };

  fs.writeFileSync(
    path.join(bundleRoot, 'manifest.json'),
    JSON.stringify(manifest, null, 2) + '\n',
  );

  return { workspaceRoot, bundleRoot };
};

afterEach(() => {
  if (originalUe4ssSource === undefined) delete process.env.OMEGGA_UE4SS_SOURCE;
  else process.env.OMEGGA_UE4SS_SOURCE = originalUe4ssSource;
  if (originalUe4ssReRoot === undefined)
    delete process.env.OMEGGA_UE4SS_RE_ROOT;
  else process.env.OMEGGA_UE4SS_RE_ROOT = originalUe4ssReRoot;
  if (originalBmfSource === undefined) delete process.env.OMEGGA_BMF_SOURCE_DIR;
  else process.env.OMEGGA_BMF_SOURCE_DIR = originalBmfSource;

  vi.restoreAllMocks();

  while (tempDirs.length > 0) {
    const dir = tempDirs.pop();
    if (dir) fs.rmSync(dir, { recursive: true, force: true });
  }
});

windowsDescribe('Windows platform support', () => {
  it('writes server config to WindowsServer', () => {
    const tempDir = makeTempDir();
    const dataPath = path.join(tempDir, 'data');

    writeServerConfig(dataPath, {
      server: { port: 7777, name: 'Windows Test Server' },
    } as any);

    const configFile = path.join(
      dataPath,
      'Saved',
      getServerConfigDirectory(),
      'GameUserSettings.ini',
    );

    expect(fs.existsSync(configFile)).toBe(true);
    expect(fs.readFileSync(configFile, 'utf8')).toContain(
      'ServerName=Windows Test Server',
    );
  });

  it('uses Windows binary and script conventions', () => {
    expect(getGameBinaryPath()).toContain(path.join('Binaries', 'Win64'));
    expect(getGameBinaryPath()).toMatch(/\.exe$/);

    const powerShellInvocation = getProcessInvocation(
      'C:\\plugins\\example\\setup.ps1',
    );
    expect(powerShellInvocation.command.toLowerCase()).toContain('powershell');
    expect(powerShellInvocation.args).toContain('-File');

    const batchInvocation = getProcessInvocation(
      'C:\\plugins\\example\\omegga_plugin.cmd',
    );
    expect(batchInvocation.command.toLowerCase()).toContain('cmd');
    expect(batchInvocation.args.slice(0, 3)).toEqual(['/d', '/s', '/c']);
  });

  it('detects Windows RPC plugin entrypoints', () => {
    const pluginDir = makeTempDir();

    fs.writeFileSync(path.join(pluginDir, 'doc.json'), '{}');
    fs.writeFileSync(path.join(pluginDir, 'omegga_plugin.cmd'), '@echo off');

    expect(RpcPlugin.canLoad(pluginDir)).toBe(true);
  });

  it('uses the Rust console bridge on Windows', () => {
    expect(getWindowsConsoleBridgeProjectDir()).toContain(
      path.join('tools', 'windows-console-bridge'),
    );
    expect(getWindowsConsoleBridgeBinaryPath()).toMatch(
      /omegga-console-bridge\.exe$/,
    );
  });

  it('installs and disables the managed UE4SS payload', () => {
    const sourceRoot = makeTempDir();
    const targetRoot = makeTempDir();
    const compatibilityWorkspace = createTempCompatibilityWorkspace();

    fs.mkdirSync(path.join(sourceRoot, 'ue4ss', 'Mods'), { recursive: true });
    fs.writeFileSync(path.join(sourceRoot, 'dwmapi.dll'), 'proxy');
    fs.writeFileSync(path.join(sourceRoot, 'ue4ss', 'UE4SS.dll'), 'dll');
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'UE4SS.prepatched.pdb'),
      'symbols',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'UE4SS-settings.ini'),
      '[General]\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.txt'),
      'Keybinds : 1\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.json'),
      '[]\n',
    );
    process.env.OMEGGA_UE4SS_SOURCE = sourceRoot;
    process.env.OMEGGA_UE4SS_RE_ROOT = compatibilityWorkspace.workspaceRoot;

    const install = installManagedUe4ss(targetRoot);
    expect(install.sourceRoot).toBe(sourceRoot);
    expect(install.compatibilityBundle.bundleId).toBe(
      getPinnedUe4ssCompatibilityBundleId(),
    );
    expect(fs.existsSync(path.join(targetRoot, 'dwmapi.dll'))).toBe(true);
    expect(
      fs.existsSync(path.join(targetRoot, 'ue4ss', 'UE4SS.prepatched.pdb')),
    ).toBe(false);
    expect(
      fs.existsSync(
        path.join(
          targetRoot,
          'ue4ss',
          'Mods',
          'OmeggaBridge',
          'Scripts',
          'main.lua',
        ),
      ),
    ).toBe(true);
    expect(
      fs.existsSync(
        path.join(
          targetRoot,
          'ue4ss',
          'BrickadiaServer-Win64-Shipping',
          'UE4SS-settings.ini',
        ),
      ),
    ).toBe(true);
    expect(
      fs.existsSync(
        path.join(targetRoot, 'ue4ss', 'Brickadia', 'UE4SS-settings.ini'),
      ),
    ).toBe(true);
    expect(
      fs.existsSync(path.join(targetRoot, 'ue4ss', 'VTableLayout.ini')),
    ).toBe(true);
    expect(
      fs.existsSync(
        path.join(
          targetRoot,
          'ue4ss',
          'Brickadia',
          'Mods',
          'OmeggaBridge',
          'Scripts',
          'main.lua',
        ),
      ),
    ).toBe(true);
    expect(
      fs.existsSync(
        path.join(targetRoot, 'ue4ss', 'Mods', 'BMF', 'Scripts', 'main.lua'),
      ),
    ).toBe(true);
    expect(
      fs.existsSync(
        path.join(
          targetRoot,
          'ue4ss',
          'Brickadia',
          'Mods',
          'BMF',
          'Scripts',
          'main.lua',
        ),
      ),
    ).toBe(true);
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Brickadia', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('OmeggaBridge : 1');
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Brickadia', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('BMF : 1');
    expect(
      fs.existsSync(
        path.join(
          targetRoot,
          'ue4ss',
          'Brickadia',
          'UE4SS_Signatures',
          'FName_Constructor.lua',
        ),
      ),
    ).toBe(true);
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('OmeggaBridge : 1');
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('BMF : 1');
    expect(
      JSON.parse(
        fs.readFileSync(
          path.join(targetRoot, 'ue4ss', 'Mods', 'mods.json'),
          'utf8',
        ),
      ),
    ).toContainEqual({ mod_name: 'BMF', mod_enabled: true });

    disableManagedUe4ss(targetRoot);
    expect(fs.existsSync(path.join(targetRoot, 'dwmapi.dll'))).toBe(false);
    expect(
      fs.existsSync(path.join(targetRoot, 'dwmapi.ue4ss-disabled.dll')),
    ).toBe(true);
    expect(fs.existsSync(path.join(targetRoot, 'ue4ss'))).toBe(false);
    expect(fs.existsSync(path.join(targetRoot, 'ue4ss-disabled'))).toBe(true);
  });

  it('reuses an existing managed UE4SS payload without recopying target files', () => {
    const sourceRoot = makeTempDir();
    const targetRoot = makeTempDir();
    const compatibilityWorkspace = createTempCompatibilityWorkspace();
    const targetProxyDll = path.join(targetRoot, 'dwmapi.dll');

    fs.mkdirSync(path.join(sourceRoot, 'ue4ss', 'Mods'), { recursive: true });
    fs.writeFileSync(path.join(sourceRoot, 'dwmapi.dll'), 'proxy');
    fs.writeFileSync(path.join(sourceRoot, 'ue4ss', 'UE4SS.dll'), 'dll');
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'UE4SS-settings.ini'),
      '[General]\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.txt'),
      'Keybinds : 1\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.json'),
      '[]\n',
    );

    process.env.OMEGGA_UE4SS_SOURCE = sourceRoot;
    process.env.OMEGGA_UE4SS_RE_ROOT = compatibilityWorkspace.workspaceRoot;
    installManagedUe4ss(targetRoot);

    const copyFileSpy = vi.spyOn(fs, 'copyFileSync');

    installManagedUe4ss(targetRoot);

    expect(
      copyFileSpy.mock.calls.some(
        ([, destination]) => destination === targetProxyDll,
      ),
    ).toBe(false);
  });

  it('uses OMEGGA_BMF_SOURCE_DIR as the managed BMF package override', () => {
    const sourceRoot = makeTempDir();
    const targetRoot = makeTempDir();
    const bmfSource = makeTempDir();
    const compatibilityWorkspace = createTempCompatibilityWorkspace();

    fs.mkdirSync(path.join(sourceRoot, 'ue4ss', 'Mods'), { recursive: true });
    fs.writeFileSync(path.join(sourceRoot, 'dwmapi.dll'), 'proxy');
    fs.writeFileSync(path.join(sourceRoot, 'ue4ss', 'UE4SS.dll'), 'dll');
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'UE4SS-settings.ini'),
      '[General]\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.txt'),
      'Keybinds : 1\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.json'),
      '[]\n',
    );

    fs.mkdirSync(path.join(bmfSource, 'Scripts'), { recursive: true });
    fs.writeFileSync(path.join(bmfSource, 'bmf.json'), '{"name":"BMF"}\n');
    fs.writeFileSync(
      path.join(bmfSource, 'Scripts', 'main.lua'),
      'return nil\n',
    );
    fs.writeFileSync(path.join(bmfSource, 'override-marker.txt'), 'override\n');
    const frameTelemetrySource = path.join(
      path.dirname(bmfSource),
      'BMFFrameTelemetry',
    );
    fs.mkdirSync(path.join(frameTelemetrySource, 'dlls'), { recursive: true });
    fs.writeFileSync(
      path.join(frameTelemetrySource, 'dlls', 'main.dll'),
      'frame telemetry dll\n',
    );
    fs.writeFileSync(
      path.join(frameTelemetrySource, 'README.md'),
      'frame telemetry\n',
    );

    process.env.OMEGGA_UE4SS_SOURCE = sourceRoot;
    process.env.OMEGGA_UE4SS_RE_ROOT = compatibilityWorkspace.workspaceRoot;
    process.env.OMEGGA_BMF_SOURCE_DIR = bmfSource;

    installManagedUe4ss(targetRoot);

    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Mods', 'BMF', 'override-marker.txt'),
        'utf8',
      ),
    ).toBe('override\n');
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('BMF : 1');
    expect(
      fs.readFileSync(
        path.join(
          targetRoot,
          'ue4ss',
          'Mods',
          'BMFFrameTelemetry',
          'README.md',
        ),
        'utf8',
      ),
    ).toBe('frame telemetry\n');
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('BMFFrameTelemetry : 1');
    expect(
      JSON.parse(
        fs.readFileSync(
          path.join(targetRoot, 'ue4ss', 'Mods', 'mods.json'),
          'utf8',
        ),
      ),
    ).toContainEqual({
      mod_name: 'BMFFrameTelemetry',
      mod_enabled: true,
    });
  });

  it('replaces stale managed BMF runtime-only alias directories', () => {
    const sourceRoot = makeTempDir();
    const installRoot = makeTempDir();
    const targetRoot = path.join(
      installRoot,
      'steam_installs',
      'main',
      'Brickadia',
      'Binaries',
      'Win64',
    );
    const bmfSource = makeTempDir();
    const compatibilityWorkspace = createTempCompatibilityWorkspace();

    fs.mkdirSync(path.join(sourceRoot, 'ue4ss', 'Mods'), { recursive: true });
    fs.writeFileSync(path.join(sourceRoot, 'dwmapi.dll'), 'proxy');
    fs.writeFileSync(path.join(sourceRoot, 'ue4ss', 'UE4SS.dll'), 'dll');
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'UE4SS-settings.ini'),
      '[General]\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.txt'),
      'Keybinds : 1\n',
    );
    fs.writeFileSync(
      path.join(sourceRoot, 'ue4ss', 'Mods', 'mods.json'),
      '[]\n',
    );

    fs.mkdirSync(path.join(bmfSource, 'Scripts'), { recursive: true });
    fs.writeFileSync(path.join(bmfSource, 'bmf.json'), '{"name":"BMF"}\n');
    fs.writeFileSync(
      path.join(bmfSource, 'Scripts', 'main.lua'),
      'return nil\n',
    );

    const staleAliasBmf = path.join(
      targetRoot,
      'ue4ss',
      'main',
      'Mods',
      'BMF',
    );
    fs.mkdirSync(path.join(staleAliasBmf, 'runtime', 'commands'), {
      recursive: true,
    });
    fs.writeFileSync(path.join(staleAliasBmf, 'stale-marker.txt'), 'stale\n');

    process.env.OMEGGA_UE4SS_SOURCE = sourceRoot;
    process.env.OMEGGA_UE4SS_RE_ROOT = compatibilityWorkspace.workspaceRoot;
    process.env.OMEGGA_BMF_SOURCE_DIR = bmfSource;

    installManagedUe4ss(targetRoot);

    expect(
      fs.readFileSync(
        path.join(staleAliasBmf, 'Scripts', 'main.lua'),
        'utf8',
      ),
    ).toBe('return nil\n');
    expect(fs.existsSync(path.join(staleAliasBmf, 'stale-marker.txt'))).toBe(
      false,
    );
    expect(
      fs.readFileSync(
        path.join(targetRoot, 'ue4ss', 'main', 'Mods', 'mods.txt'),
        'utf8',
      ),
    ).toContain('BMF : 1');
  });

  it('parses UE4SS compatibility diagnostics', () => {
    const targetRoot = makeTempDir();
    const ue4ssDir = path.join(targetRoot, 'ue4ss', 'main');
    fs.mkdirSync(ue4ssDir, { recursive: true });
    fs.writeFileSync(
      path.join(ue4ssDir, 'UE4SS.log'),
      [
        '[2026-03-06 16:00:03.1106958] UE4SS - v3.0.1 Beta #0 - Git SHA #01e0a584',
        '[2026-03-06 16:00:03.1200000] Found configuration for game: main',
        '[2026-03-06 16:00:03.2631603] [PS] Found EngineVersion: 5.5',
        '[2026-03-06 16:00:03.2639619] [PS] Failed to find FName::FName(wchar_t*): FNameCtorWchar: found 2 unique values [A, B]',
        "[2026-03-06 16:00:03.2642467] [PS] You can supply your own AOB in 'UE4SS_Signatures/FName_Constructor.lua'",
        '[2026-03-06 16:00:03.2678489] [PS] Scan failed',
      ].join('\n'),
    );

    const diagnostics = readUe4ssDiagnostics(targetRoot);
    expect(diagnostics.loaded).toBe(true);
    expect(diagnostics.engineVersion).toBe('5.5');
    expect(diagnostics.compatibilityOk).toBe(false);
    expect(diagnostics.hasCustomGameConfig).toBe(true);
    expect(diagnostics.missingSymbols).toContain('FName::FName(wchar_t*)');
    expect(diagnostics.signatureHints).toContain(
      'UE4SS_Signatures/FName_Constructor.lua',
    );
  });

  it('validates and resolves the external compatibility bundle workspace', () => {
    const compatibilityWorkspace = createTempCompatibilityWorkspace();
    process.env.OMEGGA_UE4SS_RE_ROOT = compatibilityWorkspace.workspaceRoot;

    const validation = validateUe4ssCompatibilityBundle();
    expect(validation.ok).toBe(true);
    expect(validation.validated).toBe(false);
    expect(validation.errors).toEqual([]);
    expect(validation.bundleDir).toBe(compatibilityWorkspace.bundleRoot);

    const bundle = resolveUe4ssCompatibilityBundle();
    expect(bundle.root).toBe(compatibilityWorkspace.bundleRoot);
    expect(bundle.manifest.validated).toBe(false);
  });

  it('rejects stale compatibility bundle hashes', () => {
    const compatibilityWorkspace = createTempCompatibilityWorkspace();
    process.env.OMEGGA_UE4SS_RE_ROOT = compatibilityWorkspace.workspaceRoot;

    const staleFile = path.join(
      compatibilityWorkspace.bundleRoot,
      'CustomGameConfigs',
      'Brickadia',
      'UE4SS_Signatures',
      'GNatives.lua',
    );
    fs.writeFileSync(staleFile, '-- changed\nreturn nil\n');

    const validation = validateUe4ssCompatibilityBundle();
    expect(validation.ok).toBe(false);
    expect(validation.invalidHashes).toContain(
      'CustomGameConfigs/Brickadia/UE4SS_Signatures/GNatives.lua',
    );
  });

  it('exchanges messages with the file-backed UE4SS bridge transport', async () => {
    const bridge = new Ue4ssBridgeHost(makeTempDir());
    const env = bridge.start();
    const inboxPath = env.OMEGGA_UE4SS_INBOX;
    const outboxPath = env.OMEGGA_UE4SS_OUTBOX;
    let inboxOffset = 0;
    const consoleChunks: string[] = [];
    const methodsSeen: string[] = [];

    bridge.on('console.chunk', payload => {
      consoleChunks.push(String(payload.line));
    });

    fs.appendFileSync(
      outboxPath,
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.hello',
        params: {
          session: env.OMEGGA_UE4SS_SESSION,
          transport: 'file',
        },
      }) + '\n',
    );
    fs.appendFileSync(
      outboxPath,
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'bridge.capabilities',
        params: {
          chat_broadcast: true,
          console_exec: true,
          players_list: true,
          server_status: true,
        },
      }) + '\n',
    );

    const fakeMod = setInterval(() => {
      const contents = fs.readFileSync(inboxPath, 'utf8');
      const nextChunk = contents.slice(inboxOffset);
      inboxOffset = contents.length;

      for (const line of nextChunk.split(/\r?\n/).filter(Boolean)) {
        const message = JSON.parse(line);
        methodsSeen.push(message.method);
        if (message.method === 'bridge.ping') {
          fs.appendFileSync(
            outboxPath,
            JSON.stringify({
              jsonrpc: '2.0',
              id: message.id,
              result: {
                pong: true,
                nonce: message.params.nonce,
              },
            }) + '\n',
          );
        } else if (
          message.method === 'console.exec' ||
          message.method === 'server.status' ||
          message.method === 'players.list'
        ) {
          const outputLine =
            message.method === 'players.list'
              ? '0) BP_PlayerState_C PersistentLevel.BP_PlayerState_C_1.UserName = Ty'
              : 'Server Name: Test Server';
          fs.appendFileSync(
            outboxPath,
            JSON.stringify({
              jsonrpc: '2.0',
              method: 'console.chunk',
              params: {
                request_id: message.id,
                chunk_index: 1,
                line_b64: Buffer.from(outputLine, 'utf8').toString('base64'),
              },
            }) + '\n',
          );
          fs.appendFileSync(
            outboxPath,
            JSON.stringify({
              jsonrpc: '2.0',
              method: 'console.complete',
              params: {
                request_id: message.id,
                success: true,
              },
            }) + '\n',
          );
          fs.appendFileSync(
            outboxPath,
            JSON.stringify({
              jsonrpc: '2.0',
              id: message.id,
              result: {
                accepted: true,
              },
            }) + '\n',
          );
        } else if (message.method === 'chat.broadcast') {
          fs.appendFileSync(
            outboxPath,
            JSON.stringify({
              jsonrpc: '2.0',
              id: message.id,
              result: {
                accepted: true,
                executor: 'typed-chat-broadcast',
              },
            }) + '\n',
          );
        }
      }
    }, 10);
    fakeMod.unref?.();

    await expect(bridge.waitUntilReady(1000)).resolves.toMatchObject({
      transport: 'file',
    });
    await expect(bridge.ping(1000)).resolves.toMatchObject({ pong: true });
    expect(bridge.hasCapability('server_status')).toBe(true);
    await expect(
      bridge.execCommand('Server.Status', 1000),
    ).resolves.toMatchObject({
      accepted: true,
    });
    await expect(bridge.requestServerStatus(1000)).resolves.toMatchObject({
      accepted: true,
    });
    await expect(
      bridge.requestPlayers('usernames', {}, 1000),
    ).resolves.toMatchObject({
      accepted: true,
    });
    await expect(
      bridge.broadcast('Hello from typed test', 1000),
    ).resolves.toMatchObject({
      accepted: true,
      executor: 'typed-chat-broadcast',
    });
    expect(consoleChunks).toContain('Server Name: Test Server');
    expect(consoleChunks).toContain(
      '0) BP_PlayerState_C PersistentLevel.BP_PlayerState_C_1.UserName = Ty',
    );
    expect(methodsSeen).toContain('server.status');
    expect(methodsSeen).toContain('players.list');
    expect(methodsSeen).toContain('chat.broadcast');

    clearInterval(fakeMod);
    bridge.stop();
  });
});
