# Private Groups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Independent crypto, sparse swarm and homepage work have separate file ownership; root integrates transport and UI. Steps use checkbox syntax.

**Goal:** Ship chat actions, encrypted groups and private multi-source file transfers on Android, Windows and Web.
**Architecture:** Owner-signed membership/explicit acceptance, an independent per-peer group Noise registry and purpose-bound WebRTC signaling, durable encrypted group state, and a sparse proof-verified piece swarm. Existing direct-message sessions and contiguous file transfers remain compatible.
**Tech Stack:** Existing Rust/Ed25519/snow, Flutter/Dart, encrypted native vault and IndexedDB, WebRTC, existing community relays and discovery-only Cloudflare seed.
**Spec:** docs/superpowers/specs/2026-11-15-private-groups-design.md (approved 2026-11-15).

## Global constraints
- No real conversation sends/deletions, PIN/phrase reads, remote Git, public torrents or new group cipher. Synthetic identities for QA.
- At most 16 active/reserved members per group. Initial owner-only membership changes; explicit signed acceptance; owner online finalizes joining. Creator Leave closes the group with confirmation; ordinary Leave signs a request and immediately disables local sends.
- Highest **known** signed membership governs delivery. Old plaintext and stale partitioned peers cannot be remotely revoked. A new member receives old files only through explicit current-epoch re-share.
- Pieces 256 KiB, parts 8 KiB, frames 16 KiB, 40,960 pieces, proof depth <=16, eight assemblies/four sources/two assemblies per source. Relay files <=25 MiB, Direct <=10 GiB. Seed carries SDP/ICE only.
- Owner/identity/generation binding on every async operation; persist encrypted state/outbox/dedup/cache. Avoid whole-file buffers.
- Root owns source commits, integration, platform version27+, installation and publication. Existing user files remain untouched.

## Review focus
- Invite bootstrap and accepted nonfriend members must authenticate without resetting/marking personal DM friends (Tasks1,3,4).
- Reordered/forked membership and removal during an active piece request must never authorize against stale known state (Tasks1,2,4).
- Lock/switch/restart while encryption or disk writes await must not publish data under another identity or restore deleted outbox (Tasks2,4,5).
- Group seed topic must never route message/file content or collide with legacy direct-v1 negotiation (Tasks1,3).
- Disjoint cached pieces must survive restart and complete from B+C after uploader A is offline (Tasks2,6).

## Fixed interfaces

### Crypto gateway (Task1 owns all adapters)
New `lib/groups/group_crypto_bridge.dart`:
`abstract interface class GroupCryptoBridge { Future<Map<String,Object?>> groupCall(String operation, Map<String,Object?> args); }`
Rust `AccountCore.group_call(operation,args) -> Result<serde_json::Value,String>` holds independent bounded group state and per-peer Noise sessions. Private keys stay Rust. All operations reject unknown fields and invalid identities. Stable operation inputs/results:

| Operation | Arguments | Result |
|---|---|---|
| create | name, displayName, now | state: signed JSON string |
| invite | groupId, peerId, now | invite: signed JSON string |
| accept | invite, displayName, now | receipt: signed JSON string, groupId, ownerId |
| add | receipt, now | state: signed JSON string |
| apply | state | groupId, epoch |
| remove | groupId, peerId, now | state: signed JSON string |
| leave | groupId, now | event: signed JSON string OR state for closing owner |
| sign | groupId, id, kind, payload (JSON string), now | event: signed JSON string |
| inspect | event | groupId, epoch, sender, id, kind, payload (string), sentAt |
| view | groupId | groupId, name, ownerId, epoch, closed, members:[{identityId,displayName,identity}], states:[signed JSON strings] |
| list | empty | groups:[view results] |
| export | empty | data: serialized public group engine state |
| import | data | empty (validate all signatures/chains; no secret/session import) |
| authorize | peerId, optional groupId, optional epoch | allowed:bool, optional identity:PublicIdentity |
| prepare | peerId, sessionId (32hex), initiator | empty |
| start | peerId, sessionId | frame:base64url |
| handshake | peerId, sessionId, frame | reply:string?, established:bool |
| encrypt | peerId, sessionId, id, text | frame:string |
| decrypt | peerId, sessionId, frame | id, text, duplicate |
| closeSession | peerId, sessionId | empty |
| signSignal | peerId, id, text, now | source: signed JSON string |
| inspectSignal | source, expectedPeer, now | peerId, messageId, text |

Group IDs `group:` +64 lowercase hex. Document timestamps are milliseconds. Pending invite expiry seven days. A member capsule self-signs group ID, owner ID, PublicIdentity and display name, so an owner cannot substitute another member's Noise static key. Owner signs a capsule at genesis; acceptance contains recipient capsule. State epoch starts1 and successors hash the exact previous signed state. Root cannot use any group operation to mark a personal contact verified. Crypto implementer writes exact canonical document schemas/domains to `docs/superpowers/specs/2026-11-15-group-wire.md` before returning; consumers use gateway view results rather than assuming signature internals.

