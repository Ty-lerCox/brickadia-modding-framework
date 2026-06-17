const childProcess = require('node:child_process');
const net = require('node:net');

const SERVICE_DIAGNOSTIC_GUARDRAILS = [
  'bounded-local-port-inspection',
  'no-game-server-command-probes',
  'read-local-process-state-only',
  'redact-secrets-before-display-or-export',
];

function getConfiguredPortTargets(profile = {}) {
  const ports = profile.ports || {};
  const telemetryEnabled = Boolean(profile.telemetry?.enabled);
  const bmfSocketPort = numericPort(ports.bmfSocket);

  return [
    portTarget('brickadia', 'Brickadia game port', 'brickadia-server', 'udp', ports.brickadia, {
      requiredForStackStart: true,
      nextAction: 'start-stack',
    }),
    portTarget('omegga-web', 'Omegga web and metrics port', 'omegga-runtime', 'tcp', ports.omeggaWeb, {
      requiredForStackStart: true,
      nextAction: 'start-stack',
    }),
    portTarget('bmf-socket', 'BMF socket broker port', 'bmf-native-socket', 'tcp', ports.bmfSocket, {
      enabled: bmfSocketPort > 0,
      requiredForStackStart: bmfSocketPort > 0,
      nextAction: 'start-stack',
    }),
    portTarget('alloy-ready', 'Grafana Alloy readiness port', 'grafana-alloy', 'tcp', ports.alloyReady, {
      enabled: telemetryEnabled,
      requiredForTelemetryStart: telemetryEnabled,
      nextAction: 'configure-telemetry',
    }),
  ];
}

function buildServiceDiagnostics(profile = {}, options = {}) {
  const portInspection = normalizePortInspection(options.portInspection || options);
  const targets = options.targets || getConfiguredPortTargets(profile);
  const ports = targets.map(target => diagnosePortTarget(target, portInspection));
  const stackBlockers = ports.filter(port => port.status === 'in-use' && port.requiredForStackStart);
  const telemetryBlockers = ports.filter(port => port.status === 'in-use' && port.requiredForTelemetryStart);
  const unknownRequired = ports.filter(port =>
    port.status === 'unknown' && (port.requiredForStackStart || port.requiredForTelemetryStart));
  const startReadiness = summarizeStartReadiness(stackBlockers, telemetryBlockers, unknownRequired);

  return {
    schemaVersion: 1,
    backend: profile.backend || 'local-process',
    inspectedAt: portInspection.inspectedAt || null,
    platform: portInspection.platform || process.platform,
    startReadiness,
    ports,
    guardrails: SERVICE_DIAGNOSTIC_GUARDRAILS,
    errors: portInspection.errors,
  };
}

function portTarget(id, label, component, protocol, port, options = {}) {
  const normalizedPort = numericPort(port);
  const enabled = options.enabled !== false && normalizedPort > 0;
  return {
    id,
    label,
    component,
    protocol,
    port: normalizedPort,
    enabled,
    requiredForStackStart: Boolean(options.requiredForStackStart),
    requiredForTelemetryStart: Boolean(options.requiredForTelemetryStart),
    nextAction: options.nextAction || null,
  };
}

async function inspectConfiguredPorts(profile = {}, options = {}) {
  const targets = (options.targets || getConfiguredPortTargets(profile)).filter(target => target.enabled);
  if (targets.length === 0) {
    return inspectedPortResult({
      platform: process.platform,
      targetIdsInspected: [],
      snapshots: [],
      errors: [],
    });
  }

  if (process.platform === 'win32') {
    return inspectWindowsPorts(targets, options);
  }

  return inspectTcpPorts(targets, options);
}

