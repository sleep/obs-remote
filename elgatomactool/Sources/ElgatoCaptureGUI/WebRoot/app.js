/* Elgato Capture Remote — front-end controller */
(function () {
  'use strict';

  // --- Access key (PSK) from the URL, persisted for the PWA session ---
  const params = new URLSearchParams(location.search);
  let PSK = params.get('k') || sessionStorage.getItem('psk') || '';
  if (PSK) sessionStorage.setItem('psk', PSK);

  const withKey = (path) => path + (path.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(PSK);

  // --- Framework7 app ---
  let app = null;
  try {
    if (window.Framework7) {
      app = new Framework7({ el: '#app', theme: 'ios', darkMode: true });
    }
  } catch (e) { /* controls still work without F7 */ }

  function openSettings() {
    if (app && app.popup) { app.popup.open('#settingsPopup'); return; }
    document.getElementById('settingsPopup').classList.add('fallback-open');
  }
  function closeFallback() {
    document.querySelectorAll('.popup.fallback-open').forEach((p) => p.classList.remove('fallback-open'));
  }

  // --- Service worker (PWA / offline) ---
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }

  // --- DOM refs ---
  const $ = (id) => document.getElementById(id);
  const statusDot = $('statusDot');
  const statePill = $('statePill');
  const previewFrame = $('previewFrame');
  const previewImg = $('previewImg');
  const placeholderText = $('placeholderText');
  const liveBadge = $('liveBadge');
  const recBadge = $('recBadge');
  const recTime = $('recTime');
  const resBadge = $('resBadge');
  const captureBtn = $('captureBtn');
  const captureIcon = $('captureIcon');
  const captureLabel = $('captureLabel');
  const actionsGrid = $('actionsGrid');
  const audioRow = $('audioRow');
  const audioFill = $('audioFill');
  const statusLine = $('statusLine');
  const lockedOverlay = $('lockedOverlay');

  let latest = null;
  let settingsBuilt = false;
  let online = true;

  // --- API helpers ---
  async function getState() {
    const res = await fetch(withKey('/api/state'), { cache: 'no-store' });
    if (res.status === 401) { showLocked(); throw new Error('unauthorized'); }
    return res.json();
  }
  async function postAction(payload) {
    try {
      await fetch(withKey('/api/action'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      pulse();
    } catch (e) {}
  }
  async function postSettings(payload) {
    try {
      await fetch(withKey('/api/settings'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      pulse();
    } catch (e) {}
  }
  // Quick refresh after a command for snappy UI.
  function pulse() { setTimeout(refresh, 120); setTimeout(refresh, 450); }

  function showLocked() { lockedOverlay.classList.remove('hidden'); }

  // --- Preview loop (double-buffered to avoid flicker) ---
  let previewBusy = false;
  function refreshPreview(active) {
    if (!active) {
      previewFrame.classList.remove('has-signal');
      return;
    }
    if (previewBusy) return;
    previewBusy = true;
    const img = new Image();
    img.onload = () => {
      previewImg.src = img.src;
      previewFrame.classList.add('has-signal');
      previewBusy = false;
    };
    img.onerror = () => { previewBusy = false; };
    img.src = withKey('/api/preview.jpg') + '&t=' + Date.now();
  }

  // --- Sparklines ---
  function drawSpark(canvasId, data, color) {
    const cv = $(canvasId);
    if (!cv) return;
    const dpr = window.devicePixelRatio || 1;
    const w = cv.clientWidth, h = cv.clientHeight;
    if (cv.width !== w * dpr) { cv.width = w * dpr; cv.height = h * dpr; }
    const ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    if (!data || data.length < 2) return;

    const max = Math.max(1, ...data);
    const min = Math.min(0, ...data);
    const range = max - min || 1;
    const step = w / (data.length - 1);
    const y = (v) => h - ((v - min) / range) * (h - 3) - 1.5;

    // fill
    const grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, color + '66');
    grad.addColorStop(1, color + '00');
    ctx.beginPath();
    ctx.moveTo(0, h);
    data.forEach((v, i) => ctx.lineTo(i * step, y(v)));
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // line
    ctx.beginPath();
    data.forEach((v, i) => { i ? ctx.lineTo(i * step, y(v)) : ctx.moveTo(0, y(v)); });
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.6;
    ctx.lineJoin = 'round';
    ctx.stroke();
  }

  // --- Render ---
  function fmtDur(t) {
    t = Math.floor(t || 0);
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
    return h > 0 ? `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`
                 : `${m}:${String(s).padStart(2,'0')}`;
  }
  function fmtRam(mb) { return mb >= 1024 ? (mb/1024).toFixed(1) + 'G' : Math.round(mb) + 'M'; }
  function fmtReplay(s) {
    if (s >= 60) { const m = Math.floor(s/60), r = Math.round(s%60); return r ? `${m}m${r}s` : `${m}m`; }
    return Math.round(s) + 's';
  }

  function render(s) {
    latest = s;
    const capturing = s.capturing, recording = s.recording;

    // Status dot + pill
    statusDot.className = 'status-dot ' + (recording ? 'rec' : capturing ? 'live' : 'idle');
    statePill.textContent = recording ? 'REC' : capturing ? 'LIVE' : (s.previewing ? 'PREVIEW' : 'IDLE');

    // Preview
    const showSignal = capturing;
    refreshPreview(showSignal);
    placeholderText.textContent = s.cameraAuthorized
      ? (s.deviceDisconnected ? 'Device disconnected'
         : s.previewing ? 'Preview — start capture for live frames'
         : (s.devices && s.devices.length ? 'Idle' : 'No capture device'))
      : 'Camera access needed on Mac';

    liveBadge.classList.toggle('hidden', !capturing || recording);
    recBadge.classList.toggle('hidden', !recording);
    recTime.textContent = fmtDur(s.recordingDuration);
    resBadge.textContent = s.resolution || '';
    resBadge.classList.toggle('hidden', !s.resolution);

    // Primary button
    captureBtn.classList.remove('disabled', 'is-stop');
    if (capturing) {
      captureBtn.classList.add('is-stop');
      captureIcon.textContent = 'stop_fill';
      captureLabel.textContent = 'Stop Capture';
    } else {
      captureIcon.textContent = 'play_fill';
      captureLabel.textContent = 'Start Capture';
      if (!s.devices || !s.devices.length || !s.cameraAuthorized) captureBtn.classList.add('disabled');
    }

    // Action tiles
    actionsGrid.classList.toggle('hidden', !capturing);
    audioRow.classList.toggle('hidden', !capturing || !s.hasAudio);

    const recordTile = $('recordTile');
    recordTile.classList.toggle('rec-on', recording);
    $('recordTileIcon').textContent = recording ? 'stop_circle_fill' : 'record_circle';
    $('recordTileLabel').textContent = recording ? fmtDur(s.recordingDuration) : 'Record';

    setFeedback($('screenshotTile'), s.screenshotFeedback);
    setFeedback($('replayTile'), s.replayFeedback);

    const pt = $('passthroughTile');
    pt.classList.toggle('active', s.passthrough);
    pt.classList.toggle('disabled', !s.hasAudio);
    $('passthroughIcon').textContent = s.passthrough ? 'speaker_2_fill' : 'speaker_slash_fill';

    // Audio meter
    const peak = (s.audio && s.audio.peak) || 0;
    audioFill.style.width = Math.min(100, Math.round(peak * 100)) + '%';

    // Stats
    setStat('fps', (s.fps || 0).toFixed(0), s.fps >= 55 ? '' : s.fps >= 30 ? 'warn' : 'bad');
    setStat('bitrate', (s.bitrate || 0).toFixed(1), '', 'mbps');
    setStat('buffer', Math.round(s.buffer.duration), '', 's');
    $('sub-buffer').textContent = s.buffer.sizeMB + ' MB · ' + s.buffer.frames + 'f';
    setStat('cpu', (s.system.cpu || 0).toFixed(0), s.system.cpu > 85 ? 'bad' : s.system.cpu > 60 ? 'warn' : '', '%');
    setStat('gpu', (s.system.gpu || 0).toFixed(0), s.system.gpu > 85 ? 'bad' : '', '%');
    $('val-ram').textContent = fmtRam(s.system.ramMB);
    $('val-disk').textContent = (s.system.diskFreeGB || 0).toFixed(0);

    if (s.history) {
      drawSpark('spark-fps', s.history.fps, '#3ddc84');
      drawSpark('spark-bitrate', null, '#00f5ff');
      drawSpark('spark-cpu', s.history.cpu, '#00f5ff');
      drawSpark('spark-gpu', s.history.gpu, '#9b6bff');
    }

    // Status line
    if (s.errorMessage) { statusLine.textContent = s.errorMessage; statusLine.classList.add('error'); }
    else { statusLine.textContent = s.statusMessage || ''; statusLine.classList.remove('error'); }

    if (!settingsBuilt) buildSettings(s);
    else syncSettings(s);
  }

  function setStat(name, value, cls, unit) {
    const el = $('val-' + name);
    if (!el) return;
    el.innerHTML = value + (unit ? `<small>${unit}</small>` : '');
    el.className = 'stat-value' + (cls ? ' ' + cls : '');
  }

  function setFeedback(tile, fb) {
    tile.classList.toggle('success', fb === 'success');
    tile.classList.toggle('busy', fb === 'inProgress');
  }

  // --- Settings UI ---
  function buildSettings(s) {
    settingsBuilt = true;
    const opt = s.options;

    // Bitrate chips
    const bc = $('bitrateChips');
    bc.innerHTML = '';
    opt.bitratePresets.forEach((v) => {
      const c = document.createElement('div');
      c.className = 'chip'; c.textContent = v; c.dataset.v = v;
      c.onclick = () => postSettings({ bitrateMbps: v });
      bc.appendChild(c);
    });

    // Replay chips
    const rc = $('replayChips');
    rc.innerHTML = '';
    opt.replayPresets.forEach((v) => {
      const c = document.createElement('div');
      c.className = 'chip'; c.textContent = fmtReplay(v); c.dataset.v = v;
      c.onclick = () => postSettings({ replayDuration: v });
      rc.appendChild(c);
    });

    // RAM select
    const ram = $('ramSelect');
    ram.innerHTML = '';
    opt.ramPresets.forEach((p) => {
      const o = document.createElement('option');
      o.value = p.bytes; o.textContent = p.label; ram.appendChild(o);
    });
    ram.onchange = () => postSettings({ maxReplayRAM: parseInt(ram.value, 10) });

    // Device selects
    $('deviceSelect').onchange = (e) => postAction({ cmd: 'selectDevice', id: e.target.value });
    $('audioSelect').onchange = (e) => postAction({ cmd: 'selectAudioDevice', id: e.target.value });
    $('refreshBtn').onclick = () => postAction({ cmd: 'refresh' });

    // Toggles
    $('tgRemember').onchange = (e) => postSettings({ rememberLastDevice: e.target.checked });
    $('tgAutostart').onchange = (e) => postSettings({ autoStartCapture: e.target.checked });
    $('tgMinimized').onchange = (e) => postSettings({ startMinimized: e.target.checked });

    // Check grids
    buildChecks('overlayChecks', opt.overlayStats, 'overlay');
    buildChecks('statusBarChecks', opt.statusBarFields, 'statusbar');

    syncSettings(s);
  }

  function buildChecks(containerId, items, kind) {
    const c = $(containerId);
    c.innerHTML = '';
    items.forEach((it) => {
      const el = document.createElement('div');
      el.className = 'check-item'; el.dataset.id = it.id; el.dataset.kind = kind;
      el.innerHTML = `<span class="box"><i class="f7-icons">checkmark_alt</i></span><span>${it.label}</span>`;
      el.onclick = () => {
        el.classList.toggle('checked');
        const selected = Array.from(c.querySelectorAll('.check-item.checked')).map((x) => x.dataset.id);
        postSettings(kind === 'overlay' ? { overlayStats: selected } : { statusBarFields: selected });
      };
      c.appendChild(el);
    });
  }

  function fillSelect(sel, items, includeNone) {
    const want = JSON.stringify(items.map((d) => d.id)) + ':' + includeNone;
    if (sel.dataset.sig === want) return; // avoid clobbering while user interacts
    sel.dataset.sig = want;
    sel.innerHTML = '';
    if (includeNone) {
      const o = document.createElement('option'); o.value = 'none'; o.textContent = 'None'; sel.appendChild(o);
    }
    items.forEach((d) => {
      const o = document.createElement('option'); o.value = d.id; o.textContent = d.name; sel.appendChild(o);
    });
  }

  function syncSettings(s) {
    fillSelect($('deviceSelect'), s.devices || [], false);
    fillSelect($('audioSelect'), s.audioDevices || [], true);
    const selDev = (s.devices || []).find((d) => d.selected);
    if (selDev) $('deviceSelect').value = selDev.id;
    const selAudio = (s.audioDevices || []).find((d) => d.selected);
    $('audioSelect').value = selAudio ? selAudio.id : 'none';

    const cfg = s.settings;
    $('bitrateVal').textContent = cfg.bitrateMbps + ' Mbps';
    $('replayVal').textContent = fmtReplay(cfg.replayDuration);
    markChips('bitrateChips', cfg.bitrateMbps);
    markChips('replayChips', cfg.replayDuration);
    $('ramSelect').value = cfg.maxReplayRAM;
    $('tgRemember').checked = cfg.rememberLastDevice;
    $('tgAutostart').checked = cfg.autoStartCapture;
    $('tgMinimized').checked = cfg.startMinimized;
    $('outputPath').textContent = cfg.outputDirectory || '—';

    markChecks('overlayChecks', cfg.overlayStats);
    markChecks('statusBarChecks', cfg.statusBarFields);
  }

  function markChips(id, value) {
    $(id).querySelectorAll('.chip').forEach((c) => {
      c.classList.toggle('active', Number(c.dataset.v) === Number(value));
    });
  }
  function markChecks(id, selected) {
    const set = new Set(selected || []);
    $(id).querySelectorAll('.check-item').forEach((el) => {
      el.classList.toggle('checked', set.has(el.dataset.id));
    });
  }

  // --- Wire static buttons ---
  $('settingsBtn').onclick = (e) => { e.preventDefault(); openSettings(); };
  document.querySelectorAll('.popup-close').forEach((el) => {
    el.addEventListener('click', (e) => { if (!app) { e.preventDefault(); closeFallback(); } });
  });
  captureBtn.onclick = () => {
    if (captureBtn.classList.contains('disabled')) return;
    postAction({ cmd: latest && latest.capturing ? 'stop' : 'start' });
  };
  $('recordTile').onclick = () => postAction({ cmd: 'record' });
  $('screenshotTile').onclick = () => postAction({ cmd: 'screenshot' });
  $('replayTile').onclick = () => postAction({ cmd: 'replay' });
  $('passthroughTile').onclick = () => {
    if (!latest || !latest.hasAudio) return;
    postAction({ cmd: 'passthrough', on: !latest.passthrough });
  };

  // --- Poll loop ---
  async function refresh() {
    try {
      const s = await getState();
      online = true;
      render(s);
    } catch (e) {
      online = false;
    }
  }

  if (!PSK) { showLocked(); }
  refresh();
  setInterval(refresh, 1000);
  // Preview ticks slightly offset for smoother feel
  setInterval(() => { if (latest && latest.capturing) refreshPreview(true); }, 900);
})();
