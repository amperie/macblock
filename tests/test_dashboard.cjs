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
  location.hash = '#token=expired';
  fetchImpl = async () => ({ok: false, json: async () => ({error: 'Unauthorized'})});
  await run('connectFromLink()');
  assert.equal(location.hash, '');
  assert.equal(get('token').value, '');
  assert.equal(get('message').textContent, 'Unauthorized');
  console.log('Dashboard regression checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
