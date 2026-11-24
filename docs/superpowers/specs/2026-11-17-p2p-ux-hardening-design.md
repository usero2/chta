# P2P chat usability improvements 1–6

The user approved recommendations 1–6 from the code audit: message/file fairness, permanent failure handling, network recovery, idle efficiency, cache/transfer controls, and room-scoped history. Implement these together on the shared Flutter clients and current native/browser storage. Preserve existing encryption and delivery guarantees.

## Delivery and fairness

- A maximum of four file sends and four text sends may run concurrently; each peer retains separate text/file lanes. Busy file jobs cannot occupy text capacity. Receipts/control traffic must remain serviceable.
- Transient network interruptions keep durable delivery intent. Permanent file rejection/cache damage ends automatic retry and persists a concise user-facing reason. Explicit retry remains possible. Keep message IDs, timestamps and duplicate detection unchanged.
- Paused/cancelled jobs do not restart automatically; restarting the app preserves the user's decision. Cancellation never marks delivery. Late durable receipts are handled without creating duplicate messages.

## Network recovery and idle work

- Account-scoped network observations and app resume trigger debounced recovery. Android uses the existing native runtime's network callbacks; Web uses supported browser connectivity/resume events; other native systems may use a bounded interface-change fallback.
- A connectivity event is a hint, not proof of Internet access or recipient delivery. Clear obsolete backoff and renegotiate failed socket/Direct paths while preserving outbox/history. Avoid repeated recovery for equivalent events and guard switched/disposed identities.
- Prefer event-driven relay event draining and one account retry scheduler. Idle checks may run every five seconds; active queued work checks every second. Do not notify/rebuild UI when nothing changed. Keep periodic authenticated liveness and retry safety checks.
- Do not add paid TURN, new servers, offline mailboxes, telemetry, or network probes to unrelated services.

## Files and storage

- Keep automatic encrypted file caching. Add a protected, per-identity cache budget, default 20 GiB, adjustable 1–1024 GiB. Do not evict user files automatically. Show usage and a concise actionable failure when the budget or available storage prevents receiving/importing a file.
- Reserve concurrent transfers against the shared budget before accepting them. Check known free space with a 256 MiB reserve. Browser storage estimates are advisory and can be unavailable; handle quota/write failures without sending a successful receipt. Account for existing referenced cache data conservatively on migration.
- Add Pause/Resume/Cancel for pending 1:1 files in the conversation. Stop in-flight work using transfer-scoped guards, persist pause/cancel state, and retain already verified chunks for resume. File controls must not disconnect text chat or other peers. Existing group imports use the shared cache policy where they pass through the attachment store; protect active/pending cache data from cleanup.
- Preserve relay maximum 25 MiB and the existing Direct large-file limit. Do not change transport/file wire limits as part of this work.

## History

- Save changed rooms separately using protected blobs, with a small atomic manifest and immutable room pages. A message/receipt in one room must not reserialize/rewrite all other rooms.
- Load/migrate legacy history without deleting its recoverable source. Commit new room pages before publishing their manifest. A failed save leaves the prior readable manifest intact; do not fall back silently when a committed manifest is corrupt.
- Keep stable flush, owner/generation/delete/tombstone guards and the rule that incoming data is persisted before ACK. Keep existing metadata, drafts, view position, media references and sync behavior.
- Keep old-format backup for recovery. No destructive cleanup of owner history or attachment caches during installation.

## Verification and delivery

Reproduce the two audit defects with failing regressions, then prove fairness, permanent/transient classification, pause/cancel/resume, network handover/resume/lock races, idle scheduling, cache reservation/storage failure, and room migration/transaction failure. Run full relevant suites and a fresh final read-only review. Build sanitized Android, Windows single EXE and Web version 43, update existing local apps/Web, and retain source locally. Do not publish GitHub changes/releases, send messages to real contacts, change owner settings, inspect PIN/keys, or perform Windows GUI actions. Preserve the existing worktree/target junction and unrelated Linux files.
