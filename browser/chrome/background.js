// Shared Chromium/Safari WebExtension policy engine.
// Configuration must be provisioned by a parent or device administrator.
// Never store the parent or privileged daemon credential in a browser extension.
const api = globalThis.browser || globalThis.chrome;
const normalize = value => {
  if (typeof value !== 'string') return null;
  const host = value.trim().toLowerCase();
  if (host.length > 253 || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/.test(host)) return null;
  return host;
};
async function settings() {
  const managed = await api.storage.managed.get(['serverURL', 'browserToken']).catch(() => ({}));
  return managed.serverURL && managed.browserToken ? managed : null;
}
let pending = Promise.resolve();
function update() {
  const task = pending.then(applyPolicy);
  pending = task.catch(() => {});
  return task;
}
async function applyPolicy() {
  const cfg = await settings();
  if (!cfg) throw Error('MacBlock managed configuration missing');
  const base = new URL(cfg.serverURL);
  if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) throw Error('Invalid server URL');
  const url = new URL('/api/browser/domains', base);
  const response = await fetch(url, {headers:{Authorization:'Bearer ' + cfg.browserToken},redirect:'error',cache:'no-store'});
  if (!response.ok) throw Error('Policy fetch failed: ' + response.status);
  const policy = await response.json();
  if (!Array.isArray(policy.blockedDomains)) throw Error('Invalid domain policy');
  const domains = [...new Set(policy.blockedDomains.map(normalize).filter(Boolean))].slice(0, 500);
  if (domains.length !== policy.blockedDomains.length) throw Error('Invalid domain policy');
  const existing = await api.declarativeNetRequest.getDynamicRules();
  const rules = domains.map((host,i)=>({
    id:i+1,priority:1,action:{type:'block'},
    condition:{urlFilter:'||'+host+'^',resourceTypes:['main_frame','sub_frame']}
  }));
  await api.declarativeNetRequest.updateDynamicRules({removeRuleIds:existing.map(r=>r.id),addRules:rules});
  await api.storage.local.set({lastRevision:policy.revision,lastSuccess:Date.now()});
}
api.runtime.onInstalled.addListener(()=>update().catch(console.error));
api.runtime.onStartup.addListener(()=>{update().catch(console.error);});
api.alarms.onAlarm.addListener(a=>a.name==='policy' ? update().catch(console.error) : Promise.resolve());
api.alarms.create('policy',{periodInMinutes:1});
update().catch(console.error);
