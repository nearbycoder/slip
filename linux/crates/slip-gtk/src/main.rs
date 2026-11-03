//! Slip for Linux — GTK 4 + libadwaita front-end over `slip-core`.
//!
//! Threading model: a multi-threaded tokio runtime runs all networking on background
//! threads. The GTK main thread enters the runtime context (so `tokio::spawn` works from
//! callbacks) and consumes core events from an `async_channel` via
//! `glib::spawn_future_local`. Work started from the UI is spawned on tokio and its
//! `JoinHandle` awaited from the GLib main loop.

mod util;
mod window;

use std::sync::OnceLock;

use adw::prelude::*;
use gtk::{gio, glib};

pub const APP_ID: &str = slip_core::APP_ID;

pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("slip-net")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

const CSS: &str = r#"
@define-color accent_bg_color #16a34a;
@define-color accent_color #15803d;
@define-color accent_fg_color #ffffff;
.slip-hero { font-size: 22pt; font-weight: 800; }
.slip-drop-hover { background-color: alpha(@accent_bg_color, 0.15); }
.slip-file-bar { min-width: 80px; }
"#;

fn main() -> glib::ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn,slip_core=info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    // Let tokio::spawn work from GTK callbacks for the life of the app.
    let _guard = runtime().enter();

    glib::set_application_name("Slip");

    let app = adw::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();

    app.connect_startup(|_| {
        gtk::Window::set_default_icon_name(APP_ID);
        if let Some(display) = gtk::gdk::Display::default() {
            let provider = gtk::CssProvider::new();
            provider.load_from_string(CSS);
            #[allow(deprecated)]
            gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
            // Running uninstalled: find our icon next to the sources.
            let theme = gtk::IconTheme::for_display(&display);
            for dir in [concat!(env!("CARGO_MANIFEST_DIR"), "/../../data/icons")] {
                if std::path::Path::new(dir).exists() {
                    theme.add_search_path(dir);
                }
            }
        }
    });

    app.connect_activate(|app| {
        window::SlipWindow::present(app, Vec::new());
    });
    // `slip file1 file2` (or "Open With → Slip") pre-fills the send selection.
    app.connect_open(|app, files, _| {
        let paths = files.iter().filter_map(|f| f.path()).collect();
        window::SlipWindow::present(app, paths);
    });

    let code = app.run();
    runtime_shutdown();
    code
}

fn runtime_shutdown() {
    // Nothing persistent to flush; tasks are torn down with the process.
}
