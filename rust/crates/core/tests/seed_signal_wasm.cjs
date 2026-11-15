// Real generated WASM boundary parity. Only synthetic deterministic identities.
// node --test rust/crates/core/tests/seed_signal_wasm.cjs
// CHT_SEED_WASM_MODULE points to wasm-bindgen --target nodejs output.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const {AccountCore} = require(path.resolve(process.env.CHT_SEED_WASM_MODULE));
const fixture=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../../../apps/web_portal/test/fixtures/seed-signal.json'),'utf8'));
function owner(n) {
  return new AccountCore(Buffer.from(JSON.stringify({derivationVersion:1,entropy:Array(32).fill(n),contactToken:Array(32).fill(n)})),undefined);
}
function id(a) { return JSON.parse(a.identityJson()).id; }
function trust(a,b) { a.addContact(b.contactCardJson(),'test'); a.markContactVerified(id(b)); }
test('WASM deterministic envelope matches Rust and enforces boundary checks',()=>{
  const a=owner(1),b=owner(2); trust(a,b); trust(b,a);
  const {envelope:e,now}=fixture;
  const signed=a.signSeedSignal(id(b),e.id,e.payload,now);
  assert.deepEqual(JSON.parse(signed),e);
  assert.deepEqual(JSON.parse(b.inspectSeedSignal(signed,id(a),now)),{peerId:id(a),messageId:e.id,text:e.payload});
  assert.throws(()=>b.inspectSeedSignal(signed,id(a),now));
  for (const value of [NaN,Infinity,-1,1.5,9007199254740992]) {
    assert.throws(()=>a.signSeedSignal(id(b),e.id,e.payload,value));
    assert.throws(()=>b.inspectSeedSignal(signed,id(a),value));
  }
  const locked=new AccountCore(undefined,undefined);
  assert.throws(()=>locked.signSeedSignal(id(b),e.id,e.payload,now));
  assert.throws(()=>locked.inspectSeedSignal(signed,id(a),now));
  const stranger=owner(3); trust(stranger,a);
  assert.throws(()=>stranger.inspectSeedSignal(signed,id(a),now));
  const unverified=owner(2); unverified.addContact(a.contactCardJson(),'test');
  assert.throws(()=>unverified.inspectSeedSignal(signed,id(a),now));
  const fresh=owner(2); trust(fresh,a);
  for (const [key,value] of [['signature','A'.repeat(86)],['extra',true],['to',id(stranger)],['publicKey','A'.repeat(43)]]) {
    assert.throws(()=>fresh.inspectSeedSignal(JSON.stringify({...e,[key]:value}),id(a),now));
  }
  assert.throws(()=>fresh.inspectSeedSignal(signed,id(a),now+120000));
  assert.throws(()=>fresh.inspectSeedSignal(signed,id(a),now-30001));
  assert.doesNotThrow(()=>fresh.inspectSeedSignal(signed,id(a),now));
});
