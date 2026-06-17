import Logger from '@/logger';
import { MatchGenerator } from './types';
import path from 'path';
import { existsSync, readFileSync } from 'node:fs';

const versionRegExp =
  /Brickadia (?<branchName>.+?) \(.+-CL(?<version>\d+)\), Engine (?<engineVersion>.+)/;

export function extractBrickadiaVersion(text: string): number | undefined {
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(versionRegExp);
    if (!match?.groups?.version) continue;
    return Number(match.groups.version);
  }

  return undefined;
}

const version: MatchGenerator<number> = omegga => {
  const LOG_PATH = path.join(omegga.dataPath, 'Saved/Logs/Brickadia.log');

  const emitVersion = (version: number) => {
    if (!Number.isFinite(version) || version <= 0) return;
    if (omegga.version === version) return;

    omegga.emit('version', version);
    Logger.verbose('Brickadia Version', version);
    omegga.version = version;
  };

  const readVersionFromLog = (attempt = 0) => {
    if (omegga.version > 0) return;

    if (!existsSync(LOG_PATH)) {
      if (attempt < 20) {
        setTimeout(() => readVersionFromLog(attempt + 1), 250);
      } else {
        Logger.warnp(
          'Log file not found',
          LOG_PATH.yellow + '. Cannot check version.',
        );
      }
      return;
    }

    try {
      const version = extractBrickadiaVersion(readFileSync(LOG_PATH, 'utf8'));
      if (version) {
        emitVersion(version);
        return;
      }
    } catch (err) {
      Logger.verbose('Failed to read Brickadia version from log file', err);
    }

    if (attempt < 20) {
      setTimeout(() => readVersionFromLog(attempt + 1), 250);
    } else {
      Logger.warnp('Could not parse Brickadia version from', LOG_PATH.yellow);
    }
  };

  return {
    pattern(line, _logMatch) {
      const directVersion = extractBrickadiaVersion(line);
      if (directVersion) {
        emitVersion(directVersion);
        return directVersion;
      }

      if (!line.startsWith('LogPakFile')) return;
      if (line !== 'LogPakFile: Initializing PakPlatformFile') return;

      // The version line
      // Brickadia Release-EA1 (PC-Shipping-CL11633), Engine 444a09f18f48
      // is not printed in the game logs.. only the log file...
      readVersionFromLog();

      return 1;
    },
    callback(_version) {},
  };
};

export default version;
