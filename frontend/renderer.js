'use strict';

/* ==========================================================================
   Frequenze Digitali — renderer
   Riceve frame JSON via WebSocket dal backend Python e li disegna su canvas.

   Formato frame (tutti i campi sono opzionali tranne `freq`):
   {
     "schema_version": 1,
     "t": 1739999999.123,                       // epoch in secondi
     "source": "live" | "simulated",
     "freq": 432.17,                            // Hz
     "attractor": { "x": 1.2, "y": -3.4, "z": 20.1 },
     "sensors":   { "mic_db": -42.3, "mag_ut": null, "entropy": null },
     "status":    { "sync": "normal" | "anomaly", "calibrated": false },
     "provenance": {
       "freq": "derived",
       "attractor": "derived",
       "sensors": { "mic_db": "measured", "mag_ut": "unavailable", "entropy": "unavailable" },
       "status": { "sync": "derived", "calibrated": "unavailable" }
     },
     "samples": [ ... ],                        // blocco PCM float -1..1
     "sample_rate": 44100,
     "spectrum": [ ... ],                       // magnitudi 0..1 (se assente: FFT locale dei samples)
     "event": { "type": "anomaly", "msg": "..." }
   }
   ========================================================================== */

const CONFIG = {
  wsUrl: localStorage.getItem('fd.wsUrl') || 'ws://127.0.0.1:8765',
  reconnectMinMs: 1000,
  reconnectMaxMs: 5000,
  staleMs: 2000,           // nessun frame oltre questo limite => "nessun dato"
  freqHistoryLen: 600,     // punti nel grafico frequenza/tempo
  waveLen: 1024,           // campioni mostrati e usati per la FFT (potenza di 2)
  logMax: 500,
  anomaly: {
    dFreqHz: (() => {
      const saved = Number(localStorage.getItem('fd.dFreqHz'));
      return Number.isFinite(saved) && saved >= 1 && saved <= 450 ? saved : 25;
    })(),
    entropyMax: 0.85,      // soglia indice di entropia
  },
};

const COLORS = {
  bg: '#0e0e10', data: '#00ffcc', signal: '#ff0055', warn: '#ffaa00',
  grid: 'rgba(0,255,204,0.12)', gridStrong: 'rgba(0,255,204,0.28)', muted: '#6f777a',
};

const $ = (id) => document.getElementById(id);
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

/* ---------- Stato ---------- */
const S = {
  mode: 'freq',
  source: 'offline',            // 'offline' | 'live' | 'sim'
  lastFrameAt: 0,
  lastFreq: null,
  hist: [],                     // { t, f }
  wave: new Float32Array(CONFIG.waveLen),
  waveFill: 0,
  sampleRate: 44100,
  logRows: [],                  // per export CSV
  logPaused: false,
  frameSource: 'unavailable',
  schemaVersion: '',
  provenance: {},
  telemetry: {},
  calibration: {},
  interference: {},
  attractor: {},
  lastDelta: null,
  lastFreqAnomalyAt: 0,
};

/* ==========================================================================
   Log
   ========================================================================== */
const logEl = $('log');

