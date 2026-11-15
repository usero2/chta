# chta group wire v1

All group documents are UTF-8 JSON strings. Parsers reject unknown fields and enforce a 4 MiB document limit, including nested signed documents. Public export metadata is capped at 1 MiB, with at most 64 groups, 256 states per group and 1024 pending invitations. Mutating membership operations preflight these bounds and leave public state unchanged on failure. Nested identities also reject unknown fields. A signature is base64url without padding over the literal domain bytes followed by serde_json encoding of the listed tuple. Tuple fields use the order below. JSON object key order outside the signature tuple does not affect verification. Hashes are lowercase hex SHA-256. PublicIdentity has id, rootPublicKey, noiseStaticPublicKey, derivationVersion. The DID is SHA-256 of the 32-byte root key. Times are Unix milliseconds within JavaScript's safe integer range.

## Member capsule

Fields: groupId, ownerId, identity, displayName, signature. Domain: "chta group capsule v1\\0". Tuple: [groupId,ownerId,identity,displayName]. Each member signs their own capsule. This binds the member's Noise static key to a specific group and owner. Name length is 1–64 characters.

## Membership state

Fields: version:1, groupId, epoch, previousHash, name, ownerId, ownerIdentity, members, closed, issuedAt, signature. Domain: "chta group state v1\\0". Tuple: [version,groupId,epoch,previousHash,name,ownerId,ownerIdentity,members,closed,issuedAt]. The owner signs. Genesis has epoch 1, null previousHash, one owner capsule, and closed false. Every successor increments epoch by one and hashes the prior signed state reserialized by serde_json. The owner ID/key are fixed. At most 16 unique signed member capsules, including owner. A closed state has no successor. Group ID is "group:" followed by 64 lowercase hex characters.

## Invitation and receipt

Invite fields: version:1, state, states, recipientId, nonce, issuedAt, expiresAt, signature. "state" is the latest signed state JSON string and "states" is the complete ordered chain including that latest state. Domain: "chta group invite v1\\0". Tuple: [version,state,states,recipientId,nonce,issuedAt,expiresAt]. Nonce is 64 lowercase hex; expiry is exactly issuedAt + 604800000 ms. The owner signs. The recipient accepts only when that owner is a personally verified contact with the same public identity. A received invite does not itself add the recipient to membership.

Receipt fields: version:1, invite, capsule, acceptedAt, signature. Domain: "chta group receipt v1\\0". Tuple: [version,invite,capsule,acceptedAt]. The recipient signs. Acceptance time lies within the invitation's validity interval. The owner must have that exact nonce pending; add verifies the receipt, invitation chain and signature, then signs a new membership epoch. Later owner epochs may have added other recipients since the invitation was issued; the invite's chain must still match the owner's prefix.

## Group event

Fields: version:1, groupId, epoch, sender, id, kind, payload, sentAt, signature. Domain: "chta group event v1\\0". Tuple: [version,groupId,epoch,sender,id,kind,payload,sentAt]. Sender signs. Kinds: message, file, ack, leave. Payload is a JSON string, maximum 32768 UTF-8 bytes. ID is 1–128 bytes. Inspection requires sender and local identity active in the highest accepted membership and in the event epoch. This permits queued events from older epochs after unrelated additions, while removal prevents new delivery from or to a removed member.

## Group seed signal

The exact legacy v1 fields plus version:2 and topic:"groups": version, topic, from, to, session, id, kind, payload, issuedAt, expiresAt, publicKey, signature. Domain: "chta group seed signal v1\\0". Tuple: [2,"groups",from,to,session,id,kind,payload,issuedAt,expiresAt]. ID form: "cht-control-groups-v1-<32 lowercase hex session>-<kind>-<decimal counter>". Only validated SDP offers/answers and ICE fit the payload; no content. Inner payload is the existing strict Direct schema, for example {v:1,t:"ice",s:session,c:candidate,m:null,l:0}. TTL at most 120 seconds, clock skew at most 30 seconds, 4096 replay entries. v1 Direct validator rejects v2.

## Gateway behavior

groupCall(operation,args) follows the fixed table in the implementation plan. view gives {groupId,name,ownerId,epoch,closed,members:[{identityId,displayName,identity}],states:[signed JSON strings]}. list gives {groups:[view...]}. export gives {data: JSON string} containing signed public chains and pending owner invitations; import validates every signature and exact chain, rejecting rollback or forks. No private keys or Noise session state are exported.

authorize(peerId) admits a personally verified friend or active common group member and returns {allowed:true,identity}; otherwise {allowed:false}. With groupId, both local and peer must be active in the latest state. With epoch, both must additionally have been members at that epoch. Group-specific send, request, and piece-service callers must pass group ID and, for historical files, upload epoch.

prepare creates an independent Noise KK session keyed by context, peer DID and 32 lowercase hex session ID. The optional context defaults to groups; dm-v2 requires a personally verified friend and uses the distinct prologue "chta direct message noise v2\0<sessionId>". Its prologue is "chta group noise v1\\0<sessionId>"; the legacy direct session is untouched. Registry caps: 64 group sessions and 16 dm-v2 sessions. The authenticated message ID duplicate window is bounded to 4096 entries. Receiving a new handshake must not replace an authenticated session until the candidate independently authenticates. encrypt accepts at most 32768 UTF-8 bytes; decrypt rejects decoded frames over 65535 bytes. Noise counters are serialized in Rust per session.

## Local delivery persistence

Controllers retain at most 10,000 messages per room and an outbox of 1024 jobs / 16 MiB encoded control data. Recipient jobs and room pages are written before the index commits the new message; a failed commit retains the composer draft. Group metadata travels in bounded encrypted fragments. File bytes use member-to-member Noise channels and encrypted sparse caches; the public seed accepts only signed discovery and WebRTC setup metadata.
