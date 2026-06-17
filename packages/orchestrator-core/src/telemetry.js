const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { createServerProfile, publicProfile } = require('./profiles');

const TELEMETRY_GUARDRAILS = [
  'grafana-owns-timeseries-dashboards',
  'render-config-with-env-secret-refs',
  'do-not-store-secret-values',
  'dashboard-import-dry-run-only',
  'dashboard-payload-redacts-secrets',
  'do-not-call-grafana-without-explicit-user-action',
  'grafana-upload-requires-confirm-import',
  'do-not-add-ui-driven-server-probes',
];

const DEFAULT_SCRAPE_INTERVAL = '15s';
const DEFAULT_BRICKADIA_BUILD = 'PC-Shipping-CL13530';
const DEFAULT_GRAFANA_API_TOKEN_ENV = 'BMF_GRAFANA_API_TOKEN';

function createTelemetryOnboardingPlan(input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const root = resolveRoot(options.root || profile.root);
  const assets = loadObservabilityAssets(root);
  const labels = buildTelemetryLabels(profile, {
    brickadiaBuild: options.brickadiaBuild || getSupportedBrickadiaBuild(root),
  });
  const scrapeInterval = sanitizeDuration(options.scrapeInterval || DEFAULT_SCRAPE_INTERVAL);
  const outputPath = resolveAlloyOutputPath(profile, options.outputPath || options.out);
  const config = renderAlloyConfig(assets.alloyTemplate, {
    ...labels,
    omegga_metrics_port: String(profile.ports.omeggaWeb || 8080),
    alloy_ready_port: String(profile.ports.alloyReady || 12345),
    scrape_interval: scrapeInterval,
  });
  const secretRefs = Array.isArray(assets.manifest.alloy?.remoteWriteSecretRefs)
    ? assets.manifest.alloy.remoteWriteSecretRefs.map(String)
    : [];
  const secretStatus = secretRefs.map(ref => ({
    ref,
    configured: hasEnvValue(ref, options.env || process.env),
  }));
  const missingSecretRefs = secretStatus.filter(item => !item.configured).map(item => item.ref);
  const dashboard = buildDashboardPlan(profile, assets, labels, options);

  return {
    schemaVersion: 1,
    feature: 'telemetry.onboarding',
    status: profile.telemetry.enabled
      ? missingSecretRefs.length === 0 ? 'ready' : 'needs-secrets'
      : 'disabled',
    createdAt: toIso(options.now || new Date()),
    profile: publicProfile(profile),
    labels,
    alloy: {
      templatePath: assets.paths.alloyTemplatePath,
      outputPath,
      config,
      configSha256: sha256(config),
      scrapeInterval,
      scrapeTargets: assets.manifest.alloy?.scrapeTargets || [],
      metricsUrl: `http://127.0.0.1:${profile.ports.omeggaWeb}/metrics`,
      readyUrl: `http://127.0.0.1:${profile.ports.alloyReady}/-/ready`,
      remoteWriteSecretRefs: secretRefs,
      secretStatus,
      missingSecretRefs,
      unresolvedPlaceholders: findTemplatePlaceholders(config),
    },
    dashboard,
    guardrails: TELEMETRY_GUARDRAILS,
  };
}

function writeTelemetryAlloyConfig(input = {}, options = {}) {
  const plan = createTelemetryOnboardingPlan(input, options);
  const outputPath = plan.alloy.outputPath;
  if (!outputPath) {
    throw new Error('Alloy output path is required. Pass --out or configure paths.grafanaAlloyConfig.');
  }
  const dryRun = options.dryRun === true;
  if (!dryRun) {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, plan.alloy.config, 'utf8');
  }
  return {
    schemaVersion: 1,
    feature: 'telemetry.alloy.write',
    status: dryRun ? 'planned' : 'written',
    dryRun,
    outputPath,
    bytes: Buffer.byteLength(plan.alloy.config, 'utf8'),
    sha256: plan.alloy.configSha256,
    missingSecretRefs: plan.alloy.missingSecretRefs,
    guardrails: plan.guardrails,
  };
}

