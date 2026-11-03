//! `Node` wires identity + settings + server + discovery + client together. Apps (CLI,
//! GTK) create one and consume [`Event`]s from its channel.

use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use crate::client::SlipClient;
use crate::discovery::{Discovery, DiscoveryConfig};
use crate::events::Event;
use crate::identity::Identity;
use crate::model::{DeviceInfo, DeviceType, Protocol, SharedInfo};
use crate::peers::{Peer, PeerStore};
use crate::server::{ReceiveSettings, Server, ServerError, ServerOptions, SharedReceive};
use crate::settings::Settings;

pub struct NodeOptions {
    pub settings: Settings,
    pub device_type: DeviceType,
    /// Start the multicast listener.
    pub multicast: bool,
    /// Start the HTTP(S) server.
    pub server: bool,
}

pub struct Node {
    identity: Identity,
    info: SharedInfo,
    receive: SharedReceive,
    peers: PeerStore,
    client: SlipClient,
    discoverable: Arc<AtomicBool>,
    server: Mutex<Option<Server>>,
    discovery: Mutex<Option<Arc<Discovery>>>,
    settings: Mutex<Settings>,
    events: async_channel::Sender<Event>,
    multicast_enabled: bool,
    want_server: bool,
    server_error: Mutex<Option<String>>,
}

fn receive_settings(s: &Settings) -> ReceiveSettings {
    ReceiveSettings { save_dir: s.effective_save_dir(), pin: s.effective_pin(), auto_accept: s.quick_save }
}

fn protocol_of(s: &Settings) -> Protocol {
    if s.https {
        Protocol::Https
    } else {
        Protocol::Http
    }
}

impl Node {
    /// Must be called inside a tokio runtime.
    pub async fn start(
        identity: Identity,
        opts: NodeOptions,
        events: async_channel::Sender<Event>,
    ) -> Result<Arc<Node>, ServerError> {
        let s = opts.settings.clone();
        let protocol = protocol_of(&s);
        let info = Arc::new(RwLock::new(DeviceInfo {
            alias: s.alias.clone(),
            version: crate::PROTOCOL_VERSION.into(),
            device_model: Some(crate::device_model()),
            device_type: Some(opts.device_type),
            fingerprint: identity.fingerprint(protocol).to_string(),
            port: s.port,
            protocol,
            download: false,
        }));
        let receive = Arc::new(RwLock::new(receive_settings(&s)));
        let peers = PeerStore::new(identity.own_fingerprints(), Some(events.clone()));
        let client = SlipClient::new(info.clone());
        let node = Arc::new(Node {
            identity,
            info,
            receive,
            peers,
            client,
            discoverable: Arc::new(AtomicBool::new(s.discoverable)),
            server: Mutex::new(None),
            discovery: Mutex::new(None),
            settings: Mutex::new(s),
            events,
            multicast_enabled: opts.multicast,
            want_server: opts.server,
            server_error: Mutex::new(None),
        });
        if opts.server {
            // A busy port is not fatal: the app can still send and the user can pick
            // another port. Callers inspect `server_error()`.
            if let Err(e) = node.start_server().await {
                let msg = e.to_string();
                *node.server_error.lock().unwrap() = Some(msg.clone());
                let _ = node.events.try_send(Event::Warning(msg));
            }
        }
        if opts.multicast {
            node.start_discovery();
        }
        Ok(node)
    }

    async fn start_server(&self) -> Result<(), ServerError> {
        let (port, protocol) = {
            let s = self.settings.lock().unwrap();
            (s.port, protocol_of(&s))
        };
        // Drop the old server first so the port is free.
        self.server.lock().unwrap().take();
        let server = Server::start(
            ServerOptions { bind: IpAddr::V4(Ipv4Addr::UNSPECIFIED), port, protocol },
            &self.identity,
            self.info.clone(),
            self.receive.clone(),
            self.peers.clone(),
            self.events.clone(),
        )
        .await;
        match server {
            Ok(server) => {
                *self.server.lock().unwrap() = Some(server);
                *self.server_error.lock().unwrap() = None;
                Ok(())
            }
            Err(e) => {
                *self.server_error.lock().unwrap() = Some(e.to_string());
                Err(e)
            }
        }
    }

