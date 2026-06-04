#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const vm = require('vm');
const Module = require('module');

function usage() {
  console.error([
    'Usage:',
    '  node slice-dynamic-actor-brdb.js <input.brdb> <output.brdb> (--entity-id <id> | --group-id <id>) [--parser-path <path>] [--report-json <path>] [--force]',
    '',
    'Builds an experimental single dynamic-actor graph BRDB by pruning unrelated grid files and rewriting entity chunk rows.',
  ].join('\n'));
}

function readValueArg(argv, flag) {
  const index = argv.indexOf(flag);
  if (index < 0) return null;
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`${flag} requires a value`);
  }
  argv.splice(index, 2);
  return value;
}

function readIntArg(argv, flag) {
  const value = readValueArg(argv, flag);
  if (value == null) return null;
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0) {
    throw new Error(`${flag} requires a non-negative integer`);
  }
  return number;
}

function parseArgs(argv) {
  const force = argv.includes('--force');
  if (force) argv.splice(argv.indexOf('--force'), 1);
  const entityId = readIntArg(argv, '--entity-id');
  const groupId = readIntArg(argv, '--group-id');
  const parserPath = readValueArg(argv, '--parser-path');
  const reportJson = readValueArg(argv, '--report-json');
  const [input, output] = argv;
  if (!input || !output || (entityId == null && groupId == null) || (entityId != null && groupId != null)) {
    usage();
    process.exit(2);
  }
  return {
    input: path.resolve(input),
    output: path.resolve(output),
    entityId,
    groupId,
    parserPath: parserPath ? path.resolve(parserPath) : null,
    reportJson: reportJson ? path.resolve(reportJson) : null,
    force,
  };
}

function defaultParserPath() {
  return path.resolve(
    __dirname,
    '..',
    '..',
    'Brickadia',
    'brickadia-ue4ss-re',
    'scripts',
    'list-world-entities.js',
  );
}

function loadParser(parserPath) {
  const source = fs.readFileSync(parserPath, 'utf8');
  const localRequire = Module.createRequire(parserPath);
  const moduleObj = { exports: {} };
  const sandbox = {
    require: localRequire,
    module: moduleObj,
    exports: moduleObj.exports,
    __filename: parserPath,
    __dirname: path.dirname(parserPath),
    console,
    Buffer,
    process,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
  };
  vm.runInNewContext(
    `${source}\nmodule.exports.__private = { loadBrdbInternals, readBundleFile, readType, readEntityChunkIndex };`,
    sandbox,
    { filename: parserPath },
  );
  return moduleObj.exports;
}

function encodeMsgpackInt(value) {
  if (!Number.isInteger(value)) {
    throw new Error(`Cannot encode non-integer msgpack value: ${value}`);
  }
  if (value >= 0 && value <= 0x7f) return Buffer.from([value]);
  if (value >= -32 && value < 0) return Buffer.from([0x100 + value]);
  if (value >= 0 && value <= 0xff) return Buffer.from([0xcc, value]);
  if (value >= 0 && value <= 0xffff) {
    const out = Buffer.alloc(3);
    out[0] = 0xcd;
    out.writeUInt16BE(value, 1);
    return out;
  }
  if (value >= 0 && value <= 0xffffffff) {
    const out = Buffer.alloc(5);
    out[0] = 0xce;
    out.writeUInt32BE(value, 1);
    return out;
  }
  if (value >= -0x80 && value < 0) {
    const out = Buffer.alloc(2);
    out[0] = 0xd0;
    out.writeInt8(value, 1);
    return out;
  }
  if (value >= -0x8000 && value < -0x80) {
    const out = Buffer.alloc(3);
    out[0] = 0xd1;
    out.writeInt16BE(value, 1);
    return out;
  }
  if (value >= -0x80000000 && value < -0x8000) {
    const out = Buffer.alloc(5);
    out[0] = 0xd2;
    out.writeInt32BE(value, 1);
    return out;
  }
  throw new Error(`Cannot encode msgpack integer: ${value}`);
}

