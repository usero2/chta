import {test} from 'node:test';
import assert from 'node:assert/strict';
import {advertisement} from './helpers.js';
import {verifyCourierAdvertisement} from '../src/courier-discovery.js';
test('Courier advertisements bind root certificate, device key, public routes and strict metadata only',async()=>{
  const c=advertisement();assert.deepEqual(await verifyCourierAdvertisement(c,Date.now()),c);
  for(const edit of [c=>c.certificate.ownerId=`did:cht:${'0'.repeat(64)}`,c=>c.body.freeBytes++,c=>c.body.routes=['wss://127.0.0.1/cht'],c=>c.body.filename='secret',c=>c.ciphertext='payload',c=>c.challenge='B'.repeat(43)]){
    const bad=structuredClone(c);edit(bad);await assert.rejects(verifyCourierAdvertisement(bad,Date.now()));
  }
});
