import {test} from 'node:test';
import assert from 'node:assert/strict';
import {SeedDirectory} from '../src/seed-directory.js';
import {SEED_ID} from '../src/protocol.js';
import {identity,proof,signal,groupSignal,contactSignal,dispatch} from './helpers.js';

function context(){
  const sockets=[],calls={get:0,put:0,alarm:0};
  return {sockets,calls,storage:{async get(){calls.get++;throw Error('quota');},async put(){calls.put++;throw Error('quota');},async setAlarm(){calls.alarm++;throw Error('quota');}},
    blockConcurrencyWhile:f=>f(),getWebSockets:()=>sockets,setWebSocketAutoResponse(){}};
}
async function client(ctx,dir,key){
  const nonce=crypto.getRandomValues(new Uint8Array(32));
  const connection=Buffer.from(nonce).toString('base64url');
  const ws={readyState:1,sent:[],send(s){this.sent.push(JSON.parse(s));},close(code){this.code=code;this.readyState=3;},serializeAttachment(s){this.attachment=structuredClone(s);assert.ok(Buffer.byteLength(JSON.stringify(s))<=2048);},deserializeAttachment(){return structuredClone(this.attachment);}};
  ws.serializeAttachment({nonce:connection,connection,sequence:0,deadline:Date.now()+30000,ip:'test-ip-'+key.id});
  ctx.sockets.push(ws);dir.sessions.set(ws,ws.deserializeAttachment());
  await dir.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(key,connection,SEED_ID)}));
  assert.equal(ws.sent[0]?.type,'registered');return ws;
}
test('quota failures never prevent registration, lookup or session-bound dispatch, including actor reconstruction',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
  const a=identity(),b=identity(),wa=await client(ctx,dir,a),wb=await client(ctx,dir,b);
  const writes=ctx.calls.put;
  for(const type of ['lookup','keepalive'])await dir.webSocketMessage(wa,JSON.stringify(type==='lookup'?{type,identityId:'did:cht:'+b.id}:{type}));
  assert.equal(wa.sent.findLast(x=>x.type==='presence').online,true);
  assert.equal(ctx.calls.put,writes);
  let sequence=0;
  for(const make of [signal,groupSignal,contactSignal]){
    const envelope=make(a,'did:cht:'+b.id,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
    const frame={type:'signal',envelope,dispatch:dispatch(a,envelope,wa.attachment.connection,++sequence)};
    await dir.webSocketMessage(wa,JSON.stringify(frame));
    assert.deepEqual(wb.sent.at(-1),{type:'signal',envelope});
    assert.equal(wa.attachment.sequence,sequence);
    assert.ok(!JSON.stringify(wa.attachment).includes(envelope.payload));
  }
  assert.equal(ctx.calls.put,writes,'new signaling never writes SQL');
  const woke=new SeedDirectory(ctx,{});await woke.ready;
  const envelope=signal(a,'did:cht:'+b.id,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  await woke.webSocketMessage(wa,JSON.stringify({type:'signal',envelope,dispatch:dispatch(a,envelope,wa.attachment.connection,sequence)}));
  assert.equal(wa.code,1008);assert.equal(wb.sent.filter(x=>x.type==='signal').length,3);
});
test('legacy reservation quota failure is explicit and never forwards or rejects the actor promise',async()=>{
  const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
  const a=identity(),b=identity(),wa=await client(ctx,dir,a),wb=await client(ctx,dir,b);
  const envelope=signal(a,'did:cht:'+b.id,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  await assert.doesNotReject(dir.webSocketMessage(wa,JSON.stringify({type:'signal',envelope})));
  assert.equal(wb.sent.filter(x=>x.type==='signal').length,0);
  assert.ok(wa.sent.some(x=>x.type==='error'&&x.code==='storage-unavailable'));
});
test('dispatch for another connection, unsafe sequence or user content never forwards',async()=>{
  for(const mutate of [f=>f.dispatch.connection=Buffer.alloc(32,7).toString('base64url'),
    f=>f.dispatch.sequence=Number.MAX_SAFE_INTEGER+1,f=>f.envelope.payload=JSON.stringify({text:'private'})]){
    const ctx=context(),dir=new SeedDirectory(ctx,{});await dir.ready;
    const a=identity(),b=identity(),wa=await client(ctx,dir,a),wb=await client(ctx,dir,b);
    const envelope=signal(a,'did:cht:'+b.id,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
    const frame={type:'signal',envelope,dispatch:dispatch(a,envelope,wa.attachment.connection)};mutate(frame);
    await dir.webSocketMessage(wa,JSON.stringify(frame));assert.equal(wa.code,1008);
    assert.equal(wb.sent.filter(x=>x.type==='signal').length,0);
  }
});
