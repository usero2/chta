pub mod config;
pub mod identity;
pub mod websocket;

use std::time::Duration;

use libp2p::{
    Swarm, SwarmBuilder, connection_limits, identify, noise, ping, relay, swarm::NetworkBehaviour,
    tcp, yamux,
};

pub type RelayResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(NetworkBehaviour)]
pub struct Behaviour {
    pub limits: connection_limits::Behaviour,
    pub relay: relay::Behaviour,
    pub identify: identify::Behaviour,
    pub ping: ping::Behaviour,
}

pub fn build_swarm(
    key: libp2p::identity::Keypair,
    limits: &config::Limits,
) -> RelayResult<Swarm<Behaviour>> {
    limits.validate()?;
    let connection_limits = limits.connection_limits();
    let relay_config = limits.relay_config();
    Ok(SwarmBuilder::with_existing_identity(key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_behaviour(move |key| Behaviour {
            limits: connection_limits::Behaviour::new(connection_limits),
            relay: relay::Behaviour::new(key.public().to_peer_id(), relay_config),
            identify: identify::Behaviour::new(
                identify::Config::new("/cht/relay/1".to_owned(), key.public()).with_agent_version(
                    concat!("cht-relay/", env!("CARGO_PKG_VERSION")).to_owned(),
                ),
            ),
            ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(30))),
        })?
        .with_swarm_config(|config| {
            config
                .with_idle_connection_timeout(Duration::from_secs(120))
                .with_max_negotiating_inbound_streams(32)
        })
        .build())
}
