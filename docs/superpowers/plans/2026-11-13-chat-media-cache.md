# Chat Media Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Automatically persist incoming attachments independently of chat history and deliver the minechat existing-media flow on Android without adding camera/recording.

**Architecture:** An identity-scoped encrypted blob cache stores file bytes by SHA-256; peer history stores validated references and presentation metadata. Existing embedded histories migrate only after successful cache writes. The existing encrypted chunk protocol carries bounded optional caption/group metadata, and Flutter provides staged selection, album rendering and cached media viewers.

**Tech Stack:** Rust existing platform vault protection, Flutter/Dart, current file_picker/media-kit, Web IndexedDB/WebCrypto. No new cryptographic library.

**Spec:** `docs/superpowers/specs/2026-11-13-chat-media-cache-design.md`

## Global Constraints

- No camera capture, CCTV, audio recording or video recording. Keep the existing QR scanner.
- Select existing images, videos, audio and files; preserve identity, contacts, routes, timestamps, relays and existing chat data.
- Current limits: 5 staged items, 100 MiB total selection, 100 MiB per direct file and 25 MiB per relay file; 8 KiB chunks, eight unacknowledged packets.
- Encrypted cache is scoped to the unlocked identity; no plaintext persistence on automatic receipt and no automatic execution of received files.
- Final file receipt follows successful durable cache/history writes. Failed writes retain recoverable legacy data and permit retry.
- Concise UI copy. Save copy is an export; previews and playback use cached content.
- Build fresh native registrations after dependencies: successful flutter pub get, then scripts/verify-flutter-plugins.py before any --no-pub release build.
- Never read/type a user's PIN/phrase or send messages to real contacts while testing. Leave user screenshots and 5279.mp4 untouched.

## Review Focus

1. Identity switches during cache reads/writes must not expose another identity's bytes or save the result into the newly selected room (Tasks 1–2 tests).
2. Disk failure between blob persistence and history migration must leave old embedded history recoverable and withhold final delivery (Tasks 1–2 tests).
3. Retry of the final chunk after a failed durable write must retry persistence rather than lose the already assembled file (Tasks 2–3 tests).
4. A caption plus a long filename or multibyte text must not exceed wire limits or be truncated silently (Task 3 tests).
5. A partial media batch, unsupported video codec or cancelled picker must preserve usable messages/drafts, not group unrelated files or block the entire chat (Tasks 4–5 tests).

---

### Task 1: Encrypted identity-scoped native attachment storage

**Files:** Modify `rust/crates/core/src/desktop_vault.rs`, `rust/crates/core/src/native.rs`; create `rust/crates/core/tests/attachment_cache.rs` or extend their existing private-unit-test modules where fixtures require private access.

**Interfaces:** Produce native commands `savePeerAttachment(ownerId, digest, data)` and `loadPeerAttachment(ownerId, digest)`; data is standard base64, digest lowercase SHA-256 hex. Vault methods `save_attachment(&self, owner: &str, digest: &str, bytes: &[u8]) -> Result<(), String>` and `load_attachment(&self, owner: &str, digest: &str) -> Result<Option<Vec<u8>>, String>`.

- [x] Write failing tests: save/load across reopen; on-disk bytes do not contain a known fixture; another identity/digest cannot decrypt; invalid digest/path/hash/over-100-MiB input rejected; locked/wrong-owner native command denied; identical content save is idempotent; corrupt cache read fails without overwriting it.
- [x] Run `cargo test -p cht-core attachment` and record RED.
- [x] Implement using existing vault protection with domain-separated entropy `cht-attachment-v1:<owner>:<digest>`, atomic writes under `attachments/<owner hash>/<digest>.bin`, bounded reads, digest verification and zeroized plaintext buffers. Do not return disk paths to Flutter.
- [x] Run `cargo test -p cht-core`; expect zero failures. Commit `feat: add encrypted identity-scoped attachment vault`.

### Task 2: Flutter cache references, migration and durable receipts

