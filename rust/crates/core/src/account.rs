use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Serialize;

use crate::{
    ContactError, ContactStore, IdentityError, IdentityManager, SecureSession, SessionError,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountError {
    Identity(IdentityError),
    Contact(ContactError),
    Session(SessionError),
    IdentityUnavailable,
}

impl std::fmt::Display for AccountError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Identity(error) => error.fmt(formatter),
            Self::Contact(error) => error.fmt(formatter),
            Self::Session(error) => error.fmt(formatter),
            Self::IdentityUnavailable => formatter.write_str("identity is not available"),
        }
    }
}

impl std::error::Error for AccountError {}

impl From<IdentityError> for AccountError {
    fn from(value: IdentityError) -> Self {
        Self::Identity(value)
    }
}

impl From<ContactError> for AccountError {
    fn from(value: ContactError) -> Self {
        Self::Contact(value)
    }
}

impl From<SessionError> for AccountError {
    fn from(value: SessionError) -> Self {
        Self::Session(value)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CreatedIdentity<'a> {
    mnemonic: &'a str,
    identity: &'a crate::PublicIdentity,
}

pub struct AccountCore {
    identity: Option<IdentityManager>,
    contacts: ContactStore,
    session: Option<SecureSession>,
    seed_replays: std::cell::RefCell<std::collections::BTreeMap<(String, String, String), u64>>,
    groups: crate::groups::GroupEngine,
}

impl AccountCore {
    pub fn delivery_call(&self, operation:&str,args:serde_json::Value)->Result<serde_json::Value,String>{
        let identity=self.identity.as_ref().ok_or("Unlock an identity before delivery")?;
        crate::delivery::call(identity,&self.contacts,&self.groups,operation,args)
    }
    pub fn contact_request_call(&self, operation: &str, args: serde_json::Value) -> Result<serde_json::Value, String> {
        let identity = self.identity.as_ref().ok_or("Unlock an identity before contact setup")?;
        crate::contact_requests::call(identity, &self.contacts, operation, args)
    }
    pub fn sign_seed_dispatch(&self, seed_id: &str, connection: &str, sequence: u64, envelope_json: &str) -> Result<String, String> {
        if envelope_json.len() > 15_500 { return Err("Seed envelope too large".into()); }
        let identity = self.identity.as_ref().ok_or("Identity unavailable")?;
        let envelope = serde_json::from_str(envelope_json).map_err(|_|"Invalid seed envelope")?;
        let proof = crate::seed_dispatch::SeedDispatch::signed(&identity.signing_key(), seed_id, connection, sequence, &envelope)?;
        serde_json::to_string(&proof).map_err(|e|e.to_string())
    }

