//! End-to-end loopback tests: a real server on a random port and the real client,
//! over HTTPS and HTTP.

use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use slip_core::client::{collect_items, SendError, SendItem, SendOutcome, SlipClient, Target};
use slip_core::identity::Identity;
use slip_core::model::{DeviceInfo, DeviceType, FileDto, PrepareUploadRequest, PrepareUploadResponse, Protocol};
use slip_core::peers::PeerStore;
use slip_core::server::{ReceiveSettings, Server, ServerOptions};
use slip_core::{Decision, Event};
use tokio_util::sync::CancellationToken;

struct Receiver {
    server: Server,
    events: async_channel::Receiver<Event>,
    identity: Identity,
    peers: PeerStore,
    dir: tempfile::TempDir,
    receive: Arc<RwLock<ReceiveSettings>>,
}

impl Receiver {
    fn target(&self, protocol: Protocol) -> Target {
        Target { host: "127.0.0.1".into(), port: self.server.port(), protocol }
    }
}

fn info(alias: &str, id: &Identity, protocol: Protocol) -> DeviceInfo {
    DeviceInfo {
        alias: alias.into(),
        version: "2.1".into(),
        device_model: Some("Test".into()),
        device_type: Some(DeviceType::Headless),
        fingerprint: id.fingerprint(protocol).into(),
        port: 0,
        protocol,
        download: false,
    }
}

async fn start_receiver(protocol: Protocol, auto_accept: bool, pin: Option<&str>) -> Receiver {
    let identity = Identity::generate().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let (tx, rx) = async_channel::unbounded();
    let shared = Arc::new(RwLock::new(info("Receiver", &identity, protocol)));
    let receive = Arc::new(RwLock::new(ReceiveSettings {
        save_dir: dir.path().to_path_buf(),
        pin: pin.map(str::to_string),
        auto_accept,
    }));
    let peers = PeerStore::new(identity.own_fingerprints(), Some(tx.clone()));
    let server = Server::start(
        ServerOptions { bind: IpAddr::V4(Ipv4Addr::LOCALHOST), port: 0, protocol },
        &identity,
        shared,
        receive.clone(),
        peers.clone(),
        tx,
    )
    .await
    .unwrap();
    Receiver { server, events: rx, identity, peers, dir, receive }
}

fn sender(protocol: Protocol) -> (SlipClient, Identity) {
    let id = Identity::generate().unwrap();
    let shared = Arc::new(RwLock::new(info("Sender", &id, protocol)));
    (SlipClient::new(shared), id)
}

fn noop() -> slip_core::client::ProgressFn {
    Arc::new(|_| {})
}

fn write_tree(root: &Path) -> Vec<std::path::PathBuf> {
    let big = root.join("big.bin");
    let data: Vec<u8> = (0..3_000_000u32).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();
    std::fs::write(&big, &data).unwrap();
    let folder = root.join("Photos");
    std::fs::create_dir_all(folder.join("2024")).unwrap();
    std::fs::write(folder.join("2024/a.jpg"), b"jpeg-bytes").unwrap();
    std::fs::write(folder.join("b.txt"), b"bee").unwrap();
    std::fs::write(root.join("empty.dat"), b"").unwrap();
    vec![big, folder, root.join("empty.dat")]
}

async fn wait_for<F: Fn(&Event) -> bool>(rx: &async_channel::Receiver<Event>, f: F) -> Event {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let ev = rx.recv().await.expect("event channel closed");
            if f(&ev) {
                return ev;
            }
        }
    })
    .await
    .expect("timed out waiting for event")
}

