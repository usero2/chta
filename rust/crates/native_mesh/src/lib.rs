use std::{
    collections::BTreeMap,
    ffi::{CStr, CString, c_char},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    thread,
};

use futures::{SinkExt, StreamExt};
use libp2p::{
    Multiaddr, PeerId, SwarmBuilder, identify, identity, mdns, noise, ping, relay,
    swarm::{NetworkBehaviour, SwarmEvent, behaviour::toggle::Toggle},
    tcp, yamux,
};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::{net::TcpListener, sync::mpsc};
use tokio_tungstenite::{
    accept_hdr_async,
    tungstenite::{
        Message,
        handshake::server::{ErrorResponse, Request, Response},
        http::StatusCode,
    },
};

const LOCAL_GATEWAY_PORT: u16 = 17357;
type ActiveGatewayClient = Arc<Mutex<Option<(u64, mpsc::UnboundedSender<String>)>>>;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshStatus {
    pub listening: bool,
    pub peer_id: String,
    pub addresses: Vec<String>,
    pub discovered_nodes: Vec<DiscoveredNode>,
    pub pin_required: bool,
    pub relay_enabled: bool,
    pub gateway_port: u16,
    pub gateway_connected: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredNode {
    pub peer_id: String,
    pub address: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayEvent {
    pub event_type: String,
    pub text: Option<String>,
}

enum MeshCommand {
    Stop,
}

#[derive(Clone)]
struct GatewayContext {
    status: Arc<Mutex<MeshStatus>>,
    events: Arc<Mutex<Vec<GatewayEvent>>>,
    client: ActiveGatewayClient,
    generation: Arc<AtomicU64>,
    contact_card: Arc<Mutex<String>>,
    port: u16,
}

pub struct NativeMesh {
    status: Arc<Mutex<MeshStatus>>,
    gateway_events: Arc<Mutex<Vec<GatewayEvent>>>,
    gateway_client: ActiveGatewayClient,
    gateway_generation: Arc<AtomicU64>,
    gateway_contact_card: Arc<Mutex<String>>,
    gateway_port: u16,
    command: Option<mpsc::UnboundedSender<MeshCommand>>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Default for NativeMesh {
    fn default() -> Self {
        Self {
            status: Arc::default(),
            gateway_events: Arc::default(),
            gateway_client: Arc::default(),
            gateway_generation: Arc::default(),
            gateway_contact_card: Arc::default(),
            gateway_port: LOCAL_GATEWAY_PORT,
            command: None,
            worker: None,
        }
    }
}

impl NativeMesh {
    pub fn start(
        &mut self,
        port: u16,
        pin: &str,
        allow_relay: bool,
        contact_card: &str,
    ) -> Result<MeshStatus, String> {
        if self.command.is_some() {
            return Err("node is already listening".to_owned());
        }
        let pin = pin.trim();
        if pin.chars().count() > 64 {
            return Err("PIN must be 64 characters or fewer".to_owned());
        }
        let pin_required = !pin.is_empty();
        let relay_enabled = allow_relay && !pin_required;
        if contact_card.trim().is_empty() {
            return Err("signed contact card is required".to_owned());
        }
        let key = identity::Keypair::generate_ed25519();
        let peer_id = key.public().to_peer_id();
        let status = Arc::new(Mutex::new(MeshStatus {
            listening: false,
            peer_id: peer_id.to_string(),
            addresses: Vec::new(),
            discovered_nodes: Vec::new(),
            pin_required,
            relay_enabled,
            gateway_port: self.gateway_port,
            gateway_connected: false,
            error: None,
        }));
        self.status = Arc::clone(&status);
        let gateway_events = Arc::clone(&self.gateway_events);
        let gateway_client = Arc::clone(&self.gateway_client);
        let gateway_generation = Arc::clone(&self.gateway_generation);
        self.update_contact_card(contact_card)?;
        let contact_card = Arc::clone(&self.gateway_contact_card);
        let gateway = GatewayContext {
            status: Arc::clone(&status),
            events: gateway_events,
            client: gateway_client,
            generation: gateway_generation,
            contact_card,
            port: self.gateway_port,
        };
        let (sender, receiver) = mpsc::unbounded_channel();
        self.command = Some(sender);

        let worker = thread::Builder::new()
            .name("cht-libp2p".to_owned())
            .spawn(move || {
                let result = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .map_err(|error| error.to_string())
                    .and_then(|runtime| {
                        runtime.block_on(run_mesh(
                            key,
                            peer_id,
                            port,
                            relay_enabled,
                            receiver,
                            gateway,
                        ))
                    });
                if let Err(error) = result
                    && let Ok(mut value) = status.lock()
                {
                    value.listening = false;
                    value.error = Some(error);
                }
            })
            .map_err(|error| error.to_string())?;
        self.worker = Some(worker);
        self.status()
    }

    pub fn stop(&mut self) -> Result<MeshStatus, String> {
        if let Some(command) = self.command.take() {
            command
                .send(MeshCommand::Stop)
                .map_err(|_| "listener has already stopped".to_owned())?;
        }
        if let Some(worker) = self.worker.take() {
            worker
                .join()
                .map_err(|_| "listener worker panicked".to_owned())?;
        }
        if let Ok(mut status) = self.status.lock() {
            status.listening = false;
        }
        self.status()
    }

    pub fn status(&self) -> Result<MeshStatus, String> {
        self.status
            .lock()
            .map(|value| value.clone())
            .map_err(|_| "mesh status lock is poisoned".to_owned())
    }

    pub fn drain_gateway_events(&self) -> Result<Vec<GatewayEvent>, String> {
        self.gateway_events
            .lock()
            .map(|mut events| events.drain(..).collect())
            .map_err(|_| "gateway event lock is poisoned".to_owned())
    }

    pub fn send_gateway_message(&self, text: &str) -> Result<(), String> {
        let client = self
            .gateway_client
            .lock()
            .map_err(|_| "gateway client lock is poisoned".to_owned())?;
        client
            .as_ref()
            .ok_or_else(|| "browser companion is not connected".to_owned())?
            .1
            .send(text.to_owned())
            .map_err(|_| "browser companion is not connected".to_owned())
    }

    pub fn update_contact_card(&self, card: &str) -> Result<(), String> {
        if card.trim().is_empty() {
            return Err("signed contact card is required".to_owned());
        }
        *self
            .gateway_contact_card
            .lock()
            .map_err(|_| "contact card lock is poisoned".to_owned())? = card.to_owned();
        Ok(())
    }
}

#[derive(NetworkBehaviour)]
struct MeshBehaviour {
    relay: Toggle<relay::Behaviour>,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
    mdns: mdns::tokio::Behaviour,
}

async fn run_mesh(
    key: identity::Keypair,
    peer_id: PeerId,
    port: u16,
    relay_enabled: bool,
    mut commands: mpsc::UnboundedReceiver<MeshCommand>,
    gateway: GatewayContext,
) -> Result<(), String> {
    let status = Arc::clone(&gateway.status);
    let mut swarm = SwarmBuilder::with_existing_identity(key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .map_err(|error| error.to_string())?
        .with_behaviour(move |key| {
            let relay = relay_enabled.then(|| relay::Behaviour::new(peer_id, Default::default()));
            Ok(MeshBehaviour {
                relay: Toggle::from(relay),
                identify: identify::Behaviour::new(identify::Config::new(
                    "/cht/0.0.1".to_owned(),
                    key.public(),
                )),
                ping: ping::Behaviour::new(ping::Config::new()),
                mdns: mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id)?,
            })
        })
        .map_err(|error| error.to_string())?
        .build();

    let listen_address: Multiaddr = format!("/ip4/0.0.0.0/tcp/{port}")
        .parse()
        .map_err(|error: libp2p::multiaddr::Error| error.to_string())?;
    swarm
        .listen_on(listen_address)
        .map_err(|error| error.to_string())?;
    let gateway_status = Arc::clone(&gateway.status);
    let gateway_error_status = Arc::clone(&status);
    tokio::spawn(async move {
        if let Err(error) = run_local_gateway(
            gateway_status,
            gateway.events,
            gateway.client,
            gateway.generation,
            gateway.contact_card,
            gateway.port,
        )
        .await
            && let Ok(mut value) = gateway_error_status.lock()
        {
            value.error = Some(error);
        }
    });
    let mut discovered = BTreeMap::<String, String>::new();

    loop {
        tokio::select! {
            command = commands.recv() => {
                if matches!(command, Some(MeshCommand::Stop) | None) {
                    break;
                }
            }
            event = swarm.select_next_some() => match event {
                SwarmEvent::NewListenAddr { address, .. } => {
                    if let Ok(mut value) = status.lock() {
                        let address = address.with(libp2p::multiaddr::Protocol::P2p(peer_id));
                        let address = address.to_string();
                        value.listening = true;
                        if !value.addresses.contains(&address) {
                            value.addresses.push(address);
                        }
                    }
                }
                SwarmEvent::Behaviour(MeshBehaviourEvent::Mdns(mdns::Event::Discovered(nodes))) => {
                    for (node, address) in nodes {
                        discovered.insert(node.to_string(), address.to_string());
                    }
                    update_discovered(&status, &discovered);
                }
                SwarmEvent::Behaviour(MeshBehaviourEvent::Mdns(mdns::Event::Expired(nodes))) => {
                    for (node, _) in nodes {
                        discovered.remove(&node.to_string());
                    }
                    update_discovered(&status, &discovered);
                }
                _ => {}
            }
        }
    }
    if let Ok(mut value) = status.lock() {
        value.listening = false;
        value.addresses.clear();
    }
    Ok(())
}

async fn run_local_gateway(
    status: Arc<Mutex<MeshStatus>>,
    events: Arc<Mutex<Vec<GatewayEvent>>>,
    client: ActiveGatewayClient,
    generation: Arc<AtomicU64>,
    contact_card: Arc<Mutex<String>>,
    port: u16,
) -> Result<(), String> {
    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|error| format!("local browser gateway: {error}"))?;
    loop {
        let (stream, _) = listener.accept().await.map_err(|error| error.to_string())?;
        let events = Arc::clone(&events);
        let client = Arc::clone(&client);
        let connection_id = generation.fetch_add(1, Ordering::Relaxed) + 1;
        let status = Arc::clone(&status);
        let contact_card = contact_card.clone();
        tokio::spawn(async move {
            let Ok(socket) = accept_hdr_async(stream, validate_gateway_origin).await else {
                return;
            };
            let (mut writer, mut reader) = socket.split();
            let (sender, mut outgoing) = mpsc::unbounded_channel::<String>();
            if let Ok(mut connected) = client.lock() {
                // Replacing this sender closes the previous connection's
                // outgoing channel. A single Desktop account owns one Noise
                // session, so frames must never be broadcast across sessions.
                *connected = Some((connection_id, sender));
            }
            if let Ok(mut value) = status.lock() {
                value.gateway_connected = true;
            }
            push_gateway_event(&events, "connected", None);
            let hello = json!({
                "type": "desktopHello",
                "contactCard": contact_card.lock().map(|card| card.clone()).unwrap_or_default(),
            })
            .to_string();
            if writer.send(Message::Text(hello.into())).await.is_err() {
                return;
            }

            loop {
                tokio::select! {
                    incoming = reader.next() => match incoming {
                        Some(Ok(Message::Text(text))) => {
                            push_gateway_event(&events, "message", Some(text.to_string()));
                        }
                        Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                        _ => {}
                    },
                    outgoing = outgoing.recv() => match outgoing {
                        Some(text) => {
                            if writer.send(Message::Text(text.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
            }
            let is_active = if let Ok(mut connected) = client.lock() {
                if connected
                    .as_ref()
                    .is_some_and(|(active_id, _)| *active_id == connection_id)
                {
                    *connected = None;
                    true
                } else {
                    false
                }
            } else {
                false
            };
            if is_active && let Ok(mut value) = status.lock() {
                value.gateway_connected = false;
            }
            if is_active {
                push_gateway_event(&events, "disconnected", None);
            }
        });
    }
}

#[allow(clippy::result_large_err)]
fn validate_gateway_origin(
    request: &Request,
    response: Response,
) -> Result<Response, ErrorResponse> {
    let allowed = request
        .headers()
        .get("origin")
        .and_then(|value| value.to_str().ok())
        .is_none_or(|origin| {
            origin.starts_with("http://localhost:") || origin.starts_with("http://127.0.0.1:")
        });
    if allowed {
        Ok(response)
    } else {
        let mut rejection = ErrorResponse::new(Some("local cht origins only".to_owned()));
        *rejection.status_mut() = StatusCode::FORBIDDEN;
        Err(rejection)
    }
}

fn push_gateway_event(
    events: &Arc<Mutex<Vec<GatewayEvent>>>,
    event_type: &str,
    text: Option<String>,
) {
    if let Ok(mut events) = events.lock() {
        events.push(GatewayEvent {
            event_type: event_type.to_owned(),
            text,
        });
    }
}

fn update_discovered(status: &Arc<Mutex<MeshStatus>>, nodes: &BTreeMap<String, String>) {
    if let Ok(mut value) = status.lock() {
        value.discovered_nodes = nodes
            .iter()
            .map(|(peer_id, address)| DiscoveredNode {
                peer_id: peer_id.clone(),
                address: address.clone(),
            })
            .collect();
    }
}

static MESH: OnceLock<Mutex<NativeMesh>> = OnceLock::new();

#[unsafe(no_mangle)]
/// Calls the native mesh JSON command boundary.
///
/// # Safety
/// `request` must point to a valid null-terminated UTF-8 string for the duration of the call.
pub unsafe extern "C" fn cht_mesh_call(request: *const c_char) -> *mut c_char {
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
    // SAFETY: Dart passes a valid null-terminated UTF-8 allocation for this call.
    let source = unsafe { CStr::from_ptr(request) }
        .to_str()
        .map_err(|error| error.to_string())?;
    let document: Value = serde_json::from_str(source).map_err(|error| error.to_string())?;
    let command = required_string(&document, "command")?;
    let args = document.get("args").unwrap_or(&Value::Null);
    let mesh = MESH.get_or_init(|| Mutex::new(NativeMesh::default()));
    let mut mesh = mesh
        .lock()
        .map_err(|_| "native mesh lock is poisoned".to_owned())?;
    match command {
        "startListener" => serde_json::to_value(mesh.start(
            required_u16(args, "port")?,
            required_string(args, "pin")?,
            required_bool(args, "allowRelay")?,
            required_string(args, "contactCard")?,
        )?)
        .map_err(|error| error.to_string()),
        "stopListener" => serde_json::to_value(mesh.stop()?).map_err(|error| error.to_string()),
        "listenerStatus" => serde_json::to_value(mesh.status()?).map_err(|error| error.to_string()),
        "updateListenerContactCard" => {
            mesh.update_contact_card(required_string(args, "contactCard")?)?;
            Ok(Value::Null)
        }
        "drainGatewayEvents" => {
            serde_json::to_value(mesh.drain_gateway_events()?).map_err(|error| error.to_string())
        }
        "sendGatewayMessage" => {
            mesh.send_gateway_message(required_string(args, "text")?)?;
            Ok(Value::Null)
        }
        _ => Err(format!("unknown mesh command: {command}")),
    }
}

#[unsafe(no_mangle)]
/// Releases a response allocated by [`cht_mesh_call`].
///
/// # Safety
/// `value` must be null or a pointer returned by [`cht_mesh_call`] that has not been freed.
pub unsafe extern "C" fn cht_mesh_free_string(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: This pointer was allocated by CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(value) });
    }
}

fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{key} must be a string"))
}

fn required_u16(value: &Value, key: &str) -> Result<u16, String> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|value| value.try_into().ok())
        .ok_or_else(|| format!("{key} must be a port from 0 to 65535"))
}

fn required_bool(value: &Value, key: &str) -> Result<bool, String> {
    value
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| format!("{key} must be a boolean"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    use tokio_tungstenite::connect_async;

    fn unused_gateway_port() -> u16 {
        std::net::TcpListener::bind(("127.0.0.1", 0))
            .expect("test port should bind")
            .local_addr()
            .expect("test address should exist")
            .port()
    }

    #[test]
    fn pin_protected_node_does_not_become_an_open_relay() {
        let mut mesh = NativeMesh {
            gateway_port: unused_gateway_port(),
            ..NativeMesh::default()
        };
        let initial = mesh
            .start(0, "1234", true, "signed-card")
            .expect("listener should start");
        assert!(initial.pin_required);
        assert!(!initial.relay_enabled);

        let deadline = Instant::now() + Duration::from_secs(5);
        while !mesh.status().expect("status should work").listening {
            assert!(Instant::now() < deadline, "listener did not become ready");
            thread::sleep(Duration::from_millis(25));
        }
        mesh.stop().expect("listener should stop");
    }

    #[test]
    fn local_browser_gateway_announces_the_desktop_contact_card() {
        let gateway_port = unused_gateway_port();
        let mut mesh = NativeMesh {
            gateway_port,
            ..NativeMesh::default()
        };
        mesh.start(0, "", false, "signed-desktop-card")
            .expect("listener should start");
        let runtime = tokio::runtime::Runtime::new().expect("runtime should start");
        let deadline = Instant::now() + Duration::from_secs(5);
        let (hello, mut socket) = runtime.block_on(async {
            loop {
                match connect_async(format!("ws://127.0.0.1:{gateway_port}")).await {
                    Ok((mut socket, _)) => {
                        let message = socket
                            .next()
                            .await
                            .expect("gateway should send hello")
                            .expect("hello should be valid");
                        break (message.into_text().expect("hello should be text"), socket);
                    }
                    Err(_) if Instant::now() < deadline => {
                        tokio::time::sleep(Duration::from_millis(25)).await;
                    }
                    Err(error) => panic!("gateway did not become ready: {error}"),
                }
            }
        });
        let hello: Value = serde_json::from_str(&hello).expect("hello should be JSON");
        assert_eq!(hello["type"], "desktopHello");
        assert_eq!(hello["contactCard"], "signed-desktop-card");
        runtime.block_on(async {
            socket
                .send(Message::Text("browser-frame".into()))
                .await
                .expect("browser frame should send");
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let events = mesh.drain_gateway_events().expect("events should drain");
            if events.iter().any(|event| {
                event.event_type == "message" && event.text.as_deref() == Some("browser-frame")
            }) {
                break;
            }
            assert!(Instant::now() < deadline, "browser frame was not received");
            thread::sleep(Duration::from_millis(25));
        }
        mesh.update_contact_card("updated-signed-desktop-profile")
            .expect("profile should update");
        let mut newest_socket = runtime.block_on(async {
            let (mut socket, _) = connect_async(format!("ws://127.0.0.1:{gateway_port}"))
                .await
                .expect("replacement browser should connect");
            let hello = socket
                .next()
                .await
                .expect("replacement hello should arrive")
                .expect("replacement hello should be valid");
            let hello: Value = serde_json::from_str(hello.to_text().unwrap()).unwrap();
            assert_eq!(hello["contactCard"], "updated-signed-desktop-profile");
            socket
        });
        mesh.send_gateway_message("desktop-frame")
            .expect("desktop frame should send");
        let desktop_frame = runtime.block_on(async {
            newest_socket
                .next()
                .await
                .expect("desktop frame should arrive")
                .expect("desktop frame should be valid")
                .into_text()
                .expect("desktop frame should be text")
        });
        assert_eq!(desktop_frame, "desktop-frame");
        mesh.stop().expect("listener should stop");
    }
}