    pub fn sign_seed_signal(
        &self,
        peer_id: &str,
        message_id: &str,
        text: &str,
        now: u64,
    ) -> Result<String, String> {
        let identity = self
            .identity
            .as_ref()
            .ok_or("Unlock an identity before seed signaling")?;
        self.contacts
            .verified_contact(peer_id)
            .map_err(|e| e.to_string())?;
        serde_json::to_string(&crate::seed_signal::SeedSignal::signed(
            &identity.signing_key(),
            peer_id,
            message_id,
            text,
            now,
        )?)
        .map_err(|e| e.to_string())
    }
    pub fn inspect_seed_signal(
        &self,
        source: &str,
        expected_peer: &str,
        now: u64,
    ) -> Result<String, String> {
        let identity = self
            .identity
            .as_ref()
            .ok_or("Unlock an identity before seed signaling")?;
        let peer = self
            .contacts
            .verified_contact(expected_peer)
            .map_err(|e| e.to_string())?;
        let signal = crate::seed_signal::SeedSignal::inspect(source, now)?;
        if signal.to != identity.public_identity().id
            || signal.from != expected_peer
            || signal.public_key != peer.card.identity.root_public_key
        {
            return Err("Seed signal owner or verified contact key mismatch".into());
        }
        let mut replays = self.seed_replays.borrow_mut();
        replays.retain(|_, expiry| *expiry > now);
        let key = (
            signal.from.clone(),
            signal.id.clone(),
            signal.signature.clone(),
        );
        if replays.contains_key(&key) {
            return Err("Replayed seed signal".into());
        }
        if replays.len() >= 4096 {
            return Err("Seed replay window full".into());
        }
        let result = serde_json::to_string(
            &serde_json::json!({"peerId":signal.from,"messageId":signal.id,"text":signal.payload}),
        )
        .map_err(|e| e.to_string())?;
        replays.insert(key, signal.expires_at);
        Ok(result)
    }
    pub fn relay_proof_json(&self, nonce: &str, relay_id: &str) -> Result<String, String> {
        serde_json::to_string(&self.sign_relay_proof(nonce, relay_id)?).map_err(|e| e.to_string())
    }
    pub(crate) fn sign_relay_proof(
        &self,
        nonce: &str,
        relay_id: &str,
    ) -> Result<crate::relay_directory::RelayProof, String> {
        let identity = self
            .identity
            .as_ref()
            .ok_or("Unlock an identity before connecting to a relay")?;
        crate::relay_directory::RelayProof::signed(&identity.signing_key(), nonce, relay_id)
    }
    pub fn new(
        encrypted_secret_plaintext: Option<&[u8]>,
        contacts_json: Option<&str>,
    ) -> Result<Self, AccountError> {
        let identity = encrypted_secret_plaintext
            .map(IdentityManager::from_secret)
            .transpose()?;
        let contacts = contacts_json
            .map(ContactStore::from_json)
            .transpose()?
            .unwrap_or_default();
        Ok(Self {
            identity,
            contacts,
            session: None,
            seed_replays: Default::default(),
            groups: Default::default(),
        })
    }

    pub fn has_identity(&self) -> bool {
        self.identity.is_some()
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) fn confirmed_secret(&self) -> Result<Vec<u8>, AccountError> {
        Ok(self
            .identity
            .as_ref()
            .ok_or(AccountError::IdentityUnavailable)?
            .export_confirmed_secret()?)
    }

    pub fn create_identity_json(&mut self) -> Result<String, AccountError> {
        self.identity = Some(IdentityManager::create()?);
        self.session = None;
        self.groups = Default::default();
        self.seed_replays.borrow_mut().clear();
        let identity = self.identity.as_ref().expect("identity was just assigned");
        serde_json::to_string(&CreatedIdentity {
            mnemonic: identity.mnemonic(),
            identity: identity.public_identity(),
        })
        .map_err(|error| AccountError::Identity(IdentityError::InvalidSecret(error.to_string())))
    }

    pub fn discard_pending_identity(&mut self) {
        self.identity = None;
        self.session = None;
        self.groups = Default::default();
    }

    pub fn confirm_recovery(&mut self, phrase: &str) -> Result<Vec<u8>, AccountError> {
        let identity = self
            .identity
            .as_mut()
            .ok_or(AccountError::IdentityUnavailable)?;
        identity.confirm_recovery(phrase)?;
        Ok(identity.export_confirmed_secret()?)
    }

    pub fn restore_identity_json(
        &mut self,
        phrase: &str,
    ) -> Result<(String, Vec<u8>), AccountError> {
        let identity = IdentityManager::restore(phrase)?;
        let public = serde_json::to_string(identity.public_identity()).map_err(|error| {
            AccountError::Identity(IdentityError::InvalidSecret(error.to_string()))
        })?;
        let secret = identity.export_secret();
        self.identity = Some(identity);
        self.session = None;
        self.groups = Default::default();
        Ok((public, secret))
    }

    pub fn identity_json(&self) -> Result<String, AccountError> {
        let identity = self
            .identity
            .as_ref()
            .ok_or(AccountError::IdentityUnavailable)?;
        serde_json::to_string(identity.public_identity()).map_err(|error| {
            AccountError::Identity(IdentityError::InvalidSecret(error.to_string()))
        })
    }

