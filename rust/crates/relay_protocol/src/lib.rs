//! Public, signed relay hints. A valid hint is not a reachability or trust claim.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
mod courier;
pub use courier::{CourierCatalog, verify_courier_advertisement};

pub const MAX_RECORDS: usize = 1000;
pub const MAX_BATCH_RECORDS: usize = 64;
pub const MAX_TTL_MS: u64 = 60 * 60 * 1000;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayRecord {
    pub version: u8,
    pub relay_id: String,
    pub public_key: String,
    pub endpoint: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub signature: String,
}

pub fn key_id(public: &[u8]) -> String {
    format!("{:x}", Sha256::digest(public))
}

pub fn validate_endpoint(value: &str, allow_loopback: bool) -> Result<(), String> {
    if value.len() > 2048 || value.bytes().any(|byte| byte.is_ascii_control()) {
        return Err("Relay address is too long".into());
    }
    let url = url::Url::parse(value).map_err(|_| "Invalid relay address")?;
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/cht"
    {
        return Err(
            "Use a relay WebSocket URL ending in /cht, without credentials or query".into(),
        );
    }
    let host = url
        .host_str()
        .ok_or("Missing relay host")?
        .trim_matches(['[', ']']);
    let loopback = host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback());
    if allow_loopback && loopback && matches!(url.scheme(), "ws" | "wss") {
        return Ok(());
    }
    if url.scheme() != "wss"
        || loopback
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
        || !host.contains('.') && !host.contains(':')
    {
        return Err("Shared relays require a public wss:// address".into());
    }
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        let private = match ip {
            std::net::IpAddr::V4(v) => {
                v.is_private()
                    || v.is_link_local()
                    || v.is_broadcast()
                    || v.is_documentation()
                    || v.octets()[0] == 0
                    || v.octets()[0] >= 224
                    || v.octets()[0] == 100 && (64..=127).contains(&v.octets()[1])
            }
            std::net::IpAddr::V6(v) => {
                v.is_unique_local()
                    || v.is_unicast_link_local()
                    || v.is_multicast()
                    || v.is_unspecified()
                    || v.to_ipv4_mapped().is_some()
            }
        };
        if private {
            return Err("Private addresses cannot be shared as public relays".into());
        }
    }
    Ok(())
}

impl RelayRecord {
    fn payload(&self) -> Vec<u8> {
        // Tuple order is protocol-defined; JSON object property ordering is irrelevant.
        let mut payload = b"cht relay directory v1\0".to_vec();
        payload.extend(
            serde_json::to_vec(&(
                self.version,
                &self.relay_id,
                &self.public_key,
                &self.endpoint,
                self.issued_at,
                self.expires_at,
            ))
            .expect("fixed tuple"),
        );
        payload
    }

    pub fn signed(key: &SigningKey, endpoint: String, now: u64) -> Self {
        let public = key.verifying_key().to_bytes();
        let mut record = Self {
            version: 1,
            relay_id: key_id(&public),
            public_key: B64.encode(public),
            endpoint,
            issued_at: now,
            expires_at: now.saturating_add(15 * 60 * 1000),
            signature: String::new(),
        };
        record.signature = B64.encode(key.sign(&record.payload()).to_bytes());
        record
    }

