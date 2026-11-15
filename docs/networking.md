# Networking

The current Internet path uses an ordered Noise-encrypted cht WebSocket relay, signed relay catalogs and automatic reconnect/failover. Windows can enable a supervised TryCloudflare relay in Connect; Web/Android/Desktop add its public URL and then select a verified contact. See [relay mesh setup](relay-mesh.md). The room-code WebRTC flow below remains a separate legacy path when Internet relays are not configured.

## Legacy WebRTC networking

The Web MVP uses the browser `RTCPeerConnection` and one ordered DataChannel named `cht-messages`. The UI exchanges opaque SDP documents through an ephemeral signaling room so users only handle a six-digit code:

1. Each person enters a name. It is remembered only in that browser profile and is included in the signed contact card.
2. One person selects **Invite a friend** and sends the displayed six-digit room code privately.
3. The other selects **I have an invitation**, enters the room code, and sees the inviter's signed name while confirming the contact-card fingerprint.
4. The signaling service returns the encrypted-session answer automatically. The inviter sees the joiner's signed name, confirms the other fingerprint, and both nodes complete the authenticated Noise handshake.

Protocol-level offer/answer terminology, generated JSON, and raw errors are not shown in the ordinary flow. Technical errors and the network discovery override are available only under **Advanced settings**.

Verified peers are shown by their signed display name on **Contacts**. Selecting the chat button opens that peer under `/chats/<peer DID>`. Connection setup remains under `/connect`; once authentication completes, the app moves to the peer's chat route automatically. An active WebRTC session is retained while switching tabs; after a browser refresh, the selected peer remains in the URL but the user must create or join a new room because WebRTC sessions cannot survive a reload.

The Web UI uses refresh-safe paths: `/chats`, `/chats/<conversation>`, `/contacts`, `/connect`, and `/connect/<peer DID>`. The development server returns the application shell for these client-side routes.

The development signaling server stores offers and answers only in memory, expires rooms after ten minutes, and does not receive message plaintext. It is prototype infrastructure, not a hardened public signaling deployment. The development server also sends `Cache-Control: no-store` and the Web entry point unregisters old service workers so a stale Rust/WASM bridge cannot survive a rebuild.

Two windows in the same browser profile share one IndexedDB identity and are therefore one node. The wizard detects this and asks the user to open the second node in another browser profile or Incognito window.

The app configures STUN automatically so ordinary users do not need to understand or enter a server address. The current development default is `stun:stun.l.google.com:19302`; deployments can replace it with `--dart-define=CHT_STUN_URL=stun:host:port`, and the UI keeps an override under **Advanced connection settings**. A STUN operator and the signaling service can observe IP addresses and connection metadata. TURN is not implemented, so some NAT/firewall combinations will fail.

## Native Desktop listener and relay

Every Desktop app starts its listener with Circuit Relay v2 enabled automatically once an identity has been unlocked and its profile/history loaded. It uses an automatically selected TCP port, no listener PIN, and the active identity's signed contact card. This happens even when the user stays on Chats or Contacts. The identity login PIN still protects unlocking; it is separate from the optional listener PIN.

An already-running listener is reused. **Stop listening** keeps the service stopped for the current unlocked session; it is not restarted by the status poll. Locking/switching identities stops it; unlocking the next identity starts a new service. Restarting the app also starts the service again after identity unlock. Users can stop the service and manually start in PIN-protected mode, which continues to disable relay service.

Automatic native TCP relay startup does not establish Internet reachability through NAT or CGNAT. Internet chat instead uses the separate browser-compatible WebSocket relay path and shared signed catalog. Native libp2p AutoNAT, client reservations and hole punching remain unimplemented; a reachable bootstrap is still needed to join the WebSocket relay network.

The Windows build bundles a separate Rust library, `cht_mesh.dll`, so native libp2p dependencies remain isolated from the browser WASM toolchain. The Desktop **Node service** currently provides:

- TCP listening on a fixed or operating-system-selected port.
- Noise-authenticated transport with Yamux multiplexing.
- Serverless LAN discovery using mDNS.
- Circuit Relay v2 service for cht/libp2p traffic when relay mode is enabled.
- A PIN-protected mode that disables public relay service.

The relay is application-scoped libp2p traffic, not a general-purpose TCP proxy. Relay circuits remain end-to-end encrypted between their endpoint peers; the relay can observe connection metadata but not message plaintext. LAN discovery needs no central server. Internet discovery still requires a shared public multiaddress, port forwarding, or an already-known relay/bootstrap peer.

The native listener is the transport foundation. Direct Desktop chat still needs the application-level DID/contact-card authentication, PIN challenge, routed Noise session, and message delivery events wired over libp2p before it replaces the WebRTC path.

## Browser/WASM to Desktop

Browser WASM cannot open a raw TCP socket to the Desktop libp2p listener. A compatible connection therefore uses a browser-safe transport behind the same cht peer protocol:

1. A reachable cht WebSocket relay exposes `/cht`, optionally through a Desktop-managed TryCloudflare tunnel.
2. Browser and Desktop register their DID using a signed challenge and learn signed relay hints from connected nodes.
3. The peers exchange signed contact cards for an already verified contact and complete Noise KK before enabling chat.
4. Clients keep backup relay connections, share the directory and establish a new authenticated session if the active route fails. Native libp2p WebRTC Direct remains a future transport; it is not the implementation of this WebSocket path.

The public Desktop node removes the mandatory centrally owned signaling service, but it does not remove the bootstrap problem: a new browser still needs an invitation or at least one known browser-reachable peer address. A relay fallback must itself expose a browser-compatible transport such as WebRTC, WebTransport, or secure WebSocket. Native TCP/mDNS discovery remains available for Desktop-to-Desktop LAN connections.

### Local Desktop companion

When the Web build and Desktop app run on the same computer, **Start Listening** also opens a localhost-only WebSocket companion on `ws://127.0.0.1:17357`. The Web chat route automatically tries this endpoint for a verified contact. The Desktop announces its signed contact card, the browser requires its DID to match the selected contact, and both sides complete the existing Noise handshake before chat is enabled. The Desktop asks for one-time fingerprint approval if it has not verified the browser identity yet.

This removes Invite/Join and the development signaling server from the same-computer Web-to-Desktop path. The gateway accepts browser origins served from `localhost` or `127.0.0.1`; payloads remain end-to-end encrypted at the cht session layer. It is not a general LAN browser discovery mechanism. Connecting a browser on another device still requires WebRTC Direct/WebTransport plus a browser-reachable address distributed through a contact card or bootstrap peer.

A connected DataChannel is not considered authenticated. Authentication becomes true only after both verified contact cards have bound the X25519 keys and the Noise KK handshake completes.
