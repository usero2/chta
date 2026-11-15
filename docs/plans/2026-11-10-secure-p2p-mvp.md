# Secure P2P MVP implementation plan

## Scope

Implement the requested Web-first sequence: identity/recovery, contacts, manual WebRTC signaling, authenticated Noise sessions, and 1:1 delivery states. This is a prototype and must not be described as independently audited or production-ready.

## Security decisions

- Generate 256-bit entropy with the operating system/browser CSPRNG and encode it as a 24-word English BIP-39 mnemonic.
- Derive an Ed25519 root signing key and X25519 Noise static key with HKDF-SHA256 using versioned `cht` domain-separation labels.
- Define the application-specific identifier as `did:cht:<lowercase SHA-256 hex of root public key>`; it is not a registered W3C DID method.
- Encrypt the persisted identity secret with AES-256-GCM using a non-extractable WebCrypto key stored as a `CryptoKey` in IndexedDB. This protects a raw IndexedDB export, but not a compromised same-origin application or active XSS.
- Sign contact cards with the root Ed25519 key. A fingerprint is a grouped SHA-256 digest of the root public key.
- Use browser `RTCPeerConnection`/DataChannel as the Web transport. Manual copy/paste exchanges complete SDP. STUN is configurable and has no mandatory provider.
- Use `snow` with `Noise_KK_25519_ChaChaPoly_SHA256` after signed contact cards have bound each peer's Noise static key to its identity. `snow` states that it has not received a formal audit, so this remains a staged prototype rather than a Signal-compatible implementation.
- Define statuses precisely: Pending = stored locally but not accepted by an authenticated channel; Sent = encrypted frame accepted by DataChannel; Delivered = authenticated peer returned an acknowledgement for the message ID; Failed = a local send attempt failed. Retry reuses the message ID and receivers suppress duplicates.

## Work sequence

1. Add Rust identity/recovery tests and implementation, including deterministic restore and invalid mnemonic/version handling.
2. Add encrypted browser secret storage and identity WASM/Flutter bridge.
3. Add onboarding UI for create, confirm, restore, and identity display.
4. Add signed contact-card models, verification, persistence, add/remove operations, QR display, camera scan, and fingerprint UI.
5. Add a browser WebRTC adapter with configurable STUN and copy/paste offer/answer UI.
6. Add authenticated Noise handshake over the DataChannel.
7. Add encrypted outbound/inbound messages, acknowledgements, statuses, retry, and duplicate detection.
8. Add unit/widget/browser tests, threat/limitation documentation, and local commits. Do not configure a Git remote.
