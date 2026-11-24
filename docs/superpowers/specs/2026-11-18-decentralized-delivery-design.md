# Decentralized delivery, Courier and gap repair

Status: approved by the owner on 2026-11-18; Native inline implementation in progress.

## Intent and accepted scope

The owner asked to implement the selected BitChat-inspired concepts: transport routing, Courier delivery, missing-message reconciliation, relay resilience, and privacy-preserving local diagnostics. They explicitly excluded Bluetooth mesh. Work order is seed-quota repair, routing/provider resilience, Courier, then reconciliation; diagnostics accompany those changes.

Two owner decisions override the initial proposal:

- Every unlocked Desktop automatically offers Courier service; hosting is not restricted to an opt-in verified-friends list.
- Files are deposited as encrypted subpackages and must be distributed across at least two Courier nodes. One node must never be assigned the entire package set. With fewer than two eligible nodes, work remains on the sender and visibly waits.

Continue the existing Rust core, shared Flutter clients, protected identity/history/cache, and Native inline implementation workflow. Android and Web/Wasm are Courier deposit/pickup clients; Desktop additionally hosts. No paid TURN/service/billing upgrade, Bluetooth, public Git publication, owner-contact test sends, or destructive owner-data migration.

## Existing behavior and motivating evidence

Build 43 has durable sender intent, authenticated Direct and data-relay paths, category-separated send budgets, transfer controls, protected incremental history, and bounded cache reservations. A seed connection is deliberately not recipient-delivery evidence. Public data relays currently share one infrastructure provider.

Physical Android testing on a different Internet uplink passed bidirectional text, encrypted streamed files with matching hashes, pause/resume, text during pause, and relay-route recovery. Direct signaling exchanged SDP/ICE but did not establish a channel. Separately, the public seed returned HTTP 500 on WebSocket Upgrade because its Durable Object control-storage read raised a Free-tier rows-written quota exception. Ordinary HTTP metadata still returned successfully.

The current seed synchronously loads a shared control object, writes it on registration/lookup/keepalive/catalog/signal, and uses storage alarms. The persisted exact replay reservation currently precedes legacy signal forwarding. Removing persistence without replacing that replay contract would be a security regression.

## Approaches considered

1. Keep only live links and improve retries. Low protocol impact, but both peers must overlap online and the owner-requested Courier is absent. Rejected as the complete solution; retained as the immediate routing foundation.
2. Add an encrypted central mailbox. Simpler availability, but it changes the discovery-only seed role and introduces mandatory central storage/cost. Rejected.
3. Add bounded, automatically hosted Desktop Couriers and common message identities over the existing authenticated network. This is the selected direction, refined by the owner's automatic-hosting and two-node distribution decisions. It adds storage and protocol complexity, but preserves a discovery-only seed and user-operated data carriage.

## 1. Seed operation without mandatory SQL writes

### Session-bound dispatch

Introduce a negotiated `session-dispatch-v1` capability while preserving the existing seed URL and signed inner SDP/contact/group envelopes. The server challenge supplies its fresh connection nonce. A new Rust signing operation produces a domain-separated Ed25519 dispatch proof binding seed ID, connection nonce, strictly increasing safe-integer sequence and SHA-256 of the exact canonical inner envelope. The Worker verifies the proof against the root key that authenticated this WebSocket.

The server consumes the sequence before forwarding and serializes the connection nonce, sequence high-water mark, identity, bounded rate state and only other necessary connection metadata in a <=2 KiB WebSocket attachment. Reconstruction must preserve this state. A captured dispatch is invalid on another socket or seed. Invalid, stale, repeated or out-of-order dispatches never forward. Clients and recipients retain existing signed-envelope validation and deduplication.

Strict replay properties refer to authenticated dispatches; an authorized sender intentionally re-signing an old message under a new dispatch does not create a second application message. Receiver message IDs and endpoint replay checks remain authoritative. This distinction is explicit and tested.

### Ephemeral discovery and compatibility