function createDashboardImportPlan(input = {}, options = {}) {
  const profile = normalizeProfile(input.profile || input);
  const root = resolveRoot(options.root || profile.root || profile.paths?.bmfRoot);
  const assets = loadObservabilityAssets(root);
  const labels = buildTelemetryLabels(profile, {
    brickadiaBuild: options.brickadiaBuild || getSupportedBrickadiaBuild(root),
  });
  const dashboard = buildDashboardPlan(profile, assets, labels, options);
  const endpoint = parseDashboardEndpoint(dashboard.endpoint);
  const endpointUrl = dashboard.grafanaBaseUrl
    ? joinUrl(dashboard.grafanaBaseUrl, endpoint.path)
    : null;
  const outputPath = resolveDashboardImportOutputPath(profile, options, root);
  const tokenEnvRef = String(options.grafanaApiTokenEnv || DEFAULT_GRAFANA_API_TOKEN_ENV);
  const tokenConfigured = hasEnvValue(tokenEnvRef, options.env || process.env)
    || Boolean(options.grafanaApiToken);
  const payload = buildDashboardImportPayload(assets.dashboard, assets.dashboardImport, dashboard, labels, options);
  const payloadText = stringifyJson(payload);
  const missingSecretRefs = tokenConfigured ? [] : [tokenEnvRef];
  const status = profile.telemetry.enabled
    ? dashboard.grafanaBaseUrl
      ? missingSecretRefs.length === 0 ? 'ready' : 'needs-secrets'
      : 'needs-grafana-url'
    : 'disabled';

  return {
    schemaVersion: 1,
    feature: 'telemetry.dashboard.import',
    status,
    createdAt: toIso(options.now || new Date()),
    profile: publicProfile(profile),
    dashboard,
    request: {
      method: endpoint.method,
      apiPath: endpoint.path,
      url: redactUrl(endpointUrl),
      outputPath,
      contentType: 'application/json',
      tokenEnvRef,
      secretStatus: [
        {
          field: 'grafanaApiToken',
          ref: tokenEnvRef,
          configured: tokenConfigured,
        },
      ],
      missingSecretRefs,
      commands: buildDashboardImportCommands(endpointUrl, outputPath, tokenEnvRef),
    },
    payload,
    payloadSummary: {
      dashboardUid: dashboard.dashboardUid,
      dashboardVersion: dashboard.dashboardVersion,
      folderUid: dashboard.folderUid,
      prometheusDatasourceUid: dashboard.prometheusDatasourceUid,
      labels,
      bytes: Buffer.byteLength(payloadText, 'utf8'),
      sha256: sha256(payloadText),
    },
    guardrails: TELEMETRY_GUARDRAILS,
  };
}

function writeDashboardImportPayload(input = {}, options = {}) {
  const plan = createDashboardImportPlan(input, options);
  const outputPath = plan.request.outputPath;
  if (!outputPath) {
    throw new Error('Dashboard import payload output path is required. Pass --out.');
  }
  const payloadText = stringifyJson(plan.payload);
  const dryRun = options.dryRun === true;
  if (!dryRun) {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, payloadText, 'utf8');
  }
  return {
    schemaVersion: 1,
    feature: 'telemetry.dashboard.import-payload.write',
    status: dryRun ? 'planned' : 'written',
    dryRun,
    outputPath,
    bytes: Buffer.byteLength(payloadText, 'utf8'),
    sha256: sha256(payloadText),
    dashboard: plan.dashboard,
    request: {
      method: plan.request.method,
      apiPath: plan.request.apiPath,
      url: plan.request.url,
      contentType: plan.request.contentType,
      tokenEnvRef: plan.request.tokenEnvRef,
      secretStatus: plan.request.secretStatus,
      missingSecretRefs: plan.request.missingSecretRefs,
      commands: plan.request.commands,
    },
    guardrails: plan.guardrails,
  };
}

