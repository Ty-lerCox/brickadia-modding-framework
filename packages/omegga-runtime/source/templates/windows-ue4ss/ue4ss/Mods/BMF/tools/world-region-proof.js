#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const LOOKUP_ID_PATTERN = '[a-z0-9_-]{1,64}';
const LOOKUP_PURPOSE_PATTERN = '[a-z0-9_.-]{1,64}';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LEGACY_TREE_TAG_RE = /^chop([a-z]*)tree$/i;

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = argv[index + 1];
    if (next === undefined || next.startsWith('--')) {
      args[key] = 'true';
      continue;
    }
    args[key] = next;
    index += 1;
  }
  return args;
}

function out(fields) {
  for (const [key, rawValue] of Object.entries(fields)) {
    const value = rawValue === undefined || rawValue === null ? '' : String(rawValue);
    process.stdout.write(`${key}=${value.replace(/[\r\n]+/g, ' ')}\n`);
  }
}

function fail(code, detail, extra = {}) {
  out({
    ok: false,
    code,
    detail,
    source: 'BMFWorldRegionProof',
    operation: 'world-scan-region',
    coordinate_space: 'world',
    clear_region_safe: false,
    exact_target_only: false,
    ...extra,
  });
  process.exitCode = 1;
}

function normalizeSegment(value) {
  return String(value || '').trim().toLowerCase();
}

