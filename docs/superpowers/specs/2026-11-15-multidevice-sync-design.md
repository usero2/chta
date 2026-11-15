# Multi-device sync and Profile device list

Status: approved by the user on 2026-11-15. Automatic sync after same-identity login; no QR pairing.

## Agreed behavior

The user chose **automatic sync after logging into the same identity**, without QR pairing. They also requested a Profile list of devices, Online/Offline status and Last seen. Existing Windows, Android and browser/WASM clients must interoperate. Keep the root `did:cht:` identity and existing recovery/PIN behavior.

เมื่อเปิด identity เดียวกันหลายเครื่อง ให้ค้นหาและซิงก์กันอัตโนมัติ หน้า Profile แสดงชื่อเครื่อง ประเภทเครื่อง ป้าย “เครื่องนี้” สถานะ Online/Offline และเวลา Last seen โดยไม่ต้องเพิ่มเครื่องด้วย QR

Messages, contacts/aliases, profile, group history and attachment references converge across reachable devices. Cached attachments can be copied in encrypted, resumable transfers under the existing file limits. Neither messages nor file bytes go through `chta.app/relay`.

## Approaches

1. **Automatic discovery after same-identity login — selected by the user.** A restored identity proves ownership and authorizes a distinct device key. No extra pairing screen. A person who possesses the recovery phrase can add another device; PIN remains local protection.
2. **QR approval from an unlocked device — not selected.** Adds an explicit first-sync confirmation step. It cannot replace recovery when every original device is lost.

This design adds device identity and sync; it does not describe the existing same-key connections as already supporting multi-device.

## Current constraints

- Recovery derives the same root signing and identity Noise keys. Current normal chat addresses a DID, without a Device ID.
- Public seed and Desktop WebSocket relays permit four sockets per DID and fan out packets to matching sockets. An app already opens separate DM and Groups seed sockets. Four sockets does not mean four supported devices.
- Current seed validation rejects self-DID signaling. Device discovery requires a separate authenticated protocol, not an exception that lets arbitrary self-addressed messages through v1/v2.
- Native account data, PeerHistory, GroupController public state/history/outbox and cached attachments are separate local stores. A single encrypted snapshot overwrite would lose concurrent edits.
- Root group membership chains have one owner signature and reject forks. Two devices must not independently create competing membership epochs.

## Builder decisions proposed for approval

- Start with **up to eight simultaneously online sync devices per identity**. Offline device records do not consume a live slot; a lost or reinstalled offline device therefore does not permanently block adding its replacement. Keep up to128 known device records, retaining recent offline devices for Last seen and archiving the oldest offline metadata only when that bound is reached. Never delete keys, messages or cached files as roster cleanup. If eight devices are actually online, the next unlocked device shows a device-limit state until another one disconnects; it may still display its local data. A browser profile is one device; multiple tabs in that profile share its device identity. A fresh browser profile or a new installation is a new device.
- Sync messages, delivery receipts, contacts/aliases, profile and validated group state/history automatically. File metadata and available bytes catch up in the background using resumable transfers; files above25MiB require Direct, up to10GiB/file, as today.
- **Delete chat remains local to that device**, matching the current confirmation dialogs. A persisted local deletion barrier prevents historical backfill from restoring messages the user removed. New messages remain receivable. Friend removal and profile/alias edits are account data and sync across devices.
- General/Design are local template rooms. Their deletion and local contents remain device-local; they are not remote conversations or a new shared notebook feature.
- Online means a recent authenticated device presence, not that a particular Direct route is ready. Use a20s heartbeat and90s expiry to absorb temporary network changes. Last seen is an observed authenticated time, stored in UTC milliseconds and displayed locally as `yyyy-MM-dd HH:mm:ss.fff`; an unknown value is `—`.
- Existing groups keep a designated device for owner membership changes. Other devices can chat, receive and send files, and request an owner change through that device. If it is offline, those membership changes wait instead of forking the group.
- Do not add remote logout, device revocation UI, unattended cloud mailboxes, background Android services or push wake-up in this release. The device record format must leave room for future revocation.

## Device identity and storage

Generate an identity-scoped random Device ID, Ed25519 device signing key and X25519 Noise static key. Persist the private record using the existing native protected vault or Web IndexedDB wrapping key. Keep device private keys inside Rust/platform storage boundaries; do not return them through the Dart operation API. Bind public keys to the root DID with a canonical, domain-separated root-signed device certificate. Device keys must not be deterministic derivatives shared by every recovery restore.

