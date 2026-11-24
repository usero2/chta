# Attachment progress completion

The connected Android device shows a delivered image with a receipt timestamp but a stale 100% bar. The legacy sender's account-scoped progress map is never cleared after its send future completes. The view renders that map without checking delivery; completed streamed snapshots also remain renderable.

Clear legacy outgoing progress on success/failure and receiving progress after its save attempt, notify the owning account only, and discard streamed completed snapshots. Keep UI defense against stale state: a delivered attachment has no progress/status spacer. A transfer at 100% without a receipt remains explicitly waiting for confirmation; never infer delivery from byte count. Ongoing transfers retain percentage/bytes; failed transfers use a concise error state rather than a full progress bar. Reuse the same presentation for image, video, audio and files across supported clients; group completion already replaces its progress card and needs no behavior change.

Preserve encrypted caching, durable receipts, retries, IDs, timestamps and file limits. Device captures remain private. No real-contact test sends, owner PIN access, TURN or new service activation. Build/install version 40 across the current Android/Windows/Web targets, audit artifacts and keep source commits local.
