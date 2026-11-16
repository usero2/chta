import init, { AccountCore, core_version, WebChatCore } from './wasm/cht_core.js';
import {loadGroupBlob, saveGroupBlob, deleteGroupBlob} from './group_blob_store.js';
import {createIndexedDbIdentityVault} from './web_identity_vault.js';
import {AccountMutationQueue,acquireAccountLease} from './web_account_session.js';

const databaseName = 'cht';
const databaseVersion = 2;
const stateStore = 'state';
const keyStore = 'keys';
const secretStore = 'secrets';
const chatStateKey = 'chat-store';
const contactsStateKey = 'contacts';
const profileNameKey = 'cht.profile-name';
const wrappingKeyName = 'identity-wrapping-key';
const identitySecretKey = 'identity-secret';

let core;
let account;
let identityVault;
let activeId=null;
let activeProfile={name:'',avatar:''};
let identityGeneration=0;
let accountLease=null;
const accountMutations=new AccountMutationQueue();
let peerConnection;
let dataChannel;
let localGateway;
let peerInitiator = false;
let peerPrepared = false;
let peerAuthenticated = false;
const peerEvents = [];

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, databaseVersion);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(stateStore)) {
        database.createObjectStore(stateStore);
      }
      if (!database.objectStoreNames.contains(keyStore)) {
        database.createObjectStore(keyStore);
      }
      if (!database.objectStoreNames.contains(secretStore)) {
        database.createObjectStore(secretStore);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('Unable to open IndexedDB'));
    request.onblocked = () => reject(new Error('IndexedDB upgrade was blocked'));
  });
}

function readRecord(database, storeName, key) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(storeName, 'readonly');
    const request = transaction.objectStore(storeName).get(key);
    request.onsuccess = () => resolve(request.result ?? null);
    request.onerror = () => reject(request.error ?? new Error('Unable to read chat state'));
    transaction.onabort = () => reject(transaction.error ?? new Error('Chat state read aborted'));
  });
}

function writeRecord(database, storeName, key, value) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(storeName, 'readwrite');
    transaction.objectStore(storeName).put(value, key);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error('Unable to write chat state'));
    transaction.onabort = () => reject(transaction.error ?? new Error('Chat state write aborted'));
  });
}

async function wrappingKey(database) {
  const existing = await readRecord(database, keyStore, wrappingKeyName);
  if (existing) return existing;
  const created = await crypto.subtle.generateKey(
    {name: 'AES-GCM', length: 256},
    false,
    ['encrypt', 'decrypt'],
  );
  // Two tabs must not publish different wrapping keys during first use.
  return new Promise((resolve,reject)=>{
    const tx=database.transaction(keyStore,'readwrite'),store=tx.objectStore(keyStore);
    const request=store.get(wrappingKeyName);let selected;
    request.onsuccess=()=>{selected=request.result??created;if(!request.result)store.put(created,wrappingKeyName);};
    tx.oncomplete=()=>resolve(selected);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);
  });
}

async function loadIdentitySecret(database) {
  const encrypted = await readRecord(database, secretStore, identitySecretKey);
  if (!encrypted) return null;
  if (encrypted.version !== 1) {
    throw new Error(`Unsupported encrypted identity version: ${encrypted.version}`);
  }
  const key = await wrappingKey(database);
  const plaintext = await crypto.subtle.decrypt(
    {name: 'AES-GCM', iv: encrypted.iv},
    key,
    encrypted.ciphertext,
  );
  return new Uint8Array(plaintext);
}

async function persistContacts(database) {
  await persistCurrentState();
}

function currentState(){return {chat:core.exportStateJson(),contacts:account.contactsStateJson(),profile:{...activeProfile}};}
async function transactionalAccount(action){
  const generation=identityGeneration,owner=activeId;
  const checkpoint=owner?currentState():null;
  try{return await action();}
  catch(error){
    if(checkpoint&&owner===activeId&&generation===identityGeneration){
      account.restoreContactsState(checkpoint.contacts);core.free();core=new WebChatCore(checkpoint.chat);activeProfile=checkpoint.profile;
    }
    throw error;
  }
}
async function persistCurrentState(){
  const owner=activeId,generation=identityGeneration;
  if(!owner||!account.hasIdentity()||JSON.parse(account.identityJson()).id!==owner)throw Error('Unlock an identity first');
  const state=currentState();
  await identityVault.saveState(owner,state);
  if(activeId!==owner||identityGeneration!==generation)throw Error('Identity changed');
}
function profileAliases(){
  // Optional compatibility aliases cannot make an authenticated activation fail.
  try{
    localStorage.setItem('cht.profile',JSON.stringify(activeProfile));
    localStorage.setItem(profileNameKey,activeProfile.name);
    localStorage.setItem('cht.contact-avatar',activeProfile.contactAvatar??'');
  }catch{}
}
function closeAccountPeer(){
  for(const transport of [dataChannel,peerConnection,localGateway]){
    if(!transport)continue;
    transport.onmessage=null;transport.onclose=null;transport.onerror=null;
    try{transport.close();}catch{}
  }
  dataChannel=null;peerConnection=null;localGateway=null;
  peerInitiator=false;peerPrepared=false;peerAuthenticated=false;peerEvents.length=0;
}
async function activateWebIdentity(secret,expectedId,state,lease=null){
  const next=new AccountCore(secret,state.contacts);
  const publicIdentity=next.identityJson();
  if(JSON.parse(publicIdentity).id!==expectedId){next.free();throw Error('Saved identity secret does not match its identity');}
  let nextCore,nextLease;
  try{nextCore=new WebChatCore(state.chat);nextLease=lease??await acquireAccountLease(expectedId,accountLease);}
  catch(error){next.free();nextCore?.free();throw error;}
  closeAccountPeer();account?.free();core?.free();
  if(accountLease!==nextLease)accountLease?.release();
  accountLease=nextLease;
  identityGeneration++;account=next;core=nextCore;activeId=expectedId;activeProfile={...state.profile};profileAliases();
  return publicIdentity;
}
async function registerWebIdentity(publicIdentity,secret){
  const id=JSON.parse(publicIdentity).id;
  let lease;
  try{
    lease=await acquireAccountLease(id,accountLease);
    const saved=await identityVault.loadState(id);
    const emptyAccount=new AccountCore(secret);
    const emptyChat=new WebChatCore();
    let state;
    try{state=saved??{chat:emptyChat.exportStateJson(),contacts:emptyAccount.contactsStateJson(),profile:{name:'',avatar:''}};}
    finally{emptyAccount.free();emptyChat.free();}
    await identityVault.register(id,secret,state);
    return await activateWebIdentity(secret,id,state,lease);
  }catch(error){if(lease&&lease!==accountLease)lease.release();throw error;}
  finally{secret.fill(0);}
}

