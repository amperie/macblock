const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
class Element {
  constructor() { this.children = []; this.value = ''; this.disabled = false; this.attributes = {}; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() { focused = this; }
  addEventListener(type, listener) { this["on" + type] = listener; }
  reset() {}
}
let focused, refreshTimer;
const elements = new Map();
const get = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
const fresh = () => ({policy: {schemaVersion: 1, revision: 2, apps: [{name: 'Opera', bundleId: 'com.operasoftware.Opera', blocked: false}]}, device: null});
let fetchImpl;
const location = {hash: '', pathname: '/', search: ''};
let replacedURL;
const context = vm.createContext({document: {getElementById: get, createElement: () => new Element(), createElementNS: () => new Element(), querySelectorAll: () => [...elements.values()]}, window: {setInterval(callback) { refreshTimer = callback; }, location, history: {replaceState(_state, _title, url) { replacedURL = url; location.hash = ''; }}, addEventListener() {}}, URLSearchParams, fetch: (...args) => fetchImpl(...args), console});
vm.runInContext(fs.readFileSync('server/app.js', 'utf8'), context);
const run = code => vm.runInContext(code, context);
const usage = () => ({apps: [
  {id: 'com.operasoftware.Opera', days: {'2026-11-17': 1800, '2026-11-16': 3600, '2026-11-01': 9999}, weeks: {}},
], websites: [{id: 'example.com', days: {'2026-11-17': 1200}, weeks: {}}], retentionDays: 90, timeZone: 'America/Los_Angeles', endDate: '2026-11-17'});
const responseFor = path => path === '/api/admin/usage' ? usage() :
  path === '/api/admin/activity' ? {current: null, lastSeen: null, events: []} :
  path === '/api/admin/alerts' ? {alerts: []} :
  path === '/api/admin/health' ? {deviceConnected: true, monitorConnected: true, browserProtectionVerified: false} : fresh();

(async () => {
  fetchImpl = async path => ({ok: true, json: async () => responseFor(path)});
  get('token').value = 'test-token';
  await get('connect').onclick();
  get('name').value = 'Safari';
  get('bundle').value = 'com.apple.Safari';
  await get('add').onsubmit();
  assert.equal(run('state.policy.apps.some(a => a.bundleId === "com.apple.Safari")'), true);
  for (const bundle of ['com.apple.finder', 'COM.APPLE.Finder', 'com.apple.Safari.helper', 'com.side-forge.orbit.agent']) {
    get('bundle').value = bundle;
    await get('add').onsubmit();
    assert.equal(run('state.policy.apps.length'), 2, 'Protected apps must remain rejected');
  }
  get('blocked-domains').value = 'instagram.com\ntiktok.com';
  get('blocked-domains').onchange();
  assert.equal(run('state.policy.blockedDomains[0]'), 'instagram.com');
  assert.equal(run('state.policy.blockedDomains[1]'), 'tiktok.com');
  run('dirty = true; state.policy.apps[0].blocked = true');
  fetchImpl = async () => ({ok: false, json: async () => ({error: 'Settings changed. Reload before saving.'})});
  await get('save').onclick();
  assert.equal(run('dirty'), true, 'Conflict must preserve edits');
  await get('discard').onclick();
  assert.equal(run('dirty'), true, 'Failed reload must preserve edits');
  fetchImpl = async path => ({ok: true, json: async () => responseFor(path)});
  await get('discard').onclick();
  assert.equal(run('dirty'), false);
  assert.equal(run('state.policy.apps[0].blocked'), false);
  let finish;
  fetchImpl = () => new Promise(resolve => { finish = resolve; });
  const saving = get('save').onclick();
  assert.equal(get('save').disabled, true);
  assert.equal(run('busy'), true);
  finish({ok: true, json: async () => fresh().policy});
  await saving;
  assert.equal(get('save').disabled, false);
  assert.equal(run('busy'), false);
  location.hash = '#token=link%2Btoken';
  fetchImpl = async (path, options) => {
    assert.equal(location.hash, '', 'Remove token from address before requests');
    assert.equal(options.headers.Authorization, 'Bearer link+token');
    return {ok: true, json: async () => responseFor(path)};
  };
  await run('connectFromLink()');
  assert.equal(replacedURL, '/');
  assert.equal(get('login').hidden, true);
  assert.equal(get('token').value, '');
  assert.equal(get('today-total').textContent, '30 min', 'Today uses server date, excluding previous dates');
  assert.equal(get('week-total').textContent, '1h 30m', 'Seven-day chart excludes older retained history');
  assert.equal(get('app-chart').children[0].children[1].value, 1800);
  assert.equal(get('daily-chart').children[0].attributes.role, 'img');
  assert.match(get('daily-chart').children[0].attributes['aria-label'], /2026-11-17: 30 min/);
  run('dirty = true');
  await get('tab-monitoring').onclick();
  assert.equal(run('dirty'), true, 'Changing tabs must preserve edits');
  assert.equal(get('panel-monitoring').hidden, false);
  assert.equal(get('panel-blocking').hidden, true);
  assert.equal(get('tab-monitoring').attributes['aria-selected'], 'true');
  get('usage-period').value = 'week';
  get('usage-period').onchange();
  assert.equal(get('app-chart').children[0].children[1].value, 5400);
  await get('tab-alerts').onclick();
  assert.equal(get('alerts').children[0].textContent, 'No alerts recorded.');
  assert.equal(get('panel-monitoring').hidden, true);
  get('tab-alerts').onkeydown({key: 'Home', preventDefault() {}});
  assert.equal(focused, get('tab-blocking'));
  run('usageData = {apps: [], websites: [], endDate: "2026-11-17", timeZone: "UTC"}; renderUsageCharts()');
  assert.match(get('daily-chart').children[0].textContent, /No app time recorded/);
  assert.equal(get('today-total').textContent, '0 min');
  run('dirty = false');
  const connections = {serverTimeUTC:new Date().toISOString(), devices:[
    {hostname:'daughter-mac.local',lastSeen:new Date().toISOString(),report:{agentVersion:'test',revision:2,lastError:''}},
    {hostname:'parent-mac.local',lastSeen:'2020-01-01T00:00:00Z',report:{agentVersion:'old',revision:1,lastError:'Sync failed'}},
    {hostname:null,lastSeen:'2020-01-01T00:00:00Z',report:{agentVersion:'legacy'}}
  ]};
  run('dirty = true; activeTab = "blocking"');
  fetchImpl = async path => {
    assert.equal(path, '/api/admin/connections');
    return {ok:true,json:async()=>connections};
  };
  await get('connections-refresh').onclick();
  assert.equal(run('dirty'),true, 'Connection refresh must preserve unsaved edits');
  const cards = get('connections-list').children;
  assert.equal(cards.length,3);
  assert.equal(cards[0].children[0].children[0].textContent,'daughter-mac.local');
  assert.equal(cards[0].children[0].children[1].textContent,'Recently connected');
  assert.equal(cards[1].children[0].children[1].textContent,'Offline / overdue');
  assert.equal(cards[1].children[1].children[1].dateTime,'2020-01-01T00:00:00Z');
  assert.equal(cards[2].children[0].children[0].textContent,'Unknown Mac (older agent)');
  assert.equal(cards[1].children[3].textContent,'Sync failed');
  let connectionDeletes = 0;
  fetchImpl = async (path,options) => {
    assert.equal(path,'/api/admin/connections/delete');
    assert.equal(options.method,'POST');
    connectionDeletes++;
    const payload = JSON.parse(options.body);
    assert.deepEqual(payload,{hostname:'daughter-mac.local'});
    return {ok:true,json:async()=>({...connections,devices:connections.devices.slice(1)})};
  };
  await cards[0].children[cards[0].children.length-1].onclick();
  assert.equal(connectionDeletes,1);
  assert.equal(get('connections-list').children.length,2);
  assert.equal(run('state.devices.length'),2);
  assert.equal(run('dirty'),true,'Connection deletion must preserve pending policy edits');
  assert.match(get('connections-note').textContent,/reappear/);
  fetchImpl = async () => ({ok:false,json:async()=>({error:'Delete failed'})});
  const remainingCard = get('connections-list').children[0];
  await remainingCard.children[remainingCard.children.length-1].onclick();
  assert.equal(get('connections-list').children.length,2,'Failed deletion must preserve the entries');
  assert.match(get('message').textContent,/Delete failed/);
  fetchImpl = async (path,options) => {
    assert.deepEqual(JSON.parse(options.body),{hostname:null});
    return {ok:true,json:async()=>({...connections,devices:[]})};
  };
  const unknownCard = get('connections-list').children[1];
  await unknownCard.children[unknownCard.children.length-1].onclick();
  assert.equal(run('state.devices.length'),0);
  run('render()');
  assert.equal(get('connections-list').children[0].textContent,'No Macs have connected yet.');
  run('renderConnections([])');
  assert.equal(get('connections-list').children[0].textContent,'No Macs have connected yet.');
  run('dirty = false');
  location.hash = '#token=expired';
  fetchImpl = async () => ({ok: false, json: async () => ({error: 'Unauthorized'})});
  await run('connectFromLink()');
  assert.equal(location.hash, '');
  assert.equal(get('token').value, '');
  assert.equal(get('message').textContent, 'Unauthorized');
  run(`state = {policy: {schemaVersion:1, revision:3,
    apps:[{name:'Signal',bundleId:'org.whispersystems.signal-desktop',blocked:true}],
    quota:{enabled:true,bundleId:'org.whispersystems.signal-desktop',minutes:60},
    appRules:{'org.whispersystems.signal-desktop':{minutes:30,schedule:{enabled:false,start:'21:00',end:'07:00'}}},
    overrides:{'org.whispersystems.signal-desktop':'2099-01-01T00:00:00Z'},
    appSchedules:{'org.whispersystems.signal-desktop':{}},
    appQuotaStates:{'org.whispersystems.signal-desktop':{}}}}; dirty = false; render()`);
  const deleteButton = get('apps').children[0].children[2];
  assert.equal(deleteButton.textContent, 'Delete');
  assert.equal(deleteButton.type, 'button');
  deleteButton.onclick();
  assert.equal(run('state.policy.apps.length'), 0);
  assert.equal(get('apps').children.length, 0);
  assert.equal(run('dirty'), true);
  assert.equal(run('state.policy.quota.enabled'), false);
  for (const field of ['appRules', 'overrides', 'appSchedules', 'appQuotaStates']) {
    assert.equal(run(`Object.keys(state.policy.${field}).length`), 0);
  }
  assert.match(get('message').textContent, /Save changes/);
  fetchImpl = async (path, options) => {
    assert.equal(path, '/api/admin/policy');
    const policy = JSON.parse(options.body);
    assert.deepEqual(policy.apps, []);
    assert.equal(policy.quota.enabled, false);
    return {ok:true,json:async()=>({...policy,revision:4})};
  };
  await get('save').onclick();
  assert.equal(run('dirty'), false);
  run('state = {policy: {schemaVersion:1, revision:8, apps:[]}}; dirty = true; window.confirm = () => { throw Error("Unexpected confirmation"); }');
  await get('usage-reset').onclick();
  assert.match(get('message').textContent, /Save or discard/);
  run('dirty = false; window.confirm = () => false');
  let resets = 0;
  fetchImpl = async (path, options) => {
    if (path === '/api/admin/usage/reset') {
      resets++;
      assert.equal(options.method, 'POST');
      assert.deepEqual(JSON.parse(options.body), {revision:8});
      return {ok:true,json:async()=>({ok:true,revision:9})};
    }
    if (path === '/api/admin/usage') return {ok:true,json:async()=>({...usage(),apps:[],websites:[]})};
    if (path === '/api/admin/state') return {ok:true,json:async()=>({policy:{schemaVersion:1,revision:9,apps:[]}})};
    return {ok:true,json:async()=>responseFor(path)};
  };
  await get('usage-reset').onclick();
  assert.equal(resets,0,'Cancelling must leave counters alone');
  run('window.confirm = () => true');
  await get('usage-reset').onclick();
  assert.equal(resets,1);
  assert.equal(run('state.policy.revision'),9);
  assert.equal(get('today-total').textContent,'0 min');
  assert.equal(get('week-total').textContent,'0 min');
  assert.match(get('message').textContent,/Usage counters reset/);
  console.log('Dashboard regression checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