function fmtTime(ms) {
  const d = new Date(ms);
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

const PROVENANCE_VALUES = new Set(['live', 'measured', 'derived', 'unavailable', 'simulated']);
const ORIGIN_LABELS = {
  live: 'Misurato',
  measured: 'Misurato',
  derived: 'Derivato',
  unavailable: 'Non disponibile',
  simulated: 'Simulato',
};

function originFor(field) {
  let origin;
  if (field.startsWith('sensors.')) {
    origin = S.provenance.sensors && S.provenance.sensors[field.slice(8)];
  } else if (field.startsWith('status.')) {
    origin = S.provenance.status && S.provenance.status[field.slice(7)];
  } else {
    origin = S.provenance[field];
  }
  if (PROVENANCE_VALUES.has(origin)) return origin;
  return S.frameSource === 'simulated' ? 'simulated' : 'unavailable';
}

function addOriginBadge(element, origin) {
  if (!element) return;
  let badge = element.querySelector('.origin-badge');
  if (!badge) {
    badge = document.createElement('span');
    badge.className = 'origin-badge';
    element.appendChild(badge);
  }
  badge.className = `origin-badge origin-${origin}`;
  badge.textContent = ORIGIN_LABELS[origin] || ORIGIN_LABELS.unavailable;
}

function provenanceColumns() {
  return {
    schema_version: S.schemaVersion,
    source: S.frameSource,
    freq_origin: originFor('freq'),
    attractor_origin: originFor('attractor'),
    mic_db_origin: originFor('sensors.mic_db'),
    mic_db_corrected_origin: originFor('sensors.mic_db_corrected'),
    mag_ut_origin: originFor('sensors.mag_ut'),
    mag_ut_corrected_origin: originFor('sensors.mag_ut_corrected'),
    entropy_origin: originFor('sensors.entropy'),
    sync_origin: originFor('status.sync'),
    calibration_origin: originFor('status.calibrated'),
    baseline_audio_dbfs: isNum(S.calibration.baseline_audio) ? S.calibration.baseline_audio : '',
    mic_db_corrected: isNum(S.telemetry.mic_db_corrected) ? S.telemetry.mic_db_corrected : '',
    baseline_mag_ut: isNum(S.calibration.baseline_mag) ? S.calibration.baseline_mag : '',
    calibration_completed_at: S.calibration.completed_at || '',
    interference_50_60hz: S.interference.detected === true,
    interference_frequencies_hz: Array.isArray(S.interference.frequencies_hz)
      ? S.interference.frequencies_hz.join(';')
      : '',
  };
}

function originSummary() {
  const sourceLabel = S.frameSource === 'live'
    ? 'live'
    : S.frameSource === 'simulated' ? 'simulated' : 'unavailable';
  return `source=${sourceLabel}; freq=${originFor('freq')}; attractor=${originFor('attractor')}; ` +
    `mic=${originFor('sensors.mic_db')}; mag=${originFor('sensors.mag_ut')}; ` +
    `entropy=${originFor('sensors.entropy')}`;
}

function addLog(type, msg, { freq = null, delta = null, ts = Date.now(), cls = '' } = {}) {
  const fStr = isNum(freq) ? `${freq.toFixed(2)} Hz` : '';
  const dStr = isNum(delta) ? `${delta >= 0 ? '+' : ''}${delta.toFixed(2)} Hz` : '';
  const messageWithOrigin = `${msg} [${originSummary()}]`;

  const row = document.createElement('div');
  row.className = `log-row ${cls}`.trim();
  for (const [c, text] of [['log-time', fmtTime(ts)], ['log-type', type], ['log-freq', fStr], ['log-delta', dStr], ['log-msg', messageWithOrigin]]) {
    const s = document.createElement('span');
    s.className = c;
    s.textContent = text;
    row.appendChild(s);
  }

  const stick = logEl.scrollTop + logEl.clientHeight >= logEl.scrollHeight - 24;
  logEl.appendChild(row);
  S.logRows.push({
    ora: fmtTime(ts),
    tipo: type,
    frequenza: fStr,
    variazione: dStr,
    x: isNum(S.attractor.x) ? S.attractor.x : '',
    y: isNum(S.attractor.y) ? S.attractor.y : '',
    z: isNum(S.attractor.z) ? S.attractor.z : '',
    mic_db: isNum(S.telemetry.mic_db) ? S.telemetry.mic_db : '',
    mic_db_corrected: isNum(S.telemetry.mic_db_corrected) ? S.telemetry.mic_db_corrected : '',
    mag_ut: isNum(S.telemetry.mag_ut) ? S.telemetry.mag_ut : '',
    mag_ut_corrected: isNum(S.telemetry.mag_ut_corrected) ? S.telemetry.mag_ut_corrected : '',
    entropy: isNum(S.telemetry.entropy) ? S.telemetry.entropy : '',
    messaggio: msg,
    ...provenanceColumns(),
  });

  while (logEl.childElementCount > CONFIG.logMax) logEl.firstElementChild.remove();
  if (S.logRows.length > CONFIG.logMax) S.logRows.splice(0, S.logRows.length - CONFIG.logMax);

  if (!S.logPaused && stick) logEl.scrollTop = logEl.scrollHeight;
  $('log-count').textContent = `${S.logRows.length} eventi`;
}

$('btn-clear').addEventListener('click', () => {
  logEl.replaceChildren();
  S.logRows.length = 0;
  $('log-count').textContent = '0 eventi';
});

$('btn-pause').addEventListener('click', (e) => {
  S.logPaused = !S.logPaused;
  e.currentTarget.classList.toggle('is-on', S.logPaused);
  e.currentTarget.textContent = S.logPaused ? 'Riprendi scorrimento' : 'Blocca scorrimento';
  if (!S.logPaused) logEl.scrollTop = logEl.scrollHeight;
});

$('btn-export').addEventListener('click', () => {
  exportTelemetry();
});

async function exportTelemetry() {
  const button = $('btn-export');
  if (!window.fdTelemetry) {
    addLog('ERRORE', 'Esportazione verificabile disponibile solo nell’app desktop.', { cls: 'is-error' });
    return;
  }
  const esc = (v) => `"${String(v).replace(/"/g, '""')}"`;
  const columns = [
    'ora', 'tipo', 'frequenza', 'variazione', 'x', 'y', 'z', 'mic_db',
    'mic_db_corrected', 'mag_ut', 'mag_ut_corrected', 'entropy',
    'messaggio', 'schema_version', 'source', 'freq_origin', 'attractor_origin',
    'mic_db_origin', 'mic_db_corrected_origin', 'mag_ut_origin',
    'mag_ut_corrected_origin', 'entropy_origin', 'sync_origin',
    'calibration_origin', 'baseline_audio_dbfs', 'baseline_mag_ut',
    'calibration_completed_at', 'interference_50_60hz', 'interference_frequencies_hz',
  ];
  const csv = [
    columns.map(esc).join(','),
    ...S.logRows.map((row) => columns.map((column) => esc(row[column] ?? '')).join(',')),
  ].join('\r\n');
  button.disabled = true;
  try {
    const result = await window.fdTelemetry.exportCsv(csv);
    if (!result.cancelled) {
      addLog('INFO', `CSV esportato con manifesto SHA-256: ${result.manifestPath}`, { cls: 'is-info' });
    }
  } catch (error) {
    addLog('ERRORE', `Esportazione CSV non riuscita: ${error.message}`, { cls: 'is-error' });
  } finally {
    button.disabled = false;
  }
}

/* ==========================================================================
   Pannello telemetria
   ========================================================================== */
function setText(id, v) { $(id).textContent = v; }

function speak(text) {
  if (!('speechSynthesis' in window) || !('SpeechSynthesisUtterance' in window)) {
    addLog('INFO', 'Sintesi vocale non disponibile in questo sistema', { cls: 'is-info' });
    return false;
  }
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = 'it-IT';
  utterance.rate = 1;
  utterance.pitch = 1;
  window.speechSynthesis.speak(utterance);
  return true;
}

function speakCurrentStatus() {
  if (!isNum(S.lastFreq)) {
    speak('Non sono ancora disponibili dati di telemetria.');
    return;
  }
  const change = isNum(S.lastDelta)
    ? `Variazione ${S.lastDelta >= 0 ? 'più' : 'meno'} ${Math.abs(S.lastDelta).toFixed(1)} hertz.`
    : '';
  const microphone = isNum(S.telemetry.mic_db)
    ? `Livello microfono ${S.telemetry.mic_db.toFixed(1)} d B F S.`
    : 'Livello microfono non disponibile.';
  speak(`Frequenza attuale ${S.lastFreq.toFixed(1)} hertz. ${change} ${microphone}`);
}

function speakAnomaly(freq, delta) {
  if (!$('voice-alerts').checked) return;
  const direction = delta >= 0 ? 'aumentata' : 'diminuita';
  speak(`Avviso. Variazione di frequenza oltre soglia: ${direction} di ${Math.abs(delta).toFixed(1)} hertz. Valore attuale ${freq.toFixed(1)} hertz.`);
}

const thresholdInput = $('anomaly-threshold');
thresholdInput.value = String(CONFIG.anomaly.dFreqHz);
thresholdInput.addEventListener('change', () => {
  const value = Number(thresholdInput.value);
  if (!Number.isFinite(value) || value < 1 || value > 450) {
    thresholdInput.value = String(CONFIG.anomaly.dFreqHz);
    return;
  }
  CONFIG.anomaly.dFreqHz = value;
  localStorage.setItem('fd.dFreqHz', String(value));
});

$('btn-speak').addEventListener('click', speakCurrentStatus);

function updateTelemetry(f) {
  const labels = {
    freq: $('v-freq').closest('.cell-label'),
    attractor: $('v-x').closest('.cell').querySelector('.cell-label'),
    mic_db: $('v-mic').closest('.cell-label'),
    mag_ut: $('v-mag').closest('.cell-label'),
    entropy: $('v-ent').closest('.cell-label'),
    sync: $('s-sync').closest('li'),
    calibrated: $('s-cal').closest('li'),
  };
  addOriginBadge(labels.freq, originFor('freq'));
  addOriginBadge(labels.attractor, originFor('attractor'));
  addOriginBadge(
    labels.mic_db,
    originFor(isNum(S.telemetry.mic_db_corrected) ? 'sensors.mic_db_corrected' : 'sensors.mic_db'),
  );
  addOriginBadge(labels.mag_ut, originFor('sensors.mag_ut'));
  addOriginBadge(labels.entropy, originFor('sensors.entropy'));
  addOriginBadge(labels.sync, originFor('status.sync'));
  addOriginBadge(labels.calibrated, originFor('status.calibrated'));

  if (isNum(f.freq)) {
    setText('v-freq', f.freq.toFixed(2));
    const d = S.lastFreq === null ? 0 : f.freq - S.lastFreq;
    setText('v-dfreq', `${d >= 0 ? '+' : ''}${d.toFixed(2)}`);
    $('v-dfreq').parentElement.classList.toggle('is-warn', Math.abs(d) > CONFIG.anomaly.dFreqHz);
  } else setText('v-freq', 'N/D');

  const a = f.attractor;
  S.attractor = a && typeof a === 'object' ? a : {};
  if (a) {
    if (isNum(a.x)) setText('v-x', a.x.toFixed(4));
    if (isNum(a.y)) setText('v-y', a.y.toFixed(4));
    if (isNum(a.z)) setText('v-z', a.z.toFixed(4));
  }
  if (!a || !isNum(a.x)) setText('v-x', 'N/D');
  if (!a || !isNum(a.y)) setText('v-y', 'N/D');
  if (!a || !isNum(a.z)) setText('v-z', 'N/D');

  const s = f.sensors;
  if (s) {
    const audioValue = isNum(s.mic_db_corrected) ? s.mic_db_corrected : s.mic_db;
    if (isNum(audioValue)) {
      setText('v-mic', audioValue.toFixed(1));
      $('mic-unit').textContent = isNum(s.mic_db_corrected) ? 'dBFS corretto' : 'dBFS';
    }
    if (isNum(s.mag_ut)) setText('v-mag', s.mag_ut.toFixed(2));
    if (isNum(s.entropy)) {
      setText('v-ent', s.entropy.toFixed(3));
      const hot = s.entropy > CONFIG.anomaly.entropyMax;
      $('v-ent').parentElement.classList.toggle('is-warn', hot);
      const m = $('m-ent');
      m.style.width = `${clamp(s.entropy, 0, 1) * 100}%`;
      m.classList.toggle('is-warn', hot);
    }
  }
  if (!s || (!isNum(s.mic_db) && !isNum(s.mic_db_corrected))) {
    setText('v-mic', 'N/D');
    $('mic-unit').textContent = 'dBFS';
  }
  if (!s || !isNum(s.mag_ut)) setText('v-mag', 'N/D');
  if (!s || !isNum(s.entropy)) {
    setText('v-ent', 'N/D');
    $('m-ent').style.width = '0%';
    $('m-ent').classList.remove('is-warn');
  }

  const st = f.status;
  if (st) {
    if (typeof st.sync === 'string') {
      const ok = st.sync.toLowerCase() === 'normal';
      setText('s-sync', ok ? 'Normale' : 'Anomala');
      $('led-sync').className = `led ${ok ? 'led-ok' : 'led-warn'}`;
    } else {
      setText('s-sync', 'Non disponibile');
      $('led-sync').className = 'led led-off';
    }
    const calibrationAvailable =
      st.calibrated === true && ['live', 'derived'].includes(originFor('status.calibrated'));
    setText('s-cal', calibrationAvailable ? 'Calibrati' : 'Non calibrati');
    $('led-cal').className = `led ${calibrationAvailable ? 'led-ok' : 'led-off'}`;
  } else {
    setText('s-sync', 'Non disponibile');
    $('led-sync').className = 'led led-off';
    setText('s-cal', 'Non disponibile');
    $('led-cal').className = 'led led-off';
  }
}

/* ==========================================================================
   Elaborazione frame
   ========================================================================== */
// FFT radix-2 in-place
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      const tr = re[i]; re[i] = re[j]; re[j] = tr;
      const ti = im[i]; im[i] = im[j]; im[j] = ti;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k, b = a + len / 2;
        const tr = re[b] * cr - im[b] * ci;
        const ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti;
        re[a] += tr;        im[a] += ti;
        const nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}