function emitPeer(type, details = {}) {
  peerEvents.push({type, atMilliseconds: Date.now(), ...details});
}

function parseSignal(source) {
  const signal = JSON.parse(source);
  if (signal.version !== 1 || !signal.description || !signal.contactCard) {
    throw new Error('Invalid cht manual signaling document');
  }
  return signal;
}

async function signalingRequest(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {'Content-Type': 'application/json', ...(options.headers ?? {})},
    cache: 'no-store',
  });
  const value = await response.json();
  if (response.status === 202) return null;
  if (!response.ok) throw new Error(value.error ?? 'Signaling request failed');
  return value;
}

function createPeerConnection(stunUrl) {
  peerConnection?.close();
  const trimmed = stunUrl.trim();
  peerConnection = new RTCPeerConnection({
    iceServers: trimmed ? [{urls: trimmed}] : [],
  });
  dataChannel = undefined;
  peerPrepared = false;
  peerAuthenticated = false;
  peerConnection.onconnectionstatechange = () => {
    emitPeer('connection', {state: peerConnection.connectionState});
  };
  return peerConnection;
}

function waitForIceGathering(connection) {
  if (connection.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve) => {
    const finish = () => {
      clearTimeout(timeout);
      connection.removeEventListener('icegatheringstatechange', changed);
      resolve();
    };
    const changed = () => {
      if (connection.iceGatheringState === 'complete') {
        finish();
      }
    };
    // Some networks block public STUN. Host candidates are still useful on a
    // local network, so finish with the candidates already gathered instead
    // of preventing the user from creating an invitation.
    const timeout = setTimeout(finish, 8000);
    connection.addEventListener('icegatheringstatechange', changed);
  });
}

function maybeStartNoise() {
  if (!peerInitiator || !peerPrepared || dataChannel?.readyState !== 'open') return;
  sendPeerFrame({type: 'noise', payload: account.startPeerHandshake()});
}

function sendPeerFrame(frame) {
  const encoded = JSON.stringify(frame);
  if (localGateway?.readyState === WebSocket.OPEN) {
    localGateway.send(encoded);
    return;
  }
  if (dataChannel?.readyState === 'open') {
    dataChannel.send(encoded);
    return;
  }
  throw new Error('Peer transport is not open');
}

function handlePeerFrame(source) {
  try {
    const frame = JSON.parse(source);
    if (frame.type === 'noise') {
      const result = JSON.parse(account.receivePeerHandshake(frame.payload));
      if (result.reply) {
        sendPeerFrame({type: 'noise', payload: result.reply});
      }
      if (result.established && !peerAuthenticated) {
        peerAuthenticated = true;
        emitPeer('authenticated');
      }
    } else if (frame.type === 'ciphertext') {
      const message = JSON.parse(account.decryptPeerMessage(frame.payload));
      emitPeer('message', {...message, receivedAtMilliseconds: Date.now()});
    } else if (frame.type === 'ack') {
      emitPeer('delivered', {messageId: frame.messageId,
        receivedAtMilliseconds: Number.isSafeInteger(frame.receivedAtMilliseconds) ? frame.receivedAtMilliseconds : null});
    }
  } catch (error) {
    emitPeer('failed', {reason: String(error)});
  }
}

function attachDataChannel(channel) {
  dataChannel = channel;
  channel.onopen = () => {
    emitPeer('channel', {state: 'open'});
    maybeStartNoise();
  };
  channel.onclose = () => emitPeer('channel', {state: 'closed'});
  channel.onerror = () => emitPeer('failed', {reason: 'DataChannel error'});
  channel.onmessage = (event) => handlePeerFrame(event.data);
}

const ready = (async () => {
  await init();
  const database = await openDatabase();
  identityVault=createIndexedDbIdentityVault(database,()=>wrappingKey(database));
  const persistedState = await readRecord(database, stateStore, chatStateKey);
  core = new WebChatCore(persistedState ?? undefined);
  if (persistedState === null) {
    await writeRecord(database, stateStore, chatStateKey, core.exportStateJson());
  }
  const identitySecret = await loadIdentitySecret(database);
  const contactsState = await readRecord(database, stateStore, contactsStateKey);
  try {
    account = new AccountCore(identitySecret ?? undefined, contactsState ?? undefined);
    if(account.hasIdentity()){
      const id=JSON.parse(account.identityJson()).id;
      const entry=(await identityVault.list()).find(e=>e.identityId===id);
      if(entry?.requiresPin){account.free();account=new AccountCore();core.free();core=new WebChatCore();}
      else{
        const lease=await acquireAccountLease(id,accountLease);
        try{
          // Re-read under the writer lease: another tab may have finished PIN
          // migration while this tab was decrypting the old secret.
          const current=(await identityVault.list()).find(e=>e.identityId===id);
          if(current?.requiresPin){lease.release();account.free();account=new AccountCore();core.free();core=new WebChatCore();}
          else{
            if(!current){
              let profile;try{profile=JSON.parse(localStorage.getItem('cht.profile')??'null');}catch{}
              activeProfile={name:profile?.name??localStorage.getItem(profileNameKey)??'',avatar:profile?.avatar??'',contactAvatar:localStorage.getItem('cht.contact-avatar')??''};
              await identityVault.register(id,identitySecret,{chat:core.exportStateJson(),contacts:account.contactsStateJson(),profile:activeProfile});
            }
            const state=await identityVault.loadState(id);
            await activateWebIdentity(identitySecret,id,state,lease);
          }
        }catch(error){if(lease!==accountLease)lease.release();throw error;}
      }
    }
  } finally {
    identitySecret?.fill(0);
  }
  return database;
})();

