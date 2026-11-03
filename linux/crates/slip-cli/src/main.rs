//! `slip-cli` — headless Slip / LocalSend client for interop testing.
//!
//! ```text
//! slip-cli receive --port 53317 --dir ~/Downloads --auto-accept [--http] [--pin 1234]
//! slip-cli send --to 192.168.1.5:53317 [--http] [--pin 1234] file1 folder2 …
//! slip-cli send --to 192.168.1.5:53317 --text "hello"
//! slip-cli discover [--timeout 5] [--scan]
//! ```

use std::io::{BufRead, IsTerminal, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use slip_core::client::{collect_items, SendError, SendEvent, SendItem, SendOutcome, Target};
use slip_core::identity::Identity;
use slip_core::model::{DeviceType, Protocol};
use slip_core::node::{Node, NodeOptions};
use slip_core::settings::Settings;
use slip_core::{Decision, Event};
use tokio_util::sync::CancellationToken;

#[derive(Parser)]
#[command(name = "slip-cli", version, about = "Headless Slip / LocalSend client")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Args, Clone)]
struct Common {
    /// Alias to advertise (default: random "Adjective Fruit").
    #[arg(long)]
    alias: Option<String>,
    /// Persist identity (key/cert/fingerprint) in this directory instead of using a
    /// throwaway in-memory identity.
    #[arg(long)]
    config_dir: Option<PathBuf>,
    /// Multicast UDP port.
    #[arg(long, default_value_t = slip_core::DEFAULT_PORT)]
    multicast_port: u16,
    /// Verbose logging.
    #[arg(short, long)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run a receiver.
    Receive {
        #[arg(long, default_value_t = slip_core::DEFAULT_PORT)]
        port: u16,
        /// Save directory (default: XDG Downloads).
        #[arg(long)]
        dir: Option<PathBuf>,
        /// Accept every transfer without asking (Quick Save).
        #[arg(long)]
        auto_accept: bool,
        /// Serve plain HTTP instead of HTTPS.
        #[arg(long)]
        http: bool,
        /// Require this PIN.
        #[arg(long)]
        pin: Option<String>,
        /// Don't join the multicast group.
        #[arg(long)]
        no_multicast: bool,
        /// Exit after the first completed session.
        #[arg(long)]
        once: bool,
        #[command(flatten)]
        common: Common,
    },
    /// Send files/folders (or --text) to a receiver.
    Send {
        /// Receiver address: host[:port] (port defaults to 53317).
        #[arg(long)]
        to: String,
        /// The receiver uses plain HTTP.
        #[arg(long)]
        http: bool,
        #[arg(long)]
        pin: Option<String>,
        /// Send a text message instead of files.
        #[arg(long)]
        text: Option<String>,
        files: Vec<PathBuf>,
        #[command(flatten)]
        common: Common,
    },
    /// List peers seen via multicast (and optionally an HTTP subnet scan).
    Discover {
        /// Seconds to listen.
        #[arg(long, default_value_t = 5)]
        timeout: u64,
        /// Also POST /register to every host on local /24 subnets.
        #[arg(long)]
        scan: bool,
        /// Port to scan (default: --port, or 53317 when --port is 0).
        #[arg(long)]
        scan_port: Option<u16>,
        /// TCP port for our own server (peers answer announces via POST /register).
        /// 0 picks a free port.
        #[arg(long, default_value_t = 0)]
        port: u16,
        /// Run our server/scan in plain HTTP.
        #[arg(long)]
        http: bool,
        #[command(flatten)]
        common: Common,
    },
}

fn init_logging(verbose: bool) {
    let filter = if verbose { "slip_core=debug,slip_cli=debug" } else { "warn" };
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| filter.into()))
        .with_writer(std::io::stderr)
        .try_init();
}

fn identity(common: &Common) -> Result<Identity> {
    Ok(match &common.config_dir {
        Some(d) => Identity::load_or_create(d)?,
        None => Identity::generate()?,
    })
}

fn base_settings(common: &Common) -> Settings {
    let mut s = Settings::default();
    if let Some(a) = &common.alias {
        s.alias = a.clone();
    }
    s.multicast_port = common.multicast_port;
    s
}

fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut u = 0;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 {
        format!("{bytes} B")
    } else {
        format!("{v:.1} {}", UNITS[u])
    }
}

