const databaseName = 'cht-group-blobs-v1';
const ownerPattern = /^did:cht:[0-9a-f]{64}$/;
const keyPattern = /^[A-Za-z0-9_-]{1,128}$/;
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', {fatal: true});
const maxBytes = 8 * 1024 * 1024;

function check(ownerId, key, currentOwner) {
  if (!ownerPattern.test(ownerId) || !keyPattern.test(key) ||
      typeof currentOwner !== 'function' || currentOwner() !== ownerId) {
    throw new Error('Group blob owner or key is invalid');
  }
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      db.createObjectStore('keys');
      db.createObjectStore('blobs');
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () => reject(new Error('Group blob database is blocked'));
  });
}

function read(db, store, key) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, 'readonly');
    const request = tx.objectStore(store).get(key);
    request.onsuccess = () => resolve(request.result ?? null);
    request.onerror = () => reject(request.error);
    tx.onabort = () => reject(tx.error);
  });
}

function write(db, store, key, value, remove = false) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, 'readwrite');
    if (remove) tx.objectStore(store).delete(key);
    else tx.objectStore(store).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

async function wrappingKey(db) {
  const existing = await read(db, 'keys', 'group-key');
  if (existing) return existing;
  const generated = await crypto.subtle.generateKey(
    {name: 'AES-GCM', length: 256}, false, ['encrypt', 'decrypt']);
  await write(db, 'keys', 'group-key', generated);
  return generated;
}

async function recordKey(ownerId, key) {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(`${ownerId}\0${key}`)));
  return Array.from(hash, value => value.toString(16).padStart(2, '0')).join('');
}

function aad(ownerId, key) {
  return encoder.encode(`cht-group-blob-v1\0${ownerId}\0${key}`);
}

export async function loadGroupBlob(ownerId, key, currentOwner) {
  check(ownerId, key, currentOwner);
  const db = await openDatabase();
  try {
    const id = await recordKey(ownerId, key);
    check(ownerId, key, currentOwner);
    const record = await read(db, 'blobs', id);
    check(ownerId, key, currentOwner);
    if (!record) return null;
    if (record.version !== 1 || record.iv?.byteLength !== 12 ||
        !record.ciphertext || record.ciphertext.byteLength > maxBytes + 4096) {
      throw new Error('Group blob is damaged');
    }
    const secret = await wrappingKey(db);
    const plain = await crypto.subtle.decrypt(
      {name: 'AES-GCM', iv: record.iv, additionalData: aad(ownerId, key)},
      secret, record.ciphertext);
    check(ownerId, key, currentOwner);
    if (plain.byteLength > maxBytes) throw new Error('Group blob is too large');
    return decoder.decode(plain);
  } finally { db.close(); }
}

export async function saveGroupBlob(ownerId, key, value, currentOwner) {
  check(ownerId, key, currentOwner);
  if (typeof value !== 'string') throw new Error('Invalid group blob');
  const plain = encoder.encode(value);
  if (plain.byteLength > maxBytes) throw new Error('Group blob is too large');
  const db = await openDatabase();
  try {
    const id = await recordKey(ownerId, key);
    const secret = await wrappingKey(db);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt(
      {name: 'AES-GCM', iv, additionalData: aad(ownerId, key)}, secret, plain);
    check(ownerId, key, currentOwner);
    await write(db, 'blobs', id, {version: 1, iv, ciphertext});
  } finally { db.close(); }
}

export async function deleteGroupBlob(ownerId, key, currentOwner) {
  check(ownerId, key, currentOwner);
  const db = await openDatabase();
  try {
    const id = await recordKey(ownerId, key);
    check(ownerId, key, currentOwner);
    await write(db, 'blobs', id, null, true);
  } finally { db.close(); }
}
