# Windows Desktop identities and PIN login

After restoring or confirming a new identity, Desktop asks for a profile name and a 6–12 digit PIN, entered twice. Saving completes setup. The next app launch lists saved identities with their name, thumbnail and DID; select one and enter its PIN. A recovery phrase is only needed for recovery or adding/restoring another identity.

Profile → **Switch identity / Lock** saves pending history, stops the native listener, drops the active account and session keys, and returns to the identity picker. The next identity loads its own profile, contacts, aliases, verification state and local rooms. Existing per-DID friend history remains in its encrypted local history store.

After identity unlock, Desktop automatically starts its listening/relay service with the active signed profile. The login PIN is not a relay access PIN. **Connect → Stop listening** stops the service for the current session; see [networking behavior and reachability limits](networking.md).

## Storage

- `%APPDATA%\cht\identities\<DID hash>.json`: public selection metadata, a random salt, a DPAPI-protected identity secret, and failed-attempt/cooldown state. No plaintext PIN, mnemonic, entropy or private key is written here.
- The PIN is processed with RustCrypto Argon2id v1.3, 64 MiB memory, three passes, one lane and a 32-byte output. This output and the DID are supplied as DPAPI additional entropy. Windows user-scoped DPAPI protects and authenticates the secret; unlocking requires the PIN and the same Windows user protection context. Secret/key buffers in Rust are cleared on release where possible.
- `%APPDATA%\cht\accounts\<DID hash>.bin`: DPAPI-protected profile, contact state and local room state. The account DID is the protection context. Access from the application follows successful identity unlock; this file is not independently PIN-encrypted.
- `%APPDATA%\cht\history\...`: existing DPAPI-protected friend history, already partitioned by DID.

Five incorrect PIN attempts trigger a persisted 30-second cooldown. Successful PIN login clears the failure counter. **Forgot PIN? Restore with recovery phrase** permits setting a new PIN for the recovered DID while retaining its readable local account state. Public identity metadata does not include the secret.

The first saved identity can adopt the old single `profile.json`; subsequent new identities start with a separate profile. The legacy file is retained. Previously in-memory-only contact state cannot be recovered from a closed older process. The vault is local to Windows; a recovery phrase remains necessary when moving to another computer or when Windows protection keys are unavailable. This does not change the browser identity flow.

This protects stored files and enforces the app's PIN login. It does not protect an unlocked app from malware running as the same Windows user, nor make a short PIN equivalent to a high-entropy recovery phrase.

Implementation references: [Microsoft CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata), [RustCrypto Argon2](https://docs.rs/argon2/0.5.3/argon2/).
