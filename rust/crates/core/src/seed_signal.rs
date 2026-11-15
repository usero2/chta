//! Peer-bound discovery signaling. This module never carries user content.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub(crate) const MAX_SAFE_TIME: u64 = 9_007_199_254_740_991;
const CONTEXT: &[u8] = b"chta seed signal v1\0";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SeedSignal {
    pub version: u32,
    pub from: String,
    pub to: String,
    pub session: String,
    pub id: String,
    pub kind: String,
    pub payload: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub public_key: String,
    pub signature: String,
}

#[derive(Deserialize)]
#[serde(tag = "t", deny_unknown_fields)]
pub(crate) enum Payload {
    #[serde(rename = "offer")]
    Offer { v: u32, s: String, d: String },
    #[serde(rename = "answer")]
    Answer { v: u32, s: String, d: String },
    #[serde(rename = "ice")]
    Ice {
        v: u32,
        s: String,
        c: String,
        #[serde(deserialize_with = "required_nullable")]
        m: Option<String>,
        #[serde(deserialize_with = "required_nullable", rename = "l")]
        _line: Option<u16>,
    },
}

fn required_nullable<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

pub(crate) fn hex(value: &str, len: usize) -> bool {
    value.len() == len
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
pub(crate) fn valid_identity(value: &str) -> bool {
    value.strip_prefix("did:cht:").is_some_and(|s| hex(s, 64))
}
#[cfg(target_arch = "wasm32")]
pub(crate) fn safe_time(value: f64) -> Result<u64, String> {
    if !value.is_finite() || value.fract() != 0.0 || value < 0.0 || value > MAX_SAFE_TIME as f64 {
        return Err("Seed time must be a safe nonnegative integer".into());
    }
    Ok(value as u64)
}
pub(crate) fn candidate(value: &str) -> bool {
    let parts: Vec<_> = value.split_ascii_whitespace().collect();
    value.len() <= 2048
        && !value.contains(['\r', '\n', '\0'])
        && parts.len() >= 8
        && parts[0]
            .strip_prefix("candidate:")
            .is_some_and(|s| !s.is_empty())
        && parts[1]
            .parse::<u16>()
            .is_ok_and(|n| (1..=256).contains(&n))
        && ["udp", "tcp"]
            .iter()
            .any(|t| parts[2].eq_ignore_ascii_case(t))
        && parts[3].parse::<u32>().is_ok()
        && !parts[4].is_empty()
        && parts[5].parse::<u16>().is_ok_and(|n| n > 0)
        && parts[6] == "typ"
        && ["host", "srflx", "prflx"].contains(&parts[7])
        && !parts.windows(2).any(|p| p[0] == "typ" && p[1] == "relay")
}
pub(crate) fn description(value: &str, offer: bool) -> bool {
    let lines: Vec<_> = value.lines().map(|s| s.trim_end_matches('\r')).collect();
    let fingerprints: Vec<_> = lines
        .iter()
        .filter_map(|l| l.strip_prefix("a=fingerprint:sha-256 "))
        .collect();
    let valid_fingerprint = !fingerprints.is_empty()
        && fingerprints.iter().all(|fp| {
            let bytes: Vec<_> = fp.split(':').collect();
            bytes.len() == 32
                && bytes
                    .iter()
                    .all(|b| b.len() == 2 && b.bytes().all(|c| c.is_ascii_hexdigit()))
        });
    let roles: Vec<_> = lines
        .iter()
        .filter_map(|l| l.strip_prefix("a=setup:"))
        .collect();
    value.len() <= 11000
        && !value.contains('\0')
        && lines.first() == Some(&"v=0")
        && valid_fingerprint
        && !roles.is_empty()
        && roles.iter().all(|r| {
            if offer {
                *r == "actpass"
            } else {
                ["active", "passive"].contains(r)
            }
        })
        && lines
            .iter()
            .filter_map(|l| l.strip_prefix("a=candidate:"))
            .all(|c| candidate(&format!("candidate:{c}")))
}

impl SeedSignal {
    pub fn signing_payload(&self) -> Result<Vec<u8>, String> {
        let mut bytes = CONTEXT.to_vec();
        bytes.extend(
            serde_json::to_vec(&(
                self.version,
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
    pub(crate) fn signed(
        key: &SigningKey,
        to: &str,
        id: &str,
        text: &str,
        now: u64,
    ) -> Result<Self, String> {
        let value: serde_json::Value =
            serde_json::from_str(text).map_err(|_| "Invalid seed payload")?;
        let session = value["s"].as_str().ok_or("Missing session")?.to_owned();
        let kind = value["t"].as_str().ok_or("Missing kind")?.to_owned();
        let public_key = key.verifying_key().to_bytes();
        let mut signal = Self {
            version: 1,
            from: format!("did:cht:{:x}", Sha256::digest(public_key)),
            to: to.into(),
            session,
            id: id.into(),
            kind,
            payload: text.into(),
            issued_at: now,
            expires_at: now.checked_add(120_000).ok_or("Invalid time")?,
            public_key: URL_SAFE_NO_PAD.encode(public_key),
            signature: String::new(),
        };
        signal.validate(now)?;
        signal.signature = URL_SAFE_NO_PAD.encode(key.sign(&signal.signing_payload()?).to_bytes());
        signal.check_size()?;
        Ok(signal)
    }
    fn check_size(&self) -> Result<(), String> {
        if serde_json::to_vec(self).map_err(|e| e.to_string())?.len() > 16384 {
            return Err("Seed envelope too large".into());
        }
        Ok(())
    }
    fn validate(&self, now: u64) -> Result<(), String> {
        if now > MAX_SAFE_TIME
            || self.version != 1
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
            return Err("Invalid seed envelope metadata".into());
        }
        let prefix = format!("cht-control-direct-v1-{}-{}-", self.session, self.kind);
        let counter = self.id.strip_prefix(&prefix).ok_or("Invalid signal ID")?;
        if counter.is_empty()
            || counter.len() > 20
            || !counter.bytes().all(|c| c.is_ascii_digit())
            || counter.parse::<u64>().is_err()
        {
            return Err("Invalid signal counter".into());
        }
        let payload: Payload =
            serde_json::from_str(&self.payload).map_err(|_| "Invalid seed payload schema")?;
        let valid = match payload {
            Payload::Offer { v, s, d } => {
                self.kind == "offer" && v == 1 && s == self.session && description(&d, true)
            }
            Payload::Answer { v, s, d } => {
                self.kind == "answer" && v == 1 && s == self.session && description(&d, false)
            }
            Payload::Ice {
                v,
                s,
                c,
                m,
                _line: _,
            } => {
                self.kind == "ice"
                    && v == 1
                    && s == self.session
                    && candidate(&c)
                    && m.is_none_or(|s| s.len() <= 64 && !s.contains(['\r', '\n', '\0']))
            }
        };
        if !valid {
            return Err("Invalid seed payload metadata".into());
        }
        Ok(())
    }
    pub(crate) fn inspect(source: &str, now: u64) -> Result<Self, String> {
        if source.len() > 16384 {
            return Err("Seed envelope too large".into());
        }
        let signal: Self =
            serde_json::from_str(source).map_err(|_| "Invalid seed envelope schema")?;
        signal.validate(now)?;
        let key: [u8; 32] = URL_SAFE_NO_PAD
            .decode(&signal.public_key)
            .map_err(|_| "Invalid seed key")?
            .try_into()
            .map_err(|_| "Invalid seed key length")?;
        if signal.from != format!("did:cht:{:x}", Sha256::digest(key)) {
            return Err("Seed sender key mismatch".into());
        }
        let signature: [u8; 64] = URL_SAFE_NO_PAD
            .decode(&signal.signature)
            .map_err(|_| "Invalid seed signature")?
            .try_into()
            .map_err(|_| "Invalid seed signature length")?;
        VerifyingKey::from_bytes(&key)
            .map_err(|_| "Invalid seed key")?
            .verify_strict(
                &signal.signing_payload()?,
                &Signature::from_bytes(&signature),
            )
            .map_err(|_| "Invalid seed signature")?;
        Ok(signal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn valid_signatures_do_not_bypass_metadata_and_payload_validation() {
        let key = SigningKey::from_bytes(&[7; 32]);
        let session = "0123456789abcdef0123456789abcdef";
        let payload=json!({"v":1,"t":"ice","s":session,"c":"candidate:1 1 UDP 123 192.0.2.1 1234 typ host","m":null,"l":0}).to_string();
        let now = 1_800_000_000_000;
        let original = SeedSignal::signed(
            &key,
            &format!("did:cht:{}", "1".repeat(64)),
            &format!("cht-control-direct-v1-{session}-ice-0"),
            &payload,
            now,
        )
        .unwrap();
        for field in [
            "version",
            "session",
            "id",
            "kind",
            "payload",
            "issuedAt",
            "expiresAt",
        ] {
            let mut changed = serde_json::to_value(&original).unwrap();
            changed[field] = match field {
                "version" => json!(2),
                "session" => json!("f".repeat(32)),
                "id" => json!(format!("cht-control-direct-v1-{session}-offer-0")),
                "kind" => json!("message"),
                "payload" => json!(payload.replace("typ host", "typ relay")),
                "issuedAt" => json!(now + 30_001),
                "expiresAt" => json!(now + 120_001),
                _ => unreachable!(),
            };
            let mut signal: SeedSignal = serde_json::from_value(changed).unwrap();
            signal.signature =
                URL_SAFE_NO_PAD.encode(key.sign(&signal.signing_payload().unwrap()).to_bytes());
            assert!(
                SeedSignal::inspect(&serde_json::to_string(&signal).unwrap(), now).is_err(),
                "{field}"
            );
        }
        let mut wrong_domain = original.clone();
        let canonical = original.signing_payload().unwrap();
        wrong_domain.signature =
            URL_SAFE_NO_PAD.encode(key.sign(&canonical[CONTEXT.len()..]).to_bytes());
        assert!(SeedSignal::inspect(&serde_json::to_string(&wrong_domain).unwrap(), now).is_err());
    }
}
