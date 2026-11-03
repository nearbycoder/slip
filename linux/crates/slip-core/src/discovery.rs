//! Multicast discovery (announce ×3, listen, answer via `/register` with UDP fallback)
//! and the HTTP `/24` scan fallback.

use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::stream::{self, StreamExt};
use socket2::{Domain, Protocol as SockProto, SockRef, Socket, Type};
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;

use crate::client::{SlipClient, Target};
use crate::model::{MulticastDto, Protocol, SharedInfo};
use crate::net::ipv4_interfaces;
use crate::peers::{PeerStore, PEER_TTL};

/// Timeout for the `/register` probe sent to a stale peer.
pub const PEER_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// Peers only announce at startup, so we re-announce this often; their `/register` replies keep them fresh.
pub const REANNOUNCE_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy)]
pub struct DiscoveryConfig {
    pub group: Ipv4Addr,
    pub port: u16,
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        DiscoveryConfig { group: crate::MULTICAST_GROUP, port: crate::DEFAULT_PORT }
    }
}

/// Bind the multicast socket: `0.0.0.0:port`, SO_REUSEADDR + SO_REUSEPORT, joined on
/// every non-loopback IPv4 interface, TTL 32, loopback on.
pub fn bind_multicast(cfg: &DiscoveryConfig) -> std::io::Result<(UdpSocket, Vec<Ipv4Addr>)> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(SockProto::UDP))?;
    socket.set_reuse_address(true)?;
    #[cfg(all(unix, not(any(target_os = "solaris", target_os = "illumos"))))]
    socket.set_reuse_port(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, cfg.port)).into())?;
    socket.set_multicast_ttl_v4(32)?;
    socket.set_multicast_loop_v4(true)?;

    let mut joined = Vec::new();
    for iface in ipv4_interfaces() {
        match socket.join_multicast_v4(&cfg.group, &iface.addr) {
            Ok(()) => joined.push(iface.addr),
            Err(e) => tracing::debug!("join {} on {} failed: {e}", cfg.group, iface.addr),
        }
    }
    if joined.is_empty() {
        // No usable interface (e.g. offline / CI): join on the default interface so
        // loopback multicast still works.
        if socket.join_multicast_v4(&cfg.group, &Ipv4Addr::UNSPECIFIED).is_ok() {
            joined.push(Ipv4Addr::UNSPECIFIED);
        }
    }
    let std_sock: std::net::UdpSocket = socket.into();
    Ok((UdpSocket::from_std(std_sock)?, joined))
}

/// Running discovery service. Dropping it stops the background tasks.
pub struct Discovery {
    socket: Arc<UdpSocket>,
    cfg: DiscoveryConfig,
    info: SharedInfo,
    peers: PeerStore,
    client: SlipClient,
    discoverable: Arc<AtomicBool>,
    interfaces: Vec<Ipv4Addr>,
    tasks: Vec<JoinHandle<()>>,
}

impl Drop for Discovery {
    fn drop(&mut self) {
        for t in &self.tasks {
            t.abort();
        }
    }
}

impl Discovery {
    /// Bind and start listening. Does not announce; call [`Discovery::announce`].
    pub fn start(
        cfg: DiscoveryConfig,
        info: SharedInfo,
        peers: PeerStore,
        client: SlipClient,
        discoverable: Arc<AtomicBool>,
    ) -> std::io::Result<Arc<Discovery>> {
        let (socket, interfaces) = bind_multicast(&cfg)?;
        let socket = Arc::new(socket);
        let mut d = Discovery { socket, cfg, info, peers, client, discoverable, interfaces, tasks: vec![] };
        d.tasks.push(tokio::spawn(listen_loop(
            d.socket.clone(),
            d.cfg,
            d.info.clone(),
            d.peers.clone(),
            d.client.clone(),
            d.discoverable.clone(),
            d.interfaces.clone(),
        )));
        d.tasks.push(tokio::spawn(maintenance_loop(
            d.socket.clone(),
            d.cfg,
            d.info.clone(),
            d.peers.clone(),
            d.client.clone(),
            d.discoverable.clone(),
            d.interfaces.clone(),
        )));
        Ok(Arc::new(d))
    }

    pub fn interfaces(&self) -> &[Ipv4Addr] {
        &self.interfaces
    }

    /// Announce ourselves three times (~100 ms, ~500 ms, ~2000 ms).
    pub fn announce(&self) {
        if !self.discoverable.load(Ordering::Relaxed) {
            return;
        }
        let socket = self.socket.clone();
        let cfg = self.cfg;
        let info = self.info.clone();
        let ifaces = self.interfaces.clone();
        tokio::spawn(async move {
            let mut elapsed = 0u64;
            for at in [100u64, 500, 2000] {
                tokio::time::sleep(Duration::from_millis(at - elapsed)).await;
                elapsed = at;
                let packet = MulticastDto { info: info.read().unwrap().clone(), announce: true }.to_json();
                send_multicast(&socket, &cfg, &ifaces, &packet).await;
            }
        });
    }

    /// HTTP scan fallback over each local /24.
    pub async fn scan(&self) -> usize {
        let (port, protocol) = {
            let i = self.info.read().unwrap();
            (i.port, i.protocol)
        };
        scan_subnets(&self.client, &self.peers, port, protocol).await
    }
}

