# Background reception, WebRTC fallback and connection feedback

The user approved recommendations 4–7 after completing reliable messaging 1–3.

**Scope amendment, 2026-11-17:** The user explicitly deferred TURN because of possible additional charges. Implement recommendations 4, 6 and 7 only. The TURN design below is deferred context, not an implementation or activation requirement. Existing direct-only ICE and 25 MB application-relay policy remain unchanged. No new TURN service, credentials or billing activation.

## Chosen approach

Build on the existing native platform hooks and account-scoped MessagingService. Android gets a foreground remote-messaging service and retained Flutter engine while an unlocked identity receives messages. Windows gets a native system tray in the existing runner. This avoids a Flutter SDK upgrade and preserves the single-EXE package. A separate push/mailbox backend is outside scope: the seed remains discovery-only, and no server stores offline user content.

For TURN, use short-lived credentials issued by a server-side broker, preferably Cloudflare Realtime TURN in the existing account. Activation awaits the user's explicit answer about this potentially billable new service; client/broker integration and the other work may proceed independently. No permanent TURN/API secret enters an app bundle, QR, log or repository.

## User behavior

- Android starts foreground reception after unlocking, with an ongoing notification. Back/Home preserves reception and the existing PIN preference. Locking/switching identity stops its receiver. A notification action explicitly locks and stops reception. There is no unattended identity unlock on boot or forced-stop recovery. Android can still stop a process; never promise reception after force-stop or device shutdown.
- Closing Windows hides the window to tray while retaining connections. Tray offers Open and Exit. Exit flushes protected queues/history before shutdown. Failure to create the tray must preserve a usable normal window/exit path.
- WebRTC may use TURN when a direct route cannot form. Validate/sign relay ICE candidates in Dart, Rust native/WASM and the seed, retaining DTLS fingerprint, role, destination, schema, size, replay and owner checks. Show the selected route accurately as Direct, TURN, Relay or Connecting. A ready DataChannel alone does not establish that its route is direct.
- Preserve the 25 MB application-relay file limit. Use selected WebRTC candidate-pair evidence to distinguish direct from TURN paths; document and enforce the resulting large-file policy rather than silently labeling TURN as direct.
- Distinguish discovery availability, authenticated peer connectivity, queued/sending/waiting-for-receipt/delivered and permanent local failures. A seed connection never means a friend is online; a sent frame never means delivered. Keep normal labels short and place troubleshooting details in Connect.
- Retain all existing identity/PIN/QR/alias/history/group behavior. Web should explain that closing its tab stops local reception; Android-only service controls must not imply OS support on Web.

## Verification

Add regressions for lifecycle lock/identity switch, queue flush on exit, failed native start/tray recovery, TURN credential expiry/failure/secret handling, signed relay ICE, selected candidate classification, accurate delivery states, and network loss/recovery during text and file transfer. Test real Windows native behavior without controlling the user's desktop windows unless reauthorized. Use synthetic identities for network tests, including TURN-only and relay-only cases, cross-platform interoperability and recipient background reception. Record what physical network combinations actually ran; do not infer cellular/CGNAT coverage from local tests or seed connectivity.

Build and install the next Windows/Android/Web version, inspect source and payloads for personal/local data, and keep the owner's private roadmap/history out of the public source repository. Do not publish a new GitHub release unless requested.
