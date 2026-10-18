//! The local script runner.
//!
//! Auto-discovers `.sh` and `.py` files in the configured scripts directory
//! (home by default) so a script dropped there shows up with no code change.
//! Output is streamed rather than collected, because scripts that reach other
//! hosts take a while.

use crate::{exec, settings};
use serde::Serialize;
use std::path::Path;
use std::process::Stdio;
use tauri::ipc::Channel;
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
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
        } else if !lines.is_empty()
            || (!t.is_empty() && !t.starts_with("import") && !t.starts_with("set "))
        {
            break;
        }
    }
    let has_apply = body.contains("--apply");
    (lines.join(" "), has_apply)
}

/// The interpreter for a supported script, or None. Windows installs Python 3
/// as `python`; elsewhere `python` may still be Python 2.
fn interpreter(path: &Path) -> Option<&'static str> {
    match path.extension()?.to_str()? {
        "sh" => Some("bash"),
        "py" if cfg!(windows) => Some("python"),
        "py" => Some("python3"),
        _ => None,
    }
}

#[tauri::command]
pub fn list_scripts() -> Result<Vec<Script>, String> {
    let dir = settings::load()?.scripts_dir();
    let rd = std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut out: Vec<Script> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .filter_map(|path| {
            let name = path.file_name()?.to_string_lossy().into_owned();
            let interpreter = interpreter(&path).filter(|_| !name.starts_with('.'))?;
            let (summary, has_apply) = summarize(&std::fs::read_to_string(&path).unwrap_or_default());
            Some(Script {
                path: path.to_string_lossy().into_owned(),
                name,
                summary,
                has_apply,
                interpreter: interpreter.into(),
            })
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// The canonical path of `path` if it is a supported script directly inside
/// `dir`. Both sides are canonicalised: on Windows that adds a `\\?\` prefix,
/// and on macOS it resolves `/var` to `/private/var`.
fn contained(dir: &Path, path: &Path) -> Result<std::path::PathBuf, String> {
    let canon = path.canonicalize().map_err(|e| format!("{}: {e}", path.display()))?;
    let dir = dir.canonicalize().map_err(|e| format!("{}: {e}", dir.display()))?;
    if canon.parent() != Some(dir.as_path()) || interpreter(&canon).is_none() {
        return Err("refusing to run a file outside the scripts directory".into());
    }
    Ok(canon)
}

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Line {
    Stdout { text: String },
    Stderr { text: String },
    Done { code: i32 },
}

/// Run a script, streaming each line to the UI as it arrives.
#[tauri::command]
pub async fn run_script(
    path: String,
    args: Vec<String>,
    on_line: Channel<Line>,
) -> Result<(), String> {
    // This command takes a path from the UI: only run what list_scripts offers.
    let canon = contained(&settings::load()?.scripts_dir(), Path::new(&path))?;
    for a in &args {
        if !matches!(a.as_str(), "--apply" | "--dry-run" | "") {
            return Err(format!("refusing unexpected argument: {a}"));
        }
    }

    let interp = interpreter(&canon).unwrap_or("bash");
    let mut child = exec::command(interp)
        .arg(&canon)
        .args(args.iter().filter(|a| !a.is_empty()))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not start {interp}: {e}"))?;

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
    fn only_runs_supported_scripts_directly_inside_the_directory() {
        let dir = std::env::temp_dir().join(format!("biz-kit-scripts-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        for f in ["ok.sh", "notes.txt", "sub/deep.sh"] {
            std::fs::write(dir.join(f), "").unwrap();
        }
        assert!(contained(&dir, &dir.join("ok.sh")).is_ok());
        assert!(contained(&dir, &dir.join("sub/../ok.sh")).is_ok());
        assert!(contained(&dir, &dir.join("notes.txt")).is_err());
        assert!(contained(&dir, &dir.join("sub/deep.sh")).is_err());
        assert!(contained(&dir.join("sub"), &dir.join("sub/../ok.sh")).is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn interpreters_follow_the_extension() {
        assert_eq!(interpreter(Path::new("a.sh")), Some("bash"));
        assert_eq!(interpreter(Path::new("a.py")), Some(if cfg!(windows) { "python" } else { "python3" }));
        assert_eq!(interpreter(Path::new("a.txt")), None);
    }

    #[test]
    fn detects_dry_run_support() {
        let (_, apply) = summarize("#!/bin/bash\n# x\n\nif [ \"$1\" = \"--apply\" ]; then :; fi\n");
        assert!(apply);
    }
}