**Files:** Create `apps/flutter_app/lib/chat/attachment_store.dart`, `attachment_store_native.dart`, `attachment_store_web.dart`, `attachment_store_stub.dart`, `attachment_ref.dart`; modify `core/core_bridge_native.dart`, `web/cht_core_loader.js`, `chat/peer_history.dart`, `account/account_gate.dart`, `p2p/connection_page.dart`, `chat/attachment_transfer.dart`; add `test/chat/attachment_store_test.dart`, extend history/connection tests.

**Interfaces:** `AttachmentRef(name, mimeType, size, digest)` with strict JSON parsing; `AttachmentStore.put(String ownerId, ChatAttachment file) -> Future<AttachmentRef>` and `read(String ownerId, AttachmentRef ref) -> Future<ChatAttachment>`. A separate native `AttachmentBridge` exposes the two Task 1 commands. `PeerMessage` has optional `attachmentRef` alongside legacy embedded attachment; `PeerHistory.addAttachment(String peerId, PeerMessage message) -> Future<void>` persists cache/reference before success; `PeerHistory.resolveAttachment(PeerMessage message) -> Future<ChatAttachment>` resolves either representation. Optional injected store keeps unit-test bridges independent of production storage.

- [x] Write failing tests: receive without any export click, restart/offline reopen, content equality; owner isolation; legacy history migrates to references without embedded bytes only after successful blob/history writes; failure preserves original history; final ACK withheld until a delayed cache write completes; final-chunk retry after write failure succeeds once without duplicate message.
- [x] Run focused store/history/connection tests and record RED.
- [x] Implement native bridge and Web encrypted IndexedDB blobs using existing wrapping-key pattern, keyed `peer-attachment:<ownerId>:<digest>`. Missing/corrupt blobs produce an explicit retry/error state, not an empty file.
- [x] Wire persistent cache into authenticated-home history. Keep file bytes out of reference-only history; resolve lazily for visible cards/viewers/retry. Existing text storage remains compatible.
- [x] Make the attachment receiver callback accept `FutureOr<void>` and await durable storage before marking a transfer completed. Keep a complete incoming buffer retryable on persistence failure. Preserve bounded buffering/packet backpressure.
- [x] Run `flutter test --no-pub` and `flutter analyze --no-pub`; expect zero failures/issues. Commit `feat: persist received media in encrypted chat cache`.

### Task 3: Compatible media batch and caption metadata

**Files:** Modify `chat/chat_attachment.dart`, `attachment_ref.dart`, `attachment_transfer.dart`, `peer_history.dart`; extend transfer/history tests and add `test/chat/media_batch_test.dart`.

**Interfaces:** Add optional `caption`, `groupId`, `groupIndex`, `groupCount` to ChatAttachment/AttachmentRef serialization with legacy defaults. Group ID <=64 ASCII alphanumeric/underscore/hyphen characters; index 0..4, count 1..5, index<count; caption <=512 UTF-8 bytes. A missing group keeps a standalone message. `ChatAttachment.withPresentation(...) -> ChatAttachment` shares immutable bytes.

- [x] Write failing tests: optional metadata survives transfer, cache and reopen; legacy packets still accepted; inconsistent group metadata rejected; 5-item bounds enforced; Unicode/long-name packet >12000 characters rejected before any send; data+metadata are not truncated; retries retain metadata.
- [x] Run transfer/history/batch tests; record RED.
- [x] Carry optional fields in existing authenticated attachment chunks and check metadata consistency and serialized size before queuing. Preserve 8 KiB chunks and 12000-character/24000-byte relay constraints. Old receivers may ignore new optional fields and display standalone files.
- [x] Persist presentation fields with references (cache blob identity still depends only on bytes). Run full Flutter suite and analyze; expect green. Commit `feat: carry captions and media batch metadata`.

### Task 4: Existing-media selection and one-action batch sending

**Files:** Modify `chat/attachment_files.dart`, `widgets/message_composer.dart`, `p2p/connection_page.dart`, `chat_controller.dart`, `widgets/chat_room.dart`; create `widgets/pending_attachment_tray.dart`, `widgets/attachment_picker_sheet.dart`, `chat/media_batch.dart`; extend composer/connection tests.