function checkAttachmentOwner(ownerId, digest) {
  if (!account.hasIdentity() || JSON.parse(account.identityJson()).id !== ownerId) {
    throw new Error('Unlock this identity before accessing its attachments');
  }
  if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error('Invalid attachment digest');
}

async function attachmentDigest(bytes) {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return Array.from(hash, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

const chunkedPrefix = 'chunked-attachment:v2:';
const chunkedLocks = new Map();
const chunkedIdPattern = /^[A-Za-z0-9_-]{16,96}$/;
const chunkedDigestPattern = /^[0-9a-f]{64}$/;
const chunkedMaxSize = 10 * 1024 * 1024 * 1024;
const chunkedMaxChunkSize = 1024 * 1024;
const chunkedMaxChunks = 100000;
const chunkedEncoder = new TextEncoder();

function checkChunkedOwner(ownerId, id) {
  if (!account.hasIdentity() || JSON.parse(account.identityJson()).id !== ownerId) {
    throw new Error('Unlock this identity before accessing its attachments');
  }
  if (!chunkedIdPattern.test(id)) throw new Error('Invalid attachment id');
}

function chunkedKeys(ownerId, id) {
  const base = `${chunkedPrefix}${ownerId}:${id}:`;
  return {manifest: `${base}manifest`, chunk: (index) => `${base}chunk:${index}`};
}

function chunkedAad(ownerId, id, kind, index, size, chunkSize) {
  return chunkedEncoder.encode(`cht-chunked-v2:${ownerId}:${id}:${kind}:${index}:${size}:${chunkSize}`);
}

function validateChunkedShape(size, chunkSize, digest = null) {
  if (!Number.isSafeInteger(size) || size < 0 || size > chunkedMaxSize ||
      !Number.isSafeInteger(chunkSize) || chunkSize < 1 || chunkSize > chunkedMaxChunkSize ||
      Math.ceil(size / chunkSize) > chunkedMaxChunks ||
      (digest !== null && !chunkedDigestPattern.test(digest))) {
    throw new Error('Invalid attachment metadata');
  }
}

function validateChunkedIndex(manifest, index) {
  const count = Math.ceil(manifest.size / manifest.chunkSize);
  if (!Number.isSafeInteger(index) || index < 0 || index >= count) {
    throw new Error('Attachment chunk index is outside bounds');
  }
  return Math.min(manifest.chunkSize, manifest.size - index * manifest.chunkSize);
}

function chunkedState(manifest) {
  return JSON.stringify({version: 2, id: manifest.id, size: manifest.size,
    chunkSize: manifest.chunkSize, contiguousChunks: manifest.contiguousChunks,
    completed: manifest.completed, digest: manifest.digest});
}

async function encryptChunkedRecord(database, ownerId, id, kind, index, size, chunkSize, plaintext) {
  const key = await wrappingKey(database);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({name: 'AES-GCM', iv,
    additionalData: chunkedAad(ownerId, id, kind, index, size, chunkSize)}, key, plaintext);
  checkChunkedOwner(ownerId, id);
  return {version: 2, iv, ciphertext};
}

async function decryptChunkedRecord(database, ownerId, id, kind, index, size, chunkSize, record) {
  if (record?.version !== 2 || record.iv?.byteLength !== 12 ||
      !record.ciphertext || record.ciphertext.byteLength > chunkedMaxChunkSize + 4096) {
    throw new Error('Attachment cache is damaged');
  }
  const key = await wrappingKey(database);
  const result = new Uint8Array(await crypto.subtle.decrypt({name: 'AES-GCM', iv: record.iv,
    additionalData: chunkedAad(ownerId, id, kind, index, size, chunkSize)}, key, record.ciphertext));
  checkChunkedOwner(ownerId, id);
  return result;
}

async function loadChunkedManifest(database, ownerId, id) {
  checkChunkedOwner(ownerId, id);
  const record = await readRecord(database, secretStore, chunkedKeys(ownerId, id).manifest);
  checkChunkedOwner(ownerId, id);
  if (!record) throw new Error('Attachment cache was not found');
  const plaintext = await decryptChunkedRecord(database, ownerId, id, 'manifest', 0, 0, 0, record);
  let manifest;
  try { manifest = JSON.parse(new TextDecoder().decode(plaintext)); }
  finally { plaintext.fill(0); }
  validateChunkedShape(manifest.size, manifest.chunkSize, manifest.expectedDigest);
  const count = Math.ceil(manifest.size / manifest.chunkSize);
  if (manifest.id !== id || manifest.ownerId !== ownerId ||
      !Number.isSafeInteger(manifest.contiguousChunks) || manifest.contiguousChunks < 0 ||
      manifest.contiguousChunks > count || typeof manifest.completed !== 'boolean' ||
      (manifest.digest !== null && !chunkedDigestPattern.test(manifest.digest)) ||
      (manifest.completed && (manifest.contiguousChunks !== count || !manifest.digest))) {
    throw new Error('Attachment cache is damaged');
  }
  return {manifest, record};
}

function sameChunkedRecord(a, b) {
  if (!a || !b || a.version !== b.version || a.iv?.byteLength !== b.iv?.byteLength ||
      a.ciphertext?.byteLength !== b.ciphertext?.byteLength) return false;
  const aIv = new Uint8Array(a.iv), bIv = new Uint8Array(b.iv);
  const aText = new Uint8Array(a.ciphertext), bText = new Uint8Array(b.ciphertext);
  return aIv.every((byte, index) => byte === bIv[index]) &&
    aText.every((byte, index) => byte === bText[index]);
}

function commitChunkedRecords(database, ownerId, id, expectedManifestRecord, writes, deletes = []) {
  checkChunkedOwner(ownerId, id);
  const manifestKey = chunkedKeys(ownerId, id).manifest;
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(secretStore, 'readwrite');
    const store = transaction.objectStore(secretStore);
    const request = store.get(manifestKey);
    request.onsuccess = () => {
      if (!sameChunkedRecord(request.result, expectedManifestRecord)) {
        transaction.abort();
        return;
      }
      for (const [key, value] of writes) store.put(value, key);
      for (const key of deletes) store.delete(key);
    };
    request.onerror = () => reject(request.error ?? new Error('Attachment cache read failed'));
    transaction.oncomplete = () => resolve();
    transaction.onabort = () => reject(transaction.error ?? new Error('Attachment cache changed during operation'));
    transaction.onerror = () => reject(transaction.error ?? new Error('Attachment cache write failed'));
  });
}

