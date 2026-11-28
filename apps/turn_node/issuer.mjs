import {createHmac, timingSafeEqual} from 'node:crypto';
import {createServer} from 'node:http';
import {pathToFileURL} from 'node:url';

const hexSecret = /^[a-f0-9]{64}$/;
const dnsHost = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const ttl = 3600;

export function createIssuer(env = process.env) {
  const {TURN_HOST: host, TURN_ACCESS_TOKEN: token, TURN_SHARED_SECRET: secret} = env;
  if (!host || host.length > 253 || !dnsHost.test(host) ||
      !hexSecret.test(token ?? '') || !hexSecret.test(secret ?? '') || token === secret) {
    throw new Error('Set TURN_HOST and two different 64-character hex secrets.');
  }

  const expected = Buffer.from('Bearer ' + token);
  const browserOrigin = 'https://chta.app';
  const urls = ['udp', 'tcp'].map(protocol => 'turn:' + host + ':3478?transport=' + protocol);
  let minute = 0;
  let issued = 0;
  const server = createServer({headersTimeout: 5000, requestTimeout: 5000}, (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const reply = (status, body) => {
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.writeHead(status);
      res.end(body === undefined ? undefined : JSON.stringify(body));
    };
    if (req.url === '/healthz' && (req.method === 'GET' || req.method === 'HEAD')) {
      reply(200, {ok: true, protocol: 'chta-turn-issuer', version: 1});
      return;
    }
    if (req.url !== '/ice') return reply(404);
    res.setHeader('Vary', 'Origin');
    if (req.headers.origin === browserOrigin) {
      res.setHeader('Access-Control-Allow-Origin', browserOrigin);
    }
    if (req.method === 'OPTIONS') {
      if (req.headers.origin !== browserOrigin) return reply(403);
      res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization');
      return reply(204);
    }
    if (req.method !== 'GET') {
      res.setHeader('Allow', 'GET, OPTIONS');
      return reply(405);
    }
    const auth = Buffer.from(req.headers.authorization ?? '');
    if (auth.length !== expected.length || !timingSafeEqual(auth, expected)) return reply(401);

    const now = Math.floor(Date.now() / 1000);
    const currentMinute = Math.floor(now / 60);
    if (currentMinute !== minute) {
      minute = currentMinute;
      issued = 0;
    }
    if (issued >= 300) return reply(429);
    issued++;
    // A stable label and expiry bucket keep coturn's per-user quota meaningful.
    const expires = currentMinute * 60 + ttl;
    const username = expires + ':chta';
    const credential = createHmac('sha1', secret).update(username).digest('base64');
    return reply(200, {version: 1, urls, username, credential, ttl: expires - now});
  });
  server.maxConnections = 256;
  server.setTimeout(10000, socket => socket.destroy());
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createIssuer().listen(8080, '0.0.0.0');
}
