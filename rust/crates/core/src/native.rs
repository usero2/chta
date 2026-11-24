use std::{
    ffi::{CStr, CString, c_char},
    sync::{Mutex, OnceLock},
};

use serde_json::{Value, json};

use crate::desktop_vault::{AccountData, DesktopProfile, DesktopVault};
#[cfg(any(target_os = "android", test))]
use crate::desktop_vault::{AndroidSessionState, validate_session_route};
use crate::{AccountCore, WebChatCore, core_version};
use zeroize::Zeroizing;

struct NativeRuntime {
    account: AccountCore,
    chat: WebChatCore,
    vault: DesktopVault,
    active_id: Option<String>,
    profile: DesktopProfile,
}

impl NativeRuntime {
    fn new() -> Result<Self, String> {
        Ok(Self {
            account: AccountCore::new(None, None).map_err(|error| error.to_string())?,
            chat: WebChatCore::new(None).map_err(|error| error.to_string())?,
            vault: DesktopVault::from_environment()?,
            active_id: None,
            profile: DesktopProfile::default(),
        })
    }

    fn call(&mut self, command: &str, args: &Value) -> Result<Value, String> {
        let previous_chat = (command == "deleteConversation").then(|| self.chat.clone());
        let result = self.dispatch(command, args)?;
        if matches!(
            command,
            "sendText"
                | "deleteConversation"
                | "addContact"
                | "markContactVerified"
                | "setContactAlias"
                | "removeContact"
                | "preparePeer"
                | "saveDesktopProfile"
        ) && let Err(error) = self.persist()
        {
            if let Some(previous) = previous_chat {
                self.chat = previous;
            }
            return Err(error);
        }
        Ok(result)
    }

    fn activate(&mut self, secret: &[u8], expected_id: Option<&str>) -> Result<Value, String> {
        let account = AccountCore::new(Some(secret), None).map_err(|error| error.to_string())?;
        let public = parse_json(account.identity_json().map_err(|error| error.to_string())?)?;
        let id = required_string(&public, "id")?;
        if expected_id.is_some_and(|expected| expected != id) {
            return Err("Saved identity does not match its encrypted secret".to_owned());
        }
        let data = self.vault.load_data(id)?;
        let account = AccountCore::new(Some(secret), data.contacts.as_deref())
            .map_err(|error| error.to_string())?;
        let chat = WebChatCore::new(data.chat.as_deref()).map_err(|error| error.to_string())?;
        self.account = account;
        self.chat = chat;
        self.active_id = Some(id.to_owned());
        self.profile = data.profile;
        Ok(public)
    }

    fn persist(&self) -> Result<(), String> {
        let Some(id) = self.active_id.as_ref() else {
            return Ok(());
        };
        self.vault.save_data(
            id,
            &AccountData {
                contacts: Some(
                    self.account
                        .contacts_state_json()
                        .map_err(|error| error.to_string())?,
                ),
                chat: Some(
                    self.chat
                        .export_state_json()
                        .map_err(|error| error.to_string())?,
                ),
                profile: self.profile.clone(),
            },
        )
    }

    fn clear(&mut self) -> Result<(), String> {
        self.account = AccountCore::new(None, None).map_err(|error| error.to_string())?;
        self.chat = WebChatCore::new(None).map_err(|error| error.to_string())?;
        self.active_id = None;
        self.profile = DesktopProfile::default();
        Ok(())
    }

    // Android can recreate the Flutter engine while this process-wide runtime
    // survives. Save with the previous vault before locking the old session.
    #[cfg(any(target_os = "android", test))]
    fn begin_platform_session(&mut self, vault: DesktopVault) -> Result<(), String> {
        self.persist()?;
        self.clear()?;
        self.vault = vault;
        Ok(())
    }

