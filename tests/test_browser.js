const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const src = fs.readFileSync('browser/chrome/background.js','utf8');
const handlers = {};
let rules = [];
let savedRevision = 0;
let clientId = null;
let revision = 1;
let config = {serverURL:'https://example.test',browserToken:'b'.repeat(40)};
const api = {
  storage:{
    managed:{get:async()=>config},
    local:{get:async()=>({lastRevision:savedRevision,clientId}),set:async v=>{if ('lastRevision' in v) savedRevision=v.lastRevision; if ('clientId' in v) clientId=v.clientId;}}
  },
  idle:{queryState:async()=> 'active'},
  windows:{getLastFocused:async()=>({id:1,focused:true})},
  tabs:{query:async()=>[{url:'https://example.com/path?private=1'}]},
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
const context = {chrome:api,console,URL,Date,crypto:{randomUUID:()=> '11111111-1111-4111-8111-111111111111'},fetch:async(url,opts)=>{
  assert.equal(opts.headers.Authorization,'Bearer '+config.browserToken);
  if (url.href.endsWith('/api/browser/activity')) {
    assert.equal(opts.method,'POST');
    assert.equal(JSON.parse(opts.body).domain,'example.com');
    assert.equal(JSON.parse(opts.body).clientId,'11111111-1111-4111-8111-111111111111');
    return {ok:true};
  }
  assert.equal(url.href,'https://example.test/api/browser/domains');
  return {ok:true,json:async()=>({revision,blockedDomains:domains})};
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
  revision = 2; domains=['reddit.com'];
  await handlers.alarm({name:'policy'});
  assert.equal(rules[0].condition.urlFilter,'||reddit.com^');
  revision = 1; domains=['instagram.com'];
  await handlers.alarm({name:'policy'});
  assert.equal(rules[0].condition.urlFilter,'||reddit.com^');
  await handlers.alarm({name:'website'});
  console.log('WebExtension policy and website telemetry tests passed');
})().catch(e=>{console.error(e);process.exit(1)});
