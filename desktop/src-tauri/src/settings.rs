//! User settings: everything specific to one installation lives here, not in
//! the binary.
//!
//! Read from `<config dir>/biz-kit/config.json` on every call, so an edit takes
//! effect without a restart. A missing file means "use the defaults"; a
//! malformed one is reported, never silently replaced by defaults.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// A machine the app can act on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Host {
    pub name: String,
    /// ssh destination (an alias from `~/.ssh/config` works), or None for the
    /// machine the app runs on.
    #[serde(default)]
    pub ssh: Option<String>,
    #[serde(default)]
    pub label: String,
}

/// A file, or shell glob, listed in the Configs panel.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigPattern {
    /// Expanded on the target host, so `$HOME` and globs refer to that host.
    pub path: String,
    #[serde(default)]
    pub label: Option<String>,
}

/// An extra health check: a shell command run on every host. Exit 0 is healthy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Check {
    pub label: String,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub hosts: Vec<Host>,
    /// Directory scanned by the Scripts panel. Defaults to the home directory.
    pub scripts_dir: Option<PathBuf>,
    pub configs: Vec<ConfigPattern>,
    /// Case-insensitive substrings; any config path containing one is read-only.
    pub protected_paths: Vec<String>,
    pub checks: Vec<Check>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            hosts: default_hosts(),
            scripts_dir: None,
            configs: vec![
                ConfigPattern { path: "$HOME/.config/systemd/user/*.service".into(), label: None },
                ConfigPattern { path: "$HOME/.config/systemd/user/*.d/*.conf".into(), label: None },
            ],
            protected_paths: vec![],
            checks: vec![],
        }
    }
}

/// Only the local machine, and only where a POSIX shell is guaranteed. On
/// Windows the app manages remote hosts exclusively.
fn default_hosts() -> Vec<Host> {
    if cfg!(unix) {
        vec![Host { name: "local".into(), ssh: None, label: "this machine".into() }]
    } else {
        vec![]
    }
}

impl Settings {
    pub fn parse(json: &str) -> Result<Self, String> {
        serde_json::from_str(json).map_err(|e| format!("{}: {e}", path().display()))
    }

    pub fn scripts_dir(&self) -> PathBuf {
        self.scripts_dir.clone().unwrap_or_else(home)
    }

    pub fn host(&self, name: &str) -> Result<&Host, String> {
        self.hosts
            .iter()
            .find(|h| h.name == name)
            .ok_or_else(|| format!("unknown host: {name}"))
    }

    pub fn is_protected(&self, path: &str) -> bool {
        let p = path.to_lowercase();
        self.protected_paths.iter().any(|s| p.contains(&s.to_lowercase()))
    }
}

pub fn path() -> PathBuf {
    dirs::config_dir().unwrap_or_else(home).join("biz-kit").join("config.json")
}

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

pub fn load() -> Result<Settings, String> {
    match std::fs::read_to_string(path()) {
        Ok(s) => Settings::parse(&s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
        Err(e) => Err(format!("{}: {e}", path().display())),
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppInfo {
    pub config_path: String,
    pub scripts_dir: String,
    pub hosts: Vec<Host>,
}

#[tauri::command]
pub fn app_info() -> Result<AppInfo, String> {
    let s = load()?;
    Ok(AppInfo {
        config_path: path().display().to_string(),
        scripts_dir: s.scripts_dir().display().to_string(),
        hosts: s.hosts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_object_means_defaults() {
        assert_eq!(Settings::parse("{}").unwrap(), Settings::default());
    }

    #[test]
    fn partial_settings_keep_the_other_defaults() {
        let s = Settings::parse(r#"{"hosts":[{"name":"web","ssh":"web-1"}]}"#).unwrap();
        assert_eq!(s.hosts, vec![Host { name: "web".into(), ssh: Some("web-1".into()), label: "".into() }]);
        assert_eq!(s.configs, Settings::default().configs);
    }

    #[test]
    fn malformed_settings_are_an_error_not_defaults() {
        assert!(Settings::parse("{\"hosts\": [").is_err());
        assert!(Settings::parse(r#"{"hosts":[{"ssh":"x"}]}"#).is_err());
    }

    #[test]
    fn protected_paths_match_case_insensitively() {
        let s = Settings { protected_paths: vec!["Secrets".into()], ..Settings::default() };
        assert!(s.is_protected("$HOME/.config/app/secrets/token.json"));
        assert!(!s.is_protected("$HOME/.config/app/settings.json"));
        assert!(!Settings::default().is_protected("anything"));
    }

    #[test]
    fn unknown_hosts_are_refused() {
        assert!(Settings::default().host("nope").is_err());
    }

    #[test]
    fn local_host_is_default_only_on_unix() {
        assert_eq!(Settings::default().hosts.iter().any(|h| h.ssh.is_none()), cfg!(unix));
    }
}
