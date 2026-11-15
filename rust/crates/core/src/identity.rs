use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bip39::{Language, Mnemonic};
use ed25519_dalek::SigningKey;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

const DERIVATION_VERSION: u32 = 1;
const DERIVATION_SALT: &[u8] = b"cht identity derivation v1";
const ROOT_SIGNING_INFO: &[u8] = b"cht/root-ed25519/v1";
const NOISE_STATIC_INFO: &[u8] = b"cht/noise-x25519/v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PublicIdentity {
    pub id: String,
    pub root_public_key: String,
    pub noise_static_public_key: String,
    pub derivation_version: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IdentityError {
    RandomSource(String),
    InvalidMnemonic(String),
    InvalidSecret(String),
    RecoveryConfirmationMismatch,
    RecoveryNotConfirmed,
    UnsupportedDerivationVersion(u32),
}

impl std::fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RandomSource(value) => write!(formatter, "secure random source failed: {value}"),
            Self::InvalidMnemonic(value) => write!(formatter, "invalid BIP-39 mnemonic: {value}"),
            Self::InvalidSecret(value) => write!(formatter, "invalid identity secret: {value}"),
            Self::RecoveryConfirmationMismatch => {
                formatter.write_str("recovery phrase confirmation does not match")
            }
            Self::RecoveryNotConfirmed => {
                formatter.write_str("recovery phrase has not been confirmed")
            }
            Self::UnsupportedDerivationVersion(version) => {
                write!(
                    formatter,
                    "unsupported identity derivation version: {version}"
                )
            }
        }
    }
}

impl std::error::Error for IdentityError {}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecretDocument {
    derivation_version: u32,
    entropy: Vec<u8>,
    contact_token: Vec<u8>,
}

pub struct IdentityManager {
    entropy: [u8; 32],
    mnemonic: Zeroizing<String>,
    public_identity: PublicIdentity,
    contact_token: [u8; 32],
    recovery_confirmed: bool,
}

impl std::fmt::Debug for IdentityManager {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("IdentityManager")
            .field("public_identity", &self.public_identity)
            .field("recovery_confirmed", &self.recovery_confirmed)
            .finish_non_exhaustive()
    }
}

impl PartialEq for IdentityManager {
    fn eq(&self, other: &Self) -> bool {
        self.entropy == other.entropy
            && self.public_identity == other.public_identity
            && self.recovery_confirmed == other.recovery_confirmed
    }
}

impl Eq for IdentityManager {}

impl Drop for IdentityManager {
    fn drop(&mut self) {
        self.entropy.zeroize();
        self.contact_token.zeroize();
    }
}

impl IdentityManager {
    pub fn create() -> Result<Self, IdentityError> {
        let mut entropy = [0_u8; 32];
        getrandom::fill(&mut entropy)
            .map_err(|error| IdentityError::RandomSource(error.to_string()))?;
        Self::from_entropy(entropy, random_token()?, false)
    }

    pub fn restore(phrase: &str) -> Result<Self, IdentityError> {
        let mnemonic = Mnemonic::parse_in_normalized(Language::English, phrase)
            .map_err(|error| IdentityError::InvalidMnemonic(error.to_string()))?;
        let entropy = mnemonic.to_entropy();
        let entropy: [u8; 32] = entropy.try_into().map_err(|_| {
            IdentityError::InvalidMnemonic("expected a 24-word, 256-bit phrase".to_owned())
        })?;
        Self::from_entropy(entropy, random_token()?, true)
    }

    pub fn from_secret(secret: &[u8]) -> Result<Self, IdentityError> {
        let document: SecretDocument = serde_json::from_slice(secret)
            .map_err(|error| IdentityError::InvalidSecret(error.to_string()))?;
        if document.derivation_version != DERIVATION_VERSION {
            return Err(IdentityError::UnsupportedDerivationVersion(
                document.derivation_version,
            ));
        }
        let entropy: [u8; 32] = document.entropy.try_into().map_err(|_| {
            IdentityError::InvalidSecret("entropy must contain exactly 32 bytes".to_owned())
        })?;
        let contact_token: [u8; 32] = document.contact_token.try_into().map_err(|_| {
            IdentityError::InvalidSecret("contact token must contain exactly 32 bytes".to_owned())
        })?;
        Self::from_entropy(entropy, contact_token, true)
    }

