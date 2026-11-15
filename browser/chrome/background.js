// This extension intentionally has no network or privileged device credential.
// Site rules are set locally via Chrome managed extension storage (enterprise policy)
// or through the extension's own storage for development/testing.
const normalize = value => {
  if (typeof value !== 'string') return null;
  const host = value.trim().toLowerCase().replace(/^\.+|\.+$/g, '');
  return /^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/.test(host) && host.length <= 253 ? host : null;
};
async function update() {
  const {blockedDomains = []} = await chrome.storage.local.get('blockedDomains');
  const domains = [...new Set((Array.isArray(blockedDomains) ? blockedDomains : []).map(normalize).filter(Boolean))].slice(0, 500);
  const existing = await chrome.declarativeNetRequest.getDynamicRules();
  const rules = domains.map((host, i) => ({
    id: i + 1,
    priority: 1,
    action: {type: 'block'},
    condition: {urlFilter: '||' + host + '^', resourceTypes: ['main_frame', 'sub_frame']}
  }));
  await chrome.declarativeNetRequest.updateDynamicRules({
    removeRuleIds: existing.map(r => r.id), addRules: rules
  });
}
chrome.runtime.onInstalled.addListener(() => { update().catch(console.error); });
chrome.runtime.onStartup.addListener(() => { update().catch(console.error); });
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.blockedDomains) update().catch(console.error);
});
