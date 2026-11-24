# Distributed Courier and reliable routing implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans, Native inline. The owner approved the linked design and requested implementation. One fresh whole-plan independent review before platform delivery.

**Goal:** Automatically host bounded Desktop Couriers, distribute encrypted packages across at least two nodes, repair missing messages and explain delivery health locally.
**Architecture:** Rust owns forwardable message signatures, device certificates and sealed package keys. Shared Dart account services own routing, protected package/job storage, Courier transport, gap repair and diagnostics; UI consumes stable logical job state.
**Tech Stack:** Existing Rust Ed25519/Noise and AEAD library; Flutter, protected blobs/chunk cache, existing routed WSS data relays; portable Node relay adapter.
**Spec:** `docs/superpowers/specs/2026-11-18-decentralized-delivery-design.md`, owner approved 2026-11-18.

## Global Constraints

- Desktop auto-hosts only after identity/storage unlock; lock/switch/stop cancels generations. Android/Web are deposit/pickup clients. No Bluetooth.
- At least two certified node identities; no node receives the complete package set, including ever-assigned sets during retry/reallocation. Under two nodes waits on sender.
- Defaults: <=256 KiB packages, <=8 KiB wire fragments, 24h TTL, 1 GiB host capacity, 256 MiB per depositing root, four assemblies, sixteen deposit requests. Honor shared cache/free-space limits and existing 10 GiB logical streamed limit.
- Keep seed discovery-only, private content/key on endpoints, original IDs/timestamps/dedup, durable-before-ACK, tombstones, group epoch/membership checks and text/file fairness.
- No new paid service, billing changes, owner-contact QA, secret inspection, Windows owner GUI automation, Git push/release or unrelated filesystem cleanup.
- Actual public non-Cloudflare provider endpoints remain an operator deployment dependency; implement portability/configuration without inventing deployed redundancy.

## Review Focus

- Node aliases, same-device certificates, partial deposits and replacement churn must never make one node accumulate all packages.
- Disk/quota failure, pause/cancel/lock or crash between data/index/ACK must neither lose sender intent nor produce false Delivered.
- Unknown depositors, malicious relays and unauthorized/removed group members must not forge identity, access plaintext/keys, resurrect history or exhaust resources unboundedly.
- Missing/out-of-order events, duplicate receipts and interrupted repair must converge without duplicate notifications, rewritten sent times or forged legacy authorship.
- Provider/seed outages and privacy exports must keep existing usable routes alive and never expose content, keys, DIDs or sensitive routing graphs in diagnostics.

### Task 1: Forwardable delivery and Courier cryptography

**Files:** new `rust/crates/core/src/delivery.rs`, `src/courier.rs`, associated `tests/delivery.rs`, `tests/courier.rs`; modify `src/lib.rs`, `account.rs`, native/Web exports, common dependency placement; new `lib/delivery/delivery_crypto_bridge.dart` and native/Web bindings/loader.
**Interfaces:** `deliveryCall(operation,args)` operations `signEvent/verifyEvent`, `nodeCertificate/verifyNode`, `sealManifest/openManifest`, `encryptPackage/decryptPackage`, `signControl/verifyControl`. Return typed versioned JSON with bounded bytes; keys only in Rust protected owner state.

- [ ] RED: native/Wasm vectors; cross-owner, wrong recipient, tamper/truncate, swapped index/job/expiry, key/nonce reuse, bad device cert and unsafe schema fail. Verify different encryptions of equal plaintext have distinct ciphertext hashes.
- [ ] Implement the immutable author envelope and reuse the root-signed device certificate with a separate Courier context. Generate a fresh job key. Encrypt with XChaCha20-Poly1305, unique nonces, and associated data. Use Noise IK to seal the small manifest, including the job key and ciphertext Merkle root. Keep payload keys out of carrier exports and Rust errors. Explain the forward-secrecy limits of the static offline key.
- [ ] GREEN Rust targeted tests/native/Web export checks and fixtures. Commit.

### Task 2: Distribution planner and durable sender jobs

