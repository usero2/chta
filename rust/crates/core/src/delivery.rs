//! Immutable, forwardable author proof. Acceptance and group membership stay with the caller.
use crate::seed_signal::{MAX_SAFE_TIME, hex, valid_identity};
use crate::{ContactStore, IdentityManager};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use ed25519_dalek::Signer;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(crate) fn digest(bytes: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub(crate) fn parse<T: DeserializeOwned>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|_| "Invalid delivery schema".into())
}
pub(crate) fn canonical(domain: &[u8], value: &impl Serialize) -> Result<Vec<u8>, String> {
    let mut b = domain.to_vec();
    b.extend(serde_json::to_vec(value).map_err(|_| "Invalid delivery metadata")?);
    Ok(b)
}
pub(crate) fn valid_scope(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && s.bytes().all(|b| (33..=126).contains(&b))
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DeliveryEvent {
    pub version: u32,
    pub author_id: String,
    pub scope: String,
    pub message_id: String,
    pub sent_at: u64,
    pub kind: String,
    pub payload_hash: String,
    pub public_key: String,
    pub signature: String,
}
impl DeliveryEvent {
    fn payload(&self) -> Result<Vec<u8>, String> {
        canonical(
            b"chta delivery event v1\0",
            &(
                self.version,
                &self.author_id,
                &self.scope,
                &self.message_id,
                self.sent_at,
                &self.kind,
                &self.payload_hash,
                &self.public_key,
            ),
        )
    }
    pub(crate) fn verify(&self, now: u64) -> Result<(), String> {
        if self.version != 1
            || !valid_identity(&self.author_id)
            || !valid_scope(&self.scope)
            || self.message_id.is_empty()
            || self.message_id.len() > 256
            || !self.message_id.bytes().all(|b| (33..=126).contains(&b))
            || now > MAX_SAFE_TIME
            || self.sent_at > MAX_SAFE_TIME
            || self.sent_at > now.saturating_add(300000)
            || !["text", "image", "video", "audio", "file", "group"].contains(&self.kind.as_str())
            || !hex(&self.payload_hash, 64)
        {
            return Err("Invalid delivery event".into());
        }
        let key = crate::courier::decode::<32>(&self.public_key)?;
        if self.author_id != format!("did:cht:{}", digest(key)) {
            return Err("Delivery author mismatch".into());
        }
        crate::device_sync::certificate::verify_signature(
            &self.public_key,
            &self.signature,
            &self.payload()?,
        )
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SignArgs {
    scope: String,
    message_id: String,
    sent_at: u64,
    kind: String,
    payload: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct VerifyArgs {
    event: DeliveryEvent,
    expected_author: String,
    scope: String,
    payload: String,
    now: u64,
}
pub(crate) fn call(
    identity: &IdentityManager,
    contacts: &ContactStore,
    groups: &crate::groups::GroupEngine,
    operation: &str,
    args: Value,
) -> Result<Value, String> {
    if serde_json::to_vec(&args)
        .map_err(|_| "Invalid delivery arguments")?
        .len()
        > 4 * 1024 * 1024
    {
        return Err("Delivery arguments too large".into());
    }
    match operation {
        "signEvent" => {
            let a: SignArgs = parse(args)?;
            if a.payload.len() > 32768 {
                return Err("Delivery payload too large".into());
            }
            let mut event = DeliveryEvent {
                version: 1,
                author_id: identity.public_identity().id.clone(),
                scope: a.scope,
                message_id: a.message_id,
                sent_at: a.sent_at,
                kind: a.kind,
                payload_hash: digest(a.payload.as_bytes()),
                public_key: identity.public_identity().root_public_key.clone(),
                signature: String::new(),
            };
            event.signature = B64.encode(identity.signing_key().sign(&event.payload()?).to_bytes());
            event.verify(event.sent_at)?;
            serde_json::to_value(event).map_err(|_| "Invalid delivery event".into())
        }
        "verifyEvent" => {
            let a: VerifyArgs = parse(args)?;
            if a.payload.len() > 32768
                || a.event.author_id != a.expected_author
                || a.event.scope != a.scope
                || a.event.payload_hash != digest(a.payload.as_bytes())
            {
                return Err("Delivery content mismatch".into());
            }
            a.event.verify(a.now)?;
            Ok(
                json!({"messageId":a.event.message_id,"sentAt":a.event.sent_at,"authorId":a.event.author_id,"kind":a.event.kind,"payloadHash":a.event.payload_hash}),
            )
        }
        _ => crate::courier::call(identity, contacts, groups, operation, args),
    }
}
