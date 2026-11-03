//! TLS plumbing: rustls server config from our identity and the HTTP client that
//! accepts LocalSend's self-signed certificates.

use std::sync::Arc;
use std::time::Duration;

use crate::identity::{Identity, IdentityError};

/// Install the `ring` rustls provider as process default (idempotent).
pub fn ensure_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

pub fn server_config(identity: &Identity) -> Result<Arc<rustls::ServerConfig>, IdentityError> {
    ensure_crypto_provider();
    let cert = rustls_pki_types::CertificateDer::from(identity.cert_der.clone());
    let key = identity.private_key_der()?;
    let mut cfg = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|e| IdentityError::Pem(e.to_string()))?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| IdentityError::Pem(e.to_string()))?;
    cfg.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Arc::new(cfg))
}

fn base_builder() -> reqwest::ClientBuilder {
    ensure_crypto_provider();
    reqwest::Client::builder()
        // LocalSend peers use self-signed certificates; chain + hostname checks are off
        // for these LAN endpoints only.
        .danger_accept_invalid_certs(true)
        .no_proxy()
        .http1_only()
        .user_agent(concat!("Slip/", env!("CARGO_PKG_VERSION"), " (Linux)"))
        .connect_timeout(Duration::from_secs(3))
}

/// Client for short control requests (register / info).
pub fn control_client(timeout: Duration) -> reqwest::Client {
    base_builder().timeout(timeout).build().expect("reqwest client")
}

/// Client for prepare-upload (held open by the receiver) and streamed uploads: no total
/// timeout, only connect + read-idle timeouts.
pub fn transfer_client() -> reqwest::Client {
    base_builder()
        .pool_idle_timeout(Duration::from_secs(30))
        .tcp_keepalive(Duration::from_secs(30))
        .build()
        .expect("reqwest client")
}
