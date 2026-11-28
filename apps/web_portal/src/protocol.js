// Public-key verification only. Private signing keys never enter this Worker.
const utf8 = new TextEncoder();
export const MAX_FRAME = 16384;
export const SEED_ID = 'e0ba672185682a830d168e31cee185b9434b49b210a7ec7a435e78fcb2a532a5';
export const DID = /^did:cht:[0-9a-f]{64}$/;
export function requireThat(ok) { if (!ok) throw new Error('Invalid seed control frame'); }
export const bytes = value => utf8.encode(value).byteLength;
export function exact(value, keys) {
  requireThat(value !== null && typeof value === 'object' && !Array.isArray(value));
  const actual = Object.keys(value);
  requireThat(actual.length === keys.length && keys.every(k => Object.hasOwn(value,k)));
}
export function decode(value, size) {
  requireThat(typeof value === 'string' && value.length === Math.ceil(size * 4 / 3) && /^[A-Za-z0-9_-]+$/.test(value));
  const raw = Uint8Array.from(atob(value.replace(/-/g,'+').replace(/_/g,'/')), x => x.charCodeAt(0));
  requireThat(raw.length === size && encode(raw) === value);
  return raw;
}
export const encode = raw => btoa(String.fromCharCode(...raw)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
export async function hash(value) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256',value))].map(x => x.toString(16).padStart(2,'0')).join('');
}
async function signature(publicKey, sig, payload, expectedId) {
  const raw = decode(publicKey,32), signed = decode(sig,64);
  requireThat(await hash(raw) === expectedId);
  const key = await crypto.subtle.importKey('raw',raw,{name:'Ed25519'},false,['verify']);
  requireThat(await crypto.subtle.verify('Ed25519',key,signed,utf8.encode(payload)));
}
function times(v, now, ttl, skew) {
  requireThat(Number.isSafeInteger(v.issuedAt) && v.issuedAt >= 0 && Number.isSafeInteger(v.expiresAt) && v.expiresAt >= 0);
  requireThat(v.issuedAt <= now + skew && v.expiresAt > now && v.expiresAt > v.issuedAt && v.expiresAt - v.issuedAt <= ttl);
}
export async function verifyProof(p, nonce, relayId = SEED_ID) {
  exact(p,['identityId','publicKey','signature']);
  requireThat(DID.test(p.identityId)); decode(nonce,32);
  await signature(p.publicKey,p.signature,`cht relay registration v1\0${relayId}\0${nonce}`,p.identityId.slice(8));
  return p.identityId;
}
export async function verifyDispatch(p,envelope,identityId,connection,previousSequence) {
  exact(p,['version','seedId','connection','sequence','envelopeHash','publicKey','signature']);
  requireThat(p.version===1 && p.seedId===SEED_ID && p.connection===connection);
  decode(connection,32);
  requireThat(Number.isSafeInteger(previousSequence) && previousSequence>=0 &&
    Number.isSafeInteger(p.sequence) && p.sequence>previousSequence &&
    typeof identityId==='string' && DID.test(identityId) && envelope?.from===identityId &&
    p.publicKey===envelope.publicKey && bytes(JSON.stringify(envelope))<=15500);
  const tuple=['version','topic','from','to','session','id','kind','payload','issuedAt','expiresAt','publicKey','signature'].map(k=>envelope[k]??null);
  requireThat(p.envelopeHash===await hash(utf8.encode(JSON.stringify(tuple))));
  await signature(p.publicKey,p.signature,'chta seed dispatch v1\0'+JSON.stringify([1,p.seedId,p.connection,p.sequence,p.envelopeHash]),identityId.slice(8));
  return p.sequence;
}
function payload(v) {
  requireThat(typeof v.payload === 'string' && bytes(v.payload) <= 11264);
  const p = JSON.parse(v.payload);
  exact(p,v.kind === 'ice' ? ['v','t','s','c','m','l'] : ['v','t','s','d']);
  requireThat(p.v === 1 && p.t === v.kind && p.s === v.session);
  if (v.kind !== 'ice') {
    requireThat(typeof p.d === 'string' && bytes(p.d) <= 11000 && /^v=0\r?\n/.test(p.d) && !p.d.includes('\0'));
    const lines=p.d.split(/\r?\n/),fps=lines.filter(l=>l.startsWith('a=fingerprint:sha-256 ')).map(l=>l.slice(22));
    requireThat(fps.length>0&&fps.every(fp=>/^(?:[0-9a-fA-F]{2}:){31}[0-9a-fA-F]{2}$/.test(fp)));
    const roles = [...p.d.matchAll(/(?:^|\n)a=setup:([^\r\n]+)/g)].map(m => m[1]);
    requireThat(roles.length > 0 && roles.every(role => v.kind === 'offer' ? role === 'actpass' : role === 'active' || role === 'passive'));
    for(const line of lines)if(line.startsWith('a=candidate:'))candidate(line.slice(2));
  } else {
    candidate(p.c);
    requireThat(p.m === null || typeof p.m === 'string' && bytes(p.m) <= 64 && !/[\r\n\0]/.test(p.m));
    requireThat(p.l === null || Number.isInteger(p.l) && p.l >= 0 && p.l <= 65535);
  }
}
function candidate(value){
  requireThat(typeof value === 'string' && bytes(value) <= 2048 && !/[\r\n\0]/.test(value));
  const parts = value.trim().split(/\s+/);
  requireThat(parts.length >= 8 && /^candidate:[A-Za-z0-9+/]{1,32}$/.test(parts[0]) && /^(udp|tcp)$/i.test(parts[2]) && parts[6] === 'typ' && /^(host|srflx|prflx|relay)$/.test(parts[7]));
  requireThat(/^\d+$/.test(parts[1]) && +parts[1] >= 1 && +parts[1] <= 256 && /^\d+$/.test(parts[3]) && +parts[3] <= 4294967295 && parts[4].length <= 253 && /^\d+$/.test(parts[5]) && +parts[5] >= 1 && +parts[5] <= 65535);
  requireThat(!parts.slice(8).some(part => part.toLowerCase() === 'typ'));
  if(parts[7]==='relay'){
    requireThat(/^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$/.test(parts[4]) && parts[4].split('.').every(part => Number(part)<=255));
    publicEndpoint('wss://'+parts[4]+'/cht');
  }
}
export async function verifySignal(v, sender, now) {
  if(v?.version === 2 && v.topic === 'contacts')return verifyContactSignal(v,sender,now);
  const groups = v !== null && typeof v === 'object' && v.version === 2;
  exact(v,groups ? ['version','topic','from','to','session','id','kind','payload','issuedAt','expiresAt','publicKey','signature'] : ['version','from','to','session','id','kind','payload','issuedAt','expiresAt','publicKey','signature']);
  requireThat(bytes(JSON.stringify(v)) <= MAX_FRAME && (groups ? v.topic === 'groups' : v.version === 1) && typeof v.from === 'string' && DID.test(v.from) && typeof v.to === 'string' && DID.test(v.to) && v.from === sender && v.from !== v.to);
  requireThat(typeof v.session === 'string' && /^[0-9a-f]{32}$/.test(v.session) && ['offer','answer','ice'].includes(v.kind));
  const prefix = `cht-control-${groups ? 'groups' : 'direct'}-v1-${v.session}-${v.kind}-`;
  requireThat(typeof v.id === 'string' && v.id.startsWith(prefix));
  const counter = v.id.slice(prefix.length);
  requireThat(/^[0-9]{1,20}$/.test(counter) && BigInt(counter) <= 18446744073709551615n);
  times(v,now,120000,30000); payload(v);
  const tuple = groups ? [v.version,v.topic,v.from,v.to,v.session,v.id,v.kind,v.payload,v.issuedAt,v.expiresAt] : [v.version,v.from,v.to,v.session,v.id,v.kind,v.payload,v.issuedAt,v.expiresAt];
  await signature(v.publicKey,v.signature,(groups ? 'chta group seed signal v1\0' : 'chta seed signal v1\0')+JSON.stringify(tuple),v.from.slice(8));
  return v;
}

