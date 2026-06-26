const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('bmfDesktop', {
  getBootstrapPlan(input) {
    return ipcRenderer.invoke('bmf:bootstrap-plan', input);
  },
  getProfiles(input) {
    return ipcRenderer.invoke('bmf:profiles-list', input);
  },
  saveProfile(input) {
    return ipcRenderer.invoke('bmf:profile-save', input);
  },
  selectProfile(profileId, input) {
    return ipcRenderer.invoke('bmf:profile-select', profileId, input);
  },
  chooseProfilePath(field, input) {
    return ipcRenderer.invoke('bmf:choose-path', {
      ...(input || {}),
      field,
    });
  },
  setupProfileFromBrickadiaInstall(input) {
    return ipcRenderer.invoke('bmf:profile-from-brickadia-install', input);
  },
  getOperationPlan(operationId, input) {
    return ipcRenderer.invoke('bmf:operation-plan', operationId, input);
  },
  getOperationTransaction(operationId, input) {
    return ipcRenderer.invoke('bmf:operation-transaction', operationId, input);
  },
  applyOperationTransaction(operationId, input) {
    return ipcRenderer.invoke('bmf:operation-transaction', operationId, {
      ...(input || {}),
      apply: true,
    });
  },
  getRollbackTransaction(input) {
    return ipcRenderer.invoke('bmf:rollback-transaction', input);
  },
  applyRollbackTransaction(input) {
    return ipcRenderer.invoke('bmf:rollback-transaction', {
      ...(input || {}),
      apply: true,
    });
  },
  getServiceAction(actionId, input) {
    return ipcRenderer.invoke('bmf:service-action', actionId, input);
  },
  applyServiceAction(actionId, input) {
    return ipcRenderer.invoke('bmf:service-action', actionId, {
      ...(input || {}),
      apply: true,
    });
  },
  getUpdateCheck(input) {
    return ipcRenderer.invoke('bmf:update-check', input);
  },
  getUpdatePlan(input) {
    return ipcRenderer.invoke('bmf:update-plan', input);
  },
  downloadUpdate(input) {
    return ipcRenderer.invoke('bmf:update-download', input);
  },
  getUpdateInstallPlan(input) {
    return ipcRenderer.invoke('bmf:update-install-plan', input);
  },
  launchUpdateInstaller(input) {
    return ipcRenderer.invoke('bmf:update-install-handoff', input);
  },
  getProfileHealth(input) {
    return ipcRenderer.invoke('bmf:profile-health', input);
  },
  getTelemetryPlan(input) {
    return ipcRenderer.invoke('bmf:telemetry-plan', input);
  },
  writeTelemetryAlloyConfig(input) {
    return ipcRenderer.invoke('bmf:telemetry-alloy-write', input);
  },
  getDashboardImportPlan(input) {
    return ipcRenderer.invoke('bmf:dashboard-import-plan', input);
  },
  writeDashboardImportPayload(input) {
    return ipcRenderer.invoke('bmf:dashboard-import-payload', input);
  },
  uploadDashboardImport(input) {
    return ipcRenderer.invoke('bmf:dashboard-import-upload', input);
  },
  getTrafficSnapshot(input) {
    return ipcRenderer.invoke('bmf:traffic-snapshot', input);
  },
  exportTrafficTrace(input) {
    return ipcRenderer.invoke('bmf:traffic-export', input);
  },
  getLogSnapshot(input) {
    return ipcRenderer.invoke('bmf:log-snapshot', input);
  },
  getTroubleshootingSnapshot(input) {
    return ipcRenderer.invoke('bmf:troubleshooting-snapshot-plan', input);
  },
  writeTroubleshootingSnapshot(input) {
    return ipcRenderer.invoke('bmf:troubleshooting-snapshot-write', input);
  },
  openExternal(url) {
    return ipcRenderer.invoke('bmf:open-external', url);
  },
});