fn prompt(question: &str) -> Option<String> {
    if !std::io::stdin().is_terminal() {
        return None;
    }
    eprint!("{question}");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line).ok()?;
    Some(line.trim().to_string())
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Receive { port, dir, auto_accept, http, pin, no_multicast, once, common } => {
            init_logging(common.verbose);
            receive(port, dir, auto_accept, http, pin, !no_multicast, once, &common).await
        }
        Cmd::Send { to, http, pin, text, files, common } => {
            init_logging(common.verbose);
            send(&to, http, pin, text, files, &common).await
        }
        Cmd::Discover { timeout, scan, scan_port, port, http, common } => {
            init_logging(common.verbose);
            let scan_port = scan.then(|| scan_port.unwrap_or(if port == 0 { slip_core::DEFAULT_PORT } else { port }));
            discover(timeout, scan_port, port, http, &common).await
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn receive(
    port: u16,
    dir: Option<PathBuf>,
    auto_accept: bool,
    http: bool,
    pin: Option<String>,
    multicast: bool,
    once: bool,
    common: &Common,
) -> Result<()> {
    let mut s = base_settings(common);
    s.port = port;
    s.https = !http;
    s.save_dir = dir;
    s.quick_save = auto_accept;
    if let Some(p) = pin {
        s.require_pin = true;
        s.pin = p;
    }
    let save_dir = s.effective_save_dir();
    let (tx, rx) = async_channel::unbounded();
    let node = Node::start(
        identity(common)?,
        NodeOptions { settings: s, device_type: DeviceType::Headless, multicast, server: true },
        tx,
    )
    .await?;
    if let Some(err) = node.server_error() {
        bail!("{err}");
    }
    let info = node.device_info();
    println!(
        "Receiving as \"{}\" on {}://0.0.0.0:{} → {}",
        info.alias,
        info.protocol,
        node.port().unwrap_or(port),
        save_dir.display()
    );
    println!("Fingerprint: {}", info.fingerprint);
    let ips = slip_core::net::local_ipv4_addrs();
    if !ips.is_empty() {
        println!("Addresses: {}", ips.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(", "));
    }
    println!("Multicast: {}", if node.multicast_active() { "on" } else { "off" });

    let ctrl_c = tokio::signal::ctrl_c();
    tokio::pin!(ctrl_c);
    loop {
        let ev = tokio::select! {
            _ = &mut ctrl_c => break,
            ev = rx.recv() => match ev { Ok(e) => e, Err(_) => break },
        };
        match ev {
            Event::PeerUpdated(p) => tracing::info!("peer {} ({}) at {}", p.info.alias, p.info.fingerprint, p.address()),
            Event::PeerLost { .. } => {}
            Event::IncomingRequest(req) => {
                println!("Incoming from \"{}\" ({}): {} file(s), {}", req.sender.alias, req.sender_ip, req.files.len(), human(req.total_size()));
                for f in &req.files {
                    println!("  {} ({})", f.file_name, human(f.size));
                }
                let req2 = req.clone();
                tokio::task::spawn_blocking(move || {
                    let answer = prompt("Accept? [y/N] ").unwrap_or_default();
                    let d = if answer.eq_ignore_ascii_case("y") || answer.eq_ignore_ascii_case("yes") {
                        Decision::Accept(None)
                    } else {
                        Decision::Decline
                    };
                    req2.respond(d);
                });
            }
            Event::IncomingRequestClosed { .. } => {}
            Event::TextReceived { sender, text } => println!("Message from \"{}\":\n{text}", sender.alias),
            Event::ReceiveStarted { sender, files, .. } => {
                println!("Receiving {} file(s) from \"{}\"", files.len(), sender.alias)
            }
            Event::ReceiveProgress { .. } => {}
            Event::ReceiveFileDone { path, .. } => println!("  saved {}", path.display()),
            Event::ReceiveFileFailed { file_id, error, .. } => println!("  failed {file_id}: {error}"),
            Event::ReceiveFinished { cancelled, .. } => {
                println!("{}", if cancelled { "Session cancelled" } else { "Session complete" });
                if once {
                    break;
                }
            }
            Event::Warning(w) => eprintln!("warning: {w}"),
        }
    }
    node.shutdown();
    Ok(())
}

async fn send(to: &str, http: bool, pin: Option<String>, text: Option<String>, files: Vec<PathBuf>, common: &Common) -> Result<()> {
    let protocol = if http { Protocol::Http } else { Protocol::Https };
    let target = Target::parse(to, protocol).context("invalid --to address")?;
    let items: Vec<SendItem> = match text {
        Some(t) => vec![SendItem::Text(t)],
        None => {
            if files.is_empty() {
                bail!("nothing to send: pass files or --text");
            }
            collect_items(&files)?
        }
    };
    let mut s = base_settings(common);
    s.https = !http;
    let (tx, _rx) = async_channel::unbounded();
    let node = Node::start(
        identity(common)?,
        NodeOptions { settings: s, device_type: DeviceType::Headless, multicast: false, server: false },
        tx,
    )
    .await?;
    let client = node.client().clone();

    match client.info(&target).await {
        Ok(peer) => println!("Sending to \"{}\" ({}) at {}", peer.alias, peer.device_model.as_deref().unwrap_or("?"), target.url("")),
        Err(e) => println!("Sending to {} (info unavailable: {e})", target.url("")),
    }
    let total: u64 = items.iter().map(SendItem::size).sum();
    println!("{} item(s), {}", items.len(), human(total));

    let names: Arc<Mutex<std::collections::HashMap<String, (String, u64)>>> = Default::default();
    let start = Instant::now();
    let names2 = names.clone();
    let progress: slip_core::client::ProgressFn = Arc::new(move |ev| match ev {
        SendEvent::Waiting => println!("Waiting for the receiver to accept…"),
        SendEvent::Accepted { files, .. } => {
            println!("Accepted {} file(s)", files.len());
            let mut n = names2.lock().unwrap();
            for (id, name, size) in files {
                n.insert(id, (name, size));
            }
        }
        SendEvent::Progress { .. } => {}
        SendEvent::FileDone { file_id } => {
            if let Some((name, size)) = names2.lock().unwrap().get(&file_id) {
                println!("  sent {name} ({})", human(*size));
            }
        }
        SendEvent::FileFailed { file_id, error } => {
            let name = names2.lock().unwrap().get(&file_id).map(|n| n.0.clone()).unwrap_or(file_id);
            println!("  failed {name}: {error}");
        }
    });

    let cancel = CancellationToken::new();
    let c2 = cancel.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            c2.cancel();
        }
    });

    let mut pin = pin;
    for attempt in 0..4 {
        match client.send(&target, &items, pin.as_deref(), progress.clone(), cancel.clone()).await {
            Ok(SendOutcome::Delivered) => {
                println!("Delivered");
                return Ok(());
            }
            Ok(SendOutcome::Completed { sent, failed, skipped }) => {
                let secs = start.elapsed().as_secs_f64().max(0.001);
                println!(
                    "Done: {sent} sent, {failed} failed, {skipped} skipped in {secs:.2}s ({}/s)",
                    human((total as f64 / secs) as u64)
                );
                if failed > 0 {
                    std::process::exit(1);
                }
                return Ok(());
            }
            Err(SendError::PinRequired { had_pin }) if attempt < 3 => {
                let q = if had_pin { "Wrong PIN. PIN: " } else { "PIN: " };
                match prompt(q) {
                    Some(p) if !p.is_empty() => pin = Some(p),
                    _ => bail!("{}", SendError::PinRequired { had_pin }),
                }
            }
            Err(e) => bail!("{e}"),
        }
    }
    bail!("too many PIN attempts")
}

