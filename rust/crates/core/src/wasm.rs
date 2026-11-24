use crate::{ChatError, ChatStore, ConversationId};

#[cfg(target_arch = "wasm32")]
use crate::{AccountCore, AccountError};

#[cfg_attr(target_arch = "wasm32", wasm_bindgen::prelude::wasm_bindgen)]
pub fn core_version() -> String {
    format!("cht-core@{}", env!("CARGO_PKG_VERSION"))
}

#[derive(Clone)]
pub struct WebChatCore {
    store: ChatStore,
}

impl WebChatCore {
    pub fn new(initial_state_json: Option<&str>) -> Result<Self, ChatError> {
        let store = match initial_state_json {
            Some(json) => ChatStore::from_persisted_json(json)?,
            None => ChatStore::sample(),
        };
        Ok(Self { store })
    }

    pub fn snapshot_json(&self) -> Result<String, ChatError> {
        self.store.snapshot_json()
    }

    pub fn export_state_json(&self) -> Result<String, ChatError> {
        self.store.to_persisted_json()
    }

    pub fn delete_conversation(&mut self, conversation_id: &str) -> Result<String, ChatError> {
        let id = ConversationId::try_from(conversation_id)?;
        self.store.delete_conversation(&id)?;
        self.store.snapshot_json()
    }

    pub fn send_text(
        &mut self,
        conversation_id: &str,
        text: &str,
        sent_at_milliseconds: i64,
    ) -> Result<String, ChatError> {
        let id = ConversationId::try_from(conversation_id)?;
        self.store.send_text(&id, text, sent_at_milliseconds)?;
        self.store.snapshot_json()
    }
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen(js_name = WebChatCore)]
pub struct WasmChatCore {
    inner: WebChatCore,
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen(js_class = WebChatCore)]
impl WasmChatCore {
    #[wasm_bindgen::prelude::wasm_bindgen(js_name = deleteConversation)]
    pub fn delete_conversation(
        &mut self,
        conversation_id: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .delete_conversation(conversation_id)
            .map_err(to_js_error)
    }
    #[wasm_bindgen::prelude::wasm_bindgen(constructor)]
    pub fn new(initial_state_json: Option<String>) -> Result<WasmChatCore, wasm_bindgen::JsValue> {
        WebChatCore::new(initial_state_json.as_deref())
            .map(|inner| Self { inner })
            .map_err(to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = snapshotJson)]
    pub fn snapshot_json(&self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner.snapshot_json().map_err(to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = exportStateJson)]
    pub fn export_state_json(&self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner.export_state_json().map_err(to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = sendText)]
    pub fn send_text(
        &mut self,
        conversation_id: &str,
        text: &str,
        sent_at_milliseconds: f64,
    ) -> Result<String, wasm_bindgen::JsValue> {
        if !sent_at_milliseconds.is_finite()
            || sent_at_milliseconds.fract() != 0.0
            || sent_at_milliseconds < i64::MIN as f64
            || sent_at_milliseconds > i64::MAX as f64
        {
            return Err(wasm_bindgen::JsValue::from_str(
                "sentAtMilliseconds must be a finite integer",
            ));
        }
        self.inner
            .send_text(conversation_id, text, sent_at_milliseconds as i64)
            .map_err(to_js_error)
    }
}

