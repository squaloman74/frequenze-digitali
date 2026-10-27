'use strict';

const { app, BrowserWindow, Menu, session, ipcMain, shell, dialog } = require('electron');
const { spawn, spawnSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const packageJson = require('./package.json');
const { createIntegrityManifest } = require('./export_manifest');

// --- Configurazione -------------------------------------------------------
// Avvio automatico del backend Python (opt-in): FD_SPAWN_BACKEND=1
// Interprete: FD_PYTHON. FD_UPDATE_URL punta a un JSON HTTPS con version e url.
const AUTOSTART_BACKEND = process.env.FD_SPAWN_BACKEND === '1';
const PROJECT_ROOT = path.resolve(__dirname, '..');
const PYTHON = process.env.FD_PYTHON
  || (process.platform === 'win32'
    ? path.join(PROJECT_ROOT, '.venv', 'Scripts', 'python.exe')
    : path.join(PROJECT_ROOT, '.venv', 'bin', 'python'));
const BACKEND_ENTRY = process.env.FD_BACKEND_ENTRY
  ? path.resolve(process.env.FD_BACKEND_ENTRY)
  : path.join(PROJECT_ROOT, 'main.py');

let mainWindow = null;
let backend = null;
let licensePath = null;

function runLicenseCommand(args) {
  const result = spawnSync(PYTHON, ['-m', 'core.license_guard', ...args], {
    cwd: PROJECT_ROOT,
    encoding: 'utf8',
    timeout: 15000,
    windowsHide: true,
    maxBuffer: 64 * 1024,
  });
  if (result.error) {
    throw new Error(`Impossibile avviare Python (${PYTHON}): ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || 'Verifica licenza non riuscita').trim());
  }
  return (result.stdout || '').trim();
}

function getLicenseStatus() {
  licensePath = path.join(app.getPath('userData'), 'license.key');
  if (!fs.existsSync(licensePath)) {
    return { valid: false, message: 'Attivazione richiesta per questo dispositivo.' };
  }
  try {
    runLicenseCommand(['--license', licensePath]);
    return { valid: true };
  } catch (error) {
    return { valid: false, message: error.message };
  }
}

function getHardwareId() {
  return runLicenseCommand(['--hwid']);
}

async function exportTelemetryCsv(csv) {
  if (typeof csv !== 'string' || Buffer.byteLength(csv, 'utf8') > 32 * 1024 * 1024) {
    throw new Error('Il CSV non è valido o supera i 32 MB.');
  }
  const result = await dialog.showSaveDialog(mainWindow, {
    title: 'Esporta telemetria verificabile',
    defaultPath: `frequenze-digitali-${new Date().toISOString().replace(/[:.]/g, '-')}.csv`,
    filters: [{ name: 'CSV', extensions: ['csv'] }],
  });
  if (result.canceled || !result.filePath) return { cancelled: true };

  const hwid = getHardwareId();
  const integrity = createIntegrityManifest(csv, hwid);
  const manifest = JSON.stringify({
    ...integrity,
    data_file: path.basename(result.filePath),
  }, null, 2);
  const manifestPath = `${result.filePath}.sig`;
  const transactionId = crypto.randomUUID();
  const temporaryCsvPath = `${result.filePath}.${transactionId}.tmp`;
  const temporaryManifestPath = `${manifestPath}.${transactionId}.tmp`;
  const backupCsvPath = `${result.filePath}.${transactionId}.bak`;
  const backupManifestPath = `${manifestPath}.${transactionId}.bak`;
  let backedUpCsv = false;
  let backedUpManifest = false;
  let installedCsv = false;
  let installedManifest = false;

  try {
    fs.writeFileSync(temporaryCsvPath, csv, { encoding: 'utf8', flag: 'wx' });
    fs.writeFileSync(temporaryManifestPath, `${manifest}\n`, { encoding: 'utf8', flag: 'wx' });

    if (fs.existsSync(result.filePath)) {
      fs.renameSync(result.filePath, backupCsvPath);
      backedUpCsv = true;
    }
    if (fs.existsSync(manifestPath)) {
      fs.renameSync(manifestPath, backupManifestPath);
      backedUpManifest = true;
    }
    fs.renameSync(temporaryCsvPath, result.filePath);
    installedCsv = true;
    fs.renameSync(temporaryManifestPath, manifestPath);
    installedManifest = true;
  } catch (error) {
    const rollbackErrors = [];
    for (const [filePath, installed] of [
      [manifestPath, installedManifest],
      [result.filePath, installedCsv],
    ]) {
      if (installed) {
        try {
          fs.unlinkSync(filePath);
        } catch (rollbackError) {
          rollbackErrors.push(rollbackError);
        }
      }
    }
    for (const [backupPath, filePath, backedUp] of [
      [backupManifestPath, manifestPath, backedUpManifest],
      [backupCsvPath, result.filePath, backedUpCsv],
    ]) {
      if (backedUp) {
        try {
          fs.renameSync(backupPath, filePath);
        } catch (rollbackError) {
          rollbackErrors.push(rollbackError);
        }
      }
    }
    for (const temporaryPath of [temporaryCsvPath, temporaryManifestPath]) {
      if (fs.existsSync(temporaryPath)) {
        try {
          fs.unlinkSync(temporaryPath);
        } catch (rollbackError) {
          rollbackErrors.push(rollbackError);
        }
      }
    }
    if (rollbackErrors.length) {
      throw new AggregateError([error, ...rollbackErrors], 'Esportazione fallita e ripristino incompleto.');
    }
    throw error;
  }
  const cleanupErrors = [];
  for (const backupPath of [backupCsvPath, backupManifestPath]) {
    if (fs.existsSync(backupPath)) {
      try {
        fs.unlinkSync(backupPath);
      } catch (error) {
        cleanupErrors.push(error.message);
      }
    }
  }
  if (cleanupErrors.length) {
    throw new Error(`CSV e manifesto salvati, ma non è stato possibile rimuovere i backup: ${cleanupErrors.join('; ')}`);
  }
  return { cancelled: false, csvPath: result.filePath, manifestPath, sha256: integrity.sha256 };
}

function activateLicenseText(licenseText) {
  if (typeof licenseText !== 'string' || !licenseText.trim()) {
    return { success: false, message: 'Incolla la chiave di licenza per continuare.' };
  }
  if (Buffer.byteLength(licenseText, 'utf8') > 64 * 1024) {
    return { success: false, message: 'La chiave di licenza supera la dimensione consentita.' };
  }

  const userDataPath = app.getPath('userData');
  licensePath = path.join(userDataPath, 'license.key');
  fs.mkdirSync(userDataPath, { recursive: true });
  const temporaryPath = path.join(userDataPath, `.license-${crypto.randomUUID()}.tmp`);

  try {
    fs.writeFileSync(temporaryPath, licenseText.trim(), { encoding: 'utf8', flag: 'wx' });
    runLicenseCommand(['--license', temporaryPath]);
    fs.renameSync(temporaryPath, licensePath);
    startBackend();
    return { success: true };
  } catch (error) {
    return { success: false, message: error.message };
  } finally {
    if (fs.existsSync(temporaryPath)) fs.unlinkSync(temporaryPath);
  }
}

async function activateLicenseFile() {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: 'Seleziona la licenza Frequenze Digitali',
    properties: ['openFile'],
    filters: [
      { name: 'Licenza Frequenze Digitali', extensions: ['key', 'json'] },
      { name: 'Tutti i file', extensions: ['*'] },
    ],
  });
  if (result.canceled || !result.filePaths.length) return { cancelled: true };

  const licenseText = fs.readFileSync(result.filePaths[0], 'utf8');
  const activation = activateLicenseText(licenseText);
  return { ...activation, cancelled: false };
}

function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(value);
  if (!match) return null;
  return {
    core: match.slice(1, 4).map(Number),
    prerelease: match[4] ? match[4].split('.') : null,
  };
}

function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a || !b) throw new Error('Versione non valida nel file aggiornamenti.');
  for (let index = 0; index < 3; index += 1) {
    if (a.core[index] !== b.core[index]) return a.core[index] > b.core[index] ? 1 : -1;
  }
  if (a.prerelease === null || b.prerelease === null) {
    if (a.prerelease === b.prerelease) return 0;
    return a.prerelease === null ? 1 : -1;
  }
  for (let index = 0; index < Math.max(a.prerelease.length, b.prerelease.length); index += 1) {
    if (a.prerelease[index] === undefined) return -1;
    if (b.prerelease[index] === undefined) return 1;
    const aNumber = /^\d+$/.test(a.prerelease[index]);
    const bNumber = /^\d+$/.test(b.prerelease[index]);
    if (aNumber && bNumber) {
      const difference = Number(a.prerelease[index]) - Number(b.prerelease[index]);
      if (difference !== 0) return difference > 0 ? 1 : -1;
    } else if (aNumber !== bNumber) {
      return aNumber ? -1 : 1;
    } else if (a.prerelease[index] !== b.prerelease[index]) {
      return a.prerelease[index] > b.prerelease[index] ? 1 : -1;
    }
  }
  return 0;
}

function fetchUpdateManifest(updateUrl) {
  return new Promise((resolve, reject) => {
    const request = https.get(updateUrl, { timeout: 10000 }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`Il server aggiornamenti ha risposto con HTTP ${response.statusCode}.`));
        return;
      }
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        body += chunk;
        if (body.length > 64 * 1024) {
          request.destroy(new Error('Il file aggiornamenti supera la dimensione consentita.'));
        }
      });
      response.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error('Il file aggiornamenti non contiene JSON valido.'));
        }
      });
    });
    request.on('timeout', () => request.destroy(new Error('Timeout durante la ricerca aggiornamenti.')));
    request.on('error', reject);
  });
}

async function checkForUpdates() {
  const configuredUrl = process.env.FD_UPDATE_URL;
  if (!configuredUrl) {
    return { status: 'unconfigured', message: 'Ricerca aggiornamenti non configurata (FD_UPDATE_URL).' };
  }

  let updateUrl;
  try {
    updateUrl = new URL(configuredUrl);
  } catch {
    return { status: 'error', message: 'FD_UPDATE_URL non è un URL valido.' };
  }
  if (updateUrl.protocol !== 'https:' || updateUrl.username || updateUrl.password) {
    return { status: 'error', message: 'La sorgente aggiornamenti deve usare un URL HTTPS valido.' };
  }

  try {
    const manifest = await fetchUpdateManifest(updateUrl);
    if (!manifest || typeof manifest.version !== 'string' || !parseVersion(manifest.version)) {
      throw new Error('Il file aggiornamenti deve indicare una versione semantica, ad esempio 26.0.1-beta.1.');
    }
    const releaseUrl = typeof manifest.url === 'string' ? new URL(manifest.url) : null;
    if (releaseUrl && (releaseUrl.protocol !== 'https:' || releaseUrl.username || releaseUrl.password)) {
      throw new Error('L’URL della release deve usare HTTPS.');
    }
    const comparison = compareVersions(manifest.version, packageJson.version);
    if (comparison > 0) {
      return { status: 'available', version: manifest.version, url: releaseUrl?.href || null };
    }
    return { status: 'current', version: packageJson.version };
  } catch (error) {
    return { status: 'error', message: error.message };
  }
}

function registerLicenseHandlers() {
  ipcMain.handle('license:status', () => ({
    ...getLicenseStatus(),
    requireActivation: !app.isPackaged,
  }));
  ipcMain.handle('license:hwid', () => getHardwareId());
  ipcMain.handle('license:activate', (_event, licenseText) => activateLicenseText(licenseText));
  ipcMain.handle('license:activate-file', () => activateLicenseFile());
  ipcMain.handle('telemetry:export-csv', (_event, csv) => exportTelemetryCsv(csv));
  ipcMain.handle('updates:check', () => checkForUpdates());
  ipcMain.handle('updates:open-release', async (_event, releaseUrl) => {
    let url;
    try {
      url = new URL(releaseUrl);
    } catch {
      throw new Error('URL della release non valido.');
    }
    if (url.protocol !== 'https:' || url.username || url.password) {
      throw new Error('La pagina della release deve usare un URL HTTPS valido.');
    }
    await shell.openExternal(url.href);
  });
}

function startBackend() {
  if (!AUTOSTART_BACKEND || backend) return;
  if (!licensePath || !fs.existsSync(licensePath)) return;
  backend = spawn(PYTHON, [BACKEND_ENTRY], {
    cwd: PROJECT_ROOT,
    windowsHide: true,
    env: { ...process.env, FD_LICENSE_FILE: licensePath },
  });
  backend.stdout.on('data', (d) => process.stdout.write(`[py] ${d}`));
  backend.stderr.on('data', (d) => process.stderr.write(`[py] ${d}`));
  backend.on('error', (err) => {
    console.error('[backend] avvio fallito:', err.message);
    backend = null;
  });
  backend.on('exit', (code) => {
    console.log(`[backend] terminato (codice ${code})`);
    backend = null;
  });
}

function stopBackend() {
  if (backend) {
    backend.kill();
    backend = null;
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 900,
    minHeight: 640,
    backgroundColor: '#0e0e10',
    icon: path.join(
      __dirname,
      'assets',
      process.platform === 'win32' ? 'frequenze-digitali.ico' : 'lorenz-circle.png',
    ),
    title: 'Frequenze Digitali',
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  mainWindow.once('ready-to-show', () => mainWindow.show());
  mainWindow.loadFile(path.join(__dirname, 'index.html'));

  // Nessuna navigazione o finestra esterna dal renderer.
  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.webContents.on('will-navigate', (e) => e.preventDefault());

  mainWindow.on('closed', () => { mainWindow = null; });
}

app.whenReady().then(() => {
  // Il renderer non ha bisogno di permessi (camera, notifiche, ecc.).
  session.defaultSession.setPermissionRequestHandler((_wc, _perm, cb) => cb(false));

  if (app.isPackaged) Menu.setApplicationMenu(null); // in sviluppo resta DevTools (Ctrl+Shift+I)

  registerLicenseHandlers();
  if (getLicenseStatus().valid && app.isPackaged) startBackend();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('before-quit', stopBackend);
app.on('window-all-closed', () => {
  stopBackend();
  if (process.platform !== 'darwin') app.quit();
});
