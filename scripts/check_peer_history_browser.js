// Run in a disposable playwright-cli session against the built Web app:
// playwright-cli -s=cht-history-check run-code --filename=scripts/check_peer_history_browser.js
async page => {
  const owner = 'did:cht:history-test-owner';
  const history = {
    version: 1,
    names: {'did:cht:history-test-peer': 'Test friend'},
    rooms: {
      'did:cht:history-test-peer': [{
        id: 'browser-history-test-message', text: 'Saved private test message ไทย',
        incoming: false, status: 'delivered', sentAtMilliseconds: 123456789,
      }],
    },
  };
  await page.waitForFunction(() => !!globalThis.chtCore);
  const stored = await page.evaluate(async ({owner, history}) => {
    await chtCore.ready;
    await chtCore.savePeerHistory(owner, JSON.stringify(history));
    const database = await chtCore.ready;
    const record = await new Promise((resolve, reject) => {
      const request = database.transaction('secrets').objectStore('secrets')
        .get(`peer-history:${owner}`);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    return {
      encrypted: record.ciphertext instanceof ArrayBuffer &&
        !new TextDecoder().decode(record.ciphertext).includes('Saved private test message'),
      ivBytes: record.iv.length,
    };
  }, {owner, history});
  if (!stored.encrypted || stored.ivBytes !== 12) throw new Error('History was not encrypted');
  await page.reload();
  await page.waitForFunction(() => !!globalThis.chtCore);
  const restored = await page.evaluate(async owner => ({
    history: JSON.parse(await chtCore.loadPeerHistory(owner)),
    otherIdentity: await chtCore.loadPeerHistory('did:cht:another-history-test-owner'),
  }), owner);
  if (JSON.stringify(restored.history) !== JSON.stringify(history)) {
    throw new Error('History changed after reloading the page');
  }
  if (restored.otherIdentity !== '') throw new Error('History leaked to another identity');
  return {encryptedAtRest: true, restoredAfterReload: true, isolatedByIdentity: true};
}
