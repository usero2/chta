# `mine-chat-note` Web Chat Migration Record

## Purpose

Use the existing Web Chat experience in `the reference chat project` as a read-only UX reference while creating a new Flutter Web and Rust/WASM architecture for `cht`.

The inspected source baseline was commit `2f2a935` (`2026-08-20`). The source working tree contained uncommitted changes during inspection, so this record does not treat those changes as a stable release and no source repository files were modified.

## Inspected source surfaces

- `app/src/main/assets/webchat/index.html` — two-pane shell and mobile one-pane flow.
- `app/src/main/assets/webchat/app.css` — dark palette, green outgoing bubbles, layout, and responsive breakpoint.
- `app/src/main/assets/webchat/app.js` — client interactions and REST/WebSocket behavior.
- `app/src/main/java/com/mechatnote/app/webserver/ChatWebServer.kt` — Android Ktor routes and WebSocket refresh behavior.
- `app/src/main/java/com/mechatnote/app/webserver/WebDtos.kt` — source DTO shapes.
- `web-git/` — static landing page only; it is not the source Web Chat application.

## Feature mapping

| Source behavior | `cht` Phase 1 decision | Result |
| --- | --- | --- |
| Desktop chat list + active room | Rewrite in Flutter | Implemented |
| Mobile one-pane list/room navigation | Rewrite in Flutter | Implemented |
| Dark surface palette and green outgoing bubble | Adapt visual concept | Implemented |
| Chat selection | Rewrite against typed controller | Implemented |
| Text composer | Rewrite with whitespace rejection | Implemented |
| Local message preview update | Rewrite as a Rust/WASM command | Implemented |
| Browser message persistence | New IndexedDB platform adapter | Implemented |
| REST chat/message API | Reject as core architecture | Not copied |
| WebSocket refresh | Replace with direct WebRTC events | Implemented as manual-signaling prototype |
| PIN and cookie session | Replace with BIP-39 person identity | Implemented as Web prototype |
| Chunked attachment upload | Defer | Not implemented |
| Edit/delete/checklist/move/merge/split actions | Defer | Not implemented |
| Image/video/file viewers | Defer | Not implemented |
| Android Room and filesystem storage | Reject for Web | Not copied |
| Android embedded Ktor server | Reject for Web | Not copied |
| AI, camera, Timeline, Moments, OmniTrack | Outside current scope | Not copied |

## Architecture boundary

- Flutter/Dart owns presentation, responsive layout, room selection, and a read-only projection of the latest Rust snapshot.
- Rust owns chat state, message IDs, validation, ordering rules, versioned serialization, and the browser-facing WASM command export.
- `wasm-bindgen` generates browser bindings beneath `apps/flutter_app/web/wasm/`.
- The JavaScript loader is a platform I/O adapter: it reads and writes one versioned Rust state document in IndexedDB and rolls Rust state back when a write fails.
- Dart calls the loader through a typed `CoreBridge`, initializes asynchronously, and never creates production sample messages or message IDs.

## Assets and licensing

No fonts, icons, signing files, keystores, local configuration, API keys, or source branding were copied from `mine-chat-note`. The current Flutter scaffold icons remain placeholders and require a separate `cht` branding decision before release.

## Deferred work

- Design browser key protection and encrypted-at-rest data; current IndexedDB data is plaintext and origin-scoped.
- Define migration behavior when the persisted state schema advances beyond version 1.
- Complete independent review of the implemented identity/recovery prototype before production use.
- Add TURN and persisted reconnect/session state after the current manual WebRTC prototype is reviewed.
- Add attachments and advanced message actions only after the text-message path is secure and persistent.
