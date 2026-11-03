//! The set of nearby devices, keyed by fingerprint.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::events::Event;
use crate::model::{DeviceInfo, Protocol};

pub const PEER_TTL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone)]
pub struct Peer {
    pub info: DeviceInfo,
    pub ip: IpAddr,
    pub last_seen: Instant,
}

impl Peer {
    pub fn target(&self) -> crate::client::Target {
        crate::client::Target { host: self.ip.to_string(), port: self.info.port, protocol: self.info.protocol }
    }

    pub fn address(&self) -> String {
        format!("{}:{}", self.ip, self.info.port)
    }

    pub fn protocol(&self) -> Protocol {
        self.info.protocol
    }
}

#[derive(Clone)]
pub struct PeerStore {
    inner: Arc<Mutex<HashMap<String, Peer>>>,
    own: Arc<Vec<String>>,
    events: Option<async_channel::Sender<Event>>,
    /// Fingerprints that must not expire (active transfers).
    pinned: Arc<Mutex<HashMap<String, usize>>>,
}

impl PeerStore {
    pub fn new(own_fingerprints: Vec<String>, events: Option<async_channel::Sender<Event>>) -> Self {
        PeerStore {
            inner: Default::default(),
            own: Arc::new(own_fingerprints),
            events,
            pinned: Default::default(),
        }
    }

    pub fn is_own(&self, fingerprint: &str) -> bool {
        self.own.iter().any(|f| f == fingerprint)
    }

    /// Add or update a peer. Returns `false` for our own fingerprint / empty fingerprints.
    pub fn upsert(&self, info: DeviceInfo, ip: IpAddr) -> bool {
        if info.fingerprint.is_empty() || self.is_own(&info.fingerprint) {
            return false;
        }
        let peer = Peer { info, ip, last_seen: Instant::now() };
        self.inner.lock().unwrap().insert(peer.info.fingerprint.clone(), peer.clone());
        if let Some(tx) = &self.events {
            let _ = tx.try_send(Event::PeerUpdated(peer));
        }
        true
    }

    pub fn get(&self, fingerprint: &str) -> Option<Peer> {
        self.inner.lock().unwrap().get(fingerprint).cloned()
    }

    pub fn list(&self) -> Vec<Peer> {
        let mut v: Vec<Peer> = self.inner.lock().unwrap().values().cloned().collect();
        v.sort_by(|a, b| a.info.alias.to_lowercase().cmp(&b.info.alias.to_lowercase()));
        v
    }

    /// Keep a peer alive while a transfer with it is active.
    pub fn pin(&self, fingerprint: &str) {
        *self.pinned.lock().unwrap().entry(fingerprint.to_string()).or_default() += 1;
    }

    pub fn unpin(&self, fingerprint: &str) {
        let mut p = self.pinned.lock().unwrap();
        if let Some(n) = p.get_mut(fingerprint) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                p.remove(fingerprint);
            }
        }
    }

    /// Drop peers not seen within `ttl` (unless pinned). Returns removed fingerprints.
    pub fn expire(&self, ttl: Duration) -> Vec<String> {
        let pinned = self.pinned.lock().unwrap().clone();
        let mut map = self.inner.lock().unwrap();
        let now = Instant::now();
        let stale: Vec<String> = map
            .iter()
            .filter(|(fp, p)| now.duration_since(p.last_seen) > ttl && !pinned.contains_key(*fp))
            .map(|(fp, _)| fp.clone())
            .collect();
        for fp in &stale {
            map.remove(fp);
            if let Some(tx) = &self.events {
                let _ = tx.try_send(Event::PeerLost { fingerprint: fp.clone() });
            }
        }
        stale
    }
}
