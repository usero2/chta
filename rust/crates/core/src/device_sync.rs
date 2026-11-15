//! Own-device cryptography. Discovery envelopes cannot carry account content.
mod certificate;
mod session;
use crate::IdentityManager;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
pub use certificate::DeviceCertificate;
use certificate::{decode, verify_signature};
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use session::DeviceSession;
use std::collections::BTreeMap;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const MAX_TIME: u64 = 9_007_199_254_740_991;
const MAX_SESSIONS: usize = 16;

pub struct DeviceEngine {
    certificate: DeviceCertificate,
    signing_key: Zeroizing<[u8; 32]>,
    noise_key: Zeroizing<[u8; 32]>,
    sessions: BTreeMap<String, DeviceSession>,
    replays: BTreeMap<String, u64>,
}
impl std::fmt::Debug for DeviceEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceEngine")
            .field("certificate", &self.certificate)
            .finish_non_exhaustive()
    }
}
impl DeviceEngine {
    pub fn new(identity: &IdentityManager, created_at: u64) -> Result<Self, String> {
        if created_at > MAX_TIME {
            return Err("Invalid device creation time".into());
        }
        let signing_key = Zeroizing::new(random_bytes()?);
        let noise_key = Zeroizing::new(random_bytes()?);
        let device_id = random_bytes::<16>()?
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let key = SigningKey::from_bytes(&signing_key);
        let noise = PublicKey::from(&StaticSecret::from(*noise_key));
        let mut certificate = DeviceCertificate {
            version: 1,
            owner_id: identity.public_identity().id.clone(),
            root_public_key: identity.public_identity().root_public_key.clone(),
            device_id,
            signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().to_bytes()),
            noise_public_key: URL_SAFE_NO_PAD.encode(noise.to_bytes()),
            created_at,
            signature: String::new(),
        };
        certificate.signature = URL_SAFE_NO_PAD.encode(
            identity
                .signing_key()
                .sign(&certificate.payload()?)
                .to_bytes(),
        );
        Ok(Self {
            certificate,
            signing_key,
            noise_key,
            sessions: BTreeMap::new(),
            replays: BTreeMap::new(),
        })
    }
    pub fn call(
        &mut self,
        identity: &IdentityManager,
        operation: &str,
        args: Value,
    ) -> Result<Value, String> {
        if self.certificate.owner_id != identity.public_identity().id {
            return Err("Device owner changed".into());
        }
        match operation {
            "local" => Ok(json!({"certificate":self.certificate})),
            "inspectCertificate" => {
                let c = self.remote(&args["certificate"], false)?;
                Ok(json!({"certificate":c}))
            }
            "registrationProof" => {
                let seed = string(&args, "seedId")?;
                let nonce = string(&args, "nonce")?;
                if !crate::seed_signal::hex(seed, 64) {
                    return Err("Invalid seed ID".into());
                }
                decode::<32>(nonce)?;
                let payload = canonical(
                    b"chta device registration v1\0",
                    &json!([
                        1,
                        seed,
                        nonce,
                        self.certificate.owner_id,
                        self.certificate.device_id
                    ]),
                )?;
                Ok(json!({"certificate":self.certificate,"deviceProof":self.sign(&payload)}))
            }
            "signSignal" => {
                let now = time(&args, "now")?;
                let text = string(&args, "text")?;
                let p: Value = serde_json::from_str(text).map_err(|_| "Invalid device SDP/ICE")?;
                let mut s = DeviceSignal {
                    version: 1,
                    owner_id: self.certificate.owner_id.clone(),
                    from_device: self.certificate.device_id.clone(),
                    to_device: string(&args, "toDevice")?.into(),
                    session: string(&p, "s")?.into(),
                    id: string(&args, "id")?.into(),
                    kind: string(&p, "t")?.into(),
                    payload: text.into(),
                    issued_at: now,
                    expires_at: now.checked_add(120_000).ok_or("Invalid time")?,
                    certificate: self.certificate.clone(),
                    signature: String::new(),
                };
                s.validate(now)?;
                s.signature = self.sign(&s.payload()?);
                s.size()?;
                serde_json::to_value(s).map_err(|e| e.to_string())
            }
            "inspectSignal" => {
                let now = time(&args, "now")?;
                if serde_json::to_vec(&args["envelope"])
                    .map_err(|e| e.to_string())?
                    .len()
                    > 16384
                {
                    return Err("Device signal too large".into());
                }
                let s: DeviceSignal = serde_json::from_value(args["envelope"].clone())
                    .map_err(|_| "Invalid device signal schema")?;
                s.validate(now)?;
                s.certificate.verify(&self.certificate.owner_id)?;
                if s.owner_id != self.certificate.owner_id
                    || s.from_device != s.certificate.device_id
                    || s.to_device != self.certificate.device_id
                    || s.from_device != string(&args, "expectedDevice")?
                {
                    return Err("Device signal addressing mismatch".into());
                }
                verify_signature(
                    &s.certificate.signing_public_key,
                    &s.signature,
                    &s.payload()?,
                )?;
                self.replays.retain(|_, expiry| *expiry > now);
                let replay = format!("{}:{}:{}", s.from_device, s.id, s.signature);
                if self.replays.contains_key(&replay) || self.replays.len() >= 8192 {
                    return Err("Replayed device signal".into());
                }
                self.replays.insert(replay, s.expires_at);
                Ok(
                    json!({"deviceId":s.from_device,"id":s.id,"text":s.payload,"certificate":s.certificate}),
                )
            }
            "prepare" => {
                let remote = self.remote(&args["certificate"], true)?;
                let id = valid_session(&args)?;
                if self.sessions.contains_key(id) || self.sessions.len() >= MAX_SESSIONS {
                    return Err("Device session exists or capacity reached".into());
                }
                let initiator = args["initiator"].as_bool().ok_or("Missing device role")?;
                let (session, frame) = DeviceSession::prepare(self, &remote, id, initiator)?;
                self.sessions.insert(id.into(), session);
                Ok(json!({"session":id,"frame":frame,"ready":false}))
            }
            "handshake" => {
                let id = valid_session(&args)?;
                // Only a pending handshake is consumed. A malformed replacement
                // has no access to another live session's state/counters.
                if !matches!(self.sessions.get(id), Some(DeviceSession::Handshake(_))) {
                    return Err("No pending device handshake".into());
                }
                let state = self.sessions.remove(id).ok_or("Unknown device session")?;
                let (state, frame, ready) = state.handshake(string(&args, "frame")?)?;
                self.sessions.insert(id.into(), state);
                Ok(json!({"session":id,"frame":frame,"ready":ready}))
            }
            "seal" => {
                let id = valid_session(&args)?;
                let state = self.sessions.get_mut(id).ok_or("Unknown device session")?;
                Ok(json!({"frame":state.seal(string(&args,"text")?)?}))
            }
            "open" => {
                let id = valid_session(&args)?;
                let state = self.sessions.get_mut(id).ok_or("Unknown device session")?;
                Ok(json!({"text":state.open(string(&args,"frame")?)?}))
            }
            "close" => {
                self.sessions.remove(valid_session(&args)?);
                Ok(json!({}))
            }
            _ => Err("Unsupported device operation".into()),
        }
    }
    fn remote(&self, value: &Value, different: bool) -> Result<DeviceCertificate, String> {
        let c: DeviceCertificate = serde_json::from_value(value.clone())
            .map_err(|_| "Invalid device certificate schema")?;
        c.verify(&self.certificate.owner_id)?;
        if different && c.device_id == self.certificate.device_id {
            return Err("Cannot connect a device to itself".into());
        }
        Ok(c)
    }
    fn sign(&self, payload: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(
            SigningKey::from_bytes(&self.signing_key)
                .sign(payload)
                .to_bytes(),
        )
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeviceSignal {
    version: u32,
    owner_id: String,
    from_device: String,
    to_device: String,
    session: String,
    id: String,
    kind: String,
    payload: String,
    issued_at: u64,
    expires_at: u64,
    certificate: DeviceCertificate,
    signature: String,
}
impl DeviceSignal {
    fn payload(&self) -> Result<Vec<u8>, String> {
        canonical(
            b"chta device seed signal v1\0",
            &json!([
                self.version,
                self.owner_id,
                self.from_device,
                self.to_device,
                self.session,
                self.id,
                self.kind,
                self.payload,
                self.issued_at,
                self.expires_at
            ]),
        )
    }
    fn size(&self) -> Result<(), String> {
        if serde_json::to_vec(self).map_err(|e| e.to_string())?.len() > 16384 {
            Err("Device signal too large".into())
        } else {
            Ok(())
        }
    }
    fn validate(&self, now: u64) -> Result<(), String> {
        use crate::seed_signal::{Payload, candidate, description, hex};
        if now > MAX_TIME
            || self.version != 1
            || !crate::seed_signal::valid_identity(&self.owner_id)
            || !hex(&self.from_device, 32)
            || !hex(&self.to_device, 32)
            || self.from_device == self.to_device
            || !hex(&self.session, 32)
            || self.issued_at > MAX_TIME
            || self.expires_at > MAX_TIME
            || self.issued_at > now.saturating_add(30_000)
            || self.expires_at <= now
            || self.expires_at <= self.issued_at
            || self.expires_at - self.issued_at > 120_000
            || self.payload.len() > 11264
        {
            return Err("Invalid device signal metadata".into());
        }
        let prefix = format!("cht-control-direct-v1-{}-{}-", self.session, self.kind);
        let counter = self
            .id
            .strip_prefix(&prefix)
            .ok_or("Invalid device signal ID")?;
        if counter.is_empty()
            || counter.len() > 20
            || !counter.bytes().all(|c| c.is_ascii_digit())
            || counter.parse::<u64>().is_err()
        {
            return Err("Invalid device signal counter".into());
        }
        let p: Payload =
            serde_json::from_str(&self.payload).map_err(|_| "Invalid device SDP/ICE schema")?;
        let valid = match p {
            Payload::Offer { v, s, d } => {
                v == 1 && s == self.session && self.kind == "offer" && description(&d, true)
            }
            Payload::Answer { v, s, d } => {
                v == 1 && s == self.session && self.kind == "answer" && description(&d, false)
            }
            Payload::Ice { v, s, c, m, .. } => {
                v == 1
                    && s == self.session
                    && self.kind == "ice"
                    && candidate(&c)
                    && m.is_none_or(|s| s.len() <= 64 && !s.contains(['\r', '\n', '\0']))
            }
        };
        if !valid {
            return Err("Invalid device SDP/ICE".into());
        }
        self.size()
    }
}
fn random_bytes<const N: usize>() -> Result<[u8; N], String> {
    let mut b = [0u8; N];
    getrandom::fill(&mut b).map_err(|e| e.to_string())?;
    Ok(b)
}
fn canonical(context: &[u8], tuple: &Value) -> Result<Vec<u8>, String> {
    let mut out = context.to_vec();
    out.extend(serde_json::to_vec(tuple).map_err(|e| e.to_string())?);
    Ok(out)
}
fn string<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args[key].as_str().ok_or_else(|| format!("Missing {key}"))
}
fn time(args: &Value, key: &str) -> Result<u64, String> {
    args[key]
        .as_u64()
        .filter(|n| *n <= MAX_TIME)
        .ok_or_else(|| format!("Invalid {key}"))
}
fn valid_session(args: &Value) -> Result<&str, String> {
    let id = string(args, "session")?;
    if !crate::seed_signal::hex(id, 32) {
        return Err("Invalid device session ID".into());
    }
    Ok(id)
}
