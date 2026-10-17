//! Config browsing and editing on any configured host.
//!
//! Saving always goes through a diff the user sees first, and always writes a
//! timestamped backup next to the original: a careless overwrite of a settings
//! file can silently disable everything in it.

use crate::exec;
use crate::settings::{self, ConfigPattern};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigEntry {
    pub host: String,
    pub path: String,
    pub label: String,
    pub size: u64,
    /// Matches a `protectedPaths` entry; shown, never written.
    pub protected: bool,
}

/// `$HOME`/`~` prefixes are quoted so a home with spaces survives word
/// splitting; the remainder stays unquoted so globs expand on the host.
fn shell_pattern(p: &str) -> String {
    match p.strip_prefix("$HOME").or_else(|| p.strip_prefix('~')) {
        Some(rest) => format!("\"$HOME\"{rest}"),
        None => p.to_string(),
    }
}

/// One `index|bytes|path` line per existing match, `index` naming the pattern.
fn list_script(patterns: &[ConfigPattern]) -> String {
    let loops: String = patterns
        .iter()
        .enumerate()
        .map(|(i, c)| format!("for f in {}; do emit {i} \"$f\"; done\n", shell_pattern(&c.path)))
        .collect();
    format!(
        "emit() {{ [ -f \"$2\" ] && printf '%s|%s|%s\\n' \"$1\" \"$(wc -c < \"$2\" | tr -d ' ')\" \"$2\"; }}\n{loops}true\n"
    )
}

fn derive_label(path: &str) -> String {
    let parent = std::path::Path::new(path)
        .parent()
        .and_then(|d| d.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    if parent.ends_with(".d") {
        format!("drop-in: {parent}")
    } else if path.contains("/systemd/") {
        "systemd unit".into()
    } else if parent.is_empty() {
        "file".into()
    } else {
        parent
    }
}

/// A file matched by several patterns is listed once, under the first.
fn parse_listing(host: &str, raw: &str, s: &settings::Settings) -> Vec<ConfigEntry> {
    let mut seen = std::collections::HashSet::new();
    let mut v: Vec<ConfigEntry> = raw
        .lines()
        .filter_map(|line| {
            let mut f = line.splitn(3, '|');
            let pattern = s.configs.get(f.next()?.parse::<usize>().ok()?)?;
            let size = f.next()?.parse().unwrap_or(0);
            let path = f.next()?.to_string();
            Some(ConfigEntry {
                host: host.to_string(),
                label: pattern.label.clone().unwrap_or_else(|| derive_label(&path)),
                protected: s.is_protected(&path),
                path,
                size,
            })
        })
        .filter(|e| seen.insert(e.path.clone()))
        .collect();
    v.sort_by(|a, b| a.label.cmp(&b.label).then(a.path.cmp(&b.path)));
    v
}

#[tauri::command]
pub async fn list_configs(host: String) -> Result<Vec<ConfigEntry>, String> {
    let s = settings::load()?;
    let out = exec::run(&host, &list_script(&s.configs)).await?;
    Ok(parse_listing(&host, &out.stdout, &s))
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
    if settings::load()?.is_protected(&path) {
        return Err(format!("refusing to write {path}: it matches protectedPaths in settings"));
    }
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

    fn pat(path: &str, label: Option<&str>) -> ConfigPattern {
        ConfigPattern { path: path.into(), label: label.map(String::from) }
    }

    #[test]
    fn patterns_quote_home_and_keep_globs() {
        assert_eq!(shell_pattern("$HOME/a b/*.json"), "\"$HOME\"/a b/*.json");
        assert_eq!(shell_pattern("~/x/*.conf"), "\"$HOME\"/x/*.conf");
        assert_eq!(shell_pattern("/etc/app.conf"), "/etc/app.conf");
    }

    #[test]
    #[cfg(unix)]
    fn listing_script_runs_and_tags_each_pattern() {
        let dir = std::env::temp_dir().join(format!("biz-kit-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("u.d")).unwrap();
        std::fs::write(dir.join("a.json"), "{}").unwrap();
        std::fs::write(dir.join("u.d/x.conf"), "abc").unwrap();
        let d = dir.display();
        let script = list_script(&[pat(&format!("{d}/*.json"), Some("App")), pat(&format!("{d}/*.d/*.conf"), None), pat(&format!("{d}/none-*"), None)]);
        let out = std::process::Command::new("sh").arg("-c").arg(&script).output().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        let raw = String::from_utf8(out.stdout).unwrap();
        assert_eq!(raw, format!("0|2|{d}/a.json\n1|3|{d}/u.d/x.conf\n"));
    }

    #[test]
    fn listing_is_labelled_from_settings_then_derived() {
        let s = settings::Settings {
            configs: vec![pat("$HOME/.app/settings.json", Some("App settings")), pat("$HOME/.config/systemd/user/*", None)],
            protected_paths: vec!["secret".into()],
            ..Default::default()
        };
        let raw = "0|10|/h/.app/settings.json\n1|5|/h/.config/systemd/user/a.service\n1|5|/h/.config/systemd/user/a.service.d/x.conf\n\
                   1|1|/h/.config/systemd/user/secret.service\n1|10|/h/.app/settings.json\n9|1|/nope\ngarbage\n";
        let got: Vec<_> = parse_listing("h", raw, &s).into_iter().map(|e| (e.label, e.protected)).collect();
        assert_eq!(got, [
            ("App settings".into(), false),
            ("drop-in: a.service.d".into(), false),
            ("systemd unit".into(), false),
            ("systemd unit".into(), true),
        ]);
    }
}
