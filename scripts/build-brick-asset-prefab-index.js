#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

const { summarizeArchive } = require('./list-brick-assets.js');

function usage() {
  console.error([
    'Usage:',
    '  node scripts/build-brick-asset-prefab-index.js <input.brz|input.brdb> [...] [--scan-gallery [dir]] [--clipboard] [--denied-assets <csv>] [--policy-json <path>] [--out-json <path>] [--brickadia-root <path>]',
    '',
    'Builds a prefab hash/asset index for BrickAssetPlacementGuard.',
  ].join('\n'));
}

function parseArgs(argv) {
  const args = {
    inputs: [],
    scanGallery: false,
    galleryDir: '',
    clipboard: false,
    deniedAssets: [],
    policyJson: '',
    outJson: '',
    brickadiaRoot: '',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--scan-gallery') {
      args.scanGallery = true;
      const next = argv[index + 1];
      if (next && !next.startsWith('--')) {
        args.galleryDir = next;
        index += 1;
      }
    } else if (token === '--clipboard') {
      args.clipboard = true;
    } else if (token === '--denied-assets') {
      const value = argv[index + 1] || '';
      args.deniedAssets.push(...splitList(value));
      index += 1;
    } else if (token === '--policy-json') {
      args.policyJson = argv[index + 1] || '';
      index += 1;
    } else if (token === '--out-json') {
      args.outJson = argv[index + 1] || '';
      index += 1;
    } else if (token === '--brickadia-root') {
      args.brickadiaRoot = argv[index + 1] || '';
      index += 1;
    } else if (!token.startsWith('--')) {
      args.inputs.push(token);
    } else {
      usage();
      process.exit(2);
    }
  }

  return args;
}

