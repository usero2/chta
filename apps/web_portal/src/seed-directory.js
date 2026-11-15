import { SEED_ID, DID, MAX_FRAME, bytes, encode, exact, hash, requireThat, verifyProof, verifyRecord, verifySignal } from './protocol.js';

const WINDOW = 60000;
const REPLAYS = 8192, IPS = 2048, RECORDS = 1000;
export class SeedDirectory {
  constructor(ctx, env) {
    this.ctx=ctx; this.env=env; this.sessions=new Map(); this.tails=new Map();this.queued=new Map();this.inFlight=0;this.opening=0;
    this.records=new Map();this.replay=new Map();this.ips=new Map();this.cursor=0;
    this.pendingCatalog=new Set();this.catalogAfter=0;
    this.limit=Math.max(1,Math.min(1000,Number.parseInt(env.SEED_MAX_SOCKETS || '1000',10)||1000));
    for(const ws of ctx.getWebSockets()) {
      const state=ws.deserializeAttachment();
      if(state) this.sessions.set(ws,state);
    }
    // A tiny exact keepalive carries no arbitrary data and needs no wake-up.
    this.autoKeepalive();
    this.ready=ctx.blockConcurrencyWhile(async()=>{
      const state=await ctx.storage.get('control');
      if(state){this.records=new Map(state.records.map(r=>[r.relayId,r]));this.replay=new Map(state.replay);this.ips=new Map(state.ips);this.cursor=state.cursor||0;this.pendingCatalog=new Set(state.pendingCatalog||[]);this.catalogAfter=state.catalogAfter||0;}
      this.prune(Date.now());
    });
  }
  autoKeepalive() {
    // The runtime pair is object-wide. Disable it while ANY challenge is pending,
    // otherwise an unauthenticated socket could bypass registration policy.
    if(typeof WebSocketRequestResponsePair==='undefined')return;
    const authenticated=this.sessions.size>0&&[...this.sessions.values()].every(s=>s.identityId);
    this.ctx.setWebSocketAutoResponse(authenticated?new WebSocketRequestResponsePair('{"type":"keepalive"}','{"type":"alive"}'):undefined);
  }
  prune(now) {
    for(const [id,r] of this.records)if(r.expiresAt<=now){this.records.delete(id);this.pendingCatalog.delete(id);}
    for(const [id,expiry]of this.replay)if(expiry<=now)this.replay.delete(id);
    for(const [id,b]of this.ips)if(b.until<=now)this.ips.delete(id);
  }
  save() {return this.ctx.storage.put('control',{records:[...this.records.values()],replay:[...this.replay],ips:[...this.ips],cursor:this.cursor,pendingCatalog:[...this.pendingCatalog],catalogAfter:this.catalogAfter});}
  async scheduleAlarm() {
    let next=this.pendingCatalog.size?Math.max(Date.now(),this.catalogAfter):Infinity;
    for(const s of this.sessions.values())if(!s.identityId)next=Math.min(next,s.deadline);
    if(Number.isFinite(next))await this.ctx.storage.setAlarm(next);
  }
  flushCatalog(now) {
    if(!this.pendingCatalog.size||now<this.catalogAfter)return;
    const batch=[];
    for(const id of this.pendingCatalog){
      const record=this.records.get(id);
      if(!record){this.pendingCatalog.delete(id);continue;}
      if(batch.length===64||bytes(JSON.stringify({type:'catalog',records:[...batch,record]}))>MAX_FRAME)break;
      batch.push(record);this.pendingCatalog.delete(id);
    }
    if(batch.length)for(const [ws,state]of this.sessions)if(state.identityId&&this.active(ws,state))this.send(ws,{type:'catalog',records:batch});
    this.catalogAfter=now+5000;
  }
  active(ws,state) {return this.sessions.get(ws)===state && ws.readyState===1;}
  close(ws) {this.sessions.delete(ws);this.autoKeepalive();try{ws.close(1008,'Seed control policy');}catch{}}
  send(ws,value) {
    if(ws.readyState!==1)return false;
    if(typeof ws.bufferedAmount==='number'&&ws.bufferedAmount>65536){this.close(ws);return false;}
    try{ws.send(JSON.stringify(value));return true;}catch{this.close(ws);return false;}
  }
  ipRate(ip,now,amount=1) {
    this.prune(now);
    let bucket=this.ips.get(ip);
    if(!bucket){requireThat(this.ips.size<IPS);bucket={until:now+WINDOW,count:0};this.ips.set(ip,bucket);}
    bucket.count+=amount;requireThat(bucket.count<=240);
  }
  socketRate(state,now,type) {
    if(!state.rate||state.rate.until<=now)state.rate={until:now+WINDOW,count:0,lookups:0};
    requireThat(++state.rate.count<=90);
    if(type==='lookup')requireThat(++state.rate.lookups<=12);
    this.ipRate(state.ip,now);
  }
  async fetch(request) {
    await this.ready;
    if(request.method!=='GET'||request.headers.get('upgrade')?.toLowerCase()!=='websocket')return new Response('WebSocket required',{status:426,headers:{'cache-control':'no-store'}});
    this.prune(Date.now());
    if(this.sessions.size+this.opening>=this.limit||this.opening>=32)return new Response('Seed busy',{status:503,headers:{'cache-control':'no-store'}});
    this.opening++;
    try{
    // Hash edge-derived IPs; no contact graph or user content is persisted.
    const ip=await hash(new TextEncoder().encode(request.headers.get('CF-Connecting-IP')||'local'));
    if(this.sessions.size>=this.limit)return new Response('Seed busy',{status:503});
    try{this.ipRate(ip,Date.now(),8);}catch{return new Response('Rate limited',{status:429,headers:{'cache-control':'no-store'}});}
    const pair=new WebSocketPair(),[client,server]=Object.values(pair);
    const nonce=encode(crypto.getRandomValues(new Uint8Array(32)));
    const state={nonce,deadline:Date.now()+30000,ip};
    this.ctx.acceptWebSocket(server);server.serializeAttachment(state);this.sessions.set(server,state);this.autoKeepalive();
    await this.save();
    await this.scheduleAlarm();
    this.send(server,{type:'challenge',protocol:'chta-seed',version:1,seedId:SEED_ID,nonce});
    return new Response(null,{status:101,webSocket:client});
    }finally{this.opening--;}
  }
  async webSocketMessage(ws, message) {
    const state=this.sessions.get(ws);
    const queued=this.queued.get(ws)||0;
    if(!state||this.inFlight>=64||queued>=16||typeof message!=='string'||bytes(message)>MAX_FRAME){this.close(ws);return;}
    this.inFlight++;this.queued.set(ws,queued+1);
    // SDP and ICE often arrive together. Serialize bounded work instead of
    // treating a legitimate burst as a policy violation during async crypto.
    const previous=this.tails.get(ws)||Promise.resolve();
    const operation=previous.catch(()=>{}).then(()=>this.handleMessage(ws,message,state));
    this.tails.set(ws,operation);
    try{await operation;}finally{
      this.inFlight--;
      const remaining=(this.queued.get(ws)||1)-1;
      if(remaining)this.queued.set(ws,remaining);
      else{this.queued.delete(ws);this.tails.delete(ws);}
    }
  }
  async handleMessage(ws,message,state) {
    try{
      await this.ready;
      if(!this.active(ws,state))return;
      requireThat(typeof message==='string' && bytes(message)<=MAX_FRAME);
      const frame=JSON.parse(message),now=Date.now();
      requireThat(frame&&typeof frame==='object'&&!Array.isArray(frame)&&typeof frame.type==='string');
      this.socketRate(state,now,frame.type);
      if(!state.identityId){
        exact(frame,['type','proof']);requireThat(frame.type==='register' && state.nonce && state.deadline>now);
        const nonce=state.nonce;delete state.nonce; // Consumed before any asynchronous verification.
        ws.serializeAttachment(state);
        const identityId=await verifyProof(frame.proof,nonce);
        if(!this.active(ws,state))return;
        requireThat([...this.sessions.values()].filter(s=>s.identityId===identityId).length<4);
        state.identityId=identityId;delete state.deadline;ws.serializeAttachment(state);this.autoKeepalive();
        this.send(ws,{type:'registered',protocol:'chta-seed',version:1});
        this.prune(Date.now());const records=[...this.records.values()];
        const batch=[];
        for(let i=0;i<Math.min(64,records.length);i++){
          const record=records[(this.cursor+i)%records.length];
          if(bytes(JSON.stringify({type:'catalog',records:[...batch,record]}))>MAX_FRAME)break;
          batch.push(record);
        }
        this.cursor=records.length?(this.cursor+batch.length)%records.length:0;
        const delivered=new Set(batch.map(r=>r.relayId));
        for(const r of records)if(!delivered.has(r.relayId))this.pendingCatalog.add(r.relayId);
        this.send(ws,{type:'catalog',records:batch});await this.save();await this.scheduleAlarm();return;
      }
      if(frame.type==='lookup'){
        exact(frame,['type','identityId']);requireThat(typeof frame.identityId==='string'&&DID.test(frame.identityId));
        this.send(ws,{type:'presence',identityId:frame.identityId,online:[...this.sessions].some(([w,s])=>s.identityId===frame.identityId&&this.active(w,s))});
      }else if(frame.type==='signal'){
        exact(frame,['type','envelope']);const v=await verifySignal(frame.envelope,state.identityId,now);
        if(!this.active(ws,state))return;
        this.prune(Date.now());requireThat(v.expiresAt>Date.now());
        const replayKey=await hash(new TextEncoder().encode(JSON.stringify([v.from,v.id,v.signature])));
        if(!this.active(ws,state))return;
        requireThat(!this.replay.has(replayKey)&&this.replay.size<REPLAYS);
        this.replay.set(replayKey,v.expiresAt);
        // Durable replay reservation precedes dispatch, including across hibernation.
        await this.save();if(!this.active(ws,state)||v.expiresAt<=Date.now())return;
        let sent=false;
        for(const [peer,peerState]of this.sessions)if(peerState.identityId===v.to&&this.active(peer,peerState))sent=this.send(peer,{type:'signal',envelope:v})||sent;
        if(!sent)this.send(ws,{type:'unreachable',identityId:v.to});
      }else if(frame.type==='catalog'){
        exact(frame,['type','records']);requireThat(Array.isArray(frame.records)&&frame.records.length<=64);
        const records=[];for(const r of frame.records)records.push(await verifyRecord(r,now));
        if(!this.active(ws,state))return;
        this.prune(Date.now());
        for(const r of records){
          if(r.expiresAt<=Date.now())continue;
          const old=this.records.get(r.relayId);
          if(old&&old.issuedAt>=r.issuedAt)continue;
          if(!old&&this.records.size>=RECORDS)continue;
          this.records.set(r.relayId,r);
          this.pendingCatalog.add(r.relayId);
        }
        this.flushCatalog(Date.now());
      }else if(frame.type==='keepalive'){
        exact(frame,['type']);this.send(ws,{type:'alive'});
      }else{throw new Error('Unsupported control type');}
      if(this.active(ws,state))ws.serializeAttachment(state);
      await this.save();
      await this.scheduleAlarm();
    }catch{this.close(ws);await this.save();}
  }
  webSocketClose(ws) {this.sessions.delete(ws);this.autoKeepalive();try{ws.close(1000,'Closed');}catch{}}
  webSocketError(ws) {this.close(ws);}
  async alarm() {
    await this.ready;const now=Date.now();
    for(const[ws,s]of this.sessions)if(!s.identityId&&s.deadline<=now)this.close(ws);
    this.prune(now);this.flushCatalog(now);await this.save();await this.scheduleAlarm();
  }
}
