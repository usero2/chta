# Reliable messaging implementation plan

Spec: `docs/superpowers/specs/2026-11-16-reliable-messaging-design.md`. Execute inline; preserve existing private/public repository isolation.

1. Implement and test a bounded Cloudflare live data relay compatible with the existing signed relay protocol. Add three separate production services and public identity pins. Verify challenge/proof binding, opaque routing, unreachable, capacity/traffic limits, hibernation and absence of payload persistence.
2. Refactor RelayChat to share one RelayNetwork safely across peers. Add route leases and pinned automatic bootstrap defaults. Test simultaneous sessions and independent teardown/failover.
3. Add a protected durable outbox using explicit persisted queue intent in PeerHistory. Test restart, stable IDs, durable-before-send/receipt, storage failure, cancellation and historical-message migration.
4. Introduce an account-scoped messaging service owning per-peer RelayChat, Direct file controllers, signaling and attachment receive state. Extend SeedClient to route authorized signals to multiple peers over one seed connection. Test two contacts concurrently and identity isolation.
5. Attach the service above navigation. Convert ConnectionPage into a view of selected-peer state while preserving legacy local/manual connection paths for compatibility. Route text/media sending, retry, progress and receipts through the service. Allow offline queueing.
6. Deploy the three bounded data services without changing billing. Run synthetic public native/WASM delivery, lost-ACK/restart and route-failover probes. Confirm discovery endpoint still rejects content.
7. Run regression suites, review all changes, build sanitized Windows/Android/Web artifacts and inspect for local/private data. Update installed apps and deployed Web. Record actual verification and limitations.

Completion requires the whole approved behavior, not only a design or partial UI. No real contact messages/requests are sent by automated QA.
