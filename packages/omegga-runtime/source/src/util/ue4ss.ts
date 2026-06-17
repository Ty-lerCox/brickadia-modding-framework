import Logger from '@/logger';
import {
  CONFIG_HOME,
  CONFIG_SAVED_DIR,
  GAME_BIN_PATH,
  getOverrideGameBinary,
  getSteamGameDir,
  getSteamInstallDir,
} from '@/softconfig';
import { IConfig } from '@config/types';
import { IS_WINDOWS } from '@util/platform';
import 'colors';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const UE4SS_PROXY_DLL = 'dwmapi.dll';
const UE4SS_PROXY_DLL_DISABLED = 'dwmapi.ue4ss-disabled.dll';
const UE4SS_DIRNAME = 'ue4ss';
const UE4SS_DISABLED_DIRNAME = 'ue4ss-disabled';
const UE4SS_LOG_FILENAME = 'UE4SS.log';
const UE4SS_MANAGED_MARKER = 'omegga-managed.json';
const UE4SS_COMPAT_WORKSPACE_DIRNAME = 'brickadia-ue4ss-re';
const UE4SS_COMPAT_BUNDLES_DIRNAME = 'bundles';
const UE4SS_BUNDLE_MANIFEST_FILENAME = 'manifest.json';
const UE4SS_VALIDATION_REPORT_JSON_FILENAME = 'validation-report.json';
const UE4SS_VALIDATION_REPORT_MARKDOWN_FILENAME = 'validation-report.md';
const UE4SS_VTABLE_LAYOUT_FILENAME = 'VTableLayout.ini';
const UE4SS_CACHE_DIR = path.join(CONFIG_HOME, 'ue4ss');
const UE4SS_BRIDGE_MOD_NAME = 'OmeggaBridge';
const UE4SS_PROBE_MOD_NAME = 'OmeggaBridgeProbe';
const BMF_MOD_NAME = 'BMF';
const BMF_SOCKET_MOD_NAME = 'BMFSocket';
const BMF_FRAME_TELEMETRY_MOD_NAME = 'BMFFrameTelemetry';
const BMF_SOURCE_ENV = 'OMEGGA_BMF_SOURCE_DIR';
const TEMPLATE_ROOT = path.resolve(
  __dirname,
  '..',
  '..',
  'templates',
  'windows-ue4ss',
);
const CUSTOM_GAME_CONFIG_ALIASES = [
  'Brickadia',
  'BrickadiaServer',
  'BrickadiaServer-Win64-Shipping',
] as const;
const UE4SS_PINNED_COMPATIBILITY_BUNDLE_ID =
  process.env.OMEGGA_UE4SS_COMPAT_BUNDLE ?? 'CL13530';
const COMPATIBILITY_BUNDLE_REQUIRED_FILES = [
  UE4SS_VTABLE_LAYOUT_FILENAME,
  'CustomGameConfigs/Brickadia/UE4SS-settings.ini',
  'CustomGameConfigs/Brickadia/UE4SS_Signatures/CallFunctionByNameWithArguments.lua',
  'CustomGameConfigs/Brickadia/UE4SS_Signatures/FName_ToString.lua',
  'CustomGameConfigs/Brickadia/UE4SS_Signatures/GNatives.lua',
  'CustomGameConfigs/Brickadia/UE4SS_Signatures/GUObjectArray.lua',
  'CustomGameConfigs/Brickadia/UE4SS_Signatures/GUObjectHashTables.lua',
  UE4SS_VALIDATION_REPORT_JSON_FILENAME,
  UE4SS_VALIDATION_REPORT_MARKDOWN_FILENAME,
] as const;
const RM_SYNC_RETRY_OPTIONS = {
  force: true,
  maxRetries: 5,
  retryDelay: 100,
} as const;

export const UE4SS_MANIFEST = {
  version: '3.0.1-940-g01e0a584',
  bundleDirName: 'zDEV-UE4SS_v3.0.1-940-g01e0a584',
  pinnedCompatibilityBundleId: UE4SS_PINNED_COMPATIBILITY_BUNDLE_ID,
  reverseEngineeringEnginePath:
    process.env.OMEGGA_UE4SS_ENGINE_PATH ??
    'C:\\Program Files\\Epic Games\\UE_5.5',
} as const;

export type WindowsControlBackend = 'ue4ss' | 'bridge';

export type ResolvedGameBinary = {
  gameBinary: string;
  isSteam: boolean;
  overrideBinary: string | null;
  steamBinary: string;
  steamBeta: string;
};

export type ManagedUe4ssInstall = {
  sourceRoot: string;
  cacheRoot: string;
  targetWin64Dir: string;
  targetUe4ssDir: string;
  targetProxyDll: string;
  compatibilityBundle: Ue4ssCompatibilityBundle;
};

export type Ue4ssDiagnostics = {
  logPath: string | null;
  loaded: boolean;
  engineVersion: string | null;
  compatibilityOk: boolean;
  hasCustomGameConfig: boolean;
  bridgeModStarted: boolean;
  scanFailureCount: number;
  fatalErrors: string[];
  missingSymbols: string[];
  signatureHints: string[];
  lines: string[];
};

export type Ue4ssCompatibilityBundleManifest = {
  brickadia_cl: string;
  brickadia_version_string: string;
  ue_baseline: string;
  ue4ss_commit: string;
  validated: boolean;
  validation_timestamp: string | null;
  files: Record<string, string>;
};

