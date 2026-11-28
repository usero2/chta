use std::{io::Cursor, time::Duration};

use serde_json::json;
use tokio::{
    io::{self, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::TcpStream,
    time::timeout,
};

use crate::RelayResult;

use super::COURIER_CAPABILITIES;

const MAX_HEAD_BYTES: u64 = 16 * 1024;
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);

/// Inspect only a bounded HTTP request head, then replay it to the normal
/// WebSocket upgrade handler when it is for another route.
pub(super) async fn route(
    stream: TcpStream,
) -> RelayResult<Option<impl AsyncRead + AsyncWrite + Unpin>> {
    let mut stream = BufReader::new(stream);
    let mut head = Vec::new();
    let mut bounded = (&mut stream).take(MAX_HEAD_BYTES);
    let complete = timeout(HEADER_TIMEOUT, async {
        loop {
            if bounded.read_until(b'\n', &mut head).await? == 0 {
                return Ok::<_, std::io::Error>(false);
            }
            if head.ends_with(b"\r\n\r\n") {
                return Ok(true);
            }
        }
    })
    .await??;
    if !complete {
        return Ok(None);
    }

    let mut headers = [httparse::EMPTY_HEADER; 128];
    let mut request = httparse::Request::new(&mut headers);
    if request.parse(&head)?.is_complete() && request.path == Some("/healthz") {
        let reply = match request.method {
            Some("GET") => HealthReply::Get,
            Some("HEAD") => HealthReply::Head,
            _ => HealthReply::MethodNotAllowed,
        };
        timeout(HEADER_TIMEOUT, write_reply(&mut stream, reply)).await??;
        return Ok(None);
    }

    let (reader, writer) = io::split(stream);
    Ok(Some(io::join(Cursor::new(head).chain(reader), writer)))
}

enum HealthReply {
    Get,
    Head,
    MethodNotAllowed,
}

async fn write_reply(
    stream: &mut (impl AsyncWrite + Unpin),
    reply: HealthReply,
) -> std::io::Result<()> {
    let body = json!({
        "ok": true,
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": "chta-data-relay",
        "protocolVersion": 1,
        "capabilities": [
            "websocket-v1",
            "root-auth-v1",
            "signed-relay-directory-v1",
            COURIER_CAPABILITIES[0],
            COURIER_CAPABILITIES[1]
        ],
        "offlineStorage": false,
    })
    .to_string();
    let common_headers = "Cache-Control: no-store\r\nConnection: close\r\n";
    let response = match reply {
        HealthReply::MethodNotAllowed => format!(
            "HTTP/1.1 405 Method Not Allowed\r\nAllow: GET, HEAD\r\nContent-Length: 0\r\n{common_headers}\r\n"
        ),
        HealthReply::Get | HealthReply::Head => {
            let payload = if matches!(reply, HealthReply::Get) {
                &body
            } else {
                ""
            };
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Content-Type-Options: nosniff\r\nContent-Length: {}\r\n{common_headers}\r\n{payload}",
                body.len()
            )
        }
    };
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await
}
