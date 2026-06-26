const { buildServiceHealth } = require('./health');
const { loadUnifiedRuntimeManifest } = require('./manifest');
const { createPrerequisiteAudit } = require('./prerequisites');
const { createServerProfile, publicProfile } = require('./profiles');

const DEFAULT_OPERATION_GUARDRAILS = [
  'dry-run-by-default',
  'explicit-user-action-required',
  'structured-logs-only',
  'redact-secrets-before-display-or-export',
];

const OBSERVE_ONLY_GUARDRAILS = [
  'observe-existing-traffic-only',
  'do-not-add-ui-driven-server-probes',
  'bound-retained-record-count',
  'coalesce-repetitive-status-records',
  'apply-backpressure-when-paused',
];

const OPERATION_DEFINITIONS = {
  'install-stack': {
    title: 'Install supported BMF runtime stack',
    description: 'Prepare Brickadia, Omegga, UE4SS, BMF runtime, native helpers, and generic bridge adapters for one profile.',
    mutates: true,
    actions: [
      action('resolve-brickadia-files', 'Resolve Brickadia dedicated server files', 'omegga-runtime', 'verify', {
        healthCheck: 'brickadia-files',
        inputs: ['profile.paths.brickadiaWin64'],
      }),
      action('install-omegga-runtime', 'Install BMF-compatible Omegga runtime', 'omegga-runtime', 'install', {
        inputs: ['component source or release artifact', 'profile.paths.omeggaRuntime'],
        outputs: ['Omegga runtime source', 'Start-BrickadiaOmegga.ps1 dependency bootstrap script'],
      }),
      action('stage-ue4ss', 'Stage UE4SS compatibility assets', 'ue4ss-compatibility', 'copy', {
        healthCheck: 'ue4ss-enabled',
        outputs: ['Brickadia/Binaries/Win64/dwmapi.dll', 'ue4ss/Mods'],
      }),
      action('stage-bmf-runtime', 'Stage BMF Lua runtime', 'bmf-runtime', 'copy', {
        healthCheck: 'bmf-status-fresh',
        outputs: ['ue4ss/Mods/BMF'],
      }),
      action('stage-bmf-socket', 'Stage BMFSocket transport helper', 'bmf-native-socket', 'copy', {
        healthCheck: 'bmf-socket-connected',
        optionalWhen: 'Profile does not require socket transport.',
      }),
      action('stage-generic-bridge', 'Install generic BMF bridge Omegga plugin', 'omegga-plugin-bmf-bridge', 'copy', {
        outputs: ['Omegga plugin directory'],
      }),
      action('stage-omegga-adapters', 'Install bundled BMF Omegga adapters', 'omegga-plugin-bmf-player-sync', 'copy', {
        outputs: ['bmf-player-sync', 'bmf-minigame-events'],
      }),
      action('write-server-profile', 'Write server profile metadata', 'orchestrator-core', 'write-profile', {
        outputs: ['profile.json'],
      }),
    ],
    telemetryActions: [
      action('configure-grafana-alloy', 'Generate Grafana Alloy config', 'grafana-alloy', 'configure', {
        healthCheck: 'alloy-ready',
        inputs: ['Grafana remote-write URL', 'profile telemetry labels'],
      }),
      action('import-grafana-dashboard', 'Import standard BMF Grafana dashboard', 'grafana-dashboard', 'api-call', {
        healthCheck: 'dashboard-imported',
        inputs: ['Grafana API token', 'dashboard JSON'],
      }),
    ],
  },
  'repair-stack': {
    title: 'Repair installed runtime stack',
    description: 'Apply safe repairs selected by doctor findings while backing up changed files first.',
    mutates: true,
    actions: [
      action('run-doctor', 'Collect current doctor findings', 'orchestrator-core', 'doctor', {
        mutates: false,
      }),
      action('backup-mutable-files', 'Back up files before repair', 'orchestrator-core', 'backup', {
        outputs: ['artifacts/bmfctl/backups'],
      }),
      action('repair-launch-env', 'Repair Omegga launch environment variables', 'omegga-runtime', 'patch-file', {
        inputs: ['Start-BrickadiaOmegga.ps1'],
      }),
      action('repair-mod-enablement', 'Repair UE4SS mod enablement files', 'ue4ss-compatibility', 'patch-file', {
        inputs: ['mods.txt', 'mods.json'],
      }),
      action('repair-missing-runtime-files', 'Copy missing BMF or bridge runtime files', 'bmf-runtime', 'copy'),
      action('verify-after-repair', 'Re-run health checks after repair', 'orchestrator-core', 'doctor', {
        mutates: false,
      }),
    ],
  },
  'update-stack': {
    title: 'Update supported runtime components',
    description: 'Use the release catalog, release manifests, and checksums to update BMF Desktop-managed components with rollback coverage.',
    mutates: true,
    actions: [
      action('fetch-release-catalog', 'Fetch or read release catalog', 'orchestrator-core', 'read-manifest', {
        mutates: false,
        inputs: ['release-catalog.json'],
      }),
      action('fetch-release-manifest', 'Fetch or read release manifest', 'orchestrator-core', 'read-manifest', {
        mutates: false,
        inputs: ['release-manifest.json'],
      }),
      action('verify-release-checksums', 'Verify release artifact checksums', 'orchestrator-core', 'verify', {
        mutates: false,
        inputs: ['sha256 checksums'],
      }),
      action('backup-current-components', 'Snapshot current component versions', 'orchestrator-core', 'backup'),
      action('update-bmf-runtime', 'Update BMF Lua runtime package', 'bmf-runtime', 'copy'),
      action('update-omegga-runtime', 'Update BMF-compatible Omegga runtime', 'omegga-runtime', 'copy'),
      action('update-native-helpers', 'Update native helper binaries', 'bmf-native-socket', 'copy'),
      action('validate-updated-stack', 'Validate updated runtime stack', 'orchestrator-core', 'doctor', {
        mutates: false,
      }),
    ],
  },
  'start-stack': {
    title: 'Start managed Brickadia/Omegga stack',
    description: 'Start the supported Omegga-managed server path and watch existing health signals.',
    mutates: true,
    actions: [
      action('check-start-ports', 'Check expected ports before launch', 'orchestrator-core', 'port-check', {
        mutates: false,
        inputs: ['profile.ports.brickadia', 'profile.ports.omeggaWeb', 'profile.ports.bmfSocket'],
      }),
      action('start-omegga', 'Start Omegga with profile environment', 'omegga-runtime', 'start-process', {
        outputs: ['Omegga stdout/stderr log'],
      }),
      action('wait-bmf-status', 'Watch existing BMF runtime status file', 'bmf-runtime', 'read-file', {
        mutates: false,
        healthCheck: 'bmf-status-fresh',
        inputs: ['Mods/BMF/runtime/status.json'],
      }),
      action('check-metrics-endpoint', 'Check existing Omegga metrics endpoint', 'omegga-runtime', 'http-check', {
        mutates: false,
        healthCheck: 'metrics-endpoint',
      }),
    ],
  },
  'stop-stack': {
    title: 'Stop managed Brickadia/Omegga stack',
    description: 'Stop the selected profile through the supported supervisor path and collect exit logs.',
    mutates: true,
    actions: [
      action('request-omegga-stop', 'Request Omegga-managed shutdown', 'omegga-runtime', 'stop-process'),
      action('wait-process-exit', 'Wait for Omegga and Brickadia processes to exit', 'omegga-runtime', 'process-check', {
        mutates: false,
      }),
      action('collect-stop-logs', 'Collect recent stop logs', 'orchestrator-core', 'log-tail', {
        mutates: false,
      }),
    ],
  },
  'restart-stack': {
    title: 'Restart managed Brickadia/Omegga stack',
    description: 'Stop, then start the selected profile with the same health and log model.',
    mutates: true,
    actions: [
      action('request-omegga-stop', 'Request Omegga-managed shutdown', 'omegga-runtime', 'stop-process'),
      action('wait-process-exit', 'Wait for Omegga and Brickadia processes to exit', 'omegga-runtime', 'process-check', {
        mutates: false,
      }),
      action('check-start-ports', 'Check expected ports before launch', 'orchestrator-core', 'port-check', {
        mutates: false,
      }),
      action('start-omegga', 'Start Omegga with profile environment', 'omegga-runtime', 'start-process'),
      action('wait-bmf-status', 'Watch existing BMF runtime status file', 'bmf-runtime', 'read-file', {
        mutates: false,
        healthCheck: 'bmf-status-fresh',
      }),
    ],
  },
  'snapshot-stack': {
    title: 'Create troubleshooting snapshot',
    description: 'Collect redacted manifests, doctor output, profile data, and log tails for support.',
    mutates: true,
    actions: [
      action('collect-profile-context', 'Collect profile and component metadata', 'orchestrator-core', 'read-file', {
        mutates: false,
      }),
      action('run-doctor', 'Collect current doctor findings', 'orchestrator-core', 'doctor', {
        mutates: false,
      }),
      action('tail-runtime-logs', 'Tail recent runtime logs', 'orchestrator-core', 'log-tail', {
        mutates: false,
      }),
      action('redact-snapshot-secrets', 'Redact secrets and sensitive identifiers', 'orchestrator-core', 'redact', {
        mutates: false,
      }),
      action('write-snapshot', 'Write snapshot artifact', 'orchestrator-core', 'write-file', {
        outputs: ['artifacts/bmfctl/snapshots'],
      }),
    ],
  },
  'configure-telemetry': {
    title: 'Configure Grafana telemetry',
    description: 'Configure Alloy remote-write and dashboard import while keeping Grafana as the dashboard owner.',
    mutates: true,
    actions: [
      action('validate-grafana-settings', 'Validate Grafana Cloud settings', 'grafana-alloy', 'validate', {
        mutates: false,
        inputs: ['remote-write URL', 'username', 'token reference'],
      }),
      action('check-omegga-metrics', 'Check Omegga metrics endpoint', 'omegga-runtime', 'http-check', {
        mutates: false,
        healthCheck: 'metrics-endpoint',
      }),
      action('write-alloy-config', 'Write profile Alloy config', 'grafana-alloy', 'write-file', {
        healthCheck: 'alloy-ready',
      }),
      action('start-alloy', 'Start or inspect Grafana Alloy', 'grafana-alloy', 'start-process', {
        healthCheck: 'alloy-ready',
      }),
      action('import-dashboard', 'Import or update standard BMF dashboard', 'grafana-dashboard', 'api-call', {
        healthCheck: 'dashboard-imported',
      }),
      action('save-dashboard-url', 'Store dashboard URL on the profile', 'grafana-dashboard', 'write-profile'),
    ],
  },
  'inspect-event-traffic': {
    title: 'Inspect BMF/Omegga event traffic',
    description: 'Observe the live BMFSocket event stream and bridge diagnostic records without probing the game server.',
    mutates: false,
    guardrails: OBSERVE_ONLY_GUARDRAILS,
    actions: [
      action('connect-bmf-socket-readonly', 'Connect to BMFSocket event stream in read-only mode', 'bmf-native-socket', 'socket-read', {
        mutates: false,
        healthCheck: 'bmf-socket-connected',
        guardrails: OBSERVE_ONLY_GUARDRAILS,
      }),
      action('normalize-event-envelopes', 'Normalize event and command envelopes', 'orchestrator-core', 'transform', {
        mutates: false,
        guardrails: OBSERVE_ONLY_GUARDRAILS,
      }),
      action('redact-event-payloads', 'Redact payloads before display or export', 'orchestrator-core', 'redact', {
        mutates: false,
      }),
      action('bound-local-retention', 'Apply local retention and backpressure limits', 'orchestrator-core', 'buffer-policy', {
        mutates: false,
        guardrails: OBSERVE_ONLY_GUARDRAILS,
      }),
    ],
  },
};

