//! Browser-compatible encrypted-session carrier and signed relay hint exchange.
//! This is a cht WebSocket protocol, independent of the Circuit Relay v2 listener.
use crate::RelayResult;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use cht_relay_protocol::{RelayDirectory, RelayProof, RelayRecord, validate_endpoint};
use ed25519_dalek::SigningKey;
use futures::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    net::{TcpListener, TcpStream, lookup_host},
    sync::{Semaphore, mpsc},
    time::{Instant, interval, sleep_until, timeout},
};
use tokio_tungstenite::{
    accept_hdr_async_with_config, client_async_tls_with_config,
    tungstenite::{
        Message,
        handshake::server::{ErrorResponse, Request, Response},
        protocol::WebSocketConfig as SocketConfig,
    },
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct WebSocketConfig {
    pub listen: SocketAddr,
    pub public_url: String,
    pub bootstrap_urls: Vec<String>,
    pub max_clients: usize,
    pub bytes_per_minute: usize,
    /// Local development only. Shared Internet configurations must keep false.
    pub allow_loopback: bool,
}
impl Default for WebSocketConfig {
    fn default() -> Self {
        Self {
            listen: "127.0.0.1:4002".parse().unwrap(),
            public_url: String::new(),
            bootstrap_urls: Vec::new(),
            max_clients: 128,
            bytes_per_minute: 8 * 1024 * 1024,
            allow_loopback: false,
        }
    }
}
impl WebSocketConfig {
    pub fn validate(&self) -> RelayResult<()> {
        validate_endpoint(&self.public_url, self.allow_loopback)?;
        if self.listen.port() == 0
            || !(1..=4096).contains(&self.max_clients)
            || !(65536..=1024 * 1024 * 1024).contains(&self.bytes_per_minute)
            || self.bootstrap_urls.len() > 8
        {
            return Err("Invalid WebSocket resource limits".into());
        }
        for value in &self.bootstrap_urls {
            validate_endpoint(value, self.allow_loopback)?;
        }
        Ok(())
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
type Clients = BTreeMap<String, BTreeMap<u64, mpsc::Sender<String>>>;
pub struct Hub {
    pub config: WebSocketConfig,
    key: SigningKey,
    directory: Mutex<RelayDirectory>,
    couriers: Mutex<cht_relay_protocol::CourierCatalog>,
    clients: Mutex<Clients>,
    sequence: AtomicU64,
    catalog_offset: AtomicU64,
}
struct ExchangeTask(tokio::task::JoinHandle<()>);
impl Drop for ExchangeTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}
impl Hub {
    pub fn new(config: WebSocketConfig, key: SigningKey) -> Self {
        Self {
            config,
            key,
            directory: Mutex::default(),
            couriers: Mutex::default(),
            clients: Mutex::default(),
            sequence: AtomicU64::new(1),
            catalog_offset: AtomicU64::new(0),
        }
    }
    pub fn record(&self) -> RelayRecord {
        RelayRecord::signed(&self.key, self.config.public_url.clone(), now())
    }
    fn catalog(&self) -> Value {
        let mut directory = self.directory.lock().unwrap();
        let own = self.record();
        directory.merge([own.clone()], now(), self.config.allow_loopback);
        let mut records = vec![own.clone()];
        records.extend(
            directory
                .batch(
                    now(),
                    self.catalog_offset.fetch_add(63, Ordering::Relaxed) as usize,
                )
                .into_iter()
                .filter(|record| record.relay_id != own.relay_id),
        );
        json!({"type":"catalog", "relays": records})
    }
    fn merge(&self, value: &Value) {
        let Some(array) = value.get("relays").and_then(Value::as_array) else {
            return;
        };
        if array.len() > 64 {
            return;
        }
        let entries = array
            .iter()
            .filter_map(|v| serde_json::from_value::<RelayRecord>(v.clone()).ok());
        self.directory
            .lock()
            .unwrap()
            .merge(entries, now(), self.config.allow_loopback);
    }
    fn destinations(&self, identity: &str) -> Vec<mpsc::Sender<String>> {
        self.clients
            .lock()
            .unwrap()
            .get(identity)
            .map(|clients| clients.values().cloned().collect())
            .unwrap_or_default()
    }
}

struct Registration {
    hub: Arc<Hub>,
    identity: String,
    id: u64,
}
impl Drop for Registration {
    fn drop(&mut self) {
        let mut clients = self.hub.clients.lock().unwrap();
        if let Some(registered) = clients.get_mut(&self.identity) {
            registered.remove(&self.id);
            if registered.is_empty() {
                clients.remove(&self.identity);
            }
        }
    }
}

fn socket_config() -> SocketConfig {
    SocketConfig::default()
        .max_message_size(Some(256 * 1024))
        .max_frame_size(Some(256 * 1024))
        .max_write_buffer_size(512 * 1024)
}

/// Per-connection token buckets: keep the existing burst bounds, then apply
/// TCP backpressure at the configured byte rate and 1,200 text frames/minute.
struct TrafficBudget {
    byte_capacity: f64,
    byte_tokens: f64,
    frame_tokens: f64,
    updated: Instant,
}

impl TrafficBudget {
    fn new(bytes_per_minute: usize, now: Instant) -> Self {
        let capacity = bytes_per_minute as f64;
        Self {
            byte_capacity: capacity,
            byte_tokens: capacity,
            frame_tokens: 1200.0,
            updated: now,
        }
    }

    fn reserve(&mut self, size: usize, now: Instant) -> Instant {
        let base = now.max(self.updated);
        let elapsed = base.duration_since(self.updated).as_secs_f64();
        let byte_rate = self.byte_capacity / 60.0;
        self.byte_tokens = (self.byte_tokens + elapsed * byte_rate).min(self.byte_capacity);
        self.frame_tokens = (self.frame_tokens + elapsed * 20.0).min(1200.0);
        let wait = ((size as f64 - self.byte_tokens) / byte_rate)
            .max((1.0 - self.frame_tokens) / 20.0)
            .max(0.0);
        let ready = base + Duration::from_secs_f64(wait);
        self.byte_tokens = (self.byte_tokens + wait * byte_rate - size as f64)
            .max(0.0)
            .min(self.byte_capacity);
        self.frame_tokens = (self.frame_tokens + wait * 20.0 - 1.0).max(0.0).min(1200.0);
        self.updated = ready;
        ready
    }
}

#[cfg(test)]
mod traffic_tests {
    use super::*;

    #[test]
    fn exhausted_budgets_schedule_reads_and_refill_only_to_the_burst_cap() {
        let start = Instant::now();
        let mut bytes = TrafficBudget::new(65536, start);
        assert_eq!(bytes.reserve(65536, start), start);
        let ready = bytes.reserve(32768, start);
        assert_eq!(ready.duration_since(start), Duration::from_secs(30));
        // A stale caller clock must not spend the same tokens twice.
        assert_eq!(
            bytes.reserve(32768, start).duration_since(start),
            Duration::from_secs(60)
        );
        let idle = start + Duration::from_secs(600);
        assert_eq!(bytes.reserve(65536, idle), idle);
        assert_eq!(
            bytes.reserve(65536, idle).duration_since(idle),
            Duration::from_secs(60)
        );

        let mut frames = TrafficBudget::new(8 * 1024 * 1024, start);
        for _ in 0..1200 {
            assert_eq!(frames.reserve(0, start), start);
        }
        assert_eq!(
            frames.reserve(0, start).duration_since(start),
            Duration::from_millis(50)
        );
    }

    #[test]
    fn a_bounded_frame_larger_than_a_small_byte_bucket_is_still_paced() {
        let start = Instant::now();
        let mut budget = TrafficBudget::new(65536, start);
        assert_eq!(
            budget.reserve(128 * 1024, start).duration_since(start),
            Duration::from_secs(60)
        );
        assert_eq!(
            budget.reserve(65536, start).duration_since(start),
            Duration::from_secs(120)
        );
    }
}

#[allow(clippy::result_large_err)] // tungstenite fixes the handshake callback error type.
pub async fn serve_connection(hub: Arc<Hub>, stream: TcpStream) -> RelayResult<()> {
    let callback = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        if request.uri().path() != "/cht" || request.uri().query().is_some() {
            return Err(tokio_tungstenite::tungstenite::http::Response::builder()
                .status(404)
                .body(Some("Use /cht".into()))
                .unwrap());
        }
        Ok(response)
    };
    let mut socket = timeout(
        Duration::from_secs(10),
        accept_hdr_async_with_config(stream, callback, Some(socket_config())),
    )
    .await??;
    let mut random = [0u8; 32];
    getrandom::fill(&mut random)?;
    let nonce = B64.encode(random);
    let record = hub.record();
    timeout(Duration::from_secs(5), socket.send(Message::text(json!({"type":"challenge", "nonce":nonce, "relay":record, "relays":hub.catalog()["relays"],"capabilities":["courier-directory-v1","courier-self-v1"]}).to_string()))).await??;
    let (tx, mut rx) = mpsc::channel::<String>(64);
    let mut registration: Option<Registration> = None;
    let mut directory_only = false;
    let mut wants_catalog = true;
    let mut heartbeat = interval(Duration::from_secs(20));
    let mut last_seen = now();
    let mut budget = TrafficBudget::new(hub.config.bytes_per_minute, Instant::now());
    let mut deferred: Option<(String, Instant)> = None;
    let connected = now();
    loop {
        let ready = deferred
            .as_ref()
            .map(|(_, ready)| *ready)
            .unwrap_or_else(Instant::now);
        let text = tokio::select! {
            _ = heartbeat.tick() => {
                // A deliberate read pause is backpressure, not proof of an idle peer.
                if (deferred.is_none() && now().saturating_sub(last_seen) > 65_000)
                    || (registration.is_none() && !directory_only && now().saturating_sub(connected) > 10_000) { break; }
                timeout(Duration::from_secs(5), socket.send(Message::Ping(Vec::new().into()))).await??;
                if wants_catalog { timeout(Duration::from_secs(5), socket.send(Message::text(hub.catalog().to_string()))).await??; }
                continue;
            },
            Some(value) = rx.recv() => {
                timeout(Duration::from_secs(5), socket.send(Message::text(value))).await??;
                continue;
            },
            _ = sleep_until(ready), if deferred.is_some() => {
                deferred.take().expect("deferred frame exists").0
            },
            message = socket.next(), if deferred.is_none() => {
                let Some(message) = message else { break; };
                let message = message?;
                last_seen = now();
                if message.is_close() { break; }
                if message.is_ping() || message.is_pong() { continue; }
                let Message::Text(text) = message else { return Err("Text frames required".into()); };
                let ready = budget.reserve(text.len(), Instant::now());
                // At most one bounded text frame is held. Keep forwarding the
                // opposite direction and heartbeats while reads are throttled.
                deferred = Some((text.to_string(), ready));
                continue;
            }
        };
        let value: Value = serde_json::from_str(&text)?;
        match value["type"].as_str() {
            Some("register")
                if registration.is_none()
                    && !directory_only
                    && now().saturating_sub(connected) <= 10_000 =>
            {
                let proof: RelayProof = serde_json::from_value(value["proof"].clone())?;
                proof.verify(&nonce, &record.relay_id)?;
                let id = hub.sequence.fetch_add(1, Ordering::Relaxed);
                {
                    let mut clients = hub.clients.lock().unwrap();
                    let entry = clients.entry(proof.identity_id.clone()).or_default();
                    if entry.len() >= 4 {
                        return Err("Too many connections for this identity".into());
                    }
                    entry.insert(id, tx.clone());
                }
                registration = Some(Registration {
                    hub: Arc::clone(&hub),
                    identity: proof.identity_id,
                    id,
                });
                wants_catalog = value["subscribeCatalog"].as_bool().unwrap_or(true);
                timeout(
                    Duration::from_secs(5),
                    socket.send(Message::text(json!({"type":"registered"}).to_string())),
                )
                .await??;
                hub.merge(&value);
            }
            Some("couriers") if registration.is_some() => {
                let object = value.as_object().ok_or("Invalid Courier request")?;
                if object.len() != 2 {
                    return Err("Unexpected Courier fields".into());
                }
                let records = value["records"]
                    .as_array()
                    .ok_or("Missing Courier records")?;
                let batch = {
                    let mut catalog = hub.couriers.lock().unwrap();
                    catalog.merge(records, now(), hub.config.allow_loopback)?;
                    catalog.batch(now())
                };
                timeout(
                    Duration::from_secs(5),
                    socket.send(Message::text(
                        json!({"type":"couriers","records":batch}).to_string(),
                    )),
                )
                .await??;
            }
            Some("directory") => {
                wants_catalog = value["subscribeCatalog"].as_bool().unwrap_or(true);
                if registration.is_none() {
                    directory_only = true;
                }
                hub.merge(&value);
            }
            Some("keepalive") if registration.is_some() => {
                timeout(
                    Duration::from_secs(5),
                    socket.send(Message::text("{\"type\":\"alive\"}")),
                )
                .await??;
            }
            Some("route") if registration.is_some() => {
                let sender = &registration.as_ref().unwrap().identity;
                let to = value["to"].as_str().ok_or("Missing destination")?;
                let session = value["session"].as_str().ok_or("Missing session")?;
                let packet = value["packet"].as_str().ok_or("Missing packet ID")?;
                if to.len() != 72
                    || !to.starts_with("did:cht:")
                    || session.len() != 32
                    || packet.len() != 32
                    || !session
                        .bytes()
                        .chain(packet.bytes())
                        .all(|c| c.is_ascii_hexdigit())
                    || value["body"].to_string().len() > 64 * 1024
                {
                    return Err("Invalid relay envelope".into());
                }
                let envelope = json!({"type":"route", "from":sender, "session":session, "packet":packet, "body":value["body"]}).to_string();
                // Bounded queues: a slow recipient cannot accumulate unbounded memory.
                let destinations = hub.destinations(to);
                let sent = destinations
                    .into_iter()
                    .filter(|client| client.try_send(envelope.clone()).is_ok())
                    .count();
                if sent == 0 {
                    timeout(
                        Duration::from_secs(5),
                        socket.send(Message::text(
                            json!({"type":"unreachable", "to":to, "session":session}).to_string(),
                        )),
                    )
                    .await??;
                }
            }
            _ => return Err("Unsupported or unauthenticated relay request".into()),
        }
    }
    Ok(())
}

// Resolve once, vet every result, then connect to that exact IP (no DNS re-resolution).
pub async fn connect_endpoint(
    endpoint: &str,
    allow_loopback: bool,
) -> RelayResult<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>> {
    validate_endpoint(endpoint, allow_loopback)?;
    let url = url::Url::parse(endpoint)?;
    let host = url
        .host_str()
        .ok_or("Missing host")?
        .trim_matches(['[', ']']);
    let addresses: Vec<_> = timeout(
        Duration::from_secs(5),
        lookup_host((host, url.port_or_known_default().ok_or("Missing port")?)),
    )
    .await??
    .collect();
    if addresses.is_empty() {
        return Err("Relay host has no addresses".into());
    }
    for address in &addresses {
        if !(allow_loopback && address.ip().is_loopback()) {
            let formatted = match address.ip() {
                std::net::IpAddr::V4(ip) => format!("wss://{ip}/cht"),
                std::net::IpAddr::V6(ip) => format!("wss://[{ip}]/cht"),
            };
            validate_endpoint(&formatted, false)?;
        }
    }
    let stream = timeout(Duration::from_secs(5), TcpStream::connect(&addresses[..])).await??;
    let (socket, _) = timeout(
        Duration::from_secs(10),
        client_async_tls_with_config(endpoint, stream, Some(socket_config()), None),
    )
    .await??;
    Ok(socket)
}

async fn exchange(hub: Arc<Hub>, endpoint: String) -> RelayResult<()> {
    let mut socket = connect_endpoint(&endpoint, hub.config.allow_loopback).await?;
    let challenge = timeout(Duration::from_secs(10), socket.next())
        .await?
        .ok_or("Missing relay challenge")??;
    let value: Value = serde_json::from_str(challenge.to_text()?)?;
    let record: RelayRecord = serde_json::from_value(value["relay"].clone())?;
    record.verify(now(), hub.config.allow_loopback)?;
    if record.endpoint != endpoint {
        return Err("Relay endpoint does not match its signed record".into());
    }
    hub.directory
        .lock()
        .unwrap()
        .merge([record], now(), hub.config.allow_loopback);
    hub.merge(&value);
    let mut timer = interval(Duration::from_secs(20));
    loop {
        tokio::select! {
            _ = timer.tick() => {
                let mut catalog = hub.catalog(); catalog["type"] = json!("directory");
                timeout(Duration::from_secs(5), socket.send(Message::text(catalog.to_string()))).await??;
            },
            value = socket.next() => {
                let Some(value) = value else { break; }; let value = value?;
                if value.is_text() { let value: Value = serde_json::from_str(value.to_text()?)?; hub.merge(&value); }
                else if value.is_close() { break; }
            }
        }
    }
    Ok(())
}

pub async fn run(
    config: WebSocketConfig,
    key: libp2p::identity::Keypair,
    state: PathBuf,
) -> RelayResult<()> {
    config.validate()?;
    let secret = key.try_into_ed25519()?.secret();
    let signing = SigningKey::from_bytes(secret.as_ref().try_into()?);
    let hub = Arc::new(Hub::new(config.clone(), signing));
    let cache = state.join("relay-directory.json");
    if let Ok(metadata) = std::fs::metadata(&cache)
        && metadata.len() <= 8 * 1024 * 1024
        && let Ok(bytes) = std::fs::read(&cache)
        && let Ok(value) = serde_json::from_slice::<Value>(&bytes)
        && let Some(records) = value.get("relays").and_then(Value::as_array)
    {
        for chunk in records.chunks(64).take(16) {
            hub.merge(&json!({"relays":chunk}));
        }
    }
    let listener = TcpListener::bind(config.listen).await?;
    println!(
        "{}",
        json!({"event":"websocket_listening", "address":config.listen.to_string(), "endpoint":config.public_url, "relay_id":hub.record().relay_id})
    );
    let permits = Arc::new(Semaphore::new(config.max_clients));
    let mut maintenance = interval(Duration::from_secs(10));
    let mut exchanges = BTreeMap::<String, ExchangeTask>::new();
    let mut tasks = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            connection = listener.accept() => {
                let (stream, _) = connection?;
                let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else { continue; };
                let hub = Arc::clone(&hub);
                tasks.spawn(async move { let _permit = permit; let _ = serve_connection(hub, stream).await; });
            },
            _ = tasks.join_next(), if !tasks.is_empty() => {},
            _ = maintenance.tick() => {
                exchanges.retain(|_, task| !task.0.is_finished());
                let catalog = hub.catalog();
                let mut endpoints = config.bootstrap_urls.clone();
                if let Some(records) = catalog["relays"].as_array() {
                    endpoints.extend(records.iter().filter_map(|r| r["endpoint"].as_str().map(str::to_owned)));
                }
                let mut seen = HashSet::new();
                for endpoint in endpoints {
                    if exchanges.len() >= 6 { break; }
                    if endpoint == config.public_url || !seen.insert(endpoint.clone()) || exchanges.contains_key(&endpoint) { continue; }
                    let other = Arc::clone(&hub); let url = endpoint.clone();
                    exchanges.insert(endpoint, ExchangeTask(tokio::spawn(async move { let _ = exchange(other, url).await; })));
                }
                // Cache contains only signed public hints; every entry is revalidated on load.
                let temporary = cache.with_extension("tmp");
                let saved = json!({"relays":hub.directory.lock().unwrap().snapshot(now())});
                if std::fs::write(&temporary, saved.to_string()).is_ok() { let _ = std::fs::rename(temporary, &cache); }
            }
        }
    }
}
