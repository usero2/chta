# Reliability audit after build 38

The user requested a deeper reliability assessment and improvements. Preserve the existing direct/relay architecture, identity isolation, E2E encryption, duplicate detection, durable receiver receipts and file limits. No TURN activation, paid service, server mailbox, owner-message tests or Windows GUI automation.

Investigate delivery when a Direct channel reports ready but drops payloads, immediate send failures, lost receipts, bursts, reconnects, and writes appended during a history flush. Fix demonstrated defects with failing regressions first. Text retries should alternate usable authenticated transports using the original ID and timestamp; a route error should try the other usable transport. Route availability is not delivery confirmation. Large-file route rules must not change.

History flush must wait for writes added while earlier writes are still saving, so callers do not mistake an old queue snapshot for a completed save. Preserve existing error reporting and account/room generation guards.

Run the full Flutter suite, actual native public-relay proof and available physical tests with synthetic identities. Report gaps such as independent carrier/CGNAT, extended idle/Doze, Activity destruction and interactive tray testing explicitly. Build sanitized version 39, update existing local apps/Web, retain source locally, and do not claim universal reliability from test counts.
