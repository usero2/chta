# Notification Toggle Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one final independent read-only review.

**Goal:** Make Notifications a functional, remembered Profile switch.

**Architecture:** Separate app alert preference from OS permission in IncomingNotifications; persist through existing protected identity-scoped blobs and render an adaptive switch.

**Tech Stack:** Flutter/Dart and existing native/browser notification backends.

**Spec:** `docs/superpowers/specs/2026-11-17-notification-toggle-design.md`.

## Global constraints

- No private source history, roadmap, owner data, screenshots or credentials in public source/artifacts; preserve existing worktree/target junction.
- No owner notification-setting changes, real-contact QA messages, Windows GUI, server/billing changes or GitHub publication.
- Permission prompts only from user gestures. Off must survive delayed results, restart and identity changes.

## Review focus

- OS permission and app alert preference stay separate; background reception does not re-enable opted-out chat alerts.
- Serialize protected preference writes and guard disposed/changed owners.
- Switch state reflects permission denial/save failure; no replay of suppressed events.

## Tasks

- [x] 1. RED/GREEN preference, persistence/race and notification suppression tests; wire protected storage and pending-write flush.
- [x] 2. RED/GREEN adaptive switch UI, permission-denied/error handling; review and full verification.
- [x] 3. Build/audit/install 42, inspect Profile without changing owner preferences, update Web and retain local source commits.
