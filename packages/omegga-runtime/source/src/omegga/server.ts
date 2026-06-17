import default_commands from '@/info/default_commands.json';
import Logger from '@/logger';
import { OmeggaLike, OmeggaPlayer, PluginInterop } from '@/plugin';
import {
  BRICKADIA_AUTH_FILES,
  CONFIG_AUTH_DIR,
  CONFIG_HOME,
  CONFIG_SAVED_DIR,
  DATA_PATH,
} from '@/softconfig';
import { VERSION } from '@/version';
import { EnvironmentPreset } from '@brickadia/presets';
import {
  BRBanList,
  BRPlayerNameCache,
  BRRoleAssignments,
  BRRoleSetup,
} from '@brickadia/types';
import { IConfig } from '@config/types';
import { map as mapUtils, pattern, uuid } from '@util';
import { copyFiles, mkdir, readWatchedJSON } from '@util/file';
import Webserver from '@webserver/backend';
import brs, { type ReadSaveObject, type WriteSaveObject } from 'brs-js';
import 'colors';
import glob from 'glob';
import { blake3 } from '@noble/hashes/blake3.js';
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, join } from 'path';
import { AutoRestartConfig } from '..';
import { execFileSync } from 'node:child_process';
import commandInjector from './commandInjector';
import MATCHERS from './matchers';
import Player from './player';
import { PluginLoader } from './plugin';
import {
  ILogMinigame,
  IMinigameList,
  IOmeggaOptions,
  IPlayerPositions,
  IServerStatus,
} from './types';
import OmeggaWrapper from './wrapper';

const MISSING_CMD =
  '"Command not found. Type <color=\\"ffff00\\">/help</> for a list of commands or <color=\\"ffff00\\">/plugins</> for plugin information."';
const NATIVE_PREFAB_COMMANDS = [
  'spawn',
  'spawncar',
  'capture',
  'capturecar',
  'savevehicleprobe',
  'loadvehicleprobe',
  'savebrickregion',
  'saveprefab',
  'listentities',
  'saveentity',
  'listdynamicactors',
  'savedynamicactor',
];
const NATIVE_PREFAB_COMMAND_PATH =
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\placeprefab-native-hook-outer-command.txt';
const NATIVE_PREFAB_STATUS_PATH =
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\placeprefab-native-hook-outer-status.txt';
const NATIVE_PREFAB_DEFINITIONS_PATH =
  process.env.OMEGGA_NATIVE_PREFAB_DEFINITIONS_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\spawn-prefabs.json';
const NATIVE_PREFAB_DEBUG_PATH =
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\spawncar-debug.log';
const NATIVE_PREFAB_BROKER_REQUEST_PATH =
  process.env.OMEGGA_PREFAB_BROKER_REQUEST_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\artifacts\\spawncar-broker-requests.ndjson';
const ADDITIVE_VEHICLE_PROBE_STATE_PATH =
  process.env.OMEGGA_ADDITIVE_VEHICLE_PROBE_STATE_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\artifacts\\additive-vehicle-probe.json';
const COORDINATE_PREFAB_STATE_PATH =
  process.env.OMEGGA_COORDINATE_PREFAB_STATE_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\artifacts\\coordinate-prefabs.json';
const WORLD_ENTITY_LIST_SCRIPT_PATH =
  process.env.OMEGGA_WORLD_ENTITY_LIST_SCRIPT_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\scripts\\list-world-entities.js';
const SAVED_ENTITY_STATE_PATH =
  process.env.OMEGGA_SAVED_ENTITY_STATE_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\artifacts\\saved-entities.json';
const NATIVE_PREFAB_LOG_PATH =
  process.env.OMEGGA_NATIVE_PREFAB_LOG_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\omegga-master\\omegga-master\\data\\Saved\\Logs\\Brickadia.log';
const NATIVE_PREFAB_HOOK_LOG_PATH =
  process.env.OMEGGA_NATIVE_PREFAB_HOOK_LOG_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\brickadia-ue4ss-re\\artifacts\\placeprefab-native-hook.log';
const NATIVE_PREFAB_CAR_PATH =
  process.env.OMEGGA_NATIVE_PREFAB_CAR_PATH ||
  'C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\Brickadia\\Car.brz';
const NATIVE_PREFAB_SOURCE_DIRS = (
  process.env.OMEGGA_NATIVE_PREFAB_SOURCE_DIRS ||
  [
    'C:\\Users\\tycox\\AppData\\Local\\Brickadia\\Saved\\GalleryCache\\Prefabs',
    'C:\\Users\\tycox\\AppData\\Local\\Brickadia\\Saved\\Prefabs',
    'C:\\Users\\tycox\\AppData\\Local\\Brickadia\\Saved\\Cache\\Downloads',
  ].join(';')
)
  .split(';')
  .map(part => part.trim())
  .filter(Boolean);

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

const debugNativePrefab = (...parts: unknown[]) => {
  try {
    appendFileSync(
      NATIVE_PREFAB_DEBUG_PATH,
      `${new Date().toISOString()} ${parts
        .map(part => {
          if (typeof part === 'string') return part;
          if (part instanceof Error) return part.stack || part.message;
          return JSON.stringify(part);
        })
        .join(' ')}\n`,
      'utf8',
    );
  } catch (_error) {
    // Best-effort diagnostics only.
  }
};

const finiteOr = (value: unknown, fallback: number) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const parseTriple = (args: unknown[]) => {
  if (args.length < 3) return null;
  const values = args.slice(0, 3).map(Number);
  if (!values.every(Number.isFinite)) return null;
  return values.map(Math.round) as [number, number, number];
};

const parseBoxCorners = (args: unknown[]) => {
  if (args.length < 6) return null;
  const values = args.slice(0, 6).map(Number);
  if (!values.every(Number.isFinite)) return null;
  return values.map(value => Math.round(value)) as [
    number,
    number,
    number,
    number,
    number,
    number,
  ];
};

const regionFromCorners = (corners: [
  number,
  number,
  number,
  number,
  number,
  number,
]) => {
  const min = [
    Math.min(corners[0], corners[3]),
    Math.min(corners[1], corners[4]),
    Math.min(corners[2], corners[5]),
  ] as [number, number, number];
  const max = [
    Math.max(corners[0], corners[3]),
    Math.max(corners[1], corners[4]),
    Math.max(corners[2], corners[5]),
  ] as [number, number, number];
  return {
    min,
    max,
    center: [
      Math.round((min[0] + max[0]) / 2),
      Math.round((min[1] + max[1]) / 2),
      Math.round((min[2] + max[2]) / 2),
    ] as [number, number, number],
    extent: [
      Math.max(1, Math.ceil((max[0] - min[0]) / 2)),
      Math.max(1, Math.ceil((max[1] - min[1]) / 2)),
      Math.max(1, Math.ceil((max[2] - min[2]) / 2)),
    ] as [number, number, number],
  };
};

const sanitizeWorldBundleName = (value: unknown, fallback: string) => {
  const raw = String(value || '').trim().replace(/\.brdb$/i, '');
  const safe = raw.replace(/[^A-Za-z0-9_.-]/g, '_').replace(/^_+|_+$/g, '');
  return safe || fallback;
};

const readAdditiveVehicleProbeState = () => {
  try {
    if (!existsSync(ADDITIVE_VEHICLE_PROBE_STATE_PATH)) return null;
    const parsed = JSON.parse(
      readFileSync(ADDITIVE_VEHICLE_PROBE_STATE_PATH, 'utf8'),
    );
    const bundleName = sanitizeWorldBundleName(
      (parsed as { bundleName?: unknown })?.bundleName,
      '',
    );
    return bundleName ? { bundleName } : null;
  } catch (error) {
    debugNativePrefab('additive vehicle probe state read failed', error);
    return null;
  }
};

const writeAdditiveVehicleProbeState = (
  state: Record<string, unknown> & { bundleName: string },
) => {
  mkdirSync(dirname(ADDITIVE_VEHICLE_PROBE_STATE_PATH), { recursive: true });
  writeFileSync(
    ADDITIVE_VEHICLE_PROBE_STATE_PATH,
    `${JSON.stringify(state, null, 2)}\n`,
    'utf8',
  );
};

const appendCoordinatePrefabRecord = (record: Record<string, unknown>) => {
  let records = [] as Record<string, unknown>[];
  if (existsSync(COORDINATE_PREFAB_STATE_PATH)) {
    try {
      const parsed = JSON.parse(
        readFileSync(COORDINATE_PREFAB_STATE_PATH, 'utf8'),
      );
      records = Array.isArray(parsed)
        ? parsed
        : Array.isArray((parsed as { records?: unknown[] })?.records)
          ? ((parsed as { records: Record<string, unknown>[] }).records || [])
          : [];
    } catch (error) {
      debugNativePrefab('coordinate prefab state parse failed', error);
      records = [];
    }
  }

  records.push(record);
  mkdirSync(dirname(COORDINATE_PREFAB_STATE_PATH), { recursive: true });
  writeFileSync(
    COORDINATE_PREFAB_STATE_PATH,
    `${JSON.stringify({ records }, null, 2)}\n`,
    'utf8',
  );
};

const appendSavedEntityRecord = (record: Record<string, unknown>) => {
  let records = [] as Record<string, unknown>[];
  if (existsSync(SAVED_ENTITY_STATE_PATH)) {
    try {
      const parsed = JSON.parse(readFileSync(SAVED_ENTITY_STATE_PATH, 'utf8'));
      records = Array.isArray(parsed)
        ? parsed
        : Array.isArray((parsed as { records?: unknown[] })?.records)
          ? ((parsed as { records: Record<string, unknown>[] }).records || [])
          : [];
    } catch (error) {
      debugNativePrefab('saved entity state parse failed', error);
      records = [];
    }
  }

  records.push(record);
  mkdirSync(dirname(SAVED_ENTITY_STATE_PATH), { recursive: true });
  writeFileSync(
    SAVED_ENTITY_STATE_PATH,
    `${JSON.stringify({ records }, null, 2)}\n`,
    'utf8',
  );
};

const quoteChatMessage = (message: string) => JSON.stringify(message);

const numberArray = (value: unknown): number[] =>
  Array.isArray(value)
    ? value
        .map(item => Number(item))
        .filter(Number.isFinite)
        .sort((a, b) => a - b)
    : [];

const dynamicActorGroupKey = (graph: Record<string, unknown>) =>
  JSON.stringify({
    relatedEntityIds: numberArray(graph.relatedEntityIds),
    relatedGridIds: numberArray(graph.relatedGridIds),
  });

const summarizeDynamicActorGroups = (
  graphs: Array<Record<string, unknown>>,
) => {
  const grouped = new Map<
    string,
    {
      seedEntityIds: number[];
      seedEntities: Record<string, unknown>[];
      statuses: Set<string>;
      relatedEntityIds: number[];
      relatedGridIds: number[];
      relatedEntityCount: number;
      relatedGridCount: number;
      chunkPathCounts?: unknown;
    }
  >();

  for (const graph of graphs) {
    const relatedEntityIds = numberArray(graph.relatedEntityIds);
    const relatedGridIds = numberArray(graph.relatedGridIds);
    const key = dynamicActorGroupKey(graph);
    const group =
      grouped.get(key) ||
      {
        seedEntityIds: [],
        seedEntities: [],
        statuses: new Set<string>(),
        relatedEntityIds,
        relatedGridIds,
        relatedEntityCount: relatedEntityIds.length,
        relatedGridCount: relatedGridIds.length,
        chunkPathCounts: graph.chunkPathCounts,
      };

    const seedEntityId = Number(graph.seedEntityId);
    if (Number.isFinite(seedEntityId)) group.seedEntityIds.push(seedEntityId);
    if (graph.seedEntity && typeof graph.seedEntity === 'object') {
      group.seedEntities.push(graph.seedEntity as Record<string, unknown>);
    }
    if (graph.status) group.statuses.add(String(graph.status));
    grouped.set(key, group);
  }

  return Array.from(grouped.values())
    .sort((a, b) => Math.min(...a.seedEntityIds) - Math.min(...b.seedEntityIds))
    .map((group, index) => ({
      groupId: index + 1,
      seedEntityIds: Array.from(new Set(group.seedEntityIds)).sort(
        (a, b) => a - b,
      ),
      seedEntities: group.seedEntities,
      status: Array.from(group.statuses).sort().join(',') || 'unknown',
      relatedEntityIds: group.relatedEntityIds,
      relatedGridIds: group.relatedGridIds,
      relatedEntityCount: group.relatedEntityCount,
      relatedGridCount: group.relatedGridCount,
      chunkPathCounts: group.chunkPathCounts,
    }));
};

const getDynamicActorGroups = (entityList: {
  dynamicActorGraphs?: Array<Record<string, unknown>>;
  dynamicActorGroups?: Array<Record<string, unknown>>;
}) => {
  if (
    Array.isArray(entityList.dynamicActorGroups) &&
    entityList.dynamicActorGroups.length > 0
  ) {
    return entityList.dynamicActorGroups;
  }
  return summarizeDynamicActorGroups(entityList.dynamicActorGraphs || []);
};

const formatDynamicActorGroupsForChat = (
  groups: Array<Record<string, unknown>>,
) => {
  if (groups.length === 0) return 'none';
  return groups
    .slice(0, 8)
    .map(group => {
      const seedIds = numberArray(group.seedEntityIds).join('/');
      const entityCount = Number(group.relatedEntityCount);
      const gridCount = Number(group.relatedGridCount);
      return `${seedIds || '?'}(${Number.isFinite(entityCount) ? entityCount : '?'}e/${Number.isFinite(gridCount) ? gridCount : '?'}g)`;
    })
    .join(', ');
};

const getNativeStatusField = (status: string, field: string) =>
  status.match(new RegExp(`(?:^|\\s)${field}=([^\\s]+)`))?.[1] ?? '';

const nativePrefabHookLogCursor = () => {
  try {
    return existsSync(NATIVE_PREFAB_HOOK_LOG_PATH)
      ? statSync(NATIVE_PREFAB_HOOK_LOG_PATH).size
      : 0;
  } catch (_error) {
    return 0;
  }
};

const readNativePrefabHookLogSince = (cursor: number) => {
  try {
    if (!existsSync(NATIVE_PREFAB_HOOK_LOG_PATH)) return '';
    const bytes = readFileSync(NATIVE_PREFAB_HOOK_LOG_PATH);
    const start = Math.max(0, Math.min(cursor, bytes.length));
    return bytes.subarray(start).toString('utf8');
  } catch (_error) {
    return '';
  }
};

const nativePrefabCommitLines = (text: string) =>
  text
    .split(/\r?\n/)
    .filter(
      line =>
        /\b(shared_submit_hit|additive_hit)=/.test(line) ||
        /\bspawn_accepted_(?:shared|file_shared|file_spawn|action)\b/.test(line),
    );

type NativePrefabDefinition = {
  name?: string;
  source?: string;
  capturedAt?: string;
  prefabPath?: string;
  hash?: string;
  orientation?: number;
  ownership?: boolean | number | string;
  temp?: boolean | number | string;
  target?: string;
  pasteSeedHex?: string;
  placeSeedHex?: string;
  placeAdjust?: string;
  placeOnly?: boolean | number | string;
  capture?: Record<string, unknown>;
};

const cleanHex = (value: unknown) =>
  String(value || '')
    .replace(/[^0-9a-fA-F]/g, '')
    .toUpperCase();

const NATIVE_PREFAB_CAR_HASH =
  cleanHex(process.env.OMEGGA_NATIVE_PREFAB_CAR_HASH) ||
  'A0E801F8662CA5E645861B03FA2783F781356D0CA0A66BEE0400D883A2ED96C7';

const boolToken = (value: unknown, fallback: boolean) => {
  if (value == null) return fallback ? '1' : '0';
  const text = String(value).toLowerCase();
  return text === '1' || text === 'true' || text === 'yes' || text === 'on'
    ? '1'
    : '0';
};

const envEnabled = (name: string, fallback = false) => {
  const value = process.env[name];
  if (value == null || value === '') return fallback;
  const text = String(value).toLowerCase();
  return text === '1' || text === 'true' || text === 'yes' || text === 'on';
};

