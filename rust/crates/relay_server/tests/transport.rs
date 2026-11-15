use std::time::Duration;

use cht_relay::{BehaviourEvent, build_swarm, config::Limits};
use futures::StreamExt;
use libp2p::{
    Multiaddr, StreamProtocol, Swarm, SwarmBuilder, identify, identity,
    multiaddr::Protocol,
    noise, ping, relay, request_response,
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux,
};
use tokio::{sync::mpsc, task::JoinHandle, time::timeout};

#[derive(NetworkBehaviour)]
struct Client {
    relay: relay::client::Behaviour,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
    echo: request_response::cbor::Behaviour<Vec<u8>, Vec<u8>>,
}

fn client() -> Swarm<Client> {
    SwarmBuilder::with_new_identity()
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .unwrap()
        .with_relay_client(noise::Config::new, yamux::Config::default)
        .unwrap()
        .with_behaviour(|key, relay| Client {
            relay,
            identify: identify::Behaviour::new(identify::Config::new(
                "/cht/relay/1".into(),
                key.public(),
            )),
            ping: ping::Behaviour::new(
                ping::Config::new().with_interval(Duration::from_millis(100)),
            ),
            echo: request_response::cbor::Behaviour::new(
                [(
                    StreamProtocol::new("/cht/relay-test/1"),
                    request_response::ProtocolSupport::Full,
                )],
                request_response::Config::default().with_request_timeout(Duration::from_secs(5)),
            ),
        })
        .unwrap()
        .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(20)))
        .build()
}

struct Server {
    address: Multiaddr,
    events: mpsc::UnboundedReceiver<SwarmEvent<BehaviourEvent>>,
    task: JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn server(limits: Limits) -> Server {
    let mut swarm = build_swarm(identity::Keypair::generate_ed25519(), &limits).unwrap();
    swarm
        .listen_on("/ip4/127.0.0.1/tcp/0".parse().unwrap())
        .unwrap();
    let address = loop {
        if let SwarmEvent::NewListenAddr { address, .. } = swarm.select_next_some().await {
            swarm.add_external_address(address.clone());
            break address.with(Protocol::P2p(*swarm.local_peer_id()));
        }
    };
    let (tx, events) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        loop {
            if tx.send(swarm.select_next_some().await).is_err() {
                break;
            }
        }
    });
    Server {
        address,
        events,
        task,
    }
}

async fn reserve(client: &mut Swarm<Client>, server: &Server) -> Multiaddr {
    let address = server.address.clone().with(Protocol::P2pCircuit);
    client.listen_on(address.clone()).unwrap();
    loop {
        match client.select_next_some().await {
            SwarmEvent::NewListenAddr { .. } => {
                return address.with(Protocol::P2p(*client.local_peer_id()));
            }
            SwarmEvent::ListenerError { error, .. } => panic!("Reservation failed: {error}"),
            _ => {}
        }
    }
}

async fn echo_until_result(
    source: &mut Swarm<Client>,
    destination: &mut Swarm<Client>,
    payload: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let id = source
        .behaviour_mut()
        .echo
        .send_request(destination.local_peer_id(), payload);
    loop {
        tokio::select! {
            event = source.select_next_some() => match event {
                SwarmEvent::Behaviour(ClientEvent::Echo(request_response::Event::Message {message: request_response::Message::Response {request_id, response}, ..})) if request_id == id => return Ok(response),
                SwarmEvent::Behaviour(ClientEvent::Echo(request_response::Event::OutboundFailure {request_id, error, ..})) if request_id == id => return Err(error.to_string()),
                _ => {}
            },
            event = destination.select_next_some() => {
                if let SwarmEvent::Behaviour(ClientEvent::Echo(request_response::Event::Message {message: request_response::Message::Request {request, channel, ..}, ..})) = event {
                    let _ = destination.behaviour_mut().echo.send_response(channel, request);
                }
            }
        }
    }
}

async fn connect_through(
    source: &mut Swarm<Client>,
    destination: &mut Swarm<Client>,
    address: Multiaddr,
) {
    let peer = *destination.local_peer_id();
    source.dial(address).unwrap();
    loop {
        tokio::select! {
            event = source.select_next_some() => match event {
                SwarmEvent::ConnectionEstablished {peer_id, endpoint, ..} if peer_id == peer => { assert!(endpoint.is_relayed()); return; },
                SwarmEvent::OutgoingConnectionError {error, ..} => panic!("Dial failed: {error}"),
                _ => {}
            },
            _ = destination.select_next_some() => {}
        }
    }
}