    pub fn mnemonic(&self) -> &str {
        &self.mnemonic
    }

    pub fn public_identity(&self) -> &PublicIdentity {
        &self.public_identity
    }

    pub fn confirm_recovery(&mut self, phrase: &str) -> Result<(), IdentityError> {
        let candidate = Mnemonic::parse_in_normalized(Language::English, phrase)
            .map_err(|_| IdentityError::RecoveryConfirmationMismatch)?;
        if candidate.to_entropy().as_slice() != self.entropy {
            return Err(IdentityError::RecoveryConfirmationMismatch);
        }
        self.recovery_confirmed = true;
        Ok(())
    }

    pub fn export_confirmed_secret(&self) -> Result<Vec<u8>, IdentityError> {
        if !self.recovery_confirmed {
            return Err(IdentityError::RecoveryNotConfirmed);
        }
        Ok(self.export_secret())
    }

    pub fn export_secret(&self) -> Vec<u8> {
        serde_json::to_vec(&SecretDocument {
            derivation_version: DERIVATION_VERSION,
            entropy: self.entropy.to_vec(),
            contact_token: self.contact_token.to_vec(),
        })
        .expect("fixed identity secret document is serializable")
    }

    pub(crate) fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&derive_key(&self.mnemonic, ROOT_SIGNING_INFO))
    }

    pub(crate) fn noise_static_secret(&self) -> StaticSecret {
        StaticSecret::from(derive_key(&self.mnemonic, NOISE_STATIC_INFO))
    }

    pub(crate) fn contact_token(&self) -> &[u8; 32] {
        &self.contact_token
    }

    fn from_entropy(
        entropy: [u8; 32],
        contact_token: [u8; 32],
        recovery_confirmed: bool,
    ) -> Result<Self, IdentityError> {
        let mnemonic = Mnemonic::from_entropy_in(Language::English, &entropy)
            .map_err(|error| IdentityError::InvalidMnemonic(error.to_string()))?;
        let mnemonic = Zeroizing::new(mnemonic.to_string());
        let signing_key = SigningKey::from_bytes(&derive_key(&mnemonic, ROOT_SIGNING_INFO));
        let root_public_key = signing_key.verifying_key().to_bytes();
        let noise_secret = StaticSecret::from(derive_key(&mnemonic, NOISE_STATIC_INFO));
        let noise_public_key = X25519PublicKey::from(&noise_secret).to_bytes();
        let id_hash = Sha256::digest(root_public_key);
        let public_identity = PublicIdentity {
            id: format!("did:cht:{id_hash:x}"),
            root_public_key: URL_SAFE_NO_PAD.encode(root_public_key),
            noise_static_public_key: URL_SAFE_NO_PAD.encode(noise_public_key),
            derivation_version: DERIVATION_VERSION,
        };
        Ok(Self {
            entropy,
            mnemonic,
            public_identity,
            contact_token,
            recovery_confirmed,
        })
    }
}

fn random_token() -> Result<[u8; 32], IdentityError> {
    let mut token = [0_u8; 32];
    getrandom::fill(&mut token).map_err(|error| IdentityError::RandomSource(error.to_string()))?;
    Ok(token)
}

fn derive_key(mnemonic: &str, info: &[u8]) -> [u8; 32] {
    let parsed = Mnemonic::parse_in_normalized(Language::English, mnemonic)
        .expect("internally stored mnemonic is valid");
    let seed = Zeroizing::new(parsed.to_seed_normalized(""));
    let hkdf = Hkdf::<Sha256>::new(Some(DERIVATION_SALT), seed.as_slice());
    let mut output = [0_u8; 32];
    hkdf.expand(info, &mut output)
        .expect("32-byte HKDF output is valid");
    output
}
