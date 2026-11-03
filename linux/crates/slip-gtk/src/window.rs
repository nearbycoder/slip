//! The Slip main window: Receive / Send / Transfers view stack, preferences, dialogs.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Instant;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use slip_core::client::{collect_items, ProgressFn, SendError, SendEvent, SendItem, SendOutcome, Target};
use slip_core::identity::Identity;
use slip_core::model::{DeviceType, Protocol};
use slip_core::node::{Node, NodeOptions};
use slip_core::peers::Peer;
use slip_core::settings::{config_dir, default_save_dir, Settings, Theme};
use slip_core::{Decision, Event, IncomingRequest};
use tokio_util::sync::CancellationToken;

use crate::util::*;
use crate::{runtime, APP_ID};

thread_local! {
    static INSTANCE: RefCell<Option<Rc<SlipWindow>>> = const { RefCell::new(None) };
}

#[derive(Clone, Debug)]
enum Selected {
    Path(PathBuf),
    Text(String),
}

struct FileEntry {
    row: adw::ActionRow,
    bar: gtk::ProgressBar,
    open_btn: gtk::Button,
    size: u64,
    transferred: u64,
    /// `Some(true)` done, `Some(false)` failed, `None` pending/in progress.
    outcome: Option<bool>,
    path: Rc<RefCell<Option<PathBuf>>>,
}

enum TransferKind {
    Receive { save_dir: PathBuf },
    Send { cancel: CancellationToken },
}

struct Transfer {
    expander: adw::ExpanderRow,
    bar: gtk::ProgressBar,
    cancel_btn: gtk::Button,
    folder_btn: gtk::Button,
    spinner: gtk::Widget,
    files: HashMap<String, FileEntry>,
    started: Instant,
    finished: bool,
    kind: TransferKind,
    peer_alias: String,
    status: String,
}

impl Transfer {
    fn total(&self) -> u64 {
        self.files.values().map(|f| f.size).sum()
    }
    fn transferred(&self) -> u64 {
        self.files.values().map(|f| f.transferred).sum()
    }
    fn done_count(&self) -> usize {
        self.files.values().filter(|f| f.outcome == Some(true)).count()
    }

    fn refresh(&self) {
        let total = self.total();
        let sent = self.transferred();
        if total > 0 {
            self.bar.set_fraction((sent as f64 / total as f64).clamp(0.0, 1.0));
        } else if self.finished {
            self.bar.set_fraction(1.0);
        }
        let mut parts = Vec::new();
        if !self.status.is_empty() {
            parts.push(self.status.clone());
        }
        if !self.files.is_empty() {
            parts.push(format!("{} of {}", human_size(sent), human_size(total)));
            if !self.finished {
                let speed = human_speed(sent, self.started.elapsed());
                if !speed.is_empty() {
                    parts.push(speed);
                }
            }
        }
        self.expander.set_subtitle(&parts.join(" · "));
    }
}

pub struct SlipWindow {
    app: adw::Application,
    window: adw::ApplicationWindow,
    toasts: adw::ToastOverlay,
    stack: adw::ViewStack,
    node: Arc<Node>,
    settings: RefCell<Settings>,
    settings_path: PathBuf,

    // Receive page
    recv_status: adw::StatusPage,
    recv_addr_row: adw::ActionRow,
    recv_port_row: adw::ActionRow,
    recv_dir_row: adw::ActionRow,
    recv_discoverable: adw::SwitchRow,
    recv_quick_save: adw::SwitchRow,
    recv_banner: adw::Banner,

    // Send page
    selection: RefCell<Vec<Selected>>,
    selection_list: gtk::ListBox,
    selection_group: adw::PreferencesGroup,
    devices_list: gtk::ListBox,
    device_rows: RefCell<HashMap<String, (adw::ActionRow, Peer)>>,
    refresh_btn: gtk::Button,
    scanning: Cell<bool>,

    // Transfers page
    transfers_page: adw::ViewStackPage,
    transfers_list: gtk::ListBox,
    transfers: RefCell<HashMap<String, Transfer>>,
    next_send: Cell<u64>,

    incoming: RefCell<HashMap<u64, (Arc<IncomingRequest>, adw::AlertDialog)>>,
    syncing: Cell<bool>,
}

impl SlipWindow {
    pub fn present(app: &adw::Application, paths: Vec<PathBuf>) {
        let existing = INSTANCE.with(|i| i.borrow().clone());
        let win = match existing {
            Some(w) => w,
            None => {
                let w = Self::build(app);
                INSTANCE.with(|i| *i.borrow_mut() = Some(w.clone()));
                w
            }
        };
        if !paths.is_empty() {
            win.add_paths(paths);
            win.stack.set_visible_child_name("send");
        }
        win.window.present();
    }