#[tokio::test]
async fn two_clients_exchange_payload_through_relay() {
    timeout(Duration::from_secs(15), async {
        let mut server = server(Limits::default()).await;
        let mut destination = client();
        let address = reserve(&mut destination, &server).await;
        let mut source = client();
        connect_through(&mut source, &mut destination, address).await;
        let payload = vec![42u8; 16 * 1024];
        assert_eq!(
            echo_until_result(&mut source, &mut destination, payload.clone())
                .await
                .unwrap(),
            payload
        );
        loop {
            if let SwarmEvent::Behaviour(BehaviourEvent::Relay(
                relay::Event::CircuitReqAccepted { .. },
            )) = server.events.recv().await.unwrap()
            {
                break;
            }
        }
    })
    .await
    .expect("relay round trip timed out");
}

#[tokio::test]
async fn byte_budget_closes_a_real_circuit() {
    timeout(Duration::from_secs(15), async {
        let mut server = server(Limits {
            circuit_bytes: 8192,
            ..Limits::default()
        })
        .await;
        let mut destination = client();
        let address = reserve(&mut destination, &server).await;
        let mut source = client();
        connect_through(&mut source, &mut destination, address).await;
        assert!(
            echo_until_result(&mut source, &mut destination, vec![7u8; 128 * 1024])
                .await
                .is_err()
        );
        loop {
            if let SwarmEvent::Behaviour(BehaviourEvent::Relay(relay::Event::CircuitClosed {
                error,
                ..
            })) = server.events.recv().await.unwrap()
            {
                assert!(error.is_some());
                break;
            }
        }
    })
    .await
    .expect("byte limit timed out");
}

#[tokio::test]
async fn duration_budget_closes_a_real_circuit() {
    timeout(Duration::from_secs(15), async {
        let mut server = server(Limits { circuit_seconds: 1, ..Limits::default() }).await;
        let mut destination = client();
        let address = reserve(&mut destination, &server).await;
        let mut source = client();
        connect_through(&mut source, &mut destination, address).await;
        assert_eq!(echo_until_result(&mut source, &mut destination, vec![1, 2, 3]).await.unwrap(), vec![1, 2, 3]);
        loop {
            tokio::select! {
                _ = source.select_next_some() => {},
                _ = destination.select_next_some() => {},
                event = server.events.recv() => {
                    if let Some(SwarmEvent::Behaviour(BehaviourEvent::Relay(relay::Event::CircuitClosed {error, ..}))) = event {
                        assert_eq!(error.unwrap().kind(), std::io::ErrorKind::TimedOut);
                        break;
                    }
                }
            }
        }
    }).await.expect("duration limit timed out");
}

#[tokio::test]
async fn reservation_limit_rejects_another_peer() {
    timeout(Duration::from_secs(15), async {
        let mut server = server(Limits { max_reservations: 1, ..Limits::default() }).await;
        let mut first = client();
        reserve(&mut first, &server).await;
        let mut second = client();
        second.listen_on(server.address.clone().with(Protocol::P2pCircuit)).unwrap();
        let mut denied_by_server = false;
        let mut rejected_by_client = false;
        while !denied_by_server || !rejected_by_client {
            tokio::select! {
                _ = first.select_next_some() => {},
                event = second.select_next_some() => match event {
                    SwarmEvent::ListenerError {..} | SwarmEvent::ListenerClosed {reason: Err(_), ..} => rejected_by_client = true,
                    SwarmEvent::NewListenAddr {..} => panic!("second reservation exceeded limit"),
                    _ => {}
                },
                event = server.events.recv() => {
                    if let Some(SwarmEvent::Behaviour(BehaviourEvent::Relay(relay::Event::ReservationReqDenied {..}))) = event { denied_by_server = true; }
                }
            }
        }
    }).await.expect("reservation limit timed out");
}

#[tokio::test]
async fn connection_limit_rejects_another_peer() {
    timeout(Duration::from_secs(15), async {
        let mut server = server(Limits {
            max_connections: 1,
            max_connections_per_peer: 1,
            ..Limits::default()
        })
        .await;
        let mut first = client();
        reserve(&mut first, &server).await;
        let mut second = client();
        second.dial(server.address.clone()).unwrap();
        loop {
            tokio::select! {
                _ = first.select_next_some() => {},
                _ = second.select_next_some() => {},
                event = server.events.recv() => {
                    if let Some(SwarmEvent::IncomingConnectionError {error, ..}) = event {
                        assert!(format!("{error:?}").contains("Denied"), "{error:?}");
                        break;
                    }
                }
            }
        }
    })
    .await
    .expect("connection limit timed out");
}
