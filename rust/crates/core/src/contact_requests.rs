//! Signed, recipient-sealed contact setup. This API cannot carry chat content.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::seed_signal::{MAX_SAFE_TIME, hex, valid_identity};
use crate::{ContactStore, IdentityManager};

const SIGN_CONTEXT: &[u8] = b"chta contact request signal v1\0";
const BOX_CONTEXT: &[u8] = b"chta/contact-request/box/v1\0";
const PATTERN: &str = "Noise_IK_25519_ChaChaPoly_SHA256";
const MAX_CARD: usize = 8192;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Envelope {
    version: u32,
    topic: String,
    from: String,
    to: String,
    session: String,
    id: String,
    kind: String,
    payload: String,
    issued_at: u64,
    expires_at: u64,
    public_key: String,
    signature: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    v: u32,
    t: String,
    s: String,
    #[serde(rename = "box")]
    sealed: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SealArgs {
    peer_card: String,
    request_id: String,
    kind: String,
    now: u64,
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    avatar: String,
    #[serde(default)]
    relay_urls: Vec<String>,
}

fn key32(text: &str) -> Result<[u8; 32], String> {
    let bytes = URL_SAFE_NO_PAD
        .decode(text)
        .map_err(|_| "Invalid setup key")?;
    if URL_SAFE_NO_PAD.encode(&bytes) != text {
        return Err("Noncanonical setup key".into());
    }
    bytes
        .try_into()
        .map_err(|_| "Invalid setup key length".into())
}
fn kind(value: &str) -> bool {
    ["request", "received", "accepted", "declined"].contains(&value)
}

impl Envelope {
    fn signed_bytes(&self) -> Result<Vec<u8>, String> {
        let mut bytes = SIGN_CONTEXT.to_vec();
        bytes.extend(
            serde_json::to_vec(&(
                self.version,
                &self.topic,
                &self.from,
                &self.to,
                &self.session,
                &self.id,
                &self.kind,
                &self.payload,
                self.issued_at,
                self.expires_at,
            ))
            .map_err(|e| e.to_string())?,
        );
        Ok(bytes)
    }
    fn prologue(&self) -> Result<Vec<u8>, String> {
        let mut bytes = BOX_CONTEXT.to_vec();
        bytes.extend(
            serde_json::to_vec(&(
                self.version,
                &self.topic,
                &self.from,
                &self.to,
                &self.session,
                &self.id,
                &self.kind,
                self.issued_at,
                self.expires_at,
            ))
            .map_err(|e| e.to_string())?,
        );
        Ok(bytes)
    }
    fn validate(&self, now: u64) -> Result<Payload, String> {
        let prefix = format!("cht-contact-request-v1-{}-{}-", self.session, self.kind);
        if self.version != 2
            || self.topic != "contacts"
            || !kind(&self.kind)
            || !valid_identity(&self.from)
            || !valid_identity(&self.to)
            || self.from == self.to
            || !hex(&self.session, 32)
            || !self.id.strip_prefix(&prefix).is_some_and(|v| hex(v, 32))
            || now > MAX_SAFE_TIME
            || self.issued_at > MAX_SAFE_TIME
            || self.expires_at > MAX_SAFE_TIME
            || self.issued_at > now.saturating_add(30_000)
            || self.expires_at <= now
            || self.expires_at <= self.issued_at
            || self.expires_at - self.issued_at > 120_000
            || self.payload.len() > 11264
        {
            return Err("Invalid contact request envelope".into());
        }
        let payload: Payload =
            serde_json::from_str(&self.payload).map_err(|_| "Invalid contact setup schema")?;
        if payload.v != 1
            || payload.t != self.kind
            || payload.s != self.session
            || payload.sealed.len() < 128
            || payload.sealed.len() > 11052
            || !payload
                .sealed
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err("Invalid sealed contact payload".into());
        }
        Ok(payload)
    }
}

