use std::collections::BTreeMap;

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ed25519_dalek::{Signature, Signer, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{IdentityManager, PublicIdentity};

const CONTACT_PROTOCOL_VERSION: u32 = 1;
const CONTACT_SIGNATURE_CONTEXT: &[u8] = b"cht contact card v1\0";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContactError {
    InvalidCard(String),
    UnsupportedVersion(u32),
    IdentityMismatch,
    InvalidSignature,
    InvalidName,
    InvalidAvatar,
    AlreadyExists(String),
    NotFound(String),
}

impl std::fmt::Display for ContactError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidCard(value) => write!(formatter, "invalid contact card: {value}"),
            Self::UnsupportedVersion(value) => {
                write!(formatter, "unsupported contact card version: {value}")
            }
            Self::IdentityMismatch => {
                formatter.write_str("contact identity does not match its key")
            }
            Self::InvalidSignature => formatter.write_str("contact card signature is invalid"),
            Self::InvalidName => formatter.write_str("contact name cannot be empty"),
            Self::InvalidAvatar => formatter.write_str(
                "contact avatar must be a JPEG thumbnail up to 64x64 pixels and 1024 bytes",
            ),
            Self::AlreadyExists(value) => write!(formatter, "contact already exists: {value}"),
            Self::NotFound(value) => write!(formatter, "contact not found: {value}"),
        }
    }
}

impl std::error::Error for ContactError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactCard {
    pub protocol_version: u32,
    pub identity: PublicIdentity,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub display_name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub avatar: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub relay_urls: Vec<String>,
    pub contact_token: String,
    pub capabilities: Vec<String>,
    pub signature: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UnsignedContactCard<'a> {
    protocol_version: u32,
    identity: &'a PublicIdentity,
    #[serde(skip_serializing_if = "str::is_empty")]
    display_name: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    avatar: &'a str,
    #[serde(skip_serializing_if = "<[String]>::is_empty")]
    relay_urls: &'a [String],
    contact_token: &'a str,
    capabilities: &'a [String],
}

impl ContactCard {
    pub fn to_json(&self) -> Result<String, ContactError> {
        serde_json::to_string(self).map_err(|error| ContactError::InvalidCard(error.to_string()))
    }