    fn dispatch(&mut self, command: &str, args: &Value) -> Result<Value, String> {
        match command {
            "deliveryCall" => {
                let owner=self.active_id.as_deref().ok_or("Unlock an identity before delivery")?;
                let active=parse_json(self.account.identity_json().map_err(|e|e.to_string())?)?;
                if required_string(&active,"id")?!=owner{return Err("Delivery identity mismatch".into());}
                self.account.delivery_call(required_string(args,"operation")?,args.get("args").ok_or("Missing delivery arguments")?.clone())
            }
            "contactRequestCall" => {
                let owner = self.active_id.as_deref().ok_or("Unlock an identity before contact setup")?;
                let active = parse_json(self.account.identity_json().map_err(|e| e.to_string())?)?;
                if required_string(&active, "id")? != owner { return Err("Contact setup owner mismatch".into()); }
                self.account.contact_request_call(required_string(args,"operation")?, args.get("args").ok_or("Missing contact arguments")?.clone())
            }
            "groupCall" => {
                let owner = self
                    .active_id
                    .as_deref()
                    .ok_or("Unlock an identity before using groups")?;
                let active = parse_json(self.account.identity_json().map_err(|e| e.to_string())?)?;
                if required_string(&active, "id")? != owner {
                    return Err("Active group identity mismatch".into());
                }
                let operation = required_string(args, "operation")?;
                let call_args = args.get("args").ok_or("Missing group arguments")?.clone();
                self.account.group_call(operation, call_args)
            }
            "loadGroupBlob" | "saveGroupBlob" | "deleteGroupBlob" => {
                let owner = required_string(args, "ownerId")?;
                if self.active_id.as_deref() != Some(owner) {
                    return Err("Unlock this identity before accessing group data".into());
                }
                let key = required_string(args, "key")?;
                match command {
                    "loadGroupBlob" => Ok(self
                        .vault
                        .load_group_blob(owner, key)?
                        .map(Value::String)
                        .unwrap_or(Value::Null)),
                    "saveGroupBlob" => {
                        self.vault
                            .save_group_blob(owner, key, required_string(args, "value")?)?;
                        Ok(Value::Null)
                    }
                    _ => {
                        self.vault.delete_group_blob(owner, key)?;
                        Ok(Value::Null)
                    }
                }
            }
            "beginChunkedAttachment"
            | "chunkedAttachmentStatus"
            | "writeChunkedAttachment"
            | "readChunkedAttachment"
            | "finishChunkedAttachment"
            | "deleteChunkedAttachment" => {
                use base64::{Engine, engine::general_purpose::STANDARD};
                let owner = required_string(args, "ownerId")?;
                if self.active_id.as_deref() != Some(owner) {
                    return Err("Unlock this identity before accessing its attachments".into());
                }
                let id = required_string(args, "id")?;
                let number = |key: &str| {
                    args.get(key)
                        .and_then(Value::as_u64)
                        .ok_or_else(|| format!("Invalid attachment {key}"))
                };
                let optional = |key: &str| -> Result<Option<&str>, String> {
                    match args.get(key) {
                        None | Some(Value::Null) => Ok(None),
                        Some(Value::String(s)) => Ok(Some(s)),
                        _ => Err(format!("Invalid attachment {key}")),
                    }
                };
                let state = match command {
                    "beginChunkedAttachment" => self.vault.begin_chunked_attachment(
                        owner,
                        id,
                        number("size")?,
                        u32::try_from(number("chunkSize")?).map_err(|_| "Invalid chunk size")?,
                        optional("digest")?,
                    )?,
                    "chunkedAttachmentStatus" => self.vault.chunked_attachment_status(owner, id)?,
                    "finishChunkedAttachment" => self.vault.finish_chunked_attachment(
                        owner,
                        id,
                        optional("expectedDigest")?,
                    )?,
                    "writeChunkedAttachment" => {
                        let data = required_string(args, "data")?;
                        if data.len() > (1024usize * 1024).div_ceil(3) * 4 {
                            return Err("Attachment chunk is too large".into());
                        }
                        let bytes = Zeroizing::new(
                            STANDARD
                                .decode(data)
                                .map_err(|_| "Invalid attachment chunk data")?,
                        );
                        self.vault.write_chunked_attachment(
                            owner,
                            id,
                            u32::try_from(number("index")?).map_err(|_| "Invalid chunk index")?,
                            &bytes,
                        )?;
                        return Ok(Value::Null);
                    }
                    "readChunkedAttachment" => {
                        return Ok(Value::String(
                            STANDARD.encode(
                                self.vault.read_chunked_attachment(
                                    owner,
                                    id,
                                    u32::try_from(number("index")?)
                                        .map_err(|_| "Invalid chunk index")?,
                                )?,
                            ),
                        ));
                    }
                    "deleteChunkedAttachment" => {
                        self.vault.delete_chunked_attachment(owner, id)?;
                        return Ok(Value::Null);
                    }
                    _ => unreachable!(),
                };
                serde_json::to_value(state).map_err(|e| e.to_string())
            }
            #[cfg(any(target_os = "android", test))]
            "resumeIdentity" => {
                if self.active_id.is_some() {
                    return parse_json(
                        self.account
                            .identity_json()
                            .map_err(|error| error.to_string())?,
                    );
                }
                let state = self.vault.load_android_session()?;
                if state.pin_required {
                    return Ok(Value::Null);
                }
                self.activate(&state.secret, state.identity_id.as_deref())
            }
            #[cfg(any(target_os = "android", test))]
            "sessionPreferences" => {
                if self.active_id.is_none() {
                    return Ok(json!({"pinRequired":true,"lastRoute":null}));
                }
                let state = self.vault.load_android_session()?;
                if state.identity_id.as_ref() != self.active_id.as_ref() {
                    return Ok(json!({"pinRequired":true,"lastRoute":null}));
                }
                Ok(json!({"pinRequired":state.pin_required,"lastRoute":state.last_route.clone()}))
            }
            #[cfg(any(target_os = "android", test))]
            "setPinLock" | "saveSessionRoute" => {
                let owner = required_string(args, "ownerId")?;
                if self.active_id.as_deref() != Some(owner) {
                    return Err("Unlock this identity before changing its session".into());
                }
                let mut state = self.vault.load_android_session()?;
                if state.identity_id.as_deref() != Some(owner) {
                    state = AndroidSessionState::default();
                    state.identity_id = Some(owner.to_owned());
                }
                if command == "setPinLock" {
                    use zeroize::Zeroize;
                    let required = args
                        .get("required")
                        .and_then(Value::as_bool)
                        .ok_or("Missing PIN preference")?;
                    state.secret.zeroize();
                    state.secret.clear();
                    if !required {
                        state.secret = self
                            .account
                            .confirmed_secret()
                            .map_err(|error| error.to_string())?;
                    }
                    state.pin_required = required;
                } else {
                    let path = required_string(args, "path")?;
                    validate_session_route(path)?;
                    state.last_route = Some(path.to_owned());
                }
                self.vault.save_android_session(&state)?;
                Ok(json!({"pinRequired":state.pin_required,"lastRoute":state.last_route.clone()}))
            }
            #[cfg(target_os = "android")]
            "configureAndroidStorage" => {
                use base64::Engine;
                let key = base64::engine::general_purpose::STANDARD
                    .decode(required_string(args, "wrappingKey")?)
                    .map_err(|_| "Invalid Android storage key")?;
                let vault = DesktopVault::for_android(
                    std::path::PathBuf::from(required_string(args, "path")?),
                    key,
                )?;
                self.begin_platform_session(vault)?;
                Ok(Value::Null)
            }
            "loadPeerHistory" | "savePeerHistory" => {
                let owner = required_string(args, "ownerId")?;
                if self.active_id.as_deref() != Some(owner) {
                    return Err("Unlock this identity before accessing its history".to_owned());
                }
                if command == "loadPeerHistory" {
                    Ok(json!(self.vault.load_history(owner)?))
                } else {
                    self.vault
                        .save_history(owner, required_string(args, "source")?)?;
                    Ok(Value::Null)
                }
            }
            "savePeerAttachment" | "loadPeerAttachment" => {
                use base64::{Engine as _, engine::general_purpose::STANDARD};
                let owner = required_string(args, "ownerId")?;
                if self.active_id.as_deref() != Some(owner) {
                    return Err("Unlock this identity before accessing its attachments".to_owned());
                }
                let digest = required_string(args, "digest")?;
                if command == "loadPeerAttachment" {
                    match self.vault.load_attachment(owner, digest)? {
                        Some(bytes) => {
                            let bytes = Zeroizing::new(bytes);
                            Ok(json!(STANDARD.encode(&*bytes)))
                        }
                        None => Ok(Value::Null),
                    }
                } else {
                    let data = required_string(args, "data")?;
                    if data.len() > crate::desktop_vault::MAX_ATTACHMENT_BYTES.div_ceil(3) * 4 {
                        return Err("Attachment is too large".to_owned());
                    }
                    let bytes = Zeroizing::new(
                        STANDARD
                            .decode(data)
                            .map_err(|_| "Invalid attachment data")?,
                    );
                    self.vault.save_attachment(owner, digest, &bytes)?;
                    Ok(Value::Null)
                }
            }
            "listSavedIdentities" => {
                serde_json::to_value(self.vault.list()?).map_err(|error| error.to_string())
            }
            "rememberIdentity" => {
                let id = self
                    .active_id
                    .as_ref()
                    .ok_or("Restore or create an identity first")?;
                let name = required_string(args, "displayName")?.trim();
                if name.is_empty() || name.chars().count() > 64 {
                    return Err("Enter a name of 1 to 64 characters".to_owned());
                }
                let avatar = args.get("avatar").and_then(Value::as_str).unwrap_or("");
                self.account
                    .contact_card_json_with_profile(name, avatar)
                    .map_err(|error| error.to_string())?;
                let secret = Zeroizing::new(
                    self.account
                        .confirmed_secret()
                        .map_err(|error| error.to_string())?,
                );
                let profile = DesktopProfile {
                    name: name.to_owned(),
                    contact_avatar: avatar.to_owned(),
                    ..self.profile.clone()
                };
                self.vault
                    .remember(id, required_string(args, "pin")?, &secret, &profile)?;
                self.profile = profile;
                self.persist()?;
                #[cfg(any(target_os = "android", test))]
                {
                    let mut state = AndroidSessionState::default();
                    state.identity_id = Some(id.clone());
                    self.vault.save_android_session(&state)?;
                }
                parse_json(
                    self.account
                        .identity_json()
                        .map_err(|error| error.to_string())?,
                )
            }
            "unlockIdentity" => {
                self.clear()?;
                let id = required_string(args, "identityId")?;
                let secret = self.vault.unlock(id, required_string(args, "pin")?)?;
                let result = self.activate(&secret, Some(id))?;
                #[cfg(any(target_os = "android", test))]
                {
                    use zeroize::Zeroize;
                    let mut state = self.vault.load_android_session().unwrap_or_default();
                    if state.identity_id.as_deref() != Some(id) {
                        state = AndroidSessionState::default();
                        state.identity_id = Some(id.to_owned());
                    }
                    if !state.pin_required {
                        state.secret.zeroize();
                        state.secret = secret.to_vec();
                    }
                    if let Err(error) = self.vault.save_android_session(&state) {
                        self.clear()?;
                        return Err(error);
                    }
                }
                Ok(result)
            }
            "lockIdentity" => {
                #[cfg(any(target_os = "android", test))]
                {
                    use zeroize::Zeroize;
                    let mut state = self.vault.load_android_session().unwrap_or_default();
                    state.pin_required = true;
                    state.secret.zeroize();
                    state.secret.clear();
                    self.vault.save_android_session(&state)?;
                }
                let saved = self.persist();
                self.clear()?;
                saved?;
                Ok(Value::Null)
            }
            "loadDesktopProfile" => {
                serde_json::to_value(&self.profile).map_err(|error| error.to_string())
            }
            "saveDesktopProfile" => {
                if self.active_id.is_none() {
                    return Err("Unlock an identity before saving a profile".to_owned());
                }
                let profile: DesktopProfile =
                    serde_json::from_value(args.clone()).map_err(|error| error.to_string())?;
                if let Some(avatar) = &profile.avatar {
                    use base64::Engine;
                    if avatar.len() > 350_000
                        || base64::engine::general_purpose::STANDARD
                            .decode(avatar)
                            .map_err(|_| "Invalid profile image")?
                            .len()
                            > 256 * 1024
                    {
                        return Err("Profile image must be 256 KB or smaller".to_owned());
                    }
                }
                self.account
                    .contact_card_json_with_profile(&profile.name, &profile.contact_avatar)
                    .map_err(|error| error.to_string())?;
                self.profile = profile;
                Ok(Value::Null)
            }
            "version" => Ok(json!(core_version())),
            "snapshot" => parse_json(
                self.chat
                    .snapshot_json()
                    .map_err(|error| error.to_string())?,
            ),
            "sendText" => parse_json(
                self.chat
                    .send_text(
                        required_string(args, "conversationId")?,
                        required_string(args, "text")?,
                        required_i64(args, "sentAtMilliseconds")?,
                    )
                    .map_err(|error| error.to_string())?,
            ),
            "hasIdentity" => Ok(json!(self.account.has_identity())),
            "deleteConversation" => parse_json(
                self.chat
                    .delete_conversation(required_string(args, "conversationId")?)
                    .map_err(|e| e.to_string())?,
            ),
            "createIdentity" => parse_json(
                self.account
                    .create_identity_json()
                    .map_err(|error| error.to_string())?,
            ),
            "discardPendingIdentity" => {
                self.clear()?;
                Ok(Value::Null)
            }
            "confirmRecovery" => {
                let secret = Zeroizing::new(
                    self.account
                        .confirm_recovery(required_string(args, "phrase")?)
                        .map_err(|error| error.to_string())?,
                );
                self.activate(&secret, None)
            }
            "restoreIdentity" => {
                let restored = crate::IdentityManager::restore(required_string(args, "phrase")?)
                    .map_err(|error| error.to_string())?;
                let secret = Zeroizing::new(
                    restored
                        .export_confirmed_secret()
                        .map_err(|error| error.to_string())?,
                );
                self.activate(&secret, None)
            }
            "identity" => parse_json(
                self.account
                    .identity_json()
                    .map_err(|error| error.to_string())?,
            ),
            "relayProof" => Ok(json!(self.account.relay_proof_json(
                required_string(args, "nonce")?,
                required_string(args, "relayId")?
            )?)),
            "signSeedDispatch" => Ok(json!(self.account.sign_seed_dispatch(
                required_string(args, "seedId")?,
                required_string(args, "connection")?,
                args["sequence"].as_u64().ok_or("Invalid seed sequence")?,
                required_string(args, "envelopeJson")?
            )?)),
            "signSeedSignal" => Ok(json!(
                self.account.sign_seed_signal(
                    required_string(args, "peerId")?,
                    required_string(args, "messageId")?,
                    required_string(args, "text")?,
                    args["now"]
                        .as_u64()
                        .filter(|n| *n <= crate::seed_signal::MAX_SAFE_TIME)
                        .ok_or("Invalid seed time")?
                )?
            )),
            "inspectSeedSignal" => Ok(json!(
                self.account.inspect_seed_signal(
                    required_string(args, "source")?,
                    required_string(args, "expectedPeer")?,
                    args["now"]
                        .as_u64()
                        .filter(|n| *n <= crate::seed_signal::MAX_SAFE_TIME)
                        .ok_or("Invalid seed time")?
                )?
            )),
            "inspectRelayRecord" => Ok(json!(crate::relay_directory::inspect_record_json(
                required_string(args, "source")?,
                args["now"].as_u64().ok_or("Missing time")?,
                args["allowLoopback"].as_bool().unwrap_or(false)
            )?)),
            "loadRelayState" => Ok(json!(self.vault.load_relay_state()?)),
            "saveRelayState" => {
                self.vault
                    .save_relay_state(required_string(args, "source")?)?;
                Ok(Value::Null)
            }
            "contactCard" => Ok(json!(
                self.account
                    .contact_card_json_with_relays(
                        args.get("displayName")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                        args.get("avatar").and_then(Value::as_str).unwrap_or(""),
                        &serde_json::from_value::<Vec<String>>(
                            args.get("relayUrls").cloned().unwrap_or(json!([]))
                        )
                        .map_err(|_| "Invalid relay URLs")?,
                    )
                    .map_err(|error| error.to_string())?
            )),
            "contacts" => parse_json(
                self.account
                    .contacts_json()
                    .map_err(|error| error.to_string())?,
            ),
            "inspectContactCard" => parse_json(
                self.account
                    .inspect_contact_card_json(required_string(args, "cardJson")?)
                    .map_err(|error| error.to_string())?,
            ),
            "addContact" => parse_json(
                self.account
                    .add_contact(
                        required_string(args, "cardJson")?,
                        required_string(args, "displayName")?,
                    )
                    .map_err(|error| error.to_string())?,
            ),
            "markContactVerified" => parse_json(
                self.account
                    .mark_contact_verified(required_string(args, "identityId")?)
                    .map_err(|error| error.to_string())?,
            ),
            "setContactAlias" => parse_json(
                self.account
                    .set_contact_alias(
                        required_string(args, "identityId")?,
                        required_string(args, "alias")?,
                    )
                    .map_err(|error| error.to_string())?,
            ),
            "removeContact" => parse_json(
                self.account
                    .remove_contact(required_string(args, "identityId")?)
                    .map_err(|error| error.to_string())?,
            ),
            "preparePeer" => Ok(json!(
                self.account
                    .prepare_peer(
                        required_string(args, "cardJson")?,
                        required_bool(args, "initiator")?,
                    )
                    .map_err(|error| error.to_string())?
            )),
            "startPeerHandshake" => Ok(json!(
                self.account
                    .start_peer_handshake()
                    .map_err(|error| error.to_string())?
            )),
            "receivePeerHandshake" => parse_json(
                self.account
                    .receive_peer_handshake(required_string(args, "frame")?)
                    .map_err(|error| error.to_string())?,
            ),
            "encryptPeerMessage" => Ok(json!(
                self.account
                    .encrypt_peer_message_at(
                        required_string(args, "messageId")?,
                        required_string(args, "text")?,
                        args.get("sentAtMilliseconds").and_then(Value::as_i64),
                    )
                    .map_err(|error| error.to_string())?
            )),
            "decryptPeerMessage" => parse_json(
                self.account
                    .decrypt_peer_message(required_string(args, "frame")?)
                    .map_err(|error| error.to_string())?,
            ),
            _ => Err(format!("unknown native command: {command}")),
        }
    }
}

