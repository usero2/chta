# Automatic Multi-device Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically synchronize an unlocked identity's account data, conversations and available files across Windows, Android and browser installations, and show their presence in Profile.

**Architecture:** Give each installation/identity its own root-certified device signing and Noise keys. A separate device namespace on the existing seed exchanges authenticated discovery and SDP/ICE only; independent encrypted device sessions carry bounded signed journal pages and resumable cache copies. Merge individual records into existing stores rather than replacing an identity snapshot.

**Tech Stack:** Existing Rust core, ed25519-dalek, snow/Noise, platform protected vault, WASM/WebCrypto/IndexedDB, Dart/Flutter, data-only WebRTC and Cloudflare Durable Objects. No new cryptographic dependency.

**Spec:** `docs/superpowers/specs/2026-11-15-multidevice-sync-design.md` (approved 2026-11-15).

## Global Constraints

- Automatic sync after logging into the same identity, without QR pairing. Preserve `did:cht:` and recovery/PIN compatibility.
- Up to eight simultaneously online sync devices per identity; offline records do not consume a live slot. Keep up to128 known device records.
- Use a20s heartbeat and90s expiry. Store UTC milliseconds; display locally as `yyyy-MM-dd HH:mm:ss.fff`; unknown is `—`.
- Keep device private keys inside Rust/platform storage boundaries; do not return them through the Dart operation API.
- Neither messages nor file bytes go through `chta.app/relay`. Reject sync content at the public seed. Keep strict existing DM/Groups validators.
- Preserve25MiB relay and10GiB Direct file policy. Bound control pages to32KiB plaintext and fragment at the existing16KiB transport ceiling.
- Delete chat remains local to that device. Preserve deletion barriers, contact removal tombstones, concurrent sends and monotonically merged receipts.
- Do not sync PIN, lock-on-start, cache paths or notification permissions. Do not trigger notifications for historical catch-up or resend another device's outbox.
- Keep group membership under one designated owner device, preserve conflicting evidence and pause membership edits on unresolved authority/forks.
- A browser profile is one device. Coordinate its tabs; native clients enforce one writer per installation/identity. Stop sessions on lock/switch.
- No remote logout/revocation UI, cloud history mailbox, background Android service or push wake-up in this release.
- Use synthetic data for destructive/message QA. Do not obtain user PIN/phrase, send messages to real friends, or resume Windows GUI control stopped with Esc without authorization.

## Review Focus

- Same browser origin opened in two tabs: one device key and journal writer, seamless leader handover without duplicate sequences (Tasks2/4/9).
- Delayed callbacks after lock or owner switch: no cross-owner storage, acknowledgements, notifications or presence updates (Tasks2/4/5/8).
- An empty restored device meets populated devices or locally deleted rooms: bootstrap merges without erasure or history resurrection (Tasks2/5/6).
- Receiver storage fails mid-page or transfer: no acknowledgement before durability; reconnect resumes verified data without duplication (Tasks2/4/7).
- Concurrent legacy owner-group copies and mixed client versions: no silent membership fork, DM breakage or unauthorized takeover (Tasks3/6/9).

---

## File and boundary map

- `rust/crates/core/src/device_sync.rs` plus `device_sync/{certificate,session,journal}.rs`: device-only cryptography, validation, signatures and canonical event protocol. Do not mix with DM/Groups session maps.
- `rust/crates/core/src/{account,native,wasm}.rs`, `desktop_vault/device_sync.rs`: owner-bound protected initialization/persistence and public-only operation dispatch.
- `apps/flutter_app/web/device_sync_store.js`: protected device state plus tab writer lease. `web/cht_core_loader.js`: guarded bridge only.
- `apps/web_portal/src/device-protocol.js`: independent exact-schema seed validation. `seed-directory.js`: purpose/device-aware registration, presence and routing. Existing `protocol.js` remains strict.
- `apps/flutter_app/lib/device_sync/{device_crypto_bridge,device_models,device_seed_client,device_transport,device_journal,device_sync_controller}.dart`: narrow platform bridge, discovery, transport, replication coordinator and public observable roster.
- `apps/flutter_app/lib/device_sync/{account_replica,history_replica,group_replica,device_file_sync}.dart`: adapters for existing stores; no direct UI storage shortcuts.
- `apps/flutter_app/lib/device_sync/devices_section.dart`: compact Profile list. `account/account_gate.dart`: authenticated lifecycle integration.
- Tests mirror these boundaries under Rust core tests, portal tests, Flutter `test/device_sync`, browser fixtures and QA scripts.

