// Run with playwright-cli on serve_web_identity_checks.mjs /new/index.html.
// Disposable contexts only: never open or read an existing user's account.
async page => {
  const browser = page.context().browser(), origin = new URL(page.url()).origin;
  const contexts = [], tabs = [], cards = [], ids = [];
  try {
    for (const name of ['Synthetic sender', 'Synthetic recipient']) {
      const context = await browser.newContext(), tab = await context.newPage();
      contexts.push(context); tabs.push(tab);
      await tab.goto(origin + '/new/index.html');
      await tab.waitForFunction(() => !!globalThis.chtCore);
      const value = await tab.evaluate(async name => {
        await chtCore.ready;
        let locked = false;
        try { await chtCore.contactRequestCall('inspect', '{}'); } catch { locked = true; }
        if (!locked) throw Error('Locked contact gateway was available');
        const pending = JSON.parse(await chtCore.createIdentity());
        const identity = JSON.parse(await chtCore.confirmRecovery(pending.mnemonic));
        return {id: identity.id, card: await chtCore.contactCard(name, '')};
      }, name);
      cards.push(value.card); ids.push(value.id);
    }
    await tabs[0].evaluate(async ({card,id}) => {
      await chtCore.addContact(card, 'Local alias'); await chtCore.markContactVerified(id);
    }, {card:cards[1],id:ids[1]});
    const envelope = await tabs[0].evaluate(async card => JSON.parse(await chtCore.contactRequestCall('seal',JSON.stringify({
      peerCard:card,requestId:'1234567890abcdef1234567890abcdef',kind:'request',displayName:'Synthetic sender',now:Date.now(),
    }))).envelope, cards[1]);
    if (JSON.stringify(envelope).includes('Synthetic sender')) throw Error('Unsealed profile in wire packet');
    const opened = await tabs[1].evaluate(async envelope => {
      const value=JSON.parse(await chtCore.contactRequestCall('inspect',JSON.stringify({source:JSON.stringify(envelope),now:Date.now()})));
      if(JSON.parse(await chtCore.contacts()).length)throw Error('Receiving setup created trust');
      let rejected=false;try{await chtCore.contactRequestCall('inspect',JSON.stringify({source:JSON.stringify({...envelope,kind:'accepted'}),now:Date.now()}));}catch{rejected=true;}
      if(!rejected)throw Error('Tampered setup accepted');
      await chtCore.addContact(value.cardJson,'Reviewed sender');await chtCore.markContactVerified(value.peerId);
      return value;
    }, envelope);
    if(opened.peerId!==ids[0]||opened.contact.verified)throw Error('Wrong setup sender or premature trust');
    const accepted=await tabs[1].evaluate(async card=>JSON.parse(await chtCore.contactRequestCall('seal',JSON.stringify({peerCard:card,requestId:'1234567890abcdef1234567890abcdef',kind:'accepted',now:Date.now()}))).envelope,cards[0]);
    await tabs[0].evaluate(async envelope=>{
      const value=JSON.parse(await chtCore.contactRequestCall('inspect',JSON.stringify({source:JSON.stringify(envelope),now:Date.now()})));
      if(value.kind!=='accepted')throw Error('Acceptance did not cross WASM gateway');
      if(JSON.parse(await chtCore.contacts())[0].alias!=='Local alias')throw Error('Local alias lost');
    },accepted);
    return {wasmContactSetup:true,lockedGate:true,noPreConsentTrust:true,tamperRejected:true,aliasPreserved:true};
  } finally { for(const context of contexts)await context.close(); }
}
