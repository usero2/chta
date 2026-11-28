// Actual disposable Wrangler/workerd server and real local WebSockets; no account or contacts.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { identity, proof, signal, contactSignal, dispatch } from './helpers.js';

function queue(ws) {
  const messages=[],pending=[];
  ws.addEventListener('message',e=>{const v=JSON.parse(e.data);if(pending.length)pending.shift()(v);else messages.push(v);});
  return ()=>messages.length?Promise.resolve(messages.shift()):Promise.race([new Promise(r=>pending.push(r)),delay(5000).then(()=>{throw Error('WebSocket frame timeout');})]);
}
async function client(url,key){
  const ws=new WebSocket(url),next=queue(ws),challenge=await next();
  assert.equal(challenge.type,'challenge');
  ws.send(JSON.stringify({type:'register',proof:proof(key,challenge.nonce,challenge.seedId)}));
  assert.equal((await next()).type,'registered');assert.equal((await next()).type,'catalog');return{ws,next,challenge};
}
test('actual workerd authenticates, routes signed SDP, rejects replay/content/binary/oversize, serves mounted routes',{timeout:60000},async t=>{
  const folder=await mkdtemp(join(tmpdir(),'chta-seed-runtime-')),assets=join(folder,'assets');
  await mkdir(join(assets,'chat'),{recursive:true});
  await writeFile(join(assets,'index.html'),'<html>landing</html>');
  await writeFile(join(assets,'chat/index.html'),'<html><base href="/chat/">mounted</html>');
  const listener=createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
  const fixture=JSON.parse(await readFile(new URL('./fixtures/seed-signal.json',import.meta.url),'utf8'));
  const contactFixture=JSON.parse(await readFile(new URL('./fixtures/contact-request.json',import.meta.url),'utf8'));
  const productionWorker=resolve('src/worker.js').replaceAll('\\','/'),protocol=resolve('src/protocol.js').replaceAll('\\','/');
  // Test-only wrapper checks the Rust fixture at its deterministic time, under workerd's Ed25519.
  // No test endpoint or time override exists in production sources.
  await writeFile(join(folder,'fixture-worker.mjs'),`import worker,{SeedDirectory} from ${JSON.stringify(productionWorker)};export {SeedDirectory};import {verifySignal} from ${JSON.stringify(protocol)};const f=${JSON.stringify(fixture)},c=${JSON.stringify(contactFixture)};
    export class QuotaDirectory extends SeedDirectory {constructor(ctx,env){super(new Proxy(ctx,{get(t,k){if(k==='storage')return {async get(){throw Error('quota');},async put(){throw Error('quota');},async setAlarm(){throw Error('quota');}};const v=Reflect.get(t,k,t);return typeof v==='function'?v.bind(t):v;}}),env);}}
    export default {async fetch(r,e){if(new URL(r.url).pathname==='/__fixture')return Response.json(await verifySignal(f.envelope,f.envelope.from,f.now));if(new URL(r.url).pathname==='/__contact_fixture')return Response.json(await verifySignal(c.envelope,c.envelope.from,c.now));if(new URL(r.url).pathname==='/__quota'){const url=new URL(r.url);url.pathname='/relay';return worker.fetch(new Request(url,r),{...e,SEED_DIRECTORY:e.SEED_QUOTA});}return worker.fetch(r,e);}};`);
  const config={name:'chta-seed-test',main:join(folder,'fixture-worker.mjs'),compatibility_date:'2026-11-01',assets:{directory:assets,binding:'ASSETS',run_worker_first:true,html_handling:'none',not_found_handling:'none'},durable_objects:{bindings:[{name:'SEED_DIRECTORY',class_name:'SeedDirectory'},{name:'SEED_QUOTA',class_name:'QuotaDirectory'}]},migrations:[{tag:'v1',new_sqlite_classes:['SeedDirectory','QuotaDirectory']}],vars:{SEED_MAX_SOCKETS:'24'}};
  await writeFile(join(folder,'wrangler.json'),JSON.stringify(config));
  const child=spawn(process.execPath,[resolve('node_modules/wrangler/bin/wrangler.js'),'dev','--local','--config',join(folder,'wrangler.json'),'--ip','127.0.0.1','--port',String(port),'--persist-to',join(folder,'state')],{cwd:resolve('.'),windowsHide:true,stdio:['ignore','pipe','pipe'],env:{...process.env,WRANGLER_SEND_METRICS:'false',CI:'true'}});
  let output='';child.stdout.on('data',v=>{output+=v;});child.stderr.on('data',v=>{output+=v;});
  t.after(async()=>{child.kill();await Promise.race([new Promise(r=>child.once('exit',r)),delay(5000)]);await rm(folder,{recursive:true,force:true,maxRetries:5,retryDelay:200});});
  const base=`http://127.0.0.1:${port}`,url=`ws://127.0.0.1:${port}/relay`;
  let ready=false;
  for(let i=0;i<120;i++){try{const r=await fetch(base+'/relay',{signal:AbortSignal.timeout(500)});if(r.ok){ready=true;break;}}catch{}if(child.exitCode!==null)break;await delay(150);}
  assert.ok(ready,output);
  assert.deepEqual(await(await fetch(base+'/__fixture')).json(),fixture.envelope);
  assert.deepEqual(await(await fetch(base+'/__contact_fixture')).json(),contactFixture.envelope);
  assert.match(await(await fetch(base+'/')).text(),/landing/);
  const deep=await fetch(base+'/chat/chats/did:cht:abc');assert.equal(deep.status,200);assert.match(await deep.text(),/mounted/);assert.equal(deep.headers.get('cache-control'),'no-store');
  for(const path of ['/missing','/relay/upload','/chat/missing.wasm'])assert.equal((await fetch(base+path)).status,404,path);
  assert.equal((await fetch(base+'/relay',{method:'POST',body:'secret'})).status,405);
  const qa=identity(),qb=identity(),qca=await client(`ws://127.0.0.1:${port}/__quota`,qa),qcb=await client(`ws://127.0.0.1:${port}/__quota`,qb);
  assert.ok(qca.challenge.capabilities.includes('session-dispatch-v1'));
  const qe=signal(qa,'did:cht:'+qb.id,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  const qf={type:'signal',envelope:qe,dispatch:dispatch(qa,qe,qca.challenge.nonce)};
  qca.ws.send(JSON.stringify(qf));assert.deepEqual(await qcb.next(),{type:'signal',envelope:qe});
  const qclosed=new Promise(r=>qca.ws.addEventListener('close',r,{once:true}));
  qca.ws.send(JSON.stringify(qf));assert.equal((await qclosed).code,1008);qcb.ws.close();
  const pending=new WebSocket(url),pendingNext=queue(pending);await pendingNext();
  const pendingClosed=new Promise(r=>pending.addEventListener('close',r,{once:true}));pending.send('{"type":"keepalive"}');
  assert.equal((await Promise.race([pendingClosed,delay(2500).then(()=>({code:0}))])).code,1008,'pre-registration keepalive cannot bypass authentication');
  const bad=new WebSocket(url),badNext=queue(bad),badChallenge=await badNext(),badKey=identity();
  const badClosed=new Promise(r=>bad.addEventListener('close',r,{once:true}));bad.send(JSON.stringify({type:'register',proof:proof(badKey,Buffer.alloc(32,9).toString('base64url'),badChallenge.seedId)}));assert.equal((await badClosed).code,1008,'proof for another nonce cannot authenticate');
  const a=identity(),b=identity(),ca=await client(url,a),cb=await client(url,b);
  const request=contactSignal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+120000});
  ca.ws.send(JSON.stringify({type:'signal',envelope:request}));
  assert.deepEqual(await cb.next(),{type:'signal',envelope:request},'an unknown sender may deliver only a sealed contact-setup packet');
  ca.ws.send(JSON.stringify({type:'lookup',identityId:`did:cht:${b.id}`}));assert.equal((await ca.next()).online,true);
  ca.ws.send('{"type":"keepalive"}');assert.equal((await ca.next()).type,'alive');
  const burst=[2,3].map(index=>signal(a,`did:cht:${b.id}`,{id:`cht-control-direct-v1-0123456789abcdef0123456789abcdef-offer-${index}`,issuedAt:Date.now(),expiresAt:Date.now()+60000}));
  for(const envelope of burst)ca.ws.send(JSON.stringify({type:'signal',envelope}));
  assert.equal((await cb.next()).envelope.id,burst[0].id);
  assert.equal((await cb.next()).envelope.id,burst[1].id);
  const turnSession='0123456789abcdef0123456789abcdef';
  const turn=signal(a,`did:cht:${b.id}`,{
    id:`cht-control-direct-v1-${turnSession}-ice-4`,kind:'ice',
    payload:JSON.stringify({v:1,t:'ice',s:turnSession,c:'candidate:a 1 udp 1 93.184.216.34 49160 typ relay',m:null,l:0}),
    issuedAt:Date.now(),expiresAt:Date.now()+60000,
  });
  ca.ws.send(JSON.stringify({type:'signal',envelope:turn}));
  assert.deepEqual(await cb.next(),{type:'signal',envelope:turn});
  const v=signal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  ca.ws.send(JSON.stringify({type:'signal',envelope:v}));assert.deepEqual(await cb.next(),{type:'signal',envelope:v});
  const closed=new Promise(r=>ca.ws.addEventListener('close',r,{once:true}));ca.ws.send(JSON.stringify({type:'signal',envelope:v}));assert.equal((await closed).code,1008);
  cb.ws.close();
  const future=await client(url,identity());
  const futureKey=identity(),futureAuth=await client(url,futureKey),futureClosed=new Promise(r=>futureAuth.ws.addEventListener('close',r,{once:true}));
  futureAuth.ws.send(JSON.stringify({type:'signal',envelope:signal(futureKey,`did:cht:${b.id}`,{issuedAt:Date.now()+60000,expiresAt:Date.now()+120000})}));assert.equal((await futureClosed).code,1008);future.ws.close();
  for(const frame of [JSON.stringify({type:'message',body:'synthetic secret'}),new Uint8Array([1,2,3]),'x'.repeat(16385)]){
    const c=await client(url,identity()),done=new Promise(r=>c.ws.addEventListener('close',r,{once:true}));c.ws.send(frame);assert.equal((await done).code,1008);
  }
});