static RUNTIME: OnceLock<Result<Mutex<NativeRuntime>, String>> = OnceLock::new();

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cht_call(request: *const c_char) -> *mut c_char {
    let response = call_inner(request)
        .map(|value| json!({"ok": true, "value": value}))
        .unwrap_or_else(|error| json!({"ok": false, "error": error}));
    CString::new(response.to_string())
        .expect("JSON does not contain null bytes")
        .into_raw()
}

fn call_inner(request: *const c_char) -> Result<Value, String> {
    if request.is_null() {
        return Err("request pointer is null".to_owned());
    }
    // SAFETY: The Dart bridge passes a valid null-terminated UTF-8 allocation for this call.
    let source = unsafe { CStr::from_ptr(request) }
        .to_str()
        .map_err(|error| error.to_string())?;
    let document: Value = serde_json::from_str(source).map_err(|error| error.to_string())?;
    let command = required_string(&document, "command")?;
    let args = document.get("args").unwrap_or(&Value::Null);
    let runtime = RUNTIME.get_or_init(|| NativeRuntime::new().map(Mutex::new));
    let runtime = runtime.as_ref().map_err(Clone::clone)?;
    runtime
        .lock()
        .map_err(|_| "native runtime lock is poisoned".to_owned())?
        .call(command, args)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cht_free_string(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: This pointer was allocated by CString::into_raw in cht_call and is freed once.
        drop(unsafe { CString::from_raw(value) });
    }
}