### Task 1: Certified device identity and independent encrypted sessions

**Files:** Create Rust `device_sync.rs`, `device_sync/certificate.rs`, `device_sync/session.rs`, `tests/device_sync.rs`. Modify `identity.rs`, `lib.rs`, `account.rs` only for typed internal entry points.

**Interfaces:** Produce `DeviceCertificate`, `DeviceEngine::new(identity: &IdentityManager, created_at: u64) -> Result<Self,String>`, `DeviceEngine::call(&mut self, identity: &IdentityManager, operation: &str, args: serde_json::Value) -> Result<serde_json::Value,String>`. Public operations: `local`, `registrationProof`, `inspectCertificate`, `signSignal`, `inspectSignal`, `prepare`, `handshake`, `seal`, `open`, `close`. Private state encode/decode methods are Rust/platform-only; never expose them in `call`.

Certificate JSON exact fields: `version,ownerId,rootPublicKey,deviceId,signingPublicKey,noisePublicKey,createdAt,signature`. Version1; deviceId32 lowercase hex, keys32-byte unpadded base64url, signature64-byte unpadded base64url. Root signature covers `chta device certificate v1\0` plus canonical JSON array of the first seven fields in that order. Device ID and both private keys use independent secure randomness.

Registration proof covers `chta device registration v1\0` plus `[1,seedId,nonce,ownerId,deviceId]`, signed with the device key. Reuse normal root registration proof as an additional field. Device signal signature covers `chta device seed signal v1\0` plus `[version,ownerId,fromDevice,toDevice,session,id,kind,payload,issuedAt,expiresAt]`; exact fields also include `certificate,signature`. Reuse existing strict SDP/ICE parser,120s TTL,30s skew,16KiB frame cap. Root DID is shared, Device IDs must differ.

- [ ] Write `same_root_distinct_device_keys`, `certificate_tampering_and_cross_root_rejected`, `device_signal_cannot_contain_content`, `device_noise_sessions_are_pair_and_session_bound`, `replay_and_wrong_device_rejected` with two restored copies of a synthetic identity and a different root. Assert signatures fail after each field mutation; handshake frames cannot cross session pairs; encrypted content is unreadable without that session.
- [ ] Run `cargo test -p cht-core --test device_sync`; expected RED for missing types.
- [ ] Implement strict schemas and canonical signing; Noise KK using certified device static keys, prologue binding owner/both Device IDs/roles/session, bounded session registry and staging before promotion. Keep old live session on failed replacement. Zeroize secret state on drop; redact Debug.
- [ ] Run the task tests plus existing `secure_session` and `seed_signal` tests; expected all PASS.
- [ ] Commit `feat: add certified per-device cryptography and sessions`.

### Task 2: Durable device journal and protected platform bridge

**Files:** Create Rust `device_sync/journal.rs`, `desktop_vault/device_sync.rs`, Web `device_sync_store.js`, Dart `device_crypto_bridge.dart` and `device_journal.dart`; modify core native/WASM/account, platform bridges and loader. Add corresponding Rust/Node/Dart tests.

