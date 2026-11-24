# Courier verification for build 44

Two disposable Windows Courier processes accepted three encrypted pieces for a 262,145-byte file over a public WebSocket relay. The Windows sender closed its connection before the physical Android QA app began pickup. Android saved the file, verified the SHA-256 digest, and returned a recipient receipt. The restarted Windows sender verified that receipt. ADB carried test control only. These results cover a short transfer with synthetic identities on the public relay, without testing long-running availability.

The native Rust and standalone relay fixture also exercises group text and files, recipient-owned Courier pickup, and cancellation of deposits before pickup. The separate group fixture reconnects two controllers with signed membership but incomplete history and recovers the missing events. A dropped first handshake test verifies that a group can retry when one relay is available.

Chromium opened the deployed build in a fresh context and verified that Flutter started and the Rust/Wasm core could certify a Courier node and sign a delivery event. The public seed test covered registration, lookup, session-bound signaling and the legacy handshake. The seed carries discovery and signaling only. It does not store chat or file content.

Courier deposits require two certificates under different routing identities because a relay can forward the same frame to multiple devices in one identity. The sender retains that constraint across retries. An independent public relay can be configured with a verified pin and provider label. The built-in public data relays still share one provider.

Release artifacts were scanned for local paths, device and identity identifiers, and common credential patterns. The scan included APK entries and files embedded in the Windows single executable. The temporary QA package and its test credentials are separate from the distributed app.
