# chta: chat actions, encrypted groups and private file swarms

Status: approved by the user on 2026-11-15. Implementation follows the linked plan.

## User request

Add a floating chat menu with delete and contact details. Add a plus button on the same row as `chta` to create groups. Group files must use BitTorrent-style multi-source pieces **only among authorized encrypted group members**, as explicitly confirmed on 2026-11-15. Existing 1:1 chats, media previews, Markdown, timestamps, notifications, encrypted history and Direct/relay file limits remain available.

## Approach

Use private piece swarming over chta's authenticated peer channels. This reuses chta identity and avoids public trackers, magnets and DHT publication. A public BitTorrent client would expose group activity and require another access-control layer; sending a separate complete file to every member would not satisfy multi-source swarming. Neither alternative is selected.

Use pairwise Noise-encrypted channels and authenticated WebRTC DTLS for delivery, with purpose-bound Ed25519 signatures on membership documents, messages and file manifests. This is an implementation choice, not a claim that the user selected a new cryptographic protocol. Reuse the existing evaluated libraries; do not invent a group cipher. A later MLS migration is outside this change.

## Screens and actions

- The chat list header shows `chta` at left and `＋` at right on mobile and wide layouts. `＋` opens **New group**: name and verified friends, then Create.
- Creation and received group invitations appear without navigating away to Connect. An invitation names the owner and participants. Recipients explicitly Accept or Decline; no silent group enrollment.
- A group uses the existing chat layout, with group name, member avatars/names, sender names above incoming messages, media attachments and a per-message delivery count. Open groups keep working while viewing a different room.
- The floating menu in a friend chat contains **Contact details** and **Delete chat**. Details opens a sheet with avatar, signed name, local alias, fingerprint and DID. In a group the corresponding item is **Group details**, with members and owner controls.
- Delete asks once in a confirmation dialog, then clears that room's local history and pending sends, preserving the friend/group membership and the other participant's copy. It is not a leave-group action. Already received files in the encrypted cache may remain until cache cleanup; the dialog must not claim secure erasure.
- Group details offers add/remove members to the creator and Leave to each member. Leaving stops future sends/downloads and deletes local pending work; it cannot retract content already received by others.
- Group URLs use `/chats/group:<opaque-id>` and the existing `/chat/` mount on chta.app. Reload restores the same group and encrypted history. Older versions must show an unsupported invitation rather than misread it as a direct-message file.

## Membership and identity

The creator is the single membership authority for this version. A random 256-bit group ID identifies a genesis owner-signed document. Each successor has an increasing epoch, previous-document hash, group name, owner DID/public key and at most **16 members including the creator**. The initial limit is a builder choice to bound concurrent mobile connections; exceeding it is a clear validation error, not silent omission.

Membership contains signed public identity/contact material sufficient to authenticate member-to-member links. Being in a group does not mark a new member as a personally verified friend. Invites are owner-signed, recipient-bound, expiring and replay-safe; an invite is accepted only from an already verified friend. The owner persists invite/outbox state and retransmits when that friend becomes available.

Invitation delivery has its own background bootstrap channel, authorized only for already verified friends. It can send/receive invitation documents before a group is accepted, without borrowing the selected direct-message session. Invitees are not active members yet and receive no group content. Accept signs a recipient receipt; when the owner is online it automatically validates that receipt and publishes the epoch adding the member. Until then the screen shows **Waiting for group owner**. Pending invitations reserve slots within the 16-person limit. Decline/expiry grants no access. After joining, a separate group-session constructor authenticates members against signed membership rather than the personal-friend verification gate.

Only the owner can publish new membership epochs. Validate owner, signatures, epoch/hash chain, recipient and exact allowed fields before accepting changes. Hold unknown future epochs until their signed chain arrives. Reject rollback, conflicting chains, forged invites and non-member requests. On link establishment peers exchange their highest known epoch/hash and apply any valid newer chain before sending. If no newer signed state is available they may continue at their locally accepted epoch. Immediate revocation on a disconnected machine is impossible. Peers that have learned and accepted removal stop sends, piece service and outstanding requests involving that member. Previously received plaintext and old-epoch traffic between stale partitioned peers cannot be revoked.

## Transport and persistence

The current AccountCore, RelayChat and file controller hold one selected peer. Add a bounded group-specific peer-session registry, independent of that legacy direct-message session. Serialize Noise counters per session. UI selection must not reset background group sessions or mutate the 1:1 crypto session.

