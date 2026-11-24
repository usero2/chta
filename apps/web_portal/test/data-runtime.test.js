import {test} from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync} from 'node:crypto';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {createServer} from 'node:net';
import {spawn} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {identity,proof,advertisement} from './helpers.js';
import {verifyRecord} from '../src/protocol.js';

function queue(ws) {
  const messages=[],waiters=[];
  ws.addEventListener('message',event=>{const v=JSON.parse(event.data);if(waiters.length)waiters.shift()(v);else messages.push(v);});
  return ()=>messages.length?Promise.resolve(messages.shift()):Promise.race([new Promise(r=>waiters.push(r)),delay(10000).then(()=>{throw Error('WebSocket timeout');})]);
}
test('data relay works in actual workerd with authenticated opaque forwarding', {timeout:60000},async t=>{
  const server=createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));
  const folder=await mkdtemp(join(tmpdir(),'chta-data-test-')),key=generateKeyPairSync('ed25519');
  const wrapper=join(folder,'quota-worker.mjs');
  await writeFile(wrapper,`import worker,{DataRelay} from ${JSON.stringify(resolve('src/data-worker.js').replaceAll('\\','/'))};export {DataRelay};export class QuotaDataRelay extends DataRelay{constructor(ctx,env){super(new Proxy(ctx,{get(t,k){if(k==='storage')return {async setAlarm(){throw Error('quota');},async get(){throw Error('quota');},async put(){throw Error('quota');}};const v=Reflect.get(t,k,t);return typeof v==='function'?v.bind(t):v;}}),env);}}export default{async fetch(r,e){if(new URL(r.url).pathname==='/__quota'){const u=new URL(r.url);u.pathname='/cht';return worker.fetch(new Request(u,r),{...e,DATA_RELAY:e.QUOTA_RELAY});}return worker.fetch(r,e);}};`);
  const config={name:'chta-data-test',main:wrapper,compatibility_date:'2026-11-01',durable_objects:{bindings:[{name:'DATA_RELAY',class_name:'DataRelay'},{name:'QUOTA_RELAY',class_name:'QuotaDataRelay'}]},migrations:[{tag:'v1',new_sqlite_classes:['DataRelay','QuotaDataRelay']}],vars:{RELAY_ENDPOINT:'wss://relay1.chta.app/cht',RELAY_MAX_SOCKETS:'8',RELAY_PUBLIC_KEY:key.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64url')}};
  await writeFile(join(folder,'wrangler.json'),JSON.stringify(config));
  await writeFile(join(folder,'.dev.vars'),`RELAY_PRIVATE_KEY=${key.privateKey.export({type:'pkcs8',format:'der'}).toString('base64url')}\n`);
  const child=spawn(process.execPath,[resolve('node_modules/wrangler/bin/wrangler.js'),'dev','--local','--config',join(folder,'wrangler.json'),'--ip','127.0.0.1','--port',String(port),'--persist-to',join(folder,'state')],{cwd:resolve('.'),windowsHide:true,stdio:['ignore','pipe','pipe'],env:{...process.env,WRANGLER_SEND_METRICS:'false',CI:'true'}});
  let output='';child.stdout.on('data',v=>output+=v);child.stderr.on('data',v=>output+=v);
  t.after(async()=>{child.kill();await Promise.race([new Promise(r=>child.once('exit',r)),delay(5000)]);await rm(folder,{recursive:true,force:true,maxRetries:5,retryDelay:200});});
  const base=`http://127.0.0.1:${port}`;let ready=false;
  for(let i=0;i<120;i++){try{if((await fetch(base+'/cht',{signal:AbortSignal.timeout(500)})).ok){ready=true;break;}}catch{}if(child.exitCode!==null)break;await delay(150);}
  assert.ok(ready,output);
  assert.equal((await(await fetch(base+'/cht')).json()).offlineStorage,false);
  const clients=[];t.after(()=>clients.forEach(c=>c.ws.close()));
  async function client(path='/cht') {
    const user=identity(),ws=new WebSocket(`ws://127.0.0.1:${port}${path}`),next=queue(ws),c=await next();
    await verifyRecord(c.relay,Date.now());
    ws.send(JSON.stringify({type:'register',proof:proof(user,c.nonce,c.relay.relayId),relays:[],subscribeCatalog:true}));
    assert.equal((await next()).type,'registered');const value={ws,next,user,c};clients.push(value);return value;
  }
  const a=await client(),b=await client();
  const qa=await client('/__quota'),qb=await client('/__quota'),ad=advertisement();
  assert.ok(qa.c.capabilities.includes('courier-directory-v1'));
  qa.ws.send(JSON.stringify({type:'couriers',records:[ad]}));assert.deepEqual(await qa.next(),{type:'couriers',records:[ad]});
  qb.ws.send(JSON.stringify({type:'couriers',records:[]}));assert.deepEqual(await qb.next(),{type:'couriers',records:[ad]});
  qa.ws.send(JSON.stringify({type:'route',to:`did:cht:${qb.user.id}`,session:'c'.repeat(32),packet:'d'.repeat(32),body:{type:'courier-v1',ciphertext:'synthetic'}}));assert.equal((await qb.next()).body.ciphertext,'synthetic');
  const frame={type:'route',to:`did:cht:${b.user.id}`,session:'a'.repeat(32),packet:'b'.repeat(32),body:{type:'encrypted',ciphertext:'synthetic opaque payload'}};
  a.ws.send(JSON.stringify(frame));assert.deepEqual(await b.next(),{type:'route',from:`did:cht:${a.user.id}`,session:frame.session,packet:frame.packet,body:frame.body});
  a.ws.send('{"type":"keepalive"}');assert.equal((await a.next()).type,'alive');
  a.ws.send(JSON.stringify({...frame,to:`did:cht:${identity().id}`}));assert.equal((await a.next()).type,'unreachable');
  const closed=new Promise(r=>a.ws.addEventListener('close',r,{once:true}));a.ws.send(JSON.stringify({...frame,from:`did:cht:${b.user.id}`}));assert.equal((await closed).code,1008);
});