const fftRe = new Float32Array(CONFIG.waveLen);
const fftIm = new Float32Array(CONFIG.waveLen);
const fftOut = new Float32Array(CONFIG.waveLen / 2); // riuso: nessuna allocazione per frame

// Finestra di Hann precalcolata una sola volta (evita Math.cos per campione)
const hannWindow = new Float32Array(CONFIG.waveLen);
for (let i = 0; i < CONFIG.waveLen; i++) {
  hannWindow[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (CONFIG.waveLen - 1));
}

function spectrumFromWave() {
  const n = CONFIG.waveLen;
  for (let i = 0; i < n; i++) {
    fftRe[i] = S.wave[i] * hannWindow[i];
    fftIm[i] = 0;
  }
  fft(fftRe, fftIm);
  const invScale = 1 / (n / 4);
  for (let i = 0; i < fftOut.length; i++) {
    const mag = Math.sqrt(fftRe[i] * fftRe[i] + fftIm[i] * fftIm[i]) * invScale; // evita Math.hypot
    const db = 20 * Math.log10(mag + 1e-9);
    fftOut[i] = clamp((db + 90) / 90, 0, 1);                   // -90..0 dBFS -> 0..1
  }
  return fftOut;
}

function pushSamples(arr) {
  const n = CONFIG.waveLen;
  if (arr.length >= n) {
    S.wave.set(arr.slice(arr.length - n));
  } else {
    S.wave.copyWithin(0, arr.length);
    S.wave.set(arr, n - arr.length);
  }
  S.waveFill = Math.min(n, S.waveFill + arr.length);
}

