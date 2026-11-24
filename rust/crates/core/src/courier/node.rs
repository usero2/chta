use super::*;
use crate::delivery::{digest, parse};
use crate::device_sync::certificate::verify_signature;
use crate::seed_signal::{MAX_SAFE_TIME, hex};
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use serde_json::json;
use zeroize::Zeroize;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NodeCertificate {
    version: u32,
    owner_id: String,
    root_public_key: String,
    node_id: String,
    signing_public_key: String,
    created_at: u64,
    signature: String,
}
impl NodeCertificate {
    fn payload(&self) -> Result<Vec<u8>, String> {
        canonical(
            b"chta courier node certificate v1\0",
            &(
                self.version,
                &self.owner_id,
                &self.root_public_key,
                &self.node_id,
                &self.signing_public_key,
                self.created_at,
            ),
        )
    }
    fn verify(&self, now: u64) -> Result<(), String> {
        let root = decode::<32>(&self.root_public_key)?;
        let node = decode::<32>(&self.signing_public_key)?;
        if self.version != 1
            || self.owner_id != format!("did:cht:{}", digest(root))
            || self.node_id != digest(node)
            || !hex(&self.node_id, 64)
            || now > MAX_SAFE_TIME
            || self.created_at > MAX_SAFE_TIME
            || self.created_at > now.saturating_add(30000)
        {
            return Err("Invalid Courier node certificate".into());
        }
        verify_signature(&self.root_public_key, &self.signature, &self.payload()?)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NodeState {
    certificate: NodeCertificate,
    signing_key: [u8; 32],
}
impl Drop for NodeState {
    fn drop(&mut self) {
        self.signing_key.zeroize();
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NodeArgs {
    now: u64,
    #[serde(default)]
    state: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VerifyNode {
    certificate: NodeCertificate,
    now: u64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Control {
    version: u32,
    kind: String,
    signer_id: String,
    public_key: String,
    certificate: Option<NodeCertificate>,
    challenge: String,
    body: Value,
    issued_at: u64,
    expires_at: u64,
    signature: String,
}
impl Control {
    fn payload(&self) -> Result<Vec<u8>, String> {
        canonical(
            b"chta courier control v1\0",
            &(
                self.version,
                &self.kind,
                &self.signer_id,
                &self.public_key,
                &self.certificate,
                &self.challenge,
                &self.body,
                self.issued_at,
                self.expires_at,
            ),
        )
    }
    fn verify(&self, now: u64, expected: &str, challenge: &str) -> Result<(), String> {
        decode::<32>(&self.challenge)?;
        if self.version != 1
            || self.signer_id != expected
            || self.challenge != challenge
            || now > MAX_SAFE_TIME
            || self.issued_at > now.saturating_add(30000)
            || self.expires_at > MAX_SAFE_TIME
            || (self.kind != "receipt" && self.expires_at <= now)
            || self.expires_at <= self.issued_at
            || self.expires_at - self.issued_at
                > if self.kind == "advertisement" {
                    900000
                } else {
                    120000
                }
            || !self.body.is_object()
            || serde_json::to_vec(&self.body)
                .map_err(|_| "Invalid Courier control")?
                .len()
                > 8192
        {
            return Err("Invalid Courier control".into());
        }
        if let Some(c) = &self.certificate {
            c.verify(now)?;
            if c.node_id != self.signer_id
                || c.signing_public_key != self.public_key
                || !["advertisement", "challenge", "stored"].contains(&self.kind.as_str())
            {
                return Err("Courier node role mismatch".into());
            }
        } else if ![
            "allocation",
            "store",
            "pickup",
            "receipt",
            "cancel",
            "inventory",
            "missing",
        ]
        .contains(&self.kind.as_str())
            || self.signer_id != format!("did:cht:{}", digest(decode::<32>(&self.public_key)?))
        {
            return Err("Courier owner role mismatch".into());
        }
        if self.kind == "pickup" {
            let bucket = self.body["bucket"]
                .as_u64()
                .ok_or("Invalid mailbox bucket")?;
            if self.body["mailbox"].as_str() != Some(&packages::mailbox(&self.public_key, bucket)?)
            {
                return Err("Mailbox binding mismatch".into());
            }
        }
        if self.kind == "receipt" {
            let body = self.body.as_object().ok_or("Invalid recipient receipt")?;
            let received = body
                .get("receivedAt")
                .and_then(Value::as_u64)
                .ok_or("Missing received time")?;
            if body.len() != 4
                || !body
                    .get("jobId")
                    .and_then(Value::as_str)
                    .is_some_and(|s| hex(s, 32))
                || !body
                    .get("manifestHash")
                    .and_then(Value::as_str)
                    .is_some_and(|s| hex(s, 64))
                || !body
                    .get("messageId")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty() && s.len() <= 256)
                || received > MAX_SAFE_TIME
                || received > self.issued_at.saturating_add(30000)
            {
                return Err("Invalid recipient receipt".into());
            }
        }
        verify_signature(&self.public_key, &self.signature, &self.payload()?)
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SignControl {
    #[serde(default)]
    node_state: Option<String>,
    kind: String,
    challenge: String,
    body: Value,
    now: u64,
    expires_at: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct VerifyControl {
    control: Control,
    expected_signer: String,
    challenge: String,
    now: u64,
}
pub(super) fn call(
    identity: &IdentityManager,
    operation: &str,
    args: Value,
) -> Result<Value, String> {
    match operation {
        "nodeCertificate" => {
            let a: NodeArgs = parse(args)?;
            if a.now > MAX_SAFE_TIME {
                return Err("Invalid Courier time".into());
            }
            let node = if let Some(state) = a.state {
                open_state::<NodeState>(identity, "node", &state)?
            } else {
                let key = random::<32>()?;
                let public = SigningKey::from_bytes(&key).verifying_key().to_bytes();
                let mut certificate = NodeCertificate {
                    version: 1,
                    owner_id: identity.public_identity().id.clone(),
                    root_public_key: identity.public_identity().root_public_key.clone(),
                    node_id: digest(public),
                    signing_public_key: B64.encode(public),
                    created_at: a.now,
                    signature: String::new(),
                };
                certificate.signature = B64.encode(
                    identity
                        .signing_key()
                        .sign(&certificate.payload()?)
                        .to_bytes(),
                );
                NodeState {
                    certificate,
                    signing_key: key,
                }
            };
            node.certificate.verify(a.now)?;
            if node.certificate.owner_id != identity.public_identity().id
                || node.certificate.signing_public_key
                    != B64.encode(
                        SigningKey::from_bytes(&node.signing_key)
                            .verifying_key()
                            .to_bytes(),
                    )
            {
                return Err("Courier node owner mismatch".into());
            }
            Ok(json!({"certificate":node.certificate,"state":seal_state(identity,"node",&node)?}))
        }
        "verifyNode" => {
            let a: VerifyNode = parse(args)?;
            a.certificate.verify(a.now)?;
            Ok(json!({"certificate":a.certificate}))
        }
        "signControl" => {
            let a: SignControl = parse(args)?;
            let (key, certificate, signer) = if let Some(state) = a.node_state {
                let node: NodeState = open_state(identity, "node", &state)?;
                (
                    SigningKey::from_bytes(&node.signing_key),
                    Some(node.certificate.clone()),
                    node.certificate.node_id.clone(),
                )
            } else {
                (
                    identity.signing_key(),
                    None,
                    identity.public_identity().id.clone(),
                )
            };
            let mut body = a.body;
            if a.kind == "pickup" {
                let object = body.as_object_mut().ok_or("Invalid pickup body")?;
                let bucket = object
                    .get("bucket")
                    .and_then(Value::as_u64)
                    .ok_or("Invalid mailbox bucket")?;
                object.insert(
                    "mailbox".into(),
                    json!(packages::mailbox(
                        &identity.public_identity().root_public_key,
                        bucket
                    )?),
                );
            }
            let mut c = Control {
                version: 1,
                kind: a.kind,
                signer_id: signer,
                public_key: B64.encode(key.verifying_key().to_bytes()),
                certificate,
                challenge: a.challenge,
                body,
                issued_at: a.now,
                expires_at: a.expires_at,
                signature: String::new(),
            };
            c.signature = B64.encode(key.sign(&c.payload()?).to_bytes());
            c.verify(a.now, &c.signer_id, &c.challenge)?;
            serde_json::to_value(c).map_err(|_| "Invalid Courier control".into())
        }
        "verifyControl" => {
            let a: VerifyControl = parse(args)?;
            a.control.verify(a.now, &a.expected_signer, &a.challenge)?;
            serde_json::to_value(a.control).map_err(|_| "Invalid Courier control".into())
        }
        _ => Err("Unknown Courier node operation".into()),
    }
}
