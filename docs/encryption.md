# Encrypted 1:1 messaging prototype

The application-layer session uses `snow` 0.10.0 with `Noise_KK_25519_ChaChaPoly_SHA256`. Signed contact cards bind each peer's Noise static public key to its Ed25519 root identity before the handshake starts.

`snow` implements the Noise Protocol Framework but its maintainers state that it has not received a formal audit. This implementation is therefore a staged prototype, is not Signal Protocol compatible, has no Double Ratchet, and does not claim post-compromise security or independent audit.

Delivery states mean:

- `Pending`: queued locally but not yet accepted by an authenticated transport.
- `Sent`: encrypted ciphertext was accepted by the WebRTC or Desktop companion transport.
- `Delivered`: the authenticated peer decrypted the envelope and returned its message ID as an acknowledgement.
- `Failed`: the local send attempt threw an error; retry is available.

Retries reuse the message ID and create a fresh Noise transport frame. The receiver tracks IDs for the active session, suppresses duplicate display, and acknowledges duplicates. Persisted history also suppresses duplicate message IDs per friend. A reconnect establishes a new Noise session; session keys are not persisted.

## Local friend history

Messages display sent and received timestamps as local `yyyy-MM-dd HH:mm:ss.fff` values. The sender's epoch-millisecond timestamp is carried inside the encrypted envelope; the receiver records its first receive time and returns it in the receipt. Both values persist in history schema 2. Missing times from older clients or history display as an em dash. Schema 1 incoming timestamps were local receive times, so migration does not relabel them as remote send times. Device clocks are not synchronized by cht.

Friend conversations share the Chats sidebar with local rooms. Sent and received text, direction, timestamp, and delivery status are saved per local identity and peer DID. History remains readable while offline and after reopening the application on the same device. Previously pending or sent messages without a delivery acknowledgement become retryable failures after reopening.

Web history is encrypted with AES-GCM in IndexedDB using the existing non-extractable device wrapping key. The local identity DID is authenticated as additional data. Windows history is encrypted with user-scoped DPAPI and saved under `%APPDATA%\\cht\\history`. History is local to that browser profile or Windows user; a recovery phrase does not transfer message history to another device. Saved conversation names do not restore contact verification or signed contact cards.

Messages from versions that only kept P2P history in UI memory cannot be recovered after that page or process has closed.