function handleFrame(f) {
  if (!f || typeof f !== 'object') return;
  const now = Date.now();
  const ts = isNum(f.t) ? f.t * 1000 : now;
  S.frameSource = f.source === 'live' || f.source === 'simulated'
    ? f.source
    : S.source === 'sim' ? 'simulated' : 'unavailable';
  S.schemaVersion = Number.isInteger(f.schema_version) ? f.schema_version : '';
  S.provenance = f.provenance && typeof f.provenance === 'object' ? f.provenance : {};
  S.telemetry = f.sensors && typeof f.sensors === 'object' ? f.sensors : {};
  S.calibration = f.calibration && typeof f.calibration === 'object' ? f.calibration : {};
  S.interference = f.interference && typeof f.interference === 'object' ? f.interference : {};
  S.lastFrameAt = now;
  if (S.frameSource === 'simulated') {
    $('calibration-status').textContent = 'Simulazione: calibrazione non applicata';
    $('btn-calibrate').disabled = true;
    $('grid-interference').hidden = true;
  } else if (S.calibration.active) {
    $('calibration-status').textContent = 'Calibrazione in corso…';
    $('btn-calibrate').disabled = true;
    $('grid-interference').hidden = S.interference.detected !== true;
  } else if (S.calibration.completed_at) {
    const audioBaseline = isNum(S.calibration.baseline_audio)
      ? `${S.calibration.baseline_audio.toFixed(1)} dBFS`
      : 'non disponibile';
    $('calibration-status').textContent = `Baseline ${audioBaseline} · ${S.calibration.completed_at}`;
    $('btn-calibrate').disabled = false;
    $('grid-interference').hidden = S.interference.detected !== true;
  } else if (S.calibration.error) {
    $('calibration-status').textContent = S.calibration.error;
    $('btn-calibrate').disabled = false;
    $('grid-interference').hidden = S.interference.detected !== true;
  } else {
    $('calibration-status').textContent = 'Calibrazione non eseguita';
    $('btn-calibrate').disabled = false;
    $('grid-interference').hidden = S.interference.detected !== true;
  }

  if (isNum(f.sample_rate)) S.sampleRate = f.sample_rate;

  let delta = null;
  if (isNum(f.freq)) {
    delta = S.lastFreq === null ? 0 : f.freq - S.lastFreq;
    S.lastDelta = delta;
    S.hist.push({ t: ts, f: f.freq });
    if (S.hist.length > CONFIG.freqHistoryLen) S.hist.shift();
  }

  updateTelemetry(f);

  if (Array.isArray(f.samples) && f.samples.length) {
    pushSamples(Float32Array.from(f.samples));
    if (!Array.isArray(f.spectrum)) pushSpectrum(spectrumFromWave());
  }
  if (Array.isArray(f.spectrum) && f.spectrum.length) pushSpectrum(Float32Array.from(f.spectrum));

  // Rilevamento anomalie lato UI (soglie in CONFIG.anomaly)
  const freqAnomaly = isNum(f.freq) && delta !== null && Math.abs(delta) > CONFIG.anomaly.dFreqHz;
  const anomalyCooldownElapsed = now - S.lastFreqAnomalyAt >= 3000;
  if (freqAnomaly && !handleFrame._freqHot && anomalyCooldownElapsed) {
    addLog('ANOMALIA', 'Salto di frequenza oltre soglia', { freq: f.freq, delta, ts, cls: 'is-anomaly' });
    speakAnomaly(f.freq, delta);
    S.lastFreqAnomalyAt = now;
  }
  handleFrame._freqHot = freqAnomaly;
  const ent = f.sensors && f.sensors.entropy;
  if (isNum(ent) && ent > CONFIG.anomaly.entropyMax && !handleFrame._entHot) {
    addLog('ANOMALIA', `Entropia ${ent.toFixed(3)} sopra soglia ${CONFIG.anomaly.entropyMax}`, { freq: f.freq, delta, ts, cls: 'is-anomaly' });
  }
  handleFrame._entHot = isNum(ent) && ent > CONFIG.anomaly.entropyMax;

  if (Array.isArray(f.events)) {
    for (const event of f.events) {
      if (!event || typeof event !== 'object') continue;
      const type = String(event.type || 'evento').toLowerCase();
      const cls = type === 'warning' ? 'is-warning' : type === 'error' ? 'is-error' : 'is-info';
      const label = type === 'warning' ? 'WARN' : type === 'error' ? 'ERRORE' : 'INFO';
      const eventTs = typeof event.at === 'string' ? Date.parse(event.at) : NaN;
      addLog(label, String(event.msg || ''), {
        freq: f.freq,
        delta,
        ts: Number.isFinite(eventTs) ? eventTs : ts,
        cls,
      });
    }
  }

  // Legacy single-event frames remain supported.
  if (f.event && typeof f.event === 'object') {
    const type = String(f.event.type || 'evento').toLowerCase();
    const cls = type === 'anomaly' ? 'is-anomaly' : type === 'error' ? 'is-error' : '';
    addLog(type === 'anomaly' ? 'ANOMALIA' : type === 'error' ? 'ERRORE' : 'EVENTO',
      String(f.event.msg || ''), { freq: f.freq, delta, ts, cls });
  }

  if (isNum(f.freq)) S.lastFreq = f.freq;
}

