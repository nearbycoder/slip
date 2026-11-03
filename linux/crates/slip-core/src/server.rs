//! HTTPS/HTTP receive server: info, register, prepare-upload (held open for the user's
//! decision), upload (streamed to disk), cancel.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use axum::body::{Body, Bytes};
use axum::extract::{ConnectInfo, DefaultBodyLimit, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use crate::events::{Decision, Event, IncomingRequest};
use crate::identity::Identity;
use crate::model::{DeviceInfo, FileDto, PrepareUploadRequest, PrepareUploadResponse, Protocol, SharedInfo};
use crate::paths;
use crate::peers::PeerStore;

/// How long prepare-upload waits for the user before answering 403.
pub const DECISION_TIMEOUT: Duration = Duration::from_secs(60);
/// An accepted session with no upload activity for this long is considered abandoned.
pub const STALE_SESSION: Duration = Duration::from_secs(120);

/// Receive-side settings that can change while the server runs.
#[derive(Debug, Clone)]
pub struct ReceiveSettings {
    pub save_dir: PathBuf,
    pub pin: Option<String>,
    pub auto_accept: bool,
}

pub type SharedReceive = Arc<RwLock<ReceiveSettings>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FileState {
    Pending,
    InProgress,
    Done,
    Failed,
}

#[derive(Debug)]
struct SessionFile {
    dto: FileDto,
    token: String,
    state: FileState,
}

#[derive(Debug)]
struct Session {
    id: String,
    sender_ip: IpAddr,
    #[allow(dead_code)]
    sender: DeviceInfo,
    files: HashMap<String, SessionFile>,
    cancel: CancellationToken,
    last_activity: Instant,
}

impl Session {
    fn is_finished(&self) -> bool {
        self.files.values().all(|f| matches!(f.state, FileState::Done | FileState::Failed))
    }
    fn has_active_upload(&self) -> bool {
        self.files.values().any(|f| f.state == FileState::InProgress)
    }
}

#[derive(Debug, Default)]
enum Slot {
    #[default]
    Idle,
    /// A prepare-upload is awaiting the user's decision.
    Pending { request_id: u64 },
    Active(Session),
}

struct AppState {
    info: SharedInfo,
    receive: SharedReceive,
    peers: PeerStore,
    events: async_channel::Sender<Event>,
    slot: Mutex<Slot>,
    next_request: AtomicU64,
    /// Serialises final-name allocation + rename so parallel uploads never collide.
    finalize: tokio::sync::Mutex<()>,
}

impl AppState {
    fn emit(&self, ev: Event) {
        let _ = self.events.try_send(ev);
    }
}

pub struct ServerOptions {
    pub bind: IpAddr,
    /// 0 = pick a free port.
    pub port: u16,
    pub protocol: Protocol,
}

/// A running server. Dropping it shuts it down.
pub struct Server {
    handle: axum_server::Handle,
    local_addr: SocketAddr,
    state: Arc<AppState>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.handle.shutdown();
        self.task.abort();
        if let Ok(mut slot) = self.state.slot.lock() {
            if let Slot::Active(s) = std::mem::take(&mut *slot) {
                s.cancel.cancel();
            }
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ServerError {
    #[error("could not bind port {port}: {source}")]
    Bind { port: u16, source: std::io::Error },
    #[error("TLS setup failed: {0}")]
    Tls(#[from] crate::identity::IdentityError),
    #[error("i/o: {0}")]
    Io(#[from] std::io::Error),
}

impl Server {
    /// Bind and start serving. `info.port`/`info.protocol` are updated to match.
    pub async fn start(
        opts: ServerOptions,
        identity: &Identity,
        info: SharedInfo,
        receive: SharedReceive,
        peers: PeerStore,
        events: async_channel::Sender<Event>,
    ) -> Result<Server, ServerError> {
        let listener = std::net::TcpListener::bind(SocketAddr::new(opts.bind, opts.port))
            .map_err(|source| ServerError::Bind { port: opts.port, source })?;
        listener.set_nonblocking(true)?;
        let local_addr = listener.local_addr()?;
        {
            let mut i = info.write().unwrap();
            i.port = local_addr.port();
            i.protocol = opts.protocol;
            i.fingerprint = identity.fingerprint(opts.protocol).to_string();
        }
        let state = Arc::new(AppState {
            info,
            receive,
            peers,
            events,
            slot: Mutex::new(Slot::Idle),
            next_request: AtomicU64::new(1),
            finalize: tokio::sync::Mutex::new(()),
        });
        let app = router(state.clone()).into_make_service_with_connect_info::<SocketAddr>();
        let handle = axum_server::Handle::new();
        let task = match opts.protocol {
            Protocol::Https => {
                let cfg = axum_server::tls_rustls::RustlsConfig::from_config(crate::tls::server_config(identity)?);
                let server = axum_server::from_tcp_rustls(listener, cfg).handle(handle.clone());
                tokio::spawn(async move {
                    if let Err(e) = server.serve(app).await {
                        tracing::error!("server stopped: {e}");
                    }
                })
            }
            Protocol::Http => {
                let server = axum_server::from_tcp(listener).handle(handle.clone());
                tokio::spawn(async move {
                    if let Err(e) = server.serve(app).await {
                        tracing::error!("server stopped: {e}");
                    }
                })
            }
        };
        Ok(Server { handle, local_addr, state, task })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn port(&self) -> u16 {
        self.local_addr.port()
    }

    /// Cancel the active receive session (user pressed cancel), removing partial files.
    pub fn cancel_session(&self) -> bool {
        let mut slot = self.state.slot.lock().unwrap();
        if let Slot::Active(s) = std::mem::take(&mut *slot) {
            s.cancel.cancel();
            self.state.emit(Event::ReceiveFinished { session_id: s.id, cancelled: true });
            true
        } else {
            *slot = Slot::Idle;
            false
        }
    }

    pub fn is_busy(&self) -> bool {
        !matches!(*self.state.slot.lock().unwrap(), Slot::Idle)
    }
}

fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/api/localsend/v2/info", get(info))
        .route("/api/localsend/v2/register", post(register))
        .route("/api/localsend/v2/prepare-upload", post(prepare_upload))
        .route("/api/localsend/v2/upload", post(upload))
        .route("/api/localsend/v2/cancel", post(cancel))
        .fallback(|| async { status_msg(StatusCode::NOT_FOUND, "Not found") })
        .layer(DefaultBodyLimit::max(64 * 1024 * 1024))
        .with_state(state)
}

fn status_msg(code: StatusCode, message: &str) -> Response {
    (code, Json(serde_json::json!({ "message": message }))).into_response()
}

async fn info(State(st): State<Arc<AppState>>) -> Json<DeviceInfo> {
    Json(st.info.read().unwrap().clone())
}

async fn register(
    State(st): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    body: Bytes,
) -> Response {
    let Ok(peer) = serde_json::from_slice::<DeviceInfo>(&body) else {
        return status_msg(StatusCode::BAD_REQUEST, "Invalid body");
    };
    st.peers.upsert(peer, canonical_ip(addr.ip()));
    Json(st.info.read().unwrap().clone()).into_response()
}

fn canonical_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    }
}

/// Resets a `Pending` slot if the handler is dropped (sender disconnected) or exits
/// without committing a session.
struct PendingGuard<'a> {
    st: &'a AppState,
    request_id: u64,
    armed: bool,
}

impl Drop for PendingGuard<'_> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let mut slot = self.st.slot.lock().unwrap();
        if matches!(*slot, Slot::Pending { request_id } if request_id == self.request_id) {
            *slot = Slot::Idle;
        }
        drop(slot);
        self.st.emit(Event::IncomingRequestClosed { id: self.request_id });
    }
}