#[cfg(target_arch = "wasm32")]
fn to_js_error(error: ChatError) -> wasm_bindgen::JsValue {
    wasm_bindgen::JsValue::from_str(&error.to_string())
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen(js_name = AccountCore)]
pub struct WasmAccountCore {
    inner: AccountCore,
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen::prelude::wasm_bindgen(js_class = AccountCore)]
impl WasmAccountCore {
    #[wasm_bindgen::prelude::wasm_bindgen(js_name = deliveryCall)]
    pub fn delivery_call(&self,operation:&str,args_json:&str)->Result<String,wasm_bindgen::JsValue>{
        if args_json.len()>4*1024*1024{return Err(wasm_bindgen::JsValue::from_str("Delivery arguments too large"));}
        let args=serde_json::from_str(args_json).map_err(|_|wasm_bindgen::JsValue::from_str("Invalid delivery arguments"))?;
        self.inner.delivery_call(operation,args).and_then(|v|serde_json::to_string(&v).map_err(|_|"Invalid delivery result".into())).map_err(|e|wasm_bindgen::JsValue::from_str(&e))
    }
    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactRequestCall)]
    pub fn contact_request_call(&self, operation: &str, args_json: &str) -> Result<String, wasm_bindgen::JsValue> {
        if args_json.len() > 32768 { return Err(wasm_bindgen::JsValue::from_str("Contact arguments too large")); }
        let args = serde_json::from_str(args_json).map_err(|_| wasm_bindgen::JsValue::from_str("Invalid contact arguments"))?;
        self.inner.contact_request_call(operation,args)
            .and_then(|v|serde_json::to_string(&v).map_err(|e|e.to_string()))
            .map_err(|e|wasm_bindgen::JsValue::from_str(&e))
    }
    #[wasm_bindgen::prelude::wasm_bindgen(js_name = groupCall)]
    pub fn group_call(
        &mut self,
        operation: &str,
        args_json: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        if args_json.len() > 8 * 1024 * 1024 {
            return Err(wasm_bindgen::JsValue::from_str("Group arguments too large"));
        }
        let args: serde_json::Value = serde_json::from_str(args_json)
            .map_err(|_| wasm_bindgen::JsValue::from_str("Invalid group arguments"))?;
        self.inner
            .group_call(operation, args)
            .and_then(|value| serde_json::to_string(&value).map_err(|e| e.to_string()))
            .map_err(|e| wasm_bindgen::JsValue::from_str(&e))
    }
    #[wasm_bindgen::prelude::wasm_bindgen(constructor)]
    pub fn new(
        secret: Option<Vec<u8>>,
        contacts_json: Option<String>,
    ) -> Result<WasmAccountCore, wasm_bindgen::JsValue> {
        AccountCore::new(secret.as_deref(), contacts_json.as_deref())
            .map(|inner| Self { inner })
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = hasIdentity)]
    pub fn has_identity(&self) -> bool {
        self.inner.has_identity()
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = createIdentityJson)]
    pub fn create_identity_json(&mut self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .create_identity_json()
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = discardPendingIdentity)]
    pub fn discard_pending_identity(&mut self) {
        self.inner.discard_pending_identity();
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = confirmRecovery)]
    pub fn confirm_recovery(&mut self, phrase: &str) -> Result<Vec<u8>, wasm_bindgen::JsValue> {
        self.inner
            .confirm_recovery(phrase)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = restoreIdentityJson)]
    pub fn restore_identity_json(
        &mut self,
        phrase: &str,
    ) -> Result<js_sys::Array, wasm_bindgen::JsValue> {
        let (public, secret) = self
            .inner
            .restore_identity_json(phrase)
            .map_err(account_to_js_error)?;
        let result = js_sys::Array::new();
        result.push(&wasm_bindgen::JsValue::from_str(&public));
        result.push(&js_sys::Uint8Array::from(secret.as_slice()));
        Ok(result)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = identityJson)]
    pub fn identity_json(&self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner.identity_json().map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = relayProof)]
    pub fn relay_proof(
        &self,
        nonce: &str,
        relay_id: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .relay_proof_json(nonce, relay_id)
            .map_err(|e| wasm_bindgen::JsValue::from_str(&e))
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = signSeedDispatch)]
    pub fn sign_seed_dispatch(&self, seed_id: &str, connection: &str, sequence: f64, envelope_json: &str) -> Result<String, wasm_bindgen::JsValue> {
        let sequence = crate::seed_signal::safe_time(sequence).map_err(|e| wasm_bindgen::JsValue::from_str(&e))?;
        self.inner.sign_seed_dispatch(seed_id, connection, sequence, envelope_json).map_err(|e| wasm_bindgen::JsValue::from_str(&e))
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = signSeedSignal)]
    pub fn sign_seed_signal(
        &self,
        peer_id: &str,
        message_id: &str,
        text: &str,
        now: f64,
    ) -> Result<String, wasm_bindgen::JsValue> {
        let now =
            crate::seed_signal::safe_time(now).map_err(|e| wasm_bindgen::JsValue::from_str(&e))?;
        self.inner
            .sign_seed_signal(peer_id, message_id, text, now)
            .map_err(|e| wasm_bindgen::JsValue::from_str(&e))
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = inspectSeedSignal)]
    pub fn inspect_seed_signal(
        &self,
        source: &str,
        expected_peer: &str,
        now: f64,
    ) -> Result<String, wasm_bindgen::JsValue> {
        let now =
            crate::seed_signal::safe_time(now).map_err(|e| wasm_bindgen::JsValue::from_str(&e))?;
        self.inner
            .inspect_seed_signal(source, expected_peer, now)
            .map_err(|e| wasm_bindgen::JsValue::from_str(&e))
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = inspectRelayRecord)]
    pub fn inspect_relay_record(
        &self,
        source: &str,
        now: f64,
        allow_loopback: bool,
    ) -> Result<String, wasm_bindgen::JsValue> {
        crate::relay_directory::inspect_record_json(source, now as u64, allow_loopback)
            .map_err(|e| wasm_bindgen::JsValue::from_str(&e))
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactCardJson)]
    pub fn contact_card_json(&self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner.contact_card_json().map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactCardJsonWithName)]
    pub fn contact_card_json_with_name(
        &self,
        display_name: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .contact_card_json_with_name(display_name)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactCardJsonWithProfile)]
    pub fn contact_card_json_with_profile(
        &self,
        display_name: &str,
        avatar: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .contact_card_json_with_profile(display_name, avatar)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactCardJsonWithRelays)]
    pub fn contact_card_json_with_relays(
        &self,
        display_name: &str,
        avatar: &str,
        relay_urls: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        if relay_urls.len() > 1024 {
            return Err(wasm_bindgen::JsValue::from_str("Relay URLs too large"));
        }
        let urls: Vec<String> = serde_json::from_str(relay_urls)
            .map_err(|_| wasm_bindgen::JsValue::from_str("Invalid relay URLs"))?;
        self.inner
            .contact_card_json_with_relays(display_name, avatar, &urls)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactsJson)]
    pub fn contacts_json(&self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner.contacts_json().map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = inspectContactCardJson)]
    pub fn inspect_contact_card_json(
        &self,
        card_json: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .inspect_contact_card_json(card_json)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = contactsStateJson)]
    pub fn contacts_state_json(&self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .contacts_state_json()
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = addContact)]
    pub fn add_contact(
        &mut self,
        card_json: &str,
        display_name: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .add_contact(card_json, display_name)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = restoreContactsState)]
    pub fn restore_contacts_state(&mut self, source: &str) -> Result<(), wasm_bindgen::JsValue> {
        self.inner
            .restore_contacts_state_json(source)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = markContactVerified)]
    pub fn mark_contact_verified(
        &mut self,
        identity_id: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .mark_contact_verified(identity_id)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = setContactAlias)]
    pub fn set_contact_alias(
        &mut self,
        identity_id: &str,
        alias: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .set_contact_alias(identity_id, alias)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = removeContact)]
    pub fn remove_contact(&mut self, identity_id: &str) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .remove_contact(identity_id)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = preparePeer)]
    pub fn prepare_peer(
        &mut self,
        card_json: &str,
        initiator: bool,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .prepare_peer(card_json, initiator)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = startPeerHandshake)]
    pub fn start_peer_handshake(&mut self) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .start_peer_handshake()
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = receivePeerHandshake)]
    pub fn receive_peer_handshake(&mut self, frame: &str) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .receive_peer_handshake(frame)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = encryptPeerMessage)]
    pub fn encrypt_peer_message(
        &mut self,
        message_id: &str,
        text: &str,
    ) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .encrypt_peer_message(message_id, text)
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = encryptPeerMessageAt)]
    pub fn encrypt_peer_message_at(
        &mut self,
        message_id: &str,
        text: &str,
        sent_at_milliseconds: f64,
    ) -> Result<String, wasm_bindgen::JsValue> {
        if !sent_at_milliseconds.is_finite()
            || sent_at_milliseconds.fract() != 0.0
            || sent_at_milliseconds.abs() > 8_640_000_000_000_000.0
        {
            return Err(wasm_bindgen::JsValue::from_str("Invalid message timestamp"));
        }
        self.inner
            .encrypt_peer_message_at(message_id, text, Some(sent_at_milliseconds as i64))
            .map_err(account_to_js_error)
    }

    #[wasm_bindgen::prelude::wasm_bindgen(js_name = decryptPeerMessage)]
    pub fn decrypt_peer_message(&mut self, frame: &str) -> Result<String, wasm_bindgen::JsValue> {
        self.inner
            .decrypt_peer_message(frame)
            .map_err(account_to_js_error)
    }
}

#[cfg(target_arch = "wasm32")]
fn account_to_js_error(error: AccountError) -> wasm_bindgen::JsValue {
    wasm_bindgen::JsValue::from_str(&error.to_string())
}
