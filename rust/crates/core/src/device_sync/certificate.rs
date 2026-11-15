use super::*;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceCertificate {
    pub version: u32,
    pub owner_id: String,
    pub root_public_key: String,
    pub device_id: String,
    pub signing_public_key: String,
    pub noise_public_key: String,
    pub created_at: u64,
    pub signature: String,
}

impl DeviceCertificate {
    pub(crate) fn payload(&self) -> Result<Vec<u8>, String> {
        canonical(
            b"chta device certificate v1\0",
            &json!([
                self.version,
                self.owner_id,
                self.root_public_key,
                self.device_id,
                self.signing_public_key,
                self.noise_public_key,
                self.created_at
            ]),
        )
    }
    pub fn verify(&self, expected_owner: &str) -> Result<(), String> {
        let root = decode::<32>(&self.root_public_key)?;
        if self.version != 1
            || self.owner_id != expected_owner
            || self.owner_id != format!("did:cht:{:x}", Sha256::digest(root))
            || !crate::seed_signal::hex(&self.device_id, 32)
            || self.created_at > MAX_TIME
            || decode::<32>(&self.noise_public_key)? == [0; 32]
        {
            return Err("Invalid device certificate".into());
        }
        VerifyingKey::from_bytes(&decode::<32>(&self.signing_public_key)?)
            .map_err(|_| "Invalid device signing key")?;
        verify_signature(&self.root_public_key, &self.signature, &self.payload()?)
    }
}

pub(crate) fn decode<const N: usize>(text: &str) -> Result<[u8; N], String> {
    let bytes = URL_SAFE_NO_PAD
        .decode(text)
        .map_err(|_| "Invalid base64url")?;
    if URL_SAFE_NO_PAD.encode(&bytes) != text {
        return Err("Noncanonical base64url".into());
    }
    bytes
        .try_into()
        .map_err(|_| "Invalid key/signature length".into())
}
pub(crate) fn verify_signature(
    public: &str,
    signature: &str,
    payload: &[u8],
) -> Result<(), String> {
    VerifyingKey::from_bytes(&decode::<32>(public)?)
        .map_err(|_| "Invalid public key")?
        .verify_strict(payload, &Signature::from_bytes(&decode::<64>(signature)?))
        .map_err(|_| "Invalid device signature".into())
}
