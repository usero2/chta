# Attachment progress: build 0.0.1+40

Android inspection confirmed a delivered image with its receipt time and a stale 100% transfer bar. The image and chat captures remain private and are not source assets.

## Resulting behavior

- Completed image, video, audio and file messages collapse their transfer status entirely, including its padding. Existing receipt timestamps and media controls remain.
- Legacy transfer state is cleared after success/failure, and streamed completion is removed from the active progress map. A late receipt-send error cannot reinsert progress for an already delivered file.
- All bytes sent without the final receipt shows **Waiting for receipt** for both legacy and streamed transfers. Byte count alone does not mark delivery.
- Active transfers keep their progress; streamed failures show a compact error instead of a full 100% bar. A partially delivered album follows its active member instead of showing the completed first item's stale progress. The generic queue label does not duplicate an active transfer label.

## Verification

- Failing regressions reproduced the legacy sender's retained `1.0` entry with and without an authenticated relay, retained streamed completion, and rendered completed/failed progress.
- Additional RED/GREEN regressions cover streamed 100% before the final receipt and completion-packet failure after receiver persistence.
- Widget tests cover zero-height delivered/completed state, active percentage, waiting for receipt and compact failure. A ConnectionPage integration test covers a partially delivered album.
- A receiver storage-failure test verifies progress cleanup while the sender remains unacknowledged.
- Full Flutter suite: 391 passed, 8 platform/opt-in skips. Static analysis: no issues.
- A separate actual native/public-relay test passed, including cached file hash verification and empty sender/receiver progress maps after delivery; its existing restart, receipt-loss, relay failover and 100-message checks also passed.
- Android package version 40 was installed and the existing delivered media inspected again: the media and timestamps remain, with no trailing 100% indicator. This inspection did not send another message or file to the real contact.

The transfer protocol, encryption, cache contents, file limits and retry policy are unchanged. No messages were sent to real contacts during QA. This build does not claim that a restarted app alone proves terminal callbacks were correct; those are exercised by the regression and live transfer tests above.