    fn build(app: &adw::Application) -> Rc<SlipWindow> {
        let dir = config_dir();
        let settings_path = dir.join("settings.json");
        let settings = Settings::load_or_default(&settings_path);
        let identity = Identity::load_or_create(&dir).unwrap_or_else(|e| {
            tracing::error!("could not persist identity in {}: {e}; using a temporary one", dir.display());
            Identity::generate().expect("identity")
        });
        apply_theme(settings.theme);

        let (tx, rx) = async_channel::unbounded();
        let node = runtime()
            .block_on(Node::start(
                identity,
                NodeOptions { settings: settings.clone(), device_type: DeviceType::Desktop, multicast: true, server: true },
                tx,
            ))
            .expect("node start");

        // ---------- widgets ----------
        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("Slip")
            .default_width(760)
            .default_height(680)
            .width_request(360)
            .height_request(360)
            .icon_name(APP_ID)
            .build();

        let stack = adw::ViewStack::new();
        let toasts = adw::ToastOverlay::new();

        // Receive page
        let recv_status = adw::StatusPage::builder().icon_name(APP_ID).title(settings.alias.as_str()).build();
        let recv_banner = adw::Banner::builder().revealed(false).build();
        let recv_group = adw::PreferencesGroup::new();
        let recv_addr_row = adw::ActionRow::builder().title("Network address").subtitle_selectable(true).use_markup(false).build();
        recv_addr_row.add_prefix(&icon("network-wired-symbolic"));
        let recv_port_row = adw::ActionRow::builder().title("Port").subtitle_selectable(true).build();
        recv_port_row.add_prefix(&icon("network-transmit-receive-symbolic"));
        let recv_discoverable = adw::SwitchRow::builder()
            .title("Discoverable")
            .subtitle("Let nearby devices see this computer")
            .build();
        recv_discoverable.add_prefix(&icon("find-location-symbolic"));
        let recv_quick_save = adw::SwitchRow::builder()
            .title("Quick Save")
            .subtitle("Accept incoming files without asking")
            .build();
        recv_quick_save.add_prefix(&icon("document-save-symbolic"));
        let recv_dir_row = adw::ActionRow::builder().title("Save to").activatable(true).use_markup(false).build();
        recv_dir_row.add_prefix(&icon("folder-download-symbolic"));
        let change_dir = gtk::Button::builder().label("Change…").valign(gtk::Align::Center).build();
        recv_dir_row.add_suffix(&change_dir);
        recv_group.add(&recv_addr_row);
        recv_group.add(&recv_port_row);
        recv_group.add(&recv_discoverable);
        recv_group.add(&recv_quick_save);
        recv_group.add(&recv_dir_row);
        recv_status.set_child(Some(&clamp(&recv_group)));
        let recv_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
        recv_box.append(&recv_banner);
        recv_status.set_vexpand(true);
        recv_box.append(&recv_status);

        // Send page
        let send_box = gtk::Box::new(gtk::Orientation::Vertical, 18);
        send_box.set_margin_top(18);
        send_box.set_margin_bottom(18);
        send_box.set_margin_start(12);
        send_box.set_margin_end(12);

        let tray = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        tray.set_halign(gtk::Align::Center);
        tray.set_homogeneous(true);
        let btn_files = tray_button("document-open-symbolic", "Files");
        let btn_folder = tray_button("folder-symbolic", "Folder");
        let btn_text = tray_button("document-edit-symbolic", "Text");
        let btn_paste = tray_button("edit-paste-symbolic", "Paste");
        for b in [&btn_files, &btn_folder, &btn_text, &btn_paste] {
            tray.append(b);
        }
        send_box.append(&tray);

        let selection_group = adw::PreferencesGroup::builder().title("Selection").build();
        let clear_btn = gtk::Button::builder().label("Clear").css_classes(["flat"]).valign(gtk::Align::Center).build();
        selection_group.set_header_suffix(Some(&clear_btn));
        let selection_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
        let sel_placeholder = gtk::Label::builder()
            .label("Choose files, a folder or text — or drop files here")
            .wrap(true)
            .margin_top(18)
            .margin_bottom(18)
            .margin_start(12)
            .margin_end(12)
            .css_classes(["dim-label"])
            .build();
        selection_list.set_placeholder(Some(&sel_placeholder));
        selection_group.add(&selection_list);
        send_box.append(&selection_group);

        let devices_group = adw::PreferencesGroup::builder()
            .title("Nearby devices")
            .description("Click a device to send, or drop files onto it")
            .build();
        let refresh_btn = flat_icon_button("view-refresh-symbolic", "Refresh (scan the network)");
        devices_group.set_header_suffix(Some(&refresh_btn));
        let devices_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
        let dev_placeholder = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        dev_placeholder.set_margin_top(18);
        dev_placeholder.set_margin_bottom(18);
        dev_placeholder.set_halign(gtk::Align::Center);
        dev_placeholder.append(&spinner());
        dev_placeholder.append(&gtk::Label::builder().label("Looking for devices…").css_classes(["dim-label"]).build());
        devices_list.set_placeholder(Some(&dev_placeholder));
        devices_group.add(&devices_list);
        send_box.append(&devices_group);

        let manual_group = adw::PreferencesGroup::new();
        let manual_row = adw::EntryRow::builder().title("Send to address (IP or IP:port)").show_apply_button(true).build();
        manual_row.set_input_purpose(gtk::InputPurpose::Url);
        manual_group.add(&manual_row);
        send_box.append(&manual_group);

        let send_scroller = scrolled(&clamp(&send_box));

        // Transfers page
        let transfers_box = gtk::Box::new(gtk::Orientation::Vertical, 12);
        transfers_box.set_margin_top(18);
        transfers_box.set_margin_bottom(18);
        transfers_box.set_margin_start(12);
        transfers_box.set_margin_end(12);
        let transfers_group = adw::PreferencesGroup::builder().title("Transfers").build();
        let clear_done = gtk::Button::builder().label("Clear finished").css_classes(["flat"]).valign(gtk::Align::Center).build();
        transfers_group.set_header_suffix(Some(&clear_done));
        let transfers_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
        let tr_placeholder = adw::StatusPage::builder()
            .icon_name("folder-download-symbolic")
            .title("No transfers yet")
            .description("Files you send and receive show up here")
            .css_classes(["compact"])
            .build();
        transfers_list.set_placeholder(Some(&tr_placeholder));
        transfers_group.add(&transfers_list);
        transfers_box.append(&transfers_group);
        let transfers_scroller = scrolled(&clamp(&transfers_box));

        stack.add_titled_with_icon(&recv_box, Some("receive"), "Receive", "folder-download-symbolic");
        stack.add_titled_with_icon(&send_scroller, Some("send"), "Send", "send-to-symbolic");
        let transfers_page = stack.add_titled_with_icon(&transfers_scroller, Some("transfers"), "Transfers", "document-send-symbolic");

        // Header + switchers
        let header = adw::HeaderBar::new();
        let switcher = adw::ViewSwitcher::builder().stack(&stack).policy(adw::ViewSwitcherPolicy::Wide).build();
        header.set_title_widget(Some(&switcher));
        let menu = gio::Menu::new();
        menu.append(Some("_Refresh Devices"), Some("app.refresh"));
        menu.append(Some("_Preferences"), Some("app.preferences"));
        menu.append(Some("_About Slip"), Some("app.about"));
        menu.append(Some("_Quit"), Some("app.quit"));
        let menu_btn = gtk::MenuButton::builder().icon_name("open-menu-symbolic").menu_model(&menu).primary(true).tooltip_text("Main Menu").build();
        header.pack_end(&menu_btn);
        let switcher_bar = adw::ViewSwitcherBar::builder().stack(&stack).build();
        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toasts.set_child(Some(&stack));
        toolbar.set_content(Some(&toasts));
        toolbar.add_bottom_bar(&switcher_bar);
        window.set_content(Some(&toolbar));

        let bp = adw::Breakpoint::new(adw::BreakpointCondition::new_length(adw::BreakpointConditionLengthType::MaxWidth, 550.0, adw::LengthUnit::Sp));
        bp.add_setter(&switcher_bar, "reveal", Some(&true.to_value()));
        bp.add_setter(&switcher, "visible", Some(&false.to_value()));
        window.add_breakpoint(bp);

        let ui = Rc::new(SlipWindow {
            app: app.clone(),
            window,
            toasts,
            stack,
            node,
            settings: RefCell::new(settings),
            settings_path,
            recv_status,
            recv_addr_row,
            recv_port_row,
            recv_dir_row,
            recv_discoverable,
            recv_quick_save,
            recv_banner,
            selection: RefCell::new(Vec::new()),
            selection_list,
            selection_group,
            devices_list,
            device_rows: RefCell::new(HashMap::new()),
            refresh_btn,
            scanning: Cell::new(false),
            transfers_page,
            transfers_list,
            transfers: RefCell::new(HashMap::new()),
            next_send: Cell::new(1),
            incoming: RefCell::new(HashMap::new()),
            syncing: Cell::new(false),
        });

        // ---------- signals ----------
        let w = Rc::downgrade(&ui);
        ui.recv_discoverable.connect_active_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.is_active();
                ui.update_settings(|s| s.discoverable = v);
            }
        });
        let w = Rc::downgrade(&ui);
        ui.recv_quick_save.connect_active_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.is_active();
                ui.update_settings(|s| s.quick_save = v);
            }
        });
        let w = Rc::downgrade(&ui);
        change_dir.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.choose_save_dir();
            }
        });
        let w = Rc::downgrade(&ui);
        ui.recv_dir_row.connect_activated(move |_| {
            if let Some(ui) = w.upgrade() {
                let dir = ui.settings.borrow().effective_save_dir();
                let _ = std::fs::create_dir_all(&dir);
                ui.launch_path(&dir);
            }
        });

        let w = Rc::downgrade(&ui);
        btn_files.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.pick_files();
            }
        });
        let w = Rc::downgrade(&ui);
        btn_folder.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.pick_folder();
            }
        });
        let w = Rc::downgrade(&ui);
        btn_text.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.compose_text();
            }
        });
        let w = Rc::downgrade(&ui);
        btn_paste.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.paste();
            }
        });
        let w = Rc::downgrade(&ui);
        clear_btn.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.selection.borrow_mut().clear();
                ui.rebuild_selection();
            }
        });
        let w = Rc::downgrade(&ui);
        ui.refresh_btn.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.refresh_devices();
            }
        });
        let w = Rc::downgrade(&ui);
        manual_row.connect_apply(move |row| {
            if let Some(ui) = w.upgrade() {
                ui.send_to_address(row.text().to_string());
            }
        });
        let w = Rc::downgrade(&ui);
        clear_done.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.clear_finished();
            }
        });

        // Dropping files anywhere on the Send page adds them to the selection.
        let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
        let w = Rc::downgrade(&ui);
        drop.connect_drop(move |_, value, _, _| {
            let Some(ui) = w.upgrade() else { return false };
            match value.get::<gdk::FileList>() {
                Ok(list) => {
                    ui.add_paths(list.files().iter().filter_map(|f| f.path()).collect());
                    true
                }
                Err(_) => false,
            }
        });
        send_scroller.add_controller(drop);

        let w = Rc::downgrade(&ui);
        ui.stack.connect_visible_child_name_notify(move |s| {
            if let Some(ui) = w.upgrade() {
                if s.visible_child_name().as_deref() == Some("transfers") {
                    ui.transfers_page.set_needs_attention(false);
                }
            }
        });

        let w = Rc::downgrade(&ui);
        gio::NetworkMonitor::default().connect_network_changed(move |_, _| {
            if let Some(ui) = w.upgrade() {
                ui.refresh_receive_page();
                ui.node.announce();
            }
        });

        ui.install_actions();
        ui.refresh_receive_page();
        ui.rebuild_selection();
        for p in ui.node.peer_list() {
            ui.upsert_device(p);
        }

        // Core events → UI.
        let w = Rc::downgrade(&ui);
        glib::spawn_future_local(async move {
            while let Ok(ev) = rx.recv().await {
                match w.upgrade() {
                    Some(ui) => ui.handle_event(ev),
                    None => break,
                }
            }
        });

        // If multicast finds nobody after a few seconds, fall back to an HTTP scan.
        let w = Rc::downgrade(&ui);
        glib::timeout_add_seconds_local_once(4, move || {
            if let Some(ui) = w.upgrade() {
                if ui.device_rows.borrow().is_empty() {
                    ui.refresh_devices();
                }
            }
        });

        let w = Rc::downgrade(&ui);
        ui.window.connect_close_request(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.node.shutdown();
            }
            INSTANCE.with(|i| i.borrow_mut().take());
            glib::Propagation::Proceed
        });
        ui
    }

    fn install_actions(self: &Rc<Self>) {
        let app = &self.app;
        let add = |name: &str, f: Box<dyn Fn(&Rc<SlipWindow>, Option<&glib::Variant>)>, ty: Option<&glib::VariantTy>| {
            let action = gio::SimpleAction::new(name, ty);
            let w = Rc::downgrade(self);
            action.connect_activate(move |_, param| {
                if let Some(ui) = w.upgrade() {
                    f(&ui, param);
                }
            });
            app.add_action(&action);
        };
        add("preferences", Box::new(|ui, _| ui.show_preferences()), None);
        add("about", Box::new(|ui, _| ui.show_about()), None);
        add("refresh", Box::new(|ui, _| ui.refresh_devices()), None);
        add("add-files", Box::new(|ui, _| ui.pick_files()), None);
        add(
            "present",
            Box::new(|ui, _| {
                ui.window.present();
            }),
            None,
        );
        add(
            "quit",
            Box::new(|ui, _| {
                ui.node.shutdown();
                ui.app.quit();
            }),
            None,
        );
        add(
            "accept-incoming",
            Box::new(|ui, p| {
                if let Some(id) = p.and_then(|v| v.get::<u64>()) {
                    ui.answer_incoming(id, Decision::Accept(None));
                }
            }),
            Some(glib::VariantTy::UINT64),
        );
        add(
            "decline-incoming",
            Box::new(|ui, p| {
                if let Some(id) = p.and_then(|v| v.get::<u64>()) {
                    ui.answer_incoming(id, Decision::Decline);
                }
            }),
            Some(glib::VariantTy::UINT64),
        );
        app.set_accels_for_action("app.preferences", &["<Control>comma"]);
        app.set_accels_for_action("app.quit", &["<Control>q"]);
        app.set_accels_for_action("app.refresh", &["F5", "<Control>r"]);
        app.set_accels_for_action("app.add-files", &["<Control>o"]);
    }

    fn toast(&self, msg: &str) {
        let t = adw::Toast::new(msg);
        t.set_timeout(4);
        self.toasts.add_toast(t);
    }

    fn notify(&self, id: &str, title: &str, body: &str, buttons: &[(&str, &str, Option<glib::Variant>)]) {
        if self.window.is_active() {
            return;
        }
        let n = gio::Notification::new(title);
        n.set_body(Some(body));
        n.set_icon(&gio::ThemedIcon::new(APP_ID));
        n.set_default_action("app.present");
        for (label, action, target) in buttons {
            match target {
                Some(t) => n.add_button_with_target_value(label, action, Some(t)),
                None => n.add_button(label, action),
            }
        }
        self.app.send_notification(Some(id), &n);
    }

    // ---------------------------------------------------------------- settings

    fn update_settings(self: &Rc<Self>, f: impl FnOnce(&mut Settings)) {
        if self.syncing.get() {
            return;
        }
        let new = {
            let mut s = self.settings.borrow().clone();
            f(&mut s);
            s
        };
        if new == *self.settings.borrow() {
            return;
        }
        let old_theme = self.settings.borrow().theme;
        *self.settings.borrow_mut() = new.clone();
        if let Err(e) = new.save(&self.settings_path) {
            self.toast(&format!("Couldn't save settings: {e}"));
        }
        if new.theme != old_theme {
            apply_theme(new.theme);
        }
        let node = self.node.clone();
        let w = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let res = runtime().spawn(async move { node.apply_settings(new).await.map_err(|e| e.to_string()) }).await;
            if let Some(ui) = w.upgrade() {
                if let Ok(Err(e)) = res {
                    ui.toast(&e);
                }
                ui.refresh_receive_page();
            }
        });
        self.refresh_receive_page();
    }

    fn refresh_receive_page(&self) {
        self.syncing.set(true);
        let s = self.settings.borrow().clone();
        let info = self.node.device_info();
        self.recv_status.set_title(&s.alias);
        let ips = slip_core::net::local_ipv4_addrs();
        match (self.node.server_error(), self.node.port()) {
            (Some(err), _) => {
                self.recv_status.set_description(Some("Not receiving"));
                self.recv_banner.set_title(&format!("{err}. Choose another port in Preferences."));
                self.recv_banner.set_revealed(true);
            }
            (None, Some(_)) => {
                let what = if s.discoverable { "Ready to receive" } else { "Ready to receive · hidden from discovery" };
                self.recv_status.set_description(Some(what));
                self.recv_banner.set_revealed(false);
            }
            _ => {
                self.recv_status.set_description(Some("Starting…"));
            }
        }
        self.recv_addr_row.set_subtitle(&if ips.is_empty() {
            "No network connection".to_string()
        } else {
            ips.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(", ")
        });
        let proto = match info.protocol {
            Protocol::Https => "HTTPS (encrypted)",
            Protocol::Http => "HTTP (unencrypted)",
        };
        self.recv_port_row.set_subtitle(&format!("{} · {proto}", self.node.port().unwrap_or(s.port)));
        self.recv_discoverable.set_active(s.discoverable);
        self.recv_quick_save.set_active(s.quick_save);
        self.recv_dir_row.set_subtitle(&s.effective_save_dir().display().to_string());
        self.syncing.set(false);
    }

    fn choose_save_dir(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::builder().title("Save received files to").modal(true).build();
        let current = self.settings.borrow().effective_save_dir();
        dialog.set_initial_folder(Some(&gio::File::for_path(current)));
        let w = Rc::downgrade(self);
        let window = self.window.clone();
        glib::spawn_future_local(async move {
            if let Ok(folder) = dialog.select_folder_future(Some(&window)).await {
                if let (Some(ui), Some(path)) = (w.upgrade(), folder.path()) {
                    let default = default_save_dir();
                    ui.update_settings(|s| s.save_dir = if path == default { None } else { Some(path) });
                }
            }
        });
    }

    fn show_preferences(self: &Rc<Self>) {
        let s = self.settings.borrow().clone();
        let dialog = adw::PreferencesDialog::new();
        dialog.set_search_enabled(false);
        let page = adw::PreferencesPage::builder().title("General").icon_name("preferences-system-symbolic").build();

        // Device
        let device = adw::PreferencesGroup::builder().title("Device").build();
        let alias = adw::EntryRow::builder().title("Device name").text(s.alias.as_str()).show_apply_button(true).build();
        let theme = adw::ComboRow::builder()
            .title("Appearance")
            .model(&gtk::StringList::new(&["Follow system", "Light", "Dark"]))
            .selected(match s.theme {
                Theme::System => 0,
                Theme::Light => 1,
                Theme::Dark => 2,
            })
            .build();
        device.add(&alias);
        device.add(&theme);
        page.add(&device);

        // Receiving
        let receiving = adw::PreferencesGroup::builder().title("Receiving").build();
        let dir_row = adw::ActionRow::builder().title("Save to").subtitle(s.effective_save_dir().display().to_string()).use_markup(false).build();
        let dir_btn = gtk::Button::builder().icon_name("folder-open-symbolic").valign(gtk::Align::Center).tooltip_text("Choose folder").css_classes(["flat"]).build();
        dir_row.add_suffix(&dir_btn);
        dir_row.set_activatable_widget(Some(&dir_btn));
        let quick = adw::SwitchRow::builder().title("Quick Save").subtitle("Accept incoming files without asking").active(s.quick_save).build();
        let require_pin = adw::SwitchRow::builder().title("Require PIN").subtitle("Senders must enter this PIN").active(s.require_pin).build();
        let pin = adw::PasswordEntryRow::builder().title("PIN").text(s.pin.as_str()).show_apply_button(true).sensitive(s.require_pin).build();
        receiving.add(&dir_row);
        receiving.add(&quick);
        receiving.add(&require_pin);
        receiving.add(&pin);
        page.add(&receiving);

        // Network
        let network = adw::PreferencesGroup::builder().title("Network").build();
        let discoverable = adw::SwitchRow::builder().title("Discoverable").subtitle("Announce this device on the local network").active(s.discoverable).build();
        let port = adw::EntryRow::builder().title("Port").text(s.port.to_string()).show_apply_button(true).input_purpose(gtk::InputPurpose::Digits).build();
        let https = adw::SwitchRow::builder()
            .title("Encryption")
            .subtitle("Use HTTPS. Turn off only for devices that require plain HTTP")
            .active(s.https)
            .build();
        network.add(&discoverable);
        network.add(&port);
        network.add(&https);
        let info = self.node.device_info();
        let fp = adw::ActionRow::builder()
            .title("Fingerprint")
            .subtitle(info.fingerprint.as_str())
            .subtitle_selectable(true)
            .css_classes(["property"])
            .build();
        network.add(&fp);
        page.add(&network);
        dialog.add(&page);

        let w = Rc::downgrade(self);
        alias.connect_apply(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.text().trim().to_string();
                if v.is_empty() {
                    ui.toast("Device name can't be empty");
                    return;
                }
                ui.update_settings(|s| s.alias = v);
            }
        });
        let w = Rc::downgrade(self);
        theme.connect_selected_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let t = match row.selected() {
                    1 => Theme::Light,
                    2 => Theme::Dark,
                    _ => Theme::System,
                };
                ui.update_settings(|s| s.theme = t);
            }
        });
        let w = Rc::downgrade(self);
        let dir_row2 = dir_row.clone();
        let dialog2 = dialog.clone();
        dir_btn.connect_clicked(move |_| {
            let Some(ui) = w.upgrade() else { return };
            let fd = gtk::FileDialog::builder().title("Save received files to").modal(true).build();
            fd.set_initial_folder(Some(&gio::File::for_path(ui.settings.borrow().effective_save_dir())));
            let dir_row = dir_row2.clone();
            let window = ui.window.clone();
            let w = Rc::downgrade(&ui);
            let _ = &dialog2;
            glib::spawn_future_local(async move {
                if let Ok(folder) = fd.select_folder_future(Some(&window)).await {
                    if let (Some(ui), Some(path)) = (w.upgrade(), folder.path()) {
                        dir_row.set_subtitle(&path.display().to_string());
                        let default = default_save_dir();
                        ui.update_settings(|s| s.save_dir = if path == default { None } else { Some(path) });
                    }
                }
            });
        });
        let w = Rc::downgrade(self);
        quick.connect_active_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.is_active();
                ui.update_settings(|s| s.quick_save = v);
            }
        });
        let w = Rc::downgrade(self);
        let pin2 = pin.clone();
        require_pin.connect_active_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.is_active();
                pin2.set_sensitive(v);
                if v && pin2.text().is_empty() {
                    pin2.grab_focus();
                    ui.toast("Enter a PIN and press ✓ to require it");
                }
                ui.update_settings(|s| s.require_pin = v);
            }
        });
        let w = Rc::downgrade(self);
        pin.connect_apply(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.text().trim().to_string();
                ui.update_settings(|s| s.pin = v);
                ui.toast("PIN updated");
            }
        });
        let w = Rc::downgrade(self);
        discoverable.connect_active_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.is_active();
                ui.update_settings(|s| s.discoverable = v);
            }
        });
        let w = Rc::downgrade(self);
        port.connect_apply(move |row| {
            if let Some(ui) = w.upgrade() {
                match row.text().trim().parse::<u16>() {
                    Ok(p) if p >= 1024 => ui.update_settings(|s| s.port = p),
                    _ => ui.toast("Port must be a number between 1024 and 65535"),
                }
            }
        });
        let w = Rc::downgrade(self);
        let fp2 = fp.clone();
        https.connect_active_notify(move |row| {
            if let Some(ui) = w.upgrade() {
                let v = row.is_active();
                ui.update_settings(|s| s.https = v);
                let id = ui.node.identity();
                fp2.set_subtitle(id.fingerprint(if v { Protocol::Https } else { Protocol::Http }));
            }
        });

        dialog.present(Some(&self.window));
    }

    fn show_about(&self) {
        let about = adw::AboutDialog::builder()
            .application_name("Slip")
            .application_icon(APP_ID)
            .version(env!("CARGO_PKG_VERSION"))
            .developer_name("Slip contributors")
            .license_type(gtk::License::MitX11)
            .website("https://nearbycoder.github.io/slip/")
            .issue_url("https://github.com/nearbycoder/slip/issues")
            .comments("Send files and text to nearby devices. Compatible with LocalSend.")
            .build();
        about.present(Some(&self.window));
    }

    // ---------------------------------------------------------------- selection

    fn add_paths(self: &Rc<Self>, paths: Vec<PathBuf>) {
        {
            let mut sel = self.selection.borrow_mut();
            for p in paths {
                if !sel.iter().any(|s| matches!(s, Selected::Path(q) if *q == p)) {
                    sel.push(Selected::Path(p));
                }
            }
        }
        self.rebuild_selection();
    }

    fn rebuild_selection(self: &Rc<Self>) {
        while let Some(child) = self.selection_list.first_child() {
            self.selection_list.remove(&child);
        }
        let sel = self.selection.borrow().clone();
        for (idx, item) in sel.iter().enumerate() {
            let row = adw::ActionRow::builder().use_markup(false).build();
            match item {
                Selected::Path(p) => {
                    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| p.display().to_string());
                    row.set_title(&name);
                    let is_dir = p.is_dir();
                    let subtitle = if is_dir {
                        "Folder".to_string()
                    } else {
                        std::fs::metadata(p).map(|m| human_size(m.len())).unwrap_or_else(|_| "Unavailable".into())
                    };
                    row.set_subtitle(&subtitle);
                    let mime = gio::content_type_guess(Some(p), None).0;
                    let icon_name = if is_dir { "folder-symbolic" } else { file_icon(&mime) };
                    row.add_prefix(&icon(icon_name));
                }
                Selected::Text(t) => {
                    let preview: String = t.chars().take(80).map(|c| if c == '\n' { ' ' } else { c }).collect();
                    row.set_title(&preview);
                    row.set_subtitle(&format!("Text · {}", plural(t.chars().count(), "character", "characters")));
                    row.add_prefix(&icon("text-x-generic-symbolic"));
                }
            }
            let remove = flat_icon_button("edit-delete-symbolic", "Remove");
            let w = Rc::downgrade(self);
            remove.connect_clicked(move |_| {
                if let Some(ui) = w.upgrade() {
                    if idx < ui.selection.borrow().len() {
                        ui.selection.borrow_mut().remove(idx);
                    }
                    ui.rebuild_selection();
                }
            });
            row.add_suffix(&remove);
            self.selection_list.append(&row);
        }
        let n = sel.len();
        let desc = plural(n, "item", "items");
        self.selection_group.set_description(if n == 0 { None } else { Some(desc.as_str()) });
    }

    fn pick_files(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::builder().title("Choose files to send").modal(true).build();
        let w = Rc::downgrade(self);
        let window = self.window.clone();
        glib::spawn_future_local(async move {
            if let Ok(model) = dialog.open_multiple_future(Some(&window)).await {
                let paths: Vec<PathBuf> = (0..model.n_items())
                    .filter_map(|i| model.item(i).and_downcast::<gio::File>())
                    .filter_map(|f| f.path())
                    .collect();
                if let Some(ui) = w.upgrade() {
                    ui.add_paths(paths);
                }
            }
        });
    }

    fn pick_folder(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::builder().title("Choose a folder to send").modal(true).build();
        let w = Rc::downgrade(self);
        let window = self.window.clone();
        glib::spawn_future_local(async move {
            if let Ok(folder) = dialog.select_folder_future(Some(&window)).await {
                if let (Some(ui), Some(p)) = (w.upgrade(), folder.path()) {
                    ui.add_paths(vec![p]);
                }
            }
        });
    }

    fn compose_text(self: &Rc<Self>) {
        let dialog = adw::AlertDialog::new(Some("Send text"), None);
        let view = gtk::TextView::builder().wrap_mode(gtk::WrapMode::WordChar).top_margin(8).bottom_margin(8).left_margin(8).right_margin(8).build();
        let scroller = gtk::ScrolledWindow::builder().min_content_height(140).min_content_width(320).child(&view).css_classes(["card"]).build();
        dialog.set_extra_child(Some(&scroller));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("add", "Add");
        dialog.set_response_appearance("add", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("add"));
        dialog.set_close_response("cancel");
        let w = Rc::downgrade(self);
        let window = self.window.clone();
        view.grab_focus();
        glib::spawn_future_local(async move {
            let resp = dialog.choose_future(Some(&window)).await;
            if resp == "add" {
                let buf = view.buffer();
                let text = buf.text(&buf.start_iter(), &buf.end_iter(), false).to_string();
                if let Some(ui) = w.upgrade() {
                    if !text.trim().is_empty() {
                        ui.selection.borrow_mut().push(Selected::Text(text));
                        ui.rebuild_selection();
                    }
                }
            }
        });
    }

    fn paste(self: &Rc<Self>) {
        let clipboard = self.window.clipboard();
        let w = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            if let Ok(v) = clipboard.read_value_future(gdk::FileList::static_type(), glib::Priority::DEFAULT).await {
                if let Ok(list) = v.get::<gdk::FileList>() {
                    let paths: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).collect();
                    if !paths.is_empty() {
                        if let Some(ui) = w.upgrade() {
                            ui.add_paths(paths);
                        }
                        return;
                    }
                }
            }
            match clipboard.read_text_future().await {
                Ok(Some(text)) if !text.trim().is_empty() => {
                    if let Some(ui) = w.upgrade() {
                        ui.selection.borrow_mut().push(Selected::Text(text.to_string()));
                        ui.rebuild_selection();
                    }
                }
                _ => {
                    if let Some(ui) = w.upgrade() {
                        ui.toast("Clipboard is empty");
                    }
                }
            }
        });
    }

    // ---------------------------------------------------------------- devices

    fn upsert_device(self: &Rc<Self>, peer: Peer) {
        let fp = peer.info.fingerprint.clone();
        let subtitle = format!(
            "{} · {}{}",
            peer.info.device_model.as_deref().unwrap_or("Unknown"),
            peer.address(),
            if peer.info.protocol == Protocol::Http { " · HTTP" } else { "" }
        );
        if let Some((row, stored)) = self.device_rows.borrow_mut().get_mut(&fp) {
            row.set_title(&peer.info.alias);
            row.set_subtitle(&subtitle);
            *stored = peer;
            return;
        }
        let row = adw::ActionRow::builder().title(peer.info.alias.as_str()).subtitle(subtitle.as_str()).activatable(true).use_markup(false).build();
        let img = icon(peer.info.device_type_or_default().icon_name());
        img.set_icon_size(gtk::IconSize::Large);
        row.add_prefix(&img);
        row.add_suffix(&icon("go-next-symbolic"));
        let w = Rc::downgrade(self);
        let fp2 = fp.clone();
        row.connect_activated(move |_| {
            if let Some(ui) = w.upgrade() {
                let peer = ui.device_rows.borrow().get(&fp2).map(|(_, p)| p.clone());
                if let Some(peer) = peer {
                    if ui.selection.borrow().is_empty() {
                        ui.toast("Choose files or text to send first");
                        ui.pick_files();
                        return;
                    }
                    let sel = ui.selection.borrow().clone();
                    ui.start_send(peer.target(), peer.info.alias.clone(), Some(peer.info.fingerprint.clone()), sel);
                }
            }
        });
        // Drop files straight onto a device to send them.
        let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
        let w = Rc::downgrade(self);
        let fp3 = fp.clone();
        drop.connect_drop(move |_, value, _, _| {
            let Some(ui) = w.upgrade() else { return false };
            let Ok(list) = value.get::<gdk::FileList>() else { return false };
            let paths: Vec<Selected> = list.files().iter().filter_map(|f| f.path()).map(Selected::Path).collect();
            let peer = ui.device_rows.borrow().get(&fp3).map(|(_, p)| p.clone());
            match peer {
                Some(peer) if !paths.is_empty() => {
                    ui.start_send(peer.target(), peer.info.alias.clone(), Some(peer.info.fingerprint.clone()), paths);
                    true
                }
                _ => false,
            }
        });
        let r = row.clone();
        drop.connect_enter(move |_, _, _| {
            r.add_css_class("slip-drop-hover");
            gdk::DragAction::COPY
        });
        let r = row.clone();
        drop.connect_leave(move |_| r.remove_css_class("slip-drop-hover"));
        row.add_controller(drop);

        self.devices_list.append(&row);
        self.device_rows.borrow_mut().insert(fp, (row, peer));
        self.sort_devices();
    }

    fn sort_devices(&self) {
        let rows = self.device_rows.borrow();
        let mut v: Vec<_> = rows.values().collect();
        v.sort_by_key(|(_, p)| p.info.alias.to_lowercase());
        for (row, _) in &v {
            self.devices_list.remove(row);
        }
        for (row, _) in v {
            self.devices_list.append(row);
        }
    }

    fn remove_device(&self, fp: &str) {
        if let Some((row, _)) = self.device_rows.borrow_mut().remove(fp) {
            self.devices_list.remove(&row);
        }
    }

    fn refresh_devices(self: &Rc<Self>) {
        if self.scanning.replace(true) {
            return;
        }
        self.refresh_btn.set_sensitive(false);
        let node = self.node.clone();
        let w = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let found = runtime().spawn(async move { node.refresh().await }).await.unwrap_or(0);
            if let Some(ui) = w.upgrade() {
                ui.scanning.set(false);
                ui.refresh_btn.set_sensitive(true);
                tracing::info!("scan found {found} device(s)");
            }
        });
    }

    fn send_to_address(self: &Rc<Self>, text: String) {
        if self.selection.borrow().is_empty() {
            self.toast("Choose files or text to send first");
            return;
        }
        let Some(t) = Target::parse(&text, Protocol::Https) else {
            self.toast("Enter an address like 192.168.1.20 or 192.168.1.20:53317");
            return;
        };
        let client = self.node.client().clone();
        let w = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            // Detect the receiver's protocol: HTTPS first, then HTTP.
            let probe = runtime()
                .spawn(async move {
                    for proto in [Protocol::Https, Protocol::Http] {
                        let target = Target { protocol: proto, ..t.clone() };
                        if let Ok(info) = client.register(&target).await {
                            return Some((target, info));
                        }
                    }
                    None
                })
                .await
                .ok()
                .flatten();
            let Some(ui) = w.upgrade() else { return };
            match probe {
                Some((target, info)) => {
                    let sel = ui.selection.borrow().clone();
                    ui.start_send(target, info.alias.clone(), Some(info.fingerprint.clone()), sel);
                }
                None => ui.toast(&format!("Couldn't reach {text}")),
            }
        });
    }

    // ---------------------------------------------------------------- sending

    fn start_send(self: &Rc<Self>, target: Target, alias: String, fingerprint: Option<String>, selection: Vec<Selected>) {
        if selection.is_empty() {
            return;
        }
        let ui = self.clone();
        glib::spawn_future_local(async move {
            let paths: Vec<PathBuf> = selection.iter().filter_map(|s| if let Selected::Path(p) = s { Some(p.clone()) } else { None }).collect();
            let texts: Vec<String> = selection.iter().filter_map(|s| if let Selected::Text(t) = s { Some(t.clone()) } else { None }).collect();
            let mut batches: Vec<Vec<SendItem>> = texts.into_iter().map(|t| vec![SendItem::Text(t)]).collect();
            if !paths.is_empty() {
                match runtime().spawn_blocking(move || collect_items(&paths)).await {
                    Ok(Ok(items)) if !items.is_empty() => batches.push(items),
                    Ok(Ok(_)) => ui.toast("The selected folders are empty"),
                    Ok(Err(e)) => ui.toast(&format!("Can't read files: {e}")),
                    Err(e) => ui.toast(&format!("Can't read files: {e}")),
                }
            }
            if let Some(fp) = &fingerprint {
                ui.node.peers().pin(fp);
            }
            ui.stack.set_visible_child_name("transfers");
            for batch in batches {
                if !ui.send_batch(&target, &alias, batch).await {
                    break;
                }
            }
            if let Some(fp) = &fingerprint {
                ui.node.peers().unpin(fp);
            }
        });
    }

    /// Returns false if the user cancelled or a fatal error occurred.
    async fn send_batch(self: &Rc<Self>, target: &Target, alias: &str, batch: Vec<SendItem>) -> bool {
        let n = self.next_send.get();
        self.next_send.set(n + 1);
        let key = format!("send-{n}");
        let is_text = matches!(batch.as_slice(), [SendItem::Text(_)]);
        let title = if is_text { format!("Message to {alias}") } else { format!("Sending to {alias}") };
        let cancel = CancellationToken::new();
        self.create_transfer(&key, &title, "send-to-symbolic", alias, TransferKind::Send { cancel: cancel.clone() });
        self.set_transfer_status(&key, "Waiting for the receiver to accept…");

        let mut pin: Option<String> = None;
        loop {
            let (tx, rx) = async_channel::unbounded::<SendEvent>();
            let progress: ProgressFn = Arc::new(move |ev| {
                let _ = tx.try_send(ev);
            });
            let client = self.node.client().clone();
            let t = target.clone();
            let b = batch.clone();
            let p = pin.clone();
            let c = cancel.clone();
            let handle = runtime().spawn(async move { client.send(&t, &b, p.as_deref(), progress, c).await });
            let w = Rc::downgrade(self);
            let k = key.clone();
            let pump = glib::spawn_future_local(async move {
                while let Ok(ev) = rx.recv().await {
                    if let Some(ui) = w.upgrade() {
                        ui.on_send_event(&k, ev);
                    }
                }
            });
            let result = handle.await;
            let _ = pump.await;
            let result = match result {
                Ok(r) => r,
                Err(e) => Err(SendError::Network(e.to_string())),
            };
            match result {
                Ok(SendOutcome::Delivered) => {
                    self.finish_transfer(&key, "Delivered", false);
                    self.toast(&format!("Sent to {alias}"));
                    return true;
                }
                Ok(SendOutcome::Completed { sent, failed, .. }) => {
                    if failed == 0 {
                        self.finish_transfer(&key, &format!("Sent {}", plural(sent, "file", "files")), false);
                        self.toast(&format!("Sent {} to {alias}", plural(sent, "file", "files")));
                    } else {
                        self.finish_transfer(&key, &format!("{sent} sent, {failed} failed"), true);
                        self.toast(&format!("{failed} file(s) failed to send"));
                    }
                    return true;
                }
                Err(SendError::PinRequired { had_pin }) => match self.ask_pin(alias, had_pin).await {
                    Some(p) => {
                        pin = Some(p);
                        self.set_transfer_status(&key, "Waiting for the receiver to accept…");
                        continue;
                    }
                    None => {
                        self.finish_transfer(&key, "PIN required", true);
                        return false;
                    }
                },
                Err(SendError::Cancelled) => {
                    self.finish_transfer(&key, "Cancelled", true);
                    return false;
                }
                Err(e) => {
                    let msg = e.to_string();
                    self.finish_transfer(&key, &msg, true);
                    self.toast(&format!("{alias}: {msg}"));
                    return false;
                }
            }
        }
    }

    async fn ask_pin(&self, alias: &str, wrong: bool) -> Option<String> {
        let body = if wrong { format!("That PIN was wrong. Enter the PIN shown on {alias}.") } else { format!("{alias} requires a PIN.") };
        let dialog = adw::AlertDialog::new(Some("Enter PIN"), Some(&body));
        let entry = gtk::PasswordEntry::builder().activates_default(true).show_peek_icon(true).build();
        entry.add_css_class("card");
        dialog.set_extra_child(Some(&entry));
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("ok", "Send");
        dialog.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("ok"));
        dialog.set_close_response("cancel");
        entry.grab_focus();
        let resp = dialog.choose_future(Some(&self.window)).await;
        let text = entry.text().trim().to_string();
        (resp == "ok" && !text.is_empty()).then_some(text)
    }

    fn on_send_event(self: &Rc<Self>, key: &str, ev: SendEvent) {
        match ev {
            SendEvent::Waiting => {}
            SendEvent::Accepted { files, .. } => {
                self.set_transfer_status(key, "Sending");
                for (id, name, size) in files {
                    let mime = gio::content_type_guess(Some(name.as_str()), None).0;
                    self.add_transfer_file(key, &id, &name, size, &mime, None);
                }
            }
            SendEvent::Progress { file_id, sent, .. } => self.update_file_progress(key, &file_id, sent),
            SendEvent::FileDone { file_id } => self.file_finished(key, &file_id, None, None),
            SendEvent::FileFailed { file_id, error } => self.file_finished(key, &file_id, None, Some(error)),
        }
    }

    // ---------------------------------------------------------------- transfers UI

    fn create_transfer(self: &Rc<Self>, key: &str, title: &str, icon_name: &str, alias: &str, kind: TransferKind) {
        let expander = adw::ExpanderRow::builder().title(title).use_markup(false).build();
        expander.add_prefix(&icon(icon_name));
        let bar = gtk::ProgressBar::builder().valign(gtk::Align::Center).width_request(90).build();
        bar.add_css_class("slip-file-bar");
        let spin = spinner();
        spin.set_valign(gtk::Align::Center);
        let cancel_btn = flat_icon_button("process-stop-symbolic", "Cancel");
        let folder_btn = flat_icon_button("folder-open-symbolic", "Open folder");
        folder_btn.set_visible(false);
        expander.add_suffix(&spin);
        expander.add_suffix(&bar);
        expander.add_suffix(&folder_btn);
        expander.add_suffix(&cancel_btn);

        let w = Rc::downgrade(self);
        let k = key.to_string();
        cancel_btn.connect_clicked(move |_| {
            let Some(ui) = w.upgrade() else { return };
            let transfers = ui.transfers.borrow();
            let Some(t) = transfers.get(&k) else { return };
            match &t.kind {
                TransferKind::Send { cancel } => cancel.cancel(),
                TransferKind::Receive { .. } => {
                    drop(transfers);
                    ui.node.cancel_receive();
                }
            }
        });
        let w = Rc::downgrade(self);
        let k = key.to_string();
        folder_btn.connect_clicked(move |_| {
            let Some(ui) = w.upgrade() else { return };
            let dir = match ui.transfers.borrow().get(&k).map(|t| &t.kind) {
                Some(TransferKind::Receive { save_dir }) => Some(save_dir.clone()),
                _ => None,
            };
            if let Some(d) = dir {
                ui.launch_path(&d);
            }
        });

        self.transfers_list.prepend(&expander);
        self.transfers.borrow_mut().insert(
            key.to_string(),
            Transfer {
                expander,
                bar,
                cancel_btn,
                folder_btn,
                spinner: spin,
                files: HashMap::new(),
                started: Instant::now(),
                finished: false,
                kind,
                peer_alias: alias.to_string(),
                status: String::new(),
            },
        );
        if self.stack.visible_child_name().as_deref() != Some("transfers") {
            self.transfers_page.set_needs_attention(true);
        }
    }

    fn set_transfer_status(&self, key: &str, status: &str) {
        if let Some(t) = self.transfers.borrow_mut().get_mut(key) {
            t.status = status.to_string();
            t.refresh();
        }
    }

    fn add_transfer_file(self: &Rc<Self>, key: &str, file_id: &str, name: &str, size: u64, mime: &str, path: Option<PathBuf>) {
        let mut transfers = self.transfers.borrow_mut();
        let Some(t) = transfers.get_mut(key) else { return };
        let row = adw::ActionRow::builder().title(name).subtitle(human_size(size)).use_markup(false).build();
        row.add_prefix(&icon(file_icon(mime)));
        let bar = gtk::ProgressBar::builder().valign(gtk::Align::Center).width_request(80).build();
        let open_btn = flat_icon_button("document-open-symbolic", "Open file");
        open_btn.set_visible(false);
        let reveal_btn = flat_icon_button("folder-open-symbolic", "Show in folder");
        reveal_btn.set_visible(false);
        row.add_suffix(&bar);
        row.add_suffix(&reveal_btn);
        row.add_suffix(&open_btn);
        let path_cell = Rc::new(RefCell::new(path));
        let w = Rc::downgrade(self);
        let pc = path_cell.clone();
        open_btn.connect_clicked(move |_| {
            if let (Some(ui), Some(p)) = (w.upgrade(), pc.borrow().clone()) {
                ui.launch_path(&p);
            }
        });
        let w = Rc::downgrade(self);
        let pc = path_cell.clone();
        reveal_btn.connect_clicked(move |_| {
            if let (Some(ui), Some(p)) = (w.upgrade(), pc.borrow().clone()) {
                ui.reveal_path(&p);
            }
        });
        // Show both buttons together once a path is known.
        let rb = reveal_btn.clone();
        open_btn.connect_visible_notify(move |b| rb.set_visible(b.is_visible()));
        t.expander.add_row(&row);
        t.files.insert(file_id.to_string(), FileEntry { row, bar, open_btn, size, transferred: 0, outcome: None, path: path_cell });
        t.refresh();
    }

    fn update_file_progress(&self, key: &str, file_id: &str, transferred: u64) {
        let mut transfers = self.transfers.borrow_mut();
        let Some(t) = transfers.get_mut(key) else { return };
        if let Some(f) = t.files.get_mut(file_id) {
            f.transferred = transferred;
            f.bar.set_fraction(if f.size == 0 { 1.0 } else { (transferred as f64 / f.size as f64).clamp(0.0, 1.0) });
        }
        t.refresh();
    }

    fn file_finished(&self, key: &str, file_id: &str, path: Option<PathBuf>, error: Option<String>) {
        let mut transfers = self.transfers.borrow_mut();
        let Some(t) = transfers.get_mut(key) else { return };
        if let Some(f) = t.files.get_mut(file_id) {
            f.outcome = Some(error.is_none());
            match &error {
                None => {
                    f.transferred = f.size;
                    f.bar.set_fraction(1.0);
                    f.bar.set_visible(false);
                    if let Some(p) = path {
                        f.row.set_title(&p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
                        f.row.set_subtitle(&format!("{} · {}", human_size(f.size), p.parent().map(|d| d.display().to_string()).unwrap_or_default()));
                        *f.path.borrow_mut() = Some(p);
                        f.open_btn.set_visible(true);
                    }
                }
                Some(e) => {
                    f.bar.set_visible(false);
                    f.row.set_subtitle(&format!("Failed: {e}"));
                    f.row.add_css_class("error");
                }
            }
        }
        t.refresh();
    }

    fn finish_transfer(&self, key: &str, status: &str, failed: bool) {
        let mut transfers = self.transfers.borrow_mut();
        let Some(t) = transfers.get_mut(key) else { return };
        t.finished = true;
        t.status = status.to_string();
        t.cancel_btn.set_visible(false);
        t.spinner.set_visible(false);
        t.bar.set_visible(false);
        if failed {
            t.expander.add_css_class("error");
        }
        let is_receive = matches!(t.kind, TransferKind::Receive { .. });
        t.folder_btn.set_visible(is_receive && t.done_count() > 0);
        let _ = &t.peer_alias;
        t.refresh();
    }

    fn clear_finished(&self) {
        let mut transfers = self.transfers.borrow_mut();
        let done: Vec<String> = transfers.iter().filter(|(_, t)| t.finished).map(|(k, _)| k.clone()).collect();
        for k in done {
            if let Some(t) = transfers.remove(&k) {
                self.transfers_list.remove(&t.expander);
            }
        }
        // Message history rows are plain ActionRows tagged with a widget name.
        let mut child = self.transfers_list.first_child();
        while let Some(c) = child {
            child = c.next_sibling();
            if c.widget_name() == "slip-message" {
                self.transfers_list.remove(&c);
            }
        }
    }

    fn launch_path(&self, path: &Path) {
        let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(path)));
        let w = self.window.clone();
        let toasts = self.toasts.clone();
        launcher.launch(Some(&w), None::<&gio::Cancellable>, move |res| {
            if let Err(e) = res {
                toasts.add_toast(adw::Toast::new(&format!("Couldn't open: {}", e.message())));
            }
        });
    }

    fn reveal_path(&self, path: &Path) {
        let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(path)));
        let toasts = self.toasts.clone();
        launcher.open_containing_folder(Some(&self.window), None::<&gio::Cancellable>, move |res| {
            if let Err(e) = res {
                toasts.add_toast(adw::Toast::new(&format!("Couldn't open folder: {}", e.message())));
            }
        });
    }

    // ---------------------------------------------------------------- receiving

    fn handle_event(self: &Rc<Self>, ev: Event) {
        match ev {
            Event::PeerUpdated(p) => self.upsert_device(p),
            Event::PeerLost { fingerprint } => self.remove_device(&fingerprint),
            Event::IncomingRequest(req) => self.show_incoming(req),
            Event::IncomingRequestClosed { id } => {
                if let Some((_, dialog)) = self.incoming.borrow_mut().remove(&id) {
                    dialog.force_close();
                }
                self.app.withdraw_notification(&format!("incoming-{id}"));
            }
            Event::TextReceived { sender, text } => self.show_text(&sender.alias, &text),
            Event::ReceiveStarted { session_id, sender, files, save_dir } => {
                let key = format!("recv-{session_id}");
                self.create_transfer(&key, &format!("Receiving from {}", sender.alias), "folder-download-symbolic", &sender.alias, TransferKind::Receive { save_dir });
                self.set_transfer_status(&key, "Receiving");
                for f in files {
                    self.add_transfer_file(&key, &f.id, &f.file_name, f.size, &f.file_type, None);
                }
            }
            Event::ReceiveProgress { session_id, file_id, received, .. } => {
                self.update_file_progress(&format!("recv-{session_id}"), &file_id, received)
            }
            Event::ReceiveFileDone { session_id, file_id, path } => {
                self.file_finished(&format!("recv-{session_id}"), &file_id, Some(path), None)
            }
            Event::ReceiveFileFailed { session_id, file_id, error } => {
                self.file_finished(&format!("recv-{session_id}"), &file_id, None, Some(error))
            }
            Event::ReceiveFinished { session_id, cancelled } => {
                let key = format!("recv-{session_id}");
                let (alias, done, total) = match self.transfers.borrow().get(&key) {
                    Some(t) => (t.peer_alias.clone(), t.done_count(), t.files.len()),
                    None => return,
                };
                if cancelled {
                    self.finish_transfer(&key, "Cancelled", true);
                    self.toast(&format!("Transfer from {alias} was cancelled"));
                } else {
                    let failed = total.saturating_sub(done);
                    let status = if failed == 0 { format!("Received {}", plural(done, "file", "files")) } else { format!("{done} received, {failed} failed") };
                    self.finish_transfer(&key, &status, failed > 0);
                    let msg = format!("Received {} from {alias}", plural(done, "file", "files"));
                    self.toast(&msg);
                    self.notify(&key, "Transfer complete", &msg, &[]);
                }
            }
            Event::Warning(w) => {
                self.toast(&w);
                self.refresh_receive_page();
            }
        }
    }

    fn answer_incoming(&self, id: u64, decision: Decision) {
        if let Some((req, dialog)) = self.incoming.borrow_mut().remove(&id) {
            req.respond(decision);
            dialog.force_close();
        }
        self.app.withdraw_notification(&format!("incoming-{id}"));
    }

    fn show_incoming(self: &Rc<Self>, req: Arc<IncomingRequest>) {
        let alias = req.sender.alias.clone();
        let model = req.sender.device_model.clone().unwrap_or_else(|| "Unknown device".into());
        let n = req.files.len();
        let heading = format!("{alias} wants to send you {}", plural(n, "file", "files"));
        let body = format!("{model} · {} · {} total", req.sender_ip, human_size(req.total_size()));
        let dialog = adw::AlertDialog::new(Some(&heading), Some(&body));

        let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).css_classes(["boxed-list"]).build();
        let mut checks: Vec<(String, gtk::CheckButton)> = Vec::new();
        let mut files = req.files.clone();
        files.sort_by(|a, b| a.file_name.cmp(&b.file_name));
        for f in &files {
            let row = adw::ActionRow::builder().title(f.file_name.as_str()).subtitle(human_size(f.size)).use_markup(false).build();
            let check = gtk::CheckButton::builder().active(true).valign(gtk::Align::Center).build();
            row.add_prefix(&check);
            row.add_suffix(&icon(file_icon(&f.file_type)));
            row.set_activatable_widget(Some(&check));
            list.append(&row);
            checks.push((f.id.clone(), check));
        }
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .max_content_height(280)
            .child(&list)
            .build();
        dialog.set_extra_child(Some(&scroller));
        dialog.add_response("decline", "Decline");
        dialog.add_response("accept", "Accept");
        dialog.set_response_appearance("decline", adw::ResponseAppearance::Destructive);
        dialog.set_response_appearance("accept", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("accept"));
        dialog.set_close_response("decline");

        let id = req.id;
        let w = Rc::downgrade(self);
        dialog.connect_response(None, move |_, response| {
            let Some(ui) = w.upgrade() else { return };
            let Some((req, _)) = ui.incoming.borrow_mut().remove(&id) else { return };
            ui.app.withdraw_notification(&format!("incoming-{id}"));
            if response == "accept" {
                let selected: Vec<String> = checks.iter().filter(|(_, c)| c.is_active()).map(|(id, _)| id.clone()).collect();
                if selected.is_empty() {
                    req.respond(Decision::Decline);
                } else if selected.len() == checks.len() {
                    req.respond(Decision::Accept(None));
                } else {
                    req.respond(Decision::Accept(Some(selected)));
                }
            } else {
                req.respond(Decision::Decline);
            }
        });
        self.incoming.borrow_mut().insert(id, (req, dialog.clone()));
        self.notify(
            &format!("incoming-{id}"),
            &heading,
            &body,
            &[("Decline", "app.decline-incoming", Some(id.to_variant())), ("Accept", "app.accept-incoming", Some(id.to_variant()))],
        );
        dialog.present(Some(&self.window));
    }

    fn show_text(self: &Rc<Self>, alias: &str, text: &str) {
        let dialog = adw::AlertDialog::new(Some(&format!("Message from {alias}")), None);
        let label = gtk::Label::builder().label(text).wrap(true).wrap_mode(gtk::pango::WrapMode::WordChar).selectable(true).xalign(0.0).build();
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .max_content_height(320)
            .child(&label)
            .build();
        dialog.set_extra_child(Some(&scroller));
        dialog.add_response("close", "Close");
        dialog.add_response("copy", "Copy");
        dialog.set_response_appearance("copy", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("copy"));
        dialog.set_close_response("close");
        let t = text.to_string();
        let w = Rc::downgrade(self);
        dialog.connect_response(None, move |_, response| {
            if response == "copy" {
                if let Some(ui) = w.upgrade() {
                    ui.window.clipboard().set_text(&t);
                    ui.toast("Copied to clipboard");
                }
            }
        });
        dialog.present(Some(&self.window));

        // Keep it in the Transfers history with a copy button.
        let preview: String = text.chars().take(120).map(|c| if c == '\n' { ' ' } else { c }).collect();
        let row = adw::ActionRow::builder().title(format!("Message from {alias}")).subtitle(preview.as_str()).use_markup(false).build();
        row.set_widget_name("slip-message");
        row.add_prefix(&icon("mail-unread-symbolic"));
        let copy = flat_icon_button("edit-copy-symbolic", "Copy");
        let t = text.to_string();
        let w = Rc::downgrade(self);
        copy.connect_clicked(move |_| {
            if let Some(ui) = w.upgrade() {
                ui.window.clipboard().set_text(&t);
                ui.toast("Copied to clipboard");
            }
        });
        row.add_suffix(&copy);
        self.transfers_list.prepend(&row);
        self.notify("message", &format!("Message from {alias}"), &preview, &[]);
    }
}

fn apply_theme(theme: Theme) {
    let sm = adw::StyleManager::default();
    sm.set_color_scheme(match theme {
        Theme::System => adw::ColorScheme::Default,
        Theme::Light => adw::ColorScheme::ForceLight,
        Theme::Dark => adw::ColorScheme::ForceDark,
    });
}

fn clamp(child: &impl IsA<gtk::Widget>) -> adw::Clamp {
    adw::Clamp::builder().maximum_size(640).tightening_threshold(480).child(child).build()
}

fn scrolled(child: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).child(child).build()
}

fn tray_button(icon_name: &str, label: &str) -> gtk::Button {
    let content = adw::ButtonContent::builder().icon_name(icon_name).label(label).build();
    gtk::Button::builder().child(&content).css_classes(["pill"]).build()
}