    fn start_discovery(&self) {
        let cfg = {
            let s = self.settings.lock().unwrap();
            DiscoveryConfig { group: s.multicast_group(), port: s.multicast_port }
        };
        self.discovery.lock().unwrap().take();
        match Discovery::start(cfg, self.info.clone(), self.peers.clone(), self.client.clone(), self.discoverable.clone()) {
            Ok(d) => {
                d.announce();
                *self.discovery.lock().unwrap() = Some(d);
            }
            Err(e) => {
                let _ = self.events.try_send(Event::Warning(format!(
                    "Multicast discovery unavailable on UDP {}: {e}. Use Refresh to scan the network.",
                    cfg.port
                )));
            }
        }
    }

    /// Apply new settings; restarts the server if port/protocol changed.
    pub async fn apply_settings(&self, new: Settings) -> Result<(), ServerError> {
        let old = std::mem::replace(&mut *self.settings.lock().unwrap(), new.clone());
        *self.receive.write().unwrap() = receive_settings(&new);
        self.discoverable.store(new.discoverable, Ordering::Relaxed);
        {
            let mut i = self.info.write().unwrap();
            i.alias = new.alias.clone();
        }
        let server_running = self.server.lock().unwrap().is_some();
        if self.want_server && (!server_running || old.port != new.port || old.https != new.https) {
            if let Err(e) = self.start_server().await {
                // Roll back to the old port/protocol so we keep receiving.
                {
                    let mut s = self.settings.lock().unwrap();
                    s.port = old.port;
                    s.https = old.https;
                }
                if server_running {
                    let _ = self.start_server().await;
                }
                *self.server_error.lock().unwrap() = Some(e.to_string());
                return Err(e);
            }
        }
        if self.multicast_enabled
            && (old.multicast_port != new.multicast_port || old.multicast_group != new.multicast_group)
        {
            self.start_discovery();
        } else if new.discoverable && (!old.discoverable || old.alias != new.alias || old.port != new.port || old.https != new.https) {
            self.announce();
        }
        Ok(())
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    pub fn device_info(&self) -> DeviceInfo {
        self.info.read().unwrap().clone()
    }

    pub fn client(&self) -> &SlipClient {
        &self.client
    }

    pub fn peers(&self) -> &PeerStore {
        &self.peers
    }

    pub fn peer_list(&self) -> Vec<Peer> {
        self.peers.list()
    }

    pub fn port(&self) -> Option<u16> {
        self.server.lock().unwrap().as_ref().map(Server::port)
    }

    /// Why the server isn't running, if it isn't.
    pub fn server_error(&self) -> Option<String> {
        self.server_error.lock().unwrap().clone()
    }

    pub fn multicast_active(&self) -> bool {
        self.discovery.lock().unwrap().is_some()
    }

    /// Multicast announce (×3).
    pub fn announce(&self) {
        if let Some(d) = self.discovery.lock().unwrap().as_ref() {
            d.announce();
        }
    }

    /// Announce + HTTP scan of local /24 subnets. Returns peers found by the scan.
    pub async fn refresh(&self) -> usize {
        self.announce();
        let protocol = self.info.read().unwrap().protocol;
        // Scan the configured port (peers usually share the default port).
        let scan_port = match self.settings.lock().unwrap().port {
            0 => crate::DEFAULT_PORT,
            p => p,
        };
        crate::discovery::scan_subnets(&self.client, &self.peers, scan_port, protocol).await
    }

    /// Cancel the active receive session.
    pub fn cancel_receive(&self) -> bool {
        self.server.lock().unwrap().as_ref().is_some_and(Server::cancel_session)
    }

    pub fn shutdown(&self) {
        self.discovery.lock().unwrap().take();
        self.server.lock().unwrap().take();
    }
}
