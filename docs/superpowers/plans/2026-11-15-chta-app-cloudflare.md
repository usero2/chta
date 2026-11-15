# chta.app Cloudflare Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax. Independently owned crypto, hosting, and client subsystems may use dispatching-parallel-agents only against the fixed wire/API contract; integration and review remain sequential under root.

**Goal:** Ship a chta homepage, mounted WASM chat and discovery-only public seed at chta.app.
**Architecture:** Cloudflare Worker Static Assets plus hibernating Durable Object. Rust signs/validates peer-bound SDP/ICE, Flutter reuses the Direct channel, data relays remain separate.
**Tech Stack:** Existing Rust/Flutter/Dart/WebRTC, Workers ES modules, Wrangler, Node built-in tests and actual local workerd.
**Spec:** docs/superpowers/specs/2026-11-15-chta-app-cloudflare.md (exact wire and API values are binding).

## Global Constraints
- Existing DID/appID/storage/crypto sessions and 10GiBDirect/25MiBrelay policies preserved; no remote Git or real-contact sends.
- Seed accepts discovery/SDP/ICE/signed relay hints only; no message/file/upload/offline storage APIs.
- Endpoint /relay is distinct from /cht data relay. /chat/ mount prefix never escapes to root on navigation/reload.
- Private keys stay Rust; complete endpoint/owner/peer/session/time validation; no seed trust substitute for peer signature.
- Root owns integration decisions, release/version/deploy, documentation and reviews. Per-domain implementers edit only their owned files, no commits or subagents unless root requests.

## Review Focus
- Malicious seed substitution/replayed valid offer must not authenticate another peer; crypto/client tests pin this.
- Async peer switch, close, and hibernation during signature verification must not dispatch stale work; all domains cover it.
- Browser refresh at /chat/chats/<DID> must preserve route and assets without homepage fallback; routing tests.
- Direct unavailable must not transmit user content over /relay, even queued retries; server and integration tests.
- Expired/forged relay catalogs and caller-controlled URLs must not become trusted routes or SSRF; crypto/server/client tests.

### Task 1: Rust signal cryptography and bridges
**Own:** new rust/crates/core/src/seed_signal.rs and tests, account.rs/lib.rs/native.rs/wasm.rs minimal API, new Dart seed_crypto_bridge.dart, core_bridge_native.dart/core_bridge_web.dart, web/cht_core_loader.js bridge exports, contacts.rs seed capability.
**Interfaces:** exact SeedSignal/signature tuple and SeedCryptoBridge in spec. Shared fixture path apps/web_portal/test/fixtures/seed-signal.json if needed (tell hosting owner before writing). No ConnectionPage/PeerFileController/route/server edits.
- [x] Write RED valid roundtrip, locked/unverified/wrong recipient/key/expired/tamper/extra field/payload tests; native/WASM boundary parity.
- [x] Implement Rust private-key-only signing and verified-contact inspection; adapters; deterministic cross-language fixtures.
- [x] Run cargo fmt/clippy/core tests plus focused bridge checks; report exact evidence and unresolved concerns for task review.

### Task 2: Cloudflare portal and discovery server
**Own:** apps/web_portal/** only, new scripts/build-web-portal.ps1 permitted; no Flutter/Rust existing source. No auth/deploy without root.
**Interfaces:** exact seed wire/registration/signature/catalog canonical contracts in spec; Wrangler ASSETS+SeedDirectory binding. Package build copies ../flutter_app/build/web under dist/chat and builds landing; validate /chat/ base. Root runs Flutter build with mount/seed defines. Use existing roadmap borderless logo; truthful concise Thai copy, responsive refined green/charcoal page with Open chat CTA and actual illustrative UI (synthetic names).
- [x] RED Worker routing/refresh/404/content rejection, registration+nonce/replay/ID/signature/type/rate/catalog tests; verify Cloudflare runtime where possible.
- [x] Implement bounded hibernating WebSocket seed, no generic encrypted carrier; landing/static build and custom-domain/dry-run config.
- [x] GREEN Node/runtime tests and local mobile/desktop visual QA, no placeholders/broken CTA; report deploy instructions and limits.

### Task 3: Flutter seed client, Direct integration and web mount
**Own:** lib/seed/** except seed_crypto_bridge.dart; p2p/connection_page.dart/peer_file_controller.dart minimal direct transport changes; routing/*; focused Flutter tests. No crypto adapters/JS loader/pubspec changes without root coordination.
**Interfaces:** SeedCryptoBridge and wire exact spec. Existing RelayConnector and RelayNetwork APIs; no /relay in /cht normalizers. Root sets version26. Reuse DirectFileLink authenticated signed SDP/ICE; distinguish verified seed control from authenticated Noise fallback.
- [x] RED fake network/crypto generation/replay/unverified peer/seed-only no-data tests; route mount/deep-link/root tests.
- [x] Implement auto registered seed and presence, signed signal verification, existing-contact direct-first connection, safe catalog ingest/publish, concise status; preserve old data relays and transfer resume.
- [x] GREEN focused tests/analyze; actual disposable loopback WebRTC if supported; report integration review risks.

### Task 4: Root review, deployment and release
- [x] Independent task/whole-branch security review and serious findings fixed with regression tests; all Rust/Flutter/Node checks and actual local Worker/Direct proof.
- [x] Build WASM mount plus portal dist, Wrangler deploy dry-run, local browser mobile/desktop QA; no credentials printed.
- [x] Authenticate user's Cloudflare, verify active zone chta.app, stage worker and smoke-test before bind production custom domain; document outcome honestly if login external blocker.
- [x] Fresh build26 Android/Windows/Web preserving data, install approved connected device, update canonical release and documentation/evidence. No remote Git.
