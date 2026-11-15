const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const src = fs.readFileSync('browser/chrome/background.js','utf8');
const handlers = {};
let rules = [];
let config = {serverURL:'https://example.test',browserToken:'b'.repeat(40)};
const api = {
  storage:{
    managed:{get:async()=>config},
    local:{set:async()=>{}}
  },
  declarativeNetRequest:{
    getDynamicRules:async()=>rules,
    updateDynamicRules:async({removeRuleIds,addRules})=>{
      rules=rules.filter(r=>!removeRuleIds.includes(r.id)).concat(addRules);
    }
  },
  runtime:{onInstalled:{addListener:f=>handlers.install=f},onStartup:{addListener:f=>handlers.start=f}},
  alarms:{create:()=>{},onAlarm:{addListener:f=>handlers.alarm=f}}
};
let domains=['instagram.com','tiktok.com'];
const context = {chrome:api,console,URL,Date,fetch:async(url,opts)=>{
  assert.equal(url.href,'https://example.test/api/browser/domains');
  assert.equal(opts.headers.Authorization,'Bearer '+config.browserToken);
  return {ok:true,json:async()=>({revision:1,blockedDomains:domains})};
}};
vm.runInNewContext(src,context);
(async()=>{
  await handlers.alarm({name:'policy'});
  assert.equal(rules.length,2);
  assert.equal(rules[0].condition.urlFilter,'||instagram.com^');
  domains=['youtube.com'];
  await handlers.alarm({name:'policy'});
  assert.equal(rules.length,1);
  assert.equal(rules[0].condition.urlFilter,'||youtube.com^');
  domains=['https://evil.com'];
  await handlers.alarm({name:'policy'}).catch(()=>{});
  assert.equal(rules[0].condition.urlFilter,'||youtube.com^');
  console.log('WebExtension policy tests passed');
})().catch(e=>{console.error(e);process.exit(1)});