function withChunkedLock(ownerId, id, work) {
  const lockKey = `${ownerId}:${id}`;
  const previous = chunkedLocks.get(lockKey) ?? Promise.resolve();
  const current = previous.catch(() => {}).then(work);
  chunkedLocks.set(lockKey, current);
  void current.finally(() => { if (chunkedLocks.get(lockKey) === current) chunkedLocks.delete(lockKey); }).catch(() => {});
  return current;
}

async function readChunkedBytes(database, ownerId, id, manifest, index) {
  const expectedLength = validateChunkedIndex(manifest, index);
  if (index >= manifest.contiguousChunks) throw new Error('Attachment chunk is not stored');
  const record = await readRecord(database, secretStore, chunkedKeys(ownerId, id).chunk(index));
  checkChunkedOwner(ownerId, id);
  if (!record) throw new Error('Attachment cache is damaged');
  const bytes = await decryptChunkedRecord(database, ownerId, id, 'chunk', index,
    manifest.size, manifest.chunkSize, record);
  if (bytes.byteLength !== expectedLength) throw new Error('Attachment cache is damaged');
  return bytes;
}

async function verifyChunkedProgress(database, ownerId, id, manifest) {
  for (let index = 0; index < manifest.contiguousChunks; index++) {
    const bytes = await readChunkedBytes(database, ownerId, id, manifest, index);
    bytes.fill(0);
    checkChunkedOwner(ownerId, id);
  }
}

