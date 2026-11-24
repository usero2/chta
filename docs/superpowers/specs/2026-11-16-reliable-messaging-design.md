# Reliable cross-network messaging

Approved scope: the user selected recommendations 1–3: stable automatic data relays, account-scoped multi-peer connections, and a protected persistent outgoing queue.

## Behavior

- Every unlocked client joins three stable, pinned public data-relay endpoints automatically. Existing user/community relays, Direct WebRTC, relay limits and user locks remain supported. Broken routes recover without invitations or QR exchange.
- `chta.app/relay` remains discovery/signaling only. Separate data-relay services forward opaque end-to-end encrypted frames between online clients. They do not retain offline messages or files. Three Cloudflare instances provide separate relay processes, not independent provider failure domains.
- Connections belong to the unlocked account, not the selected screen. Receiving a message or file must work while another conversation, Contacts or Profile is open. Each peer has separate Noise/Direct state; one peer's reconnect must not close another's network.
- New outgoing messages/files are cached and queued in protected account storage before transmission. Retries and restarts retain the original message ID, send timestamp and cached attachment references. Offline waiting does not exhaust delivery retries. Only a durable authenticated recipient receipt marks delivery.
- Switching/locking identities and deleting conversations invalidate old work. Old historical failed messages are not silently resent. Duplicate deliveries retain the original stored receive time.
- The composer accepts messages while offline and displays waiting/sending state. Seed connection alone never means that a peer is securely connected.

## Infrastructure

Use the existing authorized Cloudflare account with separate Worker/SQLite Durable Object services, bounded traffic and WebSocket hibernation. Relay signing keys are generated separately from user identity keys and installed through Workers secrets. Only public relay IDs are committed. Do not change the Cloudflare subscription or provision paid servers. Do not log payloads, user keys or owner-specific data. Production probes use synthetic identities only.

## Exclusions

No server offline mailbox, TURN, Android OS background-service changes, tray feature, group-admin changes or device-sync implementation in this scope. Existing groups must continue working.

## Verification

Prove concurrent two-peer reception, no route ownership interference, offline enqueue/restart/reconnect, lost ACK/replayed delivery, storage failure withholding ACK, delete/lock cancellation, attachment resume and native/WASM interoperability. Test the actual public relay endpoints with synthetic clients and force relay failover. Run existing Flutter, Worker and relevant native regression suites. Build Android, Windows single EXE and Web using the sanitized release pipeline, inspect the built payloads for personal paths/data, and deploy/install without sending messages to real contacts.
