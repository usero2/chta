# Cross-network message delivery

Build 35 fixes four gaps found while investigating Desktop ↔ Android reports of messages not arriving while the connection indicator changed between online and offline.

1. An authenticated relay session ignored a matching `unreachable` response until its 65-second liveness timeout. Outgoing retries could exhaust before the stale route was replaced. The current route, session and recipient must all match before reconnecting; an unrelated failure does not retire the session.
2. Rust decrypts and remembers a message ID before Flutter saves its history. Discarding every crypto duplicate prevented a retransmitted message from completing a previously interrupted receive or returning a lost receipt. The durable history layer now handles repeated message IDs, preserving one bubble and the original receive time.
3. A relay receipt was discarded when the same message had initially been sent on Direct, because there was no relay-local pending record. Authenticated receipts now reach conversation history across that route change.
4. Flutter could acknowledge received text while its history write was still queued. A receive acknowledgement now waits for the write and is withheld on persistence failure; a repeated message retries that write.

## What is verified

- Unit and widget regressions reproduce each affected boundary before its fix.
- An opt-in native integration test creates two disposable Rust identities and uses the production Dart WebSocket, relay, seed and crypto gateways through a temporary public relay. It exchanges messages both ways, omits one receipt, then disconnects and reconnects the recipient.
- No real peer messages or friend requests are sent by these tests.

The integration test crosses the public WSS endpoint but does not prove every Android carrier/NAT combination. Testing the reported pair of real devices still requires both devices to run the fixed build. `Seed · connected` means discovery is available; usable chat requires authenticated Direct or a reachable community data relay. WebRTC without TURN cannot connect through every network.
