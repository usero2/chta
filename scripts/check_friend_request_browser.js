// Disposable identities only. Local test relay must listen on 19422.
async page => {
  const browser = page.context().browser();
  for (const c of browser.contexts()) if (c !== page.context()) await c.close();
  const contexts = [await browser.newContext(), await browser.newContext()];
  const pages = await Promise.all(contexts.map(c => c.newPage()));
  const errors = [];
  const profiles = [];
  for (let i = 0; i < 2; i++) {
    const target = pages[i];
    target.on('pageerror', e => errors.push(e.message));
    await target.goto('http://localhost:7357/');
    await target.waitForFunction(() => !!globalThis.chtCore);
    profiles.push(await target.evaluate(async i => {
      await chtCore.ready;
      const pending = JSON.parse(await chtCore.createIdentity());
      const identity = JSON.parse(await chtCore.confirmRecovery(pending.mnemonic));
      const name = i ? 'Request Bob' : 'Request Alice';
      await chtCore.setProfileName(name);
      const card = await chtCore.contactCardWithRelays(name, '', JSON.stringify(['wss://route.example.com/cht']));
      const inspected = JSON.parse(await chtCore.inspectContactCard(card));
      if (inspected.card.relayUrls[0] !== 'wss://route.example.com/cht') throw new Error('Signed routes missing');
      await chtCore.saveRelayState(JSON.stringify({version:1,seeds:['ws://127.0.0.1:19422/cht'],pins:{},relays:[]}));
      // Use reachable local transport for this test; public URL signing checked above.
      return {id:identity.id, card:await chtCore.contactCard(name)};
    }, i));
  }
  await pages[0].evaluate(async friend => {
    await chtCore.addContact(friend.card, '');
    await chtCore.markContactVerified(friend.id);
  }, profiles[1]);
  await pages[1].goto('http://localhost:7357/chats');
  await pages[0].goto(`http://localhost:7357/chats/${encodeURIComponent(profiles[1].id)}`);
  for (const target of pages) {
    await target.waitForSelector('flt-semantics-placeholder', {state:'attached'});
    await target.locator('flt-semantics-placeholder').evaluate(e => e.click());
  }
  const bob = pages[1];
  await bob.getByRole('button', {name:'Review', exact:true}).waitFor({timeout:30000});
  if ((await bob.evaluate(async () => JSON.parse(await chtCore.contacts()))).length) throw new Error('Unapproved friend was saved');
  await bob.getByRole('button', {name:'Review', exact:true}).click();
  await bob.getByText('Verify Request Alice', {exact:true}).waitFor();
  await bob.getByRole('button', {name:'Fingerprint matches', exact:true}).click();
  for (const target of pages) await target.getByText('Connected securely', {exact:true}).first().waitFor({timeout:30000});
  await pages[0].getByRole('textbox').last().fill('Approved friend request message');
  await pages[0].getByRole('textbox').last().press('Enter');
  await bob.waitForFunction(() => document.body.innerText.includes('Approved friend request message'));
  await bob.screenshot({path:'target/relay-v13-proof/friend-approved.png'});
  await bob.goto('http://localhost:7357/contacts');
  await bob.waitForSelector('flt-semantics-placeholder', {state:'attached'});
  await bob.locator('flt-semantics-placeholder').evaluate(e => e.click());
  await bob.getByText('Friends', {exact:true}).waitFor();
  await bob.setViewportSize({width:390,height:844});
  await bob.screenshot({path:'target/relay-v13-proof/mobile-contact-qr.png'});
  await bob.getByRole('button', {name:'Chat with Request Alice', exact:true}).scrollIntoViewIfNeeded();
  await bob.mouse.move(200,600);
  await bob.mouse.wheel(0,500);
  await bob.waitForTimeout(400);
  if (new URL(bob.url()).pathname !== '/contacts') throw new Error('Authentication unexpectedly left Contacts');
  await bob.screenshot({path:'target/relay-v13-proof/mobile-friend-details.png'});
  if (errors.length) throw new Error(errors.join('\n'));
  return {signedRoutesVerified:true, requestRequiredApproval:true, approvedChatReceived:true, mobileFriendsScreenshot:true, pageErrors:errors};
}