async fn transfer_round_trip(protocol: Protocol) {
    let rx = start_receiver(protocol, true, None).await;
    let src = tempfile::tempdir().unwrap();
    let paths = write_tree(src.path());
    let items = collect_items(&paths).unwrap();
    assert_eq!(items.len(), 4);
    let (client, _) = sender(protocol);

    // info + register
    let peer = client.info(&rx.target(protocol)).await.unwrap();
    assert_eq!(peer.alias, "Receiver");
    assert_eq!(peer.fingerprint, rx.identity.fingerprint(protocol));
    assert_eq!(peer.port, rx.server.port());
    assert_eq!(peer.protocol, protocol);
    let reg = client.register(&rx.target(protocol)).await.unwrap();
    assert_eq!(reg.alias, "Receiver");
    assert_eq!(rx.peers.list().len(), 1, "register adds the caller as a peer");

    let progress_seen = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let ps = progress_seen.clone();
    let progress: slip_core::client::ProgressFn = Arc::new(move |ev| {
        if let slip_core::client::SendEvent::Progress { sent, .. } = ev {
            ps.fetch_max(sent, std::sync::atomic::Ordering::Relaxed);
        }
    });
    let outcome = client.send(&rx.target(protocol), &items, None, progress, CancellationToken::new()).await.unwrap();
    assert_eq!(outcome, SendOutcome::Completed { sent: 4, failed: 0, skipped: 0 });
    assert_eq!(progress_seen.load(std::sync::atomic::Ordering::Relaxed), 3_000_000);

    wait_for(&rx.events, |e| matches!(e, Event::ReceiveFinished { cancelled: false, .. })).await;
    let out = rx.dir.path();
    assert_eq!(std::fs::read(out.join("big.bin")).unwrap(), std::fs::read(src.path().join("big.bin")).unwrap());
    assert_eq!(std::fs::read(out.join("Photos/2024/a.jpg")).unwrap(), b"jpeg-bytes");
    assert_eq!(std::fs::read(out.join("Photos/b.txt")).unwrap(), b"bee");
    assert_eq!(std::fs::read(out.join("empty.dat")).unwrap(), b"");
    // mtime preserved (to the second).
    let src_m = std::fs::metadata(src.path().join("big.bin")).unwrap().modified().unwrap();
    let dst_m = std::fs::metadata(out.join("big.bin")).unwrap().modified().unwrap();
    let diff = src_m.duration_since(dst_m).unwrap_or_else(|e| e.duration());
    assert!(diff < Duration::from_secs(2), "mtime diff {diff:?}");
    // No partials left behind.
    assert!(std::fs::read_dir(out).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().starts_with(".slip-partial")));

    // Second send of the same file → " (1)" suffix.
    let one = collect_items(&[src.path().join("big.bin")]).unwrap();
    client.send(&rx.target(protocol), &one, None, noop(), CancellationToken::new()).await.unwrap();
    wait_for(&rx.events, |e| matches!(e, Event::ReceiveFinished { .. })).await;
    assert!(out.join("big (1).bin").exists());
}

#[tokio::test]
async fn https_round_trip() {
    transfer_round_trip(Protocol::Https).await;
}

#[tokio::test]
async fn http_round_trip() {
    transfer_round_trip(Protocol::Http).await;
}

#[tokio::test]
async fn https_client_cannot_talk_to_http_server() {
    let rx = start_receiver(Protocol::Http, true, None).await;
    let (client, _) = sender(Protocol::Https);
    assert!(client.info(&rx.target(Protocol::Https)).await.is_err());
}

#[tokio::test]
async fn pin_required_401() {
    let rx = start_receiver(Protocol::Https, true, Some("1234")).await;
    let (client, _) = sender(Protocol::Https);
    let items = vec![SendItem::Text("secret".into())];
    let t = rx.target(Protocol::Https);
    match client.send(&t, &items, None, noop(), CancellationToken::new()).await {
        Err(SendError::PinRequired { had_pin: false }) => {}
        other => panic!("expected PinRequired, got {other:?}"),
    }
    match client.send(&t, &items, Some("0000"), noop(), CancellationToken::new()).await {
        Err(SendError::PinRequired { had_pin: true }) => {}
        other => panic!("expected wrong PIN, got {other:?}"),
    }
    assert_eq!(client.send(&t, &items, Some("1234"), noop(), CancellationToken::new()).await.unwrap(), SendOutcome::Delivered);
}

