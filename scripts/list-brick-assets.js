#!/usr/bin/env node
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const childProcess = require('node:child_process');

function usage() {
  console.error([
    'Usage:',
    '  node scripts/list-brick-assets.js <input.brdb|input.brz> [--out-json <path>] [--brickadia-root <path>]',
    '',
    'Summarizes Brickadia brick asset names and per-chunk brick type usage from a world or prefab archive.',
  ].join('\n'));
}

function parseArgs(argv) {
  const args = { input: '', outJson: '', brickadiaRoot: '' };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--out-json') {
      args.outJson = argv[index + 1] || '';
      index += 1;
    } else if (token === '--brickadia-root') {
      args.brickadiaRoot = argv[index + 1] || '';
      index += 1;
    } else if (!token.startsWith('--') && !args.input) {
      args.input = token;
    } else {
      usage();
      process.exit(2);
    }
  }
  if (!args.input) {
    usage();
    process.exit(2);
  }
  return args;
}

function resolveBrickadiaRoot(explicitRoot) {
  const candidates = [
    explicitRoot,
    process.env.BRICKADIA_RE_ROOT,
    path.resolve(__dirname, '..', '..', 'Brickadia'),
    path.resolve(__dirname, '..', '..', '..', 'Brickadia'),
  ].filter(Boolean);

  for (const candidate of candidates) {
    const fullPath = path.resolve(candidate);
    if (fs.existsSync(path.join(fullPath, 'brickadia-ue4ss-re', 'scripts', 'inspect-brdb-schema.js'))) {
      return fullPath;
    }
  }

  throw new Error('Could not locate sibling Brickadia repo. Pass --brickadia-root <path>.');
}

function loadBetterSqlite3(brickadiaRoot) {
  return require(path.join(
    brickadiaRoot,
    'omegga-master',
    'omegga-master',
    'node_modules',
    'better-sqlite3',
  ));
}

function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function listFilesRecursive(rootDir) {
  const out = [];
  function visit(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        visit(fullPath);
      } else if (entry.isFile()) {
        out.push(path.relative(rootDir, fullPath).replace(/\\/g, '/'));
      }
    }
  }
  visit(rootDir);
  return out.sort();
}

function readBrdbBundleFile(db, filePath) {
  const row = db.prepare(`
    WITH RECURSIVE folder_path(folder_id, path) AS (
      SELECT folder_id, name
      FROM folders
      WHERE parent_id IS NULL
      UNION ALL
      SELECT f.folder_id, folder_path.path || '/' || f.name
      FROM folders f
      JOIN folder_path ON f.parent_id = folder_path.folder_id
    )
    SELECT blobs.compression, blobs.size_uncompressed, blobs.content
    FROM files
    JOIN folder_path ON files.parent_id = folder_path.folder_id
    JOIN blobs ON files.content_id = blobs.blob_id
    WHERE folder_path.path || '/' || files.name = ?
      AND files.deleted_at IS NULL
  `).get(filePath);
  if (!row) return null;
  if (row.compression === 1) {
    return zlib.zstdDecompressSync(row.content, {
      maxOutputLength: row.size_uncompressed,
      params: {},
    });
  }
  return row.content;
}

function listBrdbBundleFiles(db, prefix = '') {
  return db.prepare(`
    WITH RECURSIVE folder_path(folder_id, path) AS (
      SELECT folder_id, name
      FROM folders
      WHERE parent_id IS NULL
      UNION ALL
      SELECT f.folder_id, folder_path.path || '/' || f.name
      FROM folders f
      JOIN folder_path ON f.parent_id = folder_path.folder_id
    )
    SELECT folder_path.path || '/' || files.name AS path
    FROM files
    JOIN folder_path ON files.parent_id = folder_path.folder_id
    WHERE folder_path.path || '/' || files.name LIKE ?
      AND files.deleted_at IS NULL
    ORDER BY path
  `).all(`${prefix}%`).map(row => row.path);
}

