//! The ~/ script runner.
//!
//! Auto-discovers executables in home so a script dropped there shows up with no
//! code change. Output is streamed rather than collected, because the fleet
//! scripts ssh to three hosts and take a while.

use crate::exec;
use serde::Serialize;
use std::process::Stdio;
use tauri::ipc::Channel;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct Script {
    pub path: String,
    pub name: String,
    /// First comment block, used as the description in the UI.
    pub summary: String,
    /// True when the script implements a dry run we should default to.
    pub has_apply: bool,
    pub interpreter: String,
}

fn summarize(body: &str) -> (String, bool) {
    let mut lines = Vec::new();
    for line in body.lines().skip(1) {
        let t = line.trim_start();
        if t.starts_with("#!") {
            continue;
        }
        if let Some(rest) = t.strip_prefix('#') {
            let r = rest.trim();
            if r.is_empty() && lines.is_empty() {
                continue;
            }
            if r.is_empty() {
                break;
            }
            lines.push(r.to_string());
            if lines.len() >= 3 {
                break;
            }
        } else if t.starts_with("\"\"\"") {
            continue;
        } else if !lines.is_empty() {
            break;
        } else if !t.is_empty() && !t.starts_with("import") && !t.starts_with("set ") {
            break;
        }
    }
    let has_apply = body.contains("--apply");
    (lines.join(" "), has_apply)
}

#[tauri::command]
pub fn list_scripts() -> Result<Vec<Script>, String> {
    let home = exec::home();
    let mut out = vec![];
    let rd = std::fs::read_dir(&home).map_err(|e| e.to_string())?;
    for entry in rd.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let ext_ok = name.ends_with(".sh") || name.ends_with(".py");
        if !ext_ok || name.starts_with('.') {
            continue;
        }
        let body = std::fs::read_to_string(&path).unwrap_or_default();
        let (summary, has_apply) = summarize(&body);
        let interpreter = if name.ends_with(".py") { "python3" } else { "bash" };
        out.push(Script {
            path: path.to_string_lossy().into_owned(),
            name,
            summary,
            has_apply,
            interpreter: interpreter.into(),
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Line {
    Stdout { text: String },
    Stderr { text: String },
    Done { code: i32 },
}

/// Run a home script, streaming each line to the UI as it arrives.
#[tauri::command]
pub async fn run_script(
    path: String,
    args: Vec<String>,
    on_line: Channel<Line>,
) -> Result<(), String> {
    // Only ever run things out of home: this command takes a path from the UI.
    let home = exec::home();
    let p = std::path::Path::new(&path);
    let canon = p.canonicalize().map_err(|e| format!("{path}: {e}"))?;
    if canon.parent() != Some(home.as_path()) {
        return Err("refusing to run a script outside home".into());
    }
    for a in &args {
        if !matches!(a.as_str(), "--apply" | "--dry-run" | "") {
            return Err(format!("refusing unexpected argument: {a}"));
        }
    }

    let interp = if canon.to_string_lossy().ends_with(".py") { "python3" } else { "bash" };
    let mut child = Command::new(interp)
        .arg(&canon)
        .args(args.iter().filter(|a| !a.is_empty()))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;

    let stdout = child.stdout.take().ok_or("no stdout")?;
    let stderr = child.stderr.take().ok_or("no stderr")?;
    let c1 = on_line.clone();
    let c2 = on_line.clone();

    let h1 = tokio::spawn(async move {
        let mut l = BufReader::new(stdout).lines();
        while let Ok(Some(text)) = l.next_line().await {
            let _ = c1.send(Line::Stdout { text });
        }
    });
    let h2 = tokio::spawn(async move {
        let mut l = BufReader::new(stderr).lines();
        while let Ok(Some(text)) = l.next_line().await {
            let _ = c2.send(Line::Stderr { text });
        }
    });

    let status = child.wait().await.map_err(|e| e.to_string())?;
    let _ = tokio::join!(h1, h2);
    let _ = on_line.send(Line::Done { code: status.code().unwrap_or(-1) });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_leading_comment_block() {
        let (s, apply) = summarize("#!/usr/bin/env bash\n# Does a thing.\n# Second line.\n\nset -e\n");
        assert_eq!(s, "Does a thing. Second line.");
        assert!(!apply);
    }

    #[test]
    fn detects_dry_run_support() {
        let (_, apply) = summarize("#!/bin/bash\n# x\n\nif [ \"$1\" = \"--apply\" ]; then :; fi\n");
        assert!(apply);
    }
}
