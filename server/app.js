let token = '', state, dirty = false;
const $ = id => document.getElementById(id);
async function api(path, body) {
  const response = await fetch(path, {method: body ? 'POST' : 'GET', headers: {'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json'}, ...(body ? {body: JSON.stringify(body)} : {})});
  const data = await response.json();
  if (!response.ok) throw Error(data.error || 'Request failed');
  return data;
}
function render() {
  $('blocked-domains').value = (state.policy.blockedDomains || []).join('\n');
  const zone = $('enforcement-zone');
  zone.replaceChildren();
  for (const id of state.timeZones || ['America/Los_Angeles']) {
    const option = document.createElement('option'); option.value = id;
    option.textContent = id.replaceAll('_', ' '); zone.append(option);
  }
  zone.value = state.policy.enforcementTimeZone || 'America/Los_Angeles';
  const schedule = state.policy.schedule || {enabled:false,start:'21:00',end:'07:00'};
  $('schedule-enabled').checked = schedule.enabled;
  const quota = state.policy.quota || {enabled:false,bundleId:'com.roblox.RobloxPlayer',minutes:60};
  const appSelect = $('quota-app'); appSelect.replaceChildren();
  for (const app of state.policy.apps) {
    const option = document.createElement('option'); option.value = app.bundleId;
    option.textContent = app.name; appSelect.append(option);
  }
  appSelect.value = quota.bundleId;
  $('quota-enabled').checked = quota.enabled;
  $('quota-minutes').value = quota.minutes;
  const usage = state.quotaState;
  $('quota-status').textContent = usage ? `Today: ${Math.floor(usage.usedSeconds / 60)} / ${quota.minutes} min · ${usage.exceeded ? 'Limit reached' : usage.monitoringFresh ? 'Monitoring connected' : 'Monitoring unavailable'}` : '';
  $('schedule-start').value = schedule.start;
  $('schedule-end').value = schedule.end;
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
    remove.onclick = () => {
      state.policy.apps = state.policy.apps.filter(a => a !== app);
      if (state.policy.appRules) delete state.policy.appRules[app.bundleId];
      if (state.policy.overrides) delete state.policy.overrides[app.bundleId];
      if (state.policy.quota?.bundleId === app.bundleId) state.policy.quota.enabled = false;
      dirty = true; render(); $('message').textContent = 'Unsaved changes'; };
    row.append(text, label, remove); $('apps').append(row);
  }
  renderPerAppRules();
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
  const now = new Date();
  const dayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const dayEnd = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1).getTime();
  for (const e of data.events) {
    if (Date.parse(e.endedAt) < dayStart || Date.parse(e.startedAt) >= dayEnd) continue;
    const seconds = Math.max(0, (Math.min(Date.parse(e.endedAt), dayEnd) - Math.max(Date.parse(e.startedAt), dayStart)) / 1000);
    totals.set(e.appName, (totals.get(e.appName) || 0) + seconds);
  }
  const summary = document.createElement('p');
  summary.textContent = [...totals.entries()].sort((a,b) => b[1] - a[1]).slice(0, 5)
    .map(([name, seconds]) => `${name}: ${Math.round(seconds / 60)}m`).join(' · ') || 'No completed sessions';
  summary.prepend(document.createTextNode('Today (completed sessions): '));
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
for (const id of ['enforcement-zone', 'schedule-enabled', 'schedule-start', 'schedule-end', 'quota-enabled', 'quota-app', 'quota-minutes']) {
  $(id).addEventListener('change', () => {
    state.policy.enforcementTimeZone = $('enforcement-zone').value;
    state.policy.schedule = {
      enabled: $('schedule-enabled').checked,
      start: $('schedule-start').value,
      end: $('schedule-end').value
    };
    state.policy.quota = {enabled: $('quota-enabled').checked, bundleId: $('quota-app').value, minutes: Number($('quota-minutes').value)};
    dirty = true;
    $('message').textContent = 'Unsaved changes';
  });
}
const originalLoad = load;
load = async function () { await originalLoad(); await loadActivity(); };

function renderPerAppRules() {
  const container = $('per-app-rules'); container.replaceChildren();
  state.policy.appRules ||= {};
  state.policy.overrides ||= {};
  for (const app of state.policy.apps) {
    const rule = state.policy.appRules[app.bundleId] || {schedule:{enabled:false,start:'21:00',end:'07:00'},minutes:null};
    const wrap = document.createElement('div'); wrap.className = 'app';
    const heading = document.createElement('strong'); heading.textContent = app.name;
    const quota = document.createElement('input'); quota.type = 'number'; quota.min = 1; quota.max = 1440;
    quota.placeholder = 'No daily limit'; quota.value = rule.minutes ?? '';
    quota.setAttribute('aria-label', app.name + ' daily minutes');
    const enabled = document.createElement('input'); enabled.type = 'checkbox'; enabled.checked = rule.schedule.enabled;
    enabled.setAttribute('aria-label', app.name + ' schedule enabled');
    const start = document.createElement('input'); start.type = 'time'; start.value = rule.schedule.start;
    const end = document.createElement('input'); end.type = 'time'; end.value = rule.schedule.end;
    const override = document.createElement('button'); override.type = 'button'; override.className = 'secondary';
    override.textContent = 'Allow 30 min';
    const markDirty = () => {
      state.policy.appRules[app.bundleId] = {
        schedule:{enabled:enabled.checked,start:start.value,end:end.value},
        minutes:quota.value === '' ? null : Number(quota.value)
      };
      dirty = true; $('message').textContent = 'Unsaved changes';
    };
    for (const field of [quota,enabled,start,end]) field.addEventListener('change',markDirty);
    override.onclick = () => {
      state.policy.overrides[app.bundleId] = new Date(Date.now() + 30 * 60000).toISOString();
      dirty = true; $('message').textContent = 'Temporary allowance pending. Save changes to apply.';
    };
    wrap.append(heading,quota,enabled,start,end,override);
    container.append(wrap);
  }
}
async function loadAlerts() {
  const data = await api('/api/admin/alerts');
  $('alerts').replaceChildren();
  for (const item of data.alerts) {
    const line = document.createElement('p');
    line.textContent = `${new Date(item.created).toLocaleString()} · ${item.message}`;
    $('alerts').append(line);
  }
}
$('alerts-refresh').onclick = action(loadAlerts);

$('blocked-domains').addEventListener('change', () => {
  state.policy.blockedDomains = [...new Set($('blocked-domains').value.split(/\r?\n/).map(s => s.trim().toLowerCase()).filter(Boolean))];
  dirty = true; $('message').textContent = 'Unsaved changes';
});