#[derive(serde::Deserialize)]
struct PinQuery {
    pin: Option<String>,
}

async fn prepare_upload(
    State(st): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(q): Query<PinQuery>,
    body: Bytes,
) -> Response {
    let ip = canonical_ip(addr.ip());
    let settings = st.receive.read().unwrap().clone();
    if let Some(pin) = &settings.pin {
        if q.pin.as_deref() != Some(pin.as_str()) {
            return status_msg(StatusCode::UNAUTHORIZED, "PIN required");
        }
    }
    let req = match PrepareUploadRequest::parse(&body) {
        Ok(r) if !r.files.is_empty() => r,
        _ => return status_msg(StatusCode::BAD_REQUEST, "Invalid body"),
    };

    let request_id = st.next_request.fetch_add(1, Ordering::Relaxed);
    {
        let mut slot = st.slot.lock().unwrap();
        match &*slot {
            Slot::Idle => {}
            Slot::Active(s) if !s.has_active_upload() && s.last_activity.elapsed() > STALE_SESSION => {
                // Abandoned session: drop it.
                s.cancel.cancel();
                st.emit(Event::ReceiveFinished { session_id: s.id.clone(), cancelled: true });
            }
            _ => return status_msg(StatusCode::CONFLICT, "Blocked by another session"),
        }
        *slot = Slot::Pending { request_id };
    }
    let mut guard = PendingGuard { st: &st, request_id, armed: true };

    // Remember the sender as a peer (it told us its port/protocol).
    st.peers.upsert(req.info.clone(), ip);

    if req.is_text_message() {
        let text = req.files.values().filter_map(|f| f.preview.clone()).collect::<Vec<_>>().join("\n");
        guard.armed = false;
        *st.slot.lock().unwrap() = Slot::Idle;
        st.emit(Event::TextReceived { sender: req.info.clone(), text });
        return StatusCode::NO_CONTENT.into_response();
    }

    let files: Vec<FileDto> = req.files.values().cloned().collect();
    let decision = if settings.auto_accept {
        Decision::Accept(None)
    } else {
        let (tx, rx) = oneshot::channel();
        let incoming = Arc::new(IncomingRequest {
            id: request_id,
            sender: req.info.clone(),
            sender_ip: ip,
            files: files.clone(),
            responder: Mutex::new(Some(tx)),
        });
        st.emit(Event::IncomingRequest(incoming));
        match tokio::time::timeout(DECISION_TIMEOUT, rx).await {
            Ok(Ok(d)) => d,
            _ => Decision::Decline,
        }
    };

    let selected: Vec<FileDto> = match decision {
        Decision::Decline => return status_msg(StatusCode::FORBIDDEN, "Rejected"),
        Decision::Accept(None) => files,
        Decision::Accept(Some(ids)) => files.into_iter().filter(|f| ids.contains(&f.id)).collect(),
    };
    if selected.is_empty() {
        return status_msg(StatusCode::FORBIDDEN, "Rejected");
    }

    let session_id = uuid::Uuid::new_v4().to_string();
    let mut tokens = std::collections::BTreeMap::new();
    let mut session_files = HashMap::new();
    for f in &selected {
        let token = uuid::Uuid::new_v4().simple().to_string();
        tokens.insert(f.id.clone(), token.clone());
        session_files.insert(f.id.clone(), SessionFile { dto: f.clone(), token, state: FileState::Pending });
    }
    {
        let mut slot = st.slot.lock().unwrap();
        if !matches!(*slot, Slot::Pending { request_id: r } if r == request_id) {
            return status_msg(StatusCode::CONFLICT, "Blocked by another session");
        }
        *slot = Slot::Active(Session {
            id: session_id.clone(),
            sender_ip: ip,
            sender: req.info.clone(),
            files: session_files,
            cancel: CancellationToken::new(),
            last_activity: Instant::now(),
        });
    }
    guard.armed = false;
    st.emit(Event::IncomingRequestClosed { id: request_id });
    st.emit(Event::ReceiveStarted {
        session_id: session_id.clone(),
        sender: req.info.clone(),
        files: selected,
        save_dir: settings.save_dir.clone(),
    });
    Json(PrepareUploadResponse { session_id, files: tokens }).into_response()
}