The certificate contains version, owner DID/root key, Device ID, device signing public key, device Noise public key, creation time and root signature. Human-readable device names belong in encrypted account metadata; discovery can expose only a generic platform label and opaque device identifier. Validate exact fields, lengths, DID/key relationships and signatures before admitting a record.

Locking or switching identity clears device sessions and stops presence/sync for that identity, while retaining its encrypted device key. Relaunching restores the same Device ID. Missing or damaged private device state must fail closed or create an explicitly new device after identity unlock; never silently reuse an old Device ID with different keys or reset a journal sequence under an existing epoch.

Native clients enforce a single sync writer per installation/identity. Web tabs use an origin-scoped leader/lock and IndexedDB transactions so two tabs cannot allocate duplicate sequence numbers. Losing the leader tab permits another tab to resume the same device journal.

## Device-aware discovery and presence

Add a separate versioned device-sync namespace to the seed. Authenticate the root proof, device certificate and device proof of possession bound to the challenge/session. A device socket can query and signal only devices belonging to its authenticated owner DID. The server indexes owner DID + Device ID + socket purpose, rather than counting all purposes as separate devices.

Keep old DM and Groups protocol validation intact. Introduce explicit per-device/purpose and per-owner limits so eight devices can coexist without the old four-socket limit rejecting normal connections. Bound total sockets, pending verification, registration attempts, roster entries, replay reservations and signaling frames. Preserve old clients' validation rules; they need not understand device-sync metadata.

Only certificates, presence/roster identifiers, signed SDP and ICE are accepted by the seed. Reject message bodies, sync pages, profiles, contact lists, attachment manifests/chunks and arbitrary packet types. A seed status hint alone cannot authorize a data session or overwrite local account data.

Profile shows the known device roster even when devices are offline. Confirm Online with fresh authenticated presence and expire it after90s; a clean lock/close may mark Offline sooner. Persist and coalesce Last seen writes. Avoid showing a restored stale record as Online or refreshing Last seen merely because the local Profile page was opened. There is no claim that an app suspended by Android remains online.

## Encrypted device transport

Use independent, bounded Noise sessions per device pair. Reuse the existing Noise library and data-only WebRTC transport, with the device static keys and a new prologue binding owner DID, both Device IDs, role and random Session ID. Never reuse the identity DM or group session registry/counters for sync.

Start Direct automatically after discovery. A reachable user/Desktop content relay may carry encrypted sync if Direct fails. Preserve25MiB relay and10GiB Direct file policy. The public seed remains metadata-only. No route means waiting/retry with backoff, not plaintext or seed-content fallback.

Serialize SDP/ICE and ciphertext processing. Stage replacement handshakes separately and promote only after authentication; delayed probes must not evict an authenticated session. Apply queue, fragment, assembly and timeout bounds. Capture owner/device/session generation across awaits so callbacks from a locked identity cannot read or write another identity's stores.

## Replicated data and conflict rules

Use a device-signed append-only event stream with stable event IDs, journal epoch, per-device sequence and logical clock. The encrypted envelope binds owner, origin device, object ID/type and payload. Signatures and session authorization precede parsing/applying events. Do not use wall-clock timestamps alone to decide conflicts.

- Contacts: validate the friend's signed card first; sync verification decisions only from an authenticated own device. Aliases/profile fields use deterministic last-writer ordering by logical clock and Device ID. Contact removal uses a tombstone so stale backfill cannot re-add it.
- Messages: merge by stable conversation/sender/message ID. Preserve sent/received times, direction and source identity. Receiving the same message through normal chat and sync must produce one message and one per-device notification at most. Historical catch-up does not trigger new-message notifications.
- Receipts: merge monotonically; a delivered message must not regress to pending. Replicate a local outbox record's origin, but only its designated sender retries normal peer delivery. Do not let every linked device independently resend the same pending packet.
- Profile/images: sync metadata and content references; transfer larger image bytes through the protected cache rather than oversized control events.
- Group data: validate signed membership chains and events using the existing core. Merge only matching chain prefixes; detect a fork and preserve both evidence/data rather than silently choosing a wall-clock winner. Assign new groups' owner membership control to the creating device. For a legacy owner group, the device already holding its protected local owner state proposes a root/device-signed authority anchor binding the group ID and accepted chain head. Imported replicas keep that anchor instead of claiming ownership. If concurrent legacy copies produce different valid anchors, preserve all copies and pause membership edits; the owner chooses the original controller in Group details, creating a signed resolution that names the conflicting anchors. Do not pick an authority from a wall-clock timestamp or silently replace an existing anchor. An already-forked membership chain remains a visible conflict; automatic fork repair is outside this release. Normal message/file sync is not held up by an unresolved authority for membership edits. Ordinary group messages/files remain available on all devices.
- Device names/presence: names are encrypted account fields. Presence is ephemeral and does not flood the durable event log.

