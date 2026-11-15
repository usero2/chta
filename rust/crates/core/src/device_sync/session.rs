use super::*;
use snow::{HandshakeState, TransportState};

pub(crate) enum DeviceSession {
    Handshake(Box<HandshakeState>),
    Transport(Box<TransportState>),
}
impl DeviceSession {
    pub fn prepare(
        local: &DeviceEngine,
        remote: &DeviceCertificate,
        session: &str,
        initiator: bool,
    ) -> Result<(Self, Option<String>), String> {
        let (a, b) = if initiator {
            (&local.certificate.device_id, &remote.device_id)
        } else {
            (&remote.device_id, &local.certificate.device_id)
        };
        let prologue = canonical(
            b"chta device noise kk v1\0",
            &json!([
                local.certificate.owner_id,
                a,
                b,
                "initiator",
                "responder",
                session
            ]),
        )?;
        let remote_key = decode::<32>(&remote.noise_public_key)?;
        let builder = snow::Builder::new(
            "Noise_KK_25519_ChaChaPoly_SHA256"
                .parse()
                .map_err(|_| "Invalid Noise parameters")?,
        )
        .local_private_key(local.noise_key.as_ref())
        .map_err(|e| e.to_string())?
        .remote_public_key(&remote_key)
        .map_err(|e| e.to_string())?
        .prologue(&prologue)
        .map_err(|e| e.to_string())?;
        let mut state = if initiator {
            builder.build_initiator()
        } else {
            builder.build_responder()
        }
        .map_err(|e| e.to_string())?;
        let frame = if initiator {
            Some(write_handshake(&mut state)?)
        } else {
            None
        };
        Ok((Self::Handshake(Box::new(state)), frame))
    }
    pub fn handshake(self, frame: &str) -> Result<(Self, Option<String>, bool), String> {
        let Self::Handshake(mut state) = self else {
            return Err("Device session already authenticated".into());
        };
        let data = bounded_frame(frame)?;
        let mut output = vec![0u8; 1024];
        let size = state
            .read_message(&data, &mut output)
            .map_err(|_| "Device handshake authentication failed")?;
        if size != 0 {
            return Err("Unexpected device handshake payload".into());
        }
        let reply = if !state.is_handshake_finished() {
            Some(write_handshake(&mut state)?)
        } else {
            None
        };
        let ready = state.is_handshake_finished();
        if ready {
            Ok((
                Self::Transport(Box::new(
                    state.into_transport_mode().map_err(|e| e.to_string())?,
                )),
                reply,
                true,
            ))
        } else {
            Ok((Self::Handshake(state), reply, false))
        }
    }
    pub fn seal(&mut self, text: &str) -> Result<String, String> {
        let Self::Transport(state) = self else {
            return Err("Device is not authenticated".into());
        };
        // Base64 and the transport wrapper must fit the existing 16 KiB ceiling.
        if text.len() > 11_000 {
            return Err("Device plaintext fragment too large".into());
        }
        let mut out = vec![0u8; text.len() + 16];
        let size = state
            .write_message(text.as_bytes(), &mut out)
            .map_err(|e| e.to_string())?;
        Ok(URL_SAFE_NO_PAD.encode(&out[..size]))
    }
    pub fn open(&mut self, frame: &str) -> Result<String, String> {
        let Self::Transport(state) = self else {
            return Err("Device is not authenticated".into());
        };
        let data = bounded_frame(frame)?;
        let mut out = zeroize::Zeroizing::new(vec![0u8; data.len()]);
        let size = state
            .read_message(&data, &mut out)
            .map_err(|_| "Device ciphertext authentication failed")?;
        String::from_utf8(out[..size].to_vec()).map_err(|_| "Invalid device plaintext".into())
    }
}
fn write_handshake(state: &mut HandshakeState) -> Result<String, String> {
    let mut out = vec![0u8; 1024];
    let size = state
        .write_message(&[], &mut out)
        .map_err(|e| e.to_string())?;
    Ok(URL_SAFE_NO_PAD.encode(&out[..size]))
}
fn bounded_frame(frame: &str) -> Result<Vec<u8>, String> {
    if frame.len() > 15_000 {
        return Err("Device frame too large".into());
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(frame)
        .map_err(|_| "Invalid device frame")?;
    if URL_SAFE_NO_PAD.encode(&bytes) != frame {
        return Err("Noncanonical device frame".into());
    }
    Ok(bytes)
}