**Interfaces:** Produce Dart `DeviceCryptoBridge.deviceCall(String operation, Map<String,Object?> args) -> Future<Map<String,Object?>>`; engine journal operations `append`, `summary`, `page`, `inspectPage`, `commitCheckpoint`; `page` returns <=32KiB signed events. A journal event exact fields: `version,ownerId,deviceId,epoch,sequence,clock,id,objectType,objectId,payload,signature`; stable event ID hashes the canonical unsigned tuple. Epoch32 hex; nonzero monotonically allocated sequence/clock within JS safe integer range. Types: `contact`, `profile`, `peerMessage`, `receipt`, `groupState`, `groupMessage`, `deviceName`, `fileReference`. Record versions use `(logicalClock, deviceId)`; message identity is conversation/sender/message ID. Local deletion barriers are separate, never replicated as account removal.

- [ ] Write `journal_duplicate_reorder_checkpoint_restart`, `checkpoint_requires_durable_page`, `foreign_event_and_oversized_page_rejected`, `secret_state_never_in_public_call`, `failed_save_keeps_previous_sequence`; Web tests cover concurrent initialization, transaction failure, two-tab writer acquisition and leader loss.
- [ ] Run focused tests, expected RED for missing bridge/journal.
- [ ] Add a protected owner-specific `device-sync-v1` record using existing platform encryption; persist immutable journal pages before its index/checkpoint. Native single writer lock; Web origin/owner Web Lock plus transactional IndexedDB sequence allocation, one shared wrapping key creation transaction. Restore the same keys/epoch after restart; damaged state fails closed. Clear runtime keys on identity switch. Private exports may travel only between Rust/WASM and the internal wrapping host, never via Dart operations.
- [ ] Implement transactional append/accept APIs. A page is signature/owner/schema checked before materialization and acknowledged only after adapters/checkpoint are durable. Retain tombstones and stable legacy import IDs. Stream page enumeration; no whole-account JSON snapshot overwrite or unbounded journal scan into RAM. Native and Web publish the same public bridge operation results.
- [ ] Run native vault, browser host and bridge tests; expected PASS. Confirm existing vault formats still load.
- [ ] Commit `feat: persist protected device journals across platforms`.

### Task 3: Device-only seed registration, roster and routing

**Files:** Create portal `src/device-protocol.js`, `test/device-protocol.test.js`, `test/device-directory.test.js`; modify `seed-directory.js` and existing directory helpers. Create Dart `device_seed_client.dart` with fake-socket tests. Modify `seed/seed_client.dart` and `groups/group_seed_client.dart` to register certified device/purpose on new clients while preserving legacy registration for old cores.

**Interfaces:** Consume Task1 certificate/proofs/signal. Registration frame is `{type:'deviceRegister',certificate,rootProof,deviceProof,platform}`; platform one of `windows,android,web,linux,macos,ios,unknown`. Device socket supports only `deviceHeartbeat`, `deviceLookup`, `deviceSignal`, `keepalive`. Server outputs `deviceRegistered`, `deviceRoster`, `deviceSignal`, `deviceLimit`, `alive`. `DeviceSeedClient.start(ownerId)`, `close()`, `sendSignal(deviceId,id,text)`, `roster` and `signals` streams. Heartbeat carries device-signed `[1,ownerId,deviceId,registrationNonce,issuedAt,expiresAt]` under `chta device presence v1\0`; <=90s validity. Roster carries certificates and these proofs, no display names/history.

- [ ] Write tests `eight_live_devices_not_eight_old_records`, `device_socket_cannot_query_other_owner`, `wrong_challenge_and_forged_presence_rejected`, `all_content_types_rejected`, `legacy_dm_groups_stay_strict`, `queued_registration_and_hibernation_preserve_caps`. Add client reconnect/backoff/expiry/cancel-on-owner-change tests.
- [ ] Run `npm test` in portal and Flutter seed tests; expected RED for new frames/client.
- [ ] Implement exact validation and routing by owner+Device ID, total existing1000 socket bound,8 live device slots and purpose-aware per-device limits. Keep legacy4 cap in its own namespace; new normal DM/Groups sockets must identify a certified device/purpose to avoid collapsing eight installations into legacy4. Cap per-device purposes, unauthenticated sockets, pending verifications, rates/replays/queues; persist replay reservation before dispatch. Do not forward device namespace to legacy sockets. Signed presence expires even after hibernation and clean disconnects immediately update roster.
- [ ] Implement Dart client using existing connector, generation guards, bounded serialized incoming queue,20s heartbeat and jittered bounded retries. Verify received certificate/presence through Rust before recording observations; seed hints cannot authorize a transport session.
- [ ] Run all portal tests and focused Dart tests; expected PASS, including old DM/Groups protocol fixtures.
- [ ] Commit `feat: discover authenticated own devices without seed content`.