export type Ue4ssCompatibilityBundleValidation = {
  bundleId: string;
  workspaceRoot: string | null;
  bundleDir: string | null;
  manifestPath: string | null;
  manifest: Ue4ssCompatibilityBundleManifest | null;
  ok: boolean;
  validated: boolean;
  missingFiles: string[];
  invalidHashes: string[];
  errors: string[];
  warnings: string[];
};

export type Ue4ssCompatibilityBundle = {
  bundleId: string;
  workspaceRoot: string;
  root: string;
  manifestPath: string;
  validationReportJsonPath: string;
  validationReportMarkdownPath: string;
  manifest: Ue4ssCompatibilityBundleManifest;
  validation: Ue4ssCompatibilityBundleValidation;
};

type ManagedMarker = {
  version: string;
  sourceRoot: string;
  updatedAt: string;
  targetWin64Dir?: string;
  compatibilityBundleId?: string;
  compatibilityValidated?: boolean;
  compatibilityValidationTimestamp?: string | null;
  compatibilityWorkspaceRoot?: string;
};

export function getPinnedUe4ssCompatibilityBundleId() {
  return UE4SS_MANIFEST.pinnedCompatibilityBundleId;
}

export function resolveWindowsControlBackend(): WindowsControlBackend {
  const raw = (process.env.OMEGGA_WINDOWS_BACKEND ?? 'ue4ss').toLowerCase();
  return raw === 'bridge' ? 'bridge' : 'ue4ss';
}

export function resolveGameBinary(config: IConfig): ResolvedGameBinary {
  const isSteam = !config.server.branch;
  const steamBeta = config.server.steambeta ?? 'main';
  const overrideBinary = getOverrideGameBinary();
  const steamBinary = path.join(
    getSteamInstallDir(),
    steamBeta,
    getSteamGameDir(),
    GAME_BIN_PATH,
  );

  return {
    gameBinary: overrideBinary ?? steamBinary,
    isSteam,
    overrideBinary,
    steamBinary,
    steamBeta,
  };
}

export function getGameWin64Dir(config: IConfig) {
  return path.dirname(resolveGameBinary(config).gameBinary);
}

export function getUe4ssLogPath(
  targetWin64Dir: string,
  { allowDisabled = true }: { allowDisabled?: boolean } = {},
) {
  const searchRoots = [path.join(targetWin64Dir, UE4SS_DIRNAME)];
  if (allowDisabled)
    searchRoots.push(path.join(targetWin64Dir, UE4SS_DISABLED_DIRNAME));

  const discoveredLogs = searchRoots
    .flatMap(rootDir => findUe4ssLogs(rootDir))
    .sort((a, b) => {
      const aTime = safeStatMtime(a);
      const bTime = safeStatMtime(b);
      return bTime - aTime;
    });

  if (discoveredLogs.length > 0) return discoveredLogs[0];
  return path.join(targetWin64Dir, UE4SS_DIRNAME, UE4SS_LOG_FILENAME);
}

export function readUe4ssDiagnostics(
  targetWin64Dir: string,
  { allowDisabled = true }: { allowDisabled?: boolean } = {},
): Ue4ssDiagnostics {
  const logPath = getUe4ssLogPath(targetWin64Dir, { allowDisabled });
  if (!logPath || !fs.existsSync(logPath)) {
    return {
      logPath: null,
      loaded: false,
      engineVersion: null,
      compatibilityOk: false,
      hasCustomGameConfig: false,
      bridgeModStarted: false,
      scanFailureCount: 0,
      fatalErrors: [],
      missingSymbols: [],
      signatureHints: [],
      lines: [],
    };
  }

  const contents = fs.readFileSync(logPath, 'utf8');
  const lines = contents.split(/\r?\n/).filter(Boolean);
  const missingSymbols = Array.from(
    new Set(
      Array.from(
        contents.matchAll(/Failed to find (.+?):\s/g),
        match => match[1],
      ),
    ),
  );
  const signatureHints = Array.from(
    new Set(
      Array.from(
        contents.matchAll(/You can supply your own AOB in '([^']+)'/g),
        match => match[1],
      ),
    ),
  );
  const fatalErrors = Array.from(
    new Set(
      Array.from(
        contents.matchAll(/Fatal Error:\s*(.+)$/gm),
        match => match[1],
      ),
    ),
  );

  return {
    logPath,
    loaded: /UE4SS - v/i.test(contents),
    engineVersion:
      contents.match(/Found EngineVersion:\s*([0-9.]+)/)?.[1] ?? null,
    compatibilityOk:
      !contents.includes('Scan failed') &&
      missingSymbols.length === 0 &&
      fatalErrors.length === 0,
    hasCustomGameConfig: !contents.includes(
      'No specific game configuration found, using default configuration file',
    ),
    bridgeModStarted:
      /\bOmeggaBridge\b/i.test(contents) &&
      !/\bOmeggaBridgeProbe\b/i.test(contents),
    scanFailureCount: (contents.match(/Scan failed/g) ?? []).length,
    fatalErrors,
    missingSymbols,
    signatureHints,
    lines,
  };
}

export function readBrickadiaBuildInfo(logPath: string): {
  branchLabel: string | null;
  cl: string | null;
} {
  if (!logPath || !fs.existsSync(logPath)) {
    return { branchLabel: null, cl: null };
  }

  const contents = fs.readFileSync(logPath, 'utf8');
  const branchLabel =
    contents.match(/Brickadia [^(]+\([^)]*CL\d+\)/)?.[0] ?? null;
  const cl = branchLabel?.match(/CL(\d+)/)?.[1] ?? null;

  return { branchLabel, cl };
}