fn seal(identity: &IdentityManager, args: SealArgs) -> Result<Value, String> {
    if args.peer_card.len() > MAX_CARD
        || !hex(&args.request_id, 32)
        || !kind(&args.kind)
        || args.now > MAX_SAFE_TIME - 120_000
    {
        return Err("Invalid contact request arguments".into());
    }
    let peer = ContactStore::verify_card(&args.peer_card).map_err(|e| e.to_string())?;
    let own = identity
        .contact_card_with_relays(&args.display_name, &args.avatar, &args.relay_urls)
        .map_err(|e| e.to_string())?;
    let card = Zeroizing::new(own.to_json().map_err(|e| e.to_string())?.into_bytes());
    if card.len() > MAX_CARD {
        return Err("Contact card is too large".into());
    }
    let mut nonce = [0u8; 16];
    getrandom::fill(&mut nonce).map_err(|_| "Secure random source unavailable")?;
    let nonce: String = nonce.iter().map(|v| format!("{v:02x}")).collect();
    let signing = identity.signing_key();
    let mut envelope = Envelope {
        version: 2,
        topic: "contacts".into(),
        from: own.identity.id.clone(),
        to: peer.identity_id.clone(),
        session: args.request_id.clone(),
        id: format!(
            "cht-contact-request-v1-{}-{}-{nonce}",
            args.request_id, args.kind
        ),
        kind: args.kind,
        payload: String::new(),
        issued_at: args.now,
        expires_at: args.now + 120_000,
        public_key: URL_SAFE_NO_PAD.encode(signing.verifying_key().to_bytes()),
        signature: String::new(),
    };
    let private = Zeroizing::new(identity.noise_static_secret().to_bytes());
    let remote = key32(&peer.card.identity.noise_static_public_key)?;
    let prologue = envelope.prologue()?;
    let params = PATTERN.parse().map_err(|e: snow::Error| e.to_string())?;
    let mut handshake = snow::Builder::new(params)
        .prologue(&prologue)
        .and_then(|b| b.local_private_key(&*private))
        .and_then(|b| b.remote_public_key(&remote))
        .and_then(|b| b.build_initiator())
        .map_err(|e| e.to_string())?;
    let mut output = vec![0u8; MAX_CARD + 96];
    let written = handshake
        .write_message(&card, &mut output)
        .map_err(|_| "Could not seal contact request")?;
    output.truncate(written);
    envelope.payload = serde_json::to_string(&Payload {
        v: 1,
        t: envelope.kind.clone(),
        s: envelope.session.clone(),
        sealed: URL_SAFE_NO_PAD.encode(output),
    })
    .map_err(|e| e.to_string())?;
    envelope.validate(args.now)?;
    envelope.signature = URL_SAFE_NO_PAD.encode(signing.sign(&envelope.signed_bytes()?).to_bytes());
    let value = serde_json::to_value(&envelope).map_err(|e| e.to_string())?;
    if serde_json::to_vec(&value).map_err(|e| e.to_string())?.len() > 16384 {
        return Err("Contact envelope too large".into());
    }
    Ok(json!({"envelope":value}))
}