const OPERATION_IDS = Object.keys(OPERATION_DEFINITIONS);

function action(id, title, component, kind, extra = {}) {
  return {
    id,
    title,
    component,
    kind,
    mutates: extra.mutates !== false,
    requiresApproval: extra.requiresApproval !== false,
    healthCheck: extra.healthCheck || null,
    inputs: extra.inputs || [],
    outputs: extra.outputs || [],
    optionalWhen: extra.optionalWhen || null,
    guardrails: extra.guardrails || [],
  };
}

function operationDefinitionById(operationId) {
  return OPERATION_DEFINITIONS[operationId] || null;
}

function createOperationPlan(operationId, options = {}) {
  const definition = operationDefinitionById(operationId);
  if (!definition) {
    throw new Error(`Unknown BMF operation "${operationId}". Known operations: ${OPERATION_IDS.join(', ')}`);
  }

  const manifest = options.manifest || loadUnifiedRuntimeManifest(options).manifest;
  const profile = normalizeProfile(options.profile);
  const health = options.health || buildServiceHealth(manifest, options.observations || {});
  const dryRun = options.dryRun !== false;
  const actions = expandActions(definition, profile).map(item => decorateAction(item, { dryRun }));
  const summary = summarizeOperationPlan(actions);

  return {
    schemaVersion: 1,
    operationId,
    title: definition.title,
    description: definition.description,
    dryRun,
    status: summary.status,
    createdAt: options.now || new Date().toISOString(),
    profile: publicProfile(profile),
    health: {
      status: health.status,
      summary: health.summary,
    },
    guardrails: Array.from(new Set([
      ...DEFAULT_OPERATION_GUARDRAILS,
      ...(definition.guardrails || []),
    ])),
    summary,
    actions,
  };
}

