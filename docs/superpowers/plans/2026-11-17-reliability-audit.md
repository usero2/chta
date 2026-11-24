# Reliability Audit Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one independent final read-only review.

**Goal:** Reproduce and fix delivery/storage failure modes, then report verified reliability and limits.

**Architecture:** Keep the existing account-scoped MessagingService and encrypted history. Add text-only route failover on immediate error or missing receipt; drain pending history writes to a stable boundary. Do not change attachment routing or wire schemas.

**Tech Stack:** Flutter/Dart, current native/WASM Rust, existing public WSS data relays.

**Spec:** `docs/superpowers/specs/2026-11-17-reliability-audit-design.md`.

## Global constraints

- Use existing isolated worktree, preserve its target junction and private original history. No owner data, roadmap, PIN or keys in remote source/artifacts.
- No new paid services, TURN, real-contact messages, Windows GUI actions or GitHub publication.
- Preserve message IDs/timestamps, durable ACK, duplicate detection, file-size limits and account ownership.

## Review focus

- Ready but blackholed Direct must not indefinitely prevent use of an authenticated relay.
- Failover must not duplicate bubbles or bypass the relay file limit.
- Flush must include concurrent writes without hiding storage errors or switching owner.

## Tasks

- [x] 1. RED/GREEN paired-service regressions cover silent Direct loss, immediate send failure, lost Direct receipt and 258 pending messages. Alternate authenticated text routes; keep the ephemeral route hint on each existing message without an evictable ID cache or schema change.
- [x] 2. Gated RED/GREEN history flush regression passed; drain writes added during flush to a stable queue boundary.
- [x] 3. Full suite: 380 passed, 8 skipped; analysis clean. Separate native public-relay proof passed with 100 bidirectional messages, encrypted outbox restart, lost-ACK deduplication, cached file/hash and primary-relay failover. Read-only review cleared after the 258-message fix. Assessment and unverified cases are in `docs/qa/reliability-audit-39.md`. Windows single EXE, Android and WASM 39 built/audited; Android/local artifacts installed and Web deployed. Keep commits local; no paid service or GitHub release.
