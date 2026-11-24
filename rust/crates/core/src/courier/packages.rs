use super::*;
use crate::delivery::{DeliveryEvent, canonical, digest, parse, valid_scope};
use crate::seed_signal::{MAX_SAFE_TIME, hex};
use serde::{Deserialize, Serialize};
use serde_json::json;
use zeroize::Zeroize;

const DAY: u64 = 86_400_000;
const PACKAGE: usize = 256 * 1024;
const MAX_COUNT: u32 = 40960;
const PATTERN: &str = "Noise_IK_25519_ChaChaPoly_SHA256";
fn trusted_peer(
    identity: &IdentityManager,
    contacts: &ContactStore,
    groups: &crate::groups::GroupEngine,
    scope: &str,
    peer: &str,
) -> Result<crate::PublicIdentity, String> {
    if scope.starts_with("group:") {
        groups.delivery_peer(&identity.public_identity().id, scope, peer)
    } else {
        contacts
            .verified_contact(peer)
            .map(|c| c.card.identity.clone())
            .map_err(|_| "Verify Courier peer first".into())
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct JobState {
    version: u32,
    job_id: String,
    sender: String,
    recipient: String,
    recipient_noise: String,
    scope: String,
    count: u32,
    expires_at: u64,
    mailbox: String,
    receipt_challenge: String,
    bucket: u64,
    key: [u8; 32],
    merkle_root: Option<String>,
}
impl Drop for JobState {
    fn drop(&mut self) {
        self.key.zeroize();
    }
}
impl JobState {
    fn validate(&self, now: u64) -> Result<(), String> {
        decode::<32>(&self.receipt_challenge)?;
        if self.bucket > MAX_SAFE_TIME / DAY
            || self.expires_at <= self.bucket * DAY
            || self.expires_at > (self.bucket + 2) * DAY
        {
            return Err("Invalid mailbox time binding".into());
        }
        if self.version != 1
            || !hex(&self.job_id, 32)
            || !valid_scope(&self.scope)
            || !(2..=MAX_COUNT).contains(&self.count)
            || now > MAX_SAFE_TIME
            || self.expires_at > MAX_SAFE_TIME
            || self.expires_at <= now
            || self.expires_at - now > DAY
            || !hex(&self.mailbox, 64)
            || self.merkle_root.as_ref().is_some_and(|r| !hex(r, 64))
        {
            return Err("Invalid Courier job".into());
        }
        Ok(())
    }
    fn aad(&self, index: u32) -> Result<Vec<u8>, String> {
        canonical(
            b"chta courier package v1\0",
            &(
                self.version,
                &self.job_id,
                index,
                self.count,
                &self.scope,
                self.expires_at,
            ),
        )
    }
}
// Root-bound tags remain reachable after phrase recovery rotates the contact token.
pub(super) fn mailbox(public: &str, bucket: u64) -> Result<String, String> {
    decode::<32>(public)?;
    if bucket > MAX_SAFE_TIME / DAY {
        return Err("Invalid mailbox bucket".into());
    }
    Ok(digest(canonical(
        b"chta courier mailbox v1\0",
        &(public, bucket),
    )?))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NewJob {
    peer_id: String,
    job_id: String,
    scope: String,
    count: u32,
    now: u64,
    expires_at: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MailboxArgs {
    #[serde(default)]
    peer_id: Option<String>,
    bucket: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EncryptArgs {
    state: String,
    index: u32,
    plaintext: String,
    now: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DecryptArgs {
    state: String,
    index: u32,
    ciphertext: String,
    proof: Vec<String>,
    now: u64,
}
fn leaf(index: u32, bytes: &[u8]) -> String {
    digest(
        [
            b"chta courier leaf v1\0".as_slice(),
            &index.to_be_bytes(),
            bytes,
        ]
        .concat(),
    )
}
fn from_hex(s: &str) -> Result<Vec<u8>, String> {
    if !hex(s, 64) {
        return Err("Invalid package hash".into());
    }
    (0..64)
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|_| "Invalid package hash".into()))
        .collect()
}
fn branch(a: &str, b: &str) -> Result<String, String> {
    Ok(digest(
        [
            b"chta courier branch v1\0".as_slice(),
            &from_hex(a)?,
            &from_hex(b)?,
        ]
        .concat(),
    ))
}
fn verify_path(
    mut hash: String,
    mut index: u32,
    mut count: u32,
    proof: &[String],
    root: &str,
) -> Result<(), String> {
    let mut level = 0;
    while count > 1 {
        let sibling = proof.get(level).ok_or("Missing package proof")?;
        if index % 2 == 0 && index + 1 == count && sibling != &hash {
            return Err("Invalid duplicate Merkle leaf".into());
        }
        hash = if index % 2 == 0 {
            branch(&hash, sibling)?
        } else {
            branch(sibling, &hash)?
        };
        index /= 2;
        count = count.div_ceil(2);
        level += 1;
    }
    if proof.len() != level || hash != root {
        return Err("Courier package root mismatch".into());
    }
    Ok(())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RootArgs {
    hashes: Vec<String>,
    index: usize,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Metadata {
    size: u64,
    content_hash: String,
    merkle_root: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    mime: String,
}
impl Metadata {
    fn validate(&self, state: &JobState) -> Result<(), String> {
        if self.size > 10 * 1024 * 1024 * 1024
            || self.size > u64::from(state.count) * PACKAGE as u64
            || !hex(&self.content_hash, 64)
            || !hex(&self.merkle_root, 64)
            || self.name.len() > 1024
            || self.name.contains('\0')
            || self.mime.len() > 256
            || self.mime.contains(['\0', '\r', '\n'])
        {
            return Err("Invalid Courier content metadata".into());
        }
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SealArgs {
    state: String,
    event: DeliveryEvent,
    metadata: Metadata,
    now: u64,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    state: JobState,
    event: DeliveryEvent,
    metadata: Metadata,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SealedManifest {
    version: u32,
    job_id: String,
    mailbox: String,
    expires_at: u64,
    #[serde(rename = "box")]
    ciphertext: String,
}
impl SealedManifest {
    fn prologue(&self) -> Result<Vec<u8>, String> {
        canonical(
            b"chta courier manifest box v1\0",
            &(self.version, &self.job_id, &self.mailbox, self.expires_at),
        )
    }
    fn hash(&self) -> Result<String, String> {
        Ok(digest(canonical(
            b"chta courier manifest digest v1\0",
            &(
                self.version,
                &self.job_id,
                &self.mailbox,
                self.expires_at,
                &self.ciphertext,
            ),
        )?))
    }
    fn validate(&self, now: u64) -> Result<(), String> {
        if self.version != 1
            || !hex(&self.job_id, 32)
            || !hex(&self.mailbox, 64)
            || now > MAX_SAFE_TIME
            || self.expires_at > MAX_SAFE_TIME
            || self.expires_at <= now
            || self.expires_at - now > DAY
        {
            return Err("Invalid sealed Courier manifest".into());
        }
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OpenArgs {
    manifest: SealedManifest,
    now: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PublicPackage {
    index: u32,
    count: u32,
    ciphertext: String,
    hash: String,
    root: String,
    proof: Vec<String>,
}
pub(super) fn call(
    identity: &IdentityManager,
    contacts: &ContactStore,
    groups: &crate::groups::GroupEngine,
    operation: &str,
    args: Value,
) -> Result<Value, String> {
    match operation {
        "inspectManifest" => {
            let a: OpenArgs = parse(args)?;
            a.manifest.validate(a.now)?;
            if decode_bytes(&a.manifest.ciphertext, 16384)?.len() < 96 {
                return Err("Truncated sealed manifest".into());
            }
            Ok(
                json!({"manifestHash":a.manifest.hash()?,"jobId":a.manifest.job_id,"mailbox":a.manifest.mailbox,"expiresAt":a.manifest.expires_at}),
            )
        }
        "verifyPackage" => {
            let a: PublicPackage = parse(args)?;
            if !(2..=MAX_COUNT).contains(&a.count)
                || a.index >= a.count
                || !hex(&a.root, 64)
                || a.proof.len() > 16
            {
                return Err("Invalid public package metadata".into());
            }
            let bytes = decode_bytes(&a.ciphertext, PACKAGE + 40)?;
            if bytes.len() < 40 || leaf(a.index, &bytes) != a.hash {
                return Err("Courier ciphertext hash mismatch".into());
            }
            verify_path(a.hash.clone(), a.index, a.count, &a.proof, &a.root)?;
            Ok(json!({"hash":a.hash,"index":a.index,"bytes":bytes.len()}))
        }
        "mailbox" => {
            let a: MailboxArgs = parse(args)?;
            let tag = if let Some(peer) = a.peer_id {
                let c = contacts
                    .verified_contact(&peer)
                    .map_err(|_| "Verify Courier recipient first")?;
                mailbox(&c.card.identity.root_public_key, a.bucket)?
            } else {
                mailbox(&identity.public_identity().root_public_key, a.bucket)?
            };
            Ok(json!({"mailbox":tag,"bucket":a.bucket}))
        }
        "newJob" => {
            let a: NewJob = parse(args)?;
            let peer = trusted_peer(identity, contacts, groups, &a.scope, &a.peer_id)?;
            if a.peer_id == identity.public_identity().id {
                return Err("Courier recipient must be another identity".into());
            }
            let state = JobState {
                version: 1,
                job_id: a.job_id,
                sender: identity.public_identity().id.clone(),
                recipient: a.peer_id,
                recipient_noise: peer.noise_static_public_key.clone(),
                scope: a.scope,
                count: a.count,
                expires_at: a.expires_at,
                mailbox: mailbox(&peer.root_public_key, a.now / DAY)?,
                key: random::<32>()?,
                receipt_challenge: B64.encode(random::<32>()?),
                bucket: a.now / DAY,
                merkle_root: None,
            };
            state.validate(a.now)?;
            Ok(
                json!({"state":seal_state(identity,"job",&state)?,"jobId":state.job_id,"mailbox":state.mailbox,"count":state.count,"expiresAt":state.expires_at,"receiptChallenge":state.receipt_challenge,"bucket":state.bucket}),
            )
        }
        "encryptPackage" => {
            let a: EncryptArgs = parse(args)?;
            let state: JobState = open_state(identity, "job", &a.state)?;
            state.validate(a.now)?;
            if state.sender != identity.public_identity().id || a.index >= state.count {
                return Err("Invalid package owner/index".into());
            }
            if state.scope.starts_with("group:") {
                trusted_peer(identity, contacts, groups, &state.scope, &state.recipient)?;
            }
            let plain = Zeroizing::new(decode_bytes(&a.plaintext, PACKAGE)?);
            let nonce = random::<24>()?;
            let ciphertext = XChaCha20Poly1305::new_from_slice(&state.key)
                .map_err(|_| "Invalid package key")?
                .encrypt(
                    XNonce::from_slice(&nonce),
                    Payload {
                        msg: &plain,
                        aad: &state.aad(a.index)?,
                    },
                )
                .map_err(|_| "Could not encrypt package")?;
            let bytes = [nonce.as_slice(), ciphertext.as_slice()].concat();
            Ok(json!({"index":a.index,"hash":leaf(a.index,&bytes),"ciphertext":B64.encode(&bytes)}))
        }
        "packageRoot" => {
            let a: RootArgs = parse(args)?;
            if !(2..=MAX_COUNT as usize).contains(&a.hashes.len())
                || a.index >= a.hashes.len()
                || a.hashes.iter().any(|h| !hex(h, 64))
            {
                return Err("Invalid package hashes".into());
            }
            let mut level = a.hashes;
            let mut index = a.index;
            let mut proof = Vec::new();
            while level.len() > 1 {
                proof.push(
                    level[if index % 2 == 1 {
                        index - 1
                    } else {
                        (index + 1).min(level.len() - 1)
                    }]
                    .clone(),
                );
                level = level
                    .chunks(2)
                    .map(|c| branch(&c[0], c.get(1).unwrap_or(&c[0])))
                    .collect::<Result<Vec<_>, _>>()?;
                index /= 2;
            }
            Ok(json!({"root":level[0],"proof":proof}))
        }
        "sealManifest" => {
            let a: SealArgs = parse(args)?;
            let mut state: JobState = open_state(identity, "job", &a.state)?;
            state.validate(a.now)?;
            let contact = trusted_peer(identity, contacts, groups, &state.scope, &state.recipient)?;
            if state.sender != identity.public_identity().id
                || contact.noise_static_public_key != state.recipient_noise
                || a.event.author_id != state.sender
                || a.event.scope != state.scope
            {
                return Err("Manifest owner/scope mismatch".into());
            }
            a.event.verify(a.now)?;
            a.metadata.validate(&state)?;
            state.merkle_root = Some(a.metadata.merkle_root.clone());
            let mut sealed = SealedManifest {
                version: 1,
                job_id: state.job_id.clone(),
                mailbox: state.mailbox.clone(),
                expires_at: state.expires_at,
                ciphertext: String::new(),
            };
            let remote = decode::<32>(&state.recipient_noise)?;
            let private = Zeroizing::new(identity.noise_static_secret().to_bytes());
            let plain = Zeroizing::new(
                serde_json::to_vec(&Manifest {
                    state,
                    event: a.event,
                    metadata: a.metadata,
                })
                .map_err(|_| "Invalid private manifest")?,
            );
            if plain.len() > 16000 {
                return Err("Private manifest too large".into());
            }
            let prologue = sealed.prologue()?;
            let mut noise =
                snow::Builder::new(PATTERN.parse().map_err(|_| "Invalid manifest protocol")?)
                    .prologue(&prologue)
                    .and_then(|b| b.local_private_key(&*private))
                    .and_then(|b| b.remote_public_key(&remote))
                    .and_then(|b| b.build_initiator())
                    .map_err(|_| "Could not prepare manifest")?;
            let mut output = vec![0u8; plain.len() + 96];
            let size = noise
                .write_message(&plain, &mut output)
                .map_err(|_| "Could not seal manifest")?;
            output.truncate(size);
            sealed.ciphertext = B64.encode(output);
            Ok(json!({"manifestHash":sealed.hash()?,"manifest":sealed}))
        }
        "openManifest" => {
            let a: OpenArgs = parse(args)?;
            a.manifest.validate(a.now)?;
            let encrypted = decode_bytes(&a.manifest.ciphertext, 16384)?;
            let private = Zeroizing::new(identity.noise_static_secret().to_bytes());
            let prologue = a.manifest.prologue()?;
            let mut noise =
                snow::Builder::new(PATTERN.parse().map_err(|_| "Invalid manifest protocol")?)
                    .prologue(&prologue)
                    .and_then(|b| b.local_private_key(&*private))
                    .and_then(|b| b.build_responder())
                    .map_err(|_| "Could not prepare manifest")?;
            let mut plain = Zeroizing::new(vec![0u8; 16384]);
            let size = noise
                .read_message(&encrypted, &mut plain)
                .map_err(|_| "Could not open manifest")?;
            let manifest: Manifest =
                serde_json::from_slice(&plain[..size]).map_err(|_| "Invalid private manifest")?;
            let s = &manifest.state;
            s.validate(a.now)?;
            manifest.event.verify(a.now)?;
            manifest.metadata.validate(s)?;
            let sender = trusted_peer(
                identity,
                contacts,
                groups,
                &s.scope,
                &manifest.event.author_id,
            )?;
            if s.mailbox != mailbox(&identity.public_identity().root_public_key, s.bucket)?
                || s.recipient != identity.public_identity().id
                || s.sender != sender.id
                || manifest.event.scope != s.scope
                || s.job_id != a.manifest.job_id
                || s.mailbox != a.manifest.mailbox
                || s.expires_at != a.manifest.expires_at
                || s.merkle_root.as_ref() != Some(&manifest.metadata.merkle_root)
                || noise.get_remote_static()
                    != Some(decode::<32>(&sender.noise_static_public_key)?.as_slice())
            {
                return Err("Manifest binding mismatch".into());
            }
            Ok(
                json!({"state":seal_state(identity,"job",s)?,"event":manifest.event,"metadata":manifest.metadata,"jobId":s.job_id,"count":s.count,"merkleRoot":s.merkle_root,"manifestHash":a.manifest.hash()?,"receiptChallenge":s.receipt_challenge,"bucket":s.bucket}),
            )
        }
        "decryptPackage" => {
            let a: DecryptArgs = parse(args)?;
            let state: JobState = open_state(identity, "job", &a.state)?;
            state.validate(a.now)?;
            if state.recipient != identity.public_identity().id
                || a.index >= state.count
                || a.proof.len() > 16
            {
                return Err("Invalid package recipient/index".into());
            }
            if state.scope.starts_with("group:") {
                trusted_peer(identity, contacts, groups, &state.scope, &state.sender)?;
            }
            let bytes = decode_bytes(&a.ciphertext, PACKAGE + 40)?;
            if bytes.len() < 40 {
                return Err("Truncated Courier package".into());
            }
            verify_path(
                leaf(a.index, &bytes),
                a.index,
                state.count,
                &a.proof,
                state
                    .merkle_root
                    .as_deref()
                    .ok_or("Missing manifest root")?,
            )?;
            let plain = Zeroizing::new(
                XChaCha20Poly1305::new_from_slice(&state.key)
                    .map_err(|_| "Invalid package key")?
                    .decrypt(
                        XNonce::from_slice(&bytes[..24]),
                        Payload {
                            msg: &bytes[24..],
                            aad: &state.aad(a.index)?,
                        },
                    )
                    .map_err(|_| "Could not authenticate package")?,
            );
            Ok(json!({"index":a.index,"plaintext":B64.encode(&*plain)}))
        }
        _ => Err("Unknown Courier package operation".into()),
    }
}
