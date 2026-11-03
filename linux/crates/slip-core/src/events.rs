//! Events emitted by the core for the UI, and the incoming-transfer decision handle.

use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Mutex;

use tokio::sync::oneshot;

use crate::model::{DeviceInfo, FileDto};
use crate::peers::Peer;

/// The user's answer to an incoming transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Accept. `None` = all files, `Some(ids)` = only these file ids.
    Accept(Option<Vec<String>>),
    Decline,
}

/// An incoming `prepare-upload` awaiting the user's decision. The HTTP request is held
/// open until [`IncomingRequest::respond`] is called (or ~60 s elapse → 403).
#[derive(Debug)]
pub struct IncomingRequest {
    pub id: u64,
    pub sender: DeviceInfo,
    pub sender_ip: IpAddr,
    pub files: Vec<FileDto>,
    pub(crate) responder: Mutex<Option<oneshot::Sender<Decision>>>,
}

impl IncomingRequest {
    pub fn total_size(&self) -> u64 {
        self.files.iter().map(|f| f.size).sum()
    }

    /// Answer the request. Returns `false` if it was already answered or withdrawn.
    pub fn respond(&self, decision: Decision) -> bool {
        match self.responder.lock().unwrap().take() {
            Some(tx) => tx.send(decision).is_ok(),
            None => false,
        }
    }

    pub fn is_pending(&self) -> bool {
        self.responder.lock().unwrap().as_ref().is_some_and(|tx| !tx.is_closed())
    }
}

#[derive(Debug, Clone)]
pub enum Event {
    /// A peer was discovered or refreshed.
    PeerUpdated(Peer),
    /// A peer was not seen for ~60 s.
    PeerLost { fingerprint: String },
    /// A sender wants to transfer files; call `respond` on it.
    IncomingRequest(std::sync::Arc<IncomingRequest>),
    /// A pending incoming request was withdrawn (sender gone / timed out / answered elsewhere).
    IncomingRequestClosed { id: u64 },
    /// A text message arrived (already answered with 204).
    TextReceived { sender: DeviceInfo, text: String },
    /// A receive session was accepted and is waiting for uploads.
    ReceiveStarted { session_id: String, sender: DeviceInfo, files: Vec<FileDto>, save_dir: PathBuf },
    ReceiveProgress { session_id: String, file_id: String, received: u64, total: u64 },
    ReceiveFileDone { session_id: String, file_id: String, path: PathBuf },
    ReceiveFileFailed { session_id: String, file_id: String, error: String },
    /// The session ended (all files finished, or cancelled by either side).
    ReceiveFinished { session_id: String, cancelled: bool },
    /// Non-fatal problem worth surfacing (e.g. multicast unavailable).
    Warning(String),
}