function diagnosePortTarget(target, inspection) {
  if (!target.enabled) {
    return {
      ...target,
      status: 'not-configured',
      summary: `${target.label} is not enabled for this profile.`,
      owner: null,
      ownerSummary: null,
      evidence: [],
      startImpact: 'none',
    };
  }

  const inspected = isTargetInspected(target, inspection);
  if (!inspected) {
    return {
      ...target,
      status: 'unknown',
      summary: `${target.label} was not inspected in this health pass.`,
      owner: null,
      ownerSummary: null,
      evidence: [formatPort(target)],
      startImpact: 'unknown',
    };
  }

  const snapshot = findSnapshot(target, inspection.snapshots);
  if (!snapshot) {
    return {
      ...target,
      status: 'available',
      summary: `${target.label} appears available before launch.`,
      owner: null,
      ownerSummary: null,
      evidence: [formatPort(target)],
      startImpact: 'none',
    };
  }

  const owner = normalizeOwner(snapshot);
  const ownerSummary = summarizeOwner(owner);
  const impact = target.requiredForStackStart
    ? 'blocks-stack-start'
    : target.requiredForTelemetryStart
      ? 'blocks-telemetry-start'
      : 'none';

  return {
    ...target,
    status: 'in-use',
    state: snapshot.state || null,
    summary: ownerSummary
      ? `${target.label} is already in use by ${ownerSummary}.`
      : `${target.label} is already in use.`,
    owner,
    ownerSummary,
    evidence: compact([formatPort(target), ownerSummary]),
    startImpact: impact,
  };
}

function summarizeStartReadiness(stackBlockers, telemetryBlockers, unknownRequired) {
  if (stackBlockers.length > 0) {
    return {
      status: 'blocked',
      summary: `${stackBlockers.length} required stack port(s) are already in use.`,
      blockers: stackBlockers.map(blockerSummary),
      warnings: telemetryBlockers.map(blockerSummary),
    };
  }
  if (telemetryBlockers.length > 0) {
    return {
      status: 'degraded',
      summary: `${telemetryBlockers.length} telemetry port(s) are already in use.`,
      blockers: [],
      warnings: telemetryBlockers.map(blockerSummary),
    };
  }
  if (unknownRequired.length > 0) {
    return {
      status: 'unknown',
      summary: `${unknownRequired.length} required port(s) were not inspected.`,
      blockers: [],
      warnings: unknownRequired.map(blockerSummary),
    };
  }
  return {
    status: 'ready',
    summary: 'Configured ports appear ready for launch.',
    blockers: [],
    warnings: [],
  };
}

function blockerSummary(port) {
  return {
    id: `${port.id}-port`,
    portId: port.id,
    component: port.component,
    protocol: port.protocol,
    port: port.port,
    status: port.status,
    summary: port.summary,
    owner: port.owner,
    nextAction: port.nextAction,
  };
}

function normalizePortInspection(input = {}) {
  const snapshots = Array.isArray(input.snapshots)
    ? input.snapshots
    : Array.isArray(input.portSnapshots)
      ? input.portSnapshots
      : [];
  const targetIdsInspected = Array.isArray(input.targetIdsInspected)
    ? input.targetIdsInspected.map(String)
    : null;
  return {
    inspected: Boolean(input.inspected),
    inspectedAt: input.inspectedAt || null,
    platform: input.platform || process.platform,
    targetIdsInspected,
    snapshots: snapshots.map(normalizeSnapshot).filter(Boolean),
    errors: Array.isArray(input.errors) ? input.errors.map(String) : [],
  };
}

function normalizeSnapshot(input) {
  if (!input) return null;
  const port = numericPort(input.port || input.localPort);
  const protocol = String(input.protocol || '').toLowerCase();
  if (!port || !protocol) return null;
  return {
    id: input.id || input.portId || null,
    protocol,
    port,
    status: input.status || 'in-use',
    state: input.state || null,
    owningProcess: input.owningProcess || input.pid || input.owner?.pid || null,
    processName: input.processName || input.owner?.processName || null,
    processPath: input.processPath || input.owner?.path || null,
  };
}

function isTargetInspected(target, inspection) {
  if (inspection.targetIdsInspected) return inspection.targetIdsInspected.includes(target.id);
  return Boolean(inspection.inspected);
}

function findSnapshot(target, snapshots) {
  return snapshots.find(snapshot =>
    (snapshot.id ? snapshot.id === target.id : true)
    && snapshot.protocol === target.protocol
    && snapshot.port === target.port
    && snapshot.status !== 'available');
}

function normalizeOwner(snapshot) {
  if (!snapshot.owningProcess && !snapshot.processName && !snapshot.processPath) return null;
  return {
    pid: snapshot.owningProcess ? Number(snapshot.owningProcess) : null,
    processName: snapshot.processName || null,
    path: snapshot.processPath || null,
  };
}

