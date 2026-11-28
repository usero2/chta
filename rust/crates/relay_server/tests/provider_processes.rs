//! Disposable native processes, not owner relay profiles or public providers.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use cht_relay::{
    config::Config,
    websocket::{self, WebSocketConfig},
};
use cht_relay_protocol::{RelayProof, RelayRecord};
use ed25519_dalek::{Signer, SigningKey};
use futures::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Child, Command, Stdio},
    time::Duration,
};
use tokio::{
    net::TcpStream,
    time::{sleep, timeout},
};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, tungstenite::Message};
type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
fn advertisement(root: &SigningKey, route: &str) -> Value {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Certificate {
        version: u32,
        owner_id: String,
        root_public_key: String,
        node_id: String,
        signing_public_key: String,
        created_at: u64,
        signature: String,
    }
    fn sign<T: Serialize>(key: &SigningKey, domain: &[u8], value: &T) -> String {
        let mut bytes = domain.to_vec();
        bytes.extend(serde_json::to_vec(value).unwrap());
        B64.encode(key.sign(&bytes).to_bytes())
    }
    let node = SigningKey::from_bytes(&[63; 32]);
    let now = websocket::now();
    let mut c = Certificate {
        version: 1,
        owner_id: format!(
            "did:cht:{}",
            cht_relay_protocol::key_id(root.verifying_key().as_bytes())
        ),
        root_public_key: B64.encode(root.verifying_key().as_bytes()),
        node_id: cht_relay_protocol::key_id(node.verifying_key().as_bytes()),
        signing_public_key: B64.encode(node.verifying_key().as_bytes()),
        created_at: now,
        signature: String::new(),
    };
    c.signature = sign(
        root,
        b"chta courier node certificate v1\0",
        &(
            c.version,
            &c.owner_id,
            &c.root_public_key,
            &c.node_id,
            &c.signing_public_key,
            c.created_at,
        ),
    );
    let body = json!({"version":1,"nodeId":c.node_id,"ownerId":c.owner_id,"routes":[route],"maxPackageBytes":262144,"freeBytes":1073741824u64});
    let challenge = B64.encode([0u8; 32]);
    let signature = sign(
        &node,
        b"chta courier control v1\0",
        &(
            1,
            "advertisement",
            &c.node_id,
            &c.signing_public_key,
            &c,
            &challenge,
            &body,
            now,
            now + 900000,
        ),
    );
    json!({"version":1,"kind":"advertisement","signerId":c.node_id,"publicKey":c.signing_public_key,"certificate":c,"challenge":challenge,"body":body,"issuedAt":now,"expiresAt":now+900000,"signature":signature})
}
struct Node {
    child: Child,
    url: String,
    _dir: tempfile::TempDir,
    _password: tempfile::NamedTempFile,
}
impl Drop for Node {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
async fn node() -> Node {
    let dir = tempfile::tempdir().unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let url = format!("ws://127.0.0.1:{port}/cht");
    let mut password = tempfile::NamedTempFile::new_in(dir.path()).unwrap();
    password
        .write_all(b"disposable-provider-process-test-credential-123456")
        .unwrap();
    let config = Config {
        tcp_enabled: false,
        public_addresses: vec![],
        state_dir: dir.path().join("state"),
        websocket: Some(WebSocketConfig {
            listen: format!("127.0.0.1:{port}").parse().unwrap(),
            public_url: url.clone(),
            allow_loopback: true,
            ..WebSocketConfig::default()
        }),
        ..Config::default()
    };
    let path = dir.path().join("relay.json");
    std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cht-relay"))
        .arg("--config")
        .arg(&path)
        .env("CHT_RELAY_KEY_PASSWORD_FILE", password.path())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut node = Node {
        child,
        url,
        _dir: dir,
        _password: password,
    };
    for _ in 0..500 {
        assert!(
            node.child.try_wait().unwrap().is_none(),
            "owned test relay exited"
        );
        if TcpStream::connect(format!("127.0.0.1:{port}"))
            .await
            .is_ok()
        {
            return node;
        }
        sleep(Duration::from_millis(20)).await;
    }
    panic!("test relay did not listen");
}
async fn next(ws: &mut Socket, kind: &str) -> Value {
    timeout(Duration::from_secs(8), async {
        loop {
            let m = ws.next().await.unwrap().unwrap();
            if !m.is_text() {
                continue;
            }
            let v: Value = serde_json::from_str(m.to_text().unwrap()).unwrap();
            if v["type"] == kind {
                return v;
            }
        }
    })
    .await
    .unwrap()
}
async fn client(url: &str, key: &SigningKey) -> (Socket, String, String) {
    let mut ws = websocket::connect_endpoint(url, true).await.unwrap();
    let challenge = next(&mut ws, "challenge").await;
    let r: RelayRecord = serde_json::from_value(challenge["relay"].clone()).unwrap();
    r.verify(websocket::now(), true).unwrap();
    let proof = RelayProof::signed(key, challenge["nonce"].as_str().unwrap(), &r.relay_id).unwrap();
    let did = proof.identity_id.clone();
    ws.send(Message::text(
        json!({"type":"register","proof":proof,"subscribeCatalog":false}).to_string(),
    ))
    .await
    .unwrap();
    next(&mut ws, "registered").await;
    (ws, did, r.relay_id)
}

#[tokio::test(flavor = "multi_thread")]
async fn cli_probe_checks_registration_with_an_ephemeral_identity() {
    use tokio::task::spawn_blocking;
    let local = node().await;
    let endpoint = local.url.clone();
    let result = spawn_blocking(move || {
        Command::new(env!("CARGO_BIN_EXE_cht-relay"))
            .args(["--probe-websocket", &endpoint, "--allow-loopback-probe"])
            .env_remove("CHT_RELAY_KEY_PASSWORD_FILE")
            .output()
            .unwrap()
    })
    .await
    .unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let probe: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(probe["event"], "websocket_probe_ok");
    assert_eq!(probe["endpoint"], local.url);
    assert_eq!(probe["relayId"].as_str().unwrap().len(), 64);
}
#[tokio::test]
async fn independent_relay_processes_preserve_authenticated_route_after_one_stops() {
    let first = node().await;
    let second = node().await;
    let a = SigningKey::from_bytes(&[61; 32]);
    let b = SigningKey::from_bytes(&[62; 32]);
    let (mut a1, _, id1) = client(&first.url, &a).await;
    let (mut b1, to, _) = client(&first.url, &b).await;
    let (mut a2, _, id2) = client(&second.url, &a).await;
    let (mut b2, to2, _) = client(&second.url, &b).await;
    assert_ne!(id1, id2);
    let ad = advertisement(&a, &first.url);
    a1.send(Message::text(
        json!({"type":"couriers","records":[ad]}).to_string(),
    ))
    .await
    .unwrap();
    assert_eq!(next(&mut a1, "couriers").await["records"], json!([ad]));
    b1.send(Message::text(
        json!({"type":"couriers","records":[]}).to_string(),
    ))
    .await
    .unwrap();
    assert_eq!(next(&mut b1, "couriers").await["records"], json!([ad]));
    let frame = json!({"type":"route","to":to,"session":"a".repeat(32),"packet":"b".repeat(32),"body":{"type":"courier-v1","ciphertext":"synthetic-opaque-frame"}});
    a1.send(Message::text(frame.to_string())).await.unwrap();
    assert_eq!(next(&mut b1, "route").await["body"], frame["body"]);
    drop(first);
    let mut backup = frame.clone();
    backup["to"] = json!(to2);
    a2.send(Message::text(backup.to_string())).await.unwrap();
    assert_eq!(next(&mut b2, "route").await["body"], frame["body"]);
}
#[test]
fn public_operator_example_validates_without_opening_ports_or_creating_identity() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../apps/relay_node/relay.example.json");
    let config = Config::read(&path).unwrap();
    assert!(!config.tcp_enabled);
    assert!(!config.websocket.unwrap().allow_loopback);
}
