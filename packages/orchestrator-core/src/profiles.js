const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_PORTS = {
  brickadia: 7777,
  omeggaWeb: 8080,
  bmfSocket: 0,
  alloyReady: 12345,
};

const PROFILE_BACKENDS = [
  'local-process',
];

const PROFILE_STORE_GUARDRAILS = [
  'local-profile-json-only',
  'atomic-profile-writes',
  'validate-profile-id',
  'validate-profile-backend',
  'do-not-store-secret-values',
  'redact-secrets-before-display-or-export',
  'do-not-add-ui-driven-server-probes',
];

function normalizeProfileId(value) {
  return String(value || 'local')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_.-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'local';
}

function defaultProfileStorePath(options = {}) {
  const root = resolveRoot(options.root);
  return path.resolve(
    options.profileStorePath ||
    options.storePath ||
    path.join(root, 'artifacts', 'local', 'profiles', 'profiles.json'),
  );
}

function loadProfileRegistry(options = {}) {
  const storePath = defaultProfileStorePath(options);
  if (!fs.existsSync(storePath)) return emptyRegistry(storePath);

  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(storePath, 'utf8'));
  } catch (error) {
    throw new Error(`Unable to read profile registry: ${error.message || String(error)}`);
  }

  const profiles = Array.isArray(parsed.profiles)
    ? parsed.profiles.map(profile => sanitizeProfileForStorage(profile))
    : [];
  const selectedProfileId = normalizeSelectedProfileId(parsed.selectedProfileId, profiles);
  return {
    schemaVersion: 1,
    storePath,
    selectedProfileId,
    profiles,
    summary: profileRegistrySummary(profiles, selectedProfileId),
    guardrails: PROFILE_STORE_GUARDRAILS,
  };
}

function saveProfileRegistry(registry, options = {}) {
  const storePath = defaultProfileStorePath(options);
  const profiles = Array.isArray(registry?.profiles)
    ? registry.profiles.map(profile => sanitizeProfileForStorage(profile))
    : [];
  const selectedProfileId = normalizeSelectedProfileId(registry?.selectedProfileId, profiles);
  const payload = {
    schemaVersion: 1,
    selectedProfileId,
    profiles,
  };
  writeJsonAtomic(storePath, payload);
  return {
    ...payload,
    storePath,
    summary: profileRegistrySummary(profiles, selectedProfileId),
    guardrails: PROFILE_STORE_GUARDRAILS,
  };
}

function upsertStoredProfile(input = {}, options = {}) {
  const registry = loadProfileRegistry(options);
  const profile = sanitizeProfileForStorage(input.profile || input);
  const profiles = registry.profiles.filter(existing => existing.id !== profile.id);
  profiles.push(profile);
  profiles.sort((left, right) => left.id.localeCompare(right.id));
  const selectedProfileId = options.select === false
    ? registry.selectedProfileId || profile.id
    : profile.id;
  return saveProfileRegistry({
    selectedProfileId,
    profiles,
  }, options);
}

function deleteStoredProfile(profileId, options = {}) {
  const id = normalizeProfileId(profileId);
  const registry = loadProfileRegistry(options);
  const profiles = registry.profiles.filter(profile => profile.id !== id);
  const selectedProfileId = registry.selectedProfileId === id
    ? profiles[0]?.id || null
    : registry.selectedProfileId;
  return saveProfileRegistry({
    selectedProfileId,
    profiles,
  }, options);
}

function selectStoredProfile(profileId, options = {}) {
  const id = normalizeProfileId(profileId);
  const registry = loadProfileRegistry(options);
  if (!registry.profiles.some(profile => profile.id === id)) {
    throw new Error(`Profile does not exist: ${id}`);
  }
  return saveProfileRegistry({
    selectedProfileId: id,
    profiles: registry.profiles,
  }, options);
}

function getStoredProfile(profileId, options = {}) {
  const registry = loadProfileRegistry(options);
  const id = profileId ? normalizeProfileId(profileId) : registry.selectedProfileId;
  return registry.profiles.find(profile => profile.id === id) || null;
}

function createServerProfile(input = {}) {
  const id = normalizeProfileId(input.id || input.name || 'local');
  const root = input.root ? path.resolve(input.root) : null;
  const backend = normalizeProfileBackend(input.backend);
  const ports = {
    ...DEFAULT_PORTS,
    ...(input.ports || {}),
  };
  const omeggaRuntime = input.paths?.omeggaRuntime || null;
  const paths = {
    brickadiaWin64: input.paths?.brickadiaWin64 || null,
    omeggaRuntime,
    omeggaStartScript: input.paths?.omeggaStartScript || input.paths?.startScript || defaultOmeggaStartScript(omeggaRuntime),
    bmfRoot: input.paths?.bmfRoot || root,
    bmfRuntimeDir: input.paths?.bmfRuntimeDir || input.paths?.runtimeDir || null,
    grafanaAlloyExecutable: input.paths?.grafanaAlloyExecutable || input.paths?.grafanaAlloyExe || defaultGrafanaAlloyExecutable(),
    grafanaAlloyConfig: input.paths?.grafanaAlloyConfig || null,
  };

  return {
    schemaVersion: 1,
    id,
    name: input.name || id,
    backend,
    backendConfig: normalizeBackendConfig(input.backendConfig, id),
    root,
    ports,
    paths,
    telemetry: {
      enabled: Boolean(input.telemetry?.enabled),
      frameTelemetryEnabled: Boolean(input.telemetry?.frameTelemetryEnabled),
      environment: input.telemetry?.environment || 'local',
      instance: input.telemetry?.instance || id,
      dashboardUrl: input.telemetry?.dashboardUrl || null,
    },
  };
}

