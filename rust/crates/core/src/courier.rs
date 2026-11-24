//! Endpoint-only keys and authenticated opaque Courier packages.
mod node;
mod packages;
use crate::delivery::canonical;
use crate::{ContactStore, IdentityManager};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::Value;
use zeroize::Zeroizing;

pub(crate) fn random<const N: usize>() -> Result<[u8; N], String> {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).map_err(|_| "Secure randomness unavailable")?;
    Ok(b)
}
pub(crate) fn decode<const N: usize>(s: &str) -> Result<[u8; N], String> {
    decode_bytes(s, N)?
        .try_into()
        .map_err(|_| "Invalid Courier key length".into())
}
pub(crate) fn decode_bytes(s: &str, max: usize) -> Result<Vec<u8>, String> {
    if s.len() > max.div_ceil(3) * 4 {
        return Err("Courier data too large".into());
    }
    let bytes = B64.decode(s).map_err(|_| "Invalid Courier encoding")?;
    if bytes.len() > max || B64.encode(&bytes) != s {
        return Err("Invalid Courier encoding".into());
    }
    Ok(bytes)
}
fn state_key(identity: &IdentityManager) -> Result<Zeroizing<[u8; 32]>, String> {
    let private = Zeroizing::new(identity.noise_static_secret().to_bytes());
    let mut key = Zeroizing::new([0u8; 32]);
    hkdf::Hkdf::<sha2::Sha256>::new(Some(b"chta courier private state v1"), &*private)
        .expand(identity.public_identity().id.as_bytes(), &mut *key)
        .map_err(|_| "Courier key unavailable")?;
    Ok(key)
}
pub(crate) fn seal_state(
    identity: &IdentityManager,
    role: &str,
    state: &impl Serialize,
) -> Result<String, String> {
    let key = state_key(identity)?;
    let nonce = random::<24>()?;
    let plain = Zeroizing::new(serde_json::to_vec(state).map_err(|_| "Invalid Courier state")?);
    if plain.len() > 4096 {
        return Err("Courier state too large".into());
    }
    let aad = canonical(
        b"chta courier private state v1\0",
        &(role, &identity.public_identity().id),
    )?;
    let ciphertext = XChaCha20Poly1305::new_from_slice(&*key)
        .map_err(|_| "Courier key unavailable")?
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &plain,
                aad: &aad,
            },
        )
        .map_err(|_| "Could not protect Courier state")?;
    Ok(B64.encode([nonce.as_slice(), ciphertext.as_slice()].concat()))
}
pub(crate) fn open_state<T: DeserializeOwned>(
    identity: &IdentityManager,
    role: &str,
    state: &str,
) -> Result<T, String> {
    let bytes = decode_bytes(state, 4136)?;
    if bytes.len() < 40 {
        return Err("Invalid protected Courier state".into());
    }
    let key = state_key(identity)?;
    let aad = canonical(
        b"chta courier private state v1\0",
        &(role, &identity.public_identity().id),
    )?;
    let plain = Zeroizing::new(
        XChaCha20Poly1305::new_from_slice(&*key)
            .map_err(|_| "Courier key unavailable")?
            .decrypt(
                XNonce::from_slice(&bytes[..24]),
                Payload {
                    msg: &bytes[24..],
                    aad: &aad,
                },
            )
            .map_err(|_| "Could not unlock Courier state")?,
    );
    serde_json::from_slice(&plain).map_err(|_| "Invalid protected Courier state".into())
}
pub(crate) fn call(
    identity: &IdentityManager,
    contacts: &ContactStore,
    groups: &crate::groups::GroupEngine,
    operation: &str,
    args: Value,
) -> Result<Value, String> {
    match operation {
        "nodeCertificate" | "verifyNode" | "signControl" | "verifyControl" => {
            node::call(identity, operation, args)
        }
        "verifyPackage" | "inspectManifest" | "newJob" | "mailbox" | "encryptPackage"
        | "decryptPackage" | "packageRoot" | "sealManifest" | "openManifest" => {
            packages::call(identity, contacts, groups, operation, args)
        }
        _ => Err("Unknown delivery operation".into()),
    }
}
