use std::{path::PathBuf, time::Duration};

use cht_relay::{BehaviourEvent, RelayResult, build_swarm, config::Config, identity};
use clap::Parser;
use futures::StreamExt;
use libp2p::{multiaddr::Protocol, relay, swarm::SwarmEvent};
use serde_json::json;

#[derive(Parser)]
#[command(
    version,
    about = "Standalone cht Circuit Relay v2 server (TCP + Noise + Yamux)"
)]
struct Args {
    #[arg(long, default_value = "relay.json")]
    config: PathBuf,
    /// Validate configuration and exit without opening a port or creating a key.
    #[arg(long)]
    check_config: bool,
    /// Load/create the encrypted identity, print only its public Peer ID and exit.
    #[arg(long)]
    print_peer_id: bool,
    /// Windows Desktop: generate/unlock a DPAPI-protected service credential.
    #[arg(long)]
    windows_credential: bool,
    /// Test a public wss://HOST/cht endpoint without reading local credentials.
    #[arg(long, conflicts_with_all = ["check_config", "print_peer_id", "windows_credential"])]
    probe_websocket: Option<String>,
    /// Permit loopback URLs when probing a locally running test relay.
    #[arg(long, requires = "probe_websocket")]
    allow_loopback_probe: bool,
}

async fn shutdown() -> RelayResult<()> {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! { result = tokio::signal::ctrl_c() => result?, _ = terminate.recv() => {} }
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c().await?;
    Ok(())
}

#[tokio::main]
async fn main() {
    if let Err(error) = run(Args::parse()).await {
        eprintln!("{}", json!({"event":"error", "message":error.to_string()}));
        std::process::exit(1);
    }
}

async fn run(args: Args) -> RelayResult<()> {
    if let Some(endpoint) = args.probe_websocket {
        let relay = cht_relay::websocket::probe_endpoint(&endpoint, args.allow_loopback_probe).await?;
        println!(
            "{}",
            json!({"event":"websocket_probe_ok", "endpoint":relay.endpoint, "relayId":relay.relay_id})
        );
        return Ok(());
    }
    let config = Config::read(&args.config)?;
    if args.check_config {
        println!(
            "{}",
            json!({"event":"config_valid", "port":config.port,"limits":config.limits})
        );
        return Ok(());
    }
    let password = if args.windows_credential {
        identity::windows_password(&config.state_dir)?
    } else {
        let credential = std::env::var_os("CHT_RELAY_KEY_PASSWORD_FILE").ok_or(
            "Set CHT_RELAY_KEY_PASSWORD_FILE to a private credential file (or systemd credential)",
        )?;
        identity::password_from_file(std::path::Path::new(&credential))?
    };
    let key = identity::load_or_create(&config.state_dir, &password)?;
    drop(password);
    let peer_id = key.public().to_peer_id();
    if args.print_peer_id {
        println!("{peer_id}");
        return Ok(());
    }
    let websocket_key = key.clone();
    let websocket_config = config.websocket.clone();
    let websocket_state = config.state_dir.clone();
    let websocket = async move {
        match websocket_config {
            Some(value) => cht_relay::websocket::run(value, websocket_key, websocket_state).await,
            None => std::future::pending::<RelayResult<()>>().await,
        }
    };
    tokio::pin!(websocket);
    let mut swarm = build_swarm(key, &config.limits)?;
    for address in &config.public_addresses {
        swarm.add_external_address(address.parse()?);
    }
    if config.tcp_enabled {
        swarm.listen_on(config.listen_address())?;
    }
    let public_addresses: Vec<_> = config
        .public_addresses
        .iter()
        .map(|address| format!("{address}/p2p/{peer_id}"))
        .collect();
    println!(
        "{}",
        json!({"event":"starting", "peer_id":peer_id.to_string(),"public_addresses":public_addresses,"limits":config.limits})
    );
    let mut accepted_reservations = 0u64;
    let mut accepted_circuits = 0u64;
    let mut denied_requests = 0u64;
    let mut ticker = tokio::time::interval(Duration::from_secs(30));
    let shutdown = shutdown();
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            result = &mut websocket => return result,
            result = &mut shutdown => {
                result?;
                println!("{}", json!({"event":"shutdown"}));
                return Ok(());
            }
            _ = ticker.tick() => {
                println!("{}", json!({"event":"stats", "connections":swarm.network_info().connection_counters().num_established(),"peers":swarm.connected_peers().count(),"reservations_accepted":accepted_reservations,"circuits_accepted":accepted_circuits,"requests_denied":denied_requests}));
            }
            event = swarm.select_next_some() => match event {
                SwarmEvent::NewListenAddr { address, .. } => println!("{}", json!({"event":"listening", "address":address.with(Protocol::P2p(peer_id)).to_string()})),
                SwarmEvent::ListenerError { error, .. } => return Err(error.into()),
                SwarmEvent::ListenerClosed { reason, .. } => {
                    reason?;
                    return Err("Relay listener closed".into());
                }
                SwarmEvent::Behaviour(BehaviourEvent::Relay(event)) => match event {
                    relay::Event::ReservationReqAccepted { .. } => accepted_reservations = accepted_reservations.saturating_add(1),
                    relay::Event::CircuitReqAccepted { .. } => accepted_circuits = accepted_circuits.saturating_add(1),
                    relay::Event::ReservationReqDenied { .. } | relay::Event::CircuitReqDenied { .. } => denied_requests = denied_requests.saturating_add(1),
                    _ => {}
                },
                _ => {}
            }
        }
    }
}
