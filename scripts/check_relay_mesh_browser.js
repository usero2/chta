// Run against disposable browser contexts and local relay nodes at 19421/19422.
// playwright-cli -s=cht-relay-grid run-code --filename=scripts/check_relay_mesh_browser.js
async page => {
  const browser = page.context().browser();
  for (const context of browser.contexts()) if (context !== page.context()) await context.close();
  const contexts = [await browser.newContext(), await browser.newContext()];
  const pages = await Promise.all(contexts.map(context => context.newPage()));
  const failures = [];
  let activeRelay;
  const cdp = await contexts[0].newCDPSession(pages[0]);
  const sockets = new Map();
  await cdp.send('Network.enable');
  cdp.on('Network.webSocketCreated', event => sockets.set(event.requestId, event.url));
  cdp.on('Network.webSocketFrameSent', event => {
    try {
      const frame = JSON.parse(event.response.payloadData);
      if (frame.type === 'route' && frame.body?.type === 'encrypted') activeRelay = sockets.get(event.requestId);
    } catch (_) {}
  });
  for (const target of pages) target.on('pageerror', error => failures.push(error.message));
  const profiles = [];
  for (let index=0;index<pages.length;index++) {
    const target = pages[index];
    await target.goto('http://localhost:7357/connect');
    await target.waitForFunction(() => !!globalThis.chtCore);
    profiles.push(await target.evaluate(async index => {
      await chtCore.ready;
      const pending = JSON.parse(await chtCore.createIdentity());
      const identity = JSON.parse(await chtCore.confirmRecovery(pending.mnemonic));
      await chtCore.setProfileName(index === 0 ? 'Relay test Alice' : 'Relay test Bob');
      return {id:identity.id, card:await chtCore.contactCard(index === 0 ? 'Relay test Alice' : 'Relay test Bob')};
    }, index));
  }
  for (let index=0;index<pages.length;index++) {
    const target = pages[index]; const friend = profiles[1-index];
    await target.evaluate(async friend => {
      await chtCore.addContact(friend.card, '');
      await chtCore.markContactVerified(friend.id);
      await chtCore.saveRelayState(JSON.stringify({version:1,seeds:['ws://127.0.0.1:19421/cht','ws://127.0.0.1:19422/cht'],pins:{},relays:[]}));
    }, friend);
    await target.goto(`http://localhost:7357/chats/${encodeURIComponent(friend.id)}`);
    const placeholder = target.locator('flt-semantics-placeholder');
    if (await placeholder.count()) await placeholder.evaluate(element => element.click());
  }
  for (const target of pages) await target.getByText('Connected securely', {exact:true}).first().waitFor({timeout:30000});
  const composer = pages[0].getByRole('textbox').last();
  await composer.fill('Real Rust Noise relay before failover');
  await composer.press('Enter');
  await pages[1].waitForFunction(() => document.body.innerText.includes('Real Rust Noise relay before failover'), {timeout:15000});
  if (!activeRelay) throw new Error('No encrypted relay frame observed');
  return {realWasmNoiseHandshake:true, encryptedMessageReceived:true, activeRelay, pageErrors:failures};
}
