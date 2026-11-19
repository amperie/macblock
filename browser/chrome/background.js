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
function serverOrigin(cfg) {
  const base = new URL(cfg.serverURL);
  if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash ||
      (base.pathname !== '/' && base.pathname !== '')) throw Error('Invalid server URL');
  return base;
}
function fetchBounded(url, options) {
  // A hung request must not permanently block the serialized policy queue.
  return fetch(url, {...options, signal: AbortSignal.timeout(15000)});
}
let pending = Promise.resolve();
function update() {
  const task = pending.then(applyPolicy);
  pending = task.catch(() => {});
  return task;
}
async function applyPolicy() {
  const cfg = await settings();
  if (!cfg) throw Error('Orbit managed configuration missing');
  const base = serverOrigin(cfg);
  const url = new URL('/api/browser/domains', base);
  const response = await fetchBounded(url, {headers:{Authorization:'Bearer ' + cfg.browserToken},redirect:'error',cache:'no-store'});
  if (!response.ok) throw Error('Policy fetch failed: ' + response.status);
  const policy = await response.json();
  if (!Number.isSafeInteger(policy.revision) || policy.revision < 1 ||
      !Array.isArray(policy.blockedDomains)) throw Error('Invalid domain policy');
  const saved = await api.storage.local.get(['lastRevision','policyServer']);
  if ((!saved.policyServer || saved.policyServer === base.origin) &&
      Number.isSafeInteger(saved.lastRevision) && policy.revision < saved.lastRevision)
    throw Error('Rejected older browser policy');
  const domains = [...new Set(policy.blockedDomains.map(normalize).filter(Boolean))].slice(0, 500);
  if (domains.length !== policy.blockedDomains.length) throw Error('Invalid domain policy');
  const existing = await api.declarativeNetRequest.getDynamicRules();
  const rules = domains.map((host,i)=>({
    id:i+1,priority:1,action:{type:'block'},
    condition:{urlFilter:'||'+host+'^',resourceTypes:['main_frame','sub_frame']}
  }));
  await api.declarativeNetRequest.updateDynamicRules({removeRuleIds:existing.map(r=>r.id),addRules:rules});
  await api.storage.local.set({lastRevision:policy.revision,policyServer:base.origin,lastSuccess:Date.now()});
}
async function reportWebsite() {
  const cfg = await settings();
  if (!cfg) return;
  const base = serverOrigin(cfg);
  let domain = null;
  const idle = await api.idle.queryState(60);
  if (idle === 'active') {
    const window = await api.windows.getLastFocused();
    if (window && window.focused) {
      const tabs = await api.tabs.query({active:true,windowId:window.id});
      const active = tabs[0];
      if (active && active.url) {
        try {
          const page = new URL(active.url);
          if (page.protocol === 'https:' || page.protocol === 'http:')
            domain = normalize(page.hostname);
        } catch (_) { /* Ignore browser-internal and malformed URLs. */ }
      }
    }
  }
  const saved = await api.storage.local.get('clientId');
  const clientId = saved.clientId || crypto.randomUUID();
  if (!saved.clientId) await api.storage.local.set({clientId});
  const response = await fetchBounded(new URL('/api/browser/activity', base), {
    method:'POST', headers:{Authorization:'Bearer '+cfg.browserToken,'Content-Type':'application/json'},
    body:JSON.stringify({domain,clientId}), redirect:'error',cache:'no-store'
  });
  if (!response.ok) throw Error('Website activity upload failed: '+response.status);
}
api.runtime.onInstalled.addListener(()=>update().catch(console.error));
api.runtime.onStartup.addListener(()=>{update().catch(console.error);});
api.alarms.onAlarm.addListener(a=>a.name==='policy' ? update().catch(console.error) : a.name==='website' ? reportWebsite().catch(console.error) : Promise.resolve());
api.alarms.create('policy',{periodInMinutes:1});
api.alarms.create('website',{periodInMinutes:1});
update().catch(console.error);
