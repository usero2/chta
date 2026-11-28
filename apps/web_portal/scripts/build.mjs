import { cp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { resolve, dirname, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const portal=resolve(dirname(fileURLToPath(import.meta.url)),'..');
export async function build({flutterDir=resolve(portal,'../flutter_app/build/web'),outDir=resolve(portal,'dist')}={}) {
  const source=resolve(flutterDir),destination=resolve(outDir);
  const html=await readFile(resolve(source,'index.html'),'utf8');
  if(!/<base\s+href=["']\/chat\/["']\s*\/?\s*>/i.test(html))throw Error('Flutter build must use --base-href /chat/ before packaging');
  for(const required of ['main.dart.js','flutter_bootstrap.js','wasm/cht_core.js','wasm/cht_core_bg.wasm','canvaskit/canvaskit.wasm']){
    if(!(await stat(resolve(source,required)).catch(()=>null))?.isFile())throw Error('Flutter build is incomplete: missing '+required);
  }
  if(source===destination||!relative(destination,source).startsWith('..'))throw Error('Flutter source must be outside the output directory');
  // Atomic staging would require a platform-specific rename; validate first, then replace only this output.
  await rm(destination,{recursive:true,force:true});await mkdir(destination,{recursive:true});
  await cp(resolve(portal,'public'),destination,{recursive:true});
  const turnFiles=resolve(destination,'wiki/turn-server');
  await mkdir(turnFiles,{recursive:true});
  for (const file of ['compose.yaml','Caddyfile','issuer.mjs','.env.example']){
    await cp(resolve(portal,'../turn_node',file),resolve(turnFiles,file==='.env.example'?'turn.env.example':file));
  }
  await cp(source,resolve(destination,'chat'),{recursive:true});
  console.log('Portal packaged with mounted Flutter app: '+destination);
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href)await build();
