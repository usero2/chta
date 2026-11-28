import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {once} from 'node:events';
import {test} from 'node:test';
import {createIssuer} from './issuer.mjs';

test('authorizes an invite and issues short-lived coturn REST credentials', async () => {
  const access = 'a'.repeat(64);
  const secret = 'b'.repeat(64);
  const server = createIssuer({
    TURN_HOST: 'turn.example.org',
    TURN_SHARED_SECRET: secret,
    TURN_ACCESS_TOKEN: access,
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const base = 'http://127.0.0.1:' + server.address().port;
    assert.equal((await fetch(base + '/ice?token=' + access)).status, 404);
    assert.equal((await fetch(base + '/ice')).status, 401);
    assert.equal((await fetch(base + '/ice', {
      headers: {authorization: 'Bearer ' + 'z'.repeat(64)},
    })).status, 401);
    const preflight = await fetch(base + '/ice', {method: 'OPTIONS', headers: {
      origin: 'https://chta.app', 'access-control-request-headers': 'authorization',
    }});
    assert.equal(preflight.status, 204);
    assert.equal(preflight.headers.get('access-control-allow-origin'), 'https://chta.app');
    const response = await fetch(base + '/ice', {headers: {authorization: 'Bearer ' + access}});
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const value = await response.json();
    const expires = Number(value.username.split(':')[0]);
    assert.ok(expires - Math.floor(Date.now() / 1000) <= 3600);
    assert.ok(expires - Math.floor(Date.now() / 1000) > 3500);
    assert.equal(value.credential, createHmac('sha1', secret).update(value.username).digest('base64'));
    assert.ok(value.ttl > 3500 && value.ttl <= 3600);
    assert.deepEqual(value.urls, [
      'turn:turn.example.org:3478?transport=udp',
      'turn:turn.example.org:3478?transport=tcp',
    ]);
    assert.equal(JSON.stringify(value).includes(access), false);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});
