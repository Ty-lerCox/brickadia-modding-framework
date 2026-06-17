import os from 'node:os';
import path from 'node:path';
import { existsSync } from 'node:fs';

export const IS_WINDOWS = process.platform === 'win32';

export const POST_INSTALL_SCRIPTS = IS_WINDOWS
  ? ['setup.ps1', 'setup.cmd', 'setup.bat', 'setup.sh']
  : ['setup.sh'];

export const RPC_PLUGIN_FILES = IS_WINDOWS
  ? [
      'omegga_plugin.exe',
      'omegga_plugin.cmd',
      'omegga_plugin.bat',
      'omegga_plugin.js',
      'omegga_plugin',
    ]
  : ['omegga_plugin'];

export const TEMPLATE_EXECUTABLES = Array.from(
  new Set([...POST_INSTALL_SCRIPTS, ...RPC_PLUGIN_FILES]),
);

export function getConfigHome(projectName: string) {
  if (!IS_WINDOWS) return path.join(os.homedir(), '.config', projectName);

  return path.join(
    process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming'),
    projectName,
  );
}

export function getGameBinaryPath() {
  return path.join(
    'Binaries',
    IS_WINDOWS ? 'Win64' : 'Linux',
    IS_WINDOWS
      ? 'BrickadiaServer-Win64-Shipping.exe'
      : 'BrickadiaServer-Linux-Shipping',
  );
}

export function getSteamCmdFilename() {
  return IS_WINDOWS ? 'steamcmd.exe' : 'steamcmd.sh';
}

export function getServerConfigDirectory() {
  return path.join('Config', IS_WINDOWS ? 'WindowsServer' : 'LinuxServer');
}

export function resolveExistingPath(
  dir: string,
  candidates: string[],
): string | null {
  for (const candidate of candidates) {
    const filepath = path.join(dir, candidate);
    if (existsSync(filepath)) return filepath;
  }

  return null;
}
