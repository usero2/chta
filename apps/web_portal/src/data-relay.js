// Live ciphertext forwarding only. No offline mailbox or payload persistence.
import {DID,bytes,decode,encode,exact,hash,publicEndpoint,requireThat,verifyProof} from './protocol.js';
import {CourierCatalog} from './courier-discovery.js';
const utf8=new TextEncoder(), HEX=/^[0-9a-f]{32}$/;
const courierSelf = frame => frame.session==='636874612d636f75726965722d763100' &&
  frame.body?.type==='courier-v1' && ['host','client'].includes(frame.body.target) &&
  /^[0-9a-f]{64}$/.test(frame.body.nodeId) && HEX.test(frame.body.requestId);
export class DataRelay {
  constructor(ctx,env) {
    this.ctx=ctx;this.env=env;this.sessions=new Map();this.tails=new Map();this.queued=new Map();this.inFlight=0;this.opening=0;
    this.couriers=new CourierCatalog();this.authTimers=new Map();
    this.limit=Math.max(1,Math.min(1000,parseInt(env.RELAY_MAX_SOCKETS||'256',10)||256));
    for(const ws of ctx.getWebSockets()){const state=ws.deserializeAttachment?.()||ws.state;if(state){this.sessions.set(ws,state);if(!state.identityId)this.authTimeout(ws,state);}}
    this.autoKeepalive();
  }
  async record() {
    if(this.cachedRecord?.expiresAt>Date.now()+60000)return this.cachedRecord;
    publicEndpoint(this.env.RELAY_ENDPOINT);
    const raw=decode(this.env.RELAY_PUBLIC_KEY,32),now=Date.now();
    const r={version:1,relayId:await hash(raw),publicKey:encode(raw),endpoint:this.env.RELAY_ENDPOINT,issuedAt:now,expiresAt:now+900000};
    const key=await crypto.subtle.importKey('pkcs8',Uint8Array.from(atob(this.env.RELAY_PRIVATE_KEY.replace(/-/g,'+').replace(/_/g,'/')),c=>c.charCodeAt(0)),{name:'Ed25519'},false,['sign']);
    r.signature=encode(new Uint8Array(await crypto.subtle.sign('Ed25519',key,utf8.encode('cht relay directory v1\0'+JSON.stringify([r.version,r.relayId,r.publicKey,r.endpoint,r.issuedAt,r.expiresAt])))));
    this.cachedRecord=r;return r;
  }
  autoKeepalive() {
    if(typeof WebSocketRequestResponsePair==='undefined')return;
    const authenticated=this.sessions.size&&[...this.sessions.values()].every(s=>s.identityId);
    this.ctx.setWebSocketAutoResponse(authenticated?new WebSocketRequestResponsePair('{"type":"keepalive"}','{"type":"alive"}'):undefined);
  }
  close(ws) {clearTimeout(this.authTimers.get(ws));this.authTimers.delete(ws);this.sessions.delete(ws);this.autoKeepalive();try{ws.close(1008,'Relay policy');}catch{}}
  authTimeout(ws,state){const timer=setTimeout(()=>{this.authTimers.delete(ws);if(this.sessions.get(ws)===state&&!state.identityId)this.close(ws);},Math.max(0,Math.min(15000,state.deadline-Date.now())));timer.unref?.();this.authTimers.set(ws,timer);}
  send(ws,value) {
    if(ws.readyState!==1||ws.bufferedAmount>262144)return false;
    try{ws.send(JSON.stringify(value));return true;}catch{this.close(ws);return false;}
  }
  async challenge(ws,ip) {
    const r=await this.record(),state={nonce:encode(crypto.getRandomValues(new Uint8Array(32))),deadline:Date.now()+15000,ip};
    this.sessions.set(ws,state);ws.serializeAttachment(state);this.autoKeepalive();this.authTimeout(ws,state);
    try{await this.ctx.storage.setAlarm(state.deadline);}catch{/* Timed in memory when SQL quota is unavailable. */}
    if(this.sessions.get(ws)!==state)return;
    this.send(ws,{type:'challenge',nonce:state.nonce,relay:r,relays:[r],capabilities:['courier-directory-v1','courier-self-v1']});
  }
  async fetch(request) {
    if(request.method!=='GET'||request.headers.get('upgrade')?.toLowerCase()!=='websocket')return Response.json({protocol:'chta-data-relay',version:1,mode:'live-encrypted-forwarding',offlineStorage:false},{headers:{'cache-control':'no-store'}});
    if(this.sessions.size+this.opening>=this.limit||this.opening>=32)return new Response('Relay busy',{status:503});
    this.opening++;
    try {
    // The Worker supplies only the configured endpoint; caller URLs are never fetched.
    const pair=new WebSocketPair(),[client,server]=Object.values(pair);
    this.ctx.acceptWebSocket(server);
    await this.challenge(server,await hash(utf8.encode(request.headers.get('CF-Connecting-IP')||'local')));
    return new Response(null,{status:101,webSocket:client});
    } finally { this.opening--; }
  }
  async webSocketMessage(ws,message) {
    const state=this.sessions.get(ws),count=this.queued.get(ws)||0;
    if(!state||typeof message!=='string'||bytes(message)>98304||count>=16||this.inFlight>=128){this.close(ws);return;}
    this.inFlight++;this.queued.set(ws,count+1);
    const previous=this.tails.get(ws)||Promise.resolve();
    const task=previous.catch(()=>{}).then(()=>this.handle(ws,message,state));this.tails.set(ws,task);
    try{await task;}finally{this.inFlight--;const n=(this.queued.get(ws)||1)-1;if(n)this.queued.set(ws,n);else{this.queued.delete(ws);this.tails.delete(ws);}}
  }
  async handle(ws,message,state) {
    try{
      if(this.sessions.get(ws)!==state||ws.readyState!==1)return;
      const frame=JSON.parse(message),now=Date.now();requireThat(frame&&typeof frame==='object'&&!Array.isArray(frame));
      if(!state.rate||state.rate.until<=now)state.rate={until:now+60000,bytes:0,count:0};
      state.rate.bytes+=bytes(message);state.rate.count++;
      requireThat(state.rate.bytes<=64*1024*1024&&state.rate.count<=12000);
      if(!state.identityId){
        requireThat(frame.type==='register'&&state.nonce&&state.deadline>now);
        requireThat(Object.keys(frame).every(k=>['type','proof','relays','subscribeCatalog'].includes(k)));
        const nonce=state.nonce;delete state.nonce;ws.serializeAttachment(state);
        const identityId=await verifyProof(frame.proof,nonce,(await this.record()).relayId);
        if(this.sessions.get(ws)!==state)return;
        requireThat([...this.sessions.values()].filter(s=>s.identityId===identityId).length<4);
        state.identityId=identityId;delete state.ip;clearTimeout(this.authTimers.get(ws));this.authTimers.delete(ws);ws.serializeAttachment(state);this.autoKeepalive();
        this.send(ws,{type:'registered'});return;
      }
      if(frame.type==='keepalive'){exact(frame,['type']);this.send(ws,{type:'alive'});}
      else if(frame.type==='couriers'){
        exact(frame,['type','records']);await this.couriers.merge(frame.records,now);
        if(this.sessions.get(ws)===state)this.send(ws,{type:'couriers',records:this.couriers.batch(Date.now())});
      }else if(frame.type==='directory'){
        requireThat(Object.keys(frame).every(k=>['type','relays','subscribeCatalog'].includes(k))&&Array.isArray(frame.relays)&&frame.relays.length<=64);
        // Public defaults are built into clients; community gossip is handled by seed/peers.
        this.send(ws,{type:'catalog',relays:[await this.record()]});
      }else{
        exact(frame,['type','to','session','packet','body']);
        requireThat(frame.type==='route'&&typeof frame.to==='string'&&DID.test(frame.to)&&(frame.to!==state.identityId||courierSelf(frame))&&HEX.test(frame.session)&&HEX.test(frame.packet)&&frame.body&&typeof frame.body==='object'&&!Array.isArray(frame.body)&&bytes(JSON.stringify(frame.body))<=65536);
        const envelope={type:'route',from:state.identityId,session:frame.session,packet:frame.packet,body:frame.body};
        let sent=0;for(const [peer,s]of this.sessions)if(s.identityId===frame.to&&this.send(peer,envelope))sent++;
        if(!sent)this.send(ws,{type:'unreachable',to:frame.to,session:frame.session});
      }
      // Only bounded authentication/rate metadata survives hibernation.
      ws.serializeAttachment(state);
    }catch{this.close(ws);}
  }
  async alarm() {
    let next=Infinity;
    for(const [ws,s]of this.sessions)if(!s.identityId){if(s.deadline<=Date.now())this.close(ws);else next=Math.min(next,s.deadline);}
    if(Number.isFinite(next))try{await this.ctx.storage.setAlarm(next);}catch{/* Authentication timers remain active. */}
  }
  webSocketClose(ws) {clearTimeout(this.authTimers.get(ws));this.authTimers.delete(ws);this.sessions.delete(ws);this.autoKeepalive();}
  webSocketError(ws) {this.close(ws);}
}
