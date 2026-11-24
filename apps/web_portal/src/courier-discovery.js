// Public metadata only. Hosts keep ciphertext and mailboxes outside seed infrastructure.
import {DID,bytes,decode,exact,hash,publicEndpoint,requireThat} from './protocol.js';
const utf8=new TextEncoder(),HEX=/^[0-9a-f]{64}$/;
async function verify(publicKey,sig,payload){
  const key=await crypto.subtle.importKey('raw',decode(publicKey,32),{name:'Ed25519'},false,['verify']);
  requireThat(await crypto.subtle.verify('Ed25519',key,decode(sig,64),utf8.encode(payload)));
}
export async function verifyCourierAdvertisement(c,now){
  exact(c,['version','kind','signerId','publicKey','certificate','challenge','body','issuedAt','expiresAt','signature']);
  requireThat(bytes(JSON.stringify(c))<=4096&&c.version===1&&c.kind==='advertisement'&&HEX.test(c.signerId)&&c.challenge==='A'.repeat(43));
  const n=c.certificate;
  exact(n,['version','ownerId','rootPublicKey','nodeId','signingPublicKey','createdAt','signature']);
  requireThat(n.version===1&&DID.test(n.ownerId)&&n.nodeId===c.signerId&&n.signingPublicKey===c.publicKey&&Number.isSafeInteger(n.createdAt)&&n.createdAt>=0&&n.createdAt<=now+30000);
  requireThat(n.ownerId==='did:cht:'+await hash(decode(n.rootPublicKey,32))&&n.nodeId===await hash(decode(n.signingPublicKey,32)));
  const cert={version:n.version,ownerId:n.ownerId,rootPublicKey:n.rootPublicKey,nodeId:n.nodeId,signingPublicKey:n.signingPublicKey,createdAt:n.createdAt,signature:n.signature};
  await verify(n.rootPublicKey,n.signature,'chta courier node certificate v1\0'+JSON.stringify([n.version,n.ownerId,n.rootPublicKey,n.nodeId,n.signingPublicKey,n.createdAt]));
  const b=c.body;exact(b,['version','nodeId','ownerId','routes','maxPackageBytes','freeBytes']);
  requireThat(b.version===1&&b.nodeId===n.nodeId&&b.ownerId===n.ownerId&&b.maxPackageBytes===262144&&Number.isSafeInteger(b.freeBytes)&&b.freeBytes>=0&&b.freeBytes<=1099511627776&&Array.isArray(b.routes)&&b.routes.length>0&&b.routes.length<=8&&new Set(b.routes).size===b.routes.length);
  for(const url of b.routes)publicEndpoint(url);
  requireThat(Number.isSafeInteger(c.issuedAt)&&c.issuedAt>=0&&c.issuedAt<=now+30000&&Number.isSafeInteger(c.expiresAt)&&c.expiresAt>now&&c.expiresAt>c.issuedAt&&c.expiresAt-c.issuedAt<=900000);
  // serde_json Value sorts object keys; the certificate struct has a fixed field order.
  const body=Object.fromEntries(Object.keys(b).sort().map(k=>[k,b[k]]));
  await verify(c.publicKey,c.signature,'chta courier control v1\0'+JSON.stringify([1,'advertisement',c.signerId,c.publicKey,cert,c.challenge,body,c.issuedAt,c.expiresAt]));
  return c;
}

// Ephemeral hints republish after reconnect. No account SQL or offline mailbox.
export class CourierCatalog {
  constructor(){this.records=new Map();this.cursor=0;}
  prune(now){for(const [id,r]of this.records)if(r.expiresAt<=now)this.records.delete(id);}
  async merge(records,now){
    requireThat(Array.isArray(records)&&records.length<=8);
    const checked=[];for(const r of records)checked.push(await verifyCourierAdvertisement(r,now));
    this.prune(Date.now());
    for(const r of checked){
      if(r.expiresAt<=Date.now())continue;
      const old=this.records.get(r.signerId);if(old&&old.issuedAt>=r.issuedAt)continue;
      if(!old&&(this.records.size>=256||[...this.records.values()].filter(v=>v.certificate.ownerId===r.certificate.ownerId).length>=8))continue;
      this.records.set(r.signerId,r);
    }
  }
  batch(now){
    this.prune(now);const all=[...this.records.values()],batch=[];
    if(!all.length)return batch;
    for(let i=0;i<Math.min(8,all.length);i++){
      const r=all[(this.cursor+i)%all.length];
      if(bytes(JSON.stringify([...batch,r]))>12000)break;batch.push(r);
    }
    this.cursor=(this.cursor+batch.length)%all.length;return batch;
  }
}
