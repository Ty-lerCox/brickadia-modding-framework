const fs = require('node:fs');
const path = require('node:path');
const {
  backupFile,
  ensureDir,
  exists,
  isDirectory,
  readJson,
  readText,
  timestamp,
  writeJson,
  writeText,
} = require('./file');

function parseModsTxt(text) {
  const mods = new Map();
  for (const line of String(text || '').split(/\r?\n/)) {
    const match = line.match(/^\s*([^:#][^:]*?)\s*:\s*(\S+)/);
    if (!match) continue;
    const name = match[1].trim();
    const value = String(match[2]).trim().toLowerCase();
    mods.set(name, value === '1' || value === 'true');
  }
  return mods;
}

function parseModsJson(text) {
  const parsed = (() => {
    try {
      return JSON.parse(String(text || '[]'));
    } catch {
      return [];
    }
  })();
  const mods = new Map();
  if (!Array.isArray(parsed)) return mods;
  for (const entry of parsed) {
    if (!entry || typeof entry !== 'object' || !entry.mod_name) continue;
    mods.set(String(entry.mod_name), Boolean(entry.mod_enabled));
  }
  return mods;
}

function setModInTxt(text, modName, enabled) {
  const originalLines = String(text || '').split(/\r?\n/);
  const lines = originalLines.length === 1 && originalLines[0] === '' ? [] : originalLines;
  let found = false;

  const rewritten = lines.map(line => {
    const match = line.match(/^(\s*)([^:#][^:]*?)(\s*:\s*)(\S+)(.*)$/);
    if (!match || match[2].trim() !== modName) return line;
    found = true;
    return `${match[1]}${match[2].trim()}${match[3]}${enabled ? '1' : '0'}${match[5] || ''}`;
  });

  if (!found) {
    const insert = `${modName} : ${enabled ? '1' : '0'}`;
    const keybindsIndex = rewritten.findIndex(line =>
      line.trimStart().toLowerCase().startsWith('keybinds :'),
    );
    if (keybindsIndex === -1) rewritten.push(insert);
    else rewritten.splice(keybindsIndex, 0, insert);
  }

  return `${rewritten.filter((line, index) => index < rewritten.length - 1 || line !== '').join('\n')}\n`;
}

function setModInJson(text, modName, enabled) {
  const parsed = (() => {
    try {
      const value = JSON.parse(String(text || '[]'));
      return Array.isArray(value) ? value : [];
    } catch {
      return [];
    }
  })();

  const existing = parsed.find(entry => entry && entry.mod_name === modName);
  if (existing) existing.mod_enabled = enabled;
  else parsed.push({ mod_name: modName, mod_enabled: enabled });
  return parsed;
}

function modStateForDir(modsDir, modName) {
  const modsTxtPath = path.join(modsDir, 'mods.txt');
  const modsJsonPath = path.join(modsDir, 'mods.json');
  const txt = parseModsTxt(readText(modsTxtPath));
  const json = parseModsJson(readText(modsJsonPath));
  const folderPath = path.join(modsDir, modName);

  return {
    modsDir,
    folderPath,
    folderExists: isDirectory(folderPath),
    modsTxtPath,
    modsJsonPath,
    txtEnabled: txt.has(modName) ? txt.get(modName) : null,
    jsonEnabled: json.has(modName) ? json.get(modName) : null,
  };
}

function listMods(modsDir) {
  const discovered = new Map();
  if (isDirectory(modsDir)) {
    for (const entry of fs.readdirSync(modsDir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      discovered.set(entry.name, {
        name: entry.name,
        folderExists: true,
        txtEnabled: null,
        jsonEnabled: null,
      });
    }
  }

  const txt = parseModsTxt(readText(path.join(modsDir, 'mods.txt')));
  for (const [name, enabled] of txt) {
    discovered.set(name, {
      ...(discovered.get(name) || { name, folderExists: isDirectory(path.join(modsDir, name)) }),
      txtEnabled: enabled,
    });
  }

  const json = parseModsJson(readText(path.join(modsDir, 'mods.json')));
  for (const [name, enabled] of json) {
    discovered.set(name, {
      ...(discovered.get(name) || { name, folderExists: isDirectory(path.join(modsDir, name)) }),
      jsonEnabled: enabled,
    });
  }

  return Array.from(discovered.values()).sort((a, b) => a.name.localeCompare(b.name));
}

function setModEnabled(modsDir, modName, enabled, options = {}) {
  const dryRun = Boolean(options.dryRun);
  const backupRoot =
    options.backupRoot || path.join(modsDir, '.bmfctl-backups', timestamp());
  const modsTxtPath = path.join(modsDir, 'mods.txt');
  const modsJsonPath = path.join(modsDir, 'mods.json');
  const beforeTxt = readText(modsTxtPath);
  const beforeJson = readText(modsJsonPath, '[]\n');
  const afterTxt = setModInTxt(beforeTxt, modName, enabled);
  const afterJson = setModInJson(beforeJson, modName, enabled);
  const changes = [];

  if (beforeTxt !== afterTxt) {
    changes.push({
      action: dryRun ? 'would-write' : 'write',
      path: modsTxtPath,
      backupPath: exists(modsTxtPath) && !dryRun ? backupFile(modsTxtPath, backupRoot) : null,
    });
    if (!dryRun) {
      ensureDir(path.dirname(modsTxtPath));
      writeText(modsTxtPath, afterTxt);
    }
  }

  const normalizedBeforeJson = `${JSON.stringify(
    (() => {
      try {
        const parsed = JSON.parse(beforeJson || '[]');
        return Array.isArray(parsed) ? parsed : [];
      } catch {
        return [];
      }
    })(),
    null,
    2,
  )}\n`;
  const normalizedAfterJson = `${JSON.stringify(afterJson, null, 2)}\n`;
  if (normalizedBeforeJson !== normalizedAfterJson) {
    changes.push({
      action: dryRun ? 'would-write' : 'write',
      path: modsJsonPath,
      backupPath: exists(modsJsonPath) && !dryRun ? backupFile(modsJsonPath, backupRoot) : null,
    });
    if (!dryRun) {
      ensureDir(path.dirname(modsJsonPath));
      writeJson(modsJsonPath, afterJson);
    }
  }

  return {
    backupRoot: dryRun || changes.length === 0 ? null : backupRoot,
    changes,
    enabled,
    modName,
    modsDir,
  };
}

module.exports = {
  listMods,
  modStateForDir,
  parseModsJson,
  parseModsTxt,
  setModEnabled,
  setModInJson,
  setModInTxt,
};
