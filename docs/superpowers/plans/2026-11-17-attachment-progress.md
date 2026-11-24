# Attachment Progress Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline and one independent final read-only review.

**Goal:** Remove stale completed transfer UI and make active/waiting/failed states unambiguous.

**Architecture:** Clean terminal progress in the existing service/controllers; one shared message transfer widget checks durable message state before rendering either legacy or streamed progress.

**Tech Stack:** Flutter/Dart and existing encrypted native/WASM transfers.

**Spec:** `docs/superpowers/specs/2026-11-17-attachment-progress-design.md`.

## Global constraints

- Preserve private history/roadmaps/captures, existing isolated worktree and its target junction; no remote source/release publication.
- No real-contact QA sends, owner PIN/seed inspection or Windows GUI actions. Device inspection is explicitly authorized.
- Never mark delivered from 100% alone; keep file/crypto/retry policies unchanged.

## Review focus

- Late callbacks and failures must not resurrect a completed progress entry.
- Byte completion before durable receipt must remain distinguishable from delivery.
- Delivered media and albums must have no stale bars or empty status padding.

## Tasks

- [x] 1. RED/GREEN account transfer cleanup and chunked completion regressions passed. Clean ownership-guarded state and notify observers, including failure and late receipt-send callbacks.
- [x] 2. Shared message-progress presentation integrated into chat/album view. Delivered/completed state has zero status height, active progress stays visible, legacy and streamed 100% await a receipt, and failed streamed state is compact. Widget and actual ConnectionPage partial-album tests passed.
- [x] 3. Independent review cleared after streamed-receipt/late-failure fixes; 391 Flutter tests passed, 8 opt-in/platform skips, analysis clean. Separate native/public-relay proof passed with progress-map cleanup assertions. Android 40 installed and existing delivered media inspected without new real-contact sends; Windows single EXE and WASM 40 built/audited, Web updated and source retained locally.
