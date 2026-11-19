let token = '', state, dirty = false, busy = false;
const $ = id => document.getElementById(id);
const tabNames = ['blocking', 'monitoring', 'schedules', 'protection', 'alerts'];
let activeTab = 'blocking', usageData;
const appNames = new Map();
const duration = seconds => {
  if (seconds <= 0) return '0 min';
  if (seconds < 60) return '<1 min';
  const minutes = Math.floor(seconds / 60);
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes} min`;
};
function showTab(name) {
  if (!tabNames.includes(name)) return;
  activeTab = name;
  for (const tab of tabNames) {
    const selected = tab === name;
    $('tab-' + tab).setAttribute('aria-selected', String(selected));
    $('tab-' + tab).tabIndex = selected ? 0 : -1;
    $('panel-' + tab).hidden = !selected;
  }
}
async function refreshMonitoring() {
  await Promise.all([loadActivity(), loadUsage()]);
  renderUsageCharts();
}

async function api(path, body) {
  const response = await fetch(path, {method: body ? 'POST' : 'GET', headers: {'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json'}, ...(body ? {body: JSON.stringify(body)} : {})});
  const data = await response.json();
  if (!response.ok) throw Error(data.error || 'Request failed');
  return data;
}
let connectionSnapshot = [], connectionClockOffset = 0;
function renderConnections(devices = connectionSnapshot, serverTimeUTC) {
  connectionSnapshot = devices;
  if (serverTimeUTC && Number.isFinite(Date.parse(serverTimeUTC))) connectionClockOffset = Date.parse(serverTimeUTC) - Date.now();
  const root = $('connections-list'); root.replaceChildren();
  if (!devices.length) {
    const empty = document.createElement('p'); empty.className = 'empty';
    empty.textContent = 'No Macs have connected yet.'; root.append(empty); return;
  }
  for (const device of devices) {
    const row = document.createElement('article'); row.className = 'connection-card';
    const heading = document.createElement('div'); heading.className = 'line';
    const name = document.createElement('strong'); name.textContent = device.hostname || 'Unknown Mac (older agent)';
    const age = Date.now() + connectionClockOffset - Date.parse(device.lastSeen);
    const online = Number.isFinite(age) && age >= 0 && age <= 300000;
    const badge = document.createElement('span'); badge.className = 'connection-state ' + (online ? 'online' : 'offline');
    badge.textContent = online ? 'Recently connected' : 'Offline / overdue';
    heading.append(name, badge);
    const last = document.createElement('p');
    const time = document.createElement('time'); time.dateTime = device.lastSeen;
    time.textContent = Number.isFinite(Date.parse(device.lastSeen)) ? new Date(device.lastSeen).toLocaleString(undefined, {timeZoneName:'short'}) : 'Unknown';
    last.append('Last connected: ', time);
    const details = document.createElement('small');
    details.textContent = 'Agent ' + (device.report?.agentVersion || 'unknown') + ' · Settings revision ' + (device.report?.revision ?? 'unknown');
    row.append(heading, last, details);
    if (device.report?.lastError) {
      const error = document.createElement('p'); error.className = 'connection-error';
      error.textContent = device.report.lastError; row.append(error);
    }
    root.append(row);
  }
}
async function refreshConnections() {
  try {
    const data = await api('/api/admin/connections');
    renderConnections(data.devices, data.serverTimeUTC);
    $('connections-note').textContent = 'Updates every 15 seconds. Recent means a check-in within five minutes.';
  } catch (error) {
    renderConnections();
    $('connections-note').textContent = 'Connection status could not be refreshed: ' + error.message;
  }
}
$('connections-refresh').onclick = action(refreshConnections);
function render() {
  renderConnections(state.devices || (state.device ? [state.device] : []), state.serverTimeUTC);
  if (!dirty) $('blocked-domains').value = (state.policy.blockedDomains || []).join('\n');
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
  $('status').textContent = !device ? 'Waiting for the Mac to connect' : `${age > 300000 ? 'Mac offline or overdue' : 'Mac connected'} · Last seen ${new Date(device.lastSeen).toLocaleString()} · ${device.report.revision === state.policy.revision ? 'Settings received' : 'Update pending'} (revision ${device.report.revision}/${state.policy.revision}) · Agent ${device.report.agentVersion}`;
  $('health').textContent = device?.report.lastError ? `Agent needs attention: ${device.report.lastError}` : '';
}
async function load() { if (dirty) throw Error('Save your changes, or use Discard changes and reload.'); state = await api('/api/admin/state'); $('controls').hidden = false; $('login').hidden = true; render(); }
function action(fn) { return async event => {
  event?.preventDefault();
  if (busy) return;
  busy = true;
  const disable = value => document.querySelectorAll('button, input, select, textarea').forEach(element => { element.disabled = value; });
  disable(true); $('message').textContent = '';
  try { await fn(); } catch (error) { $('message').textContent = error.message; }
  finally { busy = false; disable(false); updateSaveState(); }
}; }
$('connect').onclick = action(async () => { token = $('token').value; await load(); $('token').value = ''; await refreshMonitoring(); });
$('refresh').onclick = action(load);
$('discard').onclick = action(async () => {
  // Do not drop edits until the replacement state has arrived successfully.
  const fresh = await api('/api/admin/state');
  state = fresh; dirty = false; render();
});
$('save').onclick = action(async () => { state.policy = await api('/api/admin/policy', state.policy); dirty = false; render(); $('message').textContent = 'Saved. Waiting for the Mac to receive these settings.'; });
$('add').onsubmit = action(async () => { const name = $('name').value.trim(), bundleId = $('bundle').value.trim(); if (!name || name.length > 80) throw Error('Enter an app name of at most 80 characters.'); if (state.policy.apps.length >= 100) throw Error('At most 100 apps can be configured.'); if (bundleId.length > 255) throw Error('Bundle identifier is too long.'); if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(bundleId) || (bundleId !== 'com.apple.Safari' && /^(com\.apple\.|com\.side-forge\.orbit\.)/i.test(bundleId))) throw Error('Use a non-system app bundle identifier or com.apple.Safari.'); if (state.policy.apps.some(a => a.bundleId === bundleId)) throw Error('That app is already listed.'); state.policy.apps.push({name, bundleId, blocked: false}); dirty = true; render(); $('add').reset(); $('message').textContent = 'App added. Save changes to send it to the Mac.'; });
window.addEventListener('beforeunload', event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });

async function loadActivity() {
  const data = await api('/api/admin/activity');
  for (const event of data.events) appNames.set(event.bundleId, event.appName);
  if (data.current) appNames.set(data.current.bundleId, data.current.appName);
  const last = data.lastSeen ? Date.parse(data.lastSeen) : 0;
  const fresh = last && Date.now() - last < 120000;
  $('current-app').textContent = fresh && data.current ? data.current.appName : fresh ? 'Idle or inactive' : 'Not connected';
  $('activity-current').textContent = fresh && data.current
    ? `Foreground: ${data.current.appName} (since ${new Date(data.current.since).toLocaleTimeString()})`
    : data.lastSeen ? `No current activity confirmed · Last update ${new Date(data.lastSeen).toLocaleString()}` : 'No activity reported';
  const container = $('activity-events');
  container.replaceChildren();
  for (const e of data.events.slice(0, 50)) {
    const row = document.createElement('div');
    row.className = 'session';
    const seconds = Math.max(0, (Date.parse(e.endedAt) - Date.parse(e.startedAt)) / 1000);
    row.textContent = `${e.appName} · ${new Date(e.startedAt).toLocaleString()} · ${duration(seconds)}`;
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
    const field = (text, input) => {
      const label = document.createElement('label');
      const caption = document.createElement('span'); caption.textContent = text;
      label.append(caption, input); return label;
    };
    wrap.append(heading, field('Daily minutes', quota), field('Restricted hours enabled', enabled),
      field('Start', start), field('End', end), override);
    container.append(wrap);
  }
}
async function loadAlerts() {
  const data = await api('/api/admin/alerts');
  $('alerts').replaceChildren();
  if (!data.alerts.length) { const empty = document.createElement('p'); empty.className = 'empty'; empty.textContent = 'No alerts recorded.'; $('alerts').append(empty); }
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

async function loadSecurityHealth() {
  const result = await api('/api/admin/health');
  $('security-health').textContent =
    'Daemon: ' + (result.deviceConnected ? 'recently connected' : 'not recently connected') +
    ' · Foreground monitor: ' + (result.monitorConnected ? 'recently connected' : 'not recently connected') +
    ' · Browser filtering: ' + (result.browserProtectionVerified ? 'verified' : 'NOT VERIFIED');
}
$('security-refresh').onclick = action(loadSecurityHealth);

async function loadUsage() {
  const data = await api('/api/admin/usage');
  usageData = data;
  $('usage-summary').textContent = 'Retaining ' + data.retentionDays +
    ' days · Time zone: ' + data.timeZone +
    ' · Website usage is sampled foreground-tab time, not exact browsing duration.';
  const root = $('usage-report');
  root.replaceChildren();
  const format = duration;
  for (const [kind, items] of [['Applications', data.apps], ['Websites', data.websites]]) {
    const heading = document.createElement('h3'); heading.textContent = kind;
    root.append(heading);
    if (!items.length) {
      const empty = document.createElement('p');
      empty.textContent = 'No usage recorded yet'; root.append(empty);
    }
    for (const item of items) {
      const section = document.createElement('details');
      const title = document.createElement('summary');
      const name = kind === 'Applications' ? (state?.policy?.apps || []).find(a => a.bundleId === item.id)?.name : null;
      title.textContent = (name ? name + ' (' + item.id + ')' : item.id) + ' · ' +
        format(Object.values(item.days).reduce((a,b)=>a+b,0)) + ' total';
      section.append(title);
      for (const [label, values] of [['Daily', item.days], ['Weekly (Monday start)', item.weeks]]) {
        const h = document.createElement('strong'); h.textContent = label;
        section.append(h);
        const list = document.createElement('ul');
        for (const [date, seconds] of Object.entries(values).sort((a,b)=>b[0].localeCompare(a[0]))) {
          const li = document.createElement('li');
          li.textContent = date + ': ' + format(seconds);
          list.append(li);
        }
        section.append(list);
      }
      root.append(section);
    }
  }
  renderUsageCharts();
}
$('usage-refresh').onclick = action(refreshMonitoring);

function updateSaveState() {
  $('save-state').textContent = dirty ? 'Unsaved changes' : 'Settings up to date';
}
for (const event of ['change', 'click', 'submit']) {
  $('controls').addEventListener(event, updateSaveState);
}
for (const [index, name] of tabNames.entries()) {
  $('tab-' + name).onclick = action(async () => {
    showTab(name);
    if (name === 'monitoring') await refreshMonitoring();
    if (name === 'protection') await loadSecurityHealth();
    if (name === 'alerts') await loadAlerts();
  });
  $('tab-' + name).addEventListener('keydown', event => {
    let next;
    if (event.key === 'ArrowRight') next = (index + 1) % tabNames.length;
    if (event.key === 'ArrowLeft') next = (index + tabNames.length - 1) % tabNames.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabNames.length - 1;
    if (next === undefined) return;
    event.preventDefault();
    // Manual activation: arrows move focus; Enter/Space opens the focused tab.
    $('tab-' + tabNames[next]).focus();
  });
}
function emptyChart(root, message) {
  const empty = document.createElement('p'); empty.className = 'empty';
  empty.textContent = message; root.append(empty);
}
function renderUsageCharts() {
  if (!usageData) return;
  const today = usageData.endDate;
  if (!today) return;
  const dates = Array.from({length: 7}, (_, i) => {
    const date = new Date(today + 'T12:00:00Z');
    date.setUTCDate(date.getUTCDate() - 6 + i);
    return date.toISOString().slice(0, 10);
  });
  const total = (item, days) => days.reduce((sum, day) => sum + (item.days[day] || 0), 0);
  const daily = dates.map(day => usageData.apps.reduce((sum, item) => sum + (item.days[day] || 0), 0));
  $('today-total').textContent = duration(daily[6]);
  $('today-date').textContent = today + ' · ' + usageData.timeZone;
  $('week-total').textContent = duration(daily.reduce((a, b) => a + b, 0));
  const chart = $('daily-chart'); chart.replaceChildren();
  if (!daily.some(value => value > 0)) {
    emptyChart(chart, 'No app time recorded in the past seven days. Start the tracker and use an app for about 30 seconds.');
  } else {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 700 210'); svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', 'Daily foreground app time: ' + dates.map((day, i) => day + ': ' + duration(daily[i])).join('; '));
    const peak = Math.max(...daily, 1);
    const element = (tag, attributes, text) => {
      const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
      for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value));
      if (text !== undefined) node.textContent = text;
      return node;
    };
    dates.forEach((day, i) => {
      const height = daily[i] / peak * 145;
      const bar = element('rect', {x: i * 100 + 25, y: 175 - height, width: 50, height, rx: 6});
      bar.append(element('title', {}, day + ': ' + duration(daily[i]))); svg.append(bar);
      svg.append(element('text', {x: i * 100 + 50, y: 165 - height, 'text-anchor': 'middle', class: 'value'}, duration(daily[i])));
      svg.append(element('text', {x: i * 100 + 50, y: 201, 'text-anchor': 'middle'},
        new Date(day + 'T12:00:00Z').toLocaleDateString(undefined, {weekday: 'short', day: 'numeric', timeZone: 'UTC'})));
    });
    chart.append(svg);
  }
  const days = $('usage-period').value === 'week' ? dates : [today];
  for (const [id, items] of [['app-chart', usageData.apps], ['website-chart', usageData.websites]]) {
    const root = $(id); root.replaceChildren();
    const ranked = items.map(item => ({item, seconds: total(item, days)})).filter(row => row.seconds > 0).sort((a, b) => b.seconds - a.seconds);
    if (!ranked.length) { emptyChart(root, id === 'app-chart' ? 'No app usage recorded for this period.' : 'No website usage recorded for this period. Browser extension required.'); continue; }
    const maximum = ranked[0].seconds;
    for (const {item, seconds} of ranked) {
      const name = id === 'app-chart' ? appNames.get(item.id) || state?.policy?.apps.find(app => app.bundleId === item.id)?.name || item.id : item.id;
      const row = document.createElement('div'); row.className = 'rank-row';
      const label = document.createElement('div'); label.className = 'rank-label';
      const title = document.createElement('span'); title.textContent = name; title.title = item.id;
      const value = document.createElement('strong'); value.textContent = duration(seconds);
      label.append(title, value);
      const meter = document.createElement('meter'); meter.min = 0; meter.max = maximum; meter.value = seconds;
      meter.setAttribute('aria-label', name + ': ' + duration(seconds));
      row.append(label, meter); root.append(row);
    }
  }
}
$('usage-period').addEventListener('change', renderUsageCharts);
window.setInterval(() => {
  if (!token || busy || document.hidden) return;
  void action(async () => {
    await refreshConnections();
    if (activeTab === 'monitoring') await refreshMonitoring();
  })();
}, 15000);

async function connectFromLink() {
  const supplied = new URLSearchParams(window.location.hash.slice(1)).get('token');
  if (!supplied) return;
  // Consume the fragment before making requests; keep credentials in tab memory.
  window.history.replaceState(null, '', window.location.pathname + window.location.search);
  $('token').value = supplied;
  await $('connect').onclick();
  $('token').value = '';
}
void connectFromLink();
