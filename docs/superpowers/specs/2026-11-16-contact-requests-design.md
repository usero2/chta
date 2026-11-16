# One-sided contact requests

## User decisions

- Adding a friend on one device sends a request; the recipient chooses Review, then Accept or Decline.
- Accept adds the sender back and starts normal secure connection setup. No invitation room or manual reciprocal QR exchange is needed.
- Requests remain encrypted on the sender's device and retry while both apps are online. The seed forwards live packets and does not keep an offline request mailbox.
- Apply the same behavior to Windows, Android and Web. Keep the compact interface and existing contact aliases.

## Flow

1. Scan, import or paste a signed contact card, then confirm Add friend. Confirmation authorizes that identity; the signature/DID is always verified in Rust. The fingerprint remains available for comparison. Do not claim that a comparison occurred automatically.
2. Persist an owner-bound outgoing request before sending. Show Request pending rather than falsely declaring the peer offline.
3. Forward a bounded, signed, encrypted contact-setup packet over the existing authenticated seed socket.
4. The receiver verifies and decrypts the packet, persists a pending request, and shows a Friend requests badge with Review. No contact or chat session is authorized yet.
5. Review displays the signed name, avatar and fingerprint. Accept persists the contact and decision before acknowledging; Decline never authorizes the sender.
6. The sender receives an authenticated decision, updates request state, and retries normal Direct/community-relay connection setup. A lost acknowledgement is recovered by repeating the same stable request ID.

An existing verified mutual contact may acknowledge immediately. A declined request ID must not reappear as a new pending request. Existing contacts and histories are retained. Existing contacts can explicitly Send request from an unreachable chat; do not broadcast requests to every saved contact on upgrade.

## Cryptographic boundary

Use the existing Rust `snow` dependency and identity-derived X25519 static keys. Each contact-setup packet is an independent Noise IK initial message carrying only the sender's signed ContactCard, with a fresh ephemeral key. The receiver's signed card is known from the original QR or verified request. The decrypted sender static key must equal the card's signed static key. The card's root/DID must equal the outer Ed25519 signer.

Bind the protocol version, sender, recipient, stable request ID, packet ID, kind and time window into the Noise prologue and outer signature. A response uses a fresh independent packet rather than persisting a half-completed Noise handshake. Handshake objects are discarded; private identity keys remain in Rust. This is a setup-metadata packet, not the encrypted chat session. Its initial-message confidentiality does not provide forward secrecy after recipient static-key compromise.

References: [Noise handshake patterns and zero-RTT encryption](https://noiseprotocol.org/noise.html), [snow 0.10 Builder](https://docs.rs/snow/0.10.0/snow/struct.Builder.html).

## Wire and seed

Use an isolated version-2 `contacts` topic inside the existing `signal` frame. Preserve direct version 1 and groups version 2 byte formats. Allow only request, received, accepted and declined setup kinds with exact schemas, canonical signatures, a maximum 120-second network TTL and 16-KiB envelope limit. A stable 32-hex request ID is separate from each fresh 32-hex packet nonce.

The seed verifies authenticated ownership, topic, schema, size, TTL, signature and existing rate limits, then forwards to currently connected recipient sessions. Persist only existing bounded replay hashes/expiry, rate buckets and relay catalog; never store the request payload, public card or an offline mailbox. A missing recipient is normal and leaves the local request pending.

Do not add another socket per identity. Old clients ignore this separate topic; they need the new app to show Review. Unknown setup packets must not enter the existing trusted chat signaling path.

## Local state and retry

Use the existing protected blob bridge with a dedicated owner-bound key. It is encrypted with Windows protection, Android Keystore protection or the Web encrypted IndexedDB store. Persist incoming/outgoing records and decisions; keep all mutations serialized. Save before sending or showing a success state. A storage failure remains visible and must not be acknowledged as durable.

Bound state: 64 outgoing requests, 64 incoming pending requests and 256 completed decisions; maximum state document 4 MiB. Keep one current outgoing request per recipient. Duplicate requests preserve the first review card and return the stored decision. Cap incoming processing queues and retry a small rotating batch with backoff. Closing or switching identity cancels retries and rejects stale asynchronous results.

## UI and connection status

Contacts lists pending incoming requests with Review. A global request banner/badge stays accessible from chats. Review offers Accept and Decline; incoming packets never open a conversation automatically. User acceptance may open that contact's chat. Sender acceptance refreshes the current chat without navigating away from another room.

Separate Request pending, Waiting for approval, Connecting and a usable encrypted chat. Seed presence is discovery availability; a successful request does not prove WebRTC or a community relay route is usable. Retain this distinction while investigating the original unreachable-friend report.

## Validation and delivery

Test ciphertext privacy, sender/card/static binding, wrong-recipient and tamper rejection, expiry/schema limits, no pre-Accept trust, decline/retry/deduplication, crash/restart persistence, storage failures and identity switches. Test actual Rust packets across native and WASM boundaries and the seed's forwarding/no-payload-storage behavior. Exercise UI on narrow and wide layouts.

Build all supported platforms and a backwards-compatible seed. Keep user data, private captures, credentials and local compiler paths out of Git and release artifacts. Test with synthetic identities; do not send messages or requests to a real friend on the user's behalf during automated verification.
