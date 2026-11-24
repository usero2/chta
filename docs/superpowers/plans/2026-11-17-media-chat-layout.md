# Media Chat Layout Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with one final independent read-only review.

**Goal:** Match the requested borderless image/video and below-media caption layout.

**Architecture:** Shared bubble accepts visual-media presentation; media content owns its optional caption strip. Wire existing type metadata at each room, preserve text/audio/file styling and transfer controls.

**Tech Stack:** Flutter/Dart, existing media widgets/cache.

**Spec:** `docs/superpowers/specs/2026-11-17-media-chat-layout-design.md`.

## Global constraints

- Preserve private screenshots/reference source/roadmaps, original Git history and target junction. No owner content or local reference path in public source.
- No real-contact QA sends, credential inspection, Windows GUI or paid service activation; no GitHub publication.
- Keep media opening/saving, Markdown captions, transfer states, file limits and protocol unchanged.

## Review focus

- No green padding remains around an image/video; green appears only under media when there is a caption.
- Caption and filename colors remain readable without the old bubble background.
- Cached, legacy, album, group and local paths use consistent styling; audio/files remain framed.
- Narrow layouts and a lone video do not overflow or collapse to a tiny strip.

## Tasks

- [x] 1. RED/GREEN widget/room regressions passed for unframed media, caption below/absent, text/file preservation, single-video sizing and whitespace-only streamed captions.
- [x] 2. Shared presentation wired for peer/local/group rooms. Media actions, progress, metadata and streamed no-eager-read behavior preserved. Independent review cleared; final 397 Flutter tests passed with 8 opt-in/platform skips, analysis clean.
- [x] 3. Android/Windows/WASM 41 built and audited, Android installed and existing media inspected without owner-message sends. Web version 41 deployed/verified; source synced to the original workspace and kept in local commits. Private reference/captures remain excluded.
