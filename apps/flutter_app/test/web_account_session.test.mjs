import test from 'node:test';
import assert from 'node:assert/strict';
import {AccountMutationQueue} from '../web/web_account_session.js';

test('a failed earlier mutation cannot roll back a successful later message',async()=>{
  const queue=new AccountMutationQueue();
  let state=[],durable=[],release;
  const waiting=new Promise(resolve=>release=resolve);
  const first=queue.run(async()=>{const before=[...state];state.push('A');await waiting;state=before;throw Error('disk unavailable');});
  const failure=assert.rejects(first,/disk unavailable/);
  const second=queue.run(async()=>{state.push('B');durable=[...state];});
  release();await failure;await second;
  assert.deepEqual(state,['B']);assert.deepEqual(durable,['B']);
});
