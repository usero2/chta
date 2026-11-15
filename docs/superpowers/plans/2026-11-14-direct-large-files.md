# Direct Large Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track steps with checkboxes.

**Goal:** Send direct encrypted files up to10GiB with bounded durable caches, resume, relay fallback <=25MiB, and progress on Windows/Android/Web.
**Architecture:** Signed capability and Noise-authenticated WebRTC negotiation; separate DTLS channel; encrypted per-owner chunk cache; source-backed attachment refs and v2 durable transfer protocol.
**Tech Stack:** Existing Rust vault/identity, Flutter, flutter_webrtc1.6.3, WebCrypto/IndexedDB, Dart incremental SHA256.
**Spec:** docs/superpowers/specs/2026-11-14-direct-large-files.md

## Global Constraints
- Direct10GiB/file; relay25MiB; legacy in-memory100MiB. Standard cache block256KiB, wire piece<=8KiB, bounded queues.
- Preserve account/history, existing media flows and default PIN settings. No real contacts/PIN/phrase testing; no remote Git.
- Durable cache encrypted and owner-bound; signaled DTLS fingerprint bound to verified identity. No implicit whole-file reads or arbitrary cache paths.
- Public interfaces and file ownership below are binding; root resolves routine implementation details continuously.

## Review Focus
- Peer/identity changes during await must not leak or dispatch old ciphertext/control/chunks to a new peer.
- Corrupt/short/duplicate chunks and failed disk writes must not advance durable progress or Delivered.
- Browser quota, missing cache and unsupported writable export must produce bounded recoverable errors.
- Relay loss after direct negotiation must preserve usable direct path; >25MiB must never silently relay.
- Legacy peers/media/history remain readable; v2 controls never display as user chat.

### Task1: Durable chunk cache
**Files:** new chat/chunked_attachment_bridge*.dart, chunked_file_cache.dart; core/core_bridge_native.dart; Rust desktop_vault.rs/native.rs (new module permitted); web/cht_core_loader.js chunk storage; focused Rust/Dart tests.
**Interfaces:** exact bridge/state/cache signatures in spec. No ownership of ChatAttachment, AttachmentRef, ConnectionPage, RelayChat or pubspec.
- [x] Write failing owner/tamper/sequential/retry/final-hash/reopen tests; run RED.
- [x] Implement bounded encrypted native commands and Web chunk adapter; Dart incremental import/open helper; verify GREEN.
- [x] Review task diff and focused tests; keep source handoff clean.

### Task2: Authenticated direct channel
**Files:** new p2p/direct_file_link.dart and adapter/factory/test files; pubspec.yaml/lock for flutter_webrtc; necessary plugin generated registration/Android network manifest only. Do not edit ConnectionPage/RelayChat or cache/model files.
**Interfaces:** DirectFileLink exact spec API. sendSignal carries reserved IDs/payloads over root's authenticated existing transport. Datachannel frames stream; ready peers maintain link without rendezvous relay.
- [x] Test deterministic offer, signature-session scope via root authenticated callback, stale await, bounded queues/backpressure, reconnect and relay-loss survival RED.
- [x] Implement plugin adapter (no camera/audio) and coordinator; run fake and real loopback tests where available.
- [x] Review task; record needed root wiring/build changes.

### Task3: Source-backed attachments and UI
**Files:** new attachment_source.dart; chat_attachment.dart/ref.dart/files.dart/store*.dart, media_* and widgets source-aware paths, peer_history.dart, focused chat/widget tests. No ConnectionPage, transfer v1/protocol v2, native/core or direct transport edits.
**Interfaces:** sources/ref/cache contracts in spec; root will supply TransferProgressSnapshot/ConnectionPage wiring. Import >bounded threshold to chunk cache before send/history; reads return lazy source. UI must not call bytes for streamed media.
- [x] RED tests synthetic >100MiB source, ref roundtrip/owner-safe history, source-size picker/export and legacy media.
- [x] Implement source pick/spool/cache adapter, bounded preview/export, history pending v2 retention; no full-file stream.toList/bytes fallback for large files.
- [x] GREEN tests, review and report native/browser export constraints.

### Task4: Transfer protocol and app integration (root)
**Files:** new chat/resumable_attachment_transfer.dart/file_transfer_progress.dart; ConnectionPage; minimal RelayChat external control hooks if needed; Rust contacts.rs capability; focused protocol/integration tests.
**Interfaces:** consumes Tasks1-3; offer/resume/pieces/durable-block ack/finish with bounded data and peer-bound IDs. Root wires direct signaling, transport selection, incoming/outgoing history and card progress.
- [x] RED tests >100MiB streaming exact hash + bounded buffers, disconnect/recreation resume, direct/relay limit, corruption and peer switch.
- [x] Implement v2 protocol, capability-gated direct-first connection and data routing, progress/rate and automatic resume from history. Preserve legacy V1.
- [x] GREEN integrations and peer-bound cryptographic review; address material findings.

### Task5: Whole branch verification and delivery
- [x] Fresh independent whole-branch review and fix serious findings; full Rust/Flutter/analyzer checks.
- [x] Disposable real WebRTC/native/browser >100MiB transfer, hash/memory/resume verification. No real contact sends.
- [x] Version25 fresh Android native/APK, Windows/Web builds, install-r connected device preserving data, document evidence and actual limits.
