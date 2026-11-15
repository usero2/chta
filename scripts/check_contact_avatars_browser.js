// Use a disposable playwright-cli session, never an existing user browser profile.
async page => {
  await page.goto('http://localhost:7357/');
  await page.waitForFunction(() => !!globalThis.chtCore);
  const fixture = await page.evaluate(async () => {
    await chtCore.ready;
    if (await chtCore.hasIdentity()) throw new Error('This check requires a fresh browser context');
    const local = JSON.parse(await chtCore.createIdentity());
    await chtCore.confirmRecovery(local.mnemonic);
    const jpeg = (size, color) => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = size;
      const context = canvas.getContext('2d');
      context.fillStyle = color;
      context.fillRect(0, 0, size, size);
      return canvas.toDataURL('image/jpeg', 0.35).split(',')[1];
    };
    const ownPhoto = jpeg(256, '#8fd779');
    const thumbnail = jpeg(48, '#3c8cd7');
    localStorage.setItem('cht.profile', JSON.stringify({name: 'Preview User', avatar: ownPhoto}));
    localStorage.setItem('cht.profile-name', 'Preview User');
    const {AccountCore} = await import('/wasm/cht_core.js');
    const peer = new AccountCore();
    const created = JSON.parse(peer.createIdentityJson());
    const secret = peer.confirmRecovery(created.mnemonic);
    secret.fill(0);
    const card = peer.contactCardJsonWithProfile('Preview Friend', thumbnail);
    const inspected = JSON.parse(await chtCore.inspectContactCard(card));
    if (inspected.card.avatar !== thumbnail) throw new Error('Signed avatar did not survive verification');
    await chtCore.addContact(card, '');
    const ownCard = await chtCore.contactCard('Preview User', thumbnail);
    if (new TextEncoder().encode(ownCard).length > 2953) throw new Error('Contact card exceeded QR byte capacity');
    peer.free();
    return {peerId: inspected.identityId, cardBytes: new TextEncoder().encode(ownCard).length};
  });
  await page.goto('http://localhost:7357/contacts');
  await page.waitForFunction(() => !!document.querySelector('flt-glass-pane'));
  const accessibility = page.locator('flt-semantics-placeholder');
  if (await accessibility.count()) await accessibility.evaluate(node => node.click());
  await page.getByRole('img', {name: 'Preview User avatar', exact: true}).waitFor();
  await page.getByRole('img', {name: 'Preview Friend avatar', exact: true}).waitFor();
  await page.goto(`http://localhost:7357/chats/${encodeURIComponent(fixture.peerId)}`);
  await page.waitForFunction(() => !!document.querySelector('flt-glass-pane'));
  const chatAccessibility = page.locator('flt-semantics-placeholder');
  if (await chatAccessibility.count()) await chatAccessibility.evaluate(node => node.click());
  await page.getByRole('img', {name: 'Preview Friend avatar', exact: true}).first().waitFor();
  return {signedAvatarVerified: true, ownProfileVisible: true, friendAvatarVisible: true, chatAvatarVisible: true, cardBytes: fixture.cardBytes};
}
