# Automatic attachment cache and minechat media flow

Status: user instructed implementation with one amendment: no camera/capture/recording work; only sending and receiving existing images, videos, audio and files. Full media-selection, preview, caption, album and viewer flow is included. Separate encrypted cache is the implementation approach selected by the agent.

## Intent

Receive files into the chat automatically on Desktop, and make selecting, sending and viewing images/videos on Android behave like `the reference chat project`. Saving a separate user-visible copy must be optional. Keep the Flutter UI and Rust identity/encryption core already in cht.

## Current behavior and evidence

- Received attachments are assembled automatically, SHA-256 checked, and embedded as base64 in encrypted peer history. Download exports a separate copy; it is not the network download. The current label does not communicate this distinction.
- History rewrites include all attachment bytes. The final transport receipt currently need not wait for the history write. A separate cache permits larger histories without rewriting every file after each message.
- Images render one thumbnail per message. Videos render file cards. The composer sends typed text separately, followed by individual attachments.
- The minechat reference uses a bottom attachment sheet, removable 76dp preview tiles above the composer, caption text on the first item, image albums, grouped videos and media viewers.
- The Android picker defect was independently traced to stale generated native registration. Build 20 has regenerated registration and is installed. Real-device picker verification remains pending the user's PIN unlock; no PIN is requested in chat.

## Approaches

1. Keep attachment bytes inside history and improve only previews/labels. Small change, but each history update continues to rewrite every attachment.
2. Store encrypted attachments separately and keep references in history, then add the minechat media presentation. More migration and storage work, but avoids repeatedly encoding and rewriting large files.

Implementation choice: approach 2. Preserve existing messages and migrate incrementally; never discard an embedded attachment before its cache write succeeds.

## Desktop automatic cache

- While the application is unlocked and the peer session is connected, receive attachments without a Download action.
- Validate size, metadata and integrity. Persist the complete attachment before acknowledging its final packet as received.
- Key cache entries by identity and attachment digest, with metadata in history. Keep encryption at rest using the existing platform protections: Windows DPAPI, Android wrapping-key protection, and Web IndexedDB wrapping-key encryption. Do not persist plaintext files merely because they arrived.
- Duplicate messages and retries reuse the same verified cache entry. Separate identities cannot access each other's cache.
- Render available media from the cache automatically. Show receiving progress followed by a compact cached indicator. Use **Save copy** for exporting an additional copy outside cht.
- Image/video previews and media playback do not depend on the sender remaining online after reception.
- On insufficient storage or failed cache writes, keep the message incomplete and expose retry. Do not acknowledge durable reception or delete the old history data.
- Retain cache with history. Automatic eviction, cache-clearing UI and user disk quotas are outside this change; do not silently delete chat files.

## Android media flow (confirmed scope without camera work)

- Replace the small attachment menu with a mobile sheet for gallery images/videos, audio and files. Do not add camera capture, video recording or CCTV functionality. Keep the existing QR scanner. Desktop/Web retain suitable platform options.
- Gallery supports selecting multiple images/videos together. Existing 5-item and 100 MiB total selection limits remain; the current transport permits 100 MiB per file directly and 25 MiB via relay.
- Show image thumbnails and video tiles with play indicators above the regular composer. Each item can be removed before sending.
- Send the batch once. Typed Markdown becomes the caption of the first eligible item, using the reference order: images, then videos, then files. Do not duplicate the caption as a separate text message.
- Images selected together appear as one album grid. Videos selected together share a batch row with thumbnails and play indicators. Group only matching explicit batch IDs from the same sender; never merge unrelated messages by timestamp alone.
- Tap to open a media viewer backed by cached bytes. Support browsing the selected album, image zoom, video playback controls and returning to the same chat. Do not autoplay newly received audio/video without a user action.
- Camera/gallery cancellation leaves the draft intact. Transfers can fail and retry independently without duplicating already received items or the caption.

## Protocol, persistence and compatibility

- Continue using authenticated encrypted sessions and existing chunk size/backpressure. Keep the transfer limits; this change does not add NAT traversal or raise relay limits.
- Add bounded optional caption/batch metadata. Enforce the existing serialized packet limits including metadata; do not silently truncate captions or create oversized Noise frames.
- Make saved attachment references self-contained: cache key/digest, original safe filename, MIME, size and batch/caption fields. Existing embedded history is still readable.
- Import old attachments into the cache, verify the write, then atomically replace the embedded history entry with a reference. Leave the original recoverable if any step fails.
- Protect new metadata under the same encrypted message/history boundaries. No external image URL fetching or automatic execution of received files.
- Older clients may display individual files without album presentation; preserve basic reception where protocol fields are optional. Explicitly version any incompatible envelope changes and report unsupported peers rather than exposing raw control packets.
- Document that file bytes are still bounded in memory by current transfer policy; multi-GB streaming and resume after process restart are separate work.

## Acceptance checks

1. Desktop receives a file, persists it automatically, restarts, disconnects the peer and can still view the cached attachment without Save copy.
2. Final receipt waits for durable cache success; disk-write failure does not claim completion. Retry and duplicate packets do not create duplicate cache/history entries.
3. Existing text, embedded attachments, timestamps, contact names and avatars survive migration and identity switching.
4. Android can choose actual files/images/videos through system pickers on the connected device, cancel safely and remove staged items.
5. A multiple-image/video send shows the expected preview tiles, caption and album/video grouping at both ends.
6. Image viewer and video controls work from cache, with no additional network fetch after reopening history.
7. Regenerate and verify native plugin registration after dependency changes. Build/install fresh versioned artifacts and report the tested versions accurately.

## Explicit scope boundary

No camera capture, CCTV, audio recording or video recording. Select existing files from the device only. Preserve existing identity, contacts, relay and QR behavior. Do not send test messages to real contacts or request their PIN/recovery phrase.
