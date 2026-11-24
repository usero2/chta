# Seed quota recovery

The discovery Worker now advertises `session-dispatch-v1`. Updated clients sign each dispatch against the root identity, seed ID, connection challenge, sequence and complete signed-envelope digest. The Durable Object reserves the sequence in the socket attachment before forwarding. It continues to validate the original SDP/ICE or sealed contact-setup schema. Chat messages and file packages remain excluded.

Legacy signaling requires its original durable replay reservation. Storage failure returns `storage-unavailable` and never forwards the signal. Updated clients back off on that error and identify the required update. Discovery catalogs can be republished; optional persistence is not required for live discovery. Global IP throttling is bounded but best effort across cold restarts without storage; per-socket rates and dispatch sequences survive attachment reconstruction.

Verified on 2026-11-18:

- Rust workspace: 99 passed, one explicit fixture-generation skip. The native command gateway also passed its added dispatch argument test.
- Flutter: 467 passed, eight opt-in integration skips; analysis reported no issues.
- Worker: 38 passed. Real workerd sockets registered and forwarded updated dispatches when every SQL method in the fixture threw a quota error. Replay/content and legacy fail-closed checks passed.
- Compiled Wasm account produced a dispatch accepted by the Worker verifier. Native Rust and JavaScript shared the same deterministic signature fixture.
- Independent whole-plan review found no Critical, Important or Minor issues in the implementation range.
- Production Worker version `c5ae7be5-666b-4274-a7b2-b73f8779d8e3`: public WSS registration, lookup, direct/group/contact dispatch and legacy signaling passed with disposable identities. The active Durable Object was moved to the new version with an immediate code update.
- The existing deployed Web asset manifest remained unchanged, all 59 files. No client build or Git release was published by this seed-only deployment.

Rapid repeated smoke runs encountered the existing per-IP rate limit (HTTP 429). A fresh-window run passed; the captured Worker events reported no exceptions. This does not claim an Internet Direct path succeeds through every NAT, that old clients can signal after a storage quota failure, or that Courier delivery has already shipped.

All detailed logs, synthetic harnesses and captures remain outside public source. No owner contacts received QA messages and no owner identity, PIN or recovery phrase was inspected.