async function executeDashboardImport(input = {}, options = {}) {
  if (String(options.confirm || '').toLowerCase() !== 'import') {
    throw new Error('Refusing to upload Grafana dashboard without --confirm import.');
  }

  const plan = createDashboardImportPlan(input, options);
  if (plan.status === 'disabled') {
    return dashboardUploadResult(plan, {
      status: 'blocked',
      error: 'Telemetry is disabled for this profile.',
    });
  }
  if (!plan.request.url) {
    return dashboardUploadResult(plan, {
      status: 'blocked',
      error: 'Grafana base URL is required before dashboard upload.',
    });
  }

  const token = resolveGrafanaApiToken(plan.request.tokenEnvRef, options);
  if (!token) {
    return dashboardUploadResult(plan, {
      status: 'blocked',
      error: `Grafana API token is missing. Configure ${plan.request.tokenEnvRef}.`,
    });
  }

  const fetchImpl = options.fetch || globalThis.fetch;
  if (typeof fetchImpl !== 'function') {
    return dashboardUploadResult(plan, {
      status: 'blocked',
      error: 'No fetch implementation is available for Grafana dashboard upload.',
    });
  }

  const payloadText = stringifyJson(plan.payload);
  const request = {
    method: plan.request.method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': plan.request.contentType,
    },
    body: payloadText,
  };
  const timeoutMs = sanitizeTimeoutMs(options.timeoutMs, 10_000);
  const controller = typeof AbortController === 'function' ? new AbortController() : null;
  let timer = null;
  if (controller) {
    request.signal = controller.signal;
    timer = setTimeout(() => controller.abort(), timeoutMs);
    if (typeof timer.unref === 'function') timer.unref();
  }

  try {
    const response = await fetchImpl(plan.request.url, request);
    const responseBody = await readResponseBody(response);
    const uploadStatus = response?.ok ? 'uploaded' : 'failed';
    return dashboardUploadResult(plan, {
      status: uploadStatus,
      payloadText,
      response,
      responseBody,
      timeoutMs,
      token,
    });
  } catch (error) {
    return dashboardUploadResult(plan, {
      status: 'failed',
      payloadText,
      timeoutMs,
      token,
      error: error && error.name === 'AbortError'
        ? `Grafana dashboard upload timed out after ${timeoutMs}ms.`
        : error?.message || String(error),
    });
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function loadObservabilityAssets(root) {
  const manifestPath = path.join(root, 'observability', 'observability-manifest.json');
  const manifest = readJson(manifestPath);
  const alloyTemplatePath = path.join(root, String(manifest.alloy?.template || 'observability/alloy/bmf.alloy.template'));
  const dashboardPath = path.join(root, String(manifest.grafana?.dashboard || 'observability/grafana/bmf-dashboard.json'));
  const dashboardImportPath = path.join(root, String(manifest.grafana?.import || 'observability/grafana/dashboard-import.json'));
  return {
    manifest,
    dashboard: readJson(dashboardPath),
    dashboardImport: readJson(dashboardImportPath),
    alloyTemplate: fs.readFileSync(alloyTemplatePath, 'utf8'),
    paths: {
      manifestPath,
      alloyTemplatePath,
      dashboardPath,
      dashboardImportPath,
    },
  };
}

function buildTelemetryLabels(profile, options = {}) {
  return {
    environment: sanitizeLabelValue(profile.telemetry?.environment || 'local'),
    instance: sanitizeLabelValue(profile.telemetry?.instance || profile.id || 'local'),
    server_profile: sanitizeLabelValue(profile.id || 'local'),
    brickadia_build: sanitizeLabelValue(options.brickadiaBuild || DEFAULT_BRICKADIA_BUILD),
  };
}

function buildDashboardPlan(profile, assets, labels, options = {}) {
  const importContract = assets.dashboardImport || {};
  const baseUrl = inferGrafanaBaseUrl(profile, options);
  const folderUid = options.folderUid || 'bmf';
  const datasourceUid = options.prometheusDatasourceUid || 'grafanacloud-prom';
  const dashboardUid = assets.dashboard?.uid || assets.manifest.grafana?.dashboardUid || 'bmf-standard';
  const dashboardVersion = assets.manifest.grafana?.dashboardVersion || assets.manifest.version || '0.1.0-dev';
  const dashboardUrl = profile.telemetry?.dashboardUrl
    || (baseUrl ? `${baseUrl.replace(/\/+$/, '')}/d/${encodeURIComponent(dashboardUid)}?var-environment=${encodeURIComponent(labels.environment)}&var-instance=${encodeURIComponent(labels.instance)}&var-server_profile=${encodeURIComponent(labels.server_profile)}&var-brickadia_build=${encodeURIComponent(labels.brickadia_build)}` : null);
  const requiredInputs = Array.isArray(importContract.requiredInputs)
    ? importContract.requiredInputs.map(String)
    : [];
  const secretFields = Array.isArray(importContract.secretFields)
    ? importContract.secretFields.map(String)
    : [];

  return {
    dashboardPath: assets.paths.dashboardPath,
    importContractPath: assets.paths.dashboardImportPath,
    endpoint: importContract.api?.defaultEndpoint || 'POST /api/dashboards/db',
    grafanaBaseUrl: redactUrl(baseUrl),
    dashboardUid,
    dashboardVersion,
    folderUid,
    prometheusDatasourceUid: datasourceUid,
    dashboardUrl: redactUrl(dashboardUrl),
    requiredInputs,
    secretFields,
    labels,
  };
}

function buildDashboardImportPayload(dashboardModel, importContract, dashboard, labels, options = {}) {
  const model = prepareDashboardModel(dashboardModel, dashboard, labels, options);
  const requestTemplate = importContract?.requestTemplate || importContract?.payloadTemplate || {
    dashboard: '{{dashboardJson}}',
    folderUid: '{{folderUid}}',
    overwrite: true,
    message: 'Import BMF standard dashboard {{dashboardVersion}}',
  };
  return renderDashboardTemplate(requestTemplate, {
    dashboardJson: model,
    folderUid: dashboard.folderUid,
    dashboardVersion: dashboard.dashboardVersion,
    dashboardUid: dashboard.dashboardUid,
    prometheusDatasourceUid: dashboard.prometheusDatasourceUid,
    environment: labels.environment,
    instance: labels.instance,
    server_profile: labels.server_profile,
    brickadia_build: labels.brickadia_build,
  });
}

function prepareDashboardModel(dashboardModel, dashboard, labels, options = {}) {
  const model = cloneJson(dashboardModel || {});
  model.id = null;
  model.uid = dashboard.dashboardUid;
  if (!model.title) model.title = 'BMF Standard Server Telemetry';
  if (model.templating && Array.isArray(model.templating.list)) {
    for (const variable of model.templating.list) {
      if (!variable || typeof variable !== 'object') continue;
      if (variable.name === 'datasource') {
        variable.current = {
          text: options.prometheusDatasourceName || dashboard.prometheusDatasourceUid,
          value: dashboard.prometheusDatasourceUid,
          selected: true,
        };
        continue;
      }
      if (Object.prototype.hasOwnProperty.call(labels, variable.name)) {
        variable.current = {
          text: labels[variable.name],
          value: labels[variable.name],
          selected: true,
        };
      }
    }
  }
  return model;
}

function renderDashboardTemplate(value, replacements) {
  if (Array.isArray(value)) {
    return value.map(item => renderDashboardTemplate(item, replacements));
  }
  if (value && typeof value === 'object') {
    const result = {};
    for (const [key, child] of Object.entries(value)) {
      result[key] = renderDashboardTemplate(child, replacements);
    }
    return result;
  }
  if (typeof value !== 'string') return value;

  const exact = value.match(/^{{([A-Za-z0-9_]+)}}$/);
  if (exact && Object.prototype.hasOwnProperty.call(replacements, exact[1])) {
    return cloneJson(replacements[exact[1]]);
  }

  return value.replace(/{{([A-Za-z0-9_]+)}}/g, (_, key) => {
    const replacement = replacements[key];
    return replacement === undefined || replacement === null ? '' : String(replacement);
  });
}

function dashboardUploadResult(plan, result = {}) {
  const parsed = result.responseBody?.json || null;
  const responseUrl = parsed?.url
    ? joinUrl(plan.dashboard.grafanaBaseUrl, parsed.url)
    : plan.dashboard.dashboardUrl;
  const payloadSha256 = result.payloadText ? sha256(result.payloadText) : plan.payloadSummary.sha256;
  const errors = result.error ? [redactSecretText(result.error, result.token)] : [];

  return {
    schemaVersion: 1,
    feature: 'telemetry.dashboard.import.upload',
    status: result.status || 'blocked',
    confirmed: true,
    dashboard: {
      ...plan.dashboard,
      dashboardUid: parsed?.uid || plan.dashboard.dashboardUid,
      dashboardVersion: parsed?.version || plan.dashboard.dashboardVersion,
      dashboardUrl: redactUrl(responseUrl),
    },
    request: {
      method: plan.request.method,
      apiPath: plan.request.apiPath,
      url: plan.request.url,
      contentType: plan.request.contentType,
      tokenEnvRef: plan.request.tokenEnvRef,
      payloadSha256,
      payloadBytes: result.payloadText
        ? Buffer.byteLength(result.payloadText, 'utf8')
        : plan.payloadSummary.bytes,
      timeoutMs: result.timeoutMs || null,
    },
    response: result.response ? {
      ok: Boolean(result.response.ok),
      status: Number(result.response.status || 0),
      statusText: redactSecretText(result.response.statusText || '', result.token),
      dashboardUid: parsed?.uid || null,
      dashboardUrl: redactUrl(responseUrl),
      version: parsed?.version || null,
      slug: parsed?.slug || null,
      message: redactSecretText(parsed?.message || parsed?.status || '', result.token),
      bodySnippet: redactSecretText(result.responseBody?.text || '', result.token).slice(0, 500),
    } : null,
    errors,
    guardrails: plan.guardrails,
  };
}

function resolveGrafanaApiToken(tokenEnvRef, options = {}) {
  if (options.grafanaApiToken) return String(options.grafanaApiToken);
  const env = options.env || process.env;
  if (!env || !Object.prototype.hasOwnProperty.call(env, tokenEnvRef)) return null;
  const token = String(env[tokenEnvRef] || '');
  return token ? token : null;
}

async function readResponseBody(response) {
  if (!response) return { text: '', json: null };
  let text = '';
  let json = null;
  if (typeof response.text === 'function') {
    text = await response.text();
    if (text) {
      try {
        json = JSON.parse(text);
      } catch {
        json = null;
      }
    }
  } else if (typeof response.json === 'function') {
    try {
      json = await response.json();
      text = stringifyJson(json);
    } catch {
      json = null;
    }
  }
  return { text: String(text || ''), json };
}

function redactSecretText(value, token) {
  let text = String(value || '');
  if (token) {
    text = text.split(String(token)).join('[redacted]');
  }
  return text
    .replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi, '$1[redacted]')
    .replace(/((?:token|api[_-]?key|apikey|password|secret)["'\s:=]+)[^"',\s}]+/gi, '$1[redacted]');
}

function renderAlloyConfig(template, replacements) {
  let rendered = String(template || '');
  for (const [key, value] of Object.entries(replacements)) {
    rendered = rendered.replace(new RegExp(`{{${escapeRegExp(key)}}}`, 'g'), escapeAlloyString(value));
  }
  return rendered;
}

function findTemplatePlaceholders(value) {
  const matches = String(value || '').match(/{{[A-Za-z0-9_]+}}/g);
  return matches ? Array.from(new Set(matches)) : [];
}

function resolveAlloyOutputPath(profile, outputPath) {
  const configured = outputPath || profile.paths?.grafanaAlloyConfig;
  return configured ? path.resolve(configured) : null;
}

function resolveDashboardImportOutputPath(profile, options = {}, root = resolveRoot()) {
  const configured = options.outputPath || options.out || options.dashboardImportPath;
  if (configured) return path.resolve(configured);
  const safeProfileId = String(profile.id || 'local').replace(/[^A-Za-z0-9_.-]+/g, '-');
  return path.join(root, 'artifacts', 'local', 'telemetry', `${safeProfileId}-grafana-dashboard-import.json`);
}

function normalizeProfile(input = {}) {
  if (input && input.schemaVersion === 1 && input.id && input.ports && input.paths && input.telemetry) {
    return input;
  }
  return createServerProfile(input);
}

function getSupportedBrickadiaBuild(root) {
  const packagePath = path.join(root, 'manifests', 'bmf-package.json');
  if (!fs.existsSync(packagePath)) return DEFAULT_BRICKADIA_BUILD;
  const manifest = readJson(packagePath);
  const first = Array.isArray(manifest.supportedBrickadiaBuilds) ? manifest.supportedBrickadiaBuilds[0] : null;
  return first?.build || DEFAULT_BRICKADIA_BUILD;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function resolveRoot(root) {
  return root ? path.resolve(root) : path.resolve(__dirname, '..', '..', '..');
}

function sanitizeLabelValue(value) {
  return String(value || 'unknown')
    .trim()
    .replace(/[^A-Za-z0-9_.:-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'unknown';
}

function sanitizeDuration(value) {
  const normalized = String(value || DEFAULT_SCRAPE_INTERVAL).trim();
  return /^[0-9]+(ms|s|m|h)$/.test(normalized) ? normalized : DEFAULT_SCRAPE_INTERVAL;
}

function sanitizeTimeoutMs(value, fallback) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(Math.max(Math.trunc(parsed), 1_000), 120_000);
}

function escapeAlloyString(value) {
  return String(value ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r?\n/g, ' ');
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function hasEnvValue(ref, env) {
  return Boolean(env && Object.prototype.hasOwnProperty.call(env, ref) && String(env[ref] || '').length > 0);
}

function inferGrafanaBaseUrl(profile, options = {}) {
  const direct = normalizeUrl(options.grafanaBaseUrl || profile.telemetry?.grafanaBaseUrl);
  if (direct) return direct;
  return originFromUrl(profile.telemetry?.dashboardUrl);
}

function normalizeUrl(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;
  return /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
}

function originFromUrl(value) {
  const normalized = normalizeUrl(value);
  if (!normalized) return null;
  try {
    const url = new URL(normalized);
    return `${url.protocol}//${url.host}`;
  } catch {
    return null;
  }
}

function parseDashboardEndpoint(endpoint) {
  const normalized = String(endpoint || 'POST /api/dashboards/db').trim();
  const match = normalized.match(/^([A-Za-z]+)\s+(.+)$/);
  if (!match) {
    return {
      method: 'POST',
      path: normalized.startsWith('/') ? normalized : `/${normalized}`,
    };
  }
  const apiPath = match[2].trim();
  return {
    method: match[1].toUpperCase(),
    path: apiPath.startsWith('/') ? apiPath : `/${apiPath}`,
  };
}

function joinUrl(baseUrl, apiPath) {
  if (!baseUrl) return null;
  return `${String(baseUrl).replace(/\/+$/, '')}/${String(apiPath || '').replace(/^\/+/, '')}`;
}

function buildDashboardImportCommands(endpointUrl, outputPath, tokenEnvRef) {
  const url = endpointUrl ? redactUrl(endpointUrl) : '<grafana-base-url>/api/dashboards/db';
  const payload = outputPath || '<dashboard-import-payload.json>';
  return {
    powershell: `curl.exe -X POST "${escapeCommandArg(url)}" -H "Authorization: Bearer $env:${escapeCommandArg(tokenEnvRef)}" -H "Content-Type: application/json" --data-binary "@${escapeCommandArg(payload)}"`,
    bash: `curl -X POST "${escapeCommandArg(url)}" -H "Authorization: Bearer $${escapeCommandArg(tokenEnvRef)}" -H "Content-Type: application/json" --data-binary "@${escapeCommandArg(payload)}"`,
  };
}

function escapeCommandArg(value) {
  return String(value ?? '').replace(/"/g, '\\"');
}

function redactUrl(url) {
  if (!url) return null;
  return String(url).replace(/([?&](?:token|api_key|apikey|key|auth)=)[^&]+/gi, '$1[redacted]');
}

function cloneJson(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function stringifyJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest('hex');
}

function toIso(value) {
  return new Date(value).toISOString();
}

module.exports = {
  DEFAULT_SCRAPE_INTERVAL,
  TELEMETRY_GUARDRAILS,
  buildTelemetryLabels,
  createDashboardImportPlan,
  createTelemetryOnboardingPlan,
  executeDashboardImport,
  findTemplatePlaceholders,
  loadObservabilityAssets,
  renderAlloyConfig,
  writeDashboardImportPayload,
  writeTelemetryAlloyConfig,
};
