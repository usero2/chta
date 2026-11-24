# P2P UX Hardening Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. The user previously chose Native execution; use one final independent read-only review.

**Goal:** Complete the six approved P2P usability improvements with durable delivery and shared platform behavior.

**Architecture:** Keep account-scoped messaging and protected storage. Add independent send budgets and persisted delivery controls, event-driven recovery/scheduling, an attachment budget manager, and an immutable room-page history store.

**Tech Stack:** Flutter/Dart, existing Web APIs/native Android runtime, current Rust encrypted vault, existing public WSS relays. No new infrastructure.

**Spec:** `docs/superpowers/specs/2026-11-17-p2p-ux-hardening-design.md`.

## Global Constraints

- Preserve E2E encryption, durable ACK, IDs/timestamps, duplicate detection, owner/generation/delete guards, 25 MiB relay limit and existing Direct large-file limit.
- Preserve owner history/settings and unrelated Linux/target junction. No private data, absolute owner paths, credentials or screenshots in public source/artifacts.
- No paid TURN/new servers/mailbox/telemetry, real-contact QA messages, Windows GUI or GitHub publication.
- Cache budget defaults 20 GiB, range 1–1024 GiB, with known-free-space reserve 256 MiB; never auto-delete user files.
- Build/audit/install current Android/Windows/Web as version 43.

## Review Focus

- Eight slow/broken file jobs must leave text/receipts usable, including after lock/delete.
- Permanent rejection, paused state and network waiting must have different persisted retry behavior; late receipts stay valid.
- Resume/network-change callbacks cannot resurrect a locked/switched account or trigger an endless reconnect storm.
- Cache reservations must count concurrent jobs and survive reload; storage errors must withhold ACK.
- Failed migration/page/manifest writes must preserve readable history and pending outbox; modifying one room must not rewrite another.

## Tasks

### Task 1: Fair durable outbox and permanent failures

Files: `lib/chat/durable_outbox.dart`, `peer_history.dart`, `messaging_service.dart`, `p2p/peer_file_controller.dart`; `test/chat/durable_outbox_test.dart`, `messaging_service_test.dart`.

Interfaces: produce `PeerMessage.deliveryPaused`, `failureReason` and explicit delivery-intent control while retaining JSON compatibility; four text/four file budgets. Later file controls consume these fields.

- [x] Add audit regressions: eight blocked files do not block text; permanent TransferRejected ends auto retry after 10 seconds; transient failures/restart still retry; reasons survive history reload.
- [x] Run RED, implement fair category budgets and classify permanent cache/file errors; persist terminal intent removal before re-pumping.
- [x] Run affected existing/new tests GREEN and commit locally.

### Task 2: Network observations and account recovery

Files: create `lib/runtime/network_monitor*.dart`, `network_recovery.dart`; modify Android runtime/MainActivity, `account_gate.dart`, `messaging_service.dart`, `relay_network.dart`, `seed_client.dart`, `direct_file_link.dart`, `peer_file_controller.dart`; add runtime/recovery tests.

Interfaces: `NetworkObservation`/monitor stream reports connectivity hints, not delivery; `MessagingService.recoverNetwork()` and account-scoped debounced coordinator are owner guarded. Transport recovery retains pending data and resets obsolete backoff.

- [x] RED tests for offline→online/transport switch/resume, duplicate-event debounce and disposal/identity-switch cancellation.
- [x] Implement native/browser observations with bounded desktop fallback; recover WSS/seed/Direct using existing authenticated signaling and a fresh Direct negotiation when needed.
- [x] GREEN recovery, Direct and relay regression suites; commit locally.

### Task 3: Event-driven draining and adaptive scheduler

Files: `messaging_service.dart`, `relay_chat.dart`, `peer_file_controller.dart`; scheduler tests.

Interfaces: optional account-owned ticks/event callback on RelayChat; one MessagingService scheduler (active one second/idle five seconds), coalesced poll requests. Standalone/group transport owners retain compatible defaults.

- [x] RED tests for prompt event delivery, no idle UI notifications, bounded active/idle ticks, and live receipts during slow file/Direct work.
- [x] Replace 250 ms polling and account-owned peer timers with coalesced event draining plus shared retry/liveness checks.
- [x] GREEN messaging, relay and Direct tests, including task 1 fairness; commit locally.

### Task 4: Room-scoped protected history

Files: create `lib/chat/room_history_store.dart`; modify `peer_history_store.dart`, `peer_history.dart`, owner wiring and changed-room call sites; add room-store/migration tests.

Interfaces: optional incremental store capability saves metadata + changed rooms using immutable protected pages/atomic index; existing PeerHistoryStore implementations/tests remain compatible. `PeerHistory.changed([String? peerId])` marks a specific room when supplied; unspecified callers conservatively mark all. Preserve encrypted legacy backup.

- [x] RED migration/failure tests: page write failure, manifest failure, missing/corrupt committed page, owner isolation, delete/tombstones, concurrent flush and one-room write count.
- [x] Implement staged immutable pages/manifest, legacy fallback only before migration; route shared native/Web storage through GroupBlobBridge; save only changed room data and keep generation guards.
- [x] GREEN history, outbox, notifications, sync/account suites; commit locally.

### Task 5: Cache budget, free space and transfer controls

Files: create `lib/chat/cache_policy*.dart`, cache settings/control widgets; modify attachment-store/chunk-store wrappers, account/Profile wiring, transfer classes, outbox and conversation file status UI; platform free-space bridge if needed; add tests.

Interfaces: one account-owned cache manager loads/saves protected budget/reservations, reserves before writes and exposes usage/settings. Pending file controls set persisted deliveryPaused/failureReason/intent; transfer-scoped interruption retains verified chunks and leaves text channels alive.

- [x] RED tests for limit/range, existing-data accounting, concurrent reservations/restart, low/unknown free space, quota/disk failures and owner switching.
- [x] Add shared budget-aware cache wrappers, native/browser capacity estimates and concise Profile controls; default auto-cache remains enabled.
- [x] RED→GREEN Pause/Resume/Cancel tests, including in-flight chunks, restart, a late receipt and another peer/text remaining active; add file action UI with persisted state and reasons.
- [x] GREEN cache/transfer/history/UI/group-import regressions; commit locally.

### Task 6: Review, verification and version 43

Files: QA documentation, `pubspec.yaml`; existing sanitized private build helpers.

- [x] Run full Flutter/static checks, relevant Rust/Web/native integration checks and one fresh final read-only review of the whole branch. Fix Important findings in one RED→GREEN pass and rerun suites.
- [x] Build/audit Android, Windows single EXE and Web 43; verify no private identifiers/paths/secrets in source or decompressed artifacts.
- [x] Sync only owned source changes into the original workspace after conflict checks; install Android, preserve running Desktop process, deploy existing Web. Inspect available physical UI without owner setting/message/PIN changes. Record untested carrier/Doze/soak cases honestly.
- [x] Commit source/QA locally, preserve worktree and unrelated files. No GitHub push/release.
