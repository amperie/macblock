let token = '', state, dirty = false, busy = false;
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
  $('domains').replaceChildren();
  for (const domain of state.policy.blockedDomains ?? []) {
    const row = document.createElement('div'); row.className = 'app';
    const name = document.createElement('strong'); name.textContent = domain;
    const remove = document.createElement('button'); remove.textContent = 'Remove'; remove.className = 'secondary';
    remove.setAttribute('aria-label', `Remove ${domain}`);
    remove.onclick = () => {
      state.policy.blockedDomains = state.policy.blockedDomains.filter(host => host !== domain);
      dirty = true; render(); $('message').textContent = 'Unsaved changes';
    };
    row.append(name, remove); $('domains').append(row);
  }
  const device = state.device;
  const age = device ? Date.now() - Date.parse(device.lastSeen) : Infinity;
  $('status').textContent = !device ? 'Waiting for the Mac to connect' : `${age > 300000 ? 'Mac offline or overdue' : 'Mac connected'} · Last seen ${new Date(device.lastSeen).toLocaleString()} · ${device.report.revision === state.policy.revision ? 'Settings received' : 'Update pending'} (revision ${device.report.revision}/${state.policy.revision}) · Agent ${device.report.agentVersion}`;
  $('health').textContent = device?.report.lastError ? `Agent needs attention: ${device.report.lastError}` : '';
}
async function load() { if (dirty) throw Error('Save your changes, or use Discard changes and reload.'); state = await api('/api/admin/state'); $('controls').hidden = false; $('login').hidden = true; render(); }
function action(fn) { return async event => {
  event?.preventDefault();
  if (busy) return;
  busy = true;
  const disable = value => document.querySelectorAll('button, input').forEach(element => { element.disabled = value; });
  disable(true); $('message').textContent = '';
  try { await fn(); } catch (error) { $('message').textContent = error.message; }
  finally { busy = false; disable(false); }
}; }
$('connect').onclick = action(async () => { token = $('token').value; await load(); $('token').value = ''; });
$('refresh').onclick = action(load);
$('discard').onclick = action(async () => {
  // Do not drop edits until the replacement state has arrived successfully.
  const fresh = await api('/api/admin/state');
  state = fresh; dirty = false; render();
});
$('save').onclick = action(async () => { state.policy = await api('/api/admin/policy', state.policy); dirty = false; render(); $('message').textContent = 'Saved. Waiting for the Mac to receive these settings.'; });
$('add-domain').onsubmit = action(async () => {
  const input = $('domain').value.trim();
  const host = input.toLowerCase().replace(/\.$/, '');
  const labels = host.split('.');
  const tld = labels.at(-1);
  if (!/^[\x00-\x7f]+$/.test(input) || host.length > 253 || labels.length < 2 || !/[a-z]/.test(tld) || /^0x[0-9a-f]+$/.test(tld) ||
      !labels.every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
    throw Error('Enter a domain name, such as instagram.com.');
  }
  const domains = state.policy.blockedDomains ?? [];
  if (domains.includes(host)) throw Error('That domain is already listed.');
  if (domains.length >= 100) throw Error('At most 100 domains can be configured.');
  state.policy.blockedDomains = [...domains, host].sort();
  dirty = true; render(); $('add-domain').reset(); $('message').textContent = 'Domain added. Save changes to send it to the Mac.';
});
$('add').onsubmit = action(async () => { const name = $('name').value.trim(), bundleId = $('bundle').value.trim(); if (!name || name.length > 80) throw Error('Enter an app name of at most 80 characters.'); if (state.policy.apps.length >= 100) throw Error('At most 100 apps can be configured.'); if (bundleId.length > 255) throw Error('Bundle identifier is too long.'); if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(bundleId) || /^(com\.apple\.|com\.macblock\.)/i.test(bundleId)) throw Error('Use a non-system app bundle identifier.'); if (state.policy.apps.some(a => a.bundleId === bundleId)) throw Error('That app is already listed.'); state.policy.apps.push({name, bundleId, blocked: false}); dirty = true; render(); $('add').reset(); $('message').textContent = 'App added. Save changes to send it to the Mac.'; });
window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
