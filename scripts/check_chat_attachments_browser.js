// Disposable profiles only: Rust Noise, durable encrypted blobs and cached albums.
async page => {
  const origin=new URL(page.url()).origin;
  const relayMode=new URL(page.url()).searchParams.has('relay');
  const browser=page.context().browser();
  for(const context of browser.contexts()) if(context!==page.context()) await context.close();
  const contexts=[await browser.newContext({viewport:{width:1280,height:900}}),await browser.newContext({viewport:{width:390,height:844}})];
  const pages=await Promise.all(contexts.map(c=>c.newPage()));
  const errors=[],people=[];
  const history=async(index)=>pages[index].evaluate(async({owner,peer})=>JSON.parse(await chtCore.loadPeerHistory(owner)||'{}').rooms?.[peer]||[],{owner:people[index].id,peer:people[1-index].id});
  const waitFile=async(name)=>{
    for(let i=0;i<200;i++) {if((await history(1)).some(m=>m.attachmentRef?.name===name)) return; await pages[1].waitForTimeout(150);}
    throw Error(`Missing durable attachment: ${name}`);
  };
  for(let i=0;i<2;i++) {
    const p=pages[i];p.on('pageerror',e=>errors.push(e.message));
    await p.goto(`${origin}/identity`);await p.waitForFunction(()=>!!globalThis.chtCore);
    people.push(await p.evaluate(async i=>{
      await chtCore.ready;
      const pending=JSON.parse(await chtCore.createIdentity());
      const identity=JSON.parse(await chtCore.confirmRecovery(pending.mnemonic));
      const name=i===0?'Cache Alice':'Cache Bob';await chtCore.setProfileName(name);
      return{id:identity.id,name,card:await chtCore.contactCard(name)};
    },i));
  }
  for(let i=0;i<2;i++) {
    const p=pages[i];await p.evaluate(async f=>{await chtCore.addContact(f.card,'');await chtCore.markContactVerified(f.id);},people[1-i]);
    if(relayMode) await p.evaluate(()=>chtCore.saveRelayState(JSON.stringify({version:1,seeds:['ws://127.0.0.1:19421/cht'],pins:{},relays:[]})));
    await p.goto(`${origin}/chats/${encodeURIComponent(people[1-i].id)}`);
    const placeholder=p.locator('flt-semantics-placeholder');await placeholder.waitFor({timeout:20000});await placeholder.evaluate(e=>e.click());
    if(!relayMode) await p.getByText(people[1-i].name,{exact:true}).first().waitFor({timeout:20000});
  }
  if(!relayMode) {
    const offer=await pages[0].evaluate(()=>chtCore.createPeerOffer('','Cache Alice'));
    const answer=await pages[1].evaluate(o=>chtCore.acceptPeerOffer(o,'','Cache Bob'),offer);
    await pages[0].evaluate(a=>chtCore.acceptPeerAnswer(a),answer);
  }
  for(const p of pages)await p.getByText('Connected securely',{exact:true}).first().waitFor({timeout:30000});
  const input=pages[0].getByRole('textbox').last();
  await input.fill('## Markdown\n**bold** and *italic*');
  await pages[0].getByRole('button',{name:'Send (Ctrl+Enter)',exact:true}).click();
  for(const batch of [
    {menu:'Gallery',names:['sample-image.png','sample-image-2.png','sample-video.mp4','sample-video-2.mp4'],caption:'**One caption**'},
    {menu:'Audio',names:['sample-audio.wav'],caption:''},
    {menu:'Files',names:['sample-file.bin'],caption:''},
  ]) {
    await pages[0].getByRole('button',{name:'Attach',exact:true}).click();
    const chooser=pages[0].waitForEvent('filechooser');
    await pages[0].getByRole('button',{name:batch.menu,exact:true}).click();
    await(await chooser).setFiles(batch.names.map(n=>`target/media-fixtures/${n}`));
    await pages[0].getByRole('button',{name:'Delete',exact:true}).first().waitFor();
    if(batch.caption)await input.fill(batch.caption);
    await pages[0].getByRole('button',{name:'Send (Ctrl+Enter)',exact:true}).click();
    for(const name of batch.names)await waitFile(name);
  }
  for(let i=0;i<80;i++) {
    if((await history(1)).filter(m=>m.thumbnailRef).length===2)break;
    await pages[1].waitForTimeout(100);
  }
  if((await history(1)).filter(m=>m.thumbnailRef).length!==2)throw Error('Video thumbnails were not cached');
  const sent=await pages[0].evaluate(async({owner,peer})=>{
    const h=JSON.parse(await chtCore.loadPeerHistory(owner));
    const result=[];
    for(const m of h.rooms[peer]) if(m.attachmentRef) result.push({ref:m.attachmentRef,bytes:await chtCore.loadPeerAttachment(owner,m.attachmentRef.digest)});
    return result;
  },{owner:people[0].id,peer:people[1].id});
  const result=await pages[1].evaluate(async({owner,peer,sent})=>{
    const h=JSON.parse(await chtCore.loadPeerHistory(owner));const messages=h.rooms[peer];
    const refs=messages.filter(m=>m.attachmentRef).map(m=>m.attachmentRef);
    for(const file of sent) if(await chtCore.loadPeerAttachment(owner,file.ref.digest)!==file.bytes)throw Error('Changed attachment bytes');
    if(refs.length!==6||JSON.stringify(h).includes('"bytes"'))throw Error('Expected six reference-only attachments');
    if(refs.filter(r=>r.caption).length!==1)throw Error('Caption was duplicated');
    const images=refs.filter(r=>r.mimeType.startsWith('image/')),videos=refs.filter(r=>r.mimeType.startsWith('video/'));
    if(images[0].groupId!==images[1].groupId||videos[0].groupId!==videos[1].groupId||images[0].groupId===videos[0].groupId)throw Error('Incorrect media grouping');
    // Inject one cache write failure using only this disposable profile.
    const bytes=new Uint8Array([7,8,9]);const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
    const put=IDBObjectStore.prototype.put;let rejected=false;
    IDBObjectStore.prototype.put=function(value,key){if(String(key).startsWith('peer-attachment:'))throw new DOMException('Injected quota failure','QuotaExceededError');return put.call(this,value,key);};
    try{await chtCore.savePeerAttachment(owner,hash,btoa(String.fromCharCode(...bytes)));}catch(_){rejected=true;}finally{IDBObjectStore.prototype.put=put;}
    if(!rejected||await chtCore.loadPeerAttachment(owner,hash)!==null)throw Error('Failed cache write was accepted');
    const emptyDigest='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    if(await chtCore.loadPeerAttachment(owner,emptyDigest)!==null)throw Error('Missing sentinel');
    await chtCore.savePeerAttachment(owner,emptyDigest,'');
    if(await chtCore.loadPeerAttachment(owner,emptyDigest)!=='')throw Error('Empty attachment lost');
    // A version-2 embedded attachment must migrate on the next normal app load.
    messages.push({id:'legacy-test',text:'[file] legacy.txt',incoming:true,status:'delivered',attachment:{name:'legacy.txt',mimeType:'text/plain',bytes:'AQID'}});h.version=2;
    await chtCore.savePeerHistory(owner,JSON.stringify(h));
    return{binaryIntegrity:true,markdownSaved:messages.some(m=>m.text.includes('**bold**')),files:refs.map(r=>({name:r.name,size:r.size,groupId:r.groupId})),injectedFailureRejected:rejected,cachedThumbnails:messages.filter(m=>m.thumbnailRef).length};
  },{owner:people[1].id,peer:people[0].id,sent});
  await pages[1].reload();await pages[1].waitForFunction(()=>!!globalThis.chtCore);
  for(let i=0;i<100;i++){if((await history(1)).find(m=>m.id==='legacy-test')?.attachmentRef)break;await pages[1].waitForTimeout(150);}
  await contexts[1].setOffline(true);
  const restored=await pages[1].evaluate(async({owner,peer})=>{
    const h=JSON.parse(await chtCore.loadPeerHistory(owner));const messages=h.rooms[peer];
    if(messages.some(m=>m.attachment))throw Error('Legacy attachment did not migrate');
    for(const m of messages)if(m.attachmentRef && !(await chtCore.loadPeerAttachment(owner,m.attachmentRef.digest)))throw Error('Cache unavailable offline');
    return messages.filter(m=>m.attachmentRef).length;
  },{owner:people[1].id,peer:people[0].id});
  await pages[1].screenshot({path:`target/media-cache-${relayMode?'relay':'direct'}-mobile.png`});
  await pages[0].screenshot({path:`target/media-cache-${relayMode?'relay':'direct'}-desktop.png`});
  return{transport:relayMode?'Rust Noise relay':'Rust Noise direct',...result,restoredOffline:restored,pageErrors:errors};
}
