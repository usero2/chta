import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/worker.js';
const assets=new Map([['/index.html','<html>landing</html>'],['/chat/index.html','<html><base href="/chat/">flutter</html>'],['/chat/main.dart.js','js'],['/portal.12345678.css','css']]);
const env={ASSETS:{async fetch(r){const path=new URL(r.url).pathname;return new Response(assets.get(path)||'missing',{status:assets.has(path)?200:404,headers:{'content-type':path.endsWith('.js')?'text/javascript':path.endsWith('.css')?'text/css':'text/html'}});}}};
const request=(path,method='GET')=>worker.fetch(new Request('https://chta.app'+path,{method}),env);
test('homepage, /chat slash redirect, mounted refresh and missing assets preserve boundaries',async()=>{
  assert.match(await (await request('/')).text(),/landing/);
  assert.equal((await request('/chat')).headers.get('location'),'https://chta.app/chat/');
  for(const p of ['/chat/','/chat/chats/did:cht:abc','/chat/profile','/chat/identity','/chat/identity/pin','/chat/identity/new']){const r=await request(p);assert.equal(r.status,200);assert.match(await r.text(),/flutter/);assert.equal(r.headers.get('cache-control'),'no-store');}
  for(const p of ['/unknown','/api/x','/relay/upload','/chat/missing.js','/chat/assets/missing','/chat/api/x'])assert.equal((await request(p)).status,404,p);
  assert.equal((await request('/chat/main.dart.js')).headers.get('cache-control'),'public, max-age=0, must-revalidate');
  assert.match((await request('/portal.12345678.css')).headers.get('cache-control'),/immutable/);
});
test('relay HTTP is health only, all mutation/uploads reject without HTML fallback',async()=>{
  const r=await request('/relay');assert.equal(r.status,200);assert.equal((await r.json()).mode,'discovery-only');assert.equal(r.headers.get('cache-control'),'no-store');
  for(const p of ['/relay','/chat/','/'])assert.equal((await request(p,'POST')).status,405);
});
