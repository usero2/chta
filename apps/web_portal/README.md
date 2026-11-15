# chta.app portal and discovery seed

The English homepage and getting-started guide are `public/`; `/chat/` packages the existing Flutter app. `/relay` only authenticates discovery, verifies signed SDP/ICE and shares signed public `/cht` relay hints. There is no content relay, mailbox, arbitrary route, upload handler or caller-supplied URL fetch. The browser client still verifies its selected contact's signature and owner binding independently.

Use Node 22.12+ and `npm.cmd` on Windows:

```powershell
cd apps/web_portal
npm.cmd ci --ignore-scripts
npm.cmd test
npm.cmd run build
npm.cmd run dev -- --port 8789
npm.cmd run dry-run
npm.cmd run dry-run:production
```

Build Flutter first, from `apps/flutter_app`, after building its Rust WASM bundle:

```powershell
flutter build web --release --base-href /chat/ --dart-define=CHT_APP_BASE_PATH=/chat --dart-define=CHT_SEED_URL=wss://chta.app/relay --no-web-resources-cdn --pwa-strategy=none
```

`scripts/build-web-portal.ps1 -DryRun` from the repo root installs locked tooling, runs tests, packages the actual build and prepares a workers.dev dry run. Packaging rejects a missing/incomplete build or incorrect base path. It never runs Flutter, signs into Cloudflare, publishes, changes DNS or installs user identities. Keep the local CanvasKit/WASM files; remote resources are not required for the homepage.

The default Wrangler configuration stages `chta-app` on workers.dev. The explicit `production` environment uses `chta.app` as a custom domain with a separate Durable Object namespace. Authenticate and verify zone ownership before deployment; a dry run proves bundling only. SQLite Durable Object migration `v1` creates `SeedDirectory`. The supported compatibility date is `2026-11-01`; `2026-11-15` was rejected as a future date by the installed runtime.

Published on 2026-11-15: [homepage](https://chta.app/), [Web app](https://chta.app/chat/), discovery seed `wss://chta.app/relay`. Production Worker `chta-app-production`, version `dce645c0-d36e-4815-9890-8edd7e7c78a1`. Production HTTP route/asset/content-rejection checks and real WSS registration, presence and signed SDP forwarding passed using disposable synthetic identities. Before promotion, two independent browsers used the public staging seed and actual Rust/WASM signatures to establish WebRTC, stopped the seed and transferred 27,263,099 bytes directly with matching digest. This is a bounded functional test, not a throughput/capacity claim for 1000 concurrent users.

`npm.cmd test` includes an actual disposable Wrangler/workerd process, local HTTP assets and real WebSockets. It uses synthetic Ed25519 identities and temp storage, checks registration, lookup, signed forwarding, replay and rejected content/binary/oversize input, then removes that test storage. Unit tests reconstruct a hibernated object from serialized attachments and persisted metadata, including replay/rate capacity, async closure and catalog expiry. They consume the deterministic Rust-owned fixture under `test/fixtures/`. Runtime tests do not prove eviction in Cloudflare production or WebRTC data transfer.

Memory and metadata bounds: 1–1000 total sockets (`SEED_MAX_SOCKETS`, default1000), four registered sockets per DID, 30-second one-use challenges, 16384-byte frames, 90 handled frames and 12 lookups per socket/minute, 240 IP units/minute (new connection costs8), 2048 hashed IP buckets, 64 simultaneous validations, 16 queued validations per socket, 32 pending upgrades, 8192 unexpired signal replay entries, 1000 signed relay records and up to 64 records per exact-byte-bounded batch. New relay hints reach already registered clients; further batches coalesce for five seconds using durable pending IDs and alarms, including hints beyond the initial registration frame. Full replay capacity rejects new signals rather than discarding live protection. Replay hashes/expiries, hashed short-lived IP buckets and public signed relay hints are persisted; SDP/ICE and content are never stored. Idle registration challenges expire by alarm. The runtime's automatic exact keepalive reply is enabled only when every open socket has authenticated, because its configuration applies to the entire Durable Object.

Public relay URL checks reject local/private/reserved literals, credentials, fragments and queries, and require a `wss://` `/cht` URL. They perform no DNS resolution or network fetch. Seed readiness does not prove NAT traversal or a reachable community relay. Homepage conversation and file transfer are explicitly labeled synthetic illustrations; there are no download links or testimonials.

Worker-first handles all assets so entry HTML consistently receives `no-store`, root unknown paths stay404 and only mounted application routes fall back, including authentication routes; unhashed assets revalidate and only fingerprinted files are immutable. The build requires actual main/bootstrap/Rust WASM/local CanvasKit artifacts so a partially written Flutter build cannot be packaged as ready. Account quotas and ongoing costs remain Cloudflare account operational responsibilities.

Cloudflare references: [hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [static asset binding](https://developers.cloudflare.com/workers/static-assets/binding/), [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/).
