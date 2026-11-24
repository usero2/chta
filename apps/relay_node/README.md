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

Add `wss://YOUR-HOST/cht` in the app's Connect screen. To preconfigure a pinned provider in a client build, pass a JSON array with Flutter's `--dart-define=CHTA_RELAY_PROVIDERS=…`. Each entry supplies `endpoint`, `id` (the relay's authenticated 64-character hexadecimal identity) and `domain` (a short lower-case name for its operator). The three built-in data relays share the `cloudflare` domain. Assign the same label to any endpoints that share infrastructure. Peer advertisements cannot set these labels. The connection limit stays at the user-selected 50–1000.

The independent-process test runs two disposable relay executables and verifies root authentication and continued forwarding through the second after the first exits. Container/TLS deployment still requires an operator test on the chosen public host. No non-Cloudflare public relay was deployed as part of this change.

```sh
cargo test --locked --manifest-path rust/crates/relay_server/Cargo.toml --test provider_processes
```