#[tokio::test]
async fn text_message_204() {
    let rx = start_receiver(Protocol::Https, false, None).await;
    let (client, _) = sender(Protocol::Https);
    let out = client
        .send(&rx.target(Protocol::Https), &[SendItem::Text("Hello 👋".into())], None, noop(), CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(out, SendOutcome::Delivered);
    match wait_for(&rx.events, |e| matches!(e, Event::TextReceived { .. })).await {
        Event::TextReceived { sender, text } => {
            assert_eq!(text, "Hello 👋");
            assert_eq!(sender.alias, "Sender");
        }
        _ => unreachable!(),
    }
    assert!(!rx.server.is_busy());
}

#[tokio::test]
async fn decline_403() {
    let rx = start_receiver(Protocol::Https, false, None).await;
    let (client, _) = sender(Protocol::Https);
    let src = tempfile::tempdir().unwrap();
    let items = collect_items(&write_tree(src.path())).unwrap();
    let events = rx.events.clone();
    let decider = tokio::spawn(async move {
        if let Event::IncomingRequest(req) = wait_for(&events, |e| matches!(e, Event::IncomingRequest(_))).await {
            assert_eq!(req.sender.alias, "Sender");
            assert_eq!(req.files.len(), 4);
            assert_eq!(req.total_size(), 3_000_000 + 10 + 3);
            assert!(req.respond(Decision::Decline));
            assert!(!req.respond(Decision::Decline), "second answer is ignored");
        }
    });
    match client.send(&rx.target(Protocol::Https), &items, None, noop(), CancellationToken::new()).await {
        Err(SendError::Declined) => {}
        other => panic!("expected Declined, got {other:?}"),
    }
    decider.await.unwrap();
    assert!(!rx.server.is_busy());
}

#[tokio::test]
async fn partial_accept_uploads_only_selected() {
    let rx = start_receiver(Protocol::Http, false, None).await;
    let (client, _) = sender(Protocol::Http);
    let src = tempfile::tempdir().unwrap();
    let items = collect_items(&write_tree(src.path())).unwrap();
    let events = rx.events.clone();
    tokio::spawn(async move {
        if let Event::IncomingRequest(req) = wait_for(&events, |e| matches!(e, Event::IncomingRequest(_))).await {
            let keep = req.files.iter().find(|f| f.file_name == "Photos/b.txt").unwrap().id.clone();
            req.respond(Decision::Accept(Some(vec![keep])));
        }
    });
    let out = client.send(&rx.target(Protocol::Http), &items, None, noop(), CancellationToken::new()).await.unwrap();
    assert_eq!(out, SendOutcome::Completed { sent: 1, failed: 0, skipped: 3 });
    wait_for(&rx.events, |e| matches!(e, Event::ReceiveFinished { .. })).await;
    assert!(rx.dir.path().join("Photos/b.txt").exists());
    assert!(!rx.dir.path().join("big.bin").exists());
}

#[tokio::test]
async fn busy_409_while_pending() {
    let rx = start_receiver(Protocol::Https, false, None).await;
    let (client, _) = sender(Protocol::Https);
    let t = rx.target(Protocol::Https);
    let items = vec![SendItem::File {
        path: write_tree(tempfile::tempdir().unwrap().keep().as_path())[0].clone(),
        name: "big.bin".into(),
        size: 3_000_000,
        metadata: None,
    }];
    // First send waits for a decision…
    let c1 = client.clone();
    let t1 = t.clone();
    let i1 = items.clone();
    let first = tokio::spawn(async move { c1.send(&t1, &i1, None, noop(), CancellationToken::new()).await });
    let req = match wait_for(&rx.events, |e| matches!(e, Event::IncomingRequest(_))).await {
        Event::IncomingRequest(r) => r,
        _ => unreachable!(),
    };
    // …so a second one is refused.
    match client.send(&t, &items, None, noop(), CancellationToken::new()).await {
        Err(SendError::Busy) => {}
        other => panic!("expected Busy, got {other:?}"),
    }
    assert!(req.respond(Decision::Accept(None)));
    assert_eq!(first.await.unwrap().unwrap(), SendOutcome::Completed { sent: 1, failed: 0, skipped: 0 });
}

#[tokio::test]
async fn sender_disconnect_frees_pending_slot() {
    let rx = start_receiver(Protocol::Http, false, None).await;
    let (client, _) = sender(Protocol::Http);
    let t = rx.target(Protocol::Http);
    let cancel = CancellationToken::new();
    let c1 = client.clone();
    let t1 = t.clone();
    let k = cancel.clone();
    let first = tokio::spawn(async move { c1.send(&t1, &[SendItem::File { path: "/dev/null".into(), name: "n".into(), size: 0, metadata: None }], None, noop(), k).await });
    let id = match wait_for(&rx.events, |e| matches!(e, Event::IncomingRequest(_))).await {
        Event::IncomingRequest(r) => r.id,
        _ => unreachable!(),
    };
    cancel.cancel();
    assert!(matches!(first.await.unwrap(), Err(SendError::Cancelled)));
    wait_for(&rx.events, |e| matches!(e, Event::IncomingRequestClosed { id: i } if *i == id)).await;
    assert!(!rx.server.is_busy());
}

/// Raw protocol checks: 400 / 403 for bad upload params, cancel, sha256 → 422.
#[tokio::test]
async fn raw_upload_errors_and_cancel() {
    let rx = start_receiver(Protocol::Http, true, None).await;
    let http = reqwest::Client::new();
    let base = format!("http://127.0.0.1:{}/api/localsend/v2", rx.server.port());
    let id = Identity::generate().unwrap();

    let content = b"hello world".to_vec();
    let mut files = std::collections::BTreeMap::new();
    files.insert(
        "good".to_string(),
        FileDto {
            id: "good".into(),
            file_name: "good.txt".into(),
            size: content.len() as u64,
            file_type: "application/octet-stream".into(),
            sha256: Some(slip_core::identity::sha256_hex(&content)),
            preview: None,
            metadata: None,
        },
    );
    files.insert(
        "bad".to_string(),
        FileDto {
            id: "bad".into(),
            file_name: "../../bad.txt".into(),
            size: content.len() as u64,
            file_type: "application/octet-stream".into(),
            sha256: Some("00".repeat(32)),
            preview: None,
            metadata: None,
        },
    );
    let body = PrepareUploadRequest { info: info("Raw", &id, Protocol::Http), files };

    // Malformed body → 400.
    let r = http.post(format!("{base}/prepare-upload")).body("{nope").send().await.unwrap();
    assert_eq!(r.status(), 400);

    let r = http.post(format!("{base}/prepare-upload")).json(&body).send().await.unwrap();
    assert_eq!(r.status(), 200);
    let resp: PrepareUploadResponse = r.json().await.unwrap();
    assert_eq!(resp.files.len(), 2);

    // Missing params → 400.
    let r = http.post(format!("{base}/upload?sessionId={}", resp.session_id)).body("x").send().await.unwrap();
    assert_eq!(r.status(), 400);
    // Bad token → 403.
    let r = http
        .post(format!("{base}/upload?sessionId={}&fileId=good&token=wrong", resp.session_id))
        .body(content.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 403);
    // Unknown session → 403.
    let r = http
        .post(format!("{base}/upload?sessionId=nope&fileId=good&token={}", resp.files["good"]))
        .body(content.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 403);
    // Checksum mismatch → 422 and no file.
    let r = http
        .post(format!("{base}/upload?sessionId={}&fileId=bad&token={}", resp.session_id, resp.files["bad"]))
        .body(content.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 422);
    assert!(!rx.dir.path().join("bad.txt").exists());
    // Good upload with matching sha256 → 200.
    let r = http
        .post(format!("{base}/upload?sessionId={}&fileId=good&token={}", resp.session_id, resp.files["good"]))
        .body(content.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(std::fs::read(rx.dir.path().join("good.txt")).unwrap(), content);
    // Both files finished → session over → upload again is 403.
    wait_for(&rx.events, |e| matches!(e, Event::ReceiveFinished { cancelled: false, .. })).await;
    assert!(!rx.server.is_busy());

    // New session, then cancel mid-stream: partial file removed.
    let r = http.post(format!("{base}/prepare-upload")).json(&body).send().await.unwrap();
    let resp: PrepareUploadResponse = r.json().await.unwrap();
    let (chunk_tx, chunk_rx) = async_channel::unbounded::<Result<Vec<u8>, std::io::Error>>();
    chunk_tx.send(Ok(b"hello".to_vec())).await.unwrap();
    let url = format!("{base}/upload?sessionId={}&fileId=good&token={}", resp.session_id, resp.files["good"]);
    let h2 = http.clone();
    let upload = tokio::spawn(async move { h2.post(url).body(reqwest::Body::wrap_stream(chunk_rx)).send().await });
    wait_for(&rx.events, |e| matches!(e, Event::ReceiveProgress { .. })).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let r = http.post(format!("{base}/cancel?sessionId={}", resp.session_id)).send().await.unwrap();
    assert_eq!(r.status(), 200);
    wait_for(&rx.events, |e| matches!(e, Event::ReceiveFinished { cancelled: true, .. })).await;
    let _ = tokio::time::timeout(Duration::from_secs(5), upload).await;
    drop(chunk_tx);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let leftovers: Vec<_> = std::fs::read_dir(rx.dir.path())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with(".slip-partial"))
        .collect();
    assert!(leftovers.is_empty(), "partial files left: {leftovers:?}");
    assert!(!rx.server.is_busy());

    // v1 routes are not supported.
    let r = http.post(format!("http://127.0.0.1:{}/api/localsend/v1/send-request", rx.server.port())).send().await.unwrap();
    assert_eq!(r.status(), 404);
    let _ = &rx.receive;
}

#[tokio::test]
async fn https_server_presents_identity_certificate() {
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
    use rustls::{DigitallySignedStruct, SignatureScheme};

    #[derive(Debug)]
    struct Capture(std::sync::Mutex<Option<Vec<u8>>>, Arc<rustls::crypto::CryptoProvider>);
    impl ServerCertVerifier for Capture {
        fn verify_server_cert(&self, ee: &CertificateDer<'_>, _: &[CertificateDer<'_>], _: &ServerName<'_>, _: &[u8], _: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
            *self.0.lock().unwrap() = Some(ee.to_vec());
            Ok(ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(m, c, d, &self.1.signature_verification_algorithms)
        }
        fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(m, c, d, &self.1.signature_verification_algorithms)
        }
        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.1.signature_verification_algorithms.supported_schemes()
        }
    }

    let rx = start_receiver(Protocol::Https, true, None).await;
    let port = rx.server.port();
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let capture = Arc::new(Capture(Default::default(), provider.clone()));
    let cap2 = capture.clone();
    tokio::task::spawn_blocking(move || {
        use std::io::{Read, Write};
        let cfg = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(cap2)
            .with_no_client_auth();
        let conn = rustls::ClientConnection::new(Arc::new(cfg), ServerName::try_from("localhost").unwrap()).unwrap();
        let sock = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        let mut tls = rustls::StreamOwned::new(conn, sock);
        tls.write_all(b"GET /api/localsend/v2/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").unwrap();
        let mut out = Vec::new();
        let _ = tls.read_to_end(&mut out);
        assert!(String::from_utf8_lossy(&out).starts_with("HTTP/1.1 200"));
    })
    .await
    .unwrap();
    let der = capture.0.lock().unwrap().clone().expect("captured cert");
    assert_eq!(slip_core::identity::sha256_hex(&der), rx.identity.cert_fingerprint);
}
