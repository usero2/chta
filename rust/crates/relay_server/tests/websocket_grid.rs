use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use cht_relay::websocket::{self, WebSocketConfig};
use cht_relay_protocol::{RelayProof, RelayRecord};
use ed25519_dalek::SigningKey;
use futures::{SinkExt, StreamExt};
use libp2p::identity::Keypair;
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};
use tokio::net::TcpStream;
use tokio::time::{sleep, timeout};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite::Message};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
struct Node {
    url: String,
    task: tokio::task::JoinHandle<()>,
    _dir: tempfile::TempDir,
}
impl Drop for Node {
    fn drop(&mut self) {
        self.task.abort();
    }
}
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}
async fn node(port: u16, bootstraps: Vec<String>) -> Node {
    node_with_budget(
        port,
        bootstraps,
        WebSocketConfig::default().bytes_per_minute,
    )
    .await
}
async fn node_with_budget(port: u16, bootstraps: Vec<String>, bytes_per_minute: usize) -> Node {
    let url = format!("ws://127.0.0.1:{port}/cht");
    let config = WebSocketConfig {
        listen: format!("127.0.0.1:{port}").parse().unwrap(),
        public_url: url.clone(),
        bootstrap_urls: bootstraps,
        allow_loopback: true,
        bytes_per_minute,
        ..WebSocketConfig::default()
    };
    let dir = tempfile::tempdir().unwrap();
    let state: PathBuf = dir.path().to_owned();
    let task = tokio::spawn(async move {
        websocket::run(config, Keypair::generate_ed25519(), state)
            .await
            .unwrap();
    });
    let node = Node {
        url,
        task,
        _dir: dir,
    };
    for _ in 0..100 {
        if TcpStream::connect(
            node.url
                .trim_start_matches("ws://")
                .trim_end_matches("/cht"),
        )
        .await
        .is_ok()
        {
            return node;
        }
        sleep(Duration::from_millis(20)).await;
    }
    panic!("relay did not start");
}
async fn next_json(socket: &mut Socket) -> Value {
    loop {
        let message = timeout(Duration::from_secs(25), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if message.is_text() {
            return serde_json::from_str(message.to_text().unwrap()).unwrap();
        }
    }
}
async fn registered(url: &str, key: &SigningKey) -> (Socket, String) {
    registered_with_catalog(url, key, true).await
}
async fn registered_with_catalog(url: &str, key: &SigningKey, subscribe: bool) -> (Socket, String) {
    let mut socket = websocket::connect_endpoint(url, true).await.unwrap();
    let challenge = next_json(&mut socket).await;
    let record: RelayRecord = serde_json::from_value(challenge["relay"].clone()).unwrap();
    record.verify(websocket::now(), true).unwrap();
    let proof =
        RelayProof::signed(key, challenge["nonce"].as_str().unwrap(), &record.relay_id).unwrap();
    let id = proof.identity_id.clone();
    socket
        .send(Message::text(
            json!({"type":"register", "proof":proof, "subscribeCatalog":subscribe}).to_string(),
        ))
        .await
        .unwrap();
    loop {
        if next_json(&mut socket).await["type"] == "registered" {
            break;
        }
    }
    (socket, id)
}

#[tokio::test]
async fn throttled_reads_do_not_block_reverse_traffic() {
    timeout(Duration::from_secs(10), async {
        let server = node_with_budget(free_port(), vec![], 65536).await;
        let (mut alice, alice_id) = registered_with_catalog(&server.url, &SigningKey::from_bytes(&[44;32]), false).await;
        let (mut bob, bob_id) = registered_with_catalog(&server.url, &SigningKey::from_bytes(&[45;32]), false).await;
        let large=json!({"type":"route","to":bob_id,"session":"a".repeat(32),"packet":"b".repeat(32),"body":{"type":"encrypted","payload":"x".repeat(60*1024)}}).to_string();
        alice.send(Message::text(large.clone())).await.unwrap();
        while next_json(&mut bob).await["type"]!="route" {}
        alice.send(Message::text(large)).await.unwrap();
        // This frame cannot spend its byte budget for roughly a minute.
        // The reverse direction still has to flow while it waits.
        bob.send(Message::text(json!({"type":"route","to":alice_id,"session":"a".repeat(32),"packet":"c".repeat(32),"body":{"type":"encrypted","payload":"reverse"}}).to_string())).await.unwrap();
        loop {
            let frame=next_json(&mut alice).await;
            if frame["type"]=="route" { assert_eq!(frame["body"]["payload"],"reverse"); break; }
        }
    }).await.expect("a paced read must not stall outbound forwarding");
}

#[tokio::test]
async fn bulk_transfer_survives_the_byte_budget_without_disconnect() {
    timeout(Duration::from_secs(40), async {
        let server = node(free_port(), vec![]).await;
        let (mut alice, _) = registered_with_catalog(&server.url, &SigningKey::from_bytes(&[41;32]), false).await;
        let (mut bob, bob_id) = registered_with_catalog(&server.url, &SigningKey::from_bytes(&[42;32]), false).await;
        let payload = "x".repeat(32 * 1024);
        for index in 0..300u32 {
            alice.send(Message::text(json!({"type":"route","to":bob_id,"session":"a".repeat(32),"packet":format!("{index:032x}"),"body":{"type":"encrypted","payload":payload}}).to_string())).await.unwrap();
            loop {
                let frame=next_json(&mut bob).await;
                if frame["type"]=="route" {
                    assert_eq!(frame["packet"],format!("{index:032x}"));
                    assert_eq!(frame["body"]["payload"],payload);
                    break;
                }
            }
        }
        alice.send(Message::text("{\"type\":\"keepalive\"}")).await.unwrap();
        while next_json(&mut alice).await["type"]!="alive" {}
    }).await.expect("bulk stream must remain usable above 8 MiB");
}

#[tokio::test]
async fn bulk_transfer_survives_the_message_budget_without_disconnect() {
    timeout(Duration::from_secs(30), async {
        let server = node(free_port(), vec![]).await;
        let (mut socket, _) =
            registered_with_catalog(&server.url, &SigningKey::from_bytes(&[43; 32]), false).await;
        for _ in 0..1210 {
            socket
                .send(Message::text("{\"type\":\"keepalive\"}"))
                .await
                .unwrap();
            while next_json(&mut socket).await["type"] != "alive" {}
        }
    })
    .await
    .expect("message bursts must be paced instead of disconnected");
}

#[tokio::test]
async fn backup_connection_can_use_small_authenticated_keepalives() {
    let server = node(free_port(), vec![]).await;
    let (mut socket, _) =
        registered_with_catalog(&server.url, &SigningKey::from_bytes(&[7u8; 32]), false).await;
    socket
        .send(Message::text("{\"type\":\"keepalive\"}"))
        .await
        .unwrap();
    loop {
        let frame = next_json(&mut socket).await;
        if frame["type"] == "alive" {
            break;
        }
    }
}

#[tokio::test]
async fn relay_hints_propagate_across_three_nodes() {
    timeout(Duration::from_secs(45), async {
        let c_port = free_port();
        let b_port = free_port();
        let a_port = free_port();
        let c = node(c_port, vec![]).await;
        let b = node(b_port, vec![c.url.clone()]).await;
        let a = node(a_port, vec![b.url.clone()]).await;
        let mut socket = websocket::connect_endpoint(&a.url, true).await.unwrap();
        let _ = next_json(&mut socket).await;
        socket
            .send(Message::text(
                json!({"type":"directory", "relays":[]}).to_string(),
            ))
            .await
            .unwrap();
        loop {
            let value = next_json(&mut socket).await;
            if let Some(records) = value["relays"].as_array() {
                let urls: Vec<_> = records
                    .iter()
                    .map(|r| r["endpoint"].as_str().unwrap())
                    .collect();
                if [&a.url, &b.url, &c.url]
                    .iter()
                    .all(|url| urls.contains(&url.as_str()))
                {
                    break;
                }
            }
        }
    })
    .await
    .expect("relay directory did not converge across A -> B -> C");
}

#[tokio::test]
async fn authenticated_routing_binds_sender_and_rejects_replayed_registration() {
    timeout(Duration::from_secs(15), async {
        let server = node(free_port(), vec![]).await;
        let (mut alice, alice_id) = registered(&server.url, &SigningKey::from_bytes(&[1u8;32])).await;
        let (mut bob, bob_id) = registered(&server.url, &SigningKey::from_bytes(&[2u8;32])).await;
        alice.send(Message::text(json!({"type":"route", "from":bob_id, "to":bob_id, "session":"a".repeat(32), "packet":"b".repeat(32), "body":{"type":"encrypted", "payload":"opaque-ciphertext"}}).to_string())).await.unwrap();
        loop {
            let frame = next_json(&mut bob).await;
            if frame["type"] == "route" { assert_eq!(frame["from"], alice_id); assert_eq!(frame["body"]["payload"], "opaque-ciphertext"); break; }
        }
        let mut unauthorized = websocket::connect_endpoint(&server.url, true).await.unwrap();
        let challenge = next_json(&mut unauthorized).await;
        let record: RelayRecord = serde_json::from_value(challenge["relay"].clone()).unwrap();
        let wrong = RelayProof::signed(&SigningKey::from_bytes(&[3u8;32]), &B64.encode([9u8;32]), &record.relay_id).unwrap();
        unauthorized.send(Message::text(json!({"type":"register", "proof":wrong}).to_string())).await.unwrap();
        loop {
            match unauthorized.next().await {
                None | Some(Err(_)) | Some(Ok(Message::Close(_))) => break,
                Some(Ok(Message::Text(value))) => assert_ne!(serde_json::from_str::<Value>(&value).unwrap()["type"], "registered"),
                _ => {}
            }
        }
    }).await.expect("registration/routing test timed out");
}
