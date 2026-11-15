# Rust/WASM Chat State and IndexedDB Implementation Plan

> Execute this plan in the existing `feat/web-chat-foundation` worktree. Keep Git local; do not configure or contact a remote.

**Goal:** Make Rust/WASM the single owner of chat state and message mutation, then persist that state in browser IndexedDB so messages survive reloads.

**Architecture:** Rust exposes a versioned JSON boundary through a `WebChatCore` WASM class. The browser loader provides only the IndexedDB I/O adapter and rollback-on-write-failure behavior. Flutter keeps a read-only UI projection loaded from the bridge and sends commands to Rust; it contains no production sample data or local message-ID logic.

**Tech Stack:** Rust 2024, serde/serde_json, wasm-bindgen, native IndexedDB, Flutter Web, Dart JS interop.

---

## Task 1: Versioned Rust state

- Add failing Rust tests for persisted-state round trips, malformed state, schema mismatch, and snapshots.
- Add serde DTOs and validation without weakening identifier invariants.
- Expose `ChatStore::from_persisted_json`, `to_persisted_json`, and `snapshot_json`.
- Run Rust tests and clippy.

## Task 2: WASM command boundary

- Add failing boundary tests for the exported API where native testing is possible.
- Export `WebChatCore` with constructor, snapshot, state export, and `send_text`.
- Convert Rust errors into useful JavaScript errors.
- Rebuild the generated WebAssembly bindings.

## Task 3: IndexedDB browser adapter

- Update `web/cht_core_loader.js` to open database `cht`, object store `state`, key `chat-store`.
- Seed IndexedDB from Rust only when no state exists.
- Persist after every accepted send and restore the previous Rust state if the write fails.
- Expose promise-based `snapshot` and `sendText` methods to Dart.

## Task 4: Flutter bridge and controller

- Add failing Dart tests for async initialization, command delegation, whitespace rejection, bridge failures, and server-provided ordering.
- Parse typed snapshots in Dart while removing production sample fixtures and local mutation logic.
- Expand `CoreBridge` with `loadSnapshot` and `sendText`.
- Make `ChatController` initialize and send asynchronously through the bridge.

## Task 5: UI lifecycle

- Add failing widget tests for loading, loaded chat, send completion, and initialization failure.
- Wire app startup to the bridge-backed controller.
- Adapt the composer to asynchronous sends and prevent duplicate submission while pending.
- Preserve responsive desktop and mobile behavior.

## Task 6: Verification and documentation

- Run Rust formatting, clippy, and tests.
- Run Flutter formatting, analyze, tests, and release web build.
- Browser-test a distinctive message, reload the page, and verify it remains visible from IndexedDB.
- Update the migration/checklist documentation and commit locally.