**Files:** new `lib/courier/courier_models.dart`, `distribution.dart`, `sender_jobs.dart`; tests under `test/courier/`.
**Interfaces:** `CourierNode` verified certificate identity/routes/capacity; `DistributionPlan.allocate(job,nodes,everAssigned)`; `CourierSenderJobs` protected load/flush/pause/resume/cancel/receipt transitions. Package indexes and original application identity immutable.

- [ ] RED: one node or aliases wait/no deposit; two split; optional >=3 balanced replication; changing nodes/capacity never yields a full set to any historical node. Fuzz deterministic churn/assignment invariants, including small messages/empty files and colluding aliases.
- [ ] Implement bounded protected job pages and ciphertext spool/index commits before scheduling, monotonic allocation revision and ever-assigned bitmap. Preserve sender intent until valid recipient receipt; partial carrier ACK is a distinct state.
- [ ] GREEN planner/job tests with restart, partial writes, cancellation, expiry and late valid receipt. Commit.

### Task 3: Protected host store, quota and staging cleanup

**Files:** new `lib/courier/courier_store.dart`, `courier_policy.dart`; modify `chat/cache_policy.dart`; tests `test/courier/courier_store_test.dart`, cache policy tests.
**Interfaces:** `CourierStore.acceptOffer/writePart/commitPackage/listMailbox/readPackage/recordReceipt/cancel/expire`, all owner/generation scoped. Storage ACK only after protected durable commit.

- [ ] RED: exact byte/count/per-depositor/free-space caps, concurrent admission, interrupted assembly, metadata failure, restart, spoofed allocation, expiry and replay of cancelled/deleted jobs. Test progress during an awaited quota save retains monotonic accounting.
- [ ] Implement paged protected metadata, bounded assembly and shared-cache reservations; separately clean only third-party expired/completed copies and abandoned staging. Keep receipt/cancel tombstones for bounded TTL; never touch owner history/original attachments.
- [ ] GREEN storage/cache/outbox regressions including 1 GiB/256 MiB policies. Commit.

### Task 4: Public Courier transport and signed discovery

**Files:** new `lib/courier/courier_transport.dart`, `courier_directory.dart`, `courier_service.dart`; modify RelayNetwork generic frame hooks/catalog support and Worker discovery schemas; associated `test/courier/` and Worker tests.
**Interfaces:** reserved hex routing session/body discriminator; signed node advertisements and challenge-bound controls, bounded fragmentation/ACK; `CourierService.start/stop/refresh/pickup/deposit` account-owned, no ContactStore auto-verification.

- [ ] RED: unknown eligible nodes work without a friend contact; forged route/from/control/storage ACK and unauthorized pickup fail; four assemblies/sixteen requests bound adversarial traffic; different URLs of one node never satisfy the two-node rule.
- [ ] Implement opaque mailbox binding and recipient possession proof, signed controls/allocations, ciphertext-only packages on data relays, separate bounded bulk/control queues and exact ACK retries. Seed carries discovery records only. Preserve old catalogs and private chat handlers.
- [ ] GREEN actual multi-process/real relay disposable-node tests, lock/switch and reconnect/stale signatures. Commit.

### Task 5: Delivery router and provider-aware relay portability

**Files:** new `lib/delivery/delivery_router.dart`, `route_health.dart`, `lib/relay/relay_provider_policy.dart`; modify messaging service/group transport/relay network; new portable relay runner/config under `apps/relay_node/`, tests and operator docs.
**Interfaces:** logical `DeliveryRoute` capability/authentication/health/receipt state; selector preserves stable IDs and routes text independently of bulk. Provider domains are local configuration, not unverifiable assertions from arbitrary advertisements.

- [ ] RED: slow/failing Direct cannot block live relay text; stale receipts select fallback; cooldown/jitter/hold-down bounded, healthy channels remain; locked routes/owner generations respected. Prefer configured distinct domains; unknown or same-provider URLs do not become claimed redundancy.
- [ ] Implement live Direct/Relay routing then Courier fallback with shared job controls. Retain user connection limits while separating known/warm/active concepts. Supply same-protocol Node relay with TLS reverse-proxy/Docker example, no deployed fake public endpoint or token.
- [ ] GREEN existing messaging/failover/fairness plus independent-process provider tests. Commit.

