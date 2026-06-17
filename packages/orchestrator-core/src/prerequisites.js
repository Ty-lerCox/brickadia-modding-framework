const fs = require('node:fs');
const path = require('node:path');

const { createServerProfile, publicProfile } = require('./profiles');

const PREREQUISITE_GUARDRAILS = [
  'inspect-only',
  'no-silent-external-installs',
  'no-secret-value-reads',
  'profile-paths-drive-remediation',
  'mutations-stay-in-explicit-transactions',
];

const REQUIRED_NODE_MAJOR_FOR_OMEGGA = 23;

function createPrerequisiteAudit(input = {}, options = {}) {
  const root = path.resolve(options.root || input.root || input.profile?.paths?.bmfRoot || path.join(__dirname, '..', '..', '..'));
  const profile = normalizeProfile(input.profile || input, root);
  const env = options.env || process.env;
  const commandResolver = options.commandResolver || ((command) => findExecutable(command, env));
  const nodeVersion = options.nodeVersion || process.versions.node;
  const checks = [
    checkBmfRoot(root),
    checkBrickadiaWin64(profile),
    checkOmeggaSource(root),
    checkOmeggaInstallTarget(root, profile),
    checkNodeRuntime(nodeVersion),
    checkCommand('npm-cli', 'npm', 'npm', 'Omegga dependency bootstrap uses npm install/ci before start.', commandResolver, {
      nextAction: 'Install Node.js with npm, then rerun bmfctl prerequisites.',
    }),
    checkPowerShell(commandResolver),
    checkAlloy(profile),
  ];
  const summary = summarizePrerequisites(checks);

  return {
    schemaVersion: 1,
    feature: 'prerequisites.audit',
    status: summary.blocked > 0 ? 'blocked' : summary.unhealthy > 0 || summary.degraded > 0 || summary.unknown > 0 ? 'attention' : 'ready',
    collectedAt: options.now || new Date().toISOString(),
    profile: publicProfile(profile),
    root,
    requiredNodeMajorForOmegga: REQUIRED_NODE_MAJOR_FOR_OMEGGA,
    guardrails: PREREQUISITE_GUARDRAILS,
    summary,
    checks,
  };
}

function normalizeProfile(input, root) {
  if (input && input.schemaVersion === 1 && input.id && input.paths && input.ports && input.telemetry) {
    return createServerProfile({
      ...input,
      root: input.root || root,
      paths: {
        ...input.paths,
        bmfRoot: input.paths.bmfRoot || root,
      },
    });
  }
  return createServerProfile({
    ...(input || {}),
    root,
    paths: {
      ...(input?.paths || {}),
      bmfRoot: input?.paths?.bmfRoot || root,
    },
  });
}

function checkBmfRoot(root) {
  const manifestPath = path.join(root, 'manifests', 'unified-runtime.json');
  const packagePath = path.join(root, 'manifests', 'bmf-package.json');
  const ok = fs.existsSync(manifestPath) && fs.existsSync(packagePath);
  return prerequisiteCheck({
    id: 'bmf-root',
    title: 'BMF runtime bundle',
    component: 'bmf-workspace',
    required: true,
    status: ok ? 'healthy' : 'unhealthy',
    summary: ok
      ? 'BMF root contains the unified runtime and package manifests.'
      : 'BMF root is missing required runtime manifests.',
    evidence: [manifestPath, packagePath],
    nextAction: ok ? null : 'Point BMF_ROOT or the Desktop bundled root at a complete BMF repository/package.',
    remediation: {
      kind: 'profile-path',
      profileField: 'paths.bmfRoot',
      operationId: 'install-stack',
    },
  });
}

function checkBrickadiaWin64(profile) {
  const win64 = profile.paths?.brickadiaWin64;
  const serverExe = win64 ? path.join(win64, 'BrickadiaServer-Win64-Shipping.exe') : null;
  const ok = Boolean(serverExe && fs.existsSync(serverExe));
  return prerequisiteCheck({
    id: 'brickadia-win64',
    title: 'Brickadia dedicated server files',
    component: 'brickadia-server',
    required: true,
    status: ok ? 'healthy' : 'unhealthy',
    summary: ok
      ? 'Brickadia server executable is configured.'
      : win64
        ? 'Configured Brickadia Win64 path does not contain BrickadiaServer-Win64-Shipping.exe.'
        : 'Brickadia Win64 path is not configured.',
    evidence: [win64, serverExe].filter(Boolean),
    nextAction: 'Choose the Brickadia Binaries/Win64 folder for this profile.',
    remediation: {
      kind: 'profile-path',
      profileField: 'paths.brickadiaWin64',
      operationId: 'install-stack',
    },
  });
}

