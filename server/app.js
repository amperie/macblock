let token = '', state, dirty = false, busy = false;
const $ = id => document.getElementById(id);
const tabNames = ['monitoring', 'blocking', 'websites', 'protection'];
let backgroundBusy = false;
let activeTab = 'monitoring', usageData, usageGeneration = 0, usageAvailable = false;
const appNames = new Map();
const appViews = new Map();
const appCards = new Map();
let activityGeneration = 0, healthGeneration = 0;
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
async function waitForRequests(requests) {
  // A failed request must not release the action lock while others can still update the UI.
  const results = await Promise.allSettled(requests);
  const failed = results.filter(result => result.status === 'rejected');
  if (failed.length) throw Error(failed.map(result => result.reason.message).join('; '));
}
async function refreshMonitoring() {
  try { await waitForRequests([loadActivity(), loadUsage(), loadSecurityHealth()]); }
  finally { renderUsageCharts(); updateAppSummaries(); }
}
function watchEdits(element, listener) {
  for (const event of ['input', 'change']) element.addEventListener(event, listener);
}

async function api(path, body) {
  const controller = new AbortController();
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = window.setTimeout(() => {
      reject(Error(body ? 'Request timed out. The server may have received the change; reload before retrying.' : 'Request timed out. Try refreshing again.'));
      controller.abort();
    }, 15000);
  });
  try {
    // Include JSON parsing in the deadline: a stalled response body must not lock the UI either.
    const request = (async () => {
      const response = await fetch(path, {signal:controller.signal, method:body ? 'POST' : 'GET', headers:{'Authorization':`Bearer ${token}`, 'Content-Type':'application/json'}, ...(body ? {body:JSON.stringify(body)} : {})});
      const data = await response.json();
      if (!response.ok) throw Error(data.error || 'Request failed');
      return data;
    })();
    return await Promise.race([request, deadline]);
  } finally { window.clearTimeout(timer); }
}

