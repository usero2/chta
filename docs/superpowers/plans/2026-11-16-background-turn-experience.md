# Background reception and fallback implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one independent final read-only review.

**Goal:** Implement recommendations 4, 6 and 7: Android background reception, Windows tray, honest status and real network regressions. The user explicitly deferred recommendation 5 (TURN) because it could incur additional charges.

**Architecture:** Account-scoped runtime controller bridges the existing native platform channel and MessagingService. Native Android service retains the existing engine; native Windows runner hosts tray and shutdown coordination. Short-lived TURN credentials are fetched through authenticated server control, with route evidence derived from WebRTC stats.

**Tech stack:** Flutter/Dart, existing Rust native/WASM crypto, Kotlin Android, Win32 C++, Cloudflare Workers/Durable Objects and optional Realtime TURN.

**Spec:** `docs/superpowers/specs/2026-11-16-background-turn-experience-design.md`.

## Global constraints

- Preserve private original repository history; work in the existing isolated public-source worktree. Never recursively clean its target junction.
- No owner PIN/key inspection, real-contact test messages, permanent client TURN secrets, offline server mailbox, billing activation without the pending explicit answer, or unauthorized Windows GUI automation.
- Run meaningful RED/GREEN regressions, build all supported current platforms and sanitize delivery artifacts.

## Review focus

- Closing/reopening a window or Activity must retain the same account service, not create competing owners.
- Explicit lock/exit must stop native background ownership and flush durable work even during an in-flight transfer.
- TURN auth expiry and backend failure must fall back to existing data relays without breaking chat.
- Candidate statistics must not incorrectly report TURN as direct or weaken fingerprint/peer verification.
- A positive UI status must reflect an authenticated route or durable receipt, never discovery alone.

## Tasks

- [x] 1. Add a testable app-runtime bridge/controller for account lifecycle, background preference, lock action and flush-before-exit. Wire it above navigation and into Profile.
- [x] 2. Implement Android foreground remote-messaging service, notification action and retained-engine lifecycle. Physical isolated QA verified Home/return, background text/file reception, progress/hash and explicit Lock. Activity destruction and deep Doze remain unverified.
- [x] 3. Implement native Windows tray Open/Exit, close-to-tray, single-instance restore and graceful exit handshake. Native headless policy/mutex tests and release compilation passed; no owner GUI automation.
- [x] 4. Deferred by user: no TURN broker, credentials or paid-service activation.
- [x] 5. Deferred with TURN: retain existing direct-only ICE checks and large-file policy.
- [x] 6. Implement concise transport/delivery/background status and notification visibility, including validation errors instead of infinite retry for unsendable input, and Waiting for Direct for large queued files.
- [x] 7. Verification complete within the recorded matrix in `docs/qa/background-reception-38.md`: 375 Flutter tests passed, 8 opt-in/platform tests skipped; the physical Android/native public-relay proof ran separately and passed. Static analysis clean, native tray/mutex harness passed, independent review cleared. Sanitized Windows single EXE, Android and WASM build 38 installed/deployed; source retained locally. No new GitHub release, TURN service or owner-message tests.