/* ==========================================================================
   Connessione WebSocket
   ========================================================================== */
let ws = null;
let retryMs = CONFIG.reconnectMinMs;
let retryTimer = null;

function setSource(src) {
  S.source = src;
  const b = $('conn-badge');
  const map = {
    live:    ['Live',                   'badge badge-ok'],
    sim:     ['Simulazione (non reale)', 'badge badge-warn'],
    offline: ['Offline',                'badge badge-warn'],
    stale:   ['Nessun dato',            'badge badge-warn'],
  };
  const [text, cls] = map[src];
  b.textContent = text;
  b.className = cls;
}

function connect() {
  clearTimeout(retryTimer);
  try { ws = new WebSocket(CONFIG.wsUrl); } catch (e) { scheduleRetry(); return; }

  ws.onopen = () => {
    retryMs = CONFIG.reconnectMinMs;
    stopSim();
    resetSignalState();
    setSource('live');
    addLog('INFO', `Connesso a ${CONFIG.wsUrl}`, { cls: 'is-info' });
  };

  ws.onmessage = (ev) => {
    let data;
    try { data = JSON.parse(ev.data); } catch { return; }
    if (S.source !== 'live') setSource('live');
    handleFrame(data);
  };

  ws.onclose = () => {
    if (S.source === 'live' || S.source === 'stale') {
      setSource('offline');
      addLog('ERRORE', 'Connessione al backend persa', { cls: 'is-error' });
    }
    scheduleRetry();
  };

  ws.onerror = () => { /* onclose gestisce il ripristino */ };
}

function scheduleRetry() {
  retryTimer = setTimeout(connect, retryMs);
  retryMs = Math.min(CONFIG.reconnectMaxMs, retryMs * 1.5);
}

function resetSignalState() {
  S.hist.length = 0;
  S.lastFreq = null;
  S.lastDelta = null;
  S.lastFreqAnomalyAt = 0;
  handleFrame._freqHot = false;
  S.waveFill = 0;
  S.wave.fill(0);
  clearSpectrogram();
}

// Controllo dati scaduti
setInterval(() => {
  if (S.source === 'live' && Date.now() - S.lastFrameAt > CONFIG.staleMs) {
    setSource('stale');
    addLog('ERRORE', 'Nessun frame ricevuto dal backend', { cls: 'is-error' });
  }
  $('clock').textContent = new Date().toLocaleTimeString('it-IT');
}, 1000);

/* ==========================================================================
   Simulazione (solo per provare la UI: i dati NON sono reali)
   ========================================================================== */
let simTimer = null;
const sim = { x: 1, y: 1, z: 1, phase: 0, n: 0 };

