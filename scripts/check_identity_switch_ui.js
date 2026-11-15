// Disposable browser context only. Opens synthetic local accounts; no peer sends.
async page=>{
  await page.setViewportSize({width:1280,height:1000});
  await page.waitForFunction(()=>!!globalThis.chtCore);
  await page.evaluate(async()=>{
    await chtCore.ready;
    if(await chtCore.hasIdentity()||JSON.parse(await chtCore.savedIdentities()).length)throw Error('A fresh disposable browser context is required');
    for(const [name,pin]of [['Synthetic Alpha','573921'],['Synthetic Beta','682137']]){
      const draft=JSON.parse(await chtCore.createIdentity());
      await chtCore.confirmRecovery(draft.mnemonic);
      await chtCore.rememberIdentity(pin,name,'');
      await chtCore.sendText('general',`${name} local history`,Date.now());
      await chtCore.lockIdentity();
    }
  });
  await page.reload();
  await page.locator('flt-semantics-placeholder').evaluate(e=>e.click());
  await page.getByText('Choose an identity',{exact:true}).waitFor();
  for(const [name,pin,other]of [['Synthetic Alpha','573921','Synthetic Beta'],['Synthetic Beta','682137','Synthetic Alpha'],['Synthetic Alpha','573921','Synthetic Beta']]){
    await page.getByRole('button',{name:new RegExp(`^S ${name} did:cht:`)}).click();
    const login=page.getByRole('textbox',{name:'PIN',exact:true});await login.click();await login.fill(pin);
    await page.getByRole('button',{name:'Unlock',exact:true}).click();
    await page.waitForFunction(()=>location.pathname.endsWith('/chats'));
    const correct=await page.evaluate(async ({name,other})=>{
      const snapshot=await chtCore.snapshot();
      return snapshot.includes(`${name} local history`)&&!snapshot.includes(`${other} local history`);
    },{name,other});
    if(!correct)throw Error('Account history crossed identity boundary');
    await page.getByRole('tab',{name:'Profile',exact:true}).click();
    await page.getByRole('button',{name:'Switch identity',exact:true}).waitFor();
    await page.screenshot({path:'target/chta-web30-profile-switch.png'});
    if(name==='Synthetic Alpha'&&other==='Synthetic Beta'){
      const profile=await page.evaluate(async()=>JSON.parse(await chtCore.loadDesktopProfile()).name);
      if(profile!==name)throw Error('Wrong profile after switching');
    }
    await page.getByRole('button',{name:'Switch identity',exact:true}).click();
    await page.getByText('Choose an identity',{exact:true}).waitFor();
  }
  console.log('PASS: Web picker, PIN, Profile Switch identity and isolated histories across three UI switches');
}