New-client registration, lookup, keepalive, dispatch and signed discovery advertisements must work when all SQL get/put/alarm methods fail. Discovery catalogs are signed, expiring hints recoverable from connected clients; they are not mandatory durable database state. Seed restart may lose such hints and request republishing. The seed still stores/forwards no chat payload, file package, mailbox job or receipt.

Legacy clients retain the current durable legacy replay path where storage is available. If it cannot reserve a legacy replay safely, forwarding fails closed with a bounded, explicit upgrade/storage-unavailable response; it must not silently accept legacy signals with weaker protection or generate uncaught constructor errors. Legacy ordinary data-relay chat remains compatible. Updated smoke tests must exercise both new zero-SQL dispatch and available-storage legacy behavior.

Authenticated per-socket rate state survives hibernation. Global unauthenticated IP throttling is bounded best-effort when no persistent store is available; this limitation must be documented rather than presented as globally durable rate protection. Cap pending authentication, total sockets, queued crypto work, frame bytes and signature-verification work independently. Never recover quota by deleting identity/user data, raising billing, or accepting unsigned arbitrary content.

## 2. Common delivery identity and routing

Use a versioned application delivery envelope with immutable author, conversation scope, message ID, original sent time, content kind and payload digest. New messages store a forwardable author signature produced in Rust. Delivery retries, Courier copies and gap repair reuse this identity. Preserve v43 IDs/timestamps/history; do not re-sign another author's legacy history as that author.

Route selection considers an authenticated usable channel and actual receipt progress, separately from socket/seed presence. Prefer a healthy Direct route, then eligible live relays; fall back without waiting for an entire slow file negotiation. Keep the existing text/file fairness and transfer-scoped controls. Use bounded receipt deadlines, backoff with jitter, cooldown and hold-down before restoring a failing route. Do not repeatedly destroy a healthy authenticated channel because another route appeared.

The sender outbox remains authoritative until a valid recipient receipt is durably recorded. A successful socket write, relay ACK or Courier storage ACK does not set Delivered.

### Provider resilience

Separate known-relay capacity from actively connected/warm-relay capacity. Add local operator/failure-domain configuration and select warm routes from distinct configured domains when available. Keep trust pins, signed catalogs, user locks and URL safety checks. Unknown provider classification is not proof of independent infrastructure, and multiple URLs on one provider must not be advertised as provider redundancy.

Provide a portable self-hosted relay configuration and tests using independent relay processes. No reachable non-Cloudflare public endpoint/account is currently available in the session. Do not invent one, claim one was deployed, or spend money. The client/operator capability can be complete while actual public provider diversity remains an explicitly documented deployment dependency.

## 3. Courier identity, discovery and automatic hosting

An unlocked Desktop starts one account-owned Courier host after protected storage has loaded. Lock/switch/quit stops hosting and prevents callbacks from reviving the old account. Profile/Connect offers a Stop control and shows capacity. A manual stop remains respected for the current session. Android/Web do not pretend to host a persistent Desktop service.

Each installation has a protected device signing key and a root-signed Courier node certificate. Reuse the existing device-certificate primitive where feasible, with a distinct Courier context/capability. Node identity is not a URL; aliases for one certificate count as one node. Two certified node identities do not cryptographically prove two physical machines or independent operators; collusion/Sybil resistance is not claimed.

Desktop advertises a signed, expiring capability record containing node certificate, routes, protocol version, maximum package size and available service class. Advertisements are discovery metadata, carried through the seed and authenticated relay-catalog exchange. The seed does not receive payload packages.

Courier control/data uses reserved, versioned routed frames on the existing WebSocket data-relay network, independently authenticated with device/root signatures and fresh challenges. It must not auto-add strangers to Contacts or bypass existing private-chat verification. Root/device keys remain in Rust. A malicious relay cannot spoof a package, allocation, storage ACK, pickup or receipt. Sender and recipient authorization are bound to job/package identities and expiry.

## 4. End-to-end sealed packages and two-node distribution

### Cryptography and storage

