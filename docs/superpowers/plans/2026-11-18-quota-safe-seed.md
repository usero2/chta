# Quota-safe seed implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Native inline execution was explicitly preserved; the owner approved development from the design. One fresh whole-plan read-only review precedes seed deployment.

**Goal:** Restore discovery/signaling without mandatory SQL, preserving authentication and replay protection for updated clients.
**Architecture:** Domain-separated, connection-bound signed dispatches consume monotonic sequence state in hibernating WebSocket attachments. Optional legacy storage stays fail-closed; ephemeral signed catalogs republish after restart.
**Tech Stack:** Existing Rust/snow/Ed25519, Dart/Flutter, JavaScript Workers/workerd.
**Spec:** `docs/superpowers/specs/2026-11-18-decentralized-delivery-design.md` (approved 2026-11-18).

## Global Constraints

- No Bluetooth, paid service/TURN/billing upgrade, central mailbox, remote Git push/release, owner-contact send or secret inspection.
- Existing legacy replay reservation must not silently become best-effort. Discovery-only seed never handles chat/file/Courier payloads.
- Preserve existing isolated workspace, unrelated Linux files, target junction and owner data/processes.
- Dispatch attachment <=2 KiB; preserve safe integer sequence, generation/owner guards, frame/rate/queue bounds.
- Build 43 remains the rollback baseline. Server-only deployment must preserve its live data-relay compatibility; final client builds are delivered after the second plan.

## Review Focus

- Quota failure on every SQL method must not break updated registration/lookup/dispatch or cause legacy forwarding without replay reservation.
- Dispatch replay across sockets, topics, seed IDs or reconstructed actors must never reach a recipient twice.
- Socket/owner change while signing must not emit under the replacement account or connection.
- A hostile unauthenticated client cannot create unbounded attachments, crypto queues, IP maps or discovery records.
- Catalog reconstruction/expiry and obsolete clients must fail visibly without lying about delivery or accepting user content.

### Task 1: Rust dispatch proof and public verification

**Files:** create `rust/crates/core/src/seed_dispatch.rs`, `rust/crates/core/tests/seed_dispatch.rs`; modify `src/lib.rs`, `src/account.rs`, `src/native.rs`, `src/wasm.rs`, `apps/web_portal/src/protocol.js`, `test/helpers.js`, `test/protocol.test.js`.
**Interfaces:** `AccountCore::sign_seed_dispatch(seed_id:&str, connection:&str, sequence:u64, envelope_json:&str)->Result<String,String>`; JSON gateway/export `signSeedDispatch`. Worker `verifyDispatch(proof,envelope,identityId,connection,previousSequence)` returns accepted sequence.

- [ ] RED: authentic proof verifies; altered envelope/seed/nonce/sequence/signature, cross-owner envelope, zero/unsafe integer and oversize fail. Add shared deterministic Rust/JS fixture asserting identical digest/signature payload bytes.
- [ ] Implement proof fields `version,seedId,connection,sequence,envelopeHash,publicKey,signature`; domain `chta seed dispatch v1\0`; signed tuple `[1,seedId,connection,sequence,envelopeHash]`. Envelope digest covers ordered tuple `[version,topicOrNull,from,to,session,id,kind,payload,issuedAt,expiresAt,publicKey,signature]`; never arbitrary object key order.
- [ ] GREEN: `cargo test --locked -p cht-core --test seed_dispatch`; `node --test test/protocol.test.js`. Expected 0 failures including legacy protocol tests. Commit owned files locally.

### Task 2: Quota-independent actor lifecycle and replay

**Files:** modify `apps/web_portal/src/seed-directory.js`; create `test/seed_dispatch.test.js`; extend `test/directory.test.js`, `test/runtime.test.js`.
**Interfaces:** challenge advertises `session-dispatch-v1`; `signal` optionally carries Task1 proof. Attachment retains channel nonce, consumed sequence and bounded authenticated state. Legacy frames keep exact persisted replay semantics.

- [ ] RED: all SQL get/put/setAlarm throw quota errors while upgraded two-client registration, lookup, signed signal and hibernated replay rejection still work; old signal never dispatches when reservation fails. Assert idle keepalive/lookup do not add storage writes.
- [ ] Implement optional legacy load, v2 zero-SQL path, bounded ephemeral catalogs, timed auth expiry without mandatory storage alarm, best-effort IP/global bounds and persisted per-socket rates. Consume sequence/serialize attachment before forwarding. Document IP cold-restart limits.
- [ ] GREEN: `node --test test/directory.test.js test/seed_dispatch.test.js test/runtime.test.js`; runtime includes actual hibernation-compatible workerd sockets and no content forwarding. Expected all pass. Commit.

### Task 3: Shared native/Web signing and all seed callers

**Files:** create `lib/seed/seed_dispatch.dart`; modify `seed_crypto_bridge.dart`, `seed_client.dart`, `groups/group_seed_client.dart`, native/Web core bridges, `web/cht_core_loader.js`; tests `test/seed/seed_client_test.dart`, new `test/seed/seed_dispatch_test.dart`, group seed tests.
**Interfaces:** optional `SeedDispatchCryptoBridge.signSeedDispatch(String seedId,String connection,int sequence,String envelopeJson)->Future<String>`; `SeedDispatchSession` owns negotiated nonce/sequence/signing serialization and reset. Direct, group and contact envelopes use the same wrapper.

- [ ] RED: ordered concurrent sends across all topics; reset/lock during pending signature emits nothing stale; unsafe challenge/reused nonce unsupported; old bridge/server compatibility; explicit legacy storage-unavailable reason with bounded retry.
- [ ] Implement Rust exports and JS readiness guards; reset dispatch generation on disconnect/reconnect. Never replace original signed inner IDs/timestamps or put chat content in seed frames.
- [ ] GREEN: affected Flutter seed/group/account suites plus full Flutter analysis/tests, Rust workspace tests, Worker suites. Expected no failures; retain opt-in skips. Commit.

### Task 4: Independent review and seed recovery proof

**Files:** update `scripts/smoke-public-seed.mjs`; QA docs and approved spec status; private build/deployment helpers.

- [ ] Review whole plan range with one fresh read-only reviewer. Re-grade findings and fix Important/Critical in one RED→GREEN pass; rerun full suites.
- [ ] Build native/Wasm dispatch exports as required for integration; preserve production package/owner runtime. Verify deterministic native ↔ Worker fixture and actual two-account public WSS dispatch/lookup when SQL is unavailable in fixtures.
- [ ] Deploy existing authorized seed Worker only, retaining existing production Web assets. Verify public WebSocket challenge, authenticated registration/signaling, legacy behavior and no HTTP500 constructor failure; inspect redacted diagnostics. No new billing/provider.
- [ ] Record actual results and privacy checks; local commit, no Git publication. Continue the second plan without asking for the already selected Native method again.