export function formatUe4ssDiagnostics(
  diagnostics: Ue4ssDiagnostics,
  buildInfo?: { branchLabel: string | null; cl: string | null },
) {
  const parts = [];
  if (buildInfo?.branchLabel)
    parts.push(`Brickadia build ${buildInfo.branchLabel}`);
  if (diagnostics.engineVersion) parts.push(`UE ${diagnostics.engineVersion}`);
  if (diagnostics.missingSymbols.length > 0)
    parts.push(`missing ${diagnostics.missingSymbols.join(', ')}`);
  if (diagnostics.scanFailureCount > 0)
    parts.push(`${diagnostics.scanFailureCount} scan failure(s)`);
  if (diagnostics.fatalErrors.length > 0)
    parts.push(diagnostics.fatalErrors.join('; '));
  if (!diagnostics.hasCustomGameConfig)
    parts.push('custom game config not selected');
  if (!diagnostics.bridgeModStarted)
    parts.push(`${UE4SS_BRIDGE_MOD_NAME} mod did not start`);

  return parts.join('; ');
}

export function installManagedUe4ss(
  targetWin64Dir: string,
): ManagedUe4ssInstall {
  if (!IS_WINDOWS) {
    throw new Error('UE4SS management is only supported on Windows.');
  }

  const compatibilityBundle = resolveUe4ssCompatibilityBundle();
  const sourceRoot = resolveUe4ssSourceRoot();
  const cacheRoot = ensureCachedUe4ssBundle(sourceRoot, compatibilityBundle);
  const targetUe4ssDir = path.join(targetWin64Dir, UE4SS_DIRNAME);
  const targetProxyDll = path.join(targetWin64Dir, UE4SS_PROXY_DLL);

  Logger.verbose(
    'Installing managed UE4SS payload into',
    targetWin64Dir.yellow,
  );
  fs.mkdirSync(targetWin64Dir, { recursive: true });

  restoreDisabledInstall(targetWin64Dir);

  if (
    isCurrentManagedInstall(targetWin64Dir, sourceRoot, compatibilityBundle)
  ) {
    Logger.verbose(
      'Managed UE4SS install is already current in',
      targetWin64Dir.yellow,
      '- reusing existing files.',
    );
    overlayManagedTemplates(
      targetUe4ssDir,
      compatibilityBundle,
      getRuntimeConfigAliases(targetWin64Dir),
    );
    writeManagedMarker(
      targetUe4ssDir,
      buildManagedMarker(sourceRoot, targetWin64Dir, compatibilityBundle),
    );
    return {
      sourceRoot,
      cacheRoot,
      targetWin64Dir,
      targetUe4ssDir,
      targetProxyDll,
      compatibilityBundle,
    };
  }

  fs.copyFileSync(path.join(cacheRoot, UE4SS_PROXY_DLL), targetProxyDll);
  fs.cpSync(path.join(cacheRoot, UE4SS_DIRNAME), targetUe4ssDir, {
    recursive: true,
    force: true,
  });

  overlayManagedTemplates(
    targetUe4ssDir,
    compatibilityBundle,
    getRuntimeConfigAliases(targetWin64Dir),
  );
  writeManagedMarker(
    targetUe4ssDir,
    buildManagedMarker(sourceRoot, targetWin64Dir, compatibilityBundle),
  );

  const logPath = path.join(targetUe4ssDir, UE4SS_LOG_FILENAME);
  if (fs.existsSync(logPath)) fs.rmSync(logPath, RM_SYNC_RETRY_OPTIONS);

  return {
    sourceRoot,
    cacheRoot,
    targetWin64Dir,
    targetUe4ssDir,
    targetProxyDll,
    compatibilityBundle,
  };
}

export function disableManagedUe4ss(targetWin64Dir: string) {
  const targetProxyDll = path.join(targetWin64Dir, UE4SS_PROXY_DLL);
  const disabledProxyDll = path.join(targetWin64Dir, UE4SS_PROXY_DLL_DISABLED);
  const targetUe4ssDir = path.join(targetWin64Dir, UE4SS_DIRNAME);
  const disabledUe4ssDir = path.join(targetWin64Dir, UE4SS_DISABLED_DIRNAME);

  if (fs.existsSync(disabledProxyDll))
    fs.rmSync(disabledProxyDll, RM_SYNC_RETRY_OPTIONS);
  if (fs.existsSync(disabledUe4ssDir))
    fs.rmSync(disabledUe4ssDir, {
      ...RM_SYNC_RETRY_OPTIONS,
      recursive: true,
    });

  if (fs.existsSync(targetProxyDll))
    fs.renameSync(targetProxyDll, disabledProxyDll);
  if (fs.existsSync(targetUe4ssDir))
    fs.renameSync(targetUe4ssDir, disabledUe4ssDir);

  return {
    targetWin64Dir,
    disabledProxyDll,
    disabledUe4ssDir,
  };
}