    pub fn group_call(
        &mut self,
        operation: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let identity = self
            .identity
            .as_ref()
            .ok_or("Unlock an identity before using groups")?;
        self.groups.call(identity, &self.contacts, operation, args)
    }

    pub fn contact_card_json(&self) -> Result<String, AccountError> {
        self.contact_card_json_with_name("")
    }

    pub fn contact_card_json_with_name(&self, display_name: &str) -> Result<String, AccountError> {
        self.contact_card_json_with_profile(display_name, "")
    }

    pub fn contact_card_json_with_profile(
        &self,
        display_name: &str,
        avatar: &str,
    ) -> Result<String, AccountError> {
        self.contact_card_json_with_relays(display_name, avatar, &[])
    }

    pub fn contact_card_json_with_relays(
        &self,
        display_name: &str,
        avatar: &str,
        relay_urls: &[String],
    ) -> Result<String, AccountError> {
        self.identity
            .as_ref()
            .ok_or(AccountError::IdentityUnavailable)?
            .contact_card_with_relays(display_name, avatar, relay_urls)?
            .to_json()
            .map_err(Into::into)
    }

    pub fn contacts_json(&self) -> Result<String, AccountError> {
        self.contacts.list_json().map_err(Into::into)
    }

    pub fn inspect_contact_card_json(&self, card_json: &str) -> Result<String, AccountError> {
        let contact = ContactStore::verify_card(card_json)?;
        serde_json::to_string(&contact)
            .map_err(|error| AccountError::Contact(ContactError::InvalidCard(error.to_string())))
    }

    pub fn contacts_state_json(&self) -> Result<String, AccountError> {
        self.contacts.to_json().map_err(Into::into)
    }

    pub fn restore_contacts_state_json(&mut self, source: &str) -> Result<(), AccountError> {
        let restored = ContactStore::from_json(source)?;
        self.contacts = restored;
        Ok(())
    }

    pub fn add_contact(
        &mut self,
        card_json: &str,
        display_name: &str,
    ) -> Result<String, AccountError> {
        self.contacts.add_card(card_json, display_name)?;
        self.contacts_json()
    }

    pub fn mark_contact_verified(&mut self, identity_id: &str) -> Result<String, AccountError> {
        self.contacts.mark_verified(identity_id)?;
        self.contacts_json()
    }

    pub fn set_contact_alias(
        &mut self,
        identity_id: &str,
        alias: &str,
    ) -> Result<String, AccountError> {
        self.contacts.set_alias(identity_id, alias)?;
        self.contacts_json()
    }

    pub fn remove_contact(&mut self, identity_id: &str) -> Result<String, AccountError> {
        self.contacts.remove(identity_id)?;
        self.contacts_json()
    }

    pub fn prepare_peer(
        &mut self,
        card_json: &str,
        initiator: bool,
    ) -> Result<String, AccountError> {
        let verified = ContactStore::verify_card(card_json)?;
        self.contacts.verified_contact(&verified.identity_id)?;
        let identity = self
            .identity
            .as_ref()
            .ok_or(AccountError::IdentityUnavailable)?;
        let session = if initiator {
            SecureSession::initiator(identity, &verified.card.identity)?
        } else {
            SecureSession::responder(identity, &verified.card.identity)?
        };
        let identity_id = verified.identity_id.clone();
        self.contacts.refresh_card(verified)?;
        self.session = Some(session);
        Ok(identity_id)
    }

    pub fn start_peer_handshake(&mut self) -> Result<String, AccountError> {
        let frame = self
            .session
            .as_mut()
            .ok_or(AccountError::IdentityUnavailable)?
            .start_handshake()?;
        Ok(URL_SAFE_NO_PAD.encode(frame))
    }

