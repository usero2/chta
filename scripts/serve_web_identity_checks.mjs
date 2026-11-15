import http from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
const repo=process.argv[2];
if(!repo)throw Error('Pass the repository root; serve only disposable browser checks');
const server=http.createServer(async(req,res)=>{
 try{
  const url=new URL(req.url,'http://localhost'),parts=url.pathname.split('/').filter(Boolean);
  if(!['old','new'].includes(parts[0])){res.writeHead(404).end();return;}
  const [revision,...rest]=parts;let file=rest.join('/');
  res.setHeader('Cache-Control','no-store');
  if(!file||file==='index.html'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><script type="module" src="./cht_core_loader.js"></script>');return;}
  if(file.includes('..')||!file.match(/^[a-zA-Z0-9_./-]+$/))throw Error('Invalid path');
  let source;
  if(revision==='old'&&['cht_core_loader.js','web_identity_vault.js'].includes(file))source=path.join(repo,'target','web-identity-old',file);
  else source=path.join(repo,'apps/flutter_app/web',file);
  res.setHeader('Content-Type',file.endsWith('.wasm')?'application/wasm':'application/javascript');
  res.end(await readFile(source));
 }catch{res.writeHead(404).end();}
});
server.listen(0,'127.0.0.1',()=>console.log(`http://127.0.0.1:${server.address().port}`));
