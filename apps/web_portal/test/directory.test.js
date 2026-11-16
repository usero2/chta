import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SeedDirectory } from '../src/seed-directory.js';
import { SEED_ID } from '../src/protocol.js';
import { identity, proof, signal, contactSignal, record, now } from './helpers.js';
function context() {
  const data = new Map(), sockets = [];
  return { data, sockets, storage: { async get(k) {return structuredClone(data.get(k));}, async put(k,v) {data.set(k,structuredClone(v));},async setAlarm() {} }, blockConcurrencyWhile: fn => fn(), getWebSockets: () => sockets, setWebSocketAutoResponse() {} };
}
function socket(ctx, dir, key, opts={}) {
  const ws = { readyState:1, sent:[], attachment:null, send(s){this.sent.push(JSON.parse(s));}, close(code){this.readyState=3;this.code=code;},serializeAttachment(v){this.attachment=structuredClone(v);},deserializeAttachment(){return structuredClone(this.attachment);} };
  const nonce = Buffer.alloc(32,5).toString('base64url');
  ws.serializeAttachment({nonce,deadline:Date.now()+30000,ip:'hash-'+key.id,...opts});
  ctx.sockets.push(ws); dir.sessions.set(ws,ws.deserializeAttachment());
  return ws;
}
async function registered(ctx,dir,key,opts={}) {
  const ws=socket(ctx,dir,key,opts);
  await dir.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(key,ws.attachment.nonce,SEED_ID)}));
  assert.equal(ws.sent[0]?.type,'registered'); return ws;
}