    fn signing_payload(&self) -> Result<Vec<u8>, ContactError> {
        let mut payload = CONTACT_SIGNATURE_CONTEXT.to_vec();
        payload.extend(
            serde_json::to_vec(&UnsignedContactCard {
                protocol_version: self.protocol_version,
                identity: &self.identity,
                display_name: &self.display_name,
                avatar: &self.avatar,
                relay_urls: &self.relay_urls,
                contact_token: &self.contact_token,
                capabilities: &self.capabilities,
            })
            .map_err(|error| ContactError::InvalidCard(error.to_string()))?,
        );
        Ok(payload)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactRecord {
    pub identity_id: String,
    pub display_name: String,
    #[serde(default)]
    pub signed_name: String,
    #[serde(default)]
    pub alias: String,
    pub fingerprint: String,
    pub verified: bool,
    pub card: ContactCard,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactStore {
    contacts: BTreeMap<String, ContactRecord>,
}

impl IdentityManager {
    pub fn contact_card(&self) -> Result<ContactCard, ContactError> {
        self.contact_card_with_name("")
    }

    pub fn contact_card_with_name(&self, display_name: &str) -> Result<ContactCard, ContactError> {
        self.contact_card_with_profile(display_name, "")
    }

    pub fn contact_card_with_profile(
        &self,
        display_name: &str,
        avatar: &str,
    ) -> Result<ContactCard, ContactError> {
        self.contact_card_with_relays(display_name, avatar, &[])
    }

    pub fn contact_card_with_relays(
        &self,
        display_name: &str,
        avatar: &str,
        relay_urls: &[String],
    ) -> Result<ContactCard, ContactError> {
        let display_name = display_name.trim();
        if display_name.chars().count() > 64 {
            return Err(ContactError::InvalidName);
        }
        validate_avatar(avatar)?;
        validate_relay_urls(relay_urls)?;
        let mut card = ContactCard {
            protocol_version: CONTACT_PROTOCOL_VERSION,
            identity: self.public_identity().clone(),
            display_name: display_name.to_owned(),
            avatar: avatar.to_owned(),
            relay_urls: relay_urls.to_vec(),
            contact_token: URL_SAFE_NO_PAD.encode(self.contact_token()),
            capabilities: vec![
                "seed-v1".to_owned(),
                "contact-requests-v1".to_owned(),
                "webrtc-datachannel-v1".to_owned(),
                "noise-kk-v1".to_owned(),
                "relay-catalog-v1".to_owned(),
                "files-v2".to_owned(),
                "groups-v1".to_owned(),
                "peer-sessions-v2".to_owned(),
            ],
            signature: String::new(),
        };
        let signature = self.signing_key().sign(&card.signing_payload()?);
        card.signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
        Ok(card)
    }
}

impl ContactStore {
    pub fn from_json(json: &str) -> Result<Self, ContactError> {
        let mut store: Self = serde_json::from_str(json)
            .map_err(|error| ContactError::InvalidCard(error.to_string()))?;
        for contact in store.contacts.values_mut() {
            let signed_name = signed_name(&contact.card);
            if contact.signed_name.is_empty() {
                contact.signed_name = signed_name.clone();
            }
            if contact.alias.is_empty()
                && contact.display_name != signed_name
                && contact.display_name != contact.identity_id
            {
                contact.alias = contact.display_name.clone();
            }
            contact.display_name = effective_name(&contact.signed_name, &contact.alias);
        }
        Ok(store)
    }

    pub fn to_json(&self) -> Result<String, ContactError> {
        serde_json::to_string(self).map_err(|error| ContactError::InvalidCard(error.to_string()))
    }

    pub fn verify_card(json: &str) -> Result<ContactRecord, ContactError> {
        let card: ContactCard = serde_json::from_str(json)
            .map_err(|error| ContactError::InvalidCard(error.to_string()))?;
        if card.protocol_version != CONTACT_PROTOCOL_VERSION {
            return Err(ContactError::UnsupportedVersion(card.protocol_version));
        }
        validate_avatar(&card.avatar)?;
        validate_relay_urls(&card.relay_urls)?;

        let root_public_key =
            decode_array::<32>(&card.identity.root_public_key, "root public key")?;
        let expected_id = format!("did:cht:{:x}", Sha256::digest(root_public_key));
        if card.identity.id != expected_id {
            return Err(ContactError::IdentityMismatch);
        }
        decode_array::<32>(&card.identity.noise_static_public_key, "Noise public key")?;
        decode_array::<32>(&card.contact_token, "contact token")?;

        let verifying_key = VerifyingKey::from_bytes(&root_public_key)
            .map_err(|error| ContactError::InvalidCard(error.to_string()))?;
        let signature_bytes = decode_array::<64>(&card.signature, "signature")?;
        let signature = Signature::from_bytes(&signature_bytes);
        verifying_key
            .verify(&card.signing_payload()?, &signature)
            .map_err(|_| ContactError::InvalidSignature)?;

        let card_name = card.display_name.trim();
        if card_name.chars().count() > 64 {
            return Err(ContactError::InvalidName);
        }
        let signed_name = signed_name(&card);

        Ok(ContactRecord {
            identity_id: card.identity.id.clone(),
            display_name: signed_name.clone(),
            signed_name,
            alias: String::new(),
            fingerprint: fingerprint(&root_public_key),
            verified: false,
            card,
        })
    }

    pub fn add_card(
        &mut self,
        json: &str,
        display_name: &str,
    ) -> Result<ContactRecord, ContactError> {
        let alias = display_name.trim();
        if alias.chars().count() > 64 {
            return Err(ContactError::InvalidName);
        }
        let mut record = Self::verify_card(json)?;
        if self.contacts.contains_key(&record.identity_id) {
            return Err(ContactError::AlreadyExists(record.identity_id));
        }
        if alias != record.signed_name {
            record.alias = alias.to_owned();
        }
        record.display_name = effective_name(&record.signed_name, &record.alias);
        let id = record.identity_id.clone();
        self.contacts.insert(id.clone(), record);
        Ok(self
            .contacts
            .get(&id)
            .expect("inserted contact exists")
            .clone())
    }

    pub fn set_alias(&mut self, identity_id: &str, alias: &str) -> Result<(), ContactError> {
        let alias = alias.trim();
        if alias.chars().count() > 64 {
            return Err(ContactError::InvalidName);
        }
        let contact = self
            .contacts
            .get_mut(identity_id)
            .ok_or_else(|| ContactError::NotFound(identity_id.to_owned()))?;
        contact.alias = if alias == contact.signed_name {
            String::new()
        } else {
            alias.to_owned()
        };
        contact.display_name = effective_name(&contact.signed_name, &contact.alias);
        Ok(())
    }

    pub fn refresh_card(&mut self, record: ContactRecord) -> Result<(), ContactError> {
        let contact = self
            .contacts
            .get_mut(&record.identity_id)
            .ok_or_else(|| ContactError::NotFound(record.identity_id.clone()))?;
        contact.signed_name = record.signed_name;
        contact.card = record.card;
        contact.display_name = effective_name(&contact.signed_name, &contact.alias);
        Ok(())
    }

    pub fn mark_verified(&mut self, identity_id: &str) -> Result<(), ContactError> {
        let contact = self
            .contacts
            .get_mut(identity_id)
            .ok_or_else(|| ContactError::NotFound(identity_id.to_owned()))?;
        contact.verified = true;
        Ok(())
    }

    pub fn remove(&mut self, identity_id: &str) -> Result<(), ContactError> {
        self.contacts
            .remove(identity_id)
            .map(|_| ())
            .ok_or_else(|| ContactError::NotFound(identity_id.to_owned()))
    }

    pub fn list(&self) -> Vec<&ContactRecord> {
        self.contacts.values().collect()
    }

    pub fn verified_contact(&self, identity_id: &str) -> Result<&ContactRecord, ContactError> {
        let contact = self
            .contacts
            .get(identity_id)
            .ok_or_else(|| ContactError::NotFound(identity_id.to_owned()))?;
        if !contact.verified {
            return Err(ContactError::InvalidCard(
                "contact fingerprint has not been verified".to_owned(),
            ));
        }
        Ok(contact)
    }

    pub fn list_json(&self) -> Result<String, ContactError> {
        serde_json::to_string(&self.list())
            .map_err(|error| ContactError::InvalidCard(error.to_string()))
    }
}

fn validate_relay_urls(urls: &[String]) -> Result<(), ContactError> {
    if urls.len() > 2 {
        return Err(ContactError::InvalidCard(
            "Use at most two public relay URLs".into(),
        ));
    }
    for url in urls {
        if url.len() > 256 {
            return Err(ContactError::InvalidCard(
                "Contact relay URL is too long".into(),
            ));
        }
        crate::relay_directory::validate_endpoint(url, false).map_err(ContactError::InvalidCard)?;
    }
    Ok(())
}

fn validate_avatar(encoded: &str) -> Result<(), ContactError> {
    if encoded.is_empty() {
        return Ok(());
    }
    if encoded.len() > 1368 {
        return Err(ContactError::InvalidAvatar);
    }
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| ContactError::InvalidAvatar)?;
    if bytes.len() > 1024 || !bytes.starts_with(&[0xff, 0xd8]) {
        return Err(ContactError::InvalidAvatar);
    }
    // Read JPEG dimensions without allocating an image supplied by a peer.
    let mut offset = 2;
    while offset + 4 <= bytes.len() {
        if bytes[offset] != 0xff {
            return Err(ContactError::InvalidAvatar);
        }
        let marker = bytes[offset + 1];
        if marker == 0xff {
            offset += 1;
            continue;
        }
        let length = u16::from_be_bytes([bytes[offset + 2], bytes[offset + 3]]) as usize;
        if length < 2 || offset + 2 + length > bytes.len() {
            break;
        }
        if matches!(marker, 0xc0..=0xc2) && length >= 8 {
            let height = u16::from_be_bytes([bytes[offset + 5], bytes[offset + 6]]);
            let width = u16::from_be_bytes([bytes[offset + 7], bytes[offset + 8]]);
            if (1..=64).contains(&width) && (1..=64).contains(&height) {
                return Ok(());
            }
            break;
        }
        offset += 2 + length;
    }
    Err(ContactError::InvalidAvatar)
}

fn signed_name(card: &ContactCard) -> String {
    let value = card.display_name.trim();
    if value.is_empty() {
        card.identity.id.clone()
    } else {
        value.to_owned()
    }
}

fn effective_name(signed_name: &str, alias: &str) -> String {
    if alias.is_empty() {
        signed_name.to_owned()
    } else {
        alias.to_owned()
    }
}

fn decode_array<const N: usize>(value: &str, label: &str) -> Result<[u8; N], ContactError> {
    URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|error| ContactError::InvalidCard(format!("{label}: {error}")))?
        .try_into()
        .map_err(|_| ContactError::InvalidCard(format!("{label} must be {N} bytes")))
}

fn fingerprint(root_public_key: &[u8; 32]) -> String {
    let digest = Sha256::digest(root_public_key);
    digest
        .chunks(4)
        .map(|chunk| {
            chunk
                .iter()
                .map(|byte| format!("{byte:02X}"))
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("-")
}
