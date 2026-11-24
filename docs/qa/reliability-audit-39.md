# Reliability audit: 0.0.1+39

## Assessment

Build 39 improves demonstrated delivery failures. It is suitable for further controlled trials; these results do not establish reliable operation across every carrier, NAT, device lifecycle or prolonged outage. No delivery percentage or uptime guarantee is inferred from the number of unit tests.

## Defects reproduced and fixed

- **Ready Direct channel, missing delivery:** text retries previously selected Direct repeatedly even when that channel silently discarded packets or receipts and a verified relay was usable. Retries now alternate usable authenticated transports with the same message ID and send time. An immediate transport error tries the other available route. Only a durable receipt marks delivery.
- **Large backlog losing failover preference:** an initial 256-ID tracking cache was rejected during independent review. A paired-service test with 258 pending messages reproduced starvation. Route preference now belongs to each existing message as an ephemeral boolean; no ID cache can evict a pending decision. It does not change the wire/history schema and resets safely on restart.
- **Flush returning too early:** waiting on a single write-queue snapshot could finish while another message/receipt save was still pending. History flush now drains writes added during the wait. Storage errors remain visible; generation guards remain intact.

Attachment routing and the 25 MB application-relay limit are unchanged. This text failover does not send large-file packets through a route that violates their policy. TURN remains deferred, with no new paid service activated.

## Evidence

| Check | Result |
| --- | --- |
| Silent Direct loss, Direct send error, Direct receipt loss | Reproduced failing delivery; fixed and passed with stable ID/time and no duplicate bubble |
| 258 pending messages | Reproduced cache-thrashing failure; fixed and passed |
| Save appended during another save | Gated test failed before the fix and passed afterward |
| Full Flutter suite | 380 passed, 8 opt-in/platform tests skipped |
| Static analysis | No issues |
| Actual native Rust and public WSS relays | Separate opt-in test passed, including 100 bidirectional messages, protected outbox reload after restart, dropped receipt and duplicate recovery, cached 64 KB file with hash verification, and primary relay loss with backup delivery |
| Independent read-only review | Important backlog issue fixed; no remaining Critical/Important findings in reviewed changes |
| Android background reception | Build 38 physical Home/return, file/progress/hash and Lock proof remains prior evidence; build 39 uses the same native runtime. This audit does not claim a new Android cross-carrier proof |

The public-relay proof uses disposable identities in isolated native processes. It sends no messages to real contacts. It exercises Internet WSS transport, but does not establish independent carrier or cellular coverage. Stable flush can take longer during continuous writes; the existing native exit timeout keeps the app available rather than silently discarding work.

## Remaining validation priorities

1. Physical Desktop ↔ Android on separate Wi-Fi/mobile networks, including network handover and large resumable transfers.
2. A 24–72 hour idle and traffic soak, screen-off/Doze and real Activity destruction/recreation. Home/return alone does not cover those cases.
3. All default data relays unavailable simultaneously. The three current default endpoints share Cloudflare, so they are not independent provider redundancy. With no usable Direct or data relay, work must remain queued; the seed alone cannot deliver content.
4. Disk full/corruption and abrupt OS termination during sustained transfers. Refusing to send or acknowledge unpersisted content is intentional; recovery UX still deserves additional device testing.
5. Interactive Windows tray/exit and Web background-tab throttling on each supported browser. A closed browser tab does not provide local reception.

Offline receiver delivery still requires the receiver to reconnect while a sender is available to retry. This release adds no server-side offline mailbox. Build/install and source/artifact privacy checks are recorded separately in the local release evidence; no GitHub release is created by this audit.
