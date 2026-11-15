import { createHash, generateKeyPairSync, sign } from 'node:crypto';
export const now = 1800000000000;
export const identity = () => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  return { privateKey, publicKey: raw.toString('base64url'), id: createHash('sha256').update(raw).digest('hex') };
};
export const signed = (key, domain, tuple) => sign(null, Buffer.from(domain + JSON.stringify(tuple)), key.privateKey).toString('base64url');
export function proof(key, nonce, seedId) {
  return { identityId: `did:cht:${key.id}`, publicKey: key.publicKey, signature: sign(null, Buffer.from(`cht relay registration v1\0${seedId}\0${nonce}`), key.privateKey).toString('base64url') };
}
export const sdp = kind => `v=0\r\na=fingerprint:sha-256 ${Array(32).fill('AB').join(':')}\r\na=setup:${kind === 'offer' ? 'actpass' : 'active'}\r\n`;
export function signal(key, to, changes = {}) {
  const session = '0123456789abcdef0123456789abcdef';
  const value = { version: 1, from: `did:cht:${key.id}`, to, session, id: `cht-control-direct-v1-${session}-offer-1`, kind: 'offer', payload: JSON.stringify({ v: 1, t: 'offer', s: session, d: sdp('offer') }), issuedAt: now, expiresAt: now + 120000, publicKey: key.publicKey, ...changes };
  value.signature = signed(key, 'chta seed signal v1\0', ['version','from','to','session','id','kind','payload','issuedAt','expiresAt'].map(k => value[k]));
  return value;
}
export function groupSignal(key, to, changes = {}) {
  const session = '0123456789abcdef0123456789abcdef';
  const value = { version: 2, topic: 'groups', from: `did:cht:${key.id}`, to, session, id: `cht-control-groups-v1-${session}-offer-1`, kind: 'offer', payload: JSON.stringify({ v: 1, t: 'offer', s: session, d: sdp('offer') }), issuedAt: now, expiresAt: now + 120000, publicKey: key.publicKey, ...changes };
  value.signature = signed(key, 'chta group seed signal v1\0', ['version','topic','from','to','session','id','kind','payload','issuedAt','expiresAt'].map(k => value[k]));
  return value;
}
export function record(key, changes = {}) {
  const value = { version: 1, relayId: key.id, publicKey: key.publicKey, endpoint: 'wss://relay.example.com/cht', issuedAt: now, expiresAt: now + 900000, ...changes };
  value.signature = signed(key, 'cht relay directory v1\0', ['version','relayId','publicKey','endpoint','issuedAt','expiresAt'].map(k => value[k]));
  return value;
}