function encodeMsgpackFloat(value, ty) {
  if (ty === 'f32') {
    const out = Buffer.alloc(5);
    out[0] = 0xca;
    out.writeFloatBE(Number(value) || 0, 1);
    return out;
  }
  if (ty === 'f64') {
    const out = Buffer.alloc(9);
    out[0] = 0xcb;
    out.writeDoubleBE(Number(value) || 0, 1);
    return out;
  }
  throw new Error(`Unsupported float type: ${ty}`);
}

function encodeMsgpackArrayHeader(length) {
  if (length >= 0 && length <= 15) return Buffer.from([0x90 | length]);
  if (length <= 0xffff) {
    const out = Buffer.alloc(3);
    out[0] = 0xdc;
    out.writeUInt16BE(length, 1);
    return out;
  }
  const out = Buffer.alloc(5);
  out[0] = 0xdd;
  out.writeUInt32BE(length, 1);
  return out;
}

function encodeMsgpackBinary(value) {
  const payload = Buffer.from(value || []);
  if (payload.length <= 0xff) return Buffer.concat([Buffer.from([0xc4, payload.length]), payload]);
  if (payload.length <= 0xffff) {
    const header = Buffer.alloc(3);
    header[0] = 0xc5;
    header.writeUInt16BE(payload.length, 1);
    return Buffer.concat([header, payload]);
  }
  const header = Buffer.alloc(5);
  header[0] = 0xc6;
  header.writeUInt32BE(payload.length, 1);
  return Buffer.concat([header, payload]);
}

function enumToNumber(schema, ty, value) {
  if (!schema.enums[ty]) return value;
  if (typeof value === 'number') return value;
  const mapped = schema.enums[ty][value];
  if (typeof mapped === 'number') return mapped;
  throw new Error(`Cannot encode enum ${ty}: ${value}`);
}

function encodeFlatType(schema, ty, value) {
  switch (ty) {
    case 'u8': {
      const out = Buffer.alloc(1);
      out.writeUInt8(Number(value) || 0);
      return out;
    }
    case 'u16': {
      const out = Buffer.alloc(2);
      out.writeUInt16LE(Number(value) || 0);
      return out;
    }
    case 'u32': {
      const out = Buffer.alloc(4);
      out.writeUInt32LE(Number(value) || 0);
      return out;
    }
    case 'i8': {
      const out = Buffer.alloc(1);
      out.writeInt8(Number(value) || 0);
      return out;
    }
    case 'i16': {
      const out = Buffer.alloc(2);
      out.writeInt16LE(Number(value) || 0);
      return out;
    }
    case 'i32': {
      const out = Buffer.alloc(4);
      out.writeInt32LE(Number(value) || 0);
      return out;
    }
    case 'f32': {
      const out = Buffer.alloc(4);
      out.writeFloatLE(Number(value) || 0);
      return out;
    }
    case 'f64': {
      const out = Buffer.alloc(8);
      out.writeDoubleLE(Number(value) || 0);
      return out;
    }
    default: {
      if (schema.enums[ty]) return encodeFlatType(schema, 'u8', enumToNumber(schema, ty, value));
      const struct = schema.structs[ty];
      if (!struct) throw new Error(`Unknown flat type ${ty}`);
      const parts = [];
      for (const [name, prop] of Object.entries(struct.props)) {
        if (prop.kind !== 'literal') {
          throw new Error(`Unsupported flat struct property ${ty}.${name}: ${prop.kind}`);
        }
        parts.push(encodeFlatType(schema, prop.ty, value?.[name]));
      }
      return Buffer.concat(parts);
    }
  }
}