function overlayManagedTemplates(
  targetUe4ssDir: string,
  compatibilityBundle: Ue4ssCompatibilityBundle,
  runtimeAliases: string[] = [...CUSTOM_GAME_CONFIG_ALIASES],
) {
  if (!fs.existsSync(TEMPLATE_ROOT)) {
    throw new Error(`UE4SS templates are missing from ${TEMPLATE_ROOT}`);
  }

  const managedTemplateModsDir = path.join(
    TEMPLATE_ROOT,
    UE4SS_DIRNAME,
    'Mods',
  );
  const rootModsDir = path.join(targetUe4ssDir, 'Mods');
  overlayCompatibilityBundle(
    targetUe4ssDir,
    compatibilityBundle,
    runtimeAliases,
  );
  const normalizedAliases = Array.from(
    new Set(
      runtimeAliases
        .map(alias => alias?.trim())
        .filter((alias): alias is string => Boolean(alias)),
    ),
  );

  for (const alias of normalizedAliases) {
    const aliasModsDir = path.join(targetUe4ssDir, alias, 'Mods');
    syncManagedBridgeMod(managedTemplateModsDir, aliasModsDir);
    syncManagedMods(aliasModsDir);
    ensureBridgeModEnabled(aliasModsDir);
  }

  syncManagedBridgeMod(managedTemplateModsDir, rootModsDir);
  syncManagedMods(rootModsDir);
  ensureBridgeModEnabled(rootModsDir);
}

function overlayCompatibilityBundle(
  targetUe4ssDir: string,
  compatibilityBundle: Ue4ssCompatibilityBundle,
  runtimeAliases: string[] = [...CUSTOM_GAME_CONFIG_ALIASES],
) {
  const normalizedAliases = Array.from(
    new Set(
      runtimeAliases
        .map(alias => alias?.trim())
        .filter((alias): alias is string => Boolean(alias)),
    ),
  );
  const bundleConfigDir = path.join(
    compatibilityBundle.root,
    'CustomGameConfigs',
    'Brickadia',
  );
  const targetCanonicalConfigDir = path.join(
    targetUe4ssDir,
    'CustomGameConfigs',
    'Brickadia',
  );
  const bundleVTableLayout = path.join(
    compatibilityBundle.root,
    UE4SS_VTABLE_LAYOUT_FILENAME,
  );

  if (!fs.existsSync(bundleConfigDir)) {
    throw new Error(
      `Compatibility bundle is missing Brickadia config assets at ${bundleConfigDir}`,
    );
  }

  if (fs.existsSync(bundleVTableLayout)) {
    fs.copyFileSync(
      bundleVTableLayout,
      path.join(targetUe4ssDir, UE4SS_VTABLE_LAYOUT_FILENAME),
    );
  }

  replaceDirectory(bundleConfigDir, targetCanonicalConfigDir);

  for (const alias of normalizedAliases) {
    replaceDirectory(bundleConfigDir, path.join(targetUe4ssDir, alias));
  }
}

function replaceDirectory(sourceDir: string, targetDir: string) {
  fs.rmSync(targetDir, { ...RM_SYNC_RETRY_OPTIONS, recursive: true });
  fs.mkdirSync(path.dirname(targetDir), { recursive: true });
  fs.cpSync(sourceDir, targetDir, {
    recursive: true,
    force: true,
  });
}

function syncManagedBridgeMod(
  sourceModsDir: string,
  destinationModsDir: string,
) {
  if (!fs.existsSync(sourceModsDir)) return;

  const bridgeSourceDir = path.join(sourceModsDir, UE4SS_BRIDGE_MOD_NAME);
  if (!fs.existsSync(bridgeSourceDir)) return;

  fs.mkdirSync(destinationModsDir, { recursive: true });
  fs.cpSync(
    bridgeSourceDir,
    path.join(destinationModsDir, UE4SS_BRIDGE_MOD_NAME),
    {
      recursive: true,
      force: true,
    },
  );
}

function getManagedBmfMod() {
  const overrideSourceDir = process.env[BMF_SOURCE_ENV]?.trim();
  const configuredSourceDir = overrideSourceDir
    ? path.resolve(overrideSourceDir)
    : path.join(TEMPLATE_ROOT, UE4SS_DIRNAME, 'Mods', BMF_MOD_NAME);
  const sourceDir = resolveBmfSourceDir(configuredSourceDir);

  if (!fs.existsSync(sourceDir)) {
    const sourceLabel = overrideSourceDir
      ? `configured ${BMF_SOURCE_ENV} path`
      : 'bundled BMF template';
    throw new Error(
      `Could not locate the ${sourceLabel} at ${sourceDir}. ` +
        `This Omegga build must be packaged with ${BMF_MOD_NAME}, or ${BMF_SOURCE_ENV} must point to a complete BMF mod directory or BMF repository root.`,
    );
  }

  return {
    name: BMF_MOD_NAME,
    sourceDir,
    enabled: true,
  };
}

function getManagedBmfSocketMod() {
  return getManagedBmfNativeMod(BMF_SOCKET_MOD_NAME);
}

function getManagedBmfFrameTelemetryMod() {
  return getManagedBmfNativeMod(BMF_FRAME_TELEMETRY_MOD_NAME);
}

function getManagedBmfNativeMod(modName: string) {
  const overrideSourceDir = process.env[BMF_SOURCE_ENV]?.trim();
  const configuredSourceDir = overrideSourceDir
    ? path.resolve(overrideSourceDir)
    : path.join(TEMPLATE_ROOT, UE4SS_DIRNAME, 'Mods', BMF_MOD_NAME);
  const sourceDir = resolveSiblingManagedModSourceDir(
    configuredSourceDir,
    modName,
  );
  const dllPath = path.join(sourceDir, 'dlls', 'main.dll');

  if (!fs.existsSync(dllPath)) {
    return null;
  }

  return {
    name: modName,
    sourceDir,
    enabled: true,
  };
}

