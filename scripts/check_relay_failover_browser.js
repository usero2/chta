// Stop only the active relay reported by check_relay_mesh_browser.js first.
async page => {
  const contexts = page.context().browser().contexts().filter(context => context !== page.context());
  const pages = contexts.flatMap(context => context.pages());
  if (pages.length !== 2) throw new Error('Run check_relay_mesh_browser.js first');
  const proof = {pages,failures:[]};
  for (const target of pages) target.on('pageerror', error => proof.failures.push(error.message));
  const [alice,bob] = proof.pages;
  for (const target of proof.pages) {
    await target.getByText('Connected securely', {exact:true}).first().waitFor({timeout:30000});
  }
  // The route can look connected until the socket close is processed; give
  // transport failover one retry interval before sending the next message.
  await alice.waitForTimeout(7000);
  for (const target of proof.pages) await target.getByText('Connected securely', {exact:true}).first().waitFor({timeout:30000});
  const composer = alice.getByRole('textbox').last();
  await composer.fill('Real Rust Noise relay after failover'); await composer.press('Enter');
  await bob.waitForFunction(() => document.body.innerText.includes('Real Rust Noise relay after failover'), {timeout:15000});
  await bob.screenshot({path:'target/relay-browser-proof/after-failover.png'});
  if (proof.failures.length) throw new Error(proof.failures.join('\n'));
  return {automaticFailover:true, freshWasmNoiseSession:true, encryptedMessageReceived:true, pageErrors:proof.failures};
}