### Task 4: Automatic encrypted device transport and paged catch-up

**Files:** Create Dart `device_transport.dart`, `device_sync_controller.dart`, `device_models.dart` and tests. Modify `rust/crates/relay_server/src/websocket.rs` and `apps/flutter_app/lib/relay/relay_network.dart` for distinct bounded own-device envelope routing; do not loosen legacy envelope validators.

**Interfaces:** `DeviceTransport.start()`, `close()`, `connected(deviceId)`, `isDirect(deviceId)`, `send(deviceId,text)`, `frames` stream; `DeviceSyncController.start()`, `stop()`, `devices`, `localDeviceId`, `status`. Consume Tasks1–3. Expose durable page application callback `Future<void> applyEvents(List<DeviceEvent> events, {required bool historical})`; callback must finish before checkpoint acknowledgement. Device models include ID, encrypted name, platform, current-device flag, last authenticated observation and sync state.

- [ ] Write `auto_connect_same_root_only`, `old_probe_does_not_replace_live_session`, `seed_never_receives_sync_page`, `fragment_bounds_and_serial_order`, `resume_after_failed_apply`, `identity_switch_during_crypto_and_io`, `tab_leader_handover`. Use fake Direct/relay links and blocked futures to assert no stale writes/acks.
- [ ] Run tests; expected RED.
- [ ] Reuse DirectFileLink with device IDs as link identities; sign/verify its SDP via Task3. Start offers deterministically by Device ID, serialize ICE/signaling/ciphertext and stage fresh Noise contexts separately. Attempt user-controlled content relay fallback with device-addressed authenticated envelopes; reject this content at the public seed. Enforce16KiB frames,32KiB pages,bounded assembly and queues,timeouts/backoff, and fair scheduling around presence/chat.
- [ ] Exchange journal summaries/missing page requests automatically, verify events before parsing payload, apply transactionally then commit/ack checkpoint. Persist roster <=128 records; coalesce observations; live cap8. Online requires fresh authenticated presence; fresh Profile rendering never advances Last seen. Current local unlocked leader is This device; restart initially marks remote records Offline/Unknown until proof.
- [ ] Run focused tests including legacy relay regressions; expected PASS.
- [ ] Commit `feat: connect own devices and resume encrypted journal sync`.

### Task 5: Merge account data and direct-message history

**Files:** Create Dart `account_replica.dart`, `history_replica.dart`; modify `account_controller.dart`, `profile_controller.dart`, `peer_history.dart` and Rust contacts entry points where signed card export/import is required. Add adapter tests.

**Interfaces:** `AccountReplica.exportPage(cursor,limit)` and `HistoryReplica.exportPage(cursor,limit)` produce stable materialized events; `apply(DeviceEvent event,{required bool historical}) -> Future<void>`. Local mutation listeners append events only for changed records; applying remote events suppresses feedback journaling. Add `PeerHistory.mergeSyncedMessage(peerId,message,{required bool historical})` and a persisted local deletion-barrier API. Contact export includes the validated signed card, alias, verification decision and removal tombstone; never reconstruct a card from ContactView.