function formatLookupConsoleTag(id, purpose) {
  return `lookup:${normalizeSegment(id)}:${normalizeSegment(purpose)}`;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function findLookupConsoleTag(value, purpose, legacyPrefixes = [], seen = new WeakSet(), depth = 0) {
  if (depth > 12) return undefined;
  if (Array.isArray(value)) {
    for (const item of value) {
      const tag = findLookupConsoleTag(item, purpose, legacyPrefixes, seen, depth + 1);
      if (tag) return tag;
    }
    return undefined;
  }
  if (value && typeof value === 'object') {
    if (seen.has(value)) return undefined;
    seen.add(value);
    for (const item of Object.values(value)) {
      const tag = findLookupConsoleTag(item, purpose, legacyPrefixes, seen, depth + 1);
      if (tag) return tag;
    }
    return undefined;
  }

  const text = String(value ?? '').trim();
  if (!text) return undefined;
  const expectedPurpose = normalizeSegment(purpose);
  const lookupMatch = text.match(
    new RegExp(
      `(?:^|[^a-z0-9_-])lookup:(${LOOKUP_ID_PATTERN}):(${LOOKUP_PURPOSE_PATTERN})(?:$|[^a-z0-9_.-])`,
      'i'
    )
  );
  if (lookupMatch && normalizeSegment(lookupMatch[2]) === expectedPurpose) {
    return formatLookupConsoleTag(lookupMatch[1], expectedPurpose);
  }

  const prefixes = legacyPrefixes.map(prefix => normalizeSegment(prefix).replace(/:$/, '')).filter(Boolean);
  if (prefixes.length > 0) {
    const legacyMatch = text.match(
      new RegExp(
        `(?:^|[^a-z0-9_-])(?:${prefixes.map(escapeRegExp).join('|')}):(${LOOKUP_ID_PATTERN})(?:$|[^a-z0-9_-])`,
        'i'
      )
    );
    if (legacyMatch) return formatLookupConsoleTag(legacyMatch[1], expectedPurpose);
  }

  if (UUID_RE.test(text)) return formatLookupConsoleTag(text, expectedPurpose);
  return undefined;
}

function findLegacyTreeTag(value, seen = new WeakSet(), depth = 0) {
  if (depth > 12) return undefined;
  if (Array.isArray(value)) {
    for (const item of value) {
      const tag = findLegacyTreeTag(item, seen, depth + 1);
      if (tag) return tag;
    }
    return undefined;
  }
  if (value && typeof value === 'object') {
    if (seen.has(value)) return undefined;
    seen.add(value);
    for (const item of Object.values(value)) {
      const tag = findLegacyTreeTag(item, seen, depth + 1);
      if (tag) return tag;
    }
    return undefined;
  }

  const text = String(value ?? '').trim();
  if (!text) return undefined;
  const match = text.match(LEGACY_TREE_TAG_RE);
  if (!match) return undefined;
  return `chop${String(match[1] || '').toLowerCase()}tree`;
}

function extractPosition(brick) {
  const value = brick && typeof brick === 'object' ? brick.position : undefined;
  if (Array.isArray(value) && value.length >= 3) {
    const position = value.slice(0, 3).map(Number);
    return position.every(Number.isFinite) ? position : undefined;
  }
  if (value && typeof value === 'object') {
    const position = [Number(value.x), Number(value.y), Number(value.z)];
    return position.every(Number.isFinite) ? position : undefined;
  }
  return undefined;
}

function makeLegacyTreeAnchorKey(tag, position) {
  const normalizedTag = String(tag || '').trim().toLowerCase().replace(/[^a-z0-9_-]/g, '-');
  const [x, y, z] = position.map(value => Math.round(value));
  return `legacy-tree:${normalizedTag}:${x},${y},${z}`;
}

function brickTreeKey(brick) {
  if (!brick || typeof brick !== 'object') return undefined;
  const explicit =
    findLookupConsoleTag(brick.components, 'treecut', ['treeid', 'choptree']) ||
    findLookupConsoleTag(brick.ConsoleTag, 'treecut', ['treeid', 'choptree']) ||
    findLookupConsoleTag(brick.consoleTag, 'treecut', ['treeid', 'choptree']);
  if (explicit) return explicit;

  const legacy =
    findLegacyTreeTag(brick.components) ||
    findLegacyTreeTag(brick.ConsoleTag) ||
    findLegacyTreeTag(brick.consoleTag);
  const position = extractPosition(brick);
  return legacy && position ? makeLegacyTreeAnchorKey(legacy, position) : undefined;
}

function loadBrs() {
  const candidates = [];
  const explicitPath = process.env.BMF_BRS_JS_PATH;
  if (explicitPath) candidates.push(explicitPath);

  const moduleDirs = [];
  if (process.env.BMF_BRS_JS_MODULE_DIR) moduleDirs.push(process.env.BMF_BRS_JS_MODULE_DIR);
  if (process.env.NODE_PATH) moduleDirs.push(...process.env.NODE_PATH.split(path.delimiter));
  for (const dir of moduleDirs.filter(Boolean)) {
    candidates.push(path.join(dir, 'brs-js'));
  }
  candidates.push('brs-js');

  const errors = [];
  for (const candidate of candidates) {
    try {
      const mod = require(candidate);
      if (mod && typeof mod.read === 'function') return mod;
      if (mod && mod.default && typeof mod.default.read === 'function') return mod.default;
      errors.push(`${candidate}: missing read()`);
    } catch (error) {
      errors.push(`${candidate}: ${error.message}`);
    }
  }
  throw new Error(`unable to load brs-js; tried ${errors.join('; ')}`);
}

function insideDirectory(filePath, directory) {
  if (!directory) return true;
  const resolvedFile = path.resolve(filePath);
  const resolvedDir = path.resolve(directory);
  return resolvedFile === resolvedDir || resolvedFile.startsWith(resolvedDir + path.sep);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const savePath = args.save ? path.resolve(args.save) : '';
  const expectedKey = normalizeSegment(args['expected-key'] || args.expectedKey || args.key);
  const buildsDir = args['builds-dir'] || args.buildsDir || '';
  const center = [args.x, args.y, args.z].map(Number);
  const extent = [args.ex, args.ey, args.ez].map(Number);

  if (!savePath) {
    fail('WORLD_REGION_SAVE_PATH_REQUIRED', 'save path is required');
    return;
  }
  if (!expectedKey) {
    fail('WORLD_REGION_EXPECTED_KEY_REQUIRED', 'expected tree key is required', { save_path: savePath });
    return;
  }
  if (!insideDirectory(savePath, buildsDir)) {
    fail('WORLD_REGION_SAVE_PATH_OUTSIDE_BUILDS_DIR', 'save path is outside the configured Builds directory', {
      save_path: savePath,
      builds_dir: buildsDir,
      expected_key: expectedKey,
    });
    return;
  }
  if (!fs.existsSync(savePath)) {
    fail('WORLD_REGION_SAVE_FILE_MISSING', 'saved region file was not found', {
      save_path: savePath,
      expected_key: expectedKey,
    });
    return;
  }

  let save;
  try {
    const brs = loadBrs();
    save = brs.read(fs.readFileSync(savePath));
  } catch (error) {
    fail('WORLD_REGION_BRS_PARSE_FAILED', error.message || String(error), {
      save_path: savePath,
      expected_key: expectedKey,
    });
    return;
  }

  const bricks = Array.isArray(save && save.bricks) ? save.bricks : [];
  const observedKeys = new Set();
  let targetBricks = 0;
  let untaggedBricks = 0;
  for (const brick of bricks) {
    const key = brickTreeKey(brick);
    if (!key) {
      untaggedBricks += 1;
      continue;
    }
    observedKeys.add(key);
    if (key === expectedKey) targetBricks += 1;
  }

  const observed = Array.from(observedKeys).sort();
  const exact =
    bricks.length > 0 &&
    untaggedBricks === 0 &&
    observed.length === 1 &&
    observed[0] === expectedKey &&
    targetBricks === bricks.length;
  const code = exact
    ? 'OK'
    : bricks.length === 0
      ? 'WORLD_REGION_EMPTY'
      : untaggedBricks > 0
        ? 'WORLD_REGION_UNTAGGED_BRICKS'
        : 'WORLD_REGION_TARGET_MISMATCH';

  out({
    ok: exact,
    code,
    detail: exact ? 'world-space region contains exactly the expected tree key' : 'world-space region is not exact',
    source: 'BMFWorldRegionProof',
    operation: 'world-scan-region',
    coordinate_space: 'world',
    world_space_clear_region_safe: exact,
    clear_region_safe: exact,
    exact_target_only: exact,
    expected_key: expectedKey,
    observed_keys: observed.join('|'),
    scanned_bricks: bricks.length,
    target_bricks: targetBricks,
    untagged_bricks: untaggedBricks,
    center_x: Number.isFinite(center[0]) ? center[0] : '',
    center_y: Number.isFinite(center[1]) ? center[1] : '',
    center_z: Number.isFinite(center[2]) ? center[2] : '',
    extent_x: Number.isFinite(extent[0]) ? extent[0] : '',
    extent_y: Number.isFinite(extent[1]) ? extent[1] : '',
    extent_z: Number.isFinite(extent[2]) ? extent[2] : '',
    save_path: savePath,
  });
}

try {
  main();
} catch (error) {
  fail('WORLD_REGION_PROOF_FAILED', error && error.stack ? error.stack : String(error));
}
