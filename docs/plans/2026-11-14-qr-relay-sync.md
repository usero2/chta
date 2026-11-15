# QR and Relay Sync Implementation Plan

Goal: keep Reconnect and Scan QR available together; safely accept matching signed contact cards or relay addresses; exchange bounded relay metadata only through authenticated verified peer sessions.

Architecture: reuse fingerprint confirmation for contact QRs and reject a selected friend mismatch before mutation. Use a reserved versioned peer control envelope over existing encrypted message transport, filtered before visible events. A small relay sync coordinator debounces local changes, snapshots public URLs and verified records, scopes sends to the active authenticated peer, and deduplicates identical catalogs.

Constraints: no native transport changes, no real contact traffic, no commits. Existing signature inspector verifies records; URLs are public wss addresses, bounded before mutation. The authenticated transport stays active when newly learned relays enable the network.

- [x] Add failing widget tests for side-by-side scan/reconnect, matching contact verification and mismatching rejection.
- [x] Implement QR branching and preserve existing route scan injection.
- [x] Add failing coordinator/network tests for authenticated lifecycle, change propagation, deduplication, and unsafe/oversized data.
- [x] Implement reserved control coordinator plus relay/native/WebRTC routing and filtering.
- [x] Focused tests and analyzer passed; full integration suite 167 passed with two optional skips. Final read-only review found no serious unresolved findings after direct-route and queued-control race regressions were added.
