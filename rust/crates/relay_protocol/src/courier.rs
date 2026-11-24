use super::{B64, Signature, VerifyingKey, key_id, validate_endpoint};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Certificate {
    version: u32,
    owner_id: String,
    root_public_key: String,
    node_id: String,
    signing_public_key: String,
    created_at: u64,
    signature: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Advertisement {
    version: u32,
    kind: String,
    signer_id: String,
    public_key: String,
    certificate: Certificate,
    challenge: String,
    body: Body,
    issued_at: u64,
    expires_at: u64,
    signature: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Body {
    version: u32,
    node_id: String,
    owner_id: String,
    routes: Vec<String>,
    max_package_bytes: u32,
    free_bytes: u64,
}
fn raw<const N: usize>(s: &str) -> Result<[u8; N], String> {
    let b = B64.decode(s).map_err(|_| "Invalid Courier key")?;
    if B64.encode(&b) != s {
        return Err("Noncanonical Courier key".into());
    }
    b.try_into().map_err(|_| "Invalid Courier key size".into())
}
fn verify(key: &str, sig: &str, domain: &[u8], payload: &impl Serialize) -> Result<(), String> {
    let key =
        VerifyingKey::from_bytes(&raw::<32>(key)?).map_err(|_| "Invalid Courier signing key")?;
    let mut bytes = domain.to_vec();
    bytes.extend(serde_json::to_vec(payload).map_err(|_| "Invalid Courier metadata")?);
    key.verify_strict(&bytes, &Signature::from_bytes(&raw::<64>(sig)?))
        .map_err(|_| "Invalid Courier signature".into())
}
pub fn verify_courier_advertisement(
    value: &Value,
    now: u64,
    allow_loopback: bool,
) -> Result<(), String> {
    if value.to_string().len() > 4096 {
        return Err("Courier advertisement too large".into());
    }
    let a: Advertisement = serde_json::from_value(value.clone())
        .map_err(|_| "Invalid Courier advertisement schema")?;
    let n = &a.certificate;
    let b = &a.body;
    if a.version != 1
        || a.kind != "advertisement"
        || a.challenge != B64.encode([0u8; 32])
        || n.version != 1
        || n.owner_id != format!("did:cht:{}", key_id(&raw::<32>(&n.root_public_key)?))
        || n.node_id != key_id(&raw::<32>(&n.signing_public_key)?)
        || a.signer_id != n.node_id
        || a.public_key != n.signing_public_key
        || n.created_at > now.saturating_add(30000)
        || now > 9007199254740991
        || a.issued_at > now.saturating_add(30000)
        || a.expires_at > 9007199254740991
        || a.expires_at <= now
        || a.expires_at <= a.issued_at
        || a.expires_at - a.issued_at > 900000
        || b.version != 1
        || b.node_id != n.node_id
        || b.owner_id != n.owner_id
        || b.max_package_bytes != 262144
        || b.free_bytes > 1099511627776
        || b.routes.is_empty()
        || b.routes.len() > 8
    {
        return Err("Invalid Courier advertisement".into());
    }
    let mut routes = std::collections::HashSet::new();
    for route in &b.routes {
        validate_endpoint(route, allow_loopback)?;
        if !routes.insert(route) {
            return Err("Repeated Courier route".into());
        }
    }
    verify(
        &n.root_public_key,
        &n.signature,
        b"chta courier node certificate v1\0",
        &(
            n.version,
            &n.owner_id,
            &n.root_public_key,
            &n.node_id,
            &n.signing_public_key,
            n.created_at,
        ),
    )?;
    // Body is a JSON Value in the signing core: its object keys are sorted.
    let body = serde_json::to_value(b).map_err(|_| "Invalid Courier body")?;
    verify(
        &a.public_key,
        &a.signature,
        b"chta courier control v1\0",
        &(
            a.version,
            &a.kind,
            &a.signer_id,
            &a.public_key,
            n,
            &a.challenge,
            body,
            a.issued_at,
            a.expires_at,
        ),
    )
}
#[derive(Default)]
pub struct CourierCatalog {
    records: BTreeMap<String, Value>,
    cursor: usize,
}
impl CourierCatalog {
    pub fn merge(
        &mut self,
        records: &[Value],
        now: u64,
        allow_loopback: bool,
    ) -> Result<(), String> {
        if records.len() > 8 {
            return Err("Courier discovery batch too large".into());
        }
        for r in records {
            verify_courier_advertisement(r, now, allow_loopback)?;
        }
        self.records
            .retain(|_, r| r["expiresAt"].as_u64().is_some_and(|t| t > now));
        for r in records {
            let id = r["signerId"].as_str().ok_or("Missing Courier ID")?;
            if let Some(old) = self.records.get(id) {
                if old["issuedAt"].as_u64() >= r["issuedAt"].as_u64() {
                    continue;
                }
            } else if self.records.len() >= 256
                || self
                    .records
                    .values()
                    .filter(|v| v["certificate"]["ownerId"] == r["certificate"]["ownerId"])
                    .count()
                    >= 8
            {
                continue;
            }
            self.records.insert(id.to_owned(), r.clone());
        }
        Ok(())
    }
    pub fn batch(&mut self, now: u64) -> Vec<Value> {
        self.records
            .retain(|_, r| r["expiresAt"].as_u64().is_some_and(|t| t > now));
        let all: Vec<_> = self.records.values().collect();
        if all.is_empty() {
            return vec![];
        }
        let mut out = vec![];
        for i in 0..8.min(all.len()) {
            let r = all[(self.cursor + i) % all.len()];
            let mut test = out.clone();
            test.push(r.clone());
            if json!(test).to_string().len() > 12000 {
                break;
            }
            out.push(r.clone());
        }
        self.cursor = (self.cursor + out.len()) % all.len();
        out
    }
}