function extractBrdb(inputPath, outputDir, brickadiaRoot) {
  const Database = loadBetterSqlite3(brickadiaRoot);
  const db = new Database(inputPath, { readonly: true, fileMustExist: true });
  try {
    const files = listBrdbBundleFiles(db);
    for (const filePath of files) {
      const content = readBrdbBundleFile(db, filePath);
      if (!content) continue;
      const destination = path.join(outputDir, ...filePath.split('/'));
      ensureParent(destination);
      fs.writeFileSync(destination, content);
    }
    return files;
  } finally {
    db.close();
  }
}

function extractBrz(inputPath, outputDir, brickadiaRoot) {
  const inspector = require(path.join(
    brickadiaRoot,
    'brickadia-ue4ss-re',
    'scripts',
    'inspect-brz.js',
  ));
  inspector.extractArchive(inspector.parseBrz(inputPath), outputDir);
  return listFilesRecursive(outputDir);
}

function decodeMps(inspectorPath, schemaPath, dataPath, typeName) {
  const output = childProcess.execFileSync(
    process.execPath,
    [inspectorPath, schemaPath, dataPath, typeName],
    {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    },
  );
  const parsed = JSON.parse(output);
  return parsed.decoded && parsed.decoded.value ? parsed.decoded.value : {};
}

function histogramIncrement(map, key, extra) {
  if (!map.has(key)) {
    map.set(key, { ...extra, count: 0 });
  }
  map.get(key).count += 1;
}

function sizeKey(size) {
  if (!size || typeof size !== 'object') return '';
  return `${size.X || 0}x${size.Y || 0}x${size.Z || 0}`;
}

function proceduralTypeTable(chunk) {
  const table = [];
  const counters = Array.isArray(chunk.BrickSizeCounters) ? chunk.BrickSizeCounters : [];
  for (const counter of counters) {
    const assetIndex = Number(counter.AssetIndex);
    const count = Number(counter.NumSizes) || 0;
    for (let index = 0; index < count; index += 1) {
      table.push(assetIndex);
    }
  }
  return table;
}

function classifyBrickType(globalData, chunk, brickTypeIndex) {
  const proceduralStart = Number(chunk.ProceduralBrickStartingIndex) || 0;
  const basicNames = Array.isArray(globalData.BasicBrickAssetNames)
    ? globalData.BasicBrickAssetNames
    : [];
  const proceduralNames = Array.isArray(globalData.ProceduralBrickAssetNames)
    ? globalData.ProceduralBrickAssetNames
    : [];

  if (brickTypeIndex < proceduralStart) {
    return {
      kind: 'basic',
      assetName: basicNames[brickTypeIndex] || `BasicBrickAsset#${brickTypeIndex}`,
      assetIndex: brickTypeIndex,
      proceduralIndex: null,
      size: null,
    };
  }

  const proceduralIndex = brickTypeIndex - proceduralStart;
  const typeTable = proceduralTypeTable(chunk);
  const assetIndex = typeTable[proceduralIndex];
  const brickSizes = Array.isArray(chunk.BrickSizes) ? chunk.BrickSizes : [];
  return {
    kind: 'procedural',
    assetName: proceduralNames[assetIndex] || `ProceduralBrickAsset#${assetIndex ?? proceduralIndex}`,
    assetIndex: Number.isFinite(Number(assetIndex)) ? Number(assetIndex) : null,
    proceduralIndex,
    size: brickSizes[proceduralIndex] || null,
  };
}

