// Origin-protected account data and PIN-protected recovery secrets.
// Secret bytes remain in this host/WASM boundary, never in Dart responses.
const encoder=new TextEncoder(), decoder=new TextDecoder('utf-8',{fatal:true});
const did=/^did:cht:[0-9a-f]{64}$/;
const iterations=600000;
const indexKey='identity-index-v1';
function owner(id){if(!did.test(id))throw Error('Invalid identity');}
function pin(value){if(typeof value!=='string'||!/^\d{6,12}$/.test(value))throw Error('Use 6 to 12 digits.');}

export class WebIdentityVault {
  constructor(host){this.host=host;}
  async list(){return (await this.host.read(indexKey))??[];}
  async _seal(id,kind,bytes){
    const key=await this.host.key(),iv=crypto.getRandomValues(new Uint8Array(12));
    const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode(`chta-web-identity-v1\0${id}\0${kind}`)},key,bytes);
    return {version:1,iv,ciphertext};
  }
  async _open(id,kind,record){
    if(record?.version!==1||record.iv?.byteLength!==12||!record.ciphertext||record.ciphertext.byteLength>16*1024*1024)throw Error('Saved identity data is damaged');
    return new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:record.iv,additionalData:encoder.encode(`chta-web-identity-v1\0${id}\0${kind}`)},await this.host.key(),record.ciphertext));
  }
  _state(value){
    if(!value||typeof value.chat!=='string'||typeof value.contacts!=='string'||typeof value.profile?.name!=='string'||typeof value.profile?.avatar!=='string'||value.profile.name.length>256||value.profile.avatar.length>400000)throw Error('Invalid account data');
    const bytes=encoder.encode(JSON.stringify(value));
    if(bytes.length>8*1024*1024)throw Error('Account data too large');
    return bytes;
  }
  async register(id,secret,state){
    owner(id);
    if(!(secret instanceof Uint8Array)||!secret.length||secret.length>16384)throw Error('Invalid identity secret');
    return this.host.locked(async()=>{
      const draft=await this._seal(id,'draft',secret), account=await this._seal(id,'account',this._state(state));
      const list=await this.list();
      const entry={identityId:id,displayName:state.profile.name,avatar:state.profile.avatar,requiresPin:false,lockedUntilMilliseconds:0,failures:0};
      await this.host.atomic([[`draft:${id}`,draft],[`account:${id}`,account],[`pin:${id}`,null],[indexKey,[...list.filter(e=>e.identityId!==id),entry]]]);
    });
  }
  async _pinKey(value,salt){
    const material=await crypto.subtle.importKey('raw',encoder.encode(value),'PBKDF2',false,['deriveKey']);
    return crypto.subtle.deriveKey({name:'PBKDF2',hash:'SHA-256',salt,iterations},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);
  }
  async remember(id,value){
    owner(id);pin(value);
    return this.host.locked(async()=>{
      const list=await this.list(),entry=list.find(e=>e.identityId===id);
      if(!entry)throw Error('Identity is unavailable');
      const draft=await this.host.read(`draft:${id}`);
      if(!draft)throw Error('Restore this identity before setting a new PIN');
      const secret=await this._open(id,'draft',draft);
      try{
        const salt=crypto.getRandomValues(new Uint8Array(16)),iv=crypto.getRandomValues(new Uint8Array(12));
        const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encoder.encode(id)},await this._pinKey(value,salt),secret);
        const wrapped=await this._seal(id,'pin',encoder.encode(JSON.stringify({version:1,iterations,salt:[...salt],iv:[...iv],ciphertext:[...new Uint8Array(ciphertext)]})));
        await this.host.atomic([[`pin:${id}`,wrapped],[`draft:${id}`,null],[indexKey,list.map(e=>e.identityId===id?{...e,requiresPin:true,failures:0,lockedUntilMilliseconds:0}:e)]],{clearLegacySecret:true});
      }finally{secret.fill(0);}
    });
  }
  async unlock(id,value){
    owner(id);
    return this.host.locked(async()=>{
      const list=await this.list(),entry=list.find(e=>e.identityId===id);
      if(!entry)throw Error('Saved identity is unavailable');
      if(!entry.requiresPin)return this._open(id,'draft',await this.host.read(`draft:${id}`));
      pin(value);
      if(entry.lockedUntilMilliseconds>Date.now())throw Error('Try again after the PIN timeout.');
      const wrapped=await this._open(id,'pin',await this.host.read(`pin:${id}`));
      let document;
      try{document=JSON.parse(decoder.decode(wrapped));}finally{wrapped.fill(0);}
      if(document.version!==1||document.iterations!==iterations||document.salt?.length!==16||document.iv?.length!==12||!Array.isArray(document.ciphertext)||document.ciphertext.length>16400)throw Error('Saved identity data is damaged');
      let result;
      try{
        result=new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:new Uint8Array(document.iv),additionalData:encoder.encode(id)},await this._pinKey(value,new Uint8Array(document.salt)),new Uint8Array(document.ciphertext)));
      }catch{
        const failures=(entry.failures??0)+1;
        await this.host.atomic([[indexKey,list.map(e=>e.identityId===id?{...e,failures,lockedUntilMilliseconds:failures>=5?Date.now()+30000:0}:e)]]);
        throw Error('Incorrect PIN.');
      }
      try{
        await this.host.atomic([[indexKey,list.map(e=>e.identityId===id?{...e,failures:0,lockedUntilMilliseconds:0}:e)]]);
        return result;
      }catch(error){result.fill(0);throw error;}
    });
  }
  async loadState(id){
    owner(id);const record=await this.host.read(`account:${id}`);
    if(!record)return null;
    const bytes=await this._open(id,'account',record);
    try{const state=JSON.parse(decoder.decode(bytes));this._state(state);return state;}finally{bytes.fill(0);}
  }
  async saveState(id,state){
    owner(id);
    return this.host.locked(async()=>{
      const account=await this._seal(id,'account',this._state(state)),list=await this.list();
      if(!list.some(e=>e.identityId===id))throw Error('Unknown saved identity');
      await this.host.atomic([[`account:${id}`,account],[indexKey,list.map(e=>e.identityId===id?{...e,displayName:state.profile.name,avatar:state.profile.avatar}:e)]]);
    });
  }
}

export function createIndexedDbIdentityVault(database,key){
  const prefix='web-vault-v1:';
  let tail=Promise.resolve();
  return new WebIdentityVault({
    key,
    read: name=>new Promise((resolve,reject)=>{
      const tx=database.transaction('secrets','readonly'),request=tx.objectStore('secrets').get(prefix+name);
      request.onsuccess=()=>resolve(request.result??null);request.onerror=()=>reject(request.error);tx.onabort=()=>reject(tx.error);
    }),
    atomic: (entries,options)=>new Promise((resolve,reject)=>{
      const tx=database.transaction('secrets','readwrite'),store=tx.objectStore('secrets');
      tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);
      try{
        for(const [name,value]of entries){if(value===null)store.delete(prefix+name);else store.put(value,prefix+name);}
        if(options?.clearLegacySecret)store.delete('identity-secret');
      }catch(error){try{tx.abort();}catch{}reject(error);}
    }),
    locked: action=>{
      const operation=()=>globalThis.navigator?.locks?navigator.locks.request('chta-web-identity-vault',action):action();
      const result=tail.catch(()=>{}).then(operation);tail=result.catch(()=>{});return result;
    },
  });
}