const operations = {
  contactRequestCall: async (operation, args) => {
    await ready;
    if (!account.hasIdentity()) throw new Error('Unlock an identity before contact setup');
    return account.contactRequestCall(operation, args);
  },
  groupCall: async (operation, args) => {
    await ready;
    if (!account.hasIdentity()) throw new Error('Unlock an identity before using groups');
    return account.groupCall(operation, args);
  },
  loadGroupBlob: async (ownerId, key) => {
    await ready;
    return loadGroupBlob(ownerId, key, () => account?.hasIdentity() ? JSON.parse(account.identityJson()).id : null);
  },
  saveGroupBlob: async (ownerId, key, value) => {
    await ready;
    return saveGroupBlob(ownerId, key, value, () => account?.hasIdentity() ? JSON.parse(account.identityJson()).id : null);
  },
  deleteGroupBlob: async (ownerId, key) => {
    await ready;
    return deleteGroupBlob(ownerId, key, () => account?.hasIdentity() ? JSON.parse(account.identityJson()).id : null);
  },
  ready,
  beginChunkedAttachment: async (ownerId, id, size, chunkSize, digest = null) =>
    withChunkedLock(ownerId, id, async () => {
      const database = await ready;
      checkChunkedOwner(ownerId, id);
      validateChunkedShape(size, chunkSize, digest);
      const keys = chunkedKeys(ownerId, id);
      const existing = await readRecord(database, secretStore, keys.manifest);
      checkChunkedOwner(ownerId, id);
      if (existing) {
        const {manifest} = await loadChunkedManifest(database, ownerId, id);
        if (manifest.size !== size || manifest.chunkSize !== chunkSize ||
            (digest !== null && manifest.expectedDigest !== null && manifest.expectedDigest !== digest)) {
          throw new Error('Attachment cache metadata conflicts with existing file');
        }
        await verifyChunkedProgress(database, ownerId, id, manifest);
        return chunkedState(manifest);
      }
      const manifest = {id, ownerId, size, chunkSize, contiguousChunks: 0,
        completed: false, digest: null, expectedDigest: digest};
      const encrypted = await encryptChunkedRecord(database, ownerId, id, 'manifest', 0, 0, 0,
        chunkedEncoder.encode(JSON.stringify(manifest)));
      checkChunkedOwner(ownerId, id);
      await new Promise((resolve, reject) => {
        const transaction = database.transaction(secretStore, 'readwrite');
        transaction.objectStore(secretStore).add(encrypted, keys.manifest);
        transaction.oncomplete = resolve;
        transaction.onabort = () => reject(transaction.error ?? new Error('Attachment cache creation failed'));
        transaction.onerror = () => reject(transaction.error ?? new Error('Attachment cache creation failed'));
      });
      checkChunkedOwner(ownerId, id);
      return chunkedState(manifest);
    }),
  chunkedAttachmentStatus: async (ownerId, id) => {
    const database = await ready;
    const {manifest} = await loadChunkedManifest(database, ownerId, id);
    await verifyChunkedProgress(database, ownerId, id, manifest);
    checkChunkedOwner(ownerId, id);
    return chunkedState(manifest);
  },
  writeChunkedAttachment: async (ownerId, id, index, bytes) =>
    withChunkedLock(ownerId, id, async () => {
      const database = await ready;
      const {manifest, record} = await loadChunkedManifest(database, ownerId, id);
      const expectedLength = validateChunkedIndex(manifest, index);
      if (!(bytes instanceof Uint8Array) || bytes.byteLength !== expectedLength ||
          bytes.byteLength > chunkedMaxChunkSize) throw new Error('Invalid attachment chunk length');
      if (index > manifest.contiguousChunks) throw new Error('Attachment chunks must be written in order');
      if (index < manifest.contiguousChunks) {
        const existing = await readChunkedBytes(database, ownerId, id, manifest, index);
        const identical = existing.every((byte, offset) => byte === bytes[offset]);
        existing.fill(0);
        checkChunkedOwner(ownerId, id);
        if (!identical) throw new Error('Attachment chunk retry conflicts with stored data');
        return;
      }
      if (manifest.completed) throw new Error('Attachment is already complete');
      const chunkRecord = await encryptChunkedRecord(database, ownerId, id, 'chunk', index,
        manifest.size, manifest.chunkSize, bytes);
      const updated = {...manifest, contiguousChunks: index + 1};
      const nextManifestRecord = await encryptChunkedRecord(database, ownerId, id, 'manifest', 0, 0, 0,
        chunkedEncoder.encode(JSON.stringify(updated)));
      const keys = chunkedKeys(ownerId, id);
      checkChunkedOwner(ownerId, id);
      await commitChunkedRecords(database, ownerId, id, record,
        [[keys.chunk(index), chunkRecord], [keys.manifest, nextManifestRecord]]);
      checkChunkedOwner(ownerId, id);
    }),
  readChunkedAttachment: async (ownerId, id, index) => {
    const database = await ready;
    const {manifest} = await loadChunkedManifest(database, ownerId, id);
    const bytes = await readChunkedBytes(database, ownerId, id, manifest, index);
    checkChunkedOwner(ownerId, id);
    return bytes;
  },
  finishChunkedAttachment: async (ownerId, id, expectedDigest) =>
    withChunkedLock(ownerId, id, async () => {
      const database = await ready;
      const {manifest, record} = await loadChunkedManifest(database, ownerId, id);
      if (typeof expectedDigest !== 'string' || !chunkedDigestPattern.test(expectedDigest) ||
          (manifest.expectedDigest !== null && manifest.expectedDigest !== expectedDigest)) {
        throw new Error('Attachment digest does not match expected metadata');
      }
      if (manifest.contiguousChunks !== Math.ceil(manifest.size / manifest.chunkSize)) {
        throw new Error('Attachment is missing chunks');
      }
      if (manifest.completed) {
        if (manifest.digest !== expectedDigest) throw new Error('Attachment digest conflicts with stored file');
        return chunkedState(manifest);
      }
      const updated = {...manifest, completed: true, digest: expectedDigest};
      const encrypted = await encryptChunkedRecord(database, ownerId, id, 'manifest', 0, 0, 0,
        chunkedEncoder.encode(JSON.stringify(updated)));
      checkChunkedOwner(ownerId, id);
      await commitChunkedRecords(database, ownerId, id, record,
        [[chunkedKeys(ownerId, id).manifest, encrypted]]);
      checkChunkedOwner(ownerId, id);
      return chunkedState(updated);
    }),
  deleteChunkedAttachment: async (ownerId, id) =>
    withChunkedLock(ownerId, id, async () => {
      const database = await ready;
      checkChunkedOwner(ownerId, id);
      const prefix = `${chunkedPrefix}${ownerId}:${id}:`;
      await new Promise((resolve, reject) => {
        const transaction = database.transaction(secretStore, 'readwrite');
        const request = transaction.objectStore(secretStore).openCursor(
          IDBKeyRange.bound(prefix, `${prefix}\uffff`));
        let count = 0;
        request.onsuccess = () => {
          const cursor = request.result;
          if (!cursor) return;
          if (++count > chunkedMaxChunks + 1) {
            transaction.abort();
            return;
          }
          cursor.delete();
          cursor.continue();
        };
        transaction.oncomplete = resolve;
        transaction.onabort = () => reject(transaction.error ?? new Error('Attachment cache delete failed'));
        transaction.onerror = () => reject(transaction.error ?? new Error('Attachment cache delete failed'));
      });
      checkChunkedOwner(ownerId, id);
    }),
  savePeerAttachment: async (ownerId, digest, data) => {
    const database = await ready;
    checkAttachmentOwner(ownerId, digest);
    if (typeof data !== 'string' || data.length > Math.ceil(100 * 1024 * 1024 / 3) * 4) throw new Error('Attachment is too large');
    const bytes = Uint8Array.from(atob(data), (character) => character.charCodeAt(0));
    try {
      if (bytes.length > 100 * 1024 * 1024 || await attachmentDigest(bytes) !== digest) throw new Error('Invalid attachment content');
      const key = await wrappingKey(database);
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const ciphertext = await crypto.subtle.encrypt(
        {name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(`cht-attachment-v1:${ownerId}:${digest}`)}, key, bytes,
      );
      checkAttachmentOwner(ownerId, digest);
      await writeRecord(database, secretStore, `peer-attachment:${ownerId}:${digest}`, {iv, ciphertext});
      checkAttachmentOwner(ownerId, digest);
    } finally { bytes.fill(0); }
  },
  loadPeerAttachment: async (ownerId, digest) => {
    const database = await ready;
    checkAttachmentOwner(ownerId, digest);
    const encrypted = await readRecord(database, secretStore, `peer-attachment:${ownerId}:${digest}`);
    checkAttachmentOwner(ownerId, digest);
    if (!encrypted) return null;
    if (encrypted.ciphertext?.byteLength > 100 * 1024 * 1024 + 16) throw new Error('Invalid attachment cache');
    const key = await wrappingKey(database);
    const bytes = new Uint8Array(await crypto.subtle.decrypt(
      {name: 'AES-GCM', iv: encrypted.iv, additionalData: new TextEncoder().encode(`cht-attachment-v1:${ownerId}:${digest}`)}, key, encrypted.ciphertext,
    ));
    try {
      if (await attachmentDigest(bytes) !== digest) throw new Error('Attachment cache is damaged');
      checkAttachmentOwner(ownerId, digest);
      let binary = '';
      for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
      return btoa(binary);
    } finally { bytes.fill(0); }
  },
  loadPeerHistory: async (ownerId) => {
    const database = await ready;
    const encrypted = await readRecord(database, secretStore, `peer-history:${ownerId}`);
    if (!encrypted) return '';
    const key = await wrappingKey(database);
    const plaintext = await crypto.subtle.decrypt(
      {name: 'AES-GCM', iv: encrypted.iv, additionalData: new TextEncoder().encode(ownerId)},
      key,
      encrypted.ciphertext,
    );
    return new TextDecoder().decode(plaintext);
  },
  savePeerHistory: async (ownerId, source) => {
    const database = await ready;
    const key = await wrappingKey(database);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt(
      {name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(ownerId)},
      key,
      new TextEncoder().encode(source),
    );
    await writeRecord(database, secretStore, `peer-history:${ownerId}`, {iv, ciphertext});
  },
  version: async () => {
    await ready;
    return core_version();
  },
  snapshot: async () => {
    await ready;
    return core.snapshotJson();
  },
  deleteConversation: async (conversationId) => {
    const database = await ready;
    const generation=identityGeneration;
    const previousState = core.exportStateJson();
    const snapshot = core.deleteConversation(conversationId);
    try {
      await persistCurrentState();
      return snapshot;
    } catch (error) {
      if(generation===identityGeneration){core.free();core = new WebChatCore(previousState);}
      throw error;
    }
  },
  sendText: async (conversationId, text, sentAtMilliseconds) => {
    const database = await ready;
    const generation=identityGeneration;
    const previousState = core.exportStateJson();
    const snapshot = core.sendText(conversationId, text, sentAtMilliseconds);
    try {
      await persistCurrentState();
      return snapshot;
    } catch (error) {
      if(generation===identityGeneration){core.free();core = new WebChatCore(previousState);}
      throw error;
    }
  },
  hasIdentity: async () => {
    await ready;
    return account.hasIdentity();
  },
  createIdentity: async () => {
    await ready;
    return account.createIdentityJson();
  },
  discardPendingIdentity: async () => {
    await ready;
    account.discardPendingIdentity();
  },
  confirmRecovery: async (phrase) => {
    const database = await ready;
    const secret = account.confirmRecovery(phrase);
    return registerWebIdentity(account.identityJson(),secret);
  },
  restoreIdentity: async (phrase) => {
    const database = await ready;
    const [identityJson, secret] = account.restoreIdentityJson(phrase);
    return registerWebIdentity(identityJson,secret);
  },
  savedIdentities: async()=>{await ready;return JSON.stringify(await identityVault.list());},
  rememberIdentity: async(pin,displayName,avatar,contactAvatar='')=>{
    const database=await ready;
    if(!activeId)throw Error('Restore or create an identity first');
    const name=displayName.trim();
    if(!name||[...name].length>64||avatar.length>400000||typeof contactAvatar!=='string'||contactAvatar.length>1400)throw Error('Invalid profile');
    const previous=activeProfile;activeProfile={name,avatar,contactAvatar};
    try{await persistCurrentState();await identityVault.remember(activeId,pin);profileAliases();return account.identityJson();}
    catch(error){activeProfile=previous;throw error;}
  },
  unlockIdentity: async(id,pin)=>{
    await ready;
    const lease=await acquireAccountLease(id,accountLease);
    let secret;
    try{secret=await identityVault.unlock(id,pin);const state=await identityVault.loadState(id);if(!state)throw Error('Saved account data is missing');return await activateWebIdentity(secret,id,state,lease);}
    catch(error){if(lease!==accountLease)lease.release();throw error;}
    finally{secret?.fill(0);}
  },
  lockIdentity: async()=>{
    const database=await ready;
    if(activeId)await persistCurrentState();
    await writeRecord(database,secretStore,identitySecretKey,null);
    closeAccountPeer();account.free();core.free();account=new AccountCore();core=new WebChatCore();
    accountLease?.release();accountLease=null;
    identityGeneration++;activeId=null;activeProfile={name:'',avatar:''};profileAliases();
  },
  loadDesktopProfile: async()=>{await ready;return JSON.stringify(activeProfile);},
  saveDesktopProfile: async(source)=>{
    await ready;const value=JSON.parse(source),previous=activeProfile;
    if(typeof value.name!=='string'||[...value.name].length>64||typeof value.avatar!=='string'||value.avatar.length>400000||typeof (value.contactAvatar??'')!=='string'||(value.contactAvatar??'').length>1400)throw Error('Invalid profile');
    activeProfile={name:value.name,avatar:value.avatar,contactAvatar:value.contactAvatar??''};
    try{await persistCurrentState();profileAliases();}catch(error){activeProfile=previous;throw error;}
  },
  identity: async () => {
    await ready;
    return account.identityJson();
  },
  contactCard: async (displayName = '', avatar = '') => {
    await ready;
    return account.contactCardJsonWithProfile(displayName, avatar);
  },
  contactCardWithRelays: async (displayName, avatar, relayUrls) => {
    await ready;
    return account.contactCardJsonWithRelays(displayName, avatar, relayUrls);
  },
  relayProof: async (nonce, relayId) => {
    await ready;
    return account.relayProof(nonce, relayId);
  },
  signSeedSignal: async (peerId, messageId, text, now) => {
    await ready;
    return account.signSeedSignal(peerId, messageId, text, now);
  },
  inspectSeedSignal: async (source, expectedPeer, now) => {
    await ready;
    return account.inspectSeedSignal(source, expectedPeer, now);
  },
  inspectRelayRecord: async (source, now, allowLoopback) => {
    await ready;
    return account.inspectRelayRecord(source, now, allowLoopback);
  },
  loadRelayState: async () => localStorage.getItem('cht.relay-directory') ?? '',
  saveRelayState: async (source) => {
    if (source.length > 8388608) throw new Error('Relay cache is too large');
    localStorage.setItem('cht.relay-directory', source);
  },
  profileName: async () => {await ready;return activeProfile.name;},
  setProfileName: async (name) => {
    const value = name.trim();
    if (!value || [...value].length > 64) throw new Error('Name must contain 1 to 64 characters');
    await ready;const previous=activeProfile;activeProfile={...activeProfile,name:value};
    try{await persistCurrentState();profileAliases();}catch(error){activeProfile=previous;throw error;}
  },
  contacts: async () => {
    await ready;
    return account.contactsJson();
  },
  inspectContactCard: async (cardJson) => {
    await ready;
    return account.inspectContactCardJson(cardJson);
  },
  addContact: async (cardJson, displayName) => {
    const database = await ready;
    const contacts = account.addContact(cardJson, displayName);
    await persistContacts(database);
    return contacts;
  },
  markContactVerified: async (identityId) => {
    const database = await ready;
    const contacts = account.markContactVerified(identityId);
    await persistContacts(database);
    return contacts;
  },
  setContactAlias: async (identityId, alias) => {
    const database = await ready;
    const contacts = account.setContactAlias(identityId, alias);
    await persistContacts(database);
    return contacts;
  },
  removeContact: async (identityId) => {
    const database = await ready;
    const contacts = account.removeContact(identityId);
    await persistContacts(database);
    return contacts;
  },
  preparePeer: async (cardJson, initiator) => {
    const database = await ready;
    const identityId = account.preparePeer(cardJson, initiator);
    await persistContacts(database);
    return identityId;
  },
  startPeerHandshake: async () => {
    await ready;
    return account.startPeerHandshake();
  },
  receivePeerHandshake: async (frame) => {
    await ready;
    return account.receivePeerHandshake(frame);
  },
  encryptPeerMessage: async (messageId, text, sentAtMilliseconds = null) => {
    await ready;
    return sentAtMilliseconds == null ? account.encryptPeerMessage(messageId, text)
      : account.encryptPeerMessageAt(messageId, text, sentAtMilliseconds);
  },
  decryptPeerMessage: async (frame) => {
    await ready;
    return account.decryptPeerMessage(frame);
  },
  createPeerOffer: async (stunUrl, displayName) => {
    await ready;
    peerInitiator = true;
    const connection = createPeerConnection(stunUrl);
    attachDataChannel(connection.createDataChannel('cht-messages', {ordered: true}));
    await connection.setLocalDescription(await connection.createOffer());
    await waitForIceGathering(connection);
    return JSON.stringify({
      version: 1,
      description: connection.localDescription.toJSON(),
      contactCard: account.contactCardJsonWithProfile(displayName, activeProfile.contactAvatar ?? ''),
    });
  },
  connectLocalDesktop: async (targetIdentityId, displayName) => {
    await ready;
    dataChannel?.close();
    peerConnection?.close();
    localGateway?.close();
    peerInitiator = true;
    peerPrepared = false;
    peerAuthenticated = false;
    return new Promise((resolve, reject) => {
      const socket = new WebSocket('ws://127.0.0.1:17357');
      let readyForFrames = false;
      const timeout = setTimeout(() => {
        socket.close();
        reject(new Error('Local Desktop node was not found'));
      }, 1800);
      socket.onerror = () => {
        clearTimeout(timeout);
        if (!readyForFrames) reject(new Error('Local Desktop node was not found'));
      };
      socket.onclose = () => {
        if (localGateway !== socket) return;
        localGateway = undefined;
        peerAuthenticated = false;
        peerPrepared = false;
        emitPeer('connection', {state: 'closed'});
      };
      const generation=identityGeneration;
      socket.onmessage = async (event) => {
        if(generation!==identityGeneration){socket.close();return;}
        if (readyForFrames) {
          handlePeerFrame(event.data);
          return;
        }
        try {
          const hello = JSON.parse(event.data);
          if (hello.type !== 'desktopHello' || typeof hello.contactCard !== 'string') {
            throw new Error('Invalid Desktop hello');
          }
          const identityId = await accountMutations.run(()=>transactionalAccount(async()=>{
            if(generation!==identityGeneration)throw Error('Identity changed');
            const id=account.preparePeer(hello.contactCard,true);
            if(id!==targetIdentityId)throw Error('The local Desktop node is not the selected friend');
            await persistContacts(await ready);return id;
          }));
          if(generation!==identityGeneration){socket.close();return;}
          localGateway = socket;
          peerPrepared = true;
          readyForFrames = true;
          socket.send(JSON.stringify({
            type: 'browserHello',
            targetIdentityId,
            contactCard: account.contactCardJsonWithProfile(displayName, activeProfile.contactAvatar ?? ''),
          }));
          sendPeerFrame({type: 'noise', payload: account.startPeerHandshake()});
          clearTimeout(timeout);
          emitPeer('connection', {state: 'connected'});
          resolve();
        } catch (error) {
          clearTimeout(timeout);
          socket.close();
          reject(error);
        }
      };
    });
  },
  acceptPeerOffer: async (source, stunUrl, displayName) => {
    await ready;
    const signal = parseSignal(source);
    account.preparePeer(signal.contactCard, false);
    await persistContacts(await ready);
    peerPrepared = true;
    peerInitiator = false;
    const connection = createPeerConnection(stunUrl);
    peerPrepared = true;
    connection.ondatachannel = (event) => attachDataChannel(event.channel);
    await connection.setRemoteDescription(signal.description);
    await connection.setLocalDescription(await connection.createAnswer());
    await waitForIceGathering(connection);
    return JSON.stringify({
      version: 1,
      description: connection.localDescription.toJSON(),
      contactCard: account.contactCardJsonWithProfile(displayName, activeProfile.contactAvatar ?? ''),
    });
  },
  acceptPeerAnswer: async (source) => {
    await ready;
    if (!peerConnection || !peerInitiator) throw new Error('Create an offer first');
    const signal = parseSignal(source);
    account.preparePeer(signal.contactCard, true);
    await persistContacts(await ready);
    peerPrepared = true;
    await peerConnection.setRemoteDescription(signal.description);
    maybeStartNoise();
  },
  createPeerRoom: async (offer) => {
    const value = await signalingRequest('/api/rooms', {
      method: 'POST',
      body: JSON.stringify({offer}),
    });
    return value.code;
  },
  loadPeerRoomOffer: async (code) => {
    const value = await signalingRequest(`/api/rooms/${encodeURIComponent(code)}/offer`);
    return value.offer;
  },
  publishPeerRoomAnswer: async (code, answer) => {
    await signalingRequest(`/api/rooms/${encodeURIComponent(code)}/answer`, {
      method: 'POST',
      body: JSON.stringify({answer}),
    });
  },
  loadPeerRoomAnswer: async (code) => {
    const value = await signalingRequest(`/api/rooms/${encodeURIComponent(code)}/answer`);
    return value?.answer ?? '';
  },
  peerStatus: async () => {
    await ready;
    return JSON.stringify({
      connectionState: localGateway?.readyState === WebSocket.OPEN
        ? 'connected'
        : peerConnection?.connectionState ?? 'new',
      channelState: localGateway?.readyState === WebSocket.OPEN
        ? 'open'
        : dataChannel?.readyState ?? 'closed',
      authenticated: peerAuthenticated,
    });
  },
  sendPeerMessage: async (messageId, text, sentAtMilliseconds = Date.now()) => {
    await ready;
    const transportOpen = localGateway?.readyState === WebSocket.OPEN || dataChannel?.readyState === 'open';
    if (!peerAuthenticated || !transportOpen) {
      throw new Error('Peer channel is not authenticated');
    }
    const payload = account.encryptPeerMessageAt(messageId, text, sentAtMilliseconds ?? Date.now());
    sendPeerFrame({type: 'ciphertext', payload});
    emitPeer('sent', {messageId});
  },
  acknowledgePeerMessage: async (messageId, receivedAtMilliseconds) => {
    await ready;
    sendPeerFrame({type: 'ack', messageId, receivedAtMilliseconds});
  },
  drainPeerEvents: async () => {
    await ready;
    return JSON.stringify(peerEvents.splice(0));
  },
  closePeer: async () => {
    dataChannel?.close();
    peerConnection?.close();
    localGateway?.close();
    localGateway = undefined;
    peerAuthenticated = false;
    peerPrepared = false;
    emitPeer('connection', {state: 'closed'});
  },
};

