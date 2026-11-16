# cloudflared runtime

Windows releases bundle the unmodified x64 executable from the pinned [official Cloudflare release](https://github.com/cloudflare/cloudflared/releases/tag/2026.11.0). `artifact.json` records its upstream SHA-256 digest and size. The build downloads it into the ignored build cache, verifies it and includes it in the single-file runtime.

The component uses the Apache License 2.0, included in `LICENSE`. It remains a separate executable inside the extracted runtime; chta source remains MIT-licensed. Quick Tunnels are operated by Cloudflare.
