export { SeedDirectory } from './seed-directory.js';
import { SEED_ID } from './protocol.js';
const security={
  'x-content-type-options':'nosniff',
  'referrer-policy':'no-referrer',
  'permissions-policy':'camera=(self), microphone=(self), geolocation=()',
  'cross-origin-opener-policy':'same-origin',
};
function reply(body,status=200,headers={}) {return new Response(body,{status,headers:{...security,'cache-control':'no-store',...headers}});}
export default {
  async fetch(request,env) {
    const url=new URL(request.url),path=url.pathname;
    if(!['GET','HEAD'].includes(request.method))return reply('Method not allowed',405,{allow:'GET, HEAD'});
    if(path==='/relay'){
      if(request.headers.get('upgrade')?.toLowerCase()==='websocket'){
        const id=env.SEED_DIRECTORY.idFromName('chta.app/relay/v1');return env.SEED_DIRECTORY.get(id).fetch(request);
      }
      return reply(request.method==='HEAD'?null:JSON.stringify({protocol:'chta-seed',version:1,seedId:SEED_ID,mode:'discovery-only',contentRelay:false}),200,{'content-type':'application/json; charset=utf-8'});
    }
    if(path.startsWith('/relay/')||path.startsWith('/api/'))return reply('Not found',404);
    if(path==='/chat'){url.pathname='/chat/';return reply(null,308,{location:url.href});}
    if(request.headers.has('upgrade'))return reply('Not found',404);
    const assetUrl=new URL(request.url);if(path==='/')assetUrl.pathname='/index.html';
    let asset=await env.ASSETS.fetch(new Request(assetUrl,request));
    const appRoute=/^\/chat\/(?:$|(?:chats|contacts|profile|connect|identity)(?:\/[^.]*)?$)/.test(path);
    if((asset.status===404||path==='/chat/')&&appRoute){url.pathname='/chat/index.html';url.search='';asset=await env.ASSETS.fetch(new Request(url,request));}
    if(asset.status===404)return reply('Not found',404,{'content-type':'text/plain; charset=utf-8'});
    const headers=new Headers(asset.headers);for(const[k,v]of Object.entries(security))headers.set(k,v);
    const html=headers.get('content-type')?.includes('text/html');
    headers.set('cache-control',html?'no-store':/\.[0-9a-f]{8,}\.[a-z0-9]+$/i.test(path)?'public, max-age=31536000, immutable':'public, max-age=0, must-revalidate');
    return new Response(request.method==='HEAD'?null:asset.body,{status:asset.status,headers});
  }
};