let connectionSnapshot = [], connectionClockOffset = 0, connectionGeneration = 0;
function acceptServerTime(serverTimeUTC) {
  if (Number.isFinite(Date.parse(serverTimeUTC))) connectionClockOffset = Date.parse(serverTimeUTC) - Date.now();
}
function acceptConnections(data) {
  state.devices = data.devices;
  state.serverTimeUTC = data.serverTimeUTC;
  const latest = [...data.devices].sort((a,b) => Date.parse(b.lastSeen) - Date.parse(a.lastSeen))[0];
  state.device = latest ? {report:latest.report,lastSeen:latest.lastSeen} : null;
  renderConnections(data.devices, data.serverTimeUTC);
  renderDeviceStatus();
  updateSaveState();
}
function renderConnections(devices = connectionSnapshot, serverTimeUTC) {
  connectionSnapshot = devices;
  if (serverTimeUTC) acceptServerTime(serverTimeUTC);
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
    const delivery = document.createElement('small');
    delivery.textContent = device.report?.revision === state?.policy?.revision ? 'Mac received settings' : 'Waiting for Mac to receive settings';
    row.append(heading, last, delivery);
    const advanced = document.createElement('details');
    const summary = document.createElement('summary'); summary.textContent = 'Connection details';
    advanced.append(summary, details);
    if (device.report?.lastError) {
      const error = document.createElement('p'); error.className = 'connection-error';
      error.textContent = device.report.lastError; row.append(error);
    }
    const remove = document.createElement('button'); remove.type = 'button';
    remove.className = 'secondary'; remove.textContent = 'Delete';
    remove.setAttribute('aria-label', `Delete connection for ${device.hostname || 'Unknown Mac (older agent)'}`);
    remove.onclick = action(async () => {
      if (!window.confirm('Remove this connection record? This does not uninstall or disconnect the agent. It will reappear when the Mac checks in.')) return;
      ++connectionGeneration; // Invalidate connection reads started before this deletion.
      const data = await api('/api/admin/connections/delete', {hostname: device.hostname ?? null});
      acceptConnections(data);
      $('connections-note').textContent = 'Connection entry deleted. The Mac will reappear if it checks in again.';
    });
    advanced.append(remove); row.append(advanced);
    root.append(row);
  }
}
async function refreshConnections() {
  const generation = ++connectionGeneration;
  try {
    const data = await api('/api/admin/connections');
    if (generation !== connectionGeneration) return;
    acceptConnections(data);
    $('connections-note').textContent = 'Updates every 15 seconds. Recent means a check-in within five minutes.';
  } catch (error) {
    if (generation !== connectionGeneration) return;
    renderConnections();
    renderDeviceStatus();
    $('connections-note').textContent = 'Connection status could not be refreshed: ' + error.message;
  }
}
$('connections-refresh').onclick = action(refreshConnections);
function render() {
  renderConnections(state.devices || (state.device ? [state.device] : []));
  $('blocked-domains').value = (state.policy.blockedDomains || []).join('\n');
  renderDomains();
  const zone = $('enforcement-zone');
  zone.replaceChildren();
  for (const id of state.timeZones || ['America/Los_Angeles']) {
    const option = document.createElement('option'); option.value = id;
    option.textContent = id.replaceAll('_', ' '); zone.append(option);
  }
  zone.value = state.policy.enforcementTimeZone || 'America/Los_Angeles';
  const schedule = state.policy.schedule || {enabled:false,start:'21:00',end:'07:00'};
  $('schedule-enabled').checked = schedule.enabled;
  renderQuotaControls();
  $('schedule-start').value = schedule.start;
  $('schedule-end').value = schedule.end;
  renderAppCards();
  renderQuotaStatus();
  renderUsageCharts();
  updateSaveState();
  renderDeviceStatus();
  if (busy) setControlsDisabled(true);
}
function renderQuotaControls(preserveMinutes = false) {
  const quota = state.policy.quota || {enabled:false,bundleId:'com.roblox.RobloxPlayer',minutes:60};
  const appSelect = $('quota-app'); appSelect.replaceChildren();
  for (const app of state.policy.apps) {
    const option = document.createElement('option'); option.value = app.bundleId;
    option.textContent = app.name; appSelect.append(option);
  }
  appSelect.value = state.policy.apps.some(app => app.bundleId === quota.bundleId) ? quota.bundleId : state.policy.apps[0]?.bundleId || '';
  $('quota-enabled').checked = quota.enabled;
  if (!preserveMinutes) $('quota-minutes').value = quota.minutes;
}
function refreshAppList() {
  renderAppCards(true);
  // Update the selector without rewriting potentially incomplete numeric drafts in Settings.
  renderQuotaControls(true);
  renderQuotaStatus(); updateSaveState();
}
function renderDeviceStatus() {
  const device = state.device;
  const age = device ? Date.now() + connectionClockOffset - Date.parse(device.lastSeen) : Infinity;
  $('status').textContent = !device ? 'Waiting for the Mac to connect' : `${!Number.isFinite(age) || age < 0 || age > 300000 ? 'Mac offline or overdue' : 'Mac connected'} · Last seen ${new Date(device.lastSeen).toLocaleString()} · ${device.report.revision === state.policy.revision ? 'Settings received' : 'Update pending'} (revision ${device.report.revision}/${state.policy.revision}) · Agent ${device.report.agentVersion}`;
  $('health').textContent = device?.report.lastError ? `Agent needs attention: ${device.report.lastError}` : '';
}
async function load() { if (dirty) throw Error('Save your changes, or use Discard changes and reload.'); state = await api('/api/admin/state'); ++connectionGeneration; acceptServerTime(state.serverTimeUTC); $('controls').hidden = false; $('login').hidden = true; render(); }
function setControlsDisabled(value) {
  document.querySelectorAll('button, input, select, textarea').forEach(element => { element.disabled = value; });
}
function action(fn) { return async event => {
  event?.preventDefault();
  if (busy) return;
  busy = true;
  setControlsDisabled(true); $('message').textContent = '';
  try { await fn(); } catch (error) { $('message').textContent = error.message; }
  finally { busy = false; setControlsDisabled(false); updateSaveState(); }
}; }
let iosPolicy, iosDirty = false;
async function loadIPhones(discard = false) {
  const data = await api('/api/admin/ios/state');
  if (!iosDirty || discard) {
  iosPolicy = data.policy;
  $('ios-blocked').checked = iosPolicy.blocked;
  $('ios-limited').checked = iosPolicy.dailyMinutes !== null;
  $('ios-minutes').value = iosPolicy.dailyMinutes ?? 60;
  const zones = $('ios-zone'); zones.replaceChildren();
  for (const name of [...new Set([...(state?.timeZones || []), iosPolicy.timeZone])]) {
    const option = document.createElement('option'); option.value = name; option.textContent = name;
    zones.append(option);
  }
  zones.value = iosPolicy.timeZone;
  iosDirty = false;
  }
  const root = $('ios-devices'); root.replaceChildren();
  for (const device of data.enrolled || []) {
    const card = document.createElement('article'); card.className = 'connection-card';
    const title = document.createElement('strong'); title.textContent = 'iPhone · ' + device.installationID.slice(0, 8);
    const status = data.devices.find(item => item.report.installationID.toLowerCase() === device.installationID.toLowerCase());
    const description = document.createElement('p');
    description.textContent = status ? `${status.report.authorized ? 'Screen Time authorized' : 'Authorization needed'} · ${status.report.applicationCount} selected apps · revision ${status.report.revision}/${data.policy.revision} · Last sync ${new Date(status.lastSeen).toLocaleString()}` : 'Enrolled · waiting for first status upload';
    const revoke = document.createElement('button'); revoke.type = 'button'; revoke.className = 'secondary';
    revoke.textContent = 'Revoke access'; revoke.disabled = busy;
    revoke.onclick = action(async () => {
      if (!window.confirm('Revoke this iPhone’s server access? Downloaded rules remain on the phone. This does not uninstall Orbit or remove Apple Screen Time restrictions.')) return;
      await api('/api/admin/ios/revoke', {installationID:device.installationID});
      await loadIPhones();
    });
    card.append(title, description, revoke); root.append(card);
  }
  if (!(data.enrolled || []).length) {
    const empty = document.createElement('p'); empty.textContent = 'No iPhones enrolled with a setup code yet.'; root.append(empty);
  }
  $('ios-note').textContent = iosDirty ? 'Unsaved iPhone changes kept. Save iPhone rules to send them.' : 'iPhone settings loaded. Save iPhone rules separately from Mac settings. Local shield status is not proof of enforcement.';
}
for (const id of ['ios-blocked', 'ios-limited', 'ios-minutes', 'ios-zone']) watchEdits($(id), () => {
  iosDirty = true; $('ios-note').textContent = 'Unsaved iPhone changes. Use Save iPhone rules to send them.';
});
$('ios-refresh').onclick = action(async () => {
  if (iosDirty && !window.confirm('Discard unsaved iPhone rules and reload?')) return;
  await loadIPhones(true);
});
$('ios-pair').onclick = action(async () => {
  // Never leave an old, now-invalid code visible if generating its replacement fails.
  $('ios-code').textContent = '';
  const result = await api('/api/admin/ios/pair', {});
  $('ios-code').textContent = result.code;
  $('ios-code-note').textContent = 'Enter this code in Orbit on the iPhone. It works once and expires at ' + new Date(result.expiresAt).toLocaleTimeString() + '. A new code replaces this one.';
});
$('ios-save').onclick = action(async () => {
  if (!iosPolicy) throw Error('Refresh iPhones before saving iPhone rules.');
  const minutes = Number($('ios-minutes').value);
  if ($('ios-limited').checked && (!Number.isInteger(minutes) || minutes < 1 || minutes > 1440)) throw Error('Enter an iPhone allowance from 1 to 1440 minutes.');
  iosPolicy = await api('/api/admin/ios/policy', {...iosPolicy, blocked:$('ios-blocked').checked,
    dailyMinutes:$('ios-limited').checked ? minutes : null, timeZone:$('ios-zone').value});
  iosDirty = false;
  $('ios-note').textContent = 'iPhone rules saved. Open Orbit or tap Sync on the phone to apply them.';
});
$('connect').onclick = action(async () => { token = $('token').value; await load(); $('token').value = ''; await refreshMonitoring(); });
$('refresh').onclick = action(load);
$('discard').onclick = action(async () => {
  // Do not drop edits until the replacement state has arrived successfully.
  const fresh = await api('/api/admin/state');
  state = fresh; ++connectionGeneration; acceptServerTime(state.serverTimeUTC); dirty = false; render();
});
const savePolicy = action(async () => {
  state.policy = await api('/api/admin/policy', state.policy);
  dirty = false; render();
  $('message').textContent = 'Saved. Waiting for the Mac to receive these settings.';
  if (usageData && state.policy.enforcementTimeZone && usageData.timeZone !== state.policy.enforcementTimeZone) {
    try { await loadUsage(); updateAppSummaries(); }
    catch (error) { $('message').textContent = 'Settings saved. Usage refresh failed: ' + error.message; }
  }
});
$('save').onclick = event => {
  for (const input of document.querySelectorAll('.rule-fields input, #panel-protection input, #quota-app')) {
    if (input.id?.startsWith('ios-')) continue;
    if (!input.checkValidity()) {
      event?.preventDefault(); showTab(input.closest('#panel-protection') ? 'protection' : 'blocking');
      const details = input.closest('details'); if (details) details.open = true;
      input.reportValidity(); return;
    }
  }
  const rules = [{name:'Shared', schedule:state.policy.schedule}, ...Object.entries(state.policy.appRules || {}).map(([id,rule]) => ({name:state.policy.apps.find(app => app.bundleId === id)?.name || id, schedule:rule.schedule}))];
  for (const {name,schedule} of rules) {
    if (schedule && (!schedule.start || !schedule.end || schedule.start === schedule.end)) {
      $('message').textContent = `${name}: choose different start and end times.`; return;
    }
  }
  if (state.policy.quota?.enabled && !state.policy.apps.some(app => app.bundleId === state.policy.quota.bundleId)) {
    $('message').textContent = 'Choose a configured app for the additional daily allowance.'; showTab('protection'); return;
  }
  return savePolicy(event);
};
$('add').onsubmit = action(async () => { const name = $('name').value.trim(), bundleId = $('bundle').value.trim(); if (!name || name.length > 80) throw Error('Enter an app name of at most 80 characters.'); if (state.policy.apps.length >= 100) throw Error('At most 100 apps can be configured.'); if (bundleId.length > 255) throw Error('Bundle identifier is too long.'); if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/.test(bundleId) || (bundleId !== 'com.apple.Safari' && /^(com\.apple\.|com\.side-forge\.orbit\.)/i.test(bundleId))) throw Error('Use a non-system app bundle identifier or com.apple.Safari.'); if (state.policy.apps.some(a => a.bundleId === bundleId)) throw Error('That app is already listed.'); state.policy.apps.push({name, bundleId, blocked: false}); dirty = true; refreshAppList(); $('add').reset(); $('message').textContent = 'App added. Save changes to send it to the Mac.'; });
window.addEventListener('beforeunload', event => { if (dirty || iosDirty) { event.preventDefault(); event.returnValue = ''; } });