`authorize(peerId)` permits a verified personal friend (bootstrap) or accepted common group member; groupId/epoch restrict to active membership now and at the requested file epoch. Max64 simultaneous group peer sessions; group-session prologue includes protocol and session ID (independent of legacy). Crypto registry clears on lock/discard. Noise transport includes authenticated peer/session bound application payload. UI group events use kinds message/file/ack/leave; payload is bounded content, never sent through the seed.

Group seed schema is **version2**, `topic:"groups"` plus exact v1 fields. Canonical domain `chta group seed signal v1\0`, tuple `[2,"groups",from,to,session,id,kind,payload,issuedAt,expiresAt]`. SDP/ICE payload/id validation identical to current DirectFileLink; a distinct GroupSeedClient and DirectFileLink instance per peer prevents legacy delivery. TTL120s/skew30s/replay bound4096. Sign/inspect authorize peer via verified friend or accepted membership. Legacy v1 validator rejects v2. Cloud Worker accepts only these exact two schemas.

### Encrypted blob storage (Task2 owns implementation; Task1 wires adapters)
New `lib/groups/group_blob_bridge.dart` exposes `loadGroupBlob(ownerId,key)->Future<String?>`, `saveGroupBlob(ownerId,key,value)->Future<void>`, `deleteGroupBlob(ownerId,key)->Future<void>`. Keys `[A-Za-z0-9_-]{1,128}`, values UTF8 <=8MiB, owner must be active DID at native/WASM boundary. Native vault purpose-bound owner/key protection, hashed paths, atomic writes, size-bounded reads; Web dedicated nonextractable AES-GCM CryptoKey with owner/key AAD and encrypted IndexedDB blobs. Do not overwrite legacy history. Native vault methods `load_group_blob`, `save_group_blob`, `delete_group_blob` in new desktop_vault/group_blobs.rs. JS module `web/group_blob_store.js` exports corresponding JS async functions; Task1 imports/exports them through `chtCore` and wires native dispatch/core adapters. Task2 does not edit native.rs/wasm.rs/account.rs/core adapters/cht_core_loader.js.

### Sparse swarm (Task2 owns Dart implementation)
New `lib/groups/swarm/`:
- `SwarmManifest` strict fromJson/toJson, fields groupId,epoch,uploaderId,fileId(32hex),name,mimeType,size,pieceSize,digest,merkleRoot,optional caption. Exact SHA256/Merkle canonical leaf/index/last-size/padding documented with test vectors. No signature in this model; only register manifests already verified inside a signed group file event.
- `SparseSwarmCache(ownerId, blobs:GroupBlobBridge, attachments:AttachmentStore)` uses encrypted existing AttachmentStore per context-wrapped 256KiB piece, durable paged refs/proofs/bitmap through blobs. Piece wrapper and cache keys bind group/uploader/file/epoch/index/manifest. No new Rust bulk cache format.
- `importFile({groupId,epoch,uploaderId,fileId,required ChatAttachment file})->Future<SwarmManifest>`, `begin(manifest)`, `status(manifest)->Future<SwarmCacheStatus>` (verifiedBytes,complete,available:Set<int>), `readPiece(manifest,index)->Future<SwarmPiece>` (bytes,proof), `putPiece(manifest,index,bytes,proof)`, `open(manifest)->Future<ChatAttachment>` as ranged streaming source. Verify whole digest before complete/open; a partial holder can serve verified pieces.
- `SwarmTransfer(ownerId,cache,authorize:FutureOr<bool> Function(String,SwarmManifest),peers:List<String> Function(SwarmManifest),isDirect:bool Function(String),send:Future<void> Function(String,String),onComplete:void Function(SwarmManifest))`; `register(manifest)`, `receive(peer,source)`, `tick()`, `close()`, `progressFor(fileId)->SwarmProgress?` with verifiedBytes,totalBytes,sourceCount,complete,waitingForDirect. Expose changes as ChangeNotifier. Transfers accept only locally registered signed manifests; packets prefixed `chta-swarm-v1` identify file and request/availability/piece/part, strict16KiB UTF8 bounds. Bounded pending work, corrupt-source penalty, rare-first piece selection, durable resume, no peer-derived file identity. Cache pages keep metadata values below8MiB. Larger than25MiB uses Direct sources only.

### Root transport and integration (Tasks3–5)
- `GroupTransport` lifecycle independent of selected chat. One per authenticated home, managed peer map capped64, root GroupCryptoBridge calls and separate group seed socket; supports `connect(peer)`, `send(peer,text)`, `isDirect(peer)`, `frames` stream(peer,text), `changed`, `close`.
- Shared RelayNetwork adds subscriber callbacks without replacing legacy onFrame. Group relay bodies use distinct `type:"group-v1"`; outer relay schema unchanged. Encrypted Noise frames can be fragmented into <=12KiB pieces, <=8 pieces/64KiB assembled, strict peer/session/id/count binding and expiry. Use independent group prologue and post-handshake root identity proof if necessary. Relay and Direct session transitions must rekey rather than reuse divergent Noise counters.
- New `GroupController` owns crypto state import/export, encrypted blob index/history/outbox, contacts bootstrap, invite acceptance, membership chain reconciliation, group events/acks, sparse swarm and notifications. Serialized state changes and identity generation guards. Persist before acknowledging. Dedup message IDs must bind sender/group; recipients pinned to epoch when sent.
- AuthenticatedHome owns controller, passes shared RelayNetwork after ConnectionPage initialization; groups continue across tabs/room selection. Group room route parsed before contact route. Show group rows in both local and peer sidebars. Root UI files may be split from AccountGate/ConnectionPage instead of expanding further.
- Contact details and local delete actions use existing avatars/fingerprints; local CoreChat and peer histories expose clear methods with persistence and pending-send cancellation. Group deletion retains membership; local flags prevent old callback/outbox resurrection.

