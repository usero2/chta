// Disposable synthetic identities only; never loads an app profile or sends content.
import assert from 'node:assert/strict';
import { identity, proof, signal } from '../apps/web_portal/test/helpers.js';

const endpoint=process.argv[2];
if(!endpoint?.startsWith('wss://'))throw Error('Pass a public wss seed endpoint');
const opened=[];
async function client(key){
  const ws=new WebSocket(endpoint);opened.push(ws);
  const inbox=[],waiters=[];
  ws.addEventListener('message',event=>{
    const frame=JSON.parse(event.data),index=waiters.findIndex(w=>w.type===frame.type);
    if(index<0){inbox.push(frame);return;}
    const waiter=waiters.splice(index,1)[0];clearTimeout(waiter.timer);waiter.resolve(frame);
  });
  function next(type){
    const index=inbox.findIndex(f=>f.type===type);
    if(index>=0)return Promise.resolve(inbox.splice(index,1)[0]);
    return new Promise((resolve,reject)=>{
      const waiter={type,resolve,timer:setTimeout(()=>{const i=waiters.indexOf(waiter);if(i>=0)waiters.splice(i,1);reject(Error(`Timeout waiting for ${type}`));},15000)};
      waiters.push(waiter);
    });
  }
  const challenge=await next('challenge');
  ws.send(JSON.stringify({type:'register',proof:proof(key,challenge.nonce,challenge.seedId)}));
  assert.equal((await next('registered')).protocol,'chta-seed');
  await next('catalog');
  return {ws,next};
}
try{
  const a=identity(),b=identity(),left=await client(a),right=await client(b);
  left.ws.send(JSON.stringify({type:'lookup',identityId:`did:cht:${b.id}`}));
  assert.equal((await left.next('presence')).online,true);
  const envelope=signal(a,`did:cht:${b.id}`,{issuedAt:Date.now(),expiresAt:Date.now()+60000});
  left.ws.send(JSON.stringify({type:'signal',envelope}));
  assert.deepEqual((await right.next('signal')).envelope,envelope);
  console.log('PASS: public WSS registration, synthetic peer discovery and signed SDP forwarding');
}finally{for(const ws of opened)ws.close();}