Local history deletion barriers remain local and are checked before applying backfill. Sync must not interpret an empty device as an instruction to erase another device. Local-only preferences such as PIN, lock-on-start, file paths, notification permission and cache availability are not copied as account settings.

## Bootstrap and anti-entropy

After authenticated device discovery, exchange bounded journal summaries and request missing pages. Initial backfill exports the existing validated contacts, peer/group histories and attachment references. Apply a page transactionally, persist the receiving checkpoint, then acknowledge it. Resume after interruption without starting over, duplicating records or discarding concurrent local sends.

Use a journal epoch when durable stream state is rebuilt, with a stable event ID/dedup mapping for imported records. Bound control pages to32KiB plaintext, fragment encrypted frames using the existing16KiB transport ceiling, limit pending requests and coalesce checkpoint writes. Stream histories and files; never assemble a multi-gigabyte attachment or a whole identity snapshot in RAM.

Checkpoint/compaction must preserve removal tombstones and acknowledged sequence boundaries. A new device may request a current snapshot plus newer events; compaction cannot silently drop data required by a known offline device. Store immutable page/content hashes separately from mutable encrypted indexes, and publish the index only after the referenced pages are durable.

Offline catch-up requires at least one reachable source device or an already available user-controlled content route. No seed mailbox stores history. If all devices are offline or all usable copies of a file were deleted, recovery phrase alone cannot reconstruct that content; report unavailable and retain valid metadata.

## Attachment transfer

Sync only files referenced by an authenticated imported message/manifest. Validate size, digest, MIME/name bounds and ownership before accepting bytes. Resume verified chunks and check the complete digest. Reuse encrypted caches and ranged reads; never accept a filesystem path from another device as an instruction to open a local file.

A cache copy receipt records local availability; it is not a new delivery acknowledgement to the external conversation partner. Avoid duplicate cache imports for the same content. Pause a large transfer when Direct is lost, retain verified chunks and continue after reconnection. Historical file backfill should not block current chat or presence heartbeats.

## Profile UI

Add a concise **Devices** section:

- Device display name and platform icon/label.
- “This device” badge on the local record.
- Online/Offline status (Unknown before any authenticated observation).
- Last seen timestamp; `—` when unknown.
- A short Syncing/Waiting state where useful, distinct from Online.

Keep the list usable on a320px phone. Device details expand on a new row. Do not expose public keys, raw signaling, relay internals or private recovery data in the normal list.

## Verification and rollout

Test same-identity devices with distinct device keys; cross-root/forged-certificate/replayed-session rejection; identity lock/switch during awaits; duplicate/reordered events; concurrent profile/contact edits; local deletion versus backfill; interrupted bootstrap and partial file resume; group owner changes without forks; file corruption and missing source; presence expiry/relaunch; and multiple browser tabs.

Run real three-device synthetic tests, including one offline device returning later, and Windows/Android/WASM interoperability. Check Profile timestamps/status and that existing peer chat remains functional. Audit the public seed to prove it never receives chat/file/sync content. Use disposable identities/data and never obtain the user's PIN/phrase or send test messages to real contacts.

Old clients may continue normal peer chat but cannot sync until upgraded. Device capability negotiation must state that clearly. Preserve existing identity, contacts, chat history, groups, recovery and PIN vault formats with explicit migrations. Build and deploy only after focused protocol/security review, full checks and actual-device evidence.

## Reference

Signal's [Sesame specification](https://signal.org/docs/specifications/sesame/) explains per-user/per-device session management and multi-device fan-out. It assumes server mailboxes; this design keeps the project's user-owned data paths and does not claim Signal compatibility or implement Sesame unchanged.

## Builder check resolution

A fresh engineering check asked about concurrent legacy group authority and replacing devices at the cap. The explicit rules above resolve both as builder decisions for approval: conflict pauses owner edits rather than guessing; the cap counts live devices, not every historical installation. Offline records remain visible without consuming a live slot. No extra pairing requirement was added to the selected automatic approach.