async function verifyContactSignal(v, sender, now) {
  const fields=['version','topic','from','to','session','id','kind','payload','issuedAt','expiresAt','publicKey','signature'];
  exact(v,fields);
  requireThat(bytes(JSON.stringify(v))<=MAX_FRAME&&v.version===2&&v.topic==='contacts');
  requireThat(typeof v.from==='string'&&DID.test(v.from)&&v.from===sender&&typeof v.to==='string'&&DID.test(v.to)&&v.from!==v.to);
  requireThat(typeof v.session==='string'&&/^[0-9a-f]{32}$/.test(v.session)&&['request','received','accepted','declined'].includes(v.kind));
  const prefix=`cht-contact-request-v1-${v.session}-${v.kind}-`;
  requireThat(typeof v.id==='string'&&v.id.startsWith(prefix)&&/^[0-9a-f]{32}$/.test(v.id.slice(prefix.length)));
  times(v,now,120000,30000);
  requireThat(typeof v.payload==='string'&&bytes(v.payload)<=11264);
  const p=JSON.parse(v.payload);exact(p,['v','t','s','box']);
  requireThat(p.v===1&&p.t===v.kind&&p.s===v.session&&typeof p.box==='string'&&p.box.length>=128&&p.box.length<=11052);
  const size=Math.floor(p.box.length*3/4);requireThat(size>=96&&size<=8288);decode(p.box,size);
  await signature(v.publicKey,v.signature,'chta contact request signal v1\0'+JSON.stringify(fields.slice(0,-2).map(k=>v[k])),v.from.slice(8));
  return v;
}
// This is syntax validation only: never resolve or fetch a caller-supplied URL.
export function publicEndpoint(value) {
  requireThat(typeof value === 'string' && bytes(value) <= 2048 && !/[\u0000-\u0020\u007f]/.test(value));
  const u = new URL(value), host = u.hostname.toLowerCase().replace(/\.$/,'');
  requireThat(u.protocol === 'wss:' && u.pathname === '/cht' && !u.username && !u.password && !u.search && !u.hash);
  requireThat(host !== 'localhost' && !/\.(localhost|local|internal)$/.test(host) && (host.includes('.') || host.includes(':')));
  if (/^\d+(\.\d+){3}$/.test(host)) {
    const [a,b,c] = host.split('.').map(Number);
    requireThat(!(a === 0 || a === 10 || a === 127 || a >= 224 || a === 169 && b === 254 || a === 172 && b >= 16 && b <= 31 || a === 192 && b === 168 || a === 100 && b >= 64 && b <= 127 || a === 192 && b === 0 || a === 198 && (b === 18 || b === 19 || b === 51 && c === 100) || a === 203 && b === 0 && c === 113));
  }
  if (host.startsWith('[')) {
    const h = host.slice(1,-1);
    // Require globally routable unicast IPv6, excluding mapped, ULA, link-local and documentation.
    requireThat(/^[23][0-9a-f]{3}:/.test(h) && !h.startsWith('2001:db8:'));
  }
  return true;
}
export async function verifyRecord(r, now) {
  exact(r,['version','relayId','publicKey','endpoint','issuedAt','expiresAt','signature']);
  requireThat(r.version === 1 && typeof r.relayId === 'string' && /^[0-9a-f]{64}$/.test(r.relayId));
  times(r,now,3600000,60000); publicEndpoint(r.endpoint);
  await signature(r.publicKey,r.signature,'cht relay directory v1\0'+JSON.stringify([r.version,r.relayId,r.publicKey,r.endpoint,r.issuedAt,r.expiresAt]),r.relayId);
  return r;
}
