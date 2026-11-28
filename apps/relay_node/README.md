# Portable data relay

This deployment uses the existing Rust WebSocket relay. It works with the same root-authenticated `/cht` protocol as the Desktop, Android and Web clients. It forwards opaque encrypted frames while peers are online; it is not the discovery-only seed and does not store an offline inbox. Courier hosting is a separate Desktop capability.

Run it on a reachable server with DNS and ports 80/443 available. This example uses Caddy for TLS and does not need Cloudflare or TryCloudflare. Replace `relay.example.com` in both configuration files with the same hostname. Keep `allow_loopback` false on public deployments.

From this directory, create a private credential before starting:

```sh
mkdir -p .local
chmod 700 .local
openssl rand -base64 48 > .local/relay-key-password
chmod 600 .local/relay-key-password
sudo chown 10001:10001 .local/relay-key-password
docker compose -f compose.example.yaml up --build -d
```

Keep the state volume and credential together across restarts. The relay identity is encrypted on disk. Losing either changes the relay identity; clients will reject an unexpected replacement under an existing pin. Do not commit the credential, state volume or a filled deployment configuration.

## Verify it from another network

Run both checks from outside the server's network. The first checks public HTTPS and shows the relay build, protocol version and supported capabilities. The second upgrades `/cht` to WebSocket, validates the relay's signed address, registers a temporary in-memory identity and waits for a keepalive response.

```sh
curl --fail --silent --show-error --max-time 15 https://relay.example.com/healthz
cht-relay --probe-websocket wss://relay.example.com/cht
```

If the relay binary is available only inside Docker, build it from the repository root on the test machine with `cargo build --release --locked --manifest-path rust/crates/relay_server/Cargo.toml`. Run the binary at `rust/crates/relay_server/target/release/cht-relay` (`cht-relay.exe` on Windows). The probe uses the public hostname and works without the server configuration or password file.

| What fails | What to check |
| --- | --- |
| DNS resolution | The A or AAAA record points to the server. Remove an AAAA record if the server cannot receive IPv6. |
| Connection or TLS | Allow ports 80 and 443 to reach Caddy. Check `docker compose -f compose.example.yaml logs tls` for certificate errors. |
| HTTPS passes, WebSocket fails | Make sure the reverse proxy forwards upgrades on `/cht`. Check the `relay` and `tls` logs for backend errors. |
| Signed address mismatch | Set `websocket.public_url` to the exact public `wss://…/cht` address and restart the relay. |
| Probe passes, a conversation still fails | Check that both users can connect to the relay. The probe checks an individual relay connection and registration. |

Add `wss://YOUR-HOST/cht` in the app's Connect screen. To preconfigure a pinned provider in a client build, pass a JSON array with Flutter's `--dart-define=CHTA_RELAY_PROVIDERS=…`. Each entry supplies `endpoint`, `id` (the relay's authenticated 64-character hexadecimal identity) and `domain` (a short lower-case name for its operator). The three built-in data relays share the `cloudflare` domain. Assign the same label to any endpoints that share infrastructure. Peer advertisements cannot set these labels. The connection limit stays at the user-selected 50–1000.

The independent-process tests cover the WebSocket probe, root authentication and continued forwarding through the second relay after the first exits.

```sh
cargo test --locked --manifest-path rust/crates/relay_server/Cargo.toml --test provider_processes
```