#[derive(serde::Deserialize)]
struct UploadQuery {
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    #[serde(rename = "fileId")]
    file_id: Option<String>,
    token: Option<String>,
}

async fn upload(
    State(st): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(q): Query<UploadQuery>,
    body: Body,
) -> Response {
    let (Some(session_id), Some(file_id), Some(token)) = (q.session_id, q.file_id, q.token) else {
        return status_msg(StatusCode::BAD_REQUEST, "Missing parameters");
    };
    let ip = canonical_ip(addr.ip());
    let (dto, cancel) = {
        let mut slot = st.slot.lock().unwrap();
        let Slot::Active(s) = &mut *slot else {
            return status_msg(StatusCode::FORBIDDEN, "Invalid session");
        };
        if s.id != session_id {
            return status_msg(StatusCode::FORBIDDEN, "Invalid session");
        }
        if s.sender_ip != ip {
            return status_msg(StatusCode::FORBIDDEN, "Invalid IP address");
        }
        let Some(f) = s.files.get_mut(&file_id) else {
            return status_msg(StatusCode::FORBIDDEN, "Invalid file");
        };
        if f.token != token {
            return status_msg(StatusCode::FORBIDDEN, "Invalid token");
        }
        if matches!(f.state, FileState::InProgress | FileState::Done) {
            return status_msg(StatusCode::CONFLICT, "File already uploaded");
        }
        f.state = FileState::InProgress;
        s.last_activity = Instant::now();
        (f.dto.clone(), s.cancel.clone())
    };
    let save_dir = st.receive.read().unwrap().save_dir.clone();

    let result = receive_file(&st, &session_id, &dto, &save_dir, body, &cancel).await;
    let (code, state) = match &result {
        Ok(path) => {
            st.emit(Event::ReceiveFileDone { session_id: session_id.clone(), file_id: file_id.clone(), path: path.clone() });
            (StatusCode::OK, FileState::Done)
        }
        Err(e) => {
            st.emit(Event::ReceiveFileFailed { session_id: session_id.clone(), file_id: file_id.clone(), error: e.message() });
            (e.status(), FileState::Failed)
        }
    };

    // Update session; end it when every file is done/failed.
    {
        let mut slot = st.slot.lock().unwrap();
        if let Slot::Active(s) = &mut *slot {
            if s.id == session_id {
                if let Some(f) = s.files.get_mut(&file_id) {
                    f.state = state;
                }
                s.last_activity = Instant::now();
                if s.is_finished() {
                    let id = s.id.clone();
                    *slot = Slot::Idle;
                    st.emit(Event::ReceiveFinished { session_id: id, cancelled: false });
                }
            }
        }
    }
    if code == StatusCode::OK {
        StatusCode::OK.into_response()
    } else {
        status_msg(code, &result.err().map(|e| e.message()).unwrap_or_default())
    }
}