function summarizeArchive(inputPath, options) {
  const brickadiaRoot = resolveBrickadiaRoot(options.brickadiaRoot);
  const inspectorPath = path.join(
    brickadiaRoot,
    'brickadia-ue4ss-re',
    'scripts',
    'inspect-brdb-schema.js',
  );
  const ext = path.extname(inputPath).toLowerCase();
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bmf-brick-assets-'));
  try {
    const files = ext === '.brz'
      ? extractBrz(inputPath, workDir, brickadiaRoot)
      : extractBrdb(inputPath, workDir, brickadiaRoot);

    const globalData = decodeMps(
      inspectorPath,
      path.join(workDir, 'World', '0', 'GlobalData.schema'),
      path.join(workDir, 'World', '0', 'GlobalData.mps'),
      'BRSavedGlobalDataSoA',
    );
    const chunkSchemaPath = path.join(workDir, 'World', '0', 'Bricks', 'ChunksShared.schema');
    const chunkPaths = files.filter(filePath =>
      /^World\/0\/Bricks\/Grids\/\d+\/Chunks\/.+\.mps$/.test(filePath),
    );
    const assetHistogram = new Map();
    const typeHistogram = new Map();
    const chunkSummaries = [];
    let brickCount = 0;

    for (const chunkPath of chunkPaths) {
      const chunk = decodeMps(
        inspectorPath,
        chunkSchemaPath,
        path.join(workDir, ...chunkPath.split('/')),
        'BRSavedBrickChunkSoA',
      );
      const brickTypeIndices = Array.isArray(chunk.BrickTypeIndices) ? chunk.BrickTypeIndices : [];
      const chunkAssetHistogram = new Map();
      for (const rawIndex of brickTypeIndices) {
        const brickTypeIndex = Number(rawIndex);
        const classified = classifyBrickType(globalData, chunk, brickTypeIndex);
        brickCount += 1;
        histogramIncrement(
          assetHistogram,
          `${classified.kind}:${classified.assetName}`,
          {
            assetName: classified.assetName,
            kind: classified.kind,
            assetIndex: classified.assetIndex,
          },
        );
        histogramIncrement(
          typeHistogram,
          `${classified.kind}:${classified.assetName}:${brickTypeIndex}:${sizeKey(classified.size)}`,
          {
            assetName: classified.assetName,
            kind: classified.kind,
            brickTypeIndex,
            assetIndex: classified.assetIndex,
            proceduralIndex: classified.proceduralIndex,
            size: classified.size,
            sizeKey: sizeKey(classified.size),
          },
        );
        histogramIncrement(
          chunkAssetHistogram,
          `${classified.kind}:${classified.assetName}`,
          {
            assetName: classified.assetName,
            kind: classified.kind,
          },
        );
      }

      chunkSummaries.push({
        path: chunkPath,
        proceduralBrickStartingIndex: Number(chunk.ProceduralBrickStartingIndex) || 0,
        brickCount: brickTypeIndices.length,
        assetHistogram: Array.from(chunkAssetHistogram.values())
          .sort((left, right) => right.count - left.count || left.assetName.localeCompare(right.assetName)),
      });
    }

    const entityTypes = Array.isArray(globalData.EntityTypeNames) ? globalData.EntityTypeNames : [];
    const componentTypes = Array.isArray(globalData.ComponentTypeNames) ? globalData.ComponentTypeNames : [];

    return {
      feature: 'archives.brick-assets',
      status: 'passed',
      validationLevel: 'L0 Static',
      startedAt: new Date().toISOString(),
      finishedAt: new Date().toISOString(),
      data: {
        inputPath: path.resolve(inputPath),
        brickadiaRoot,
        archiveType: ext === '.brz' ? 'brz' : 'brdb',
        fileCount: files.length,
        brickChunkCount: chunkPaths.length,
        brickCount,
        basicBrickAssetNames: globalData.BasicBrickAssetNames || [],
        proceduralBrickAssetNames: globalData.ProceduralBrickAssetNames || [],
        entityTypeNames: entityTypes,
        componentTypeNames: componentTypes,
        assetHistogram: Array.from(assetHistogram.values())
          .sort((left, right) => right.count - left.count || left.assetName.localeCompare(right.assetName)),
        typeHistogram: Array.from(typeHistogram.values())
          .sort((left, right) => right.count - left.count || left.assetName.localeCompare(right.assetName)),
        chunkSummaries,
      },
      errors: [],
    };
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = summarizeArchive(path.resolve(args.input), args);
  const json = `${JSON.stringify(result, null, 2)}\n`;
  if (args.outJson) {
    const outPath = path.resolve(args.outJson);
    ensureParent(outPath);
    fs.writeFileSync(outPath, json);
  }
  process.stdout.write(json);
}

module.exports = {
  summarizeArchive,
};

if (require.main === module) {
  main();
}
