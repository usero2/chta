import assert from 'node:assert/strict';
import test from 'node:test';
import worker from '../src/worker.js';
import shareWorker from '../src/share-worker.js';
import { invitationForClipboard, shareDestinations } from '../public/share/share.js';

test('share route serves a private landing page for GET and HEAD', async () => {
  for (const method of ['GET', 'HEAD']) {
    const response = await worker.fetch(new Request('https://chta.app/share/', { method }), {
      ASSETS: {
        fetch(request) {
          const url = new URL(request.url);
          assert.equal(url.pathname, '/share/index.html');
          return new Response('Open in chta', { headers: { 'content-type': 'text/html' } });
        },
      },
    });
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(await response.text(), method === 'HEAD' ? '' : 'Open in chta');
  }
});

test('platform destinations keep the magnet token out of HTTP requests', () => {
  const token = 'bWFnbmV0Ong';
  const android = shareDestinations(token, 'Android');
  assert.equal(android.web, '/chat/contacts#chta=' + token);
  assert.equal(android.download, 'https://play.google.com/store/apps/details?id=app.cht.cht');
  assert.match(android.open, /^intent:\/\/share\/open\?payload=bWFnbmV0Ong#Intent;scheme=chta;package=app\.cht\.cht;/);
  const desktop = shareDestinations(token, 'Windows');
  assert.equal(desktop.download, '/#platforms');
  assert.equal(desktop.open, null);
  assert.equal(shareDestinations(token, 'iPhone').download, null);
  assert.equal(shareDestinations('bad=token', 'Android'), null);
});

test('isolated Worker serves only public share assets', async () => {
  const env = { ASSETS: { fetch: async (request) => {
    assert.equal(new URL(request.url).pathname, '/index.html');
    assert.equal(new URL(request.url).search, '');
    return new Response('share');
  } } };
  const response = await shareWorker.fetch(new Request('https://chta.app/share/?ignored=1'), env);
  assert.equal(await response.text(), 'share');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  for (const path of ['/relay', '/chat/', '/share/private']) {
    assert.equal((await shareWorker.fetch(new Request('https://chta.app' + path), env)).status, 404);
  }
});

test('clipboard supplies the signed card to older clients', () => {
  const card = '{"name":"Mali"}';
  const magnet = 'magnet:?xt=urn%3Achta%3Acontact%3A1&x.chta-card=' + Buffer.from(card).toString('base64url');
  assert.equal(invitationForClipboard(Buffer.from(magnet).toString('base64url')), card);
  assert.equal(invitationForClipboard('aBc'), null);
});