    pub fn receive_peer_handshake(&mut self, encoded: &str) -> Result<String, AccountError> {
        let frame = URL_SAFE_NO_PAD.decode(encoded).map_err(|error| {
            AccountError::Session(SessionError::InvalidEnvelope(error.to_string()))
        })?;
        let session = self
            .session
            .as_mut()
            .ok_or(AccountError::IdentityUnavailable)?;
        let reply = session
            .receive_handshake(&frame)?
            .map(|value| URL_SAFE_NO_PAD.encode(value));
        serde_json::to_string(&serde_json::json!({
            "reply": reply,
            "established": session.is_established(),
        }))
        .map_err(|error| AccountError::Session(SessionError::InvalidEnvelope(error.to_string())))
    }

    pub fn encrypt_peer_message(
        &mut self,
        message_id: &str,
        text: &str,
    ) -> Result<String, AccountError> {
        self.encrypt_peer_message_at(message_id, text, None)
    }

    pub fn encrypt_peer_message_at(
        &mut self,
        message_id: &str,
        text: &str,
        sent_at_milliseconds: Option<i64>,
    ) -> Result<String, AccountError> {
        let frame = self
            .session
            .as_mut()
            .ok_or(AccountError::IdentityUnavailable)?
            .encrypt_message_at(message_id, text.as_bytes(), sent_at_milliseconds)?;
        Ok(URL_SAFE_NO_PAD.encode(frame))
    }

    pub fn decrypt_peer_message(&mut self, encoded: &str) -> Result<String, AccountError> {
        let frame = URL_SAFE_NO_PAD.decode(encoded).map_err(|error| {
            AccountError::Session(SessionError::InvalidEnvelope(error.to_string()))
        })?;
        let message = self
            .session
            .as_mut()
            .ok_or(AccountError::IdentityUnavailable)?
            .decrypt_message(&frame)?;
        let text = String::from_utf8(message.plaintext).map_err(|error| {
            AccountError::Session(SessionError::InvalidEnvelope(error.to_string()))
        })?;
        serde_json::to_string(&serde_json::json!({
            "messageId": message.message_id,
            "text": text,
            "duplicate": message.duplicate,
            "sentAtMilliseconds": message.sent_at_milliseconds,
        }))
        .map_err(|error| AccountError::Session(SessionError::InvalidEnvelope(error.to_string())))
    }
}

#[cfg(test)]
mod seed_tests {
    use super::*;
    #[test]
    fn seed_replay_window_is_bounded_and_prunes_expired_entries() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../apps/web_portal/test/fixtures/seed-signal.json"
        ))
        .unwrap();
        let secret=serde_json::json!({"derivationVersion":1,"entropy":vec![2;32],"contactToken":vec![2;32]}).to_string();
        let sender_secret=serde_json::json!({"derivationVersion":1,"entropy":vec![1;32],"contactToken":vec![1;32]}).to_string();
        let sender = AccountCore::new(Some(sender_secret.as_bytes()), None).unwrap();
        let mut recipient = AccountCore::new(Some(secret.as_bytes()), None).unwrap();
        recipient
            .add_contact(&sender.contact_card_json().unwrap(), "")
            .unwrap();
        let peer = fixture["envelope"]["from"].as_str().unwrap();
        recipient.mark_contact_verified(peer).unwrap();
        let now = fixture["now"].as_u64().unwrap();
        for n in 0..4096 {
            recipient
                .seed_replays
                .borrow_mut()
                .insert((peer.to_owned(), n.to_string(), String::new()), now + 1);
        }
        let source = fixture["envelope"].to_string();
        assert!(
            recipient
                .inspect_seed_signal(&source, peer, now)
                .unwrap_err()
                .contains("window full")
        );
        assert!(
            recipient
                .inspect_seed_signal(&source, peer, now + 2)
                .is_ok()
        );
        assert_eq!(recipient.seed_replays.borrow().len(), 1);
    }
}