function summarizeOwner(owner) {
  if (!owner) return null;
  const name = owner.processName || 'process';
  return owner.pid ? `${name} pid=${owner.pid}` : name;
}

function formatPort(target) {
  return `${target.protocol.toUpperCase()} ${target.port}`;
}

function inspectedPortResult({ platform, targetIdsInspected, snapshots, errors }) {
  return {
    inspected: errors.length === 0,
    inspectedAt: new Date().toISOString(),
    platform,
    targetIdsInspected,
    snapshots,
    errors,
    guardrails: SERVICE_DIAGNOSTIC_GUARDRAILS,
  };
}

function inspectWindowsPorts(targets, options = {}) {
  return new Promise(resolve => {
    const script = buildWindowsPortScript(targets);
    const timeoutMs = Math.max(500, Number(options.timeoutMs) || 5000);
    childProcess.execFile(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { timeout: timeoutMs, windowsHide: true, maxBuffer: 1024 * 256 },
      (error, stdout, stderr) => {
        if (error) {
          resolve(inspectedPortResult({
            platform: 'win32',
            targetIdsInspected: [],
            snapshots: [],
            errors: compact([error.message, stderr && String(stderr).trim()]),
          }));
          return;
        }
        resolve(inspectedPortResult({
          platform: 'win32',
          targetIdsInspected: targets.map(target => target.id),
          snapshots: parseJsonArray(stdout),
          errors: [],
        }));
      },
    );
  });
}

function buildWindowsPortScript(targets) {
  const rows = targets.map(target =>
    `[pscustomobject]@{Id=${psQuote(target.id)};Protocol=${psQuote(target.protocol)};Port=${target.port}}`);
  return `
$targets = @(${rows.join(',')})
$rows = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
  if ($target.Protocol -eq 'tcp') {
    $connections = @(Get-NetTCPConnection -LocalPort $target.Port -State Listen -ErrorAction SilentlyContinue)
  } else {
    $connections = @(Get-NetUDPEndpoint -LocalPort $target.Port -ErrorAction SilentlyContinue)
  }
  foreach ($connection in $connections) {
    $pidValue = [int]$connection.OwningProcess
    $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    $state = $null
    if ($connection.PSObject.Properties.Name -contains 'State') { $state = [string]$connection.State }
    $processName = $null
    $processPath = $null
    if ($proc) {
      $processName = [string]$proc.ProcessName
      $processPath = [string]$proc.Path
    }
    $rows.Add([ordered]@{
      id = [string]$target.Id
      protocol = [string]$target.Protocol
      port = [int]$target.Port
      status = 'in-use'
      state = $state
      owningProcess = $pidValue
      processName = $processName
      processPath = $processPath
    })
  }
}
$rows | ConvertTo-Json -Depth 6 -Compress
`.trim();
}

function inspectTcpPorts(targets, options = {}) {
  const timeoutMs = Math.max(100, Number(options.timeoutMs) || 350);
  const tcpTargets = targets.filter(target => target.protocol === 'tcp');
  return Promise.all(tcpTargets.map(target => probeTcpListener(target, timeoutMs)))
    .then(results => inspectedPortResult({
      platform: process.platform,
      targetIdsInspected: tcpTargets.map(target => target.id),
      snapshots: results.filter(Boolean),
      errors: targets.some(target => target.protocol !== 'tcp')
        ? ['UDP port ownership is only inspected on Windows.']
        : [],
    }));
}

function probeTcpListener(target, timeoutMs) {
  return new Promise(resolve => {
    const socket = net.createConnection({ host: '127.0.0.1', port: target.port });
    let settled = false;
    const settle = result => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeoutMs);
    socket.on('connect', () => settle({
      id: target.id,
      protocol: target.protocol,
      port: target.port,
      status: 'in-use',
      state: 'listening',
    }));
    socket.on('timeout', () => settle(null));
    socket.on('error', () => settle(null));
  });
}

function parseJsonArray(stdout) {
  const text = String(stdout || '').trim();
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    return [];
  }
}

function numericPort(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) return 0;
  return parsed;
}

function psQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function compact(items) {
  return items.filter(item => item !== undefined && item !== null && item !== '');
}

module.exports = {
  SERVICE_DIAGNOSTIC_GUARDRAILS,
  buildServiceDiagnostics,
  getConfiguredPortTargets,
  inspectConfiguredPorts,
};
