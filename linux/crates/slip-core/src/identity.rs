//! Device identity: a persisted ECDSA P-256 key + self-signed certificate (CN=Slip),
//! the HTTPS fingerprint (SHA-256 of the certificate DER) and a persisted random
//! fingerprint used in HTTP mode.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivateKeyDer};
use sha2::{Digest, Sha256};

use crate::model::Protocol;

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("i/o: {0}")]
    Io(#[from] io::Error),
    #[error("certificate generation failed: {0}")]
    Rcgen(#[from] rcgen::Error),
    #[error("invalid PEM: {0}")]
    Pem(String),
}

#[derive(Clone)]
pub struct Identity {
    pub cert_pem: String,
    pub key_pem: String,
    pub cert_der: Vec<u8>,
    /// Lowercase hex SHA-256 of the certificate DER.
    pub cert_fingerprint: String,
    /// Random 32-char hex used when running plain HTTP.
    pub http_fingerprint: String,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("cert_fingerprint", &self.cert_fingerprint)
            .field("http_fingerprint", &self.http_fingerprint)
            .finish_non_exhaustive()
    }
}

/// Lowercase hex SHA-256.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn random_hex32() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

impl Identity {
    /// Generate a fresh, in-memory identity.
    pub fn generate() -> Result<Self, IdentityError> {
        let key = KeyPair::generate()?;
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, "Slip");
        dn.push(DnType::OrganizationName, "Slip");
        params.distinguished_name = dn;
        let now = time::OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::days(1);
        params.not_after = now + time::Duration::days(365 * 20);
        let mut serial = [0u8; 16];
        serial.copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        serial[0] &= 0x7f;
        params.serial_number = Some(rcgen::SerialNumber::from_slice(&serial));
        let cert = params.self_signed(&key)?;
        let cert_der = cert.der().to_vec();
        Ok(Identity {
            cert_pem: cert.pem(),
            key_pem: key.serialize_pem(),
            cert_fingerprint: sha256_hex(&cert_der),
            cert_der,
            http_fingerprint: random_hex32(),
        })
    }

    /// Load `cert.pem`, `key.pem`, `http-fingerprint` from `dir`, generating and
    /// persisting any that are missing or invalid.
    pub fn load_or_create(dir: &Path) -> Result<Self, IdentityError> {
        fs::create_dir_all(dir)?;
        let cert_path = dir.join("cert.pem");
        let key_path = dir.join("key.pem");
        let fp_path = dir.join("http-fingerprint");

        let loaded = match (fs::read_to_string(&cert_path), fs::read_to_string(&key_path)) {
            (Ok(cert_pem), Ok(key_pem)) => Self::from_pem(cert_pem, key_pem, String::new()).ok(),
            _ => None,
        };
        let mut id = match loaded {
            Some(id) => id,
            None => {
                let id = Self::generate()?;
                write_private(&key_path, id.key_pem.as_bytes())?;
                fs::write(&cert_path, id.cert_pem.as_bytes())?;
                id
            }
        };
        match fs::read_to_string(&fp_path) {
            Ok(s) if s.trim().len() >= 16 => id.http_fingerprint = s.trim().to_string(),
            _ => {
                if id.http_fingerprint.is_empty() {
                    id.http_fingerprint = random_hex32();
                }
                fs::write(&fp_path, id.http_fingerprint.as_bytes())?;
            }
        }
        Ok(id)
    }

    pub fn from_pem(cert_pem: String, key_pem: String, http_fingerprint: String) -> Result<Self, IdentityError> {
        let der = CertificateDer::from_pem_slice(cert_pem.as_bytes())
            .map_err(|e| IdentityError::Pem(e.to_string()))?;
        // Validate the key parses.
        PrivateKeyDer::from_pem_slice(key_pem.as_bytes()).map_err(|e| IdentityError::Pem(e.to_string()))?;
        let cert_der = der.as_ref().to_vec();
        Ok(Identity {
            cert_fingerprint: sha256_hex(&cert_der),
            cert_der,
            cert_pem,
            key_pem,
            http_fingerprint,
        })
    }

    /// The fingerprint to advertise for the given protocol.
    pub fn fingerprint(&self, protocol: Protocol) -> &str {
        match protocol {
            Protocol::Https => &self.cert_fingerprint,
            Protocol::Http => &self.http_fingerprint,
        }
    }

    /// Both fingerprints (used to filter self-discovery regardless of mode).
    pub fn own_fingerprints(&self) -> Vec<String> {
        vec![self.cert_fingerprint.clone(), self.http_fingerprint.clone()]
    }

    pub fn private_key_der(&self) -> Result<PrivateKeyDer<'static>, IdentityError> {
        PrivateKeyDer::from_pem_slice(self.key_pem.as_bytes()).map_err(|e| IdentityError::Pem(e.to_string()))
    }
}

fn write_private(path: &PathBuf, data: &[u8]) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(path)?;
        f.write_all(data)
    }
    #[cfg(not(unix))]
    {
        fs::write(path, data)
    }
}
