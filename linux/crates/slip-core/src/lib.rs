//! `slip-core` — the UI-free LocalSend v2 implementation used by the Slip Linux client.
//!
//! Behaviour follows `protocol/IMPLEMENTATION.md` in the repository root.
//!
//! * [`model`] — lenient serde models for the wire format.
//! * [`identity`] — persisted key/certificate, fingerprints.
//! * [`alias`] — random "Adjective Fruit" aliases.
//! * [`settings`] — persisted user settings (JSON in the XDG config dir).
//! * [`discovery`] — multicast announce/listen + HTTP `/24` scan.
//! * [`server`] — HTTPS/HTTP receive server.
//! * [`client`] — sender client.
//! * [`node`] — wires all of the above together for apps.

pub mod alias;
pub mod client;
pub mod discovery;
pub mod events;
pub mod identity;
pub mod model;
pub mod net;
pub mod node;
pub mod paths;
pub mod peers;
pub mod server;
pub mod settings;
pub mod tls;

pub use events::{Decision, Event, IncomingRequest};
pub use model::{DeviceInfo, DeviceType, FileDto, FileMetadata, Protocol};

/// Protocol version string we advertise.
pub const PROTOCOL_VERSION: &str = "2.1";
/// Default TCP/UDP port.
pub const DEFAULT_PORT: u16 = 53317;
/// Default multicast group.
pub const MULTICAST_GROUP: std::net::Ipv4Addr = std::net::Ipv4Addr::new(224, 0, 0, 167);
/// API prefix.
pub const API_PREFIX: &str = "/api/localsend/v2";
/// Application id (also used for the config directory on Linux desktops).
pub const APP_ID: &str = "io.github.nearbycoder.Slip";

/// The `deviceModel` string for this host.
pub fn device_model() -> String {
    match std::env::consts::OS {
        "linux" => "Linux".into(),
        "macos" => "macOS".into(),
        "windows" => "Windows".into(),
        "freebsd" => "FreeBSD".into(),
        other => other.to_string(),
    }
}
