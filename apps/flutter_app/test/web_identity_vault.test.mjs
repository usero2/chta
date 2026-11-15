import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto} from 'node:crypto';
import {WebIdentityVault} from '../web/web_identity_vault.js';

globalThis.crypto ??= webcrypto;
const alice='did:cht:'+'a'.repeat(64), bob='did:cht:'+'b'.repeat(64);
async function storage(){
  const records=new Map();
  const key=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
  return {records,fail:false,failCleanup:false,async read(k){return structuredClone(records.get(k)??null);},async key(){return key;},async atomic(entries,options){if(this.fail||this.failCleanup&&options?.clearLegacySecret)throw Error('disk unavailable');for(const [k,v]of entries){if(v===null)records.delete(k);else records.set(k,structuredClone(v));}if(options?.clearLegacySecret)records.delete('legacy-secret');},async locked(action){return action();}};
}
const state=(title)=>({chat:JSON.stringify({room:title}),contacts:JSON.stringify({friend:title}),profile:{name:title,avatar:''}});

test('saved identities require their own PIN and retain isolated encrypted state',async()=>{
  const host=await storage(), vault=new WebIdentityVault(host);
  await vault.register(alice,new Uint8Array([1,2,3]),state('Alice private fixture'));
  await vault.remember(alice,'123456');
  await vault.register(bob,new Uint8Array([4,5,6]),state('Bob private fixture'));
  await vault.remember(bob,'654321');
  assert.deepEqual([...await vault.unlock(alice,'123456')],[1,2,3]);
  await assert.rejects(vault.unlock(alice,'654321'),/PIN/);
  assert.deepEqual([...await vault.unlock(bob,'654321')],[4,5,6]);
  const reopened=new WebIdentityVault(host);
  assert.equal((await reopened.list()).length,2);
  assert.deepEqual(await reopened.loadState(alice),state('Alice private fixture'));
  assert.deepEqual(await reopened.loadState(bob),state('Bob private fixture'));
  const stored=host.records.get(`account:${alice}`);
  assert.ok(stored.ciphertext instanceof ArrayBuffer);
  assert.equal(new TextDecoder().decode(stored.ciphertext).includes('Alice private fixture'),false);
  assert.equal(host.records.has(`draft:${alice}`),false);
});

test('failed PIN setup or state persistence leaves the recoverable account intact',async()=>{
  const host=await storage(),vault=new WebIdentityVault(host);
  await vault.register(alice,new Uint8Array([7,8]),state('Original'));
  host.fail=true;
  await assert.rejects(vault.remember(alice,'123456'),/disk unavailable/);
  await assert.rejects(vault.saveState(alice,state('Uncommitted')),/disk unavailable/);
  host.fail=false;
  assert.deepEqual(await vault.loadState(alice),state('Original'));
  assert.deepEqual([...await vault.unlock(alice,'')],[7,8]);
  await vault.remember(alice,'123456');
  assert.deepEqual([...await vault.unlock(alice,'123456')],[7,8]);
});

test('invalid identities, PIN guessing and ciphertext swapped between accounts fail closed',async()=>{
  const host=await storage(),vault=new WebIdentityVault(host);
  await assert.rejects(vault.register('not-a-did',new Uint8Array([1]),state('x')));
  await vault.register(alice,new Uint8Array([1]),state('Alice'));
  await assert.rejects(vault.remember(alice,'12'),/6 to 12/);
  await vault.remember(alice,'123456');
  for(let i=0;i<5;i++)await assert.rejects(vault.unlock(alice,'000000'),/PIN/);
  await assert.rejects(vault.unlock(alice,'123456'),/Try again/);
  await vault.register(bob,new Uint8Array([2]),state('Bob'));
  host.records.set(`account:${bob}`,host.records.get(`account:${alice}`));
  await assert.rejects(vault.loadState(bob));
});

test('PIN commit and legacy-secret cleanup either both persist or both remain retryable',async()=>{
  const host=await storage(),vault=new WebIdentityVault(host);
  await vault.register(alice,new Uint8Array([9]),state('Legacy'));
  host.records.set('legacy-secret','origin-wrapped legacy fixture');
  host.failCleanup=true;
  await assert.rejects(vault.remember(alice,'123456'),/disk unavailable/);
  assert.equal((await vault.list())[0].requiresPin,false);
  assert.deepEqual([...await vault.unlock(alice,'')],[9]);
  host.failCleanup=false;
  await vault.remember(alice,'123456');
  assert.equal(host.records.has('legacy-secret'),false);
  assert.deepEqual([...await vault.unlock(alice,'123456')],[9]);
});
