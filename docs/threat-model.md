# Prototype threat model

## Protected assets

- Recovery entropy and root/device private keys.
- Contact authenticity and verified fingerprints.
- Message plaintext in transit.
- Message IDs and delivery integrity.

## Current mitigations

- Standard BIP-39, HKDF-SHA256, Ed25519, X25519, SHA-256, AES-GCM, and Noise libraries; no custom cryptographic primitive.
- Versioned domain separation and strict input validation.
- Signed contact cards and explicit fingerprint verification before connection.
- Non-extractable browser wrapping key and authenticated encryption for persisted identity secrets.
- Noise authenticated encryption above WebRTC DTLS.
- Message-ID duplicate suppression and authenticated acknowledgements.
- No recovery phrase, private key, or plaintext message logging.

## Known risks and limitations

- No independent security audit; `snow` itself reports no formal audit.
- XSS or compromised same-origin code can use the WebCrypto key and access unlocked WASM memory/UI input.
- Manual SDP and STUN reveal network metadata; TURN is absent.
- No Double Ratchet, forward-secrecy rotation after the Noise session, multi-device certificate/revocation, offline relay, or persisted encrypted P2P queue.
- Duplicate tracking lasts only for the active session.
- Contact verification depends on the user comparing fingerprints over a trustworthy channel.
- Denial of service and malicious oversized signaling/message inputs need additional limits before production.
