#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const vm = require('vm');
const Module = require('module');

function usage() {
  console.error([
    'Usage:',
    '  node remap-staged-vehicle-brdb.js <input.brdb> <output.brdb> [--entity-offset <n>] [--grid-offset <n>] [--parser-path <path>] [--report-json <path>] [--force]',
    '',
    'Offsets saved entity persistent ids and brick grid persistent folder ids in a staged BRDB.',
    'This is intended for duplicate additive-load canaries where two copies of the same vehicle bundle would otherwise coalesce.',
  ].join('\n'));
}

function readValueArg(argv, flag) {
  const index = argv.indexOf(flag);
  if (index < 0) return null;
  const value = argv[index + 1];
  if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value`);
  argv.splice(index, 2);
  return value;
}

function readIntArg(argv, flag) {
  const value = readValueArg(argv, flag);
  if (value == null) return null;
  const number = Number(value);
  if (!Number.isInteger(number) || number <= 0) throw new Error(`${flag} requires a positive integer`);
  return number;
}

function parseArgs(argv) {
  const force = argv.includes('--force');
  if (force) argv.splice(argv.indexOf('--force'), 1);
  const entityOffset = readIntArg(argv, '--entity-offset') ?? 100000;
  const gridOffset = readIntArg(argv, '--grid-offset') ?? entityOffset;
  const parserPath = readValueArg(argv, '--parser-path');
  const reportJson = readValueArg(argv, '--report-json');
  const [input, output] = argv;
  if (!input || !output) {
    usage();
    process.exit(2);
  }
  return {
    input: path.resolve(input),
    output: path.resolve(output),
    entityOffset,
    gridOffset,
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
    `${source}\nmodule.exports.__private = { loadBrdbInternals, readType, readEntityChunkIndex };`,
    sandbox,
    { filename: parserPath },
  );
  return moduleObj.exports;
}

function encodeMsgpackInt(value) {
  if (!Number.isInteger(value)) throw new Error(`Cannot encode non-integer msgpack value: ${value}`);
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
    case 'bool':
    case 'u8': {
      const out = Buffer.alloc(1);
      out.writeUInt8(ty === 'bool' ? (value ? 1 : 0) : (Number(value) || 0));
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
    case 'u64': {
      const out = Buffer.alloc(8);
      out.writeBigUInt64LE(BigInt(Number(value) || 0));
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
    case 'i64': {
      const out = Buffer.alloc(8);
      out.writeBigInt64LE(BigInt(Number(value) || 0));
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
        if (prop.kind !== 'literal') throw new Error(`Unsupported flat struct property ${ty}.${name}: ${prop.kind}`);
        parts.push(encodeFlatType(schema, prop.ty, value?.[name]));
      }
      return Buffer.concat(parts);
    }
  }
}

function encodeMsgpackString(value) {
  const payload = Buffer.from(String(value ?? ''), 'utf8');
  if (payload.length <= 31) return Buffer.concat([Buffer.from([0xa0 | payload.length]), payload]);
  if (payload.length <= 0xff) return Buffer.concat([Buffer.from([0xd9, payload.length]), payload]);
  if (payload.length <= 0xffff) {
    const header = Buffer.alloc(3);
    header[0] = 0xda;
    header.writeUInt16BE(payload.length, 1);
    return Buffer.concat([header, payload]);
  }
  const header = Buffer.alloc(5);
  header[0] = 0xdb;
  header.writeUInt32BE(payload.length, 1);
  return Buffer.concat([header, payload]);
}

function encodeType(schema, ty, value) {
  if (ty === 'bool') return Buffer.from([value ? 0xc3 : 0xc2]);
  if (ty === 'str') return encodeMsgpackString(value);
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

function readMsgpackMarker(buffer, offset) {
  const byte = buffer[offset];
  if (byte <= 0x7f) return { kind: 'fixpos', offset: offset + 1 };
  if (byte >= 0xe0) return { kind: 'fixneg', offset: offset + 1 };
  if ((byte & 0xf0) === 0x90) return { kind: 'fixarray', length: byte & 0x0f, offset: offset + 1 };
  switch (byte) {
    case 0xc4: return { kind: 'bin8', length: buffer.readUInt8(offset + 1), offset: offset + 2 };
    case 0xc5: return { kind: 'bin16', length: buffer.readUInt16BE(offset + 1), offset: offset + 3 };
    case 0xc6: return { kind: 'bin32', length: buffer.readUInt32BE(offset + 1), offset: offset + 5 };
    case 0xcc: return { kind: 'uint8', offset: offset + 2 };
    case 0xcd: return { kind: 'uint16', offset: offset + 3 };
    case 0xce: return { kind: 'uint32', offset: offset + 5 };
    case 0xd0: return { kind: 'int8', offset: offset + 2 };
    case 0xd1: return { kind: 'int16', offset: offset + 3 };
    case 0xd2: return { kind: 'int32', offset: offset + 5 };
    case 0xdc: return { kind: 'array16', length: buffer.readUInt16BE(offset + 1), offset: offset + 3 };
    case 0xdd: return { kind: 'array32', length: buffer.readUInt32BE(offset + 1), offset: offset + 5 };
    default:
      throw new Error(`Unsupported msgpack marker 0x${byte.toString(16)} at ${offset}`);
  }
}

function readMsgpackArrayHeader(buffer, offset) {
  const marker = readMsgpackMarker(buffer, offset);
  if (!marker.kind.includes('array')) throw new Error(`Expected msgpack array at ${offset}, got ${marker.kind}`);
  return marker;
}

function readMsgpackInt(buffer, offset) {
  const byte = buffer[offset];
  if (byte <= 0x7f) return { value: byte, offset: offset + 1 };
  if (byte >= 0xe0) return { value: byte - 0x100, offset: offset + 1 };
  switch (byte) {
    case 0xcc: return { value: buffer.readUInt8(offset + 1), offset: offset + 2 };
    case 0xcd: return { value: buffer.readUInt16BE(offset + 1), offset: offset + 3 };
    case 0xce: return { value: buffer.readUInt32BE(offset + 1), offset: offset + 5 };
    case 0xd0: return { value: buffer.readInt8(offset + 1), offset: offset + 2 };
    case 0xd1: return { value: buffer.readInt16BE(offset + 1), offset: offset + 3 };
    case 0xd2: return { value: buffer.readInt32BE(offset + 1), offset: offset + 5 };
    default:
      throw new Error(`Expected msgpack integer at ${offset}, got 0x${byte.toString(16)}`);
  }
}

function readWirePortTarget(buffer, cursor) {
  const brickIndex = readMsgpackInt(buffer, cursor);
  const componentTypeIndex = readMsgpackInt(buffer, brickIndex.offset);
  const portIndex = readMsgpackInt(buffer, componentTypeIndex.offset);
  return {
    value: {
      brickIndexInChunk: brickIndex.value,
      componentTypeIndex: componentTypeIndex.value,
      portIndex: portIndex.value,
    },
    offset: portIndex.offset,
  };
}

function readMsgpackBinary(buffer, offset) {
  const marker = readMsgpackMarker(buffer, offset);
  if (!marker.kind.startsWith('bin')) throw new Error(`Expected msgpack binary at ${offset}, got ${marker.kind}`);
  return {
    value: buffer.subarray(marker.offset, marker.offset + marker.length),
    offset: marker.offset + marker.length,
  };
}

function readWireChunk(buffer) {
  let cursor = 0;
  const remoteSourceHeader = readMsgpackArrayHeader(buffer, cursor);
  cursor = remoteSourceHeader.offset;
  const remoteWireSources = [];
  for (let i = 0; i < remoteSourceHeader.length; i++) {
    const gridPersistentIndex = readMsgpackInt(buffer, cursor);
    const x = readMsgpackInt(buffer, gridPersistentIndex.offset);
    const y = readMsgpackInt(buffer, x.offset);
    const z = readMsgpackInt(buffer, y.offset);
    const portTarget = readWirePortTarget(buffer, z.offset);
    cursor = portTarget.offset;
    remoteWireSources.push({
      gridPersistentIndex: gridPersistentIndex.value,
      chunkIndex: { x: x.value, y: y.value, z: z.value },
      ...portTarget.value,
    });
  }

  const localSourceHeader = readMsgpackArrayHeader(buffer, cursor);
  cursor = localSourceHeader.offset;
  const localWireSources = [];
  for (let i = 0; i < localSourceHeader.length; i++) {
    const source = readWirePortTarget(buffer, cursor);
    cursor = source.offset;
    localWireSources.push(source.value);
  }

  const remoteTargetHeader = readMsgpackArrayHeader(buffer, cursor);
  cursor = remoteTargetHeader.offset;
  const remoteWireTargets = [];
  for (let i = 0; i < remoteTargetHeader.length; i++) {
    const target = readWirePortTarget(buffer, cursor);
    cursor = target.offset;
    remoteWireTargets.push(target.value);
  }

  const localTargetHeader = readMsgpackArrayHeader(buffer, cursor);
  cursor = localTargetHeader.offset;
  const localWireTargets = [];
  for (let i = 0; i < localTargetHeader.length; i++) {
    const target = readWirePortTarget(buffer, cursor);
    cursor = target.offset;
    localWireTargets.push(target.value);
  }

  const pendingPropagationFlags = readMsgpackBinary(buffer, cursor);
  return {
    remoteWireSources,
    localWireSources,
    remoteWireTargets,
    localWireTargets,
    pendingPropagationFlags: pendingPropagationFlags.value,
  };
}

function encodeWirePortTarget(target) {
  return Buffer.concat([
    encodeMsgpackInt(target.brickIndexInChunk),
    encodeMsgpackInt(target.componentTypeIndex),
    encodeMsgpackInt(target.portIndex),
  ]);
}

function encodeWireChunk(chunk) {
  const parts = [encodeMsgpackArrayHeader(chunk.remoteWireSources.length)];
  for (const source of chunk.remoteWireSources) {
    parts.push(encodeMsgpackInt(source.gridPersistentIndex));
    parts.push(encodeMsgpackInt(source.chunkIndex.x));
    parts.push(encodeMsgpackInt(source.chunkIndex.y));
    parts.push(encodeMsgpackInt(source.chunkIndex.z));
    parts.push(encodeWirePortTarget(source));
  }
  parts.push(encodeMsgpackArrayHeader(chunk.localWireSources.length));
  for (const source of chunk.localWireSources) parts.push(encodeWirePortTarget(source));
  parts.push(encodeMsgpackArrayHeader(chunk.remoteWireTargets.length));
  for (const target of chunk.remoteWireTargets) parts.push(encodeWirePortTarget(target));
  parts.push(encodeMsgpackArrayHeader(chunk.localWireTargets.length));
  for (const target of chunk.localWireTargets) parts.push(encodeWirePortTarget(target));
  parts.push(encodeMsgpackBinary(chunk.pendingPropagationFlags));
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

function listFiles(db, prefix = '') {
  return db.prepare(`
    WITH RECURSIVE folder_path(folder_id, path) AS (
      SELECT folder_id, name FROM folders WHERE parent_id IS NULL
      UNION ALL
      SELECT f.folder_id, folder_path.path || '/' || f.name
      FROM folders f JOIN folder_path ON f.parent_id = folder_path.folder_id
    )
    SELECT folder_path.path || '/' || files.name AS path
    FROM files
    JOIN folder_path ON files.parent_id = folder_path.folder_id
    WHERE folder_path.path || '/' || files.name LIKE ?
      AND files.deleted_at IS NULL
    ORDER BY path
  `).all(`${prefix}%`).map(row => row.path);
}

function listGridFolders(db) {
  return db.prepare(`
    WITH RECURSIVE folder_path(folder_id, parent_id, name, path) AS (
      SELECT folder_id, parent_id, name, name FROM folders WHERE parent_id IS NULL
      UNION ALL
      SELECT f.folder_id, f.parent_id, f.name, folder_path.path || '/' || f.name
      FROM folders f JOIN folder_path ON f.parent_id = folder_path.folder_id
      WHERE f.deleted_at IS NULL
    )
    SELECT folder_id, name, path
    FROM folder_path
    WHERE path LIKE 'World/0/Bricks/Grids/%'
      AND path NOT LIKE 'World/0/Bricks/Grids/%/%'
    ORDER BY CAST(name AS INTEGER)
  `).all().filter(row => /^\d+$/.test(String(row.name)));
}

function remapNumbers(values, map, stats, field) {
  if (!Array.isArray(values)) return [];
  return values.map(value => {
    const numeric = Number(value);
    if (map.has(numeric)) {
      stats[field] = (stats[field] || 0) + 1;
      return map.get(numeric);
    }
    return value;
  });
}

function remapEntityChunk(decoded, entityMap, stats) {
  decoded.PersistentIndices = remapNumbers(decoded.PersistentIndices, entityMap, stats, 'entityPersistentIndices');
  // Owner fields are Brickadia owner-array indices, not persistent entity ids.
  // Remapping them can crash the loader when it indexes the saved owner table.
  return decoded;
}

function remapComponentChunk(decoded, entityMap, gridMap, stats) {
  decoded.JointEntityReferences = remapNumbers(decoded.JointEntityReferences, entityMap, stats, 'componentJointEntityReferences');
  decoded.MicrochipBrickGridReferences = remapNumbers(decoded.MicrochipBrickGridReferences, gridMap, stats, 'componentMicrochipGridReferences');
  return decoded;
}

function encodeEntityChunkIndex(index, nextPersistentIndex) {
  const parts = [
    encodeMsgpackInt(nextPersistentIndex),
    encodeMsgpackArrayHeader(index.chunks.length),
  ];
  for (const chunk of index.chunks) {
    parts.push(encodeMsgpackInt(chunk.x));
    parts.push(encodeMsgpackInt(chunk.y));
    parts.push(encodeMsgpackInt(chunk.z));
  }
  parts.push(encodeMsgpackArrayHeader(index.counts.length));
  for (const count of index.counts) parts.push(encodeMsgpackInt(count));
  return Buffer.concat(parts);
}

function renameGridFolders(db, gridMap) {
  const folders = listGridFolders(db).filter(folder => gridMap.has(Number(folder.name)));
  const renames = folders.map((folder, index) => ({
    folderId: folder.folder_id,
    oldName: String(folder.name),
    newName: String(gridMap.get(Number(folder.name))),
    tempName: `.__bmf_grid_remap_${process.pid}_${Date.now()}_${index}_${folder.name}`,
  })).filter(rename => rename.oldName !== rename.newName);
  const stmt = db.prepare('UPDATE folders SET name = ? WHERE folder_id = ?');
  for (const rename of renames) stmt.run(rename.tempName, rename.folderId);
  for (const rename of renames) stmt.run(rename.newName, rename.folderId);
  return renames.length;
}

function buildIdMaps(summary, options) {
  const entityIds = Array.from(new Set((summary.entities || [])
    .map(entity => Number(entity.persistentIndex ?? entity.id))
    .filter(Number.isFinite))).sort((a, b) => a - b);
  const gridIds = Array.from(new Set((summary.brickGrids || [])
    .map(grid => Number(grid.gridId))
    .filter(Number.isFinite))).sort((a, b) => a - b);
  return {
    entityIds,
    gridIds,
    entityMap: new Map(entityIds.map(id => [id, id + options.entityOffset])),
    gridMap: new Map(gridIds.map(id => [id, id + options.gridOffset])),
  };
}

function maxMappedValue(map, fallback) {
  let max = fallback;
  for (const value of map.values()) max = Math.max(max, value);
  return max;
}

function remapStagedVehicleBrdb(options) {
  const parserPath = options.parserPath || defaultParserPath();
  if (!fs.existsSync(options.input)) throw new Error(`Input does not exist: ${options.input}`);
  if (!fs.existsSync(parserPath)) throw new Error(`Parser does not exist: ${parserPath}`);
  if (fs.existsSync(options.output) && !options.force) throw new Error(`Refusing to overwrite existing output: ${options.output}`);

  const brickadiaRoot = path.resolve(path.dirname(parserPath), '..', '..');
  const nodeModulesRoot = path.join(brickadiaRoot, 'omegga-master', 'omegga-master', 'node_modules');
  const Database = require(path.join(nodeModulesRoot, 'better-sqlite3'));
  const { blake3 } = require(path.join(nodeModulesRoot, '@noble', 'hashes', 'blake3.js'));
  const parser = loadParser(parserPath);
  const parserPrivate = parser.__private;
  const { readBrdbSchema } = parserPrivate.loadBrdbInternals();
  const sourceSummary = parser.summarizeEntities(options.input);
  const maps = buildIdMaps(sourceSummary, options);
  if (maps.entityIds.length === 0) throw new Error('Input BRDB has no saved entities to remap.');
  if (maps.gridIds.length === 0) throw new Error('Input BRDB has no brick grids to remap.');

  fs.mkdirSync(path.dirname(options.output), { recursive: true });
  fs.copyFileSync(options.input, options.output);

  const stats = {};
  const chunkReports = [];
  const db = new Database(options.output);
  try {
    const entitySchema = readBrdbSchema(readBlob(db, 'World/0/Entities/ChunksShared.schema').content);
    const componentSchema = readBrdbSchema(readBlob(db, 'World/0/Bricks/ComponentsShared.schema').content);
    const tx = db.transaction(() => {
      for (const chunkPath of listFiles(db, 'World/0/Entities/Chunks/').filter(file => file.endsWith('.mps'))) {
        const blob = readBlob(db, chunkPath);
        const decodedChunk = parserPrivate.readType(blob.content, 0, entitySchema, 'BRSavedEntityChunkSoA');
        const tail = blob.content.subarray(decodedChunk.offset);
        const beforeIds = Array.from(decodedChunk.value.PersistentIndices || []);
        const remapped = remapEntityChunk(decodedChunk.value, maps.entityMap, stats);
        writeBlob(db, blake3, blob, Buffer.concat([encodeType(entitySchema, 'BRSavedEntityChunkSoA', remapped), tail]));
        chunkReports.push({
          path: chunkPath,
          type: 'entity',
          entityCount: beforeIds.length,
          firstPersistentIndexBefore: beforeIds[0] ?? null,
          firstPersistentIndexAfter: remapped.PersistentIndices?.[0] ?? null,
          preservedTailBytes: tail.length,
        });
      }

      const entityIndexBlob = readBlob(db, 'World/0/Entities/ChunkIndex.mps');
      const entityIndex = parserPrivate.readEntityChunkIndex(entityIndexBlob.content);
      const nextPersistentIndex = Math.max(
        Number(entityIndex.nextPersistentIndex || 0) + options.entityOffset,
        maxMappedValue(maps.entityMap, 0) + 1,
      );
      writeBlob(db, blake3, entityIndexBlob, encodeEntityChunkIndex(entityIndex, nextPersistentIndex));

      for (const componentPath of listFiles(db, 'World/0/Bricks/Grids/').filter(file => /\/Components\/.+\.mps$/.test(file))) {
        const blob = readBlob(db, componentPath);
        const decodedChunk = parserPrivate.readType(blob.content, 0, componentSchema, 'BRSavedComponentChunkSoA');
        const tail = blob.content.subarray(decodedChunk.offset);
        const beforeJointRefs = Array.from(decodedChunk.value.JointEntityReferences || []);
        const beforeMicroRefs = Array.from(decodedChunk.value.MicrochipBrickGridReferences || []);
        const remapped = remapComponentChunk(decodedChunk.value, maps.entityMap, maps.gridMap, stats);
        writeBlob(db, blake3, blob, Buffer.concat([encodeType(componentSchema, 'BRSavedComponentChunkSoA', remapped), tail]));
        chunkReports.push({
          path: componentPath,
          type: 'component',
          jointReferenceCount: beforeJointRefs.length,
          microchipGridReferenceCount: beforeMicroRefs.length,
          preservedTailBytes: tail.length,
        });
      }

      for (const wirePath of listFiles(db, 'World/0/Bricks/Grids/').filter(file => /\/Wires\/.+\.mps$/.test(file))) {
        const blob = readBlob(db, wirePath);
        const parsed = readWireChunk(blob.content);
        let changed = false;
        for (const source of parsed.remoteWireSources) {
          const remappedGrid = maps.gridMap.get(Number(source.gridPersistentIndex));
          if (remappedGrid != null) {
            source.gridPersistentIndex = remappedGrid;
            changed = true;
            stats.wireRemoteGridReferences = (stats.wireRemoteGridReferences || 0) + 1;
          }
        }
        if (changed) writeBlob(db, blake3, blob, encodeWireChunk(parsed));
        chunkReports.push({
          path: wirePath,
          type: 'wire',
          remoteWireSourceCount: parsed.remoteWireSources.length,
          changed,
        });
      }

      stats.renamedGridFolders = renameGridFolders(db, maps.gridMap);
    });
    tx();
  } finally {
    db.close();
  }

  const outputSummary = parser.summarizeEntities(options.output);
  const report = {
    feature: 'archives.staged-vehicle-brdb-id-remap',
    status: 'passed',
    validationLevel: 'L0 Static',
    inputPath: options.input,
    outputPath: options.output,
    parserPath,
    entityOffset: options.entityOffset,
    gridOffset: options.gridOffset,
    source: {
      entityCount: sourceSummary.entities?.length || 0,
      brickGridCount: sourceSummary.brickGrids?.length || 0,
      dynamicActorGroupCount: sourceSummary.dynamicActorGroups?.length || 0,
      entityIds: maps.entityIds,
      gridIds: maps.gridIds,
    },
    output: {
      entityCount: outputSummary.entities?.length || 0,
      brickGridCount: outputSummary.brickGrids?.length || 0,
      dynamicActorGroupCount: outputSummary.dynamicActorGroups?.length || 0,
      dynamicActorGroups: outputSummary.dynamicActorGroups || [],
      fileBytes: fs.statSync(options.output).size,
    },
    rewritten: stats,
    rewrittenChunks: chunkReports,
    notes: [
      'This is an experimental static archive rewrite intended for duplicate staged-vehicle additive-load validation.',
      'Entity chunk dynamic-property tails and component custom-data tails are preserved byte-for-byte.',
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
    const report = remapStagedVehicleBrdb(parseArgs(process.argv.slice(2)));
    console.log(JSON.stringify(report, null, 2));
  } catch (error) {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  remapStagedVehicleBrdb,
};

if (require.main === module) {
  main();
}
