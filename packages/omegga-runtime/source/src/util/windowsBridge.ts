import Logger from '@/logger';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { IS_WINDOWS } from './platform';

const BRIDGE_PROJECT_DIR = path.resolve(
  __dirname,
  '../../tools/windows-console-bridge',
);
const BRIDGE_MANIFEST_PATH = path.join(BRIDGE_PROJECT_DIR, 'Cargo.toml');
const BRIDGE_BINARY_PATH = path.join(
  BRIDGE_PROJECT_DIR,
  'target',
  'release',
  'omegga-console-bridge.exe',
);

function getCargoPath() {
  const candidates = [
    process.env.CARGO,
    path.join(os.homedir(), '.cargo', 'bin', 'cargo.exe'),
    'cargo',
  ].filter(Boolean) as string[];

  return candidates.find(candidate => candidate === 'cargo' || fs.existsSync(candidate));
}

function listSourceFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];

  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) return listSourceFiles(fullPath);
    return fullPath.endsWith('.rs') ? [fullPath] : [];
  });
}

function needsBridgeBuild(binaryPath: string) {
  if (!fs.existsSync(binaryPath)) return true;

  const binaryMtime = fs.statSync(binaryPath).mtimeMs;
  const inputs = [BRIDGE_MANIFEST_PATH, ...listSourceFiles(path.join(BRIDGE_PROJECT_DIR, 'src'))];

  return inputs.some(file => fs.existsSync(file) && fs.statSync(file).mtimeMs > binaryMtime);
}

export function getWindowsConsoleBridgeProjectDir() {
  return BRIDGE_PROJECT_DIR;
}

export function getWindowsConsoleBridgeBinaryPath() {
  return BRIDGE_BINARY_PATH;
}

export function ensureWindowsConsoleBridgeBinary() {
  if (!IS_WINDOWS) return null;

  if (!fs.existsSync(BRIDGE_MANIFEST_PATH)) {
    throw new Error(`Windows console bridge manifest not found at ${BRIDGE_MANIFEST_PATH}`);
  }

  if (!needsBridgeBuild(BRIDGE_BINARY_PATH)) {
    return BRIDGE_BINARY_PATH;
  }

  const cargo = getCargoPath();
  if (!cargo) {
    throw new Error(
      'Rust cargo was not found. Install Rust to build the Windows console bridge.',
    );
  }

  Logger.logp('Building Windows console bridge...');
  const result = spawnSync(
    cargo,
    ['build', '--release', '--manifest-path', BRIDGE_MANIFEST_PATH],
    {
      cwd: BRIDGE_PROJECT_DIR,
      encoding: 'utf8',
      stdio: 'pipe',
      windowsHide: true,
    },
  );

  if (Logger.VERBOSE && result.stdout?.trim()) Logger.verbose(result.stdout.trim());
  if (Logger.VERBOSE && result.stderr?.trim()) Logger.verbose(result.stderr.trim());

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0 || !fs.existsSync(BRIDGE_BINARY_PATH)) {
    throw new Error(
      result.stderr?.trim() ||
        result.stdout?.trim() ||
        'Failed to build Windows console bridge.',
    );
  }

  return BRIDGE_BINARY_PATH;
}