function startSim() {
  if (simTimer || S.source === 'live') return;
  resetSignalState();
  setSource('sim');
  addLog('INFO', 'Simulazione avviata: Lorenz σ=10 ρ=28 β=8/3', { cls: 'is-info' });
  $('btn-sim').textContent = 'Ferma simulazione';
  $('btn-sim').classList.add('is-on');

  const SR = 7680, BLOCK = 256, FPS = SR / BLOCK;
  S.sampleRate = SR;
  simTimer = setInterval(() => {
    const dt = 0.005;
    for (let i = 0; i < 3; i++) {
      const dx = 10 * (sim.y - sim.x);
      const dy = sim.x * (28 - sim.z) - sim.y;
      const dz = sim.x * sim.y - (8 / 3) * sim.z;
      sim.x += dx * dt; sim.y += dy * dt; sim.z += dz * dt;
    }
    sim.n++;
    const freq = 432 + sim.x * 2.5;
    const samples = new Array(BLOCK);
    for (let i = 0; i < BLOCK; i++) {
      sim.phase += (2 * Math.PI * freq) / SR;
      samples[i] = 0.8 * Math.sin(sim.phase);
    }
    sim.phase %= 2 * Math.PI;
    const entropy = clamp(0.5 + 0.3 * Math.tanh(sim.y / 15) + (Math.random() - 0.5) * 0.04, 0, 1);
    const jump = S.lastFreq !== null && Math.abs(freq - S.lastFreq) > CONFIG.anomaly.dFreqHz;

    handleFrame({
      schema_version: 1,
      t: Date.now() / 1000,
      source: 'simulated',
      freq,
      attractor: { x: sim.x, y: sim.y, z: sim.z },
      sensors: {
        mic_db: -45 + 6 * Math.sin(sim.n / 40) + (Math.random() - 0.5) * 1.2,
        mag_ut: 48 + sim.z * 0.08 + (Math.random() - 0.5) * 0.3,
        entropy,
      },
      status: { sync: jump || entropy > CONFIG.anomaly.entropyMax ? 'anomaly' : 'normal', calibrated: false },
      provenance: {
        freq: 'derived',
        attractor: 'derived',
        sensors: {
          mic_db: 'simulated',
          mag_ut: 'simulated',
          entropy: 'simulated',
        },
        status: {
          sync: 'simulated',
          calibrated: 'unavailable',
        },
      },
      samples,
      sample_rate: SR,
    });
  }, 1000 / FPS);
}

function stopSim() {
  if (!simTimer) return;
  clearInterval(simTimer);
  simTimer = null;
  $('btn-sim').textContent = 'Avvia simulazione';
  $('btn-sim').classList.remove('is-on');
  if (S.source === 'sim') setSource('offline');
}

$('btn-sim').addEventListener('click', () => (simTimer ? stopSim() : startSim()));

/* ==========================================================================
   Rendering canvas
   ========================================================================== */
const canvas = $('scope');
const ctx = canvas.getContext('2d');
let W = 0, H = 0, DPR = 1;

const specCanvas = document.createElement('canvas');
const specCtx = specCanvas.getContext('2d', { willReadFrequently: false });
const SPEC_COL = 2; // larghezza (px dispositivo) di ogni colonna temporale
let specBins = 0;

function clearSpectrogram() {
  specCtx.fillStyle = COLORS.bg;
  specCtx.fillRect(0, 0, specCanvas.width, specCanvas.height);
}

function resize() {
  const r = canvas.getBoundingClientRect();
  DPR = window.devicePixelRatio || 1;
  W = Math.max(1, Math.floor(r.width));
  H = Math.max(1, Math.floor(r.height));
  canvas.width = Math.floor(W * DPR);
  canvas.height = Math.floor(H * DPR);
  specCanvas.width = canvas.width;
  specCanvas.height = canvas.height;
  clearSpectrogram();
}
new ResizeObserver(resize).observe(canvas.parentElement);

// Colormap sobria: sfondo -> ciano
function cmap(v) {
  const k = Math.pow(clamp(v, 0, 1), 0.8);
  return [14 + (0 - 14) * k, 14 + (255 - 14) * k, 16 + (204 - 16) * k];
}

let specImageData = null;
let specImageDataH = 0;

function pushSpectrum(bins) {
  specBins = bins.length;
  const h = specCanvas.height, w = specCanvas.width;
  specCtx.drawImage(specCanvas, -SPEC_COL, 0);

  // Riusa il buffer ImageData: ricrealo solo se l'altezza della canvas cambia
  if (specImageData === null || specImageDataH !== h) {
    specImageData = specCtx.createImageData(SPEC_COL, h);
    specImageDataH = h;
  }
  const data = specImageData.data;
  const binsLen = bins.length;
  const maxIdx = binsLen - 1;
  for (let y = 0; y < h; y++) {
    const idx = Math.min(maxIdx, ((1 - y / h) * binsLen) | 0);
    // cmap inline (sfondo -> ciano): evita allocazione array per colonna
    const k = Math.pow(clamp(bins[idx], 0, 1), 0.8);
    const r = 14 - 14 * k;
    const g = 14 + 241 * k;
    const b = 16 + 188 * k;
    for (let c = 0; c < SPEC_COL; c++) {
      const o = (y * SPEC_COL + c) * 4;
      data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255;
    }
  }
  specCtx.putImageData(specImageData, w - SPEC_COL, 0);
}

const M = { l: 62, r: 14, t: 12, b: 24 };

function drawGrid(plot, xDiv, yDiv) {
  ctx.lineWidth = 1;
  ctx.font = '11px "Cascadia Mono", Consolas, monospace';
  for (let i = 0; i <= xDiv; i++) {
    const x = Math.round(plot.x + (plot.w * i) / xDiv) + 0.5;
    ctx.strokeStyle = i === 0 || i === xDiv ? COLORS.gridStrong : COLORS.grid;
    ctx.beginPath(); ctx.moveTo(x, plot.y); ctx.lineTo(x, plot.y + plot.h); ctx.stroke();
  }
  for (let j = 0; j <= yDiv; j++) {
    const y = Math.round(plot.y + (plot.h * j) / yDiv) + 0.5;
    ctx.strokeStyle = j === 0 || j === yDiv ? COLORS.gridStrong : COLORS.grid;
    ctx.beginPath(); ctx.moveTo(plot.x, y); ctx.lineTo(plot.x + plot.w, y); ctx.stroke();
  }
}

