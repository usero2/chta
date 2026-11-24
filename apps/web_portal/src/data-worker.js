export {DataRelay} from './data-relay.js';
export default {
  async fetch(request,env) {
    const url=new URL(request.url);
    if(url.pathname!=='/cht')return new Response('Not found',{status:404});
    if(!['GET','HEAD'].includes(request.method))return new Response('Method not allowed',{status:405});
    const id=env.DATA_RELAY.idFromName('chta-live-data-relay/v1');
    return env.DATA_RELAY.get(id,{locationHint:env.RELAY_LOCATION||'apac'}).fetch(request);
  }
};
