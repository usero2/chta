use std::time::Duration;

use cht_relay_protocol::{RelayProof, RelayRecord};
use ed25519_dalek::SigningKey;
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::{net::TcpStream, time::timeout};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite::Message};
use zeroize::Zeroizing;

use crate::RelayResult;

use super::{connect_endpoint, now};

const RESPONSE_TIMEOUT: Duration = Duration::from_secs(5);
type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Verify the public upgrade and real relay registration without loading a
/// local profile or writing an identity to disk.
pub async fn probe_endpoint(endpoint: &str, allow_loopback: bool) -> RelayResult<RelayRecord> {
    let mut socket = connect_endpoint(endpoint, allow_loopback).await?;
    let challenge = wait_for(&mut socket, "challenge").await?;
    let record: RelayRecord = serde_json::from_value(challenge["relay"].clone())
        .map_err(|error| format!("Invalid relay challenge record: {error}"))?;
    record.verify(now(), allow_loopback)?;
    if record.endpoint != endpoint {
        return Err("Relay endpoint does not match its signed record".into());
    }
    let nonce = challenge["nonce"].as_str().ok_or("Missing relay nonce")?;
    let mut secret = Zeroizing::new([0u8; 32]);
    getrandom::fill(secret.as_mut())?;
    let proof = RelayProof::signed(&SigningKey::from_bytes(&secret), nonce, &record.relay_id)?;
    timeout(
        RESPONSE_TIMEOUT,
        socket.send(Message::text(
            json!({"type":"register","proof":proof,"subscribeCatalog":false}).to_string(),
        )),
    )
    .await
    .map_err(|_| "Relay registration write timed out")??;
    wait_for(&mut socket, "registered").await?;
    timeout(
        RESPONSE_TIMEOUT,
        socket.send(Message::text(r#"{"type":"keepalive"}"#)),
    )
    .await
    .map_err(|_| "Relay keepalive write timed out")??;
    wait_for(&mut socket, "alive").await?;
    let _ = timeout(RESPONSE_TIMEOUT, socket.close(None)).await;
    Ok(record)
}

async fn wait_for(socket: &mut Socket, expected: &'static str) -> RelayResult<Value> {
    timeout(RESPONSE_TIMEOUT, async {
        while let Some(frame) = socket.next().await {
            match frame? {
                Message::Text(text) => {
                    let value: Value = serde_json::from_str(&text).map_err(|error| {
                        format!("Invalid relay response while waiting for {expected}: {error}")
                    })?;
                    if value["type"] == expected {
                        return Ok(value);
                    }
                }
                Message::Ping(_) => socket.flush().await?,
                Message::Close(_) => break,
                _ => {}
            }
        }
        Err(format!("Relay closed before sending {expected}").into())
    })
    .await
    .map_err(|_| format!("Relay response timed out while waiting for {expected}"))?
}
