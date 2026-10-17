//! Host execution primitive.
//!
//! Every panel ultimately runs a shell command on one configured host. Local
//! commands run through a login `bash`; remote ones go over the user's own ssh
//! configuration, so a host alias resolves exactly as it does in a terminal and
//! no new credential path is introduced.

use crate::settings::{self, Host};
use serde::Serialize;
use std::process::Stdio;
use tokio::process::Command;

/// Wrap a string so a POSIX shell sees it as one literal argument.
/// Paths and unit names reach the shell, so this is not optional.
pub fn shq(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// A child process that never opens a console window on Windows.
pub fn command(program: &str) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c.stdin(Stdio::null());
    c
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
    /// Exactly what ran, for display in confirmation dialogs and the log.
    pub command: String,
}

/// Build the argv actually spawned, plus a human-readable rendering.
pub fn plan(h: &Host, script: &str) -> Result<(Vec<String>, String), String> {
    match &h.ssh {
        None if cfg!(windows) => Err(format!(
            "{}: local hosts need a POSIX shell; on Windows, reach hosts over ssh",
            h.name
        )),
        None => Ok((
            vec!["bash".into(), "-lc".into(), script.into()],
            script.into(),
        )),
        Some(dest) => Ok((
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", dest, script]
                .map(String::from)
                .to_vec(),
            format!("ssh {dest} {}", shq(script)),
        )),
    }
}

fn plan_for(host: &str, script: &str) -> Result<(Vec<String>, String), String> {
    plan(settings::load()?.host(host)?, script)
}

/// Run a shell snippet on a host and collect its output.
pub async fn run(host: &str, script: &str) -> Result<Output, String> {
    let (argv, rendered) = plan_for(host, script)?;
    let out = command(&argv[0])
        .args(&argv[1..])
        .output()
        .await
        .map_err(|e| format!("could not start {}: {e}", argv[0]))?;
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
    plan_for(&host, &script).map(|(_, rendered)| rendered)
}

#[tauri::command]
pub async fn run_on(host: String, script: String) -> Result<Output, String> {
    run(&host, &script).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(ssh: Option<&str>) -> Host {
        Host { name: "h".into(), ssh: ssh.map(String::from), label: String::new() }
    }

    #[test]
    fn quotes_single_quotes() {
        assert_eq!(shq("it's"), r"'it'\''s'");
    }

    #[test]
    fn remote_plans_are_non_interactive_and_end_option_parsing() {
        let (argv, shown) = plan(&host(Some("web-1")), "uptime").unwrap();
        assert_eq!(argv[0], "ssh");
        assert!(argv.contains(&"BatchMode=yes".to_string()));
        assert_eq!(argv[argv.len() - 3..], ["--", "web-1", "uptime"]);
        assert_eq!(shown, "ssh web-1 'uptime'");
    }

    #[test]
    fn local_plans_need_a_posix_shell() {
        let p = plan(&host(None), "uptime");
        assert_eq!(p.is_ok(), cfg!(unix));
    }
}
