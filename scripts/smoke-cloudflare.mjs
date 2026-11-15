// Public HTTP smoke checks; never uses credentials or creates an identity.
import assert from 'node:assert/strict';
const base=process.argv[2];
if(!base||!/^https:\/\//.test(base))throw Error('Pass an https origin');
for(const path of ['/','/chat/','/chat/identity','/chat/identity/pin','/chat/identity/new','/chat/chats/did%3Acht%3A'+'a'.repeat(64),'/chat/wasm/cht_core_bg.wasm','/relay']){
  const response=await fetch(base+path,{signal:AbortSignal.timeout(15000)});
  assert.equal(response.status,200,path);
  const type=response.headers.get('content-type');
  if(path.endsWith('.wasm'))assert.match(type,/application\/wasm/);
  else if(path==='/relay')assert.equal((await response.json()).contentRelay,false);
  else assert.match(type,/text\/html/);
  console.log(JSON.stringify({path,status:response.status,type,cache:response.headers.get('cache-control')}));
}
assert.equal((await fetch(base+'/chat',{redirect:'manual'})).status,308);
assert.equal((await fetch(base+'/relay',{method:'POST',body:'synthetic content must be rejected'})).status,405);
assert.equal((await fetch(base+'/missing')).status,404);
assert.equal((await fetch(base+'/chat/missing.wasm')).status,404);
console.log('PASS: mounted pages, WASM, discovery-only seed and missing assets');