fn parse_json(source: String) -> Result<Value, String> {
    serde_json::from_str(&source).map_err(|error| error.to_string())
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{key} must be a string"))
}

fn required_i64(value: &Value, key: &str) -> Result<i64, String> {
    value
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| format!("{key} must be an integer"))
}

fn required_bool(value: &Value, key: &str) -> Result<bool, String> {
    value
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| format!("{key} must be a boolean"))
}

#[cfg(test)]
mod tests {
    #[cfg(windows)]
    #[test]
    fn contact_request_native_opens_without_pretrust_and_rejects_wrong_recipient() {
        let folder = TestVault::new();
        let mut sender = folder.runtime();
        let receiver_folder = TestVault::new();
        let mut receiver = receiver_folder.runtime();
        let a = crate::IdentityManager::create().unwrap();
        let b = crate::IdentityManager::create().unwrap();
        sender.account = crate::AccountCore::new(Some(&a.export_secret()), None).unwrap();
        sender.active_id = Some(a.public_identity().id.clone());
        receiver.account = crate::AccountCore::new(Some(&b.export_secret()), None).unwrap();
        receiver.active_id = Some(b.public_identity().id.clone());
        let now = 1_800_000_000_000u64;
        let sealed = sender.call("contactRequestCall", &serde_json::json!({
            "operation":"seal", "args": {
                "peerCard": b.contact_card().unwrap().to_json().unwrap(),
                "requestId":"0123456789abcdef0123456789abcdef",
                "kind":"request", "displayName":"Synthetic request sender", "now":now,
            }
        })).expect("A signed card should permit sending a contact request before mutual add");
        let source = sealed["envelope"].to_string();
        assert!(!source.contains("Synthetic request sender"));
        let inspect = serde_json::json!({"operation":"inspect","args":{"source":source,"now":now}});
        assert_eq!(receiver.account.contacts_json().unwrap(), "[]");
        let opened = receiver.call("contactRequestCall", &inspect).unwrap();
        assert_eq!(opened["peerId"], a.public_identity().id);
        assert_eq!(opened["kind"], "request");
        assert_eq!(opened["contact"]["verified"], false);
        assert_eq!(receiver.account.contacts_json().unwrap(), "[]", "Only Review/Accept may create trust");
        assert!(sender.call("contactRequestCall", &inspect).is_err());
        let mut tampered = sealed["envelope"].clone();
        tampered["kind"] = serde_json::json!("accepted");
        assert!(receiver.call("contactRequestCall", &serde_json::json!({
            "operation":"inspect","args":{"source":tampered.to_string(),"now":now}
        })).is_err());
        assert!(receiver.call("contactRequestCall", &serde_json::json!({
            "operation":"inspect","args":{"source":source,"now":now+120000}
        })).is_err());
    }
    #[cfg(windows)]
    #[test]
    fn seed_native_command_arguments_and_result_match_account() {
        use base64::Engine as _;
        let folder = TestVault::new();
        let mut runtime = folder.runtime();
        let args =
            serde_json::json!({"peerId":"invalid","messageId":"invalid","text":"{}","now":0});
        assert!(
            runtime
                .call("signSeedSignal", &args)
                .unwrap_err()
                .contains("Unlock")
        );
        assert!(
            runtime
                .call(
                    "inspectSeedSignal",
                    &serde_json::json!({"source":"{}","expectedPeer":"invalid","now":0})
                )
                .unwrap_err()
                .contains("Unlock")
        );
        let a = crate::IdentityManager::create().unwrap();
        let b = crate::IdentityManager::create().unwrap();
        let peer = b.public_identity().id.clone();
        runtime.account = crate::AccountCore::new(Some(&a.export_secret()), None).unwrap();
        runtime
            .account
            .add_contact(&b.contact_card().unwrap().to_json().unwrap(), "")
            .unwrap();
        runtime.account.mark_contact_verified(&peer).unwrap();
        runtime.active_id=Some(a.public_identity().id.clone());
        let delivery=runtime.call("deliveryCall",&json!({"operation":"signEvent","args":{"scope":"direct:test","messageId":"native-test","sentAt":1800000000000u64,"kind":"text","payload":"hello"}})).unwrap();
        assert_eq!(delivery["messageId"],"native-test");
        let session = "0123456789abcdef0123456789abcdef";
        let message_id = format!("cht-control-direct-v1-{session}-ice-0");
        let payload=serde_json::json!({"v":1,"t":"ice","s":session,"c":"candidate:1 1 UDP 123 192.0.2.1 1234 typ host","m":null,"l":0}).to_string();
        let args = serde_json::json!({"peerId":peer,"messageId":message_id,"text":payload,"now":1_800_000_000_000u64});
        let expected = runtime
            .account
            .sign_seed_signal(&peer, &message_id, &payload, 1_800_000_000_000)
            .unwrap();
        assert_eq!(
            runtime.call("signSeedSignal", &args).unwrap(),
            serde_json::json!(expected)
        );
        let dispatch_args=serde_json::json!({"seedId":"e0ba672185682a830d168e31cee185b9434b49b210a7ec7a435e78fcb2a532a5",
            "connection":base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([5u8;32]),"sequence":1,"envelopeJson":expected});
        let dispatch_source=runtime.call("signSeedDispatch",&dispatch_args).unwrap();
        let dispatch:serde_json::Value=serde_json::from_str(dispatch_source.as_str().unwrap()).unwrap();
        assert_eq!(dispatch["sequence"],1);
        for sequence in [serde_json::json!(-1),serde_json::json!(1.5),serde_json::json!(9_007_199_254_740_992u64)] {
            let mut bad=dispatch_args.clone();bad["sequence"]=sequence;
            assert!(runtime.call("signSeedDispatch",&bad).is_err());
        }
        for now in [
            serde_json::json!(-1),
            serde_json::json!(1.5),
            serde_json::json!(9_007_199_254_740_992u64),
        ] {
            let mut bad = args.clone();
            bad["now"] = now;
            assert!(runtime.call("signSeedSignal", &bad).is_err());
        }
        runtime.account = crate::AccountCore::new(Some(&b.export_secret()), None).unwrap();
        runtime
            .account
            .add_contact(&a.contact_card().unwrap().to_json().unwrap(), "")
            .unwrap();
        runtime
            .account
            .mark_contact_verified(&a.public_identity().id)
            .unwrap();
        let received=runtime.call("inspectSeedSignal", &serde_json::json!({"source":expected,"expectedPeer":a.public_identity().id,"now":1_800_000_000_000u64})).unwrap();
        let inspected: serde_json::Value =
            serde_json::from_str(received.as_str().unwrap()).unwrap();
        assert_eq!(
            inspected,
            serde_json::json!({"peerId":a.public_identity().id,"messageId":message_id,"text":payload})
        );
    }
    use super::*;

