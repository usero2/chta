# cht Web Chat Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first runnable `cht` Web Chat shell with Flutter Web, a tested Rust core that compiles to WebAssembly, and UI behavior adapted from the read-only `mine-chat-note` reference.

**Architecture:** Flutter Web owns presentation and local UI state. Rust owns typed core models, validation, and security-sensitive business rules, and exposes a minimal `wasm-bindgen` API. Phase 1 uses in-memory sample conversations only; networking, identity, recovery, storage, and real encryption remain out of scope.

**Tech Stack:** Flutter stable, Dart, Rust stable, Cargo workspace, `wasm-bindgen`, Flutter widget tests, Rust unit tests.

**Spec:** `roadmaps/0.0.1/0.0.1a-task.md`

## Global Constraints

- App and visible branding must use `cht`.
- Web is the first implementation target; Android, iOS, and Windows remain future adapters.
- `the reference chat project` is a read-only UX reference.
- Production UI must be Flutter/Dart; do not copy the source project's vanilla JavaScript into production.
- Do not copy Android Ktor, Room, PIN-session, cleartext LAN HTTP, secrets, signing files, or local configuration.
- No P2P connection, identity/recovery cryptography, E2EE, or persistent message storage in this phase.
- No logs may contain secret material or plaintext messages.

## Review Focus

- Narrow browser widths must keep the active conversation usable and provide a path back to the chat list.
- Empty or whitespace-only message input must not create a message.
- Selecting an unknown conversation ID must return an explicit error rather than stale data.
- Message ordering must remain deterministic when timestamps are equal.
- Rust/WASM exports must not expose internal mutable state or accept malformed identifiers silently.

---

### Task 1: Toolchains and Repository Scaffold

**Files:**
- Create: `.gitignore`
- Create: `Cargo.toml`
- Create: `rust/Cargo.toml`
- Create: `rust/crates/core/Cargo.toml`
- Create: `rust/crates/core/src/lib.rs`
- Create: `apps/flutter_app/**` via Flutter scaffold

**Interfaces:**
- Produces: Cargo workspace member `cht-core` and Flutter package `cht`.
- Consumes: none.

- [x] **Step 1: Install or locate Flutter stable and Rust stable**

Run: `flutter --version`, `rustc --version`, `cargo --version`  
Expected: all commands exit 0 and print versions.

- [x] **Step 2: Add the Rust WebAssembly target**

Run: `rustup target add wasm32-unknown-unknown`  
Expected: target is installed or already up to date.

- [x] **Step 3: Generate the Flutter Web and Cargo scaffolds**

Run: `flutter create --platforms web --project-name cht apps/flutter_app`  
Expected: Flutter creates a web-capable package.

- [x] **Step 4: Verify generated baselines**

Run: `flutter test apps/flutter_app` and `cargo test --workspace`  
Expected: both suites pass before custom behavior is added.

- [ ] **Step 5: Commit**

```bash
git add .gitignore Cargo.toml rust apps/flutter_app
git commit -m "build: scaffold cht web and rust workspace"
```

### Task 2: Rust Chat Domain

**Files:**
- Modify: `rust/crates/core/src/lib.rs`
- Create: `rust/crates/core/src/chat.rs`
- Create: `rust/crates/core/src/error.rs`
- Test: inline Rust unit tests in `rust/crates/core/src/chat.rs`

**Interfaces:**
- Produces: `ConversationId`, `MessageId`, `ChatMessage`, `ConversationSummary`, `ChatStore::conversation`, and `ChatStore::send_text`.
- Consumes: Cargo scaffold from Task 1.

- [x] **Step 1: Write failing tests for deterministic sample conversations and message validation**

Tests assert that the sample store returns literal `cht` conversations, rejects unknown IDs, trims valid text, rejects whitespace-only text, and orders equal timestamps by message ID.

- [x] **Step 2: Run tests to verify RED**

Run: `cargo test -p cht-core`  
Expected: compilation/test failure because the domain API does not exist.

- [x] **Step 3: Implement the minimal typed domain**

Use opaque ID newtypes, explicit `ChatError`, immutable query results, and an in-memory store only.

- [x] **Step 4: Run tests to verify GREEN**

Run: `cargo test -p cht-core`  
Expected: all `cht-core` tests pass.

- [x] **Step 5: Verify WebAssembly compilation**

Run: `cargo build -p cht-core --target wasm32-unknown-unknown`  
Expected: build exits 0.

- [ ] **Step 6: Commit**

```bash
git add rust/crates/core
git commit -m "feat: add typed chat core"
```

### Task 3: Rust WebAssembly Boundary

**Files:**
- Modify: `rust/crates/core/Cargo.toml`
- Create: `rust/crates/core/src/wasm.rs`
- Modify: `rust/crates/core/src/lib.rs`
- Create: `scripts/build-web-core.ps1`
- Create: `apps/flutter_app/web/cht_core_loader.js`

**Interfaces:**
- Produces: JavaScript global `chtCore.version()` after loader initialization.
- Consumes: Rust crate APIs from Task 2.