enum RecvError {
    Cancelled,
    Checksum,
    Io(std::io::Error),
    Body(String),
}

impl RecvError {
    fn status(&self) -> StatusCode {
        match self {
            RecvError::Cancelled => StatusCode::CONFLICT,
            RecvError::Checksum => StatusCode::UNPROCESSABLE_ENTITY,
            RecvError::Io(_) => StatusCode::INTERNAL_SERVER_ERROR,
            RecvError::Body(_) => StatusCode::BAD_REQUEST,
        }
    }
    fn message(&self) -> String {
        match self {
            RecvError::Cancelled => "Cancelled".into(),
            RecvError::Checksum => "Checksum mismatch (sha256)".into(),
            RecvError::Io(e) => format!("I/O error: {e}"),
            RecvError::Body(e) => format!("Transfer interrupted: {e}"),
        }
    }
}

/// Removes the partial file unless disarmed.
struct PartialGuard(Option<PathBuf>);
impl Drop for PartialGuard {
    fn drop(&mut self) {
        if let Some(p) = self.0.take() {
            let _ = std::fs::remove_file(p);
        }
    }
}

async fn receive_file(
    st: &AppState,
    session_id: &str,
    dto: &FileDto,
    save_dir: &Path,
    body: Body,
    cancel: &CancellationToken,
) -> Result<PathBuf, RecvError> {
    tokio::fs::create_dir_all(save_dir).await.map_err(RecvError::Io)?;
    let partial = save_dir.join(format!(".slip-partial-{}", uuid::Uuid::new_v4().simple()));
    let mut guard = PartialGuard(Some(partial.clone()));
    let mut file = tokio::fs::File::create(&partial).await.map_err(RecvError::Io)?;
    let mut hasher = dto.sha256.as_ref().map(|_| Sha256::new());
    let mut stream = body.into_data_stream();
    let mut received: u64 = 0;
    let mut last_emit = Instant::now() - Duration::from_secs(1);
    let total = dto.size;
    st.emit(Event::ReceiveProgress { session_id: session_id.into(), file_id: dto.id.clone(), received: 0, total });
    loop {
        let chunk = tokio::select! {
            _ = cancel.cancelled() => return Err(RecvError::Cancelled),
            c = stream.next() => c,
        };
        let Some(chunk) = chunk else { break };
        let chunk = chunk.map_err(|e| RecvError::Body(e.to_string()))?;
        if let Some(h) = hasher.as_mut() {
            h.update(&chunk);
        }
        file.write_all(&chunk).await.map_err(RecvError::Io)?;
        received += chunk.len() as u64;
        if last_emit.elapsed() >= Duration::from_millis(100) {
            last_emit = Instant::now();
            st.emit(Event::ReceiveProgress { session_id: session_id.into(), file_id: dto.id.clone(), received, total });
        }
    }
    file.flush().await.map_err(RecvError::Io)?;
    file.sync_all().await.map_err(RecvError::Io)?;
    drop(file);
    if cancel.is_cancelled() {
        return Err(RecvError::Cancelled);
    }
    if let (Some(h), Some(expected)) = (hasher, dto.sha256.as_ref()) {
        let actual = hex::encode(h.finalize());
        if !actual.eq_ignore_ascii_case(expected.trim()) {
            return Err(RecvError::Checksum);
        }
    }
    st.emit(Event::ReceiveProgress { session_id: session_id.into(), file_id: dto.id.clone(), received, total: total.max(received) });

    let _lock = st.finalize.lock().await;
    let dest = paths::destination(save_dir, &dto.file_name);
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(RecvError::Io)?;
    }
    tokio::fs::rename(&partial, &dest).await.map_err(RecvError::Io)?;
    guard.0 = None;
    if let Some(modified) = dto.metadata.as_ref().and_then(|m| m.modified.as_deref()) {
        if let Ok(t) = chrono::DateTime::parse_from_rfc3339(modified) {
            let ft = filetime::FileTime::from_unix_time(t.timestamp(), t.timestamp_subsec_nanos());
            let _ = filetime::set_file_mtime(&dest, ft);
        }
    }
    Ok(dest)
}

#[derive(serde::Deserialize)]
struct CancelQuery {
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
}

async fn cancel(
    State(st): State<Arc<AppState>>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(q): Query<CancelQuery>,
) -> Response {
    let ip = canonical_ip(addr.ip());
    let mut slot = st.slot.lock().unwrap();
    if let Slot::Active(s) = &*slot {
        let matches = match &q.session_id {
            Some(id) => *id == s.id,
            None => s.sender_ip == ip,
        };
        if matches && s.sender_ip == ip {
            s.cancel.cancel();
            let id = s.id.clone();
            *slot = Slot::Idle;
            st.emit(Event::ReceiveFinished { session_id: id, cancelled: true });
        }
    }
    StatusCode::OK.into_response()
}