fn inspect(
    identity: &IdentityManager,
    contacts: &ContactStore,
    source: &str,
    now: u64,
) -> Result<Value, String> {
    if source.len() > 16384 {
        return Err("Contact envelope too large".into());
    }
    let envelope: Envelope =
        serde_json::from_str(source).map_err(|_| "Invalid contact envelope schema")?;
    let payload = envelope.validate(now)?;
    if envelope.to != identity.public_identity().id {
        return Err("Wrong contact request recipient".into());
    }
    let public = key32(&envelope.public_key)?;
    if envelope.from != format!("did:cht:{:x}", Sha256::digest(public)) {
        return Err("Contact request signer mismatch".into());
    }
    let signature: [u8; 64] = URL_SAFE_NO_PAD
        .decode(&envelope.signature)
        .map_err(|_| "Invalid contact signature")?
        .try_into()
        .map_err(|_| "Invalid contact signature length")?;
    VerifyingKey::from_bytes(&public)
        .map_err(|_| "Invalid contact signing key")?
        .verify_strict(
            &envelope.signed_bytes()?,
            &Signature::from_bytes(&signature),
        )
        .map_err(|_| "Invalid contact signature")?;
    let ciphertext = URL_SAFE_NO_PAD
        .decode(&payload.sealed)
        .map_err(|_| "Invalid sealed contact encoding")?;
    if URL_SAFE_NO_PAD.encode(&ciphertext) != payload.sealed || ciphertext.len() > MAX_CARD + 96 {
        return Err("Invalid sealed contact encoding".into());
    }
    let private = Zeroizing::new(identity.noise_static_secret().to_bytes());
    let prologue = envelope.prologue()?;
    let params = PATTERN.parse().map_err(|e: snow::Error| e.to_string())?;
    let mut handshake = snow::Builder::new(params)
        .prologue(&prologue)
        .and_then(|b| b.local_private_key(&*private))
        .and_then(|b| b.build_responder())
        .map_err(|e| e.to_string())?;
    let mut plaintext = Zeroizing::new(vec![0u8; MAX_CARD]);
    let written = handshake
        .read_message(&ciphertext, &mut plaintext)
        .map_err(|_| "Could not open contact request")?;
    let card_json =
        std::str::from_utf8(&plaintext[..written]).map_err(|_| "Invalid contact card encoding")?;
    let card = ContactStore::verify_card(card_json).map_err(|e| e.to_string())?;
    let remote_static = key32(&card.card.identity.noise_static_public_key)?;
    if card.identity_id != envelope.from
        || card.card.identity.root_public_key != envelope.public_key
        || handshake.get_remote_static() != Some(remote_static.as_slice())
    {
        return Err("Contact request card or static key mismatch".into());
    }
    if let Ok(known) = contacts.verified_contact(&card.identity_id) {
        if known.card.identity != card.card.identity {
            return Err("Saved contact keys changed".into());
        }
    }
    Ok(
        json!({"peerId":card.identity_id,"requestId":envelope.session,"kind":envelope.kind,
        "packetId":envelope.id,"cardJson":card.card.to_json().map_err(|e| e.to_string())?,"contact":card}),
    )
}

