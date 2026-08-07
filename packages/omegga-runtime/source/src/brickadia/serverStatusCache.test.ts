import type { IConfig } from '@config/types';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  buildCachedServerStatusLines,
  emptyBrickadiaBuildInfoSnapshot,
  getServerStatusSettingsPath,
  MAX_SERVER_STATUS_SETTINGS_BYTES,
  resolveServerStatusIdentity,
  updateBrickadiaBuildInfoSnapshot,
} from './serverStatusCache';

const tempDirs: string[] = [];
const makeConfig = (server: Partial<IConfig['server']> = {}): IConfig => ({
  server: { port: 7777, ...server },
});
const makeTempDir = () => {
  const directory = fs.mkdtempSync(
    path.join(os.tmpdir(), 'omegga-status-cache-'),
  );
  tempDirs.push(directory);
  return directory;
};

const writeSettings = (
  serverPath: string,
  config: IConfig,
  contents: string,
) => {
  const settingsPath = getServerStatusSettingsPath(serverPath, config);
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, contents);
};

afterEach(() => {
  while (tempDirs.length > 0) {
    const directory = tempDirs.pop();
    if (directory) fs.rmSync(directory, { recursive: true, force: true });
  }
});

describe('UE4SS server status cache', () => {
  it('builds the compatibility status chunk entirely from cached plain data', () => {
    expect(
      buildCachedServerStatusLines(
        {
          serverName: 'Cached Server',
          description: 'Cached description',
          source: 'omegga_config',
        },
        12_345,
      ),
    ).toEqual([
      'Server Name: Cached Server',
      'Description: Cached description',
      'Bricks: 0',
      'Components: 0',
      'Time: 12345ms',
      '* Name                     | Ping   | Time     | Roles              | Address                | Id                              ',
    ]);
  });

  it('uses the current GameUserSettings identity without mutating it', () => {
    const serverPath = makeTempDir();
    const config = makeConfig({
      name: 'Stale Omegga Name',
      description: 'Configured description',
    });
    const contents = [
      '[Server__BP_ServerSettings_General_C BP_ServerSettings_General_C]',
      'ServerName=CityRPG v1 - Under Maintenance',
      'ServerDescription=Current description',
      '',
    ].join('\n');
    writeSettings(serverPath, config, contents);

    expect(resolveServerStatusIdentity(serverPath, config)).toEqual({
      serverName: 'CityRPG v1 - Under Maintenance',
      description: 'Current description',
      source: 'game_user_settings',
    });
    expect(
      fs.readFileSync(getServerStatusSettingsPath(serverPath, config), 'utf8'),
    ).toBe(contents);
  });

  it('bounds the startup read and sanitizes the config fallback', () => {
    const serverPath = makeTempDir();
    const config = makeConfig({
      name: 'Configured\nServer',
      description: 'One\r\nLine',
    });
    writeSettings(
      serverPath,
      config,
      'x'.repeat(MAX_SERVER_STATUS_SETTINGS_BYTES + 1),
    );

    expect(resolveServerStatusIdentity(serverPath, config)).toEqual({
      serverName: 'Configured Server',
      description: 'One Line',
      source: 'omegga_config',
    });
  });

  it('maintains build identity from existing stdout without reading the log', () => {
    const empty = emptyBrickadiaBuildInfoSnapshot();
    expect(updateBrickadiaBuildInfoSnapshot(empty, 'unrelated line')).toBe(
      empty,
    );
    expect(
      updateBrickadiaBuildInfoSnapshot(
        empty,
        'Brickadia EA3 (PC-Shipping-CL14860), Engine abd7468205d6',
      ),
    ).toEqual({
      branchLabel: 'Brickadia EA3 (PC-Shipping-CL14860)',
      cl: '14860',
      networkCl: null,
      steamBuild: null,
    });
    expect(
      updateBrickadiaBuildInfoSnapshot(empty, 'Using network version 24045983'),
    ).toMatchObject({ networkCl: '24045983' });
  });

  it('keeps Server.Status cache-only while preserving compatibility lines', () => {
    const templatePath = path.resolve(
      __dirname,
      '../../templates/windows-ue4ss/ue4ss/Mods/OmeggaBridge/Scripts/main.lua',
    );
    const source = fs.readFileSync(templatePath, 'utf8');
    const statusStart = source.indexOf('local function build_status_output()');
    const statusEnd = source.indexOf(
      'function build_status_output_unsafe()',
      statusStart,
    );
    const statusPath = source.slice(statusStart, statusEnd);
    const cacheStart = source.indexOf(
      'local function build_status_output_from_cache()',
    );
    const cacheEnd = source.indexOf(
      'local function is_valid_object(object)',
      cacheStart,
    );
    const cachePath = source.slice(cacheStart, cacheEnd);

    expect(statusStart).toBeGreaterThan(-1);
    expect(statusEnd).toBeGreaterThan(statusStart);
    expect(cacheStart).toBeGreaterThan(-1);
    expect(cacheEnd).toBeGreaterThan(cacheStart);
    expect(statusPath).toContain('build_status_output_from_cache()');
    expect(statusPath).not.toMatch(
      /read_file\s*\(|io\.open|get_brickadia_log/i,
    );
    expect(cachePath).not.toMatch(
      /read_file\s*\(|io\.open|get_brickadia_log|FindAllOf|GetPropertyValue/i,
    );
    expect(source).not.toContain('build_status_output_from_log');
    expect(source).not.toContain('Brickadia Windows UE4SS');
    expect(cachePath).toContain('"Server Name: "');
    expect(cachePath).toContain('"Description: "');
    expect(cachePath).toContain('"Bricks: 0"');
    expect(cachePath).toContain('"Components: 0"');
    expect(source).toContain('server_status_cache_hits_total');
    expect(source).toContain('server_status_cache_server_name');
    expect(source).toContain('server_status_request_full_log_scans_total');

    const serverSource = fs.readFileSync(
      path.resolve(__dirname, 'server.ts'),
      'utf8',
    );
    expect(serverSource).not.toContain('readBrickadiaBuildInfo(');
    expect(serverSource).not.toContain('getBrickadiaLogPath(');
    expect(serverSource).toContain('updateBrickadiaBuildInfoSnapshot(');
    expect(serverSource).toContain(
      "new Set(['Server.Status', 'br.Server.Status'])",
    );
    expect(serverSource).toContain(
      'SERVER_STATUS_COMMANDS.has(normalizedLine)',
    );
    expect(serverSource).toContain('this.emitSyntheticServerStatus();');
    expect(serverSource).not.toContain('.requestServerStatus(');
  });
});
