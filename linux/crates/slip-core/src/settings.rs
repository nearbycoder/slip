//! User settings, persisted as `settings.json` in the config directory.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{alias, DEFAULT_PORT, MULTICAST_GROUP};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub alias: String,
    pub port: u16,
    pub https: bool,
    /// `None` → XDG Downloads.
    pub save_dir: Option<PathBuf>,
    pub quick_save: bool,
    pub require_pin: bool,
    pub pin: String,
    pub discoverable: bool,
    pub theme: Theme,
    pub multicast_group: String,
    pub multicast_port: u16,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            alias: alias::generate_alias(),
            port: DEFAULT_PORT,
            https: true,
            save_dir: None,
            quick_save: false,
            require_pin: false,
            pin: String::new(),
            discoverable: true,
            theme: Theme::System,
            multicast_group: MULTICAST_GROUP.to_string(),
            multicast_port: DEFAULT_PORT,
        }
    }
}

impl Settings {
    /// Load from `path`; a missing/corrupt file yields defaults which are then persisted.
    pub fn load_or_default(path: &Path) -> Self {
        let parsed = fs::read(path).ok().and_then(|b| serde_json::from_slice::<Settings>(&b).ok());
        match parsed {
            Some(mut s) => {
                if s.alias.trim().is_empty() {
                    s.alias = alias::generate_alias();
                }
                s
            }
            None => {
                let s = Settings::default();
                let _ = s.save(path);
                s
            }
        }
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self).expect("serialisable"))?;
        fs::rename(tmp, path)
    }

    pub fn effective_save_dir(&self) -> PathBuf {
        self.save_dir.clone().unwrap_or_else(default_save_dir)
    }

    pub fn effective_pin(&self) -> Option<String> {
        (self.require_pin && !self.pin.is_empty()).then(|| self.pin.clone())
    }

    pub fn multicast_group(&self) -> std::net::Ipv4Addr {
        self.multicast_group.parse().unwrap_or(MULTICAST_GROUP)
    }
}

/// `$SLIP_CONFIG_DIR`, else `$XDG_CONFIG_HOME/slip` (`~/.config/slip`).
pub fn config_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("SLIP_CONFIG_DIR") {
        return PathBuf::from(d);
    }
    dirs::config_dir().unwrap_or_else(|| home().join(".config")).join("slip")
}

/// XDG Downloads (from `user-dirs.dirs`), falling back to `~/Downloads`.
pub fn default_save_dir() -> PathBuf {
    dirs::download_dir().unwrap_or_else(|| home().join("Downloads"))
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}