test('contact requests forward live only; offline retries never create a seed mailbox', async () => {
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
  const a=identity(),b=identity(),wa=await registered(ctx,dir,a);
  const envelope=contactSignal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  await dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope}));
  assert.equal(wa.readyState,1);
  assert.deepEqual(wa.sent.at(-1),{type:'unreachable',identityId:`did:cht:${b.id}`});
  assert.ok(!JSON.stringify([...ctx.data]).includes(envelope.payload));
  assert.ok(!JSON.stringify([...ctx.data]).includes(envelope.session));
  const woke=new SeedDirectory(ctx,{});await woke.ready;
  const wb=await registered(ctx,woke,b);
  assert.equal(wb.sent.filter(p=>p.type==='signal').length,0);
  const retry=contactSignal(a,`did:cht:${b.id}`,{id:envelope.id.slice(0,-32)+'b'.repeat(32),issuedAt:Date.now(),expiresAt:Date.now()+60000});
  await woke.webSocketMessage(wa,JSON.stringify({type:'signal',envelope:retry}));
  assert.deepEqual(wb.sent.at(-1),{type:'signal',envelope:retry});
  assert.ok(!JSON.stringify([...ctx.data]).includes(retry.payload));
  assert.ok(!JSON.stringify([...ctx.data]).includes(retry.session));
});
test('only authenticated lookup and signed signals route; duplicate replay survives reconstruction', async () => {
  const ctx=context(), dir=new SeedDirectory(ctx,{}); await dir.ready;
  const a=identity(),b=identity(),wa=await registered(ctx,dir,a),wb=await registered(ctx,dir,b);
  await dir.webSocketMessage(wa,JSON.stringify({type:'lookup',identityId:`did:cht:${b.id}`}));
  assert.deepEqual(wa.sent.at(-1),{type:'presence',identityId:`did:cht:${b.id}`,online:true});
  const v=signal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+110000});
  await dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope:v}));
  assert.deepEqual(wb.sent.at(-1),{type:'signal',envelope:v});
  const woke=new SeedDirectory(ctx,{});await woke.ready;
  await woke.webSocketMessage(wa,JSON.stringify({type:'signal',envelope:v}));
  assert.equal(wa.code,1008);assert.equal(wb.sent.filter(x=>x.type==='signal').length,1);
});
test('unregistered, expired challenge, repeated registration, binary and content frames close', async () => {
  for(const payload of [{type:'lookup',identityId:`did:cht:${identity().id}`},{type:'message',body:'secret'},{type:'upload',filename:'secret'},{type:'route',payload:'encrypted'},new Uint8Array([1,2]),'x'.repeat(16385)]) {
    const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const ws=socket(ctx,dir,identity());
    await dir.webSocketMessage(ws,typeof payload==='object' && !(payload instanceof Uint8Array)?JSON.stringify(payload):payload);
    assert.equal(ws.code,1008);
  }
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const key=identity();
  const expired=socket(ctx,dir,key,{deadline:Date.now()-1});
  await dir.webSocketMessage(expired,JSON.stringify({type:'register',proof:proof(key,expired.attachment.nonce,SEED_ID)}));assert.equal(expired.code,1008);
  const ws=await registered(ctx,dir,key);
  await dir.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(key,Buffer.alloc(32,5).toString('base64url'),SEED_ID)}));assert.equal(ws.code,1008);
});
test('authenticated content, extra fields, self signal and sender spoof never dispatch', async () => {
  for(const body of [{type:'message',body:'secret'},{type:'keepalive',body:'secret'},{type:'catalog',records:[],filename:'secret'},{type:'lookup',identityId:'all'},{type:'catalog',records:Array(65).fill({})}]) {
    const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const ws=await registered(ctx,dir,identity());await dir.webSocketMessage(ws,JSON.stringify(body));assert.equal(ws.code,1008);
  }
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const a=identity(),b=identity(),wa=await registered(ctx,dir,a),wb=await registered(ctx,dir,b);
  await dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope:signal(b,`did:cht:${a.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+1000})}));assert.equal(wa.code,1008);assert.equal(wb.sent.filter(v=>v.type==='signal').length,0);
});
test('per-DID bound and per-socket lookup rate are enforced',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const a=identity();
  for(let i=0;i<4;i++) await registered(ctx,dir,a);
  const fifth=socket(ctx,dir,a);await dir.webSocketMessage(fifth,JSON.stringify({type:'register',proof:proof(a,fifth.attachment.nonce,SEED_ID)}));assert.equal(fifth.code,1008);
  const ws=[...dir.sessions.keys()][0];for(let i=0;i<13;i++)await dir.webSocketMessage(ws,JSON.stringify({type:'lookup',identityId:`did:cht:${identity().id}`}));assert.equal(ws.code,1008);
});
test('closed socket while signature verification awaits cannot register or route stale work', async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const a=identity(),ws=socket(ctx,dir,a);
  const pending=dir.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(a,ws.attachment.nonce,SEED_ID)}));
  dir.webSocketClose(ws,1000,'',true);await pending;assert.equal(ws.sent.length,0);
});
test('close during a valid signal verification cannot dispatch or consume a replay reservation',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
  const a=identity(),b=identity(),wa=await registered(ctx,dir,a),wb=await registered(ctx,dir,b);
  const v=signal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+10000});
  const pending=dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope:v}));
  dir.webSocketClose(wa);await pending;assert.equal(wb.sent.filter(x=>x.type==='signal').length,0);
});
test('bounded replay ledger refuses new dispatch instead of evicting live protection',async()=>{
  const ctx=context();ctx.data.set('control',{records:[],ips:[],replay:Array.from({length:8192},(_,i)=>[String(i),Date.now()+100000])});
  const dir=new SeedDirectory(ctx,{});await dir.ready;const a=identity(),b=identity(),wa=await registered(ctx,dir,a),wb=await registered(ctx,dir,b);
  await dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope:signal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+10000})}));
  assert.equal(wa.code,1008);assert.equal(wb.sent.filter(x=>x.type==='signal').length,0);assert.equal(ctx.data.get('control').replay.length,8192);
});
test('per-IP limit survives reconstruction and bounds unique rate buckets',async()=>{
  for(const saturated of [false,true]){
    const ctx=context(),key=identity(),ip='hash-'+key.id;
    ctx.data.set('control',{records:[],replay:[],ips:saturated?Array.from({length:2048},(_,i)=>['bucket'+i,{until:Date.now()+60000,count:1}]):[[ip,{until:Date.now()+60000,count:240}]]});
    const dir=new SeedDirectory(ctx,{});await dir.ready;const ws=socket(ctx,dir,key);
    await dir.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(key,ws.attachment.nonce,SEED_ID)}));assert.equal(ws.code,1008);
  }
});
test('global asynchronous validation capacity stays reserved until closed work settles',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
  let release;dir.ready=new Promise(r=>release=r);const key=identity(),pending=[];
  const message=JSON.stringify({type:'register',proof:proof(key,Buffer.alloc(32,5).toString('base64url'),SEED_ID)});
  for(let i=0;i<64;i++){const ws=socket(ctx,dir,key);pending.push(dir.webSocketMessage(ws,message));dir.webSocketClose(ws);}
  const overflow=socket(ctx,dir,key),result=dir.webSocketMessage(overflow,message);
  assert.equal(overflow.code,1008);release();await Promise.all([...pending,result]);
});

test('a valid control burst queues behind async validation without closing its socket',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
  const a=identity(),b=identity(),wa=await registered(ctx,dir,a),wb=await registered(ctx,dir,b);
  const first=signal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  const second=signal(a,`did:cht:${b.id}`,{id:first.id.replace('-1','-2'),issuedAt:Date.now(),expiresAt:Date.now()+60000});
  await Promise.all([first,second].map(envelope=>dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope}))));
  assert.equal(wa.code,undefined);
  assert.equal(wb.sent.filter(frame=>frame.type==='signal').length,2);
  assert.equal(dir.inFlight,0);
});
test('signed catalogs persist through hibernation and expired hints are never served',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const a=identity(),wa=await registered(ctx,dir,a);
  const r=record(a,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  await dir.webSocketMessage(wa,JSON.stringify({type:'catalog',records:[r]}));
  const woke=new SeedDirectory(ctx,{});await woke.ready;const wb=await registered(ctx,woke,identity());assert.deepEqual(wb.sent[1],{type:'catalog',records:[r]});
  await woke.webSocketMessage(wb,JSON.stringify({type:'catalog',records:[{...r,endpoint:'wss://127.0.0.1/cht'}]}));assert.equal(wb.code,1008);
  const saved=ctx.data.get('control');saved.records[0].expiresAt=Date.now()-1;ctx.data.set('control',saved);
  const expired=new SeedDirectory(ctx,{});await expired.ready;const wc=await registered(ctx,expired,identity());assert.deepEqual(wc.sent[1],{type:'catalog',records:[]});
});

test('online peers receive new relay hints and coalesced updates survive hibernation',async()=>{
  const clock=Date.now;let time=clock();Date.now=()=>time;
  try{
    const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
    const a=identity(),b=identity(),wa=await registered(ctx,dir,a),wb=await registered(ctx,dir,b);
    const first=record(identity(),{issuedAt:time,expiresAt:time+60000});
    await dir.webSocketMessage(wa,JSON.stringify({type:'catalog',records:[first]}));
    assert.ok(wb.sent.some(frame=>frame.type==='catalog'&&frame.records.some(r=>r.relayId===first.relayId)));
    const second=record(identity(),{issuedAt:time,expiresAt:time+60000});
    await dir.webSocketMessage(wa,JSON.stringify({type:'catalog',records:[second]}));
    assert.ok(!wb.sent.some(frame=>frame.type==='catalog'&&frame.records.some(r=>r.relayId===second.relayId)));
    const woke=new SeedDirectory(ctx,{});await woke.ready;time+=5001;await woke.alarm();
    assert.ok(wb.sent.some(frame=>frame.type==='catalog'&&frame.records.some(r=>r.relayId===second.relayId)));
    assert.ok(wb.sent.filter(frame=>frame.type==='catalog').every(frame=>Buffer.byteLength(JSON.stringify(frame))<=16384));
  }finally{Date.now=clock;}
});
test('outgoing catalog respects frame bytes as well as record count and rotates remaining records',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;const a=identity(),wa=await registered(ctx,dir,a);
  // Use long public hostnames close to the protocol's 2048-byte endpoint budget.
  const records=Array.from({length:12},()=>record(identity(),{endpoint:'wss://'+Array(30).fill('a'.repeat(60)).join('.')+'.example.com/cht',issuedAt:Date.now(),expiresAt:Date.now()+60000}));
  for(let i=0;i<records.length;i+=4)await dir.webSocketMessage(wa,JSON.stringify({type:'catalog',records:records.slice(i,i+4)}));
  assert.equal(wa.code,undefined);
  dir.pendingCatalog.clear(); // Earlier publications have already drained.
  const first=await registered(ctx,dir,identity()),second=await registered(ctx,dir,identity());
  const firstFrame=first.sent[1],secondFrame=second.sent[1];
  assert.ok(Buffer.byteLength(JSON.stringify(firstFrame))<=16384);
  assert.ok(Buffer.byteLength(JSON.stringify(secondFrame))<=16384);
  assert.ok(firstFrame.records.length>0&&firstFrame.records.length<12);
  assert.notEqual(firstFrame.records[0].relayId,secondFrame.records[0].relayId);
  // A long-lived client must also learn records beyond its registration batch.
  const woke=new SeedDirectory(ctx,{});await woke.ready;
  woke.catalogAfter=0;await woke.alarm();woke.catalogAfter=0;await woke.alarm();
  const received=new Set(first.sent.filter(f=>f.type==='catalog').flatMap(f=>f.records.map(r=>r.relayId)));
  assert.equal(received.size,records.length);
});
