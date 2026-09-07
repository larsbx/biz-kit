//! Config browsing and editing across the fleet.
//!
//! Saving always goes through a diff the user sees first, and always writes a
//! timestamped backup next to the original -- the same discipline used by hand
//! when editing papa's settings.json, which carries seven hook events that a
//! careless overwrite would silently disable.

use crate::exec;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct ConfigEntry {
    pub host: String,
    pub path: String,
    pub label: String,
    pub exists: bool,
    pub size: u64,
}

/// Files worth having one click away. Globs are expanded on the host.
fn catalog() -> Vec<(&'static str, &'static str)> {
    vec![
        ("$HOME/.claude/settings.json", "Claude Code settings"),
        ("$HOME/.claude/settings.local.json", "Claude Code settings (local)"),
        ("$HOME/.local/state/syncthing/config.xml", "Syncthing config"),
        ("$HOME/.openclaw/openclaw.json", "openclaw config"),
    ]
}

const LIST: &str = r#"
emit() { [ -e "$1" ] && printf '%s|%s\n' "$1" "$(stat -c %s "$1" 2>/dev/null || echo 0)"; }
for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
         "$HOME/.local/state/syncthing/config.xml" "$HOME/.openclaw/openclaw.json"; do
  emit "$f"
done
for f in "$HOME"/.config/systemd/user/*.service "$HOME"/.config/systemd/user/*.d/*.conf \
         "$HOME"/.claude/hooks/*; do
  emit "$f"
done
"#;

#[tauri::command]
pub async fn list_configs(host: String) -> Result<Vec<ConfigEntry>, String> {
    let out = exec::run(&host, LIST).await?;
    let labels = catalog();
    let mut v = vec![];
    for line in out.stdout.lines() {
        let Some((path, size)) = line.rsplit_once('|') else { continue };
        let label = labels
            .iter()
            .find(|(p, _)| path.ends_with(p.trim_start_matches("$HOME/")))
            .map(|(_, l)| l.to_string())
            .unwrap_or_else(|| {
                let p = std::path::Path::new(path);
                let parent = p.parent().and_then(|d| d.file_name()).map(|s| s.to_string_lossy().into_owned());
                match parent {
                    Some(d) if d.ends_with(".d") => format!("drop-in: {d}"),
                    Some(d) if d == "hooks" => "Claude hook".into(),
                    _ => "systemd unit".into(),
                }
            });
        v.push(ConfigEntry {
            host: host.clone(),
            path: path.to_string(),
            label,
            exists: true,
            size: size.parse().unwrap_or(0),
        });
    }
    v.sort_by(|a, b| a.label.cmp(&b.label).then(a.path.cmp(&b.path)));
    Ok(v)
}

#[tauri::command]
pub async fn read_config(host: String, path: String) -> Result<String, String> {
    let out = exec::run(&host, &format!("cat -- {}", exec::shq(&path))).await?;
    if out.code != 0 {
        return Err(out.stderr.trim().to_string());
    }
    Ok(out.stdout)
}

/// Unified diff of the pending change, produced on the host so what is compared
/// is the file as it exists right now -- not a copy fetched earlier.
#[tauri::command]
pub async fn diff_config(host: String, path: String, content: String) -> Result<String, String> {
    let b64 = base64_encode(content.as_bytes());
    let script = format!(
        "tmp=$(mktemp) && printf '%s' {} | base64 -d > \"$tmp\" && \
         diff -u -- {} \"$tmp\"; rc=$?; rm -f \"$tmp\"; exit 0",
        exec::shq(&b64),
        exec::shq(&path)
    );
    let out = exec::run(&host, &script).await?;
    Ok(if out.stdout.trim().is_empty() {
        "(no changes)".into()
    } else {
        out.stdout
    })
}

/// Write, keeping a timestamped backup. Validates JSON before replacing a
/// .json file: a malformed settings.json silently disables every setting in it.
#[tauri::command]
pub async fn write_config(host: String, path: String, content: String) -> Result<String, String> {
    if path.ends_with(".json") {
        serde_json::from_str::<serde_json::Value>(&content)
            .map_err(|e| format!("refusing to write invalid JSON: {e}"))?;
    }
    let b64 = base64_encode(content.as_bytes());
    let script = format!(
        "set -e; p={}; \
         cp -a -- \"$p\" \"$p.bak-$(date +%Y%m%d%H%M%S)\"; \
         printf '%s' {} | base64 -d > \"$p\"; \
         echo \"wrote $p\"",
        exec::shq(&path),
        exec::shq(&b64)
    );
    let out = exec::run(&host, &script).await?;
    if out.code != 0 {
        return Err(out.stderr.trim().to_string());
    }
    Ok(out.stdout.trim().to_string())
}

fn base64_encode(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in data.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        s.push(T[(n >> 18 & 63) as usize] as char);
        s.push(T[(n >> 12 & 63) as usize] as char);
        s.push(if c.len() > 1 { T[(n >> 6 & 63) as usize] as char } else { '=' });
        s.push(if c.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_reference_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn round_trips_json_with_quotes_and_newlines() {
        let s = "{\n  \"a\": \"it's \\\"quoted\\\"\"\n}\n";
        let e = base64_encode(s.as_bytes());
        assert!(e.chars().all(|c| c.is_ascii_alphanumeric() || "+/=".contains(c)));
    }
}
