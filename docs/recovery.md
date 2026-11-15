# Recovery and browser key storage

The recovery phrase is placed directly into 24 numbered, editable fields during identity creation and must match the pending identity before it is persisted. The user may generate a fresh random phrase repeatedly; each replacement updates all 24 fields and discards the previous pending identity. Restore accepts only a valid 24-word English BIP-39 phrase. The phrase is never sent to a server.

The optional `.txt` download is intentionally preceded by a warning. That file is plaintext and grants control of the identity to anyone who obtains it; it should be stored offline and unsafe copies should be deleted.

The persisted secret contains the entropy, derivation version, and random contact token. On Web it is encrypted with AES-256-GCM using a non-extractable WebCrypto `CryptoKey`. The key and ciphertext are stored in separate IndexedDB object stores. Plaintext buffers are overwritten after encryption/decryption where the platform permits.

This design protects against a simple raw IndexedDB export. It does not protect against active XSS, a malicious same-origin script, a compromised browser profile, or a running unlocked device, because same-origin code can ask WebCrypto to use the non-extractable key. JavaScript strings used to display or enter the mnemonic cannot be reliably zeroized.

If both the recovery phrase and browser profile are lost, the identity cannot be recovered. There is no server-side reset.
