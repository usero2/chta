# Relay resilience implementation plan

**Goal** Improve reconnection, file transfer fairness, portable relay diagnostics, and optional TURN fallback.

**Architecture** Keep discovery, live data relays, and Courier separate. Reuse the existing message receipts, attachment protocol, and signed WebRTC signaling. Run the TURN credential issuer alongside coturn on infrastructure chosen by the operator.

- [x] Recover transient relay loss with an explicit reconnecting state and drain pending messages after peer authentication. Verify stable delivery IDs and a real offline transition when the recovery window expires.
- [x] Bound outstanding attachment traffic per transfer and let chat and unrelated transfers proceed independently. Verify a stalled transfer using the existing receipt format.
- [x] Give the portable relay an HTTP health endpoint and a WebSocket probe. Verify the endpoint and `/cht` registration together in a disposable relay process.
- [x] Test link validation, short-lived credentials, and signed relay ICE candidates. Use the saved TURN connection in WebRTC and verify the selected route when moving large file blocks.
- [x] Publish the [TURN setup guide](https://chta.app/wiki/turn.html) and verify that the Web app and Privacy page still load.

A real cross-network TURN allocation still needs a reachable coturn host and two clients. The production seed returned HTTP 429 to the test connection. Signed TURN signaling passed in disposable workerd.
