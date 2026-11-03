use std::time::Duration;

use adw::prelude::*;

pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut u = 0;
    while v >= 1000.0 && u < UNITS.len() - 1 {
        v /= 1000.0;
        u += 1;
    }
    if u == 0 {
        format!("{bytes} B")
    } else if v < 10.0 {
        format!("{v:.1} {}", UNITS[u])
    } else {
        format!("{v:.0} {}", UNITS[u])
    }
}

pub fn human_speed(bytes: u64, elapsed: Duration) -> String {
    let secs = elapsed.as_secs_f64();
    if secs < 0.2 {
        return String::new();
    }
    format!("{}/s", human_size((bytes as f64 / secs) as u64))
}

pub fn plural(n: usize, one: &str, many: &str) -> String {
    if n == 1 {
        format!("1 {one}")
    } else {
        format!("{n} {many}")
    }
}

/// A spinner: `AdwSpinner` on libadwaita ≥ 1.6, `GtkSpinner` otherwise.
pub fn spinner() -> gtk::Widget {
    #[cfg(feature = "adw_1_6")]
    {
        adw::Spinner::new().upcast()
    }
    #[cfg(not(feature = "adw_1_6"))]
    {
        let s = gtk::Spinner::new();
        s.start();
        s.upcast()
    }
}

/// Icon for a file name / mime type.
pub fn file_icon(file_type: &str) -> &'static str {
    let t = file_type.to_ascii_lowercase();
    if t.starts_with("image/") {
        "image-x-generic-symbolic"
    } else if t.starts_with("video/") {
        "video-x-generic-symbolic"
    } else if t.starts_with("audio/") {
        "audio-x-generic-symbolic"
    } else if t.starts_with("text/") {
        "text-x-generic-symbolic"
    } else if t.contains("zip") || t.contains("tar") || t.contains("compressed") {
        "package-x-generic-symbolic"
    } else {
        "text-x-generic-symbolic"
    }
}

pub fn icon(name: &str) -> gtk::Image {
    gtk::Image::from_icon_name(name)
}

pub fn flat_icon_button(icon_name: &str, tooltip: &str) -> gtk::Button {
    let b = gtk::Button::from_icon_name(icon_name);
    b.set_tooltip_text(Some(tooltip));
    b.set_valign(gtk::Align::Center);
    b.add_css_class("flat");
    b
}