function resolveBmfSourceDir(sourceDir: string) {
  if (fs.existsSync(path.join(sourceDir, 'bmf.json'))) return sourceDir;

  const repoLayoutSourceDir = path.join(
    sourceDir,
    'framework',
    UE4SS_DIRNAME,
    'Mods',
    BMF_MOD_NAME,
  );
  if (fs.existsSync(path.join(repoLayoutSourceDir, 'bmf.json'))) {
    return repoLayoutSourceDir;
  }

  return sourceDir;
}

function resolveSiblingManagedModSourceDir(
  configuredSourceDir: string,
  modName: string,
) {
  if (fs.existsSync(path.join(configuredSourceDir, 'bmf.json'))) {
    return path.join(path.dirname(configuredSourceDir), modName);
  }

  const repoLayoutSourceDir = path.join(
    configuredSourceDir,
    'framework',
    UE4SS_DIRNAME,
    'Mods',
    modName,
  );
  if (fs.existsSync(repoLayoutSourceDir)) {
    return repoLayoutSourceDir;
  }

  return path.join(configuredSourceDir, modName);
}

function getManagedMods() {
  const mods: { name: string; sourceDir: string; enabled: boolean }[] = [];
  mods.push(getManagedBmfMod());
  const bmfSocketMod = getManagedBmfSocketMod();
  if (bmfSocketMod) {
    mods.push(bmfSocketMod);
  }
  const bmfFrameTelemetryMod = getManagedBmfFrameTelemetryMod();
  if (bmfFrameTelemetryMod) {
    mods.push(bmfFrameTelemetryMod);
  }
  return mods;
}

function syncManagedMods(destinationModsDir: string) {
  for (const mod of getManagedMods()) {
    if (!fs.existsSync(mod.sourceDir)) continue;
    fs.mkdirSync(destinationModsDir, { recursive: true });
    const targetModDir = path.join(destinationModsDir, mod.name);
    fs.rmSync(targetModDir, { ...RM_SYNC_RETRY_OPTIONS, recursive: true });
    fs.cpSync(mod.sourceDir, targetModDir, {
      recursive: true,
      force: true,
      filter: shouldCopyManagedModPath,
    });
  }
}

function shouldCopyManagedModPath(sourcePath: string) {
  const name = path.basename(sourcePath);
  return ![
    '.git',
    '.github',
    '.pytest_cache',
    '__pycache__',
    'node_modules',
  ].includes(name);
}

function ensureBridgeModEnabled(modsDir: string) {
  fs.mkdirSync(modsDir, { recursive: true });
  const managedMods = getManagedMods();
  const managedModNames = [
    UE4SS_BRIDGE_MOD_NAME,
    UE4SS_PROBE_MOD_NAME,
    ...managedMods.map(mod => mod.name),
  ];

  const modsTxtPath = path.join(modsDir, 'mods.txt');
  const existingLines = fs.existsSync(modsTxtPath)
    ? fs.readFileSync(modsTxtPath, 'utf8').split(/\r?\n/)
    : [];
  const rewrittenLines = existingLines.filter(
    line =>
      !line.match(
        new RegExp(
          `^\\s*(${managedModNames
            .map(name => escapeRegExp(name))
            .join('|')})\\s*:`,
        ),
      ),
  );
  const keybindsIndex = rewrittenLines.findIndex(line =>
    line.trimStart().startsWith('Keybinds :'),
  );
  const bridgeLines = [
    `${UE4SS_BRIDGE_MOD_NAME} : 1`,
    ...managedMods.filter(mod => mod.enabled).map(mod => `${mod.name} : 1`),
  ];
  const insertionIndex =
    keybindsIndex === -1 ? rewrittenLines.length : Math.max(keybindsIndex, 0);
  rewrittenLines.splice(insertionIndex, 0, ...bridgeLines);
  fs.writeFileSync(modsTxtPath, rewrittenLines.join(os.EOL).trimEnd() + os.EOL);

  const modsJsonPath = path.join(modsDir, 'mods.json');
  const modsJson = fs.existsSync(modsJsonPath)
    ? safeReadJsonFile(modsJsonPath)
    : [];
  const normalizedMods = Array.isArray(modsJson) ? modsJson : [];
  upsertNamedMod(normalizedMods, UE4SS_BRIDGE_MOD_NAME, true);
  upsertNamedMod(normalizedMods, UE4SS_PROBE_MOD_NAME, false);
  for (const mod of managedMods) {
    upsertNamedMod(normalizedMods, mod.name, mod.enabled);
  }
  fs.writeFileSync(
    modsJsonPath,
    JSON.stringify(normalizedMods, null, 2) + os.EOL,
  );
}

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function upsertNamedMod(
  mods: { mod_name?: string; mod_enabled?: boolean }[],
  modName: string,
  enabled: boolean,
) {
  const existing = mods.find(mod => mod.mod_name === modName);
  if (existing) {
    existing.mod_enabled = enabled;
    return;
  }

  mods.push({ mod_name: modName, mod_enabled: enabled });
}

function safeReadJsonFile(filepath: string) {
  try {
    return JSON.parse(fs.readFileSync(filepath, 'utf8'));
  } catch {
    return [];
  }
}

function readManagedMarker(targetDir: string): ManagedMarker | null {
  const markerPath = path.join(targetDir, UE4SS_MANAGED_MARKER);
  if (!fs.existsSync(markerPath)) return null;

  const marker = safeReadJsonFile(markerPath);
  return marker && typeof marker === 'object'
    ? (marker as ManagedMarker)
    : null;
}

