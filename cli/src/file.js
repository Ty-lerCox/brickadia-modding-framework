const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function exists(filepath) {
  return Boolean(filepath) && fs.existsSync(filepath);
}

function isDirectory(filepath) {
  return exists(filepath) && fs.statSync(filepath).isDirectory();
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
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

function writeText(filepath, value) {
  ensureDir(path.dirname(filepath));
  fs.writeFileSync(filepath, value, 'utf8');
}

function writeJson(filepath, value) {
  writeText(filepath, `${JSON.stringify(value, null, 2)}\n`);
}

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function sha256(filepath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filepath)).digest('hex');
}

function pathKey(filepath) {
  return path.resolve(filepath).replace(/^[A-Za-z]:/, '').replace(/[\\/]+/g, '__').replace(/^__/, '');
}

function backupFile(filepath, backupRoot) {
  if (!exists(filepath)) return null;
  const destination = path.join(backupRoot, `${pathKey(filepath)}.bak`);
  ensureDir(path.dirname(destination));
  fs.copyFileSync(filepath, destination);
  return destination;
}

function backupDirectory(dir, backupRoot) {
  if (!isDirectory(dir)) return null;
  const destination = path.join(backupRoot, `${pathKey(dir)}.bak`);
  ensureDir(path.dirname(destination));
  fs.cpSync(dir, destination, { recursive: true, force: true });
  return destination;
}

function copyDirectory(source, destination) {
  ensureDir(path.dirname(destination));
  fs.cpSync(source, destination, { recursive: true, force: true });
}

function listFilesRecursive(root, predicate = () => true) {
  if (!isDirectory(root)) return [];
  const out = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const filepath = path.join(root, entry.name);
    if (entry.isDirectory()) out.push(...listFilesRecursive(filepath, predicate));
    else if (entry.isFile() && predicate(filepath)) out.push(filepath);
  }
  return out;
}

function tailFile(filepath, maxLines = 250) {
  const text = readText(filepath);
  if (!text) return '';
  return text.split(/\r?\n/).slice(-maxLines).join('\n');
}

function safeRelative(root, filepath) {
  return path.relative(root, filepath).replace(/\\/g, '/');
}

module.exports = {
  backupDirectory,
  backupFile,
  copyDirectory,
  ensureDir,
  exists,
  isDirectory,
  listFilesRecursive,
  readJson,
  readText,
  safeRelative,
  sha256,
  tailFile,
  timestamp,
  writeJson,
  writeText,
};
