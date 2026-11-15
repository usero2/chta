// Read-only preflight. Credentials remain in process memory and are never logged.
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const portal=resolve(root,'apps/web_portal');
const auth=spawnSync(process.execPath,[resolve(portal,'node_modules/wrangler/bin/wrangler.js'),'auth','token','--json'],{cwd:portal,encoding:'utf8',windowsHide:true,env:{...process.env,WRANGLER_SEND_METRICS:'false'}});
if(auth.status!==0)throw Error('Cloudflare login is not available');
let data;
try{data=JSON.parse(auth.stdout);}catch{throw Error('Wrangler did not return authentication JSON');}
const token=data.token??data.apiToken??data.oauthToken;
if(typeof token!=='string'||token.length<10)throw Error('Unsupported Wrangler authentication type');
const response=await fetch('https://api.cloudflare.com/client/v4/zones?name=chta.app',{headers:{authorization:`Bearer ${token}`}});
const result=await response.json();
if(!response.ok||!result.success){console.log(JSON.stringify({ok:false,status:response.status,errorCodes:result.errors?.map(e=>e.code)}));process.exitCode=1;}
else{
  const zones=(result.result??[]).filter(zone=>zone.name==='chta.app').map(zone=>({name:zone.name,status:zone.status,accountName:zone.account?.name,accountId:zone.account?.id}));
  console.log(JSON.stringify({ok:zones.some(zone=>zone.status==='active'),zones}));
  if(!zones.some(zone=>zone.status==='active'))process.exitCode=1;
}