function encodeType(schema, ty, value) {
  if (/^[ui](8|16|32|64)$/.test(ty)) return encodeMsgpackInt(Number(value) || 0);
  if (ty === 'f32' || ty === 'f64') return encodeMsgpackFloat(value, ty);
  if (schema.enums[ty]) return encodeMsgpackInt(enumToNumber(schema, ty, value));

  const struct = schema.structs[ty];
  if (!struct) throw new Error(`Unknown type ${ty}`);
  const parts = [];
  for (const [name, prop] of Object.entries(struct.props)) {
    const child = value?.[name];
    if (prop.kind === 'literal') {
      parts.push(encodeType(schema, prop.ty, child));
    } else if (prop.kind === 'array') {
      const items = Array.isArray(child) ? child : [];
      parts.push(encodeMsgpackArrayHeader(items.length));
      for (const item of items) parts.push(encodeType(schema, prop.ty, item));
    } else if (prop.kind === 'flatarray') {
      const items = Array.isArray(child) ? child : [];
      parts.push(encodeMsgpackBinary(Buffer.concat(items.map(item => encodeFlatType(schema, prop.ty, item)))));
    } else {
      throw new Error(`Unsupported schema property ${ty}.${name}: ${prop.kind}`);
    }
  }
  return Buffer.concat(parts);
}

function bitIsSet(flags, index) {
  const byte = flags?.Flags?.[Math.floor(index / 8)] || 0;
  return Boolean(byte & (1 << (index % 8)));
}

function compactFlags(flags, orderedRows) {
  const sourceBytes = flags?.Flags || [];
  if (!sourceBytes.length) {
    return { Flags: [] };
  }
  const output = new Array(Math.ceil(orderedRows.length / 8)).fill(0);
  orderedRows.forEach((oldRow, newRow) => {
    if (!bitIsSet(flags, oldRow)) return;
    const byteIndex = Math.floor(newRow / 8);
    output[byteIndex] = (output[byteIndex] || 0) | (1 << (newRow % 8));
  });
  return { Flags: output };
}

function selectedRowsByType(decoded, selectedRowSet) {
  const orderedRows = [];
  const counters = [];
  let rowStart = 0;
  for (const counter of decoded.TypeCounters || []) {
    const count = Number(counter.NumEntities) || 0;
    const rows = [];
    for (let row = rowStart; row < rowStart + count; row++) {
      if (selectedRowSet.has(row)) rows.push(row);
    }
    if (rows.length > 0) {
      counters.push({
        TypeIndex: Number(counter.TypeIndex) || 0,
        NumEntities: rows.length,
      });
      orderedRows.push(...rows);
    }
    rowStart += count;
  }
  return { counters, orderedRows };
}

function filterRows(values, orderedRows, fieldName) {
  if (!Array.isArray(values)) return [];
  if (values.length === 0) return [];
  const maxRow = Math.max(...orderedRows);
  if (values.length <= maxRow) {
    throw new Error(`Cannot row-filter ${fieldName}: ${values.length} values for max selected row ${maxRow}`);
  }
  return orderedRows.map(row => values[row]);
}

function rewriteEntityChunk(decoded, schema, selectedRows) {
  const selectedRowSet = new Set(selectedRows);
  const { counters, orderedRows } = selectedRowsByType(decoded, selectedRowSet);
  const next = {
    TypeCounters: counters,
    PersistentIndices: filterRows(decoded.PersistentIndices, orderedRows, 'PersistentIndices'),
    OwnerIndices: filterRows(decoded.OwnerIndices, orderedRows, 'OwnerIndices'),
    OriginalOwnerIndices: filterRows(decoded.OriginalOwnerIndices, orderedRows, 'OriginalOwnerIndices'),
    Locations: filterRows(decoded.Locations, orderedRows, 'Locations'),
    Rotations: filterRows(decoded.Rotations, orderedRows, 'Rotations'),
    WeldParentFlags: compactFlags(decoded.WeldParentFlags, orderedRows),
    PhysicsLockedFlags: compactFlags(decoded.PhysicsLockedFlags, orderedRows),
    PhysicsSleepingFlags: compactFlags(decoded.PhysicsSleepingFlags, orderedRows),
    WeldParentIndices: [],
    LinearVelocities: filterRows(decoded.LinearVelocities, orderedRows, 'LinearVelocities'),
    AngularVelocities: filterRows(decoded.AngularVelocities, orderedRows, 'AngularVelocities'),
    ColorsAndAlphas: filterRows(decoded.ColorsAndAlphas, orderedRows, 'ColorsAndAlphas'),
  };
  if (Array.isArray(decoded.WeldParentIndices) && decoded.WeldParentIndices.length > 0) {
    if (decoded.WeldParentIndices.length === decoded.PersistentIndices.length) {
      next.WeldParentIndices = filterRows(decoded.WeldParentIndices, orderedRows, 'WeldParentIndices');
    } else {
      throw new Error('Cannot rewrite non-empty sparse WeldParentIndices yet.');
    }
  }
  return { encoded: encodeType(schema, 'BRSavedEntityChunkSoA', next), orderedRows, counters };
}

