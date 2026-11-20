const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
class Element {
  constructor(tag = '') { this.tag = tag; this.children = []; this.value = ''; this.disabled = false; this.attributes = {}; }
  append(...children) { for(const child of children) { if(child instanceof Element) child.parent=this; } this.children.push(...children); }
  replaceChildren(...children) { for(const child of this.children) { if(child instanceof Element) child.parent=null; } this.children=[]; this.append(...children); }
  remove() { if(this.parent) { this.parent.children=this.parent.children.filter(child=>child!==this); this.parent=null; } }
  setAttribute(name, value) { this.attributes[name] = value; }
  focus() { focused = this; }
  addEventListener(type, listener) { this["on" + type] = listener; }
  reset() {}
  checkValidity() { return true; }
  closest(selector) { if(selector==='#panel-protection') return this.settingsPanel; for(let el=this;el;el=el.parent) { if(selector.startsWith('.') ? (el.className || '').split(' ').includes(selector.slice(1)) : el.tag===selector) return el; } return null; }
  reportValidity() { this.validityReported = true; }
}
let focused, refreshTimer;
const windowListeners = {};
const elements = new Map();
const html = fs.readFileSync('server/index.html','utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match=>match[1]);
assert.equal(ids.length,new Set(ids).size,'HTML IDs must be unique');
const tagById = new Map([...html.matchAll(/<([a-z]+)\b[^>]*\bid="([^"]+)"/g)].map(match=>[match[2],match[1]]));
const settingsHTML = html.slice(html.indexOf('id="panel-protection"'),html.indexOf('id="save-bar"'));
const settingsIds = new Set([...settingsHTML.matchAll(/\bid="([^"]+)"/g)].map(match=>match[1]));
const get = id => {
  assert.ok(ids.includes(id),`Missing HTML element: ${id}`);
  if (!elements.has(id)) {
    const element = new Element(tagById.get(id)); element.id=id;
    if (settingsIds.has(id)) element.settingsPanel=true;
    elements.set(id,element);
  }
  return elements.get(id);
};
const fresh = () => ({policy: {schemaVersion: 1, revision: 2, apps: [{name: 'Opera', bundleId: 'com.operasoftware.Opera', blocked: false}]}, device: null});
let fetchImpl;
const location = {hash: '', pathname: '/', search: ''};
let replacedURL;
const queryElements = selector => {
  const all=new Set(elements.values());
  for(const el of all) for(const child of el.children) if(child instanceof Element) all.add(child);
  if(selector==='button, input, select, textarea') return [...all].filter(el=>['button','input','select','textarea'].includes(el.tag));
  if(selector==='.rule-fields input, #panel-protection input, #quota-app') return [...all].filter(el=>(el.tag==='input' && (el.closest('.rule-fields') || el.settingsPanel)) || el===get('quota-app'));
  throw Error('Unsupported test selector: '+selector);
};
const context = vm.createContext({document: {getElementById: get, createElement: tag => new Element(tag), createElementNS: (_namespace,tag) => new Element(tag), querySelectorAll: queryElements}, window: {setInterval(callback) { refreshTimer = callback; }, setTimeout, clearTimeout, location, history: {replaceState(_state, _title, url) { replacedURL = url; location.hash = ''; }}, addEventListener(type, listener) { windowListeners[type] = listener; }, confirm() { return true; }}, URLSearchParams, AbortController, fetch: (...args) => fetchImpl(...args), console});
vm.runInContext(fs.readFileSync('server/app.js', 'utf8'), context);
const run = code => vm.runInContext(code, context);
const usage = () => ({apps: [
  {id: 'com.operasoftware.Opera', days: {'2026-11-17': 1800, '2026-11-16': 3600, '2026-11-01': 9999}, weeks: {}},
], websites: [{id: 'example.com', days: {'2026-11-17': 1200}, weeks: {}}], retentionDays: 90, timeZone: 'America/Los_Angeles', endDate: '2026-11-17'});
const responseFor = path => path === '/api/admin/ios/state' ? {policy:{schemaVersion:1, revision:1, blocked:false, dailyMinutes:null, timeZone:'America/Los_Angeles'}, devices:[], enrolled:[]} : path === '/api/admin/usage' ? usage() :
  path === '/api/admin/activity' ? {current: null, lastSeen: null, events: []} :
  path === '/api/admin/alerts' ? {alerts: []} :
  path === '/api/admin/health' ? {deviceConnected: true, monitorConnected: true, browserProtectionVerified: false} : fresh();

(async () => {
  fetchImpl = async path => ({ok: true, json: async () => responseFor(path)});
  get('token').value = 'test-token';
  await get('connect').onclick();
  const phonePolicy = {schemaVersion:1, revision:1, blocked:false, dailyMinutes:null, timeZone:'America/Los_Angeles'};
  const phoneID = '12345678-1234-1234-1234-123456789012';
  fetchImpl = async (path, options) => {
    if (path === '/api/admin/ios/pair') return {ok:true, json:async () => ({code:'ABCD-EFGH-JKLM', expiresAt:'2026-11-20T22:10:00Z'})};
    if (path === '/api/admin/ios/state') return {ok:true, json:async () => ({policy:phonePolicy, enrolled:[{installationID:phoneID}], devices:[]})};
    return {ok:true, json:async () => responseFor(path)};
  };
  await get('ios-pair').onclick();
  assert.equal(get('ios-code').textContent, 'ABCD-EFGH-JKLM');
  await get('ios-refresh').onclick();
  assert.equal(get('ios-devices').children.length, 1);
  assert.equal(get('ios-blocked').checked, false);
  run('dirty = true');
  get('ios-limited').checked = true; get('ios-minutes').value = '25';
  get('ios-minutes').oninput();
  await run('loadIPhones()');
  assert.equal(get('ios-minutes').value, '25', 'Status refresh preserves unsaved iPhone edits');
  fetchImpl = async (path, options) => {
    assert.equal(path, '/api/admin/ios/policy');
    const body = JSON.parse(options.body);
    assert.equal(body.dailyMinutes, 25);
    return {ok:true, json:async () => ({...body, revision:2})};
  };
  await get('ios-save').onclick();
  assert.equal(run('dirty'), true, 'Saving iPhone rules preserves unfinished Mac edits');
  fetchImpl = async () => ({ok:false, json:async () => ({error:'Failed to generate code'})});
  await get('ios-pair').onclick();
  assert.equal(get('ios-code').textContent, '', 'A failed replacement must not leave a superseded code visible');
  run('dirty = false');
  fetchImpl = async path => ({ok:true, json:async () => responseFor(path)});
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
  assert.equal(get('save').disabled, true, 'Save stays disabled when nothing changed');
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
  await get('tab-protection').onclick();
  assert.equal(get('alerts').children[0].textContent, 'No alerts recorded.');
  assert.equal(get('panel-monitoring').hidden, true);
  get('tab-protection').onkeydown({key: 'Home', preventDefault() {}});
  assert.equal(focused, get('tab-monitoring'));
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
  await cards[0].children[cards[0].children.length-1].children[2].onclick();
  assert.equal(connectionDeletes,1);
  assert.equal(get('connections-list').children.length,2);
  assert.equal(run('state.devices.length'),2);
  assert.equal(run('dirty'),true,'Connection deletion must preserve pending policy edits');
  assert.match(get('connections-note').textContent,/reappear/);
  fetchImpl = async () => ({ok:false,json:async()=>({error:'Delete failed'})});
  const remainingCard = get('connections-list').children[0];
  await remainingCard.children[remainingCard.children.length-1].children[2].onclick();
  assert.equal(get('connections-list').children.length,2,'Failed deletion must preserve the entries');
  assert.match(get('message').textContent,/Delete failed/);
  fetchImpl = async (path,options) => {
    assert.deepEqual(JSON.parse(options.body),{hostname:null});
    return {ok:true,json:async()=>({...connections,devices:[]})};
  };
  const unknownCard = get('connections-list').children[1];
  await unknownCard.children[unknownCard.children.length-1].children[2].onclick();
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
  const deleteButton = get('apps').children[0].children[4].children[2];
  assert.equal(deleteButton.textContent, 'Remove app');
  assert.equal(deleteButton.type, 'button');
  deleteButton.onclick();
  assert.equal(run('state.policy.apps.length'), 0);
  assert.match(get('apps').children[0].textContent, /No apps configured/);
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
  // Include usage for unconfigured apps; labels describe daily rules even in weekly view.
  run(`state = {policy:{revision:1,apps:[{name:'Roblox',bundleId:'roblox.app',blocked:false}],
    appRules:{'roblox.app':{minutes:60,schedule:{enabled:false,start:'21:00',end:'07:00'}}}}};
    usageData={endDate:'2026-11-20',timeZone:'UTC',apps:[
      {id:'roblox.app',days:{'2026-11-20':2520}},
      {id:'unconfigured.app',days:{'2026-11-20':1440}},
      {id:'third.app',days:{'2026-11-20':720}}
    ],websites:[]}; dirty=false; render();`);
  get('usage-period').value='today'; run('renderUsageCharts()');
  const rows=get('app-chart').children;
  assert.equal(rows.length,3,'Every used app is included, not just configured apps');
  assert.match(rows[0].children[2].textContent,/60 min\/day.*18 min remaining/);
  assert.equal(rows[1].children[2].textContent,'No daily limit');
  assert.equal(rows[0].children[1].max,2520,'Bars use a common usage scale, independent of limits');
  assert.equal(rows[1].children[1].value,1440);
  get('usage-period').value='week'; run('renderUsageCharts()');
  assert.equal(get('app-chart').children[0].children[2].textContent,'60 min/day');
  assert.equal(run('dailyLimit("unconfigured.app")'),null);
  run(`state.policy.quota={enabled:true,bundleId:'roblox.app',minutes:30}`);
  assert.equal(run('dailyLimit("roblox.app")'),30,'Existing additional allowance is respected');
  assert.equal(run('appStatus(state.policy.apps[0])'),'Daily limit reached');
  run(`state.policy.apps[0].blocked=true;state.policy.overrides={'roblox.app':'2099-01-01T00:00:00Z'}`);
  assert.equal(run('appStatus(state.policy.apps[0])'),'Blocked manually','Manual block precedes temporary allowance');
  run(`state.policy.apps[0].blocked=false`);
  assert.match(run('appStatus(state.policy.apps[0])'),/Temporary allowance/);
  run(`state.policy.overrides={};state.policy.quota.enabled=false;renderAppCards()`);
  const card=get('apps').children[0];
  const editor=card.children[3];
  const quota=editor.children[1].children[1];
  quota.value='90';quota.oninput();
  assert.equal(run('state.policy.appRules["roblox.app"].minutes'),90);
  assert.equal(run('dirty'),true);
  assert.equal(get('save').disabled,false);
  assert.match(card.children[0].children[1].children[1].textContent,/48 min remaining/);
  run(`state.policy.appRules={};state.policy.schedule={enabled:true,start:'21:00',end:'07:00'};renderAppCards()`);
  const inheritedQuota=get('apps').children[0].children[3].children[1].children[1];
  inheritedQuota.value='45';inheritedQuota.oninput();
  assert.equal(run('state.policy.appRules["roblox.app"].schedule.enabled'),true,'Adding a limit preserves shared restricted hours');
  get('domain-name').value='https://example.com/path';
  get('domain-add').onsubmit({preventDefault(){}});
  assert.match(get('message').textContent,/Enter a domain/);
  get('domain-name').value='EXAMPLE.COM';
  get('domain-add').onsubmit({preventDefault(){}});
  assert.equal(run('state.policy.blockedDomains[0]'),'example.com');
  assert.equal(get('domain-list').children[0].children[0].textContent,'example.com');
  get('domain-list').children[0].children[1].onclick();
  assert.equal(run('state.policy.blockedDomains.length'),0);
  assert.equal(get('attention').hidden,false,'Unverified filtering appears on overview');
  // Re-rendering cached state must not reinterpret an old server timestamp as "now".
  run(`state.serverTimeUTC='2020-01-01T00:00:00Z';connectionClockOffset=321;render()`);
  assert.equal(run('connectionClockOffset'),321,'Rendering cannot rewind the server clock');
  run('connectionClockOffset=0');

  // Unrelated settings changes must preserve an absent/disabled legacy quota selection.
  run(`state.policy.quota={enabled:false,bundleId:'old.app',minutes:75};render()`);
  get('quota-app').value='';get('enforcement-zone').value='Europe/London';
  get('enforcement-zone').onchange();
  assert.equal(run('state.policy.quota.bundleId'),'old.app');
  assert.equal(run('state.policy.quota.minutes'),75);
  get('schedule-enabled').checked=false;get('schedule-start').value='22:00';get('schedule-end').value='08:00';
  get('schedule-start').onchange();
  assert.equal(run('state.policy.quota.bundleId'),'old.app');

  // Apps refresh in place: preserve open editors and entered limits.
  run(`state.policy.appRules['roblox.app'].schedule.enabled=false;renderAppCards();activeTab='blocking'`);
  const liveCard=get('apps').children[0];
  liveCard.children[3].open=true;
  const liveQuota=liveCard.children[3].children[1].children[1];
  const liveUsage={endDate:'2026-11-20',timeZone:'Europe/London',retentionDays:90,
    apps:[{id:'roblox.app',days:{'2026-11-20':2640},weeks:{}}],websites:[]};
  fetchImpl=async path=>({ok:true,json:async()=>path==='/api/admin/usage'?liveUsage:responseFor(path)});
  await run('refreshMonitoring()');
  assert.equal(get('apps').children[0],liveCard,'Refresh must not replace app controls');
  assert.equal(liveCard.children[3].open,true);
  assert.equal(liveQuota.value,45);
  assert.match(liveCard.children[1].children[0].textContent,/44 min used today/);
  assert.equal(liveCard.children[1].children[1].value,2640);

  // One failed endpoint must not release the action lock while another is still pending.
  let finishUsage;
  fetchImpl=async path=>{
    if(path==='/api/admin/health') throw Error('Health unavailable');
    if(path==='/api/admin/usage') return new Promise(resolve=>{finishUsage=resolve;});
    return {ok:true,json:async()=>responseFor(path)};
  };
  const updating=get('usage-refresh').onclick();
  await Promise.resolve();await Promise.resolve();
  assert.equal(run('busy'),true);
  finishUsage({ok:true,json:async()=>liveUsage});
  await updating;
  assert.equal(run('busy'),false);
  assert.match(get('message').textContent,/Health unavailable/);
  assert.equal(get('today-total').textContent,'44 min');

  // An older connection read must not resurrect a record deleted while that read was pending.
  const device={hostname:'temporary.local',lastSeen:new Date().toISOString(),report:{revision:1,agentVersion:'test'}};
  run(`renderConnections(${JSON.stringify([device])})`);
  let finishConnections;
  fetchImpl=async path=>{
    if(path==='/api/admin/connections') return new Promise(resolve=>{finishConnections=resolve;});
    assert.equal(path,'/api/admin/connections/delete');
    return {ok:true,json:async()=>({devices:[],serverTimeUTC:new Date().toISOString()})};
  };
  const pendingConnections=run('refreshConnections()');
  const connectionCard=get('connections-list').children[0];
  await connectionCard.children[3].children[2].onclick();
  finishConnections({ok:true,json:async()=>({devices:[device],serverTimeUTC:new Date().toISOString()})});
  await pendingConnections;
  assert.equal(run('state.devices.length'),0);
  assert.equal(run('state.device'),null);
  assert.match(get('status').textContent,/Waiting for the Mac/);

  // Validate equal schedule endpoints locally and preserve the draft.
  run(`state.policy.schedule={enabled:true,start:'09:00',end:'09:00'};dirty=true`);
  fetchImpl=async()=>{throw Error('Invalid schedule must not be sent');};
  await get('save').onclick();
  assert.match(get('message').textContent,/different start and end times/);
  assert.equal(run('dirty'),true);
  const settingsMinutes=get('quota-minutes');
  settingsMinutes.checkValidity=()=>false;settingsMinutes.settingsPanel={};
  await get('save').onclick();
  assert.equal(run('activeTab'),'protection','Invalid settings open the correct tab');
  assert.equal(settingsMinutes.validityReported,true);
  settingsMinutes.checkValidity=()=>true;

  // Newer usage responses win when requests overlap (e.g. a reset or timezone save).
  let finishOldUsage, usageReads=0;
  fetchImpl=async()=>{
    usageReads++;
    if(usageReads===1)return new Promise(resolve=>{finishOldUsage=resolve;});
    return {ok:true,json:async()=>liveUsage};
  };
  const oldUsage=run('loadUsage()');
  await run('loadUsage()');
  finishOldUsage({ok:true,json:async()=>({...liveUsage,apps:[]})});
  await oldUsage;
  assert.equal(get('today-total').textContent,'44 min','Older usage responses cannot overwrite newer totals');
  run(`state.policy.quota={enabled:true,bundleId:'roblox.app',minutes:30};updateAppSummaries()`);
  assert.match(get('quota-status').textContent,/Limit reached/);
  run(`state.policy.quota.minutes=60;updateAppSummaries()`);
  assert.match(get('quota-status').textContent,/Below limit/,'Settings status re-evaluates a changed allowance immediately');
  // Typing must enable Save immediately; mobile browsers need not blur a disabled button.
  run(`dirty=false;render()`);
  get('quota-minutes').value='80';
  assert.equal(typeof get('quota-minutes').oninput,'function','Allowance edits must register before blur');
  get('quota-minutes').oninput();
  assert.equal(run('state.policy.quota.minutes'),80);
  assert.equal(get('save').disabled,false);
  run('dirty=false;updateSaveState()');
  get('blocked-domains').value='example.org';
  assert.equal(typeof get('blocked-domains').oninput,'function','Bulk website edits must register before blur');
  get('blocked-domains').oninput();
  assert.equal(run('state.policy.blockedDomains[0]'),'example.org');
  assert.equal(get('save').disabled,false);

  // A refresh must not overwrite a time being edited before its change event fires.
  run(`state.policy.appRules={};state.policy.schedule={enabled:true,start:'21:00',end:'07:00'};renderAppCards()`);
  const inheritedEditor=get('apps').children[0].children[3];
  const editingStart=inheritedEditor.children[3].children[0].children[1];
  editingStart.value='22:30';
  run('updateAppSummaries()');
  assert.equal(editingStart.value,'22:30','Polling cannot replace a time edit before blur');

  // Settings must hold the action lock until all parallel requests finish, even after an error.
  let finishAlerts;
  fetchImpl=async path=>{
    if(path==='/api/admin/health') throw Error('Health request failed');
    if(path==='/api/admin/alerts') return new Promise(resolve=>{finishAlerts=resolve;});
    throw Error('Unexpected request');
  };
  const settingsRefresh=get('tab-protection').onclick();
  for(let i=0;i<12;i++) await Promise.resolve();
  assert.equal(run('busy'),true,'Settings must wait for its pending alerts request');
  finishAlerts({ok:true,json:async()=>({alerts:[]})});
  await settingsRefresh;
  assert.equal(run('busy'),false);
  assert.match(get('security-health').textContent,/unavailable/i,'A failed health request cannot leave a previous healthy status');
  assert.equal(get('attention').hidden,false);

  // A failed activity request must not leave an old app displayed as current.
  get('current-app').textContent='Safari';
  fetchImpl=async()=>{throw Error('Offline');};
  await assert.rejects(run('loadActivity()'),/Offline/);
  assert.equal(get('current-app').textContent,'Unavailable');
  // Newer failures must win over older successes from overlapping refreshes.
  let finishOldActivity, activityReads=0;
  fetchImpl=async()=>{
    if(++activityReads===1) return new Promise(resolve=>{finishOldActivity=resolve;});
    throw Error('Activity unavailable');
  };
  const oldActivity=run('loadActivity()');
  await assert.rejects(run('loadActivity()'),/Activity unavailable/);
  finishOldActivity({ok:true,json:async()=>({events:[],lastSeen:new Date().toISOString(),current:{appName:'Old Safari',bundleId:'com.apple.Safari',since:new Date().toISOString()}})});
  await oldActivity;
  assert.equal(get('current-app').textContent,'Unavailable','Late activity cannot replace a newer failure');

  let finishOldHealth, healthReads=0;
  fetchImpl=async()=>{
    if(++healthReads===1) return new Promise(resolve=>{finishOldHealth=resolve;});
    throw Error('Health unavailable');
  };
  const oldHealth=run('loadSecurityHealth()');
  await assert.rejects(run('loadSecurityHealth()'),/Health unavailable/);
  finishOldHealth({ok:true,json:async()=>({deviceConnected:true,monitorConnected:true,browserProtectionVerified:true})});
  await oldHealth;
  assert.match(get('security-health').textContent,/unavailable/i);
  assert.equal(get('attention').hidden,false,'Late health results cannot dismiss the current warning');

  // Inherited hours still follow deliberate shared-hours changes.
  run(`state.policy.appRules={};state.policy.schedule={enabled:true,start:'21:00',end:'07:00'};renderAppCards()`);
  const sharedEditor=get('apps').children[0].children[3];
  const sharedStart=sharedEditor.children[3].children[0].children[1];
  get('schedule-start').value='20:30';get('schedule-end').value='06:30';get('schedule-enabled').checked=true;
  get('schedule-start').oninput();
  assert.equal(sharedStart.value,'20:30');
  sharedStart.value='22:15';sharedStart.oninput();
  assert.equal(run('state.policy.appRules["roblox.app"].schedule.start'),'22:15','Per-app time edits register immediately');
  run('updateAppSummaries()');
  assert.equal(sharedStart.value,'22:15');
  // Structural app-list edits must not silently turn an invalid numeric draft into no limit.
  run(`state.policy.schedule={enabled:false,start:'21:00',end:'07:00'};state.policy.appRules={'roblox.app':{minutes:60,schedule:{enabled:false,start:'21:00',end:'07:00'}}};render()`);
  const draftCard=get('apps').children[0];
  const draftMinutes=draftCard.children[3].children[1].children[1];
  draftCard.children[3].open=true;
  // Browsers expose partial numeric input as an empty value with badInput validity.
  draftMinutes.value='';draftMinutes.checkValidity=()=>false;draftMinutes.oninput();
  get('name').value='Second app';get('bundle').value='second.app';
  await get('add').onsubmit();
  assert.equal(get('apps').children[0],draftCard,'Adding an app preserves other draft controls');
  assert.equal(draftCard.children[3].open,true);
  let sentInvalid=false;
  fetchImpl=async()=>{sentInvalid=true;throw Error('Invalid draft must not be saved');};
  await get('save').onclick();
  assert.equal(sentInvalid,false,'Native invalid drafts remain available to Save validation');
  assert.equal(draftMinutes.validityReported,true);
  const secondCard=get('apps').children[1];
  secondCard.children[4].children[2].onclick();
  assert.equal(get('apps').children[0],draftCard,'Removing another app preserves drafts');
  draftMinutes.checkValidity=()=>true;
  // App-list edits must not rewrite an unfinished Settings number input either.
  let settingsWrites=0, rawMinutes='';
  Object.defineProperty(get('quota-minutes'),'value',{configurable:true,get(){return rawMinutes;},set(value){settingsWrites++;rawMinutes=value;}});
  get('name').value='Another app';get('bundle').value='another.app';
  await get('add').onsubmit();
  assert.equal(settingsWrites,0,'App-list updates cannot sanitize away an unfinished Settings entry');
  Object.defineProperty(get('quota-minutes'),'value',{configurable:true,writable:true,value:80});

  // A successful save may still await timezone usage: its replacement controls must stay locked.
  run(`state.policy.enforcementTimeZone='Europe/London';usageData.timeZone='UTC';dirty=true;updateSaveState()`);
  let finishPostSaveUsage;
  fetchImpl=async(path,options)=>{
    if(path==='/api/admin/policy') return {ok:true,json:async()=>({...JSON.parse(options.body),revision:99})};
    if(path==='/api/admin/usage') return new Promise(resolve=>{finishPostSaveUsage=resolve;});
    throw Error('Unexpected request');
  };
  const finishingSave=get('save').onclick();
  for(let i=0;i<20 && !finishPostSaveUsage;i++) await Promise.resolve();
  assert.equal(typeof finishPostSaveUsage,'function');
  assert.equal(run('busy'),true);
  assert.ok(queryElements('button, input, select, textarea').every(el=>el.disabled),'Newly rendered controls stay disabled while Save is finishing');
  finishPostSaveUsage({ok:true,json:async()=>liveUsage});
  await finishingSave;
  assert.equal(run('busy'),false);
  assert.equal(get('apps').children[0].children[2].children[1].disabled,false);
  // A rejected login must not start the authenticated polling loop.
  run(`var authenticatedTestState=state;state=undefined;token='invalid-token';backgroundBusy=false`);
  let unauthenticatedPolls=0;
  fetchImpl=async()=>{unauthenticatedPolls++;throw Error('Unauthorized');};
  refreshTimer();
  for(let i=0;i<12;i++)await Promise.resolve();
  assert.equal(unauthenticatedPolls,0,'No automatic requests before a successful login');
  run('state=authenticatedTestState');
  // Unknown usage must not be presented as a full remaining allowance.
  run(`state.policy.appRules['roblox.app'].minutes=60;var previousUsageData=usageData;usageData=undefined`);
  assert.equal(run('allowanceLabel("roblox.app")'),'60 min/day','No remaining-time claim before usage loads');
  run('usageData=previousUsageData');

  // Failed usage refreshes retain history but stop presenting stale totals as current allowance.
  fetchImpl=async()=>{throw Error('Usage offline');};
  await assert.rejects(run('loadUsage()'),/Usage offline/);
  assert.match(get('usage-summary').textContent,/unavailable/i);
  assert.doesNotMatch(run('allowanceLabel("roblox.app")'),/remaining/);
  assert.match(get('apps').children[0].children[1].children[0].textContent,/unavailable/i);

  // A request that never resolves must time out and release the action lock, preserving edits.
  const originalSetTimeout=run('window.setTimeout');
  const originalClearTimeout=run('window.clearTimeout');
  let expireRequest, clearedRequest=false, requestSignal;
  context.window.setTimeout=callback=>{expireRequest=callback;return 123;};
  context.window.clearTimeout=id=>{assert.equal(id,123);clearedRequest=true;};
  fetchImpl=(_path,options)=>{requestSignal=options.signal;return new Promise(()=>{});};
  run('dirty=true;updateSaveState()');
  const hangingSave=get('save').onclick();
  assert.equal(run('busy'),true);
  assert.equal(typeof expireRequest,'function');
  expireRequest();
  await hangingSave;
  assert.equal(run('busy'),false);
  assert.equal(run('dirty'),true);
  assert.equal(requestSignal.aborted,true);
  assert.equal(clearedRequest,true);
  assert.match(get('message').textContent,/timed out/i);
  // The same timeout also bounds a stalled JSON body after headers arrived.
  clearedRequest=false;
  fetchImpl=async()=>({ok:true,json:()=>new Promise(()=>{})});
  const hangingBody=run('api("/api/admin/usage")');
  expireRequest();
  await assert.rejects(hangingBody,/timed out/i);
  assert.equal(clearedRequest,true);
  context.window.setTimeout=originalSetTimeout;context.window.clearTimeout=originalClearTimeout;
  fetchImpl=async()=>({ok:true,json:async()=>({...liveUsage,timeZone:'Europe/London'})});
  await run('loadUsage()');
  assert.match(run('allowanceLabel("roblox.app")'),/16 min remaining/,'A successful retry restores current allowance labels');
  assert.equal(get('apps').children[0].children[1].children[1].hidden,false);
  // Failures from superseded reads must not turn a newer successful refresh into an error.
  for (const loader of ['loadUsage','loadActivity','loadSecurityHealth']) {
    let rejectOldRead, reads=0;
    fetchImpl=async path=>{
      if(++reads===1) return new Promise((_resolve,reject)=>{rejectOldRead=reject;});
      return {ok:true,json:async()=>path==='/api/admin/usage'?liveUsage:responseFor(path)};
    };
    const oldRead=run(loader+'()');
    await run(loader+'()');
    rejectOldRead(Error('Superseded request failed'));
    await oldRead;
  }
  run('dirty = false; iosDirty = true');
  let warnedAboutDrafts = false;
  const unload = {preventDefault() { warnedAboutDrafts = true; }};
  windowListeners.beforeunload(unload);
  assert.equal(warnedAboutDrafts, true, 'Leaving the website must warn about unsaved iPhone rules');
  assert.equal(unload.returnValue, '');
  run('iosDirty = false');
  console.log('Dashboard regression checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
