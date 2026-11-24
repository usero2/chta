# Connecting and sending messages

Current clients automatically connect to three pinned public data relays:
`relay1.chta.app`, `relay2.chta.app`, and `relay3.chta.app`. No invitation, relay QR, public IP or Desktop hosting switch is needed for two current clients to reconnect. Both people must have accepted the contact and have an unlocked app online.

`chta.app/relay` remains discovery/signaling only. The separate data relays forward live end-to-end encrypted packets and do not provide offline message or file storage. They use separate Cloudflare Worker/Durable Object instances; they share a provider and therefore do not provide provider-independent redundancy. User-hosted/community relays remain available.

Messages and cached attachments wait in the sender's encrypted local history until an authenticated receipt arrives. New queued work survives restarting the app and retains its original message ID and timestamp. Old failed messages are not silently resent. A slow file does not block text to the same contact. Files above 25 MB wait for Direct WebRTC; smaller files can use a data relay. Delivery timestamps mean the recipient durably stored the message, not merely that a relay accepted a frame.

Connections belong to the unlocked account. Opening another chat, Contacts or Profile leaves other peer connections and transfers running. Locking/switching identity stops its transport. Android OS background restrictions still apply; this change does not add push notifications or a foreground service.

## Hosting the default services

`apps/web_portal/wrangler.data.jsonc` defines three independent deployments. Each requires `RELAY_PRIVATE_KEY` (Ed25519 PKCS#8 DER, base64url) and `RELAY_PUBLIC_KEY` (32 raw bytes, base64url) through Workers secrets. Never commit the private key. Clients pin the public-key SHA-256 ID in `default_relays.dart`. Rotating a pin requires a coordinated client release; a changed server identity is rejected rather than silently trusted.

Deploy each configured environment with Wrangler. SQLite Durable Objects use WebSocket hibernation. Authentication and bounded rate metadata live with sockets; payloads are never written to Durable Object storage. Limits are 256 live sockets per instance, four sockets per identity, bounded frame/queue sizes and traffic limits. This is not a guarantee of uninterrupted service: account quotas, provider outages and client connectivity can still prevent delivery. Monitor service health and Cloudflare usage, and add independent community providers as usage grows.

The opt-in `messaging_native_test.dart` proof uses synthetic native accounts, protected history/cache storage, live public relays, deliberately lost receipts and an injected primary-route outage. Enable it only for network integration QA. Never use real contacts for automated test sends.
