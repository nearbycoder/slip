//! Stale peers are probed with `POST /register` before they are dropped.

use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use slip_core::client::SlipClient;
use slip_core::discovery::expire_stale;
use slip_core::identity::Identity;
use slip_core::model::{DeviceInfo, DeviceType, Protocol};
use slip_core::peers::{PeerStore, PEER_TTL};
use slip_core::server::{ReceiveSettings, Server, ServerOptions};

const LOCALHOST: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

fn device(alias: &str, fingerprint: &str, port: u16, protocol: Protocol) -> DeviceInfo {
    DeviceInfo {
        alias: alias.into(),
        version: "2.1".into(),
        device_model: None,
        device_type: Some(DeviceType::Headless),
        fingerprint: fingerprint.into(),
        port,
        protocol,
        download: false,
    }
}

/// A peer store whose clock the test can move forward.
fn store() -> (PeerStore, Arc<Mutex<Instant>>) {
    let now = Arc::new(Mutex::new(Instant::now()));
    let clock = now.clone();
    (PeerStore::with_clock(vec!["our-fingerprint".into()], None, Arc::new(move || *clock.lock().unwrap())), now)
}

fn advance(now: &Mutex<Instant>, by: Duration) {
    *now.lock().unwrap() += by;
}

fn our_client() -> SlipClient {
    SlipClient::new(Arc::new(RwLock::new(device("Us", "our-fingerprint", 1, Protocol::Http))))
}

fn closed_port() -> u16 {
    std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap().local_addr().unwrap().port()
}

#[tokio::test]
async fn stale_reachable_peer_is_refreshed_under_its_original_key() {
    let identity = Identity::generate().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let (tx, _rx) = async_channel::unbounded();
    let server = Server::start(
        ServerOptions { bind: LOCALHOST, port: 0, protocol: Protocol::Http },
        &identity,
        Arc::new(RwLock::new(device("Reachable", "", 0, Protocol::Http))),
        Arc::new(RwLock::new(ReceiveSettings { save_dir: dir.path().to_path_buf(), pin: None, auto_accept: false })),
        PeerStore::new(identity.own_fingerprints(), None),
        tx,
    )
    .await
    .unwrap();
    let port = server.port();

    let (peers, now) = store();
    peers.upsert(device("Old name", "original-fp", port, Protocol::Http), LOCALHOST);
    advance(&now, PEER_TTL + Duration::from_secs(1));

    let removed = expire_stale(&our_client(), &peers, PEER_TTL, Duration::from_secs(2)).await;

    assert!(removed.is_empty());
    let list = peers.list();
    assert_eq!(list.len(), 1);
    let peer = &list[0];
    assert_eq!(peer.info.fingerprint, "original-fp");
    assert_eq!(peer.info.port, port);
    assert_eq!(peer.info.protocol, Protocol::Http);
    assert_eq!(peer.info.alias, "Reachable");
    assert_eq!(peer.last_seen, *now.lock().unwrap());
}

#[tokio::test]
async fn stale_unreachable_peer_is_removed_but_pinned_and_fresh_are_kept() {
    let port = closed_port();
    let (peers, now) = store();
    peers.upsert(device("Gone", "gone", port, Protocol::Http), LOCALHOST);
    peers.upsert(device("Busy", "busy", port, Protocol::Http), LOCALHOST);
    peers.pin("busy");
    advance(&now, PEER_TTL + Duration::from_secs(1));
    peers.upsert(device("Fresh", "fresh", port, Protocol::Http), LOCALHOST);

    let removed = expire_stale(&our_client(), &peers, PEER_TTL, Duration::from_millis(500)).await;

    assert_eq!(removed, vec!["gone".to_string()]);
    let mut left: Vec<String> = peers.list().into_iter().map(|p| p.info.fingerprint).collect();
    left.sort();
    assert_eq!(left, ["busy", "fresh"]);
}

#[test]
fn removal_skips_peers_seen_again_since_the_snapshot() {
    let (peers, now) = store();
    peers.upsert(device("A", "a", 1, Protocol::Http), LOCALHOST);
    advance(&now, PEER_TTL + Duration::from_secs(1));
    let stale = peers.stale(PEER_TTL);
    assert_eq!(stale.len(), 1);
    peers.upsert(device("A", "a", 1, Protocol::Http), LOCALHOST);
    assert!(!peers.remove_if_unseen(&stale[0]));
    assert_eq!(peers.list().len(), 1);
}