function label(text, x, y, align = 'left', color = COLORS.muted) {
  ctx.fillStyle = color;
  ctx.textAlign = align;
  ctx.textBaseline = 'middle';
  ctx.fillText(text, x, y);
}

function emptyMessage(plot, text) {
  label(text, plot.x + plot.w / 2, plot.y + plot.h / 2, 'center', COLORS.warn);
}

function drawFreq(plot) {
  drawGrid(plot, 10, 6);
  const h = S.hist;
  if (h.length < 2) { emptyMessage(plot, 'In attesa di dati di frequenza'); return; }

  let lo = Infinity, hi = -Infinity;
  for (const p of h) { if (p.f < lo) lo = p.f; if (p.f > hi) hi = p.f; }
  const pad = Math.max((hi - lo) * 0.15, 0.5);
  lo -= pad; hi += pad;

  for (let j = 0; j <= 6; j++) {
    const v = hi - ((hi - lo) * j) / 6;
    label(v.toFixed(1), plot.x - 8, plot.y + (plot.h * j) / 6, 'right');
  }
  label('Hz', 8, plot.y + 4, 'left');

  const n = CONFIG.freqHistoryLen;
  const x0 = plot.x + plot.w * (1 - h.length / n);
  ctx.strokeStyle = COLORS.signal;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  h.forEach((p, i) => {
    const x = x0 + (plot.w * i) / n;
    const y = plot.y + plot.h * (1 - (p.f - lo) / (hi - lo));
    i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
  });
  ctx.stroke();

  const span = (h[h.length - 1].t - h[0].t) / 1000;
  label(`-${span.toFixed(0)} s`, plot.x, plot.y + plot.h + 14);
  label('ora', plot.x + plot.w, plot.y + plot.h + 14, 'right');
}

function drawWave(plot) {
  drawGrid(plot, 10, 8);
  for (const [v, j] of [['+1.0', 0], ['0', 4], ['-1.0', 8]]) {
    label(v, plot.x - 8, plot.y + (plot.h * j) / 8, 'right');
  }
  if (S.waveFill === 0) { emptyMessage(plot, 'Nessun campione audio nei frame: usa "Frequenza nel tempo"'); return; }

  const n = CONFIG.waveLen;
  const wave = S.wave;
  const xStep = plot.w / (n - 1);
  const halfH = plot.h * 0.5;
  ctx.strokeStyle = COLORS.signal;
  ctx.lineWidth = 1.25;
  ctx.beginPath();
  // Evita clamp() per punto: Math.min/max inline; nessuna divisione nel loop
  let v = wave[0];
  v = v < -1 ? -1 : v > 1 ? 1 : v;
  ctx.moveTo(plot.x, plot.y + halfH * (1 - v));
  for (let i = 1; i < n; i++) {
    let s = wave[i];
    s = s < -1 ? -1 : s > 1 ? 1 : s;
    ctx.lineTo(plot.x + xStep * i, plot.y + halfH * (1 - s));
  }
  ctx.stroke();

  const ms = (n / S.sampleRate) * 1000;
  label('0 ms', plot.x, plot.y + plot.h + 14);
  label(`${ms.toFixed(1)} ms`, plot.x + plot.w, plot.y + plot.h + 14, 'right');
}

function drawSpec(plot) {
  if (specBins === 0) { drawGrid(plot, 10, 6); emptyMessage(plot, 'Nessun dato spettrale (servono samples o spectrum)'); return; }

  // Blit del buffer offscreen nell'area del grafico (coordinate in pixel dispositivo)
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.drawImage(specCanvas,
    0, 0, specCanvas.width, specCanvas.height,
    plot.x * DPR, plot.y * DPR, plot.w * DPR, plot.h * DPR);
  ctx.restore();
  drawGrid(plot, 10, 6);

  const nyq = S.sampleRate / 2;
  for (let j = 0; j <= 6; j++) {
    label(`${Math.round(nyq * (1 - j / 6))}`, plot.x - 8, plot.y + (plot.h * j) / 6, 'right');
  }
  label('Hz', 8, plot.y + 4, 'left');
  label('tempo →', plot.x + plot.w, plot.y + plot.h + 14, 'right');
}

function frame() {
  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  ctx.fillStyle = COLORS.bg;
  ctx.fillRect(0, 0, W, H);

  const plot = { x: M.l, y: M.t, w: Math.max(10, W - M.l - M.r), h: Math.max(10, H - M.t - M.b) };
  if (S.mode === 'freq') drawFreq(plot);
  else if (S.mode === 'wave') drawWave(plot);
  else drawSpec(plot);

  requestAnimationFrame(frame);
}

/* ---------- Tab di visualizzazione ---------- */
document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    S.mode = tab.dataset.mode;
    document.querySelectorAll('.tab').forEach((t) => {
      const on = t === tab;
      t.classList.toggle('is-active', on);
      t.setAttribute('aria-selected', String(on));
    });
  });
});

/* ---------- Avvio ---------- */
resize();
requestAnimationFrame(frame);

const licenseGate = $('license-gate');
const appContent = $('app-content');
const appHeader = $('app-header');
const licenseMessage = $('license-message');
let isLicensed = false;

function setLicenseMessage(message, state = 'info') {
  licenseMessage.textContent = message;
  licenseMessage.className = `license-message${state === 'error' ? ' is-error' : ''}${state === 'success' ? ' is-success' : ''}`;
}