function publicProfile(profile) {
  return {
    id: profile.id,
    name: profile.name,
    backend: profile.backend,
    backendConfig: profile.backendConfig,
    ports: profile.ports,
    paths: profile.paths,
    telemetry: {
      enabled: profile.telemetry.enabled,
      frameTelemetryEnabled: profile.telemetry.frameTelemetryEnabled,
      environment: profile.telemetry.environment,
      instance: profile.telemetry.instance,
      dashboardUrl: profile.telemetry.dashboardUrl,
    },
  };
}

function sanitizeProfileForStorage(input = {}) {
  const profile = createServerProfile(input);
  const clean = publicProfile(profile);
  clean.backend = normalizeProfileBackend(clean.backend);
  clean.backendConfig = normalizeBackendConfig(clean.backendConfig, clean.id);
  clean.paths = {
    brickadiaWin64: normalizeNullablePath(clean.paths.brickadiaWin64),
    omeggaRuntime: normalizeNullablePath(clean.paths.omeggaRuntime),
    omeggaStartScript: normalizeNullablePath(clean.paths.omeggaStartScript),
    bmfRoot: normalizeNullablePath(clean.paths.bmfRoot),
    bmfRuntimeDir: normalizeNullablePath(clean.paths.bmfRuntimeDir),
    grafanaAlloyExecutable: normalizeNullablePath(clean.paths.grafanaAlloyExecutable),
    grafanaAlloyConfig: normalizeNullablePath(clean.paths.grafanaAlloyConfig),
  };
  clean.telemetry = {
    ...clean.telemetry,
    dashboardUrl: redactUrl(clean.telemetry.dashboardUrl),
  };
  return clean;
}

function emptyRegistry(storePath) {
  return {
    schemaVersion: 1,
    storePath,
    selectedProfileId: null,
    profiles: [],
    summary: profileRegistrySummary([], null),
    guardrails: PROFILE_STORE_GUARDRAILS,
  };
}

function profileRegistrySummary(profiles, selectedProfileId) {
  return {
    total: profiles.length,
    selectedProfileId: selectedProfileId || null,
    selectedExists: Boolean(selectedProfileId && profiles.some(profile => profile.id === selectedProfileId)),
  };
}

function normalizeSelectedProfileId(value, profiles) {
  if (!value) return profiles[0]?.id || null;
  const id = normalizeProfileId(value);
  return profiles.some(profile => profile.id === id) ? id : profiles[0]?.id || null;
}

function normalizeNullablePath(value) {
  return value ? path.resolve(value) : null;
}

function normalizeProfileBackend(value) {
  const backend = String(value || 'local-process').trim().toLowerCase();
  if (backend === 'local' || backend === 'process' || backend === 'powershell') return 'local-process';
  return 'local-process';
}

function normalizeBackendConfig(_input = {}, _profileId = 'local') {
  return {};
}

function defaultOmeggaStartScript(omeggaRuntime) {
  return omeggaRuntime ? path.join(omeggaRuntime, 'Start-BrickadiaOmegga.ps1') : null;
}

function defaultGrafanaAlloyExecutable() {
  const candidates = [
    process.env.GRAFANA_ALLOY_EXE,
    process.env.GRAFANA_ALLOY_EXECUTABLE,
    process.env.ProgramFiles ? path.join(process.env.ProgramFiles, 'GrafanaLabs', 'Alloy', 'alloy.exe') : null,
    process.env.ProgramFiles ? path.join(process.env.ProgramFiles, 'GrafanaLabs', 'Alloy', 'alloy-windows-amd64.exe') : null,
    process.env['ProgramFiles(x86)'] ? path.join(process.env['ProgramFiles(x86)'], 'GrafanaLabs', 'Alloy', 'alloy.exe') : null,
    process.env['ProgramFiles(x86)'] ? path.join(process.env['ProgramFiles(x86)'], 'GrafanaLabs', 'Alloy', 'alloy-windows-amd64.exe') : null,
  ].filter(Boolean);
  return candidates.find(candidate => fs.existsSync(candidate)) || null;
}

function resolveRoot(root) {
  return path.resolve(root || path.join(__dirname, '..', '..', '..'));
}

function writeJsonAtomic(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tempPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  fs.renameSync(tempPath, filePath);
}

function redactUrl(url) {
  return url
    ? String(url).replace(/([?&](?:token|api_key|apikey|key|auth|session)=)[^&]+/gi, '$1[redacted]')
    : null;
}

module.exports = {
  DEFAULT_PORTS,
  PROFILE_BACKENDS,
  PROFILE_STORE_GUARDRAILS,
  createServerProfile,
  defaultProfileStorePath,
  deleteStoredProfile,
  getStoredProfile,
  loadProfileRegistry,
  normalizeProfileBackend,
  normalizeProfileId,
  publicProfile,
  saveProfileRegistry,
  selectStoredProfile,
  upsertStoredProfile,
};