async fn discover(timeout: u64, scan_port: Option<u16>, port: u16, http: bool, common: &Common) -> Result<()> {
    let mut s = base_settings(common);
    s.port = port;
    s.https = !http;
    let (tx, rx) = async_channel::unbounded();
    let node = Node::start(
        identity(common)?,
        NodeOptions { settings: s, device_type: DeviceType::Headless, multicast: true, server: true },
        tx,
    )
    .await?;
    eprintln!(
        "Listening for {timeout}s as \"{}\" (server {}://0.0.0.0:{}, multicast {})…",
        node.device_info().alias,
        node.device_info().protocol,
        node.port().unwrap_or(0),
        if node.multicast_active() { "on" } else { "off" }
    );
    let scan_task = scan_port.map(|scan_port| {
        let node = node.clone();
        let protocol = if http { Protocol::Http } else { Protocol::Https };
        tokio::spawn(async move {
            slip_core::discovery::scan_subnets(node.client(), node.peers(), scan_port, protocol).await
        })
    });
    let deadline = tokio::time::sleep(Duration::from_secs(timeout));
    tokio::pin!(deadline);
    let mut seen = std::collections::HashSet::new();
    loop {
        tokio::select! {
            _ = &mut deadline => break,
            ev = rx.recv() => match ev {
                Ok(Event::PeerUpdated(p)) => {
                    if seen.insert(p.info.fingerprint.clone()) {
                        eprintln!("  found {} at {}", p.info.alias, p.address());
                    }
                }
                Ok(Event::Warning(w)) => eprintln!("warning: {w}"),
                Ok(_) => {}
                Err(_) => break,
            }
        }
    }
    if let Some(t) = scan_task {
        let _ = tokio::time::timeout(Duration::from_secs(5), t).await;
    }
    let peers = node.peer_list();
    if peers.is_empty() {
        println!("No peers found.");
    } else {
        println!("{:<24} {:<10} {:<10} {:<22} {:<6} FINGERPRINT", "ALIAS", "TYPE", "MODEL", "ADDRESS", "PROTO");
        for p in peers {
            println!(
                "{:<24} {:<10} {:<10} {:<22} {:<6} {}",
                p.info.alias,
                format!("{:?}", p.info.device_type_or_default()).to_lowercase(),
                p.info.device_model.as_deref().unwrap_or("-"),
                p.address(),
                p.info.protocol,
                &p.info.fingerprint[..p.info.fingerprint.len().min(16)]
            );
        }
    }
    node.shutdown();
    Ok(())
}