pub(crate) fn call(
    identity: &IdentityManager,
    contacts: &ContactStore,
    operation: &str,
    args: Value,
) -> Result<Value, String> {
    if serde_json::to_vec(&args).map_err(|e| e.to_string())?.len() > 32768 {
        return Err("Contact setup arguments too large".into());
    }
    match operation {
        "seal" => seal(
            identity,
            serde_json::from_value(args).map_err(|_| "Invalid contact seal arguments")?,
        ),
        "inspect" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Args {
                source: String,
                now: u64,
            }
            let args: Args =
                serde_json::from_value(args).map_err(|_| "Invalid contact inspect arguments")?;
            inspect(identity, contacts, &args.source, args.now)
        }
        "peer" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase", deny_unknown_fields)]
            struct Args {
                peer_id: String,
            }
            let args: Args =
                serde_json::from_value(args).map_err(|_| "Invalid contact peer arguments")?;
            let peer = contacts
                .list()
                .into_iter()
                .find(|c| c.identity_id == args.peer_id)
                .ok_or("Contact not found")?;
            Ok(json!({"cardJson":peer.card.to_json().map_err(|e| e.to_string())?}))
        }
        _ => Err("Unknown contact request operation".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const NOW: u64 = 1_800_000_000_000;
    fn args(peer: &IdentityManager, kind: &str) -> SealArgs {
        SealArgs {
            peer_card: peer.contact_card().unwrap().to_json().unwrap(),
            request_id: "0123456789abcdef0123456789abcdef".into(),
            kind: kind.into(),
            now: NOW,
            display_name: "Synthetic request sender".into(),
            avatar: String::new(),
            relay_urls: vec![],
        }
    }
    #[test]
    fn sealed_request_response_kinds_and_fresh_retry_need_no_saved_handshake() {
        let a = IdentityManager::create().unwrap();
        let b = IdentityManager::create().unwrap();
        let store = ContactStore::default();
        for kind in ["request", "received", "accepted", "declined"] {
            let value = seal(&a, args(&b, kind)).unwrap();
            let source = value["envelope"].to_string();
            let opened = inspect(&b, &store, &source, NOW).unwrap();
            assert_eq!(opened["kind"], kind);
            assert_eq!(opened["contact"]["displayName"], "Synthetic request sender");
            assert_eq!(store.list().len(), 0);
            assert!(!source.contains("Synthetic request sender"));
            let retry = seal(&a, args(&b, kind)).unwrap();
            assert_eq!(value["envelope"]["session"], retry["envelope"]["session"]);
            assert_ne!(value["envelope"]["id"], retry["envelope"]["id"]);
            assert_ne!(value["envelope"]["payload"], retry["envelope"]["payload"]);
            if kind == "request" {
                if let Ok(path) = std::env::var("CHTA_CONTACT_FIXTURE_OUT") {
                    let envelope = &value["envelope"];
                    let parsed: Envelope = serde_json::from_value(envelope.clone()).unwrap();
                    std::fs::write(
                        path,
                        serde_json::to_vec_pretty(&json!({
                            "now":NOW,"envelope":envelope,
                            "canonical":String::from_utf8(parsed.signed_bytes().unwrap()).unwrap(),
                        }))
                        .unwrap(),
                    )
                    .unwrap();
                }
            }
        }
    }
    #[test]
    fn setup_rejects_arbitrary_content_metadata_and_protocol_confusion() {
        let a = IdentityManager::create().unwrap();
        let b = IdentityManager::create().unwrap();
        let source = seal(&a, args(&b, "request")).unwrap()["envelope"].clone();
        for (field, value) in [
            ("version", json!(1)),
            ("topic", json!("groups")),
            ("kind", json!("message")),
            ("session", json!("A".repeat(32))),
            ("issuedAt", json!(NOW + 30001)),
            ("expiresAt", json!(NOW + 120001)),
            ("extra", json!("content")),
        ] {
            let mut bad = source.clone();
            bad[field] = value;
            assert!(
                inspect(&b, &ContactStore::default(), &bad.to_string(), NOW).is_err(),
                "{field}"
            );
        }
        let mut bad_args=serde_json::to_value(json!({"peerCard":args(&b,"request").peer_card,"requestId":"a".repeat(32),"kind":"request","now":NOW})).unwrap();
        bad_args["text"] = json!("not allowed");
        assert!(call(&a, &ContactStore::default(), "seal", bad_args).is_err());
        assert!(seal(&a, args(&a, "request")).is_err());
        assert!(
            inspect(
                &b,
                &ContactStore::default(),
                &source.to_string(),
                NOW + 120000
            )
            .is_err()
        );
    }
    #[test]
    fn encrypted_static_and_card_must_match_the_outer_root_signer() {
        let a = IdentityManager::create().unwrap();
        let b = IdentityManager::create().unwrap();
        let c = IdentityManager::create().unwrap();
        for (static_owner, card_owner) in [(&c, &a), (&a, &c)] {
            let value = seal(&a, args(&b, "request")).unwrap();
            let mut envelope: Envelope = serde_json::from_value(value["envelope"].clone()).unwrap();
            let prologue = envelope.prologue().unwrap();
            let private = static_owner.noise_static_secret().to_bytes();
            let remote = key32(&b.public_identity().noise_static_public_key).unwrap();
            let mut state = snow::Builder::new(PATTERN.parse().unwrap())
                .prologue(&prologue)
                .unwrap()
                .local_private_key(&private)
                .unwrap()
                .remote_public_key(&remote)
                .unwrap()
                .build_initiator()
                .unwrap();
            let card = card_owner.contact_card().unwrap().to_json().unwrap();
            let mut output = vec![0u8; MAX_CARD + 96];
            let len = state.write_message(card.as_bytes(), &mut output).unwrap();
            output.truncate(len);
            envelope.payload = serde_json::to_string(&Payload {
                v: 1,
                t: "request".into(),
                s: envelope.session.clone(),
                sealed: URL_SAFE_NO_PAD.encode(output),
            })
            .unwrap();
            envelope.signature = URL_SAFE_NO_PAD.encode(
                a.signing_key()
                    .sign(&envelope.signed_bytes().unwrap())
                    .to_bytes(),
            );
            assert!(
                inspect(
                    &b,
                    &ContactStore::default(),
                    &serde_json::to_string(&envelope).unwrap(),
                    NOW
                )
                .is_err()
            );
        }
    }
}
