# Identity

`cht` uses a person-centric root identity that does not require a phone number, email address, username, or central account.

## Version 1 derivation

1. Generate 32 bytes of entropy from `getrandom`, which maps to the browser CSPRNG on WebAssembly.
2. Encode the entropy as a 24-word English BIP-39 mnemonic with `bip39` 3.0.0.
3. Convert the mnemonic to the standard BIP-39 seed with an empty BIP-39 passphrase.
4. Apply HKDF-SHA256 with salt `cht identity derivation v1` and separate info labels:
   - `cht/root-ed25519/v1` for the Ed25519 root signing key.
   - `cht/noise-x25519/v1` for the X25519 Noise static key.
5. Compute `did:cht:<lowercase SHA-256 hex of the 32-byte Ed25519 public key>`.

`did:cht` is an application-specific identifier and is not a registered W3C DID method. The derivation version is stored and unsupported versions fail closed.

The same mnemonic restores the same identifier and keys. A restored installation receives a new random contact token.
