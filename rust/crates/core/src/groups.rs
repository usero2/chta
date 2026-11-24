use crate::{ContactStore, IdentityManager, PublicIdentity, SecureSession};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

const MAX_TIME: u64 = 9_007_199_254_740_991;
const WEEK: u64 = 604_800_000;
const MAX_DOC: usize = 4 * 1024 * 1024;
const MAX_METADATA: usize = 1024 * 1024;
const MAX_CHAIN: usize = 256;
const MAX_TEXT: usize = 32_768;
const MAX_SESSIONS: usize = 64;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Capsule {
    group_id: String,
    owner_id: String,
    identity: PublicIdentity,
    display_name: String,
    signature: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct State {
    version: u8,
    group_id: String,
    epoch: u32,
    previous_hash: Option<String>,
    name: String,
    owner_id: String,
    owner_identity: PublicIdentity,
    members: Vec<Capsule>,
    closed: bool,
    issued_at: u64,
    signature: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Invite {
    version: u8,
    state: String,
    states: Vec<String>,
    recipient_id: String,
    nonce: String,
    issued_at: u64,
    expires_at: u64,
    signature: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Receipt {
    version: u8,
    invite: String,
    capsule: Capsule,
    accepted_at: u64,
    signature: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Event {
    version: u8,
    group_id: String,
    epoch: u32,
    sender: String,
    id: String,
    kind: String,
    payload: String,
    sent_at: u64,
    signature: String,
}
#[derive(Default)]
pub(crate) struct GroupEngine {
    states: BTreeMap<String, Vec<State>>,
    pending: BTreeMap<String, Invite>,
    sessions: BTreeMap<(String, String, String), SecureSession>,
    pub(crate) signal_replays: BTreeMap<(String, String, String), u64>,
}
fn valid_hex(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn valid_did(s: &str) -> bool {
    s.strip_prefix("did:cht:").is_some_and(|v| valid_hex(v, 64))
}
fn valid_group(s: &str) -> bool {
    s.strip_prefix("group:").is_some_and(|v| valid_hex(v, 64))
}
fn valid_name(s: &str) -> bool {
    let n = s.trim().chars().count();
    n > 0 && n <= 64 && !s.contains(['\0', '\r', '\n'])
}
fn verify_identity(i: &PublicIdentity) -> Result<(), String> {
    let key = URL_SAFE_NO_PAD
        .decode(&i.root_public_key)
        .map_err(|_| "Invalid root key")?;
    let noise = URL_SAFE_NO_PAD
        .decode(&i.noise_static_public_key)
        .map_err(|_| "Invalid Noise key")?;
    if key.len() != 32
        || noise.len() != 32
        || i.derivation_version != 1
        || i.id != format!("did:cht:{:x}", Sha256::digest(&key))
    {
        return Err("Invalid public identity".into());
    }
    Ok(())
}
fn canonical<T: Serialize>(value: &T) -> Result<Vec<u8>, String> {
    serde_json::to_vec(value).map_err(|e| e.to_string())
}
fn signed<T: Serialize>(
    domain: &[u8],
    value: &T,
    local: &IdentityManager,
) -> Result<String, String> {
    let mut payload = domain.to_vec();
    payload.extend(canonical(value)?);
    Ok(URL_SAFE_NO_PAD.encode(local.signing_key().sign(&payload).to_bytes()))
}
fn check<T: Serialize>(
    domain: &[u8],
    value: &T,
    signature: &str,
    public: &PublicIdentity,
) -> Result<(), String> {
    verify_identity(public)?;
    let key: [u8; 32] = URL_SAFE_NO_PAD
        .decode(&public.root_public_key)
        .map_err(|_| "Invalid key")?
        .try_into()
        .map_err(|_| "Invalid key")?;
    let sig: [u8; 64] = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|_| "Invalid signature")?
        .try_into()
        .map_err(|_| "Invalid signature")?;
    let mut payload = domain.to_vec();
    payload.extend(canonical(value)?);
    VerifyingKey::from_bytes(&key)
        .map_err(|_| "Invalid key")?
        .verify_strict(&payload, &Signature::from_bytes(&sig))
        .map_err(|_| "Invalid signature".into())
}
fn doc<T: for<'a> Deserialize<'a>>(s: &str) -> Result<T, String> {
    if s.len() > MAX_DOC {
        return Err("Group document too large".into());
    }
    serde_json::from_str(s).map_err(|_| "Invalid group document schema".into())
}
fn no_extra(args: &Value, allowed: &[&str]) -> Result<(), String> {
    let map = args.as_object().ok_or("Arguments must be an object")?;
    if map.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err("Unknown group argument".into());
    }
    Ok(())
}
fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing or invalid {key}"))
}
fn session_context(args: &Value) -> Result<&str, String> {
    match args.get("context") {
        None => Ok("groups"),
        Some(Value::String(s)) if s == "groups" || s == "dm-v2" => Ok(s),
        _ => Err("Invalid peer session context".into()),
    }
}
fn time_arg(args: &Value, key: &str) -> Result<u64, String> {
    let t = args
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("Missing or invalid {key}"))?;
    if t > MAX_TIME {
        return Err("Invalid time".into());
    }
    Ok(t)
}
fn nonce() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| e.to_string())?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}
impl Capsule {
    fn new(
        group_id: &str,
        owner_id: &str,
        display_name: &str,
        local: &IdentityManager,
    ) -> Result<Self, String> {
        if !valid_name(display_name) {
            return Err("Invalid member name".into());
        }
        let mut result = Self {
            group_id: group_id.into(),
            owner_id: owner_id.into(),
            identity: local.public_identity().clone(),
            display_name: display_name.into(),
            signature: String::new(),
        };
        result.signature = signed(
            b"chta group capsule v1\0",
            &(
                &result.group_id,
                &result.owner_id,
                &result.identity,
                &result.display_name,
            ),
            local,
        )?;
        Ok(result)
    }
    fn verify(&self, group_id: &str, owner_id: &str) -> Result<(), String> {
        if self.group_id != group_id || self.owner_id != owner_id || !valid_name(&self.display_name)
        {
            return Err("Invalid capsule binding".into());
        }
        check(
            b"chta group capsule v1\0",
            &(
                &self.group_id,
                &self.owner_id,
                &self.identity,
                &self.display_name,
            ),
            &self.signature,
            &self.identity,
        )
    }
}
impl State {
    fn fields(&self) -> impl Serialize + '_ {
        (
            &self.version,
            &self.group_id,
            &self.epoch,
            &self.previous_hash,
            &self.name,
            &self.owner_id,
            &self.owner_identity,
            &self.members,
            &self.closed,
            &self.issued_at,
        )
    }
    fn sign(&mut self, local: &IdentityManager) -> Result<(), String> {
        let signature = signed(b"chta group state v1\0", &self.fields(), local)?;
        self.signature = signature;
        Ok(())
    }
    fn verify(&self, prev: Option<&State>) -> Result<(), String> {
        if self.version != 1
            || !valid_group(&self.group_id)
            || !valid_name(&self.name)
            || self.issued_at > MAX_TIME
            || self.owner_id != self.owner_identity.id
            || self.members.is_empty()
            || self.members.len() > 16
        {
            return Err("Invalid group state".into());
        }
        check(
            b"chta group state v1\0",
            &self.fields(),
            &self.signature,
            &self.owner_identity,
        )?;
        let mut ids = BTreeSet::new();
        for member in &self.members {
            member.verify(&self.group_id, &self.owner_id)?;
            if !ids.insert(&member.identity.id) {
                return Err("Duplicate group member".into());
            }
        }
        if !ids.contains(&self.owner_id) {
            return Err("Missing owner".into());
        }
        let owner = self
            .members
            .iter()
            .find(|m| m.identity.id == self.owner_id)
            .unwrap();
        if owner.identity != self.owner_identity {
            return Err("Owner key mismatch".into());
        }
        match prev {
            None if self.epoch == 1
                && self.previous_hash.is_none()
                && !self.closed
                && self.members.len() == 1 => {}
            Some(p)
                if self.epoch == p.epoch + 1
                    && self.group_id == p.group_id
                    && self.owner_identity == p.owner_identity
                    && self.previous_hash.as_deref() == Some(&hash_state(p)?)
                    && self.issued_at >= p.issued_at
                    && !p.closed => {}
            _ => return Err("Group state chain mismatch".into()),
        }
        Ok(())
    }
}
fn hash_state(state: &State) -> Result<String, String> {
    Ok(format!("{:x}", Sha256::digest(canonical(state)?)))
}
impl Invite {
    fn fields(&self) -> impl Serialize + '_ {
        (
            &self.version,
            &self.state,
            &self.states,
            &self.recipient_id,
            &self.nonce,
            &self.issued_at,
            &self.expires_at,
        )
    }
    fn verify(&self, now: u64) -> Result<State, String> {
        let state: State = doc(&self.state)?;
        if self.states.is_empty()
            || self.states.len() > MAX_CHAIN
            || self.states.last() != Some(&self.state)
        {
            return Err("Invalid invite chain".into());
        }
        let mut previous: Option<State> = None;
        for source in &self.states {
            let member: State = doc(source)?;
            member.verify(previous.as_ref())?;
            if member.group_id != state.group_id {
                return Err("Invalid invite chain group".into());
            }
            previous = Some(member);
        }
        if self.version != 1
            || !valid_did(&self.recipient_id)
            || !valid_hex(&self.nonce, 64)
            || self.issued_at > MAX_TIME
            || self.expires_at > MAX_TIME
            || self.expires_at != self.issued_at.checked_add(WEEK).ok_or("Invalid expiry")?
            || now < self.issued_at.saturating_sub(30_000)
            || now >= self.expires_at
        {
            return Err("Invite expired or invalid".into());
        }
        check(
            b"chta group invite v1\0",
            &self.fields(),
            &self.signature,
            &state.owner_identity,
        )?;
        Ok(state)
    }
}
impl Receipt {
    fn fields(&self) -> impl Serialize + '_ {
        (
            &self.version,
            &self.invite,
            &self.capsule,
            &self.accepted_at,
        )
    }
    fn verify(&self) -> Result<Invite, String> {
        let invite: Invite = doc(&self.invite)?;
        let state: State = doc(&invite.state)?;
        if self.version != 1
            || self.capsule.identity.id != invite.recipient_id
            || self.accepted_at < invite.issued_at
            || self.accepted_at >= invite.expires_at
        {
            return Err("Invalid acceptance receipt".into());
        }
        self.capsule.verify(&state.group_id, &state.owner_id)?;
        check(
            b"chta group receipt v1\0",
            &self.fields(),
            &self.signature,
            &self.capsule.identity,
        )?;
        Ok(invite)
    }
}
impl Event {
    fn fields(&self) -> impl Serialize + '_ {
        (
            &self.version,
            &self.group_id,
            &self.epoch,
            &self.sender,
            &self.id,
            &self.kind,
            &self.payload,
            &self.sent_at,
        )
    }
}
impl GroupEngine {
    pub(crate) fn delivery_peer(
        &self,
        local: &str,
        scope: &str,
        peer: &str,
    ) -> Result<PublicIdentity, String> {
        let (gid, epoch) = scope
            .rsplit_once(':')
            .ok_or("Invalid group delivery scope")?;
        let epoch: u32 = epoch.parse().map_err(|_| "Invalid group delivery epoch")?;
        if !valid_group(gid) || scope != format!("{gid}:{epoch}") {
            return Err("Invalid group delivery scope".into());
        }
        let current = self.active(local, gid)?;
        if Self::member(current, peer).is_none() {
            return Err("Courier peer is no longer a group member".into());
        }
        let historical = self
            .states
            .get(gid)
            .and_then(|states| states.iter().find(|s| s.epoch == epoch))
            .ok_or("Unknown group delivery epoch")?;
        if historical.closed || Self::member(historical, local).is_none() {
            return Err("Not a member of delivery epoch".into());
        }
        Self::member(historical, peer)
            .map(|m| m.identity.clone())
            .ok_or("Peer is not a member of delivery epoch".into())
    }
    fn latest(&self, gid: &str) -> Result<&State, String> {
        self.states
            .get(gid)
            .and_then(|v| v.last())
            .ok_or("Unknown group".into())
    }
    fn member<'a>(state: &'a State, id: &str) -> Option<&'a Capsule> {
        state.members.iter().find(|m| m.identity.id == id)
    }
    fn active<'a>(&'a self, local: &str, gid: &str) -> Result<&'a State, String> {
        let state = self.latest(gid)?;
        if state.closed || Self::member(state, local).is_none() {
            return Err("Not an active group member".into());
        }
        Ok(state)
    }
    pub(crate) fn peer(
        &self,
        local: &str,
        contacts: &ContactStore,
        peer: &str,
    ) -> Option<PublicIdentity> {
        if let Ok(c) = contacts.verified_contact(peer) {
            return Some(c.card.identity.clone());
        }
        for states in self.states.values() {
            if let Some(state) = states.last()
                && !state.closed
                && Self::member(state, local).is_some()
                && let Some(m) = Self::member(state, peer)
            {
                return Some(m.identity.clone());
            }
        }
        None
    }
    fn apply(&mut self, state: State, local: &str) -> Result<Value, String> {
        let previous = self.states.get(&state.group_id).and_then(|v| v.last());
        if previous.is_none() && Self::member(&state, local).is_none() {
            return Err("Local identity not in genesis".into());
        }
        state.verify(previous)?;
        let gid = state.group_id.clone();
        let epoch = state.epoch;
        self.states.entry(gid.clone()).or_default().push(state);
        Ok(json!({"groupId":gid,"epoch":epoch}))
    }
    fn view(&self, gid: &str) -> Result<Value, String> {
        let chain = self.states.get(gid).ok_or("Unknown group")?;
        let state = chain.last().unwrap();
        Ok(
            json!({"groupId":gid,"name":state.name,"ownerId":state.owner_id,"epoch":state.epoch,
            "closed":state.closed,"members":state.members.iter().map(|m|json!({"identityId":m.identity.id,"displayName":m.display_name,"identity":m.identity})).collect::<Vec<_>>(),
            "states":chain.iter().map(|s|serde_json::to_string(s).unwrap()).collect::<Vec<_>>() }),
        )
    }
    fn import(&mut self, data: &str, local: &str, contacts: &ContactStore) -> Result<(), String> {
        if data.len() > 8 * 1024 * 1024 {
            return Err("Group export too large".into());
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Export {
            states: BTreeMap<String, Vec<State>>,
            pending: BTreeMap<String, Invite>,
        }
        let export: Export = doc_large(data)?;
        let mut next = BTreeMap::new();
        for (gid, chain) in export.states {
            if chain.is_empty() || chain.len() > MAX_CHAIN || chain[0].group_id != gid {
                return Err("Invalid imported group".into());
            }
            if !chain
                .iter()
                .any(|state| Self::member(state, local).is_some())
                && contacts
                    .verified_contact(&chain[0].owner_id)
                    .map_or(true, |c| c.card.identity != chain[0].owner_identity)
            {
                return Err("Imported group owner is not trusted".into());
            }
            for (i, state) in chain.iter().enumerate() {
                state.verify(if i == 0 { None } else { Some(&chain[i - 1]) })?
            }
            if let Some(current) = self.states.get(&gid)
                && (chain.len() < current.len()
                    || current
                        .iter()
                        .zip(&chain)
                        .any(|(a, b)| canonical(a).ok() != canonical(b).ok()))
            {
                return Err("Imported rollback or fork".into());
            }
            next.insert(gid, chain);
        }
        for (gid, chain) in &self.states {
            next.entry(gid.clone()).or_insert_with(|| chain.clone());
        }
        for (nonce, invite) in export.pending {
            if nonce != invite.nonce {
                return Err("Invalid pending invite".into());
            }
            let state = invite.verify(invite.issued_at)?;
            if state.owner_id != local || !next.contains_key(&state.group_id) {
                return Err("Invalid pending invite owner".into());
            }
            self.pending.insert(nonce, invite);
        }
        self.states = next;
        self.sessions.clear();
        Ok(())
    }
    pub(crate) fn call(
        &mut self,
        local: &IdentityManager,
        contacts: &ContactStore,
        op: &str,
        args: Value,
    ) -> Result<Value, String> {
        let mutating = matches!(
            op,
            "create" | "invite" | "accept" | "add" | "apply" | "remove" | "leave" | "import"
        );
        if !mutating {
            return self.call_inner(local, contacts, op, args);
        }
        let states = self.states.clone();
        let pending = self.pending.clone();
        let result = self
            .call_inner(local, contacts, op, args)
            .and_then(|value| {
                self.check_bounds()?;
                Ok(value)
            });
        if result.is_err() {
            self.states = states;
            self.pending = pending;
        }
        result
    }
    fn check_bounds(&self) -> Result<(), String> {
        if self.states.len() > 64
            || self.pending.len() > 1024
            || self.states.values().any(|v| v.len() > MAX_CHAIN)
            || canonical(&json!({"states":self.states,"pending":self.pending}))?.len()
                > MAX_METADATA
        {
            return Err("Group metadata limit reached; create another group".into());
        }
        for chain in self.states.values() {
            let last = chain.last().ok_or("Empty group chain")?;
            let invite = json!({"version":1,"state":serde_json::to_string(last).unwrap(),
                "states":chain.iter().map(|s|serde_json::to_string(s).unwrap()).collect::<Vec<_>>(),
                "recipientId":last.owner_id,"nonce":"0".repeat(64),"issuedAt":last.issued_at,
                "expiresAt":MAX_TIME,"signature":"A".repeat(86)})
            .to_string();
            let receipt=json!({"version":1,"invite":invite,"capsule":last.members[0],"acceptedAt":MAX_TIME,"signature":"A".repeat(86)}).to_string();
            if receipt.len() + 4096 > MAX_DOC {
                return Err("Group invitation metadata limit reached".into());
            }
        }
        Ok(())
    }
    fn call_inner(
        &mut self,
        local: &IdentityManager,
        contacts: &ContactStore,
        op: &str,
        args: Value,
    ) -> Result<Value, String> {
        let me = &local.public_identity().id;
        match op {
            "create" => {
                no_extra(&args, &["name", "displayName", "now"])?;
                let name = str_arg(&args, "name")?;
                let display = str_arg(&args, "displayName")?;
                let now = time_arg(&args, "now")?;
                if !valid_name(name) || !valid_name(display) {
                    return Err("Invalid group or member name".into());
                }
                let gid = format!("group:{}", nonce()?);
                let mut state = State {
                    version: 1,
                    group_id: gid.clone(),
                    epoch: 1,
                    previous_hash: None,
                    name: name.into(),
                    owner_id: me.clone(),
                    owner_identity: local.public_identity().clone(),
                    members: vec![Capsule::new(&gid, me, display, local)?],
                    closed: false,
                    issued_at: now,
                    signature: String::new(),
                };
                state.sign(local)?;
                state.verify(None)?;
                let result = serde_json::to_string(&state).map_err(|e| e.to_string())?;
                self.states.insert(gid, vec![state]);
                Ok(json!({"state":result}))
            }
            "invite" => {
                no_extra(&args, &["groupId", "peerId", "now"])?;
                let gid = str_arg(&args, "groupId")?;
                let peer = str_arg(&args, "peerId")?;
                let now = time_arg(&args, "now")?;
                let state = self.active(me, gid)?;
                if state.owner_id != *me || Self::member(state, peer).is_some() {
                    return Err("Only owner can invite a new member".into());
                }
                contacts.verified_contact(peer).map_err(|e| e.to_string())?;
                if let Some(existing) = self.pending.values().find(|v| {
                    v.recipient_id == peer
                        && v.expires_at > now
                        && doc::<State>(&v.state).is_ok_and(|s| s.group_id == gid)
                }) {
                    return Ok(
                        json!({"invite":serde_json::to_string(existing).map_err(|e|e.to_string())?}),
                    );
                }
                if state.members.len()
                    + self
                        .pending
                        .values()
                        .filter(|v| {
                            doc::<State>(&v.state)
                                .is_ok_and(|s| s.group_id == gid && v.expires_at > now)
                        })
                        .count()
                    >= 16
                {
                    return Err("Group is full".into());
                }
                let states = self
                    .states
                    .get(gid)
                    .unwrap()
                    .iter()
                    .map(|s| serde_json::to_string(s).unwrap())
                    .collect();
                let mut invite = Invite {
                    version: 1,
                    state: serde_json::to_string(state).unwrap(),
                    states,
                    recipient_id: peer.into(),
                    nonce: nonce()?,
                    issued_at: now,
                    expires_at: now
                        .checked_add(WEEK)
                        .filter(|t| *t <= MAX_TIME)
                        .ok_or("Invalid time")?,
                    signature: String::new(),
                };
                let signature = signed(b"chta group invite v1\0", &invite.fields(), local)?;
                invite.signature = signature;
                let result = serde_json::to_string(&invite).unwrap();
                self.pending.insert(invite.nonce.clone(), invite);
                Ok(json!({"invite":result}))
            }
            "inspectInvite" => {
                no_extra(&args, &["invite", "now"])?;
                let invite: Invite = doc(str_arg(&args, "invite")?)?;
                let state = invite.verify(time_arg(&args, "now")?)?;
                if invite.recipient_id != *me || Self::member(&state, me).is_some() {
                    return Err("Invite recipient mismatch".into());
                }
                let owner = contacts
                    .verified_contact(&state.owner_id)
                    .map_err(|e| e.to_string())?;
                if owner.card.identity != state.owner_identity {
                    return Err("Verified owner key mismatch".into());
                }
                Ok(
                    json!({"groupId":state.group_id,"name":state.name,"ownerId":state.owner_id,"expiresAt":invite.expires_at,"memberCount":state.members.len()}),
                )
            }
            "accept" => {
                no_extra(&args, &["invite", "displayName", "now"])?;
                let source = str_arg(&args, "invite")?;
                let display = str_arg(&args, "displayName")?;
                let now = time_arg(&args, "now")?;
                let invite: Invite = doc(source)?;
                let state = invite.verify(now)?;
                if invite.recipient_id != *me || Self::member(&state, me).is_some() {
                    return Err("Invite recipient mismatch".into());
                }
                let owner = contacts
                    .verified_contact(&state.owner_id)
                    .map_err(|e| e.to_string())?;
                if owner.card.identity != state.owner_identity {
                    return Err("Verified owner key mismatch".into());
                }
                if let Some(chain) = self.states.get(&state.group_id) {
                    if chain.len() > invite.states.len()
                        || chain.iter().enumerate().any(|(i, s)| {
                            serde_json::to_string(s).ok() != Some(invite.states[i].clone())
                        })
                    {
                        return Err("Stale or forked invitation".into());
                    }
                } else {
                    self.states.insert(
                        state.group_id.clone(),
                        invite
                            .states
                            .iter()
                            .map(|s| doc(s))
                            .collect::<Result<Vec<State>, String>>()?,
                    );
                }
                let capsule = Capsule::new(&state.group_id, &state.owner_id, display, local)?;
                let mut receipt = Receipt {
                    version: 1,
                    invite: source.into(),
                    capsule,
                    accepted_at: now,
                    signature: String::new(),
                };
                let signature = signed(b"chta group receipt v1\0", &receipt.fields(), local)?;
                receipt.signature = signature;
                Ok(
                    json!({"receipt":serde_json::to_string(&receipt).unwrap(),"groupId":state.group_id,"ownerId":state.owner_id}),
                )
            }
            "add" => {
                no_extra(&args, &["receipt", "now"])?;
                let receipt: Receipt = doc(str_arg(&args, "receipt")?)?;
                let now = time_arg(&args, "now")?;
                let invite = receipt.verify()?;
                let base = invite.verify(now)?;
                let state = self.active(me, &base.group_id)?;
                let base_local = self
                    .states
                    .get(&base.group_id)
                    .and_then(|v| v.iter().find(|s| s.epoch == base.epoch))
                    .ok_or("Unknown invite epoch")?;
                if state.owner_id != *me || hash_state(base_local)? != hash_state(&base)? {
                    return Err("Stale or foreign invite".into());
                }
                if !self.pending.contains_key(&invite.nonce)
                    || Self::member(state, &invite.recipient_id).is_some()
                    || state.members.len() >= 16
                {
                    return Err("Invite not pending or group full".into());
                }
                let mut next = state.clone();
                next.epoch += 1;
                next.previous_hash = Some(hash_state(state)?);
                next.issued_at = now;
                next.members.push(receipt.capsule);
                next.sign(local)?;
                next.verify(Some(state))?;
                let result = serde_json::to_string(&next).unwrap();
                self.states.get_mut(&base.group_id).unwrap().push(next);
                self.pending.remove(&invite.nonce);
                Ok(json!({"state":result}))
            }
            "apply" => {
                no_extra(&args, &["state"])?;
                self.apply(doc(str_arg(&args, "state")?)?, me)
            }
            "remove" => {
                no_extra(&args, &["groupId", "peerId", "now"])?;
                let gid = str_arg(&args, "groupId")?;
                let peer = str_arg(&args, "peerId")?;
                let now = time_arg(&args, "now")?;
                let state = self.active(me, gid)?;
                if state.owner_id != *me || peer == me || Self::member(state, peer).is_none() {
                    return Err("Invalid member removal".into());
                }
                let mut next = state.clone();
                next.epoch += 1;
                next.previous_hash = Some(hash_state(state)?);
                next.issued_at = now;
                next.members.retain(|m| m.identity.id != peer);
                next.sign(local)?;
                next.verify(Some(state))?;
                let result = serde_json::to_string(&next).unwrap();
                self.states.get_mut(gid).unwrap().push(next);
                Ok(json!({"state":result}))
            }
            "leave" => {
                no_extra(&args, &["groupId", "now"])?;
                let gid = str_arg(&args, "groupId")?;
                let now = time_arg(&args, "now")?;
                let state = self.active(me, gid)?;
                if state.owner_id == *me {
                    let mut next = state.clone();
                    next.epoch += 1;
                    next.previous_hash = Some(hash_state(state)?);
                    next.issued_at = now;
                    next.closed = true;
                    next.sign(local)?;
                    next.verify(Some(state))?;
                    let result = serde_json::to_string(&next).unwrap();
                    self.states.get_mut(gid).unwrap().push(next);
                    Ok(json!({"state":result}))
                } else {
                    self.sign_event(local, gid, &format!("leave-{now}"), "leave", "{}", now)
                }
            }
            "sign" => {
                no_extra(&args, &["groupId", "id", "kind", "payload", "now"])?;
                self.sign_event(
                    local,
                    str_arg(&args, "groupId")?,
                    str_arg(&args, "id")?,
                    str_arg(&args, "kind")?,
                    str_arg(&args, "payload")?,
                    time_arg(&args, "now")?,
                )
            }
            "inspect" => {
                no_extra(&args, &["event"])?;
                let event: Event = doc(str_arg(&args, "event")?)?;
                if event.version != 1
                    || event.id.is_empty()
                    || event.id.len() > 128
                    || event.payload.len() > MAX_TEXT
                    || event.sent_at > MAX_TIME
                    || !["message", "file", "ack", "leave"].contains(&event.kind.as_str())
                {
                    return Err("Invalid group event".into());
                }
                let state = self.active(me, &event.group_id)?;
                if Self::member(state, &event.sender).is_none() {
                    return Err("Sender is no longer a member".into());
                }
                let historical = self
                    .states
                    .get(&event.group_id)
                    .and_then(|chain| chain.iter().find(|s| s.epoch == event.epoch))
                    .ok_or("Unknown event epoch")?;
                if Self::member(historical, me).is_none() {
                    return Err("Recipient was not a member at event epoch".into());
                }
                let member = Self::member(historical, &event.sender)
                    .ok_or("Sender was not a member at event epoch")?;
                check(
                    b"chta group event v1\0",
                    &event.fields(),
                    &event.signature,
                    &member.identity,
                )?;
                Ok(
                    json!({"groupId":event.group_id,"epoch":event.epoch,"sender":event.sender,"id":event.id,"kind":event.kind,"payload":event.payload,"sentAt":event.sent_at}),
                )
            }
            "view" => {
                no_extra(&args, &["groupId"])?;
                self.view(str_arg(&args, "groupId")?)
            }
            "list" => {
                no_extra(&args, &[])?;
                Ok(
                    json!({"groups":self.states.keys().map(|g|self.view(g).unwrap()).collect::<Vec<_>>()}),
                )
            }
            "export" => {
                no_extra(&args, &[])?;
                Ok(json!({"data":json!({"states":self.states,"pending":self.pending}).to_string()}))
            }
            "import" => {
                no_extra(&args, &["data"])?;
                self.import(str_arg(&args, "data")?, me, contacts)?;
                Ok(json!({}))
            }
            "authorize" => {
                no_extra(&args, &["peerId", "groupId", "epoch"])?;
                let peer = str_arg(&args, "peerId")?;
                if !valid_did(peer) {
                    return Err("Invalid peer ID".into());
                }
                let result = if let Some(gid) = args.get("groupId").and_then(Value::as_str) {
                    if !valid_group(gid) {
                        return Err("Invalid group ID".into());
                    }
                    let current = match self.active(me, gid) {
                        Ok(s) => s,
                        Err(_) => return Ok(json!({"allowed":false})),
                    };
                    let old = if let Some(epoch) = args.get("epoch") {
                        let n = epoch.as_u64().ok_or("Invalid epoch")?;
                        self.states
                            .get(gid)
                            .unwrap()
                            .iter()
                            .find(|s| s.epoch as u64 == n)
                    } else {
                        Some(current)
                    };
                    if Self::member(current, peer).is_some()
                        && old.is_some_and(|s| {
                            Self::member(s, peer).is_some() && Self::member(s, me).is_some()
                        })
                    {
                        Self::member(current, peer).map(|m| m.identity.clone())
                    } else {
                        None
                    }
                } else if args.get("groupId").is_some() || args.get("epoch").is_some() {
                    return Err("Invalid group authorization arguments".into());
                } else {
                    self.peer(me, contacts, peer)
                };
                if let Some(identity) = result {
                    Ok(json!({"allowed":true,"identity":identity}))
                } else {
                    Ok(json!({"allowed":false}))
                }
            }
            "prepare" => {
                no_extra(&args, &["peerId", "sessionId", "initiator", "context"])?;
                let peer = str_arg(&args, "peerId")?;
                let sid = str_arg(&args, "sessionId")?;
                let context = session_context(&args)?;
                let initiator = args
                    .get("initiator")
                    .and_then(Value::as_bool)
                    .ok_or("Invalid initiator")?;
                if !valid_hex(sid, 32)
                    || peer == me
                    || self
                        .sessions
                        .keys()
                        .filter(|(_, _, c)| c == context)
                        .count()
                        >= if context == "groups" {
                            MAX_SESSIONS
                        } else {
                            16
                        }
                    || self
                        .sessions
                        .contains_key(&(peer.into(), sid.into(), context.into()))
                {
                    return Err("Invalid or full group session registry".into());
                }
                let identity = if context == "dm-v2" {
                    contacts
                        .verified_contact(peer)
                        .map_err(|e| e.to_string())?
                        .card
                        .identity
                        .clone()
                } else {
                    self.peer(me, contacts, peer)
                        .ok_or("Unauthorized group peer")?
                };
                let session = SecureSession::contextual(local, &identity, initiator, sid, context)
                    .map_err(|e| e.to_string())?;
                self.sessions
                    .insert((peer.into(), sid.into(), context.into()), session);
                Ok(json!({}))
            }
            "start" | "handshake" | "encrypt" | "decrypt" | "closeSession" => {
                let mut allowed = match op {
                    "start" | "closeSession" => vec!["peerId", "sessionId"],
                    "handshake" | "decrypt" => vec!["peerId", "sessionId", "frame"],
                    _ => vec!["peerId", "sessionId", "id", "text"],
                };
                allowed.push("context");
                no_extra(&args, &allowed)?;
                let peer = str_arg(&args, "peerId")?;
                let sid = str_arg(&args, "sessionId")?;
                let context = session_context(&args)?;
                if op == "closeSession" {
                    self.sessions
                        .remove(&(peer.into(), sid.into(), context.into()));
                    return Ok(json!({}));
                }
                if (context == "dm-v2" && contacts.verified_contact(peer).is_err())
                    || (context == "groups" && self.peer(me, contacts, peer).is_none())
                {
                    return Err("Unauthorized group peer".into());
                }
                let session = self
                    .sessions
                    .get_mut(&(peer.into(), sid.into(), context.into()))
                    .ok_or("Unknown group session")?;
                match op {
                    "start" => Ok(
                        json!({"frame":URL_SAFE_NO_PAD.encode(session.start_handshake().map_err(|e|e.to_string())?)}),
                    ),
                    "handshake" => {
                        let frame = URL_SAFE_NO_PAD
                            .decode(str_arg(&args, "frame")?)
                            .map_err(|_| "Invalid handshake frame")?;
                        if frame.len() > 1024 {
                            return Err("Handshake frame too large".into());
                        }
                        let reply = session
                            .receive_handshake(&frame)
                            .map_err(|e| e.to_string())?
                            .map(|f| URL_SAFE_NO_PAD.encode(f));
                        Ok(json!({"reply":reply,"established":session.is_established()}))
                    }
                    "encrypt" => {
                        let id = str_arg(&args, "id")?;
                        let text = str_arg(&args, "text")?;
                        if id.is_empty() || id.len() > 128 || text.len() > MAX_TEXT {
                            return Err("Group frame too large".into());
                        }
                        let frame = session
                            .encrypt_message(id, text.as_bytes())
                            .map_err(|e| e.to_string())?;
                        Ok(json!({"frame":URL_SAFE_NO_PAD.encode(frame)}))
                    }
                    _ => {
                        let frame = URL_SAFE_NO_PAD
                            .decode(str_arg(&args, "frame")?)
                            .map_err(|_| "Invalid ciphertext")?;
                        if frame.len() > 65_535 {
                            return Err("Group frame too large".into());
                        }
                        let message = session.decrypt_message(&frame).map_err(|e| e.to_string())?;
                        let text =
                            String::from_utf8(message.plaintext).map_err(|_| "Invalid text")?;
                        if text.len() > MAX_TEXT {
                            return Err("Group text too large".into());
                        }
                        Ok(
                            json!({"id":message.message_id,"text":text,"duplicate":message.duplicate}),
                        )
                    }
                }
            }
            "signSignal" | "inspectSignal" => {
                crate::groups_signal::call(self, local, contacts, op, args)
            }
            _ => Err("Unknown group operation".into()),
        }
    }
    fn sign_event(
        &self,
        local: &IdentityManager,
        gid: &str,
        id: &str,
        kind: &str,
        payload: &str,
        now: u64,
    ) -> Result<Value, String> {
        let state = self.active(&local.public_identity().id, gid)?;
        if id.is_empty()
            || id.len() > 128
            || payload.len() > MAX_TEXT
            || !["message", "file", "ack", "leave"].contains(&kind)
            || serde_json::from_str::<Value>(payload).is_err()
        {
            return Err("Invalid event".into());
        }
        let mut event = Event {
            version: 1,
            group_id: gid.into(),
            epoch: state.epoch,
            sender: local.public_identity().id.clone(),
            id: id.into(),
            kind: kind.into(),
            payload: payload.into(),
            sent_at: now,
            signature: String::new(),
        };
        let signature = signed(b"chta group event v1\0", &event.fields(), local)?;
        event.signature = signature;
        Ok(json!({"event":serde_json::to_string(&event).unwrap()}))
    }
}
fn doc_large<T: for<'a> Deserialize<'a>>(s: &str) -> Result<T, String> {
    serde_json::from_str(s).map_err(|_| "Invalid group export".into())
}
