const fs = require('node:fs');
const path = require('node:path');

function exists(filepath) {
  return Boolean(filepath) && fs.existsSync(filepath);
}

function isDirectory(filepath) {
  return exists(filepath) && fs.statSync(filepath).isDirectory();
}

function readText(filepath, fallback = '') {
  if (!exists(filepath)) return fallback;
  return fs.readFileSync(filepath, 'utf8');
}

function readJson(filepath, fallback = null) {
  try {
    return JSON.parse(readText(filepath));
  } catch {
    return fallback;
  }
}

function findBmfRoot(startDir = process.cwd()) {
  let current = path.resolve(startDir);
  while (true) {
    if (
      exists(path.join(current, 'manifests', 'unified-runtime.json')) &&
      exists(path.join(current, 'manifests', 'bmf-package.json'))
    ) {
      return current;
    }

    const parent = path.dirname(current);
    if (parent === current) return path.resolve(startDir);
    current = parent;
  }
}

module.exports = {
  exists,
  findBmfRoot,
  isDirectory,
  readJson,
  readText,
};