const readNativePrefabDefinitions = () => {
  if (!existsSync(NATIVE_PREFAB_DEFINITIONS_PATH)) {
    return {} as Record<string, NativePrefabDefinition>;
  }
  try {
    const parsed = JSON.parse(readFileSync(NATIVE_PREFAB_DEFINITIONS_PATH, 'utf8'));
    return parsed && typeof parsed === 'object'
      ? (parsed.prefabs || parsed)
      : ({} as Record<string, NativePrefabDefinition>);
  } catch (error) {
    Logger.warnp('native prefab definitions parse failed', error);
    return {} as Record<string, NativePrefabDefinition>;
  }
};

const writeNativePrefabDefinition = (
  kind: string,
  definition: NativePrefabDefinition,
) => {
  let parsed = {} as Record<string, unknown>;
  let wrapped = false;
  if (existsSync(NATIVE_PREFAB_DEFINITIONS_PATH)) {
    try {
      parsed = JSON.parse(readFileSync(NATIVE_PREFAB_DEFINITIONS_PATH, 'utf8'));
      wrapped = Boolean(
        parsed &&
          typeof parsed === 'object' &&
          (parsed as { prefabs?: unknown }).prefabs &&
          typeof (parsed as { prefabs?: unknown }).prefabs === 'object',
      );
    } catch (error) {
      debugNativePrefab('capture definitions parse failed before write', error);
      parsed = {};
    }
  }

  const prefabs = wrapped
    ? ({ ...((parsed as { prefabs?: Record<string, NativePrefabDefinition> })
        .prefabs || {}) } as Record<string, NativePrefabDefinition>)
    : ({ ...(parsed as Record<string, NativePrefabDefinition>) } as Record<
        string,
        NativePrefabDefinition
      >);
  prefabs[kind] = definition;

  const next = wrapped ? { ...parsed, prefabs } : prefabs;
  writeFileSync(
    NATIVE_PREFAB_DEFINITIONS_PATH,
    `${JSON.stringify(next, null, 2)}\n`,
    'utf8',
  );
};

const bridgeOutputLines = (output: unknown) =>
  Array.isArray((output as { chunks?: unknown[] })?.chunks)
    ? ((output as { chunks: Array<{ line?: unknown }> }).chunks || []).map(chunk =>
        String(chunk?.line ?? ''),
      )
    : [];

const bridgeLineFields = (lines: string[]) => {
  const fields = new Map<string, string>();
  for (const line of lines) {
    const match = line.match(/^([^=]+)=(.*)$/);
    if (match) fields.set(match[1], match[2]);
  }
  return fields;
};

const parseNativePrefabRawHistory = (lines: string[]) => {
  const history = [] as Array<{
    index: number;
    sequence: number;
    source: string;
    label: string;
    function: string;
    contextPointer: string;
    bytes: number;
  }>;
  for (const line of lines) {
    const match = String(line).match(
      /^history\[(\d+)\]=seq=(\d+)\s+source=([^ ]*)\s+label=([^ ]*)\s+function=(.*?)\s+context_pointer=([^ ]*)\s+bytes=(\d+)$/,
    );
    if (!match) continue;
    history.push({
      index: Number(match[1]),
      sequence: Number(match[2]),
      source: match[3],
      label: match[4],
      function: match[5],
      contextPointer: match[6],
      bytes: Number(match[7]),
    });
  }
  return history;
};

const parseNativePrefabRawCapture = (lines: string[]) => {
  const fields = bridgeLineFields(lines);
  const placeSeedHex = cleanHex(fields.get('param_hex'));
  const history = parseNativePrefabRawHistory(lines);
  return {
    enabled: fields.get('enabled') === 'true',
    targetLabel: fields.get('target_label') || '',
    lastCapture: fields.get('last_capture') || '',
    source: fields.get('source') || '',
    paramBytes: Number(fields.get('param_bytes')),
    replayLayout: fields.get('raw_replay_layout') || '',
    placeSeedHex,
    history,
    clientPaste: history.find(
      entry => entry.source === 'client' && entry.label === 'ServerPastePrefab',
    ),
    clientPlace: history.find(
      entry =>
        entry.source === 'client' && entry.label === 'ServerPlaceCurrentPrefab',
    ),
  };
};

const parseNativePrefabSpecificRawCapture = (lines: string[]) => {
  const fields = bridgeLineFields(lines);
  const paramHex = cleanHex(fields.get('param_hex'));
  return {
    available: fields.get('available') === 'true',
    targetLabel: fields.get('target_label') || '',
    paramBytes: Number(fields.get('param_bytes')),
    replayLayout: fields.get('raw_replay_layout') || '',
    paramHex,
    error: fields.get('error') || '',
  };
};

const readLatestNativePrefabCacheHash = () => {
  if (!existsSync(NATIVE_PREFAB_LOG_PATH)) {
    return null as null | { hash: string; size: number | null; line: string };
  }

  const lines = readFileSync(NATIVE_PREFAB_LOG_PATH, 'utf8').split(/\r?\n/);
  for (let index = lines.length - 1; index >= 0; index--) {
    const line = lines[index];
    if (!line.includes('LogBrickPrefabs:')) continue;
    const hash = line.match(/Hash=([0-9a-fA-F]{64})/)?.[1]?.toUpperCase();
    if (!hash) continue;
    const sizeMatch = line.match(/(?:DataSize|Size)=(\d+) bytes/);
    return {
      hash,
      size: sizeMatch ? Number(sizeMatch[1]) : null,
      line,
    };
  }

  return null as null | { hash: string; size: number | null; line: string };
};

const hexBytes = (bytes: Uint8Array) =>
  Buffer.from(bytes).toString('hex').toUpperCase();

const findNativePrefabSourceByHash = (
  hash: string,
  expectedSize: number | null,
) => {
  const normalizedHash = cleanHex(hash);
  if (normalizedHash.length !== 64) return null as null | string;

  const candidates: string[] = [];
  for (const root of NATIVE_PREFAB_SOURCE_DIRS) {
    if (!existsSync(root)) continue;
    const stack = [root];
    while (stack.length > 0) {
      const dir = stack.pop();
      if (!dir) continue;
      let entries = [] as ReturnType<typeof readdirSync>;
      try {
        entries = readdirSync(dir, { withFileTypes: true });
      } catch (error) {
        debugNativePrefab('prefab source scan dir failed', dir, error);
        continue;
      }

      for (const entry of entries) {
        const fullPath = join(dir, entry.name);
        if (entry.isDirectory()) {
          stack.push(fullPath);
          continue;
        }
        if (!entry.isFile()) continue;

        try {
          const stat = statSync(fullPath);
          if (
            Number.isFinite(expectedSize) &&
            expectedSize != null &&
            stat.size !== expectedSize
          ) {
            continue;
          }
          const bytes = readFileSync(fullPath);
          if (hexBytes(blake3(bytes)) === normalizedHash) {
            candidates.push(fullPath);
          }
        } catch (error) {
          debugNativePrefab('prefab source hash failed', fullPath, error);
        }
      }
    }
  }

  candidates.sort((left, right) => {
    const leftBrz = left.toLowerCase().endsWith('.brz') ? 0 : 1;
    const rightBrz = right.toLowerCase().endsWith('.brz') ? 0 : 1;
    return leftBrz - rightBrz || left.localeCompare(right);
  });
  return candidates[0] || null;
};

const extractPointer = (value: unknown) =>
  String(value || '').match(/0x[0-9a-fA-F]+/)?.[0] ?? '';

const fallbackSpawnTarget = (index = 0): [number, number, number] => {
  const columns = Math.max(
    1,
    Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_FALLBACK_COLUMNS, 5)),
  );
  const spacingX = Math.round(
    finiteOr(process.env.OMEGGA_NATIVE_PREFAB_SPACING_X, 900),
  );
  const spacingY = Math.round(
    finiteOr(process.env.OMEGGA_NATIVE_PREFAB_SPACING_Y, 900),
  );
  return [
    Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_FALLBACK_X, 4366)) +
      (index % columns) * spacingX,
    Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_FALLBACK_Y, 500)) +
      Math.floor(index / columns) * spacingY,
    Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_FALLBACK_Z, 500)),
  ];
};

// TODO: safe broadcast parsing

export default class Omegga extends OmeggaWrapper implements OmeggaLike {
  /** The save counter prevents omegga from saving over the same file */
  _tempCounter = { save: 0, environment: 0 };
  /** The save prefix is prepended to all temporary saves */
  _tempSavePrefix = 'omegga_temp_';

  // pluginloader is not private so plugins can potentially add more formats
  pluginLoader: PluginLoader = undefined;
  webserver: Webserver;

  verbose: boolean;
  savePath: string;
  worldPath: string;
  presetPath: string;
  configPath: string;
  options: IOmeggaOptions;

  version: number;

  host?: { id: string; name: string };
  players: OmeggaPlayer[];

  started = false;
  starting = false;
  stopping = false;
  currentMap: string;
  _startedAtMs = 0;
  _playerJoinedAt = new Map<string, number>();
  _nativePrefabFallbackCount = 0;

  getServerStatus: () => Promise<IServerStatus>;
  listMinigames: () => Promise<IMinigameList>;
  getAllPlayerPositions: () => Promise<IPlayerPositions>;
  getMinigames: () => Promise<ILogMinigame[]>;