function splitList(value) {
  return String(value || '')
    .split(/[|,]/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function defaultGalleryDir() {
  return process.env.LOCALAPPDATA
    ? path.join(process.env.LOCALAPPDATA, 'Brickadia', 'Saved', 'GalleryCache', 'Prefabs')
    : '';
}

function defaultClipboardPath() {
  return process.env.LOCALAPPDATA
    ? path.join(process.env.LOCALAPPDATA, 'Brickadia', 'Saved', 'Temp', 'Clipboard.brz')
    : '';
}

function collectInputs(args) {
  const inputs = args.inputs.map((input) => path.resolve(input));
  if (args.clipboard) {
    const clipboard = defaultClipboardPath();
    if (clipboard && fs.existsSync(clipboard)) {
      inputs.push(clipboard);
    }
  }
  if (args.scanGallery) {
    const galleryDir = path.resolve(args.galleryDir || defaultGalleryDir());
    if (!galleryDir || !fs.existsSync(galleryDir)) {
      throw new Error(`Missing gallery prefab directory: ${galleryDir}`);
    }
    for (const entry of fs.readdirSync(galleryDir).sort()) {
      if (/\.brz$/i.test(entry)) {
        inputs.push(path.join(galleryDir, entry));
      }
    }
  }
  return Array.from(new Set(inputs.map((input) => path.resolve(input))));
}

function normalizeAssetKey(value) {
  return String(value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function normalizeRule(value) {
  const text = String(value || '').trim();
  if (!text) return null;
  const startsWild = text.startsWith('*');
  const endsWild = text.endsWith('*');
  const key = normalizeAssetKey(text.replace(/\*/g, ''));
  if (!key) return null;
  let mode = 'contains';
  if (!startsWild && endsWild) mode = 'prefix';
  if (startsWild && !endsWild) mode = 'suffix';
  return { name: text, key, mode };
}

function ruleMatches(assetName, rule) {
  const key = normalizeAssetKey(assetName);
  if (!key || !rule || !rule.key) return false;
  if (rule.mode === 'prefix') return key.startsWith(rule.key);
  if (rule.mode === 'suffix') return key.endsWith(rule.key);
  return key.includes(rule.key);
}

function uniqueSorted(values) {
  const seen = new Set();
  const out = [];
  for (const value of values) {
    const text = String(value || '').trim();
    if (!text) continue;
    const key = text.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(text);
  }
  return out.sort((left, right) => left.localeCompare(right));
}

function collectAssetNames(summary) {
  const data = summary.data || {};
  return uniqueSorted([
    ...(data.basicBrickAssetNames || []),
    ...(data.proceduralBrickAssetNames || []),
    ...(data.entityTypeNames || []),
  ]);
}

function normalizeHash(value) {
  const hex = String(value || '').replace(/[^0-9a-f]/gi, '').toUpperCase();
  return hex.length === 64 ? hex : '';
}

function loadHashPrefab(brickadiaRoot) {
  const scriptPath = path.join(brickadiaRoot, 'brickadia-ue4ss-re', 'scripts', 'prefab-hash-report.js');
  if (!fs.existsSync(scriptPath)) return null;
  return require(scriptPath).hashPrefab;
}

function inferBrickadiaRoot(explicit) {
  const candidates = [
    explicit,
    process.env.BRICKADIA_RE_ROOT,
    path.resolve(__dirname, '..', '..', 'Brickadia'),
  ].filter(Boolean);
  for (const candidate of candidates) {
    const full = path.resolve(candidate);
    if (fs.existsSync(path.join(full, 'brickadia-ue4ss-re', 'scripts', 'prefab-hash-report.js'))) {
      return full;
    }
  }
  throw new Error('Could not locate Brickadia root. Pass --brickadia-root <path>.');
}

function loadTierRules(args) {
  const tiers = [];
  if (args.deniedAssets.length > 0) {
    tiers.push({
      capability: 'legacy',
      assets: uniqueSorted(args.deniedAssets),
      rules: args.deniedAssets.map(normalizeRule).filter(Boolean),
    });
  }
  if (!args.policyJson) return tiers;

  const policyPath = path.resolve(args.policyJson);
  const parsed = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const policy = parsed && parsed.policy && typeof parsed.policy === 'object' ? parsed.policy : parsed;
  const configuredTiers = policy && policy.tiers && typeof policy.tiers === 'object' ? policy.tiers : {};
  for (const [capability, tier] of Object.entries(configuredTiers)) {
    const assets = uniqueSorted(tier && (tier.assets || tier.deniedAssets || tier.blockedAssets) || []);
    if (assets.length === 0) continue;
    tiers.push({
      capability: String(capability).trim().toLowerCase(),
      assets,
      rules: assets.map(normalizeRule).filter(Boolean),
    });
  }
  return tiers;
}

function buildIndex(args) {
  const brickadiaRoot = inferBrickadiaRoot(args.brickadiaRoot);
  const hashPrefab = loadHashPrefab(brickadiaRoot);
  const tierRules = loadTierRules(args);
  const prefabs = [];

  for (const input of collectInputs(args)) {
    if (!fs.existsSync(input)) {
      throw new Error(`Input archive does not exist: ${input}`);
    }
    const summary = summarizeArchive(input, { brickadiaRoot });
    const assetNames = collectAssetNames(summary);
    const assetRequirements = [];
    for (const asset of assetNames) {
      const requiredCapabilities = uniqueSorted(tierRules
        .filter((tier) => tier.rules.some((rule) => ruleMatches(asset, rule)))
        .map((tier) => tier.capability));
      if (requiredCapabilities.length > 0) {
        assetRequirements.push({ asset, requiredCapabilities });
      }
    }
    const deniedAssets = assetRequirements.map((item) => item.asset);
    const requiredCapabilities = uniqueSorted(assetRequirements.flatMap((item) => item.requiredCapabilities));
    const ext = path.extname(input).toLowerCase();
    const hashReport = ext === '.brz' && hashPrefab ? hashPrefab(input) : null;
    const hash = normalizeHash(hashReport && hashReport.brPrefabHashCandidate);

    prefabs.push({
      inputPath: path.resolve(input),
      archiveType: ext === '.brz' ? 'brz' : 'brdb',
      name: hashReport && hashReport.name ? hashReport.name : path.basename(input, ext),
      hash,
      brPrefabHashCandidate: hash,
      assetNames,
      deniedAssets,
      assetRequirements,
      requiredCapabilities,
      brickCount: summary.data.brickCount,
      entityTypeNames: summary.data.entityTypeNames || [],
      basicBrickAssetNames: summary.data.basicBrickAssetNames || [],
      proceduralBrickAssetNames: summary.data.proceduralBrickAssetNames || [],
    });
  }

  const deniedPrefabHashes = prefabs
    .filter((prefab) => prefab.hash && prefab.deniedAssets.length > 0)
    .map((prefab) => ({
      hash: prefab.hash,
      name: prefab.name,
      deniedAssets: prefab.deniedAssets,
      assetRequirements: prefab.assetRequirements,
      requiredCapabilities: prefab.requiredCapabilities,
      inputPath: prefab.inputPath,
    }));

  return {
    feature: 'brick-asset-prefab-index',
    status: 'passed',
    generatedAt: new Date().toISOString(),
    data: {
      brickadiaRoot,
      deniedAssets: args.deniedAssets,
      policyJson: args.policyJson ? path.resolve(args.policyJson) : '',
      tiers: tierRules.map((tier) => ({ capability: tier.capability, assets: tier.assets })),
      prefabCount: prefabs.length,
      deniedPrefabHashCount: deniedPrefabHashes.length,
      prefabs,
      deniedPrefabHashes,
    },
    prefabs,
    deniedPrefabHashes,
    errors: [],
  };
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (args.inputs.length === 0 && !args.scanGallery && !args.clipboard) {
      usage();
      process.exit(2);
    }
    const result = buildIndex(args);
    const json = `${JSON.stringify(result, null, 2)}\n`;
    if (args.outJson) {
      const out = path.resolve(args.outJson);
      ensureParent(out);
      fs.writeFileSync(out, json, 'utf8');
    }
    process.stdout.write(json);
  } catch (error) {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
  }
}

module.exports = {
  buildIndex,
};

if (require.main === module) {
  main();
}