**Interfaces:** `PreparedMediaBatch prepareMediaBatch(String text, List<ChatAttachment> files, String batchId)` orders images, videos, then other files while retaining order within each type. First eligible item gets the caption; each same-kind group has a distinct ID derived from batchId, with stable ordinal/count. Composer accepts `Future<bool> Function(String, List<ChatAttachment>)? onSendBatch`; true means the whole batch is durably queued, not necessarily delivered. Cache all outgoing files before committing batch metadata; network failures thereafter use existing failed-message retry. Failed durable queueing keeps the draft and avoids duplicate entries on another click.

- [x] Write failing tests: selecting existing mixed gallery media; 76px removable preview tiles and video play indicator; audio/files retained; caption applied exactly once with images/video/file priority; no separate duplicate caption text; cancellation/failure preserves draft; successful queue clears draft; double click/navigate away never duplicates or touches disposed controllers; narrow 320px layout.
- [x] Run composer/batch/connection tests; record RED.
- [x] Add mobile attachment sheet for Gallery, Audio, Files; Gallery uses FileType.media. No capture/recording actions. Keep desktop choices appropriate.
- [x] Queue a batch with stable message IDs and explicit groups, store metadata once, then send files sequentially through current policy. Preserve per-file progress and retries. Local example rooms keep their existing storage path but understand optional presentation metadata.
- [x] Run full Flutter suite and analyze; expect green. Commit `feat: add staged media batches and captions`.

### Task 5: Cached albums, video thumbnails and media viewers

**Files:** Create `widgets/media_album.dart`, `widgets/media_viewer.dart`, `chat/media_thumbnail.dart` with conditional platform helpers as needed; modify `widgets/attachment_content.dart`, `widgets/message_composer.dart`, `widgets/chat_room.dart`, `p2p/connection_page.dart`; add album/viewer/thumbnail tests.

**Interfaces:** `MediaAlbum(items, onOpen)` displays same-direction, same-group message entries ordered by groupIndex. Resolve cache bytes through Task 2 callbacks. Thumbnail generation is best effort, uses received cached bytes only, and never blocks durable receipt. Persist bounded thumbnails separately in the encrypted blob cache if generated; fallback remains a usable video play tile.

- [x] Write failing tests: album grouping by explicit ID only; partial 1-of-3 group remains usable; caption below its group exactly once; image viewer browses/zooms cached album; audio/video controls use cached bytes; no autoplay; unsupported video retains filename/Save copy; cache indicator and Save copy export do not initiate network downloads; narrow/landscape layouts do not overflow.
- [x] Run album/viewer/content tests and record RED.
- [x] Render image grids and video thumbnail rows, with concise cached-state indicators and **Save copy** export. Open full-screen media routes backed by the cache, with image paging/zoom and accessible playback/seek controls. Generate previews from cached files using existing media-kit/native/Web APIs, and clean only app-owned decrypted temporary previews after use.
- [x] Run full Flutter suite and analyze; expect green. Commit `feat: show cached media albums and viewers`.

### Task 6: Integration review and fresh platform delivery

**Files:** Extend `scripts/check_chat_attachments_browser.js`, `scripts/create_chat_test_fixtures.py`, `scripts/verify-flutter-plugins.py` if needed; update `docs/chat-media.md`, `docs/android.md`, this plan and a test report.

- [x] Run baseline and final Rust/Flutter suites. Browser disposable identities must send multiple images/videos/audio/files over both direct and relay paths, compare bytes and reopen cached history offline. Test metadata bounds, one injected cache-write failure and legacy migration.
- [x] Use a fresh review of the complete diff/spec/plan, resolve important findings with failing regression tests, and record evidence/rulings in the ledger. Do not repeatedly run already green suites without a new change/failure.
- [x] Integrate reviewed changes back into the shared checkout without discarding user work. Rebuild Rust Android core/WASM as needed, run flutter pub get successfully, verify native registrations, then release builds for Android/Windows/Web with a new common build number.
- [x] Install on connected Android and launch Desktop. User enters PIN locally; verify actual existing-file selection, cache reuse and presentation. Do not send test chat to real contacts. Keep hardware-dependent claims limited to observed results.
- [x] Record artifact versions, test evidence, cache limits and any remaining limitations; commit `docs: document automatic media cache and verification`.

Final release: build22. See `docs/chat-media-cache-verification.md` for observed checks and hardware limits.