    pub fn verify(&self, now: u64, allow_loopback: bool) -> Result<(), String> {
        validate_endpoint(&self.endpoint, allow_loopback)?;
        if self.version != 1
            || self.expires_at <= now
            || self.issued_at > now.saturating_add(60_000)
            || self.expires_at <= self.issued_at
            || self.expires_at - self.issued_at > MAX_TTL_MS
        {
            return Err("Expired or unsupported relay record".into());
        }
        let public = decode::<32>(&self.public_key)?;
        if key_id(&public) != self.relay_id {
            return Err("Relay key does not match its ID".into());
        }
        VerifyingKey::from_bytes(&public)
            .map_err(|_| "Invalid relay public key")?
            .verify_strict(
                &self.payload(),
                &Signature::from_bytes(&decode::<64>(&self.signature)?),
            )
            .map_err(|_| "Invalid relay signature".into())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RelayProof {
    pub identity_id: String,
    pub public_key: String,
    pub signature: String,
}

fn auth_payload(nonce: &str, relay_id: &str) -> Result<Vec<u8>, String> {
    decode::<32>(nonce)?;
    if relay_id.len() != 64 || !relay_id.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid relay ID".into());
    }
    Ok(format!("cht relay registration v1\0{relay_id}\0{nonce}").into_bytes())
}

impl RelayProof {
    pub fn signed(key: &SigningKey, nonce: &str, relay_id: &str) -> Result<Self, String> {
        let public = key.verifying_key().to_bytes();
        Ok(Self {
            identity_id: format!("did:cht:{}", key_id(&public)),
            public_key: B64.encode(public),
            signature: B64.encode(key.sign(&auth_payload(nonce, relay_id)?).to_bytes()),
        })
    }
    pub fn verify(&self, nonce: &str, relay_id: &str) -> Result<(), String> {
        let public = decode::<32>(&self.public_key)?;
        if self.identity_id != format!("did:cht:{}", key_id(&public)) {
            return Err("Registration DID mismatch".into());
        }
        VerifyingKey::from_bytes(&public)
            .map_err(|_| "Invalid public key")?
            .verify_strict(
                &auth_payload(nonce, relay_id)?,
                &Signature::from_bytes(&decode::<64>(&self.signature)?),
            )
            .map_err(|_| "Invalid relay registration proof".into())
    }
}

fn decode<const N: usize>(value: &str) -> Result<[u8; N], String> {
    if value.len() > N * 2 {
        return Err("Invalid key encoding".into());
    }
    B64.decode(value)
        .map_err(|_| "Invalid key encoding")?
        .try_into()
        .map_err(|_| "Invalid key length".into())
}

#[derive(Default)]
pub struct RelayDirectory {
    records: std::collections::BTreeMap<String, RelayRecord>,
}
impl RelayDirectory {
    pub fn merge(
        &mut self,
        entries: impl IntoIterator<Item = RelayRecord>,
        now: u64,
        allow_loopback: bool,
    ) -> usize {
        self.records.retain(|_, r| r.expires_at > now);
        let mut accepted = 0;
        for record in entries.into_iter().take(MAX_RECORDS) {
            if record.verify(now, allow_loopback).is_err() {
                continue;
            }
            if let Some(old) = self.records.get(&record.relay_id) {
                if old.issued_at >= record.issued_at {
                    continue;
                }
            } else if self.records.len() >= MAX_RECORDS {
                continue;
            }
            self.records.insert(record.relay_id.clone(), record);
            accepted += 1;
        }
        accepted
    }
    pub fn snapshot(&mut self, now: u64) -> Vec<RelayRecord> {
        self.records.retain(|_, r| r.expires_at > now);
        self.records.values().cloned().collect()
    }
    pub fn batch(&mut self, now: u64, offset: usize) -> Vec<RelayRecord> {
        self.records.retain(|_, r| r.expires_at > now);
        let count = self.records.len();
        if count == 0 {
            return Vec::new();
        }
        self.records
            .values()
            .cycle()
            .skip(offset % count)
            .take(count.min(MAX_BATCH_RECORDS - 1))
            .cloned()
            .collect()
    }
}

pub fn inspect_record_json(source: &str, now: u64, allow_loopback: bool) -> Result<String, String> {
    if source.len() > 4096 {
        return Err("Relay record is too large".into());
    }
    let record: RelayRecord = serde_json::from_str(source).map_err(|_| "Invalid relay record")?;
    record.verify(now, allow_loopback)?;
    serde_json::to_string(&record).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(byte: u8) -> SigningKey {
        SigningKey::from_bytes(&[byte; 32])
    }
    #[test]
    fn thousand_records_are_retained_and_rotating_batches_are_bounded() {
        let now = 1_000_000;
        let records = (0u32..1001)
            .map(|i| {
                let mut bytes = [0u8; 32];
                bytes[..4].copy_from_slice(&i.to_le_bytes());
                RelayRecord::signed(
                    &SigningKey::from_bytes(&bytes),
                    format!("wss://r{i}.example.com/cht"),
                    now,
                )
            })
            .collect::<Vec<_>>();
        let mut directory = RelayDirectory::default();
        for batch in records.chunks(64) {
            directory.merge(batch.to_vec(), now, false);
        }
        assert_eq!(directory.snapshot(now).len(), 1000);
        let mut seen = std::collections::HashSet::new();
        for offset in (0..1000).step_by(63) {
            let batch = directory.batch(now, offset);
            assert!(batch.len() <= 63);
            seen.extend(batch.into_iter().map(|r| r.relay_id));
        }
        assert_eq!(seen.len(), 1000);
    }
    #[test]
    fn signed_directory_rejects_tampering_expiry_replays_and_private_addresses() {
        let now = 1_000_000;
        let first = RelayRecord::signed(&key(1), "wss://a.example.com/cht".into(), now);
        let second = RelayRecord::signed(&key(2), "wss://b.example.com/cht".into(), now);
        let mut directory = RelayDirectory::default();
        assert_eq!(
            directory.merge([first.clone(), second.clone()], now, false),
            2
        );
        assert_eq!(directory.merge([first.clone()], now, false), 0);
        let mut tampered = first.clone();
        tampered.endpoint = second.endpoint;
        assert!(tampered.verify(now, false).is_err());
        assert!(first.verify(first.expires_at, false).is_err());
        for endpoint in [
            "ws://a.example.com/cht",
            "wss://127.0.0.1/cht",
            "wss://192.168.1.1/cht",
            "wss://100.64.0.1/cht",
            "wss://example.com/cht?token=x",
            "wss://u:p@example.com/cht",
            "wss://[::ffff:127.0.0.1]/cht",
        ] {
            assert!(validate_endpoint(endpoint, false).is_err(), "{endpoint}");
        }
        assert!(directory.snapshot(now + MAX_TTL_MS).is_empty());
    }
    #[test]
    fn proof_is_bound_to_fresh_challenge_and_relay() {
        let nonce = B64.encode([3u8; 32]);
        let relay = key_id(&[8; 32]);
        let proof = RelayProof::signed(&key(1), &nonce, &relay).unwrap();
        proof.verify(&nonce, &relay).unwrap();
        assert!(proof.verify(&B64.encode([4u8; 32]), &relay).is_err());
        assert!(proof.verify(&nonce, &key_id(&[9; 32])).is_err());
    }
}
