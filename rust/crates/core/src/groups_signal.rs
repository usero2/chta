use crate::groups::GroupEngine;
use crate::seed_signal::{MAX_SAFE_TIME, candidate, description, hex, valid_identity};
use crate::{ContactStore, IdentityManager};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const DOMAIN: &[u8] = b"chta group seed signal v1\0";
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Signal {
    version: u8,
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
impl Signal {
    fn fields(&self) -> impl Serialize + '_ {
        (
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
        )
    }
    fn payload_bytes(&self) -> Result<Vec<u8>, String> {
        let mut bytes = DOMAIN.to_vec();
        bytes.extend(serde_json::to_vec(&self.fields()).map_err(|e| e.to_string())?);
        Ok(bytes)
    }
    fn validate(&self, now: u64) -> Result<(), String> {
        if self.version != 2
            || self.topic != "groups"
            || !valid_identity(&self.from)
            || !valid_identity(&self.to)
            || self.from == self.to
            || !hex(&self.session, 32)
            || self.issued_at > MAX_SAFE_TIME
            || self.expires_at > MAX_SAFE_TIME
            || self.expires_at <= self.issued_at
            || self.expires_at - self.issued_at > 120_000
            || self.issued_at > now.saturating_add(30_000)
            || self.expires_at <= now
            || self.payload.len() > 11264
        {
            return Err("Invalid group seed envelope metadata".into());
        }
        let prefix = format!("cht-control-groups-v1-{}-{}-", self.session, self.kind);
        let counter = self
            .id
            .strip_prefix(&prefix)
            .ok_or("Invalid group signal ID")?;
        if counter.is_empty()
            || counter.len() > 20
            || !counter.bytes().all(|c| c.is_ascii_digit())
            || counter.parse::<u64>().is_err()
        {
            return Err("Invalid group signal counter".into());
        }
        let p: Value =
            serde_json::from_str(&self.payload).map_err(|_| "Invalid group signal payload")?;
        let map = p.as_object().ok_or("Invalid group signal payload")?;
        if p["v"] != 1 || p["t"] != self.kind || p["s"] != self.session {
            return Err("Invalid group signal payload metadata".into());
        }
        let valid = match self.kind.as_str() {
            "offer" | "answer" => {
                map.len() == 4
                    && p["d"]
                        .as_str()
                        .is_some_and(|d| description(d, self.kind == "offer"))
            }
            "ice" => {
                map.len() == 6
                    && p["c"].as_str().is_some_and(candidate)
                    && (p["m"].is_null()
                        || p["m"]
                            .as_str()
                            .is_some_and(|s| s.len() <= 64 && !s.contains(['\r', '\n', '\0'])))
                    && (p["l"].is_null() || p["l"].as_u64().is_some_and(|n| n <= u16::MAX as u64))
            }
            _ => false,
        };
        if !valid {
            return Err("Invalid group seed payload metadata".into());
        }
        Ok(())
    }
    fn verify(&self) -> Result<(), String> {
        let key: [u8; 32] = URL_SAFE_NO_PAD
            .decode(&self.public_key)
            .map_err(|_| "Invalid group signal key")?
            .try_into()
            .map_err(|_| "Invalid group signal key")?;
        if self.from != format!("did:cht:{:x}", Sha256::digest(key)) {
            return Err("Group signal sender key mismatch".into());
        }
        let sig: [u8; 64] = URL_SAFE_NO_PAD
            .decode(&self.signature)
            .map_err(|_| "Invalid group signal signature")?
            .try_into()
            .map_err(|_| "Invalid group signal signature")?;
        VerifyingKey::from_bytes(&key)
            .map_err(|_| "Invalid group signal key")?
            .verify_strict(&self.payload_bytes()?, &Signature::from_bytes(&sig))
            .map_err(|_| "Invalid group signal signature".into())
    }
}
pub(crate) fn call(
    engine: &mut GroupEngine,
    local: &IdentityManager,
    contacts: &ContactStore,
    op: &str,
    args: Value,
) -> Result<Value, String> {
    let map = args.as_object().ok_or("Invalid group signal arguments")?;
    let expected = if op == "signSignal" {
        ["peerId", "id", "text", "now"].as_slice()
    } else {
        ["source", "expectedPeer", "now"].as_slice()
    };
    if map.len() != expected.len() || map.keys().any(|k| !expected.contains(&k.as_str())) {
        return Err("Invalid group signal arguments".into());
    }
    let now = args["now"]
        .as_u64()
        .filter(|n| *n <= MAX_SAFE_TIME)
        .ok_or("Invalid group signal time")?;
    if op == "signSignal" {
        let peer = args["peerId"].as_str().ok_or("Invalid group signal peer")?;
        let id = args["id"].as_str().ok_or("Invalid group signal ID")?;
        let text = args["text"]
            .as_str()
            .ok_or("Invalid group signal payload")?;
        if engine
            .peer(&local.public_identity().id, contacts, peer)
            .is_none()
        {
            return Err("Unauthorized group signal peer".into());
        }
        let p: Value = serde_json::from_str(text).map_err(|_| "Invalid group signal payload")?;
        let session = p["s"].as_str().ok_or("Missing group signal session")?;
        let kind = p["t"].as_str().ok_or("Missing group signal kind")?;
        let key = local.signing_key();
        let mut signal = Signal {
            version: 2,
            topic: "groups".into(),
            from: local.public_identity().id.clone(),
            to: peer.into(),
            session: session.into(),
            id: id.into(),
            kind: kind.into(),
            payload: text.into(),
            issued_at: now,
            expires_at: now
                .checked_add(120_000)
                .filter(|n| *n <= MAX_SAFE_TIME)
                .ok_or("Invalid time")?,
            public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().to_bytes()),
            signature: String::new(),
        };
        signal.validate(now)?;
        signal.signature = URL_SAFE_NO_PAD.encode(key.sign(&signal.payload_bytes()?).to_bytes());
        let source = serde_json::to_string(&signal).map_err(|e| e.to_string())?;
        if source.len() > 16384 {
            return Err("Group signal too large".into());
        }
        Ok(json!({"source":source}))
    } else {
        let source = args["source"]
            .as_str()
            .ok_or("Invalid group signal source")?;
        let expected_peer = args["expectedPeer"]
            .as_str()
            .ok_or("Invalid expected peer")?;
        if source.len() > 16384 {
            return Err("Group signal too large".into());
        }
        let signal: Signal =
            serde_json::from_str(source).map_err(|_| "Invalid group signal schema")?;
        signal.validate(now)?;
        signal.verify()?;
        if signal.to != local.public_identity().id || signal.from != expected_peer {
            return Err("Group signal recipient or peer mismatch".into());
        }
        let identity = engine
            .peer(&local.public_identity().id, contacts, expected_peer)
            .ok_or("Unauthorized group signal peer")?;
        if identity.root_public_key != signal.public_key {
            return Err("Group signal peer key mismatch".into());
        }
        engine.signal_replays.retain(|_, expiry| *expiry > now);
        let key = (
            signal.from.clone(),
            signal.id.clone(),
            signal.signature.clone(),
        );
        if engine.signal_replays.contains_key(&key) {
            return Err("Replayed group signal".into());
        }
        if engine.signal_replays.len() >= 4096 {
            return Err("Group signal replay window full".into());
        }
        engine.signal_replays.insert(key, signal.expires_at);
        Ok(json!({"peerId":signal.from,"messageId":signal.id,"text":signal.payload}))
    }
}