### Task 6: 1:1 and group delivery integration

**Files:** messaging service, peer history, connection widgets, group controller/transport/models/swarm; new delivery/Courier adapters and tests.
**Interfaces:** v2 forwardable delivery envelope persisted with protected message metadata; Courier adapters return to existing durable receive pipeline; group adapter preserves signed event/roster/epoch domain. Sender file controls target one logical job across all routes.

- [ ] RED: live/offline copies deliver once with original ID/time; no notification replay; file plaintext/key absent in host/relay artifacts; whole-file SHA-256 and packet Merkle verification precede recipient signed receipt. Removed/banned member cannot request or receive later-epoch packages.
- [ ] Wire automatic Desktop host after loaded unlock, Android/Web client pickup/deposit, host stop override and identity lifecycle. Integrate private messages/files and authenticated group events without downgrading existing protocols; old clients stay live-compatible and get explicit unavailable offline capability.
- [ ] GREEN direct/group/Courier real-stack integration and existing group/admin/media suites. Commit.

### Task 7: Bounded missing-message reconciliation

**Files:** new `lib/delivery/gap_repair.dart`, protected inventory adapter; modify messaging/group receive paths; tests `test/delivery/gap_repair_test.dart` and integration fixtures.
**Interfaces:** authenticated scoped inventories and paged exact-ID/digest requests; bounded repair windows and byte caps. Original author proves legacy 1:1 data; new signed events can be forwarded only within authorized scope.

- [ ] RED: missing/out-of-order histories converge, duplicates/tampered author/event IDs reject, interruptions restart safely; deletion tombstones prevail and group epoch/removal gates hold. No full-history rewrite or notification/sent-time replay.
- [ ] Implement reconnect-triggered inventories, missing pages and signed event verification; persist repair cursor after durable commit. Reuse Courier/live routes without weakening their two-node/payload limits.
- [ ] GREEN gap/history/group/cache/outbox suites and two-disconnected-then-online real-core test. Commit.

### Task 8: Diagnostics, concise UI and settings

**Files:** new `lib/delivery/local_diagnostics.dart`, shared Profile/Connect details widgets and file job UI; tests for redaction/settings/lifecycle and mobile layouts.
**Interfaces:** aggregate local counters/current health only; explicit redacted export; Courier capacity and role state; concise message/job statuses map to existing timestamps and action widgets.

- [ ] RED: export never contains content/keys/DIDs/message IDs/secret URLs/per-message timestamps; settings frozen on lock; two-node waiting/storage ACK/recipient-delivered states distinct; no idle rebuild storm or mobile overflow.
- [ ] Implement diagnostics and host capacity controls; platform-specific host availability clearly reported. No automatic telemetry or owner preference changes in QA.
- [ ] GREEN shared widget/notification/media/cache/lifecycle suites. Commit.

### Task 9: Whole-branch review, real networks and build delivery

**Files:** QA evidence/docs, version metadata, private sanitized build helpers.

- [ ] Run full Flutter/Rust/Worker/portable relay suites; one fresh most-capable read-only review of this plan range and interactions with seed plan. One Important/Critical RED→GREEN fix pass, then green suites.
- [ ] Real disposable Android/Windows/Web tests across different uplinks, with >=2 synthetic Desktop Couriers: sender exits after durable deposit; recipient opens later, reconstructs file and receipts return when sender returns. Exercise carrier loss/partial deposit and preserve never-full-set assignment. Be explicit about CLI/native UI, network and long-soak limits.
- [ ] Build/audit Windows single EXE, Android arm64 and Web/Wasm next build; no private paths/identifiers/credentials/source or fixture data. Sync owned files with baseline checks, install Android, preserve owner Desktop process, deploy authorized existing Web. No remote Git/release/new billing.
- [ ] Record remaining actual external-provider dependency, commits, hashes, privacy checks and user handoff requirements; keep isolated worktree and unrelated files.