function isCurrentManagedInstall(
  targetWin64Dir: string,
  sourceRoot: string,
  compatibilityBundle: Ue4ssCompatibilityBundle,
) {
  const targetProxyDll = path.join(targetWin64Dir, UE4SS_PROXY_DLL);
  const targetUe4ssDir = path.join(targetWin64Dir, UE4SS_DIRNAME);
  const marker = readManagedMarker(targetUe4ssDir);

  return (
    fs.existsSync(targetProxyDll) &&
    fs.existsSync(path.join(targetUe4ssDir, 'UE4SS.dll')) &&
    marker?.version === UE4SS_MANIFEST.version &&
    marker?.sourceRoot === sourceRoot &&
    marker?.compatibilityBundleId === compatibilityBundle.bundleId &&
    marker?.compatibilityValidated === compatibilityBundle.manifest.validated &&
    marker?.compatibilityValidationTimestamp ===
      compatibilityBundle.manifest.validation_timestamp &&
    marker?.compatibilityWorkspaceRoot === compatibilityBundle.workspaceRoot
  );
}

function restoreDisabledInstall(targetWin64Dir: string) {
  const targetProxyDll = path.join(targetWin64Dir, UE4SS_PROXY_DLL);
  const disabledProxyDll = path.join(targetWin64Dir, UE4SS_PROXY_DLL_DISABLED);
  const targetUe4ssDir = path.join(targetWin64Dir, UE4SS_DIRNAME);
  const disabledUe4ssDir = path.join(targetWin64Dir, UE4SS_DISABLED_DIRNAME);

  if (!fs.existsSync(targetProxyDll) && fs.existsSync(disabledProxyDll)) {
    fs.renameSync(disabledProxyDll, targetProxyDll);
  }
  if (!fs.existsSync(targetUe4ssDir) && fs.existsSync(disabledUe4ssDir)) {
    fs.renameSync(disabledUe4ssDir, targetUe4ssDir);
  }
}

function ensureCachedUe4ssBundle(
  sourceRoot: string,
  compatibilityBundle: Ue4ssCompatibilityBundle,
) {
  const cacheRoot = path.join(UE4SS_CACHE_DIR, UE4SS_MANIFEST.bundleDirName);
  const cacheMarkerPath = path.join(cacheRoot, UE4SS_MANAGED_MARKER);

  const marker = fs.existsSync(cacheMarkerPath)
    ? (safeReadJsonFile(cacheMarkerPath) as ManagedMarker)
    : null;

  if (
    fs.existsSync(path.join(cacheRoot, UE4SS_DIRNAME, 'UE4SS.dll')) &&
    marker?.version === UE4SS_MANIFEST.version &&
    marker?.sourceRoot === sourceRoot &&
    marker?.compatibilityBundleId === compatibilityBundle.bundleId &&
    marker?.compatibilityValidated === compatibilityBundle.manifest.validated &&
    marker?.compatibilityValidationTimestamp ===
      compatibilityBundle.manifest.validation_timestamp &&
    marker?.compatibilityWorkspaceRoot === compatibilityBundle.workspaceRoot
  ) {
    return cacheRoot;
  }

  Logger.verbose('Refreshing cached UE4SS payload from', sourceRoot.yellow);
  fs.rmSync(cacheRoot, { ...RM_SYNC_RETRY_OPTIONS, recursive: true });
  fs.mkdirSync(cacheRoot, { recursive: true });
  fs.copyFileSync(
    path.join(sourceRoot, UE4SS_PROXY_DLL),
    path.join(cacheRoot, UE4SS_PROXY_DLL),
  );
  copyDirectoryContents(
    path.join(sourceRoot, UE4SS_DIRNAME),
    path.join(cacheRoot, UE4SS_DIRNAME),
  );
  overlayManagedTemplates(
    path.join(cacheRoot, UE4SS_DIRNAME),
    compatibilityBundle,
  );
  writeManagedMarker(
    cacheRoot,
    buildManagedMarker(sourceRoot, undefined, compatibilityBundle),
  );

  return cacheRoot;
}

function resolveUe4ssSourceRoot() {
  const override = normalizeSourceRoot(process.env.OMEGGA_UE4SS_SOURCE);
  if (override) return override;

  const candidates = new Set<string>();
  for (const root of getAncestorPaths(process.cwd())) {
    candidates.add(path.join(root, UE4SS_MANIFEST.bundleDirName));
  }
  for (const root of getAncestorPaths(path.resolve(__dirname, '..', '..'))) {
    candidates.add(path.join(root, UE4SS_MANIFEST.bundleDirName));
  }

  for (const candidate of candidates) {
    const normalized = normalizeSourceRoot(candidate);
    if (normalized) return normalized;
  }

  throw new Error(
    [
      `Could not locate the pinned UE4SS bundle ${UE4SS_MANIFEST.bundleDirName}.`,
      `Set ${'OMEGGA_UE4SS_SOURCE'.yellow} to a directory containing ${UE4SS_PROXY_DLL} and ${UE4SS_DIRNAME}.`,
    ].join(' '),
  );
}

function normalizeSourceRoot(candidate?: string | null) {
  if (!candidate) return null;

  const resolved = path.resolve(candidate);
  if (isValidUe4ssSourceRoot(resolved)) return resolved;

  if (
    path.basename(resolved).toLowerCase() === UE4SS_DIRNAME &&
    isValidUe4ssSourceRoot(path.dirname(resolved))
  ) {
    return path.dirname(resolved);
  }

  return null;
}