## Tasks

### Task1: Group cryptography and bridge wiring (independent implementer)
Own new Rust groups modules/tests + account.rs/lib.rs/native.rs/wasm.rs/secure_session.rs as needed, new GroupCryptoBridge, core_bridge_native.dart/core_bridge_web.dart/cht_core_loader.js wiring, contacts capability; new wire doc. No UI/relay/swarm/portal edits.
- [ ] RED: explicit accept, forged owner/member capsule, rollback/fork, recipient-bound expiry, outsider/removed member, owner close, imported chains, independent simultaneous A-B/A-C Noise+legacy sessions, cross-session substitution, locked APIs, v1/v2 seed separation/tamper/expiry/replay.
- [ ] Implement strict gateway and bounded registry; coordinate Task2 blob hooks only through fixed interfaces.
- [ ] GREEN: Rust core tests/fmt/native+wasm clippy and real native/WASM JSON parity. Report exact commands/logs; root commits.

### Task2: Sparse encrypted cache and private swarm (independent implementer)
Own blob bridge + JS group_blob_store.js + desktop_vault/group_blobs.rs and module declaration only + all lib/groups/swarm/** and focused tests. No files owned Task1/root/UI.
- [ ] RED: disjoint native/Web blob encryption/AAD, tamper/size/path, sparse pieces restart, wrong index/proof/group, whole digest, ranged streaming, zero/small/max bounds, A offline D downloads complementary B+C, corrupt/stalled/revoked peer, >25MiB relay waits.
- [ ] Implement streaming import/Merkle/sparse durable page cache/scheduler with above exact API; synthetic network test intentionally disconnects A and records both B/C as sources.
- [ ] GREEN: focused Dart tests/analyze and native blob tests. Root handles adapters, full suite and actual browser QA.

### Task3: Background peer transport and seed topic (root)
Own new group_seed_client.dart/group_transport.dart, shared RelayNetwork subscriber support, portal protocol v2 support/tests.
- [ ] RED seeded two simultaneous peer negotiations and legacy coexistence; public Worker rejects content and wrong topic/signature; fragmented frame limits/reorder/timeouts/rekey.
- [ ] Implement group-specific signing/verification/client peer map and bounded rate/queues; authenticated encrypted Direct/relay paths.
- [ ] GREEN focused Flutter/Worker tests, actual synthetic public/local WebRTC proof; root commit.

### Task4: Group state/history/outbox/notifications (root)
Own new group_controller.dart/models/store/tests; reads fixed crypto/swarm interfaces.
- [ ] RED invite/accept/owner finalize; multi-recipient ack/dedup/outbox restore; known epoch reconcile/removal; lock/switch/delete races; incoming notifications only after persistence.
- [ ] Implement background group lifecycle, immutable event routing, explicit group membership and signed file registration; serialize public state and outbox in owner-scoped encrypted blobs.
- [ ] GREEN controller tests with synthetic actors and actual crypto harness where possible; commit.

### Task5: Chat menu, group creation and room UI (root)
Own AccountGate/ChatShell/ConnectionPage/ConversationList/group widgets, local Rust/Core chat clear gateway if needed (coordinate Task1 to avoid same files).
- [ ] RED widget tests local history deletion retains friend, details, plus same header, create/accept/group rows/routes/sender names/delivery counts/media/progress, narrow width and selection preservation.
- [ ] Implement reusable dialog/sheets and existing media composer/viewer/Markdown notifications; refresh routes preserve group selection. Creator leave closes with explicit confirmation.
- [ ] GREEN Flutter tests/analyze and real mobile/desktop/Web visual proof with synthetic data; commit.

### Task6: Integration, independent review and release (root)
- [ ] All meaningful Rust/Flutter/Worker checks, A-offline B+C-to-D resume/hash proof, simultaneous DM and group traffic, 25MiB relay/large Direct enforcement, native/Web encrypted cache and no seed content.
- [ ] Fresh whole-branch security/concurrency review using most capable available non-quota tier. Fix serious findings RED/GREEN, all suites pass.
- [ ] Merge authorized homepage English branch separately after review and publish promptly; never overwrite Groups source with homepage artifacts. No extra design approval needed for clear English/font/how-to request.
- [ ] Build version27+ native/WASM/Android and one-file Windows, preserve user data, install connected device and run desktop. Update mounted chta.app/chat and seed backwards compat only after staging proof. Verify public routes, WSS, screenshots, final release paths. No real chat sends.
