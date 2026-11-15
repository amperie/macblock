let token = '', state, dirty = false;
const $ = id => document.getElementById(id);
async function api(path, body) {
  const response = await fetch(path, {method: body ? 'POST' : 'GET', headers: {'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json'}, ...(body ? {body: JSON.stringify(body)} : {})});
  const data = await response.json();
  if (!response.ok) throw Error(data.error || 'Request failed');
  return data;
}
function render() {
  $('apps').replaceChildren();
  for (const app of state.policy.apps) {
    const row = document.createElement('div'); row.className = 'app';
    const text = document.createElement('div'); const title = document.createElement('strong'); title.textContent = app.name;
    const detail = document.createElement('small'); detail.textContent = app.bundleId; text.append(title, detail);
    const label = document.createElement('label'); label.className = 'switch';
    const toggle = document.createElement('input'); toggle.type = 'checkbox'; toggle.checked = app.blocked;
    toggle.setAttribute('aria-label', `Block ${app.name}`);
    const caption = document.createElement('span'); caption.textContent = app.blocked ? 'Blocked' : 'Allowed';
    toggle.onchange = () => { app.blocked = toggle.checked; dirty = true; caption.textContent = app.blocked ? 'Blocked' : 'Allowed'; $('message').textContent = 'Unsaved changes'; };
    label.append(toggle, caption);
    const remove = document.createElement('button'); remove.textContent = 'Remove'; remove.className = 'secondary'; remove.setAttribute('aria-label', `Remove ${app.name}`);
    remove.onclick = () => { state.policy.apps = state.policy.apps.filter(a => a !== app); dirty = true; render(); $('message').textContent = 'Unsaved changes'; };
    row.append(text, label, remove); $('apps').append(row);
  }
  const device = state.device;
  const age = device ? Date.now() - Date.parse(device.lastSeen) : Infinity;
  $('status').textContent = !device ? 'Waiting for the Mac to connect' : `${age > 300000 ? 'Mac offline or overdue' : 'Mac connected'} · Last seen ${new Date(device.lastSeen).toLocaleString()} · ${device.report.revision === state.policy.revision ? 'Settings received' : 'Update pending'} (revision ${device.report.revision}/${state.policy.revision})`;
  $('health').textContent = device?.report.lastError ? `Agent needs attention: ${device.report.lastError}` : '';
}
async function load() { if (dirty) throw Error('Save your changes before refreshing.'); state = await api('/api/admin/state'); $('controls').hidden = false; $('login').hidden = true; render(); }
function action(fn) { return async event => { event?.preventDefault(); $('message').textContent = ''; try { await fn(); } catch (error) { $('message').textContent = error.message; } }; }
$('connect').onclick = action(async () => { token = $('token').value; await load(); $('token').value = ''; });
$('refresh').onclick = action(load);
$('save').onclick = action(async () => { state.policy = await api('/api/admin/policy', state.policy); dirty = false; await load(); $('message').textContent = 'Saved. Waiting for the Mac to receive these settings.'; });
$('add').onsubmit = action(async () => { const name = $('name').value.trim(), bundleId = $('bundle').value.trim(); if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(bundleId) || /^(com\.apple\.|com\.macblock\.)/i.test(bundleId)) throw Error('Use a non-system app bundle identifier.'); if (state.policy.apps.some(a => a.bundleId === bundleId)) throw Error('That app is already listed.'); state.policy.apps.push({name, bundleId, blocked: false}); dirty = true; render(); $('add').reset(); $('message').textContent = 'App added. Save changes to send it to the Mac.'; });
window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });

async function loadActivity() {
  const data = await api('/api/admin/activity');
  const last = data.lastSeen ? Date.parse(data.lastSeen) : 0;
  const fresh = last && Date.now() - last < 120000;
  $('activity-current').textContent = fresh && data.current
    ? `Foreground: ${data.current.appName} (since ${new Date(data.current.since).toLocaleTimeString()})`
    : data.lastSeen ? `No current activity confirmed · Last update ${new Date(data.lastSeen).toLocaleString()}` : 'No activity reported';
  const container = $('activity-events');
  container.replaceChildren();
  const totals = new Map();
  for (const e of data.events) {
    const seconds = Math.max(0, (Date.parse(e.endedAt) - Date.parse(e.startedAt)) / 1000);
    totals.set(e.appName, (totals.get(e.appName) || 0) + seconds);
  }
  const summary = document.createElement('p');
  summary.textContent = [...totals.entries()].sort((a,b) => b[1] - a[1]).slice(0, 5)
    .map(([name, seconds]) => `${name}: ${Math.round(seconds / 60)}m`).join(' · ') || 'No completed sessions';
  container.append(summary);
  for (const e of data.events.slice(0, 50)) {
    const row = document.createElement('div');
    row.className = 'app';
    const seconds = Math.max(0, (Date.parse(e.endedAt) - Date.parse(e.startedAt)) / 1000);
    row.textContent = `${e.appName} · ${new Date(e.startedAt).toLocaleString()} · ${Math.round(seconds / 60)} min`;
    container.append(row);
  }
}
$('activity-refresh').onclick = action(loadActivity);
const originalLoad = load;
load = async function () { await originalLoad(); await loadActivity(); };