function createBootstrapPlan(options = {}) {
  const manifest = options.manifest || loadUnifiedRuntimeManifest(options).manifest;
  const profile = normalizeProfile(options.profile);
  const prerequisites = createPrerequisiteAudit({ profile }, {
    root: options.root,
    env: options.env,
    now: options.now,
    nodeVersion: options.nodeVersion,
    commandResolver: options.commandResolver,
  });
  const operationIds = [
    'install-stack',
    ...(profile.telemetry.enabled ? ['configure-telemetry'] : []),
    'start-stack',
    'inspect-event-traffic',
  ];

  return {
    schemaVersion: 1,
    planId: 'bootstrap-profile',
    title: 'Bootstrap BMF server profile',
    profile: publicProfile(profile),
    dryRun: options.dryRun !== false,
    prerequisites,
    operations: operationIds.map(operationId =>
      createOperationPlan(operationId, {
        ...options,
        manifest,
        profile,
      }),
    ),
  };
}

function expandActions(definition, profile) {
  const actions = [...definition.actions];
  if (profile.telemetry.enabled && definition.telemetryActions) {
    actions.push(...definition.telemetryActions);
  }
  return actions;
}

function decorateAction(item, { dryRun }) {
  return {
    ...item,
    status: 'planned',
    mode: dryRun ? 'would-run' : 'ready',
    requiresApproval: item.mutates || item.requiresApproval,
    guardrails: Array.from(new Set([
      ...(item.mutates ? DEFAULT_OPERATION_GUARDRAILS : []),
      ...(item.guardrails || []),
    ])),
  };
}

function normalizeProfile(input = {}) {
  if (input && input.schemaVersion === 1 && input.id && input.ports && input.paths && input.telemetry) {
    return input;
  }
  return createServerProfile(input);
}

function summarizeOperationPlan(actions) {
  const summary = actions.reduce(
    (counts, item) => {
      counts.total += 1;
      counts.byKind[item.kind] = (counts.byKind[item.kind] || 0) + 1;
      if (item.mutates) counts.mutating += 1;
      else counts.readOnly += 1;
      return counts;
    },
    {
      total: 0,
      mutating: 0,
      readOnly: 0,
      byKind: {},
      status: 'planned',
    },
  );
  return summary;
}

module.exports = {
  DEFAULT_OPERATION_GUARDRAILS,
  OBSERVE_ONLY_GUARDRAILS,
  OPERATION_DEFINITIONS,
  OPERATION_IDS,
  createBootstrapPlan,
  createOperationPlan,
  operationDefinitionById,
  summarizeOperationPlan,
};