function encodeEntityChunkIndex(index, selectedChunkCounts) {
  const chunks = [];
  const counts = [];
  for (let i = 0; i < index.chunks.length; i++) {
    const chunk = index.chunks[i];
    const chunkPath = `World/0/Entities/Chunks/${chunk.x}_${chunk.y}_${chunk.z}.mps`;
    if (!selectedChunkCounts.has(chunkPath)) continue;
    chunks.push(chunk);
    counts.push(selectedChunkCounts.get(chunkPath));
  }

  const parts = [encodeMsgpackInt(index.nextPersistentIndex), encodeMsgpackArrayHeader(chunks.length)];
  for (const chunk of chunks) {
    parts.push(encodeMsgpackInt(chunk.x));
    parts.push(encodeMsgpackInt(chunk.y));
    parts.push(encodeMsgpackInt(chunk.z));
  }
  parts.push(encodeMsgpackArrayHeader(counts.length));
  for (const count of counts) parts.push(encodeMsgpackInt(count));
  return Buffer.concat(parts);
}

function readBlob(db, filePath) {
  const row = db.prepare(`
    WITH RECURSIVE folder_path(folder_id, path) AS (
      SELECT folder_id, name FROM folders WHERE parent_id IS NULL
      UNION ALL
      SELECT f.folder_id, folder_path.path || '/' || f.name
      FROM folders f JOIN folder_path ON f.parent_id = folder_path.folder_id
    )
    SELECT files.file_id, blobs.blob_id, blobs.compression, blobs.size_uncompressed, blobs.content
    FROM files
    JOIN folder_path ON files.parent_id = folder_path.folder_id
    JOIN blobs ON files.content_id = blobs.blob_id
    WHERE folder_path.path || '/' || files.name = ?
      AND files.deleted_at IS NULL
  `).get(filePath);
  if (!row) throw new Error(`Missing bundle file: ${filePath}`);
  let content = row.content;
  if (row.compression === 1) {
    content = zlib.zstdDecompressSync(content, {
      maxOutputLength: row.size_uncompressed,
      params: {},
    });
  }
  return { ...row, content };
}

function writeBlob(db, blake3, blob, content) {
  const compressed = blob.compression === 1
    ? zlib.zstdCompressSync(content, { params: {} })
    : content;
  db.prepare(`
    UPDATE blobs
    SET size_uncompressed = ?, size_compressed = ?, hash = ?, content = ?
    WHERE blob_id = ?
  `).run(content.length, compressed.length, Buffer.from(blake3(content)), compressed, blob.blob_id);
}

function listFiles(db) {
  return db.prepare(`
    WITH RECURSIVE folder_path(folder_id, path) AS (
      SELECT folder_id, name FROM folders WHERE parent_id IS NULL
      UNION ALL
      SELECT f.folder_id, folder_path.path || '/' || f.name
      FROM folders f JOIN folder_path ON f.parent_id = folder_path.folder_id
    )
    SELECT files.file_id, folder_path.path || '/' || files.name AS path
    FROM files
    JOIN folder_path ON files.parent_id = folder_path.folder_id
    WHERE files.deleted_at IS NULL
    ORDER BY path
  `).all();
}