async fn send_multicast(socket: &UdpSocket, cfg: &DiscoveryConfig, ifaces: &[Ipv4Addr], packet: &[u8]) {
    let dest = SocketAddr::V4(SocketAddrV4::new(cfg.group, cfg.port));
    if ifaces.is_empty() || ifaces == [Ipv4Addr::UNSPECIFIED] {
        if let Err(e) = socket.send_to(packet, dest).await {
            tracing::debug!("multicast send failed: {e}");
        }
        return;
    }
    for iface in ifaces {
        // Route the datagram out of each interface in turn.
        let _ = SockRef::from(socket).set_multicast_if_v4(iface);
        if let Err(e) = socket.send_to(packet, dest).await {
            tracing::debug!("multicast send via {iface} failed: {e}");
        }
    }
    let _ = SockRef::from(socket).set_multicast_if_v4(&Ipv4Addr::UNSPECIFIED);
}

async fn listen_loop(
    socket: Arc<UdpSocket>,
    cfg: DiscoveryConfig,
    info: SharedInfo,
    peers: PeerStore,
    client: SlipClient,
    discoverable: Arc<AtomicBool>,
    ifaces: Vec<Ipv4Addr>,
) {
    let mut buf = vec![0u8; 65536];
    loop {
        let (n, src) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                tracing::debug!("multicast recv error: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
        };
        let Ok(dto) = MulticastDto::parse(&buf[..n]) else {
            continue;
        };
        if peers.is_own(&dto.info.fingerprint) {
            continue;
        }
        let ip = src.ip();
        let peer_info = dto.info.clone();
        if !peers.upsert(dto.info, ip) {
            continue;
        }
        if dto.announce && discoverable.load(Ordering::Relaxed) {
            let client = client.clone();
            let socket = socket.clone();
            let info = info.clone();
            let ifaces = ifaces.clone();
            tokio::spawn(async move {
                let target = Target { host: ip.to_string(), port: peer_info.port, protocol: peer_info.protocol };
                if let Err(e) = client.register(&target).await {
                    tracing::debug!("register with {ip} failed ({e}); answering via multicast");
                    let packet = MulticastDto { info: info.read().unwrap().clone(), announce: false }.to_json();
                    send_multicast(&socket, &cfg, &ifaces, &packet).await;
                }
            });
        }
    }
}

/// Re-announces every [`REANNOUNCE_INTERVAL`] and expires silent peers (after probing them).
async fn maintenance_loop(
    socket: Arc<UdpSocket>,
    cfg: DiscoveryConfig,
    info: SharedInfo,
    peers: PeerStore,
    client: SlipClient,
    discoverable: Arc<AtomicBool>,
    ifaces: Vec<Ipv4Addr>,
) {
    let tick = Duration::from_secs(5);
    let mut interval = tokio::time::interval(tick);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut since_announce = Duration::ZERO;
    loop {
        interval.tick().await;
        since_announce += tick;
        // Peers only announce at startup, so ask again periodically; their /register replies refresh them.
        if since_announce >= REANNOUNCE_INTERVAL {
            since_announce = Duration::ZERO;
            if discoverable.load(Ordering::Relaxed) {
                let packet = MulticastDto { info: info.read().unwrap().clone(), announce: true }.to_json();
                send_multicast(&socket, &cfg, &ifaces, &packet).await;
            }
        }
        expire_stale(&client, &peers, PEER_TTL, PEER_PROBE_TIMEOUT).await;
    }
}

/// Probe peers not seen within `ttl` with `POST /register` (concurrently) and drop only those
/// that don't answer within `timeout`. Answering peers are refreshed under their original
/// fingerprint, port and protocol; pinned peers (active transfers) are never touched.
/// Returns the removed fingerprints.
pub async fn expire_stale(client: &SlipClient, peers: &PeerStore, ttl: Duration, timeout: Duration) -> Vec<String> {
    let probes = peers.stale(ttl).into_iter().map(|peer| {
        let client = client.clone();
        let peers = peers.clone();
        async move {
            let reply = tokio::time::timeout(timeout, client.register_with_timeout(&peer.target(), timeout)).await;
            match reply {
                Ok(Ok(mut info)) => {
                    info.fingerprint = peer.info.fingerprint.clone();
                    info.port = peer.info.port;
                    info.protocol = peer.info.protocol;
                    peers.upsert(info, peer.ip);
                    None
                }
                _ => peers.remove_if_unseen(&peer).then(|| {
                    tracing::debug!("peer {} ({}) is gone", peer.info.alias, peer.address());
                    peer.info.fingerprint.clone()
                }),
            }
        }
    });
    futures_util::future::join_all(probes).await.into_iter().flatten().collect()
}

/// `POST /register` to every host of each local /24 (≤ 50 concurrent, ~1 s timeout).
/// Returns the number of peers found.
pub async fn scan_subnets(client: &SlipClient, peers: &PeerStore, port: u16, protocol: Protocol) -> usize {
    let hosts: Vec<Ipv4Addr> = ipv4_interfaces().iter().flat_map(|i| i.scan_hosts()).collect();
    scan_hosts(client, peers, &hosts, port, protocol).await
}

pub async fn scan_hosts(client: &SlipClient, peers: &PeerStore, hosts: &[Ipv4Addr], port: u16, protocol: Protocol) -> usize {
    let found = stream::iter(hosts.iter().copied())
        .map(|ip| {
            let client = client.clone();
            let peers = peers.clone();
            async move {
                let target = Target { host: ip.to_string(), port, protocol };
                match tokio::time::timeout(Duration::from_millis(1200), client.register_with_timeout(&target, Duration::from_secs(1))).await {
                    Ok(Ok(mut info)) => {
                        // Responses may omit port/protocol; we know what worked.
                        info.port = port;
                        info.protocol = protocol;
                        peers.upsert(info, IpAddr::V4(ip))
                    }
                    _ => false,
                }
            }
        })
        .buffer_unordered(50)
        .filter(|ok| std::future::ready(*ok))
        .count()
        .await;
    found
}