function checkOmeggaSource(root) {
  const sourceRoot = path.join(root, 'packages', 'omegga-runtime', 'source');
  const packagePath = path.join(sourceRoot, 'package.json');
  const lockPath = path.join(sourceRoot, 'package-lock.json');
  const ok = fs.existsSync(packagePath) && fs.existsSync(lockPath);
  return prerequisiteCheck({
    id: 'omegga-runtime-source',
    title: 'Bundled BMF-supported Omegga source',
    component: 'omegga-runtime',
    required: true,
    status: ok ? 'healthy' : 'unhealthy',
    summary: ok
      ? 'Bundled BMF-supported Omegga source and lockfile are present.'
      : 'Bundled BMF-supported Omegga source is incomplete.',
    evidence: [packagePath, lockPath],
    nextAction: ok ? null : 'Restore packages/omegga-runtime/source from the BMF release package.',
    remediation: {
      kind: 'release-package',
      operationId: 'install-stack',
    },
  });
}

function checkOmeggaInstallTarget(root, profile) {
  const configured = profile.paths?.omeggaRuntime;
  const packagedSource = path.resolve(root, 'packages', 'omegga-runtime', 'source');
  const target = configured ? path.resolve(configured) : null;
  const isPackagedSource = target && samePath(target, packagedSource);
  const ok = Boolean(target && !isPackagedSource);
  return prerequisiteCheck({
    id: 'omegga-install-target',
    title: 'Writable Omegga install target',
    component: 'omegga-runtime',
    required: true,
    status: ok ? 'healthy' : 'unhealthy',
    summary: ok
      ? 'Profile has a writable Omegga runtime target distinct from the bundled source.'
      : isPackagedSource
        ? 'Omegga target points at the bundled source tree; choose a writable profile install folder.'
        : 'Omegga runtime install target is not configured.',
    evidence: [target || configured, packagedSource].filter(Boolean),
    nextAction: 'Choose a writable Omegga runtime folder for this profile.',
    remediation: {
      kind: 'profile-path',
      profileField: 'paths.omeggaRuntime',
      operationId: 'install-stack',
    },
  });
}

function checkNodeRuntime(nodeVersion) {
  const parsed = parseNodeVersion(nodeVersion);
  const ok = parsed.major >= REQUIRED_NODE_MAJOR_FOR_OMEGGA;
  return prerequisiteCheck({
    id: 'node-runtime',
    title: 'Node.js runtime for Omegga',
    component: 'nodejs',
    required: true,
    status: ok ? 'healthy' : 'unhealthy',
    summary: ok
      ? `Node.js ${parsed.text} satisfies the BMF-supported Omegga runtime floor.`
      : `Node.js ${parsed.text || 'is not available'} does not satisfy Omegga's Node ${REQUIRED_NODE_MAJOR_FOR_OMEGGA}+ requirement.`,
    evidence: [process.execPath, parsed.text ? `node=${parsed.text}` : null].filter(Boolean),
    nextAction: ok ? null : `Install Node.js ${REQUIRED_NODE_MAJOR_FOR_OMEGGA}+ with npm before starting Omegga.`,
    remediation: {
      kind: 'external-install',
      command: `winget install OpenJS.NodeJS.LTS`,
      operationId: 'start-stack',
    },
  });
}

function checkCommand(id, title, command, summary, commandResolver, extra = {}) {
  const resolved = commandResolver(command);
  return prerequisiteCheck({
    id,
    title,
    component: 'host-tools',
    required: true,
    status: resolved ? 'healthy' : 'unhealthy',
    summary: resolved ? `${title} was found on PATH.` : summary,
    evidence: resolved ? [resolved] : [],
    nextAction: resolved ? null : extra.nextAction,
    remediation: {
      kind: 'external-install',
      operationId: 'start-stack',
      ...(extra.remediation || {}),
    },
  });
}

