const DB_NAME = 'sidestore-web';
const DB_VERSION = 1;
const STORE = 'apps';
const SETTINGS_KEY = 'settings';

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
let deferredInstall = null;
let selectedFile = null;

function toast(message) {
  const el = $('#toast');
  el.textContent = message;
  el.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => el.classList.remove('show'), 2600);
}

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE, { keyPath: 'id', autoIncrement: true });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function tx(mode, action) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, mode);
    const store = transaction.objectStore(STORE);
    const result = action(store);
    transaction.oncomplete = () => resolve(result?.result ?? result);
    transaction.onerror = () => reject(transaction.error);
  });
}

async function getApps() {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const request = db.transaction(STORE, 'readonly').objectStore(STORE).getAll();
    request.onsuccess = () => resolve(request.result.sort((a,b) => b.id - a.id));
    request.onerror = () => reject(request.error);
  });
}

async function addApp(app) {
  return tx('readwrite', store => store.add(app));
}

async function deleteApp(id) {
  return tx('readwrite', store => store.delete(id));
}

function getSettings() {
  try { return JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}'); } catch { return {}; }
}

function saveSettings(value) {
  localStorage.setItem(SETTINGS_KEY, JSON.stringify(value));
}

function apiBase() {
  return (getSettings().apiUrl || '').replace(/\/$/, '');
}

async function api(path, options = {}) {
  const base = apiBase();
  if (!base) throw new Error('Configure a signing service URL in Settings first.');
  const response = await fetch(`${base}${path}`, {
    ...options,
    headers: {'Content-Type': 'application/json', ...(options.headers || {})},
    credentials: 'include'
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Request failed (${response.status})`);
  return data;
}

function showView(name) {
  $$('.view').forEach(v => v.classList.toggle('active', v.dataset.view === name));
  $$('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
  $('#page-title').textContent = name === 'apps' ? 'Apps' : name[0].toUpperCase() + name.slice(1);
  history.replaceState(null, '', `#${name}`);
  if (name === 'apps') renderApps();
  if (name === 'devices') loadDevices();
}

function renderApps() {
  getApps().then(apps => {
    $('#app-count').textContent = apps.length;
    $('#apps-list').innerHTML = apps.map(app => `
      <article class="card">
        <div class="app-icon">${escapeHtml((app.name || 'A').slice(0,1).toUpperCase())}</div>
        <div class="card-main">
          <strong>${escapeHtml(app.name || 'Unnamed App')}</strong>
          <span>${escapeHtml(app.bundleId || 'Bundle ID not set')} · ${escapeHtml(app.version || 'Unknown version')}</span>
        </div>
        <div class="card-actions">
          <button data-sign="${app.id}">Sign</button>
          <button data-delete="${app.id}" aria-label="Delete app">×</button>
        </div>
      </article>`).join('');
    $('#empty-apps').hidden = apps.length !== 0;
    $$('#apps-list [data-delete]').forEach(btn => btn.onclick = async () => {
      await deleteApp(Number(btn.dataset.delete));
      renderApps();
      toast('Removed');
    });
    $$('#apps-list [data-sign]').forEach(btn => btn.onclick = () => startSigning(Number(btn.dataset.sign)));
  });
}

async function startSigning(id) {
  const apps = await getApps();
  const app = apps.find(x => x.id === id);
  if (!app) return;
  if (!apiBase()) { showView('settings'); toast('Configure the signing service first.'); return; }
  try {
    const result = await api('/auth/start', {method:'POST', body: JSON.stringify({appId:id, bundleId:app.bundleId})});
    if (result.status === 'verification_required') {
      const code = prompt('Apple verification code');
      if (!code) return;
      const verified = await api('/auth/2fa', {method:'POST', body: JSON.stringify({sessionId:result.sessionId, code})});
      toast(verified.message || 'Verification submitted');
    } else {
      toast(result.message || 'Signing session started');
    }
  } catch (error) { toast(error.message); }
}

async function loadDevices() {
  const list = $('#devices-list');
  const empty = $('#empty-devices');
  if (!apiBase()) { list.innerHTML = ''; empty.hidden = false; return; }
  try {
    const data = await api('/devices');
    const devices = data.devices || [];
    list.innerHTML = devices.map(d => `<article class="card"><div class="app-icon">▣</div><div class="card-main"><strong>${escapeHtml(d.name || 'Device')}</strong><span>${escapeHtml(d.udid || 'UDID unavailable')} · ${escapeHtml(d.status || 'registered')}</span></div></article>`).join('');
    empty.hidden = devices.length !== 0;
  } catch (error) { toast(error.message); }
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
}

$('#ipa-file').addEventListener('change', e => {
  selectedFile = e.target.files?.[0] || null;
  $('#selected-file').hidden = !selectedFile;
  $('#selected-file').textContent = selectedFile ? `${selectedFile.name} · ${(selectedFile.size / 1048576).toFixed(1)} MB` : '';
});

$('#save-app').onclick = async () => {
  if (!selectedFile) { toast('Select an IPA first.'); return; }
  const name = $('#app-name').value.trim() || selectedFile.name.replace(/\.ipa$/i,'');
  const bundleId = $('#bundle-id').value.trim();
  const version = $('#app-version').value.trim() || '1.0';
  await addApp({name, bundleId, version, filename:selectedFile.name, size:selectedFile.size, blob:selectedFile, createdAt:Date.now()});
  selectedFile = null;
  $('#ipa-file').value = '';
  $('#selected-file').hidden = true;
  $('#app-name').value = '';
  $('#bundle-id').value = '';
  $('#app-version').value = '';
  toast('IPA added locally');
  showView('apps');
};

$('#save-settings').onclick = () => {
  const apiUrl = $('#api-url').value.trim();
  if (apiUrl && !/^https:\/\//i.test(apiUrl)) { toast('Signing service must use HTTPS.'); return; }
  saveSettings({apiUrl});
  toast('Settings saved');
};

$('#refresh-devices').onclick = loadDevices;
$('#clear-local').onclick = async () => {
  if (!confirm('Delete all locally stored app data?')) return;
  const db = await openDB();
  await new Promise((resolve, reject) => { const r = db.transaction(STORE,'readwrite').objectStore(STORE).clear(); r.onsuccess=resolve; r.onerror=()=>reject(r.error); });
  renderApps();
  toast('Local data cleared');
};

$$('[data-tab]').forEach(btn => btn.onclick = () => showView(btn.dataset.tab));
$$('[data-go]').forEach(btn => btn.onclick = () => showView(btn.dataset.go));

window.addEventListener('beforeinstallprompt', e => {
  e.preventDefault();
  deferredInstall = e;
  $('#install-pwa').hidden = false;
});
$('#install-pwa').onclick = async () => {
  if (!deferredInstall) { toast('Use Safari Share → Add to Home Screen.'); return; }
  deferredInstall.prompt();
  await deferredInstall.userChoice;
  deferredInstall = null;
  $('#install-pwa').hidden = true;
};

window.addEventListener('appinstalled', () => { $('#pwa-status').textContent = 'Installed as a web app'; });

const settings = getSettings();
$('#api-url').value = settings.apiUrl || '';

if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch(() => {});

const initial = location.hash.slice(1);
showView(['apps','add','devices','settings'].includes(initial) ? initial : 'apps');
