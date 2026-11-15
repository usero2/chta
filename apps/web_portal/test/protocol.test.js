import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { SEED_ID, verifyProof, verifySignal, verifyRecord, publicEndpoint } from '../src/protocol.js';
import { identity, now, proof, signal, groupSignal, record, sdp } from './helpers.js';
const alice = identity(), bob = identity();
const did = `did:cht:${bob.id}`;
test('seed ID and registration use the existing Rust relay authentication domain', async () => {
  assert.equal(SEED_ID, createHash('sha256').update('chta.app/relay/v1').digest('hex'));
  const nonce = Buffer.alloc(32, 5).toString('base64url');
  const p = proof(alice, nonce, SEED_ID);
  assert.equal(await verifyProof(p, nonce), `did:cht:${alice.id}`);
  for (const bad of [{...p, identityId: did}, {...p, extra: true}, {...p, signature: p.signature.slice(1)}, {...p, publicKey: bob.publicKey}]) await assert.rejects(verifyProof(bad, nonce));
  await assert.rejects(verifyProof(p, Buffer.alloc(32, 6).toString('base64url')));
});
test('valid signed offer and strict timestamp, schema, endpoint, identity and signature binding', async () => {
  const value = signal(alice, did);
  assert.deepEqual(await verifySignal(value, value.from, now), value);
  for (const change of [{to:[did]},{to: value.from},{from: did},{version:2},{session:'A'.repeat(32)},{id:value.id+'x'},{issuedAt:now+30001},{issuedAt:now-1},{expiresAt:now},{expiresAt:now+120001},{expiresAt:1.5},{extra:1},{signature:value.signature.slice(1)},{publicKey:bob.publicKey}]) {
    const changed = 'signature' in change ? {...value,...change} : signal(alice, did, change);
    await assert.rejects(verifySignal(changed, value.from, now), JSON.stringify(change));
  }
  await assert.rejects(verifySignal({...value,to:`did:cht:${identity().id}`}, value.from, now));
  await assert.rejects(verifySignal(value, did, now));
});
test('only original bounded SDP/ICE payloads are accepted, never chat or file carriers', async () => {
  const base = signal(alice,did), session = base.session;
  for(const d of [sdp('offer')+'a=fingerprint:sha-256 invalid\r\n',sdp('offer')+'\0',sdp('offer')+'a=candidate:invalid\r\n'])await assert.rejects(verifySignal(signal(alice,did,{payload:JSON.stringify({v:1,t:'offer',s:session,d})}),base.from,now));
  for (const p of [{v:1,t:'offer',s:session,d:sdp('offer'),body:'message'},{v:1,t:'offer',s:session,d:'x'.repeat(11001)},{v:1,t:'offer',s:session,d:sdp('answer')},{v:1,t:'offer',s:session,d:sdp('offer')+'a=candidate:x 1 udp 1 1.2.3.4 123 typ relay\r\n'},{v:1,t:'offer',s:session,d:sdp('offer').replace('sha-256','sha-1')},{v:1,t:'message',s:session,d:'secret'},{v:1,t:'offer',s:'b'.repeat(32),d:sdp('offer')}]) await assert.rejects(verifySignal(signal(alice,did,{payload:JSON.stringify(p)}),base.from,now));
  const ice = {v:1,t:'ice',s:session,c:'candidate:a 1 udp 2122260223 203.0.113.1 50000 typ host',m:null,l:0};
  const changes = {kind:'ice',id:`cht-control-direct-v1-${session}-ice-2`};
  assert.ok(await verifySignal(signal(alice,did,{...changes,payload:JSON.stringify(ice)}),base.from,now));
  for(const p of [{...ice,c:ice.c.replace('typ host','typ relay')},{...ice,l:-1},{...ice,l:65536},{...ice,m:'x'.repeat(65)},{...ice,c:'opaque-encrypted-blob'},{...ice,filename:'secret'},{...ice,c:'candidate:a 1 udp 1 x 0 typ host'}]) await assert.rejects(verifySignal(signal(alice,did,{...changes,payload:JSON.stringify(p)}),base.from,now));
  await assert.rejects(verifySignal(signal(alice,did,{payload:' '.repeat(11265)}),base.from,now));
});
test('relay hints verify canonical signatures, TTL, public /cht URLs and reject SSRF targets without fetching', async () => {
  const good = record(alice);
  assert.deepEqual(await verifyRecord(good, now),good);
  for (const change of [{endpoint:'wss://example.com/relay'},{endpoint:'ws://example.com/cht'},{endpoint:'wss://127.0.0.1/cht'},{endpoint:'wss://10.1.2.3/cht'},{endpoint:'wss://100.64.0.1/cht'},{endpoint:'wss://[::ffff:8.8.8.8]/cht'},{endpoint:'wss://[::1]/cht'},{endpoint:'wss://[fc00::1]/cht'},{endpoint:'wss://localhost./cht'},{endpoint:'wss://example.local/cht'},{endpoint:'wss://user:pass@example.com/cht'},{endpoint:'wss://example.com/cht?q=1'},{endpoint:'wss://example.com/cht#x'},{expiresAt:now},{expiresAt:now+3600001},{issuedAt:now+60001},{extra:'x'},{relayId:bob.id}]) await assert.rejects(verifyRecord(record(alice,change),now),JSON.stringify(change));
  await assert.rejects(verifyRecord({...good, endpoint:'wss://other.example.com/cht'},now));
  for(const endpoint of ['wss://8.8.8.8/cht','wss://[2606:4700:4700::1111]/cht']) assert.equal(publicEndpoint(endpoint),true);
});
test('Rust deterministic shared signal fixture agrees with JavaScript canonical verification', async () => {
  const fixture = JSON.parse(await readFile(new URL('./fixtures/seed-signal.json',import.meta.url),'utf8'));
  assert.equal('chta seed signal v1\0'+JSON.stringify(['version','from','to','session','id','kind','payload','issuedAt','expiresAt'].map(k=>fixture.envelope[k])),fixture.canonical);
  assert.deepEqual(await verifySignal(fixture.envelope, fixture.envelope.from, fixture.now),fixture.envelope);
});
test('group v2 signals use a distinct signed topic and never enter v1', async () => {
  const value = groupSignal(alice, did);
  assert.deepEqual(await verifySignal(value, value.from, now), value);
  await assert.rejects(verifySignal({...value, version: 1}, value.from, now));
  await assert.rejects(verifySignal({...value, topic: 'direct'}, value.from, now));
  await assert.rejects(verifySignal({...value, id: signal(alice,did).id}, value.from, now));
  await assert.rejects(verifySignal({...signal(alice,did), topic: 'groups'}, value.from, now));
});
test('group v2 accepts SDP and ICE only with exact schema and signature', async () => {
  const base = groupSignal(alice, did), session = base.session;
  const ice = {v:1,t:'ice',s:session,c:'candidate:a 1 udp 2122260223 203.0.113.1 50000 typ host',m:null,l:0};
  const good = groupSignal(alice,did,{kind:'ice',id:`cht-control-groups-v1-${session}-ice-2`,payload:JSON.stringify(ice)});
  assert.deepEqual(await verifySignal(good,good.from,now),good);
  for (const change of [{payload:JSON.stringify({...ice,filename:'secret'})},{payload:JSON.stringify({...ice,c:'candidate:a 1 udp 1 1.2.3.4 123 typ relay'})},{payload:JSON.stringify({v:1,t:'message',s:session,text:'secret'})},{kind:'message'},{extra:1},{signature:base.signature.slice(1)}]) {
    const candidate = 'signature' in change ? {...base,...change} : groupSignal(alice,did,change);
    await assert.rejects(verifySignal(candidate,base.from,now),JSON.stringify(change));
  }
});