- [ ] Write `empty_device_cannot_erase_history`, `concurrent_contacts_profile_converge`, `removed_contact_not_resurrected`, `synced_and_live_message_deduplicate`, `delivered_cannot_regress`, `only_origin_retries_outbox`, `delete_barrier_blocks_old_backfill_but_allows_new_message`, `catchup_has_no_notification`, `failed_persistence_keeps_checkpoint`.
- [ ] Run focused tests; expected RED.
- [ ] Bootstrap existing validated records with deterministic legacy event IDs, then capture edits incrementally. Validate card fingerprints before applying contacts/verification; apply field versions by logical clock/Device ID. Merge receipts monotonically and retain original sent/received times. Preserve attachment references as metadata with no foreign paths. Add explicit source/origin fields so imported pending messages never enter external resend queues. General/Design and all local PIN/preferences stay outside replication.
- [ ] Make remote apply persist before completion and update existing controllers/UI listeners after commit. Add migration tests for existing history versions1–4 and contact/profile vaults.
- [ ] Run account/history/profile/notification suites; expected PASS.
- [ ] Commit `feat: synchronize contacts profile and chat history safely`.

### Task 6: Group replication and single-device membership authority

**Files:** Create Dart `group_replica.dart`; modify `groups/group_controller.dart`, Rust `rust/crates/core/src/groups.rs`, Group details UI in `account/account_gate.dart` and tests.

**Interfaces:** `GroupReplica.exportPage(cursor,limit)`, `apply(DeviceEvent,{required bool historical})`; add root/device-signed authority record `{version,groupId,ownerId,deviceId,chainHead,signature}` and signed conflict resolution naming all competing anchors. Add controller `membershipAuthority(groupId)` and `canEditMembership(groupId)`; normal `canSend` remains independent of authority availability.

- [ ] Write `same_chain_merges_messages_without_duplicate_notifications`, `owner_devices_cannot_fork_epochs`, `legacy_owner_bootstraps_one_anchor`, `conflicting_anchors_pause_edits`, `non_controller_requests_wait_when_offline`, `existing_membership_fork_preserves_evidence`, `local_group_delete_survives_backfill`.
- [ ] Run focused group/device tests; expected RED.
- [ ] Validate imported chains/documents with the existing core, merge only matching prefixes and histories by stable signed IDs; never blindly import an entire group core over concurrent state. New groups choose their creating device; legacy owner-state holder creates an anchor; imported copies retain it. Route membership edits to the controller and persist requests. Show concise Waiting/Conflict state and a deliberate owner resolution action when anchors conflict. Preserve fork evidence without automatic repair; normal messages/files continue where membership validates.
- [ ] Persist group histories, manifests and origin-owned outbox state before acknowledging sync. Preserve explicit group invitation acceptance and16-member bounds.
- [ ] Run complete Groups/swarm regressions; expected PASS.
- [ ] Commit `feat: synchronize groups without membership forks`.

### Task 7: Referenced encrypted file cache copies

**Files:** Create Dart `device_file_sync.dart`; use existing `chunked_file_cache.dart`, `chunked_attachment_bridge.dart`, `attachment_store.dart`, Groups sparse cache and their tests. Modify cache abstraction only for bounded status/range operations.

**Interfaces:** `DeviceFileSync.enqueue(DeviceFileReference reference)`, `handleFrame(deviceId,text)`, `close()`, `progress` observable. Reference includes authenticated message identity, size,digest,MIME/name,content identity; local cache IDs/paths are assigned by the receiver. Ranged requests carry file identity,index,requested byte length and request ID; responses bind the same values inside the authenticated session. Local availability receipts never call normal peer delivery acknowledgement.

- [ ] Write `unreferenced_or_corrupt_file_rejected`, `receiver_restart_resumes_verified_chunks`, `relay_25_mib_direct_10_gib_limits`, `direct_loss_pauses_large_copy`, `owner_change_cancels_range_read`, `missing_source_retains_metadata`, `current_chat_not_starved_by_backfill`.
- [ ] Run tests with generated streaming sources and instrumented peak reads; expected RED.
- [ ] Copy only authenticated referenced content using encrypted resumable chunks and bounded range reads; hash chunks/whole content before marking available. Handle existing small cache migration and group sparse references. Preserve partial progress across restart, enforce route-specific caps and request budgets; never assemble a whole large file or trust a remote filesystem path. Prioritize current chat/presence over bulk historical transfer.
- [ ] Run cache/chunk/attachment regressions; expected PASS with bounded memory independent of file size. Include >25MiB real Direct transfer in Task9.
- [ ] Commit `feat: synchronize available attachment caches resumably`.

