// Disposable synthetic identities only; never loads an app profile or sends content.
import assert from 'node:assert/strict';
import { identity, proof, signal, groupSignal, contactSignal, dispatch } from '../apps/web_portal/test/helpers.js';

const endpoint=process.argv[2];
if(!endpoint?.startsWith('wss://'))throw Error('Pass a public wss seed endpoint');
const opened=[];
async function client(key){
  const ws=new WebSocket(endpoint);opened.push(ws);
  const inbox=[],waiters=[];
  let failure=null,phase='challenge';
  function fail(){failure=Error(`Seed WebSocket closed or upgrade failed while waiting for ${phase}`);for(const w of waiters.splice(0)){clearTimeout(w.timer);w.reject(failure);}}
  ws.addEventListener('error',fail);ws.addEventListener('close',fail);
  ws.addEventListener('message',event=>{
    const frame=JSON.parse(event.data),index=waiters.findIndex(w=>w.type===frame.type);
    if(index<0){inbox.push(frame);return;}
    const waiter=waiters.splice(index,1)[0];clearTimeout(waiter.timer);waiter.resolve(frame);
  });
  function next(type){
    phase=type;
    const index=inbox.findIndex(f=>f.type===type);
    if(index>=0)return Promise.resolve(inbox.splice(index,1)[0]);
    if(failure)return Promise.reject(failure);
    return new Promise((resolve,reject)=>{
      const waiter={type,resolve,reject,timer:setTimeout(()=>{const i=waiters.indexOf(waiter);if(i>=0)waiters.splice(i,1);reject(Error(`Timeout waiting for ${type}`));},15000)};
      waiters.push(waiter);
    });
  }
  const challenge=await next('challenge');
  ws.send(JSON.stringify({type:'register',proof:proof(key,challenge.nonce,challenge.seedId)}));
  assert.equal((await next('registered')).protocol,'chta-seed');
  await next('catalog');
  return {ws,next,challenge};
}
try{
  const a=identity(),b=identity(),left=await client(a),right=await client(b);
  left.ws.send(JSON.stringify({type:'lookup',identityId:`did:cht:${b.id}`}));
  assert.equal((await left.next('presence')).online,true);
  assert.ok(left.challenge.capabilities?.includes('session-dispatch-v1'),'updated dispatch capability required');
  let sequence=0;
  for(const make of [signal,groupSignal,contactSignal]){
    const envelope=make(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
    left.ws.send(JSON.stringify({type:'signal',envelope,dispatch:dispatch(a,envelope,left.challenge.nonce,++sequence)}));
    assert.deepEqual((await right.next('signal')).envelope,envelope);
  }
  const legacyKey=identity(),legacy=await client(legacyKey);
  legacy.ws.send('{"type":"keepalive"}');assert.equal((await legacy.next('alive')).type,'alive');
  const oldEnvelope=signal(legacyKey,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  legacy.ws.send(JSON.stringify({type:'signal',envelope:oldEnvelope}));
  const legacyResult=await Promise.race([right.next('signal').then(f=>{assert.deepEqual(f.envelope,oldEnvelope);return 'durable forwarding';}),legacy.next('error').then(f=>{assert.equal(f.code,'storage-unavailable');return 'explicit storage-unavailable';})]);
  console.log('PASS: public WSS registration, peer lookup, session-bound direct/group/contact dispatch and legacy keepalive');
  console.log('Legacy signaling: '+legacyResult);
}finally{for(const ws of opened)ws.close();}