    #[cfg(windows)]
    #[test]
    fn deleted_initial_rooms_persist_and_failed_delete_keeps_history() {
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let phrase = json!({"phrase":local.mnemonic()});
        let mut runtime = folder.runtime();
        runtime.call("restoreIdentity", &phrase).unwrap();
        runtime.call("sendText", &json!({"conversationId":"general","text":"persistent fixture","sentAtMilliseconds":1})).unwrap();
        let account_path = std::fs::read_dir(folder.0.join("accounts"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let blocker = account_path.with_extension("tmp");
        std::fs::create_dir(&blocker).unwrap();
        let before = runtime.call("snapshot", &Value::Null).unwrap();
        assert!(
            runtime
                .call("deleteConversation", &json!({"conversationId":"general"}))
                .is_err()
        );
        assert_eq!(runtime.call("snapshot", &Value::Null).unwrap(), before);
        std::fs::remove_dir(blocker).unwrap();
        runtime
            .call("deleteConversation", &json!({"conversationId":"general"}))
            .unwrap();
        runtime
            .call("deleteConversation", &json!({"conversationId":"design"}))
            .unwrap();
        let mut reopened = folder.runtime();
        reopened.call("restoreIdentity", &phrase).unwrap();
        assert_eq!(
            reopened.call("snapshot", &Value::Null).unwrap()["conversations"],
            json!([])
        );
    }

    #[cfg(windows)]
    #[test]
    fn chunked_commands_require_active_owner_and_reopen_durable_bytes() {
        use base64::{Engine, engine::general_purpose::STANDARD};
        let folder = TestVault::new();
        let mut runtime = folder.runtime();
        let local = crate::IdentityManager::create().unwrap();
        let owner = local.public_identity().id.clone();
        let args = json!({"ownerId":owner,"id":"native-chunk-fixture-01","size":4,"chunkSize":4});
        assert!(
            runtime
                .call("beginChunkedAttachment", &args)
                .unwrap_err()
                .contains("Unlock")
        );
        runtime
            .call("restoreIdentity", &json!({"phrase":local.mnemonic()}))
            .unwrap();
        assert_eq!(
            runtime.call("beginChunkedAttachment", &args).unwrap()["contiguousChunks"],
            0
        );
        let chunk = json!({"ownerId":owner,"id":"native-chunk-fixture-01","index":0,"data":STANDARD.encode(b"file")});
        runtime.call("writeChunkedAttachment", &chunk).unwrap();
        let done = runtime.call("finishChunkedAttachment", &args).unwrap();
        assert_eq!(done["completed"], true);
        assert_eq!(
            runtime.call("readChunkedAttachment", &chunk).unwrap(),
            chunk["data"]
        );
        let wrong =
            json!({"ownerId":format!("did:cht:{}","b".repeat(64)),"id":"native-chunk-fixture-01"});
        assert!(
            runtime
                .call("chunkedAttachmentStatus", &wrong)
                .unwrap_err()
                .contains("Unlock")
        );
    }

    #[cfg(windows)]
    #[test]
    fn attachment_commands_require_the_unlocked_owner() {
        use base64::Engine;
        use sha2::{Digest, Sha256};
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let id = local.public_identity().id.clone();
        let data = b"native cached bytes";
        let digest = format!("{:x}", Sha256::digest(data));
        let args = json!({"ownerId":id,"digest":digest,"data":base64::engine::general_purpose::STANDARD.encode(data)});
        let mut runtime = folder.runtime();
        assert!(
            runtime
                .call("savePeerAttachment", &args)
                .unwrap_err()
                .contains("Unlock")
        );
        runtime
            .call("restoreIdentity", &json!({"phrase":local.mnemonic()}))
            .unwrap();
        runtime.call("savePeerAttachment", &args).unwrap();
        assert_eq!(
            runtime.call("loadPeerAttachment", &args).unwrap(),
            args["data"]
        );
        assert!(
            runtime
                .call(
                    "loadPeerAttachment",
                    &json!({"ownerId":format!("did:cht:{}", "b".repeat(64)),"digest":digest})
                )
                .is_err()
        );
        runtime.call("lockIdentity", &Value::Null).unwrap();
        assert!(
            runtime
                .call("loadPeerAttachment", &args)
                .unwrap_err()
                .contains("Unlock")
        );
    }

    #[cfg(windows)]
    struct TestVault(std::path::PathBuf);

    #[cfg(windows)]
    impl TestVault {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                    "cht-vault-test-{}-{}",
                    std::process::id(),
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                )))
        }
        fn runtime(&self) -> NativeRuntime {
            let mut runtime = NativeRuntime::new().unwrap();
            runtime.vault = DesktopVault::new(self.0.clone());
            runtime
        }
    }

    #[cfg(windows)]
    impl Drop for TestVault {
        fn drop(&mut self) {
            if self.0.exists() {
                assert_eq!(
                    self.0.parent().unwrap().canonicalize().unwrap(),
                    std::env::temp_dir().canonicalize().unwrap()
                );
                assert!(
                    self.0
                        .file_name()
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .starts_with("cht-vault-test-")
                );
                std::fs::remove_dir_all(&self.0).unwrap();
            }
        }
    }

    #[cfg(windows)]
    #[test]
    fn resume_grant_secret_must_match_its_saved_owner() {
        let folder = TestVault::new();
        let a = crate::IdentityManager::create().unwrap();
        let b = crate::IdentityManager::create().unwrap();
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase":a.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"918273","displayName":"A"}),
            )
            .unwrap();
        let secret = Zeroizing::new(runtime.account.confirmed_secret().unwrap());
        runtime
            .call("restoreIdentity", &json!({"phrase":b.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"192837","displayName":"B"}),
            )
            .unwrap();
        let mut swapped = AndroidSessionState::default();
        swapped.identity_id = Some(b.public_identity().id.clone());
        swapped.pin_required = false;
        swapped.secret = secret.to_vec();
        runtime.vault.save_android_session(&swapped).unwrap();
        let mut reopened = folder.runtime();
        assert!(reopened.call("resumeIdentity", &Value::Null).is_err());
        assert_eq!(reopened.call("hasIdentity", &Value::Null).unwrap(), false);
    }

    #[cfg(windows)]
    #[test]
    fn failed_pin_preference_write_preserves_original_pin_record() {
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let id = local.public_identity().id.clone();
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase":local.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"918273","displayName":"Fixture"}),
            )
            .unwrap();
        let identity_path = std::fs::read_dir(folder.0.join("identities"))
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let original = std::fs::read(&identity_path).unwrap();
        let session_path = folder.0.join("android-session.bin");
        let original_session = std::fs::read(&session_path).unwrap();
        let temporary_path = session_path.with_extension("tmp");
        std::fs::create_dir(&temporary_path).unwrap();
        assert!(
            runtime
                .call("setPinLock", &json!({"ownerId":id,"required":false}))
                .is_err()
        );
        assert_eq!(std::fs::read(identity_path).unwrap(), original);
        assert_eq!(std::fs::read(&session_path).unwrap(), original_session);
        assert_eq!(
            folder
                .runtime()
                .call("resumeIdentity", &Value::Null)
                .unwrap(),
            Value::Null
        );
        std::fs::remove_dir(temporary_path).unwrap();
        assert_eq!(
            folder
                .runtime()
                .call("unlockIdentity", &json!({"identityId":id,"pin":"918273"}))
                .unwrap()["id"],
            id
        );
    }

    #[cfg(windows)]
    #[test]
    fn pin_off_resumes_only_saved_identity_and_route_with_encrypted_storage() {
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let id = local.public_identity().id.clone();
        let mut runtime = folder.runtime();
        assert_eq!(
            runtime.call("resumeIdentity", &Value::Null).unwrap(),
            Value::Null
        );
        runtime
            .call("restoreIdentity", &json!({"phrase":local.mnemonic()}))
            .unwrap();
        assert!(
            runtime
                .call("setPinLock", &json!({"ownerId":id,"required":false}))
                .is_err()
        );
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"918273","displayName":"Fixture"}),
            )
            .unwrap();
        assert_eq!(
            runtime.call("sessionPreferences", &Value::Null).unwrap()["pinRequired"],
            true
        );
        runtime
            .call("setPinLock", &json!({"ownerId":id,"required":false}))
            .unwrap();
        runtime
            .call(
                "saveSessionRoute",
                &json!({"ownerId":id,"path":"/chats/general"}),
            )
            .unwrap();
        runtime
            .chat
            .send_text("general", "preserved across restart", 123)
            .unwrap();
        let secret = Zeroizing::new(runtime.account.confirmed_secret().unwrap());
        runtime
            .begin_platform_session(DesktopVault::new(folder.0.clone()))
            .unwrap();
        assert_eq!(
            runtime.call("resumeIdentity", &Value::Null).unwrap()["id"],
            id
        );
        assert!(
            runtime
                .call("snapshot", &Value::Null)
                .unwrap()
                .to_string()
                .contains("preserved across restart")
        );
        let mut reopened = folder.runtime();
        assert_eq!(
            reopened.call("resumeIdentity", &Value::Null).unwrap()["id"],
            id
        );
        assert_eq!(
            reopened.call("sessionPreferences", &Value::Null).unwrap()["lastRoute"],
            "/chats/general"
        );
        let bytes = std::fs::read(folder.0.join("android-session.bin")).unwrap();
        assert!(!bytes.windows(secret.len()).any(|window| window == *secret));
        assert!(!String::from_utf8_lossy(&bytes).contains("918273"));
    }

    #[cfg(windows)]
    #[test]
    fn pin_on_manual_lock_and_identity_switch_revoke_remembered_access() {
        let folder = TestVault::new();
        let a = crate::IdentityManager::create().unwrap();
        let b = crate::IdentityManager::create().unwrap();
        let a_id = a.public_identity().id.clone();
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase":a.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"918273","displayName":"A"}),
            )
            .unwrap();
        runtime
            .call("setPinLock", &json!({"ownerId":a_id,"required":false}))
            .unwrap();
        runtime
            .call("setPinLock", &json!({"ownerId":a_id,"required":true}))
            .unwrap();
        assert_eq!(
            folder
                .runtime()
                .call("resumeIdentity", &Value::Null)
                .unwrap(),
            Value::Null
        );
        runtime
            .call("setPinLock", &json!({"ownerId":a_id,"required":false}))
            .unwrap();
        runtime.call("lockIdentity", &Value::Null).unwrap();
        assert_eq!(
            folder
                .runtime()
                .call("resumeIdentity", &Value::Null)
                .unwrap(),
            Value::Null
        );
        assert!(
            runtime
                .call("setPinLock", &json!({"ownerId":a_id,"required":false}))
                .is_err()
        );
        assert!(
            runtime
                .call(
                    "saveSessionRoute",
                    &json!({"ownerId":a_id,"path":"/contacts"})
                )
                .is_err()
        );
        runtime
            .call("unlockIdentity", &json!({"identityId":a_id,"pin":"918273"}))
            .unwrap();
        runtime
            .call("setPinLock", &json!({"ownerId":a_id,"required":false}))
            .unwrap();
        runtime
            .call("restoreIdentity", &json!({"phrase":b.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"192837","displayName":"B"}),
            )
            .unwrap();
        assert_eq!(
            folder
                .runtime()
                .call("resumeIdentity", &Value::Null)
                .unwrap(),
            Value::Null
        );
        assert!(
            runtime
                .call(
                    "saveSessionRoute",
                    &json!({"ownerId":a_id,"path":"/contacts"})
                )
                .is_err()
        );
    }

    #[cfg(windows)]
    #[test]
    fn damaged_resume_state_fails_closed_and_correct_pin_recovers_without_erasure() {
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let id = local.public_identity().id.clone();
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase":local.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin":"918273","displayName":"Fixture"}),
            )
            .unwrap();
        runtime
            .call("setPinLock", &json!({"ownerId":id,"required":false}))
            .unwrap();
        for path in [
            "/identity/new",
            "/chats/%zz",
            "/chats/%ff",
            "/chats/%00",
            "/chats/../identity",
            "/profile?secret=bad",
        ] {
            assert!(
                runtime
                    .call("saveSessionRoute", &json!({"ownerId":id,"path":path}))
                    .is_err()
            );
        }
        std::fs::write(folder.0.join("android-session.bin"), b"corrupt").unwrap();
        let mut reopened = folder.runtime();
        assert!(reopened.call("resumeIdentity", &Value::Null).is_err());
        assert_eq!(reopened.call("hasIdentity", &Value::Null).unwrap(), false);
        reopened
            .call("unlockIdentity", &json!({"identityId":id,"pin":"918273"}))
            .unwrap();
        assert_eq!(
            reopened.call("sessionPreferences", &Value::Null).unwrap()["pinRequired"],
            true
        );
        assert_eq!(
            reopened
                .call("listSavedIdentities", &Value::Null)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[cfg(windows)]
    #[test]
    fn engine_recreation_locks_the_old_session_and_preserves_saved_data() {
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let friend = crate::IdentityManager::create().unwrap();
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase": local.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin": "918273", "displayName": "Alice"}),
            )
            .unwrap();
        runtime.call("addContact", &json!({"cardJson": friend.contact_card_with_name("Friend").unwrap().to_json().unwrap(), "displayName": "Friend"})).unwrap();
        // Change memory directly so the reset must flush it to the old vault.
        runtime
            .chat
            .send_text("general", "survives engine recreation", 123)
            .unwrap();
        runtime
            .begin_platform_session(DesktopVault::new(folder.0.clone()))
            .unwrap();
        assert_eq!(runtime.call("hasIdentity", &Value::Null).unwrap(), false);
        assert!(runtime.call("identity", &Value::Null).is_err());
        assert_eq!(
            runtime.call("listSavedIdentities", &Value::Null).unwrap()[0]["displayName"],
            "Alice"
        );
        runtime
            .call(
                "unlockIdentity",
                &json!({"identityId": local.public_identity().id, "pin": "918273"}),
            )
            .unwrap();
        assert_eq!(
            runtime.call("contacts", &Value::Null).unwrap()[0]["displayName"],
            "Friend"
        );
        assert!(
            runtime
                .call("snapshot", &Value::Null)
                .unwrap()
                .to_string()
                .contains("survives engine recreation")
        );
        runtime
            .begin_platform_session(DesktopVault::new(folder.0.clone()))
            .unwrap();
        runtime
            .begin_platform_session(DesktopVault::new(folder.0.clone()))
            .unwrap();
        assert_eq!(runtime.call("hasIdentity", &Value::Null).unwrap(), false);
    }

    #[cfg(windows)]
    #[test]
    fn desktop_pin_restores_keys_contacts_profile_and_rooms_after_restart() {
        let folder = TestVault::new();
        let local = crate::IdentityManager::create().unwrap();
        let friend = crate::IdentityManager::create().unwrap();
        let id = &local.public_identity().id;
        {
            let mut runtime = folder.runtime();
            runtime
                .call("restoreIdentity", &json!({"phrase": local.mnemonic()}))
                .unwrap();
            runtime
                .call(
                    "rememberIdentity",
                    &json!({"pin": "918273645012", "displayName": "Alice"}),
                )
                .unwrap();
            runtime.call("addContact", &json!({"cardJson": friend.contact_card_with_name("Friend").unwrap().to_json().unwrap(), "displayName": "Work friend"})).unwrap();
            runtime
                .call(
                    "markContactVerified",
                    &json!({"identityId": friend.public_identity().id}),
                )
                .unwrap();
            runtime.call("sendText", &json!({"conversationId": "general", "text": "private account message", "sentAtMilliseconds": 123})).unwrap();
        }
        let encoded = std::fs::read_to_string(
            folder
                .0
                .join("identities")
                .join(format!("{}.json", &id[8..])),
        )
        .unwrap();
        assert!(!encoded.contains(local.mnemonic()));
        assert!(!encoded.contains("918273645012"));
        assert!(!encoded.contains("entropy"));
        let mut reopened = folder.runtime();
        assert_eq!(reopened.call("hasIdentity", &Value::Null).unwrap(), false);
        assert_eq!(
            reopened.call("listSavedIdentities", &Value::Null).unwrap()[0]["displayName"],
            "Alice"
        );
        assert_eq!(
            reopened
                .call(
                    "unlockIdentity",
                    &json!({"identityId": id, "pin": "918273645012"})
                )
                .unwrap()["id"],
            *id
        );
        let contacts = reopened.call("contacts", &Value::Null).unwrap();
        assert_eq!(contacts[0]["displayName"], "Work friend");
        assert_eq!(contacts[0]["verified"], true);
        assert_eq!(
            reopened.call("loadDesktopProfile", &Value::Null).unwrap()["name"],
            "Alice"
        );
        assert!(
            reopened
                .call("snapshot", &Value::Null)
                .unwrap()
                .to_string()
                .contains("private account message")
        );
    }

    #[cfg(windows)]
    #[test]
    fn desktop_identity_selection_isolates_accounts_and_rejects_wrong_pins() {
        let folder = TestVault::new();
        let alice = crate::IdentityManager::create().unwrap();
        let bob = crate::IdentityManager::create().unwrap();
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase": alice.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin": "123456", "displayName": "Alice"}),
            )
            .unwrap();
        runtime.call("sendText", &json!({"conversationId": "general", "text": "Alice only", "sentAtMilliseconds": 1})).unwrap();
        runtime.call("lockIdentity", &Value::Null).unwrap();
        runtime
            .call("restoreIdentity", &json!({"phrase": bob.mnemonic()}))
            .unwrap();
        assert!(
            !runtime
                .call("snapshot", &Value::Null)
                .unwrap()
                .to_string()
                .contains("Alice only")
        );
        assert_eq!(
            runtime.call("loadDesktopProfile", &Value::Null).unwrap()["name"],
            ""
        );
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin": "654321", "displayName": "Bob"}),
            )
            .unwrap();
        assert_eq!(
            runtime
                .call("listSavedIdentities", &Value::Null)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );
        runtime.call("lockIdentity", &Value::Null).unwrap();
        assert!(
            runtime
                .call(
                    "unlockIdentity",
                    &json!({"identityId": alice.public_identity().id, "pin": "654321"})
                )
                .is_err()
        );
        assert_eq!(runtime.call("hasIdentity", &Value::Null).unwrap(), false);
        runtime
            .call(
                "unlockIdentity",
                &json!({"identityId": alice.public_identity().id, "pin": "123456"}),
            )
            .unwrap();
        assert!(
            runtime
                .call("snapshot", &Value::Null)
                .unwrap()
                .to_string()
                .contains("Alice only")
        );
        assert_eq!(
            runtime.call("loadDesktopProfile", &Value::Null).unwrap()["name"],
            "Alice"
        );
    }

    #[cfg(windows)]
    #[test]
    fn pin_attempt_limit_survives_restart_and_phrase_can_reset_the_pin() {
        let folder = TestVault::new();
        let identity = crate::IdentityManager::create().unwrap();
        let id = &identity.public_identity().id;
        let mut runtime = folder.runtime();
        runtime
            .call("restoreIdentity", &json!({"phrase": identity.mnemonic()}))
            .unwrap();
        runtime
            .call(
                "rememberIdentity",
                &json!({"pin": "123456", "displayName": "Test"}),
            )
            .unwrap();
        runtime.call("lockIdentity", &Value::Null).unwrap();
        for _ in 0..5 {
            assert!(
                runtime
                    .call(
                        "unlockIdentity",
                        &json!({"identityId": id, "pin": "000000"})
                    )
                    .is_err()
            );
        }
        drop(runtime);
        let mut reopened = folder.runtime();
        let error = reopened
            .call(
                "unlockIdentity",
                &json!({"identityId": id, "pin": "123456"}),
            )
            .unwrap_err();
        assert!(error.contains("wait 30 seconds"));
        reopened
            .call("restoreIdentity", &json!({"phrase": identity.mnemonic()}))
            .unwrap();
        reopened
            .call(
                "rememberIdentity",
                &json!({"pin": "987654", "displayName": "Recovered"}),
            )
            .unwrap();
        reopened.call("lockIdentity", &Value::Null).unwrap();
        assert_eq!(
            reopened
                .call(
                    "unlockIdentity",
                    &json!({"identityId": id, "pin": "987654"})
                )
                .unwrap()["id"],
            *id
        );
    }

    #[test]
    fn native_runtime_creates_and_confirms_an_identity() {
        let mut runtime = NativeRuntime::new().expect("runtime should initialize");
        assert_eq!(
            runtime
                .call("hasIdentity", &Value::Null)
                .expect("identity status should work"),
            json!(false)
        );

        let created = runtime
            .call("createIdentity", &Value::Null)
            .expect("identity should generate");
        let phrase = created["mnemonic"]
            .as_str()
            .expect("created identity should contain its mnemonic");
        let confirmed = runtime
            .call("confirmRecovery", &json!({"phrase": phrase}))
            .expect("recovery phrase should confirm");

        assert!(
            confirmed["id"]
                .as_str()
                .expect("identity should contain an id")
                .starts_with("did:cht:")
        );
    }

    #[test]
    fn native_runtime_discards_an_unconfirmed_identity() {
        let mut runtime = NativeRuntime::new().expect("runtime should initialize");
        runtime
            .call("createIdentity", &Value::Null)
            .expect("identity should generate");
        runtime
            .call("discardPendingIdentity", &Value::Null)
            .expect("pending identity should be discarded");

        assert_eq!(
            runtime
                .call("hasIdentity", &Value::Null)
                .expect("identity status should work"),
            json!(false)
        );
    }
}