Rust generates a fresh random content key per Courier job. Encrypt content with the existing reviewed AEAD library (XChaCha20-Poly1305), unique nonces and domain-separated associated data binding the job, package index/count, conversation scope and expiry. Use established Noise IK recipient sealing, with the recipient's pinned key and verified sender identity, for the private manifest/content key. Existing live Noise-session ciphertext must not be reused as an offline envelope.

The sealed manifest binds the original delivery envelope, package ciphertext hashes, original file size/hash, ordered reconstruction metadata and expiry. Couriers never receive the content key or plaintext manifest, filename, caption or message body. Package hashes are hashes of randomized ciphertext, not public plaintext-file fingerprints. All Courier-held data is also stored in protected local storage.

Static-key offline manifest sealing does not promise forward secrecy against later recipient-key compromise. Prekeys/ratchets require a separate design; do not claim that property in this version. Keep live-session encryption and existing group key/epoch rules unchanged.

### Packages, allocation and retries

Builder defaults: package payload <=256 KiB, bounded wire fragments <=8 KiB compatible with existing relay frame limits; job/file maximum remains within the current 10 GiB streamed-file ceiling and available quotas. Small content is split into at least two packages as well. A signed allocation binds package indexes to the selected node certificates. No selected node receives the complete package set, including after reallocation/retry; persist the ever-assigned set per node. Duplicate URLs or reconnects do not create additional nodes.

With two nodes, partition packages across them and require both assigned sets for completion. With three or more available nodes, balanced replication may tolerate a missing node only if no individual node obtains every package; use at least as many packages as needed for that invariant. Explicit erasure coding is not required. If the invariant cannot be satisfied, retain sender intent and display waiting rather than weakening it.

Do not begin deposit until two distinct eligible nodes are available. If a node fails mid-deposit, retain the partial encrypted deposits and sender state, retry missing pieces to a valid second/replacement node, and preserve the never-full-set invariant. Do not label partially deposited work as fully carried. Reassembly only occurs at an authorized recipient, which verifies every package, the manifest, sender and final content digest before publishing to history and issuing a receipt.

Receiving partial packages is bounded; it must not reserve unrestricted memory or allow strangers to exhaust chat capacity. Text/control traffic retains priority over Courier bulk work. Pause/Resume/Cancel apply to the whole logical sender job and persist across restart. Cancelling or expiring a Courier job never deletes the sender's original file/chat history.

### Addressing and receipts

Use an opaque mailbox tag derived from the recipient's signed contact token/root key and a time bucket; do not store a clear recipient DID/name in a deposit index. An authenticated pickup proves possession of the matching recipient key and mailbox binding. This minimizes stored routing metadata, but carriers may still observe IPs, sizes, timing and associations during pickup; anonymity or operator independence is not promised.

A storage ACK is sent only after package/allocation metadata is durable. After receiving/reconstructing a job, the recipient durably saves history and attachments, then signs a receipt bound to job ID, application message ID, manifest digest and received time. Sender verifies the pinned recipient identity before Delivered. Receipts can travel back through live routes or Couriers when the sender returns. Carriers retain enough bounded receipt state to resolve duplicate pickup; do not recreate deleted history or turn a terminal cancellation into an invented delivery. A genuinely late valid receipt still records real delivery.

### Bounds and lifecycle

Builder defaults: retention 24 hours, 1 GiB total Courier capacity per Desktop identity, 256 MiB per depositing root identity, <=4 active assembly jobs and <=16 concurrent deposit requests. Apply both byte/count caps, known free-space reserve and the shared cache budget. Expose the local capacity setting. Refuse excess work explicitly without evicting owner history or silently accepting bytes. Package TTL applies to third-party Courier copies; their expiry/ack cleanup is separate from owner-history retention. A 10 GiB file is not guaranteed to fit small Courier quotas: wait for sufficient eligible capacity and show why.