async function loadActivity() {
  const generation = ++activityGeneration;
  try {
    const data = await api('/api/admin/activity');
    if (generation !== activityGeneration) return;
    for (const event of data.events) appNames.set(event.bundleId, event.appName);
    if (data.current) appNames.set(data.current.bundleId, data.current.appName);
    const last = data.lastSeen ? Date.parse(data.lastSeen) : 0;
    const fresh = last && Date.now() + connectionClockOffset - last >= 0 && Date.now() + connectionClockOffset - last < 120000;
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
  } catch (error) {
    if (generation !== activityGeneration) return;
    $('current-app').textContent = 'Unavailable';
    $('activity-current').textContent = 'Current activity could not be refreshed. ' + error.message;
    throw error;
  }
}
$('activity-refresh').onclick = action(loadActivity);
watchEdits($('enforcement-zone'), () => {
  state.policy.enforcementTimeZone = $('enforcement-zone').value;
  markEdited(); updateAppSummaries();
});
for (const id of ['schedule-enabled', 'schedule-start', 'schedule-end']) {
  watchEdits($(id), () => {
    state.policy.schedule = {enabled:$('schedule-enabled').checked, start:$('schedule-start').value, end:$('schedule-end').value};
    markEdited(); updateAppSummaries();
  });
}
for (const id of ['quota-enabled', 'quota-app', 'quota-minutes']) {
  watchEdits($(id), () => {
    const previous = state.policy.quota;
    state.policy.quota = {
      enabled:$('quota-enabled').checked,
      bundleId:$('quota-app').value || previous?.bundleId || 'com.roblox.RobloxPlayer',
      minutes:Number($('quota-minutes').value)
    };
    markEdited(); updateAppSummaries();
  });
}

