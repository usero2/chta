//! Per-connection authorization for quota-independent seed signaling.
use crate::seed_signal::{MAX_SAFE_TIME, hex, valid_identity};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SeedDispatch {
    pub version: u32,
    pub seed_id: String,
    pub connection: String,
    pub sequence: u64,
    pub envelope_hash: String,
    pub public_key: String,
    pub signature: String,
}
impl SeedDispatch {
    pub fn envelope_hash(envelope: &Value) -> Result<String, String> {
        let object = envelope.as_object().ok_or("Invalid seed envelope")?;
        let fields = [
            "version",
            "topic",
            "from",
            "to",
            "session",
            "id",
            "kind",
            "payload",
            "issuedAt",
            "expiresAt",
            "publicKey",
            "signature",
        ];
        let has_topic = object.contains_key("topic");
        if object.len() != if has_topic { 12 } else { 11 }
            || fields
                .iter()
                .any(|f| *f != "topic" && !object.contains_key(*f))
            || (has_topic
                && ![Some("contacts"), Some("groups")].contains(&envelope["topic"].as_str()))
            || envelope["version"].as_u64() != Some(if has_topic { 2 } else { 1 })
            || !envelope["from"].as_str().is_some_and(valid_identity)
            || !envelope["to"].as_str().is_some_and(valid_identity)
            || serde_json::to_vec(envelope)
                .map_err(|e| e.to_string())?
                .len()
                > 15_500
        {
            return Err("Invalid seed envelope".into());
        }
        let tuple: Vec<&Value> = fields.iter().map(|f| &envelope[*f]).collect();
        Ok(format!(
            "{:x}",
            Sha256::digest(serde_json::to_vec(&tuple).map_err(|e| e.to_string())?)
        ))
    }
    pub fn signing_payload(&self) -> Result<Vec<u8>, String> {
        let mut bytes = b"chta seed dispatch v1\0".to_vec();
        bytes.extend(
            serde_json::to_vec(&(
                self.version,
                &self.seed_id,
                &self.connection,
                self.sequence,
                &self.envelope_hash,
            ))
            .map_err(|e| e.to_string())?,
        );
        Ok(bytes)
    }
    pub fn signed(
        key: &SigningKey,
        seed_id: &str,
        connection: &str,
        sequence: u64,
        envelope: &Value,
    ) -> Result<Self, String> {
        let channel = URL_SAFE_NO_PAD
            .decode(connection)
            .map_err(|_| "Invalid seed connection")?;
        let public = key.verifying_key().to_bytes();
        if !hex(seed_id, 64)
            || channel.len() != 32
            || URL_SAFE_NO_PAD.encode(&channel) != connection
            || sequence == 0
            || sequence > MAX_SAFE_TIME
            || envelope["from"].as_str() != Some(&format!("did:cht:{:x}", Sha256::digest(public)))
            || envelope["publicKey"].as_str() != Some(&URL_SAFE_NO_PAD.encode(public))
        {
            return Err("Invalid seed dispatch binding".into());
        }
        let mut proof = Self {
            version: 1,
            seed_id: seed_id.into(),
            connection: connection.into(),
            sequence,
            envelope_hash: Self::envelope_hash(envelope)?,
            public_key: URL_SAFE_NO_PAD.encode(public),
            signature: String::new(),
        };
        proof.signature = URL_SAFE_NO_PAD.encode(key.sign(&proof.signing_payload()?).to_bytes());
        Ok(proof)
    }
}