function checkPowerShell(commandResolver) {
  const resolved = commandResolver('pwsh') || commandResolver('powershell');
  return prerequisiteCheck({
    id: 'powershell-runtime',
    title: 'PowerShell runtime',
    component: 'host-tools',
    required: true,
    status: resolved ? 'healthy' : 'unhealthy',
    summary: resolved
      ? 'PowerShell is available for generated start scripts and validation helpers.'
      : 'PowerShell is required for BMF/Omegga start scripts and Windows validation helpers.',
    evidence: resolved ? [resolved] : [],
    nextAction: resolved ? null : 'Install PowerShell or run on a supported Windows environment.',
    remediation: {
      kind: 'external-install',
      command: 'winget install Microsoft.PowerShell',
      operationId: 'start-stack',
    },
  });
}

function checkAlloy(profile) {
  const telemetryEnabled = Boolean(profile.telemetry?.enabled);
  const configured = profile.paths?.grafanaAlloyExecutable;
  const ok = Boolean(!telemetryEnabled || (configured && fs.existsSync(configured)));
  return prerequisiteCheck({
    id: 'grafana-alloy-executable',
    title: 'Grafana Alloy executable',
    component: 'grafana-alloy',
    required: telemetryEnabled,
    status: ok ? 'healthy' : telemetryEnabled ? 'unhealthy' : 'degraded',
    summary: ok
      ? telemetryEnabled
        ? 'Grafana Alloy executable is configured for telemetry.'
        : 'Telemetry is disabled; Alloy is optional.'
      : configured
        ? 'Configured Grafana Alloy executable does not exist.'
        : 'Telemetry is enabled but Grafana Alloy executable is not configured.',
    evidence: configured ? [configured] : [],
    nextAction: ok ? null : 'Install Grafana Alloy and select the executable in the profile.',
    remediation: {
      kind: 'profile-path',
      profileField: 'paths.grafanaAlloyExecutable',
      operationId: 'configure-telemetry',
    },
  });
}

function prerequisiteCheck(input) {
  return {
    id: input.id,
    title: input.title,
    component: input.component,
    required: Boolean(input.required),
    status: input.status,
    summary: input.summary,
    evidence: Array.from(new Set((input.evidence || []).filter(Boolean).map(String))),
    nextAction: input.nextAction || null,
    remediation: input.remediation || null,
  };
}

function summarizePrerequisites(checks) {
  const summary = {
    total: checks.length,
    required: checks.filter(check => check.required).length,
    healthy: 0,
    degraded: 0,
    unhealthy: 0,
    unknown: 0,
    blocked: 0,
  };
  for (const check of checks) {
    if (check.status === 'healthy') summary.healthy += 1;
    else if (check.status === 'degraded') summary.degraded += 1;
    else if (check.status === 'unhealthy') summary.unhealthy += 1;
    else summary.unknown += 1;
    if (check.required && check.status !== 'healthy') summary.blocked += 1;
  }
  return summary;
}

function findExecutable(command, env = process.env) {
  if (!command) return null;
  const pathValue = env.PATH || env.Path || env.path || '';
  const extensions = process.platform === 'win32'
    ? String(env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').filter(Boolean)
    : [''];
  for (const directory of pathValue.split(path.delimiter).filter(Boolean)) {
    for (const extension of extensions) {
      const candidate = path.join(directory, hasKnownExtension(command, extensions) ? command : `${command}${extension.toLowerCase()}`);
      if (fs.existsSync(candidate)) return candidate;
      const upperCandidate = path.join(directory, hasKnownExtension(command, extensions) ? command : `${command}${extension.toUpperCase()}`);
      if (fs.existsSync(upperCandidate)) return upperCandidate;
    }
  }
  return null;
}

function hasKnownExtension(command, extensions) {
  const lower = command.toLowerCase();
  return extensions.some(extension => extension && lower.endsWith(extension.toLowerCase()));
}

function parseNodeVersion(value) {
  const text = String(value || '').replace(/^v/i, '');
  const [majorText, minorText, patchText] = text.split('.');
  return {
    text,
    major: Number.parseInt(majorText, 10) || 0,
    minor: Number.parseInt(minorText, 10) || 0,
    patch: Number.parseInt(patchText, 10) || 0,
  };
}

function samePath(left, right) {
  return path.resolve(left).toLowerCase() === path.resolve(right).toLowerCase();
}

module.exports = {
  PREREQUISITE_GUARDRAILS,
  REQUIRED_NODE_MAJOR_FOR_OMEGGA,
  createPrerequisiteAudit,
  findExecutable,
  summarizePrerequisites,
};