function pruneFiles(db, selectedGridIds, selectedEntityChunkPaths) {
  const gridIds = new Set(selectedGridIds.map(Number));
  const entityChunks = new Set(selectedEntityChunkPaths);
  const files = listFiles(db);
  const pruned = [];
  for (const file of files) {
    const gridMatch = file.path.match(/^World\/0\/Bricks\/Grids\/(\d+)\//);
    const isEntityChunk = file.path.startsWith('World/0/Entities/Chunks/');
    const keep = gridMatch
      ? gridIds.has(Number(gridMatch[1]))
      : isEntityChunk
        ? entityChunks.has(file.path)
        : true;
    if (!keep) pruned.push(file);
  }
  const stmt = db.prepare('UPDATE files SET deleted_at = 1 WHERE file_id = ?');
  for (const file of pruned) stmt.run(file.file_id);
  return { before: files.length, pruned: pruned.length, after: files.length - pruned.length };
}

function chooseGroup(summary, options) {
  const groups = summary.dynamicActorGroups || [];
  if (options.groupId != null) {
    const group = groups.find(candidate => Number(candidate.groupId) === options.groupId);
    if (!group) throw new Error(`No dynamic actor group matched group id ${options.groupId}`);
    return group;
  }
  const group = groups.find(candidate =>
    (candidate.seedEntityIds || []).some(id => Number(id) === options.entityId),
  ) || groups.find(candidate =>
    (candidate.relatedEntityIds || []).some(id => Number(id) === options.entityId),
  );
  if (!group) throw new Error(`No dynamic actor group contained entity id ${options.entityId}`);
  return group;
}

function sliceDynamicActorBrdb(options) {
  const parserPath = options.parserPath || defaultParserPath();
  if (!fs.existsSync(options.input)) throw new Error(`Input does not exist: ${options.input}`);
  if (!fs.existsSync(parserPath)) throw new Error(`Parser does not exist: ${parserPath}`);
  if (fs.existsSync(options.output) && !options.force) {
    throw new Error(`Refusing to overwrite existing output: ${options.output}`);
  }

  const brickadiaRoot = path.resolve(path.dirname(parserPath), '..', '..');
  const nodeModulesRoot = path.join(brickadiaRoot, 'omegga-master', 'omegga-master', 'node_modules');
  const Database = require(path.join(nodeModulesRoot, 'better-sqlite3'));
  const { blake3 } = require(path.join(nodeModulesRoot, '@noble', 'hashes', 'blake3.js'));
  const parser = loadParser(parserPath);
  const parserPrivate = parser.__private;
  const { readBrdbSchema } = parserPrivate.loadBrdbInternals();

  const initialSummary = parser.summarizeEntities(options.input);
  const selectedGroup = chooseGroup(initialSummary, options);
  const selectedSeedEntityId = options.entityId != null && (selectedGroup.seedEntityIds || []).some(id => Number(id) === options.entityId)
    ? options.entityId
    : Number((selectedGroup.seedEntityIds || [])[0]);
  if (!Number.isFinite(selectedSeedEntityId)) {
    throw new Error('Selected dynamic actor group did not have a usable seed entity id.');
  }
  const selectedSummary = parser.summarizeEntities(options.input, { entityId: selectedSeedEntityId });
  const graph = selectedSummary.selectedEntityGraph;
  if (!graph) throw new Error(`Parser did not resolve selected entity graph for ${selectedSeedEntityId}`);
  if ((graph.missingEntityIds || []).length > 0) {
    throw new Error(`Selected graph has missing entity ids: ${graph.missingEntityIds.join(', ')}`);
  }

  fs.mkdirSync(path.dirname(options.output), { recursive: true });
  fs.copyFileSync(options.input, options.output);

  const db = new Database(options.output);
  const chunkReports = [];
  try {
    const schema = readBrdbSchema(parserPrivate.readBundleFile(db, 'World/0/Entities/ChunksShared.schema'));
    const relatedRowsByChunk = new Map();
    for (const entity of graph.relatedEntities || []) {
      const chunkPath = entity.chunkPath;
      if (!relatedRowsByChunk.has(chunkPath)) relatedRowsByChunk.set(chunkPath, []);
      relatedRowsByChunk.get(chunkPath).push(Number(entity.row));
    }

    const selectedChunkCounts = new Map();
    const tx = db.transaction(() => {
      for (const [chunkPath, rows] of relatedRowsByChunk.entries()) {
        rows.sort((a, b) => a - b);
        const blob = readBlob(db, chunkPath);
        const decodedChunk = parserPrivate.readType(blob.content, 0, schema, 'BRSavedEntityChunkSoA');
        const decoded = decodedChunk.value;
        const dynamicPropertyTail = blob.content.subarray(decodedChunk.offset);
        const rewrite = rewriteEntityChunk(decoded, schema, rows);
        writeBlob(db, blake3, blob, Buffer.concat([rewrite.encoded, dynamicPropertyTail]));
        selectedChunkCounts.set(chunkPath, rewrite.orderedRows.length);
        chunkReports.push({
          chunkPath,
          selectedRows: rewrite.orderedRows,
          selectedEntityCount: rewrite.orderedRows.length,
          typeCounters: rewrite.counters,
          preservedDynamicPropertyTailBytes: dynamicPropertyTail.length,
        });
      }

      const indexBlob = readBlob(db, 'World/0/Entities/ChunkIndex.mps');
      const entityIndex = parserPrivate.readEntityChunkIndex(indexBlob.content);
      writeBlob(db, blake3, indexBlob, encodeEntityChunkIndex(entityIndex, selectedChunkCounts));
      pruneFiles(db, graph.relatedGridIds || [], Array.from(relatedRowsByChunk.keys()));
    });
    tx();
  } finally {
    db.close();
  }

  const slicedSummary = parser.summarizeEntities(options.output, { entityId: selectedSeedEntityId });
  const report = {
    feature: 'archives.dynamic-actor-brdb-slice',
    status: 'passed',
    validationLevel: 'L0 Static',
    inputPath: options.input,
    outputPath: options.output,
    parserPath,
    selectedGroupId: Number(selectedGroup.groupId),
    selectedSeedEntityId,
    seedEntityIds: (selectedGroup.seedEntityIds || []).map(Number),
    source: {
      entityCount: selectedSummary.entities.length,
      dynamicActorGroupCount: selectedSummary.dynamicActorGroups.length,
      relatedEntityCount: graph.relatedEntityIds.length,
      relatedGridCount: graph.relatedGridIds.length,
    },
    output: {
      entityCount: slicedSummary.entities.length,
      dynamicActorGraphCount: slicedSummary.dynamicActorGraphs.length,
      dynamicActorGroupCount: slicedSummary.dynamicActorGroups.length,
      dynamicActorGroups: slicedSummary.dynamicActorGroups,
      fileBytes: fs.statSync(options.output).size,
    },
    rewrittenEntityChunks: chunkReports,
    notes: [
      'This is an experimental static archive slice. It proves the output can be parsed as a BRDB, not that Brickadia can load it additively.',
      'The slicer preserves original persistent ids and prunes unrelated grid file rows from the bundle table.',
    ],
  };
  if (options.reportJson) {
    fs.mkdirSync(path.dirname(options.reportJson), { recursive: true });
    fs.writeFileSync(options.reportJson, `${JSON.stringify(report, null, 2)}\n`);
  }
  return report;
}

function main() {
  try {
    const report = sliceDynamicActorBrdb(parseArgs(process.argv.slice(2)));
    console.log(JSON.stringify(report, null, 2));
  } catch (error) {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  sliceDynamicActorBrdb,
};

if (require.main === module) {
  main();
}
