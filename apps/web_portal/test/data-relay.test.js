import {test} from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {DataRelay} from '../src/data-relay.js';
import {verifyRecord} from '../src/protocol.js';
import {advertisement} from './helpers.js';
import {identity,proof} from './helpers.js';

function setup() {
  const key=generateKeyPairSync('ed25519');
  const writes=[];
  const ctx={getWebSockets:()=>[],setWebSocketAutoResponse(){},storage:{setAlarm:async()=>{},put:async(...args)=>writes.push(args)}};
  const relay=new DataRelay(ctx,{RELAY_PRIVATE_KEY:key.privateKey.export({type:'pkcs8',format:'der'}).toString('base64url'),RELAY_PUBLIC_KEY:key.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64url'),RELAY_ENDPOINT:'wss://relay1.chta.app/cht'});
  const socket=()=>({readyState:1,sent:[],send(v){this.sent.push(JSON.parse(v));},serializeAttachment(v){this.state=structuredClone(v);},close(code){this.code=code;this.readyState=3;}});
  const register=async(user=identity())=>{const ws=socket();await relay.challenge(ws,'synthetic');const c=ws.sent.shift();await verifyRecord(c.relay,Date.now());await relay.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(user,c.nonce,c.relay.relayId),relays:[]}));assert.equal(ws.sent.shift().type,'registered');return {ws,user,c};};
  return {relay,writes,socket,register};
}
test('authenticated opaque forwarding, unreachable and no payload storage',async()=>{
  const {relay,writes,register}=setup(),a=await register(),b=await register();
  const frame={type:'route',to:`did:cht:${b.user.id}`,session:'a'.repeat(32),packet:'b'.repeat(32),body:{t:'cipher',ciphertext:'synthetic-encrypted-bytes'}};
  await relay.webSocketMessage(a.ws,JSON.stringify(frame));
  assert.deepEqual(b.ws.sent.pop(),{type:'route',from:`did:cht:${a.user.id}`,session:frame.session,packet:frame.packet,body:frame.body});
  relay.webSocketClose(b.ws);await relay.webSocketMessage(a.ws,JSON.stringify(frame));
  assert.deepEqual(a.ws.sent.pop(),{type:'unreachable',to:frame.to,session:frame.session});
  assert.equal(writes.length,0);assert.ok(!JSON.stringify(a.ws.state).includes('ciphertext'));
});
test('proof bound to challenge and relay; pending keepalive and forged sender rejected',async()=>{
  for(const kind of ['wrong-nonce','keepalive','spoof']){
    const {relay,socket,register}=setup();let ws;
    if(kind==='spoof'){({ws}=await register());await relay.webSocketMessage(ws,JSON.stringify({type:'route',from:`did:cht:${identity().id}`,to:`did:cht:${identity().id}`,session:'a'.repeat(32),packet:'b'.repeat(32),body:{}}));}
    else{ws=socket();await relay.challenge(ws,'synthetic');const c=ws.sent.shift();await relay.webSocketMessage(ws,JSON.stringify(kind==='keepalive'?{type:'keepalive'}:{type:'register',proof:proof(identity(),'A'.repeat(43),c.relay.relayId)}));}
    assert.equal(ws.code,1008,kind);
  }
});
test('restores authenticated sockets after hibernation and rejects oversized frames',async()=>{
  const {relay,register}=setup(),a=await register(),b=await register();
  const resumed=new DataRelay({...relay.ctx,getWebSockets:()=>[a.ws,b.ws]},relay.env);
  await resumed.webSocketMessage(a.ws,'{"type":"keepalive"}');assert.equal(a.ws.sent.pop().type,'alive');
  await resumed.webSocketMessage(a.ws,JSON.stringify({type:'route',to:`did:cht:${b.user.id}`,session:'a'.repeat(32),packet:'b'.repeat(32),body:{x:'x'.repeat(65537)}}));assert.equal(a.ws.code,1008);
});
test('one identity has at most four sockets and incomplete registration expires',async()=>{
  const {relay,register,socket}=setup(),user=identity();for(let i=0;i<4;i++)await register(user);
  const ws=socket();await relay.challenge(ws,'synthetic');const c=ws.sent.shift();await relay.webSocketMessage(ws,JSON.stringify({type:'register',proof:proof(user,c.nonce,c.relay.relayId)}));assert.equal(ws.code,1008);
  const pending=socket();await relay.challenge(pending,'synthetic');relay.sessions.get(pending).deadline=0;await relay.alarm();assert.equal(pending.code,1008);
});
test('bounded concurrent openings reject before creating more WebSockets',async()=>{
  const {relay}=setup();relay.opening=32;
  assert.equal((await relay.fetch(new Request('https://relay1.chta.app/cht',{headers:{upgrade:'websocket'}}))).status,503);
});
test('own-device Courier frames route to the authenticated identity, while ordinary self chat stays forbidden',async()=>{
  const {relay,register}=setup(),a=await register();
  const frame={type:'route',to:`did:cht:${a.user.id}`,session:'636874612d636f75726965722d763100',packet:'b'.repeat(32),body:{type:'courier-v1',target:'host',nodeId:'a'.repeat(64),requestId:'c'.repeat(32),op:'hello',nonce:'A'.repeat(43)}};
  await relay.webSocketMessage(a.ws,JSON.stringify(frame));assert.equal(a.ws.readyState,1);assert.equal(a.ws.sent.pop().body.type,'courier-v1');
  await relay.webSocketMessage(a.ws,JSON.stringify({...frame,body:{type:'ordinary-message'}}));assert.equal(a.ws.code,1008);
});
test('quota exhaustion cannot block registration and Courier discovery stays metadata-only',async()=>{
  const {relay,register}=setup();relay.ctx.storage.setAlarm=async()=>{throw Error('quota');};
  const a=await register(),b=await register();
  assert.ok(a.c.capabilities.includes('courier-directory-v1'));
  const record=advertisement();
  await relay.webSocketMessage(a.ws,JSON.stringify({type:'couriers',records:[record]}));assert.equal(a.ws.readyState,1);
  await relay.webSocketMessage(b.ws,JSON.stringify({type:'couriers',records:[]}));
  assert.deepEqual(b.ws.sent.pop(),{type:'couriers',records:[record]});
  await relay.webSocketMessage(b.ws,JSON.stringify({type:'couriers',records:[],ciphertext:'secret'}));assert.equal(b.ws.code,1008);
});
