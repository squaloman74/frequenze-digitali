'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('fdLicense', {
  status: () => ipcRenderer.invoke('license:status'),
  getHardwareId: () => ipcRenderer.invoke('license:hwid'),
  activate: (licenseText) => ipcRenderer.invoke('license:activate', licenseText),
  activateFromFile: () => ipcRenderer.invoke('license:activate-file'),
});

contextBridge.exposeInMainWorld('fdUpdates', {
  check: () => ipcRenderer.invoke('updates:check'),
  openRelease: (url) => ipcRenderer.invoke('updates:open-release', url),
});

contextBridge.exposeInMainWorld('fdTelemetry', {
  exportCsv: (csv) => ipcRenderer.invoke('telemetry:export-csv', csv),
});
