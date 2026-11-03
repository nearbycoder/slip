//! Sender side: register/info, prepare-upload, ≤3 parallel streamed uploads with
//! progress, cancel, PIN handling.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::stream::{self, StreamExt};
use reqwest::StatusCode;
use tokio_util::io::ReaderStream;
use tokio_util::sync::CancellationToken;

use crate::model::{DeviceInfo, FileDto, FileMetadata, PrepareUploadRequest, PrepareUploadResponse, Protocol, SharedInfo};
use crate::API_PREFIX;

/// Where to send: host (IP or name), port, protocol.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub host: String,
    pub port: u16,
    pub protocol: Protocol,
}

impl Target {
    /// Parse `host[:port]` (port defaults to 53317).
    pub fn parse(s: &str, protocol: Protocol) -> Option<Target> {
        let s = s.trim();
        let s = s.strip_prefix("https://").or_else(|| s.strip_prefix("http://")).unwrap_or(s);
        let s = s.trim_end_matches('/');
        if s.is_empty() {
            return None;
        }
        let (host, port) = match s.rsplit_once(':') {
            Some((h, p)) if !h.contains(':') || h.starts_with('[') => (h.trim_matches(['[', ']']).to_string(), p.parse().ok()?),
            _ => (s.to_string(), crate::DEFAULT_PORT),
        };
        Some(Target { host, port, protocol })
    }

    pub fn url(&self, path: &str) -> String {
        let host = if self.host.contains(':') { format!("[{}]", self.host) } else { self.host.clone() };
        format!("{}://{}:{}{}{}", self.protocol, host, self.port, API_PREFIX, path)
    }
}

/// Something to send.
#[derive(Debug, Clone)]
pub enum SendItem {
    /// A file on disk; `name` is the `fileName` to advertise (may contain `/`).
    File { path: PathBuf, name: String, size: u64, metadata: Option<FileMetadata> },
    /// A text message.
    Text(String),
}

impl SendItem {
    pub fn display_name(&self) -> String {
        match self {
            SendItem::File { name, .. } => name.clone(),
            SendItem::Text(t) => {
                let one_line: String = t.chars().take(40).map(|c| if c.is_control() { ' ' } else { c }).collect();
                format!("“{one_line}”")
            }
        }
    }

    pub fn size(&self) -> u64 {
        match self {
            SendItem::File { size, .. } => *size,
            SendItem::Text(t) => t.len() as u64,
        }
    }
}

