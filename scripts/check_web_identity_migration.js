// Run against a built Web app in a disposable context. Seeds the actual legacy
// encrypted schema, never an existing user's data or recovery phrase.
async page=>{
  const url=page.url(),context=await page.context().browser().newContext({viewport:{width:1280,height:1000}}),tab=await context.newPage();
  let step='seed legacy data';
  try{
    await tab.goto(url);await tab.waitForFunction(()=>!!globalThis.chtCore);
    await tab.evaluate(async()=>{
      const db=await chtCore.ready;
      if(await chtCore.hasIdentity()||JSON.parse(await chtCore.savedIdentities()).length)throw Error('Fresh context required');
      const module=await import('./wasm/cht_core.js');
      const account=new module.AccountCore(),chat=new module.WebChatCore();
      const draft=JSON.parse(account.createIdentityJson()),secret=account.confirmRecovery(draft.mnemonic);
      try{
        chat.sendText('general','Legacy stored history',1234);
        const key=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
        const iv=crypto.getRandomValues(new Uint8Array(12));
        const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv},key,secret);
        await new Promise((resolve,reject)=>{
          const tx=db.transaction(['keys','secrets','state'],'readwrite');
          tx.objectStore('keys').put(key,'identity-wrapping-key');
          tx.objectStore('secrets').put({version:1,iv,ciphertext},'identity-secret');
          tx.objectStore('state').put(chat.exportStateJson(),'chat-store');
          tx.objectStore('state').put(account.contactsStateJson(),'contacts');
          tx.oncomplete=resolve;tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);
        });
        localStorage.setItem('cht.profile',JSON.stringify({name:'Legacy Synthetic',avatar:''}));
      }finally{secret.fill(0);account.free();chat.free();}
    });
    step='legacy startup';await tab.reload();await tab.locator('flt-semantics-placeholder').evaluate(e=>e.click());
    await tab.getByText('Set a PIN',{exact:true}).waitFor();
    await tab.getByRole('textbox',{name:'Profile name',exact:true}).click();
    const profileInput=await tab.getByRole('textbox',{name:'Profile name',exact:true}).inputValue();
    if(profileInput!=='Legacy Synthetic')throw Error(`Migration profile mismatch: ${JSON.stringify({input:profileInput,stored:await tab.evaluate(async()=>JSON.parse(await chtCore.loadDesktopProfile()).name)})}`);
    const setup=tab.getByRole('textbox',{name:'PIN (6 to 12 digits)',exact:true});await setup.click();await setup.fill('573921');
    const confirm=tab.getByRole('textbox',{name:'Confirm PIN',exact:true});await confirm.click();await confirm.fill('573921');
    step='save PIN';await tab.getByRole('button',{name:'Save and continue',exact:true}).click();
    await tab.waitForFunction(()=>location.pathname.endsWith('/chats'));
    if(!await tab.evaluate(async()=>(await chtCore.snapshot()).includes('Legacy stored history')))throw Error('Migration lost history');
    step='reload with PIN';await tab.reload();await tab.locator('flt-semantics-placeholder').evaluate(e=>e.click());
    await tab.getByText('Choose an identity',{exact:true}).waitFor();
    const login=tab.getByRole('textbox',{name:'PIN',exact:true});await login.click();await login.fill('573921');
    step='unlock migrated identity';await tab.getByRole('button',{name:'Unlock',exact:true}).click();
    await tab.waitForFunction(()=>location.pathname.endsWith('/chats'));
    if(!await tab.evaluate(async()=>(await chtCore.snapshot()).includes('Legacy stored history')))throw Error('History missing after PIN reload');
    console.log('PASS: legacy encrypted identity migrates through PIN setup and survives authenticated reload');
  }catch(error){await tab.screenshot({path:'target/chta-web30-migration-failure.png'});throw Error(`${step}: ${String(error)}; UI=${(await tab.locator('body').innerText()).slice(0,1200)}`);}
  finally{await context.close();}
}