All job/manifest/package indexes are bounded protected pages, not one growing 8 MiB blob. Write data before indexes, preserve prior readable commits on failure, reconcile staging reservations after crashes, and release capacity only after successful cleanup of those staging/Courier objects. Keep monotonic accounting if progress overlaps an awaited settings write.

## 5. Missing-message and group repair

On authenticated reconnect, compare bounded conversation inventories/high-water marks and request missing message identities in pages. Start with exact IDs/digests; a probabilistic summary may optimize later but cannot be the only correctness check. Canonical author signatures and payload hashes prevent conflicting duplicate content. Replaying a transfer creates no duplicate bubble, notification, timestamp or receipt downgrade.

Preserve tombstones: deleted conversations/messages are not resurrected by repair or Courier pickup. New signed delivery envelopes can be forwarded by authorized holders. Legacy unsigned 1:1 history may only be repaired through its authenticated original author, never attested as authored by a third-party cache.

Integrate direct 1:1 rooms and authenticated group events. Group inventories/backfill and Courier manifests are membership/epoch scoped. A removed/banned member cannot request later-epoch history or packages. Group content stays in its existing encrypted/signed domain; files continue to use verified chunk/Merkle metadata. This work is message gap repair, not a claim that every existing own-device sync UI/transport has already been wired; reuse the Rust device certificate/session APIs where relevant and test the actual adapters used.

## 6. Diagnostics and UX

Local counters and current health snapshots cover seed availability/quota rejection, authenticated routes, receipt timeouts, route changes, Courier waiting/deposits/pickups/expiry, repaired gaps and failures. Persist aggregate counts only; no message contents, keys, DID/contact graph, URLs with secrets or per-message diagnostic IDs/timestamps. Nothing uploads automatically. User-triggered export is redacted and reviewable.

Ordinary UI stays concise. Distinguish connecting, securely connected, waiting for receiver, waiting for two Couriers, depositing, stored across nodes, expired, failed and recipient-delivered states. Chat timestamps remain as requested. Details and quota/network reasons belong behind a status/detail action, not explanatory paragraphs in every room.

## Verification and delivery gates

Use failing-first regressions for quota-denied constructor/SQL operations, zero-SQL dispatch, nonce/counter/signature tampering, cross-session replay, attachment-size limits, legacy fail-closed behavior and cold/hibernated state. Run actual workerd and public WSS smoke checks before claiming seed recovery.

Test route fairness, stale/live alternatives, provider classification, jitter/cooldown, seed-independent live chat and lock/switch races. Test Courier encryption/tamper/truncation/reorder/collision, unauthorized pickup, two-node minimum and alias/certificate handling, every reallocation's never-full-set property, partial deposit/restart, quota/disk failures, staging cleanup, late/duplicate receipts, expiry and cancellation.

Test exact gap repair with missing/out-of-order data, tombstones, original-author validation, group membership removal/epoch rotation, sparse file reconstruction and no notification replay. Keep existing build-43 suites green. Use disposable identities and separate Android QA package for real network tests; never inspect owner secrets or send to real contacts.

Perform a fresh whole-branch independent read-only review before shipping. Build/audit Windows single EXE, Android arm64 and Web/Wasm as the next build, synchronize owned sources only, preserve the running owner Desktop and private workspaces/roadmaps, update existing authorized Web service, and report real provider/carrier/soak limits. No GitHub push/release or paid infrastructure is included in this authorization.

## Builder choices and outstanding deployment dependencies

The package size, retention and quotas above are implementation defaults, not additional owner-selected requirements. They may be tuned during implementation with evidence while retaining the strict two-node rule and encryption/storage bounds. Settle internal module boundaries, exact bounded schemas and test fixtures in the implementation plan; do not invent unreviewed cryptographic constructions.

Actual independent-provider public relay hosting requires an operator-supplied reachable endpoint or separately authorized account. Code, portable deployment configuration and local independent-process verification do not establish that real-world dependency. The owner's manual PIN/GUI cooperation may be needed for live installed-app verification; preserve all prior policy boundaries rather than retrying blocked actions.
