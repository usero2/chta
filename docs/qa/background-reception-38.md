# Background reception: build 0.0.1+38

Android keeps the unlocked messaging engine running in a foreground service when **Keep receiving in background** is on in Profile. Home/Back does not lock that session. The notification opens the app or locks it. Lock app and Switch identity stop reception. If Android hides the notification, Profile reports that and offers the existing notification permission controls. Enabling reception can request permission; startup does not prompt.

Windows Close hides the window in the tray. Open restores it; Exit saves pending work before closing. Launching the executable again restores the existing process. A missing tray icon falls back to normal exit. A slow or failed save restores the window rather than discarding work; retrying Exit takes a fresh save snapshot.

The Web app runs while its browser tab stays open. Closing a tab, force-stopping Android, shutting down a device, or an OS terminating the process stops reception. This release adds no push mailbox or offline server storage.

TURN was deferred at the user's request. Existing WebRTC direct connections and application data relays remain available. Files larger than 25 MB still wait for Direct; the message shows that explicitly. Seed registration does not mean the friend is connected, and a sent frame is shown as waiting for a receipt until the receiver durably acknowledges it.

## Verification matrix

| Case | Evidence |
| --- | --- |
| Windows native Rust → physical Android via public WSS relay | Synthetic text received and durably acknowledged while Android was on Home |
| File received while Android was on Home | 64 KB fixture, progress reported, cached bytes matched SHA-256 |
| Android Home and return | Same isolate marker and active account; another message acknowledged after return |
| Android explicit Lock | Receiver shut down after saving; foreground service stopped |
| Multiple peers, interrupted negotiation, retry and lost receipt | Automated messaging/outbox regressions |
| Windows tray lifecycle and duplicate process policy | Headless native tests and release runner compilation |
| Exit save failure, timeout, overlapping retries and identity changes | Gated runtime regressions; each retry takes a new snapshot |
| Web | WASM release compilation and shared Flutter regressions |

The physical proof uses USB only for test control; message and file payloads travel through public relay WSS connections. It does not establish independent cellular/CGNAT coverage. Activity destruction, deep Doze, and interactive tray clicks were not exercised; tests did not automate the owner's Windows GUI. TURN-only paths were not tested because TURN is out of scope. All network fixtures used disposable identities, with no messages sent to real contacts.
