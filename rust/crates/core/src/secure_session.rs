use std::collections::{BTreeSet, VecDeque};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use snow::{Builder, HandshakeState, TransportState, params::NoiseParams};

use crate::{IdentityManager, PublicIdentity};

const NOISE_PATTERN: &str = "Noise_KK_25519_ChaChaPoly_SHA256";
const ENVELOPE_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionError {
    InvalidPeerKey(String),
    Noise(String),
    InvalidState(&'static str),
    InvalidEnvelope(String),
    UnsupportedEnvelopeVersion(u32),
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidPeerKey(value) => write!(formatter, "invalid peer Noise key: {value}"),
            Self::Noise(value) => write!(formatter, "Noise session error: {value}"),
            Self::InvalidState(value) => write!(formatter, "invalid session state: {value}"),
            Self::InvalidEnvelope(value) => write!(formatter, "invalid message envelope: {value}"),
            Self::UnsupportedEnvelopeVersion(value) => {
                write!(formatter, "unsupported message envelope version: {value}")
            }
        }
    }
}

impl std::error::Error for SessionError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecryptedMessage {
    pub message_id: String,
    pub plaintext: Vec<u8>,
    pub duplicate: bool,
    pub sent_at_milliseconds: Option<i64>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageEnvelope {
    version: u32,
    message_id: String,
    plaintext: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sent_at_milliseconds: Option<i64>,
}

pub struct SecureSession {
    handshake: Option<HandshakeState>,
    transport: Option<TransportState>,
    initiator: bool,
    seen_message_ids: BTreeSet<String>,
    seen_message_order: VecDeque<String>,
}

impl SecureSession {
    pub fn initiator(
        local: &IdentityManager,
        remote: &PublicIdentity,
    ) -> Result<Self, SessionError> {
        Self::build(local, remote, true)
    }

    pub fn responder(
        local: &IdentityManager,
        remote: &PublicIdentity,
    ) -> Result<Self, SessionError> {
        Self::build(local, remote, false)
    }

    pub(crate) fn contextual(
        local: &IdentityManager,
        remote: &PublicIdentity,
        initiator: bool,
        session_id: &str,
        context: &str,
    ) -> Result<Self, SessionError> {
        let prologue = match context {
            "groups" => format!("chta group noise v1\0{session_id}"),
            "dm-v2" => format!("chta direct message noise v2\0{session_id}"),
            _ => return Err(SessionError::InvalidState("Unknown peer session context")),
        };
        Self::build_with_prologue(local, remote, initiator, prologue.as_bytes())
    }

    pub fn start_handshake(&mut self) -> Result<Vec<u8>, SessionError> {
        if !self.initiator {
            return Err(SessionError::InvalidState(
                "only the initiator starts the handshake",
            ));
        }
        let handshake = self
            .handshake
            .as_mut()
            .ok_or(SessionError::InvalidState("handshake is not available"))?;
        let mut output = vec![0_u8; 65_535];
        let written = handshake
            .write_message(&[], &mut output)
            .map_err(|error| SessionError::Noise(error.to_string()))?;
        output.truncate(written);
        self.promote_if_finished()?;
        Ok(output)
    }

