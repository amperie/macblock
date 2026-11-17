const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
class Element {
  constructor() { this.children = []; this.value = ''; this.disabled = false; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute() {}
  addEventListener(type, listener) { this["on" + type] = listener; }
  reset() {}
}
const elements = new Map();
const get = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
const fresh = () => ({policy: {schemaVersion: 1, revision: 2, apps: [{name: 'Opera', bundleId: 'com.operasoftware.Opera', blocked: false}]}, device: null});
let fetchImpl;
const context = vm.createContext({document: {getElementById: get, createElement: () => new Element(), querySelectorAll: () => [...elements.values()]}, window: {addEventListener() {}}, fetch: (...args) => fetchImpl(...args), console});
vm.runInContext(fs.readFileSync('server/app.js', 'utf8'), context);
const run = code => vm.runInContext(code, context);
(async () => {
  fetchImpl = async path => ({ok: true, json: async () => path === '/api/admin/usage' ? {apps: [], websites: [], retentionDays: 90, timeZone: 'UTC'} : fresh()});
  get('token').value = 'test-token';
  await get('connect').onclick();
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
  fetchImpl = async path => ({ok: true, json: async () => path === '/api/admin/usage' ? {apps: [], websites: [], retentionDays: 90, timeZone: 'UTC'} : fresh()});
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
  console.log('Dashboard regression checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