function unlockApplication() {
  if (isLicensed) return;
  isLicensed = true;
  licenseGate.hidden = true;
  appHeader.inert = false;
  appHeader.setAttribute('aria-hidden', 'false');
  appContent.inert = false;
  appContent.setAttribute('aria-hidden', 'false');
  addLog('INFO', `Licenza verificata — connessione a ${CONFIG.wsUrl}`, { cls: 'is-info' });
  connect();
}

async function initializeLicenseGate() {
  if (!window.fdLicense) {
    setLicenseMessage('Servizio licenze non disponibile. Avvia l’applicazione desktop.', 'error');
    return;
  }

  try {
    const result = await window.fdLicense.status();
    if (result.valid && !result.requireActivation) {
      unlockApplication();
      return;
    }
    if (result.valid) {
      setLicenseMessage('Modalità sviluppo: incolla o carica la licenza di questo dispositivo.');
    } else {
      setLicenseMessage(result.message || 'Attivazione richiesta per questo dispositivo.');
    }
  } catch (error) {
    setLicenseMessage(`Impossibile controllare la licenza: ${error.message}`, 'error');
  }

  try {
    $('license-hwid').value = await window.fdLicense.getHardwareId();
  } catch (error) {
    $('license-hwid').value = 'Non disponibile';
    setLicenseMessage(`Impossibile calcolare l’ID dispositivo: ${error.message}`, 'error');
  }
  $('btn-activate').focus();
}

$('btn-select-license').addEventListener('click', async (event) => {
  const button = event.currentTarget;
  button.disabled = true;
  setLicenseMessage('Seleziona il file di licenza da verificare…');
  try {
    const result = await window.fdLicense.activateFromFile();
    if (result.cancelled) {
      setLicenseMessage('Selezione annullata.');
    } else if (result.success) {
      setLicenseMessage('Licenza verificata. Avvio dell’applicazione…', 'success');
      unlockApplication();
    } else {
      setLicenseMessage(result.message || 'La licenza non è valida per questo dispositivo.', 'error');
    }
  } catch (error) {
    setLicenseMessage(`Caricamento licenza non riuscito: ${error.message}`, 'error');
  } finally {
    button.disabled = false;
  }
});

$('btn-activate').addEventListener('click', async (event) => {
  const button = event.currentTarget;
  const licenseText = $('license-key').value.trim();
  if (!licenseText) {
    setLicenseMessage('Incolla la chiave di licenza prima di accedere.', 'error');
    $('license-key').focus();
    return;
  }

  button.disabled = true;
  setLicenseMessage('Verifica della licenza Ed25519 in corso…');
  try {
    const result = await window.fdLicense.activate(licenseText);
    if (result.success) {
      setLicenseMessage('Licenza verificata. Avvio dell’applicazione…', 'success');
      $('license-key').value = '';
      unlockApplication();
    } else {
      setLicenseMessage(result.message || 'La licenza non è valida per questo dispositivo.', 'error');
    }
  } catch (error) {
    setLicenseMessage(`Attivazione non riuscita: ${error.message}`, 'error');
  } finally {
    button.disabled = false;
  }
});

$('btn-calibrate').addEventListener('click', () => {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    addLog('ERRORE', 'Connettiti al backend live prima di calibrare l’ambiente.', { cls: 'is-error' });
    return;
  }
  ws.send(JSON.stringify({ type: 'calibrate' }));
  $('btn-calibrate').disabled = true;
  $('calibration-status').textContent = 'Calibrazione in corso… 10 secondi';
  addLog('INFO', 'Calibrazione ambientale avviata (10 secondi).', { cls: 'is-info' });
});

$('btn-copy-hwid').addEventListener('click', async () => {
  const hwid = $('license-hwid').value;
  if (!hwid || hwid === 'Non disponibile') {
    setLicenseMessage('ID dispositivo non disponibile.', 'error');
    return;
  }
  try {
    await navigator.clipboard.writeText(hwid);
    setLicenseMessage('ID dispositivo copiato.', 'success');
  } catch (error) {
    setLicenseMessage(`Impossibile copiare l’ID dispositivo: ${error.message}`, 'error');
  }
});

$('btn-science-info').addEventListener('click', () => {
  $('science-info').hidden = false;
  $('btn-close-science-info').focus();
});

$('btn-close-science-info').addEventListener('click', () => {
  $('science-info').hidden = true;
  $('btn-science-info').focus();
});

$('science-info').addEventListener('click', (event) => {
  if (event.target === $('science-info')) $('science-info').hidden = true;
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !$('science-info').hidden) {
    $('science-info').hidden = true;
    $('btn-science-info').focus();
  }
});

$('btn-updates').addEventListener('click', async (event) => {
  const button = event.currentTarget;
  const status = $('update-status');
  const releaseButton = $('btn-release');
  button.disabled = true;
  releaseButton.hidden = true;
  status.textContent = 'Ricerca in corso…';
  try {
    const result = await window.fdUpdates.check();
    if (result.status === 'available') {
      status.textContent = `Disponibile versione ${result.version}`;
      if (result.url) {
        releaseButton.hidden = false;
        releaseButton.onclick = async () => {
          try {
            await window.fdUpdates.openRelease(result.url);
          } catch (error) {
            status.textContent = `Impossibile aprire la release: ${error.message}`;
          }
        };
      }
    } else if (result.status === 'current') {
      status.textContent = `Versione ${result.version}: aggiornata`;
    } else {
      status.textContent = result.message || 'Ricerca aggiornamenti non riuscita.';
    }
  } catch (error) {
    status.textContent = `Ricerca aggiornamenti non riuscita: ${error.message}`;
  } finally {
    button.disabled = false;
  }
});

initializeLicenseGate();