function usageMatchesZone() {
  return !state?.policy?.enforcementTimeZone || usageData?.timeZone === state.policy.enforcementTimeZone;
}
function usableUsage() {
  return Boolean(usageData && usageAvailable && usageMatchesZone());
}
function appUsageLabel(id) {
  if (!usageData) return 'Usage not loaded';
  if (!usageAvailable) return 'Usage unavailable · ' + allowanceLabel(id);
  if (!usageMatchesZone()) return 'Usage awaiting time zone refresh · ' + allowanceLabel(id);
  return `${duration(todayUsage(id))} used today · ${allowanceLabel(id)}`;
}
function renderQuotaStatus() {
  const quota = state?.policy?.quota;
  if (!quota?.enabled) { $('quota-status').textContent = 'Additional allowance disabled.'; return; }
  if (usageData && !usageAvailable) { $('quota-status').textContent = 'Usage unavailable. Additional allowance: ' + quota.minutes + ' min/day.'; return; }
  if (usageData && !usageMatchesZone()) { $('quota-status').textContent = 'Save the time zone change to recalculate usage.'; return; }
  const used = usageData ? todayUsage(quota.bundleId) : state.quotaState?.bundleId === quota.bundleId ? state.quotaState.usedSeconds : null;
  $('quota-status').textContent = used === null ? 'Usage not loaded' :
    `Today: ${duration(used)} / ${quota.minutes} min · ${used >= quota.minutes * 60 ? 'Limit reached' : 'Below limit'}`;
}
function dailyLimit(id) {
  const policy = state?.policy;
  const limits = [];
  const minutes = policy?.appRules?.[id]?.minutes;
  if (minutes != null) limits.push(minutes);
  if (policy?.quota?.enabled && policy.quota.bundleId === id) limits.push(policy.quota.minutes);
  return limits.length ? Math.min(...limits) : null;
}
function todayUsage(id) {
  return usageData?.apps.find(item => item.id === id)?.days[usageData.endDate] || 0;
}
function allowanceLabel(id, weekly = false) {
  const limit = dailyLimit(id);
  if (limit === null) return 'No daily limit';
  return `${limit} min/day` + (weekly || !usableUsage() ? '' : ` · ${duration(Math.max(0, limit * 60 - todayUsage(id)))} remaining`);
}
function appStatus(app) {
  if (app.blocked) return 'Blocked manually';
  const until = Date.parse(state.policy.overrides?.[app.bundleId]);
  const now = Date.now() + connectionClockOffset;
  if (until > now) return 'Temporary allowance until ' + new Date(until).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'});
  const rule = state.policy.appRules?.[app.bundleId];
  const schedule = rule?.schedule || state.policy.schedule;
  if (schedule?.enabled) {
    const clock = new Intl.DateTimeFormat('en-GB', {timeZone:state.policy.enforcementTimeZone || 'America/Los_Angeles',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).format(new Date(now));
    const blocked = schedule.start < schedule.end ? clock >= schedule.start && clock < schedule.end : clock >= schedule.start || clock < schedule.end;
    if (blocked) return `Restricted hours · until ${schedule.end}`;
  }
  const limit = dailyLimit(app.bundleId);
  if (limit !== null && usableUsage() && todayUsage(app.bundleId) >= limit * 60) return 'Daily limit reached';
  if (limit !== null) return allowanceLabel(app.bundleId);
  return 'No daily limit' + (schedule?.enabled ? ' · Restricted hours set' : ' · No restricted hours');
}
function markEdited(message = 'Unsaved changes') {
  dirty = true; $('message').textContent = message; updateSaveState(); renderUsageCharts();
}
function updateAppSummaries() {
  renderQuotaStatus();
  for (const app of state?.policy?.apps || []) appViews.get(app.bundleId)?.();
}
function renderAppCards(preserveEditors = false) {
  if (!state) return;
  const container = $('apps');
  if (!preserveEditors) { container.replaceChildren(); appViews.clear(); appCards.clear(); }
  else {
    const retained = new Set(state.policy.apps.map(app => app.bundleId));
    for (const [id,card] of appCards) {
      if (!retained.has(id)) { card.remove(); appCards.delete(id); appViews.delete(id); }
    }
    if (!appCards.size) container.replaceChildren();
  }
  state.policy.appRules ||= {};
  state.policy.overrides ||= {};
  for (const app of state.policy.apps) {
    if (preserveEditors && appCards.has(app.bundleId)) continue;
    const wrap = document.createElement('article'); wrap.className = 'app-card';
    const heading = document.createElement('div'); heading.className = 'app-heading';
    const icon = document.createElement('span'); icon.className = 'app-icon'; icon.textContent = app.name.slice(0,1).toUpperCase(); icon.setAttribute('aria-hidden','true');
    const titleGroup = document.createElement('div');
    const title = document.createElement('strong'); title.textContent = app.name;
    const status = document.createElement('p'); status.className = 'app-state'; status.textContent = appStatus(app);
    titleGroup.append(title,status); heading.append(icon,titleGroup);
    const usage = document.createElement('div'); usage.className = 'app-usage';
    const usageText = document.createElement('small');
    usageText.textContent = appUsageLabel(app.bundleId);
    usage.append(usageText);
    const meter = document.createElement('meter');
    const updateMeter = () => {
      const limit = dailyLimit(app.bundleId);
      meter.hidden = limit === null || !usableUsage(); meter.min=0; meter.max=(limit || 1)*60; meter.value=todayUsage(app.bundleId);
      meter.setAttribute('aria-label',`${app.name}: ${duration(todayUsage(app.bundleId))} of ${limit} minutes today`);
    };
    const updateSummary = () => {
      updateMeter(); status.textContent = appStatus(app);
      usageText.textContent = appUsageLabel(app.bundleId);
    };
    updateMeter(); usage.append(meter);
    const block = document.createElement('label'); block.className = 'switch';
    const toggle = document.createElement('input'); toggle.type='checkbox'; toggle.checked=app.blocked;
    toggle.setAttribute('aria-label',`Block ${app.name} manually`);
    block.append('Block manually',toggle);
    const editor = document.createElement('details'); editor.className='rule-fields';
    const summary = document.createElement('summary'); summary.textContent='Limits & restricted hours'; editor.append(summary);
    const rule = state.policy.appRules[app.bundleId];
    // An absent app schedule inherits shared hours. Preserve that distinction on limit edits.
    const inherited = !rule;
    const schedule = rule?.schedule || state.policy.schedule || {enabled:false,start:'21:00',end:'07:00'};
    let scheduleEdited = false;
    let sharedScheduleSignature = JSON.stringify(state.policy.schedule);
    const field = (text,input) => { const label=document.createElement('label'); const caption=document.createElement('span'); caption.textContent=text; label.append(caption,input); return label; };
    const quota=document.createElement('input'); quota.type='number'; quota.min=1; quota.max=1440; quota.inputMode='numeric'; quota.placeholder='No daily limit'; quota.value=rule?.minutes ?? '';
    quota.setAttribute('aria-label',app.name+' daily minutes');
    const enabled=document.createElement('input'); enabled.type='checkbox'; enabled.checked=schedule.enabled; enabled.setAttribute('aria-label',app.name+' restricted hours');
    const start=document.createElement('input'); start.type='time'; start.required=true; start.value=schedule.start;
    const end=document.createElement('input'); end.type='time'; end.required=true; end.value=schedule.end;
    const grid=document.createElement('div'); grid.className='field-grid'; grid.append(field('From',start),field('Until',end));
    const note=document.createElement('small');
    const updateEditorContext = () => {
      const inheritsNow = !state.policy.appRules[app.bundleId];
      const signature = JSON.stringify(state.policy.schedule);
      if (inheritsNow && state.policy.schedule && signature !== sharedScheduleSignature) {
        enabled.checked = state.policy.schedule.enabled;
        start.value = state.policy.schedule.start; end.value = state.policy.schedule.end;
      }
      sharedScheduleSignature = signature;
      note.textContent = 'Blank means no per-app limit. Hours use ' + (state.policy.enforcementTimeZone || 'America/Los_Angeles') + '.' +
        (inheritsNow ? ' Currently inherits shared hours.' : '') +
        (state.policy.quota?.enabled && state.policy.quota.bundleId === app.bundleId ? ` An additional ${state.policy.quota.minutes} min daily allowance is enabled in Settings; the lower limit applies.` : '');
    };
    updateEditorContext();
    appViews.set(app.bundleId, () => { updateSummary(); updateEditorContext(); });
    const apply = () => {
      const minutes=quota.value==='' ? null : Number(quota.value);
      // Do not accidentally exempt this app from shared schedules when only editing its limit.
      const nextSchedule = {enabled:enabled.checked,start:start.value,end:end.value};
      if (inherited && !scheduleEdited && minutes===null) delete state.policy.appRules[app.bundleId];
      else state.policy.appRules[app.bundleId]={schedule:nextSchedule,minutes};
      markEdited(); updateEditorContext(); updateMeter(); status.textContent=appStatus(app);
      usageText.textContent=appUsageLabel(app.bundleId);
    };
    quota.addEventListener('input',apply);
    for (const input of [enabled,start,end]) watchEdits(input,()=>{scheduleEdited=true;apply();});
    toggle.onchange=()=>{app.blocked=toggle.checked;markEdited();status.textContent=appStatus(app);};
    const override=document.createElement('button'); override.type='button';override.className='secondary';override.textContent='Allow for 30 min';
    override.onclick=()=>{state.policy.overrides[app.bundleId]=new Date(Date.now()+connectionClockOffset+30*60000).toISOString();markEdited('Temporary allowance pending. Save changes to apply.');status.textContent=appStatus(app);};
    const hint=document.createElement('small');hint.textContent='Bypasses limits and hours. Manual blocks still apply. Save to activate.';
    editor.append(field('Daily limit (minutes)',quota),field('Restricted hours',enabled),grid,note,override,hint);
    const advanced=document.createElement('details');advanced.className='advanced';
    const advancedTitle=document.createElement('summary');advancedTitle.textContent='Advanced details';
    const identifier=document.createElement('small');identifier.textContent=app.bundleId;
    const remove=document.createElement('button');remove.type='button';remove.className='secondary danger';remove.textContent='Remove app';
    remove.onclick=()=>{
      if (!window.confirm(`Remove ${app.name} and its rules? Usage history is kept. Save changes to apply.`)) return;
      state.policy.apps=state.policy.apps.filter(a=>a!==app);
      for(const key of ['appRules','overrides','appSchedules','appQuotaStates']) {if(state.policy[key]) delete state.policy[key][app.bundleId];}
      if(state.policy.quota?.bundleId===app.bundleId) state.policy.quota.enabled=false;
      markEdited(`${app.name} removed. Save changes to apply.`);refreshAppList();
    };
    advanced.append(advancedTitle,identifier,remove);
    wrap.append(heading,usage,block,editor,advanced);container.append(wrap);appCards.set(app.bundleId,wrap);
  }
  if (!state.policy.apps.length) emptyChart(container,'No apps configured. Add an app below to set limits or block it.');
}
$('app-preset').addEventListener('change',()=>{
  const [name,bundle]=$('app-preset').value.split('|');
  if(bundle){$('name').value=name;$('bundle').value=bundle;}
});
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

watchEdits($('blocked-domains'), () => {
  state.policy.blockedDomains = [...new Set($('blocked-domains').value.split(/\r?\n/).map(s => s.trim().toLowerCase()).filter(Boolean))];
  markEdited(); renderDomains();
});

async function loadSecurityHealth() {
  const generation = ++healthGeneration;
  try {
    const result = await api('/api/admin/health');
    if (generation !== healthGeneration) return;
    const problems = [];
    if (!result.deviceConnected) problems.push('Mac agent not recently connected');
    if (!result.monitorConnected) problems.push('Foreground monitor not recently connected');
    if (!result.browserProtectionVerified) problems.push('Browser filtering not verified');
    $('attention').hidden = !problems.length;
    $('attention-text').textContent = problems.join(' · ');
    $('security-health').textContent =
      'Daemon: ' + (result.deviceConnected ? 'recently connected' : 'not recently connected') +
      ' · Foreground monitor: ' + (result.monitorConnected ? 'recently connected' : 'not recently connected') +
      ' · Browser filtering: ' + (result.browserProtectionVerified ? 'verified' : 'NOT VERIFIED');
  } catch (error) {
    if (generation !== healthGeneration) return;
    $('security-health').textContent = 'Protection status unavailable. ' + error.message;
    $('attention').hidden = false;
    $('attention-text').textContent = 'Protection status could not be refreshed.';
    throw error;
  }
}
$('security-refresh').onclick = action(loadSecurityHealth);

async function loadUsage() {
  const generation = ++usageGeneration;
  try {
    const data = await api('/api/admin/usage');
    if (generation !== usageGeneration) return;
    usageData = data; usageAvailable = true;
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
    updateAppSummaries();
  } catch (error) {
    if (generation !== usageGeneration) return;
    usageAvailable = false;
    $('usage-summary').textContent = 'Usage unavailable. Charts show the last successfully loaded totals. ' + error.message;
    renderUsageCharts(); updateAppSummaries();
    throw error;
  }
}
$('usage-refresh').onclick = action(refreshMonitoring);
$('usage-reset').onclick = action(async () => {
  if (dirty) throw Error('Save or discard your changes before resetting counters.');
  if (!window.confirm('Reset ALL app and website usage totals to zero, including today’s daily-limit usage? This clears daily and weekly totals for all connected Macs. Session history and blocking rules are kept.')) return;
  ++usageGeneration; // Ignore pre-reset reads still in flight.
  await api('/api/admin/usage/reset', {revision: state.policy.revision});
  await load();
  await refreshMonitoring();
  $('message').textContent = 'Usage counters reset. Daily limits will be reevaluated on the Mac’s next settings update.';
});

function updateSaveState() {
  const devices = connectionSnapshot;
  const received = devices.length && devices.every(device => device.report?.revision === state?.policy?.revision);
  $('save-state').textContent = dirty ? 'Unsaved changes' : received ? 'Macs received settings' : 'Saved · waiting for Mac';
  $('delivery-state').textContent = dirty ? 'Save to send changes to connected Macs.' : received ? 'Settings received. Offline Macs keep their last settings.' : 'Changes arrive at the next agent check.';
  $('save-bar').className = 'save-bar' + (dirty ? ' has-changes' : '');
  $('save').disabled = busy || !dirty;
  $('discard').disabled = busy || !dirty;
}
for (const event of ['change', 'click', 'submit']) {
  $('controls').addEventListener(event, updateSaveState);
}
for (const [index, name] of tabNames.entries()) {
  $('tab-' + name).onclick = action(async () => {
    showTab(name);
    if (name === 'monitoring' || name === 'websites') await refreshMonitoring();
    if (name === 'blocking') await refreshMonitoring();
    if (name === 'protection') await waitForRequests([loadSecurityHealth(), loadAlerts(), loadIPhones()]);
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
    svg.setAttribute('viewBox', '0 0 350 180'); svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', 'Daily foreground app time: ' + dates.map((day, i) => day + ': ' + duration(daily[i])).join('; '));
    const peak = Math.max(...daily, 1);
    const element = (tag, attributes, text) => {
      const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
      for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value));
      if (text !== undefined) node.textContent = text;
      return node;
    };
    dates.forEach((day, i) => {
      const height = daily[i] / peak * 115;
      const bar = element('rect', {x: i * 50 + 10, y: 145 - height, width: 30, height, rx: 5});
      bar.append(element('title', {}, day + ': ' + duration(daily[i]))); svg.append(bar);
      svg.append(element('text', {x: i * 50 + 25, y: 135 - height, 'text-anchor': 'middle', class: 'value'}, duration(daily[i])));
      svg.append(element('text', {x: i * 50 + 25, y: 173, 'text-anchor': 'middle'},
        new Date(day + 'T12:00:00Z').toLocaleDateString(undefined, {weekday: 'short', timeZone: 'UTC'})));
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
      row.append(label, meter);
      if (id === 'app-chart') {
        const note = document.createElement('small');
        const app = state?.policy?.apps.find(app => app.bundleId === item.id);
        note.textContent = (app?.blocked ? 'Blocked manually · ' : '') + allowanceLabel(item.id, days.length > 1);
        row.append(note);
      }
      root.append(row);
    }
  }
}
$('usage-period').addEventListener('change', renderUsageCharts);
window.setInterval(() => {
  if (!token || !state || $('controls').hidden || busy || backgroundBusy || document.hidden) return;
  backgroundBusy = true;
  void (async () => {
    try {
      await refreshConnections();
      await refreshMonitoring();
    } catch (error) { $('message').textContent = 'Activity refresh failed: ' + error.message; }
    finally { backgroundBusy = false; }
  })();
}, 15000);

function renderDomains() {
  const root=$('domain-list');root.replaceChildren();
  for (const domain of state.policy.blockedDomains || []) {
    const row=document.createElement('div');row.className='domain-row line';
    const name=document.createElement('strong');name.textContent=domain;
    const remove=document.createElement('button');remove.type='button';remove.className='secondary';remove.textContent='Remove';remove.setAttribute('aria-label','Remove '+domain);
    remove.onclick=()=>{state.policy.blockedDomains=state.policy.blockedDomains.filter(item=>item!==domain);$('blocked-domains').value=state.policy.blockedDomains.join('\n');markEdited();renderDomains();};
    row.append(name,remove);root.append(row);
  }
  if (!root.children.length) emptyChart(root,'No websites blocked.');
}
$('domain-add').onsubmit=event=>{
  event.preventDefault();
  const domain=$('domain-name').value.trim().toLowerCase().replace(/\.$/,'');
  if (domain.length > 253 || domain.split('.').length < 2 || !/[a-z]/.test(domain.split('.').at(-1)) || /^0x[0-9a-f]+$/.test(domain.split('.').at(-1)) || !domain.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) { $('message').textContent='Enter a domain such as example.com, without https:// or a path.';return; }
  const domains=state.policy.blockedDomains || [];
  if (domains.includes(domain)) {$('message').textContent='That website is already listed.';return;}
  if (domains.length>=100) {$('message').textContent='At most 100 websites can be configured.';return;}
  state.policy.blockedDomains=[...domains,domain];$('blocked-domains').value=state.policy.blockedDomains.join('\n');$('domain-name').value='';markEdited();renderDomains();
};
$('attention-details').onclick=()=>{$('tab-protection').onclick();};

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
