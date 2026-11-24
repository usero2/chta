# P2P usability: build 0.0.1+43

This update covers the six approved improvements to account-owned messaging.

- Four file jobs and four text jobs have independent capacity. A busy file lane cannot occupy every text slot.
- Known permanent file validation failures stop automatic retry and retain a reason. Network interruptions keep their durable delivery intent.
- Supported network-change and resume events schedule debounced recovery. Repeated equivalent events stay quiet; locked or replaced accounts cannot restart transports.
- Relay events drain promptly through one adaptive account scheduler. Idle checks run every five seconds, active work every second, without idle UI notifications.
- Protected cache reservations default to 20 GiB, adjustable from 1 to 1024 GiB in Profile. Known free-space estimates retain a 256 MiB margin. Pending 1:1 files have Pause, Resume and Cancel controls; verified chunks survive interruption.
- Changed conversations use bounded immutable encrypted pages and an atomic index. Unchanged rooms are not reserialized. Legacy history remains as a recovery source.

Existing encryption, message IDs, timestamps, duplicate detection, durable-before-ACK behavior, the 25 MiB relay limit and the existing Direct large-file limit remain in place. No new server, mailbox, paid TURN service or telemetry was added.

## Review and tests

A fresh read-only review of the complete branch identified a cross-room durability defect and six important edge cases. One regression-driven fix pass addressed them:

- Failed room writes/deletions remain dirty until committed, including when another room or contact metadata saves successfully.
- File guards remain attached to queued relay packets and their retries. Transfer-scoped cancellation also removes matching relay pending packets without clearing text or another file.
- Authenticated V2 completion packets can update existing outgoing history after its active job has ended. They cannot recreate deleted messages.
- A transient cache-settings read failure can be retried in the same account session, including through a Profile Retry action.
- An unreadable previous index prevents cleanup of its unknown pages, while a validated current index can still accept new commits. Corruption of committed current data still fails visibly.
- Legacy local validation failures become terminal file failures with explicit retry available.
- Aborted unpublished streamed imports delete only their fresh staging object before releasing capacity. Definitively missing legacy writes release their reservation. Failed group imports keep accounting for cached pieces without reserving the missing remainder.

Verification:

- Flutter: **461 passed, 8 intentional platform/opt-in skips**; static analysis: no issues.
- Rust workspace: **97 passed, 1 ignored**.
- Web portal/seed worker: **33 passed**.
- An additional opt-in integration test used the actual Rust core and public WSS relays with disposable accounts: concurrent messaging, protected outbox restart/migration, lost receipt handling, cached-file hash verification and relay failover passed.
- Wire and service regressions cover a lost-ACK retry after pause, completion after cancellation, cancellation while encryption awaits, subsequent text delivery, and a receiver pausing during a durable chunk write.

## Decisions and remaining limits

- Cache usage is a logical payload/reservation budget, including group binding context. Encryption and filesystem overhead are not an exact physical quota; free-space estimates are advisory and failed writes withhold successful receipts.
- Cancelling a packet already being encrypted can require the existing authenticated session recovery, as with a lost ciphertext packet. The next-text regression passes, but zero rekey latency is not promised.
- A single chunk-read interruption remains retryable. Native/browser status validation rejects persistent saved-chunk corruption on the following attempt.
- Real independent-carrier handovers, extended Android Doze/background operation and a 24–72 hour reconnect soak are not established by these tests. Networks that prevent Direct connections still require a reachable data relay; the seed is discovery/signaling only.
- Windows launch/UI and unrelated Linux work are outside this verification. Platform build/install and artifact privacy results are recorded separately. Existing workspaces and shared artifact directories are preserved.

Deferred minor: write-progress accounting can remain conservatively stale if another settings save overlaps it. The whole-file reservation stays protected, but free-space admission may be more restrictive after reload. Revision-aware progress merging is follow-up work.

No owner conversation was used for test sends, and no owner preference was changed. No private captures, identifiers, credentials or local paths belong in this report. GitHub publication is separate from local build delivery.

## Build delivery

Windows release, the single-file Windows launcher, Android arm64 release and Web/Wasm builds completed successfully as build 43. The installed Android package reports version code 43; the deployed Web version endpoint reports build 43. The previous owner Desktop process was preserved, so using the new EXE requires exiting that older instance from its tray first.

Source inspection covered 525 tracked files and commit author metadata. Artifact inspection covered 466 runtime/Web/decompressed APK/embedded launcher entries, checking local paths, known private identifiers and credential patterns; no findings were reported. Only the owned source files were synchronized after conflict checks. No GitHub push or public release was performed.

After the owner manually opened Profile, the physical Android screen showed the Cache usage, 20 GB limit field, enabled Apply control and version 0.0.1 (43), without a settings error or layout overflow. The existing notification, background and lock preferences were left unchanged. Screenshots, accessibility snapshots and the device proof bundle remain private. Widget tests separately cover Cache validation/Retry and file controls; no live transfer was sent to an owner contact.