  /**
   * Omegga instance
   */
  constructor(serverPath: string, cfg: IConfig, options: IOmeggaOptions = {}) {
    super(serverPath, cfg);
    this.verbose = Logger.VERBOSE;

    Logger.verbose('Running omegga', `v${VERSION}`.green);
    Logger.verbose('Versions', process.versions);
    Logger.verbose('Config', cfg);

    // inject commands
    Logger.verbose('Setting up command injector');
    commandInjector(this, this.logWrangler);

    // launch options (disabling webserver)
    this.options = options;
    const savedDir = cfg.server.savedDir ?? CONFIG_SAVED_DIR;

    // path to save files
    this.savePath = join(this.path, DATA_PATH, savedDir, 'Builds');
    this.worldPath = join(this.path, DATA_PATH, savedDir, 'Worlds');

    this.presetPath = join(this.path, DATA_PATH, savedDir, 'Presets');

    // path to config files
    this.configPath = join(this.path, DATA_PATH, savedDir, 'Server');

    // create dir folders
    Logger.verbose('Creating directories');
    mkdir(this.savePath);
    mkdir(this.configPath);

    // ignore auth file copy
    if (!options.noauth) {
      Logger.verbose('Copying auth files');
      this.copyAuthFiles();
    }

    // create the webserver if it's enabled
    // the web interface provides access to server information while the server is running
    // and lets you view chat logs, disable plugins, etc
    if (!options.noweb) {
      Logger.verbose('Creating webserver');
      this.webserver = new Webserver(cfg.omegga, this);
    }

    if (!options.noplugin) {
      Logger.verbose('Creating plugin loader');
      // create the pluginloader
      this.pluginLoader = new PluginLoader(this.path, this);
    }

    /** @type {Array<Player>}list of online players */
    this.players = [];

    /** host player info `{id: uuid, name: player name}` */
    this.host = undefined;

    /** @type {String} current game version - may later be turned into CL#### versions */
    this.version = -1;

    /** @type {Boolean} whether server has started */
    this.started = false;
    /** @type {Boolean} whether server is starting up */
    this.starting = false;

    /** @type {String} current map */
    this.currentMap = '';

    // add all the matchers to the server
    Logger.verbose('Adding matchers');
    for (const matcher of MATCHERS) {
      const { pattern, callback } = matcher(this);
      this.addMatcher(pattern, callback);
    }

    process.on('uncaughtException', async err => {
      Logger.verbose('Uncaught exception', err);
      this.emit('error', err);

      // publish stop to database
      this.webserver?.database?.addChatLog('server', {}, 'Server error');

      try {
        await this.stop();
      } catch (e) {
        Logger.error(e);
      }
      process.exit();
    });

    // when brickadia starts, mark the server as started
    this.on('start', ({ map }) => {
      this.started = true;
      this.starting = false;
      this.currentMap = map;
      this._startedAtMs = Date.now();
      this._playerJoinedAt.clear();
      this.writeln('Chat.MessageForUnknownCommands 0');

      this.restoreServer();
    });

    // when brickadia exits, stop omegga
    this.on('exit', () => {
      this.stop();
    });

    // when the process closes, emit the exit signal and stop
    this.on('closed', () => {
      if (this.started) this.emit('exit');
      if (!this.stopping) this.stop();
    });

    this.on('join', (player: OmeggaPlayer) => {
      this._playerJoinedAt.set(player.id, Date.now());
    });

    this.on('leave', (player: OmeggaPlayer) => {
      this._playerJoinedAt.delete(player.id);
    });

    this.on('cmd:spawn', (name, ...args) => {
      debugNativePrefab('event cmd:spawn', name, args);
      void this.handleNativePrefabSpawnCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:spawn error', name, error);
        Logger.errorp('native prefab spawn command failed', error);
      });
    });

    this.on('cmd:spawncar', (name, ...args) => {
      debugNativePrefab('event cmd:spawncar', name, args);
      void this.handleNativePrefabSpawnCommand(name, 'car', ...args).catch(
        error => {
          debugNativePrefab('event cmd:spawncar error', name, error);
          Logger.errorp('native prefab spawn command failed', error);
        },
      );
    });

    this.on('cmd:capture', (name, ...args) => {
      debugNativePrefab('event cmd:capture', name, args);
      void this.handleNativePrefabCaptureCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:capture error', name, error);
        Logger.errorp('native prefab capture command failed', error);
      });
    });

    this.on('cmd:capturecar', (name, ...args) => {
      debugNativePrefab('event cmd:capturecar', name, args);
      void this.handleNativePrefabCaptureCommand(name, 'car', ...args).catch(
        error => {
          debugNativePrefab('event cmd:capturecar error', name, error);
          Logger.errorp('native prefab capture command failed', error);
        },
      );
    });

    this.on('cmd:savevehicleprobe', (name, ...args) => {
      debugNativePrefab('event cmd:savevehicleprobe', name, args);
      void this.handleAdditiveVehicleProbeSaveCommand(name, ...args).catch(
        error => {
          debugNativePrefab('event cmd:savevehicleprobe error', name, error);
          Logger.errorp('additive vehicle probe save command failed', error);
        },
      );
    });

    this.on('cmd:loadvehicleprobe', (name, ...args) => {
      debugNativePrefab('event cmd:loadvehicleprobe', name, args);
      void this.handleAdditiveVehicleProbeLoadCommand(name, ...args).catch(
        error => {
          debugNativePrefab('event cmd:loadvehicleprobe error', name, error);
          Logger.errorp('additive vehicle probe load command failed', error);
        },
      );
    });

    this.on('cmd:savebrickregion', (name, ...args) => {
      debugNativePrefab('event cmd:savebrickregion', name, args);
      void this.handleBrickRegionSaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:savebrickregion error', name, error);
        Logger.errorp('brick region save command failed', error);
      });
    });

    this.on('cmd:saveprefab', (name, ...args) => {
      debugNativePrefab('event cmd:saveprefab', name, args);
      void this.handleCoordinatePrefabSaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:saveprefab error', name, error);
        Logger.errorp('coordinate prefab save command failed', error);
      });
    });

    this.on('cmd:listentities', (name, ...args) => {
      debugNativePrefab('event cmd:listentities', name, args);
      void this.handleEntityListCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:listentities error', name, error);
        Logger.errorp('entity list command failed', error);
      });
    });

    this.on('cmd:listdynamicactors', (name, ...args) => {
      debugNativePrefab('event cmd:listdynamicactors', name, args);
      void this.handleEntityListCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:listdynamicactors error', name, error);
        Logger.errorp('dynamic actor list command failed', error);
      });
    });

    this.on('cmd:saveentity', (name, ...args) => {
      debugNativePrefab('event cmd:saveentity', name, args);
      void this.handleEntitySaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:saveentity error', name, error);
        Logger.errorp('entity save command failed', error);
      });
    });

    this.on('cmd:savedynamicactor', (name, ...args) => {
      debugNativePrefab('event cmd:savedynamicactor', name, args);
      void this.handleDynamicActorSaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event cmd:savedynamicactor error', name, error);
        Logger.errorp('dynamic actor save command failed', error);
      });
    });

    // detect when a missing command is sent
    this.on('cmd', (cmd, name, ...args) => {
      // if it's not in the default commands and it's not registered to a plugin,
      // it's okay to send the missing command message
      if (
        !default_commands.includes(cmd) &&
        !NATIVE_PREFAB_COMMANDS.includes(String(cmd).toLowerCase()) &&
        (!this.pluginLoader || !this.pluginLoader.isCommand(cmd))
      ) {
        this.whisper(name, MISSING_CMD);
      }
    });

    this.on('chatcmd:spawn', (name, ...args) => {
      debugNativePrefab('event chatcmd:spawn', name, args);
      void this.handleNativePrefabSpawnCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:spawn error', name, error);
        Logger.errorp('native prefab spawn command failed', error);
      });
    });

    this.on('chatcmd:spawncar', (name, ...args) => {
      debugNativePrefab('event chatcmd:spawncar', name, args);
      void this.handleNativePrefabSpawnCommand(name, 'car', ...args).catch(
        error => {
          debugNativePrefab('event chatcmd:spawncar error', name, error);
          Logger.errorp('native prefab spawn command failed', error);
        },
      );
    });

    this.on('chatcmd:capture', (name, ...args) => {
      debugNativePrefab('event chatcmd:capture', name, args);
      void this.handleNativePrefabCaptureCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:capture error', name, error);
        Logger.errorp('native prefab capture command failed', error);
      });
    });

    this.on('chatcmd:capturecar', (name, ...args) => {
      debugNativePrefab('event chatcmd:capturecar', name, args);
      void this.handleNativePrefabCaptureCommand(name, 'car', ...args).catch(
        error => {
          debugNativePrefab('event chatcmd:capturecar error', name, error);
          Logger.errorp('native prefab capture command failed', error);
        },
      );
    });

    this.on('chatcmd:savevehicleprobe', (name, ...args) => {
      debugNativePrefab('event chatcmd:savevehicleprobe', name, args);
      void this.handleAdditiveVehicleProbeSaveCommand(name, ...args).catch(
        error => {
          debugNativePrefab('event chatcmd:savevehicleprobe error', name, error);
          Logger.errorp('additive vehicle probe save command failed', error);
        },
      );
    });

    this.on('chatcmd:loadvehicleprobe', (name, ...args) => {
      debugNativePrefab('event chatcmd:loadvehicleprobe', name, args);
      void this.handleAdditiveVehicleProbeLoadCommand(name, ...args).catch(
        error => {
          debugNativePrefab('event chatcmd:loadvehicleprobe error', name, error);
          Logger.errorp('additive vehicle probe load command failed', error);
        },
      );
    });

    this.on('chatcmd:savebrickregion', (name, ...args) => {
      debugNativePrefab('event chatcmd:savebrickregion', name, args);
      void this.handleBrickRegionSaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:savebrickregion error', name, error);
        Logger.errorp('brick region save command failed', error);
      });
    });

    this.on('chatcmd:saveprefab', (name, ...args) => {
      debugNativePrefab('event chatcmd:saveprefab', name, args);
      void this.handleCoordinatePrefabSaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:saveprefab error', name, error);
        Logger.errorp('coordinate prefab save command failed', error);
      });
    });

    this.on('chatcmd:listentities', (name, ...args) => {
      debugNativePrefab('event chatcmd:listentities', name, args);
      void this.handleEntityListCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:listentities error', name, error);
        Logger.errorp('entity list command failed', error);
      });
    });

    this.on('chatcmd:listdynamicactors', (name, ...args) => {
      debugNativePrefab('event chatcmd:listdynamicactors', name, args);
      void this.handleEntityListCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:listdynamicactors error', name, error);
        Logger.errorp('dynamic actor list command failed', error);
      });
    });

    this.on('chatcmd:saveentity', (name, ...args) => {
      debugNativePrefab('event chatcmd:saveentity', name, args);
      void this.handleEntitySaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:saveentity error', name, error);
        Logger.errorp('entity save command failed', error);
      });
    });

    this.on('chatcmd:savedynamicactor', (name, ...args) => {
      debugNativePrefab('event chatcmd:savedynamicactor', name, args);
      void this.handleDynamicActorSaveCommand(name, ...args).catch(error => {
        debugNativePrefab('event chatcmd:savedynamicactor error', name, error);
        Logger.errorp('dynamic actor save command failed', error);
      });
    });

    this.on('chat', (name, message) => {
      const rawText = String(message || '').trim();
      const text = rawText.toLowerCase();
      const [plainCommand, ...plainArgs] = rawText.split(/\s+/);
      const normalizedPlainCommand = String(plainCommand || '').toLowerCase();
      if (text === 'capturecar' || text === 'capture car') {
        debugNativePrefab('event chat plain capturecar', name, message);
        void this.handleNativePrefabCaptureCommand(name, 'car').catch(error => {
          debugNativePrefab('event chat plain capturecar error', name, error);
          Logger.errorp('native prefab capture command failed', error);
        });
        return;
      }

      if (text === 'savevehicleprobe' || text === 'save vehicle probe') {
        debugNativePrefab('event chat plain savevehicleprobe', name, message);
        void this.handleAdditiveVehicleProbeSaveCommand(name).catch(error => {
          debugNativePrefab('event chat plain savevehicleprobe error', name, error);
          Logger.errorp('additive vehicle probe save command failed', error);
        });
        return;
      }

      if (text === 'loadvehicleprobe' || text === 'load vehicle probe') {
        debugNativePrefab('event chat plain loadvehicleprobe', name, message);
        void this.handleAdditiveVehicleProbeLoadCommand(name).catch(error => {
          debugNativePrefab('event chat plain loadvehicleprobe error', name, error);
          Logger.errorp('additive vehicle probe load command failed', error);
        });
        return;
      }

      if (
        normalizedPlainCommand === 'listentities' ||
        normalizedPlainCommand === 'listdynamicactors' ||
        text === 'list dynamic actors' ||
        text === 'list entities'
      ) {
        debugNativePrefab('event chat plain dynamic actor list', name, message);
        void this.handleEntityListCommand(name, ...plainArgs).catch(error => {
          debugNativePrefab('event chat plain dynamic actor list error', name, error);
          Logger.errorp('dynamic actor list command failed', error);
        });
        return;
      }

      if (normalizedPlainCommand === 'saveentity') {
        debugNativePrefab('event chat plain saveentity', name, message);
        void this.handleEntitySaveCommand(name, ...plainArgs).catch(error => {
          debugNativePrefab('event chat plain saveentity error', name, error);
          Logger.errorp('entity save command failed', error);
        });
        return;
      }

      if (normalizedPlainCommand === 'savedynamicactor') {
        debugNativePrefab('event chat plain savedynamicactor', name, message);
        void this.handleDynamicActorSaveCommand(name, ...plainArgs).catch(error => {
          debugNativePrefab('event chat plain savedynamicactor error', name, error);
          Logger.errorp('dynamic actor save command failed', error);
        });
        return;
      }

      if (text !== 'spawncar' && text !== 'spawn car') return;

      debugNativePrefab('event chat plain spawncar', name, message);
      void this.handleNativePrefabSpawnCommand(name, 'car').catch(error => {
        debugNativePrefab('event chat plain spawncar error', name, error);
        Logger.errorp('native prefab spawn command failed', error);
      });
    });
  }

  async handleBrickRegionSaveCommand(name: string, ...args: string[]) {
    const timestamp = new Date()
      .toISOString()
      .replace(/[-:.TZ]/g, '')
      .slice(0, 17);
    const rawArgs = [...args].filter(arg => String(arg || '').trim() !== '');
    const firstArgNumber = Number.isFinite(Number(rawArgs[0]));
    const saveName = sanitizeWorldBundleName(
      !firstArgNumber && rawArgs.length > 0 ? rawArgs.shift() : undefined,
      `BrickRegion_${timestamp}`,
    );
    const corners = parseBoxCorners(rawArgs);

    if (!corners) {
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          'Usage: /savebrickregion <name> x1 y1 z1 x2 y2 z2',
        ),
      );
      return;
    }

    const region = regionFromCorners(corners);
    debugNativePrefab('brick region save start', name, {
      saveName,
      corners,
      region,
    });

    try {
      await this.saveBricksAsync(saveName, {
        center: region.center,
        extent: region.extent,
      });
      appendCoordinatePrefabRecord({
        type: 'brick-region',
        saveName,
        requestedBy: name,
        savedAt: new Date().toISOString(),
        corners,
        region,
        output: `${saveName}.brs`,
        vehicleCapable: false,
      });
      debugNativePrefab('brick region save complete', name, {
        saveName,
        region,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(`Brick region saved as ${saveName}.brs.`),
      );
    } catch (error) {
      debugNativePrefab('brick region save failed', name, {
        saveName,
        region,
        error,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Brick region save failed for ${saveName}; check logs for details.`,
        ),
      );
    }
  }

  async handleCoordinatePrefabSaveCommand(name: string, ...args: string[]) {
    const timestamp = new Date()
      .toISOString()
      .replace(/[-:.TZ]/g, '')
      .slice(0, 17);
    const rawArgs = [...args].filter(arg => String(arg || '').trim() !== '');
    const firstArgNumber = Number.isFinite(Number(rawArgs[0]));
    const prefabName = sanitizeWorldBundleName(
      !firstArgNumber && rawArgs.length > 0 ? rawArgs.shift() : undefined,
      'prefab',
    );
    const corners = parseBoxCorners(rawArgs);

    if (!corners) {
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage('Usage: /saveprefab <name> x1 y1 z1 x2 y2 z2'),
      );
      return;
    }

    const region = regionFromCorners(corners);
    const bundleName = sanitizeWorldBundleName(
      `${prefabName}_${timestamp}`,
      `prefab_${timestamp}`,
    );
    const brickSaveName = sanitizeWorldBundleName(
      `${bundleName}_bricks`,
      `prefab_bricks_${timestamp}`,
    );

    debugNativePrefab('coordinate prefab save start', name, {
      prefabName,
      bundleName,
      brickSaveName,
      corners,
      region,
    });

    const worldSaved = await this.saveWorldAs(bundleName);
    if (!worldSaved) {
      debugNativePrefab('coordinate prefab world snapshot failed', name, {
        bundleName,
        corners,
        region,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Coordinate prefab snapshot failed for ${bundleName}; use a new name or check the server log.`,
        ),
      );
      return;
    }

    let brickRegionSaved = false;
    let brickRegionError = '';
    try {
      await this.saveBricksAsync(brickSaveName, {
        center: region.center,
        extent: region.extent,
      });
      brickRegionSaved = true;
    } catch (error) {
      brickRegionError = error instanceof Error ? error.message : String(error);
      debugNativePrefab('coordinate prefab brick sidecar failed', name, {
        brickSaveName,
        error,
      });
    }

    appendCoordinatePrefabRecord({
      type: 'coordinate-prefab',
      prefabName,
      bundleName,
      requestedBy: name,
      savedAt: new Date().toISOString(),
      corners,
      region,
      sourceBundle: `${bundleName}.brdb`,
      brickRegionSidecar: brickRegionSaved ? `${brickSaveName}.brs` : null,
      brickRegionError,
      extractionStatus: 'pending-bounded-brdb-extractor',
      vehicleCapable: true,
      note: 'Source world snapshot is full-world; bounds are recorded for the extractor stage.',
    });

    debugNativePrefab('coordinate prefab save complete', name, {
      bundleName,
      brickSaveName,
      brickRegionSaved,
      region,
    });
    await this.tryNativePrefabWhisper(
      name,
      quoteChatMessage(
        `Coordinate prefab snapshot saved as ${bundleName}.brdb; bounded extraction pending.`,
      ),
    );
  }

  snapshotAndListSavedEntities(
    requestedBy: string,
    prefix: string,
  ): {
    bundleName: string;
    worldPath: string;
    outputPath: string;
    entityList: {
      entities?: Array<Record<string, unknown>>;
      entityIndex?: Record<string, unknown>;
      typeNames?: string[];
      brickGrids?: Array<Record<string, unknown>>;
      dynamicActorGraphs?: Array<Record<string, unknown>>;
      dynamicActorGroups?: Array<Record<string, unknown>>;
      selectedEntityGraph?: Record<string, unknown> | null;
    };
  } | null {
    const timestamp = new Date()
      .toISOString()
      .replace(/[-:.TZ]/g, '')
      .slice(0, 17);
    const bundleName = sanitizeWorldBundleName(
      `${prefix}_${timestamp}`,
      `EntitySnapshot_${timestamp}`,
    );
    const outputPath = join(
      dirname(SAVED_ENTITY_STATE_PATH),
      `${bundleName}-entities.json`,
    );

    return {
      bundleName,
      worldPath: '',
      outputPath,
      entityList: {},
    };
  }

  runSavedEntityInspector(
    bundleName: string,
    outputPath: string,
    entityId?: number,
  ): {
    entities?: Array<Record<string, unknown>>;
    entityIndex?: Record<string, unknown>;
    typeNames?: string[];
    brickGrids?: Array<Record<string, unknown>>;
    dynamicActorGraphs?: Array<Record<string, unknown>>;
    dynamicActorGroups?: Array<Record<string, unknown>>;
    selectedEntityGraph?: Record<string, unknown> | null;
  } {
    if (!existsSync(WORLD_ENTITY_LIST_SCRIPT_PATH)) {
      throw new Error(`Entity inspector script missing: ${WORLD_ENTITY_LIST_SCRIPT_PATH}`);
    }

    const worldPath = this.getWorldPath(bundleName);
    if (!worldPath) {
      throw new Error(`World bundle not found after save: ${bundleName}.brdb`);
    }

    const stdout = execFileSync(
      process.execPath,
      [
        WORLD_ENTITY_LIST_SCRIPT_PATH,
        worldPath,
        '--out-json',
        outputPath,
        ...(Number.isFinite(entityId) ? ['--entity-id', String(entityId)] : []),
      ],
      {
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
      },
    );
    return JSON.parse(stdout);
  }

  async handleEntityListCommand(name: string, ...args: string[]) {
    const rawArgs = [...args].filter(arg => String(arg || '').trim() !== '');
    const requestedPrefix = sanitizeWorldBundleName(
      rawArgs[0],
      'EntitySnapshot',
    );
    const snapshot = this.snapshotAndListSavedEntities(
      name,
      requestedPrefix,
    );
    if (!snapshot) return;

    debugNativePrefab('entity list snapshot start', name, {
      bundleName: snapshot.bundleName,
      outputPath: snapshot.outputPath,
    });

    const saved = await this.saveWorldAs(snapshot.bundleName);
    if (!saved) {
      debugNativePrefab('entity list snapshot save failed', name, {
        bundleName: snapshot.bundleName,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Entity list snapshot failed for ${snapshot.bundleName}.`,
        ),
      );
      return;
    }

    try {
      const entityList = this.runSavedEntityInspector(
        snapshot.bundleName,
        snapshot.outputPath,
      );
      const entities = entityList.entities || [];
      const dynamicActorGraphs = entityList.dynamicActorGraphs || [];
      const dynamicActorGroups = getDynamicActorGroups(entityList);
      const dynamicActorIds = entities
        .filter(entity => entity.typeName === 'BrickGridDynamicActor')
        .map(entity => entity.persistentIndex ?? entity.id);
      appendSavedEntityRecord({
        type: 'entity-list',
        bundleName: snapshot.bundleName,
        requestedBy: name,
        savedAt: new Date().toISOString(),
        outputPath: snapshot.outputPath,
        entityCount: entities.length,
        dynamicActorIds,
        dynamicActorGroups,
        dynamicActorGraphs: dynamicActorGraphs.map(graph => ({
          seedEntityId: graph.seedEntityId,
          status: graph.status,
          relatedEntityIds: graph.relatedEntityIds,
          relatedGridIds: graph.relatedGridIds,
        })),
      });
      debugNativePrefab('entity list snapshot complete', name, {
        bundleName: snapshot.bundleName,
        outputPath: snapshot.outputPath,
        entityCount: entities.length,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Dynamic actors saved: ${dynamicActorGroups.length} groups from ${entities.length} entities. Groups: ${formatDynamicActorGroupsForChat(dynamicActorGroups)}.`,
        ),
      );
    } catch (error) {
      debugNativePrefab('entity list inspect failed', name, {
        bundleName: snapshot.bundleName,
        outputPath: snapshot.outputPath,
        error,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Entity list snapshot saved, but entity inspection failed for ${snapshot.bundleName}.`,
        ),
      );
    }
  }

  async handleEntitySaveCommand(name: string, ...args: string[]) {
    const rawArgs = [...args].filter(arg => String(arg || '').trim() !== '');
    const firstArgNumber = Number.isFinite(Number(rawArgs[0]));
    const entityName = sanitizeWorldBundleName(
      !firstArgNumber && rawArgs.length > 0 ? rawArgs.shift() : undefined,
      'entity',
    );
    const entityId = Math.round(Number(rawArgs.shift()));

    if (!Number.isFinite(entityId)) {
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage('Usage: /saveentity <name> <persistentEntityId>'),
      );
      return;
    }

    const snapshot = this.snapshotAndListSavedEntities(
      name,
      `SavedEntity_${entityName}`,
    );
    if (!snapshot) return;

    debugNativePrefab('entity save snapshot start', name, {
      entityName,
      entityId,
      bundleName: snapshot.bundleName,
      outputPath: snapshot.outputPath,
    });

    const saved = await this.saveWorldAs(snapshot.bundleName);
    if (!saved) {
      debugNativePrefab('entity save snapshot failed', name, {
        entityName,
        entityId,
        bundleName: snapshot.bundleName,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Entity save snapshot failed for ${snapshot.bundleName}.`,
        ),
      );
      return;
    }

    try {
      const entityList = this.runSavedEntityInspector(
        snapshot.bundleName,
        snapshot.outputPath,
        entityId,
      );
      const entities = entityList.entities || [];
      const selected = entities.find(entity => {
        const id = Number(entity.persistentIndex ?? entity.id);
        return id === entityId;
      });

      if (!selected) {
        debugNativePrefab('entity save id missing', name, {
          entityName,
          entityId,
          bundleName: snapshot.bundleName,
          entityCount: entities.length,
        });
        await this.tryNativePrefabWhisper(
          name,
          quoteChatMessage(
            `Entity ${entityId} was not found in ${snapshot.bundleName}. Run /listentities again.`,
          ),
        );
        return;
      }

      const record = {
        type: 'saved-entity',
        entityName,
        entityId,
        selectedEntity: selected,
        selectedEntityGraph: entityList.selectedEntityGraph || null,
        requestedBy: name,
        savedAt: new Date().toISOString(),
        sourceBundle: `${snapshot.bundleName}.brdb`,
        entityListPath: snapshot.outputPath,
        extractionStatus: entityList.selectedEntityGraph
          ? 'entity-graph-captured-pending-brdb-slicer'
          : 'pending-entity-graph-extractor',
        note:
          'This records the selected saved-world entity and its resolved graph. The next step is BRDB slicing: copy only the related entity rows, brick grids, component chunks, and wire chunks into an additive-loadable bundle.',
      };
      appendSavedEntityRecord(record);
      debugNativePrefab('entity save record complete', name, record);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Entity ${entityId} (${String(
            selected.typeName || 'unknown',
          )}) recorded from ${snapshot.bundleName}.`,
        ),
      );
    } catch (error) {
      debugNativePrefab('entity save inspect failed', name, {
        entityName,
        entityId,
        bundleName: snapshot.bundleName,
        outputPath: snapshot.outputPath,
        error,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Entity snapshot saved, but inspection failed for ${snapshot.bundleName}.`,
        ),
      );
    }
  }

  async handleDynamicActorSaveCommand(name: string, ...args: string[]) {
    const rawArgs = [...args].filter(arg => String(arg || '').trim() !== '');
    const firstArgNumber = Number.isFinite(Number(rawArgs[0]));
    const dynamicActorName = sanitizeWorldBundleName(
      !firstArgNumber && rawArgs.length > 0 ? rawArgs.shift() : undefined,
      'dynamicActor',
    );
    const dynamicActorId = Math.round(Number(rawArgs.shift()));

    if (!Number.isFinite(dynamicActorId)) {
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          'Usage: /savedynamicactor <name> <dynamicActorId>',
        ),
      );
      return;
    }

    const snapshot = this.snapshotAndListSavedEntities(
      name,
      `SavedDynamicActor_${dynamicActorName}`,
    );
    if (!snapshot) return;

    debugNativePrefab('dynamic actor save snapshot start', name, {
      dynamicActorName,
      dynamicActorId,
      bundleName: snapshot.bundleName,
      outputPath: snapshot.outputPath,
    });

    const saved = await this.saveWorldAs(snapshot.bundleName);
    if (!saved) {
      debugNativePrefab('dynamic actor save snapshot failed', name, {
        dynamicActorName,
        dynamicActorId,
        bundleName: snapshot.bundleName,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Dynamic actor save snapshot failed for ${snapshot.bundleName}.`,
        ),
      );
      return;
    }

    try {
      const entityList = this.runSavedEntityInspector(
        snapshot.bundleName,
        snapshot.outputPath,
        dynamicActorId,
      );
      const entities = entityList.entities || [];
      const selected = entities.find(entity => {
        const id = Number(entity.persistentIndex ?? entity.id);
        return id === dynamicActorId;
      });

      if (!selected) {
        debugNativePrefab('dynamic actor save id missing', name, {
          dynamicActorName,
          dynamicActorId,
          bundleName: snapshot.bundleName,
          entityCount: entities.length,
        });
        await this.tryNativePrefabWhisper(
          name,
          quoteChatMessage(
            `Dynamic actor ${dynamicActorId} was not found in ${snapshot.bundleName}. Run /listdynamicactors again.`,
          ),
        );
        return;
      }

      if (selected.typeName !== 'BrickGridDynamicActor') {
        debugNativePrefab('dynamic actor save wrong type', name, {
          dynamicActorName,
          dynamicActorId,
          typeName: selected.typeName,
          bundleName: snapshot.bundleName,
        });
        await this.tryNativePrefabWhisper(
          name,
          quoteChatMessage(
            `Entity ${dynamicActorId} is ${String(selected.typeName || 'unknown')}, not BrickGridDynamicActor.`,
          ),
        );
        return;
      }

      const dynamicActorGroups = getDynamicActorGroups(entityList);
      const dynamicActorGroup =
        dynamicActorGroups.find(group =>
          numberArray(group.seedEntityIds).includes(dynamicActorId),
        ) || null;
      const seedIds = dynamicActorGroup
        ? numberArray(dynamicActorGroup.seedEntityIds)
        : [dynamicActorId];
      const relatedEntityCount = dynamicActorGroup
        ? Number(dynamicActorGroup.relatedEntityCount)
        : numberArray(entityList.selectedEntityGraph?.relatedEntityIds).length;
      const relatedGridCount = dynamicActorGroup
        ? Number(dynamicActorGroup.relatedGridCount)
        : numberArray(entityList.selectedEntityGraph?.relatedGridIds).length;

      const record = {
        type: 'saved-dynamic-actor',
        dynamicActorName,
        dynamicActorId,
        dynamicActorSeedIds: seedIds,
        selectedDynamicActor: selected,
        dynamicActorGroup,
        selectedDynamicActorGraph: entityList.selectedEntityGraph || null,
        requestedBy: name,
        savedAt: new Date().toISOString(),
        sourceBundle: `${snapshot.bundleName}.brdb`,
        entityListPath: snapshot.outputPath,
        extractionStatus: 'dynamic-actor-graph-captured-pending-brdb-slicer',
        note:
          'This records the selected dynamic actor group and its resolved graph. The next step is BRDB slicing: copy only related entity rows, brick grids, component chunks, and wire chunks into an additive-loadable bundle.',
      };
      appendSavedEntityRecord(record);
      debugNativePrefab('dynamic actor save record complete', name, record);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Dynamic actor group ${seedIds.join('/')} saved as ${dynamicActorName}: ${Number.isFinite(relatedEntityCount) ? relatedEntityCount : '?'} entities, ${Number.isFinite(relatedGridCount) ? relatedGridCount : '?'} grids.`,
        ),
      );
    } catch (error) {
      debugNativePrefab('dynamic actor save inspect failed', name, {
        dynamicActorName,
        dynamicActorId,
        bundleName: snapshot.bundleName,
        outputPath: snapshot.outputPath,
        error,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Dynamic actor snapshot saved, but inspection failed for ${snapshot.bundleName}.`,
        ),
      );
    }
  }

  async handleAdditiveVehicleProbeSaveCommand(name: string, ...args: string[]) {
    const timestamp = new Date()
      .toISOString()
      .replace(/[-:.TZ]/g, '')
      .slice(0, 17);
    const bundleName = sanitizeWorldBundleName(
      args[0],
      `VehiclePersistenceProbe_${timestamp}`,
    );

    debugNativePrefab('additive vehicle probe save start', name, { bundleName });
    const ok = await this.saveWorldAs(bundleName);
    if (!ok) {
      debugNativePrefab('additive vehicle probe save failed', name, { bundleName });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Vehicle probe save failed for ${bundleName}; use a new name or check the server log.`,
        ),
      );
      return;
    }

    writeAdditiveVehicleProbeState({
      bundleName,
      requestedBy: name,
      savedAt: new Date().toISOString(),
      strategy: 'additive-world-persistence-probe',
    });

    debugNativePrefab('additive vehicle probe save complete', name, {
      bundleName,
    });
    await this.tryNativePrefabWhisper(
      name,
      quoteChatMessage(
        `Vehicle probe saved as ${bundleName}. Run /loadvehicleprobe to additively load a duplicate.`,
      ),
    );
  }

  async handleAdditiveVehicleProbeLoadCommand(name: string, ...args: string[]) {
    const probeState = readAdditiveVehicleProbeState();
    const defaultBundleName = probeState?.bundleName || 'VehiclePersistenceProbe';
    const rawArgs = [...args].filter(arg => String(arg || '').trim() !== '');
    const firstArgNumber = Number.isFinite(Number(rawArgs[0]));
    const bundleName = sanitizeWorldBundleName(
      !firstArgNumber && rawArgs.length > 0 ? rawArgs.shift() : defaultBundleName,
      defaultBundleName,
    );
    const target =
      parseTriple(rawArgs) ||
      ([
        Math.round(finiteOr(process.env.OMEGGA_ADDITIVE_VEHICLE_PROBE_X, 20000)),
        Math.round(finiteOr(process.env.OMEGGA_ADDITIVE_VEHICLE_PROBE_Y, 0)),
        Math.round(finiteOr(process.env.OMEGGA_ADDITIVE_VEHICLE_PROBE_Z, 1000)),
      ] as [number, number, number]);
    const orientation = Math.round(
      finiteOr(
        rawArgs.length >= 4 ? rawArgs[3] : undefined,
        finiteOr(process.env.OMEGGA_ADDITIVE_VEHICLE_PROBE_ORIENTATION, 0),
      ),
    );

    debugNativePrefab('additive vehicle probe load start', name, {
      bundleName,
      target,
      orientation,
    });
    const ok = await this.loadWorldAdditive(
      bundleName,
      target[0],
      target[1],
      target[2],
      orientation,
    );

    if (!ok) {
      debugNativePrefab('additive vehicle probe load failed before command', name, {
        bundleName,
        target,
        orientation,
      });
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          `Vehicle probe load failed before additive load; ${bundleName}.brdb was not found.`,
        ),
      );
      return;
    }

    await this.tryNativePrefabWhisper(
      name,
      quoteChatMessage(
        `Vehicle probe additive load queued from ${bundleName} at ${target.join(
          ' ',
        )}.`,
      ),
    );
  }

  async armNativePrefabRawCapture(name: string) {
    try {
      const output = await this.execControlCommandWithOutput(
        'Omegga.Bridge.ArmRawProcessEventCapture ServerPastePrefab ServerPlaceCurrentPrefab',
        8000,
      );
      const lines = bridgeOutputLines(output);
      debugNativePrefab('capture arm complete', name, lines.slice(0, 20));
      Logger.logp('native prefab raw capture armed', name);
      return true;
    } catch (error) {
      debugNativePrefab('capture arm failed', name, error);
      Logger.warnp('native prefab raw capture arm failed', error);
      return false;
    }
  }

  async readNativePrefabSpecificRawCapture(name: string, label: string) {
    try {
      const output = await this.execControlCommandWithOutput(
        `Omegga.Bridge.DescribeRawProcessEventCaptureFor ${label}`,
        8000,
      );
      const lines = bridgeOutputLines(output);
      const capture = parseNativePrefabSpecificRawCapture(lines);
      debugNativePrefab('specific raw capture parsed', name, {
        label,
        capture: {
          available: capture.available,
          targetLabel: capture.targetLabel,
          paramBytes: capture.paramBytes,
          replayLayout: capture.replayLayout,
          paramHexLength: capture.paramHex.length,
          error: capture.error,
        },
      });
      return capture;
    } catch (error) {
      debugNativePrefab('specific raw capture bridge error', name, { label, error });
      Logger.warnp('native prefab specific raw capture failed', label, error);
      return null;
    }
  }

  async handleNativePrefabCaptureCommand(name: string, ...args: string[]) {
    debugNativePrefab('capture handler start', name, args);
    Logger.logp('native prefab capture command', name, args.join(' '));
    const kind = String(args[0] || '').toLowerCase();

    if (kind !== 'car') {
      debugNativePrefab('capture handler usage', name, { kind, args });
      Logger.warnp('native prefab capture usage', name, 'Usage: /capturecar');
      await this.tryNativePrefabWhisper(name, quoteChatMessage('Usage: /capturecar'));
      return;
    }

    let lines = [] as string[];
    try {
      const output = await this.execControlCommandWithOutput(
        'Omegga.Bridge.DescribeRawProcessEventCapture',
        8000,
      );
      lines = bridgeOutputLines(output);
    } catch (error) {
      debugNativePrefab('capture bridge error', name, error);
      Logger.warnp('native prefab capture bridge failed', error);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage('Vehicle snapshot failed: raw native capture bridge did not respond.'),
      );
      return;
    }

    const capture = parseNativePrefabRawCapture(lines);
    const cacheHash = readLatestNativePrefabCacheHash();
    debugNativePrefab('capture parsed', name, {
      capture: {
        enabled: capture.enabled,
        targetLabel: capture.targetLabel,
        source: capture.source,
        paramBytes: capture.paramBytes,
        replayLayout: capture.replayLayout,
        placeSeedHexLength: capture.placeSeedHex.length,
        clientPaste: capture.clientPaste,
        clientPlace: capture.clientPlace,
      },
      cacheHash,
    });

    const validPlaceSeed =
      capture.targetLabel === 'ServerPlaceCurrentPrefab' &&
      capture.replayLayout === 'ServerPlaceCurrentPrefab' &&
      capture.paramBytes === 0xdf &&
      capture.placeSeedHex.length === 0xdf * 2;

    const pasteCapture = await this.readNativePrefabSpecificRawCapture(
      name,
      'ServerPastePrefab',
    );
    const validPasteSeed =
      Boolean(pasteCapture) &&
      pasteCapture?.available === true &&
      pasteCapture.targetLabel === 'ServerPastePrefab' &&
      pasteCapture.replayLayout === 'ServerPastePrefab' &&
      pasteCapture.paramBytes === 0x40 &&
      pasteCapture.paramHex.length === 0x40 * 2;

    if (!validPlaceSeed || !validPasteSeed || !capture.clientPaste || !capture.clientPlace) {
      Logger.warnp(
        'native prefab capture incomplete',
        `target=${capture.targetLabel || '<none>'}`,
        `bytes=${Number.isFinite(capture.paramBytes) ? capture.paramBytes : '<none>'}`,
        `pasteBytes=${Number.isFinite(pasteCapture?.paramBytes) ? pasteCapture?.paramBytes : '<none>'}`,
      );
      await this.armNativePrefabRawCapture(name);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          'Vehicle snapshot armed. Place one working vehicle prefab, then run /capturecar again.',
        ),
      );
      return;
    }

    if (!cacheHash || cleanHex(cacheHash.hash).length !== 64) {
      debugNativePrefab('capture hash missing', name, { log: NATIVE_PREFAB_LOG_PATH });
      Logger.warnp('native prefab capture hash missing', NATIVE_PREFAB_LOG_PATH);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage('Vehicle snapshot failed: no prefab cache hash was found in Brickadia.log.'),
      );
      return;
    }

    const prefabPath = findNativePrefabSourceByHash(cacheHash.hash, cacheHash.size);
    if (!prefabPath) {
      debugNativePrefab('capture source missing', name, {
        hash: cacheHash.hash,
        size: cacheHash.size,
        sourceDirs: NATIVE_PREFAB_SOURCE_DIRS,
      });
      Logger.warnp(
        'native prefab capture source missing',
        cacheHash.hash,
        `size=${cacheHash.size ?? '<unknown>'}`,
      );
    }

    const existing = readNativePrefabDefinitions()[kind] || {};
    const definition: NativePrefabDefinition = {
      ...existing,
      name: existing.name || 'Car',
      source: 'native-cache-snapshot',
      capturedAt: new Date().toISOString(),
      prefabPath: prefabPath || existing.prefabPath,
      hash: cacheHash.hash,
      orientation: Math.max(
        0,
        Math.min(255, Math.round(finiteOr(existing.orientation, 16))),
      ),
      ...(existing.ownership != null ? { ownership: existing.ownership } : {}),
      ...(existing.temp != null ? { temp: existing.temp } : {}),
      target: existing.target && existing.target !== '0' ? existing.target : undefined,
      placeAdjust: 'full',
      placeOnly: false,
      pasteSeedHex: pasteCapture!.paramHex,
      placeSeedHex: capture.placeSeedHex,
      capture: {
        source: capture.source,
        lastCapture: capture.lastCapture,
        cacheLogPath: NATIVE_PREFAB_LOG_PATH,
        cacheLogLine: cacheHash.line,
        cacheSize: cacheHash.size,
        prefabPath: prefabPath || null,
        pasteSeedHexLength: pasteCapture!.paramHex.length,
        history: capture.history,
      },
    };

    writeNativePrefabDefinition(kind, definition);
    debugNativePrefab('capture saved', name, {
      kind,
      hash: definition.hash,
      pasteSeedHexLength: pasteCapture!.paramHex.length,
      placeSeedHexLength: capture.placeSeedHex.length,
      path: NATIVE_PREFAB_DEFINITIONS_PATH,
    });
    Logger.logp(
      'native prefab capture saved',
      kind,
      definition.hash,
      NATIVE_PREFAB_DEFINITIONS_PATH,
    );
    await this.tryNativePrefabWhisper(
      name,
      quoteChatMessage('Vehicle snapshot saved. /spawncar will use it from disk.'),
    );
  }

  async handleNativePrefabSpawnCommand(name: string, ...args: string[]) {
    debugNativePrefab('handler start', name, args);
    Logger.logp('native prefab spawn command', name, args.join(' '));
    const [kindRaw, modeRaw, ...rest] = args;
    const kind = String(kindRaw || '').toLowerCase();
    const mode = String(modeRaw || '').toLowerCase();

    if (kind !== 'car') {
      debugNativePrefab('handler usage', name, { kind, mode, rest });
      Logger.warnp('native prefab spawn usage', name, 'Usage: /spawncar or /spawn car');
      await this.tryNativePrefabWhisper(name, quoteChatMessage('Usage: /spawncar or /spawn car'));
      return;
    }

    const playerOffset = () => [
      finiteOr(process.env.OMEGGA_NATIVE_PREFAB_OFFSET_X, 0),
      finiteOr(process.env.OMEGGA_NATIVE_PREFAB_OFFSET_Y, 600),
      finiteOr(process.env.OMEGGA_NATIVE_PREFAB_OFFSET_Z, 250),
    ] as [number, number, number];

    const targetNearPlayer = async (offset: [number, number, number]) => {
      const player = this.getPlayer(name);
      let position: [number, number, number] | null = null;
      debugNativePrefab('target lookup start', name, {
        hasPlayer: Boolean(player),
        offset,
      });

      if (process.env.OMEGGA_NATIVE_PREFAB_PLAYER_LOCATION === '1') {
        try {
          const playerName = String(name || '')
            .replace(/[\r\n]/g, ' ')
            .trim();
          const output = await this.execControlCommandWithOutput(
            `Omegga.Bridge.DescribePlayerLocation ${playerName}`,
            5000,
          );
          const lines = bridgeOutputLines(output);
          const fields = bridgeLineFields(lines);
          if (fields.get('ok') === 'true') {
            const x = Number(fields.get('x'));
            const y = Number(fields.get('y'));
            const z = Number(fields.get('z'));
            if ([x, y, z].every(Number.isFinite)) {
              position = [x, y, z];
              debugNativePrefab('target bridge position', name, {
                position,
                source: fields.get('source') || '',
              });
              Logger.logp(
                'native prefab spawn bridge position',
                name,
                position.join(', '),
                fields.get('source') || '',
              );
            }
          } else {
            debugNativePrefab(
              'target bridge unresolved',
              name,
              fields.get('detail') || lines.slice(0, 5).join(' | '),
            );
            Logger.warnp(
              'native prefab spawn bridge position unresolved',
              name,
              fields.get('detail') || lines.slice(0, 5).join(' | '),
            );
          }
        } catch (error) {
          debugNativePrefab('target bridge error', name, error);
          Logger.warnp('native prefab spawn bridge position lookup failed', error);
        }
      }

      if (player) {
        try {
          position = position || (await player.getPosition());
          debugNativePrefab('target player position', name, position);
        } catch (error) {
          debugNativePrefab('target player error', name, error);
          Logger.errorp('native prefab spawn position lookup failed', error);
        }
      }

      if (!position) {
        debugNativePrefab('target lookup missing', name);
        return null;
      }

      const target = [
        Math.round(position[0] + offset[0]),
        Math.round(position[1] + offset[1]),
        Math.round(position[2] + offset[2]),
      ] as [number, number, number];
      debugNativePrefab('target resolved', name, target);
      return target;
    };

    let target = null as [number, number, number] | null;
    if (mode === 'absolute' || mode === 'at') {
      target = parseTriple(rest);
      if (!target) {
        debugNativePrefab('target absolute invalid', name, { mode, rest });
        Logger.warnp(
          'native prefab spawn usage',
          name,
          'Usage: /spawn car absolute x y z',
        );
        return;
      }
    } else if (
      mode === '' ||
      mode === 'player' ||
      mode === 'nearplayer' ||
      mode === 'near' ||
      mode === 'offset'
    ) {
      const explicitOffset =
        mode === 'offset' || mode === 'near' ? parseTriple(rest) : null;
      target = await targetNearPlayer(explicitOffset || playerOffset());
      if (!target) {
        target = fallbackSpawnTarget(this._nativePrefabFallbackCount++);
        debugNativePrefab('target fallback', name, target);
        Logger.warnp(
          'native prefab spawn fallback',
          name,
          `Could not resolve player position; using ${target.join(', ')}`,
        );
      }
    } else {
      target = fallbackSpawnTarget(this._nativePrefabFallbackCount++);
      debugNativePrefab('target fallback unknown mode', name, { mode, target });
    }

    debugNativePrefab('handler target final', name, target);
    if (await this.tryNativePrefabBrokerCommand(name, kind, target)) {
      debugNativePrefab('handler broker queued', name, target);
      return;
    }

    if (await this.tryNativePrefabFileSpawnCommand(name, kind, target)) {
      debugNativePrefab('handler native file complete', name, target);
      return;
    }

    if (await this.tryNativePrefabSnapshotSeedCommand(name, kind)) {
      debugNativePrefab('handler snapshot seed complete', name, target);
    }

    if (await this.tryNativePrefabHashSpawnCommand(name, kind, target)) {
      debugNativePrefab('handler native hash complete', name, target);
      return;
    }

    if (await this.tryNativePrefabLiveSharedReplayCommand(name, kind, target)) {
      debugNativePrefab('handler native live shared complete', name, target);
      return;
    }

    if (process.env.OMEGGA_NATIVE_PREFAB_LEGACY_HOOK !== '1') {
      debugNativePrefab('handler legacy disabled', name, target);
      Logger.warnp(
        'native prefab legacy hook fallback disabled',
        name,
        target.join(', '),
      );
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage(
          'Vehicle spawn failed before placement; place a working vehicle and run /capturecar to refresh the snapshot.',
        ),
      );
      return;
    }

    const nonce = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    writeFileSync(
      NATIVE_PREFAB_COMMAND_PATH,
      [
        'spawn=1',
        `nonce=${nonce}`,
        `absolute_x=${target[0]}`,
        `absolute_y=${target[1]}`,
        `absolute_z=${target[2]}`,
        '',
      ].join('\n'),
      'utf8',
    );

    let status = '';
    try {
      Logger.logp(
        'native prefab spawn queued',
        name,
        target.join(', '),
        nonce,
      );
      debugNativePrefab('legacy queued', name, { target, nonce });

      for (let attempt = 0; attempt < 30; attempt++) {
        await sleep(100);
        try {
          status = readFileSync(NATIVE_PREFAB_STATUS_PATH, 'utf8');
        } catch (_error) {
          status = '';
        }
        if (status.includes(`nonce=${nonce}`)) break;
      }

      if (!status.includes(`nonce=${nonce}`)) {
        debugNativePrefab('legacy timeout', name, { nonce, status });
        Logger.warnp('native prefab spawn status timeout', nonce);
        await this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn timed out before the native hook responded.'),
        );
        return;
      }

      const normalizedStatus = status.trim().replace(/\s+/g, ' ');
      if (status.includes('ok=1')) {
        debugNativePrefab('legacy accepted', name, normalizedStatus);
        Logger.logp('native prefab spawn accepted', normalizedStatus);
        await this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn accepted by native hook.'),
        );
      } else {
        debugNativePrefab('legacy failed', name, normalizedStatus);
        Logger.warnp('native prefab spawn failed', normalizedStatus);
        const error = getNativeStatusField(status, 'error');
        const message =
          error === 'no_shared_or_action_snapshot'
            ? 'Place one working vehicle prefab first, then run /spawncar again.'
            : error === 'target_allocator_unavailable'
              ? 'Vehicle spawn failed: target allocator unavailable.'
              : `Vehicle spawn failed${error ? `: ${error}` : ''}.`;
        await this.tryNativePrefabWhisper(name, quoteChatMessage(message));
      }
    } finally {
      try {
        writeFileSync(
          NATIVE_PREFAB_COMMAND_PATH,
          ['spawn=0', `last_nonce=${nonce}`, ''].join('\n'),
          'utf8',
        );
      } catch (error) {
        debugNativePrefab('legacy reset failed', name, error);
        Logger.warnp('native prefab spawn command reset failed', error);
      }
    }
  }

  async tryNativePrefabBrokerCommand(
    name: string,
    kind: string,
    target: [number, number, number],
  ) {
    if (kind !== 'car' || !envEnabled('OMEGGA_PREFAB_BROKER')) {
      return false;
    }

    const nonce = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    const request = {
      id: nonce,
      type: 'spawn_prefab',
      prefab: kind,
      requestedBy: String(name || ''),
      requestedAt: new Date().toISOString(),
      target: {
        x: target[0],
        y: target[1],
        z: target[2],
      },
      source: 'omegga-chat-command',
      strategy: 'client-placement-worker',
    };

    try {
      appendFileSync(
        NATIVE_PREFAB_BROKER_REQUEST_PATH,
        `${JSON.stringify(request)}\n`,
        'utf8',
      );
      Logger.logp(
        'native prefab broker request queued',
        name,
        kind,
        target.join(', '),
        nonce,
      );
      debugNativePrefab('broker request queued', name, request);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage('Vehicle spawn request queued for the prefab worker.'),
      );
    } catch (error) {
      debugNativePrefab('broker request failed', name, error);
      Logger.warnp('native prefab broker request failed', error);
      await this.tryNativePrefabWhisper(
        name,
        quoteChatMessage('Vehicle spawn request could not be queued for the prefab worker.'),
      );
    }

    return true;
  }

  async tryNativePrefabLiveSharedReplayCommand(
    name: string,
    kind: string,
    target: [number, number, number],
  ) {
    if (
      kind !== 'car' ||
      process.env.OMEGGA_NATIVE_PREFAB_SHARED_REPLAY !== '1' ||
      process.env.OMEGGA_NATIVE_PREFAB_LIVE_SHARED_REPLAY !== '1'
    ) {
      return false;
    }

    const nonce = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    writeFileSync(
      NATIVE_PREFAB_COMMAND_PATH,
      [
        'spawn=1',
        'method=shared',
        `nonce=${nonce}`,
        `absolute_x=${target[0]}`,
        `absolute_y=${target[1]}`,
        `absolute_z=${target[2]}`,
        '',
      ].join('\n'),
      'utf8',
    );

    let status = '';
    try {
      Logger.logp(
        'native prefab live shared replay queued',
        name,
        target.join(', '),
        nonce,
      );
      debugNativePrefab('live shared queued', name, { target, nonce });

      for (let attempt = 0; attempt < 40; attempt++) {
        await sleep(100);
        try {
          status = readFileSync(NATIVE_PREFAB_STATUS_PATH, 'utf8');
        } catch (_error) {
          status = '';
        }
        if (status.includes(`nonce=${nonce}`)) break;
      }

      if (!status.includes(`nonce=${nonce}`)) {
        debugNativePrefab('live shared timeout', name, { nonce, status });
        Logger.warnp('native prefab live shared replay timeout', nonce);
        return false;
      }

      const normalizedStatus = status.trim().replace(/\s+/g, ' ');
      if (status.includes('ok=1')) {
        debugNativePrefab('live shared accepted', name, normalizedStatus);
        Logger.logp('native prefab live shared replay accepted', normalizedStatus);
        void this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn accepted by native shared replay.'),
        ).catch(error =>
          Logger.warnp('native prefab live shared replay whisper failed', error),
        );
        return true;
      }

      debugNativePrefab('live shared failed', name, normalizedStatus);
      Logger.warnp('native prefab live shared replay failed', normalizedStatus);
      return false;
    } finally {
      try {
        writeFileSync(
          NATIVE_PREFAB_COMMAND_PATH,
          ['spawn=0', `last_nonce=${nonce}`, ''].join('\n'),
          'utf8',
        );
      } catch (error) {
        debugNativePrefab('live shared reset failed', name, error);
        Logger.warnp('native prefab live shared command reset failed', error);
      }
    }
  }

  async tryNativePrefabSnapshotSeedCommand(name: string, kind: string) {
    if (kind !== 'car') {
      return false;
    }

    const definition = readNativePrefabDefinitions()[kind] || {};
    const prefabPath = String(definition.prefabPath || '').trim();
    const prefabHash = cleanHex(definition.hash);
    if (!prefabPath) {
      debugNativePrefab('snapshot seed skipped missing path', name, kind);
      return false;
    }
    if (!existsSync(prefabPath)) {
      debugNativePrefab('snapshot seed path missing', name, prefabPath);
      Logger.warnp('native prefab snapshot seed file missing', prefabPath);
      return false;
    }

    let contextFields = new Map<string, string>();
    let contextLines = [] as string[];
    try {
      const output = await this.execControlCommandWithOutput(
        'Omegga.Bridge.DescribeServerPastePrefabContext',
        5000,
      );
      contextLines = bridgeOutputLines(output);
      contextFields = bridgeLineFields(contextLines);
    } catch (error) {
      debugNativePrefab('snapshot seed context bridge error', name, error);
      Logger.warnp('native prefab snapshot seed context lookup failed', error);
      return false;
    }

    const cacheOwner =
      extractPointer(contextFields.get('prefab_cache_addr')) ||
      extractPointer(contextFields.get('prefab_cache'));
    if (!cacheOwner) {
      debugNativePrefab('snapshot seed context incomplete', name, {
        cacheOwner,
        lines: contextLines.slice(0, 20),
      });
      Logger.warnp('native prefab snapshot seed context incomplete');
      return false;
    }

    const seedWaitMs = Math.max(
      1000,
      Math.min(
        30000,
        Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_SEED_WAIT_MS, 12000)),
      ),
    );
    const deadline = Date.now() + seedWaitMs;
    let lastStatus = '';
    let seedAttempt = 0;

    while (Date.now() < deadline) {
      const nonce = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
      writeFileSync(
        NATIVE_PREFAB_COMMAND_PATH,
        [
          'spawn=1',
          'method=file_seed',
          `nonce=${nonce}`,
          `cache_owner=${cacheOwner}`,
          prefabHash ? `hash=${prefabHash}` : '',
          `prefab_path=${prefabPath}`,
          '',
        ].filter(Boolean).join('\n'),
        'utf8',
      );

      let status = '';
      try {
        seedAttempt++;
        Logger.logp('native prefab snapshot seed queued', name, prefabPath, nonce);
        debugNativePrefab('snapshot seed queued', name, {
          nonce,
          cacheOwner,
          prefabPath,
          prefabHash,
          seedAttempt,
        });

        for (let poll = 0; poll < 30; poll++) {
          await sleep(100);
          try {
            status = readFileSync(NATIVE_PREFAB_STATUS_PATH, 'utf8');
          } catch (_error) {
            status = '';
          }
          if (status.includes(`nonce=${nonce}`)) break;
        }
      } finally {
        try {
          writeFileSync(
            NATIVE_PREFAB_COMMAND_PATH,
            ['spawn=0', `last_nonce=${nonce}`, ''].join('\n'),
            'utf8',
          );
        } catch (error) {
          debugNativePrefab('snapshot seed reset failed', name, error);
          Logger.warnp('native prefab snapshot seed command reset failed', error);
        }
      }

      if (!status.includes(`nonce=${nonce}`)) {
        debugNativePrefab('snapshot seed timeout attempt', name, { nonce, status });
        lastStatus = status.trim().replace(/\s+/g, ' ');
        await sleep(250);
        continue;
      }

      const normalizedStatus = status.trim().replace(/\s+/g, ' ');
      lastStatus = normalizedStatus;
      if (status.includes('ok=1')) {
        debugNativePrefab('snapshot seed accepted', name, normalizedStatus);
        Logger.logp('native prefab snapshot seed accepted', normalizedStatus);
        return true;
      }

      if (getNativeStatusField(status, 'pending') === '1') {
        debugNativePrefab('snapshot seed pending', name, {
          seedAttempt,
          status: normalizedStatus,
        });
        await sleep(250);
        continue;
      }

      debugNativePrefab('snapshot seed failed', name, normalizedStatus);
      Logger.warnp('native prefab snapshot seed failed', normalizedStatus);
      return false;
    }

    debugNativePrefab('snapshot seed timeout', name, { seedWaitMs, lastStatus });
    Logger.warnp('native prefab snapshot seed status timeout', lastStatus || '<empty>');
    return false;
  }

  async tryNativePrefabFileSpawnCommand(
    name: string,
    kind: string,
    target: [number, number, number],
  ) {
    if (kind !== 'car') {
      return false;
    }

    if (
      process.env.OMEGGA_NATIVE_PREFAB_FILE_SHARED !== '1' ||
      process.env.OMEGGA_NATIVE_PREFAB_FILE_HOOK !== '1' ||
      process.env.OMEGGA_NATIVE_PREFAB_SHARED_REPLAY !== '1'
    ) {
      debugNativePrefab('file shared skipped', name, {
        fileShared: process.env.OMEGGA_NATIVE_PREFAB_FILE_SHARED || '',
        fileHook: process.env.OMEGGA_NATIVE_PREFAB_FILE_HOOK || '',
        sharedReplay: process.env.OMEGGA_NATIVE_PREFAB_SHARED_REPLAY || '',
      });
      return false;
    }

    const definition = readNativePrefabDefinitions()[kind] || {};
    const prefabPath = String(definition.prefabPath || NATIVE_PREFAB_CAR_PATH).trim();
    const prefabHash = cleanHex(definition.hash);
    const orientation = Math.max(
      0,
      Math.min(255, Math.round(finiteOr(definition.orientation, 16))),
    );

    if (!existsSync(prefabPath)) {
      debugNativePrefab('file prefab missing', name, prefabPath);
      Logger.warnp('native prefab file missing', prefabPath);
      return false;
    }

    let contextFields = new Map<string, string>();
    let contextLines = [] as string[];
    try {
      const output = await this.execControlCommandWithOutput(
        'Omegga.Bridge.DescribeServerPastePrefabContext',
        5000,
      );
      contextLines = bridgeOutputLines(output);
      contextFields = bridgeLineFields(contextLines);
    } catch (error) {
      debugNativePrefab('file context bridge error', name, error);
      Logger.warnp('native prefab file context lookup failed', error);
      return false;
    }

    const cacheOwner =
      extractPointer(contextFields.get('prefab_cache_addr')) ||
      extractPointer(contextFields.get('prefab_cache'));
    const owner =
      extractPointer(contextFields.get('context_addr')) ||
      extractPointer(contextFields.get('context'));
    const placeContext =
      extractPointer(contextFields.get('place_context_addr')) ||
      extractPointer(contextFields.get('place_context'));
    if (!cacheOwner || (!owner && !placeContext)) {
      debugNativePrefab('file context incomplete', name, {
        cacheOwner,
        owner,
        placeContext,
        lines: contextLines.slice(0, 20),
      });
      Logger.warnp(
        'native prefab file context incomplete',
        `owner=${owner || '<missing>'}`,
        `placeContext=${placeContext || '<missing>'}`,
        `cache=${cacheOwner || '<missing>'}`,
      );
      return false;
    }

    const commandOwner = owner || '0';
    const nonce = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
    writeFileSync(
      NATIVE_PREFAB_COMMAND_PATH,
      [
        'spawn=1',
        'method=file_shared',
        `nonce=${nonce}`,
        `owner=${commandOwner}`,
        `cache_owner=${cacheOwner}`,
        placeContext ? `place_context=${placeContext}` : '',
        prefabHash ? `hash=${prefabHash}` : '',
        `prefab_path=${prefabPath}`,
        `orientation=${orientation}`,
        `absolute_x=${target[0]}`,
        `absolute_y=${target[1]}`,
        `absolute_z=${target[2]}`,
        '',
      ].filter(Boolean).join('\n'),
      'utf8',
    );

    let status = '';
    try {
      Logger.logp(
        'native prefab file seed queued',
        name,
        target.join(', '),
        nonce,
      );
      debugNativePrefab('file queued', name, {
        target,
        nonce,
        owner,
        commandOwner,
        placeContext,
        cacheOwner,
        path: prefabPath,
        hash: prefabHash,
      });

      for (let attempt = 0; attempt < 80; attempt++) {
        await sleep(100);
        try {
          status = readFileSync(NATIVE_PREFAB_STATUS_PATH, 'utf8');
        } catch (_error) {
          status = '';
        }
        if (status.includes(`nonce=${nonce}`)) break;
      }

      if (!status.includes(`nonce=${nonce}`)) {
        debugNativePrefab('file timeout', name, { nonce, status });
        Logger.warnp('native prefab file spawn status timeout', nonce);
        await this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn timed out before the native file hook responded.'),
        );
        return true;
      }

      const normalizedStatus = status.trim().replace(/\s+/g, ' ');
      if (status.includes('ok=1')) {
        debugNativePrefab('file shared accepted', name, normalizedStatus);
        Logger.logp('native prefab file shared accepted', normalizedStatus);
        void this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn accepted by native file hook.'),
        ).catch(error =>
          Logger.warnp('native prefab file shared success whisper failed', error),
        );
        return true;
      } else {
        debugNativePrefab('file failed', name, normalizedStatus);
        Logger.warnp('native prefab file seed failed', normalizedStatus);
        const error = getNativeStatusField(status, 'error');
        debugNativePrefab('file fallback hash', name, { error, status: normalizedStatus });
        Logger.warnp('native prefab file seed falling back to hash bridge', error);
        return false;
      }
    } finally {
      try {
        writeFileSync(
          NATIVE_PREFAB_COMMAND_PATH,
          ['spawn=0', `last_nonce=${nonce}`, ''].join('\n'),
          'utf8',
        );
      } catch (error) {
        debugNativePrefab('file reset failed', name, error);
        Logger.warnp('native prefab file command reset failed', error);
      }
    }
  }

  async tryNativePrefabHashSpawnCommand(
    name: string,
    kind: string,
    target: [number, number, number],
    options: {
      force?: boolean;
      hashOverride?: string;
      handledOnFailure?: boolean;
    } = {},
  ) {
    if (!options.force && process.env.OMEGGA_NATIVE_PREFAB_FORCE_LEGACY_HOOK === '1') {
      debugNativePrefab('hash skipped force legacy hook', name, {
        kind,
        target,
      });
      return false;
    }

    const definitions = readNativePrefabDefinitions();
    const definition = definitions[kind] || {};
    if (!definition) {
      debugNativePrefab('hash definition missing', name, kind);
      return false;
    }

    const hash = cleanHex(options.hashOverride || definition.hash);
    if (hash.length !== 64) {
      debugNativePrefab('hash definition invalid', name, {
        kind,
        hashOverride: Boolean(options.hashOverride),
        hashLength: hash.length,
      });
      Logger.warnp('native prefab hash definition invalid', kind);
      return false;
    }

    const orientation = Math.max(
      0,
      Math.min(255, Math.round(finiteOr(definition.orientation, 16))),
    );
    const pasteSeedHex = cleanHex(definition.pasteSeedHex);
    const parts = [
      'Omegga.Bridge.PasteAndPlacePrefabHash',
      hash,
      'grid',
      String(target[0]),
      String(target[1]),
      String(target[2]),
    ];

    if (!pasteSeedHex || definition.orientation != null) {
      parts.push(String(orientation));
    }
    if (!pasteSeedHex || definition.ownership != null) {
      parts.push(`ownership=${boolToken(definition.ownership, true)}`);
    }
    if (!pasteSeedHex || definition.temp != null) {
      parts.push(`temp=${boolToken(definition.temp, false)}`);
    }
    const targetOverride =
      definition.target != null && String(definition.target).trim() !== '';
    if (!pasteSeedHex) {
      parts.push(`target=${String(definition.target || '0')}`);
    } else if (targetOverride && String(definition.target).trim() !== '0') {
      parts.push(`target=${String(definition.target).trim()}`);
    }

    if (pasteSeedHex) {
      if (pasteSeedHex.length !== 0x40 * 2) {
        debugNativePrefab('paste seed invalid', name, {
          kind,
          length: pasteSeedHex.length,
        });
        Logger.warnp('native prefab paste seed length invalid', kind);
        return false;
      }
      parts.push(`pasteseed=hex:${pasteSeedHex}`);
    }

    let placeSeedHex = cleanHex(definition.placeSeedHex);
    if (placeSeedHex) {
      if (placeSeedHex.length !== 0xdf * 2) {
        debugNativePrefab('place seed invalid', name, {
          kind,
          length: placeSeedHex.length,
        });
        Logger.warnp('native prefab place seed length invalid; using default', kind);
        placeSeedHex = '';
      }
    }
    if (placeSeedHex) {
      parts.push(`placeseed=hex:${placeSeedHex}`);
    }

    if (definition.placeAdjust) {
      parts.push(`placeadjust=${String(definition.placeAdjust)}`);
    }
    if (definition.placeOnly != null) {
      parts.push(`placeonly=${boolToken(definition.placeOnly, false)}`);
    }

    const spec = parts.slice(1).join(' ');
    const combinedModeSetting = process.env.OMEGGA_NATIVE_PREFAB_COMBINED_PASTE_PLACE;
    const combinedPastePlace =
      combinedModeSetting === '1' ||
      (combinedModeSetting !== '0' && Boolean(pasteSeedHex));
    const requireNativeCommit =
      process.env.OMEGGA_NATIVE_PREFAB_REQUIRE_NATIVE_COMMIT === '1';
    const commitWaitMs = Math.max(
      0,
      Math.min(
        5000,
        Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_COMMIT_WAIT_MS, 1000)),
      ),
    );
    const command = combinedPastePlace
      ? `Omegga.Bridge.PasteAndPlacePrefabHash ${spec}`
      : `Omegga.Bridge.PastePrefabHash ${spec}`;
    const hookLogCursor = nativePrefabHookLogCursor();
    debugNativePrefab('hash queued', name, {
      kind,
      target,
      mode: combinedPastePlace ? 'combined' : 'split',
      command,
    });
    Logger.logp('native prefab hash spawn queued', name, target.join(', '));

    try {
      const output = await this.execControlCommandWithOutput(command, 15000);
      const lines = bridgeOutputLines(output);
      const fields = bridgeLineFields(lines);
      const ok = fields.get('ok') === 'true';
      debugNativePrefab(combinedPastePlace ? 'hash bridge output' : 'hash paste bridge output', name, {
        ok,
        lines: lines.slice(0, 30),
      });
      const detail =
        fields.get('paste_detail') ||
        fields.get('place_detail') ||
        fields.get('detail') ||
        lines[0] ||
        '';

      if (!ok) {
        debugNativePrefab(combinedPastePlace ? 'hash failed' : 'hash paste failed', name, {
          result: fields.get('result') || '',
          detail,
        });
        Logger.warnp(
          combinedPastePlace ? 'native prefab hash spawn failed' : 'native prefab hash paste failed',
          fields.get('result') || detail || '<no detail>',
        );
        const result = fields.get('result') || '';
        const message =
          result === 'no-place-context' && /after ServerPastePrefab/i.test(detail)
            ? 'Vehicle spawn reached native paste, but the prefab cache/placer context was not materialized server-side.'
            : result === 'no-place-context'
              ? 'Vehicle spawn failed: no valid prefab placer context is available.'
              : `Vehicle spawn failed${detail ? `: ${detail}` : ''}.`;
        await this.tryNativePrefabWhisper(name, quoteChatMessage(message));
        return (
          options.handledOnFailure ??
          process.env.OMEGGA_NATIVE_PREFAB_LEGACY_HOOK !== '1'
        );
      }

      if (combinedPastePlace) {
        if (requireNativeCommit) {
          if (commitWaitMs > 0) {
            await sleep(commitWaitMs);
          }
          const commitLines = nativePrefabCommitLines(
            readNativePrefabHookLogSince(hookLogCursor),
          );
          if (commitLines.length === 0) {
            debugNativePrefab('hash no native commit', name, {
              detail,
              waitMs: commitWaitMs,
            });
            Logger.warnp(
              'native prefab hash returned success but no native placement transaction followed',
              detail || '<no detail>',
            );
            return false;
          }
          debugNativePrefab('hash native commit observed', name, commitLines.slice(0, 8));
        }
        debugNativePrefab('hash accepted', name, detail);
        Logger.logp('native prefab hash spawn accepted', detail);
        void this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn accepted by prefab hash bridge.'),
        ).catch(error =>
          Logger.warnp('native prefab hash spawn success whisper failed', error),
        );
        return true;
      }

      debugNativePrefab('hash paste accepted', name, detail);
      const delayMs = Math.max(
        0,
        Math.min(
          5000,
          Math.round(finiteOr(process.env.OMEGGA_NATIVE_PREFAB_PASTE_PLACE_DELAY_MS, 750)),
        ),
      );
      if (delayMs > 0) {
        await sleep(delayMs);
      }

      const placeCommand = `Omegga.Bridge.PlaceCurrentPrefab ${spec}`;
      debugNativePrefab('hash place queued', name, {
        kind,
        target,
        delayMs,
        command: placeCommand,
      });

      const placeOutput = await this.execControlCommandWithOutput(placeCommand, 15000);
      const placeLines = bridgeOutputLines(placeOutput);
      const placeFields = bridgeLineFields(placeLines);
      const placeOk = placeFields.get('ok') === 'true';
      const placeDetail =
        placeFields.get('place_detail') ||
        placeFields.get('detail') ||
        placeLines[0] ||
        '';
      debugNativePrefab('hash place bridge output', name, {
        ok: placeOk,
        lines: placeLines.slice(0, 30),
      });

      if (placeOk) {
        if (requireNativeCommit) {
          if (commitWaitMs > 0) {
            await sleep(commitWaitMs);
          }
          const commitLines = nativePrefabCommitLines(
            readNativePrefabHookLogSince(hookLogCursor),
          );
          if (commitLines.length === 0) {
            debugNativePrefab('hash place no native commit', name, {
              detail: placeDetail,
              waitMs: commitWaitMs,
            });
            Logger.warnp(
              'native prefab hash place returned success but no native placement transaction followed',
              placeDetail || '<no detail>',
            );
            return false;
          }
          debugNativePrefab(
            'hash place native commit observed',
            name,
            commitLines.slice(0, 8),
          );
        }
        debugNativePrefab('hash accepted', name, placeDetail);
        Logger.logp('native prefab hash spawn accepted', placeDetail);
        void this.tryNativePrefabWhisper(
          name,
          quoteChatMessage('Vehicle spawn accepted by prefab hash bridge.'),
        ).catch(error =>
          Logger.warnp('native prefab hash spawn success whisper failed', error),
        );
        return true;
      }

      debugNativePrefab('hash place failed', name, {
        result: placeFields.get('result') || '',
        detail: placeDetail,
      });
      Logger.warnp(
        'native prefab hash place failed',
        placeFields.get('result') || placeDetail || '<no detail>',
      );
      const placeResult = placeFields.get('result') || '';
      const placeMessage =
        placeResult === 'no-place-context'
          ? 'Vehicle spawn failed: no valid prefab placer context is available.'
          : `Vehicle spawn failed${placeDetail ? `: ${placeDetail}` : ''}.`;
      await this.tryNativePrefabWhisper(name, quoteChatMessage(placeMessage));
      return (
        options.handledOnFailure ??
        process.env.OMEGGA_NATIVE_PREFAB_LEGACY_HOOK !== '1'
      );
    } catch (error) {
      debugNativePrefab('hash bridge error', name, error);
      Logger.warnp('native prefab hash spawn bridge failed', error);
      return false;
    }
  }

  async whisperName(name: string, message: string) {
    await this.writelnAsync(`Chat.Whisper "${name}" ${message}`);
  }

  async tryNativePrefabWhisper(name: string, message: string) {
    try {
      await this.writelnAsync(`Chat.Broadcast ${message}`);
    } catch (error) {
      debugNativePrefab('feedback broadcast failed', name, error);
      Logger.warnp('native prefab command feedback failed', error);
    }
  }

  /** attempt to save server state */
  async saveServer(config: AutoRestartConfig) {
    if (config.players && this.players.length > 0) {
      Logger.logp('Getting player positions...');
      const players = await this.getAllPlayerPositions();
      Logger.logp(`Saving ${players.length} player positions...`);
      const data = players
        .filter(p => !p.isDead && p.pos)
        .map(p => ({ position: p.pos, id: p.player.id }));
      if (players.length > 0)
        writeFileSync(
          join(this.path, DATA_PATH, 'omegga_temp_players.json'),
          JSON.stringify(data),
        );
    }

    if (config.saveWorld) {
      Logger.logp('Saving world...');
      await this.saveWorld();
    }
  }

  async restartServer() {
    if (this.starting || this.stopping) return;
    if (!this.started) return await this.start();

    const nextWorld = this.getNextWorld();
    if (nextWorld) {
      Logger.logp('Loading world', nextWorld.file.yellow);
      Logger.verbose('Next world configured from', nextWorld.source.yellow);
      this.loadWorld(nextWorld.file);
    } else {
      this.changeMap(this.currentMap);
    }

    const res = await Promise.race([
      // wait for the map to change
      new Promise(resolve =>
        this.once('mapchange', () => resolve('mapchange')),
      ),
      // Timeout after 10 seconds
      new Promise(resolve => setTimeout(() => resolve('timeout'), 10000)),
    ]);
    Logger.verbose('Restart result:', res);
  }

  /** attempt to restore the server's state */
  async restoreServer() {
    const tempPlayersFile = join(
      this.path,
      DATA_PATH,
      'omegga_temp_players.json',
    );
    if (!existsSync(tempPlayersFile)) return;

    try {
      Logger.logp('Loading previous player positions...');

      // player positions are an array to address multi-clienting
      const players: { position: number[]; id: string }[] = JSON.parse(
        readFileSync(tempPlayersFile).toString(),
      );

      // restore player position on join
      const callback = (player: OmeggaPlayer) => {
        const index = players.findIndex(p => p.id === player.id);
        if (index > -1) {
          const { position } = players[index];
          this.writeln(
            `Chat.Command /TP "${player.name}" ${position.join(' ')} 0`,
          );

          // remove the entry
          players[index] = players[players.length - 1];
          players.pop();
        }
      };
      this.on('join', callback);

      let timeout = setTimeout(() => {
        try {
          this.off('join', callback);
          if (existsSync(tempPlayersFile)) unlinkSync(tempPlayersFile);
        } catch (err) {
          Logger.error('Error removing omegga_temp_players.json', err);
        }
      }, 10000);
      this.once('changemap', () => {
        clearTimeout(timeout);
        this.off('join', callback);
      });
    } catch (err) {
      Logger.error('Error restoring previous server state', err);
    }
  }

  /**
   * start webserver, load plugins, start the brickadia server
   * this should not be called by a plugin
   */
  //
  async start(): Promise<any> {
    this.starting = true;
    if (this.webserver) await this.webserver.start();
    if (this.pluginLoader) {
      // scan for plugins
      Logger.verbose('Scanning for plugins');
      await this.pluginLoader.scan();

      // load the plugins
      Logger.verbose('Loading plugins');
      await this.pluginLoader.reload();
    }

    Logger.verbose('Starting Brickadia');
    await super.start();
    this.emit('server:starting');
  }

  /**
   * unload plugins and stop the server
   * this should not be called by a plugin
   */
  async stop() {
    if (!this.started && !this.starting) {
      Logger.verbose("Stop called while server wasn't started or was starting");
      return;
    }

    if (this.stopping) {
      Logger.verbose('Stop called while server was starting');
      return;
    }

    this.stopping = true;
    this.emit('server:stopping');
    if (this.pluginLoader) {
      Logger.verbose('Unloading plugins');
      await this.pluginLoader.unload();
    }
    Logger.verbose('Stopping server');
    super.stop();

    const res = await Promise.race([
      new Promise(resolve => this.once('exit', () => resolve('exit'))),
      // Timeout after 10 seconds
      new Promise(resolve => setTimeout(() => resolve('timeout'), 10000)),
    ]);

    Logger.verbose('Stop result:', res);
    if (this.stopping) this.emit('server:stopped');
    this.stopping = false;
    this.started = false;
    this.starting = false;
    this._startedAtMs = 0;
    this._playerJoinedAt.clear();
    this.players = [];
  }

  /**
   * Copies auth files from home config dir
   * this should never be called by a plugin
   */
  copyAuthFiles() {
    const authDir = this.config.server.authDir ?? CONFIG_AUTH_DIR;
    const savedDir = this.config.server.savedDir ?? CONFIG_SAVED_DIR;
    const authPath = join(this.path, DATA_PATH, savedDir, authDir);
    const homeAuthPath = join(
      CONFIG_HOME,
      savedDir !== CONFIG_SAVED_DIR ? savedDir : '',
      authDir,
    );

    copyFiles(homeAuthPath, authPath, BRICKADIA_AUTH_FILES);
  }

  // TODO: split messages that longer than 512 characters
  // TODO: delete characters that are known to crash the game
  async broadcast(...messages: string[]) {
    for (const message of messages
      .flatMap(m => m.toString().split('\n'))
      .filter(m => m.length < 512)) {
      await this.writelnAsync(`Chat.Broadcast ${message}`);
    }
  }

  async whisper(target: string | OmeggaPlayer, ...messages: string[]) {
    const targetName =
      typeof target === 'object'
        ? target?.name
        : this.getPlayer(target)?.name ?? target;

    if (!targetName) {
      Logger.warnp('skipping whisper to unresolved player');
      return;
    }

    // whisper the messages to that player
    for (const message of messages
      .flatMap(m => m.toString().split('\n'))
      .filter(m => m.length < 512)) {
      try {
        await this.writelnAsync(`Chat.Whisper "${targetName}" ${message}`);
      } catch (error) {
        Logger.warnp(
          'whisper failed; broadcasting message instead',
          error instanceof Error ? error.message : String(error),
        );
        try {
          await this.writelnAsync(`Chat.Broadcast ${message}`);
        } catch (broadcastError) {
          Logger.warnp(
            'broadcast fallback failed',
            broadcastError instanceof Error
              ? broadcastError.message
              : String(broadcastError),
          );
        }
      }
    }
  }

  async middlePrint(target: string | OmeggaPlayer, message: string) {
    const targetName =
      typeof target === 'object'
        ? target?.name
        : this.getPlayer(target)?.name ?? target;

    if (!targetName) {
      Logger.warnp('skipping status message to unresolved player');
      return;
    }

    // whisper the messages to that player
    if (message.length > 512) return;
    try {
      await this.writelnAsync(`Chat.StatusMessage "${targetName}" ${message}`);
    } catch (error) {
      Logger.warnp(
        'status message failed; falling back to whisper',
        error instanceof Error ? error.message : String(error),
      );
      await this.whisper(targetName, message);
    }
  }

  getPlayers(): {
    id: string;
    name: string;
    displayName: string;
    controller: string;
    state: string;
  }[] {
    return this.players.map(p => ({ ...p }));
  }

  getRoleSetup(): BRRoleSetup {
    // Read RoleSetup2, fallback to old RoleSetup if it doesn't exist
    return (readWatchedJSON(join(this.configPath, 'RoleSetup2.json')) ??
      readWatchedJSON(join(this.configPath, 'RoleSetup.json'))) as BRRoleSetup;
  }

  getRoleAssignments(): BRRoleAssignments {
    return readWatchedJSON(
      join(this.configPath, 'RoleAssignments.json'),
    ) as BRRoleAssignments;
  }

  getBanList(): BRBanList {
    return readWatchedJSON(join(this.configPath, 'BanList.json')) as BRBanList;
  }

  getNameCache(): BRPlayerNameCache {
    return readWatchedJSON(
      join(this.configPath, 'PlayerNameCache.json'),
    ) as BRPlayerNameCache;
  }

  getPlayer(target: string): OmeggaPlayer {
    return this.players.find(
      p =>
        p.name === target ||
        p.id === target ||
        p.controller === target ||
        p.state === target,
    );
  }

  findPlayerByName(name: string): OmeggaPlayer {
    name = name.toLowerCase();
    const exploded = pattern.explode(name);
    return (
      this.players.find(p => p.name === name || p.displayName === name) || // find by exact match
      this.players.find(
        p => p.name.indexOf(name) > -1 || p.displayName.indexOf(name) > -1,
      ) || // find by rough match
      this.players.find(
        p => p.name.match(exploded) || p.displayName.match(exploded),
      ) // find by exploded regex match (ck finds cake, tbp finds TheBlackParrot)
    );
  }

  getHostId(): string {
    return this.host?.id ?? '';
  }

  saveMinigame(index: number, name: string) {
    this.writeln(`Server.Minigames.SavePreset ${index} "${name}"`);
  }

  deleteMinigame(index: number) {
    this.writeln(`Server.Minigames.Delete ${index}`);
  }

  resetMinigame(index: number) {
    this.writeln(`Server.Minigames.Reset ${index}`);
  }

  nextRoundMinigame(index: number) {
    this.writeln(`Server.Minigames.NextRound ${index}`);
  }

  loadMinigame(presetName: string, owner = '') {
    this.writeln(
      `Server.Minigames.LoadPreset "${presetName}" ${owner ? `"${owner}"` : ''}`,
    );
  }

  getMinigamePresets(): string[] {
    const presetPath = join(this.presetPath, 'Minigame');
    return existsSync(presetPath)
      ? glob
          .sync(presetPath + '/**/*.bp')
          .map(f => basename(f).replace(/\.bp$/, ''))
      : [];
  }

  resetEnvironment() {
    this.writeln(`Server.Environment.Reset`);
  }

  async saveEnvironment(presetName: string): Promise<void> {
    await this.addWatcher(/Environment preset saved.$/, {
      // request the pawn for this player's controller (should only be one)
      exec: () => this.writeln(`Server.Environment.SavePreset "${presetName}"`),
      timeoutDelay: 100,
    });
  }

  async getEnvironmentData(): Promise<EnvironmentPreset> {
    const saveName =
      this._tempSavePrefix + Date.now() + '_' + this._tempCounter.environment++;

    await this.saveEnvironment(saveName);
    const data = this.readEnvironmentData(saveName);
    const file = join(this.presetPath, 'Environment', saveName + '.bp');
    if (existsSync(file)) unlinkSync(file);

    return data;
  }

  readEnvironmentData(saveName: string): EnvironmentPreset {
    if (typeof saveName !== 'string')
      throw 'expected name argument for readEnvironmentData';

    const file = join(this.presetPath, 'Environment', saveName + '.bp');
    try {
      if (existsSync(file)) return JSON.parse(readFileSync(file).toString());
    } catch (err) {
      Logger.verbose('Error parsing save data in readEnvironmentData', err);
    }
    return null;
  }

  async loadEnvironment(presetName: string): Promise<void> {
    await this.writelnAsync(`Server.Environment.LoadPreset ${presetName}`);
  }

  async loadEnvironmentData(
    preset: EnvironmentPreset | EnvironmentPreset['data']['groups'],
  ): Promise<void> {
    if ('data' in preset) preset = preset.data.groups;

    const saveFile =
      this._tempSavePrefix + Date.now() + '_' + this._tempCounter.environment++;

    const path = join(this.presetPath, 'Environment', saveFile + '.bp');

    writeFileSync(
      path,
      JSON.stringify({
        formatVersion: '1',
        presetVersion: '1',
        type: 'Environment',
        data: {
          groups: {
            ...preset,
          },
        },
      }),
    );

    await this.loadEnvironment(saveFile);

    // this is lazy, but environments should load much faster than builds
    // do, so it's not really worth keeping track of logs for this
    setTimeout(() => {
      try {
        if (existsSync(path)) unlinkSync(path);
      } catch (err) {
        Logger.verbose('Failed to remove temporary environment preset', path, err);
      }
    }, 5000);
  }

  getEnvironmentPresets(): string[] {
    const presetPath = join(this.presetPath, 'Environment');
    return existsSync(presetPath)
      ? glob
          .sync(presetPath + '/**/*.bp')
          .map(f => basename(f).replace(/\.bp$/, ''))
      : [];
  }

  clearBricks(target: string | { id: string }, quiet = false) {
    // target is a player object, just use that id
    if (typeof target === 'object' && target.id) target = target.id;
    // if the target isn't a uuid already, find the player by name or controller and use that uuid
    else if (typeof target === 'string' && !uuid.match(target)) {
      // only set the target if the player exists
      const player = this.getPlayer(target);
      target = player && player.id;
    }

    if (!target) return;

    this.writeln(`Bricks.Clear ${target} ${quiet ? 1 : ''}`);
  }

  clearRegion(
    region: {
      center: [number, number, number];
      extent: [number, number, number];
    },
    options?: { target: string | OmeggaPlayer },
  ) {
    let target = '';

    // target is a player object, just use that id
    if (options && typeof options.target === 'object')
      target = ' ' + options.target.id;
    // if the target isn't a uuid already, find the player by name or controller and use that uuid

    if (typeof target === 'string' && !uuid.match(target)) {
      // only set the target if the player exists
      const player = this.getPlayer(target);
      if (player) target = ' ' + player.id;
    }

    this.writeln(
      `Bricks.ClearRegion ${region.center.join(' ')} ${region.extent.join(
        ' ',
      )}${target}`,
    );
  }

  clearAllBricks(quiet = false) {
    this.writeln(`Bricks.ClearAll ${quiet ? 1 : ''}`);
  }

  saveBricks(
    saveName: string,
    region?: {
      center: [number, number, number];
      extent: [number, number, number];
    },
  ) {
    if (!saveName) return;

    // add quotes around the filename if it doesn't have them (backwards compat w/ plugins)
    if (!(saveName.startsWith('"') && saveName.endsWith('"')))
      saveName = `"${saveName}"`;

    if (region?.center && region?.extent)
      this.writeln(
        `Bricks.SaveRegion ${saveName} ${region.center.join(
          ' ',
        )} ${region.extent.join(' ')}`,
      );
    else this.writeln(`Bricks.Save ${saveName}`);
  }

  async saveBricksAsync(
    saveName: string,
    region?: {
      center: [number, number, number];
      extent: [number, number, number];
    },
  ): Promise<void> {
    if (!saveName) return;

    let saveNameClean = saveName;
    // add quotes around the filename if it doesn't have them (backwards compat w/ plugins)
    if (!(saveName.startsWith('"') && saveName.endsWith('"')))
      saveNameClean = `"${saveName}"`;

    const command =
      region?.center && region?.extent
        ? `Bricks.SaveRegion ${saveNameClean} ${region.center.join(
            ' ',
          )} ${region.extent.join(' ')}`
        : `Bricks.Save ${saveNameClean}`;

    // wait for the server to save the file
    await this.watchLogChunk(command, /^(LogBrickSerializer|LogTemp): (.+)$/, {
      first: match => match[0].endsWith(saveName + '.brs...'),
      last: match =>
        Boolean(
          match[2].match(
            /Saved .+ bricks and .+ components from .+ owners|Error: No bricks in grid!|Error: No bricks selected to save!/,
          ),
        ),
      afterMatchDelay: 0,
      timeoutDelay: 30000,
    });
  }

  loadBricks(
    saveName: string,
    {
      offX = 0,
      offY = 0,
      offZ = 0,
      quiet = false,
      correctPalette = false,
      correctCustom = false,
    } = {},
  ) {
    // add quotes around the filename if it doesn't have them (backwards compat w/ plugins)
    if (!(saveName.startsWith('"') && saveName.endsWith('"')))
      saveName = `"${saveName}"`;

    this.writeln(
      `Bricks.Load ${saveName} ${offX} ${offY} ${offZ} ${quiet ? 1 : 0} ${
        correctPalette ? 1 : 0
      } ${correctCustom ? 1 : 0}`,
    );
  }

  loadBricksOnPlayer(
    saveName: string,
    player: string | OmeggaPlayer,
    {
      offX = 0,
      offY = 0,
      offZ = 0,
      correctPalette = false,
      correctCustom = false,
    } = {},
  ) {
    player = typeof player === 'string' ? this.getPlayer(player) : player;
    if (!player) return;

    // add quotes around the filename if it doesn't have them (backwards compat w/ plugins)
    if (!(saveName.startsWith('"') && saveName.endsWith('"')))
      saveName = `"${saveName}"`;

    this.writeln(
      `Bricks.LoadTemplate ${saveName} ${offX} ${offY} ${offZ}  ${
        correctPalette ? 1 : 0
      } ${correctCustom ? 1 : 0} "${player.name}"`,
    );
  }

  getSaves(): string[] {
    return existsSync(this.savePath)
      ? glob.sync(this.savePath + '/**/*.brs')
      : [];
  }

  getWorlds(): string[] {
    return existsSync(this.worldPath)
      ? glob.sync(this.worldPath + '/**/*.brdb')
      : [];
  }

  getSavePath(saveName: string) {
    const file = join(
      this.savePath,
      saveName.endsWith('.brs') ? saveName : saveName + '.brs',
    );
    return existsSync(file) ? file : undefined;
  }

  getWorldPath(worldName: string) {
    const file = join(
      this.worldPath,
      worldName.endsWith('.brdb') ? worldName : worldName + '.brdb',
    );
    return existsSync(file) ? file : undefined;
  }

  async getWorldRevisions(worldName: string) {
    if (!this.started || this.starting || this.stopping) {
      throw new Error('Server is not started');
    }

    worldName = worldName.replace(/\.brdb$/i, '');

    if (!worldName || !this.getWorldPath(worldName)) {
      throw new Error(`World "${worldName}" does not exist`);
    }

    /*
      LogBRBundleManager: There are 2 revisions
      LogBRBundleManager: Revision 1 - 2001.02.03-04.05.06: Initial Revision
      LogBRBundleManager: Revision 2 - 2001.02.03-04.05.06: Manual Save
    */
    let numRevisions = 0;
    const revisionsRaw = await this.watchLogChunk<RegExpMatchArray>(
      `BR.World.ListRevisions "${worldName}"`,
      /^LogBRBundleManager: (There are (?<numRevisions>\d+) revisions|Revision (?<revision>\d+) - (?<date>[\d.-]+): (?<note>.+))$/,
      {
        last: match => Number(match.groups.reverse) === numRevisions,
        first: match => {
          if (match.groups?.numRevisions !== undefined) {
            numRevisions = Number(match.groups.numRevisions);
            return true;
          }
          return false;
        },
      },
    );

    if (!revisionsRaw) return [];
    return revisionsRaw
      .map(match => {
        if (match.groups?.numRevisions !== undefined) {
          return null;
        }

        const revision = match.groups.revision
          ? Number(match.groups.revision)
          : 0;
        // parse date from YYYY.MM.DD-HH.MM.SS to YYYY-MM-DDTHH:MM:SSZ
        const dateStr = match.groups.date.replace(
          /(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2})/,
          '$1-$2-$3T$4:$5:$6Z',
        );
        const date = new Date(dateStr);
        const note = match.groups.note || '';
        return { index: revision, date, note };
      })
      .filter(Boolean);
  }

  async loadWorld(worldName: string): Promise<boolean> {
    worldName = worldName.replace(/\.brdb$/i, '');
    if (!worldName || !this.getWorldPath(worldName)) return false;
    this.writeln(`BR.World.Load "${worldName}"`);
    const res = await Promise.race([
      // wait for the map to change
      new Promise(resolve =>
        this.once('mapchange', () => resolve('mapchange')),
      ),
      // Timeout after 10 seconds
      new Promise(resolve => setTimeout(() => resolve('timeout'), 10000)),
    ]);
    Logger.verbose('LoadWorld', worldName, 'result:', res);
    return res === 'mapchange';
  }

  async loadWorldRevision(
    worldName: string,
    revision: number,
  ): Promise<boolean> {
    worldName = worldName.replace(/\.brdb$/i, '');
    if (!worldName || !this.getWorldPath(worldName)) return false;
    if (typeof revision !== 'number' || revision < 1) {
      throw new Error(`Invalid revision number: ${revision}`);
    }
    this.writeln(`BR.World.LoadRevision "${worldName}" ${revision}`);
    const res = await Promise.race([
      // wait for the map to change
      new Promise(resolve =>
        this.once('mapchange', () => resolve('mapchange')),
      ),
      // Timeout after 10 seconds
      new Promise(resolve => setTimeout(() => resolve('timeout'), 10000)),
    ]);
    Logger.verbose('LoadWorld', worldName, 'result:', res);
    return res === 'mapchange';
  }

  async loadWorldAdditive(
    worldName: string,
    x = 0,
    y = 0,
    z = 0,
    orientation = 0,
  ): Promise<boolean> {
    worldName = sanitizeWorldBundleName(worldName, '');
    if (!worldName || !this.getWorldPath(worldName)) return false;

    const target = [x, y, z].map(value => Math.round(finiteOr(value, 0)));
    const rotation = Math.round(finiteOr(orientation, 0));
    this.writeln(
      `BR.World.LoadAdditive ${worldName} ${target[0]} ${target[1]} ${target[2]} ${rotation}`,
    );
    Logger.verbose(
      'LoadWorldAdditive',
      worldName,
      'at',
      target.join(' '),
      'orientation',
      rotation,
    );
    return true;
  }

  async saveWorldAs(worldName: string) {
    if (!worldName) return false;
    if (this.stopping || this.starting || !this.started) return false;

    if (this.getWorldPath(worldName)) {
      return false;
    }
    worldName = worldName.replace(/\.brdb$/i, '');

    try {
      const match = await this.addWatcher<{ res: boolean }>(
        (_line, match) => {
          if (match?.groups?.generator !== 'LogBRWorldManager') return;

          const ok = match.groups.data.match(/^World files saved after /);
          const err =
            !match.groups.data.startsWith(
              'Error: Failed to capture minigame settings',
            ) &&
            match.groups.data.match(
              /^Error: (World already exists|Failed to create new world)?/,
            );
          return ok ? { res: true } : err ? { res: false } : undefined;
        },
        {
          exec: () => {
            this.writeln(`BR.World.SaveAs "${worldName}"`);
          },
          timeoutDelay: Math.round(
            finiteOr(process.env.OMEGGA_WORLD_SAVE_TIMEOUT_MS, 10000),
          ),
        },
      );
      return match?.[0]?.['res'] ?? false;
    } catch (err) {
      return false;
    }
  }

  async saveWorld(): Promise<boolean> {
    // Don't allow saving while the server is starting or stopping
    if (this.stopping || this.starting || !this.started) return false;

    try {
      const match = await this.addWatcher<{ res: boolean }>(
        (_line, match) => {
          if (match?.groups?.generator !== 'LogBRWorldManager') return;

          const ok = match.groups.data.match(/^World files saved after /);
          const err =
            !match.groups.data.startsWith(
              'Error: Failed to capture minigame settings',
            ) &&
            match.groups.data.match(/^Error: (World has not been saved\.)?/);
          return ok ? { res: true } : err ? { res: false } : undefined;
        },
        {
          exec: () => {
            this.writeln(`BR.World.Save 0`);
          },
          timeoutDelay: 2000,
        },
      );
      return match?.[0]?.['res'] ?? false;
    } catch (err) {
      return false;
    }
  }

  async createEmptyWorld(
    worldName: string,
    map: 'Plate' | 'Space' | 'Studio' | 'Peaks' = 'Plate',
  ): Promise<boolean> {
    if (!worldName) return;
    worldName = worldName.replace(/\.brdb$/i, '');

    try {
      const match = await this.addWatcher<{ res: boolean }>(
        (_line, match) => {
          if (match?.groups?.generator !== 'LogBRWorldManager') return;

          const ok = match.groups.data.match(/^World files saved after /);
          const err = match.groups.data.match(
            /^Error: (Invalid preset|World already exists|Failed to create new world)?/,
          );
          return ok ? { res: true } : err ? { res: false } : undefined;
        },
        {
          exec: () => {
            this.writeln(`BR.World.CreateEmpty "${worldName}" ${map}`);
          },
          timeoutDelay: 2000,
        },
      );
      return match?.[0]?.['res'] ?? false;
    } catch (err) {
      return false;
    }
  }

  writeSaveData(saveName: string, saveData: WriteSaveObject) {
    if (typeof saveName !== 'string')
      throw 'expected name argument for writeSaveData';

    const file = join(this.savePath, saveName + '.brs');
    if (!file.startsWith(this.savePath))
      throw 'save file not in Saved/Builds directory';
    writeFileSync(file, new Uint8Array(brs.write(saveData)));
  }

  readSaveData(saveName: string, nobricks = false): ReadSaveObject {
    if (typeof saveName !== 'string')
      throw 'expected name argument for readSaveData';

    const file = this.getSavePath(saveName);
    if (!file || !file.startsWith(this.savePath))
      throw 'save file not in Saved/Builds directory';
    if (file)
      return brs.read(readFileSync(file), {
        preview: false,
        bricks: !nobricks,
      });
  }

  async loadSaveData(
    saveData: WriteSaveObject,
    {
      offX = 0,
      offY = 0,
      offZ = 0,
      quiet = false,
      correctPalette = false,
      correctCustom = false,
    } = {},
  ) {
    const saveFile =
      this._tempSavePrefix + Date.now() + '_' + this._tempCounter.save++;
    // write savedata to file
    this.writeSaveData(saveFile, saveData);

    // wait for the server to finish reading the save
    await this.watchLogChunk(
      `Bricks.Load "${saveFile}" ${offX} ${offY} ${offZ} ${quiet ? 1 : 0} ${
        correctPalette ? 1 : 0
      } ${correctCustom ? 1 : 0}`,
      /^LogBrickSerializer: (.+)$/,
      {
        first: match => match[0].endsWith(saveFile + '.brs...'),
        last: match => Boolean(match[1].match(/Read .+ bricks/)),
        afterMatchDelay: 0,
        timeoutDelay: 30000,
      },
    );

    // delete the save file after we're done
    const savePath = this.getSavePath(saveFile);
    if (savePath) {
      unlinkSync(savePath);
    }
  }

  async loadSaveDataOnPlayer(
    saveData: WriteSaveObject,
    player: string | OmeggaPlayer,
    {
      offX = 0,
      offY = 0,
      offZ = 0,
      correctPalette = false,
      correctCustom = false,
    } = {},
  ) {
    player = typeof player === 'string' ? this.getPlayer(player) : player;
    if (!player) return;

    const saveFile =
      this._tempSavePrefix + Date.now() + '_' + this._tempCounter.save++;
    // write savedata to file
    this.writeSaveData(saveFile, saveData);

    // wait for the server to finish reading the save
    await this.watchLogChunk(
      `Bricks.LoadTemplate "${saveFile}" ${offX} ${offY} ${offZ} ${
        correctPalette ? 1 : 0
      } ${correctCustom ? 1 : 0} "${player.name}"`,
      /^LogBrickSerializer: (.+)$/,
      {
        first: match => match[0].endsWith(saveFile + '.brs...'),
        last: match => Boolean(match[1].match(/Read .+ bricks/)),
        afterMatchDelay: 0,
        timeoutDelay: 30000,
      },
    );

    // delete the save file after we're done
    const savePath = this.getSavePath(saveFile);
    if (savePath) {
      unlinkSync(savePath);
    }
  }

  async getSaveData(region?: {
    center: [number, number, number];
    extent: [number, number, number];
  }) {
    const saveFile =
      this._tempSavePrefix + Date.now() + '_' + this._tempCounter.save++;

    await this.saveBricksAsync(saveFile, region);

    // read the save file
    const savePath = this.getSavePath(saveFile);
    if (savePath) {
      // read and parse the save file
      const saveData = brs.read(readFileSync(savePath));

      // delete the save file after we're done reading it
      unlinkSync(savePath);

      // return the parsed save
      return saveData;
    }

    return undefined;
  }

  // TODO: switch this to use worlds...
  async changeMap(map: string) {
    if (!map) return;

    // ServerTravel requires /Game/Maps/Plate/Plate instead of Plate
    const brName = mapUtils.n2brn(map);

    // wait for the server to change maps
    const match = await this.addWatcher(
      /^.*(LogLoad: Took .+ seconds to LoadMap\((?<map>.+)\))|(ERROR: The map .+)$/,
      {
        timeoutDelay: 30000,
        exec: () => this.writeln(`ServerTravel ${brName}`),
      },
    );
    const success = !!(
      match &&
      match[0] &&
      match[0].groups &&
      match[0].groups.map
    );
    return success;
  }

  async getPlugin(name: string): Promise<PluginInterop> {
    const plugin = this.pluginLoader.plugins.find(p => p.getName() === name);

    if (plugin) {
      return {
        name,
        documentation: plugin.getDocumentation(),
        loaded: plugin.isLoaded(),
        emitPlugin: (event: string, ...args: any[]) => {
          return plugin.emitPlugin(event, 'unsafe', args);
        },
      };
    } else {
      return null;
    }
  }
}