- [x] **Step 1: Write a failing Rust test for the version payload used at the boundary**

Assert the hand-derived literal version string and ensure it contains no environment details.

- [x] **Step 2: Run test to verify RED**

Run: `cargo test -p cht-core`  
Expected: failure because boundary version API does not exist.

- [x] **Step 3: Add the minimal `wasm-bindgen` export and loader**

Export a zero-argument `core_version() -> String`; do not export store internals.

- [x] **Step 4: Build the browser package**

Run: `powershell -ExecutionPolicy Bypass -File scripts/build-web-core.ps1`  
Expected: generated WASM bindings are written beneath `apps/flutter_app/web/wasm/`.

- [x] **Step 5: Run Rust suite and WebAssembly build**

Run: `cargo test --workspace` and `cargo build -p cht-core --target wasm32-unknown-unknown`  
Expected: both commands pass.

- [ ] **Step 6: Commit**

```bash
git add rust scripts apps/flutter_app/web
git commit -m "feat: expose rust core to flutter web"
```

### Task 4: Flutter Chat State

**Files:**
- Create: `apps/flutter_app/lib/chat/chat_models.dart`
- Create: `apps/flutter_app/lib/chat/chat_controller.dart`
- Test: `apps/flutter_app/test/chat/chat_controller_test.dart`

**Interfaces:**
- Produces: `ChatController`, `ConversationView`, `MessageView`, `selectConversation(String)`, and `sendText(String)`.
- Consumes: none; sample adapter mirrors the Rust fixtures until typed WASM data transport is added in a later phase.

- [x] **Step 1: Write failing controller tests**

Tests assert initial selection, explicit unknown-ID error, trimming, whitespace rejection, and stable message insertion.

- [x] **Step 2: Run test to verify RED**

Run: `flutter test apps/flutter_app/test/chat/chat_controller_test.dart`  
Expected: failure because controller classes do not exist.

- [x] **Step 3: Implement minimal models and controller**

Use immutable views and `ChangeNotifier`; do not add persistence or networking.

- [x] **Step 4: Run controller test and full Flutter suite**

Run: `flutter test apps/flutter_app/test/chat/chat_controller_test.dart` then `flutter test apps/flutter_app`  
Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add apps/flutter_app/lib/chat apps/flutter_app/test/chat
git commit -m "feat: add web chat state"
```

### Task 5: Responsive Flutter Web Chat Shell

**Files:**
- Modify: `apps/flutter_app/lib/main.dart`
- Create: `apps/flutter_app/lib/app.dart`
- Create: `apps/flutter_app/lib/chat/chat_shell.dart`
- Create: `apps/flutter_app/lib/chat/widgets/conversation_list.dart`
- Create: `apps/flutter_app/lib/chat/widgets/chat_room.dart`
- Create: `apps/flutter_app/lib/chat/widgets/message_composer.dart`
- Test: `apps/flutter_app/test/chat/chat_shell_test.dart`

**Interfaces:**
- Produces: runnable `ChtApp` and responsive `ChatShell`.
- Consumes: `ChatController` from Task 4.

- [x] **Step 1: Write failing widget tests**

Tests assert `cht` branding, conversation selection, sent-message rendering, whitespace rejection, and narrow-layout back navigation.

- [x] **Step 2: Run widget tests to verify RED**

Run: `flutter test apps/flutter_app/test/chat/chat_shell_test.dart`  
Expected: failure because chat widgets do not exist.

- [x] **Step 3: Implement the minimal responsive shell**

Adapt the source reference's two-pane desktop pattern and single-pane narrow pattern using Flutter Material widgets and `LayoutBuilder`.

- [x] **Step 4: Run widget tests and analyze**

Run: `flutter test apps/flutter_app` then `flutter analyze apps/flutter_app`  
Expected: tests pass and analyzer reports no issues.

- [x] **Step 5: Build the web application**

Run: `flutter build web --release --output build/web` from `apps/flutter_app`  
Expected: release build exits 0.

- [ ] **Step 6: Commit**

```bash
git add apps/flutter_app
git commit -m "feat: build responsive cht web chat shell"
```

### Task 6: Documentation and Phase Verification

**Files:**
- Create: `README.md`
- Create: `docs/migrations/mine-chat-note-webchat.md`
- Modify: `roadmaps/0.0.1/0.0.1a-task.md`

**Interfaces:**
- Produces: setup instructions, migration record, and checked Phase 1 items backed by evidence.
- Consumes: verified outputs from Tasks 1–5.

- [x] **Step 1: Document setup, scope, and source-reference decisions**

Record source paths and the inspected baseline commit without copying secrets or describing uncommitted source changes as stable.

- [x] **Step 2: Run full verification**

Run: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`, `cargo build -p cht-core --target wasm32-unknown-unknown`, `flutter analyze apps/flutter_app`, `flutter test apps/flutter_app`, and `flutter build web --release`.

Expected: every command exits 0.

- [x] **Step 3: Update only checklist items proven by the verification output**

- [x] **Step 4: Commit**

```bash
git add README.md docs roadmaps
git commit -m "docs: record web chat foundation"
```
