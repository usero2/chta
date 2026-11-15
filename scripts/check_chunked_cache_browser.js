// Run against a disposable localhost server rooted at this worktree:
// playwright-cli -s=cht-chunk-test run-code --filename=scripts/check_chunked_cache_browser.js
async page => {
  await page.goto('http://127.0.0.1:41739/');
  return await page.evaluate(async () => {
    const source = await (await fetch('/apps/flutter_app/web/cht_core_loader.js')).text();
    const transformed = source
      .replace(/^import .*;\s*/m, '')
      .replace('let account;', `let account = {
        hasIdentity: () => true,
        identityJson: () => JSON.stringify({id: globalThis.__chunkOwner}),
      };`)
      .replace(/const ready = \(async \(\) => \{[\s\S]*?\}\)\(\);/, 'const ready = openDatabase();');
    globalThis.__chunkOwner = 'disposable-owner-1';
    (0, eval)(transformed);
    const core = globalThis.chtCore;
    const owner = globalThis.__chunkOwner;
    const id = 'disposable_chunk_1234';
    await core.beginChunkedAttachment(owner, id, 5, 3);
    const database = await core.ready;
    const originalTransaction = database.transaction.bind(database);
    database.transaction = (stores, mode) => {
      if (mode === 'readwrite') throw new DOMException('Synthetic quota', 'QuotaExceededError');
      return originalTransaction(stores, mode);
    };
    let rejected = false;
    try { await core.writeChunkedAttachment(owner, id, 0, new Uint8Array([1, 2, 3])); }
    catch (error) { rejected = error.name === 'QuotaExceededError'; }
    database.transaction = originalTransaction;
    if (!rejected || JSON.parse(await core.chunkedAttachmentStatus(owner, id)).contiguousChunks !== 0) {
      throw new Error('Quota failure advanced durable progress');
    }
    await core.writeChunkedAttachment(owner, id, 0, new Uint8Array([1, 2, 3]));
    await core.writeChunkedAttachment(owner, id, 0, new Uint8Array([1, 2, 3]));
    const state = JSON.parse(await core.chunkedAttachmentStatus(owner, id));
    if (state.contiguousChunks !== 1 || state.completed) throw new Error('Progress is wrong');
    rejected = false;
    try { await core.writeChunkedAttachment(owner, id, 0, new Uint8Array([3, 2, 1])); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Conflicting retry was accepted');
    globalThis.__chunkOwner = 'disposable-owner-2';
    rejected = false;
    try { await core.readChunkedAttachment(owner, id, 0); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Old owner could read cache');
    globalThis.__chunkOwner = owner;
    const records = await new Promise((resolve, reject) => {
      const request = database.transaction('secrets').objectStore('secrets').getAll();
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    if (!records.some(record => record?.ciphertext?.byteLength === 19 &&
        record.iv?.byteLength === 12)) {
      throw new Error('Encrypted chunk record is missing');
    }
    await core.writeChunkedAttachment(owner, id, 1, new Uint8Array([4, 5]));
    const digest = '74f81fe167d99b4cb41d6d0ccda82278caee9f3e2f25d5e5a3936ff3dcec60d0';
    const complete = JSON.parse(await core.finishChunkedAttachment(owner, id, digest));
    if (!complete.completed || complete.digest !== digest) throw new Error('Finish failed');
    const keys = [];
    await new Promise((resolve, reject) => {
      const request = database.transaction('secrets').objectStore('secrets').getAllKeys();
      request.onsuccess = () => { keys.push(...request.result); resolve(); };
      request.onerror = () => reject(request.error);
    });
    const chunkKey = keys.find(key => String(key).endsWith(`${id}:chunk:0`));
    const record = await new Promise((resolve, reject) => {
      const request = database.transaction('secrets').objectStore('secrets').get(chunkKey);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    record.ciphertext = record.ciphertext.slice(0);
    new Uint8Array(record.ciphertext)[0] ^= 1;
    await new Promise((resolve, reject) => {
      const transaction = database.transaction('secrets', 'readwrite');
      transaction.objectStore('secrets').put(record, chunkKey);
      transaction.oncomplete = resolve;
      transaction.onerror = () => reject(transaction.error);
    });
    rejected = false;
    try { await core.readChunkedAttachment(owner, id, 0); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Tampered chunk was accepted');
    rejected = false;
    try { await core.chunkedAttachmentStatus(owner, id); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Status claimed tampered completed chunks');
    rejected = false;
    try { await core.beginChunkedAttachment(owner, id, 5, 3); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Begin resumed tampered completed chunks');
    await new Promise((resolve, reject) => {
      const transaction = database.transaction('secrets', 'readwrite');
      transaction.objectStore('secrets').delete(chunkKey);
      transaction.oncomplete = resolve;
      transaction.onerror = () => reject(transaction.error);
    });
    rejected = false;
    try { await core.chunkedAttachmentStatus(owner, id); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Status claimed missing completed chunk');
    rejected = false;
    try { await core.beginChunkedAttachment(owner, id, 5, 3); }
    catch (_) { rejected = true; }
    if (!rejected) throw new Error('Begin resumed missing completed chunk');
    await core.deleteChunkedAttachment(owner, id);
    return {encryptedRecords: true, exactRetry: true, ownerSwitch: true,
      quotaProgress: true, tamperRejected: true, missingRejected: true,
      completeAndDelete: true};
  });
}