Keep group signaling distinct from direct-message signaling: purpose-bound signed `groups` topic, validated SDP/ICE only, receiver authentication against accepted group membership. Do not encode group chat, invitations, file names or pieces into the public seed channel. The existing seed remains discovery-only. Full invitations and membership documents travel over authenticated content channels to verified friends. Use a dedicated group link shared across accepted groups for the same peer, rather than one connection per group.

This requires a new signed schema and peer-indexed seed client; the current selected-peer v1 client is not sufficient. Reject group signals in the legacy direct-message validator and direct-message signals in the group validator. A shared relay-frame dispatcher routes by authenticated peer and protocol so neither group service nor RelayChat can replace the other's sole callback.

Prefer Direct. Use existing community `/cht` data relays for encrypted group events and small-file pieces when Direct is unavailable. Never treat `/relay` on chta.app as a content route. Bind all events to group ID, membership epoch, sender, event ID and timestamp. Verify signatures, deduplicate, acknowledge per recipient and persist the outbox for offline members. A delivery count means recipient acknowledgement, not read receipt. Restore encrypted membership/history/outbox under the active identity, with generation guards on lock, identity switch and asynchronous callbacks.

## Private file swarm

The existing contiguous-prefix file cache cannot support disjoint pieces; introduce a separate sparse encrypted cache on native and Web, leaving the 1:1 transfer format compatible.

- Import files by streaming; never buffer a large file in full. Immutable uploader-signed manifests bind file ID, group/epoch, display metadata, exact size, piece size, whole-file SHA-256 and a Merkle root.
- Use **256 KiB pieces**, split into bounded **8 KiB wire parts**. Merkle proofs bind piece index and expected size, so a malicious member cannot substitute a piece or a whole hash list. Persist a piece and advertise its availability only after verification.
- Persist the verified-piece bitmap; serve verified pieces while the remainder is incomplete. Restart resumes missing pieces, not a contiguous-prefix assumption. Bind cache encryption to local owner, group, file and piece index.
- Request pieces from several authorized online members, prefer rare missing pieces, bound concurrent requests and memory, time out stalled sources and try another. Reject corrupt pieces, duplicates, unauthorized requests and stale membership. Show total progress plus active source count.
- Preserve current limits: files through a content relay up to **25 MiB per file**; **Direct up to 10 GiB**. A larger file waits for a Direct source and states that clearly. No bulk content goes through the seed. Final whole-file SHA-256 must match before opening/exporting as complete.
- Members with cached pieces can help other members automatically while their app is unlocked and online. Android process suspension and unavailable peers still interrupt progress; there is no always-online promise or server copy.

Authorize both requester and source against the highest locally accepted membership on every transfer operation, including after restart; the requester must also have been active in the manifest's signed epoch. New members do not automatically gain old files. The uploader can explicitly re-share with a new file ID and manifest in the current epoch. Retaining cached old pieces never overrides membership checks. Each cache record binds owner/group/uploader/file/manifest hash and upload epoch independently of any source connection.

Parser/allocation bounds: at most 40,960 pieces, 16 Merkle proof levels with deterministic power-of-two padding, 32 parts per piece, eight in-flight piece assemblies globally from at most four sources, at most two assemblies per source, and 16 KiB per control/wire frame. Exact expected part and last-piece lengths are checked before allocation/write. The manifest contains the Merkle root, not an unbounded per-piece hash list. Completion requires every piece proof plus final whole-file digest.

## Acceptance evidence

1. Existing direct-message tests and mounted routes pass unchanged; simultaneous group and 1:1 traffic does not reset either session.
2. Three synthetic identities create/accept a group and exchange signed encrypted text, Markdown and media. History survives restart and selection changes; notifications identify the group/sender.
3. Four synthetic identities A/B/C/D are authorized. A uploads a multi-piece file; B and C retain complementary verified pieces. Disconnect A completely. D downloads pieces from **both B and C**, restarts mid-transfer, resumes, and finishes with the original SHA-256. Also test B/C cross-filling with only three identities.
4. Reject outsider, removed-member, forged owner/manifest/invite, replay, wrong group/epoch, corrupt piece and rollback. Test native and browser sparse storage and interrupted relay/Direct transitions.
5. Exercise mobile and wide layouts, plus/create, contact/group details and local deletion; never delete or send through a user's real conversations during QA.
6. Build and install Android and one-file Windows release after review; rebuild the hosted Web app. Report any incomplete platform proof explicitly.

## Work order

Finish the already reviewed homepage/seed and single-exe release first. Then implement chat actions; membership/peer crypto; background group transport/history/UI; sparse cache and swarm; final cross-platform tests/builds. Group code starts after this document is approved. Public Cloudflare seed deployment is already authorized separately.
