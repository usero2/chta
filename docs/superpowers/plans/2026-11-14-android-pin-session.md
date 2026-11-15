# Android PIN Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Android Lock PIN preference and safe session/page restoration.
**Architecture:** Native device-encrypted resume grant; separate optional AndroidSessionBridge; controller routes and Profile toggle. Preserve existing PIN vault and identity isolation.
**Tech Stack:** Existing Rust vault protection, Flutter, Android FlutterActivity/Keystore. No new crypto dependency.
**Spec:** docs/superpowers/specs/2026-11-14-android-pin-session.md

## Global Constraints

- Android only; existing accounts default On, no plaintext PIN/seed/private key.
- Only last selected saved identity resumes; manual lock/switch revokes automatic access.
- Fail closed on corrupt state; preserve identity/history and allow PIN recovery.
- No real PIN/phrase input or real-contact messages in automated tests.
- On locks after root Back/close and cold reopen; Home/app switching/pickers retain the session, per user clarification.

## Review Focus

- Corrupt or mismatched resume grant must not unlock another identity.
- Manual lock or switching must not leave stale remembered access.
- Delayed route writes must not recreate revoked grants.
- Process/engine recreation must not lose last page with Off or bypass On.
- Back/pickers/background transitions must preserve intended auth and staged state.

### Task 1: Native encrypted resume state

**Files:** rust/crates/core/src/desktop_vault.rs, native.rs private unit tests.
**Interfaces:** Android/test native commands resumeIdentity, sessionPreferences, setPinLock(required bool), saveSessionRoute(ownerId,path). Preferences return pinRequired and lastRoute for active identity only. No secret crosses Flutter boundary.
- [x] Write and run failing tests for default On; Off across runtime/engine recreation with encrypted bytes; identity binding; manual lock/switch revocation; corrupt state fallback and PIN recovery; route validation and stale-owner denial.
- [x] Implement atomic bounded device-encrypted state via existing protect; zeroize decrypted buffers and secret fields. Keep original PIN record unchanged.
- [x] Run cargo test -p cht-core (51 passed); commit with the reviewed integration.

### Task 2: Flutter preference/controller/UI

**Files:** new account/android_session_bridge.dart; core/core_bridge_native.dart; account/account_controller.dart, account_gate.dart; profile/profile_page.dart; focused tests.
**Interfaces:** optional AndroidSessionBridge supportsRememberedSession, resumeIdentity(), sessionPreferences(), setPinLock(bool), saveSessionRoute(owner,path). Separate from DesktopIdentityBridge to preserve fake and other-platform compatibility.
- [x] Failing tests for initialize Off, On fallback, corrupt recovery, toggle save failures, owner-switch route ordering, Profile On/Off and Lock app.
- [x] Implement controller serialization, last-route restoration, concise Profile controls, normal PIN switch/recovery paths.
- [x] Full Flutter suite (167 passed, two optional skips), analyzer clean; local integration commit ac87993.

### Task 3: Android back/lifecycle and delivery

**Files:** MainActivity.kt and root/home navigation handling; regression tests, docs.
- [x] Resolve user's lifecycle On choice, record it in spec.
- [x] Implement warm task retention and chosen PIN boundary without breaking media pickers; 10 focused home tests passed, including history flush, repeated Back and pushed routes.
- [x] Review security-sensitive native/controller changes with a fresh read-only reviewer; no critical/important findings. Corrected write-failure test to block atomic temporary-file creation; regression passed.
- [ ] Integrate locally, fresh Android Rust build + pub get + native-registration check + versioned APK install-r. User unlocks/toggles actual preference locally; verify Back/re-entry without reading PIN. Preserve data.