export function validateUe4ssCompatibilityBundle(
  bundleId = getPinnedUe4ssCompatibilityBundleId(),
): Ue4ssCompatibilityBundleValidation {
  const errors: string[] = [];
  const warnings: string[] = [];
  const missingFiles: string[] = [];
  const invalidHashes: string[] = [];
  const workspaceRoot = resolveUe4ssCompatibilityWorkspaceRoot({
    allowMissing: true,
  });
  const bundleDir = workspaceRoot
    ? path.join(workspaceRoot, UE4SS_COMPAT_BUNDLES_DIRNAME, bundleId)
    : null;
  const manifestPath = bundleDir
    ? path.join(bundleDir, UE4SS_BUNDLE_MANIFEST_FILENAME)
    : null;
  let manifest: Ue4ssCompatibilityBundleManifest | null = null;

  if (!workspaceRoot) {
    errors.push(
      `Could not locate the Brickadia UE4SS compatibility workspace ${UE4SS_COMPAT_WORKSPACE_DIRNAME}.`,
    );
  }

  if (workspaceRoot && !fs.existsSync(bundleDir)) {
    errors.push(
      `Compatibility bundle ${bundleId} was not found in ${workspaceRoot}.`,
    );
  }

  if (bundleDir && fs.existsSync(bundleDir) && !fs.existsSync(manifestPath)) {
    errors.push(
      `Compatibility bundle manifest is missing from ${manifestPath}.`,
    );
  }

  if (manifestPath && fs.existsSync(manifestPath)) {
    try {
      manifest = JSON.parse(
        fs.readFileSync(manifestPath, 'utf8'),
      ) as Ue4ssCompatibilityBundleManifest;
    } catch (error) {
      errors.push(
        `Failed to parse compatibility bundle manifest ${manifestPath}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  if (manifest) {
    for (const field of [
      'brickadia_cl',
      'brickadia_version_string',
      'ue_baseline',
      'ue4ss_commit',
      'validated',
      'validation_timestamp',
      'files',
    ] as const) {
      if (!(field in manifest)) {
        errors.push(`Compatibility bundle manifest is missing ${field}.`);
      }
    }

    if (
      !manifest.brickadia_cl ||
      String(manifest.brickadia_cl) !== bundleId.replace(/^CL/i, '')
    ) {
      errors.push(
        `Compatibility bundle manifest brickadia_cl ${String(
          manifest.brickadia_cl ?? '',
        )} does not match ${bundleId}.`,
      );
    }
  }

  for (const relativePath of COMPATIBILITY_BUNDLE_REQUIRED_FILES) {
    const normalizedPath = normalizeBundleRelativePath(relativePath);
    const absolutePath = bundleDir
      ? resolveBundleAbsolutePath(bundleDir, normalizedPath)
      : null;
    if (!absolutePath || !fs.existsSync(absolutePath)) {
      missingFiles.push(normalizedPath);
    }
  }

  if (missingFiles.length > 0) {
    errors.push(
      `Compatibility bundle is missing required files: ${missingFiles.join(', ')}.`,
    );
  }

  if (!manifest?.files || typeof manifest.files !== 'object') {
    errors.push(
      'Compatibility bundle manifest.files must be an object map of relative paths to sha256 hashes.',
    );
  } else if (bundleDir) {
    for (const relativePath of COMPATIBILITY_BUNDLE_REQUIRED_FILES) {
      const normalizedPath = normalizeBundleRelativePath(relativePath);
      const expectedHash = manifest.files[normalizedPath];
      if (!expectedHash) {
        errors.push(
          `Compatibility bundle manifest is missing hash for ${normalizedPath}.`,
        );
        continue;
      }

      const absolutePath = resolveBundleAbsolutePath(bundleDir, normalizedPath);
      if (!fs.existsSync(absolutePath)) continue;

      const actualHash = sha256File(absolutePath);
      if (actualHash !== expectedHash) {
        invalidHashes.push(normalizedPath);
      }
    }
  }

  if (invalidHashes.length > 0) {
    errors.push(
      `Compatibility bundle file hashes are stale for: ${invalidHashes.join(', ')}.`,
    );
  }

  if (manifest?.validated !== true) {
    warnings.push(
      `Compatibility bundle ${bundleId} is staged but not yet validated for object-dependent Windows control.`,
    );
  }

  return {
    bundleId,
    workspaceRoot,
    bundleDir,
    manifestPath,
    manifest,
    ok: errors.length === 0,
    validated: errors.length === 0 && manifest?.validated === true,
    missingFiles,
    invalidHashes,
    errors,
    warnings,
  };
}

export function resolveUe4ssCompatibilityBundle(
  bundleId = getPinnedUe4ssCompatibilityBundleId(),
): Ue4ssCompatibilityBundle {
  const validation = validateUe4ssCompatibilityBundle(bundleId);
  if (
    !validation.ok ||
    !validation.workspaceRoot ||
    !validation.bundleDir ||
    !validation.manifestPath ||
    !validation.manifest
  ) {
    throw new Error(
      validation.errors.join(' ') ||
        `Compatibility bundle ${bundleId} is not available.`,
    );
  }

  return {
    bundleId,
    workspaceRoot: validation.workspaceRoot,
    root: validation.bundleDir,
    manifestPath: validation.manifestPath,
    validationReportJsonPath: path.join(
      validation.bundleDir,
      UE4SS_VALIDATION_REPORT_JSON_FILENAME,
    ),
    validationReportMarkdownPath: path.join(
      validation.bundleDir,
      UE4SS_VALIDATION_REPORT_MARKDOWN_FILENAME,
    ),
    manifest: validation.manifest,
    validation,
  };
}

export function resolveUe4ssCompatibilityWorkspaceRoot({
  allowMissing = false,
}: { allowMissing?: boolean } = {}) {
  const override = process.env.OMEGGA_UE4SS_RE_ROOT;
  if (override) {
    const resolvedOverride = path.resolve(override);
    if (fs.existsSync(resolvedOverride)) return resolvedOverride;
    if (!allowMissing) {
      throw new Error(
        `Configured UE4SS compatibility workspace ${resolvedOverride} does not exist.`,
      );
    }
    return null;
  }

  const candidates = new Set<string>();
  for (const root of getAncestorPaths(process.cwd())) {
    candidates.add(path.join(root, UE4SS_COMPAT_WORKSPACE_DIRNAME));
  }
  for (const root of getAncestorPaths(path.resolve(__dirname, '..', '..'))) {
    candidates.add(path.join(root, UE4SS_COMPAT_WORKSPACE_DIRNAME));
  }

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }

  if (allowMissing) return null;

  throw new Error(
    `Could not locate the Brickadia UE4SS compatibility workspace ${UE4SS_COMPAT_WORKSPACE_DIRNAME}.`,
  );
}

function isValidUe4ssSourceRoot(candidate: string) {
  return (
    fs.existsSync(path.join(candidate, UE4SS_PROXY_DLL)) &&
    fs.existsSync(path.join(candidate, UE4SS_DIRNAME, 'UE4SS.dll'))
  );
}

function copyDirectoryContents(sourceDir: string, targetDir: string) {
  fs.mkdirSync(targetDir, { recursive: true });

  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    if (shouldSkipManagedBundleEntry(entry.name)) continue;

    const sourcePath = path.join(sourceDir, entry.name);
    const targetPath = path.join(targetDir, entry.name);

    if (entry.isDirectory()) {
      fs.cpSync(sourcePath, targetPath, {
        recursive: true,
        force: true,
      });
      continue;
    }

    if (entry.isSymbolicLink()) {
      const linkTarget = fs.readlinkSync(sourcePath);
      try {
        fs.rmSync(targetPath, { force: true, recursive: true });
      } catch {}
      fs.symlinkSync(linkTarget, targetPath);
      continue;
    }

    fs.copyFileSync(sourcePath, targetPath);
  }
}

function shouldSkipManagedBundleEntry(entryName: string) {
  return /\.(pdb|exp|lib)$/i.test(entryName);
}

function buildManagedMarker(
  sourceRoot: string,
  targetWin64Dir: string | undefined,
  compatibilityBundle: Ue4ssCompatibilityBundle,
): ManagedMarker {
  return {
    version: UE4SS_MANIFEST.version,
    sourceRoot,
    updatedAt: new Date().toISOString(),
    targetWin64Dir,
    compatibilityBundleId: compatibilityBundle.bundleId,
    compatibilityValidated: compatibilityBundle.manifest.validated,
    compatibilityValidationTimestamp:
      compatibilityBundle.manifest.validation_timestamp,
    compatibilityWorkspaceRoot: compatibilityBundle.workspaceRoot,
  };
}

function writeManagedMarker(targetDir: string, marker: ManagedMarker) {
  fs.writeFileSync(
    path.join(targetDir, UE4SS_MANAGED_MARKER),
    JSON.stringify(marker, null, 2) + os.EOL,
  );
}

function getAncestorPaths(start: string) {
  const ancestors = [];
  let current = path.resolve(start);
  for (;;) {
    ancestors.push(current);
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return ancestors;
}

function getRuntimeConfigAliases(targetWin64Dir: string) {
  const aliases = new Set<string>(CUSTOM_GAME_CONFIG_ALIASES);
  const runtimeAlias = path.basename(
    path.resolve(targetWin64Dir, '..', '..', '..'),
  );
  if (runtimeAlias) aliases.add(runtimeAlias);
  return Array.from(aliases);
}

function findUe4ssLogs(rootDir: string): string[] {
  if (!fs.existsSync(rootDir)) return [];

  const logs: string[] = [];
  const stack = [rootDir];

  while (stack.length > 0) {
    const currentDir = stack.pop();
    if (!currentDir) continue;

    for (const entry of fs.readdirSync(currentDir, { withFileTypes: true })) {
      const entryPath = path.join(currentDir, entry.name);
      if (entry.isDirectory()) {
        stack.push(entryPath);
      } else if (entry.isFile() && entry.name === UE4SS_LOG_FILENAME) {
        logs.push(entryPath);
      }
    }
  }

  return logs;
}

function safeStatMtime(filepath: string) {
  try {
    return fs.statSync(filepath).mtimeMs;
  } catch {
    return 0;
  }
}

function resolveBundleAbsolutePath(bundleDir: string, relativePath: string) {
  return path.join(
    bundleDir,
    ...normalizeBundleRelativePath(relativePath).split('/'),
  );
}

function normalizeBundleRelativePath(relativePath: string) {
  return relativePath.replace(/\\/g, '/');
}

function sha256File(filepath: string) {
  return createHash('sha256').update(fs.readFileSync(filepath)).digest('hex');
}

export function getBrickadiaLogPath(
  dataPath: string,
  savedDir = CONFIG_SAVED_DIR,
) {
  return path.join(dataPath, savedDir, 'Logs', 'Brickadia.log');
}
