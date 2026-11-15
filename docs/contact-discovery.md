# Contact discovery

A contact card is versioned JSON containing only public data: identity ID, a user-chosen display name, Ed25519 root public key, Noise X25519 public key, random contact token, supported capabilities, and an Ed25519 signature over the canonical card payload. The display name is signed with the rest of the card, so changing it invalidates the signature.

The importer verifies the signature, verifies that the identity ID hashes to the supplied root key, validates key/token lengths, and rejects duplicate contacts. Flutter can render the card as a QR code, scan it with the camera, or accept pasted JSON.

The Contacts user flow is:

1. Open **Contacts** and let the other person scan **Your contact card**, or copy the public card to them.
2. To add someone, choose **Scan friend QR**, **Import QR image** (Android), or **Paste friend card**. With **Save my QR image**, Web/Desktop/Android can export a 1200×1200 PNG with a white quiet zone and send it privately as a file. The Android document picker imports the original image and reads it using the bundled, offline ML Kit scanner.
3. cht validates the signature before showing the signed name, DID, and security fingerprint.
4. Optionally set a local alias. Compare the fingerprint over a separate trusted channel and check the confirmation when it matches.
5. Select **Add friend**. Unverified friends may be stored, but chat stays disabled until their fingerprint is marked verified.

Adding a friend is a local signature-verification and storage operation. It works across unrelated networks and does not require USB, matching Wi-Fi, a listening Desktop, a directory server, or a live peer connection. Send the public card/QR image through an existing private messaging channel, then import it. Compare the fingerprint in person or over a trusted call/message; importing a signed card alone does not mark the human identity as verified.

Friend import does not establish an Internet chat route. Web, Android and Desktop can add a shared reachable WebSocket relay under Connect; Windows can create one through TryCloudflare. See [relay mesh](relay-mesh.md). The USB Desktop companion remains available when no Internet relays are configured. The QR importer does not fetch arbitrary URLs from scanned content.

Contact dialogs keep their text controllers until the closing route has left the overlay. The scanner route also finishes closing before the add-friend dialog opens. This prevents the controller-disposal error and subsequent red Flutter `_dependents.isEmpty` assertion during mobile import. Dialog content scrolls when the keyboard reduces available height. Camera errors offer a readable explanation and the image/card alternatives.

Profile avatars are normalized locally to a 256×256 JPEG with a 256 KB maximum. Shared cards contain an optional signed JPEG thumbnail, normally 48×48 pixels, capped at 1024 bytes so the contact QR remains bounded. The receiver accepts dimensions up to 64×64 and includes the avatar in signature verification. Empty avatars are omitted to retain compatibility with existing cards without photos; older clients must be updated to verify cards containing avatars.

The Contacts page displays the local profile photo and name. Friend photos appear in Contacts, the Chats sidebar, and the selected chat header, with an initial fallback when no usable photo exists. A new connection refreshes signed name and avatar while preserving the local alias and fingerprint verification. Friend thumbnails are cached with local encrypted history for offline display. The Desktop companion refreshes its advertised contact card when the local profile changes; connected friends receive the update on their next connection.

The displayed fingerprint is SHA-256 of the root public key, formatted as eight groups of eight uppercase hexadecimal characters. Users must compare it over a trusted channel before marking a contact verified. A connection is refused until that verification flag is set.

The random contact token is not a global address and cannot locate a peer. There is no global directory.

On browsers without the native `BarcodeDetector` API, the current `mobile_scanner` package may load its `zxing-wasm` fallback from a public CDN. Production deployment should self-host or bundle that fallback and pin it through the site's Content Security Policy.