const serializedOperations=new Set(['savedIdentities','hasIdentity','identity','snapshot','contacts','loadDesktopProfile','profileName',
  'createIdentity','discardPendingIdentity','confirmRecovery','restoreIdentity','rememberIdentity','unlockIdentity','lockIdentity',
  'deleteConversation','sendText','setProfileName','saveDesktopProfile','addContact','markContactVerified','setContactAlias','removeContact','preparePeer',
  'createPeerOffer','acceptPeerOffer','acceptPeerAnswer','groupCall','contactRequestCall','startPeerHandshake','receivePeerHandshake','encryptPeerMessage','decryptPeerMessage','relayProof','contactCard','contactCardWithRelays']);
const transactionalOperations=new Set(['deleteConversation','sendText','addContact','markContactVerified','setContactAlias','removeContact','preparePeer','setProfileName','saveDesktopProfile','acceptPeerOffer','acceptPeerAnswer']);
const unscopedOperations=new Set(['savedIdentities','hasIdentity','identity','snapshot','contacts','loadDesktopProfile','profileName']);
globalThis.chtCore=Object.freeze(Object.fromEntries(Object.entries(operations).map(([name,operation])=>[name,
  serializedOperations.has(name)?(...args)=>{
    const requestedGeneration=identityGeneration;
    return accountMutations.run(async()=>{
      await ready;
      if(!unscopedOperations.has(name)&&requestedGeneration!==identityGeneration)throw Error('Identity changed');
      return transactionalOperations.has(name)?transactionalAccount(()=>operation(...args)):operation(...args);
    });
  }:operation
])));
