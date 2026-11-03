//! Wire models. Parsing is deliberately lenient: unknown fields are ignored, optional
//! fields default, `null` is accepted wherever a default exists.

use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize};

use crate::{DEFAULT_PORT, PROTOCOL_VERSION};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Http,
    #[default]
    Https,
}

impl Protocol {
    pub fn as_str(self) -> &'static str {
        match self {
            Protocol::Http => "http",
            Protocol::Https => "https",
        }
    }
}

impl std::fmt::Display for Protocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Protocol {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = Option::<String>::deserialize(d)?;
        Ok(match s.as_deref().map(str::to_ascii_lowercase).as_deref() {
            Some("http") => Protocol::Http,
            _ => Protocol::Https,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum DeviceType {
    Mobile,
    #[default]
    Desktop,
    Web,
    Headless,
    Server,
}

impl DeviceType {
    fn parse(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "mobile" => DeviceType::Mobile,
            "web" => DeviceType::Web,
            "headless" => DeviceType::Headless,
            "server" => DeviceType::Server,
            _ => DeviceType::Desktop,
        }
    }

    /// A freedesktop icon name suitable for this device type.
    pub fn icon_name(self) -> &'static str {
        match self {
            DeviceType::Mobile => "phone-symbolic",
            DeviceType::Desktop => "computer-symbolic",
            DeviceType::Web => "web-browser-symbolic",
            DeviceType::Headless => "utilities-terminal-symbolic",
            DeviceType::Server => "network-server-symbolic",
        }
    }
}

impl<'de> Deserialize<'de> for DeviceType {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let s = Option::<String>::deserialize(d)?;
        Ok(s.map(|s| DeviceType::parse(&s)).unwrap_or_default())
    }
}

/// `null` → `T::default()`.
fn null_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

/// Port: missing / `null` / out-of-range / string → parsed or 53317.
fn lenient_port<'de, D: Deserializer<'de>>(d: D) -> Result<u16, D::Error> {
    let v = Option::<serde_json::Value>::deserialize(d)?;
    let port = match v {
        Some(serde_json::Value::Number(n)) => n.as_u64().and_then(|p| u16::try_from(p).ok()),
        Some(serde_json::Value::String(s)) => s.trim().parse().ok(),
        _ => None,
    };
    Ok(port.filter(|p| *p != 0).unwrap_or(DEFAULT_PORT))
}

/// Size: number (or numeric string); anything else → 0.
fn lenient_u64<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(match v {
        Some(serde_json::Value::Number(n)) => n
            .as_u64()
            .or_else(|| n.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
            .unwrap_or(0),
        Some(serde_json::Value::String(s)) => s.trim().parse().unwrap_or(0),
        _ => 0,
    })
}

fn lenient_bool<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(match v {
        Some(serde_json::Value::Bool(b)) => b,
        Some(serde_json::Value::String(s)) => s.eq_ignore_ascii_case("true"),
        Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0) != 0,
        _ => false,
    })
}

fn default_version() -> String {
    PROTOCOL_VERSION.to_string()
}
fn default_port() -> u16 {
    DEFAULT_PORT
}
fn default_alias() -> String {
    "Unknown".to_string()
}
fn default_file_type() -> String {
    "application/octet-stream".to_string()
}

fn opt_device_type<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DeviceType>, D::Error> {
    let s = Option::<serde_json::Value>::deserialize(d)?;
    Ok(match s {
        Some(serde_json::Value::String(s)) => Some(DeviceType::parse(&s)),
        _ => None,
    })
}

fn opt_string<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(match v {
        Some(serde_json::Value::String(s)) => Some(s),
        Some(serde_json::Value::Null) | None => None,
        Some(other) => Some(other.to_string()),
    })
}

fn string_or_default<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(opt_string(d)?.unwrap_or_default())
}

/// `DeviceInfo` — announce, register, prepare-upload `info`, info.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    #[serde(default = "default_alias", deserialize_with = "alias_de")]
    pub alias: String,
    #[serde(default = "default_version", deserialize_with = "version_de")]
    pub version: String,
    #[serde(default, deserialize_with = "opt_string")]
    pub device_model: Option<String>,
    #[serde(default, deserialize_with = "opt_device_type")]
    pub device_type: Option<DeviceType>,
    #[serde(default, deserialize_with = "string_or_default")]
    pub fingerprint: String,
    #[serde(default = "default_port", deserialize_with = "lenient_port")]
    pub port: u16,
    #[serde(default, deserialize_with = "null_default")]
    pub protocol: Protocol,
    #[serde(default, deserialize_with = "lenient_bool")]
    pub download: bool,
}