    pub fn receive_handshake(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>, SessionError> {
        let handshake = self
            .handshake
            .as_mut()
            .ok_or(SessionError::InvalidState("handshake is not available"))?;
        let mut discarded_payload = vec![0_u8; 65_535];
        handshake
            .read_message(frame, &mut discarded_payload)
            .map_err(|error| SessionError::Noise(error.to_string()))?;

        let reply = if !self.initiator && !handshake.is_handshake_finished() {
            let mut output = vec![0_u8; 65_535];
            let written = handshake
                .write_message(&[], &mut output)
                .map_err(|error| SessionError::Noise(error.to_string()))?;
            output.truncate(written);
            Some(output)
        } else {
            None
        };
        self.promote_if_finished()?;
        Ok(reply)
    }

    pub fn is_established(&self) -> bool {
        self.transport.is_some()
    }

    pub fn encrypt_message(
        &mut self,
        message_id: &str,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, SessionError> {
        self.encrypt_message_at(message_id, plaintext, None)
    }

    pub fn encrypt_message_at(
        &mut self,
        message_id: &str,
        plaintext: &[u8],
        sent_at_milliseconds: Option<i64>,
    ) -> Result<Vec<u8>, SessionError> {
        let envelope = serde_json::to_vec(&MessageEnvelope {
            version: ENVELOPE_VERSION,
            message_id: message_id.to_owned(),
            plaintext: URL_SAFE_NO_PAD.encode(plaintext),
            sent_at_milliseconds,
        })
        .map_err(|error| SessionError::InvalidEnvelope(error.to_string()))?;
        let transport = self
            .transport
            .as_mut()
            .ok_or(SessionError::InvalidState("session is not established"))?;
        let mut output = vec![0_u8; envelope.len() + 32];
        let written = transport
            .write_message(&envelope, &mut output)
            .map_err(|error| SessionError::Noise(error.to_string()))?;
        output.truncate(written);
        Ok(output)
    }

    pub fn decrypt_message(&mut self, ciphertext: &[u8]) -> Result<DecryptedMessage, SessionError> {
        let transport = self
            .transport
            .as_mut()
            .ok_or(SessionError::InvalidState("session is not established"))?;
        let mut plaintext = vec![0_u8; ciphertext.len()];
        let written = transport
            .read_message(ciphertext, &mut plaintext)
            .map_err(|error| SessionError::Noise(error.to_string()))?;
        plaintext.truncate(written);
        let envelope: MessageEnvelope = serde_json::from_slice(&plaintext)
            .map_err(|error| SessionError::InvalidEnvelope(error.to_string()))?;
        if envelope.version != ENVELOPE_VERSION {
            return Err(SessionError::UnsupportedEnvelopeVersion(envelope.version));
        }
        let decoded = URL_SAFE_NO_PAD
            .decode(&envelope.plaintext)
            .map_err(|error| SessionError::InvalidEnvelope(error.to_string()))?;
        let duplicate = !self.seen_message_ids.insert(envelope.message_id.clone());
        if !duplicate {
            self.seen_message_order
                .push_back(envelope.message_id.clone());
            if self.seen_message_order.len() > 4096
                && let Some(expired) = self.seen_message_order.pop_front()
            {
                self.seen_message_ids.remove(&expired);
            }
        }
        Ok(DecryptedMessage {
            message_id: envelope.message_id,
            plaintext: decoded,
            duplicate,
            sent_at_milliseconds: envelope.sent_at_milliseconds,
        })
    }

    fn build(
        local: &IdentityManager,
        remote: &PublicIdentity,
        initiator: bool,
    ) -> Result<Self, SessionError> {
        Self::build_with_prologue(local, remote, initiator, b"")
    }

    fn build_with_prologue(
        local: &IdentityManager,
        remote: &PublicIdentity,
        initiator: bool,
        prologue: &[u8],
    ) -> Result<Self, SessionError> {
        let params: NoiseParams = NOISE_PATTERN
            .parse()
            .map_err(|error: snow::Error| SessionError::Noise(error.to_string()))?;
        let local_private = local.noise_static_secret().to_bytes();
        let remote_public = URL_SAFE_NO_PAD
            .decode(&remote.noise_static_public_key)
            .map_err(|error| SessionError::InvalidPeerKey(error.to_string()))?;
        let builder = Builder::new(params)
            .prologue(prologue)
            .map_err(|error| SessionError::Noise(error.to_string()))?
            .local_private_key(&local_private)
            .and_then(|builder| builder.remote_public_key(&remote_public))
            .map_err(|error| SessionError::Noise(error.to_string()))?;
        let handshake = if initiator {
            builder.build_initiator()
        } else {
            builder.build_responder()
        }
        .map_err(|error| SessionError::Noise(error.to_string()))?;
        Ok(Self {
            handshake: Some(handshake),
            transport: None,
            initiator,
            seen_message_ids: BTreeSet::new(),
            seen_message_order: VecDeque::new(),
        })
    }

    fn promote_if_finished(&mut self) -> Result<(), SessionError> {
        if self
            .handshake
            .as_ref()
            .is_some_and(HandshakeState::is_handshake_finished)
        {
            let handshake = self.handshake.take().expect("checked handshake is present");
            self.transport = Some(
                handshake
                    .into_transport_mode()
                    .map_err(|error| SessionError::Noise(error.to_string()))?,
            );
        }
        Ok(())
    }
}