fn rfc3339(t: std::io::Result<std::time::SystemTime>) -> Option<String> {
    let t = t.ok()?;
    let dt: chrono::DateTime<chrono::Utc> = t.into();
    Some(dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

fn file_item(path: &Path, name: String) -> std::io::Result<SendItem> {
    let md = std::fs::metadata(path)?;
    let metadata = Some(FileMetadata { modified: rfc3339(md.modified()), accessed: rfc3339(md.accessed()) });
    Ok(SendItem::File { path: path.to_path_buf(), name, size: md.len(), metadata })
}

/// Expand files and folders into send items. A folder `Photos` yields entries named
/// `Photos/2024/a.jpg`. Hidden files inside folders are included; symlinks are followed
/// for files but not for directories.
pub fn collect_items<P: AsRef<Path>>(paths: &[P]) -> std::io::Result<Vec<SendItem>> {
    let mut out = Vec::new();
    for p in paths {
        let p = p.as_ref();
        let md = std::fs::metadata(p)?;
        let base = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
        if md.is_dir() {
            walk_dir(p, &base, &mut out)?;
        } else {
            out.push(file_item(p, base)?);
        }
    }
    Ok(out)
}

fn walk_dir(dir: &Path, rel: &str, out: &mut Vec<SendItem>) -> std::io::Result<()> {
    let mut entries: Vec<_> = std::fs::read_dir(dir)?.filter_map(Result::ok).collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let name = e.file_name().to_string_lossy().into_owned();
        let child_rel = format!("{rel}/{name}");
        let ft = e.file_type()?;
        if ft.is_dir() {
            walk_dir(&e.path(), &child_rel, out)?;
        } else if ft.is_file() || ft.is_symlink() {
            let path = e.path();
            if std::fs::metadata(&path).map(|m| m.is_file()).unwrap_or(false) {
                out.push(file_item(&path, child_rel)?);
            }
        }
    }
    Ok(())
}

#[derive(Debug, thiserror::Error)]
pub enum SendError {
    /// 401: the receiver needs a PIN (`had_pin` = one was sent and was wrong).
    #[error("{}", if *had_pin { "Invalid PIN" } else { "PIN required" })]
    PinRequired { had_pin: bool },
    #[error("Declined by receiver")]
    Declined,
    #[error("Receiver is busy")]
    Busy,
    #[error("Too many requests")]
    TooManyRequests,
    #[error("Cancelled")]
    Cancelled,
    #[error("Receiver responded with HTTP {0}")]
    Status(u16),
    #[error("Network error: {0}")]
    Network(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Invalid response: {0}")]
    InvalidResponse(String),
    #[error("Nothing to send")]
    Empty,
}

impl From<reqwest::Error> for SendError {
    fn from(e: reqwest::Error) -> Self {
        SendError::Network(error_chain(&e))
    }
}

fn error_chain(e: &dyn std::error::Error) -> String {
    let mut s = e.to_string();
    let mut src = e.source();
    while let Some(inner) = src {
        let t = inner.to_string();
        if !s.contains(&t) {
            s.push_str(": ");
            s.push_str(&t);
        }
        src = inner.source();
    }
    s
}

/// Progress/state events for one send.
#[derive(Debug, Clone)]
pub enum SendEvent {
    /// Waiting for the receiver to accept.
    Waiting,
    /// Receiver accepted these files (id, name, size).
    Accepted { session_id: String, files: Vec<(String, String, u64)> },
    Progress { file_id: String, sent: u64, total: u64 },
    FileDone { file_id: String },
    FileFailed { file_id: String, error: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendOutcome {
    /// Text message delivered (receiver answered 204).
    Delivered,
    /// Files uploaded.
    Completed { sent: usize, failed: usize, skipped: usize },
}

pub type ProgressFn = Arc<dyn Fn(SendEvent) + Send + Sync>;

#[derive(Clone)]
pub struct SlipClient {
    control: reqwest::Client,
    scan: reqwest::Client,
    transfer: reqwest::Client,
    info: SharedInfo,
}

impl SlipClient {
    pub fn new(info: SharedInfo) -> Self {
        SlipClient {
            control: crate::tls::control_client(Duration::from_secs(4)),
            scan: crate::tls::control_client(Duration::from_secs(1)),
            transfer: crate::tls::transfer_client(),
            info,
        }
    }

    pub fn device_info(&self) -> DeviceInfo {
        self.info.read().unwrap().clone()
    }

    /// `POST /register` with our info; returns the peer's info.
    pub async fn register(&self, target: &Target) -> Result<DeviceInfo, SendError> {
        self.register_inner(&self.control, target).await
    }

    pub async fn register_with_timeout(&self, target: &Target, timeout: Duration) -> Result<DeviceInfo, SendError> {
        if timeout <= Duration::from_secs(1) {
            self.register_inner(&self.scan, target).await
        } else {
            self.register_inner(&self.control, target).await
        }
    }

    async fn register_inner(&self, client: &reqwest::Client, target: &Target) -> Result<DeviceInfo, SendError> {
        let resp = client.post(target.url("/register")).json(&self.device_info()).send().await?;
        if !resp.status().is_success() {
            return Err(SendError::Status(resp.status().as_u16()));
        }
        let bytes = resp.bytes().await?;
        serde_json::from_slice(&bytes).map_err(|e| SendError::InvalidResponse(e.to_string()))
    }

    /// `GET /info`.
    pub async fn info(&self, target: &Target) -> Result<DeviceInfo, SendError> {
        let resp = self.control.get(target.url("/info")).send().await?;
        if !resp.status().is_success() {
            return Err(SendError::Status(resp.status().as_u16()));
        }
        let bytes = resp.bytes().await?;
        serde_json::from_slice(&bytes).map_err(|e| SendError::InvalidResponse(e.to_string()))
    }

    /// `POST /cancel?sessionId=`.
    pub async fn cancel(&self, target: &Target, session_id: &str) -> Result<(), SendError> {
        self.control.post(target.url("/cancel")).query(&[("sessionId", session_id)]).send().await?;
        Ok(())
    }

    /// Send items to `target`. Text items must be sent on their own.
    pub async fn send(
        &self,
        target: &Target,
        items: &[SendItem],
        pin: Option<&str>,
        progress: ProgressFn,
        cancel: CancellationToken,
    ) -> Result<SendOutcome, SendError> {
        if items.is_empty() {
            return Err(SendError::Empty);
        }
        // Build the file map.
        let mut files = BTreeMap::new();
        let mut by_id: BTreeMap<String, &SendItem> = BTreeMap::new();
        for item in items {
            let id = uuid::Uuid::new_v4().to_string();
            let dto = match item {
                SendItem::File { name, size, metadata, path } => FileDto {
                    id: id.clone(),
                    file_name: name.clone(),
                    size: *size,
                    file_type: mime_guess::from_path(path).first_or_octet_stream().essence_str().to_string(),
                    sha256: None,
                    preview: None,
                    metadata: metadata.clone(),
                },
                SendItem::Text(text) => FileDto {
                    id: id.clone(),
                    file_name: format!("{id}.txt"),
                    size: text.len() as u64,
                    file_type: "text/plain".into(),
                    sha256: Some(crate::identity::sha256_hex(text.as_bytes())),
                    preview: Some(text.clone()),
                    metadata: None,
                },
            };
            files.insert(id.clone(), dto);
            by_id.insert(id, item);
        }
        let body = PrepareUploadRequest { info: self.device_info(), files: files.clone() };

        progress(SendEvent::Waiting);
        let mut req = self.transfer.post(target.url("/prepare-upload")).json(&body);
        if let Some(pin) = pin {
            req = req.query(&[("pin", pin)]);
        }
        let resp = tokio::select! {
            _ = cancel.cancelled() => return Err(SendError::Cancelled),
            r = tokio::time::timeout(Duration::from_secs(180), req.send()) => match r {
                Ok(r) => r?,
                Err(_) => return Err(SendError::Network("timed out waiting for the receiver".into())),
            },
        };
        let status = resp.status();
        match status {
            StatusCode::OK => {}
            StatusCode::NO_CONTENT => return Ok(SendOutcome::Delivered),
            StatusCode::UNAUTHORIZED => return Err(SendError::PinRequired { had_pin: pin.is_some() }),
            StatusCode::FORBIDDEN => return Err(SendError::Declined),
            StatusCode::CONFLICT => return Err(SendError::Busy),
            StatusCode::TOO_MANY_REQUESTS => return Err(SendError::TooManyRequests),
            s => return Err(SendError::Status(s.as_u16())),
        }
        let bytes = resp.bytes().await?;
        let accepted: PrepareUploadResponse =
            serde_json::from_slice(&bytes).map_err(|e| SendError::InvalidResponse(e.to_string()))?;

        let jobs: Vec<(String, String, SendItem)> = accepted
            .files
            .iter()
            .filter_map(|(id, token)| by_id.get(id).map(|item| (id.clone(), token.clone(), (*item).clone())))
            .collect();
        let skipped = items.len() - jobs.len();
        progress(SendEvent::Accepted {
            session_id: accepted.session_id.clone(),
            files: jobs.iter().map(|(id, _, item)| (id.clone(), files[id].file_name.clone(), item.size())).collect(),
        });

        let session_id = accepted.session_id.clone();
        let uploads = stream::iter(jobs.into_iter())
            .map(|(id, token, item): (String, String, SendItem)| {
                let progress = progress.clone();
                let session_id = session_id.clone();
                let client = self.clone();
                let target = target.clone();
                async move {
                    let r = client.upload_one(&target, &session_id, &id, &token, &item, progress.clone()).await;
                    match &r {
                        Ok(()) => progress(SendEvent::FileDone { file_id: id.clone() }),
                        Err(e) => progress(SendEvent::FileFailed { file_id: id.clone(), error: e.to_string() }),
                    }
                    r.is_ok()
                }
            })
            .buffer_unordered(3)
            .collect::<Vec<bool>>();

        let results = tokio::select! {
            _ = cancel.cancelled() => {
                let _ = self.cancel(target, &session_id).await;
                return Err(SendError::Cancelled);
            }
            r = uploads => r,
        };
        let sent = results.iter().filter(|ok| **ok).count();
        Ok(SendOutcome::Completed { sent, failed: results.len() - sent, skipped })
    }

    async fn upload_one(
        &self,
        target: &Target,
        session_id: &str,
        file_id: &str,
        token: &str,
        item: &SendItem,
        progress: ProgressFn,
    ) -> Result<(), SendError> {
        let total = item.size();
        let sent = Arc::new(AtomicU64::new(0));
        let body = match item {
            SendItem::Text(t) => reqwest::Body::from(t.clone().into_bytes()),
            SendItem::File { path, .. } => {
                let file = tokio::fs::File::open(path).await?;
                let sent = sent.clone();
                let fid = file_id.to_string();
                let progress = progress.clone();
                let mut last = Instant::now() - Duration::from_secs(1);
                let stream = ReaderStream::with_capacity(file, 256 * 1024).map(move |chunk| {
                    if let Ok(c) = &chunk {
                        let n = sent.fetch_add(c.len() as u64, Ordering::Relaxed) + c.len() as u64;
                        if last.elapsed() >= Duration::from_millis(100) || n >= total {
                            last = Instant::now();
                            progress(SendEvent::Progress { file_id: fid.clone(), sent: n, total });
                        }
                    }
                    chunk
                });
                reqwest::Body::wrap_stream(stream)
            }
        };
        let resp = self
            .transfer
            .post(target.url("/upload"))
            .query(&[("sessionId", session_id), ("fileId", file_id), ("token", token)])
            .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
            .header(reqwest::header::CONTENT_LENGTH, total)
            .body(body)
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(SendError::Status(resp.status().as_u16()));
        }
        progress(SendEvent::Progress { file_id: file_id.to_string(), sent: total, total });
        Ok(())
    }
}
