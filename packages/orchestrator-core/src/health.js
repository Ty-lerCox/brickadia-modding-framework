const HEALTH_RANK = {
  healthy: 0,
  unknown: 1,
  degraded: 2,
  unhealthy: 3,
};

function statusFromObservation(check, observation = {}) {
  if (observation.status) return observation.status;
  if (observation.healthy === true) return 'healthy';
  if (observation.healthy === false) {
    return check.severity === 'optional' || check.severity === 'degraded-ok'
      ? 'degraded'
      : 'unhealthy';
  }
  return 'unknown';
}

function buildServiceHealth(manifest, observations = {}) {
  const checks = (manifest.healthChecks || []).map(check => {
    const observation = observations[check.id] || {};
    const status = statusFromObservation(check, observation);
    return {
      id: check.id,
      component: check.component,
      severity: check.severity,
      status,
      healthyWhen: check.healthyWhen,
      summary: observation.summary || check.healthyWhen,
      evidence: observation.evidence || [],
      nextAction: observation.nextAction || null,
    };
  });

  const status = checks.reduce((current, check) => {
    return HEALTH_RANK[check.status] > HEALTH_RANK[current] ? check.status : current;
  }, 'healthy');

  return {
    status,
    summary: summarizeHealth(checks),
    checks,
  };
}

function summarizeHealth(checks) {
  return checks.reduce(
    (summary, check) => {
      summary[check.status] = (summary[check.status] || 0) + 1;
      return summary;
    },
    { healthy: 0, degraded: 0, unhealthy: 0, unknown: 0 },
  );
}

module.exports = {
  buildServiceHealth,
  statusFromObservation,
  summarizeHealth,
};
