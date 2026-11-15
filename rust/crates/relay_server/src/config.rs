use std::{
    fs,
    io::Read,
    net::IpAddr,
    path::{Path, PathBuf},
    time::Duration,
};

use libp2p::{Multiaddr, connection_limits::ConnectionLimits, multiaddr::Protocol, relay};
use serde::{Deserialize, Serialize};

use crate::RelayResult;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub listen_ip: IpAddr,
    pub port: u16,
    pub public_addresses: Vec<String>,
    pub state_dir: PathBuf,
    pub limits: Limits,
    pub tcp_enabled: bool,
    pub websocket: Option<crate::websocket::WebSocketConfig>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen_ip: "0.0.0.0".parse().expect("literal IP"),
            port: 4001,
            public_addresses: Vec::new(),
            state_dir: PathBuf::from("relay-data"),
            limits: Limits::default(),
            tcp_enabled: true,
            websocket: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Limits {
    pub max_connections: u32,
    pub max_connections_per_peer: u32,
    pub max_pending_incoming: u32,
    pub max_pending_outgoing: u32,
    pub max_reservations: usize,
    pub max_reservations_per_peer: usize,
    pub reservation_seconds: u64,
    pub max_circuits: usize,
    pub max_circuits_per_peer: usize,
    pub circuit_seconds: u64,
    pub circuit_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_connections: 128,
            max_connections_per_peer: 4,
            max_pending_incoming: 32,
            max_pending_outgoing: 16,
            max_reservations: 64,
            max_reservations_per_peer: 1,
            reservation_seconds: 3600,
            max_circuits: 32,
            max_circuits_per_peer: 4,
            circuit_seconds: 300,
            circuit_bytes: 8 * 1024 * 1024,
        }
    }
}

impl Config {
    pub fn read(path: &Path) -> RelayResult<Self> {
        let mut bytes = Vec::new();
        fs::File::open(path)?
            .take(64 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 64 * 1024 {
            return Err("Relay configuration is too large".into());
        }
        let value: Self = serde_json::from_slice(&bytes)?;
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> RelayResult<()> {
        if self.port == 0 {
            return Err("Use a fixed TCP port from 1 to 65535".into());
        }
        if self.state_dir.as_os_str().is_empty() {
            return Err("state_dir must not be empty".into());
        }
        if self.tcp_enabled && self.public_addresses.is_empty() || self.public_addresses.len() > 16
        {
            return Err(
                "Set 1 to 16 reachable public_addresses (use loopback only for local tests)".into(),
            );
        }
        if let Some(config) = &self.websocket {
            config.validate()?;
        }
        if !self.tcp_enabled && self.websocket.is_none() {
            return Err("Enable TCP or WebSocket transport".into());
        }
        for address in &self.public_addresses {
            let parsed: Multiaddr = address.parse()?;
            let parts: Vec<_> = parsed.iter().collect();
            let host_valid = matches!(parts.first(), Some(Protocol::Ip4(ip)) if !ip.is_unspecified())
                || matches!(parts.first(), Some(Protocol::Ip6(ip)) if !ip.is_unspecified())
                || matches!(parts.first(), Some(Protocol::Dns(host) | Protocol::Dns4(host) | Protocol::Dns6(host)) if !host.is_empty());
            if parts.len() != 2
                || !host_valid
                || !matches!(parts.get(1), Some(Protocol::Tcp(port)) if *port == self.port)
            {
                return Err("Each public address must be /ip4|ip6|dns4|dns6/HOST/tcp/PORT using the listening port, without /p2p".into());
            }
        }
        self.limits.validate()
    }

    pub fn listen_address(&self) -> Multiaddr {
        Multiaddr::empty()
            .with(Protocol::from(self.listen_ip))
            .with(Protocol::Tcp(self.port))
    }
}

impl Limits {
    pub fn validate(&self) -> RelayResult<()> {
        let counts = [
            self.max_connections as u64,
            self.max_connections_per_peer as u64,
            self.max_pending_incoming as u64,
            self.max_pending_outgoing as u64,
            self.max_reservations as u64,
            self.max_reservations_per_peer as u64,
            self.max_circuits as u64,
            self.max_circuits_per_peer as u64,
        ];
        if counts.iter().any(|&count| count == 0 || count > 65535) {
            return Err("All connection, reservation and circuit counts must be 1 to 65535".into());
        }
        if self.max_connections_per_peer > self.max_connections
            || self.max_reservations_per_peer > self.max_reservations
            || self.max_circuits_per_peer > self.max_circuits
        {
            return Err("Per-peer limits must not exceed their total limits".into());
        }
        if !(1..=86400).contains(&self.reservation_seconds)
            || !(1..=86400).contains(&self.circuit_seconds)
            || !(1..=1024 * 1024 * 1024).contains(&self.circuit_bytes)
        {
            return Err(
                "Durations must be 1 to 86400 seconds and circuit_bytes 1 to 1073741824".into(),
            );
        }
        Ok(())
    }

    pub fn relay_config(&self) -> relay::Config {
        // Preserve libp2p's default per-IP and per-peer request rate limiters.
        relay::Config {
            max_reservations: self.max_reservations,
            max_reservations_per_peer: self.max_reservations_per_peer,
            reservation_duration: Duration::from_secs(self.reservation_seconds),
            max_circuits: self.max_circuits,
            max_circuits_per_peer: self.max_circuits_per_peer,
            max_circuit_duration: Duration::from_secs(self.circuit_seconds),
            max_circuit_bytes: self.circuit_bytes,
            ..Default::default()
        }
    }

    pub fn connection_limits(&self) -> ConnectionLimits {
        ConnectionLimits::default()
            .with_max_pending_incoming(Some(self.max_pending_incoming))
            .with_max_pending_outgoing(Some(self.max_pending_outgoing))
            .with_max_established_incoming(Some(self.max_connections))
            .with_max_established_outgoing(Some(self.max_connections))
            .with_max_established(Some(self.max_connections))
            .with_max_established_per_peer(Some(self.max_connections_per_peer))
    }
}