fn alias_de<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(opt_string(d)?.filter(|s| !s.trim().is_empty()).unwrap_or_else(default_alias))
}
fn version_de<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(opt_string(d)?.unwrap_or_else(default_version))
}

impl DeviceInfo {
    /// Device type with the protocol-mandated fallback to `desktop`.
    pub fn device_type_or_default(&self) -> DeviceType {
        self.device_type.unwrap_or_default()
    }
}

/// A multicast packet: `DeviceInfo` + `announce` (+ legacy `announcement`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MulticastDto {
    pub info: DeviceInfo,
    pub announce: bool,
}

impl MulticastDto {
    pub fn to_json(&self) -> Vec<u8> {
        #[derive(Serialize)]
        struct Out<'a> {
            #[serde(flatten)]
            info: &'a DeviceInfo,
            announce: bool,
            announcement: bool,
        }
        serde_json::to_vec(&Out { info: &self.info, announce: self.announce, announcement: self.announce })
            .expect("serialisable")
    }

    pub fn parse(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        let value: serde_json::Value = serde_json::from_slice(bytes)?;
        let announce = |k: &str| match value.get(k) {
            Some(serde_json::Value::Bool(b)) => Some(*b),
            _ => None,
        };
        let announce = announce("announce").or_else(|| announce("announcement")).unwrap_or(false);
        let info: DeviceInfo = serde_json::from_value(value)?;
        Ok(MulticastDto { info, announce })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FileMetadata {
    #[serde(default, deserialize_with = "opt_string")]
    pub modified: Option<String>,
    #[serde(default, deserialize_with = "opt_string")]
    pub accessed: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDto {
    #[serde(default, deserialize_with = "string_or_default")]
    pub id: String,
    #[serde(default, deserialize_with = "string_or_default")]
    pub file_name: String,
    #[serde(default, deserialize_with = "lenient_u64")]
    pub size: u64,
    #[serde(default = "default_file_type", deserialize_with = "file_type_de")]
    pub file_type: String,
    #[serde(default, deserialize_with = "opt_string")]
    pub sha256: Option<String>,
    #[serde(default, deserialize_with = "opt_string")]
    pub preview: Option<String>,
    #[serde(default, deserialize_with = "opt_metadata")]
    pub metadata: Option<FileMetadata>,
}

fn file_type_de<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(opt_string(d)?.filter(|s| !s.is_empty()).unwrap_or_else(default_file_type))
}

fn opt_metadata<'de, D: Deserializer<'de>>(d: D) -> Result<Option<FileMetadata>, D::Error> {
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(match v {
        Some(v @ serde_json::Value::Object(_)) => serde_json::from_value(v).ok(),
        _ => None,
    })
}

impl FileDto {
    pub fn is_text_message(&self) -> bool {
        self.file_type.starts_with("text/") && self.preview.is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrepareUploadRequest {
    pub info: DeviceInfo,
    #[serde(default)]
    pub files: BTreeMap<String, FileDto>,
}

impl PrepareUploadRequest {
    /// Parse leniently and fill missing file ids from the map keys.
    pub fn parse(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        let mut req: PrepareUploadRequest = serde_json::from_slice(bytes)?;
        for (key, f) in req.files.iter_mut() {
            if f.id.is_empty() {
                f.id = key.clone();
            }
        }
        Ok(req)
    }

    /// True when this request is a text message (every file is `text/*` with a preview).
    pub fn is_text_message(&self) -> bool {
        !self.files.is_empty() && self.files.values().all(FileDto::is_text_message)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponse {
    pub session_id: String,
    #[serde(default)]
    pub files: BTreeMap<String, String>,
}

/// Our own `DeviceInfo`, shared between server, discovery and client so alias/port
/// changes propagate without restarts.
pub type SharedInfo = std::sync::Arc<std::sync::RwLock<DeviceInfo>>;
