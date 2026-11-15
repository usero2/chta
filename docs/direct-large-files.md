# Direct files and notifications — 0.0.1+25

Both peers should update to build 25. Existing verified friends exchange the signed `files-v2` capability on their next authenticated connection; no account reset or new recovery phrase is needed.

Files above 25 MiB use a direct WebRTC DataChannel, up to 10 GiB per file. The existing encrypted chat path exchanges the connection information. If NAT/firewall rules prevent a direct path, files above 25 MiB wait for Direct; they are never sent through the relay. Files up to 25 MiB can fall back to the relay. Direct connections can continue after signaling is lost, until the data connection itself closes.

The attachment card shows confirmed bytes, percentage, speed and Direct/Relay. Received blocks are encrypted on disk before being acknowledged. Reopening the chat resumes from durable blocks. Completion requires the exact SHA-256 and saved chat history. Browser storage quotas and available disk space still apply. Large media uses a file card when the player cannot stream it; ordinary media up to 25 MiB retains its preview flow. Saving large files on Web requires a browser with File System Access support.

To enable incoming message/file notifications, open **Profile → Notifications → Enable** and allow the system/browser permission. Notifications contain the friend's name and a generic message label or received filename. Opening saved history does not replay notifications. Files notify after verification and successful history persistence. Notifications require cht to be running and connected; this release does not add push delivery to a terminated app.

## Verification

- Disposable actual WebRTC loopback on Chrome, Windows and the connected Android device: 135,266,427 bytes (129 MiB + 123), interruption after 32 MiB, durable resume from block 128, completion with signaling disabled.
- All three produced SHA-256 `8957098fa7809e46093cb8ebb478c52174a736bf2a1660a708cdd466632ff33b`.
- This validates streaming and resume on each platform. It does not establish Internet reachability through every NAT or a measured 10 GiB transfer.
- Regression tests cover owner isolation, ciphertext tampering, quota/write failures, final hash, peer switches during negotiation/decryption, legacy file compatibility and notification deduplication.

The disposable harness is `apps/flutter_app/test_harness/direct_large_file_qa.dart`. Android QA must use `-PchtQa=true` and the separate package `app.cht.cht.qa`. Do not run it inside a real identity's application data directory.
