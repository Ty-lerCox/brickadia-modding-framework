import { CONFIG_SAVED_DIR, DATA_PATH } from '@/softconfig';
import type { IConfig } from '@config/types';
import { getServerConfigDirectory } from '@util/platform';
import fs from 'node:fs';
import path from 'node:path';

const SERVER_SETTINGS_FILENAME = 'GameUserSettings.ini';
export const MAX_SERVER_STATUS_SETTINGS_BYTES = 64 * 1024;

export type ServerStatusIdentitySource =
  | 'game_user_settings'
  | 'omegga_config'
  | 'fallback';

export type ServerStatusIdentity = {
  serverName: string;
  description: string;
  source: ServerStatusIdentitySource;
};

export type BrickadiaBuildInfoSnapshot = {
  branchLabel: string | null;
  cl: string | null;
  networkCl: string | null;
  steamBuild: string | null;
};

const SERVER_STATUS_TABLE_HEADER =
  '* Name                     | Ping   | Time     | Roles              | Address                | Id                              ';

export const buildCachedServerStatusLines = (
  identity: ServerStatusIdentity,
  uptimeMs: number,
) => [
  `Server Name: ${identity.serverName}`,
  `Description: ${identity.description}`,
  'Bricks: 0',
  'Components: 0',
  `Time: ${Math.max(0, Math.floor(Number(uptimeMs) || 0))}ms`,
  SERVER_STATUS_TABLE_HEADER,
];

export const emptyBrickadiaBuildInfoSnapshot =
  (): BrickadiaBuildInfoSnapshot => ({
    branchLabel: null,
    cl: null,
    networkCl: null,
    steamBuild: null,
  });

/** Update the cached build identity from the stdout stream Omegga already owns. */
export const updateBrickadiaBuildInfoSnapshot = (
  current: BrickadiaBuildInfoSnapshot,
  line: string,
): BrickadiaBuildInfoSnapshot => {
  const text = String(line);
  const branchLabel =
    text.match(/Brickadia [^(]+\([^)]*CL\d+\)/)?.[0] ?? current.branchLabel;
  const cl = branchLabel?.match(/CL(\d+)/)?.[1] ?? current.cl;
  const networkCl =
    text.match(/\bUsing network version\s+(\d+)\b/i)?.[1] ?? current.networkCl;
  const steamBuild =
    text.match(/\b(?:Steam\s+)?build\s+(\d+)\b/i)?.[1] ?? current.steamBuild;

  if (
    branchLabel === current.branchLabel &&
    cl === current.cl &&
    networkCl === current.networkCl &&
    steamBuild === current.steamBuild
  ) {
    return current;
  }

  return {
    branchLabel,
    cl,
    networkCl,
    steamBuild,
  };
};

const sanitizeStatusLineValue = (value: unknown) => {
  const normalized = String(value ?? '')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .trim();
  if (
    normalized.length >= 2 &&
    normalized.startsWith('"') &&
    normalized.endsWith('"')
  ) {
    return normalized.slice(1, -1).trim();
  }
  return normalized;
};

const readIniValue = (contents: string, key: string) => {
  const prefix = `${key}=`;
  for (const line of contents.split(/\r?\n/)) {
    if (line.startsWith(prefix)) {
      return sanitizeStatusLineValue(line.slice(prefix.length));
    }
  }
  return '';
};

export const getServerStatusSettingsPath = (
  serverPath: string,
  config: IConfig,
) =>
  path.join(
    serverPath,
    DATA_PATH,
    config.server.savedDir ?? CONFIG_SAVED_DIR,
    getServerConfigDirectory(),
    SERVER_SETTINGS_FILENAME,
  );

const readCurrentServerStatusIdentity = (
  serverPath: string,
  config: IConfig,
): Omit<ServerStatusIdentity, 'source'> | null => {
  const settingsPath = getServerStatusSettingsPath(serverPath, config);
  let descriptor: number | null = null;
  try {
    descriptor = fs.openSync(settingsPath, 'r');
    const buffer = Buffer.alloc(MAX_SERVER_STATUS_SETTINGS_BYTES + 1);
    const bytesRead = fs.readSync(descriptor, buffer, 0, buffer.length, 0);
    if (bytesRead <= 0 || bytesRead > MAX_SERVER_STATUS_SETTINGS_BYTES)
      return null;
    const contents = buffer.subarray(0, bytesRead).toString('utf8');
    return {
      serverName: readIniValue(contents, 'ServerName'),
      description: readIniValue(contents, 'ServerDescription'),
    };
  } catch {
    return null;
  } finally {
    if (descriptor !== null) fs.closeSync(descriptor);
  }
};

/**
 * Resolve the plain identity snapshot handed to the in-process UE4SS bridge.
 * The existing GameUserSettings.ini wins because it is what the launched
 * Brickadia process currently consumes. Omegga config is a bounded fallback.
 */
export const resolveServerStatusIdentity = (
  serverPath: string,
  config: IConfig,
): ServerStatusIdentity => {
  const current = readCurrentServerStatusIdentity(serverPath, config);
  const configuredName = sanitizeStatusLineValue(config.server.name);
  const configuredDescription = sanitizeStatusLineValue(
    config.server.description,
  );
  const currentName = sanitizeStatusLineValue(current?.serverName);

  if (currentName) {
    return {
      serverName: currentName,
      description:
        sanitizeStatusLineValue(current?.description) || configuredDescription,
      source: 'game_user_settings',
    };
  }

  if (configuredName) {
    return {
      serverName: configuredName,
      description: configuredDescription,
      source: 'omegga_config',
    };
  }

  return {
    serverName: 'Brickadia Server',
    description: configuredDescription,
    source: 'fallback',
  };
};
