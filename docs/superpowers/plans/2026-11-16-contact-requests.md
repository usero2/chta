# Contact requests implementation plan

> Execute inline with superpowers:executing-plans. Root implements; use one fresh read-only branch review before delivery.

**Goal:** Add on one side; Review/Accept on the other; protected local retry without a seed mailbox.

**Spec:** `docs/superpowers/specs/2026-11-16-contact-requests-design.md`

**Architecture:** A Rust signed/sealed contact packet API, the existing seed socket, an owner-bound durable Dart controller, and shared Contacts/Review UI. Ordinary chat still requires a usable authenticated Direct or community-relay path.

## Global constraints

- No seed request payload persistence, new identity sockets, plaintext secrets, or pre-consent trusted contact creation.
- Keep direct v1 and groups v2 compatible. All supported platforms receive the feature.
- Preserve aliases, history, compact UI and existing mobile/desktop navigation.
- No real-user messages or friend requests in automated tests. Never inspect or enter PIN/recovery secrets.
- Source is published only from the clean repository; owner roadmaps and captures remain local.

## Review focus

- An unknown sender must never be trusted before a user accepts.
- Fresh signed retries with a stable request ID must not duplicate a prompt or lose an accepted decision.
- A crash between adding a contact and saving a decision must recover without duplicate/false success.
- Identity switching and failed persistence must not send an old owner's packet or display its state.
- Seed availability and accepted friendship must not falsely imply a working chat route.

### 1. Rust contact-setup packets and bridge gateway

- [x] RED native command test: seal to a QR-known recipient, inspect before reciprocal add, wrong recipient/tamper reject, contacts unchanged.
- [x] Implement `contact_requests.rs`: strict sealed card packet, canonical Ed25519 envelope, Noise IK initial packet and static/card binding.
- [x] Add `AccountCore::contact_request_call`, native gateway and WASM binding; advertise capability.
- [x] Add malformed/schema, expiry, cross-protocol, response-kind and locked-identity tests; run core checks.

### 2. Seed forwarding

- [x] RED protocol/DO tests for the new isolated topic, live delivery, offline retry and no stored request body.
- [x] Add exact bounded contacts-topic validation and live forwarding; retain existing replay/rate handling and backwards compatibility.
- [x] Run portal and cross-language packet tests.

### 3. Durable request controller

- [x] Add Dart optional crypto bridge and native/Web adapters, with guarded Web loader calls.
- [x] RED controller tests: local outgoing queue/restart, pre-consent pending inbox, Accept/Decline, duplicate/lost ACK, storage errors and owner switch.
- [x] Implement owner-bound encrypted-blob state, serialized transitions, bounded retry/backoff and decision replay.
- [x] Run relevant tests; keep pending statuses honest.

### 4. Shared socket and UI

- [x] RED SeedClient tests for unknown contact packets and owner/registration boundaries without another socket.
- [x] Wire contact packet stream/controller into the existing shared SeedClient and AccountGate lifecycle.
- [x] RED UI tests for Add -> pending and global Review -> Accept -> contact; decline and cross-room navigation.
- [x] Update Add/Review consent, Contacts request list and chat status/explicit request retry. Preserve prior aliases/rooms.

### 5. End-to-end verification

- [x] Actual Rust two-identity proof from one-sided add through request/restart/Review/Accept to mutual trust, with synthetic identities only.
- [x] WASM/loader and Worker runtime proofs; full Flutter/core/portal checks. Independent review was unavailable due to its service usage limit; a separate author review and regression pass were used.

### 6. Delivery

- [x] Backwards-compatible seed deployment after staging checks; no request payload persistence.
- [x] Build Windows single EXE, Android and Web/WASM, install locally preserving data; inspect UI without real peer sends.
- [x] Audit source, existing pushed history/metadata and decompressed release binaries; remap compiler paths. Recheck the final commit before pushing.
- [ ] Commit/push and versioned release only after verification; sync explicit changed source/artifacts to original workspace without its private history.