### Task 8: Authenticated lifecycle and Profile Devices

**Files:** Create `device_sync/devices_section.dart`; modify `account/account_gate.dart`, `profile/profile_page.dart`, platform bridges and tests.

**Interfaces:** Inject optional `DeviceSyncController` into ProfilePage; authenticated home owns one controller per unlocked owner and stops/disposes it before any identity transition. Devices section consumes Task4's public view models only. Provide device-name edit through encrypted journal, max64 characters.

- [ ] Write widget tests `devices_fit_320px`, `this_device_and_platform_visible`, `online_expires_after_90_seconds`, `last_seen_not_changed_by_opening_profile`, `offline_record_survives_restart`, `lock_and_switch_stop_old_device`, `limit_state_does_not_block_local_history`.
- [ ] Run focused tests; expected RED.
- [ ] Start automatically after protected account/history/groups/profile initialization; gate capability for older cores rather than pretending sync succeeded. Show Devices with name/platform,This device,Online/Offline,Last seen, and short Syncing/Waiting when needed. Use existing timestamp formatter or a shared millisecond formatter; no explanatory wall of text. Keep narrow layout details on a new row and preserve app navigation/PIN behavior.
- [ ] Run Profile/account/navigation suites and analyzer; expected PASS and no overflow.
- [ ] Commit `feat: show linked devices and sync state in Profile`.

### Task 9: Security review, real interop and release

**Files:** Add synthetic QA harnesses under scripts/tests; update changelog/version and verification report only after acceptance. Do not replace user data for QA.

**Interfaces:** Consume all prior tasks. Use independent stores/browser contexts and one root restored internally into synthetic Windows/Android/WASM clients. Record public proofs without printing recovery/device secrets.

- [ ] Run full Rust core/relay tests and native/WASM clippy, portal tests, full Flutter tests/analyzer; expected zero failures (record intentional existing skips).
- [ ] Run three-device synthetic QA: concurrent send/edit, one device offline then catch-up, two tabs then leader close, restart retaining Device ID, local delete then backfill, contact removal, monotonic receipts, group controller offline/conflict, corrupted file and missing source. Assert identical materialized records where sync applies and no historical notifications/outbox resend.
- [ ] Transfer >25MiB on real Direct with full digest equality; interrupt/resume smaller relay transfer and verify route cap plus fair current chat. Inspect seed frame capture and reject attempted message/file/page frames; no content persisted by the public seed.
- [ ] Obtain a fresh whole-branch protocol/security review under the chosen execution workflow; fix important findings with failing regressions before release. A model quota failure is a review limitation to resolve, not a passing review.
- [ ] Build Windows release/single-file chta.exe, Android arm64 and mounted WASM web. Install Android preserving data and inspect Devices on actual device. Respect the outstanding Windows GUI Esc stop; do not claim actual Desktop UI evidence without resumed authorization. Run staging HTTP/WSS smokes before production deployment.
- [ ] Publish only after checks/review/interop; retain exact source hash, artifact versions, deployment IDs and known reachability limits in report. No Git remote operations. Finish local integration under existing authorization and preserve user untracked files/junctions.

## Self-review

Spec coverage: Tasks1–2 own certificate/private storage/journal/transactions; Task3 discovery/caps/metadata-only policy; Task4 transport/presence/anti-entropy; Task5 account/DM conflicts/deletion/notifications; Task6 groups authority/forks; Task7 ranged file copies; Task8 Profile/lifecycle; Task9 adversarial and actual-platform acceptance. The five Review Focus cases have named tests in their owning tasks. The shared `DeviceCryptoBridge.deviceCall`, signed certificate/event schemas and apply-before-checkpoint contract are consistent across tasks. Implementation must keep this design's automatic user flow; task ordering does not reduce the agreed scope.
