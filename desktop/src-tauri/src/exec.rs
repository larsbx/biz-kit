//! Host execution primitive.
//!
//! Every panel ultimately runs a shell command on one of the fleet hosts. Local
//! commands run through `bash -lc`; remote ones go over the user's existing ssh
//! config, so `papa` resolves exactly as it does in a terminal and no
//! new credential path is introduced.

use serde::{Deserialize, Serialize};
use std::process::Stdio;
use tokio::process::Command;

/// A fleet member. `local` is the workstation the app runs on.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Host {
    pub name: String,
    /// ssh destination, or None for the machine we are running on.
    pub ssh: Option<String>,
    pub label: String,
}

impl Host {
    pub fn is_local(&self) -> bool {
        self.ssh.is_none()
    }
}

/// Default fleet. Overridable via ~/.config/biz-kit/hosts.json so a new
/// box can be added without a rebuild.
pub fn default_hosts() -> Vec<Host> {
    vec![
        Host { name: "adder-ws".into(), ssh: None, label: "workstation (local)".into() },
        Host { name: "papa".into(), ssh: Some("papa".into()), label: "papa - EU, openclaw".into() },
    ]
}

pub fn load_hosts() -> Vec<Host> {
    let path = dirs_config().join("hosts.json");
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<Host>>(&s).ok())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(default_hosts)
}

pub fn dirs_config() -> std::path::PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| home().join(".config"));
    base.join("biz-kit")
}

pub fn home() -> std::path::PathBuf {
    std::env::var("HOME").map(std::path::PathBuf::from).unwrap_or_default()
}

/// Wrap a string so a POSIX shell sees it as one literal argument.
/// Paths and unit names reach the shell, so this is not optional.
pub fn shq(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[derive(Debug, Clone, Serialize)]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
    /// Exactly what ran, for display in confirmation dialogs and the log.
    pub command: String,
}

fn host_by_name(name: &str) -> Result<Host, String> {
    load_hosts()
        .into_iter()
        .find(|h| h.name == name)
        .ok_or_else(|| format!("unknown host: {name}"))
}

/// Build the argv actually spawned, plus a human-readable rendering.
pub fn plan(host: &str, script: &str) -> Result<(Vec<String>, String), String> {
    let h = host_by_name(host)?;
    if h.is_local() {
        Ok((
            vec!["bash".into(), "-lc".into(), script.to_string()],
            script.to_string(),
        ))
    } else {
        let dest = h.ssh.clone().unwrap();
        Ok((
            vec![
                "ssh".into(),
                "-o".into(),
                "BatchMode=yes".into(),
                "-o".into(),
                "ConnectTimeout=10".into(),
                dest.clone(),
                script.to_string(),
            ],
            format!("ssh {dest} {}", shq(script)),
        ))
    }
}

/// Run a shell snippet on a host and collect its output.
pub async fn run(host: &str, script: &str) -> Result<Output, String> {
    let (argv, rendered) = plan(host, script)?;
    let out = Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .output()
        .await
        .map_err(|e| format!("spawn failed: {e}"))?;
    Ok(Output {
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        code: out.status.code().unwrap_or(-1),
        command: rendered,
    })
}

/// Preview a command without running it. Backs the confirmation dialog so what
/// the user approves is textually the same string that will execute.
#[tauri::command]
pub fn preview_command(host: String, script: String) -> Result<String, String> {
    plan(&host, &script).map(|(_, rendered)| rendered)
}

#[tauri::command]
pub fn list_hosts() -> Vec<Host> {
    load_hosts()
}

#[tauri::command]
pub async fn run_on(host: String, script: String) -> Result<Output, String> {
    run(&host, &script).await
}
